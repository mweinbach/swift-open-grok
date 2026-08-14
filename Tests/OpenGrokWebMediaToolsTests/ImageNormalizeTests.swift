// ImageNormalizeTests.swift
//
// Unit tests for Image Normalization, Resizing, Digest Hash Cache, and Text-only fallback.

import Foundation
import Testing
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(ImageIO)
import ImageIO
#endif
@testable import OpenGrokWebMediaTools

@Suite("ImageNormalizeTests")
struct ImageNormalizeTests {

    // MARK: - Test Helpers

    private func createTestImageData(width: Int, height: Int, format: ImageFormat = .png) -> Data? {
        #if canImport(CoreGraphics) && canImport(ImageIO)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }

        // Draw background and contrasting rectangle
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 1.0)
        context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))

        guard let image = context.makeImage() else { return nil }

        let destData = NSMutableData()
        let typeIdent: CFString
        switch format {
        case .png: typeIdent = "public.png" as CFString
        case .jpeg: typeIdent = "public.jpeg" as CFString
        case .gif: typeIdent = "com.compuserve.gif" as CFString
        default: typeIdent = "public.png" as CFString
        }

        guard let dest = CGImageDestinationCreateWithData(destData, typeIdent, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }

        return destData as Data
        #else
        // Minimal synthetic 100x100 PNG header for non-Apple test runners
        return minimalPNG(width: width, height: height)
        #endif
    }

    private func minimalPNG(width: Int, height: Int) -> Data {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) // PNG magic
        // IHDR chunk: length 13
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x0D])
        data.append(contentsOf: [0x49, 0x48, 0x44, 0x52]) // "IHDR"
        data.append(UInt8((width >> 24) & 0xFF))
        data.append(UInt8((width >> 16) & 0xFF))
        data.append(UInt8((width >> 8) & 0xFF))
        data.append(UInt8(width & 0xFF))
        data.append(UInt8((height >> 24) & 0xFF))
        data.append(UInt8((height >> 16) & 0xFF))
        data.append(UInt8((height >> 8) & 0xFF))
        data.append(UInt8(height & 0xFF))
        data.append(contentsOf: [0x08, 0x02, 0x00, 0x00, 0x00]) // 8-bit RGB, no compression/filter/interlace
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // CRC placeholder
        return data
    }

    // MARK: - 1. Dimensions and Aspect Ratio

    @Test("ImageDimensions calculates aspect ratio and pixel counts accurately")
    func testImageDimensionsCalculations() {
        let dim1 = ImageDimensions(width: 1920, height: 1080)
        #expect(dim1.width == 1920)
        #expect(dim1.height == 1080)
        #expect(abs(dim1.aspectRatio - (1920.0 / 1080.0)) < 0.0001)
        #expect(dim1.pixelCount == 2_073_600)
        #expect(!dim1.isEmpty)
        #expect(dim1.description == "1920x1080")

        let zeroDim = ImageDimensions(width: 0, height: 0)
        #expect(zeroDim.aspectRatio == 0.0)
        #expect(zeroDim.pixelCount == 0)
        #expect(zeroDim.isEmpty)

        let squareDim = ImageDimensions(width: 500, height: 500)
        #expect(squareDim.aspectRatio == 1.0)
        #expect(squareDim.pixelCount == 250_000)
    }

    @Test("calculateTargetDimensions preserves aspect ratio under bounding box constraints")
    func testAspectRatioPreservationDuringDownsampling() {
        // Case 1: 4000x2000 (aspect ratio 2.0) with maxSide = 2000
        let orig1 = ImageDimensions(width: 4000, height: 2000)
        let target1 = ImageNormalizer.calculateTargetDimensions(
            original: orig1,
            maxSide: 2000,
            maxPixels: 2_408_448
        )
        #expect(target1.width == 2000)
        #expect(target1.height == 1000)
        #expect(abs(target1.aspectRatio - 2.0) < 0.001)
        #expect(target1.pixelCount <= 2_408_448)

        // Case 2: 3000x3000 (aspect ratio 1.0, 9M pixels) with maxPixels = 2_408_448
        let orig2 = ImageDimensions(width: 3000, height: 3000)
        let target2 = ImageNormalizer.calculateTargetDimensions(
            original: orig2,
            maxSide: 2000,
            maxPixels: 2_408_448
        )
        #expect(target2.width <= 2000)
        #expect(target2.height <= 2000)
        #expect(target2.pixelCount <= 2_408_448)
        #expect(abs(target2.aspectRatio - 1.0) < 0.01)

        // Case 3: 800x600 (under limits) -> remains untouched
        let orig3 = ImageDimensions(width: 800, height: 600)
        let target3 = ImageNormalizer.calculateTargetDimensions(
            original: orig3,
            maxSide: 2000,
            maxPixels: 2_408_448
        )
        #expect(target3 == orig3)

        // Case 4: Ultra-tall image 100x5000 (aspect ratio 0.02)
        let orig4 = ImageDimensions(width: 100, height: 5000)
        let target4 = ImageNormalizer.calculateTargetDimensions(
            original: orig4,
            maxSide: 2000,
            maxPixels: 2_408_448
        )
        #expect(target4.height == 2000)
        #expect(target4.width == 40)
        #expect(abs(target4.aspectRatio - 0.02) < 0.001)
    }

    // MARK: - 2. Header and Dimension Detection

    @Test("Header parsing accurately extracts format and dimensions")
    func testHeaderDimensionDetection() throws {
        // PNG detection
        let pngData = try #require(createTestImageData(width: 640, height: 480, format: .png))
        #expect(ImageNormalizer.detectFormat(in: pngData) == .png)
        let pngDims = ImageNormalizer.detectDimensions(in: pngData)
        #expect(pngDims?.width == 640)
        #expect(pngDims?.height == 480)

        // JPEG detection
        let jpegData = try #require(createTestImageData(width: 320, height: 240, format: .jpeg))
        #expect(ImageNormalizer.detectFormat(in: jpegData) == .jpeg)
        let jpegDims = ImageNormalizer.detectDimensions(in: jpegData)
        #expect(jpegDims?.width == 320)
        #expect(jpegDims?.height == 240)

        // GIF detection
        let gifData = try #require(createTestImageData(width: 160, height: 120, format: .gif))
        #expect(ImageNormalizer.detectFormat(in: gifData) == .gif)
        let gifDims = ImageNormalizer.detectDimensions(in: gifData)
        #expect(gifDims?.width == 160)
        #expect(gifDims?.height == 120)

        // BMP header test
        var bmpData = Data([0x42, 0x4D]) // "BM"
        bmpData.append(contentsOf: [UInt8](repeating: 0, count: 12))
        // DIB header size 40 (0x28)
        bmpData.append(contentsOf: [0x28, 0x00, 0x00, 0x00])
        // Width: 800 (0x0320)
        bmpData.append(contentsOf: [0x20, 0x03, 0x00, 0x00])
        // Height: 600 (0x0258)
        bmpData.append(contentsOf: [0x58, 0x02, 0x00, 0x00])
        #expect(ImageNormalizer.detectFormat(in: bmpData) == .bmp)
        let bmpDims = ImageNormalizer.detectDimensions(in: bmpData)
        #expect(bmpDims?.width == 800)
        #expect(bmpDims?.height == 600)
    }

    // MARK: - 3. Image Downsampling & Normalization

    @Test("ImageNormalizer downsamples oversized images and respects maxSide and maxPixels")
    func testDownsampleOversizedImage() throws {
        // Create 2400x1200 PNG image
        let originalData = try #require(createTestImageData(width: 2400, height: 1200, format: .png))
        let options = ImageNormalizeOptions(
            maxSide: 1200,
            maxPixels: 1_000_000,
            maxBytes: 1_000_000
        )

        let result = try ImageNormalizer.normalize(image: originalData, options: options)

        #expect(result.wasDownsampled)
        #expect(result.originalDimensions.width == 2400)
        #expect(result.originalDimensions.height == 1200)
        #expect(result.dimensions.width <= 1200)
        #expect(result.dimensions.height <= 600)
        #expect(result.dimensions.pixelCount <= 1_000_000)
        #expect(result.byteCount <= 1_000_000)
        #expect(abs(result.dimensions.aspectRatio - 2.0) < 0.05)
    }

    @Test("ImageNormalizer rejects images below minimum vision threshold")
    func testImageBelowVisionThreshold() {
        let tinyPng = minimalPNG(width: 4, height: 4)
        do {
            _ = try ImageNormalizer.normalize(image: tinyPng)
            Issue.record("Expected imageTooSmall error for 4x4 image")
        } catch ImageNormalizeError.imageTooSmall(let w, let h) {
            #expect(w == 4)
            #expect(h == 4)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Compliant image within bounds passes through without re-encoding")
    func testCompliantImagePassthrough() throws {
        let smallData = try #require(createTestImageData(width: 400, height: 300, format: .png))
        let options = ImageNormalizeOptions(
            maxSide: 2000,
            maxPixels: 2_408_448,
            maxBytes: 2_000_000
        )

        let result = try ImageNormalizer.normalize(image: smallData, options: options)

        #expect(!result.wasDownsampled)
        #expect(!result.wasRecompressed)
        #expect(result.data == smallData)
        #expect(result.dimensions.width == 400)
        #expect(result.dimensions.height == 300)
    }

    // MARK: - 4. Digest Hash Cache

    @Test("ImageNormalizeCache stores, retrieves, and avoids re-processing identical attachments")
    func testImageNormalizeCacheHitAndStore() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-test-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cache = ImageNormalizeCache(cacheDirectory: tempDir)

        let rawImage = try #require(createTestImageData(width: 1600, height: 1200, format: .png))
        let normalizedImage = try #require(createTestImageData(width: 800, height: 600, format: .png))

        let hash = ImageNormalizeCache.sha256Hex(for: rawImage)
        #expect(hash.count == 64)

        // Initial lookup miss
        #expect(cache.cachedNormalizedImage(for: rawImage) == nil)
        #expect(!cache.contains(rawData: rawImage))

        // Store in cache
        cache.cacheNormalizedImage(data: normalizedImage, for: rawImage)

        // Cache hit
        #expect(cache.contains(rawData: rawImage))
        let hitData = cache.cachedNormalizedImage(for: rawImage)
        #expect(hitData == normalizedImage)

        // Verify disk files were created: <sha256>.png and <sha256>.json
        let diskPng = tempDir.appendingPathComponent("\(hash).png")
        let diskJson = tempDir.appendingPathComponent("\(hash).json")
        #expect(FileManager.default.fileExists(atPath: diskPng.path))
        #expect(FileManager.default.fileExists(atPath: diskJson.path))

        // Query structured result metadata
        let result = cache.cachedNormalizedResult(for: rawImage)
        #expect(result != nil)
        #expect(result?.dimensions.width == 800)
        #expect(result?.dimensions.height == 600)
        #expect(result?.originalDimensions.width == 1600)
        #expect(result?.originalDimensions.height == 1200)

        // Independent cache instance pointing to same directory reads from disk
        let secondaryCache = ImageNormalizeCache(cacheDirectory: tempDir)
        let secondaryHit = secondaryCache.cachedNormalizedImage(for: rawImage)
        #expect(secondaryHit == normalizedImage)
        #expect(secondaryCache.entryCount == 1)

        // Clear cache
        secondaryCache.clear()
        #expect(!secondaryCache.contains(rawData: rawImage))
        #expect(secondaryCache.cachedNormalizedImage(for: rawImage) == nil)
    }

    // MARK: - 5. Text-Only Model Fallback Synthesis

    @Test("Synthesizes descriptive text fallback markdown block")
    func testTextOnlyFallbackSynthesis() throws {
        // With explicit dimensions
        let placeholder1 = ImageNormalizer.textFallbackPlaceholder(
            dimensions: ImageDimensions(width: 1920, height: 1080),
            format: .png
        )
        #expect(placeholder1 == "[Image: 1920x1080, PNG]")

        let placeholder2 = ImageNormalizer.textFallbackPlaceholder(
            dimensions: ImageDimensions(width: 800, height: 600),
            format: .jpeg
        )
        #expect(placeholder2 == "[Image: 800x600, JPEG]")

        let placeholder3 = ImageNormalizer.textFallbackPlaceholder(
            dimensions: nil,
            format: .webp
        )
        #expect(placeholder3 == "[Image: unknown dimensions, WebP]")

        // From raw image bytes
        let rawPng = try #require(createTestImageData(width: 1024, height: 768, format: .png))
        let autoFallback = ImageNormalizer.textFallbackPlaceholder(for: rawPng)
        #expect(autoFallback == "[Image: 1024x768, PNG]")

        // With optional custom label
        let labeledFallback = ImageNormalizer.synthesizeTextFallback(for: rawPng, label: "architecture.png")
        #expect(labeledFallback == "[Image: 1024x768, PNG - architecture.png]")
    }
}
