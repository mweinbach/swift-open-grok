// ImageNormalize.swift
//
// Image Normalization, Resizing, and Dimension Inspection for Open Grok.
// Downsamples oversized images to fit model and API provider constraints,
// preserves aspect ratios, supports format conversions (PNG, JPEG, WebP, GIF),
// and generates text-only fallback placeholders.
// Port of `crates/codegen/xai-grok-shell/src/session/image_normalize.rs`
// and `crates/codegen/xai-grok-tools/src/util/image_compress.rs`.

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

// MARK: - ImageDimensions

/// 2D Image dimensions (width, height) with aspect ratio and pixel area calculations.
public struct ImageDimensions: Sendable, Codable, Equatable, Hashable, CustomStringConvertible {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = max(0, width)
        self.height = max(0, height)
    }

    /// Aspect ratio (width / height). Returns 0.0 if height <= 0.
    public var aspectRatio: Double {
        guard height > 0 else { return 0.0 }
        return Double(width) / Double(height)
    }

    /// Total pixel count (width * height).
    public var pixelCount: Int {
        width * height
    }

    /// True if either dimension is zero or non-positive.
    public var isEmpty: Bool {
        width <= 0 || height <= 0
    }

    public var description: String {
        "\(width)x\(height)"
    }
}

// MARK: - ImageFormat

/// Supported image formats for normalization and conversion.
public enum ImageFormat: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
    case png = "image/png"
    case jpeg = "image/jpeg"
    case webp = "image/webp"
    case gif = "image/gif"
    case bmp = "image/bmp"
    case tiff = "image/tiff"
    case unknown = "application/octet-stream"

    public var mimeType: String { rawValue }

    public var displayName: String {
        switch self {
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .webp: return "WebP"
        case .gif: return "GIF"
        case .bmp: return "BMP"
        case .tiff: return "TIFF"
        case .unknown: return "Unknown"
        }
    }

    public var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .webp: return "webp"
        case .gif: return "gif"
        case .bmp: return "bmp"
        case .tiff: return "tiff"
        case .unknown: return "bin"
        }
    }

    public static func from(mimeType: String) -> ImageFormat {
        let clean = mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch clean {
        case "image/png": return .png
        case "image/jpeg", "image/jpg": return .jpeg
        case "image/webp": return .webp
        case "image/gif": return .gif
        case "image/bmp": return .bmp
        case "image/tiff", "image/tif": return .tiff
        default: return .unknown
        }
    }

    public static func from(data: Data) -> ImageFormat {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if data.starts(with: [0x47, 0x49, 0x46, 0x38]) { return .gif }
        if data.starts(with: [0x52, 0x49, 0x46, 0x46]) && data.count >= 12 && data[8..<12] == Data("WEBP".utf8) { return .webp }
        if data.starts(with: [0x42, 0x4D]) { return .bmp }
        if data.starts(with: [0x49, 0x49, 0x2A, 0x00]) || data.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return .tiff }
        return .unknown
    }
}

// MARK: - ImageNormalizeOptions

/// Parameters controlling image normalization and downsampling.
public struct ImageNormalizeOptions: Sendable, Codable, Equatable, Hashable {
    /// Maximum dimension (width or height) allowed.
    public var maxSide: Int
    /// Maximum total pixel count (width * height).
    public var maxPixels: Int
    /// Maximum output size in raw bytes.
    public var maxBytes: Int
    /// Minimum side dimension floor.
    public var minSide: Int
    /// Target image format (nil preserves source format if possible).
    public var targetFormat: ImageFormat?
    /// Quality steps to attempt during lossy compression.
    public var qualitySteps: [Double]

    public init(
        maxSide: Int = ImageNormalizer.defaultMaxEncodeSidePx,
        maxPixels: Int = ImageNormalizer.defaultMaxEncodePixels,
        maxBytes: Int = ImageNormalizer.defaultMaxImageBytes,
        minSide: Int = ImageNormalizer.defaultMinEncodeSidePx,
        targetFormat: ImageFormat? = nil,
        qualitySteps: [Double] = [0.88, 0.80, 0.72, 0.64, 0.56, 0.48, 0.40, 0.32]
    ) {
        self.maxSide = maxSide
        self.maxPixels = maxPixels
        self.maxBytes = maxBytes
        self.minSide = minSide
        self.targetFormat = targetFormat
        self.qualitySteps = qualitySteps
    }

    public static let standard = ImageNormalizeOptions()
    public static let strict = ImageNormalizeOptions(maxSide: ImageNormalizer.strictMaxEncodeSidePx)
}

// MARK: - NormalizedImageResult

/// Outcome of an image normalization operation.
public struct NormalizedImageResult: Sendable, Codable, Equatable {
    public let data: Data
    public let dimensions: ImageDimensions
    public let originalDimensions: ImageDimensions
    public let format: ImageFormat
    public let originalFormat: ImageFormat
    public let byteCount: Int
    public let originalByteCount: Int
    public let wasDownsampled: Bool
    public let wasRecompressed: Bool

    public init(
        data: Data,
        dimensions: ImageDimensions,
        originalDimensions: ImageDimensions,
        format: ImageFormat,
        originalFormat: ImageFormat,
        byteCount: Int,
        originalByteCount: Int,
        wasDownsampled: Bool,
        wasRecompressed: Bool
    ) {
        self.data = data
        self.dimensions = dimensions
        self.originalDimensions = originalDimensions
        self.format = format
        self.originalFormat = originalFormat
        self.byteCount = byteCount
        self.originalByteCount = originalByteCount
        self.wasDownsampled = wasDownsampled
        self.wasRecompressed = wasRecompressed
    }

    /// Compression ratio: compressed bytes / original bytes.
    public var compressionRatio: Double {
        guard originalByteCount > 0 else { return 1.0 }
        return Double(byteCount) / Double(originalByteCount)
    }

    public var description: String {
        let verb = wasDownsampled ? "Downscaled" : (wasRecompressed ? "Compressed" : "Unchanged")
        return "\(verb): \(originalByteCount) bytes (\(originalDimensions)) -> \(byteCount) bytes (\(dimensions)) [\(format.displayName)]"
    }
}

// MARK: - ImageNormalizeError

public enum ImageNormalizeError: Error, CustomStringConvertible, Equatable {
    case invalidImageData
    case unsupportedFormat(String)
    case decodeFailed(String)
    case encodeFailed(String)
    case imageTooSmall(width: Int, height: Int)
    case couldNotFitUnderByteCap(maxBytes: Int, lastDimension: ImageDimensions)

    public var description: String {
        switch self {
        case .invalidImageData:
            return "Image data is empty or invalid"
        case .unsupportedFormat(let format):
            return "Unsupported image format: \(format)"
        case .decodeFailed(let reason):
            return "Failed to decode image: \(reason)"
        case .encodeFailed(let reason):
            return "Failed to encode image: \(reason)"
        case .imageTooSmall(let width, let height):
            return "Image dimensions (\(width)x\(height)) are below minimum vision threshold"
        case .couldNotFitUnderByteCap(let maxBytes, let lastDimension):
            return "Could not compress image under \(maxBytes) bytes (last dimensions: \(lastDimension))"
        }
    }
}

// MARK: - ImageNormalizer

/// Image inspection, dimension detection, downsampling, format conversion, and text fallback synthesis.
public enum ImageNormalizer {

    // MARK: Constants matching Rust open-grok caps
    public static let defaultMaxImageBytes: Int = 1_500_000
    public static let defaultMaxEncodePixels: Int = 2_408_448
    public static let defaultMaxEncodeSidePx: Int = 2000
    public static let strictMaxEncodeSidePx: Int = 1024
    public static let defaultMinEncodeSidePx: Int = 512
    public static let defaultMinVisionSidePx: Int = 8
    public static let defaultMinVisionTotalPx: Int = 512
    public static let defaultMaxVisionTotalPx: Int = 178_956_970

    // MARK: - Dimension & Format Detection

    /// Detect the format of the given image data from magic bytes.
    public static func detectFormat(in data: Data) -> ImageFormat {
        ImageFormat.from(data: data)
    }

    /// Inspect raw image bytes and extract dimensions without fully decoding if possible.
    public static func detectDimensions(in data: Data) -> ImageDimensions? {
        guard !data.isEmpty else { return nil }

        // 1. Fast binary header parsing
        if let dims = parseDimensionsFromHeader(data) {
            return dims
        }

        // 2. ImageIO fallback
        #if canImport(ImageIO)
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            if width > 0 && height > 0 {
                return ImageDimensions(width: width, height: height)
            }
        }
        #endif

        return nil
    }

    // MARK: - Aspect Ratio Preserving Target Dimension Calculation

    /// Calculate target bounding-box dimensions preserving aspect ratio under `maxSide` and `maxPixels`.
    public static func calculateTargetDimensions(
        original: ImageDimensions,
        maxSide: Int = defaultMaxEncodeSidePx,
        maxPixels: Int = defaultMaxEncodePixels
    ) -> ImageDimensions {
        guard original.width > 0 && original.height > 0 else { return original }
        let origW = original.width
        let origH = original.height
        let origMax = max(origW, origH)

        var targetW = origW
        var targetH = origH

        // 1. Side clamp
        if origMax > maxSide {
            let scale = Double(maxSide) / Double(origMax)
            targetW = max(1, Int((Double(origW) * scale).rounded()))
            targetH = max(1, Int((Double(origH) * scale).rounded()))
        }

        // 2. Area clamp
        let currentPixels = targetW * targetH
        if currentPixels > maxPixels {
            let areaScale = sqrt(Double(maxPixels) / Double(currentPixels))
            targetW = max(1, Int((Double(targetW) * areaScale).rounded()))
            targetH = max(1, Int((Double(targetH) * areaScale).rounded()))

            while targetW > 1 && targetH > 1 && (targetW * targetH) > maxPixels {
                if targetW >= targetH {
                    targetW -= 1
                } else {
                    targetH -= 1
                }
            }
        }

        return ImageDimensions(width: targetW, height: targetH)
    }

    // MARK: - Image Normalization

    /// Inspect and normalize image data, downsampling and recompressing if oversized.
    public static func normalize(
        image data: Data,
        options: ImageNormalizeOptions = .standard
    ) throws -> NormalizedImageResult {
        guard !data.isEmpty else {
            throw ImageNormalizeError.invalidImageData
        }

        let originalFormat = detectFormat(in: data)
        let rawDimensions = detectDimensions(in: data) ?? ImageDimensions(width: 0, height: 0)

        // Validate vision floor
        if rawDimensions.width > 0 && rawDimensions.height > 0 {
            if rawDimensions.width < defaultMinVisionSidePx || rawDimensions.height < defaultMinVisionSidePx {
                throw ImageNormalizeError.imageTooSmall(
                    width: rawDimensions.width,
                    height: rawDimensions.height
                )
            }
        }

        let targetFormat = options.targetFormat ?? (originalFormat == .unknown ? .png : originalFormat)
        let exceedsMaxSide = rawDimensions.width > options.maxSide || rawDimensions.height > options.maxSide
        let exceedsMaxPixels = rawDimensions.pixelCount > options.maxPixels
        let exceedsMaxBytes = data.count > options.maxBytes
        let needsFormatChange = (options.targetFormat != nil && options.targetFormat != originalFormat)

        // Passthrough if already compliant and no format change
        if !exceedsMaxSide && !exceedsMaxPixels && !exceedsMaxBytes && !needsFormatChange && originalFormat != .unknown {
            return NormalizedImageResult(
                data: data,
                dimensions: rawDimensions,
                originalDimensions: rawDimensions,
                format: originalFormat,
                originalFormat: originalFormat,
                byteCount: data.count,
                originalByteCount: data.count,
                wasDownsampled: false,
                wasRecompressed: false
            )
        }

        #if canImport(CoreGraphics) && canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageNormalizeError.decodeFailed("Could not decode image with CGImageSource")
        }

        let actualOriginalDimensions = ImageDimensions(width: cgImage.width, height: cgImage.height)
        var currentTargetDimensions = calculateTargetDimensions(
            original: actualOriginalDimensions,
            maxSide: options.maxSide,
            maxPixels: options.maxPixels
        )

        var currentSide = max(currentTargetDimensions.width, currentTargetDimensions.height)
        var bestResult: (data: Data, dimensions: ImageDimensions, format: ImageFormat)? = nil

        while currentSide >= options.minSide || bestResult == nil {
            guard let resizedCG = renderResizedCGImage(cgImage, targetDimensions: currentTargetDimensions) else {
                throw ImageNormalizeError.encodeFailed("Could not resize image to \(currentTargetDimensions)")
            }

            // 1. Try lossless PNG / GIF
            if targetFormat == .png || targetFormat == .gif {
                if let encodedData = encodeCGImage(resizedCG, format: targetFormat), encodedData.count <= options.maxBytes {
                    bestResult = (encodedData, currentTargetDimensions, targetFormat)
                    break
                }
            }

            // 2. Try lossy JPEG / WebP quality steps
            if targetFormat == .jpeg || targetFormat == .png || targetFormat == .webp || targetFormat == .unknown {
                let encFormat: ImageFormat = (targetFormat == .webp) ? .webp : .jpeg
                for quality in options.qualitySteps {
                    if let encData = encodeCGImage(resizedCG, format: encFormat, quality: quality) {
                        if encData.count <= options.maxBytes {
                            bestResult = (encData, currentTargetDimensions, encFormat)
                            break
                        }
                    }
                }
                if bestResult != nil { break }
            }

            if currentSide <= options.minSide {
                break
            }
            let nextSide = max(options.minSide, Int(Double(currentSide) * 0.75))
            if nextSide >= currentSide {
                break
            }
            currentSide = nextSide
            currentTargetDimensions = calculateTargetDimensions(
                original: actualOriginalDimensions,
                maxSide: currentSide,
                maxPixels: options.maxPixels
            )
        }

        if let result = bestResult {
            let wasDownsampled = result.dimensions.width != actualOriginalDimensions.width || result.dimensions.height != actualOriginalDimensions.height
            let wasRecompressed = result.data != data
            return NormalizedImageResult(
                data: result.data,
                dimensions: result.dimensions,
                originalDimensions: actualOriginalDimensions,
                format: result.format,
                originalFormat: originalFormat,
                byteCount: result.data.count,
                originalByteCount: data.count,
                wasDownsampled: wasDownsampled,
                wasRecompressed: wasRecompressed
            )
        }

        throw ImageNormalizeError.couldNotFitUnderByteCap(
            maxBytes: options.maxBytes,
            lastDimension: currentTargetDimensions
        )
        #else
        return NormalizedImageResult(
            data: data,
            dimensions: rawDimensions,
            originalDimensions: rawDimensions,
            format: targetFormat,
            originalFormat: originalFormat,
            byteCount: data.count,
            originalByteCount: data.count,
            wasDownsampled: false,
            wasRecompressed: false
        )
        #endif
    }

    // MARK: - Text-Only Model Fallback Placeholder

    /// Synthesize descriptive markdown placeholder block `[Image: <dimensions>, <format>]` when vision is unsupported.
    public static func textFallbackPlaceholder(
        dimensions: ImageDimensions?,
        format: ImageFormat
    ) -> String {
        let dimStr: String
        if let dims = dimensions, !dims.isEmpty {
            dimStr = "\(dims.width)x\(dims.height)"
        } else {
            dimStr = "unknown dimensions"
        }
        let formatStr = format.displayName
        return "[Image: \(dimStr), \(formatStr)]"
    }

    /// Synthesize descriptive markdown placeholder block `[Image: <dimensions>, <format>]` from raw image data.
    public static func textFallbackPlaceholder(for rawData: Data) -> String {
        let format = detectFormat(in: rawData)
        let dimensions = detectDimensions(in: rawData)
        return textFallbackPlaceholder(dimensions: dimensions, format: format)
    }

    /// Synthesize descriptive markdown placeholder block with optional label.
    public static func synthesizeTextFallback(for rawData: Data, label: String? = nil) -> String {
        let format = detectFormat(in: rawData)
        let dimensions = detectDimensions(in: rawData)
        let dimStr = (dimensions != nil && !dimensions!.isEmpty) ? "\(dimensions!.width)x\(dimensions!.height)" : "unknown dimensions"
        let formatStr = format.displayName
        if let label = label, !label.isEmpty {
            return "[Image: \(dimStr), \(formatStr) - \(label)]"
        }
        return "[Image: \(dimStr), \(formatStr)]"
    }

    // MARK: - Private Binary Header Parsers

    private static func parseDimensionsFromHeader(_ data: Data) -> ImageDimensions? {
        // PNG
        if data.count >= 24 && data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            let width = (Int(data[16]) << 24) | (Int(data[17]) << 16) | (Int(data[18]) << 8) | Int(data[19])
            let height = (Int(data[20]) << 24) | (Int(data[21]) << 16) | (Int(data[22]) << 8) | Int(data[23])
            if width > 0 && height > 0 {
                return ImageDimensions(width: width, height: height)
            }
        }

        // GIF
        if data.count >= 10 && (data.starts(with: Data("GIF87a".utf8)) || data.starts(with: Data("GIF89a".utf8))) {
            let width = Int(data[6]) | (Int(data[7]) << 8)
            let height = Int(data[8]) | (Int(data[9]) << 8)
            if width > 0 && height > 0 {
                return ImageDimensions(width: width, height: height)
            }
        }

        // BMP
        if data.count >= 26 && data.starts(with: [0x42, 0x4D]) {
            let headerSize = Int(data[14]) | (Int(data[15]) << 8) | (Int(data[16]) << 16) | (Int(data[17]) << 24)
            if headerSize >= 40 && data.count >= 26 {
                let width = Int(Int32(bitPattern: UInt32(data[18]) | (UInt32(data[19]) << 8) | (UInt32(data[20]) << 16) | (UInt32(data[21]) << 24)))
                let height = abs(Int(Int32(bitPattern: UInt32(data[22]) | (UInt32(data[23]) << 8) | (UInt32(data[24]) << 16) | (UInt32(data[25]) << 24))))
                if width > 0 && height > 0 {
                    return ImageDimensions(width: width, height: height)
                }
            } else if headerSize == 12 && data.count >= 22 {
                let width = Int(data[18]) | (Int(data[19]) << 8)
                let height = Int(data[20]) | (Int(data[21]) << 8)
                if width > 0 && height > 0 {
                    return ImageDimensions(width: width, height: height)
                }
            }
        }

        // WebP
        if data.count >= 30 && data.starts(with: Data("RIFF".utf8)) && data[8..<12] == Data("WEBP".utf8) {
            let formatTag = String(data: data[12..<16], encoding: .ascii) ?? ""
            if formatTag == "VP8 " && data.count >= 30 {
                // Lossy VP8
                if data[23] == 0x9D && data[24] == 0x01 && data[25] == 0x2A {
                    let width = (Int(data[26]) | (Int(data[27]) << 8)) & 0x3FFF
                    let height = (Int(data[28]) | (Int(data[29]) << 8)) & 0x3FFF
                    if width > 0 && height > 0 {
                        return ImageDimensions(width: width, height: height)
                    }
                }
            } else if formatTag == "VP8L" && data.count >= 25 {
                // Lossless VP8L
                if data[20] == 0x2F {
                    let b0 = Int(data[21]), b1 = Int(data[22]), b2 = Int(data[23]), b3 = Int(data[24])
                    let width = 1 + (((b1 & 0x3F) << 8) | b0)
                    let height = 1 + (((b3 & 0x0F) << 10) | (b2 << 2) | ((b1 & 0xC0) >> 6))
                    if width > 0 && height > 0 {
                        return ImageDimensions(width: width, height: height)
                    }
                }
            } else if formatTag == "VP8X" && data.count >= 30 {
                // Extended VP8X
                let width = 1 + (Int(data[24]) | (Int(data[25]) << 8) | (Int(data[26]) << 16))
                let height = 1 + (Int(data[27]) | (Int(data[28]) << 8) | (Int(data[29]) << 16))
                if width > 0 && height > 0 {
                    return ImageDimensions(width: width, height: height)
                }
            }
        }

        // JPEG
        if data.count >= 4 && data.starts(with: [0xFF, 0xD8, 0xFF]) {
            var offset = 2
            while offset < data.count - 8 {
                if data[offset] != 0xFF {
                    offset += 1
                    continue
                }
                let marker = data[offset + 1]
                offset += 2

                // Standalone markers
                if marker == 0xD8 || marker == 0xD9 || marker == 0x00 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7) {
                    continue
                }

                guard offset + 2 <= data.count else { break }
                let segmentLength = (Int(data[offset]) << 8) | Int(data[offset + 1])
                guard segmentLength >= 2 else { break }

                // SOF markers (Start Of Frame)
                if (marker >= 0xC0 && marker <= 0xC3) || (marker >= 0xC5 && marker <= 0xC7) || (marker >= 0xC9 && marker <= 0xCB) || (marker >= 0xCD && marker <= 0xCF) {
                    if offset + 7 <= data.count {
                        let height = (Int(data[offset + 3]) << 8) | Int(data[offset + 4])
                        let width = (Int(data[offset + 5]) << 8) | Int(data[offset + 6])
                        if width > 0 && height > 0 {
                            return ImageDimensions(width: width, height: height)
                        }
                    }
                }
                offset += segmentLength
            }
        }

        return nil
    }

    // MARK: - CoreGraphics Helpers

    #if canImport(CoreGraphics) && canImport(ImageIO)
    private static func utTypeIdentifier(for format: ImageFormat) -> CFString {
        #if canImport(UniformTypeIdentifiers)
        if #available(macOS 11.0, iOS 14.0, *) {
            switch format {
            case .png: return UTType.png.identifier as CFString
            case .jpeg: return UTType.jpeg.identifier as CFString
            case .gif: return UTType.gif.identifier as CFString
            case .webp: return UTType.webP.identifier as CFString
            case .bmp: return UTType.bmp.identifier as CFString
            case .tiff: return UTType.tiff.identifier as CFString
            case .unknown: return UTType.png.identifier as CFString
            }
        }
        #endif
        switch format {
        case .png: return "public.png" as CFString
        case .jpeg: return "public.jpeg" as CFString
        case .gif: return "com.compuserve.gif" as CFString
        case .webp: return "org.webmproject.webp" as CFString
        case .bmp: return "com.microsoft.bmp" as CFString
        case .tiff: return "public.tiff" as CFString
        case .unknown: return "public.png" as CFString
        }
    }

    private static func renderResizedCGImage(_ cgImage: CGImage, targetDimensions: ImageDimensions) -> CGImage? {
        let targetW = targetDimensions.width
        let targetH = targetDimensions.height
        guard targetW > 0 && targetH > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let context = CGContext(
            data: nil,
            width: targetW,
            height: targetH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
        return context.makeImage()
    }

    private static func encodeCGImage(_ cgImage: CGImage, format: ImageFormat, quality: Double? = nil) -> Data? {
        let destData = NSMutableData()
        let typeIdent = utTypeIdentifier(for: format)
        guard let dest = CGImageDestinationCreateWithData(destData, typeIdent, 1, nil) else {
            // Fallback to PNG if the destination format is unsupported by the platform
            if format != .png {
                return encodeCGImage(cgImage, format: .png, quality: nil)
            }
            return nil
        }

        var options: [CFString: Any] = [:]
        if let q = quality, (format == .jpeg || format == .webp) {
            options[kCGImageDestinationLossyCompressionQuality] = q as CFNumber
        }

        CGImageDestinationAddImage(dest, cgImage, options.isEmpty ? nil : (options as CFDictionary))
        if CGImageDestinationFinalize(dest) {
            return destData as Data
        }
        return nil
    }
    #endif
}
