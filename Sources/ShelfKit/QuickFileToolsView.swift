import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
public final class QuickFileToolsModel: ObservableObject {
    @Published public private(set) var files: [URL] = []
    @Published public private(set) var busy = false
    @Published public private(set) var output: URL?
    @Published public private(set) var message: String?
    @Published public private(set) var failed = false
    public var shelfFiles: (() -> [URL])?
    public var language = "system"
    private let copyText: (String) -> Void
    private var strings: DropStrings { DropStrings(language: DropLanguage(rawValue: language) ?? .system) }

    public init(copyText: @escaping (String) -> Void = { text in NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }) {
        self.copyText = copyText
    }

    public func setFiles(_ urls: [URL]) {
        guard !busy else { return }
        var seen = Set<URL>()
        files = urls.filter { $0.isFileURL && seen.insert($0.standardizedFileURL).inserted }
        output = nil; message = nil; failed = false
    }
    public func removeFile(_ url: URL) { setFiles(files.filter { $0 != url }) }
    public func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !busy, !providers.isEmpty else { return false }
        busy = true
        Task {
            var dropped: [URL] = []
            for provider in providers {
                let url: URL? = await withCheckedContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        if let url = item as? URL { continuation.resume(returning: url) }
                        else if let data = item as? Data { continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil)) }
                        else { continuation.resume(returning: nil) }
                    }
                }
                if let url, url.isFileURL { dropped.append(url) }
            }
            busy = false
            if dropped.isEmpty { failed = true; message = strings.text("沒有可讀取的檔案路徑。", "No readable file paths were found.") }
            else { setFiles(files + dropped) }
        }
        return true
    }
    public func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true; panel.canChooseFiles = true; panel.canChooseDirectories = true
        if panel.runModal() == .OK { setFiles(panel.urls) }
    }
    public func useShelf() { setFiles(shelfFiles?() ?? []) }
    public func copyPaths() {
        guard !files.isEmpty else { return }
        copyText(files.map(\.path).joined(separator: "\n"))
        failed = false; message = strings.text("已複製路徑。", "Paths copied.")
    }
    public func chooseDestinationAndRun(_ operation: QuickFileOperation) {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = strings.text("輸出到這裡", "Export Here")
        if panel.runModal() == .OK, let destination = panel.url { Task { await run(operation, destination: destination) } }
    }
    public func run(_ operation: QuickFileOperation, destination: URL) async {
        guard !busy, !files.isEmpty else { return }
        busy = true; output = nil; message = nil; failed = false
        let inputs = files
        let accesses = (inputs + [destination]).filter { $0.startAccessingSecurityScopedResource() }
        defer { accesses.forEach { $0.stopAccessingSecurityScopedResource() }; busy = false }
        do {
            output = try await Task.detached(priority: .userInitiated) {
                try QuickFileProcessor.process(inputs, operation: operation, destination: destination)
            }.value
            message = strings.text("已輸出新副本。", "New copies exported.")
        } catch {
            failed = true
            switch error {
            case QuickFileError.notImage(let name): message = strings.text("不是可讀取的圖片：", "Not a readable image: ") + name
            case QuickFileError.unreadable(let name): message = strings.text("無法讀取：", "Cannot read: ") + name
            case QuickFileError.tooLarge(let name): message = strings.text("圖片超過 8,000 萬像素：", "Image exceeds 80 megapixels: ") + name
            case QuickFileError.destinationInsideSource: message = strings.text("請把輸出位置選在來源資料夾之外。", "Choose an export location outside the source folder.")
            default: message = strings.text("無法完成輸出：", "Export failed: ") + error.localizedDescription
            }
        }
    }
}

public struct QuickFileToolsView: View {
    @ObservedObject private var model: QuickFileToolsModel
    private let language: String
    private let preview: Bool
    @State private var dropTargeted = false
    private var s: DropStrings { DropStrings(language: DropLanguage(rawValue: language) ?? .system) }
    public init(model: QuickFileToolsModel, language: String, preview: Bool = false) {
        self.model = model; self.language = language; self.preview = preview
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(s.text("檔案，順手整理。", "Files, ready to go.")).font(.system(size: 21, weight: .semibold))
                Text(s.text("選好檔案，一次輸出新的副本。", "Choose files and export fresh copies in one step."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(s.text("待處理檔案", "Selected files"), systemImage: "doc.on.doc").fontWeight(.medium)
                    Spacer()
                    Text("\(model.files.count)").monospacedDigit().foregroundStyle(.secondary)
                }
                if model.files.isEmpty {
                    Text(s.text("拖入檔案、從檔案架加入，或直接選擇。", "Drop files here, add from the shelf, or choose them."))
                        .foregroundStyle(.secondary).padding(.vertical, 10)
                } else {
                    ForEach(Array(model.files.prefix(4).enumerated()), id: \.offset) { _, file in
                        HStack {
                            Label(file.lastPathComponent, systemImage: "doc").lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button { model.removeFile(file) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain)
                                .accessibilityLabel(s.text("移除：", "Remove: ") + file.lastPathComponent)
                        }
                    }
                    if model.files.count > 4 { Text(s.text("另有 ", "And ") + "\(model.files.count - 4)" + s.text(" 個檔案", " more files")).foregroundStyle(.secondary) }
                }
                HStack {
                    Button(s.text("選擇檔案…", "Choose Files…")) { model.chooseFiles() }.disabled(preview)
                    Button(s.text("從檔案架加入", "Add from Shelf")) { model.useShelf() }.disabled(preview)
                    Spacer()
                    Button(s.text("清空", "Clear")) { model.setFiles([]) }.disabled(model.files.isEmpty)
                }
            }.padding(18).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(dropTargeted ? Color.accentColor : Color.clear, lineWidth: 2))
                .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTargeted) { providers in
                    !preview && model.acceptDrop(providers)
                }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                action(s.text("打包 ZIP", "Create ZIP"), symbol: "archivebox", operation: .zip)
                action(s.text("縮至 1600px · PNG", "Resize to 1600px · PNG"), symbol: "arrow.down.right.and.arrow.up.left", operation: .resize)
                action(s.text("轉成 PNG", "Convert to PNG"), symbol: "photo", operation: .png)
                action(s.text("轉成 JPEG", "Convert to JPEG"), symbol: "photo.fill", operation: .jpeg)
            }.disabled(model.files.isEmpty || model.busy || preview)
            HStack {
                Button(s.text("複製檔案路徑", "Copy File Paths")) { model.copyPaths() }.disabled(model.files.isEmpty || preview)
                Spacer()
                if model.busy { ProgressView().controlSize(.small); Text(s.text("處理中…", "Processing…")) }
            }
            if let message = model.message {
                Label(message, systemImage: model.failed ? "exclamationmark.triangle" : "checkmark.circle")
                    .foregroundStyle(model.failed ? Color.orange : Color.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let output = model.output {
                Button(s.text("在 Finder 顯示輸出", "Reveal Export in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([output]) }
            }
            Text(s.text("每次輸出到新的 Orbit Export 資料夾；JPEG 的透明區域會填白。", "Each export gets a new Orbit Export folder. Transparent areas become white in JPEG."))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12)).tint(.primary).disabled(model.busy)
        .onAppear { model.language = language }
        .onChange(of: language) { _, value in model.language = value }
    }

    private func action(_ title: String, symbol: String, operation: QuickFileOperation) -> some View {
        Button { model.chooseDestinationAndRun(operation) } label: {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        }.buttonStyle(.bordered)
    }
}
