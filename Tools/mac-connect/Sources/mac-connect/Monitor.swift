import Foundation
import IOKit
import IOKit.hid
import CoreGraphics
import HIDCore

/// `mac-connect monitor [seconds] [--no-open] [--per-device] [--seize [--ack-f13]] [--kbd-type N]`
///
/// Test oracle. Watches only HID devices whose Transport is Bluetooth Low Energy:
/// - DEVICE+/DEVICE- lines when such a device appears or disappears (hot-plug, with timestamps);
/// - VALUE lines for every input value the device delivers (needs the device to open);
/// - CURSOR lines at 4 Hz with the system cursor position and the Caps Lock state;
/// - SYS lines when the system-wide modifier flags or the F13 key state change (polled at 20 Hz);
/// - SYSKEY lines from a listen-only event tap for every key event that reaches the window
///   server, with its keyboard type and (when it can be attributed) the BLE device it came from.
///
/// `--per-device` opens each device on its own (`IOHIDDeviceCreate` + `IOHIDDeviceOpen`) instead
/// of through the manager. `--seize` does the same with kIOHIDOptionsTypeSeizeDevice, so the
/// device's input reaches only this tool: one `SEIZE OK` / `SEIZE FAILED` line per device, and
/// `SEIZE RELEASED` on exit (normal end, SIGINT, SIGTERM, SIGHUP; the kernel also drops the
/// seize if the process dies). Only iPhone-like devices are seized (manufacturer "Apple Inc."
/// and no VendorID, i.e. HIDPad), never another BLE keyboard or mouse. In seize mode, KEY
/// lines show what macOS would type for each key down (UCKeyTranslate, current layout, for the
/// device's keyboard type and for ANSI/ISO/JIS).
/// `--ack-f13` (with `--seize`): after F13 down+up arrives on a seized device and the event
/// tap saw no F13 from the system, write the seize token (LED output 0x1D) to the device.
/// HIDPad's `--selftest=text` types only after receiving it.
/// It never uses CoreBluetooth, so it does not influence how the Mac binds to the phone.
@MainActor
final class Monitor {
    struct Options {
        var openDevices = true
        var perDevice = false
        var seize = false
        var ackF13 = false
        var keyboardTypeOverride: Int?
    }

    static var shared: Monitor?
    static let seizeToken: UInt8 = 0x1D

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private let options: Options
    private var known: [UInt64: String] = [:]
    private var valueCounts: [String: Int] = [:]
    /// Arrival times (from the HID value timestamps) of non-zero X values, for the report-rate estimate.
    private var xTimes: [Double] = []
    private var staleValues = 0
    private var lastCursor: CGPoint?
    private var lastFlags: CGEventFlags?
    private var lastF13: Bool?
    private var opened: [UInt64: OpenedDevice] = [:]
    private var bleServiceIDs: [UInt64: Set<UInt64>] = [:]
    private var tap: SystemTap?
    private var tapEvents: [SystemTap.Event] = []
    private var tapCounts: [String: Int] = [:]
    private var stopReason: String?
    private var layout = KeyTranslate.currentLayout()

    /// A device opened on its own (per-device or seize mode).
    final class OpenedDevice {
        let id: UInt64
        let device: IOHIDDevice
        let product: String
        let seized: Bool
        let keyboardType: Int
        var modifiers: KeyModifiers = []
        var f13Down: Double?
        var typed: [Int: String] = [:]
        var keyDowns = 0
        var acks = 0

        init(id: UInt64, device: IOHIDDevice, product: String, seized: Bool, keyboardType: Int) {
            self.id = id; self.device = device; self.product = product; self.seized = seized; self.keyboardType = keyboardType
        }
    }

    init(options: Options) {
        self.options = options
    }

    func stop(_ reason: String) {
        if stopReason == nil {
            stopReason = reason
            emit("MONITOR stop requested (\(reason))")
        }
    }

    func run(seconds: Double) async -> Int32 {
        let perDevice = options.perDevice || options.seize
        emit("MONITOR start seconds=\(seconds) open=\(options.openDevices) mode=\(options.seize ? "SEIZE" : perDevice ? "per-device" : "manager") ackF13=\(options.ackF13) input-monitoring(ListenEvent)=\(listenAccessName()) \(capsText())")
        if let l = layout { emit("MONITOR keyboard layout for KEY lines: \(l.id)") }
        let tap = SystemTap { ev in DispatchQueue.main.async { MainActor.assumeIsolated { Monitor.shared?.tapEvent(ev) } } }
        self.tap = tap
        emit(tap.start() ? "TAP listen-only event tap running (keyDown/keyUp/flagsChanged)" : "TAP FAILED to create the event tap (Input Monitoring?) — SYSKEY lines unavailable")

        IOHIDManagerSetDeviceMatching(manager, bleMatching())
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { _, _, _, device in
            MainActor.assumeIsolated { Monitor.shared?.deviceAdded(device) }
        }, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { _, _, _, device in
            MainActor.assumeIsolated { Monitor.shared?.deviceRemoved(device) }
        }, nil)
        // Manager mode: values are delivered through the manager: registering a callback on a
        // device after the manager is activated is not allowed, and devices opened one by one
        // deliver nothing to the manager's callback. Opening the manager also opens devices
        // that appear later. Per-device mode opens separate IOHIDDevice objects instead.
        if !perDevice {
            IOHIDManagerRegisterInputValueCallback(manager, { _, _, sender, value in
                MainActor.assumeIsolated { Monitor.shared?.inputValue(value, from: nil) }
            }, nil)
        }
        IOHIDManagerSetDispatchQueue(manager, DispatchQueue.main)
        if options.openDevices && !perDevice {
            let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            emit("OPEN manager -> \(ioReturnName(result))")
            if result == kIOReturnNotPermitted {
                emit("OPEN needs the Input Monitoring permission (System Settings > Privacy & Security > Input Monitoring) for the app hosting this terminal; values may be missing, hot-plug and cursor still work")
            }
        }
        IOHIDManagerActivate(manager)

        let end = Date().addingTimeInterval(seconds)
        var tick = 0
        while Date() < end, stopReason == nil {
            pollSystemKeys()
            if tick % 5 == 0 { sampleCursor() }
            tick += 1
            try? await Task.sleep(for: .milliseconds(50))
        }
        closeAll(reason: stopReason ?? "time up")
        IOHIDManagerCancel(manager)
        if options.openDevices && !perDevice { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        summarize()
        emit("MONITOR end \(capsText())")
        return 0
    }

    // MARK: - Devices

    private func deviceAdded(_ device: IOHIDDevice) {
        let id = registryID(device)
        known[id] = stringProperty(device, kIOHIDProductKey) ?? "-"
        emit("DEVICE+ \(deviceHeadline(device))")
        if let pairs = property(device, kIOHIDDeviceUsagePairsKey) as? [[String: Any]] {
            let text = pairs.map { p in
                String(format: "0x%02X/0x%02X", (p[kIOHIDDeviceUsagePageKey] as? NSNumber)?.intValue ?? -1,
                       (p[kIOHIDDeviceUsageKey] as? NSNumber)?.intValue ?? -1)
            }
            emit("DEVICE+   DeviceUsagePairs: \(text.joined(separator: ", "))")
        }
        let ids = serviceTreeIDs(IOHIDDeviceGetService(device))
        bleServiceIDs[id] = ids
        tap?.setBLEIDs(bleServiceIDs.values.reduce(into: Set<UInt64>()) { $0.formUnion($1) })
        emit("DEVICE+   registry IDs (device and child services): \(ids.sorted().map { String(format: "0x%llx", $0) }.joined(separator: " "))")
        let kt = keyboardType(of: device)
        emit("KBDTYPE device \(String(format: "0x%llx", id)) \(kt.text)")
        guard options.openDevices, options.perDevice || options.seize else { return }
        openSeparately(device, id: id, keyboardType: kt.type)
    }

    private func keyboardType(of device: IOHIDDevice) -> (type: Int, text: String) {
        let key = KeyboardTypeStore.key(productID: intProperty(device, kIOHIDProductIDKey) ?? 0,
                                        vendorID: intProperty(device, kIOHIDVendorIDKey) ?? 0,
                                        countryCode: intProperty(device, kIOHIDCountryCodeKey) ?? 0)
        let stored = KeyboardTypeStore.all()[key]
        var text = "plist key \"\(key)\" -> \(stored.map { "\($0) (\(KeyTranslate.typeName($0)))" } ?? "absent (macOS would ask with Keyboard Setup Assistant)") in \(KeyboardTypeStore.path)"
        if let o = options.keyboardTypeOverride { text += "; using --kbd-type \(o) (\(KeyTranslate.typeName(o)))" }
        return (options.keyboardTypeOverride ?? stored ?? KeyTranslate.ansi, text)
    }

    /// Only HIDPad-like devices are seized: an iPhone serving HID (manufacturer from iOS's own
    /// Device Information, no VendorID in IOKit) with a keyboard collection.
    private func seizeEligible(_ device: IOHIDDevice) -> (Bool, String) {
        let man = stringProperty(device, kIOHIDManufacturerKey) ?? "-"
        let vid = intProperty(device, kIOHIDVendorIDKey) ?? 0
        let pairs = (property(device, kIOHIDDeviceUsagePairsKey) as? [[String: Any]]) ?? []
        let hasKeyboard = pairs.contains { ($0[kIOHIDDeviceUsagePageKey] as? NSNumber)?.intValue == 1 && ($0[kIOHIDDeviceUsageKey] as? NSNumber)?.intValue == 6 }
        let ok = man == "Apple Inc." && vid == 0 && hasKeyboard
        return (ok, "manufacturer=\"\(man)\" vendorID=\(vid) keyboardCollection=\(hasKeyboard)")
    }

    private func openSeparately(_ managerDevice: IOHIDDevice, id: UInt64, keyboardType: Int) {
        let idText = String(format: "0x%llx", id)
        if options.seize {
            let (ok, why) = seizeEligible(managerDevice)
            guard ok else {
                emit("SEIZE SKIPPED device \(idText) (not a HIDPad-like device: \(why)) — not opened")
                return
            }
        }
        guard let dev = IOHIDDeviceCreate(kCFAllocatorDefault, IOHIDDeviceGetService(managerDevice)) else {
            emit("\(options.seize ? "SEIZE FAILED" : "OPEN FAILED") device \(idText): IOHIDDeviceCreate returned nil")
            return
        }
        let o = OpenedDevice(id: id, device: dev, product: known[id] ?? "-", seized: options.seize, keyboardType: keyboardType)
        let mode = IOOptionBits(options.seize ? kIOHIDOptionsTypeSeizeDevice : kIOHIDOptionsTypeNone)
        let result = IOHIDDeviceOpen(dev, mode)
        if result != kIOReturnSuccess {
            emit(options.seize
                 ? "SEIZE FAILED device \(idText) product=\"\(o.product)\" -> \(ioReturnName(result)); its input still reaches the system — do NOT send text"
                 : "OPEN FAILED device \(idText) -> \(ioReturnName(result))")
            return
        }
        let ctx = Unmanaged.passUnretained(o).toOpaque()
        IOHIDDeviceRegisterInputValueCallback(dev, { ctx, _, _, value in
            let o = Unmanaged<Monitor.OpenedDevice>.fromOpaque(ctx!).takeUnretainedValue()
            MainActor.assumeIsolated { Monitor.shared?.inputValue(value, from: o) }
        }, ctx)
        IOHIDDeviceSetDispatchQueue(dev, DispatchQueue.main)
        IOHIDDeviceActivate(dev)
        opened[id] = o
        emit(options.seize
             ? "SEIZE OK device \(idText) product=\"\(o.product)\" (kIOHIDOptionsTypeSeizeDevice) — its input now reaches only this tool; keyboard type for KEY lines: \(keyboardType) (\(KeyTranslate.typeName(keyboardType)))"
             : "OPEN per-device \(idText) product=\"\(o.product)\" -> success")
    }

    private func close(_ o: OpenedDevice, reason: String) {
        let mode = IOOptionBits(o.seized ? kIOHIDOptionsTypeSeizeDevice : kIOHIDOptionsTypeNone)
        let r = IOHIDDeviceClose(o.device, mode)
        IOHIDDeviceCancel(o.device)
        emit("\(o.seized ? "SEIZE RELEASED" : "CLOSE") device \(String(format: "0x%llx", o.id)) (\(reason)) -> \(ioReturnName(r))")
    }

    private func closeAll(reason: String) {
        for o in opened.values { close(o, reason: reason) }
        let wasSeized = opened.values.contains { $0.seized }
        for o in opened.values {
            for (t, s) in o.typed.sorted(by: { $0.key < $1.key }) {
                emit("TYPED device \(String(format: "0x%llx", o.id)) type=\(t) (\(KeyTranslate.typeName(t)))\(t == o.keyboardType ? " [device type]" : "") keyDowns=\(o.keyDowns): \(KeyTranslate.show(s))")
            }
        }
        opened = [:]
        if wasSeized { emit("SEIZE none active (all released)") }
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        let id = registryID(device)
        emit(String(format: "DEVICE- device 0x%llx product=\"%@\"", id, known[id] ?? "-"))
        if let o = opened.removeValue(forKey: id) { close(o, reason: "device removed") }
        known[id] = nil
        bleServiceIDs[id] = nil
        tap?.setBLEIDs(bleServiceIDs.values.reduce(into: Set<UInt64>()) { $0.formUnion($1) })
    }

    /// Registry IDs of a service and everything below it (IOHIDInterface, event driver…).
    private func serviceTreeIDs(_ service: io_service_t) -> Set<UInt64> {
        var ids: Set<UInt64> = []
        func visit(_ entry: io_registry_entry_t, depth: Int) {
            var id: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(entry, &id)
            ids.insert(id)
            guard depth < 4 else { return }
            var iter: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &iter) == KERN_SUCCESS else { return }
            defer { IOObjectRelease(iter) }
            while case let child = IOIteratorNext(iter), child != 0 {
                visit(child, depth: depth + 1)
                IOObjectRelease(child)
            }
        }
        visit(service, depth: 0)
        return ids
    }

    // MARK: - Values

    private func inputValue(_ value: IOHIDValue, from o: OpenedDevice?) {
        let element = IOHIDValueGetElement(value)
        let page = Int(IOHIDElementGetUsagePage(element))
        let usage = Int(IOHIDElementGetUsage(element))
        let integer = IOHIDValueGetIntegerValue(value)
        let reportID = Int(IOHIDElementGetReportID(element))
        let t = Clock.epoch(machTime: IOHIDValueGetTimeStamp(value))
        // Every element of an incoming report is reported; elements whose value did not change
        // keep their old timestamp. Only print values that are new.
        if Date().timeIntervalSince1970 - t > 1.0 {
            staleValues += 1
            return
        }
        let devID = o?.id ?? registryID(IOHIDElementGetDevice(element))
        emit(String(format: "VALUE device 0x%llx rid=%d %@ value=%ld%@", devID, reportID, pageUsage(page, usage), integer, o?.seized == true ? " [seized]" : ""), at: t)
        valueCounts[pageUsage(page, usage) + (integer == 0 ? " =0" : " !=0"), default: 0] += 1
        if page == 0x01 && usage == 0x30 && integer != 0 { xTimes.append(t) }
        if page == 0x07, let o { keyboardValue(o, usage: usage, value: integer, at: t) }
    }

    private func keyboardValue(_ o: OpenedDevice, usage: Int, value: Int, at t: Double) {
        if (0xE0...0xE7).contains(usage) {
            let flag = KeyModifiers(rawValue: 1 << UInt8(usage - 0xE0))
            if value != 0 { o.modifiers.insert(flag) } else { o.modifiers.remove(flag) }
            return
        }
        if usage == 0x68 {
            if value != 0 { o.f13Down = t } else if let down = o.f13Down {
                o.f13Down = nil
                if o.seized && options.ackF13 { scheduleAck(o, downAt: down, upAt: t) }
            }
        }
        guard o.seized, value != 0, (0x04...0xA4).contains(usage) else { return }
        guard let layout else { return }
        o.keyDowns += 1
        var types = [o.keyboardType]
        for x in [KeyTranslate.ansi, KeyTranslate.iso, KeyTranslate.jis] where !types.contains(x) { types.append(x) }
        var cols: [String] = []
        for ty in types {
            let s = KeyTranslate.characters(layout: layout, usage: UInt8(usage), modifiers: o.modifiers, keyboardType: ty)
            if usage < 0x68 || usage > 0x73 { o.typed[ty, default: ""] += s ?? "" }
            cols.append("\(KeyTranslate.typeName(ty))=\(KeyTranslate.show(s))")
        }
        let vk = KeyTranslate.virtualKey(usage: UInt8(usage), keyboardType: o.keyboardType).map { String(format: "0x%02X", $0) } ?? "-"
        emit(String(format: "KEY device 0x%llx down usage=0x%02X mods=0x%02X vk=%@ -> %@ [device type %d]  (%@)", o.id, usage, o.modifiers.rawValue, vk,
                    KeyTranslate.show(KeyTranslate.characters(layout: layout, usage: UInt8(usage), modifiers: o.modifiers, keyboardType: o.keyboardType)),
                    o.keyboardType, cols.joined(separator: " ")), at: t)
    }

    /// Acknowledge a proven seize: F13 arrived here, and the system saw no F13 meanwhile.
    private func scheduleAck(_ o: OpenedDevice, downAt: Double, upAt: Double) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard self.opened[o.id] === o else { return }
            guard self.tap?.started == true else {
                emit("ACK withheld: event tap not running, cannot prove that F13 did not reach the system")
                return
            }
            let leaked = self.tapEvents.filter { $0.time >= downAt - 0.3 && $0.keycode == 0x69 && ($0.type == .keyDown || $0.type == .keyUp) }
            let fromBLE = self.tapEvents.filter { $0.time >= downAt - 0.3 && $0.bleSender != nil }
            guard leaked.isEmpty, fromBLE.isEmpty else {
                emit("ACK withheld: the system saw F13/BLE key events (\(leaked.count) F13, \(fromBLE.count) from BLE) — seize NOT proven")
                return
            }
            let byte = Monitor.seizeToken
            // With report IDs, the buffer starts with the ID (MaxOutputReportSize is 2 here).
            var buffer: [UInt8] = [ReportID.keyboard, byte]
            let r = IOHIDDeviceSetReport(o.device, kIOHIDReportTypeOutput, CFIndex(ReportID.keyboard), &buffer, buffer.count)
            o.acks += 1
            emit(String(format: "ACK seize proven for device 0x%llx (F13 down+up received here, %.0f ms held, no system F13 event); wrote seize token 0x%02X to the LED output report -> %@",
                        o.id, (upAt - downAt) * 1000, byte, ioReturnName(r)))
        }
    }

    // MARK: - System side

    private func tapEvent(_ e: SystemTap.Event) {
        if e.type == .tapDisabledByTimeout || e.type == .tapDisabledByUserInput {
            emit("SYSKEY tap was disabled by the system (\(e.type.rawValue)); re-enabled")
            return
        }
        tapEvents.append(e)
        if tapEvents.count > 2000 { tapEvents.removeFirst(1000) }
        let kind = e.type == .keyDown ? "down" : e.type == .keyUp ? "up" : "flags"
        let src = e.bleSender.map { String(format: "BLE(0x%llx via field %d)", $0.id, $0.field) } ?? "other"
        tapCounts["\(kind) src=\(e.bleSender == nil ? "other" : "BLE")", default: 0] += 1
        let safeKeycodes: Set<Int> = [0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A, 0x39]
        let showKey = e.type == .flagsChanged || safeKeycodes.contains(e.keycode) || e.bleSender != nil
        let kc = showKey ? String(format: "0x%02X%@", e.keycode, e.keycode == 0x69 ? " (F13)" : "") : "(hidden: not from BLE)"
        emit(String(format: "SYSKEY %@ kc=%@ kbdType=%d (%@) flags=0x%llx src=%@", kind, kc, e.keyboardType, KeyTranslate.typeName(e.keyboardType), e.flags, src), at: e.time)
    }

    private func sampleCursor() {
        let p = CGEvent(source: nil)?.location ?? .zero
        let d = lastCursor.map { CGPoint(x: p.x - $0.x, y: p.y - $0.y) } ?? .zero
        emit(String(format: "CURSOR x=%.1f y=%.1f dx=%+.1f dy=%+.1f %@", p.x, p.y, d.x, d.y, capsText()))
        lastCursor = p
    }

    /// System-wide view (all keyboards): modifier flags and F13. Does not identify the source device.
    private func pollSystemKeys() {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let relevant = flags.intersection([.maskAlphaShift, .maskShift, .maskControl, .maskAlternate, .maskCommand])
        if relevant != lastFlags {
            emit("SYS flags capsLock=\(relevant.contains(.maskAlphaShift) ? 1 : 0) shift=\(relevant.contains(.maskShift) ? 1 : 0) ctrl=\(relevant.contains(.maskControl) ? 1 : 0) alt=\(relevant.contains(.maskAlternate) ? 1 : 0) cmd=\(relevant.contains(.maskCommand) ? 1 : 0)")
            lastFlags = relevant
        }
        let f13 = CGEventSource.keyState(.combinedSessionState, key: 0x69) // kVK_F13
        if f13 != lastF13 {
            emit("SYS F13 down=\(f13 ? 1 : 0)")
            lastF13 = f13
        }
    }

    private func capsText() -> String {
        "capsLock=\(CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift) ? "ON" : "off")"
    }

    private func summarize() {
        emit("SUMMARY BLE HID devices present at end: \(known.count); unchanged element values not printed: \(staleValues)")
        for key in valueCounts.keys.sorted() {
            emit("SUMMARY values \(key): \(valueCounts[key]!)")
        }
        for key in tapCounts.keys.sorted() {
            emit("SUMMARY system key events \(key): \(tapCounts[key]!)")
        }
        // Gaps of 1 s or more separate bursts and are not part of the rate estimate.
        let gaps = zip(xTimes.dropFirst(), xTimes).map { ($0 - $1) * 1000 }.filter { $0 < 1000 }.sorted()
        guard !gaps.isEmpty else { return }
        emit(String(format: "SUMMARY non-zero X values=%d inter-arrival ms (within bursts): min=%.1f median=%.1f max=%.1f",
                    xTimes.count, gaps.first!, gaps[gaps.count / 2], gaps.last!))
    }
}
