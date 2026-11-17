import Testing
@testable import HIDCore

@Suite("Cursor pad (space-bar cursor gesture → arrow keys)")
struct CursorPadTests {
    // MARK: Grid

    @Test func gridTextAndGeometry() {
        let g = CursorPadGrid(rows: 5, columns: 7)
        #expect(g.text == Array(repeating: String(repeating: "\u{00A0}", count: 7), count: 5).joined(separator: "\n"))
        #expect(g.text.utf16.count == g.length)
        #expect(g.length == 5 * 8 - 1)
        #expect(g.center == PadPosition(row: 2, column: 3))
        #expect(g.centerOffset == 2 * 8 + 3)
        #expect(g.prefix + g.suffix == g.text)
        #expect(g.prefix.utf16.count == g.prefixLength)
        #expect(g.suffix.utf16.count == g.suffixLength)
        #expect(!g.text.contains(" "))   // no breaking space: the pad never wraps or triggers ". "
    }

    @Test func gridDimensionsAreOddAndAtLeastThree() {
        let g = CursorPadGrid(rows: 4, columns: 1)
        #expect(g.rows == 5)
        #expect(g.columns == 3)
    }

    @Test func gridOffsetRoundTrip() {
        let g = CursorPadGrid(rows: 15, columns: 31)
        for o in 0...g.length {
            let p = g.position(ofOffset: o)!
            #expect(g.offset(of: p) == o)
            #expect(p.column <= g.columns)
        }
        #expect(g.position(ofOffset: -1) == nil)
        #expect(g.position(ofOffset: g.length + 1) == nil)
        // End of a line is the place before its "\n"; the next offset starts the next line.
        #expect(g.position(ofOffset: 31) == PadPosition(row: 0, column: 31))
        #expect(g.position(ofOffset: 32) == PadPosition(row: 1, column: 0))
        #expect(g.offset(of: PadPosition(row: 99, column: -4)) == 14 * 32)
    }

    @Test func gridEdge() {
        let g = CursorPadGrid(rows: 15, columns: 31)
        #expect(!g.isNearEdge(g.center, columnMargin: 3, rowMargin: 2))
        #expect(g.isNearEdge(PadPosition(row: 7, column: 2), columnMargin: 3, rowMargin: 2))
        #expect(!g.isNearEdge(PadPosition(row: 7, column: 3), columnMargin: 3, rowMargin: 2))
        #expect(g.isNearEdge(PadPosition(row: 7, column: 29), columnMargin: 3, rowMargin: 2))
        #expect(!g.isNearEdge(PadPosition(row: 7, column: 28), columnMargin: 3, rowMargin: 2))
        #expect(g.isNearEdge(PadPosition(row: 1, column: 15), columnMargin: 3, rowMargin: 2))
        #expect(g.isNearEdge(PadPosition(row: 13, column: 15), columnMargin: 3, rowMargin: 2))
        #expect(!g.isNearEdge(PadPosition(row: 12, column: 15), columnMargin: 3, rowMargin: 2))
    }

    // MARK: Tracker

    private func offset(_ t: CursorPadTracker, dr: Int, dc: Int) -> Int {
        t.grid.offset(of: PadPosition(row: t.grid.center.row + dr, column: t.grid.center.column + dc))
    }

    private func steps(_ o: CursorPadTracker.Outcome) -> [ArrowSteps]? {
        if case .moved(_, _, let s, _, _) = o { return s }
        return nil
    }

    @Test func downTwoRowsIsDownTwice() {
        var t = CursorPadTracker(grid: CursorPadGrid(rows: 15, columns: 31))
        let o = t.caretMoved(toOffset: offset(t, dr: 2, dc: 0))
        #expect(steps(o) == [ArrowSteps(.down, 2)])
        #expect(steps(o)?.summary == "↓×2")
        #expect(t.baseline == PadPosition(row: 9, column: 15))
    }

    @Test func columnsAndRowsHorizontalFirst() {
        var t = CursorPadTracker(grid: CursorPadGrid(rows: 15, columns: 31))
        #expect(steps(t.caretMoved(toOffset: offset(t, dr: -1, dc: -3))) == [ArrowSteps(.left, 3), ArrowSteps(.up, 1)])
        #expect(steps(t.caretMoved(toOffset: offset(t, dr: -1, dc: 2))) == [ArrowSteps(.right, 5)])
    }

    @Test func movesAreRelativeToTheLastPlace() {
        var t = CursorPadTracker(grid: CursorPadGrid(rows: 15, columns: 31))
        #expect(steps(t.caretMoved(toOffset: offset(t, dr: 0, dc: 1))) == [ArrowSteps(.right, 1)])
        #expect(steps(t.caretMoved(toOffset: offset(t, dr: 0, dc: 2))) == [ArrowSteps(.right, 1)])
        #expect(steps(t.caretMoved(toOffset: offset(t, dr: 0, dc: 0))) == [ArrowSteps(.left, 2)])
        #expect(t.caretMoved(toOffset: offset(t, dr: 0, dc: 0)) == .unchanged)
        #expect(t.caretMoved(toOffset: -5) == .outside)
    }

    @Test func halfSensitivityCarriesTheRemainder() {
        var t = CursorPadTracker(grid: CursorPadGrid(rows: 15, columns: 31), columnsPerStep: 2)
        #expect(steps(t.caretMoved(toOffset: offset(t, dr: 0, dc: 1))) == [])
        #expect(steps(t.caretMoved(toOffset: offset(t, dr: 0, dc: 2))) == [ArrowSteps(.right, 1)])
        #expect(steps(t.caretMoved(toOffset: offset(t, dr: 0, dc: 5))) == [ArrowSteps(.right, 1)])   // 3 more: 1 step, 1 left over
        #expect(steps(t.caretMoved(toOffset: offset(t, dr: 0, dc: 4))) == [])   // back 1: remainder 0
        #expect(steps(t.caretMoved(toOffset: offset(t, dr: 0, dc: 1))) == [ArrowSteps(.left, 1)])   // back 3: 1 step, -1 left over
        #expect(steps(t.caretMoved(toOffset: offset(t, dr: 0, dc: 0))) == [ArrowSteps(.left, 1)])
        // Rows stay 1:1.
        #expect(steps(t.caretMoved(toOffset: offset(t, dr: 1, dc: 0))) == [ArrowSteps(.down, 1)])
    }

    @Test func gestureEndDropsTheRemainder() {
        var t = CursorPadTracker(grid: CursorPadGrid(rows: 15, columns: 31), columnsPerStep: 2)
        #expect(steps(t.caretMoved(toOffset: offset(t, dr: 0, dc: 1))) == [])
        t.gestureEnded()
        t.didRecentre(midGesture: false)
        #expect(steps(t.caretMoved(toOffset: offset(t, dr: 0, dc: 1))) == [])
        #expect(steps(t.caretMoved(toOffset: offset(t, dr: 0, dc: 2))) == [ArrowSteps(.right, 1)])
    }

    @Test func nearTheEdgeAsksForARecentre() {
        var t = CursorPadTracker(grid: CursorPadGrid(rows: 15, columns: 31))
        if case .moved(_, _, let s, let recentre, _) = t.caretMoved(toOffset: offset(t, dr: 0, dc: -13)) {
            #expect(s == [ArrowSteps(.left, 13)])
            #expect(recentre)   // column 2 < 3
        } else { Issue.record("expected a move") }
        if case .moved(_, _, _, let recentre, _) = t.caretMoved(toOffset: offset(t, dr: 0, dc: -12)) {
            #expect(!recentre)
        } else { Issue.record("expected a move") }
        if case .moved(_, _, _, let recentre, _) = t.caretMoved(toOffset: offset(t, dr: 5, dc: -12)) {
            #expect(!recentre)   // row 12: not near (rows 13 and 14 are)
        } else { Issue.record("expected a move") }
        if case .moved(_, _, let s, let recentre, _) = t.caretMoved(toOffset: offset(t, dr: 6, dc: -12)) {
            #expect(s == [ArrowSteps(.down, 1)])
            #expect(recentre)
        } else { Issue.record("expected a move") }
    }

    @Test func recentreRebaselinesAtTheCentre() {
        var t = CursorPadTracker(grid: CursorPadGrid(rows: 15, columns: 31))
        _ = t.caretMoved(toOffset: offset(t, dr: 3, dc: 0))
        t.gestureEnded()
        t.didRecentre(midGesture: false)
        #expect(t.baseline == t.grid.center)
        // A new gesture from the centre: relative to the centre.
        #expect(steps(t.caretMoved(toOffset: offset(t, dr: 1, dc: 0))) == [ArrowSteps(.down, 1)])
    }

    @Test func snapBackAfterAMidGestureRecentreSendsNothingAndStopsEdgeRecentres() {
        var t = CursorPadTracker(grid: CursorPadGrid(rows: 15, columns: 31))
        _ = t.caretMoved(toOffset: offset(t, dr: 0, dc: -13))   // column 2: near the edge
        t.didRecentre(midGesture: true)                                          // app recentres mid-gesture
        // UIKit puts the caret back by the finger's absolute point: next to column 2.
        let o = t.caretMoved(toOffset: offset(t, dr: 0, dc: -14))
        #expect(o == .snapBack(from: PadPosition(row: 7, column: 2), to: PadPosition(row: 7, column: 1)))
        #expect(!t.midGestureRecentre)
        // Further moves are relative again; no more edge recentres in this gesture.
        if case .moved(_, _, let s, let recentre, _) = t.caretMoved(toOffset: offset(t, dr: 0, dc: -15)) {
            #expect(s == [ArrowSteps(.left, 1)])
            #expect(!recentre)
        } else { Issue.record("expected a move") }
        t.gestureEnded()
        #expect(t.midGestureRecentre)
    }

    @Test func relativeMoveAfterARecentreIsNotASnapBack() {
        var t = CursorPadTracker(grid: CursorPadGrid(rows: 15, columns: 31))
        _ = t.caretMoved(toOffset: offset(t, dr: 0, dc: -13))
        t.didRecentre(midGesture: true)
        // The caret moved on from the centre (UIKit is relative): a normal move.
        let o = t.caretMoved(toOffset: offset(t, dr: 0, dc: -1))
        #expect(o == .moved(from: t.grid.center, to: PadPosition(row: 7, column: 14), steps: [ArrowSteps(.left, 1)],
                            recentre: false, afterRecentre: true))
        #expect(t.midGestureRecentre)
    }

    @Test func recentreAfterTheGestureIsNotCheckedForASnapBack() {
        var t = CursorPadTracker(grid: CursorPadGrid(rows: 15, columns: 31))
        _ = t.caretMoved(toOffset: offset(t, dr: 0, dc: -13))
        t.gestureEnded()
        t.didRecentre(midGesture: false)
        #expect(steps(t.caretMoved(toOffset: offset(t, dr: 0, dc: -14))) == [ArrowSteps(.left, 14)])
    }

    @Test func snapBackIsCheckedOnlyOnce() {
        var t = CursorPadTracker(grid: CursorPadGrid(rows: 15, columns: 31))
        _ = t.caretMoved(toOffset: offset(t, dr: 0, dc: -13))
        t.didRecentre(midGesture: true)
        _ = t.caretMoved(toOffset: offset(t, dr: 0, dc: 1))
        #expect(steps(t.caretMoved(toOffset: offset(t, dr: 0, dc: -13))) == [ArrowSteps(.left, 14)])
    }

    // MARK: Queue

    @Test func queueKeepsOrder() {
        var q = ArrowStepQueue()
        q.add(ArrowSteps(.right, 2))
        q.add(ArrowSteps(.down, 1))
        #expect(q.summary == "→×2 ↓×1")
        #expect(q.next() == .right)
        #expect(q.next() == .right)
        #expect(q.next() == .down)
        #expect(q.next() == nil)
        #expect(q.summary == "none")
    }

    @Test func queueCapsEachDirectionAndCountsDrops() {
        var q = ArrowStepQueue(cap: 6)
        let r = q.add(ArrowSteps(.down, 9))
        #expect(r == ArrowStepQueue.AddResult(added: 6, cancelled: 0, dropped: 3))
        #expect(q.count(.down) == 6)
        // Another direction has its own cap.
        #expect(q.add(ArrowSteps(.right, 2)).added == 2)
        _ = q.next()
        #expect(q.add(ArrowSteps(.down, 3)) == ArrowStepQueue.AddResult(added: 1, cancelled: 0, dropped: 2))
    }

    @Test func queueCancelsOppositeSteps() {
        var q = ArrowStepQueue()
        q.add(ArrowSteps(.left, 4))
        let r = q.add(ArrowSteps(.right, 6))
        #expect(r == ArrowStepQueue.AddResult(added: 2, cancelled: 4, dropped: 0))
        #expect(q.pending == [.right, .right])
        q.add(ArrowSteps(.up, 1))
        #expect(q.add(ArrowSteps(.down, 1)).cancelled == 1)
        #expect(q.pending == [.right, .right])
        #expect(q.removeAll() == 2)
        #expect(q.isEmpty)
    }

    @Test func directionUsages() {
        #expect(ArrowDirection.left.usage == .leftArrow)
        #expect(ArrowDirection.right.usage == .rightArrow)
        #expect(ArrowDirection.up.usage == .upArrow)
        #expect(ArrowDirection.down.usage == .downArrow)
        for d in ArrowDirection.allCases { #expect(d.opposite.opposite == d) }
    }

    @Test func arrowTapGetsALatchedModifierOnceLikeThePanel() {
        var s = KeyboardState()
        _ = s.modifierDown(.shift, at: 0)
        _ = s.modifierUp(.shift, at: 0.05)   // latched
        let first = s.tap(ArrowDirection.down.usage)
        #expect(first.first == KeyboardReport(modifiers: .leftShift, keys: []))
        #expect(first.contains(KeyboardReport(modifiers: .leftShift, keys: [.downArrow])))
        #expect(first.last == .empty)
        let second = s.tap(ArrowDirection.down.usage)
        #expect(second == [KeyboardReport(modifiers: [], keys: [.downArrow]), .empty])
    }
}

@Suite("Cursor pad edge repeat")
struct EdgeRepeaterTests {
    let grid = CursorPadGrid(rows: 15, columns: 33)
    private func at(_ r: Int, _ c: Int) -> PadPosition { PadPosition(row: r, column: c) }
    private let always: (ArrowDirection) -> Bool = { _ in true }

    @Test func edgesOfThePad() {
        #expect(EdgeRepeater.edges(of: at(7, 16), in: grid) == [])
        #expect(EdgeRepeater.edges(of: at(7, 0), in: grid) == [.left])
        #expect(EdgeRepeater.edges(of: at(7, 33), in: grid) == [.right])
        #expect(EdgeRepeater.edges(of: at(7, 32), in: grid) == [])
        #expect(EdgeRepeater.edges(of: at(0, 16), in: grid) == [.up])
        #expect(EdgeRepeater.edges(of: at(14, 16), in: grid) == [.down])
        #expect(EdgeRepeater.edges(of: at(0, 0), in: grid) == [.left, .up])
        #expect(EdgeRepeater.edges(of: at(14, 33), in: grid) == [.right, .down])
    }

    @Test func startDelayThenCadence() {
        var e = EdgeRepeater()
        #expect(e.update(position: at(14, 10), grid: grid, at: 10) == [.start(.down)])
        #expect(e.nextDueTime == 10.3)
        #expect(e.tick(at: 10.29, room: always) == [])
        #expect(e.tick(at: 10.3, room: always) == [.down])
        #expect(e.tick(at: 10.35, room: always) == [])
        #expect(e.tick(at: 10.4, room: always) == [.down])
        #expect(e.tick(at: 10.5, room: always) == [.down])
        // Moving along the edge keeps the repeat (no new start delay).
        #expect(e.update(position: at(14, 3), grid: grid, at: 10.55) == [])
        #expect(e.tick(at: 10.6, room: always) == [.down])
    }

    @Test func noRepeatOffTheEdge() {
        var e = EdgeRepeater()
        #expect(e.update(position: at(13, 10), grid: grid, at: 0) == [])
        #expect(e.tick(at: 5, room: always) == [])
        #expect(e.nextDueTime == nil)
    }

    @Test func leavingTheEdgeStopsAtOnce() {
        var e = EdgeRepeater()
        _ = e.update(position: at(0, 5), grid: grid, at: 0)
        _ = e.tick(at: 0.3, room: always)
        _ = e.tick(at: 0.4, room: always)
        let c = e.update(position: at(1, 5), grid: grid, at: 0.45)
        #expect(c.count == 1)
        if case .stop(let d, let n, let pinned) = c.first {
            #expect(d == .up)
            #expect(n == 2)
            #expect(abs(pinned - 0.45) < 1e-9)
        } else { Issue.record("expected a stop") }
        #expect(e.tick(at: 0.5, room: always) == [])
        // Back on the edge: the start delay again.
        #expect(e.update(position: at(0, 5), grid: grid, at: 1) == [.start(.up)])
        #expect(e.tick(at: 1.2, room: always) == [])
        #expect(e.tick(at: 1.3, room: always) == [.up])
    }

    @Test func gestureEndStopsEverything() {
        var e = EdgeRepeater()
        _ = e.update(position: at(0, 0), grid: grid, at: 0)
        #expect(e.isActive)
        let c = e.update(position: nil, grid: grid, at: 0.2)
        #expect(c == [.stop(.left, steps: 0, pinned: 0.2), .stop(.up, steps: 0, pinned: 0.2)])
        #expect(!e.isActive)
        #expect(e.tick(at: 1, room: always) == [])
        #expect(e.stopAll(at: 2) == [])
    }

    @Test func cornerRepeatsBothDirections() {
        var e = EdgeRepeater()
        #expect(e.update(position: at(0, 33), grid: grid, at: 0) == [.start(.right), .start(.up)])
        #expect(e.tick(at: 0.3, room: always) == [.right, .up])
        // Slide down along the right edge: ↑ stops, → goes on.
        let c = e.update(position: at(4, 33), grid: grid, at: 0.35)
        #expect(c == [.stop(.up, steps: 1, pinned: 0.35)])
        #expect(e.tick(at: 0.4, room: always) == [.right])
    }

    @Test func fullQueueSkipsWithoutBacklog() {
        var e = EdgeRepeater()
        _ = e.update(position: at(7, 0), grid: grid, at: 0)
        var room = false
        #expect(e.tick(at: 0.3, room: { _ in room }) == [])
        #expect(e.tick(at: 0.4, room: { _ in room }) == [])
        room = true
        #expect(e.tick(at: 0.45, room: { _ in room }) == [])   // not due yet: no catch-up
        #expect(e.tick(at: 0.5, room: { _ in room }) == [.left])
        #expect(e.pins[.left]?.steps == 1)
    }

    @Test func lateTickDoesNotBurst() {
        var e = EdgeRepeater()
        _ = e.update(position: at(7, 0), grid: grid, at: 0)
        #expect(e.tick(at: 1.0, room: always) == [.left])
        #expect(e.tick(at: 1.0, room: always) == [])
        #expect(e.nextDueTime == 1.1)
    }

    @Test func speedsUpAfterAWhile() {
        var e = EdgeRepeater()
        _ = e.update(position: at(7, 0), grid: grid, at: 0)
        var t = 0.3
        var times: [Double] = []
        while t < 2.5 {
            if !e.tick(at: t, room: always).isEmpty { times.append(t) }
            t = (t * 1000 + 1).rounded() / 1000   // 1 ms steps
        }
        let gaps = zip(times.dropFirst(), times).map { (($0 - $1) * 1000).rounded() }
        #expect(gaps.first == 100)
        #expect(gaps.contains(60))
        #expect(gaps.allSatisfy { $0 == 100 || $0 == 60 })
        // 100 ms until the repeat has run for 1.5 s (from 0.3 s), 60 ms after.
        let firstFast = zip(times.dropFirst(), gaps).first { $0.1 == 60 }!.0
        #expect(firstFast >= 1.8 - 1e-9 && firstFast <= 1.9 + 1e-9)
    }

    @Test func repeatFeedsTheQueueWithinItsCap() {
        var e = EdgeRepeater()
        var q = ArrowStepQueue(cap: 6)
        _ = e.update(position: at(7, 0), grid: grid, at: 0)
        var t = 0.3
        var dropped = 0
        while t < 3 {   // nothing drains the queue: it fills to the cap and stays there
            for d in e.tick(at: t, room: { q.count($0) < q.cap }) { dropped += q.add(ArrowSteps(d, 1)).dropped }
            t += 0.01
        }
        #expect(q.count(.left) == 6)
        #expect(dropped == 0)
        #expect(e.pins[.left]?.steps == 6)
    }
}
