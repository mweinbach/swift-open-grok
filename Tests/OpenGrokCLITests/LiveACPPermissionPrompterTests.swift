// LiveACPPermissionPrompterTests.swift
//
// Assert through the live permission seam: a gated tool prepare under an ACP
// prompter must issue `session/request_permission`, and the client's answer
// must change `mayDispatch`. Composition-only / broker-only coverage is
// intentionally insufficient (AGENTS.md §3).

import Foundation
import OpenGrokACP
import OpenGrokACPRuntime
import OpenGrokFileTools
import OpenGrokShared
import OpenGrokWorkspace
import Testing
@testable import OpenGrokCLI

private actor FakeACPPermissionClient: ACPPermissionReverseClient {
    enum Behavior: Sendable {
        case respond(RequestPermissionResponse)
        case throwTransport(String)
        case hang
    }

    private let behavior: Behavior
    private(set) var methods: [String] = []
    private(set) var params: [JSONValue] = []

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func requestClient(method: String, params: JSONValue) async throws -> JSONValue {
        methods.append(method)
        self.params.append(params)
        switch behavior {
        case .respond(let response):
            return try JSONValue.encode(response)
        case .throwTransport(let message):
            throw ACPRuntimeError.transport(message)
        case .hang:
            try await Task.sleep(nanoseconds: 60_000_000_000)
            throw ACPRuntimeError.transport("hang ended")
        }
    }

    func recordedMethods() -> [String] { methods }

    func lastRequest() throws -> RequestPermissionRequest? {
        guard let last = params.last else { return nil }
        return try last.decode(RequestPermissionRequest.self)
    }
}

private func makePipeline(
    prompter: LiveACPPermissionPrompter,
    workspaceRoot: String = "/work"
) -> PermissionPipeline {
    FileToolSession.makePipeline(
        policy: .prompt(prompter),
        workspaceRoot: workspaceRoot,
        resolved: ResolvedPermissions(
            config: PermissionConfig(
                rules: [PermissionRule(action: .ask, tool: .edit, source: .synthetic)],
                promptPolicy: .ask
            ),
            alwaysApprove: false
        )
    )
}

private func editRequest(path: String = "/work/a.swift") -> PrepareToolAccessRequest {
    PrepareToolAccessRequest(
        access: .edit(path),
        toolName: "search_replace",
        toolCallId: "tc-acp-1"
    )
}

private func selected(_ optionId: String) -> RequestPermissionResponse {
    RequestPermissionResponse(
        outcome: .selected(SelectedPermissionOutcome(optionId: PermissionOptionId(optionId)))
    )
}

@Suite("ACP reverse permission bridge")
struct LiveACPPermissionPrompterTests {
    @Test("client allow → mayDispatch true and issues session/request_permission")
    func clientAllowMayDispatch() async throws {
        let client = FakeACPPermissionClient(behavior: .respond(selected("allow-once")))
        let prompter = LiveACPPermissionPrompter(
            client: client,
            sessionId: AcpSessionId("sess-allow"),
            timeoutSeconds: 5
        )
        let pipeline = makePipeline(prompter: prompter)

        let prepared = await pipeline.prepare(editRequest())
        #expect(prepared.mayDispatch)
        #expect(prepared.decision == .allow)

        let methods = await client.recordedMethods()
        #expect(methods == [ClientMethodNames.sessionRequestPermission])
        let request = try await client.lastRequest()
        #expect(request?.sessionId == AcpSessionId("sess-allow"))
        #expect(request?.toolCall.toolCallId.rawValue == "tc-acp-1")
        #expect(request?.options.contains { $0.optionId.rawValue == "allow-once" } == true)
    }

    @Test("client reject → mayDispatch false")
    func clientRejectDeniesDispatch() async throws {
        let client = FakeACPPermissionClient(behavior: .respond(selected("reject-once")))
        let prompter = LiveACPPermissionPrompter(
            client: client,
            sessionId: AcpSessionId("sess-reject"),
            timeoutSeconds: 5
        )
        let pipeline = makePipeline(prompter: prompter)

        let prepared = await pipeline.prepare(editRequest())
        #expect(prepared.mayDispatch == false)
        guard case .reject = prepared.decision else {
            Issue.record("expected reject, got \(prepared.decision)")
            return
        }
        let methods = await client.recordedMethods()
        #expect(methods == [ClientMethodNames.sessionRequestPermission])
    }

    @Test("client cancel → mayDispatch false")
    func clientCancelDeniesDispatch() async throws {
        let client = FakeACPPermissionClient(
            behavior: .respond(RequestPermissionResponse(outcome: .cancelled))
        )
        let prompter = LiveACPPermissionPrompter(
            client: client,
            sessionId: AcpSessionId("sess-cancel"),
            timeoutSeconds: 5
        )
        let pipeline = makePipeline(prompter: prompter)

        let prepared = await pipeline.prepare(editRequest())
        #expect(prepared.mayDispatch == false)
        #expect(prepared.decision == .cancelled)
        let methods = await client.recordedMethods()
        #expect(methods == [ClientMethodNames.sessionRequestPermission])
    }

    @Test("no reverse sender → denied without allow")
    func noReverseSenderDenies() async throws {
        let prompter = LiveACPPermissionPrompter(
            client: nil,
            sessionId: AcpSessionId("sess-none"),
            timeoutSeconds: 5
        )
        let pipeline = makePipeline(prompter: prompter)

        let prepared = await pipeline.prepare(editRequest())
        #expect(prepared.mayDispatch == false)
        guard case .reject(let reason) = prepared.decision else {
            Issue.record("expected reject, got \(prepared.decision)")
            return
        }
        #expect(reason.contains("no approval prompt") || reason.contains("disabled for this session"))
    }

    @Test("transport throw → denied")
    func transportThrowDenies() async throws {
        let client = FakeACPPermissionClient(
            behavior: .throwTransport("no ACP client is connected")
        )
        let prompter = LiveACPPermissionPrompter(
            client: client,
            sessionId: AcpSessionId("sess-transport"),
            timeoutSeconds: 5
        )
        let pipeline = makePipeline(prompter: prompter)

        let prepared = await pipeline.prepare(editRequest())
        #expect(prepared.mayDispatch == false)
        guard case .reject(let reason) = prepared.decision else {
            Issue.record("expected reject, got \(prepared.decision)")
            return
        }
        #expect(reason.contains("failed to request permission"))
        let methods = await client.recordedMethods()
        #expect(methods == [ClientMethodNames.sessionRequestPermission])
    }

    @Test("timeout → denied")
    func timeoutDenies() async throws {
        let client = FakeACPPermissionClient(behavior: .hang)
        let prompter = LiveACPPermissionPrompter(
            client: client,
            sessionId: AcpSessionId("sess-timeout"),
            timeoutSeconds: 0.04
        )
        let pipeline = makePipeline(prompter: prompter)

        let prepared = await pipeline.prepare(editRequest())
        #expect(prepared.mayDispatch == false)
        guard case .reject(let reason) = prepared.decision else {
            Issue.record("expected reject, got \(prepared.decision)")
            return
        }
        #expect(reason.contains("timed out"))
        let methods = await client.recordedMethods()
        #expect(methods == [ClientMethodNames.sessionRequestPermission])
    }

    @Test("unknown option id → denied")
    func unknownOptionIdDenies() async throws {
        let client = FakeACPPermissionClient(behavior: .respond(selected("not-a-real-option")))
        let prompter = LiveACPPermissionPrompter(
            client: client,
            sessionId: AcpSessionId("sess-unknown"),
            timeoutSeconds: 5
        )
        let pipeline = makePipeline(prompter: prompter)

        let prepared = await pipeline.prepare(editRequest())
        #expect(prepared.mayDispatch == false)
        guard case .reject(let reason) = prepared.decision else {
            Issue.record("expected reject, got \(prepared.decision)")
            return
        }
        #expect(reason.contains("unknown permission option"))
    }

    @Test("PermissionHandle.request allow/reject through the same prompter")
    func permissionHandleLiveSeam() async throws {
        let allowClient = FakeACPPermissionClient(behavior: .respond(selected("allow-once")))
        let allowPrompter = LiveACPPermissionPrompter(
            client: allowClient,
            sessionId: AcpSessionId("sess-handle"),
            timeoutSeconds: 5
        )
        let allowHandle = PermissionHandle(
            config: PermissionConfig(promptPolicy: .ask),
            shellCwd: "/work",
            prompter: allowPrompter,
            classifier: nil
        )
        let allowDecision = await allowHandle.request(
            access: .edit("/work/a.swift"),
            toolName: "search_replace",
            toolCallId: "tc-h1"
        )
        #expect(allowDecision == .allow)
        #expect(allowDecision.isAllow)
        let allowMethods = await allowClient.recordedMethods()
        #expect(allowMethods == [ClientMethodNames.sessionRequestPermission])

        let rejectClient = FakeACPPermissionClient(behavior: .respond(selected("reject-once")))
        let rejectPrompter = LiveACPPermissionPrompter(
            client: rejectClient,
            sessionId: AcpSessionId("sess-handle-2"),
            timeoutSeconds: 5
        )
        let rejectHandle = PermissionHandle(
            config: PermissionConfig(promptPolicy: .ask),
            shellCwd: "/work",
            prompter: rejectPrompter,
            classifier: nil
        )
        let rejectDecision = await rejectHandle.request(
            access: .edit("/work/a.swift"),
            toolName: "search_replace",
            toolCallId: "tc-h2"
        )
        #expect(rejectDecision.isAllow == false)
        guard case .reject = rejectDecision else {
            Issue.record("expected reject, got \(rejectDecision)")
            return
        }
    }
}
