import SwiftUI
import UIKit
import HIDCore

// UIKit press targets: they report touch-down and touch-up (SwiftUI buttons only report a
// completed tap), and several can be held at once with different fingers.

// MARK: - Circular button

/// A large circular button with an SF Symbol. `onDown` fires on touch-down, `onUp` when the
/// last finger lifts (also on cancel). `active` tints it (e.g. a toggled panel).
struct PressButton: UIViewRepresentable {
    var symbol: String
    var accessibility: String
    var diameter: CGFloat = 64
    var active = false
    var onDown: () -> Void = {}
    var onUp: () -> Void = {}

    func makeUIView(context: Context) -> CirclePressView { CirclePressView() }

    func updateUIView(_ v: CirclePressView, context: Context) {
        v.configure(symbol: symbol, accessibility: accessibility, active: active)
        v.onDown = onDown
        v.onUp = onUp
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: CirclePressView, context: Context) -> CGSize? {
        CGSize(width: diameter, height: diameter)
    }
}

final class CirclePressView: UIView {
    var onDown: () -> Void = {}
    var onUp: () -> Void = {}
    private let image = UIImageView()
    private var touches = 0
    private var active = false
    private var symbol = ""

    init() {
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        isExclusiveTouch = false
        backgroundColor = Theme.button
        image.tintColor = Theme.label
        image.contentMode = .center
        addSubview(image)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(symbol: String, accessibility: String, active: Bool) {
        if symbol != self.symbol {
            self.symbol = symbol
            let size = min(bounds.width, bounds.height)
            let pt = size > 0 ? size * 0.34 : 22
            image.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: pt, weight: .medium))
        }
        accessibilityLabel = accessibility
        self.active = active
        restyle()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = min(bounds.width, bounds.height) / 2
        image.frame = bounds
        let pt = min(bounds.width, bounds.height) * 0.34
        image.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: pt, weight: .medium))
    }

    private func restyle() {
        backgroundColor = touches > 0 ? Theme.buttonPressed : active ? UIColor(white: 0.85, alpha: 1) : Theme.button
        image.tintColor = active && touches == 0 ? UIColor(white: 0.05, alpha: 1) : Theme.label
    }

    override func touchesBegan(_ t: Set<UITouch>, with event: UIEvent?) {
        let first = touches == 0
        touches += t.count
        restyle()
        if first { onDown() }
    }

    override func touchesEnded(_ t: Set<UITouch>, with event: UIEvent?) { lift(t.count) }
    override func touchesCancelled(_ t: Set<UITouch>, with event: UIEvent?) { lift(t.count) }

    private func lift(_ n: Int) {
        guard touches > 0 else { return }
        touches = max(0, touches - n)
        restyle()
        if touches == 0 { onUp() }
    }
}

// MARK: - Key grid

/// What a panel key does.
enum PanelAction: Hashable {
    case key(KeyUsage)
    case modifier(PanelModifier)
    case media(ConsumerUsage)
}

struct PanelKey: Hashable {
    var action: PanelAction
    var label: String
    var symbol: String? = nil
    /// Relative width in its row.
    var width: CGFloat = 1
}

/// Appearance of one key, computed by SwiftUI from the controller state.
struct KeyLook: Hashable {
    enum Mode: Hashable { case normal, latched, locked }
    var mode: Mode = .normal
    var held = false
    var led: Bool? = nil
}

/// Rows of keys in one multi-touch view. Each finger is bound to the key it touched first
/// and releases that key when it lifts (sliding off does not release it, so a key can be
/// held reliably for host auto-repeat).
struct KeyGrid: UIViewRepresentable {
    var rows: [[PanelKey]]
    var looks: [PanelAction: KeyLook]
    var rowHeight: CGFloat = 46
    var onDown: (PanelAction) -> Void
    var onUp: (PanelAction) -> Void

    func makeUIView(context: Context) -> KeyGridView { KeyGridView() }

    func updateUIView(_ v: KeyGridView, context: Context) {
        v.onDown = onDown
        v.onUp = onUp
        v.rowHeight = rowHeight
        v.setRows(rows)
        v.apply(looks)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: KeyGridView, context: Context) -> CGSize? {
        let gap: CGFloat = 8
        let h = CGFloat(rows.count) * rowHeight + CGFloat(max(0, rows.count - 1)) * gap
        return CGSize(width: proposal.width ?? 320, height: h)
    }
}

final class KeyGridView: UIView {
    var onDown: (PanelAction) -> Void = { _ in }
    var onUp: (PanelAction) -> Void = { _ in }
    var rowHeight: CGFloat = 46
    private var rows: [[PanelKey]] = []
    private var cells: [(key: PanelKey, view: KeyCell)] = []
    private var bound: [ObjectIdentifier: PanelAction] = [:]
    private var pressCount: [PanelAction: Int] = [:]
    private var looks: [PanelAction: KeyLook] = [:]

    init() {
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        isExclusiveTouch = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setRows(_ new: [[PanelKey]]) {
        guard new != rows else { return }
        // Release anything held on the old layout.
        for (action, n) in pressCount where n > 0 { onUp(action) }
        pressCount = [:]
        bound = [:]
        rows = new
        cells.forEach { $0.view.removeFromSuperview() }
        cells = new.flatMap { $0 }.map { k in
            let c = KeyCell(key: k)
            addSubview(c)
            return (k, c)
        }
        setNeedsLayout()
        apply(looks)
    }

    func apply(_ looks: [PanelAction: KeyLook]) {
        self.looks = looks
        for (k, v) in cells {
            v.update(look: looks[k.action] ?? KeyLook(), pressed: (pressCount[k.action] ?? 0) > 0)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let gap: CGFloat = 8
        var i = 0
        for (r, row) in rows.enumerated() {
            let total = row.reduce(0) { $0 + $1.width }
            let usable = bounds.width - gap * CGFloat(max(0, row.count - 1))
            var x: CGFloat = 0
            let y = CGFloat(r) * (rowHeight + gap)
            for k in row {
                let w = usable * k.width / total
                cells[i].view.frame = CGRect(x: x, y: y, width: w, height: rowHeight)
                x += w + gap
                i += 1
            }
        }
    }

    private func action(at p: CGPoint) -> PanelAction? {
        // Nearest key within the gap, so touches between keys still count.
        cells.first { $0.view.frame.insetBy(dx: -4, dy: -4).contains(p) }?.key.action
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            guard let a = action(at: t.location(in: self)) else { continue }
            bound[ObjectIdentifier(t)] = a
            let n = pressCount[a] ?? 0
            pressCount[a] = n + 1
            if n == 0 { onDown(a) }
        }
        apply(looks)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches) }

    private func lift(_ touches: Set<UITouch>) {
        for t in touches {
            guard let a = bound.removeValue(forKey: ObjectIdentifier(t)) else { continue }
            let n = (pressCount[a] ?? 1) - 1
            pressCount[a] = max(0, n)
            if n <= 0 { onUp(a) }
        }
        apply(looks)
    }
}

final class KeyCell: UIView {
    private let label = UILabel()
    private let image = UIImageView()
    private let dot = UIView()
    let key: PanelKey

    init(key: PanelKey) {
        self.key = key
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        layer.cornerRadius = 11
        layer.cornerCurve = .continuous
        label.text = key.label
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = Theme.label
        addSubview(label)
        if let s = key.symbol {
            image.image = UIImage(systemName: s, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium))
            image.contentMode = .center
            image.tintColor = Theme.label
            addSubview(image)
            label.font = .systemFont(ofSize: 9, weight: .medium)
            label.textColor = Theme.secondaryLabel
        }
        dot.layer.cornerRadius = 3
        dot.isHidden = true
        addSubview(dot)
        isAccessibilityElement = true
        accessibilityLabel = key.label
        accessibilityTraits = .keyboardKey
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        if key.symbol != nil, key.label.isEmpty {
            image.frame = bounds
        } else if key.symbol != nil {
            image.frame = CGRect(x: 0, y: 2, width: bounds.width, height: bounds.height * 0.62)
            label.frame = CGRect(x: 2, y: bounds.height * 0.6, width: bounds.width - 4, height: bounds.height * 0.36)
        } else {
            label.frame = bounds.insetBy(dx: 3, dy: 2)
        }
        dot.frame = CGRect(x: bounds.width - 11, y: 5, width: 6, height: 6)
    }

    func update(look: KeyLook, pressed: Bool) {
        let bg: UIColor
        if pressed || look.held { bg = Theme.keyPressed }
        else {
            switch look.mode {
            case .normal: bg = Theme.key
            case .latched: bg = Theme.latched
            case .locked: bg = Theme.locked
            }
        }
        backgroundColor = bg
        layer.borderWidth = look.mode == .locked ? 1.5 : 0
        layer.borderColor = UIColor.white.withAlphaComponent(0.8).cgColor
        if let led = look.led {
            dot.isHidden = false
            dot.backgroundColor = led ? Theme.ledOn : UIColor(white: 0.3, alpha: 1)
        } else {
            dot.isHidden = true
        }
        accessibilityValue = look.mode == .locked ? "ロック" : look.mode == .latched ? "次のキーに適用" : look.led == true ? "オン" : nil
    }
}

// MARK: - Text capture

/// What the text field reports to the controller (which returns the log outcome).
enum CaptureEvent {
    /// ASCII path (non-Japanese keyboard, nothing composing): `text` typed (the field stays empty).
    case insert(String)
    /// ASCII path: the delete key.
    case delete
    /// Japanese path: a composition change, commit, or text / delete outside a composition,
    /// derived from the field's state after the change (CompositionMirror).
    case mirror(CompositionMirror.Event)
    /// The field took focus.
    case focus
    /// The field is losing focus (UIKit may commit the composition next: not a 確定).
    case focusLost(composing: Bool)
    /// The field was cleared after a commit (`text` is what was cleared).
    case cleared(String)
    /// The space-bar cursor gesture moved the caret in the pad: arrow keys for the host.
    case arrows([ArrowSteps])
}

/// The 文字入力 field (design §8.4, 2026-11-18). A real `UITextView`, so iOS gives it full
/// `UITextInput` / marked-text support and the Japanese keyboard composes in it.
///
/// - ASCII path (non-Japanese keyboard, nothing marked, field empty): typing arrives as
///   `shouldChangeTextIn` (captured 00:41: the English keyboard does not call the
///   `insertText` / `deleteBackward` overrides) or through those overrides; it goes to the
///   controller and the field stays empty (no context for autocorrect, text replacement or
///   predictions).
/// - Japanese path (Japanese keyboard, a composition, or uncleared text): UIKit edits the field
///   normally. After every callback the field's state (marked text, text) is compared with the
///   last one and turned into a `CompositionMirror.Event`. When nothing is marked any more, the
///   field is cleared on the next run-loop turn.
/// - Cursor pad (2026-11-18): the field's text is invisible pad + the user's content + pad
///   (`CursorPadGrid`); everything above sees only the content. The space-bar cursor gesture
///   moves the caret in the pad; see "Cursor pad" below. The field itself is invisible; the
///   strip shows the content in a label.
/// - Every override and delegate callback is logged as one `TEXTCAP` line (typed text only if
///   「入力内容をログに記録する」 is on); offsets in TEXTCAP lines are relative to the content.
struct KeyCapture: UIViewRepresentable {
    var active: Bool
    var columnsPerStep = 1
    var handle: (CaptureEvent, String?) -> String?
    /// Whether one more arrow of that direction fits in the controller's queue (edge repeat).
    var arrowRoom: (ArrowDirection) -> Bool = { _ in true }
    var onModeChange: (String?, String) -> Void = { _, _ in }
    var onText: (String) -> Void = { _ in }

    func makeUIView(context: Context) -> CapturePadHost { CapturePadHost() }

    func updateUIView(_ host: CapturePadHost, context: Context) {
        let v = host.field
        v.handle = handle
        v.onModeChange = onModeChange
        v.onText = onText
        v.arrowRoom = arrowRoom
        if v.columnsPerStep != columnsPerStep { v.columnsPerStep = columnsPerStep }
        if active, !v.isFirstResponder {
            DispatchQueue.main.async { _ = v.becomeFirstResponder() }
        } else if !active, v.isFirstResponder {
            DispatchQueue.main.async { _ = v.resignFirstResponder() }
        }
    }

    static func dismantleUIView(_ host: CapturePadHost, coordinator: ()) {
        _ = host.field.resignFirstResponder()
    }
}

/// Holds the capture field. The field is taller than the strip (the pad's lines extend above
/// and below it, centred on the strip) so that vertical caret moves need no scrolling; touches
/// outside the host's bounds never reach it (UIKit hit-tests the host first).
final class CapturePadHost: UIView {
    let field = CaptureTextView()

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        clipsToBounds = false
        addSubview(field)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        field.layout(inHost: bounds)
    }
}

final class CaptureTextView: UITextView {
    /// The field that has (or last had) focus (for the controller's resets and the self-test).
    static weak var current: CaptureTextView?

    var handle: (CaptureEvent, String?) -> String? = { _, _ in nil }
    var onModeChange: (String?, String) -> Void = { _, _ in }
    var onText: (String) -> Void = { _ in }
    var arrowRoom: (ArrowDirection) -> Bool = { _ in true }
    private let relay = CaptureDelegate()
    private var observer: NSObjectProtocol?
    private var lastLanguage: String??
    private var lastLogTime: Double?
    private var clearScheduled = false
    /// Last observed state (for deriving mirror events). Content only (no pad).
    private var seenMarked: String?
    private var seenText = ""
    private var markStart = 0
    /// Programmatic changes (clear, focus loss, self-test discard) produce no mirror events.
    private var suppressMirror = false
    private var inDeleteOverride = false
    private var deleteSeen = false

    // Cursor pad state (see "Cursor pad").
    static let padRows = 15
    static let padFont = UIFont.monospacedSystemFont(ofSize: 15, weight: .regular)
    static let charWidth: CGFloat = (String(CursorPadGrid.padCharacter) as NSString).size(withAttributes: [.font: padFont]).width
    private static let padVisible = ProcessInfo.processInfo.arguments.contains("--cursorpad-visible")
    private(set) var grid = CursorPadGrid(rows: CaptureTextView.padRows, columns: 31)
    private var tracker = CursorPadTracker(grid: CursorPadGrid(rows: CaptureTextView.padRows, columns: 31))
    /// A pad of a new width waiting for the field to be empty.
    private var pendingGrid: CursorPadGrid?
    private var padText = ""
    private var padPrefixText = ""
    private var padSuffixText = ""
    /// UTF-16 lengths of the pad before / after the content (fixed while the pad is intact).
    private var padPrefix = 0
    private var padSuffix = 0
    /// Set while the app itself changes the selection (pad reset, recentre): the reason.
    private var selfChange: String?
    /// > 0 while a keyboard edit (insert, delete, marked text, unmark, replace) is applied.
    private var editDepth = 0
    /// Storage offset / length of the selection last seen by the selection handler.
    private var lastCaret = 0
    private var lastSelLength = 0
    private var damagedLogged = false
    /// Floating cursor (UITextInput begin/update/endFloatingCursor, called by the keyboard's
    /// space-bar gesture).
    private var fcActive = false
    /// Edge auto-repeat while the caret is pinned on a pad edge during the gesture.
    private var edgeRepeat = EdgeRepeater()
    private var edgeTimerGeneration = 0
    private var fcSeen = false
    private var fcUpdates = 0
    private var fcBegin = CGPoint.zero
    private var fcLast = CGPoint.zero
    private var fcLastUpdateTime = 0.0
    private var fcLastLogTime = 0.0
    private var quietGeneration = 0
    private var quietPending = false
    static let quietDelay = 0.25
    var columnsPerStep = 1 {
        didSet {
            tracker.columnsPerStep = columnsPerStep
            Log.line("CURSORPAD sensitivity: \(columnsPerStep) column(s) per Left/Right press (rows 1:1)")
        }
    }

    init() {
        super.init(frame: .zero, textContainer: nil)
        relay.view = self
        delegate = relay
        font = Self.padFont
        if Self.padVisible {
            backgroundColor = UIColor(white: 0.3, alpha: 0.5)
            textColor = .white
            tintColor = .systemOrange
        } else {
            backgroundColor = .clear
            textColor = .clear
            tintColor = .clear
        }
        textContainerInset = UIEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
        textContainer.lineFragmentPadding = 0
        textContainer.lineBreakMode = .byClipping
        isScrollEnabled = false
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        // Nothing may rewrite what the user types.
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        inlinePredictionType = .no
        if #available(iOS 18.0, *) {
            mathExpressionCompletionType = .no
            writingToolsBehavior = .none
        }
        allowsEditingTextAttributes = false
        dataDetectorTypes = []
        keyboardType = .default
        keyboardAppearance = .dark
        returnKeyType = .default
        enablesReturnKeyAutomatically = false
        textContentType = nil
        installGrid(grid, reason: "init")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The language of the keyboard in use.
    var language: String? { textInputMode?.primaryLanguage }
    private var japanese: Bool { KeyboardInputMode(primaryLanguage: language) == .japanese }
    /// The Japanese path: Japanese keyboard, a composition in progress, or text not yet cleared.
    private var capturing: Bool { japanese || markedTextRange != nil || !content.isEmpty || Self.probe }
    var composing: Bool { markedTextRange != nil }
    private static let probe = LaunchOptions.current.textCapProbe
    private var probeStarted = false

    // MARK: Content (the field's text without the pad)

    private var storage: NSString { (text ?? "") as NSString }

    private var padIntact: Bool {
        let s = storage
        guard s.length >= padPrefix + padSuffix else { return false }
        return s.substring(to: padPrefix) == padPrefixText && s.substring(from: s.length - padSuffix) == padSuffixText
    }

    /// Storage range of the content.
    private var contentRange: NSRange {
        NSRange(location: padPrefix, length: max(0, storage.length - padPrefix - padSuffix))
    }

    /// What the user typed (composition included): the field's text without the pad.
    var content: String {
        if padIntact { return storage.substring(with: contentRange) }
        if !damagedLogged {
            damagedLogged = true
            Log.line("CURSORPAD pad damaged (storage \(storage.length) UTF-16, expected pad \(padPrefix)+\(padSuffix)): content = text without NBSP until the next clear")
        }
        return storage.replacingOccurrences(of: String(CursorPadGrid.padCharacter), with: "")
            .trimmingCharacters(in: .newlines)
    }

    private func contentOffset(_ p: UITextPosition) -> Int { offset(from: beginningOfDocument, to: p) - padPrefix }

    // MARK: Focus and keyboard

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            Self.current = self
            if observer == nil {
                observer = NotificationCenter.default.addObserver(forName: UITextInputMode.currentInputModeDidChangeNotification,
                                                                  object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.log("inputModeChange", nil)
                        self.reportMode("notification")
                    }
                }
            }
            // textInputMode is settled only after the keyboard came up.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reportMode("focus")
                self.log("focusSettled", self.handle(.focus, self.language))
                if Self.probe, !self.probeStarted { self.startProbe() }
            }
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        guard isFirstResponder else { return super.resignFirstResponder() }
        // UIKit commits a live composition while resigning (unmarkText): that is not a 確定,
        // so the mirror is reset first and the commit is not observed.
        log("resignFirstResponder", handle(.focusLost(composing: composing), language))
        stopEdgeRepeat(reason: "focus lost")
        suppressMirror = true
        let ok = super.resignFirstResponder()
        suppressMirror = false
        if ok, let o = observer {
            NotificationCenter.default.removeObserver(o)
            observer = nil
            lastLanguage = nil
        }
        discardText(reason: "focus lost")
        return ok
    }

    /// A tap on the strip (the field itself takes no touches): focus again if needed.
    static func focusFromTap() {
        guard let v = current, !v.isFirstResponder else { return }
        _ = v.becomeFirstResponder()
    }

    private func reportMode(_ source: String) {
        let l = language
        if source == "focus" || lastLanguage == nil || lastLanguage! != l {
            lastLanguage = .some(l)
            onModeChange(l, source)
        }
    }

    /// No edit menu paste / cut etc.: a paste would type the clipboard into the host without
    /// the confirmation (use the paste button).
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool { false }

    /// Always true, so the delete key reaches `deleteBackward` on an empty field too (the
    /// ASCII path keeps the field empty).
    override var hasText: Bool { true }

    // MARK: Keyboard input (UIKeyInput / UITextInput entry points; logged, super on the Japanese path)

    override func insertText(_ s: String) {
        reportMode("event")
        if capturing {
            caretHomeBeforeEdit("insertText")
            let before = snapshot()
            editDepth += 1
            super.insertText(s)
            editDepth -= 1
            log("insertText \(Log.q(s))", observe(), before: before)
            afterCapture()
        } else {
            log("insertText \(Log.q(s))", handle(.insert(s), language))
        }
    }

    override func deleteBackward() {
        reportMode("event")
        if capturing {
            caretHomeBeforeEdit("deleteBackward")
            let before = snapshot()
            let emptyBefore = content.isEmpty && markedTextRange == nil
            inDeleteOverride = true
            deleteSeen = false
            editDepth += 1
            super.deleteBackward()
            editDepth -= 1
            inDeleteOverride = false
            var outcome = observe()
            if emptyBefore, !deleteSeen { outcome = handle(.mirror(.deleted), language) }
            log("deleteBackward", outcome, before: before)
            afterCapture()
        } else {
            log("deleteBackward", handle(.delete, language))
        }
    }

    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        reportMode("event")
        caretHomeBeforeEdit("setMarkedText")
        let before = snapshot()
        editDepth += 1
        super.setMarkedText(markedText, selectedRange: selectedRange)
        editDepth -= 1
        log("setMarkedText \(Log.q(markedText ?? "")) sel={\(selectedRange.location),\(selectedRange.length)}", observe(), before: before)
        afterCapture()
    }

    override func setAttributedMarkedText(_ markedText: NSAttributedString?, selectedRange: NSRange) {
        reportMode("event")
        caretHomeBeforeEdit("setAttributedMarkedText")
        let before = snapshot()
        editDepth += 1
        super.setAttributedMarkedText(markedText, selectedRange: selectedRange)
        editDepth -= 1
        log("setAttributedMarkedText \(Log.q(markedText?.string ?? "")) sel={\(selectedRange.location),\(selectedRange.length)}", observe(), before: before)
        afterCapture()
    }

    override func unmarkText() {
        let before = snapshot()
        editDepth += 1
        super.unmarkText()
        editDepth -= 1
        log("unmarkText", observe(), before: before)
        afterCapture()
    }

    override func replace(_ range: UITextRange, withText s: String) {
        let r = "[\(contentOffset(range.start)),\(contentOffset(range.end)))"
        let before = snapshot()
        editDepth += 1
        super.replace(range, withText: s)
        editDepth -= 1
        log("replace \(r) with \(Log.q(s))", observe(), before: before)
        afterCapture()
    }

    // MARK: Delegate callbacks (via CaptureDelegate)

    func delegateShouldChange(_ range: NSRange, _ s: String) -> Bool {
        let cr = contentRange
        let inContent = range.location >= cr.location && NSMaxRange(range) <= NSMaxRange(cr)
        var head = "shouldChangeTextIn {\(range.location - cr.location),\(range.length)} replacementText=\(Log.q(s))"
        if !inContent { head += " [touches the pad: storage {\(range.location),\(range.length)}, content {\(cr.location),\(cr.length)}]" }
        if capturing {
            // The delete key with no content changes nothing; this is its only trace (00:41
            // capture: the keyboard's delete arrives here, not in deleteBackward). With the pad
            // it asks to delete the pad character before the caret: refused.
            if s.isEmpty, content.isEmpty, markedTextRange == nil, !suppressMirror, range.length == 0 || !inContent {
                deleteSeen = true
                log(head + " (delete on an empty field)", handle(.mirror(.deleted), language))
                return range.length == 0
            }
            if !inContent, !suppressMirror {
                log(head + " (edit outside the content: refused, pad kept)", nil)
                DispatchQueue.main.async { [weak self] in self?.recentre("after a refused edit", midGesture: false) }
                return false
            }
            log(head, "→ true")
            return true
        }
        // ASCII path: send it and keep the field empty.
        let event: CaptureEvent = s.isEmpty ? .delete : .insert(s)
        log(head + " (ASCII path, returns false)", handle(event, language))
        return false
    }

    func delegateDidChange() {
        log("textViewDidChange", observe())
        afterCapture()
    }

    func delegateDidChangeSelection() {
        log("textViewDidChangeSelection", observe())
        cursorPadSelectionChanged()
    }
    func delegateBeginEditing() { log("textViewDidBeginEditing", nil) }
    func delegateEndEditing() { log("textViewDidEndEditing", nil) }

    // MARK: Mirror events

    /// Compares the field's content with the last observed state and reports a mirror event,
    /// if any.
    private func observe() -> String? {
        guard !suppressMirror else { return nil }
        let t = content
        var m: String?
        if let r = markedTextRange { m = self.text(in: r) ?? "" }
        defer { seenMarked = m; seenText = t }
        guard m != seenMarked || t != seenText else { return nil }
        if let m {
            if seenMarked == nil, let r = markedTextRange { markStart = contentOffset(r.start) }
            return m != seenMarked ? handle(.mirror(.marked(m)), language) : nil
        }
        if seenMarked != nil {
            let ns = t as NSString
            let start = min(max(0, markStart), ns.length)
            let committed = ns.substring(from: start)
            return handle(.mirror(.ended(committed: committed, reading: nil)), language)
        }
        if t.count > seenText.count, t.hasPrefix(seenText) {
            return handle(.mirror(.inserted(String(t.dropFirst(seenText.count)))), language)
        }
        return nil
    }

    /// Empties the field (back to the bare pad) without any mirror event.
    private func discardText(reason: String) {
        suppressMirror = true
        if markedTextRange != nil { unmarkText() }
        let had = content
        if !had.isEmpty || !padIntact { resetPad("discard: \(reason)") }
        suppressMirror = false
        seenMarked = nil
        seenText = ""
        onText("")
        if !had.isEmpty { log("discard (\(reason)) text=\(Log.q(had))", nil) }
    }

    // MARK: Cursor pad (space-bar cursor gesture → arrow keys)
    //
    // - The field's text is `grid` pad around the content; the caret's home is the pad's centre.
    // - A selection change counts as the gesture only when it is not the app's own
    //   (`selfChange`), not caused by a keyboard edit (`editDepth`), nothing is marked (iOS
    //   moves the caret inside a composition: left to the IME) and the content is empty. Taps
    //   never reach the field (the strip covers it), so nothing else moves the caret.
    // - A non-empty selection is collapsed back home and ignored.
    // - Recentre (caret back home): when the floating cursor ends; ~250 ms after the last move
    //   if no floating cursor is seen; at once when the caret comes near the pad's edge (unless
    //   a snap-back showed that UIKit places the caret by the finger's absolute point — see
    //   `CursorPadTracker`); before a keyboard edit if the caret is outside the content.
    // - Every selection change, floating cursor callback, recentre and the keys are logged as
    //   `CURSORPAD` lines.

    /// Lays the field out over the host: full width, the pad's lines centred on the strip.
    /// A different width makes a pad with a different number of columns (applied when empty).
    func layout(inHost b: CGRect) {
        guard b.width > 40 else { return }
        let usable = b.width - textContainerInset.left - textContainerInset.right
        let g = CursorPadGrid(rows: Self.padRows, columns: Int(usable / Self.charWidth) - 2)
        let h = CGFloat(g.rows) * Self.padFont.lineHeight + textContainerInset.top + textContainerInset.bottom + 6
        let f = CGRect(x: 0, y: (b.midY - h / 2).rounded(), width: b.width, height: h.rounded(.up))
        if frame != f { frame = f }
        guard g != grid, g != pendingGrid else { return }
        if markedTextRange == nil, content.isEmpty {
            installGrid(g, reason: "layout width \(Int(b.width)) pt")
        } else {
            pendingGrid = g
        }
    }

    private func installGrid(_ g: CursorPadGrid, reason: String) {
        grid = g
        pendingGrid = nil
        tracker.grid = g
        padText = g.text
        padPrefixText = g.prefix
        padSuffixText = g.suffix
        let saved = suppressMirror
        suppressMirror = true
        resetPad("new pad")
        suppressMirror = saved
        Log.line("CURSORPAD pad \(g.rows) rows × \(g.columns) columns (\(reason)): home \(g.center) offset \(g.centerOffset), char \(String(format: "%.2f", Self.charWidth)) pt, line \(String(format: "%.2f", Self.padFont.lineHeight)) pt, field frame \(frame.integral), \(columnsPerStep) column(s) per Left/Right press\(Self.padVisible ? ", VISIBLE (--cursorpad-visible)" : "")")
    }

    /// The field becomes the bare pad with the caret at home (replaces `text = ""`).
    private func resetPad(_ reason: String) {
        if let g = pendingGrid, markedTextRange == nil {
            pendingGrid = nil
            grid = g
            tracker.grid = g
            padText = g.text
            padPrefixText = g.prefix
            padSuffixText = g.suffix
        }
        padPrefix = grid.prefixLength
        padSuffix = grid.suffixLength
        selfChange = "pad reset (\(reason))"
        text = padText
        selectedRange = NSRange(location: padPrefix, length: 0)
        selfChange = nil
        lastCaret = padPrefix
        lastSelLength = 0
        damagedLogged = false
        tracker.reset()
        quietPending = false
        quietGeneration += 1
    }

    /// "r7c16" for a storage offset when the field is the bare pad, else "-".
    private func place(_ o: Int) -> String {
        guard markedTextRange == nil, storage.length == grid.length, let p = grid.position(ofOffset: o) else { return "-" }
        return p.description
    }

    private var fcState: String { fcActive ? "active" : fcSeen ? "ended" : "never" }

    private func cursorPadSelectionChanged() {
        let sel = selectedRange
        let old = lastCaret, oldLen = lastSelLength
        lastCaret = sel.location
        lastSelLength = sel.length
        let marked = markedTextRange != nil
        let why = selfChange ?? (editDepth > 0 ? "typing" : suppressMirror ? "programmatic" : nil)
        defer { updateEdgeRepeat() }
        if why != nil, sel.location == old, sel.length == oldLen { return }   // nothing moved
        let c = content
        var line = "CURSORPAD sel \(old)\(oldLen > 0 ? "+\(oldLen)" : "")→\(sel.location)\(sel.length > 0 ? "+\(sel.length)" : "") \(place(old))→\(place(sel.location)) marked=\(marked) content=\(c.count) fc=\(fcState)"
        if let why {
            if !marked, c.isEmpty { tracker.rebase(toOffset: sel.location) }
            Log.line(line + " self=\(why) → no keys")
            return
        }
        if marked {
            Log.line(line + " → inside a composition: left to the IME, no keys")
            return
        }
        if !c.isEmpty {
            Log.line(line + " → the field has content (not yet cleared): no keys")
            return
        }
        if sel.length > 0 {
            Log.line(line + " → non-empty selection: collapsed back home, no keys")
            let mid = fcActive
            DispatchQueue.main.async { [weak self] in self?.recentre("selection collapsed", midGesture: mid) }
            return
        }
        switch tracker.caretMoved(toOffset: sel.location) {
        case .outside:
            line += " → outside the pad, no keys"
        case .unchanged:
            line += " → no move"
        case .snapBack(let from, let to):
            line += " → SNAP-BACK after a recentre (was \(from), now \(to)): UIKit put the caret back where the finger is; no keys, no more edge recentres in this gesture"
        case .moved(let from, let to, let steps, let recentre, let afterRecentre):
            line += " Δcol=\(to.column - from.column) Δrow=\(to.row - from.row)"
            if afterRecentre { line += " [first move after a recentre: relative to home, no snap-back]" }
            if steps.isEmpty {
                line += " → no keys yet (sensitivity remainder)"
            } else {
                line += " → " + (handle(.arrows(steps), language) ?? "arrows \(steps.summary)")
            }
            // Near the edge: no recentre during a floating-cursor gesture (UIKit puts the caret
            // back where the finger is: seen 02:43, every time); the edge repeat takes over.
            // Without a floating cursor the recentre stays (snap-back checked).
            if recentre, !fcActive {
                line += "; near the pad's edge → recentre (no floating cursor)"
                let mid = !fcSeen
                DispatchQueue.main.async { [weak self] in self?.recentre("near the edge", midGesture: mid) }
            }
            scheduleQuietRecentre()
        }
        Log.line(line)
    }

    /// Recentre ~250 ms after the last move, unless a floating cursor is still active (then
    /// its end recentres; a floating cursor silent for 2 s counts as ended).
    private func scheduleQuietRecentre() {
        quietGeneration += 1
        quietPending = true
        let g = quietGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.quietDelay) { [weak self] in
            self?.quietFired(g)
        }
    }

    private func quietFired(_ g: Int) {
        guard g == quietGeneration, quietPending else { return }
        if fcActive {
            if ProcessInfo.processInfo.systemUptime - fcLastUpdateTime < 2 {
                scheduleQuietRecentre()
                return
            }
            Log.line("CURSORPAD floating cursor silent for 2 s without end: treated as ended")
            fcActive = false
            updateEdgeRepeat()
        }
        quietPending = false
        tracker.gestureEnded()
        recentre("quiet \(Int(Self.quietDelay * 1000)) ms", midGesture: true)
    }

    /// Caret back home (content empty, nothing marked).
    private func recentre(_ reason: String, midGesture: Bool) {
        guard markedTextRange == nil, content.isEmpty, padIntact else {
            Log.line("CURSORPAD recentre (\(reason)) skipped: marked=\(markedTextRange != nil) content=\(content.count) padIntact=\(padIntact)")
            return
        }
        let s = selectedRange
        let from = tracker.baseline
        guard s.location != padPrefix || s.length != 0 || from != grid.center else { return }
        tracker.didRecentre(midGesture: midGesture)
        selfChange = "recentre"
        selectedRange = NSRange(location: padPrefix, length: 0)
        selfChange = nil
        lastCaret = padPrefix
        lastSelLength = 0
        Log.line("CURSORPAD recentre (\(reason)\(midGesture ? "; next move checked for a snap-back" : "")) \(place(s.location))\(s.length > 0 ? "+\(s.length)" : "") (tracked \(from)) → \(grid.center)")
    }

    /// Before a keyboard edit with nothing marked: the caret must be in the content (the pad
    /// before and after it stays fixed).
    private func caretHomeBeforeEdit(_ what: String) {
        guard markedTextRange == nil, padIntact else { return }
        let cr = contentRange, s = selectedRange
        guard s.location < cr.location || NSMaxRange(s) > NSMaxRange(cr) else { return }
        quietPending = false
        quietGeneration += 1
        tracker.gestureEnded()
        tracker.didRecentre(midGesture: false)
        selfChange = "caret home before \(what)"
        selectedRange = NSRange(location: NSMaxRange(cr), length: 0)
        selfChange = nil
        lastCaret = NSMaxRange(cr)
        lastSelLength = 0
        Log.line("CURSORPAD caret was outside the content (\(s.location)+\(s.length), \(place(s.location))) before \(what): moved home")
    }

    // Floating cursor: the keyboard's space-bar gesture drives these (logged; UIKit moves the
    // caret in super).

    override func beginFloatingCursor(at point: CGPoint) {
        fcActive = true
        fcSeen = true
        fcUpdates = 0
        fcBegin = point
        fcLast = point
        fcLastUpdateTime = ProcessInfo.processInfo.systemUptime
        fcLastLogTime = 0
        Log.line("CURSORPAD floating cursor begin at \(pt(point)) caret \(selectedRange.location) \(place(selectedRange.location)) marked=\(markedTextRange != nil) content=\(content.count)")
        super.beginFloatingCursor(at: point)
    }

    override func updateFloatingCursor(at point: CGPoint) {
        fcUpdates += 1
        fcLast = point
        let now = ProcessInfo.processInfo.systemUptime
        fcLastUpdateTime = now
        super.updateFloatingCursor(at: point)
        updateEdgeRepeat()
        if now - fcLastLogTime >= 0.1 {
            fcLastLogTime = now
            let dx = point.x - fcBegin.x, dy = point.y - fcBegin.y
            Log.line("CURSORPAD floating cursor update #\(fcUpdates) at \(pt(point)) Δ=\(pt(CGPoint(x: dx, y: dy))) ≈ \(String(format: "%+.1f", dx / Self.charWidth)) col \(String(format: "%+.1f", dy / Self.padFont.lineHeight)) row; caret \(selectedRange.location) \(place(selectedRange.location))")
        }
    }

    override func endFloatingCursor() {
        super.endFloatingCursor()
        fcActive = false
        updateEdgeRepeat()
        Log.line("CURSORPAD floating cursor end after \(fcUpdates) update(s), last \(pt(fcLast)) Δ=\(pt(CGPoint(x: fcLast.x - fcBegin.x, y: fcLast.y - fcBegin.y))); caret \(selectedRange.location) \(place(selectedRange.location))")
        quietPending = false
        quietGeneration += 1
        tracker.gestureEnded()
        DispatchQueue.main.async { [weak self] in self?.recentre("gesture end", midGesture: true) }
    }

    private func pt(_ p: CGPoint) -> String { String(format: "(%.1f,%.1f)", p.x, p.y) }

    // Edge auto-repeat: the floating cursor is clamped to the pad, so a caret on an edge row /
    // column cannot move on (02:43 capture: y stuck at 10.0 on row 0, x at 1.5 on column 0).
    // While the gesture is active and the caret sits on an edge: after 300 ms one step every
    // 100 ms (60 ms after 1.5 s) in that direction (`EdgeRepeater`), into the controller's
    // bounded queue; a full queue skips the tick. Stops when the caret leaves the edge, the
    // gesture ends, marked text appears, the field gets content or loses focus, and on the
    // controller's resets (app inactive, host change).

    /// Re-evaluates the pinned edges from the current state (cheap; called on every selection
    /// change and floating cursor callback).
    private func updateEdgeRepeat() {
        let s = selectedRange
        var p: PadPosition?
        if fcActive, isFirstResponder, markedTextRange == nil, s.length == 0, storage.length == grid.length, padIntact {
            p = grid.position(ofOffset: s.location)
        }
        let t = ProcessInfo.processInfo.systemUptime
        logEdgeChanges(edgeRepeat.update(position: p, grid: grid, at: t), at: p)
        edgeTick()
    }

    /// Stops the edge repeat (controller resets).
    func stopEdgeRepeat(reason: String) {
        guard edgeRepeat.isActive else { return }
        logEdgeChanges(edgeRepeat.stopAll(at: ProcessInfo.processInfo.systemUptime), at: nil, reason: reason)
        edgeTimerGeneration += 1
    }

    private func logEdgeChanges(_ changes: [EdgeRepeater.Change], at p: PadPosition?, reason: String? = nil) {
        for c in changes {
            switch c {
            case .start(let d):
                Log.line("CURSORPAD edge-repeat start \(d.symbol) (caret \(p?.description ?? "-") on the pad's edge; first step in \(Int(edgeRepeat.initialDelay * 1000)) ms, then every \(Int(edgeRepeat.interval * 1000)) ms, \(Int(edgeRepeat.fastInterval * 1000)) ms after \(edgeRepeat.fastAfter) s)")
            case .stop(let d, let n, let pinned):
                edgeFullNoted.remove(d)
                let why = reason ?? (!fcActive ? "gesture ended" : markedTextRange != nil ? "marked text" : p == nil ? "not applicable" : "left the edge (caret \(p!))")
                Log.line("CURSORPAD edge-repeat stop \(d.symbol) (\(why)) after \(n) step(s), pinned \(String(format: "%.2f", pinned)) s")
            }
        }
    }

    /// Emits the due repeat steps and schedules the next check.
    private func edgeTick() {
        guard edgeRepeat.isActive else { return }
        let t = ProcessInfo.processInfo.systemUptime
        var full: [ArrowDirection] = []
        let due = edgeRepeat.tick(at: t) { [arrowRoom] d in
            let ok = arrowRoom(d)
            if !ok { full.append(d) }
            return ok
        }
        // A full queue skips the tick: noted once per direction and pin.
        for d in full where !edgeFullNoted.contains(d) {
            edgeFullNoted.insert(d)
            Log.line("CURSORPAD edge-repeat \(d.symbol) waits: no room (2 of its steps still waiting for the key pacing, or the setting is off); ticks skipped silently while pinned")
        }
        for d in due {
            let n = edgeRepeat.pins[d]?.steps ?? 0
            let since = edgeRepeat.pins[d].map { t - $0.since } ?? 0
            let out = handle(.arrows([ArrowSteps(d, 1)]), language) ?? "arrows \(d.symbol)"
            Log.line("CURSORPAD edge-repeat \(d.symbol)#\(n) +\(String(format: "%.2f", since))s → \(out)")
        }
        guard let next = edgeRepeat.nextDueTime else { return }
        edgeTimerGeneration += 1
        let g = edgeTimerGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.001, next - t)) { [weak self] in
            guard let self, g == self.edgeTimerGeneration else { return }
            self.updateEdgeRepeat()
        }
    }

    private var edgeFullNoted: Set<ArrowDirection> = []

    // MARK: Self-test (`--selftest=compose`)

    /// Sets marked text as the keyboard does (setAttributedMarkedText, caret at the end).
    func selfTestMark(_ s: String) {
        setAttributedMarkedText(NSAttributedString(string: s), selectedRange: NSRange(location: (s as NSString).length, length: 0))
    }

    /// Ends the self-test composition without any mirror event (never a 確定).
    func selfTestDiscard() { discardText(reason: "self-test") }

    /// `--textcap-probe`: exercise the capture path and the cursor pad without the keyboard
    /// (nothing is sent: the controller only logs what it would send).
    private func startProbe() {
        probeStarted = true
        Log.line("TEXTCAP probe: setMarkedText in 1 s, unmarkText in 8 s, cursor pad probe from 10 s, edge repeat from 21 s (not routed, nothing sent)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.unmarkText()
        }
        let lh = Self.padFont.lineHeight, cw = Self.charWidth
        let steps: [(Double, String, @MainActor (CaptureTextView) -> Void)] = [
            (10.0, "caret down 2 rows (expect ↓×2)", { $0.probeMove(rows: 2, columns: 0) }),
            (11.0, "caret left 3 columns (expect ←×3)", { $0.probeMove(rows: 0, columns: -3) }),
            (11.1, "caret right 9, up 1 at once (expect →×9 ↑×1: cancels pending ←, cap 6 per direction drops the rest)", { $0.probeMove(rows: -1, columns: 9) }),
            (12.0, "non-empty selection (expect: collapsed, no keys)", { v in
                v.probeSelect(NSRange(location: v.padPrefix - 2, length: 4)) }),
            (13.0, "floating cursor begin at the caret", { v in v.probeFloatingBegin() }),
            (13.1, "floating cursor +1 row", { v in v.probeFloatingUpdate(dx: 0, dy: lh) }),
            (13.2, "floating cursor +2 rows", { v in v.probeFloatingUpdate(dx: 0, dy: 2 * lh) }),
            (13.3, "floating cursor +2 rows +2 cols", { v in v.probeFloatingUpdate(dx: 2 * cw, dy: 2 * lh) }),
            (13.4, "floating cursor +2 rows +4 cols", { v in v.probeFloatingUpdate(dx: 4 * cw, dy: 2 * lh) }),
            (13.8, "floating cursor end", { v in v.endFloatingCursor() }),
            (15.0, "floating cursor begin (edge test)", { v in v.probeFloatingBegin() }),
            (15.1, "floating cursor to 2 columns from the left edge (expect edge recentre mid-gesture)", { v in
                v.probeFloatingUpdate(dx: -CGFloat(v.grid.center.column - 2) * cw, dy: 0) }),
            (15.4, "floating cursor 1 more column left (expect snap-back or a relative move)", { v in
                v.probeFloatingUpdate(dx: -CGFloat(v.grid.center.column - 1) * cw, dy: 0) }),
            (15.8, "floating cursor end", { v in v.endFloatingCursor() }),
            (17.0, "marked text, then the caret inside it (expect: left to the IME)", { v in
                v.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0)) }),
            (17.3, "caret inside the marked text", { v in
                if let r = v.markedTextRange, let p = v.position(from: r.start, offset: 1) { v.selectedTextRange = v.textRange(from: p, to: p) } }),
            (17.8, "unmark (commit, not routed)", { v in v.unmarkText() }),
            (19.0, "caret up 1 row after the clear (expect ↑×1)", { $0.probeMove(rows: -1, columns: 0) }),
            // Edge repeat: the floating cursor is driven by hand (programmatic calls do not move
            // the caret), the caret is placed with selectedRange.
            (21.0, "edge: floating cursor begin", { v in v.probeFloatingBegin() }),
            (21.1, "edge: caret to column 0 (expect ←×16 capped, then edge-repeat start ←, steps after 300 ms every 100 ms)", { v in
                v.probeMoveTo(row: v.grid.center.row, column: 0) }),
            (22.6, "edge: caret to the corner r0c0 (expect ↑×7, edge-repeat start ↑; ← goes on)", { v in v.probeMoveTo(row: 0, column: 0) }),
            (25.0, "edge: caret off the edges r3c5 (expect edge-repeat stop ← and ↑)", { v in v.probeMoveTo(row: 3, column: 5) }),
            (25.3, "edge: caret on the bottom row, then floating cursor end before the delay (expect start ↓, stop ↓ with 0 steps)", { v in
                v.probeMoveTo(row: v.grid.rows - 1, column: 5) }),
            (25.5, "edge: floating cursor end", { v in v.endFloatingCursor() }),
            (26.5, "cursor pad probe done", { _ in }),
        ]
        // Floating cursor updates every 100 ms while the probe's gesture is on (as the keyboard does).
        for i in 0..<44 {
            let t = 21.05 + Double(i) * 0.1
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.probeFloatingUpdate(dx: 0, dy: 0) }
        }
        for (t, what, action) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                guard let self else { return }
                Log.line("CURSORPAD probe @\(t)s: \(what)")
                action(self)
            }
        }
    }

    private func probeMove(rows: Int, columns: Int) {
        let base = grid.position(ofOffset: selectedRange.location) ?? grid.center
        let o = grid.offset(of: PadPosition(row: base.row + rows, column: base.column + columns))
        probeSelect(NSRange(location: o, length: 0))
    }

    private func probeMoveTo(row: Int, column: Int) {
        probeSelect(NSRange(location: grid.offset(of: PadPosition(row: row, column: column)), length: 0))
    }

    private func probeSelect(_ r: NSRange) {
        let before = (lastCaret, lastSelLength)
        selectedRange = r
        if (lastCaret, lastSelLength) == before, (r.location, r.length) != before {
            Log.line("CURSORPAD probe: no selection callback for the programmatic selection; calling the handler directly")
            delegateDidChangeSelection()
        }
    }

    private func probeFloatingBegin() {
        let p = caretRect(for: selectedTextRange?.start ?? beginningOfDocument)
        fcProbeOrigin = CGPoint(x: p.midX, y: p.midY)
        beginFloatingCursor(at: fcProbeOrigin)
    }

    private var fcProbeOrigin = CGPoint.zero

    private func probeFloatingUpdate(dx: CGFloat, dy: CGFloat) {
        updateFloatingCursor(at: CGPoint(x: fcProbeOrigin.x + dx, y: fcProbeOrigin.y + dy))
    }

    // MARK: Clearing

    /// When nothing is marked any more, clear the field on the next run-loop turn (re-checked
    /// then, so an active composition is never disturbed).
    private func afterCapture() {
        let c = content
        onText(c)
        if markedTextRange == nil, c.isEmpty, !padIntact {
            Log.line("CURSORPAD pad damaged by an edit with no content: pad rebuilt")
            suppressMirror = true
            resetPad("repair")
            suppressMirror = false
            seenMarked = nil
            seenText = ""
            return
        }
        guard markedTextRange == nil, !c.isEmpty, !clearScheduled else { return }
        clearScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.clearScheduled = false
            guard self.markedTextRange == nil, !self.content.isEmpty else { return }
            let cleared = self.content
            self.suppressMirror = true
            self.resetPad("clear")
            self.suppressMirror = false
            self.seenMarked = nil
            self.seenText = ""
            self.onText("")
            self.log("clear (committed, nothing marked) cleared=\(Log.q(cleared))", self.handle(.cleared(cleared), self.language))
        }
    }

    // MARK: Logging

    private func snapshot() -> String { "text=\(Log.q(content))\(markedText())" }

    private func markedText() -> String {
        guard let m = markedTextRange else { return " marked=nil" }
        return " marked=[\(contentOffset(m.start)),\(contentOffset(m.end)))\(Log.q(self.text(in: m) ?? ""))"
    }

    private func selectionText() -> String {
        guard let s = selectedTextRange else { return "nil" }
        return "[\(contentOffset(s.start)),\(contentOffset(s.end)))"
    }

    /// One line per event: `TEXTCAP +<ms since previous TEXTCAP> <event> lang=<…> text="…"
    /// marked=[a,b)"…"|nil sel=[a,b) [before: text=… marked=…] → <outcome>`. Offsets are UTF-16,
    /// relative to the content (the pad is not shown; a caret in the pad gives offsets outside).
    private func log(_ event: String, _ outcome: String?, before: String? = nil) {
        let t = ProcessInfo.processInfo.systemUptime
        let dt = lastLogTime.map { "+\(Int((t - $0) * 1000))ms" } ?? "first"
        lastLogTime = t
        var line = "TEXTCAP \(dt) \(event) lang=\(language ?? "nil") text=\(Log.q(content))\(markedText()) sel=\(selectionText())"
        if let before { line += " | before: \(before)" }
        if let outcome { line += " → \(outcome)" }
        Log.line(line)
    }
}

/// `UITextViewDelegate` for `CaptureTextView` (a separate object; the view stays plain).
final class CaptureDelegate: NSObject, UITextViewDelegate {
    weak var view: CaptureTextView?

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        view?.delegateShouldChange(range, text) ?? true
    }
    func textViewDidChange(_ textView: UITextView) { view?.delegateDidChange() }
    func textViewDidChangeSelection(_ textView: UITextView) { view?.delegateDidChangeSelection() }
    func textViewDidBeginEditing(_ textView: UITextView) { view?.delegateBeginEditing() }
    func textViewDidEndEditing(_ textView: UITextView) { view?.delegateEndEditing() }
}
