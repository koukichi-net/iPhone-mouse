import Testing
@testable import KanaRomaji

// Human-reviewable expected per-kana mappings. Each row is a string of characters and the
// space-separated keys expected for each character, in order. This table is typed by hand and is
// NOT derived from the library's tables.

/// Exact, typed with the IME ON.
let expectedIMERows: [(chars: String, keys: String)] = [
    // ── Hiragana ─────────────────────────────────────────────
    ("あいうえお", "a i u e o"),
    ("かきくけこ", "ka ki ku ke ko"),
    ("がぎぐげご", "ga gi gu ge go"),
    ("さしすせそ", "sa shi su se so"),
    ("ざじずぜぞ", "za ji zu ze zo"),
    ("たちつてと", "ta chi tsu te to"),
    ("だぢづでど", "da di du de do"),
    ("なにぬねの", "na ni nu ne no"),
    ("はひふへほ", "ha hi fu he ho"),
    ("ばびぶべぼ", "ba bi bu be bo"),
    ("ぱぴぷぺぽ", "pa pi pu pe po"),
    ("まみむめも", "ma mi mu me mo"),
    ("やゆよ", "ya yu yo"),
    ("らりるれろ", "ra ri ru re ro"),
    ("わゐゑをん", "wa wyi wye wo nn"),
    ("ゔ", "vu"),
    ("ぁぃぅぇぉ", "xa xi xu xe xo"),
    ("っゃゅょゎ", "xtu xya xyu xyo xwa"),
    // ── Katakana (full-width): same keys; the host composes hiragana ─────────
    ("アイウエオ", "a i u e o"),
    ("カキクケコ", "ka ki ku ke ko"),
    ("ガギグゲゴ", "ga gi gu ge go"),
    ("サシスセソ", "sa shi su se so"),
    ("ザジズゼゾ", "za ji zu ze zo"),
    ("タチツテト", "ta chi tsu te to"),
    ("ダヂヅデド", "da di du de do"),
    ("ナニヌネノ", "na ni nu ne no"),
    ("ハヒフヘホ", "ha hi fu he ho"),
    ("バビブベボ", "ba bi bu be bo"),
    ("パピプペポ", "pa pi pu pe po"),
    ("マミムメモ", "ma mi mu me mo"),
    ("ヤユヨ", "ya yu yo"),
    ("ラリルレロ", "ra ri ru re ro"),
    ("ワヰヱヲン", "wa wyi wye wo nn"),
    ("ヴ", "vu"),
    ("ァィゥェォ", "xa xi xu xe xo"),
    ("ッャュョヮ", "xtu xya xyu xyo xwa"),
    ("ヵヶ", "xka xke"),
    ("ー", "-"),
    // ── Half-width katakana (incl. ﾞ/ﾟ forming one Character with the base) ─────
    ("ｱｲｳｴｵ", "a i u e o"),
    ("ｶｷｸｹｺ", "ka ki ku ke ko"),
    ("ｻｼｽｾｿ", "sa shi su se so"),
    ("ﾀﾁﾂﾃﾄ", "ta chi tsu te to"),
    ("ﾅﾆﾇﾈﾉ", "na ni nu ne no"),
    ("ﾊﾋﾌﾍﾎ", "ha hi fu he ho"),
    ("ﾏﾐﾑﾒﾓ", "ma mi mu me mo"),
    ("ﾔﾕﾖ", "ya yu yo"),
    ("ﾗﾘﾙﾚﾛ", "ra ri ru re ro"),
    ("ﾜｦﾝ", "wa wo nn"),
    ("ｧｨｩｪｫ", "xa xi xu xe xo"),
    ("ｯｬｭｮ", "xtu xya xyu xyo"),
    ("ｰ", "-"),
    ("ｶﾞｷﾞｸﾞｹﾞｺﾞ", "ga gi gu ge go"),
    ("ｻﾞｼﾞｽﾞｾﾞｿﾞ", "za ji zu ze zo"),
    ("ﾀﾞﾁﾞﾂﾞﾃﾞﾄﾞ", "da di du de do"),
    ("ﾊﾞﾋﾞﾌﾞﾍﾞﾎﾞ", "ba bi bu be bo"),
    ("ﾊﾟﾋﾟﾌﾟﾍﾟﾎﾟ", "pa pi pu pe po"),
    ("ｳﾞ", "vu"),
    // ── Hiragana with COMBINING (U+3099 / U+309A) marks: NFC-composed ─────
    ("か\u{3099}は\u{309A}う\u{3099}", "ga pa vu"),
    // ── Japanese punctuation / symbols (default IME settings; see README) ─────
    ("、。・「」", ", . / [ ]"),
    ("｡､･｢｣", ". , / [ ]"),            // half-width forms
    ("？！（）〜～", "? ! ( ) ~ ~"),
    ("：；＠＃＄％＆＊＋＝＿｜＜＞", ": ; @ # $ % & * + = _ | < >"),
    ("０１２３４５６７８９", "0 1 2 3 4 5 6 7 8 9"),
]

/// Sent, but the host shows something different (reported in `approximations`).
let expectedApproximations: [(char: Character, keys: String, kind: KanaRomaji.SegmentKind)] = [
    ("ゕ", "xka", .ime),     // host shows ヵ
    ("ゖ", "xke", .ime),     // host shows ヶ
    ("Ａ", "A", .direct), ("ｚ", "z", .direct),
    ("／", "/", .direct),    // "/" with the IME on gives ・
    ("－", "-", .direct),    // "-" with the IME on gives ー
    ("，", ",", .direct),    // "," with the IME on gives 、
    ("．", ".", .direct),    // "." with the IME on gives 。
    ("＾", "^", .direct), ("＂", "\"", .direct), ("＇", "'", .direct), ("｛", "{", .direct),
    ("＼", "\\", .direct),
]

/// Not sendable, with the reason.
let expectedUnconvertible: [(char: Character, reason: KanaRomaji.UnconvertibleReason)] = [
    ("漢", .kanji), ("〆", .kanji), ("〇", .kanji), ("𠮷", .kanji),
    ("々", .iterationMark), ("〃", .iterationMark), ("ゝ", .iterationMark), ("ゞ", .iterationMark),
    ("ヽ", .iterationMark), ("ヾ", .iterationMark),
    ("👍", .emoji), ("👍🏽", .emoji), ("1️⃣", .emoji), ("🇯🇵", .emoji), ("👨‍👩‍👧", .emoji), ("❤️", .emoji),
    ("『", .noReliableKey), ("』", .noReliableKey), ("…", .noReliableKey), ("‥", .noReliableKey),
    ("【", .noReliableKey), ("】", .noReliableKey), ("※", .noReliableKey), ("〒", .noReliableKey),
    ("“", .noReliableKey), ("”", .noReliableKey), ("→", .noReliableKey), ("☆", .noReliableKey),
    ("¥", .noReliableKey), ("￥", .noReliableKey),
    ("ヷ", .noReliableKey), ("ヸ", .noReliableKey), ("ヹ", .noReliableKey), ("ヺ", .noReliableKey),
    ("゛", .noReliableKey), ("゜", .noReliableKey), ("ﾞ", .noReliableKey), ("ﾟ", .noReliableKey),
    ("ｱﾞ", .noReliableKey), ("ﾜﾞ", .noReliableKey), ("ゟ", .noReliableKey), ("ㇰ", .noReliableKey),
    ("\u{0007}", .control), ("\u{200B}", .control),
    ("é", .unsupportedScript), ("한", .unsupportedScript),
]

struct MappingTableTests {

    @Test("every IME-mode row maps exactly as listed", arguments: expectedIMERows)
    func imeRows(row: (chars: String, keys: String)) {
        let chars = Array(row.chars)
        let keys = row.keys.split(separator: " ").map(String.init)
        #expect(chars.count == keys.count, "row \(row.chars) is malformed")
        for (c, k) in zip(chars, keys) {
            #expect(KanaRomaji.mapping(for: c) == .ime(k), "\(c) (U+\(scalars(c)))")
            #expect(KanaRomaji.romaji(for: c) == k)
        }
    }

    @Test func approximations() {
        for (c, keys, kind) in expectedApproximations {
            guard case .approximate(let k, let kd, _) = KanaRomaji.mapping(for: c) else {
                Issue.record("\(c) should be approximate, got \(KanaRomaji.mapping(for: c))")
                continue
            }
            #expect(k == keys && kd == kind, "\(c)")
            #expect(KanaRomaji.romaji(for: c) == nil)
        }
    }

    @Test func unconvertible() {
        for (c, reason) in expectedUnconvertible {
            #expect(KanaRomaji.mapping(for: c) == .unconvertible(reason), "\(c) (U+\(scalars(c)))")
        }
    }

    @Test func asciiPassesThroughDirect() {
        for v in 0x20...0x7E {
            let c = Character(Unicode.Scalar(v)!)
            #expect(KanaRomaji.mapping(for: c) == .direct(String(c)))
        }
        for c: Character in ["\n", "\t", "\r\n"] {
            #expect(KanaRomaji.mapping(for: c) == .direct(String(c)))
        }
    }

    @Test func fullWidthSpaceIsTheSpaceKey() {
        #expect(KanaRomaji.mapping(for: "\u{3000}") == .space)
        #expect(KanaRomaji.mapping(for: " ") == .direct(" "))
    }

    /// Every code point in the hiragana and katakana blocks is either in the reviewed tables
    /// above or explicitly unconvertible: nothing falls through silently.
    @Test func kanaBlocksAreFullyAccountedFor() {
        let listed = Set(expectedIMERows.flatMap { Array($0.chars) })
            .union(expectedApproximations.map(\.char))
            .union(expectedUnconvertible.map(\.char))
        for v in Array(0x3041...0x3096) + Array(0x30A1...0x30FA) + [0x30FC] + Array(0xFF66...0xFF9D) {
            let c = Character(Unicode.Scalar(v)!)
            #expect(listed.contains(c), "U+\(String(v, radix: 16, uppercase: true)) \(c) is not in the reviewed tables")
            if case .unconvertible = KanaRomaji.mapping(for: c) {
                #expect(expectedUnconvertible.contains { $0.char == c }, "\(c) unexpectedly unconvertible")
            }
        }
    }

    /// The IME-mode output alphabet: lowercase letters, digits and the named punctuation only.
    /// (Uppercase would be a mode switch on the Mac: Shift enters alphanumeric mode.)
    @Test func imeKeysUseOnlyTheAllowedAlphabet() {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789,./[]-~?!():;@#$%&*+=_|<>")
        for row in expectedIMERows {
            for c in row.chars {
                guard let k = KanaRomaji.romaji(for: c) else { continue }
                #expect(k.allSatisfy { allowed.contains($0) }, "\(c) -> \(k)")
            }
        }
    }
}

func scalars(_ c: Character) -> String {
    c.unicodeScalars.map { String($0.value, radix: 16, uppercase: true) }.joined(separator: "+")
}
