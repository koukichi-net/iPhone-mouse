import Foundation
import HIDCore

/// Launch arguments: `--log-reports`, `--selftest=pointer[,burst][,keys][,text]`, `--repeat=<s>`,
/// `--active-central=<uuid>`, `--text-layout=us|jis`.
struct LaunchOptions: Sendable {
    var logReports = false
    var selfTests: [String] = []
    var repeatSeconds: Double = 0
    /// `--active-central=<uuid>`: only this central ever becomes the active host automatically
    /// (for automated tests with more than one bonded host).
    var activeCentral: UUID?
    /// `--text-layout=us|jis`: KeyMap layout for `--selftest=text` only (host macOS).
    var textLayout: KeyboardLayout?
    /// `--show=keys|function|text|media|settings|settings-scroll|settings-cursorpad|hosts|hostdetail|speed|clicker`: open that panel or sheet at
    /// launch (for screenshots with `devicectl device capture screenshot`).
    var show: String?
    /// `--textcap-probe`: the text field marks "かな" programmatically ~1 s after focus and
    /// unmarks it ~8 s later, to check the TEXTCAP callbacks without the keyboard; from ~10 s
    /// it moves the caret in the cursor pad (programmatic selection and floating cursor) and
    /// logs the arrow keys it would send (CURSORPAD). Nothing from the field reaches the router
    /// or the host while it is set. (`--cursorpad-visible` shows the field and its pad.)
    var textCapProbe = false
    /// `--reading-probe`: log the on-device reading (JapaneseReading) of fixed examples.
    var readingProbe = false
    /// `--clicker-probe`: no-send clicker probe. The BLE layer never hands an input report to
    /// CoreBluetooth in this process (reports are logged as `WOULD_SEND`); the probe drives
    /// next/previous taps and pointer holds (synthetic rotation, then the real gyro at rest)
    /// through the clicker pipeline. Shows the clicker screen without saving the setting.
    var clickerProbe = false

    static let current: LaunchOptions = {
        let args = ProcessInfo.processInfo.arguments.dropFirst()
        func value(_ name: String) -> String? {
            args.first { $0.hasPrefix("--\(name)=") }.map { String($0.dropFirst(name.count + 3)) }
        }
        var o = LaunchOptions()
        o.logReports = args.contains("--log-reports")
        o.selfTests = value("selftest").map { $0.split(separator: ",").map(String.init) } ?? []
        o.repeatSeconds = value("repeat").flatMap(Double.init) ?? 0
        o.activeCentral = value("active-central").flatMap(UUID.init(uuidString:))
        o.textLayout = value("text-layout").flatMap(KeyboardLayout.init(rawValue:))
        o.show = value("show")
        o.textCapProbe = args.contains("--textcap-probe")
        o.readingProbe = args.contains("--reading-probe")
        o.clickerProbe = args.contains("--clicker-probe")
        return o
    }()
}

/// Line logger to stdout (unbuffered, so `devicectl … --console` sees lines at once).
enum Log {
    nonisolated(unsafe) private static var started = false
    /// 入力内容をログに記録する（診断用）. When false (the default), typed text never reaches
    /// the log: `q` gives only lengths and `notes` hides every quoted literal.
    @MainActor static var recordTyping = false

    /// Typed text for a log line: quoted, or only its length when recording is off.
    @MainActor static func q(_ s: String) -> String { recordTyping ? s.debugDescription : "<\(s.count) chars>" }

    /// Free-form notes that may quote typed text (IME notes, mirror reasons): as they are, or
    /// with every quoted literal replaced by "…" when recording is off.
    @MainActor static func notes(_ s: String) -> String { recordTyping ? s : LogRedaction.quoted(s) }

    private static let t0 = Date()

    @MainActor static func line(_ s: String) {
        if !started {
            setvbuf(stdout, nil, _IONBF, 0)
            started = true
        }
        let now = Date()
        var secs = time_t(now.timeIntervalSince1970)
        var parts = tm()
        localtime_r(&secs, &parts)
        let ms = Int(now.timeIntervalSince1970.truncatingRemainder(dividingBy: 1) * 1000)
        print(String(format: "[HP %02d:%02d:%02d.%03d +%8.3f] ", parts.tm_hour, parts.tm_min, parts.tm_sec, ms,
                     now.timeIntervalSince(t0)) + s)
    }
}

func hexString(_ bytes: some Sequence<UInt8>) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

func shortID(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }

extension OutgoingReport {
    /// Human-readable value, for SEND lines.
    var logText: String {
        switch self {
        case .mouse(let r):
            "mouse buttons=\(r.buttons.rawValue) x=\(r.x) y=\(r.y) wheel=\(r.wheel) pan=\(r.pan)"
        case .keyboard(let r):
            "keyboard mods=0x\(String(format: "%02X", r.modifiers.rawValue)) keys=\(r.keys.map(\.description))"
        case .consumer(let r):
            "consumer usage=\(r.usage)"
        }
    }
}

extension PointerAction {
    var logText: String {
        switch self {
        case .buttons(let b): "buttons=\(b.rawValue)"
        case .move(let dx, let dy): "move dx=\(dx) dy=\(dy)"
        case .scroll(let w, let p): "scroll wheel=\(w) pan=\(p)"
        }
    }
}
