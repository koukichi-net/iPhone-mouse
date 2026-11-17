// Merged from spike/kana-romaji/Sources/KanaRomaji/KanaRomaji.swift (2026-11-17 23:38, sha256 4630a29f620a). Edit there first.
import Foundation

/// Converts Japanese text typed on an iPhone (one `insertText` chunk at a time) into the ASCII
/// characters that, typed as keystrokes into a host computer whose Japanese IME is in
/// hiragana / ROMAJI input mode with the default romaji table, make the host IME compose the
/// same kana.
///
/// - Output is a string of *characters* (`"ka"`, `","`, `"?"`), not HID key codes. Mapping them to
///   key codes (and Shift) for the host's keyboard layout (US vs JIS) is the caller's job.
/// - Katakana is typed as the romaji of the corresponding hiragana. The host composes HIRAGANA;
///   the user converts to katakana/kanji on the host (Space / F7 etc.).
/// - The host's "kana input" (かな入力) mode is not supported.
///
/// Two modes:
/// - `.perKana` (default): every kana becomes a self-contained spelling (small kana use `x`
///   forms, ん is `nn`, っ is `xtu`). Typed in isolation each spelling yields exactly one kana and
///   leaves nothing pending, so one host Backspace removes exactly what one phone character added.
/// - `.natural`: for a whole string (paste / send-text path): digraphs (きゃ → `kya`) and doubled
///   consonants (っか → `kka`). Not per-kana reversible; do not use for keystroke-by-keystroke typing.
public enum KanaRomaji {

    // MARK: - Public types

    public enum Mode: Sendable, Hashable {
        /// One self-contained spelling per character (stateless). Use for live typing.
        case perKana
        /// Multi-kana spellings (きゃ → kya, っか → kka). Use for pasting a whole string.
        case natural
    }

    /// How a run of keys must be typed on the host.
    public enum SegmentKind: Sendable, Hashable {
        /// Type with the host IME ON (hiragana, romaji input). Lands in the IME composition.
        case ime
        /// Type with the host IME OFF (direct / half-width alphanumeric). ASCII passthrough.
        case direct
        /// The Space key, typed with the IME ON (from a full-width space `U+3000`). With an open
        /// composition the host CONVERTS instead of inserting a space; with an empty composition
        /// it inserts a space (full- or half-width per host setting; not verified from a primary
        /// source). Caller decides.
        case space
    }

    public struct Segment: Sendable, Hashable {
        public var kind: SegmentKind
        /// Characters to type, in order. For `.ime` only `a`–`z`, digits and the punctuation in
        /// the README table; for `.direct` arbitrary printable ASCII plus `\t`, `\n`, `\r`.
        public var keys: String
        /// Source range, in `Character` (grapheme) offsets of the input string.
        public var characterRange: Range<Int>
        /// Source range, in UTF-16 offsets of the input string (matches `NSRange` / UIKit).
        public var utf16Range: Range<Int>
    }

    public enum UnconvertibleReason: Sendable, Hashable {
        /// CJK ideograph (kanji). Only its reading can be typed.
        case kanji
        /// Emoji (including keycaps, ZWJ sequences, flags).
        case emoji
        /// 々 〃 ゝ ゞ ヽ ヾ 〻: no romaji spelling in either IME's default table.
        case iterationMark
        /// Kana, symbol or punctuation with no reliable key in both IMEs' defaults
        /// (e.g. 『』 … ヷ, a lone ゛/ﾞ, a voiced mark on a kana that has no voiced form).
        case noReliableKey
        /// Control or format character other than tab / newline.
        case control
        /// Any other script (accented Latin, Hangul, ...).
        case unsupportedScript
    }

    public struct Unconvertible: Sendable, Hashable {
        public var character: Character
        public var characterOffset: Int
        public var utf16Offset: Int
        public var reason: UnconvertibleReason
    }

    /// A character that IS sent, but the host will not show exactly the input character
    /// (e.g. full-width `Ａ` sent as half-width `A` with the IME off, `ゕ` shown as `ヵ`).
    public struct Approximation: Sendable, Hashable {
        public var character: Character
        public var characterOffset: Int
        public var utf16Offset: Int
        public var keys: String
        public var kind: SegmentKind
        public var note: String
    }

    /// What a chunk needs from the host IME.
    public enum InputClass: Sendable, Hashable {
        case empty
        /// Every character is sendable and needs the host IME ON (kana, Japanese punctuation,
        /// full-width digits, full-width space).
        case kanaLike
        /// Every character is sendable with the host IME OFF (ASCII, and full-width letters that
        /// are approximated by ASCII).
        case asciiLike
        /// Everything is sendable but the chunk needs both IME ON and OFF runs (see segments).
        case mixed
        /// Some characters are sendable, some are not (e.g. "漢字です").
        case partiallySendable
        /// Nothing in the chunk can be sent (kanji only, emoji only, ...).
        case unsendable
    }

    /// How one character is handled.
    public enum CharacterMapping: Sendable, Hashable {
        /// Exact: type `keys` with the IME on (default IME settings assumed).
        case ime(String)
        /// Exact: type `keys` with the IME off.
        case direct(String)
        /// Space key with the IME on (from U+3000). See `SegmentKind.space`.
        case space
        /// Sent, but the host shows something slightly different (see `note`).
        case approximate(keys: String, kind: SegmentKind, note: String)
        case unconvertible(UnconvertibleReason)
    }

    public struct Conversion: Sendable, Hashable {
        /// Runs to type, in input order. Adjacent characters of the same kind are merged; a run is
        /// split wherever an unconvertible character was dropped.
        public var segments: [Segment]
        /// Characters that were dropped.
        public var unconvertible: [Unconvertible]
        /// Characters that were sent but will not appear exactly as typed.
        public var approximations: [Approximation]

        /// All keys of all segments concatenated, ignoring segment kinds. Convenient for tests and
        /// for pure-kana chunks; a caller that types mixed chunks must use `segments`.
        public var keys: String { segments.map(\.keys).joined() }
        /// `true` when nothing was dropped.
        public var isComplete: Bool { unconvertible.isEmpty }
        public var inputClass: InputClass {
            KanaRomaji.inputClass(
                hasIME: segments.contains { $0.kind != .direct },
                hasDirect: segments.contains { $0.kind == .direct },
                hasUnconvertible: !unconvertible.isEmpty,
                isEmpty: segments.isEmpty && unconvertible.isEmpty)
        }
    }

    // MARK: - Public API

    /// Converts one chunk of text (typically a single `insertText` payload).
    public static func convert(_ text: String, mode: Mode = .perKana) -> Conversion {
        var units = makeUnits(text)
        if mode == .natural { units = naturalize(units) }

        var segments: [Segment] = []
        var unconvertible: [Unconvertible] = []
        var approximations: [Approximation] = []

        for unit in units {
            let kind: SegmentKind
            let keys: String
            switch unit.mapping {
            case .ime(let k): kind = .ime; keys = k
            case .direct(let k): kind = .direct; keys = k
            case .space: kind = .space; keys = " "
            case .approximate(let k, let kd, let note):
                kind = kd; keys = k
                approximations.append(Approximation(
                    character: unit.firstCharacter, characterOffset: unit.characterRange.lowerBound,
                    utf16Offset: unit.utf16Range.lowerBound, keys: k, kind: kd, note: note))
            case .unconvertible(let reason):
                unconvertible.append(Unconvertible(
                    character: unit.firstCharacter, characterOffset: unit.characterRange.lowerBound,
                    utf16Offset: unit.utf16Range.lowerBound, reason: reason))
                continue
            }
            if var last = segments.last, last.kind == kind,
               last.characterRange.upperBound == unit.characterRange.lowerBound {
                last.keys += keys
                last.characterRange = last.characterRange.lowerBound..<unit.characterRange.upperBound
                last.utf16Range = last.utf16Range.lowerBound..<unit.utf16Range.upperBound
                segments[segments.count - 1] = last
            } else {
                segments.append(Segment(kind: kind, keys: keys,
                                        characterRange: unit.characterRange, utf16Range: unit.utf16Range))
            }
        }
        return Conversion(segments: segments, unconvertible: unconvertible, approximations: approximations)
    }

    /// Classifies a chunk: does it need the host IME on, off, both, or can it not be sent at all?
    public static func classify(_ text: String) -> InputClass {
        var hasIME = false, hasDirect = false, hasUnconvertible = false
        for c in text {
            switch mapping(for: c) {
            case .ime, .space: hasIME = true
            case .direct: hasDirect = true
            case .approximate(_, let kind, _): if kind == .direct { hasDirect = true } else { hasIME = true }
            case .unconvertible: hasUnconvertible = true
            }
        }
        return inputClass(hasIME: hasIME, hasDirect: hasDirect,
                          hasUnconvertible: hasUnconvertible, isEmpty: text.isEmpty)
    }

    /// Per-kana romaji for one character, or `nil` if the character is not typed with the IME on
    /// (ASCII, unconvertible, approximated, space). Katakana returns its hiragana's spelling.
    public static func romaji(for character: Character) -> String? {
        if case .ime(let keys) = mapping(for: character) { return keys }
        return nil
    }

    /// The per-kana mapping of a single character.
    public static func mapping(for character: Character) -> CharacterMapping {
        let normalized = normalize(character)

        if let kana = hiraganaKey(normalized), let keys = perKanaTable[kana] {
            // Keyed on the input itself: ヵ/ヶ are exact, only hiragana ゕ/ゖ are approximated.
            if let note = kanaApproximationNotes[normalized] {
                return .approximate(keys: keys, kind: .ime, note: note)
            }
            return .ime(keys)
        }
        if let keys = imeSymbolTable[normalized] { return .ime(keys) }
        if normalized == "\u{3000}" { return .space }

        let scalars = Array(character.unicodeScalars)

        // ASCII passthrough (including "\r\n", which is a single Character).
        if scalars.allSatisfy({ $0.isASCII }) {
            if scalars.allSatisfy({ (0x20...0x7E).contains($0.value) || $0.value == 0x09 || $0.value == 0x0A || $0.value == 0x0D }) {
                return .direct(String(character))
            }
            return .unconvertible(.control)
        }

        // Remaining full-width ASCII forms (letters, ／ － ， ． ＂ ...): no IME-on key gives them
        // under default settings, so send the ASCII character with the IME off.
        let nScalars = Array(normalized.unicodeScalars)
        if nScalars.count == 1, (0xFF01...0xFF5E).contains(nScalars[0].value),
           let ascii = Unicode.Scalar(nScalars[0].value - 0xFEE0) {
            return .approximate(keys: String(Character(ascii)), kind: .direct,
                                note: "full-width form sent as half-width ASCII with the IME off")
        }

        return .unconvertible(reason(for: character, normalized: normalized))
    }

    // MARK: - Internals

    static func inputClass(hasIME: Bool, hasDirect: Bool, hasUnconvertible: Bool, isEmpty: Bool) -> InputClass {
        if isEmpty { return .empty }
        if !hasIME && !hasDirect { return .unsendable }
        if hasUnconvertible { return .partiallySendable }
        if hasIME && hasDirect { return .mixed }
        return hasIME ? .kanaLike : .asciiLike
    }

    /// NFC for everything; NFKC (then NFC) only for half-width katakana and half-width CJK
    /// punctuation (U+FF61–U+FF9F) so that ｶﾞ → ガ and ｡ → 。 without folding anything else.
    static func normalize(_ character: Character) -> Character {
        let s = String(character)
        let isHalfwidthKana = character.unicodeScalars.contains { (0xFF61...0xFF9F).contains($0.value) }
        let n = isHalfwidthKana
            ? s.precomposedStringWithCompatibilityMapping.precomposedStringWithCanonicalMapping
            : s.precomposedStringWithCanonicalMapping
        return n.count == 1 ? Character(n) : character
    }

    /// The hiragana table key for a (normalized) kana character: katakana U+30A1–U+30F6 is folded
    /// to hiragana U+3041–U+3096 (ヴ → ゔ, ヵ → ゕ, ヶ → ゖ).
    static func hiraganaKey(_ character: Character) -> Character? {
        let scalars = character.unicodeScalars
        guard scalars.count == 1, let s = scalars.first else { return nil }
        if (0x30A1...0x30F6).contains(s.value), let h = Unicode.Scalar(s.value - 0x60) {
            return Character(h)
        }
        if (0x3041...0x3096).contains(s.value) { return character }
        return nil
    }

    static func reason(for character: Character, normalized: Character) -> UnconvertibleReason {
        if iterationMarks.contains(normalized) { return .iterationMark }
        let scalars = Array(character.unicodeScalars)
        if scalars.contains(where: { $0.properties.isIdeographic }) { return .kanji }
        if scalars.contains(where: { $0.value == 0xFE0F || $0.value == 0x20E3 || $0.value == 0x200D })
            || scalars.contains(where: { $0.properties.isEmojiPresentation })
            || scalars.contains(where: { $0.properties.isEmoji && $0.value >= 0x2000 }) {
            return .emoji
        }
        guard let first = scalars.first else { return .control }
        switch first.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator:
            return .control
        default:
            break
        }
        let v = first.value
        let isKanaBlock = (0x3040...0x30FF).contains(v) || (0x31F0...0x31FF).contains(v)
            || (0xFF61...0xFF9F).contains(v) || (0x1B000...0x1B16F).contains(v)
        if isKanaBlock { return .noReliableKey }
        switch first.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation,
             .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol, .spaceSeparator:
            return .noReliableKey
        default:
            return .unsupportedScript
        }
    }

    struct Unit {
        var characters: [Character]
        var characterRange: Range<Int>
        var utf16Range: Range<Int>
        var mapping: CharacterMapping
        /// Hiragana key when the unit is a single exactly-mapped kana (natural-mode input).
        var kana: Character?
        var firstCharacter: Character { characters[0] }
    }

    static func makeUnits(_ text: String) -> [Unit] {
        var units: [Unit] = []
        var offset = 0
        var utf16 = 0
        for c in text {
            let length = c.utf16.count
            let m = mapping(for: c)
            var kana: Character? = nil
            if case .ime = m { kana = hiraganaKey(normalize(c)) }
            units.append(Unit(characters: [c], characterRange: offset..<(offset + 1),
                              utf16Range: utf16..<(utf16 + length), mapping: m, kana: kana))
            offset += 1
            utf16 += length
        }
        return units
    }

    /// Natural mode: merge digraphs, then turn っ before a consonant into a doubled consonant.
    static func naturalize(_ units: [Unit]) -> [Unit] {
        var merged: [Unit] = []
        var i = 0
        while i < units.count {
            if let a = units[i].kana, i + 1 < units.count, let b = units[i + 1].kana,
               let keys = digraphTable[String([a, b])] {
                merged.append(Unit(
                    characters: units[i].characters + units[i + 1].characters,
                    characterRange: units[i].characterRange.lowerBound..<units[i + 1].characterRange.upperBound,
                    utf16Range: units[i].utf16Range.lowerBound..<units[i + 1].utf16Range.upperBound,
                    mapping: .ime(keys), kana: nil))
                i += 2
            } else {
                merged.append(units[i])
                i += 1
            }
        }
        for j in merged.indices where merged[j].kana == "っ" && j + 1 < merged.count {
            guard case .ime(let next) = merged[j + 1].mapping, merged[j + 1].kana != "っ",
                  merged[j + 1].kana != "ん", let first = next.first,
                  sokuonDoublableLetters.contains(first) else { continue }
            merged[j].mapping = .ime(String(first))
        }
        return merged
    }
}
