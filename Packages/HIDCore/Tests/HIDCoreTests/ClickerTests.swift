import Testing
@testable import HIDCore

private func kb(_ mods: KeyModifiers = [], _ keys: [KeyUsage] = []) -> ClickerReport {
    .keyboard(KeyboardReport(modifiers: mods, keys: keys))
}

/// What a host ends up with after a report list, and how often each key went down.
private struct FakeHost {
    var keyboard = KeyboardReport.empty
    var buttons: MouseButtons = []
    var keyDowns: [KeyUsage: Int] = [:]
    /// A key went down without the modifiers the sequence had set just before it.
    var keyWithoutModifier = false

    mutating func apply(_ reports: [ClickerReport]) {
        for r in reports {
            switch r {
            case .keyboard(let k):
                for key in k.keys where !keyboard.keys.contains(key) {
                    keyDowns[key, default: 0] += 1
                    // The modifier must already be down in the previous report.
                    if !k.modifiers.isEmpty, !keyboard.modifiers.isSuperset(of: k.modifiers) { keyWithoutModifier = true }
                }
                keyboard = k
            case .mouseButtons(let b):
                buttons = b
            }
        }
    }
}

@Suite("Clicker")
struct ClickerTests {
    // MARK: Slide keys

    @Test func slideKeys() {
        let s = ClickerState()
        #expect(s.slideTap(.next, keys: .arrows) == [kb([], [.rightArrow]), kb()])
        #expect(s.slideTap(.previous, keys: .arrows) == [kb([], [.leftArrow]), kb()])
        #expect(s.slideTap(.next, keys: .pages) == [kb([], [.pageDown]), kb()])
        #expect(s.slideTap(.previous, keys: .pages) == [kb([], [.pageUp]), kb()])
    }

    @Test func slideKeysAreBlockedWhileControlIsHeld() {
        var s = ClickerState()
        _ = s.pointerPressed(method: .controlLeftButton, host: .windows)
        #expect(s.slideTap(.next, keys: .arrows).isEmpty)
        _ = s.release()
        #expect(!s.slideTap(.next, keys: .arrows).isEmpty)
        // The toggle method has nothing down during the hold: slides still turn.
        _ = s.pointerPressed(method: .powerPointToggle, host: .windows)
        #expect(s.slideTap(.previous, keys: .arrows) == [kb([], [.leftArrow]), kb()])
        _ = s.pointerPressed(method: .pointerOnly, host: .macOS)   // ignored: still the toggle hold
        #expect(s.hold?.method == .powerPointToggle)
    }

    // MARK: PowerPoint toggle

    @Test func powerPointToggleWindows() {
        var s = ClickerState()
        #expect(s.pointerPressed(method: .powerPointToggle, host: .windows)
                == [kb(.leftControl), kb(.leftControl, [.l]), kb(.leftControl), kb()])
        #expect(s.isPointerHeld)
        #expect(s.release() == [kb(.leftControl), kb(.leftControl, [.a]), kb(.leftControl), kb()])
        #expect(!s.isPointerHeld)
    }

    @Test func powerPointToggleMac() {
        var s = ClickerState()
        #expect(s.pointerPressed(method: .powerPointToggle, host: .macOS)
                == [kb(.leftGUI), kb(.leftGUI, [.l]), kb(.leftGUI), kb()])
        #expect(s.release() == [kb(.leftGUI), kb(.leftGUI, [.a]), kb(.leftGUI), kb()])
    }

    // MARK: Control + left button

    @Test func controlLeftButton() {
        var s = ClickerState()
        #expect(s.pointerPressed(method: .controlLeftButton, host: .windows)
                == [kb(.leftControl), .mouseButtons(.left)])
        #expect(s.release() == [.mouseButtons([]), kb()])
    }

    @Test func pointerOnlySendsNoKeys() {
        var s = ClickerState()
        #expect(s.pointerPressed(method: .pointerOnly, host: .windows).isEmpty)
        #expect(s.isPointerHeld)
        #expect(s.release().isEmpty)
        #expect(!s.isPointerHeld)
    }

    // MARK: Pairing guarantees

    @Test func releaseWithoutPressSendsNothing() {
        var s = ClickerState()
        #expect(s.release().isEmpty)
        _ = s.pointerPressed(method: .powerPointToggle, host: .macOS)
        #expect(!s.release().isEmpty)
        #expect(s.release().isEmpty)   // a second end (e.g. cancel after lift, forced after lift)
    }

    @Test func secondPressDuringHoldIsIgnored() {
        var s = ClickerState()
        let first = s.pointerPressed(method: .powerPointToggle, host: .windows)
        #expect(!first.isEmpty)
        #expect(s.pointerPressed(method: .powerPointToggle, host: .windows).isEmpty)
        #expect(s.release().count == 4)
        #expect(s.release().isEmpty)
    }

    @Test func releaseUsesWhatWasPressed() {
        // The press captured macOS + toggle; whatever the profile says by the release time,
        // the release is ⌘A (it takes no arguments, by design).
        var s = ClickerState()
        _ = s.pointerPressed(method: .powerPointToggle, host: .macOS)
        #expect(s.hold == .init(method: .powerPointToggle, host: .macOS))
        #expect(s.release().contains(kb(.leftGUI, [.a])))
        _ = s.pointerPressed(method: .controlLeftButton, host: .windows)
        #expect(s.release() == [.mouseButtons([]), kb()])
    }

    @Test func forgetDropsTheHoldWithoutReports() {
        var s = ClickerState()
        _ = s.pointerPressed(method: .controlLeftButton, host: .windows)
        s.forget()
        #expect(!s.isPointerHeld)
        #expect(s.release().isEmpty)
    }

    /// For every method and host OS: press + release leaves the host with nothing down, the
    /// shortcut keys go down only with their modifier already down, and the "on" and "off"
    /// shortcuts come in pairs.
    @Test(arguments: LaserMethod.allCases, HostOS.allCases)
    func everyHoldEndsReleased(method: LaserMethod, host: HostOS) {
        for presses in 1...3 {
            var s = ClickerState()
            var h = FakeHost()
            for _ in 0..<presses {
                h.apply(s.pointerPressed(method: method, host: host))
                // During a hold only the Control + button method keeps anything down.
                if method == .controlLeftButton {
                    #expect(h.keyboard == KeyboardReport(modifiers: .leftControl, keys: []) && h.buttons == .left)
                } else {
                    #expect(h.keyboard == .empty && h.buttons == [])
                }
                h.apply(s.slideTap(.next, keys: .arrows))
                h.apply(s.release())
                h.apply(s.release())
                #expect(h.keyboard == .empty)
                #expect(h.buttons == [])
            }
            #expect(!h.keyWithoutModifier)
            #expect(h.keyDowns[.l, default: 0] == h.keyDowns[.a, default: 0])
            #expect(h.keyDowns[.l, default: 0] == (method == .powerPointToggle ? presses : 0))
            // Slides were sent unless Control was held.
            #expect(h.keyDowns[.rightArrow, default: 0] == (method == .controlLeftButton ? 0 : presses))
        }
    }

    // MARK: Tap zones

    @Test func tapInAHalfFiresOnLift() {
        var t = ClickerTapTracker()
        t.began(1, in: .next)
        #expect(t.zone(of: 1) == .next)
        #expect(t.ended(1, in: .next) == .next)
        t.began(2, in: .previous)
        t.moved(2, to: .previous)
        #expect(t.ended(2, in: .previous) == .previous)
        #expect(t.activeTouches == 0)
    }

    @Test func liftIsCountedOnce() {
        var t = ClickerTapTracker()
        t.began(1, in: .next)
        #expect(t.ended(1, in: .next) == .next)
        #expect(t.ended(1, in: .next) == nil)
        #expect(t.ended(7, in: .previous) == nil)   // never began
    }

    @Test func slidingInFromTheOtherHalfSendsNothing() {
        var t = ClickerTapTracker()
        t.began(1, in: .next)
        t.moved(1, to: .previous)
        #expect(t.zone(of: 1) == nil)
        #expect(t.ended(1, in: .previous) == nil)
        // Out and back again: still void.
        t.began(2, in: .previous)
        t.moved(2, to: .next)
        t.moved(2, to: .previous)
        #expect(t.ended(2, in: .previous) == nil)
    }

    @Test func touchesOverThePointerButtonSendNothing() {
        var t = ClickerTapTracker()
        t.began(1, in: .outside)                 // started on the button area
        #expect(t.ended(1, in: .next) == nil)
        t.began(2, in: .next)
        #expect(t.ended(2, in: .outside) == nil) // lifted over the button
    }

    @Test func cancelledTouchesSendNothing() {
        var t = ClickerTapTracker()
        t.began(1, in: .next)
        t.cancelled(1)
        #expect(t.ended(1, in: .next) == nil)
        t.began(2, in: .previous)
        t.reset()
        #expect(t.ended(2, in: .previous) == nil)
    }

    @Test func fingersAreIndependent() {
        var t = ClickerTapTracker()
        t.began(1, in: .next)
        t.began(2, in: .next)
        t.began(3, in: .previous)
        t.moved(2, to: .previous)
        #expect(t.ended(3, in: .previous) == .previous)
        #expect(t.ended(2, in: .previous) == nil)
        #expect(t.ended(1, in: .next) == .next)
    }
}

@Suite("ReportQueue pressed kinds")
struct ReportQueuePressedKindsTests {
    @Test func pressedKindsFollowWhatWasSent() {
        var q = ReportQueue(pacing: [.keyboard: .keys, .mouse: .keys])
        #expect(q.pressedKinds.isEmpty)
        q.didSend(.keyboard(KeyboardReport(modifiers: .leftControl, keys: [])), at: 0)
        q.didSend(.mouse(MouseReport(buttons: .left)), at: 0.05)
        #expect(q.pressedKinds == [.keyboard, .mouse])
        q.didSend(.mouse(MouseReport(buttons: .left, x: 5)), at: 0.06)   // motion with the button down
        #expect(q.pressedKinds == [.keyboard, .mouse])
        q.didSend(.mouse(MouseReport()), at: 0.1)
        #expect(q.pressedKinds == [.keyboard])
        q.didSend(.keyboard(.empty), at: 0.2)
        #expect(q.pressedKinds.isEmpty)
        q.didSend(.consumer(ConsumerReport(.playPause)), at: 0.3)
        #expect(q.pressedKinds == [.consumer])
        q.removeAll()
        #expect(q.pressedKinds.isEmpty)
    }
}
