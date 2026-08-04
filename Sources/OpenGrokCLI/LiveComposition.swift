import Foundation
import OpenGrokModels
import OpenGrokPager
import OpenGrokPagerMinimal
import OpenGrokPagerRender
import OpenGrokProviderSession
import OpenGrokSampler
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase
import OpenGrokTerminalCore
import OpenGrokTTY

public struct OpenGrokLiveSamplingConfiguration: Sendable, Equatable {
    public let model: String
    public let baseURL: String
    public let apiKey: String
    public let provider: ModelProvider
    public let apiBackend: ApiBackend

    public init(
        model: String,
        baseURL: String,
        apiKey: String,
        provider: ModelProvider = .xai,
        apiBackend: ApiBackend = .chatCompletions
    ) {
        self.model = model
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.provider = provider
        self.apiBackend = apiBackend
    }
}

public struct OpenGrokLiveSamplingRequest: Sendable, Equatable {
    public let sessionID: String
    public let turnID: String
    public let model: String
    public let prompt: String

    public init(sessionID: String, turnID: String, model: String, prompt: String) {
        self.sessionID = sessionID
        self.turnID = turnID
        self.model = model
        self.prompt = prompt
    }
}

public enum OpenGrokLiveSamplingEvent: Sendable, Equatable {
    case output(String)
    case status(String)
}

public struct OpenGrokLiveSamplingResponse: Sendable, Equatable {
    public let output: String
    public let stopReason: String?

    public init(output: String, stopReason: String? = nil) {
        self.output = output
        self.stopReason = stopReason
    }
}

public struct OpenGrokLiveSampler: Sendable {
    public typealias Emit = @Sendable (OpenGrokLiveSamplingEvent) async -> Void

    private let sampleOperation: @Sendable (
        OpenGrokLiveSamplingRequest,
        @escaping Emit
    ) async throws -> OpenGrokLiveSamplingResponse

    public init(
        sample: @escaping @Sendable (
            OpenGrokLiveSamplingRequest,
            @escaping Emit
        ) async throws -> OpenGrokLiveSamplingResponse
    ) {
        self.sampleOperation = sample
    }

    public func sample(
        _ request: OpenGrokLiveSamplingRequest,
        emit: @escaping Emit
    ) async throws -> OpenGrokLiveSamplingResponse {
        try await sampleOperation(request, emit)
    }

    public static func production(
        configuration: OpenGrokLiveSamplingConfiguration
    ) throws -> OpenGrokLiveSampler {
        let client = try SamplingClient(config: SamplerConfig(
            apiKey: configuration.apiKey,
            baseURL: configuration.baseURL,
            model: configuration.model,
            apiBackend: configuration.apiBackend,
            provider: configuration.provider
        ))
        return OpenGrokLiveSampler { request, emit in
            await emit(.status("sampling"))
            let response = try await client.conversationCollect(ConversationRequest(
                items: [.user(request.prompt)],
                model: request.model,
                xGrokReqId: request.turnID,
                xGrokSessionId: request.sessionID
            ))
            let output = response.assistantText()
            if !output.isEmpty {
                await emit(.output(output))
            }
            return OpenGrokLiveSamplingResponse(
                output: output,
                stopReason: response.stopReason?.asString
            )
        }
    }
}

public struct OpenGrokLiveCompositionDependencies: Sendable {
    public let makeSampler: @Sendable (OpenGrokLiveSamplingConfiguration) throws -> OpenGrokLiveSampler
    public let terminal: OpenGrokLiveTerminal

    public init(
        makeSampler: @escaping @Sendable (OpenGrokLiveSamplingConfiguration) throws -> OpenGrokLiveSampler,
        terminal: OpenGrokLiveTerminal = .production
    ) {
        self.makeSampler = makeSampler
        self.terminal = terminal
    }

    public static let production = OpenGrokLiveCompositionDependencies(
        makeSampler: OpenGrokLiveSampler.production(configuration:),
        terminal: .production
    )
}

public struct OpenGrokLiveTerminalSize: Sendable, Equatable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
    }
}

public struct OpenGrokLiveTerminal: Sendable {
    private let isTTYOperation: @Sendable () -> Bool
    private let sizeOperation: @Sendable () -> OpenGrokLiveTerminalSize?
    private let writeOperation: @Sendable (Data) async throws -> Void

    public init(
        isTTY: @escaping @Sendable () -> Bool,
        size: @escaping @Sendable () -> OpenGrokLiveTerminalSize?,
        write: @escaping @Sendable (Data) async throws -> Void
    ) {
        self.isTTYOperation = isTTY
        self.sizeOperation = size
        self.writeOperation = write
    }

    public func isTTY() -> Bool {
        isTTYOperation()
    }

    public func size() -> OpenGrokLiveTerminalSize? {
        sizeOperation()
    }

    public func write(_ string: String) async throws {
        try await writeOperation(Data(string.utf8))
    }

    public func write(_ data: Data) async throws {
        try await writeOperation(data)
    }

    public static var production: OpenGrokLiveTerminal {
        let adapter = PlatformTTYAdapter()
        return OpenGrokLiveTerminal(
            isTTY: { adapter.isATTY() },
            size: {
                adapter.size().map {
                    OpenGrokLiveTerminalSize(width: $0.width, height: $0.height)
                }
            },
            write: { data in try await adapter.write(data) }
        )
    }
}

extension OpenGrokApplication {
    public static func live(
        dependencies: OpenGrokLiveCompositionDependencies = .production,
        control: CLIExecutionControl = .taskCancellation
    ) -> OpenGrokApplication {
        OpenGrokApplication(
            launcher: OpenGrokLiveApplicationLauncher(dependencies: dependencies).launcher,
            control: control
        )
    }
}

public struct OpenGrokLiveApplicationLauncher: Sendable {
    private let dependencies: OpenGrokLiveCompositionDependencies

    public init(dependencies: OpenGrokLiveCompositionDependencies = .production) {
        self.dependencies = dependencies
    }

    public var launcher: CLIApplicationLauncher {
        CLIApplicationLauncher { command, context in
            guard case .launch(let options) = command else {
                throw CLIApplicationError.unsupported(route: command.routeName)
            }
            guard options.mode == .interactive || options.mode == .minimal || options.mode == .headless else {
                throw CLIApplicationError.unsupported(route: options.mode.rawValue)
            }
            try Self.validateUnsupportedOptions(options)

            let prompt = try Self.resolvePrompt(options, environment: context.environment)
            let cwd = try Self.resolveWorkingDirectory(options.common.cwd)
            let openGrokHome = Self.resolveOpenGrokHome(environment: context.environment)
            let sessionID = options.sessionID ?? UUID().uuidString
            let samplingConfiguration = try Self.resolveSamplingConfiguration(
                options: options,
                environment: context.environment
            )
            let sampler = try dependencies.makeSampler(samplingConfiguration)
            let providerConfiguration = Self.makeProviderConfiguration(
                sessionID: sessionID,
                sampling: samplingConfiguration,
                openGrokHome: openGrokHome,
                environment: context.environment
            )
            let shell = OpenGrokShell(configuration: OpenGrokShellConfiguration(
                openGrokHome: openGrokHome,
                processBackend: UnavailableLiveShellProcessBackend(),
                providerFactory: ProviderSessionFactoryAdapter(),
                turnDriver: ProviderSessionTurnDriver(
                    sampler: LiveShellSamplingDriver(sampler: sampler)
                )
            ))
            let runtime = LivePagerRuntimeAdapter(
                shell: shell,
                cwd: cwd,
                providerConfiguration: providerConfiguration
            )
            if options.mode == .interactive {
                let pagerMode = try Self.resolveInteractivePagerMode(
                    options: options,
                    terminal: dependencies.terminal
                )
                let pager = OpenGrokPager(
                    runtime: runtime,
                    frontendFactory: LiveInteractiveFrontendFactory(
                        terminal: dependencies.terminal,
                        prompt: prompt
                    )
                )
                let task = Task {
                    try await pager.run(OpenGrokPagerRequest(
                        prompt: prompt,
                        mode: pagerMode,
                        sessionID: sessionID,
                        metadata: ["mode": options.mode.rawValue]
                    ))
                }
                return CLIApplicationSession(
                    waitForExit: {
                        _ = try await task.value
                    },
                    shutdown: {
                        task.cancel()
                        await pager.shutdown()
                        _ = await shell.shutdown(timeout: ShellDuration(timeInterval: 1))
                    }
                )
            } else {
                let pager = OpenGrokPagerMinimal(
                    runtime: runtime,
                    renderer: PlainLivePagerRenderer(),
                    output: LivePagerOutput(streams: context.streams, format: options.outputFormat)
                )
                let task = Task {
                    try await pager.run(OpenGrokPagerMinimalRequest(
                        prompt: prompt,
                        sessionID: sessionID,
                        metadata: ["mode": options.mode.rawValue]
                    ))
                }
                return CLIApplicationSession(
                    waitForExit: {
                        _ = try await task.value
                    },
                    shutdown: {
                        task.cancel()
                        await pager.shutdown()
                        _ = await shell.shutdown(timeout: ShellDuration(timeInterval: 1))
                    }
                )
            }
        }
    }

    private static func validateUnsupportedOptions(_ options: CLIExecutionOptions) throws {
        if options.resume != nil || options.continueSession || options.forkSession {
            throw CLIApplicationError.unsupported(route: "session restoration")
        }
        if options.common.profile != nil || !options.common.pluginDirectories.isEmpty {
            throw CLIApplicationError.unsupported(route: "profiles and plugins")
        }
        if options.common.mcpConfig != nil || options.common.workflow != nil {
            throw CLIApplicationError.unsupported(route: "MCP and workflows")
        }
        if options.common.leader || options.common.noLeader {
            throw CLIApplicationError.unsupported(route: "interactive composition options")
        }
        if options.mode == .interactive && options.outputFormat != .plain {
            throw CLIApplicationError.unsupported(route: "interactive structured output")
        }
        if options.noAltScreen && options.fullscreen {
            throw CLIApplicationError.failed("--no-alt-screen and --fullscreen cannot be used together")
        }
    }

    private static func resolveInteractivePagerMode(
        options: CLIExecutionOptions,
        terminal: OpenGrokLiveTerminal
    ) throws -> OpenGrokPagerMode {
        if options.noAltScreen {
            return .inline
        }
        if options.fullscreen {
            guard terminal.isTTY() else {
                throw CLIApplicationError.failed("--fullscreen requires an attached terminal")
            }
            return .fullScreen
        }
        return terminal.isTTY() ? .fullScreen : .inline
    }

    private static func resolvePrompt(
        _ options: CLIExecutionOptions,
        environment: [String: String]
    ) throws -> String {
        let prompt: String
        if let direct = options.prompt {
            prompt = direct
        } else if let path = options.promptFile {
            let url = resolveURL(path, relativeTo: FileManager.default.currentDirectoryPath)
            do {
                prompt = try String(contentsOf: url, encoding: .utf8)
            } catch {
                throw CLIApplicationError.failed("could not read prompt file '\(url.path)': \(error)")
            }
        } else if let json = options.promptJSON {
            prompt = try decodePromptJSON(json)
        } else if let inherited = environment["OPENGROK_PROMPT"], !inherited.isEmpty {
            prompt = inherited
        } else {
            throw CLIApplicationError.failed("\(options.mode.rawValue) mode requires a prompt")
        }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CLIApplicationError.failed("prompt must not be empty")
        }
        return prompt
    }

    private static func decodePromptJSON(_ value: String) throws -> String {
        guard let data = value.data(using: .utf8) else {
            throw CLIApplicationError.failed("prompt JSON is not UTF-8")
        }
        do {
            let decoded = try JSONSerialization.jsonObject(with: data)
            if let prompt = decoded as? String {
                return prompt
            }
            if let object = decoded as? [String: Any] {
                if let prompt = object["prompt"] as? String { return prompt }
                if let text = object["text"] as? String { return text }
            }
            throw CLIApplicationError.failed("prompt JSON must be a string or contain 'prompt' or 'text'")
        } catch let error as CLIApplicationError {
            throw error
        } catch {
            throw CLIApplicationError.failed("invalid prompt JSON: \(error)")
        }
    }

    private static func resolveWorkingDirectory(_ path: String?) throws -> URL {
        let url = resolveURL(path ?? FileManager.default.currentDirectoryPath, relativeTo: FileManager.default.currentDirectoryPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CLIApplicationError.failed("working directory does not exist: \(url.path)")
        }
        return url
    }

    private static func resolveURL(_ path: String, relativeTo cwd: String) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return URL(fileURLWithPath: cwd, isDirectory: true)
            .appendingPathComponent(path)
            .standardizedFileURL
    }

    private static func resolveOpenGrokHome(environment: [String: String]) -> URL {
        if let path = environment["OPENGROK_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        let home = environment["HOME"] ?? environment["USERPROFILE"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".opengrok", isDirectory: true)
            .standardizedFileURL
    }

    private static func resolveSamplingConfiguration(
        options: CLIExecutionOptions,
        environment: [String: String]
    ) throws -> OpenGrokLiveSamplingConfiguration {
        let provider = options.common.provider?.lowercased() ?? "xai"
        guard provider == "xai" else {
            throw CLIApplicationError.unsupported(route: "provider \(provider)")
        }
        guard let apiKey = environment["XAI_API_KEY"], !apiKey.isEmpty else {
            throw CLIApplicationError.failed("XAI_API_KEY is required for the live Swift composition")
        }
        let model = options.common.model ?? defaultModel()
        let baseURL = environment["GROK_XAI_API_BASE_URL"]
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? XAI_API_BASE_URL_DEFAULT
        return OpenGrokLiveSamplingConfiguration(
            model: model,
            baseURL: baseURL,
            apiKey: apiKey
        )
    }

    private static func makeProviderConfiguration(
        sessionID: String,
        sampling: OpenGrokLiveSamplingConfiguration,
        openGrokHome: URL,
        environment: [String: String]
    ) -> ProviderSessionConfiguration {
        let endpoints = EndpointsConfig(
            xaiApiBaseURL: sampling.baseURL,
            modelsBaseURL: sampling.baseURL
        )
        let entry = ModelEntry.fallback(slug: sampling.model, endpoints: endpoints)
        return ProviderSessionConfiguration(
            sessionID: sessionID,
            modelCatalog: [sampling.model: entry],
            initialModelID: sampling.model,
            credentialBindings: [
                sampling.provider: .apiKey(scope: "cli:\(sessionID)", key: sampling.apiKey)
            ],
            openGrokHome: openGrokHome,
            environment: environment
        )
    }
}

private struct LiveShellSamplingDriver: OpenGrokShellSamplingDriver, Sendable {
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
            case .output(let text):
                await emit(.assistantText(text))
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

private struct LivePagerRuntimeAdapter: OpenGrokPagerMinimalRuntimeAdapter, OpenGrokPagerRuntimeAdapter, Sendable {
    let shell: OpenGrokShell
    let cwd: URL
    let providerConfiguration: ProviderSessionConfiguration

    func makeSession(
        for request: OpenGrokPagerMinimalRequest
    ) async throws -> any OpenGrokPagerMinimalSessionAdapter {
        _ = try await shell.start()
        let shellEvents = await shell.events()
        let sessionID = SessionID(request.sessionID ?? providerConfiguration.sessionID)
        _ = try await shell.createSession(OpenGrokShellSessionRequest(
            sessionID: sessionID,
            cwd: cwd,
            providerConfiguration: providerConfiguration,
            restorePersistedState: false
        ))
        let handle = try await shell.submitTurn(
            sessionID: sessionID,
            request: OpenGrokShellTurnRequest(text: request.prompt)
        )
        return LivePagerSession(shell: shell, handle: handle, shellEvents: shellEvents)
    }

    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        try await makeSession(for: request.sessionRequest)
    }
}

private final class LivePagerSession: OpenGrokPagerMinimalSessionAdapter, @unchecked Sendable {
    let sessionID: String?
    let events: AsyncThrowingStream<OpenGrokPagerMinimalEvent, Error>

    private let shell: OpenGrokShell
    private let handle: OpenGrokShellTurnHandle
    private let eventTask: Task<Void, Never>

    init(
        shell: OpenGrokShell,
        handle: OpenGrokShellTurnHandle,
        shellEvents: AsyncThrowingStream<OpenGrokShellEvent, Error>
    ) {
        self.shell = shell
        self.handle = handle
        self.sessionID = handle.sessionID.rawValue
        var continuation: AsyncThrowingStream<OpenGrokPagerMinimalEvent, Error>.Continuation!
        self.events = AsyncThrowingStream { continuation = $0 }
        self.eventTask = Task {
            do {
                for try await event in shellEvents {
                    switch event {
                    case .turnUpdate(let update) where update.turnID == handle.turnID:
                        switch update.kind {
                        case .assistantText(let text): continuation.yield(.output(text))
                        case .status(let status): continuation.yield(.status(status))
                        }
                    case .turnCompleted(let result) where result.turnID == handle.turnID:
                        continuation.yield(.completed(OpenGrokPagerMinimalCompletion(
                            sessionID: handle.sessionID.rawValue,
                            summary: result.stopReason
                        )))
                        continuation.finish()
                        return
                    case .turnCancelled(let cancelled) where cancelled == handle:
                        continuation.yield(.cancelled)
                        continuation.finish()
                        return
                    case .turnFailed(let failed, let message) where failed == handle:
                        continuation.finish(throwing: CLIApplicationError.failed(message))
                        return
                    default:
                        continue
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    func cancel() async {
        eventTask.cancel()
        try? await shell.cancelTurn(handle)
    }

    func close() async {
        eventTask.cancel()
        _ = await shell.shutdown(timeout: ShellDuration(timeInterval: 1))
    }
}

private struct PlainLivePagerRenderer: OpenGrokPagerMinimalRenderAdapter, Sendable {
    func begin() async throws {}
    func render(_ event: OpenGrokPagerMinimalEvent) async throws {}
    func restoreTerminal() async throws {}
}

private struct LiveInteractiveFrontendFactory: OpenGrokPagerFrontendFactory, Sendable {
    let terminal: OpenGrokLiveTerminal
    let prompt: String

    func makeFrontend(for mode: OpenGrokPagerMode) async throws -> any OpenGrokPagerFrontend {
        guard mode == .fullScreen || mode == .inline else {
            throw CLIApplicationError.unsupported(route: "interactive pager mode \(mode.rawValue)")
        }
        return OpenGrokPagerForwardingFrontend(
            renderer: LiveInteractivePagerRenderer(mode: mode, terminal: terminal, prompt: prompt),
            output: SilentLivePagerOutput()
        )
    }
}

private actor LiveInteractivePagerRenderer: OpenGrokPagerRenderAdapter {
    private let mode: OpenGrokPagerMode
    private let terminal: OpenGrokLiveTerminal
    private let prompt: String
    private let renderEngine = PagerRenderEngine()

    private var output = ""
    private var status = "Starting"
    private var inlineBegan = false
    private var inlineEnded = false
    private var restored = false

    init(mode: OpenGrokPagerMode, terminal: OpenGrokLiveTerminal, prompt: String) {
        self.mode = mode
        self.terminal = terminal
        self.prompt = prompt
    }

    func begin() async throws {
        switch mode {
        case .fullScreen:
            try await terminal.write("\u{1B}[?1049h\u{1B}[?25l")
            try await renderFullScreen()
        case .inline:
            inlineBegan = true
            try await terminal.write("You: \(prompt)\nGrok: ")
        case .minimal, .plain:
            throw CLIApplicationError.unsupported(route: "interactive pager mode \(mode.rawValue)")
        }
    }

    func render(_ event: OpenGrokPagerEvent) async throws {
        switch event {
        case .lifecycle(.starting):
            status = "Starting"
        case .lifecycle(.running):
            status = "Thinking"
        case .lifecycle(let lifecycle):
            status = lifecycle.rawValue
        case .output(let text):
            output += text
            status = "Responding"
            if mode == .inline {
                try await terminal.write(text)
            }
        case .status(let value):
            status = value
        case .permissionRequested(let request):
            status = "Permission required: \(request.prompt)"
        case .completed:
            status = "Completed"
            if mode == .inline {
                try await finishInline()
            }
        case .cancelled:
            status = "Cancelled"
            if mode == .inline {
                try await finishInline()
            }
        }
        if mode == .fullScreen {
            try await renderFullScreen()
        }
    }

    func restoreTerminal() async throws {
        guard !restored else { return }
        restored = true
        switch mode {
        case .fullScreen:
            try await terminal.write(TerminalRestore.fullRestore)
            try await terminal.write(finalTranscript)
        case .inline:
            try await finishInline()
        case .minimal, .plain:
            break
        }
    }

    private func renderFullScreen() async throws {
        let terminalSize = terminal.size() ?? OpenGrokLiveTerminalSize(width: 80, height: 24)
        let result = renderEngine.render(PagerRenderState(
            size: OpenGrokTerminalCore.TerminalSize(
                width: terminalSize.width,
                height: terminalSize.height
            ),
            header: PagerHeader(title: "Open Grok", subtitle: "Interactive"),
            conversation: [
                .message(PagerMessage(role: .user, text: prompt)),
                .message(PagerMessage(role: .assistant, text: output, isStreaming: status == "Responding"))
            ],
            status: PagerStatusLine(text: status, isStreaming: status == "Thinking" || status == "Responding"),
            input: PagerInputState(
                prompt: "",
                text: "",
                isFocused: false,
                cursorVisible: false,
                maximumHeight: 1
            ),
            footer: PagerFooter(leading: "Ctrl-C cancel", trailing: "Swift port")
        ))
        let frame = ANSIOutput.beginSynchronizedUpdate
            + ANSIOutput.moveTo(column: 0, row: 0)
            + result.snapshot(includeTrailingSpaces: true)
            + ANSIOutput.clearFromCursorDown
            + ANSIOutput.endSynchronizedUpdate
        try await terminal.write(frame)
    }

    private func finishInline() async throws {
        guard inlineBegan, !inlineEnded else { return }
        inlineEnded = true
        if !output.hasSuffix("\n") {
            try await terminal.write("\n")
        }
    }

    private var finalTranscript: String {
        var transcript = "You: \(prompt)\nGrok: \(output)"
        if !transcript.hasSuffix("\n") {
            transcript += "\n"
        }
        return transcript
    }
}

private struct SilentLivePagerOutput: OpenGrokPagerOutputAdapter, Sendable {
    func forward(_ event: OpenGrokPagerEvent) async throws {}
}

private actor LivePagerOutput: OpenGrokPagerMinimalOutputAdapter {
    private let streams: CLIStreams
    private let format: CLIOutputFormat
    private var collectedOutput = ""
    private var wrotePlainOutput = false

    init(streams: CLIStreams, format: CLIOutputFormat) {
        self.streams = streams
        self.format = format
    }

    func forward(_ event: OpenGrokPagerMinimalEvent) async throws {
        switch format {
        case .plain:
            forwardPlain(event)
        case .json:
            try forwardJSON(event)
        case .streamingJSON:
            try forwardStreamingJSON(event, messagesOnly: false)
        case .streamingMessagesJSON:
            try forwardStreamingJSON(event, messagesOnly: true)
        }
    }

    private func forwardPlain(_ event: OpenGrokPagerMinimalEvent) {
        switch event {
        case .output(let text):
            collectedOutput += text
            wrotePlainOutput = true
            streams.out(text)
        case .completed:
            if wrotePlainOutput, !collectedOutput.hasSuffix("\n") {
                streams.out("\n")
            }
        case .status(let status):
            streams.err("open-grok: \(status)\n")
        case .permissionRequested(let request):
            streams.err("open-grok: permission required: \(request.prompt)\n")
        case .cancelled:
            streams.err("open-grok: cancelled\n")
        case .lifecycle:
            break
        }
    }

    private func forwardJSON(_ event: OpenGrokPagerMinimalEvent) throws {
        switch event {
        case .output(let text):
            collectedOutput += text
        case .completed(let completion):
            streams.out(try Self.jsonLine([
                "type": "completed",
                "session_id": completion.sessionID as Any,
                "output": collectedOutput,
                "summary": completion.summary as Any
            ]))
        case .cancelled:
            streams.out(try Self.jsonLine(["type": "cancelled"]))
        case .lifecycle, .status, .permissionRequested:
            break
        }
    }

    private func forwardStreamingJSON(
        _ event: OpenGrokPagerMinimalEvent,
        messagesOnly: Bool
    ) throws {
        switch event {
        case .output(let text):
            collectedOutput += text
            streams.out(try Self.jsonLine([
                "type": messagesOnly ? "assistant" : "output",
                "content": text
            ]))
        case .status(let status) where !messagesOnly:
            streams.out(try Self.jsonLine(["type": "status", "status": status]))
        case .completed(let completion):
            streams.out(try Self.jsonLine([
                "type": "completed",
                "session_id": completion.sessionID as Any,
                "summary": completion.summary as Any
            ]))
        case .cancelled:
            streams.out(try Self.jsonLine(["type": "cancelled"]))
        case .permissionRequested(let request) where !messagesOnly:
            streams.out(try Self.jsonLine([
                "type": "permission_requested",
                "id": request.id,
                "prompt": request.prompt
            ]))
        case .lifecycle, .status, .permissionRequested:
            break
        }
    }

    private static func jsonLine(_ object: [String: Any]) throws -> String {
        let normalized = object.compactMapValues { value -> Any? in
            if value is NSNull { return value }
            let mirror = Mirror(reflecting: value)
            if mirror.displayStyle == .optional {
                return mirror.children.first?.value ?? NSNull()
            }
            return value
        }
        let data = try JSONSerialization.data(
            withJSONObject: normalized,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}

private actor UnavailableLiveShellProcessBackend: ShellProcessBackend {
    func run(_ request: ShellCommandRequest) async throws -> ShellCommandResult {
        throw ShellError.unsupported(capability: .processExecution, platform: "live Swift composition")
    }

    func runBackground(_ request: ShellCommandRequest) async throws -> ShellBackgroundHandle {
        throw ShellError.unsupported(capability: .processExecution, platform: "live Swift composition")
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
