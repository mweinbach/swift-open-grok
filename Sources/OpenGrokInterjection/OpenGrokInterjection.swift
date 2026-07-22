// OpenGrokInterjection.swift
//
// Shared mid-turn interjection buffer and formatting for the client and
// server agent loops.
//
// This is the Swift port of the Rust crate `xai-interjection-core`
// (crates/common/xai-interjection-core). It provides:
//
//   * `EventQueue<E>` — a thread-safe, `Arc`-shared FIFO queue of
//     out-of-band events. Producers enqueue; readers drain at hook
//     points. Mirrors `xai_interjection_core::events::EventQueue`.
//   * `InterjectionBuffer<Attachment>` — `EventQueue<PendingInterjection<Attachment>>`,
//     the queue of buffered mid-turn interjections awaiting the next safe
//     drain point.
//   * `drainFormatted(_:sanitize:)` — drains the buffer, framing each
//     entry as a synthetic user message (FIFO, one message per entry,
//     never merged). Mirrors `xai_interjection_core::buffer::drain_formatted`.
//   * `formatInterjection(_:)` and `userQuery(_:)` — the canonical wire
//     formatters, byte-identical to the shell's historical format.
//
// Concurrency parity: the Rust `EventQueue` is `Arc<Mutex<Vec<E>>>` and
// `Clone` (clones share one queue). The Swift port stores events in an
// actor-isolated `Box<[E]>` reference cell so multiple `EventQueue`
// values share one queue and all operations are serialized. This is the
// idiomatic Swift 6 strict-concurrency translation of `Arc<Mutex<_>>`.
//
// Wire-form parity: `formatInterjection` and `userQuery` produce
// byte-identical output to the Rust formatters (including the UTF-8
// boundary truncation rule and the `... [truncated]` suffix). The Swift
// Testing suite in `Tests/OpenGrokInterjectionTests/` pins the format.
//
// Rust crate mapping: xai-interjection-core
// (crates/common/xai-interjection-core). See CRATE_MAP.md and
// PORT_PLAN.md (W1-S2).

import Foundation

// MARK: - EventQueue

/// A thread-safe, shared FIFO queue of out-of-band events.
///
/// Producers enqueue events for later draining; readers drain the ones
/// relevant to them at hook points. Clones share one underlying queue
/// (Rust `Arc<Mutex<Vec<E>>>` parity); mutation is serialized through
/// `NSRecursiveLock`-protected access to a shared heap cell so the type
/// stays `Sendable` even when `E` is not reference-type-free.
///
/// Swift port of `xai_interjection_core::events::EventQueue`.
public final class EventQueue<E>: @unchecked Sendable {
    /// Shared mutable backing storage. Clones of `EventQueue` share one
    /// `Storage` instance, mirroring `Arc<Mutex<Vec<E>>>` semantics.
    private final class Storage: @unchecked Sendable {
        var events: [E] = []
    }

    private let storage: Storage
    /// Recursive lock guarding `storage.events`. Recursive because
    /// `pushCapped` and `drainMatching` re-enter through `lock()`.
    private let lock: NSRecursiveLock

    public init() {
        self.storage = Storage()
        self.lock = NSRecursiveLock()
    }

    /// Internal initializer used by `clone()` to share the same storage
    /// and lock.
    private init(storage: Storage, lock: NSRecursiveLock) {
        self.storage = storage
        self.lock = lock
    }

    /// Returns a new `EventQueue` that shares the same underlying queue.
    /// Mirrors Rust `Clone for EventQueue` (`Arc::clone`).
    public func clone() -> EventQueue<E> {
        EventQueue<E>(storage: storage, lock: lock)
    }

    /// Helper: lock the queue and run a closure with mutable access to
    /// the underlying array.
    @inline(__always)
    private func withLockedArray<R>(_ body: (inout [E]) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&storage.events)
    }

    /// Producer hook: record an event for later draining.
    public func push(_ event: E) {
        withLockedArray { arr in arr.append(event) }
    }

    /// Push, then drop the oldest events so at most `max` remain.
    public func pushCapped(_ event: E, max: Int) {
        withLockedArray { arr in
            arr.append(event)
            if arr.count > max {
                let excess = arr.count - max
                arr.removeFirst(excess)
            }
        }
    }

    /// The number of events currently buffered.
    public var count: Int {
        withLockedArray { arr in arr.count }
    }

    /// `true` when no events are buffered.
    public var isEmpty: Bool {
        withLockedArray { arr in arr.isEmpty }
    }

    /// Remove and return events matching `take`, retaining the rest.
    /// FIFO order is preserved in both the returned and retained sets.
    public func drainMatching(_ take: (E) -> Bool) -> [E] {
        withLockedArray { arr in
            var matched: [E] = []
            var kept: [E] = []
            for element in arr {
                if take(element) {
                    matched.append(element)
                } else {
                    kept.append(element)
                }
            }
            arr = kept
            return matched
        }
    }

    /// Remove and return all events, leaving the queue empty (FIFO
    /// order).
    public func drainAll() -> [E] {
        withLockedArray { arr in
            let out = arr
            arr.removeAll(keepingCapacity: false)
            return out
        }
    }

    /// Discard all events.
    public func clear() {
        withLockedArray { arr in arr.removeAll(keepingCapacity: false) }
    }
}

extension EventQueue where E: Equatable {
    /// Clone of the current events, for inspection without draining.
    /// Mirrors `EventQueue<E: Clone>::snapshot`.
    public func snapshot() -> [E] {
        withLockedArray { arr in arr }
    }
}

// MARK: - PendingInterjection / FormattedInterjection

/// A buffered mid-turn interjection awaiting the next safe drain point.
/// `Attachment` is host-defined (inline images, asset IDs); core never
/// reads it.
///
/// Swift port of `xai_interjection_core::buffer::PendingInterjection`.
/// `Codable` so hosts can persist pending interjections across
/// reconnects if they choose (the Rust derive is `Serialize, Deserialize`
/// for the same reason).
public struct PendingInterjection<Attachment>: Hashable, Sendable, Codable where Attachment: Hashable & Sendable & Codable {
    public var text: String
    public var attachments: [Attachment]

    public init(text: String, attachments: [Attachment] = []) {
        self.text = text
        self.attachments = attachments
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case attachments
    }
}

/// A drained entry, wrapped and ready to emit as a synthetic user
/// message.
///
/// Swift port of `xai_interjection_core::buffer::FormattedInterjection`.
/// Not `Codable` — the Rust twin is also not serialized; the formatter
/// has already baked the wire text into `text`.
public struct FormattedInterjection<Attachment>: Hashable, Sendable where Attachment: Hashable & Sendable {
    public var text: String
    public var attachments: [Attachment]

    public init(text: String, attachments: [Attachment] = []) {
        self.text = text
        self.attachments = attachments
    }
}

/// A queue of pending interjections — just an `EventQueue` of
/// `PendingInterjection`. Use `drainFormatted(_:sanitize:)` to drain +
/// frame them as synthetic user messages.
///
/// Swift port of `xai_interjection_core::buffer::InterjectionBuffer`.
public typealias InterjectionBuffer<Attachment> = EventQueue<PendingInterjection<Attachment>> where Attachment: Hashable & Sendable & Codable

/// Drain `buffer`, framing each entry as a synthetic user message (FIFO,
/// one message per entry, never merged). `sanitize` runs on the raw text
/// first (hosts strip artifacts like image placeholder paths; pass
/// `id` if none).
///
/// Swift port of `xai_interjection_core::buffer::drain_formatted`.
public func drainFormatted<Attachment>(
    _ buffer: InterjectionBuffer<Attachment>,
    sanitize: (String) -> String
) -> [FormattedInterjection<Attachment>] where Attachment: Hashable & Sendable & Codable {
    buffer.drainAll().map { entry in
        FormattedInterjection(
            text: formatInterjection(sanitize(entry.text)),
            attachments: entry.attachments
        )
    }
}

/// Convenience overload that performs no sanitization (the Rust
/// `std::convert::identity` case). Equivalent to passing `{ s in s }`.
public func drainFormatted<Attachment>(
    _ buffer: InterjectionBuffer<Attachment>
) -> [FormattedInterjection<Attachment>] where Attachment: Hashable & Sendable & Codable {
    drainFormatted(buffer, sanitize: { s in s })
}

// MARK: - Formatting

/// Truncation threshold, matching the shell's large-prompt limit.
public let largePromptThreshold: Int = 25_000

/// Wrap a user message in the canonical `<user_query>` envelope.
///
/// Swift port of `xai_interjection_core::format::user_query`. Output is
/// byte-identical to the Rust formatter.
public func userQuery(_ userMessage: String) -> String {
    "<user_query>\n\(userMessage)\n</user_query>"
}

/// Wrap interjection text as a synthetic user message with a mid-turn
/// note. No deferral instruction: the model decides how to weigh it
/// against in-flight work. Output is byte-identical to the shell's
/// historical format.
///
/// Swift port of `xai_interjection_core::format::format_interjection`.
/// The truncation rule preserves the UTF-8 boundary: the cut is taken at
/// the last UTF-8 scalar whose start offset is below
/// `largePromptThreshold`, matching Rust's
/// `char_indices().take_while(|(i, _)| *i < LARGE_PROMPT_THRESHOLD)` —
/// the resulting slice extends to the END of that scalar
/// (`i + c.len_utf8()`), so the prefix is always UTF-8-valid.
public func formatInterjection(_ text: String) -> String {
    let truncated: String
    if text.utf8.count > largePromptThreshold {
        // Mirror Rust's UTF-8-boundary truncation: walk the string by
        // Unicode scalar (`Rust char`), measure progress in UTF-8 bytes,
        // and keep scalars whose START offset is strictly below
        // `largePromptThreshold`. The slice extends to the END of the
        // last kept scalar (Rust's `i + c.len_utf8()`).
        //
        // We iterate the `unicodeScalars` view (not `String.Iterator`'s
        // grapheme clusters) so each step is exactly one `char`-equivalent
        // and `scalar.utf8.count` is `c.len_utf8()`.
        var byteCut = 0
        var scalarCount = 0
        for scalar in text.unicodeScalars {
            if byteCut >= largePromptThreshold {
                break
            }
            byteCut += scalar.utf8.count
            scalarCount += 1
        }
        let prefix = String(text.unicodeScalars.prefix(scalarCount))
        truncated = "\(prefix)... [truncated]"
    } else {
        truncated = text
    }

    return "The user sent a message while you were working:\n\(userQuery(truncated))"
}

// MARK: - Interjection kinds
//
// Hosts distinguish mid-turn steering from follow-ups, interrupts, and
// queued-prompt drains. Core formatting is shared; dequeue order remains
// FIFO via EventQueue.

/// Why a mid-turn message was buffered.
public enum InterjectionKind: String, Hashable, Sendable, Codable {
    /// User steered the in-flight turn.
    case steer
    /// User provided a follow-up that should run after the turn.
    case followUp = "follow_up"
    /// Hard interrupt requesting cancellation of the current turn.
    case interrupt
    /// A queued prompt promoted into the interjection path.
    case queuedPrompt = "queued_prompt"
}

/// A pending interjection tagged with its host-visible kind.
public struct KindedInterjection<Attachment>: Hashable, Sendable, Codable
where Attachment: Hashable & Sendable & Codable {
    public var kind: InterjectionKind
    public var pending: PendingInterjection<Attachment>

    public init(kind: InterjectionKind, text: String, attachments: [Attachment] = []) {
        self.kind = kind
        self.pending = PendingInterjection(text: text, attachments: attachments)
    }

    public init(kind: InterjectionKind, pending: PendingInterjection<Attachment>) {
        self.kind = kind
        self.pending = pending
    }
}

/// Drain kinded interjections as formatted synthetic user messages,
/// preserving FIFO order and never merging entries.
public func drainKindedFormatted<Attachment>(
    _ buffer: EventQueue<KindedInterjection<Attachment>>,
    sanitize: (String) -> String = { $0 }
) -> [(kind: InterjectionKind, formatted: FormattedInterjection<Attachment>)]
where Attachment: Hashable & Sendable & Codable {
    buffer.drainAll().map { entry in
        (
            kind: entry.kind,
            formatted: FormattedInterjection(
                text: formatInterjection(sanitize(entry.pending.text)),
                attachments: entry.pending.attachments
            )
        )
    }
}
