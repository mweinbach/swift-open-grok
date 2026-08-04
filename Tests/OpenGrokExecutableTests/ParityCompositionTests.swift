import Foundation
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokShell
import OpenGrokShellBase
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokCLI

private final class ParityTerminalFixture: @unchecked Sendable {
    private let lock = NSLock()
    private let tty: Bool
    private let terminalSize: OpenGrokLiveTerminalSize?
    private var storage = Data()

    init(tty: Bool, size: OpenGrokLiveTerminalSize?) {
        self.tty = tty
        self.terminalSize = size
    }

    var terminal: OpenGrokLiveTerminal {
        let fixture = self
        return OpenGrokLiveTerminal(
            isTTY: { fixture.tty },
            size: { fixture.terminalSize },
            write: { data in fixture.append(data) }
        )
    }

    var output: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: storage, as: UTF8.self)
    }

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }
}

private final class ParityTerminalSink: PagerTerminalSink {
    let capabilities = PagerTerminalCapabilities.standard
    private let terminal: ParityTerminalFixture

    init(terminal: ParityTerminalFixture) {
        self.terminal = terminal
    }

    func write(bytes: [UInt8]) throws {
        terminal.append(Data(bytes))
    }

    func flush() throws {}
}

private enum ParityInputEvent: Sendable, Equatable {
    case prompt(String)
    case ctrlC
    case eof
}

private actor ParityInputFixture {
    private var events: [ParityInputEvent]

    init(_ events: [ParityInputEvent]) {
        self.events = events
    }

    func next() -> ParityInputEvent? {
        guard !events.isEmpty else { return nil }
        return events.removeFirst()
    }
}

private final class ParitySamplerFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: OpenGrokLiveSamplingResponse]
    private var requests: [OpenGrokLiveSamplingRequest] = []

    init(responses: [String: OpenGrokLiveSamplingResponse]) {
        self.responses = responses
    }

    var recordedRequests: [OpenGrokLiveSamplingRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func makeSampler() -> OpenGrokLiveSampler {
        let fixture = self
        return OpenGrokLiveSampler { request, emit in
            let response = fixture.recordAndResolve(request)
            await emit(.status("sampling"))
            await emit(.output(response.output))
            return response
        }
    }

    private func recordAndResolve(_ request: OpenGrokLiveSamplingRequest) -> OpenGrokLiveSamplingResponse {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        return responses.removeValue(forKey: request.prompt)
            ?? OpenGrokLiveSamplingResponse(output: "missing response")
    }
}

private actor ParityProviderSession: OpenGrokShellProviderSession {
    private var activeTurnID: String?
    private(set) var completedTurnIDs: [String] = []
    private(set) var cancelledTurnIDs: [String] = []

    func snapshot() async -> OpenGrokShellProviderSessionSnapshot {
        OpenGrokShellProviderSessionSnapshot(
            sessionID: "parity-session",
            modelID: "grok-test",
            provider: "xai",
            generation: 0
        )
    }

    func beginTurn(turnID: String) async throws -> OpenGrokShellProviderTurnContext {
        guard activeTurnID == nil else {
            throw OpenGrokShellError.turnAlreadyActive(turnID)
        }
        activeTurnID = turnID
        return OpenGrokShellProviderTurnContext(
            sessionID: "parity-session",
            turnID: turnID,
            modelID: "grok-test",
            attempt: 1
        )
    }

    func finishTurn(turnID: String) async throws {
        guard activeTurnID == turnID else {
            throw OpenGrokShellError.turnNotFound(turnID)
        }
        activeTurnID = nil
        completedTurnIDs.append(turnID)
    }

    func failTurn(turnID: String) async {
        if activeTurnID == turnID {
            activeTurnID = nil
        }
    }

    func cancelTurn(turnID: String) async throws {
        guard activeTurnID == turnID else {
            throw OpenGrokShellError.turnNotFound(turnID)
        }
        activeTurnID = nil
        cancelledTurnIDs.append(turnID)
    }
}

private struct ParityLiveTurnDriver: OpenGrokShellSamplingDriver, Sendable {
    let sampler: OpenGrokLiveSampler

    func sample(
        context: OpenGrokShellProviderTurnContext,
        request: OpenGrokShellTurnRequest,
        emit: @escaping @Sendable (OpenGrokShellTurnUpdateKind) async -> Void
    ) async throws -> OpenGrokShellSamplingResult {
        let response = try await sampler.sample(OpenGrokLiveSamplingRequest(
            sessionID: context.sessionID,
            turnID: context.turnID,
            model: context.modelID,
            prompt: request.text
        )) { event in
            switch event {
            case .output(let output):
                await emit(.assistantText(output))
            case .status(let status):
                await emit(.status(status))
            }
        }
        return OpenGrokShellSamplingResult(
            output: response.output,
            stopReason: response.stopReason
        )
    }
}

private actor ParityPagerRenderer: OpenGrokPagerRenderAdapter {
    private(set) var began = false
    private(set) var restoredCount = 0
    private(set) var renderedEvents: [OpenGrokPagerEvent] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func begin() async throws {
        began = true
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func render(_ event: OpenGrokPagerEvent) async throws {
        renderedEvents.append(event)
    }

    func restoreTerminal() async throws {
        restoredCount += 1
    }

    func waitForBegin() async {
        guard !began else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor ParityPagerSession: OpenGrokPagerSessionAdapter {
    nonisolated let sessionID: String?
    nonisolated let events: AsyncThrowingStream<OpenGrokPagerEvent, Error>

    private var continuation: AsyncThrowingStream<OpenGrokPagerEvent, Error>.Continuation!
    private var didCancel = false
    private var cancellationCount = 0
    private var closureCount = 0

    init(sessionID: String, initialEvents: [OpenGrokPagerEvent] = []) {
        self.sessionID = sessionID
        var streamContinuation: AsyncThrowingStream<OpenGrokPagerEvent, Error>.Continuation!
        self.events = AsyncThrowingStream { streamContinuation = $0 }
        self.continuation = streamContinuation
        for event in initialEvents {
            streamContinuation.yield(event)
        }
    }

    func cancel() async {
        guard !didCancel else { return }
        didCancel = true
        cancellationCount += 1
        let streamContinuation = continuation
        streamContinuation?.yield(.cancelled)
        streamContinuation?.finish()
    }

    func close() async {
        closureCount += 1
        let streamContinuation = continuation
        streamContinuation?.finish()
    }

    var cancelCount: Int {
        cancellationCount
    }

    var closeCount: Int {
        closureCount
    }
}

private struct ParityPagerRuntime: OpenGrokPagerRuntimeAdapter, Sendable {
    let session: ParityPagerSession

    func makeSession(for request: OpenGrokPagerRequest) async throws -> any OpenGrokPagerSessionAdapter {
        session
    }
}

private struct ParityPagerFrontendFactory: OpenGrokPagerFrontendFactory, Sendable {
    let renderer: ParityPagerRenderer

    func makeFrontend(for mode: OpenGrokPagerMode) async throws -> any OpenGrokPagerFrontend {
        _ = mode
        return OpenGrokPagerForwardingFrontend(renderer: renderer, output: ParityPagerOutput())
    }
}

private struct ParityPagerOutput: OpenGrokPagerOutputAdapter, Sendable {
    func forward(_ event: OpenGrokPagerEvent) async throws {
        _ = event
    }
}

private final class ParityCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

private actor ParitySignal {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        signaled = true
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func wait() async {
        guard !signaled else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor ParityShellCommandBackend: ShellProcessBackend {
    private(set) var requests: [ShellCommandRequest] = []

    func run(_ request: ShellCommandRequest) async throws -> ShellCommandResult {
        requests.append(request)
        return ShellCommandResult(combinedOutput: "tool output", stdout: "tool output", exitCode: 0)
    }

    func runBackground(_ request: ShellCommandRequest) async throws -> ShellBackgroundHandle {
        requests.append(request)
        return ShellBackgroundHandle(taskID: "background-tool")
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

private struct ParityShellCommandTool: Sendable {
    let backend: any ShellProcessBackend

    func call(command: String, sessionID: String) async throws -> ShellCommandResult {
        try await backend.run(ShellCommandRequest(
            command: command,
            toolCallID: "tool-1",
            ownerSessionID: sessionID,
            description: "parity shell command"
        ))
    }
}

@Suite("OpenGrok executable parity composition")
struct ParityCompositionTests {
    @Test("live interactive composition reuses one session across typed turns")
    func liveInteractiveMultiTurnComposition() async {
        let terminal = ParityTerminalFixture(
            tty: true,
            size: OpenGrokLiveTerminalSize(width: 60, height: 12)
        )
        let sampler = ParitySamplerFixture(responses: [
            "first question": OpenGrokLiveSamplingResponse(output: "first answer"),
            "second question": OpenGrokLiveSamplingResponse(output: "second answer")
        ])
        let input = AsyncThrowingStream<InputEvent, Error> { continuation in
            Task {
                for event in Self.typed("first question") + [.key(KeyEvent(key: .enter))] {
                    continuation.yield(event)
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
                for event in Self.typed("second question") + [.key(KeyEvent(key: .enter))] {
                    continuation.yield(event)
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
                continuation.yield(.key(KeyEvent(
                    key: .char("d"),
                    modifiers: .control,
                    character: "d"
                )))
                continuation.finish()
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in sampler.makeSampler() },
            terminal: terminal.terminal,
            makeInteractiveInput: {
                OpenGrokLiveInteractiveInput(events: input, close: {})
            },
            makeTerminalSink: {
                ParityTerminalSink(terminal: terminal)
            }
        )
        let application = OpenGrokApplication.live(dependencies: dependencies, control: .never)
        let (streams, out, err) = CLIStreams.buffered()

        let code = await CLIRunner.run(
            ["interactive"],
            environment: [
                "HOME": root.path,
                "OPENGROK_HOME": root.appendingPathComponent("state").path,
                "XAI_API_KEY": "test-key"
            ],
            streams: streams,
            application: application
        )

        let requests = sampler.recordedRequests
        #expect(code == CLIRunner.ExitCode.success.rawValue)
        #expect(out.contents.isEmpty)
        #expect(err.contents.isEmpty)
        #expect(requests.map(\.prompt) == ["first question", "second question"])
        #expect(Set(requests.map(\.sessionID)).count == 1)
        #expect(terminal.output.contains("\u{1B}[?1049h"))
        #expect(terminal.output.contains("\u{1B}[?1049l"))
        #expect(terminal.output.hasSuffix(
            "You: first question\nGrok: first answer\nYou: second question\nGrok: second answer\n"
        ))
    }

    @Test("injected input drives multiple sampler-backed turns")
    func multipleInteractiveTurns() async throws {
        let input = ParityInputFixture([
            .prompt("first question"),
            .prompt("second question"),
            .eof
        ])
        let samplerFixture = ParitySamplerFixture(responses: [
            "first question": OpenGrokLiveSamplingResponse(output: "first answer", stopReason: "stop"),
            "second question": OpenGrokLiveSamplingResponse(output: "second answer", stopReason: "stop")
        ])
        let turnDriver = ProviderSessionTurnDriver(sampler: ParityLiveTurnDriver(sampler: samplerFixture.makeSampler()))
        let providerSession = ParityProviderSession()
        var outputs: [String] = []

        while let event = await input.next() {
            switch event {
            case .prompt(let prompt):
                let result = try await turnDriver.submit(
                    providerSession: providerSession,
                    request: OpenGrokShellTurnRequest(promptID: prompt, text: prompt, turnID: prompt),
                    emit: { update in
                        _ = update
                    }
                )
                outputs.append(result.output)
            case .ctrlC:
                try await turnDriver.cancel(providerSession: providerSession, turnID: "active")
            case .eof:
                break
            }
        }

        #expect(outputs == ["first answer", "second answer"])
        #expect(samplerFixture.recordedRequests.map(\.prompt) == ["first question", "second question"])
        #expect(await providerSession.completedTurnIDs == ["first question", "second question"])
    }

    @Test("full-screen live composition restores the terminal")
    func fullScreenRestoration() async {
        let terminal = ParityTerminalFixture(tty: true, size: OpenGrokLiveTerminalSize(width: 60, height: 12))
        let sampler = ParitySamplerFixture(responses: [
            "render full screen": OpenGrokLiveSamplingResponse(output: "full-screen answer")
        ])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in sampler.makeSampler() },
            terminal: terminal.terminal
        )
        let application = OpenGrokApplication.live(dependencies: dependencies, control: .never)
        let (streams, out, err) = CLIStreams.buffered()

        let code = await CLIRunner.run(
            ["interactive", "--prompt", "render full screen"],
            environment: [
                "HOME": root.path,
                "OPENGROK_HOME": root.appendingPathComponent("state").path,
                "XAI_API_KEY": "test-key"
            ],
            streams: streams,
            application: application
        )

        #expect(code == CLIRunner.ExitCode.success.rawValue)
        #expect(out.contents.isEmpty)
        #expect(err.contents.isEmpty)
        #expect(terminal.output.contains("\u{1B}[?1049h"))
        #expect(terminal.output.contains("\u{1B}[?1049l"))
        #expect(terminal.output.hasSuffix("You: render full screen\nGrok: full-screen answer\n"))
    }

    @Test("non-TTY live composition falls back inline")
    func inlineFallback() async {
        let terminal = ParityTerminalFixture(tty: false, size: nil)
        let sampler = ParitySamplerFixture(responses: [
            "render inline": OpenGrokLiveSamplingResponse(output: "inline answer")
        ])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in sampler.makeSampler() },
            terminal: terminal.terminal
        )
        let application = OpenGrokApplication.live(dependencies: dependencies, control: .never)
        let (streams, out, err) = CLIStreams.buffered()

        let code = await CLIRunner.run(
            ["interactive", "--prompt", "render inline"],
            environment: [
                "HOME": root.path,
                "OPENGROK_HOME": root.appendingPathComponent("state").path,
                "XAI_API_KEY": "test-key"
            ],
            streams: streams,
            application: application
        )

        #expect(code == CLIRunner.ExitCode.success.rawValue)
        #expect(out.contents.isEmpty)
        #expect(err.contents.isEmpty)
        #expect(terminal.output == "You: render inline\nGrok: inline answer\n")
        #expect(!terminal.output.contains("\u{1B}[?1049h"))
    }

    @Test("Ctrl-C cancels the live turn and restores the terminal")
    func ctrlCCancellation() async {
        let terminal = ParityTerminalFixture(tty: true, size: OpenGrokLiveTerminalSize(width: 60, height: 12))
        let started = ParitySignal()
        let sampler = OpenGrokLiveSampler { _, _ in
            await started.signal()
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch is CancellationError {
                throw CancellationError()
            }
            return OpenGrokLiveSamplingResponse(output: "unexpected")
        }
        let cancellation = ParityCancellationBox()
        let control = CLIExecutionControl(
            isCancelled: { cancellation.isCancelled },
            waitForCancellation: {
                while !cancellation.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000)
                }
            }
        )
        let input = ParityInputFixture([.ctrlC])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in sampler },
            terminal: terminal.terminal
        )
        let application = OpenGrokApplication.live(dependencies: dependencies, control: control)
        let (streams, _, _) = CLIStreams.buffered()
        let task = Task {
            await CLIRunner.run(
                ["interactive", "--prompt", "cancel me"],
                environment: [
                    "HOME": root.path,
                    "OPENGROK_HOME": root.appendingPathComponent("state").path,
                    "XAI_API_KEY": "test-key"
                ],
                streams: streams,
                application: application
            )
        }

        await started.wait()
        if await input.next() == .ctrlC {
            cancellation.cancel()
        }
        let code = await task.value

        #expect(code == CLIRunner.ExitCode.cancelled.rawValue)
        #expect(terminal.output.contains("\u{1B}[?1049l"))
    }

    @Test("EOF shuts down a pager and restores its terminal exactly once")
    func eofShutdown() async throws {
        let input = ParityInputFixture([.eof])
        let renderer = ParityPagerRenderer()
        let session = ParityPagerSession(
            sessionID: "eof-session",
            initialEvents: [.output("still running")]
        )
        let pager = OpenGrokPager(
            runtime: ParityPagerRuntime(session: session),
            frontendFactory: ParityPagerFrontendFactory(renderer: renderer)
        )
        let task = Task {
            try await pager.run(OpenGrokPagerRequest(
                prompt: "EOF",
                mode: .inline,
                sessionID: "eof-session"
            ))
        }

        await renderer.waitForBegin()
        if await input.next() == .eof {
            await pager.shutdown()
        }
        let result = try await task.value

        #expect(result.terminalRestored)
        #expect(await renderer.restoredCount == 1)
        #expect(await session.cancelCount >= 1)
        #expect(await session.closeCount == 1)
    }

    @Test("injected shell process seam preserves tool-call metadata")
    func shellCommandToolCall() async throws {
        let backend = ParityShellCommandBackend()
        let tool = ParityShellCommandTool(backend: backend)

        let result = try await tool.call(command: "printf tool", sessionID: "shell-session")
        let requests = await backend.requests

        #expect(result.combinedOutput == "tool output")
        #expect(requests.count == 1)
        #expect(requests.first?.command == "printf tool")
        #expect(requests.first?.toolCallID == "tool-1")
        #expect(requests.first?.ownerSessionID == "shell-session")
    }

    private static func typed(_ text: String) -> [InputEvent] {
        text.map { character in
            .key(KeyEvent(key: .char(character), character: character))
        }
    }
}
