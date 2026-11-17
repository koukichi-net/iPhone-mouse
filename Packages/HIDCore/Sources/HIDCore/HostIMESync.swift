// Keeps the host's Japanese input mode (かな / 英数) in step with the iOS keyboard
// (利用者の報告 2026-11-18: the phone's Japanese/English and the host's were not in sync).
//
// Rules (when enabled — the setting 「日本語入力を自動で切り替える」):
// - The host mode is assumed `unknown` until this sync sends かな (LANG1) or 英数 (LANG2) itself.
// - Before a key that needs a mode (the caller says which), the mode is asserted when it is
//   `unknown` or different. The caller asks lazily, before the next key — never on an iOS
//   keyboard change notification — so cycling through keyboards sends nothing.
// - Reset to `unknown` on: active host change, app back in the foreground, text field focus,
//   a manual かな / 英数 on the key panel, and `idleReset` seconds without text-field activity
//   (the user may have changed the host's mode by other means).
// - The same LANG key is never sent twice in a row within `repeatWindow` seconds (a manual
//   panel press counts): on macOS a double かな starts reconversion and a double 英数 converts
//   the last input to alphanumerics. A suppressed key assumes the mode it would have set.
//   A host change clears this guard (the previous key went to another host).

/// What the text field assumes about the host's input mode.
public enum HostIMEMode: String, Sendable, Hashable {
    /// Not known (start, after a reset).
    case unknown
    /// Japanese input on: かな (LANG1) was sent (or just pressed on the panel and kept).
    case kana
    /// Japanese input off: 英数 (LANG2) was sent.
    case eisu
}

public struct HostIMESync: Sendable, Hashable {
    /// Result of `before(...)`: the LANG key to send first (if any) and a log note (if
    /// anything happened: a reset by idle, a key sent or suppressed).
    public struct Decision: Sendable, Hashable {
        public var send: KeyUsage?
        public var notes: [String] = []
    }

    public static let defaultIdleReset = 30.0
    public static let defaultRepeatWindow = 1.5

    public var enabled: Bool
    public var idleReset: Double
    public var repeatWindow: Double
    public private(set) var mode: HostIMEMode = .unknown
    /// Why the mode is `unknown` (for logs).
    public private(set) var unknownReason = "start"
    private var lastLangKey: KeyUsage?
    private var lastLangTime = 0.0
    private var lastActivity: Double?

    public init(enabled: Bool = true, idleReset: Double = Self.defaultIdleReset,
                repeatWindow: Double = Self.defaultRepeatWindow) {
        self.enabled = enabled
        self.idleReset = idleReset
        self.repeatWindow = repeatWindow
    }

    /// Forget the host mode. `newHost`: the active host changed, so the repeat guard no
    /// longer applies either.
    public mutating func reset(_ reason: String, newHost: Bool = false) {
        mode = .unknown
        unknownReason = reason
        if newHost { lastLangKey = nil }
    }

    /// The user pressed かな / 英数 on the key panel at `time`: the mode is unknown (it may
    /// have toggled nothing), and that press is the last LANG key for the repeat guard.
    public mutating func noteManualKey(_ usage: KeyUsage, at time: Double) {
        reset("panel \(Self.name(usage))")
        lastLangKey = usage
        lastLangTime = time
    }

    /// Call before each text-field key (or composition event) at `time`. `target` is the mode
    /// the key needs (nil: any mode will do). `why` explains the target for the log.
    public mutating func before(target: HostIMEMode?, why: String, at time: Double) -> Decision {
        var d = Decision()
        if let last = lastActivity, time - last >= idleReset, mode != .unknown {
            mode = .unknown
            unknownReason = "idle \(Int(time - last)) s"
            d.notes.append("host mode reset to unknown (idle \(Int(time - last)) s)")
        }
        lastActivity = time
        guard enabled, let target, target != .unknown, target != mode else { return d }
        let usage: KeyUsage = target == .kana ? .lang1 : .lang2
        let from = mode == .unknown ? "unknown (\(unknownReason))" : mode.rawValue
        if lastLangKey == usage, time - lastLangTime < repeatWindow {
            mode = target
            d.notes.append("\(Self.name(usage)) suppressed: same key \(Int((time - lastLangTime) * 1000)) ms ago; host assumed \(target.rawValue) [\(why); host was \(from)]")
            return d
        }
        mode = target
        lastLangKey = usage
        lastLangTime = time
        d.send = usage
        d.notes.append("\(Self.name(usage)) reason: \(why); host was \(from)")
        return d
    }

    static func name(_ u: KeyUsage) -> String { u == .lang1 ? "LANG1(かな)" : u == .lang2 ? "LANG2(英数)" : "\(u)" }
}
