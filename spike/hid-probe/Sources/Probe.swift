import Foundation
import CoreBluetooth
import SwiftUI
import UIKit

// MARK: - Result types

struct CBResult: Sendable {
    var status: String            // OK | ERROR | EXCEPTION | TIMEOUT | SKIPPED
    var domain: String? = nil
    var code: Int? = nil
    var desc: String? = nil
    var userInfo: String? = nil
    var exception: String? = nil
    var cbUUIDString: String? = nil   // service.uuid.uuidString as seen in didAdd
    var cbUUIDBytes: Int? = nil       // service.uuid.data.count as seen in didAdd

    var ok: Bool { status == "OK" }

    static func from(error: Error?) -> CBResult {
        guard let e = error as NSError? else { return CBResult(status: "OK") }
        return CBResult(status: "ERROR", domain: e.domain, code: e.code,
                        desc: e.localizedDescription, userInfo: "\(e.userInfo)")
    }

    var dict: [String: Any] {
        var d: [String: Any] = ["status": status]
        if let domain { d["domain"] = domain }
        if let code { d["code"] = code }
        if let desc { d["desc"] = desc }
        if let exception { d["exception"] = exception }
        if let cbUUIDString { d["uuidString"] = cbUUIDString }
        if let cbUUIDBytes { d["uuidBytes"] = cbUUIDBytes }
        return d
    }

    var line: String {
        switch status {
        case "OK": return "OK"
        case "ERROR": return "ERROR domain=\(domain ?? "-") code=\(code ?? -1) desc=\"\(desc ?? "-")\" userInfo=\(userInfo ?? "-")"
        case "EXCEPTION": return "EXCEPTION \(exception ?? "-")"
        default: return status
        }
    }
}

// MARK: - Constants

enum K {
    static let base = "-0000-1000-8000-00805F9B34FB"
    static func sig(_ hex4: String, full: Bool) -> CBUUID {
        full ? CBUUID(string: "0000\(hex4)\(base)") : CBUUID(string: hex4)
    }
    // CBUUID is non-Sendable in the iOS 27 SDK: a `static let` is a Swift 6 error, so use computed properties.
    static var customService: CBUUID { CBUUID(string: "8F3A2C10-5B7E-4D2A-9C61-0E4B7A1D3F01") }
    static var customChar: CBUUID { CBUUID(string: "8F3A2C11-5B7E-4D2A-9C61-0E4B7A1D3F01") }

    static let hidInfo = Data([0x11, 0x01, 0x00, 0x02])   // bcdHID 1.11, country 0, normally connectable
    static let reportReference = Data([0x00, 0x01])       // report ID 0, Input
    // Standard boot-style mouse: 3 buttons + X/Y/wheel, no report ID (matches Report Reference ID 0).
    static let reportMap = Data([
        0x05, 0x01,       // Usage Page (Generic Desktop)
        0x09, 0x02,       // Usage (Mouse)
        0xA1, 0x01,       // Collection (Application)
        0x09, 0x01,       //   Usage (Pointer)
        0xA1, 0x00,       //   Collection (Physical)
        0x05, 0x09,       //     Usage Page (Button)
        0x19, 0x01,       //     Usage Minimum (1)
        0x29, 0x03,       //     Usage Maximum (3)
        0x15, 0x00,       //     Logical Minimum (0)
        0x25, 0x01,       //     Logical Maximum (1)
        0x95, 0x03,       //     Report Count (3)
        0x75, 0x01,       //     Report Size (1)
        0x81, 0x02,       //     Input (Data,Var,Abs)
        0x95, 0x01,       //     Report Count (1)
        0x75, 0x05,       //     Report Size (5)
        0x81, 0x03,       //     Input (Const,Var,Abs) padding
        0x05, 0x01,       //     Usage Page (Generic Desktop)
        0x09, 0x30,       //     Usage (X)
        0x09, 0x31,       //     Usage (Y)
        0x09, 0x38,       //     Usage (Wheel)
        0x15, 0x81,       //     Logical Minimum (-127)
        0x25, 0x7F,       //     Logical Maximum (127)
        0x75, 0x08,       //     Report Size (8)
        0x95, 0x03,       //     Report Count (3)
        0x81, 0x06,       //     Input (Data,Var,Rel)
        0xC0,             //   End Collection
        0xC0,             // End Collection
    ])

    /// 4-hex-digit SIG short form if the UUID is 16-bit or the SIG base 128-bit form; else full string.
    static func short16(_ u: CBUUID) -> String {
        let d = u.data
        if d.count == 2 { return String(format: "%02X%02X", d[0], d[1]) }
        if d.count == 16, u.uuidString.uppercased().hasSuffix(base), u.uuidString.hasPrefix("0000") {
            return String(u.uuidString.dropFirst(4).prefix(4)).uppercased()
        }
        return u.uuidString
    }
}

func stateName(_ s: CBManagerState) -> String {
    switch s {
    case .unknown: return "unknown"
    case .resetting: return "resetting"
    case .unsupported: return "unsupported"
    case .unauthorized: return "unauthorized"
    case .poweredOff: return "poweredOff"
    case .poweredOn: return "poweredOn"
    @unknown default: return "raw(\(s.rawValue))"
    }
}

func authName(_ a: CBManagerAuthorization) -> String {
    switch a {
    case .notDetermined: return "notDetermined"
    case .restricted: return "restricted"
    case .denied: return "denied"
    case .allowedAlways: return "allowedAlways"
    @unknown default: return "raw(\(a.rawValue))"
    }
}

// MARK: - Probe

@MainActor
final class Probe: NSObject, ObservableObject {
    @Published var lines: [String] = []

    private var pm: CBPeripheralManager!
    private let stayMode = ProcessInfo.processInfo.arguments.contains("--stay")
    /// `--adv=short|full` (default full): which CBUUID form of 0x1812 stay mode keeps advertising. Service is always 128-bit.
    private let advForm: String = {
        let a = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--adv=") }
        return a.map { String($0.dropFirst("--adv=".count)) } == "short" ? "short" : "full"
    }()
    private var started = false
    private var observers: [NSObjectProtocol] = []
    private var heartbeat: Task<Void, Never>?
    private var logFile: FileHandle?
    private let t0 = Date()

    private var token = 0
    private var pendingState: CheckedContinuation<Void, Never>?
    private var pendingAdd: CheckedContinuation<CBResult, Never>?
    private var pendingAddService: CBMutableService?   // didAdd is only credited if it is this exact object
    private var pendingAdv: CheckedContinuation<CBResult, Never>?

    private var summary: [String: Any] = [:]
    private var stateHistory: [String] = []

    // Stay-mode GATT objects
    private var inputReportChar: CBMutableCharacteristic?
    private var protocolMode: UInt8 = 0x01
    private var pointerTask: Task<Void, Never>?

    override init() {
        super.init()
        setvbuf(stdout, nil, _IONBF, 0)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("probe.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        logFile = try? FileHandle(forWritingTo: url)
    }

    func log(_ s: String) {
        let line = String(format: "[HP %6.2f] ", Date().timeIntervalSince(t0)) + s
        print(line)
        lines.append(line)
        if let d = (line + "\n").data(using: .utf8) { try? logFile?.write(contentsOf: d) }
    }

    func start() {
        guard !started else { return }
        started = true
        installLifecycleLogging()
        Task { await run() }
    }

    private func appStateName() -> String {
        switch UIApplication.shared.applicationState {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "raw"
        }
    }

    private func installLifecycleLogging() {
        // atexit: runs if anything (us or UIKit) calls exit(); not run on SIGKILL. Writes straight to fd 1.
        atexit {
            let msg = "[HP atexit] process is exiting via exit() (UIKit or app)\n"
            _ = msg.withCString { write(1, $0, strlen($0)) }
        }
        let names: [(Notification.Name, String)] = [
            (UIApplication.willResignActiveNotification, "willResignActive"),
            (UIApplication.didEnterBackgroundNotification, "didEnterBackground"),
            (UIApplication.willEnterForegroundNotification, "willEnterForeground"),
            (UIApplication.didBecomeActiveNotification, "didBecomeActive"),
            (UIApplication.willTerminateNotification, "willTerminate"),
            (UIApplication.didReceiveMemoryWarningNotification, "didReceiveMemoryWarning"),
            (UIApplication.protectedDataWillBecomeUnavailableNotification, "protectedDataWillBecomeUnavailable(device locking)"),
            (UIApplication.protectedDataDidBecomeAvailableNotification, "protectedDataDidBecomeAvailable(device unlocked)"),
        ]
        for (n, label) in names {
            observers.append(NotificationCenter.default.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.log("LIFECYCLE \(label) appState=\(self.appStateName()) isAdvertising=\(self.pm?.isAdvertising ?? false)")
                }
            })
        }
    }

    // MARK: Waiting helpers (all on MainActor)

    private func waitPoweredOn(timeout: Double) async {
        if isSettled() { return }
        token += 1
        let my = token
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            pendingState = c
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                if my == self.token, let p = self.pendingState {
                    self.pendingState = nil
                    self.log("STATE wait TIMEOUT after \(timeout)s (state=\(stateName(self.pm.state)) auth=\(authName(CBManager.authorization)))")
                    p.resume()
                }
            }
        }
    }

    private func isSettled() -> Bool {
        let s = pm.state
        if s == .poweredOn { return true }
        if (s == .unsupported || s == .poweredOff || s == .unauthorized)
            && CBManager.authorization != .notDetermined { return true }
        return false
    }

    private func addAndWait(_ service: CBMutableService, label: String, timeout: Double = 8) async -> CBResult {
        log("ADD \(label) uuid=\(service.uuid.uuidString) (bytes=\(service.uuid.data.count)) chars=\(service.characteristics?.map { $0.uuid.uuidString } ?? [])")
        token += 1
        let my = token
        let r: CBResult = await withCheckedContinuation { (c: CheckedContinuation<CBResult, Never>) in
            pendingAdd = c
            pendingAddService = service
            if let exc = HPTryCatch({ self.pm.add(service) }) {
                pendingAdd = nil
                c.resume(returning: CBResult(status: "EXCEPTION", exception: exc))
                return
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                if my == self.token, let p = self.pendingAdd {
                    self.pendingAdd = nil
                    p.resume(returning: CBResult(status: "TIMEOUT"))
                }
            }
        }
        log("ADD_RESULT \(label): \(r.line)" + (r.cbUUIDString.map { " didAdd.uuidString=\($0) didAdd.uuid.data.count=\(r.cbUUIDBytes ?? -1)" } ?? ""))
        return r
    }

    private func advertiseAndWait(_ uuids: [CBUUID], label: String, timeout: Double = 8) async -> CBResult {
        let adv: [String: Any] = [CBAdvertisementDataServiceUUIDsKey: uuids,
                                  CBAdvertisementDataLocalNameKey: "HIDProbe"]
        log("ADV \(label) uuids=\(uuids.map { "\($0.uuidString)(\($0.data.count)B)" }) name=HIDProbe")
        token += 1
        let my = token
        var r: CBResult = await withCheckedContinuation { (c: CheckedContinuation<CBResult, Never>) in
            pendingAdv = c
            if let exc = HPTryCatch({ self.pm.startAdvertising(adv) }) {
                pendingAdv = nil
                c.resume(returning: CBResult(status: "EXCEPTION", exception: exc))
                return
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                if my == self.token, let p = self.pendingAdv {
                    self.pendingAdv = nil
                    p.resume(returning: CBResult(status: "TIMEOUT"))
                }
            }
        }
        r.cbUUIDString = nil
        log("ADV_RESULT \(label): \(r.line) isAdvertising=\(pm.isAdvertising)")
        return r
    }

    // MARK: Service builders

    private func makeSimpleService(_ uuid: CBUUID, charUUID: CBUUID) -> CBMutableService {
        let s = CBMutableService(type: uuid, primary: true)
        let c = CBMutableCharacteristic(type: charUUID, properties: [.read], value: nil, permissions: [.readable])
        s.characteristics = [c]
        return s
    }

    private func makeDeviceInfo(full: Bool) -> CBMutableService {
        // 2A29 Manufacturer Name String
        makeSimpleService(K.sig("180A", full: full), charUUID: K.sig("2A29", full: full))
    }

    private func makeBattery(full: Bool) -> CBMutableService {
        let s = CBMutableService(type: K.sig("180F", full: full), primary: true)
        let c = CBMutableCharacteristic(type: K.sig("2A19", full: full), properties: [.read, .notify],
                                        value: nil, permissions: [.readable])
        s.characteristics = [c]
        return s
    }

    struct HIDBuild {
        var service: CBMutableService?
        var inputReport: CBMutableCharacteristic?
        var buildException: String?
        var descriptor2908: String   // "included" | "EXCEPTION: ..." | "omitted"
    }

    private func makeHID(svcFull: Bool, charFull: Bool, encrypted: Bool, try2908: Bool) -> HIDBuild {
        let R: CBAttributePermissions = encrypted ? .readEncryptionRequired : .readable
        let W: CBAttributePermissions = encrypted ? .writeEncryptionRequired : .writeable
        var desc2908 = "omitted"
        var svc: CBMutableService?
        var input: CBMutableCharacteristic?
        var refDesc: CBMutableDescriptor?

        if try2908 {
            let dUUID = K.sig("2908", full: charFull)
            if let exc = HPTryCatch({ refDesc = CBMutableDescriptor(type: dUUID, value: K.reportReference) }) {
                desc2908 = "EXCEPTION: \(exc)"
                refDesc = nil
            } else {
                desc2908 = "included"
            }
        }

        let exc = HPTryCatch {
            let s = CBMutableService(type: K.sig("1812", full: svcFull), primary: true)
            let info = CBMutableCharacteristic(type: K.sig("2A4A", full: charFull), properties: [.read], value: nil, permissions: [R])
            let map = CBMutableCharacteristic(type: K.sig("2A4B", full: charFull), properties: [.read], value: nil, permissions: [R])
            let cp = CBMutableCharacteristic(type: K.sig("2A4C", full: charFull), properties: [.writeWithoutResponse], value: nil, permissions: [W])
            let pmode = CBMutableCharacteristic(type: K.sig("2A4E", full: charFull), properties: [.read, .writeWithoutResponse], value: nil, permissions: [R, W])
            let inp = CBMutableCharacteristic(type: K.sig("2A4D", full: charFull), properties: [.read, .notify], value: nil, permissions: [R])
            if let refDesc { inp.descriptors = [refDesc] }
            s.characteristics = [info, map, cp, pmode, inp]
            svc = s
            input = inp
        }
        return HIDBuild(service: exc == nil ? svc : nil, inputReport: input, buildException: exc, descriptor2908: desc2908)
    }

    /// Encrypted first; on failure retry once with plain permissions.
    /// Within each permission set: with 2908 if constructible; if the add raises, retry without 2908.
    private func hidChain(label: String, svcFull: Bool, charFull: Bool) async -> (attempts: [[String: Any]], accepted: [String: Any]?) {
        var attempts: [[String: Any]] = []
        for encrypted in [true, false] {
            var variants: [Bool] = [true]   // try2908
            var i = 0
            while i < variants.count {
                let try2908 = variants[i]; i += 1
                let b = makeHID(svcFull: svcFull, charFull: charFull, encrypted: encrypted, try2908: try2908)
                let perms = encrypted ? "encrypted" : "plain"
                let with2908 = b.descriptor2908 == "included"
                var a: [String: Any] = ["perms": perms, "desc2908": b.descriptor2908,
                                        "svcUUID": svcFull ? "128" : "16", "charUUIDs": charFull ? "128" : "16"]
                log("HID \(label) attempt perms=\(perms) svc=\(svcFull ? 128 : 16)bit chars=\(charFull ? 128 : 16)bit desc2908=\(b.descriptor2908)")
                guard let svc = b.service else {
                    a["result"] = CBResult(status: "EXCEPTION", exception: "build: \(b.buildException ?? "?")").dict
                    log("HID \(label) build EXCEPTION: \(b.buildException ?? "?")")
                    attempts.append(a)
                    if with2908 { variants.append(false) }
                    continue
                }
                let r = await addAndWait(svc, label: "\(label)/\(perms)/\(with2908 ? "with2908" : "no2908")")
                a["result"] = r.dict
                attempts.append(a)
                if r.ok {
                    pm.remove(svc)
                    log("REMOVE \(label) (isolating next attempt)")
                    return (attempts, a)
                }
                if r.status == "EXCEPTION" && with2908 { variants.append(false) }
            }
        }
        return (attempts, nil)
    }

    // MARK: Main sequence

    private func run() async {
        log("START stayMode=\(stayMode) iOS=\(UIDevice.current.systemVersion) model=\(UIDevice.current.model) auth(before)=\(authName(CBManager.authorization))")
        pm = CBPeripheralManager(delegate: self, queue: .main, options: nil)
        log("CBPeripheralManager created; state=\(stateName(pm.state)) auth=\(authName(CBManager.authorization))")
        await waitPoweredOn(timeout: 30)
        summary["state"] = stateName(pm.state)
        summary["authorization"] = authName(CBManager.authorization)
        summary["stateHistory"] = stateHistory

        guard pm.state == .poweredOn else {
            log("ABORT: manager not poweredOn")
            finish()
            return
        }

        var adds: [String: Any] = [:]

        // 1. custom (control) - kept in DB
        let custom = makeSimpleService(K.customService, charUUID: K.customChar)
        adds["custom"] = await addAndWait(custom, label: "custom").dict

        // 2/3. Device Info + Battery, short then full128; remove after success to isolate.
        var accepted180A: Bool? = nil, accepted180F: Bool? = nil   // value = full form?
        for (name, maker) in [("180A", makeDeviceInfo), ("180F", makeBattery)] as [(String, (Bool) -> CBMutableService)] {
            for full in [false, true] {
                let s = maker(full)
                let key = "\(name)_\(full ? "full128" : "short")"
                let r = await addAndWait(s, label: key)
                adds[key] = r.dict
                if r.ok {
                    pm.remove(s); log("REMOVE \(key) (isolating next attempt)")
                    if name == "180A", accepted180A == nil || !full { accepted180A = accepted180A ?? full }
                    if name == "180F", accepted180F == nil || !full { accepted180F = accepted180F ?? full }
                }
            }
        }

        // 4. HID short form
        let hs = await hidChain(label: "hid_short", svcFull: false, charFull: false)
        adds["hid_short"] = ["attempts": hs.attempts, "accepted": hs.accepted as Any? ?? NSNull()]

        // 5. HID full 128-bit (chars + 2908 in 128-bit too); fallback: 128 service + short chars
        let hf = await hidChain(label: "hid_full128", svcFull: true, charFull: true)
        adds["hid_full128"] = ["attempts": hf.attempts, "accepted": hf.accepted as Any? ?? NSNull()]
        var hidFullAccepted = hf.accepted
        if hf.accepted == nil {
            let hm = await hidChain(label: "hid_full128_shortchars", svcFull: true, charFull: false)
            adds["hid_full128_shortchars"] = ["attempts": hm.attempts, "accepted": hm.accepted as Any? ?? NSNull()]
            hidFullAccepted = hm.accepted
        }
        summary["adds"] = adds

        // 6. Final GATT DB (custom already present): accepted 180A/180F + accepted HID variant.
        var finalDB: [String: Any] = [:]
        if let f = accepted180A { finalDB["180A"] = await addAndWait(makeDeviceInfo(full: f), label: "final_180A_\(f ? "full128" : "short")").dict }
        if let f = accepted180F { finalDB["180F"] = await addAndWait(makeBattery(full: f), label: "final_180F_\(f ? "full128" : "short")").dict }
        let hidPick: (svcFull: Bool, charFull: Bool, acc: [String: Any])? = {
            if let a = hidFullAccepted { return (true, (a["charUUIDs"] as? String) == "128", a) }
            if let a = hs.accepted { return (false, false, a) }
            return nil
        }()
        if let p = hidPick {
            let enc = (p.acc["perms"] as? String) == "encrypted"
            let use2908 = (p.acc["desc2908"] as? String) == "included"
            let b = makeHID(svcFull: p.svcFull, charFull: p.charFull, encrypted: enc, try2908: use2908)
            if let svc = b.service {
                let r = await addAndWait(svc, label: "final_hid svc=\(p.svcFull ? 128 : 16) chars=\(p.charFull ? 128 : 16) \(enc ? "encrypted" : "plain") desc2908=\(b.descriptor2908)")
                finalDB["hid"] = r.dict
                if r.ok { inputReportChar = b.inputReport }
            }
        }
        summary["finalDB"] = finalDB

        // 7. Advertising tests
        var advs: [String: Any] = [:]
        let hidShort = CBUUID(string: "1812")
        let hidFull = CBUUID(string: "00001812\(K.base)")
        for (key, uuids) in [("adv_custom", [K.customService]), ("adv_hid_short", [hidShort]), ("adv_hid_full128", [hidFull])] {
            let r = await advertiseAndWait(uuids, label: key)
            advs[key] = r.dict
            pm.stopAdvertising()
            log("STOP_ADV \(key) isAdvertising=\(pm.isAdvertising)")
            try? await Task.sleep(for: .milliseconds(700))
        }
        summary["advertising"] = advs

        let stayOK = hidFullAccepted != nil && ((advs["adv_hid_full128"] as? [String: Any])?["status"] as? String) == "OK"
        summary["stayModeEligible"] = stayOK
        summary["stayMode"] = stayMode
        var stayAdv: CBResult? = nil
        if stayMode && stayOK {
            // Stay mode: service is 128-bit in both cases; only the advertised CBUUID form differs.
            let uuid = advForm == "short" ? hidShort : hidFull
            stayAdv = await advertiseAndWait([uuid], label: "stay_adv_\(advForm)")
            summary["stayAdv"] = ["form": advForm, "uuid": uuid.uuidString, "bytes": uuid.data.count, "result": stayAdv!.dict]
        }
        finish(stay: stayMode && stayOK && stayAdv?.ok == true)
    }

    private func finish(stay: Bool = false) {
        summary["state"] = stateName(pm?.state ?? .unknown)
        summary["authorization"] = authName(CBManager.authorization)
        summary["stateHistory"] = stateHistory
        summary["iOS"] = UIDevice.current.systemVersion
        let json: String
        if let d = try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys, .withoutEscapingSlashes]),
           let s = String(data: d, encoding: .utf8) { json = s } else { json = "{\"error\":\"json\"}" }
        log("SPIKE_RESULT " + json)
        if stay {
            UIApplication.shared.isIdleTimerDisabled = true
            log("STAY_MODE_READY adv=\(advForm) advertisedUUID=\(advForm == "short" ? "1812(2B)" : "00001812-0000-1000-8000-00805F9B34FB(16B)") service=128-bit name=HIDProbe appState=\(appStateName()); waiting for centrals (no exit path in stay mode)")
            heartbeat = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    self.log("HEARTBEAT appState=\(self.appStateName()) isAdvertising=\(self.pm.isAdvertising) state=\(stateName(self.pm.state))")
                }
            }
        } else {
            if stayMode { log("STAY_MODE_NOT_ELIGIBLE (needs hid_full128 accepted AND adv_hid_full128 OK AND stay advertising OK); exiting") }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                self.log("EXIT")
                exit(0)
            }
        }
    }

    // MARK: Stay-mode GATT handling

    private func valueFor(_ uuid: CBUUID) -> Data? {
        switch K.short16(uuid) {
        case "2A4A": return K.hidInfo
        case "2A4B": return K.reportMap
        case "2A4E": return Data([protocolMode])
        case "2A4D": return Data([0, 0, 0, 0])
        case "2A29": return "HIDProbe".data(using: .utf8)
        case "2A19": return Data([100])
        default: return uuid == K.customChar ? "hello".data(using: .utf8) : nil
        }
    }

    private func startPointer() {
        pointerTask?.cancel()
        pointerTask = Task { @MainActor in
            guard let ch = self.inputReportChar else { self.log("POINTER no input report characteristic"); return }
            let ok0 = self.pm.updateValue(Data([0, 0, 0, 0]), for: ch, onSubscribedCentrals: nil)
            self.log("NOTIFY baseline [0,0,0,0] queued=\(ok0)")
            for i in 1...20 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                let ok = self.pm.updateValue(Data([0, 10, 0, 0]), for: ch, onSubscribedCentrals: nil)
                self.log("NOTIFY \(i)/20 [0,+10,0,0] queued=\(ok)")
            }
        }
    }
}

// MARK: - Delegate
// Swift 6: isolated conformance (SE-0470). Manager uses queue: .main so callbacks arrive on the main actor.

extension Probe: @MainActor CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        let s = "\(stateName(peripheral.state))/auth=\(authName(CBManager.authorization))"
        stateHistory.append(s)
        log("DID_UPDATE_STATE state=\(stateName(peripheral.state)) (raw \(peripheral.state.rawValue)) auth=\(authName(CBManager.authorization))")
        if isSettled(), let p = pendingState {
            pendingState = nil
            p.resume()
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        var r = CBResult.from(error: error)
        r.cbUUIDString = service.uuid.uuidString
        r.cbUUIDBytes = service.uuid.data.count
        log("DID_ADD service.uuid.uuidString=\(service.uuid.uuidString) service.uuid.data.count=\(service.uuid.data.count) chars=\(service.characteristics?.map { "\($0.uuid.uuidString)(\($0.uuid.data.count)B)" } ?? []) error=\(r.line)")
        if let p = pendingAdd, service === pendingAddService || service.uuid == pendingAddService?.uuid {
            pendingAdd = nil
            pendingAddService = nil
            p.resume(returning: r)
        } else {
            log("DID_ADD (late/unexpected, no pending add)")
        }
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        let r = CBResult.from(error: error)
        log("DID_START_ADVERTISING \(r.line)")
        if let p = pendingAdv {
            pendingAdv = nil
            p.resume(returning: r)
        } else {
            log("DID_START_ADVERTISING (late/unexpected)")
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        let u = request.characteristic.uuid
        log("DID_RECEIVE_READ char=\(u.uuidString) (\(K.short16(u))) central=\(request.central.identifier) offset=\(request.offset)")
        guard let v = valueFor(u) else { peripheral.respond(to: request, withResult: .readNotPermitted); return }
        if request.offset > v.count { peripheral.respond(to: request, withResult: .invalidOffset); return }
        request.value = v.subdata(in: request.offset..<v.count)
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for r in requests {
            let u = r.characteristic.uuid
            let hex = (r.value ?? Data()).map { String(format: "%02X", $0) }.joined()
            log("DID_RECEIVE_WRITE char=\(u.uuidString) (\(K.short16(u))) central=\(r.central.identifier) value=\(hex)")
            if K.short16(u) == "2A4E", let b = r.value?.first { protocolMode = b }
        }
        if let first = requests.first {
            if let exc = HPTryCatch({ peripheral.respond(to: first, withResult: .success) }) {
                log("RESPOND write EXCEPTION \(exc)")
            }
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        log("DID_SUBSCRIBE char=\(characteristic.uuid.uuidString) (\(K.short16(characteristic.uuid))) central=\(central.identifier) maxUpdate=\(central.maximumUpdateValueLength)")
        if K.short16(characteristic.uuid) == "2A4D" { startPointer() }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        log("DID_UNSUBSCRIBE char=\(characteristic.uuid.uuidString) (\(K.short16(characteristic.uuid))) central=\(central.identifier)")
        if K.short16(characteristic.uuid) == "2A4D" { pointerTask?.cancel() }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        log("READY_TO_UPDATE_SUBSCRIBERS")
    }
}

// MARK: - UI

struct ContentView: View {
    @ObservedObject var probe: Probe
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(probe.lines.enumerated()), id: \.offset) { i, l in
                        Text(l).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).id(i)
                    }
                }.padding(8)
            }
            .onChange(of: probe.lines.count) { _, n in
                if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) }
            }
        }
    }
}

@main
struct HIDProbeApp: App {
    @StateObject private var probe = Probe()
    var body: some Scene {
        WindowGroup {
            ContentView(probe: probe).onAppear { probe.start() }
        }
    }
}
