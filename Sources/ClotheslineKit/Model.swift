import AppKit
import ImageIO
import OSLog
import Vision

@MainActor final class Model: ObservableObject {
    @Published var captures: [Capture] = []
    @Published var thumbnails: [UUID: NSImage] = [:]
    @Published var message = ""
    @Published var busy = Set<UUID>()
    let settings: ClotheslineSettings
    let library: CaptureLibrary
    private let watcher = ScreenshotWatcher()
    private let logger = Logger(subsystem: "app.utuvo.orbit", category: "clothesline")
    private var cleanupTimer: Timer?
    var didCapture: (() -> Void)?

    init(root: URL, settings: ClotheslineSettings) throws {
        self.settings = settings
        library = try CaptureLibrary(root: root)
        refresh()
        watcher.receive = { [weak self] in _ = self?.ingest($0) }
        watcher.failure = { [weak self] in self?.message = $0 }
        settings.changedDirectory = { [weak self] in self?.startWatching() }
    }

    func startWatching() {
        watcher.stop()
        guard let folder = settings.beginAccess() else {
            message = Self.folderPrompt
            return
        }
        if message == Self.folderPrompt { message = "" }
        watcher.start(at: folder)
    }

    static var folderPrompt: String {
        L.text("先在 UTUVO Orbit 設定裡選擇截圖資料夾。", "Choose your screenshot folder in UTUVO Orbit Settings first.")
    }

    func stop() {
        watcher.stop()
        cleanupTimer?.invalidate(); cleanupTimer = nil
        settings.endAccess()
    }

    func start() {
        startWatching(); clean()
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.clean() }
        }
    }

    func clean() {
        let errors = library.clean(days: settings.days)
        if let error = errors.first { message = error }
        refresh()
    }

    func refresh() {
        captures = library.captures
        let visible = Set(captures.prefix(12).map(\.id))
        thumbnails = thumbnails.filter { visible.contains($0.key) }
        for capture in captures.prefix(12) where thumbnails[capture.id] == nil {
            thumbnails[capture.id] = autoreleasepool {
                guard let source = CGImageSourceCreateWithURL(library.url(for: capture) as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 480,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCache: false
                  ] as CFDictionary) else { return nil }
                let thumbnail = NSImage(cgImage: image, size: .zero)
                thumbnail.cacheMode = .never
                return thumbnail
            }
        }
    }

    @discardableResult
    func ingest(_ url: URL, managedInput: Bool = false, preserveSource: Bool = false) -> Bool {
        let start = ContinuousClock.now
        do {
            let capture = try library.ingest(url)
            refresh(); didCapture?()
            if !preserveSource && (settings.noDesktop || managedInput) {
                do { try library.removeSourceFromDesktop(capture.id) }
                catch { message = L.text("已掛上，來源保留：", "Hung up; source preserved: ") + error.localizedDescription }
            }
            refresh()
            logger.info("ingested capture \(capture.id.uuidString, privacy: .public); processing duration \(String(describing: start.duration(to: .now)), privacy: .public)")
            return true
        } catch { message = error.localizedDescription; return false }
    }

    func copy(_ capture: Capture) {
        guard let image = NSImage(contentsOf: library.url(for: capture)) else { message = LibraryError.missingCapture.localizedDescription; return }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.writeObjects([image]) { message = L.text("圖片拷貝好了", "Image copied") }
    }

    func preview(_ capture: Capture) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else { message = L.text("找不到 Preview", "Preview is unavailable"); return }
        NSWorkspace.shared.open([library.url(for: capture)], withApplicationAt: app, configuration: .init()) { [weak self] _, error in
            Task { @MainActor in if let error { self?.message = error.localizedDescription } }
        }
    }

    func discard(_ capture: Capture) {
        do { try library.discard(capture.id); refresh(); message = L.text("已放進垃圾桶，可復原", "Moved to Trash; you can restore it") }
        catch { message = error.localizedDescription }
    }

    func endDrag(_ capture: Capture, operation: NSDragOperation) {
        do {
            if operation.contains(.delete) { try library.discard(capture.id) }
            else if operation.contains(.move) { try library.reconcileExternalMove(capture.id) }
            refresh()
        } catch { message = error.localizedDescription }
    }

    func archive(_ capture: Capture) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = L.text("收好", "Archive")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let name = L.text("晾衣繩", "Clothesline") + "-" + String(capture.id.uuidString.prefix(8)) + "." + library.url(for: capture).pathExtension
        do {
            // copyItem will refuse an existing destination, never overwrite a user's file.
            try FileManager.default.copyItem(at: library.url(for: capture), to: folder.appendingPathComponent(name))
            try library.discard(capture.id)
            refresh(); message = L.text("收好了", "Archived")
        } catch { message = error.localizedDescription }
    }

    func recognize(_ capture: Capture) {
        guard !busy.contains(capture.id) else { return }
        busy.insert(capture.id)
        let url = library.url(for: capture)
        Task { [weak self] in
            do {
                let text = try await OCR.recognize(url)
                guard let self else { return }
                if text.isEmpty { self.message = L.text("這張沒有辨識到文字", "No text was found") }
                else {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    self.message = L.text("文字拷貝好了", "Text copied")
                }
            } catch { self?.message = error.localizedDescription }
            self?.busy.remove(capture.id)
        }
    }
}

public enum OCR {
    private static let queue = DispatchQueue(label: "app.utuvo.orbit.clothesline.ocr", qos: .userInitiated)
    /// Runs Vision in-process on a background queue. The request, handler and
    /// their caches live inside one autorelease pool and are released as soon
    /// as the single image is done; nothing persists between calls.
    public static func recognize(_ url: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let result: Result<String, any Error> = autoreleasepool { Result {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    let supported = try request.supportedRecognitionLanguages()
                    request.recognitionLanguages = ["zh-Hant", "en-US"].filter { supported.contains($0) }
                    request.usesLanguageCorrection = true
                    try VNImageRequestHandler(url: url).perform([request])
                    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                } }
                continuation.resume(with: result)
            }
        }
    }
}
