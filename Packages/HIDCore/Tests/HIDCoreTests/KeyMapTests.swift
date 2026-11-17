import Testing
@testable import HIDCore

// Reviewable layout tables: one row per key position, giving the character the host
// types for that key unshifted, with Shift, and (where used) with Option/Alt.
// nil = this key/modifier combination is not used by the map for typing ASCII.
// The expected character → key stroke table is derived from these rows.

struct LegendRow {
    var usage: KeyUsage
    var plain: Character?
    var shift: Character?
    var option: Character? = nil
}

/// Letters and digits' unshifted legends are the same on US and JIS.
let letterRows: [LegendRow] = zip("abcdefghijklmnopqrstuvwxyz", 0x04...0x1D).map { ch, raw in
    LegendRow(usage: KeyUsage(rawValue: UInt8(raw)), plain: ch, shift: Character(ch.uppercased()))
}

// US (ANSI) layout, macOS "ABC"/"U.S." and Windows "US".
let usRows: [LegendRow] = letterRows + [
    LegendRow(usage: .digit1, plain: "1", shift: "!"),
    LegendRow(usage: .digit2, plain: "2", shift: "@"),
    LegendRow(usage: .digit3, plain: "3", shift: "#"),
    LegendRow(usage: .digit4, plain: "4", shift: "$"),
    LegendRow(usage: .digit5, plain: "5", shift: "%"),
    LegendRow(usage: .digit6, plain: "6", shift: "^"),
    LegendRow(usage: .digit7, plain: "7", shift: "&"),
    LegendRow(usage: .digit8, plain: "8", shift: "*"),
    LegendRow(usage: .digit9, plain: "9", shift: "("),
    LegendRow(usage: .digit0, plain: "0", shift: ")"),
    LegendRow(usage: .minus, plain: "-", shift: "_"),
    LegendRow(usage: .equal, plain: "=", shift: "+"),
    LegendRow(usage: .leftBracket, plain: "[", shift: "{"),
    LegendRow(usage: .rightBracket, plain: "]", shift: "}"),
    LegendRow(usage: .backslash, plain: "\\", shift: "|"),
    LegendRow(usage: .semicolon, plain: ";", shift: ":"),
    LegendRow(usage: .quote, plain: "'", shift: "\""),
    LegendRow(usage: .grave, plain: "`", shift: "~"),
    LegendRow(usage: .comma, plain: ",", shift: "<"),
    LegendRow(usage: .period, plain: ".", shift: ">"),
    LegendRow(usage: .slash, plain: "/", shift: "?"),
    LegendRow(usage: .space, plain: " ", shift: nil),
]

// JIS (106/109) layout. Source: macOS 27.2 UCKeyTranslate over "ABC" with keyboard type
// 18 (JIS), which printed:
//   0x2D -  =   0x2E ^  ~   0x2F @  `   0x30 [  {   0x31 ]  }   0x33 ;  +   0x34 :  *
//   digits 1-9 shifted: ! " # $ % & ' ( )   (Shift+0 types 0)
//   ¥ key (Intl3): ¥  |  Option: \          ろ key (Intl1): _  _
// Windows 106/109 (kbd106): ¥ key = \ (shown as ¥) / |,  ろ key = \ / _  — same symbols
// except `\`, which macOS only types with Option+¥.
// The `]}` key is sent as 0x31 (Backslash); hosts map it like the JIS key at 0x32.
// 0x35 (半角/全角 on JIS) is never used.
let jisCommonRows: [LegendRow] = letterRows + [
    LegendRow(usage: .digit1, plain: "1", shift: "!"),
    LegendRow(usage: .digit2, plain: "2", shift: "\""),
    LegendRow(usage: .digit3, plain: "3", shift: "#"),
    LegendRow(usage: .digit4, plain: "4", shift: "$"),
    LegendRow(usage: .digit5, plain: "5", shift: "%"),
    LegendRow(usage: .digit6, plain: "6", shift: "&"),
    LegendRow(usage: .digit7, plain: "7", shift: "'"),
    LegendRow(usage: .digit8, plain: "8", shift: "("),
    LegendRow(usage: .digit9, plain: "9", shift: ")"),
    LegendRow(usage: .digit0, plain: "0", shift: nil),
    LegendRow(usage: .minus, plain: "-", shift: "="),
    LegendRow(usage: .equal, plain: "^", shift: "~"),
    LegendRow(usage: .leftBracket, plain: "@", shift: "`"),
    LegendRow(usage: .rightBracket, plain: "[", shift: "{"),
    LegendRow(usage: .backslash, plain: "]", shift: "}"),
    LegendRow(usage: .semicolon, plain: ";", shift: "+"),
    LegendRow(usage: .quote, plain: ":", shift: "*"),
    LegendRow(usage: .comma, plain: ",", shift: "<"),
    LegendRow(usage: .period, plain: ".", shift: ">"),
    LegendRow(usage: .slash, plain: "/", shift: "?"),
    LegendRow(usage: .international1, plain: nil, shift: "_"),
    LegendRow(usage: .space, plain: " ", shift: nil),
]
let jisMacRows = jisCommonRows + [
    LegendRow(usage: .international3, plain: nil /* ¥, not ASCII */, shift: "|", option: "\\"),
]
let jisWindowsRows = jisCommonRows + [
    LegendRow(usage: .international3, plain: "\\", shift: "|"),
]

let controlStrokes: [(Character, KeyStroke)] = [
    ("\n", KeyStroke(.returnKey)), ("\r", KeyStroke(.returnKey)), ("\r\n", KeyStroke(.returnKey)),
    ("\t", KeyStroke(.tab)), ("\u{08}", KeyStroke(.backspace)), ("\u{7F}", KeyStroke(.backspace)),
    ("\u{1B}", KeyStroke(.escape)),
]

func expectedStrokes(_ rows: [LegendRow]) -> [Character: KeyStroke] {
    var out: [Character: KeyStroke] = [:]
    func put(_ ch: Character?, _ stroke: KeyStroke) {
        guard let ch else { return }
        precondition(out[ch] == nil, "table types \(ch) twice")
        out[ch] = stroke
    }
    for row in rows {
        put(row.plain, KeyStroke(row.usage))
        put(row.shift, KeyStroke(row.usage, .shift))
        put(row.option, KeyStroke(row.usage, .option))
    }
    for (ch, s) in controlStrokes { out[ch] = s }
    return out
}

let printableASCII: [Character] = (0x20...0x7E).map { Character(Unicode.Scalar(UInt8($0))) }

@Suite("KeyMap")
struct KeyMapTests {
    static let cases: [(String, KeyMap, [LegendRow])] = [
        ("US/macOS", KeyMap(layout: .us, host: .macOS), usRows),
        ("US/Windows", KeyMap(layout: .us, host: .windows), usRows),
        ("JIS/macOS", KeyMap(layout: .jis, host: .macOS), jisMacRows),
        ("JIS/Windows", KeyMap(layout: .jis, host: .windows), jisWindowsRows),
    ]

    @Test(arguments: 0..<4)
    func everyPrintableASCIIMatchesTable(index: Int) {
        let (name, map, rows) = Self.cases[index]
        let expected = expectedStrokes(rows)
        for ch in printableASCII {
            let want = expected[ch]
            #expect(want != nil, "\(name): table has no entry for \(ch)")
            #expect(map.keyStroke(for: ch) == want, "\(name): \(ch)")
        }
        for (ch, stroke) in controlStrokes {
            #expect(map.keyStroke(for: ch) == stroke, "\(name): control \(ch.unicodeScalars.first!.value)")
        }
        // Nothing beyond the table.
        #expect(map.mappedCharacters == Set(expected.keys), "\(name)")
    }

    @Test(arguments: 0..<4)
    func roundTripIsInjective(index: Int) {
        let (name, map, _) = Self.cases[index]
        var seen: [KeyStroke: Character] = [:]
        for ch in printableASCII {
            guard let s = map.keyStroke(for: ch) else { Issue.record("\(name): \(ch) unmapped"); continue }
            #expect(seen[s] == nil, "\(name): \(ch) and \(seen[s].map(String.init) ?? "") share \(s)")
            seen[s] = ch
            #expect(!s.usage.isModifier && s.usage != .none)
        }
    }

    @Test func jisNeverUsesHankakuZenkakuKey() {
        for host in HostOS.allCases {
            let map = KeyMap(layout: .jis, host: host)
            for ch in map.mappedCharacters {
                #expect(map.keyStroke(for: ch)?.usage != .grave, "\(ch)")
            }
        }
    }

    @Test func jisHostDifferenceIsOnlyBackslash() {
        let mac = KeyMap(layout: .jis, host: .macOS), win = KeyMap(layout: .jis, host: .windows)
        let differing = printableASCII.filter { mac.keyStroke(for: $0) != win.keyStroke(for: $0) }
        #expect(differing == ["\\"])
        #expect(mac.keyStroke(for: "\\") == KeyStroke(.international3, .option))
        #expect(win.keyStroke(for: "\\") == KeyStroke(.international3))
    }

    @Test func unmappableCharactersReturnNil() {
        for map in [KeyMap.us, KeyMap(layout: .jis)] {
            for ch: Character in ["é", "あ", "¥", "€", "\u{0}", "😀", "\u{2028}"] {
                #expect(map.keyStroke(for: ch) == nil, "\(ch)")
            }
        }
    }
}
