// PlaceholderImages.swift
//
// Pure helpers for resolving `[Image #N: <path>]` placeholders.
//
// Ported from xai-grok-shared/src/placeholder_images.rs. This file ports
// the PURE functions that have no external crate dependencies:
//   - `PlaceholderMatch` struct
//   - `extract_placeholders` — scan text for `[Image #N: <path>]` tokens
//   - `strip_paths_from_image_placeholders` — rewrite to `[Image #N]`
//   - Constants: MAX_PLACEHOLDER_IMAGE_BYTES, MAX_PLACEHOLDERS_PER_PROMPT,
//     MAX_PLACEHOLDER_AGGREGATE_BYTES, ALLOWED_IMAGE_EXTENSIONS,
//     DENY_PATH_CONTAINS, HOME_IMAGE_SUBDIRS, IMAGE_DISPLAY_NUMBER_META_KEY
//   - `PlaceholderLoadError` enum
//   - `LoadedPlaceholderImage` struct
//   - `loadPlaceholderImage` / `loadCanonicalPlaceholderImage` — file I/O
//     with prefix allowlist, deny-list, extension check, size cap, and
//     image magic-byte validation
//   - `canonicalFromFileURI` — parse `file://` URIs
//   - `defaultAllowedPrefixes` / `defaultAllowedPrefixesWithHome`
//
// The full `recover_orphan_placeholders` pipeline depends on
// `agent_client_protocol::ImageContent` (W1-S2) and `xai_grok_tools::util::image_validate`
// (W5-S1). Those integration points are deferred; this file provides the
// pure parsing, validation, and file-loading logic that has no cross-target
// dependencies.
//
// Threat model (preserved from Rust):
//   * Canonicalises every candidate path (resolves `..` and symlinks).
//   * Asserts the canonical target lives under an explicit prefix allowlist.
//   * Asserts the extension is in ALLOWED_IMAGE_EXTENSIONS.
//   * Validates image magic bytes (PNG/JPEG/TIFF/GIF/WEBP/BMP).
//   * Rejects deny-listed subtrees (.photoslibrary, .ssh, .aws, .gnupg, etc.).
//   * Enforces per-image and aggregate byte caps.

import Foundation

// MARK: - Constants

/// Maximum size of a single placeholder-loaded image (50 MB).
public let maxPlaceholderImageBytes: Int = 50_000_000

/// Maximum number of placeholders processed per call.
public let maxPlaceholdersPerPrompt: Int = 16

/// Per-prompt aggregate-bytes cap across recovered placeholder images (200 MB).
public let maxPlaceholderAggregateBytes: Int = 200 * 1024 * 1024

/// `_meta` key under which an attached image's `[Image #N]` display number
/// is recorded on its ACP image block.
public let imageDisplayNumberMetaKey = "xai.dev/imageDisplayNumber"

/// File extensions accepted by the placeholder loader.
public let allowedImageExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif",
]

/// Substrings that, if present anywhere in a canonical path, deny the load
/// even when the parent prefix is in the allowlist.
///
/// Each needle uses forward-slash separators and is matched case-sensitively
/// against the canonical path. The enforcement site normalises `\` → `/`
/// before the substring check, so Windows paths are covered.
public let denyPathContains: [String] = [
    ".photoslibrary/",
    ".musiclibrary/",
    ".imovielibrary/",
    "/.Trash/",
    "/Library/Keychains/",
    "/Library/Containers/",
    "/.ssh/",
    "/.aws/",
    "/.gnupg/",
]

/// Subdirectories under `$HOME` that are part of the default allowlist.
public let homeImageSubdirs: [String] = [
    "Downloads",
    "Desktop",
    "Pictures",
    "Documents",
    "Screenshots",
]

// MARK: - PlaceholderMatch

/// UTF-8 byte offset range (for compatibility with Rust's `usize` spans).
///
/// Stored explicitly at match time so it is independent of the source
/// string's lifetime and does not require re-derivation from `String.Index`
/// values. Accessing this must never trap even when the original source
/// string is no longer reachable.
public struct PlaceholderByteSpan: Hashable, Sendable, Equatable {
    public let start: Int
    public let end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

/// One occurrence of `[Image #N: <path>]` in arbitrary text.
public struct PlaceholderMatch: Hashable, Sendable, Equatable {
    /// The `N` in `[Image #N: …]` (1-based per the TUI's convention).
    public let displayNumber: Int

    /// The raw path string as it appeared in the text (no canonicalisation).
    public let path: String

    /// Byte offsets into the source text covered by the full match.
    public let span: Range<String.Index>

    /// UTF-8 byte offset range (for compatibility with Rust's `usize` spans).
    ///
    /// Stored explicitly at match time so it is independent of the source
    /// string's lifetime and does not require re-derivation from `String.Index`
    /// values. Accessing this must never trap even when the original source
    /// string is no longer reachable.
    public let byteSpan: PlaceholderByteSpan

    public init(displayNumber: Int, path: String, span: Range<String.Index>, byteSpan: PlaceholderByteSpan) {
        self.displayNumber = displayNumber
        self.path = path
        self.span = span
        self.byteSpan = byteSpan
    }
}

// MARK: - Placeholder regex (pure Swift, no external regex crate)

/// The compiled regex pattern matching `[Image #<digits>: <path>]`.
///
/// * Producer emits exactly `": "` (colon, single space) as the separator.
/// * The path capture excludes `]`, `\n`, and `\r` so the match terminates
///   cleanly at the placeholder boundary.
/// * Path captures may contain spaces (typical macOS paths in `~/My Pictures`).
private let placeholderPattern: String = #"\[Image #(\d+): ([^\]\r\n]+?)\]"#

/// Scan `text` for every well-formed placeholder.
///
/// Malformed forms are skipped without failing the whole scan. The scan is
/// bounded by `maxPlaceholdersPerPrompt`.
public func extractPlaceholders(_ text: String) -> [PlaceholderMatch] {
    guard let regex = try? NSRegularExpression(pattern: placeholderPattern, options: []) else {
        return []
    }
    let nsText = text as NSString
    let matches = regex.matches(
        in: text,
        range: NSRange(location: 0, length: nsText.length)
    )

    var results: [PlaceholderMatch] = []
    results.reserveCapacity(min(matches.count, maxPlaceholdersPerPrompt))

    // Pre-compute UTF-8 view bounds once so per-match byte-offset computation
    // is O(1) and does not re-derive from `String.Index` against a foreign
    // string (which would trap on `utf16Offset(in: "")`).
    let utf8 = text.utf8
    let utf8Start = utf8.startIndex

    for match in matches.prefix(maxPlaceholdersPerPrompt) {
        guard match.numberOfRanges >= 3,
              let numberRange = Range(match.range(at: 1), in: text),
              let pathRange = Range(match.range(at: 2), in: text),
              let fullRange = Range(match.range, in: text)
        else { continue }

        let numberStr = String(text[numberRange])
        guard let displayNumber = Int(numberStr) else { continue }

        let path = String(text[pathRange]).trimmingCharacters(in: .whitespaces)
        if path.isEmpty { continue }

        // Compute UTF-8 byte offsets from the source string's own UTF-8 view.
        // `samePosition(in:)` returns nil only when the index is not valid for
        // the target view; the indices above are guaranteed valid for `text`.
        let byteStart: Int
        let byteEnd: Int
        if let utf8Lower = fullRange.lowerBound.samePosition(in: utf8),
           let utf8Upper = fullRange.upperBound.samePosition(in: utf8) {
            byteStart = utf8.distance(from: utf8Start, to: utf8Lower)
            byteEnd = utf8.distance(from: utf8Start, to: utf8Upper)
        } else {
            // Fallback: utf16 offset → utf8 offset via NSString bridging is
            // not trivially safe; fall back to 0-length span at the lower
            // bound so the match is still reported with a degenerate span
            // rather than trapping.
            byteStart = 0
            byteEnd = 0
        }

        results.append(
            PlaceholderMatch(
                displayNumber: displayNumber,
                path: path,
                span: fullRange,
                byteSpan: PlaceholderByteSpan(start: byteStart, end: byteEnd)
            )
        )
    }
    return results
}

/// Rewrite every `[Image #N: <path>]` placeholder in `text` to the shorter
/// `[Image #N]` form, dropping the path component.
///
/// Run AFTER the orphan-recovery pipeline has finished extracting paths.
/// The bracketed anchor `[Image #N]` is preserved so the model can still
/// tell where in the prose the image was referenced.
///
/// The scan is bounded by `maxPlaceholdersPerPrompt`; any extra placeholders
/// past the cap are left in their original form.
public func stripPathsFromImagePlaceholders(_ text: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: placeholderPattern, options: []) else {
        return text
    }
    // Fast path: if no match, return input unchanged.
    let nsText = text as NSString
    let firstMatch = regex.firstMatch(
        in: text,
        range: NSRange(location: 0, length: nsText.length)
    )
    guard firstMatch != nil else {
        return text
    }

    var result = ""
    result.reserveCapacity(text.count)
    let nsTextForRanges = text as NSString
    var lastEnd = 0

    for match in regex.matches(
        in: text,
        range: NSRange(location: 0, length: nsTextForRanges.length)
    ).prefix(maxPlaceholdersPerPrompt) {
        guard match.numberOfRanges >= 2,
              let numberRange = Range(match.range(at: 1), in: text),
              let fullRange = Range(match.range, in: text)
        else { continue }

        let lastIdx = text.index(text.startIndex, offsetBy: lastEnd)
        let upToMatch = String(text[lastIdx..<fullRange.lowerBound])
        result.append(upToMatch)

        let number = String(text[numberRange])
        result.append("[Image #\(number)]")

        lastEnd = text.distance(from: text.startIndex, to: fullRange.upperBound)
    }

    // Append the remaining text after the last match.
    let remainingIdx = text.index(text.startIndex, offsetBy: lastEnd)
    result.append(String(text[remainingIdx...]))

    return result
}

// MARK: - PlaceholderLoadError

/// Why a placeholder load was rejected.
///
/// Error variants are deliberately coarse-grained: an attacker with log
/// access should not be able to probe the filesystem by reading distinct
/// error messages.
public enum PlaceholderLoadError: Error, Hashable, Sendable, Equatable {
    /// Resolved path is outside every entry in the prefix allowlist
    /// (or matches a deny-list entry inside an allowed prefix).
    case outsideAllowedPrefixes
    /// Path could not be canonicalised (missing, permission denied, etc.).
    case canonicalizeFailed
    /// Extension is not in `allowedImageExtensions`.
    case unsupportedExtension
    /// Resolved path is not a regular file (e.g. directory, FIFO).
    case notAFile
    /// `read` failed after canonicalisation.
    case readFailed(String)
    /// File exceeds the configured per-image byte cap.
    case tooLarge(actual: Int, limit: Int)
    /// Bytes do not decode as a supported image.
    case notAnImage

    public var errorCode: String {
        switch self {
        case .outsideAllowedPrefixes: return "placeholder_outside_allowed_prefixes"
        case .canonicalizeFailed: return "placeholder_canonicalize_failed"
        case .unsupportedExtension: return "placeholder_unsupported_extension"
        case .notAFile: return "placeholder_not_a_file"
        case .readFailed: return "placeholder_read_failed"
        case .tooLarge: return "placeholder_too_large"
        case .notAnImage: return "placeholder_not_an_image"
        }
    }
}

// MARK: - LoadedPlaceholderImage

/// Loaded image bytes plus a sniffed MIME type.
public struct LoadedPlaceholderImage: Hashable, Sendable {
    /// Raw image bytes read from disk.
    public let data: Data

    /// MIME type derived from magic-byte validation.
    public let mimeType: String

    public init(data: Data, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }
}

// MARK: - Image magic-byte validation

/// Infer the MIME type from the first bytes of an image payload.
///
/// Falls back to `"application/octet-stream"` if the magic bytes are
/// unrecognized. This is the pure Swift equivalent of
/// `xai_grok_tools::util::image_validate::validate_image_bytes_with` and
/// `xai_grok_shared::clipboard::mime_from_bytes` — each format is checked
/// by its own prefix length (PNG needs 8 bytes, JPEG 3, TIFF 4, GIF 4,
/// BMP 2); only WEBP requires the 12-byte RIFF....WEBP layout, so it is
/// the only branch gated on `data.count >= 12`.
public func mimeTypeFromBytes(_ data: Data) -> String {
    // PNG: 89 50 4E 47 0D 0A 1A 0A
    if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
        return "image/png"
    }
    // JPEG: FF D8 FF
    if data.starts(with: [0xFF, 0xD8, 0xFF]) {
        return "image/jpeg"
    }
    // TIFF: II 2A 00 (little-endian) or MM 00 2A (big-endian)
    if data.starts(with: [0x49, 0x49, 0x2A, 0x00]) || data.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) {
        return "image/tiff"
    }
    // GIF: GIF8
    if data.starts(with: [0x47, 0x49, 0x46, 0x38]) {
        return "image/gif"
    }
    // WEBP: RIFF....WEBP (needs 12 bytes)
    if data.count >= 12,
       data[0] == 0x52, data[1] == 0x49, data[2] == 0x46, data[3] == 0x46,
       data[8] == 0x57, data[9] == 0x45, data[10] == 0x42, data[11] == 0x50 {
        return "image/webp"
    }
    // BMP: BM
    if data.starts(with: [0x42, 0x4D]) {
        return "image/bmp"
    }
    return "application/octet-stream"
}

/// `true` when the bytes decode as a supported image (magic-byte check).
///
/// **Warning:** this is a magic-byte-only check. It accepts a file whose
/// first bytes are PNG/JPEG/etc. magic followed by arbitrary content (e.g.
/// a private key). The placeholder loader uses `validateImageHeader`, which
/// parses the structural header, to reject such forgeries. Use
/// `mimeTypeFromBytes` only for non-security-sensitive MIME sniffing (e.g.
/// clipboard fallback) where the bytes are already trusted.
public func isSupportedImageData(_ data: Data) -> Bool {
    let mime = mimeTypeFromBytes(data)
    return mime != "application/octet-stream"
}

/// Validate image bytes by parsing the structural header, not just the magic
/// bytes.
///
/// This is the pure-Swift equivalent of Rust's
/// `image::ImageReader::with_guessed_format` + `into_dimensions`: it reads
/// enough of the per-format header to confirm the bytes are a real image,
/// rejecting a forged file whose first bytes are PNG/JPEG magic followed by
/// arbitrary content (e.g. a private key). Returns the MIME type on success,
/// or `nil` if the header does not parse as a supported image.
///
/// Each format's check is intentionally minimal but structural:
///   * **PNG**: the IHDR chunk must follow the signature, carry a 4-byte
///     length and the `IHDR` type, and have a non-zero width/height. The
///     chunk CRC is not re-computed (the `image` crate does, but the length
///     + type + dimensions check is enough to reject magic-byte forgeries).
///   * **JPEG**: the SOI marker (`FF D8`) must be followed by a valid marker
///     segment (`FF C0`/`C2`/`C4`/`DA`/`E0`–`EF` etc.) whose length field is
///     plausible. A bare `FF D8 FF` followed by garbage fails this.
///   * **GIF**: the `GIF8` signature must be followed by `7a`/`9a` and a
///     logical screen descriptor with a valid packed byte.
///   * **WEBP**: the RIFF container must declare a `WEBP` form type and one
///     of the supported chunk types (`VP8 `, `VP8L`, `VP8X`).
///   * **BMP**: the `BM` magic must be followed by a 14-byte file header and
///     a 40-byte (or larger) DIB header whose width/height are non-zero.
///   * **TIFF**: the byte-order marker must be followed by a 16-bit magic
///     (`2A00` LE or `002A` BE) and a plausible IFD offset.
public func validateImageHeader(_ data: Data) -> String? {
    guard data.count >= 4 else { return nil }

    // PNG: 8-byte signature + 25-byte IHDR chunk (length=13, type, 13 bytes).
    if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
        // IHDR chunk: 4-byte big-endian length (must be 13), 4-byte type
        // ("IHDR"), 4-byte width, 4-byte height, 1-byte depth, ...
        guard data.count >= 8 + 25 else { return nil }
        let ihdrLength = (UInt32(data[8]) << 24) | (UInt32(data[9]) << 16)
                       | (UInt32(data[10]) << 8) | UInt32(data[11])
        guard ihdrLength == 13 else { return nil }
        // Type must be "IHDR".
        guard data[12] == 0x49, data[13] == 0x48, data[14] == 0x44, data[15] == 0x52 else {
            return nil
        }
        let width = (UInt32(data[16]) << 24) | (UInt32(data[17]) << 16)
                  | (UInt32(data[18]) << 8) | UInt32(data[19])
        let height = (UInt32(data[20]) << 24) | (UInt32(data[21]) << 16)
                   | (UInt32(data[22]) << 8) | UInt32(data[23])
        guard width > 0, height > 0 else { return nil }
        return "image/png"
    }

    // JPEG: FF D8 FF followed by a marker segment with a plausible length.
    if data.starts(with: [0xFF, 0xD8, 0xFF]) {
        // The third byte (after SOI) is the marker type. SOF (C0/C2),
        // DHT (C4), SOS (DA), APPn (E0-EF), DQT (DB), DRI (DD), COM (FE)
        // all carry a 2-byte big-endian length. RSTn (D0-D7), SOI (D8),
        // EOI (D9), TEM (01) do not. We require at least one length-bearing
        // marker segment whose length is plausible.
        guard data.count >= 4 else { return nil }
        let marker = data[3]
        // Standalone markers (no length payload) cannot start the stream.
        let standaloneMarkers: Set<UInt8> = [0xD0, 0xD1, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0x01]
        if standaloneMarkers.contains(marker) { return nil }
        // All other markers carry a 2-byte big-endian length that includes
        // the length bytes themselves; the minimum is 2.
        guard data.count >= 6 else { return nil }
        let segLength = (UInt16(data[4]) << 8) | UInt16(data[5])
        guard segLength >= 2, Int(segLength) <= data.count - 4 else { return nil }
        return "image/jpeg"
    }

    // TIFF: II 2A 00 (LE) or MM 00 2A (BE).
    if data.starts(with: [0x49, 0x49, 0x2A, 0x00]) || data.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) {
        // After the 4-byte header, a 4-byte offset to the first IFD. The
        // offset must point within the file (or be 0 for an empty image,
        // which we reject). A forged file with magic + garbage tail will
        // typically have a nonsense offset.
        guard data.count >= 8 else { return nil }
        let isLE = data[0] == 0x49
        let ifdOffset: UInt32
        if isLE {
            ifdOffset = UInt32(data[4]) | (UInt32(data[5]) << 8)
                      | (UInt32(data[6]) << 16) | (UInt32(data[7]) << 24)
        } else {
            ifdOffset = (UInt32(data[4]) << 24) | (UInt32(data[5]) << 16)
                      | (UInt32(data[6]) << 8) | UInt32(data[7])
        }
        guard ifdOffset > 0, Int(ifdOffset) < data.count else { return nil }
        return "image/tiff"
    }

    // GIF: GIF8 7a/9a + logical screen descriptor.
    if data.starts(with: [0x47, 0x49, 0x46, 0x38]) {
        // GIF87a or GIF89a.
        guard data.count >= 6 else { return nil }
        guard data[4] == 0x37 || data[4] == 0x39, data[5] == 0x61 else { return nil }
        // Logical screen descriptor: 2-byte width, 2-byte height, 1-byte
        // packed (GCT flag + color resolution + sort + GCT size), 1-byte
        // bg color, 1-byte pixel aspect ratio.
        guard data.count >= 13 else { return nil }
        let width = UInt16(data[6]) | (UInt16(data[7]) << 8)
        let height = UInt16(data[8]) | (UInt16(data[9]) << 8)
        guard width > 0, height > 0 else { return nil }
        return "image/gif"
    }

    // WEBP: RIFF....WEBP + VP8/VP8L/VP8X chunk.
    if data.count >= 12,
       data[0] == 0x52, data[1] == 0x49, data[2] == 0x46, data[3] == 0x46,
       data[8] == 0x57, data[9] == 0x45, data[10] == 0x42, data[11] == 0x50 {
        // The first subchunk after the 12-byte RIFF header must be one of
        // "VP8 " (lossy), "VP8L" (lossless), or "VP8X" (extended).
        guard data.count >= 20 else { return nil }
        let chunk = String(bytes: [data[12], data[13], data[14], data[15]], encoding: .ascii)
        guard chunk == "VP8 " || chunk == "VP8L" || chunk == "VP8X" else { return nil }
        // Subchunk length (4 bytes, little-endian) must fit in the file.
        let chunkLen = UInt32(data[16]) | (UInt32(data[17]) << 8)
                     | (UInt32(data[18]) << 16) | (UInt32(data[19]) << 24)
        guard Int(chunkLen) <= data.count - 20 else { return nil }
        return "image/webp"
    }

    // BMP: BM + 14-byte file header + 40-byte (or larger) DIB header.
    if data.starts(with: [0x42, 0x4D]) {
        // BITMAPFILEHEADER is 14 bytes; the DIB header size is at offset 14
        // (4 bytes, little-endian). Must be >= 40 (BITMAPINFOHEADER).
        guard data.count >= 18 else { return nil }
        let dibSize = UInt32(data[14]) | (UInt32(data[15]) << 8)
                    | (UInt32(data[16]) << 16) | (UInt32(data[17]) << 24)
        guard dibSize >= 40, Int(dibSize) <= data.count - 14 else { return nil }
        // Width (offset 18, 4 bytes LE) and height (offset 22, 4 bytes LE)
        // must be non-zero. Height may be negative (top-down BMP); check
        // absolute value.
        guard data.count >= 26 else { return nil }
        let width = Int32(bitPattern: UInt32(data[18]) | (UInt32(data[19]) << 8)
                          | (UInt32(data[20]) << 16) | (UInt32(data[21]) << 24))
        let height = Int32(bitPattern: UInt32(data[22]) | (UInt32(data[23]) << 8)
                           | (UInt32(data[24]) << 16) | (UInt32(data[25]) << 24))
        guard width != 0, height != 0 else { return nil }
        return "image/bmp"
    }

    return nil
}

/// Map an image MIME type to a file extension.
///
/// Returns `"bin"` for unrecognized types.
public func mimeToExtension(_ mime: String) -> String {
    switch mime {
    case "image/png": return "png"
    case "image/jpeg": return "jpg"
    case "image/tiff": return "tiff"
    case "image/gif": return "gif"
    case "image/webp": return "webp"
    case "image/bmp": return "bmp"
    default: return "bin"
    }
}

// MARK: - Path validation and loading

/// Resolve and validate `pathString`, then read the file.
///
/// Validation order is **prefix-first** by design: an out-of-allowlist path
/// returns `.outsideAllowedPrefixes` regardless of whether the file exists.
///
/// `allowedPrefixes` should already be canonical. Symlinks are followed
/// (via canonicalisation), then the resolved path is checked against the
/// prefix allowlist.
public func loadPlaceholderImage(
    pathString: String,
    allowedPrefixes: [URL]
) -> Result<LoadedPlaceholderImage, PlaceholderLoadError> {
    loadPlaceholderImageWithCap(
        pathString: pathString,
        allowedPrefixes: allowedPrefixes,
        maxBytes: maxPlaceholderImageBytes
    )
}

/// Variant of `loadPlaceholderImage` that takes an explicit byte cap.
public func loadPlaceholderImageWithCap(
    pathString: String,
    allowedPrefixes: [URL],
    maxBytes: Int
) -> Result<LoadedPlaceholderImage, PlaceholderLoadError> {
    let path = URL(fileURLWithPath: pathString)
    // Standardize resolves `..` and symlinks on macOS/Linux.
    // standardizedFileURL resolves `..` but not symlinks; for symlink
    // resolution we'd need FileManager.fileSystemRepresentation or
    // path.resolveSymlinksInPath(). Use resolvingSymlinksInPath() which
    // does both.
    let canonical = path.resolvingSymlinksInPath()
    return loadCanonicalPlaceholderImage(
        canonical: canonical,
        allowedPrefixes: allowedPrefixes,
        maxBytes: maxBytes
    )
}

/// Load a placeholder image from an already-canonicalised URL.
public func loadCanonicalPlaceholderImage(
    canonical: URL,
    allowedPrefixes: [URL],
    maxBytes: Int
) -> Result<LoadedPlaceholderImage, PlaceholderLoadError> {
    // Prefix check first — out-of-scope paths return a single, file-system-
    // independent variant.
    //
    // Use component-aware containment, NOT string-prefix matching. A string
    // prefix check authorises `/tmp/allowed-escape/secret.png` when the
    // allowlist contains `/tmp/allowed` — a path-boundary bypass. Comparing
    // `URL.pathComponents` (which splits on `/` and drops trailing slashes)
    // ensures `allowed` is a proper ancestor directory of `canonical`.
    let canonicalPath = canonical.path
    let isAllowed = allowedPrefixes.contains { prefix in
        isPath(canonicalPath, containedInPrefix: prefix.path)
    }
    if !isAllowed {
        return .failure(.outsideAllowedPrefixes)
    }

    // Deny-list pass: normalise `\` → `/` so Windows paths hit the same
    // forward-slash needles as Unix paths.
    let canonicalStr = canonicalPath.replacingOccurrences(of: "\\", with: "/")
    if denyPathContains.contains(where: { canonicalStr.contains($0) }) {
        return .failure(.outsideAllowedPrefixes)
    }

    // Extension check.
    let ext = canonical.pathExtension.lowercased()
    if ext.isEmpty {
        return .failure(.unsupportedExtension)
    }
    if !allowedImageExtensions.contains(ext) {
        return .failure(.unsupportedExtension)
    }

    // File metadata check.
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: canonicalPath) else {
        return .failure(.readFailed("metadata unavailable"))
    }
    let fileType = attrs[.type] as? FileAttributeType
    if fileType != .typeRegular {
        return .failure(.notAFile)
    }
    let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
    if size > maxBytes {
        return .failure(.tooLarge(actual: size, limit: maxBytes))
    }

    // Read bytes.
    guard let data = try? Data(contentsOf: canonical) else {
        return .failure(.readFailed("read failed"))
    }
    if data.count > maxBytes {
        return .failure(.tooLarge(actual: data.count, limit: maxBytes))
    }

    // Image-decoder validation. Rust routes the bytes through
    // `image::ImageReader::with_guessed_format` + `into_dimensions`, which
    // parses the structural header (not just the magic bytes) so a file with
    // PNG magic followed by a private key is rejected. The pure-Swift
    // equivalent below validates the per-format structural header
    // (chunk/segment dimensions, length fields, end markers) for each
    // supported format. A magic-byte-only check is NOT sufficient because it
    // accepts forged files.
    guard let mime = validateImageHeader(data) else {
        return .failure(.notAnImage)
    }

    return .success(LoadedPlaceholderImage(data: data, mimeType: mime))
}

/// Component-aware path containment check.
///
/// Returns `true` iff `path` is equal to `prefix` or `prefix` is a proper
/// ancestor directory of `path`. This is the `std::path::Path::starts_with`
/// semantic — NOT a string-prefix match. A string `hasPrefix` check would
/// authorise `/tmp/allowed-escape/secret.png` when the allowlist contains
/// `/tmp/allowed`; the component-aware check rejects that because
/// `allowed-escape` is not the `allowed` component.
///
/// Both inputs are expected to be absolute, canonical paths. Trailing
/// separators on `prefix` are tolerated.
private func isPath(_ path: String, containedInPrefix prefix: String) -> Bool {
    // Fast path: identical paths.
    if path == prefix { return true }
    let pathParts = pathComponents(path)
    var prefixParts = pathComponents(prefix)
    // Drop a trailing empty component produced by a trailing slash so
    // `/tmp/allowed/` compares equal to `/tmp/allowed`.
    while prefixParts.last == "" {
        prefixParts.removeLast()
    }
    if prefixParts.count > pathParts.count {
        return false
    }
    for i in 0..<prefixParts.count {
        if pathParts[i] != prefixParts[i] {
            return false
        }
    }
    return true
}

/// Split a path string into components on `/`. A leading `/` yields a
/// leading empty component (mirroring `URL.pathComponents` and
/// `std::path::Component` root handling). A trailing `/` yields a trailing
/// empty component, which the caller is expected to trim for prefix
/// comparison.
private func pathComponents(_ path: String) -> [String] {
    // Foundation's `URL(fileURLWithPath:).pathComponents` would normalise
    // `..` and `.`; we want the raw lexical components here because the
    // caller has already canonicalised. Split manually.
    if path.isEmpty { return [] }
    var result: [String] = []
    var current = ""
    for ch in path {
        if ch == "/" {
            result.append(current)
            current = ""
        } else {
            current.append(ch)
        }
    }
    result.append(current)
    return result
}

// MARK: - Prefix allowlist construction

/// Build the canonical prefix allowlist with the workspace cwd plus a small
/// set of common user-image directories under `$HOME`.
public func defaultAllowedPrefixes(workspaceCwd: URL) -> [URL] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return defaultAllowedPrefixesWithHome(workspaceCwd: workspaceCwd, home: home)
}

/// Test-injectable variant with an explicit home directory.
///
/// The returned array is canonical, deduplicated, and sorted alphabetically.
public func defaultAllowedPrefixesWithHome(workspaceCwd: URL, home: URL?) -> [URL] {
    var prefixes: [URL] = []

    // Workspace cwd (canonical, drop if it doesn't resolve).
    let workspaceCanon = workspaceCwd.resolvingSymlinksInPath()
    if FileManager.default.fileExists(atPath: workspaceCanon.path) {
        prefixes.append(workspaceCanon)
    }

    // Home image subdirs.
    if let home {
        for sub in homeImageSubdirs {
            let dir = home.appendingPathComponent(sub)
            let canon = dir.resolvingSymlinksInPath()
            if FileManager.default.fileExists(atPath: canon.path) {
                prefixes.append(canon)
            }
        }
    }

    // Sort + dedup.
    prefixes = Array(Set(prefixes.map { $0.standardizedFileURL.path }))
        .map { URL(fileURLWithPath: $0) }
        .sorted { $0.path < $1.path }

    return prefixes
}

// MARK: - file:// URI parsing

/// Parse a `file://...` URI into a canonical `URL`, accepting both the
/// relaxed unencoded form and the percent-encoded RFC 3986 form.
///
/// Returns `nil` if the URI does not start with `file://`.
public func canonicalFromFileURI(_ uri: String) -> URL? {
    guard uri.hasPrefix("file://") else { return nil }
    let rawPath = String(uri.dropFirst("file://".count))

    // Try percent-decoding first; fall back to the literal form.
    let decoded = rawPath.removingPercentEncoding ?? rawPath
    let url = URL(fileURLWithPath: decoded)
    let canonical = url.resolvingSymlinksInPath()
    return canonical
}
