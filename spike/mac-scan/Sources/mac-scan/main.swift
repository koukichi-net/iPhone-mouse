import Foundation
import CoreBluetooth
import CoreGraphics

// Spike: what does this Mac see from the HIDProbe iPhone app over the air?
// Usage: mac-scan [scanSeconds=20] [filteredSeconds=10]

setvbuf(stdout, nil, _IONBF, 0)

let base = "-0000-1000-8000-00805F9B34FB"
let customUUIDString = "8F3A2C10-5B7E-4D2A-9C61-0E4B7A1D3F01"

func short16(_ u: CBUUID) -> String {
    let d = u.data
    if d.count == 2 { return String(format: "%02X%02X", d[0], d[1]) }
    let s = u.uuidString.uppercased()
    if d.count == 16, s.hasPrefix("0000"), s.hasSuffix(base) { return String(s.dropFirst(4).prefix(4)) }
    return s
}
func fmtUUID(_ u: CBUUID) -> String { "\(u.uuidString)(\(u.data.count)B)" }
func hex(_ d: Data) -> String { d.map { String(format: "%02X", $0) }.joined() }

func fmtValue(_ v: Any) -> String {
    if let a = v as? [CBUUID] { return "[" + a.map(fmtUUID).joined(separator: ", ") + "]" }
    if let d = v as? Data { return "0x" + hex(d) + " (\(d.count)B)" }
    if let m = v as? [CBUUID: Data] { return "{" + m.map { "\(fmtUUID($0.key))=0x\(hex($0.value))" }.sorted().joined(separator: ", ") + "}" }
    return "\(v)"
}

func propsName(_ p: CBCharacteristicProperties) -> String {
    var r: [String] = []
    if p.contains(.broadcast) { r.append("broadcast") }
    if p.contains(.read) { r.append("read") }
    if p.contains(.writeWithoutResponse) { r.append("writeWithoutResponse") }
    if p.contains(.write) { r.append("write") }
    if p.contains(.notify) { r.append("notify") }
    if p.contains(.indicate) { r.append("indicate") }
    if p.contains(.authenticatedSignedWrites) { r.append("signedWrites") }
    if p.contains(.extendedProperties) { r.append("extendedProperties") }
    if p.contains(.notifyEncryptionRequired) { r.append("notifyEncReq") }
    if p.contains(.indicateEncryptionRequired) { r.append("indicateEncReq") }
    return r.joined(separator: "|")
}

let t0 = Date()
func log(_ s: String) { print(String(format: "[MS %6.2f] ", Date().timeIntervalSince(t0)) + s) }

@MainActor
final class Scanner: NSObject {
    var cm: CBCentralManager!
    var phase = "init"
    var allSeen = Set<UUID>()
    var matched: [UUID: CBPeripheral] = [:]
    var matchedNames: [UUID: String] = [:]
    var lastSig: [UUID: String] = [:]
    var advCount: [UUID: Int] = [:]
    var rssiRange: [UUID: (Int, Int)] = [:]
    var filteredHits: [UUID: String] = [:]

    var pending: CheckedContinuation<Bool, Never>?
    var pendingKey = ""
    var token = 0

    func wait(_ key: String, timeout: Double) async -> Bool {
        token += 1
        let my = token
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            pending = c; pendingKey = key
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                if my == self.token, let p = self.pending { self.pending = nil; p.resume(returning: false) }
            }
        }
    }
    func signal(_ key: String) {
        if pendingKey == key, let p = pending { pending = nil; p.resume(returning: true) }
    }

    func run(scanSeconds: Double, filteredSeconds: Double) async {
        log("START macOS=\(ProcessInfo.processInfo.operatingSystemVersionString) auth(before)=\(authName(CBManager.authorization))")
        cm = CBCentralManager(delegate: self, queue: .main)
        if cm.state != .poweredOn {
            let ok = await wait("poweredOn", timeout: 15)
            if !ok {
                log("ABORT central state=\(stateName(cm.state)) auth=\(authName(CBManager.authorization)) (not poweredOn within 15s; a TCC prompt may be waiting for a human)")
                return
            }
        }

        // Phase 1: unfiltered scan
        phase = "unfiltered"
        log("PHASE1 scanForPeripherals(withServices: nil, allowDuplicates: true) for \(scanSeconds)s")
        cm.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        try? await Task.sleep(for: .seconds(scanSeconds))
        cm.stopScan()
        log("PHASE1 done: distinct peripherals seen=\(allSeen.count), matched=\(matched.count)")
        for (id, _) in matched {
            let r = rssiRange[id] ?? (0, 0)
            log("PHASE1 SUMMARY id=\(id) name=\(matchedNames[id] ?? "-") adverts=\(advCount[id] ?? 0) rssi=[\(r.0)..\(r.1)]")
        }

        // Phase 2: filtered scans
        for (label, u) in [("1812(16-bit)", CBUUID(string: "1812")), ("00001812-...(128-bit)", CBUUID(string: "00001812\(base)"))] {
            phase = "filtered"
            filteredHits = [:]
            log("PHASE2 scanForPeripherals(withServices: [\(fmtUUID(u))] /*\(label)*/, allowDuplicates: true) for \(filteredSeconds)s")
            cm.scanForPeripherals(withServices: [u], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            try? await Task.sleep(for: .seconds(filteredSeconds))
            cm.stopScan()
            let phoneHit = filteredHits.keys.contains { matched[$0] != nil }
            log("PHASE2 RESULT filter=\(label): peripherals returned=\(filteredHits.count) phoneMatched=\(phoneHit)")
            for (id, d) in filteredHits { log("PHASE2 HIT filter=\(label) id=\(id) \(d)") }
        }

        // Phase 3: connect + GATT discovery
        phase = "connect"
        let target = matched.first { ($0.value.name ?? "").contains("HIDProbe") || (matchedNames[$0.key] ?? "").contains("HIDProbe") }?.value
            ?? matched.values.first
        guard let p = target else { log("PHASE3 SKIPPED: phone not seen in phase 1"); return }
        log("PHASE3 connect id=\(p.identifier) name=\(p.name ?? "-")")
        p.delegate = self
        cm.connect(p, options: nil)
        guard await wait("connect", timeout: 15) else { log("PHASE3 connect TIMEOUT/FAILED state=\(p.state.rawValue)"); cm.cancelPeripheralConnection(p); return }
        p.discoverServices(nil)
        guard await wait("services", timeout: 15) else { log("PHASE3 discoverServices TIMEOUT"); cm.cancelPeripheralConnection(p); return }
        for s in p.services ?? [] {
            log("GATT SERVICE \(fmtUUID(s.uuid)) short=\(short16(s.uuid)) primary=\(s.isPrimary)")
            p.discoverCharacteristics(nil, for: s)
            if !(await wait("chars", timeout: 10)) { log("GATT   discoverCharacteristics TIMEOUT for \(fmtUUID(s.uuid))"); continue }
            for c in s.characteristics ?? [] {
                log("GATT   CHAR \(fmtUUID(c.uuid)) short=\(short16(c.uuid)) props=\(propsName(c.properties))")
                p.discoverDescriptors(for: c)
                if await wait("descs", timeout: 10) {
                    for d in c.descriptors ?? [] { log("GATT     DESC \(fmtUUID(d.uuid)) short=\(short16(d.uuid))") }
                } else { log("GATT     discoverDescriptors TIMEOUT") }
            }
        }
        // Read only unencrypted values: Device Information 2A29 and the custom characteristic.
        for s in p.services ?? [] {
            for c in s.characteristics ?? [] where short16(c.uuid) == "2A29" || c.uuid.uuidString.uppercased().hasPrefix("8F3A2C11") {
                p.readValue(for: c)
                if await wait("read", timeout: 10) {
                    let v = c.value ?? Data()
                    log("READ \(fmtUUID(c.uuid)) value=0x\(hex(v)) utf8=\"\(String(data: v, encoding: .utf8) ?? "-")\"")
                } else { log("READ \(fmtUUID(c.uuid)) TIMEOUT") }
            }
        }
        cm.cancelPeripheralConnection(p)
        _ = await wait("disconnect", timeout: 5)
        log("DONE")
    }
}

func stateName(_ s: CBManagerState) -> String {
    switch s {
    case .unknown: "unknown"; case .resetting: "resetting"; case .unsupported: "unsupported"
    case .unauthorized: "unauthorized"; case .poweredOff: "poweredOff"; case .poweredOn: "poweredOn"
    @unknown default: "raw(\(s.rawValue))"
    }
}
func authName(_ a: CBManagerAuthorization) -> String {
    switch a {
    case .notDetermined: "notDetermined"; case .restricted: "restricted"; case .denied: "denied"; case .allowedAlways: "allowedAlways"
    @unknown default: "raw(\(a.rawValue))"
    }
}

extension Scanner: @MainActor CBCentralManagerDelegate, @MainActor CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("CENTRAL_STATE \(stateName(central.state)) auth=\(authName(CBManager.authorization))")
        if central.state == .poweredOn { signal("poweredOn") }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData ad: [String: Any], rssi RSSI: NSNumber) {
        allSeen.insert(peripheral.identifier)
        let localName = ad[CBAdvertisementDataLocalNameKey] as? String
        let uuidKeys = [CBAdvertisementDataServiceUUIDsKey, CBAdvertisementDataOverflowServiceUUIDsKey, CBAdvertisementDataSolicitedServiceUUIDsKey]
        let allUUIDs = uuidKeys.flatMap { (ad[$0] as? [CBUUID]) ?? [] }
        let nameHit = [localName, peripheral.name].compactMap { $0 }.contains { $0.contains("HIDProbe") }
        let uuidHit = allUUIDs.contains { short16($0) == "1812" || $0.uuidString.uppercased() == customUUIDString }
        let keys = ad.keys.filter { $0 != "kCBAdvDataTimestamp" }.sorted()
        let body = keys.map { "\($0)=\(fmtValue(ad[$0]!))" }.joined(separator: " ")
        let desc = "periph.name=\(peripheral.name ?? "nil") advLocalName=\(localName ?? "nil") rssi=\(RSSI) | \(body)"

        if phase == "filtered" {
            if filteredHits[peripheral.identifier] == nil { filteredHits[peripheral.identifier] = desc }
            return
        }
        guard phase == "unfiltered", nameHit || uuidHit else { return }
        let id = peripheral.identifier
        matched[id] = peripheral
        if let n = localName ?? peripheral.name { matchedNames[id] = n }
        advCount[id, default: 0] += 1
        let r = RSSI.intValue
        let old = rssiRange[id] ?? (r, r)
        rssiRange[id] = (min(old.0, r), max(old.1, r))
        let sig = "\(peripheral.name ?? "nil")|\(body.replacingOccurrences(of: #"kCBAdvDataRxPrimaryPHY=\S+ |kCBAdvDataRxSecondaryPHY=\S+ ?"#, with: "", options: .regularExpression))"
        if lastSig[id] != sig {
            lastSig[id] = sig
            log("PHASE1 MATCH id=\(id) [\(nameHit ? "name" : "")\(uuidHit ? "+uuid" : "")] \(desc)")
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("CONNECTED id=\(peripheral.identifier) name=\(peripheral.name ?? "-")"); signal("connect")
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("CONNECT_FAILED \(String(describing: error))")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("DISCONNECTED error=\(String(describing: error))"); signal("disconnect")
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        log("DID_DISCOVER_SERVICES count=\(peripheral.services?.count ?? 0) error=\(String(describing: error))"); signal("services")
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { log("DISCOVER_CHARS error=\(error)") }
        signal("chars")
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: Error?) {
        if let error { log("DISCOVER_DESCS \(fmtUUID(characteristic.uuid)) error=\(error)") }
        signal("descs")
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { log("READ_ERROR \(fmtUUID(characteristic.uuid)) \(error)") }
        signal("read")
    }
}

let args = CommandLine.arguments
// Pointer sampler mode: mac-scan pointer [seconds=30]  -> prints CGEvent location every 0.25 s.
if args.count > 1, args[1] == "pointer" {
    let secs = args.count > 2 ? Double(args[2]) ?? 30 : 30
    var prev: CGPoint? = nil
    let n = Int(secs / 0.25)
    for _ in 0..<n {
        let p = CGEvent(source: nil)?.location ?? .zero
        let dx = prev.map { p.x - $0.x } ?? 0
        let dy = prev.map { p.y - $0.y } ?? 0
        log(String(format: "POINTER x=%.1f y=%.1f dx=%+.1f dy=%+.1f", p.x, p.y, dx, dy))
        prev = p
        try? await Task.sleep(for: .milliseconds(250))
    }
    exit(0)
}
let scanS = args.count > 1 ? Double(args[1]) ?? 20 : 20
let filtS = args.count > 2 ? Double(args[2]) ?? 10 : 10
let scanner = Scanner()
await scanner.run(scanSeconds: scanS, filteredSeconds: filtS)
exit(0)
