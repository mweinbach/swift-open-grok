// CompactionMode.swift
//
// Open Grok — Swift port of the compaction mode and compaction detail types
// in `crates/codegen/xai-chat-state/src/{compaction_mode.rs,compaction_transcript.rs}`.
//
// `CompactionMode` controls how compaction exposes pre-compaction history to
// the model afterwards (summary only, summary + transcript pointer, or
// summary + a `compaction/` folder of clean per-segment markdown).
// `CompactionDetail` controls per-turn detail in the verbatim section.

import Foundation
import OpenGrokSamplingTypes

/// How much per-turn detail lands in the verbatim section of a compaction
/// segment. Mirrors the Python `compaction_persist_detail`. `verbose` is the
/// default.
public enum CompactionDetail: String, Sendable, Equatable, Hashable, Defaultable {
    case none
    case minimal
    case balanced
    case verbose

    public static let defaultValue: CompactionDetail = .verbose

    /// Case-insensitive; `nil` → caller falls back to default.
    public static func parse(_ s: String) -> CompactionDetail? {
        switch s.trimmingCharacters(in: .whitespaces).lowercased() {
        case "none": return .none
        case "minimal": return .minimal
        case "balanced": return .balanced
        case "verbose": return .verbose
        default: return nil
        }
    }
}

/// How compaction exposes pre-compaction history to the model afterwards.
/// `segments` carries its verbatim detail level inline, since detail is
/// meaningful only there.
public enum CompactionMode: Sendable, Equatable, Hashable, Defaultable {
    case summary
    case transcript
    case segments(CompactionDetail)

    public static let defaultValue: CompactionMode = .summary

    /// Parse the mode word (case-insensitive); `nil` → caller falls back.
    /// `segments` gets the default detail — callers override it via
    /// `withSegmentDetail` once detail is resolved.
    public static func parse(_ s: String) -> CompactionMode? {
        switch s.trimmingCharacters(in: .whitespaces).lowercased() {
        case "summary": return .summary
        case "transcript": return .transcript
        case "segments": return .segments(.defaultValue)
        default: return nil
        }
    }

    /// Replace the detail level if this is `.segments`, else unchanged.
    public func withSegmentDetail(_ detail: CompactionDetail) -> CompactionMode {
        switch self {
        case .segments: return .segments(detail)
        case .summary, .transcript: return self
        }
    }

    public func segmentDetail() -> CompactionDetail? {
        if case .segments(let d) = self { return d }
        return nil
    }

    /// Whether this mode persists the `compaction/` segment store.
    public func writesSegments() -> Bool {
        if case .segments = self { return true }
        return false
    }

    /// Transcript hint for the summary, given the one `location` this mode
    /// points at (raw transcript path or `compaction/` folder). `nil` if the
    /// mode adds no pointer (`summary`) or the location is absent.
    public func transcriptHint(location: String?) -> String? {
        guard let location else { return nil }
        switch self {
        case .summary:
            return nil
        case .transcript:
            return "\n\nIf you need specific details from before compaction (like exact code snippets, error messages, or content you generated), read the full transcript at: \(location)"
        case .segments:
            let indexFile = CompactionTranscript.INDEX_FILE
            return "\n\nFull verbatim rollouts of previous segments are available at \(location)/segment_*.md.  See \(location)/\(indexFile) for a table of contents.  Use read_file or grep to recover specific details (exact code, file paths, tool outputs) if this summary is insufficient.  Do NOT modify these files."
        }
    }
}
