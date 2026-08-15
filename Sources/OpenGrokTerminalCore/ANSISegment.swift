// ANSISegment.swift
//
// ANSI-aware line segmentation matching
// `xai-ratatui-inline::split_into_line_segments` at pin 650c1db7
// (`crates/codegen/xai-ratatui-inline/src/segment.rs`).

/// A line segment (physical row) with its content and whether it ends with a hard break.
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

/// Events the splitter distinguishes. Complete CSI/OSC/ESC are `escape`;
/// C0 other than CR/LF is `control` so strip can keep TAB/BS while dropping SGR.
private enum SegmentEvent {
    case print(Unicode.Scalar)
    case carriageReturn
    case lineFeed
    case control(UInt8)
    case escape
}

/// VTE-style state machine matching `anstyle-parse` 0.2 (the production
/// parser behind pin `split_into_line_segments`). Mid-sequence bytes do not
/// emit events; Print fires on the last UTF-8 byte of a scalar.
private struct ANSIEventParser {
    private enum State {
        case ground
        case escape
        case escapeIntermediate
        case csiEntry
        case csiParam
        case csiIntermediate
        case csiIgnore
        case oscString
        case dcsEntry
        case dcsPassthrough
        case sosPmApcString
        case utf8
    }

    private var state: State = .ground
    private var utf8Buffer: [UInt8] = []
    private var utf8Needed = 0

    mutating func advance(_ byte: UInt8) -> SegmentEvent? {
        if state == .utf8 {
            return consumeUtf8(byte)
        }

        // Anywhere transitions (CAN/SUB/ESC) override the current state.
        switch byte {
        case 0x18, 0x1A:
            // Leaving OSC/DCS still completes that string (Other), then
            // Execute wins the one-slot event — neither is CR/LF.
            state = .ground
            utf8Reset()
            return execute(byte)
        case 0x1B:
            // OSC/DCS/SOS emit their end action on the ESC that starts ST.
            let endingString =
                state == .oscString
                || state == .dcsPassthrough
                || state == .sosPmApcString
            state = .escape
            utf8Reset()
            return endingString ? .escape : nil
        default:
            break
        }

        switch state {
        case .ground:
            return ground(byte)
        case .escape:
            return inEscape(byte)
        case .escapeIntermediate:
            return inEscapeIntermediate(byte)
        case .csiEntry:
            return inCsiEntry(byte)
        case .csiParam:
            return inCsiParam(byte)
        case .csiIntermediate:
            return inCsiIntermediate(byte)
        case .csiIgnore:
            return inCsiIgnore(byte)
        case .oscString:
            return inOsc(byte)
        case .dcsEntry:
            return inDcsEntry(byte)
        case .dcsPassthrough, .sosPmApcString:
            return inString(byte)
        case .utf8:
            return consumeUtf8(byte)
        }
    }

    private mutating func ground(_ byte: UInt8) -> SegmentEvent? {
        switch byte {
        case 0x00...0x1F:
            return execute(byte)
        case 0x7F:
            return .control(byte)
        case 0x20...0x7E:
            return .print(Unicode.Scalar(byte))
        default:
            return startUtf8(byte)
        }
    }

    private mutating func inEscape(_ byte: UInt8) -> SegmentEvent? {
        switch byte {
        case 0x00...0x1F:
            return execute(byte)
        case 0x7F:
            return nil
        case 0x20...0x2F:
            state = .escapeIntermediate
            return nil
        case 0x50: // P DCS
            state = .dcsEntry
            return nil
        case 0x58, 0x5E, 0x5F: // X ^ _
            state = .sosPmApcString
            return nil
        case 0x5B: // [
            state = .csiEntry
            return nil
        case 0x5D: // ]
            state = .oscString
            return nil
        default:
            state = .ground
            return .escape
        }
    }

    private mutating func inEscapeIntermediate(_ byte: UInt8) -> SegmentEvent? {
        switch byte {
        case 0x00...0x1F:
            return execute(byte)
        case 0x7F:
            return nil
        case 0x20...0x2F:
            return nil
        default:
            state = .ground
            return .escape
        }
    }

    private mutating func inCsiEntry(_ byte: UInt8) -> SegmentEvent? {
        switch byte {
        case 0x00...0x1F:
            // Stay in CSI — VTE executes C0 without cancelling the sequence
            // (segment.rs:138-140, `\x1b[3\n1m`).
            return execute(byte)
        case 0x7F:
            return nil
        case 0x20...0x2F:
            state = .csiIntermediate
            return nil
        case 0x30...0x39, 0x3B:
            state = .csiParam
            return nil
        case 0x3A:
            state = .csiIgnore
            return nil
        case 0x3C...0x3F:
            state = .csiParam
            return nil
        case 0x40...0x7E:
            state = .ground
            return .escape
        default:
            return nil
        }
    }

    private mutating func inCsiParam(_ byte: UInt8) -> SegmentEvent? {
        switch byte {
        case 0x00...0x1F:
            return execute(byte)
        case 0x7F:
            return nil
        case 0x20...0x2F:
            state = .csiIntermediate
            return nil
        case 0x30...0x39, 0x3A, 0x3B:
            return nil
        case 0x3C...0x3F:
            state = .csiIgnore
            return nil
        case 0x40...0x7E:
            state = .ground
            return .escape
        default:
            return nil
        }
    }

    private mutating func inCsiIntermediate(_ byte: UInt8) -> SegmentEvent? {
        switch byte {
        case 0x00...0x1F:
            return execute(byte)
        case 0x7F:
            return nil
        case 0x20...0x2F:
            return nil
        case 0x30...0x3F:
            state = .csiIgnore
            return nil
        case 0x40...0x7E:
            state = .ground
            return .escape
        default:
            return nil
        }
    }

    private mutating func inCsiIgnore(_ byte: UInt8) -> SegmentEvent? {
        switch byte {
        case 0x00...0x1F:
            return execute(byte)
        case 0x40...0x7E:
            state = .ground
            return .escape
        default:
            return nil
        }
    }

    private mutating func inOsc(_ byte: UInt8) -> SegmentEvent? {
        if byte == 0x07 {
            state = .ground
            return .escape
        }
        return nil
    }

    private mutating func inDcsEntry(_ byte: UInt8) -> SegmentEvent? {
        switch byte {
        case 0x00...0x1F:
            return execute(byte)
        case 0x40...0x7E:
            state = .dcsPassthrough
            return .escape
        default:
            return nil
        }
    }

    private mutating func inString(_ byte: UInt8) -> SegmentEvent? {
        if byte == 0x07 {
            state = .ground
            return .escape
        }
        return nil
    }

    private func execute(_ byte: UInt8) -> SegmentEvent {
        switch byte {
        case 0x0D:
            return .carriageReturn
        case 0x0A:
            return .lineFeed
        default:
            return .control(byte)
        }
    }

    private mutating func startUtf8(_ byte: UInt8) -> SegmentEvent? {
        let needed: Int
        if byte & 0xE0 == 0xC0 {
            needed = 1
        } else if byte & 0xF0 == 0xE0 {
            needed = 2
        } else if byte & 0xF8 == 0xF0 {
            needed = 3
        } else {
            return .print(Unicode.Scalar(0xFFFD)!)
        }
        utf8Buffer = [byte]
        utf8Needed = needed
        state = .utf8
        return nil
    }

    private mutating func consumeUtf8(_ byte: UInt8) -> SegmentEvent? {
        utf8Buffer.append(byte)
        utf8Needed -= 1
        if utf8Needed > 0 {
            return nil
        }
        state = .ground
        let decoded = String(decoding: utf8Buffer, as: UTF8.self)
        utf8Buffer.removeAll(keepingCapacity: true)
        if let scalar = decoded.unicodeScalars.first {
            return .print(scalar)
        }
        return .print(Unicode.Scalar(0xFFFD)!)
    }

    private mutating func utf8Reset() {
        utf8Buffer.removeAll(keepingCapacity: true)
        utf8Needed = 0
    }
}

private func utf8ByteCount(_ scalar: Unicode.Scalar) -> Int {
    switch scalar.value {
    case 0..<0x80: return 1
    case 0x80..<0x800: return 2
    case 0x800..<0x1_0000: return 3
    default: return 4
    }
}

/// Incremental splitter. Feeding UTF-8 chunks then `finish()` must match
/// one-shot `splitIntoLineSegments` of the concatenation (parser + wrap state
/// persist across `push`).
struct ANSILineSplitter {
    private let termWidth: Int
    private var parser = ANSIEventParser()
    private var buffer: [UInt8] = []
    private var completed: [LineSegment] = []
    private var segmentStart = 0
    private var segmentEnd = 0
    private var visualWidth = 0
    private var hasVisual = false
    private var prevIsCR = false

    init(termWidth: Int) {
        // Pin takes `usize`; negative Swift widths collapse to 0 (wrap after
        // the first visual column). Width 0 is not treated as "unlimited".
        self.termWidth = max(termWidth, 0)
    }

    mutating func push(_ chunk: String) {
        let origin = buffer.count
        buffer.append(contentsOf: chunk.utf8)
        process(from: origin)
    }

    mutating func finish() -> [LineSegment] {
        // Trailing incomplete sequences (dangling "\x1b[") stay outside
        // `segmentEnd`, matching segment.rs:191-193 / termwiz.
        if segmentEnd > segmentStart {
            if let last = completed.indices.last {
                if !completed[last].endsWithCRLF && !hasVisual {
                    completed[last].content += decode(segmentStart, segmentEnd)
                } else {
                    emit(end: segmentEnd, crlf: false)
                }
            } else {
                emit(end: segmentEnd, crlf: false)
            }
        }
        let result = completed
        reset()
        return result
    }

    private mutating func process(from start: Int) {
        for index in start..<buffer.count {
            guard let event = parser.advance(buffer[index]) else { continue }
            var isCR = false
            switch event {
            case .lineFeed:
                // Use `segmentEnd` (not `index`) so pending escape bytes do
                // not leak — segment.rs:138-145 (`\x1b[3\n1m`).
                emit(end: segmentEnd - (prevIsCR ? 1 : 0), crlf: true)
                segmentEnd = index + 1
                segmentStart = segmentEnd
            case .carriageReturn:
                segmentEnd = index + 1
                visualWidth = 0
                isCR = true
            case .print(let scalar):
                let charBytes = utf8ByteCount(scalar)
                segmentEnd = index + 1 - charBytes
                let charWidth = UnicodeDisplayWidth.width(of: scalar) ?? 0
                let newWidth = visualWidth + charWidth
                if newWidth > termWidth && hasVisual {
                    emit(end: segmentEnd, crlf: false)
                    segmentStart = segmentEnd
                    segmentEnd += charBytes
                    visualWidth = charWidth
                    hasVisual = true
                    if charWidth > termWidth {
                        emit(end: segmentEnd, crlf: false)
                        segmentStart = segmentEnd
                    }
                } else {
                    segmentEnd += charBytes
                    visualWidth = newWidth
                    hasVisual = true
                }
            case .control, .escape:
                segmentEnd = index + 1
            }
            prevIsCR = isCR
        }
    }

    private mutating func emit(end: Int, crlf: Bool) {
        completed.append(LineSegment(content: decode(segmentStart, end), endsWithCRLF: crlf))
        visualWidth = 0
        hasVisual = false
    }

    private func decode(_ start: Int, _ end: Int) -> String {
        guard start < end, start >= 0, end <= buffer.count else { return "" }
        return String(decoding: buffer[start..<end], as: UTF8.self)
    }

    private mutating func reset() {
        parser = ANSIEventParser()
        buffer.removeAll(keepingCapacity: true)
        completed.removeAll(keepingCapacity: true)
        segmentStart = 0
        segmentEnd = 0
        visualWidth = 0
        hasVisual = false
        prevIsCR = false
    }
}

/// Split text into physical line segments with ANSI awareness and visual wrapping.
///
/// - Parameters:
///   - input: UTF-8 text (may contain ANSI escapes).
///   - termWidth: Terminal width in columns; wrapping uses `UnicodeWidthChar`.
/// - Returns: Segments whose `content` holds the corresponding input bytes
///   (CR/LF at hard breaks stripped; wrap does not drop bytes).
public func splitIntoLineSegments(_ input: String, termWidth: Int) -> [LineSegment] {
    var splitter = ANSILineSplitter(termWidth: termWidth)
    splitter.push(input)
    return splitter.finish()
}

// MARK: - ANSI Stripping

/// Strips CSI / OSC / ESC / DCS sequences and leaves visible text.
///
/// Walks bytes, not `Character`s — Swift treats `"\r\n"` as one `Character`,
/// so a character scan would miss a lone CR or glue it to LF inside OSC.
public func stripAnsiSequences(_ text: String) -> String {
    var parser = ANSIEventParser()
    var out: [UInt8] = []
    out.reserveCapacity(text.utf8.count)
    for byte in text.utf8 {
        guard let event = parser.advance(byte) else { continue }
        switch event {
        case .print(let scalar):
            appendScalar(scalar, to: &out)
        case .carriageReturn:
            out.append(0x0D)
        case .lineFeed:
            out.append(0x0A)
        case .control(let control):
            out.append(control)
        case .escape:
            break
        }
    }
    return String(decoding: out, as: UTF8.self)
}

private func appendScalar(_ scalar: Unicode.Scalar, to buffer: inout [UInt8]) {
    let value = scalar.value
    if value < 0x80 {
        buffer.append(UInt8(truncatingIfNeeded: value))
    } else if value < 0x800 {
        buffer.append(0xC0 | UInt8(truncatingIfNeeded: value >> 6))
        buffer.append(0x80 | UInt8(truncatingIfNeeded: value & 0x3F))
    } else if value < 0x1_0000 {
        buffer.append(0xE0 | UInt8(truncatingIfNeeded: value >> 12))
        buffer.append(0x80 | UInt8(truncatingIfNeeded: (value >> 6) & 0x3F))
        buffer.append(0x80 | UInt8(truncatingIfNeeded: value & 0x3F))
    } else {
        buffer.append(0xF0 | UInt8(truncatingIfNeeded: value >> 18))
        buffer.append(0x80 | UInt8(truncatingIfNeeded: (value >> 12) & 0x3F))
        buffer.append(0x80 | UInt8(truncatingIfNeeded: (value >> 6) & 0x3F))
        buffer.append(0x80 | UInt8(truncatingIfNeeded: value & 0x3F))
    }
}
