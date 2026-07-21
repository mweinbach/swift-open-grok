// DoomLoop.swift
//
// Open Grok — Swift port of the server-side doom-loop check wire contract
// types and tolerant parsers in
// `crates/codegen/xai-grok-sampling-types/src/doom_loop.rs`.
//
// When the client opts in via the `x-grok-doom-loop-check` request header,
// the inference API reports detected generation loops on streaming
// `/v1/responses` requests. This module is the single home for that wire
// shape; everything here is best-effort by design — malformed payloads yield
// `.unknown` kinds or empty trigger sets, never an error, so the feature can
// never fail a stream.

import Foundation
import OpenGrokShared

/// Request header whose presence enables the server-side check.
public let DOOM_LOOP_CHECK_HEADER = "x-grok-doom-loop-check"

/// `type` of the non-standard mid-stream SSE event — also its SSE `event:`
/// name. Carrying this name or type must be intercepted before typed
/// deserialization.
public let DOOM_LOOP_CHECK_EVENT_TYPE = "response.doom_loop_check"

/// Byte-exact `data:` payload of a check-event frame as emitted by the
/// server. Exported as a fixture so transport tests pin the real bytes, not a
/// paraphrase.
public let SAMPLE_CHECK_EVENT_DATA =
    #"{"sequence_number":4176,"type":"response.doom_loop_check","doom_loop_check":{"triggers":["tail_repetition:4@response"]}}"#

/// Companion fixture carrying the grown cumulative trigger set.
public let SAMPLE_CHECK_EVENT_DATA_CUMULATIVE =
    #"{"sequence_number":4178,"type":"response.doom_loop_check","doom_loop_check":{"triggers":["tail_repetition:4@response","tail_repetition:2@response"]}}"#

/// Channel label of the model's thinking stream — the only channel recovery
/// acts on (loops in visible output are the user's to judge).
public let THINKING_CHANNEL = "thinking"

/// Resolved runtime tunables for doom-loop recovery.
public struct DoomLoopRecoveryPolicy: Codable, Sendable, Equatable, Hashable {
    /// Act only on `tail_repetition:{t}@thinking` triggers with `t` at or
    /// below this value (lower thresholds indicate tighter, more confident
    /// loops).
    public var maxThreshold: UInt32
    /// Resample budget per turn before accepting the response as-is.
    public var maxRetries: UInt32

    public static let MAX_THRESHOLD_RANGE: ClosedRange<UInt32> = 2...64
    public static let MAX_RETRIES_RANGE: ClosedRange<UInt32> = 0...5
    public static let DEFAULT_MAX_THRESHOLD: UInt32 = 8
    public static let DEFAULT_MAX_RETRIES: UInt32 = 2

    public init(maxThreshold: UInt32, maxRetries: UInt32) {
        self.maxThreshold = maxThreshold
        self.maxRetries = maxRetries
    }

    public init() {
        self.maxThreshold = Self.DEFAULT_MAX_THRESHOLD
        self.maxRetries = Self.DEFAULT_MAX_RETRIES
    }

    public enum CodingKeys: String, CodingKey {
        case maxThreshold = "max_threshold"
        case maxRetries = "max_retries"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Per-field serde defaults: payloads written before a field existed
        // must keep deserializing.
        self.maxThreshold = try c.decodeIfPresent(UInt32.self, forKey: .maxThreshold) ?? Self.DEFAULT_MAX_THRESHOLD
        self.maxRetries = try c.decodeIfPresent(UInt32.self, forKey: .maxRetries) ?? Self.DEFAULT_MAX_RETRIES
    }

    /// Clamp a configured `maxThreshold` into `MAX_THRESHOLD_RANGE`.
    public static func clampMaxThreshold(_ value: UInt32) -> UInt32 {
        min(max(value, MAX_THRESHOLD_RANGE.lowerBound), MAX_THRESHOLD_RANGE.upperBound)
    }

    /// Clamp a configured `maxRetries` into `MAX_RETRIES_RANGE`.
    public static func clampMaxRetries(_ value: UInt32) -> UInt32 {
        min(max(value, MAX_RETRIES_RANGE.lowerBound), MAX_RETRIES_RANGE.upperBound)
    }

    /// A signal this policy treats as a real loop worth acting on: tail
    /// repetition in the thinking channel, at or below the confidence
    /// threshold. Everything else is warn-only.
    public func isConfident(_ signal: DoomLoopSignal) -> Bool {
        guard signal.channel == THINKING_CHANNEL else { return false }
        if case .tailRepetition(let t) = signal.kind {
            return t <= maxThreshold
        }
        return false
    }

    /// Raw labels of the confident signals in `signals`; empty when none.
    public func confidentTriggers(_ signals: [DoomLoopSignal]) -> [String] {
        signals.filter { isConfident($0) }.map { $0.raw }
    }
}

/// Parsed classification of a single trigger label.
public enum DoomLoopSignalKind: Codable, Sendable, Equatable, Hashable {
    /// `tail_repetition:{threshold}@{channel}` — a repeating tail was found
    /// at the given detector threshold.
    case tailRepetition(UInt32)
    /// `low_logprob@{channel}` — degenerate low-entropy generation.
    case lowLogprob
    /// Any label this client version cannot classify; the unparsed kind
    /// segment is preserved verbatim.
    case unknown(String)
}

/// One doom-loop trigger reported by the server.
public struct DoomLoopSignal: Codable, Sendable, Equatable, Hashable {
    public var kind: DoomLoopSignalKind
    /// Channel the loop was detected on (e.g. `thinking`, `response`).
    /// Empty when the label carries no `@channel` suffix.
    public var channel: String
    /// The verbatim label; the stable identity used for deduplication and
    /// logging.
    public var raw: String

    public init(kind: DoomLoopSignalKind, channel: String, raw: String) {
        self.kind = kind
        self.channel = channel
        self.raw = raw
    }

    /// Parse a trigger label. Never fails: any grammar mismatch yields
    /// `.unknown` with the raw label preserved.
    public init(parsing raw: String) {
        let raw_ = raw
        let (head, channel): (String, String)
        if let atIdx = raw_.firstIndex(of: "@") {
            head = String(raw_[raw_.startIndex..<atIdx])
            channel = String(raw_[raw_.index(after: atIdx)...])
        } else {
            head = raw_
            channel = ""
        }
        let kind: DoomLoopSignalKind
        if let colonIdx = head.firstIndex(of: ":") {
            let kindName = String(head[head.startIndex..<colonIdx])
            let threshold = String(head[head.index(after: colonIdx)...])
            if kindName == "tail_repetition", let t = UInt32(threshold) {
                kind = .tailRepetition(t)
            } else {
                kind = .unknown(head)
            }
        } else if head == "low_logprob" {
            kind = .lowLogprob
        } else {
            kind = .unknown(head)
        }
        self.init(kind: kind, channel: channel, raw: raw_)
    }
}

extension DoomLoopSignal {
    /// The tightest label among `raws`: the `tail_repetition` trigger with
    /// the LOWEST threshold (tighter repetition = stronger evidence),
    /// falling back to the first label when none parse as `tail_repetition`.
    /// Raw labels only — telemetry-safe.
    public static func tightest(_ raws: [String]) -> String? {
        var first: String?
        var best: (threshold: UInt32, raw: String)?
        for raw in raws {
            if first == nil { first = raw }
            let parsed = DoomLoopSignal(parsing: raw)
            if case .tailRepetition(let t) = parsed.kind {
                if best == nil || t < best!.threshold {
                    best = (t, raw)
                }
            }
        }
        return best?.raw ?? first
    }
}

/// Result of peeking a raw SSE `data:` payload for doom-loop content.
public enum DoomLoopPeek: Sendable, Equatable {
    /// The payload is the non-standard `response.doom_loop_check` event.
    /// The caller must swallow it (never forward to the typed event parser);
    /// the array is empty when the payload is malformed.
    case checkEvent([DoomLoopSignal])
    /// The payload is an ordinary event whose `response` object carries a
    /// `doom_loop_check` field (the terminal belt-and-braces copy).
    case responseField([DoomLoopSignal])
    /// Nothing doom-loop related; forward untouched.
    case none
}

/// Tolerantly peek a raw SSE `data:` JSON payload for doom-loop content.
///
/// Cheap for the common case: payloads that don't mention `doom_loop_check`
/// return `.none` without a JSON parse. Anything malformed degrades to
/// `.none` or an empty trigger array — never an error.
public func peekDoomLoop(_ data: String) -> DoomLoopPeek {
    if !data.contains("doom_loop_check") { return .none }
    guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(data.utf8)) else {
        return .none
    }
    if value["type"]?.stringValue == DOOM_LOOP_CHECK_EVENT_TYPE {
        let triggers = value["doom_loop_check"]?["triggers"]
        return .checkEvent(parseTriggers(triggers))
    }
    if let triggers = value["response"]?["doom_loop_check"]?["triggers"] {
        return .responseField(parseTriggers(triggers))
    }
    return .none
}

/// True when an SSE frame IS the doom-loop check event — by its SSE `event:`
/// name, or by a tolerant peek of the payload's `"type"` tag, gated on a
/// cheap substring precheck so normal traffic never pays a JSON parse.
public func isCheckEvent(eventName: String, data: String) -> Bool {
    if eventName == DOOM_LOOP_CHECK_EVENT_TYPE { return true }
    if !data.contains(DOOM_LOOP_CHECK_EVENT_TYPE) { return false }
    guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(data.utf8)) else {
        return false
    }
    return value["type"]?.stringValue == DOOM_LOOP_CHECK_EVENT_TYPE
}

/// Parse a `triggers` JSON value into signals, skipping non-string entries.
/// A missing or non-array value yields an empty array.
private func parseTriggers(_ triggers: JSONValue?) -> [DoomLoopSignal] {
    guard let triggers, case .array(let arr) = triggers else { return [] }
    return arr.compactMap { v in
        if let s = v.stringValue { return DoomLoopSignal(parsing: s) }
        return nil
    }
}
