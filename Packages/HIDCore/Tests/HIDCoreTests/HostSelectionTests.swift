import Testing
@testable import HIDCore

@Suite("HostSelection")
struct HostSelectionTests {
    let mac = "MAC", win = "WIN", ipad = "IPAD"

    @Test func firstHostBecomesActive() {
        #expect(HostSelection.afterSubscribe(mac, active: nil, subscribed: [mac], pinned: nil, preferred: nil, inLaunchWindow: true) == mac)
        #expect(HostSelection.afterSubscribe(mac, active: nil, subscribed: [mac], pinned: nil, preferred: win, inLaunchWindow: false) == mac)
    }

    @Test func newcomerDoesNotStealInput() {
        // The observed case: controlling the Mac, Windows reconnects by itself.
        #expect(HostSelection.afterSubscribe(win, active: mac, subscribed: [mac, win], pinned: nil, preferred: mac, inLaunchWindow: false) == mac)
        #expect(HostSelection.afterSubscribe(win, active: mac, subscribed: [mac, win], pinned: nil, preferred: nil, inLaunchWindow: false) == mac)
        // Even the preferred host does not steal after the launch window.
        #expect(HostSelection.afterSubscribe(win, active: mac, subscribed: [mac, win], pinned: nil, preferred: win, inLaunchWindow: false) == mac)
    }

    @Test func newcomerTakesOverWhenTheActiveHostIsGone() {
        #expect(HostSelection.afterSubscribe(win, active: mac, subscribed: [win], pinned: nil, preferred: mac, inLaunchWindow: false) == win)
    }

    @Test func preferredHostWinsAtLaunch() {
        // Windows subscribed first, the Mac (last used) a moment later.
        #expect(HostSelection.afterSubscribe(mac, active: win, subscribed: [win, mac], pinned: nil, preferred: mac, inLaunchWindow: true) == mac)
        // A non-preferred host arriving second during the window does not switch.
        #expect(HostSelection.afterSubscribe(ipad, active: mac, subscribed: [mac, ipad], pinned: nil, preferred: mac, inLaunchWindow: true) == mac)
        #expect(HostSelection.afterSubscribe(ipad, active: win, subscribed: [win, ipad], pinned: nil, preferred: mac, inLaunchWindow: true) == win)
    }

    @Test func pinnedOverridesEverything() {
        #expect(HostSelection.afterSubscribe(win, active: nil, subscribed: [win], pinned: mac, preferred: win, inLaunchWindow: true) == nil)
        #expect(HostSelection.afterSubscribe(mac, active: nil, subscribed: [win, mac], pinned: mac, preferred: win, inLaunchWindow: true) == mac)
        #expect(HostSelection.afterSubscribe(win, active: mac, subscribed: [win, mac], pinned: mac, preferred: win, inLaunchWindow: true) == mac)
        #expect(HostSelection.afterActiveGone(remaining: [win], pinned: mac, preferred: win) == nil)
    }

    @Test func activeGoneFallsBackToPreferredThenMostRecent() {
        #expect(HostSelection.afterActiveGone(remaining: [win, ipad], pinned: nil, preferred: win) == win)
        #expect(HostSelection.afterActiveGone(remaining: [win, ipad], pinned: nil, preferred: mac) == ipad)
        #expect(HostSelection.afterActiveGone(remaining: [String](), pinned: nil, preferred: mac) == nil)
    }
}
