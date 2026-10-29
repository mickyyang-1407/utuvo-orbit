import Foundation

/// Thread-safe bridge between the pure `ShelfModel` and the AppKit layer.
/// The AppKit layer calls `insertFromPasteboard` on the main thread when a
/// drop completes; tests use a background thread directly.
public final class ShelfViewModel {
    public let model: ShelfModel
    private let lock = NSLock()

    public init(model: ShelfModel = ShelfModel()) {
        self.model = model
    }

    /// Insert URLs after normalization, returning the URLs that were actually
    /// new on the shelf.
    @discardableResult
    public func insert(_ urls: [URL]) -> [URL] {
        lock.lock(); defer { lock.unlock() }
        return model.insert(urls)
    }

    @discardableResult
    public func remove(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return model.remove(url)
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        model.clear()
    }

    public var allItems: [ShelfItem] {
        lock.lock(); defer { lock.unlock() }
        return model.allItems
    }

    public var isEmpty: Bool { allItems.isEmpty }
}
