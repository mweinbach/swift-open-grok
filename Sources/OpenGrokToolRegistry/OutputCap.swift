// OutputCap.swift
//
// Head/tail truncation helpers from `xai-grok-tools/src/util/truncate.rs`.
// Output caps preserve head, tail, and truncation metadata for model-facing
// tool results.

import Foundation

public let defaultSoftWrapWidth: Int = 2_000
public let previewSize: Int = 2_000
public let truncationMarker: String = "…"

/// Metadata describing a truncated tool output payload.
public struct TruncationMetadata: Codable, Sendable, Hashable, Equatable {
    public var truncated: Bool
    public var totalBytes: Int
    public var totalChars: Int
    public var shownBytes: Int
    public var headChars: Int
    public var tailChars: Int
    public var outputFile: String?
    public var marker: String?

    public init(
        truncated: Bool,
        totalBytes: Int,
        totalChars: Int,
        shownBytes: Int,
        headChars: Int = 0,
        tailChars: Int = 0,
        outputFile: String? = nil,
        marker: String? = nil
    ) {
        self.truncated = truncated
        self.totalBytes = totalBytes
        self.totalChars = totalChars
        self.shownBytes = shownBytes
        self.headChars = headChars
        self.tailChars = tailChars
        self.outputFile = outputFile
        self.marker = marker
    }

    public static func notTruncated(text: String) -> TruncationMetadata {
        let bytes = text.utf8.count
        let chars = text.count
        return TruncationMetadata(
            truncated: false,
            totalBytes: bytes,
            totalChars: chars,
            shownBytes: bytes,
            headChars: chars,
            tailChars: 0
        )
    }

    /// Model-visible footer matching bash / MCP style messaging.
    public var footer: String? {
        guard truncated else { return nil }
        let shown = formatByteCount(shownBytes)
        let total = formatByteCount(totalBytes)
        if let outputFile {
            return "[truncated: showing first/last \(shown) of \(total) - full output at: \(outputFile)]"
        }
        return "[truncated: showing first/last \(shown) of \(total)]"
    }

    private enum CodingKeys: String, CodingKey {
        case truncated
        case totalBytes = "total_bytes"
        case totalChars = "total_chars"
        case shownBytes = "shown_bytes"
        case headChars = "head_chars"
        case tailChars = "tail_chars"
        case outputFile = "output_file"
        case marker
    }
}

/// Result of applying an output cap.
public struct CappedOutput: Sendable, Hashable, Equatable {
    public var text: String
    public var metadata: TruncationMetadata

    public init(text: String, metadata: TruncationMetadata) {
        self.text = text
        self.metadata = metadata
    }

    /// Text with optional truncation footer appended for the model.
    public var modelText: String {
        if let footer = metadata.footer {
            return text + "\n\n" + footer
        }
        return text
    }
}

// MARK: - Helpers

public func formatByteCount(_ bytes: Int) -> String {
    if bytes >= 1_000_000 {
        return String(format: "%.1fMB", Double(bytes) / 1_000_000.0)
    } else if bytes >= 1_000 {
        return String(format: "%.1fKB", Double(bytes) / 1_000.0)
    } else {
        return "\(bytes)B"
    }
}

/// Truncate at a UTF-8 boundary without a marker.
public func truncateUTF8(_ s: String, maxBytes: Int) -> String {
    if s.utf8.count <= maxBytes { return s }
    var end = maxBytes
    let utf8 = Array(s.utf8)
    while end > 0 && !isCharBoundary(utf8, end) {
        end -= 1
    }
    return String(decoding: utf8[0..<end], as: UTF8.self)
}

private func isCharBoundary(_ utf8: [UInt8], _ index: Int) -> Bool {
    if index == 0 || index >= utf8.count { return true }
    return utf8[index] & 0b1100_0000 != 0b1000_0000
}

/// Keep head and tail of a character budget (parity with `truncate_front_and_back`).
public func truncateFrontAndBack(_ s: String, maxChars: Int) -> CappedOutput {
    let totalChars = s.count
    let totalBytes = s.utf8.count
    if totalChars <= maxChars {
        return CappedOutput(text: s, metadata: .notTruncated(text: s))
    }
    let half = maxChars / 2
    let head = String(s.prefix(half))
    let tail = String(s.suffix(half))
    let ellipsis = "\n\n... (output truncated) ...\n\n"
    let text = head + ellipsis + tail
    let meta = TruncationMetadata(
        truncated: true,
        totalBytes: totalBytes,
        totalChars: totalChars,
        shownBytes: text.utf8.count,
        headChars: half,
        tailChars: half,
        marker: ellipsis
    )
    return CappedOutput(text: text, metadata: meta)
}

/// Keep first/last halves with `"..."` marker (parity with `truncate_middle`).
public func truncateMiddle(_ s: String, maxChars: Int) -> String {
    let charCount = s.count
    if charCount <= maxChars { return s }
    let marker = "..."
    let remaining = max(0, maxChars - marker.count)
    let frontCount = remaining / 2
    let backCount = remaining - frontCount
    return String(s.prefix(frontCount)) + marker + String(s.suffix(backCount))
}

/// Cap tool output to `maxBytes` keeping head+tail when over budget.
/// Optionally records `outputFile` for recovery footers.
public func capToolOutput(
    _ s: String,
    maxBytes: Int = defaultToolOutputBytes,
    outputFile: String? = nil
) -> CappedOutput {
    let totalBytes = s.utf8.count
    if totalBytes <= maxBytes {
        return CappedOutput(text: s, metadata: .notTruncated(text: s))
    }
    // Split budget ~half for head/tail in *bytes*, snapped to char boundaries.
    let half = maxBytes / 2
    let head = truncateUTF8(s, maxBytes: half)
    // Tail: take last `half` bytes at a char boundary.
    let utf8 = Array(s.utf8)
    var start = max(0, utf8.count - half)
    while start < utf8.count && !isCharBoundary(utf8, start) {
        start += 1
    }
    let tail = String(decoding: utf8[start..<utf8.count], as: UTF8.self)
    let ellipsis = "\n\n... (output truncated) ...\n\n"
    let text = head + ellipsis + tail
    let meta = TruncationMetadata(
        truncated: true,
        totalBytes: totalBytes,
        totalChars: s.count,
        shownBytes: text.utf8.count,
        headChars: head.count,
        tailChars: tail.count,
        outputFile: outputFile,
        marker: ellipsis
    )
    return CappedOutput(text: text, metadata: meta)
}

/// Soft-wrap a long line by inserting newlines every `wrapWidth` characters.
public func softWrapLine(_ line: String, wrapWidth: Int = defaultSoftWrapWidth) -> String {
    if line.count <= wrapWidth { return line }
    var result = ""
    var onLine = 0
    for ch in line {
        if onLine >= wrapWidth {
            result.append("\n")
            onLine = 0
        }
        result.append(ch)
        onLine += 1
    }
    return result
}
