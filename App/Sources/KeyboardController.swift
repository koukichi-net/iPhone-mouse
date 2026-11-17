import Foundation
import UIKit
import Observation
import HIDCore

/// Key panel, media keys and text field → `KeyboardState` / `TextTyper` → `BLEPeripheral`
/// (whose `ReportQueue` paces keyboard and consumer reports). Design §8.3, §8.4.
@MainActor
@Observable
final class KeyboardController {
    /// Snapshot of the panel state for the UI (changes only on user actions).
    private(set) var modifierStates: [PanelModifier: LatchState] = [:]
    private(set) var heldModifiers: Set<PanelModifier> = []
    /// Brief indication of characters that could not be sent (cleared after a moment).
    private(set) var skippedNotice: String?
    /// The last characters sent from the text field (for the echo line).
    private(set) var echo: String = ""
    /// Characters still being typed out from a paste.
    private(set) var pasteRemaining = 0
    /// What the text field assumes about the host's Japanese input (かな / 英数 / unknown).
    private(set) var assumedHostMode: HostIMEMode = .unknown
    /// Language of the iOS keyboard in use (`ja-JP`, `en-US`, … or nil).
    private(set) var keyboardLanguage: String?
    /// What the capture field holds now (composition included); empty when cleared.
    private(set) var fieldText: String = ""
    /// The last text committed with the Japanese keyboard (for the echo line).
    private(set) var capturedEcho: String = ""
    /// 接続先で確認（改行で確定）: shown after a candidate was committed on the phone.
    private(set) var hint: String?
    /// Brief echo of arrow keys sent by the space-bar cursor gesture (「↓×2」).
    private(set) var arrowNotice: String?

    @ObservationIgnored let peripheral: BLEPeripheral
    @ObservationIgnored private weak var input: InputController?
    @ObservationIgnored private var state = KeyboardState()
    /// Separate state for self-test input (real input is ignored while a phase plays).
    @ObservationIgnored private var selfTestState = KeyboardState()
    @ObservationIgnored var keyMap: KeyMap = KeyMap(layout: .jis, host: .macOS)
    @ObservationIgnored var haptics = true
    @ObservationIgnored private let haptic = UIImpactFeedbackGenerator(style: .light)
    @ObservationIgnored private let logReports: Bool
    @ObservationIgnored private var consumerDown: ConsumerUsage?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// Text field: kana → romaji and automatic かな / 英数 (design §8.4).
    @ObservationIgnored private var router = TextEntryRouter()
    @ObservationIgnored var autoIMESwitch = true { didSet { router.autoSwitch = autoIMESwitch } }
    /// Steps waiting for the pause after a かな / 英数 key (the host switches its input source
    /// asynchronously; a letter sent too soon lands in the old mode).
    @ObservationIgnored private var pendingSteps: [TextEntryRouter.Step] = []
    @ObservationIgnored private var holdUntil: Double = 0
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var mirrorTask: Task<Void, Never>?
    @ObservationIgnored private var hintTask: Task<Void, Never>?
    /// `--selftest=compose`: mirror events pass the gate, and every step must satisfy this
    /// check or the test aborts (nothing more is sent).
    @ObservationIgnored var composeSelfTestGuard: ((TextEntryRouter.Step) -> Bool)?
    @ObservationIgnored private(set) var composeSelfTestAborted = false
    @ObservationIgnored private var savedAutoSwitch = true
    /// 空白キー長押しのカーソル移動を矢印キーとして送る (cursor pad, Controls.swift).
    @ObservationIgnored var cursorPadEnabled = true
    @ObservationIgnored private var arrowQueue = ArrowStepQueue()
    @ObservationIgnored private var arrowTask: Task<Void, Never>?
    @ObservationIgnored private var arrowNoticeTask: Task<Void, Never>?
    static let hintText = "接続先で確認（改行で確定）"
    /// Seconds from queuing かな / 英数 to the next key of the text field. Measured on this Mac
    /// (macOS 27.2, 2026-11-17): the input source changed ~250 ms after the かな key-down
    /// arrived (ABC → ひらがな) and ~60 ms after 英数. Plus the key's own pacing (press ≥ 35 ms,
    /// release ≥ 15 ms) and ~30 ms of BLE latency.
    static func imeSwitchPause(_ u: KeyUsage) -> Double { u == .lang1 ? 0.4 : 0.2 }

    init(peripheral: BLEPeripheral, input: InputController, logReports: Bool) {
        self.peripheral = peripheral
        self.input = input
        self.logReports = logReports
    }

    var capsLockOn: Bool { peripheral.leds.contains(.capsLock) }

    // MARK: - Panel (real input)

    private func gate() -> Bool {
        if let input, input.selfTestPlaying { input.noteIgnoredRealEvent(); return false }
        return true
    }

    func modifierDown(_ m: PanelModifier) {
        guard gate() else { return }
        tick()
        send(state.modifierDown(m, at: now()), "modifier \(m.rawValue) down")
    }

    func modifierUp(_ m: PanelModifier) {
        guard gate() else { return }
        send(state.modifierUp(m, at: now()), "modifier \(m.rawValue) up")
    }

    func keyDown(_ usage: KeyUsage) {
        guard gate() else { return }
        tick()
        if usage == .lang1 || usage == .lang2 {
            // The user set the host IME by hand: the mode is unknown again, and this press
            // counts as the last LANG key (no automatic double press right after it).
            router.noteManualIMEKey(usage, at: now())
            syncHostMode()
            Log.line("TEXTCAP panel key \(usage == .lang1 ? "LANG1 (かな)" : "LANG2 (英数)") -> host mode reset to unknown")
        }
        send(state.keyDown(usage), "key \(usage) down")
    }

    func keyUp(_ usage: KeyUsage) {
        guard gate() else { return }
        send(state.keyUp(usage), "key \(usage) up")
    }

    func mediaDown(_ usage: ConsumerUsage) {
        guard gate() else { return }
        tick()
        consumerDown = usage
        peripheral.send(ConsumerReport(usage))
        if logReports { Log.line("KEYPANEL media \(usage) down") }
    }

    func mediaUp(_ usage: ConsumerUsage) {
        guard gate(), consumerDown == usage else { return }
        consumerDown = nil
        peripheral.send(ConsumerReport.released)
        if logReports { Log.line("KEYPANEL media \(usage) up") }
    }

    // MARK: - Text field

    /// Every event of the capture field (`CaptureTextView`). Returns the outcome for its
    /// `TEXTCAP` line.
    func handleCapture(_ event: CaptureEvent, language: String?) -> String? {
        if LaunchOptions.current.textCapProbe {
            if case .arrows(let steps) = event { return cursorPadArrows(steps) }
            return "probe: not routed, nothing sent"
        }
        switch event {
        case .arrows(let steps): return cursorPadArrows(steps)
        case .insert(let s): return textInsert(s, language: language)
        case .delete: return textDelete(language: language)
        case .mirror(let e): return mirrorEvent(e, language: language)
        case .focus:
            router.forgetHostState(reason: "text field focus")
            router.mirrorReset(phoneComposing: false)
            syncHostMode()
            return "host mode reset to unknown (text field focus)"
        case .focusLost(let composing):
            router.mirrorReset(phoneComposing: composing)
            return "mirror reset, nothing sent (focus lost\(composing ? " while composing" : ""))"
        case .cleared(let s):
            capturedEcho = s.replacingOccurrences(of: "\n", with: "⏎")
            if capturedEcho.count > 40 { capturedEcho = String(capturedEcho.suffix(40)) }
            return nil
        }
    }

    func noteFieldText(_ s: String) {
        if s != fieldText { fieldText = s }
    }

    // MARK: Cursor pad (space-bar cursor gesture → arrow keys)

    /// Arrow steps from the cursor pad: queued (bounded per direction, opposite steps cancel)
    /// and pressed one at a time when the keyboard reports are idle, through the panel's
    /// `KeyboardState` (latched / locked / held modifiers apply as for the panel's arrows). The
    /// mirror state is left alone: with an uncommitted conversion on the host, the arrows pick
    /// candidates / segments there. No かな / 英数. `--textcap-probe`: logged, never sent.
    private func cursorPadArrows(_ steps: [ArrowSteps]) -> String {
        let probe = LaunchOptions.current.textCapProbe
        if !probe {
            guard cursorPadEnabled else { return "setting off (空白キー長押しで矢印キー): nothing sent" }
            guard composeSelfTestGuard == nil, gate() else { return "ignored (self-test playing)" }
        }
        var r = ArrowStepQueue.AddResult()
        for s in steps {
            let a = arrowQueue.add(s)
            r.added += a.added
            r.cancelled += a.cancelled
            r.dropped += a.dropped
        }
        var out = probe ? "would send \(steps.summary) (probe: nothing sent)" : "arrows \(steps.summary)"
        out += ": \(r.added) queued"
        if r.cancelled > 0 { out += ", \(r.cancelled) cancelled against opposite pending" }
        if r.dropped > 0 { out += ", \(r.dropped) DROPPED (cap \(arrowQueue.cap) per direction)" }
        out += "; pending \(arrowQueue.summary)"
        let m = router.mirror
        if m.hostComposing {
            out += " [host assumed composing (reading=\(m.hostReading.count) converted=\(m.converted) detached=\(m.detached)): arrows go to its conversion; mirror kept, no LANG]"
        }
        let mods = state.pending
        if !mods.isEmpty { out += " [modifiers \(String(format: "0x%02X", mods.rawValue)) apply]" }
        if r.added > 0 { pumpArrows() }
        arrowNotice = steps.summary
        arrowNoticeTask?.cancel()
        arrowNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            self?.arrowNotice = nil
        }
        return out
    }

    /// The keyboard pipeline can take the next arrow: nothing of the text field waiting
    /// (かな/英数 pause, mirror events) and the report queue empty.
    private var arrowReady: Bool {
        peripheral.isIdle && pendingSteps.isEmpty && now() >= holdUntil && !router.mirror.hasPending && mirrorTask == nil
    }

    private func pumpArrows() {
        guard arrowTask == nil else { return }
        arrowTask = Task { [weak self] in
            while true {
                guard let self, !Task.isCancelled else { return }
                guard !self.arrowQueue.isEmpty else {
                    self.arrowTask = nil
                    return
                }
                if LaunchOptions.current.textCapProbe {
                    let d = self.arrowQueue.next()!
                    Log.line("CURSORPAD would press \(d.symbol) (probe: nothing sent); pending \(self.arrowQueue.summary)")
                    try? await Task.sleep(for: .milliseconds(50))
                    continue
                }
                if self.arrowReady, let d = self.arrowQueue.next() {
                    let r = self.state.tap(d.usage)
                    self.peripheral.send(r)
                    Log.line("CURSORPAD pressed \(d.symbol) -> \(r.map { OutgoingReport.keyboard($0).logText }); pending \(self.arrowQueue.summary)")
                    self.syncUI()
                }
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
    }

    /// The edge repeat adds a step only while fewer than this many of its direction wait, so
    /// it follows the key pacing (~20 keys/s) instead of building a backlog (in a corner two
    /// directions repeat at once; 2 × 16.7/s would exceed the pacing).
    static let edgeRepeatMaxPending = 2

    /// One more edge-repeat arrow of `d` may be queued (the edge repeat skips its tick otherwise).
    func arrowRoom(_ d: ArrowDirection) -> Bool {
        (cursorPadEnabled || LaunchOptions.current.textCapProbe)
            && arrowQueue.count(d) < min(arrowQueue.cap, Self.edgeRepeatMaxPending)
    }

    private func dropArrows(reason: String) {
        CaptureTextView.current?.stopEdgeRepeat(reason: reason)
        arrowTask?.cancel()
        arrowTask = nil
        let n = arrowQueue.removeAll()
        if n > 0 { Log.line("CURSORPAD dropped \(n) pending arrow(s) (\(reason))") }
    }

    // MARK: Composition mirroring (CompositionMirror, design §8.4 step 2)

    /// A Japanese-path event: queued; processed when stable (`flushMirror`).
    private func mirrorEvent(_ e: CompositionMirror.Event, language: String?) -> String {
        noteLanguage(language, source: "event")
        guard composeSelfTestGuard != nil || gate() else { return "ignored (self-test playing)" }
        var event = e
        var note = ""
        if case .ended(let c, _) = e {
            let reading = JapaneseReading.reading(of: c)
            event = .ended(committed: c, reading: reading)
            note = " reading=\(Log.q(reading ?? "nil"))"
        }
        router.mirrorReceive(event, at: now())
        scheduleMirrorFlush()
        return "mirror \(Self.eventName(event))\(note) queued"
    }

    private static func eventName(_ e: CompositionMirror.Event) -> String {
        switch e {
        case .marked: "marked"
        case .ended: "commit"
        case .inserted: "insert"
        case .deleted: "delete"
        }
    }

    private func scheduleMirrorFlush() {
        guard let due = router.mirror.nextFlushTime else { return }
        mirrorTask?.cancel()
        mirrorTask = Task { [weak self] in
            let wait = max(0, due - ProcessInfo.processInfo.systemUptime)
            try? await Task.sleep(for: .milliseconds(Int(wait * 1000) + 1))
            guard let self, !Task.isCancelled else { return }
            self.mirrorTask = nil
            self.flushMirror()
        }
    }

    /// Sends the keys for the stable mirror events; one MIRROR line per event.
    func flushMirror() {
        let plan = router.mirrorFlush(at: now())
        for m in plan.mirror { Log.line(m.line(redact: !Log.recordTyping)) }
        if !plan.imeNotes.isEmpty {
            let notes = plan.imeNotes.joined(separator: "; ")
            Log.line("MIRROR host mode: " + Log.notes(notes))
        }
        if !plan.unsendable.isEmpty { noteSkipped(plan.unsendable.map(\.character)) }
        if !plan.steps.isEmpty {
            if !pendingSteps.isEmpty { Log.line("MIRROR queued behind \(pendingSteps.count) step(s)") }
            run(plan.steps)
        }
        if plan.hint { showHint() }
        if plan.steps.contains(.type("\n")) { clearHint() }
        if router.mirror.hasPending { scheduleMirrorFlush() }
        syncHostMode()
    }

    private func showHint() {
        hint = Self.hintText
        hintTask?.cancel()
        hintTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.hint = nil
        }
    }

    private func clearHint() {
        hintTask?.cancel()
        hint = nil
    }

    /// The ASCII path is about to send keys (英数 first when needed): whatever the host held
    /// uncommitted from the Japanese path is committed or typed into by them, so the mirror
    /// must not assume it any more (else the next composition would skip its かな).
    private func leaveComposition() {
        guard router.mirror.hostComposing, !(CaptureTextView.current?.composing ?? false) else { return }
        router.mirrorReset(phoneComposing: false)
        Log.line("MIRROR reset (ASCII path typing), nothing sent")
    }

    /// Forget the mirror state without sending (resets).
    private func resetMirror(reason: String) {
        mirrorTask?.cancel()
        mirrorTask = nil
        let composing = CaptureTextView.current?.composing ?? false
        router.mirrorReset(phoneComposing: composing)
        Log.line("MIRROR reset (\(reason)), nothing sent\(composing ? "; phone composition ignored until it ends" : "")")
    }

    /// A non-Japanese keyboard typed `text`: ASCII to the host (with 英数 asserted first when
    /// needed); unsendable characters (emoji, …) are skipped and briefly shown.
    private func textInsert(_ text: String, language: String?) -> String {
        guard gate() else { return "ignored (self-test playing)" }
        noteLanguage(language, source: "event")
        leaveComposition()
        let mode = KeyboardInputMode(primaryLanguage: language)
        let before = router.hostMode
        let plan = router.insert(text, keyboard: mode, at: now())
        var line = "\(Log.recordTyping ? "(\(scalarText(text))) " : "")mode=\(mode) host=\(before.rawValue)"
        if router.hostMode != before { line += "→\(router.hostMode.rawValue)" }
        let langs = plan.imeKeys.map { $0 == .lang1 ? "LANG1" : "LANG2" }
        line += " → " + (plan.steps.isEmpty ? "nothing" : "sent \(Log.q(plan.typedText))")
        if !langs.isEmpty { line += " with \(langs.joined(separator: ",")) before" }
        if !plan.imeNotes.isEmpty, Log.recordTyping { line += " [" + plan.imeNotes.joined(separator: "; ") + "]" }
        if !plan.unsendable.isEmpty {
            line += " | unsendable " + (Log.recordTyping
                ? plan.unsendable.map { "\($0.character)(\($0.reason))" }.joined(separator: " ")
                : plan.unsendable.map { "(\($0.reason))" }.joined(separator: " "))
        }
        if !plan.approximations.isEmpty {
            line += " | approx " + (Log.recordTyping
                ? plan.approximations.map { "\($0.character)→\($0.keys.debugDescription)" }.joined(separator: " ")
                : "\(plan.approximations.count)")
        }
        if !pendingSteps.isEmpty { line += " (queued behind \(pendingSteps.count) step(s))" }
        run(plan.steps)
        let sent = String(text.enumerated().filter { e in !plan.unsendable.contains { $0.characterOffset == e.offset } }.map(\.element))
        appendEcho(sent)
        if !plan.unsendable.isEmpty { noteSkipped(plan.unsendable.map(\.character)) }
        syncHostMode()
        syncUI()
        return line
    }

    /// A non-Japanese keyboard's delete key: Backspace, unless the deleted phone character was
    /// never sent (see `TextEntryRouter`).
    private func textDelete(language: String?) -> String {
        guard gate() else { return "ignored (self-test playing)" }
        noteLanguage(language, source: "event")
        leaveComposition()
        let mode = KeyboardInputMode(primaryLanguage: language)
        let plan = router.deleteBackward(keyboard: mode, at: now())
        var line = "mode=\(mode) → \(plan.steps.isEmpty ? "nothing (that character was never sent)" : plan.imeKeys.isEmpty ? "Backspace" : "Backspace with LANG2 before")"
        if !plan.imeNotes.isEmpty { line += " [" + Log.notes(plan.imeNotes.joined(separator: "; ")) + "]" }
        if !pendingSteps.isEmpty { line += " (queued behind \(pendingSteps.count) step(s))" }
        run(plan.steps)
        if !echo.isEmpty { echo.removeLast() }
        syncHostMode()
        syncUI()
        return line
    }

    /// Forget the host's IME mode (app back in the foreground).
    func resetHostIME(reason: String) {
        router.forgetHostState(reason: reason)
        resetMirror(reason: reason)
        syncHostMode()
        Log.line("TEXTCAP host mode reset to unknown (\(reason))")
    }

    /// The keyboard in use changed (or was first seen).
    func textModeChanged(_ language: String?, source: String) {
        noteLanguage(language, source: source)
    }

    private func noteLanguage(_ language: String?, source: String) {
        if source == "event", language == keyboardLanguage { return }
        if source != "event" || language != keyboardLanguage {
            Log.line("TEXTCAP keyboard \(source): \(keyboardLanguage ?? "nil") → \(language ?? "nil") (mode=\(KeyboardInputMode(primaryLanguage: language)), host assumed \(router.hostMode.rawValue), autoIME=\(autoIMESwitch))")
        }
        keyboardLanguage = language
    }

    /// Runs text-field steps in order, pausing after かな / 英数.
    private func run(_ steps: [TextEntryRouter.Step]) {
        pendingSteps += steps
        let now = self.now()
        while !pendingSteps.isEmpty {
            if now < holdUntil {
                scheduleFlush(at: holdUntil)
                return
            }
            let step = pendingSteps.removeFirst()
            if let check = composeSelfTestGuard, !check(step) {
                Log.line("COMPOSE ABORTED: step \(step) is not allowed — dropped it and \(pendingSteps.count) pending step(s), nothing more is sent")
                pendingSteps.removeAll()
                composeSelfTestAborted = true
                composeSelfTestGuard = { _ in false }
                return
            }
            let r = step.reports(state: &state, keyMap: keyMap)
            peripheral.send(r.reports)
            if !r.skipped.isEmpty { Log.line("TEXTCAP keymap could not type \(Log.recordTyping ? "\(r.skipped.map(String.init))" : "\(r.skipped.count) character(s)")") }
            if case .imeKey(let u) = step {
                holdUntil = now + Self.imeSwitchPause(u)
                Log.line("TEXTCAP \(u == .lang1 ? "LANG1 (かな)" : "LANG2 (英数)") sent -> \(r.reports.map { OutgoingReport.keyboard($0).logText }); next key after \(Int(Self.imeSwitchPause(u) * 1000)) ms")
            }
        }
    }

    private func scheduleFlush(at t: Double) {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            let wait = max(0, t - ProcessInfo.processInfo.systemUptime)
            try? await Task.sleep(for: .milliseconds(Int(wait * 1000) + 1))
            guard let self, !Task.isCancelled else { return }
            self.flushTask = nil
            self.run([])
        }
    }

    private func syncHostMode() {
        if router.hostMode != assumedHostMode { assumedHostMode = router.hostMode }
    }

    private func scalarText(_ s: String) -> String {
        s.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
    }

    /// Types a pasted string. Returns the number of characters that will be typed.
    @discardableResult
    func typePasted(_ text: String) -> Int {
        guard gate() else { return 0 }
        let out = state.type(text, with: TextTyper(keyMap: keyMap))
        peripheral.send(out.reports)
        let count = text.count - out.skipped.count
        Log.line("PASTE chars=\(text.count) typed=\(count) reports=\(out.reports.count) skipped=\(out.skipped.count)")
        if !out.skipped.isEmpty { noteSkipped(out.skipped.map(\.character)) }
        pasteRemaining = count
        Task { await watchPaste() }
        syncUI()
        return count
    }

    /// Counts typable characters of `text` (for the paste confirmation).
    func typableCount(_ text: String) -> (typable: Int, skipped: Int, lines: Int) {
        let skipped = text.filter { keyMap.keyStroke(for: $0) == nil }.count
        let lines = text.filter { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }.count
        return (text.count - skipped, skipped, lines)
    }

    private func watchPaste() async {
        while !peripheral.isIdle { try? await Task.sleep(for: .milliseconds(100)) }
        pasteRemaining = 0
    }

    // MARK: - Reset

    /// Release everything at the host and clear latches/locks (host change, app leaves the
    /// foreground, self-test phase start).
    func releaseAll(reason: String) {
        // Text-field steps still waiting must not reach another host; the host's IME mode is
        // no longer known.
        if !pendingSteps.isEmpty { Log.line("TEXTCAP dropped \(pendingSteps.count) pending step(s) (\(reason))") }
        pendingSteps.removeAll()
        flushTask?.cancel()
        flushTask = nil
        holdUntil = 0
        dropArrows(reason: reason)
        router.forgetHostState(reason: reason, newHost: reason.contains("host"))
        resetMirror(reason: reason)
        syncHostMode()
        let r = state.releaseAll()
        var sent = r
        if consumerDown != nil {
            consumerDown = nil
            peripheral.send(ConsumerReport.released)
            sent.append(.empty)
        }
        if !r.isEmpty { peripheral.send(r) }
        if !sent.isEmpty || reason.contains("host") { Log.line("KEYBOARD_RESET (\(reason)) sent=\(sent.count)") }
        syncUI()
    }

    /// The host is gone (Bluetooth off): forget without sending.
    func forgetHost() {
        dropArrows(reason: "host gone")
        state.forgetHost()
        selfTestState.forgetHost()
        consumerDown = nil
        syncUI()
    }

    // MARK: - Self-test input (bypasses the gate; the caller checks safety)

    func selfTestKeyDown(_ usage: KeyUsage) -> [KeyboardReport] {
        let r = selfTestState.keyDown(usage)
        peripheral.send(r)
        return r
    }

    func selfTestKeyUp(_ usage: KeyUsage) -> [KeyboardReport] {
        let r = selfTestState.keyUp(usage)
        peripheral.send(r)
        return r
    }

    /// Reports for `text` without sending them (for the safety check before typing).
    func selfTestPreview(_ text: String, keyMap map: KeyMap) -> TextTyper.Output {
        var copy = selfTestState
        return copy.type(text, with: TextTyper(keyMap: map))
    }

    func selfTestType(_ text: String, keyMap map: KeyMap) -> TextTyper.Output {
        let out = selfTestState.type(text, with: TextTyper(keyMap: map))
        peripheral.send(out.reports)
        return out
    }

    /// かな / 英数 alone (the one-off input-source check, `--selftest=lang`).
    func selfTestTapBare(_ usage: KeyUsage) -> [KeyboardReport] {
        let r = selfTestState.tapBare(usage)
        peripheral.send(r)
        return r
    }

    /// Plan + reports for a text-field chunk on the self-test state, without sending (preview).
    func selfTestPreviewInsert(_ chunks: [String], keyMap map: KeyMap) -> (plans: [TextEntryRouter.Plan], reports: [KeyboardReport]) {
        var copy = selfTestState
        var r = TextEntryRouter(autoSwitch: false)
        var plans: [TextEntryRouter.Plan] = []
        var reports: [KeyboardReport] = []
        for c in chunks {
            let p = r.insert(c, keyboard: .japanese)
            plans.append(p)
            reports += p.reports(state: &copy, keyMap: map).reports
        }
        return (plans, reports)
    }

    /// Sends chunks through the text-field conversion (as if inserted by the Japanese keyboard,
    /// one chunk per insertText) with automatic かな/英数 off.
    func selfTestInsert(_ chunks: [String], keyMap map: KeyMap) -> Int {
        var r = TextEntryRouter(autoSwitch: false)
        var n = 0
        for c in chunks {
            let p = r.insert(c, keyboard: .japanese)
            let out = p.reports(state: &selfTestState, keyMap: map).reports
            peripheral.send(out)
            n += out.count
        }
        return n
    }

    // MARK: Compose self-test (`--selftest=compose`)

    /// Mirror preview for marked-text sequences (each starts a fresh composition), auto かな/英数
    /// off. Returns the steps per sequence.
    func composePreview(_ sequences: [[String]]) -> [[TextEntryRouter.Step]] {
        var r = TextEntryRouter(autoSwitch: false)
        var t = 0.0
        return sequences.map { seq in
            r.mirrorReset(phoneComposing: false)
            var steps: [TextEntryRouter.Step] = []
            for s in seq {
                t += 1
                r.mirrorReceive(.marked(s), at: t)
                steps += r.mirrorFlush(at: t + 0.5).steps
            }
            return steps
        }
    }

    /// Starts routing the text field through the real pipeline for the self-test: auto
    /// かな/英数 off, every step checked by `allow`.
    func beginComposeSelfTest(allow: @escaping (TextEntryRouter.Step) -> Bool) {
        composeSelfTestAborted = false
        composeSelfTestGuard = allow
        savedAutoSwitch = router.autoSwitch
        router.autoSwitch = false
        router.mirrorReset(phoneComposing: false)
    }

    /// Between sequences: forget the composition (the field was discarded, nothing sent).
    func composeSelfTestNextSequence() {
        router.mirrorReset(phoneComposing: false)
    }

    func endComposeSelfTest() {
        mirrorTask?.cancel()
        mirrorTask = nil
        router.mirrorReset(phoneComposing: false)
        router.autoSwitch = savedAutoSwitch
        composeSelfTestGuard = nil
    }

    func selfTestRelease() -> [KeyboardReport] {
        let r = selfTestState.releaseAll()
        peripheral.send(r)
        return r
    }

    // MARK: - Helpers

    private func send(_ reports: [KeyboardReport], _ what: String) {
        if !reports.isEmpty { peripheral.send(reports) }
        if logReports { Log.line("KEYPANEL \(what) -> \(reports.map { OutgoingReport.keyboard($0).logText })") }
        syncUI()
    }

    private func syncUI() {
        var states: [PanelModifier: LatchState] = [:]
        var held: Set<PanelModifier> = []
        for m in PanelModifier.allCases {
            states[m] = state.state(of: m)
            if state.isHeld(m) { held.insert(m) }
        }
        if states != modifierStates { modifierStates = states }
        if held != heldModifiers { heldModifiers = held }
    }

    private func appendEcho(_ s: String) {
        echo += s.replacingOccurrences(of: "\n", with: "⏎")
        if echo.count > 40 { echo = String(echo.suffix(40)) }
    }

    private func noteSkipped(_ chars: [Character]) {
        let shown = chars.prefix(3).map(String.init).joined()
        skippedNotice = "送れない: \(shown)\(chars.count > 3 ? "…" : "")"
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.skippedNotice = nil
        }
    }

    private func tick() {
        if haptics { haptic.impactOccurred(intensity: 0.6) }
    }

    private func now() -> Double { ProcessInfo.processInfo.systemUptime }
}

extension BLEPeripheral {
    func send(_ reports: [KeyboardReport]) {
        for r in reports { send(r) }
    }
}
