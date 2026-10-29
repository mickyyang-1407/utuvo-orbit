import Foundation

/// One reference held on the shelf. Pure value; URL is the identity.
public struct ShelfItem: Hashable, Identifiable, Sendable {
    /// Absolute file URL; standardized to ensure dedupe across `~/foo` vs `/Users/x/foo`.
    public let url: URL
    /// Display name (last path component) captured at insert time so the shelf still shows
    /// a label even when the file is later moved or deleted.
    public let displayName: String
    /// Byte size at insert time (nil if not determinable); nil for directories / unknown.
    public let byteSize: Int64?
    /// Insertion timestamp.
    public let addedAt: Date

    public var id: URL { url }

    public init(url: URL, displayName: String, byteSize: Int64?, addedAt: Date) {
        self.url = url
        self.displayName = displayName
        self.byteSize = byteSize
        self.addedAt = addedAt
    }
}

/// Reasons an existing reference can become stale.
public enum ShelfItemStatus: Hashable, Sendable {
    case ok
    case missing          // file no longer exists at recorded URL
    case unreadable       // exists but cannot be read
}
