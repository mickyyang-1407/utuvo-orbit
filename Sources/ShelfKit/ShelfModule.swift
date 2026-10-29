import AppKit

// MARK: - UTUVO Orbit module facade
//
// The cat-tail file shelf that used to ship as the standalone app UTUVO Drop.
// Orbit owns the single menu bar icon and the language setting; this type only
// creates the floating shelf while the module is switched on and tears it down
// completely when it is switched off (no window, no observers, no file
// references left behind).

@MainActor public final class ShelfModule {
    private let defaults: UserDefaults?
    private var controller: ShelfWindowController?
    private var languageCode: String

    /// Returns false while Orbit is locked; the shelf then refuses new files.
    public var dropGate: (() -> Bool)?
    /// Called when a drag is refused by `dropGate`. Orbit sets no gate, so
    /// every drop is accepted.
    public var onGatedDrop: (() -> Void)?
    /// Right-click menu on the cat; Orbit supplies its own module menu.
    public var contextMenu: (() -> NSMenu?)?
    public var onOpenQuickTools: (([URL]) -> Void)?

    /// `defaults == nil` keeps every preference in memory (tests, previews).
    /// `language` is Orbit's `AppLanguage` raw value: "system", "en" or "zh-Hant".
    public init(defaults: UserDefaults?, language: String) {
        self.defaults = defaults
        languageCode = language
    }

    public var isRunning: Bool { controller != nil }

    public func start() {
        guard controller == nil else { return }
        let settings = DropSettings(defaults: defaults)
        settings.language = DropLanguage(rawValue: languageCode) ?? .system
        let controller = ShelfWindowController(settings: settings)
        controller.content.dropGate = { [weak self] in self?.dropGate?() ?? true }
        controller.content.onGatedDrop = { [weak self] in self?.onGatedDrop?() }
        controller.content.contextMenu = { [weak self, weak controller] in
            guard let self else { return nil }
            let menu = self.contextMenu?() ?? NSMenu()
            let title = DropStrings(language: DropLanguage(rawValue: self.languageCode) ?? .system).text("檔案快速處理…", "Quick File Tools…")
            let item = NSMenuItem(title: title, action: #selector(ShelfQuickToolsTarget.open), keyEquivalent: "")
            let target = ShelfQuickToolsTarget { [weak self, weak controller] in
                self?.onOpenQuickTools?(controller?.viewModel.allItems.map(\.url) ?? [])
            }
            self.quickToolsTarget = target; item.target = target
            menu.addItem(item)
            return menu
        }
        self.controller = controller
        controller.showShelf()
    }

    /// Drops every in-memory file reference (originals are never touched).
    public func stop() {
        guard let controller else { return }
        controller.viewModel.clear()
        controller.window?.orderOut(nil)
        controller.close()
        self.controller = nil
    }

    public func setLanguage(_ language: String) {
        languageCode = language
        controller?.changeLanguage(DropLanguage(rawValue: language) ?? .system)
    }

    public var itemCount: Int { controller?.viewModel.allItems.count ?? 0 }
    public var fileURLs: [URL] { controller?.viewModel.allItems.map(\.url) ?? [] }
    private var quickToolsTarget: ShelfQuickToolsTarget?
    public func showFiles() { controller?.showShelf(); controller?.content.setDetailsVisible(true) }
    public func clear() { controller?.content.clearShelf() }
    public func moveToOtherEdge() { controller?.cycleEdge() }
    public func resetPosition() { controller?.resetPosition() }

    #if DEBUG
    /// Local QA only (compiled out of Release): hands files to the shelf
    /// through the same pasteboard path a drop uses, so App Store captures
    /// never need a synthetic mouse drag.
    public func qaAcceptFiles(_ urls: [URL]) {
        guard let controller, !urls.isEmpty else { return }
        let board = NSPasteboard(name: NSPasteboard.Name("app.utuvo.orbit.qa.shelf"))
        board.clearContents()
        board.writeObjects(urls as [NSURL])
        controller.content.acceptFiles(from: board)
        board.releaseGlobally()
    }
    #endif
}

@MainActor
private final class ShelfQuickToolsTarget: NSObject {
    let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
    @objc func open() { action() }
}
