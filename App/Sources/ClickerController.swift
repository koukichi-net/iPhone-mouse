import Foundation
import UIKit
import CoreMotion
import HIDCore

/// Clicker mode (design §8.5): slide taps and the pointer button → `ClickerState` /
/// `AirPointer` (HIDCore) → `BLEPeripheral` (its `ReportQueue` paces keys and buttons and
/// coalesces motion while the link is busy; reports go to the active host only).
///
/// Every pointer press is paired with its release (`ClickerState`): lift, touch cancel, app
/// resigning active, host change, mode off and the screen going away all end the hold through
/// `endHold`. Logs use the tag `CLICKER`.
@MainActor
final class ClickerController {
    let peripheral: BLEPeripheral
    let settings: AppSettings
    let hosts: HostStore
    private var state = ClickerState()
    private var air = AirPointer()
    private let motion = CMMotionManager()
    /// Real device motion is running (only during a hold, or the probe's rest phase).
    private(set) var motionRunning = false
    /// Hold bookkeeping for the log.
    private var holdStart: Double?
    private var holdSource = ""
    /// Probe hook: every raw device-motion sample (time, rotation rate, gravity).
    var onRawSample: ((Double, Vector3, Vector3) -> Void)?
    private var warmupSamples = 0

    static let motionInterval = 1.0 / 100

    private let nextHaptic = UIImpactFeedbackGenerator(style: .rigid)
    private let previousHaptic = UIImpactFeedbackGenerator(style: .soft)
    private let pointerHaptic = UIImpactFeedbackGenerator(style: .medium)

    init(peripheral: BLEPeripheral, settings: AppSettings, hosts: HostStore) {
        self.peripheral = peripheral
        self.settings = settings
        self.hosts = hosts
    }

    var isPointerHeld: Bool { state.isPointerHeld }

    private var profile: HostProfile? { hosts.profile(peripheral.activeHostID) }

    /// The active host's method / OS / sensitivity (defaults when there is no host).
    var currentMethod: LaserMethod { profile?.laserMethod ?? .powerPointToggle }
    var currentHostOS: HostOS { profile?.hostOS ?? settings.defaultHostOS }
    var currentAirSpeed: Double { profile?.airSpeed ?? SpeedScale.airPointer.defaultValue }

    // MARK: - Slides

    /// A tap on the upper (next) or lower (previous) half, decided by `ClickerTapTracker`.
    func slide(_ d: ClickerDirection, zone: String = "") {
        let keys = settings.slideKeys
        let reports = state.slideTap(d, keys: keys)
        guard !reports.isEmpty else {
            Log.line("CLICKER \(d.rawValue) tap\(zone.isEmpty ? "" : " (\(zone))") ignored: Control is held by the pointer (Ctrl＋左ボタン)")
            return
        }
        send(reports)
        if settings.haptics { haptic(d) }
        Log.line("CLICKER \(d.rawValue) tap\(zone.isEmpty ? "" : " (\(zone))") key=\(Self.keyName(keys.usage(d))) host=\(hostText) -> \(Self.text(reports))")
    }

    private func haptic(_ d: ClickerDirection) {
        switch d {
        case .next:
            nextHaptic.impactOccurred(intensity: 1.0)
        case .previous:
            // Two soft taps, so "back" feels different from "next" without looking.
            previousHaptic.impactOccurred(intensity: 0.8)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { [weak self] in
                MainActor.assumeIsolated { self?.previousHaptic.impactOccurred(intensity: 0.8) }
            }
        }
    }

    // MARK: - Pointer

    /// The pointer button went down. `method` / `host` default to the active host's profile.
    /// `realMotion`: start the gyro (false: the probe feeds synthetic samples).
    func pointerDown(method: LaserMethod? = nil, host: HostOS? = nil, realMotion: Bool = true, source: String = "button") {
        guard !state.isPointerHeld else { return }
        let m = method ?? currentMethod
        let os = host ?? currentHostOS
        let reports = state.pointerPressed(method: m, host: os)
        send(reports)
        air.settings = AirPointerSettings(sensitivity: currentAirSpeed)
        air.reset()
        holdStart = ProcessInfo.processInfo.systemUptime
        holdSource = source
        if settings.haptics { pointerHaptic.impactOccurred(intensity: 0.9) }
        Log.line(String(format: "CLICKER pointer press (%@) method=%@ hostOS=%@ host=%@ sensitivity=%.2f gain=%.0f counts/rad motionAuth=%@ -> %@",
                        source, m.rawValue, os.rawValue, hostText, currentAirSpeed, air.settings.gain, Self.authorizationText, Self.text(reports)))
        if realMotion { startMotion() }
    }

    /// The hold ends: finger lifted (`reason` "lift"), touch cancelled, or forced (app
    /// resigning, host change, mode off, screen gone). Sends the paired release, if any.
    func endHold(reason: String) {
        let wasHeld = state.isPointerHeld
        let method = state.hold?.method
        stopMotion()
        let reports = state.release()
        guard wasHeld else { return }
        send(reports)
        let st = air.stats
        let held = holdStart.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
        Log.line("CLICKER pointer release (\(reason); pressed by \(holdSource)) method=\(method?.rawValue ?? "?") host=\(hostText) -> \(Self.text(reports))")
        Log.line(String(format: "CLICKER motion held=%.2fs samples=%d (%.1f Hz over %.2fs) moving=%d sumDX=%d sumDY=%d maxRate=%.3f rad/s meanRate=%.4f rad/s invalid=%d",
                        held, st.samples, st.sampleRate, st.duration, st.movingSamples, st.sumDX, st.sumDY, st.maxRate, st.meanRate, st.invalid))
        holdStart = nil
        air.reset()
    }

    /// One motion sample (real or synthetic) → pointer motion for the active host.
    func feedMotion(rotationRate: Vector3, gravity: Vector3, timestamp: Double) {
        guard state.isPointerHeld else { return }
        let o = air.update(rotationRate: rotationRate, gravity: gravity, timestamp: timestamp)
        if o.dx != 0 || o.dy != 0 {
            peripheral.send([.move(dx: o.dx, dy: o.dy)])
        }
    }

    // MARK: - Device motion

    var motionAvailable: Bool { motion.isDeviceMotionAvailable }
    var gyroAvailable: Bool { motion.isGyroAvailable }

    /// `CMMotionManager.authorizationStatus` (new in the iOS 27.2 SDK; earlier systems have no
    /// authorization for device motion).
    static var authorizationText: String {
        if #available(iOS 27.2, *) {
            switch CMMotionManager.authorizationStatus {
            case .notDetermined: return "notDetermined"
            case .restricted: return "restricted"
            case .denied: return "denied"
            case .authorized: return "authorized"
            @unknown default: return "unknown(\(CMMotionManager.authorizationStatus.rawValue))"
            }
        }
        return "n/a (before iOS 27.2)"
    }

    /// Motion access is refused (the pointer cannot move).
    static var motionRefused: Bool {
        if #available(iOS 27.2, *) {
            let s = CMMotionManager.authorizationStatus
            return s == .denied || s == .restricted
        }
        return false
    }

    /// When the clicker screen appears: if motion access was never asked for, run device
    /// motion for a moment so that any permission prompt comes now, not at the first pointer
    /// press during a talk. Logs the status before and after.
    func prepareMotion(done: @escaping @MainActor () -> Void = {}) {
        let before = Self.authorizationText
        guard before == "notDetermined", !motionRunning else {
            Log.line("CLICKER motion authorization=\(before) available=\(motionAvailable) gyro=\(gyroAvailable)")
            done()
            return
        }
        warmupSamples = 0
        let saved = onRawSample
        onRawSample = { [weak self] t, w, g in self?.warmupSamples += 1; saved?(t, w, g) }
        startMotion()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self else { return }
            self.onRawSample = saved
            if !self.state.isPointerHeld { self.stopMotion() }
            Log.line("CLICKER motion warm-up: authorization \(before) -> \(Self.authorizationText), samples in 0.6 s=\(self.warmupSamples)")
            done()
        }
    }

    func startMotion() {
        guard !motionRunning else { return }
        guard motion.isDeviceMotionAvailable else {
            Log.line("CLICKER device motion not available — the pointer will not move")
            return
        }
        motionRunning = true
        motion.deviceMotionUpdateInterval = Self.motionInterval
        motion.startDeviceMotionUpdates(to: .main) { [weak self] m, error in
            // Plain values out of the (non-Sendable) CMDeviceMotion before hopping.
            let sample: (Double, Vector3, Vector3)? = m.map {
                ($0.timestamp, Vector3($0.rotationRate.x, $0.rotationRate.y, $0.rotationRate.z),
                 Vector3($0.gravity.x, $0.gravity.y, $0.gravity.z))
            }
            let err = error.map { "\($0)" }
            MainActor.assumeIsolated {
                guard let self else { return }
                if let err { Log.line("CLICKER device motion error: \(err)") }
                guard let (t, w, g) = sample else { return }
                self.onRawSample?(t, w, g)
                self.feedMotion(rotationRate: w, gravity: g, timestamp: t)
            }
        }
    }

    func stopMotion() {
        guard motionRunning else { return }
        motion.stopDeviceMotionUpdates()
        motionRunning = false
    }

    // MARK: - Helpers

    private func send(_ reports: [ClickerReport]) {
        for r in reports {
            switch r {
            case .keyboard(let k): peripheral.send(k)
            case .mouseButtons(let b): peripheral.send([.buttons(b)])
            }
        }
    }

    private var hostText: String {
        peripheral.activeHostID.map { "\(shortID($0)) \"\(hosts.displayName($0))\"" } ?? "none"
    }

    static func text(_ reports: [ClickerReport]) -> String {
        if reports.isEmpty { return "[] (nothing)" }
        return "[" + reports.map { r in
            switch r {
            case .keyboard(let k): OutgoingReport.keyboard(k).logText
            case .mouseButtons(let b): "mouse buttons=\(b.rawValue)"
            }
        }.joined(separator: ", ") + "]"
    }

    static func keyName(_ u: KeyUsage) -> String {
        switch u {
        case .rightArrow: "RightArrow"
        case .leftArrow: "LeftArrow"
        case .pageDown: "PageDown"
        case .pageUp: "PageUp"
        default: "\(u)"
        }
    }
}

// MARK: - UI text

extension LaserMethod {
    var title: String {
        switch self {
        case .powerPointToggle: "PowerPoint（切り替え）"
        case .controlLeftButton: "Ctrl＋左ボタン押しっぱなし"
        case .pointerOnly: "ポインタを動かすだけ"
        }
    }
}

extension SlideKeys {
    var title: String {
        switch self {
        case .arrows: "→ / ←"
        case .pages: "PageDown / PageUp"
        }
    }
}

#if DEBUG
// MARK: - No-send probe (`--clicker-probe`, Debug builds only)

/// Drives the clicker pipeline with synthetic input while `BLEPeripheral.dryRun` keeps every
/// input report away from CoreBluetooth (logged as `WOULD_SEND`). Then holds the pointer with
/// the real gyro for a few seconds (the phone lies still) and logs the sample rate, a few
/// samples and the motion that would have been sent.
@MainActor
final class ClickerProbe {
    let clicker: ClickerController
    let peripheral: BLEPeripheral

    init(clicker: ClickerController, peripheral: BLEPeripheral) {
        self.clicker = clicker
        self.peripheral = peripheral
    }

    func start() {
        Task { await run() }
    }

    private func sleep(_ s: Double) async { try? await Task.sleep(for: .milliseconds(Int(s * 1000))) }

    private func waitIdle() async {
        for _ in 0..<200 where !peripheral.isIdle { await sleep(0.01) }
    }

    private func run() async {
        guard peripheral.dryRun else {
            Log.line("CLICKER_PROBE refused: transport is not in dry-run mode")
            return
        }
        // Wait for a host so the routing (active host, subscriptions) is exercised too.
        for _ in 0..<150 where peripheral.activeHost?.inputs.contains(.keyboard) != true {
            await sleep(0.1)
        }
        await sleep(1.5)
        let before = peripheral.dryRunStats
        let real = peripheral.stats
        Log.line("CLICKER_PROBE begin dryRun=\(peripheral.dryRun) activeHost=\(peripheral.activeHostID?.uuidString ?? "none") inputs=\(peripheral.activeHost?.subscriptionText ?? "-") deviceMotionAvailable=\(clicker.motionAvailable) gyroAvailable=\(clicker.gyroAvailable) motionAuth=\(ClickerController.authorizationText) slideKeys=\(clicker.settings.slideKeys.rawValue)")

        // 1. Taps through the tap tracker (touch-up rule).
        var tracker = ClickerTapTracker()
        let taps: [(String, [(String, ClickerZone)])] = [
            ("tap upper half", [("began", .next), ("ended", .next)]),
            ("tap lower half", [("began", .previous), ("ended", .previous)]),
            ("slide from lower into upper half", [("began", .previous), ("moved", .next), ("ended", .next)]),
            ("lift over the pointer button", [("began", .next), ("moved", .outside), ("ended", .outside)]),
            ("cancelled touch", [("began", .next), ("cancelled", .next)]),
        ]
        for (i, (name, events)) in taps.enumerated() {
            var fired: ClickerDirection?
            for (kind, zone) in events {
                switch kind {
                case "began": tracker.began(i, in: zone)
                case "moved": tracker.moved(i, to: zone)
                case "ended": fired = tracker.ended(i, in: zone)
                default: tracker.cancelled(i)
                }
            }
            Log.line("CLICKER_PROBE \(name): \(events.map { "\($0.0)@\($0.1.rawValue)" }.joined(separator: " ")) -> \(fired?.rawValue ?? "nothing")")
            if let d = fired { clicker.slide(d, zone: "probe") }
            await waitIdle()
            await sleep(0.3)
        }

        // 2. PageDown / PageUp.
        let savedKeys = clicker.settings.slideKeys
        clicker.settings.slideKeys = .pages
        clicker.slide(.next, zone: "probe, PageDown setting")
        await waitIdle()
        clicker.slide(.previous, zone: "probe, PageUp setting")
        await waitIdle()
        clicker.settings.slideKeys = savedKeys
        await sleep(0.3)

        // 3. Pointer holds with a synthetic rotation, for each method / OS.
        let holds: [(LaserMethod, HostOS)] = [(.powerPointToggle, .macOS), (.powerPointToggle, .windows),
                                             (.controlLeftButton, .windows), (.pointerOnly, .macOS)]
        for (m, os) in holds {
            clicker.pointerDown(method: m, host: os, realMotion: false, source: "probe synthetic")
            await waitIdle()
            if m == .controlLeftButton { clicker.slide(.next, zone: "probe, during Ctrl hold") }
            await feedSynthetic()
            clicker.endHold(reason: "probe lift")
            await waitIdle()
            await sleep(0.4)
        }

        // 4. Forced release (as when the app resigns active during a hold).
        clicker.pointerDown(method: .powerPointToggle, host: .windows, realMotion: false, source: "probe forced")
        await sleep(0.2)
        clicker.endHold(reason: "probe: forced (as app resigning active)")
        await waitIdle()
        let afterForced = peripheral.dryRunStats
        clicker.endHold(reason: "probe: second end after release")
        await waitIdle()
        let extra = peripheral.dryRunStats - afterForced
        Log.line("CLICKER_PROBE second end after release: held=\(clicker.isPointerHeld) reports=\(extra.keyboardReports + extra.mouseReports) (must be 0)")
        await sleep(0.4)

        // 5. Real gyro, phone at rest.
        var samples = 0
        var first: [String] = []
        var t0: Double?
        var tLast = 0.0
        var maxW = 0.0
        clicker.onRawSample = { t, w, g in
            samples += 1
            if t0 == nil { t0 = t }
            tLast = t
            maxW = max(maxW, w.length)
            if first.count < 5 {
                first.append(String(format: "t=%.4f w=(%.4f,%.4f,%.4f) g=(%.3f,%.3f,%.3f)", t - (t0 ?? t), w.x, w.y, w.z, g.x, g.y, g.z))
            }
        }
        let restBefore = peripheral.dryRunStats
        clicker.pointerDown(method: .pointerOnly, realMotion: true, source: "probe real gyro at rest")
        await sleep(4)
        clicker.endHold(reason: "probe lift")
        clicker.onRawSample = nil
        await waitIdle()
        let restDelta = peripheral.dryRunStats - restBefore
        let span = tLast - (t0 ?? tLast)
        Log.line(String(format: "CLICKER_PROBE real gyro: samples=%d span=%.2fs rate=%.1f Hz max|w|=%.4f rad/s; would-send mouse reports=%d sumX=%d sumY=%d",
                        samples, span, span > 0 ? Double(samples - 1) / span : 0, maxW, restDelta.mouseReports, restDelta.sumX, restDelta.sumY))
        for f in first { Log.line("CLICKER_PROBE sample \(f)") }

        let d = peripheral.dryRunStats - before
        let r = peripheral.stats - real
        Log.line("CLICKER_PROBE would-send totals: \(d.text)")
        Log.line("CLICKER_PROBE handed to CoreBluetooth during the probe: mouse=\(r.mouseReports) keyboard=\(r.keyboardReports) consumer=\(r.consumerReports) (baselines \(r.baselines))")
        Log.line("CLICKER_PROBE end")
    }

    /// 1.2 s at 100 Hz, phone flat: turn right, tilt up, turn left, tilt down (≈ net zero).
    private func feedSynthetic() async {
        let flat = Vector3(0, 0, -1)
        let phases: [(String, Vector3)] = [("turn right", Vector3(0, 0, -0.6)), ("tilt up", Vector3(0.6, 0, 0)),
                                          ("turn left", Vector3(0, 0, 0.6)), ("tilt down", Vector3(-0.6, 0, 0))]
        var t = ProcessInfo.processInfo.systemUptime
        for (_, w) in phases {
            for _ in 0..<30 {
                clicker.feedMotion(rotationRate: w, gravity: flat, timestamp: t)
                t += ClickerController.motionInterval
                await sleep(ClickerController.motionInterval)
            }
        }
        // Come to rest so the smoothing tail is flushed.
        for _ in 0..<10 {
            clicker.feedMotion(rotationRate: .zero, gravity: flat, timestamp: t)
            t += ClickerController.motionInterval
            await sleep(ClickerController.motionInterval)
        }
    }
}
#endif
