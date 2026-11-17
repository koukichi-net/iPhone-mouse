// Key panel and text-field logic (design §8.3, §8.4): what the host should see when the
// user works the on-screen modifiers, keys and the text field.
//
// Pure value type: the caller passes times in, and gets the keyboard reports to queue.

/// The four modifier keys on the panel (left-hand usages).
public enum PanelModifier: String, Sendable, Hashable, CaseIterable {
    case control, option, command, shift

    public var flag: KeyModifiers {
        switch self {
        case .control: .leftControl
        case .option: .leftAlt
        case .command: .leftGUI
        case .shift: .leftShift
        }
    }
}

/// Latch state of a panel modifier.
public enum LatchState: String, Sendable, Hashable {
    /// Not active (unless a finger holds it).
    case off
    /// One-shot: applies to the next key press (panel key or typed character), then off.
    case latched
    /// Held down at the host until tapped again.
    case locked
}

/// State of the on-screen keyboard and the host's view of it.
///
/// Modifier rules:
/// - Tap (down and up with no other key pressed meanwhile): off → latched; latched → locked
///   if within `doubleTapInterval` of the previous tap, else off; locked → off.
/// - Hold: while a finger is on a modifier, keys pressed meanwhile get it ("chord"); it then
///   stays down at the host until the finger lifts (so ⌘ held + Tab, Tab works), and the
///   release of that finger does not change the latch state.
/// - Nothing is sent for a modifier alone, except locking, which puts it down at the host at
///   once (so locked ⌘ also applies to trackpad clicks), and unlocking, which releases it.
///   This avoids sending a lone Windows key or Alt tap, which opens menus on Windows.
/// - A latched modifier is consumed by the next key press; it is released at the host after
///   that key (and any other panel key held with it) is released.
///
/// Keys: `keyDown` / `keyUp` per panel key; the key stays down at the host until `keyUp`
/// (the host does auto-repeat). If the modifiers change, a modifier-only report goes first
/// on press and last on release, so the host never sees the key with stale modifiers.
public struct KeyboardState: Sendable {
    public var doubleTapInterval: Double = 0.4

    public private(set) var latch: [PanelModifier: LatchState] = [:]
    /// Number of fingers on each panel modifier.
    private var fingers: [PanelModifier: Int] = [:]
    /// Held modifiers that were used for a key (stay down at the host while held).
    private var usedWhileHeld: Set<PanelModifier> = []
    private var lastTap: [PanelModifier: Double] = [:]
    /// Latched modifiers consumed by the keys currently down.
    private var consumed: KeyModifiers = []
    /// Panel keys currently down, in press order.
    public private(set) var keysDown: [KeyUsage] = []
    /// The last report produced (what the host has).
    public private(set) var host = KeyboardReport.empty

    public init() {}

    // MARK: - Queries

    public func state(of m: PanelModifier) -> LatchState { latch[m] ?? .off }
    public func isHeld(_ m: PanelModifier) -> Bool { (fingers[m] ?? 0) > 0 }

    public var locked: KeyModifiers { flags { state(of: $0) == .locked } }
    public var latched: KeyModifiers { flags { state(of: $0) == .latched } }
    public var held: KeyModifiers { flags { isHeld($0) } }

    /// Modifiers the next key press gets.
    public var pending: KeyModifiers { locked.union(latched).union(held) }

    /// Modifiers that should be down at the host right now.
    private var desiredModifiers: KeyModifiers {
        var m = locked.union(flags { usedWhileHeld.contains($0) && isHeld($0) })
        if !keysDown.isEmpty { m.formUnion(consumed) }
        return m
    }

    private func flags(_ include: (PanelModifier) -> Bool) -> KeyModifiers {
        var m: KeyModifiers = []
        for p in PanelModifier.allCases where include(p) { m.insert(p.flag) }
        return m
    }

    // MARK: - Modifiers

    public mutating func modifierDown(_ m: PanelModifier, at time: Double) -> [KeyboardReport] {
        let n = fingers[m] ?? 0
        fingers[m] = n + 1
        if n == 0 { usedWhileHeld.remove(m) }
        // A modifier pressed while panel keys are down applies to them at once (as on a real
        // keyboard); it then counts as used.
        guard !keysDown.isEmpty else { return [] }
        usedWhileHeld.insert(m)
        return sync()
    }

    public mutating func modifierUp(_ m: PanelModifier, at time: Double) -> [KeyboardReport] {
        let n = fingers[m] ?? 0
        guard n > 0 else { return [] }
        fingers[m] = n - 1
        guard n == 1 else { return [] }
        if usedWhileHeld.remove(m) == nil {
            // A tap.
            switch state(of: m) {
            case .off:
                latch[m] = .latched
                lastTap[m] = time
            case .latched:
                let quick = lastTap[m].map { time - $0 <= doubleTapInterval } ?? false
                latch[m] = quick ? .locked : .off
                lastTap[m] = nil
            case .locked:
                latch[m] = .off
                lastTap[m] = nil
            }
        }
        return sync()
    }

    /// Clear one modifier's latch or lock (e.g. a long press on a locked key in the UI).
    public mutating func setLatch(_ m: PanelModifier, _ s: LatchState, at time: Double) -> [KeyboardReport] {
        latch[m] = s
        lastTap[m] = s == .latched ? time : nil
        return sync()
    }

    // MARK: - Keys

    /// A panel key goes down. Modifier usages (0xE0–0xE7) are allowed and go into the
    /// modifier byte (used by the self-test for "Shift alone").
    public mutating func keyDown(_ usage: KeyUsage) -> [KeyboardReport] {
        guard !keysDown.contains(usage) else { return [] }
        consumeForPress()
        keysDown.append(usage)
        var out: [KeyboardReport] = []
        let mods = desiredModifiers
        if mods != host.modifiers {
            out += emit(KeyboardReport(modifiers: mods, keys: host.keys))
        }
        out += emit(KeyboardReport(modifiers: mods, keys: keysDown))
        return out
    }

    public mutating func keyUp(_ usage: KeyUsage) -> [KeyboardReport] {
        guard let i = keysDown.firstIndex(of: usage) else { return [] }
        keysDown.remove(at: i)
        var out = emit(KeyboardReport(modifiers: host.modifiers, keys: keysDown))
        if keysDown.isEmpty { consumed = [] }
        out += sync()
        return out
    }

    /// Press and release (e.g. the text field's Backspace).
    public mutating func tap(_ usage: KeyUsage) -> [KeyboardReport] {
        keyDown(usage) + keyUp(usage)
    }

    /// Press and release without consuming latched modifiers (for かな / 英数 sent by the text
    /// field: Shift+かな is a different key on macOS). Locked and held modifiers stay as they are.
    public mutating func tapBare(_ usage: KeyUsage) -> [KeyboardReport] {
        guard !keysDown.contains(usage) else { return [] }
        let mods = desiredModifiers
        var out = emit(KeyboardReport(modifiers: mods, keys: keysDown + [usage]))
        out += emit(KeyboardReport(modifiers: mods, keys: keysDown))
        return out
    }

    /// Types text from the text field with `typer`. The first character gets latched
    /// modifiers (then they are consumed); every character gets locked and held ones.
    public mutating func type(_ text: String, with typer: TextTyper) -> TextTyper.Output {
        var reports: [KeyboardReport] = []
        var skipped: [TextTyper.SkippedCharacter] = []
        for (offset, ch) in text.enumerated() {
            guard typer.keyMap.keyStroke(for: ch) != nil else {
                skipped.append(.init(offset: offset, character: ch))
                continue
            }
            consumeForPress()
            let base = desiredModifiers.union(consumed)
            let out = typer.reports(for: String(ch), holding: base, from: host.modifiers)
            for r in out.reports {
                // Keep panel keys that are down (rare: typing while holding a panel key).
                reports += emit(KeyboardReport(modifiers: r.modifiers, keys: keysDown + r.keys))
            }
            if keysDown.isEmpty { consumed = [] }
            reports += sync()
        }
        return TextTyper.Output(reports: reports, skipped: skipped)
    }

    // MARK: - Reset

    /// Everything off and released: latches, locks, held fingers and keys. Returns the
    /// report that releases the host (if it had anything down).
    public mutating func releaseAll() -> [KeyboardReport] {
        latch = [:]
        fingers = [:]
        usedWhileHeld = []
        lastTap = [:]
        consumed = []
        keysDown = []
        return emit(.empty)
    }

    /// Forget the host's state without sending (the host is gone).
    public mutating func forgetHost() {
        _ = releaseAll()
        host = .empty
    }

    // MARK: - Helpers

    /// A key press uses held modifiers and consumes latched ones.
    private mutating func consumeForPress() {
        for m in PanelModifier.allCases {
            if isHeld(m) { usedWhileHeld.insert(m) }
            if state(of: m) == .latched {
                consumed.insert(m.flag)
                latch[m] = .off
                lastTap[m] = nil
            }
        }
    }

    private mutating func sync() -> [KeyboardReport] {
        emit(KeyboardReport(modifiers: desiredModifiers, keys: keysDown))
    }

    private mutating func emit(_ r: KeyboardReport) -> [KeyboardReport] {
        guard r != host else { return [] }
        host = r
        return [r]
    }
}
