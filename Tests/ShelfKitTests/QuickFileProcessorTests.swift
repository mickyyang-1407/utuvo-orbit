import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import Testing
import AppKit
@testable import ShelfKit

struct QuickFileProcessorTests {
    @MainActor @Test func dropsMergeDeduplicateAndRemoveReferencesWithoutTouchingFiles() async throws {
        let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("note.txt"); try Data("fixture".utf8).write(to: file)
        let model = QuickFileToolsModel(copyText: { _ in })
        model.setFiles([file, file]); #expect(model.files.count == 1)
        let provider = NSItemProvider(item: file as NSURL, typeIdentifier: UTType.fileURL.identifier)
        #expect(model.acceptDrop([provider]))
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while model.busy && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(!model.busy && model.files.count == 1)
        model.removeFile(file); #expect(model.files.isEmpty)
        #expect(try Data(contentsOf: file) == Data("fixture".utf8))
    }
    @MainActor @Test func copyPathsUsesInjectedClipboardAndKeepsFileReferences() {
        var copied = ""
        let model = QuickFileToolsModel(copyText: { copied = $0 })
        let urls = [URL(fileURLWithPath: "/fixture/a.png"), URL(fileURLWithPath: "/fixture/b.txt")]
        model.setFiles(urls); model.copyPaths()
        #expect(copied == "/fixture/a.png\n/fixture/b.txt")
        #expect(model.files == urls)
        #expect(model.message != nil)
    }
    @Test func duplicateNamesExportToDistinctFilesAndPreserveSources() throws {
        let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b"), dest = root.appendingPathComponent("export")
        for url in [a,b,dest] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
        let first = a.appendingPathComponent("same.png"), second = b.appendingPathComponent("SAME.png")
        try image(first, width: 64, height: 32); try image(second, width: 40, height: 20)
        let originals = try [Data(contentsOf: first), Data(contentsOf: second)]
        let out = try QuickFileProcessor.process([first,second], operation: .jpeg, destination: dest)
        let exports = try FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)
        #expect(exports.count == 2)
        #expect(Set(exports.map { $0.lastPathComponent.lowercased() }).count == 2)
        #expect(try Data(contentsOf: first) == originals[0])
        #expect(try Data(contentsOf: second) == originals[1])
        for url in exports { #expect(CGImageSourceGetType(try #require(CGImageSourceCreateWithURL(url as CFURL,nil))) as String? == UTType.jpeg.identifier) }
    }

    @Test func resizeDoesNotUpscaleAndHonorsOrientation() throws {
        let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let large = root.appendingPathComponent("large.png"), small = root.appendingPathComponent("small.png")
        try image(large, width: 2400, height: 1200); try image(small, width: 64, height: 32)
        let out = try QuickFileProcessor.process([large,small], operation: .resize, destination: root)
        #expect(try dimensions(out.appendingPathComponent("large.png")) == [1600,800])
        #expect(try dimensions(out.appendingPathComponent("small.png")) == [64,32])
        let rotated = root.appendingPathComponent("rotated.jpg")
        try image(rotated, width: 40, height: 20, orientation: 6)
        let upright = try QuickFileProcessor.process([rotated], operation: .png, destination: root)
        #expect(try dimensions(upright.appendingPathComponent("rotated.png")) == [20,40])
    }

    @Test func transparentJPEGBecomesWhite() throws {
        let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("transparent.png")
        try image(source, width: 16, height: 16)
        let out = try QuickFileProcessor.process([source], operation: .jpeg, destination: root)
        let decoded = try #require(CGImageSourceCreateWithURL(out.appendingPathComponent("transparent.jpg") as CFURL,nil))
        let bitmap = try #require(CGImageSourceCreateImageAtIndex(decoded,0,nil))
        let context = try #require(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(bitmap, in: CGRect(x: 0, y: 0, width: 16, height: 16))
        let pixel = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        #expect(pixel[0] >= 245 && pixel[1] >= 245 && pixel[2] >= 245)
    }

    @Test func zipRoundTripKeepsFilesAndFailureLeavesNoPartialExport() throws {
        let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt"); try Data("original".utf8).write(to: source)
        let out = try QuickFileProcessor.process([source], operation: .zip, destination: root)
        let unpacked = root.appendingPathComponent("unpacked")
        let unzip = Process(); unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x","-k",out.appendingPathComponent("Orbit Files.zip").path,unpacked.path]
        try unzip.run(); unzip.waitUntilExit()
        #expect(unzip.terminationStatus == 0)
        #expect(try Data(contentsOf: unpacked.appendingPathComponent("source.txt")) == Data("original".utf8))
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(throws: QuickFileError.self) { _ = try QuickFileProcessor.process([source], operation: .png, destination: root) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == before)
        #expect(try Data(contentsOf: source) == Data("original".utf8))
        #expect(throws: QuickFileError.destinationInsideSource) {
            _ = try QuickFileProcessor.process([root], operation: .zip, destination: root)
        }
    }

    private func fixtureRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-files-tests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false); return url
    }
    private func image(_ url: URL, width: Int, height: Int, orientation: Int = 1) throws {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let cg = try #require(context.makeImage())
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL,(url.pathExtension == "jpg" ? UTType.jpeg.identifier : UTType.png.identifier) as CFString,1,nil))
        CGImageDestinationAddImage(dest,cg,[kCGImagePropertyOrientation:orientation] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
    }
    private func dimensions(_ url: URL) throws -> [Int] {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL,nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any])
        return [try #require(properties[kCGImagePropertyPixelWidth] as? Int),try #require(properties[kCGImagePropertyPixelHeight] as? Int)]
    }
}
