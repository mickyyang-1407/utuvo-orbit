import AppKit
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
    func save(_ value: Value) throws {
        guard !damaged else { throw WorkbenchError.invalid("Storage needs backup and reset / 資料需先備份並重設") }
        let data = try JSONEncoder().encode(value)
        if let fileURL {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } else { defaults?.set(data, forKey: key) }
    }
    func backupAndReset(_ value: Value) throws {
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.copyItem(at: fileURL, to: fileURL.appendingPathExtension("backup." + UUID().uuidString))
        } else if let raw = defaults?.object(forKey: key) { defaults?.set(raw, forKey: key + ".backup." + UUID().uuidString) }
        damaged = false; try save(value)
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
