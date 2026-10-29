import AppKit
import ClotheslineKit
import CoreImage.CIFilterBuiltins
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

enum TextAction: String, CaseIterable, Identifiable {
    case trimLines, removeEmpty, deduplicate, upper, lower, json, urlEncode, urlDecode, base64Encode, base64Decode
    var id: Self { self }
    func title(_ c: ToolCopy) -> String {
        switch self {
        case .trimLines: c("清理每行空白", "Trim lines")
        case .removeEmpty: c("移除空白行", "Remove blank lines")
        case .deduplicate: c("移除重複行", "Deduplicate lines")
        case .upper: c("轉大寫", "UPPERCASE")
        case .lower: c("轉小寫", "lowercase")
        case .json: c("JSON 排版", "Format JSON")
        case .urlEncode: c("URL 編碼", "URL encode")
        case .urlDecode: c("URL 解碼", "URL decode")
        case .base64Encode: c("Base64 編碼", "Base64 encode")
        case .base64Decode: c("Base64 解碼", "Base64 decode")
        }
    }
    func apply(_ input: String) throws -> String {
        guard input.utf8.count <= 1_000_000 else { throw WorkbenchError.invalid("Text exceeds 1 MB / 文字超過 1 MB") }
        let lines = input.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        switch self {
        case .trimLines: return lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
        case .removeEmpty: return lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n")
        case .deduplicate:
            var seen = Set<String>(); return lines.filter { seen.insert($0).inserted }.joined(separator: "\n")
        case .upper: return input.uppercased(with: Locale(identifier: "en_US_POSIX"))
        case .lower: return input.lowercased(with: Locale(identifier: "en_US_POSIX"))
        case .json:
            let object = try JSONSerialization.jsonObject(with: Data(input.utf8), options: .fragmentsAllowed)
            return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self)
        case .urlEncode:
            return input.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? input
        case .urlDecode:
            guard let result = input.removingPercentEncoding else { throw WorkbenchError.invalid("Invalid URL encoding / URL 編碼不完整") }; return result
        case .base64Encode: return Data(input.utf8).base64EncodedString()
        case .base64Decode:
            guard let data = Data(base64Encoded: input.trimmingCharacters(in: .whitespacesAndNewlines)), let result = String(data: data, encoding: .utf8) else {
                throw WorkbenchError.invalid("Invalid UTF-8 Base64 / 不是有效的 UTF-8 Base64")
            }; return result
        }
    }
}

enum QRToolkit {
    static func generate(_ text: String) throws -> CGImage {
        guard !text.isEmpty, text.utf8.count <= 1800 else { throw WorkbenchError.invalid("QR: 1–1800 UTF-8 bytes / 請輸入 1–1800 bytes 的文字") }
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(text.utf8); filter.correctionLevel = "M"
        guard let image = filter.outputImage,
              let code = CIContext().createCGImage(image, from: image.extent) else { throw CocoaError(.fileReadCorruptFile) }
        // Four-module quiet zone is part of the exported pixels; nearest-neighbour scaling.
        let side = (code.width + 8) * 8
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.coderInvalidValue) }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.interpolationQuality = .none
        context.draw(code, in: CGRect(x: 32, y: 32, width: code.width * 8, height: code.height * 8))
        guard let result = context.makeImage() else { throw CocoaError(.coderInvalidValue) }; return result
    }
    static func recognize(_ image: CGImage) throws -> [String] {
        let request = VNDetectBarcodesRequest(); request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([request])
        var seen = Set<String>()
        return (request.results ?? []).compactMap(\.payloadStringValue).filter { seen.insert($0).inserted }
    }
    static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }; return data as Data
    }
}

enum PDFAction: String, CaseIterable, Identifiable {
    case merge, extract, split, rotate, images
    var id: Self { self }
    func title(_ c: ToolCopy) -> String {
        switch self { case .merge: c("合併 PDF", "Merge PDFs"); case .extract: c("擷取頁面", "Extract pages"); case .split: c("逐頁拆分", "Split pages"); case .rotate: c("旋轉 90°", "Rotate 90°"); case .images: c("圖片轉 PDF", "Images to PDF") }
    }
}

enum PDFToolkit {
    static func pageIndexes(_ value: String, count: Int) throws -> [Int] {
        guard count > 0 else { throw CocoaError(.fileReadCorruptFile) }
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return Array(0..<count) }
        var output: [Int] = []; var seen = Set<Int>()
        for token in value.components(separatedBy: ",") {
            let bounds = token.trimmingCharacters(in: .whitespaces).components(separatedBy: "-")
            guard (1...2).contains(bounds.count), let first = Int(bounds[0]), first >= 1, first <= count,
                  let last = Int(bounds.last!), last >= first, last <= count else {
                throw WorkbenchError.invalid("Invalid pages: use 1-3,5 / 頁碼請填 1-3,5，且不得超出範圍")
            }
            for number in first...last where seen.insert(number - 1).inserted { output.append(number - 1) }
        }
        return output
    }
    static func process(_ urls: [URL], action: PDFAction, pages: String = "") throws -> [ToolExport] {
        guard !urls.isEmpty, urls.count <= 50 else { throw WorkbenchError.invalid("Choose 1–50 files / 請選 1–50 個檔案") }
        var inputBytes: Int64 = 0
        for url in urls {
            try Task.checkCancellation()
            let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard size.isRegularFile == true else { throw CocoaError(.fileReadUnsupportedScheme) }
            inputBytes += Int64(size.fileSize ?? 0)
        }
        guard inputBytes <= 200_000_000 else { throw WorkbenchError.invalid("Inputs exceed 200 MB / 輸入超過 200 MB") }
        let output = PDFDocument()
        func append(_ page: PDFPage) throws {
            guard output.pageCount < 500, let copy = page.copy() as? PDFPage else { throw WorkbenchError.invalid("Limit: 500 pages / 最多 500 頁") }
            output.insert(copy, at: output.pageCount)
        }
        if action == .images {
            for url in urls {
                let image = try ScreenshotEditing.load(url)
                guard let page = PDFPage(image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))) else { throw CocoaError(.fileReadCorruptFile) }
                try append(page)
            }
        } else {
            guard action == .merge || urls.count == 1 else { throw WorkbenchError.invalid("Choose one PDF for this action / 此操作請選一份 PDF") }
            for url in urls {
                guard let document = PDFDocument(url: url), !document.isEncrypted, document.pageCount > 0, document.pageCount <= 500 else {
                    throw WorkbenchError.invalid("Unreadable, encrypted or oversized PDF / PDF 無法讀取、已加密或超過 500 頁")
                }
                let indexes = try pageIndexes(action == .merge ? "" : pages, count: document.pageCount)
                for index in indexes {
                    try Task.checkCancellation()
                    guard let page = document.page(at: index) else { throw CocoaError(.fileReadCorruptFile) }
                    try append(page)
                    if action == .rotate, let copy = output.page(at: output.pageCount - 1) { copy.rotation = (copy.rotation + 90) % 360 }
                }
            }
        }
        if action == .split {
            return try (0..<output.pageCount).map { index in
                let single = PDFDocument()
                guard let page = output.page(at: index)?.copy() as? PDFPage else { throw CocoaError(.fileReadCorruptFile) }
                single.insert(page, at: 0)
                guard let data = single.dataRepresentation() else { throw CocoaError(.fileWriteUnknown) }
                return ToolExport(name: String(format: "Page-%03d.pdf", index + 1), data: data)
            }
        }
        guard let data = output.dataRepresentation() else { throw CocoaError(.fileWriteUnknown) }
        return [ToolExport(name: "Orbit-\(action.rawValue).pdf", data: data)]
    }
}
