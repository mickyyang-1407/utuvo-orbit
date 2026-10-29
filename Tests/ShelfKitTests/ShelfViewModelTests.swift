import XCTest
@testable import ShelfKit


/// ShelfViewModel's only job is to keep ShelfModel safe across threads — the
/// model itself is not thread-safe. These tests exercise that contract under
/// contention rather than re-asserting the model's pure logic.
final class ShelfViewModelTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelfVM-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
    }

    private func makeFiles(_ count: Int) throws -> [URL] {
        try (0..<count).map { index in
            let url = tempDir.appendingPathComponent("file-\(index).txt")
            try Data("payload-\(index)".utf8).write(to: url)
            return url
        }
    }

    // 1. Disjoint inserts from several threads: every file lands exactly once,
    //    and the count of actually-added URLs adds up to the whole set.
    func testConcurrentDisjointInsertsAllLand() throws {
        let files = try makeFiles(64)
        let viewModel = ShelfViewModel()
        let chunk = 16

        DispatchQueue.concurrentPerform(iterations: files.count / chunk) { batch in
            let slice = Array(files[(batch * chunk)..<((batch + 1) * chunk)])
            _ = viewModel.insert(slice)
        }

        XCTAssertEqual(viewModel.allItems.count, files.count, "no file may be dropped or duplicated under contention")
        XCTAssertEqual(Set(viewModel.allItems.map(\.url)).count, files.count, "keys must be unique")
        XCTAssertTrue(viewModel.allItems.allSatisfy { $0.url.lastPathComponent.hasPrefix("file-") })
    }

    // 2. Everyone inserts the SAME files: dedupe must hold under contention, so
    //    the shelf ends with one entry per file, not one per racing thread.
    func testConcurrentIdenticalInsertsDedupe() throws {
        let files = try makeFiles(24)
        let viewModel = ShelfViewModel()

        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            _ = viewModel.insert(files)
        }

        XCTAssertEqual(viewModel.allItems.count, files.count, "identical concurrent inserts must collapse to one entry each")
        XCTAssertFalse(viewModel.isEmpty)
    }

    // 3. Inserts and clears racing each other must never corrupt the shelf: the
    //    final state is either fully cleared or a subset with unique keys.
    func testConcurrentInsertAndClearStaysConsistent() throws {
        let files = try makeFiles(32)
        let viewModel = ShelfViewModel()

        DispatchQueue.concurrentPerform(iterations: 16) { batch in
            if batch % 2 == 0 { _ = viewModel.insert(files) } else { viewModel.clear() }
        }

        let items = viewModel.allItems
        XCTAssertEqual(Set(items.map(\.url)).count, items.count, "no duplicate keys may survive a clear race")
        XCTAssertTrue(items.allSatisfy { files.map(ShelfModel.normalize).contains($0.url) })
    }

    // 4. isEmpty is observable from any thread and agrees with allItems.
    func testIsEmptyConsistentAcrossThreads() throws {
        let viewModel = ShelfViewModel()
        XCTAssertTrue(viewModel.isEmpty)

        let files = try makeFiles(8)
        _ = viewModel.insert(files)

        let group = DispatchGroup()
        for _ in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                XCTAssertFalse(viewModel.isEmpty)
                group.leave()
            }
        }
        group.wait()

        viewModel.clear()
        XCTAssertTrue(viewModel.isEmpty)
        XCTAssertEqual(viewModel.allItems.count, 0)
    }
}
