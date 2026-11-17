import Foundation
import CoreBluetooth
import UIKit
import Observation
import HIDCore

// HID over GATT peripheral (design §5, §7.3, §7.4, §8.2).
//
// - GATT comes from a `GATTLayout` value (plan A by default); nothing here depends on the plan.
// - Every service is added exactly once per power-on, one at a time; advertising starts only
//   after the last didAdd. Nothing is removed afterwards.
// - Characteristic values are never static: reads are answered in didReceiveRead.
// - Input reports go through one `ReportQueue` and only to the active host.
// - CoreBluetooth can raise Objective-C exceptions; calls are wrapped in `HPTryCatch`.

/// A connected central, as far as a peripheral can tell (it subscribed to something).
struct HostInfo: Identifiable, Hashable {
    let id: UUID
    var inputs: Set<ReportKind> = []
    var battery = false
    var maximumUpdateValueLength = 0
    /// When this central last subscribed to the mouse input report.
    var lastMouseSubscribe: Date?
    /// When this central last subscribed to the keyboard input report.
    var lastKeyboardSubscribe: Date?

    var subscriptionText: String {
        var parts = ReportKind.allCases.filter { inputs.contains($0) }.map(\.rawValue)
        if battery { parts.append("battery") }
        return parts.isEmpty ? "-" : parts.joined(separator: ",")
    }
}

/// Counters of what was handed to CoreBluetooth. Snapshots are subtracted for per-phase logs.
struct SendStats: Sendable {
    var mouseReports = 0, sumX = 0, sumY = 0, sumWheel = 0, sumPan = 0
    var nonZeroX = 0, wheelReports = 0, mouseWithButtons = 0
    var keyboardReports = 0, consumerReports = 0
    var baselines = 0
    /// updateValue returned false (report pushed back, sending paused).
    var queueFull = 0
    var readyCallbacks = 0
    /// Reports dropped because no active host was subscribed to their kind.
    var dropped = 0
    /// Times the queue head was held by key pacing (ReportPacing).
    var pacingHolds = 0
    var exceptions = 0
    var longestBlockMs = 0.0

    static func - (a: SendStats, b: SendStats) -> SendStats {
        var d = SendStats()
        d.mouseReports = a.mouseReports - b.mouseReports
        d.sumX = a.sumX - b.sumX; d.sumY = a.sumY - b.sumY
        d.sumWheel = a.sumWheel - b.sumWheel; d.sumPan = a.sumPan - b.sumPan
        d.nonZeroX = a.nonZeroX - b.nonZeroX; d.wheelReports = a.wheelReports - b.wheelReports
        d.mouseWithButtons = a.mouseWithButtons - b.mouseWithButtons
        d.keyboardReports = a.keyboardReports - b.keyboardReports
        d.consumerReports = a.consumerReports - b.consumerReports
        d.baselines = a.baselines - b.baselines
        d.queueFull = a.queueFull - b.queueFull
        d.readyCallbacks = a.readyCallbacks - b.readyCallbacks
        d.dropped = a.dropped - b.dropped
        d.pacingHolds = a.pacingHolds - b.pacingHolds
        d.exceptions = a.exceptions - b.exceptions
        d.longestBlockMs = a.longestBlockMs   // not a counter: caller resets it per phase
        return d
    }

    var text: String {
        "mouseReports=\(mouseReports) (nonZeroX=\(nonZeroX) wheel=\(wheelReports) withButtons=\(mouseWithButtons)) "
            + "sumX=\(sumX) sumY=\(sumY) sumWheel=\(sumWheel) sumPan=\(sumPan) keyboard=\(keyboardReports) consumer=\(consumerReports) "
            + "updateValueFalse=\(queueFull) isReady=\(readyCallbacks) longestBlock=\(String(format: "%.1f", longestBlockMs))ms "
            + "pacingHolds=\(pacingHolds) dropped=\(dropped) exceptions=\(exceptions)"
    }
}

@MainActor
@Observable
final class BLEPeripheral: NSObject {
    // MARK: Observable state (changes only on events, never per report)

    private(set) var state: CBManagerState = .unknown
    private(set) var authorization: CBManagerAuthorization = CBManager.authorization
    private(set) var servicesReady = false
    private(set) var isAdvertising = false
    private(set) var setupProblem: String?
    /// Centrals with at least one subscription, in order of first subscription.
    private(set) var hosts: [HostInfo] = []
    private(set) var activeHostID: UUID?
    /// A host that connected while another one stayed active (shown briefly; cleared after 5 s).
    private(set) var newcomerNotice: UUID?
    private(set) var leds: KeyboardLEDs = []
    /// Number of keyboard LED output writes received (any central), and the last one.
    @ObservationIgnored private(set) var ledWriteCount = 0
    @ObservationIgnored private(set) var lastLEDWrite: (central: UUID, value: KeyboardLEDs, at: Date)?

    // MARK: Hooks

    /// Called before the active host changes, while reports still go to the old one, so the
    /// input side can release held buttons. The queue is cleared right after.
    @ObservationIgnored var willChangeActiveHost: (() -> Void)?
    /// Called right after the active host changed (to apply that host's profile).
    @ObservationIgnored var didChangeActiveHost: ((UUID?) -> Void)?
    /// Called when a central subscribes to the mouse input report.
    @ObservationIgnored var didSubscribeMouse: ((UUID) -> Void)?
    /// Called when a central subscribes to any input report or the battery (a host appeared).
    @ObservationIgnored var didSeeHost: ((UUID) -> Void)?
    /// Called when a central writes the keyboard LED output report.
    @ObservationIgnored var didWriteLEDs: ((UUID, KeyboardLEDs) -> Void)?

    // MARK: Private

    @ObservationIgnored let layout: GATTLayout
    #if DEBUG
    /// When set, automatic selection only ever picks this central (`--active-central`, Debug
    /// builds only; set before `start()`).
    @ObservationIgnored var pinnedCentral: UUID?
    #else
    var pinnedCentral: UUID? { nil }
    #endif
    @ObservationIgnored private let localName: String
    @ObservationIgnored private let logReports: Bool
    @ObservationIgnored private var manager: CBPeripheralManager!
    @ObservationIgnored private var definitions: [ObjectIdentifier: CharacteristicDefinition] = [:]
    @ObservationIgnored private var inputCharacteristics: [ReportKind: CBMutableCharacteristic] = [:]
    @ObservationIgnored private var batteryCharacteristic: CBMutableCharacteristic?
    @ObservationIgnored private var centrals: [UUID: CBCentral] = [:]
    @ObservationIgnored private var lastInput: [ReportKind: Data] = [:]
    @ObservationIgnored private var protocolModes: [HIDServiceRole: UInt8] = [:]
    /// Last HID Control Point value per HID service (0 = Suspend, 1 = Exit Suspend). Stored only.
    @ObservationIgnored private(set) var controlPoints: [HIDServiceRole: UInt8] = [:]
    @ObservationIgnored private var pendingServices: [(label: String, service: CBMutableService)] = []
    @ObservationIgnored private var addingService: CBMutableService?
    @ObservationIgnored private var settingUp = false
    /// Keyboard and consumer reports, and mouse button transitions, are paced
    /// (ReportPacing.keys: a press lasts ≥ 35 ms, a release ≥ 15 ms). Mouse motion is not.
    @ObservationIgnored private var queue = ReportQueue(pacing: [.keyboard: .keys, .consumer: .keys, .mouse: .keys])
    /// Uptime at which a pacing wake-up is scheduled (nil: none).
    @ObservationIgnored private var wakeAt: Double?
    @ObservationIgnored private var blocked = false
    @ObservationIgnored private var blockedSince: Date?
    @ObservationIgnored private var pendingBaselines: [(central: CBCentral, characteristic: CBMutableCharacteristic, data: Data, label: String)] = []
    @ObservationIgnored private(set) var stats = SendStats()
    #if DEBUG
    /// `--clicker-probe` (Debug builds only; set before `start()`): input reports are never
    /// handed to CoreBluetooth; each one that would have been sent is logged (`WOULD_SEND`) and
    /// counted in `dryRunStats` instead. Baselines on subscription (all-zero reports) and
    /// battery notifications are unchanged.
    @ObservationIgnored var dryRun = false
    @ObservationIgnored private(set) var dryRunStats = SendStats()
    #endif
    /// The host that was active last (persisted). Preferred at launch and when the active
    /// host goes away (`HostSelection`). Set by the user's choice, and by automatic changes
    /// after the launch window (or the first one ever); never while `--active-central` pins
    /// the host. Automatic choices inside the launch window do not overwrite it, so a host that
    /// happens to connect first at launch does not displace the one used last.
    @ObservationIgnored private(set) var preferredHost: UUID? = UserDefaults.standard.string(forKey: "lastActiveHost").flatMap(UUID.init(uuidString:))
    @ObservationIgnored private var startedAt: Date?
    /// Hosts subscribing this long after start are "newcomers" that never take over.
    static let launchWindow: TimeInterval = 8

    init(layout: GATTLayout = .planA, localName: String = "HIDPad", logReports: Bool = false) {
        self.layout = layout
        self.localName = localName
        self.logReports = logReports
        super.init()
    }

    func start() {
        guard manager == nil else { return }
        startedAt = Date()
        Log.line("ACTIVE_HOST preferred (last used) = \(preferredHost?.uuidString ?? "none") pinned=\(pinnedCentral?.uuidString ?? "none")")
        UIDevice.current.isBatteryMonitoringEnabled = true
        manager = CBPeripheralManager(delegate: self, queue: .main, options: nil)
        #if DEBUG
        Log.line("MANAGER created state=\(stateName(manager.state)) auth=\(authName(CBManager.authorization)) layout=\(layout.plan)\(dryRun ? " DRY-RUN (no input report is handed to CoreBluetooth)" : "")")
        #endif
        NotificationCenter.default.addObserver(forName: UIDevice.batteryLevelDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.notifyBattery() }
        }
    }

    // MARK: - Sending (input side API)

    func send(_ actions: [PointerAction]) {
        guard !actions.isEmpty else { return }
        queue.enqueue(actions)
        drain()
    }

    func send(_ report: KeyboardReport) {
        queue.enqueue(report)
        drain()
    }

    func send(_ report: ConsumerReport) {
        queue.enqueue(report)
        drain()
    }

    /// True when nothing is waiting to be handed to CoreBluetooth.
    var isIdle: Bool { queue.isEmpty && !blocked && pendingBaselines.isEmpty }

    /// For per-phase measurements.
    func resetLongestBlock() { stats.longestBlockMs = 0 }

    var activeHost: HostInfo? { hosts.first { $0.id == activeHostID } }

    private func drain() {
        guard !blocked, manager != nil else { return }
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            guard let report = queue.next(now: now) else {
                if let due = queue.nextSendTime { scheduleWake(at: due) }
                return
            }
            if transmit(report, now: now) == .blocked { return }
        }
    }

    private enum TransmitResult { case sent, dropped, blocked }

    /// Hands one report to CoreBluetooth for the active host (or, in dry-run mode, only logs
    /// it). On `.blocked` the report has been pushed back and sending is paused.
    private func transmit(_ report: OutgoingReport, now: Double) -> TransmitResult {
        guard let manager else { return .dropped }
        let kind = report.kind
        guard let characteristic = inputCharacteristics[kind], let hostID = activeHostID,
              let central = centrals[hostID], hosts.first(where: { $0.id == hostID })?.inputs.contains(kind) == true else {
            stats.dropped += 1
            #if DEBUG
            if logReports || dryRun { Log.line("DROP \(report.logText) (no active host subscribed to \(kind.rawValue))") }
            #endif
            return .dropped
        }
        let data = Data(report.bytes)
        #if DEBUG
        if dryRun {
            queue.didSend(report, at: now)
            Self.record(report, in: &dryRunStats)
            Log.line("WOULD_SEND \(kind.rawValue) central=\(shortID(hostID)) [\(hexString(data))] \(report.logText) (dry run: not sent)")
            return .sent
        }
        #endif
        var queued = false
        if let exc = HPTryCatch({ queued = manager.updateValue(data, for: characteristic, onSubscribedCentrals: [central]) }) {
            stats.exceptions += 1
            Log.line("SEND EXCEPTION \(exc) \(report.logText)")
            return .dropped
        }
        if !queued {
            queue.pushBack(report)
            blocked = true
            blockedSince = Date()
            stats.queueFull += 1
            Log.line("SEND_QUEUE_FULL \(kind.rawValue) central=\(shortID(hostID)) pushed back [\(report.logText)] pending=\(queue.count)")
            return .blocked
        }
        queue.didSend(report, at: now)
        lastInput[kind] = data
        Self.record(report, in: &stats)
        if logReports { Log.line("SEND \(kind.rawValue) central=\(shortID(hostID)) [\(hexString(data))] \(report.logText)") }
        return .sent
    }

    /// Before the active host changes: what the input side queued for the old host (releases
    /// from `willChangeActiveHost`, e.g. the clicker's "arrow pointer" shortcut, which pacing
    /// spreads over ~85 ms) goes out now, without pacing, up to `limit` reports. Anything
    /// left is dropped, and if the old host was last sent something still pressed, it gets an
    /// all-released report of that kind, so no key or button stays down there.
    private func flushBeforeHostChange(limit: Int = 24) {
        guard manager != nil, activeHostID != nil else { return }
        var sent = 0, left = 0
        let now = ProcessInfo.processInfo.systemUptime
        while !blocked, sent < limit, let report = queue.next() {
            if transmit(report, now: now) == .sent { sent += 1 }
        }
        while queue.next() != nil { left += 1 }
        var released: [String] = []
        if !blocked {
            for kind in queue.pressedKinds.sorted(by: { $0.rawValue < $1.rawValue }) {
                let idle: OutgoingReport = switch kind {
                case .mouse: .mouse(MouseReport())
                case .keyboard: .keyboard(.empty)
                case .consumer: .consumer(.released)
                }
                if transmit(idle, now: now) == .sent { released.append(kind.rawValue) }
            }
        }
        if sent > 0 || left > 0 || !released.isEmpty || blocked {
            Log.line("HOST_CHANGE_FLUSH sent=\(sent) unpaced, dropped=\(left), released=\(released)\(blocked ? " (transport blocked: rest dropped)" : "")")
        }
    }

    /// Pacing holds the queue head; come back when it may go.
    private func scheduleWake(at due: Double) {
        if let w = wakeAt, w <= due { return }
        wakeAt = due
        stats.pacingHolds += 1
        let delay = max(0, due - ProcessInfo.processInfo.systemUptime)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.wakeAt = nil
                self.drain()
            }
        }
    }

    private static func record(_ report: OutgoingReport, in stats: inout SendStats) {
        switch report {
        case .mouse(let r):
            stats.mouseReports += 1
            stats.sumX += r.x; stats.sumY += r.y; stats.sumWheel += r.wheel; stats.sumPan += r.pan
            if r.x != 0 { stats.nonZeroX += 1 }
            if r.wheel != 0 { stats.wheelReports += 1 }
            if r.buttons != [] { stats.mouseWithButtons += 1 }
        case .keyboard: stats.keyboardReports += 1
        case .consumer: stats.consumerReports += 1
        }
    }

    // MARK: - Hosts

    /// Make `id` the host that receives input reports (nil: none). `byUser`: the user chose it
    /// (it becomes the preferred host for the next launch).
    func selectActiveHost(_ id: UUID?, reason: String, byUser: Bool = false) {
        let inWindow = startedAt.map { Date().timeIntervalSince($0) < Self.launchWindow } ?? true
        if let id, pinnedCentral == nil, byUser || preferredHost == nil || !inWindow, preferredHost != id {
            let why = byUser ? "user choice" : preferredHost == nil ? "first automatic choice" : "automatic, after the launch window"
            preferredHost = id
            UserDefaults.standard.set(id.uuidString, forKey: "lastActiveHost")
            Log.line("ACTIVE_HOST preferred host saved: \(id) (\(why))")
        }
        if id == newcomerNotice { newcomerNotice = nil }
        guard id != activeHostID else { return }
        willChangeActiveHost?()          // releases go to the old host while it is still active
        flushBeforeHostChange()
        queue.removeAll()
        let old = activeHostID
        activeHostID = id
        Log.line("ACTIVE_HOST \(old.map(shortID) ?? "none") -> \(id.map { $0.uuidString } ?? "none") (\(reason))")
        didChangeActiveHost?(id)
    }

    /// A central subscribed to the mouse report: apply `HostSelection` (never steal input from
    /// a host that is still subscribed, except for the preferred host during the launch window).
    private func mouseSubscribed(_ id: UUID) {
        let subscribed = Set(hosts.filter { $0.inputs.contains(.mouse) }.map(\.id))
        let inWindow = startedAt.map { Date().timeIntervalSince($0) < Self.launchWindow } ?? true
        let old = activeHostID
        let next = HostSelection.afterSubscribe(id, active: old, subscribed: subscribed, pinned: pinnedCentral,
                                                preferred: preferredHost, inLaunchWindow: inWindow)
        guard next == id else {
            Log.line("ACTIVE_HOST unchanged: \(id) subscribed to mouse; keeping \(old?.uuidString ?? "none") (pinned=\(pinnedCentral.map(shortID) ?? "none") preferred=\(preferredHost.map(shortID) ?? "none") launchWindow=\(inWindow))")
            if pinnedCentral == nil, old != nil { showNewcomer(id) }
            return
        }
        if old != id {
            var reason = old == nil ? "no active host"
                : !subscribed.contains(old!) ? "previous active host no longer subscribed"
                : "preferred (last used) host within the launch window"
            #if DEBUG
            if pinnedCentral != nil { reason = "pinned by --active-central" }
            #endif
            selectActiveHost(id, reason: reason)
            if let old, old != id, pinnedCentral == nil, subscribed.contains(old) { showNewcomer(old) }
        }
        didSubscribeMouse?(id)
    }

    private func showNewcomer(_ id: UUID) {
        newcomerNotice = id
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            if self?.newcomerNotice == id { self?.newcomerNotice = nil }
        }
    }

    private func updateHost(_ id: UUID, _ change: (inout HostInfo) -> Void) {
        if let i = hosts.firstIndex(where: { $0.id == id }) {
            change(&hosts[i])
            if hosts[i].inputs.isEmpty && !hosts[i].battery {
                hosts.remove(at: i)
                centrals[id] = nil
                Log.line("HOST_GONE central=\(id) (no subscriptions left)")
            }
        } else {
            var h = HostInfo(id: id)
            change(&h)
            if !h.inputs.isEmpty || h.battery {
                hosts.append(h)
                Log.line("HOST_NEW central=\(id) hosts=\(hosts.count)")
            }
        }
    }

    // MARK: - GATT construction

    private func cb(_ uuid: BluetoothUUID) -> CBUUID { CBUUID(string: uuid.rawValue) }

    private func buildServices() -> [(String, CBMutableService)] {
        definitions = [:]
        inputCharacteristics = [:]
        batteryCharacteristic = nil
        var out: [(String, CBMutableService)] = []
        for sdef in layout.services {
            let service = CBMutableService(type: cb(sdef.uuid), primary: sdef.isPrimary)
            var chars: [CBMutableCharacteristic] = []
            for cdef in sdef.characteristics {
                let c = CBMutableCharacteristic(
                    type: cb(cdef.uuid),
                    properties: CBCharacteristicProperties(rawValue: UInt(cdef.properties.rawValue)),
                    value: nil,
                    permissions: CBAttributePermissions(rawValue: UInt(cdef.permissions.rawValue)))
                if !cdef.descriptors.isEmpty {
                    c.descriptors = cdef.descriptors.map { CBMutableDescriptor(type: cb($0.uuid), value: Data($0.value)) }
                }
                definitions[ObjectIdentifier(c)] = cdef
                switch cdef.role {
                case .inputReport(let kind): inputCharacteristics[kind] = c
                case .batteryLevel: batteryCharacteristic = c
                case .protocolMode(let s): protocolModes[s] = cdef.value?.first ?? 0x01
                default: break
                }
                chars.append(c)
            }
            service.characteristics = chars
            let label = "\(sdef.role)"
            let charText = sdef.characteristics.map { roleText($0) }.joined(separator: " ")
            Log.line("SERVICE \(label) uuid=\(sdef.uuid) chars=[\(charText)]")
            if case .hid = sdef.role, let map = sdef.characteristics.first(where: { if case .reportMap = $0.role { true } else { false } })?.value {
                Log.line("REPORT_MAP \(label) \(map.count) bytes: \(hexString(map))")
            }
            out.append((label, service))
        }
        return out
    }

    private func setUp() {
        guard !settingUp, !servicesReady else { return }
        settingUp = true
        setupProblem = nil
        pendingServices = buildServices()
        addNextService()
    }

    private func addNextService() {
        guard let manager else { return }
        guard !pendingServices.isEmpty else {
            settingUp = false
            servicesReady = true
            startAdvertising()
            return
        }
        let (label, service) = pendingServices.removeFirst()
        addingService = service
        Log.line("ADD \(label)")
        if let exc = HPTryCatch({ manager.add(service) }) {
            addingService = nil
            settingUp = false
            setupProblem = "add \(label): \(exc)"
            Log.line("ADD_FAILED \(label) EXCEPTION \(exc) — not advertising")
        }
    }

    private func startAdvertising() {
        guard let manager else { return }
        // The advertisement carries the 16-bit form (as in M0); GATT uses the 128-bit form.
        let uuids = layout.advertisedServiceUUIDs.map { u in
            u.shortValue.map { CBUUID(string: String(format: "%04X", $0)) } ?? cb(u)
        }
        let ad: [String: Any] = [CBAdvertisementDataServiceUUIDsKey: uuids, CBAdvertisementDataLocalNameKey: localName]
        Log.line("ADVERTISE start uuids=\(uuids.map(\.uuidString)) name=\(localName)")
        if let exc = HPTryCatch({ manager.startAdvertising(ad) }) {
            setupProblem = "advertise: \(exc)"
            Log.line("ADVERTISE EXCEPTION \(exc)")
        }
    }

    private func clearAfterPowerLoss() {
        if servicesReady || settingUp || !hosts.isEmpty {
            Log.line("RESET GATT state (services are gone after \(stateName(state)))")
        }
        servicesReady = false
        settingUp = false
        isAdvertising = false
        pendingServices = []
        addingService = nil
        if activeHostID != nil { selectActiveHost(nil, reason: "bluetooth \(stateName(state))") }
        hosts = []
        centrals = [:]
        queue.removeAll()
        blocked = false
        pendingBaselines = []
    }

    // MARK: - Values

    private func roleText(_ d: CharacteristicDefinition) -> String {
        let short = d.uuid.shortValue.map { String(format: "%04X", $0) } ?? d.uuid.rawValue
        switch d.role {
        case .inputReport(let k): return "\(short)(in:\(k.rawValue)\(d.reportReference.map { ",id=\($0.id)" } ?? ""))"
        case .outputReport(let k): return "\(short)(out:\(k.rawValue)\(d.reportReference.map { ",id=\($0.id)" } ?? ""))"
        default: return short
        }
    }

    private func roleText(_ c: CBCharacteristic) -> String {
        definitions[ObjectIdentifier(c)].map { roleText($0) } ?? "UNKNOWN(\(c.uuid.uuidString))"
    }

    private var batteryByte: UInt8 {
        let level = UIDevice.current.batteryLevel
        guard level >= 0 else { return 100 }   // unknown (e.g. monitoring off)
        return UInt8(max(0, min(100, Int((level * 100).rounded()))))
    }

    private func readValue(_ d: CharacteristicDefinition) -> Data? {
        switch d.role {
        case .hidInformation, .reportMap, .manufacturerName, .pnpID:
            return d.value.map { Data($0) }
        case .protocolMode(let s):
            return Data([protocolModes[s] ?? 0x01])
        case .inputReport(let kind):
            return lastInput[kind] ?? Data(count: kind.inputByteCount)
        case .outputReport:
            return Data([leds.rawValue])
        case .batteryLevel:
            return Data([batteryByte])
        case .hidControlPoint:
            return nil
        }
    }

    private func notifyBattery() {
        guard let manager, let c = batteryCharacteristic else { return }
        let subs = hosts.filter(\.battery).compactMap { centrals[$0.id] }
        guard !subs.isEmpty else { return }
        var ok = false
        _ = HPTryCatch { ok = manager.updateValue(Data([self.batteryByte]), for: c, onSubscribedCentrals: subs) }
        Log.line("BATTERY notify level=\(batteryByte) to \(subs.count) central(s) queued=\(ok)")
    }

    private func sendBaseline(_ central: CBCentral, _ c: CBMutableCharacteristic, _ data: Data, label: String) {
        guard let manager else { return }
        var queued = false
        if let exc = HPTryCatch({ queued = manager.updateValue(data, for: c, onSubscribedCentrals: [central]) }) {
            Log.line("BASELINE EXCEPTION \(exc) \(label)")
            return
        }
        if queued {
            stats.baselines += 1
            Log.line("SEND \(label) [\(hexString(data))] baseline to \(central.identifier)")
        } else {
            pendingBaselines.append((central, c, data, label))
            blocked = true
            blockedSince = Date()
            stats.queueFull += 1
            Log.line("SEND_QUEUE_FULL baseline \(label) to \(central.identifier) — retry when ready")
        }
    }
}

// MARK: - Delegate (callbacks arrive on the main queue)

extension BLEPeripheral: @MainActor CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        state = peripheral.state
        authorization = CBManager.authorization
        Log.line("STATE \(stateName(peripheral.state)) auth=\(authName(CBManager.authorization))")
        if peripheral.state == .poweredOn {
            setUp()
        } else {
            clearAfterPowerLoss()
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        Log.line("DID_ADD uuid=\(service.uuid.uuidString) chars=\(service.characteristics?.count ?? 0) error=\(error.map { "\($0)" } ?? "none")")
        guard let adding = addingService, adding === service else {
            Log.line("DID_ADD unexpected (not the pending service)")
            return
        }
        addingService = nil
        if let error {
            settingUp = false
            setupProblem = "add \(service.uuid.uuidString): \(error.localizedDescription)"
            Log.line("ADD_FAILED \(service.uuid.uuidString) — not advertising")
            return
        }
        addNextService()
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        isAdvertising = peripheral.isAdvertising
        if let error { setupProblem = "advertise: \(error.localizedDescription)" }
        Log.line("DID_START_ADVERTISING error=\(error.map { "\($0)" } ?? "none") isAdvertising=\(peripheral.isAdvertising)")
        Log.line("READY services=\(layout.services.count) inputs=\(layout.reportKinds.map(\.rawValue))")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        let text = roleText(request.characteristic)
        let central = request.central.identifier
        guard let d = definitions[ObjectIdentifier(request.characteristic)], let v = readValue(d) else {
            Log.line("READ \(text) central=\(central) offset=\(request.offset) -> readNotPermitted")
            _ = HPTryCatch { peripheral.respond(to: request, withResult: .readNotPermitted) }
            return
        }
        guard request.offset <= v.count else {
            Log.line("READ \(text) central=\(central) offset=\(request.offset) -> invalidOffset")
            _ = HPTryCatch { peripheral.respond(to: request, withResult: .invalidOffset) }
            return
        }
        let part = v.subdata(in: request.offset..<v.count)
        request.value = part
        Log.line("READ \(text) central=\(central) offset=\(request.offset) -> \(part.count)B [\(hexString(part.prefix(16)))\(part.count > 16 ? " …" : "")]")
        if let exc = HPTryCatch({ peripheral.respond(to: request, withResult: .success) }) {
            Log.line("READ respond EXCEPTION \(exc)")
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for r in requests {
            let text = roleText(r.characteristic)
            let v = r.value ?? Data()
            var meaning = ""
            switch definitions[ObjectIdentifier(r.characteristic)]?.role {
            case .protocolMode(let s)?:
                if let b = v.first { protocolModes[s] = b }
                meaning = v.first == 0 ? "(Boot Protocol)" : v.first == 1 ? "(Report Protocol)" : "(?)"
            case .hidControlPoint(let s)?:
                if let b = v.first { controlPoints[s] = b }
                meaning = v.first == 0 ? "(Suspend)" : v.first == 1 ? "(Exit Suspend)" : "(?)"
            case .outputReport(.keyboard)?:
                if let l = KeyboardLEDs(outputReportValue: v) {
                    leds = l
                    ledWriteCount += 1
                    lastLEDWrite = (r.central.identifier, l, Date())
                    didWriteLEDs?(r.central.identifier, l)
                    meaning = "(LED num=\(l.contains(.numLock) ? 1 : 0) caps=\(l.contains(.capsLock) ? 1 : 0) scroll=\(l.contains(.scrollLock) ? 1 : 0) compose=\(l.contains(.compose) ? 1 : 0) kana=\(l.contains(.kana) ? 1 : 0))"
                }
            default:
                meaning = "(ignored)"
            }
            Log.line("WRITE \(text) central=\(r.central.identifier) offset=\(r.offset) value=[\(hexString(v))] \(meaning)")
        }
        // One response for the batch; for write-without-response there is nothing to answer.
        if let first = requests.first, let exc = HPTryCatch({ peripheral.respond(to: first, withResult: .success) }) {
            Log.line("WRITE respond EXCEPTION \(exc)")
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        let text = roleText(characteristic)
        let id = central.identifier
        Log.line("SUBSCRIBE \(text) central=\(id) maxUpdate=\(central.maximumUpdateValueLength)")
        guard let d = definitions[ObjectIdentifier(characteristic)], let c = characteristic as? CBMutableCharacteristic else { return }
        centrals[id] = central
        switch d.role {
        case .inputReport(let kind):
            updateHost(id) {
                $0.inputs.insert(kind)
                $0.maximumUpdateValueLength = central.maximumUpdateValueLength
                if kind == .mouse { $0.lastMouseSubscribe = Date() }
                if kind == .keyboard { $0.lastKeyboardSubscribe = Date() }
            }
            didSeeHost?(id)
            if let exc = HPTryCatch({ peripheral.setDesiredConnectionLatency(.low, for: central) }) {
                Log.line("LATENCY EXCEPTION \(exc)")
            }
            sendBaseline(central, c, Data(count: kind.inputByteCount), label: "\(kind.rawValue)")
            if kind == .mouse { mouseSubscribed(id) }
        case .batteryLevel:
            updateHost(id) { $0.battery = true }
            didSeeHost?(id)
            sendBaseline(central, c, Data([batteryByte]), label: "battery")
        default:
            break
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        let id = central.identifier
        Log.line("UNSUBSCRIBE \(roleText(characteristic)) central=\(id)")
        switch definitions[ObjectIdentifier(characteristic)]?.role {
        case .inputReport(let kind)?:
            updateHost(id) { $0.inputs.remove(kind) }
            if kind == .mouse, activeHostID == id {
                let remaining = hosts.filter { $0.inputs.contains(.mouse) && $0.id != id }
                    .sorted { ($0.lastMouseSubscribe ?? .distantPast) < ($1.lastMouseSubscribe ?? .distantPast) }
                    .map(\.id)
                let next = HostSelection.afterActiveGone(remaining: remaining, pinned: pinnedCentral, preferred: preferredHost)
                selectActiveHost(next, reason: "active host unsubscribed from mouse\(next != nil && next == preferredHost ? "; preferred host" : "")")
            }
        case .batteryLevel?:
            updateHost(id) { $0.battery = false }
        default:
            break
        }
        pendingBaselines.removeAll { $0.central.identifier == id && $0.characteristic === characteristic }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        stats.readyCallbacks += 1
        if blocked, let since = blockedSince {
            let ms = Date().timeIntervalSince(since) * 1000
            stats.longestBlockMs = max(stats.longestBlockMs, ms)
            Log.line("IS_READY after \(String(format: "%.1f", ms)) ms pending=\(queue.count) baselines=\(pendingBaselines.count)")
        }
        blocked = false
        blockedSince = nil
        let baselines = pendingBaselines
        pendingBaselines = []
        for (i, b) in baselines.enumerated() {
            sendBaseline(b.central, b.characteristic, b.data, label: b.label)
            if blocked {
                pendingBaselines += baselines.dropFirst(i + 1)
                return
            }
        }
        drain()
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
