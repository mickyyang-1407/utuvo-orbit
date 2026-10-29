import AppKit
import Combine
import ClotheslineKit
import OrbitCore

@MainActor
final class TextToolsModel: ObservableObject {
    @Published var input = "  Hello Orbit  \n\n  Keep it simple.  " { didSet { output = ""; error = nil } }
    @Published private(set) var output = ""
    @Published var action: TextAction = .trimLines { didSet { output = ""; error = nil } }
    @Published private(set) var error: String?
    func transform() {
        do { output = try action.apply(input); error = nil } catch { output = ""; self.error = error.localizedDescription }
    }
}

@MainActor
final class PDFToolsModel: ObservableObject {
    @Published var action: PDFAction = .merge
    @Published var pages = ""
    @Published private(set) var files: [URL] = []
    @Published private(set) var busy = false
    @Published private(set) var output: URL?
    @Published private(set) var error: String?
    private var job: Task<Void, Never>?
    private var generation = UUID()
    func choose() { let urls = ToolFiles.choose(action == .images ? [.image] : [.pdf]); if !urls.isEmpty { files = urls; output = nil; error = nil } }
    func setFiles(_ urls: [URL]) { files = urls; output = nil; error = nil }
    func move(_ index: Int, by offset: Int) { guard !busy, files.indices.contains(index + offset) else { return }; files.swapAt(index, index + offset) }
    func remove(_ index: Int) { guard !busy, files.indices.contains(index) else { return }; files.remove(at: index) }
    func export() { guard let parent = ToolFiles.directory() else { return }; export(to: parent) }
    func export(to parent: URL) {
        guard !busy, !files.isEmpty else { return }
        let urls = files; let operation = action; let selectedPages = pages
        let current = UUID(); generation = current; busy = true; output = nil; error = nil
        job = Task { [weak self] in
            guard let self else { return }
            let scopes = (urls + [parent]).filter { $0.startAccessingSecurityScopedResource() }
            defer { scopes.forEach { $0.stopAccessingSecurityScopedResource() }; if generation == current { busy = false } }
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    let exports = try PDFToolkit.process(urls, action: operation, pages: selectedPages)
                    try Task.checkCancellation(); return try ToolFiles.write(exports, to: parent)
                }
                let destination = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled, generation == current else { return }; output = destination
            } catch { if generation == current { self.error = error.localizedDescription } }
        }
    }
    func stop() { generation = UUID(); job?.cancel(); busy = false }
}

@MainActor
final class QRToolsModel: ObservableObject {
    @Published var text = "https://utuvo.app"
    @Published private(set) var image: CGImage?
    @Published private(set) var results: [String] = []
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    var language: AppLanguage = .system
    private var job: Task<Void, Never>?
    private var generation = UUID()
    private let copyText: (String) -> Void
    init(copyText: @escaping (String) -> Void) { self.copyText = copyText }
    func generate() {
        guard !busy else { return }
        do { image = try QRToolkit.generate(text); message = nil } catch { image = nil; message = error.localizedDescription }
    }
    func chooseImage() { if let url = ToolFiles.choose([.image], multiple: false).first { recognize(url) } }
    func recognize(_ url: URL) {
        begin {
            let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return try await Task.detached(priority: .userInitiated) { try QRToolkit.recognize(ScreenshotEditing.load(url)) }.value
        }
    }
    func recognize(_ image: CGImage) { begin { try await Task.detached(priority: .userInitiated) { try QRToolkit.recognize(image) }.value } }
    private func begin(_ operation: @escaping () async throws -> [String]) {
        guard !busy else { return }
        let current = UUID(); generation = current; busy = true; results = []; message = nil
        job = Task { [weak self] in
            guard let self else { return }
            defer { if generation == current { busy = false } }
            do {
                let values = try await operation()
                guard !Task.isCancelled, generation == current else { return }
                results = values
                if values.isEmpty { message = ToolCopy(language: language)("沒有辨識到 QR Code。", "No QR code found.") }
            } catch { if generation == current { message = error.localizedDescription } }
        }
    }
    func copy(_ text: String) { copyText(text) }
    func export() {
        guard let image, let parent = ToolFiles.directory() else { return }
        let scoped = parent.startAccessingSecurityScopedResource(); defer { if scoped { parent.stopAccessingSecurityScopedResource() } }
        do {
            _ = try ToolFiles.write([ToolExport(name: "Orbit-QR.png", data: QRToolkit.png(image))], to: parent)
            message = ToolCopy(language: language)("PNG 已匯出。", "PNG exported.")
        } catch { message = error.localizedDescription }
    }
    func stop() { generation = UUID(); job?.cancel(); busy = false }
}

struct ColorSwatch: Identifiable, Codable, Equatable {
    var id = UUID()
    var hex: String
    static func normalized(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let raw = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard raw.count == 6, raw.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) }) else { return nil }
        return "#" + raw
    }
    var components: (red: Int, green: Int, blue: Int) {
        let value = Int(hex.dropFirst(), radix: 16) ?? 0
        return ((value >> 16) & 255, (value >> 8) & 255, value & 255)
    }
    var rgb: String { let c = components; return "rgb(\(c.red), \(c.green), \(c.blue))" }
    var color: NSColor { let c = components; return NSColor(srgbRed: Double(c.red)/255, green: Double(c.green)/255, blue: Double(c.blue)/255, alpha: 1) }
}

@MainActor
final class ColorToolsModel: ObservableObject {
    @Published var input = "#27A89A"
    @Published private(set) var swatches: [ColorSwatch] = []
    @Published private(set) var error: String?
    private let storage: ToolStorage<[ColorSwatch]>
    private let copyText: (String) -> Void
    private var generation = UUID()
    private var sampler: NSColorSampler?
    var needsRecovery: Bool { storage.damaged }
    var current: ColorSwatch? { ColorSwatch.normalized(input).map { ColorSwatch(hex: $0) } }
    init(defaults: UserDefaults?, copyText: @escaping (String) -> Void) {
        storage = ToolStorage(defaults, "tools.colors.v1"); self.copyText = copyText
        swatches = storage.load(fallback: [], validate: { $0.count <= 30 && Set($0.map(\.id)).count == $0.count && $0.allSatisfy { ColorSwatch.normalized($0.hex) == $0.hex } })
    }
    func sample() {
        let current = UUID(); generation = current
        let sampler = NSColorSampler(); self.sampler = sampler
        sampler.show { [weak self] value in
            Task { @MainActor in
                guard let self, self.generation == current else { return }; self.sampler = nil
                guard let rgb = value?.usingColorSpace(.sRGB) else { return }
                self.input = String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
            }
        }
    }
    func save() {
        guard let value = current else { error = "Use six hexadecimal digits / 請輸入六位 HEX 色碼"; return }
        guard !swatches.contains(where: { $0.hex == value.hex }) else { return }
        persist(Array(([value] + swatches).prefix(30)))
    }
    func remove(_ value: ColorSwatch) { persist(swatches.filter { $0.id != value.id }) }
    func copy(_ text: String) { copyText(text) }
    func recover() { do { try storage.backupAndReset([]); swatches = []; error = nil } catch { self.error = error.localizedDescription } }
    func stop() { generation = UUID(); sampler = nil }
    private func persist(_ values: [ColorSwatch]) { do { try storage.save(values); swatches = values; error = nil } catch { self.error = error.localizedDescription } }
}
