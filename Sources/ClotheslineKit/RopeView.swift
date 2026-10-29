import AppKit
import Combine
import QuartzCore

/// The always-visible surface uses AppKit; SwiftUI is loaded for Settings on demand.
@MainActor final class RopeView: NSView {
    private let model: Model
    private let settings: ClotheslineSettings
    private let preview: (Capture) -> Void
    private let scroll = NSScrollView()
    private let document = NSView()
    private let message = NSTextField(labelWithString: "")
    private var subscriptions = Set<AnyCancellable>()
    private var cards: [UUID: CaptureCard] = [:]

    init(model: Model, settings: ClotheslineSettings, preview: @escaping (Capture) -> Void) {
        self.model = model; self.settings = settings; self.preview = preview
        super.init(frame: .zero)
        scroll.drawsBackground = false; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true; scroll.documentView = document
        addSubview(scroll); addSubview(message)
        message.font = .systemFont(ofSize: 11); message.textColor = .secondaryLabelColor
        message.alignment = .center; message.maximumNumberOfLines = 2
        model.objectWillChange.sink { [weak self] _ in
            // Published sends before mutation. Coalesce rendering on the next event-loop turn.
            DispatchQueue.main.async { [weak self] in self?.refresh() }
        }.store(in: &subscriptions)
        settings.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.refresh() }
        }.store(in: &subscriptions)
        refresh()
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        scroll.frame = NSRect(x: 16, y: 16, width: max(0, bounds.width - 32), height: 226)
        message.frame = NSRect(x: 26, y: 246, width: max(0, bounds.width - 52), height: 32)
        arrangeCards()
    }

    private func refresh() {
        let visible = Array(model.captures.prefix(12))
        let ids = Set(visible.map(\.id))
        for id in Array(cards.keys) where !ids.contains(id) {
            cards.removeValue(forKey: id)?.removeFromSuperview()
        }
        for (index, capture) in visible.enumerated() {
            if cards[capture.id] == nil {
                let card = CaptureCard(capture: capture, model: model, preview: preview)
                cards[capture.id] = card; document.addSubview(card)
                card.sway(index: index)
            }
            cards[capture.id]?.update(width: settings.frameWidth)
        }
        message.stringValue = model.message.isEmpty
            ? (visible.isEmpty ? L.text("下一張截圖，晾在這裡。  ⌘⇧3 · ⌘⇧4 · ⌘⇧5", "Your next screenshot has a place to hang.  ⌘⇧3 · ⌘⇧4 · ⌘⇧5") : L.text("點一下拷貝 · 雙擊用「預覽程式」打開 · 長按快速查看", "Click to copy · Double-click for Preview · Hold for Quick Look"))
            : model.message
        if model.captures.count > 12 {
            message.stringValue += L.text(" · 另有 \(model.captures.count - 12) 張，可從選單打開素材庫", " · \(model.captures.count - 12) more in the library")
        }
        needsLayout = true; needsDisplay = true
    }

    private func arrangeCards() {
        let width = CGFloat(settings.frameWidth) + 20
        let captures = Array(model.captures.prefix(12))
        document.frame = NSRect(x: 0, y: 0, width: max(scroll.contentSize.width, CGFloat(captures.count) * (width + 18) + 36), height: 220)
        for (index, capture) in captures.enumerated() {
            cards[capture.id]?.frame = NSRect(x: 18 + CGFloat(index) * (width + 18), y: 5, width: width, height: 210)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rope = NSBezierPath(); rope.move(to: NSPoint(x: 0, y: 18))
        rope.curve(to: NSPoint(x: bounds.width, y: 18), controlPoint1: NSPoint(x: bounds.width * 0.33, y: 42), controlPoint2: NSPoint(x: bounds.width * 0.66, y: 42))
        NSColor(calibratedRed: 0.57, green: 0.39, blue: 0.22, alpha: 0.9).setStroke()
        rope.lineWidth = 3; rope.stroke()
        NSColor.white.withAlphaComponent(0.4).setStroke()
        rope.lineWidth = 0.7; rope.setLineDash([2, 4], count: 2, phase: 0); rope.stroke()
    }
}

@MainActor private final class CaptureCard: NSView {
    private let capture: Capture
    private weak var model: Model?
    private let glass = NSVisualEffectView()
    private let image = NSImageView()
    private let gesture = CaptureGestureView()
    private let time = NSTextField(labelWithString: "")
    private let ocr = NSButton()
    private let discard = NSButton()
    private var width: CGFloat = 176

    init(capture: Capture, model: Model, preview: @escaping (Capture) -> Void) {
        self.capture = capture; self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        glass.material = .hudWindow; glass.blendingMode = .behindWindow; glass.state = .active
        glass.wantsLayer = true; glass.layer?.cornerRadius = 16
        glass.layer?.borderColor = NSColor.white.withAlphaComponent(0.3).cgColor
        glass.layer?.borderWidth = 1
        glass.layer?.masksToBounds = true
        addSubview(glass)
        image.imageScaling = .scaleProportionallyUpOrDown
        glass.addSubview(image); glass.addSubview(gesture)
        gesture.capture = capture; gesture.model = model; gesture.markup = preview
        gesture.setAccessibilityLabel(L.text("截圖：點擊拷貝，雙擊開啟，長按快速查看，拖曳傳送", "Screenshot: click to copy, double-click to open, hold for Quick Look, drag to send"))
        time.stringValue = capture.capturedAt.formatted(date: .omitted, time: .shortened)
        time.font = .monospacedSystemFont(ofSize: 10, weight: .regular); time.textColor = .secondaryLabelColor
        glass.addSubview(time)
        for button in [ocr, discard] {
            button.isBordered = false; button.bezelStyle = .inline; button.target = self
            glass.addSubview(button)
        }
        ocr.action = #selector(recognize); discard.action = #selector(trash)
        ocr.toolTip = L.text("拷貝圖中文字", "Copy text in image")
        discard.toolTip = L.text("移入垃圾桶", "Move to Trash")
        discard.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: discard.toolTip)
        let menu = NSMenu()
        for (title, action) in [(L.text("拷貝圖片", "Copy image"), #selector(copyImage)), (L.text("拷貝文字", "Copy text"), #selector(recognize)), (L.text("收進資料夾…", "Archive to folder…"), #selector(archive)), (L.text("移入垃圾桶", "Move to Trash"), #selector(trash))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: ""); item.target = self
        }
        gesture.menu = menu
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    func update(width: Double) {
        self.width = CGFloat(width)
        image.image = model?.thumbnails[capture.id]
        let busy = model?.busy.contains(capture.id) == true
        ocr.isEnabled = !busy
        ocr.image = NSImage(systemSymbolName: busy ? "hourglass" : "text.viewfinder", accessibilityDescription: ocr.toolTip)
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let height = width * 0.58
        glass.frame = NSRect(x: 0, y: 25, width: bounds.width, height: height + 48)
        // NSVisualEffectView uses the ordinary bottom-left coordinate system.
        image.frame = NSRect(x: 10, y: 34, width: width, height: height)
        gesture.frame = image.frame
        time.frame = NSRect(x: 10, y: 10, width: max(20, width - 64), height: 16)
        ocr.frame = NSRect(x: bounds.width - 60, y: 7, width: 24, height: 24)
        discard.frame = NSRect(x: bounds.width - 32, y: 7, width: 24, height: 24)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let peg = NSRect(x: bounds.midX - 8, y: 0, width: 16, height: 33)
        let path = NSBezierPath(roundedRect: peg, xRadius: 4, yRadius: 4)
        NSGradient(starting: NSColor(calibratedRed: 0.90, green: 0.72, blue: 0.46, alpha: 1), ending: NSColor(calibratedRed: 0.68, green: 0.45, blue: 0.24, alpha: 1))?.draw(in: path, angle: 0)
        NSColor.brown.withAlphaComponent(0.35).setFill()
        NSRect(x: bounds.midX, y: 4, width: 1, height: 25).fill()
        NSColor.gray.setFill(); NSRect(x: bounds.midX - 7, y: 15, width: 14, height: 3).fill()
    }
    func sway(index: Int) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let animation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        let sign = index.isMultiple(of: 2) ? 1.0 : -1.0
        animation.values = [0.035 * sign, -0.02 * sign, 0.01 * sign, 0]
        animation.duration = 0.7; layer?.add(animation, forKey: "settle")
    }
    @objc private func copyImage() { model?.copy(capture) }
    @objc private func recognize() { model?.recognize(capture) }
    @objc private func archive() { model?.archive(capture) }
    @objc private func trash() { model?.discard(capture) }
}
