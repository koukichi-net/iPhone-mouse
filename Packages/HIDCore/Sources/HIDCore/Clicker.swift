// Clicker mode (design §8.5): slide keys, the tap zones and the laser-pointer button.
//
// Pure value types: the caller feeds touches / button presses in and queues the reports that
// come out (keyboard reports and mouse button states, in order). Pacing between them is the
// transport's job (`ReportQueue` with `ReportPacing.keys`).

public enum ClickerDirection: String, Sendable, Hashable, CaseIterable {
    case next, previous
}

/// Which keys turn the slides.
public enum SlideKeys: String, Sendable, Hashable, CaseIterable {
    /// → / ← (default).
    case arrows
    /// PageDown / PageUp.
    case pages

    public func usage(_ d: ClickerDirection) -> KeyUsage {
        switch (self, d) {
        case (.arrows, .next): .rightArrow
        case (.arrows, .previous): .leftArrow
        case (.pages, .next): .pageDown
        case (.pages, .previous): .pageUp
        }
    }
}

/// How the pointer button shows PowerPoint's laser pointer (per host).
public enum LaserMethod: String, Sendable, Hashable, CaseIterable {
    /// Press: "laser pointer" shortcut; release: "arrow pointer" shortcut
    /// (Windows Ctrl+L / Ctrl+A, macOS ⌘L / ⌘A). Default.
    case powerPointToggle
    /// Press: Left Control down, then the left button down; release: button up, then Control
    /// up (Windows PowerPoint shows the laser while Ctrl + left button are held).
    case controlLeftButton
    /// No keys or buttons; the pointer only moves.
    case pointerOnly
}

/// One report the clicker wants queued.
public enum ClickerReport: Sendable, Hashable {
    case keyboard(KeyboardReport)
    /// The complete mouse button state (queued as a button transition).
    case mouseButtons(MouseButtons)
}

/// The pointer button and the slide keys. Guarantees (unit-tested):
/// - every press is followed by exactly one release sequence, whichever way the hold ends
///   (`release()` for lift, cancel and forced release alike), and a release without a press
///   produces nothing;
/// - the release uses the method and host OS captured at the press, so changing the setting
///   or the host profile during a hold cannot unpair them;
/// - shortcut keys go down only after their modifier is down, and every sequence ends with
///   nothing pressed (except the deliberate Control + button hold of `controlLeftButton`);
/// - slide keys are not sent while that hold has Control down (Ctrl+→ would be a different key).
public struct ClickerState: Sendable {
    public struct Hold: Sendable, Hashable {
        public var method: LaserMethod
        public var host: HostOS
    }

    /// The pointer hold in progress (nil when the button is up).
    public private(set) var hold: Hold?

    public init() {}

    public var isPointerHeld: Bool { hold != nil }

    /// Modifier + keys of the PowerPoint shortcuts for `host`.
    public static func shortcut(for host: HostOS) -> (modifiers: KeyModifiers, laserOn: KeyUsage, arrow: KeyUsage) {
        switch host {
        case .macOS: (.leftGUI, .l, .a)
        case .windows: (.leftControl, .l, .a)
        }
    }

    /// Modifier down, key down (modifier still down), key up, modifier up.
    static func chord(_ modifiers: KeyModifiers, _ key: KeyUsage) -> [ClickerReport] {
        [
            .keyboard(KeyboardReport(modifiers: modifiers, keys: [])),
            .keyboard(KeyboardReport(modifiers: modifiers, keys: [key])),
            .keyboard(KeyboardReport(modifiers: modifiers, keys: [])),
            .keyboard(.empty),
        ]
    }

    /// One press and release of the slide key, or nothing while Control is held down by a
    /// `controlLeftButton` hold.
    public func slideTap(_ d: ClickerDirection, keys: SlideKeys) -> [ClickerReport] {
        if hold?.method == .controlLeftButton { return [] }
        let u = keys.usage(d)
        return [.keyboard(KeyboardReport(modifiers: [], keys: [u])), .keyboard(.empty)]
    }

    /// The pointer button went down. A second press during a hold does nothing.
    public mutating func pointerPressed(method: LaserMethod, host: HostOS) -> [ClickerReport] {
        guard hold == nil else { return [] }
        hold = Hold(method: method, host: host)
        switch method {
        case .powerPointToggle:
            let s = Self.shortcut(for: host)
            return Self.chord(s.modifiers, s.laserOn)
        case .controlLeftButton:
            return [.keyboard(KeyboardReport(modifiers: .leftControl, keys: [])), .mouseButtons(.left)]
        case .pointerOnly:
            return []
        }
    }

    /// The hold ends (finger lifted, touch cancelled, app resigning, host change, mode off):
    /// the release that pairs with the press, or nothing if there was no press.
    public mutating func release() -> [ClickerReport] {
        guard let h = hold else { return [] }
        hold = nil
        switch h.method {
        case .powerPointToggle:
            let s = Self.shortcut(for: h.host)
            return Self.chord(s.modifiers, s.arrow)
        case .controlLeftButton:
            return [.mouseButtons([]), .keyboard(.empty)]
        case .pointerOnly:
            return []
        }
    }

    /// Forget the hold without sending (the host is gone).
    public mutating func forget() {
        hold = nil
    }
}

/// Where a touch on the clicker screen is.
public enum ClickerZone: String, Sendable, Hashable {
    /// Upper half.
    case next
    /// Lower half.
    case previous
    /// Neither (over the pointer button, outside the surfaces).
    case outside

    public var direction: ClickerDirection? {
        switch self {
        case .next: .next
        case .previous: .previous
        case .outside: nil
        }
    }
}

/// Decides which touches on the two halves turn a slide. A touch counts on lift (touch-up),
/// once, and only if it began in a half and never left it: touches that start on the pointer
/// button, slide in from the other half, wander out and back, or are cancelled by the system
/// send nothing. Holding sends nothing until the lift (no auto-repeat).
public struct ClickerTapTracker: Sendable {
    private var touches: [Int: ClickerZone] = [:]

    public init() {}

    public var activeTouches: Int { touches.count }

    /// Zone a touch is currently valid in (nil: not tracked or void).
    public func zone(of id: Int) -> ClickerZone? {
        guard let z = touches[id], z != .outside else { return nil }
        return z
    }

    public mutating func began(_ id: Int, in zone: ClickerZone) {
        touches[id] = zone
    }

    public mutating func moved(_ id: Int, to zone: ClickerZone) {
        guard let z = touches[id], z != zone else { return }
        touches[id] = ClickerZone.outside   // left its half: void for good
    }

    /// The direction to send for this lift, or nil.
    public mutating func ended(_ id: Int, in zone: ClickerZone) -> ClickerDirection? {
        guard let z = touches.removeValue(forKey: id), z == zone else { return nil }
        return z.direction
    }

    public mutating func cancelled(_ id: Int) {
        touches[id] = nil
    }

    public mutating func reset() {
        touches = [:]
    }
}
