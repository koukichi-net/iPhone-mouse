// Merged from spike/kana-romaji/Sources/KanaRomaji/KanaRomajiTables.swift (2026-11-17 23:38, sha256 da36b67bafca). Edit there first.
// Mapping tables for KanaRomaji.
//
// Every romaji spelling below was chosen so that it appears, with the SAME meaning, in both
// default romaji tables:
//
//  [A]  Apple, "Macの日本語での英字とかなの対応" (日本語入力プログラムユーザガイド 6.3), fetched 2026-11-17
//       https://support.apple.com/ja-jp/guide/japanese-input-method/jpim10277/mac
//       Primary source, full table, read as text.
//  [M1] Windows Blog for Japan (Microsoft), IME tips post of 2016-09-27, section
//       "いまさら聞けないローマ字入力", table image romaji1.png
//       https://blogs.windows.com/japan/2016/09/27/jpimetips3/
//       https://blogs.windows.com/wp-content/uploads/prod/sites/31/2016/09/romaji1.png
//       Primary source but PARTIAL: it lists only the "confusing" spellings (small kana, ゐ ゑ ん,
//       ヴ, digraphs). It does not list the basic 50-sound rows. Read by eye from the image.
//  [M2] "ローマ字とかな対応一覧（MS-IME 2000）", teaching handout hosted at chiba-kc.ac.jp (third party, old)
//       https://www.chiba-kc.ac.jp/user/~iseri/siryo/romakana.pdf
//       Used only for the basic rows that [M1] omits (shi, chi, tsu, fu, ji, ...).
//
// The test target contains an oracle built mechanically from [A] and a separate one transcribed
// from [M1]+[M2]; every mapping here is checked against both.
//
// Punctuation / symbol keys are NOT in any of the tables above. They come from the default
// IME settings ("句読点の種類", "“/”キーで入力する文字", "数字を全角入力" on the Mac, documented at
// https://support.apple.com/ja-jp/guide/japanese-input-method/jpim662a12b9/mac) plus memory of
// Microsoft IME's defaults (句読点 "、。", 記号 "「」・"). See README for the IME-dependent rows.

extension KanaRomaji {

    /// Per-kana ("stateless") spellings, keyed by HIRAGANA. Katakana is folded to hiragana first.
    /// Each value, typed alone into an empty romaji composition, yields exactly that one kana and
    /// leaves nothing pending in the IME's romaji buffer.
    static let perKanaTable: [Character: String] = [
        // あ行
        "あ": "a", "い": "i", "う": "u", "え": "e", "お": "o",
        // か行 / が行
        "か": "ka", "き": "ki", "く": "ku", "け": "ke", "こ": "ko",
        "が": "ga", "ぎ": "gi", "ぐ": "gu", "げ": "ge", "ご": "go",
        // さ行 / ざ行 (Hepburn shi / ji: listed by [A] and [M2])
        "さ": "sa", "し": "shi", "す": "su", "せ": "se", "そ": "so",
        "ざ": "za", "じ": "ji", "ず": "zu", "ぜ": "ze", "ぞ": "zo",
        // た行 / だ行 (ぢ = di, づ = du in both; Hepburn "ji"/"zu" would give じ/ず)
        "た": "ta", "ち": "chi", "つ": "tsu", "て": "te", "と": "to",
        "だ": "da", "ぢ": "di", "づ": "du", "で": "de", "ど": "do",
        // な行
        "な": "na", "に": "ni", "ぬ": "nu", "ね": "ne", "の": "no",
        // は行 / ば行 / ぱ行
        "は": "ha", "ひ": "hi", "ふ": "fu", "へ": "he", "ほ": "ho",
        "ば": "ba", "び": "bi", "ぶ": "bu", "べ": "be", "ぼ": "bo",
        "ぱ": "pa", "ぴ": "pi", "ぷ": "pu", "ぺ": "pe", "ぽ": "po",
        // ま行
        "ま": "ma", "み": "mi", "む": "mu", "め": "me", "も": "mo",
        // や行
        "や": "ya", "ゆ": "yu", "よ": "yo",
        // ら行
        "ら": "ra", "り": "ri", "る": "ru", "れ": "re", "ろ": "ro",
        // わ行 + ん. ゐ/ゑ: "wyi"/"wye" in [A] and [M1] (MS-IME 2000 [M2] could not type them).
        "わ": "wa", "ゐ": "wyi", "ゑ": "wye", "を": "wo", "ん": "nn",
        // ゔ: [A] gives ゔ, [M1] gives ヴ (katakana) for "vu". Host-dependent script, same sound.
        "ゔ": "vu",
        // Small kana: always the explicit x- forms (l- forms are equally valid in both).
        "ぁ": "xa", "ぃ": "xi", "ぅ": "xu", "ぇ": "xe", "ぉ": "xo",
        "っ": "xtu", "ゃ": "xya", "ゅ": "xyu", "ょ": "xyo", "ゎ": "xwa",
        // ゕ/ゖ are typed as ヵ/ヶ: both IMEs produce the KATAKANA small ka/ke for xka/xke.
        "ゕ": "xka", "ゖ": "xke",
    ]

    /// Kana that the host renders differently from the input even though the keystrokes are the
    /// documented ones. Reported as `Approximation`s in the conversion result.
    static let kanaApproximationNotes: [Character: String] = [
        "ゕ": "host shows katakana ヵ (xka has no hiragana result in either IME)",
        "ゖ": "host shows katakana ヶ (xke has no hiragana result in either IME)",
    ]

    /// Natural-mode digraphs (kana + small kana -> one romaji syllable), keyed by hiragana pairs.
    /// Only spellings present with the same meaning in [A] and in [M1]/[M2]. Deliberately avoided:
    /// "qu" ([A] くぅ, [M2] く), "qwa" ([A] くゎ, [M1]/[M2] くぁ), and every spelling listed by only
    /// one side: [A] only: hwa hwi hwe hwo kwi kwu kwe kwo; Microsoft only: ca ci cu ce co yi wu
    /// whu lyi xyi vyi vye. (Mechanical diff pinned in OracleSanityTests.completeTableDifference.)
    static let digraphTable: [String: String] = {
        var t: [String: String] = [:]
        let smallVowels: [(Character, String)] = [("ゃ", "a"), ("ぃ", "i"), ("ゅ", "u"), ("ぇ", "e"), ("ょ", "o")]
        // Xy + vowel families present in both for all five columns.
        let yRows: [(Character, String)] = [
            ("き", "ky"), ("ぎ", "gy"), ("に", "ny"), ("ひ", "hy"), ("び", "by"),
            ("ぴ", "py"), ("み", "my"), ("り", "ry"), ("ぢ", "dy"),
        ]
        for (base, prefix) in yRows {
            for (small, vowel) in smallVowels { t[String([base, small])] = prefix + vowel }
        }
        let explicit: [String: String] = [
            // し / じ / ち rows (Hepburn where both list it)
            "しゃ": "sha", "しぃ": "syi", "しゅ": "shu", "しぇ": "she", "しょ": "sho",
            "じゃ": "ja", "じぃ": "jyi", "じゅ": "ju", "じぇ": "je", "じょ": "jo",
            "ちゃ": "cha", "ちぃ": "cyi", "ちゅ": "chu", "ちぇ": "che", "ちょ": "cho",
            // て / で + small
            "てゃ": "tha", "てぃ": "thi", "てゅ": "thu", "てぇ": "the", "てょ": "tho",
            "でゃ": "dha", "でぃ": "dhi", "でゅ": "dhu", "でぇ": "dhe", "でょ": "dho",
            // と / ど + small vowels
            "とぁ": "twa", "とぃ": "twi", "とぅ": "twu", "とぇ": "twe", "とぉ": "two",
            "どぁ": "dwa", "どぃ": "dwi", "どぅ": "dwu", "どぇ": "dwe", "どぉ": "dwo",
            // つ + small vowels (つぅ has no spelling in either table)
            "つぁ": "tsa", "つぃ": "tsi", "つぇ": "tse", "つぉ": "tso",
            // ふ + small
            "ふぁ": "fa", "ふぃ": "fi", "ふぅ": "fwu", "ふぇ": "fe", "ふぉ": "fo",
            "ふゃ": "fya", "ふゅ": "fyu", "ふょ": "fyo",
            // う / い + small
            "うぁ": "wha", "うぃ": "wi", "うぇ": "we", "うぉ": "who", "いぇ": "ye",
            // ゔ + small ([M1] renders the ゔ part as ヴ)
            "ゔぁ": "va", "ゔぃ": "vi", "ゔぇ": "ve", "ゔぉ": "vo",
            "ゔゃ": "vya", "ゔゅ": "vyu", "ゔょ": "vyo",
            // く / ぐ / す + small
            "くぁ": "qa", "くぃ": "qwi", "くぅ": "qwu", "くぇ": "qwe", "くぉ": "qwo",
            "くゃ": "qya", "くゅ": "qyu", "くょ": "qyo",
            "ぐぁ": "gwa", "ぐぃ": "gwi", "ぐぅ": "gwu", "ぐぇ": "gwe", "ぐぉ": "gwo",
            "すぁ": "swa", "すぃ": "swi", "すぅ": "swu", "すぇ": "swe", "すぉ": "swo",
        ]
        t.merge(explicit) { _, new in new }
        return t
    }()

    /// Letters that may be doubled to produce っ in natural mode. Both sources: "次の音節の最初の
    /// 子音を2つ続けて入力" ([A]); "n 以外の子音の連続も可" ([M2]).
    static let sokuonDoublableLetters: Set<Character> = [
        "k", "g", "s", "z", "j", "t", "c", "d", "h", "f", "b", "p", "m", "y", "r", "w", "v", "q",
    ]

    /// Punctuation and symbols typed WITH THE IME ON. Default IME settings assumed.
    /// The host produces the full-width / Japanese form in the composition.
    static let imeSymbolTable: [Character: String] = [
        "、": ",",   // 句読点の種類 default 「、。」 (both); IME-setting dependent
        "。": ".",
        "・": "/",   // Mac: "“/”キーで入力する文字" setting; MS IME: 記号 setting 「」・ (default)
        "「": "[",
        "」": "]",
        "ー": "-",   // prolonged sound mark
        "〜": "~",   // WAVE DASH U+301C (iOS). MS IME produces FULLWIDTH TILDE U+FF5E
        "～": "~",   // FULLWIDTH TILDE U+FF5E
        "？": "?", "！": "!",
        "（": "(", "）": ")",
        "：": ":", "；": ";",
        "＠": "@", "＃": "#", "＄": "$", "％": "%", "＆": "&", "＊": "*",
        "＋": "+", "＝": "=", "＿": "_", "｜": "|", "＜": "<", "＞": ">",
        // Full-width digits: typed as ASCII digits in the composition; width is IME-setting
        // dependent (Mac "数字を全角入力"; MS IME default full-width in hiragana mode).
        "０": "0", "１": "1", "２": "2", "３": "3", "４": "4",
        "５": "5", "６": "6", "７": "7", "８": "8", "９": "9",
    ]

    /// Iteration marks: no romaji spelling in either table (typed by converting a reading such
    /// as "おなじ" on the host).
    static let iterationMarks: Set<Character> = ["々", "〃", "ゝ", "ゞ", "ヽ", "ヾ", "〻"]
}
