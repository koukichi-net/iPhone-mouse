import Testing
@testable import HIDCore

private func kb(_ mods: KeyModifiers = [], _ keys: KeyUsage...) -> KeyboardReport {
    KeyboardReport(modifiers: mods, keys: keys)
}

@Suite("TextTyper")
struct TextTyperTests {
    let us = TextTyper(keyMap: .us)

    @Test func plainLetters() {
        #expect(us.reports(for: "ab").reports == [kb([], .a), kb(), kb([], .b), kb()])
    }

    @Test func repeatedCharacterIsReleasedBetweenPresses() {
        #expect(us.reports(for: "ll").reports == [kb([], .l), kb(), kb([], .l), kb()])
    }

    @Test func shiftIsPressedFirstAndKeptAcrossSameModifierRun() {
        let out = us.reports(for: "aBC!d").reports
        #expect(out == [
            kb([], .a), kb(),
            kb(.shift),                       // Shift down before the key
            kb(.shift, .b), kb(.shift),
            kb(.shift, .c), kb(.shift),
            kb(.shift, .digit1), kb(.shift),  // "!"
            kb(),                             // Shift up
            kb([], .d), kb(),
        ])
    }

    @Test func endsWithAllReleasedWhenModifierHeld() {
        let out = us.reports(for: "A").reports
        #expect(out == [kb(.shift), kb(.shift, .a), kb(.shift), kb()])
        #expect(out.last == .empty)
    }

    @Test func modifierSwitchOnJISMac() {
        let t = TextTyper(keyMap: KeyMap(layout: .jis, host: .macOS))
        #expect(t.reports(for: "|\\").reports == [
            kb(.shift), kb(.shift, .international3), kb(.shift),
            kb(.option), kb(.option, .international3), kb(.option),
            kb(),
        ])
    }

    @Test func skippedCharactersAreReported() {
        let out = us.reports(for: "aé\nあb")
        #expect(out.reports == [kb([], .a), kb(), kb([], .returnKey), kb(), kb([], .b), kb()])
        #expect(out.skipped == [
            TextTyper.SkippedCharacter(offset: 1, character: "é"),
            TextTyper.SkippedCharacter(offset: 3, character: "あ"),
        ])
    }

    @Test func emptyAndAllSkipped() {
        #expect(us.reports(for: "").reports.isEmpty)
        let out = us.reports(for: "日本")
        #expect(out.reports.isEmpty && out.skipped.count == 2)
    }

    @Test func crlfIsOneReturn() {
        #expect(us.reports(for: "a\r\nb").reports == [kb([], .a), kb(), kb([], .returnKey), kb(), kb([], .b), kb()])
    }

    @Test func everyPressIsFollowedByRelease() {
        let text = String(printableASCII)
        for map in [KeyMap.us, KeyMap(layout: .jis, host: .windows), KeyMap(layout: .jis, host: .macOS)] {
            let out = TextTyper(keyMap: map).reports(for: text)
            #expect(out.skipped.isEmpty)
            #expect(out.reports.filter { !$0.keys.isEmpty }.count == text.count)
            for (i, r) in out.reports.enumerated() where !r.keys.isEmpty {
                #expect(r.keys.count == 1)
                #expect(out.reports[i + 1].keys.isEmpty && out.reports[i + 1].modifiers == r.modifiers)
                if i > 0 { #expect(out.reports[i - 1].modifiers == r.modifiers) }
            }
            #expect(out.reports.last == .empty)
        }
    }
}
