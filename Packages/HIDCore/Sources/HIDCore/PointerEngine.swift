// Touch stream → pointer actions (design §8.1).

import Foundation

/// A 2-D point or vector in iPhone points (screen coordinates: +x right, +y down).
public struct Vector2: Sendable, Hashable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    public init(x: Double, y: Double) { self.x = x; self.y = y }

    public static let zero = Vector2(0, 0)
    public var length: Double { (x * x + y * y).squareRoot() }
    public var isFinite: Bool { x.isFinite && y.isFinite }

    public static func + (a: Vector2, b: Vector2) -> Vector2 { Vector2(a.x + b.x, a.y + b.y) }
    public static func - (a: Vector2, b: Vector2) -> Vector2 { Vector2(a.x - b.x, a.y - b.y) }
    public static func * (a: Vector2, s: Double) -> Vector2 { Vector2(a.x * s, a.y * s) }
}

public enum TouchPhase: Sendable, Hashable {
    case began
    case moved
    case ended
    case cancelled
}

/// Where on the touch surface a touch began (only the `.began` event's zone matters).
public enum TouchZone: Sendable, Hashable {
    /// The trackpad area.
    case surface
    /// The scroll strip along one edge (`ScrollStripLayout`).
    case scrollStrip
}

/// One touch change, as delivered by UIKit (one event per changed `UITouch`).
public struct TouchEvent: Sendable, Hashable {
    /// Stable identifier of the finger for the life of the touch.
    public var id: Int
    public var phase: TouchPhase
    /// Location in points.
    public var location: Vector2
    /// Seconds on any monotonic clock (e.g. `UITouch.timestamp`).
    public var timestamp: Double
    /// Zone the touch began in (set by the view from `ScrollStripLayout`; read on `.began`).
    public var zone: TouchZone

    public init(id: Int, phase: TouchPhase, location: Vector2, timestamp: Double, zone: TouchZone = .surface) {
        self.id = id
        self.phase = phase
        self.location = location
        self.timestamp = timestamp
        self.zone = zone
    }
}

/// Output of the engine, in the order it must reach the host.
public enum PointerAction: Sendable, Hashable {
    /// The complete button state changed to this value (a transition).
    case buttons(MouseButtons)
    /// Relative pointer motion in host pixels (+x right, +y down).
    case move(dx: Int, dy: Int)
    /// Scroll in wheel units: +wheel = scroll up (fingers moved up), +pan = scroll right
    /// (fingers moved right). Inverted when `PointerSettings.invertScroll` is true.
    case scroll(wheel: Int, pan: Int)
}

/// Which edge of the touch surface carries the scroll strip.
public enum ScrollStripEdge: String, Sendable, Hashable, CaseIterable {
    case right
    case left
    case off
}

/// Geometry of the scroll strip (design §8.1): a lane of `width` points along one edge.
public struct ScrollStripLayout: Sendable, Hashable {
    public static let defaultWidth: Double = 40
    public static let widthRange: ClosedRange<Double> = 28...72

    public var edge: ScrollStripEdge
    public var width: Double

    public init(edge: ScrollStripEdge = .right, width: Double = ScrollStripLayout.defaultWidth) {
        self.edge = edge
        self.width = width
    }

    /// The strip's x range on a surface `surfaceWidth` points wide (nil when off or degenerate).
    /// The strip never takes more than half of the surface.
    public func xRange(surfaceWidth: Double) -> ClosedRange<Double>? {
        guard edge != .off, surfaceWidth > 0, width.isFinite, width > 0 else { return nil }
        let w = min(width, surfaceWidth / 2)
        return edge == .right ? (surfaceWidth - w)...surfaceWidth : 0...w
    }

    /// The zone a touch at `location` begins in.
    public func zone(at location: Vector2, surfaceWidth: Double) -> TouchZone {
        guard let r = xRange(surfaceWidth: surfaceWidth), location.x.isFinite else { return .surface }
        // Touches just outside the surface edge (UIKit can report slightly negative or
        // too-large x at the border) still count as the strip.
        switch edge {
        case .right: return location.x >= r.lowerBound ? .scrollStrip : .surface
        case .left: return location.x <= r.upperBound ? .scrollStrip : .surface
        case .off: return .surface
        }
    }
}

/// Tunables of `PointerEngine`. Distances are in iPhone points, times in seconds.
public struct PointerSettings: Sendable, Hashable {
    /// Longest contact (first finger down → last finger up) that still counts as a tap.
    public var tapMaxDuration: Double = 0.25
    /// A finger that moves farther than this from where it touched down is no longer a
    /// tap; one-finger pointer motion and two-finger scrolling start only past it.
    /// 10 pt matches UIKit's tap `allowableMovement`.
    public var tapSlop: Double = 10
    /// Maximum time from a tap's lift to the next touch-down for that touch to become a
    /// drag (double-tap-and-hold-then-move) or a second click.
    public var doubleTapWindow: Double = 0.3
    /// Host pixels per point at low finger speed.
    public var sensitivity: Double = 1.5
    /// Extra gain at high speed: gain = sensitivity × (1 + acceleration × f), where f goes
    /// linearly from 0 at `accelerationLowSpeed` to 1 at `accelerationHighSpeed`.
    /// 0 disables acceleration. Note the host applies its own acceleration on top.
    public var acceleration: Double = 1.0
    /// Finger speed (points/s) at or below which no acceleration applies.
    public var accelerationLowSpeed: Double = 100
    /// Finger speed (points/s) at or above which full acceleration applies.
    public var accelerationHighSpeed: Double = 1200

    /// Points of scroll movement per wheel / pan unit at low speed (the per-host scroll
    /// speed sets this; it is the base gain of scrolling).
    public var scrollPointsPerUnit: Double = 10
    /// Scroll acceleration: units = points / scrollPointsPerUnit × (1 + scrollAcceleration × f),
    /// f linear from 0 at `scrollAccelerationLowSpeed` to 1 at `scrollAccelerationHighSpeed`
    /// (speed of the scrolling finger or of the two-finger centroid). 0 disables it.
    public var scrollAcceleration: Double = 1.5
    public var scrollAccelerationLowSpeed: Double = 250
    public var scrollAccelerationHighSpeed: Double = 1500
    /// Reverse both scroll axes.
    public var invertScroll: Bool = false

    /// Momentum after a fast scroll (strip or two-finger): the scroll continues with the
    /// release velocity, decaying as exp(−t / inertiaTimeConstant), until the next touch or
    /// until the speed falls below `inertiaStopSpeed`. Driven by `advance(to:)`.
    public var scrollInertia: Bool = true
    /// Seconds for the inertial speed to fall to 1/e. Total inertial travel is
    /// inertiaTimeConstant × (releaseSpeed − inertiaStopSpeed) points.
    public var inertiaTimeConstant: Double = 0.25
    /// Release speed (points/s) needed to start inertia.
    public var inertiaMinSpeed: Double = 300
    /// Inertia ends when its speed falls below this (points/s).
    public var inertiaStopSpeed: Double = 40

    /// A strip touch starts scrolling once it moved this far vertically (the motion so far is
    /// then sent at once). Keeps a resting thumb from scrolling.
    public var stripSlop: Double = 4

    /// A second finger landing within this time after the first, while the first has moved
    /// no farther than `twoFingerGraceTravel`, makes the gesture two-finger from the start:
    /// one-finger pointer motion is held back during this time so none leaks out.
    public var twoFingerGrace: Double = 0.1
    public var twoFingerGraceTravel: Double = 20

    /// When false, taps never click: no one-finger left click, no two-finger right click,
    /// and therefore no tap-and-drag. Moving and scrolling are unaffected, and on-screen
    /// buttons (`setButton`) still work.
    public var tapToClick: Bool = true

    public init() {}
}

/// Turns touches into pointer actions.
///
/// Gestures:
/// - **Move**: one finger. Motion starts once the finger leaves `tapSlop` or the touch is
///   older than `tapMaxDuration`, and not before `twoFingerGrace` has passed (unless the finger
///   travelled more than `twoFingerGraceTravel`); the motion held back so far is then sent at
///   once, so nothing is lost. Scaled by the speed-based gain; fractional pixels carry over.
/// - **Tap**: one finger, ≤ `tapMaxDuration`, never left `tapSlop` → left click
///   (press, release) emitted *at the lift, without waiting*. A touch that stops inertia is
///   not a tap.
/// - **Two-finger tap**: two fingers, neither left the slop, all lifted within
///   `tapMaxDuration` of the first touch-down → right click, emitted when the last finger
///   lifts. The remaining finger after the first lift never clicks or moves.
/// - **Drag**: a touch that begins within `doubleTapWindow` after a tap's lift and then
///   starts moving (as for Move) presses the left button (before its first motion), moves with it
///   held and releases on lift. If it lifts without leaving the slop quickly, it is a
///   second click (so a double tap is a double click).
/// - **Scroll**: two fingers; the centroid motion past the slop becomes wheel (vertical)
///   and AC Pan (horizontal), with remainder carry. When one finger lifts, scrolling stops
///   (inertia may start); the remaining finger does nothing; if a finger lands again, the
///   two-finger scroll resumes from the new centroid (no jump).
/// - **Strip scroll**: one finger that *begins* in the scroll strip (`TouchZone.scrollStrip`)
///   scrolls vertically past `stripSlop`, even after leaving the strip. It never moves the
///   pointer or clicks. A second finger within the grace period turns it into a two-finger
///   gesture; later extra fingers are ignored.
/// - **Inertia**: after a strip or two-finger scroll released faster than `inertiaMinSpeed`.
///   Call `advance(to:)` with the current time while `isInertiaActive`; any new touch stops it.
/// - Three or more fingers, or a finger added during a gesture that cannot absorb it,
///   suppress output until all fingers lift. Extra fingers during a drag are ignored.
/// - Cancel releases any gesture-held button and never clicks.
///
/// Tap design: because the first tap clicks immediately, the drag starts with a second
/// press. A host may count that press as the second click of a double click (a
/// "double-click drag"). The alternative — hold the first press until the window ends —
/// delays every click's release by the window, so it was not chosen.
///
/// On-screen buttons use `setButton(_:pressed:)`; a button is reported down while either
/// the gesture or the on-screen button holds it.
public struct PointerEngine: Sendable {
    public var settings: PointerSettings

    /// The button state last reported through `.buttons` (initially none).
    public private(set) var buttons: MouseButtons = []

    private struct Touch: Sendable {
        var start: Vector2
        var startTime: Double
        /// Position up to which motion has been emitted.
        var anchor: Vector2
        var previous: Vector2
        var previousTime: Double
        var exceededSlop = false
    }

    private struct Pointing: Sendable {
        var primary: Int
        var startTime: Double
        var dragCandidate: Bool
        var dragging = false
        /// The touch stopped inertia: it is never a tap.
        var noTap: Bool
    }

    private struct TwoFinger: Sendable {
        var startTime: Double
        var anchor: Vector2
        var scrolling: Bool
        var tapEligible: Bool
        var fingerLifted = false
    }

    private struct Strip: Sendable {
        var primary: Int
        var startTime: Double
        var scrolling = false
    }

    private enum Gesture: Sendable {
        case idle
        case pointing(Pointing)
        case twoFinger(TwoFinger)
        case strip(Strip)
        case suppressed
    }

    private struct Inertia: Sendable {
        var t0: Double
        /// Release velocity in points/s (finger space).
        var v0: Vector2
        /// Scroll gain frozen at the release.
        var gain: Double
        var tEnd: Double
        /// Displacement already converted to scroll (points).
        var emitted = Vector2.zero
    }

    private var touches: [Int: Touch] = [:]
    private var gesture: Gesture = .idle
    private var lastTapTime: Double?
    private var gestureButtons: MouseButtons = []
    private var externalButtons: MouseButtons = []
    private var moveRemainder = Vector2.zero
    private var scrollRemainder = Vector2.zero   // x: pan, y: wheel
    private var lastSpeed: Double = 0
    private var scrollTrack = VelocityTracker()
    private var inertia: Inertia?

    public init(settings: PointerSettings = PointerSettings()) {
        self.settings = settings
    }

    /// Number of fingers currently down.
    public var activeTouchCount: Int { touches.count }

    /// True while inertial scrolling continues; call `advance(to:)` (e.g. every frame).
    public var isInertiaActive: Bool { inertia != nil }

    // MARK: - Input

    public mutating func handle(_ events: [TouchEvent]) -> [PointerAction] {
        events.flatMap { handle($0) }
    }

    public mutating func handle(_ event: TouchEvent) -> [PointerAction] {
        guard event.location.isFinite, event.timestamp.isFinite else { return [] }
        switch event.phase {
        case .began: return began(event)
        case .moved: return moved(event)
        case .ended: return ended(event, cancelled: false)
        case .cancelled: return ended(event, cancelled: true)
        }
    }

    /// Press or release an on-screen button.
    public mutating func setButton(_ button: MouseButtons, pressed: Bool) -> [PointerAction] {
        if pressed { externalButtons.formUnion(button) } else { externalButtons.subtract(button) }
        return syncButtons()
    }

    /// Continue inertial scrolling up to `time` (same clock as the touch timestamps). Returns
    /// the scroll for the time since the last call; ends the inertia when it has decayed.
    /// Times before the last call are ignored.
    public mutating func advance(to time: Double) -> [PointerAction] {
        guard var i = inertia, time.isFinite else { return [] }
        let tau = settings.inertiaTimeConstant
        let te = min(time, i.tEnd)
        var out: [PointerAction] = []
        if te > i.t0, tau > 0 {
            let travelled = i.v0 * (tau * (1 - exp(-(te - i.t0) / tau)))
            let delta = travelled - i.emitted
            if delta.x * i.v0.x >= 0, delta.y * i.v0.y >= 0 {   // never backwards (stale time)
                i.emitted = travelled
                if let a = scrollAction(delta, gain: i.gain) { out.append(a) }
            }
        }
        inertia = time >= i.tEnd ? nil : i
        return out
    }

    /// Stop inertia without output (e.g. scroll settings changed).
    public mutating func stopInertia() { inertia = nil }

    /// Forget all touches and release every button (gesture-held and on-screen), e.g. when
    /// the app leaves the foreground or the host changes. Stops inertia.
    public mutating func reset() -> [PointerAction] {
        touches.removeAll()
        gesture = .idle
        lastTapTime = nil
        gestureButtons = []
        externalButtons = []
        moveRemainder = .zero
        scrollRemainder = .zero
        scrollTrack.reset()
        inertia = nil
        return syncButtons()
    }

    // MARK: - Phases

    private mutating func began(_ e: TouchEvent) -> [PointerAction] {
        let stoppedInertia = inertia != nil
        inertia = nil
        touches[e.id] = Touch(start: e.location, startTime: e.timestamp, anchor: e.location,
                              previous: e.location, previousTime: e.timestamp)
        switch gesture {
        case .idle:
            if touches.count == 1 {
                let candidate = lastTapTime.map { e.timestamp >= $0 && e.timestamp - $0 <= settings.doubleTapWindow } ?? false
                lastTapTime = nil
                moveRemainder = .zero
                if e.zone == .scrollStrip {
                    scrollRemainder = .zero
                    scrollTrack.reset()
                    scrollTrack.add(Vector2(0, e.location.y), at: e.timestamp)
                    gesture = .strip(Strip(primary: e.id, startTime: e.timestamp))
                } else {
                    gesture = .pointing(Pointing(primary: e.id, startTime: e.timestamp,
                                                 dragCandidate: candidate && !stoppedInertia, noTap: stoppedInertia))
                }
            } else {
                gesture = .suppressed
            }
        case .pointing(let p):
            if p.dragging { break }   // extra finger during a drag: ignored
            if touches.count == 2 {
                // Pointer motion was held back during the grace period, so a second finger
                // landing early makes this a two-finger gesture from the start.
                let first = touches[p.primary]
                let eligible = !p.noTap && (first.map { !$0.exceededSlop } ?? false)
                    && e.timestamp - p.startTime <= settings.tapMaxDuration
                startTwoFinger(startTime: p.startTime, scrolling: false, tapEligible: eligible, at: e.timestamp)
            } else {
                gesture = .suppressed
            }
        case .strip(let s):
            guard touches.count == 2, let first = touches[s.primary] else { break }   // extra fingers: ignored
            let early = e.timestamp - s.startTime <= settings.twoFingerGrace
                && (first.previous - first.start).length <= settings.twoFingerGraceTravel
            if early {
                startTwoFinger(startTime: s.startTime, scrolling: false, tapEligible: false, at: e.timestamp)
            }
        case .twoFinger(let g):
            if g.fingerLifted, touches.count == 2 {
                // A finger lands again after one lifted: resume from the new centroid.
                startTwoFinger(startTime: g.startTime, scrolling: g.scrolling, tapEligible: false, at: e.timestamp,
                               keepRemainder: true)
            } else {
                gesture = .suppressed
            }
        case .suppressed:
            break
        }
        return []
    }

    private mutating func startTwoFinger(startTime: Double, scrolling: Bool, tapEligible: Bool, at t: Double,
                                         keepRemainder: Bool = false) {
        if !keepRemainder { scrollRemainder = .zero }
        let c = centroid()
        scrollTrack.reset()
        scrollTrack.add(c, at: t)
        gesture = .twoFinger(TwoFinger(startTime: startTime, anchor: c, scrolling: scrolling, tapEligible: tapEligible))
    }

    private mutating func moved(_ e: TouchEvent) -> [PointerAction] {
        guard var touch = touches[e.id] else { return [] }
        let dt = e.timestamp - touch.previousTime
        if dt > 0 {
            let speed = (e.location - touch.previous).length / dt
            if speed.isFinite { lastSpeed = speed }
        }
        touch.previous = e.location
        touch.previousTime = e.timestamp
        if !touch.exceededSlop, (e.location - touch.start).length > settings.tapSlop {
            touch.exceededSlop = true
        }
        touches[e.id] = touch

        switch gesture {
        case .pointing(var p):
            // Motion starts past the slop, or as soon as the touch is too old to be a tap
            // (so small, precise nudges work after resting the finger) — but not during the
            // two-finger grace period unless the finger already travelled far.
            let age = e.timestamp - p.startTime
            let graceOver = age > settings.twoFingerGrace || (e.location - touch.start).length > settings.twoFingerGraceTravel
            let active = (touch.exceededSlop || age > settings.tapMaxDuration) && graceOver
            guard e.id == p.primary, active else { return [] }
            var out: [PointerAction] = []
            if p.dragCandidate, !p.dragging {
                p.dragging = true
                gestureButtons.insert(.left)
                gesture = .pointing(p)
                out += syncButtons()
            }
            let delta = e.location - touch.anchor
            touches[e.id]?.anchor = e.location
            if let move = pointerMove(delta, speed: lastSpeed) { out.append(move) }
            return out

        case .strip(var s):
            guard e.id == s.primary else { return [] }
            scrollTrack.add(Vector2(0, e.location.y), at: e.timestamp)
            if !s.scrolling, abs(e.location.y - touch.start.y) > settings.stripSlop {
                s.scrolling = true
                gesture = .strip(s)
            }
            guard s.scrolling else { return [] }
            let delta = Vector2(0, e.location.y - touch.anchor.y)
            touches[e.id]?.anchor = e.location
            let gain = scrollGain(speed: scrollTrack.velocity(span: VelocityTracker.gainSpan).length)
            return scrollAction(delta, gain: gain).map { [$0] } ?? []

        case .twoFinger(var g):
            if touch.exceededSlop { g.tapEligible = false }
            var out: [PointerAction] = []
            if !g.fingerLifted {
                let c = centroid()
                scrollTrack.add(c, at: e.timestamp)
                if !g.scrolling, (c - g.anchor).length > settings.tapSlop {
                    g.scrolling = true
                    g.tapEligible = false
                }
                if g.scrolling {
                    let delta = c - g.anchor
                    g.anchor = c
                    let gain = scrollGain(speed: scrollTrack.velocity(span: VelocityTracker.gainSpan).length)
                    if let scroll = scrollAction(delta, gain: gain) { out.append(scroll) }
                }
            }
            gesture = .twoFinger(g)
            return out

        case .idle, .suppressed:
            return []
        }
    }

    private mutating func ended(_ e: TouchEvent, cancelled: Bool) -> [PointerAction] {
        guard let touch = touches.removeValue(forKey: e.id) else { return [] }
        if cancelled { lastTapTime = nil }
        var out: [PointerAction] = []

        switch gesture {
        case .pointing(let p):
            guard e.id == p.primary else { return [] }   // extra finger lifted during a drag
            if p.dragging {
                gestureButtons.remove(.left)
                out += syncButtons()
            } else if settings.tapToClick, !cancelled, !p.noTap, !touch.exceededSlop,
                      e.timestamp - p.startTime <= settings.tapMaxDuration {
                out += click(.left)
                lastTapTime = e.timestamp
            }
            gesture = touches.isEmpty ? .idle : .suppressed

        case .strip(let s):
            guard e.id == s.primary else { return [] }   // ignored extra finger
            if s.scrolling, !cancelled { startInertia(at: e.timestamp) }
            gesture = touches.isEmpty ? .idle : .suppressed

        case .twoFinger(var g):
            if cancelled || touch.exceededSlop { g.tapEligible = false }
            if !g.fingerLifted, g.scrolling, !cancelled { startInertia(at: e.timestamp) }
            if touches.isEmpty {
                gesture = .idle
                if settings.tapToClick, g.tapEligible, e.timestamp - g.startTime <= settings.tapMaxDuration {
                    out += click(.right)
                }
            } else {
                g.fingerLifted = true
                gesture = .twoFinger(g)
            }

        case .suppressed:
            if touches.isEmpty { gesture = .idle }

        case .idle:
            break
        }
        return out
    }

    // MARK: - Helpers

    private mutating func startInertia(at t: Double) {
        guard settings.scrollInertia, settings.inertiaTimeConstant > 0 else { return }
        let v = scrollTrack.releaseVelocity(at: t)
        let speed = v.length
        guard speed.isFinite, speed >= settings.inertiaMinSpeed, speed > settings.inertiaStopSpeed,
              settings.inertiaStopSpeed > 0 else { return }
        let duration = settings.inertiaTimeConstant * log(speed / settings.inertiaStopSpeed)
        inertia = Inertia(t0: t, v0: v, gain: scrollGain(speed: speed), tEnd: t + duration)
    }

    private func centroid() -> Vector2 {
        guard !touches.isEmpty else { return .zero }
        var sum = Vector2.zero
        for t in touches.values { sum = sum + t.previous }
        return sum * (1 / Double(touches.count))
    }

    private static func ramp(_ speed: Double, _ low: Double, _ high: Double) -> Double {
        guard speed.isFinite else { return 0 }
        if high > low { return min(max((speed - low) / (high - low), 0), 1) }
        return speed >= high ? 1 : 0
    }

    private func gain(speed: Double) -> Double {
        settings.sensitivity * (1 + settings.acceleration * Self.ramp(speed, settings.accelerationLowSpeed, settings.accelerationHighSpeed))
    }

    /// Multiplier on top of 1/scrollPointsPerUnit.
    func scrollGain(speed: Double) -> Double {
        1 + max(0, settings.scrollAcceleration)
            * Self.ramp(speed, settings.scrollAccelerationLowSpeed, settings.scrollAccelerationHighSpeed)
    }

    private mutating func pointerMove(_ delta: Vector2, speed: Double) -> PointerAction? {
        let scaled = delta * gain(speed: speed) + moveRemainder
        let (dx, rx) = Self.split(scaled.x)
        let (dy, ry) = Self.split(scaled.y)
        moveRemainder = Vector2(rx, ry)
        return dx == 0 && dy == 0 ? nil : .move(dx: dx, dy: dy)
    }

    /// `delta` is finger motion in points (+y down); `gain` multiplies 1/scrollPointsPerUnit.
    private mutating func scrollAction(_ delta: Vector2, gain: Double) -> PointerAction? {
        guard settings.scrollPointsPerUnit > 0 else { return nil }
        let sign: Double = settings.invertScroll ? -1 : 1
        let k = gain / settings.scrollPointsPerUnit * sign
        let wheel = -delta.y * k + scrollRemainder.y
        let pan = delta.x * k + scrollRemainder.x
        let (w, rw) = Self.split(wheel)
        let (p, rp) = Self.split(pan)
        scrollRemainder = Vector2(rp, rw)
        return w == 0 && p == 0 ? nil : .scroll(wheel: w, pan: p)
    }

    /// Integer part toward zero and the remainder; non-finite input gives (0, 0) and huge
    /// values are clamped so the conversion to Int cannot trap.
    private static func split(_ value: Double) -> (Int, Double) {
        guard value.isFinite else { return (0, 0) }
        let clamped = min(max(value, -1_000_000), 1_000_000)
        let whole = clamped.rounded(.towardZero)
        return (Int(whole), clamped - whole)
    }

    /// Press and release `button` unless it is already held.
    private mutating func click(_ button: MouseButtons) -> [PointerAction] {
        let held = gestureButtons.union(externalButtons)
        guard !held.contains(button) else { return [] }
        buttons = held
        return [.buttons(held.union(button)), .buttons(held)]
    }

    private mutating func syncButtons() -> [PointerAction] {
        let held = gestureButtons.union(externalButtons)
        guard held != buttons else { return [] }
        buttons = held
        return [.buttons(held)]
    }
}

/// Velocity of a scrolling finger (or two-finger centroid) from timestamped positions.
struct VelocityTracker: Sendable {
    struct Sample: Sendable { var t: Double; var p: Vector2 }

    /// The scroll gain uses the average over at least this span (smooths 120–240 Hz jitter).
    static let gainSpan = 0.05
    /// The release velocity is the average over this span before the lift…
    static let releaseSpan = 0.05
    /// …and is zero when the last motion is older than this at the lift (finger paused).
    static let releaseMaxAge = 0.05

    private var samples: [Sample] = []

    mutating func reset() { samples.removeAll() }

    mutating func add(_ p: Vector2, at t: Double) {
        guard p.isFinite, t.isFinite else { return }
        if let last = samples.last, t < last.t { return }
        samples.append(Sample(t: t, p: p))
        if let first = samples.first, t - first.t > 0.3 {
            samples.removeAll { t - $0.t > 0.3 }
        }
    }

    /// Average velocity (points/s) from the newest sample back over at least `span` seconds
    /// (or over all samples if they cover less). Zero with fewer than two samples.
    func velocity(span: Double) -> Vector2 {
        guard let last = samples.last, samples.count >= 2 else { return .zero }
        let ref = samples.last { $0.t <= last.t - span } ?? samples[0]
        let dt = last.t - ref.t
        guard dt > 0.004 else { return .zero }
        return (last.p - ref.p) * (1 / dt)
    }

    /// Velocity at a lift at `t`: the average over the last `releaseSpan`, or zero if the
    /// finger has not moved within `releaseMaxAge` before the lift.
    func releaseVelocity(at t: Double) -> Vector2 {
        guard let last = samples.last else { return .zero }
        // Time of the last sample whose position differs from the one before it.
        var lastMotion: Double?
        for i in stride(from: samples.count - 1, to: 0, by: -1) where samples[i].p != samples[i - 1].p {
            lastMotion = samples[i].t
            break
        }
        guard let lm = lastMotion, t - lm <= Self.releaseMaxAge, t >= last.t - 1e-9 else { return .zero }
        let window = samples.filter { $0.t >= t - Self.releaseSpan }
        guard let a = window.first, let b = window.last, b.t - a.t > 0.004 else {
            return velocity(span: Self.releaseSpan)
        }
        return (b.p - a.p) * (1 / (b.t - a.t))
    }
}
