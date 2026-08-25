#if os(Windows)

import Foundation
import Testing

@testable import OpenGrokHTTP

@Suite("Windows named-pipe cooperative-executor isolation", .serialized)
struct WindowsNamedPipeControlParityTests {
    @Test("registration and control acknowledgements progress beside blocked accepts and reads", .timeLimit(.minutes(1)))
    func nativeControlAcknowledgementDoesNotStarve() async throws {
        let path = "C:\\opengrok-pipe-parity\\\(UUID().uuidString)\\leader.sock"
        let name = WindowsNamedPipeName.fullName(forPath: path)
        let listener = WindowsNamedPipeListener(pipeName: name)
        try listener.start()
        defer { listener.close() }

        let server = Task {
            let channel = try await listener.accept()
            let blockedAccept = Task {
                try await listener.accept()
            }
            defer {
                blockedAccept.cancel()
                listener.close()
            }

            let registration = try #require(try await channel.read())
            #expect(String(decoding: registration, as: UTF8.self) == "register:grok-pager-update")
            try await channel.write(Array("registered:1.0.0".utf8))

            let control = try #require(try await channel.read())
            #expect(String(decoding: control, as: UTF8.self) == "relaunch_for_update:2.0.0")
            try await channel.write(Array("relaunching:1.0.0:2.0.0:10000".utf8))

            let completion = try #require(try await channel.read())
            #expect(String(decoding: completion, as: UTF8.self) == "acknowledged")
            await channel.close()
        }

        let client = try await WindowsNamedPipeDialer.connect(
            pipeName: name,
            timeoutSeconds: 2
        )
        try await client.write(Array("register:grok-pager-update".utf8))
        let registered = try #require(try await client.read())
        #expect(String(decoding: registered, as: UTF8.self) == "registered:1.0.0")

        let blockedControlReply = Task {
            try await client.read()
        }
        for _ in 0..<8 {
            await Task.yield()
        }

        let started = ContinuousClock.now
        try await client.write(Array("relaunch_for_update:2.0.0".utf8))
        let acknowledgement = try #require(try await blockedControlReply.value)
        #expect(String(decoding: acknowledgement, as: UTF8.self)
            == "relaunching:1.0.0:2.0.0:10000")
        #expect(started.duration(to: .now) < .seconds(2))

        try await client.write(Array("acknowledged".utf8))
        try await server.value
        await client.close()
    }

    @Test("closing a listener interrupts a native worker parked inside ConnectNamedPipe", .timeLimit(.minutes(1)))
    func closingListenerInterruptsBlockedAccept() async throws {
        let path = "C:\\opengrok-pipe-close\\\(UUID().uuidString)\\leader.sock"
        let listener = WindowsNamedPipeListener(
            pipeName: WindowsNamedPipeName.fullName(forPath: path)
        )
        try listener.start()

        let pending = Task {
            try await listener.accept()
        }
        for _ in 0..<8 {
            await Task.yield()
        }
        listener.close()

        do {
            let unexpected = try await pending.value
            await unexpected.close()
            Issue.record("a closed named-pipe listener unexpectedly accepted a client")
        } catch {
            #expect(error is WindowsNamedPipeError)
        }
    }

    @Test("repeated parked accepts stop without blocking the native listener owner", .timeLimit(.minutes(1)))
    func repeatedBlockedAcceptTeardownIsBounded() async throws {
        for index in 0..<20 {
            let path = "C:\\opengrok-pipe-repeated-close\\\(UUID().uuidString)\\\(index).sock"
            let listener = WindowsNamedPipeListener(
                pipeName: WindowsNamedPipeName.fullName(forPath: path)
            )
            try listener.start()
            let pending = Task {
                try await listener.accept()
            }
            for _ in 0..<8 {
                await Task.yield()
            }

            let started = ContinuousClock.now
            listener.close()
            do {
                let unexpected = try await pending.value
                await unexpected.close()
                Issue.record("closed listener unexpectedly accepted a client on iteration \(index)")
            } catch {
                #expect(error is WindowsNamedPipeError)
            }
            #expect(started.duration(to: .now) < .seconds(1))
        }
    }

    @Test("repeated native pipe connections restore blocking ping and acknowledgement semantics", .timeLimit(.minutes(1)))
    func repeatedNativePingAcknowledgementsPreserveBlockingMode() async throws {
        let path = "C:\\opengrok-pipe-ping\\\(UUID().uuidString)\\leader.sock"
        let name = WindowsNamedPipeName.fullName(forPath: path)
        let listener = WindowsNamedPipeListener(pipeName: name)
        try listener.start()
        defer { listener.close() }

        for index in 0..<12 {
            let accepting = Task {
                try await listener.accept()
            }
            let client = try await WindowsNamedPipeDialer.connect(
                pipeName: name,
                timeoutSeconds: 2
            )
            let server = try await accepting.value
            let ping = "ping-\(index)"
            let acknowledgement = "ack-\(index)"

            let reading = Task {
                try #require(try await server.read())
            }
            for _ in 0..<4 {
                await Task.yield()
            }
            try await client.write(Array(ping.utf8))
            #expect(String(decoding: try await reading.value, as: UTF8.self) == ping)

            let reply = Task {
                try #require(try await client.read())
            }
            try await server.write(Array(acknowledgement.utf8))
            #expect(String(decoding: try await reply.value, as: UTF8.self) == acknowledgement)

            await server.close()
            await client.close()
        }
    }
}

#endif
