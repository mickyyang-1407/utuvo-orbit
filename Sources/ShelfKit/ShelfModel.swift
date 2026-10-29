import Foundation

/// Pure, observable model of the shelf. No AppKit / UIKit types so it can be unit-tested
/// without spinning up a window server.
///
/// Insert rules:
///   - URLs are normalized via `.standardizedFileURL` so `~/foo` and `/Users/me/foo` dedupe.
///   - Symlink targets are resolved (`.resolvingSymlinksInPath`) so two paths pointing to the
///     same inode are recognized as one reference.
///   - Directories are allowed (a folder is a valid drop target to bring back out).
///   - Insert order is preserved; re-inserting an existing URL is a no-op (returns the
///     existing index).
public final class ShelfModel {
    public typealias FileProbe = (URL) -> ShelfItemStatus

    private var items: [ShelfItem] = []
    private let probe: FileProbe

    public init(probe: @escaping FileProbe = ShelfModel.defaultProbe) {
        self.probe = probe
    }

    public var allItems: [ShelfItem] { items }
    public var count: Int { items.count }
    public var isEmpty: Bool { items.isEmpty }

    /// Insert a batch of URLs. Returns the set of normalized URLs that were actually added
    /// (i.e. were not already present). Order of insertion follows `urls`.
    @discardableResult
    public func insert(_ urls: [URL], now: Date = Date()) -> [URL] {
        var added: [URL] = []
        for raw in urls where raw.isFileURL && (raw.host == nil || raw.host == "" || raw.host == "localhost") {
            let key = Self.normalize(raw)
            if items.contains(where: { $0.url == key }) { continue }
            let item = ShelfItem(
                url: key,
                displayName: key.lastPathComponent.isEmpty ? key.path : key.lastPathComponent,
                byteSize: ShelfModel.byteSizeIfRegularFile(key),
                addedAt: now
            )
            items.append(item)
            added.append(key)
        }
        return added
    }

    /// Remove the entry with the given URL (after normalization). Returns true if removed.
    @discardableResult
    public func remove(_ url: URL) -> Bool {
        let key = Self.normalize(url)
        let before = items.count
        items.removeAll { $0.url == key }
        return items.count != before
    }

    /// Remove every entry.
    public func clear() {
        items.removeAll()
    }

    /// Re-check on-disk status of every entry, returning the set of URLs that are now stale.
    /// Items themselves are not removed by this call — the UI is expected to surface the
    /// status and let the user decide whether to clear.
    public func refreshStaleStatus() -> [URL: ShelfItemStatus] {
        var map: [URL: ShelfItemStatus] = [:]
        for item in items {
            map[item.url] = probe(item.url)
        }
        return map
    }

    /// Normalize for storage and dedupe.
    public static func normalize(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Probe whether a URL is currently readable on disk.
    public static func defaultProbe(_ url: URL) -> ShelfItemStatus {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if !exists { return .missing }
        if FileManager.default.isReadableFile(atPath: url.path) { return .ok }
        return .unreadable
    }

    /// Returns the regular-file byte size, or nil for directories / symlinks to dirs / errors.
    /// Files larger than `Int64.max` are clamped.
    public static func byteSizeIfRegularFile(_ url: URL) -> Int64? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              !isDir.boolValue
        else { return nil }
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attrs[.size] as? NSNumber { return size.int64Value }
        } catch {
            return nil
        }
        return nil
    }
}
