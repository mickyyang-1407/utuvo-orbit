import Foundation
#if canImport(AppKit)
import AppKit

/// Extracts file URLs from an `NSPasteboard` (or any `NSDraggingInfo`-derived
/// pasteboard). Public AppKit API only: `readObjects(forClasses:options:)` with
/// `NSPasteboardURLReadingFileURLsOnlyKey` and `[NSURL.self]`.
///
/// This is a thin pure-Foundation wrapper — no AppKit types in its public
/// surface besides `NSPasteboard` — so the call site stays test-friendly: tests
/// inject a fresh pasteboard with `NSPasteboard.withUniqueName()` and check the
/// returned URLs.
public struct PasteboardFileURLReader {
    public init() {}

    /// Read every file URL on `pasteboard`. Returns `[]` when no file URLs are
    /// present (e.g. text drag, image drag, empty pasteboard).
    public func readFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) ?? []
        var out: [URL] = []
        for obj in objects {
            if let url = obj as? URL, url.isFileURL,
               url.host == nil || url.host == "" || url.host == "localhost" { out.append(url) }
        }
        return out
    }

    /// Quick check that the pasteboard contains at least one file URL.
    /// Does **not** trigger the system "Pasted from X" notice — see NSPasteboard
    /// header comments around `canReadObject(forClasses:options:)`.
    public func canReadFileURLs(_ pasteboard: NSPasteboard) -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        return pasteboard.canReadObject(forClasses: [NSURL.self], options: options)
    }
}
#endif
