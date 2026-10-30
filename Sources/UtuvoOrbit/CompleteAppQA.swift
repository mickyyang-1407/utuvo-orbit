#if DEBUG && ORBIT_COMPLETE_APP_QA
import CoreGraphics
import Foundation
import ImageIO
import OrbitCore
import UniformTypeIdentifiers
import Darwin
@preconcurrency import ScreenCaptureKit

enum CompleteAppQAError: Error, Equatable {
    case invalidConfiguration, invalidRoot, invalidMarker, unexpectedContents, receiptWriteFailed
}

/// A reusable fixture root is identified by the signed QA bundle and its Info.plist nonce.
struct CompleteAppQARoot {
    static let bundleIdentifier = "com.utuvo.orbit.completeqa20261030"
    static let rootInfoKey = "OrbitCompleteQARootDirectory"
    static let nonceInfoKey = "OrbitCompleteQARootNonce"
    static let markerName = ".utuvo-orbit-complete-qa.json"
    static let schema = 1
    static let maximumMarkerBytes = 4_096
    static let maximumReceiptBytes = 64_000_000

    enum Store: String, CaseIterable {
        case notes = "Notes"
        case snippets = "Snippets"
        case quickLinks = "Quicklinks"
        case clipboard = "Clipboard"
        case screenshots = "Screenshots"
        case clothesline = "Clothesline"
    }

    let rootURL: URL
    let dataURL: URL
    let fixturesURL: URL
    let receiptsURL: URL
    let nonce: String
    let preferencesDomain: String
    let legacyPreferencesDomain: String
    let defaults: UserDefaults

    private struct Marker: Codable, Equatable {
        let schema: Int
        let bundle: String
        let nonce: String
        let uid: UInt32
    }

    static func open(bundleIdentifier: String?, info: [String: Any],
                     temporaryDirectory: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
                     uid: uid_t = getuid()) throws -> CompleteAppQARoot {
        guard bundleIdentifier == Self.bundleIdentifier,
              let rawPath = info[rootInfoKey] as? String, !rawPath.isEmpty,
              let rawNonce = info[nonceInfoKey] as? String,
              let parsedNonce = UUID(uuidString: rawNonce), parsedNonce.uuidString.lowercased() == rawNonce.lowercased() else {
            throw CompleteAppQAError.invalidConfiguration
        }

        let requestedRoot = URL(fileURLWithPath: rawPath, isDirectory: true).standardizedFileURL
        let tempRoot = temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let requestedParent = requestedRoot.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let name = requestedRoot.lastPathComponent
        guard requestedRoot.isFileURL, requestedParent.path == tempRoot.path,
              !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw CompleteAppQAError.invalidRoot
        }

        let parentFD = tempRoot.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard parentFD >= 0 else { throw CompleteAppQAError.invalidRoot }
        defer { close(parentFD) }
        var parentStat = stat()
        guard fstat(parentFD, &parentStat) == 0,
              (parentStat.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              parentStat.st_uid == uid,
              (parentStat.st_mode & mode_t(0o022)) == 0 else { throw CompleteAppQAError.invalidRoot }

        var rootFD = name.withCString { openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        var created = false
        if rootFD < 0, errno == ENOENT {
            guard name.withCString({ mkdirat(parentFD, $0, mode_t(0o700)) }) == 0 else {
                throw CompleteAppQAError.invalidRoot
            }
            created = true
            rootFD = name.withCString { openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        }
        guard rootFD >= 0 else { throw CompleteAppQAError.invalidRoot }
        defer { close(rootFD) }
        try verifyDirectory(rootFD, uid: uid, mode: 0o700)

        let nonce = parsedNonce.uuidString.lowercased()
        let marker = Marker(schema: schema, bundle: Self.bundleIdentifier, nonce: nonce, uid: UInt32(uid))
        if created {
            try writeFile(try JSONEncoder().encode(marker), directoryFD: rootFD, name: markerName, mode: 0o600,
                          maxBytes: maximumMarkerBytes)
            _ = fsync(rootFD)
        } else {
            let bytes = try readFile(directoryFD: rootFD, name: markerName, uid: uid,
                                     mode: 0o600, maxBytes: maximumMarkerBytes)
            guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  Set(object.keys) == Set(["schema", "bundle", "nonce", "uid"]),
                  let saved = try? JSONDecoder().decode(Marker.self, from: bytes), saved == marker else {
                throw CompleteAppQAError.invalidMarker
            }
        }

        let allowedRootNames: Set<String> = [markerName, "Data", "Fixtures", "Receipts"]
        let existingRootNames = Set(try FileManager.default.contentsOfDirectory(atPath: tempRoot.appendingPathComponent(name).path))
        guard existingRootNames.isSubset(of: allowedRootNames) else { throw CompleteAppQAError.unexpectedContents }
        try ensureDirectory(directoryFD: rootFD, name: "Data", uid: uid)
        try ensureDirectory(directoryFD: rootFD, name: "Fixtures", uid: uid)
        try ensureDirectory(directoryFD: rootFD, name: "Receipts", uid: uid)

        let dataFD = openat(rootFD, "Data", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dataFD >= 0 else { throw CompleteAppQAError.invalidRoot }
        defer { close(dataFD) }
        let allowedStores = Set(Store.allCases.map(\.rawValue))
        let existingStores = Set(try FileManager.default.contentsOfDirectory(atPath: tempRoot.appendingPathComponent(name).appendingPathComponent("Data").path))
        guard existingStores.isSubset(of: allowedStores) else { throw CompleteAppQAError.unexpectedContents }
        for store in Store.allCases { try ensureDirectory(directoryFD: dataFD, name: store.rawValue, uid: uid) }

        let preferencesDomain = "com.utuvo.orbit.completeqa.preferences.\(nonce)"
        let legacyDomain = "com.utuvo.orbit.completeqa.empty-legacy.\(nonce)"
        guard let defaults = UserDefaults(suiteName: preferencesDomain) else { throw CompleteAppQAError.invalidConfiguration }
        let canonicalRoot = tempRoot.appendingPathComponent(name, isDirectory: true)
        return CompleteAppQARoot(rootURL: canonicalRoot,
                                 dataURL: canonicalRoot.appendingPathComponent("Data", isDirectory: true),
                                 fixturesURL: canonicalRoot.appendingPathComponent("Fixtures", isDirectory: true),
                                 receiptsURL: canonicalRoot.appendingPathComponent("Receipts", isDirectory: true),
                                 nonce: nonce, preferencesDomain: preferencesDomain,
                                 legacyPreferencesDomain: legacyDomain, defaults: defaults)
    }

    func storeURL(_ store: Store) -> URL { dataURL.appendingPathComponent(store.rawValue, isDirectory: true) }

    func makePreferencesBackend() -> LivePreferencesBackend {
        LivePreferencesBackend(inspector: UserDefaultsInspector(), newDomain: preferencesDomain,
                               legacyDomain: legacyPreferencesDomain)
    }

    func writeTextReceipt(_ text: String, label: String = "copy-text") throws -> URL {
        try writeReceipt(Data(text.utf8), label: label, fileExtension: "txt")
    }

    func writeImageReceipt(_ image: CGImage, label: String = "copy-image") throws -> URL {
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer, UTType.png.identifier as CFString, 1, nil) else {
            throw CompleteAppQAError.receiptWriteFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CompleteAppQAError.receiptWriteFailed }
        return try writeReceipt(buffer as Data, label: label, fileExtension: "png")
    }

    private func writeReceipt(_ data: Data, label: String, fileExtension: String) throws -> URL {
        guard data.count <= Self.maximumReceiptBytes,
              !label.isEmpty, label.utf8.count <= 40,
              label.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 45 }) else {
            throw CompleteAppQAError.receiptWriteFailed
        }
        let rootFD = rootURL.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard rootFD >= 0 else { throw CompleteAppQAError.invalidRoot }
        defer { close(rootFD) }
        let receiptsFD = openat(rootFD, "Receipts", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard receiptsFD >= 0 else { throw CompleteAppQAError.invalidRoot }
        defer { close(receiptsFD) }
        let name = "\(label)-\(UUID().uuidString.lowercased()).\(fileExtension)"
        try Self.writeFile(data, directoryFD: receiptsFD, name: name, mode: 0o600,
                           maxBytes: Self.maximumReceiptBytes)
        return receiptsURL.appendingPathComponent(name, isDirectory: false)
    }

    private static func verifyDirectory(_ fd: Int32, uid: uid_t, mode: mode_t) throws {
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              info.st_uid == uid,
              (info.st_mode & mode_t(0o7777)) == mode else { throw CompleteAppQAError.invalidRoot }
    }

    private static func ensureDirectory(directoryFD: Int32, name: String, uid: uid_t) throws {
        var info = stat()
        let status = name.withCString { fstatat(directoryFD, $0, &info, AT_SYMLINK_NOFOLLOW) }
        if status != 0 {
            guard errno == ENOENT, name.withCString({ mkdirat(directoryFD, $0, mode_t(0o700)) }) == 0 else {
                throw CompleteAppQAError.invalidRoot
            }
        }
        let fd = name.withCString { openat(directoryFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw CompleteAppQAError.invalidRoot }
        defer { close(fd) }
        try verifyDirectory(fd, uid: uid, mode: 0o700)
    }

    private static func readFile(directoryFD: Int32, name: String, uid: uid_t, mode: mode_t,
                                 maxBytes: Int) throws -> Data {
        let fd = name.withCString { openat(directoryFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw CompleteAppQAError.invalidMarker }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_uid == uid, (info.st_mode & mode_t(0o7777)) == mode,
              info.st_size >= 0, info.st_size <= maxBytes else { throw CompleteAppQAError.invalidMarker }
        let expected = Int(info.st_size)
        var bytes = [UInt8](repeating: 0, count: expected)
        var offset = 0
        while offset < expected {
            let count = bytes.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress!.advanced(by: offset), expected - offset)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw CompleteAppQAError.invalidMarker }
            offset += count
        }
        return Data(bytes)
    }

    private static func writeFile(_ data: Data, directoryFD: Int32, name: String,
                                  mode: mode_t, maxBytes: Int) throws {
        guard data.count <= maxBytes else { throw CompleteAppQAError.receiptWriteFailed }
        let fd = name.withCString { openat(directoryFD, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode) }
        guard fd >= 0 else { throw CompleteAppQAError.receiptWriteFailed }
        var committed = false
        defer {
            close(fd)
            if !committed { name.withCString { _ = unlinkat(directoryFD, $0, 0) } }
        }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw CompleteAppQAError.receiptWriteFailed }
                offset += count
            }
        }
        guard fchmod(fd, mode) == 0, fsync(fd) == 0 else { throw CompleteAppQAError.receiptWriteFailed }
        committed = true
    }
}

struct CompleteAppQACardFacts: Equatable {
    let windowID: UInt32
    let ownerBundleID: String?
    let title: String?
    let frame: CGRect
}

struct CompleteAppQADisplayFacts: Equatable {
    let displayID: UInt32
    let frame: CGRect
}

enum CompleteAppQAPolicy {
    static let cardBundleID = "com.utuvo.orbit.capturecard20261029"
    static let cardTitle = "Orbit Test Card 20261029"

    static func isKnownCard(_ card: CompleteAppQACardFacts) -> Bool {
        card.ownerBundleID == cardBundleID && card.title == cardTitle && finite(card.frame)
            && card.frame.width == 620 && card.frame.height == 432
    }

    static func allowsDisplay(_ display: CompleteAppQADisplayFacts, card: CompleteAppQACardFacts,
                              includedDisplayIDs: [UInt32], includedWindowIDs: [UInt32]) -> Bool {
        cardFitsDisplay(display, card: card)
            && includedDisplayIDs == [display.displayID] && includedWindowIDs == [card.windowID]
    }

    static func cardFitsDisplay(_ display: CompleteAppQADisplayFacts, card: CompleteAppQACardFacts) -> Bool {
        isKnownCard(card) && finite(display.frame) && display.frame.contains(card.frame)
    }

    private static func finite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
    }
}

/// Retains only the user-selected QA Card. Display capture is reconstructed as a
/// display-inclusion filter containing that exact window, before a stream exists.
@MainActor
final class CompleteAppQACapturePolicy {
    private var knownCard: SCWindow?

    func transform(_ filter: SCContentFilter, mode: ScreenshotCaptureMode) -> SCContentFilter? {
        guard #available(macOS 15.2, *) else { return nil }
        switch mode {
        case .window:
            knownCard = nil
            guard filter.style == .window, filter.includedWindows.count == 1,
                  let card = filter.includedWindows.first,
                  CompleteAppQAPolicy.isKnownCard(Self.facts(card)) else { return nil }
            knownCard = card
            return filter
        case .display:
            guard let card = knownCard, filter.style == .display,
                  filter.includedDisplays.count == 1,
                  let display = filter.includedDisplays.first else { return nil }
            let cardFacts = Self.facts(card)
            let displayFacts = Self.facts(display)
            guard CompleteAppQAPolicy.cardFitsDisplay(displayFacts, card: cardFacts) else { return nil }
            let included = SCContentFilter(display: display, including: [card])
            included.includeMenuBar = false
            let windows = included.includedWindows.map(\.windowID)
            let displays = included.includedDisplays.map(\.displayID)
            guard CompleteAppQAPolicy.allowsDisplay(displayFacts, card: cardFacts,
                                                     includedDisplayIDs: displays,
                                                     includedWindowIDs: windows) else { return nil }
            return included
        }
    }

    private static func facts(_ window: SCWindow) -> CompleteAppQACardFacts {
        CompleteAppQACardFacts(windowID: window.windowID,
                               ownerBundleID: window.owningApplication?.bundleIdentifier,
                               title: window.title, frame: window.frame)
    }

    private static func facts(_ display: SCDisplay) -> CompleteAppQADisplayFacts {
        CompleteAppQADisplayFacts(displayID: display.displayID, frame: display.frame)
    }
}
#endif
