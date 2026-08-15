// KittyGraphics.swift
//
// Pin-correct Kitty graphics encoder (transmit / place / crop / delete).
// Reference: crates/codegen/xai-grok-pager-render/src/terminal/image.rs @ 650c1db7
//
// Names live under `KittyGraphics` so OpenGrokPagerRender's diverged
// encoder can keep compiling until the lead redirects it here.

import Foundation

// MARK: - Protocol / format

/// Graphics protocol supported by a terminal brand (`image.rs` `GraphicsProtocol`).
public enum KittyGraphicsProtocol: String, Sendable, Equatable, Hashable {
    /// Kitty graphics protocol (Kitty, Ghostty, WezTerm, Warp).
    case kitty
    /// iTerm2 OSC 1337 inline images. Present for the pin enum; `protocolForBrand`
    /// never returns this today (`image.rs` disables iTerm2).
    case iterm2
    /// No graphics protocol — text fallback only.
    case none

    /// Whether this protocol can render pixel images inline.
    public var supportsImages: Bool {
        self != .none
    }
}

/// Kitty graphics protocol image format identifier (`f=`).
///
/// Only PNG (`f=100`) is accepted; callers pass already-encoded PNG bytes.
public enum KittyGraphicsFormat: UInt16, Sendable, Equatable, Hashable {
    /// PNG image data (`f=100`).
    case png = 100

    /// Kitty `f=` code.
    public var code: UInt16 { rawValue }
}

// MARK: - Process-wide force-off (`INLINE_OVERLAY_FORCE_OFF`)

/// Process-wide flag: when set, scrollback inline-media overlays stay off
/// regardless of terminal capability. Default `false`.
///
/// Pin uses a `Relaxed` `AtomicBool` (`image.rs`); Swift has no stdlib atomic
/// bool without an extra package, so this is a lock-backed store with the
/// same process-wide lifetime. Tests that mutate it must restore the value.
private final class InlineOverlayForceOffStore: @unchecked Sendable {
    static let shared = InlineOverlayForceOffStore()

    private let lock = NSLock()
    private var off = false

    private init() {}

    func set(_ value: Bool) {
        lock.lock()
        off = value
        lock.unlock()
    }

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return off
    }
}

/// Force scrollback inline-media overlays off (`off = true`) or restore the
/// capability-based default (`off = false`) process-wide.
///
/// Pin: `set_inline_overlay_force_off` (`image.rs`). Called once at startup
/// by the pager when minimal mode is active.
public func setInlineOverlayForceOff(_ off: Bool) {
    InlineOverlayForceOffStore.shared.set(off)
}

/// Whether scrollback inline-media overlays are currently forced off.
///
/// Pin: `scrollback_inline_overlay_forced_off` (`image.rs`). Default `false`.
public func scrollbackInlineOverlayForcedOff() -> Bool {
    InlineOverlayForceOffStore.shared.get()
}

// MARK: - Encoder

/// Pin-correct Kitty / iTerm2 graphics encoder.
///
/// Does not rasterize: transmit/render take already-encoded PNG bytes.
public enum KittyGraphics: Sendable {
    /// Shared overlay placement ID (`KITTY_PLACEMENT_ID`). Overlay `a=T`
    /// render uses this; scrollback transmit/place/delete take a caller ID.
    public static let placementID: UInt32 = 1

    /// Base64 chunk size used by `kitty_chunked_escape`.
    public static let chunkSize = 4096

    /// PNG magic used by pin `mime_from_bytes` / `kitty_format_from_bytes`.
    public static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    /// Map terminal brand to graphics protocol.
    ///
    /// Pin: `protocol_for_brand` (`image.rs`). Windows is always `.none`
    /// because ConPTY strips Kitty/iTerm2 APC sequences. iTerm2 is `.none`
    /// because OSC 1337 lacks image-id / z-index / crop / clear, so overlay
    /// images do not track the text grid.
    public static func protocolForBrand(
        brand: MouseScrollTerminalBrand,
        isWindows: Bool = false
    ) -> KittyGraphicsProtocol {
        if isWindows {
            return .none
        }
        switch brand {
        case .kitty, .ghostty, .wezTerm, .warpTerminal:
            return .kitty
        case .iterm2:
            // Pin disables iTerm2 inline; text fallback is used instead.
            return .none
        default:
            return .none
        }
    }

    /// Pure brand+protocol check for scrollback inline-media overlays.
    ///
    /// Pin: `scrollback_inline_overlay_active_for_brand`. Narrower than
    /// "supports Kitty": Warp accepts some Kitty escapes but not the
    /// placement/scrollback model, so it stays off.
    public static func scrollbackOverlayActiveForBrand(
        protocol proto: KittyGraphicsProtocol,
        brand: MouseScrollTerminalBrand
    ) -> Bool {
        guard proto == .kitty else { return false }
        switch brand {
        case .kitty, .ghostty, .wezTerm:
            return true
        default:
            return false
        }
    }

    /// Scrollback overlay active after applying the process-wide force-off.
    ///
    /// Pin: `scrollback_inline_overlay_active` minus host-terminal detection
    /// (that cache lives in pager-render glue).
    public static func scrollbackOverlayActive(
        protocol proto: KittyGraphicsProtocol,
        brand: MouseScrollTerminalBrand
    ) -> Bool {
        if scrollbackInlineOverlayForcedOff() {
            return false
        }
        return scrollbackOverlayActiveForBrand(protocol: proto, brand: brand)
    }

    /// Detect Kitty format from encoded bytes. PNG only; no conversion.
    ///
    /// Pin: `kitty_format_from_bytes` via `mime_from_bytes` PNG magic.
    public static func formatFromBytes(_ imageData: Data) -> KittyGraphicsFormat? {
        if imageData.starts(with: pngSignature) {
            return .png
        }
        return nil
    }

    /// Transmit + display (`a=T`) at the shared overlay placement ID.
    ///
    /// Pin: `render_kitty_image` defaults `z=1` (above text, modal overlays).
    public static func render(
        imageData: Data,
        format: KittyGraphicsFormat = .png,
        cols: UInt16,
        rows: UInt16
    ) -> String {
        renderZ(imageData: imageData, format: format, cols: cols, rows: rows, z: 1)
    }

    /// Transmit + display (`a=T`) with an explicit z-index.
    ///
    /// `z=1`: above text. `z=-1`: below text, above background (scrollback).
    public static func renderZ(
        imageData: Data,
        format: KittyGraphicsFormat = .png,
        cols: UInt16,
        rows: UInt16,
        z: Int32
    ) -> String {
        let header = "a=T,f=\(format.code),t=d,q=2,C=1,z=\(z),i=\(placementID),p=\(placementID),c=\(cols),r=\(rows)"
        return chunkedEscape(imageData: imageData, firstChunkHeader: header)
    }

    /// Transmit image data without displaying it (`a=t`).
    ///
    /// Uses the caller-supplied `imageId` — not the overlay placement ID.
    /// Pin: `transmit_kitty_image`.
    public static func transmit(
        imageData: Data,
        format: KittyGraphicsFormat = .png,
        imageId: UInt32
    ) -> String {
        let header = "a=t,f=\(format.code),t=d,q=2,i=\(imageId)"
        return chunkedEscape(imageData: imageData, firstChunkHeader: header)
    }

    /// Place an already-transmitted image at the cursor (`a=p`).
    ///
    /// Pin: `place_kitty_image` — `p` equals the image id, not a hardcoded 1.
    public static func place(
        imageId: UInt32,
        cols: UInt16,
        rows: UInt16,
        z: Int32
    ) -> String {
        "\u{1b}_Ga=p,i=\(imageId),p=\(imageId),c=\(cols),r=\(rows),z=\(z),C=1,q=2\u{1b}\\"
    }

    /// Place an already-transmitted image with source cropping (`a=p`).
    ///
    /// Pin: `place_kitty_image_cropped`. Used so scrollback images crop as
    /// the text grid scrolls rather than leaving stale pixels.
    public static func placeCropped(
        imageId: UInt32,
        cols: UInt16,
        rows: UInt16,
        z: Int32,
        srcX: UInt32,
        srcY: UInt32,
        srcW: UInt32,
        srcH: UInt32
    ) -> String {
        "\u{1b}_Ga=p,i=\(imageId),p=\(imageId),c=\(cols),r=\(rows),z=\(z),x=\(srcX),y=\(srcY),w=\(srcW),h=\(srcH),C=1,q=2\u{1b}\\"
    }

    /// Delete a specific image by ID (`a=d,d=i`).
    ///
    /// Pin: `clear_kitty_image` — ID-specific; no `p=` field.
    public static func clear(imageId: UInt32) -> String {
        "\u{1b}_Ga=d,d=i,i=\(imageId),q=2\u{1b}\\"
    }

    /// Crop-on-scroll placement for a previously transmitted image (`z=-1`).
    ///
    /// Pin: Kitty branch of `place_inline_image` without the cursor prefix
    /// (cursor positioning stays in pager-render glue).
    public static func placeForScrollback(
        imageId: UInt32,
        imgW: UInt32,
        imgH: UInt32,
        areaWidth: UInt16,
        areaHeight: UInt16,
        fullRows: UInt16,
        topCropRows: UInt16
    ) -> String {
        let fit = fitImageToCells(imgW: imgW, imgH: imgH, maxCols: areaWidth, maxRows: fullRows)
        let visibleRows = min(areaHeight, fit.rows)
        if topCropRows > 0 || visibleRows < fit.rows {
            let srcY: UInt32
            let srcH: UInt32
            if fit.rows > 0 {
                srcY = (UInt32(topCropRows) * imgH) / UInt32(fit.rows)
                srcH = (UInt32(visibleRows) * imgH) / UInt32(fit.rows)
            } else {
                srcY = 0
                srcH = imgH
            }
            return placeCropped(
                imageId: imageId,
                cols: fit.cols,
                rows: visibleRows,
                z: -1,
                srcX: 0,
                srcY: srcY,
                srcW: imgW,
                srcH: max(srcH, 1)
            )
        }
        return place(imageId: imageId, cols: fit.cols, rows: fit.rows, z: -1)
    }

    /// Cell dimensions that preserve pixel aspect inside `maxCols × maxRows`.
    ///
    /// Pin: `fit_image_to_cells`. Terminal cells are treated as 0.5 wide/tall.
    public static func fitImageToCells(
        imgW: UInt32,
        imgH: UInt32,
        maxCols: UInt16,
        maxRows: UInt16
    ) -> (cols: UInt16, rows: UInt16) {
        if imgW == 0 || imgH == 0 || maxCols == 0 || maxRows == 0 {
            return (max(maxCols, 1), max(maxRows, 1))
        }

        let cellAspect = 0.5
        let imgAspect = Double(imgW) / Double(imgH)
        let colsPerRow = imgAspect / cellAspect

        let colsByWidth = maxCols
        let rowsByWidth = u16FromRounded(Double(colsByWidth) / colsPerRow)

        let rowsByHeight = maxRows
        let colsByHeight = u16FromRounded(Double(rowsByHeight) * colsPerRow)

        if rowsByWidth <= maxRows {
            return (colsByWidth, max(rowsByWidth, 1))
        }
        return (min(max(colsByHeight, 1), maxCols), rowsByHeight)
    }

    /// iTerm2 OSC 1337 helper. Gated off by `protocolForBrand` (returns `.none`
    /// for `.iterm2`); kept so glue can call it if the pin re-enables iTerm2.
    public static func renderITerm2Image(
        imageData: Data,
        cols: UInt16,
        rows: UInt16
    ) -> String {
        let b64 = imageData.base64EncodedString()
        return "\u{1b}]1337;File=inline=1;width=\(cols)cells;height=\(rows)cells;preserveAspectRatio=1:\(b64)\u{07}"
    }

    /// Encode image data as chunked Kitty APC sequences.
    ///
    /// Pin: `kitty_chunked_escape`. Continuation chunks carry `q=2,m=` —
    /// the diverged PagerRender encoder omits `q=2` here.
    public static func chunkedEscape(imageData: Data, firstChunkHeader: String) -> String {
        let b64 = imageData.base64EncodedString()
        if b64.isEmpty {
            return ""
        }

        var out = ""
        var offset = b64.startIndex
        var index = 0
        while offset < b64.endIndex {
            let next = b64.index(offset, offsetBy: chunkSize, limitedBy: b64.endIndex) ?? b64.endIndex
            let chunk = b64[offset..<next]
            let isLast = next == b64.endIndex
            let more = isLast ? 0 : 1
            if index == 0 {
                out += "\u{1b}_G\(firstChunkHeader),m=\(more);\(chunk)\u{1b}\\"
            } else {
                out += "\u{1b}_Gq=2,m=\(more);\(chunk)\u{1b}\\"
            }
            index += 1
            offset = next
        }
        return out
    }
}

private func u16FromRounded(_ value: Double) -> UInt16 {
    let rounded = value.rounded()
    if rounded <= 0 { return 0 }
    if rounded >= Double(UInt16.max) { return UInt16.max }
    return UInt16(rounded)
}
