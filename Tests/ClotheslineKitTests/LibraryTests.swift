import Foundation
import Testing
import Darwin
@testable import ClotheslineKit

private func fixture() throws -> (URL, URL, CaptureLibrary) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LineDry-test-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("synthetic.png")
    try Data("synthetic test data, never a user's screenshot".utf8).write(to: source)
    return (root, source, try CaptureLibrary(root: root.appendingPathComponent("managed")))
}

@Test func sourceIsPreservedUntilExplicitDisposition() throws {
    let (_, source, library) = try fixture()
    let capture = try library.ingest(source)
    #expect(FileManager.default.fileExists(atPath: source.path))
    #expect(try Data(contentsOf: source) == Data(contentsOf: library.url(for: capture)))
    #expect(try CaptureLibrary(root: library.root).captures == [capture])
}

@Test func repeatedEventsDoNotDuplicate() throws {
    let (_, source, library) = try fixture()
    let capture = try library.ingest(source)
    #expect(try library.ingest(source).id == capture.id)
    #expect(library.captures.count == 1)
}

@Test func replacedSourceIsNeverTrashed() throws {
    let (root, source, library) = try fixture()
    let capture = try library.ingest(source)
    try FileManager.default.moveItem(at: source, to: root.appendingPathComponent("old.png"))
    try Data("replacement file".utf8).write(to: source)
    #expect(throws: LibraryError.self) { try library.removeSourceFromDesktop(capture.id) }
    try library.discard(capture.id)
    #expect(try String(contentsOf: source, encoding: .utf8) == "replacement file")
}

@Test func discardMovesManagedFileToRecoverableTrash() throws {
    let (_, source, library) = try fixture()
    let capture = try library.ingest(source)
    let expected = try Data(contentsOf: source)
    let trashed = try #require(try library.discard(capture.id))
    #expect(try Data(contentsOf: trashed) == expected)
    #expect(library.captures.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: source.path))
}

@Test func desktopRemovalRequiresDurableCopy() throws {
    let (_, source, library) = try fixture()
    let capture = try library.ingest(source)
    try library.removeSourceFromDesktop(capture.id)
    #expect(!FileManager.default.fileExists(atPath: source.path))
    #expect(FileManager.default.fileExists(atPath: library.url(for: capture).path))
    #expect(try CaptureLibrary(root: library.root).captures.first?.source == nil)
}

@Test func simulatedRetentionBoundaryAndOff() throws {
    let (_, source, library) = try fixture()
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    try library.ingest(source, at: start)
    #expect(library.clean(days: 0, now: start.addingTimeInterval(10 * 86400)).isEmpty)
    #expect(library.captures.count == 1)
    #expect(library.clean(days: 1, now: start.addingTimeInterval(86399)).isEmpty)
    #expect(library.captures.count == 1)
    #expect(library.clean(days: 1, now: start.addingTimeInterval(86400)).isEmpty)
    #expect(library.captures.isEmpty)
}

@Test func externalCopyDoesNotRemoveCapture() throws {
    let (root, source, library) = try fixture()
    let capture = try library.ingest(source)
    try FileManager.default.copyItem(at: library.url(for: capture), to: root.appendingPathComponent("copy.png"))
    try library.reconcileExternalMove(capture.id)
    #expect(library.captures.count == 1)
    try FileManager.default.moveItem(at: library.url(for: capture), to: root.appendingPathComponent("archive.png"))
    try library.reconcileExternalMove(capture.id)
    #expect(library.captures.isEmpty)
}

@Test func untrackedFilesAreNeverCleaned() throws {
    let (_, source, library) = try fixture()
    let unrelated = library.root.appendingPathComponent("untracked.png")
    try Data("leave this alone".utf8).write(to: unrelated)
    try library.ingest(source, at: Date(timeIntervalSince1970: 0))
    #expect(library.clean(days: 1).isEmpty)
    #expect(try String(contentsOf: unrelated, encoding: .utf8) == "leave this alone")
}

@Test func managedReplacementIsPreserved() throws {
    let (root, source, library) = try fixture()
    let capture = try library.ingest(source)
    let managed = library.url(for: capture)
    try FileManager.default.moveItem(at: managed, to: root.appendingPathComponent("prior.png"))
    try Data("replacement managed file".utf8).write(to: managed)
    #expect(throws: LibraryError.self) { try library.discard(capture.id) }
    #expect(FileManager.default.fileExists(atPath: managed.path))
    #expect(library.captures.count == 1)
}

@Test func symlinksAndForgedManifestAreRejected() throws {
    let (root, source, library) = try fixture()
    let alias = root.appendingPathComponent("alias.png")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
    #expect(throws: LibraryError.self) { try library.ingest(alias) }
    try Data("not a valid JSON manifest".utf8).write(to: library.root.appendingPathComponent("library.json"))
    #expect(throws: LibraryError.self) { try CaptureLibrary(root: library.root) }
    #expect(FileManager.default.fileExists(atPath: source.path))
}

@Test func detectionRequiresMetadataNotFilename() throws {
    let (_, source, _) = try fixture()
    #expect(!CapturePolicy.isSystemScreenshot(source))
    let marker = try PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
    let result = marker.withUnsafeBytes { setxattr(source.path, "com.apple.metadata:kMDItemIsScreenCapture", $0.baseAddress, marker.count, 0, 0) }
    #expect(result == 0)
    #expect(CapturePolicy.isSystemScreenshot(source))
}
