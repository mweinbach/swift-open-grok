// LiveAskUserQuestionReachabilityTests.swift
//
// Proves the `ask_user_question` path is REACHED end to end, not merely
// implemented: the real registered tool invoked through the live
// `LiveToolExecutor`, the question sheet presented by the live renderer via
// the shared `PagerQuestionCoordinator`, the answer typed through
// `renderer.handleInput`, and the tool result carrying the chosen option
// text. Advertisement is asserted against `executor.tools` — what the model
// is actually offered — for both shapes: the interactive composition (broker
// present → advertised) and the headless one (no broker → absent).

import Foundation
import OpenGrokPagerRender
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase
import OpenGrokTerminalCore
import OpenGrokToolRegistry
import Testing
@testable import OpenGrokCLI

// MARK: - Fixtures

/// Runs nothing; the executor requires a backend but these tests never
/// exercise the shell.
private actor InertShellBackend: ShellProcessBackend {
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

private final class CapturingSink: PagerTerminalSink, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []

    var capabilities: PagerTerminalCapabilities { .standard }

    func write(bytes newBytes: [UInt8]) throws {
        lock.lock(); defer { lock.unlock() }
        bytes.append(contentsOf: newBytes)
    }

    func flush() throws {}

    var strippedText: String {
        lock.lock(); defer { lock.unlock() }
        var output = ""
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x1B else {
                output.unicodeScalars.append(Unicode.Scalar(bytes[index]))
                index += 1
                continue
            }
            index += 1
            guard index < bytes.count else { break }
            switch bytes[index] {
            case UInt8(ascii: "["):
                index += 1
                while index < bytes.count, !(0x40...0x7E).contains(bytes[index]) {
                    index += 1
                }
                index += 1
            case UInt8(ascii: "]"):
                index += 1
                while index < bytes.count {
                    if bytes[index] == 0x07 { index += 1; break }
                    if bytes[index] == 0x1B, index + 1 < bytes.count,
                       bytes[index + 1] == UInt8(ascii: "\\") {
                        index += 2
                        break
                    }
                    index += 1
                }
            default:
                index += 1
            }
        }
        return output
    }
}

/// An isolated workspace + `$HOME`/`$OPENGROK_HOME` so the executor's hook
/// and MCP discovery cannot pick up the developer's real configuration.
private struct QuestionWorkspace {
    let root: URL
    let environment: [String: String]

    init() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-askuser-live-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("repo", isDirectory: true)
        let home = base.appendingPathComponent("home", isDirectory: true)
        let grokHome = home.appendingPathComponent(".opengrok", isDirectory: true)
        for directory in [root, home, grokHome] {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        environment = [
            "HOME": home.path,
            "OPENGROK_HOME": grokHome.path,
        ]
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }
}

private func makeExecutor(
    _ workspace: QuestionWorkspace,
    userQuestions: (any UserQuestionPresenting)? = nil,
    subagent: Bool = false
) async throws -> LiveToolExecutor {
    try await LiveToolExecutor(
        processBackend: InertShellBackend(),
        sessionID: "ask-user-live",
        workingDirectory: workspace.root,
        toolPolicy: nil,
        telemetryBootstrapContext: .empty,
        fileAccessPolicy: .allowAll,
        environment: workspace.environment,
        subagent: subagent,
        userQuestions: userQuestions
    )
}

private func databaseQuestionCall() -> ToolCall {
    ToolCall(
        id: "ask-1",
        name: "ask_user_question",
        arguments: """
        {"questions": [{"question": "Which database?", "options": [\
        {"label": "Redis", "description": "In-memory"}, \
        {"label": "Postgres", "description": "Relational"}]}]}
        """
    )
}

// MARK: - Tests

@Suite("ask_user_question live seam", .serialized)
struct LiveAskUserQuestionReachabilityTests {
    @Test("the registered tool blocks on the live sheet and returns the key-picked answer")
    func endToEndAnswerThroughRenderer() async throws {
        let workspace = QuestionWorkspace()
        defer { workspace.cleanup() }

        let coordinator = PagerQuestionCoordinator()
        let executor = try await makeExecutor(
            workspace,
            userQuestions: LiveUserQuestionBroker(coordinator: coordinator)
        )
        #expect(executor.tools.map(\.name).contains("ask_user_question"))

        let sink = CapturingSink()
        let terminal = OpenGrokLiveTerminal(
            isTTY: { false },
            size: { OpenGrokLiveTerminalSize(width: 100, height: 30) },
            write: { _ in }
        )
        let renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: terminal,
            sink: sink,
            workingDirectory: workspace.root.path,
            modelName: "test-model",
            questionCoordinator: coordinator,
            paintCadence: PagerMotion.minimumPaintCadence
        )
        try await renderer.begin()

        // The model's call, through the same executor entry point the turn
        // loop uses. It suspends until the user answers on the sheet.
        let sessionID = "ask-user-live"
        let cwd = workspace.root
        let invocation = Task {
            await executor.invoke(
                sessionID: sessionID,
                workingDirectory: cwd,
                call: databaseQuestionCall()
            )
        }

        // The sheet must actually paint before keys can mean anything.
        var deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !sink.strippedText.contains("Which database?") {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(sink.strippedText.contains("Question 1 of 1"))
        #expect(sink.strippedText.contains("Which database?"))
        #expect(sink.strippedText.contains("Redis"))

        // Down to "Postgres", Enter to answer — synthetic keys through the
        // same input router a real terminal feeds.
        #expect(try await renderer.handleInput(.key(KeyEvent(key: .down))) == .consumed)
        #expect(try await renderer.handleInput(.key(KeyEvent(key: .enter))) == .consumed)

        let result = await invocation.value
        guard case .success(let output) = result else {
            Issue.record("expected an answered tool result, got \(result)")
            try await renderer.restoreTerminal()
            return
        }
        let text = output.promptText
        #expect(text.contains("User has answered your questions:"))
        #expect(text.contains("\"Which database?\"=\"Postgres\""))

        // The sheet is gone and the coordinator queue drained.
        deadline = Date().addingTimeInterval(5)
        while Date() < deadline, await coordinator.pendingCount != 0 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await coordinator.pendingCount == 0)
        try await renderer.restoreTerminal()
    }

    @Test("Esc on the sheet resolves the blocked tool with upstream's cancel text")
    func escapeCancelsThroughRenderer() async throws {
        let workspace = QuestionWorkspace()
        defer { workspace.cleanup() }

        let coordinator = PagerQuestionCoordinator()
        let executor = try await makeExecutor(
            workspace,
            userQuestions: LiveUserQuestionBroker(coordinator: coordinator)
        )
        let sink = CapturingSink()
        let terminal = OpenGrokLiveTerminal(
            isTTY: { false },
            size: { OpenGrokLiveTerminalSize(width: 100, height: 30) },
            write: { _ in }
        )
        let renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: terminal,
            sink: sink,
            workingDirectory: workspace.root.path,
            modelName: "test-model",
            questionCoordinator: coordinator,
            paintCadence: PagerMotion.minimumPaintCadence
        )
        try await renderer.begin()

        let sessionID = "ask-user-live"
        let cwd = workspace.root
        let invocation = Task {
            await executor.invoke(
                sessionID: sessionID,
                workingDirectory: cwd,
                call: databaseQuestionCall()
            )
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !sink.strippedText.contains("Which database?") {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(try await renderer.handleInput(.key(KeyEvent(key: .escape))) == .consumed)

        let result = await invocation.value
        guard case .success(let output) = result else {
            Issue.record("expected a cancelled tool result, got \(result)")
            try await renderer.restoreTerminal()
            return
        }
        // Cancel is a user decision the turn continues from (`format.rs:22`),
        // not a tool failure.
        #expect(output.promptText == "User declined to answer the questions. Continue with the task using your best judgment, or ask different questions.")
        try await renderer.restoreTerminal()
    }

    @Test("the headless composition does not advertise ask_user_question at all")
    func headlessDoesNotAdvertise() async throws {
        let workspace = QuestionWorkspace()
        defer { workspace.cleanup() }

        // No broker — the shape `makeSessionFoundation` builds for `-p` and
        // non-TTY launches. The tool must be absent from what the model sees,
        // not present-and-erroring (§4: no dead surfaces).
        let executor = try await makeExecutor(workspace, userQuestions: nil)
        let advertised = Set(executor.tools.map(\.name))
        #expect(!advertised.contains("ask_user_question"))

        // And dispatch agrees with advertisement: the name is unknown, not a
        // registered tool that fails.
        let result = await executor.invoke(
            sessionID: "ask-user-live",
            workingDirectory: workspace.root,
            call: databaseQuestionCall()
        )
        guard case .failure(let error) = result else {
            Issue.record("expected unknown-tool failure, got \(result)")
            return
        }
        #expect(error.description.contains("unknown tool"))
    }

    @Test("the foundation gates the question surface on the real interactive input, not stdout")
    func foundationGatesOnInteractiveSurface() async throws {
        // Wave 14 review finding: the coordinators used to gate on stdout
        // TTY-ness alone, so an `open-grok < file` launch (stdout a TTY,
        // stdin not) advertised a tool no presenter could ever answer. The
        // launcher now derives `interactiveSurfaceAvailable` from the
        // constructed input AND sink; this pins the foundation half of that
        // gate for both values.
        let workspace = QuestionWorkspace()
        defer { workspace.cleanup() }
        let command = try CLICommandParser.parseOrThrow(
            ["interactive", "--cwd", workspace.root.path]
        )
        guard case .launch(let options) = command else {
            Issue.record("fixture did not parse to a launch")
            return
        }
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { _, _ in
                    OpenGrokLiveSamplingResponse(output: "unused", stopReason: "stop")
                }
            }
        )
        func foundation(interactiveSurfaceAvailable: Bool) async throws -> OpenGrokLiveApplicationLauncher.LiveSessionFoundation {
            let (streams, _, _) = CLIStreams.buffered()
            return try await OpenGrokLiveApplicationLauncher.makeSessionFoundation(
                options: options,
                context: CLIApplicationContext(
                    environment: [
                        "HOME": workspace.root.path,
                        "OPENGROK_HOME": workspace.root.appendingPathComponent("state").path,
                        "XAI_API_KEY": "test-key",
                    ],
                    streams: streams,
                    control: .never
                ),
                dependencies: dependencies,
                interactiveSurfaceAvailable: interactiveSurfaceAvailable
            )
        }

        let withSurface = try await foundation(interactiveSurfaceAvailable: true)
        #expect(withSurface.questionCoordinator != nil)
        #expect(withSurface.planApprovalCoordinator != nil)
        #expect(Set(withSurface.toolExecutor.tools.map(\.name)).contains("ask_user_question"))

        let withoutSurface = try await foundation(interactiveSurfaceAvailable: false)
        #expect(withoutSurface.questionCoordinator == nil)
        #expect(withoutSurface.planApprovalCoordinator == nil)
        #expect(!Set(withoutSurface.toolExecutor.tools.map(\.name)).contains("ask_user_question"))
    }

    @Test("a subagent executor does not advertise ask_user_question even with a broker")
    func subagentDoesNotAdvertise() async throws {
        let workspace = QuestionWorkspace()
        defer { workspace.cleanup() }

        let coordinator = PagerQuestionCoordinator()
        let executor = try await makeExecutor(
            workspace,
            userQuestions: LiveUserQuestionBroker(coordinator: coordinator),
            subagent: true
        )
        #expect(!executor.tools.map(\.name).contains("ask_user_question"))
    }
}
