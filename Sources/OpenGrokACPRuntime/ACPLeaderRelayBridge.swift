import Foundation
import OpenGrokHTTP

/// Give each authenticated relay connection the same registered carrier
/// identity, request namespace, and session authority as a local IPC client.
/// The shared runtime keeps its leader-owned sinks across relay reconnects.
///
/// Rust pin `00e176c8fb4035701c24199bf9225973c1b13c20`,
/// `xai-grok-shell/src/agent/app.rs:1259-1307`, keeps separate IPC/relay
/// channels to one agent and mirrors its output to both. This port instead
/// applies the leader's owner-scoped routing to the relay too. Cost: remote
/// clients must explicitly attach to sessions; a reconnect does not inherit
/// its predecessor's driver identity or receive unscoped output mirroring.
public struct ACPLeaderRelayBridge: Sendable {
    private let host: ACPLeaderIPCHost
    private let log: @Sendable (String) -> Void

    public init(
        host: ACPLeaderIPCHost,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.host = host
        self.log = log
    }

    public func serve(_ transport: any ACPTransport) async {
        let channel = InMemoryWebSocketChannel.makePair()
        let client = ACPLeaderClient(
            channel: channel.a,
            clientType: "grok-relay",
            mode: .headless
        )
        let serving = Task { await host.serve(channel: channel.b) }

        await withTaskCancellationHandler {
            do {
                let registration = try await client.start()
                guard registration.ready else {
                    throw ACPLeaderClientError.registrationClosed
                }
                let events = try await client.events()
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        do {
                            while !Task.isCancelled {
                                let message = try await transport.receive()
                                try await client.forward(message)
                            }
                        } catch {
                            // Closing either leg must unblock the other read
                            // before the structured task group can join it.
                        }
                        await client.close()
                        await transport.close()
                    }
                    group.addTask {
                        do {
                            for try await message in events {
                                try await transport.send(message)
                            }
                        } catch {
                            // A leader shutdown and a dropped relay both end
                            // only this registered carrier, not its runtime.
                        }
                        await client.close()
                        await transport.close()
                    }
                    await group.waitForAll()
                }
            } catch {
                log("relay: leader carrier registration failed: \(error)")
            }
            await client.close()
            await transport.close()
            await serving.value
        } onCancel: {
            Task {
                await client.close()
                await transport.close()
            }
        }
    }
}
