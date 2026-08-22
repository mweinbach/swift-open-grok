import Foundation
import OpenGrokShared
import Testing

@testable import OpenGrokCodeModeProtocol

@Suite("Nested Code Mode tool progress protocol")
struct NestedToolProgressProtocolTests {
    @Test("progress chunks preserve structured payloads and explicit JSON null")
    func progressWireShape() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let structured = NestedToolProgress.withPayload(
            "output",
            .object(["step": .number(.int64(2))])
        )
        let structuredJSON = try #require(String(
            data: try encoder.encode(structured),
            encoding: .utf8
        ))
        #expect(structuredJSON == #"{"payload":{"step":2},"text":"output"}"#)
        #expect(try JSONDecoder().decode(NestedToolProgress.self, from: encoder.encode(structured)) == structured)

        let plain = NestedToolProgress.text("plain")
        let plainJSON = try #require(String(data: try encoder.encode(plain), encoding: .utf8))
        #expect(plainJSON == #"{"payload":null,"text":"plain"}"#)
        #expect(try JSONDecoder().decode(NestedToolProgress.self, from: Data(#"{"text":"plain"}"#.utf8)) == plain)
    }

    @Test("queued chunks are delivered in FIFO order")
    func fifoOrder() {
        let (sink, receiver) = nestedToolProgressChannel()
        sink.push(.text("first"))
        sink.push(.text("second"))

        #expect(receiver.tryReceive() == .text("first"))
        #expect(receiver.tryReceive() == .text("second"))
        #expect(receiver.tryReceive() == nil)
    }

    @Test("a full queue drops its oldest chunk and counts every drop")
    func boundedDropOldest() {
        let (sink, receiver) = nestedToolProgressChannel()
        for index in 0..<(NESTED_TOOL_PROGRESS_CAPACITY + 3) {
            sink.push(.text("chunk-\(index)"))
        }

        #expect(sink.droppedChunks == 3)
        for index in 3..<(NESTED_TOOL_PROGRESS_CAPACITY + 3) {
            #expect(receiver.tryReceive() == .text("chunk-\(index)"))
        }
        #expect(receiver.tryReceive() == nil)
    }

    @Test("an async receiver wakes for the next producer push")
    func asyncReceiverWakesForPush() async {
        let (sink, receiver) = nestedToolProgressChannel()
        let waiting = Task { await receiver.receive() }
        await Task.yield()
        sink.push(.withPayload("ready", .object(["ok": .bool(true)])))

        #expect(await waiting.value == .withPayload("ready", .object(["ok": .bool(true)])))
    }

    @Test("closing preserves queued chunks and refuses every later push")
    func closePreservesOnlyQueuedProgress() async {
        let (sink, receiver) = nestedToolProgressChannel()
        sink.push(.text("queued"))
        receiver.close()

        #expect(sink.isClosed)
        #expect(receiver.isClosed)
        #expect(await receiver.receive() == .text("queued"))
        #expect(await receiver.receive() == nil)
        sink.push(.text("late"))
        #expect(receiver.tryReceive() == nil)
    }

    @Test("closing wakes an already-suspended receiver")
    func closeWakesWaitingReceiver() async {
        let (sink, receiver) = nestedToolProgressChannel()
        let waiting = Task { await receiver.receive() }
        await Task.yield()
        receiver.close()

        #expect(await waiting.value == nil)
        #expect(sink.isClosed)
    }

    @Test("dropping the receiver closes every retained producer")
    func droppingReceiverClosesProducer() {
        var retainedSink: NestedToolProgressSink?
        do {
            let channel = nestedToolProgressChannel()
            retainedSink = channel.sink
            #expect(!channel.sink.isClosed)
        }

        #expect(retainedSink?.isClosed == true)
        retainedSink?.push(.text("ignored"))
        #expect(retainedSink?.droppedChunks == 0)
        retainedSink = nil
    }

    @Test("dropping the last producer closes the receiver")
    func droppingLastProducerClosesReceiver() async {
        var retainedSink: NestedToolProgressSink?
        let receiver: NestedToolProgressReceiver
        do {
            let channel = nestedToolProgressChannel()
            retainedSink = channel.sink
            receiver = channel.receiver
        }
        #expect(!receiver.isClosed)
        #expect(retainedSink != nil)
        retainedSink = nil

        #expect(receiver.isClosed)
        #expect(await receiver.receive() == nil)
    }

    @Test("cancelling one suspended receive does not close its channel")
    func cancellingReceiveLeavesChannelUsable() async {
        let (sink, receiver) = nestedToolProgressChannel()
        let waiting = Task { await receiver.receive() }
        await Task.yield()
        waiting.cancel()
        #expect(await waiting.value == nil)

        #expect(!sink.isClosed)
        sink.push(.text("next"))
        #expect(await receiver.receive() == .text("next"))
    }

    @Test("exec description advertises progress and the current 30-second default")
    func execDescriptionAdvertisesProgress() {
        let description = buildExecToolDescription(
            enabledTools: [],
            deferredTools: [],
            namespaceDescriptions: [:],
            codeModeOnly: false
        )

        #expect(description.contains("onProgress(handler)"))
        #expect(description.contains("oldest queued chunks are dropped"))
        #expect(description.contains("Defaults to 30000 ms."))
    }
}
