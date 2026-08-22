import Foundation
import OpenGrokAgentDefinitions
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokSubagentResolution
import Testing

@testable import OpenGrokCLI

private final class AgentLaunchParityRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [OpenGrokLiveSamplingRequest] = []

    func append(_ request: OpenGrokLiveSamplingRequest) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let index = requests.count
        requests.append(request)
        return index
    }

    func snapshot() -> [OpenGrokLiveSamplingRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

private struct AgentLaunchParityFixture {
    let root: URL
    let home: URL
    let workspace: URL
    let environment: [String: String]

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-agent-launch-authority-\(UUID().uuidString)",
            isDirectory: true
        )
        home = root.appendingPathComponent("home", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "XDG_STATE_HOME": home.appendingPathComponent("state").path,
            "XAI_API_KEY": "agent-launch-test-key",
        ]
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func writeAgent(
        name: String,
        body: String,
        tools: String? = nil,
        disallowedTools: String? = nil,
        model: String? = nil,
        outsideCatalog: Bool = false
    ) throws -> URL {
        let directory = outsideCatalog
            ? workspace.appendingPathComponent("profiles", isDirectory: true)
            : home.appendingPathComponent("agents", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var lines = ["---", "name: \(name)", "description: Profile \(name)", "agentsMd: false"]
        if let tools { lines.append("tools: \(tools)") }
        if let disallowedTools { lines.append("disallowedTools: \(disallowedTools)") }
        if let model { lines.append("model: \(model)") }
        lines.append("---")
        lines.append(body)

        let url = directory.appendingPathComponent("\(name).md")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func options(_ arguments: [String]) throws -> CLIExecutionOptions {
        let command = try CLICommandParser.parseOrThrow(
            ["headless", "--prompt", "inspect launch authority", "--cwd", workspace.path,
             "--model", "grok-4.5"] + arguments
        )
        guard case let .launch(options) = command else {
            throw CLIApplicationError.failed("fixture command was not a launch")
        }
        return options
    }

    func authority(
        _ arguments: [String] = [],
        environment override: [String: String]? = nil
    ) throws -> LiveAgentLaunchAuthority {
        try LiveAgentLaunchAuthority.resolve(
            options: options(arguments),
            workingDirectory: workspace,
            environment: override ?? environment
        )
    }

    func run(
        _ arguments: [String],
        recorder: AgentLaunchParityRecorder = AgentLaunchParityRecorder(),
        response: String = "done",
        handler: (@Sendable (OpenGrokLiveSamplingRequest, Int) -> OpenGrokLiveSamplingResponse)? = nil
    ) async -> (code: Int32, stdout: String, stderr: String, requests: [OpenGrokLiveSamplingRequest]) {
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { request, emit in
                    let index = recorder.append(request)
                    let result = handler?(request, index) ?? OpenGrokLiveSamplingResponse(output: response)
                    if !result.output.isEmpty {
                        await emit(.output(result.output))
                    }
                    return result
                }
            }
        )
        let captured = CLIStreams.buffered()
        let code = await CLIRunner.run(
            ["headless", "--prompt", "inspect launch authority", "--cwd", workspace.path,
             "--model", "grok-4.5"] + arguments,
            environment: environment,
            streams: captured.0,
            application: OpenGrokApplication.live(dependencies: dependencies, control: .never)
        )
        return (code, captured.1.contents, captured.2.contents, recorder.snapshot())
    }

    func foundation(
        _ arguments: [String],
        interactive: Bool
    ) async throws -> OpenGrokLiveApplicationLauncher.LiveSessionFoundation {
        let context = CLIApplicationContext(
            environment: environment,
            streams: CLIStreams(out: { _ in }, err: { _ in }),
            control: .never
        )
        return try await OpenGrokLiveApplicationLauncher.makeSessionFoundation(
            options: options(arguments),
            context: context,
            dependencies: OpenGrokLiveCompositionDependencies(
                makeSampler: { _ in
                    OpenGrokLiveSampler { _, _ in OpenGrokLiveSamplingResponse(output: "done") }
                }
            ),
            interactiveSurfaceAvailable: interactive
        )
    }
}

@Suite("Live agent launch authority parity", .serialized)
struct LiveAgentLaunchAuthorityParityTests {
    @Test("absence of launch-agent flags preserves the existing unprofiled model route")
    func absentProfileDoesNotInventAnAgent() throws {
        let fixture = try AgentLaunchParityFixture()
        defer { fixture.cleanup() }
        let authority = try fixture.authority()
        #expect(authority.agentProfile == nil)
        #expect(authority.selectedAgentDefinition == nil)
        #expect(authority.cliAgents.isEmpty)
        #expect(authority.jsonSchema == nil)
        #expect(authority.toolPolicy(tools: nil, disallowedTools: nil) == nil)
    }

    @Test("inline agents normalize prompt aliases, default metadata, and canonical map-key names")
    func inlineAgentsNormalizeUpstreamFields() throws {
        let parsed = try LiveAgentLaunchAuthority.parseInlineAgents(#"""
        {
            "reviewer":{"name":"spoofed","prompt":"Cite every changed hunk","tools":["read_file"]},
            "writer":{"description":"Writes documentation","prompt":"ignored alias","promptBody":"Canonical body"}
        }
        """#)
        #expect(parsed.map(\.name) == ["reviewer", "writer"])
        #expect(parsed[0].description == "reviewer")
        #expect(parsed[0].promptBody == "Cite every changed hunk")
        #expect(parsed[0].tools == ["read_file"])
        #expect(parsed[1].description == "Writes documentation")
        #expect(parsed[1].promptBody == "Canonical body")
    }

    @Test("inline-agent malformed roots, nonobjects, unsafe names, and invalid definitions fail closed")
    func inlineAgentsRejectInvalidDefinitions() {
        for (input, marker) in [
            ("{broken", "invalid JSON"),
            (#"[]"#, "expected a JSON object"),
            (#"{"worker":false}"#, "failed to parse 'worker'"),
            (#"{"../escape":{"prompt":"no"}}"#, "path separators"),
            (#"{"worker":{"maxTurns":0}}"#, "failed to parse 'worker'"),
        ] {
            do {
                _ = try LiveAgentLaunchAuthority.parseInlineAgents(input)
                Issue.record("inline agent unexpectedly accepted: \(input)")
            } catch {
                #expect(String(describing: error).contains(marker))
            }
        }
    }

    @Test("--json-schema accepts only valid object roots and preserves nested schema values")
    func schemaRequiresJSONObject() throws {
        let parsedSchema = try LiveAgentLaunchAuthority.parseJSONSchema(
            #"{"type":"object","properties":{"answer":{"type":"string"}},"required":["answer"]}"#
        )
        let schema = try #require(parsedSchema)
        #expect(schema.objectValue?["type"] == .string("object"))
        #expect(schema.objectValue?["properties"]?.objectValue?["answer"]?.objectValue?["type"] == .string("string"))

        for input in ["true", "null", "[]", #""schema""#, "7"] {
            do {
                _ = try LiveAgentLaunchAuthority.parseJSONSchema(input)
                Issue.record("nonobject schema unexpectedly accepted: \(input)")
            } catch {
                #expect(String(describing: error).contains("must be a JSON object"))
            }
        }
        do {
            _ = try LiveAgentLaunchAuthority.parseJSONSchema("{broken")
            Issue.record("malformed schema unexpectedly accepted")
        } catch {
            #expect(String(describing: error).contains("invalid JSON"))
        }
    }

    @Test("--agent profile path overrides --agent-profile while an agent name does not")
    func agentProfilePathAndNamePrecedence() throws {
        let fixture = try AgentLaunchParityFixture()
        defer { fixture.cleanup() }
        try fixture.writeAgent(name: "selected-profile", body: "Selected profile prompt")
        try fixture.writeAgent(name: "named-agent", body: "Named agent prompt")
        let explicitFile = try fixture.writeAgent(
            name: "path-agent",
            body: "Path agent prompt",
            outsideCatalog: true
        )

        let named = try fixture.authority([
            "--agent-profile", "selected-profile", "--agent", "named-agent",
        ])
        #expect(named.selectedAgentDefinition?.name == "selected-profile")

        let file = try fixture.authority([
            "--agent-profile", "selected-profile", "--agent", explicitFile.path,
        ])
        #expect(file.selectedAgentDefinition?.name == "path-agent")
        #expect(file.agentProfile?.systemPrompt?.contains("Path agent prompt") == true)

        let relative = try fixture.authority([
            "--agent", "profiles/path-agent.md",
        ])
        #expect(relative.selectedAgentDefinition?.name == "path-agent")
    }

    @Test("explicit CLI agent outranks GROK_AGENT while inline agents remain subagent-only")
    func environmentAndInlineAuthorityBoundaries() throws {
        let fixture = try AgentLaunchParityFixture()
        defer { fixture.cleanup() }
        try fixture.writeAgent(name: "environment-agent", body: "Environment-owned prompt")
        try fixture.writeAgent(name: "cli-agent", body: "CLI-owned prompt")

        var environment = fixture.environment
        environment["GROK_AGENT"] = "environment-agent"
        #expect(try fixture.authority(environment: environment).selectedAgentDefinition?.name == "environment-agent")
        #expect(try fixture.authority(["--agent", "cli-agent"], environment: environment)
            .selectedAgentDefinition?.name == "cli-agent")

        do {
            _ = try fixture.authority([
                "--agent", "inline-only", "--agents", #"{"inline-only":{"prompt":"child prompt"}}"#,
            ])
            Issue.record("an inline subagent was unexpectedly promoted into the root profile")
        } catch {
            #expect(String(describing: error).contains("inline-only"))
        }
    }

    @Test("rules append exact human_rules markup while a nonblank override replaces everything verbatim")
    func systemPromptRulesAndOverridePrecedence() throws {
        let fixture = try AgentLaunchParityFixture()
        defer { fixture.cleanup() }

        let rules = try fixture.authority(["--rules", "Preserve all permission gates."])
        #expect(rules.applyingSystemPrompt(to: "Base instructions") ==
            "Base instructions\n\n<human_rules>\nPreserve all permission gates.\n</human_rules>")

        let override = try fixture.authority([
            "--rules", "must not appear",
            "--system-prompt-override", "  Exact replacement\n",
        ])
        #expect(override.hasSystemPromptOverride)
        #expect(override.applyingSystemPrompt(to: "must not survive") == "  Exact replacement\n")

        let blankOverride = try fixture.authority([
            "--rules", "remain effective", "--system-prompt-override", " \n ",
        ])
        #expect(!blankOverride.hasSystemPromptOverride)
        #expect(blankOverride.applyingSystemPrompt(to: "base") ==
            "base\n\n<human_rules>\nremain effective\n</human_rules>")
    }

    @Test("plan and question suppression only narrows profile, CLI, and managed-facing tool policy")
    func restrictionsUnionWithExistingDenials() throws {
        let fixture = try AgentLaunchParityFixture()
        defer { fixture.cleanup() }
        try fixture.writeAgent(
            name: "restricted-profile",
            body: "Keep every inherited denial.",
            disallowedTools: "write"
        )

        let authority = try fixture.authority([
            "--agent", "restricted-profile", "--no-plan", "--no-ask-user",
        ])
        let policy = try #require(authority.toolPolicy(
            tools: "read_file,enter_plan_mode,exit_plan_mode,ask_user_question,run_terminal_cmd,write",
            disallowedTools: "run_terminal_cmd"
        ))
        #expect(policy.allows(liveToolName: "read_file"))
        #expect(!policy.allows(liveToolName: "enter_plan_mode"))
        #expect(!policy.allows(liveToolName: "exit_plan_mode"))
        #expect(!policy.allows(liveToolName: "ask_user_question"))
        #expect(!policy.allows(liveToolName: "run_terminal_cmd"))
        #expect(!policy.allows(liveToolName: "write"))
    }

    @Test("actual live launch sends --agent profile instructions and the profile-constrained tool list")
    func selectedProfileReachesProvider() async throws {
        let fixture = try AgentLaunchParityFixture()
        defer { fixture.cleanup() }
        try fixture.writeAgent(
            name: "reviewer",
            body: "PROFILE WIRE INSTRUCTION: cite the exact changed hunk.",
            tools: "read_file",
            model: "grok-4.5"
        )

        let result = await fixture.run(["--agent", "reviewer"])
        #expect(result.code == CLIRunner.ExitCode.success.rawValue)
        let request = try #require(result.requests.first)
        let system = request.items.compactMap { item -> String? in
            guard case let .system(content) = item else { return nil }
            return content.content
        }
        #expect(system.count == 1)
        #expect(system[0].contains("PROFILE WIRE INSTRUCTION"))
        #expect(request.tools.contains { $0.name == "read_file" })
        #expect(!request.tools.contains { $0.name == "run_terminal_cmd" })
    }

    @Test("actual live launch sends a full prompt override verbatim and never leaks appended rules")
    func systemPromptOverrideReachesProviderVerbatim() async throws {
        let fixture = try AgentLaunchParityFixture()
        defer { fixture.cleanup() }
        let override = "  EXACT PROVIDER SYSTEM PROMPT\n"
        let result = await fixture.run([
            "--rules", "SHOULD NEVER REACH THE PROVIDER",
            "--system-prompt-override", override,
        ])
        #expect(result.code == CLIRunner.ExitCode.success.rawValue)
        let request = try #require(result.requests.first)
        let systems = request.items.compactMap { item -> String? in
            guard case let .system(value) = item else { return nil }
            return value.content
        }
        #expect(systems == [override])
    }

    @Test("a resumed session replaces its durable system head only for a nonblank full override")
    func resumedSystemPromptOverrideReplacesPersistedHead() async throws {
        let fixture = try AgentLaunchParityFixture()
        defer { fixture.cleanup() }

        let sessionID = UUID().uuidString.lowercased()
        let store = LiveConversationStore(openGrokHome: fixture.home)
        var existing = LiveConversationRecord.new(
            sessionID: sessionID,
            workingDirectory: fixture.workspace
        )
        existing.currentModelID = "grok-4.5"
        existing.currentProvider = .xai
        existing.items = [
            .system("PERSISTED SYSTEM INSTRUCTIONS MUST NOT SURVIVE"),
            .user("earlier prompt"),
            .assistant(AssistantItem(content: "earlier answer")),
        ]
        try await store.save(existing)

        let replacement = "REPLACED SYSTEM HEAD FROM RESUME"
        let result = await fixture.run([
            "--resume", sessionID,
            "--system-prompt-override", replacement,
        ])
        #expect(result.code == CLIRunner.ExitCode.success.rawValue)
        let request = try #require(result.requests.first)
        let systems = request.items.compactMap { item -> String? in
            guard case let .system(value) = item else { return nil }
            return value.content
        }
        #expect(systems == [replacement])

        let persisted = try await store.load(sessionID: sessionID)
        let durableSystems = persisted.items.compactMap { item -> String? in
            guard case let .system(value) = item else { return nil }
            return value.content
        }
        #expect(durableSystems == [replacement])
    }

    @Test("actual live launch appends human rules to the provider system prompt")
    func humanRulesReachProvider() async throws {
        let fixture = try AgentLaunchParityFixture()
        defer { fixture.cleanup() }
        let result = await fixture.run(["--rules", "Never weaken managed deny rules."])
        #expect(result.code == CLIRunner.ExitCode.success.rawValue)
        let request = try #require(result.requests.first)
        let system = request.items.compactMap { item -> String? in
            guard case let .system(value) = item else { return nil }
            return value.content
        }.joined(separator: "\n")
        #expect(system.contains("<human_rules>\nNever weaken managed deny rules.\n</human_rules>"))
    }

    @Test("actual live launch forwards the exact strict JSON schema to the native provider request")
    func strictSchemaReachesProvider() async throws {
        let fixture = try AgentLaunchParityFixture()
        defer { fixture.cleanup() }
        let rawSchema = #"{"type":"object","properties":{"answer":{"type":"string"}},"required":["answer"],"additionalProperties":false}"#
        let parsedSchema = try LiveAgentLaunchAuthority.parseJSONSchema(rawSchema)
        let expected = try #require(parsedSchema)
        let result = await fixture.run(
            ["--json-schema", rawSchema],
            response: #"{"answer":"validated"}"#
        )
        #expect(result.code == CLIRunner.ExitCode.success.rawValue)
        #expect(try #require(result.requests.first).jsonSchema == expected)
        #expect(result.stdout.contains("validated"))
    }

    @Test("malformed launch schema and inline definitions fail before a provider can be constructed")
    func malformedAuthoritiesNeverSample() async {
        do {
            let fixture = try AgentLaunchParityFixture()
            defer { fixture.cleanup() }
            let malformedSchema = await fixture.run(["--json-schema", "[]"])
            #expect(malformedSchema.code != CLIRunner.ExitCode.success.rawValue)
            #expect(malformedSchema.stderr.contains("must be a JSON object"))
            #expect(malformedSchema.requests.isEmpty)

            let malformedAgents = await fixture.run(["--agents", #"{"unsafe/name":{}}"#])
            #expect(malformedAgents.code != CLIRunner.ExitCode.success.rawValue)
            #expect(malformedAgents.stderr.contains("--agents"))
            #expect(malformedAgents.requests.isEmpty)
        } catch {
            Issue.record("could not create launch fixture: \(error)")
        }
    }

    @Test("inline subagents become real advertised child types and their exact prompt reaches a child sampler")
    func inlineAgentsRunThroughLiveChildDispatch() async throws {
        let fixture = try AgentLaunchParityFixture()
        defer { fixture.cleanup() }
        let inline = #"{"wire-reviewer":{"description":"INLINE AGENT WIRE DESCRIPTION","prompt":"INLINE CHILD SYSTEM INSTRUCTIONS"}}"#
        let result = await fixture.run(
            ["--agents", inline],
            handler: { _, index in
                if index == 0 {
                    return OpenGrokLiveSamplingResponse(
                        output: "",
                        toolCalls: [ToolCall(
                            id: "call-inline-child",
                            name: "spawn_subagent",
                            arguments: #"{"prompt":"Inspect the delegated request","description":"inline delegation","subagent_type":"wire-reviewer","background":false}"#
                        )]
                    )
                }
                if index == 1 {
                    return OpenGrokLiveSamplingResponse(output: "inline child completed")
                }
                return OpenGrokLiveSamplingResponse(output: "root observed inline completion")
            }
        )
        #expect(result.code == CLIRunner.ExitCode.success.rawValue)
        #expect(result.requests.count >= 3)
        let parent = try #require(result.requests.first)
        let spawn = try #require(parent.tools.first { $0.name == "spawn_subagent" })
        #expect(spawn.description?.contains("wire-reviewer") == true)
        #expect(spawn.description?.contains("INLINE AGENT WIRE DESCRIPTION") == true)

        let child = try #require(result.requests.first { $0.sessionID != parent.sessionID })
        let system = child.items.compactMap { item -> String? in
            guard case let .system(value) = item else { return nil }
            return value.content
        }.joined(separator: "\n")
        #expect(system.contains("INLINE CHILD SYSTEM INSTRUCTIONS"))
    }

    @Test("--no-plan removes the actual provider plan tools without changing ordinary tools")
    func noPlanRemovesToolsFromProvider() async throws {
        let fixture = try AgentLaunchParityFixture()
        defer { fixture.cleanup() }
        let result = await fixture.run(["--no-plan"])
        #expect(result.code == CLIRunner.ExitCode.success.rawValue)
        let tools = try #require(result.requests.first).tools.map(\.name)
        #expect(tools.contains("read_file"))
        #expect(!tools.contains("enter_plan_mode"))
        #expect(!tools.contains("exit_plan_mode"))
    }

    @Test("interactive --no-plan and --no-ask-user remove actual presenters and advertised tools")
    func interactiveFlagsGateRealPresenters() async throws {
        let fixture = try AgentLaunchParityFixture()
        defer { fixture.cleanup() }

        let baseline = try await fixture.foundation([], interactive: true)
        #expect(baseline.questionCoordinator != nil)
        #expect(baseline.planApprovalCoordinator != nil)
        #expect(baseline.toolExecutor.tools.contains { $0.name == "ask_user_question" })
        #expect(baseline.toolExecutor.tools.contains { $0.name == "enter_plan_mode" })
        await baseline.toolExecutor.shutdown()

        let restricted = try await fixture.foundation(
            ["--no-plan", "--no-ask-user"],
            interactive: true
        )
        #expect(restricted.questionCoordinator == nil)
        #expect(restricted.planApprovalCoordinator == nil)
        let names = restricted.toolExecutor.tools.map(\.name)
        #expect(names.contains("read_file"))
        #expect(!names.contains("ask_user_question"))
        #expect(!names.contains("enter_plan_mode"))
        #expect(!names.contains("exit_plan_mode"))
        await restricted.toolExecutor.shutdown()
    }
}
