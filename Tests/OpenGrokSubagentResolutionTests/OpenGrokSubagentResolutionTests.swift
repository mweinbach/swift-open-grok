import Foundation
import Testing
@testable import OpenGrokSubagentResolution

@Suite("Subagent resolution")
struct SubagentResolutionTests {
    @Test("explicit, role, persona, and parent precedence")
    func precedence() {
        let role = SubagentRole(
            defaultCapabilityMode: "read-write",
            model: "role-model",
            reasoningEffort: "high",
            defaultIsolation: "worktree"
        )
        let persona = SubagentPersona(
            instructions: "Be concise.",
            defaultIsolation: "none",
            model: "persona-model",
            reasoningEffort: "low"
        )
        let overrides = SubagentRuntimeOverrides(
            model: "explicit-model",
            persona: "writer",
            reasoningEffort: "medium",
            capabilityMode: .readOnly
        )
        let runtime = resolveEffectiveOverrides(
            overrides: overrides,
            role: role,
            personas: ["writer": persona],
            cwd: nil,
            parent: ParentRuntimeDefaults(model: "parent-model", reasoningEffort: "parent")
        )
        #expect(runtime.model == "explicit-model")
        #expect(runtime.reasoningEffort == "medium")
        #expect(runtime.capabilityMode == SubagentCapabilityMode.readOnly)
        #expect(runtime.isolation.rawValue == "worktree")
        #expect(runtime.personaInstructions == "Be concise.")
    }

    @Test("capability intersection never escalates")
    func capabilityIntersection() {
        #expect(intersectCapabilityModes(requested: .all, ceiling: .readOnly) == .readOnly)
        #expect(intersectCapabilityModes(requested: .readWrite, ceiling: .execute) == .readOnly)
        #expect(intersectCapabilityModes(requested: .execute, ceiling: .readWrite) == .readOnly)
        #expect(intersectCapabilityModes(requested: nil, ceiling: .execute) == .execute)
    }

    @Test("persona files merge inline text and fail closed on IO")
    func personaFileResolution() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("persona.md")
        try "From file.".write(to: file, atomically: true, encoding: .utf8)
        let runtime = resolveEffectiveOverrides(
            overrides: SubagentRuntimeOverrides(persona: "writer"),
            role: nil,
            personas: ["writer": SubagentPersona(instructions: "Inline.", instructionsFile: "persona.md", sourceDirectory: directory)],
            cwd: nil
        )
        #expect(runtime.personaInstructions == "Inline.\n\nFrom file.")
        #expect(runtime.personaError == nil)

        let broken = resolveEffectiveOverrides(
            overrides: SubagentRuntimeOverrides(model: "should-be-cleared", persona: "broken"),
            role: nil,
            personas: ["broken": SubagentPersona(instructionsFile: "missing.md", sourceDirectory: directory)],
            cwd: nil
        )
        #expect(broken.personaResolutionFatal)
        #expect(broken.model == nil)
    }

    @Test("definition precedence and deterministic names")
    func definitionPrecedence() throws {
        let project = AgentDefinition(name: "reviewer", description: "Project reviewer")
        let user = AgentDefinition(name: "reviewer", description: "User reviewer")
        let context = DefinitionResolutionContext(
            cwd: URL(fileURLWithPath: "/tmp/does-not-exist"),
            definitions: [
                SubagentDefinition(definition: user, source: .user),
                SubagentDefinition(definition: project, source: .project)
            ],
            includeFilesystemDefinitions: false
        )
        let resolved = try resolveAgentDefinition(subagentType: "reviewer", context: context)
        #expect(resolved.description == "Project reviewer")
        #expect(availableAgentNames(context: context) == ["explore", "general-purpose", "plan", "reviewer"])
    }

    @Test("definition inheritance detects cycles and unknown parents")
    func hierarchyValidation() {
        let first = AgentDefinition(name: "first", description: "First")
        let second = AgentDefinition(name: "second", description: "Second")
        let cycleContext = DefinitionResolutionContext(
            cwd: URL(fileURLWithPath: "/tmp"),
            definitions: [
                SubagentDefinition(definition: first, extends: "second", source: .project),
                SubagentDefinition(definition: second, extends: "first", source: .project)
            ],
            includeFilesystemDefinitions: false
        )
        do {
            _ = try resolveAgentDefinition(subagentType: "first", context: cycleContext)
            Issue.record("expected cycle error")
        } catch let error as ResolutionError {
            guard case let .hierarchyCycle(path) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(path == ["first", "second", "first"])
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        let unknownContext = DefinitionResolutionContext(
            cwd: URL(fileURLWithPath: "/tmp"),
            definitions: [SubagentDefinition(definition: first, extends: "missing", source: .project)],
            includeFilesystemDefinitions: false
        )
        do {
            _ = try resolveAgentDefinition(subagentType: "first", context: unknownContext)
            Issue.record("expected unknown parent error")
        } catch let error as ResolutionError {
            #expect(error.description == "subagent \"first\" extends unknown definition \"missing\"")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("resume identity uses stable errors and ignores model")
    func resumeValidation() {
        let source = ResumeSourceData(
            subagentID: "child",
            subagentType: "general-purpose",
            persona: "writer",
            modelID: "old-model",
            childCWD: "/workspace",
            childSessionID: "session"
        )
        do {
            try validateResumeIdentity(requestedType: "explore", requestedPersona: nil, source: source)
            Issue.record("expected type mismatch")
        } catch let error as ResumeValidationError {
            #expect(error == .typeMismatch(requested: "explore", sourceValue: "general-purpose"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        do {
            try validateResumeIdentity(requestedType: "general-purpose", requestedPersona: "reviewer", source: source)
            Issue.record("expected persona mismatch")
        } catch let error as ResumeValidationError {
            #expect(error == .personaMismatch(requested: "reviewer", sourceValue: "writer"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        do {
            try validateResumeIdentity(requestedType: "general-purpose", requestedPersona: nil, source: source)
        } catch {
            Issue.record("unexpected matching error: \(error)")
        }
    }

    @Test("child tool policy removes escalation surfaces")
    func toolPolicy() {
        let toolIDs = [
            "read_file", "grep", "write", "run_terminal_command", "spawn_subagent", "workflow", "get_task_output", "enter_plan_mode"
        ]
        var definition = AgentDefinition(
            name: "child",
            description: "Child",
            toolConfig: AgentToolConfiguration(tools: toolIDs.map { AgentToolDefinition(id: $0) })
        )
        applyChildToolPolicy(definition: &definition, capabilityMode: .readOnly, allowNestedSubagents: false)
        #expect(definition.toolConfig.toolNames == ["read_file", "grep"])
    }
}
