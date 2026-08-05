import Foundation
import OpenGrokConfig
import OpenGrokHooks
import OpenGrokHooksPluginTypes
import Testing

@Suite("OpenGrok hooks")
struct OpenGrokHooksTests {
    @Test("matcher preserves exact and regex semantics")
    func matcherSemantics() throws {
        let exact = try HookMatcher(pattern: "Bash|Read")
        #expect(exact.isMatch("Bash"))
        #expect(exact.isMatch("run_terminal_command"))
        #expect(exact.isMatch("read_file"))
        #expect(!exact.isMatch("my_read_file"))

        let regex = try HookMatcher(pattern: "^Bash$")
        #expect(regex.isMatch("Bash"))
        #expect(regex.isMatch("run_terminal_command"))
        #expect(!regex.isMatch("read_file"))
        #expect(throws: HookMatcherError.self) {
            _ = try HookMatcher(pattern: "[invalid")
        }
    }

    @Test("environment expansion resolves extra values and preserves deferred forms")
    func environmentExpansion() {
        let expanded = expandHookEnvironment(
            "${HOOK_ROOT}/check ${MISSING} ${VALUE:-fallback} $PLAIN",
            extra: ["HOOK_ROOT": "/plugin", "PLAIN": "value"],
            environment: [:]
        )
        #expect(expanded == "/plugin/check ${MISSING} ${VALUE:-fallback} value")
    }

    @Test("JSON configuration skips unknown events and applies stop timeout")
    func jsonConfiguration() {
        let path = URL(fileURLWithPath: "/tmp/settings.json")
        let json = #"{"hooks":{"UnknownEvent":[{"hooks":[{"type":"command","command":"ignored.sh"}]}],"Stop":[{"matcher":"*","hooks":[{"type":"command","command":"verify.sh"}]}],"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"${ROOT}/check.sh","timeout":2,"env":{"ROOT":"/workspace"}}]}]}}"#
        let result = parseHookFile(json, path: path, environment: [:])
        #expect(result.errors.isEmpty)
        #expect(result.specs.count == 2)
        #expect(result.skippedEvents == ["UnknownEvent"])
        let pre = result.specs.first { $0.event == .preToolUse }
        #expect(pre?.command == "/workspace/check.sh")
        #expect(pre?.timeoutMs == 2_000)
        let stop = result.specs.first { $0.event == .stop }
        #expect(stop?.timeoutMs == defaultStopHookTimeoutMs)
        #expect(stop?.matcher == nil)
        #expect(stop?.configuredMatcher == "*")
    }

    @Test("TOML configuration is lenient per malformed event")
    func tomlConfiguration() throws {
        let value = try parseTOMLTable(#"hooks = { PreToolUse = [{ hooks = [{ type = "command", command = "check.sh" }] }], Broken = "skip" }"#)
        let result = parseHooksFromTOML(.table(value["hooks"]?.table ?? TOMLTable()), sourceName: "user", sourcePath: URL(fileURLWithPath: "/tmp/config.toml"), environment: [:])
        #expect(result.specs.count == 1)
        #expect(result.skippedEvents == ["Broken"])
    }

    @Test("discovery is deterministic, first-wins, and isolated by OPENGROK_HOME")
    func discoveryAndDeduplication() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let global = root.appendingPathComponent("global")
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: global, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let hook = #"{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"same.sh"}]}]}}"#
        try hook.write(to: global.appendingPathComponent("01-first.json"), atomically: true, encoding: .utf8)
        try hook.write(to: global.appendingPathComponent("02-second.json"), atomically: true, encoding: .utf8)
        try hook.write(to: project.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)
        try "ignored".write(to: global.appendingPathComponent(".hidden.json"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = HookDiscovery.load(globalDirectory: global, projectDirectory: project, environment: ["OPENGROK_HOME": root.appendingPathComponent("isolated").path])
        let hooks = result.registry.hooks(for: .sessionStart)
        #expect(result.errors.isEmpty)
        #expect(hooks.count == 1)
        #expect(hooks[0].name.hasPrefix("global/"))
        #expect(!HookDiscovery.defaultDirectories(workspaceRoot: root, environment: ["OPENGROK_HOME": root.appendingPathComponent("isolated").path]).global.path.contains(".grok"))
    }

    @Test("envelope flattens payload with camelCase keys")
    func envelopeEncoding() throws {
        let envelope = HookEventEnvelope(
            hookEventName: .preToolUse,
            sessionId: "session-1",
            cwd: "/workspace",
            workspaceRoot: "/workspace",
            timestamp: "2026-08-04T00:00:00Z",
            payload: [
                "toolName": .string("run_terminal_command"),
                "toolInput": .object(["command": .string("pwd")])
            ]
        )
        let object = try JSONSerialization.jsonObject(with: envelope.jsonData()) as? [String: Any]
        #expect(object?["hookEventName"] as? String == "pre_tool_use")
        #expect(object?["sessionId"] as? String == "session-1")
        #expect(object?["toolName"] as? String == "run_terminal_command")
        #expect(object?["toolInput"] != nil)
        #expect(object?["hook_event_name"] == nil)
    }

    @Test("command hooks honor explicit deny and stop the pre-tool chain")
    func commandDenyStopsChain() async {
        let first = HookSpec(name: "first", event: .preToolUse, handlerType: .command, command: #"printf '{"decision":"deny","reason":"first-deny"}'"#, commandRaw: "first", timeoutMs: 1_000, sourceDirectory: URL(fileURLWithPath: "/tmp"))
        let second = HookSpec(name: "second", event: .preToolUse, handlerType: .command, command: #"printf '{"decision":"deny","reason":"second-deny"}'"#, commandRaw: "second", timeoutMs: 1_000, sourceDirectory: URL(fileURLWithPath: "/tmp"))
        let dispatcher = HookDispatcher(registry: HookRegistry(specs: [first, second]), disabledNames: [])
        let envelope = HookEventEnvelope(hookEventName: .preToolUse, sessionId: "s", cwd: "/tmp", workspaceRoot: "/tmp", payload: ["toolName": .string("run_terminal_command")])
        let result = await dispatcher.dispatchPreToolUse(envelope: envelope, context: HookRunContext(sessionId: "s", workspaceRoot: URL(fileURLWithPath: "/tmp")))
        #expect(result.decision == .deny(reason: "first-deny", hookName: "first"))
        #expect(result.results.count == 1)
    }

    @Test("command hook failures are fail-open")
    func commandFailureIsFailOpen() async {
        let failing = HookSpec(name: "failing", event: .preToolUse, handlerType: .command, command: #"exit 9"#, commandRaw: "exit 9", timeoutMs: 1_000, sourceDirectory: URL(fileURLWithPath: "/tmp"))
        let dispatcher = HookDispatcher(registry: HookRegistry(specs: [failing]), disabledNames: [])
        let envelope = HookEventEnvelope(hookEventName: .preToolUse, sessionId: "s", cwd: "/tmp", workspaceRoot: "/tmp", payload: ["toolName": .string("run_terminal_command")])
        let result = await dispatcher.dispatchPreToolUse(envelope: envelope, context: HookRunContext(sessionId: "s", workspaceRoot: URL(fileURLWithPath: "/tmp")))
        #expect(result.decision == .allow)
        #expect(result.results.first?.state == .failed)
    }

    @Test("command timeout and cancellation return without blocking")
    func commandTimeoutAndCancellation() async {
        let timeoutSpec = HookSpec(name: "timeout", event: .sessionStart, handlerType: .command, command: "sleep 30", commandRaw: "sleep 30", timeoutMs: 20, sourceDirectory: URL(fileURLWithPath: "/tmp"))
        let envelope = HookEventEnvelope(hookEventName: .sessionStart, sessionId: "s", cwd: "/tmp", workspaceRoot: "/tmp")
        let timedOut = await HookRunner.run(spec: timeoutSpec, envelope: envelope, context: HookRunContext(sessionId: "s", workspaceRoot: URL(fileURLWithPath: "/tmp")), mode: .observe)
        #expect(timedOut.result == .failed("timed out after 20ms"))

        let cancellationSpec = HookSpec(name: "cancel", event: .sessionStart, handlerType: .command, command: "sleep 5", commandRaw: "sleep 5", timeoutMs: 10_000, sourceDirectory: URL(fileURLWithPath: "/tmp"))
        let task = Task {
            await HookRunner.run(spec: cancellationSpec, envelope: envelope, context: HookRunContext(sessionId: "s", workspaceRoot: URL(fileURLWithPath: "/tmp")), mode: .observe)
        }
        task.cancel()
        let cancelled = await task.value
        #expect(cancelled.result == .failed("hook cancelled"))
    }

    @Test("HTTP hooks reject insecure and private literal URLs")
    func httpURLPolicy() async {
        let envelope = HookEventEnvelope(hookEventName: .sessionStart, sessionId: "s", cwd: "/tmp", workspaceRoot: "/tmp")
        for url in ["http://example.com/hook", "https://10.0.0.1/hook", "https://169.254.169.254/latest"] {
            let spec = HookSpec(name: url, event: .sessionStart, handlerType: .http, url: url, urlRaw: url, timeoutMs: 100, sourceDirectory: URL(fileURLWithPath: "/tmp"))
            let result = await HookRunner.run(spec: spec, envelope: envelope, context: HookRunContext(sessionId: "s", workspaceRoot: URL(fileURLWithPath: "/tmp")), mode: .observe)
            if case .failed = result.result { } else { Issue.record("expected URL policy failure for \(url)") }
        }
    }
}
