import AppKit

/// Screen-space deltas keep tracking stable as the receiving window moves.
struct ShelfMoveGesture {
    private var last: NSPoint?
    private(set) var moved = false
    mutating func begin(at point: NSPoint) { last = point; moved = false }
    mutating func delta(to point: NSPoint) -> NSPoint? {
        guard let last else { return nil }
        let delta = NSPoint(x: point.x - last.x, y: point.y - last.y)
        guard moved || hypot(delta.x, delta.y) >= 4 else { return nil }
        moved = true; self.last = point
        return delta
    }
    mutating func end() { last = nil; moved = false }
    static func point(_ event: NSEvent, in view: NSView) -> NSPoint {
        view.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
    }
}

final class ShelfMoveHandle: NSView {
    private let icon = NSImageView()
    private var gesture = ShelfMoveGesture()
    var onMove: ((NSPoint) -> Void)?
    var onMoveEnded: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.image = NSImage(systemSymbolName: "arrow.up.and.down.and.arrow.left.and.right", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        addSubview(icon)
        setAccessibilityElement(true); setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func layout() { super.layout(); icon.frame = bounds.insetBy(dx: 4, dy: 4) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) {
        _ = accessibilityPerformPress()
        gesture.begin(at: ShelfMoveGesture.point(event, in: self))
    }
    override func mouseDragged(with event: NSEvent) {
        if let delta = gesture.delta(to: ShelfMoveGesture.point(event, in: self)) { onMove?(delta) }
    }
    override func mouseUp(with event: NSEvent) {
        if gesture.moved { onMoveEnded?() }
        gesture.end()
    }
    override func accessibilityPerformPress() -> Bool {
        window?.makeKey()
        return window?.makeFirstResponder(self) ?? false
    }
    override func keyDown(with event: NSEvent) {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 20 : 5
        let delta: NSPoint
        switch event.keyCode {
        case 123: delta = NSPoint(x: -step, y: 0)
        case 124: delta = NSPoint(x: step, y: 0)
        case 125: delta = NSPoint(x: 0, y: -step)
        case 126: delta = NSPoint(x: 0, y: step)
        default: super.keyDown(with: event); return
        }
        onMove?(delta); onMoveEnded?()
    }
}
