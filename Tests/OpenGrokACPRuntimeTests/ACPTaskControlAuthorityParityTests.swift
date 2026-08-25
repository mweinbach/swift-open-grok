import Foundation
import OpenGrokACP
import OpenGrokShared
import Testing

@testable import OpenGrokACPRuntime

private actor ACPDeniedTaskControlHandler: ACPAgentExtensionHandler {
    private var invocations: [String] = []

    func handle(method: String, params: JSONValue) async throws -> JSONValue {
        invocations.append(method)
        return .object([
            "executed": .bool(true),
            "method": .string(method),
            "params": params,
        ])
    }

    func invocationCount() -> Int {
        invocations.count
    }
}

@Suite("ACP task-control carrier and leader authority")
struct ACPTaskControlAuthorityParityTests {
    @Test("denied subagent controls conceal children without invoking their handlers")
    func deniedSubagentControlsNeverInvokeHandlers() async throws {
        let handler = ACPDeniedTaskControlHandler()
        let router = ACPExtensionMethodRouter()
            .register(exact: "x.ai/subagent/cancel", handler: handler)
            .register(exact: "x.ai/subagent/get", handler: handler)
            .register(exact: "x.ai/custom/mutate", handler: handler)
        let runtime = ACPAgentRuntime(
            extensionRouter: router,
            makeSessionId: { "owner-session" }
        )
        await runtime.setReverseSender { _ in }
        await runtime.setSessionOwnerVerifier { sessionID, clientID in
            sessionID.rawValue == "owner-session" && clientID == "owner-driver"
        }
        try await openOwnerSession(runtime)

        let deniedCancel = await request(
            runtime,
            clientID: "foreign-subscriber",
            id: 3,
            method: "x.ai/subagent/cancel",
            params: .object([
                "subagentId": .string("private-child"),
                "_meta": .object([
                    "x.ai/leaderClientId": .string("owner-driver")
                ]),
            ])
        )
        guard case .response(_, let cancel?, nil)? = deniedCancel.last else {
            Issue.record("denied cancel did not produce its hidden upstream response")
            await runtime.close()
            return
        }
        #expect(cancel == .object([
            "result": .object([
                "subagentId": .string("private-child"),
                "cancelled": .bool(false),
                "outcome": .object(["kind": .string("not_found")]),
            ])
        ]))
        #expect(await handler.invocationCount() == 0)

        let deniedRead = await request(
            runtime,
            clientID: "foreign-subscriber",
            id: 4,
            method: "x.ai/subagent/get",
            params: .object([
                "sessionId": .string("owner-session"),
                "subagentId": .string("private-child"),
            ])
        )
        guard case .response(_, let snapshot?, nil)? = deniedRead.last else {
            Issue.record("denied read did not conceal the private child")
            await runtime.close()
            return
        }
        #expect(snapshot == .object([
            "result": .object(["snapshot": .null])
        ]))
        #expect(await handler.invocationCount() == 0)

        let deniedGeneric = await request(
            runtime,
            clientID: "foreign-subscriber",
            id: 5,
            method: "x.ai/custom/mutate",
            params: .object(["subagentId": .string("private-child")])
        )
        guard case .response(_, nil, _?)? = deniedGeneric.last else {
            Issue.record("generic denied methods must retain the authentication error")
            await runtime.close()
            return
        }
        #expect(await handler.invocationCount() == 0)

        let authorized = await request(
            runtime,
            clientID: "owner-driver",
            id: 6,
            method: "x.ai/subagent/get",
            params: .object(["subagentId": .string("private-child")])
        )
        guard case .response(_, let executed?, nil)? = authorized.last else {
            Issue.record("the authenticated owner could not reach its registered handler")
            await runtime.close()
            return
        }
        #expect(executed["executed"]?.boolValue == true)
        #expect(await handler.invocationCount() == 1)
        await runtime.close()
    }

    @Test("carrier-bound ownership revokes authority without changing direct-runtime queries")
    func connectedSessionOwnershipFailsClosedOnDisconnect() async throws {
        let gateway = ACPNotificationGateway()
        let runtime = ACPAgentRuntime(makeSessionId: { "owner-session" })
        await gateway.attach(runtime)
        try await openOwnerSession(runtime)

        let sessionID = AcpSessionId("owner-session")
        #expect(await gateway.ownsSession(sessionID))
        #expect(await gateway.ownsConnectedSession(sessionID) == false)

        await runtime.setReverseSender { _ in }
        #expect(await gateway.ownsSession(sessionID))
        #expect(await gateway.ownsConnectedSession(sessionID))

        await runtime.setReverseSender(nil)
        #expect(await gateway.ownsSession(sessionID))
        #expect(await gateway.ownsConnectedSession(sessionID) == false)
        await runtime.close()
    }

    private func openOwnerSession(_ runtime: ACPAgentRuntime) async throws {
        let initialization = await request(
            runtime,
            clientID: "owner-driver",
            id: 1,
            method: AgentMethodNames.initialize,
            params: try JSONValue.encode(InitializeRequest(protocolVersion: .v1))
        )
        guard case .response(_, _?, nil)? = initialization.last else {
            throw ACPRuntimeError.transport("test runtime could not initialize")
        }

        let opened = await request(
            runtime,
            clientID: "owner-driver",
            id: 2,
            method: AgentMethodNames.sessionNew,
            params: .object([
                "cwd": .string(FileManager.default.temporaryDirectory.path),
                "mcpServers": .array([]),
            ])
        )
        guard case .response(_, let payload?, nil)? = opened.last,
              payload["sessionId"]?.stringValue == "owner-session"
        else {
            throw ACPRuntimeError.transport("test runtime could not open its owner session")
        }
    }

    private func request(
        _ runtime: ACPAgentRuntime,
        clientID: String,
        id: Int64,
        method: String,
        params: JSONValue
    ) async -> [ACPMessage] {
        await ACPLeaderRequestAuthority.$clientID.withValue(clientID) {
            await runtime.handle(.request(
                id: .number(id),
                method: method,
                params: params
            ))
        }
    }
}
