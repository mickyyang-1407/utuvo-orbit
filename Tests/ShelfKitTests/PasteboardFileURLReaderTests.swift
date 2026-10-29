import XCTest
@testable import ShelfKit
#if canImport(AppKit)
import AppKit


final class PasteboardFileURLReaderTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("utuvo-drop-pb-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func writeFile(_ name: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try Data([0x01]).write(to: url)
        return url
    }

    func testReadsMultipleFileURLs() throws {
        let a = try writeFile("a.txt")
        let b = try writeFile("b.txt")

        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        XCTAssertTrue(pb.writeObjects([a as NSURL, b as NSURL]))

        let reader = PasteboardFileURLReader()
        XCTAssertTrue(reader.canReadFileURLs(pb))
        let urls = reader.readFileURLs(from: pb)
        XCTAssertEqual(urls.count, 2)
        XCTAssertTrue(urls.contains(a))
        XCTAssertTrue(urls.contains(b))
    }

    func testEmptyPasteboardYieldsEmpty() {
        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        let reader = PasteboardFileURLReader()
        XCTAssertFalse(reader.canReadFileURLs(pb))
        XCTAssertEqual(reader.readFileURLs(from: pb), [])
    }

    func testTextOnlyPasteboardYieldsEmpty() {
        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        pb.setString("hello world", forType: .string)
        let reader = PasteboardFileURLReader()
        XCTAssertFalse(reader.canReadFileURLs(pb))
        XCTAssertEqual(reader.readFileURLs(from: pb), [])
    }
}
#endif
