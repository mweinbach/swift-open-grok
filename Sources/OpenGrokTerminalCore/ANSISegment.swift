// ANSISegment.swift
//
// Zero-copy (slice) ANSI-aware line segmentation matching
// `xai-ratatui-inline::split_into_line_segments`.

import Foundation

/// A line segment (physical row) with its content and whether it ends with CRLF.
public struct LineSegment: Sendable, Equatable {
    /// Contiguous string content (ANSI codes included; CR/LF stripped on break).
    public var content: String
    /// True when the segment was terminated by LF (optionally preceded by CR).
    public var endsWithCRLF: Bool

    public init(content: String, endsWithCRLF: Bool) {
        self.content = content
        self.endsWithCRLF = endsWithCRLF
    }

    /// Render content with trailing CRLF when marked.
    public var rendered: String {
        endsWithCRLF ? content + "\r\n" : content
    }
}

/// Events the splitter distinguishes.
private enum SegmentEvent {
    case print(Character)
    case carriageReturn
    case lineFeed
    case other
}

/// Lightweight VTE-style ANSI state machine sufficient for production line
/// splitting (SGR, CSI, OSC, ESC, C0). Mid-sequence bytes do not emit events.
private final class ANSIEventParser {
    private enum State {
        case ground
        case escape
        case csiEntry
        case csiParam
        case csiIntermediate
        case oscString
        case dcsEntry
        case dcsPassthrough
        case sosPmApcString
    }

    private var state: State = .ground
    private var utf8Buffer: [UInt8] = []
    private var utf8Needed = 0

    func advance(_ byte: UInt8) -> SegmentEvent? {
        // UTF-8 multi-byte assembly in ground state.
        if state == .ground {
            if utf8Needed > 0 {
                utf8Buffer.append(byte)
                utf8Needed -= 1
                if utf8Needed == 0 {
                    if let s = String(bytes: utf8Buffer, encoding: .utf8), let ch = s.first {
                        utf8Buffer.removeAll(keepingCapacity: true)
                        return .print(ch)
                    }
                    utf8Buffer.removeAll(keepingCapacity: true)
                    return .other
                }
                return nil
            }
            if byte < 0x80 {
                return handleGroundASCII(byte)
            }
            // Start multi-byte UTF-8
            if byte & 0xE0 == 0xC0 {
                utf8Buffer = [byte]; utf8Needed = 1
                return nil
            }
            if byte & 0xF0 == 0xE0 {
                utf8Buffer = [byte]; utf8Needed = 2
                return nil
            }
            if byte & 0xF8 == 0xF0 {
                utf8Buffer = [byte]; utf8Needed = 3
                return nil
            }
            return .other
        }
        return handleEscapeState(byte)
    }

    private func handleGroundASCII(_ byte: UInt8) -> SegmentEvent? {
        switch byte {
        case 0x1B:
            state = .escape
            return nil
        case 0x0D:
            return .carriageReturn
        case 0x0A:
            return .lineFeed
        case 0x00...0x1F, 0x7F:
            return .other
        default:
            return .print(Character(UnicodeScalar(byte)))
        }
    }

    private func handleEscapeState(_ byte: UInt8) -> SegmentEvent? {
        switch state {
        case .escape:
            switch byte {
            case 0x5B: // [
                state = .csiEntry
                return nil
            case 0x5D: // ]
                state = .oscString
                return nil
            case 0x50: // P DCS
                state = .dcsEntry
                return nil
            case 0x58, 0x5E, 0x5F: // X ^ _
                state = .sosPmApcString
                return nil
            case 0x5C: // \  — String Terminator (from OSC/DCS)
                state = .ground
                return .other
            case 0x20...0x2F:
                // intermediate, stay in escape-ish
                return nil
            default:
                state = .ground
                return .other
            }
        case .csiEntry, .csiParam, .csiIntermediate:
            if (0x30...0x3F).contains(byte) {
                state = .csiParam
                return nil
            }
            if (0x20...0x2F).contains(byte) {
                state = .csiIntermediate
                return nil
            }
            if (0x40...0x7E).contains(byte) {
                state = .ground
                return .other
            }
            if byte == 0x1B {
                state = .escape
                return nil
            }
            // Cancel on C0 other than ESC
            if byte < 0x20 {
                state = .ground
                return .other
            }
            return nil
        case .oscString:
            // BEL or ST (ESC \) terminate
            if byte == 0x07 {
                state = .ground
                return .other
            }
            if byte == 0x1B {
                state = .escape
                return nil
            }
            return nil
        case .dcsEntry, .dcsPassthrough, .sosPmApcString:
            if byte == 0x1B {
                state = .escape
                return nil
            }
            if byte == 0x07 {
                state = .ground
                return .other
            }
            return nil
        case .ground:
            return handleGroundASCII(byte)
        }
    }
}

/// Split text into physical line segments with ANSI awareness and visual wrapping.
///
/// - Parameters:
///   - input: UTF-8 text (may contain ANSI escapes).
///   - termWidth: Terminal width in columns; wrapping uses display width.
/// - Returns: Segments whose `content` is a substring of `input` (copied into
///   Swift `String` values; zero intermediate allocations beyond the result).
public func splitIntoLineSegments(_ input: String, termWidth: Int) -> [LineSegment] {
    if input.isEmpty { return [] }
    let width = max(termWidth, 0)
    // Use a large width when 0 so wrapping is disabled rather than forcing
    // every character onto its own line.
    let effectiveWidth = width == 0 ? Int.max / 4 : width

    let bytes = Array(input.utf8)
    // Map byte index → String via UTF-8 view of original.
    let utf8 = input.utf8

    func substring(start: Int, end: Int) -> String {
        guard start < end, start >= 0, end <= bytes.count else { return "" }
        let sIdx = utf8.index(utf8.startIndex, offsetBy: start)
        let eIdx = utf8.index(utf8.startIndex, offsetBy: end)
        return String(input[sIdx..<eIdx])
    }

    let parser = ANSIEventParser()
    var segments: [LineSegment] = []
    var segmentStart = 0
    var segmentEnd = 0
    var visualWidth = 0
    var hasVisual = false
    var prevIsCR = false

    func pushSegment(end: Int, crlf: Bool) {
        segments.append(LineSegment(content: substring(start: segmentStart, end: end), endsWithCRLF: crlf))
        visualWidth = 0
        hasVisual = false
    }

    for (index, byte) in bytes.enumerated() {
        guard let event = parser.advance(byte) else { continue }
        var isCR = false

        switch event {
        case .lineFeed:
            let end = segmentEnd - (prevIsCR ? 1 : 0)
            pushSegment(end: end, crlf: true)
            segmentEnd = index + 1
            segmentStart = segmentEnd
        case .carriageReturn:
            segmentEnd = index + 1
            visualWidth = 0
            isCR = true
        case .print(let ch):
            let charBytes = String(ch).utf8.count
            segmentEnd = index + 1 - charBytes
            let charWidth = UnicodeDisplayWidth.width(of: String(ch))
            let newWidth = visualWidth + charWidth
            if newWidth > effectiveWidth && hasVisual {
                pushSegment(end: segmentEnd, crlf: false)
                segmentStart = segmentEnd
                segmentEnd += charBytes
                visualWidth = charWidth
                hasVisual = true
                if charWidth > effectiveWidth {
                    pushSegment(end: segmentEnd, crlf: false)
                    segmentStart = segmentEnd
                }
            } else {
                segmentEnd += charBytes
                visualWidth = newWidth
                hasVisual = true
            }
        case .other:
            segmentEnd = index + 1
        }
        prevIsCR = isCR
    }

    if segmentEnd > segmentStart {
        if let last = segments.indices.last {
            if !segments[last].endsWithCRLF && !hasVisual {
                // Concatenate trailing zero-width (ANSI) onto previous segment.
                let mergedStart = segments[last].content
                // Reconstruct by byte range: previous content started at prior start.
                // Simpler: append substring.
                let trailing = substring(start: segmentStart, end: segmentEnd)
                segments[last].content = segments[last].content + trailing
                _ = mergedStart
            } else {
                pushSegment(end: segmentEnd, crlf: false)
            }
        } else {
            pushSegment(end: segmentEnd, crlf: false)
        }
    }

    return segments
}

// MARK: - ANSI Stripping

private let ansiPatternRegex: NSRegularExpression? = {
    let pattern = #"\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~]|\].*?(?:\x07|\x1B\\))"#
    return try? NSRegularExpression(pattern: pattern)
}()

/// Strips ANSI escape codes from a string using a precompiled regex.
public func stripAnsiSequences(_ text: String) -> String {
    guard let regex = ansiPatternRegex else { return text }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
}
