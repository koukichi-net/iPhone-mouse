import Foundation
import HIDCore

// Key self-tests (design §11.2, safety rules §11.3).
//
// `keys` — safe without seize: F13 down/up, Left Shift alone down/up, Caps Lock exactly twice
//   (always twice, whatever the LED does, so the host's Caps state ends where it started).
//   Checks that LED output writes arrive and that the app's Caps state follows them.
// `kana` — only under a proven seize: a fixed kana corpus through the text-field conversion
//   (auto かな/英数 off), checked like `text` (Space also forbidden).
// `lang` — one-off, unseized: かな alone, then 英数 alone (input-source check, §11.3 exception).
// `text` — only under a proven seize. It proves the seize itself before typing: it sends an
//   F13 probe and waits for the seize token, an LED output write of `seizeToken` that
//   `mac-connect monitor --seize --ack-f13` makes only after it received that F13 on the
//   seized device while no system key event appeared. No token: nothing is typed.
//   Then it types every printable ASCII character (0x20–0x7E) the KeyMap can produce, after
//   checking every report: modifiers only Shift/Option, keys only those of printable
//   characters (never Return, Tab, Esc, Delete, arrows, F-keys, Caps Lock).

/// LED output value the monitor writes to acknowledge a proven seize: Num+Scroll+Compose+Kana
/// without Caps, a combination no host sets on its own.
let seizeToken = KeyboardLEDs(rawValue: 0x1D)

extension SelfTestRunner {
    // MARK: keys

    func runKeys(run n: Int) async -> Bool {
        input.setSelfTestPlaying(true)
        defer { input.setSelfTestPlaying(false) }
        await waitIdle(seconds: 1)
        let before = peripheral.stats
        let leds0 = peripheral.leds
        let writes0 = peripheral.ledWriteCount
        Log.line("KEYS #\(n) begin host=\(peripheral.activeHostID?.uuidString ?? "none") leds=0x\(hex(leds0.rawValue)) capsApp=\(keyboard.capsLockOn) keyMap=\(keyboard.keyMap.layout.rawValue)/\(keyboard.keyMap.host.rawValue)")

        let safe: Set<KeyUsage> = Set((13...20).compactMap { KeyUsage.function($0) } + [.capsLock, .leftShift])
        func press(_ u: KeyUsage, holdMs: Int, label: String) async {
            precondition(safe.contains(u), "unsafe key in keys self-test")
            let down = keyboard.selfTestKeyDown(u)
            Log.line("KEYS #\(n) \(label) down -> \(down.map { OutgoingReport.keyboard($0).logText })")
            try? await Task.sleep(for: .milliseconds(holdMs))
            let up = keyboard.selfTestKeyUp(u)
            Log.line("KEYS #\(n) \(label) up -> \(up.map { OutgoingReport.keyboard($0).logText })")
            await waitIdle(seconds: 1)
        }

        await press(.f13, holdMs: 120, label: "F13")
        try? await Task.sleep(for: .milliseconds(400))
        await press(.leftShift, holdMs: 120, label: "LeftShift")
        try? await Task.sleep(for: .milliseconds(400))

        var results: [String] = []
        for i in 1...2 {
            let wantCaps = i == 1 ? !leds0.contains(.capsLock) : leds0.contains(.capsLock)
            let w0 = peripheral.ledWriteCount
            await press(.capsLock, holdMs: 150, label: "CapsLock#\(i)")
            let t0 = Date()
            var arrived = false
            while Date().timeIntervalSince(t0) < 2.5 {
                if peripheral.ledWriteCount > w0, peripheral.leds.contains(.capsLock) == wantCaps { arrived = true; break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            let appCaps = keyboard.capsLockOn
            let ok = arrived && appCaps == wantCaps
            results.append("caps#\(i)=\(ok ? "ok" : "FAIL")")
            Log.line("KEYS #\(n) CapsLock#\(i) expect caps=\(wantCaps) ledWrite=\(arrived ? "arrived after \(ms)ms" : "NONE within 2500ms") leds=0x\(hex(peripheral.leds.rawValue)) writes+\(peripheral.ledWriteCount - w0) appCaps=\(appCaps) -> \(ok ? "OK" : "FAIL")")
            try? await Task.sleep(for: .milliseconds(400))
        }
        _ = keyboard.selfTestRelease()
        await waitIdle(seconds: 1)
        let d = peripheral.stats - before
        Log.line("KEYS #\(n) end \(results.joined(separator: " ")) ledWrites=\(peripheral.ledWriteCount - writes0) finalLeds=0x\(hex(peripheral.leds.rawValue)) capsRestored=\(peripheral.leds.contains(.capsLock) == leds0.contains(.capsLock)) sent: \(d.text) realEventsIgnored=\(input.ignoredRealEvents)")
        return true
    }

    // MARK: text

    func runText(run n: Int) async -> Bool {
        input.setSelfTestPlaying(true)
        defer { input.setSelfTestPlaying(false) }
        await waitIdle(seconds: 1)
        guard let host = peripheral.activeHostID, options.activeCentral == host else {
            Log.line("TEXT #\(n) refused: --active-central must be set and active (active=\(peripheral.activeHostID?.uuidString ?? "none"))")
            return false
        }
        let layout = options.textLayout ?? keyboard.keyMap.layout
        let map = KeyMap(layout: layout, host: options.textLayout == nil ? keyboard.keyMap.host : .macOS)

        // 1. Seize proof: F13 probe, then wait for the monitor's token on the LED output.
        guard await proveSeize(label: "TEXT", run: n, host: host) else { return false }

        // 2. Build and check.
        let chars = (0x20...0x7E).map { Character(Unicode.Scalar(UInt8($0))) }.filter { map.keyStroke(for: $0) != nil }
        let text = String(chars)
        let preview = keyboard.selfTestPreview(text, keyMap: map)
        // 0x35 is `` ` `` on US but 半角/全角 (IME toggle on Windows) on JIS: forbidden there.
        if let bad = unsafeReport(preview.reports, chars: chars, map: map, allowSpace: true) {
            Log.line("TEXT #\(n) ABORTED: unsafe report \(OutgoingReport.keyboard(bad).logText) — nothing typed")
            return false
        }
        for (i, ch) in chars.enumerated() {
            let s = map.keyStroke(for: ch)!
            Log.line("TEXT #\(n) expect #\(i) \(String(ch).debugDescription) usage=\(s.usage) mods=0x\(hex(s.modifiers.rawValue))")
        }

        // 3. Type through the real pipeline.
        let before = peripheral.stats
        let t0 = Date()
        Log.line("TEXT #\(n) begin layout=\(map.layout.rawValue) host=\(map.host.rawValue) chars=\(chars.count) reports=\(preview.reports.count) text=\(text.debugDescription)")
        let out = keyboard.selfTestType(text, keyMap: map)
        await waitIdle(seconds: Double(out.reports.count) * 0.06 + 5)
        _ = keyboard.selfTestRelease()
        await waitIdle(seconds: 1)
        let d = peripheral.stats - before
        Log.line("TEXT #\(n) end idle=\(peripheral.isIdle) duration=\(String(format: "%.2f", Date().timeIntervalSince(t0)))s skipped=\(out.skipped.count) sent: \(d.text)")
        return true
    }

    /// F13 probe, then wait for `mac-connect monitor --seize --ack-f13`'s token on the LED
    /// output report. Nothing printable may be sent unless this returns true.
    private func proveSeize(label: String, run n: Int, host: UUID) async -> Bool {
        // The F13 probe (safe even unseized) is repeated every 4 s for up to 30 s, so the
        // monitor can be started after this test began.
        let firstProbe = Date()
        var probes = 0
        while Date().timeIntervalSince(firstProbe) < 30 {
            let probeAt = Date()
            probes += 1
            Log.line("\(label) #\(n) probe F13 #\(probes) (waiting for seize token 0x\(hex(seizeToken.rawValue)) from \(host))")
            _ = keyboard.selfTestKeyDown(.f13)
            try? await Task.sleep(for: .milliseconds(120))
            _ = keyboard.selfTestKeyUp(.f13)
            while Date().timeIntervalSince(probeAt) < 4 {
                if let w = peripheral.lastLEDWrite, w.at > probeAt, w.central == host, w.value == seizeToken {
                    Log.line("\(label) #\(n) seize token received \(Int(Date().timeIntervalSince(probeAt) * 1000)) ms after probe #\(probes)")
                    return true
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        Log.line("\(label) #\(n) ABORTED: no seize token within 30 s (\(probes) F13 probes) — nothing typed (last LED write: \(peripheral.lastLEDWrite.map { "0x\(hex($0.value.rawValue)) from \(shortID($0.central))" } ?? "none"))")
        return false
    }

    /// Reports allowed under a proven seize: keys of `chars` only, Shift/Option only, never
    /// Return/Tab/Esc/Delete/arrows/F-keys/Caps/LANG/Space (Space only if `allowSpace`).
    private func unsafeReport(_ reports: [KeyboardReport], chars: [Character], map: KeyMap, allowSpace: Bool) -> KeyboardReport? {
        let allowedKeys = Set(chars.compactMap { map.keyStroke(for: $0)?.usage })
        var forbidden: Set<KeyUsage> = [.returnKey, .escape, .backspace, .tab, .deleteForward, .capsLock, .insert,
                                        .home, .end, .pageUp, .pageDown, .leftArrow, .rightArrow, .upArrow, .downArrow,
                                        .lang1, .lang2, .application]
        if !allowSpace { forbidden.insert(.space) }
        let allowedMods: KeyModifiers = [.leftShift, .leftAlt]
        return reports.first { r in
            !allowedMods.isSuperset(of: r.modifiers) || r.isRollOver || r.keys.contains {
                !allowedKeys.contains($0) || forbidden.contains($0) || ($0 == .grave && map.layout == .jis)
            }
        }
    }

    // MARK: kana

    /// Fixed kana corpus, one chunk per insertText as the flick keyboard delivers it. No Space,
    /// Return or Backspace; digits avoided (their width is a host setting).
    static let kanaCorpus: [String] = ["に", "ほ", "ん", "ご", "の", "か", "な", "、", "き", "ゃ", "っ", "ぁ", "ぃ", "ぅ", "ぇ", "ぉ",
                                       "ゎ", "。", "「", "ヴ", "ァ", "イ", "オ", "リ", "ン", "」", "ー", "・", "？", "！", "〜",
                                       "が", "ぱ", "づ", "ぢ", "を", "ゐ", "ゑ", "ヵ", "ヶ", "ｶﾞ"]

    /// `--selftest=kana` (seize required): the kana corpus through the text-field conversion
    /// and the real report pipeline, with automatic かな/英数 off (LANG keys are not allowed
    /// under the seize rules). The monitor's TYPED must equal the expected romaji.
    func runKana(run n: Int) async -> Bool {
        input.setSelfTestPlaying(true)
        defer { input.setSelfTestPlaying(false) }
        await waitIdle(seconds: 1)
        guard let host = peripheral.activeHostID, options.activeCentral == host else {
            Log.line("KANA #\(n) refused: --active-central must be set and active (active=\(peripheral.activeHostID?.uuidString ?? "none"))")
            return false
        }
        let layout = options.textLayout ?? keyboard.keyMap.layout
        let map = KeyMap(layout: layout, host: options.textLayout == nil ? keyboard.keyMap.host : .macOS)
        let chunks = Self.kanaCorpus
        let preview = keyboard.selfTestPreviewInsert(chunks, keyMap: map)
        let expected = preview.plans.map(\.typedText).joined()
        let langs = preview.plans.flatMap(\.imeKeys)
        let unsendable = preview.plans.flatMap(\.unsendable)
        guard langs.isEmpty, unsendable.isEmpty, expected.allSatisfy({ $0.isASCII && $0 != " " }) else {
            Log.line("KANA #\(n) ABORTED before probing: plan has LANG keys \(langs) / unsendable \(unsendable.map(\.character)) / non-printable keys")
            return false
        }
        if let bad = unsafeReport(preview.reports, chars: Array(expected), map: map, allowSpace: false) {
            Log.line("KANA #\(n) ABORTED before probing: unsafe report \(OutgoingReport.keyboard(bad).logText)")
            return false
        }
        for (c, p) in zip(chunks, preview.plans) {
            Log.line("KANA #\(n) expect \(c.debugDescription) (\(c.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " "))) -> \(p.typedText.debugDescription)")
        }
        guard await proveSeize(label: "KANA", run: n, host: host) else { return false }
        let before = peripheral.stats
        let t0 = Date()
        Log.line("KANA #\(n) begin layout=\(map.layout.rawValue) host=\(map.host.rawValue) chunks=\(chunks.count) reports=\(preview.reports.count) expected=\(expected.debugDescription)")
        let sent = keyboard.selfTestInsert(chunks, keyMap: map)
        await waitIdle(seconds: Double(sent) * 0.06 + 5)
        _ = keyboard.selfTestRelease()
        await waitIdle(seconds: 1)
        let d = peripheral.stats - before
        Log.line("KANA #\(n) end idle=\(peripheral.isIdle) duration=\(String(format: "%.2f", Date().timeIntervalSince(t0)))s reports=\(sent) sent: \(d.text)")
        Log.line("KANA #\(n) EXPECTED TYPED: \(expected)")
        return true
    }

    // MARK: compose

    /// Marked-text sequences as the flick keyboard produces them (one kana more per step). Only
    /// growth: no edit (Backspace), no conversion (Space), no commit (Return) — those are
    /// covered by unit tests (design §11.3). Each sequence ends with a discard that sends nothing.
    static let composeCorpus: [[String]] = [
        ["こ", "こん", "こんに", "こんにち", "こんにちは"],
        ["お", "おく", "おくら", "おくられ", "おくられて", "おくられてな", "おくられてない"],
        ["き", "きゃ", "きゃっ", "きゃっと", "きゃっとー"],
        ["に", "にほ", "にほん", "にほんご", "にほんご、", "にほんご、か", "にほんご、かな。"],
    ]

    /// `--selftest=compose` (seize required, launch with `--show=text`): the corpus as marked
    /// text on the real text field (`setAttributedMarkedText`, as the keyboard does) through the
    /// mirror and the real report pipeline, auto かな/英数 off. Every step is checked at run time
    /// against the preview (typed letters/punctuation only); anything else aborts the test.
    func runCompose(run n: Int) async -> Bool {
        guard let host = peripheral.activeHostID, options.activeCentral == host else {
            Log.line("COMPOSE #\(n) refused: --active-central must be set and active (active=\(peripheral.activeHostID?.uuidString ?? "none"))")
            return false
        }
        guard let view = CaptureTextView.current, view.isFirstResponder, !view.composing else {
            Log.line("COMPOSE #\(n) refused: the text field is not focused (launch with --show=text; the phone must be unlocked with the app in front)")
            return false
        }
        let map = keyboard.keyMap
        let sequences = Self.composeCorpus
        let preview = keyboard.composePreview(sequences)
        var expected = ""
        for steps in preview {
            for st in steps {
                guard case .type(let s) = st, !s.contains(" "), !s.contains("\n") else {
                    Log.line("COMPOSE #\(n) ABORTED before probing: preview has a non-typing step \(st)")
                    return false
                }
                expected += s
            }
        }
        let allowed = Set(expected)
        var copy = KeyboardState()
        let reports = copy.type(expected, with: TextTyper(keyMap: map))
        if let bad = unsafeReport(reports.reports, chars: Array(allowed), map: map, allowSpace: false) {
            Log.line("COMPOSE #\(n) ABORTED before probing: unsafe report \(OutgoingReport.keyboard(bad).logText)")
            return false
        }
        for (seq, steps) in zip(sequences, preview) {
            Log.line("COMPOSE #\(n) expect \(seq.last!.debugDescription) -> \(steps.map { "\($0)" }.joined(separator: " "))")
        }
        input.setSelfTestPlaying(true)
        defer { input.setSelfTestPlaying(false) }
        await waitIdle(seconds: 1)
        guard await proveSeize(label: "COMPOSE", run: n, host: host) else { return false }
        let before = peripheral.stats
        let t0 = Date()
        Log.line("COMPOSE #\(n) begin layout=\(map.layout.rawValue) host=\(map.host.rawValue) sequences=\(sequences.count) expected=\(expected.debugDescription)")
        keyboard.beginComposeSelfTest { step in
            if case .type(let s) = step { return !s.isEmpty && s.allSatisfy { allowed.contains($0) } }
            return false
        }
        defer { keyboard.endComposeSelfTest() }
        for seq in sequences {
            for s in seq {
                guard !keyboard.composeSelfTestAborted, CaptureTextView.current === view, view.isFirstResponder else { break }
                view.selfTestMark(s)
                try? await Task.sleep(for: .milliseconds(250))
            }
            try? await Task.sleep(for: .milliseconds(200))
            view.selfTestDiscard()
            keyboard.composeSelfTestNextSequence()
            await waitIdle(seconds: 3)
            if keyboard.composeSelfTestAborted { break }
            // A Japanese system keyboard clears marked text it did not create once the field
            // changed under it (seen 02:14:41: setAttributedMarkedText "" 45 ms after the next
            // sequence started). Restart the keyboard session: re-focus (both send nothing).
            _ = view.resignFirstResponder()
            try? await Task.sleep(for: .milliseconds(400))
            _ = view.becomeFirstResponder()
            try? await Task.sleep(for: .milliseconds(900))
            keyboard.composeSelfTestNextSequence()
        }
        await waitIdle(seconds: 5)
        let d = peripheral.stats - before
        Log.line("COMPOSE #\(n) end aborted=\(keyboard.composeSelfTestAborted) idle=\(peripheral.isIdle) duration=\(String(format: "%.2f", Date().timeIntervalSince(t0)))s sent: \(d.text)")
        Log.line("COMPOSE #\(n) EXPECTED TYPED: \(expected)")
        return !keyboard.composeSelfTestAborted
    }

    // MARK: lang (unseized, one-off)

    /// `--selftest=lang`: かな (LANG1) alone, wait, 英数 (LANG2) alone, wait. No character keys.
    /// The Mac side reads its input source before/between/after (`mac-connect inputsource`).
    func runLang(run n: Int) async -> Bool {
        input.setSelfTestPlaying(true)
        defer { input.setSelfTestPlaying(false) }
        await waitIdle(seconds: 1)
        guard let host = peripheral.activeHostID, options.activeCentral == host else {
            Log.line("LANG #\(n) refused: --active-central must be set and active (active=\(peripheral.activeHostID?.uuidString ?? "none"))")
            return false
        }
        for (u, name) in [(KeyUsage.lang1, "LANG1 (かな)"), (KeyUsage.lang2, "LANG2 (英数)")] {
            let r = keyboard.selfTestTapBare(u)
            Log.line("LANG #\(n) \(name) sent at \(wallClock()) -> \(r.map { OutgoingReport.keyboard($0).logText })")
            await waitIdle(seconds: 1)
            try? await Task.sleep(for: .seconds(5))
        }
        _ = keyboard.selfTestRelease()
        Log.line("LANG #\(n) end at \(wallClock())")
        return true
    }

    private func wallClock() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }

    private func waitIdle(seconds: Double) async {
        let t0 = Date()
        while !peripheral.isIdle, Date().timeIntervalSince(t0) < seconds {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private func hex(_ b: UInt8) -> String { String(format: "%02X", b) }
