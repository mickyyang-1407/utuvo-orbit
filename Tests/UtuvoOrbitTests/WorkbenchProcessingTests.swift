import AppKit
import ClotheslineKit
import PDFKit
import Testing
@testable import UtuvoOrbit

struct WorkbenchProcessingTests {
    @Test func textTransformsPreserveUnicodeAndRejectMalformedInput() throws {
        let original = "繁體中文 / café? a=1&b=2 🔆"
        #expect(try TextAction.urlDecode.apply(TextAction.urlEncode.apply(original)) == original)
        #expect(try TextAction.base64Decode.apply(TextAction.base64Encode.apply(original)) == original)
        #expect(try TextAction.trimLines.apply("  One  \r\n Two\t") == "One\nTwo")
        #expect(try TextAction.removeEmpty.apply("a\n  \nb\n") == "a\nb")
        #expect(try TextAction.deduplicate.apply("b\na\nb") == "b\na")
        #expect(throws: (any Error).self) { try TextAction.urlDecode.apply("%XY") }
        #expect(throws: (any Error).self) { try TextAction.base64Decode.apply("/w==") }
        #expect(throws: (any Error).self) { try TextAction.json.apply("{broken}") }
        let object = try JSONSerialization.jsonObject(with: Data(TextAction.json.apply("{\"b\":2,\"a\":1}").utf8)) as? [String: Int]
        #expect(object == ["a":1,"b":2])
        #expect(throws: (any Error).self) { try TextAction.lower.apply(String(repeating: "x", count: 1_000_001)) }
    }

    @Test func qrGenerationRoundTripsUnicodeAndHasOpaqueQuietZone() throws {
        let text = "https://utuvo.app/?message=繁體中文&hello=Orbit"
        let image = try QRToolkit.generate(text)
        #expect(try QRToolkit.recognize(image) == [text])
        let data = try QRToolkit.png(image)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        let corner = try #require(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB))
        // Color-space conversion may represent white as 0.99999994.
        #expect(abs(corner.redComponent - 1) < 0.001 && abs(corner.greenComponent - 1) < 0.001 && abs(corner.blueComponent - 1) < 0.001)
        #expect(corner.alphaComponent == 1)
        #expect(throws: (any Error).self) { try QRToolkit.generate("") }
        #expect(throws: (any Error).self) { try QRToolkit.generate(String(repeating: "中", count: 601)) }
    }

    @Test func pdfMergeExtractRotateSplitAndImageConversionKeepOriginals() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit.pdf.tests.\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = PDFDocument()
        for size in [100,200,300] {
            let image = NSImage(size: NSSize(width: size, height: 80), flipped: false) { rect in NSColor.white.setFill(); rect.fill(); return true }
            document.insert(try #require(PDFPage(image: image)), at: document.pageCount)
        }
        let source = try #require(document.dataRepresentation()); let url = root.appendingPathComponent("source.pdf"); try source.write(to: url)
        let merged = try PDFToolkit.process([url, url], action: .merge)
        #expect(PDFDocument(data: merged[0].data)?.pageCount == 6)
        let extracted = try PDFToolkit.process([url], action: .extract, pages: "3,1-2,3")
        let extractDoc = try #require(PDFDocument(data: extracted[0].data))
        #expect(extractDoc.pageCount == 3)
        #expect(extractDoc.page(at: 0)?.bounds(for: .mediaBox).width == 300)
        let rotated = try PDFToolkit.process([url], action: .rotate, pages: "2")
        #expect(PDFDocument(data: rotated[0].data)?.page(at: 0)?.rotation == 90)
        let split = try PDFToolkit.process([url], action: .split)
        #expect(split.count == 3 && split.allSatisfy { PDFDocument(data: $0.data)?.pageCount == 1 })
        #expect(throws: (any Error).self) { try PDFToolkit.process([url], action: .extract, pages: "0,4") }
        #expect(throws: (any Error).self) { try PDFToolkit.process([url,url], action: .rotate) }
        let imageURL = root.appendingPathComponent("fixture.png"); try QRToolkit.png(QRToolkit.generate("Orbit")).write(to: imageURL)
        let imagePDF = try PDFToolkit.process([imageURL], action: .images)
        #expect(PDFDocument(data: imagePDF[0].data)?.pageCount == 1)
        let out1 = try ToolFiles.write(split, to: root), out2 = try ToolFiles.write(split, to: root)
        #expect(out1 != out2 && FileManager.default.fileExists(atPath: out1.appendingPathComponent("Page-001.pdf").path))
        #expect(try Data(contentsOf: url) == source)
    }

    @Test(arguments: ["2-1", "1,,2", "1-2-3", "x", "-1", "4"])
    func invalidPageSelectionsFail(_ value: String) {
        #expect(throws: (any Error).self) { try PDFToolkit.pageIndexes(value, count: 3) }
    }
    @Test func exportFailureRemovesOnlyItsOwnNewFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit.export.tests.\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("keep.txt"); try Data("keep".utf8).write(to: marker)
        #expect(throws: (any Error).self) { try ToolFiles.write([.init(name: "../escape", data: Data())], to: root) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["keep.txt"])
        #expect(try Data(contentsOf: marker) == Data("keep".utf8))
    }
}
