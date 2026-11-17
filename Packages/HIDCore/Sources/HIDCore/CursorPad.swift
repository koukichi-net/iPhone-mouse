// The iOS keyboard's cursor gesture (long-press the space bar / 空白, then slide) as arrow
// keys for the host (利用者の要望 2026-11-18: 「下にスワイプしたら下矢印キー」).
//
// The text field keeps invisible pad text around the caret — a grid of `rows` lines of
// `columns` no-break spaces in a monospaced font, so one column is one character and one row
// is one line — and the caret sits at the centre. The gesture moves the caret inside the pad;
// the caret's move in columns / rows becomes Left/Right / Up/Down presses, and the caret is put
// back at the centre ("recentred") when the gesture ends or goes quiet.
//
// Pure logic only: the pad geometry (`CursorPadGrid`), caret move → arrow steps with the
// sensitivity (`CursorPadTracker`), and the bounded per-direction backlog (`ArrowStepQueue`).
// The UIKit glue (which selection changes count, when to recentre) is the app's.

/// An arrow key.
public enum ArrowDirection: String, Sendable, Hashable, CaseIterable {
    case left, right, up, down

    public var usage: KeyUsage {
        switch self {
        case .left: .leftArrow
        case .right: .rightArrow
        case .up: .upArrow
        case .down: .downArrow
        }
    }

    public var opposite: ArrowDirection {
        switch self {
        case .left: .right
        case .right: .left
        case .up: .down
        case .down: .up
        }
    }

    /// For log lines and the on-screen echo.
    public var symbol: String {
        switch self {
        case .left: "←"
        case .right: "→"
        case .up: "↑"
        case .down: "↓"
        }
    }
}

/// `count` presses of one arrow key.
public struct ArrowSteps: Sendable, Hashable, CustomStringConvertible {
    public var direction: ArrowDirection
    public var count: Int

    public init(_ direction: ArrowDirection, _ count: Int) {
        self.direction = direction
        self.count = count
    }

    /// `↓×2`.
    public var description: String { "\(direction.symbol)×\(count)" }
}

extension Array where Element == ArrowSteps {
    /// `→×3 ↓×1`, or `none`.
    public var summary: String { isEmpty ? "none" : map(\.description).joined(separator: " ") }
}

/// A caret place in the pad: `row` 0..<rows, `column` 0...columns (columns = end of the line).
public struct PadPosition: Sendable, Hashable, CustomStringConvertible {
    public var row: Int
    public var column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }

    /// `r7c16`.
    public var description: String { "r\(row)c\(column)" }
}

/// The pad text and offset ↔ (row, column) for an empty field (no user content).
///
/// Text: `rows` lines of `columns` U+00A0, joined by "\n" (no trailing newline). Every
/// character is one UTF-16 unit, so offsets are both character and UTF-16 offsets. The caret
/// home is the middle of the middle line; user content is inserted there, so the pad before the
/// caret (`prefixLength`) and after it (`suffixLength`) stay fixed while the field has content.
public struct CursorPadGrid: Sendable, Hashable {
    public static let padCharacter: Character = "\u{00A0}"

    public let rows: Int
    public let columns: Int

    /// `rows` and `columns` are made odd and at least 3 (so there is a middle).
    public init(rows: Int, columns: Int) {
        let r = max(3, rows), c = max(3, columns)
        self.rows = r % 2 == 1 ? r : r + 1
        self.columns = c % 2 == 1 ? c : c + 1
    }

    public var center: PadPosition { PadPosition(row: rows / 2, column: columns / 2) }
    /// UTF-16 units per line including its "\n".
    public var lineLength: Int { columns + 1 }
    /// UTF-16 length of the whole pad.
    public var length: Int { rows * lineLength - 1 }
    public var centerOffset: Int { offset(of: center) }
    public var prefixLength: Int { centerOffset }
    public var suffixLength: Int { length - centerOffset }

    public var text: String {
        let line = String(repeating: Self.padCharacter, count: columns)
        return Array(repeating: line, count: rows).joined(separator: "\n")
    }
    /// The pad before the caret home.
    public var prefix: String { String(text.prefix(prefixLength)) }
    /// The pad after the caret home.
    public var suffix: String { String(text.suffix(suffixLength)) }

    /// The caret place for an offset into the pad text (nil when outside it).
    public func position(ofOffset o: Int) -> PadPosition? {
        guard o >= 0, o <= length else { return nil }
        return PadPosition(row: o / lineLength, column: o % lineLength)
    }

    /// The offset for a caret place (clamped into the pad).
    public func offset(of p: PadPosition) -> Int {
        let r = min(max(p.row, 0), rows - 1)
        let c = min(max(p.column, 0), columns)
        return r * lineLength + c
    }

    /// True when `p` is within `columnMargin` columns of the left/right end or `rowMargin` rows
    /// of the first/last line.
    public func isNearEdge(_ p: PadPosition, columnMargin: Int, rowMargin: Int) -> Bool {
        p.column < columnMargin || p.column > columns - columnMargin
            || p.row < rowMargin || p.row > rows - 1 - rowMargin
    }
}

/// Turns caret moves inside the pad into arrow steps.
///
/// - Δcolumns → Left/Right, Δrows → Up/Down (horizontal first). `columnsPerStep` /
///   `rowsPerStep` (≥ 1) are the sensitivity; the remainder carries over to the next move of
///   the same gesture (`gestureEnded` drops it).
/// - The caller tells it every accepted caret move (`caretMoved`) and every recentre
///   (`didRecentre`). After a recentre during a gesture, the next move is checked for a
///   "snap-back": UIKit may place the floating cursor by the finger's absolute point, so the
///   caret jumps back next to where it was before the recentre. That jump is not the finger's
///   move: it re-baselines without steps, and edge recentres are off for the rest of the
///   gesture (`midGestureRecentre` false).
public struct CursorPadTracker: Sendable {
    public var grid: CursorPadGrid
    public var columnsPerStep: Int { didSet { columnsPerStep = max(1, columnsPerStep) } }
    public var rowsPerStep: Int { didSet { rowsPerStep = max(1, rowsPerStep) } }
    /// Recentre when the caret comes within this many columns / rows of the pad's edge.
    public var edgeColumns = 3
    public var edgeRows = 2

    /// Where the caret is assumed to be (the last accepted place; the centre after a recentre).
    public private(set) var baseline: PadPosition
    /// Edge recentres allowed during the current gesture (false after a snap-back).
    public private(set) var midGestureRecentre = true
    private var residueColumns = 0
    private var residueRows = 0
    /// The place before the last recentre, while the next move is checked for a snap-back.
    private var snapCheck: PadPosition?

    public enum Outcome: Sendable, Hashable {
        /// The offset is not a place in the pad.
        case outside
        /// Same place as the baseline.
        case unchanged
        /// The caret jumped back next to where it was before a recentre (see above).
        case snapBack(from: PadPosition, to: PadPosition)
        /// A move: the steps to send (may be empty while the sensitivity's remainder builds
        /// up) and whether to recentre now (near the edge, and allowed).
        case moved(from: PadPosition, to: PadPosition, steps: [ArrowSteps], recentre: Bool, afterRecentre: Bool)
    }

    public init(grid: CursorPadGrid, columnsPerStep: Int = 1, rowsPerStep: Int = 1) {
        self.grid = grid
        self.columnsPerStep = max(1, columnsPerStep)
        self.rowsPerStep = max(1, rowsPerStep)
        baseline = grid.center
    }

    /// The caret is at the centre again (pad rebuilt, field cleared); forgets the gesture.
    public mutating func reset() {
        baseline = grid.center
        snapCheck = nil
        gestureEnded()
    }

    /// Accept the caret place without steps (moves caused by typing or by the app itself).
    public mutating func rebase(toOffset o: Int) {
        if let p = grid.position(ofOffset: o) { baseline = p }
    }

    /// The gesture is over (floating cursor ended, or quiet): drop the remainder and allow
    /// edge recentres again.
    public mutating func gestureEnded() {
        residueColumns = 0
        residueRows = 0
        midGestureRecentre = true
    }

    /// The app put the caret back at the centre. `midGesture`: the gesture may still be going
    /// on (the next move is checked for a snap-back).
    public mutating func didRecentre(midGesture: Bool) {
        snapCheck = midGesture && baseline != grid.center ? baseline : nil
        baseline = grid.center
    }

    /// A caret move that is not typing and not the app's own (the gesture).
    public mutating func caretMoved(toOffset o: Int) -> Outcome {
        guard let p = grid.position(ofOffset: o) else { return .outside }
        let check = snapCheck
        snapCheck = nil
        let from = baseline
        guard p != from else { return .unchanged }
        if let s = check, abs(p.column - s.column) <= 3, abs(p.row - s.row) <= 1,
           abs(p.column - grid.center.column) > 3 || abs(p.row - grid.center.row) > 1 {
            baseline = p
            midGestureRecentre = false
            residueColumns = 0
            residueRows = 0
            return .snapBack(from: s, to: p)
        }
        baseline = p
        var steps: [ArrowSteps] = []
        residueColumns += p.column - from.column
        let h = residueColumns / columnsPerStep   // truncates toward zero: the remainder keeps its sign
        residueColumns -= h * columnsPerStep
        if h != 0 { steps.append(ArrowSteps(h > 0 ? .right : .left, abs(h))) }
        residueRows += p.row - from.row
        let v = residueRows / rowsPerStep
        residueRows -= v * rowsPerStep
        if v != 0 { steps.append(ArrowSteps(v > 0 ? .down : .up, abs(v))) }
        let near = grid.isNearEdge(p, columnMargin: edgeColumns, rowMargin: edgeRows)
        return .moved(from: from, to: p, steps: steps, recentre: near && midGestureRecentre, afterRecentre: check != nil)
    }
}

/// Arrow presses waiting for the keyboard pacing (~20 keys/s), bounded so a fast swipe does
/// not leave a backlog that keeps moving the host's cursor after the finger stopped.
///
/// - A new step first cancels a pending step of the opposite direction (the newest one).
/// - At most `cap` pending steps per direction; the excess is dropped (and counted).
/// - Steps go out in the order they were added.
public struct ArrowStepQueue: Sendable, Hashable {
    public static let defaultCap = 6

    public var cap: Int
    public private(set) var pending: [ArrowDirection] = []

    public struct AddResult: Sendable, Hashable {
        public var added = 0
        public var cancelled = 0
        public var dropped = 0

        public init(added: Int = 0, cancelled: Int = 0, dropped: Int = 0) {
            self.added = added
            self.cancelled = cancelled
            self.dropped = dropped
        }
    }

    public init(cap: Int = Self.defaultCap) {
        self.cap = max(1, cap)
    }

    public var isEmpty: Bool { pending.isEmpty }

    public func count(_ d: ArrowDirection) -> Int { pending.filter { $0 == d }.count }

    @discardableResult
    public mutating func add(_ steps: ArrowSteps) -> AddResult {
        var r = AddResult()
        for _ in 0..<max(0, steps.count) {
            if let i = pending.lastIndex(of: steps.direction.opposite) {
                pending.remove(at: i)
                r.cancelled += 1
            } else if count(steps.direction) < cap {
                pending.append(steps.direction)
                r.added += 1
            } else {
                r.dropped += 1
            }
        }
        return r
    }

    /// The next step to press.
    public mutating func next() -> ArrowDirection? {
        pending.isEmpty ? nil : pending.removeFirst()
    }

    /// Drops everything pending; returns how many.
    @discardableResult
    public mutating func removeAll() -> Int {
        defer { pending.removeAll() }
        return pending.count
    }

    /// Pending steps grouped in runs, e.g. `↓×2 →×1` (or `none`).
    public var summary: String {
        var runs: [ArrowSteps] = []
        for d in pending {
            if let last = runs.last, last.direction == d { runs[runs.count - 1].count += 1 } else { runs.append(ArrowSteps(d, 1)) }
        }
        return runs.summary
    }
}

/// Auto-repeat while the caret is pinned on an edge of the pad during the cursor gesture
/// (利用者の報告 2026-11-18: 「端まで行くとそれ以上カーソルが動かせない」).
///
/// The floating cursor is clamped to the pad, so on an edge row / column the finger can push
/// on but the caret cannot move. Like a pointer pushed against a screen edge: after
/// `initialDelay` on the edge, one step in that direction every `interval`, every
/// `fastInterval` once the repeat has run for `fastAfter`. Both directions in a corner. The
/// caller reports the caret place while the gesture is active (`update`; nil = no gesture,
/// marked text, etc.: everything stops) and asks for due steps (`tick`), passing whether the
/// direction has room in its queue: a full queue skips that tick silently.
public struct EdgeRepeater: Sendable {
    public static let defaultInitialDelay = 0.3
    public static let defaultInterval = 0.1
    public static let defaultFastInterval = 0.06
    public static let defaultFastAfter = 1.5

    public var initialDelay: Double
    public var interval: Double
    public var fastInterval: Double
    public var fastAfter: Double

    public struct Pin: Sendable, Hashable {
        /// When the caret arrived on this edge.
        public var since: Double
        public var nextDue: Double
        /// Steps emitted so far.
        public var steps: Int
    }

    public enum Change: Sendable, Hashable {
        case start(ArrowDirection)
        case stop(ArrowDirection, steps: Int, pinned: Double)
    }

    public private(set) var pins: [ArrowDirection: Pin] = [:]

    public init(initialDelay: Double = Self.defaultInitialDelay, interval: Double = Self.defaultInterval,
                fastInterval: Double = Self.defaultFastInterval, fastAfter: Double = Self.defaultFastAfter) {
        self.initialDelay = initialDelay
        self.interval = interval
        self.fastInterval = fastInterval
        self.fastAfter = fastAfter
    }

    /// The pad edges `p` sits on, as the directions the finger pushes towards (← → ↑ ↓ order).
    public static func edges(of p: PadPosition, in grid: CursorPadGrid) -> [ArrowDirection] {
        var d: [ArrowDirection] = []
        if p.column <= 0 { d.append(.left) }
        if p.column >= grid.columns { d.append(.right) }
        if p.row <= 0 { d.append(.up) }
        if p.row >= grid.rows - 1 { d.append(.down) }
        return d
    }

    public var isActive: Bool { !pins.isEmpty }

    /// The earliest time a step is due (nil: nothing pinned).
    public var nextDueTime: Double? { pins.values.map(\.nextDue).min() }

    /// The caret is at `p` during an active gesture at `t` (nil: no active gesture / not
    /// applicable). Starts edges the caret arrived on; stops the ones it left.
    public mutating func update(position p: PadPosition?, grid: CursorPadGrid, at t: Double) -> [Change] {
        let now = Set(p.map { Self.edges(of: $0, in: grid) } ?? [])
        var out: [Change] = []
        for d in ArrowDirection.allCases {
            if let pin = pins[d], !now.contains(d) {
                pins[d] = nil
                out.append(.stop(d, steps: pin.steps, pinned: t - pin.since))
            } else if pins[d] == nil, now.contains(d) {
                pins[d] = Pin(since: t, nextDue: t + initialDelay, steps: 0)
                out.append(.start(d))
            }
        }
        return out
    }

    /// Stops everything (gesture end, app inactive, host change, …).
    public mutating func stopAll(at t: Double) -> [Change] {
        update(position: nil, grid: CursorPadGrid(rows: 3, columns: 3), at: t)
    }

    /// The steps due at `t` (at most one per direction per call; a late call does not catch
    /// up). `room(d)` false: no step for `d` this time (its queue is full), the cadence goes on.
    public mutating func tick(at t: Double, room: (ArrowDirection) -> Bool) -> [ArrowDirection] {
        var out: [ArrowDirection] = []
        for d in ArrowDirection.allCases {
            guard var pin = pins[d], t + 1e-9 >= pin.nextDue else { continue }
            if room(d) {
                out.append(d)
                pin.steps += 1
            }
            let iv = t - pin.since - initialDelay >= fastAfter - 1e-9 ? fastInterval : interval
            pin.nextDue += iv
            if pin.nextDue <= t { pin.nextDue = t + iv }
            pins[d] = pin
        }
        return out
    }
}
