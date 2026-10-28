import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Formats the file shelf can convert to / from.
enum ImageFormat: String, CaseIterable, Identifiable {
    case heic, png, jpeg, tiff, pdf

    var id: String { rawValue }

    var title: String {
        switch self {
        case .heic: return "HEIC"
        case .png:  return "PNG"
        case .jpeg: return "JPEG"
        case .tiff: return "TIFF"
        case .pdf:  return "PDF"
        }
    }

    var fileExtension: String {
        switch self {
        case .heic: return "heic"
        case .png:  return "png"
        case .jpeg: return "jpg"
        case .tiff: return "tiff"
        case .pdf:  return "pdf"
        }
    }

    var utType: UTType {
        switch self {
        case .heic: return .heic
        case .png:  return .png
        case .jpeg: return .jpeg
        case .tiff: return .tiff
        case .pdf:  return .pdf
        }
    }

    /// The format a file already has (nil for anything else, e.g. GIF or RAW).
    init?(url: URL) {
        switch url.pathExtension.lowercased() {
        case "heic", "heif": self = .heic
        case "png":          self = .png
        case "jpg", "jpeg":  self = .jpeg
        case "tif", "tiff":  self = .tiff
        case "pdf":          self = .pdf
        default: return nil
        }
    }
}

enum ConversionError: LocalizedError {
    case unreadable
    case encodeFailed(ImageFormat)

    var errorDescription: String? {
        switch self {
        case .unreadable:            return "Couldn't read that file."
        case .encodeFailed(let f):   return "Couldn't create a \(f.title) file."
        }
    }
}

/// Converts images and PDFs completely offline with ImageIO / PDFKit. Nothing leaves the Mac.
/// Results go to a temp folder (cleaned at launch); the originals are never touched.
/// Metadata (EXIF, GPS...) is not copied to the new file.
enum ImageConverter {
    nonisolated static var outputRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("NotchIsland-Converted", isDirectory: true)
    }

    nonisolated static func cleanTemp() {
        try? FileManager.default.removeItem(at: outputRoot)
    }

    /// Any image type ImageIO might know, or a PDF.
    nonisolated static func canConvert(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .pdf)
    }

    /// Blocking: call it off the main thread.
    nonisolated static func convert(_ source: URL, to format: ImageFormat) throws -> URL {
        let image = try loadImage(source)

        // One folder per conversion, so the file keeps a clean name ("photo.jpg") when dragged out.
        let folder = outputRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = source.deletingPathExtension().lastPathComponent
        let output = folder.appendingPathComponent(name).appendingPathExtension(format.fileExtension)

        if format == .pdf {
            try writePDF(image, to: output)
        } else {
            try writeImage(image, as: format, to: output)
        }
        return output
    }

    // MARK: - Reading

    nonisolated private static func loadImage(_ url: URL) throws -> CGImage {
        if UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .pdf) == true {
            return try renderFirstPDFPage(url)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ConversionError.unreadable }

        // The thumbnail call at full size applies the EXIF rotation, so phone photos don't come out sideways.
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let longSide = max(width, height)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: longSide > 0 ? longSide : 16384,
        ]
        if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) { return image }
        if let image = CGImageSourceCreateImageAtIndex(source, 0, nil) { return image }
        throw ConversionError.unreadable
    }

    /// Page 1 of a PDF as a bitmap (about 144 dpi, white background).
    nonisolated private static func renderFirstPDFPage(_ url: URL) throws -> CGImage {
        guard let document = PDFDocument(url: url), let page = document.page(at: 0) else {
            throw ConversionError.unreadable
        }
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0 else { throw ConversionError.unreadable }
        let scale = min(2, 8000 / max(box.width, box.height))
        let size = CGSize(width: box.width * scale, height: box.height * scale)
        let thumb = page.thumbnail(of: size, for: .mediaBox)
        guard let cg = thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ConversionError.unreadable
        }
        return flatten(cg)
    }

    // MARK: - Writing

    nonisolated private static func writeImage(_ image: CGImage, as format: ImageFormat, to output: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL,
                                                               format.utType.identifier as CFString, 1, nil) else {
            throw ConversionError.encodeFailed(format)
        }
        // JPEG has no transparency: put it on white instead of letting it turn black.
        let final = (format == .jpeg && hasAlpha(image)) ? flatten(image) : image
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        CGImageDestinationAddImage(destination, final, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ConversionError.encodeFailed(format) }
    }

    nonisolated private static func writePDF(_ image: CGImage, to output: URL) throws {
        // The page is scaled to a sensible paper size; the full-resolution image is still embedded.
        let longSide = CGFloat(max(image.width, image.height))
        let scale = min(1, 842 / longSide)
        var box = CGRect(x: 0, y: 0, width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        guard let consumer = CGDataConsumer(url: output as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw ConversionError.encodeFailed(.pdf)
        }
        context.beginPDFPage(nil)
        context.draw(image, in: box)
        context.endPDFPage()
        context.closePDF()
    }

    // MARK: - Helpers

    nonisolated private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    nonisolated private static func flatten(_ image: CGImage) -> CGImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage() ?? image
    }
}
