import Testing
@testable import HIDCore

private func kb(_ mods: KeyModifiers = [], _ keys: KeyUsage...) -> KeyboardReport {
    KeyboardReport(modifiers: mods, keys: keys)
}

@Suite("KeyboardState")
struct KeyboardStateTests {
    @Test func plainKeyHoldsUntilRelease() {
        var s = KeyboardState()
        #expect(s.keyDown(.leftArrow) == [kb([], .leftArrow)])
        #expect(s.keyDown(.leftArrow).isEmpty)          // already down
        #expect(s.keyUp(.leftArrow) == [kb()])
        #expect(s.keyUp(.leftArrow).isEmpty)
    }

    @Test func modifierAloneSendsNothingAndLatches() {
        var s = KeyboardState()
        #expect(s.modifierDown(.command, at: 0).isEmpty)
        #expect(s.modifierUp(.command, at: 0.1).isEmpty)
        #expect(s.state(of: .command) == .latched)
    }

    @Test func latchedModifierIsOneShot() {
        var s = KeyboardState()
        _ = s.modifierDown(.shift, at: 0); _ = s.modifierUp(.shift, at: 0.05)
        #expect(s.keyDown(.tab) == [kb(.shift), kb(.shift, .tab)])
        #expect(s.state(of: .shift) == .off)
        #expect(s.keyUp(.tab) == [kb(.shift), kb()])     // key released before the modifier
        #expect(s.keyDown(.tab) == [kb([], .tab)])
        #expect(s.keyUp(.tab) == [kb()])
    }

    @Test func doubleTapLocksAndLockIsHeldAtHost() {
        var s = KeyboardState()
        _ = s.modifierDown(.command, at: 0); _ = s.modifierUp(.command, at: 0.05)
        _ = s.modifierDown(.command, at: 0.2)
        #expect(s.modifierUp(.command, at: 0.25) == [kb(.command)])   // locked: down at once
        #expect(s.state(of: .command) == .locked)
        #expect(s.keyDown(.c) == [kb(.command, .c)])
        #expect(s.keyUp(.c) == [kb(.command)])
        #expect(s.keyDown(.v) == [kb(.command, .v)])
        #expect(s.keyUp(.v) == [kb(.command)])
        _ = s.modifierDown(.command, at: 3)
        #expect(s.modifierUp(.command, at: 3.1) == [kb()])            // unlock releases
        #expect(s.state(of: .command) == .off)
    }

    @Test func slowSecondTapUnlatches() {
        var s = KeyboardState()
        _ = s.modifierDown(.option, at: 0); _ = s.modifierUp(.option, at: 0.05)
        _ = s.modifierDown(.option, at: 1.0); _ = s.modifierUp(.option, at: 1.05)
        #expect(s.state(of: .option) == .off)
    }

    @Test func heldModifierChordsAndStaysDownUntilLifted() {
        var s = KeyboardState()
        _ = s.modifierDown(.command, at: 0)
        #expect(s.keyDown(.tab) == [kb(.command), kb(.command, .tab)])
        #expect(s.keyUp(.tab) == [kb(.command)])
        #expect(s.keyDown(.tab) == [kb(.command, .tab)])
        #expect(s.keyUp(.tab) == [kb(.command)])
        #expect(s.modifierUp(.command, at: 2) == [kb()])
        #expect(s.state(of: .command) == .off)                         // chord, not a tap
    }

    @Test func modifierPressedWhileKeyDownApplies() {
        var s = KeyboardState()
        _ = s.keyDown(.rightArrow)
        #expect(s.modifierDown(.shift, at: 0) == [kb(.shift, .rightArrow)])
        #expect(s.keyUp(.rightArrow) == [kb(.shift)])
        #expect(s.modifierUp(.shift, at: 1) == [kb()])
        #expect(s.state(of: .shift) == .off)
    }

    @Test func modifierUsageAloneForSelfTest() {
        var s = KeyboardState()
        #expect(s.keyDown(.leftShift) == [kb(.shift)])
        #expect(s.keyUp(.leftShift) == [kb()])
    }

    @Test func typedTextGetsLatchedModifierOnFirstCharacterOnly() {
        var s = KeyboardState()
        let typer = TextTyper(keyMap: .us)
        _ = s.modifierDown(.command, at: 0); _ = s.modifierUp(.command, at: 0.05)
        let out = s.type("ab", with: typer)
        #expect(out.reports == [
            kb(.command), kb(.command, .a), kb(.command), kb(),
            kb([], .b), kb(),
        ])
        #expect(s.state(of: .command) == .off)
    }

    @Test func typedTextWithLockedShiftAndSkips() {
        var s = KeyboardState()
        let typer = TextTyper(keyMap: .us)
        _ = s.modifierDown(.shift, at: 0); _ = s.modifierUp(.shift, at: 0.05)
        _ = s.modifierDown(.shift, at: 0.1); _ = s.modifierUp(.shift, at: 0.15)   // locked → [shift]
        let out = s.type("aé1", with: typer)
        #expect(out.reports == [kb(.shift, .a), kb(.shift), kb(.shift, .digit1), kb(.shift)])
        #expect(out.skipped.map(\.character) == ["é"])
        #expect(s.host == kb(.shift))
    }

    @Test func releaseAllClearsEverything() {
        var s = KeyboardState()
        _ = s.modifierDown(.option, at: 0); _ = s.modifierUp(.option, at: 0.05)
        _ = s.modifierDown(.option, at: 0.1); _ = s.modifierUp(.option, at: 0.15)
        _ = s.keyDown(.pageDown)
        #expect(s.releaseAll() == [kb()])
        #expect(s.state(of: .option) == .off && s.keysDown.isEmpty)
        #expect(s.releaseAll().isEmpty)
    }
}

@Suite("ReportQueue pacing")
struct ReportPacingTests {
    private func paced() -> ReportQueue {
        ReportQueue(pacing: [.keyboard: ReportPacing(minPress: 0.035, minRelease: 0.015)])
    }

    @Test func releaseWaitsForMinPress() {
        var q = paced()
        q.enqueue([kb([], .a), kb(), kb([], .a), kb()])
        let r1 = q.next(now: 0)
        #expect(r1 == .keyboard(kb([], .a)))
        q.didSend(r1!, at: 0)
        #expect(q.next(now: 0.010) == nil)
        #expect(q.nextSendTime == 0.035)
        let r2 = q.next(now: 0.035)
        #expect(r2 == .keyboard(kb()))
        q.didSend(r2!, at: 0.035)
        #expect(q.next(now: 0.040) == nil)               // release holds minRelease
        #expect(q.nextSendTime == 0.050)
        #expect(q.next(now: 0.050) == .keyboard(kb([], .a)))
    }

    @Test func otherKindsBehindHeldHeadWaitButMotionCoalesces() {
        var q = paced()
        q.enqueue(kb([], .a))
        q.didSend(q.next(now: 0)!, at: 0)
        q.enqueue(kb())
        q.enqueueMotion(dx: 1)
        q.enqueueMotion(dx: 2)
        #expect(q.next(now: 0.01) == nil)
        #expect(q.count == 2)
        #expect(q.next(now: 0.04) == .keyboard(kb()))
        #expect(q.next(now: 0.04) == .mouse(MouseReport(x: 3)))
    }

    @Test func unpacedKindsAndUnchangedStateAreNotHeld() {
        var q = paced()
        q.setMouseButtons(.left)
        q.didSend(q.next(now: 0)!, at: 0)
        q.setMouseButtons([])
        #expect(q.next(now: 0.001) == .mouse(MouseReport()))   // mouse not paced by default
        q.enqueue(kb(.shift))
        q.didSend(q.next(now: 1)!, at: 1)
        q.enqueue(kb(.shift))                                   // same state again
        #expect(q.next(now: 1.001) == .keyboard(kb(.shift)))
    }

    @Test func pushedBackReportIsNotRecorded() {
        var q = paced()
        q.enqueue([kb([], .a), kb()])
        let r = q.next(now: 0)!
        q.pushBack(r)                                           // stack refused it
        #expect(q.next(now: 0.001) == .keyboard(kb([], .a)))
    }

    @Test func removeAllForgetsHistory() {
        var q = paced()
        q.enqueue(kb([], .a))
        q.didSend(q.next(now: 0)!, at: 0)
        q.removeAll()
        q.enqueue(kb())
        #expect(q.next(now: 0.001) == .keyboard(kb()))
    }

    /// Mouse pacing (app: `[.mouse: .keys]`) holds button transitions only. Motion is
    /// never held by itself: motion before the press and during a drag goes out at once and
    /// carries the button state it was queued with; motion queued after a held release waits
    /// behind it (≤ minPress) so it is never sent with the button still down.
    @Test func mousePacingHoldsOnlyButtonTransitions() {
        var q = ReportQueue(pacing: [.mouse: .keys])
        func send(_ now: Double) -> OutgoingReport? {
            guard let r = q.next(now: now) else { return nil }
            q.didSend(r, at: now)
            return r
        }
        q.enqueueMotion(dx: 4)
        #expect(send(0) == .mouse(MouseReport(x: 4)))
        q.enqueueMotion(dx: 1)
        #expect(send(0.001) == .mouse(MouseReport(x: 1)))                 // motion: never held
        q.setMouseButtons(.left)
        #expect(send(0.002) == .mouse(MouseReport(buttons: .left)))       // press (no earlier change)
        q.enqueueMotion(dx: 3)
        #expect(send(0.003) == .mouse(MouseReport(buttons: .left, x: 3))) // drag motion: not held, carries the button
        q.enqueueMotion(dy: 2)
        #expect(send(0.004) == .mouse(MouseReport(buttons: .left, y: 2)))
        q.setMouseButtons([])
        q.enqueueMotion(dx: 5)
        #expect(send(0.010) == nil)                                        // release held until ≈0.037
        #expect(q.nextSendTime == 0.002 + ReportPacing.keys.minPress)
        #expect(send(0.038) == .mouse(MouseReport()))                      // release first …
        #expect(send(0.038) == .mouse(MouseReport(x: 5)))                  // … then the motion, without the button
        q.setMouseButtons(.left)                                           // next click: held minRelease
        #expect(send(0.040) == nil)
        #expect(send(0.054) == .mouse(MouseReport(buttons: .left)))
    }

    @Test func consumerPressAndRelease() {
        var q = ReportQueue(pacing: [.consumer: .keys])
        q.enqueue(ConsumerReport(.playPause))
        q.enqueue(ConsumerReport.released)
        q.didSend(q.next(now: 0)!, at: 0)
        #expect(q.next(now: 0.02) == nil)
        #expect(q.next(now: 0.035) == .consumer(.released))
    }
}

@Suite("TextTyper holding")
struct TextTyperHoldingTests {
    @Test func baseModifiersAreKeptAndRestored() {
        let t = TextTyper(keyMap: .us)
        #expect(t.reports(for: "aA", holding: .command, from: []).reports == [
            kb(.command), kb(.command, .a), kb(.command),
            kb([.command, .shift]), kb([.command, .shift], .a), kb([.command, .shift]),
            kb(.command),
        ])
        #expect(t.reports(for: "b", holding: [], from: .option).reports == [kb(), kb([], .b), kb()])
        #expect(t.reports(for: "é", holding: .shift, from: []).reports.isEmpty)
    }
}
