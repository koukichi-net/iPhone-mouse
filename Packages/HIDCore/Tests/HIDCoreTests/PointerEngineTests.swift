import Testing
@testable import HIDCore

private func down(_ id: Int, _ x: Double, _ y: Double, _ t: Double) -> TouchEvent {
    TouchEvent(id: id, phase: .began, location: Vector2(x, y), timestamp: t)
}
private func move(_ id: Int, _ x: Double, _ y: Double, _ t: Double) -> TouchEvent {
    TouchEvent(id: id, phase: .moved, location: Vector2(x, y), timestamp: t)
}
private func up(_ id: Int, _ x: Double, _ y: Double, _ t: Double) -> TouchEvent {
    TouchEvent(id: id, phase: .ended, location: Vector2(x, y), timestamp: t)
}
private func cancel(_ id: Int, _ x: Double, _ y: Double, _ t: Double) -> TouchEvent {
    TouchEvent(id: id, phase: .cancelled, location: Vector2(x, y), timestamp: t)
}

/// Linear settings: 1 px per point, no pointer or scroll acceleration, no inertia, no
/// two-finger grace hold (the tests of those features set them explicitly).
private func linear(_ configure: (inout PointerSettings) -> Void = { _ in }) -> PointerEngine {
    var s = PointerSettings()
    s.sensitivity = 1
    s.acceleration = 0
    s.scrollAcceleration = 0
    s.scrollInertia = false
    s.twoFingerGrace = 0
    configure(&s)
    return PointerEngine(settings: s)
}

private let leftClick: [PointerAction] = [.buttons(.left), .buttons([])]
private let rightClick: [PointerAction] = [.buttons(.right), .buttons([])]

@Suite("PointerEngine")
struct PointerEngineTests {
    // MARK: Move

    @Test func oneFingerMoveStartsPastSlopWithoutLosingMotion() {
        var e = linear()
        #expect(e.handle(down(1, 0, 0, 0)) == [])
        #expect(e.handle(move(1, 5, 0, 0.01)) == [])               // inside the 10 pt slop
        #expect(e.handle(move(1, 20, 0, 0.02)) == [.move(dx: 20, dy: 0)])   // catches up from touch-down
        #expect(e.handle(move(1, 23, 4, 0.03)) == [.move(dx: 3, dy: 4)])
        #expect(e.handle(move(1, 23, -6, 0.04)) == [.move(dx: 0, dy: -10)])
        #expect(e.handle(up(1, 23, -6, 0.05)) == [])               // moved: no click
    }

    @Test func smallNudgesWorkOnceTheTouchIsTooOldToBeATap() {
        var e = linear()
        _ = e.handle(down(1, 0, 0, 0))
        #expect(e.handle(move(1, 1, 0, 0.1)) == [])                // young: still a possible tap
        #expect(e.handle(move(1, 3, 1, 0.3)) == [.move(dx: 3, dy: 1)])  // > tapMaxDuration: moves
        #expect(e.handle(move(1, 4, 1, 0.35)) == [.move(dx: 1, dy: 0)])
        #expect(e.handle(up(1, 4, 1, 0.4)) == [])
    }

    @Test func subPixelRemainderCarriesAcrossEvents() {
        var e = linear { $0.sensitivity = 0.5 }
        _ = e.handle(down(1, 0, 0, 0))
        #expect(e.handle(move(1, 11, 0, 0.01)) == [.move(dx: 5, dy: 0)])   // 5.5 → 5, carry 0.5
        #expect(e.handle(move(1, 12, 0, 0.02)) == [.move(dx: 1, dy: 0)])   // 0.5 + 0.5
        #expect(e.handle(move(1, 13, 0, 0.03)) == [])                      // 0.5 carried
        #expect(e.handle(move(1, 14, 0, 0.04)) == [.move(dx: 1, dy: 0)])
        // Negative direction rounds toward zero and carries negative remainders.
        #expect(e.handle(move(1, 13, 0, 0.05)) == [])                      // -0.5
        #expect(e.handle(move(1, 12, 0, 0.06)) == [.move(dx: -1, dy: 0)])
    }

    @Test func totalMotionIsPreservedOverManySmallSteps() {
        var e = linear { $0.sensitivity = 0.25 }
        _ = e.handle(down(1, 0, 0, 0))
        var total = 0
        for i in 1...200 {
            for a in e.handle(move(1, Double(i), 0, Double(i) * 0.01)) {
                if case .move(let dx, _) = a { total += dx }
            }
        }
        #expect(total == 50)   // 200 pt × 0.25
    }

    @Test func accelerationDependsOnSpeed() {
        func dx(for distance: Double, over dt: Double) -> Int {
            var e = PointerEngine(settings: {
                var s = PointerSettings()
                s.sensitivity = 1; s.acceleration = 1; s.accelerationLowSpeed = 100; s.accelerationHighSpeed = 1200
                return s
            }())
            _ = e.handle(down(1, 0, 0, 0))
            _ = e.handle(move(1, 20, 0, 1))          // past slop, slow
            let out = e.handle(move(1, 20 + distance, 0, 1 + dt))
            guard case .move(let x, _)? = out.first else { return 0 }
            return x
        }
        // Exact binary time steps keep the arithmetic exact.
        #expect(dx(for: 10, over: 1) == 10)            // 10 pt/s: gain 1
        #expect(dx(for: 75, over: 0.0625) == 150)      // 1200 pt/s: gain 2
        #expect(dx(for: 250, over: 0.0625) == 500)     // 4000 pt/s: capped at gain 2
        #expect(dx(for: 40.625, over: 0.0625) == 60)   // 650 pt/s: gain 1.5 → 60.9375
    }

    @Test func sameTimestampAndNonFiniteInputDoNotTrap() {
        var e = PointerEngine()
        _ = e.handle(down(1, 0, 0, 5))
        let a = e.handle(move(1, 30, 0, 5))          // dt = 0
        #expect(a.count == 1)
        #expect(e.handle(move(1, .nan, 0, 5.01)) == [])
        #expect(e.handle(move(1, 40, .infinity, 5.02)) == [])
        #expect(e.handle(move(1, 40, 0, .nan)) == [])
        let b = e.handle(move(1, 1e300, 0, 5.03))    // absurd jump: clamped, no trap
        #expect(b.count == 1)
    }

    // MARK: Tap

    @Test func tapClicksImmediatelyOnLift() {
        var e = linear()
        #expect(e.handle(down(1, 50, 50, 0)) == [])
        #expect(e.handle(move(1, 53, 52, 0.05)) == [])
        #expect(e.handle(up(1, 53, 52, 0.1)) == leftClick)
        #expect(e.buttons == [])
    }

    @Test func longPressOrMovedTouchDoesNotClick() {
        var e = linear()
        _ = e.handle(down(1, 0, 0, 0))
        #expect(e.handle(up(1, 0, 0, 0.4)) == [])
        _ = e.handle(down(1, 0, 0, 1))
        _ = e.handle(move(1, 30, 0, 1.05))
        _ = e.handle(move(1, 0, 0, 1.1))            // came back, but it left the slop
        #expect(e.handle(up(1, 0, 0, 1.15)) == [])
    }

    @Test func twoFingerTapIsRightClickOnLastLift() {
        var e = linear()
        #expect(e.handle(down(1, 100, 100, 0)) == [])
        #expect(e.handle(down(2, 150, 100, 0.03)) == [])
        #expect(e.handle(move(2, 152, 101, 0.05)) == [])
        #expect(e.handle(up(1, 100, 100, 0.1)) == [])
        #expect(e.handle(move(2, 153, 101, 0.11)) == [])   // remaining finger: no pointer motion
        #expect(e.handle(up(2, 153, 101, 0.12)) == rightClick)
    }

    @Test func twoFingerTapFailsWhenSlowOrMoved() {
        var e = linear()
        _ = e.handle(down(1, 100, 100, 0))
        _ = e.handle(down(2, 150, 100, 0.03))
        _ = e.handle(up(1, 100, 100, 0.2))
        #expect(e.handle(up(2, 150, 100, 0.3)) == [])        // took too long

        // Pinch: centroid stays, but each finger leaves the slop.
        _ = e.handle(down(1, 100, 100, 1))
        _ = e.handle(down(2, 150, 100, 1.01))
        #expect(e.handle([move(1, 80, 100, 1.05), move(2, 170, 100, 1.05)]) == [])
        _ = e.handle(up(1, 80, 100, 1.08))
        #expect(e.handle(up(2, 170, 100, 1.1)) == [])

        // Remaining finger moves after the first lift.
        _ = e.handle(down(1, 100, 100, 2))
        _ = e.handle(down(2, 150, 100, 2.01))
        _ = e.handle(up(1, 100, 100, 2.05))
        #expect(e.handle(move(2, 180, 100, 2.07)) == [])
        #expect(e.handle(up(2, 180, 100, 2.1)) == [])
    }

    @Test func tapToClickOffNeverClicksOrDrags() {
        var e = linear { $0.tapToClick = false }
        _ = e.handle(down(1, 50, 50, 0))
        #expect(e.handle(up(1, 50, 50, 0.08)) == [])                 // tap: nothing
        _ = e.handle(down(1, 50, 50, 0.2))                           // inside the old double-tap window
        #expect(e.handle(move(1, 70, 50, 0.25)) == [.move(dx: 20, dy: 0)])   // a plain move, no drag
        #expect(e.handle(up(1, 70, 50, 0.3)) == [])
        _ = e.handle(down(1, 100, 100, 1))
        _ = e.handle(down(2, 150, 100, 1.03))
        _ = e.handle(up(1, 100, 100, 1.1))
        #expect(e.handle(up(2, 150, 100, 1.12)) == [])               // two-finger tap: nothing
        #expect(e.setButton(.left, pressed: true) == [.buttons(.left)])   // on-screen buttons still work
        #expect(e.setButton(.left, pressed: false) == [.buttons([])])
    }

    // MARK: Double tap / drag

    @Test func doubleTapAndMoveDrags() {
        var e = linear()
        _ = e.handle(down(1, 50, 50, 0))
        #expect(e.handle(up(1, 50, 50, 0.08)) == leftClick)
        #expect(e.handle(down(2, 60, 60, 0.25)) == [])              // 0.17 s after the lift
        #expect(e.handle(move(2, 64, 60, 0.3)) == [])               // inside the slop: not yet
        #expect(e.handle(move(2, 75, 60, 0.35)) == [.buttons(.left), .move(dx: 15, dy: 0)])  // press first
        #expect(e.buttons == .left)
        #expect(e.handle(move(2, 75, 90, 0.4)) == [.move(dx: 0, dy: 30)])
        #expect(e.handle(up(2, 75, 90, 0.45)) == [.buttons([])])
        #expect(e.buttons == [])
    }

    @Test func doubleTapHeldStillThenMovedStillDrags() {
        var e = linear()
        _ = e.handle(down(1, 0, 0, 0))
        _ = e.handle(up(1, 0, 0, 0.1))
        _ = e.handle(down(1, 0, 0, 0.3))
        #expect(e.handle(move(1, 30, 0, 1.5)) == [.buttons(.left), .move(dx: 30, dy: 0)])
        #expect(e.handle(up(1, 30, 0, 1.6)) == [.buttons([])])
    }

    @Test func doubleTapWithoutMoveIsTwoClicks() {
        var e = linear()
        _ = e.handle(down(1, 0, 0, 0))
        #expect(e.handle(up(1, 0, 0, 0.08)) == leftClick)
        _ = e.handle(down(1, 2, 2, 0.2))
        #expect(e.handle(up(1, 2, 2, 0.28)) == leftClick)
        // A third quick touch-and-move drags too (window restarts at each tap).
        _ = e.handle(down(1, 2, 2, 0.4))
        #expect(e.handle(move(1, 30, 2, 0.45)).first == .buttons(.left))
    }

    @Test func touchAfterWindowJustMoves() {
        var e = linear()
        _ = e.handle(down(1, 0, 0, 0))
        _ = e.handle(up(1, 0, 0, 0.1))
        _ = e.handle(down(1, 0, 0, 0.41))                 // 0.31 s > 0.3 s window
        #expect(e.handle(move(1, 20, 0, 0.45)) == [.move(dx: 20, dy: 0)])
        #expect(e.handle(up(1, 20, 0, 0.5)) == [])
    }

    @Test func twoFingersAfterTapAreNotADrag() {
        var e = linear()
        _ = e.handle(down(1, 0, 0, 0))
        _ = e.handle(up(1, 0, 0, 0.1))
        _ = e.handle(down(1, 0, 0, 0.2))
        _ = e.handle(down(2, 50, 0, 0.21))
        let out = e.handle([move(1, 0, -40, 0.3), move(2, 50, -40, 0.3)])
        #expect(!out.contains(.buttons(.left)))
        #expect(out.allSatisfy { if case .scroll = $0 { true } else { false } })
    }

    // MARK: Scroll

    @Test func twoFingerPanScrollsWithRemainderCarry() {
        var e = linear()
        _ = e.handle(down(1, 100, 100, 0))
        _ = e.handle(down(2, 140, 100, 0.01))
        // Finger 1 up 30: centroid up 15 (> slop) → 1.5 units → wheel 1, carry 0.5.
        #expect(e.handle(move(1, 100, 70, 0.05)) == [.scroll(wheel: 1, pan: 0)])
        // Finger 2 up 30: centroid up another 15 → 1.5 + 0.5 = 2.
        #expect(e.handle(move(2, 140, 70, 0.05)) == [.scroll(wheel: 2, pan: 0)])
        // Both right 20 in one batch → pan +2.
        #expect(e.handle([move(1, 120, 70, 0.1), move(2, 160, 70, 0.1)]) == [.scroll(wheel: 0, pan: 1), .scroll(wheel: 0, pan: 1)])
        // Down 40 → wheel -4.
        let down40 = e.handle([move(1, 120, 110, 0.15), move(2, 160, 110, 0.15)])
        #expect(down40 == [.scroll(wheel: -2, pan: 0), .scroll(wheel: -2, pan: 0)])
        _ = e.handle(up(1, 120, 110, 0.2))
        #expect(e.handle(move(2, 160, 300, 0.22)) == [])  // one finger left: nothing
        #expect(e.handle(up(2, 160, 300, 0.25)) == [])    // no right click after a scroll
    }

    @Test func invertScrollFlipsBothAxes() {
        var e = linear { $0.invertScroll = true }
        _ = e.handle(down(1, 100, 100, 0))
        _ = e.handle(down(2, 140, 100, 0))
        #expect(e.handle([move(1, 120, 80, 0.05), move(2, 160, 80, 0.05)]) == [.scroll(wheel: -1, pan: -1), .scroll(wheel: -1, pan: -1)])
    }

    @Test func secondFingerLandingDoesNotJump() {
        var e = linear()
        _ = e.handle(down(1, 0, 0, 0))
        #expect(e.handle(move(1, 30, 0, 0.05)) == [.move(dx: 30, dy: 0)])
        #expect(e.handle(down(2, 300, 300, 0.1)) == [])   // far away: no move, no scroll
        // From now on it is a scroll gesture; finger 1 moving does not move the pointer.
        // First event moves the centroid exactly 10 pt (not past the slop); the second
        // crosses it and sends the whole 20 pt.
        let out = e.handle([move(1, 30, -20, 0.15), move(2, 300, 280, 0.15)])
        #expect(out == [.scroll(wheel: 2, pan: 0)])
        _ = e.handle(up(2, 300, 280, 0.2))
        #expect(e.handle(move(1, 80, -20, 0.25)) == [])
        #expect(e.handle(up(1, 80, -20, 0.3)) == [])
    }

    // MARK: Cancel and extra fingers

    @Test func cancelDuringDragReleasesWithoutClick() {
        var e = linear()
        _ = e.handle(down(1, 0, 0, 0))
        _ = e.handle(up(1, 0, 0, 0.1))
        _ = e.handle(down(1, 0, 0, 0.2))
        #expect(e.handle(move(1, 20, 0, 0.25)).first == .buttons(.left))
        #expect(e.handle(cancel(1, 20, 0, 0.3)) == [.buttons([])])
        // The cancelled touch does not arm a drag for the next touch.
        _ = e.handle(down(1, 0, 0, 0.35))
        #expect(e.handle(move(1, 20, 0, 0.4)) == [.move(dx: 20, dy: 0)])
    }

    @Test func cancelledTapNeverClicks() {
        var e = linear()
        _ = e.handle(down(1, 0, 0, 0))
        #expect(e.handle(cancel(1, 0, 0, 0.05)) == [])
        _ = e.handle(down(1, 0, 0, 1))
        _ = e.handle(down(2, 40, 0, 1.01))
        #expect(e.handle(cancel(1, 0, 0, 1.05)) == [])
        #expect(e.handle(cancel(2, 40, 0, 1.05)) == [])
    }

    @Test func threeFingersSuppressEverything() {
        var e = linear()
        _ = e.handle([down(1, 0, 0, 0), down(2, 40, 0, 0), down(3, 80, 0, 0)])
        #expect(e.handle([move(1, 0, 50, 0.05), move(2, 40, 50, 0.05), move(3, 80, 50, 0.05)]) == [])
        #expect(e.handle([up(1, 0, 50, 0.1), up(2, 40, 50, 0.1), up(3, 80, 50, 0.1)]) == [])
        // Back to normal afterwards.
        _ = e.handle(down(1, 0, 0, 1))
        #expect(e.handle(up(1, 0, 0, 1.05)) == leftClick)
    }

    @Test func extraFingerDuringDragIsIgnored() {
        var e = linear()
        _ = e.handle(down(1, 0, 0, 0))
        _ = e.handle(up(1, 0, 0, 0.1))
        _ = e.handle(down(1, 0, 0, 0.2))
        _ = e.handle(move(1, 20, 0, 0.25))
        #expect(e.handle(down(2, 100, 100, 0.3)) == [])
        #expect(e.handle(move(2, 150, 100, 0.35)) == [])
        #expect(e.handle(move(1, 30, 0, 0.35)) == [.move(dx: 10, dy: 0)])
        #expect(e.handle(up(2, 150, 100, 0.4)) == [])
        #expect(e.buttons == .left)
        #expect(e.handle(up(1, 30, 0, 0.45)) == [.buttons([])])
    }

    @Test func dragReleasedWhenPrimaryLiftsFirst() {
        var e = linear()
        _ = e.handle(down(1, 0, 0, 0))
        _ = e.handle(up(1, 0, 0, 0.1))
        _ = e.handle(down(1, 0, 0, 0.2))
        _ = e.handle(move(1, 20, 0, 0.25))
        _ = e.handle(down(2, 100, 100, 0.3))
        #expect(e.handle(up(1, 20, 0, 0.35)) == [.buttons([])])
        #expect(e.handle(move(2, 200, 100, 0.4)) == [])
        #expect(e.handle(up(2, 200, 100, 0.45)) == [])
    }

    // MARK: On-screen buttons

    @Test func onScreenButtons() {
        var e = linear()
        #expect(e.setButton(.left, pressed: true) == [.buttons(.left)])
        #expect(e.setButton(.left, pressed: true) == [])
        // Move while holding the on-screen button = drag.
        _ = e.handle(down(1, 0, 0, 0))
        #expect(e.handle(move(1, 20, 0, 0.05)) == [.move(dx: 20, dy: 0)])
        _ = e.handle(up(1, 20, 0, 0.1))
        // A tap while left is held does not click again.
        _ = e.handle(down(1, 0, 0, 1))
        #expect(e.handle(up(1, 0, 0, 1.05)) == [])
        #expect(e.setButton(.right, pressed: true) == [.buttons([.left, .right])])
        #expect(e.setButton(.left, pressed: false) == [.buttons(.right)])
        #expect(e.setButton(.right, pressed: false) == [.buttons([])])
    }

    @Test func gestureAndOnScreenHoldsCombine() {
        var e = linear()
        _ = e.handle(down(1, 0, 0, 0))
        _ = e.handle(up(1, 0, 0, 0.1))
        _ = e.handle(down(1, 0, 0, 0.2))
        #expect(e.handle(move(1, 20, 0, 0.25)).first == .buttons(.left))
        #expect(e.setButton(.left, pressed: true) == [])            // already down
        #expect(e.handle(up(1, 20, 0, 0.3)) == [])                   // still held on screen
        #expect(e.setButton(.left, pressed: false) == [.buttons([])])
    }

    @Test func tapWhileRightHeldKeepsRight() {
        var e = linear()
        _ = e.setButton(.right, pressed: true)
        _ = e.handle(down(1, 0, 0, 0))
        #expect(e.handle(up(1, 0, 0, 0.05)) == [.buttons([.left, .right]), .buttons(.right)])
    }

    @Test func resetReleasesEverything() {
        var e = linear()
        _ = e.setButton(.right, pressed: true)
        _ = e.handle(down(1, 0, 0, 0))
        _ = e.handle(up(1, 0, 0, 0.1))
        _ = e.handle(down(1, 0, 0, 0.2))
        _ = e.handle(move(1, 20, 0, 0.25))
        #expect(e.buttons == [.left, .right])
        #expect(e.reset() == [.buttons([])])
        #expect(e.activeTouchCount == 0)
        #expect(e.handle(move(1, 50, 0, 0.3)) == [])                // unknown touch now
    }
}
