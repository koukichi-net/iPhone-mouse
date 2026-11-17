import Testing
@testable import KanaRomaji

/// The oracle must be able to fail; these pin down its behaviour and record the Apple/Microsoft
/// differences found in the sources (the library avoids every one of them).
struct OracleSanityTests {

    @Test func basicDecoding() {
        for ime in bothIMEs {
            #expect(ime.decode("ka") == .init(output: "か", pending: "", ok: true))
            #expect(ime.decode("kka") == .init(output: "っか", pending: "", ok: true))
            #expect(ime.decode("nna") == .init(output: "んあ", pending: "", ok: true))
            #expect(ime.decode("n").pending == "n", "bare n must stay pending")
            #expect(ime.decode("ky").pending == "ky")
            #expect(!ime.decode("KA").ok, "uppercase is not romaji")
            #expect(!ime.decode("xq").ok)
        }
    }

    @Test func differencesBetweenTheTwoIMEs() {
        // vu: Apple ゔ (hiragana), Microsoft ヴ (katakana)
        #expect(appleIME.decode("vu").output == "ゔ")
        #expect(microsoftIME.decode("vu").output == "ヴ")
        // qwa: Apple くゎ, Microsoft くぁ
        #expect(appleIME.decode("qwa").output == "くゎ")
        #expect(microsoftIME.decode("qwa").output == "くぁ")
        // qu: Apple くぅ, Microsoft く
        #expect(appleIME.decode("qu").output == "くぅ")
        #expect(microsoftIME.decode("qu").output == "く")
        // kwi..kwo listed only by Apple
        #expect(appleIME.decode("kwi").output == "くぃ")
        #expect(!microsoftIME.decode("kwi").ok)
        // single n before a consonant: documented for Microsoft ([M2]) only
        #expect(microsoftIME.decode("kanji").output == "かんじ")
        #expect(!appleIME.decode("kanji").ok)
        // ca/ci/cu/ce/co, yi, wu: Microsoft ([M2]) only
        #expect(microsoftIME.decode("ca").output == "か")
        #expect(!appleIME.decode("ca").ok)
        // ~ : Apple WAVE DASH, Microsoft FULLWIDTH TILDE (from memory, see README)
        #expect(appleIME.decode("~").output == "〜")
        #expect(microsoftIME.decode("~").output == "～")
    }

    /// The complete, mechanically derived difference between the two romaji tables. If a source
    /// table is re-transcribed, this pins what changed. Listed in the README.
    @Test func completeTableDifference() {
        var a: [String: String] = [:]; for (r, k) in appleRomajiTable { a[r] = k }
        var m: [String: String] = [:]; for (r, k) in microsoftRomajiTable { m[r] = k }
        let appleOnly = a.keys.filter { m[$0] == nil }.sorted()
        let microsoftOnly = m.keys.filter { a[$0] == nil }.sorted()
        let differing = a.keys.filter { m[$0] != nil && m[$0] != a[$0] }.sorted()
        #expect(appleOnly == ["hwa", "hwe", "hwi", "hwo", "kwe", "kwi", "kwo", "kwu"])
        #expect(microsoftOnly == ["ca", "ce", "ci", "co", "cu", "lyi", "vye", "vyi", "whu", "wu", "xyi", "yi"])
        #expect(differing == ["qu", "qwa", "va", "ve", "vi", "vo", "vu", "vya", "vyo", "vyu"])
        // The library emits none of the one-sided or conflicting spellings except the v-row,
        // whose difference is only hiragana ゔ vs katakana ヴ.
        let avoided = Set(appleOnly + microsoftOnly + ["qu", "qwa"])
        for (_, keys) in KanaRomaji.digraphTable { #expect(!avoided.contains(keys)) }
        for (_, keys) in KanaRomaji.perKanaTable { #expect(!avoided.contains(keys)) }
    }

    @Test func hostFoldIgnoresScriptAndWidthOnly() {
        #expect(hostFold("ヴァｶﾞ１～") == "ゔぁが1〜")
        #expect(hostFold("か") != hostFold("が"))
    }
}
