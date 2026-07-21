// Clipboard.swift
//
// Cross-platform clipboard value types and protocol.
//
// Ported from xai-grok-shared/src/clipboard.rs. This file ports the
// platform-neutral value types and the clipboard access protocol. The
// concrete platform implementations (macOS pbcopy/pbpaste + NSPasteboard
// via dlopen, Linux arboard/wl-clipboard/xclip, Windows) are deferred to
// W5-S2 (OpenGrokWebMediaTools) which owns the clipboard tool implementations.
//
// The value types here are used by both the clipboard tool (W5-S2) and the
// placeholder image recovery pipeline (this target), so they live in
// OpenGrokShared as the shared foundation.
//
// Key behavior preserved from Rust:
//   * `ImageData` carries encoded image bytes (not raw RGBA) + MIME type.
//   * `ClipboardAttachments` combines file URLs and image data from one probe.
//   * `NativeWriteOutcome` records per-leg outcomes for telemetry.
//   * `mime_from_bytes` and `mime_to_extension` are pure helpers shared
//     between clipboard and placeholder image validation.
//   * OSC 52 remote clipboard helpers are pure byte-sequence builders.
//   * `is_remote_session` and `is_containerized_without_display` are
//     environment probes that callers use to decide OSC 52 vs native clipboard.

import Foundation

// MARK: - ImageData

/// Encoded image data read from the system clipboard or a placeholder file.
///
/// `data` contains encoded image bytes (PNG, JPEG, TIFF, etc.), not raw RGBA
/// pixels. Suitable for direct persistence and later base64 transport.
public struct ClipboardImageData: Hashable, Sendable, Equatable {
    /// Encoded image bytes (PNG, JPEG, TIFF, etc.).
    public var data: Data

    /// MIME type of the encoded data (e.g. `"image/png"`).
    public var mimeType: String

    public init(data: Data, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }
}

// MARK: - ClipboardAttachments

/// File URLs and/or image data from the system clipboard in one probe.
public struct ClipboardAttachments: Hashable, Sendable, Equatable {
    /// Newline-joined POSIX paths (same format as `getFileUrls`).
    public var fileURLs: String?

    /// Encoded image bytes when the pasteboard holds a raster image.
    public var image: ClipboardImageData?

    public init(fileURLs: String? = nil, image: ClipboardImageData? = nil) {
        self.fileURLs = fileURLs
        self.image = image
    }

    /// `true` when both file URLs and image are absent.
    public var isEmpty: Bool {
        (fileURLs?.isEmpty ?? true) && image == nil
    }
}

// MARK: - NativeWriteOutcome

/// Per-leg outcome of a native clipboard write (for telemetry).
public struct NativeWriteOutcome: Hashable, Sendable, Equatable {
    /// CLI tools attempted (e.g. `["pbcopy"]`, `["wl-copy", "xclip"]`).
    public var cliToolsTried: [String]

    /// Subset of `cliToolsTried` that succeeded (order preserved).
    public var cliOkTools: [String]

    /// `true` if any CLI tool succeeded.
    public var cliOk: Bool

    /// `true` if the arboard library leg succeeded.
    public var arboardOk: Bool

    /// The Wayland data-control protocol was available for this write.
    public var dataControl: Bool

    /// `true` when at least one leg succeeded.
    public var anyOk: Bool

    public init(
        cliToolsTried: [String] = [],
        cliOkTools: [String] = [],
        cliOk: Bool = false,
        arboardOk: Bool = false,
        dataControl: Bool = false,
        anyOk: Bool = false
    ) {
        self.cliToolsTried = cliToolsTried
        self.cliOkTools = cliOkTools
        self.cliOk = cliOk
        self.arboardOk = arboardOk
        self.dataControl = dataControl
        self.anyOk = anyOk
    }
}

// MARK: - ClipboardProvider protocol

/// Read/write access to the system clipboard, capability/permission mediated.
///
/// The concrete platform implementation (macOS pbcopy/pbpaste + NSPasteboard,
/// Linux wl-clipboard/xclip/arboard, Windows) is provided by W5-S2
/// (OpenGrokWebMediaTools). This protocol lets shared code reference
/// clipboard operations without importing platform-specific modules.
public protocol ClipboardProvider: Sendable {
    /// Read text from the system clipboard.
    /// Returns `nil` when the clipboard is empty or does not contain text.
    func getText() async throws -> String?

    /// Read an image from the system clipboard.
    /// Returns `nil` when the clipboard does not contain an image.
    func getImage() async throws -> ClipboardImageData?

    /// Read file references the file manager places on the clipboard.
    /// Returns newline-joined absolute paths, or `nil` when none.
    func getFileURLs() async throws -> String?

    /// Probe file URLs then image in one call.
    func getAttachments() async throws -> ClipboardAttachments

    /// Write text and return per-leg outcomes for telemetry.
    func setTextWithOutcome(_ text: String) async throws -> NativeWriteOutcome

    /// Write text to the system clipboard.
    func setText(_ text: String) async throws

    /// Copy an image file to the system clipboard.
    func setImageFile(at path: URL) async throws
}

/// Errors from clipboard operations.
public enum ClipboardError: Error, Hashable, Sendable, Equatable {
    case unsupported(String)
    case unavailable(String)
    case readFailed(String)
    case writeFailed(String)
}

// MARK: - OSC 52 remote clipboard (pure byte builders)

/// Build the OSC 52 clipboard-set byte sequence.
///
/// When `tmuxPassthrough` is true, wrap in the tmux DCS passthrough envelope
/// (only correct when tmux is the IMMEDIATE terminal); otherwise emit a plain
/// OSC 52.
public func osc52Sequence(text: String, tmuxPassthrough: Bool) -> Data {
    let encoded = Data(text.utf8).base64EncodedString()
    if tmuxPassthrough {
        let str = "\u{1b}Ptmux;\u{1b}\u{1b}]52;c;\(encoded)\u{07}\u{1b}\\"
        return Data(str.utf8)
    } else {
        let str = "\u{1b}]52;c;\(encoded)\u{07}"
        return Data(str.utf8)
    }
}

// MARK: - Environment probes

/// Returns `true` when the process appears to be running inside a remote
/// SSH session (with or without a multiplexer like tmux/screen).
///
/// Checks for `SSH_CONNECTION`, `SSH_TTY`, or `SSH_CLIENT` environment
/// variables set by the OpenSSH server on the remote side.
public func isRemoteSession(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
    environment["SSH_CONNECTION"] != nil
        || environment["SSH_TTY"] != nil
        || environment["SSH_CLIENT"] != nil
}

/// Returns `true` when the process appears to be running inside a container
/// (Docker, Podman, Kubernetes, etc.) without a display server.
///
/// In this environment the native system clipboard will fail because there
/// is no X11/Wayland compositor. OSC 52 terminal escapes are the only viable
/// clipboard path.
public func isContainerizedWithoutDisplay(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
) -> Bool {
    // If a display server is available, native clipboard should work.
    if environment["DISPLAY"] != nil || environment["WAYLAND_DISPLAY"] != nil {
        return false
    }
    // Docker creates this sentinel file in every container.
    if fileManager.fileExists(atPath: "/.dockerenv") {
        return true
    }
    // Podman creates this file.
    if fileManager.fileExists(atPath: "/run/.containerenv") {
        return true
    }
    // Many container runtimes set this env var (podman, systemd-nspawn, etc.).
    if environment["container"] != nil {
        return true
    }
    return false
}

/// The clipboard tool used for native writes on the current platform.
///
/// Returns `"pbcopy"` on macOS, the probed CLI tool name on Linux, or
/// `"arboard"` as a fallback. The actual probing is deferred to W5-S2; this
/// helper returns the expected default for the current platform.
public func nativeClipboardToolName() -> String {
    #if os(macOS)
    return "pbcopy"
    #elseif os(Linux)
    return "arboard" // W5-S2 probes wl-copy/xclip/xsel at runtime
    #else
    return "arboard"
    #endif
}

/// Whether the fast image probe exists on this platform.
public func clipboardImageProbeSupported() -> Bool {
    #if os(macOS)
    return true
    #else
    return false
    #endif
}

// MARK: - macOS attachments protocol parsing (pure, no I/O)

/// Constants for the macOS unified attachments osascript stdout parsing.
public enum AttachmentsProtocol {
    public static let furlMarker = "<<<FURL>>>"
    public static let imageMarker = "<<<IMAGE>>>"
}

/// Parse the stdout payload of the `get_file_urls` AppleScript.
///
/// The script returns one of:
/// - one or more POSIX paths separated by `\n` (success), or
/// - the literal string `"none"` (no file URLs present), or
/// - empty / whitespace-only (degenerate cases that map to `nil`).
public func parseOsascriptFurlOutput(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || trimmed == "none" {
        return nil
    }
    return trimmed
}

/// Parse stdout from the unified attachments AppleScript.
///
/// Format:
/// ```
/// <<<FURL>>>
/// {none | one or more POSIX paths separated by newlines}
/// <<<IMAGE>>>
/// IMAGE:{NONE | PNGf | TIFF | JPEG}
/// ```
///
/// File URLs take precedence over the image class at the `getAttachments`
/// layer (image bytes are not read if `fileURLs` is non-nil).
public func parseAttachmentsOutput(_ raw: String) -> (fileURLs: String?, imageClass: String?) {
    let (furlSection, imageLine): (String, String?)
    if let range = raw.range(of: AttachmentsProtocol.imageMarker) {
        furlSection = String(raw[raw.startIndex..<range.lowerBound])
        imageLine = String(raw[range.upperBound...])
    } else {
        furlSection = raw
        imageLine = nil
    }

    let fileURLs: String?
    if furlSection.contains(AttachmentsProtocol.furlMarker) {
        let body = furlSection
            .replacingOccurrences(of: AttachmentsProtocol.furlMarker, with: "")
            .drop(while: { $0 == "\n" || $0 == "\r" })
        fileURLs = parseOsascriptFurlOutput(String(body))
    } else {
        fileURLs = nil
    }

    let imageClass: String?
    if let line = imageLine {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("IMAGE:") {
            let value = String(trimmed.dropFirst("IMAGE:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if value != "NONE" && !value.isEmpty {
                switch value {
                case "PNGf", "TIFF", "JPEG":
                    imageClass = value
                default:
                    imageClass = nil
                }
            } else {
                imageClass = nil
            }
        } else {
            imageClass = nil
        }
    } else {
        imageClass = nil
    }

    return (fileURLs, imageClass)
}
