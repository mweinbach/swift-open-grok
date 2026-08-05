import Foundation
import OpenGrokAgentDefinitions
import OpenGrokAuth
import OpenGrokFileTools
import OpenGrokHTTP
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
import OpenGrokToolRegistry
import OpenGrokTTY
import OpenGrokWorkspace

public struct OpenGrokLiveSamplingConfiguration: Sendable, Equatable {
    public let model: String
    public let baseURL: String
    public let apiKey: String
    public let provider: ModelProvider
    public let apiBackend: ApiBackend
    /// Provider headers that travel with every sampling request — Codex OAuth
    /// account pinning (`ChatGPT-Account-ID`, `X-OpenAI-Fedramp`) arrives here.
    public let extraHeaders: [String: String]

    public init(
        model: String,
        baseURL: String,
        apiKey: String,
        provider: ModelProvider = .xai,
        apiBackend: ApiBackend = .chatCompletions,
        extraHeaders: [String: String] = [:]
    ) {
        self.model = model
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.provider = provider
        self.apiBackend = apiBackend
        self.extraHeaders = extraHeaders
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
            self.toolCalls = resolvedItems.reversed().compactMap { item -> [ToolCall]? in
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
            provider: configuration.provider,
            extraHeaders: configuration.extraHeaders
                .sorted { $0.key < $1.key }
                .map { (name: $0.key, value: $0.value) }
        ))
        return OpenGrokLiveSampler { request, emit in
            await emit(.status("sampling"))
            // Assistant text is forwarded incrementally as it arrives; the
            // collected response carries the same bytes, so nothing is emitted
            // again once the turn completes.
            let response = try await client.streamConversation(ConversationRequest(
                items: request.items,
                tools: request.tools,
                toolChoice: request.tools.isEmpty ? nil : .auto,
                model: request.model,
                xGrokReqId: request.turnID,
                xGrokSessionId: request.sessionID
            )) { delta in
                await emit(.output(delta))
            }
            let output = response.assistantText()
            return OpenGrokLiveSamplingResponse(
                output: output,
                stopReason: response.stopReason?.asString,
                items: response.items,
                toolCalls: response.assistant()?.toolCalls ?? []
            )
        }
    }
}

extension SamplingClient {
    /// Run one turn over the backend's streaming API, forwarding assistant text
    /// deltas as they arrive.
    ///
    /// The returned response is the same value ``conversationCollect`` would
    /// have produced — both drain the identical layer-2 event stream and read
    /// the terminal `completed` event — so persisted history is unaffected by
    /// streaming. Cancellation propagates through the underlying `AsyncStream`,
    /// which tears down the in-flight HTTP request on termination.
    fileprivate func streamConversation(
        _ request: ConversationRequest,
        requestId: RequestId = .random(),
        idleTimeout: MonotonicDuration = .seconds(300),
        onTextDelta: @escaping @Sendable (String) async -> Void
    ) async throws -> ConversationResponse {
        let events: AsyncStream<SamplingEvent>
        switch apiBackend {
        case .chatCompletions:
            let (raw, metadata) = try await conversationStream(request)
            events = streamChatCompletions(
                rawStream: raw,
                modelMetadata: metadata,
                requestId: requestId,
                idleTimeout: idleTimeout
            )
        case .responses:
            let (raw, metadata, doomLoop, customToolNames) =
                try await conversationStreamResponses(request)
            events = streamResponsesWithClientCustomTools(
                rawStream: raw,
                modelMetadata: metadata,
                requestId: requestId,
                idleTimeout: idleTimeout,
                doomLoop: doomLoop,
                clientCustomToolNames: customToolNames
            )
        case .messages:
            let (raw, metadata) = try await conversationStreamMessages(request)
            events = streamMessages(
                rawStream: raw,
                modelMetadata: metadata,
                requestId: requestId,
                idleTimeout: idleTimeout
            )
        }

        var coalescer = LiveTextDeltaCoalescer()
        for await event in events {
            try Task.checkCancellation()
            switch event {
            case .channelToken(_, .text, let text, _):
                if let batch = coalescer.push(text) {
                    await onTextDelta(batch)
                }
            case .completed(_, let response, _):
                if let batch = coalescer.flush() {
                    await onTextDelta(batch)
                }
                return response
            case .failed(_, let error):
                throw CLIApplicationError.failed(error.message)
            default:
                continue
            }
        }
        try Task.checkCancellation()
        throw CLIApplicationError.failed("sampling stream ended without a response")
    }
}

/// Batches assistant text deltas so a fast token stream does not force one
/// repaint per token.
///
/// The first delta is released immediately — the pane should show the answer
/// starting, not a blank pause — and later deltas accumulate until the interval
/// elapses. Released batches concatenate to exactly the tokens pushed, so
/// coalescing never changes the text the pane or a headless stream observes.
struct LiveTextDeltaCoalescer {
    private let interval: MonotonicDuration

    private var pending = ""
    // Module-qualified: `OpenGrokHTTP` declares its own `MonotonicInstant`.
    private var lastRelease: OpenGrokSampler.MonotonicInstant?

    init(interval: MonotonicDuration = .milliseconds(50)) {
        self.interval = interval
    }

    mutating func push(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        pending += text
        let now = OpenGrokSampler.MonotonicInstant.now
        guard let lastRelease else {
            self.lastRelease = now
            return take()
        }
        guard interval < now - lastRelease else { return nil }
        self.lastRelease = now
        return take()
    }

    mutating func flush() -> String? {
        take()
    }

    private mutating func take() -> String? {
        guard !pending.isEmpty else { return nil }
        defer { pending = "" }
        return pending
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
        case .unknown(let data):
            // `TerminalInputDecoder` has no mouse handling: an SGR report
            // (`ESC [ < b ; x ; y M|m`) terminates on its final byte, falls
            // through the CSI switch and arrives here intact, so decoding it
            // recovers the event without a new module dependency. Legacy X10
            // is *not* recoverable this way — that parser treats `ESC [ M` as a
            // complete CSI and the three coordinate bytes leak as text — which
            // is why the driver enables `?1006h` last, making SGR the mode any
            // terminal that understands it will use.
            guard case .event(let mouse) = MouseReportDecoder.decode(Array(data)) else {
                return []
            }
            return [.mouse(mouse)]
        case .text, .pasteStart, .pasteEnd:
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
            if LiveAuthComposition.handles(command) {
                return try await LiveAuthComposition.session(for: command, context: context)
            }
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
            let agentProfile = try Self.resolveAgentProfile(
                named: options.common.profile,
                workingDirectory: cwd,
                environment: context.environment
            )
            let openGrokHome = Self.resolveOpenGrokHome(environment: context.environment)
            let conversationStore = LiveConversationStore(openGrokHome: openGrokHome)
            let conversationRecord = try await Self.resolveConversationRecord(
                options: options,
                workingDirectory: cwd,
                store: conversationStore
            )
            let sessionID = conversationRecord.sessionID
            let (samplingConfiguration, credential) = try await Self.resolveSamplingConfiguration(
                options: options,
                profileModel: agentProfile?.model,
                environment: context.environment,
                openGrokHome: openGrokHome,
                sessionID: sessionID
            )
            let sampler = try dependencies.makeSampler(samplingConfiguration)
            let providerConfiguration = Self.makeProviderConfiguration(
                sessionID: sessionID,
                sampling: samplingConfiguration,
                credential: credential,
                openGrokHome: openGrokHome,
                environment: context.environment
            )
            let processBackend = dependencies.makeProcessBackend()
            // The coordinator is created unconditionally and gates on whether a
            // presenter ever attaches, so headless and non-TTY runs keep the
            // fail-closed denial without a second construction path.
            let permissionCoordinator = PagerPermissionCoordinator()
            let toolExecutor = try await LiveToolExecutor(
                processBackend: processBackend,
                sessionID: sessionID,
                workingDirectory: cwd,
                toolPolicy: agentProfile?.toolPolicy,
                fileAccessPolicy: Self.resolveFileAccessPolicy(
                    environment: context.environment,
                    coordinator: permissionCoordinator
                )
            )
            // Code Mode is a session-wide decision: the tool surface it
            // projects is fixed for the life of the timeline, which is what
            // makes a `wait` after a yield resolvable.
            let toolMode = LiveCodeModeSettings.resolveToolMode(
                environment: context.environment,
                workingDirectory: cwd,
                openGrokHome: openGrokHome
            )
            let toolSurface = LiveCodeModeToolSurface(
                mode: toolMode,
                baseTools: toolExecutor.tools
            )
            let codeMode = toolSurface.isCodeMode
                ? LiveCodeModeCoordinator(
                    surface: toolSurface,
                    toolExecutor: toolExecutor,
                    sessionID: sessionID,
                    workingDirectory: cwd
                )
                : nil
            let conversationHistory = LiveConversationHistory(
                record: conversationRecord,
                store: conversationStore
            )
            // `/model` rebuilds the provider stack through this coordinator; the
            // shell, session and tool runtime below are provider-independent and
            // survive a switch untouched.
            let modelSwitch = LiveModelSwitchCoordinator(
                sampling: samplingConfiguration,
                sampler: sampler,
                resolver: LiveModelCatalogResolver(
                    environment: context.environment,
                    openGrokHome: openGrokHome,
                    sessionID: sessionID
                ),
                makeSampler: dependencies.makeSampler,
                history: conversationHistory
            )
            // A provider change invalidates the cells and stored values the
            // old runtime holds (model_switch.rs:249).
            await modelSwitch.attachCodeMode(codeMode)
            let shell = OpenGrokShell(configuration: OpenGrokShellConfiguration(
                openGrokHome: openGrokHome,
                processBackend: processBackend,
                providerFactory: ProviderSessionFactoryAdapter(),
                turnDriver: ProviderSessionTurnDriver(
                    sampler: LiveShellSamplingDriver(
                        modelSwitch: modelSwitch,
                        toolExecutor: toolExecutor,
                        conversationHistory: conversationHistory,
                        systemPrompt: agentProfile?.systemPrompt,
                        toolSurface: toolSurface,
                        codeMode: codeMode
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
                        sink: terminalSink,
                        workingDirectory: cwd.path,
                        modelName: providerConfiguration.initialModelID,
                        // The picker lists the whole embedded catalog, not just
                        // the model this session started on — otherwise `/model`
                        // offers exactly one row, the current one.
                        modelCatalog: LiveModelCatalogResolver.catalog(),
                        modelSwitch: modelSwitch,
                        permissionCoordinator: permissionCoordinator,
                        terminalProgram: context.environment["TERM_PROGRAM"]
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
                            await codeMode?.shutdown()
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
                        await codeMode?.shutdown()
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
                        await codeMode?.shutdown()
                        await toolExecutor.shutdown()
                    }
                )
            }
        }
    }

    private static func validateUnsupportedOptions(_ options: CLIExecutionOptions) throws {
        if !options.common.pluginDirectories.isEmpty {
            throw CLIApplicationError.unsupported(route: "plugins")
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

    private static func resolveConversationRecord(
        options: CLIExecutionOptions,
        workingDirectory: URL,
        store: LiveConversationStore
    ) async throws -> LiveConversationRecord {
        if options.continueSession, options.resume != nil {
            throw CLIApplicationError.failed("--resume and --continue cannot be used together")
        }

        let requestedResumeID = options.resume?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceRecord: LiveConversationRecord?
        if let requestedResumeID, !requestedResumeID.isEmpty {
            sourceRecord = try await store.load(sessionID: requestedResumeID)
        } else if options.resume != nil || options.continueSession || options.forkSession {
            sourceRecord = try await store.latest(workingDirectory: workingDirectory)
        } else {
            sourceRecord = nil
        }

        if options.forkSession {
            guard let sourceRecord else {
                throw CLIApplicationError.failed("no session is available to fork")
            }
            let destinationID = options.sessionID ?? UUID().uuidString
            try LiveConversationStore.validateSessionID(destinationID)
            guard destinationID != sourceRecord.sessionID else {
                throw CLIApplicationError.failed("forked session ID must differ from the source session")
            }
            if try await store.loadIfPresent(sessionID: destinationID) != nil {
                throw CLIApplicationError.failed("session already exists: \(destinationID)")
            }
            return LiveConversationRecord(
                sessionID: destinationID,
                workingDirectory: workingDirectory.standardizedFileURL.path,
                parentSessionID: sourceRecord.sessionID,
                createdAt: Date(),
                updatedAt: Date(),
                items: sourceRecord.items
            )
        }

        if var sourceRecord {
            if let requestedSessionID = options.sessionID,
               requestedSessionID != sourceRecord.sessionID {
                throw CLIApplicationError.failed(
                    "--session-id requires --fork-session when restoring a different session"
                )
            }
            sourceRecord.workingDirectory = workingDirectory.standardizedFileURL.path
            return sourceRecord
        }

        if let requestedSessionID = options.sessionID {
            try LiveConversationStore.validateSessionID(requestedSessionID)
            if var existing = try await store.loadIfPresent(sessionID: requestedSessionID) {
                existing.workingDirectory = workingDirectory.standardizedFileURL.path
                return existing
            }
            return LiveConversationRecord.new(
                sessionID: requestedSessionID,
                workingDirectory: workingDirectory
            )
        }

        return LiveConversationRecord.new(
            sessionID: UUID().uuidString,
            workingDirectory: workingDirectory
        )
    }

    private static func resolveSamplingConfiguration(
        options: CLIExecutionOptions,
        profileModel: String?,
        environment: [String: String],
        openGrokHome: URL,
        sessionID: String
    ) async throws -> (OpenGrokLiveSamplingConfiguration, LiveResolvedCredential) {
        let requestedProvider = try options.common.provider.map(resolveProvider)
        let embedded = embeddedDefaultModels()
        let requestedModel = options.common.model ?? profileModel
        let knownModel = requestedModel.flatMap { requested in
            embedded.models.first { model in
                (model.id ?? model.model) == requested || model.model == requested
            }
        }
        if let requestedProvider, let knownModel, knownModel.provider != requestedProvider {
            throw CLIApplicationError.failed(
                "model '\(requestedModel ?? knownModel.model)' belongs to provider \(knownModel.provider.asString), not \(requestedProvider.asString)"
            )
        }

        let provider = requestedProvider ?? knownModel?.provider ?? .xai
        let selectedModel = try knownModel ?? defaultModelProfile(
            provider: provider,
            embedded: embedded,
            environment: environment
        )
        let selectedProfile = requestedModel == nil || knownModel != nil
            ? selectedModel
            : nil
        let model = knownModel == nil
            ? (requestedModel ?? selectedModel.model)
            : selectedModel.model
        let apiBackend = selectedProfile?.apiBackend ?? defaultBackend(provider: provider)
        guard provider.profile.supportsBackend(apiBackend) else {
            throw CLIApplicationError.failed(
                "provider \(provider.asString) does not support \(apiBackend.rawValue)"
            )
        }
        let baseURL = resolveProviderBaseURL(
            provider: provider,
            model: selectedProfile,
            environment: environment
        )
        if provider == .kimi,
           let modelBaseURL = selectedProfile?.baseURL,
           let modelEndpoint = KimiModels.endpoint(forBaseURL: modelBaseURL),
           let resolvedEndpoint = KimiModels.endpoint(forBaseURL: baseURL),
           modelEndpoint != resolvedEndpoint {
            throw CLIApplicationError.failed(
                "Kimi model '\(model)' cannot use endpoint \(baseURL)"
            )
        }
        // Explicit model/provider environment keys still resolve exactly as
        // before; they are the resolver's highest-precedence input.
        let explicitAPIKey = try resolveProviderAPIKey(
            provider: provider,
            model: selectedProfile,
            baseURL: baseURL,
            environment: environment
        )
        let resolver = LiveCredentialResolver(
            environment: environment,
            openGrokHome: openGrokHome,
            codexRefreshService: .live(
                endpoints: CodexEndpoints.fromEnvironment(environment),
                transport: URLSessionHTTPTransport()
            )
        )
        let credential: LiveResolvedCredential
        do {
            credential = try await resolver.resolve(
                provider: provider,
                explicitAPIKey: explicitAPIKey,
                scope: "cli:\(sessionID)"
            )
        } catch let error as LiveCredentialError {
            throw CLIApplicationError.failed(error.description)
        }
        let sampling = OpenGrokLiveSamplingConfiguration(
            model: model,
            baseURL: baseURL,
            apiKey: credential.bearer,
            provider: provider,
            apiBackend: apiBackend,
            extraHeaders: credential.extraHeaders
        )
        return (sampling, credential)
    }

    private static func resolveAgentProfile(
        named name: String?,
        workingDirectory: URL,
        environment: [String: String]
    ) throws -> LiveAgentProfile? {
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        guard let definition = AgentDefinition.byName(
            name,
            in: workingDirectory,
            environment: environment
        ) else {
            throw CLIApplicationError.failed("agent profile '\(name)' was not found")
        }
        let instructionFiles = definition.agentsMd
            ? AgentInstructionDiscovery(environment: environment).discover(at: workingDirectory)
            : []
        let composedPrompt = definition.composePrompt(
            basePrompt: "",
            agentsMdFiles: instructionFiles
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return LiveAgentProfile(
            model: definition.model.modelID,
            systemPrompt: composedPrompt.isEmpty ? nil : composedPrompt,
            toolPolicy: LiveAgentToolPolicy(definition: definition)
        )
    }

    private static func resolveProvider(_ value: String) throws -> ModelProvider {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "xai", "grok":
            return .xai
        case "codex", "openai", "openai_codex":
            return .codex
        case "kimi", "moonshot", "moonshot_ai":
            return .kimi
        case "fireworks", "fireworks_ai":
            return .fireworks
        default:
            throw CLIApplicationError.unsupported(route: "provider \(value)")
        }
    }

    private static func defaultModelProfile(
        provider: ModelProvider,
        embedded: EmbeddedDefaultModels,
        environment: [String: String]
    ) throws -> DefaultModelJSON {
        // Reject an unroutable override before it can silently fall back to
        // the other Kimi service's catalog.
        if provider == .kimi,
           let override = nonEmptyEnvironmentValue(KimiModels.apiBaseURLEnv, environment: environment),
           KimiModels.endpoint(forBaseURL: override) == nil {
            throw CLIApplicationError.failed(
                "unsupported Kimi API base URL: \(override)"
            )
        }
        // Service-aware: Kimi Platform and Kimi Code are separate services with
        // separate catalogs and credential scopes, so selection runs over the
        // endpoint's partition rather than raw file order. Ordering within the
        // partition is upstream's own defaulting.
        guard let model = defaultEmbeddedModel(
            forProvider: provider,
            embedded: embedded,
            environment: environment
        ) else {
            throw CLIApplicationError.failed(
                "no embedded default model for provider \(provider.asString)"
            )
        }
        return model
    }

    private static func defaultBackend(provider: ModelProvider) -> ApiBackend {
        switch provider {
        case .xai:
            return .chatCompletions
        case .codex:
            return .responses
        case .kimi, .fireworks:
            return .chatCompletions
        }
    }

    static func resolveProviderBaseURL(
        provider: ModelProvider,
        model: DefaultModelJSON?,
        environment: [String: String]
    ) -> String {
        let overrideKey: String
        let fallback: String
        switch provider {
        case .xai:
            overrideKey = "GROK_XAI_API_BASE_URL"
            fallback = model?.apiBaseURL ?? model?.baseURL ?? XAI_API_BASE_URL_DEFAULT
        case .codex:
            overrideKey = "GROK_CODEX_INFERENCE_BASE_URL"
            fallback = model?.apiBaseURL ?? model?.baseURL ?? CodexModels.defaultInferenceBaseURL
        case .kimi:
            overrideKey = KimiModels.apiBaseURLEnv
            fallback = model?.apiBaseURL ?? model?.baseURL ?? KimiModels.platformAPIBaseURL
        case .fireworks:
            overrideKey = FireworksModels.apiBaseURLEnv
            fallback = model?.apiBaseURL ?? model?.baseURL ?? FireworksModels.apiBaseURLDefault
        }
        return nonEmptyEnvironmentValue(overrideKey, environment: environment)
            ?? fallback
    }

    static func resolveProviderAPIKey(
        provider: ModelProvider,
        model: DefaultModelJSON?,
        baseURL: String,
        environment: [String: String]
    ) throws -> String? {
        if provider == .kimi {
            guard let endpoint = KimiModels.endpoint(forBaseURL: baseURL) else {
                throw CLIApplicationError.failed(
                    "unsupported Kimi API base URL: \(baseURL)"
                )
            }
            return nonEmptyEnvironmentValue(endpoint.apiKeyEnv, environment: environment)
        }
        if let credential = model?.envKey?.resolveValue(environment: environment)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !credential.isEmpty {
            return credential
        }
        let keys: [String]
        switch provider {
        case .xai:
            keys = ["XAI_API_KEY", "GROK_CODE_XAI_API_KEY"]
        case .codex:
            keys = ["OPENAI_API_KEY"]
        case .kimi:
            keys = []
        case .fireworks:
            keys = [FireworksModels.apiKeyEnv]
        }
        return keys.lazy.compactMap { key in
            nonEmptyEnvironmentValue(key, environment: environment)
        }.first
    }

    private static func nonEmptyEnvironmentValue(
        _ key: String,
        environment: [String: String]
    ) -> String? {
        environment[key]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func providerCredentialDescription(_ provider: ModelProvider) -> String {
        switch provider {
        case .xai:
            return "XAI_API_KEY"
        case .codex:
            return "Codex OAuth credentials"
        case .kimi:
            return "MOONSHOT_API_KEY or KIMI_CODE_API_KEY"
        case .fireworks:
            return "FIREWORKS_API_KEY"
        }
    }

    /// Dispatch gate for the file tool pack.
    ///
    /// `OPENGROK_ALLOW_WRITES=1` is an explicit bypass that skips prompting
    /// entirely. Otherwise mutations route to `coordinator`: in an interactive
    /// TTY the pager renderer installs itself as its presenter and the tool
    /// suspends on the permission sheet, and everywhere else nothing is
    /// listening, so the prompter fails closed with an actionable message
    /// rather than hanging on a modal no terminal will paint.
    static func resolveFileAccessPolicy(
        environment: [String: String],
        coordinator: PagerPermissionCoordinator? = nil
    ) -> FileToolAccessPolicy {
        let raw = environment["OPENGROK_ALLOW_WRITES"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch raw {
        case "1", "true", "yes", "on":
            return .allowAll
        default:
            guard let coordinator else { return .prompt(LiveWriteDenialPrompter()) }
            return .prompt(LivePermissionModalPrompter(
                coordinator: coordinator,
                sessionPolicy: LiveSessionWritePolicy()
            ))
        }
    }

    private static func makeProviderConfiguration(
        sessionID: String,
        sampling: OpenGrokLiveSamplingConfiguration,
        credential: LiveResolvedCredential,
        openGrokHome: URL,
        environment: [String: String]
    ) -> ProviderSessionConfiguration {
        let entry = ModelEntry(
            info: ModelInfo(
                model: sampling.model,
                baseURL: sampling.baseURL,
                apiBackend: sampling.apiBackend,
                provider: sampling.provider
            ),
            apiKey: sampling.apiKey,
            apiBaseURL: sampling.baseURL
        )
        return ProviderSessionConfiguration(
            sessionID: sessionID,
            modelCatalog: [sampling.model: entry],
            initialModelID: sampling.model,
            credentialBindings: [sampling.provider: credential.binding],
            openGrokHome: openGrokHome,
            environment: environment
        )
    }
}

/// Rejects every mutation with an actionable message instead of hanging on a
/// prompt no terminal is listening for.
struct LiveWriteDenialPrompter: PermissionPrompter {
    func prompt(
        access: AccessKind,
        toolName: String,
        toolCallId: String
    ) async -> PermissionDecision {
        _ = (access, toolCallId)
        return .reject(LiveWriteDenialPrompter.denialMessage(toolName: toolName))
    }

    static func denialMessage(toolName: String) -> String {
        "'\(toolName)' would modify files, and file mutations are disabled for this session. "
            + "Set OPENGROK_ALLOW_WRITES=1 to allow them."
    }
}

/// "Allow for the rest of the session", held outside the coordinator so a
/// second mutation never re-prompts once the user has said yes.
actor LiveSessionWritePolicy {
    private var allowsAll = false

    init() {}

    func isAllowingAll() -> Bool { allowsAll }
    func allowAll() { allowsAll = true }
}

/// Routes a mutation through the pager's permission sheet.
///
/// Fails closed when no presenter is installed — headless runs, non-TTY pipes,
/// and the window after teardown — so a tool can never suspend on a modal that
/// will not be drawn.
struct LivePermissionModalPrompter: PermissionPrompter {
    let coordinator: PagerPermissionCoordinator
    let sessionPolicy: LiveSessionWritePolicy

    func prompt(
        access: AccessKind,
        toolName: String,
        toolCallId: String
    ) async -> PermissionDecision {
        if await sessionPolicy.isAllowingAll() { return .allow }
        guard await coordinator.hasPresenter else {
            return .reject(LiveWriteDenialPrompter.denialMessage(toolName: toolName))
        }
        let request = PagerPermissionRequest(
            id: toolCallId.isEmpty ? UUID().uuidString : toolCallId,
            toolName: toolName,
            targetPath: Self.targetPath(for: access)
        )
        switch await coordinator.decision(for: request) {
        case .allowOnce:
            return .allow
        case .allowSession:
            await sessionPolicy.allowAll()
            return .allow
        case .deny:
            return .reject("'\(toolName)' was denied.")
        }
    }

    private static func targetPath(for access: AccessKind) -> String? {
        switch access {
        case .edit(let path):
            return path
        case .read(let path):
            return path
        case .grep(let path, _):
            return path
        case .bash(let command):
            return command
        case .webFetch(let url):
            return url
        case .webSearch(let query):
            return query
        case .mcpTool(let name, _):
            return name
        }
    }
}

struct LiveToolExecutor: Sendable {
    let tools: [ToolSpec]
    let workingDirectory: URL
    private let composition: OpenGrokShellToolRuntimeComposition
    private let fileToolBridge: ToolBridge
    private let fileToolNames: Set<String>

    init(
        processBackend: any ShellProcessBackend,
        sessionID: String,
        workingDirectory: URL,
        toolPolicy: LiveAgentToolPolicy?,
        fileAccessPolicy: FileToolAccessPolicy = .denyByDefault
    ) async throws {
        let composition = OpenGrokShellToolRuntimeComposition(
            processBackend: processBackend,
            runtime: LiveRunTerminalToolRuntime()
        )
        try await composition.registerSession(
            sessionID: sessionID,
            workingDirectory: workingDirectory
        )
        let standardizedWorkingDirectory = workingDirectory.standardizedFileURL
        let fileToolResources = FileToolSession.makeResources(
            workspaceRoot: standardizedWorkingDirectory.path,
            sessionId: sessionID,
            agentId: "main",
            policy: fileAccessPolicy
        )
        let fileToolBridge = ToolBridge(toolset: try FileToolPack.finalizeBuildPack(
            resources: fileToolResources,
            capabilityMode: Self.capabilityMode(for: toolPolicy)
        ))
        let fileToolDefinitions = fileToolBridge.toolDefinitions()
        let allowedFileToolDefinitions = fileToolDefinitions.filter {
            toolPolicy?.allows(liveToolName: $0.name) ?? true
        }
        let terminalTools = toolPolicy?.allows(liveToolName: Self.runTerminalTool.name) == false
            ? []
            : [Self.runTerminalTool]
        self.composition = composition
        self.fileToolBridge = fileToolBridge
        self.fileToolNames = Set(allowedFileToolDefinitions.map(\.name))
        self.workingDirectory = standardizedWorkingDirectory
        self.tools = terminalTools + allowedFileToolDefinitions.map { definition in
            ToolSpec(
                name: definition.name,
                description: definition.description,
                parameters: definition.argumentsSchema ?? .object([
                    "type": .string("object")
                ])
            )
        }
    }

    /// Listing gate: a read-only agent profile never sees a mutating tool.
    /// A profile that declares no capability mode gets the pack's default.
    private static func capabilityMode(
        for policy: LiveAgentToolPolicy?
    ) -> ToolCapabilityMode {
        switch policy?.capabilityMode {
        case .readOnly: return .readOnly
        case .readWrite: return .readWrite
        case .execute: return .execute
        case .all: return .all
        case nil: return .readWrite
        }
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

        if fileToolNames.contains(call.name) {
            if Task.isCancelled {
                return .failure(.cancelled)
            }
            switch await fileToolBridge.call(
                name: call.name,
                args: args,
                callId: call.callId
            ) {
            case .success(let result):
                return .success(OpenGrokShellToolCallResult(
                    value: result.output.value,
                    promptText: result.promptText
                ))
            case .failure(let error):
                return .failure(.failed(error.description))
            }
        }

        guard call.name == Self.runTerminalTool.name else {
            return .failure(.unsupported("unknown tool '\(call.name)'"))
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
                "output_byte_limit": .object([
                    "type": .string("integer"),
                    "description": .string("Maximum captured output bytes before truncation.")
                ]),
                "description": .object([
                    "type": .string("string"),
                    "description": .string("Short explanation of the command.")
                ]),
                "is_background": .object([
                    "type": .string("boolean"),
                    "description": .string("Run as a background task.")
                ]),
                "environment": .object([
                    "type": .string("object"),
                    "description": .string("Optional environment variables for the command."),
                    "additionalProperties": .object([
                        "type": .string("string")
                    ])
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

struct LiveConversationRecord: Codable, Sendable, Equatable {
    var sessionID: String
    var workingDirectory: String
    var parentSessionID: String?
    var createdAt: Date
    var updatedAt: Date
    var items: [ConversationItem]

    static func new(sessionID: String, workingDirectory: URL) -> LiveConversationRecord {
        let now = Date()
        return LiveConversationRecord(
            sessionID: sessionID,
            workingDirectory: workingDirectory.standardizedFileURL.path,
            parentSessionID: nil,
            createdAt: now,
            updatedAt: now,
            items: []
        )
    }
}

actor LiveConversationStore {
    private let sessionsDirectory: URL
    private let fileManager: FileManager

    init(openGrokHome: URL, fileManager: FileManager = .default) {
        self.sessionsDirectory = openGrokHome
            .appendingPathComponent("sessions", isDirectory: true)
            .standardizedFileURL
        self.fileManager = fileManager
    }

    static func validateSessionID(_ sessionID: String) throws {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !sessionID.isEmpty,
              sessionID.count <= 128,
              sessionID != ".",
              sessionID != "..",
              sessionID.allSatisfy(allowed.contains)
        else {
            throw CLIApplicationError.failed("invalid session ID: \(sessionID)")
        }
    }

    func load(sessionID: String) throws -> LiveConversationRecord {
        guard let record = try loadIfPresent(sessionID: sessionID) else {
            throw CLIApplicationError.failed("session not found: \(sessionID)")
        }
        return record
    }

    func loadIfPresent(sessionID: String) throws -> LiveConversationRecord? {
        try Self.validateSessionID(sessionID)
        let url = fileURL(sessionID: sessionID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let record = try JSONDecoder().decode(LiveConversationRecord.self, from: data)
            guard record.sessionID == sessionID else {
                throw CLIApplicationError.failed("session file ID mismatch: \(sessionID)")
            }
            return record
        } catch let error as CLIApplicationError {
            throw error
        } catch {
            throw CLIApplicationError.failed("failed to load session \(sessionID): \(error)")
        }
    }

    func latest(workingDirectory: URL) throws -> LiveConversationRecord? {
        guard fileManager.fileExists(atPath: sessionsDirectory.path) else { return nil }
        let expectedDirectory = workingDirectory.standardizedFileURL.path
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: sessionsDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw CLIApplicationError.failed("failed to list sessions: \(error)")
        }

        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> LiveConversationRecord? in
                guard let data = try? Data(contentsOf: url),
                      let record = try? JSONDecoder().decode(LiveConversationRecord.self, from: data),
                      URL(fileURLWithPath: record.workingDirectory).standardizedFileURL.path == expectedDirectory
                else { return nil }
                return record
            }
            .max { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.sessionID < rhs.sessionID
                }
                return lhs.updatedAt < rhs.updatedAt
            }
    }

    func save(_ record: LiveConversationRecord) throws {
        try Self.validateSessionID(record.sessionID)
        do {
            try fileManager.createDirectory(
                at: sessionsDirectory,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(record)
            try data.write(to: fileURL(sessionID: record.sessionID), options: .atomic)
        } catch {
            throw CLIApplicationError.failed("failed to save session \(record.sessionID): \(error)")
        }
    }

    private func fileURL(sessionID: String) -> URL {
        sessionsDirectory.appendingPathComponent(sessionID).appendingPathExtension("json")
    }
}

struct LiveAgentProfile: Sendable, Equatable {
    let model: String?
    let systemPrompt: String?
    let toolPolicy: LiveAgentToolPolicy
}

struct LiveAgentToolPolicy: Sendable, Equatable {
    let configuredTools: [String]
    let allowlist: [String]
    let denylist: [String]
    let sessionAllowlist: [String]?
    let sessionDenylist: [String]
    let capabilityMode: AgentCapabilityMode?

    init(definition: AgentDefinition) {
        configuredTools = definition.toolConfig.toolNames
        allowlist = definition.tools
        denylist = definition.disallowedTools
        sessionAllowlist = definition.sessionToolsAllowlist
        sessionDenylist = definition.sessionToolsDenylist ?? []
        capabilityMode = definition.capabilityMode
    }

    func allows(liveToolName: String) -> Bool {
        let aliases = Self.aliases(for: liveToolName)
        guard Self.matches(configuredTools, aliases: aliases) else { return false }
        if !allowlist.isEmpty, !Self.matches(allowlist, aliases: aliases) { return false }
        if Self.matches(denylist, aliases: aliases) { return false }
        if Self.matches(sessionDenylist, aliases: aliases) { return false }
        if let sessionAllowlist, !Self.matches(sessionAllowlist, aliases: aliases) { return false }
        guard let capabilityMode else { return true }
        switch capabilityMode {
        case .readOnly, .readWrite:
            return liveToolName != "run_terminal_cmd"
        case .execute, .all:
            return true
        }
    }

    private static func aliases(for liveToolName: String) -> Set<String> {
        if liveToolName == "run_terminal_cmd" {
            return [liveToolName, "run_terminal_command"]
        }
        return [liveToolName]
    }

    private static func matches(_ entries: [String], aliases: Set<String>) -> Bool {
        entries.contains { entry in
            let shortName = entry.split(separator: ":").last.map(String.init) ?? entry
            return aliases.contains(entry) || aliases.contains(shortName)
        }
    }
}

actor LiveConversationHistory {
    private var record: LiveConversationRecord
    private let store: LiveConversationStore

    init(record: LiveConversationRecord, store: LiveConversationStore) {
        self.record = record
        self.store = store
    }

    var items: [ConversationItem] { record.items }

    /// Rewrite history to its provider-neutral spine ahead of a provider
    /// change, and persist the result. Returns how many items were dropped.
    ///
    /// This is destructive on purpose: the persisted session must not keep
    /// carriers the next provider would be handed on resume.
    @discardableResult
    func isolateForProviderSwitch() async throws -> Int {
        let before = record.items
        let sanitized = liveProviderNeutralHistory(before)
        guard sanitized != before else { return 0 }
        record.items = sanitized
        record.updatedAt = Date()
        try await store.save(record)
        return before.count - sanitized.count
    }

    func itemsForTurn(sessionID: String, prompt: String) -> [ConversationItem] {
        var items = sessionID == record.sessionID ? record.items : []
        items.append(.user(prompt))
        return items
    }

    func commit(sessionID: String, items: [ConversationItem]) async throws {
        guard sessionID == record.sessionID else {
            throw CLIApplicationError.failed("conversation session mismatch: \(sessionID)")
        }
        record.items = items
        record.updatedAt = Date()
        try await store.save(record)
    }
}

private struct LiveShellSamplingDriver: OpenGrokShellSamplingDriver, Sendable {
    /// Owns the sampler rather than holding one, so `/model` can rebuild the
    /// provider stack between turns without replacing the shell.
    let modelSwitch: LiveModelSwitchCoordinator
    let toolExecutor: LiveToolExecutor
    let conversationHistory: LiveConversationHistory
    let systemPrompt: String?
    /// The tool list this session advertises. In Code Mode it carries `exec`
    /// and `wait` and, in `code_mode_only`, hides everything the cell can
    /// reach through `tools.*`.
    let toolSurface: LiveCodeModeToolSurface
    /// `nil` in `direct` mode, which leaves the turn loop byte-identical to a
    /// session that has never heard of Code Mode.
    let codeMode: LiveCodeModeCoordinator?

    func sample(
        context: OpenGrokShellProviderTurnContext,
        request: OpenGrokShellTurnRequest,
        emit: @escaping @Sendable (OpenGrokShellTurnUpdateKind) async -> Void
    ) async throws -> OpenGrokShellSamplingResult {
        guard let codeMode else {
            return try await runTurn(context: context, request: request, emit: emit)
        }
        // Nested calls raise their tool cards through this turn's sink, and a
        // cancelled turn (Esc) terminates whatever cells are still running.
        await codeMode.beginTurn(emit: emit)
        do {
            let result = try await withTaskCancellationHandler {
                try await runTurn(context: context, request: request, emit: emit)
            } onCancel: {
                Task { await codeMode.cancelActiveCells() }
            }
            await codeMode.endTurn()
            return result
        } catch {
            await codeMode.cancelActiveCells()
            await codeMode.endTurn()
            throw error
        }
    }

    private func runTurn(
        context: OpenGrokShellProviderTurnContext,
        request: OpenGrokShellTurnRequest,
        emit: @escaping @Sendable (OpenGrokShellTurnUpdateKind) async -> Void
    ) async throws -> OpenGrokShellSamplingResult {
        // One snapshot per turn: a switch that lands mid tool loop applies to
        // the next turn, never to half of this one.
        let active = await modelSwitch.snapshot()
        let sampler = active.sampler
        var items = await conversationHistory.itemsForTurn(
            sessionID: context.sessionID,
            prompt: request.text
        )
        if let systemPrompt,
           !items.contains(where: {
               if case .system = $0 { return true }
               return false
           }) {
            items.insert(.system(systemPrompt), at: 0)
        }
        var toolRoundCount = 0

        while true {
            try Task.checkCancellation()
            let response = try await sampler.sample(OpenGrokLiveSamplingRequest(
                sessionID: context.sessionID,
                turnID: context.turnID,
                model: active.modelID,
                prompt: request.text,
                items: items,
                tools: toolSurface.modelTools
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
                try Task.checkCancellation()
                try await conversationHistory.commit(
                    sessionID: context.sessionID,
                    items: items
                )
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
            items.append(contentsOf: try await executeToolCalls(
                response.toolCalls,
                sessionID: context.sessionID,
                emit: emit
            ))
        }
    }

    private func executeToolCalls(
        _ calls: [ToolCall],
        sessionID: String,
        emit: @escaping @Sendable (OpenGrokShellTurnUpdateKind) async -> Void
    ) async throws -> [ConversationItem] {
        // `exec` and `wait` are transport, not tools: they raise no card and
        // never announce themselves, so the transcript shows only the nested
        // calls the cell made (turn.rs:1998). They also mutate one runtime, so
        // they run in order rather than joining the parallel group.
        var transportResults: [Int: ToolResultItem] = [:]
        if let codeMode {
            for (index, call) in calls.enumerated() where codeMode.isTransportCall(call) {
                try Task.checkCancellation()
                transportResults[index] = await codeMode.handleTransportCall(call)
            }
        }
        let dispatched = calls.enumerated().filter { transportResults[$0.offset] == nil }

        for (_, call) in dispatched {
            try Task.checkCancellation()
            await emit(.tool(OpenGrokShellToolUpdate(
                callID: call.callId,
                name: call.name,
                input: call.arguments,
                state: .running
            )))
            await emit(.status("running tool \(call.name)"))
        }

        return try await withThrowingTaskGroup(
            of: (Int, ToolResultItem).self,
            returning: [ConversationItem].self
        ) { group in
            for (index, call) in dispatched {
                group.addTask {
                    let result = await toolExecutor.invoke(
                        sessionID: sessionID,
                        workingDirectory: toolExecutorWorkingDirectory,
                        call: call
                    )
                    let content: String
                    switch result {
                    case .success(let result):
                        content = result.promptText
                        await emit(.tool(OpenGrokShellToolUpdate(
                            callID: call.callId,
                            name: call.name,
                            input: call.arguments,
                            output: content,
                            state: .succeeded
                        )))
                        await emit(.status("tool \(call.name) completed"))
                    case .failure(.cancelled):
                        await emit(.tool(OpenGrokShellToolUpdate(
                            callID: call.callId,
                            name: call.name,
                            input: call.arguments,
                            output: "Cancelled",
                            state: .cancelled
                        )))
                        throw CancellationError()
                    case .failure(let error):
                        content = "Tool \(call.name) failed: \(error.description)"
                        await emit(.tool(OpenGrokShellToolUpdate(
                            callID: call.callId,
                            name: call.name,
                            input: call.arguments,
                            output: content,
                            state: .failed
                        )))
                        await emit(.status("tool \(call.name) failed"))
                    }
                    return (index, ToolResultItem(
                        toolCallId: call.callId,
                        content: content
                    ))
                }
            }

            var orderedResults = Array<ToolResultItem?>(repeating: nil, count: calls.count)
            for (index, result) in transportResults {
                orderedResults[index] = result
            }
            for try await (index, result) in group {
                orderedResults[index] = result
            }
            return orderedResults.compactMap { result in
                result.map(ConversationItem.toolResult)
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
                        case .tool(let tool):
                            let state: OpenGrokPagerToolState
                            switch tool.state {
                            case .running: state = .running
                            case .succeeded: state = .succeeded
                            case .failed: state = .failed
                            case .cancelled: state = .cancelled
                            }
                            continuation.yield(.tool(OpenGrokPagerToolUpdate(
                                callID: tool.callID,
                                name: tool.name,
                                input: tool.input,
                                output: tool.output,
                                state: state
                            )))
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

/// Chrome the live TUI composes for every frame.
///
/// The reference builds its shortcut hints from an action registry
/// (`src/actions/defaults.rs`); this port lists only the bindings the Swift
/// controller actually honors, so the bar never advertises a key that does
/// nothing.
enum LivePagerChrome {
    static func collapseHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    static func shortcutHints(isTurnRunning: Bool) -> [PagerShortcutHint] {
        var hints: [PagerShortcutHint] = [
            // The submit label flips to "queue" while a turn is in flight,
            // matching `views/agent.rs:992`.
            PagerShortcutHint(key: "Enter", label: isTurnRunning ? "queue" : "send", isPinned: true)
        ]
        if isTurnRunning {
            hints.append(PagerShortcutHint(key: "Esc", label: "cancel", isPinned: true))
        } else {
            hints.append(PagerShortcutHint(key: "\u{2191}", label: "history"))
            hints.append(PagerShortcutHint(key: "/", label: "commands"))
        }
        hints.append(PagerShortcutHint(keys: ["PgUp", "PgDn"], label: "scroll"))
        hints.append(PagerShortcutHint(key: "Ctrl+c", label: "quit", isPinned: true))
        return hints
    }
}

private struct LivePagerConversationState {
    private(set) var items: [PagerConversationItem] = []
    private var activeAssistantIndex: Int?
    private var toolIndicesByCallID: [String: Int] = [:]
    /// Renders assistant messages as markdown for frame painting. `nil` leaves
    /// them as plain text, which is what the inline and transcript paths want.
    private let markdown: PagerMarkdownRenderer?

    init(markdown: PagerMarkdownRenderer? = nil) {
        self.markdown = markdown
    }

    /// Re-render the accumulated message body.
    ///
    /// The whole message is re-parsed on each delta rather than patched: a
    /// streamed answer is bounded by the model's output budget, and markdown
    /// structure is not stable under append (a fence or table opened by the
    /// latest delta reinterprets earlier lines).
    private func styledLines(for text: String) -> [PagerStyledLine] {
        guard let markdown, !text.isEmpty else { return [] }
        return markdown.render(text)
    }

    mutating func startTurn(prompt: String) {
        toolIndicesByCallID.removeAll(keepingCapacity: true)
        items.append(.message(PagerMessage(role: .user, text: prompt)))
        items.append(.message(PagerMessage(
            role: .assistant,
            text: "",
            isStreaming: true
        )))
        activeAssistantIndex = items.indices.last
    }

    mutating func appendMessage(_ message: PagerMessage) {
        items.append(.message(message))
    }

    mutating func appendAssistant(_ text: String) {
        guard let activeAssistantIndex,
              items.indices.contains(activeAssistantIndex),
              case .message(var message) = items[activeAssistantIndex]
        else {
            items.append(.message(PagerMessage(
                role: .assistant,
                text: text,
                isStreaming: true,
                styledLines: styledLines(for: text)
            )))
            self.activeAssistantIndex = items.indices.last
            return
        }
        message.text += text
        message.isStreaming = true
        message.styledLines = styledLines(for: message.text)
        items[activeAssistantIndex] = .message(message)
    }

    mutating func finishAssistant(removingIfEmpty: Bool = false) {
        guard let activeAssistantIndex,
              items.indices.contains(activeAssistantIndex),
              case .message(var message) = items[activeAssistantIndex]
        else { return }
        if removingIfEmpty, message.text.isEmpty {
            items.remove(at: activeAssistantIndex)
            self.activeAssistantIndex = nil
            return
        }
        message.isStreaming = false
        message.styledLines = styledLines(for: message.text)
        items[activeAssistantIndex] = .message(message)
        self.activeAssistantIndex = nil
    }

    mutating func apply(_ tool: OpenGrokPagerToolUpdate) {
        let card = PagerToolCard(
            name: tool.name,
            input: tool.input,
            output: tool.output,
            state: Self.renderState(for: tool.state)
        )
        if let index = toolIndicesByCallID[tool.callID], items.indices.contains(index) {
            items[index] = .tool(card)
        } else {
            finishAssistant(removingIfEmpty: true)
            items.append(.tool(card))
            toolIndicesByCallID[tool.callID] = items.indices.last
        }
    }

    var transcript: String {
        let lines = items.flatMap(Self.transcriptLines(for:))
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    static func transcript(for tool: OpenGrokPagerToolUpdate) -> String {
        transcriptLines(for: .tool(PagerToolCard(
            name: tool.name,
            input: tool.input,
            output: tool.output,
            state: renderState(for: tool.state)
        ))).joined(separator: "\n") + "\n"
    }

    private static func renderState(for state: OpenGrokPagerToolState) -> PagerToolState {
        switch state {
        case .running: return .running
        case .succeeded: return .succeeded
        case .failed: return .failed
        case .cancelled: return .cancelled
        }
    }

    /// The plain transcript replayed to the real terminal after the alt-screen
    /// is torn down. This is deliberately *not* the on-screen presentation: it
    /// is a labeled plain-text log that other composition paths and their
    /// tests share.
    private static func transcriptLines(for item: PagerConversationItem) -> [String] {
        switch item {
        case .message(let message):
            let label: String
            switch message.role {
            case .user: label = "You"
            case .assistant: label = "Grok"
            case .system: label = "System"
            case .reasoning: label = "Reasoning"
            case .error: label = "Error"
            }
            return ["\(label): \(message.text)"]
        case .tool(let tool):
            var lines = ["Tool \(tool.name) [\(transcriptState(tool.state))]"]
            if !tool.input.isEmpty {
                lines.append("  input: \(tool.input)")
            }
            if let output = tool.output, !output.isEmpty {
                lines.append("  result: \(output)")
            }
            return lines
        case .separator(let text):
            return [text]
        }
    }

    private static func transcriptState(_ state: PagerToolState) -> String {
        switch state {
        case .pending: return "pending"
        case .running: return "running"
        case .succeeded: return "done"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        }
    }
}

private actor LiveInteractiveControllerRenderer: OpenGrokPagerInteractiveRenderAdapter {
    private let mode: OpenGrokPagerMode
    private let terminal: OpenGrokLiveTerminal
    private let sink: any PagerTerminalSink
    private let renderer: PagerTerminalRenderer

    private var conversation = LivePagerConversationState(markdown: PagerMarkdownRenderer())
    private var prompt = OpenGrokPagerInteractivePromptState()
    private var terminalSize: OpenGrokTerminalCore.TerminalSize
    private var restored = false

    /// Frame chrome. `turnActivity` is `nil` whenever no turn is in flight,
    /// which is what hides the turn-status row — the reference gives that row
    /// zero height when idle.
    private let workingDirectory: String
    private var modelName: String
    /// `(id, provider)` pairs the `/model` picker lists.
    private let modelCatalog: [(id: String, provider: String)]
    /// Rebuilds the sampling stack when a picker row is chosen. `nil` in
    /// compositions with no provider session (tests, headless renders), where
    /// the picker degrades to a relabel.
    private let modelSwitch: LiveModelSwitchCoordinator?
    /// Prompts waiting behind the running turn, as published by the controller.
    private var queuedPromptCount = 0
    private var turnActivity: String?
    private var turnStartedAt: Date?
    private var animationTick = 0
    private var isCancelling = false

    /// Viewport state. The last frame's geometry is cached so a page-sized
    /// scroll can be expressed in rows without re-laying out the transcript.
    private var followsBottom = true
    private var scrollOffset = 0
    private var lastConversationHeight = 1
    private var lastMaximumScrollOffset = 0

    /// Overlay stack and the geometry the last frame published for it. Bounds
    /// are replaced wholesale every frame and never cached across one: a modal
    /// that no longer fits (below 20×6) publishes nothing, so a stale rect
    /// would hit-test against an overlay that is not on screen.
    private var overlays = PagerOverlayStack()
    private var lastOverlayBounds: [PagerOverlayBounds] = []
    private let permissionCoordinator: PagerPermissionCoordinator?
    private var currentPermissionRequestID: String?
    private var hasStartedFirstTurn = false

    /// Mouse. `linesPerEvent` folds the terminal's reports-per-notch into a
    /// per-report line count, which is the whole of the port's wheel handling —
    /// the reference's acceleration bands are not ported.
    private let wheelTuning: MouseWheelTuning
    private var mouseReportingEnabled: Bool

    init(
        mode: OpenGrokPagerMode,
        terminal: OpenGrokLiveTerminal,
        sink: any PagerTerminalSink,
        workingDirectory: String = FileManager.default.currentDirectoryPath,
        modelName: String = "unknown",
        modelCatalog: [(id: String, provider: String)] = [],
        modelSwitch: LiveModelSwitchCoordinator? = nil,
        permissionCoordinator: PagerPermissionCoordinator? = nil,
        terminalProgram: String? = nil,
        enableMouseReporting: Bool = true
    ) {
        self.mode = mode
        self.terminal = terminal
        self.sink = sink
        self.workingDirectory = workingDirectory
        self.modelName = modelName
        self.modelCatalog = modelCatalog.isEmpty
            ? [(id: modelName, provider: "current")]
            : modelCatalog
        self.modelSwitch = modelSwitch
        self.permissionCoordinator = permissionCoordinator
        self.wheelTuning = MouseWheelTuning(
            eventsPerTick: MouseWheelTuning.eventsPerTick(forTerminalProgram: terminalProgram)
        )
        self.mouseReportingEnabled = enableMouseReporting
        let size = terminal.size() ?? OpenGrokLiveTerminalSize(width: 80, height: 24)
        self.terminalSize = OpenGrokTerminalCore.TerminalSize(
            width: size.width,
            height: size.height
        )
        self.renderer = PagerTerminalRenderer(
            sink: sink,
            configuration: PagerTerminalRendererConfiguration(
                mode: mode == .fullScreen
                    ? .fullscreen
                    : .inline(height: max(1, min(12, size.height))),
                useAlternateScreen: mode == .fullScreen,
                useSynchronizedOutput: true,
                useMouseReporting: enableMouseReporting
            )
        )
    }

    func begin() async throws {
        try renderer.start()
        if let permissionCoordinator {
            await permissionCoordinator.setPresenter { [weak self] request in
                await self?.showPermission(request)
            }
        }
        // The welcome screen only makes sense on an empty session, and it must
        // not capture input: the reference paints a live composer beneath it.
        if conversation.items.isEmpty {
            overlays.push(.welcome(
                PagerWelcomeOverlay(
                    subtitle: LivePagerChrome.collapseHome(workingDirectory)
                ),
                capturesInput: false
            ))
        }
        try renderState()
    }

    func resize(to size: OpenGrokTerminalCore.TerminalSize) async throws {
        terminalSize = size
        try renderer.resize(to: size)
        try renderState()
    }

    func render(_ event: OpenGrokPagerInteractiveEvent) async throws {
        animationTick += 1
        switch event {
        case .lifecycle(let lifecycle):
            if lifecycle == .cancelling { isCancelling = true }
        case .promptChanged(let prompt):
            self.prompt = prompt
        case .turnStarted(let request):
            // The welcome screen's lifetime is exactly "before the first turn".
            if !hasStartedFirstTurn {
                hasStartedFirstTurn = true
                overlays.dismiss(id: "welcome")
            }
            conversation.startTurn(prompt: request.prompt)
            turnActivity = "Thinking\u{2026}"
            turnStartedAt = Date()
            isCancelling = false
        case .session(let event):
            apply(event)
        case .turnFinished:
            finishAssistant()
            endTurn()
        case .notice(let message):
            conversation.appendMessage(PagerMessage(role: .system, text: message))
        case .queueChanged(let count):
            queuedPromptCount = count
        case .viewport(let command):
            applyViewport(command)
        case .overlay(let request):
            try await present(request)
        case .turnCancelled:
            finishAssistant()
            conversation.appendMessage(PagerMessage(role: .system, text: "Cancelled."))
            // A cancelled turn must not leave a tool parked on a sheet the user
            // just walked away from.
            await resolveOutstandingPermissions()
            endTurn()
        case .eof, .shutdown:
            await resolveOutstandingPermissions()
            endTurn()
        case .cancelled:
            finishAssistant()
            await resolveOutstandingPermissions()
            endTurn()
        case .failed(let message):
            finishAssistant()
            conversation.appendMessage(PagerMessage(role: .error, text: message))
            await resolveOutstandingPermissions()
            endTurn()
        }
        try renderState()
    }

    private func endTurn() {
        turnActivity = nil
        turnStartedAt = nil
        isCancelling = false
    }

    /// Move the transcript viewport.
    ///
    /// Follow-bottom mirrors `scrollback/state/nav.rs`: scrolling up always
    /// breaks follow, and a downward scroll re-engages it only once it arrives
    /// already clamped at the bottom — the reference's overscroll gesture. A
    /// scroll that merely *lands* at the bottom moved real rows and does not
    /// re-engage.
    private func applyViewport(_ command: OpenGrokPagerViewportCommand) {
        let page = max(1, lastConversationHeight)
        let half = max(1, page / 2)
        switch command {
        case .top:
            followsBottom = false
            scrollOffset = 0
        case .bottom:
            followsBottom = true
            scrollOffset = lastMaximumScrollOffset
        case .lineUp:
            scrollUp(by: 1)
        case .lineDown:
            scrollDown(by: 1)
        case .halfPageUp:
            scrollUp(by: half)
        case .halfPageDown:
            scrollDown(by: half)
        case .pageUp:
            scrollUp(by: page)
        case .pageDown:
            scrollDown(by: page)
        }
    }

    private func scrollUp(by rows: Int) {
        let current = followsBottom ? lastMaximumScrollOffset : scrollOffset
        followsBottom = false
        scrollOffset = max(0, current - rows)
    }

    private func scrollDown(by rows: Int) {
        guard !followsBottom else { return }
        let target = min(lastMaximumScrollOffset, scrollOffset + rows)
        if target == scrollOffset {
            // The gesture arrived already clamped at the bottom: re-engage.
            followsBottom = true
        }
        scrollOffset = target
    }

    func restoreTerminal() async throws {
        guard !restored else { return }
        restored = true
        // Detach the presenter first, so a tool that asks after this point
        // fails closed instead of suspending on a sheet nobody will paint.
        await permissionCoordinator?.setPresenter(nil)
        await permissionCoordinator?.resolveAll(with: .deny)
        overlays.removeAll()
        currentPermissionRequestID = nil
        try renderer.restore()
        if mode == .fullScreen {
            try sink.write(transcript)
            try sink.flush()
        }
    }

    private func apply(_ event: OpenGrokPagerEvent) {
        switch event {
        case .lifecycle(let lifecycle):
            if lifecycle == .running, turnActivity == nil {
                turnActivity = "Thinking\u{2026}"
                turnStartedAt = turnStartedAt ?? Date()
            }
        case .output(let text):
            appendAssistant(text)
            turnActivity = "Responding\u{2026}"
        case .status(let text):
            turnActivity = text
        case .tool(let tool):
            apply(tool)
        case .permissionRequested(let request):
            turnActivity = "Permission required: \(request.prompt)"
        case .completed:
            finishAssistant()
            endTurn()
        case .cancelled:
            finishAssistant()
            endTurn()
        }
    }

    private func appendAssistant(_ text: String) {
        conversation.appendAssistant(text)
    }

    private func finishAssistant(removingIfEmpty: Bool = false) {
        conversation.finishAssistant(removingIfEmpty: removingIfEmpty)
    }

    private func apply(_ tool: OpenGrokPagerToolUpdate) {
        conversation.apply(tool)
        // While a tool runs, the turn-status row shows the tool's own title —
        // the reference has no separate "tool running" phrasing.
        if tool.state == .running {
            turnActivity = tool.name
        }
    }

    // MARK: - Overlays

    private func present(_ request: OpenGrokPagerOverlayRequest) async throws {
        switch request {
        case .help:
            overlays.push(.help(lines: OpenGrokPagerInteractiveController.helpText
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { PagerStyledLine(text: String($0)) }))
        case .modelPicker:
            overlays.push(.modelPicker(models: modelCatalog, currentModelID: modelName))
        case .toggleMouseReporting:
            mouseReportingEnabled.toggle()
            try renderer.setMouseReporting(mouseReportingEnabled)
            conversation.appendMessage(PagerMessage(
                role: .system,
                text: mouseReportingEnabled
                    ? "Mouse reporting on. Wheel scrolls the transcript; click selects overlay rows."
                    : "Mouse reporting off. Click and drag now selects text for your terminal's copy/paste."
            ))
        case .dismissAll:
            overlays.removeAll()
            currentPermissionRequestID = nil
        }
    }

    /// Push or replace the permission sheet. Driven by the coordinator's
    /// presenter callback, so `nil` means "the queue drained".
    private func showPermission(_ request: PagerPermissionRequest?) async {
        if let current = currentPermissionRequestID {
            overlays.dismiss(id: "permission:\(current)")
            currentPermissionRequestID = nil
        }
        if let request {
            overlays.push(.permission(request))
            currentPermissionRequestID = request.id
        }
        try? renderState()
    }

    private func resolveOutstandingPermissions() async {
        guard let permissionCoordinator else { return }
        await permissionCoordinator.resolveAll(with: .deny)
        if let current = currentPermissionRequestID {
            overlays.dismiss(id: "permission:\(current)")
            currentPermissionRequestID = nil
        }
    }

    /// Apply the outcome of a row choice, whether it came from `Enter` or a
    /// click. Overlay row ids are domain ids, so both paths land here.
    private func select(overlayID: String, rowID: String) async {
        if overlayID.hasPrefix("permission:") {
            // The sheet's row ids are `PagerPermissionDecision` raw values, so a
            // click resolves the request exactly as the keyboard would.
            guard let decision = PagerPermissionDecision(rawValue: rowID) else { return }
            await resolve(
                overlayID: overlayID,
                requestID: String(overlayID.dropFirst("permission:".count)),
                decision: decision
            )
            return
        }
        overlays.dismiss(id: overlayID)
        guard overlayID == "model" else { return }
        await switchModel(to: rowID)
    }

    /// Rebuild the live sampling stack for `modelID` and record what happened.
    ///
    /// A refused switch is reported as an error row and leaves `modelName` — and
    /// therefore the composer's border and the next turn's provider — alone.
    private func switchModel(to modelID: String) async {
        guard let modelSwitch else {
            // No provider session behind this renderer; the picker can still
            // relabel, but it must not claim the session changed.
            modelName = modelID
            conversation.appendMessage(PagerMessage(
                role: .system,
                text: "Model set to \(modelID). It applies to new sessions — "
                    + "this session keeps its current model."
            ))
            return
        }
        switch await modelSwitch.apply(modelID: modelID) {
        case .unchanged:
            conversation.appendMessage(PagerMessage(
                role: .system,
                text: "Already using \(modelID)."
            ))
        case .switched(let summary):
            modelName = summary.modelID
            conversation.appendMessage(PagerMessage(
                role: .system,
                text: summary.transcriptMessage
            ))
        case .failed(let modelID, let message):
            conversation.appendMessage(PagerMessage(
                role: .error,
                text: "Could not switch to \(modelID): \(message). "
                    + "Staying on \(modelName)."
            ))
        }
    }

    private func resolve(
        overlayID: String,
        requestID: String,
        decision: PagerPermissionDecision
    ) async {
        overlays.dismiss(id: overlayID)
        if currentPermissionRequestID == requestID { currentPermissionRequestID = nil }
        await permissionCoordinator?.resolve(requestID: requestID, decision: decision)
    }

    // MARK: - Input routing

    func handleInput(_ event: InputEvent) async throws -> OpenGrokPagerInputRouting {
        switch event {
        case .key(let key):
            guard overlays.isActive else { return .notHandled }
            switch overlays.handle(key, viewportHeight: overlayViewportHeight) {
            case .ignored:
                return .notHandled
            case .redraw, .consumed, .dismissed:
                try renderState()
                return .consumed
            case .selected(let id, let rowID):
                await select(overlayID: id, rowID: rowID)
                try renderState()
                return .consumed
            case .permission(let id, let requestID, let decision):
                await resolve(overlayID: id, requestID: requestID, decision: decision)
                try renderState()
                return .consumed
            }
        case .mouse(let mouse):
            guard mouseReportingEnabled else { return .notHandled }
            try await handleMouse(mouse)
            return .consumed
        case .paste:
            // A modal swallows pasted text for the same reason it swallows
            // keys: nothing typed while it is up belongs to the composer.
            return overlays.isActive ? .consumed : .notHandled
        default:
            return .notHandled
        }
    }

    /// Row budget for the focused overlay's page keys, read off the last painted
    /// frame. Falls back to the transcript height when that overlay published no
    /// bounds, which is what a viewport too small to hold a modal looks like.
    private var overlayViewportHeight: Int {
        guard let focused = overlays.focused?.id,
              let bounds = lastOverlayBounds.last(where: { $0.id == focused })
        else { return max(1, lastConversationHeight) }
        return max(1, bounds.content.height)
    }

    private func handleMouse(_ event: MouseEvent) async throws {
        let hit = lastOverlayBounds.last { $0.hitTest(x: event.x, y: event.y) }
        if event.isScroll {
            // One notch moves an overlay's selection by exactly one row, but
            // moves the transcript by the terminal's lines-per-report — the
            // reference's split between dropdown navigation and scrollback.
            if let hit, overlays.isActive, hit.id == overlays.focused?.id {
                let key = KeyEvent(key: event.kind == .scrollUp ? .up : .down)
                switch overlays.handle(key, viewportHeight: max(1, hit.content.height)) {
                case .ignored: break
                default:
                    try renderState()
                    return
                }
            }
            switch event.kind {
            case .scrollUp:
                scrollUp(by: wheelTuning.linesPerEvent)
            case .scrollDown:
                scrollDown(by: wheelTuning.linesPerEvent)
            case .scrollLeft, .scrollRight:
                return
            default:
                return
            }
            try renderState()
            return
        }

        guard event.kind == .down, event.resolvedButton == .left, let hit else { return }
        if let close = hit.closeButton, close.contains(x: event.x, y: event.y) {
            overlays.dismiss(id: hit.id)
            if currentPermissionRequestID.map({ "permission:\($0)" }) == hit.id {
                currentPermissionRequestID = nil
            }
            try renderState()
            return
        }
        if let row = hit.row(atX: event.x, y: event.y) {
            await select(overlayID: hit.id, rowID: row.id)
            try renderState()
            return
        }
        if let hint = hit.hints.first(where: { $0.frame.contains(x: event.x, y: event.y) }),
           let key = Self.keyEvent(forHint: hint.key)
        {
            switch overlays.handle(key, viewportHeight: max(1, hit.content.height)) {
            case .selected(let id, let rowID):
                await select(overlayID: id, rowID: rowID)
            case .permission(let id, let requestID, let decision):
                await resolve(overlayID: id, requestID: requestID, decision: decision)
            case .ignored, .redraw, .consumed, .dismissed:
                break
            }
            try renderState()
        }
    }

    /// Footer hints label the key they stand for, so a click on one replays it.
    /// Range and arrow hints (`1-9`, `↑/↓`) name no single key and do nothing.
    private static func keyEvent(forHint key: String) -> KeyEvent? {
        switch key.lowercased() {
        case "esc": return KeyEvent(key: .escape)
        case "enter": return KeyEvent(key: .enter)
        default: return nil
        }
    }

    private func renderState() throws {
        let isTurnRunning = turnActivity != nil
        let completions = prompt.completions.isEmpty
            ? nil
            : PagerCompletionMenu(
                rows: prompt.completions.map {
                    PagerCompletionRow(
                        label: $0.name,
                        summary: $0.summary,
                        isAvailable: $0.isAvailable
                    )
                },
                selectedIndex: prompt.selectedCompletion
            )
        let state = PagerRenderState(
            size: terminalSize,
            statusBar: PagerStatusBar(
                workingDirectory: LivePagerChrome.collapseHome(workingDirectory),
                queuedPromptCount: queuedPromptCount
            ),
            conversation: conversation.items,
            turnStatus: turnActivity.map { label in
                PagerTurnStatus(
                    label: isCancelling ? "Cancelling\u{2026}" : label,
                    isCancelling: isCancelling,
                    tick: animationTick,
                    elapsed: turnStartedAt.map { Date().timeIntervalSince($0) },
                    queuedPromptCount: queuedPromptCount,
                    // Bare Enter force-sends the head only when the composer is
                    // empty; with a draft, Enter queues it behind the others.
                    queueIsSendable: queuedPromptCount > 0 && prompt.text.isEmpty
                )
            },
            completions: completions,
            input: PagerComposerState(
                text: prompt.text,
                cursorCharacterOffset: prompt.cursorOffset,
                isFocused: true,
                cursorVisible: true,
                modelName: modelName,
                maximumHeight: max(3, terminalSize.height / 2)
            ),
            shortcuts: PagerShortcutsBar(
                hints: LivePagerChrome.shortcutHints(isTurnRunning: isTurnRunning),
                pendingKey: prompt.pendingConfirmationKey,
                pendingLabel: prompt.pendingConfirmationLabel
            ),
            scrollPosition: followsBottom ? .followTail : .offset(scrollOffset),
            overlays: overlays
        )
        // Render through the frame function rather than the renderer's own
        // engine so the resulting layout can seed the next scroll gesture.
        let result = renderPagerFrame(state)
        // Fresh every frame: a modal that no longer fits publishes no bounds.
        lastOverlayBounds = result.overlays
        lastConversationHeight = max(1, result.layout.conversation.height)
        lastMaximumScrollOffset = max(
            0,
            result.layout.totalContentLines - result.layout.conversation.height
        )
        if followsBottom { scrollOffset = lastMaximumScrollOffset }
        try renderer.render(result)
    }

    private var transcript: String { conversation.transcript }
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

    private var conversation: LivePagerConversationState
    private var output = ""
    private var status = "Starting"
    private var inlineBegan = false
    private var inlineEnded = false
    private var inlineNeedsAssistantPrefix = false
    private var restored = false
    private var renderTick = 0

    init(mode: OpenGrokPagerMode, terminal: OpenGrokLiveTerminal, prompt: String) {
        self.mode = mode
        self.terminal = terminal
        self.prompt = prompt
        // Inline mode streams raw text straight to the terminal and only uses
        // the conversation state for its plain transcript, so markdown is
        // rendered for the full-screen frame path only.
        conversation = LivePagerConversationState(
            markdown: mode == .fullScreen ? PagerMarkdownRenderer() : nil
        )
        conversation.startTurn(prompt: prompt)
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
            conversation.appendAssistant(text)
            status = "Responding"
            if mode == .inline {
                if inlineNeedsAssistantPrefix {
                    inlineNeedsAssistantPrefix = false
                    try await terminal.write("Grok: ")
                }
                try await terminal.write(text)
            }
        case .status(let value):
            status = value
        case .tool(let tool):
            conversation.apply(tool)
            status = "Tool \(tool.name) \(tool.state.rawValue)"
            if mode == .inline, tool.state != .running {
                try await terminal.write("\n")
                try await terminal.write(LivePagerConversationState.transcript(for: tool))
                inlineNeedsAssistantPrefix = true
            }
        case .permissionRequested(let request):
            status = "Permission required: \(request.prompt)"
        case .completed:
            conversation.finishAssistant()
            status = "Completed"
            if mode == .inline {
                try await finishInline()
            }
        case .cancelled:
            conversation.finishAssistant()
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
        renderTick += 1
        let terminalSize = terminal.size() ?? OpenGrokLiveTerminalSize(width: 80, height: 24)
        let result = renderEngine.render(PagerRenderState(
            size: OpenGrokTerminalCore.TerminalSize(
                width: terminalSize.width,
                height: terminalSize.height
            ),
            statusBar: PagerStatusBar(
                workingDirectory: LivePagerChrome.collapseHome(
                    FileManager.default.currentDirectoryPath
                )
            ),
            conversation: conversation.items,
            turnStatus: PagerTurnStatus(label: status, tick: renderTick),
            input: PagerComposerState(
                text: "",
                isFocused: false,
                cursorVisible: false,
                placeholder: "",
                maximumHeight: 3
            ),
            shortcuts: PagerShortcutsBar(
                hints: [PagerShortcutHint(key: "Ctrl+c", label: "cancel", isPinned: true)]
            )
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
        conversation.transcript
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
        case .lifecycle, .tool:
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
        case .lifecycle, .status, .tool, .permissionRequested:
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
        case .tool(let tool):
            streams.out(try Self.jsonLine([
                "type": "tool",
                "call_id": tool.callID,
                "name": tool.name,
                "input": tool.input,
                "output": tool.output as Any,
                "state": tool.state.rawValue
            ]))
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
