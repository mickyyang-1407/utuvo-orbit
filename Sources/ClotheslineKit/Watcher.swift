import AppKit
import ImageIO

@MainActor final class ScreenshotWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var known = Set<URL>()
    private var pending = Set<URL>()
    private var generation = UUID()
    private var directory: URL?
    var receive: ((URL) -> Void)?
    var failure: ((String) -> Void)?

    func start(at directory: URL) {
        stop()
        self.directory = directory
        do { known = Set(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) }
        catch { failure?(error.localizedDescription); return }
        let fd = open(directory.path, O_EVTONLY | O_NOFOLLOW)
        guard fd >= 0 else { failure?(L.text("無法監聽截圖目錄，請檢查目錄存取權。", "Unable to watch this folder. Check folder access.")); return }
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .revoke], queue: .main)
        watcher.setEventHandler { [weak self, weak watcher] in MainActor.assumeIsolated {
            guard let watcher else { return }
            if watcher.data.intersection([.rename, .delete, .revoke]).isEmpty { self?.scan() }
            else { self?.failure?(L.text("截圖目錄已變更或無法存取，請重新選擇。", "The screenshot folder moved or became inaccessible. Choose it again.")); self?.stop() }
        } }
        watcher.setCancelHandler { close(fd) }
        source = watcher; watcher.resume()
    }

    func stop() { source?.cancel(); source = nil; pending = []; known = []; generation = UUID() }

    private func scan() {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        let current = Set(files)
        for url in current.subtracting(known) where !pending.contains(url) {
            pending.insert(url)
            settle(url, last: nil, remaining: 16, generation: generation)
        }
        known = current
    }

    private func settle(_ url: URL, last: Fingerprint?, remaining: Int, generation token: UUID) {
        guard generation == token else { return }
        let now = try? Fingerprint.read(url)
        if let now, now.size > 0, now == last, CapturePolicy.isSystemScreenshot(url),
           Self.isDecodableImage(url) {
            pending.remove(url); receive?(url); return
        }
        guard remaining > 0 else { pending.remove(url); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.045) { [weak self] in
            self?.settle(url, last: now, remaining: remaining - 1, generation: token)
        }
    }

    private static func isDecodableImage(_ url: URL) -> Bool {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return false }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 4,
                kCGImageSourceShouldCache: false
            ] as CFDictionary) != nil
        }
    }
}
