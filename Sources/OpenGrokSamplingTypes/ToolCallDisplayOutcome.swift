// ToolCallDisplayOutcome.swift
//
// Open Grok — UI/session sidecar for per-tool terminal display state.
//
// This is **not** a Chat Completions / Responses / Anthropic Messages wire
// field. `ToolResultItem` deliberately carries only provider-exportable
// content (`tool_call_id`, `content`, images, ordered content). Exporting a
// success/failure bit on that type would leak into provider transcripts.
//
// Session resume (`/resume`) and dashboard peek need the live turn's terminal
// accent (succeeded / failed / cancelled / denied / pending). Rust preserves
// that via ACP `ToolCallStatus` on replay (`acp/tracker.rs` terminal status
// on `is_replay`). This port stores the same fact in a session-local map
// keyed by tool call id, written by the live tool executor and read by seed
// / peek — never by provider export.
//
// Cost of a sidecar vs. extending `ToolResultItem`: resume honesty requires a
// deliberate load of this map; forgetting it still compiles and silently
// reverts to the old hard-coded `.succeeded` lie. The live owner must wire
// record + seed; the type alone cannot force that.

import Foundation

// MARK: - Outcome

/// Terminal (or still-open) display state for one tool call card.
///
/// Raw values are stable session-file tokens. They are not provider wire
/// vocabulary and must not be serialized onto `ToolResultItem`.
public enum ToolCallDisplayOutcome: String, Codable, Sendable, Equatable, Hashable {
    case succeeded
    case failed
    case cancelled
    case denied
    case pending
}

// MARK: - Record

/// One call's persisted display outcome.
public struct ToolCallOutcomeRecord: Codable, Sendable, Equatable, Hashable {
    public var callID: String
    public var outcome: ToolCallDisplayOutcome
    /// Optional card detail (e.g. `"exit code 7"`, denial reason). Omitted
    /// from JSON when `nil` or empty.
    public var detail: String?

    public init(
        callID: String,
        outcome: ToolCallDisplayOutcome,
        detail: String? = nil
    ) {
        self.callID = callID
        self.outcome = outcome
        self.detail = detail.flatMap { $0.isEmpty ? nil : $0 }
    }

    public enum CodingKeys: String, CodingKey {
        case callID = "call_id"
        case outcome
        case detail
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.callID = try c.decode(String.self, forKey: .callID)
        self.outcome = try c.decode(ToolCallDisplayOutcome.self, forKey: .outcome)
        let detail = try c.decodeIfPresent(String.self, forKey: .detail)
        self.detail = detail.flatMap { $0.isEmpty ? nil : $0 }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(callID, forKey: .callID)
        try c.encode(outcome, forKey: .outcome)
        try c.encodeIfPresent(detail.flatMap { $0.isEmpty ? nil : $0 }, forKey: .detail)
    }
}

// MARK: - Map

/// Session-local map of tool-call display outcomes, keyed by call id.
///
/// Lookup never invents `.succeeded` for a missing key — it returns `nil` so
/// resume can default unpaired calls to `.pending` (or running/failed with
/// no output), never a hard-coded success.
public struct ToolCallOutcomeMap: Codable, Sendable, Equatable, Hashable {
    private var storage: [String: ToolCallOutcomeRecord]

    public init() {
        self.storage = [:]
    }

    public init(records: [ToolCallOutcomeRecord]) {
        var storage: [String: ToolCallOutcomeRecord] = [:]
        storage.reserveCapacity(records.count)
        for record in records {
            storage[record.callID] = record
        }
        self.storage = storage
    }

    public var isEmpty: Bool { storage.isEmpty }

    public var count: Int { storage.count }

    public var callIDs: [String] { Array(storage.keys) }

    public var records: [ToolCallOutcomeRecord] { Array(storage.values) }

    /// Returns the stored outcome, or `nil` when the call id was never recorded.
    ///
    /// Callers must not coalesce `nil` to `.succeeded`.
    public func outcome(for callID: String) -> ToolCallDisplayOutcome? {
        storage[callID]?.outcome
    }

    /// Full record for `callID`, or `nil` when missing.
    public func record(for callID: String) -> ToolCallOutcomeRecord? {
        storage[callID]
    }

    /// Insert or replace the outcome for `record.callID`.
    public mutating func upsert(_ record: ToolCallOutcomeRecord) {
        storage[record.callID] = record
    }

    /// Convenience upsert from parts.
    public mutating func upsert(
        callID: String,
        outcome: ToolCallDisplayOutcome,
        detail: String? = nil
    ) {
        upsert(ToolCallOutcomeRecord(callID: callID, outcome: outcome, detail: detail))
    }

    /// Merge `other` into this map. Matching call ids are overwritten by
    /// `other` (last-write-wins).
    public mutating func merge(_ other: ToolCallOutcomeMap) {
        for (callID, record) in other.storage {
            storage[callID] = record
        }
    }

    /// Non-mutating merge; `other` overwrites on conflict.
    public func merging(_ other: ToolCallOutcomeMap) -> ToolCallOutcomeMap {
        var copy = self
        copy.merge(other)
        return copy
    }

    public mutating func remove(callID: String) {
        storage.removeValue(forKey: callID)
    }

    public mutating func removeAll() {
        storage.removeAll()
    }

    // Wire form: JSON object keyed by call id. Values carry outcome + optional
    // detail (call id is the key, not repeated). Empty map → `{}`.
    private struct StoredValue: Codable, Sendable, Equatable {
        var outcome: ToolCallDisplayOutcome
        var detail: String?

        enum CodingKeys: String, CodingKey {
            case outcome
            case detail
        }

        init(outcome: ToolCallDisplayOutcome, detail: String?) {
            self.outcome = outcome
            self.detail = detail.flatMap { $0.isEmpty ? nil : $0 }
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.outcome = try c.decode(ToolCallDisplayOutcome.self, forKey: .outcome)
            let detail = try c.decodeIfPresent(String.self, forKey: .detail)
            self.detail = detail.flatMap { $0.isEmpty ? nil : $0 }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(outcome, forKey: .outcome)
            try c.encodeIfPresent(detail, forKey: .detail)
        }
    }

    public init(from decoder: Decoder) throws {
        // Prefer object form `{ "call-id": { "outcome": "…" } }`. Also accept
        // an array of full records for hand-written fixtures. JSON null → empty.
        let container = try decoder.singleValueContainer()
        if let dict = try? container.decode([String: StoredValue].self) {
            var storage: [String: ToolCallOutcomeRecord] = [:]
            storage.reserveCapacity(dict.count)
            for (callID, value) in dict {
                storage[callID] = ToolCallOutcomeRecord(
                    callID: callID,
                    outcome: value.outcome,
                    detail: value.detail
                )
            }
            self.storage = storage
            return
        }
        if let records = try? container.decode([ToolCallOutcomeRecord].self) {
            var storage: [String: ToolCallOutcomeRecord] = [:]
            storage.reserveCapacity(records.count)
            for record in records {
                storage[record.callID] = record
            }
            self.storage = storage
            return
        }
        if container.decodeNil() {
            self.storage = [:]
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "ToolCallOutcomeMap expects a call-id object or an array of records"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var dict: [String: StoredValue] = [:]
        dict.reserveCapacity(storage.count)
        for (callID, record) in storage {
            dict[callID] = StoredValue(outcome: record.outcome, detail: record.detail)
        }
        // Empty → `{}`. Parents that want to omit the field entirely should
        // `encodeIfPresent(map.isEmpty ? nil : map, …)`.
        var container = encoder.singleValueContainer()
        try container.encode(dict)
    }
}

// MARK: - State-string helpers

extension ToolCallDisplayOutcome {
    /// Map an `OpenGrokShellToolState` raw value without importing OpenGrokShell.
    ///
    /// Known tokens: `running`, `succeeded`, `failed`, `cancelled`.
    /// `running` becomes `.pending` (not yet terminal for resume).
    /// Unknown strings return `nil`.
    public static func outcome(fromShellState raw: String) -> ToolCallDisplayOutcome? {
        switch raw {
        case "succeeded": return .succeeded
        case "failed": return .failed
        case "cancelled": return .cancelled
        case "denied": return .denied
        case "pending", "running": return .pending
        default: return nil
        }
    }

    /// Map an `OpenGrokPagerToolState` / `PagerToolState` raw value without
    /// importing pager modules.
    ///
    /// Known tokens: `pending`, `running`, `succeeded`, `failed`, `cancelled`.
    /// `running` becomes `.pending`. Unknown strings return `nil`.
    public static func outcome(fromPagerState raw: String) -> ToolCallDisplayOutcome? {
        switch raw {
        case "succeeded": return .succeeded
        case "failed": return .failed
        case "cancelled": return .cancelled
        case "denied": return .denied
        case "pending", "running": return .pending
        default: return nil
        }
    }
}
