import Foundation
import Darwin

public struct Capture: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let filename: String
    public let capturedAt: Date
    public let managedFingerprint: Fingerprint
    public var source: URL?
    public var sourceFingerprint: Fingerprint?
}

public struct Fingerprint: Codable, Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let size: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanos: Int64

    public static func read(_ url: URL) throws -> Self {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG else {
            throw LibraryError.unsafeFile
        }
        return Self(device: UInt64(info.st_dev), inode: info.st_ino, size: info.st_size,
                    modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
                    modifiedNanos: Int64(info.st_mtimespec.tv_nsec))
    }
}

public enum LibraryError: Error, LocalizedError {
    case unsafeFile, invalidManifest, changedDuringCopy, missingCapture
    public var errorDescription: String? {
        switch self {
        case .unsafeFile: "The file is unavailable, a symlink, or not a regular file."
        case .invalidManifest: "The library manifest is invalid. Files have been preserved."
        case .changedDuringCopy: "The screenshot changed while it was being saved. The source has been preserved."
        case .missingCapture: "This screenshot is no longer available."
        }
    }
}

public enum CapturePolicy {
    public static func isSystemScreenshot(_ url: URL) -> Bool {
        guard ["png", "jpg", "jpeg", "tiff", "heic"].contains(url.pathExtension.lowercased()),
              (try? Fingerprint.read(url)) != nil else { return false }
        let name = "com.apple.metadata:kMDItemIsScreenCapture"
        let count = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard count > 0, count < 4096 else { return false }
        var bytes = [UInt8](repeating: 0, count: count)
        guard getxattr(url.path, name, &bytes, count, 0, XATTR_NOFOLLOW) == count else { return false }
        let data = Data(bytes)
        if let value = try? PropertyListSerialization.propertyList(from: data, format: nil) {
            if let string = value as? String { return string.lowercased() == "1" || string.lowercased() == "true" }
            if let number = value as? NSNumber { return number.boolValue }
        }
        return false
    }

    public static func expired(_ date: Date, days: Int, now: Date) -> Bool {
        days > 0 && now.timeIntervalSince(date) >= Double(days) * 86_400
    }
}

/// Only files in this library's explicit manifest may be cleaned. No recursive directory deletion.
public final class CaptureLibrary {
    public let root: URL
    public private(set) var captures: [Capture]
    private let fm = FileManager.default
    private var manifest: URL { root.appendingPathComponent("library.json") }

    public init(root: URL) throws {
        self.root = root.standardizedFileURL
        captures = []
        try fm.createDirectory(at: self.root, withIntermediateDirectories: true)
        let rootInfo = try self.root.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard rootInfo.isSymbolicLink != true else { throw LibraryError.unsafeFile }
        if fm.fileExists(atPath: manifest.path) {
            do {
                captures = try JSONDecoder().decode([Capture].self, from: Data(contentsOf: manifest))
                guard Set(captures.map(\.id)).count == captures.count,
                      captures.allSatisfy({ Self.safeName($0.filename) }) else {
                    throw LibraryError.invalidManifest
                }
            } catch { throw LibraryError.invalidManifest }
        }
    }

    public func url(for capture: Capture) -> URL { root.appendingPathComponent(capture.filename) }

    private static func safeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
    }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(captures).write(to: manifest, options: .atomic)
    }

    @discardableResult
    public func ingest(_ source: URL, at date: Date = Date()) throws -> Capture {
        let fingerprint = try Fingerprint.read(source)
        if let existing = captures.first(where: { $0.source == source && $0.sourceFingerprint == fingerprint }) {
            return existing
        }
        let id = UUID()
        let name = "\(id.uuidString).\(source.pathExtension.lowercased())"
        let target = root.appendingPathComponent(name)
        try fm.copyItem(at: source, to: target)
        guard try Fingerprint.read(source) == fingerprint,
              try Fingerprint.read(target).size == fingerprint.size else {
            // Preserve both files on a racing writer; the untracked copy is never auto-cleaned.
            throw LibraryError.changedDuringCopy
        }
        let capture = Capture(id: id, filename: name, capturedAt: date,
                              managedFingerprint: try Fingerprint.read(target),
                              source: source, sourceFingerprint: fingerprint)
        captures.insert(capture, at: 0)
        do { try save() } catch { captures.removeAll { $0.id == id }; throw error }
        return capture
    }

    /// Durable managed copy and manifest exist before touching the source.
    public func removeSourceFromDesktop(_ id: UUID) throws {
        guard let index = captures.firstIndex(where: { $0.id == id }) else { throw LibraryError.missingCapture }
        let capture = captures[index]
        guard fm.fileExists(atPath: url(for: capture).path) else { throw LibraryError.missingCapture }
        if let source = capture.source, let fingerprint = capture.sourceFingerprint {
            guard try Fingerprint.read(source) == fingerprint else { throw LibraryError.changedDuringCopy }
            try fm.trashItem(at: source, resultingItemURL: nil)
        }
        captures[index].source = nil
        captures[index].sourceFingerprint = nil
        try save()
    }

    @discardableResult
    public func discard(_ id: UUID) throws -> URL? {
        guard let index = captures.firstIndex(where: { $0.id == id }) else { throw LibraryError.missingCapture }
        let capture = captures[index]
        let managed = url(for: capture)
        if fm.fileExists(atPath: managed.path) {
            let actual = try Fingerprint.read(managed)
            guard actual.device == capture.managedFingerprint.device,
                  actual.inode == capture.managedFingerprint.inode else { throw LibraryError.unsafeFile }
        }
        // Never delete a replacement at the original pathname.
        if let source = capture.source,
           let expected = capture.sourceFingerprint,
           let actual = try? Fingerprint.read(source), actual == expected {
            try fm.trashItem(at: source, resultingItemURL: nil)
        }
        var trashed: NSURL?
        if fm.fileExists(atPath: managed.path) {
            try fm.trashItem(at: managed, resultingItemURL: &trashed)
        }
        captures.remove(at: index)
        do { try save() } catch { captures.insert(capture, at: index); throw error }
        return trashed as URL?
    }

    /// Called only after the OS moved the managed file, never merely because a drag ended.
    public func reconcileExternalMove(_ id: UUID) throws {
        guard let index = captures.firstIndex(where: { $0.id == id }) else { return }
        guard !fm.fileExists(atPath: url(for: captures[index]).path) else { return }
        let removed = captures.remove(at: index)
        do { try save() } catch { captures.insert(removed, at: index); throw error }
    }

    public func clean(days: Int, now: Date = Date()) -> [String] {
        let ids = captures.filter { CapturePolicy.expired($0.capturedAt, days: days, now: now) }.map(\.id)
        return ids.compactMap { id in
            do { try discard(id); return nil } catch { return error.localizedDescription }
        }
    }
}
