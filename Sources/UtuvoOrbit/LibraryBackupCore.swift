import Darwin
import Foundation

// MARK: - Format

/// The libraries Orbit can back up. The raw values are part of the public
/// file format, so they never change.
enum LibraryBackupKind: String, CaseIterable, Codable, Sendable {
    case notes
    case snippets
    case quicklinks
}

/// The published backup format: one UTF-8 JSON file per library.
///
///     {"format":"utuvo.orbit.library","version":1,"kind":"notes","records":[…]}
///
/// Dates use the JSONEncoder default (seconds since 2001 as a number), so a
/// record survives the round trip exactly instead of being cut to a date.
enum LibraryBackupFormat {
    static let identifier = "utuvo.orbit.library"
    static let version = 1
    /// An encoded file may not be larger than this, in either direction.
    static let maxEncodedBytes = 16 * 1024 * 1024
    /// A document nested deeper than this is refused before it is decoded.
    static let maxJSONDepth = 32
}

/// Why a record was refused. The models map these onto their own messages so
/// the wording stays the one the user already knows.
enum LibraryBackupViolation: Equatable, Sendable {
    case tooManyRecords
    case duplicateIdentifier
    case storageFull
    case emptyTitle
    case titleTooLong
    case keywordTooLong
    case bodyTooLarge
    case templateTooLong
    case duplicateKeyword
    case invalidDate
    case invalidTemplate
    case mismatchedRecord
}

enum LibraryBackupError: LocalizedError, Equatable {
    case notABackupFile
    case unsupportedVersion(Int)
    case wrongKind(expected: LibraryBackupKind)
    case tooLarge
    case tooDeep
    case malformed
    case duplicateIdentifier
    case conflictingRecord
    case duplicateKeyword
    case limitExceeded
    case recordInvalid(LibraryBackupViolation)
    case notRegularFile
    case changedWhileReading
    case writeFailed
    case stalePreview
    case dirtyLibrary
    case damagedLibrary

    var errorDescription: String? {
        switch self {
        case .notABackupFile:
            "This is not an Orbit library backup / 這不是 Orbit 資料備份檔"
        case .unsupportedVersion:
            "This backup uses another format version / 這個備份使用了其他格式版本"
        case .wrongKind:
            "This backup holds a different library / 這個備份是另一份資料"
        case .tooLarge:
            "The backup file is larger than 16 MiB / 備份檔超過 16 MiB"
        case .tooDeep:
            "The backup file is nested too deeply / 備份檔巢狀層級過深"
        case .malformed:
            "The backup file could not be read / 無法讀取這個備份檔"
        case .duplicateIdentifier:
            "The backup repeats a record ID / 備份檔中有重複的記錄 ID"
        case .conflictingRecord:
            "A record differs from the same ID on this Mac / 有記錄與本機相同 ID 的內容不同"
        case .duplicateKeyword:
            "A snippet keyword is already used on this Mac / 這個片段關鍵字在本機已經有人用了"
        case .limitExceeded:
            "The merged data would be too large / 合併後的資料會超過上限"
        case .recordInvalid(let violation):
            LibraryBackupError.message(for: violation)
        case .notRegularFile:
            "Choose a regular backup file / 請選擇一般的備份檔"
        case .changedWhileReading:
            "The backup file changed while it was read / 備份檔在讀取時被更動"
        case .writeFailed:
            "The backup could not be written / 無法寫出這個備份"
        case .stalePreview:
            "The data changed after the preview / 預覽後資料已經變更，請重新預覽"
        case .dirtyLibrary:
            "Save your changes first / 請先儲存目前的變更"
        case .damagedLibrary:
            "This data needs backup and reset first / 這份資料需先備份並重設"
        }
    }

    static func message(for violation: LibraryBackupViolation) -> String {
        switch violation {
        case .tooManyRecords:
            "The data holds too many records / 這份資料的記錄太多"
        case .duplicateIdentifier:
            "The data repeats a record ID / 這份資料有重複的記錄 ID"
        case .storageFull:
            "The data storage is full / 資料儲存空間已滿"
        case .emptyTitle:
            "A record has no title / 有記錄沒有標題"
        case .titleTooLong:
            "A title is too long / 有標題太長"
        case .keywordTooLong:
            "A keyword is too long / 有關鍵字太長"
        case .bodyTooLarge:
            "A body is too large / 有內容太大"
        case .templateTooLong:
            "A URL template is too long / 有網址範本太長"
        case .duplicateKeyword:
            "A keyword is used twice / 有關鍵字重複"
        case .invalidDate:
            "A date is not a finite value / 有日期不是有限值"
        case .invalidTemplate:
            "A URL template is not a fixed http(s) address / 有網址範本不是固定的 http(s) 網址"
        case .mismatchedRecord:
            "The backup holds another kind of record / 備份檔含有另一種記錄"
        }
    }
}

// MARK: - Records

/// A record of one library, kept in its own type until it is written back.
/// The record types stay in the files that already own them.
enum LibraryBackupRecord: Equatable, Sendable {
    case note(QuickNote)
    case snippet(Snippet)
    case quickLink(QuickLink)

    var id: UUID {
        switch self {
        case .note(let value): value.id
        case .snippet(let value): value.id
        case .quickLink(let value): value.id
        }
    }

    var kind: LibraryBackupKind {
        switch self {
        case .note: .notes
        case .snippet: .snippets
        case .quickLink: .quicklinks
        }
    }

    /// Two records are the same when their bytes are the same.
    ///
    /// Swift compares strings by canonical equivalence, so "é" and "e" plus a
    /// combining accent are the same string even though their UTF-8 bytes
    /// differ. A backup must not treat two such records as one, so the text
    /// is compared byte by byte here. The record types themselves stay as
    /// they are.
    static func == (lhs: LibraryBackupRecord, rhs: LibraryBackupRecord) -> Bool {
        switch (lhs, rhs) {
        case (.note(let left), .note(let right)):
            return left.id == right.id && left.pinned == right.pinned
                && left.modified == right.modified && left.deleted == right.deleted
                && sameBytes(left.title, right.title) && sameBytes(left.body, right.body)
        case (.snippet(let left), .snippet(let right)):
            return left.id == right.id && left.pinned == right.pinned
                && left.modified == right.modified
                && sameBytes(left.title, right.title)
                && sameBytes(left.keyword, right.keyword)
                && sameBytes(left.body, right.body)
        case (.quickLink(let left), .quickLink(let right)):
            return left.id == right.id && left.pinned == right.pinned
                && sameBytes(left.title, right.title) && sameBytes(left.template, right.template)
        default:
            return false
        }
    }

    /// Compares the UTF-8 bytes, so two texts that only look the same are not
    /// the same record.
    static func sameBytes(_ left: String, _ right: String) -> Bool {
        left.utf8.elementsEqual(right.utf8)
    }
}

// MARK: - Validation

/// The one strict rule set for a whole library.
///
/// The same rules run when a library is loaded, when it is saved and when it
/// comes back from a backup, so an import can never persist a library that
/// would come back damaged.
enum LibraryBackupValidation {
    /// Notes: an empty title is valid, the trash is part of the library.
    static func notes(_ records: [QuickNote]) throws {
        guard records.count <= 100 else { throw LibraryBackupError.recordInvalid(.tooManyRecords) }
        guard Set(records.map(\.id)).count == records.count else {
            throw LibraryBackupError.recordInvalid(.duplicateIdentifier)
        }
        guard records.reduce(0, { $0 + $1.body.utf8.count }) <= 2_000_000 else {
            throw LibraryBackupError.recordInvalid(.storageFull)
        }
        for record in records {
            guard record.title.count <= 120 else { throw LibraryBackupError.recordInvalid(.titleTooLong) }
            guard record.body.utf8.count <= 65_536 else { throw LibraryBackupError.recordInvalid(.bodyTooLarge) }
            guard record.modified.timeIntervalSince1970.isFinite else {
                throw LibraryBackupError.recordInvalid(.invalidDate)
            }
            if let deleted = record.deleted {
                guard deleted.timeIntervalSince1970.isFinite else {
                    throw LibraryBackupError.recordInvalid(.invalidDate)
                }
            }
        }
    }

    /// Snippets: the body is editing content, so an unfinished template is
    /// valid and is never refused for its template syntax.
    static func snippets(_ records: [Snippet]) throws {
        guard records.count <= SnippetTemplate.maxSnippets else {
            throw LibraryBackupError.recordInvalid(.tooManyRecords)
        }
        guard Set(records.map(\.id)).count == records.count else {
            throw LibraryBackupError.recordInvalid(.duplicateIdentifier)
        }
        guard records.reduce(0, { $0 + $1.body.utf8.count }) <= SnippetTemplate.maxTotalBytes else {
            throw LibraryBackupError.recordInvalid(.storageFull)
        }
        var keywords: Set<String> = []
        for record in records {
            let title = record.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw LibraryBackupError.recordInvalid(.emptyTitle) }
            guard record.title.count <= SnippetTemplate.maxTitleLength else {
                throw LibraryBackupError.recordInvalid(.titleTooLong)
            }
            guard record.keyword.count <= SnippetTemplate.maxKeywordLength else {
                throw LibraryBackupError.recordInvalid(.keywordTooLong)
            }
            guard record.body.utf8.count <= SnippetTemplate.maxBodyBytes else {
                throw LibraryBackupError.recordInvalid(.bodyTooLarge)
            }
            guard record.modified.timeIntervalSince1970.isFinite else {
                throw LibraryBackupError.recordInvalid(.invalidDate)
            }
            let keyword = record.keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !keyword.isEmpty {
                guard !keywords.contains(keyword) else {
                    throw LibraryBackupError.recordInvalid(.duplicateKeyword)
                }
                keywords.insert(keyword)
            }
        }
    }

    /// Quick links: a fixed http(s) template with a usable title.
    static func quickLinks(_ records: [QuickLink]) throws {
        guard records.count <= QuickLinkTemplate.maxLinks else {
            throw LibraryBackupError.recordInvalid(.tooManyRecords)
        }
        guard Set(records.map(\.id)).count == records.count else {
            throw LibraryBackupError.recordInvalid(.duplicateIdentifier)
        }
        for record in records {
            let title = record.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw LibraryBackupError.recordInvalid(.emptyTitle) }
            guard record.title.count <= QuickLinkTemplate.maxTitleLength else {
                throw LibraryBackupError.recordInvalid(.titleTooLong)
            }
            guard record.template.count <= QuickLinkTemplate.maxTemplateLength else {
                throw LibraryBackupError.recordInvalid(.templateTooLong)
            }
            guard (try? QuickLinkTemplate.validate(record.template)) != nil else {
                throw LibraryBackupError.recordInvalid(.invalidTemplate)
            }
        }
    }

    /// Validates a whole library of one kind.
    static func validate(kind: LibraryBackupKind, records: [LibraryBackupRecord]) throws {
        switch kind {
        case .notes:
            try notes(try only(records, kind: .notes) { record -> QuickNote? in
                if case .note(let value) = record { return value }
                return nil
            })
        case .snippets:
            try snippets(try only(records, kind: .snippets) { record -> Snippet? in
                if case .snippet(let value) = record { return value }
                return nil
            })
        case .quicklinks:
            try quickLinks(try only(records, kind: .quicklinks) { record -> QuickLink? in
                if case .quickLink(let value) = record { return value }
                return nil
            })
        }
    }

    /// Keeps the records of one kind and refuses the rest.
    static func only<Record>(_ records: [LibraryBackupRecord], kind: LibraryBackupKind,
                             _ value: (LibraryBackupRecord) -> Record?) throws -> [Record] {
        var kept: [Record] = []
        kept.reserveCapacity(records.count)
        for record in records {
            guard record.kind == kind else { throw LibraryBackupError.recordInvalid(.mismatchedRecord) }
            guard let unwrapped = value(record) else { throw LibraryBackupError.recordInvalid(.mismatchedRecord) }
            kept.append(unwrapped)
        }
        return kept
    }
}

// MARK: - Codec

/// The file envelope. The kind is kept as a string so a backup of another
/// library is refused with a clear reason instead of a decoding failure.
struct LibraryBackupEnvelope<Record: Codable>: Codable {
    var format: String
    var version: Int
    var kind: String
    var records: [Record]
}

/// Reads and writes the public backup format.
enum LibraryBackupCodec {
    // MARK: Typed

    static func encodeNotes(_ records: [QuickNote]) throws -> Data {
        try encodeEnvelope(kind: .notes, records: records)
    }

    static func decodeNotes(_ data: Data) throws -> [QuickNote] {
        let records: [QuickNote] = try decodeEnvelope(kind: .notes, data: data)
        try LibraryBackupValidation.notes(records)
        return records
    }

    static func encodeSnippets(_ records: [Snippet]) throws -> Data {
        try encodeEnvelope(kind: .snippets, records: records)
    }

    static func decodeSnippets(_ data: Data) throws -> [Snippet] {
        let records: [Snippet] = try decodeEnvelope(kind: .snippets, data: data)
        try LibraryBackupValidation.snippets(records)
        return records
    }

    static func encodeQuickLinks(_ records: [QuickLink]) throws -> Data {
        try encodeEnvelope(kind: .quicklinks, records: records)
    }

    static func decodeQuickLinks(_ data: Data) throws -> [QuickLink] {
        let records: [QuickLink] = try decodeEnvelope(kind: .quicklinks, data: data)
        try LibraryBackupValidation.quickLinks(records)
        return records
    }

    // MARK: One library at a time

    static func encode(kind: LibraryBackupKind, records: [LibraryBackupRecord]) throws -> Data {
        switch kind {
        case .notes:
            return try encodeNotes(try LibraryBackupValidation.only(records, kind: .notes) { record -> QuickNote? in
                if case .note(let value) = record { return value }
                return nil
            })
        case .snippets:
            return try encodeSnippets(try LibraryBackupValidation.only(records, kind: .snippets) { record -> Snippet? in
                if case .snippet(let value) = record { return value }
                return nil
            })
        case .quicklinks:
            return try encodeQuickLinks(try LibraryBackupValidation.only(records, kind: .quicklinks) { record -> QuickLink? in
                if case .quickLink(let value) = record { return value }
                return nil
            })
        }
    }

    static func decode(kind: LibraryBackupKind, data: Data) throws -> [LibraryBackupRecord] {
        switch kind {
        case .notes: return try decodeNotes(data).map { .note($0) }
        case .snippets: return try decodeSnippets(data).map { .snippet($0) }
        case .quicklinks: return try decodeQuickLinks(data).map { .quickLink($0) }
        }
    }

    // MARK: Internals

    private static func encodeEnvelope<Record: Codable>(kind: LibraryBackupKind, records: [Record]) throws -> Data {
        let envelope = LibraryBackupEnvelope(format: LibraryBackupFormat.identifier,
                                             version: LibraryBackupFormat.version,
                                             kind: kind.rawValue,
                                             records: records)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        guard data.count <= LibraryBackupFormat.maxEncodedBytes else { throw LibraryBackupError.tooLarge }
        return data
    }

    private static func decodeEnvelope<Record: Codable>(kind: LibraryBackupKind, data: Data) throws -> [Record] {
        guard data.count <= LibraryBackupFormat.maxEncodedBytes else { throw LibraryBackupError.tooLarge }
        try LibraryBackupJSON.checkDepth(data)
        let decoded: LibraryBackupEnvelope<Record>
        do {
            decoded = try JSONDecoder().decode(LibraryBackupEnvelope<Record>.self, from: data)
        } catch {
            throw LibraryBackupError.malformed
        }
        guard decoded.format == LibraryBackupFormat.identifier else { throw LibraryBackupError.notABackupFile }
        guard decoded.version == LibraryBackupFormat.version else {
            throw LibraryBackupError.unsupportedVersion(decoded.version)
        }
        guard decoded.kind == kind.rawValue else { throw LibraryBackupError.wrongKind(expected: kind) }
        return decoded.records
    }
}

/// Checks the shape of a document before the decoder touches it.
enum LibraryBackupJSON {
    /// Refuses a pathologically nested document. Braces and brackets inside a
    /// quoted string do not count, and an escaped quote does not end it.
    static func checkDepth(_ data: Data) throws {
        var depth = 0
        var inString = false
        var escaped = false
        for byte in data {
            if inString {
                if escaped { escaped = false }
                else if byte == 0x5C { escaped = true }
                else if byte == 0x22 { inString = false }
                continue
            }
            switch byte {
            case 0x22:
                inString = true
            case 0x7B, 0x5B:
                depth += 1
                if depth > LibraryBackupFormat.maxJSONDepth { throw LibraryBackupError.tooDeep }
            case 0x7D, 0x5D:
                depth -= 1
            default:
                break
            }
        }
    }
}

// MARK: - Merging

/// What an import would do. Nothing is written until the plan is applied.
struct LibraryBackupPlan: Equatable {
    let kind: LibraryBackupKind
    /// The records that would be added.
    let additions: [LibraryBackupRecord]
    /// The records that are already on this Mac, unchanged.
    let identicalCount: Int

    var incomingCount: Int { additions.count + identicalCount }
    var isEmpty: Bool { additions.isEmpty }
}

/// Plans a merge. Nothing is written and nothing is thrown away silently.
enum LibraryBackupPlanner {
    /// Validates the whole incoming library, then plans the merge into the
    /// records that are saved right now.
    ///
    /// The same ID with the same complete record is skipped. The same ID with
    /// another content is refused, because an import never overwrites. A
    /// snippet keyword that another record already uses is refused as well.
    static func plan(kind: LibraryBackupKind, current: [LibraryBackupRecord],
                     incoming: [LibraryBackupRecord]) throws -> LibraryBackupPlan {
        try LibraryBackupValidation.validate(kind: kind, records: incoming)
        var currentByID: [UUID: LibraryBackupRecord] = [:]
        for record in current { currentByID[record.id] = record }

        var additions: [LibraryBackupRecord] = []
        var identical = 0
        for record in incoming {
            if let existing = currentByID[record.id] {
                guard existing == record else { throw LibraryBackupError.conflictingRecord }
                identical += 1
            } else {
                additions.append(record)
            }
        }

        try checkKeywordConflicts(kind: kind, current: current, incoming: incoming)

        let merged = current + additions
        do {
            try LibraryBackupValidation.validate(kind: kind, records: merged)
        } catch {
            throw LibraryBackupError.limitExceeded
        }
        return LibraryBackupPlan(kind: kind, additions: additions, identicalCount: identical)
    }

    /// A snippet keyword may only be used by one record. The incoming record
    /// may keep a keyword that belongs to the very same record.
    private static func checkKeywordConflicts(kind: LibraryBackupKind, current: [LibraryBackupRecord],
                                              incoming: [LibraryBackupRecord]) throws {
        guard kind == .snippets else { return }
        var owners: [String: UUID] = [:]
        for record in current {
            guard case .snippet(let snippet) = record else { continue }
            let keyword = snippet.keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !keyword.isEmpty { owners[keyword] = snippet.id }
        }
        for record in incoming {
            guard case .snippet(let snippet) = record else { continue }
            let keyword = snippet.keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !keyword.isEmpty else { continue }
            if let owner = owners[keyword], owner != snippet.id { throw LibraryBackupError.duplicateKeyword }
        }
    }
}

// MARK: - Files

/// Reads and writes backup files. The file is opened once, without following
/// a link, and read within a fixed size, so a growing or unusual file can
/// neither hang the app nor be read past its limit.
enum LibraryBackupFileIO {
    /// Reads a backup file. A directory, a link or a pipe is refused.
    static func readBackup(at url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw LibraryBackupError.notRegularFile }
        defer { close(descriptor) }

        var before = stat()
        guard fstat(descriptor, &before) == 0 else { throw LibraryBackupError.notRegularFile }
        guard (before.st_mode & S_IFMT) == S_IFREG else { throw LibraryBackupError.notRegularFile }
        guard before.st_size >= 0, before.st_size <= Int64(LibraryBackupFormat.maxEncodedBytes) else {
            throw LibraryBackupError.tooLarge
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                read(descriptor, raw.baseAddress, raw.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw LibraryBackupError.malformed
            }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
            if data.count > LibraryBackupFormat.maxEncodedBytes { throw LibraryBackupError.tooLarge }
        }

        var after = stat()
        guard fstat(descriptor, &after) == 0 else { throw LibraryBackupError.changedWhileReading }
        guard before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw LibraryBackupError.changedWhileReading
        }
        var onPath = stat()
        guard lstat(url.path, &onPath) == 0 else { throw LibraryBackupError.changedWhileReading }
        guard onPath.st_dev == before.st_dev, onPath.st_ino == before.st_ino else {
            throw LibraryBackupError.changedWhileReading
        }
        return data
    }

    /// Writes the backup into a new folder of its own. The folder is private,
    /// the file is private, nothing existing is overwritten and a failure
    /// removes only the folder this call created.
    @discardableResult
    static func writeBackup(_ data: Data, kind: LibraryBackupKind, to parent: URL) throws -> URL {
        guard data.count <= LibraryBackupFormat.maxEncodedBytes else { throw LibraryBackupError.tooLarge }
        let folder = parent.appendingPathComponent("Orbit Library Backup \(kind.rawValue) \(stamp()) \(UUID().uuidString.prefix(8))",
                                                   isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                     attributes: [.posixPermissions: 0o700])
        } catch {
            throw LibraryBackupError.writeFailed
        }
        do {
            try writeFile(data, to: folder.appendingPathComponent("Orbit Library Backup - \(kind.rawValue).json"))
            return folder
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// Writes one file with its own permissions, without following a link and
    /// without replacing anything that is already there.
    private static func writeFile(_ data: Data, to url: URL) throws {
        let descriptor = url.path.withCString { path in
            open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard descriptor >= 0 else { throw LibraryBackupError.writeFailed }
        var closed = false
        defer { if !closed { close(descriptor) } }
        do {
            try data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(descriptor, base.advanced(by: offset), raw.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw LibraryBackupError.writeFailed
                    }
                    offset += written
                }
            }
            guard fchmod(descriptor, 0o600) == 0 else { throw LibraryBackupError.writeFailed }
            guard fsync(descriptor) == 0 else { throw LibraryBackupError.writeFailed }
        } catch {
            close(descriptor); closed = true
            unlink(url.path)
            throw error
        }
        close(descriptor); closed = true
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter.string(from: Date())
    }
}
