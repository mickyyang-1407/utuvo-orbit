import AppKit
import Darwin
import OrbitCore
import UniformTypeIdentifiers

struct ToolCopy {
    let language: AppLanguage
    var chinese: Bool { language.resolvedIdentifier(preferredLanguages: Locale.preferredLanguages) == "zh-Hant" }
    func callAsFunction(_ zh: String, _ en: String) -> String { chinese ? zh : en }
}

enum WorkbenchError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let message): message } }
}

/// Keeps unreadable preference bytes intact until an explicit backup/reset.
@MainActor
final class ToolStorage<Value: Codable> {
    let defaults: UserDefaults?
    let key: String
    let fileURL: URL?
    private(set) var damaged = false
    init(_ defaults: UserDefaults?, _ key: String, fileURL: URL? = nil) { self.defaults = defaults; self.key = key; self.fileURL = fileURL }
    func load(fallback: Value, validate: (Value) -> Bool = { _ in true }) -> Value {
        let raw: Any?
        if let fileURL {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return fallback }
            guard let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 24_000_000,
                  let data = try? Data(contentsOf: fileURL) else { damaged = true; return fallback }
            raw = data
        } else { raw = defaults?.object(forKey: key) }
        guard let raw else { return fallback }
        guard let data = raw as? Data, data.count <= 24_000_000,
              let decoded = try? JSONDecoder().decode(Value.self, from: data), validate(decoded) else {
            damaged = true; return fallback
        }
        return decoded
    }
    /// A seam for a real failure test: throwing here leaves the saved file
    /// exactly as it was. It runs before the file is committed.
    var beforeFileCommit: (() throws -> Void)?
    func save(_ value: Value) throws {
        guard !damaged else { throw WorkbenchError.invalid("Storage needs backup and reset / 資料需先備份並重設") }
        let data = try JSONEncoder().encode(value)
        if let fileURL {
            try writeAtomically(data, to: fileURL)
        } else { defaults?.set(data, forKey: key) }
    }

    /// Writes the bytes with one private temporary file in the same folder and
    /// one rename.
    ///
    /// Everything that can fail happens before the rename, so a failure never
    /// leaves a half written file behind, never overwrites anything and never
    /// reports a failure after the file was already changed.
    private func writeAtomically(_ data: Data, to fileURL: URL) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // The name is random and the file is created exclusively, so a link or
        // an existing file is never followed or replaced.
        let temporary = directory.appendingPathComponent("." + fileURL.lastPathComponent + "." + UUID().uuidString + ".tmp")
        let descriptor = temporary.path.withCString { path in
            open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard descriptor >= 0 else {
            throw WorkbenchError.invalid("The library file could not be written / 無法寫入檔案")
        }
        var closed = false
        defer { if !closed { close(descriptor) } }
        do {
            try data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let written = write(descriptor, base.advanced(by: offset), raw.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw WorkbenchError.invalid("The library file could not be written / 無法寫入檔案")
                    }
                    offset += written
                }
            }
            // The permissions are set before the commit, so the file is never
            // readable by anyone else, not even for a moment.
            guard fchmod(descriptor, 0o600) == 0 else {
                throw WorkbenchError.invalid("The library file could not be written / 無法寫入檔案")
            }
            guard fsync(descriptor) == 0 else {
                throw WorkbenchError.invalid("The library file could not be written / 無法寫入檔案")
            }
            try beforeFileCommit?()
        } catch {
            close(descriptor); closed = true
            unlink(temporary.path)
            throw error
        }
        close(descriptor); closed = true
        // The commit. Nothing that can fail may follow it.
        guard rename(temporary.path, fileURL.path) == 0 else {
            unlink(temporary.path)
            throw WorkbenchError.invalid("The library file could not be written / 無法寫入檔案")
        }
    }
    func backupAndReset(_ value: Value) throws {
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.copyItem(at: fileURL, to: fileURL.appendingPathExtension("backup." + UUID().uuidString))
        } else if let raw = defaults?.object(forKey: key) { defaults?.set(raw, forKey: key + ".backup." + UUID().uuidString) }
        // The reset only counts when the bytes were really replaced. If the
        // save fails, the library stays damaged, so the caller is told the
        // truth and every transfer stays blocked.
        let wasDamaged = damaged
        damaged = false
        do {
            try save(value)
        } catch {
            damaged = wasDamaged
            throw error
        }
    }
}

struct ToolExport: Sendable { let name: String; let data: Data }

enum ToolFiles {
    @MainActor static func choose(_ types: [UTType], multiple: Bool = true) -> [URL] {
        let panel = NSOpenPanel(); panel.allowedContentTypes = types
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = multiple
        return panel.runModal() == .OK ? panel.urls : []
    }
    @MainActor static func directory() -> URL? {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
    /// A unique output folder is the transaction boundary. Inputs are never overwritten.
    static func write(_ exports: [ToolExport], to parent: URL) throws -> URL {
        guard !exports.isEmpty else { throw WorkbenchError.invalid("No output / 沒有輸出") }
        let directory = parent.appendingPathComponent("Orbit Export " + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            for item in exports {
                try Task.checkCancellation()
                guard item.name == URL(fileURLWithPath: item.name).lastPathComponent else { throw CocoaError(.fileWriteInvalidFileName) }
                try item.data.write(to: directory.appendingPathComponent(item.name), options: .withoutOverwriting)
            }
            return directory
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
}
