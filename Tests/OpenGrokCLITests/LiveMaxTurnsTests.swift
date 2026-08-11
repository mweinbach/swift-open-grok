// LiveMaxTurnsTests.swift
//
// Proves `--max-turns` is honored through the live turn loop (AGENTS.md §3):
// parsed on launch options, not refused at validation, and enforced in
// `LiveShellSamplingDriver.runTurn` with the same counter semantics as
// upstream turn.rs:2347,3130-3140.

import Foundation
import Testing
import OpenGrokModels
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase
import OpenGrokTestSupport
@testable import OpenGrokCLI

// MARK: - Canned sampler

private actor MaxTurnsSamplerStore {
    private var queue: [OpenGrokLiveSamplingResponse] = []
    private(set) var sampleCount = 0

    func enqueue(_ responses: [OpenGrokLiveSamplingResponse]) {
        queue.append(contentsOf: responses)
    }

    func next(turnID: String, tools: [ToolSpec]) throws -> OpenGrokLiveSamplingResponse {
        if tools.isEmpty && turnID.hasPrefix("compaction-") {
            return OpenGrokLiveSamplingResponse(output: "compacted summary")
        }
        sampleCount += 1
        if !queue.isEmpty {
            return queue.removeFirst()
        }
        return OpenGrokLiveSamplingResponse(output: "done")
    }
}

private func makeMaxTurnsSampler(_ store: MaxTurnsSamplerStore) -> OpenGrokLiveSampler {
    OpenGrokLiveSampler { request, _ in
        try await store.next(turnID: request.turnID, tools: request.tools)
    }
}

private func toolCallResponse(callId: String, name: String, args: String) -> OpenGrokLiveSamplingResponse {
    OpenGrokLiveSamplingResponse(
        output: "",
        toolCalls: [ToolCall(id: callId, name: name, arguments: args)]
    )
}

// MARK: - Fixture

private struct MaxTurnsFixture {
    let home: URL
    let workspace: URL
    let server: MockInferenceServer
    let environment: [String: String]

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-max-turns-\(UUID().uuidString)", isDirectory: true)
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

    func launchOptions(maxTurns: UInt32) throws -> CLIExecutionOptions {
        let command = try CLICommandParser.parseOrThrow([
            "headless",
            "--prompt", "hello",
            "--cwd", workspace.path,
            "--max-turns", String(maxTurns),
        ])
        guard case .launch(let options) = command else {
            throw CLIApplicationError.failed("fixture did not parse to a launch")
        }
        return options
    }

    func context() -> CLIApplicationContext {
        CLIApplicationContext(
            environment: environment,
            streams: CLIStreams(out: { _ in }, err: { _ in }),
            control: .never
        )
    }
}

// MARK: - Tests

@Suite("Live max-turns enforcement", .serialized)
struct LiveMaxTurnsTests {
    @Test("parsed --max-turns lands on CLIAgentOptions")
    func parsedOnAgentOptions() throws {
        let command = try CLICommandParser.parseOrThrow([
            "headless",
            "--prompt", "hi",
            "--max-turns", "5",
        ])
        guard case .launch(let options) = command else {
            Issue.record("expected launch command, got \(command)")
            return
        }
        #expect(options.agentOptions.maxTurns == 5)
    }

    @Test("--max-turns is not refused at launch validation")
    func notRefusedAtValidation() async throws {
        let fixture = try MaxTurnsFixture()
        defer { fixture.dispose() }

        let store = MaxTurnsSamplerStore()
        await store.enqueue([OpenGrokLiveSamplingResponse(output: "ok")])

        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in makeMaxTurnsSampler(store) }
        )

        let foundation = try await OpenGrokLiveApplicationLauncher.makeSessionFoundation(
            options: fixture.launchOptions(maxTurns: 3),
            context: fixture.context(),
            dependencies: dependencies
        )
        #expect(foundation.options.agentOptions.maxTurns == 3)
    }

    @Test("maxTurns 1 stops after one sampler round when tools continue")
    func maxTurnsOneStopsAfterFirstRound() async throws {
        let fixture = try MaxTurnsFixture()
        defer { fixture.dispose() }

        let store = MaxTurnsSamplerStore()
        await store.enqueue([
            toolCallResponse(
                callId: "call-1",
                name: "todo_write",
                args: #"{"todos":[{"id":"1","content":"do it","status":"pending"}]}"#
            ),
            OpenGrokLiveSamplingResponse(output: "should not reach second sample"),
        ])

        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in makeMaxTurnsSampler(store) }
        )

        let foundation = try await OpenGrokLiveApplicationLauncher.makeSessionFoundation(
            options: fixture.launchOptions(maxTurns: 1),
            context: fixture.context(),
            dependencies: dependencies
        )
        let stack = await OpenGrokLiveApplicationLauncher.makeAgentStack(
            foundation: foundation,
            context: fixture.context(),
            dependencies: dependencies
        )

        let shell = stack.shell
        _ = try await shell.start()
        let sessionID = SessionID(foundation.sessionID)
        _ = try await shell.createSession(OpenGrokShellSessionRequest(
            sessionID: sessionID,
            cwd: foundation.cwd,
            providerConfiguration: foundation.providerConfiguration
        ))

        let handle = try await shell.submitTurn(
            sessionID: sessionID,
            request: OpenGrokShellTurnRequest(promptID: "p1", text: "keep calling tools", turnID: "t1")
        )
        let result = try await shell.waitForTurn(handle, timeout: ShellDuration(timeInterval: 30))

        #expect(await store.sampleCount == 1)
        #expect(result.stopReason == "max_turns_reached")
    }

    @Test("maxTurns 2 allows two sampler rounds then stops")
    func maxTurnsTwoAllowsTwoRounds() async throws {
        let fixture = try MaxTurnsFixture()
        defer { fixture.dispose() }

        let store = MaxTurnsSamplerStore()
        await store.enqueue([
            toolCallResponse(
                callId: "call-1",
                name: "todo_write",
                args: #"{"todos":[{"id":"1","content":"first","status":"pending"}]}"#
            ),
            toolCallResponse(
                callId: "call-2",
                name: "todo_write",
                args: #"{"todos":[{"id":"2","content":"second","status":"pending"}]}"#
            ),
            OpenGrokLiveSamplingResponse(output: "should not reach third sample"),
        ])

        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in makeMaxTurnsSampler(store) }
        )

        let foundation = try await OpenGrokLiveApplicationLauncher.makeSessionFoundation(
            options: fixture.launchOptions(maxTurns: 2),
            context: fixture.context(),
            dependencies: dependencies
        )
        let stack = await OpenGrokLiveApplicationLauncher.makeAgentStack(
            foundation: foundation,
            context: fixture.context(),
            dependencies: dependencies
        )

        let shell = stack.shell
        _ = try await shell.start()
        let sessionID = SessionID(foundation.sessionID)
        _ = try await shell.createSession(OpenGrokShellSessionRequest(
            sessionID: sessionID,
            cwd: foundation.cwd,
            providerConfiguration: foundation.providerConfiguration
        ))

        let handle = try await shell.submitTurn(
            sessionID: sessionID,
            request: OpenGrokShellTurnRequest(promptID: "p1", text: "two rounds only", turnID: "t1")
        )
        let result = try await shell.waitForTurn(handle, timeout: ShellDuration(timeInterval: 30))

        #expect(await store.sampleCount == 2)
        #expect(result.stopReason == "max_turns_reached")
    }
}
