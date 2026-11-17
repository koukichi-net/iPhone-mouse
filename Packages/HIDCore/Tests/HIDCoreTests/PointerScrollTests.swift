import Testing
import Foundation
@testable import HIDCore

// Scroll strip, scroll acceleration, inertia and two-finger robustness (design §8.1,
// 利用者の指摘 2026-11-17). Scripted touch sequences with explicit timestamps.

private func down(_ id: Int, _ x: Double, _ y: Double, _ t: Double, strip: Bool = false) -> TouchEvent {
    TouchEvent(id: id, phase: .began, location: Vector2(x, y), timestamp: t, zone: strip ? .scrollStrip : .surface)
}
private func move(_ id: Int, _ x: Double, _ y: Double, _ t: Double) -> TouchEvent {
    TouchEvent(id: id, phase: .moved, location: Vector2(x, y), timestamp: t)
}
private func up(_ id: Int, _ x: Double, _ y: Double, _ t: Double) -> TouchEvent {
    TouchEvent(id: id, phase: .ended, location: Vector2(x, y), timestamp: t)
}

private func engine(_ configure: (inout PointerSettings) -> Void = { _ in }) -> PointerEngine {
    var s = PointerSettings()
    s.sensitivity = 1
    s.acceleration = 0
    configure(&s)
    return PointerEngine(settings: s)
}

private struct Totals: Equatable {
    var moves = 0, dx = 0, dy = 0, wheel = 0, pan = 0, scrolls = 0, buttons = 0
    init(_ actions: [PointerAction] = []) { add(actions) }
    mutating func add(_ actions: [PointerAction]) {
        for a in actions {
            switch a {
            case .move(let x, let y): moves += 1; dx += x; dy += y
            case .scroll(let w, let p): scrolls += 1; wheel += w; pan += p
            case .buttons: buttons += 1
            }
        }
    }
}

/// Runs inertia to the end with ticks every `dt` seconds from `t0`.
private func runInertia(_ e: inout PointerEngine, from t0: Double, dt: Double, limit: Double = 10) -> [PointerAction] {
    var out: [PointerAction] = []
    var t = t0
    while e.isInertiaActive, t < t0 + limit {
        t += dt
        out += e.advance(to: t)
    }
    return out
}

/// One-finger strip flick: up `steps` × `step` pt at 120 Hz from y = 500, lifted right after.
private func stripFlick(_ e: inout PointerEngine, id: Int = 1, step: Double, steps: Int, t0: Double = 0) -> (actions: [PointerAction], liftTime: Double) {
    var out = e.handle(down(id, 300, 500, t0, strip: true))
    var y = 500.0, t = t0
    for _ in 0..<steps {
        t += 1.0 / 120
        y += step
        out += e.handle(move(id, 300, y, t))
    }
    out += e.handle(up(id, 300, y, t))
    return (out, t)
}

@Suite("Scroll strip, acceleration, inertia")
struct PointerScrollTests {
    // MARK: Strip geometry

    @Test func stripZones() {
        let right = ScrollStripLayout(edge: .right, width: 40)
        #expect(right.zone(at: Vector2(359, 100), surfaceWidth: 360) == .scrollStrip)
        #expect(right.zone(at: Vector2(320, 100), surfaceWidth: 360) == .scrollStrip)
        #expect(right.zone(at: Vector2(319.9, 100), surfaceWidth: 360) == .surface)
        #expect(right.zone(at: Vector2(362, 100), surfaceWidth: 360) == .scrollStrip)   // border overshoot
        let left = ScrollStripLayout(edge: .left, width: 40)
        #expect(left.zone(at: Vector2(-1, 100), surfaceWidth: 360) == .scrollStrip)
        #expect(left.zone(at: Vector2(40, 100), surfaceWidth: 360) == .scrollStrip)
        #expect(left.zone(at: Vector2(41, 100), surfaceWidth: 360) == .surface)
        let off = ScrollStripLayout(edge: .off, width: 40)
        #expect(off.zone(at: Vector2(359, 100), surfaceWidth: 360) == .surface)
        #expect(off.xRange(surfaceWidth: 360) == nil)
        // Never more than half the surface.
        #expect(ScrollStripLayout(edge: .right, width: 500).xRange(surfaceWidth: 100) == 50...100)
        #expect(right.zone(at: Vector2(359, 100), surfaceWidth: 0) == .surface)
    }

    // MARK: Strip gesture

    @Test func stripScrollsVerticallyAndNeverMovesOrClicks() {
        var e = engine { $0.scrollAcceleration = 0; $0.scrollInertia = false }
        #expect(e.handle(down(1, 340, 400, 0, strip: true)) == [])
        #expect(e.handle(move(1, 340, 397, 0.02)) == [])                  // inside the 4 pt strip slop
        // Past the slop: the whole 12.5 pt from touch-down is sent (1.25 units → 1, carry 0.25).
        #expect(e.handle(move(1, 340, 387.5, 0.04)) == [.scroll(wheel: 1, pan: 0)])
        // Leaving the strip sideways keeps scrolling, and horizontal motion is ignored.
        #expect(e.handle(move(1, 200, 380, 0.06)) == [.scroll(wheel: 1, pan: 0)])   // 0.75 + 0.25
        #expect(e.handle(move(1, 100, 420, 0.08)) == [.scroll(wheel: -4, pan: 0)])
        #expect(e.handle(up(1, 100, 420, 0.1)) == [])
        #expect(e.buttons == [])
    }

    @Test func stripTapRestAndDoubleTapDoNothing() {
        var e = engine()
        _ = e.handle(down(1, 340, 400, 0, strip: true))
        #expect(e.handle(up(1, 340, 400, 0.05)) == [])                    // tap: no click
        _ = e.handle(down(1, 340, 400, 0.15, strip: true))                // within the double-tap window
        #expect(e.handle(move(1, 341, 402, 0.5)) == [])                   // resting thumb: nothing
        #expect(e.handle(up(1, 341, 402, 0.6)) == [])
        // A surface tap followed by a strip touch is not a drag.
        _ = e.handle(down(1, 100, 100, 1))
        #expect(e.handle(up(1, 100, 100, 1.05)) == [.buttons(.left), .buttons([])])
        _ = e.handle(down(1, 340, 400, 1.15, strip: true))
        let out = e.handle(move(1, 360, 300, 1.3))
        #expect(!out.contains { if case .buttons = $0 { true } else { false } })
        #expect(!out.contains { if case .move = $0 { true } else { false } })
    }

    @Test func extraFingerDuringStripScrollIsIgnored() {
        var e = engine { $0.scrollAcceleration = 0; $0.scrollInertia = false }
        _ = e.handle(down(1, 340, 400, 0, strip: true))
        _ = e.handle(move(1, 340, 380, 0.05))
        #expect(e.handle(down(2, 100, 400, 0.3)) == [])                   // late: ignored
        #expect(e.handle(move(2, 150, 300, 0.35)) == [])
        #expect(e.handle(move(1, 340, 370, 0.35)) == [.scroll(wheel: 1, pan: 0)])
        #expect(e.handle(up(2, 150, 300, 0.4)) == [])
        #expect(e.handle(up(1, 340, 370, 0.45)) == [])
    }

    @Test func secondFingerEarlyInStripMakesTwoFingerScroll() {
        var e = engine { $0.scrollAcceleration = 0; $0.scrollInertia = false }
        _ = e.handle(down(1, 340, 400, 0, strip: true))
        #expect(e.handle(down(2, 280, 400, 0.05)) == [])                  // within the grace
        // Both move right 30: horizontal scroll (the strip alone would ignore x).
        let out = e.handle([move(1, 370, 400, 0.1), move(2, 310, 400, 0.1)])
        #expect(Totals(out).pan == 3)
        #expect(Totals(out).moves == 0)
    }

    // MARK: Two-finger robustness

    @Test func staggeredSecondFingerLeaksNoPointerMotion() {
        var e = engine { $0.scrollAcceleration = 0; $0.scrollInertia = false }   // default grace 0.1 s / 20 pt
        var all: [PointerAction] = []
        all += e.handle(down(1, 100, 300, 0))
        all += e.handle(move(1, 100, 288, 0.03))      // 12 pt: past the tap slop, inside the grace
        all += e.handle(move(1, 100, 284, 0.05))
        #expect(all == [])
        all += e.handle(down(2, 160, 300, 0.08))      // 80 ms later
        // From here it is a scroll: centroid up 20 pt.
        let s = e.handle([move(1, 100, 264, 0.12), move(2, 160, 280, 0.12)])
        all += s
        all += e.handle(up(1, 100, 264, 0.2))
        all += e.handle(up(2, 160, 280, 0.21))
        let t = Totals(all)
        #expect(t.moves == 0)
        #expect(t.buttons == 0)
        #expect(t.wheel > 0)
    }

    @Test func graceHoldsMotionThenCatchesUpWithoutLoss() {
        var e = engine()
        _ = e.handle(down(1, 0, 0, 0))
        #expect(e.handle(move(1, 15, 0, 0.04)) == [])                     // held (grace)
        #expect(e.handle(move(1, 18, 0, 0.11)) == [.move(dx: 18, dy: 0)]) // grace over: all of it
        #expect(e.handle(move(1, 20, 0, 0.12)) == [.move(dx: 2, dy: 0)])
    }

    @Test func fastStartIsNotDelayed() {
        var e = engine()
        _ = e.handle(down(1, 0, 0, 0))
        #expect(e.handle(move(1, 25, 0, 0.03)) == [.move(dx: 25, dy: 0)]) // > 20 pt: meaningful travel
    }

    @Test func secondFingerAfterRealPointerMotionStillScrollsWithoutJump() {
        var e = engine { $0.scrollAcceleration = 0; $0.scrollInertia = false }
        _ = e.handle(down(1, 0, 0, 0))
        #expect(e.handle(move(1, 40, 0, 0.15)) == [.move(dx: 40, dy: 0)])
        #expect(e.handle(down(2, 300, 300, 0.3)) == [])
        let out = e.handle([move(1, 40, -20, 0.35), move(2, 300, 280, 0.35)])
        #expect(out == [.scroll(wheel: 2, pan: 0)])
    }

    @Test func liftingOneFingerOfAScrollNeitherJumpsNorClicksAndRelandingResumes() {
        var e = engine { $0.scrollAcceleration = 0; $0.scrollInertia = false }
        _ = e.handle(down(1, 100, 300, 0))
        _ = e.handle(down(2, 160, 300, 0.01))
        #expect(Totals(e.handle([move(1, 100, 260, 0.1), move(2, 160, 260, 0.1)])).wheel == 4)
        // Lift finger 2: the centroid jumps by 30 pt, but nothing is sent.
        #expect(e.handle(up(2, 160, 260, 0.15)) == [])
        #expect(e.handle(move(1, 100, 200, 0.2)) == [])                   // remaining finger: nothing
        // Finger 2 lands again far away: no jump; scrolling resumes from the new centroid.
        #expect(e.handle(down(2, 300, 500, 0.3)) == [])
        #expect(e.handle([move(1, 100, 190, 0.35), move(2, 300, 490, 0.35)]) == [.scroll(wheel: 1, pan: 0)])
        #expect(e.handle(up(1, 100, 190, 0.4)) == [])
        #expect(e.handle(up(2, 300, 490, 0.45)) == [])
        #expect(e.buttons == [])
    }

    @Test func staggeredTwoFingerTapIsStillARightClick() {
        var e = engine()   // defaults: grace on
        _ = e.handle(down(1, 100, 100, 0))
        _ = e.handle(move(1, 103, 101, 0.04))
        _ = e.handle(down(2, 150, 100, 0.09))
        _ = e.handle(up(1, 103, 101, 0.15))
        #expect(e.handle(up(2, 150, 100, 0.18)) == [.buttons(.right), .buttons([])])
    }

    // MARK: Acceleration

    @Test func slowScrollGivesEvenlySpacedSingleNotches() {
        // Acceleration on, but 64 pt/s is below the ramp. 8 pt per unit keeps the arithmetic exact.
        var e = engine { $0.scrollInertia = false; $0.scrollPointsPerUnit = 8 }
        _ = e.handle(down(1, 340, 500, 0, strip: true))
        var notchSteps: [Int] = []
        var y = 500.0
        for i in 1...120 {
            y -= 1   // 1 pt per event at 64 Hz
            let out = e.handle(move(1, 340, y, Double(i) / 64))   // binary time steps
            for a in out {
                guard case .scroll(let w, _) = a else { Issue.record("unexpected \(a)"); continue }
                #expect(w == 1)
                notchSteps.append(i)
            }
        }
        // Notches at 8, 16, … 120 pt: exactly every 8 events.
        #expect(notchSteps == Array(stride(from: 8, through: 120, by: 8)))
    }

    @Test func fastScrollGetsLargerGain() {
        func wheel(stepPoints: Double) -> Int {
            var e = engine { $0.scrollInertia = false; $0.scrollPointsPerUnit = 8 }
            _ = e.handle(down(1, 340, 1000, 0, strip: true))
            var y = 1000.0, total = 0
            for i in 1...12 {
                y -= stepPoints
                total += Totals(e.handle(move(1, 340, y, Double(i) / 120))).wheel
            }
            return total
        }
        // Same distance (120 pt): slowly vs. as a flick.
        var slow = engine { $0.scrollInertia = false; $0.scrollPointsPerUnit = 8 }
        _ = slow.handle(down(1, 340, 1000, 0, strip: true))
        var slowTotal = 0
        for i in 1...120 { slowTotal += Totals(slow.handle(move(1, 340, 1000 - Double(i), Double(i) / 64))).wheel }
        #expect(slowTotal == 15)
        let fast = wheel(stepPoints: 10)            // 1200 pt/s
        #expect(fast > 30)                          // gain ≈ 2.5
        #expect(fast <= 45)                         // never more than 1 + scrollAcceleration
        #expect(wheel(stepPoints: 10) == fast)      // deterministic
    }

    @Test func scrollSpeedSettingIsTheBaseGain() {
        var e = engine { $0.scrollInertia = false; $0.scrollPointsPerUnit = 4 }
        _ = e.handle(down(1, 340, 500, 0, strip: true))
        var total = 0
        for i in 1...50 { total += Totals(e.handle(move(1, 340, 500 - Double(i), Double(i) / 64))).wheel }
        #expect(total == 12)   // 50 pt / 4
    }

    // MARK: Inertia

    @Test func inertiaContinuesDecaysAndIsDeterministic() {
        var a = engine()
        let flick = stripFlick(&a, step: -10, steps: 6)
        let gesture = Totals(flick.actions)
        #expect(gesture.wheel > 0)
        #expect(a.isInertiaActive)
        var b = a, c = a
        let at60 = runInertia(&a, from: flick.liftTime, dt: 1.0 / 60)
        let at120 = runInertia(&b, from: flick.liftTime, dt: 1.0 / 120)
        let once = c.advance(to: flick.liftTime + 5)
        #expect(!a.isInertiaActive && !b.isInertiaActive && !c.isInertiaActive)
        let total = Totals(at60).wheel
        #expect(total > 0)
        #expect(Totals(at120).wheel == total)
        #expect(Totals(once).wheel == total)
        #expect(Totals(at60).pan == 0 && Totals(at60).moves == 0 && Totals(at60).buttons == 0)
        // Expected magnitude: τ × (v0 − vStop) × gain / pointsPerUnit, plus the remainder.
        let s = PointerSettings()
        let v0 = 1200.0                                               // 60 pt in 50 ms
        let g = 1 + s.scrollAcceleration * min(max((v0 - s.scrollAccelerationLowSpeed) / (s.scrollAccelerationHighSpeed - s.scrollAccelerationLowSpeed), 0), 1)
        let expected = s.inertiaTimeConstant * (v0 - s.inertiaStopSpeed) * g / s.scrollPointsPerUnit
        #expect(abs(Double(total) - expected) / expected < 0.25)   // v0 estimate: 1200…1440 pt/s
        // Decay: per-tick amounts never grow (beyond ±1 from remainder carry).
        let perTick = at60.compactMap { if case .scroll(let w, _) = $0 { w } else { nil } }
        for (x, y) in zip(perTick, perTick.dropFirst()) { #expect(y <= x + 1) }
        #expect(perTick.first! > perTick.last!)
        #expect(a.advance(to: flick.liftTime + 20) == [])
    }

    @Test func nextTouchStopsInertiaAndDoesNotClick() {
        var e = engine()
        let flick = stripFlick(&e, step: -10, steps: 6)
        _ = e.advance(to: flick.liftTime + 0.05)
        #expect(e.isInertiaActive)
        #expect(e.handle(down(2, 100, 100, flick.liftTime + 0.1)) == [])
        #expect(!e.isInertiaActive)
        #expect(e.advance(to: flick.liftTime + 0.2) == [])
        #expect(e.handle(up(2, 100, 100, flick.liftTime + 0.15)) == [])    // the stopping tap: no click
        // The tap after that clicks normally.
        _ = e.handle(down(2, 100, 100, flick.liftTime + 1))
        #expect(e.handle(up(2, 100, 100, flick.liftTime + 1.05)) == [.buttons(.left), .buttons([])])
    }

    @Test func noInertiaWhenSlowPausedOrDisabled() {
        var slow = engine()
        _ = stripFlick(&slow, step: -1, steps: 30)          // 120 pt/s
        #expect(!slow.isInertiaActive)

        var paused = engine()
        _ = paused.handle(down(1, 340, 500, 0, strip: true))
        for i in 1...6 { _ = paused.handle(move(1, 340, 500 - 10 * Double(i), Double(i) / 120)) }
        _ = paused.handle(up(1, 340, 440, 0.2))             // lifted 150 ms after the last motion
        #expect(!paused.isInertiaActive)

        var off = engine { $0.scrollInertia = false }
        _ = stripFlick(&off, step: -10, steps: 6)
        #expect(!off.isInertiaActive)
    }

    @Test func twoFingerFlickHasInertiaAndResetStopsIt() {
        var e = engine()
        _ = e.handle(down(1, 100, 500, 0))
        _ = e.handle(down(2, 160, 500, 0.005))
        var y = 500.0
        for i in 1...8 {
            y -= 10
            _ = e.handle([move(1, 100, y, 0.005 + Double(i) / 120), move(2, 160, y, 0.005 + Double(i) / 120)])
        }
        _ = e.handle(up(1, 100, y, 0.005 + 8.0 / 120))
        #expect(e.isInertiaActive)
        _ = e.handle(up(2, 160, y, 0.005 + 8.0 / 120 + 0.01))   // the other finger's lift does not stop it
        #expect(e.isInertiaActive)
        let some = e.advance(to: 0.2)
        #expect(Totals(some).wheel > 0)
        #expect(e.reset() == [])
        #expect(!e.isInertiaActive)
    }

    // MARK: Net zero

    @Test func symmetricStripGesturesWithInertiaNetZero() {
        var e = engine()
        var all: [PointerAction] = []
        let upFlick = stripFlick(&e, step: -7.5, steps: 8)
        all += upFlick.actions + runInertia(&e, from: upFlick.liftTime, dt: 1.0 / 60)
        let downFlick = stripFlick(&e, step: 7.5, steps: 8, t0: upFlick.liftTime + 3)
        all += downFlick.actions + runInertia(&e, from: downFlick.liftTime, dt: 1.0 / 90)   // other tick rate
        let t = Totals(all)
        #expect(t.wheel == 0)
        #expect(t.scrolls > 4)
        #expect(t.moves == 0 && t.buttons == 0 && t.pan == 0)
    }

    @Test func symmetricTwoFingerGesturesNetZero() {
        var e = engine()
        var all: [PointerAction] = []
        for (dir, t0) in [(-1.0, 0.0), (1.0, 3.0)] {
            all += e.handle(down(1, 100, 500, t0))
            all += e.handle(down(2, 160, 500, t0 + 0.02))
            var y = 500.0
            var t = t0 + 0.02
            for _ in 0..<10 {
                t += 1.0 / 120
                y += 6 * dir
                all += e.handle([move(1, 100, y, t), move(2, 160, y, t)])
            }
            all += e.handle(up(1, 100, y, t))
            all += e.handle(up(2, 160, y, t + 0.01))
            all += runInertia(&e, from: t, dt: 1.0 / 60)
        }
        let tot = Totals(all)
        #expect(tot.wheel == 0 && tot.pan == 0 && tot.moves == 0 && tot.buttons == 0)
        #expect(tot.scrolls > 4)
    }

    @Test func stripScriptOfTheSelfTestIsExactlyNetZeroWithDefaults() {
        // Slow (75 pt/s) strip scroll up 25 pt and back, rested before the lift, as the app's
        // self-test plays it: default settings except inertia off.
        var e = PointerEngine(settings: { var s = PointerSettings(); s.scrollInertia = false; return s }())
        var out = e.handle(down(1, 340, 400, 0, strip: true))
        var t = 0.0, y = 400.0
        for _ in 0..<18 { t += 1.0 / 60; out += e.handle(move(1, 340, y, t)) }
        for _ in 0..<20 { t += 1.0 / 60; y -= 1.25; out += e.handle(move(1, 340, y, t)) }
        for _ in 0..<18 { t += 1.0 / 60; out += e.handle(move(1, 340, y, t)) }
        for _ in 0..<20 { t += 1.0 / 60; y += 1.25; out += e.handle(move(1, 340, y, t)) }
        for _ in 0..<6 { t += 1.0 / 60; out += e.handle(move(1, 340, y, t)) }
        out += e.handle(up(1, 340, y, t + 1.0 / 60))
        #expect(out == [.scroll(wheel: 1, pan: 0), .scroll(wheel: 1, pan: 0), .scroll(wheel: -1, pan: 0), .scroll(wheel: -1, pan: 0)])
    }
}
