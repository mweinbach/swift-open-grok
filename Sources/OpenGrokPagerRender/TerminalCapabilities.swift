// TerminalCapabilities.swift
//
// Terminal capability queries, image graphics protocol encoding,
// and keyboard enhancement protocol negotiation.
//
// Reference: crates/codegen/xai-grok-pager-render/src/terminal/

import Foundation
@_exported import OpenGrokTerminalCore
#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

public typealias TerminalName = MouseScrollTerminalBrand

public enum HostOs: String, Sendable, Equatable, Hashable {
    case macos
    case linux
    case windows
    case other

    public static func current() -> HostOs {
        #if os(macOS)
        return .macos
        #elseif os(Linux)
        return .linux
        #elseif os(Windows)
        return .windows
        #else
        return .other
        #endif
    }
}

public func detectTerminalBrandFromEnv(_ env: [String: String]) -> TerminalName {
    MouseScrollTerminalBrand.from(termProgram: env["TERM_PROGRAM"])
}

// MARK: - Select All Capability

/// `cmd_a_select_all_supported` (views/prompt_widget/mod.rs:140-142).
/// Strictly gated to Ghostty terminal brand.
public func cmdASelectAllSupported(brand: TerminalName) -> Bool {
    brand == .ghostty
}

// MARK: - Graphics Protocol

/// Terminal graphics protocol format.
public enum GraphicsProtocol: String, Sendable, Equatable, Hashable {
    case kitty
    case iterm2
    case none
}

/// Image formats supported by Kitty graphics protocol.
public enum KittyImageFormat: UInt8, Sendable, Equatable {
    case png = 100
}

/// Determine graphics protocol supported by terminal brand.
public func protocolForBrand(brand: TerminalName, isWindows: Bool = false) -> GraphicsProtocol {
    if isWindows { return .none }
    switch brand {
    case .ghostty, .kitty, .wezTerm:
        return .kitty
    case .iterm2:
        return .iterm2
    default:
        return .none
    }
}

private nonisolated(unsafe) var testGraphicsProtocolOverride: GraphicsProtocol? = nil

/// Set test override for graphics protocol detection.
public func setTestGraphicsProtocolOverride(_ proto: GraphicsProtocol?) {
    testGraphicsProtocolOverride = proto
}

/// Detect active graphics protocol from environment.
public func detectGraphicsProtocol(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    host: HostOs = HostOs.current()
) -> GraphicsProtocol {
    if let override = testGraphicsProtocolOverride {
        return override
    }
    let brand = detectTerminalBrandFromEnv(environment)
    let isWindows = host == .windows || environment["OS"] == "Windows_NT"
    return protocolForBrand(brand: brand, isWindows: isWindows)
}

// MARK: - Kitty Graphics Protocol Framing

/// Render Kitty image directly with z-index = -1 (inline/scrollback).
public func renderKittyImage(
    imageData: Data,
    format: KittyImageFormat = .png,
    cols: UInt16,
    rows: UInt16
) -> String {
    renderKittyImageZ(imageData: imageData, format: format, cols: cols, rows: rows, z: -1)
}

/// Render Kitty image with explicit z-index (z=1 for modal overlays, z=-1 for scrollback).
/// Chunks base64 payload at 4096-byte boundaries.
public func renderKittyImageZ(
    imageData: Data,
    format: KittyImageFormat = .png,
    cols: UInt16,
    rows: UInt16,
    z: Int32
) -> String {
    let b64 = imageData.base64EncodedString()
    guard !b64.isEmpty else { return "" }

    let chunkSize = 4096
    var chunks: [Substring] = []
    var index = b64.startIndex
    while index < b64.endIndex {
        let nextIndex = b64.index(index, offsetBy: chunkSize, limitedBy: b64.endIndex) ?? b64.endIndex
        chunks.append(b64[index..<nextIndex])
        index = nextIndex
    }

    var result = ""
    for (i, chunk) in chunks.enumerated() {
        let hasMore = (i + 1 < chunks.count) ? 1 : 0
        if i == 0 {
            result += "\u{1b}_Ga=T,f=\(format.rawValue),t=d,q=2,C=1,z=\(z),i=1,p=1,c=\(cols),r=\(rows),m=\(hasMore);\(chunk)\u{1b}\\"
        } else {
            result += "\u{1b}_Gm=\(hasMore);\(chunk)\u{1b}\\"
        }
    }
    return result
}

/// Transmit Kitty image data into terminal storage without placing it.
public func transmitKittyImage(
    imageData: Data,
    format: KittyImageFormat = .png,
    imageId: UInt32
) -> String {
    let b64 = imageData.base64EncodedString()
    guard !b64.isEmpty else { return "" }

    let chunkSize = 4096
    var chunks: [Substring] = []
    var index = b64.startIndex
    while index < b64.endIndex {
        let nextIndex = b64.index(index, offsetBy: chunkSize, limitedBy: b64.endIndex) ?? b64.endIndex
        chunks.append(b64[index..<nextIndex])
        index = nextIndex
    }

    var result = ""
    for (i, chunk) in chunks.enumerated() {
        let hasMore = (i + 1 < chunks.count) ? 1 : 0
        if i == 0 {
            result += "\u{1b}_Ga=t,f=\(format.rawValue),t=d,q=2,i=\(imageId),p=1,m=\(hasMore);\(chunk)\u{1b}\\"
        } else {
            result += "\u{1b}_Gm=\(hasMore);\(chunk)\u{1b}\\"
        }
    }
    return result
}

/// Place a previously transmitted Kitty image at specified cell dimensions and z-index.
public func placeKittyImage(
    imageId: UInt32,
    cols: UInt16,
    rows: UInt16,
    z: Int32
) -> String {
    "\u{1b}_Ga=p,i=\(imageId),p=1,q=2,C=1,z=\(z),c=\(cols),r=\(rows);\u{1b}\\"
}

/// Place a cropped slice of a previously transmitted Kitty image.
public func placeKittyImageCropped(
    imageId: UInt32,
    cols: UInt16,
    rows: UInt16,
    z: Int32,
    srcX: UInt32,
    srcY: UInt32,
    srcW: UInt32,
    srcH: UInt32
) -> String {
    "\u{1b}_Ga=p,i=\(imageId),p=1,q=2,C=1,z=\(z),c=\(cols),r=\(rows),x=\(srcX),y=\(srcY),w=\(srcW),h=\(srcH);\u{1b}\\"
}

/// Clear/delete Kitty image by image ID.
public func clearKittyImage(imageId: UInt32) -> String {
    "\u{1b}_Ga=d,d=i,i=\(imageId),p=1,q=2;\u{1b}\\"
}

/// Render an image using iTerm2 inline image escape sequence (OSC 1337).
public func renderIterm2Image(imageData: Data, cols: UInt16, rows: UInt16) -> String {
    let b64 = imageData.base64EncodedString()
    return "\u{1b}]1337;File=inline=1;width=\(cols);height=\(rows):\(b64)\u{07}"
}

/// Compute scaled cell bounds for image aspect ratio.
public func fitImageToCells(
    imgW: UInt32,
    imgH: UInt32,
    maxCols: UInt16,
    maxRows: UInt16
) -> (cols: UInt16, rows: UInt16) {
    guard imgW > 0, imgH > 0, maxCols > 0, maxRows > 0 else { return (1, 1) }

    // Terminal cells typically have a ~2:1 height-to-width pixel aspect ratio
    let pixelAspect = Double(imgW) / Double(imgH)
    let cellAspect = pixelAspect * 2.0 // cell columns / cell rows

    var cols = Double(maxCols)
    var rows = cols / cellAspect

    if rows > Double(maxRows) {
        rows = Double(maxRows)
        cols = rows * cellAspect
    }

    let finalCols = max(1, min(maxCols, UInt16(cols.rounded())))
    let finalRows = max(1, min(maxRows, UInt16(rows.rounded())))
    return (finalCols, finalRows)
}

/// Prepare/convert image bytes to PNG format for Kitty graphics overlay rendering.
public func prepareKittyOverlayImageBytes(_ imageData: Data) -> Data? {
    guard !imageData.isEmpty else { return nil }

    // Check for PNG magic signature
    let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    if imageData.count >= pngSignature.count && Array(imageData.prefix(pngSignature.count)) == pngSignature {
        return imageData
    }

    #if canImport(CoreGraphics) && canImport(ImageIO)
    guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        return nil
    }

    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        output,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        return nil
    }

    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return output as Data
    #else
    return nil
    #endif
}

