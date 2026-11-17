// Character → key stroke mapping for the host's keyboard layout setting (design §8.4).
//
// The HID usage names a key position; the host's layout setting decides which character
// that position types. So to type a character we need the layout the *host* is set to.
//
// JIS notes (verified on macOS 27.2 with UCKeyTranslate over the ABC layout and a JIS
// keyboard type; Windows values from the 106/109 layout and Microsoft's HID→scan code
// table — not yet verified on hardware):
// - `]}` key: real JIS keyboards put it in the ISO `#` position. We send Backslash (0x31),
//   which both macOS (virtual key 0x2A) and Windows (scan code 0x2B) map to the same key
//   as Non-US # (0x32), and which every host supports.
// - `ろ` key (International1): Windows `\` / `_`, macOS `_` / `_`. So `_` = Shift+ろ works
//   on both.
// - `¥` key (International3): Windows `\` / `|` (the `\` is shown as ¥ in Japanese
//   fonts), macOS `¥` / `|` and Option+¥ = `\`. So `|` = Shift+¥ works on both, but `\`
//   differs per host OS — the only reason `HostOS` exists. (If the user changed the macOS
//   Japanese IME setting "¥キーで入力する文字" to `\`, Option+¥ types `¥` instead.)
// - 0x35 (US grave) is 半角/全角 on JIS and toggles the IME on Windows; the JIS map never
//   uses it.

/// The keyboard layout the host is configured with.
public enum KeyboardLayout: String, Sendable, Hashable, CaseIterable {
    /// US (ANSI) layout.
    case us
    /// Japanese (JIS 106/109) layout.
    case jis
}

/// The host operating system. Only matters for characters whose key differs between
/// hosts with the same layout (currently only `\` on JIS).
public enum HostOS: String, Sendable, Hashable, CaseIterable {
    case macOS
    case windows
}

/// One key press: a key plus the modifiers that must be held with it.
public struct KeyStroke: Sendable, Hashable, CustomStringConvertible {
    public var usage: KeyUsage
    public var modifiers: KeyModifiers

    public init(_ usage: KeyUsage, _ modifiers: KeyModifiers = []) {
        self.usage = usage
        self.modifiers = modifiers
    }

    public var description: String { "\(usage)+\(String(modifiers.rawValue, radix: 16))" }
}

/// Maps characters to key strokes for a host layout.
///
/// Covers all printable ASCII (0x20–0x7E) for both layouts, plus Return (`\n`, `\r`,
/// `\r\n`), Tab, Backspace (U+0008 and U+007F) and Escape. Everything else returns nil.
public struct KeyMap: Sendable, Hashable {
    public let layout: KeyboardLayout
    public let host: HostOS
    private let table: [Character: KeyStroke]

    public init(layout: KeyboardLayout, host: HostOS = .macOS) {
        self.layout = layout
        self.host = host
        self.table = Self.buildTable(layout: layout, host: host)
    }

    public static let us = KeyMap(layout: .us)

    /// The key stroke that types `character` on the host, or nil if it cannot be typed.
    public func keyStroke(for character: Character) -> KeyStroke? {
        table[character]
    }

    /// Every character this map can type.
    public var mappedCharacters: Set<Character> { Set(table.keys) }

    // MARK: - Tables

    private static func buildTable(layout: KeyboardLayout, host: HostOS) -> [Character: KeyStroke] {
        var t: [Character: KeyStroke] = [:]
        let letters: [KeyUsage] = [.a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m,
                                   .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z]
        for (i, usage) in letters.enumerated() {
            let lower = Character(Unicode.Scalar(UInt8(ascii: "a") + UInt8(i)))
            let upper = Character(Unicode.Scalar(UInt8(ascii: "A") + UInt8(i)))
            t[lower] = KeyStroke(usage)
            t[upper] = KeyStroke(usage, .shift)
        }
        let digits: [(Character, KeyUsage)] = [("1", .digit1), ("2", .digit2), ("3", .digit3), ("4", .digit4),
                                               ("5", .digit5), ("6", .digit6), ("7", .digit7), ("8", .digit8),
                                               ("9", .digit9), ("0", .digit0)]
        for (ch, usage) in digits { t[ch] = KeyStroke(usage) }

        // Control characters and space (same on every layout).
        t["\n"] = KeyStroke(.returnKey)
        t["\r"] = KeyStroke(.returnKey)
        t["\r\n"] = KeyStroke(.returnKey)   // one grapheme cluster in Swift
        t["\t"] = KeyStroke(.tab)
        t["\u{08}"] = KeyStroke(.backspace)
        t["\u{7F}"] = KeyStroke(.backspace)
        t["\u{1B}"] = KeyStroke(.escape)
        t[" "] = KeyStroke(.space)

        let symbols: [(Character, KeyUsage, KeyModifiers)]
        switch layout {
        case .us:
            symbols = [
                ("!", .digit1, .shift), ("@", .digit2, .shift), ("#", .digit3, .shift), ("$", .digit4, .shift),
                ("%", .digit5, .shift), ("^", .digit6, .shift), ("&", .digit7, .shift), ("*", .digit8, .shift),
                ("(", .digit9, .shift), (")", .digit0, .shift),
                ("-", .minus, []), ("_", .minus, .shift),
                ("=", .equal, []), ("+", .equal, .shift),
                ("[", .leftBracket, []), ("{", .leftBracket, .shift),
                ("]", .rightBracket, []), ("}", .rightBracket, .shift),
                ("\\", .backslash, []), ("|", .backslash, .shift),
                (";", .semicolon, []), (":", .semicolon, .shift),
                ("'", .quote, []), ("\"", .quote, .shift),
                ("`", .grave, []), ("~", .grave, .shift),
                (",", .comma, []), ("<", .comma, .shift),
                (".", .period, []), (">", .period, .shift),
                ("/", .slash, []), ("?", .slash, .shift),
            ]
        case .jis:
            symbols = [
                ("!", .digit1, .shift), ("\"", .digit2, .shift), ("#", .digit3, .shift), ("$", .digit4, .shift),
                ("%", .digit5, .shift), ("&", .digit6, .shift), ("'", .digit7, .shift), ("(", .digit8, .shift),
                (")", .digit9, .shift),
                ("-", .minus, []), ("=", .minus, .shift),
                ("^", .equal, []), ("~", .equal, .shift),
                ("@", .leftBracket, []), ("`", .leftBracket, .shift),
                ("[", .rightBracket, []), ("{", .rightBracket, .shift),
                ("]", .backslash, []), ("}", .backslash, .shift),
                (";", .semicolon, []), ("+", .semicolon, .shift),
                (":", .quote, []), ("*", .quote, .shift),
                (",", .comma, []), ("<", .comma, .shift),
                (".", .period, []), (">", .period, .shift),
                ("/", .slash, []), ("?", .slash, .shift),
                ("_", .international1, .shift),
                ("|", .international3, .shift),
                host == .macOS ? ("\\", .international3, .option) : ("\\", .international3, []),
            ]
        }
        for (ch, usage, mods) in symbols { t[ch] = KeyStroke(usage, mods) }
        return t
    }
}
