import AppKit

/// Explicit drag grip: uses the same native file-URL session as individual rows.
final class ShelfDragHandle: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "Drag all files")
    private var mouseDownLocation: NSPoint?
    var onDragRequested: ((NSEvent) -> Void)?
    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue; needsLayout = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 16
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .systemBrown
        icon.image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        icon.contentTintColor = .systemBrown
        addSubview(icon)
        addSubview(label)
        toolTip = "Drag this handle to send all files to another app."
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        updateFill()
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func layout() {
        super.layout()
        let width = min(label.intrinsicContentSize.width, max(1, bounds.width - 48))
        let x = (bounds.width - width - 24) / 2
        icon.frame = NSRect(x: x, y: bounds.midY - 8, width: 16, height: 16)
        label.frame = NSRect(x: x + 24, y: bounds.midY - 9, width: width, height: 18)
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateFill() }
    private func updateFill() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(mouseDownLocation == nil ? 0.14 : 0.24).cgColor
        }
    }
    override func mouseDown(with event: NSEvent) { mouseDownLocation = event.locationInWindow; updateFill() }
    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownLocation,
              hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) >= 4 else { return }
        mouseDownLocation = nil
        updateFill()
        onDragRequested?(event)
    }
    override func mouseUp(with event: NSEvent) { mouseDownLocation = nil; updateFill() }
}
