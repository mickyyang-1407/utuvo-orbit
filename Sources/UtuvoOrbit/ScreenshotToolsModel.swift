import AppKit
import ClotheslineKit
import OrbitCore
import ShelfKit
import UniformTypeIdentifiers

@MainActor
final class ScreenshotToolsModel: ObservableObject {
    @Published private(set) var recent: [Capture] = []
    @Published private(set) var selectedID: UUID?
    @Published private(set) var image: CGImage?
    @Published private(set) var edits: [ScreenshotEdit] = []
    @Published private(set) var busy = false
    @Published private(set) var waitingForSelection = false
    @Published private(set) var message: String?
    @Published private(set) var failed = false
    @Published private(set) var draftNeedsRecovery = false
    @Published var tool: ScreenshotTool = .crop
    var language: AppLanguage = .system
    var onSendToFiles: ((URL) -> Void)?
    var onSendToQR: ((CGImage) -> Void)?
    var onSendToClothesline: ((URL) -> Bool)?
    var canSendToClothesline: () -> Bool = { false }
    private var original: CGImage?
    private var library: CaptureLibrary?
    private let capture: any ScreenshotCapturing
    private let copyImage: (CGImage) -> Void
    private let copyText: (String) -> Void
    private let scratch: URL
    private let ephemeralRoot: URL?
    private var job: Task<Void, Never>?
    private var generation = UUID()
    private var l: OrbitStrings { OrbitStrings(language: language) }

    init(root: URL? = nil, capture: (any ScreenshotCapturing)? = nil, preview: Bool = false,
         copyImage: @escaping (CGImage) -> Void = { image in
             NSPasteboard.general.clearContents()
             NSPasteboard.general.writeObjects([NSImage(cgImage: image, size: .zero)])
         }, copyText: @escaping (String) -> Void = { text in
             NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
         }) {
        self.capture = capture ?? (preview ? PreviewScreenshotCapture() : SystemScreenshotCapture())
        self.copyImage = copyImage; self.copyText = copyText
        let actualRoot: URL
        if let root { actualRoot = root; ephemeralRoot = nil }
        else if preview {
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-screenshot-preview-\(UUID())", isDirectory: true)
            actualRoot = temp; ephemeralRoot = temp
        } else {
            actualRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("UTUVO Orbit/Screenshots", isDirectory: true)
            ephemeralRoot = nil
        }
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-screenshot-edits-\(UUID())", isDirectory: true)
        do { library = try CaptureLibrary(root: actualRoot); recent = library?.captures ?? [] }
        catch { failed = true; message = error.localizedDescription }
    }

    func loadFixture() {
        do { try admit(ScreenshotFixture.image()) } catch { show(error) }
    }

    func take(_ mode: ScreenshotCaptureMode) {
        guard !busy, library != nil else { return }
        begin { [self] in
            let request = generation
            waitingForSelection = true
            defer { if generation == request { waitingForSelection = false } }
            let result = try await capture.capture(mode)
            try Task.checkCancellation()
            try admit(result)
            message = l("截圖已就緒，可以開始編修。")
        }
    }

    func chooseImage() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { importImage(url) }
    }

    func importImage(_ url: URL) {
        guard !busy, library != nil else { return }
        begin { [self] in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let image = try await Task.detached(priority: .userInitiated) { try ScreenshotEditing.load(url) }.value
            try Task.checkCancellation()
            guard let library else { return }
            let item = try library.ingest(url)
            try await restoreSelection(item, original: image)
            message = l("已加入副本，原始圖片保持不變。")
        }
    }

    func select(_ id: UUID) {
        guard !busy, let item = recent.first(where: { $0.id == id }), let library else { return }
        begin { [self] in
            let url = library.url(for: item)
            let image = try await Task.detached(priority: .userInitiated) { try ScreenshotEditing.load(url) }.value
            try Task.checkCancellation(); try await restoreSelection(item, original: image)
        }
    }
    private func select(_ item: Capture, image: CGImage) {
        original = image; self.image = image; selectedID = item.id; edits = []
        draftNeedsRecovery = false
        recent = library?.captures ?? []
    }
    private func draftURL(_ id: UUID) -> URL? { library?.root.appendingPathComponent(id.uuidString + ".edits.json") }
    private func restoreSelection(_ item: Capture, original: CGImage) async throws {
        select(item, image: original)
        var saved: [ScreenshotEdit] = []
        do {
            if let url = draftURL(item.id), FileManager.default.fileExists(atPath: url.path) {
                saved = try JSONDecoder().decode([ScreenshotEdit].self, from: Data(contentsOf: url))
            }
            let proposed = saved
            let rendered = try await Task.detached(priority: .userInitiated) { try ScreenshotEditing.render(original, edits: proposed) }.value
            try Task.checkCancellation()
            image = rendered; edits = saved
        } catch {
            if !(error is CancellationError) { draftNeedsRecovery = true }
            throw error
        }
    }

    private func admit(_ image: CGImage) throws {
        guard let library else { return }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let file = scratch.appendingPathComponent("Screenshot-\(UUID()).png")
        try ScreenshotEditing.writePNG(image, to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let item = try library.ingest(file)
        select(item, image: image)
    }

    func apply(from: CGPoint, to: CGPoint) {
        guard edits.count < 32 else { failed = true; message = l("已達 32 次編修，請先輸出再繼續。"); return }
        render(edits + [.init(tool: tool, start: from, end: to)])
    }
    func undo() { guard !edits.isEmpty else { return }; render(Array(edits.dropLast())) }
    func resetEdits() {
        if draftNeedsRecovery, let id = selectedID, let url = draftURL(id) {
            do {
                let backup = url.deletingLastPathComponent().appendingPathComponent(id.uuidString + ".edits.backup-\(UUID()).json")
                try FileManager.default.copyItem(at: url, to: backup)
                try JSONEncoder().encode([ScreenshotEdit]()).write(to: url, options: .atomic)
                draftNeedsRecovery = false; image = original; edits = []; failed = false
                message = l("已備份編修紀錄並還原原圖。")
            } catch { show(error) }
        } else { render([]) }
    }
    private func render(_ proposed: [ScreenshotEdit]) {
        guard !busy, !draftNeedsRecovery, let original else { return }
        begin { [self] in
            let output = try await Task.detached(priority: .userInitiated) { try ScreenshotEditing.render(original, edits: proposed) }.value
            try Task.checkCancellation()
            if let id = selectedID, let url = draftURL(id) {
                try JSONEncoder().encode(proposed).write(to: url, options: .atomic)
            }
            self.image = output; self.edits = proposed
        }
    }

    func copy() {
        guard !busy, let image else { return }
        copyImage(image); failed = false; message = l("已複製編修後的圖片。")
    }

    func recognize() {
        guard !busy, image != nil else { return }
        begin { [self] in
            let file = try currentCopy()
            defer { try? FileManager.default.removeItem(at: file) }
            let text = try await OCR.recognize(file)
            try Task.checkCancellation()
            if text.isEmpty { message = l("這張沒有辨識到文字。") }
            else { copyText(text); message = l("已複製辨識出的文字。") }
        }
    }

    func chooseExport() {
        guard !busy, image != nil else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = l("輸出到這裡")
        if panel.runModal() == .OK, let url = panel.url { export(to: url) }
    }

    func export(to folder: URL) {
        guard !busy else { return }
        begin { [self] in
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            let file = try currentCopy()
            defer { try? FileManager.default.removeItem(at: file) }
            let output = try await Task.detached(priority: .userInitiated) {
                try QuickFileProcessor.process([file], operation: .png, destination: folder)
            }.value
            try Task.checkCancellation()
            message = l("已輸出到 %@", output.lastPathComponent)
        }
    }

    func sendToFiles() {
        guard !busy else { return }
        do { onSendToFiles?(try currentCopy()); failed = false; message = l("已加入檔案工具。") } catch { show(error) }
    }
    func sendToClothesline() {
        guard !busy, canSendToClothesline() else { return }
        do {
            let file = try currentCopy()
            defer { try? FileManager.default.removeItem(at: file) }
            guard onSendToClothesline?(file) == true else { throw ScreenshotEditError.exportFailed }
            failed = false; message = l("已掛上晾衣繩。")
        } catch { show(error) }
    }
    func openLibrary() { if let library { NSWorkspace.shared.open(library.root) } }

    /// A unique flattened copy is shared; callers never receive the original.
    private func currentCopy() throws -> URL {
        guard let image else { throw ScreenshotEditError.invalidImage }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let url = scratch.appendingPathComponent("Orbit-Screenshot-\(UUID().uuidString.prefix(8)).png")
        try ScreenshotEditing.writePNG(image, to: url)
        return url
    }

    private func begin(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; failed = false; message = nil
        let id = UUID(); generation = id
        job = Task { [weak self] in
            do { try await operation() }
            catch {
                if let self, self.generation == id { self.show(error) }
            }
            if let self, self.generation == id { self.busy = false; self.job = nil }
        }
    }

    func cancel() {
        generation = UUID(); job?.cancel(); job = nil; capture.cancel(); busy = false; waitingForSelection = false
        failed = false; message = l("已取消操作。")
    }
    func stop() {
        cancel()
        try? FileManager.default.removeItem(at: scratch)
        if let ephemeralRoot { try? FileManager.default.removeItem(at: ephemeralRoot) }
    }
    private func show(_ error: any Error) {
        if error is CancellationError || (error as? ScreenshotCaptureError) == .cancelled {
            failed = false; message = l("已取消操作。"); return
        }
        failed = true
        switch error {
        case ScreenshotCaptureError.unavailable: message = l("系統截圖選擇器目前不可用，請使用 ⌘⇧4 截圖後匯入。")
        case ScreenshotCaptureError.selectionRejected: message = ToolCopy(language: language)("所選內容不符合擷取條件，請重新選擇。", "The selected content is not eligible for capture. Choose another window or display.")
        case ScreenshotCaptureError.selectionTimedOut: message = ToolCopy(language: language)("選取已逾時。請重新擷取，並在系統選擇器中選取視窗或螢幕。", "Selection timed out. Try again and choose a window or display in the system picker.")
        case ScreenshotCaptureError.frameTimedOut: message = ToolCopy(language: language)("沒有及時收到完整畫面。請重新擷取。", "No complete frame arrived in time. Try the capture again.")
        case ScreenshotEditError.invalidSelection: message = l("請在圖片內拖出有效範圍。")
        case ScreenshotEditError.tooLarge, ScreenshotCaptureError.invalidSize: message = l("圖片超過可處理尺寸。")
        default: message = l("無法完成截圖操作：%@", error.localizedDescription)
        }
    }
}
