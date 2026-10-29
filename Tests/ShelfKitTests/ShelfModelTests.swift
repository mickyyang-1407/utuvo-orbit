import XCTest
@testable import ShelfKit


final class ShelfModelTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("utuvo-drop-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func writeFile(_ name: String, bytes: Int = 10) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        let data = Data(repeating: 0xAB, count: bytes)
        try data.write(to: url)
        return url
    }

    func testInsertAddsAndPreservesOrder() throws {
        let model = ShelfModel()
        let a = try writeFile("a.txt")
        let b = try writeFile("b.txt")
        let c = try writeFile("c.txt")

        let added = model.insert([a, b, c])
        XCTAssertEqual(added.count, 3)
        XCTAssertEqual(model.allItems.map(\.url), [a, b, c].map(ShelfModel.normalize))
    }

    func testInsertDeduplicatesByStandardizedURL() throws {
        let model = ShelfModel()
        let url = try writeFile("foo.txt")

        // Same URL via different prefixes — should still dedupe.
        let duplicate = URL(fileURLWithPath: url.path)
        let withTilde: URL = {
            let home = NSHomeDirectory()
            if url.path.hasPrefix(home) {
                let tail = url.path.dropFirst(home.count)
                return URL(fileURLWithPath: "~" + tail)
            }
            return duplicate
        }()

        let first = model.insert([url])
        let second = model.insert([duplicate, withTilde])
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 0, "re-inserting same logical URL must not duplicate")
        XCTAssertEqual(model.count, 1)
    }

    func testInsertDeduplicatesAcrossSymlinks() throws {
        let model = ShelfModel()
        let real = try writeFile("real.txt")
        let link = tmpDir.appendingPathComponent("link.txt")
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let added = model.insert([real, link])
        XCTAssertEqual(added.count, 1, "symlink pointing at real file must dedupe to one shelf item")
    }

    func testRemoveByURL() throws {
        let model = ShelfModel()
        let a = try writeFile("a.txt")
        let b = try writeFile("b.txt")
        model.insert([a, b])
        XCTAssertTrue(model.remove(a))
        XCTAssertFalse(model.remove(a), "second remove of same URL is a no-op")
        XCTAssertEqual(model.count, 1)
        XCTAssertEqual(model.allItems.first?.url, ShelfModel.normalize(b))
    }

    func testClearEmpties() throws {
        let model = ShelfModel()
        let a = try writeFile("a.txt")
        let b = try writeFile("b.txt")
        model.insert([a, b])
        model.clear()
        XCTAssertTrue(model.isEmpty)
        XCTAssertEqual(model.count, 0)
    }

    func testMissingFileStatus() throws {
        let model = ShelfModel()
        let a = try writeFile("present.txt")
        let b = tmpDir.appendingPathComponent("ghost.txt")
        model.insert([a, b])

        let statuses = model.refreshStaleStatus()
        XCTAssertEqual(statuses[ShelfModel.normalize(a)], .ok)
        XCTAssertEqual(statuses[ShelfModel.normalize(b)], .missing)
    }

    func testByteSizeRecordedOnlyForRegularFiles() throws {
        let model = ShelfModel()
        let f = try writeFile("f.txt", bytes: 42)
        let d = tmpDir.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)

        model.insert([f, d])
        let items = Dictionary(uniqueKeysWithValues: model.allItems.map { ($0.url, $0) })

        XCTAssertEqual(items[ShelfModel.normalize(f)]?.byteSize, 42)
        XCTAssertNil(items[ShelfModel.normalize(d)]?.byteSize)
    }

    func testInsertIgnoresNonFiles() throws {
        // Directories ARE valid drop targets — we keep them. The contract is
        // "any URL is fine as a reference". This test documents that.
        let model = ShelfModel()
        let d = tmpDir.appendingPathComponent("a-folder")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let added = model.insert([d])
        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(model.allItems.first?.displayName, "a-folder")
    }

    func testNormalizeResolvesSymlinks() throws {
        let real = try writeFile("real.txt")
        let link = tmpDir.appendingPathComponent("link.txt")
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertEqual(ShelfModel.normalize(link), ShelfModel.normalize(real))
    }
}
