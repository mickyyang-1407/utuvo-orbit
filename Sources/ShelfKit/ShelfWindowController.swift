import AppKit

/// All geometry is based on the chosen screen's visible frame, including negative origins.
enum ShelfLayout {
    enum Edge { case left, right }
    static let collapsedWidth: CGFloat = 136
    static let collapsedHeight: CGFloat = 144
    static let thoughtGap: CGFloat = 48
    static let expandedWidth: CGFloat = 340
    static let itemHeight: CGFloat = 62

    static func frame(in visible: NSRect, edge: Edge, expanded: Bool, count: Int) -> NSRect {
        let inset = min(8, max(0, min(visible.width, visible.height) / 4))
        let width = min(expanded ? expandedWidth : collapsedWidth, max(1, visible.width - 2 * inset))
        let height = min(expanded ? collapsedHeight + thoughtGap + (count == 0 ? 176 : min(422, 156 + CGFloat(count) * itemHeight)) : collapsedHeight,
                         max(1, visible.height - 2 * inset))
        return NSRect(x: edge == .right ? visible.maxX - width : visible.minX,
                      y: max(visible.minY + inset, min(visible.midY - collapsedHeight / 2, visible.maxY - inset - height)),
                      width: width, height: height)
    }
}

/// Pet origin is independent of the larger thought bubble, so opening it never moves the cat.
struct ShelfPlacement {
    var frame: NSRect
    var petOffsetX: CGFloat
    var bubbleAbove: Bool
    static func clamp(_ point: NSPoint, to visible: NSRect) -> NSPoint {
        NSPoint(x: min(max(point.x, visible.minX), max(visible.minX, visible.maxX - ShelfLayout.collapsedWidth)),
                y: min(max(point.y, visible.minY), max(visible.minY, visible.maxY - ShelfLayout.collapsedHeight)))
    }
    static func screenIndex(for point: NSPoint, frames: [NSRect]) -> Int? {
        frames.indices.min { a, b in
            func distance(_ r: NSRect) -> CGFloat {
                let x = max(r.minX - point.x, 0, point.x - r.maxX)
                let y = max(r.minY - point.y, 0, point.y - r.maxY)
                return x * x + y * y
            }
            return distance(frames[a]) < distance(frames[b])
        }
    }
    static func make(origin: NSPoint, visible: NSRect, expanded: Bool, count: Int, onLeft: Bool) -> Self {
        let origin = clamp(origin, to: visible)
        let petHeight = min(ShelfLayout.collapsedHeight, visible.height)
        let width = min(expanded ? ShelfLayout.expandedWidth : ShelfLayout.collapsedWidth, visible.width)
        let above = max(0, visible.maxY - origin.y - petHeight)
        let below = max(0, origin.y - visible.minY)
        let desired = ShelfLayout.thoughtGap + (count == 0 ? 176 : min(422, 156 + CGFloat(count) * ShelfLayout.itemHeight))
        let bubbleAbove = above >= desired || above >= below
        let extra = expanded ? min(desired, bubbleAbove ? above : below) : 0
        let preferredX = origin.x - (onLeft ? 0 : width - min(ShelfLayout.collapsedWidth, width))
        let x = min(max(preferredX, visible.minX), visible.maxX - width)
        return Self(frame: NSRect(x: x, y: origin.y - (bubbleAbove ? 0 : extra), width: width, height: petHeight + extra),
                    petOffsetX: origin.x - x, bubbleAbove: bubbleAbove)
    }
}

private final class ShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class ShelfWindowController: NSWindowController {
    let viewModel: ShelfViewModel
    let content: ShelfContentView
    let settings: DropSettings
    private(set) var edge: ShelfLayout.Edge = .right
    private(set) var petOrigin = NSPoint.zero
    private var screenObserver: NSObjectProtocol?

    init(viewModel: ShelfViewModel = ShelfViewModel(), settings: DropSettings = DropSettings()) {
        self.viewModel = viewModel
        self.settings = settings
        content = ShelfContentView(viewModel: viewModel, strings: settings.strings)
        let panel = ShelfPanel(contentRect: content.frame,
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.title = "UTUVO Orbit · File Shelf"
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.contentView = content
        super.init(window: panel)
        edge = settings.petOnLeft ? .left : .right
        let visible = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        petOrigin = settings.savedOrigin ?? ShelfLayout.frame(in: visible, edge: edge, expanded: false, count: 0).origin
        content.onSizeChanged = { [weak self] in self?.position() }
        content.onMove = { [weak self] delta in self?.move(by: delta) }
        content.onMoveEnded = { [weak self] in self?.finishMoving() }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.position() }
        position()
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    deinit { if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) } }
    private var screen: NSScreen? {
        let screens = NSScreen.screens
        let center = NSPoint(x: petOrigin.x + ShelfLayout.collapsedWidth / 2, y: petOrigin.y + ShelfLayout.collapsedHeight / 2)
        guard let index = ShelfPlacement.screenIndex(for: center, frames: screens.map(\.visibleFrame)) else { return nil }
        return screens[index]
    }
    func reload() { content.reload(); position() }
    func cycleEdge() {
        edge = edge == .right ? .left : .right
        guard let visible = screen?.visibleFrame else { return }
        petOrigin.x = edge == .left ? visible.minX : visible.maxX - ShelfLayout.collapsedWidth
        settings.petOnLeft = edge == .left
        position(); settings.savedOrigin = petOrigin
    }
    func resetPosition() {
        guard let visible = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame else { return }
        edge = .right; settings.petOnLeft = false
        petOrigin = ShelfLayout.frame(in: visible, edge: edge, expanded: false, count: 0).origin
        position(); settings.savedOrigin = petOrigin
    }
    func showShelf() { position(); window?.orderFrontRegardless() }
    func changeLanguage(_ language: DropLanguage) {
        settings.language = language
        content.apply(strings: settings.strings)
    }
    func move(by delta: NSPoint) {
        guard let window else { return }
        content.isMoving = true
        petOrigin.x += delta.x; petOrigin.y += delta.y
        // Keep the current layout frozen under the pointer; fit the bubble only on release.
        window.setFrameOrigin(NSPoint(x: window.frame.minX + delta.x, y: window.frame.minY + delta.y))
    }
    func finishMoving() {
        content.isMoving = false
        position(); settings.savedOrigin = petOrigin
    }
    func position() {
        guard !content.isMoving, let visible = screen?.visibleFrame else { return }
        petOrigin = ShelfPlacement.clamp(petOrigin, to: visible)
        let placement = ShelfPlacement.make(origin: petOrigin, visible: visible, expanded: content.isExpanded,
                                             count: viewModel.allItems.count, onLeft: edge == .left)
        content.petOnLeft = edge == .left
        content.petOffsetX = placement.petOffsetX
        content.bubbleAbove = placement.bubbleAbove
        window?.setFrame(placement.frame, display: true)
        content.needsLayout = true
    }
}
