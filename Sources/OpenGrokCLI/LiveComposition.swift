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
    public let items: [ConversationItem]
    public let tools: [ToolSpec]

    public init(
        sessionID: String,
        turnID: String,
        model: String,
        prompt: String,
        items: [ConversationItem]? = nil,
        tools: [ToolSpec] = []
    ) {
        self.sessionID = sessionID
        self.turnID = turnID
        self.model = model
        self.prompt = prompt
        self.items = items ?? [.user(prompt)]
        self.tools = tools
    }
}

public enum OpenGrokLiveSamplingEvent: Sendable, Equatable {
    case output(String)
    case status(String)
}

public struct OpenGrokLiveSamplingResponse: Sendable, Equatable {
    public let output: String
    public let stopReason: String?
    public let items: [ConversationItem]
    public let toolCalls: [ToolCall]

    public init(
        output: String,
        stopReason: String? = nil,
        items: [ConversationItem]? = nil,
        toolCalls: [ToolCall] = []
    ) {
        self.output = output
        self.stopReason = stopReason
        let resolvedItems = items ?? [.assistant(AssistantItem(
            content: output,
            toolCalls: toolCalls
        ))]
        self.items = resolvedItems
        if toolCalls.isEmpty {
            self.toolCalls = resolvedItems.reversed().compactMap { item in
                guard case .assistant(let assistant) = item else { return nil }
                return assistant.toolCalls
            }.first ?? []
        } else {
            self.toolCalls = toolCalls
        }
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
                items: request.items,
                tools: request.tools,
                toolChoice: request.tools.isEmpty ? nil : .auto,
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
                stopReason: response.stopReason?.asString,
                items: response.items,
                toolCalls: response.assistant()?.toolCalls ?? []
            )
        }
    }
}

public struct OpenGrokLiveCompositionDependencies: Sendable {
    public let makeSampler: @Sendable (OpenGrokLiveSamplingConfiguration) throws -> OpenGrokLiveSampler
    public let makeProcessBackend: @Sendable () -> any ShellProcessBackend
    public let terminal: OpenGrokLiveTerminal
    public let makeInteractiveInput: @Sendable () async throws -> OpenGrokLiveInteractiveInput?
    public let makeTerminalSink: @Sendable () -> (any PagerTerminalSink)?

    public init(
        makeSampler: @escaping @Sendable (OpenGrokLiveSamplingConfiguration) throws -> OpenGrokLiveSampler,
        makeProcessBackend: @escaping @Sendable () -> any ShellProcessBackend = {
            LocalShellProcessBackend()
        },
        terminal: OpenGrokLiveTerminal = .production,
        makeInteractiveInput: @escaping @Sendable () async throws -> OpenGrokLiveInteractiveInput? = { nil },
        makeTerminalSink: @escaping @Sendable () -> (any PagerTerminalSink)? = { nil }
    ) {
        self.makeSampler = makeSampler
        self.makeProcessBackend = makeProcessBackend
        self.terminal = terminal
        self.makeInteractiveInput = makeInteractiveInput
        self.makeTerminalSink = makeTerminalSink
    }

    public static let production = OpenGrokLiveCompositionDependencies(
        makeSampler: OpenGrokLiveSampler.production(configuration:),
        makeProcessBackend: { LocalShellProcessBackend() },
        terminal: .production,
        makeInteractiveInput: OpenGrokLiveInteractiveInput.production,
        makeTerminalSink: { FileHandlePagerTerminalSink() }
    )
}

public struct OpenGrokLiveInteractiveInput: Sendable {
    public let events: AsyncThrowingStream<InputEvent, Error>
    private let closeOperation: @Sendable () async -> Void

    public init(
        events: AsyncThrowingStream<InputEvent, Error>,
        close: @escaping @Sendable () async -> Void
    ) {
        self.events = events
        self.closeOperation = close
    }

    public func close() async {
        await closeOperation()
    }
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

extension OpenGrokLiveInteractiveInput {
    public static func production() async throws -> OpenGrokLiveInteractiveInput? {
        let inputTTY = PlatformTTYAdapter(fd: 0)
        guard inputTTY.isATTY() else { return nil }

        let lease = try await inputTTY.enterRawMode()
        let input: any TerminalInput
        do {
            input = try PlatformTerminalInput()
        } catch {
            await lease.release()
            throw error
        }

        var continuation: AsyncThrowingStream<InputEvent, Error>.Continuation!
        let events = AsyncThrowingStream<InputEvent, Error> { continuation = $0 }
        let emitter = LiveInteractiveInputEmitter(continuation: continuation)
        let resizeSource: any TerminalResizeSource = PlatformTerminalResizeMonitor(fd: 1)
        let resource = LiveInteractiveInputResource(
            input: input,
            resizeSource: resizeSource,
            lease: lease
        )
        let inputTask = Task {
            var pasteBuffer: String?
            do {
                while let event = try await input.readEvent() {
                    switch event {
                    case .pasteStart:
                        pasteBuffer = ""
                    case .pasteEnd:
                        if let pasteBuffer {
                            emitter.yield(.paste(pasteBuffer))
                        }
                        pasteBuffer = nil
                    case .text(let text):
                        if pasteBuffer != nil {
                            pasteBuffer?.append(text)
                        } else {
                            for character in text {
                                emitter.yield(.key(KeyEvent(
                                    key: .char(character),
                                    character: character
                                )))
                            }
                        }
                    default:
                        for translated in translate(event) {
                            emitter.yield(translated)
                        }
                    }
                }
                if let pasteBuffer, !pasteBuffer.isEmpty {
                    emitter.yield(.paste(pasteBuffer))
                }
                emitter.finish()
            } catch TerminalInputError.cancelled {
                emitter.finish()
            } catch TerminalInputError.closed {
                emitter.finish()
            } catch is CancellationError {
                emitter.finish()
            } catch {
                emitter.finish(throwing: error)
            }
        }
        let resizeTask = Task {
            for await size in resizeSource.events() {
                emitter.yield(.resize(OpenGrokTerminalCore.TerminalSize(
                    width: size.width,
                    height: size.height
                )))
            }
        }
        await resource.install(inputTask: inputTask, resizeTask: resizeTask)
        return OpenGrokLiveInteractiveInput(
            events: events,
            close: { await resource.close() }
        )
    }

    private static func translate(_ event: TerminalInputEvent) -> [InputEvent] {
        switch event {
        case .key(let key):
            return translate(key)
        case .control(let control):
            return [translate(control)]
        case .resize(let size):
            return [.resize(OpenGrokTerminalCore.TerminalSize(
                width: size.width,
                height: size.height
            ))]
        case .text, .pasteStart, .pasteEnd, .unknown:
            return []
        }
    }

    private static func translate(_ key: TerminalKey) -> [InputEvent] {
        switch key {
        case .character(let text, let modifiers):
            return text.map { character in
                .key(KeyEvent(
                    key: .char(character),
                    modifiers: translate(modifiers),
                    character: character
                ))
            }
        case .named(let named, let modifiers):
            let keyCode: KeyCode
            switch named {
            case .up: keyCode = .up
            case .down: keyCode = .down
            case .left: keyCode = .left
            case .right: keyCode = .right
            case .home: keyCode = .home
            case .end: keyCode = .end
            case .pageUp: keyCode = .pageUp
            case .pageDown: keyCode = .pageDown
            case .insert: keyCode = .insert
            case .delete: keyCode = .delete
            case .function(let number): keyCode = .f(number)
            }
            return [.key(KeyEvent(key: keyCode, modifiers: translate(modifiers)))]
        }
    }

    private static func translate(_ control: TerminalControlKey) -> InputEvent {
        switch control {
        case .null:
            return .key(KeyEvent(key: .null))
        case .character(let byte):
            let scalarValue = byte >= 1 && byte <= 26 ? Int(byte) + 96 : Int(byte)
            let character = Character(String(UnicodeScalar(scalarValue)!))
            return .key(KeyEvent(
                key: .char(character),
                modifiers: .control,
                character: character
            ))
        case .backspace, .delete:
            return .key(KeyEvent(key: .backspace))
        case .tab:
            return .key(KeyEvent(key: .tab))
        case .enter:
            return .key(KeyEvent(key: .enter))
        case .escape:
            return .key(KeyEvent(key: .escape))
        case .eof:
            return controlCharacter("d")
        case .interrupt:
            return controlCharacter("c")
        case .suspend:
            return controlCharacter("z")
        }
    }

    private static func controlCharacter(_ character: Character) -> InputEvent {
        .key(KeyEvent(
            key: .char(character),
            modifiers: .control,
            character: character
        ))
    }

    private static func translate(_ modifiers: TerminalKeyModifiers) -> KeyModifiers {
        var translated: KeyModifiers = []
        if modifiers.contains(.shift) { translated.insert(.shift) }
        if modifiers.contains(.control) { translated.insert(.control) }
        if modifiers.contains(.alt) { translated.insert(.alt) }
        if modifiers.contains(.meta) { translated.insert(.meta) }
        return translated
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

            let prompt = try Self.resolvePrompt(
                options,
                environment: context.environment,
                required: options.mode != .interactive
            )
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
            let processBackend = dependencies.makeProcessBackend()
            let toolExecutor = try await LiveToolExecutor(
                processBackend: processBackend,
                sessionID: sessionID,
                workingDirectory: cwd
            )
            let shell = OpenGrokShell(configuration: OpenGrokShellConfiguration(
                openGrokHome: openGrokHome,
                processBackend: processBackend,
                providerFactory: ProviderSessionFactoryAdapter(),
                turnDriver: ProviderSessionTurnDriver(
                    sampler: LiveShellSamplingDriver(
                        sampler: sampler,
                        toolExecutor: toolExecutor
                    )
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
                let interactiveInput = dependencies.terminal.isTTY()
                    ? try await dependencies.makeInteractiveInput()
                    : nil
                if let interactiveInput, let terminalSink = dependencies.makeTerminalSink() {
                    let renderer = LiveInteractiveControllerRenderer(
                        mode: pagerMode,
                        terminal: dependencies.terminal,
                        sink: terminalSink
                    )
                    let controller = OpenGrokPagerInteractiveController(
                        input: interactiveInput.events,
                        runtime: runtime,
                        renderer: renderer,
                        output: SilentLiveInteractiveOutput()
                    )
                    let request = OpenGrokPagerRequest(
                        prompt: prompt,
                        mode: pagerMode,
                        sessionID: sessionID,
                        metadata: ["mode": options.mode.rawValue]
                    )
                    let task = Task {
                        do {
                            let result: OpenGrokPagerInteractiveResult
                            if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                result = try await controller.run(request)
                            } else {
                                let initialSession = try await runtime.makeSession(for: request)
                                result = try await controller.run(
                                    initialSession: initialSession,
                                    request: request
                                )
                            }
                            await interactiveInput.close()
                            return result
                        } catch {
                            await interactiveInput.close()
                            throw error
                        }
                    }
                    return CLIApplicationSession(
                        waitForExit: {
                            _ = try await withTaskCancellationHandler {
                                try await task.value
                            } onCancel: {
                                task.cancel()
                            }
                        },
                        shutdown: {
                            task.cancel()
                            await controller.shutdown()
                            await interactiveInput.close()
                            _ = await shell.shutdown(timeout: ShellDuration(timeInterval: 1))
                            await toolExecutor.shutdown()
                        }
                    )
                }
                if let interactiveInput {
                    await interactiveInput.close()
                }
                guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CLIApplicationError.failed("interactive mode requires terminal input or a prompt")
                }
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
                        _ = try await withTaskCancellationHandler {
                            try await task.value
                        } onCancel: {
                            task.cancel()
                        }
                    },
                    shutdown: {
                        task.cancel()
                        await pager.shutdown()
                        _ = await shell.shutdown(timeout: ShellDuration(timeInterval: 1))
                        await toolExecutor.shutdown()
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
                        _ = try await withTaskCancellationHandler {
                            try await task.value
                        } onCancel: {
                            task.cancel()
                        }
                    },
                    shutdown: {
                        task.cancel()
                        await pager.shutdown()
                        _ = await shell.shutdown(timeout: ShellDuration(timeInterval: 1))
                        await toolExecutor.shutdown()
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
        environment: [String: String],
        required: Bool = true
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
        } else if !required {
            return ""
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

private struct LiveToolExecutor: Sendable {
    let tools: [ToolSpec]
    let workingDirectory: URL
    private let composition: OpenGrokShellToolRuntimeComposition

    init(
        processBackend: any ShellProcessBackend,
        sessionID: String,
        workingDirectory: URL
    ) async throws {
        let composition = OpenGrokShellToolRuntimeComposition(
            processBackend: processBackend,
            runtime: LiveRunTerminalToolRuntime()
        )
        try await composition.registerSession(
            sessionID: sessionID,
            workingDirectory: workingDirectory
        )
        self.composition = composition
        self.workingDirectory = workingDirectory.standardizedFileURL
        self.tools = [Self.runTerminalTool]
    }

    func invoke(
        sessionID: String,
        workingDirectory: URL,
        call: ToolCall
    ) async -> Result<OpenGrokShellToolCallResult, OpenGrokShellToolRuntimeError> {
        let args: JSONValue
        do {
            args = try JSONDecoder().decode(
                JSONValue.self,
                from: Data(call.arguments.utf8)
            )
        } catch {
            return .failure(.invalidCall(
                "tool arguments are not valid JSON: \(error)"
            ))
        }

        do {
            return try await composition.invoke(
                sessionID: sessionID,
                workingDirectory: workingDirectory,
                name: call.name,
                args: args,
                callID: call.callId
            )
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(.failed(String(describing: error)))
        }
    }

    func shutdown() async {
        await composition.shutdown()
    }

    private static let runTerminalTool = ToolSpec(
        name: "run_terminal_cmd",
        description: "Run a validated shell command in the workspace with bounded output and cancellable process cleanup.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "description": .string("Shell command to execute.")
                ]),
                "timeout_ms": .object([
                    "type": .string("integer"),
                    "description": .string("Optional timeout in milliseconds.")
                ]),
                "description": .object([
                    "type": .string("string"),
                    "description": .string("Short explanation of the command.")
                ]),
                "is_background": .object([
                    "type": .string("boolean"),
                    "description": .string("Run as a background task.")
                ])
            ]),
            "required": .array([.string("command")]),
            "additionalProperties": .bool(false)
        ])
    )
}

private struct LiveRunTerminalToolRuntime: OpenGrokShellToolRuntime, Sendable {
    func invoke(
        _ call: OpenGrokShellToolCall,
        using process: any OpenGrokShellProcessExecution
    ) async -> Result<OpenGrokShellToolCallResult, OpenGrokShellToolRuntimeError> {
        guard call.name == "run_terminal_cmd" else {
            return .failure(.unsupported("unknown tool '\(call.name)'"))
        }
        guard case .object(let object) = call.args,
              case .string(let command)? = object["command"],
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .failure(.invalidCall("run_terminal_cmd requires a non-empty command"))
        }

        let timeoutMilliseconds = Self.integer(object["timeout_ms"])
            .map { max(1, min(3_600_000, $0)) }
            ?? 30_000
        let outputByteLimit = Self.integer(object["output_byte_limit"])
            .map { max(1, min(1_000_000, $0)) }
            ?? 30_000
        let isBackground = Self.boolean(object["is_background"]) ?? false
        let description = Self.string(object["description"])
        let environment = Self.stringDictionary(object["environment"])
        let request = ShellCommandRequest(
            command: command,
            workingDirectory: process.workingDirectory,
            environment: environment,
            timeout: .milliseconds(Int64(timeoutMilliseconds)),
            outputByteLimit: outputByteLimit,
            toolCallID: call.callID,
            autoBackgroundOnTimeout: true,
            foregroundBlockBudget: .seconds(10),
            ownerSessionID: call.sessionID,
            description: description
        )

        do {
            if isBackground {
                let handle = try await process.runBackground(request)
                let value: JSONValue = .object([
                    "type": .string("background"),
                    "task_id": .string(handle.taskID),
                    "output_file": handle.outputFile.map {
                        .string($0.path)
                    } ?? .null,
                    "pid": handle.processID.map {
                        .number(.int64(Int64($0)))
                    } ?? .null
                ])
                return .success(OpenGrokShellToolCallResult(
                    value: value,
                    promptText: "Background task \(handle.taskID) started."
                ))
            }

            let result = try await process.run(request)
            let value: JSONValue = .object([
                "type": .string(result.backgrounded ? "backgrounded" : "foreground"),
                "combined_output": .string(result.combinedOutput),
                "exit_code": result.exitCode.map {
                    .number(.int64(Int64($0)))
                } ?? .null,
                "signal": result.signal.map(JSONValue.string) ?? .null,
                "truncated": .bool(result.truncated),
                "timed_out": .bool(result.timedOut),
                "cancelled": .bool(result.cancelled),
                "output_file": result.outputFile.map {
                    .string($0.path)
                } ?? .null,
                "total_bytes": .number(.int64(Int64(result.totalBytes))),
                "pid": result.processID.map {
                    .number(.int64(Int64($0)))
                } ?? .null,
                "task_id": result.taskID.map(JSONValue.string) ?? .null
            ])
            return .success(OpenGrokShellToolCallResult(
                value: value,
                promptText: Self.promptText(for: result)
            ))
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(.failed(String(describing: error)))
        }
    }

    func cancel(_ call: OpenGrokShellToolCall) async {
        _ = call
    }

    private static func integer(_ value: JSONValue?) -> Int? {
        guard let value else { return nil }
        switch value {
        case .number(let number):
            if let integer = number.int64Value {
                return Int(exactly: integer)
            }
            if let integer = number.uint64Value {
                return Int(exactly: integer)
            }
            return nil
        case .string(let string):
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private static func boolean(_ value: JSONValue?) -> Bool? {
        guard let value else { return nil }
        switch value {
        case .bool(let boolean):
            return boolean
        case .string(let string):
            switch string.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        default:
            return nil
        }
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let string)? = value else { return nil }
        return string
    }

    private static func stringDictionary(_ value: JSONValue?) -> [String: String] {
        guard case .object(let object)? = value else { return [:] }
        return object.reduce(into: [:]) { result, entry in
            if case .string(let value) = entry.value {
                result[entry.key] = value
            }
        }
    }

    private static func promptText(for result: ShellCommandResult) -> String {
        var lines: [String] = []
        if !result.combinedOutput.isEmpty {
            lines.append(result.combinedOutput)
        } else {
            lines.append("(command produced no output)")
        }
        if let exitCode = result.exitCode {
            lines.append("Exit code: \(exitCode)")
        }
        if let signal = result.signal {
            lines.append("Signal: \(signal)")
        }
        if result.timedOut {
            lines.append("The command timed out.")
        }
        if result.cancelled {
            lines.append("The command was cancelled.")
        }
        if result.truncated {
            lines.append("Output was truncated; full output: \(result.outputFile?.path ?? "unavailable")")
        }
        if let taskID = result.taskID {
            lines.append("Background task: \(taskID)")
        }
        return lines.joined(separator: "\n")
    }
}

private struct LiveShellSamplingDriver: OpenGrokShellSamplingDriver, Sendable {
    let sampler: OpenGrokLiveSampler
    let toolExecutor: LiveToolExecutor

    func sample(
        context: OpenGrokShellProviderTurnContext,
        request: OpenGrokShellTurnRequest,
        emit: @escaping @Sendable (OpenGrokShellTurnUpdateKind) async -> Void
    ) async throws -> OpenGrokShellSamplingResult {
        var items: [ConversationItem] = [.user(request.text)]
        var toolRoundCount = 0

        while true {
            try Task.checkCancellation()
            let response = try await sampler.sample(OpenGrokLiveSamplingRequest(
                sessionID: context.sessionID,
                turnID: context.turnID,
                model: context.modelID,
                prompt: request.text,
                items: items,
                tools: toolExecutor.tools
            )) { event in
                switch event {
                case .output(let text):
                    await emit(.assistantText(text))
                case .status(let status):
                    await emit(.status(status))
                }
            }
            items.append(contentsOf: response.items)

            guard !response.toolCalls.isEmpty else {
                return OpenGrokShellSamplingResult(
                    output: response.output,
                    stopReason: response.stopReason
                )
            }
            guard toolRoundCount < 16 else {
                throw CLIApplicationError.failed(
                    "tool loop exceeded 16 rounds"
                )
            }
            toolRoundCount += 1

            for call in response.toolCalls {
                try Task.checkCancellation()
                await emit(.status("running tool \(call.name)"))
                let result = await toolExecutor.invoke(
                    sessionID: context.sessionID,
                    workingDirectory: toolExecutorWorkingDirectory,
                    call: call
                )
                let content: String
                switch result {
                case .success(let result):
                    content = result.promptText
                    await emit(.status("tool \(call.name) completed"))
                case .failure(.cancelled):
                    throw CancellationError()
                case .failure(let error):
                    content = "Tool \(call.name) failed: \(error.description)"
                    await emit(.status("tool \(call.name) failed"))
                }
                items.append(.toolResult(ToolResultItem(
                    toolCallId: call.callId,
                    content: content
                )))
            }
        }
    }

    private var toolExecutorWorkingDirectory: URL {
        toolExecutor.workingDirectory
    }
}

private actor LivePagerRuntimeAdapter: OpenGrokPagerMinimalRuntimeAdapter, OpenGrokPagerRuntimeAdapter {
    let shell: OpenGrokShell
    let cwd: URL
    let providerConfiguration: ProviderSessionConfiguration
    private var createdSessionID: SessionID?

    init(
        shell: OpenGrokShell,
        cwd: URL,
        providerConfiguration: ProviderSessionConfiguration
    ) {
        self.shell = shell
        self.cwd = cwd
        self.providerConfiguration = providerConfiguration
    }

    func makeSession(
        for request: OpenGrokPagerMinimalRequest
    ) async throws -> any OpenGrokPagerMinimalSessionAdapter {
        _ = try await shell.start()
        let shellEvents = await shell.events()
        let sessionID = SessionID(request.sessionID ?? providerConfiguration.sessionID)
        if let createdSessionID {
            guard createdSessionID == sessionID else {
                throw CLIApplicationError.failed("interactive runtime cannot switch session IDs")
            }
        } else {
            _ = try await shell.createSession(OpenGrokShellSessionRequest(
                sessionID: sessionID,
                cwd: cwd,
                providerConfiguration: providerConfiguration,
                restorePersistedState: false
            ))
            createdSessionID = sessionID
        }
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
    }
}

private actor LiveInteractiveInputResource {
    private let input: any TerminalInput
    private let resizeSource: any TerminalResizeSource
    private let lease: any RawModeLease
    private var inputTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var closed = false

    init(
        input: any TerminalInput,
        resizeSource: any TerminalResizeSource,
        lease: any RawModeLease
    ) {
        self.input = input
        self.resizeSource = resizeSource
        self.lease = lease
    }

    func install(
        inputTask: Task<Void, Never>,
        resizeTask: Task<Void, Never>
    ) {
        self.inputTask = inputTask
        self.resizeTask = resizeTask
    }

    func close() async {
        guard !closed else { return }
        closed = true
        await input.close()
        resizeSource.stop()
        inputTask?.cancel()
        resizeTask?.cancel()
        if let inputTask {
            _ = await inputTask.value
        }
        if let resizeTask {
            _ = await resizeTask.value
        }
        await lease.release()
    }
}

private final class LiveInteractiveInputEmitter: @unchecked Sendable {
    private let continuation: AsyncThrowingStream<InputEvent, Error>.Continuation

    init(continuation: AsyncThrowingStream<InputEvent, Error>.Continuation) {
        self.continuation = continuation
    }

    func yield(_ event: InputEvent) {
        continuation.yield(event)
    }

    func finish(throwing error: Error? = nil) {
        continuation.finish(throwing: error)
    }
}

private final class FileHandlePagerTerminalSink: PagerTerminalSink, @unchecked Sendable {
    let capabilities = PagerTerminalCapabilities.standard
    private let handle: FileHandle
    private let lock = NSLock()

    init(handle: FileHandle = .standardOutput) {
        self.handle = handle
    }

    func write(bytes: [UInt8]) throws {
        guard !bytes.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        try handle.write(contentsOf: Data(bytes))
    }

    func flush() throws {
        lock.lock()
        defer { lock.unlock() }
        try handle.synchronize()
    }
}

private actor LiveInteractiveControllerRenderer: OpenGrokPagerInteractiveRenderAdapter {
    private let mode: OpenGrokPagerMode
    private let terminal: OpenGrokLiveTerminal
    private let sink: any PagerTerminalSink
    private let renderer: PagerTerminalRenderer

    private var conversation: [PagerConversationItem] = []
    private var prompt = OpenGrokPagerInteractivePromptState()
    private var status = PagerStatusLine(text: "Starting")
    private var activeAssistantIndex: Int?
    private var restored = false

    init(
        mode: OpenGrokPagerMode,
        terminal: OpenGrokLiveTerminal,
        sink: any PagerTerminalSink
    ) {
        self.mode = mode
        self.terminal = terminal
        self.sink = sink
        let terminalHeight = terminal.size()?.height ?? 12
        self.renderer = PagerTerminalRenderer(
            sink: sink,
            configuration: PagerTerminalRendererConfiguration(
                mode: mode == .fullScreen
                    ? .fullscreen
                    : .inline(height: max(1, min(12, terminalHeight))),
                useAlternateScreen: mode == .fullScreen,
                useSynchronizedOutput: true
            )
        )
    }

    func begin() async throws {
        try renderer.start()
        try renderState()
    }

    func render(_ event: OpenGrokPagerInteractiveEvent) async throws {
        switch event {
        case .lifecycle(let lifecycle):
            status = PagerStatusLine(
                text: lifecycle.rawValue.capitalized,
                isStreaming: lifecycle == .running
            )
        case .promptChanged(let prompt):
            self.prompt = prompt
        case .turnStarted(let request):
            conversation.append(.message(PagerMessage(role: .user, text: request.prompt)))
            conversation.append(.message(PagerMessage(
                role: .assistant,
                text: "",
                isStreaming: true
            )))
            activeAssistantIndex = conversation.indices.last
            status = PagerStatusLine(text: "Thinking", isStreaming: true)
        case .session(let event):
            apply(event)
        case .turnFinished(let result):
            finishAssistant()
            status = PagerStatusLine(text: result.lifecycle.rawValue.capitalized)
        case .notice(let message):
            status = PagerStatusLine(text: message)
        case .eof:
            status = PagerStatusLine(text: "End of input")
        case .cancelled:
            finishAssistant()
            status = PagerStatusLine(text: "Cancelled")
        case .failed(let message):
            finishAssistant()
            conversation.append(.message(PagerMessage(role: .error, text: message)))
            status = PagerStatusLine(text: "Failed")
        case .shutdown:
            status = PagerStatusLine(text: "Shutdown")
        }
        try renderState()
    }

    func restoreTerminal() async throws {
        guard !restored else { return }
        restored = true
        try renderer.restore()
        if mode == .fullScreen {
            try sink.write(transcript)
            try sink.flush()
        }
    }

    private func apply(_ event: OpenGrokPagerEvent) {
        switch event {
        case .lifecycle(let lifecycle):
            status = PagerStatusLine(
                text: lifecycle.rawValue.capitalized,
                isStreaming: lifecycle == .running
            )
        case .output(let text):
            appendAssistant(text)
            status = PagerStatusLine(text: "Responding", isStreaming: true)
        case .status(let text):
            status = PagerStatusLine(text: text, isStreaming: true)
        case .permissionRequested(let request):
            status = PagerStatusLine(
                text: "Permission required",
                detail: request.prompt
            )
        case .completed:
            finishAssistant()
            status = PagerStatusLine(text: "Completed")
        case .cancelled:
            finishAssistant()
            status = PagerStatusLine(text: "Cancelled")
        }
    }

    private func appendAssistant(_ text: String) {
        guard let activeAssistantIndex,
              conversation.indices.contains(activeAssistantIndex),
              case .message(var message) = conversation[activeAssistantIndex]
        else { return }
        message.text += text
        message.isStreaming = true
        conversation[activeAssistantIndex] = .message(message)
    }

    private func finishAssistant() {
        guard let activeAssistantIndex,
              conversation.indices.contains(activeAssistantIndex),
              case .message(var message) = conversation[activeAssistantIndex]
        else { return }
        message.isStreaming = false
        conversation[activeAssistantIndex] = .message(message)
        self.activeAssistantIndex = nil
    }

    private func renderState() throws {
        let size = terminal.size() ?? OpenGrokLiveTerminalSize(width: 80, height: 24)
        try renderer.render(PagerRenderState(
            size: OpenGrokTerminalCore.TerminalSize(
                width: size.width,
                height: size.height
            ),
            header: PagerHeader(title: "Open Grok", subtitle: "Interactive"),
            conversation: conversation,
            status: status,
            input: PagerInputState(
                text: prompt.text,
                cursorCharacterOffset: prompt.cursorOffset,
                isFocused: true,
                cursorVisible: true,
                maximumHeight: 4
            ),
            footer: PagerFooter(
                leading: "Enter send · Ctrl-C cancel · Ctrl-D exit",
                trailing: "Swift port"
            )
        ))
    }

    private var transcript: String {
        var lines: [String] = []
        for item in conversation {
            guard case .message(let message) = item else { continue }
            let label: String
            switch message.role {
            case .user: label = "You"
            case .assistant: label = "Grok"
            case .system: label = "System"
            case .reasoning: label = "Reasoning"
            case .error: label = "Error"
            }
            lines.append("\(label): \(message.text)")
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }
}

private struct SilentLiveInteractiveOutput: OpenGrokPagerInteractiveOutputAdapter, Sendable {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws {
        _ = event
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
