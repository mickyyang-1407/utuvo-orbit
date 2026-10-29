import AppKit
import Combine
import Foundation

/// A saved web link. The template is an absolute http/https URL that may contain
/// the single supported placeholder `{query}`.
struct QuickLink: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var title: String
    var template: String
    var pinned = false
}

enum QuickLinkError: LocalizedError, Equatable {
    case emptyTitle
    case titleTooLong
    case templateTooLong
    case tooManyLinks
    case controlCharacters
    case unsupportedScheme
    case missingHost
    case invalidHost
    case userInfoNotAllowed
    case unsupportedPlaceholder
    case unclosedPlaceholder
    case placeholderNotAllowed
    case emptyQuery
    case unexpectedQuery
    case queryTooLong
    case urlTooLong
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .emptyTitle: "Give the link a title / 請替連結取個名稱"
        case .titleTooLong: "Title is limited to 120 characters / 標題上限 120 字"
        case .templateTooLong: "Template is limited to 2048 characters / 網址範本上限 2048 字"
        case .tooManyLinks: "Up to 50 quick links / 最多 50 個快捷連結"
        case .controlCharacters: "The URL contains control characters / 網址含有控制字元"
        case .unsupportedScheme: "Only absolute http or https URLs are allowed / 只允許絕對的 http 或 https 網址"
        case .missingHost: "The URL needs a host name / 網址需要主機名稱"
        case .invalidHost: "The host name is not valid / 主機名稱不合法"
        case .userInfoNotAllowed: "A user name or password is not allowed / 不允許在網址中包含帳號或密碼"
        case .unsupportedPlaceholder: "Only {query} is supported / 只支援 {query} 佔位符"
        case .unclosedPlaceholder: "The placeholder is not closed / 佔位符沒有閉合"
        case .placeholderNotAllowed: "{query} is only allowed in the path or query part / {query} 只能出現在路徑或查詢字串"
        case .emptyQuery: "Enter a search term first / 請先輸入搜尋字詞"
        case .unexpectedQuery: "This link does not take a search term / 這個連結不需要搜尋字詞"
        case .queryTooLong: "The search term is limited to 2048 characters / 搜尋字詞上限 2048 字"
        case .urlTooLong: "The final URL is too long / 產生的網址太長"
        case .invalidURL: "The URL could not be read / 無法解析這個網址"
        }
    }
}

/// Validation and building for quick-link templates.
///
/// Rules: absolute http/https only, a fixed non-empty host, no user info, no
/// control characters, and the only supported placeholder is `{query}`, which may
/// appear in the path or the query part but never in the scheme, the authority
/// or the fragment. The user's search term is percent-encoded exactly once with
/// an unreserved-only character set, so `+`, `&`, `#`, `/`, `%` and non-ASCII
/// text can never turn into URL separators.
enum QuickLinkTemplate {
    static let queryToken = "{query}"
    static let maxLinks = 50
    static let maxTitleLength = 120
    static let maxTemplateLength = 2048
    static let maxQueryLength = 2048
    static let maxURLBytes = 8192

    /// A safe, alphanumeric stand-in used while the template is inspected.
    private static let sentinel = "orbitqueryplaceholder"

    /// What a validated template supports.
    struct Layout: Equatable {
        var hasQuery: Bool
    }

    // MARK: - Validation

    static func validate(_ template: String) throws -> Layout {
        guard template.count <= maxTemplateLength else { throw QuickLinkError.templateTooLong }
        guard !containsControlCharacter(template) else { throw QuickLinkError.controlCharacters }

        let placeholders = try scan(template)
        for placeholder in placeholders where placeholder.content != "query" {
            throw QuickLinkError.unsupportedPlaceholder
        }

        let regions = classify(template)
        for placeholder in placeholders {
            let region = regions.region(at: placeholder.offset)
            guard region == .path || region == .query else { throw QuickLinkError.placeholderNotAllowed }
        }

        let probe = template.replacingOccurrences(of: queryToken, with: sentinel)
        let scheme = try schemeOf(template).lowercased()
        guard scheme == "http" || scheme == "https" else { throw QuickLinkError.unsupportedScheme }

        guard let components = URLComponents(string: probe) else { throw QuickLinkError.invalidURL }
        guard components.user == nil, components.password == nil else { throw QuickLinkError.userInfoNotAllowed }
        // A placeholder in the authority is already refused above, so a host
        // that merely contains the probe text is a normal host.
        guard let host = components.host, !host.isEmpty else { throw QuickLinkError.missingHost }
        guard isValidHost(host) else { throw QuickLinkError.invalidHost }

        return Layout(hasQuery: !placeholders.isEmpty)
    }

    static func requiresQuery(_ template: String) -> Bool {
        template.contains(queryToken)
    }

    // MARK: - Building

    /// Builds the final URL. A template without a placeholder opens directly;
    /// a template with `{query}` needs a non-empty search term.
    static func build(template: String, query: String?) throws -> URL {
        let layout = try validate(template)
        var filled = template
        if layout.hasQuery {
            let raw = query ?? ""
            guard !raw.isEmpty else { throw QuickLinkError.emptyQuery }
            guard raw.count <= maxQueryLength else { throw QuickLinkError.queryTooLong }
            filled = template.replacingOccurrences(of: queryToken, with: percentEncode(raw))
        } else if let query, !query.isEmpty {
            throw QuickLinkError.unexpectedQuery
        }
        guard filled.utf8.count <= maxURLBytes else { throw QuickLinkError.urlTooLong }
        guard let url = URL(string: filled), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else {
            throw QuickLinkError.invalidURL
        }
        return url
    }

    /// Percent-encodes with the unreserved character set only
    /// (ALPHA / DIGIT / "-" / "." / "_" / "~"), exactly once.
    static func percentEncode(_ value: String) -> String {
        var output = ""
        output.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E:
                output.append(Character(UnicodeScalar(byte)))
            default:
                output += String(format: "%%%02X", Int(byte))
            }
        }
        return output
    }

    // MARK: - Internals

    private struct Placeholder {
        /// UTF-16 offset of the placeholder, so it can be compared with the
        /// region boundaries computed on the same scale.
        var offset: Int
        var content: String
    }

    private enum Region {
        case scheme, authority, path, query, fragment
    }

    private static func scan(_ template: String) throws -> [Placeholder] {
        var found: [Placeholder] = []
        var index = template.startIndex
        let utf16 = template.utf16
        while index < template.endIndex {
            guard template[index] == "{" else {
                index = template.index(after: index)
                continue
            }
            guard let close = template.range(of: "}", range: template.index(after: index)..<template.endIndex) else {
                throw QuickLinkError.unclosedPlaceholder
            }
            let content = String(template[template.index(after: index)..<close.lowerBound])
            let start = index.samePosition(in: utf16).map { utf16.distance(from: utf16.startIndex, to: $0) } ?? 0
            found.append(Placeholder(offset: start, content: content))
            index = close.upperBound
        }
        return found
    }

    private struct Regions {
        var schemeEnd = -1
        var authorityStart = -1
        var authorityEnd = -1
        var queryStart = -1
        var fragmentStart = -1

        func region(at offset: Int) -> Region {
            if fragmentStart >= 0, offset >= fragmentStart { return .fragment }
            if queryStart >= 0, offset >= queryStart { return .query }
            if schemeEnd >= 0, offset < schemeEnd { return .scheme }
            if authorityStart >= 0, offset < authorityEnd { return .authority }
            return .path
        }
    }

    private static func classify(_ template: String) -> Regions {
        // UTF-16 units keep the boundaries on the same scale as the placeholder offsets.
        let units = Array(template.utf16)
        let hash: UInt16 = 0x23, question: UInt16 = 0x3F, slash: UInt16 = 0x2F, colon: UInt16 = 0x3A
        var regions = Regions()
        if let index = units.firstIndex(of: hash) { regions.fragmentStart = index }
        if let index = units.firstIndex(of: question) {
            regions.queryStart = regions.fragmentStart >= 0 ? min(index, regions.fragmentStart) : index
        }
        if units.count >= 3 {
            for index in 0...(units.count - 3) where units[index] == colon && units[index + 1] == slash && units[index + 2] == slash {
                regions.schemeEnd = index
                regions.authorityStart = index + 3
                break
            }
        }
        if regions.authorityStart >= 0 {
            var end = units.count
            for index in regions.authorityStart..<units.count {
                if units[index] == slash || units[index] == question || units[index] == hash {
                    end = index
                    break
                }
            }
            regions.authorityEnd = end
        }
        return regions
    }

    private static func schemeOf(_ template: String) throws -> String {
        let units = Array(template.utf16)
        let slash: UInt16 = 0x2F, colon: UInt16 = 0x3A
        guard units.count >= 3 else { throw QuickLinkError.unsupportedScheme }
        for index in 0...(units.count - 3) where units[index] == colon && units[index + 1] == slash && units[index + 2] == slash {
            return String(decoding: units[0..<index], as: UTF16.self)
        }
        throw QuickLinkError.unsupportedScheme
    }

    private static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty else { return false }
        for character in host {
            guard character.isASCII else { return false }
            guard character.isLetter || character.isNumber || character == "-" || character == "." ||
                    character == ":" || character == "[" || character == "]" else { return false }
        }
        return true
    }

    private static func containsControlCharacter(_ text: String) -> Bool {
        for scalar in text.unicodeScalars where scalar.value < 0x20 || scalar.value == 0x7F {
            return true
        }
        return false
    }
}

// MARK: - Opening

/// Links are only ever opened from an explicit user action. The opener is
/// injected so preview and tests never reach NSWorkspace.
@MainActor
protocol QuickLinkOpening: AnyObject {
    func open(_ url: URL)
}

@MainActor
final class SystemQuickLinkOpener: QuickLinkOpening {
    func open(_ url: URL) { NSWorkspace.shared.open(url) }
}

/// Preview and test fake: records the URLs instead of launching a browser.
@MainActor
final class PreviewQuickLinkOpener: QuickLinkOpening {
    private(set) var opened: [URL] = []
    func open(_ url: URL) { opened.append(url) }
}

// MARK: - Model

@MainActor
final class QuickLinksModel: ObservableObject {
    @Published private(set) var links: [QuickLink] = []
    @Published var query = ""
    @Published private(set) var error: String?
    /// A template link waiting for its search term.
    @Published var pendingLinkID: UUID?
    @Published var pendingQuery = ""

    private let store: ToolStorage<[QuickLink]>
    private let opener: any QuickLinkOpening

    init(root: URL? = nil, preview: Bool = false, opener: (any QuickLinkOpening)? = nil) {
        let url: URL? = preview ? nil : (root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UTUVO Orbit/Quicklinks", isDirectory: true)).appendingPathComponent("quicklinks.json")
        store = ToolStorage(nil, "quicklinks", fileURL: url)
        self.opener = opener ?? (preview ? PreviewQuickLinkOpener() : SystemQuickLinkOpener())
        links = store.load(fallback: [], validate: { values in
            (try? LibraryBackupValidation.quickLinks(values)) != nil
        })
    }

    var needsRecovery: Bool { store.damaged }

    var visible: [QuickLink] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return links.filter { term.isEmpty || $0.title.localizedCaseInsensitiveContains(term) || $0.template.localizedCaseInsensitiveContains(term) }
            .sorted { $0.pinned != $1.pinned ? $0.pinned : $0.title.localizedCompare($1.title) == .orderedAscending }
    }

    var pendingLink: QuickLink? {
        guard let pendingLinkID else { return nil }
        return links.first { $0.id == pendingLinkID }
    }

    func link(_ id: UUID) -> QuickLink? { links.first { $0.id == id } }

    // MARK: Editing

    @discardableResult
    func add(title: String, template: String) -> Bool {
        guard !store.damaged else {
            error = "Quick links need backup and reset / 快捷連結需先備份並重設"
            return false
        }
        guard let title = validatedTitle(title) else { return false }
        guard template.count <= QuickLinkTemplate.maxTemplateLength else {
            error = QuickLinkError.templateTooLong.errorDescription
            return false
        }
        do { _ = try QuickLinkTemplate.validate(template) }
        catch let failure { error = failure.localizedDescription; return false }
        guard links.count < QuickLinkTemplate.maxLinks else {
            error = QuickLinkError.tooManyLinks.errorDescription
            return false
        }
        return persist(links + [QuickLink(title: title, template: template)])
    }

    @discardableResult
    func update(_ id: UUID, title: String, template: String) -> Bool {
        guard !store.damaged else {
            error = "Quick links need backup and reset / 快捷連結需先備份並重設"
            return false
        }
        guard let index = links.firstIndex(where: { $0.id == id }) else { return false }
        guard let title = validatedTitle(title) else { return false }
        guard template.count <= QuickLinkTemplate.maxTemplateLength else {
            error = QuickLinkError.templateTooLong.errorDescription
            return false
        }
        do { _ = try QuickLinkTemplate.validate(template) }
        catch let failure { error = failure.localizedDescription; return false }
        var updated = links
        updated[index].title = title
        updated[index].template = template
        return persist(updated)
    }

    @discardableResult
    func remove(_ id: UUID) -> Bool {
        guard let index = links.firstIndex(where: { $0.id == id }) else { return false }
        var updated = links
        updated.remove(at: index)
        if pendingLinkID == id { pendingLinkID = nil; pendingQuery = "" }
        return persist(updated)
    }

    @discardableResult
    func togglePin(_ id: UUID) -> Bool {
        guard let index = links.firstIndex(where: { $0.id == id }) else { return false }
        var updated = links
        updated[index].pinned.toggle()
        return persist(updated)
    }

    func recover() {
        do {
            try store.backupAndReset([])
            links = []
            pendingLinkID = nil
            pendingQuery = ""
            error = nil
        } catch let failure {
            error = failure.localizedDescription
        }
    }

    // MARK: - Library backups

    var libraryBackupKind: LibraryBackupKind { .quicklinks }
    var libraryBackupRecords: [LibraryBackupRecord] { links.map { .quickLink($0) } }
    /// Quick links have no draft, so there is nothing unsaved to block a
    /// transfer.
    var libraryBackupIsDirty: Bool { false }
    var libraryBackupNeedsRecovery: Bool { store.damaged }
    /// The message of the last failed save, if there is one.
    var libraryBackupError: String? { error }
    var libraryBackupChanges: AnyPublisher<Void, Never> { objectWillChange.eraseToAnyPublisher() }

    /// The bytes of the library as it is saved right now.
    func libraryBackupPayload() throws -> Data { try LibraryBackupCodec.encodeQuickLinks(links) }

    /// Adds the imported links with one save. Nothing that is already here is
    /// changed, and a failed save keeps the array, the file and the selection.
    @discardableResult
    func libraryBackupApply(_ additions: [LibraryBackupRecord]) -> Bool {
        guard !store.damaged else {
            error = "Quick links need backup and reset / 快捷連結需先備份並重設"
            return false
        }
        var incoming: [QuickLink] = []
        for record in additions {
            guard case .quickLink(let link) = record else {
                error = "This is not a quick links backup / 這不是快捷連結備份"
                return false
            }
            incoming.append(link)
        }
        let merged = links + incoming
        do {
            try LibraryBackupValidation.quickLinks(merged)
        } catch {
            self.error = "The merged data would be too large / 合併後的資料會超過上限"
            return false
        }
        return persist(merged)
    }

    // MARK: Opening

    /// Opens a fixed link straight away. A template link asks for its search
    /// term first, so nothing navigates before the user confirmed the value.
    @discardableResult
    func requestOpen(_ id: UUID) -> Bool {
        guard let link = link(id) else { return false }
        do {
            let layout = try QuickLinkTemplate.validate(link.template)
            if layout.hasQuery {
                pendingLinkID = id
                pendingQuery = ""
                error = nil
                return true
            }
            pendingLinkID = nil
            let url = try QuickLinkTemplate.build(template: link.template, query: nil)
            opener.open(url)
            error = nil
            return true
        } catch let failure {
            error = failure.localizedDescription
            return false
        }
    }

    /// Builds and opens the pending template link. An empty search term is an
    /// error, never a navigation.
    @discardableResult
    func confirmPendingOpen() -> Bool {
        guard let id = pendingLinkID, let link = link(id) else { return false }
        do {
            let url = try QuickLinkTemplate.build(template: link.template, query: pendingQuery)
            opener.open(url)
            pendingLinkID = nil
            pendingQuery = ""
            error = nil
            return true
        } catch let failure {
            error = failure.localizedDescription
            return false
        }
    }

    func cancelPendingOpen() {
        pendingLinkID = nil
        pendingQuery = ""
    }

    // MARK: Internals

    private func validatedTitle(_ title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            error = QuickLinkError.emptyTitle.errorDescription
            return nil
        }
        guard trimmed.count <= QuickLinkTemplate.maxTitleLength else {
            error = QuickLinkError.titleTooLong.errorDescription
            return nil
        }
        return trimmed
    }

    private func persist(_ updated: [QuickLink]) -> Bool {
        do {
            try store.save(updated)
            links = updated
            error = nil
            return true
        } catch let failure {
            error = failure.localizedDescription
            return false
        }
    }
}
