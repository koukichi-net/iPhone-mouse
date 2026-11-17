// Merged from spike/kana-romaji/Tests/KanaRomajiTests/ClassificationTests.swift (2026-11-17 23:38, sha256 4f6c4d7309f5).
import Testing
@testable import HIDCore

typealias K = KanaRomaji

struct ClassificationTests {

    @Test(arguments: [
        ("", K.InputClass.empty),
        ("か", .kanaLike), ("カタカナ", .kanaLike), ("ｶﾞ", .kanaLike), ("。", .kanaLike),
        ("、「」", .kanaLike), ("１２", .kanaLike), ("\u{3000}", .kanaLike), ("ゕ", .kanaLike),
        ("a", .asciiLike), ("Hello, world!", .asciiLike), ("123", .asciiLike), ("\n", .asciiLike),
        ("Ａ", .asciiLike), ("／", .asciiLike),
        ("abcか", .mixed), ("3じ", .mixed), ("か a", .mixed),
        ("漢字です", .partiallySendable), ("かな👍", .partiallySendable), ("a漢", .partiallySendable),
        ("漢字", .unsendable), ("👍", .unsendable), ("👨‍👩‍👧🇯🇵", .unsendable), ("々", .unsendable),
        ("『』", .unsendable),
    ])
    func classify(input: String, expected: K.InputClass) {
        #expect(K.classify(input) == expected)
        #expect(K.convert(input).inputClass == expected)
        #expect(K.convert(input, mode: .natural).inputClass == expected)
    }

    @Test func emptyInput() {
        for mode in [K.Mode.perKana, .natural] {
            let c = K.convert("", mode: mode)
            #expect(c.segments.isEmpty && c.unconvertible.isEmpty && c.approximations.isEmpty)
            #expect(c.keys == "" && c.isComplete)
        }
    }

    @Test func asciiPassesThroughUnchangedAsDirect() {
        let c = K.convert("Hello, World! 123 ~")
        #expect(c.segments == [K.Segment(kind: .direct, keys: "Hello, World! 123 ~",
                                         characterRange: 0..<19, utf16Range: 0..<19)])
    }

    @Test func mixedChunkIsSplitIntoSegments() {
        let c = K.convert("abcかな。OK")
        #expect(c.segments.map(\.kind) == [.direct, .ime, .direct])
        #expect(c.segments.map(\.keys) == ["abc", "kana.", "OK"])
        #expect(c.segments.map(\.characterRange) == [0..<3, 3..<6, 6..<8])
    }

    @Test func unconvertibleOffsetsAreCharacterAndUTF16() {
        // "a" (1 unit), "👍🏽" (4 UTF-16 units, 1 Character), "か", "漢", "ｶﾞ" (2 units, 1 Character), "😀"
        let c = K.convert("a👍🏽か漢ｶﾞ😀")
        #expect(c.unconvertible.map(\.characterOffset) == [1, 3, 5])
        #expect(c.unconvertible.map(\.utf16Offset) == [1, 6, 9])
        #expect(c.unconvertible.map(\.reason) == [.emoji, .kanji, .emoji])
        #expect(c.unconvertible.map(\.character) == ["👍🏽", "漢", "😀"])
        // segments are split at the dropped characters
        #expect(c.segments.map(\.keys) == ["a", "ka", "ga"])
        #expect(c.segments.map(\.kind) == [.direct, .ime, .ime])
        #expect(c.segments.map(\.characterRange) == [0..<1, 2..<3, 4..<5])
        #expect(c.segments.map(\.utf16Range) == [0..<1, 5..<6, 7..<9])
        #expect(c.keys == "akaga")
        #expect(!c.isComplete)
    }

    @Test func kanjiStringReportsEveryCharacter() {
        let c = K.convert("日本語")
        #expect(c.segments.isEmpty)
        #expect(c.unconvertible.map(\.characterOffset) == [0, 1, 2])
        #expect(c.unconvertible.allSatisfy { $0.reason == .kanji })
    }

    @Test func fullWidthSpaceIsItsOwnSegment() {
        let c = K.convert("か\u{3000}な")
        #expect(c.segments.map(\.kind) == [.ime, .space, .ime])
        #expect(c.segments.map(\.keys) == ["ka", " ", "na"])
    }

    /// Pins current behaviour: ASCII space, tab and newline are plain `.direct` ASCII. Callers must
    /// intercept the phone's space / return keys BEFORE converting (see README "Caller guidance"),
    /// otherwise "かな\n" looks like a chunk that needs the IME switched off.
    @Test func asciiSpaceAndNewlineAreDirect() {
        #expect(K.classify(" ") == .asciiLike)
        #expect(K.classify("\n") == .asciiLike)
        let c = K.convert("かな\n")
        #expect(c.inputClass == .mixed)
        #expect(c.segments.map(\.kind) == [.ime, .direct])
        #expect(c.segments.map(\.keys) == ["kana", "\n"])
    }

    @Test func approximationsAreReported() {
        let c = K.convert("ＡＢか／ゕ")
        #expect(c.segments.map(\.kind) == [.direct, .ime, .direct, .ime])
        #expect(c.segments.map(\.keys) == ["AB", "ka", "/", "xka"])
        #expect(c.approximations.map(\.characterOffset) == [0, 1, 3, 4])
        #expect(c.isComplete)
    }

    @Test func mixedRoundTrip() {
        for s in ["abcかな。OK", "か漢字な", "Ａか", "3じ", "a👍🏽か漢ｶﾞ😀", "ｶﾞｯﾂ!", "ゕ月"] {
            expectRoundTrip(s, mode: .perKana)
            expectRoundTrip(s, mode: .natural)
        }
    }

    @Test func naturalModeDoesNotMergeAcrossDroppedOrDirectCharacters() {
        #expect(K.convert("っa", mode: .natural).keys == "xtua")
        #expect(K.convert("っ漢か", mode: .natural).keys == "xtuka")
        #expect(K.convert("き漢ゃ", mode: .natural).keys == "kixya")
    }
}
