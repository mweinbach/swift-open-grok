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
    func value(_ key: String) -> String? {
        guard let value = env[key], !value.isEmpty else { return nil }
        return value
    }

    if value("CURSOR_TRACE_ID") != nil {
        return .cursor
    }
    if let askpass = value("VSCODE_GIT_ASKPASS_MAIN") {
        let normalized = askpass.lowercased()
        if normalized.contains("cursor") { return .cursor }
        if normalized.contains("windsurf") { return .windsurf }
        return .vsCode
    }

    if let program = value("TERM_PROGRAM") {
        let normalized = program.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { $0 != " " && $0 != "-" && $0 != "_" && $0 != "." }
        switch normalized {
        case "appleterminal": return .appleTerminal
        case "ghostty": return .ghostty
        case "iterm", "iterm2", "itermapp": return .iterm2
        case "warp", "warpterminal": return .warpTerminal
        case "vscode": return .vsCode
        case "wezterm": return .wezTerm
        case "kitty": return .kitty
        case "alacritty": return .alacritty
        case "rio": return .rio
        case "terminator": return .terminator
        case "zed": return .zed
        case "grokdesktop": return .grokDesktop
        case "windowsterminal": return .windowsTerminal
        case "otty": return .otty
        default: break
        }
    }

    if let emulator = value("TERMINAL_EMULATOR")?.lowercased(),
       emulator.contains("jetbrains") || emulator.contains("jediterm") {
        return .jetBrains
    }
    if value("WEZTERM_VERSION") != nil { return .wezTerm }
    if value("ITERM_SESSION_ID") != nil
        || value("ITERM_PROFILE") != nil
        || value("LC_TERMINAL")?.lowercased() == "iterm2" {
        return .iterm2
    }
    if value("TERM_SESSION_ID") != nil { return .appleTerminal }
    if value("KITTY_WINDOW_ID") != nil || value("TERM")?.contains("kitty") == true {
        return .kitty
    }
    if value("ALACRITTY_SOCKET") != nil || value("TERM") == "alacritty" {
        return .alacritty
    }
    if value("TERM") == "rio" { return .rio }
    if let term = value("TERM"), ["foot", "foot-extra", "foot-direct"].contains(term) {
        return .foot
    }
    if value("TERMINATOR_UUID") != nil { return .terminator }
    if value("VTE_VERSION") != nil { return .vte }
    if value("WT_SESSION") != nil { return .windowsTerminal }
    return .unknown
}

// MARK: - Select All Capability

/// `cmd_a_select_all_supported` (views/prompt_widget/mod.rs:140-142).
/// Strictly gated to Ghostty terminal brand.
public func cmdASelectAllSupported(brand: TerminalName) -> Bool {
    brand == .ghostty
}

// MARK: - Graphics Protocol

/// Terminal graphics protocol format.
///
/// Pin: `GraphicsProtocol` (`image.rs`). `protocolForBrand` never returns
/// `.iterm2` today — OSC 1337 lacks image-id / z-index / crop / clear.
public enum GraphicsProtocol: String, Sendable, Equatable, Hashable {
    case kitty
    case iterm2
    case none

    /// Whether this protocol can render pixel images inline.
    public var supportsImages: Bool {
        self != .none
    }
}

/// Image formats supported by Kitty graphics protocol.
public enum KittyImageFormat: UInt8, Sendable, Equatable {
    case png = 100
}

/// Determine graphics protocol supported by terminal brand.
///
/// Pin: `protocol_for_brand` (`image.rs`). Windows is always `.none`
/// (ConPTY strips APC). iTerm2 is `.none` (no placement/scrollback model).
/// Warp is `.kitty` for overlay transmit, not scrollback placement.
public func protocolForBrand(brand: TerminalName, isWindows: Bool = false) -> GraphicsProtocol {
    GraphicsProtocol(KittyGraphics.protocolForBrand(brand: brand, isWindows: isWindows))
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
    if environment["TERM"]?.lowercased() == "dumb" {
        return .none
    }
    if let backend = environment["BYOBU_BACKEND"], !backend.isEmpty {
        if backend.lowercased() == "tmux" { return .none }
        if backend.lowercased() != "screen",
           let tmux = environment["TMUX"], !tmux.isEmpty {
            return .none
        }
    } else if let tmux = environment["TMUX"], !tmux.isEmpty {
        return .none
    }
    let brand = detectTerminalBrandFromEnv(environment)
    let isWindows = host == .windows || environment["OS"] == "Windows_NT"
    return protocolForBrand(brand: brand, isWindows: isWindows)
}

// MARK: - Kitty Graphics Protocol Framing
//
// Bodies call `OpenGrokTerminalCore.KittyGraphics`. Public names stay on
// this module so existing PagerRender / CLI call sites keep compiling.
// `setInlineOverlayForceOff` / `scrollbackInlineOverlayForcedOff` are
// already visible here via `@_exported import OpenGrokTerminalCore`.

/// Render Kitty image directly with z-index = -1 (inline/scrollback).
///
/// PagerRender keeps z=-1 even though pin `render_kitty_image` and
/// `KittyGraphics.render` default to z=1 (modal overlays).
public func renderKittyImage(
    imageData: Data,
    format: KittyImageFormat = .png,
    cols: UInt16,
    rows: UInt16
) -> String {
    KittyGraphics.renderZ(
        imageData: imageData,
        format: format.coreFormat,
        cols: cols,
        rows: rows,
        z: -1
    )
}

/// Render Kitty image with explicit z-index (z=1 for modal overlays, z=-1 for scrollback).
public func renderKittyImageZ(
    imageData: Data,
    format: KittyImageFormat = .png,
    cols: UInt16,
    rows: UInt16,
    z: Int32
) -> String {
    KittyGraphics.renderZ(
        imageData: imageData,
        format: format.coreFormat,
        cols: cols,
        rows: rows,
        z: z
    )
}

/// Transmit Kitty image data into terminal storage without placing it.
public func transmitKittyImage(
    imageData: Data,
    format: KittyImageFormat = .png,
    imageId: UInt32
) -> String {
    KittyGraphics.transmit(imageData: imageData, format: format.coreFormat, imageId: imageId)
}

/// Place a previously transmitted Kitty image at specified cell dimensions and z-index.
public func placeKittyImage(
    imageId: UInt32,
    cols: UInt16,
    rows: UInt16,
    z: Int32
) -> String {
    KittyGraphics.place(imageId: imageId, cols: cols, rows: rows, z: z)
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
    KittyGraphics.placeCropped(
        imageId: imageId,
        cols: cols,
        rows: rows,
        z: z,
        srcX: srcX,
        srcY: srcY,
        srcW: srcW,
        srcH: srcH
    )
}

/// Clear/delete Kitty image by image ID.
public func clearKittyImage(imageId: UInt32) -> String {
    KittyGraphics.clear(imageId: imageId)
}

/// Render an image using iTerm2 inline image escape sequence (OSC 1337).
///
/// Helper exists for the pin enum; `protocolForBrand` never selects it.
public func renderIterm2Image(imageData: Data, cols: UInt16, rows: UInt16) -> String {
    KittyGraphics.renderITerm2Image(imageData: imageData, cols: cols, rows: rows)
}

/// Compute scaled cell bounds for image aspect ratio.
public func fitImageToCells(
    imgW: UInt32,
    imgH: UInt32,
    maxCols: UInt16,
    maxRows: UInt16
) -> (cols: UInt16, rows: UInt16) {
    KittyGraphics.fitImageToCells(imgW: imgW, imgH: imgH, maxCols: maxCols, maxRows: maxRows)
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

// MARK: - PagerRender ↔ TerminalCore mapping

extension GraphicsProtocol {
    fileprivate init(_ proto: KittyGraphicsProtocol) {
        switch proto {
        case .kitty:
            self = .kitty
        case .iterm2:
            self = .iterm2
        case .none:
            self = .none
        }
    }
}

extension KittyImageFormat {
    fileprivate var coreFormat: KittyGraphicsFormat {
        switch self {
        case .png:
            return .png
        }
    }
}
