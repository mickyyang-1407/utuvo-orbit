import AppKit
import QuartzCore

/// A small, always discoverable handle while the cat is tucked behind the edge.
final class TailPeekView: NSView {
    private let tailLayer = CALayer()
    private var downLocation: NSPoint?
    private var moveGesture = ShelfMoveGesture()
    private var displayObserver: NSObjectProtocol?
    private(set) var isWagging = false
    var isOnLeft = false { didSet { if oldValue != isOnLeft { needsLayout = true } } }
    var isPresented = true { didSet { updateWag() } }
    var reduceMotionOverride: Bool? { didSet { updateWag() } }
    var onClick: (() -> Void)?
    var onMove: ((NSPoint) -> Void)?
    var onMoveEnded: (() -> Void)?
    var contextMenu: (() -> NSMenu?)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        tailLayer.contentsGravity = .resizeAspect
        tailLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        if let url = Bundle.module.url(forResource: "drop-tail", withExtension: "png", subdirectory: "Assets"),
           let image = NSImage(contentsOf: url) {
            tailLayer.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        layer?.addSublayer(tailLayer)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("貓咪尾巴，點一下查看保管的檔案")
        toolTip = "把檔案拖到尾巴旁，貓咪就會出來。點一下查看清單。"
        displayObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.updateWag() }
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    deinit { if let displayObserver { NSWorkspace.shared.notificationCenter.removeObserver(displayObserver) } }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { isPresented && super.hitTest(point) != nil ? self : nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateWag() }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        tailLayer.bounds = CGRect(origin: .zero, size: bounds.size)
        tailLayer.anchorPoint = CGPoint(x: 0.92, y: 0.9)
        tailLayer.position = CGPoint(x: bounds.width * (isOnLeft ? 0.08 : 0.92), y: bounds.height * 0.9)
        tailLayer.transform = CATransform3DMakeScale(isOnLeft ? -1 : 1, 1, 1)
        CATransaction.commit()
    }
    func updateWag() {
        let reduce = reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let shouldWag = isPresented && window != nil && !reduce
        guard shouldWag != isWagging else { return }
        isWagging = shouldWag
        tailLayer.removeAnimation(forKey: "wag")
        guard shouldWag else { return }
        // Two little swishes, then a rest. Entirely composited; no polling timer.
        let wag = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        wag.values = [0, -0.12, 0.10, -0.06, 0, 0]
        wag.keyTimes = [0, 0.12, 0.24, 0.36, 0.46, 1]
        wag.duration = 4.6
        wag.repeatCount = .infinity
        wag.calculationMode = .cubic
        tailLayer.add(wag, forKey: "wag")
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }
    override func mouseDown(with event: NSEvent) {
        downLocation = event.locationInWindow
        moveGesture.begin(at: ShelfMoveGesture.point(event, in: self))
    }
    override func mouseDragged(with event: NSEvent) {
        if let delta = moveGesture.delta(to: ShelfMoveGesture.point(event, in: self)) { onMove?(delta) }
    }
    override func mouseUp(with event: NSEvent) {
        if moveGesture.moved { onMoveEnded?() }
        else if downLocation != nil, bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
        downLocation = nil; moveGesture.end()
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 36 { onClick?() }
        else { super.keyDown(with: event) }
    }
}
