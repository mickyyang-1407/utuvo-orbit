import Foundation
import CoreGraphics
import Testing
@testable import ClotheslineKit

struct ScreenshotEditingTests {
    @MainActor @Test func explicitClotheslineCopyPreservesSourceEvenWhenDesktopCleanupIsOn() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "orbit.screenshot.handoff.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ClotheslineSettings(defaults: defaults, isSandboxed: true)
        settings.noDesktop = true
        let source = root.appendingPathComponent("source.png")
        try ScreenshotEditing.writePNG(fixture(), to: source)
        let bytes = try Data(contentsOf: source)
        let model = try Model(root: root.appendingPathComponent("library"), settings: settings)
        defer { model.stop() }
        #expect(model.ingest(source, preserveSource: true))
        #expect(model.captures.count == 1)
        #expect(try Data(contentsOf: source) == bytes)
    }
    private func fixture() throws -> CGImage {
        var bytes = [UInt8]()
        for y in 0..<80 { for _ in 0..<120 { bytes += y < 40 ? [255, 40, 20, 255] : [20, 40, 255, 255] } }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(CGImage(width: 120, height: 80, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 480,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let bytes = try #require(image.dataProvider?.data) as Data
        let offset = y * image.bytesPerRow + x * 4
        return Array(bytes[offset..<(offset + 4)])
    }

    @Test func cropUsesTopLeftPixelsAndSupportsReverseDrag() throws {
        let image = try fixture()
        let edit = ScreenshotEdit(tool: .crop, start: .init(x: 0.75, y: 0.25), end: .init(x: 0.25, y: 0))
        let cropped = try ScreenshotEditing.render(image, edits: [edit])
        #expect(cropped.width == 60 && cropped.height == 20)
        #expect(try pixel(cropped, x: 0, y: 0) == [255, 40, 20, 255])
        let retinaRect = try ScreenshotEditing.pixelRect(edit, width: 240, height: 160)
        #expect(retinaRect == CGRect(x: 60, y: 0, width: 120, height: 40))
    }

    @Test func redactionIsOpaqueInFinalPixelsAndOriginalIsUnchanged() throws {
        let image = try fixture(), original = try #require(image.dataProvider?.data) as Data
        let edited = try ScreenshotEditing.render(image, edits: [.init(tool: .redact, start: .init(x: 0.1, y: 0.1), end: .init(x: 0.6, y: 0.3))])
        #expect(try pixel(edited, x: 20, y: 12) == [0, 0, 0, 255])
        #expect(try pixel(edited, x: 20, y: 70) == [20, 40, 255, 255])
        #expect((image.dataProvider?.data as Data?) == original)
    }

    @Test func arrowBoxCropSequenceAndUndoRenderCorrectly() throws {
        let image = try fixture()
        let arrow = ScreenshotEdit(tool: .arrow, start: .init(x: 0.1, y: 0.5), end: .init(x: 0.8, y: 0.5))
        let box = ScreenshotEdit(tool: .rectangle, start: .init(x: 0.1, y: 0.1), end: .init(x: 0.8, y: 0.8))
        let crop = ScreenshotEdit(tool: .crop, start: .zero, end: .init(x: 0.5, y: 0.5))
        let marked = try ScreenshotEditing.render(image, edits: [arrow, box])
        #expect((marked.dataProvider?.data as Data?) != (image.dataProvider?.data as Data?))
        let cropped = try ScreenshotEditing.render(image, edits: [arrow, box, crop])
        #expect(cropped.width == 60 && cropped.height == 40)
        let undone = try ScreenshotEditing.render(image, edits: [])
        #expect(undone.width == 120 && undone.height == 80)
    }

    @Test(arguments: [CGPoint(x: .nan, y: 0.5), CGPoint(x: -0.1, y: 0.1), CGPoint(x: 0.5, y: 0.5)])
    func invalidSelectionsDoNotProduceAnImage(point: CGPoint) throws {
        let image = try fixture()
        #expect(throws: ScreenshotEditError.self) {
            try ScreenshotEditing.render(image, edits: [.init(tool: .crop, start: point, end: .init(x: 0.5, y: 0.5))])
        }
    }

    @Test func pngExportRoundTripsAndRefusesOverwrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("copy.png"), image = try fixture()
        try ScreenshotEditing.writePNG(image, to: file)
        let data = try Data(contentsOf: file), loaded = try ScreenshotEditing.load(file)
        #expect(loaded.width == 120 && loaded.height == 80)
        #expect(throws: ScreenshotEditError.self) { try ScreenshotEditing.writePNG(image, to: file) }
        #expect(try Data(contentsOf: file) == data)
    }
}
