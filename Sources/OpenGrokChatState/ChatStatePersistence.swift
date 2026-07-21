// ChatStatePersistence.swift
//
// Open Grok — Swift port of the chat persistence protocol and mock/null
// implementations in `crates/codegen/xai-chat-state/src/persistence.rs`.
//
// The actor owns persistence exclusively (via a `ChatPersistence` adapter),
// so all methods take `mutating self` — no locks, no atomics, no shared
// state. The mock collects records into a synchronous buffer the test
// drains; the real implementation (W7-S2 OpenGrokSessionPersistence) wraps
// a JSONL sink under `OPENGROK_HOME`.

import Foundation
import OpenGrokSamplingTypes
import OpenGrokShared

/// Abstraction over chat-specific persistence operations.
///
/// The actor owns this exclusively, so all methods can take `mutating self`.
/// Conforming types must be `Sendable` so the actor (a Swift `actor`) can
/// hold them without crossing isolation boundaries.
public protocol ChatPersistence: Sendable {
    /// Persist a single conversation item (append to chat_history.jsonl).
    func persistMessage(_ item: ConversationItem)
    /// Replace the entire chat history (compaction / rewind).
    func replaceHistory(_ items: [ConversationItem])
    /// Flush pending writes to disk.
    func flush()
}

/// A record of a persistence call, collected by the mock for test inspection.
public enum PersistenceRecord: Sendable, Equatable {
    case message(ConversationItem)
    case replaceHistory([ConversationItem])
    case flush
}

/// Test implementation: collects every call as a `PersistenceRecord` into a
/// synchronous buffer. The test drains the buffer to inspect what the actor
/// did. Thread-safe via a lock (the actor is the sole writer, but tests read
/// concurrently).
public final class MockChatPersistence: ChatPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [PersistenceRecord] = []

    public init() {}

    public func persistMessage(_ item: ConversationItem) {
        lock.lock()
        defer { lock.unlock() }
        records.append(.message(item))
    }

    public func replaceHistory(_ items: [ConversationItem]) {
        lock.lock()
        defer { lock.unlock() }
        records.append(.replaceHistory(items))
    }

    public func flush() {
        lock.lock()
        defer { lock.unlock() }
        records.append(.flush)
    }

    /// Drain and return all pending records.
    public func drain() -> [PersistenceRecord] {
        lock.lock()
        defer { lock.unlock() }
        let out = records
        records.removeAll()
        return out
    }

    /// Collect all `message` items received so far (drains the buffer).
    public func messages() -> [ConversationItem] {
        drain().compactMap { record in
            if case .message(let item) = record { return item }
            return nil
        }
    }
}

/// No-op implementation: discards everything (for benchmarks / noop
/// scenarios).
public struct NullChatPersistence: ChatPersistence, Sendable {
    public init() {}

    public func persistMessage(_ item: ConversationItem) {}
    public func replaceHistory(_ items: [ConversationItem]) {}
    public func flush() {}
}
