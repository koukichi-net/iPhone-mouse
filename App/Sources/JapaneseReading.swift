import Foundation

/// Hiragana reading of committed Japanese text, offline (`CFStringTokenizer` with a Japanese
/// locale), for mirroring a candidate tap to the host (CompositionMirror rule 5).
///
/// - Tokens with kanji: Latin transcription → hiragana (`CFStringTransform`).
/// - Tokens that are already kana: kept, katakana folded to hiragana (keeps ー, which the Latin
///   route loses: コンピュータ → こんぴゅうた).
/// - Text between tokens (punctuation, spaces) is kept as is.
/// - Any Latin letters or a token without a transcription: nil (no usable reading).
/// The result is validated again in HIDCore (only composition characters are used).
enum JapaneseReading {
    static func reading(of s: String) -> String? {
        guard !s.isEmpty else { return nil }
        let ns = s as NSString
        let cf = s as CFString
        let tokenizer = CFStringTokenizerCreate(nil, cf, CFRangeMake(0, ns.length), kCFStringTokenizerUnitWordBoundary,
                                                Locale(identifier: "ja_JP") as CFLocale)
        var out = ""
        var pos = 0
        var type = CFStringTokenizerAdvanceToNextToken(tokenizer)
        while !type.isEmpty {
            let r = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            if r.location > pos { out += ns.substring(with: NSRange(location: pos, length: r.location - pos)) }
            let token = ns.substring(with: NSRange(location: r.location, length: r.length))
            if token.unicodeScalars.contains(where: { $0.isASCII && CharacterSet.letters.contains($0) }) { return nil }
            if !token.unicodeScalars.contains(where: isIdeograph) {
                out += hiragana(token)   // kana, punctuation: as is (katakana folded)
            } else if let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String {
                let m = NSMutableString(string: latin)
                guard CFStringTransform(m, nil, kCFStringTransformLatinHiragana, false) else { return nil }
                out += m as String
            } else {
                return nil
            }
            pos = r.location + r.length
            type = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }
        if pos < ns.length { out += ns.substring(from: pos) }
        return out
    }

    /// Kanji (and 々 〆), which need the tokenizer's transcription.
    private static func isIdeograph(_ u: Unicode.Scalar) -> Bool {
        let v = u.value
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0xF900...0xFAFF).contains(v)
            || (0x20000...0x3FFFF).contains(v) || v == 0x3005 || v == 0x3006
    }

    /// Katakana letters → hiragana, everything else kept. (ICU's Katakana-Hiragana transform
    /// turns ー into a vowel: コンピュータ → こんぴゅうた.)
    private static func hiragana(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map { u in
            (0x30A1...0x30F6).contains(u.value) ? Unicode.Scalar(u.value - 0x60)! : u
        }))
    }

    #if DEBUG
    /// `--reading-probe` examples (logged on the device at launch; Debug builds only).
    static let probeExamples = ["送られてないですね", "送ら", "送らない", "今日は", "日本語入力", "コンピュータ", "行った",
                                "ありがとうございます", "お願いします。", "東京都、大阪府", "iPhoneで", "😀", "明日", "上手"]
    #endif
}
