// Merged from spike/kana-romaji/Tests/KanaRomajiTests/Oracle.swift (2026-11-17 23:38, sha256 8515724f9e7f).
import Foundation
// Test oracle: a small model of a host romaji IME, independent of the library's tables.
//
// `RomajiIME.decode` feeds keys one at a time, like a real IME:
//  - while the buffer is a strict prefix of some table key, it waits;
//  - when the buffer is exactly a key (and no longer key starts with it), it emits that kana;
//  - when the buffer starts with a doubled consonant other than n ("kk", "tt", "cc"), it emits っ
//    and keeps the second letter ([A]: "次の音節の最初の子音を2つ続けて入力"; [M2]: "n 以外の子音の
//    連続も可");
//  - (Microsoft only) "n" followed by a consonant other than n/y emits ん ([M2]: "子音の前のみ n");
//  - anything else is a decoding failure.
// After the last key, anything left in the buffer is reported as `pending` (a key that is still
// waiting in the host's romaji buffer); the per-kana contract requires it to be empty.

/// Punctuation / symbol keys typed with the IME on, default settings. NOT from the romaji tables:
/// 、。・「」 defaults are documented as settings on the Mac (jpim662a12b9) and in MS IME's settings;
/// the rest (full-width ？！（）etc. and 〜 vs ～) are from memory of default behaviour.
let defaultSymbolKeys: [(romaji: String, apple: String, microsoft: String)] = [
    (",", "、", "、"), (".", "。", "。"), ("/", "・", "・"), ("[", "「", "「"), ("]", "」", "」"),
    ("-", "ー", "ー"), ("~", "〜", "～"),
    ("?", "？", "？"), ("!", "！", "！"), ("(", "（", "（"), (")", "）", "）"),
    (":", "：", "："), (";", "；", "；"), ("@", "＠", "＠"), ("#", "＃", "＃"), ("$", "＄", "＄"),
    ("%", "％", "％"), ("&", "＆", "＆"), ("*", "＊", "＊"), ("+", "＋", "＋"), ("=", "＝", "＝"),
    ("_", "＿", "＿"), ("|", "｜", "｜"), ("<", "＜", "＜"), (">", "＞", "＞"),
    ("0", "０", "０"), ("1", "１", "１"), ("2", "２", "２"), ("3", "３", "３"), ("4", "４", "４"),
    ("5", "５", "５"), ("6", "６", "６"), ("7", "７", "７"), ("8", "８", "８"), ("9", "９", "９"),
]

/// Microsoft IME default romaji table, transcribed by hand.
///  [M1] Windows Blog for Japan, 2016-09-27 (jpimetips3), image romaji1.png — small kana, ゐ ゑ ん,
///       ヴ, digraphs. https://blogs.windows.com/wp-content/uploads/prod/sites/31/2016/09/romaji1.png
///  [M2] "ローマ字とかな対応一覧（MS-IME 2000）" (third-party handout, chiba-kc.ac.jp) — basic rows.
/// Where the two differ, [M1] (newer, Microsoft's own) wins: it adds kwa, xtsu, wyi, wye.
let microsoftRomajiTable: [(romaji: String, kana: String)] = {
    var t: [(String, String)] = []
    func row(_ kana: String, _ romaji: String) {
        let ks = kana.split(separator: " ").map(String.init)
        let rs = romaji.split(separator: " ").map(String.init)
        precondition(ks.count == rs.count, "row mismatch: \(kana) / \(romaji)")
        for (k, r) in zip(ks, rs) { t.append((r, k)) }
    }
    // あ行 [M2]
    row("あ い う え お", "a i u e o")
    row("い う う", "yi wu whu")
    row("ぁ ぃ ぅ ぇ ぉ", "la li lu le lo")
    row("ぁ ぃ ぅ ぇ ぉ", "xa xi xu xe xo")
    row("ぃ ぃ ぇ ぇ", "lyi xyi lye xye")
    row("いぇ", "ye")
    row("うぁ うぃ うぃ うぇ うぇ うぉ", "wha whi wi whe we who")
    // か行 [M2] (+ kwa from [M1])
    row("か き く け こ", "ka ki ku ke ko")
    row("か く こ く", "ca cu co qu")
    row("きゃ きぃ きゅ きぇ きょ", "kya kyi kyu kye kyo")
    row("くゃ くゅ くょ", "qya qyu qyo")
    row("ヵ ヵ ヶ ヶ", "lka xka lke xke")
    row("くぁ くぃ くぅ くぇ くぉ", "qwa qwi qwu qwe qwo")
    row("くぁ くぃ くぇ くぉ くぃ くぇ", "qa qi qe qo qyi qye")
    row("くぁ", "kwa")
    row("が ぎ ぐ げ ご", "ga gi gu ge go")
    row("ぎゃ ぎぃ ぎゅ ぎぇ ぎょ", "gya gyi gyu gye gyo")
    row("ぐぁ ぐぃ ぐぅ ぐぇ ぐぉ", "gwa gwi gwu gwe gwo")
    // さ行 [M2]
    row("さ し す せ そ", "sa si su se so")
    row("し せ し", "ci ce shi")
    row("しゃ しぃ しゅ しぇ しょ", "sya syi syu sye syo")
    row("しゃ しゅ しぇ しょ", "sha shu she sho")
    row("すぁ すぃ すぅ すぇ すぉ", "swa swi swu swe swo")
    row("ざ じ ず ぜ ぞ じ", "za zi zu ze zo ji")
    row("じゃ じぃ じゅ じぇ じょ", "zya zyi zyu zye zyo")
    row("じゃ じゅ じぇ じょ", "ja ju je jo")
    row("じゃ じぃ じゅ じぇ じょ", "jya jyi jyu jye jyo")
    // た行 [M2] (+ xtsu from [M1])
    row("た ち つ て と ち つ", "ta ti tu te to chi tsu")
    row("ちゃ ちぃ ちゅ ちぇ ちょ", "tya tyi tyu tye tyo")
    row("ちゃ ちゅ ちぇ ちょ", "cha chu che cho")
    row("ちゃ ちぃ ちゅ ちぇ ちょ", "cya cyi cyu cye cyo")
    row("っ っ っ っ", "ltu xtu ltsu xtsu")
    row("つぁ つぃ つぇ つぉ", "tsa tsi tse tso")
    row("てゃ てぃ てゅ てぇ てょ", "tha thi thu the tho")
    row("とぁ とぃ とぅ とぇ とぉ", "twa twi twu twe two")
    row("だ ぢ づ で ど", "da di du de do")
    row("ぢゃ ぢぃ ぢゅ ぢぇ ぢょ", "dya dyi dyu dye dyo")
    row("でゃ でぃ でゅ でぇ でょ", "dha dhi dhu dhe dho")
    row("どぁ どぃ どぅ どぇ どぉ", "dwa dwi dwu dwe dwo")
    // な行 [M2]
    row("な に ぬ ね の", "na ni nu ne no")
    row("にゃ にぃ にゅ にぇ にょ", "nya nyi nyu nye nyo")
    // は行 [M2]; ヴ rows: [M1]/[M2] both give KATAKANA ヴ
    row("は ひ ふ へ ほ ふ", "ha hi hu he ho fu")
    row("ひゃ ひぃ ひゅ ひぇ ひょ", "hya hyi hyu hye hyo")
    row("ふゃ ふゅ ふょ", "fya fyu fyo")
    row("ふぁ ふぃ ふぅ ふぇ ふぉ", "fwa fwi fwu fwe fwo")
    row("ふぁ ふぃ ふぇ ふぉ ふぃ ふぇ", "fa fi fe fo fyi fye")
    row("ば び ぶ べ ぼ", "ba bi bu be bo")
    row("びゃ びぃ びゅ びぇ びょ", "bya byi byu bye byo")
    row("ヴぁ ヴぃ ヴ ヴぇ ヴぉ", "va vi vu ve vo")
    row("ヴゃ ヴぃ ヴゅ ヴぇ ヴょ", "vya vyi vyu vye vyo")
    row("ぱ ぴ ぷ ぺ ぽ", "pa pi pu pe po")
    row("ぴゃ ぴぃ ぴゅ ぴぇ ぴょ", "pya pyi pyu pye pyo")
    // ま行 [M2]
    row("ま み む め も", "ma mi mu me mo")
    row("みゃ みぃ みゅ みぇ みょ", "mya myi myu mye myo")
    // や行 [M2]
    row("や ゆ よ", "ya yu yo")
    row("ゃ ゅ ょ ゃ ゅ ょ", "lya lyu lyo xya xyu xyo")
    // ら行 [M2]
    row("ら り る れ ろ", "ra ri ru re ro")
    row("りゃ りぃ りゅ りぇ りょ", "rya ryi ryu rye ryo")
    // わ行 [M2]; ゐ ゑ from [M1]
    row("わ を ゎ ゎ", "wa wo lwa xwa")
    row("ゐ ゑ", "wyi wye")
    row("ん ん ん", "nn n' xn")
    return t
}()

struct RomajiIME {
    let name: String
    let table: [String: String]
    let strictPrefixes: Set<String>
    let singleNBeforeConsonant: Bool

    init(name: String, entries: [(romaji: String, kana: String)], symbols: [(String, String)],
         singleNBeforeConsonant: Bool) {
        var t: [String: String] = [:]
        for (r, k) in entries {
            if let existing = t[r] { precondition(existing == k, "\(name): \(r) is ambiguous") }
            t[r] = k
        }
        for (r, k) in symbols { t[r] = k }
        self.name = name
        self.table = t
        var p = Set<String>()
        for key in t.keys where key.count > 1 {
            for n in 1..<key.count { p.insert(String(key.prefix(n))) }
        }
        self.strictPrefixes = p
        self.singleNBeforeConsonant = singleNBeforeConsonant
    }

    struct Result: Equatable {
        var output: String
        /// Keys still waiting in the romaji buffer after the last key.
        var pending: String
        /// `false` if some key sequence could not be decoded at all.
        var ok: Bool
    }

    static let vowels: Set<Character> = ["a", "i", "u", "e", "o"]

    static func isConsonant(_ c: Character) -> Bool {
        c.isASCII && c.isLetter && c.isLowercase && !vowels.contains(c)
    }

    func decode(_ keys: String) -> Result {
        var out = ""
        var buffer = ""
        for key in keys {
            buffer.append(key)
            guard resolve(&buffer, &out) else { return Result(output: out, pending: buffer, ok: false) }
        }
        return Result(output: out, pending: buffer, ok: true)
    }

    /// Emits whatever the buffer determines. Returns false on an undecodable sequence.
    private func resolve(_ buffer: inout String, _ out: inout String) -> Bool {
        while !buffer.isEmpty {
            if strictPrefixes.contains(buffer) { return true }          // wait for more keys
            if let kana = table[buffer] { out += kana; buffer = ""; return true }
            let chars = Array(buffer)
            if chars.count >= 2, chars[0] == chars[1], chars[0] != "n", Self.isConsonant(chars[0]) {
                out += "っ"; buffer.removeFirst(); continue
            }
            if singleNBeforeConsonant, chars.count >= 2, chars[0] == "n",
               Self.isConsonant(chars[1]), chars[1] != "n", chars[1] != "y" {
                out += "ん"; buffer.removeFirst(); continue
            }
            return false
        }
        return true
    }
}

let appleIME = RomajiIME(
    name: "Apple", entries: appleRomajiTable,
    symbols: defaultSymbolKeys.map { ($0.romaji, $0.apple) }, singleNBeforeConsonant: false)

let microsoftIME = RomajiIME(
    name: "Microsoft", entries: microsoftRomajiTable,
    symbols: defaultSymbolKeys.map { ($0.romaji, $0.microsoft) }, singleNBeforeConsonant: true)

let bothIMEs = [appleIME, microsoftIME]

/// Folds what the host shows and what the phone sent to a comparable form: katakana → hiragana
/// (the host composes hiragana; ヴ/ヵ/ヶ fold to ゔ/ゕ/ゖ, which also absorbs Microsoft's ヴ),
/// half-width katakana → full-width (NFKC on U+FF61–FF9F only), full-width digits → ASCII,
/// FULLWIDTH TILDE → WAVE DASH.
func hostFold(_ s: String) -> String {
    var out = String.UnicodeScalarView()
    for ch in s {
        var t = String(ch)
        if ch.unicodeScalars.contains(where: { (0xFF61...0xFF9F).contains($0.value) }) {
            t = t.precomposedStringWithCompatibilityMapping
        }
        t = t.precomposedStringWithCanonicalMapping
        for u in t.unicodeScalars {
            switch u.value {
            case 0x30A1...0x30F6: out.append(Unicode.Scalar(u.value - 0x60)!)
            case 0xFF10...0xFF19: out.append(Unicode.Scalar(u.value - 0xFEE0)!)
            case 0xFF5E: out.append("〜")
            default: out.append(u)
            }
        }
    }
    return String(out)
}
