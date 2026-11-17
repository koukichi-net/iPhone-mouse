// Merged from spike/kana-romaji/Tests/KanaRomajiTests/CorpusTests.swift (2026-11-17 23:38, sha256 1f4d4b499b5b).
import Testing
@testable import HIDCore

/// Word / sentence corpus with the expected NATURAL-mode keys (hand-written). Every entry is also
/// round-tripped through both IME models in both modes.
let corpus: [(text: String, natural: String)] = [
    // ん handling: always "nn" (safe before vowels, y and n)
    ("こんにちは", "konnnichiha"),
    ("んあ", "nna"),
    ("な", "na"),
    ("かんい", "kanni"),
    ("かに", "kani"),
    ("んな", "nnna"),
    ("んにゃ", "nnnya"),
    ("んんん", "nnnnnn"),
    ("しんや", "shinnya"),
    ("きんようび", "kinnyoubi"),
    ("じゅんび", "junnbi"),
    ("けっこん", "kekkonn"),
    // っ: doubled consonant, explicit xtu at word end / before vowels / before っ
    ("ほっかいどう", "hokkaidou"),
    ("あっ", "axtu"),
    ("ほっ", "hoxtu"),
    ("っ", "xtu"),
    ("っっか", "xtukka"),
    ("きって", "kitte"),
    ("がっこう", "gakkou"),
    ("ちょっと", "chotto"),
    ("まっちゃ", "maccha"),
    ("ちっちゃい", "chicchai"),
    ("ざっし", "zasshi"),
    ("にっぽん", "nipponn"),
    ("いっぱい", "ippai"),
    ("さっぽろ", "sapporo"),
    ("あっさり", "assari"),
    ("ばっぐ", "baggu"),
    ("べっど", "beddo"),
    ("ぐっず", "guzzu"),
    ("やっぱり", "yappari"),
    ("わっふる", "waffuru"),
    ("びっくり", "bikkuri"),
    ("しゅっぱつ", "shuppatsu"),
    ("ぶりっじ", "burijji"),
    ("ゆっくり", "yukkuri"),
    ("えっ、うっそ", "extu,usso"),
    // きゃ / しゅ / ちょ families
    ("きゃく", "kyaku"),
    ("しゅくだい", "shukudai"),
    ("しゃしん", "shashinn"),
    ("ちゃんと", "channto"),
    ("ぎゅうにゅう", "gyuunyuu"),
    ("りょこう", "ryokou"),
    ("はっぴょう", "happyou"),
    ("びょういん", "byouinn"),
    ("みゃく", "myaku"),
    ("ひゃく", "hyaku"),
    ("じゃま", "jama"),
    ("にゃんこ", "nyannko"),
    ("ぎょうざ", "gyouza"),
    ("ちぢむ", "chidimu"),
    ("つづく", "tsuduku"),
    // foreign-sound digraphs
    ("ふぁいる", "fairu"),
    ("ふぃるむ", "firumu"),
    ("ふぇす", "fesu"),
    ("ふぉーく", "fo-ku"),
    ("うぃきぺでぃあ", "wikipedhia"),
    ("うぇぶ", "webu"),
    ("うぉっか", "whokka"),
    ("いぇい", "yei"),
    ("てぃっしゅ", "thisshu"),
    ("でゅえっと", "dhuetto"),
    ("でぃすく", "dhisuku"),
    ("とぅーる", "twu-ru"),
    ("しぇあ", "shea"),
    ("ジェット", "jetto"),
    ("チェック", "chekku"),
    ("シェフ", "shefu"),
    ("クァルテット", "qarutetto"),
    // ゔ / ヴ
    ("ヴァイオリン", "vaiorinn"),
    ("ゔぁいおりん", "vaiorinn"),
    ("ヴィーナス", "vi-nasu"),
    ("ヴェネツィア", "venetsia"),
    ("ヴ", "vu"),
    // long vowels and katakana
    ("ぱーてぃー", "pa-thi-"),
    ("コーヒー", "ko-hi-"),
    ("らーめん", "ra-menn"),
    ("ディズニー", "dhizuni-"),
    ("カタカナ", "katakana"),
    // half-width katakana
    ("ﾊﾝｶｸ", "hannkaku"),
    ("ｶﾞｷﾞｸﾞ", "gagigu"),
    ("ﾊﾟｰﾃｨｰ", "pa-thi-"),
    ("ｷｬｯﾁ", "kyacchi"),
    // historical kana, small kana standing alone
    ("ゐる", "wyiru"),
    ("ゑびす", "wyebisu"),
    ("をかし", "wokashi"),
    ("ぁ", "xa"),
    ("ゃゅょ", "xyaxyuxyo"),
    ("あぁ", "axa"),
    ("いっかげつ", "ikkagetsu"),
    ("ヶ", "xke"),
    // sentences with punctuation
    ("こんにちは。", "konnnichiha."),
    ("ほんとう？", "honntou?"),
    ("「はい」", "[hai]"),
    ("え、ほんと！", "e,honnto!"),
    ("とうきょう・おおさか", "toukyou/oosaka"),
    ("いいね〜", "iine~"),
    ("３じ", "3ji"),
]

/// Per-kana keys for a few entries, spelled out (the per-kana mode never uses digraphs or
/// doubled consonants).
let perKanaExamples: [(text: String, keys: String)] = [
    ("きゃ", "kixya"),
    ("っか", "xtuka"),
    ("こんにちは", "konnnichiha"),
    ("ぱーてぃー", "pa-texi-"),
    ("ほっかいどう", "hoxtukaidou"),
    ("んあ", "nna"),
    ("ヴァ", "vuxa"),
    ("でゅ", "dexyu"),
    ("ﾊﾟｰﾃｨｰ", "pa-texi-"),
]

struct CorpusTests {

    @Test func corpusIsLargeEnough() {
        #expect(corpus.count >= 60)
    }

    @Test("natural keys", arguments: corpus)
    func naturalKeys(entry: (text: String, natural: String)) {
        let c = KanaRomaji.convert(entry.text, mode: .natural)
        #expect(c.keys == entry.natural)
        #expect(c.isComplete)
        #expect(c.segments.allSatisfy { $0.kind == .ime })
    }

    @Test("round trip both modes", arguments: corpus)
    func roundTrip(entry: (text: String, natural: String)) {
        expectRoundTrip(entry.text, mode: .perKana)
        expectRoundTrip(entry.text, mode: .natural)
    }

    @Test("per-kana keys", arguments: perKanaExamples)
    func perKanaKeys(entry: (text: String, keys: String)) {
        #expect(KanaRomaji.convert(entry.text).keys == entry.keys)
    }

    /// Per-kana keys of a string are exactly the concatenation of each character's keys: this is
    /// what makes "type one character, Backspace one character" line up with the host.
    @Test("per-kana is per-character", arguments: corpus)
    func perKanaIsConcatenation(entry: (text: String, natural: String)) {
        let joined = entry.text.map { KanaRomaji.convert(String($0)).keys }.joined()
        #expect(KanaRomaji.convert(entry.text).keys == joined)
    }

    /// Simulates the flick keyboard: type a kana, then the 濁点/小 key replaces it
    /// (deleteBackward + insertText). Host side: one Backspace per kana in the composition.
    @Test func replaceLastCharacterLikeTheFlickKeyboard() {
        // つ → っ → づ (the ゛小 key cycles)
        var hostComposition: [String] = []
        for ime in bothIMEs {
            hostComposition = []
            for step in ["つ", "⌫", "っ", "⌫", "づ"] {
                if step == "⌫" { hostComposition.removeLast(); continue }
                let r = ime.decode(KanaRomaji.convert(step).keys)
                #expect(r.pending.isEmpty)
                hostComposition.append(r.output)
                #expect(r.output.count == 1, "one phone character must be one host character")
            }
            #expect(hostComposition.joined() == "づ")
        }
    }
}
