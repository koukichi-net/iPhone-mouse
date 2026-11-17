import Foundation
import Observation
import HIDCore

/// Global settings (design §8.3), persisted in UserDefaults. Per-host values (name, pointer
/// and scroll speed, key layout, host OS) live in `HostStore`; the `default…` values here are
/// what a newly seen host starts with.
@MainActor
@Observable
final class AppSettings {
    static let accelerationRange: ClosedRange<Double> = 0...3

    var acceleration: Double { didSet { save("acceleration", acceleration) } }
    var invertScroll: Bool { didSet { save("invertScroll", invertScroll) } }
    var tapToClick: Bool { didSet { save("tapToClick", tapToClick) } }
    var haptics: Bool { didSet { save("haptics", haptics) } }
    var defaultPointerSpeed: Double { didSet { save("defaultPointerSpeed", defaultPointerSpeed) } }
    var defaultScrollSpeed: Double { didSet { save("defaultScrollSpeed", defaultScrollSpeed) } }
    var defaultLayout: KeyboardLayout { didSet { save("defaultLayout", defaultLayout.rawValue) } }
    var defaultHostOS: HostOS { didSet { save("defaultHostOS", defaultHostOS.rawValue) } }
    /// Scroll strip (design §8.1): edge (right/left/off) and width in points.
    var scrollStripEdge: ScrollStripEdge { didSet { save("scrollStripEdge", scrollStripEdge.rawValue) } }
    var scrollStripWidth: Double { didSet { save("scrollStripWidth", scrollStripWidth) } }
    /// Momentum after a fast scroll.
    var scrollInertia: Bool { didSet { save("scrollInertia", scrollInertia) } }
    /// Text field: send かな / 英数 before kana / ASCII letters so the host IME follows (§8.4).
    var autoIMESwitch: Bool { didSet { save("autoIMESwitch", autoIMESwitch) } }
    #if DEBUG
    /// 入力内容をログに記録する（診断用）: TEXTCAP / MIRROR lines show what was typed. Off by
    /// default (typed text is replaced by lengths); turned off once for installs that had the
    /// old default on (2026-11-18, `logTypingDefaultOff`). Debug builds only (no log in Release).
    var logTyping: Bool { didSet { save("logTyping", logTyping); Log.recordTyping = logTyping } }
    #endif
    /// 空白キー長押しのカーソル移動を矢印キーとして送る (the keyboard's space-bar cursor gesture).
    var cursorPadArrows: Bool { didSet { save("cursorPadArrows", cursorPadArrows) } }
    /// Cursor gesture sensitivity: characters of caret movement per Left/Right press (1 or 2).
    var cursorPadColumnsPerStep: Int { didSet { save("cursorPadColumnsPerStep", cursorPadColumnsPerStep) } }
    /// クリッカーモード (design §8.5): the main screen becomes the presentation remote.
    var clickerMode: Bool { didSet { save("clickerMode", clickerMode) } }
    /// Clicker screen shown without the saved setting (`--show=clicker`, `--clicker-probe`).
    /// Not persisted; turning the mode off clears it too.
    var clickerPreview = false
    /// スライド送りのキー: → / ← (default) or PageDown / PageUp.
    var slideKeys: SlideKeys { didSet { save("slideKeys", slideKeys.rawValue) } }

    /// The clicker screen is showing.
    var clickerActive: Bool { clickerMode || clickerPreview }

    func setClicker(_ on: Bool) {
        if clickerMode != on { clickerMode = on }
        if !on { clickerPreview = false }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let base = PointerSettings()
        acceleration = (defaults.object(forKey: "acceleration") as? Double) ?? base.acceleration
        invertScroll = (defaults.object(forKey: "invertScroll") as? Bool) ?? base.invertScroll
        tapToClick = (defaults.object(forKey: "tapToClick") as? Bool) ?? base.tapToClick
        haptics = (defaults.object(forKey: "haptics") as? Bool) ?? true
        defaultPointerSpeed = (defaults.object(forKey: "defaultPointerSpeed") as? Double) ?? SpeedScale.pointer.defaultValue
        defaultScrollSpeed = (defaults.object(forKey: "defaultScrollSpeed") as? Double) ?? SpeedScale.scroll.defaultValue
        // US: macOS treats an unknown keyboard (no vendor/product ID) as ANSI, where the US
        // map types all of printable ASCII correctly. Windows hosts are recognised by their
        // NumLock LED write and start as JIS (HostStore.noteLEDWrite).
        defaultLayout = (defaults.string(forKey: "defaultLayout")).flatMap(KeyboardLayout.init(rawValue:)) ?? .us
        defaultHostOS = (defaults.string(forKey: "defaultHostOS")).flatMap(HostOS.init(rawValue:)) ?? .macOS
        scrollStripEdge = (defaults.string(forKey: "scrollStripEdge")).flatMap(ScrollStripEdge.init(rawValue:)) ?? .right
        scrollStripWidth = (defaults.object(forKey: "scrollStripWidth") as? Double) ?? ScrollStripLayout.defaultWidth
        scrollInertia = (defaults.object(forKey: "scrollInertia") as? Bool) ?? base.scrollInertia
        autoIMESwitch = (defaults.object(forKey: "autoIMESwitch") as? Bool) ?? true
        #if DEBUG
        // One-time: the old default was on and the user never chose it, so it is forced off
        // once; a later choice in the settings is kept.
        if !defaults.bool(forKey: "logTypingDefaultOff") {
            defaults.set(false, forKey: "logTyping")
            defaults.set(true, forKey: "logTypingDefaultOff")
        }
        logTyping = (defaults.object(forKey: "logTyping") as? Bool) ?? false
        #endif
        cursorPadArrows = (defaults.object(forKey: "cursorPadArrows") as? Bool) ?? true
        cursorPadColumnsPerStep = min(2, max(1, (defaults.object(forKey: "cursorPadColumnsPerStep") as? Int) ?? 1))
        clickerMode = (defaults.object(forKey: "clickerMode") as? Bool) ?? false
        slideKeys = (defaults.string(forKey: "slideKeys")).flatMap(SlideKeys.init(rawValue:)) ?? .arrows
        #if DEBUG
        Log.recordTyping = logTyping
        #endif
    }

    var scrollStrip: ScrollStripLayout { ScrollStripLayout(edge: scrollStripEdge, width: scrollStripWidth) }

    /// Engine settings for a host profile (nil: no host, use the defaults).
    func pointerSettings(for profile: HostProfile?) -> PointerSettings {
        var s = PointerSettings()
        s.sensitivity = profile?.pointerSpeed ?? defaultPointerSpeed
        s.scrollPointsPerUnit = PointerSettings().scrollPointsPerUnit / (profile?.scrollSpeed ?? defaultScrollSpeed)
        s.acceleration = acceleration
        s.invertScroll = invertScroll
        s.tapToClick = tapToClick
        s.scrollInertia = scrollInertia
        return s
    }

    func resetToDefaults() {
        let base = PointerSettings()
        acceleration = base.acceleration
        invertScroll = base.invertScroll
        tapToClick = base.tapToClick
        haptics = true
        defaultPointerSpeed = SpeedScale.pointer.defaultValue
        defaultScrollSpeed = SpeedScale.scroll.defaultValue
        scrollStripEdge = .right
        scrollStripWidth = ScrollStripLayout.defaultWidth
        scrollInertia = base.scrollInertia
        autoIMESwitch = true
        #if DEBUG
        logTyping = false
        #endif
        cursorPadArrows = true
        cursorPadColumnsPerStep = 1
        clickerMode = false
        clickerPreview = false
        slideKeys = .arrows
    }

    /// One line for the log; the settings sheet also watches it for changes.
    var summary: String {
        String(format: "acceleration=%.2f invertScroll=%@ tapToClick=%@ haptics=%@ strip=%@/%.0fpt inertia=%@ autoIME=%@ logTyping=%@ cursorPad=%@/%d clicker=%@%@ slideKeys=%@ defaults: speed=%.2f scroll=%.2f layout=%@ os=%@",
               acceleration, "\(invertScroll)", "\(tapToClick)", "\(haptics)", scrollStripEdge.rawValue, scrollStripWidth,
               "\(scrollInertia)", "\(autoIMESwitch)", logTypingText, "\(cursorPadArrows)", cursorPadColumnsPerStep,
               "\(clickerMode)", clickerPreview ? "(preview)" : "", slideKeys.rawValue, defaultPointerSpeed, defaultScrollSpeed,
               defaultLayout.rawValue, defaultHostOS.rawValue)
    }

    private var logTypingText: String {
        #if DEBUG
        "\(logTyping)"
        #else
        "false"
        #endif
    }

    private func save(_ key: String, _ value: Any) {
        defaults.set(value, forKey: key)
    }
}

/// Non-linear (geometric) slider scale: slider position 0…1 ↔ value min…max, so that both
/// ends are equally controllable (each step is the same ratio).
struct SpeedScale: Sendable {
    let min: Double
    let max: Double
    let defaultValue: Double

    /// Pointer speed (PointerSettings.sensitivity, HID counts per point): 0.5…15, default 4.
    static let pointer = SpeedScale(min: 0.5, max: 15, defaultValue: 4)
    /// Scroll speed multiplier (1 = 10 pt per wheel step): 0.25…4, default 1.
    static let scroll = SpeedScale(min: 0.25, max: 4, defaultValue: 1)
    /// Clicker air-pointer sensitivity (× AirPointerSettings.baseGain = 1500 counts/rad): 0.25…4,
    /// default 2 (2026-11-18: 1 was too weak on the Mac; the user settled on 2).
    static let airPointer = SpeedScale(min: 0.25, max: 4, defaultValue: 2)

    func position(of value: Double) -> Double {
        let v = Swift.min(Swift.max(value, min), max)
        return log(v / min) / log(max / min)
    }

    func value(at position: Double) -> Double {
        let p = Swift.min(Swift.max(position, 0), 1)
        let raw = min * pow(max / min, p)
        // Round to 2 significant-ish digits so values are readable and repeatable.
        let step = raw < 1 ? 0.05 : raw < 5 ? 0.1 : 0.5
        return (raw / step).rounded() * step
    }
}
