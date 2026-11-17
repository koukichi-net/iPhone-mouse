import SwiftUI
import UIKit
import CoreBluetooth
import HIDCore

/// Owns the long-lived objects and the lifecycle logging. It is the only place that sets
/// the `BLEPeripheral` hooks, so no hook silently replaces another.
@MainActor
final class AppModel {
    let options = LaunchOptions.current
    let settings = AppSettings()
    let hosts: HostStore
    let peripheral: BLEPeripheral
    let input: InputController
    let keyboard: KeyboardController
    let clicker: ClickerController
    private var clickerProbe: ClickerProbe?
    private let namer: HostNamer
    private var named: Set<UUID> = []
    private var selfTest: SelfTestRunner?
    private var started = false
    private var observers: [NSObjectProtocol] = []

    init() {
        hosts = HostStore(settings: settings)
        namer = HostNamer(store: hosts)
        peripheral = BLEPeripheral(layout: .planA, localName: "HIDPad", logReports: options.logReports,
                                   pinnedCentral: options.activeCentral, dryRun: options.clickerProbe)
        input = InputController(peripheral: peripheral, settings: settings, logReports: options.logReports)
        keyboard = KeyboardController(peripheral: peripheral, input: input, logReports: options.logReports)
        input.keyboard = keyboard
        clicker = ClickerController(peripheral: peripheral, settings: settings, hosts: hosts)
        if options.show == "clicker" || options.clickerProbe {
            settings.clickerPreview = true   // shown without changing the saved setting
        }
        peripheral.willChangeActiveHost = { [weak self] in
            guard let self else { return }
            // The pointer's release (e.g. the arrow-pointer shortcut) goes to the old host
            // first; BLEPeripheral flushes it unpaced before the switch.
            self.clicker.endHold(reason: "active host change")
            self.input.reset(reason: "active host change")
            self.keyboard.releaseAll(reason: "active host change")
        }
        peripheral.didChangeActiveHost = { [weak self] id in
            guard let self else { return }
            if let id { self.hosts.ensure(id) }
            self.applyProfile(reason: "active host \(id.map(shortID) ?? "none")")
        }
        peripheral.didWriteLEDs = { [weak self] id, leds in
            guard let self else { return }
            self.hosts.ensure(id)
            self.hosts.noteLEDWrite(id, leds)
            if id == self.peripheral.activeHostID { self.applyProfile(reason: "LED write") }
        }
        peripheral.didSeeHost = { [weak self] id in
            guard let self else { return }
            self.hosts.ensure(id)
            if self.named.insert(id).inserted { self.namer.lookUp(id) }
        }
        applyProfile(reason: "launch")
    }

    /// The active host's profile drives the pointer engine and the KeyMap.
    func applyProfile(reason: String, log: Bool = true) {
        let profile = hosts.profile(peripheral.activeHostID)
        input.applySettings(settings.pointerSettings(for: profile), log: log)
        keyboard.keyMap = profile?.keyMap ?? KeyMap(layout: settings.defaultLayout, host: settings.defaultHostOS)
        keyboard.haptics = settings.haptics
        if keyboard.autoIMESwitch != settings.autoIMESwitch { keyboard.autoIMESwitch = settings.autoIMESwitch }
        if keyboard.cursorPadEnabled != settings.cursorPadArrows {
            keyboard.cursorPadEnabled = settings.cursorPadArrows
            Log.line("CURSORPAD setting: arrows \(settings.cursorPadArrows ? "on" : "off") (\(reason))")
        }
        if log {
            Log.line("PROFILE (\(reason)) \(profile?.summary ?? "defaults") keyMap=\(keyboard.keyMap.layout.rawValue)/\(keyboard.keyMap.host.rawValue)")
        }
    }

    /// The clicker screen was shown or hidden (setting, host menu, launch flag).
    func clickerModeChanged(_ on: Bool) {
        if on {
            input.reset(reason: "clicker mode on")
            keyboard.releaseAll(reason: "clicker mode on")
        } else {
            clicker.endHold(reason: "clicker mode off")
        }
        Log.line("CLICKER mode \(on ? "on" : "off") (saved=\(settings.clickerMode) preview=\(settings.clickerPreview)) slideKeys=\(settings.slideKeys.rawValue) host=\(peripheral.activeHostID.map(shortID) ?? "none") \(hosts.profile(peripheral.activeHostID).map { "laser=\($0.laserMethod.rawValue) os=\($0.hostOS.rawValue) air=\(String(format: "%.2f", $0.airSpeed))" } ?? "")")
    }

    func start() {
        guard !started else { return }
        started = true
        Log.line("START HIDPad iOS=\(UIDevice.current.systemVersion) args=\(Array(ProcessInfo.processInfo.arguments.dropFirst())) logReports=\(options.logReports) selftest=\(options.selfTests) activeCentral=\(options.activeCentral?.uuidString ?? "none") repeat=\(options.repeatSeconds)s auth=\(authName(CBManager.authorization))")
        Log.line("SETTINGS \(settings.summary)")
        for p in hosts.ordered { Log.line("HOST_PROFILE known \(p.id) \(p.summary)") }
        if !options.selfTests.isEmpty {
            let runner = SelfTestRunner(names: options.selfTests, options: options, input: input, keyboard: keyboard, peripheral: peripheral)
            selfTest = runner
            peripheral.didSubscribeMouse = { [weak runner] _ in runner?.mouseSubscribed() }
        }
        installLifecycleLogging()
        if settings.clickerActive {
            Log.line("CLICKER mode on at launch (saved=\(settings.clickerMode) preview=\(settings.clickerPreview)) slideKeys=\(settings.slideKeys.rawValue)")
        }
        if options.clickerProbe {
            let probe = ClickerProbe(clicker: clicker, peripheral: peripheral)
            clickerProbe = probe
            probe.start()
        }
        if options.readingProbe {
            for s in JapaneseReading.probeExamples {
                Log.line("READING \(s.debugDescription) -> \((JapaneseReading.reading(of: s) ?? "nil").debugDescription)")
            }
        }
        UIApplication.shared.isIdleTimerDisabled = true   // didBecomeActive may have fired before onAppear
        peripheral.start()
        Task { await heartbeat() }
    }

    private func appState() -> String {
        switch UIApplication.shared.applicationState {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "raw"
        }
    }

    private func installLifecycleLogging() {
        let names: [(Notification.Name, String)] = [
            (UIApplication.willResignActiveNotification, "willResignActive"),
            (UIApplication.didEnterBackgroundNotification, "didEnterBackground"),
            (UIApplication.willEnterForegroundNotification, "willEnterForeground"),
            (UIApplication.didBecomeActiveNotification, "didBecomeActive"),
            (UIApplication.willTerminateNotification, "willTerminate"),
            (UIApplication.didReceiveMemoryWarningNotification, "didReceiveMemoryWarning"),
        ]
        for (name, label) in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Log.line("LIFECYCLE \(label) appState=\(self.appState()) isAdvertising=\(self.peripheral.isAdvertising)")
                    switch label {
                    case "willResignActive":
                        UIApplication.shared.isIdleTimerDisabled = false
                        self.clicker.endHold(reason: "app resigning active")
                        self.input.reset(reason: "app resigning active")
                        self.keyboard.releaseAll(reason: "app resigning active")
                    case "didBecomeActive":
                        UIApplication.shared.isIdleTimerDisabled = true
                        self.keyboard.resetHostIME(reason: "app became active")
                    default:
                        break
                    }
                }
            })
        }
    }

    private func heartbeat() async {
        while true {
            try? await Task.sleep(for: .seconds(30))
            let p = peripheral
            let hosts = p.hosts.map { "\(shortID($0.id))[\($0.subscriptionText)]" }.joined(separator: " ")
            Log.line("HEARTBEAT appState=\(appState()) state=\(stateName(p.state)) adv=\(p.isAdvertising) hosts=\(p.hosts.count) {\(hosts)} active=\(p.activeHostID.map(shortID) ?? "none") leds=\(p.leds.rawValue) idleTimerDisabled=\(UIApplication.shared.isIdleTimerDisabled) battery=\(Int(UIDevice.current.batteryLevel * 100))% stats: \(p.stats.text)")
        }
    }
}

@main
struct HIDPadApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RemoteView(model: model)
                .onAppear { model.start() }
        }
    }
}
