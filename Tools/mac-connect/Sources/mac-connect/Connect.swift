import Foundation
import CoreBluetooth
import IOKit.hid

/// `mac-connect connect [--timeout s] [--name substring]`
///
/// Gives macOS the first connection to the phone so that its HID driver binds the HID service.
/// It only connects and discovers the HID service; it never reads, subscribes to or relays reports,
/// and it exits without cancelling the connection (the system HID driver keeps using the link).
@MainActor
final class Connector: NSObject {
    private let timeout: Double
    private let nameFilter: String?
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var waiter: CheckedContinuation<Bool, Never>?
    private var waitingFor = ""
    private let hidWatcher = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var hidAppeared: IOHIDDevice?

    static var shared: Connector?

    /// The HID service as advertised (16-bit) and as the phone registers it (128-bit).
    private var hidUUIDs: [CBUUID] {
        [CBUUID(string: "1812"), CBUUID(string: "00001812-0000-1000-8000-00805F9B34FB")]
    }

    init(timeout: Double, nameFilter: String?) {
        self.timeout = timeout
        self.nameFilter = nameFilter
    }

    func run() async -> Int32 {
        let deadline = Date().addingTimeInterval(timeout)
        let existing = copyBLEDevices()
        if !existing.isEmpty {
            emit("CONNECT a BLE HID device already exists; nothing to do (no Bluetooth calls made)")
            for device in existing { for line in describe(device) { emit(line) } }
            return 0
        }
        startHIDWatcher()

        central = CBCentralManager(delegate: self, queue: .main)
        if central.state != .poweredOn {
            guard await wait(for: "poweredOn", until: deadline), central.state == .poweredOn else {
                emit("CONNECT error: Bluetooth not available (state=\(central.state.rawValue), authorization=\(CBManager.authorization.rawValue)). If authorization is denied, allow Bluetooth for the terminal app in System Settings > Privacy & Security > Bluetooth.")
                return 2
            }
        }

        let connected = central.retrieveConnectedPeripherals(withServices: hidUUIDs)
        emit("CONNECT system-connected peripherals with HID service: \(connected.map { "\($0.identifier) \"\($0.name ?? "-")\"" })")
        if let p = connected.first(where: matchesName) {
            emit("CONNECT using already-connected peripheral \(p.identifier) \"\(p.name ?? "-")\"")
            peripheral = p
        } else {
            emit("CONNECT scanning for connectable peripherals advertising 0x1812" + (nameFilter.map { " with name containing \"\($0)\"" } ?? ""))
            central.scanForPeripherals(withServices: [CBUUID(string: "1812")], options: nil)
            guard await wait(for: "discovered", until: deadline), peripheral != nil else {
                central.stopScan()
                emit("CONNECT error: timeout after \(Int(timeout)) s, no matching peripheral found. Is the phone app in the foreground and advertising?")
                return 1
            }
        }

        guard let p = peripheral else { return 1 }
        p.delegate = self
        if hidAppeared == nil {
            emit("CONNECT connecting to \(p.identifier)")
            central.connect(p, options: nil)
            guard await wait(for: "connected", until: deadline) else {
                emit("CONNECT error: timeout or failure while connecting (peripheral state=\(p.state.rawValue))")
                return 1
            }
            p.discoverServices(hidUUIDs)
        }

        if hidAppeared == nil { _ = await wait(for: "hid", until: deadline) }
        guard let device = hidAppeared else {
            emit("CONNECT error: connected, but macOS created no BLE HID device within \(Int(timeout)) s. See: /usr/bin/log show --last 5m --predicate 'process == \"bluetoothd\" OR process == \"BTLEServer\"' --style compact")
            return 1
        }
        emit("CONNECT done: macOS created a BLE HID device")
        for line in describe(device) { emit(line) }
        return 0
    }

    private func matchesName(_ p: CBPeripheral) -> Bool {
        guard let nameFilter else { return true }
        return (p.name ?? "").localizedCaseInsensitiveContains(nameFilter)
    }

    private func startHIDWatcher() {
        IOHIDManagerSetDeviceMatching(hidWatcher, bleMatching())
        IOHIDManagerRegisterDeviceMatchingCallback(hidWatcher, { _, _, _, device in
            MainActor.assumeIsolated {
                guard let me = Connector.shared, me.hidAppeared == nil else { return }
                emit("CONNECT HID device appeared: \(deviceHeadline(device))")
                me.hidAppeared = device
                me.signal("hid")
            }
        }, nil)
        IOHIDManagerSetDispatchQueue(hidWatcher, DispatchQueue.main)
        IOHIDManagerActivate(hidWatcher)
    }

    // MARK: waiting

    private func wait(for event: String, until deadline: Date) async -> Bool {
        waitingFor = event
        let remaining = max(0, deadline.timeIntervalSinceNow)
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            waiter = c
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(remaining))
                if self.waitingFor == event, let w = self.waiter {
                    self.waiter = nil
                    w.resume(returning: false)
                }
            }
        }
    }

    private func signal(_ event: String, _ ok: Bool = true) {
        guard waitingFor == event, let w = waiter else { return }
        waiter = nil
        waitingFor = ""
        w.resume(returning: ok)
    }
}

extension Connector: @MainActor CBCentralManagerDelegate, @MainActor CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        emit("CONNECT bluetooth state=\(central.state.rawValue) authorization=\(CBManager.authorization.rawValue)")
        if central.state == .poweredOn { signal("poweredOn") }
        if central.state == .unauthorized || central.state == .unsupported || central.state == .poweredOff { signal("poweredOn", false) }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        let connectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? false
        emit("CONNECT discovered \(peripheral.identifier) name=\"\(name)\" connectable=\(connectable) rssi=\(rssi)")
        guard connectable, self.peripheral == nil else { return }
        if let nameFilter, !name.localizedCaseInsensitiveContains(nameFilter) { return }
        central.stopScan()
        self.peripheral = peripheral
        signal("discovered")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        emit("CONNECT connected \(peripheral.identifier)")
        signal("connected")
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        emit("CONNECT connect failed: \(error.map { "\($0)" } ?? "unknown error")")
        signal("connected", false)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        emit("CONNECT disconnected: \(error.map { "\($0)" } ?? "no error")")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = (peripheral.services ?? []).map { $0.uuid.uuidString }
        emit("CONNECT HID service discovery: \(services) error=\(error.map { "\($0)" } ?? "none")")
    }
}
