import AppKit
import QuartzCore

/// The pet is the real drag handle. Only the belly scales; its head and paws stay put.
final class CatPetView: NSView {
    enum Mood: Equatable { case idle, hungry, chewing, giving }
    private let body = CALayer()
    private let head = CALayer()
    private let openHead = CALayer()
    private let paws = CALayer()
    private let floorShadow = CALayer()
    private var mouseDownLocation: NSPoint?
    private var didDrag = false
    private var moving = false
    private var moveGesture = ShelfMoveGesture()
    var strings = DropStrings()
    var onMove: ((NSPoint) -> Void)?
    var onMoveEnded: (() -> Void)?
    var contextMenu: (() -> NSMenu?)?
    private var chewTask: Task<Void, Never>?
    private(set) var mood: Mood = .idle
    private(set) var fileCount = 0
    private(set) var bellyScale: CGFloat = 1
    var onClick: (() -> Void)?
    var onDragRequested: ((NSEvent) -> Void)?
    var interactionEnabled = true
    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var drawingScale: CGFloat { min(bounds.width / 200, bounds.height / 218) }
    var mouthPoint: NSPoint { NSPoint(x: bounds.midX, y: 117 * drawingScale) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for part in [floorShadow, body, head, openHead, paws] {
            part.contentsGravity = .resizeAspect
            part.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            layer?.addSublayer(part)
        }
        floorShadow.shadowColor = NSColor.black.cgColor
        floorShadow.shadowOpacity = 0.16
        floorShadow.shadowRadius = 7
        floorShadow.shadowOffset = .zero
        if let url = Bundle.module.url(forResource: "drop-cat-atlas", withExtension: "png", subdirectory: "Assets"),
           let image = NSImage(contentsOf: url), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            // Atlas parts have transparent margins; regions are normalized to the original.
            func crop(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGImage? {
                cg.cropping(to: CGRect(x: x * CGFloat(cg.width), y: y * CGFloat(cg.height),
                                      width: w * CGFloat(cg.width), height: h * CGFloat(cg.height)))
            }
            head.contents = crop(0, 0.080, 0.493, 0.42)
            openHead.contents = crop(0.493, 0.080, 0.507, 0.42)
            body.contents = crop(0.009, 0.556, 0.594, 0.361)
            paws.contents = crop(0.633, 0.793, 0.279, 0.14)
        }
        openHead.opacity = 0
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Drop cat. Drop files to feed me; click to see files.")
        toolTip = "Drop files to feed me. Drag me to take them out. Click to see the list."
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { !interactionEnabled || super.hitTest(point) == nil ? nil : self }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let cx = bounds.midX
        let s = drawingScale
        floorShadow.frame = CGRect(x: cx - 49 * s, y: 194 * s, width: 98 * s, height: 13 * s)
        floorShadow.shadowPath = CGPath(ellipseIn: floorShadow.bounds, transform: nil)
        body.bounds = CGRect(x: 0, y: 0, width: 126 * s, height: 83 * s)
        body.anchorPoint = CGPoint(x: 0.40, y: 1)
        body.position = CGPoint(x: cx, y: 201 * s)
        head.frame = CGRect(x: cx - 88 * s, y: 6 * s, width: 176 * s, height: 150 * s)
        openHead.frame = head.frame
        paws.frame = CGRect(x: cx - 37 * s, y: 178 * s, width: 74 * s, height: 37 * s)
        CATransaction.commit()
    }

    func update(count: Int, mood nextMood: Mood, animated: Bool = true) {
        let changed = count != fileCount
        fileCount = count
        mood = nextMood
        bellyScale = 1 + min(CGFloat(count), 10) * 0.042
        let target = CATransform3DMakeScale(bellyScale, 1 + min(CGFloat(count), 10) * 0.019, 1)
        let previous = body.presentation()?.transform ?? body.transform
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body.transform = target
        let mouthOpen = nextMood != .idle
        openHead.opacity = mouthOpen ? 1 : 0
        head.opacity = mouthOpen ? 0 : 1
        CATransaction.commit()
        if changed, animated, !reduceMotion {
            let spring = CASpringAnimation(keyPath: "transform")
            spring.fromValue = NSValue(caTransform3D: previous)
            spring.toValue = NSValue(caTransform3D: target)
            spring.mass = 1; spring.stiffness = 280; spring.damping = 24
            spring.duration = 0.32
            body.add(spring, forKey: "belly")
        } else if reduceMotion || !animated { body.removeAllAnimations() }
        setAccessibilityValue(strings.count(count))
    }

    func chew() {
        chewTask?.cancel()
        update(count: fileCount, mood: .chewing)
        if !reduceMotion {
            let nod = CAKeyframeAnimation(keyPath: "transform.translation.y")
            nod.values = [0, 3, 0, 2, 0]
            nod.keyTimes = [0, 0.25, 0.5, 0.75, 1]
            nod.duration = 0.28
            head.add(nod, forKey: "chew"); openHead.add(nod, forKey: "chew")
        }
        chewTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled, let self, self.mood == .chewing else { return }
            self.update(count: self.fileCount, mood: .idle)
        }
    }

    /// A local copy of the icon converges on the same mouth used by native drag-out.
    func swallow(_ image: NSImage) {
        guard !reduceMotion else { return }
        let morsel = CALayer()
        morsel.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        morsel.frame = CGRect(x: mouthPoint.x - 17, y: mouthPoint.y - 55, width: 34, height: 34)
        layer?.addSublayer(morsel)
        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = NSValue(point: morsel.position)
        move.toValue = NSValue(point: mouthPoint)
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1; scale.toValue = 0.2
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1; fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [move, scale, fade]; group.duration = 0.24
        group.timingFunction = CAMediaTimingFunction(name: .easeIn)
        CATransaction.begin()
        CATransaction.setCompletionBlock { morsel.removeFromSuperlayer() }
        morsel.add(group, forKey: "swallow")
        morsel.opacity = 0
        CATransaction.commit()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }
    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
        didDrag = false
        moving = fileCount == 0 || event.modifierFlags.contains(.option)
        moveGesture.begin(at: ShelfMoveGesture.point(event, in: self))
    }
    override func mouseDragged(with event: NSEvent) {
        if moving {
            if let delta = moveGesture.delta(to: ShelfMoveGesture.point(event, in: self)) { didDrag = true; onMove?(delta) }
            return
        }
        guard fileCount > 0, !didDrag, let start = mouseDownLocation,
              hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) >= 4 else { return }
        didDrag = true
        onDragRequested?(event)
    }
    override func mouseUp(with event: NSEvent) {
        defer { mouseDownLocation = nil; didDrag = false; moving = false; moveGesture.end() }
        if moving && moveGesture.moved { onMoveEnded?() }
        if !didDrag, mouseDownLocation != nil, bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 36 { onClick?() }
        else { super.keyDown(with: event) }
    }
}
