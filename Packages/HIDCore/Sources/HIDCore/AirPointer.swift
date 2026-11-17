// Air mouse for the clicker's pointer button (design §8.5): the phone's rotation rate turns
// into relative pointer motion.
//
// Pure value type: the caller passes the gyro rotation rate, the gravity vector and the
// sample time in (CoreMotion's `CMDeviceMotion.rotationRate`, `.gravity`, `.timestamp`), and
// gets HID counts out. Nothing here reads a sensor or a clock.
//
// Axes and signs (device frame, as CoreMotion reports it): x points to the right edge of the
// screen, y to the top edge, z out of the screen. Rotation rates are right-handed, in rad/s.
// Gravity points towards the ground, in g.
//
// - "Turning" is rotation about the world's vertical axis (up = −gravity). Positive turning
//   swings the phone's top edge to the right (seen from above, clockwise), whatever the roll.
// - "Tilting" is rotation about the horizontal axis perpendicular to where the top edge points
//   (r = normalize(top × up), which points to the user's right). Positive tilting swings the
//   top edge upwards.
// - Output: turning right → +x (pointer right); tilting up → −y (pointer up, HID y grows
//   downwards). Rotation about the pointing direction itself (roll) is ignored.

/// A 3-D vector (device frame).
public struct Vector3: Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }

    public static let zero = Vector3(0, 0, 0)
    public var length: Double { (x * x + y * y + z * z).squareRoot() }
    public var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
    public func dot(_ o: Vector3) -> Double { x * o.x + y * o.y + z * o.z }
    public func cross(_ o: Vector3) -> Vector3 {
        Vector3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x)
    }
    public var normalized: Vector3 { let l = length; return l > 0 ? self * (1 / l) : .zero }

    public static func + (a: Vector3, b: Vector3) -> Vector3 { Vector3(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func - (a: Vector3, b: Vector3) -> Vector3 { Vector3(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static func * (a: Vector3, s: Double) -> Vector3 { Vector3(a.x * s, a.y * s, a.z * s) }
    public static prefix func - (a: Vector3) -> Vector3 { Vector3(-a.x, -a.y, -a.z) }
}

public struct AirPointerSettings: Sendable, Hashable {
    /// HID counts per radian of rotation at sensitivity 1. 1500 counts/rad ≈ 26 counts per
    /// degree: about 35° of turning crosses a 1920-pixel screen before the host's own pointer
    /// acceleration (a guess; the user tunes it with the sensitivity).
    public static let baseGain = 1500.0

    /// HID counts per radian (base gain × sensitivity).
    public var gain = AirPointerSettings.baseGain
    /// Angular speed (rad/s) below which nothing moves (hand tremor, gyro noise). Above it the
    /// dead zone is subtracted, so the speed ramps up from zero without a jump.
    public var deadZone = 0.025
    /// Time constant (s) of the low-pass filter on the angular rates.
    public var smoothingTime = 0.02
    /// Longest step (s) used for one sample (a gap in the samples is not integrated in full).
    public var maxStep = 0.05
    /// Rates are clamped to this (rad/s) per axis.
    public var maxRate = 15.0
    /// Counts per sample are clamped to this per axis (the excess is discarded, not carried).
    public var maxCountsPerSample = 400
    /// Below this length of the top edge's horizontal component (|top × up|, 0…1) the phone
    /// points almost straight up or down; tilting then uses the screen's x axis instead.
    public var minHorizontal = 0.2

    public init() {}

    public init(sensitivity: Double) {
        gain = Self.baseGain * sensitivity
    }
}

/// Rotation samples → pointer counts, with smoothing, dead zone and sub-count carry.
public struct AirPointer: Sendable {
    public var settings: AirPointerSettings

    /// Per-hold statistics (cleared by `reset`).
    public struct Stats: Sendable, Hashable {
        public var samples = 0
        /// Samples that produced motion.
        public var movingSamples = 0
        public var sumDX = 0
        public var sumDY = 0
        public var firstTime: Double?
        public var lastTime: Double?
        /// Largest (turn, tilt) speed seen before the dead zone, rad/s.
        public var maxRate = 0.0
        /// Sum of the raw (turn, tilt) speeds, for the mean.
        public var sumRate = 0.0
        /// Samples without usable gravity (free fall, invalid data).
        public var invalid = 0

        public var duration: Double { (lastTime ?? 0) - (firstTime ?? 0) }
        public var sampleRate: Double { duration > 0 ? Double(samples - 1) / duration : 0 }
        public var meanRate: Double { samples > 0 ? sumRate / Double(samples) : 0 }
    }

    public private(set) var stats = Stats()
    private var lastTime: Double?
    /// Smoothed (turn, tilt), rad/s.
    private var smoothed = Vector2.zero
    /// Sub-count remainder carried to the next sample.
    private var remainder = Vector2.zero

    public init(settings: AirPointerSettings = AirPointerSettings()) {
        self.settings = settings
    }

    /// Forget the motion history (a new hold starts from rest).
    public mutating func reset() {
        lastTime = nil
        smoothed = .zero
        remainder = .zero
        stats = Stats()
    }

    /// Turning and tilting rates (rad/s) for one sample: `turn` > 0 swings the top edge right,
    /// `tilt` > 0 swings it up. Nil when gravity is unusable.
    public static func angularRates(rotationRate w: Vector3, gravity g: Vector3,
                                    minHorizontal: Double = AirPointerSettings().minHorizontal) -> (turn: Double, tilt: Double)? {
        guard w.isFinite, g.isFinite, g.length > 0.1 else { return nil }
        let up = (-g).normalized
        let top = Vector3(0, 1, 0)
        var right = top.cross(up)
        if right.length < minHorizontal {
            // Top edge (nearly) vertical: the screen's x axis, made horizontal, stands in.
            let x = Vector3(1, 0, 0)
            right = x - up * x.dot(up)
            if right.length < 1e-6 { return nil }
        }
        right = right.normalized
        return (turn: -w.dot(up), tilt: w.dot(right))
    }

    /// One sample → counts to send (dx > 0 right, dy > 0 down). The first sample after
    /// `reset` only sets the time base.
    public mutating func update(rotationRate: Vector3, gravity: Vector3, timestamp: Double) -> (dx: Int, dy: Int) {
        stats.samples += 1
        if stats.firstTime == nil { stats.firstTime = timestamp }
        stats.lastTime = timestamp
        let previous = lastTime
        lastTime = timestamp
        guard let rates = Self.angularRates(rotationRate: rotationRate, gravity: gravity, minHorizontal: settings.minHorizontal) else {
            stats.invalid += 1
            return (0, 0)
        }
        let s = settings
        let raw = Vector2(min(max(rates.turn, -s.maxRate), s.maxRate), min(max(rates.tilt, -s.maxRate), s.maxRate))
        stats.maxRate = max(stats.maxRate, raw.length)
        stats.sumRate += raw.length
        guard let previous else { return (0, 0) }
        let dt = min(timestamp - previous, s.maxStep)
        guard dt > 0 else { return (0, 0) }

        // Low-pass (time-constant form, so irregular sample spacing filters the same).
        let alpha = s.smoothingTime > 0 ? dt / (s.smoothingTime + dt) : 1
        smoothed = smoothed + (raw - smoothed) * alpha

        // Soft dead zone on the combined speed.
        let speed = smoothed.length
        guard speed > s.deadZone else {
            remainder = .zero
            return (0, 0)
        }
        let rate = smoothed * ((speed - s.deadZone) / speed)

        // Integrate (turn → +x, tilt up → −y), carry the fraction.
        let exact = Vector2(rate.x * s.gain * dt, -rate.y * s.gain * dt) + remainder
        var dx = Int(exact.x.rounded(.towardZero))
        var dy = Int(exact.y.rounded(.towardZero))
        remainder = Vector2(exact.x - Double(dx), exact.y - Double(dy))
        let cap = s.maxCountsPerSample
        if abs(dx) > cap { dx = dx > 0 ? cap : -cap; remainder.x = 0 }
        if abs(dy) > cap { dy = dy > 0 ? cap : -cap; remainder.y = 0 }
        if dx != 0 || dy != 0 {
            stats.movingSamples += 1
            stats.sumDX += dx
            stats.sumDY += dy
        }
        return (dx, dy)
    }
}
