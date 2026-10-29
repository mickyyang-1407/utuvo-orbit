import AppKit
import QuartzCore

/// A soft cloud around the real file controls, with a trail back to the cat.
final class ThoughtBubbleView: NSView {
    private let cloud = CAShapeLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        cloud.lineWidth = 1
        cloud.shadowColor = NSColor.black.cgColor
        cloud.shadowOpacity = 0.10
        cloud.shadowRadius = 6
        cloud.shadowOffset = CGSize(width: 0, height: 2)
        layer?.addSublayer(cloud)
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        let r = bounds.insetBy(dx: 12, dy: 12)
        let w = r.width, h = r.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x, y: r.minY + y) }
        let path = CGMutablePath()
        path.move(to: p(w * 0.15, 14))
        path.addCurve(to: p(w * 0.34, 7), control1: p(w * 0.18, -5), control2: p(w * 0.27, -5))
        path.addCurve(to: p(w * 0.59, 7), control1: p(w * 0.40, -7), control2: p(w * 0.53, -7))
        path.addCurve(to: p(w * 0.83, 14), control1: p(w * 0.68, -6), control2: p(w * 0.80, -4))
        path.addCurve(to: p(w - 10, 47), control1: p(w - 14, 7), control2: p(w + 5, 25))
        path.addCurve(to: p(w - 6, h * 0.5), control1: p(w + 8, h * 0.27), control2: p(w + 7, h * 0.42))
        path.addCurve(to: p(w - 10, h - 47), control1: p(w + 8, h * 0.64), control2: p(w + 7, h - 42))
        path.addCurve(to: p(w * 0.82, h - 14), control1: p(w + 3, h - 14), control2: p(w * 0.91, h + 2))
        path.addCurve(to: p(w * 0.58, h - 7), control1: p(w * 0.76, h + 7), control2: p(w * 0.65, h + 5))
        path.addCurve(to: p(w * 0.34, h - 7), control1: p(w * 0.50, h + 8), control2: p(w * 0.41, h + 8))
        path.addCurve(to: p(w * 0.15, h - 14), control1: p(w * 0.25, h + 7), control2: p(w * 0.17, h + 4))
        path.addCurve(to: p(10, h - 47), control1: p(5, h - 12), control2: p(-5, h - 28))
        path.addCurve(to: p(6, h * 0.5), control1: p(-8, h * 0.70), control2: p(-7, h * 0.59))
        path.addCurve(to: p(10, 47), control1: p(-8, h * 0.35), control2: p(-7, 40))
        path.addCurve(to: p(w * 0.15, 14), control1: p(-3, 16), control2: p(w * 0.07, 2))
        path.closeSubpath()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        cloud.path = path; cloud.shadowPath = path
        CATransaction.commit()
    }
    static func colors(for appearance: NSAppearance) -> (fill: NSColor, stroke: NSColor) {
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return dark
            ? (NSColor(calibratedRed: 0.20, green: 0.19, blue: 0.18, alpha: 1), NSColor.white.withAlphaComponent(0.12))
            : (NSColor(calibratedRed: 1, green: 0.985, blue: 0.965, alpha: 1), NSColor(calibratedRed: 0.63, green: 0.44, blue: 0.28, alpha: 0.17))
    }
    private func updateColors() {
        let colors = Self.colors(for: effectiveAppearance)
        cloud.fillColor = colors.fill.cgColor; cloud.strokeColor = colors.stroke.cgColor
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColors() }
}

final class ThoughtTrailView: NSView {
    var catCenterX: CGFloat = 0 { didSet { needsDisplay = true } }
    var isOnLeft = false { didSet { needsDisplay = true } }
    var bubbleAbove = true { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let colors = ThoughtBubbleView.colors(for: effectiveAppearance)
        let direction: CGFloat = isOnLeft ? 1 : -1
        for (offset, y, size): (CGFloat, CGFloat, CGFloat) in [(42, 1, 18), (24, 25, 12), (10, 42, 6)] {
            let circle = NSBezierPath(ovalIn: NSRect(x: catCenterX + direction * offset - size / 2, y: bubbleAbove ? y : bounds.height - y - size, width: size, height: size))
            colors.fill.setFill(); circle.fill()
            colors.stroke.setStroke(); circle.lineWidth = 1; circle.stroke()
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}
