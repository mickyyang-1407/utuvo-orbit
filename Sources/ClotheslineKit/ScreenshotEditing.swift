import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ScreenshotTool: String, CaseIterable, Identifiable, Codable, Sendable {
    case crop, arrow, rectangle, redact
    public var id: Self { self }
}

/// Points are normalized in the displayed image, with the origin at top-left.
public struct ScreenshotEdit: Codable, Equatable, Sendable {
    public let tool: ScreenshotTool
    public let start: CGPoint
    public let end: CGPoint
    public init(tool: ScreenshotTool, start: CGPoint, end: CGPoint) {
        self.tool = tool; self.start = start; self.end = end
    }
}

public enum ScreenshotEditError: Error { case invalidImage, tooLarge, invalidSelection, exportFailed }

public enum ScreenshotEditing {
    public static func load(_ url: URL) throws -> CGImage {
        guard url.isFileURL,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { throw ScreenshotEditError.invalidImage }
        guard width <= 32768, height <= 32768, Int64(width) * Int64(height) <= 80_000_000 else { throw ScreenshotEditError.tooLarge }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height)
        ] as CFDictionary) else { throw ScreenshotEditError.invalidImage }
        return image
    }

    public static func render(_ original: CGImage, edits: [ScreenshotEdit]) throws -> CGImage {
        guard original.width > 0, original.height > 0, original.width <= 32768, original.height <= 32768,
              Int64(original.width) * Int64(original.height) <= 80_000_000, edits.count <= 32 else { throw ScreenshotEditError.tooLarge }
        var image = original
        for edit in edits { image = try apply(edit, to: image) }
        return image
    }

    public static func pixelRect(_ edit: ScreenshotEdit, width: Int, height: Int) throws -> CGRect {
        let points = [edit.start.x, edit.start.y, edit.end.x, edit.end.y]
        guard width > 0, height > 0, points.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw ScreenshotEditError.invalidSelection }
        let left = floor(min(edit.start.x, edit.end.x) * Double(width))
        let top = floor(min(edit.start.y, edit.end.y) * Double(height))
        let right = ceil(max(edit.start.x, edit.end.x) * Double(width))
        let bottom = ceil(max(edit.start.y, edit.end.y) * Double(height))
        let rect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard rect.width >= 2, rect.height >= 2 else { throw ScreenshotEditError.invalidSelection }
        return rect
    }

    private static func apply(_ edit: ScreenshotEdit, to image: CGImage) throws -> CGImage {
        // Horizontal and vertical arrows are valid, unlike empty crop/box areas.
        let rect: CGRect
        if edit.tool == .arrow {
            guard [edit.start.x, edit.start.y, edit.end.x, edit.end.y].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                  hypot((edit.end.x - edit.start.x) * Double(image.width), (edit.end.y - edit.start.y) * Double(image.height)) >= 3
            else { throw ScreenshotEditError.invalidSelection }
            rect = .zero
        } else { rect = try pixelRect(edit, width: image.width, height: image.height) }
        if edit.tool == .crop {
            guard let cropped = image.cropping(to: rect) else { throw ScreenshotEditError.invalidSelection }
            return cropped
        }
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ScreenshotEditError.exportFailed }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bottomRect = CGRect(x: rect.minX, y: Double(image.height) - rect.maxY, width: rect.width, height: rect.height)
        let line = max(3, Double(min(image.width, image.height)) / 180)
        if edit.tool == .redact {
            // Solid pixels are written into the output; this is not a removable overlay.
            context.setShouldAntialias(false)
            context.setBlendMode(.copy)
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(bottomRect)
        } else {
            context.setStrokeColor(CGColor(red: 0.05, green: 0.55, blue: 0.58, alpha: 1))
            context.setLineWidth(line); context.setLineCap(.round); context.setLineJoin(.round)
            if edit.tool == .rectangle { context.stroke(bottomRect.insetBy(dx: line / 2, dy: line / 2)) }
            else {
                let a = CGPoint(x: edit.start.x * Double(image.width), y: (1 - edit.start.y) * Double(image.height))
                let b = CGPoint(x: edit.end.x * Double(image.width), y: (1 - edit.end.y) * Double(image.height))
                let angle = atan2(b.y - a.y, b.x - a.x), length = min(hypot(b.x - a.x, b.y - a.y) / 3, line * 5)
                context.move(to: a); context.addLine(to: b)
                context.move(to: CGPoint(x: b.x - length * cos(angle - .pi / 6), y: b.y - length * sin(angle - .pi / 6)))
                context.addLine(to: b)
                context.addLine(to: CGPoint(x: b.x - length * cos(angle + .pi / 6), y: b.y - length * sin(angle + .pi / 6)))
                context.strokePath()
            }
        }
        guard let output = context.makeImage() else { throw ScreenshotEditError.exportFailed }
        return output
    }

    public static func writePNG(_ image: CGImage, to url: URL) throws {
        // Callers supply a newly generated private/export path, never a source path.
        guard url.isFileURL, !FileManager.default.fileExists(atPath: url.path),
              let writer = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw ScreenshotEditError.exportFailed }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer) else { throw ScreenshotEditError.exportFailed }
    }
}
