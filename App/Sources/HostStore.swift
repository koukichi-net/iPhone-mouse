import Foundation
import Observation
import CoreBluetooth
import HIDCore

/// What the app remembers about one host (a central, keyed by `CBCentral.identifier`).
/// Brings forward part of M4 (design §7.3): name and per-host pointer/keyboard profile.
struct HostProfile: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    /// 1-based, in order of first appearance; used for the placeholder name.
    var number: Int
    /// Name the user typed (wins over everything).
    var customName: String?
    /// Name iOS reported for the remote device, if any (see `HostNamer`).
    var autoName: String?
    var pointerSpeed: Double
    var scrollSpeed: Double
    var layoutRaw: String
    var hostOSRaw: String
    var firstSeen: Date
    var lastSeen: Date
    /// True once the user changed anything in this profile; automatic guesses never
    /// overwrite such a profile. (Optional so profiles saved before M3 still decode.)
    var edited: Bool?
    /// How layout/OS were initialised: "default", "numlock-led" (Windows guess), "migration".
    var initialGuess: String?
    /// Clicker (design §8.5): ポインターの出し方 (nil: PowerPoint toggle, the default) and the
    /// air-pointer sensitivity (nil: 1). Optional so older saved profiles still decode.
    var laserMethodRaw: String?
    var airPointerSpeed: Double?

    var layout: KeyboardLayout {
        get { KeyboardLayout(rawValue: layoutRaw) ?? .jis }
        set { layoutRaw = newValue.rawValue }
    }
    var hostOS: HostOS {
        get { HostOS(rawValue: hostOSRaw) ?? .macOS }
        set { hostOSRaw = newValue.rawValue }
    }

    var laserMethod: LaserMethod {
        get { laserMethodRaw.flatMap(LaserMethod.init(rawValue:)) ?? .powerPointToggle }
        set { laserMethodRaw = newValue.rawValue }
    }
    var airSpeed: Double {
        get { airPointerSpeed ?? SpeedScale.airPointer.defaultValue }
        set { airPointerSpeed = newValue }
    }

    var placeholderName: String { "接続先 \(number)" }

    /// The name shown everywhere.
    var displayName: String {
        if let n = customName?.trimmingCharacters(in: .whitespaces), !n.isEmpty { return n }
        if let n = autoName, !n.isEmpty { return n }
        return placeholderName
    }

    var hasRealName: Bool { displayName != placeholderName }

    /// Icon only (never used as the name): from the host OS setting, refined by the name.
    var symbolName: String {
        let n = (autoName ?? customName ?? "").lowercased()
        if n.contains("macbook") { return "laptopcomputer" }
        if n.contains("imac") || n.contains("mac mini") || n.contains("mac studio") { return "desktopcomputer" }
        if n.contains("ipad") { return "ipad" }
        return hostOS == .windows ? "pc" : "laptopcomputer"
    }

    var keyMap: KeyMap { KeyMap(layout: layout, host: hostOS) }

    var summary: String {
        String(format: "name=\"%@\" speed=%.2f scroll=%.2f layout=%@ os=%@ laser=%@ air=%.2f", displayName, pointerSpeed, scrollSpeed, layoutRaw, hostOSRaw,
               laserMethod.rawValue, airSpeed)
    }
}

/// Persisted host profiles (UserDefaults, JSON).
@MainActor
@Observable
final class HostStore {
    private(set) var profiles: [UUID: HostProfile] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let settings: AppSettings
    private static let key = "hostProfiles.v1"

    init(settings: AppSettings, defaults: UserDefaults = .standard) {
        self.settings = settings
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let list = try? JSONDecoder().decode([HostProfile].self, from: data) {
            profiles = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        }
    }

    /// Hosts in order of first appearance.
    var ordered: [HostProfile] { profiles.values.sorted { $0.number < $1.number } }

    func profile(_ id: UUID?) -> HostProfile? { id.flatMap { profiles[$0] } }

    /// Creates the profile on first sight (with the global defaults) and stamps lastSeen.
    @discardableResult
    func ensure(_ id: UUID) -> HostProfile {
        if var p = profiles[id] {
            p.lastSeen = Date()
            profiles[id] = p
            save()
            return p
        }
        let number = (profiles.values.map(\.number).max() ?? 0) + 1
        let p = HostProfile(id: id, number: number, customName: nil, autoName: nil,
                            pointerSpeed: settings.defaultPointerSpeed, scrollSpeed: settings.defaultScrollSpeed,
                            layoutRaw: settings.defaultLayout.rawValue, hostOSRaw: settings.defaultHostOS.rawValue,
                            firstSeen: Date(), lastSeen: Date(), edited: false, initialGuess: "default")
        profiles[id] = p
        save()
        Log.line("HOST_PROFILE new \(id) \(p.summary)")
        return p
    }

    /// Change a profile. `byUser` (the default) marks it edited, so automatic guesses leave
    /// it alone from then on.
    func update(_ id: UUID, byUser: Bool = true, _ change: (inout HostProfile) -> Void) {
        guard var p = profiles[id] else { return }
        change(&p)
        guard p != profiles[id] else { return }
        if byUser { p.edited = true }
        profiles[id] = p
        save()
    }

    /// A host wrote the keyboard LED output report. Windows writes NumLock right after it
    /// subscribes (seen twice, value [01]); macOS never did. For a host whose profile was just
    /// created with the defaults and never edited, that is taken as "Windows + JIS".
    func noteLEDWrite(_ id: UUID, _ leds: KeyboardLEDs) {
        guard leds.contains(.numLock), let p = profiles[id], p.edited != true, p.initialGuess == "default",
              Date().timeIntervalSince(p.firstSeen) < 30 else { return }
        update(id, byUser: false) {
            $0.hostOS = .windows
            $0.layout = .jis
            $0.initialGuess = "numlock-led"
        }
        Log.line("HOST_PROFILE guess \(id): NumLock LED written \(String(format: "%.1f", Date().timeIntervalSince(p.firstSeen))) s after first sight -> Windows + JIS")
    }

    func remove(_ id: UUID) {
        profiles[id] = nil
        save()
        Log.line("HOST_PROFILE removed \(id)")
    }

    func displayName(_ id: UUID?) -> String {
        guard let id else { return "接続先なし" }
        return profiles[id]?.displayName ?? "接続先 \(shortID(id))"
    }

    private func save() {
        if let data = try? JSONEncoder().encode(Array(profiles.values)) {
            defaults.set(data, forKey: Self.key)
        }
    }
}

/// Tries to learn a host's Bluetooth name. A central that connected to us is also a remote
/// device that iOS may know as a `CBPeripheral` with the same identifier; this asks
/// `retrievePeripherals(withIdentifiers:)` and `retrieveConnectedPeripherals(withServices:)`.
/// It never scans and never connects. Results (including "nothing") are logged as HOSTNAME.
@MainActor
final class HostNamer: NSObject {
    private var central: CBCentralManager?
    private var pending: Set<UUID> = []
    private var looked: [UUID: Int] = [:]
    private let store: HostStore

    init(store: HostStore) {
        self.store = store
        super.init()
    }

    func lookUp(_ id: UUID) {
        pending.insert(id)
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
            Log.line("HOSTNAME central manager created state=\(stateName(central!.state)) auth=\(authName(CBManager.authorization))")
        }
        run()
    }

    private func run() {
        guard let central, central.state == .poweredOn else { return }
        let ids = pending
        pending = []
        for id in ids {
            let n = (looked[id] ?? 0) + 1
            looked[id] = n
            var parts: [String] = []
            let byID = central.retrievePeripherals(withIdentifiers: [id]).filter { $0.identifier == id }
            parts.append("retrievePeripherals=\(byID.isEmpty ? "[]" : byID.map { "{name=\($0.name.map { "\"\($0)\"" } ?? "nil") state=\($0.state.rawValue)}" }.joined())")
            var connectedName: String?
            // Only the entry with this host's identifier is used or logged; other connected
            // devices (a watch, earbuds…) are counted but never named in the log.
            for svc in ["180A", "180F", "1805"] {
                let list = central.retrieveConnectedPeripherals(withServices: [CBUUID(string: svc)])
                let match = list.first { $0.identifier == id }
                if let m = match, connectedName == nil { connectedName = m.name }
                let matchText = match.map { "{name=\($0.name.map { "\"\($0)\"" } ?? "nil")}" } ?? "no match"
                parts.append("connected(\(svc))=\(matchText) others=\(list.count - (match == nil ? 0 : 1))")
            }
            let name = byID.first?.name ?? connectedName
            Log.line("HOSTNAME lookup#\(n) central=\(id) \(parts.joined(separator: " ")) -> \(name.map { "\"\($0)\"" } ?? "none")")
            if let name, !name.isEmpty {
                store.update(id, byUser: false) { $0.autoName = name }
            }
        }
    }
}

extension HostNamer: @MainActor CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Log.line("HOSTNAME central state=\(stateName(central.state))")
        if central.state == .poweredOn {
            // Hosts seen before the manager was ready.
            run()
        }
    }
}
