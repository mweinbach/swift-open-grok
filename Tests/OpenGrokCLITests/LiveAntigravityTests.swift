// LiveAntigravityTests.swift
//
// Antigravity through the LIVE seam (AGENTS.md §3): a real
// `LiveSubagentHost.spawn` with an injectable `LiveAntigravityServices`
// proves `antigravity:` models route to the CLI runner (never the in-process
// sampler) and that disabled / missing-CLI / unknown-model refusals fire
// before `coordinator.spawn`. Pure helpers cover argv shape and
// `classify_output` without a process.

import Foundation
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase
import OpenGrokSubagentResolution
import Testing
@testable import OpenGrokCLI

// MARK: - Fixtures

private actor AntigravityInertShellBackend: ShellProcessBackend {
    func run(_ request: ShellCommandRequest) async throws -> ShellCommandResult {
        ShellCommandResult(combinedOutput: "", stdout: "", exitCode: 0)
    }

    func runBackground(_ request: ShellCommandRequest) async throws -> ShellBackgroundHandle {
        ShellBackgroundHandle(taskID: "bg")
    }

    func getTask(_ taskID: String) async -> ShellTaskSnapshot? { nil }
    func killTask(_ taskID: String) async -> ShellKillOutcome { .notFound }
    func killForegroundCommands() async {}
    func killForegroundCommands(ownerSessionID: String) async {}
    func killAllBackgroundTasks() async {}
    func killAllBackgroundTasks(ownerSessionID: String) async {}
    func warmShell(at cwd: URL) async {}
    func backgroundForegroundCommand(toolCallID: String) async -> Bool { false }
    func waitForCompletion(_ taskID: String, timeout: ShellDuration?) async -> ShellTaskSnapshot? { nil }
    func listTasks() async -> [ShellTaskSnapshot] { [] }
    func shellCWD() async -> URL? { nil }
}

private final class AntigravityRunCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var runs: [LiveAntigravityRun] = []

    func append(_ run: LiveAntigravityRun) {
        lock.lock()
        defer { lock.unlock() }
        runs.append(run)
    }

    var all: [LiveAntigravityRun] {
        lock.lock()
        defer { lock.unlock() }
        return runs
    }
}

private struct AntigravityHostFixture {
    let home: URL
    let workspace: URL
    let environment: [String: String]
    let host: LiveSubagentHost
    let runCapture: AntigravityRunCapture
    private let root: URL

    init(
        configTOML: String = "",
        services: LiveAntigravityServices? = nil,
        samplerShouldNeverRun: Bool = true
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-antigravity-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        if !configTOML.isEmpty {
            try configTOML.write(
                to: home.appendingPathComponent("config.toml"),
                atomically: true,
                encoding: .utf8
            )
        }
        environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "XDG_STATE_HOME": home.appendingPathComponent("state").path,
        ]

        let capture = AntigravityRunCapture()
        runCapture = capture
        let resolvedServices = services ?? Self.defaultFakeServices(
            capture: capture,
            environment: environment
        )

        let sampler = OpenGrokLiveSampler { _, _ in
            if samplerShouldNeverRun {
                Issue.record("in-process sampler was invoked for an antigravity child")
            }
            return OpenGrokLiveSamplingResponse(output: "sampler must not run")
        }
        let securityContext = LiveSecurityContext.resolve(
            workspaceRoot: workspace,
            environment: environment,
            isInteractive: false
        )
        host = LiveSubagentHost(context: LiveSubagentHost.Context(
            sampler: sampler,
            parentModel: "test-model",
            workingDirectory: workspace,
            sessionID: "antigravity-session",
            openGrokHome: home,
            conversationStore: LiveConversationStore(openGrokHome: home),
            processBackend: AntigravityInertShellBackend(),
            securityContext: securityContext,
            sandboxDecision: LiveSandboxDecision(
                profileName: "none",
                mode: .none,
                enforced: false
            ),
            permissionOptions: CLIPermissionOptions(),
            fileAccessPolicy: .allowAll,
            telemetryBootstrapContext: .empty,
            imageToolContext: nil,
            webToolContext: nil,
            environment: environment,
            parentCapabilityCeiling: nil,
            definitionContext: DefinitionResolutionContext(
                cwd: workspace,
                includeFilesystemDefinitions: true,
                environment: environment
            ),
            modelSlugs: ["grok-4.5"],
            antigravityServices: resolvedServices
        ))
    }

    func dispose() {
        try? FileManager.default.removeItem(at: root)
    }

    static func spawnArgs(
        model: String = "antigravity:gemini-3.6-flash",
        capabilityMode: String? = nil,
        resumeFrom: String? = nil,
        taskID: String? = nil,
        reasoningEffort: String? = nil,
        background: Bool = false
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "prompt": .string("probe the fixture"),
            "description": .string("antigravity probe"),
            "subagent_type": .string("general-purpose"),
            "background": .bool(background),
            "model": .string(model),
        ]
        if let capabilityMode {
            object["capability_mode"] = .string(capabilityMode)
        }
        if let resumeFrom {
            object["resume_from"] = .string(resumeFrom)
        }
        if let taskID {
            object["task_id"] = .string(taskID)
        }
        if let reasoningEffort {
            object["reasoning_effort"] = .string(reasoningEffort)
        }
        return .object(object)
    }

    static func defaultFakeServices(
        capture: AntigravityRunCapture,
        environment: [String: String],
        installed: Bool = true,
        status: LiveAntigravityStatus = LiveAntigravityStatus(
            signedIn: true,
            models: ["gemini-3.6-flash", "claude-sonnet-4-6"],
            detail: nil
        ),
        runOutcome: LiveAntigravityRunOutcome = .success(
            output: "agy final answer",
            conversationID: nil
        )
    ) -> LiveAntigravityServices {
        LiveAntigravityServices(
            loadConfig: { LiveAntigravityConfig.load(environment: $0) },
            isCLIInstalled: { _, _ in installed },
            probeModels: { _ in status },
            runPrint: { run in
                capture.append(run)
                return runOutcome
            }
        )
    }
}

// MARK: - Pure helpers

@Suite("antigravity pure helpers")
struct LiveAntigravityHelperTests {
    @Test("stripModelPrefix accepts non-empty antigravity slugs")
    func stripPrefix() {
        #expect(LiveAntigravityComposition.stripModelPrefix("antigravity:gemini-3.6-flash")
            == "gemini-3.6-flash")
        #expect(LiveAntigravityComposition.stripModelPrefix("antigravity:") == nil)
        #expect(LiveAntigravityComposition.stripModelPrefix("grok-4.5") == nil)
    }

    @Test("argv matches upstream build_command shape with skip-permissions")
    func argvShapeWithSkipPermissions() {
        let workspace = URL(fileURLWithPath: "/tmp/ws", isDirectory: true)
        let log = URL(fileURLWithPath: "/tmp/ws/agy.log")
        let run = LiveAntigravityRun(
            binary: "agy",
            model: "gemini-3.6-flash",
            prompt: "do the thing",
            workspaceDirectory: workspace,
            logFile: log,
            timeout: 600,
            skipPermissions: true
        )
        #expect(antigravityArguments(for: run) == [
            "--print", "do the thing",
            "--model", "gemini-3.6-flash",
            "--add-dir", workspace.path,
            "--log-file", log.path,
            "--print-timeout", "600s",
            "--dangerously-skip-permissions",
        ])
    }

    @Test("argv omits skip-permissions when false")
    func argvOmitsSkipPermissions() {
        let run = LiveAntigravityRun(
            binary: "agy",
            model: "gemini-3.6-flash",
            prompt: "read only",
            workspaceDirectory: URL(fileURLWithPath: "/tmp/ws", isDirectory: true),
            logFile: URL(fileURLWithPath: "/tmp/agy.log"),
            timeout: 30,
            skipPermissions: false
        )
        #expect(!antigravityArguments(for: run).contains("--dangerously-skip-permissions"))
    }

    @Test("effort planning swaps suffixed siblings and clamps base-model effort")
    func effortPlanning() {
        let roster = [
            "gemini-3.6-flash-low",
            "gemini-3.6-flash-medium",
            "gemini-3.6-flash-high",
            "claude-sonnet-4-6",
        ]
        #expect(planAntigravityModelArguments(
            model: "gemini-3.6-flash-high",
            effort: "minimal",
            roster: roster
        ) == LiveAntigravityModelPlan(model: "gemini-3.6-flash-low", effort: nil))
        #expect(planAntigravityModelArguments(
            model: "claude-sonnet-4-6",
            effort: "ultra",
            roster: roster
        ) == LiveAntigravityModelPlan(model: "claude-sonnet-4-6", effort: "high"))
        #expect(normalizeAntigravityEffort("none") == nil)
    }

    @Test("argv carries planned effort and conversation continuation")
    func argvEffortAndConversation() {
        let run = LiveAntigravityRun(
            binary: "agy",
            model: "gemini-3.6-flash",
            effort: "xhigh",
            modelRoster: ["gemini-3.6-flash"],
            prompt: "continue",
            workspaceDirectory: URL(fileURLWithPath: "/tmp/ws", isDirectory: true),
            logFile: URL(fileURLWithPath: "/tmp/agy.log"),
            timeout: 45,
            skipPermissions: false,
            conversationID: "3605d5fa-fbdd-442c-83f4-90325fbc9186"
        )
        let args = antigravityArguments(for: run)
        #expect(args.containsSubsequence(["--effort", "high"]))
        #expect(args.containsSubsequence([
            "--conversation", "3605d5fa-fbdd-442c-83f4-90325fbc9186"
        ]))
    }

    @Test("model guidance floats the reference family first")
    func rosterOrdering() {
        let status = LiveAntigravityStatus(
            signedIn: true,
            models: [
                "claude-sonnet-4-6",
                "gemini-3.6-flash-high",
                "gemini-3.6-flash",
                "gemini-3.6-pro",
            ],
            detail: nil
        )
        #expect(status.prefixedModels == [
            "antigravity:gemini-3.6-flash",
            "antigravity:gemini-3.6-flash-high",
            "antigravity:claude-sonnet-4-6",
            "antigravity:gemini-3.6-pro",
        ])
    }

    @Test("log helpers recover HTTP port, conversation id, and phases")
    func logHelpers() {
        let conversation = "3605d5fa-fbdd-442c-83f4-90325fbc9186"
        let log = """
        Language server listening on random port at 51042 for HTTPS
        Print mode: conversation=\(conversation), sending message
        Language server listening on random port at 51043 for HTTP
        ExecuteCommand tool_call
        """
        #expect(parseAntigravityHTTPPort(log) == 51043)
        #expect(extractAntigravityConversationID(log) == conversation)
        #expect(antigravityPhase(from: log) == "Working")
        #expect(antigravityPhase(from: "Language server shutting down") == "Wrapping up")
    }

    @Test("quota and available-model Connect payloads parse")
    func quotaParsers() throws {
        let quota = try #require(parseAntigravityQuotaSummary(Data("""
        {"response":{"groups":[{"displayName":"Gemini Models","buckets":[
          {"displayName":"Daily Limit","bucketId":"daily","window":"daily","remainingFraction":0.25,"resetTime":"2026-08-17T00:00:00Z"}
        ]}]}}
        """.utf8)))
        #expect(quota.count == 1)
        #expect(quota[0].label == "Daily Limit")
        #expect(quota[0].remainingFraction == 0.25)

        let models = try #require(parseAntigravityAvailableModels(Data("""
        {"response":{"models":{
          "gemini-3.6-flash":{"quotaInfo":{"remainingFraction":1}},
          "gemini-3.6-pro":{"quotaInfo":{"remainingFraction":0}}
        }}}
        """.utf8)))
        #expect(models.count == 2)
        #expect(models.first(where: { $0.key == "gemini-3.6-pro" })?.isExhausted == true)
    }

    @Test("classify_output success returns trimmed stdout")
    func classifySuccess() {
        let result = classifyAntigravityOutput(
            stdout: "  hello from agy\n",
            stderr: "",
            exitOK: true
        )
        #expect(result == .success("hello from agy"))
    }

    @Test("classify_output first Error: line is failure")
    func classifyErrorPrefix() {
        let result = classifyAntigravityOutput(
            stdout: "Error: Please sign in\nmore\n",
            stderr: "",
            exitOK: true
        )
        guard case .failure(let message) = result else {
            Issue.record("expected failure, got \(result)")
            return
        }
        #expect(message.hasPrefix("Error: Please sign in"))
        #expect(message.contains("run `agy` once"))
    }

    @Test("classify_output jetski diagnostic is failure")
    func classifyJetski() {
        let result = classifyAntigravityOutput(
            stdout: "jetski: no output produced (timeout)\n",
            stderr: "",
            exitOK: true
        )
        guard case .failure(let message) = result else {
            Issue.record("expected failure, got \(result)")
            return
        }
        #expect(message.hasPrefix("jetski: no output produced"))
    }

    @Test("parse_models_output treats Error: as signed out")
    func parseModelsSignedOut() {
        let status = LiveAntigravityStatus.parse(
            stdout: "Error: Please sign in to continue\n",
            stderr: ""
        )
        #expect(status.signedIn == false)
        #expect(status.models.isEmpty)
    }

    @Test("parse_models_output collects roster lines")
    func parseModelsRoster() {
        let status = LiveAntigravityStatus.parse(
            stdout: "gemini-3.6-flash\nclaude-sonnet-4-6\n",
            stderr: ""
        )
        #expect(status.signedIn == true)
        #expect(status.models == ["gemini-3.6-flash", "claude-sonnet-4-6"])
    }

    @Test("config defaults: subagents off, skip_permissions on")
    func configDefaults() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-agy-cfg-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let env = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
        ]
        let config = LiveAntigravityConfig.load(environment: env)
        #expect(config.enabled == false)
        #expect(config.skipPermissions == true)
        #expect(config.binary == "agy")
    }

    @Test("config reads ui.antigravity_subagents and antigravity.skip_permissions")
    func configReadsTOML() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-agy-cfg-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
            [ui]
            antigravity_subagents = true

            [antigravity]
            skip_permissions = false
            binary = "/opt/agy"
            """.write(
                to: home.appendingPathComponent("config.toml"),
                atomically: true,
                encoding: .utf8
            )
        let config = LiveAntigravityConfig.load(environment: [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
        ])
        #expect(config.enabled == true)
        #expect(config.skipPermissions == false)
        #expect(config.binary == "/opt/agy")
    }

    @Test("hiddenSettingsKeys hide rows when CLI is absent")
    func settingsHonestyGate() {
        let absent = LiveAntigravityCapabilities(cliInstalled: false)
        #expect(LiveAntigravityCapabilities.hiddenSettingsKeys(when: absent)
            == Set(LiveAntigravityCapabilities.settingsKeys))
        let present = LiveAntigravityCapabilities(cliInstalled: true)
        #expect(LiveAntigravityCapabilities.hiddenSettingsKeys(when: present).isEmpty)
    }
}

// MARK: - Live seam

@Suite("antigravity spawn through the live seam", .serialized)
struct LiveAntigravitySpawnTests {
    @Test("running antigravity child retains attachable live items")
    func runningChildAttachment() async throws {
        let gate = AntigravityRunGate()
        let capture = AntigravityRunCapture()
        let services = LiveAntigravityServices(
            loadConfig: { _ in
                LiveAntigravityConfig(enabled: true, binary: "agy", skipPermissions: true)
            },
            isCLIInstalled: { _, _ in true },
            probeModels: { _ in
                LiveAntigravityStatus(
                    signedIn: true,
                    models: ["gemini-3.6-flash"],
                    detail: nil
                )
            },
            runPrint: { run in
                capture.append(run)
                return await gate.wait()
            }
        )
        let fixture = try AntigravityHostFixture(services: services)
        defer { fixture.dispose() }

        let spawn = await fixture.host.spawn(
            args: AntigravityHostFixture.spawnArgs(taskID: "agy-running", background: true),
            toolCallID: "call-agy-running"
        )
        guard case .success = spawn else {
            Issue.record("background spawn failed: \(spawn)")
            return
        }

        for _ in 0..<50 {
            if await fixture.host.subagentSnapshot(id: "agy-running") != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let items = try #require(await fixture.host.subagentConversationItems(id: "agy-running"))
        let snapshot = try #require(await fixture.host.subagentSnapshot(id: "agy-running"))
        #expect(snapshot.status == "running")
        #expect(items.contains { item in
            if case .assistant(let assistant) = item {
                return assistant.content.contains("Antigravity: Starting")
            }
            return false
        })
        let rendered = LiveSubagentAttachment.lines(items: items, snapshot: snapshot)
            .map(\.text).joined(separator: "\n")
        #expect(rendered.contains("Status: running"))
        #expect(rendered.contains("Antigravity: Starting"))

        await gate.release(.success(output: "done", conversationID: "conversation-running"))
        let completed = await fixture.host.awaitSubagent(id: "agy-running", timeoutMS: 2_000)
        #expect(completed?.completed == true)
    }

    @Test("antigravity model routes to the CLI runner, not runChild")
    func routesToCLIRunner() async throws {
        let fixture = try AntigravityHostFixture(
            configTOML: """
                [ui]
                antigravity_subagents = true
                """
        )
        defer { fixture.dispose() }

        let result = await fixture.host.spawn(
            args: AntigravityHostFixture.spawnArgs(),
            toolCallID: "call-agy-1"
        )
        guard case .success(let value) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(value.promptText.contains("agy final answer")
            || String(describing: value.value).contains("agy final answer"))
        #expect(fixture.runCapture.all.count == 1)
        let run = try #require(fixture.runCapture.all.first)
        #expect(run.model == "gemini-3.6-flash")
        #expect(run.skipPermissions == true)
        #expect(antigravityArguments(for: run).contains("--dangerously-skip-permissions"))
    }

    @Test("resume passes the stored Antigravity conversation and effort")
    func conversationResume() async throws {
        let capture = AntigravityRunCapture()
        let services = LiveAntigravityServices(
            loadConfig: { _ in
                LiveAntigravityConfig(enabled: true, binary: "agy", skipPermissions: true)
            },
            isCLIInstalled: { _, _ in true },
            probeModels: { _ in
                LiveAntigravityStatus(
                    signedIn: true,
                    models: ["gemini-3.6-flash"],
                    detail: nil
                )
            },
            runPrint: { run in
                capture.append(run)
                return .success(
                    output: run.conversationID == nil ? "first" : "continued",
                    conversationID: run.conversationID ?? "conversation-source"
                )
            }
        )
        let fixture = try AntigravityHostFixture(services: services)
        defer { fixture.dispose() }

        guard case .success = await fixture.host.spawn(
            args: AntigravityHostFixture.spawnArgs(
                taskID: "agy-source",
                reasoningEffort: "xhigh"
            ),
            toolCallID: "call-agy-source"
        ) else {
            Issue.record("source Antigravity spawn failed")
            return
        }
        guard case .success = await fixture.host.spawn(
            args: AntigravityHostFixture.spawnArgs(
                resumeFrom: "agy-source",
                taskID: "agy-resumed"
            ),
            toolCallID: "call-agy-resumed"
        ) else {
            Issue.record("resumed Antigravity spawn failed")
            return
        }

        #expect(capture.all.count == 2)
        #expect(capture.all[0].effort == "xhigh")
        #expect(capture.all[0].modelRoster == ["gemini-3.6-flash"])
        #expect(capture.all[1].conversationID == "conversation-source")
        #expect(capture.all[1].model == "gemini-3.6-flash")
    }

    @Test("cached availability and quota surface before spawning")
    func cachedAvailabilityAndUsage() async throws {
        LiveAntigravityComposition.invalidateCaches()
        defer { LiveAntigravityComposition.invalidateCaches() }
        LiveAntigravityCache.shared.store(models: [
            LiveAntigravityModelAvailability(
                key: "gemini-3.6-pro",
                remainingFraction: 0
            )
        ])
        LiveAntigravityCache.shared.store(quota: [
            LiveAntigravityQuotaBucket(
                group: "Gemini Models",
                displayName: "Daily Limit",
                bucketID: "daily",
                window: "daily",
                remainingFraction: 0,
                resetTime: "2026-08-17T00:00:00Z"
            )
        ])
        #expect(antigravityModelAvailabilityIssue(
            model: "gemini-3.6-pro",
            roster: ["gemini-3.6-pro"]
        ) == .exhausted)
        let message = antigravityUnavailableModelMessage(
            model: "gemini-3.6-pro",
            issue: .exhausted
        )
        #expect(message.contains("out of quota"))
        #expect(message.contains("Daily Limit exhausted"))

        let report = await LiveUsageComposition.report(context: nil, items: [])
        #expect(report.antigravityQuota?.buckets.count == 1)
        #expect(LiveUsageComposition.render(report).contains("Antigravity quota"))
    }

    @Test("Error:-prefixed runner outcome surfaces as spawn failure")
    func errorStdoutFailure() async throws {
        let capture = AntigravityRunCapture()
        let services = LiveAntigravityServices(
            loadConfig: { _ in
                LiveAntigravityConfig(enabled: true, binary: "agy", skipPermissions: true)
            },
            isCLIInstalled: { _, _ in true },
            probeModels: { _ in
                LiveAntigravityStatus(
                    signedIn: true,
                    models: ["gemini-3.6-flash"],
                    detail: nil
                )
            },
            runPrint: { run in
                capture.append(run)
                return .failure("Error: something broke")
            }
        )
        let fixture = try AntigravityHostFixture(services: services)
        defer { fixture.dispose() }

        let result = await fixture.host.spawn(
            args: AntigravityHostFixture.spawnArgs(),
            toolCallID: "call-agy-err"
        )
        guard case .failure(let error) = result else {
            Issue.record("expected failure, got \(result)")
            return
        }
        #expect(String(describing: error).contains("Error: something broke"))
        #expect(capture.all.count == 1)
    }

    @Test("jetski no-output classification fails the child result")
    func jetskiFailureThroughClassify() {
        let classified = classifyAntigravityOutput(
            stdout: "jetski: no output produced\n",
            stderr: "",
            exitOK: true
        )
        #expect(classified == .failure("jetski: no output produced"))
    }

    @Test("feature disabled refuses before the runner")
    func featureDisabledRefusal() async throws {
        let capture = AntigravityRunCapture()
        let services = LiveAntigravityServices(
            loadConfig: { _ in
                LiveAntigravityConfig(enabled: false, binary: "agy", skipPermissions: true)
            },
            isCLIInstalled: { _, _ in true },
            probeModels: { _ in
                Issue.record("probeModels must not run when feature is disabled")
                return .unavailable("unreachable")
            },
            runPrint: { run in
                capture.append(run)
                Issue.record("runPrint must not run when feature is disabled")
                return .success(output: "nope", conversationID: nil)
            }
        )
        let fixture = try AntigravityHostFixture(services: services)
        defer { fixture.dispose() }

        let result = await fixture.host.spawn(
            args: AntigravityHostFixture.spawnArgs(),
            toolCallID: "call-agy-disabled"
        )
        guard case .failure(let error) = result else {
            Issue.record("expected refusal, got \(result)")
            return
        }
        #expect(String(describing: error).contains("[ui].antigravity_subagents"))
        #expect(capture.all.isEmpty)
    }

    @Test("missing CLI refuses before the runner")
    func cliMissingRefusal() async throws {
        let capture = AntigravityRunCapture()
        let services = LiveAntigravityServices(
            loadConfig: { _ in
                LiveAntigravityConfig(enabled: true, binary: "agy", skipPermissions: true)
            },
            isCLIInstalled: { _, _ in false },
            probeModels: { _ in
                Issue.record("probeModels must not run when CLI is missing")
                return .unavailable("unreachable")
            },
            runPrint: { run in
                capture.append(run)
                return .success(output: "nope", conversationID: nil)
            }
        )
        let fixture = try AntigravityHostFixture(services: services)
        defer { fixture.dispose() }

        let result = await fixture.host.spawn(
            args: AntigravityHostFixture.spawnArgs(),
            toolCallID: "call-agy-missing"
        )
        guard case .failure(let error) = result else {
            Issue.record("expected refusal, got \(result)")
            return
        }
        #expect(String(describing: error).contains("was not found on this system"))
        #expect(capture.all.isEmpty)
    }

    @Test("unknown model refuses with available roster")
    func unknownModelRefusal() async throws {
        let capture = AntigravityRunCapture()
        let services = LiveAntigravityServices(
            loadConfig: { _ in
                LiveAntigravityConfig(enabled: true, binary: "agy", skipPermissions: true)
            },
            isCLIInstalled: { _, _ in true },
            probeModels: { _ in
                LiveAntigravityStatus(
                    signedIn: true,
                    models: ["gemini-3.6-flash"],
                    detail: nil
                )
            },
            runPrint: { run in
                capture.append(run)
                return .success(output: "nope", conversationID: nil)
            }
        )
        let fixture = try AntigravityHostFixture(services: services)
        defer { fixture.dispose() }

        let result = await fixture.host.spawn(
            args: AntigravityHostFixture.spawnArgs(model: "antigravity:not-a-real-model"),
            toolCallID: "call-agy-unknown"
        )
        guard case .failure(let error) = result else {
            Issue.record("expected refusal, got \(result)")
            return
        }
        let text = String(describing: error)
        #expect(text.contains("Unknown antigravity model"))
        #expect(text.contains("antigravity:gemini-3.6-flash"))
        #expect(capture.all.isEmpty)
    }

    @Test("skip_permissions defaults on; ReadOnly capability forces it off")
    func readOnlyForcesSkipPermissionsOff() async throws {
        let capture = AntigravityRunCapture()
        let services = LiveAntigravityServices(
            loadConfig: { _ in
                LiveAntigravityConfig(enabled: true, binary: "agy", skipPermissions: true)
            },
            isCLIInstalled: { _, _ in true },
            probeModels: { _ in
                LiveAntigravityStatus(
                    signedIn: true,
                    models: ["gemini-3.6-flash"],
                    detail: nil
                )
            },
            runPrint: { run in
                capture.append(run)
                return .success(output: "ok", conversationID: nil)
            }
        )
        let fixture = try AntigravityHostFixture(services: services)
        defer { fixture.dispose() }

        let defaultResult = await fixture.host.spawn(
            args: AntigravityHostFixture.spawnArgs(),
            toolCallID: "call-agy-skip-default"
        )
        guard case .success = defaultResult else {
            Issue.record("default spawn failed: \(defaultResult)")
            return
        }
        #expect(capture.all.first?.skipPermissions == true)

        let readOnlyResult = await fixture.host.spawn(
            args: AntigravityHostFixture.spawnArgs(capabilityMode: "read-only"),
            toolCallID: "call-agy-skip-ro"
        )
        guard case .success = readOnlyResult else {
            Issue.record("read-only spawn failed: \(readOnlyResult)")
            return
        }
        #expect(capture.all.count == 2)
        #expect(capture.all.last?.skipPermissions == false)
    }

    @Test("catalog bypass: antigravity slug is not rejected as unavailable model")
    func catalogBypass() async throws {
        let services = LiveAntigravityServices(
            loadConfig: { _ in
                LiveAntigravityConfig(enabled: true, binary: "agy", skipPermissions: true)
            },
            isCLIInstalled: { _, _ in true },
            probeModels: { _ in
                LiveAntigravityStatus(
                    signedIn: true,
                    models: ["gemini-3.6-flash"],
                    detail: nil
                )
            },
            runPrint: { _ in .success(output: "ok", conversationID: nil) }
        )
        let fixture = try AntigravityHostFixture(services: services)
        defer { fixture.dispose() }

        let result = await fixture.host.spawn(
            args: AntigravityHostFixture.spawnArgs(model: "antigravity:gemini-3.6-flash"),
            toolCallID: "call-agy-bypass"
        )
        guard case .success = result else {
            Issue.record("catalog bypass failed: \(result)")
            return
        }
    }

    /// `task_id` is decoder-supported but not advertised, so nothing else
    /// constrains it — and the Antigravity runner joins it straight into
    /// `$OPENGROK_HOME/sessions/<session>/subagents/<childID>` before handing
    /// that to `createDirectory` and `agy --log-file`.
    @Test("traversal in task_id is refused before any filesystem use")
    func traversalTaskIDRefused() async throws {
        let ran = LockedBox(false)
        let services = LiveAntigravityServices(
            loadConfig: { _ in
                LiveAntigravityConfig(enabled: true, binary: "agy", skipPermissions: true)
            },
            isCLIInstalled: { _, _ in true },
            probeModels: { _ in
                LiveAntigravityStatus(signedIn: true, models: ["gemini-3.6-flash"], detail: nil)
            },
            runPrint: { _ in
                ran.set(true)
                return .success(output: "ok", conversationID: nil)
            }
        )
        let fixture = try AntigravityHostFixture(services: services)
        defer { fixture.dispose() }

        guard case .object(var args) = AntigravityHostFixture.spawnArgs() else {
            Issue.record("unexpected spawn args shape")
            return
        }
        args["task_id"] = .string("../../outside")

        let result = await fixture.host.spawn(args: .object(args), toolCallID: "call-agy-traversal")
        guard case .failure(let error) = result else {
            Issue.record("expected traversal refusal, got \(result)")
            return
        }
        #expect(error.description.contains("task_id"))
        #expect(ran.get() == false)
    }
}

/// Minimal `Sendable` flag for asserting a closure did or did not run.
private final class LockedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    init(_ value: Bool) { self.value = value }

    func set(_ newValue: Bool) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private actor AntigravityRunGate {
    private var continuation: CheckedContinuation<LiveAntigravityRunOutcome, Never>?
    private var pending: LiveAntigravityRunOutcome?

    func wait() async -> LiveAntigravityRunOutcome {
        if let pending {
            self.pending = nil
            return pending
        }
        return await withCheckedContinuation { continuation = $0 }
    }

    func release(_ outcome: LiveAntigravityRunOutcome) {
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: outcome)
        } else {
            pending = outcome
        }
    }
}

private extension Array where Element == String {
    func containsSubsequence(_ subsequence: [String]) -> Bool {
        guard !subsequence.isEmpty, subsequence.count <= count else { return false }
        for start in 0...(count - subsequence.count) {
            if Array(self[start..<(start + subsequence.count)]) == subsequence { return true }
        }
        return false
    }
}
