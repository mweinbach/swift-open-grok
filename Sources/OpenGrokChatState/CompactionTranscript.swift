// CompactionTranscript.swift
//
// Open Grok — Swift port of the pure rendering of a compacted segment into
// self-contained markdown in
// `crates/codegen/xai-chat-state/src/compaction_transcript.rs`.
//
// No I/O. Not byte-identical to the Python implementation (the data models
// differ), but headers, sections, detail levels, and INDEX columns match.

import Foundation
import OpenGrokSamplingTypes
import OpenGrokShared

public enum CompactionTranscript {
    /// Layout of the per-session segment store — single source of the path
    /// convention (writer, index parser, and transcript-hint builder all use
    /// these).
    public static let COMPACTION_DIR = "compaction"
    public static let INDEX_FILE = "INDEX.md"

    /// Whole-turn-boundary truncation cap for one segment's verbatim section.
    static let SEGMENT_MAX_BYTES = 512 * 1024
    static let SEGMENT_PREFIX = "segment_"
    static let TRUNCATION_NOTICE = "\n\n[... TRUNCATED at {limit} bytes, {omitted} turns omitted ...]\n"
    /// Per-turn text/arg caps for the `balanced` detail level (chars).
    static let BALANCED_TEXT_CHARS = 2000
    static let BALANCED_RESPONSE_CHARS = 500
    /// Trailing chars of the last assistant message kept for the stats excerpt.
    static let LAST_RESPONSE_EXCERPT_CHARS = 500
    /// Approx markdown overhead charged per turn in the verbose-size estimate.
    static let PER_TURN_OVERHEAD_BYTES = 64

    /// Zero-padded segment number, e.g. `007`.
    public static func segmentLabel(_ index: UInt64) -> String {
        String(format: "%03llu", index)
    }

    /// Flat per-segment filename, e.g. `segment_007.md`.
    public static func segmentFilename(_ index: UInt64) -> String {
        "\(SEGMENT_PREFIX)\(segmentLabel(index)).md"
    }

    /// Parse a segment index out of a `segment_NNN.md` filename, if it
    /// matches.
    public static func parseSegmentIndex(_ filename: String) -> UInt64? {
        guard filename.hasPrefix(SEGMENT_PREFIX), filename.hasSuffix(".md") else {
            return nil
        }
        let middle = String(filename.dropFirst(SEGMENT_PREFIX.count).dropLast(3))
        return UInt64(middle)
    }

    /// INDEX.md title + table header, written once when the file is created.
    public static let INDEX_HEADER = """
    # Compaction Segment Index

    | Segment | File | Turns | Approx bytes | Keywords |
    |---|---|---|---|---|
    """

    /// One INDEX.md row (with trailing newline). `keywords` are quoted and
    /// comma-joined; the columns match `INDEX_HEADER`.
    public static func renderIndexRow(
        index: UInt64, turnCount: Int, approxBytes: Int, keywords: [String]
    ) -> String {
        let kw = keywords.map { "\"\($0)\"" }.joined(separator: ", ")
        return "| \(segmentLabel(index)) | \(segmentFilename(index)) | \(turnCount) | \(approxBytes) | \(kw) |\n"
    }
}

// MARK: - CompactionArtifact (path classification)

/// A read of the `compaction/` store; used as a telemetry label on
/// `compaction.segment_read`.
public enum CompactionArtifact: Sendable, Equatable, Hashable {
    case segment(UInt64)
    case index
    case dir

    public func segmentIndex() -> UInt64? {
        if case .segment(let i) = self { return i }
        return nil
    }

    public var telemetryLabel: String {
        switch self {
        case .segment: return "segment"
        case .index: return "index"
        case .dir: return "dir"
        }
    }
}

/// Anchors on the `compaction/` component, not the session dir, so relative
/// reads still match (a same-named file elsewhere is acceptable noise).
public func classifyCompactionPath(_ path: String) -> CompactionArtifact? {
    let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
    if trimmed == CompactionTranscript.COMPACTION_DIR {
        return .dir
    }
    if trimmed.hasSuffix("/\(CompactionTranscript.COMPACTION_DIR)") {
        return .dir
    }
    guard let compactionRange = path.range(of: CompactionTranscript.COMPACTION_DIR) else {
        return nil
    }
    let after = String(path[compactionRange.upperBound...])
    guard after.hasPrefix("/") else { return nil }
    let rest = String(after.dropFirst())
    if let index = CompactionTranscript.parseSegmentIndex(rest) {
        return .segment(index)
    }
    if rest == CompactionTranscript.INDEX_FILE {
        return .index
    }
    return nil
}

// MARK: - Segment rendering

/// Role label per item, mapped onto the Python `Turn` role vocabulary
/// (`System`/`Human`/`Assistant`/`Function`). Model-side items with no Python
/// analog fold into `Assistant`.
func roleLabel(_ item: ConversationItem) -> String {
    switch item {
    case .system: return "System"
    case .user: return "Human"
    case .assistant: return "Assistant"
    case .toolResult, .customToolOutput: return "Function"
    case .backendToolCall, .reasoning: return "Assistant"
    }
}

/// Model-visible text for either function or native custom-tool output.
/// Ordered output is the source of truth when present; images are represented
/// by a small marker so segment artifacts never embed base64 payloads.
func toolOutputText(_ item: ConversationItem) -> String? {
    switch item {
    case .toolResult(let result) where result.orderedContent.isEmpty:
        var text = result.content
        for _ in result.images {
            if !text.isEmpty { text += "\n" }
            text += "[image]"
        }
        return result.images.isEmpty ? result.content : text
    case .toolResult(let result):
        return result.orderedContent.map { part in
            switch part {
            case .text(let text): return text
            case .image: return "[image]"
            }
        }.joined()
    case .customToolOutput(let output):
        return output.content.map { part in
            switch part {
            case .text(let text): return text
            case .image: return "[image]"
            }
        }.joined()
    default:
        return nil
    }
}

/// Render one segment: header, metadata, stats, curated summary, and (unless
/// `detail == .none`) verbatim turns truncated at a whole-turn boundary
/// before `SEGMENT_MAX_BYTES`.
public func renderSegmentMD(
    items: [ConversationItem],
    summary: String,
    index: UInt64,
    detail: CompactionDetail,
    timestamp: String
) -> String {
    let label = CompactionTranscript.segmentLabel(index)
    let header = """
    # HISTORICAL -- DO NOT EDIT
    # Record of compaction segment \(label) (detail=\(detail.rawValue)) from this same task.
    # Use read_file or grep to look up details, but do not modify.


    """
    let metadata = """
    ## Segment metadata
    - Index: \(label)
    - Turn count: \(items.count)
    - Timestamp: \(timestamp)


    """
    let statsSection = renderStatsBlock(computeTurnStats(items)) + "\n"
    let summaryBody = summary.trimmingCharacters(in: .whitespacesAndNewlines)
    let summarySection = """
    ## Summary (curated by compaction step)

    \(summaryBody.isEmpty ? "(empty)" : summaryBody)


    """
    let preambleHead = header + metadata + statsSection + summarySection
    if detail == .none {
        return preambleHead
    }

    let turnsHeader: String
    switch detail {
    case .minimal: turnsHeader = "## Turn signatures\n\n"
    case .balanced: turnsHeader = "## Turns (balanced detail)\n\n"
    case .verbose: turnsHeader = "## Verbatim turns\n\n"
    case .none: fatalError("none returns above")
    }

    let preamble = preambleHead + turnsHeader
    // Reserve the preamble, the notice, and slack for its `{limit}`/`{omitted}`
    // substitutions so the rendered doc stays under the cap.
    let budget = CompactionTranscript.SEGMENT_MAX_BYTES
        .subtractingWithSaturate(preamble.utf8.count
            + CompactionTranscript.TRUNCATION_NOTICE.utf8.count
            + CompactionTranscript.PER_TURN_OVERHEAD_BYTES)

    var blocks: [String] = []
    var used = 0
    var truncatedAt: Int? = nil
    for (i, item) in items.enumerated() {
        let block = renderTurn(item, index: i, detail: detail)
        if used + block.utf8.count > budget {
            truncatedAt = i
            break
        }
        used += block.utf8.count
        blocks.append(block)
    }

    var body = blocks.joined(separator: "\n")
    if let at = truncatedAt {
        let omitted = items.count - at
        let notice = CompactionTranscript.TRUNCATION_NOTICE
            .replacingOccurrences(of: "{limit}", with: "\(CompactionTranscript.SEGMENT_MAX_BYTES)")
            .replacingOccurrences(of: "{omitted}", with: "\(omitted)")
        body += notice
    }
    return preamble + body
}

/// Walk-once statistics for the always-on `## Turn statistics` block.
struct TurnStats {
    var turnCount: Int
    var roleCounts: [(role: String, count: Int)]
    var toolCounts: [(tool: String, count: Int)]
    var uniqueFiles: [String]
    var toolErrorCount: Int
    var verboseByteEstimate: Int
    var lastAssistantExcerpt: String
}

func computeTurnStats(_ items: [ConversationItem]) -> TurnStats {
    var roleCounts: [String: Int] = [:]
    var toolCounts: [String: Int] = [:]
    var uniqueFiles: Set<String> = []
    var toolErrorCount = 0
    var lastAssistant = ""
    var verboseByteEstimate = 0

    for item in items {
        let label = roleLabel(item)
        roleCounts[label, default: 0] += 1
        verboseByteEstimate += CompactionTranscript.PER_TURN_OVERHEAD_BYTES

        switch item {
        case .assistant(let a):
            verboseByteEstimate += a.content.utf8.count
            if !a.content.isEmpty {
                lastAssistant = a.content
            }
            for tc in a.toolCalls {
                toolCounts[tc.name, default: 0] += 1
                let args = toolArgs(tc.arguments)
                for key in fileArgKeys {
                    if let v = args[key], case .string(let s) = v, !s.isEmpty {
                        uniqueFiles.insert(s)
                        break
                    }
                }
                verboseByteEstimate += args.reduce(0) { acc, kv in
                    acc + 32 + kv.key.utf8.count + argValuePlain(kv.value).utf8.count
                }
            }
        case .toolResult, .customToolOutput:
            let content = toolOutputText(item) ?? ""
            verboseByteEstimate += content.utf8.count
            if content.hasPrefix("Error") || content.contains("Failed tool validation") {
                toolErrorCount += 1
            }
        default:
            verboseByteEstimate += item.textContent().utf8.count
        }
    }

    let n = lastAssistant.count
    let startIdx = lastAssistant.index(lastAssistant.startIndex, offsetBy: max(0, n - CompactionTranscript.LAST_RESPONSE_EXCERPT_CHARS))
    let excerpt = String(lastAssistant[startIdx...]).trimmingCharacters(in: .whitespacesAndNewlines)

    let sortedRoleCounts = roleCounts.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    var sortedToolCounts = toolCounts.map { ($0.key, $0.value) }
    // Descending count for at-a-glance scanning; name breaks ties.
    sortedToolCounts.sort { a, b in
        if a.1 != b.1 { return a.1 > b.1 }
        return a.0 < b.0
    }

    return TurnStats(
        turnCount: items.count,
        roleCounts: sortedRoleCounts,
        toolCounts: sortedToolCounts,
        uniqueFiles: Array(uniqueFiles).sorted(),
        toolErrorCount: toolErrorCount,
        verboseByteEstimate: verboseByteEstimate,
        lastAssistantExcerpt: excerpt
    )
}

let fileArgKeys = ["target_file", "file_path", "path", "target_directory"]

func renderStatsBlock(_ stats: TurnStats) -> String {
    var out = "## Turn statistics\n\n"
    let rc = stats.roleCounts.map { "\($0.role)=\($0.count)" }.joined(separator: ", ")
    out += "- Turns: \(stats.turnCount) (\(rc))\n"
    let tc: String
    if stats.toolCounts.isEmpty {
        tc = "(none)"
    } else {
        tc = stats.toolCounts.map { "\($0.tool) (\($0.count))" }.joined(separator: ", ")
    }
    out += "- Tools used: \(tc)\n"
    let uf = stats.uniqueFiles
    let ufStr: String
    if uf.isEmpty {
        ufStr = "(none)"
    } else if uf.count <= 8 {
        ufStr = uf.joined(separator: ", ")
    } else {
        ufStr = "\(uf.prefix(5).joined(separator: ", ")), ... and \(uf.count - 5) more"
    }
    out += "- Unique target files (\(uf.count)): \(ufStr)\n"
    out += "- Tool errors: \(stats.toolErrorCount)\n"
    out += "- Verbose-render size estimate: \(withThousands(stats.verboseByteEstimate)) B\n"
    if !stats.lastAssistantExcerpt.isEmpty {
        let oneline = truncateChars(stats.lastAssistantExcerpt.replacingOccurrences(of: "\n", with: " "), max: 300, marker: "")
        out += "- Last assistant response excerpt: \"\(oneline)\"\n"
    }
    out += "\n"
    return out
}

/// One verbatim turn: role header, text, and `[tool_request: …]` arg lines.
func renderTurn(_ item: ConversationItem, index: Int, detail: CompactionDetail) -> String {
    switch detail {
    case .minimal:
        return renderTurnSignature(item, index: index)
    case .balanced:
        return renderTurnBalanced(item, index: index)
    case .verbose:
        return renderTurnVerbose(item, index: index)
    case .none:
        fatalError("none is handled by the caller")
    }
}

func renderTurnVerbose(_ item: ConversationItem, index: Int) -> String {
    var parts: [String] = ["### Turn \(index) (\(roleLabel(item)))"]
    switch item {
    case .assistant(let a):
        if !a.content.isEmpty {
            parts.append(a.content)
        }
        for tc in a.toolCalls {
            parts.append("[tool_request: \(tc.name)]")
            for (k, v) in toolArgs(tc.arguments) {
                parts.append("- \(k): \(argValuePlain(v))")
            }
        }
    case .toolResult, .customToolOutput:
        parts.append("[tool_response]")
        if let content = toolOutputText(item), !content.isEmpty {
            parts.append(content)
        }
    default:
        let txt = item.textContent()
        if !txt.isEmpty {
            parts.append(txt)
        }
    }
    return parts.joined(separator: "\n") + "\n"
}

func renderTurnBalanced(_ item: ConversationItem, index: Int) -> String {
    var parts: [String] = ["### Turn \(index) (\(roleLabel(item)))"]
    switch item {
    case .assistant(let a):
        if !a.content.isEmpty {
            parts.append(truncateChars(a.content, max: CompactionTranscript.BALANCED_TEXT_CHARS, marker: "... [truncated]"))
        }
        for tc in a.toolCalls {
            parts.append("[tool_request: \(tc.name)]")
            for (k, v) in toolArgs(tc.arguments) {
                let v = truncateChars(argValuePlain(v), max: CompactionTranscript.BALANCED_RESPONSE_CHARS, marker: "... [truncated]")
                parts.append("- \(k): \(v)")
            }
        }
    case .toolResult, .customToolOutput:
        parts.append("[tool_response]")
        if let content = toolOutputText(item), !content.isEmpty {
            parts.append(truncateChars(content, max: CompactionTranscript.BALANCED_RESPONSE_CHARS, marker: "... [truncated]"))
        }
    default:
        let txt = item.textContent()
        if !txt.isEmpty {
            parts.append(txt)
        }
    }
    return parts.joined(separator: "\n") + "\n"
}

func renderTurnSignature(_ item: ConversationItem, index: Int) -> String {
    let role = roleLabel(item)
    switch item {
    case .assistant(let a):
        let sigs: [String] = a.toolCalls.map { tc in
            let args = toolArgs(tc.arguments)
            let keyArg = ["target_file", "file_path", "path", "target_directory", "command", "pattern"]
                .first { key in
                    if case .string(let v)? = args[key], !v.isEmpty {
                        return true
                    }
                    return false
                }
                .map { key -> String in
                    if case .string(let v)? = args[key] {
                        return "\(key)=\(truncateChars(v, max: 80, marker: "..."))"
                    }
                    return ""
                } ?? ""
            return "\(tc.name)(\(keyArg))"
        }
        let sigStr = sigs.isEmpty ? "(text only)" : sigs.joined(separator: "  ")
        return "### Turn \(index) (\(role))  \(sigStr)\n"
    case .toolResult, .customToolOutput:
        return "### Turn \(index) (\(role))  [tool_response]\n"
    default:
        return "### Turn \(index) (\(role))\n"
    }
}

// MARK: - Helpers

/// One JSON tool-arg value rendered for a `- key: value` line.
func argValuePlain(_ v: JSONValue) -> String {
    if case .string(let s) = v { return s }
    // Fall back to JSON serialization for non-string values.
    guard let data = try? JSONEncoder().encode(v) else { return "" }
    return String(data: data, encoding: .utf8) ?? ""
}

func toolArgs(_ arguments: String) -> [String: JSONValue] {
    guard let data = arguments.data(using: .utf8),
          let value = try? JSONDecoder().decode(JSONValue.self, from: data),
          case .object(let map) = value else {
        return [:]
    }
    return map
}

/// Truncate to ≤ `max` chars, appending `marker` if cut (char-based).
func truncateChars(_ s: String, max: Int, marker: String) -> String {
    if s.count <= max { return s }
    return String(s.prefix(max)) + marker
}

/// Insert thousands separators (mirrors Python's `{:,}`).
func withThousands(_ n: Int) -> String {
    let digits = String(n)
    let chars = Array(digits)
    var out = ""
    for (i, ch) in chars.enumerated() {
        if i > 0 && (chars.count - i) % 3 == 0 {
            out += ","
        }
        out.append(ch)
    }
    return out
}

// MARK: - Saturating arithmetic helper

fileprivate extension Int {
    func subtractingWithSaturate(_ other: Int) -> Int {
        let (diff, overflow) = self.subtractingReportingOverflow(other)
        return overflow ? 0 : diff
    }
}
