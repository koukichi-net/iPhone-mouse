import Testing
@testable import HIDCore

private func drain(_ q: inout ReportQueue) -> [OutgoingReport] {
    var out: [OutgoingReport] = []
    while let r = q.next() { out.append(r) }
    return out
}
private func mouse(_ b: MouseButtons = [], x: Int = 0, y: Int = 0, wheel: Int = 0, pan: Int = 0) -> OutgoingReport {
    .mouse(MouseReport(buttons: b, x: x, y: y, wheel: wheel, pan: pan))
}

@Suite("ReportQueue")
struct ReportQueueTests {
    @Test func motionCoalescesWhileBusy() {
        var q = ReportQueue()
        q.enqueueMotion(dx: 3, dy: 1)
        q.enqueueMotion(dx: 4, dy: -2)
        q.enqueueMotion(wheel: 1)
        q.enqueueMotion(dx: -1, pan: -2)
        #expect(q.count == 1)
        #expect(drain(&q) == [mouse(x: 6, y: -1, wheel: 1, pan: -2)])
        #expect(q.isEmpty)
    }

    @Test func buttonTransitionsKeepOrderAndSplitMotion() {
        var q = ReportQueue()
        q.enqueueMotion(dx: 5)
        q.setMouseButtons(.left)
        q.enqueueMotion(dx: 2)
        q.enqueueMotion(dx: 3)
        q.setMouseButtons([])
        q.enqueueMotion(dx: 7)
        #expect(drain(&q) == [
            mouse(x: 5),
            mouse(.left),
            mouse(.left, x: 5),   // motion during the drag carries the button
            mouse(),
            mouse(x: 7),
        ])
    }

    @Test func clickIsNeverMerged() {
        var q = ReportQueue()
        q.enqueue([PointerAction.buttons(.left), .buttons([]), .buttons(.left), .buttons([])])
        #expect(drain(&q) == [mouse(.left), mouse(), mouse(.left), mouse()])
    }

    @Test func redundantButtonStateIsIgnored() {
        var q = ReportQueue()
        q.setMouseButtons([])
        #expect(q.isEmpty)
        q.setMouseButtons(.right)
        q.setMouseButtons(.right)
        #expect(q.count == 1)
        #expect(q.mouseButtons == .right)
    }

    @Test func oversizedSumSplitsWithSameButtons() {
        var q = ReportQueue()
        q.setMouseButtons(.left)
        _ = q.next()
        for _ in 0..<4 { q.enqueueMotion(dx: 10_000, wheel: 75) }   // 40000, 300
        #expect(drain(&q) == [
            mouse(.left, x: 32767, wheel: 127),
            mouse(.left, x: 7233, wheel: 127),
            mouse(.left, wheel: 46),
        ])
        q.enqueueMotion(dx: -70_000)
        #expect(drain(&q) == [mouse(.left, x: -32767), mouse(.left, x: -32767), mouse(.left, x: -4466)])
    }

    @Test func keyboardAndConsumerKeepOrderWithMouse() {
        var q = ReportQueue()
        q.enqueue(KeyboardReport(modifiers: .command))
        q.enqueueMotion(dx: 1)
        q.setMouseButtons(.left)
        q.setMouseButtons([])
        q.enqueue(KeyboardReport.empty)
        q.enqueueMotion(dx: 2)
        q.enqueue(ConsumerReport(.volumeIncrement))
        q.enqueueMotion(dx: 3)   // does not merge across the consumer report
        q.enqueue(ConsumerReport.released)
        let out = drain(&q)
        #expect(out == [
            .keyboard(KeyboardReport(modifiers: .command)),
            mouse(x: 1), mouse(.left), mouse(),
            .keyboard(.empty),
            mouse(x: 2),
            .consumer(ConsumerReport(.volumeIncrement)),
            mouse(x: 3),
            .consumer(.released),
        ])
        #expect(out.map(\.kind) == [.keyboard, .mouse, .mouse, .mouse, .keyboard, .mouse, .consumer, .mouse, .consumer])
    }

    @Test func identicalKeyboardReportsAreKept() {
        var q = ReportQueue()
        let typed = TextTyper(keyMap: .us).reports(for: "aa").reports
        q.enqueue(typed)
        #expect(drain(&q) == typed.map { .keyboard($0) })
    }

    @Test func zeroSumMotionIsDropped() {
        var q = ReportQueue()
        q.enqueueMotion(dx: 5)
        q.enqueueMotion(dx: -5)
        q.enqueue(KeyboardReport(.a))
        #expect(drain(&q) == [.keyboard(KeyboardReport(.a))])
        q.enqueueMotion()
        #expect(q.isEmpty)
    }

    @Test func pushBackSendsFirstNextTime() {
        var q = ReportQueue()
        q.enqueue(KeyboardReport(.a))
        q.enqueue(KeyboardReport.empty)
        let first = q.next()!
        q.pushBack(first)                      // updateValue returned false
        #expect(drain(&q) == [.keyboard(KeyboardReport(.a)), .keyboard(.empty)])
    }

    @Test func busyTransportScenario() {
        var q = ReportQueue()
        q.enqueueMotion(dx: 10)
        let sent = q.next()!                   // transport tries, fails
        q.pushBack(sent)
        q.enqueueMotion(dx: 4, dy: 2)          // more motion while busy
        q.setMouseButtons(.left)
        q.enqueueMotion(dx: 1)
        // Ready again.
        #expect(drain(&q) == [mouse(x: 14, y: 2), mouse(.left), mouse(.left, x: 1)])
    }

    @Test func pushedBackMotionMergesOnlyWithSameButtons() {
        var q = ReportQueue()
        q.setMouseButtons(.left)
        q.enqueueMotion(dx: 3)
        let press = q.next()!                  // the press transition
        q.pushBack(press)                      // a transition always goes back as is
        #expect(q.count == 2)
        #expect(drain(&q) == [mouse(.left), mouse(.left, x: 3)])

        q.setMouseButtons(.left)               // no-op: already .left
        q.enqueueMotion(dx: 5)
        let moved = q.next()!
        q.enqueueMotion(dx: 1)
        q.pushBack(moved)                      // motion with the same buttons → merged
        #expect(q.count == 1)
        #expect(drain(&q) == [mouse(.left, x: 6)])

        q.setMouseButtons([])
        q.enqueueMotion(dx: 2)
        let release = q.next()!
        #expect(release == mouse())
        q.pushBack(mouse(.right, x: 9))        // different buttons → kept separate, first
        #expect(drain(&q) == [mouse(.right, x: 9), mouse(x: 2)])
    }

    @Test func pushedBackPressSurvivesMotionSummingToZero() {
        var q = ReportQueue()
        q.setMouseButtons(.left)
        q.enqueueMotion(dx: 3)
        let press = q.next()!
        q.pushBack(press)
        q.enqueueMotion(dx: -3)
        q.setMouseButtons([])
        #expect(drain(&q) == [mouse(.left), mouse()])
    }

    @Test func pointerEngineOutputFeedsQueue() {
        var e = PointerEngine()
        var q = ReportQueue()
        q.enqueue(e.handle(TouchEvent(id: 1, phase: .began, location: .zero, timestamp: 0)))
        q.enqueue(e.handle(TouchEvent(id: 1, phase: .ended, location: .zero, timestamp: 0.05)))
        #expect(drain(&q) == [mouse(.left), mouse()])
    }

    @Test func removeAllClears() {
        var q = ReportQueue()
        q.setMouseButtons(.left)
        q.enqueueMotion(dx: 1)
        q.removeAll()
        #expect(q.isEmpty && q.mouseButtons == [])
        #expect(q.next() == nil)
    }

    @Test func longRunStaysOrdered() {
        var q = ReportQueue()
        var expected: [OutgoingReport] = []
        for i in 0..<500 {
            let r = KeyboardReport(modifiers: KeyModifiers(rawValue: UInt8(i % 256)))
            q.enqueue(r)
            expected.append(.keyboard(r))
            if i % 3 == 0, let x = q.next() { #expect(x == expected.removeFirst()) }
        }
        #expect(drain(&q) == expected)
    }

    @Test func outgoingBytesHaveNoReportID() {
        #expect(mouse(x: 1).bytes.count == 7)
        #expect(OutgoingReport.keyboard(.empty).bytes.count == 8)
        #expect(OutgoingReport.consumer(.released).bytes.count == 2)
    }
}
