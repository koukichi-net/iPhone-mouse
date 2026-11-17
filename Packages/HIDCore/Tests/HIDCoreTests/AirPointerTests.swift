import Testing
import Foundation
@testable import HIDCore

/// Feeds `seconds` of a constant rotation at `rate` Hz (or explicit times) and sums the output.
private func run(_ p: inout AirPointer, rate w: Vector3, gravity g: Vector3, times: [Double]) -> (dx: Int, dy: Int, outputs: [(Int, Int)]) {
    var sx = 0, sy = 0
    var outs: [(Int, Int)] = []
    for t in times {
        let o = p.update(rotationRate: w, gravity: g, timestamp: t)
        sx += o.dx; sy += o.dy
        outs.append((o.dx, o.dy))
    }
    return (sx, sy, outs)
}

private func regularTimes(_ seconds: Double, hz: Double = 100, start: Double = 1000) -> [Double] {
    let n = Int((seconds * hz).rounded())
    return (0...n).map { start + Double($0) / hz }
}

private let flat = Vector3(0, 0, -1)          // lying face up, top edge pointing forward
private let s = AirPointerSettings()

/// Expected counts for a constant speed held for `seconds` (first sample only sets the time
/// base; smoothing lags by about one time constant).
private func expected(_ speed: Double, _ seconds: Double) -> Double {
    (speed - s.deadZone) * s.gain * (seconds - s.smoothingTime)
}

@Suite("AirPointer")
struct AirPointerTests {
    @Test func turningRightMovesRightOnly() {
        var p = AirPointer()
        // Seen from above, clockwise = negative rotation about the up axis (+z when flat).
        let r = run(&p, rate: Vector3(0, 0, -0.5), gravity: flat, times: regularTimes(1))
        #expect(r.dy == 0)
        #expect(r.dx > 0)
        #expect(abs(Double(r.dx) - expected(0.5, 1)) < 15, "dx=\(r.dx) expected≈\(expected(0.5, 1))")
    }

    @Test func turningLeftMovesLeftSymmetrically() {
        var a = AirPointer(), b = AirPointer()
        let right = run(&a, rate: Vector3(0, 0, -0.5), gravity: flat, times: regularTimes(1))
        let left = run(&b, rate: Vector3(0, 0, 0.5), gravity: flat, times: regularTimes(1))
        #expect(left.dx == -right.dx)
        #expect(left.dy == 0)
    }

    @Test func tiltingUpMovesUpOnly() {
        var p = AirPointer()
        // Top edge rising = positive rotation about the screen's x axis when flat.
        let r = run(&p, rate: Vector3(0.5, 0, 0), gravity: flat, times: regularTimes(1))
        #expect(r.dx == 0)
        #expect(r.dy < 0)
        #expect(abs(Double(-r.dy) - expected(0.5, 1)) < 15)
        var q = AirPointer()
        let down = run(&q, rate: Vector3(-0.5, 0, 0), gravity: flat, times: regularTimes(1))
        #expect(down.dy == -r.dy && down.dx == 0)
    }

    @Test func rollAboutThePointingDirectionIsIgnored() {
        var p = AirPointer()
        let r = run(&p, rate: Vector3(0, 1.0, 0), gravity: flat, times: regularTimes(1))
        #expect(r.dx == 0 && r.dy == 0)
    }

    /// The same world motion gives the same pointer motion however the phone is rolled in the
    /// hand (screen up, sideways, upside down…).
    @Test(arguments: [0.0, 30, 45, 90, 135, 180, 225, 270, 315])
    func rolledPhoneBehavesTheSame(rollDegrees: Double) {
        let phi = rollDegrees * .pi / 180
        // Rolling about the top edge (device y) keeps gravity perpendicular to it.
        let g = Vector3(sin(phi), 0, -cos(phi))
        let up = -g
        let right = Vector3(cos(phi), 0, sin(phi))   // = top × up, horizontal, to the user's right
        #expect(abs(right.dot(up)) < 1e-12)

        var a = AirPointer(), ref = AirPointer()
        let turn = run(&a, rate: up * -0.5, gravity: g, times: regularTimes(1))
        let flatTurn = run(&ref, rate: Vector3(0, 0, -0.5), gravity: flat, times: regularTimes(1))
        #expect(turn.dy == 0)
        #expect(abs(turn.dx - flatTurn.dx) <= 1, "roll \(rollDegrees)°: dx=\(turn.dx) flat=\(flatTurn.dx)")

        var b = AirPointer(), ref2 = AirPointer()
        let tilt = run(&b, rate: right * 0.5, gravity: g, times: regularTimes(1))
        let flatTilt = run(&ref2, rate: Vector3(0.5, 0, 0), gravity: flat, times: regularTimes(1))
        #expect(tilt.dx == 0)
        #expect(abs(tilt.dy - flatTilt.dy) <= 1 && tilt.dy < 0)
    }

    @Test func raisedPhoneStillTurnsHorizontally() {
        // Top edge raised 30° (pointing up at a screen), screen facing up-back.
        let a = 30.0 * .pi / 180
        let g = Vector3(0, -sin(a), -cos(a))
        var p = AirPointer()
        let r = run(&p, rate: (-g) * -0.5, gravity: g, times: regularTimes(1))
        #expect(r.dx > 0 && r.dy == 0)
        // A rotation about the screen's own z axis is not pure turning any more: only its
        // vertical component (cos 30°) turns the pointer.
        var q = AirPointer()
        let z = run(&q, rate: Vector3(0, 0, -0.5), gravity: g, times: regularTimes(1))
        #expect(z.dx > 0 && z.dx < r.dx)
    }

    @Test func pointingStraightUpDoesNotBreak() {
        let g = Vector3(0, -1, 0)   // top edge straight up
        var p = AirPointer()
        let r = run(&p, rate: Vector3(0, -0.5, 0), gravity: g, times: regularTimes(0.5))
        #expect(r.dx > 0 && r.dy == 0)
        var q = AirPointer()
        let t = run(&q, rate: Vector3(0.5, 0, 0), gravity: g, times: regularTimes(0.5))
        #expect(t.dx == 0 && t.dy < 0)
    }

    @Test func zeroInputGivesNothing() {
        var p = AirPointer()
        let r = run(&p, rate: .zero, gravity: flat, times: regularTimes(2))
        #expect(r.dx == 0 && r.dy == 0)
        #expect(p.stats.samples == 201 && p.stats.movingSamples == 0)
    }

    @Test func deadZoneSwallowsTremor() {
        var p = AirPointer()
        // Slow drift below the dead zone, and ±0.04 rad/s tremor at 8 Hz (smoothed below it).
        let still = run(&p, rate: Vector3(0, 0, -0.02), gravity: flat, times: regularTimes(2))
        #expect(still.dx == 0 && still.dy == 0)
        var q = AirPointer()
        var sum = (0, 0)
        for (i, t) in regularTimes(2).enumerated() {
            let w = 0.04 * sin(2 * .pi * 8 * Double(i) / 100)
            let o = q.update(rotationRate: Vector3(w * 0.3, 0, w), gravity: flat, timestamp: t)
            sum.0 += o.dx; sum.1 += o.dy
        }
        #expect(abs(sum.0) <= 2 && abs(sum.1) <= 2, "tremor leaked \(sum)")
    }

    @Test func deadZoneHasNoJump() {
        // Just above the dead zone the speed starts from (almost) zero.
        var p = AirPointer()
        let r = run(&p, rate: Vector3(0, 0, -(s.deadZone + 0.002)), gravity: flat, times: regularTimes(1))
        #expect(r.dx >= 0 && r.dx <= 3)
    }

    @Test func remainderIsCarried() {
        var cfg = AirPointerSettings()
        cfg.smoothingTime = 0
        cfg.deadZone = 0
        var p = AirPointer(settings: cfg)
        // 0.02 rad/s × 1500 × 0.01 s = 0.3 counts per sample.
        let r = run(&p, rate: Vector3(0, 0, -0.02), gravity: flat, times: regularTimes(1))
        #expect(r.outputs.allSatisfy { $0.0 == 0 || $0.0 == 1 })
        #expect(r.dx == 29 || r.dx == 30, "dx=\(r.dx)")   // 100 steps × 0.3 = 30 (float rounding)
        #expect(r.outputs.filter { $0.0 == 1 }.count == r.dx)
    }

    @Test func irregularSampleSpacingIntegratesTheSame() {
        var a = AirPointer(), b = AirPointer()
        let regular = run(&a, rate: Vector3(0.2, 0, -0.6), gravity: flat, times: regularTimes(1))
        // Same span, intervals of 4…16 ms in a fixed pattern.
        var times: [Double] = [1000]
        let pattern = [0.004, 0.016, 0.009, 0.011, 0.013, 0.007, 0.010, 0.012, 0.008, 0.010]
        var i = 0
        while times.last! < 1001 - 1e-9 {
            times.append(min(1001, times.last! + pattern[i % pattern.count]))
            i += 1
        }
        let jittered = run(&b, rate: Vector3(0.2, 0, -0.6), gravity: flat, times: times)
        #expect(abs(jittered.dx - regular.dx) <= 3, "\(jittered.dx) vs \(regular.dx)")
        #expect(abs(jittered.dy - regular.dy) <= 3, "\(jittered.dy) vs \(regular.dy)")
    }

    @Test func gapsAreNotIntegratedInFull() {
        var p = AirPointer()
        _ = p.update(rotationRate: Vector3(0, 0, -1), gravity: flat, timestamp: 10)
        let o = p.update(rotationRate: Vector3(0, 0, -1), gravity: flat, timestamp: 12)   // 2 s gap
        // At most maxStep worth (and less after smoothing).
        #expect(o.dx > 0 && Double(o.dx) <= 1 * s.gain * s.maxStep)
    }

    @Test func outputIsClamped() {
        var cfg = AirPointerSettings()
        cfg.smoothingTime = 0
        var p = AirPointer(settings: cfg)
        let r = run(&p, rate: Vector3(0, 0, -100), gravity: flat, times: [0, 0.05, 0.10])
        #expect(r.outputs.allSatisfy { abs($0.0) <= cfg.maxCountsPerSample })
        #expect(r.outputs.last!.0 == cfg.maxCountsPerSample)   // 15 rad/s × 1500 × 0.05 = 1125 → 400
    }

    @Test func badSamplesGiveNothing() {
        var p = AirPointer()
        let r = run(&p, rate: Vector3(0, 0, -1), gravity: .zero, times: regularTimes(0.2))
        #expect(r.dx == 0 && r.dy == 0)
        #expect(p.stats.invalid == 21)
        var q = AirPointer()
        let n = run(&q, rate: Vector3(.nan, 0, 0), gravity: flat, times: regularTimes(0.2))
        #expect(n.dx == 0 && n.dy == 0)
        // Repeated timestamps.
        var d = AirPointer()
        let dup = run(&d, rate: Vector3(0, 0, -1), gravity: flat, times: [5, 5, 5])
        #expect(dup.dx == 0)
    }

    @Test func firstSampleOnlySetsTheTimeBase() {
        var p = AirPointer()
        let o = p.update(rotationRate: Vector3(0, 0, -3), gravity: flat, timestamp: 1)
        #expect(o.dx == 0 && o.dy == 0)
    }

    @Test func sensitivityScalesTheGain() {
        var a = AirPointer(settings: AirPointerSettings(sensitivity: 1))
        var b = AirPointer(settings: AirPointerSettings(sensitivity: 2))
        let one = run(&a, rate: Vector3(0, 0, -0.4), gravity: flat, times: regularTimes(1))
        let two = run(&b, rate: Vector3(0, 0, -0.4), gravity: flat, times: regularTimes(1))
        #expect(abs(two.dx - 2 * one.dx) <= 2)
    }

    @Test func resetClearsHistoryAndStats() {
        var p = AirPointer()
        _ = run(&p, rate: Vector3(0, 0, -0.5), gravity: flat, times: regularTimes(0.3))
        #expect(p.stats.samples == 31 && p.stats.sumDX > 0)
        #expect(abs(p.stats.sampleRate - 100) < 0.5)
        p.reset()
        #expect(p.stats == AirPointer.Stats())
        let o = p.update(rotationRate: Vector3(0, 0, -0.5), gravity: flat, timestamp: 2000)
        #expect(o.dx == 0)   // a new time base, no carried remainder
    }

    @Test func netZeroForOppositeMotions() {
        var p = AirPointer()
        var sum = (0, 0)
        var t = 0.0
        for (w, n) in [(Vector3(0, 0, -0.5), 30), (Vector3(0.5, 0, 0), 30), (Vector3(0, 0, 0.5), 30), (Vector3(-0.5, 0, 0), 30)] {
            for _ in 0..<n {
                let o = p.update(rotationRate: w, gravity: flat, timestamp: t)
                sum.0 += o.dx; sum.1 += o.dy
                t += 0.01
            }
        }
        // Smoothing tails make it only approximately zero.
        #expect(abs(sum.0) <= 25 && abs(sum.1) <= 25, "\(sum)")
    }
}
