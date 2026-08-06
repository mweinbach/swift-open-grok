import Foundation
import OpenGrokACP
import OpenGrokACPRuntime
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
