import Foundation
import Testing
@testable import UtuvoOrbit

/// Orbit is completely free in every build. These tests check the pieces that
/// replaced the old purchase code: the legacy UTUVO Drop adoption marker and
/// the absence of any payment symbol in the shipped source.
///
/// Everything runs on temporary files. The real app group container is never
/// touched.
@MainActor
struct FreeDistributionTests {
    // MARK: - Legacy Drop adoption marker

    @Test func aVersionOneMarkerMeansDropWasUsed() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try write(#"{"version":1,"writtenAt":"2026-05-12T03:04:05Z","unlockJWS":"ignored-receipt"}"#, to: url)
        #expect(DropHandoff.read(from: url).dropWasUsed)
    }

    @Test func anUnknownReceiptFieldIsIgnored() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try write(#"{"version":1,"writtenAt":"2026-05-12T03:04:05Z","somethingNew":{"a":1}}"#, to: url)
        #expect(DropHandoff.read(from: url).dropWasUsed)
    }

    @Test func aMissingMarkerMeansNo() {
        #expect(DropHandoff.read(from: nil).dropWasUsed == false)
        #expect(DropHandoff.read(from: temporaryFile()).dropWasUsed == false)
    }

    @Test func aCorruptMarkerMeansNo() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("this is not json", to: url)
        #expect(DropHandoff.read(from: url).dropWasUsed == false)
    }

    @Test func anUnsupportedVersionMeansNo() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try write(#"{"version":2,"writtenAt":"2026-05-12T03:04:05Z"}"#, to: url)
        #expect(DropHandoff.read(from: url).dropWasUsed == false)
    }

    @Test func anOversizedMarkerMeansNo() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let padding = String(repeating: "x", count: DropHandoff.maxRecordBytes + 1)
        try write(#"{"version":1,"writtenAt":"2026-05-12T03:04:05Z","pad":"\#(padding)"}"#, to: url)
        #expect(DropHandoff.read(from: url).dropWasUsed == false)
    }

    @Test func theMarkerIsOnlyReadAndNeverWritten() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let original = #"{"version":1,"writtenAt":"2026-05-12T03:04:05Z"}"#
        try write(original, to: url)
        _ = DropHandoff.read(from: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == original)
    }

    @Test func theAppGroupIsUnchangedSoTheExistingRecordIsFound() {
        #expect(DropHandoff.appGroup == "RPNT54P79S.app.utuvo.handoff")
        #expect(DropHandoff.fileName == "drop-handoff.json")
        #expect(DropHandoff.supportedVersion == 1)
    }

    // MARK: - No purchase code is left

    @Test func noPaymentSymbolSurvivesInTheShippedSource() throws {
        let markers = ["UTUVOStore", "UTUVOPaywall", "OrbitPaywallWindowController",
                       "trialProductID", "unlockProductID", "product.purchase(",
                       "Transaction.currentEntitlements", "mas-qa-full-access",
                       "OrbitMAS.allowsPanel", "import StoreKit"]
        let root = repositoryRoot
        var hits: [String] = []
        for folder in ["Sources", "MAS"] {
            let directory = root.appendingPathComponent(folder)
            for file in swiftFiles(in: directory) {
                let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                for marker in markers where text.contains(marker) {
                    hits.append("\(file.path.replacingOccurrences(of: root.path + "/", with: "")): \(marker)")
                }
            }
        }
        #expect(hits.isEmpty, "payment symbols are still in the source: \(hits)")
    }

    // MARK: - Preview file reads

    @Test func theDefaultPreviewRefusesFileReads() {
        let model = FileIntegrityModel(preview: true)
        #expect(model.addFiles([URL(fileURLWithPath: "/tmp/orbit-free-distribution.txt")]) == false)
        #expect(model.files.isEmpty)
    }

    @Test func anExplicitlyOptedInModelReadsTheChosenFile() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("abc", to: url)
        // The opted-in preview model: file reads are allowed, everything else
        // stays a fake.
        let model = FileIntegrityModel(preview: false)
        #expect(model.addFiles([url]))
        await model.compute()
        #expect(model.results.count == 1)
        #expect(model.results.first?.digest == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    // MARK: - Helpers

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func swiftFiles(in directory: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        var files: [URL] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            files.append(url)
        }
        return files
    }

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("OrbitFreeDistribution-\(UUID().uuidString).json")
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }
}
