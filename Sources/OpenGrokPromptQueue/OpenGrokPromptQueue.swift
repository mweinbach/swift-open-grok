// OpenGrokPromptQueue.swift
//
// Shared prompt-queue wire types for the Open Grok shell and pager.
//
// This is the Swift port of the Rust crate `xai-prompt-queue`
// (crates/codegen/xai-prompt-queue). It defines the per-row wire model
// the session actor publishes to subscribers and the broadcast payload
// for the `x.ai/queue/changed` notification. The actor's in-process
// state is held by the shell (W6-S4); only the JSON-stable wire types
// live here so the pager (W8/W9) and shell (W6-S4) can be compiled
// independently against the same wire contract.
//
// Wire-form parity is mandatory: the JSON shape (camelCase keys,
// `None` fields omitted, defaults for missing fields, unknown fields
// ignored) must round-trip byte-significantly against the Rust
// `serde_json` serializer. The Swift Testing suite in
// `Tests/OpenGrokPromptQueueTests/` pins the exact wire JSON and
// round-trip behavior translated from `xai-prompt-queue/src/types.rs`.
//
// Rust crate mapping: xai-prompt-queue (crates/codegen/xai-prompt-queue).
// See CRATE_MAP.md and PORT_PLAN.md (W1-S2).

import Foundation
import OpenGrokShared

/// Per-item queue metadata the session actor attaches to user-originated
/// inputs; synthetic inputs (auto-wake, nudges) carry none and never appear
/// in the visible queue. Held in actor state, never serialized itself.
///
/// Swift port of `xai_prompt_queue::types::QueueEntryMeta`. Unlike the
/// wire type, this struct intentionally does NOT conform to `Codable`:
/// it lives inside the session actor (W6-S4) and is never written to
/// disk or sent over the wire. The wire twin is `QueueEntryWire`.
public struct QueueEntryMeta: Hashable, Sendable {
    /// Stable id, reusing the prompt's unique `prompt_id`.
    public var id: String

    /// Monotonic, bumped on each in-place edit; an edit against a stale
    /// version is a no-op.
    public var version: UInt64

    /// Enqueuing client identifier (attribution); never overwritten by
    /// edits.
    public var owner: String?

    /// Most recent editor's client identifier, replaced on every in-place
    /// edit.
    public var lastEditor: String?

    /// Display kind label; client-cosmetic kinds resolve to their send-intent
    /// before enqueue.
    public var kind: String

    /// Plain prompt text for the shared queue display.
    public var text: String

    /// Create queue-entry metadata.
    public init(
        id: String,
        version: UInt64 = 0,
        owner: String? = nil,
        lastEditor: String? = nil,
        kind: String,
        text: String
    ) {
        self.id = id
        self.version = version
        self.owner = owner
        self.lastEditor = lastEditor
        self.kind = kind
        self.text = text
    }
}

/// One queue row on the wire.
///
/// Swift port of `xai_prompt_queue::types::QueueEntryWire`. Mirrors the
/// Rust `#[serde(rename_all = "camelCase")]` shape: `last_editor` →
/// `lastEditor` on the wire. The `owner` and `lastEditor` fields are
/// omitted from the wire when `nil` (Rust `skip_serializing_if =
/// "Option::is_none"`); all other optional fields default on decode.
public struct QueueEntryWire: Hashable, Sendable, Codable {
    public var id: String

    /// Defaults to `0` when missing on the wire.
    public var version: UInt64

    /// Omitted from the wire when `nil`.
    public var owner: String?

    /// Mirrors `QueueEntryMeta.lastEditor`; omitted from the wire when
    /// `nil`.
    public var lastEditor: String?

    /// Defaults to `""` when missing on the wire.
    public var kind: String

    /// Defaults to `""` when missing on the wire.
    public var text: String

    /// 0-based position among queued, not-yet-running prompts. Defaults
    /// to `0` when missing on the wire.
    public var position: Int

    private enum CodingKeys: String, CodingKey {
        case id
        case version
        case owner
        case lastEditor
        case kind
        case text
        case position
    }

    public init(
        id: String,
        version: UInt64 = 0,
        owner: String? = nil,
        lastEditor: String? = nil,
        kind: String = "",
        text: String = "",
        position: Int = 0
    ) {
        self.id = id
        self.version = version
        self.owner = owner
        self.lastEditor = lastEditor
        self.kind = kind
        self.text = text
        self.position = position
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        version = try container.decodeIfPresent(UInt64.self, forKey: .version) ?? 0
        owner = try container.decodeIfPresent(String.self, forKey: .owner)
        lastEditor = try container.decodeIfPresent(String.self, forKey: .lastEditor)
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? ""
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        position = try container.decodeIfPresent(Int.self, forKey: .position) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(version, forKey: .version)
        // Mirror Rust `skip_serializing_if = "Option::is_none"`.
        try container.encodeIfPresent(owner, forKey: .owner)
        try container.encodeIfPresent(lastEditor, forKey: .lastEditor)
        try container.encode(kind, forKey: .kind)
        try container.encode(text, forKey: .text)
        try container.encode(position, forKey: .position)
    }
}

/// Broadcast payload for the `x.ai/queue/changed` notification.
///
/// Swift port of `xai_prompt_queue::types::QueueChanged`. The `sessionId`
/// field is required on decode (Rust rejects a missing `session_id`); the
/// `runningPromptId` field is omitted from the wire when `nil`; `entries`
/// defaults to an empty array.
public struct QueueChanged: Hashable, Sendable, Codable {
    /// The session this queue belongs to; drives per-session fan-out
    /// routing. Required on the wire — a payload missing this field must
    /// fail to decode, not apply under the wrong key.
    public var sessionId: String

    /// Defaults to an empty array when missing on the wire.
    public var entries: [QueueEntryWire]

    /// The prompt the actor is currently draining, `nil` when no turn
    /// runs. The correlation signal a subscriber uses to adopt
    /// `current_prompt_id` for notification routing. Omitted from the
    /// wire when `nil`.
    public var runningPromptId: String?

    private enum CodingKeys: String, CodingKey {
        case sessionId
        case entries
        case runningPromptId
    }

    public init(
        sessionId: String,
        entries: [QueueEntryWire] = [],
        runningPromptId: String? = nil
    ) {
        self.sessionId = sessionId
        self.entries = entries
        self.runningPromptId = runningPromptId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `sessionId` is required — a missing key throws, matching Rust.
        sessionId = try container.decode(String.self, forKey: .sessionId)
        entries = try container.decodeIfPresent([QueueEntryWire].self, forKey: .entries) ?? []
        runningPromptId = try container.decodeIfPresent(String.self, forKey: .runningPromptId)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(entries, forKey: .entries)
        try container.encodeIfPresent(runningPromptId, forKey: .runningPromptId)
    }
}

extension QueueChanged: OpenGrokShared.Defaultable {
    /// The default broadcast: empty session id, no entries, no running
    /// prompt. Mirrors Rust `#[derive(Default)]`: `session_id` defaults
    /// to `String::default()` (the empty string), `entries` to `Vec::new`,
    /// `running_prompt_id` to `None`.
    public static var defaultValue: QueueChanged {
        QueueChanged(sessionId: "", entries: [], runningPromptId: nil)
    }
}

extension QueueChanged {
    /// `QueueChanged` with `sessionId` defaulted to the empty string.
    ///
    /// Mirrors Rust `#[derive(Default)]` — the broadcast derives
    /// `Default`, so callers can construct `QueueChanged::default()`
    /// without arguments. Provided as a convenience next to the
    /// `OpenGrokShared.Defaultable`-protocol default.
    public init() {
        self.init(sessionId: "", entries: [], runningPromptId: nil)
    }
}

// MARK: - FIFO prompt queue state machine
//
// Actor-owned in-process queue used by session hosts. Wire snapshots
// are produced as `QueueChanged` for pager subscribers. Ordering is
// strictly FIFO; edits bump version; stale-version edits are no-ops.

/// Errors from in-process prompt-queue mutations.
public enum PromptQueueError: Error, Hashable, Sendable {
    case notFound(id: String)
    case alreadyRunning
    case empty
}

/// Actor-safe FIFO prompt queue. Mirrors the session actor's visible
/// queue contract without owning the full session runtime.
public actor PromptQueue {
    public private(set) var entries: [QueueEntryMeta] = []
    public private(set) var runningPromptId: String?
    public let sessionId: String

    public init(sessionId: String) {
        self.sessionId = sessionId
    }

    /// Enqueue at the tail. Returns the enqueued entry with its position.
    @discardableResult
    public func enqueue(_ entry: QueueEntryMeta) -> QueueEntryWire {
        entries.append(entry)
        return wireSnapshot().entries.last!
    }

    /// Pop the front entry and mark it running. Fails if already running.
    public func beginNext() throws -> QueueEntryMeta {
        if runningPromptId != nil {
            throw PromptQueueError.alreadyRunning
        }
        guard !entries.isEmpty else {
            throw PromptQueueError.empty
        }
        let next = entries.removeFirst()
        runningPromptId = next.id
        return next
    }

    /// Clear the running marker after a turn completes.
    public func completeRunning() {
        runningPromptId = nil
    }

    /// Cancel the running prompt without dequeuing remaining work.
    public func cancelRunning() {
        runningPromptId = nil
    }

    /// In-place edit. Stale version is a no-op and returns nil.
    @discardableResult
    public func edit(
        id: String,
        expectedVersion: UInt64,
        text: String,
        kind: String? = nil,
        editor: String? = nil
    ) -> QueueEntryMeta? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        guard entries[index].version == expectedVersion else {
            return nil
        }
        entries[index].text = text
        if let kind {
            entries[index].kind = kind
        }
        entries[index].lastEditor = editor
        entries[index].version += 1
        return entries[index]
    }

    /// Remove a not-yet-running entry by id.
    @discardableResult
    public func remove(id: String) throws -> QueueEntryMeta {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            throw PromptQueueError.notFound(id: id)
        }
        return entries.remove(at: index)
    }

    /// Ordered ids currently queued (not including running).
    public var orderedIds: [String] {
        entries.map(\.id)
    }

    /// Number of queued, not-yet-running entries. This is the count the TUI
    /// renders as `+{n}`; a running prompt is no longer queued.
    public var count: Int {
        entries.count
    }

    public var isEmpty: Bool {
        entries.isEmpty
    }

    /// Ordered texts currently queued (not including running).
    public var orderedTexts: [String] {
        entries.map(\.text)
    }

    /// Drop every queued entry, leaving any running prompt alone. The explicit
    /// discard a quit performs — cancelling a turn must not reach for this.
    @discardableResult
    public func removeAll() -> [QueueEntryMeta] {
        let dropped = entries
        entries.removeAll()
        return dropped
    }

    /// Wire snapshot for `x.ai/queue/changed`.
    public func wireSnapshot() -> QueueChanged {
        let wires = entries.enumerated().map { index, entry in
            QueueEntryWire(
                id: entry.id,
                version: entry.version,
                owner: entry.owner,
                lastEditor: entry.lastEditor,
                kind: entry.kind,
                text: entry.text,
                position: index
            )
        }
        return QueueChanged(
            sessionId: sessionId,
            entries: wires,
            runningPromptId: runningPromptId
        )
    }
}
