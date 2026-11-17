import Foundation
import CoreBluetooth
import UIKit

// M0 probe: HID over GATT peripheral per design §5/§6. GATT is built once, every service is added
// exactly once, advertising starts only after all didAdd callbacks, and nothing is removed afterwards.

enum UUIDs {
    // CBUUID is not Sendable: computed properties instead of stored constants.
    static func sig(_ hex4: String) -> CBUUID { CBUUID(string: "0000\(hex4)-0000-1000-8000-00805F9B34FB") }
    static var hid: CBUUID { sig("1812") }
    static var deviceInfo: CBUUID { sig("180A") }
    static var battery: CBUUID { sig("180F") }
    static var advertisedHID: CBUUID { CBUUID(string: "1812") }   // 16-bit form in the advertisement only
}

/// What a characteristic is, resolved by object identity (layout A has four 2A4D, layout B two 1812).
enum Role {
    case hidInformation(service: Int)
    case reportMap(service: Int)
    case controlPoint(service: Int)
    case protocolMode(service: Int)
    case report(slot: Int)
    case manufacturer, pnpID, batteryLevel

    var shortUUID: String {
        switch self {
        case .hidInformation: "2A4A"
        case .reportMap: "2A4B"
        case .controlPoint: "2A4C"
        case .protocolMode: "2A4E"
        case .report: "2A4D"
        case .manufacturer: "2A29"
        case .pnpID: "2A50"
        case .batteryLevel: "2A19"
        }
    }
}

struct ReportSlot {
    let spec: ReportSpec
    let service: Int
    let characteristic: CBMutableCharacteristic
    var value: Data
    var subscribers: [UUID: CBCentral] = [:]

    var label: String {
        "report(id=\(spec.reportID),\(spec.type == 1 ? "input" : "output"),\(spec.kind.rawValue)) svc#\(service)"
    }
}

@MainActor
final class Peripheral: NSObject, ObservableObject {
    @Published var lines: [String] = []
    @Published var header = ""

    let layout: Layout
    let repeatSeconds: Double
    let scriptName: String?          // nil = default script; "big" = pointer-only rectangle
    let excludeCentral: UUID?        // input reports are never sent to this central
    private var manager: CBPeripheralManager!
    private var serviceSpecs: [HIDServiceSpec] = []
    private var roles: [ObjectIdentifier: Role] = [:]
    private var slots: [ReportSlot] = []
    private var protocolModes: [UInt8] = []
    private var batteryChar: CBMutableCharacteristic?
    private var started = false
    private var observers: [NSObjectProtocol] = []
    private var logFile: FileHandle?
    private let t0 = Date()

    private var pendingAdd: (service: CBMutableService, cont: CheckedContinuation<Error?, Never>)?
    private var pendingAdvertising: CheckedContinuation<Error?, Never>?
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []
    private var stateWaiter: CheckedContinuation<Void, Never>?

    // Test script scheduling: one scheduler, a script is never interrupted once started.
    private var lastSubscribe: Date?
    private var lastScriptStart: Date?
    private var lastScriptEnd: Date?
    private var schedulerRunning = false
    private var scriptCount = 0
    private var queueFullCount = 0

    override init() {
        let args = ProcessInfo.processInfo.arguments
        func value(_ name: String) -> String? {
            args.first { $0.hasPrefix("--\(name)=") }.map { String($0.dropFirst(name.count + 3)) }
        }
        layout = Layout(rawValue: (value("layout") ?? "A").uppercased()) ?? .A
        repeatSeconds = value("repeat").flatMap(Double.init) ?? 30
        scriptName = value("script")?.lowercased()
        excludeCentral = value("exclude-central").flatMap { UUID(uuidString: $0) }
        super.init()
        setvbuf(stdout, nil, _IONBF, 0)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("m0.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        logFile = try? FileHandle(forWritingTo: url)
        header = "HIDPad-M0 layout \(layout.rawValue) repeat \(Int(repeatSeconds)) s"
    }

    // MARK: Logging

    func log(_ s: String) {
        let now = Date()
        var secs = time_t(now.timeIntervalSince1970)
        var parts = tm()
        localtime_r(&secs, &parts)
        let ms = Int(now.timeIntervalSince1970.truncatingRemainder(dividingBy: 1) * 1000)
        let line = String(format: "[M0 %02d:%02d:%02d.%03d +%7.3f] ", parts.tm_hour, parts.tm_min, parts.tm_sec, ms,
                          now.timeIntervalSince(t0)) + s
        print(line)
        lines.append(line)
        if lines.count > 1500 { lines.removeFirst(lines.count - 1500) }
        if let d = (line + "\n").data(using: .utf8) { try? logFile?.write(contentsOf: d) }
    }

    private func appState() -> String {
        switch UIApplication.shared.applicationState {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "raw"
        }
    }

    // MARK: Startup

    func start() {
        guard !started else { return }
        started = true
        UIApplication.shared.isIdleTimerDisabled = true
        UIDevice.current.isBatteryMonitoringEnabled = true
        installLifecycleLogging()
        log("START layout=\(layout.rawValue) repeat=\(repeatSeconds)s script=\(scriptName ?? "default") excludeCentral=\(excludeCentral?.uuidString ?? "none") iOS=\(UIDevice.current.systemVersion) args=\(ProcessInfo.processInfo.arguments.dropFirst()) auth=\(authName(CBManager.authorization)) idleTimerDisabled=\(UIApplication.shared.isIdleTimerDisabled)")
        Task { await run() }
        Task { await heartbeat() }
    }

    private func installLifecycleLogging() {
        let names: [(Notification.Name, String)] = [
            (UIApplication.willResignActiveNotification, "willResignActive"),
            (UIApplication.didEnterBackgroundNotification, "didEnterBackground"),
            (UIApplication.willEnterForegroundNotification, "willEnterForeground"),
            (UIApplication.didBecomeActiveNotification, "didBecomeActive"),
            (UIApplication.willTerminateNotification, "willTerminate"),
            (UIApplication.didReceiveMemoryWarningNotification, "didReceiveMemoryWarning"),
            (UIApplication.protectedDataWillBecomeUnavailableNotification, "protectedDataWillBecomeUnavailable"),
            (UIApplication.protectedDataDidBecomeAvailableNotification, "protectedDataDidBecomeAvailable"),
        ]
        for (name, label) in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.log("LIFECYCLE \(label) appState=\(self.appState()) isAdvertising=\(self.manager?.isAdvertising ?? false)")
                }
            })
        }
    }

    private func heartbeat() async {
        var tick = 0
        while true {
            try? await Task.sleep(for: .seconds(10))
            tick += 1
            let perSlot = slots.enumerated().filter { $0.element.spec.type == 1 }.map { i, s in
                "\(i)(id=\(s.spec.reportID)):[\(s.subscribers.keys.map { $0.uuidString }.sorted().joined(separator: ","))]"
            }.joined(separator: " ")
            log("SUBS \(perSlot)")
            guard tick % 3 == 0 else { continue }
            let subs = slots.enumerated().map { "\($0.offset):\($0.element.subscribers.count)" }.joined(separator: ",")
            log("HEARTBEAT appState=\(appState()) state=\(stateName(manager?.state ?? .unknown)) isAdvertising=\(manager?.isAdvertising ?? false) subscribers[slot:n]=\(subs) scripts=\(scriptCount) battery=\(Int(UIDevice.current.batteryLevel * 100))%")
        }
    }

    private func run() async {
        manager = CBPeripheralManager(delegate: self, queue: .main, options: nil)
        log("MANAGER created state=\(stateName(manager.state))")
        if manager.state != .poweredOn {
            await withCheckedContinuation { stateWaiter = $0 }
        }
        guard manager.state == .poweredOn else {
            log("ABORT manager state=\(stateName(manager.state)) auth=\(authName(CBManager.authorization)) — needs Bluetooth permission for this app on the phone")
            return
        }

        var services: [(String, CBMutableService)] = [("deviceInfo", makeDeviceInfo()), ("battery", makeBattery())]
        serviceSpecs = Descriptors.services(for: layout)
        for (i, spec) in serviceSpecs.enumerated() {
            services.append((spec.name, makeHID(spec, index: i)))
            log("REPORT_MAP \(spec.name) (\(spec.reportMap.count) bytes): \(hexString(spec.reportMap))")
        }
        for (label, service) in services {
            let chars = (service.characteristics ?? []).map { c -> String in
                let role = roles[ObjectIdentifier(c)].map { $0.shortUUID } ?? "?"
                return role
            }
            log("ADD \(label) uuid=\(service.uuid.uuidString) chars=\(chars)")
            var exception: String?
            let error: Error? = await withCheckedContinuation { cont in
                pendingAdd = (service, cont)
                exception = HPTryCatch { self.manager.add(service) }
                if exception != nil {
                    pendingAdd = nil
                    cont.resume(returning: nil)
                }
            }
            if let exception {
                log("ADD_FAILED \(label) EXCEPTION \(exception) — stopping; this layout is rejected by iOS")
                return
            }
            if let error {
                log("ADD_FAILED \(label) error=\(error) — stopping; this layout is rejected by iOS")
                return
            }
            log("ADD_OK \(label)")
        }

        let ad: [String: Any] = [CBAdvertisementDataServiceUUIDsKey: [UUIDs.advertisedHID],
                                 CBAdvertisementDataLocalNameKey: "HIDPad-M0"]
        log("ADVERTISE start uuids=[1812] name=HIDPad-M0")
        var advException: String?
        let advError: Error? = await withCheckedContinuation { cont in
            pendingAdvertising = cont
            advException = HPTryCatch { self.manager.startAdvertising(ad) }
            if advException != nil {
                pendingAdvertising = nil
                cont.resume(returning: nil)
            }
        }
        log("ADVERTISE result=\(advException.map { "EXCEPTION \($0)" } ?? advError.map { "error \($0)" } ?? "OK") isAdvertising=\(manager.isAdvertising)")
        log("READY layout=\(layout.rawValue) slots=\(slots.enumerated().map { "\($0.offset)=\($0.element.label)" })")
    }

    // MARK: GATT construction

    private func characteristic(_ uuid: String, _ props: CBCharacteristicProperties, _ perms: CBAttributePermissions,
                                role: Role) -> CBMutableCharacteristic {
        let c = CBMutableCharacteristic(type: UUIDs.sig(uuid), properties: props, value: nil, permissions: perms)
        roles[ObjectIdentifier(c)] = role
        return c
    }

    private func makeDeviceInfo() -> CBMutableService {
        let s = CBMutableService(type: UUIDs.deviceInfo, primary: true)
        s.characteristics = [
            characteristic("2A29", [.read], [.readable], role: .manufacturer),
            characteristic("2A50", [.read], [.readable], role: .pnpID),
        ]
        return s
    }

    private func makeBattery() -> CBMutableService {
        let s = CBMutableService(type: UUIDs.battery, primary: true)
        let level = characteristic("2A19", [.read, .notify], [.readable], role: .batteryLevel)
        batteryChar = level
        s.characteristics = [level]
        return s
    }

    private func makeHID(_ spec: HIDServiceSpec, index: Int) -> CBMutableService {
        let R: CBAttributePermissions = .readEncryptionRequired
        let W: CBAttributePermissions = .writeEncryptionRequired
        let s = CBMutableService(type: UUIDs.hid, primary: true)
        protocolModes.append(0x01)
        var chars: [CBMutableCharacteristic] = [
            characteristic("2A4A", [.read], R, role: .hidInformation(service: index)),
            characteristic("2A4B", [.read], R, role: .reportMap(service: index)),
            characteristic("2A4C", [.writeWithoutResponse], W, role: .controlPoint(service: index)),
            characteristic("2A4E", [.read, .writeWithoutResponse], [R, W], role: .protocolMode(service: index)),
        ]
        for report in spec.reports {
            let props: CBCharacteristicProperties = report.type == 1 ? [.read, .notify] : [.read, .write, .writeWithoutResponse]
            let perms: CBAttributePermissions = report.type == 1 ? R : [R, W]
            let c = characteristic("2A4D", props, perms, role: .report(slot: slots.count))
            c.descriptors = [CBMutableDescriptor(type: UUIDs.sig("2908"), value: Data([report.reportID, report.type]))]
            slots.append(ReportSlot(spec: report, service: index, characteristic: c, value: Data(count: report.length)))
            chars.append(c)
        }
        s.characteristics = chars
        return s
    }

    private func roleText(_ c: CBCharacteristic) -> (Role?, String) {
        guard let role = roles[ObjectIdentifier(c)] else { return (nil, "UNKNOWN(\(c.uuid.uuidString))") }
        switch role {
        case .report(let i): return (role, "2A4D \(slots[i].label)")
        case .hidInformation(let s), .reportMap(let s), .controlPoint(let s), .protocolMode(let s):
            return (role, "\(role.shortUUID) svc#\(s)")
        default: return (role, role.shortUUID)
        }
    }

    private func value(for role: Role) -> Data? {
        switch role {
        case .hidInformation: Data(Descriptors.hidInformation)
        case .reportMap(let s): Data(serviceSpecs[s].reportMap)
        case .protocolMode(let s): Data([protocolModes[s]])
        case .report(let i): slots[i].value
        case .manufacturer: Data("HIDPad-M0 probe".utf8)
        case .pnpID: Data(Descriptors.pnpID)
        case .batteryLevel: Data([UInt8(max(0, min(100, Int(UIDevice.current.batteryLevel * 100))))])
        case .controlPoint: nil
        }
    }

    // MARK: Sending

    /// Sends one input report to all subscribers of `slot`; waits for isReady when the queue is full.
    /// Subscribed centrals of `slot` minus --exclude-central. nil = all subscribers (no exclusion configured).
    private func targets(_ slot: Int) -> [CBCentral]? {
        guard let ex = excludeCentral else { return nil }
        return slots[slot].subscribers.filter { $0.key != ex }.map { $0.value }
    }

    private func hasTarget(_ slot: Int) -> Bool {
        targets(slot).map { !$0.isEmpty } ?? !slots[slot].subscribers.isEmpty
    }

    @discardableResult
    private func send(_ slot: Int, _ bytes: [UInt8], note: String) async -> Bool {
        let data = Data(bytes)
        slots[slot].value = data
        var attempts = 0
        while true {
            let to = targets(slot)
            if let to, to.isEmpty {
                log("SCRIPT skipped: no target central (\(slots[slot].label) \(note))")
                return false
            }
            var queued = false
            let ch = slots[slot].characteristic
            if let exc = HPTryCatch({ queued = self.manager.updateValue(data, for: ch, onSubscribedCentrals: to) }) {
                log("SEND EXCEPTION \(exc) \(slots[slot].label)")
                return false
            }
            if queued {
                let toText = to.map { " to=\($0.map { $0.identifier.uuidString })" } ?? ""
                log("SEND \(slots[slot].label) [\(hexString(data))] \(note)\(toText)" + (attempts > 0 ? " (after \(attempts) wait(s) for isReady)" : ""))
                return true
            }
            attempts += 1
            queueFullCount += 1
            log("SEND_QUEUE_FULL \(slots[slot].label) [\(hexString(data))] — waiting for peripheralManagerIsReady")
            await withCheckedContinuation { readyWaiters.append($0) }
        }
    }

    // MARK: Test script (design §11.3 safety rules: only these inputs, all net-zero / even Caps Lock)

    private func slot(_ kind: ReportKind) -> Int? {
        slots.firstIndex { $0.spec.kind == kind && $0.spec.type == 1 }
    }

    private func ensureScheduler() {
        guard !schedulerRunning else { return }
        schedulerRunning = true
        Task { await schedulerLoop() }
    }

    private func schedulerLoop() async {
        while true {
            try? await Task.sleep(for: .milliseconds(100))
            guard let sub = lastSubscribe, Date().timeIntervalSince(sub) >= 2 else { continue }
            guard slots.contains(where: { $0.spec.type == 1 && !$0.subscribers.isEmpty }) else { continue }
            let newSubscribes = lastScriptStart.map { sub > $0 } ?? true
            let repeatDue = repeatSeconds > 0 && (lastScriptEnd.map { Date().timeIntervalSince($0) >= repeatSeconds } ?? true)
            guard newSubscribes || repeatDue else { continue }
            lastScriptStart = Date()
            await runScript()
            lastScriptEnd = Date()
        }
    }

    private func pause(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }

    private func runScript() async {
        scriptCount += 1
        let n = scriptCount
        if scriptName == "big" { await runBigScript(n); return }
        log("SCRIPT #\(n) begin")
        if let m = slot(.mouse), !slots[m].subscribers.isEmpty {
            for i in 1...10 { await send(m, mouseReport(dx: 10), note: "pointer +10 (\(i)/10)"); await pause(100) }
            for i in 1...10 { await send(m, mouseReport(dx: -10), note: "pointer -10 (\(i)/10)"); await pause(100) }
            await pause(400)
            await send(m, mouseReport(wheel: 1), note: "wheel +1")
            await pause(300)
            await send(m, mouseReport(wheel: -1), note: "wheel -1")
            await pause(500)
        } else {
            log("SCRIPT #\(n) mouse report not subscribed; pointer/wheel steps skipped")
        }
        if let k = slot(.keyboard), !slots[k].subscribers.isEmpty {
            await send(k, keyboardReport(keys: [0x68]), note: "F13 down")
            await pause(300)
            await send(k, keyboardReport(), note: "F13 up")
            await pause(500)
            await send(k, keyboardReport(modifiers: 0x02), note: "LeftShift down")
            await pause(500)
            await send(k, keyboardReport(), note: "LeftShift up")
            await pause(500)
            for press in 1...2 {
                await send(k, keyboardReport(keys: [0x39]), note: "CapsLock down (\(press)/2)")
                await pause(300)
                await send(k, keyboardReport(), note: "CapsLock up (\(press)/2)")
                if press == 1 { await pause(500) }
            }
        } else {
            log("SCRIPT #\(n) keyboard report not subscribed; key steps skipped")
        }
        log("SCRIPT #\(n) end")
    }

    /// --script=big: pointer only, rectangle right 400, down 300, left 400, up 300 (net zero), 20 units per report, ~30 ms apart.
    private func runBigScript(_ n: Int) async {
        guard let m = slot(.mouse) else { log("SCRIPT #\(n) big: no mouse input report"); return }
        guard hasTarget(m) else { log("SCRIPT skipped: no target central (#\(n) big)"); return }
        let tgt = targets(m).map { $0.map { $0.identifier.uuidString } } ?? Array(slots[m].subscribers.keys.map { $0.uuidString })
        log("SCRIPT #\(n) big begin targets=\(tgt)")
        let qf0 = queueFullCount
        var sent = 0
        let legs: [(Int16, Int16, Int, String)] = [(20, 0, 20, "right"), (0, 20, 15, "down"), (-20, 0, 20, "left"), (0, -20, 15, "up")]
        outer: for (dx, dy, count, name) in legs {
            for i in 1...count {
                guard await send(m, mouseReport(dx: dx, dy: dy), note: "big \(name) (\(i)/\(count))") else {
                    log("SCRIPT #\(n) big aborted at \(name) \(i)/\(count)")
                    break outer
                }
                sent += 1
                await pause(30)
            }
        }
        log("SCRIPT #\(n) big end sent=\(sent)/70 updateValueFalse=\(queueFullCount - qf0)")
    }

    private func mouseReport(dx: Int16 = 0, dy: Int16 = 0, wheel: Int8 = 0) -> [UInt8] {
        let x = UInt16(bitPattern: dx), y = UInt16(bitPattern: dy)
        return [0x00, UInt8(x & 0xFF), UInt8(x >> 8), UInt8(y & 0xFF), UInt8(y >> 8), UInt8(bitPattern: wheel), 0x00]
    }

    private func keyboardReport(modifiers: UInt8 = 0, keys: [UInt8] = []) -> [UInt8] {
        var r: [UInt8] = [modifiers, 0x00, 0, 0, 0, 0, 0, 0]
        for (i, k) in keys.prefix(6).enumerated() { r[2 + i] = k }
        return r
    }
}

// MARK: - Delegate (callbacks arrive on the main queue)

extension Peripheral: @MainActor CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        log("STATE \(stateName(peripheral.state)) auth=\(authName(CBManager.authorization))")
        let settled = peripheral.state == .poweredOn || peripheral.state == .unauthorized
            || peripheral.state == .unsupported || peripheral.state == .poweredOff
        if settled, let w = stateWaiter {
            stateWaiter = nil
            w.resume()
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        log("DID_ADD uuid=\(service.uuid.uuidString) chars=\(service.characteristics?.count ?? 0) error=\(error.map { "\($0)" } ?? "none")")
        if let p = pendingAdd, p.service === service {
            pendingAdd = nil
            p.cont.resume(returning: error)
        } else {
            log("DID_ADD unexpected (not the pending service)")
        }
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        log("DID_START_ADVERTISING error=\(error.map { "\($0)" } ?? "none")")
        if let c = pendingAdvertising {
            pendingAdvertising = nil
            c.resume(returning: error)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        let (role, text) = roleText(request.characteristic)
        guard let role, let v = value(for: role) else {
            log("READ \(text) central=\(request.central.identifier) offset=\(request.offset) -> readNotPermitted")
            _ = HPTryCatch { peripheral.respond(to: request, withResult: .readNotPermitted) }
            return
        }
        guard request.offset <= v.count else {
            log("READ \(text) central=\(request.central.identifier) offset=\(request.offset) -> invalidOffset")
            _ = HPTryCatch { peripheral.respond(to: request, withResult: .invalidOffset) }
            return
        }
        let part = v.subdata(in: request.offset..<v.count)
        request.value = part
        log("READ \(text) central=\(request.central.identifier) offset=\(request.offset) -> \(part.count)B [\(hexString(part.prefix(16)))\(part.count > 16 ? " …" : "")]")
        if let exc = HPTryCatch({ peripheral.respond(to: request, withResult: .success) }) {
            log("READ respond EXCEPTION \(exc)")
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for r in requests {
            let (role, text) = roleText(r.characteristic)
            let v = r.value ?? Data()
            var meaning = ""
            switch role {
            case .protocolMode(let s)?:
                if let b = v.first { protocolModes[s] = b }
                meaning = v.first == 0 ? "(Boot Protocol)" : v.first == 1 ? "(Report Protocol)" : ""
            case .controlPoint?:
                meaning = v.first == 0 ? "(Suspend)" : v.first == 1 ? "(Exit Suspend)" : ""
            case .report(let i)?:
                slots[i].value = v
                if slots[i].spec.kind == .led, let b = v.first {
                    meaning = "(LED NumLock=\(b & 1) CapsLock=\((b >> 1) & 1) ScrollLock=\((b >> 2) & 1) Compose=\((b >> 3) & 1) Kana=\((b >> 4) & 1))"
                }
            default: break
            }
            log("WRITE \(text) central=\(r.central.identifier) offset=\(r.offset) value=[\(hexString(v))] \(meaning)")
        }
        // Answer once for the whole batch. For write-without-response there is nothing to answer; guard the call.
        if let first = requests.first, let exc = HPTryCatch({ peripheral.respond(to: first, withResult: .success) }) {
            log("WRITE respond EXCEPTION \(exc)")
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        let (role, text) = roleText(characteristic)
        log("SUBSCRIBE \(text) central=\(central.identifier) maxUpdate=\(central.maximumUpdateValueLength)")
        guard case .report(let i)? = role else { return }
        slots[i].subscribers[central.identifier] = central
        if let exc = HPTryCatch({ peripheral.setDesiredConnectionLatency(.low, for: central) }) {
            log("LATENCY EXCEPTION \(exc)")
        }
        let zero = Data(count: slots[i].spec.length)
        slots[i].value = zero
        var queued = false
        let ch = slots[i].characteristic
        _ = HPTryCatch { queued = peripheral.updateValue(zero, for: ch, onSubscribedCentrals: [central]) }
        log("SEND \(slots[i].label) [\(hexString(zero))] baseline to \(central.identifier) queued=\(queued)")
        lastSubscribe = Date()
        ensureScheduler()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        let (role, text) = roleText(characteristic)
        log("UNSUBSCRIBE \(text) central=\(central.identifier)")
        if case .report(let i)? = role { slots[i].subscribers[central.identifier] = nil }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        log("IS_READY_TO_UPDATE_SUBSCRIBERS waiters=\(readyWaiters.count)")
        let waiters = readyWaiters
        readyWaiters = []
        for w in waiters { w.resume() }
    }
}

func stateName(_ s: CBManagerState) -> String {
    switch s {
    case .unknown: "unknown"
    case .resetting: "resetting"
    case .unsupported: "unsupported"
    case .unauthorized: "unauthorized"
    case .poweredOff: "poweredOff"
    case .poweredOn: "poweredOn"
    @unknown default: "raw(\(s.rawValue))"
    }
}

func authName(_ a: CBManagerAuthorization) -> String {
    switch a {
    case .notDetermined: "notDetermined"
    case .restricted: "restricted"
    case .denied: "denied"
    case .allowedAlways: "allowedAlways"
    @unknown default: "raw(\(a.rawValue))"
    }
}
