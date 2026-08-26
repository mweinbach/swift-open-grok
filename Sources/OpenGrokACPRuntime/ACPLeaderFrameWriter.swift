import Foundation
import OpenGrokHTTP

enum ACPLeaderFrameWriterError: Error, Sendable, Hashable, CustomStringConvertible {
    case queueLimitExceeded(maximumFrames: Int, maximumBytes: Int)

    var description: String {
        switch self {
        case .queueLimitExceeded(let frames, let bytes):
            return "leader IPC write queue exceeds \(frames) frames or \(bytes) bytes"
        }
    }
}

/// One drain owns complete framed writes, including while channel.write
/// suspends. Actor isolation alone permits another send to enter during that
/// suspension and interleave the partial writes of two length-prefixed frames.
///
/// Rust pin 00e176c8fb4035701c24199bf9225973c1b13c20 uses one mutable writer
/// in leader/client.rs:498-523 and leader/server.rs:2476-2504. This queue also
/// bounds retained frames and bytes. Overload fails explicitly instead of
/// buffering without limit; cancelling a partially written frame costs the
/// entire connection because its framing cannot safely be recovered.
actor ACPLeaderFrameWriter {
    private struct PendingWrite {
        let id: UUID
        let frame: [UInt8]
        let continuation: CheckedContinuation<Void, Error>
    }

    private static let frameLimit = 64
    private static let byteLimit = ACPLeaderProtocolLimits.maximumMessageSize + 4

    private let channel: any WebSocketByteChannel
    private let maximumPendingFrames: Int
    private let maximumPendingBytes: Int
    private var queue: [PendingWrite] = []
    private var active: PendingWrite?
    private var pendingBytes = 0
    private var closed = false
    private var drainTask: Task<Void, Never>?
    private var closingTask: Task<Void, Never>?

    init(
        channel: any WebSocketByteChannel,
        maximumPendingFrames: Int = 64,
        maximumPendingBytes: Int = ACPLeaderProtocolLimits.maximumMessageSize + 4
    ) {
        self.channel = channel
        self.maximumPendingFrames = min(Self.frameLimit, max(1, maximumPendingFrames))
        self.maximumPendingBytes = min(Self.byteLimit, max(1, maximumPendingBytes))
    }

    /// Includes the frame currently in channel.write.
    func pendingFrameCount() -> Int {
        queue.count + (active == nil ? 0 : 1)
    }

    func write(_ frame: [UInt8]) async throws {
        try Task.checkCancellation()
        guard !closed else { throw ACPLeaderProtocolError.connectionClosed }
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard !closed else {
                    continuation.resume(throwing: ACPLeaderProtocolError.connectionClosed)
                    return
                }
                guard pendingFrameCount() < maximumPendingFrames,
                      frame.count <= maximumPendingBytes - pendingBytes
                else {
                    continuation.resume(throwing: ACPLeaderFrameWriterError.queueLimitExceeded(
                        maximumFrames: maximumPendingFrames,
                        maximumBytes: maximumPendingBytes
                    ))
                    return
                }
                pendingBytes += frame.count
                queue.append(PendingWrite(
                    id: id,
                    frame: frame,
                    continuation: continuation
                ))
                if drainTask == nil {
                    drainTask = Task { await drain() }
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func close() async {
        let draining = drainTask
        failPending(
            activeError: ACPLeaderProtocolError.connectionClosed,
            queuedError: ACPLeaderProtocolError.connectionClosed
        )
        await closeChannel()
        await draining?.value
    }

    private func drain() async {
        defer { drainTask = nil }
        while !closed, !queue.isEmpty {
            let write = queue.removeFirst()
            active = write
            do {
                try await channel.write(write.frame)
                guard active?.id == write.id else { return }
                active = nil
                pendingBytes -= write.frame.count
                write.continuation.resume()
            } catch {
                failPending(activeError: error, queuedError: error)
                await closeChannel()
                return
            }
        }
    }

    private func cancel(_ id: UUID) async {
        if active?.id == id {
            let draining = drainTask
            failPending(
                activeError: CancellationError(),
                queuedError: ACPLeaderProtocolError.connectionClosed
            )
            await closeChannel()
            await draining?.value
        } else if let index = queue.firstIndex(where: { $0.id == id }) {
            let write = queue.remove(at: index)
            pendingBytes -= write.frame.count
            write.continuation.resume(throwing: CancellationError())
        }
    }

    private func failPending(activeError: any Error, queuedError: any Error) {
        guard !closed else { return }
        closed = true
        let writing = active
        let queued = queue
        active = nil
        queue.removeAll()
        pendingBytes = 0
        drainTask?.cancel()
        writing?.continuation.resume(throwing: activeError)
        for write in queued {
            write.continuation.resume(throwing: queuedError)
        }
    }

    private func closeChannel() async {
        if let closingTask {
            await closingTask.value
            return
        }
        let channel = channel
        let closing = Task { await channel.close() }
        closingTask = closing
        await closing.value
    }
}
