// Pending-send queue between input logic and the BLE transport (design §8.1, §8.2).

/// A report ready to send, tagged with its kind so the transport can pick the
/// characteristic.
public enum OutgoingReport: Sendable, Hashable {
    case mouse(MouseReport)
    case keyboard(KeyboardReport)
    case consumer(ConsumerReport)

    public var kind: ReportKind {
        switch self {
        case .mouse: .mouse
        case .keyboard: .keyboard
        case .consumer: .consumer
        }
    }

    /// The characteristic value (no report ID).
    public var bytes: [UInt8] {
        switch self {
        case .mouse(let r): r.bytes
        case .keyboard(let r): r.bytes
        case .consumer(let r): r.bytes
        }
    }
}

/// FIFO of reports waiting for the transport.
///
/// - One queue for all report kinds, so the order between them is kept (e.g. Command down,
///   then a click, then Command up).
/// - Relative motion (pointer, wheel, pan) coalesces into the newest queue entry when that
///   entry is itself pending motion. A button transition or any keyboard/consumer report
///   ends the coalescing run, so motion never moves across a transition.
/// - Each motion entry carries the button state in effect when it was queued (so motion
///   during a drag is sent with the button down).
/// - When a coalesced sum exceeds one report's range, `next()` sends the largest
///   in-range part and keeps the rest at the head; all parts carry the same buttons.
/// - Button transitions, keyboard and consumer reports are never merged or dropped.
///
/// Transport usage: call `next()` when ready; if the send fails (`updateValue` returned
/// false), call `pushBack(_:)` with the report and stop until the stack is ready again.
///
/// Paced transport usage: call `next(now:)` instead, and `didSend(_:at:)` after every
/// report the stack accepted. When `next(now:)` returns nil while the queue is not empty,
/// `nextSendTime` says when to try again. See `ReportPacing`.
public struct ReportQueue: Sendable {
    private enum Entry: Sendable, Hashable {
        /// Coalescable motion with unbounded sums.
        case motion(buttons: MouseButtons, dx: Int, dy: Int, wheel: Int, pan: Int)
        /// A report sent exactly as is.
        case fixed(OutgoingReport)
    }

    private var entries: [Entry] = []
    private var head = 0   // index of the first live entry (amortised O(1) pops)

    /// Mouse button state after everything queued so far (initially none).
    public private(set) var mouseButtons: MouseButtons = []

    /// Minimum spacing of state changes, per report kind (kinds not listed are not paced).
    /// Only `next(now:)` applies it.
    public var pacing: [ReportKind: ReportPacing]

    /// Last state change handed to the transport, per kind (from `didSend`).
    private var lastChange: [ReportKind: (state: ReportState, time: Double, wasPress: Bool)] = [:]
    /// Last state sent per kind (also for reports that did not change it).
    private var lastState: [ReportKind: ReportState] = [:]

    public init(pacing: [ReportKind: ReportPacing] = [:]) {
        self.pacing = pacing
    }

    public var isEmpty: Bool { head == entries.count }
    /// Number of queue entries (a coalesced motion run counts as one, even if it later
    /// splits into several reports).
    public var count: Int { entries.count - head }

    // MARK: - Producers

    /// Add relative motion; coalesces with pending motion at the tail.
    public mutating func enqueueMotion(dx: Int = 0, dy: Int = 0, wheel: Int = 0, pan: Int = 0) {
        guard dx != 0 || dy != 0 || wheel != 0 || pan != 0 else { return }
        if head < entries.count, case .motion(let b, let x, let y, let w, let p) = entries[entries.count - 1],
           b == mouseButtons {
            entries[entries.count - 1] = .motion(buttons: b, dx: Self.add(x, dx), dy: Self.add(y, dy),
                                                 wheel: Self.add(w, wheel), pan: Self.add(p, pan))
        } else {
            entries.append(.motion(buttons: mouseButtons, dx: dx, dy: dy, wheel: wheel, pan: pan))
        }
    }

    /// Set the complete mouse button state. A change queues a transition report (no
    /// motion); setting the current state again does nothing.
    public mutating func setMouseButtons(_ buttons: MouseButtons) {
        guard buttons != mouseButtons else { return }
        mouseButtons = buttons
        entries.append(.fixed(.mouse(MouseReport(buttons: buttons))))
    }

    public mutating func enqueue(_ report: KeyboardReport) {
        entries.append(.fixed(.keyboard(report)))
    }

    public mutating func enqueue(_ report: ConsumerReport) {
        entries.append(.fixed(.consumer(report)))
    }

    public mutating func enqueue(_ reports: [KeyboardReport]) {
        for r in reports { enqueue(r) }
    }

    /// Queue an engine action.
    public mutating func enqueue(_ action: PointerAction) {
        switch action {
        case .buttons(let b): setMouseButtons(b)
        case .move(let dx, let dy): enqueueMotion(dx: dx, dy: dy)
        case .scroll(let wheel, let pan): enqueueMotion(wheel: wheel, pan: pan)
        }
    }

    public mutating func enqueue(_ actions: [PointerAction]) {
        for a in actions { enqueue(a) }
    }

    // MARK: - Transport

    /// The next report to send, or nil when nothing is pending.
    public mutating func next() -> OutgoingReport? {
        while head < entries.count {
            switch entries[head] {
            case .fixed(let report):
                popHead()
                return report
            case .motion(let b, let dx, let dy, let w, let p):
                let report = MouseReport(buttons: b, x: dx, y: dy, wheel: w, pan: p)
                let rest = (dx - report.x, dy - report.y, w - report.wheel, p - report.pan)
                if rest == (0, 0, 0, 0) {
                    popHead()
                } else {
                    entries[head] = .motion(buttons: b, dx: rest.0, dy: rest.1, wheel: rest.2, pan: rest.3)
                }
                if report.hasNoMotion { continue }   // e.g. +5 then -5 coalesced to nothing
                return .mouse(report)
            }
        }
        return nil
    }

    /// Like `next()`, but holds the queue while the head report would change its kind's
    /// state sooner than `pacing` allows after the previous change (see `ReportPacing`).
    /// Everything behind a held head waits too, so the order between kinds is kept; motion
    /// queued meanwhile keeps coalescing.
    public mutating func next(now: Double) -> OutgoingReport? {
        if let due = nextSendTime, now < due { return nil }
        return next()
    }

    /// When the head report may be sent, or nil if it may be sent now (or nothing is
    /// pending). Only meaningful with `next(now:)`.
    public var nextSendTime: Double? {
        guard let report = peek() else { return nil }
        let kind = report.kind
        guard let p = pacing[kind], let last = lastChange[kind] else { return nil }
        let state = ReportState(report)
        guard state != lastState[kind] else { return nil }   // no change: never held
        let due = last.time + (last.wasPress ? p.minPress : p.minRelease)
        return due
    }

    /// Record that the transport handed `report` to the stack at `time` (seconds, any
    /// monotonic clock). Only reports that change their kind's state start a pacing interval.
    public mutating func didSend(_ report: OutgoingReport, at time: Double) {
        let kind = report.kind
        let state = ReportState(report)
        let old = lastState[kind] ?? .idle(kind)
        lastState[kind] = state
        guard state != old else { return }
        lastChange[kind] = (state, time, state.presses(comparedTo: old))
    }

    /// Kinds whose last report handed to the transport (`didSend`) left something pressed
    /// (keys, modifiers, buttons, a consumer usage). Used before dropping the queue on a host
    /// change, to release at that host whatever it still has down.
    public var pressedKinds: Set<ReportKind> {
        Set(lastState.filter { !$0.value.pressed.isEmpty }.map(\.key))
    }

    /// The report `next()` would return, without removing it.
    private func peek() -> OutgoingReport? {
        var i = head
        while i < entries.count {
            switch entries[i] {
            case .fixed(let report):
                return report
            case .motion(let b, let dx, let dy, let w, let p):
                let report = MouseReport(buttons: b, x: dx, y: dy, wheel: w, pan: p)
                if report.hasNoMotion { i += 1; continue }
                return .mouse(report)
            }
        }
        return nil
    }

    /// Put back a report that could not be sent, so it goes out first next time.
    ///
    /// A mouse report without motion (a button transition) always goes back as is. A mouse
    /// report with motion merges into pending motion at the head when the buttons match,
    /// or goes back as a coalescable motion entry, so motion queued after it while the
    /// transport is busy can still merge into it.
    public mutating func pushBack(_ report: OutgoingReport) {
        if case .mouse(let r) = report, !r.hasNoMotion {
            if head < entries.count, case .motion(let b, let dx, let dy, let w, let p) = entries[head], b == r.buttons {
                entries[head] = .motion(buttons: b, dx: Self.add(dx, r.x), dy: Self.add(dy, r.y),
                                        wheel: Self.add(w, r.wheel), pan: Self.add(p, r.pan))
                return
            }
            insertAtHead(.motion(buttons: r.buttons, dx: r.x, dy: r.y, wheel: r.wheel, pan: r.pan))
            return
        }
        insertAtHead(.fixed(report))
    }

    private mutating func insertAtHead(_ entry: Entry) {
        if head > 0 {
            head -= 1
            entries[head] = entry
        } else {
            entries.insert(entry, at: 0)
        }
    }

    /// Drop everything pending and forget the button state (e.g. after disconnecting).
    /// Pacing history is forgotten too: the next host starts from idle.
    public mutating func removeAll() {
        entries.removeAll()
        head = 0
        mouseButtons = []
        lastChange = [:]
        lastState = [:]
    }

    // MARK: - Helpers

    private mutating func popHead() {
        head += 1
        if head == entries.count {
            entries.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 64, head * 2 >= entries.count {
            entries.removeFirst(head)
            head = 0
        }
    }

    private static func add(_ a: Int, _ b: Int) -> Int {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? (b > 0 ? Int.max : Int.min) : sum
    }
}

/// Minimum spacing between state changes of one report kind, so that a press and its
/// release (or a release and the next press) are never handed to the stack so close
/// together that they share a connection event. A host that samples key state instead of
/// processing every report could otherwise miss a key.
///
/// The state is the set of pressed keys and modifiers (keyboard), the usage (consumer) or
/// the buttons (mouse); motion is not state. A report that adds anything to the state is a
/// press: the next change waits `minPress`. A report that only removes is a release: the
/// next change waits `minRelease`. Reports that do not change the state are never held.
public struct ReportPacing: Sendable, Hashable {
    /// Seconds a press stays in effect before the next change of the same kind.
    public var minPress: Double
    /// Seconds a release stays in effect before the next change of the same kind.
    public var minRelease: Double

    public init(minPress: Double, minRelease: Double) {
        self.minPress = minPress
        self.minRelease = minRelease
    }

    /// The app's default for keyboard and consumer reports: a press lasts at least one
    /// connection interval of this Mac (about 30 ms, design §9) plus margin; a release
    /// lasts at least half of that.
    public static let keys = ReportPacing(minPress: 0.035, minRelease: 0.015)
}

/// The pressed state a report expresses (motion ignored).
struct ReportState: Hashable {
    var kind: ReportKind
    var pressed: Set<UInt16>

    static func idle(_ kind: ReportKind) -> ReportState { ReportState(kind: kind, pressed: []) }

    init(kind: ReportKind, pressed: Set<UInt16>) {
        self.kind = kind
        self.pressed = pressed
    }

    init(_ report: OutgoingReport) {
        kind = report.kind
        switch report {
        case .mouse(let r):
            pressed = Set((0..<5).filter { r.buttons.rawValue & (1 << $0) != 0 }.map { UInt16($0) })
        case .keyboard(let r):
            var s = Set(r.modifiers.usages.map { UInt16($0.rawValue) })
            if r.isRollOver { s.insert(UInt16(KeyUsage.errorRollOver.rawValue)) }
            for k in r.keys { s.insert(UInt16(k.rawValue)) }
            pressed = s
        case .consumer(let r):
            pressed = r.usage == .none ? [] : [r.usage.rawValue]
        }
    }

    /// True if this state presses something `old` did not.
    func presses(comparedTo old: ReportState) -> Bool {
        !pressed.subtracting(old.pressed).isEmpty
    }
}
