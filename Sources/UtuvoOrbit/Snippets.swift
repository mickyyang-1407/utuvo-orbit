import AppKit
import Combine
import Foundation

/// A plain-text snippet. The body is a template that may contain `{{date}}`,
/// `{{time}}` and named custom fields such as `{{name}}`.
struct Snippet: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var title: String
    var keyword: String
    var body: String
    var pinned = false
    var modified: Date
}

enum SnippetError: LocalizedError, Equatable {
    case emptyTitle
    case titleTooLong
    case keywordTooLong
    case bodyTooLarge
    case tooManySnippets
    case storageFull
    case duplicateKeyword
    case malformedBraces
    case unsupportedPlaceholder
    case invalidFieldName
    case tooManyFields
    case missingFieldValue
    case duplicateIdentifier
    case invalidDate

    var errorDescription: String? {
        switch self {
        case .emptyTitle: "Give the snippet a title / 請替片段取個名稱"
        case .titleTooLong: "Title is limited to 120 characters / 標題上限 120 字"
        case .keywordTooLong: "Keyword is limited to 32 characters / 關鍵字上限 32 字"
        case .bodyTooLarge: "Each snippet is limited to 64 KiB / 每則片段上限 64 KiB"
        case .tooManySnippets: "Up to 100 snippets / 最多 100 則片段"
        case .storageFull: "Snippet storage is full (2 MB) / 片段已達 2 MB 上限"
        case .duplicateKeyword: "That keyword is already used / 這個關鍵字已經有人用了"
        case .malformedBraces: "The template has an unclosed {{ }} / 範本裡的 {{ }} 沒有閉合"
        case .unsupportedPlaceholder: "This placeholder is not supported / 不支援這個佔位符"
        case .invalidFieldName: "Field names start with a letter and use letters, digits or _ / 欄位名稱要以字母開頭，只能用字母、數字或底線"
        case .tooManyFields: "Up to 16 custom fields / 最多 16 個自訂欄位"
        case .missingFieldValue: "Fill in every field first / 請先填寫所有欄位"
        case .duplicateIdentifier: "A snippet repeats an ID / 有片段重複了 ID"
        case .invalidDate: "A snippet has an unusable date / 有片段的日期不合法"
        }
    }
}

/// The snippet template grammar.
///
/// `{{date}}` and `{{time}}` are filled from one shared date snapshot. Any
/// other `{{name}}` is a custom field: the name starts with an ASCII letter and
/// may continue with letters, digits or underscores (32 characters at most,
/// 16 distinct custom fields per template). Reserved system-like names are
/// refused instead of becoming custom fields, so nothing can reach the network
/// or the clipboard.
///
/// Expansion walks the parsed template once: a value the user types is inserted
/// literally, so `{{date}}` inside a value stays `{{date}}`.
enum SnippetTemplate {
    struct Field: Equatable, Identifiable, Sendable {
        var id: String { name }
        let name: String
        let isBuiltIn: Bool
    }

    enum Segment: Equatable {
        case literal(String)
        case field(String)
    }

    static let builtInNames = ["date", "time"]
    /// Only names that would suggest Orbit reads something by itself are
    /// refused. Every other name — email, url, user, path, input, … — is an
    /// ordinary custom field the user fills in by hand. Nothing in this tool
    /// reads the clipboard, the network, the shell or the environment.
    static let reservedNames: Set<String> = ["clipboard", "network", "shell", "env", "system"]
    static let maxCustomFields = 16
    static let maxFieldNameLength = 32
    static let maxTitleLength = 120
    static let maxKeywordLength = 32
    static let maxBodyBytes = 65_536
    static let maxSnippets = 100
    static let maxTotalBytes = 2_000_000

    // MARK: - Parsing

    static func parse(_ body: String) throws -> [Segment] {
        var segments: [Segment] = []
        var literal = ""
        var index = body.startIndex
        while index < body.endIndex {
            guard body[index] == "{" else {
                literal.append(body[index])
                index = body.index(after: index)
                continue
            }
            let next = body.index(after: index)
            guard next < body.endIndex, body[next] == "{" else {
                // A single brace is ordinary text.
                literal.append(body[index])
                index = next
                continue
            }
            guard let close = body.range(of: "}}", range: body.index(after: next)..<body.endIndex) else {
                throw SnippetError.malformedBraces
            }
            let name = String(body[body.index(after: next)..<close.lowerBound])
            guard isValidFieldName(name) else { throw SnippetError.invalidFieldName }
            if !builtInNames.contains(name), reservedNames.contains(name) {
                throw SnippetError.unsupportedPlaceholder
            }
            if !literal.isEmpty {
                segments.append(.literal(literal))
                literal = ""
            }
            segments.append(.field(name))
            index = close.upperBound
        }
        if !literal.isEmpty { segments.append(.literal(literal)) }
        return segments
    }

    /// Every placeholder used by the template, in order of appearance.
    static func fields(in body: String) throws -> [Field] {
        var seen: [String] = []
        for segment in try parse(body) {
            guard case .field(let name) = segment else { continue }
            if !seen.contains(name) { seen.append(name) }
        }
        let custom = seen.filter { !builtInNames.contains($0) }
        guard custom.count <= maxCustomFields else { throw SnippetError.tooManyFields }
        return seen.map { Field(name: $0, isBuiltIn: builtInNames.contains($0)) }
    }

    /// Expands the template once. `values` supplies the custom fields.
    static func expand(_ body: String, values: [String: String], snapshot: Date, timeZone: TimeZone) throws -> String {
        let segments = try parse(body)
        var output = ""
        for segment in segments {
            switch segment {
            case .literal(let text):
                output += text
            case .field(let name):
                if name == "date" { output += formatted(snapshot, timeZone, format: "yyyy-MM-dd") }
                else if name == "time" { output += formatted(snapshot, timeZone, format: "HH:mm") }
                else {
                    guard let value = values[name], !value.isEmpty else { throw SnippetError.missingFieldValue }
                    output += value
                }
            }
        }
        return output
    }

    static func isValidFieldName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= maxFieldNameLength else { return false }
        guard let first = name.first, first.isASCII, first.isLetter else { return false }
        for character in name.dropFirst() {
            guard character.isASCII, character.isLetter || character.isNumber || character == "_" else { return false }
        }
        return true
    }

    private static func formatted(_ date: Date, _ timeZone: TimeZone, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}

// MARK: - Model

@MainActor
final class SnippetsModel: ObservableObject {
    @Published private(set) var snippets: [Snippet] = []
    @Published private(set) var selectedID: UUID?
    @Published private(set) var draftTitle = ""
    @Published private(set) var draftKeyword = ""
    @Published private(set) var draftBody = ""
    @Published private(set) var dirty = false
    @Published private(set) var error: String?
    @Published private(set) var preview: String?
    @Published private(set) var previewError: String?
    @Published var query = ""
    /// Current values for the custom fields of the selected template.
    @Published private(set) var fieldValues: [String: String] = [:]

    private let store: ToolStorage<[Snippet]>
    private let now: () -> Date
    private let timeZone: TimeZone
    private let copyText: (String) -> Void
    private var autosave: Task<Void, Never>?

    init(root: URL? = nil, preview: Bool = false, now: @escaping () -> Date = Date.init,
         timeZone: TimeZone = .current, copyText: @escaping (String) -> Void = { _ in }) {
        self.now = now
        self.timeZone = timeZone
        self.copyText = copyText
        let url: URL? = preview ? nil : (root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UTUVO Orbit/Snippets", isDirectory: true)).appendingPathComponent("snippets.json")
        store = ToolStorage(nil, "snippets", fileURL: url)
        snippets = store.load(fallback: [], validate: { values in
            (try? LibraryBackupValidation.snippets(values)) != nil
        })
        if let first = snippets.first {
            selectDraft(first)
        }
    }

    var needsRecovery: Bool { store.damaged }
    var selected: Snippet? { snippets.first { $0.id == selectedID } }

    var visible: [Snippet] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return snippets.filter { term.isEmpty || ($0.title + "\n" + $0.keyword + "\n" + $0.body).localizedCaseInsensitiveContains(term) }
            .sorted {
                if $0.pinned != $1.pinned { return $0.pinned }
                if $0.modified != $1.modified { return $0.modified > $1.modified }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    /// The custom fields the current draft needs, in order of appearance.
    var draftFields: [SnippetTemplate.Field] {
        (try? SnippetTemplate.fields(in: draftBody)) ?? []
    }

    var customFields: [SnippetTemplate.Field] {
        draftFields.filter { !$0.isBuiltIn }
    }

    // MARK: - Editing

    @discardableResult
    func create(title: String = "", body: String = "", keyword: String = "") -> Bool {
        guard flush() else { return false }
        guard snippets.count < SnippetTemplate.maxSnippets else {
            error = SnippetError.tooManySnippets.errorDescription
            return false
        }
        guard let title = validatedTitle(title) else { return false }
        guard let keyword = validatedKeyword(keyword, excluding: nil) else { return false }
        guard body.utf8.count <= SnippetTemplate.maxBodyBytes else {
            error = SnippetError.bodyTooLarge.errorDescription
            return false
        }
        let snippet = Snippet(title: title, keyword: keyword, body: body, modified: now())
        guard save(snippets + [snippet]) else { return false }
        selectDraft(snippet)
        return true
    }

    /// Selecting another snippet is refused while a draft could not be saved.
    @discardableResult
    func select(_ id: UUID) -> Bool {
        guard let snippet = snippets.first(where: { $0.id == id }), flush() else { return false }
        selectDraft(snippets.first(where: { $0.id == snippet.id })!)
        return true
    }

    func editTitle(_ value: String) {
        guard selected?.id != nil, value.count <= SnippetTemplate.maxTitleLength else { return }
        draftTitle = value
        schedule()
    }

    func editKeyword(_ value: String) {
        guard selected?.id != nil, value.count <= SnippetTemplate.maxKeywordLength else { return }
        draftKeyword = value
        schedule()
    }

    func editBody(_ value: String) {
        guard selected?.id != nil else { return }
        guard value.utf8.count <= SnippetTemplate.maxBodyBytes else {
            error = SnippetError.bodyTooLarge.errorDescription
            return
        }
        draftBody = value
        schedule()
    }

    func setFieldValue(_ value: String, for name: String) {
        fieldValues[name] = value
    }

    func fieldValue(_ name: String) -> String { fieldValues[name] ?? "" }

    /// Writes the pending draft. On failure the draft is kept and the caller
    /// is told, so a selection change or a quit can be stopped.
    @discardableResult
    func flush() -> Bool {
        autosave?.cancel()
        autosave = nil
        guard dirty, let index = snippets.firstIndex(where: { $0.id == selectedID }) else { return true }
        var updated = snippets
        updated[index].title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        updated[index].keyword = draftKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        updated[index].body = draftBody
        updated[index].modified = now()
        guard save(updated) else { return false }
        dirty = false
        return true
    }

    @discardableResult
    func pin(_ id: UUID) -> Bool {
        guard flush(), let index = snippets.firstIndex(where: { $0.id == id }) else { return false }
        var updated = snippets
        updated[index].pinned.toggle()
        return save(updated)
    }

    /// Deleting needs a clear confirmation from the user.
    @discardableResult
    func delete(_ id: UUID, confirmed: Bool) -> Bool {
        guard confirmed else { return false }
        guard let index = snippets.firstIndex(where: { $0.id == id }) else { return false }
        var updated = snippets
        updated.remove(at: index)
        guard save(updated) else { return false }
        if selectedID == id {
            if let next = snippets.first { selectDraft(next) }
            else { clearDraft() }
        }
        return true
    }

    func recover() {
        autosave?.cancel()
        autosave = nil
        do {
            try store.backupAndReset([])
            snippets = []
            clearDraft()
            error = nil
        } catch let failure {
            error = failure.localizedDescription
        }
    }

    func stop() { _ = flush() }

    /// Drops the draft that could not be saved, on the user's decision.
    func discardDraft() {
        autosave?.cancel()
        autosave = nil
        if let selected { selectDraft(selected) }
        else { clearDraft() }
        error = nil
    }

    // MARK: - Expansion

    /// Expands the current draft with one shared date snapshot.
    @discardableResult
    func makePreview() -> Bool {
        do {
            let snapshot = now()
            preview = try SnippetTemplate.expand(draftBody, values: fieldValues, snapshot: snapshot, timeZone: timeZone)
            previewError = nil
            return true
        } catch let failure {
            preview = nil
            previewError = failure.localizedDescription
            return false
        }
    }

    /// Explicit copy. Nothing is copied on startup or when the draft changes.
    func copyPreview() {
        guard makePreview(), let preview else { return }
        copyText(preview)
    }

    /// The expanded text for a hand-off to another tool.
    func expansionForSending() -> String? {
        guard makePreview() else { return nil }
        return preview
    }

    // MARK: - Internals

    private func selectDraft(_ snippet: Snippet) {
        selectedID = snippet.id
        draftTitle = snippet.title
        draftKeyword = snippet.keyword
        draftBody = snippet.body
        fieldValues = [:]
        preview = nil
        previewError = nil
        dirty = false
    }

    private func clearDraft() {
        selectedID = nil
        draftTitle = ""
        draftKeyword = ""
        draftBody = ""
        fieldValues = [:]
        preview = nil
        previewError = nil
        dirty = false
    }

    private func validatedTitle(_ title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            error = SnippetError.emptyTitle.errorDescription
            return nil
        }
        guard trimmed.count <= SnippetTemplate.maxTitleLength else {
            error = SnippetError.titleTooLong.errorDescription
            return nil
        }
        return trimmed
    }

    private func validatedKeyword(_ keyword: String, excluding id: UUID?) -> String? {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= SnippetTemplate.maxKeywordLength else {
            error = SnippetError.keywordTooLong.errorDescription
            return nil
        }
        guard !trimmed.isEmpty else { return "" }
        let normalized = trimmed.lowercased()
        let clash = snippets.contains { snippet in
            snippet.id != id && snippet.keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
        }
        guard !clash else {
            error = SnippetError.duplicateKeyword.errorDescription
            return nil
        }
        return trimmed
    }

    private func schedule() {
        dirty = true
        autosave?.cancel()
        autosave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard !Task.isCancelled else { return }
            _ = self?.flush()
        }
    }

    private func save(_ updated: [Snippet]) -> Bool {
        guard validate(updated) else { return false }
        do {
            try store.save(updated)
            snippets = updated
            error = nil
            return true
        } catch let failure {
            error = failure.localizedDescription
            return false
        }
    }

    /// The same rules the loader and the backup use, so nothing invalid can
    /// ever reach the file. A library that would come back damaged is refused
    /// here instead: the draft stays dirty and the caller keeps the block.
    private func validate(_ records: [Snippet]) -> Bool {
        do {
            try LibraryBackupValidation.snippets(records)
            return true
        } catch let failure as LibraryBackupError {
            error = SnippetsModel.message(for: failure)
            return false
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// The wording the user already knows, kept next to the shared rules.
    private static func message(for failure: LibraryBackupError) -> String? {
        guard case .recordInvalid(let violation) = failure else { return failure.localizedDescription }
        switch violation {
        case .tooManyRecords: return SnippetError.tooManySnippets.errorDescription
        case .duplicateIdentifier: return SnippetError.duplicateIdentifier.errorDescription
        case .storageFull: return SnippetError.storageFull.errorDescription
        case .emptyTitle: return SnippetError.emptyTitle.errorDescription
        case .titleTooLong: return SnippetError.titleTooLong.errorDescription
        case .keywordTooLong: return SnippetError.keywordTooLong.errorDescription
        case .bodyTooLarge: return SnippetError.bodyTooLarge.errorDescription
        case .duplicateKeyword: return SnippetError.duplicateKeyword.errorDescription
        case .invalidDate: return SnippetError.invalidDate.errorDescription
        default: return failure.localizedDescription
        }
    }

    // MARK: - Library backups

    var libraryBackupKind: LibraryBackupKind { .snippets }
    var libraryBackupRecords: [LibraryBackupRecord] { snippets.map { .snippet($0) } }
    /// A draft that is not saved yet blocks every transfer.
    var libraryBackupIsDirty: Bool { dirty }
    var libraryBackupNeedsRecovery: Bool { store.damaged }
    /// The message of the last failed save, if there is one.
    var libraryBackupError: String? { error }
    var libraryBackupChanges: AnyPublisher<Void, Never> {
        objectWillChange.eraseToAnyPublisher()
    }

    /// The bytes of the library as it is saved right now.
    func libraryBackupPayload() throws -> Data { try LibraryBackupCodec.encodeSnippets(snippets) }

    /// Adds the imported snippets with one save. Nothing that is already here
    /// is changed, and a failed save keeps the array, the file and the draft.
    @discardableResult
    func libraryBackupApply(_ additions: [LibraryBackupRecord]) -> Bool {
        guard !store.damaged else {
            error = "Snippets need backup and reset / 片段需先備份並重設"
            return false
        }
        guard !dirty else {
            error = "Please save the draft first / 請先儲存目前的草稿"
            return false
        }
        var incoming: [Snippet] = []
        for record in additions {
            guard case .snippet(let snippet) = record else {
                error = "This is not a snippets backup / 這不是片段備份"
                return false
            }
            incoming.append(snippet)
        }
        guard save(snippets + incoming) else { return false }
        if selectedID == nil, let first = incoming.first { selectDraft(first) }
        return true
    }
}
