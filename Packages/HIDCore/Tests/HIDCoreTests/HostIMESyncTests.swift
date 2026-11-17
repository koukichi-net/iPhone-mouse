import Testing
@testable import HIDCore

@Suite("Host IME mode sync")
struct HostIMESyncTests {
    @Test func englishKeyboardFromUnknownAssertsEisuOnce() {
        var r = TextEntryRouter()
        let p = r.insert("n", keyboard: .other, at: 1)
        #expect(p.steps == [.imeKey(.lang2), .type("n")])
        #expect(p.imeNotes.count == 1)
        #expect(r.hostMode == .eisu)
        #expect(r.insert("i", keyboard: .other, at: 1.2).steps == [.type("i")])
        #expect(r.insert(" ", keyboard: .other, at: 1.4).steps == [.type(" ")])
    }

    @Test func japaneseCompositionFromUnknownAssertsKanaOnce() {
        var r = TextEntryRouter()
        #expect(r.compositionEvent(at: 1).steps == [.imeKey(.lang1)])
        #expect(r.hostMode == .kana)
        #expect(r.compositionEvent(at: 1.3).steps == [])
        #expect(r.compositionEvent(at: 5).steps == [])
    }

    @Test func everyKeyAssertsFromUnknownIncludingBackspaceAndReturn() {
        var r = TextEntryRouter()
        #expect(r.deleteBackward(keyboard: .other, at: 1).steps == [.imeKey(.lang2), .backspace])
        var s = TextEntryRouter()
        #expect(s.insert("\n", keyboard: .other, at: 1).steps == [.imeKey(.lang2), .type("\n")])
        var t = TextEntryRouter()
        #expect(t.insert("1", keyboard: .japanese, at: 1).steps == [.imeKey(.lang1), .type("1")])
    }

    @Test func keyboardChangeIsAssertedLazilyBeforeTheNextKey() {
        var r = TextEntryRouter()
        _ = r.insert("a", keyboard: .other, at: 0)                       // 英数
        // A keyboard change itself calls nothing; the next key in the new mode asserts.
        #expect(r.compositionEvent(at: 3).steps == [.imeKey(.lang1)])
        #expect(r.insert("b", keyboard: .other, at: 6).steps == [.imeKey(.lang2), .type("b")])
        // Digit from the Japanese keyboard right after a change: かな.
        #expect(r.insert("1", keyboard: .japanese, at: 9).steps == [.imeKey(.lang1), .type("1")])
        // Same keyboard, mode known: digits do not switch.
        #expect(r.insert("2", keyboard: .japanese, at: 9.5).steps == [.type("2")])
    }

    @Test func resetsMakeTheNextKeyAssertAgain() {
        var r = TextEntryRouter()
        _ = r.insert("a", keyboard: .other, at: 0)
        for (i, reason) in ["text field focus", "app foreground", "active host change"].enumerated() {
            let t = Double(10 * (i + 1))
            r.forgetHostState(reason: reason, newHost: reason.contains("host"))
            #expect(r.hostMode == .unknown)
            let p = r.insert("a", keyboard: .other, at: t)
            #expect(p.steps == [.imeKey(.lang2), .type("a")])
            #expect(p.imeNotes.first?.contains(reason) == true)
        }
    }

    @Test func idleResetsTheMode() {
        var r = TextEntryRouter()
        _ = r.insert("a", keyboard: .other, at: 0)
        #expect(r.insert("b", keyboard: .other, at: 29).steps == [.type("b")])      // 29 s: still known
        let p = r.insert("c", keyboard: .other, at: 29 + HostIMESync.defaultIdleReset)
        #expect(p.steps == [.imeKey(.lang2), .type("c")])
        #expect(p.imeNotes.first?.contains("idle") == true)
        // Composition events count as activity.
        _ = r.compositionEvent(at: 100)
        _ = r.compositionEvent(at: 120)
        #expect(r.compositionEvent(at: 140).steps == [])
    }

    @Test func sameLangKeyIsNeverSentTwiceInARowWithinTheWindow() {
        var r = TextEntryRouter()
        _ = r.insert("a", keyboard: .other, at: 0)                       // LANG2 at 0
        r.forgetHostState(reason: "text field focus")
        let p = r.insert("b", keyboard: .other, at: 0.5)
        #expect(p.steps == [.type("b")])
        #expect(p.imeNotes.first?.contains("suppressed") == true)
        #expect(r.hostMode == .eisu)                                      // assumed
        r.forgetHostState(reason: "text field focus")
        #expect(r.insert("c", keyboard: .other, at: 5).steps == [.imeKey(.lang2), .type("c")])
        // A different LANG key in between: not "in a row".
        _ = r.compositionEvent(at: 5.2)                                    // LANG1
        #expect(r.insert("d", keyboard: .other, at: 5.4).steps == [.imeKey(.lang2), .type("d")])
    }

    @Test func manualPanelKeyCountsForTheRepeatGuard() {
        var r = TextEntryRouter()
        _ = r.insert("a", keyboard: .other, at: 0)
        r.noteManualIMEKey(.lang1, at: 10)
        #expect(r.hostMode == .unknown)
        let p = r.compositionEvent(at: 10.4)
        #expect(p.steps == [])                                            // no double かな
        #expect(r.hostMode == .kana)
        r.noteManualIMEKey(.lang1, at: 20)
        #expect(r.insert("x", keyboard: .other, at: 20.3).steps == [.imeKey(.lang2), .type("x")])   // different key
        r.noteManualIMEKey(.lang2, at: 30)
        #expect(r.insert("y", keyboard: .other, at: 30.5).steps == [.type("y")])                      // no double 英数
        r.noteManualIMEKey(.lang2, at: 40)
        #expect(r.insert("z", keyboard: .other, at: 45).steps == [.imeKey(.lang2), .type("z")])     // window over
    }

    @Test func hostChangeClearsTheRepeatGuard() {
        var r = TextEntryRouter()
        _ = r.insert("a", keyboard: .other, at: 0)
        r.forgetHostState(reason: "active host change", newHost: true)
        #expect(r.insert("b", keyboard: .other, at: 0.2).steps == [.imeKey(.lang2), .type("b")])
    }

    @Test func switchOffSendsNoLangKeysAndKeepsUnknown() {
        var r = TextEntryRouter(autoSwitch: false)
        #expect(r.compositionEvent(at: 0).steps == [])
        #expect(r.insert("a", keyboard: .other, at: 1).steps == [.type("a")])
        #expect(r.deleteBackward(keyboard: .other, at: 2).steps == [.backspace])
        #expect(r.hostMode == .unknown)
        r.autoSwitch = true
        #expect(r.insert("a", keyboard: .other, at: 3).steps == [.imeKey(.lang2), .type("a")])
    }

    @Test func unsentCharactersDoNotAssert() {
        var r = TextEntryRouter()
        #expect(r.insert("😀", keyboard: .other, at: 0).steps == [])
        #expect(r.hostMode == .unknown)
        #expect(r.deleteBackward(keyboard: .other, at: 1).steps == [])   // deleting it sends nothing
        #expect(r.hostMode == .unknown)
    }
}
