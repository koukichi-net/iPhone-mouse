// Expands text into keyboard reports (design §8.4, text field).

/// Turns a string into a sequence of keyboard reports using a `KeyMap`.
///
/// Sequence per character:
/// 1. If the needed modifiers differ from the ones currently held, a modifier-only report
///    switches them first (so the host sees e.g. Shift down before the key).
/// 2. The key press (modifiers + key).
/// 3. The key release (modifiers still held, no keys).
///
/// Every key is released before the next press, so repeated identical characters
/// ("ll") are seen as separate presses. Modifiers stay held across consecutive characters
/// that need the same modifiers ("AB" = one Shift down). The sequence always ends with
/// `KeyboardReport.empty`. Characters the map cannot type are skipped and reported.
public struct TextTyper: Sendable, Hashable {
    public struct SkippedCharacter: Sendable, Hashable {
        /// Index of the character in the string, counted in `Character`s.
        public var offset: Int
        public var character: Character
    }

    public struct Output: Sendable, Hashable {
        public var reports: [KeyboardReport]
        public var skipped: [SkippedCharacter]
    }

    public var keyMap: KeyMap

    public init(keyMap: KeyMap) { self.keyMap = keyMap }

    public func reports(for text: String) -> Output {
        reports(for: text, holding: [], from: [])
    }

    /// Like `reports(for:)`, with modifiers that are held down throughout (`base`, e.g.
    /// modifiers latched or locked on the key panel) and the modifiers the host currently
    /// has down (`current`). Every character is typed with its own modifiers plus `base`;
    /// the sequence ends with exactly `base` held (no report if nothing changed). Text
    /// whose characters are all skipped gives no reports at all.
    public func reports(for text: String, holding base: KeyModifiers, from current: KeyModifiers) -> Output {
        var reports: [KeyboardReport] = []
        var skipped: [SkippedCharacter] = []
        var held = current

        for (offset, character) in text.enumerated() {
            guard let stroke = keyMap.keyStroke(for: character) else {
                skipped.append(SkippedCharacter(offset: offset, character: character))
                continue
            }
            let want = stroke.modifiers.union(base)
            if want != held {
                held = want
                reports.append(KeyboardReport(modifiers: held))
            }
            reports.append(KeyboardReport(modifiers: held, keys: [stroke.usage]))
            reports.append(KeyboardReport(modifiers: held))
        }
        if !reports.isEmpty, held != base { reports.append(KeyboardReport(modifiers: base)) }
        return Output(reports: reports, skipped: skipped)
    }
}
