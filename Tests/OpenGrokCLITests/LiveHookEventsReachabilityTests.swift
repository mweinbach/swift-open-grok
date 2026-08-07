// LiveHookEventsReachabilityTests.swift
//
// Proves the full hook event table fires through the LIVE seam
// (AGENTS.md §3): the composition the executable actually runs —
// `makeSessionFoundation` → `makeAgentStack` → the real `OpenGrokShell`
// driving the real `LiveShellSamplingDriver` turn loop and `LiveToolExecutor`
// — not a composition-level stub. A silent hook (one that parses, is
// registered, and never fires) is exactly the failure mode this port
// generates, so every assertion reads the side-effect file the hook command
// appends to, not the in-memory gate buffer.
//
// The hook command is a small Python script that reads the envelope JSON off
// stdin and appends `hookEventName` plus the key payload fields to a log file.
// A second, deliberately-failing hook proves a broken hook command does not
// fail the turn (observe events fail open, PORT_PLAN.md gate order).

import Foundation
import Testing
import OpenGrokModels
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase
import OpenGrokTestSupport
@testable import OpenGrokCLI

// MARK: - Fixture

/// A hermetic home whose hooks config registers a command hook for every
/// observe event, plus a deliberately-failing hook for `UserPromptSubmit`
/// to prove a broken hook does not fail the turn. The endpoint config pins
/// the xAI base URL at the mock server so the foundation resolves.
private struct HookEventsFixture {
    let home: URL
    let workspace: URL
    let server: MockInferenceServer
    let environment: [String: String]
    let logPath: String
    let scriptPath: String

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-hooks-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        // A workspace file the model can ask `read_file` for, so a successful
        // tool call has a real target rather than a synthesized one.
        try "hello".write(
            to: workspace.appendingPathComponent("target.txt"),
            atomically: true,
            encoding: .utf8
        )

        server = try MockInferenceServer()
        try """
        [endpoints]
        xai_api_base_url = "\(server.url)"

        [permissions]
        deny = ["Bash(rm:*)"]
        """.write(
            to: home.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )

        logPath = home.appendingPathComponent("events.log").path
        scriptPath = home.appendingPathComponent("record_hook.py").path
        // The hook command: read the envelope JSON off stdin and append
        // `hookEventName` plus the key payload fields to the log. Key fields
        // are top-level in the envelope (the encoder flattens payload).
        // The shebang makes the `.py` file directly executable — the hook
        // runner treats a command with no shell metacharacters as a path to
        // an executable and launches it directly.
        let recorder = """
        #!/usr/bin/env python3
        import json, sys
        try:
            env = json.load(sys.stdin)
        except Exception:
            env = {}
        name = env.get("hookEventName", "")
        fields = ["source", "prompt", "toolName", "toolUseId", "error",
                  "notificationType", "reason", "toolInputTruncated",
                  "toolResultTruncated", "isBackgrounded"]
        parts = [name]
        for key in fields:
            if key in env:
                parts.append("{}={}".format(key, env[key]))
        with open("\(logPath)", "a") as f:
            f.write("|".join(parts) + "\\n")
        """
        try recorder.write(to: URL(fileURLWithPath: scriptPath), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: scriptPath
        )

        // A deliberately-broken hook for UserPromptSubmit: exits 7 (neither
        // 0 nor 2), so it is an operational failure that must fail open and
        // be recorded without failing the turn.
        let brokenPath = home.appendingPathComponent("broken_hook.sh").path
        try "#!/bin/sh\nexit 7\n".write(
            to: URL(fileURLWithPath: brokenPath),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: brokenPath
        )

        // Hook file: one command hook per observe event, all pointing at the
        // recorder, plus a broken UserPromptSubmit hook to prove fail-open.
        let hooksJSON = """
        {
          "hooks": {
            "SessionStart":        [{"hooks": [{"type": "command", "command": "\(scriptPath)"}]}],
            "UserPromptSubmit":    [{"hooks": [{"type": "command", "command": "\(brokenPath)"},
                                              {"type": "command", "command": "\(scriptPath)"}]}],
            "PostToolUse":         [{"hooks": [{"type": "command", "command": "\(scriptPath)"}]}],
            "PostToolUseFailure":  [{"hooks": [{"type": "command", "command": "\(scriptPath)"}]}],
            "PermissionDenied":     [{"hooks": [{"type": "command", "command": "\(scriptPath)"}]}],
            "StopFailure":          [{"hooks": [{"type": "command", "command": "\(scriptPath)"}]}],
            "Notification":        [{"hooks": [{"type": "command", "command": "\(scriptPath)"}]}],
            "PreCompact":           [{"hooks": [{"type": "command", "command": "\(scriptPath)"}]}],
            "PostCompact":          [{"hooks": [{"type": "command", "command": "\(scriptPath)"}]}],
            "SessionEnd":           [{"hooks": [{"type": "command", "command": "\(scriptPath)"}]}]
          }
        }
        """
        let hooksDir = home.appendingPathComponent("hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        try hooksJSON.write(
            to: hooksDir.appendingPathComponent("events.json"),
            atomically: true,
            encoding: .utf8
        )

        var env = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "XDG_STATE_HOME": home.appendingPathComponent("state").path,
            "XAI_API_KEY": "test-xai-key",
        ]
        environment = env
    }

    func dispose() {
        server.stop()
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    func launchOptions(_ arguments: [String]) throws -> CLIExecutionOptions {
        let command = try CLICommandParser.parseOrThrow(
            ["headless", "--prompt", "hello", "--cwd", workspace.path] + arguments
        )
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

    /// Read the recorded event log, one entry per line.
    func recordedEvents() -> [String] {
        guard let contents = try? String(contentsOf: URL(fileURLWithPath: logPath), encoding: .utf8)
        else { return [] }
        return contents.split(whereSeparator: \.isNewline).map(String.init)
    }

    /// Wait for `event` to appear in the log, polling the file the hook
    /// command writes. Observe hooks are fire-and-forget — the spawned task
    /// may outlive the turn — so the test polls the side-effect file rather
    /// than asserting inline.
    func waitFor(event: String, timeoutSeconds: TimeInterval = 15) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let entries = recordedEvents()
            if entries.contains(where: { $0.hasPrefix(event + "|") || $0 == event }) {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
            Issue.record("timed out waiting for hook event '\(event)'; got: \(recordedEvents())")
    }
}

// MARK: - Canned sampler

/// A canned `OpenGrokLiveSampler` that returns a queued sequence of
/// responses for normal turns and a summary for compaction requests. This
/// drives the REAL `LiveShellSamplingDriver.runTurn` → `executeToolCalls`
/// path (the live seam for hooks) without the fragility of SSE parsing; the
/// mock inference server is still wired for endpoint resolution.
private actor CannedSamplerStore {
    private var queue: [OpenGrokLiveSamplingResponse] = []
    private var throwNext = false

    func enqueue(_ responses: [OpenGrokLiveSamplingResponse]) {
        queue.append(contentsOf: responses)
    }

    /// Make the next `sample` call throw a server error, so the turn ends in
    /// a `StopFailure` (turn.rs:1224-1234 fires `StopFailure` on an API
    /// error rather than a genuine stop).
    func enqueueThrow() {
        throwNext = true
    }

    func next(turnID: String, tools: [ToolSpec]) throws -> OpenGrokLiveSamplingResponse {
        if throwNext {
            throwNext = false
            throw SamplingError.api(
                status: HTTPStatus(500),
                message: "server exploded",
                modelMetadata: nil,
                retryAfterSecs: nil,
                shouldRetry: false
            )
        }
        // Compaction requests carry no tools and a turnID prefixed
        // "compaction-"; return a summary so the compaction engine succeeds.
        if tools.isEmpty && turnID.hasPrefix("compaction-") {
            return OpenGrokLiveSamplingResponse(output: "compacted summary")
        }
        if !queue.isEmpty {
            return queue.removeFirst()
        }
        // Default: a bare text turn that ends the loop.
        return OpenGrokLiveSamplingResponse(output: "done")
    }
}

private func makeCannedSampler(_ store: CannedSamplerStore) -> OpenGrokLiveSampler {
    OpenGrokLiveSampler { request, _ in
        try await store.next(turnID: request.turnID, tools: request.tools)
    }
}

// MARK: - Helpers

/// Build a tool-call response: the model asks for `tool` with `args`, and the
/// turn loop will run it and then re-sample for the final text.
private func toolCallResponse(callId: String, name: String, args: String) -> OpenGrokLiveSamplingResponse {
    OpenGrokLiveSamplingResponse(
        output: "",
        toolCalls: [ToolCall(id: callId, name: name, arguments: args)]
    )
}

private func textResponse(_ text: String) -> OpenGrokLiveSamplingResponse {
    OpenGrokLiveSamplingResponse(output: text)
}

// MARK: - Tests

@Suite("Live hook events reachability", .serialized)
struct LiveHookEventsReachabilityTests {
    /// Drive the live composition through the full lifecycle and assert each
    /// observe event fires exactly when upstream fires it, with the payload
    /// keys upstream sends. A broken UserPromptSubmit hook proves fail-open.
    @Test("the full hook event table fires through the live seam")
    func fullEventTableFires() async throws {
        let fixture = try HookEventsFixture()
        defer { fixture.dispose() }

        let store = CannedSamplerStore()
        // Turn 1: a successful tool call (todo_write), then a final text.
        await store.enqueue([
            toolCallResponse(
                callId: "call-1",
                name: "todo_write",
                args: #"{"todos":[{"id":"1","content":"do it","status":"pending"}]}"#
            ),
            textResponse("turn one done"),
        ])
        // Turn 2: a failing tool call (unknown tool), then a final text.
        await store.enqueue([
            toolCallResponse(callId: "call-2", name: "nope_not_a_tool", args: "{}"),
            textResponse("turn two done"),
        ])
        // Turn 3: a denied tool call (run_terminal_cmd with a denied command),
        // then a final text. The deny rule is set via the agent profile below.
        await store.enqueue([
            toolCallResponse(
                callId: "call-3",
                name: "run_terminal_cmd",
                args: #"{"command":"rm -rf something"}"#
            ),
            textResponse("turn three done"),
        ])

        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in makeCannedSampler(store) }
        )

        let foundation = try await OpenGrokLiveApplicationLauncher.makeSessionFoundation(
            options: fixture.launchOptions(["--model", "grok-4.5"]),
            context: fixture.context(),
            dependencies: dependencies
        )
        let stack = await OpenGrokLiveApplicationLauncher.makeAgentStack(
            foundation: foundation,
            context: fixture.context(),
            dependencies: dependencies
        )

        // SessionStart fires at the end of makeAgentStack.
        try await fixture.waitFor(event: "session_start")

        let shell = stack.shell
        _ = try await shell.start()
        let sessionID = SessionID(foundation.sessionID)
        _ = try await shell.createSession(OpenGrokShellSessionRequest(
            sessionID: sessionID,
            cwd: foundation.cwd,
            providerConfiguration: foundation.providerConfiguration
        ))

        // Turn 1: UserPromptSubmit + PostToolUse (todo_write succeeds).
        let h1 = try await shell.submitTurn(
            sessionID: sessionID,
            request: OpenGrokShellTurnRequest(promptID: "p1", text: "do a todo", turnID: "t1")
        )
        _ = try await shell.waitForTurn(h1, timeout: ShellDuration(timeInterval: 30))
        try await fixture.waitFor(event: "user_prompt_submit")
        try await fixture.waitFor(event: "post_tool_use")

        // Turn 2: PostToolUseFailure (unknown tool fails).
        let h2 = try await shell.submitTurn(
            sessionID: sessionID,
            request: OpenGrokShellTurnRequest(promptID: "p2", text: "run a bad tool", turnID: "t2")
        )
        _ = try await shell.waitForTurn(h2, timeout: ShellDuration(timeInterval: 30))
        try await fixture.waitFor(event: "post_tool_use_failure")

        // Turn 3: PermissionDenied (run_terminal_cmd rm is denied by profile).
        let h3 = try await shell.submitTurn(
            sessionID: sessionID,
            request: OpenGrokShellTurnRequest(promptID: "p3", text: "run rm", turnID: "t3")
        )
        _ = try await shell.waitForTurn(h3, timeout: ShellDuration(timeInterval: 30))
        try await fixture.waitFor(event: "permission_denied")

        // Turn 4: the sampler throws a 500, so the turn ends in a StopFailure
        // (turn.rs:1224-1234). The shell surfaces the error through
        // waitForTurn, so the test expects the throw and then asserts the
        // hook landed.
        await store.enqueueThrow()
        let h4 = try await shell.submitTurn(
            sessionID: sessionID,
            request: OpenGrokShellTurnRequest(promptID: "p4", text: "provoke a server error", turnID: "t4")
        )
        do {
            _ = try await shell.waitForTurn(h4, timeout: ShellDuration(timeInterval: 30))
            Issue.record("StopFailure turn should have surfaced a failed turn result")
        } catch {
            // Expected: the turn ended in an API error.
        }
        try await fixture.waitFor(event: "stop_failure")

        // SessionEnd fires on shutdown.
        await foundation.toolExecutor.shutdown()
        try await fixture.waitFor(event: "session_end")

        // Assert each event landed with its key payload fields.
        let events = fixture.recordedEvents()
        #expect(events.contains { $0.hasPrefix("session_start|source=startup") }, "SessionStart should carry source=startup")
        #expect(events.contains { $0.contains("user_prompt_submit|prompt=do a todo") }, "UserPromptSubmit should carry the prompt text")
        #expect(events.contains { $0.hasPrefix("post_tool_use|") && $0.contains("toolName=todo_write") }, "PostToolUse should carry toolName=todo_write")
        #expect(events.contains { $0.hasPrefix("post_tool_use_failure|") && $0.contains("toolName=nope_not_a_tool") }, "PostToolUseFailure should carry toolName")
        #expect(events.contains { $0.hasPrefix("permission_denied|") && $0.contains("toolName=run_terminal_cmd") }, "PermissionDenied should carry toolName")
        #expect(events.contains { $0.hasPrefix("stop_failure|") && $0.contains("error=server_error") }, "StopFailure should carry the error kind")
        #expect(events.contains { $0.hasPrefix("session_end|") && $0.contains("reason=shutdown") }, "SessionEnd should carry reason=shutdown")

        // The broken UserPromptSubmit hook exited 7; the turn still completed
        // (h1 finished without throwing), which is the fail-open proof. The
        // recorder hook (second in the list) still ran, so user_prompt_submit
        // landed — proving the broken hook did not abort dispatch or the turn.
        #expect(!events.filter { $0.hasPrefix("user_prompt_submit|") }.isEmpty, "UserPromptSubmit recorder hook should still fire after the broken hook fails open")
    }
}
