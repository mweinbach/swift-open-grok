// WrapClipboardImage.swift
//
// Host clipboard image paste framing protocol (OSC 999),
// composer pasted image models, and dropped file path classification.
//
// Reference:
//   * crates/codegen/xai-grok-pager/src/wrap_clipboard_image.rs
//   * crates/codegen/xai-grok-pager-render/src/prompt_images.rs

import Foundation
import OpenGrokShared
@_exported import OpenGrokTerminalCore
@_exported import OpenGrokTextArea
#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

// MARK: - Pasted Image Model

/// Representation of an image attached or pasted into the prompt composer.
public struct PastedImage: Sendable, Equatable, Identifiable {
    public var id: ElementId { elementId }
    public var elementId: ElementId
    public var displayNumber: Int
    public var mimeType: String
    public var dimensions: (width: UInt32, height: UInt32)?
    public var byteLen: Int
    public var encodedBytes: Data?
    public var sourcePath: String?
    public var stagedTempPath: String?
    public var sessionImagePath: String?
    public var preview: PromptImagePreview

    public init(
        elementId: ElementId = ElementId(raw: 0),
        displayNumber: Int,
        mimeType: String,
        dimensions: (width: UInt32, height: UInt32)? = nil,
        byteLen: Int,
        encodedBytes: Data? = nil,
        sourcePath: String? = nil,
        stagedTempPath: String? = nil,
        sessionImagePath: String? = nil,
        preview: PromptImagePreview = .pending
    ) {
        self.elementId = elementId
        self.displayNumber = displayNumber
        self.mimeType = mimeType
        self.dimensions = dimensions
        self.byteLen = byteLen
        self.encodedBytes = encodedBytes
        self.sourcePath = sourcePath
        self.stagedTempPath = stagedTempPath
        self.sessionImagePath = sessionImagePath
        self.preview = preview
    }

    public static func == (lhs: PastedImage, rhs: PastedImage) -> Bool {
        lhs.elementId == rhs.elementId
            && lhs.displayNumber == rhs.displayNumber
            && lhs.mimeType == rhs.mimeType
            && lhs.dimensions?.width == rhs.dimensions?.width
            && lhs.dimensions?.height == rhs.dimensions?.height
            && lhs.byteLen == rhs.byteLen
            && lhs.encodedBytes == rhs.encodedBytes
            && lhs.sourcePath == rhs.sourcePath
            && lhs.stagedTempPath == rhs.stagedTempPath
            && lhs.sessionImagePath == rhs.sessionImagePath
            && lhs.preview == rhs.preview
    }
}

/// Preview rendering state for an image in the prompt composer.
public enum PromptImagePreview: Sendable, Equatable {
    case pending
    case available(cols: UInt16, rows: UInt16)
    case unsupported
    case failed
}

/// Display string formatted for composer chip representation (`[Image #N]`).
public func displayText(displayNumber: Int) -> String {
    "[Image #\(displayNumber)]"
}

// MARK: - MIME & Extension Mapping

private let mimeExtensions: [String: String] = [
    "image/png": "png",
    "image/jpeg": "jpg",
    "image/jpg": "jpg",
    "image/webp": "webp",
    "image/gif": "gif",
    "image/bmp": "bmp",
    "image/tiff": "tiff",
    "image/heic": "heic",
    "image/heif": "heif",
    "image/svg+xml": "svg",
    "image/x-icon": "ico",
    "image/avif": "avif"
]

private let extensionMimes: [String: String] = [
    "png": "image/png",
    "jpg": "image/jpeg",
    "jpeg": "image/jpeg",
    "webp": "image/webp",
    "gif": "image/gif",
    "bmp": "image/bmp",
    "tiff": "image/tiff",
    "tif": "image/tiff",
    "heic": "image/heic",
    "heif": "image/heif",
    "svg": "image/svg+xml",
    "ico": "image/x-icon",
    "avif": "image/avif"
]

public func extensionForMime(_ mime: String) -> String {
    mimeExtensions[mime.lowercased()] ?? "png"
}

public func mimeForExtension(_ ext: String) -> String {
    extensionMimes[ext.lowercased()] ?? "image/png"
}

public func isImageExtension(_ ext: String) -> Bool {
    extensionMimes[ext.lowercased()] != nil
}

// MARK: - Image Recompression & Quality Step-down

/// Fit image into MAX_WRAP_IMAGE_BYTES budget using JPEG quality step-down [85, 70, 55, 40, 25]
/// and half-resolution thumbnail fallback at quality 60.
public func fitImageForWrap(_ img: ClipboardImageData) -> (mime: String, data: Data)? {
    if !img.data.isEmpty && img.data.count <= MAX_WRAP_IMAGE_BYTES {
        return (img.mimeType, img.data)
    }

    #if canImport(CoreGraphics) && canImport(ImageIO)
    guard let source = CGImageSourceCreateWithData(img.data as CFData, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        return nil
    }

    let qualities: [CGFloat] = [0.85, 0.70, 0.55, 0.40, 0.25]
    for q in qualities {
        let destData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            destData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { continue }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: q
        ]
        CGImageDestinationAddImage(dest, cgImage, options as CFDictionary)
        if CGImageDestinationFinalize(dest) {
            let resultData = destData as Data
            if resultData.count <= MAX_WRAP_IMAGE_BYTES {
                return ("image/jpeg", resultData)
            }
        }
    }

    // Half-resolution thumbnail fallback at quality 60
    let halfWidth = max(1, cgImage.width / 2)
    let halfHeight = max(1, cgImage.height / 2)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: halfWidth,
        height: halfHeight,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return nil
    }

    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: halfWidth, height: halfHeight))
    guard let thumbnail = context.makeImage() else { return nil }

    let thumbData = NSMutableData()
    guard let thumbDest = CGImageDestinationCreateWithData(
        thumbData,
        UTType.jpeg.identifier as CFString,
        1,
        nil
    ) else {
        return nil
    }

    let thumbOptions: [CFString: Any] = [
        kCGImageDestinationLossyCompressionQuality: 0.60
    ]
    CGImageDestinationAddImage(thumbDest, thumbnail, thumbOptions as CFDictionary)
    if CGImageDestinationFinalize(thumbDest) {
        let resultData = thumbData as Data
        if resultData.count <= MAX_WRAP_IMAGE_BYTES {
            return ("image/jpeg", resultData)
        }
    }
    return nil
    #else
    return nil
    #endif
}

/// Encode image response wrapped in bracketed paste escape sequences.
public func encodeWrapImageResponse(image: ClipboardImageData?) -> Data {
    let startPaste = "\u{1b}[200~"
    let endPaste = "\u{1b}[201~"

    guard let image = image, let fitted = fitImageForWrap(image) else {
        let raw = "\(startPaste)\(MAGIC_NONE)\(endPaste)"
        return Data(raw.utf8)
    }

    let payload = "\(MAGIC_IMG)\n\(fitted.mime)\n\(fitted.data.base64EncodedString())"
    let raw = "\(startPaste)\(payload)\(endPaste)"
    return Data(raw.utf8)
}

/// Decode paste payload for wrap host image.
public func tryDecodeWrapHostImagePaste(text: String) -> WrapImagePaste? {
    decodeWrapImagePaste(payload: text)
}

/// Request wrap clipboard image on paste miss if OSC 52 sink is active and no local attachments exist.
@discardableResult
public func maybeRequestWrapHostImage(
    sinkActive: Bool,
    localImage: Bool,
    localText: Bool,
    localFileURLs: Bool,
    emit: ([UInt8]) -> Void
) -> Bool {
    guard sinkActive && !localImage && !localText && !localFileURLs else {
        return false
    }
    emit(requestOscBytes())
    return true
}

// MARK: - Dropped Path Classification

/// A filesystem path detected from terminal drag-and-drop text.
public struct DroppedPath: Sendable, Equatable {
    public var path: String
    public var isImage: Bool

    public init(path: String, isImage: Bool) {
        self.path = path
        self.isImage = isImage
    }
}

/// Try to parse dropped file paths from dropped/pasted text string.
public func tryReadDroppedPaths(
    text: String,
    fileManager: FileManager = .default
) -> [DroppedPath] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }

    // Normalize file:// URLs
    var lines: [String] = []
    for line in trimmed.split(whereSeparator: \.isNewline) {
        let cleaned = String(line).trimmingCharacters(in: .whitespaces)
        if cleaned.hasPrefix("file://") {
            if let url = URL(string: cleaned), url.isFileURL {
                lines.append(url.path)
            } else {
                lines.append(String(cleaned.dropFirst(7)))
            }
        } else {
            lines.append(cleaned)
        }
    }

    var result: [DroppedPath] = []
    for line in lines {
        // Unescape backslash-escaped spaces if present
        let unescaped = line.replacingOccurrences(of: "\\ ", with: " ")
        let expanded = (unescaped as NSString).expandingTildeInPath
        if fileManager.fileExists(atPath: expanded) {
            let ext = (expanded as NSString).pathExtension
            let isImg = isImageExtension(ext)
            result.append(DroppedPath(path: expanded, isImage: isImg))
        } else if fileManager.fileExists(atPath: line) {
            let ext = (line as NSString).pathExtension
            let isImg = isImageExtension(ext)
            result.append(DroppedPath(path: line, isImage: isImg))
        }
    }
    return result
}

/// Try to load a PastedImage from a local file path if it exists and is an image.
public func tryReadImageFromPath(
    text: String,
    fileManager: FileManager = .default
) -> PastedImage? {
    let unescaped = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\ ", with: " ")
    let expanded = (unescaped as NSString).expandingTildeInPath

    guard fileManager.fileExists(atPath: expanded) else { return nil }
    let ext = (expanded as NSString).pathExtension.lowercased()
    guard isImageExtension(ext) else { return nil }

    guard let data = try? Data(contentsOf: URL(fileURLWithPath: expanded)), !data.isEmpty else {
        return nil
    }

    var dimensions: (width: UInt32, height: UInt32)? = nil
    #if canImport(CoreGraphics) && canImport(ImageIO)
    if let source = CGImageSourceCreateWithData(data as CFData, nil),
       let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
        if let width = properties[kCGImagePropertyPixelWidth] as? UInt32,
           let height = properties[kCGImagePropertyPixelHeight] as? UInt32 {
            dimensions = (width, height)
        }
    }
    #endif

    return PastedImage(
        displayNumber: 1,
        mimeType: mimeForExtension(ext),
        dimensions: dimensions,
        byteLen: data.count,
        encodedBytes: data,
        sourcePath: expanded,
        preview: .pending
    )
}

/// Parse dropped text and extract all images as PastedImages.
public func tryReadImagesFromPaste(
    text: String,
    fileManager: FileManager = .default
) -> [PastedImage] {
    let dropped = tryReadDroppedPaths(text: text, fileManager: fileManager)
    var images: [PastedImage] = []
    for item in dropped where item.isImage {
        if let img = tryReadImageFromPath(text: item.path, fileManager: fileManager) {
            images.append(img)
        }
    }
    return images
}

// MARK: - Pasted Image Lifecycle & Reconciliation

/// Reconcile pasted images list against active textarea ElementIds.
/// Cleans up staged temp files for any removed images.
public func reconcile(
    images: inout [PastedImage],
    liveIds: Set<ElementId>,
    fileManager: FileManager = .default
) {
    var kept: [PastedImage] = []
    for img in images {
        if liveIds.contains(img.elementId) {
            kept.append(img)
        } else {
            cleanupTempFile(image: img, fileManager: fileManager)
        }
    }
    images = kept
}

/// Drain and return all pasted images from tracking array.
public func drainAndCleanup(images: inout [PastedImage]) -> [PastedImage] {
    let drained = images
    images.removeAll()
    return drained
}

/// Reset the sequential image counter to 0.
public func resetCounter(imageCounter: inout Int) {
    imageCounter = 0
}

/// Clear all tracked images, clean up their temp files, and reset counter.
public func clear(
    images: inout [PastedImage],
    imageCounter: inout Int,
    fileManager: FileManager = .default
) {
    for img in images {
        cleanupTempFile(image: img, fileManager: fileManager)
    }
    images.removeAll()
    imageCounter = 0
}

/// Remove staged temporary file for a pasted image if present.
public func cleanupTempFile(
    image: PastedImage,
    fileManager: FileManager = .default
) {
    guard let path = image.stagedTempPath, !path.isEmpty else { return }
    try? fileManager.removeItem(atPath: path)
}
