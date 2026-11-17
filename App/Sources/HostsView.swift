import SwiftUI
import CoreBluetooth
import HIDCore

// Hosts list, per-host profile, settings and the quick speed sheet (design §8.3; per-host
// profiles bring part of M4 forward). UI text is Japanese.

// MARK: - Hosts list

struct HostsView: View {
    let model: AppModel
    var initialDetail: UUID? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var detail: UUID?

    private var peripheral: BLEPeripheral { model.peripheral }

    var body: some View {
        let connectedIDs = Set(peripheral.hosts.map(\.id))
        let connected = model.hosts.ordered.filter { connectedIDs.contains($0.id) }
        let known = model.hosts.ordered.filter { !connectedIDs.contains($0.id) }
        List {
            Section("接続中") {
                if connected.isEmpty {
                    Text("なし").foregroundStyle(.secondary)
                }
                ForEach(connected) { p in
                    HostRow(model: model, profile: p, connected: true, showDetail: { detail = p.id })
                }
            }
            if !known.isEmpty {
                Section("以前の接続先") {
                    ForEach(known) { p in
                        HostRow(model: model, profile: p, connected: false, showDetail: { detail = p.id })
                            .swipeActions {
                                Button("削除", role: .destructive) { model.hosts.remove(p.id) }
                            }
                    }
                }
            }
            Section("Bluetooth") {
                row("状態", stateText)
                row("アドバタイズ", peripheral.isAdvertising ? "中（HIDPad）" : "停止")
                if let p = peripheral.setupProblem { row("問題", p) }
                row("LED", ledText)
            }
            Section("新しい接続先") {
                Text("接続先の Bluetooth 設定で「HIDPad」を選びます。")
                Text("再ペアリングの前に両側の古い登録を削除")
                Text("この Mac では「このデバイスを削除」をしない")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .navigationTitle("接続先")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完了") { dismiss() } } }
        .navigationDestination(item: $detail) { id in HostDetailView(model: model, id: id) }
        .onAppear { if detail == nil, let d = initialDetail { detail = d } }
    }

    private var stateText: String {
        switch peripheral.state {
        case .poweredOn: "オン"
        case .poweredOff: "オフ"
        case .unauthorized: "許可されていません"
        case .unsupported: "非対応"
        case .resetting: "リセット中"
        default: "不明"
        }
    }

    private var ledText: String {
        let l = peripheral.leds
        let on = [("Num", KeyboardLEDs.numLock), ("Caps", .capsLock), ("Scroll", .scrollLock), ("Compose", .compose), ("Kana", .kana)]
            .filter { l.contains($0.1) }.map(\.0)
        return on.isEmpty ? "すべて消灯" : on.joined(separator: " ")
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k); Spacer(); Text(v).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
    }
}

/// Edits the host's name. Shows the custom name, else the Bluetooth name, as real text;
/// typing the Bluetooth name back (or clearing the field) removes the custom name.
@MainActor
func nameBinding(_ model: AppModel, _ id: UUID) -> Binding<String> {
    Binding(
        get: { model.hosts.profile(id).map { $0.customName ?? $0.autoName ?? "" } ?? "" },
        set: { v in
            let t = v.trimmingCharacters(in: .whitespaces)
            model.hosts.update(id) { $0.customName = (t.isEmpty || t == $0.autoName) ? nil : v }
        })
}

struct HostRow: View {
    let model: AppModel
    let profile: HostProfile
    let connected: Bool
    let showDetail: () -> Void

    var body: some View {
        let active = model.peripheral.activeHostID == profile.id
        let info = model.peripheral.hosts.first { $0.id == profile.id }
        HStack(spacing: 12) {
            Image(systemName: profile.symbolName)
                .font(.system(size: 20))
                .frame(width: 30)
                .foregroundStyle(connected ? Color.primary : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                TextField(profile.placeholderName, text: nameBinding(model, profile.id))
                    .font(.body)
                    .foregroundStyle(connected ? Color.primary : Color.secondary)
                    .submitLabel(.done)
                Text(subtitle(info))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if connected {
                Button {
                    model.peripheral.selectActiveHost(profile.id, reason: "selected in hosts list", byUser: true)
                } label: {
                    Image(systemName: active ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundStyle(active ? Color.green : Color.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(active ? "選択中" : "この接続先を選ぶ")
                .disabled(info.map { !$0.inputs.contains(.mouse) && !$0.inputs.contains(.keyboard) } ?? true)
            }
            Button(action: showDetail) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 17))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("接続先ごとの設定")
        }
        .opacity(connected ? 1 : 0.55)
    }

    private func subtitle(_ info: HostInfo?) -> String {
        var parts = [shortID(profile.id)]
        parts.append(connected ? "接続中" : "未接続")
        parts.append("\(profile.layout == .jis ? "JIS" : "US")・\(profile.hostOS == .macOS ? "macOS" : "Windows")")
        if profile.customName != nil, let n = profile.autoName { parts.append(n) }
        return parts.joined(separator: "  ")
    }
}

// MARK: - Per-host profile

struct HostDetailView: View {
    let model: AppModel
    let id: UUID

    var body: some View {
        if let p = model.hosts.profile(id) {
            Form {
                Section("名前") {
                    TextField(p.placeholderName, text: nameBinding(model, id))
                    if let n = p.autoName { LabeledContent("Bluetooth 上の名前", value: n) }
                    LabeledContent("ID") { Text(id.uuidString).font(.system(size: 11, design: .monospaced)).textSelection(.enabled) }
                }
                Section("ポインタ") {
                    SpeedSlider(title: "ポインタの速さ", scale: .pointer, value: binding(\.pointerSpeed), onEnd: { apply() })
                    SpeedSlider(title: "スクロールの速さ", scale: .scroll, value: binding(\.scrollSpeed), onEnd: { apply() })
                }
                Section {
                    ClickerHostRows(model: model, id: id)
                } header: {
                    Text("クリッカー")
                } footer: {
                    ClickerHostWarning(profile: p)
                }
                Section {
                    Picker("キー配列", selection: Binding(get: { model.hosts.profile(id)?.layout ?? .jis },
                                                       set: { v in model.hosts.update(id) { $0.layout = v }; apply() })) {
                        Text("JIS（日本語）").tag(KeyboardLayout.jis)
                        Text("US（英語）").tag(KeyboardLayout.us)
                    }
                    Picker("接続先の OS", selection: Binding(get: { model.hosts.profile(id)?.hostOS ?? .macOS },
                                                         set: { v in model.hosts.update(id) { $0.hostOS = v }; apply() })) {
                        Text("macOS").tag(HostOS.macOS)
                        Text("Windows").tag(HostOS.windows)
                    }
                } header: {
                    Text("キーボード")
                } footer: {
                    Text("記号が違うときは US／JIS を切り替え")
                }
            }
            .navigationTitle(p.displayName)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            Text("この接続先は削除されました").foregroundStyle(.secondary)
        }
    }

    private func binding(_ kp: WritableKeyPath<HostProfile, Double>) -> Binding<Double> {
        Binding(get: { model.hosts.profile(id)?[keyPath: kp] ?? 1 },
                set: { v in
                    model.hosts.update(id) { $0[keyPath: kp] = v }
                    if model.peripheral.activeHostID == id { model.applyProfile(reason: "slider", log: false) }
                })
    }

    private func apply() {
        if model.peripheral.activeHostID == id { model.applyProfile(reason: "host settings changed") }
    }
}

/// Labelled slider on a geometric scale; applies on every change (`value` setter), `onEnd`
/// when the finger lifts.
struct SpeedSlider: View {
    let title: String
    let scale: SpeedScale
    @Binding var value: Double
    var onEnd: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: value < 1 ? "%.2f" : "%.1f", value))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                if abs(value - scale.defaultValue) > 0.001 {
                    Button("標準") { value = scale.defaultValue; onEnd() }
                        .font(.caption)
                        .buttonStyle(.borderless)
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "tortoise.fill").foregroundStyle(.secondary).font(.caption)
                Slider(value: Binding(get: { scale.position(of: value) },
                                      set: { value = scale.value(at: $0) }),
                       in: 0...1,
                       onEditingChanged: { editing in if !editing { onEnd() } })
                    .accessibilityValue(String(format: "%.1f", value))
                Image(systemName: "hare.fill").foregroundStyle(.secondary).font(.caption)
            }
        }
    }
}

// MARK: - Quick speed sheet (from the host menu)

struct SpeedSheet: View {
    let model: AppModel

    var body: some View {
        if model.settings.clickerActive {
            clickerBody
        } else {
            speedBody
        }
    }

    /// Clicker mode: the active host's air-pointer sensitivity and method.
    @ViewBuilder private var clickerBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let id = model.peripheral.activeHostID, model.hosts.profile(id) != nil {
                Text("\(model.hosts.displayName(id)) のポインター").font(.headline)
                ClickerHostRows(model: model, id: id)
            } else {
                Text("接続先なし").font(.headline)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
    }

    private var speedBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(model.peripheral.activeHostID == nil ? "標準の速さ" : "\(model.hosts.displayName(model.peripheral.activeHostID)) の速さ")
                .font(.headline)
            SpeedSlider(title: "ポインタ", scale: .pointer, value: binding(\.pointerSpeed, \.defaultPointerSpeed), onEnd: { done() })
            SpeedSlider(title: "スクロール", scale: .scroll, value: binding(\.scrollSpeed, \.defaultScrollSpeed), onEnd: { done() })
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
    }

    /// The active host's value, or the global default when there is no active host.
    private func binding(_ kp: WritableKeyPath<HostProfile, Double>, _ global: ReferenceWritableKeyPath<AppSettings, Double>) -> Binding<Double> {
        Binding(
            get: {
                if let id = model.peripheral.activeHostID, let p = model.hosts.profile(id) { return p[keyPath: kp] }
                return model.settings[keyPath: global]
            },
            set: { v in
                if let id = model.peripheral.activeHostID, model.hosts.profile(id) != nil {
                    model.hosts.update(id) { $0[keyPath: kp] = v }
                } else {
                    model.settings[keyPath: global] = v
                }
                model.applyProfile(reason: "speed sheet", log: false)
            })
    }

    private func done() { model.applyProfile(reason: "speed sheet") }
}

// MARK: - Settings

struct SettingsView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var settings = model.settings
        NavigationStack {
            ScrollViewReader { proxy in
            Form {
                Section {
                    Toggle("クリッカーモード", isOn: Binding(get: { settings.clickerActive }, set: { settings.setClicker($0) }))
                    Picker("スライド送りのキー", selection: $settings.slideKeys) {
                        ForEach(SlideKeys.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    if let id = model.peripheral.activeHostID, let p = model.hosts.profile(id) {
                        ClickerHostRows(model: model, id: id)
                        ClickerHostWarning(profile: p)
                            .font(.footnote)
                    }
                } header: {
                    Text("クリッカー")
                }
                if let id = model.peripheral.activeHostID, model.hosts.profile(id) != nil {
                    Section {
                        SpeedSheetRows(model: model, id: id)
                    } header: {
                        Text("\(model.hosts.displayName(id)) の速さ")
                    }
                }
                Section {
                    NavigationLink { HostsView(model: model) } label: {
                        Label("接続先の管理", systemImage: "laptopcomputer.and.iphone")
                    }
                }
                Section("トラックパッド") {
                    VStack(alignment: .leading) {
                        Text("加速 \(String(format: "%.2f", settings.acceleration))")
                        Slider(value: $settings.acceleration, in: AppSettings.accelerationRange, step: 0.05)
                    }
                    Toggle("タップでクリック", isOn: $settings.tapToClick)
                    Toggle("スクロールの向きを反転", isOn: $settings.invertScroll)
                    Toggle("ボタンを押したときの振動", isOn: $settings.haptics)
                }
                Section {
                    Picker("スクロール帯", selection: $settings.scrollStripEdge) {
                        Text("右端").tag(ScrollStripEdge.right)
                        Text("左端").tag(ScrollStripEdge.left)
                        Text("なし").tag(ScrollStripEdge.off)
                    }
                    if settings.scrollStripEdge != .off {
                        VStack(alignment: .leading) {
                            Text("帯の幅 \(Int(settings.scrollStripWidth)) pt")
                            Slider(value: $settings.scrollStripWidth, in: ScrollStripLayout.widthRange, step: 2)
                        }
                    }
                    Toggle("スクロールの慣性", isOn: $settings.scrollInertia)
                } header: {
                    Text("スクロール")
                        .id("scrollSection")
                }
                Section {
                    Toggle("日本語入力を自動で切り替える", isOn: $settings.autoIMESwitch)
                    Toggle("空白キー長押しで矢印キー", isOn: $settings.cursorPadArrows)
                    if settings.cursorPadArrows {
                        Picker("カーソル移動の感度", selection: $settings.cursorPadColumnsPerStep) {
                            Text("1文字で1回").tag(1)
                            Text("2文字で1回").tag(2)
                        }
                    }
                    #if DEBUG
                    Toggle("入力内容のログ（診断用）", isOn: $settings.logTyping)
                    #endif
                } header: {
                    Text("文字入力")
                        .id("textSection")
                } footer: {
                    #if DEBUG
                    Text(settings.logTyping ? "接続先はローマ字入力にしてください。ログに打った文字が残ります。" : "接続先はローマ字入力にしてください。")
                    #else
                    Text("接続先はローマ字入力にしてください。")
                    #endif
                }
                Section {
                    SpeedSlider(title: "ポインタの速さ", scale: .pointer, value: $settings.defaultPointerSpeed)
                    SpeedSlider(title: "スクロールの速さ", scale: .scroll, value: $settings.defaultScrollSpeed)
                    Picker("キー配列", selection: $settings.defaultLayout) {
                        Text("JIS（日本語）").tag(KeyboardLayout.jis)
                        Text("US（英語）").tag(KeyboardLayout.us)
                    }
                    Picker("接続先の OS", selection: $settings.defaultHostOS) {
                        Text("macOS").tag(HostOS.macOS)
                        Text("Windows").tag(HostOS.windows)
                    }
                } header: {
                    Text("新しい接続先の初期値")
                }
                Section {
                    Button("初期設定に戻す") { settings.resetToDefaults() }
                }
            }
            #if DEBUG
            .onAppear {
                // `--show=settings-scroll` / `settings-cursorpad`: start at the scroll / text
                // entry section (for screenshots).
                let anchor = ["settings-scroll": "scrollSection", "settings-cursorpad": "textSection"][model.options.show ?? ""]
                if let anchor {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { proxy.scrollTo(anchor, anchor: .top) }
                }
            }
            #endif
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完了") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .onChange(of: settings.summary) { _, _ in model.applyProfile(reason: "settings changed", log: false) }
        .onDisappear { model.applyProfile(reason: "settings closed") }
    }
}

/// Pointer and scroll speed of one host, as rows in a Form.
struct SpeedSheetRows: View {
    let model: AppModel
    let id: UUID

    var body: some View {
        SpeedSlider(title: "ポインタの速さ", scale: .pointer, value: binding(\.pointerSpeed), onEnd: { model.applyProfile(reason: "settings speed") })
        SpeedSlider(title: "スクロールの速さ", scale: .scroll, value: binding(\.scrollSpeed), onEnd: { model.applyProfile(reason: "settings speed") })
    }

    private func binding(_ kp: WritableKeyPath<HostProfile, Double>) -> Binding<Double> {
        Binding(get: { model.hosts.profile(id)?[keyPath: kp] ?? 1 },
                set: { v in
                    model.hosts.update(id) { $0[keyPath: kp] = v }
                    if model.peripheral.activeHostID == id { model.applyProfile(reason: "slider", log: false) }
                })
    }
}

// MARK: - Clicker per-host rows

/// ポインターの出し方 and ポインターの感度 of one host (design §8.5).
struct ClickerHostRows: View {
    let model: AppModel
    let id: UUID

    var body: some View {
        Picker("ポインターの出し方", selection: Binding(get: { model.hosts.profile(id)?.laserMethod ?? .powerPointToggle },
                                                set: { v in
                                                    model.hosts.update(id) { $0.laserMethod = v }
                                                    Log.line("CLICKER setting laser method=\(v.rawValue) host=\(shortID(id))")
                                                })) {
            ForEach(LaserMethod.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        SpeedSlider(title: "ポインターの感度", scale: .airPointer,
                    value: Binding(get: { model.hosts.profile(id)?.airSpeed ?? SpeedScale.airPointer.defaultValue },
                                   set: { v in model.hosts.update(id) { $0.airSpeed = v } }),
                    onEnd: { Log.line(String(format: "CLICKER setting sensitivity=%.2f host=%@", model.hosts.profile(id)?.airSpeed ?? SpeedScale.airPointer.defaultValue, shortID(id))) })
    }
}

/// Warning for Ctrl＋左ボタン on a Mac (nothing otherwise).
struct ClickerHostWarning: View {
    let profile: HostProfile

    var body: some View {
        if profile.laserMethod == .controlLeftButton && profile.hostOS == .macOS {
            Text("Windows 用です（Mac では右クリックになります）").foregroundStyle(.orange)
        }
    }
}
