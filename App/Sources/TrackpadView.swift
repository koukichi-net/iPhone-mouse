import SwiftUI
import UIKit
import HIDCore

/// The touch surface (design §8.3): one large rounded rectangle, raw UIKit touches, no
/// SwiftUI gestures. The click buttons are separate views (`PressButton`) below it; a finger
/// can hold one while another finger moves here (drag), because UIKit delivers touches on
/// different views independently.
struct TrackpadView: UIViewRepresentable {
    let input: InputController
    var strip: ScrollStripLayout = ScrollStripLayout()

    func makeUIView(context: Context) -> TouchSurfaceView {
        TouchSurfaceView(input: input)
    }

    func updateUIView(_ uiView: TouchSurfaceView, context: Context) {
        uiView.strip = strip
    }
}

final class TouchSurfaceView: UIView {
    private let input: InputController
    private var ids: [ObjectIdentifier: Int] = [:]
    private var nextID = 1
    /// The scroll strip: a slightly lighter lane with two small chevrons (understated).
    private let stripView = UIView()
    private let stripDivider = UIView()
    private let chevronUp = UIImageView()
    private let chevronDown = UIImageView()
    /// Faint grid with dots at the intersections (decoration only: layers take no touches).
    private let gridLines = CAShapeLayer()
    private let gridDots = CAShapeLayer()
    private var gridKey: (CGSize, ClosedRange<Double>?)?
    var strip = ScrollStripLayout() {
        didSet { if strip != oldValue { setNeedsLayout() } }
    }

    init(input: InputController) {
        self.input = input
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        isExclusiveTouch = false
        backgroundColor = Theme.surface
        layer.cornerRadius = 30
        layer.cornerCurve = .continuous
        layer.borderWidth = 0.5
        layer.borderColor = Theme.surfaceBorder.cgColor
        clipsToBounds = true
        stripView.backgroundColor = Theme.strip
        stripView.isUserInteractionEnabled = false
        stripDivider.backgroundColor = Theme.surfaceBorder
        stripDivider.isUserInteractionEnabled = false
        let cfg = UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        chevronUp.image = UIImage(systemName: "chevron.up", withConfiguration: cfg)
        chevronDown.image = UIImage(systemName: "chevron.down", withConfiguration: cfg)
        for v in [chevronUp, chevronDown] {
            v.tintColor = Theme.stripMark
            v.contentMode = .center
        }
        gridLines.fillColor = Theme.gridLine.cgColor
        gridDots.fillColor = Theme.gridDot.cgColor
        layer.addSublayer(gridLines)
        layer.addSublayer(gridDots)
        addSubview(stripView)
        addSubview(stripDivider)
        stripView.addSubview(chevronUp)
        stripView.addSubview(chevronDown)
        isAccessibilityElement = true
        accessibilityLabel = "トラックパッド"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateGrid()
        guard let r = strip.xRange(surfaceWidth: Double(bounds.width)) else {
            stripView.isHidden = true
            stripDivider.isHidden = true
            accessibilityHint = nil
            return
        }
        stripView.isHidden = false
        stripDivider.isHidden = false
        let x0 = CGFloat(r.lowerBound), w = CGFloat(r.upperBound - r.lowerBound)
        stripView.frame = CGRect(x: x0, y: 0, width: w, height: bounds.height)
        let dividerX = strip.edge == .right ? x0 : x0 + w - 0.5
        stripDivider.frame = CGRect(x: dividerX, y: 0, width: 0.5, height: bounds.height)
        let mid = bounds.height / 2
        chevronUp.frame = CGRect(x: 0, y: mid - 26, width: w, height: 16)
        chevronDown.frame = CGRect(x: 0, y: mid + 10, width: w, height: 16)
        accessibilityHint = strip.edge == .right ? "右端の帯を上下になぞるとスクロールします" : "左端の帯を上下になぞるとスクロールします"
    }

    // MARK: Grid pattern

    /// Cell size in points; the same when the surface shrinks for the key panel (fewer cells).
    static let gridPitch: CGFloat = 36
    /// Distance from the surface's edges (clear of the rounded corners) and from the strip lane.
    static let gridMargin: CGFloat = 22
    static let gridDotDiameter: CGFloat = 2.5

    /// Rebuilds the pattern when the size or the strip changes (never per touch or frame). The
    /// grid is centred in the area left of / right of the strip and ends on its outer dots.
    private func updateGrid() {
        let range = strip.xRange(surfaceWidth: Double(bounds.width))
        if let k = gridKey, k.0 == bounds.size, k.1 == range { return }
        gridKey = (bounds.size, range)
        var area = bounds.insetBy(dx: Self.gridMargin, dy: Self.gridMargin)
        if let r = range {
            if strip.edge == .right {
                area.size.width = max(0, CGFloat(r.lowerBound) - Self.gridMargin - area.minX)
            } else {
                let left = CGFloat(r.upperBound) + Self.gridMargin
                area.size.width = max(0, area.maxX - left)
                area.origin.x = left
            }
        }
        let scale = window?.screen.scale ?? traitCollection.displayScale
        let px = 1 / max(1, scale)
        func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        let p = Self.gridPitch
        let cols = Int(area.width / p), rows = Int(area.height / p)
        let lines = CGMutablePath(), dots = CGMutablePath()
        if cols >= 1, rows >= 1 {
            let x0 = snap(area.minX + (area.width - CGFloat(cols) * p) / 2)
            let y0 = snap(area.minY + (area.height - CGFloat(rows) * p) / 2)
            let w = CGFloat(cols) * p, h = CGFloat(rows) * p
            // Hairlines as 1-pixel rectangles on pixel boundaries (crisp, no anti-aliasing).
            for c in 0...cols { lines.addRect(CGRect(x: snap(x0 + CGFloat(c) * p), y: y0, width: px, height: h + px)) }
            for r in 0...rows { lines.addRect(CGRect(x: x0, y: snap(y0 + CGFloat(r) * p), width: w + px, height: px)) }
            let d = Self.gridDotDiameter
            for c in 0...cols {
                for r in 0...rows {
                    let cx = snap(x0 + CGFloat(c) * p) + px / 2, cy = snap(y0 + CGFloat(r) * p) + px / 2
                    dots.addEllipse(in: CGRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d))
                }
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gridLines.frame = bounds
        gridDots.frame = bounds
        gridLines.path = lines
        gridDots.path = dots
        CATransaction.commit()
    }

    private func event(_ t: UITouch, id: Int, phase: TouchPhase) -> TouchEvent {
        let p = t.location(in: self)
        let loc = Vector2(Double(p.x), Double(p.y))
        let zone = phase == .began ? strip.zone(at: loc, surfaceWidth: Double(bounds.width)) : .surface
        return TouchEvent(id: id, phase: phase, location: loc, timestamp: t.timestamp, zone: zone)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        var events: [TouchEvent] = []
        for t in touches {
            let id = nextID
            nextID &+= 1
            ids[ObjectIdentifier(t)] = id
            events.append(self.event(t, id: id, phase: .began))
        }
        feed(events)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        var events: [TouchEvent] = []
        for t in touches {
            guard let id = ids[ObjectIdentifier(t)] else { continue }
            // Coalesced samples carry the full-rate path (each with its own timestamp); the
            // touch itself is the last of them, so it is not fed separately.
            let samples = event?.coalescedTouches(for: t) ?? [t]
            for s in (samples.isEmpty ? [t] : samples) {
                events.append(self.event(s, id: id, phase: .moved))
            }
        }
        events.sort { $0.timestamp < $1.timestamp }
        feed(events)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, phase: .ended)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, phase: .cancelled)
    }

    private func finish(_ touches: Set<UITouch>, phase: TouchPhase) {
        var events: [TouchEvent] = []
        for t in touches {
            if let id = ids.removeValue(forKey: ObjectIdentifier(t)) {
                events.append(self.event(t, id: id, phase: phase))
            }
        }
        feed(events)
    }

    private func feed(_ events: [TouchEvent]) {
        guard !events.isEmpty else { return }
        input.handleTouches(events)
    }
}

/// Colours shared by the UIKit and SwiftUI parts (near-black, Apple TV Remote–like).
enum Theme {
    static let background = UIColor(white: 0.035, alpha: 1)
    static let surface = UIColor(white: 0.115, alpha: 1)
    static let surfaceBorder = UIColor(white: 0.18, alpha: 1)
    static let strip = UIColor(white: 0.135, alpha: 1)
    static let stripMark = UIColor(white: 0.36, alpha: 1)
    /// Trackpad grid: hairlines a little lighter than `surface`, dots a little brighter.
    static let gridLine = UIColor(white: 0.16, alpha: 1)
    static let gridDot = UIColor(white: 0.22, alpha: 1)
    static let button = UIColor(white: 0.17, alpha: 1)
    static let buttonPressed = UIColor(white: 0.32, alpha: 1)
    static let key = UIColor(white: 0.16, alpha: 1)
    static let keyPressed = UIColor(white: 0.34, alpha: 1)
    static let label = UIColor(white: 0.88, alpha: 1)
    static let secondaryLabel = UIColor(white: 0.55, alpha: 1)
    static let latched = UIColor.systemBlue.withAlphaComponent(0.45)
    static let locked = UIColor.systemBlue
    static let ledOn = UIColor.systemGreen

    static var backgroundColor: Color { Color(uiColor: background) }
}
