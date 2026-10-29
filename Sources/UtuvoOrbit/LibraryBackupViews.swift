import AppKit
import Combine
import OrbitCore
import SwiftUI
import UniformTypeIdentifiers

/// What a model has to offer so its library can be backed up and restored.
/// The records stay in the model; this only moves them in and out.
@MainActor
protocol LibraryBackupParticipant: ObservableObject {
    var libraryBackupKind: LibraryBackupKind { get }
    var libraryBackupRecords: [LibraryBackupRecord] { get }
    /// A draft that is not saved yet blocks every transfer.
    var libraryBackupIsDirty: Bool { get }
    /// A damaged library blocks every transfer: an empty backup must never
    /// stand in for bytes that could not be read.
    var libraryBackupNeedsRecovery: Bool { get }
    /// Fires whenever the library or its draft changes.
    var libraryBackupChanges: AnyPublisher<Void, Never> { get }
    /// The message of the last failed save, if there is one.
    var libraryBackupError: String? { get }
    /// The bytes of the library as it is saved right now.
    func libraryBackupPayload() throws -> Data
    /// Adds the imported records with one save.
    @discardableResult func libraryBackupApply(_ additions: [LibraryBackupRecord]) -> Bool
}

/// The three libraries that can be backed up.
extension QuickNotesModel: LibraryBackupParticipant {}
extension SnippetsModel: LibraryBackupParticipant {}
extension QuickLinksModel: LibraryBackupParticipant {}

/// The state of one library transfer.
///
/// A preview never writes and never flushes. Only an explicit apply writes,
/// and it writes once.
@MainActor
final class LibraryBackupController<Model: LibraryBackupParticipant>: ObservableObject {
    /// The import that is waiting for the user.
    @Published private(set) var plan: LibraryBackupPlan?
    /// What happened last, in plain words.
    @Published private(set) var message: String?
    /// Why the last attempt did not work.
    @Published private(set) var failure: String?
    /// Where the export went.
    @Published private(set) var exportedFolder: URL?

    let kind: LibraryBackupKind
    /// In preview the transfer is off, so nothing can reach the file system.
    /// It is a mode, so it stays readable and settable inside the app.
    var preview: Bool

    private let model: Model
    /// The library as it was when the preview was made.
    private var base: [LibraryBackupRecord]?
    private var cancellable: AnyCancellable?
    private var applying = false
    /// How a backup file is read. A test injects its own, so it can prove
    /// that nothing was read without touching a real file.
    private let readFile: (URL) throws -> Data

    init(model: Model, preview: Bool,
         readFile: @escaping (URL) throws -> Data = { try LibraryBackupFileIO.readBackup(at: $0) }) {
        self.model = model
        self.preview = preview
        self.kind = model.libraryBackupKind
        self.readFile = readFile
        subscribe()
    }

    // MARK: - Export

    /// Writes the library into a new folder of its own. Nothing existing is
    /// touched and the source library is not changed.
    func export() {
        guard !preview else {
            failure = "預覽模式不提供檔案傳輸 / File transfer is off in preview"
            return
        }
        guard !model.libraryBackupIsDirty else {
            failure = "請先儲存目前的變更 / Save your changes first"
            return
        }
        guard !model.libraryBackupNeedsRecovery else {
            failure = "這份資料需先備份並重設 / This data needs backup and reset first"
            return
        }
        guard let parent = ToolFiles.directory() else { return }
        let scoped = parent.startAccessingSecurityScopedResource()
        defer { if scoped { parent.stopAccessingSecurityScopedResource() } }
        do {
            let data = try model.libraryBackupPayload()
            let folder = try LibraryBackupFileIO.writeBackup(data, kind: kind, to: parent)
            exportedFolder = folder
            message = "備份已寫到：\(folder.path) / Backup written to: \(folder.path)"
            failure = nil
        } catch let error {
            failure = error.localizedDescription
        }
    }

    // MARK: - Import

    /// Asks for one backup file and shows what it would add. Nothing is
    /// written here.
    func chooseBackupFile() {
        guard !preview else {
            failure = "預覽模式不提供檔案傳輸 / File transfer is off in preview"
            return
        }
        // An older preview never stays actionable after a newer file was tried.
        invalidate()
        message = nil
        failure = nil
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.message = "選擇一個 Orbit 資料備份檔 / Choose an Orbit data backup file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    /// Reads a backup file and plans the merge. The file is read once, into
    /// memory, and is not read again when the plan is applied.
    func load(_ url: URL) {
        // The preview mode keeps the file system out of reach.
        guard !preview else {
            invalidate()
            failure = "預覽模式不提供檔案傳輸 / File transfer is off in preview"
            return
        }
        // An unsaved draft and a damaged library block the transfer before
        // anything is read.
        guard !model.libraryBackupIsDirty else {
            invalidate()
            failure = "請先儲存目前的變更 / Save your changes first"
            return
        }
        guard !model.libraryBackupNeedsRecovery else {
            invalidate()
            failure = "這份資料需先備份並重設 / This data needs backup and reset first"
            return
        }
        do {
            let data = try readFile(url)
            let incoming = try LibraryBackupCodec.decode(kind: kind, data: data)
            let current = model.libraryBackupRecords
            let newPlan = try LibraryBackupPlanner.plan(kind: kind, current: current, incoming: incoming)
            plan = newPlan
            base = current
            failure = nil
        } catch let error {
            plan = nil
            base = nil
            failure = error.localizedDescription
        }
    }

    /// Writes the plan into the library with one save.
    func apply() {
        // The preview mode keeps the file system out of reach.
        guard !preview else {
            invalidate()
            failure = "預覽模式不提供檔案傳輸 / File transfer is off in preview"
            return
        }
        guard let plan, let base else {
            failure = "沒有可匯入的預覽 / There is no preview to apply"
            return
        }
        guard !model.libraryBackupIsDirty else {
            invalidate()
            failure = "請先儲存目前的變更 / Save your changes first"
            return
        }
        guard !model.libraryBackupNeedsRecovery else {
            invalidate()
            failure = "這份資料需先備份並重設 / This data needs backup and reset first"
            return
        }
        guard model.libraryBackupRecords == base else {
            invalidate()
            failure = "預覽後資料已經變更，請重新預覽 / The data changed after the preview, please preview again"
            return
        }
        if plan.isEmpty {
            self.plan = nil
            self.base = nil
            message = "沒有新的資料，沒有寫入任何東西 / Nothing new, nothing was written"
            return
        }
        applying = true
        let saved = model.libraryBackupApply(plan.additions)
        applying = false
        if saved {
            self.plan = nil
            self.base = nil
            message = "已匯入 \(plan.additions.count) 筆 / Imported \(plan.additions.count) records"
            failure = nil
        } else {
            // The library, its file and the selection are unchanged, so the
            // user can simply try again.
            failure = model.libraryBackupError ?? "匯入失敗，請再試一次 / The import failed, please try again"
        }
    }

    /// Drops the preview. Nothing changes on disk.
    func cancel() {
        plan = nil
        base = nil
        message = nil
        failure = nil
    }

    // MARK: - Internals

    private func subscribe() {
        cancellable = model.libraryBackupChanges.sink { [weak self] in
            Task { @MainActor in self?.invalidateIfNeeded() }
        }
    }

    /// A preview is only good while the library stays as it was.
    private func invalidateIfNeeded() {
        guard !applying, plan != nil else { return }
        guard model.libraryBackupRecords == base, !model.libraryBackupIsDirty,
              !model.libraryBackupNeedsRecovery else {
            invalidate()
            failure = "預覽已過期，請重新選擇備份檔 / The preview is out of date, choose the backup file again"
            return
        }
    }

    private func invalidate() {
        plan = nil
        base = nil
    }
}

/// Backup and restore for one library.
///
/// The transfer is always started by the user, and the preview mode keeps the
/// file system out of reach.
struct LibraryBackupControls<Model: LibraryBackupParticipant>: View {
    @ObservedObject var model: Model
    var language: AppLanguage
    var preview: Bool
    @StateObject private var controller: LibraryBackupController<Model>
    private var c: ToolCopy { ToolCopy(language: language) }

    init(model: Model, language: AppLanguage, preview: Bool) {
        self.model = model
        self.language = language
        self.preview = preview
        _controller = StateObject(wrappedValue: LibraryBackupController(model: model, preview: preview))
    }

    var body: some View {
        WorkbenchCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(c("備份與匯入", "Backup and import")).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button(c("匯出備份…", "Export backup…")) { controller.export() }
                        .accessibilityLabel(c("匯出這份資料的備份", "Export this data as a backup"))
                        .disabled(preview || model.libraryBackupIsDirty || model.libraryBackupNeedsRecovery)
                    Button(c("匯入備份…", "Import backup…")) { controller.chooseBackupFile() }
                        .accessibilityLabel(c("匯入一份資料備份", "Import a data backup"))
                        .disabled(preview || model.libraryBackupIsDirty || model.libraryBackupNeedsRecovery)
                }
                if let plan = controller.plan {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(c("將新增 \(plan.additions.count) 筆，略過 \(plan.identicalCount) 筆已經有的記錄。",
                               "Will add \(plan.additions.count) records and skip \(plan.identicalCount) that are already here."))
                            .font(.caption)
                        HStack(spacing: 12) {
                            Button(c("匯入", "Import")) { controller.apply() }.buttonStyle(.borderedProminent)
                            Button(c("取消", "Cancel")) { controller.cancel() }.keyboardShortcut(.cancelAction)
                        }
                    }
                }
                if let message = controller.message {
                    Text(message).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                if let failure = controller.failure {
                    Text(failure).foregroundStyle(.orange).font(.caption).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var detail: String {
        let kindNote: String = switch controller.kind {
        case .notes:
            c("備份包含最近刪除的筆記。", "The backup includes the notes in Recently Deleted.")
        case .snippets:
            c("備份包含每一則片段的完整內容。", "The backup holds the full text of every snippet.")
        case .quicklinks:
            c("備份只包含連結名稱與網址範本。", "The backup holds the link titles and URL templates.")
        }
        let privacy = c("備份是純文字檔，請放在只有你能讀到的地方。",
                        "A backup is a plain text file. Store it where only you can read it.")
        let merge = c("匯入只會新增資料，不會覆蓋或刪除現有記錄。",
                      "Import only adds records. Nothing on this Mac is overwritten or deleted.")
        return kindNote + " " + merge + " " + privacy
    }
}
