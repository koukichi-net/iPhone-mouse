import Testing
@testable import HIDCore

/// Fixtures from the TEXTCAP capture of 2026-11-18 00:41–00:55 (App/build/run-capture-0041-0055.log):
/// events as the app derives them from the post-change state of the field (times in seconds of
/// the log's wall clock), flushed like the app does (after `quiet` without a new event).
@Suite("CompositionMirror")
struct CompositionMirrorTests {
    typealias E = CompositionMirror.Event

    /// Feeds timed events, flushing whenever the app's timer would, then at the end.
    private func play(_ r: inout TextEntryRouter, _ events: [(Double, E)]) -> [TextEntryRouter.Plan] {
        var plans: [TextEntryRouter.Plan] = []
        func flush(_ t: Double) {
            if let due = r.mirror.nextFlushTime, t >= due {
                let p = r.mirrorFlush(at: due)
                if !p.mirror.isEmpty || !p.steps.isEmpty { plans.append(p) }
            }
        }
        for (t, e) in events {
            flush(t)
            r.mirrorReceive(e, at: t)
        }
        flush(.infinity)
        return plans
    }

    private func steps(_ plans: [TextEntryRouter.Plan]) -> [TextEntryRouter.Step] { plans.flatMap(\.steps) }
    private func ro(_ s: String) -> String { TextEntryRouter.romaji(s) }
    private func returns(_ s: [TextEntryRouter.Step]) -> Int { s.filter { $0 == .type("\n") }.count }

    // MARK: Captured sequences

    @Test func konnichiwaThenKakuteiThenTwoReturns() {
        // 00:41:42.976–00:41:47.458
        var r = TextEntryRouter()
        let plans = play(&r, [
            (42.990, .marked("こ")), (43.281, .marked("こん")), (43.544, .marked("こんに")),
            (44.530, .marked("こんにち")), (44.810, .marked("こんにちは")),
            // 確定: shouldChangeTextIn {0,5} same text, setAttributedMarkedText same (no new
            // state), unmarkText in the same millisecond.
            (45.095, .ended(committed: "こんにちは", reading: "こんにちは")),
            (46.740, .inserted("\n")), (47.458, .inserted("\n")),
        ])
        #expect(steps(plans) == [.imeKey(.lang1), .type("ko"), .type(ro("ん")), .type(ro("に")), .type(ro("ち")), .type(ro("は")),
                                 .type("\n"), .type("\n"), .type("\n")])
        #expect(plans.allSatisfy { !$0.hint })
        #expect(r.mirror.hostReading.isEmpty && !r.mirror.hostComposing)
    }

    @Test func deleteDuringCompositionToEmpty() {
        // 00:55:19.049–00:55:19.202: お, then delete → text "" marked nil.
        var r = TextEntryRouter()
        let plans = play(&r, [(19.060, .marked("お")), (19.202, .ended(committed: "", reading: nil))])
        #expect(steps(plans) == [.imeKey(.lang1), .type("o"), .backspace])
        #expect(returns(steps(plans)) == 0)
    }

    @Test func dakutenReplacesTheLastKana() {
        // 00:55:26.640 / 26.772: おくられてないて → おくられてないで (shouldChangeTextIn {8,0} "゛").
        var r = TextEntryRouter()
        _ = play(&r, [(26.0, .marked("おくられてないて"))])
        let p = play(&r, [(26.772, .marked("おくられてないで"))])
        #expect(steps(p) == [.backspace, .type("de")])
    }

    @Test func candidateTapConvertsTheSameReadingOnTheHost() {
        // 00:55:24.883–00:55:27.605: おくられてないですね, candidate 送られてないですね
        // (marked = candidate at 27.342, unmarkText at 27.345), then the keyboard's Return.
        var r = TextEntryRouter()
        let typing = ["お", "おく", "おくら", "おくられ", "おくられて", "おくられてな", "おくられてない",
                      "おくられてないて", "おくられてないで", "おくられてないです", "おくられてないですね"]
        let times = [24.883, 25.185, 25.491, 25.750, 25.897, 26.152, 26.340, 26.640, 26.772, 26.906, 27.155]
        var events: [(Double, E)] = zip(times, typing).map { ($0, .marked($1)) }
        events += [(27.342, .marked("送られてないですね")),
                   (27.345, .ended(committed: "送られてないですね", reading: "おくられてないですね"))]
        let plans = play(&r, events)
        let s = steps(plans)
        #expect(returns(s) == 0)
        #expect(s.last == .type(" "))                       // host converts
        #expect(!s.contains(.backspace) || s.filter { $0 == .backspace }.count == 1)   // only the て→で edit
        #expect(plans.last?.hint == true)
        #expect(r.mirror.converted && r.mirror.detached)
        // The phone's Return 253 ms later: Return on the host (commits its conversion).
        let after = play(&r, [(27.605, .inserted("\n"))])
        #expect(steps(after) == [.type("\n")])
        #expect(!r.mirror.hostComposing)
    }

    @Test func keyboardSwitchMidCompositionReturnsOnce() {
        // 00:44:24.661–00:44:30.795: おんに, then unmarkText (commit as is) and a second
        // unmarkText with nothing marked (no event), then the keyboard changed.
        var r = TextEntryRouter()
        let plans = play(&r, [(24.661, .marked("お")), (25.012, .marked("おん")), (25.296, .marked("おんに")),
                              (30.772, .ended(committed: "おんに", reading: "おんに"))])
        #expect(returns(steps(plans)) == 1)
        #expect(steps(plans).last == .type("\n"))
    }

    @Test func intermediateCandidateStateIsNeverTakenAsAConversion() {
        // If the candidate's marked state were processed alone it would be rule 3 (Space) and
        // the commit would equal it (Return). The batch must drop it.
        var r = TextEntryRouter()
        _ = play(&r, [(0, .marked("おく"))])
        r.mirrorReceive(.marked("送"), at: 1.000)
        #expect(r.mirrorFlush(at: 1.001).steps.isEmpty)     // not quiet yet
        r.mirrorReceive(.ended(committed: "送", reading: "おく"), at: 1.001)
        let p = r.mirrorFlush(at: 1.001 + CompositionMirror.defaultQuiet)
        #expect(p.steps == [.type(" ")])
        #expect(returns(p.steps) == 0)
    }

    // MARK: Rule 3

    @Test func phoneConversionSendsSpacePerCandidateAndKakuteiReturns() {
        var r = TextEntryRouter()
        _ = play(&r, [(0, .marked("かんじ"))])
        #expect(steps(play(&r, [(1, .marked("漢字"))])) == [.type(" ")])
        #expect(steps(play(&r, [(2, .marked("感じ"))])) == [.type(" ")])
        #expect(steps(play(&r, [(3, .ended(committed: "感じ", reading: "かんじ"))])) == [.type("\n")])
        #expect(!r.mirror.hostComposing)
    }

    @Test func katakanaWhileMarkedIsAConversion() {
        var r = TextEntryRouter()
        _ = play(&r, [(0, .marked("かな"))])
        #expect(steps(play(&r, [(1, .marked("カナ"))])) == [.type(" ")])
    }

    @Test func cancelledConversionSendsNothingUntilTheCompositionEnds() {
        var r = TextEntryRouter()
        _ = play(&r, [(0, .marked("かんじ")), (1, .marked("漢字"))])
        let p = play(&r, [(2, .marked("かんじ")), (3, .marked("かんじを"))])
        #expect(steps(p).isEmpty)
        #expect(p.first?.hint == true)
        let end = play(&r, [(4, .ended(committed: "かんじを", reading: "かんじを"))])
        #expect(steps(end).isEmpty)                        // no Return, no Escape
        // Next composition: the host commits its leftover itself; no Backspace, no LANG key.
        #expect(steps(play(&r, [(5, .marked("あ"))])) == [.type("a")])
    }

    // MARK: Rule 5 variants

    @Test func candidateAfterHostConversionSendsNothing() {
        var r = TextEntryRouter()
        _ = play(&r, [(0, .marked("かんじ")), (1, .marked("漢字"))])
        let p = play(&r, [(2, .marked("幹事")), (2.001, .ended(committed: "幹事", reading: "かんじ"))])
        #expect(steps(p).isEmpty)
        #expect(p.last?.hint == true)
    }

    @Test func predictiveCandidateLongerThanTyped() {
        var r = TextEntryRouter()
        _ = play(&r, [(0, .marked("お")), (0.3, .marked("おく"))])
        let p = play(&r, [(1, .ended(committed: "送らない", reading: "おくらない"))])
        #expect(steps(p) == [.type(ro("らない") + " ")])   // kana then Space (one typed run)
        #expect(p.first?.hint == true)
    }

    @Test func readingShorterThanTyped() {
        var r = TextEntryRouter()
        _ = play(&r, [(0, .marked("おくられ"))])
        #expect(steps(play(&r, [(1, .ended(committed: "送", reading: "おく"))])) == [.backspace, .backspace, .type(" ")])
    }

    @Test func noUsableReadingSendsNothing() {
        for reading in [nil, "", "いぷほね😀", "コンピュータ", "ipho"] as [String?] {
            var r = TextEntryRouter()
            _ = play(&r, [(0, .marked("あ"))])
            let p = play(&r, [(1, .ended(committed: "😀", reading: reading))])
            #expect(steps(p).isEmpty)
            #expect(p.first?.hint == true)
            // The host still holds "あ": the next composition starts without Backspaces.
            #expect(steps(play(&r, [(2, .marked("い"))])) == [.type("i")])
        }
    }

    @Test func spaceOutsideAfterCandidateGoesToTheHost() {
        var r = TextEntryRouter()
        _ = play(&r, [(0, .marked("おく")), (1, .ended(committed: "億", reading: "おく"))])
        #expect(steps(play(&r, [(2, .inserted(" "))])) == [.type(" ")])     // next host candidate
        #expect(r.mirror.detached)
        #expect(steps(play(&r, [(3, .inserted("\n"))])) == [.type("\n")])
        #expect(!r.mirror.hostComposing)
    }

    // MARK: Rule 2 details

    @Test func pendingAsciiLettersAreNotMirrored() {
        var r = TextEntryRouter()
        #expect(steps(play(&r, [(0, .marked("かn"))])) == [.imeKey(.lang1), .type("ka")])
        #expect(steps(play(&r, [(1, .marked("かな"))])) == [.type("na")])
        #expect(steps(play(&r, [(2, .marked("かなk"))])).isEmpty)
    }

    @Test func decomposedInputIsNormalised() {
        var r = TextEntryRouter()
        _ = play(&r, [(0, .marked("か"))])
        #expect(steps(play(&r, [(1, .marked("か\u{3099}"))])) == [.backspace, .type("ga")])
        #expect(steps(play(&r, [(2, .marked("が"))])).isEmpty)
    }

    @Test func noLangKeyWhileTheHostComposesEvenAfterIdle() {
        var r = TextEntryRouter()
        _ = play(&r, [(0, .marked("お"))])
        #expect(steps(play(&r, [(100, .marked("おく"))])) == [.type("ku")])
        #expect(steps(play(&r, [(101, .ended(committed: "おく", reading: "おく"))])) == [.type("\n")])
        // New composition after idle: asserted again.
        #expect(steps(play(&r, [(200, .marked("あ"))])) == [.imeKey(.lang1), .type("a")])
    }

    @Test func punctuationOutsideACompositionLeavesTheHostComposing() {
        var r = TextEntryRouter()
        #expect(steps(play(&r, [(0, .inserted("、"))])) == [.imeKey(.lang1), .type(",")])
        #expect(r.mirror.detached)
        #expect(steps(play(&r, [(1, .deleted)])) == [.backspace])
    }

    // MARK: Resets

    @Test func resetMidCompositionSendsNothingUntilItEnds() {
        var r = TextEntryRouter()
        _ = play(&r, [(0, .marked("か"))])
        r.mirrorReceive(.marked("かな"), at: 1)
        r.mirrorReset(phoneComposing: true)                 // e.g. host change: drops the pending event
        #expect(r.mirrorFlush(at: 10, force: true).steps.isEmpty)
        let p = play(&r, [(11, .marked("かなた")), (12, .ended(committed: "かなた", reading: "かなた"))])
        #expect(steps(p).isEmpty)                            // no Backspace, no Return
        r.forgetHostState(reason: "test", newHost: true)
        #expect(steps(play(&r, [(20, .marked("た"))])) == [.imeKey(.lang1), .type("ta")])
    }

    @Test func returnOnlyForKakuteiAndExplicitNewline() {
        // Over all fixtures above, Return comes only from rule 4 or "\n"; spot-check the rest.
        var r = TextEntryRouter()
        let p = play(&r, [(0, .marked("あ")), (1, .marked("亜")), (2, .marked("阿")),
                          (3, .marked("あい")), (4, .ended(committed: "愛", reading: "あい")),
                          (5, .inserted(" ")), (6, .deleted)])
        #expect(returns(steps(p)) == 0)
    }

    @Test func mirrorLineFormat() {
        var r = TextEntryRouter()
        _ = play(&r, [(0, .marked("お"))])
        let p = play(&r, [(1, .marked("おく"))])
        #expect(p.first?.mirror.first?.line(redact: false) == #"MIRROR marked "おく" hostReading="お"→"おく" converted=false → keys: "ku" (kana added)"#)
        #expect(p.first?.mirror.first?.line(redact: true) == #"MIRROR marked hostReading=<1>→<2> converted=false → keys: "…" (kana added)"#)
    }

    /// With the logging setting off, no typed character survives in a MIRROR line or an IME
    /// note: escaped quotes inside a literal and kana in notes included.
    @Test func redactionHidesTypedText() {
        #expect(LogRedaction.quoted(#"keys: "a\"b" and "c""#) == #"keys: "…" and "…""#)
        #expect(LogRedaction.quoted(#"LANG2(英数) reason: "\\" from a non-Japanese keyboard"#) == #"LANG2(英数) reason: "…" from a non-Japanese keyboard"#)
        var r = TextEntryRouter()
        let kana = r.insert("ぬ", keyboard: .japanese)
        #expect(!kana.imeNotes.isEmpty)
        for n in kana.imeNotes { #expect(!LogRedaction.quoted(n).contains("ぬ")) }
        let p = play(&r, [(10, .inserted("Q\"Z"))])
        for m in p.flatMap(\.mirror) {
            let line = m.line(redact: true)
            #expect(!line.contains("Q") && !line.contains("Z"), "\(line)")
        }
        for n in p.flatMap(\.imeNotes) { #expect(!LogRedaction.quoted(n).contains("Q")) }
    }
}
