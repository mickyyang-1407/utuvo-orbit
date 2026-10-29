import AppKit
import Darwin

/// Clothesline preferences. The screenshot folder is kept as a
/// security-scoped bookmark so the App Store (sandboxed) build can still read
/// it after a relaunch; Orbit never changes the system screenshot location.
@MainActor public final class ClotheslineSettings: ObservableObject {
    private let defaults: UserDefaults
    let isSandboxed: Bool

    private enum Key {
        static let bookmark = "clothesline.folderBookmark"
        static let noDesktop = "clothesline.noDesktop"
        static let days = "clothesline.days"
        static let frameWidth = "clothesline.frameWidth"
        static let delay = "clothesline.delay"
    }

    /// Path shown to the user; `nil` until a folder is known.
    @Published public private(set) var folderPath: String?
    @Published public var noDesktop: Bool { didSet { defaults.set(noDesktop, forKey: Key.noDesktop) } }
    @Published public var days: Int { didSet { defaults.set(days, forKey: Key.days) } }
    @Published public var frameWidth: Double { didSet { defaults.set(frameWidth, forKey: Key.frameWidth) } }
    @Published public var delay: Double { didSet { defaults.set(delay, forKey: Key.delay) } }
    var changedDirectory: (() -> Void)?

    private var bookmark: Data? { didSet { defaults.set(bookmark, forKey: Key.bookmark) } }
    private var scopedURL: URL?

    public static let retentionChoices = [0, 1, 3, 7, 14, 30]

    public init(defaults: UserDefaults,
                isSandboxed: Bool = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil) {
        self.defaults = defaults
        self.isSandboxed = isSandboxed
        bookmark = defaults.data(forKey: Key.bookmark)
        noDesktop = defaults.bool(forKey: Key.noDesktop)
        days = defaults.object(forKey: Key.days) == nil ? 7 : max(0, defaults.integer(forKey: Key.days))
        let width = defaults.double(forKey: Key.frameWidth)
        frameWidth = width == 0 ? 176 : min(240, max(120, width))
        delay = defaults.object(forKey: Key.delay) == nil ? 0.25 : min(1, max(0.05, defaults.double(forKey: Key.delay)))
        folderPath = nil
        folderPath = resolvedFolderPathWithoutAccess()
    }

    /// The real home folder, even inside the sandbox container.
    static var realHome: URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Unsandboxed builds keep the original LineDry behaviour: without a
    /// chosen folder they watch the system screenshot location (or Desktop).
    /// The sandbox cannot read either, so the App Store build always asks.
    private var fallbackFolder: URL? {
        guard !isSandboxed else { return nil }
        if let system = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            return URL(fileURLWithPath: (system as NSString).expandingTildeInPath, isDirectory: true)
        }
        return Self.realHome.appendingPathComponent("Desktop", isDirectory: true)
    }

    private func resolvedFolderPathWithoutAccess() -> String? {
        if let bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                                  relativeTo: nil, bookmarkDataIsStale: &stale) { return url.path }
        }
        return fallbackFolder?.path
    }

    /// Opens security-scoped access to the watched folder; balanced by `endAccess()`.
    func beginAccess() -> URL? {
        endAccess()
        guard let bookmark else { return fallbackFolder }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        guard url.startAccessingSecurityScopedResource() else { return nil }
        scopedURL = url
        if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            self.bookmark = fresh
        }
        folderPath = url.path
        return url
    }

    func endAccess() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }

    public var needsFolder: Bool { folderPath == nil }

    public func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = L.text("選這個資料夾", "Choose")
        panel.message = L.text("選擇你的截圖存放位置（通常是「桌面」）。UTUVO Orbit 不會改動系統設定。",
                               "Choose where your screenshots are saved (usually Desktop). UTUVO Orbit won't change the system setting.")
        panel.directoryURL = fallbackFolder ?? Self.realHome.appendingPathComponent("Desktop", isDirectory: true)
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        else { return }
        endAccess()
        bookmark = data
        folderPath = url.path
        changedDirectory?()
    }
}
