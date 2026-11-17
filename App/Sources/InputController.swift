import Foundation
import UIKit
import HIDCore

/// Touches → `PointerEngine` → `BLEPeripheral` (whose `ReportQueue` coalesces and paces).
@MainActor
final class InputController {
    let peripheral: BLEPeripheral
    let settings: AppSettings
    private var engine: PointerEngine
    /// Separate engine for synthetic self-test touches, with fixed settings (defaults, inertia
    /// off unless a phase asks for it) so the scripts' net-zero property does not depend on the
    /// user's settings.
    private var selfTestEngine = PointerEngine(settings: InputController.selfTestDefaults)
    static var selfTestDefaults: PointerSettings {
        var s = PointerSettings()
        s.scrollInertia = false
        return s
    }
    /// Drives inertial scrolling (`PointerEngine.advance(to:)`) once per frame while active.
    private var displayLink: CADisplayLink?
    /// Scroll sent by self-test inertia (added to the phase totals by the runner).
    private(set) var selfTestInertiaTotals = ActionTotals()
    var selfTestInertiaActive: Bool { selfTestEngine.isInertiaActive }
    private let haptic = UIImpactFeedbackGenerator(style: .light)
    private let logReports: Bool
    /// True while a self-test phase plays: real touches and on-screen buttons are ignored so
    /// the phase's report counts contain only synthetic input.
    private(set) var selfTestPlaying = false
    private(set) var ignoredRealEvents = 0
    /// Released together with the pointer when a self-test phase starts.
    weak var keyboard: KeyboardController?

    init(peripheral: BLEPeripheral, settings: AppSettings, logReports: Bool) {
        self.peripheral = peripheral
        self.settings = settings
        self.logReports = logReports
        engine = PointerEngine(settings: settings.pointerSettings(for: nil))
        // Hooks on `peripheral` are wired by AppModel (one owner, so none is overwritten).
    }

    /// Apply the active host's pointer settings (called on every change, also while a
    /// slider is dragged). Logged only when asked, to keep slider drags out of the log.
    func applySettings(_ s: PointerSettings, log: Bool = true) {
        guard s != engine.settings else { return }
        engine.settings = s
        if log { Log.line(String(format: "POINTER_SETTINGS sensitivity=%.2f scrollPointsPerUnit=%.2f acceleration=%.2f scrollAcceleration=%.2f (%.0f…%.0f pt/s) inertia=%@ (tau=%.2fs min=%.0f stop=%.0f pt/s) invertScroll=%@ tapToClick=%@",
                                 s.sensitivity, s.scrollPointsPerUnit, s.acceleration, s.scrollAcceleration,
                                 s.scrollAccelerationLowSpeed, s.scrollAccelerationHighSpeed, "\(s.scrollInertia)",
                                 s.inertiaTimeConstant, s.inertiaMinSpeed, s.inertiaStopSpeed, "\(s.invertScroll)", "\(s.tapToClick)")) }
    }

    var currentSettings: PointerSettings { engine.settings }

    func noteIgnoredRealEvent() { ignoredRealEvents += 1 }

    // MARK: Real input

    func handleTouches(_ events: [TouchEvent]) {
        guard !events.isEmpty else { return }
        if selfTestPlaying { ignoredRealEvents += events.count; return }
        let hadInertia = engine.isInertiaActive
        emit(engine.handle(events))
        if logReports, hadInertia, !engine.isInertiaActive { Log.line("INERTIA stopped by touch") }
        if logReports, engine.isInertiaActive, !hadInertia, events.contains(where: { $0.phase == .ended }) { Log.line("INERTIA start") }
        updateInertiaDriver()
    }

    // MARK: Inertia

    private func updateInertiaDriver() {
        let needed = engine.isInertiaActive || selfTestEngine.isInertiaActive
        if needed, displayLink == nil {
            let link = CADisplayLink(target: DisplayLinkProxy { [weak self] in self?.inertiaTick() }, selector: #selector(DisplayLinkProxy.tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else if !needed, let link = displayLink {
            link.invalidate()
            displayLink = nil
        }
    }

    private func inertiaTick() {
        let now = CACurrentMediaTime()   // same clock as UITouch.timestamp and systemUptime
        if engine.isInertiaActive {
            emit(engine.advance(to: now))
            if logReports, !engine.isInertiaActive { Log.line("INERTIA end") }
        }
        if selfTestEngine.isInertiaActive {
            let actions = selfTestEngine.advance(to: now)
            for a in actions { selfTestInertiaTotals.add(a); Log.line("ACTION inertia \(a.logText)") }
            peripheral.send(actions)
        }
        updateInertiaDriver()
    }

    func setButton(_ button: MouseButtons, pressed: Bool) {
        if selfTestPlaying { ignoredRealEvents += 1; return }
        emit(engine.setButton(button, pressed: pressed))
    }

    /// Start or stop ignoring real input for a self-test phase. Starting releases whatever the
    /// real engine holds (its touches are forgotten, so later events of those touches are ignored).
    func setSelfTestPlaying(_ playing: Bool) {
        if playing {
            let actions = engine.reset()
            if !actions.isEmpty { Log.line("INPUT_RESET (self-test phase start) -> \(actions.map(\.logText))") }
            peripheral.send(actions)
            keyboard?.releaseAll(reason: "self-test phase start")
            ignoredRealEvents = 0
        }
        selfTestPlaying = playing
    }

    /// Release everything (app leaves the foreground, touches cancelled, host change).
    func reset(reason: String) {
        let actions = engine.reset() + selfTestEngine.reset()
        if !actions.isEmpty { Log.line("INPUT_RESET (\(reason)) -> \(actions.map(\.logText))") }
        peripheral.send(actions)
        updateInertiaDriver()
    }

    private func emit(_ actions: [PointerAction]) {
        guard !actions.isEmpty else { return }
        if settings.haptics, actions.contains(where: { if case .buttons(let b) = $0 { !b.isEmpty } else { false } }) {
            haptic.impactOccurred()
        }
        if logReports, actions.contains(where: { if case .buttons = $0 { true } else { false } }) {
            Log.line("ACTION \(actions.map(\.logText))")
        }
        peripheral.send(actions)
    }

    // MARK: Self-test input

    /// Feeds one synthetic touch through the engine. Returns false (and sends nothing) if the
    /// engine produced a button action, which the self-test must never send (design §11.3).
    /// Settings for the next self-test phase (nil: `selfTestDefaults`); clears the inertia totals.
    func prepareSelfTestPhase(settings: PointerSettings?) {
        _ = selfTestEngine.reset()
        selfTestEngine.settings = settings ?? Self.selfTestDefaults
        selfTestInertiaTotals = ActionTotals()
        updateInertiaDriver()
    }

    func feedSelfTest(_ event: TouchEvent, totals: inout ActionTotals, logActions: Bool) -> Bool {
        let actions = selfTestEngine.handle(event)
        defer { updateInertiaDriver() }
        if actions.contains(where: { if case .buttons = $0 { true } else { false } }) {
            Log.line("SELFTEST_ABORT engine produced a button action \(actions.map(\.logText)) — not sent")
            _ = selfTestEngine.reset()
            return false
        }
        for a in actions {
            totals.add(a)
            if logActions { Log.line("ACTION \(a.logText)") }
        }
        peripheral.send(actions)
        return true
    }
}

/// `--selftest=<names>` driver: 2 s after the mouse input report is subscribed, plays the
/// scripted touches in real time through `InputController.feedSelfTest`, and the key tests
/// (`keys`, `text`, see KeySelfTest.swift) through `KeyboardController`. Key tests run once
/// per process, never again on a re-subscribe or `--repeat`.
@MainActor
final class SelfTestRunner {
    let names: [String]
    let repeatSeconds: Double
    let options: LaunchOptions
    let input: InputController
    let keyboard: KeyboardController
    let peripheral: BLEPeripheral
    /// Key tests already run (or refused) in this process.
    var keyTestsDone: Set<String> = []
    static let keyTestNames: Set<String> = ["keys", "text", "kana", "lang", "compose"]
    private var lastSubscribe: Date?
    private var lastRunStart: Date?
    private var lastRunEnd: Date?
    private var loopRunning = false
    private var runs = 0

    init(names: [String], options: LaunchOptions, input: InputController, keyboard: KeyboardController, peripheral: BLEPeripheral) {
        self.names = names
        self.repeatSeconds = options.repeatSeconds
        self.options = options
        self.input = input
        self.keyboard = keyboard
        self.peripheral = peripheral
        for n in names where SelfTestScript.phases(for: n, origin: .zero).isEmpty && !Self.keyTestNames.contains(n) {
            Log.line("SELFTEST unknown name '\(n)' (known: pointer, inertia, burst, keys, text, kana, lang, compose)")
        }
    }

    private var needsKeyboard: Bool { names.contains { Self.keyTestNames.contains($0) } }
    private var onlyKeyTestsLeft: Bool { names.allSatisfy { keyTestsDone.contains($0) } }

    func mouseSubscribed() {
        lastSubscribe = Date()
        guard !loopRunning else { return }
        loopRunning = true
        Task { await loop() }
    }

    private func loop() async {
        while true {
            try? await Task.sleep(for: .milliseconds(100))
            guard let sub = lastSubscribe, Date().timeIntervalSince(sub) >= 2 else { continue }
            guard peripheral.activeHost?.inputs.contains(.mouse) == true else { continue }
            if needsKeyboard, peripheral.activeHost?.inputs.contains(.keyboard) != true { continue }
            if onlyKeyTestsLeft { return }
            let newSubscribe = lastRunStart.map { sub > $0 } ?? true
            let repeatDue = repeatSeconds > 0 && (lastRunEnd.map { Date().timeIntervalSince($0) >= repeatSeconds } ?? true)
            guard newSubscribe || repeatDue else { continue }
            lastRunStart = Date()
            // Synthetic input must land on the intended host only: either the pinned central is
            // active, or exactly one central is subscribed to the mouse report.
            let mouseHosts = peripheral.hosts.filter { $0.inputs.contains(.mouse) }
            let pinnedOK = peripheral.pinnedCentral.map { $0 == peripheral.activeHostID } ?? (mouseHosts.count == 1)
            guard pinnedOK else {
                Log.line("SELFTEST skipped: active=\(peripheral.activeHostID?.uuidString ?? "none") pinned=\(peripheral.pinnedCentral?.uuidString ?? "none") mouse subscribers=\(mouseHosts.map(\.id.uuidString))")
                lastRunEnd = Date()
                continue
            }
            await run()
            lastRunEnd = Date()
        }
    }

    private func run() async {
        runs += 1
        let n = runs
        let host = peripheral.activeHostID.map(\.uuidString) ?? "none"
        Log.line("SELFTEST #\(n) begin names=\(names) host=\(host) (engine: default PointerSettings)")
        for name in names {
            if Self.keyTestNames.contains(name) {
                guard !keyTestsDone.contains(name) else {
                    Log.line("SELFTEST #\(n) \(name) skipped: key tests run once per process")
                    continue
                }
                keyTestsDone.insert(name)
                let ok: Bool
                switch name {
                case "keys": ok = await runKeys(run: n)
                case "kana": ok = await runKana(run: n)
                case "lang": ok = await runLang(run: n)
                case "compose": ok = await runCompose(run: n)
                default: ok = await runText(run: n)
                }
                if !ok {
                    Log.line("SELFTEST #\(n) aborted")
                    return
                }
                try? await Task.sleep(for: .milliseconds(800))
                continue
            }
            for phase in SelfTestScript.phases(for: name, origin: Vector2(200, 400)) {
                guard await runPhase(phase, run: n) else {
                    Log.line("SELFTEST #\(n) aborted")
                    return
                }
                try? await Task.sleep(for: .milliseconds(800))
            }
        }
        Log.line("SELFTEST #\(n) end")
    }

    private func runPhase(_ phase: SelfTestPhase, run n: Int) async -> Bool {
        input.setSelfTestPlaying(true)
        defer { input.setSelfTestPlaying(false) }
        // Let earlier (real) reports leave the queue so they are not counted in this phase.
        for _ in 0..<100 where !peripheral.isIdle { try? await Task.sleep(for: .milliseconds(10)) }
        let before = peripheral.stats
        peripheral.resetLongestBlock()
        var totals = ActionTotals()
        input.prepareSelfTestPhase(settings: phase.settings)
        let clock = ContinuousClock()
        var start = clock.now
        var base = ProcessInfo.processInfo.systemUptime
        let logActions = phase.touches.count <= 400
        Log.line("PHASE #\(n) \(phase.name) begin events=\(phase.touches.count) span=\(String(format: "%.3f", phase.touches.last?.time ?? 0))s playback=\(phase.playbackSpeed)x")
        var lateMax = 0.0
        for st in phase.touches {
            if st.event.phase == .began, input.selfTestInertiaActive {
                // A new touch would stop the inertia and break the net-zero symmetry: wait for
                // it to end, then shift the rest of the script by the wait.
                let waitStart = clock.now
                while input.selfTestInertiaActive, clock.now - waitStart < .seconds(3) {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                let waited = clock.now - waitStart
                start = start + waited
                base += ms(waited) / 1000
                Log.line("PHASE #\(n) \(phase.name) waited \(String(format: "%.0f", ms(waited))) ms for inertia to end before the next touch")
            }
            let due = start + .microseconds(Int((st.time / phase.playbackSpeed * 1_000_000).rounded()))
            if clock.now < due { try? await Task.sleep(until: due, tolerance: .zero, clock: clock) }
            lateMax = max(lateMax, ms(clock.now - due))
            var e = st.event
            e.timestamp = base + st.time
            guard input.feedSelfTest(e, totals: &totals, logActions: logActions) else { return false }
        }
        var fedAt = clock.now
        while input.selfTestInertiaActive, clock.now - fedAt < .seconds(3) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if input.selfTestInertiaActive {
            Log.line("PHASE #\(n) \(phase.name) inertia still active after 3 s — resetting")
            input.prepareSelfTestPhase(settings: nil)
        }
        fedAt = clock.now
        totals.merge(input.selfTestInertiaTotals)
        // Let the queue empty (back-pressure may delay it), then a little longer.
        while !peripheral.isIdle, clock.now - fedAt < .seconds(3) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let drainMs = ms(clock.now - fedAt)
        try? await Task.sleep(for: .milliseconds(200))
        let d = peripheral.stats - before
        Log.line("PHASE #\(n) \(phase.name) actions: \(totals) (of which inertia: \(input.selfTestInertiaTotals))")
        Log.line("PHASE #\(n) \(phase.name) sent: \(d.text)")
        Log.line(String(format: "PHASE #%d %@ timing: feedDuration=%.3fs maxFeedLate=%.1fms drainAfterLastEvent=%.1fms idle=%@",
                        n, phase.name, ms(fedAt - start) / 1000,
                        lateMax, drainMs, "\(peripheral.isIdle)"))
        let net = d.sumX == 0 && d.sumY == 0 && d.sumWheel == 0 && d.sumPan == 0 && d.mouseWithButtons == 0
        Log.line("PHASE #\(n) \(phase.name) end netZero=\(net) buttonsSent=\(d.mouseWithButtons) realTouchEventsIgnored=\(input.ignoredRealEvents)")
        return true
    }
}

/// CADisplayLink retains its target; this proxy keeps the controller out of that cycle.
@MainActor
private final class DisplayLinkProxy: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func tick() { action() }
}

private func ms(_ d: Duration) -> Double {
    Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}
