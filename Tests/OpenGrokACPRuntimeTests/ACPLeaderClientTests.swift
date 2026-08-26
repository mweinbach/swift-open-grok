import Foundation
import OpenGrokACP
@testable import OpenGrokACPRuntime
import OpenGrokHTTP
import Testing

@Suite("ACP leader client")
struct ACPLeaderClientTests {
    @Test("registers and demultiplexes ACP and control traffic")
    func registrationAndMultiplexing() async throws {
        let pair = InMemoryWebSocketChannel.makePair()
        let client = ACPLeaderClient(
            channel: pair.a,
            clientType: "test-client",
            mode: .stdio,
            capabilities: ACPLeaderClientCapabilities(
                clientVersion: "test",
                terminal: true,
                fsRead: true
            )
        )

        let server = Task { () throws -> ACPLeaderClientMessage in
            let reader = ACPLeaderChannelReader(
                channel: pair.b,
                maximumMessageSize: ACPLeaderProtocolLimits.maximumMessageSize
            )
            guard let registration = try await reader.next(ACPLeaderClientMessage.self) else {
                throw ACPLeaderProtocolError.connectionClosed
            }
            try await pair.b.write(try ACPLeaderCodec.encode(
                ACPLeaderServerMessage.registered(
                    clientID: 7,
                    ready: true,
                    protocolVersion: 1,
                    binaryVersion: "test-leader",
                    capabilities: ACPLeaderCapabilities(controlV1: true)
                )
            ))

            guard case .acp(let requestPayload) = try await reader.next(ACPLeaderClientMessage.self),
                  let requestData = requestPayload.data(using: .utf8),
                  let request = try? ACPMessage(data: requestData),
                  case .request(let requestID, _, _) = request
            else {
                throw ACPLeaderProtocolError.invalidJSON("expected ACP request")
            }
            try await pair.b.write(try ACPLeaderCodec.encode(
                ACPLeaderServerMessage.acp(
                    payload: String(decoding: try ACPMessage.notification(
                        method: "test/notification",
                        params: .object(["value": .string("interleaved")])
                    ).encodedData(), as: UTF8.self)
                )
            ))
            try await pair.b.write(try ACPLeaderCodec.encode(
                ACPLeaderServerMessage.acp(
                    payload: String(decoding: try ACPMessage.response(
                        id: requestID,
                        result: .object(["ok": .bool(true)]),
                        error: nil
                    ).encodedData(), as: UTF8.self)
                )
            ))

            guard case .control(let requestID, _) = try await reader.next(ACPLeaderClientMessage.self) else {
                throw ACPLeaderProtocolError.invalidJSON("expected control request")
            }
            try await pair.b.write(try ACPLeaderCodec.encode(
                ACPLeaderServerMessage.acp(
                    payload: String(decoding: try ACPMessage.notification(
                        method: "test/control-notification",
                        params: .object([:])
                    ).encodedData(), as: UTF8.self)
                )
            ))
            try await pair.b.write(try ACPLeaderCodec.encode(
                ACPLeaderServerMessage.controlResult(
                    requestID: requestID,
                    payload: .cpuProfileStatus(ACPLeaderCpuProfileStatus())
                )
            ))
            return registration
        }

        let registration = try await client.start()
        #expect(registration.clientID == 7)
        #expect(registration.binaryVersion == "test-leader")
        #expect(registration.capabilities?.controlV1 == true)

        let events = try await client.events()
        let response = try await client.request(
            method: "test/request",
            params: .object(["prompt": .string("hello")])
        )
        #expect(response == .object(["ok": .bool(true)]))
        var iterator = events.makeAsyncIterator()
        let firstEvent = try await iterator.next()
        guard case .notification(let method, let params) = firstEvent else {
            Issue.record("expected the interleaved notification")
            return
        }
        #expect(method == "test/notification")
        #expect(params == .object(["value": .string("interleaved")]))

        let control = try await client.control(["command": "status"])
        guard case .cpuProfileStatus(let status) = control else {
            Issue.record("expected the correlated control result")
            return
        }
        #expect(!status.active)
        let secondEvent = try await iterator.next()
        guard case .notification(let secondMethod, _) = secondEvent else {
            Issue.record("expected the second interleaved notification")
            return
        }
        #expect(secondMethod == "test/control-notification")

        let serverRegistration = try await server.value
        guard case .register(let clientType, let mode, let capabilities) = serverRegistration else {
            Issue.record("expected a register frame")
            return
        }
        #expect(clientType == "test-client")
        #expect(mode == .stdio)
        #expect(capabilities.terminal)
        #expect(capabilities.fsRead)

        await client.close()
        #expect(try await pair.b.read() == nil)
    }
}

private actor StalledLeaderWriteChannel: WebSocketByteChannel {
    private var firstWrite: CheckedContinuation<Void, Error>?
    private(set) var started: [[UInt8]] = []
    private(set) var bytes: [UInt8] = []
    private(set) var activeWrites = 0
    private(set) var maximumConcurrentWrites = 0
    private(set) var closeCalls = 0
    private(set) var closed = false

    func read() async throws -> [UInt8]? { nil }

    func write(_ frame: [UInt8]) async throws {
        guard !closed else { throw WebSocketChannelError.closed }
        let isFirst = started.isEmpty
        started.append(frame)
        activeWrites += 1
        maximumConcurrentWrites = max(maximumConcurrentWrites, activeWrites)
        defer { activeWrites -= 1 }
        let split = frame.count / 2
        bytes.append(contentsOf: frame.prefix(split))
        if isFirst {
            try await withCheckedThrowingContinuation { firstWrite = $0 }
        }
        guard !closed else { throw WebSocketChannelError.closed }
        bytes.append(contentsOf: frame.dropFirst(split))
    }

    func releaseFirstWrite() -> Bool {
        guard let firstWrite else { return false }
        self.firstWrite = nil
        firstWrite.resume()
        return true
    }

    func close() async {
        closeCalls += 1
        closed = true
        let firstWrite = firstWrite
        self.firstWrite = nil
        firstWrite?.resume(throwing: WebSocketChannelError.closed)
    }
}

private func waitForLeaderWriteState(
    _ ready: @Sendable () async -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        if await ready() { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    throw ACPTransportError.invalidMessage("leader write state did not arrive")
}

private func withStalledLeaderWriter(
    maximumPendingFrames: Int = 64,
    maximumPendingBytes: Int = ACPLeaderProtocolLimits.maximumMessageSize + 4,
    _ body: @Sendable (ACPLeaderFrameWriter, StalledLeaderWriteChannel) async throws -> Void
) async throws {
    let channel = StalledLeaderWriteChannel()
    let writer = ACPLeaderFrameWriter(
        channel: channel,
        maximumPendingFrames: maximumPendingFrames,
        maximumPendingBytes: maximumPendingBytes
    )
    do {
        try await body(writer, channel)
        await writer.close()
    } catch {
        await writer.close()
        throw error
    }
}

private func leaderWriteFailure(_ task: Task<Void, Error>) async -> (any Error)? {
    switch await task.result {
    case .success:
        Issue.record("leader frame write unexpectedly succeeded")
        return nil
    case .failure(let error):
        return error
    }
}

@Suite("Leader full-frame write serialization", .serialized)
struct ACPLeaderFrameWriterTests {
    @Test("concurrent frames remain FIFO while the first write is suspended",
          .timeLimit(.minutes(1)))
    func suspendedWriteCannotInterleaveFrames() async throws {
        try await withStalledLeaderWriter { writer, channel in
            let firstFrame = try ACPLeaderCodec.encode(ACPLeaderClientMessage.ping)
            let secondFrame = try ACPLeaderCodec.encode(ACPLeaderClientMessage.disconnect)
            let thirdFrame = try ACPLeaderCodec.encode(ACPLeaderClientMessage.acp(payload: "{}"))
            let first = Task { try await writer.write(firstFrame) }
            try await waitForLeaderWriteState { await channel.started.count == 1 }
            let second = Task { try await writer.write(secondFrame) }
            try await waitForLeaderWriteState { await writer.pendingFrameCount() == 2 }
            let third = Task { try await writer.write(thirdFrame) }
            try await waitForLeaderWriteState { await writer.pendingFrameCount() == 3 }
            #expect(await channel.started == [firstFrame])
            #expect(await channel.maximumConcurrentWrites == 1)
            #expect(await channel.releaseFirstWrite())
            try await first.value
            try await second.value
            try await third.value
            #expect(await channel.started == [firstFrame, secondFrame, thirdFrame])
            #expect(await channel.bytes == firstFrame + secondFrame + thirdFrame)
            #expect(await writer.pendingFrameCount() == 0)
            #expect(await channel.maximumConcurrentWrites == 1)
        }
    }

    @Test("cancelling a queued frame removes it without closing another write",
          .timeLimit(.minutes(1)))
    func queuedCancellationPreservesCarrier() async throws {
        try await withStalledLeaderWriter { writer, channel in
            let firstFrame: [UInt8] = [1, 2, 3, 4]
            let lastFrame: [UInt8] = [9, 10, 11, 12]
            let first = Task { try await writer.write(firstFrame) }
            try await waitForLeaderWriteState { await channel.started.count == 1 }
            let cancelled = Task { try await writer.write([5, 6, 7, 8]) }
            try await waitForLeaderWriteState { await writer.pendingFrameCount() == 2 }
            cancelled.cancel()
            #expect(await leaderWriteFailure(cancelled) is CancellationError)
            #expect(await writer.pendingFrameCount() == 1)
            #expect(await !channel.closed)
            let last = Task { try await writer.write(lastFrame) }
            try await waitForLeaderWriteState { await writer.pendingFrameCount() == 2 }
            #expect(await channel.releaseFirstWrite())
            try await first.value
            try await last.value
            #expect(await channel.bytes == firstFrame + lastFrame)
            #expect(await channel.started == [firstFrame, lastFrame])
        }
    }

    @Test("cancelling a partially written frame closes and fails queued frames",
          .timeLimit(.minutes(1)))
    func activeCancellationClosesPartialFrame() async throws {
        try await withStalledLeaderWriter { writer, channel in
            let first = Task { try await writer.write([1, 2, 3, 4]) }
            try await waitForLeaderWriteState { await channel.started.count == 1 }
            let queued = Task { try await writer.write([5, 6, 7, 8]) }
            try await waitForLeaderWriteState { await writer.pendingFrameCount() == 2 }
            first.cancel()
            #expect(await leaderWriteFailure(first) is CancellationError)
            let queuedFailure = await leaderWriteFailure(queued)
            #expect(queuedFailure as? ACPLeaderProtocolError == .connectionClosed)
            await writer.close()
            #expect(await channel.closed)
            #expect(await channel.closeCalls == 1)
            #expect(await channel.activeWrites == 0)
            #expect(await channel.started.count == 1)
            #expect(await writer.pendingFrameCount() == 0)
            do {
                try await writer.write([9, 10])
                Issue.record("a cancelled partial frame left its carrier writable")
            } catch let error as ACPLeaderProtocolError {
                #expect(error == .connectionClosed)
            }
        }
    }

    @Test("close releases the suspended channel write and every waiting sender",
          .timeLimit(.minutes(1)))
    func closeUnblocksEveryWrite() async throws {
        try await withStalledLeaderWriter { writer, channel in
            let first = Task { try await writer.write([1, 2, 3, 4]) }
            try await waitForLeaderWriteState { await channel.started.count == 1 }
            let queued = Task { try await writer.write([5, 6, 7, 8]) }
            try await waitForLeaderWriteState { await writer.pendingFrameCount() == 2 }
            await writer.close()
            let firstFailure = await leaderWriteFailure(first)
            let queuedFailure = await leaderWriteFailure(queued)
            #expect(firstFailure as? ACPLeaderProtocolError == .connectionClosed)
            #expect(queuedFailure as? ACPLeaderProtocolError == .connectionClosed)
            #expect(await channel.activeWrites == 0)
            #expect(await writer.pendingFrameCount() == 0)
            #expect(await channel.started.count == 1)
            await writer.close()
            #expect(await channel.closeCalls == 1)
        }
    }

    @Test("pending frame and byte caps fail explicitly without entering the channel",
          .timeLimit(.minutes(1)))
    func queueBoundsIncludeActiveFrame() async throws {
        try await withStalledLeaderWriter(
            maximumPendingFrames: 2,
            maximumPendingBytes: 16
        ) { writer, channel in
            let first = Task { try await writer.write([1, 2, 3, 4]) }
            try await waitForLeaderWriteState { await channel.started.count == 1 }
            let queued = Task { try await writer.write([5, 6, 7, 8]) }
            try await waitForLeaderWriteState { await writer.pendingFrameCount() == 2 }
            let expected = ACPLeaderFrameWriterError.queueLimitExceeded(
                maximumFrames: 2, maximumBytes: 16
            )
            do {
                try await writer.write([9])
                Issue.record("pending frame limit was not enforced")
            } catch let error as ACPLeaderFrameWriterError {
                #expect(error == expected)
            }
            queued.cancel()
            #expect(await leaderWriteFailure(queued) is CancellationError)
            do {
                try await writer.write(Array(repeating: 9, count: 13))
                Issue.record("pending byte limit did not include the active frame")
            } catch let error as ACPLeaderFrameWriterError {
                #expect(error == expected)
            }
            #expect(await writer.pendingFrameCount() == 1)
            #expect(await channel.started.count == 1)
            #expect(await channel.releaseFirstWrite())
            try await first.value
            try await writer.write(Array(repeating: 10, count: 16))
            #expect(await channel.started.count == 2)
            #expect(await writer.pendingFrameCount() == 0)
        }
    }
}
