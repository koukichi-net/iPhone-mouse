import Testing
@testable import HIDCore

@Suite("TextEntryRouter")
struct TextEntryRouterTests {
    // MARK: Mode switching

    @Test func firstKanaSendsKanaOnceThenRomaji() {
        var r = TextEntryRouter()
        #expect(r.hostMode == .unknown)
        #expect(r.insert("か", keyboard: .japanese).steps == [.imeKey(.lang1), .type("ka")])
        #expect(r.hostMode == .kana)
        #expect(r.insert("な", keyboard: .japanese).steps == [.type("na")])
        #expect(r.insert("きゃっ", keyboard: .japanese).steps == [.type("kixyaxtu")])
        #expect(r.insert("ん", keyboard: .japanese).steps == [.type("nn")])
    }

    @Test func letterAfterKanaSendsEisuEvenFromTheJapaneseKeyboard() {
        var r = TextEntryRouter()
        _ = r.insert("あ", keyboard: .japanese)
        #expect(r.insert("a", keyboard: .japanese).steps == [.imeKey(.lang2), .type("a")])
        #expect(r.hostMode == .eisu)
        #expect(r.insert("b", keyboard: .other).steps == [.type("b")])
        #expect(r.insert("い", keyboard: .japanese).steps == [.imeKey(.lang1), .type("i")])
    }

    @Test func asciiFromUnknownStateAssertsEisu() {
        // 2026-11-18: from the unknown state the mode is asserted (the old rule sent nothing
        // and left the host in whatever mode it was in). Consequence: panel かな followed by
        // romaji on an English keyboard no longer stays in かな — the first letter sends 英数.
        var r = TextEntryRouter()
        #expect(r.insert("nihongo", keyboard: .other).steps == [.imeKey(.lang2), .type("nihongo")])
        #expect(r.insert("123.", keyboard: .other).steps == [.type("123.")])
        _ = r.insert("か", keyboard: .japanese, at: 10)
        r.forgetHostState(reason: "test")
        #expect(r.insert("ka", keyboard: .other, at: 20).steps == [.imeKey(.lang2), .type("ka")])
        #expect(r.insert("か", keyboard: .japanese, at: 30).steps == [.imeKey(.lang1), .type("ka")])
    }

    @Test func kanaContextCharactersDoNotSwitchToEisu() {
        var r = TextEntryRouter()
        _ = r.insert("か", keyboard: .japanese)
        #expect(r.insert(" ", keyboard: .japanese).steps == [.type(" ")])
        #expect(r.insert("\u{3000}", keyboard: .japanese).steps == [.type(" ")])
        #expect(r.insert("\n", keyboard: .japanese).steps == [.type("\n")])
        #expect(r.insert("、。「」・ー？！", keyboard: .japanese).steps == [.type(",.[]/-?!")])
        #expect(r.insert("1", keyboard: .japanese).steps == [.type("1")])       // digit pane of the kana keyboard
        #expect(r.insert("?", keyboard: .japanese).steps == [.type("?")])
        #expect(r.hostMode == .kana)
        // 2026-11-18: Space and Return from an English keyboard follow that keyboard (英数).
        #expect(r.insert(" ", keyboard: .other).steps == [.imeKey(.lang2), .type(" ")])
        #expect(r.insert("\n", keyboard: .other).steps == [.type("\n")])
        #expect(r.hostMode == .eisu)
    }

    @Test func digitsAndSymbolsFromAnEnglishKeyboardAfterKanaSwitch() {
        var r = TextEntryRouter()
        _ = r.insert("か", keyboard: .japanese)
        #expect(r.insert("1", keyboard: .other).steps == [.imeKey(.lang2), .type("1")])
        var s = TextEntryRouter()
        _ = s.insert("か", keyboard: .japanese)
        #expect(s.insert(".", keyboard: .unknown).steps == [.imeKey(.lang2), .type(".")])
    }

    @Test func mixedChunkSwitchesInsideTheChunk() {
        var r = TextEntryRouter()
        let p = r.insert("かA", keyboard: .japanese)
        #expect(p.steps == [.imeKey(.lang1), .type("ka"), .imeKey(.lang2), .type("A")])
    }

    @Test func unsendableIsReportedAndSendsNothing() {
        var r = TextEntryRouter()
        let k = r.insert("漢", keyboard: .japanese)
        #expect(k.steps.isEmpty)
        #expect(k.unsendable.map(\.character) == ["漢"])
        #expect(k.unsendable.first?.reason == .kanji)
        #expect(r.hostMode == .unknown)   // no かな for nothing
        let mixed = r.insert("漢字です😀", keyboard: .japanese)
        #expect(mixed.steps == [.imeKey(.lang1), .type("desu")])
        #expect(mixed.unsendable.map(\.characterOffset) == [0, 1, 4])
        #expect(mixed.unsendable.last?.reason == .emoji)
    }

    @Test func autoSwitchOffNeverSendsLangKeys() {
        var r = TextEntryRouter(autoSwitch: false)
        #expect(r.insert("か", keyboard: .japanese).steps == [.type("ka")])
        #expect(r.insert("a", keyboard: .other).steps == [.type("a")])
        #expect(r.hostMode == .unknown)
    }

    @Test func approximationsAreSentAndListed() {
        var r = TextEntryRouter()
        _ = r.insert("か", keyboard: .japanese)
        let p = r.insert("Ａ", keyboard: .japanese)   // full-width letter: sent half-width with 英数
        #expect(p.steps == [.imeKey(.lang2), .type("A")])
        #expect(p.approximations.count == 1)
    }

    // MARK: Backspace shadow

    @Test func flickDakutenAsDeleteAndInsert() {
        var r = TextEntryRouter()
        _ = r.insert("か", keyboard: .japanese)
        #expect(r.deleteBackward().steps == [.backspace])
        #expect(r.insert("が", keyboard: .japanese).steps == [.type("ga")])
        #expect(r.deleteBackward().steps == [.backspace])
        #expect(r.insert("か", keyboard: .japanese).steps == [.type("ka")])
    }

    @Test func deletingUnsentCharactersSendsNothing() {
        var r = TextEntryRouter()
        _ = r.insert("か", keyboard: .japanese)
        _ = r.insert("漢字", keyboard: .japanese)
        #expect(r.deleteBackward().steps == [])
        #expect(r.deleteBackward().steps == [])
        #expect(r.deleteBackward().steps == [.backspace])
        #expect(r.deleteBackward().steps == [.backspace])   // no shadow: host text, always sent
        _ = r.insert("か", keyboard: .japanese)
        _ = r.insert(" ", keyboard: .japanese)              // Space: the shadow is unknown
        #expect(r.deleteBackward().steps == [.backspace])
    }

    // MARK: Keyboard mode

    @Test func keyboardModeFromPrimaryLanguage() {
        #expect(KeyboardInputMode(primaryLanguage: "ja-JP") == .japanese)
        #expect(KeyboardInputMode(primaryLanguage: "en-US") == .other)
        #expect(KeyboardInputMode(primaryLanguage: "emoji") == .other)
        #expect(KeyboardInputMode(primaryLanguage: nil) == .unknown)
    }

    // MARK: Reports

    private func reports(_ text: String, _ map: KeyMap, keyboard: KeyboardInputMode = .japanese) -> [KeyboardReport] {
        var r = TextEntryRouter()
        var state = KeyboardState()
        return r.insert(text, keyboard: keyboard).reports(state: &state, keyMap: map).reports
    }

    private func press(_ u: KeyUsage, _ m: KeyModifiers = []) -> [KeyboardReport] {
        [KeyboardReport(modifiers: m, keys: [u]), KeyboardReport(modifiers: m)]
    }

    @Test func kanaReportsOnUSAndJIS() {
        let ga = press(.lang1) + press(.g) + press(.a)
        #expect(reports("が", KeyMap(layout: .us)) == ga)
        #expect(reports("が", KeyMap(layout: .jis)) == ga)
        // 「ー」: brackets sit on different keys on US and JIS.
        let us = press(.lang1) + press(.leftBracket) + press(.minus) + press(.rightBracket)
        let jis = press(.lang1) + press(.rightBracket) + press(.minus) + press(.backslash)
        #expect(reports("「ー」", KeyMap(layout: .us)) == us)
        #expect(reports("「ー」", KeyMap(layout: .jis)) == jis)
        // ？ needs Shift on both layouts; 〜 is Shift+` on US and Shift+^ on JIS.
        #expect(reports("？", KeyMap(layout: .us)) == press(.lang1) + [KeyboardReport(modifiers: .leftShift)] + press(.slash, .leftShift) + [.empty])
        #expect(reports("〜", KeyMap(layout: .jis)) == press(.lang1) + [KeyboardReport(modifiers: .leftShift)] + press(.equal, .leftShift) + [.empty])
    }

    @Test func langKeyIgnoresLatchedShiftWhichStillAppliesAfterwards() {
        var state = KeyboardState()
        _ = state.modifierDown(.shift, at: 0)
        _ = state.modifierUp(.shift, at: 0.05)
        #expect(state.state(of: .shift) == .latched)
        #expect(state.tapBare(.lang1) == press(.lang1))
        #expect(state.state(of: .shift) == .latched)
    }

    @Test func backspaceStepIsTheBackspaceKey() {
        var r = TextEntryRouter()
        var state = KeyboardState()
        _ = r.insert("か", keyboard: .japanese)
        #expect(r.deleteBackward().reports(state: &state, keyMap: .us).reports == press(.backspace))
    }
}
