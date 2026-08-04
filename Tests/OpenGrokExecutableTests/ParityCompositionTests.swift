import Foundation
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokSamplingTypes
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

private final class ParitySamplingConfigurationFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var configurations: [OpenGrokLiveSamplingConfiguration] = []

    var recordedConfigurations: [OpenGrokLiveSamplingConfiguration] {
        lock.lock()
        defer { lock.unlock() }
        return configurations
    }

    func makeSampler(configuration: OpenGrokLiveSamplingConfiguration) -> OpenGrokLiveSampler {
        lock.lock()
        configurations.append(configuration)
        lock.unlock()
        return OpenGrokLiveSampler { _, emit in
            await emit(.output("provider answer"))
            return OpenGrokLiveSamplingResponse(output: "provider answer", stopReason: "stop")
        }
    }
}

private final class ParityToolLoopSamplerFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [OpenGrokLiveSamplingRequest] = []

    var recordedRequests: [OpenGrokLiveSamplingRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func makeSampler() -> OpenGrokLiveSampler {
        let fixture = self
        return OpenGrokLiveSampler { request, emit in
            let requestIndex = fixture.record(request)
            if requestIndex == 0 {
                let call = ToolCall(
                    id: "call-1",
                    name: "run_terminal_cmd",
                    arguments: #"{"command":"printf tool-output","description":"parity tool"}"#
                )
                return OpenGrokLiveSamplingResponse(
                    output: "",
                    stopReason: "tool_calls",
                    items: [.assistant(AssistantItem(content: "", toolCalls: [call]))]
                )
            }

            let toolResult = request.items.compactMap { item -> ToolResultItem? in
                guard case .toolResult(let result) = item else { return nil }
                return result
            }.last
            let answer = "final answer after \(toolResult?.content ?? "missing tool result")"
            await emit(.output(answer))
            return OpenGrokLiveSamplingResponse(output: answer, stopReason: "stop")
        }
    }

    private func record(_ request: OpenGrokLiveSamplingRequest) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let index = requests.count
        requests.append(request)
        return index
    }
}

private final class ParityFileToolSamplerFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [OpenGrokLiveSamplingRequest] = []
    private let arguments: String

    init(arguments: String) {
        self.arguments = arguments
    }

    var recordedRequests: [OpenGrokLiveSamplingRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func makeSampler() -> OpenGrokLiveSampler {
        let fixture = self
        return OpenGrokLiveSampler { request, emit in
            let requestIndex = fixture.record(request)
            if requestIndex == 0 {
                let call = ToolCall(
                    id: "file-call-1",
                    name: "read_file",
                    arguments: fixture.arguments
                )
                return OpenGrokLiveSamplingResponse(
                    output: "",
                    stopReason: "tool_calls",
                    items: [.assistant(AssistantItem(content: "", toolCalls: [call]))]
                )
            }

            let toolResult = request.items.compactMap { item -> ToolResultItem? in
                guard case .toolResult(let result) = item else { return nil }
                return result
            }.last
            let answer = "file tool result: \(toolResult?.content ?? "missing")"
            await emit(.output(answer))
            return OpenGrokLiveSamplingResponse(output: answer, stopReason: "stop")
        }
    }

    private func record(_ request: OpenGrokLiveSamplingRequest) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let index = requests.count
        requests.append(request)
        return index
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
    @Test("live composition resolves built-in API-key provider profiles")
    func liveProviderProfiles() async {
        struct ProviderCase {
            let arguments: [String]
            let environment: [String: String]
            let provider: ModelProvider
            let model: String
            let baseURL: String
            let apiBackend: ApiBackend
            let apiKey: String
        }

        let cases = [
            ProviderCase(
                arguments: ["headless", "--prompt", "hello"],
                environment: ["XAI_API_KEY": "xai-key"],
                provider: .xai,
                model: "grok-4.5",
                baseURL: "https://api.x.ai/v1",
                apiBackend: .responses,
                apiKey: "xai-key"
            ),
            ProviderCase(
                arguments: ["headless", "--prompt", "hello", "--provider", "kimi"],
                environment: [
                    "OPENGROK_KIMI_API_BASE_URL": "https://api.kimi.com/coding/v1",
                    "MOONSHOT_API_KEY": "wrong-platform-key",
                    "KIMI_CODE_API_KEY": "kimi-code-key"
                ],
                provider: .kimi,
                model: "kimi-for-coding",
                baseURL: "https://api.kimi.com/coding/v1",
                apiBackend: .chatCompletions,
                apiKey: "kimi-code-key"
            ),
            ProviderCase(
                arguments: ["headless", "--prompt", "hello", "--model", "kimi-for-coding"],
                environment: ["KIMI_CODE_API_KEY": "kimi-code-key"],
                provider: .kimi,
                model: "kimi-for-coding",
                baseURL: "https://api.kimi.com/coding/v1",
                apiBackend: .chatCompletions,
                apiKey: "kimi-code-key"
            ),
            ProviderCase(
                arguments: ["headless", "--prompt", "hello", "--provider", "fireworks"],
                environment: ["FIREWORKS_API_KEY": "fireworks-key"],
                provider: .fireworks,
                model: "accounts/fireworks/models/glm-5p2",
                baseURL: "https://api.fireworks.ai/inference/v1",
                apiBackend: .chatCompletions,
                apiKey: "fireworks-key"
            ),
        ]

        for providerCase in cases {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = ParitySamplingConfigurationFixture()
            let dependencies = OpenGrokLiveCompositionDependencies(
                makeSampler: fixture.makeSampler(configuration:)
            )
            let application = OpenGrokApplication.live(dependencies: dependencies, control: .never)
            let (streams, out, err) = CLIStreams.buffered()
            var environment = providerCase.environment
            environment["HOME"] = root.path
            environment["OPENGROK_HOME"] = root.appendingPathComponent("state").path

            let code = await CLIRunner.run(
                providerCase.arguments,
                environment: environment,
                streams: streams,
                application: application
            )

            let configuration = fixture.recordedConfigurations.first
            #expect(code == CLIRunner.ExitCode.success.rawValue)
            #expect(err.contents.isEmpty)
            #expect(out.contents.contains("provider answer"))
            #expect(configuration?.provider == providerCase.provider)
            #expect(configuration?.model == providerCase.model)
            #expect(configuration?.baseURL == providerCase.baseURL)
            #expect(configuration?.apiBackend == providerCase.apiBackend)
            #expect(configuration?.apiKey == providerCase.apiKey)
        }
    }

    @Test("live headless composition executes provider tool calls and resamples")
    func liveHeadlessToolLoopComposition() async {
        let backend = ParityShellCommandBackend()
        let sampler = ParityToolLoopSamplerFixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in sampler.makeSampler() },
            makeProcessBackend: { backend }
        )
        let application = OpenGrokApplication.live(dependencies: dependencies, control: .never)
        let (streams, out, err) = CLIStreams.buffered()

        let code = await CLIRunner.run(
            ["headless", "--prompt", "use the terminal", "--cwd", root.path],
            environment: [
                "HOME": root.path,
                "OPENGROK_HOME": root.appendingPathComponent("state").path,
                "XAI_API_KEY": "test-key"
            ],
            streams: streams,
            application: application
        )

        let samplerRequests = sampler.recordedRequests
        let processRequests = await backend.requests
        #expect(code == CLIRunner.ExitCode.success.rawValue)
        #expect(err.contents.contains("running tool run_terminal_cmd"))
        #expect(out.contents.contains("final answer after tool output"))
        #expect(samplerRequests.count == 2)
        #expect(samplerRequests.first?.tools.map(\.name).contains("run_terminal_cmd") == true)
        #expect(samplerRequests.first?.tools.map(\.name).contains("read_file") == true)
        #expect(samplerRequests.first?.tools.map(\.name).contains("list_dir") == true)
        #expect(samplerRequests.first?.tools.map(\.name).contains("grep") == true)
        #expect(samplerRequests.last?.items.contains { item in
            guard case .toolResult(let result) = item else { return false }
            return result.toolCallId == "call-1"
                && result.content.contains("tool output")
        } == true)
        #expect(processRequests.count == 1)
        #expect(processRequests.first?.command == "printf tool-output")
        #expect(processRequests.first?.workingDirectory == root.standardizedFileURL)
        #expect(processRequests.first?.toolCallID == "call-1")
        #expect(processRequests.first?.ownerSessionID != nil)
    }

    @Test("live headless composition executes sandboxed read-only file tools")
    func liveHeadlessFileToolComposition() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? "file tool contents\n".write(
            to: root.appendingPathComponent("sample.txt"),
            atomically: true,
            encoding: .utf8
        )
        let sampler = ParityFileToolSamplerFixture(
            arguments: #"{"target_file":"sample.txt"}"#
        )
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in sampler.makeSampler() }
        )
        let application = OpenGrokApplication.live(dependencies: dependencies, control: .never)
        let (streams, out, err) = CLIStreams.buffered()

        let code = await CLIRunner.run(
            ["headless", "--prompt", "read the file", "--cwd", root.path],
            environment: [
                "HOME": root.path,
                "OPENGROK_HOME": root.appendingPathComponent("state").path,
                "XAI_API_KEY": "test-key"
            ],
            streams: streams,
            application: application
        )

        let requests = sampler.recordedRequests
        let toolResult = requests.last?.items.compactMap { item -> ToolResultItem? in
            guard case .toolResult(let result) = item else { return nil }
            return result
        }.last
        #expect(code == CLIRunner.ExitCode.success.rawValue)
        #expect(err.contents.contains("running tool read_file"))
        #expect(out.contents.contains("file tool contents"))
        #expect(requests.count == 2)
        #expect(Set(requests.first?.tools.map(\.name) ?? []) == Set([
            "run_terminal_cmd", "read_file", "list_dir", "grep"
        ]))
        #expect(toolResult?.toolCallId == "file-call-1")
        #expect(toolResult?.content.contains("file tool contents") == true)
    }

    @Test("live file tools reject paths outside the working directory")
    func liveFileToolSandbox() async {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = parent.appendingPathComponent("workspace")
        defer { try? FileManager.default.removeItem(at: parent) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? "outside secret\n".write(
            to: parent.appendingPathComponent("outside.txt"),
            atomically: true,
            encoding: .utf8
        )
        let sampler = ParityFileToolSamplerFixture(
            arguments: #"{"target_file":"../outside.txt"}"#
        )
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in sampler.makeSampler() }
        )
        let application = OpenGrokApplication.live(dependencies: dependencies, control: .never)
        let (streams, out, _) = CLIStreams.buffered()

        let code = await CLIRunner.run(
            ["headless", "--prompt", "escape the workspace", "--cwd", root.path],
            environment: [
                "HOME": parent.path,
                "OPENGROK_HOME": parent.appendingPathComponent("state").path,
                "XAI_API_KEY": "test-key"
            ],
            streams: streams,
            application: application
        )

        let toolResult = sampler.recordedRequests.last?.items.compactMap { item -> ToolResultItem? in
            guard case .toolResult(let result) = item else { return nil }
            return result
        }.last
        #expect(code == CLIRunner.ExitCode.success.rawValue)
        #expect(out.contents.contains("outside secret") == false)
        #expect(toolResult?.content.contains("failed") == true)
    }

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
                await Self.waitForTerminalOutput("first answer", terminal: terminal)
                for event in Self.typed("second question") + [.key(KeyEvent(key: .enter))] {
                    continuation.yield(event)
                }
                await Self.waitForTerminalOutput("second answer", terminal: terminal)
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
        #expect(requests.first?.items == [
            .user("first question")
        ])
        #expect(requests.last?.items == [
            .user("first question"),
            .assistant(AssistantItem(content: "first answer")),
            .user("second question")
        ])
        #expect(terminal.output.contains("\u{1B}[?1049h"))
        #expect(terminal.output.contains("\u{1B}[?1049l"))
        #expect(terminal.output.hasSuffix(
            "You: first question\nGrok: first answer\nYou: second question\nGrok: second answer\n"
        ))
    }

    @Test("live interactive composition redraws after terminal resize")
    func liveInteractiveResizeComposition() async {
        let terminal = ParityTerminalFixture(
            tty: true,
            size: OpenGrokLiveTerminalSize(width: 60, height: 12)
        )
        let sampler = ParitySamplerFixture(responses: [
            "resize question": OpenGrokLiveSamplingResponse(output: "resized answer")
        ])
        let input = AsyncThrowingStream<InputEvent, Error> { continuation in
            Task {
                continuation.yield(.resize(TerminalSize(width: 40, height: 8)))
                for event in Self.typed("resize question") + [.key(KeyEvent(key: .enter))] {
                    continuation.yield(event)
                }
                await Self.waitForTerminalOutput("resized answer", terminal: terminal)
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

        let fullScreenClearCount = terminal.output.components(separatedBy: "\u{1B}[2J").count - 1
        #expect(code == CLIRunner.ExitCode.success.rawValue)
        #expect(out.contents.isEmpty)
        #expect(err.contents.isEmpty)
        #expect(sampler.recordedRequests.map(\.prompt) == ["resize question"])
        #expect(fullScreenClearCount >= 2)
        #expect(terminal.output.hasSuffix("You: resize question\nGrok: resized answer\n"))
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

    private static func waitForTerminalOutput(
        _ text: String,
        terminal: ParityTerminalFixture
    ) async {
        for _ in 0..<1_000 {
            if terminal.output.contains(text) {
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
