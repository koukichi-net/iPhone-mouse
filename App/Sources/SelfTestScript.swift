import HIDCore

// Synthetic touch scripts for `--selftest=…` (design §11.2, safety rules §11.3).
//
// Pure values (no UIKit) so the same code can be dry-run through PointerEngine on the Mac.
// Every script must produce no button actions and net-zero motion and scroll:
// - touches are rested (stationary "moved" events) longer than the tap time before moving, so
//   motion never starts with a catch-up burst and a contact can never count as a tap;
// - one-finger steps are uniform and slower than `accelerationLowSpeed` (100 pt/s), so the gain is
//   exactly the sensitivity on both legs (timestamp rounding cannot change it) and the remainders
//   cancel; the app runs these scripts on a separate engine with default `PointerSettings`;
// - two-finger contacts move their centroid well past the slop, so they are never a right click.

struct ScriptedTouch: Sendable {
    /// Seconds from the start of the phase.
    var time: Double
    var event: TouchEvent
}

struct SelfTestPhase: Sendable {
    var name: String
    var touches: [ScriptedTouch]
    /// Wall-clock playback speed relative to the scripted times (the engine always sees the
    /// scripted timestamps, so its output does not change). 10 = ten times faster.
    var playbackSpeed: Double = 1
    /// Engine settings for this phase (nil: defaults with inertia off).
    var settings: PointerSettings? = nil
}

enum SelfTestScript {
    /// Phases for one `--selftest` value. Unknown names give no phases.
    static func phases(for name: String, origin: Vector2) -> [SelfTestPhase] {
        switch name {
        case "pointer":
            return [oneFingerDrag(origin: origin), twoFingerScroll(origin: origin), stripScroll(origin: origin)]
        case "inertia":
            return [stripInertia(origin: origin)]
        case "burst":
            // Same events twice: at 120 Hz, then delivered 10× faster (~1.2 kHz) to make sure the
            // stack's transmit queue fills and the pushBack / isReady path runs.
            var flood = burst(origin: origin)
            flood.name = "burst120x10"
            flood.playbackSpeed = 10
            return [burst(origin: origin), flood]
        default:
            return []
        }
    }

    /// One finger: rest 0.3 s, 27 steps of +1.5 pt at 60 Hz (40.5 pt right at 90 pt/s), 27 steps
    /// back, rest, lift. Default settings: 2.25 px per step, 60.75 px each way.
    static func oneFingerDrag(origin: Vector2, id: Int = 9001) -> SelfTestPhase {
        SelfTestPhase(name: "drag", touches: oneFinger(origin: origin, id: id, step: 1.5, steps: 27, rate: 60))
    }

    /// Touch events at 120 Hz for 1 s of motion: rest, 60 steps of +0.75 pt (45 pt right at
    /// 90 pt/s), 60 steps back, lift. Default settings: 1.125 px per event, 67.5 px each way.
    /// Small per event on purpose; the point is the event rate, to exercise back-pressure.
    static func burst(origin: Vector2, id: Int = 9101) -> SelfTestPhase {
        SelfTestPhase(name: "burst120", touches: oneFinger(origin: origin, id: id, step: 0.75, steps: 60, rate: 120))
    }

    private static func oneFinger(origin: Vector2, id: Int, step: Double, steps: Int, rate: Double) -> [ScriptedTouch] {
        let dt = 1 / rate
        var out: [ScriptedTouch] = []
        var t = 0.0
        var x = origin.x
        func add(_ phase: TouchPhase) {
            out.append(ScriptedTouch(time: t, event: TouchEvent(id: id, phase: phase, location: Vector2(x, origin.y), timestamp: t)))
        }
        add(.began)
        // Rest past the tap time (0.25 s) with stationary samples, so the first real step is
        // measured at the same speed as the others.
        let restSamples = Int((0.3 * rate).rounded(.up))
        for _ in 0..<restSamples { t += dt; add(.moved) }
        for _ in 0..<steps { t += dt; x += step; add(.moved) }
        for _ in 0..<steps { t += dt; x -= step; add(.moved) }
        for _ in 0..<Int((0.1 * rate).rounded(.up)) { t += dt; add(.moved) }
        t += dt; add(.ended)
        return out
    }

    /// Two fingers 100 pt apart: rest, both move up 25 pt in 2.5 pt steps (one finger per event,
    /// so the centroid moves 1.25 pt per event), hold, move back down 25 pt, lift both.
    /// With the default 10 pt per wheel unit this is wheel +1, +1, then −1, −1 (net 0).
    /// All positions are multiples of 1/4, so the remainders are exact.
    static func twoFingerScroll(origin: Vector2, ids: (Int, Int) = (9201, 9202)) -> SelfTestPhase {
        let dt = 1.0 / 60
        var out: [ScriptedTouch] = []
        var t = 0.0
        var y = origin.y
        let x1 = origin.x - 50, x2 = origin.x + 50
        func add(_ id: Int, _ x: Double, _ phase: TouchPhase) {
            out.append(ScriptedTouch(time: t, event: TouchEvent(id: id, phase: phase, location: Vector2(x, y), timestamp: t)))
        }
        add(ids.0, x1, .began)
        add(ids.1, x2, .began)
        for _ in 0..<18 { t += dt; add(ids.0, x1, .moved); add(ids.1, x2, .moved) }   // rest 0.3 s
        func leg(_ dy: Double) {
            // Finger 1 moves, then finger 2 catches up: centroid steps of dy/2.
            for _ in 0..<10 {
                t += dt
                let before = y
                y = before + dy
                out.append(ScriptedTouch(time: t, event: TouchEvent(id: ids.0, phase: .moved, location: Vector2(x1, y), timestamp: t)))
                out.append(ScriptedTouch(time: t, event: TouchEvent(id: ids.1, phase: .moved, location: Vector2(x2, y), timestamp: t)))
            }
        }
        leg(-2.5)                                                                      // up 25 pt
        for _ in 0..<18 { t += dt; add(ids.0, x1, .moved); add(ids.1, x2, .moved) }   // hold 0.3 s
        leg(+2.5)                                                                      // back down 25 pt
        for _ in 0..<6 { t += dt; add(ids.0, x1, .moved); add(ids.1, x2, .moved) }
        t += dt; add(ids.0, x1, .ended)
        t += dt; add(ids.1, x2, .ended)
        return SelfTestPhase(name: "scroll", touches: out)
    }
}

extension SelfTestScript {
    /// One finger that begins in the scroll strip: rest 0.3 s, up 25 pt in 1.25 pt steps at
    /// 60 Hz (75 pt/s: below the scroll-acceleration ramp and the inertia threshold), hold,
    /// back down 25 pt, rest, lift. Default settings: wheel +1, +1, −1, −1 (net 0).
    static func stripScroll(origin: Vector2, id: Int = 9301) -> SelfTestPhase {
        let dt = 1.0 / 60
        var out: [ScriptedTouch] = []
        var t = 0.0
        var y = origin.y
        let x = origin.x + 140   // near the right edge; the zone is set explicitly anyway
        func add(_ phase: TouchPhase) {
            out.append(ScriptedTouch(time: t, event: TouchEvent(id: id, phase: phase, location: Vector2(x, y), timestamp: t,
                                                                 zone: .scrollStrip)))
        }
        add(.began)
        for _ in 0..<18 { t += dt; add(.moved) }
        for _ in 0..<20 { t += dt; y -= 1.25; add(.moved) }
        for _ in 0..<18 { t += dt; add(.moved) }
        for _ in 0..<20 { t += dt; y += 1.25; add(.moved) }
        for _ in 0..<6 { t += dt; add(.moved) }
        t += dt; add(.ended)
        return SelfTestPhase(name: "strip", touches: out)
    }

    /// Strip flick up with inertia, then the mirror flick down (after the inertia ended).
    /// 60 pt at 120 Hz (≈1200 pt/s), lifted while moving. Settings: inertia on and a very low
    /// scroll gain (300 pt per wheel unit), so gesture + inertia stay at about 2 notches each
    /// way. Net 0 when both inertias run to their end (the runner waits before each touch).
    static func stripInertia(origin: Vector2, ids: (Int, Int) = (9401, 9402)) -> SelfTestPhase {
        var out: [ScriptedTouch] = []
        var t = 0.0
        let x = origin.x + 140
        func flick(id: Int, step: Double) {
            var y = origin.y
            func add(_ phase: TouchPhase) {
                out.append(ScriptedTouch(time: t, event: TouchEvent(id: id, phase: phase, location: Vector2(x, y), timestamp: t,
                                                                     zone: .scrollStrip)))
            }
            add(.began)
            for _ in 0..<36 { t += 1.0 / 120; add(.moved) }        // rest 0.3 s
            for _ in 0..<6 { t += 1.0 / 120; y += step; add(.moved) }
            add(.ended)                                              // lifted while moving
        }
        flick(id: ids.0, step: -10)
        t += 1.5                                                     // inertia lasts ≈ 0.85 s
        flick(id: ids.1, step: 10)
        var s = PointerSettings()
        s.scrollInertia = true
        s.scrollPointsPerUnit = 300
        return SelfTestPhase(name: "inertia", touches: out, settings: s)
    }
}

/// Sums of a list of pointer actions, for logs and the dry run.
struct ActionTotals: Sendable, CustomStringConvertible {
    var moves = 0, dx = 0, dy = 0
    var scrolls = 0, wheel = 0, pan = 0
    var wheelUp = 0, wheelDown = 0
    var buttons = 0

    mutating func merge(_ o: ActionTotals) {
        moves += o.moves; dx += o.dx; dy += o.dy
        scrolls += o.scrolls; wheel += o.wheel; pan += o.pan
        wheelUp += o.wheelUp; wheelDown += o.wheelDown
        buttons += o.buttons
    }

    mutating func add(_ a: PointerAction) {
        switch a {
        case .move(let x, let y): moves += 1; dx += x; dy += y
        case .scroll(let w, let p):
            scrolls += 1; wheel += w; pan += p
            if w > 0 { wheelUp += w } else { wheelDown += w }
        case .buttons: buttons += 1
        }
    }

    var description: String {
        "moves=\(moves) sumDx=\(dx) sumDy=\(dy) scrolls=\(scrolls) sumWheel=\(wheel) (+\(wheelUp)/\(wheelDown)) sumPan=\(pan) buttonActions=\(buttons)"
    }
}
