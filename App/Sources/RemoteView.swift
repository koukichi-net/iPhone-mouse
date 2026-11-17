import SwiftUI
import UIKit
import HIDCore

/// Main screen (design §8.3), modelled on the layout of the Apple TV Remote: near-black,
/// one large rounded touch surface, host picker at the top centre, settings in a corner,
/// large round buttons below. The button area swaps to the key panel; the surface shrinks
/// but stays usable. Portrait, one-handed.
struct RemoteView: View {
    let model: AppModel
    @State private var panel: PanelPage?
    @State private var lastPage: PanelPage = .keys
    @State private var showSettings = false
    @State private var showHosts = false
    @State private var showSpeed = false

    var body: some View {
        VStack(spacing: 0) {
            TopBar(model: model, showSettings: $showSettings, showHosts: $showHosts, showSpeed: $showSpeed)
            if model.settings.clickerActive {
                // Clicker mode (design §8.5): no trackpad, buttons, key panel or text entry.
                ClickerScreen(model: model)
                    .overlay(alignment: .top) { NewcomerBanner(model: model) }
                    .transition(.opacity)
            } else {
            TrackpadView(input: model.input, strip: model.settings.scrollStrip)
                .overlay(alignment: .top) { NewcomerBanner(model: model) }
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .layoutPriority(0)
            if let page = panel {
                KeyPanel(model: model, page: Binding(get: { page }, set: { panel = $0; lastPage = $0 }),
                         close: { panel = nil })
                    .padding(.top, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                RemoteButtons(model: model, openKeyboard: { panel = lastPage })
                    .padding(.top, 18)
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }
            }
        }
        .animation(.easeOut(duration: 0.18), value: panel)
        .onChange(of: model.settings.clickerActive) { _, on in
            if on { panel = nil }
            model.clickerModeChanged(on)
        }
        .background(Theme.backgroundColor.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
        .onAppear {
            guard let show = model.options.show else { return }
            if let p = PanelPage(rawValue: show) { panel = p; lastPage = p }
            showSettings = show == "settings" || show == "settings-scroll" || show == "settings-cursorpad"
            showHosts = show == "hosts" || show == "hostdetail"
            showSpeed = show == "speed"
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(model: model)
        }
        .sheet(isPresented: $showHosts) {
            NavigationStack {
                HostsView(model: model, initialDetail: model.options.show == "hostdetail" ? model.hosts.ordered.first?.id : nil)
            }
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showSpeed) {
            SpeedSheet(model: model)
                .presentationDetents([.height(model.settings.clickerActive ? 300 : 250)])
                .presentationBackground(Color(white: 0.09))
                .preferredColorScheme(.dark)
        }
    }
}

// MARK: - Top bar

struct TopBar: View {
    let model: AppModel
    @Binding var showSettings: Bool
    @Binding var showHosts: Bool
    @Binding var showSpeed: Bool

    private var peripheral: BLEPeripheral { model.peripheral }

    var body: some View {
        ZStack {
            HStack {
                statusBadge
                Spacer()
                Button { Haptics.tap(model); showSettings = true } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(Color(white: 0.55))
                        .frame(width: 40, height: 40)
                }
                .accessibilityLabel("設定")
            }
            hostPicker
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
    }

    /// Bluetooth problems and Caps Lock, only when there is something to say.
    @ViewBuilder private var statusBadge: some View {
        HStack(spacing: 8) {
            if peripheral.state != .poweredOn {
                Label(peripheral.state == .unauthorized ? "許可なし" : "BT オフ", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } else if !peripheral.isAdvertising && peripheral.hosts.isEmpty {
                Label("準備中", systemImage: "hourglass").foregroundStyle(.orange)
            }
            if peripheral.leds.contains(.capsLock) {
                Image(systemName: "capslock.fill").foregroundStyle(.green).accessibilityLabel("Caps Lock オン")
            }
        }
        .font(.system(size: 12, weight: .medium))
        .labelStyle(.iconOnly)
        .frame(width: 40, alignment: .leading)
    }

    private var hostPicker: some View {
        Menu {
            let connected = peripheral.hosts.filter { $0.inputs.contains(.mouse) || $0.inputs.contains(.keyboard) }
            Section("接続中") {
                if connected.isEmpty {
                    Text("なし")
                }
                ForEach(connected) { h in
                    let p = model.hosts.profile(h.id)
                    Button {
                        peripheral.selectActiveHost(h.id, reason: "selected in host menu", byUser: true)
                    } label: {
                        if h.id == peripheral.activeHostID {
                            Label(model.hosts.displayName(h.id), systemImage: "checkmark")
                        } else {
                            Label(model.hosts.displayName(h.id), systemImage: p?.symbolName ?? "laptopcomputer")
                        }
                    }
                }
            }
            Section {
                if model.settings.clickerActive {
                    Button { showSpeed = true } label: { Label("感度…", systemImage: "speedometer") }
                } else {
                    Button { showSpeed = true } label: { Label("速さ…", systemImage: "speedometer") }
                }
                Button { showHosts = true } label: { Label("接続先の管理…", systemImage: "list.bullet") }
            }
            if model.settings.clickerActive {
                Section {
                    Button { model.settings.setClicker(false) } label: {
                        Label("クリッカーを終了", systemImage: "xmark.circle")
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(dotColor).frame(width: 7, height: 7)
                Text(model.hosts.displayName(peripheral.activeHostID))
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color(white: 0.55))
            }
            .foregroundStyle(Color(white: 0.92))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color(white: 0.13)))
            .frame(maxWidth: 270)
        }
        .accessibilityLabel("接続先: \(model.hosts.displayName(peripheral.activeHostID))")
    }

    private var dotColor: Color {
        if peripheral.state != .poweredOn { return .red }
        if peripheral.activeHostID != nil { return .green }
        return peripheral.isAdvertising ? .yellow : .orange
    }
}

// MARK: - Remote buttons

struct RemoteButtons: View {
    let model: AppModel
    let openKeyboard: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            // No captions: left / right click by position (as on a mouse), the keyboard by its
            // icon. The accessibility labels keep the names.
            HStack(alignment: .center, spacing: 26) {
                PressButton(symbol: "cursorarrow.click", accessibility: "左クリック", diameter: 76,
                            onDown: { model.input.setButton(.left, pressed: true) },
                            onUp: { model.input.setButton(.left, pressed: false) })
                PressButton(symbol: "keyboard", accessibility: "キーボード", diameter: 64,
                            onDown: { Haptics.tap(model) }, onUp: openKeyboard)
                PressButton(symbol: "cursorarrow.click.2", accessibility: "右クリック", diameter: 76,
                            onDown: { model.input.setButton(.right, pressed: true) },
                            onUp: { model.input.setButton(.right, pressed: false) })
            }
            HStack(spacing: 22) {
                media("backward.fill", "前のトラック", .scanPreviousTrack)
                media("playpause.fill", "再生／一時停止", .playPause)
                media("forward.fill", "次のトラック", .scanNextTrack)
                media("speaker.wave.1.fill", "音量を下げる", .volumeDecrement)
                media("speaker.wave.3.fill", "音量を上げる", .volumeIncrement)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func media(_ symbol: String, _ label: String, _ usage: ConsumerUsage) -> some View {
        PressButton(symbol: symbol, accessibility: label, diameter: 50,
                    onDown: { model.keyboard.mediaDown(usage) },
                    onUp: { model.keyboard.mediaUp(usage) })
    }
}

// MARK: - Key panel

enum PanelPage: String, CaseIterable, Identifiable {
    case keys, function, text, media
    var id: String { rawValue }
    var title: String {
        switch self {
        case .keys: "キー"
        case .function: "Fn"
        case .text: "文字入力"
        case .media: "メディア"
        }
    }
}

struct KeyPanel: View {
    let model: AppModel
    @Binding var page: PanelPage
    let close: () -> Void

    private var keyboard: KeyboardController { model.keyboard }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Picker("ページ", selection: $page) {
                    ForEach(PanelPage.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Button { Haptics.tap(model); close() } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 34, height: 32)
                        .background(Circle().fill(Color(white: 0.17)))
                        .foregroundStyle(Color(white: 0.85))
                }
                .accessibilityLabel("キーパネルを閉じる")
            }
            switch page {
            case .keys:
                grid([modifierRow] + KeyRows.keys)
            case .function:
                grid([modifierRow] + KeyRows.function)
            case .media:
                grid(KeyRows.media, rowHeight: 54)
            case .text:
                grid([modifierRow])
                TextEntryStrip(model: model)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, page == .text ? 6 : 10)
    }

    private var isWindows: Bool {
        (model.hosts.profile(model.peripheral.activeHostID)?.hostOS ?? model.settings.defaultHostOS) == .windows
    }

    private var modifierRow: [PanelKey] {
        if isWindows {
            return [
                PanelKey(action: .modifier(.shift), label: "Shift", symbol: "shift", width: 1.2),
                PanelKey(action: .modifier(.control), label: "Ctrl", width: 1.1),
                PanelKey(action: .modifier(.command), label: "Win", width: 1.1),
                PanelKey(action: .modifier(.option), label: "Alt", width: 1.1),
                PanelKey(action: .key(.capsLock), label: "Caps", symbol: "capslock"),
            ]
        }
        return [
            PanelKey(action: .modifier(.shift), label: "shift", symbol: "shift", width: 1.2),
            PanelKey(action: .modifier(.control), label: "control", symbol: "control", width: 1.1),
            PanelKey(action: .modifier(.option), label: "option", symbol: "option", width: 1.1),
            PanelKey(action: .modifier(.command), label: "command", symbol: "command", width: 1.1),
            PanelKey(action: .key(.capsLock), label: "caps", symbol: "capslock"),
        ]
    }

    private var looks: [PanelAction: KeyLook] {
        var l: [PanelAction: KeyLook] = [:]
        for m in PanelModifier.allCases {
            var look = KeyLook()
            switch keyboard.modifierStates[m] ?? .off {
            case .off: look.mode = .normal
            case .latched: look.mode = .latched
            case .locked: look.mode = .locked
            }
            look.held = keyboard.heldModifiers.contains(m)
            l[.modifier(m)] = look
        }
        l[.key(.capsLock)] = KeyLook(led: keyboard.capsLockOn)
        return l
    }

    private func grid(_ rows: [[PanelKey]], rowHeight: CGFloat = 46) -> some View {
        KeyGrid(rows: rows, looks: looks, rowHeight: rowHeight,
                onDown: { a in
                    switch a {
                    case .key(let u): keyboard.keyDown(u)
                    case .modifier(let m): keyboard.modifierDown(m)
                    case .media(let u): keyboard.mediaDown(u)
                    }
                },
                onUp: { a in
                    switch a {
                    case .key(let u): keyboard.keyUp(u)
                    case .modifier(let m): keyboard.modifierUp(m)
                    case .media(let u): keyboard.mediaUp(u)
                    }
                })
    }
}

enum KeyRows {
    static let keys: [[PanelKey]] = [
        [
            PanelKey(action: .key(.escape), label: "esc"),
            PanelKey(action: .key(.tab), label: "tab", symbol: "arrow.right.to.line"),
            PanelKey(action: .key(.lang2), label: "英数"),
            PanelKey(action: .key(.lang1), label: "かな"),
            PanelKey(action: .key(.backspace), label: "delete", symbol: "delete.left"),
            PanelKey(action: .key(.deleteForward), label: "del", symbol: "delete.right"),
        ],
        [
            PanelKey(action: .key(.home), label: "home"),
            PanelKey(action: .key(.pageUp), label: "pg up"),
            PanelKey(action: .key(.upArrow), label: "", symbol: "arrowtriangle.up.fill"),
            PanelKey(action: .key(.pageDown), label: "pg dn"),
            PanelKey(action: .key(.returnKey), label: "return", symbol: "return", width: 1.4),
        ],
        [
            PanelKey(action: .key(.end), label: "end"),
            PanelKey(action: .key(.leftArrow), label: "", symbol: "arrowtriangle.left.fill"),
            PanelKey(action: .key(.downArrow), label: "", symbol: "arrowtriangle.down.fill"),
            PanelKey(action: .key(.rightArrow), label: "", symbol: "arrowtriangle.right.fill"),
            PanelKey(action: .key(.space), label: "space", width: 1.4),
        ],
    ]

    static let function: [[PanelKey]] = [
        (1...6).map { PanelKey(action: .key(KeyUsage.function($0)!), label: "F\($0)") },
        (7...12).map { PanelKey(action: .key(KeyUsage.function($0)!), label: "F\($0)") },
    ]

    static let media: [[PanelKey]] = [
        [
            PanelKey(action: .media(.scanPreviousTrack), label: "前へ", symbol: "backward.fill"),
            PanelKey(action: .media(.playPause), label: "再生／停止", symbol: "playpause.fill"),
            PanelKey(action: .media(.scanNextTrack), label: "次へ", symbol: "forward.fill"),
        ],
        [
            PanelKey(action: .media(.mute), label: "消音", symbol: "speaker.slash.fill"),
            PanelKey(action: .media(.volumeDecrement), label: "音量 −", symbol: "speaker.wave.1.fill"),
            PanelKey(action: .media(.volumeIncrement), label: "音量 ＋", symbol: "speaker.wave.3.fill"),
        ],
    ]
}

// MARK: - Text entry

/// Shown above the iOS keyboard on the 文字入力 page: an echo of what was sent, the
/// "could not send" notice, and paste-and-type.
struct TextEntryStrip: View {
    let model: AppModel
    @State private var pasted: String?
    @State private var tooLong = false

    private var keyboard: KeyboardController { model.keyboard }
    static let pasteLimit = 2000
    /// `--cursorpad-visible`: show the capture field and its pad (diagnostics, screenshots).
    static let padVisible = ProcessInfo.processInfo.arguments.contains("--cursorpad-visible")

    var body: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.13))
                // The capture field is invisible (its text is the cursor pad around what was
                // typed); the labels below show the composition, hints and the echo.
                KeyCapture(active: true,
                           columnsPerStep: model.settings.cursorPadColumnsPerStep,
                           handle: { keyboard.handleCapture($0, language: $1) },
                           arrowRoom: { keyboard.arrowRoom($0) },
                           onModeChange: { keyboard.textModeChanged($0, source: $1) },
                           onText: { keyboard.noteFieldText($0) })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .modifier(PadClip(visible: Self.padVisible))
                // Taps never reach the field (a tap would move its caret = arrow keys).
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { CaptureTextView.focusFromTap() }
                Group {
                    if !keyboard.fieldText.isEmpty {
                        // The composition (or text not yet cleared).
                        Text(keyboard.fieldText.replacingOccurrences(of: "\n", with: "⏎"))
                            .foregroundStyle(.white).truncationMode(.head)
                    } else if let hint = keyboard.hint {
                        Text(hint).foregroundStyle(.orange)
                    } else if let arrows = keyboard.arrowNotice {
                        Text(arrows).foregroundStyle(Color(white: 0.75))
                    } else if let notice = keyboard.skippedNotice {
                        Text(notice).foregroundStyle(.orange)
                    } else if keyboard.pasteRemaining > 0 {
                        Text("入力中… \(keyboard.pasteRemaining)").foregroundStyle(Color(white: 0.6))
                    } else if KeyboardInputMode(primaryLanguage: keyboard.keyboardLanguage) == .japanese {
                        // Japanese: the host composes the same reading; it converts and commits.
                        if keyboard.capturedEcho.isEmpty {
                            Text("かな → 接続先").foregroundStyle(Color(white: 0.4))
                        } else {
                            Text("確定: \(keyboard.capturedEcho)").foregroundStyle(Color(white: 0.55)).truncationMode(.head)
                        }
                    } else if keyboard.echo.isEmpty {
                        Text("文字 → 接続先").foregroundStyle(Color(white: 0.4))
                    } else {
                        Text(keyboard.echo).foregroundStyle(Color(white: 0.75)).truncationMode(.head)
                    }
                }
                .font(.system(size: 13, design: .monospaced))
                .lineLimit(1)
                .padding(.leading, 10)
                .padding(.trailing, model.settings.autoIMESwitch ? 52 : 10)
                .allowsHitTesting(false)
                if model.settings.autoIMESwitch {
                    HostModeTag(mode: keyboard.assumedHostMode)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 6)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 36)
            PasteButton(payloadType: String.self) { strings in
                let text = strings.joined()
                Task { @MainActor in
                    if text.count > Self.pasteLimit { tooLong = true } else if !text.isEmpty { pasted = text }
                }
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.circle)
            .tint(Color(white: 0.25))
            .accessibilityLabel("ペーストして入力")
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { pasted != nil }, set: { if !$0 { pasted = nil } }),
                            titleVisibility: .visible) {
            Button("入力する") {
                if let t = pasted { keyboard.typePasted(t) }
                pasted = nil
            }
            Button("キャンセル", role: .cancel) { pasted = nil }
        }
        .alert("長すぎます", isPresented: $tooLong) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("\(Self.pasteLimit) 文字まで")
        }
    }

    private var confirmTitle: String {
        guard let t = pasted else { return "" }
        let c = keyboard.typableCount(t)
        var s = "\(c.typable) 文字を入力"
        if c.lines > 0 { s += "（改行 \(c.lines)）" }
        if c.skipped > 0 { s += "・送れない \(c.skipped) 文字は省略" }
        return s
    }
}

/// Clips the capture field to the strip (it is taller than the strip), unless it is shown
/// for diagnostics.
private struct PadClip: ViewModifier {
    let visible: Bool
    func body(content: Content) -> some View {
        if visible { content } else { content.clipShape(RoundedRectangle(cornerRadius: 10)) }
    }
}

/// The host input mode the text field assumes (かな / 英数), shown small at the field's end.
struct HostModeTag: View {
    let mode: HostIMEMode

    var body: some View {
        Text(mode == .kana ? "かな" : mode == .eisu ? "英数" : "－")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(mode == .unknown ? Color(white: 0.4) : Color(white: 0.7))
            .frame(width: 38, height: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.2)))
            .accessibilityLabel(mode == .kana ? "接続先はかな入力と推定" : mode == .eisu ? "接続先は英数入力と推定" : "接続先の入力モードは不明")
    }
}

// MARK: - Newcomer banner

/// Brief, non-interactive note that another host connected while input stays where it is.
struct NewcomerBanner: View {
    let model: AppModel

    var body: some View {
        if let id = model.peripheral.newcomerNotice, id != model.peripheral.activeHostID {
            Text("\(model.hosts.displayName(id)) が接続")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(white: 0.75))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color(white: 0.2)))
                .padding(.top, 10)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }
}

// MARK: - Haptics

@MainActor
enum Haptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    static func tap(_ model: AppModel) {
        if model.settings.haptics { light.impactOccurred(intensity: 0.6) }
    }
}
