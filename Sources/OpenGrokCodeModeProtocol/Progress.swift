import Foundation
import OpenGrokShared

/// Maximum queued progress chunks for one nested invocation. A slow JavaScript
/// consumer loses its oldest chunk instead of accumulating unbounded output.
public let NESTED_TOOL_PROGRESS_CAPACITY = 64

/// Observation-only output emitted while a nested tool is still running.
///
/// Rust serializes an absent payload as JSON null, rather than omitting it.
/// Keeping that detail makes the subprocess transport and JavaScript callback
/// agree with `xai-grok-code-mode-protocol/src/progress.rs:27-49`.
public struct NestedToolProgress: Codable, Equatable, Sendable {
    public let text: String
    public let payload: JSONValue?

    public init(text: String, payload: JSONValue? = nil) {
        self.text = text
        self.payload = payload
    }

    public static func text(_ text: String) -> NestedToolProgress {
        NestedToolProgress(text: text)
    }

    public static func withPayload(_ text: String, _ payload: JSONValue) -> NestedToolProgress {
        NestedToolProgress(text: text, payload: payload)
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case payload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        payload = try container.decodeIfPresent(JSONValue.self, forKey: .payload)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        if let payload {
            try container.encode(payload, forKey: .payload)
        } else {
            try container.encodeNil(forKey: .payload)
        }
    }
}

fileprivate final class NestedToolProgressChannelState: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [NestedToolProgress] = []
    private var waiters: [UUID: CheckedContinuation<NestedToolProgress?, Never>] = [:]
    private var waiterOrder: [UUID] = []
    private var closed = false
    private var dropped = UInt64.zero

    var isClosed: Bool {
        lock.withLock { closed }
    }

    var droppedChunks: UInt64 {
        lock.withLock { dropped }
    }

    func push(_ progress: NestedToolProgress) {
        let waiter: CheckedContinuation<NestedToolProgress?, Never>? = lock.withLock {
            guard !closed else { return nil }
            if let id = waiterOrder.first {
                waiterOrder.removeFirst()
                return waiters.removeValue(forKey: id)
            }
            if queue.count >= NESTED_TOOL_PROGRESS_CAPACITY {
                queue.removeFirst()
                dropped += 1
            }
            queue.append(progress)
            return nil
        }
        waiter?.resume(returning: progress)
    }

    func tryReceive() -> NestedToolProgress? {
        lock.withLock {
            guard !queue.isEmpty else { return nil }
            return queue.removeFirst()
        }
    }

    func registerWaiter(
        id: UUID,
        continuation: CheckedContinuation<NestedToolProgress?, Never>
    ) {
        let immediate: (shouldResume: Bool, progress: NestedToolProgress?) = lock.withLock {
            if !queue.isEmpty {
                return (true, queue.removeFirst())
            }
            if closed || Task.isCancelled {
                return (true, nil)
            }
            waiters[id] = continuation
            waiterOrder.append(id)
            return (false, nil)
        }
        if immediate.shouldResume {
            continuation.resume(returning: immediate.progress)
        }
    }

    func cancelWaiter(_ id: UUID) {
        let waiter: CheckedContinuation<NestedToolProgress?, Never>? = lock.withLock {
            guard let waiter = waiters.removeValue(forKey: id) else { return nil }
            waiterOrder.removeAll { $0 == id }
            return waiter
        }
        waiter?.resume(returning: nil)
    }

    func close() {
        let pending: [CheckedContinuation<NestedToolProgress?, Never>] = lock.withLock {
            guard !closed else { return [] }
            closed = true
            let pending = Array(waiters.values)
            waiters.removeAll()
            waiterOrder.removeAll()
            return pending
        }
        for waiter in pending {
            waiter.resume(returning: nil)
        }
    }
}

/// Producer half of one bounded nested-tool progress channel.
///
/// Copies share this ARC-owned handle; the channel closes when its last
/// producer reference disappears, mirroring the upstream cloned-sink lifetime.
public final class NestedToolProgressSink: @unchecked Sendable {
    private let state: NestedToolProgressChannelState

    fileprivate init(state: NestedToolProgressChannelState) {
        self.state = state
    }

    deinit {
        state.close()
    }

    public func push(_ progress: NestedToolProgress) {
        state.push(progress)
    }

    public var droppedChunks: UInt64 {
        state.droppedChunks
    }

    public var isClosed: Bool {
        state.isClosed
    }
}

/// Consumer half of one nested-tool progress channel. Closing preserves
/// already-queued chunks while rejecting every later producer push.
public final class NestedToolProgressReceiver: @unchecked Sendable {
    private let state: NestedToolProgressChannelState

    fileprivate init(state: NestedToolProgressChannelState) {
        self.state = state
    }

    deinit {
        state.close()
    }

    public var isClosed: Bool {
        state.isClosed
    }

    public func close() {
        state.close()
    }

    public func tryReceive() -> NestedToolProgress? {
        state.tryReceive()
    }

    public func receive() async -> NestedToolProgress? {
        guard !Task.isCancelled else { return nil }
        let id = UUID()
        let state = self.state
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                state.registerWaiter(id: id, continuation: continuation)
            }
        } onCancel: {
            state.cancelWaiter(id)
        }
    }
}

/// Creates a bounded, FIFO, drop-oldest progress channel for one invocation.
public func nestedToolProgressChannel() -> (
    sink: NestedToolProgressSink,
    receiver: NestedToolProgressReceiver
) {
    let state = NestedToolProgressChannelState()
    return (NestedToolProgressSink(state: state), NestedToolProgressReceiver(state: state))
}
