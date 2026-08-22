import Foundation
import OpenGrokAgentControlTools
import OpenGrokFileTools
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase
import OpenGrokToolRegistry
import Testing

@testable import OpenGrokCLI

private enum FixtureSessionBusError: Error, CustomStringConvertible {
    case disabled

    var description: String { "session_bus_disabled: the session bus is disabled" }
}

private actor FixtureSessionBusBackend: SessionCollaborationBackend {
    let enabled: Bool
    private(set) var listCalls = 0
    private(set) var readCalls: [(sessionID: String, maxUpdates: Int)] = []
    private(set) var messages: [(sessionID: String, message: String)] = []
    private var messageStatus: MessageSessionStatus = .accepted

    init(enabled: Bool = true) {
        self.enabled = enabled
    }

    func setMessageStatus(_ status: MessageSessionStatus) {
        messageStatus = status
    }

    func listSessions() async throws -> ListSessionsOutput {
        listCalls += 1
        guard enabled else { return ListSessionsOutput(busEnabled: false, sessions: []) }
        return ListSessionsOutput(busEnabled: true, sessions: [
            LiveSessionEntry(
                sessionID: "session-self",
                cwd: "/tmp/project",
                projectName: "project",
                modelID: "grok-4",
                status: "idle",
                isSelf: true
            ),
            LiveSessionEntry(
                sessionID: "session-peer",
                cwd: "/tmp/other",
                projectName: "other",
                title: "Other session",
                status: "busy",
                isSelf: false
            ),
        ])
    }

    func readSession(sessionID: String, maxUpdates: Int) async throws -> ReadSessionOutput {
        guard enabled else { throw FixtureSessionBusError.disabled }
        readCalls.append((sessionID: sessionID, maxUpdates: maxUpdates))
        return ReadSessionOutput(
            sessionID: sessionID,
            title: "Other session",
            live: true,
            updates: [
                SessionCollaborationTranscriptEntry(role: "user", text: "Inspect the build"),
                SessionCollaborationTranscriptEntry(role: "agent", text: "Reviewing"),
            ]
        )
    }

    func messageSession(
        sessionID: String,
        message: String
    ) async throws -> MessageSessionStatus {
        guard enabled else { throw FixtureSessionBusError.disabled }
        messages.append((sessionID: sessionID, message: message))
        return messageStatus
    }
}

private actor FixtureDynamicMCPProvider: MCPToolProviding {
    nonisolated let serverName: String
    private(set) var calls: [JSONValue] = []
    let toolName: String

    init(serverName: String = "dynamic", toolName: String = "echo") {
        self.serverName = serverName
        self.toolName = toolName
    }

    func listBridgedTools() async throws -> [MCPBridgedTool] {
        [MCPBridgedTool(
            name: toolName,
            description: "Dynamically connected echo tool.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "text": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("text")]),
            ])
        )]
    }

    func callBridgedTool(
        name: String,
        arguments: JSONValue
    ) async throws -> MCPBridgedCallResult {
        calls.append(arguments)
        return MCPBridgedCallResult(text: "echo: \(arguments["text"]?.stringValue ?? "")")
    }
}

private struct SessionCollaborationExecutorFixture {
    let root: URL
    let environment: [String: String]
    let processBackend: LocalShellProcessBackend

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-session-collaboration-\(UUID().uuidString)")
        root = base.appendingPathComponent("workspace", isDirectory: true)
        let home = base.appendingPathComponent("home", isDirectory: true)
        let openGrokHome = home.appendingPathComponent(".opengrok", isDirectory: true)
        for directory in [root, home, openGrokHome] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        environment = [
            "HOME": home.path,
            "OPENGROK_HOME": openGrokHome.path,
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        ]
        processBackend = LocalShellProcessBackend(inheritedEnvironment: environment)
    }

    func executor(
        bus: (any SessionCollaborationBackend)? = nil,
        policy: LiveAgentToolPolicy? = nil,
        permissions: CLIPermissionOptions = CLIPermissionOptions()
    ) async throws -> LiveToolExecutor {
        try await LiveToolExecutor(
            processBackend: processBackend,
            sessionID: "session-self",
            workingDirectory: root,
            toolPolicy: policy,
            telemetryBootstrapContext: .empty,
            fileAccessPolicy: .allowAll,
            environment: environment,
            permissionOptions: permissions,
            sessionCollaborationBackend: bus
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }
}

private func collaborationCall(
    _ name: String,
    arguments: String = "{}"
) -> ToolCall {
    ToolCall(id: "call-\(UUID().uuidString)", name: name, arguments: arguments)
}

@Suite("Live cross-process session collaboration tools", .serialized)
struct LiveSessionCollaborationToolTests {
    @Test("tools are absent and undispatchable without an actual session-bus backend")
    func absentWithoutRealBackend() async throws {
        let fixture = try SessionCollaborationExecutorFixture()
        defer { fixture.cleanup() }
        let executor = try await fixture.executor()
        defer { Task { await executor.shutdown() } }

        for name in ["list_sessions", "read_session", "message_session"] {
            #expect(!executor.tools.contains { $0.name == name })
            let outcome = await executor.invoke(
                sessionID: "session-self",
                workingDirectory: fixture.root,
                call: collaborationCall(name)
            )
            guard case .failure(let error) = outcome else {
                Issue.record("unbacked \(name) unexpectedly dispatched")
                continue
            }
            #expect(error.description.contains("unknown tool"))
        }
    }

    @Test("a real backend advertises strict tools independently of the subagent mailbox")
    func backendAdvertisesThreeTools() async throws {
        let fixture = try SessionCollaborationExecutorFixture()
        defer { fixture.cleanup() }
        let executor = try await fixture.executor(bus: FixtureSessionBusBackend())
        defer { Task { await executor.shutdown() } }

        let specs = Dictionary(uniqueKeysWithValues: executor.tools.map { ($0.name, $0) })
        for tool in SessionCollaborationTool.allCases {
            #expect(specs[tool.rawValue]?.description == tool.descriptionTemplate)
            #expect(specs[tool.rawValue]?.parameters
                == SessionCollaborationToolSurface.inputSchema(for: tool))
        }
        #expect(specs["list_agents"] == nil)
        #expect(specs["read_session"]?.parameters["additionalProperties"] == .bool(false))
        #expect(specs["message_session"]?.parameters["additionalProperties"] == .bool(false))
    }

    @Test("all three session tools remain directly model-facing in Code Mode Only")
    func toolsAreDirectOnlyInCodeMode() async throws {
        let fixture = try SessionCollaborationExecutorFixture()
        defer { fixture.cleanup() }
        let executor = try await fixture.executor(bus: FixtureSessionBusBackend())
        defer { Task { await executor.shutdown() } }

        let surface = LiveCodeModeToolSurface(mode: .codeModeOnly, baseTools: executor.currentToolSpecs())
        let names = Set(surface.modelTools.map(\.name))
        for tool in SessionCollaborationTool.allCases {
            #expect(names.contains(tool.rawValue))
            #expect(isLiveCodeModeDirectOnlyTool(tool.rawValue))
            #expect(!surface.snapshot.tools.contains { $0.name == tool.rawValue })
        }
    }

    @Test("session-collaboration prompt text matches serde declaration order")
    func prettyOutputDeclarationOrder() {
        let listed = serdeListSessionsJSON(ListSessionsOutput(busEnabled: false, sessions: []))
        #expect(listed == """
        {
          "bus_enabled": false,
          "sessions": []
        }
        """)

        let read = serdeReadSessionJSON(ReadSessionOutput(
            sessionID: "peer",
            live: true,
            updates: [SessionCollaborationTranscriptEntry(role: "peer", text: "line\nnext")]
        ))
        #expect(read == """
        {
          "session_id": "peer",
          "live": true,
          "updates": [
            {
              "role": "peer",
              "text": "line\\nnext"
            }
          ]
        }
        """)

        let messaged = serdeMessageSessionJSON(MessageSessionOutput(
            targetSessionID: "peer",
            status: .unknownSession
        ))
        #expect(messaged == """
        {
          "target_session_id": "peer",
          "status": "unknown_session"
        }
        """)
    }

    @Test("list_sessions returns typed self and peer entries through the live permission gate")
    func listingReturnsTypedOutput() async throws {
        let fixture = try SessionCollaborationExecutorFixture()
        defer { fixture.cleanup() }
        let backend = FixtureSessionBusBackend()
        let executor = try await fixture.executor(bus: backend)
        defer { Task { await executor.shutdown() } }

        let outcome = await executor.invoke(
            sessionID: "session-self",
            workingDirectory: fixture.root,
            call: collaborationCall("list_sessions", arguments: #"{"unknown":"allowed"}"#)
        )
        guard case .success(let result) = outcome else {
            Issue.record("list_sessions failed: \(outcome)")
            return
        }
        #expect(result.value["bus_enabled"] == .bool(true))
        #expect(result.value["sessions"]?[0]?["is_self"] == .bool(true))
        #expect(result.value["sessions"]?[1]?["status"] == .string("busy"))
        #expect(result.promptText.contains("\"project_name\": \"project\""))
        #expect(await backend.listCalls == 1)
    }

    @Test("disabled real backend keeps tools live and reports disabled truthfully")
    func disabledBackendRemainsBacked() async throws {
        let fixture = try SessionCollaborationExecutorFixture()
        defer { fixture.cleanup() }
        let executor = try await fixture.executor(bus: FixtureSessionBusBackend(enabled: false))
        defer { Task { await executor.shutdown() } }

        let listed = await executor.invoke(
            sessionID: "session-self",
            workingDirectory: fixture.root,
            call: collaborationCall("list_sessions")
        )
        guard case .success(let output) = listed else {
            Issue.record("disabled list should succeed: \(listed)")
            return
        }
        #expect(output.value["bus_enabled"] == .bool(false))
        #expect(output.value["sessions"] == .array([]))

        let read = await executor.invoke(
            sessionID: "session-self",
            workingDirectory: fixture.root,
            call: collaborationCall("read_session", arguments: #"{"session_id":"peer"}"#)
        )
        guard case .failure(let error) = read else {
            Issue.record("disabled read unexpectedly succeeded")
            return
        }
        #expect(error.description.contains("session_bus_disabled"))
    }

    @Test("invalid and unknown read fields never reach the backend")
    func strictReadValidationBeforeDispatch() async throws {
        let fixture = try SessionCollaborationExecutorFixture()
        defer { fixture.cleanup() }
        let backend = FixtureSessionBusBackend()
        let executor = try await fixture.executor(bus: backend)
        defer { Task { await executor.shutdown() } }

        for arguments in [
            #"{"session_id":"  "}"#,
            #"{"session_id":"peer","max_updates":-1}"#,
            #"{"session_id":"peer","invented":true}"#,
        ] {
            let outcome = await executor.invoke(
                sessionID: "session-self",
                workingDirectory: fixture.root,
                call: collaborationCall("read_session", arguments: arguments)
            )
            guard case .failure = outcome else {
                Issue.record("invalid arguments unexpectedly dispatched: \(arguments)")
                continue
            }
        }
        #expect(await backend.readCalls.isEmpty)
    }

    @Test("read defaults and cap are enforced before calling the peer backend")
    func liveReadBounds() async throws {
        let fixture = try SessionCollaborationExecutorFixture()
        defer { fixture.cleanup() }
        let backend = FixtureSessionBusBackend()
        let executor = try await fixture.executor(bus: backend)
        defer { Task { await executor.shutdown() } }

        for arguments in [
            #"{"session_id":" session-peer "}"#,
            #"{"session_id":"session-peer","max_updates":0}"#,
            #"{"session_id":"session-peer","max_updates":999}"#,
        ] {
            let outcome = await executor.invoke(
                sessionID: "session-self",
                workingDirectory: fixture.root,
                call: collaborationCall("read_session", arguments: arguments)
            )
            guard case .success(let output) = outcome else {
                Issue.record("read_session failed: \(outcome)")
                continue
            }
            #expect(output.value["session_id"] == .string("session-peer"))
            #expect(output.value["updates"]?[1]?["role"] == .string("agent"))
        }
        let calls = await backend.readCalls
        #expect(calls.map(\.maxUpdates) == [30, 1, 200])
    }

    @Test("message_session trims, preserves typed unknown verdicts, and enforces byte caps")
    func liveMessageValidationAndDelivery() async throws {
        let fixture = try SessionCollaborationExecutorFixture()
        defer { fixture.cleanup() }
        let backend = FixtureSessionBusBackend()
        await backend.setMessageStatus(.unknownSession)
        let executor = try await fixture.executor(bus: backend)
        defer { Task { await executor.shutdown() } }

        let outcome = await executor.invoke(
            sessionID: "session-self",
            workingDirectory: fixture.root,
            call: collaborationCall(
                "message_session",
                arguments: #"{"session_id":" session-peer ","message":" hi "}"#
            )
        )
        guard case .success(let result) = outcome else {
            Issue.record("message_session failed: \(outcome)")
            return
        }
        #expect(result.value["target_session_id"] == .string("session-peer"))
        #expect(result.value["status"] == .string("unknown_session"))

        let oversized = String(repeating: "x", count: sessionCollaborationMaximumMessageBytes + 1)
        let encoded = try JSONEncoder().encode(JSONValue.object([
            "session_id": .string("session-peer"),
            "message": .string(oversized),
        ]))
        let invalid = await executor.invoke(
            sessionID: "session-self",
            workingDirectory: fixture.root,
            call: collaborationCall(
                "message_session",
                arguments: String(decoding: encoded, as: UTF8.self)
            )
        )
        guard case .failure(let error) = invalid else {
            Issue.record("oversized peer message unexpectedly dispatched")
            return
        }
        #expect(error.description.contains("32768-byte limit"))
        #expect(await backend.messages.count == 1)
    }

    @Test("agent-profile allowlists filter cross-process collaboration tools")
    func profileFiltersSessionTools() async throws {
        let fixture = try SessionCollaborationExecutorFixture()
        defer { fixture.cleanup() }
        let policy = LiveAgentToolPolicy.resolveLaunchPolicy(
            tools: "list_sessions",
            disallowedTools: nil,
            profile: nil
        )
        let executor = try await fixture.executor(bus: FixtureSessionBusBackend(), policy: policy)
        defer { Task { await executor.shutdown() } }

        #expect(executor.tools.contains { $0.name == "list_sessions" })
        #expect(!executor.tools.contains { $0.name == "read_session" })
        #expect(!executor.tools.contains { $0.name == "message_session" })
    }

    @Test("read-only agent capability retains collaboration like upstream")
    func readOnlyProfilesKeepCollaboration() async throws {
        let fixture = try SessionCollaborationExecutorFixture()
        defer { fixture.cleanup() }
        let policy = LiveAgentToolPolicy(unrestrictedWith: .readOnly)
        let executor = try await fixture.executor(bus: FixtureSessionBusBackend(), policy: policy)
        defer { Task { await executor.shutdown() } }

        let names = Set(executor.tools.map(\.name))
        for tool in SessionCollaborationTool.allCases {
            #expect(names.contains(tool.rawValue))
        }
    }
}

@Suite("Live dynamic MCP tool surface", .serialized)
struct LiveDynamicMCPToolSurfaceTests {
    @Test("new MCP tools appear, validate, dispatch through registry, and vanish on removal")
    func addDispatchAndRemove() async throws {
        let fixture = try SessionCollaborationExecutorFixture()
        defer { fixture.cleanup() }
        let executor = try await fixture.executor()
        defer { Task { await executor.shutdown() } }
        let provider = FixtureDynamicMCPProvider()

        #expect(!executor.currentToolSpecs().contains { $0.name == "dynamic__echo" })
        let registration = await MCPToolBridge.register(provider: provider, into: executor.mcpToolset)
        #expect(registration.registeredNames == ["dynamic__echo"])
        #expect(executor.currentToolSpecs().contains { $0.name == "dynamic__echo" })

        let malformed = await executor.invoke(
            sessionID: "session-self",
            workingDirectory: fixture.root,
            call: collaborationCall("dynamic__echo")
        )
        guard case .failure(let validationError) = malformed else {
            Issue.record("missing required MCP field unexpectedly dispatched")
            return
        }
        #expect(validationError.description.contains("text"))
        #expect(await provider.calls.isEmpty)

        let valid = await executor.invoke(
            sessionID: "session-self",
            workingDirectory: fixture.root,
            call: collaborationCall("dynamic__echo", arguments: #"{"text":"hello"}"#)
        )
        guard case .success(let response) = valid else {
            Issue.record("newly added MCP tool was not dispatchable: \(valid)")
            return
        }
        #expect(response.promptText == "echo: hello")
        #expect(await provider.calls.count == 1)

        MCPToolBridge.unregister(server: "dynamic", from: executor.mcpToolset)
        #expect(!executor.currentToolSpecs().contains { $0.name == "dynamic__echo" })
        let removed = await executor.invoke(
            sessionID: "session-self",
            workingDirectory: fixture.root,
            call: collaborationCall("dynamic__echo", arguments: #"{"text":"again"}"#)
        )
        guard case .failure(let removalError) = removed else {
            Issue.record("removed MCP tool unexpectedly remained dispatchable")
            return
        }
        #expect(removalError.description.contains("unknown tool"))
        #expect(await provider.calls.count == 1)
    }

    @Test("dynamic MCP tools cannot escape the original launch allowlist")
    func launchPolicyStillApplies() async throws {
        let fixture = try SessionCollaborationExecutorFixture()
        defer { fixture.cleanup() }
        let policy = LiveAgentToolPolicy.resolveLaunchPolicy(
            tools: "read_file",
            disallowedTools: nil,
            profile: nil
        )
        let executor = try await fixture.executor(policy: policy)
        defer { Task { await executor.shutdown() } }
        let provider = FixtureDynamicMCPProvider()

        let registration = await MCPToolBridge.register(provider: provider, into: executor.mcpToolset)
        #expect(registration.registeredNames == ["dynamic__echo"])
        #expect(!executor.currentToolSpecs().contains { $0.name == "dynamic__echo" })

        let denied = await executor.invoke(
            sessionID: "session-self",
            workingDirectory: fixture.root,
            call: collaborationCall("dynamic__echo", arguments: #"{"text":"forbidden"}"#)
        )
        guard case .failure(let error) = denied else {
            Issue.record("profile-filtered MCP tool escaped the launch allowlist")
            return
        }
        #expect(error.description.contains("unknown tool"))
        #expect(await provider.calls.isEmpty)
    }

    @Test("dynamic snapshots preserve immutable built-ins and Code Mode nested exposure")
    func immutableBuiltinsAndCodeMode() async throws {
        let fixture = try SessionCollaborationExecutorFixture()
        defer { fixture.cleanup() }
        let executor = try await fixture.executor()
        defer { Task { await executor.shutdown() } }
        let originalBuiltins = Set(executor.tools.map(\.name))
        let provider = FixtureDynamicMCPProvider()

        let registration = await MCPToolBridge.register(provider: provider, into: executor.mcpToolset)
        #expect(registration.registeredNames == ["dynamic__echo"])
        let current = executor.currentToolSpecs()
        #expect(originalBuiltins.isSubset(of: Set(current.map(\.name))))

        let projected = LiveCodeModeToolSurface(mode: .codeModeOnly, baseTools: current)
        #expect(!projected.modelTools.contains { $0.name == "dynamic__echo" })
        #expect(projected.snapshot.tools.contains { $0.name == "dynamic__echo" })
    }

    #if canImport(JavaScriptCore)
    @Test("persistent Code Mode picks up and drops MCP tools across turns without losing state")
    func persistentCodeModeRefreshesDynamicTools() async throws {
        let fixture = try SessionCollaborationExecutorFixture()
        defer { fixture.cleanup() }
        let executor = try await fixture.executor(bus: FixtureSessionBusBackend())
        defer { Task { await executor.shutdown() } }
        let coordinator = LiveCodeModeCoordinator(
            surface: LiveCodeModeToolSurface(mode: .codeMode, baseTools: executor.currentToolSpecs()),
            toolExecutor: executor,
            sessionID: "session-self",
            workingDirectory: fixture.root
        )
        defer { Task { await coordinator.shutdown() } }

        func exec(_ source: String) throws -> ToolCall {
            let data = try JSONEncoder().encode(JSONValue.object(["source": .string(source)]))
            return collaborationCall("exec", arguments: String(decoding: data, as: UTF8.self))
        }

        await coordinator.beginTurn { _ in }
        let stored = await coordinator.handleTransportCall(try exec(
            "store('session_marker', 41); text('stored');"
        ))
        #expect(stored.content.contains("stored"))
        await coordinator.endTurn()

        let provider = FixtureDynamicMCPProvider()
        let registration = await MCPToolBridge.register(provider: provider, into: executor.mcpToolset)
        #expect(registration.registeredNames == ["dynamic__echo"])

        await coordinator.beginTurn { _ in }
        let called = await coordinator.handleTransportCall(try exec("""
            const answer = await tools.dynamic__echo({ text: "hello" });
            text(JSON.stringify({ marker: load("session_marker"), result: answer.content }));
            """))
        #expect(called.content.contains(#""marker":41"#))
        #expect(called.content.contains("echo: hello"))
        #expect(await provider.calls.count == 1)
        await coordinator.endTurn()

        MCPToolBridge.unregister(server: "dynamic", from: executor.mcpToolset)
        await coordinator.beginTurn { _ in }
        let removed = await coordinator.handleTransportCall(try exec("""
            text(JSON.stringify({ marker: load("session_marker"), tool: typeof tools.dynamic__echo }));
            """))
        #expect(removed.content.contains(#""marker":41"#))
        #expect(removed.content.contains(#""tool":"undefined""#))
        #expect(await provider.calls.count == 1)
        await coordinator.endTurn()
    }
    #endif
}
