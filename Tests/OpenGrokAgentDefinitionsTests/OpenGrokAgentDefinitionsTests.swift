import Foundation
import Testing
@testable import OpenGrokAgentDefinitions

@Suite("Open Grok agent definitions")
struct OpenGrokAgentDefinitionsTests {
    @Test("parses frontmatter fields, tool directives, and prompt body")
    func parsesDefinition() throws {
        let content = """
        ---
        name: coordinator
        description: Coordinates implementation work
        promptMode: full
        tools: Agent(worker, researcher), read_file, grep
        disallowedTools: search_replace, write
        permissionMode: plan
        color: BLUE
        model: grok-3-fast
        mcpInheritance:
          named:
            - github
            - slack
        ---

        Use the project conventions.
        """

        let definition = try AgentDefinition.parse(content)
        #expect(definition.name == "coordinator")
        #expect(definition.promptMode == .full)
        #expect(definition.tools == ["Agent(worker, researcher)", "read_file", "grep"])
        #expect(definition.disallowedTools == ["search_replace", "write"])
        #expect(definition.permissionMode == .plan)
        #expect(definition.color == .blue)
        #expect(definition.model == .override("grok-3-fast"))
        #expect(definition.mcpInheritance == .named(["github", "slack"]))
        #expect(definition.promptBody == "Use the project conventions.")
    }

    @Test("rejects malformed required fields and max turns")
    func rejectsInvalidDefinitions() {
        do {
            _ = try AgentDefinition.parse("---\ndescription: missing name\n---\n")
            Issue.record("missing name should fail")
        } catch let error as AgentBuildError {
            #expect(error == .missingField("name"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        do {
            _ = try AgentDefinition.parse("---\nname: invalid\ndescription: test\nmaxTurns: 0\n---\n")
            Issue.record("zero maxTurns should fail")
        } catch let error as AgentBuildError {
            #expect(error == .invalidConfig("maxTurns must be greater than 0"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        do {
            _ = try AgentDefinition.parse("plain markdown without delimiters")
            Issue.record("missing delimiters should fail")
        } catch let error as AgentBuildError {
            #expect(error == .parseError("missing frontmatter delimiters"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("accepts invalid decorative colors without dropping the agent")
    func ignoresUnknownColor() throws {
        let definition = try AgentDefinition.parse("---\nname: colored\ndescription: test\ncolor: magenta\n---\n")
        #expect(definition.color == nil)
    }

    @Test("model override and JSON serialization are deterministic")
    func stableSerialization() throws {
        let definition = try AgentDefinition.parse("---\nname: stable\ndescription: test\nmodel: inherit\n---\nBody")
        let data = try definition.stableJSONData()
        let json = String(decoding: data, as: UTF8.self)
        let roundTripped = try String(decoding: AgentDefinition.fromJSONData(data).stableJSONData(), as: UTF8.self)
        #expect(json == roundTripped)
        #expect(json.range(of: "\"description\"")!.lowerBound < json.range(of: "\"name\"")!.lowerBound)
        #expect(definition.model == .inherit)
    }

    @Test("built-in profiles expose the Rust subagent policy")
    func builtinProfiles() {
        let explore = AgentDefinition.explore()
        #expect(explore.permissionMode == .plan)
        #expect(explore.inheritSkills == false)
        #expect(explore.toolConfig.toolNames == ["read_file", "view_image", "list_dir", "grep"])
        #expect(AgentDefinition.grokBuildOrchestrator().injectDefaultTools == false)
        #expect(isStrictHarnessAgentType("grok-build-orchestrator"))
        #expect(!isStrictHarnessAgentType("grok-build"))
        #expect(BuiltinAgentName.subagentVariants == [.generalPurpose, .explore, .plan])
    }

    @Test("built-in profile tools stay within the live registered surface")
    func builtinProfileToolsAreLive() throws {
        var profiles = Dictionary(uniqueKeysWithValues: BuiltinAgentName.allCases.map {
            ($0.rawValue, Set($0.definition.toolConfig.toolNames))
        })
        for preset in [
            "grok-build-plan-no-subagents", "grok-build-ask-user",
            "grok-build-orchestrator", "grok-computer",
        ] {
            profiles[preset] = Set(try #require(toolsetForPreset(preset)).toolNames)
        }
        profiles["workspace-grok-build"] = Set(workspaceGrokBuildToolset().toolNames)

        for (profile, toolNames) in profiles {
            let unregistered = toolNames.subtracting(liveRegisteredToolNames)
            #expect(unregistered.isEmpty, "\(profile) exposes unregistered tools: \(unregistered.sorted())")
        }
    }

    @Test("project definitions take precedence over user and bundled definitions")
    func discoveryPrecedence() throws {
        let root = try makeTemporaryDirectory()
        let project = root.appendingPathComponent("project", isDirectory: true)
        let nested = project.appendingPathComponent("Sources/Feature", isDirectory: true)
        let projectAgents = nested.appendingPathComponent(".opengrok/agents", isDirectory: true)
        let rootAgents = project.appendingPathComponent(".opengrok/agents", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let userAgents = home.appendingPathComponent(".opengrok/agents", isDirectory: true)
        let bundledAgents = home.appendingPathComponent(".opengrok/bundled/agents", isDirectory: true)
        for directory in [project.appendingPathComponent(".git"), projectAgents, rootAgents, userAgents, bundledAgents] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try writeAgent("duplicate", description: "nested", to: projectAgents)
        try writeAgent("duplicate", description: "root", to: rootAgents)
        try writeAgent("duplicate", description: "user", to: userAgents)
        try writeAgent("bundled-only", description: "bundled", to: bundledAgents)
        try writeAgent("explore", description: "bundled explore", to: bundledAgents)
        try writeAgent("explore", description: "user explore", to: userAgents)

        let discovery = AgentDefinitionDiscovery(environment: [
            "HOME": home.path,
            "OPENGROK_HOME": home.appendingPathComponent(".opengrok").path
        ])
        let definitions = discovery.discover(at: nested)
        #expect(definitions.first(where: { $0.name == "duplicate" })?.description == "nested")
        #expect(definitions.first(where: { $0.name == "duplicate" })?.scope == .project)
        #expect(discovery.byName("bundled-only", in: nested)?.scope == .bundled)
        #expect(discovery.byName("explore", in: nested)?.description == "user explore")
        #expect(discovery.allSubagents(at: nested).first(where: { $0.name == "explore" })?.source == .builtin(.explore))
    }

    @Test("instruction discovery and prompt composition preserve order")
    func instructionPromptComposition() throws {
        let root = try makeTemporaryDirectory()
        let project = root.appendingPathComponent("project", isDirectory: true)
        let nested = project.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("root rule".utf8).write(to: project.appendingPathComponent("AGENTS.md"))
        try Data("nested rule".utf8).write(to: nested.appendingPathComponent("AGENTS.md"))

        let discovery = AgentInstructionDiscovery(environment: ["HOME": root.appendingPathComponent("home").path])
        let files = discovery.discover(at: nested)
        #expect(files.map(\.content) == ["root rule", "nested rule"])
        let definition = AgentDefinition(name: "prompt", description: "test", promptBody: "agent body")
        let prompt = definition.composePrompt(basePrompt: "base", agentsMdFiles: files, personaSummaries: ["persona"], skillInstructions: ["skill"])
        #expect(prompt.contains("base"))
        #expect(prompt.contains("agent body"))
        #expect(prompt.contains("root rule"))
        #expect(prompt.contains("nested rule"))
        #expect(prompt.contains("persona"))
        #expect(prompt.contains("skill"))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("OpenGrokAgentDefinitionsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeAgent(_ name: String, description: String, to directory: URL) throws {
        let content = "---\nname: \(name)\ndescription: \(description)\n---\n"
        try Data(content.utf8).write(to: directory.appendingPathComponent("\(name).md"))
    }
}

private let liveRegisteredToolNames: Set<String> = [
    "agent_swarm", "apply_patch", "ask_user_question", "edit",
    "enter_plan_mode", "exit_plan_mode", "get_command_or_subagent_output", "glob",
    "grep", "image_gen", "kill_command_or_subagent", "list_dir",
    "memory_get", "memory_search", "monitor", "read_file",
    "run_terminal_command", "scheduler_create", "scheduler_delete", "scheduler_list",
    "search_replace", "skill", "spawn_subagent", "todo_write",
    "update_goal", "view_image", "wait_commands_or_subagents", "web_fetch",
    "web_search", "workflow", "write",
]
