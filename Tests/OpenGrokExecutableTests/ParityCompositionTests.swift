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

    /// Painted text with the escape sequences removed.
    ///
    /// The renderer emits a cursor move and an SGR run before every glyph, so
    /// `output` never contains a readable word. Stripping the sequences leaves
    /// the cells in paint order, which for a full frame is reading order.
    var paintedText: String {
        var result = ""
        var iterator = output[...]
        while let escape = iterator.firstIndex(of: "\u{1B}") {
            result += iterator[iterator.startIndex..<escape]
            var cursor = iterator.index(after: escape)
            guard cursor < iterator.endIndex else { break }
            if iterator[cursor] == "[" || iterator[cursor] == "]" {
                let isOSC = iterator[cursor] == "]"
                cursor = iterator.index(after: cursor)
                while cursor < iterator.endIndex {
                    let scalar = iterator[cursor].unicodeScalars.first!.value
                    let isFinal = isOSC
                        ? (scalar == 0x07 || iterator[cursor] == "\\")
                        : (scalar >= 0x40 && scalar <= 0x7E)
                    cursor = iterator.index(after: cursor)
                    if isFinal { break }
                }
            } else {
                cursor = iterator.index(after: cursor)
            }
            iterator = iterator[cursor...]
        }
        result += iterator
        return result
    }

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }
}

@Suite("Wave 11 new-session reachability")
struct Wave11NewSessionCompositionTests {
    @Test("interactive /new rotates the live session and provider history")
    func interactiveNewSessionResetsProviderHistory() async throws {
        let terminal = ParityTerminalFixture(
            tty: true,
            size: OpenGrokLiveTerminalSize(width: 80, height: 20)
        )
        let sampler = ParitySamplerFixture(responses: [
            "first session prompt": OpenGrokLiveSamplingResponse(output: "first session answer"),
            "second session prompt": OpenGrokLiveSamplingResponse(output: "second session answer")
        ])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = AsyncThrowingStream<InputEvent, Error> { continuation in
            Task {
                for event in Self.typed("first session prompt") {
                    continuation.yield(event)
                }
                continuation.yield(.key(KeyEvent(key: .enter)))
                await Self.waitForTerminalOutput("first session answer", terminal: terminal)
                continuation.yield(.paste("/new"))
                continuation.yield(.key(KeyEvent(key: .enter)))
                for event in Self.typed("second session prompt") {
                    continuation.yield(event)
                }
                continuation.yield(.key(KeyEvent(key: .enter)))
                await Self.waitForTerminalOutput("second session answer", terminal: terminal)
                continuation.yield(.key(KeyEvent(
                    key: .char("d"),
                    modifiers: .control,
                    character: "d"
                )))
                continuation.finish()
            }
        }
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
            ["interactive", "--cwd", root.path],
            environment: [
                "HOME": root.path,
                "OPENGROK_HOME": root.appendingPathComponent("state").path,
                "XAI_API_KEY": "test-key"
            ],
            streams: streams,
            application: application
        )

        let requests = sampler.recordedRequests
        let sessionFiles = (try? FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("state/sessions"),
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }) ?? []
        let firstItems = requests.first?.items ?? []
        let secondItems = requests.dropFirst().first?.items ?? []
        func userTexts(_ items: [ConversationItem]) -> [String] {
            items.compactMap { item in
                guard case .user(let user) = item else { return nil }
                return user.content.compactMap { part in
                    guard case .text(let text) = part else { return nil }
                    return text
                }.joined()
            }
        }
        #expect(code == CLIRunner.ExitCode.success.rawValue)
        #expect(out.contents.isEmpty)
        #expect(err.contents.isEmpty)
        #expect(requests.count == 2)
        guard requests.count == 2 else { return }
        #expect(requests[0].sessionID != requests[1].sessionID)
        #expect(userTexts(firstItems).contains("first session prompt"))
        #expect(userTexts(secondItems).contains("second session prompt"))
        #expect(userTexts(secondItems).contains("first session prompt") == false)
        #expect(sessionFiles.count == 2)
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

/// Sampler that forwards an answer as a sequence of incremental deltas, the way
/// the production sampler forwards streamed assistant text.
private final class ParityStreamingSamplerFixture: @unchecked Sendable {
    private let lock = NSLock()
    private let deltas: [String]
    private let holdOpenAfterDeltas: Bool
    private var emitted: [String] = []
    private let started = ParitySignal()

    init(deltas: [String], holdOpenAfterDeltas: Bool = false) {
        self.deltas = deltas
        self.holdOpenAfterDeltas = holdOpenAfterDeltas
    }

    var answer: String { deltas.joined() }

    var emittedDeltas: [String] {
        lock.lock()
        defer { lock.unlock() }
        return emitted
    }

    /// Resolves once every delta has been delivered but before the turn
    /// completes, so a test can cancel with the stream genuinely mid-flight and
    /// without racing the deltas it wants to assert on.
    func waitForDeltas() async {
        await started.wait()
    }

    func makeSampler() -> OpenGrokLiveSampler {
        let fixture = self
        return OpenGrokLiveSampler { _, emit in
            await emit(.status("sampling"))
            for delta in fixture.deltas {
                try Task.checkCancellation()
                await emit(.output(delta))
                fixture.record(delta)
            }
            await fixture.started.signal()
            if fixture.holdOpenAfterDeltas {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            }
            return OpenGrokLiveSamplingResponse(
                output: fixture.answer,
                stopReason: "stop"
            )
        }
    }

    private func record(_ delta: String) {
        lock.lock()
        emitted.append(delta)
        lock.unlock()
    }
}

private final class ParitySamplingConfigurationFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var configurations: [OpenGrokLiveSamplingConfiguration] = []
    private var requests: [OpenGrokLiveSamplingRequest] = []

    var recordedConfigurations: [OpenGrokLiveSamplingConfiguration] {
        lock.lock()
        defer { lock.unlock() }
        return configurations
    }

    var recordedRequests: [OpenGrokLiveSamplingRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func makeSampler(configuration: OpenGrokLiveSamplingConfiguration) -> OpenGrokLiveSampler {
        lock.lock()
        configurations.append(configuration)
        lock.unlock()
        let fixture = self
        return OpenGrokLiveSampler { request, emit in
            fixture.record(request)
            await emit(.output("provider answer"))
            return OpenGrokLiveSamplingResponse(output: "provider answer", stopReason: "stop")
        }
    }

    private func record(_ request: OpenGrokLiveSamplingRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
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

private final class ParityStopHookSamplerFixture: @unchecked Sendable {
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
            let index = fixture.record(request)
            let answer = index == 0 ? "first answer" : "final answer"
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

private final class ParityParallelToolLoopSamplerFixture: @unchecked Sendable {
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
                let calls = [
                    ToolCall(
                        id: "call-slow",
                        name: "run_terminal_cmd",
                        arguments: #"{"command":"slow","description":"slow parity tool"}"#
                    ),
                    ToolCall(
                        id: "call-fast",
                        name: "run_terminal_cmd",
                        arguments: #"{"command":"fast","description":"fast parity tool"}"#
                    )
                ]
                return OpenGrokLiveSamplingResponse(
                    output: "",
                    stopReason: "tool_calls",
                    items: [.assistant(AssistantItem(content: "", toolCalls: calls))]
                )
            }

            let results = request.items.compactMap { item -> ToolResultItem? in
                guard case .toolResult(let result) = item else { return nil }
                return result
            }
            let answer = "parallel results: \(results.map(\.content).joined(separator: ", "))"
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
    private let toolName: String

    init(arguments: String, toolName: String = "read_file") {
        self.arguments = arguments
        self.toolName = toolName
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
                    name: fixture.toolName,
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

private actor ParityConcurrentShellCommandBackend: ShellProcessBackend {
    private(set) var requests: [ShellCommandRequest] = []
    private(set) var maximumConcurrentRuns = 0
    private var activeRuns = 0

    func run(_ request: ShellCommandRequest) async throws -> ShellCommandResult {
        requests.append(request)
        activeRuns += 1
        maximumConcurrentRuns = max(maximumConcurrentRuns, activeRuns)
        if request.command == "slow" {
            try await Task.sleep(nanoseconds: 100_000_000)
        } else {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        activeRuns -= 1
        let output = "\(request.command) output"
        return ShellCommandResult(combinedOutput: output, stdout: output, exitCode: 0)
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
                // The Kimi **Code** service's own default, not `kimi-for-coding`.
                // With no user preference, upstream falls back to the first
                // entry in catalog order within the selected partition
                // (`resolve_default_model_with_provider_auth`,
                // `xai-grok-shell/src/agent/models/resolution.rs:116-142`), and
                // upstream lists `k3` first — "Kimi Code's flagship coding and
                // agent model" (`xai-grok-models/default_models.json:56-72`) —
                // ahead of the older K2.7 `kimi-for-coding` family. This
                // expectation was `kimi-for-coding` only because the port's
                // embedded catalog predated `k3`.
                model: "k3",
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

    @Test("live composition applies agent profiles with CLI model precedence")
    func liveAgentProfileComposition() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let state = root.appendingPathComponent("state", isDirectory: true)
        let agents = state.appendingPathComponent("agents", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try "workspace instructions".write(
            to: root.appendingPathComponent("AGENTS.md"),
            atomically: true,
            encoding: .utf8
        )
        try """
        ---
        name: coding
        description: Coding profile
        model: glm-5.2
        ---
        Follow the profile prompt.
        """.write(
            to: agents.appendingPathComponent("coding.md"),
            atomically: true,
            encoding: .utf8
        )

        let fixture = ParitySamplingConfigurationFixture()
        let application = OpenGrokApplication.live(
            dependencies: OpenGrokLiveCompositionDependencies(
                makeSampler: fixture.makeSampler(configuration:)
            ),
            control: .never
        )
        let environment = [
            "HOME": root.path,
            "OPENGROK_HOME": state.path,
            "XAI_API_KEY": "xai-key",
            "FIREWORKS_API_KEY": "fireworks-key"
        ]

        let (profileStreams, _, profileError) = CLIStreams.buffered()
        let profileCode = await CLIRunner.run(
            [
                "headless", "--prompt", "profile question",
                "--cwd", root.path,
                "--profile", "coding"
            ],
            environment: environment,
            streams: profileStreams,
            application: application
        )
        let (overrideStreams, _, overrideError) = CLIStreams.buffered()
        let overrideCode = await CLIRunner.run(
            [
                "headless", "--prompt", "override question",
                "--cwd", root.path,
                "--profile", "coding",
                "--model", "grok-4.5"
            ],
            environment: environment,
            streams: overrideStreams,
            application: application
        )

        let configurations = fixture.recordedConfigurations
        let requests = fixture.recordedRequests
        let systemPrompt: String? = {
            guard case .system(let item)? = requests.first?.items.first else { return nil }
            return item.content
        }()
        #expect(profileCode == CLIRunner.ExitCode.success.rawValue)
        #expect(overrideCode == CLIRunner.ExitCode.success.rawValue)
        #expect(profileError.contents.isEmpty)
        #expect(overrideError.contents.isEmpty)
        #expect(configurations.map(\.provider) == [.fireworks, .xai])
        #expect(configurations.map(\.model) == [
            "accounts/fireworks/models/glm-5p2",
            "grok-4.5"
        ])
        #expect(systemPrompt?.contains("Follow the profile prompt.") == true)
        #expect(systemPrompt?.contains("workspace instructions") == true)
        #expect(systemPrompt?.contains("## From:") == true)
        #expect(systemPrompt?.contains("AGENTS.md") == true)
        #expect(requests.map(\.prompt) == ["profile question", "override question"])
    }

    @Test("live agent profiles filter the advertised tool surface")
    func liveAgentProfileToolPolicy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let state = root.appendingPathComponent("state", isDirectory: true)
        let agents = state.appendingPathComponent("agents", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try """
        ---
        name: reader
        description: Read-only profile
        agentsMd: false
        capabilityMode: read-only
        tools: read_file, grep
        disallowedTools: grep
        ---
        Read only.
        """.write(
            to: agents.appendingPathComponent("reader.md"),
            atomically: true,
            encoding: .utf8
        )
        try """
        ---
        name: executor
        description: Terminal-only profile
        agentsMd: false
        capabilityMode: execute
        tools: run_terminal_command
        ---
        Execute commands.
        """.write(
            to: agents.appendingPathComponent("executor.md"),
            atomically: true,
            encoding: .utf8
        )

        let sampler = ParitySamplerFixture(responses: [
            "read question": OpenGrokLiveSamplingResponse(output: "read answer"),
            "execute question": OpenGrokLiveSamplingResponse(output: "execute answer")
        ])
        let application = OpenGrokApplication.live(
            dependencies: OpenGrokLiveCompositionDependencies(
                makeSampler: { _ in sampler.makeSampler() }
            ),
            control: .never
        )
        let environment = [
            "HOME": root.path,
            "OPENGROK_HOME": state.path,
            "XAI_API_KEY": "test-key"
        ]

        let (readerStreams, _, readerError) = CLIStreams.buffered()
        let readerCode = await CLIRunner.run(
            [
                "headless", "--prompt", "read question",
                "--cwd", root.path,
                "--profile", "reader"
            ],
            environment: environment,
            streams: readerStreams,
            application: application
        )
        let (executorStreams, _, executorError) = CLIStreams.buffered()
        let executorCode = await CLIRunner.run(
            [
                "headless", "--prompt", "execute question",
                "--cwd", root.path,
                "--profile", "executor"
            ],
            environment: environment,
            streams: executorStreams,
            application: application
        )

        let requests = sampler.recordedRequests
        #expect(readerCode == CLIRunner.ExitCode.success.rawValue)
        #expect(executorCode == CLIRunner.ExitCode.success.rawValue)
        #expect(readerError.contents == "open-grok: sampling\n")
        #expect(executorError.contents == "open-grok: sampling\n")
        #expect(requests[0].tools.map(\.name) == ["read_file"])
        #expect(requests[1].tools.map(\.name) == ["run_terminal_cmd"])
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
            [
                "headless", "--prompt", "use the terminal", "--cwd", root.path,
                // Headless has no prompter, so shell needs explicit authorization.
                // This is the supported path a scripted user uses.
                "--allowedTools", "Bash",
            ],
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

    @Test("live headless composition re-enters after a Stop hook block")
    func liveStopHookContinuationComposition() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let state = root.appendingPathComponent("stop-count")
        let envelopeDirectory = root.appendingPathComponent("stop-envelopes")
        try FileManager.default.createDirectory(at: envelopeDirectory, withIntermediateDirectories: true)
        let hookScript = root.appendingPathComponent("stop-hook.sh")
        try """
        #!/bin/sh
        count=0
        if [ -f '\(state.path)' ]; then count=$(cat '\(state.path)'); fi
        count=$((count + 1))
        printf '%s' "$count" > '\(state.path)'
        cat > "\(envelopeDirectory.path)/$count.json"
        if [ "$count" -eq 1 ]; then
          printf '%s' '{"decision":"block","reason":"please verify","hookSpecificOutput":{"additionalContext":"include test evidence"}}'
        else
          printf '%s' '{"decision":"allow"}'
        fi
        """.write(to: hookScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: hookScript.path
        )
        let hooksDirectory = root.appendingPathComponent("state/hooks")
        try FileManager.default.createDirectory(at: hooksDirectory, withIntermediateDirectories: true)
        try """
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\(hookScript.path)"}]}]}}
        """.write(
            to: hooksDirectory.appendingPathComponent("stop.json"),
            atomically: true,
            encoding: .utf8
        )

        let sampler = ParityStopHookSamplerFixture()
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in sampler.makeSampler() }
        )
        let application = OpenGrokApplication.live(dependencies: dependencies, control: .never)
        let (streams, out, _) = CLIStreams.buffered()
        let code = await CLIRunner.run(
            ["headless", "--prompt", "stop-hook prompt", "--cwd", root.path],
            environment: [
                "HOME": root.path,
                "OPENGROK_HOME": root.appendingPathComponent("state").path,
                "XAI_API_KEY": "test-key"
            ],
            streams: streams,
            application: application
        )

        let requests = sampler.recordedRequests
        let envelopes = (1...2).compactMap { index -> [String: Any]? in
            let data = try? Data(contentsOf: envelopeDirectory.appendingPathComponent("\(index).json"))
            return data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        #expect(code == CLIRunner.ExitCode.success.rawValue)
        #expect(out.contents.contains("final answer"))
        #expect(requests.count == 2)
        #expect(envelopes.count == 2)
        guard requests.count == 2, envelopes.count == 2 else { return }
        #expect(envelopes[0]["hookEventName"] as? String == "stop")
        #expect(envelopes[0]["reason"] as? String == "end_turn")
        #expect(envelopes[0]["stopHookActive"] as? Bool == false)
        #expect(envelopes[0]["promptId"] as? String != nil)
        #expect(envelopes[0]["lastAssistantMessage"] as? String == "first answer")
        #expect(envelopes[1]["stopHookActive"] as? Bool == true)
        #expect(requests[1].items.contains { item in
            let text = item.textContent()
            return text.contains("please verify") && text.contains("include test evidence")
        })
    }

    @Test("live headless Stop force-stop ends without a continuation request")
    func liveStopHookForceStopComposition() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let hooksDirectory = root.appendingPathComponent("state/hooks")
        try FileManager.default.createDirectory(at: hooksDirectory, withIntermediateDirectories: true)
        let hookScript = root.appendingPathComponent("force-stop-hook.sh")
        try """
        #!/bin/sh
        printf '%s' '{"decision":"block","reason":"do not continue","continue":false,"stopReason":"forced stop"}'
        """.write(to: hookScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: hookScript.path
        )
        try """
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\(hookScript.path)"}]}]}}
        """.write(
            to: hooksDirectory.appendingPathComponent("stop.json"),
            atomically: true,
            encoding: .utf8
        )

        let sampler = ParityStopHookSamplerFixture()
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in sampler.makeSampler() }
        )
        let application = OpenGrokApplication.live(dependencies: dependencies, control: .never)
        let (streams, out, _) = CLIStreams.buffered()
        let code = await CLIRunner.run(
            ["headless", "--prompt", "force-stop prompt", "--cwd", root.path],
            environment: [
                "HOME": root.path,
                "OPENGROK_HOME": root.appendingPathComponent("state").path,
                "XAI_API_KEY": "test-key"
            ],
            streams: streams,
            application: application
        )

        #expect(code == CLIRunner.ExitCode.success.rawValue)
        #expect(out.contents.contains("first answer"))
        #expect(sampler.recordedRequests.count == 1)
    }

    @Test("live tool rounds execute concurrently and preserve result order")
    func liveParallelToolLoopComposition() async {
        let backend = ParityConcurrentShellCommandBackend()
        let sampler = ParityParallelToolLoopSamplerFixture()
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
            [
                "headless", "--prompt", "run both", "--cwd", root.path,
                "--allowedTools", "Bash",
            ],
            environment: [
                "HOME": root.path,
                "OPENGROK_HOME": root.appendingPathComponent("state").path,
                "XAI_API_KEY": "test-key"
            ],
            streams: streams,
            application: application
        )

        let samplerRequests = sampler.recordedRequests
        let resultItems = samplerRequests.last?.items.compactMap { item -> ToolResultItem? in
            guard case .toolResult(let result) = item else { return nil }
            return result
        } ?? []
        #expect(code == CLIRunner.ExitCode.success.rawValue)
        #expect(err.contents.contains("running tool run_terminal_cmd"))
        #expect(out.contents.contains("parallel results: slow output\nExit code: 0, fast output\nExit code: 0"))
        #expect(await backend.maximumConcurrentRuns == 2)
        #expect(Set(await backend.requests.map(\.command)) == Set(["slow", "fast"]))
        #expect(resultItems.map(\.toolCallId) == ["call-slow", "call-fast"])
        #expect(resultItems.map(\.content) == [
            "slow output\nExit code: 0",
            "fast output\nExit code: 0"
        ])
    }

    @Test("live streaming JSON reports structured tool lifecycle events")
    func liveStreamingJSONToolLifecycleComposition() async {
        for outputFormat in ["streaming-json", "streaming-messages-json"] {
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
            let (streams, out, _) = CLIStreams.buffered()

            let code = await CLIRunner.run(
                [
                    "headless", "--prompt", "use the terminal",
                    "--cwd", root.path,
                    "--output-format", outputFormat,
                    "--allowedTools", "Bash"
                ],
                environment: [
                    "HOME": root.path,
                    "OPENGROK_HOME": root.appendingPathComponent("state").path,
                    "XAI_API_KEY": "test-key"
                ],
                streams: streams,
                application: application
            )

            let records = out.contents.split(separator: "\n").compactMap { line in
                try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            }
            let toolRecords = records.filter { $0["type"] as? String == "tool" }

            #expect(code == CLIRunner.ExitCode.success.rawValue)
            #expect(toolRecords.count == 2)
            #expect(toolRecords[0]["call_id"] as? String == "call-1")
            #expect(toolRecords[0]["name"] as? String == "run_terminal_cmd")
            #expect(toolRecords[0]["input"] as? String == #"{"command":"printf tool-output","description":"parity tool"}"#)
            #expect(toolRecords[0]["state"] as? String == "running")
            #expect(toolRecords[0]["output"] is NSNull)
            #expect(toolRecords[1]["call_id"] as? String == "call-1")
            #expect(toolRecords[1]["state"] as? String == "succeeded")
            #expect((toolRecords[1]["output"] as? String)?.contains("tool output") == true)
            #expect(records.contains { $0["type"] as? String == "completed" })
            if outputFormat == "streaming-messages-json" {
                #expect(records.contains { $0["type"] as? String == "status" } == false)
            }
        }
    }

    @Test("live interactive composition renders structured tool cards")
    func liveInteractiveToolCardComposition() async {
        let backend = ParityShellCommandBackend()
        let sampler = ParityToolLoopSamplerFixture()
        let terminal = ParityTerminalFixture(
            tty: true,
            size: OpenGrokLiveTerminalSize(width: 80, height: 20)
        )
        let input = AsyncThrowingStream<InputEvent, Error> { continuation in
            Task {
                for event in Self.typed("use a tool") + [.key(KeyEvent(key: .enter))] {
                    continuation.yield(event)
                }
                await Self.waitForTerminalOutput("final answer after tool output", terminal: terminal)
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
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in sampler.makeSampler() },
            makeProcessBackend: { backend },
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
            [
                "interactive", "--cwd", root.path,
                // No presenter attaches in this fixture, so the sheet cannot be
                // answered; the flag is how a caller authorizes shell instead.
                "--allowedTools", "Bash",
            ],
            environment: [
                "HOME": root.path,
                "OPENGROK_HOME": root.appendingPathComponent("state").path,
                "XAI_API_KEY": "test-key"
            ],
            streams: streams,
            application: application
        )

        let output = terminal.output
        let toolRange = output.range(of: "Tool run_terminal_cmd [done]")
        let answerRange = output.range(of: "Grok: final answer after tool output")
        #expect(code == CLIRunner.ExitCode.success.rawValue)
        #expect(out.contents.isEmpty)
        #expect(err.contents.isEmpty)
        #expect(output.contains(#"input: {"command":"printf tool-output","description":"parity tool"}"#))
        #expect(output.contains("result: tool output"))
        #expect(toolRange != nil)
        #expect(answerRange != nil)
        if let toolRange, let answerRange {
            #expect(toolRange.lowerBound < answerRange.lowerBound)
        }
    }

    @Test("live headless composition advertises the full live tool surface and executes a file tool")
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
        // A session with no agent profile lists the full read-write build pack.
        // The mutating tools are only *offered* here; the permission gate still
        // decides at dispatch, which `liveFileToolsDenyMutationsByDefault` pins.
        //
        // `image_gen` / `image_edit` join the list because this session carries
        // an `XAI_API_KEY`, which is exactly the advertisement rule upstream
        // uses (`xai-grok-agent/src/builder.rs:771`): the image tools appear
        // when the session's resolved credentials can actually reach an image
        // endpoint. `ImageToolCompositionTests` pins both directions.
        //
        // `get_command_or_subagent_output` / `wait_commands_or_subagents` /
        // `kill_command_or_subagent` ride along with `run_terminal_cmd`: it can
        // background a command — on request, or on its own once the foreground
        // budget runs out — and these are the only way to read, wait on, or stop
        // the task it hands back.
        //
        // `web_search` / `web_fetch` / `x_search` follow the image-tool rule:
        // this session's `XAI_API_KEY` resolves an xAI search backend, so all
        // three are offered. `LiveWebToolsTests` pins the credential cases.
        // `todo_write` needs no credentials at all and is unconditional.
        let advertised = Set(requests.first?.tools.map(\.name) ?? [])
        #expect(advertised == Set([
            "run_terminal_cmd", "read_file", "list_dir", "grep",
            "glob", "view_image", "search_replace", "write", "apply_patch",
            "image_gen", "image_edit",
            "get_command_or_subagent_output", "wait_commands_or_subagents", "kill_command_or_subagent",
            "web_search", "web_fetch", "x_search",
            "todo_write"
        ]))
        // The `.build` file-tool pack proper is exactly these eight; the rest
        // of the surface enters at the composition site (terminal tool
        // unconditionally, image tools by credential advertisement).
        #expect(advertised.isSuperset(of: [
            "read_file", "list_dir", "grep", "glob",
            "view_image", "search_replace", "write", "apply_patch"
        ]))
        #expect(toolResult?.toolCallId == "file-call-1")
        #expect(toolResult?.content.contains("file tool contents") == true)
    }

    /// The dispatch gate, as distinct from the listing gate above: `write` is
    /// offered to the model but refused at call time unless the session opts in.
    private func runWriteToolSession(
        allowWrites: Bool
    ) async -> (code: Int32, toolResult: String?, wroteFile: Bool) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("written.txt")

        let sampler = ParityFileToolSamplerFixture(
            arguments: #"{"file_path":"written.txt","content":"written by the model\n"}"#,
            toolName: "write"
        )
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in sampler.makeSampler() }
        )
        let application = OpenGrokApplication.live(dependencies: dependencies, control: .never)
        let (streams, _, _) = CLIStreams.buffered()
        var environment = [
            "HOME": root.path,
            "OPENGROK_HOME": root.appendingPathComponent("state").path,
            "XAI_API_KEY": "test-key"
        ]
        if allowWrites {
            environment["OPENGROK_ALLOW_WRITES"] = "1"
        }
        let code = await CLIRunner.run(
            ["headless", "--prompt", "write the file", "--cwd", root.path],
            environment: environment,
            streams: streams,
            application: application
        )
        let toolResult = sampler.recordedRequests.last?.items.compactMap { item -> ToolResultItem? in
            guard case .toolResult(let result) = item else { return nil }
            return result
        }.last?.content
        return (code, toolResult, FileManager.default.fileExists(atPath: target.path))
    }

    @Test("live file tools deny mutations by default and say how to enable them")
    func liveFileToolsDenyMutationsByDefault() async {
        let outcome = await runWriteToolSession(allowWrites: false)
        #expect(outcome.wroteFile == false)
        #expect(outcome.toolResult?.contains("OPENGROK_ALLOW_WRITES") == true)
    }

    @Test("OPENGROK_ALLOW_WRITES lets the write tool through the permission gate")
    func liveFileToolsAllowWritesOptIn() async {
        let outcome = await runWriteToolSession(allowWrites: true)
        #expect(outcome.wroteFile == true)
        #expect(outcome.toolResult?.contains("OPENGROK_ALLOW_WRITES") != true)
    }

    /// Drives a real interactive session whose turn calls the write tool, and
    /// answers the permission sheet with a scripted key once it is painted.
    private func runInteractivePermissionSession(
        answer: [InputEvent]
    ) async -> (code: Int32, painted: String, toolResult: String?, wroteFile: Bool) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("written.txt")

        let sampler = ParityFileToolSamplerFixture(
            arguments: #"{"file_path":"written.txt","content":"written by the model\n"}"#,
            toolName: "write"
        )
        let terminal = ParityTerminalFixture(
            tty: true,
            size: OpenGrokLiveTerminalSize(width: 80, height: 24)
        )
        let input = AsyncThrowingStream<InputEvent, Error> { continuation in
            Task {
                for event in Self.typed("write the file") + [.key(KeyEvent(key: .enter))] {
                    continuation.yield(event)
                }
                await Self.waitForPaintedText("Allow write", terminal: terminal)
                for event in answer {
                    continuation.yield(event)
                }
                await Self.waitForTerminalOutput("file tool result", terminal: terminal)
                continuation.yield(.key(KeyEvent(
                    key: .char("d"),
                    modifiers: .control,
                    character: "d"
                )))
                continuation.finish()
            }
        }
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
        let (streams, _, _) = CLIStreams.buffered()
        let code = await CLIRunner.run(
            ["interactive", "--cwd", root.path],
            environment: [
                "HOME": root.path,
                "OPENGROK_HOME": root.appendingPathComponent("state").path,
                "XAI_API_KEY": "test-key"
            ],
            streams: streams,
            application: application
        )
        let toolResult = sampler.recordedRequests.last?.items.compactMap { item -> ToolResultItem? in
            guard case .toolResult(let result) = item else { return nil }
            return result
        }.last?.content
        return (
            code,
            terminal.paintedText,
            toolResult,
            FileManager.default.fileExists(atPath: target.path)
        )
    }

    @Test("the interactive permission sheet allows a write when the user picks Yes")
    func liveInteractivePermissionAllowsWrite() async {
        // Option 2 is "Yes" — a one-shot allow.
        let outcome = await runInteractivePermissionSession(
            answer: [.key(KeyEvent(key: .char("2"), character: "2"))]
        )
        #expect(outcome.code == CLIRunner.ExitCode.success.rawValue)
        #expect(outcome.painted.contains("Allow write"))
        #expect(outcome.wroteFile == true)
        // The sheet replaces the env gate in interactive mode, so the denial
        // message that names the variable must not appear.
        #expect(outcome.toolResult?.contains("OPENGROK_ALLOW_WRITES") != true)
    }

    @Test("the interactive permission sheet denies a write when the user picks No")
    func liveInteractivePermissionDeniesWrite() async {
        // Option 3 is "No, and tell Grok what to do differently".
        let outcome = await runInteractivePermissionSession(
            answer: [.key(KeyEvent(key: .char("3"), character: "3"))]
        )
        #expect(outcome.code == CLIRunner.ExitCode.success.rawValue)
        #expect(outcome.wroteFile == false)
        #expect(outcome.toolResult?.contains("denied") == true)
    }

    @Test("arrowing down to Yes and pressing Enter answers the permission sheet")
    func liveInteractivePermissionKeyboardNavigation() async {
        // The sheet opens on option 1 ("allow all edits this session"); one
        // Down lands on "Yes", and Enter confirms the highlighted row.
        let outcome = await runInteractivePermissionSession(
            answer: [
                .key(KeyEvent(key: .down)),
                .key(KeyEvent(key: .enter))
            ]
        )
        #expect(outcome.wroteFile == true)
    }

    @Test("OPENGROK_ALLOW_WRITES still bypasses the sheet in interactive mode")
    func liveInteractivePermissionEnvBypass() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("written.txt")

        let sampler = ParityFileToolSamplerFixture(
            arguments: #"{"file_path":"written.txt","content":"written by the model\n"}"#,
            toolName: "write"
        )
        let terminal = ParityTerminalFixture(
            tty: true,
            size: OpenGrokLiveTerminalSize(width: 80, height: 24)
        )
        let input = AsyncThrowingStream<InputEvent, Error> { continuation in
            Task {
                for event in Self.typed("write the file") + [.key(KeyEvent(key: .enter))] {
                    continuation.yield(event)
                }
                await Self.waitForTerminalOutput("file tool result", terminal: terminal)
                continuation.yield(.key(KeyEvent(
                    key: .char("d"),
                    modifiers: .control,
                    character: "d"
                )))
                continuation.finish()
            }
        }
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in sampler.makeSampler() },
            terminal: terminal.terminal,
            makeInteractiveInput: {
                OpenGrokLiveInteractiveInput(events: input, close: {})
            },
            makeTerminalSink: { ParityTerminalSink(terminal: terminal) }
        )
        let application = OpenGrokApplication.live(dependencies: dependencies, control: .never)
        let (streams, _, _) = CLIStreams.buffered()
        let code = await CLIRunner.run(
            ["interactive", "--cwd", root.path],
            environment: [
                "HOME": root.path,
                "OPENGROK_HOME": root.appendingPathComponent("state").path,
                "XAI_API_KEY": "test-key",
                "OPENGROK_ALLOW_WRITES": "1"
            ],
            streams: streams,
            application: application
        )
        #expect(code == CLIRunner.ExitCode.success.rawValue)
        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect(terminal.paintedText.contains("Allow write") == false)
    }

    /// Runs an interactive session with a scripted key sequence and no turn,
    /// returning everything written to the terminal.
    private func runInteractiveOverlaySession(
        configuration: String? = nil,
        environmentOverrides: [String: String] = [:],
        script: @escaping @Sendable (
            ParityTerminalFixture,
            AsyncThrowingStream<InputEvent, Error>.Continuation
        ) async -> Void
    ) async -> (code: Int32, output: String, painted: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let state = root.appendingPathComponent("state")
        try? FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        if let configuration {
            try? configuration.write(
                to: state.appendingPathComponent("config.toml"),
                atomically: true,
                encoding: .utf8
            )
        }
        let sampler = ParitySamplerFixture(responses: [:])
        let terminal = ParityTerminalFixture(
            tty: true,
            size: OpenGrokLiveTerminalSize(width: 100, height: 30)
        )
        let input = AsyncThrowingStream<InputEvent, Error> { continuation in
            Task {
                await script(terminal, continuation)
                continuation.yield(.key(KeyEvent(
                    key: .char("d"),
                    modifiers: .control,
                    character: "d"
                )))
                continuation.finish()
            }
        }
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in sampler.makeSampler() },
            terminal: terminal.terminal,
            makeInteractiveInput: {
                OpenGrokLiveInteractiveInput(events: input, close: {})
            },
            makeTerminalSink: { ParityTerminalSink(terminal: terminal) }
        )
        let application = OpenGrokApplication.live(dependencies: dependencies, control: .never)
        let (streams, _, _) = CLIStreams.buffered()
        var environment = [
            "HOME": root.path,
            "OPENGROK_HOME": state.path,
            "XAI_API_KEY": "test-key"
        ]
        environment.merge(environmentOverrides) { _, override in override }
        let code = await CLIRunner.run(
            ["interactive", "--cwd", root.path],
            environment: environment,
            streams: streams,
            application: application
        )
        return (code, terminal.output, terminal.paintedText)
    }

    @Test("a fresh session opens on the welcome screen with the composer still live")
    func liveInteractiveWelcomeScreen() async {
        let outcome = await runInteractiveOverlaySession { terminal, continuation in
            await Self.waitForPaintedText("Open Grok", terminal: terminal)
            // The welcome overlay does not capture input, so a prompt typed
            // underneath it still submits — which is also what pops it.
            for event in Self.typed("hello") { continuation.yield(event) }
            continuation.yield(.key(KeyEvent(key: .enter)))
            await Self.waitForTerminalOutput("missing response", terminal: terminal)
        }
        #expect(outcome.code == CLIRunner.ExitCode.success.rawValue)
        #expect(outcome.painted.contains("Open Grok"))
        #expect(outcome.output.contains("You: hello"))
    }

    @Test("/help opens the shortcuts modal and Esc closes it")
    func liveInteractiveHelpOverlay() async {
        let outcome = await runInteractiveOverlaySession { terminal, continuation in
            continuation.yield(.paste("/help"))
            continuation.yield(.key(KeyEvent(key: .enter)))
            await Self.waitForPaintedText("Keyboard Shortcuts", terminal: terminal)
            continuation.yield(.key(KeyEvent(key: .escape)))
        }
        #expect(outcome.painted.contains("Keyboard Shortcuts"))
        // Asserts a row near the top of the list rather than a specific command
        // deep in it: the registry keeps growing, and the modal scrolls, so
        // pinning a late entry makes this test fail whenever a command is added
        // ahead of it — which says nothing about whether /help opened.
        #expect(outcome.painted.contains("/help"))
    }

    @Test("/model switches the live session and refuses what it cannot authenticate")
    func liveInteractiveModelPicker() async {
        let outcome = await runInteractiveOverlaySession { terminal, continuation in
            continuation.yield(.paste("/model"))
            continuation.yield(.key(KeyEvent(key: .enter)))
            await Self.waitForPaintedText("Select model", terminal: terminal)
            // The picker opens on the active model, so a bare Enter is a no-op
            // rather than a pointless rebuild.
            continuation.yield(.key(KeyEvent(key: .enter)))
            await Self.waitForPaintedText("Already using", terminal: terminal)

            continuation.yield(.paste("/model"))
            continuation.yield(.key(KeyEvent(key: .enter)))
            // Only `XAI_API_KEY` is set, so any Codex row is a provider this
            // session cannot authenticate. Filter to the Codex partition by its
            // `provider:slug` selector rather than counting arrow presses: rows
            // sort by provider then name, so a positional assertion would break
            // every time a provider is added or the ordering is tweaked, and it
            // would fail looking like broken picker navigation. Typing into the
            // filter resets the selection to the first visible row, so whichever
            // Codex model leads the partition is the one selected.
            for event in Self.typed("codex:") { continuation.yield(event) }
            continuation.yield(.key(KeyEvent(key: .enter)))
            await Self.waitForPaintedText("Could not switch to", terminal: terminal)
        }
        #expect(outcome.painted.contains("Select model"))
        #expect(outcome.output.contains("Already using"))
        // A refused switch says why and names the model it stayed on.
        #expect(outcome.output.contains("Could not switch to"))
        #expect(outcome.output.contains("Staying on"))
    }

    /// A typed selector that names exactly one model switches without ever
    /// showing the picker; an unresolvable one is refused rather than falling
    /// back to the overlay, so a typo never silently becomes "pick something
    /// else". Mirrors upstream's `Unknown model: …` result.
    @Test("/model <selector> switches directly and refuses an unknown name")
    func liveInteractiveTypedModelSelector() async {
        let outcome = await runInteractiveOverlaySession { terminal, continuation in
            await Self.waitForPaintedText("Build anything", terminal: terminal)

            continuation.yield(.paste("/model codex:gpt-5.6-sol"))
            continuation.yield(.key(KeyEvent(key: .enter)))
            // Codex cannot authenticate here, so the switch is refused — but it
            // was attempted, which is what proves the selector resolved.
            await Self.waitForPaintedText("Could not switch to", terminal: terminal)

            continuation.yield(.paste("/model definitely-not-a-model"))
            continuation.yield(.key(KeyEvent(key: .enter)))
            await Self.waitForPaintedText("Unknown model", terminal: terminal)
        }
        #expect(outcome.output.contains("Could not switch to"))
        #expect(outcome.output.contains("Unknown model"))
        // The typed path resolves in place; the picker never opens.
        #expect(!outcome.painted.contains("Select model"))
    }

    /// A bare display name shared by two configured rows must be refused rather
    /// than resolving to whichever entry happens to sort first.
    @Test("/model refuses an ambiguous bare name")
    func liveInteractiveAmbiguousModelSelector() async {
        let outcome = await runInteractiveOverlaySession(configuration: """
        [model.ambiguous_one]
        model = "ambiguous-one"
        name = "Ambiguous Fixture Model"
        provider = "xai"
        base_url = "https://api.x.ai/v1"
        api_backend = "chat_completions"

        [model.ambiguous_two]
        model = "ambiguous-two"
        name = "Ambiguous Fixture Model"
        provider = "xai"
        base_url = "https://api.x.ai/v1"
        api_backend = "chat_completions"
        """) { terminal, continuation in
            await Self.waitForPaintedText("Build anything", terminal: terminal)
            continuation.yield(.paste("/model Ambiguous Fixture Model"))
            continuation.yield(.key(KeyEvent(key: .enter)))
            await Self.waitForPaintedText("Unknown model", terminal: terminal)
        }
        #expect(outcome.output.contains("Unknown model: Ambiguous Fixture Model"))
        #expect(!outcome.painted.contains("Select model"))
    }

    @Test("mouse reporting is bracketed with the alternate screen and toggleable")
    func liveInteractiveMouseReporting() async {
        let outcome = await runInteractiveOverlaySession { terminal, continuation in
            // A wheel report over the transcript scrolls it rather than
            // reaching the composer.
            continuation.yield(.mouse(MouseEvent(kind: .scrollUp, x: 10, y: 5)))
            continuation.yield(.paste("/toggle-mouse-reporting"))
            continuation.yield(.key(KeyEvent(key: .enter)))
            await Self.waitForPaintedText("Mouse reporting off", terminal: terminal)
        }
        let output = outcome.output
        let enable = output.range(of: "\u{1B}[?1006h")
        let alternateEnter = output.range(of: "\u{1B}[?1049h")
        let disable = output.range(of: "\u{1B}[?1006l")
        let alternateExit = output.range(of: "\u{1B}[?1049l")
        #expect(enable != nil)
        #expect(disable != nil)
        // Enable lands inside the alternate screen; the final disable lands
        // before leaving it, so reporting can never outlive the session.
        if let enable, let alternateEnter {
            #expect(alternateEnter.lowerBound < enable.lowerBound)
        }
        if let alternateExit, let disable = output.range(
            of: "\u{1B}[?1006l",
            options: .backwards
        ) {
            #expect(disable.lowerBound < alternateExit.lowerBound)
        }
        _ = disable
        #expect(output.contains("Mouse reporting off"))
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

    @Test("live sessions resume canonical history across launches")
    func liveSessionResumeComposition() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspace = root.appendingPathComponent("workspace")
        let state = root.appendingPathComponent("state")
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let sampler = ParitySamplerFixture(responses: [
            "first persisted question": OpenGrokLiveSamplingResponse(output: "first persisted answer"),
            "second persisted question": OpenGrokLiveSamplingResponse(output: "second persisted answer")
        ])
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in sampler.makeSampler() }
        )
        let application = OpenGrokApplication.live(dependencies: dependencies, control: .never)
        let environment = [
            "HOME": root.path,
            "OPENGROK_HOME": state.path,
            "XAI_API_KEY": "test-key"
        ]

        let (firstStreams, _, _) = CLIStreams.buffered()
        let firstCode = await CLIRunner.run(
            [
                "headless", "--prompt", "first persisted question",
                "--cwd", workspace.path,
                "--session-id", "persisted-session"
            ],
            environment: environment,
            streams: firstStreams,
            application: application
        )
        let (secondStreams, _, _) = CLIStreams.buffered()
        let secondCode = await CLIRunner.run(
            [
                "headless", "--prompt", "second persisted question",
                "--cwd", workspace.path,
                "--resume", "persisted-session"
            ],
            environment: environment,
            streams: secondStreams,
            application: application
        )

        let requests = sampler.recordedRequests
        #expect(firstCode == CLIRunner.ExitCode.success.rawValue)
        #expect(secondCode == CLIRunner.ExitCode.success.rawValue)
        #expect(requests.map(\.sessionID) == ["persisted-session", "persisted-session"])
        #expect(requests.last?.items == [
            .user("first persisted question"),
            .assistant(AssistantItem(content: "first persisted answer")),
            .user("second persisted question")
        ])
        #expect(FileManager.default.fileExists(
            atPath: state.appendingPathComponent("sessions/persisted-session.json").path
        ))
    }

    @Test("live resume restores the stored non-xAI provider instead of ambient xAI")
    func liveSessionResumeRestoresStoredProvider() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspace = root.appendingPathComponent("workspace")
        let state = root.appendingPathComponent("state")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let fixture = ParitySamplingConfigurationFixture()
        let application = OpenGrokApplication.live(
            dependencies: OpenGrokLiveCompositionDependencies(
                makeSampler: fixture.makeSampler(configuration:)
            ),
            control: .never
        )
        let environment = [
            "HOME": root.path,
            "OPENGROK_HOME": state.path,
            "XAI_API_KEY": "ambient-xai-key",
            "OPENAI_API_KEY": "codex-key"
        ]

        let (firstStreams, _, _) = CLIStreams.buffered()
        let firstCode = await CLIRunner.run(
            [
                "headless", "--prompt", "codex question",
                "--provider", "codex",
                "--cwd", workspace.path,
                "--session-id", "stored-codex"
            ],
            environment: environment,
            streams: firstStreams,
            application: application
        )
        let storedBeforeResume = try await LiveConversationStore(openGrokHome: state)
            .load(sessionID: "stored-codex")
        let (resumeStreams, resumeOut, resumeErr) = CLIStreams.buffered()
        let resumeCode = await CLIRunner.run(
            [
                "headless", "--prompt", "resumed question",
                "--resume", "stored-codex",
                "--cwd", workspace.path
            ],
            environment: environment,
            streams: resumeStreams,
            application: application
        )

        let configurations = fixture.recordedConfigurations
        #expect(firstCode == CLIRunner.ExitCode.success.rawValue)
        #expect(storedBeforeResume.currentModelID == "gpt-5.6-sol")
        #expect(storedBeforeResume.currentProvider == .codex)
        #expect(resumeCode == CLIRunner.ExitCode.success.rawValue)
        #expect(resumeErr.contents.isEmpty)
        #expect(resumeOut.contents == "provider answer\n")
        #expect(configurations.count == 2)
        #expect(configurations.allSatisfy { $0.provider == .codex })
        #expect(configurations.allSatisfy { $0.provider != .xai })
        #expect(try await LiveConversationStore(openGrokHome: state).load(sessionID: "stored-codex").currentProvider == .codex)
        #expect(try await LiveConversationStore(openGrokHome: state).load(sessionID: "stored-codex").everUsedNonXAI == true)
    }

    @Test("explicit xAI resume neutralizes opaque history before sampling and persistence")
    func liveResumeNeutralizesOpaqueHistoryForXAI() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspace = root.appendingPathComponent("workspace")
        let state = root.appendingPathComponent("state")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let toolCall = ToolCall(id: "call-1", name: "read", arguments: "{}")
        let opaqueItems: [ConversationItem] = [
            .system("system spine"),
            .user("old question"),
            .reasoning(ReasoningItem(id: "reasoning-1")),
            .backendToolCall(BackendToolCallItem(kind: .webSearch(
                WebSearchToolCall(id: "backend-1", action: .search(query: "secret"))
            ))),
            .assistant(AssistantItem(content: "visible answer", toolCalls: [toolCall])),
            .toolResult(ToolResultItem(toolCallId: "call-1", content: "opaque result"))
        ]
        var record = LiveConversationRecord.new(sessionID: "opaque-resume", workingDirectory: workspace)
        record.items = opaqueItems
        record.currentModelID = "gpt-5.6-sol"
        record.currentProvider = .codex
        record.everUsedNonXAI = true
        try await LiveConversationStore(openGrokHome: state).save(record)

        let sampler = ParitySamplerFixture(responses: [
            "xAI question": OpenGrokLiveSamplingResponse(output: "xAI answer")
        ])
        let application = OpenGrokApplication.live(
            dependencies: OpenGrokLiveCompositionDependencies(
                makeSampler: { _ in sampler.makeSampler() }
            ),
            control: .never
        )
        let (streams, _, _) = CLIStreams.buffered()
        let code = await CLIRunner.run(
            [
                "headless", "--prompt", "xAI question",
                "--model", "grok-4.5",
                "--resume", "opaque-resume",
                "--cwd", workspace.path
            ],
            environment: [
                "HOME": root.path,
                "OPENGROK_HOME": state.path,
                "XAI_API_KEY": "xai-key"
            ],
            streams: streams,
            application: application
        )

        let request = try #require(sampler.recordedRequests.first)
        let saved = try await LiveConversationStore(openGrokHome: state).load(sessionID: "opaque-resume")
        #expect(code == CLIRunner.ExitCode.success.rawValue)
        #expect(request.items == [
            .system("system spine"),
            .user("old question"),
            .assistant(AssistantItem(content: "visible answer")),
            .user("xAI question")
        ])
        #expect(saved.items == [
            .system("system spine"),
            .user("old question"),
            .assistant(AssistantItem(content: "visible answer")),
            .user("xAI question")
        ] + [.assistant(AssistantItem(content: "xAI answer"))])
        #expect(saved.currentProvider == .xai)
        #expect(saved.everUsedNonXAI == true)
    }

    @Test("legacy resume strips opaque carriers without inventing a clean export marker")
    func legacyResumePreservesUnknownExportMarker() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspace = root.appendingPathComponent("workspace")
        let state = root.appendingPathComponent("state")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        var record = LiveConversationRecord.new(sessionID: "legacy-resume", workingDirectory: workspace)
        record.items = [
            .user("legacy question"),
            .reasoning(ReasoningItem(id: "legacy-reasoning")),
            .backendToolCall(BackendToolCallItem(kind: .webSearch(
                WebSearchToolCall(id: "legacy-backend", action: .search(query: "legacy secret"))
            ))),
            .assistant(AssistantItem(content: "legacy answer", toolCalls: [
                ToolCall(id: "legacy-call", name: "read", arguments: "{}")
            ])),
            .toolResult(ToolResultItem(toolCallId: "legacy-call", content: "legacy result"))
        ]
        record.currentModelID = nil
        record.currentProvider = nil
        record.everUsedNonXAI = nil
        try await LiveConversationStore(openGrokHome: state).save(record)

        let sampler = ParitySamplerFixture(responses: [
            "legacy question": OpenGrokLiveSamplingResponse(output: "legacy response")
        ])
        let application = OpenGrokApplication.live(
            dependencies: OpenGrokLiveCompositionDependencies(makeSampler: { _ in sampler.makeSampler() }),
            control: .never
        )
        let (streams, _, _) = CLIStreams.buffered()
        let code = await CLIRunner.run(
            [
                "headless", "--prompt", "legacy question",
                "--resume", "legacy-resume",
                "--cwd", workspace.path
            ],
            environment: [
                "HOME": root.path,
                "OPENGROK_HOME": state.path,
                "XAI_API_KEY": "xai-key"
            ],
            streams: streams,
            application: application
        )

        let request = try #require(sampler.recordedRequests.first)
        let saved = try await LiveConversationStore(openGrokHome: state).load(sessionID: "legacy-resume")
        #expect(code == CLIRunner.ExitCode.success.rawValue)
        #expect(request.items.contains(where: { if case .reasoning = $0 { return true }; return false }) == false)
        #expect(request.items.contains(where: { if case .toolResult = $0 { return true }; return false }) == false)
        #expect(request.items.contains(where: { if case .backendToolCall = $0 { return true }; return false }) == false)
        #expect(request.items.contains(where: {
            if case .assistant(let assistant) = $0 { return !assistant.toolCalls.isEmpty }
            return false
        }) == false)
        #expect(saved.items.contains(where: { if case .reasoning = $0 { return true }; return false }) == false)
        #expect(saved.items.contains(where: { if case .backendToolCall = $0 { return true }; return false }) == false)
        #expect(saved.items.contains(where: { if case .toolResult = $0 { return true }; return false }) == false)
        #expect(saved.everUsedNonXAI == nil)
    }

    @Test("an explicitly xAI-targeted fork sanitizes only the child")
    func explicitXAIConversationForkIsSourceSafe() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspace = root.appendingPathComponent("workspace")
        let state = root.appendingPathComponent("state")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let call = ToolCall(id: "fork-call", name: "read", arguments: "{}")
        let sourceItems: [ConversationItem] = [
            .user("source question"),
            .reasoning(ReasoningItem(id: "source-reasoning")),
            .assistant(AssistantItem(content: "source answer", toolCalls: [call])),
            .toolResult(ToolResultItem(toolCallId: "fork-call", content: "source result"))
        ]
        var source = LiveConversationRecord.new(sessionID: "fork-source", workingDirectory: workspace)
        source.items = sourceItems
        source.currentModelID = "gpt-5.6-sol"
        source.currentProvider = .codex
        source.everUsedNonXAI = true
        let store = LiveConversationStore(openGrokHome: state)
        try await store.save(source)

        let sampler = ParitySamplerFixture(responses: [
            "fork question": OpenGrokLiveSamplingResponse(output: "fork answer")
        ])
        let application = OpenGrokApplication.live(
            dependencies: OpenGrokLiveCompositionDependencies(makeSampler: { _ in sampler.makeSampler() }),
            control: .never
        )
        let (streams, _, _) = CLIStreams.buffered()
        let code = await CLIRunner.run(
            [
                "headless", "--prompt", "fork question",
                "--model", "grok-4.5",
                "--resume", "fork-source",
                "--fork-session", "--session-id", "fork-child",
                "--cwd", workspace.path
            ],
            environment: [
                "HOME": root.path,
                "OPENGROK_HOME": state.path,
                "XAI_API_KEY": "xai-key"
            ],
            streams: streams,
            application: application
        )

        let request = try #require(sampler.recordedRequests.first)
        let savedSource = try await store.load(sessionID: "fork-source")
        let savedChild = try await store.load(sessionID: "fork-child")
        #expect(code == CLIRunner.ExitCode.success.rawValue)
        #expect(request.sessionID == "fork-child")
        #expect(request.items == [
            .user("source question"),
            .assistant(AssistantItem(content: "source answer")),
            .user("fork question")
        ])
        #expect(savedSource.items == sourceItems)
        #expect(savedSource.currentProvider == .codex)
        #expect(savedChild.currentProvider == .xai)
        #expect(savedChild.everUsedNonXAI == true)
    }

    @Test("live session persistence pins sandbox mode on resume")
    func liveSessionSandboxResumeDowngradeIsRefused() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspace = root.appendingPathComponent("workspace")
        let state = root.appendingPathComponent("state")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let sampler = ParitySamplerFixture(responses: [
            "create pinned session": OpenGrokLiveSamplingResponse(output: "created")
        ])
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in sampler.makeSampler() }
        )
        let application = OpenGrokApplication.live(dependencies: dependencies, control: .never)
        let environment = [
            "HOME": root.path,
            "OPENGROK_HOME": state.path,
            "XAI_API_KEY": "test-key"
        ]

        let (createStreams, _, _) = CLIStreams.buffered()
        let createCode = await CLIRunner.run(
            [
                "headless", "--prompt", "create pinned session",
                "--cwd", workspace.path,
                "--session-id", "pinned-session"
            ],
            environment: environment,
            streams: createStreams,
            application: application
        )
        let sessionURL = state.appendingPathComponent("sessions/pinned-session.json")
        let persisted = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: sessionURL)) as? [String: Any]
        )
        #expect(createCode == CLIRunner.ExitCode.success.rawValue)
        #expect(persisted["sandbox_profile"] as? String == "off")

        var pinned = persisted
        pinned["sandbox_profile"] = "strict"
        try JSONSerialization.data(withJSONObject: pinned, options: [.prettyPrinted, .sortedKeys])
            .write(to: sessionURL, options: .atomic)

        let (resumeStreams, resumeOut, resumeErr) = CLIStreams.buffered()
        let resumeCode = await CLIRunner.run(
            [
                "headless", "--prompt", "must not sample",
                "--cwd", workspace.path,
                "--resume", "pinned-session",
                "--sandbox", "off"
            ],
            environment: environment,
            streams: resumeStreams,
            application: application
        )

        #expect(resumeCode == CLIRunner.ExitCode.failure.rawValue)
        #expect(resumeOut.contents.isEmpty)
        #expect(resumeErr.contents.contains("cannot resume this session with sandbox profile 'off'"))
        #expect(resumeErr.contents.contains("created with 'strict'"))
        #expect(sampler.recordedRequests.count == 1)
    }

    @Test("live continue selects the latest session for the working directory")
    func liveSessionContinueComposition() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspace = root.appendingPathComponent("workspace")
        let otherWorkspace = root.appendingPathComponent("other-workspace")
        let state = root.appendingPathComponent("state")
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: otherWorkspace, withIntermediateDirectories: true)
        let sampler = ParitySamplerFixture(responses: [
            "workspace question": OpenGrokLiveSamplingResponse(output: "workspace answer"),
            "other question": OpenGrokLiveSamplingResponse(output: "other answer"),
            "continued question": OpenGrokLiveSamplingResponse(output: "continued answer")
        ])
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in sampler.makeSampler() }
        )
        let application = OpenGrokApplication.live(dependencies: dependencies, control: .never)
        let environment = [
            "HOME": root.path,
            "OPENGROK_HOME": state.path,
            "XAI_API_KEY": "test-key"
        ]

        let (workspaceStreams, _, _) = CLIStreams.buffered()
        let workspaceCode = await CLIRunner.run(
            [
                "headless", "--prompt", "workspace question",
                "--cwd", workspace.path,
                "--session-id", "workspace-session"
            ],
            environment: environment,
            streams: workspaceStreams,
            application: application
        )
        let (otherStreams, _, _) = CLIStreams.buffered()
        let otherCode = await CLIRunner.run(
            [
                "headless", "--prompt", "other question",
                "--cwd", otherWorkspace.path,
                "--session-id", "other-session"
            ],
            environment: environment,
            streams: otherStreams,
            application: application
        )
        let (continueStreams, _, _) = CLIStreams.buffered()
        let continueCode = await CLIRunner.run(
            [
                "headless", "--prompt", "continued question",
                "--cwd", workspace.path,
                "--continue"
            ],
            environment: environment,
            streams: continueStreams,
            application: application
        )

        let requests = sampler.recordedRequests
        #expect(workspaceCode == CLIRunner.ExitCode.success.rawValue)
        #expect(otherCode == CLIRunner.ExitCode.success.rawValue)
        #expect(continueCode == CLIRunner.ExitCode.success.rawValue)
        #expect(requests.last?.sessionID == "workspace-session")
        #expect(requests.last?.items == [
            .user("workspace question"),
            .assistant(AssistantItem(content: "workspace answer")),
            .user("continued question")
        ])
    }

    @Test("live session forks copy route metadata, history, and rewind state")
    func liveSessionForkComposition() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspace = root.appendingPathComponent("workspace")
        let state = root.appendingPathComponent("state")
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let sampler = ParitySamplingConfigurationFixture()
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: sampler.makeSampler(configuration:)
        )
        let application = OpenGrokApplication.live(dependencies: dependencies, control: .never)
        let environment = [
            "HOME": root.path,
            "OPENGROK_HOME": state.path,
            "XAI_API_KEY": "test-key",
            "FIREWORKS_API_KEY": "fireworks-key"
        ]

        let (sourceStreams, _, _) = CLIStreams.buffered()
        let sourceCode = await CLIRunner.run(
            [
                "headless", "--prompt", "source question",
                "--model", "glm-5.2",
                "--cwd", workspace.path,
                "--session-id", "source-session"
            ],
            environment: environment,
            streams: sourceStreams,
            application: application
        )
        let parentRewind = LiveRewindStore(openGrokHome: state, sessionID: "source-session")
        await parentRewind.append(LiveRewindPoint(
            promptIndex: 0,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            promptText: "source question"
        ))
        let parentRewindURL = LiveRewindStore.rewindFileURL(
            openGrokHome: state,
            sessionID: "source-session"
        )
        let parentRewindBytes = try? Data(contentsOf: parentRewindURL)
        let (forkStreams, _, _) = CLIStreams.buffered()
        let forkCode = await CLIRunner.run(
            [
                "headless", "--prompt", "fork question",
                "--cwd", workspace.path,
                "--resume", "source-session",
                "--fork-session",
                "--session-id", "fork-session"
            ],
            environment: environment,
            streams: forkStreams,
            application: application
        )
        let (resumeStreams, _, _) = CLIStreams.buffered()
        let resumeCode = await CLIRunner.run(
            [
                "headless", "--prompt", "source follow-up",
                "--cwd", workspace.path,
                "--resume", "source-session"
            ],
            environment: environment,
            streams: resumeStreams,
            application: application
        )

        let requests = sampler.recordedRequests
        let configurations = sampler.recordedConfigurations
        let forkURL = state.appendingPathComponent("sessions/fork-session.json")
        let forkObject = (try? Data(contentsOf: forkURL)).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        let store = LiveConversationStore(openGrokHome: state)
        let childRecord = try? await store.load(sessionID: "fork-session")
        let childRewindURL = LiveRewindStore.rewindFileURL(
            openGrokHome: state,
            sessionID: "fork-session"
        )
        let childRewindBytes = try? Data(contentsOf: childRewindURL)
        #expect(sourceCode == CLIRunner.ExitCode.success.rawValue)
        #expect(forkCode == CLIRunner.ExitCode.success.rawValue)
        #expect(resumeCode == CLIRunner.ExitCode.success.rawValue)
        #expect(configurations.map(\.provider) == [.fireworks, .fireworks, .fireworks])
        #expect(configurations.map(\.model) == [
            "accounts/fireworks/models/glm-5p2",
            "accounts/fireworks/models/glm-5p2",
            "accounts/fireworks/models/glm-5p2"
        ])
        #expect(requests[1].sessionID == "fork-session")
        #expect(requests[1].items == [
            .user("source question"),
            .assistant(AssistantItem(content: "provider answer")),
            .user("fork question")
        ])
        #expect(requests[2].sessionID == "source-session")
        #expect(requests[2].items == [
            .user("source question"),
            .assistant(AssistantItem(content: "provider answer")),
            .user("source follow-up")
        ])
        #expect(forkObject?["parentSessionID"] as? String == "source-session")
        #expect(forkObject?["current_model_id"] as? String == "accounts/fireworks/models/glm-5p2")
        #expect(forkObject?["current_provider"] as? String == "fireworks")
        #expect(forkObject?["ever_used_codex"] as? Bool == true)
        #expect(childRecord?.parentSessionID == "source-session")
        #expect(childRecord?.currentModelID == "accounts/fireworks/models/glm-5p2")
        #expect(childRecord?.currentProvider == .fireworks)
        #expect(childRecord?.everUsedNonXAI == true)
        #expect(childRewindBytes == parentRewindBytes)

        if let childRecord {
            let childServices = await OpenGrokLiveApplicationLauncher.makeSessionServices(
                sessionID: "fork-session",
                workingDirectory: workspace,
                openGrokHome: state,
                conversationRecord: childRecord,
                environment: environment
            )
            guard let childRewind = childServices.rewind else {
                Issue.record("forked session services did not construct rewind")
                return
            }
            let points = await childRewind.points()
            #expect(points.map(\.promptIndex) == [0])
            let dryRun = try? await childRewind.restore(
                toPromptIndex: 0,
                mode: .conversationOnly,
                force: false,
                currentItems: childRecord.items
            )
            #expect(dryRun?.applied == false)
            #expect(dryRun?.targetPromptIndex == 0)
        }
    }

    @Test("forking a legacy record refuses before creating child artifacts")
    func legacyForkRefusesWithoutChildArtifacts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspace = root.appendingPathComponent("workspace")
        let state = root.appendingPathComponent("state")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        var legacy = LiveConversationRecord.new(
            sessionID: "legacy-source",
            workingDirectory: workspace
        )
        legacy.everUsedNonXAI = nil
        try await LiveConversationStore(openGrokHome: state).save(legacy)

        let application = OpenGrokApplication.live(
            dependencies: OpenGrokLiveCompositionDependencies(
                makeSampler: { _ in
                    OpenGrokLiveSampler { _, _ in
                        OpenGrokLiveSamplingResponse(output: "should not sample")
                    }
                }
            ),
            control: .never
        )
        let (streams, _, errorOutput) = CLIStreams.buffered()
        let code = await CLIRunner.run(
            [
                "headless", "--prompt", "fork question",
                "--resume", "legacy-source",
                "--fork-session", "--session-id", "legacy-child",
                "--cwd", workspace.path
            ],
            environment: [
                "HOME": root.path,
                "OPENGROK_HOME": state.path,
                "XAI_API_KEY": "xai-key"
            ],
            streams: streams,
            application: application
        )

        #expect(code == CLIRunner.ExitCode.failure.rawValue)
        #expect(errorOutput.contents.contains("ever_used_codex"))
        #expect((try? await LiveConversationStore(openGrokHome: state).load(sessionID: "legacy-child")) == nil)
        #expect(!FileManager.default.fileExists(atPath: LiveRewindStore.rewindFileURL(
            openGrokHome: state,
            sessionID: "legacy-child"
        ).path))
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

    @Test("non-TTY fallback preserves structured tool cards")
    func inlineFallbackToolCards() async {
        let terminal = ParityTerminalFixture(tty: false, size: nil)
        let backend = ParityShellCommandBackend()
        let sampler = ParityToolLoopSamplerFixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in sampler.makeSampler() },
            makeProcessBackend: { backend },
            terminal: terminal.terminal
        )
        let application = OpenGrokApplication.live(dependencies: dependencies, control: .never)
        let (streams, out, err) = CLIStreams.buffered()

        let code = await CLIRunner.run(
            [
                "interactive", "--prompt", "use the terminal", "--cwd", root.path,
                "--allowedTools", "Bash",
            ],
            environment: [
                "HOME": root.path,
                "OPENGROK_HOME": root.appendingPathComponent("state").path,
                "XAI_API_KEY": "test-key"
            ],
            streams: streams,
            application: application
        )

        let output = terminal.output
        let toolRange = output.range(of: "Tool run_terminal_cmd [done]")
        let answerRange = output.range(of: "Grok: final answer after tool output")
        #expect(code == CLIRunner.ExitCode.success.rawValue)
        #expect(out.contents.isEmpty)
        #expect(err.contents.isEmpty)
        #expect(output.contains(#"input: {"command":"printf tool-output","description":"parity tool"}"#))
        #expect(output.contains("result: tool output"))
        #expect(toolRange != nil)
        #expect(answerRange != nil)
        if let toolRange, let answerRange {
            #expect(toolRange.lowerBound < answerRange.lowerBound)
        }
        #expect(!output.contains("\u{1B}[?1049h"))
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

    @Test("delta coalescing preserves the exact token sequence")
    func textDeltaCoalescingPreservesText() {
        // A long interval forces every delta after the first to accumulate.
        var batching = LiveTextDeltaCoalescer(interval: .seconds(3_600))
        let tokens = ["The ", "answer ", "arrives ", "in pieces."]
        var released: [String] = []
        for token in tokens {
            if let batch = batching.push(token) {
                released.append(batch)
            }
        }
        if let batch = batching.flush() {
            released.append(batch)
        }

        #expect(released.joined() == tokens.joined())
        #expect(released.first == "The ")
        #expect(released.count == 2)

        // Whatever the interval, the released batches must still concatenate to
        // the pushed tokens and nothing may be released twice.
        var immediate = LiveTextDeltaCoalescer(interval: .milliseconds(0))
        var eager = tokens.compactMap { immediate.push($0) }
        if let batch = immediate.flush() {
            eager.append(batch)
        }
        #expect(eager.joined() == tokens.joined())
        #expect(immediate.flush() == nil)

        // Empty deltas never produce a batch.
        var idle = LiveTextDeltaCoalescer()
        #expect(idle.push("") == nil)
        #expect(idle.flush() == nil)
    }

    @Test("streaming JSON forwards assistant deltas in order without coalescing them")
    func liveStreamingJSONAssistantDeltaOrdering() async {
        for outputFormat in ["streaming-json", "streaming-messages-json"] {
            let deltas = ["The ", "answer ", "arrives ", "in pieces."]
            let sampler = ParityStreamingSamplerFixture(deltas: deltas)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let dependencies = OpenGrokLiveCompositionDependencies(
                makeSampler: { _ in sampler.makeSampler() }
            )
            let application = OpenGrokApplication.live(dependencies: dependencies, control: .never)
            let (streams, out, _) = CLIStreams.buffered()

            let code = await CLIRunner.run(
                [
                    "headless", "--prompt", "stream it",
                    "--cwd", root.path,
                    "--output-format", outputFormat
                ],
                environment: [
                    "HOME": root.path,
                    "OPENGROK_HOME": root.appendingPathComponent("state").path,
                    "XAI_API_KEY": "test-key"
                ],
                streams: streams,
                application: application
            )

            let records = out.contents.split(separator: "\n").compactMap { line in
                try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            }
            let textType = outputFormat == "streaming-messages-json" ? "assistant" : "output"
            let textRecords = records.filter { $0["type"] as? String == textType }
            let contents = textRecords.compactMap { $0["content"] as? String }

            #expect(code == CLIRunner.ExitCode.success.rawValue)
            #expect(contents == deltas)
            #expect(contents.joined() == sampler.answer)
            // The terminal event must not overtake the deltas that precede it.
            let completedIndex = records.firstIndex { $0["type"] as? String == "completed" }
            let lastTextIndex = records.lastIndex { $0["type"] as? String == textType }
            #expect(completedIndex != nil)
            if let completedIndex, let lastTextIndex {
                #expect(lastTextIndex < completedIndex)
            }
        }
    }

    @Test("Ctrl-C mid-stream cancels the turn and keeps the delivered deltas")
    func ctrlCCancellationMidStream() async {
        let terminal = ParityTerminalFixture(
            tty: true,
            size: OpenGrokLiveTerminalSize(width: 60, height: 12)
        )
        let deltas = ["partial ", "answer "]
        let sampler = ParityStreamingSamplerFixture(
            deltas: deltas,
            holdOpenAfterDeltas: true
        )
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
            makeSampler: { _ in sampler.makeSampler() },
            terminal: terminal.terminal
        )
        let application = OpenGrokApplication.live(dependencies: dependencies, control: control)
        let (streams, _, _) = CLIStreams.buffered()
        let task = Task {
            await CLIRunner.run(
                ["interactive", "--prompt", "cancel mid stream"],
                environment: [
                    "HOME": root.path,
                    "OPENGROK_HOME": root.appendingPathComponent("state").path,
                    "XAI_API_KEY": "test-key"
                ],
                streams: streams,
                application: application
            )
        }

        await sampler.waitForDeltas()
        // Wait for the deltas to reach the frame as well, so the assertion
        // below is about cancellation rather than about render timing.
        await Self.waitForTerminalOutput("partial", terminal: terminal)
        if await input.next() == .ctrlC {
            cancellation.cancel()
        }
        let code = await task.value

        #expect(code == CLIRunner.ExitCode.cancelled.rawValue)
        #expect(sampler.emittedDeltas == deltas)
        // Text delivered before the cancellation survives into the transcript.
        #expect(terminal.output.contains("partial"))
        #expect(terminal.output.contains("\u{1B}[?1049l"))
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

    /// Wait for text that only ever appears on screen, never in the transcript.
    private static func waitForPaintedText(
        _ text: String,
        terminal: ParityTerminalFixture
    ) async {
        for _ in 0..<1_000 {
            if terminal.paintedText.contains(text) {
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
