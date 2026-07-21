// OpenGrokWebMediaTools.swift
//
// Bootstrap scaffold for the clipboard portability seam (W5-S2 owns the full
// web/media/computer/clipboard tool implementations). Clipboard access is
// platform-specific (macOS NSPasteboard / Linux wl-clipboard/xclip / Windows
// clipboard API) and is isolated behind `ClipboardProvider` so platform-neutral
// callers exchange typed results and `ClipboardError.unsupported` rather than
// conditional code.
//
// Reference: xai-grok-tools clipboard implementation.

import Foundation

/// Clipboard errors.
public enum ClipboardError: Error, Equatable, Sendable {
    case empty
    case accessDenied(String)
    case unsupported(String)
}

/// A clipboard payload.
public enum ClipboardContent: Sendable, Equatable {
    case text(String)
    case image(Data)
}

/// Read/write access to the system clipboard, capability/permission mediated.
public protocol ClipboardProvider: Sendable {
    func read() async throws -> ClipboardContent
    func write(_ content: ClipboardContent) async throws
}

/// Bootstrap clipboard provider that reports `unsupported`. The owning slice
/// (W5-S2) provides the NSPasteboard / wl-clipboard / Windows clipboard adapter.
public struct BootstrapClipboardProvider: ClipboardProvider {
    public init() {}
    public func read() async throws -> ClipboardContent {
        throw ClipboardError.unsupported("BootstrapClipboardProvider does not read; W5-S2 provides the platform adapter.")
    }
    public func write(_ content: ClipboardContent) async throws {
        throw ClipboardError.unsupported("BootstrapClipboardProvider does not write; W5-S2 provides the platform adapter.")
    }
}
