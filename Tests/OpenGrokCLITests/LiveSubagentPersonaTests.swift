// LiveSubagentPersonaTests.swift
//
// Personas through the LIVE seam (AGENTS.md §3): the composition the
// executable actually runs — `makeSessionFoundation`, the real
// `OpenGrokLiveSampler.production` factory against the mock inference
// server, the real coordinator child — so a persona `.toml` on disk in an
// isolated home/cwd observably changes a REAL subagent's sampler request.
// Before this slice the host resolved every spawn with `personas: [:]`,
// which is exactly the "Saved, and permanently unfindable" class the B9-b
// program exists to close.
//
// The persona NAME rides the internal-spawner channel
// (`SubagentRequest.runtime_overrides.persona`, task/types.rs:331-332),
// because the model-facing task input has no persona parameter at the pin
// (`TaskTool::run` hardcodes `persona: None`, task/mod.rs:394). The
// dispatch-path tests below therefore also pin the inverse: a spawn through
// the real tool executor NEVER carries a persona block, even with persona
// files on disk.

import Foundation
import Testing
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShell
import OpenGrokTestSupport
import OpenGrokToolTypes
@testable import OpenGrokCLI

// MARK: - Fixture

private struct PersonaFixture {
    let home: URL
    let workspace: URL
    let server: MockInferenceServer
    let environment: [String: String]

    init(userConfig: String? = nil) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-subagent-persona-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        server = try MockInferenceServer()
        var config = """
            [endpoints]
            xai_api_base_url = "\(server.url)"
            """
        if let userConfig {
            config += "\n\n" + userConfig
        }
        try config.write(
            to: home.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
        environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "XDG_STATE_HOME": home.appendingPathComponent("state").path,
            "XAI_API_KEY": "test-xai-key",
        ]
    }

    func dispose() {
        server.stop()
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    /// Write `{home}/personas/{name}.toml` — the user scope.
    func writeUserPersona(_ name: String, instructions: String) throws {
        try writePersona(
            name,
            instructions: instructions,
            directory: home.appendingPathComponent("personas", isDirectory: true)
        )
    }

    /// Write `{workspace}/.opengrok/personas/{name}.toml` — the project scope.
    func writeProjectPersona(_ name: String, instructions: String) throws {
        try writePersona(
            name,
            instructions: instructions,
            directory: workspace
                .appendingPathComponent(".opengrok", isDirectory: true)
                .appendingPathComponent("personas", isDirectory: true)
        )
    }

    private func writePersona(_ name: String, instructions: String, directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "instructions = \"\(instructions)\"".write(
            to: directory.appendingPathComponent("\(name).toml"),
            atomically: true,
            encoding: .utf8
        )
    }

    func context() -> CLIApplicationContext {
        CLIApplicationContext(
            environment: environment,
            streams: CLIStreams(out: { _ in }, err: { _ in }),
            control: .never
        )
    }

    /// The REAL production sampler factory — the child must reach the wire
    /// through the code path the executable runs, not a stub.
    func makeFoundation() async throws -> OpenGrokLiveApplicationLauncher.LiveSessionFoundation {
        let command = try CLICommandParser.parseOrThrow(
            ["headless", "--prompt", "hello", "--cwd", workspace.path, "--model", "grok-4.5"]
        )
        guard case .launch(let options) = command else {
            throw CLIApplicationError.failed("fixture did not parse to a launch")
        }
        return try await OpenGrokLiveApplicationLauncher.makeSessionFoundation(
            options: options,
            context: context(),
            dependencies: OpenGrokLiveCompositionDependencies(
                makeSampler: OpenGrokLiveSampler.production(configuration:)
            )
        )
    }

    func enqueueChildTurn(_ text: String) throws {
        try server.enqueueResponse(
            path: "/v1/responses",
            response: .sse(SseEvents.responsesApiEventsExact(text: text, model: "grok-4.5"))
        )
    }

    /// Inference POST bodies to the Responses endpoint, in arrival order.
    func responsesBodies() -> [String] {
        server.requests()
            .filter { $0.method == "POST" && $0.path.contains("responses") }
            .map { (try? $0.body?.encodeString()) ?? "" }
    }

    static func spawnArgs(
        prompt: String,
        extra: [String: OpenGrokShared.JSONValue] = [:]
    ) -> OpenGrokShared.JSONValue {
        var object: [String: OpenGrokShared.JSONValue] = [
            "prompt": .string(prompt),
            "description": .string("persona probe"),
            "subagent_type": .string("general-purpose"),
            "background": .bool(false),
        ]
        for (key, value) in extra { object[key] = value }
        return .object(object)
    }
}

// MARK: - The live persona feed

@Suite("subagent personas through the live seam", .serialized)
struct LiveSubagentPersonaTests {
    /// The flagship (§3): a persona file on disk, in an isolated home the
    /// composition resolved (never the process's), lands its instructions on
    /// the REAL child's sampler request — loader → host context → per-spawn
    /// overlay → `resolveRuntimeConfig` → `<persona>` block → wire.
    @Test("a user-scope persona .toml changes a real child's sampler request")
    func personaFileReachesTheChildRequest() async throws {
        let fixture = try PersonaFixture()
        defer { fixture.dispose() }
        let marker = "Cite the keystone ledger \(UUID().uuidString) in every answer."
        try fixture.writeUserPersona("probe", instructions: marker)
        try fixture.enqueueChildTurn("child done")

        let foundation = try await fixture.makeFoundation()
        defer { Task { await foundation.toolExecutor.shutdown() } }
        let host = try #require(foundation.subagentHost)

        let result = await host.spawn(
            args: PersonaFixture.spawnArgs(prompt: "run the probe"),
            toolCallID: "call-persona-1",
            persona: "probe"
        )
        guard case .success = result else {
            Issue.record("persona spawn failed: \(result)")
            return
        }

        let bodies = fixture.responsesBodies()
        #expect(bodies.count == 1)
        let childBody = try #require(bodies.first)
        #expect(childBody.contains("<persona>"))
        #expect(childBody.contains(marker))
    }

    /// Project beats User, proven on the wire: the same persona name in both
    /// scopes resolves to the project file's instructions
    /// (`effective_definition_maps`, config/mod.rs:546-560).
    @Test("a project persona shadows the user persona on the wire")
    func projectShadowsUserOnTheWire() async throws {
        let fixture = try PersonaFixture()
        defer { fixture.dispose() }
        let projectMarker = "PROJECT-SOUL-\(UUID().uuidString)"
        let userMarker = "USER-SOUL-\(UUID().uuidString)"
        try fixture.writeProjectPersona("probe", instructions: projectMarker)
        try fixture.writeUserPersona("probe", instructions: userMarker)
        try fixture.enqueueChildTurn("child done")

        let foundation = try await fixture.makeFoundation()
        defer { Task { await foundation.toolExecutor.shutdown() } }
        let host = try #require(foundation.subagentHost)

        let result = await host.spawn(
            args: PersonaFixture.spawnArgs(prompt: "run the probe"),
            toolCallID: "call-persona-1",
            persona: "probe"
        )
        guard case .success = result else {
            Issue.record("persona spawn failed: \(result)")
            return
        }
        let childBody = try #require(fixture.responsesBodies().first)
        #expect(childBody.contains(projectMarker))
        #expect(!childBody.contains(userMarker))
    }

    /// Inline `[subagents.personas]` beats a project file of the same name —
    /// the `source_path.is_none()` arm of the merge (config/mod.rs:554-559).
    @Test("an inline config persona shadows the project file on the wire")
    func inlineShadowsProjectFileOnTheWire() async throws {
        let inlineMarker = "INLINE-SOUL-\(UUID().uuidString)"
        let fixture = try PersonaFixture(userConfig: """
            [subagents.personas.probe]
            instructions = "\(inlineMarker)"
            """)
        defer { fixture.dispose() }
        let projectMarker = "PROJECT-SOUL-\(UUID().uuidString)"
        try fixture.writeProjectPersona("probe", instructions: projectMarker)
        try fixture.enqueueChildTurn("child done")

        let foundation = try await fixture.makeFoundation()
        defer { Task { await foundation.toolExecutor.shutdown() } }
        let host = try #require(foundation.subagentHost)

        let result = await host.spawn(
            args: PersonaFixture.spawnArgs(prompt: "run the probe"),
            toolCallID: "call-persona-1",
            persona: "probe"
        )
        guard case .success = result else {
            Issue.record("persona spawn failed: \(result)")
            return
        }
        let childBody = try #require(fixture.responsesBodies().first)
        #expect(childBody.contains(inlineMarker))
        #expect(!childBody.contains(projectMarker))
    }

    /// The abort arm: a named-but-unknown persona rejects the spawn with the
    /// resolver's own copy, before any child samples. Upstream fails the
    /// spawn on ANY persona error (handle_request.rs:308-315), not only the
    /// fatal file-I/O one — this is the positive control proving the fed map
    /// (not `[:]`) is what resolution consulted.
    @Test("a named-but-missing persona rejects the spawn with the resolver's copy")
    func missingPersonaAbortsTheSpawn() async throws {
        let fixture = try PersonaFixture()
        defer { fixture.dispose() }
        try fixture.writeUserPersona("probe", instructions: "exists but is not asked for")

        let foundation = try await fixture.makeFoundation()
        defer { Task { await foundation.toolExecutor.shutdown() } }
        let host = try #require(foundation.subagentHost)

        let result = await host.spawn(
            args: PersonaFixture.spawnArgs(prompt: "run the probe"),
            toolCallID: "call-persona-1",
            persona: "ghost"
        )
        guard case .failure(let error) = result else {
            Issue.record("a missing persona unexpectedly spawned: \(result)")
            return
        }
        #expect(error.description.contains("persona \"ghost\" not found in config"))
        #expect(fixture.responsesBodies().isEmpty)
    }

    /// A malformed persona file never takes a spawn down: the broken file is
    /// skipped (config/mod.rs:311-318, warn-and-continue) and a valid
    /// sibling still applies.
    @Test("a malformed persona file is skipped and a valid sibling still applies")
    func malformedPersonaFileIsSkipped() async throws {
        let fixture = try PersonaFixture()
        defer { fixture.dispose() }
        let marker = "SURVIVOR-SOUL-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            at: fixture.home.appendingPathComponent("personas"),
            withIntermediateDirectories: true
        )
        try "instructions = [unclosed".write(
            to: fixture.home.appendingPathComponent("personas/broken.toml"),
            atomically: true,
            encoding: .utf8
        )
        try fixture.writeUserPersona("probe", instructions: marker)
        try fixture.enqueueChildTurn("child done")

        let foundation = try await fixture.makeFoundation()
        defer { Task { await foundation.toolExecutor.shutdown() } }
        let host = try #require(foundation.subagentHost)

        let result = await host.spawn(
            args: PersonaFixture.spawnArgs(prompt: "run the probe"),
            toolCallID: "call-persona-1",
            persona: "probe"
        )
        guard case .success = result else {
            Issue.record("spawn beside a malformed persona file failed: \(result)")
            return
        }
        let childBody = try #require(fixture.responsesBodies().first)
        #expect(childBody.contains(marker))
    }

    /// The regression guard AND the parity pin in one: through the REAL tool
    /// dispatch (`toolExecutor.invoke`), a spawn resolves exactly as before —
    /// no `<persona>` block — even with persona files on disk, because the
    /// model-facing task input has no persona parameter at the pin
    /// (task/mod.rs:394 hardcodes `persona: None`).
    @Test("tool dispatch never carries a persona, with or without files on disk")
    func dispatchPathStaysPersonaFree() async throws {
        let fixture = try PersonaFixture()
        defer { fixture.dispose() }
        try fixture.writeUserPersona("probe", instructions: "MUST-NOT-APPEAR-\(UUID().uuidString)")
        try fixture.enqueueChildTurn("child done")

        let foundation = try await fixture.makeFoundation()
        defer { Task { await foundation.toolExecutor.shutdown() } }

        // Even a model that GUESSES a persona argument gets nil: the decoder
        // has no such key, exactly like upstream's input struct.
        let result = await foundation.toolExecutor.invoke(
            sessionID: foundation.sessionID,
            workingDirectory: foundation.cwd,
            call: ToolCall(
                id: "call-spawn-1",
                name: "spawn_subagent",
                arguments: #"{"prompt":"plain spawn","description":"d","subagent_type":"general-purpose","background":false,"persona":"probe"}"#
            )
        )
        guard case .success = result else {
            Issue.record("plain spawn failed: \(result)")
            return
        }
        let childBody = try #require(fixture.responsesBodies().first)
        #expect(!childBody.contains("<persona>"))
        #expect(!childBody.contains("MUST-NOT-APPEAR"))
    }

    /// Resume inherits the source's persona (handle_request.rs:255-258) and
    /// refuses an explicit mismatch (`validate_resume_identity`).
    @Test("resume inherits the source persona and rejects a mismatched one")
    func resumeInheritsAndValidatesPersona() async throws {
        let fixture = try PersonaFixture()
        defer { fixture.dispose() }
        let marker = "RESUME-SOUL-\(UUID().uuidString)"
        try fixture.writeUserPersona("probe", instructions: marker)
        try fixture.enqueueChildTurn("first child answer")
        try fixture.enqueueChildTurn("resumed child answer")

        let foundation = try await fixture.makeFoundation()
        defer { Task { await foundation.toolExecutor.shutdown() } }
        let host = try #require(foundation.subagentHost)

        let first = await host.spawn(
            args: PersonaFixture.spawnArgs(prompt: "first task"),
            toolCallID: "call-persona-1",
            persona: "probe"
        )
        guard case .success(let firstResult) = first,
              let firstID = firstResult.value["subagent_id"]?.stringValue else {
            Issue.record("first persona spawn failed: \(first)")
            return
        }

        // An explicit different persona on resume is refused before spawn.
        let mismatch = await host.spawn(
            args: PersonaFixture.spawnArgs(
                prompt: "follow-up",
                extra: ["resume_from": .string(firstID)]
            ),
            toolCallID: "call-persona-2",
            persona: "other"
        )
        guard case .failure(let mismatchError) = mismatch else {
            Issue.record("a persona-mismatched resume unexpectedly spawned")
            return
        }
        #expect(mismatchError.description.contains(
            "Resumed sessions must use the same persona as the source"
        ))

        // A plain resume (no persona named) inherits the source's, and the
        // record survives to the resumed child's bookkeeping.
        let resumed = await host.spawn(
            args: PersonaFixture.spawnArgs(
                prompt: "follow-up",
                extra: ["resume_from": .string(firstID)]
            ),
            toolCallID: "call-persona-3"
        )
        guard case .success(let resumedResult) = resumed,
              let resumedID = resumedResult.value["subagent_id"]?.stringValue else {
            Issue.record("persona resume failed: \(resumed)")
            return
        }
        let recorded = await host.bookkeeping[resumedID]?.persona
        #expect(recorded == "probe")
    }
}
