import AppKit
import Combine
import CryptoKit
import Foundation

// MARK: - Algorithm

enum FileIntegrityAlgorithm: String, CaseIterable, Identifiable, Sendable {
    case sha256, sha512, md5
    var id: Self { self }
    var digestBytes: Int {
        switch self { case .sha256: 32; case .sha512: 64; case .md5: 16 }
    }
    var hexLength: Int { digestBytes * 2 }
    var title: String {
        switch self { case .sha256: "SHA-256"; case .sha512: "SHA-512"; case .md5: "MD5" }
    }
    /// MD5 only exists here to compare with checksums made by older tools. It is
    /// not collision resistant and never proves that two files are identical.
    var compatibilityOnly: Bool { self == .md5 }
}

enum FileIntegrityError: LocalizedError, Equatable {
    case tooManyFiles
    case noFiles
    case cannotOpen
    case symlinkRejected
    case notRegularFile
    case readFailed
    case changedDuringRead
    case cancelled
    case invalidExpectedLength
    case invalidExpectedHex

    var errorDescription: String? {
        switch self {
        case .tooManyFiles: "Up to 8 files / 最多 8 個檔案"
        case .noFiles: "Choose at least one file / 請先選擇檔案"
        case .cannotOpen: "The file could not be opened / 無法開啟這個檔案"
        case .symlinkRejected: "Symbolic links are not hashed / 不計算符號連結"
        case .notRegularFile: "Only regular files are hashed / 只計算一般檔案"
        case .readFailed: "The file could not be read / 無法讀取這個檔案"
        case .changedDuringRead: "The file changed while it was hashed, so no result is shown / 檔案在計算期間變動，因此不顯示結果"
        case .cancelled: "The calculation was cancelled / 計算已取消"
        case .invalidExpectedLength: "The expected checksum length does not match the algorithm / 預期雜湊的長度與演算法不符"
        case .invalidExpectedHex: "The expected checksum is not hexadecimal / 預期雜湊不是十六進位"
        }
    }
}

// MARK: - Streaming digest

/// Streaming digest state. All three algorithms come from Apple's CryptoKit;
/// MD5 uses `Insecure.MD5`, which is kept only to compare with checksums made
/// by other tools.
enum StreamingDigest {
    case sha256(SHA256)
    case sha512(SHA512)
    case md5(Insecure.MD5)

    init(_ algorithm: FileIntegrityAlgorithm) {
        switch algorithm {
        case .sha256: self = .sha256(SHA256())
        case .sha512: self = .sha512(SHA512())
        case .md5: self = .md5(Insecure.MD5())
        }
    }

    mutating func update(_ bytes: UnsafeRawBufferPointer) {
        switch self {
        case .sha256(var hasher):
            hasher.update(data: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: bytes.baseAddress!).assumingMemoryBound(to: UInt8.self), count: bytes.count, deallocator: .none))
            self = .sha256(hasher)
        case .sha512(var hasher):
            hasher.update(data: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: bytes.baseAddress!).assumingMemoryBound(to: UInt8.self), count: bytes.count, deallocator: .none))
            self = .sha512(hasher)
        case .md5(var hasher):
            hasher.update(data: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: bytes.baseAddress!).assumingMemoryBound(to: UInt8.self), count: bytes.count, deallocator: .none))
            self = .md5(hasher)
        }
    }

    func finalize() -> [UInt8] {
        switch self {
        case .sha256(let hasher): return Array(hasher.finalize())
        case .sha512(let hasher): return Array(hasher.finalize())
        case .md5(let hasher): return Array(hasher.finalize())
        }
    }
}

// MARK: - Hashing

struct FileIntegrityDigest: Equatable, Sendable {
    let hex: String
    let byteCount: Int
}

/// Hashes one file with a single descriptor.
///
/// The descriptor is opened with O_NOFOLLOW and O_NONBLOCK so a symlink is
/// never followed and a FIFO can never block the open. The descriptor must be
/// a regular file, and the same descriptor is used for the whole read. The
/// metadata is compared before and after the read and the path is checked
/// again, so a file that changed or was replaced produces an error instead of
/// a result nobody should trust.
enum FileIntegrityHasher {
    static let chunkSize = 1 << 20  // 1 MiB
    private static let modeMask: UInt16 = 0o170000
    private static let modeLink: UInt16 = 0o120000
    private static let modeRegular: UInt16 = 0o100000

    /// `afterOpen` is a test seam: it runs between the open and the read so a
    /// test can change the file or the path on purpose.
    static func digest(of url: URL, algorithm: FileIntegrityAlgorithm,
                       isCancelled: @Sendable () -> Bool,
                       afterOpen: @Sendable () -> Void = {}) throws -> FileIntegrityDigest {
        let path = url.path

        var linkInfo = stat()
        guard lstat(path, &linkInfo) == 0 else { throw FileIntegrityError.cannotOpen }
        let linkMode = linkInfo.st_mode & modeMask
        if linkMode == modeLink { throw FileIntegrityError.symlinkRejected }
        guard linkMode == modeRegular else { throw FileIntegrityError.notRegularFile }

        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw FileIntegrityError.cannotOpen }
        defer { close(descriptor) }

        var before = stat()
        guard fstat(descriptor, &before) == 0 else { throw FileIntegrityError.cannotOpen }
        guard (before.st_mode & modeMask) == modeRegular else { throw FileIntegrityError.notRegularFile }
        guard before.st_dev == linkInfo.st_dev, before.st_ino == linkInfo.st_ino else {
            throw FileIntegrityError.changedDuringRead
        }

        afterOpen()

        var hasher = StreamingDigest(algorithm)
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var total = 0
        while true {
            if isCancelled() { throw FileIntegrityError.cancelled }
            let count = try buffer.withUnsafeMutableBytes { raw -> Int in
                let read = try readChunk(descriptor: descriptor, buffer: raw.baseAddress!)
                if read > 0 {
                    hasher.update(UnsafeRawBufferPointer(start: raw.baseAddress!.assumingMemoryBound(to: UInt8.self), count: read))
                }
                return read
            }
            if count == 0 { break }
            total += count
        }

        if isCancelled() { throw FileIntegrityError.cancelled }

        // The file must not have changed while it was read.
        var after = stat()
        guard fstat(descriptor, &after) == 0 else { throw FileIntegrityError.cannotOpen }
        guard after.st_dev == before.st_dev, after.st_ino == before.st_ino,
              after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec else {
            throw FileIntegrityError.changedDuringRead
        }
        guard Int64(total) == before.st_size else { throw FileIntegrityError.changedDuringRead }

        // The path must still point at the very same file.
        var pathInfo = stat()
        guard lstat(path, &pathInfo) == 0 else { throw FileIntegrityError.changedDuringRead }
        guard pathInfo.st_dev == before.st_dev, pathInfo.st_ino == before.st_ino else {
            throw FileIntegrityError.changedDuringRead
        }

        let bytes = hasher.finalize()
        return FileIntegrityDigest(hex: hexString(bytes), byteCount: total)
    }

    private static func readChunk(descriptor: Int32, buffer: UnsafeMutableRawPointer) throws -> Int {
        while true {
            let count = read(descriptor, buffer, chunkSize)
            if count >= 0 { return count }
            if errno == EINTR { continue }
            throw FileIntegrityError.readFailed
        }
    }

    static func hexString(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", Int($0)) }.joined()
    }
}

// MARK: - Cancellation

/// A cancellation flag that is safe to read from the hashing task.
final class FileIntegrityCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func cancel() {
        lock.lock()
        flag = true
        lock.unlock()
    }
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}

// MARK: - Model

struct FileIntegrityResult: Identifiable, Equatable {
    let id = UUID()
    let fileName: String
    let digest: String
    let byteCount: Int
    let algorithm: FileIntegrityAlgorithm
}

struct FileIntegrityComparison: Equatable {
    let first: FileIntegrityResult
    let second: FileIntegrityResult
    let matches: Bool
}

struct FileIntegrityExpectedCheck: Identifiable, Equatable {
    let id = UUID()
    let fileName: String
    let matched: Bool
}

enum FileIntegrityOutcome {
    case success([FileIntegrityResult])
    case failure(any Error)
    case cancelled
}

@MainActor
final class FileIntegrityModel: ObservableObject {
    @Published private(set) var files: [URL] = []
    @Published private(set) var results: [FileIntegrityResult] = []
    @Published private(set) var comparison: FileIntegrityComparison?
    @Published private(set) var expectedChecks: [FileIntegrityExpectedCheck] = []
    /// A failure of the run or of a file.
    @Published private(set) var error: String?
    /// A failure of the expected checksum itself. Kept apart from `error` so a
    /// successful recheck never hides an unrelated file failure.
    @Published private(set) var expectedError: String?
    @Published private(set) var busy = false
    @Published var algorithm: FileIntegrityAlgorithm = .sha256 {
        didSet {
            guard algorithm != oldValue else { return }
            // The results belong to the old algorithm, so they are dropped.
            invalidateInputs()
        }
    }
    @Published var expected = "" {
        didSet {
            guard expected != oldValue else { return }
            // A changed expectation invalidates the previous comparison.
            expectedChecks = []
            expectedError = nil
        }
    }

    static let maxFiles = 8
    /// The hashing step, injected so a test can hold a run open on purpose.
    typealias HashFile = @Sendable (URL, FileIntegrityAlgorithm, @Sendable () -> Bool) throws -> FileIntegrityDigest
    private let preview: Bool
    private let copyText: (String) -> Void
    private let hashFile: HashFile
    private var generation = 0
    private var work: Task<FileIntegrityOutcome, Never>?
    private var cancellation: FileIntegrityCancellation?

    init(preview: Bool = false, copyText: @escaping (String) -> Void = { _ in }, hashFile: HashFile? = nil) {
        self.preview = preview
        self.copyText = copyText
        self.hashFile = hashFile ?? { url, algorithm, isCancelled in
            try FileIntegrityHasher.digest(of: url, algorithm: algorithm, isCancelled: isCancelled)
        }
    }

    /// The request id of the newest run. A result from an older id is stale.
    var currentRequestID: Int { generation }

    /// Drops the pending work and the current results. Any change of the
    /// algorithm or of the file selection invalidates what is on screen.
    func invalidateInputs() {
        generation += 1
        cancellation?.cancel()
        work?.cancel()
        work = nil
        cancellation = nil
        busy = false
        error = nil
        clearResults()
        expectedChecks = []
        expectedError = nil
    }

    // MARK: Files

    @discardableResult
    func addFiles(_ urls: [URL]) -> Bool {
        guard !preview else {
            error = "Preview mode does not read files / 預覽模式不會讀取檔案"
            return false
        }
        guard files.count + urls.count <= Self.maxFiles else {
            error = FileIntegrityError.tooManyFiles.errorDescription
            return false
        }
        invalidateInputs()
        files.append(contentsOf: urls)
        return true
    }

    @discardableResult
    func removeFile(_ url: URL) -> Bool {
        guard files.contains(url) else { return false }
        invalidateInputs()
        files.removeAll { $0 == url }
        return true
    }

    func clearFiles() {
        invalidateInputs()
        files = []
    }

    // MARK: Computing

    /// Hashes the chosen files. Nothing is hashed before the user asks.
    func compute() async {
        guard !preview else { return }
        guard !files.isEmpty else {
            error = FileIntegrityError.noFiles.errorDescription
            return
        }
        work?.cancel()
        cancellation?.cancel()

        let requestID = generation + 1
        generation = requestID
        error = nil
        clearResults()
        expectedChecks = []
        expectedError = nil
        busy = true

        let algorithm = self.algorithm
        let urls = files
        let token = FileIntegrityCancellation()
        cancellation = token
        let hashFile = self.hashFile

        let task = Task.detached(priority: .utility) { () -> FileIntegrityOutcome in
            var collected: [FileIntegrityResult] = []
            for url in urls {
                if token.isCancelled { return .cancelled }
                // Security scope is started and stopped on every outcome.
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let digest = try hashFile(url, algorithm, { token.isCancelled })
                    collected.append(FileIntegrityResult(fileName: url.lastPathComponent, digest: digest.hex,
                                                         byteCount: digest.byteCount, algorithm: algorithm))
                } catch FileIntegrityError.cancelled {
                    return .cancelled
                } catch {
                    return .failure(error)
                }
            }
            if token.isCancelled { return .cancelled }
            return .success(collected)
        }
        work = task

        let outcome = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            token.cancel()
            task.cancel()
        }
        // Only the newest run may clear the task and the token, so an older
        // run that finishes late cannot wipe the state of a newer one.
        if requestID == generation {
            work = nil
            cancellation = nil
        }
        // A run that was cancelled — here or by its parent — never commits,
        // even when the hash had already finished.
        let delivered: FileIntegrityOutcome = (token.isCancelled || Task.isCancelled) ? .cancelled : outcome
        commit(delivered, requestID: requestID)
    }

    /// Stores a finished run. A result from a request that is no longer the
    /// newest one is dropped, so a slow run can never overwrite a newer one.
    func commit(_ outcome: FileIntegrityOutcome, requestID: Int) {
        guard requestID == generation else { return }
        busy = false
        switch outcome {
        case .success(let values):
            results = values
            error = nil
            comparison = makeComparison(values)
            checkExpected()
        case .failure(let failure):
            error = failure.localizedDescription
        case .cancelled:
            error = nil
        }
    }

    /// Cancels the running hash. The generation is invalidated as well, so a
    /// result that is ready but not yet delivered is never committed.
    func cancel() {
        cancellation?.cancel()
        work?.cancel()
        generation += 1
        work = nil
        cancellation = nil
        busy = false
    }

    func stop() {
        cancel()
    }

    // MARK: Expected checksum

    /// Normalises the expected checksum (case and whitespace) and compares it
    /// with the current successful results only. A checksum error never hides
    /// an unrelated file failure.
    func checkExpected() {
        expectedChecks = []
        let normalized = Self.normalizedHex(expected)
        guard !normalized.isEmpty else {
            expectedError = nil
            return
        }
        guard normalized.count == algorithm.hexLength else {
            expectedError = FileIntegrityError.invalidExpectedLength.errorDescription
            return
        }
        guard normalized.allSatisfy({ Self.allowedHex.contains($0) }) else {
            expectedError = FileIntegrityError.invalidExpectedHex.errorDescription
            return
        }
        // Only results made with the current algorithm take part.
        expectedChecks = results.filter { $0.algorithm == algorithm }.map { result in
            FileIntegrityExpectedCheck(fileName: result.fileName, matched: result.digest == normalized)
        }
        expectedError = nil
    }

    private static let allowedHex: Set<Character> = Set("0123456789abcdef")

    static func normalizedHex(_ value: String) -> String {
        value.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            .map { Character($0).lowercased() }
            .reduce(into: "") { $0.append($1) }
    }

    // MARK: Output

    func copyHash(_ id: UUID) {
        guard let result = results.first(where: { $0.id == id }) else { return }
        copyText(result.digest)
    }

    /// A plain text report of the current run.
    func reportText() -> String? {
        guard !results.isEmpty else { return nil }
        var lines = ["File integrity — \(algorithm.title)"]
        for result in results {
            lines.append("\(result.fileName): \(result.digest) (\(result.byteCount) bytes)")
        }
        if let comparison {
            lines.append(comparison.matches
                         ? "The two hash values match. This does not prove the files are identical."
                         : "The two hash values differ.")
        }
        for check in expectedChecks {
            lines.append("\(check.fileName): expected checksum \(check.matched ? "matches" : "does not match")")
        }
        if algorithm.compatibilityOnly {
            lines.append("MD5 is a compatibility algorithm. It is not collision resistant.")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Internals

    private func makeComparison(_ values: [FileIntegrityResult]) -> FileIntegrityComparison? {
        guard files.count == 2, values.count == 2, values[0].algorithm == values[1].algorithm else { return nil }
        return FileIntegrityComparison(first: values[0], second: values[1], matches: values[0].digest == values[1].digest)
    }

    private func clearResults() {
        results = []
        comparison = nil
        expectedChecks = []
    }
}
