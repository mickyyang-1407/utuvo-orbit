import AppKit
import Carbon

// MARK: - UTUVO Orbit module facade
//
// The screenshot clothesline (previously the preview app 晾好了 LineDry).
// Orbit owns the menu bar icon and the language. While the module is off
// nothing exists: no panel, no mouse monitor, no hotkey, no folder watch.
// It never changes the system screenshot location or system shortcuts.

@MainActor final class RopePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor public final class ClotheslineModule {
    public let settings: ClotheslineSettings
    private let libraryRoot: URL
    private var model: Model?
    private var panel: RopePanel?
    private let preview = PreviewController()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var pendingReveal: DispatchWorkItem?
    private var revealed = false
    private var pinned = false
    private var hotkey: EventHotKeyRef?
    private var hotkeyHandler: EventHandlerRef?

    /// Orbit returns true while its own popover is open, so reaching for the
    /// menu bar icon does not drop the line over the panel.
    public var suppressReveal: (() -> Bool)?
    /// Non-empty when ⌃⌥T could not be registered.
    public private(set) var hotkeyProblem: String?

    /// `libraryRoot` holds the managed copies and the manifest (inside the
    /// app container for the App Store build).
    public init(settings: ClotheslineSettings, libraryRoot: URL, language: String) {
        self.settings = settings
        self.libraryRoot = libraryRoot
        L.languageCode = language
    }

    public var isRunning: Bool { model != nil }

    public func setLanguage(_ language: String) {
        L.languageCode = language
        (panel?.contentView as? RopeView)?.needsDisplay = true
        model?.objectWillChange.send()
    }

    public func start() throws {
        guard model == nil else { return }
        let model = try Model(root: libraryRoot, settings: settings)
        self.model = model
        model.didCapture = { [weak self] in
            self?.setRevealed(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.hover(NSEvent.mouseLocation) }
        }
        let panel = RopePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .statusBar; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.contentView = RopeView(model: model, settings: settings,
                                     preview: { [weak self, weak model] capture in
                                         guard let model else { return }
                                         self?.preview.show(model.library.url(for: capture))
                                     })
        self.panel = panel
        registerShortcut()
        model.start()
        revealed = false
        reposition(animated: false)
        panel.orderFrontRegardless()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated { self?.hover(NSEvent.mouseLocation) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.hover(NSEvent.mouseLocation); return event
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.reposition(animated: false) } }
    }

    public func stop() {
        pendingReveal?.cancel(); pendingReveal = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }; globalMonitor = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }; localMonitor = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }; screenObserver = nil
        if let hotkey { UnregisterEventHotKey(hotkey) }; hotkey = nil
        if let hotkeyHandler { RemoveEventHandler(hotkeyHandler) }; hotkeyHandler = nil
        model?.stop()
        settings.changedDirectory = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        model = nil
        revealed = false; pinned = false
    }

    public func toggle() {
        guard model != nil else { return }
        pinned = !revealed
        setRevealed(!revealed)
    }

    public func cleanNow() { model?.clean() }

    /// Explicit handoff from Orbit's editor. Never applies the watched-folder
    /// policy that may trash a desktop original.
    @discardableResult public func addCopy(_ url: URL) -> Bool {
        model?.ingest(url, preserveSource: true) ?? false
    }

    public func openLibrary() {
        NSWorkspace.shared.open(libraryRoot)
    }

    private func hover(_ point: NSPoint) {
        guard let screen = NSScreen.screens.first else { return }
        let band = revealed ? 285 : max(30, screen.safeAreaInsets.top)
        var shouldReveal = pinned || (point.x >= screen.frame.minX && point.x <= screen.frame.maxX && point.y >= screen.frame.maxY - band)
        if !pinned, !revealed, suppressReveal?() == true { shouldReveal = false }
        guard shouldReveal != revealed else { pendingReveal?.cancel(); return }
        pendingReveal?.cancel()
        let job = DispatchWorkItem { [weak self] in self?.setRevealed(shouldReveal) }
        pendingReveal = job
        DispatchQueue.main.asyncAfter(deadline: .now() + settings.delay, execute: job)
    }

    private func setRevealed(_ value: Bool) {
        pendingReveal?.cancel(); revealed = value
        if !value { pinned = false }
        reposition(animated: true)
    }

    private func reposition(animated: Bool) {
        guard let panel, let screen = NSScreen.screens.first else { return }
        let height = 285.0
        let width = min(screen.frame.width, 1450)
        let y = revealed ? screen.visibleFrame.maxY - height : screen.frame.maxY + 1
        let frame = NSRect(x: screen.frame.midX - width / 2, y: y, width: width, height: height)
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !animated || reduce { panel.setFrame(frame, display: true); return }
        NSAnimationContext.runAnimationGroup { context in context.duration = 0.2; panel.animator().setFrame(frame, display: true) }
    }

    private func registerShortcut() {
        hotkeyProblem = nil
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID(signature: 0, id: 0)
            guard GetEventParameter(event, UInt32(kEventParamDirectObject), UInt32(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == 0x4F52424C, id.id == 1 else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { Unmanaged<ClotheslineModule>.fromOpaque(userData).takeUnretainedValue().toggle() }
            return noErr
        }, 1, &type, pointer, &hotkeyHandler)
        let id = EventHotKeyID(signature: 0x4F52424C, id: 1) // 'ORBL'
        if result != noErr || RegisterEventHotKey(UInt32(kVK_ANSI_T), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotkey) != noErr {
            hotkeyProblem = L.text("⌃⌥T 無法註冊，可能被其他 App 使用。請用選單顯示晾衣繩。", "⌃⌥T is unavailable or already in use. Use the menu to show the line.")
            model?.message = hotkeyProblem ?? ""
        }
    }
}
