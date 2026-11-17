import SwiftUI
import UIKit
import HIDCore

/// Clicker screen (design §8.5), in the style of the main screen (§8.3): two large rounded
/// surfaces — upper half 次へ, lower half 前へ — and a large round ポインター button over the
/// boundary. Made to be used without looking: the halves are as large as the screen allows,
/// and next / previous have different haptics.
struct ClickerScreen: View {
    let model: AppModel
    @State private var motionRefused = ClickerController.motionRefused

    var body: some View {
        VStack(spacing: 8) {
            ClickerPad(clicker: model.clicker)
                .padding(.horizontal, 14)
                .padding(.top, 4)
            if motionRefused {
                Text("モーションが許可されていません（ポインターは動きません）")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
        }
        .padding(.bottom, 10)
        .onAppear {
            model.clicker.prepareMotion { motionRefused = ClickerController.motionRefused }
        }
        .onDisappear { model.clicker.endHold(reason: "clicker screen closed") }
    }
}

struct ClickerPad: UIViewRepresentable {
    let clicker: ClickerController

    func makeUIView(context: Context) -> ClickerPadView { ClickerPadView(clicker: clicker) }

    func updateUIView(_ v: ClickerPadView, context: Context) {}
}

/// Raw UIKit touches (as the trackpad). Touches that begin on the pointer button go to the
/// button (a subview); every other touch is tracked here by `ClickerTapTracker` and turns a
/// slide on lift if it stayed in its half.
final class ClickerPadView: UIView {
    private let clicker: ClickerController
    private var tracker = ClickerTapTracker()
    private var ids: [ObjectIdentifier: Int] = [:]
    private var nextID = 1
    private let upper = ZoneSurface(symbol: "chevron.right", title: "次へ")
    private let lower = ZoneSurface(symbol: "chevron.left", title: "前へ")
    private let button = PointerButtonView()
    static let gap: CGFloat = 12

    init(clicker: ClickerController) {
        self.clicker = clicker
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        addSubview(upper)
        addSubview(lower)
        addSubview(button)
        button.onDown = { [weak clicker] in clicker?.pointerDown() }
        button.onUp = { [weak clicker] reason in clicker?.endHold(reason: reason) }
        upper.accessibilityLabel = "次のスライド"
        lower.accessibilityLabel = "前のスライド"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var diameter: CGFloat { min(140, bounds.width * 0.38) }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width, h = bounds.height
        let half = (h - Self.gap) / 2
        upper.frame = CGRect(x: 0, y: 0, width: w, height: half)
        lower.frame = CGRect(x: 0, y: half + Self.gap, width: w, height: half)
        let d = diameter
        button.frame = CGRect(x: (w - d) / 2, y: (h - d) / 2, width: d, height: d)
        // Labels centred in the part of each half that the button does not cover.
        let free = max(0, half - (d - Self.gap) / 2)
        upper.labelCenterY = free / 2
        lower.labelCenterY = half - free / 2
    }

    /// Which half a point is in; over (or just around) the button counts as neither.
    private func zone(at p: CGPoint) -> ClickerZone {
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        if hypot(p.x - c.x, p.y - c.y) < diameter / 2 + 8 { return .outside }
        if !bounds.insetBy(dx: -20, dy: -20).contains(p) { return .outside }
        return p.y < bounds.midY ? .next : .previous
    }

    private func id(_ t: UITouch, create: Bool) -> Int? {
        let k = ObjectIdentifier(t)
        if let i = ids[k] { return i }
        guard create else { return nil }
        let i = nextID
        nextID += 1
        ids[k] = i
        return i
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            guard let i = id(t, create: true) else { continue }
            tracker.began(i, in: zone(at: t.location(in: self)))
        }
        refresh()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            guard let i = id(t, create: false) else { continue }
            tracker.moved(i, to: zone(at: t.location(in: self)))
        }
        refresh()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            guard let i = id(t, create: false) else { continue }
            ids[ObjectIdentifier(t)] = nil
            if let d = tracker.ended(i, in: zone(at: t.location(in: self))) {
                clicker.slide(d, zone: d == .next ? "upper half" : "lower half")
                (d == .next ? upper : lower).flash()
            }
        }
        refresh()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            guard let i = id(t, create: false) else { continue }
            ids[ObjectIdentifier(t)] = nil
            tracker.cancelled(i)
        }
        refresh()
    }

    /// Highlight a half while a valid touch rests in it.
    private func refresh() {
        let zones = ids.values.compactMap { tracker.zone(of: $0) }
        upper.setPressed(zones.contains(.next))
        lower.setPressed(zones.contains(.previous))
    }
}

/// One half: a large rounded surface with an understated icon and title.
final class ZoneSurface: UIView {
    private let icon = UIImageView()
    private let title = UILabel()
    var labelCenterY: CGFloat = 0 { didSet { setNeedsLayout() } }
    private var pressed = false

    init(symbol: String, title text: String) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false   // touches are handled by ClickerPadView
        backgroundColor = Theme.surface
        layer.cornerRadius = 34
        layer.cornerCurve = .continuous
        layer.borderWidth = 0.5
        layer.borderColor = Theme.surfaceBorder.cgColor
        icon.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 30, weight: .semibold))
        icon.tintColor = UIColor(white: 0.5, alpha: 1)
        icon.contentMode = .center
        title.text = text
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.textColor = UIColor(white: 0.62, alpha: 1)
        title.textAlignment = .center
        for v in [icon, title] { addSubview(v) }
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width
        let cy = labelCenterY
        icon.frame = CGRect(x: 0, y: cy - 34, width: w, height: 36)
        title.frame = CGRect(x: 0, y: cy + 6, width: w, height: 26)
    }

    func setPressed(_ p: Bool) {
        guard p != pressed else { return }
        pressed = p
        backgroundColor = p ? UIColor(white: 0.19, alpha: 1) : Theme.surface
    }

    /// Brief confirmation that a slide key was sent.
    func flash() {
        backgroundColor = UIColor(white: 0.26, alpha: 1)
        UIView.animate(withDuration: 0.25, delay: 0.05, options: [.allowUserInteraction]) {
            self.backgroundColor = self.pressed ? UIColor(white: 0.19, alpha: 1) : Theme.surface
        }
    }
}

/// The round ポインター button (icon only; the accessibility label names it): `onDown` on the
/// first finger, `onUp("lift" / "touch cancelled")` when the last finger leaves. Lit red while held.
final class PointerButtonView: UIView {
    var onDown: () -> Void = {}
    var onUp: (String) -> Void = { _ in }
    private let icon = UIImageView()
    private var touchCount = 0

    init() {
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        backgroundColor = Theme.button
        layer.borderWidth = 6
        layer.borderColor = Theme.background.cgColor   // separates it from the surfaces
        icon.tintColor = Theme.label
        icon.contentMode = .center
        addSubview(icon)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "ポインター（押している間）"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let d = min(bounds.width, bounds.height)
        layer.cornerRadius = d / 2
        icon.image = UIImage(systemName: "cursorarrow.rays", withConfiguration: UIImage.SymbolConfiguration(pointSize: d * 0.3, weight: .medium))
        icon.frame = bounds
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // Round hit area (corners belong to the halves' "neither" ring).
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        return hypot(point.x - c.x, point.y - c.y) <= bounds.width / 2
    }

    private func restyle() {
        let held = touchCount > 0
        backgroundColor = held ? UIColor(red: 0.78, green: 0.13, blue: 0.13, alpha: 1) : Theme.button
        icon.tintColor = held ? .white : Theme.label
    }

    override func touchesBegan(_ t: Set<UITouch>, with event: UIEvent?) {
        let first = touchCount == 0
        touchCount += t.count
        restyle()
        if first { onDown() }
    }

    override func touchesEnded(_ t: Set<UITouch>, with event: UIEvent?) { lift(t.count, "lift") }
    override func touchesCancelled(_ t: Set<UITouch>, with event: UIEvent?) { lift(t.count, "touch cancelled") }

    private func lift(_ n: Int, _ reason: String) {
        guard touchCount > 0 else { return }
        touchCount = max(0, touchCount - n)
        restyle()
        if touchCount == 0 { onUp(reason) }
    }
}
