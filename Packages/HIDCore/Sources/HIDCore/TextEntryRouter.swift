// Text field → key steps, including Japanese flick input (design §8.4, 利用者の要望 2026-11-17).
//
// Each `insertText` chunk is converted per character with `KanaRomaji` (per-kana mode): kana
// and Japanese punctuation become romaji typed with the host IME on; ASCII is typed as is.
// The router also decides when to send かな (LANG1) / 英数 (LANG2) so the host IME follows.

/// The iOS keyboard the user is typing with (`UITextInputMode.primaryLanguage`).
public enum KeyboardInputMode: Sendable, Hashable, CustomStringConvertible {
    /// A Japanese keyboard (flick, kana, romaji: "ja-JP").
    case japanese
    /// Any other keyboard ("en-US", "emoji", …).
    case other
    /// Not observable (nil primary language).
    case unknown

    public init(primaryLanguage: String?) {
        guard let p = primaryLanguage, !p.isEmpty else { self = .unknown; return }
        self = p.hasPrefix("ja") ? .japanese : .other
    }

    public var description: String {
        switch self {
        case .japanese: "ja"
        case .other: "en"
        case .unknown: "unknown"
        }
    }
}

/// Turns text-field events into key steps.
///
/// IME rules (when `autoSwitch` is on; the mode bookkeeping, resets, idle and repeat guard
/// are `HostIMESync`):
/// - Each key needs a host mode: kana and Japanese punctuation (`KanaRomaji` `.ime`) need
///   かな; ASCII letters need 英数 (letters typed into the host IME would become kana); other
///   keys (digits, symbols, Space, Return, Tab, Backspace) follow the iOS keyboard: 英数 for a
///   non-Japanese keyboard; for the Japanese keyboard かな only when the host mode is unknown or
///   the keyboard just changed (otherwise they belong to the current context).
/// - The needed mode is asserted (かな / 英数 sent) when the host mode is unknown or
///   different — lazily, before the key, so an iOS keyboard change alone sends nothing.
/// - A composition event of the Japanese keyboard (`compositionEvent`) needs かな.
///
/// Backspace: one per deleted phone character that reached the host. A shadow records, per
/// phone character since the last Space/Return, whether it was sent; deleting a character that
/// was never sent (kanji, emoji) sends nothing. With no shadow left, Backspace is always sent.
public struct TextEntryRouter: Sendable {
    public enum Step: Sendable, Hashable {
        /// かな / 英数, pressed and released bare (no latched modifiers).
        case imeKey(KeyUsage)
        /// ASCII characters for `TextTyper`.
        case type(String)
        case backspace
    }

    public struct Plan: Sendable, Hashable {
        public var steps: [Step] = []
        /// Characters not sent (kanji, emoji, …).
        public var unsendable: [KanaRomaji.Unconvertible] = []
        /// Characters sent but shown slightly differently by the host.
        public var approximations: [KanaRomaji.Approximation] = []
        /// Host-mode decisions (LANG key sent or suppressed with the reason, idle reset).
        public var imeNotes: [String] = []
        /// Composition mirroring: one entry per processed event (for MIRROR log lines).
        public var mirror: [MirrorEntry] = []
        /// Show the "confirm on the host" hint (rule 5 and desync cases).
        public var hint: Bool { mirror.contains { $0.result.hint } }

        public init() {}

        /// All typed characters, in order (for logs and tests).
        public var typedText: String {
            steps.map { if case .type(let s) = $0 { s } else { "" } }.joined()
        }
        public var imeKeys: [KeyUsage] {
            steps.compactMap { if case .imeKey(let u) = $0 { u } else { nil } }
        }

        mutating func type(_ s: String) {
            if case .type(let prev)? = steps.last { steps[steps.count - 1] = .type(prev + s) } else { steps.append(.type(s)) }
        }
    }

    public var autoSwitch: Bool {
        get { ime.enabled }
        set { ime.enabled = newValue }
    }
    public private(set) var ime: HostIMESync
    public var hostMode: HostIMEMode { ime.mode }
    /// Japanese composition → host IME (`CompositionMirror`).
    public private(set) var mirror = CompositionMirror()
    /// False while the caller's keys must not assert the host mode (host holds a composition).
    private var assertAllowed = true
    /// The iOS keyboard of the last key or composition event (for "the keyboard changed").
    private var lastKeyboard: KeyboardInputMode?
    /// Per phone character since the last Space/Return: true if it reached the host.
    private var shadow: [Bool] = []
    private static let shadowLimit = 256

    public init(autoSwitch: Bool = true) {
        ime = HostIMESync(enabled: autoSwitch)
    }

    /// Forget the assumed host mode and the Backspace shadow. `newHost`: the active host
    /// changed (also clears the LANG repeat guard).
    public mutating func forgetHostState(reason: String = "reset", newHost: Bool = false) {
        ime.reset(reason, newHost: newHost)
        shadow.removeAll()
    }

    /// The panel's かな / 英数 was pressed at `time`.
    public mutating func noteManualIMEKey(_ usage: KeyUsage, at time: Double) {
        ime.noteManualKey(usage, at: time)
        shadow.removeAll()
    }

    /// A composition event of the Japanese keyboard (marked text set or text entered): the
    /// host should be in かな. Sends nothing else.
    public mutating func compositionEvent(at time: Double = 0) -> Plan {
        var plan = Plan()
        prepare(.kana, why: "Japanese keyboard composing", keyboard: .japanese, at: time, plan: &plan)
        return plan
    }

    // MARK: - Composition mirroring

    /// A change of the Japanese text field (see `CompositionMirror.Event`).
    public mutating func mirrorReceive(_ event: CompositionMirror.Event, at time: Double) {
        mirror.receive(event, at: time)
    }

    /// Steps for the mirror events that are stable at `time` (empty plan if none are due).
    public mutating func mirrorFlush(at time: Double, force: Bool = false) -> Plan {
        var plan = Plan()
        for r in mirror.flush(at: time, force: force) {
            let start = plan.steps.count
            var keys: [String] = []
            for a in r.actions {
                switch a {
                case .backspaces(let n):
                    plan.steps += Array(repeating: .backspace, count: n)
                    keys.append("BS×\(n)")
                case .kana(let s):
                    if r.hostComposingBefore {
                        prepare(nil, why: "composition kana (host composing)", keyboard: .japanese, at: time, plan: &plan)
                    } else {
                        prepare(.kana, why: "composition kana \(s.debugDescription)", keyboard: .japanese, at: time, plan: &plan)
                    }
                    let romaji = Self.romaji(s)
                    plan.type(romaji)
                    keys.append(romaji.debugDescription)
                case .space:
                    plan.type(" ")
                    keys.append("Space")
                case .returnKey:
                    plan.type("\n")
                    keys.append("Return")
                case .outside(let s):
                    assertAllowed = !r.hostComposingBefore
                    let p = insert(s, keyboard: .japanese, at: time)
                    assertAllowed = true
                    plan.steps += p.steps
                    plan.imeNotes += p.imeNotes
                    plan.unsendable += p.unsendable
                    plan.approximations += p.approximations
                    keys.append(p.steps.isEmpty ? "nothing" : p.typedText.debugDescription)
                case .outsideDelete:
                    assertAllowed = !r.hostComposingBefore
                    let p = deleteBackward(keyboard: .japanese, at: time)
                    assertAllowed = true
                    plan.steps += p.steps
                    plan.imeNotes += p.imeNotes
                    keys.append(p.steps.isEmpty ? "nothing" : "Backspace")
                }
            }
            let langs = plan.steps[start...].compactMap { if case .imeKey(let u) = $0 { u == .lang1 ? "LANG1" : "LANG2" } else { nil } }
            plan.mirror.append(MirrorEntry(result: r, keys: (langs + keys).joined(separator: " ")))
        }
        return plan
    }

    /// Forget the mirror state without sending anything (host change, app inactive, focus
    /// lost, self-test). `phoneComposing`: the field still has marked text.
    public mutating func mirrorReset(phoneComposing: Bool) {
        mirror.reset(phoneComposing: phoneComposing)
    }

    /// Per-kana romaji of composition characters (KanaRomaji `.perKana`).
    static func romaji(_ s: String) -> String {
        s.map { ch -> String in
            switch KanaRomaji.mapping(for: ch) {
            case .ime(let k): return k
            case .approximate(let k, _, _): return k
            default: return ""
            }
        }.joined()
    }

    /// One `insertText` chunk.
    public mutating func insert(_ text: String, keyboard: KeyboardInputMode, at time: Double = 0) -> Plan {
        var plan = Plan()
        for (offset, ch) in text.enumerated() {
            switch KanaRomaji.mapping(for: ch) {
            case .ime(let keys):
                prepare(.kana, why: "kana \(ch.debugDescription)", keyboard: keyboard, at: time, plan: &plan)
                plan.type(keys)
                record(true)
            case .space:
                neutral(" ", ch, keyboard: keyboard, at: time, plan: &plan)
                plan.type(" ")
                shadow.removeAll()
            case .direct(let keys):
                direct(keys, ch, keyboard: keyboard, at: time, plan: &plan)
            case .approximate(let keys, let kind, let note):
                plan.approximations.append(KanaRomaji.Approximation(character: ch, characterOffset: offset,
                                                                    utf16Offset: utf16Offset(text, offset),
                                                                    keys: keys, kind: kind, note: note))
                switch kind {
                case .ime:
                    prepare(.kana, why: "kana \(ch.debugDescription)", keyboard: keyboard, at: time, plan: &plan)
                    plan.type(keys); record(true)
                case .direct: direct(keys, ch, keyboard: keyboard, at: time, plan: &plan)
                case .space:
                    neutral(" ", ch, keyboard: keyboard, at: time, plan: &plan)
                    plan.type(" "); shadow.removeAll()
                }
            case .unconvertible(let reason):
                plan.unsendable.append(KanaRomaji.Unconvertible(character: ch, characterOffset: offset,
                                                                utf16Offset: utf16Offset(text, offset), reason: reason))
                record(false)
            }
        }
        return plan
    }

    /// The keyboard's delete key. With `keyboard` given, the host mode is asserted first like
    /// any other key (nil: no assertion).
    public mutating func deleteBackward(keyboard: KeyboardInputMode? = nil, at time: Double = 0) -> Plan {
        var plan = Plan()
        let send: Bool
        if let sent = shadow.popLast() { send = sent } else { send = true }
        if send {
            if let keyboard { neutral("Backspace", nil, keyboard: keyboard, at: time, plan: &plan) }
            plan.steps.append(.backspace)
        }
        return plan
    }

    // MARK: - Helpers

    private mutating func prepare(_ target: HostIMEMode?, why: String, keyboard: KeyboardInputMode,
                                  at time: Double, plan: inout Plan) {
        let d = ime.before(target: assertAllowed ? target : nil, why: why, at: time)
        if let u = d.send { plan.steps.append(.imeKey(u)) }
        plan.imeNotes += d.notes
        lastKeyboard = keyboard
    }

    /// Digits, symbols, Space, Return, Tab, Backspace: the mode of the iOS keyboard.
    private mutating func neutral(_ what: String, _ ch: Character?, keyboard: KeyboardInputMode,
                                  at time: Double, plan: inout Plan) {
        let changed = lastKeyboard != nil && lastKeyboard != keyboard
        let label = ch.map { $0.debugDescription } ?? what
        switch keyboard {
        case .japanese:
            let assert = hostMode == .unknown || changed
            prepare(assert ? .kana : nil,
                    why: "\(label) from the Japanese keyboard\(changed ? " (keyboard changed)" : "")",
                    keyboard: keyboard, at: time, plan: &plan)
        case .other, .unknown:
            prepare(.eisu, why: "\(label) from a non-Japanese keyboard (\(keyboard))\(changed ? " (keyboard changed)" : "")",
                    keyboard: keyboard, at: time, plan: &plan)
        }
    }

    private mutating func direct(_ keys: String, _ ch: Character, keyboard: KeyboardInputMode,
                                 at time: Double, plan: inout Plan) {
        guard let c = keys.first else { return }
        let isLineOrTab = c == "\n" || c == "\r" || c == "\r\n" || c == "\t"
        if c.isASCII && c.isLetter {
            prepare(.eisu, why: "letter \(ch.debugDescription)", keyboard: keyboard, at: time, plan: &plan)
        } else {
            neutral(keys, ch, keyboard: keyboard, at: time, plan: &plan)
        }
        plan.type(keys)
        if isLineOrTab || c == " " {
            shadow.removeAll()   // Space converts / Return commits on the host: shadow unknown
        } else {
            record(true)
        }
    }

    private mutating func record(_ sent: Bool) {
        shadow.append(sent)
        if shadow.count > Self.shadowLimit { shadow.removeFirst(shadow.count - Self.shadowLimit) }
    }

    private func utf16Offset(_ text: String, _ characterOffset: Int) -> Int {
        text.prefix(characterOffset).utf16.count
    }
}

/// Hides typed text in diagnostic log lines (the app's 「入力内容をログに記録する」 off).
public enum LogRedaction {
    /// Every quoted string literal (as `debugDescription` writes it, escapes included) becomes
    /// `"…"`. Typed text in notes and reasons is always quoted, so this removes all of it.
    public static func quoted(_ s: String) -> String {
        s.replacingOccurrences(of: #""(?:[^"\\]|\\.)*""#, with: "\"…\"", options: .regularExpression)
    }
}

/// One processed mirror event and the keys it produced (for the MIRROR log line).
public struct MirrorEntry: Sendable, Hashable {
    public var result: CompositionMirror.Result
    /// `BS×2 "ka" Space`, `Return`, `none`, with any LANG key first.
    public var keys: String

    /// `MIRROR <event> hostReading="…"→"…" converted=<bool> → keys: … (reason)`.
    /// `redact`: replace typed content with lengths (the diagnostic logging setting is off).
    public func line(redact: Bool) -> String {
        func q(_ s: String) -> String { redact ? "<\(s.count)>" : s.debugDescription }
        let event = redact ? (result.event.split(separator: " ").first.map(String.init) ?? "event") : result.event
        let k = keys.isEmpty ? "none" : (redact ? LogRedaction.quoted(keys) : keys)
        let reason = redact ? LogRedaction.quoted(result.reason) : result.reason
        return "MIRROR \(event) hostReading=\(q(result.readingBefore))→\(q(result.readingAfter)) converted=\(result.converted) → keys: \(k) (\(reason))"
    }
}

extension TextEntryRouter.Plan {
    /// The keyboard reports for this plan on `state` with the host's `keyMap`. Characters the
    /// map cannot type are returned in `skipped` (they should not occur: romaji and ASCII).
    public func reports(state: inout KeyboardState, keyMap: KeyMap) -> (reports: [KeyboardReport], skipped: [Character]) {
        var out: [KeyboardReport] = []
        var skipped: [Character] = []
        for step in steps {
            let r = step.reports(state: &state, keyMap: keyMap)
            out += r.reports
            skipped += r.skipped
        }
        return (out, skipped)
    }
}

extension TextEntryRouter.Step {
    public func reports(state: inout KeyboardState, keyMap: KeyMap) -> (reports: [KeyboardReport], skipped: [Character]) {
        switch self {
        case .imeKey(let u):
            return (state.tapBare(u), [])
        case .type(let s):
            let o = state.type(s, with: TextTyper(keyMap: keyMap))
            return (o.reports, o.skipped.map(\.character))
        case .backspace:
            return (state.tap(.backspace), [])
        }
    }
}
