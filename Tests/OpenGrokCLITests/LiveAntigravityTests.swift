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
        resumeFrom: String? = nil
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "prompt": .string("probe the fixture"),
            "description": .string("antigravity probe"),
            "subagent_type": .string("general-purpose"),
            "background": .bool(false),
            "model": .string(model),
        ]
        if let capabilityMode {
            object["capability_mode"] = .string(capabilityMode)
        }
        if let resumeFrom {
            object["resume_from"] = .string(resumeFrom)
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
        runOutcome: LiveAntigravityRunOutcome = .success(output: "agy final answer")
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
                return .success(output: "nope")
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
                return .success(output: "nope")
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
                return .success(output: "nope")
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
                return .success(output: "ok")
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
            runPrint: { _ in .success(output: "ok") }
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
}
