import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum QuickFileOperation: String, CaseIterable, Sendable {
    case zip, png, jpeg, resize
}

public enum QuickFileError: Error, Equatable {
    case noFiles
    case unreadable(String)
    case notImage(String)
    case tooLarge(String)
    case exportFailed
    case destinationInsideSource
}

public enum QuickFileProcessor {
    /// Each job owns one new directory. Existing files are never destinations.
    public static func process(_ urls: [URL], operation: QuickFileOperation, destination: URL) throws -> URL {
        guard !urls.isEmpty else { throw QuickFileError.noFiles }
        guard destination.isFileURL else { throw QuickFileError.exportFailed }
        let files = Array(NSOrderedSet(array: urls).array.compactMap { $0 as? URL })
        for url in files {
            guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
                  FileManager.default.isReadableFile(atPath: url.path) else { throw QuickFileError.unreadable(url.lastPathComponent) }
            let attributes = try url.resourceValues(forKeys: [.isDirectoryKey])
            let sourcePath = url.resolvingSymlinksInPath().standardizedFileURL.path
            let destinationPath = destination.resolvingSymlinksInPath().standardizedFileURL.path
            if attributes.isDirectory == true,
               destinationPath == sourcePath || destinationPath.hasPrefix(sourcePath + "/") { throw QuickFileError.destinationInsideSource }
            if operation != .zip { _ = try imageSource(url) }
        }
        let output = destination.appendingPathComponent("Orbit Export \(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        do {
            if operation == .zip {
                let staging = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-archive-\(UUID())", isDirectory: true)
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
                defer { try? FileManager.default.removeItem(at: staging) }
                var used = Set<String>()
                for file in files {
                    let name = uniqueName(file.lastPathComponent, used: &used)
                    try FileManager.default.copyItem(at: file, to: staging.appendingPathComponent(name))
                }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                process.arguments = ["-c", "-k", "--sequesterRsrc", staging.path, output.appendingPathComponent("Orbit Files.zip").path]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run(); process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw QuickFileError.exportFailed }
            } else {
                var used = Set<String>()
                for file in files {
                    let source = try imageSource(file)
                    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
                    let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
                    let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
                    let edge = operation == .resize ? min(1600, max(width, height)) : max(width, height)
                    guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: max(1, edge)
                    ] as CFDictionary) else { throw QuickFileError.notImage(file.lastPathComponent) }
                    let isJPEG = operation == .jpeg
                    let image = isJPEG ? try flattened(thumbnail) : thumbnail
                    let name = uniqueName(file.deletingPathExtension().lastPathComponent + (isJPEG ? ".jpg" : ".png"), used: &used)
                    guard let writer = CGImageDestinationCreateWithURL(output.appendingPathComponent(name) as CFURL,
                                                                       (isJPEG ? UTType.jpeg.identifier : UTType.png.identifier) as CFString, 1, nil) else { throw QuickFileError.exportFailed }
                    CGImageDestinationAddImage(writer, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
                    guard CGImageDestinationFinalize(writer) else { throw QuickFileError.exportFailed }
                }
            }
            return output
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    private static func imageSource(_ url: URL) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value,
              width > 0, height > 0 else { throw QuickFileError.notImage(url.lastPathComponent) }
        guard width <= 32768, height <= 32768, width * height <= 80_000_000 else { throw QuickFileError.tooLarge(url.lastPathComponent) }
        return source
    }

    private static func flattened(_ image: CGImage) throws -> CGImage {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw QuickFileError.exportFailed }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let result = context.makeImage() else { throw QuickFileError.exportFailed }
        return result
    }

    private static func uniqueName(_ name: String, used: inout Set<String>) -> String {
        var result = name, index = 2
        let url = URL(fileURLWithPath: name), ext = url.pathExtension
        while used.contains(result.lowercased()) {
            result = url.deletingPathExtension().lastPathComponent + " (\(index))" + (ext.isEmpty ? "" : "." + ext)
            index += 1
        }
        used.insert(result.lowercased()); return result
    }
}
