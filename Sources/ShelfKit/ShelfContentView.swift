import AppKit
import QuartzCore

/// A pet-sized native drop destination with an on-demand file list.
final class ShelfContentView: NSView, NSDraggingSource {
    let viewModel: ShelfViewModel
    private(set) var strings: DropStrings
    let moveHandle = ShelfMoveHandle()
    var petOffsetX: CGFloat?
    var bubbleAbove = true
    var isMoving = false
    var onMove: ((NSPoint) -> Void)?
    var onMoveEnded: (() -> Void)?
    var contextMenu: (() -> NSMenu?)?
    let cat = CatPetView(frame: .zero)
    let tail = TailPeekView(frame: .zero)
    private let card = ThoughtBubbleView(frame: .zero)
    private let thoughtTrail = ThoughtTrailView(frame: .zero)
    private let cardContent = FlippedView()
    private let titleLabel = NSTextField(labelWithString: "In my belly")
    private let emptyLabel = NSTextField(wrappingLabelWithString: "Drop files on the cat.\nI'll keep them handy for you.")
    private let footerLabel = NSTextField(labelWithString: "Originals stay right where they are.")
    private let scroll = NSScrollView()
    private let document = FlippedView()
    let closeButton = NSButton(title: "", target: nil, action: nil)
    let dragAllHandle = ShelfDragHandle()
    let clearButton = NSButton(title: "清空", target: nil, action: nil)
    private(set) var rowsByURL: [URL: ShelfItemRow] = [:]
    private(set) var isExpanded = false
    private(set) var isRevealed = false
    private(set) var incoming = false
    private(set) var outgoing = false
    private enum ReferenceError { case invalidDrop, invalidDrag }
    private var referenceError: ReferenceError?
    var errorMessage: String? {
        switch referenceError {
        case .invalidDrop: strings.invalidDrop
        case .invalidDrag: strings.invalidDrag
        case nil: nil
        }
    }
    private(set) var outgoingURLs: [URL] = []
    private var tracking: NSTrackingArea?
    private var hideTask: Task<Void, Never>?
    var onSizeChanged: (() -> Void)?
    var petOnLeft = false {
        didSet { tail.isOnLeft = petOnLeft; needsLayout = true }
    }
    var startSession: (([NSDraggingItem], NSEvent) -> Void)?
    /// Set by the host app (UTUVO Orbit's trial/unlock gate). `nil` accepts drops.
    var dropGate: (() -> Bool)?
    var onGatedDrop: (() -> Void)?
    var acceptsIncomingDrops: Bool { dropGate?() ?? true }

    init(viewModel: ShelfViewModel, strings: DropStrings = DropStrings()) {
        self.viewModel = viewModel
        self.strings = strings
        super.init(frame: NSRect(x: 0, y: 0, width: ShelfLayout.collapsedWidth, height: ShelfLayout.collapsedHeight))
        wantsLayer = true
        autoresizingMask = [.width, .height]
        card.addSubview(cardContent); cardContent.autoresizingMask = [.width, .height]
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        clearButton.bezelStyle = .rounded; clearButton.controlSize = .small
        clearButton.target = self; clearButton.action = #selector(clearShelf)
        clearButton.toolTip = "Clear the list. Original files stay in place."
        clearButton.setAccessibilityLabel("Clear shelf; keep original files")
        emptyLabel.font = .systemFont(ofSize: 13); emptyLabel.alignment = .center
        footerLabel.font = .systemFont(ofSize: 11); footerLabel.alignment = .center
        footerLabel.lineBreakMode = .byTruncatingTail
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay; scroll.documentView = document
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)
        closeButton.symbolConfiguration = .init(pointSize: 17, weight: .regular)
        closeButton.contentTintColor = .tertiaryLabelColor
        closeButton.target = self; closeButton.action = #selector(toggleDetails)
        closeButton.toolTip = "收起想法"
        closeButton.setAccessibilityLabel("關閉檔案清單")
        cat.onClick = { [weak self] in self?.toggleDetails() }
        cat.onDragRequested = { [weak self] event in
            guard let self else { return }
            self.beginDrag(for: self.viewModel.allItems.map(\.url), event: event)
        }
        dragAllHandle.onDragRequested = cat.onDragRequested
        tail.onClick = cat.onClick
        let move: (NSPoint) -> Void = { [weak self] delta in
            self?.hideTask?.cancel(); self?.onMove?(delta)
        }
        let end: () -> Void = { [weak self] in
            self?.onMoveEnded?()
            if self?.isExpanded == false { self?.scheduleTuckAway(after: 0.6) }
        }
        tail.onMove = move; tail.onMoveEnded = end
        cat.onMove = move; cat.onMoveEnded = end
        moveHandle.onMove = move; moveHandle.onMoveEnded = end
        cat.contextMenu = { [weak self] in self?.contextMenu?() }
        tail.contextMenu = cat.contextMenu
        cat.layer?.opacity = 0
        cat.interactionEnabled = false
        cat.setAccessibilityHidden(true)
        [moveHandle, titleLabel, closeButton, clearButton, emptyLabel, scroll, footerLabel, dragAllHandle].forEach { cardContent.addSubview($0) }
        [card, thoughtTrail, cat, tail].forEach { addSubview($0) }
        registerForDraggedTypes([.fileURL]); setAccessibilityLabel("UTUVO Orbit file shelf cat")
        apply(strings: strings)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }
    func setHovered(_ value: Bool) {
        if value { rowsByURL.values.forEach { $0.refreshStatus() } }
        else { scheduleTuckAway(after: 0.45) }
    }
    @objc func toggleDetails() { setDetailsVisible(!isExpanded) }
    func setDetailsVisible(_ visible: Bool) {
        guard visible != isExpanded else { return }
        isExpanded = visible
        if visible { revealCat() } else { scheduleTuckAway(after: 0.45) }
        onSizeChanged?(); updateFeedback(); needsLayout = true
    }

    func revealCat(animated: Bool = true) {
        hideTask?.cancel()
        setCatRevealed(true, animated: animated)
    }
    func tuckAwayIfIdle(animated: Bool = true) {
        guard !incoming, !outgoing, !isExpanded, !isMoving else { return }
        setCatRevealed(false, animated: animated)
    }
    private func scheduleTuckAway(after delay: Double) {
        hideTask?.cancel()
        guard isRevealed else { return }
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.tuckAwayIfIdle()
        }
    }
    private func setCatRevealed(_ revealed: Bool, animated: Bool) {
        guard revealed != isRevealed else { return }
        isRevealed = revealed
        cat.interactionEnabled = revealed
        cat.setAccessibilityHidden(!revealed)
        tail.isPresented = !revealed
        tail.setAccessibilityHidden(revealed)
        guard let catLayer = cat.layer, let tailLayer = tail.layer else { return }
        let live = catLayer.presentation()
        let oldOpacity = live?.opacity ?? catLayer.opacity
        let offscreen: CGFloat = (petOnLeft ? -1 : 1) * ShelfLayout.collapsedWidth
        let before = revealed && oldOpacity < 0.001
            ? CATransform3DMakeTranslation(offscreen, 0, 0)
            : live?.transform ?? catLayer.transform
        let target = CATransform3DMakeTranslation(revealed ? 0 : offscreen, 0, 0)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        catLayer.transform = target
        catLayer.opacity = revealed ? 1 : 0
        tailLayer.opacity = revealed ? 0 : 1
        CATransaction.commit()
        if animated, !cat.reduceMotion {
            let slide = CABasicAnimation(keyPath: "transform")
            slide.fromValue = NSValue(caTransform3D: before); slide.toValue = NSValue(caTransform3D: target)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = oldOpacity; fade.toValue = revealed ? 1 : 0
            let group = CAAnimationGroup()
            group.animations = [slide, fade]; group.duration = revealed ? 0.24 : 0.20
            group.timingFunction = CAMediaTimingFunction(name: revealed ? .easeOut : .easeIn)
            catLayer.add(group, forKey: "peek")
            let tailFade = CABasicAnimation(keyPath: "opacity")
            tailFade.fromValue = revealed ? 1 : 0; tailFade.toValue = revealed ? 0 : 1; tailFade.duration = 0.18
            tailLayer.add(tailFade, forKey: "peek")
        } else { catLayer.removeAnimation(forKey: "peek"); tailLayer.removeAnimation(forKey: "peek") }
        updateFeedback(); needsLayout = true
    }
    override func layout() {
        super.layout()
        let petX = petOffsetX ?? (petOnLeft ? 0 : bounds.width - ShelfLayout.collapsedWidth)
        let petY = bubbleAbove ? bounds.height - ShelfLayout.collapsedHeight : 0
        cat.frame = NSRect(x: petX + 4, y: petY, width: 128, height: 140)
        tail.frame = NSRect(x: petX + (petOnLeft ? -3 : 83), y: petY + 36, width: 56, height: 84)
        card.isHidden = !isExpanded
        thoughtTrail.isHidden = !isExpanded
        let cardHeight = max(1, bounds.height - ShelfLayout.collapsedHeight - ShelfLayout.thoughtGap)
        card.frame = NSRect(x: 0, y: bubbleAbove ? 0 : ShelfLayout.collapsedHeight + ShelfLayout.thoughtGap, width: bounds.width, height: cardHeight)
        thoughtTrail.frame = NSRect(x: 0, y: bubbleAbove ? cardHeight : ShelfLayout.collapsedHeight, width: bounds.width, height: ShelfLayout.thoughtGap)
        thoughtTrail.bubbleAbove = bubbleAbove
        thoughtTrail.catCenterX = cat.frame.midX
        thoughtTrail.isOnLeft = petOnLeft
        cardContent.frame = card.bounds
        moveHandle.frame = NSRect(x: 26, y: 28, width: 26, height: 26)
        titleLabel.frame = NSRect(x: 58, y: 29, width: bounds.width - 119, height: 23)
        closeButton.frame = NSRect(x: bounds.width - 57, y: 28, width: 26, height: 26)
        clearButton.frame = NSRect(x: 28, y: cardHeight - 81, width: 50, height: 30)
        scroll.frame = NSRect(x: 20, y: 70, width: bounds.width - 40, height: max(1, cardHeight - 156))
        dragAllHandle.frame = NSRect(x: 87, y: cardHeight - 81, width: bounds.width - 117, height: 32)
        footerLabel.frame = NSRect(x: 27, y: cardHeight - 40, width: bounds.width - 54, height: 18)
        emptyLabel.frame = NSRect(x: 28, y: 73, width: bounds.width - 56, height: 52)
        [scroll, dragAllHandle, clearButton].forEach { $0.isHidden = viewModel.isEmpty }
        emptyLabel.isHidden = !viewModel.isEmpty
        let width = max(1, scroll.contentSize.width)
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(scroll.contentSize.height, CGFloat(rowsByURL.count) * ShelfLayout.itemHeight))
        for (index, item) in viewModel.allItems.enumerated() {
            rowsByURL[item.url]?.frame = NSRect(x: 0, y: CGFloat(index) * ShelfLayout.itemHeight, width: width, height: ShelfLayout.itemHeight)
        }
    }
    func reload() {
        document.subviews.forEach { $0.removeFromSuperview() }; rowsByURL.removeAll()
        for item in viewModel.allItems {
            let row = ShelfItemRow(item: item, strings: strings)
            row.onDragRequested = { [weak self] url, event in self?.beginDrag(for: [url], event: event) }
            row.onRemoveRequested = { [weak self] url in
                self?.viewModel.remove(url); self?.referenceError = nil
                if self?.viewModel.isEmpty == true { self?.isExpanded = false }
                self?.reload()
            }
            document.addSubview(row); rowsByURL[item.url] = row
        }
        let count = viewModel.allItems.count
        clearButton.isEnabled = count > 0
        dragAllHandle.title = strings.dragAll
        dragAllHandle.setAccessibilityLabel(strings.dragAll + " · " + strings.count(count))
        onSizeChanged?(); updateFeedback(); needsLayout = true
        if !isExpanded { scheduleTuckAway(after: 1.2) }
    }
    private func updateFeedback() {
        let count = viewModel.allItems.count
        titleLabel.stringValue = strings.title(count)
        titleLabel.toolTip = strings.title(count)
        emptyLabel.stringValue = strings.empty
        let names = viewModel.allItems.prefix(8).map(\.displayName).joined(separator: "\n")
        let more = count > 8 ? strings.text("\n另有 \(count - 8) 份…", "\nAnd \(count - 8) more…") : ""
        let hint = count == 0 ? strings.text("把檔案拖過來，點一下查看清單。", "Drop files here; click to see the list.")
            : names + more + "\n\n" + strings.text("點一下查看清單，拖曳貓咪整批帶走。", "Click to see files; drag the cat to take them all.")
        tail.toolTip = hint + "\n" + strings.movementHelp
        cat.toolTip = hint + "\n" + strings.movementHelp
        tail.setAccessibilityValue(strings.count(count))
        footerLabel.stringValue = errorMessage ?? strings.footer
        footerLabel.toolTip = footerLabel.stringValue
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let secondary = NSColor.labelColor.withAlphaComponent(0.75)
            emptyLabel.textColor = secondary
            footerLabel.textColor = errorMessage == nil ? secondary : .systemRed
        }
        cat.update(count: count, mood: incoming ? .hungry : outgoing ? .giving : .idle)
        // Keep the native drop destination stable while the cat slides into view.
        layer?.backgroundColor = incoming ? NSColor.white.withAlphaComponent(0.02).cgColor : NSColor.clear.cgColor
        window?.invalidateCursorRects(for: cat)
    }
    func apply(strings: DropStrings) {
        self.strings = strings
        cat.strings = strings
        titleLabel.lineBreakMode = .byTruncatingTail
        clearButton.title = strings.clear
        clearButton.toolTip = strings.clearHelp
        clearButton.setAccessibilityLabel(strings.clearHelp)
        closeButton.toolTip = strings.close
        closeButton.setAccessibilityLabel(strings.close)
        moveHandle.toolTip = strings.movementHelp
        moveHandle.setAccessibilityLabel(strings.move)
        tail.setAccessibilityLabel(strings.tailLabel)
        cat.setAccessibilityLabel(strings.catLabel)
        dragAllHandle.toolTip = strings.dragAllHelp
        setAccessibilityLabel(strings.catLabel)
        reload()
    }
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateFeedback() }
    @objc func clearShelf() { viewModel.clear(); referenceError = nil; isExpanded = false; reload(); scheduleTuckAway(after: 0.6) }
    func operation(for pasteboard: NSPasteboard, mask: NSDragOperation) -> NSDragOperation {
        guard mask.contains(.copy), !PasteboardFileURLReader().readFileURLs(from: pasteboard).isEmpty else { return [] }
        return .copy
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !outgoing, (sender.draggingSource as? ShelfContentView) !== self else { return [] }
        guard acceptsIncomingDrops else { onGatedDrop?(); return [] }
        let op = operation(for: sender.draggingPasteboard, mask: sender.draggingSourceOperationMask)
        incoming = op == .copy
        if incoming { revealCat() }
        updateFeedback(); return op
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !outgoing, (sender.draggingSource as? ShelfContentView) !== self else { return [] }
        guard acceptsIncomingDrops else { return [] }
        return operation(for: sender.draggingPasteboard, mask: sender.draggingSourceOperationMask)
    }
    override func wantsPeriodicDraggingUpdates() -> Bool { false }
    override func draggingExited(_ sender: NSDraggingInfo?) { finishIncoming() }
    override func draggingEnded(_ sender: NSDraggingInfo?) { finishIncoming() }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { finishIncoming() }
    private func finishIncoming() {
        incoming = false
        if cat.mood != .chewing { updateFeedback(); scheduleTuckAway(after: 0.45) }
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard !outgoing, (sender.draggingSource as? ShelfContentView) !== self else { return false }
        guard acceptsIncomingDrops else { return false }
        return operation(for: sender.draggingPasteboard, mask: sender.draggingSourceOperationMask) == .copy
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard prepareForDragOperation(sender) else { finishIncoming(); return false }
        return acceptFiles(from: sender.draggingPasteboard)
    }
    @discardableResult func acceptFiles(from pasteboard: NSPasteboard) -> Bool {
        let urls = PasteboardFileURLReader().readFileURLs(from: pasteboard)
        guard !urls.isEmpty else { return false }
        revealCat()
        let before = Set(viewModel.allItems.map(\.url))
        viewModel.insert(urls); incoming = false
        referenceError = viewModel.model.refreshStaleStatus().values.contains(where: { $0 != .ok }) ? .invalidDrop : nil
        reload()
        setDetailsVisible(true)
        if let added = viewModel.allItems.first(where: { !before.contains($0.url) }) {
            cat.chew(); cat.swallow(NSWorkspace.shared.icon(forFile: added.url.path))
        }
        return true
    }
    func draggingItems(for urls: [URL]) -> [NSDraggingItem] {
        let wanted = viewModel.allItems.filter { urls.contains($0.url) }
        guard !wanted.isEmpty else { return [] }
        guard wanted.allSatisfy({ ShelfModel.defaultProbe($0.url) == .ok }) else {
            referenceError = .invalidDrag
            setDetailsVisible(true); reload(); return []
        }
        referenceError = nil
        let mouth = convert(cat.mouthPoint, from: cat)
        return wanted.enumerated().map { index, item in
            let drag = NSDraggingItem(pasteboardWriter: item.url as NSURL)
            drag.setDraggingFrame(NSRect(x: mouth.x - 16 + CGFloat(index % 3) * 3, y: mouth.y - 16, width: 32, height: 32),
                                  contents: NSWorkspace.shared.icon(forFile: item.url.path))
            return drag
        }
    }
    func beginDrag(for url: URL, event: NSEvent) { beginDrag(for: [url], event: event) }
    func beginDrag(for urls: [URL], event: NSEvent) {
        guard event.type == .leftMouseDragged, window != nil, !outgoing else { return }
        guard !viewModel.isEmpty else { return }
        revealCat(animated: false)
        layoutSubtreeIfNeeded()
        let items = draggingItems(for: urls)
        guard !items.isEmpty else { return }
        outgoingURLs = viewModel.allItems.filter { urls.contains($0.url) }.map(\.url)
        outgoing = true; updateFeedback()
        if let startSession { startSession(items, event) }
        else {
            let session = beginDraggingSession(with: items, event: event, source: self)
            session.draggingFormation = .pile
            session.animatesToStartingPositionsOnCancelOrFail = true
        }
    }
    static let sourceOperations: NSDragOperation = .copy
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { Self.sourceOperations }
    func draggingSession(_ session: NSDraggingSession, endedAt point: NSPoint, operation: NSDragOperation) { completeDrag(operation: operation) }
    func completeDrag(operation: NSDragOperation) {
        // Only a destination's successful copy consumes shelf references. Cancel keeps them.
        if operation.contains(.copy) { outgoingURLs.forEach { viewModel.remove($0) } }
        outgoingURLs = []; outgoing = false
        if viewModel.isEmpty { isExpanded = false }
        reload()
        scheduleTuckAway(after: 1.0)
    }
}
private final class FlippedView: NSView { override var isFlipped: Bool { true } }
