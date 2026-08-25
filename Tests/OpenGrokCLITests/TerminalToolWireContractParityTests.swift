import Foundation
import OpenGrokFileTools
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase
import OpenGrokWorkspace
import Testing
@testable import OpenGrokCLI

private actor TerminalWireContractProcess: OpenGrokShellProcessExecution, ShellProcessBackend {
    nonisolated let sessionID: String
    nonisolated let workingDirectory: URL
    private var requests: [ShellCommandRequest] = []
    private var backgroundRequests: [ShellCommandRequest] = []

    init(sessionID: String = "terminal-wire-session", workingDirectory: URL) {
        self.sessionID = sessionID
        self.workingDirectory = workingDirectory
    }

    func run(_ request: ShellCommandRequest) async throws -> ShellCommandResult {
        requests.append(request)
        return ShellCommandResult(combinedOutput: "terminal parity", exitCode: 0)
    }

    func runBackground(_ request: ShellCommandRequest) async throws -> ShellBackgroundHandle {
        backgroundRequests.append(request)
        return ShellBackgroundHandle(taskID: "terminal-wire-task")
    }

    func capturedRequests() -> [ShellCommandRequest] { requests }
    func capturedBackgroundRequests() -> [ShellCommandRequest] { backgroundRequests }
    func cancel(toolCallID: String) async {}
    func cancelAll() async {}
    func getTask(_ taskID: String) async -> ShellTaskSnapshot? { nil }
    func taskSnapshot(_ taskID: String) async -> ShellTaskSnapshot? { nil }
    func killTask(_ taskID: String) async -> ShellKillOutcome { .notFound }
    func killForegroundCommands() async {}
    func killForegroundCommands(ownerSessionID: String) async {}
    func killAllBackgroundTasks() async {}
    func killAllBackgroundTasks(ownerSessionID: String) async {}
    func warmShell(at cwd: URL) async {}
    func backgroundForegroundCommand(toolCallID: String) async -> Bool { false }
    func waitForCompletion(_ taskID: String, timeout: ShellDuration?) async -> ShellTaskSnapshot? {
        nil
    }
    func listTasks() async -> [ShellTaskSnapshot] { [] }
    func shellCWD() async -> URL? { workingDirectory }
}

private struct TerminalWireContractPrompter: PermissionPrompter {
    func prompt(
        access: AccessKind,
        toolName: String,
        toolCallId: String
    ) async -> PermissionDecision {
        .allow
    }
}

private struct TerminalWireContractWorkspace {
    let root: URL
    let workspace: URL
    let environment: [String: String]

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-wire-parity-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let state = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        environment = [
            "HOME": root.path,
            "OPENGROK_HOME": state.path,
            "GROK_SANDBOX": "off",
            "XAI_API_KEY": "terminal-wire-parity-key",
        ]
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor TerminalWireSamplingRecorder {
    private var recorded: [OpenGrokLiveSamplingRequest] = []

    func record(_ request: OpenGrokLiveSamplingRequest) {
        recorded.append(request)
    }

    func first() -> OpenGrokLiveSamplingRequest? {
        recorded.first
    }
}

@Suite("Pinned Rust live terminal wire contract")
struct LiveTerminalToolWireContractParityTests {
    @Test("the actual provider receives the canonical terminal contract first")
    func actualProviderReceivesCanonicalContract() async throws {
        let fixture = try TerminalWireContractWorkspace()
        defer { fixture.cleanUp() }
        let recorder = TerminalWireSamplingRecorder()
        let application = OpenGrokApplication.live(
            dependencies: OpenGrokLiveCompositionDependencies(
                makeSampler: { _ in
                    OpenGrokLiveSampler { request, emit in
                        await recorder.record(request)
                        await emit(.output("terminal parity"))
                        return OpenGrokLiveSamplingResponse(output: "terminal parity")
                    }
                }
            ),
            control: .never
        )
        let (streams, _, _) = CLIStreams.buffered()
        let exitCode = await CLIRunner.run(
            ["headless", "--prompt", "inspect terminal tools", "--cwd", fixture.workspace.path],
            environment: fixture.environment,
            streams: streams,
            application: application
        )

        #expect(exitCode == CLIRunner.ExitCode.success.rawValue)
        let request = try #require(await recorder.first())
        let canonical = try #require(request.tools.first {
            $0.name == "run_terminal_command"
        })
        let legacy = try #require(request.tools.first {
            $0.name == "run_terminal_cmd"
        })
        let canonicalIndex = try #require(request.tools.firstIndex {
            $0.name == canonical.name
        })
        let legacyIndex = try #require(request.tools.firstIndex {
            $0.name == legacy.name
        })
        #expect(canonicalIndex < legacyIndex)

        let schema = try #require(canonical.parameters.objectValue)
        let properties = try #require(schema["properties"]?.objectValue)
        #expect(Set(properties.keys) == [
            "command", "description", "timeout", "background",
        ])
        #expect(schema["required"]?.arrayValue == [
            .string("command"), .string("description"),
        ])
        #expect(properties["environment"] == nil)
        #expect(properties["output_byte_limit"] == nil)
        #expect(legacy.parameters.objectValue?["properties"]?.objectValue?["environment"] == nil)
    }

    @Test("canonical foreground timeout defaults, clamps, and accepts numeric strings")
    func canonicalForegroundTimeoutParity() async throws {
        let process = TerminalWireContractProcess(workingDirectory: URL(fileURLWithPath: "/tmp"))
        let runtime = LiveRunTerminalToolRuntime(subagents: nil)

        let inputs: [(JSONValue?, TimeInterval)] = [
            (nil, 120),
            (.number(.int64(0)), 120),
            (.number(.int64(5_000)), 5),
            (.string("2500"), 2.5),
            (.number(.int64(900_000)), 300),
        ]
        for (timeout, expected) in inputs {
            var fields: [String: JSONValue] = [
                "command": .string("printf parity"),
                "description": .string("Verify canonical timeout"),
            ]
            if let timeout { fields["timeout"] = timeout }
            let result = await runtime.invoke(
                OpenGrokShellToolCall(
                    sessionID: process.sessionID,
                    name: "run_terminal_command",
                    args: .object(fields),
                    callID: UUID().uuidString
                ),
                using: process
            )
            guard case .success = result else {
                Issue.record("canonical timeout failed: \(result)")
                continue
            }
            let request = try #require(await process.capturedRequests().last)
            #expect(request.timeout.timeInterval == expected)
            #expect(request.environment.isEmpty)
            #expect(request.outputByteLimit == 30_000)
        }
    }

    @Test("background tasks remain unbounded by the foreground timeout")
    func backgroundTimeoutParity() async throws {
        let process = TerminalWireContractProcess(workingDirectory: URL(fileURLWithPath: "/tmp"))
        let runtime = LiveRunTerminalToolRuntime(subagents: nil)

        let scenarios: [(JSONValue?, TimeInterval)] = [
            (nil, 0),
            (.number(.int64(0)), 0),
            (.number(.int64(900_000)), 900),
            (.number(.int64(99_000_000)), 36_000),
        ]
        for (timeout, expected) in scenarios {
            var fields: [String: JSONValue] = [
                "command": .string("sleep 60"),
                "description": .string("Start an owned background command"),
                "background": .bool(true),
            ]
            if let timeout { fields["timeout"] = timeout }
            let result = await runtime.invoke(
                OpenGrokShellToolCall(
                    sessionID: process.sessionID,
                    name: "run_terminal_command",
                    args: .object(fields),
                    callID: UUID().uuidString
                ),
                using: process
            )
            guard case .success(let output) = result else {
                Issue.record("background timeout failed: \(result)")
                continue
            }
            #expect(output.value.objectValue?["task_id"] == .string("terminal-wire-task"))
            let request = try #require(await process.capturedBackgroundRequests().last)
            #expect(request.timeout.timeInterval == expected)
            #expect(request.ownerSessionID == process.sessionID)
        }
    }

    @Test("canonical descriptions are mandatory while old recordings stay callable")
    func descriptionsAndLegacyAliases() async throws {
        let process = TerminalWireContractProcess(workingDirectory: URL(fileURLWithPath: "/tmp"))
        let runtime = LiveRunTerminalToolRuntime(subagents: nil)

        let canonical = await runtime.invoke(
            OpenGrokShellToolCall(
                sessionID: process.sessionID,
                name: "run_terminal_command",
                args: .object(["command": .string("printf parity")]),
                callID: "missing-description"
            ),
            using: process
        )
        guard case .failure(.invalidCall(let reason)) = canonical else {
            Issue.record("canonical command unexpectedly accepted a missing description")
            return
        }
        #expect(reason.contains("description"))
        #expect(await process.capturedRequests().isEmpty)

        let legacy = await runtime.invoke(
            OpenGrokShellToolCall(
                sessionID: process.sessionID,
                name: "run_terminal_cmd",
                args: .object([
                    "command": .string("sleep 60"),
                    "is_background": .bool(true),
                    "timeout_ms": .number(.int64(1_500)),
                ]),
                callID: "legacy-recording"
            ),
            using: process
        )
        guard case .success = legacy else {
            Issue.record("legacy terminal recording stopped dispatching: \(legacy)")
            return
        }
        let request = try #require(await process.capturedBackgroundRequests().last)
        #expect(request.timeout.timeInterval == 1.5)
    }

    @Test("process environment, output overrides, and conflicting aliases fail closed")
    func unsafeFieldsCannotBypassEitherSpelling() async {
        let process = TerminalWireContractProcess(workingDirectory: URL(fileURLWithPath: "/tmp"))
        let runtime = LiveRunTerminalToolRuntime(subagents: nil)
        let unsafeFields: [[String: JSONValue]] = [
            ["environment": .object(["XAI_API_KEY": .string("exfiltrate")])],
            ["output_byte_limit": .number(.int64(999_999))],
            ["background": .bool(false), "is_background": .bool(true)],
            ["timeout": .number(.int64(1)), "timeout_ms": .number(.int64(2))],
            ["timeout": .number(.int64(-1))],
        ]

        for name in ["run_terminal_command", "run_terminal_cmd"] {
            for unsafe in unsafeFields {
                var fields: [String: JSONValue] = [
                    "command": .string("printf parity"),
                    "description": .string("Reject unsafe process controls"),
                ]
                for (key, value) in unsafe { fields[key] = value }
                let outcome = await runtime.invoke(
                    OpenGrokShellToolCall(
                        sessionID: process.sessionID,
                        name: name,
                        args: .object(fields),
                        callID: UUID().uuidString
                    ),
                    using: process
                )
                guard case .failure(.invalidCall) = outcome else {
                    Issue.record("unsafe terminal arguments bypassed validation: \(name), \(unsafe)")
                    continue
                }
            }
        }
        #expect(await process.capturedRequests().isEmpty)
        #expect(await process.capturedBackgroundRequests().isEmpty)
    }

    @Test("a deny on either spelling removes both callable terminal surfaces")
    func deniedAliasesCannotReachProcessExecution() async throws {
        for deniedName in ["run_terminal_command", "run_terminal_cmd"] {
            let fixture = try TerminalWireContractWorkspace()
            defer { fixture.cleanUp() }
            let backend = TerminalWireContractProcess(workingDirectory: fixture.workspace)
            let policy = LiveAgentToolPolicy.resolveLaunchPolicy(
                tools: nil,
                disallowedTools: deniedName,
                profile: nil
            )
            let executor = try await LiveToolExecutor(
                processBackend: backend,
                sessionID: backend.sessionID,
                workingDirectory: fixture.workspace,
                toolPolicy: policy,
                telemetryBootstrapContext: .empty,
                fileAccessPolicy: .prompt(TerminalWireContractPrompter()),
                environment: fixture.environment
            )
            #expect(!executor.tools.contains { tool in
                tool.name == "run_terminal_command" || tool.name == "run_terminal_cmd"
            })

            for name in ["run_terminal_command", "run_terminal_cmd"] {
                let result = await executor.invoke(
                    sessionID: backend.sessionID,
                    workingDirectory: fixture.workspace,
                    call: ToolCall(
                        id: UUID().uuidString,
                        name: name,
                        arguments: #"{"command":"printf forbidden","description":"must stay denied"}"#
                    )
                )
                guard case .failure = result else {
                    Issue.record("denied alias reached execution: \(deniedName), \(name)")
                    continue
                }
            }
            #expect(await backend.capturedRequests().isEmpty)
            await executor.shutdown()
        }
    }

    @Test("both authorized terminal names cross the identical live permission gate")
    func bothAliasesShareLivePermissionPipeline() async throws {
        let fixture = try TerminalWireContractWorkspace()
        defer { fixture.cleanUp() }
        let backend = TerminalWireContractProcess(workingDirectory: fixture.workspace)
        let executor = try await LiveToolExecutor(
            processBackend: backend,
            sessionID: backend.sessionID,
            workingDirectory: fixture.workspace,
            toolPolicy: nil,
            telemetryBootstrapContext: .empty,
            fileAccessPolicy: .prompt(TerminalWireContractPrompter()),
            environment: fixture.environment
        )
        for name in ["run_terminal_command", "run_terminal_cmd"] {
            let result = await executor.invoke(
                sessionID: backend.sessionID,
                workingDirectory: fixture.workspace,
                call: ToolCall(
                    id: UUID().uuidString,
                    name: name,
                    arguments: #"{"command":"printf allowed","description":"Verify identical gates"}"#
                )
            )
            guard case .success = result else {
                Issue.record("authorized terminal alias did not dispatch: \(name), \(result)")
                continue
            }
        }
        #expect(await backend.capturedRequests().count == 2)
        await executor.shutdown()
    }

    @Test("additional directory grants stay bound to the authenticated root tree")
    func additionalRootsRemainScopedAndRevocable() async throws {
        let fixture = try TerminalWireContractWorkspace()
        defer { fixture.cleanUp() }
        let approved = fixture.root.appendingPathComponent("approved", isDirectory: true)
        let childWorkspace = fixture.root.appendingPathComponent("child-worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: approved, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: childWorkspace, withIntermediateDirectories: true)

        let rootBackend = TerminalWireContractProcess(workingDirectory: fixture.workspace)
        let rootExecutor = try await LiveToolExecutor(
            processBackend: rootBackend,
            sessionID: rootBackend.sessionID,
            workingDirectory: fixture.workspace,
            toolPolicy: nil,
            telemetryBootstrapContext: .empty,
            fileAccessPolicy: .prompt(TerminalWireContractPrompter()),
            environment: fixture.environment
        )
        let permissions = try #require(await rootExecutor.permissionHandle())
        try await rootExecutor.updateAdditionalWorkingDirectories(
            [approved],
            sessionID: rootBackend.sessionID
        )
        #expect(rootExecutor.additionalWorkingDirectories() == [approved])
        #expect(await permissions.workingDirectoryRoots(sessionID: rootBackend.sessionID) == [approved])

        let childBackend = TerminalWireContractProcess(
            sessionID: "authenticated-child",
            workingDirectory: childWorkspace
        )
        let childExecutor = try await LiveToolExecutor(
            processBackend: childBackend,
            sessionID: childBackend.sessionID,
            workingDirectory: childWorkspace,
            toolPolicy: nil,
            telemetryBootstrapContext: .empty,
            fileAccessPolicy: .prompt(TerminalWireContractPrompter()),
            environment: fixture.environment,
            inheritedPermissionHandle: permissions,
            authorizationScope: rootExecutor.resourceAuthorizationScope
        )
        #expect(childExecutor.resourceAuthorizationScope === rootExecutor.resourceAuthorizationScope)
        #expect(childExecutor.mcpToolset.resources.allowedRoots.contains(approved.path))
        #expect(childExecutor.mcpToolset.resources.allowedRoots.contains(childWorkspace.path))
        #expect(!rootExecutor.mcpToolset.resources.allowedRoots.contains(childWorkspace.path))

        do {
            try await childExecutor.updateAdditionalWorkingDirectories(
                [fixture.workspace],
                sessionID: childBackend.sessionID
            )
            Issue.record("a descendant changed its parent's authorization scope")
        } catch {
            #expect(rootExecutor.additionalWorkingDirectories() == [approved])
        }

        try await rootExecutor.updateAdditionalWorkingDirectories(
            [],
            sessionID: rootBackend.sessionID
        )
        #expect(rootExecutor.additionalWorkingDirectories().isEmpty)
        #expect(!childExecutor.mcpToolset.resources.allowedRoots.contains(approved.path))
        #expect(await permissions.workingDirectoryRoots(sessionID: rootBackend.sessionID).isEmpty)

        await childExecutor.shutdown()
        await rootExecutor.shutdown()
    }
}
