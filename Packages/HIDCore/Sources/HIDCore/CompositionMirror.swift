// Mirrors the iPhone's Japanese composition (UITextView marked text) to the host's IME
// (step 2, 2026-11-18; ground truth: the TEXTCAP capture of 00:41–00:55, see the tests).
//
// The host is assumed to use romaji input. The phone keeps its own composition; the host
// gets the same kana typed as per-kana romaji, so its IME holds the same reading:
//
// 1. State: `hostReading` (the phone characters mirrored into the host's composition) and
//    `converted` (a Space was sent since the last kana edit: the host shows a conversion).
// 2. Marked text that is kana-only (hiragana, ー, the punctuation and full-width digits that
//    KanaRomaji types with the IME on; NOT katakana, which only a conversion produces): diff
//    against `hostReading` by common prefix; one Backspace per removed character, then
//    per-kana romaji for the new suffix. A trailing run of ASCII letters (romaji keyboard,
//    letters not yet kana) is pending and not mirrored. When the host holds an uncommitted
//    conversion from before (`detached`), the first new kana make the host commit it by
//    itself: start from an empty reading, no Backspaces.
// 3. Marked text that is not kana-only while still marked (the phone converts): Space; each
//    further change while it stays marked and converted: Space again (next candidate). Back
//    to kana-only while marked (conversion cancelled on the phone): Escape would cancel the
//    host's conversion in Apple's IME and Microsoft IME as far as known, but it is not
//    verified (live conversion, other IMEs), and a wrong Escape reaches the host app. So
//    nothing is sent; the mirror stops until this composition ends ("desynced").
// 4. Composition ends with committed text == the last stable marked text (確定 key, a
//    keyboard switch): Return (the host commits what it shows). Committed empty (deleted to
//    nothing): Backspaces only.
// 5. Composition ends with different text (candidate tap, predictive candidate): no Return.
//    Not converted on the host and a usable reading: diff to the reading, then Space (the
//    host shows its own conversion of the same reading, uncommitted). Host already converted
//    or no usable reading: nothing. Always: the hint to confirm on the host. Afterwards the
//    host holds an uncommitted conversion (`detached`) until Return / new kana.
// 6. Outside a composition (Japanese keyboard): inserted text and the delete key go to the
//    caller's normal text path (Return, Space, Backspace, KanaRomaji for punctuation).
// 7. Return only for rule 4 and an explicit "\n" (rule 6).
//
// Stability: UIKit reports a candidate tap as "marked = the candidate" 1 ms before the
// commit; a 確定 tap as "same marked text, then commit". Events are therefore collected and
// processed only after `quiet` seconds without a new event (or `maxHold` after the first),
// and a marked state directly followed by the end of the composition in the same batch is
// dropped (it is the commit's intermediate step, never the "previous marked text").

public struct CompositionMirror: Sendable {
    public enum Event: Sendable, Hashable {
        /// The field has marked text (after the change).
        case marked(String)
        /// The marked text went away; `committed` is the text it left (may be empty).
        /// `reading`: the committed text's reading from the app (kana), if it has one.
        case ended(committed: String, reading: String?)
        /// Text entered with no composition (Japanese keyboard: "\n", " ", punctuation).
        case inserted(String)
        /// The delete key with no composition.
        case deleted
    }

    /// Something to send, in order.
    public enum Action: Sendable, Hashable {
        case backspaces(Int)
        /// Phone characters to type as per-kana romaji (host IME on).
        case kana(String)
        case space
        case returnKey
        /// Rule 6: the caller's normal path for this text / the delete key.
        case outside(String)
        case outsideDelete
    }

    /// One processed event.
    public struct Result: Sendable, Hashable {
        public var event: String
        public var readingBefore: String
        public var readingAfter: String
        public var converted: Bool
        public var actions: [Action]
        public var reason: String
        /// Show 接続先の画面で確認してください（改行＝確定、空白＝次の候補）.
        public var hint: Bool = false
        /// The host was assumed to hold a composition before this event (no LANG assertion
        /// before its keys: a かな/英数 press could disturb that composition).
        public var hostComposingBefore: Bool
    }

    public static let defaultQuiet = 0.04
    public static let defaultMaxHold = 0.25

    public var quiet: Double
    public var maxHold: Double

    public private(set) var hostReading: [Character] = []
    public private(set) var converted = false
    /// The host holds uncommitted text not tied to a phone composition (after rule 5, or kana
    /// punctuation typed outside a composition).
    public private(set) var detached = false
    /// Not mirroring until the phone composition ends (after a reset mid-composition, or a
    /// conversion cancelled on the phone).
    public private(set) var desynced: Desync?
    public enum Desync: String, Sendable, Hashable {
        case reset, cancelledConversion
    }
    /// The last processed marked text (nil: the phone is not composing).
    public private(set) var lastMarked: String?

    private var inbox: [Event] = []
    private var firstEventTime = 0.0
    private var lastEventTime = 0.0

    public init(quiet: Double = Self.defaultQuiet, maxHold: Double = Self.defaultMaxHold) {
        self.quiet = quiet
        self.maxHold = maxHold
    }

    /// The host is assumed to hold a composition (reading, conversion or detached text).
    public var hostComposing: Bool { !hostReading.isEmpty || converted || detached }

    // MARK: - Input

    public mutating func receive(_ event: Event, at time: Double) {
        if inbox.isEmpty { firstEventTime = time }
        lastEventTime = time
        inbox.append(event)
    }

    public var hasPending: Bool { !inbox.isEmpty }

    /// When `flush` will release the pending events (nil: nothing pending).
    public var nextFlushTime: Double? {
        inbox.isEmpty ? nil : min(lastEventTime + quiet, firstEventTime + maxHold)
    }

    /// Processes the pending events if they are stable at `time` (or `force`).
    public mutating func flush(at time: Double, force: Bool = false) -> [Result] {
        guard let due = nextFlushTime, force || time + 1e-9 >= due else { return [] }
        let batch = inbox
        inbox.removeAll()
        var out: [Result] = []
        for (i, e) in batch.enumerated() {
            if case .marked = e, i + 1 < batch.count, case .ended = batch[i + 1] { continue }
            if let r = process(e) { out.append(r) }
        }
        return out
    }

    /// Forget everything without sending (host change, app inactive, focus lost, self-test).
    /// `phoneComposing`: the field still has marked text — ignore it until it ends.
    public mutating func reset(phoneComposing: Bool) {
        inbox.removeAll()
        hostReading = []
        converted = false
        detached = false
        lastMarked = phoneComposing ? "" : nil
        desynced = phoneComposing ? .reset : nil
    }

    // MARK: - Rules

    private mutating func process(_ e: Event) -> Result? {
        let before = String(hostReading), wasComposing = hostComposing
        func result(_ event: String, _ actions: [Action], _ reason: String, hint: Bool = false) -> Result {
            Result(event: event, readingBefore: before, readingAfter: String(hostReading), converted: converted,
                   actions: actions, reason: reason, hint: hint, hostComposingBefore: wasComposing)
        }
        switch e {
        case .marked(let raw):
            let m = raw.precomposedStringWithCanonicalMapping
            let wasMarked = lastMarked
            defer { lastMarked = m }
            let label = "marked \(m.debugDescription)"
            if let d = desynced {
                return result(label, [], "not mirrored until the composition ends (\(d.rawValue))", hint: d == .cancelledConversion)
            }
            guard m != wasMarked else { return nil }
            let split = Self.split(m)
            if split.kanaOnly {
                if converted, wasMarked != nil, !detached {
                    desynced = .cancelledConversion
                    return result(label, [], "phone cancelled its conversion; Escape not sent (not verified for both IMEs) — host left as is until the composition ends", hint: true)
                }
                var note = ""
                if detached, wasMarked == nil {
                    // Rule 2: the host commits its pending conversion / text on the first key.
                    detached = false
                    converted = false
                    hostReading = []
                    note = "; host commits its uncommitted text by itself"
                }
                let target = Array(split.kana)
                let p = Self.commonPrefix(hostReading, target)
                let bs = hostReading.count - p
                let add = String(target[p...])
                hostReading = target
                if bs == 0 && add.isEmpty {
                    return split.pending.isEmpty ? nil : result(label, [], "pending letters \(split.pending.debugDescription) not mirrored\(note)")
                }
                var actions: [Action] = []
                if bs > 0 { actions.append(.backspaces(bs)) }
                if !add.isEmpty { actions.append(.kana(add)) }
                var reason = bs > 0 ? "kana edited" : "kana added"
                if !split.pending.isEmpty { reason += ", pending letters \(split.pending.debugDescription) not mirrored" }
                return result(label, actions, reason + note)
            }
            // Rule 3: the phone converts.
            if hostReading.isEmpty && !converted {
                desynced = .cancelledConversion
                return result(label, [], "non-kana marked text with nothing mirrored on the host — not mirrored until the composition ends", hint: true)
            }
            if !converted {
                converted = true
                return result(label, [.space], "phone converts → host converts")
            }
            return result(label, [.space], "phone shows another candidate → next host candidate")

        case .ended(let raw, let rawReading):
            let c = raw.precomposedStringWithCanonicalMapping
            let prev = lastMarked
            lastMarked = nil
            let label = "commit \(c.debugDescription)"
            if let d = desynced {
                desynced = nil
                hostReading = []
                converted = false
                detached = d == .cancelledConversion
                return result(label, [], "composition ended while not mirrored (\(d.rawValue)) — nothing sent", hint: d == .cancelledConversion)
            }
            if c.isEmpty {
                if converted {
                    hostReading = []
                    detached = true
                    return result(label, [], "phone composition deleted while the host converts — nothing sent", hint: true)
                }
                let n = hostReading.count
                hostReading = []
                return n == 0 ? nil : result(label, [.backspaces(n)], "composition deleted on the phone")
            }
            if let prev, c == prev {
                // Rule 4.
                let pending = Self.split(prev).pending
                hostReading = []
                converted = false
                detached = false
                return result(label, [.returnKey], "committed as shown (確定)" + (pending.isEmpty ? "" : "; pending letters \(pending.debugDescription) were not mirrored"))
            }
            // Rule 5.
            if converted {
                hostReading = []
                detached = true
                return result(label, [], "candidate committed on the phone; host already converting — nothing sent", hint: true)
            }
            if let r = rawReading?.precomposedStringWithCanonicalMapping, !r.isEmpty, Self.split(r).kanaOnly, Self.split(r).pending.isEmpty {
                let target = Array(r)
                let p = Self.commonPrefix(hostReading, target)
                let bs = hostReading.count - p
                let add = String(target[p...])
                var actions: [Action] = []
                if bs > 0 { actions.append(.backspaces(bs)) }
                if !add.isEmpty { actions.append(.kana(add)) }
                actions.append(.space)
                hostReading = []
                converted = true
                detached = true
                return result(label, actions, "candidate committed on the phone (reading \(r.debugDescription)) → host converts the same reading", hint: true)
            }
            hostReading = []
            detached = true
            return result(label, [], "candidate committed on the phone; no usable reading (\((rawReading ?? "nil").debugDescription)) — nothing sent", hint: true)

        case .inserted(let s):
            let label = "insert \(s.debugDescription)"
            if s.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) {
                hostReading = []
                converted = false
                detached = false
            } else if s.contains(where: { Self.isCompositionCharacter($0) }) {
                detached = true   // the host IME holds this text uncommitted
            }
            return result(label, [.outside(s)], "outside a composition")

        case .deleted:
            return result("delete", [.outsideDelete], "outside a composition")
        }
    }

    // MARK: - Helpers

    /// Splits marked text into the kana to mirror and a trailing run of ASCII letters.
    /// `kanaOnly`: everything before that run is composition kana.
    static func split(_ s: String) -> (kana: String, pending: String, kanaOnly: Bool) {
        var chars = Array(s)
        var pending: [Character] = []
        while let last = chars.last, last.isASCII, last.isLetter {
            pending.insert(last, at: 0)
            chars.removeLast()
        }
        let kanaOnly = chars.allSatisfy(isCompositionCharacter)
        return (String(chars), String(pending), kanaOnly)
    }

    /// A character the host IME composes from romaji the same way the phone shows it:
    /// KanaRomaji types it with the IME on, and it is not a katakana letter (katakana in marked
    /// text comes from a conversion; typed as romaji it would become hiragana).
    public static func isCompositionCharacter(_ c: Character) -> Bool {
        if let v = c.unicodeScalars.first?.value, c.unicodeScalars.count == 1 {
            if (0x30A1...0x30FA).contains(v) || (0x30FD...0x30FF).contains(v) || (0x31F0...0x31FF).contains(v)
                || (0xFF66...0xFF9F).contains(v) { return false }
        }
        switch KanaRomaji.mapping(for: c) {
        case .ime: return true
        case .approximate(_, let kind, _): return kind == .ime
        default: return false
        }
    }

    static func commonPrefix(_ a: [Character], _ b: [Character]) -> Int {
        var i = 0
        while i < a.count, i < b.count, a[i] == b[i] { i += 1 }
        return i
    }
}
