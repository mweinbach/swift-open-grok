// LiveSubagentChildEffortTests.swift
//
// Child reasoning effort at sample time (Rust handle_request.rs:705-714):
// `runtime.reasoningEffort` must reach `OpenGrokLiveSamplingRequest` and win
// over the parent sampler config default. Asserted through the live seam —
// real foundation, real host.spawn, production sampler against the mock
// server — so a wiring regression fails here, not only a library unit.

import Foundation
import Testing
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShell
import OpenGrokTestSupport
@testable import OpenGrokCLI

// MARK: - Fixture

private struct ChildEffortFixture {
    let home: URL
    let workspace: URL
    let server: MockInferenceServer
    let environment: [String: String]

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-child-effort-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        server = try MockInferenceServer()
        try """
            [endpoints]
            xai_api_base_url = "\(server.url)"
            """.write(
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

    /// User-scope persona carrying `reasoning_effort` — the runtime field
    /// `runChild` parses onto the sampling request.
    func writeEffortPersona(name: String, effort: String) throws {
        let directory = home.appendingPathComponent("personas", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try """
            instructions = "effort persona"
            reasoning_effort = "\(effort)"
            """.write(
                to: directory.appendingPathComponent("\(name).toml"),
                atomically: true,
                encoding: .utf8
            )
    }

    func makeFoundation() async throws -> OpenGrokLiveApplicationLauncher.LiveSessionFoundation {
        let command = try CLICommandParser.parseOrThrow(
            ["headless", "--prompt", "hello", "--cwd", workspace.path, "--model", "grok-4.5"]
        )
        guard case .launch(let options) = command else {
            throw CLIApplicationError.failed("fixture did not parse to a launch")
        }
        return try await OpenGrokLiveApplicationLauncher.makeSessionFoundation(
            options: options,
            context: CLIApplicationContext(
                environment: environment,
                streams: CLIStreams(out: { _ in }, err: { _ in }),
                control: .never
            ),
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

    func lastResponsesEntry() -> LogEntry? {
        server.requests()
            .last { $0.method == "POST" && $0.path.contains("responses") }
    }
}

// MARK: - Request struct

@Suite("OpenGrokLiveSamplingRequest child effort", .serialized)
struct OpenGrokLiveSamplingRequestEffortTests {
    @Test("OpenGrokLiveSamplingRequest stores a per-request reasoningEffort")
    func requestCarriesEffort() {
        let withEffort = OpenGrokLiveSamplingRequest(
            sessionID: "s",
            turnID: "t",
            model: "grok-4.5",
            prompt: "hi",
            reasoningEffort: .low
        )
        #expect(withEffort.reasoningEffort == .low)

        let defaulted = OpenGrokLiveSamplingRequest(
            sessionID: "s",
            turnID: "t",
            model: "grok-4.5",
            prompt: "hi"
        )
        #expect(defaulted.reasoningEffort == nil)
    }

    @Test("an unparseable runtime effort token yields no override")
    func unparseableTokenIsNoOverride() {
        // Documented policy in LiveSubagentHost.runChild: non-nil but unknown
        // tokens flatMap to nil so the parent sampler default still applies.
        #expect(parseCanonicalEffortToken("turbo") == nil)
        #expect(parseCanonicalEffortToken("low") == .low)
    }
}

// MARK: - Live seam

@Suite("subagent child reasoning effort through the live seam", .serialized)
struct LiveSubagentChildEffortTests {
    /// Persona `reasoning_effort = "low"` must win over grok-4.5's catalog
    /// default (`high`) on the child's outbound Responses body — the exact
    /// failure this slice closes (parent sampler sampled with no override).
    @Test("persona reasoning_effort reaches the child wire and overrides the parent default")
    func personaEffortReachesChildWire() async throws {
        let fixture = try ChildEffortFixture()
        defer { fixture.dispose() }
        try fixture.writeEffortPersona(name: "probe", effort: "low")
        try fixture.enqueueChildTurn("child done")

        let foundation = try await fixture.makeFoundation()
        defer { Task { await foundation.toolExecutor.shutdown() } }
        // Parent config still carries the catalog default — the child must
        // NOT silently inherit it when the persona asks for low.
        #expect(foundation.samplingConfiguration.reasoningEffort == .high)
        let host = try #require(foundation.subagentHost)

        let result = await host.spawn(
            args: OpenGrokShared.JSONValue.object([
                "prompt": .string("run the probe"),
                "description": .string("effort probe"),
                "subagent_type": .string("general-purpose"),
                "background": .bool(false),
            ]),
            toolCallID: "call-effort-1",
            persona: "probe"
        )
        guard case .success = result else {
            Issue.record("effort persona spawn failed: \(result)")
            return
        }

        let body = fixture.lastResponsesEntry()?.body
        #expect(body?["reasoning"]["effort"].stringValue == "low",
                "child must override parent catalog default high with persona low")
    }

    /// Recording-sampler proof that `runChild` puts the parsed effort on the
    /// sampling request itself — not only that the wire eventually carries
    /// it through config defaults.
    @Test("LiveSubagentHost puts parsed runtime effort on OpenGrokLiveSamplingRequest")
    func hostPassesEffortOnSamplingRequest() async throws {
        let fixture = try ChildEffortFixture()
        defer { fixture.dispose() }
        try fixture.writeEffortPersona(name: "probe", effort: "medium")

        final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var requests: [OpenGrokLiveSamplingRequest] = []
            func append(_ request: OpenGrokLiveSamplingRequest) {
                lock.lock(); defer { lock.unlock() }
                requests.append(request)
            }
            func snapshot() -> [OpenGrokLiveSamplingRequest] {
                lock.lock(); defer { lock.unlock() }
                return requests
            }
        }
        let recorder = Recorder()

        let foundation = try await OpenGrokLiveApplicationLauncher.makeSessionFoundation(
            options: {
                let command = try CLICommandParser.parseOrThrow(
                    ["headless", "--prompt", "hello", "--cwd", fixture.workspace.path, "--model", "grok-4.5"]
                )
                guard case .launch(let options) = command else {
                    throw CLIApplicationError.failed("fixture did not parse to a launch")
                }
                return options
            }(),
            context: CLIApplicationContext(
                environment: fixture.environment,
                streams: CLIStreams(out: { _ in }, err: { _ in }),
                control: .never
            ),
            dependencies: OpenGrokLiveCompositionDependencies(
                makeSampler: { _ in
                    OpenGrokLiveSampler { request, _ in
                        recorder.append(request)
                        return OpenGrokLiveSamplingResponse(output: "done")
                    }
                }
            )
        )
        defer { Task { await foundation.toolExecutor.shutdown() } }
        let host = try #require(foundation.subagentHost)

        let result = await host.spawn(
            args: OpenGrokShared.JSONValue.object([
                "prompt": .string("run the probe"),
                "description": .string("effort probe"),
                "subagent_type": .string("general-purpose"),
                "background": .bool(false),
            ]),
            toolCallID: "call-effort-2",
            persona: "probe"
        )
        guard case .success = result else {
            Issue.record("effort persona spawn failed: \(result)")
            return
        }

        // The child's sample uses the child id as sessionID, never the root's.
        let childSample = recorder.snapshot().first { $0.sessionID != foundation.sessionID }
        let request = try #require(childSample)
        #expect(request.reasoningEffort == .medium)
    }
}
