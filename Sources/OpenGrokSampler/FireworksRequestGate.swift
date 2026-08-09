// FireworksRequestGate.swift
//
// Process-global pacing gate for Fireworks chat-completions requests. Port of
// the `.58` delta's `FIREWORKS_REQUEST_GATE` (`xai-grok-sampler/src/client.rs`
// at the pin): a `Semaphore(2)` static (client.rs:59-68) acquired for
// Fireworks requests only (client.rs:70-83), held for the whole request on
// the non-streaming path (client.rs:1878) and until the response stream drops
// on the streaming path (client.rs:1937, :2097-2100).
//
// Upstream leans on tokio RAII: dropping an `OwnedSemaphorePermit` releases,
// and dropping a parked `acquire_owned()` future removes the waiter without
// consuming a permit. Swift has neither, so both halves are explicit here:
// `ProviderRequestPermit` guards release for exactly-once, and a cancelled
// waiter is resumed throwing `CancellationError` and removed from the queue
// (no permit consumed, no stranded continuation).

import Foundation
import OpenGrokSamplingTypes

/// client.rs:59. Fireworks rejects bursts; two in-flight requests per process.
let FIREWORKS_MAX_CONCURRENT_REQUESTS = 2

/// The process-global gate (client.rs:61-68). One instance across every
/// session and client in the process — a Swift global `let` gives the same
/// lazy-once initialization as upstream's `OnceLock`.
let fireworksRequestGate = RequestPacingSemaphore(permits: FIREWORKS_MAX_CONCURRENT_REQUESTS)

/// Acquire a pacing permit for `provider`, or `nil` for the bypass.
/// Port of `acquire_provider_request_permit_from` (client.rs:70-83): every
/// provider except Fireworks bypasses without ever touching the gate.
///
/// Throws only `CancellationError`, when the caller's task is cancelled while
/// parked — the Swift spelling of dropping a parked tokio acquire future.
func acquireProviderRequestPermit(
    provider: ModelProvider,
    gate: RequestPacingSemaphore
) async throws -> ProviderRequestPermit? {
    guard provider == .fireworks else { return nil }
    try await gate.acquire()
    return ProviderRequestPermit(gate: gate)
}

/// A held pacing permit. `release()` is idempotent so the two mutually
/// exclusive release sites (the pre-stream error path and the stream's
/// termination handler) cannot double-release even if a future edit makes
/// them overlap; `deinit` is the RAII backstop that keeps parity with
/// upstream's drop semantics if a permit is ever abandoned unreleased.
final class ProviderRequestPermit: @unchecked Sendable {
    private let gate: RequestPacingSemaphore
    private let lock = NSLock()
    private var released = false

    init(gate: RequestPacingSemaphore) {
        self.gate = gate
    }

    deinit {
        release()
    }

    /// Return the permit to the gate. Safe to call more than once and from
    /// any context; only the first call releases.
    func release() {
        let shouldRelease: Bool = lock.withLock {
            if released { return false }
            released = true
            return true
        }
        guard shouldRelease else { return }
        // Synchronous callers (stream termination handlers, deinit) cannot
        // await the actor; the hop is fire-and-forget. Waiters therefore wake
        // asynchronously after release — same as tokio's semaphore.
        let gate = gate
        Task { await gate.release() }
    }
}

/// Actor-based counting semaphore with FIFO handoff. All bookkeeping is
/// actor-isolated, so every continuation is stored and resumed under
/// serialization; each is resumed exactly once, by exactly one of the four
/// sites named in `acquire`/`release`/`cancelWaiter`.
actor RequestPacingSemaphore {
    private let capacity: Int
    private var available: Int
    /// Parked acquirers, oldest first. `release()` hands its permit directly
    /// to the head instead of incrementing `available`, so a late arriver can
    /// never overtake a parked waiter.
    private var waiters: [(id: UInt64, continuation: CheckedContinuation<Void, any Error>)] = []
    /// Intents registered by `acquire()` before its first suspension and
    /// cleared when the matching continuation is resumed. Gates
    /// `cancelWaiter` so a cancellation delivered after the waiter was
    /// already resumed (permit granted, `withTaskCancellationHandler` not yet
    /// unwound) is a no-op instead of a second resume or a stale marker.
    private var outstandingIntents: Set<UInt64> = []
    /// Intents whose cancellation arrived before their continuation did.
    private var cancelledBeforeSuspension: Set<UInt64> = []
    private var nextIntentID: UInt64 = 0

    init(permits: Int) {
        capacity = permits
        available = permits
    }

    var availablePermits: Int { available }
    var waiterCount: Int { waiters.count }

    /// Take a permit, parking FIFO when none is free. A cancelled parked
    /// caller throws `CancellationError`, consumes no permit, and leaves the
    /// queue — the gate keeps serving everyone else.
    func acquire() async throws {
        if available > 0 {
            available -= 1
            return
        }
        let id = nextIntentID
        nextIntentID += 1
        outstandingIntents.insert(id)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                self.enqueueWaiter(id: id, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    /// Return one permit. Hands it straight to the oldest waiter if any.
    func release() {
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            outstandingIntents.remove(waiter.id)
            waiter.continuation.resume()
            return
        }
        precondition(
            available < capacity,
            "over-release of the Fireworks request gate — a permit was released twice"
        )
        available += 1
    }

    private func enqueueWaiter(
        id: UInt64,
        continuation: CheckedContinuation<Void, any Error>
    ) {
        if cancelledBeforeSuspension.remove(id) != nil {
            outstandingIntents.remove(id)
            continuation.resume(throwing: CancellationError())
            return
        }
        // A release may have interleaved between `acquire()` registering the
        // intent and this continuation arriving; parking now would strand the
        // caller until the next release.
        if available > 0 {
            available -= 1
            outstandingIntents.remove(id)
            continuation.resume()
            return
        }
        waiters.append((id: id, continuation: continuation))
    }

    private func cancelWaiter(id: UInt64) {
        guard outstandingIntents.contains(id) else {
            // Already resumed (a permit was granted just before cancellation
            // landed); the granted permit stays with the caller and is
            // released through the permit's normal lifecycle.
            return
        }
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: index)
            outstandingIntents.remove(id)
            waiter.continuation.resume(throwing: CancellationError())
            return
        }
        // Cancelled before the continuation reached the actor: leave the
        // intent registered and let `enqueueWaiter` resume-throw on arrival.
        cancelledBeforeSuspension.insert(id)
    }
}
