import AppKit
import Testing
@testable import ClotheslineKit

/// OCR now runs in-process (the App Store build ships no helper executable).
/// Renders known text into a synthetic PNG and reads it back.
@Test func inProcessOCRReadsRenderedText() async throws {
    let size = NSSize(width: 900, height: 220)
    let image = NSImage(size: size, flipped: false) { rect in
        NSColor.white.setFill(); rect.fill()
        ("UTUVO Orbit 2026" as NSString).draw(at: NSPoint(x: 40, y: 80),
            withAttributes: [.font: NSFont.systemFont(ofSize: 72, weight: .semibold), .foregroundColor: NSColor.black])
        return true
    }
    let tiff = try #require(image.tiffRepresentation)
    let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-ocr-\(UUID()).png")
    try png.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let text = try await OCR.recognize(url)
    #expect(text.contains("UTUVO"))
    #expect(text.contains("2026"))
}

@Test func blankImageYieldsEmptyText() async throws {
    let image = NSImage(size: NSSize(width: 200, height: 200), flipped: false) { rect in
        NSColor.white.setFill(); rect.fill(); return true
    }
    let tiff = try #require(image.tiffRepresentation)
    let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-ocr-blank-\(UUID()).png")
    try png.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(try await OCR.recognize(url).isEmpty)
}
