// HookPermissionGateTests.swift
//
// Proves the `PreToolUse` gate honors the locked order from PORT_PLAN.md:
//
//   1. plan edit gate
//   2. PreToolUse hooks — operational failures fail open but are recorded
//   3. plan-file auto-approval
//   4. permission evaluation (deny > ask > allow)
//
// The interesting cases are all about who wins: a hook deny must stop a
// dispatch that permissions would have allowed, a hook that crashes must not,
// and a hook allow must not buy a pass through permission evaluation.

import Foundation
import OpenGrokConfig
import OpenGrokHooks
import OpenGrokHooksPluginTypes
import OpenGrokShared
import OpenGrokWorkspace
import Testing

// MARK: - Fixtures

/// Writes executable shell scripts and hook specs into a scratch directory.
private struct HookFixture {
    let root: URL

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hook-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Creates a script that appends its name to `order.log` and then runs
    /// `body`, so tests can assert both the decision and the execution order.
    func script(named name: String, body: String) throws -> String {
        let path = root.appendingPathComponent("\(name).sh")
        let source = """
        #!/bin/sh
        printf '%s\\n' '\(name)' >> '\(root.appendingPathComponent("order.log").path)'
        \(body)
        """
        try source.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: path.path
        )
        return path.path
    }

    func executionOrder() -> [String] {
        guard let contents = try? String(
            contentsOf: root.appendingPathComponent("order.log"),
            encoding: .utf8
        ) else { return [] }
        return contents.split(whereSeparator: \.isNewline).map(String.init)
    }

    func spec(name: String, command: String, matcher: String? = nil) -> HookSpec {
        HookSpec(
            name: name,
            event: .preToolUse,
            handlerType: .command,
            configuredMatcher: matcher,
            matcher: matcher.flatMap { try? HookMatcher(pattern: $0) },
            command: command,
            commandRaw: command,
            timeoutMs: 10_000,
            sourceDirectory: root
        )
    }

    func gate(_ specs: [HookSpec]) -> HookPermissionGate {
        HookPermissionGate(
            dispatcher: HookDispatcher(registry: HookRegistry(specs: specs), disabledNames: []),
            context: HookSessionContext(
                sessionId: "test-session",
                workspaceRoot: root,
                environment: ProcessInfo.processInfo.environment
            )
        )
    }
}

private func readAccess(_ path: String) -> AccessKind { .read(path) }

// MARK: - Tests

@Suite("PreToolUse hook gate")
struct HookPermissionGateTests {
    @Test("a hook that denies blocks the dispatch")
    func denyBlocks() async throws {
        let fixture = try HookFixture()
        defer { fixture.cleanup() }

        let command = try fixture.script(
            named: "denier",
            body: #"printf '{"decision":"deny","reason":"blocked by policy"}\n'"#
        )
        let gate = fixture.gate([fixture.spec(name: "denier", command: command)])

        let decision = await gate.runPreToolUse(
            toolName: "read_file",
            toolCallId: "call-1",
            access: readAccess("/tmp/x"),
            permissionMode: nil
        )

        guard case .deny(let reason, let hookName) = decision else {
            Issue.record("expected a deny, got \(decision)")
            return
        }
        #expect(reason == "blocked by policy")
        #expect(hookName == "denier")

        let records = gate.recordedRuns()
        #expect(records.count == 1)
        #expect(records[0].state == .blocked)
    }

    @Test("exit code 2 with no JSON denies")
    func exitCodeTwoDenies() async throws {
        let fixture = try HookFixture()
        defer { fixture.cleanup() }

        let command = try fixture.script(named: "gate2", body: "exit 2")
        let gate = fixture.gate([fixture.spec(name: "gate2", command: command)])

        let decision = await gate.runPreToolUse(
            toolName: "read_file",
            toolCallId: "call-1",
            access: readAccess("/tmp/x"),
            permissionMode: nil
        )
        guard case .deny = decision else {
            Issue.record("expected a deny, got \(decision)")
            return
        }
    }

    @Test("an operational failure fails open and is recorded")
    func operationalFailureFailsOpen() async throws {
        let fixture = try HookFixture()
        defer { fixture.cleanup() }

        // Exit 7 is neither success (0) nor the deny gate code (2), so it is an
        // operational failure: the hook is broken, not answering.
        let crashing = try fixture.script(named: "crasher", body: "exit 7")
        let gate = fixture.gate([fixture.spec(name: "crasher", command: crashing)])

        let decision = await gate.runPreToolUse(
            toolName: "read_file",
            toolCallId: "call-1",
            access: readAccess("/tmp/x"),
            permissionMode: nil
        )
        #expect(decision == .allow)

        let records = gate.recordedRuns()
        #expect(records.count == 1)
        #expect(records[0].state == .failed)
        #expect(records[0].hookName == "crasher")
        #expect(records[0].detail != nil)
    }

    @Test("a missing hook binary fails open and is recorded")
    func missingBinaryFailsOpen() async throws {
        let fixture = try HookFixture()
        defer { fixture.cleanup() }

        let gate = fixture.gate([
            fixture.spec(name: "ghost", command: fixture.root.appendingPathComponent("nope.sh").path)
        ])

        let decision = await gate.runPreToolUse(
            toolName: "read_file",
            toolCallId: "call-1",
            access: readAccess("/tmp/x"),
            permissionMode: nil
        )
        #expect(decision == .allow)
        #expect(gate.recordedRuns().first?.state == .failed)
    }

    @Test("a timeout fails open rather than wedging the turn")
    func timeoutFailsOpen() async throws {
        let fixture = try HookFixture()
        defer { fixture.cleanup() }

        let command = try fixture.script(named: "sleeper", body: "sleep 30")
        var spec = fixture.spec(name: "sleeper", command: command)
        spec.timeoutMs = 250

        let gate = fixture.gate([spec])
        let decision = await gate.runPreToolUse(
            toolName: "read_file",
            toolCallId: "call-1",
            access: readAccess("/tmp/x"),
            permissionMode: nil
        )
        #expect(decision == .allow)
        #expect(gate.recordedRuns().first?.state == .failed)
    }

    @Test("hooks run in registration order and a deny short-circuits the rest")
    func denyShortCircuits() async throws {
        let fixture = try HookFixture()
        defer { fixture.cleanup() }

        let first = try fixture.script(named: "first", body: "exit 0")
        let denier = try fixture.script(
            named: "denier",
            body: #"printf '{"decision":"deny","reason":"stop here"}\n'"#
        )
        let never = try fixture.script(named: "never", body: "exit 0")

        let gate = fixture.gate([
            fixture.spec(name: "first", command: first),
            fixture.spec(name: "denier", command: denier),
            fixture.spec(name: "never", command: never),
        ])

        let decision = await gate.runPreToolUse(
            toolName: "read_file",
            toolCallId: "call-1",
            access: readAccess("/tmp/x"),
            permissionMode: nil
        )
        guard case .deny = decision else {
            Issue.record("expected a deny, got \(decision)")
            return
        }
        #expect(fixture.executionOrder() == ["first", "denier"])
    }

    @Test("a failing hook does not stop later hooks from denying")
    func failureDoesNotMaskLaterDeny() async throws {
        let fixture = try HookFixture()
        defer { fixture.cleanup() }

        let broken = try fixture.script(named: "broken", body: "exit 7")
        let denier = try fixture.script(
            named: "denier",
            body: #"printf '{"decision":"deny","reason":"still denied"}\n'"#
        )

        let gate = fixture.gate([
            fixture.spec(name: "broken", command: broken),
            fixture.spec(name: "denier", command: denier),
        ])

        let decision = await gate.runPreToolUse(
            toolName: "read_file",
            toolCallId: "call-1",
            access: readAccess("/tmp/x"),
            permissionMode: nil
        )
        guard case .deny(let reason, _) = decision else {
            Issue.record("expected a deny, got \(decision)")
            return
        }
        #expect(reason == "still denied")
        #expect(fixture.executionOrder() == ["broken", "denier"])

        let states = gate.recordedRuns().map(\.state)
        #expect(states == [.failed, .blocked])
    }

    @Test("a matcher that does not match skips the hook entirely")
    func matcherFiltersHooks() async throws {
        let fixture = try HookFixture()
        defer { fixture.cleanup() }

        let denier = try fixture.script(
            named: "denier",
            body: #"printf '{"decision":"deny","reason":"nope"}\n'"#
        )
        let gate = fixture.gate([
            fixture.spec(name: "denier", command: denier, matcher: "^write_file$")
        ])

        let decision = await gate.runPreToolUse(
            toolName: "read_file",
            toolCallId: "call-1",
            access: readAccess("/tmp/x"),
            permissionMode: nil
        )
        #expect(decision == .allow)
        #expect(fixture.executionOrder().isEmpty)
    }

    @Test("the envelope carries the tool name the matcher tests against")
    func envelopeCarriesToolName() async throws {
        let fixture = try HookFixture()
        defer { fixture.cleanup() }

        let capture = fixture.root.appendingPathComponent("envelope.json").path
        let command = try fixture.script(named: "capture", body: "cat > '\(capture)'")
        let gate = fixture.gate([fixture.spec(name: "capture", command: command)])

        _ = await gate.runPreToolUse(
            toolName: "search_replace",
            toolCallId: "call-42",
            access: .edit("/tmp/file.swift"),
            permissionMode: "acceptEdits"
        )

        let data = try Data(contentsOf: URL(fileURLWithPath: capture))
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["toolName"] as? String == "search_replace")
        #expect(object["toolCallId"] as? String == "call-42")
        #expect(object["accessKind"] as? String == "edit")
        #expect(object["accessDetail"] as? String == "/tmp/file.swift")
        #expect(object["permissionMode"] as? String == "acceptEdits")
        // The envelope uses the snake_case runtime wire name for the event.
        #expect(object["hookEventName"] as? String == "pre_tool_use")
    }

    @Test("with no hooks the gate allows without spawning anything")
    func emptyRegistryAllows() async throws {
        let fixture = try HookFixture()
        defer { fixture.cleanup() }

        let gate = fixture.gate([])
        #expect(!gate.hasPreToolUseHooks)

        let decision = await gate.runPreToolUse(
            toolName: "read_file",
            toolCallId: "call-1",
            access: readAccess("/tmp/x"),
            permissionMode: nil
        )
        #expect(decision == .allow)
        #expect(gate.recordedRuns().isEmpty)
    }

    @Test("a disabled hook is recorded as skipped and cannot deny")
    func disabledHookSkipped() async throws {
        let fixture = try HookFixture()
        defer { fixture.cleanup() }

        let denier = try fixture.script(
            named: "denier",
            body: #"printf '{"decision":"deny","reason":"nope"}\n'"#
        )
        var disabled = fixture.spec(name: "denier", command: denier)
        disabled.enabled = false
        let enabled = fixture.spec(
            name: "bystander",
            command: try fixture.script(named: "bystander", body: "exit 0")
        )

        let gate = fixture.gate([disabled, enabled])
        let decision = await gate.runPreToolUse(
            toolName: "read_file",
            toolCallId: "call-1",
            access: readAccess("/tmp/x"),
            permissionMode: nil
        )
        #expect(decision == .allow)
        #expect(gate.recordedRuns().map(\.state) == [.skipped, .success])
        // The disabled hook's script never ran, so it never wrote to the log.
        #expect(fixture.executionOrder() == ["bystander"])
    }

    @Test("when every hook is disabled nothing is spawned at all")
    func allHooksDisabledSpawnsNothing() async throws {
        let fixture = try HookFixture()
        defer { fixture.cleanup() }

        var spec = fixture.spec(
            name: "denier",
            command: try fixture.script(
                named: "denier",
                body: #"printf '{"decision":"deny","reason":"nope"}\n'"#
            )
        )
        spec.enabled = false

        let gate = fixture.gate([spec])
        #expect(!gate.hasPreToolUseHooks)

        let decision = await gate.runPreToolUse(
            toolName: "read_file",
            toolCallId: "call-1",
            access: readAccess("/tmp/x"),
            permissionMode: nil
        )
        #expect(decision == .allow)
        #expect(fixture.executionOrder().isEmpty)
    }
}

// MARK: - Pipeline ordering

@Suite("hook gate inside the permission pipeline")
struct HookPipelineOrderTests {
    private func makePipeline(gate: HookPermissionGate?, root: URL) -> PermissionPipeline {
        PermissionPipeline(
            permissions: PermissionHandle(
                config: PermissionConfig(),
                allowAll: true,
                shellCwd: root.path
            ),
            planMode: PlanModeTracker(sessionDirectory: root.path),
            hooks: FailOpenPreToolUseHookRunner(inner: gate)
        )
    }

    @Test("a hook deny overrides an allow-all permission config")
    func hookDenyBeatsAllowAll() async throws {
        let fixture = try HookFixture()
        defer { fixture.cleanup() }

        let denier = try fixture.script(
            named: "denier",
            body: #"printf '{"decision":"deny","reason":"policy says no"}\n'"#
        )
        let gate = fixture.gate([fixture.spec(name: "denier", command: denier)])
        let pipeline = makePipeline(gate: gate, root: fixture.root)

        let prepared = await pipeline.prepare(PrepareToolAccessRequest(
            access: .read("/tmp/x"),
            toolName: "read_file",
            toolCallId: "call-1"
        ))

        #expect(!prepared.mayDispatch)
        #expect(prepared.source == .preToolUseHook)
        #expect(prepared.reason == "hook_deny:denier")
    }

    @Test("a hook allow does not skip permission evaluation")
    func hookAllowStillReachesPermissions() async throws {
        let fixture = try HookFixture()
        defer { fixture.cleanup() }

        let permissive = try fixture.script(
            named: "permissive",
            body: #"printf '{"decision":"allow"}\n'"#
        )
        let gate = fixture.gate([fixture.spec(name: "permissive", command: permissive)])
        let pipeline = makePipeline(gate: gate, root: fixture.root)

        let prepared = await pipeline.prepare(PrepareToolAccessRequest(
            access: .read("/tmp/x"),
            toolName: "read_file",
            toolCallId: "call-1"
        ))

        // The decision comes from the permission engine, not from the hook:
        // the gate is a veto, never an authorization.
        #expect(prepared.source == .permissionEngine)
    }

    @Test("a failing hook still reaches permission evaluation")
    func failingHookFallsThroughToPermissions() async throws {
        let fixture = try HookFixture()
        defer { fixture.cleanup() }

        let broken = try fixture.script(named: "broken", body: "exit 7")
        let gate = fixture.gate([fixture.spec(name: "broken", command: broken)])
        let pipeline = makePipeline(gate: gate, root: fixture.root)

        let prepared = await pipeline.prepare(PrepareToolAccessRequest(
            access: .read("/tmp/x"),
            toolName: "read_file",
            toolCallId: "call-1"
        ))
        #expect(prepared.source == .permissionEngine)
        #expect(gate.recordedRuns().first?.state == .failed)
    }

    @Test("the plan edit gate runs before hooks")
    func planGatePrecedesHooks() async throws {
        let fixture = try HookFixture()
        defer { fixture.cleanup() }

        let denier = try fixture.script(
            named: "denier",
            body: #"printf '{"decision":"deny","reason":"hook"}\n'"#
        )
        let gate = fixture.gate([fixture.spec(name: "denier", command: denier)])

        var planMode = PlanModeTracker(sessionDirectory: fixture.root.path)
        planMode.enter()

        let pipeline = PermissionPipeline(
            permissions: PermissionHandle(
                config: PermissionConfig(),
                allowAll: true,
                shellCwd: fixture.root.path
            ),
            planMode: planMode,
            hooks: FailOpenPreToolUseHookRunner(inner: gate)
        )

        let prepared = await pipeline.prepare(PrepareToolAccessRequest(
            access: .edit("/tmp/not-the-plan.swift"),
            toolName: "search_replace",
            toolCallId: "call-1"
        ))

        // Plan mode rejects first, so the hook never runs at all.
        #expect(prepared.source == .planModeGate)
        #expect(fixture.executionOrder().isEmpty)
    }
}

// MARK: - Config loading

@Suite("hook session loading")
struct HookSessionLoadingTests {
    @Test("[hooks] blocks in the config document become PreToolUse specs")
    func loadsHooksFromConfigTOML() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hook-load-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let document = try parseTOML("""
        [[hooks.PreToolUse]]
        matcher = "read_file"

        [[hooks.PreToolUse.hooks]]
        type = "command"
        command = "/bin/true"
        timeout = 3
        """)

        let result = HookSessionLoader.load(
            configDocument: document,
            configPath: root.appendingPathComponent("config.toml"),
            workspaceRoot: root,
            environment: ["HOME": root.path, "OPENGROK_HOME": root.path],
            includeFileDiscovery: false
        )

        #expect(result.errors.isEmpty)
        let hooks = result.registry.hooks(for: .preToolUse)
        #expect(hooks.count == 1)
        #expect(hooks.first?.command == "/bin/true")
        #expect(hooks.first?.configuredMatcher == "read_file")
        // Seconds in config, milliseconds in the spec.
        #expect(hooks.first?.timeoutMs == 3_000)
        #expect(hooks.first?.name.hasPrefix("config/") == true)
    }

    @Test("an unknown event key is skipped without losing the valid hooks")
    func unknownEventSkipped() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hook-load-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let document = try parseTOML("""
        [[hooks.NotAnEvent]]
        matcher = "x"

        [[hooks.NotAnEvent.hooks]]
        type = "command"
        command = "/bin/true"

        [[hooks.PreToolUse]]

        [[hooks.PreToolUse.hooks]]
        type = "command"
        command = "/bin/echo"
        """)

        let result = HookSessionLoader.load(
            configDocument: document,
            configPath: root.appendingPathComponent("config.toml"),
            workspaceRoot: root,
            environment: ["HOME": root.path, "OPENGROK_HOME": root.path],
            includeFileDiscovery: false
        )

        #expect(result.skippedEvents.contains("NotAnEvent"))
        #expect(result.registry.hooks(for: .preToolUse).count == 1)
    }

    @Test("no hooks anywhere yields no gate")
    func noHooksYieldsNoGate() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hook-load-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let (gate, result) = HookSessionLoader.makeGate(
            configDocument: nil,
            configPath: root.appendingPathComponent("config.toml"),
            sessionId: "s",
            workspaceRoot: root,
            environment: ["HOME": root.path, "OPENGROK_HOME": root.path],
            includeFileDiscovery: false
        )
        #expect(gate == nil)
        #expect(result.isEmpty)

        // The pipeline default must still be safe with no gate installed.
        let runner = FailOpenPreToolUseHookRunner(inner: gate)
        let decision = await runner.runPreToolUse(
            toolName: "read_file",
            toolCallId: "c",
            access: .read(nil),
            permissionMode: nil
        )
        #expect(decision == .allow)
    }
}
