#if DEBUG && ORBIT_COMPLETE_APP_QA
import Darwin
import CoreGraphics
import Foundation
import Testing
import OrbitCore
@testable import UtuvoOrbit

@MainActor
struct CompleteAppQARootTests {
    private func makeParent() throws -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("orbit-complete-qa-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        guard chmod(parent.path, 0o700) == 0 else { throw CompleteAppQAError.invalidRoot }
        return parent
    }

    private func info(root: URL, nonce: String = UUID().uuidString) -> [String: Any] {
        [CompleteAppQARoot.rootInfoKey: root.path, CompleteAppQARoot.nonceInfoKey: nonce]
    }

    private func open(_ root: URL, parent: URL, nonce: String) throws -> CompleteAppQARoot {
        try CompleteAppQARoot.open(bundleIdentifier: CompleteAppQARoot.bundleIdentifier,
                                   info: info(root: root, nonce: nonce),
                                   temporaryDirectory: parent)
    }

    private func expect(_ expected: CompleteAppQAError, operation: () throws -> Void) {
        do {
            try operation()
            Issue.record("Expected \(expected)")
        } catch let error as CompleteAppQAError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private func replace(_ data: Data, at url: URL) throws {
        let fd = url.path.withCString { Darwin.open($0, O_WRONLY | O_TRUNC | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw CompleteAppQAError.invalidMarker }
        defer { close(fd) }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw CompleteAppQAError.invalidMarker }
                offset += count
            }
        }
        guard fchmod(fd, 0o600) == 0, fsync(fd) == 0 else { throw CompleteAppQAError.invalidMarker }
    }

    @Test func sameOwnedRootReopensPreferencesAndToolData() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let nonce = UUID().uuidString.lowercased()
        let url = parent.appendingPathComponent("complete-app", isDirectory: true)
        let first = try open(url, parent: parent, nonce: nonce)
        defer { first.defaults.removePersistentDomain(forName: first.preferencesDomain) }

        let preferences = OrbitPreferencesModel(backend: first.makePreferencesBackend())
        preferences.update { $0.showPercent = true; $0.language = .english }
        let notes = QuickNotesModel(root: first.storeURL(.notes))
        #expect(notes.create(title: "fixture note", body: "saved under QA root"))
        let textReceipt = try first.writeTextReceipt("fixture copy")
        let secondTextReceipt = try first.writeTextReceipt("fixture copy")
        #expect(textReceipt != secondTextReceipt)
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let imageReceipt = try first.writeImageReceipt(context.makeImage()!)

        let reopened = try open(url, parent: parent, nonce: nonce)
        let restored = OrbitPreferencesModel(backend: reopened.makePreferencesBackend())
        #expect(restored.values.showPercent)
        #expect(restored.values.language == .english)
        let restoredNotes = QuickNotesModel(root: reopened.storeURL(.notes))
        #expect(restoredNotes.notes.first?.title == "fixture note")
        #expect(restoredNotes.notes.first?.body == "saved under QA root")
        #expect(try Data(contentsOf: textReceipt) == Data("fixture copy".utf8))
        #expect(try Data(contentsOf: secondTextReceipt) == Data("fixture copy".utf8))
        #expect(Array(try Data(contentsOf: imageReceipt).prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10])
        #expect(reopened.rootURL == first.rootURL)
    }

    @Test func rejectsWrongBundleAndRootOutsideConfiguredTemporaryDirectory() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let url = parent.appendingPathComponent("complete-app", isDirectory: true)
        let nonce = UUID().uuidString
        expect(.invalidConfiguration) {
            _ = try CompleteAppQARoot.open(bundleIdentifier: "com.utuvo.orbit", info: info(root: url, nonce: nonce), temporaryDirectory: parent)
        }
        expect(.invalidRoot) {
            _ = try CompleteAppQARoot.open(bundleIdentifier: CompleteAppQARoot.bundleIdentifier,
                                           info: info(root: parent.deletingLastPathComponent().appendingPathComponent("outside", isDirectory: true), nonce: nonce),
                                           temporaryDirectory: parent)
        }
    }

    @Test func rejectsSymlinkRootAndUnexpectedContents() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let target = parent.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        guard chmod(target.path, 0o700) == 0 else { throw CompleteAppQAError.invalidRoot }
        let alias = parent.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        expect(.invalidRoot) { _ = try open(alias, parent: parent, nonce: UUID().uuidString) }

        let root = parent.appendingPathComponent("owned", isDirectory: true)
        let nonce = UUID().uuidString
        let opened = try open(root, parent: parent, nonce: nonce)
        defer { opened.defaults.removePersistentDomain(forName: opened.preferencesDomain) }
        try Data("unexpected".utf8).write(to: root.appendingPathComponent("extra.txt"))
        expect(.unexpectedContents) { _ = try open(root, parent: parent, nonce: nonce) }
    }

    @Test func rejectsForeignNonceAndOversizedMarker() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("owned", isDirectory: true)
        let nonce = UUID().uuidString.lowercased()
        let opened = try open(root, parent: parent, nonce: nonce)
        defer { opened.defaults.removePersistentDomain(forName: opened.preferencesDomain) }
        let markerURL = root.appendingPathComponent(CompleteAppQARoot.markerName)
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: markerURL)) as? [String: Any])
        object["nonce"] = UUID().uuidString.lowercased()
        try replace(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), at: markerURL)
        expect(.invalidMarker) { _ = try open(root, parent: parent, nonce: nonce) }

        try replace(Data(repeating: 65, count: CompleteAppQARoot.maximumMarkerBytes + 1), at: markerURL)
        expect(.invalidMarker) { _ = try open(root, parent: parent, nonce: nonce) }
    }
}
#endif
