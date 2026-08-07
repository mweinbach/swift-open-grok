import Foundation
import OpenGrokAgentDefinitions
import OpenGrokACPRuntime
import OpenGrokAuth
import OpenGrokCodeMode
import OpenGrokCompaction
import OpenGrokConfig
import OpenGrokFileTools
import OpenGrokHTTP
import OpenGrokHooks
import OpenGrokHooksPluginTypes
import OpenGrokModels
import OpenGrokPager
import OpenGrokPagerCommandUI
import OpenGrokPagerMinimal
import OpenGrokPagerRender
import OpenGrokTokenEstimation
import OpenGrokProviderSession
import OpenGrokSampler
import OpenGrokSamplingTypes
import OpenGrokSandbox
import OpenGrokSessionRuntime
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase
import OpenGrokShellSessionSupport
import OpenGrokTerminalCore
import OpenGrokToolRegistry
import OpenGrokTTY
import OpenGrokWebMediaTools
import OpenGrokWorkspace

/// The catalog entry's model-tuning facts, carried from resolution into the
/// live `SamplerConfig` construction. Before these were threaded, the single
/// live `SamplingClient` was built with none of them, so a catalog effort like
/// grok-4.5's `high` never reached an outbound request — the classic
/// "compiles, returns, quietly does nothing" port failure.
public struct OpenGrokLiveSamplingTuning: Sendable, Equatable {
    /// The effort the sampler sends, and — per the sampler's contract — the
    /// "this model supports effort" signal for the Fireworks strip gate
    /// (`sanitizeChatWireRequest`; upstream client.rs:1806-1813). `nil` when
    /// the model declares no effort support, never a guessed default.
    public var reasoningEffort: ReasoningEffort?
    /// Responses `reasoning.summary` policy. `nil` means "no summary policy":
    /// the Codex patcher strips the base `concise` (provider.rs:613-620).
    public var reasoningSummary: ReasoningSummary?
    public var codexMultiAgentV2: Bool
    public var temperature: Float?
    public var topP: Float?
    public var maxCompletionTokens: UInt32?
    public var contextWindow: UInt64?

    public init(
        reasoningEffort: ReasoningEffort? = nil,
        reasoningSummary: ReasoningSummary? = nil,
        codexMultiAgentV2: Bool = false,
        temperature: Float? = nil,
        topP: Float? = nil,
        maxCompletionTokens: UInt32? = nil,
        contextWindow: UInt64? = nil
    ) {
        self.reasoningEffort = reasoningEffort
        self.reasoningSummary = reasoningSummary
        self.codexMultiAgentV2 = codexMultiAgentV2
        self.temperature = temperature
        self.topP = topP
        self.maxCompletionTokens = maxCompletionTokens
        self.contextWindow = contextWindow
    }

    /// Project a resolved catalog entry, with an optional validated per-switch
    /// effort override. The override applies only when the entry declares
    /// effort support (`model_supports_reasoning_effort` gate,
    /// handlers/model_switch.rs:139-158); a non-supporting model keeps `nil`
    /// so the sampler's provider gates see "no effort declared".
    public init(entry: ModelEntry, effortOverride: ReasoningEffort? = nil) {
        let info = entry.info
        self.init(
            reasoningEffort: info.supportsReasoningEffort
                ? (effortOverride ?? info.reasoningEffort)
                : nil,
            // `.none` is the catalog's "no summary" sentinel; the sampler's
            // policy hook wants absence, not the string "none".
            reasoningSummary: info.defaultReasoningSummary == .none
                ? nil
                : info.defaultReasoningSummary,
            codexMultiAgentV2: info.codexMultiAgentV2,
            temperature: info.temperature,
            topP: info.topP,
            maxCompletionTokens: info.maxCompletionTokens,
            contextWindow: info.contextWindow
        )
    }
}

public struct OpenGrokLiveSamplingConfiguration: Sendable, Equatable {
    public let model: String
    public let baseURL: String
    public let apiKey: String
    public let provider: ModelProvider
    public let apiBackend: ApiBackend
    /// Provider headers that travel with every sampling request — Codex OAuth
    /// account pinning (`ChatGPT-Account-ID`, `X-OpenAI-Fedramp`) arrives here.
    public let extraHeaders: [String: String]
    public let queryParams: [String: String]
    /// Model-tuning facts from the catalog entry (effort, summary, sampling
    /// scalars). Defaults to empty for compositions with no catalog entry.
    public let tuning: OpenGrokLiveSamplingTuning
    public let bearerResolver: (any BearerResolver)?
    public let credentialProvider: (any AuthCredentialProvider)?
    public let transport: (any HTTPTransport)?

    public var reasoningEffort: ReasoningEffort? { tuning.reasoningEffort }

    public init(
        model: String,
        baseURL: String,
        apiKey: String,
        provider: ModelProvider = .xai,
        apiBackend: ApiBackend = .chatCompletions,
        extraHeaders: [String: String] = [:],
        queryParams: [String: String] = [:],
        tuning: OpenGrokLiveSamplingTuning = OpenGrokLiveSamplingTuning(),
        bearerResolver: (any BearerResolver)? = nil,
        credentialProvider: (any AuthCredentialProvider)? = nil,
        transport: (any HTTPTransport)? = nil
    ) {
        self.model = model
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.provider = provider
        self.apiBackend = apiBackend
        self.extraHeaders = extraHeaders
        self.queryParams = queryParams
        self.tuning = tuning
        self.bearerResolver = bearerResolver
        self.credentialProvider = credentialProvider
        self.transport = transport
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model == rhs.model && lhs.baseURL == rhs.baseURL && lhs.apiKey == rhs.apiKey &&
        lhs.provider == rhs.provider && lhs.apiBackend == rhs.apiBackend &&
        lhs.extraHeaders == rhs.extraHeaders && lhs.queryParams == rhs.queryParams &&
        lhs.tuning == rhs.tuning
    }
}

final class NamedAuthBearerResolver: BearerResolver, @unchecked Sendable {
    private let provider: NamedAuthProviderResolver

    init(provider: NamedAuthProviderResolver) {
        self.provider = provider
    }

    func currentBearer() -> String? {
        provider.currentToken()
    }

    var reservedHeaders: [String] { ["Authorization", "x-api-key"] }
}

final class CredentialBearerResolver: BearerResolver, @unchecked Sendable {
    private let provider: any AuthCredentialProvider

    init(provider: any AuthCredentialProvider) {
        self.provider = provider
    }

    func currentBearer() -> String? {
        provider.snapshot().token
    }

    func currentAuth() -> ResolvedBearerAuth? {
        let snapshot = provider.snapshot()
        guard let token = snapshot.token else { return nil }
        let extraHeaders: [(name: String, value: String)] = provider.needsTokenAuthHeader()
            ? [(name: xaiTokenAuthHeader, value: xaiTokenAuthValue)]
            : []
        return ResolvedBearerAuth(bearer: token, extraHeaders: extraHeaders)
    }

    var reservedHeaders: [String] {
        ["Authorization", "x-api-key", xaiTokenAuthHeader]
    }
}

public struct OpenGrokLiveSamplingRequest: Sendable, Equatable {
    public let sessionID: String
    public let turnID: String
    public let model: String
    public let prompt: String
    public let items: [ConversationItem]
    public let tools: [ToolSpec]
    /// Force the model to answer in this JSON Schema (strict mode).
    ///
    /// A workflow's `agent(prompt, #{output_schema: ...})` is the only caller
    /// today: the script indexes into the result (`r.output.gaps`), so a prose
    /// answer would make the workflow take a wrong branch rather than fail
    /// loudly. Only the chat-completions backend projects this
    /// (`ConversationExtensions.swift:224`); on the other backends it is
    /// carried but ignored, and the runner falls back to parsing the text.
    public let jsonSchema: JSONValue?

    public init(
        sessionID: String,
        turnID: String,
        model: String,
        prompt: String,
        items: [ConversationItem]? = nil,
        tools: [ToolSpec] = [],
        jsonSchema: JSONValue? = nil
    ) {
        self.sessionID = sessionID
        self.turnID = turnID
        self.model = model
        self.prompt = prompt
        self.items = items ?? [.user(prompt)]
        self.tools = tools
        self.jsonSchema = jsonSchema
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
        let baseTransport = configuration.transport ?? URLSessionHTTPTransport()
        let transport: any HTTPTransport
        let bearerResolver: (any BearerResolver)?
        if let credentialProvider = configuration.credentialProvider {
            transport = AuthRetryTransport(
                transport: baseTransport,
                credentials: credentialProvider,
                maxRetries: 1
            )
            bearerResolver = configuration.bearerResolver
                ?? CredentialBearerResolver(provider: credentialProvider)
        } else {
            transport = baseTransport
            bearerResolver = configuration.bearerResolver
        }
        // The tuning fields ride on the config, not per-request: the sampler
        // backfills them in `applyConversationDefaults`, which is upstream's
        // `apply_defaults` seam (xai-grok-sampler client.rs:1148, :1460,
        // :3231-3233). Dropping any of them here silently reverts the model
        // to provider defaults — the audit that motivated this found NO
        // effort ever reaching an outbound request.
        let client = try SamplingClient(config: SamplerConfig(
            apiKey: configuration.apiKey,
            baseURL: configuration.baseURL,
            model: configuration.model,
            maxCompletionTokens: configuration.tuning.maxCompletionTokens,
            temperature: configuration.tuning.temperature,
            topP: configuration.tuning.topP,
            apiBackend: configuration.apiBackend,
            provider: configuration.provider,
            extraHeaders: configuration.extraHeaders
                .sorted { $0.key < $1.key }
                .map { (name: $0.key, value: $0.value) },
            queryParams: configuration.queryParams,
            contextWindow: configuration.tuning.contextWindow ?? 0,
            reasoningEffort: configuration.tuning.reasoningEffort,
            reasoningSummary: configuration.tuning.reasoningSummary,
            codexMultiAgentV2: configuration.tuning.codexMultiAgentV2,
            bearerResolver: bearerResolver
        ), transport: transport)
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
                xGrokSessionId: request.sessionID,
                jsonSchema: request.jsonSchema
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
    public let makeCodeModeCapability: @Sendable () -> CodeModeRuntimeCapability
    public let makeProcessBackend: @Sendable () -> any ShellProcessBackend
    public let terminal: OpenGrokLiveTerminal
    public let makeInteractiveInput: @Sendable () async throws -> OpenGrokLiveInteractiveInput?
    public let makeTerminalSink: @Sendable () -> (any PagerTerminalSink)?
    /// Transport the image tools issue their requests over. Injectable so a
    /// composition test can drive the full pipeline against a mock endpoint
    /// without reaching the network.
    public let makeImageTransport: @Sendable () -> any HTTPTransport
    public let workspaceRoute: LiveWorkspaceRouteDependencies
    public let makeLeaderClient: @Sendable (
        LiveLeaderClientLaunchConfiguration
    ) async throws -> LiveLeaderClientLease

    public init(
        makeSampler: @escaping @Sendable (OpenGrokLiveSamplingConfiguration) throws -> OpenGrokLiveSampler,
        makeCodeModeCapability: @escaping @Sendable () -> CodeModeRuntimeCapability = {
            InProcessCodeModeSession.runtimeCapability
        },
        makeProcessBackend: @escaping @Sendable () -> any ShellProcessBackend = {
            LocalShellProcessBackend()
        },
        terminal: OpenGrokLiveTerminal = .production,
        makeInteractiveInput: @escaping @Sendable () async throws -> OpenGrokLiveInteractiveInput? = { nil },
        makeTerminalSink: @escaping @Sendable () -> (any PagerTerminalSink)? = { nil },
        makeImageTransport: @escaping @Sendable () -> any HTTPTransport = {
            URLSessionHTTPTransport()
        },
        workspaceRoute: LiveWorkspaceRouteDependencies = .production(),
        makeLeaderClient: @escaping @Sendable (
            LiveLeaderClientLaunchConfiguration
        ) async throws -> LiveLeaderClientLease = { configuration in
            try await LiveLeaderClientAcquisition.production.connectOrSpawn(configuration)
        }
    ) {
        self.makeSampler = makeSampler
        self.makeCodeModeCapability = makeCodeModeCapability
        self.makeProcessBackend = makeProcessBackend
        self.terminal = terminal
        self.makeInteractiveInput = makeInteractiveInput
        self.makeTerminalSink = makeTerminalSink
        self.makeImageTransport = makeImageTransport
        self.workspaceRoute = workspaceRoute
        self.makeLeaderClient = makeLeaderClient
    }

    public static let production = OpenGrokLiveCompositionDependencies(
        makeSampler: OpenGrokLiveSampler.production(configuration:),
        makeCodeModeCapability: { InProcessCodeModeSession.runtimeCapability },
        makeProcessBackend: { LocalShellProcessBackend() },
        terminal: .production,
            makeInteractiveInput: OpenGrokLiveInteractiveInput.production,
            makeTerminalSink: { FileHandlePagerTerminalSink() },
        makeImageTransport: { URLSessionHTTPTransport() },
        workspaceRoute: .production(),
        makeLeaderClient: { configuration in
            try await LiveLeaderClientAcquisition.production.connectOrSpawn(configuration)
        }
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

private final class LiveSessionExportBoundaryRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var boundaries: [String: ExportBoundary] = [:]

    func register(sessionID: String, boundary: ExportBoundary) {
        lock.lock()
        boundaries[sessionID] = boundary
        lock.unlock()
    }

    func remove(sessionID: String) {
        lock.lock()
        boundaries.removeValue(forKey: sessionID)
        lock.unlock()
    }

    func boundary(for sessionID: String) -> ExportBoundary? {
        lock.lock()
        defer { lock.unlock() }
        return boundaries[sessionID]
    }
}

public struct OpenGrokLiveApplicationLauncher: Sendable {
    private let dependencies: OpenGrokLiveCompositionDependencies
    private let updateServices: LiveUpdateServices
    private let exportBoundaries = LiveSessionExportBoundaryRegistry()

    public init(
        dependencies: OpenGrokLiveCompositionDependencies = .production,
        updateServices: LiveUpdateServices = .production
    ) {
        self.dependencies = dependencies
        self.updateServices = updateServices
    }

    public var launcher: CLIApplicationLauncher {
        CLIApplicationLauncher { command, context in
            if LiveAuthComposition.handles(command) {
                return try await LiveAuthComposition.session(for: command, context: context)
            }
            if LiveUpdateComposition.handles(command) {
                return try await LiveUpdateComposition.session(
                    for: command,
                    context: context,
                    services: updateServices
                )
            }
            if LiveMCPComposition.handles(command) {
                return try await LiveMCPComposition.session(for: command, context: context)
            }
            if LiveWorkflowComposition.handles(command) {
                return try await LiveWorkflowComposition.session(for: command, context: context)
            }
            if LiveSessionsComposition.handles(command) {
                return try await LiveSessionsComposition.session(for: command, context: context)
            }
            if LiveShareComposition.handles(command) {
                return try await LiveShareComposition.session(
                    for: command,
                    context: context,
                    liveBoundaries: { sessionID in
                        exportBoundaries.boundary(for: sessionID)
                    }
                )
            }
            if LiveWorkspaceComposition.handles(command) {
                return try await LiveWorkspaceComposition.session(
                    for: command,
                    context: context,
                    routeDependencies: dependencies.workspaceRoute
                )
            }
            if LiveWorktreeComposition.handles(command) {
                return try await LiveWorktreeComposition.session(for: command, context: context)
            }
            // Ordering is load-bearing for the three ACP-family routes.
            // `LiveACPComposition.handles` still claims .serve/.leader with the
            // historical refusals, and `LiveServeComposition.handles` still
            // claims .leader with its own, so each working implementation has
            // to be consulted before the refusal that predates it: leader
            // first, then serve, then acp.
            if LiveLeaderComposition.handles(command) {
                return try await LiveLeaderComposition.session(
                    for: command,
                    context: context,
                    services: Self.liveACPServices(dependencies: dependencies)
                )
            }
            if LiveServeComposition.handles(command) {
                return try await LiveServeComposition.session(
                    for: command,
                    context: context,
                    services: Self.liveACPServices(dependencies: dependencies)
                )
            }
            if LiveACPComposition.handles(command) {
                return try await LiveACPComposition.session(
                    for: command,
                    context: context,
                    services: Self.liveACPServices(dependencies: dependencies)
                )
            }
            if LivePluginComposition.handles(command) {
                return try await LivePluginComposition.session(for: command, context: context)
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
            let workflowSourceCWD = try Self.resolveWorkingDirectory(options.common.cwd)
            let workflowsEnabled = try loadResolvedWorkflows(
                cwd: workflowSourceCWD,
                environment: context.environment
            ).value
            if options.common.workflow != nil && !workflowsEnabled {
                throw CLIApplicationError.failed(
                    "workflows are disabled by GROK_WORKFLOWS or [workflows].enabled"
                )
            }
            if options.common.leader {
                let cwd = try Self.resolveWorkingDirectory(options.common.cwd)
                let openGrokHome = Self.resolveOpenGrokHome(environment: context.environment)
                let relay = GrokComConfig.default(environment: context.environment)
                let lease = try await dependencies.makeLeaderClient(
                    LiveLeaderClientLaunchConfiguration(
                        workingDirectory: cwd,
                        openGrokHome: openGrokHome,
                        relayURL: relay.grokWSURL,
                        relayOrigin: relay.grokWSOrigin,
                        socketOverride: options.common.leaderSocket,
                        environment: context.environment,
                        clientType: options.mode == .headless ? "grok-p" : "grok-tui",
                        mode: options.mode == .headless ? .headless : .stdio,
                        capabilities: ACPLeaderClientCapabilities(
                            clientVersion: OpenGrokCLIVersion.installed(environment: context.environment),
                            terminal: options.mode == .interactive,
                            fsRead: true,
                            fsWrite: true
                        )
                    )
                )
                return try await Self.makeLeaderLaunchSession(
                    options: options,
                    prompt: prompt,
                    workingDirectory: cwd,
                    lease: lease,
                    context: context,
                    terminal: dependencies.terminal
                )
            }
            let foundation = try await Self.makeSessionFoundation(
                options: options,
                context: context,
                dependencies: dependencies
            )
            let cwd = foundation.cwd
            let agentProfile = foundation.agentProfile
            let openGrokHome = foundation.openGrokHome
            let sessionID = foundation.sessionID
            let samplingConfiguration = foundation.samplingConfiguration
            let sampler = foundation.sampler
            let providerConfiguration = foundation.providerConfiguration
            let permissionCoordinator = foundation.permissionCoordinator
            let toolExecutor = foundation.toolExecutor
        let skillCommands = foundation.skillCatalog.map { entry in
                OpenGrokPagerCommandRegistration(
                    name: entry.commandName,
                    summary: entry.skill.shortDescription ?? entry.skill.description,
                    usage: entry.skill.argumentHint
                )
            }
            let feedbackCommands = foundation.feedback.slashCommandAvailable
                ? [OpenGrokPagerCommandRegistration(
                    name: "feedback",
                    summary: "Send private feedback about this session",
                    usage: "/feedback <text>"
                )]
                : []
            // A `--workflow` launch is a background run, exactly as upstream:
            // it is registered and started here and the session continues
            // unblocked. A non-interactive launch has no session to continue
            // into, so it waits for the run and reports it — otherwise the
            // process would exit while its agents were still working.
            // One registry per session, shared by the `--workflow` launch and
            // the `/workflows` dashboard, so both see the same runs.
            let workflowRegistry: RhaiWorkflowRunRegistry?
            if workflowsEnabled {
                let registry = LiveWorkflowLaunch.makeRegistry(openGrokHome: openGrokHome)
                // Runs left active by a previous process are marked interrupted
                // before this one starts, so the dashboard never shows a run as
                // progressing with no task behind it.
                _ = try? await registry.restore()
                workflowRegistry = registry
            } else {
                workflowRegistry = nil
            }
            if let workflowPath = options.common.workflow, let registry = workflowRegistry {
                let record = try await LiveWorkflowLaunch.start(
                    script: try LiveWorkflowComposition.readScript(at: workflowPath),
                    registry: registry,
                    session: LiveWorkflowLaunch.Session(
                        sampler: sampler,
                        model: samplingConfiguration.model,
                        workspaceRoot: cwd,
                        sessionID: sessionID,
                        openGrokHome: openGrokHome,
                        telemetryBootstrapContext: foundation.telemetryBootstrapContext,
                        systemPrompt: [
                            agentProfile?.systemPrompt,
                            LiveSkills.listing(foundation.discoveredSkills)
                        ]
                        .compactMap { value in
                            guard let value, !value.isEmpty else { return nil }
                            return value
                        }
                        .joined(separator: "\n\n"),
                        toolPolicy: agentProfile?.toolPolicy,
                        fileAccessPolicy: Self.resolveFileAccessPolicy(
                            environment: context.environment,
                            coordinator: permissionCoordinator
                        ),
                        makeProcessBackend: dependencies.makeProcessBackend,
                        environment: context.environment
                    )
                )
                if options.mode != .interactive {
                    context.streams.out("workflow run \(record.runID) started\n")
                    _ = try await registry.awaitCompletion(runID: record.runID)
                    context.streams.out(LiveWorkflowComposition.renderDetail(
                        try await registry.view(runID: record.runID)
                    ))
                    await toolExecutor.shutdown()
                    return CLIApplicationSession(waitForExit: {}, shutdown: {})
                }
                context.streams.out(
                    "workflow run \(record.runID) started in the background; watch it with /workflows\n"
                )
            }
            let stack = await Self.makeAgentStack(
                foundation: foundation,
                context: context,
                dependencies: dependencies,
                launchAutoUpdate: LiveLaunchAutoUpdate.Request(
                    noAutoUpdate: options.advanced.noAutoUpdate,
                    services: updateServices
                )
            )
            let sharedExportBoundary = await stack.conversationHistory.sharedExportBoundary
            exportBoundaries.register(
                sessionID: sessionID,
                boundary: sharedExportBoundary
            )
            let codeMode = stack.codeMode
            let modelSwitch = stack.modelSwitch
            let shell = stack.shell
            let runtime = LivePagerRuntimeAdapter(
                shell: shell,
                cwd: cwd,
                providerConfiguration: providerConfiguration,
                conversationHistory: stack.conversationHistory,
                conversationStore: foundation.conversationStore,
                toolExecutor: foundation.toolExecutor,
                compaction: stack.compaction,
                modelSwitch: modelSwitch
            )
            // Seed the manager's session route so `/effort`'s "current" and
            // the effort dropdown's "(active)" marker reflect the model this
            // session actually started on — the same seeding upstream's
            // session creation performs on `ModelState` before any switch.
            stack.catalogStore.noteModelSwitch(
                catalogID: providerConfiguration.initialModelID,
                effort: foundation.samplingConfiguration.reasoningEffort
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
                        modelCatalog: stack.catalogStore.pickerEntries(),
                        catalogStore: stack.catalogStore,
                        modelSwitch: modelSwitch,
                        providerBoundarySync: { everUsedNonXAI in
                            try await shell.synchronizeProviderBoundary(
                                sessionID: SessionID(sessionID),
                                everUsedNonXAI: everUsedNonXAI
                            )
                        },
                        permissionCoordinator: permissionCoordinator,
                        workflowRegistry: workflowRegistry,
                        workflowsEnabled: workflowsEnabled,
                        terminalProgram: context.environment["TERM_PROGRAM"],
                        // The composer border shows the session's live effort
                        // from the first frame; before this the parameter had
                        // no production caller and rendered nil forever.
                        reasoningEffort: foundation.samplingConfiguration
                            .reasoningEffort?.asString,
                        compaction: stack.compaction,
                        sessionID: sessionID,
                        // The tool executor's own aggregate, not a second one:
                        // `/rewind` must see the snapshots the turn loop
                        // captured, and `/remember` must write to the backend
                        // `memory_search` reads.
                        sessionServices: toolExecutor.sessionServices,
                        conversationHistory: stack.conversationHistory,
                        sessionCatalog: LiveSessionCatalog(openGrokHome: openGrokHome),
                        // The connection outcomes `/mcps` renders — the tool
                        // executor recorded them when it brought the session's
                        // configured servers online.
                        mcpServers: toolExecutor.mcpServerConnections,
                        openGrokHome: openGrokHome,
                        // The paint ceiling: `GROK_MIN_DRAW_MS` wins, then the
                        // `[ui.display_refresh]` auto-cadence policy (inert
                        // until a display probe exists — `probedRefreshHz` is
                        // nil, which resolves to upstream's `probe_skip`
                        // default), then the 16 ms default.
                        paintCadence: PagerFrameClock.cadence(
                            environment: context.environment,
                            policy: Self.resolveDisplayRefreshPolicy(
                                workingDirectory: cwd,
                                environment: context.environment
                            ),
                            probedRefreshHz: nil
                        )
                    )
                    let controller = OpenGrokPagerInteractiveController(
                        input: interactiveInput.events,
                        runtime: runtime,
                        renderer: renderer,
                        output: SilentLiveInteractiveOutput(),
                        customCommands: skillCommands,
                        customCommandHandler: { invocation in
                            LiveSkills.invocationPrompt(
                                commandName: invocation.name,
                                args: invocation.arguments.joined(separator: " "),
                                catalog: foundation.skillCatalog,
                                sessionID: sessionID
                            )
                        },
                        localCommands: feedbackCommands,
                        localCommandHandler: { invocation in
                            guard invocation.name == "feedback" else { return nil }
                            let text = invocation.arguments.joined(separator: " ")
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else {
                                return "usage: /feedback <text>"
                            }
                            let outcome = try await foundation.feedback.submitText(text)
                            switch outcome {
                            case .persistedLocally:
                                return "feedback saved locally; this session is not eligible for upload"
                            case .persistedAndUploaded:
                                return "feedback uploaded"
                            case .persistedButUploadFailed:
                                return "feedback saved locally; upload failed"
                            }
                        },
                        workflowsEnabled: workflowsEnabled
                    )
                    // The render side reports what is moving (welcome logo,
                    // visible streaming blocks, finish flashes) and the
                    // controller's ticker arms or parks on it — this is what
                    // turns the welcome shimmer on with no turn running. The
                    // controller is captured weakly: it owns the renderer
                    // strongly, and a cycle here would keep both alive past
                    // shutdown.
                    await renderer.setMotionStateSink { [weak controller] state in
                        await controller?.setMotionState(state)
                    }
                    // Slash-command recency persists at
                    // `<opengrok home>/slash-mru.json`, upstream's grok_home
                    // location (`mru.rs:78-80`).
                    await controller.setSlashMru(PagerSlashMru(directory: openGrokHome))
                    // Typing `/model ` drops the dropdown into the catalog, as
                    // upstream's `ModelCommand::suggest_args` does. Rows insert
                    // the provider-qualified selector, so accepting one
                    // produces a command the resolver cannot find ambiguous.
                    let completionCatalog = stack.catalogStore.pickerEntries()
                    let activeModelID = providerConfiguration.initialModelID
                    let suggestionCatalogStore = stack.catalogStore
                    let suggestionCWD = cwd
                    await controller.setArgumentSuggestions { command, query in
                        switch command {
                        case "model", "m":
                            return LiveModelPicker.suggestions(
                                query: query,
                                entries: completionCatalog,
                                currentModelID: activeModelID
                            )
                        case "effort":
                            // The current model's effort menu with the active
                            // level marked (`EffortCommand::suggest_args` over
                            // `build_effort_arg_items`, effort.rs:44-55).
                            guard let entry = suggestionCatalogStore.currentModelEntry(),
                                  entry.supportsReasoningEffort
                            else { return [] }
                            let menu = LiveModelEffort.options(
                                supportsReasoningEffort: entry.supportsReasoningEffort,
                                declaredEfforts: entry.reasoningEfforts
                            )
                            let active = suggestionCatalogStore.currentReasoningEffort()
                            let needle = query
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .lowercased()
                            return menu
                                .filter { needle.isEmpty || $0.id.lowercased().contains(needle) }
                                .map { option in
                                    OpenGrokPagerCommandSuggestion(
                                        name: option.value == active
                                            ? "\(option.label) (active)"
                                            : option.label,
                                        summary: option.description ?? "",
                                        insertText: "/effort \(option.id)"
                                    )
                                }
                        case "export":
                            // Path completion for the export target
                            // (`list_path_completions`, export.rs:83-160).
                            return LiveExportPathSuggestions.suggestions(
                                query: query,
                                workingDirectory: suggestionCWD
                            )
                        default:
                            return []
                        }
                    }
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
                            exportBoundaries.remove(sessionID: sessionID)
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
                        exportBoundaries.remove(sessionID: sessionID)
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
                        exportBoundaries.remove(sessionID: sessionID)
                    }
                )
            }
        }
    }

    private static func makeLeaderLaunchSession(
        options: CLIExecutionOptions,
        prompt: String,
        workingDirectory: URL,
        lease: LiveLeaderClientLease,
        context: CLIApplicationContext,
        terminal: OpenGrokLiveTerminal
    ) async throws -> CLIApplicationSession {
        let runtime = LiveLeaderPagerRuntimeAdapter(
            client: lease.client,
            workingDirectory: workingDirectory
        )

        if options.mode == .interactive {
            guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                await lease.close()
                throw CLIApplicationError.failed(
                    "interactive leader mode requires a prompt when no local input controller is attached"
                )
            }
            let pagerMode = try Self.resolveInteractivePagerMode(
                options: options,
                terminal: terminal
            )
            let pager = OpenGrokPager(
                runtime: runtime,
                frontendFactory: LiveInteractiveFrontendFactory(
                    terminal: terminal,
                    prompt: prompt
                )
            )
            let request = OpenGrokPagerRequest(
                prompt: prompt,
                mode: pagerMode,
                metadata: ["mode": options.mode.rawValue]
            )
            let task = Task { try await pager.run(request) }
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
                    await lease.close()
                }
            )
        }

        let pager = OpenGrokPagerMinimal(
            runtime: runtime,
            renderer: PlainLivePagerRenderer(),
            output: LivePagerOutput(streams: context.streams, format: options.outputFormat)
        )
        let task = Task {
            try await pager.run(OpenGrokPagerMinimalRequest(
                prompt: prompt,
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
                await lease.close()
            }
        )
    }

    /// Root flags that the parser now accepts but that nothing downstream
    /// honors yet.
    ///
    /// Each of these narrows or redirects what the agent may do. Accepting one
    /// and ignoring it produces a run that is not merely incomplete but wrong
    /// in the user's favour-of-caution direction — a `--tools Read` run that
    /// quietly kept Bash, a `--worktree` run that edited the real checkout, a
    /// `--json-schema` run whose output does not match the schema. Refusing is
    /// the only honest option until the corresponding subsystem lands.
    ///
    /// Flags deliberately absent from this list:
    /// - `--verbatim` and `--include-partial-messages`: output-shaping
    ///   preferences whose wrong answer is incomplete streaming, not a silently
    ///   widened tool surface — tolerated until structured output honors them.
    /// - `--no-auto-update`: excluded while the update composition wires it.
    /// - Everything under `common.permissions`, which the permission and
    ///   sandbox layer consumes.
    /// `--reasoning-effort` left this list when `resolveSamplingConfiguration`
    /// started validating and applying it to the initial session.
    private static func unhonoredLaunchFlag(_ options: CLIExecutionOptions) -> String? {
        if options.agentOptions.tools != nil { return "--tools" }
        if options.agentOptions.disallowedTools != nil { return "--disallowed-tools" }
        if options.agentOptions.agent != nil { return "--agent" }
        if options.agentOptions.agentsJSON != nil { return "--agents" }
        if options.agentOptions.maxTurns != nil { return "--max-turns" }
        if options.agentOptions.noSubagents { return "--no-subagents" }
        if options.agentOptions.noPlan { return "--no-plan" }
        if options.agentOptions.noAskUser { return "--no-ask-user" }
        if options.agentOptions.rules != nil { return "--rules" }
        if options.agentOptions.systemPromptOverride != nil { return "--system-prompt-override" }
        if options.jsonSchema != nil { return "--json-schema" }
        if options.restoreCode { return "--restore-code" }
        if options.advanced.reauthenticate { return "--reauth" }
        if options.advanced.storageMode != nil { return "--storage-mode" }
        if options.advanced.clientIdentifier != nil { return "--client-identifier" }
        if options.advanced.hunkTrackerMode != nil { return "--hunk-tracker-mode" }
        if options.advanced.installer != nil { return "--installer" }
        if options.advanced.compactionMode != nil { return "--compaction-mode" }
        if options.advanced.compactionDetail != nil { return "--compaction-detail" }
        if options.advanced.terminal { return "--terminal" }
        if options.advanced.fsRead { return "--fs-read" }
        if options.advanced.fsWrite { return "--fs-write" }
        if options.advanced.todoGate { return "--todo-gate" }
        if options.advanced.logSampling { return "--log-sampling" }
        if options.advanced.noWaitForBackground { return "--no-wait-for-background" }
        // Default is 600 (`cli.rs:677-734`); any other value means the caller
        // set `--background-wait-timeout` explicitly.
        if options.advanced.backgroundWaitTimeoutSeconds != 600 { return "--background-wait-timeout" }
        if options.advanced.forceLogin { return "--force-login" }
        // Silently keeping the default host when the caller named another one
        // sends the request somewhere they did not ask for, which is worse than
        // refusing to start.
        if options.advanced.cliChatProxyBaseURL != nil { return "--cli-chat-proxy-base-url" }
        if options.advanced.xaiAPIBaseURL != nil { return "--xai-api-base-url" }
        return nil
    }

    private static func validateUnsupportedOptions(_ options: CLIExecutionOptions) throws {
        if !options.common.pluginDirectories.isEmpty {
            throw CLIApplicationError.unsupported(route: "plugins")
        }
        if options.common.mcpConfig != nil {
            throw CLIApplicationError.unsupported(route: "MCP config")
        }
        // `--restore-code` gets its own message because the generic one is
        // actively misleading now that rewind exists: a user who has seen
        // `/rewind` work will reasonably read "not honored yet" as "code
        // restoration is missing", when in fact it is present and this flag
        // means something else. Rust's `--restore-code` checks out the git
        // commit the session was pinned to; the rewind store restores file
        // snapshots. Same intent, different mechanism, and silently serving one
        // when the user asked for the other would be the wrong answer rather
        // than a missing one.
        if options.restoreCode {
            throw CLIApplicationError.unsupported(
                route: """
                --restore-code, which checks out the session's git commit — \
                not ported. To undo edits made in a session, resume it and use \
                /rewind, which restores files from per-prompt snapshots
                """
            )
        }
        if let flag = unhonoredLaunchFlag(options) {
            throw CLIApplicationError.unsupported(route: "\(flag), which nothing in this composition honors yet")
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
        // Root `--minimal` picks the scrollback-native renderer for an
        // interactive session. It is session-scoped and writes no config, so it
        // only reaches here; `--fullscreen` above already overrides it, and
        // `--no-alt-screen` wins because inline is the stricter request.
        if options.minimalRendering {
            // Scrollback-native rendering pins a live region above the prompt,
            // which needs a terminal to pin it to. Piped output falls back to
            // inline rather than failing, since unlike `--fullscreen` this flag
            // is a preference about presentation, not a hard requirement.
            return terminal.isTTY() ? .minimal : .inline
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

    // MARK: - Shared session construction

    /// Everything a live session needs before anything provider-facing exists.
    ///
    /// Split out of the launch closure so the `acp` route builds a session the
    /// same way an interactive or headless launch does. The split point is
    /// deliberate: a `--workflow` launch can finish and return between the two
    /// phases, so nothing here may depend on the agent stack, and the launch
    /// path keeps its original construction order exactly.
    struct LiveSessionFoundation: Sendable {
        let options: CLIExecutionOptions
        let cwd: URL
        let openGrokHome: URL
        let agentProfile: LiveAgentProfile?
        let sessionID: String
        let conversationRecord: LiveConversationRecord
        let conversationStore: LiveConversationStore
        let conversationHistory: LiveConversationHistory
        let securityContext: LiveSecurityContext
        let sandboxDecision: LiveSandboxDecision
        let samplingConfiguration: OpenGrokLiveSamplingConfiguration
        let sampler: OpenGrokLiveSampler
        let providerConfiguration: ProviderSessionConfiguration
        let processBackend: any ShellProcessBackend
        let permissionCoordinator: PagerPermissionCoordinator
        let telemetryBootstrapContext: LiveTelemetryBootstrapContext
        let toolExecutor: LiveToolExecutor
        let discoveredSkills: [SkillInfo]
        let skillCatalog: [LiveSkills.SkillCommand]
        let feedback: LiveFeedbackComposition
    }

    /// The provider-facing half: tool surface, Code Mode, history, `/model`
    /// switching and the turn driver those feed.
    ///
    /// `turnDriver` is exposed alongside `shell` because the ACP route drives
    /// turns through `ProviderBackedACPPromptDriver` rather than through the
    /// pager runtime, and both must be the *same* driver instance so an ACP
    /// prompt gets the identical tool gating, permission behavior, hooks and
    /// MCP tools a headless launch gets.
    struct LiveAgentStack: Sendable {
        let toolSurface: LiveCodeModeToolSurface
        let codeMode: LiveCodeModeCoordinator?
        let conversationHistory: LiveConversationHistory
        let catalogStore: LiveModelCatalogStore
        let modelSwitch: LiveModelSwitchCoordinator
        /// Exposed so the interactive controller can offer `/compact` and a
        /// `/usage` readout without rebuilding the model contract itself. The
        /// turn loop holds the same instance, so a manual compaction and the
        /// automatic one share a compaction counter.
        let compaction: LiveCompactionCoordinator
        let turnDriver: ProviderSessionTurnDriver
        let shell: OpenGrokShell
        /// Retained only so reachability tests can await the post-readiness
        /// launch update check; production callers ignore it.
        let launchAutoUpdateTask: Task<Void, Never>?
    }

    static func makeSessionFoundation(
        options: CLIExecutionOptions,
        context: CLIApplicationContext,
        dependencies: OpenGrokLiveCompositionDependencies
    ) async throws -> LiveSessionFoundation {
        let sourceCwd = try resolveWorkingDirectory(options.common.cwd)
        let openGrokHome = resolveOpenGrokHome(environment: context.environment)
        let worktreePreparation = try LiveWorktreeLaunch.prepare(
            options: options,
            sourceDirectory: sourceCwd,
            openGrokHome: openGrokHome,
            isCancelled: context.control.isCancelled
        )
        let cwd = worktreePreparation?.effectiveDirectory ?? sourceCwd
        let agentProfile = try resolveAgentProfile(
            named: options.common.profile,
            workingDirectory: cwd,
            environment: context.environment
        )
        let discoveredSkills: [SkillInfo]
        if agentProfile?.discoverSkills ?? true {
            discoveredSkills = LiveSkills.discover(cwd: cwd, environment: context.environment)
        } else {
            discoveredSkills = []
        }
        let skillCatalog = LiveSkills.commandCatalog(
            skills: discoveredSkills,
            reservedNames: OpenGrokPagerInteractiveController.builtinCommandNames
                .union(["feedback"])
        )
        let conversationStore = LiveConversationStore(openGrokHome: openGrokHome)
        var conversationRecord = try await resolveConversationRecord(
            options: options,
            lookupWorkingDirectory: sourceCwd,
            workingDirectory: cwd,
            store: conversationStore
        )
        let sessionID = conversationRecord.sessionID
        try LiveWorktreeLaunch.attachSession(worktreePreparation, sessionID: sessionID)
        let permissionCoordinator = PagerPermissionCoordinator()
        let fileAccessPolicy = resolveFileAccessPolicy(
            environment: context.environment,
            coordinator: permissionCoordinator
        )
        let securityContext = LiveSecurityContext.resolve(
            workspaceRoot: cwd.standardizedFileURL,
            environment: context.environment,
            isInteractive: fileAccessPolicy.isInteractive,
            cli: options.common.permissions
        )
        // Bootstrap owns the first irreversible process-wide operation. It
        // happens after the persisted record and effective cwd are known, but
        // before sampler, process backend, hooks, MCP transports, or tools are
        // constructed. Linux may replace this process with bubblewrap here.
        let sandboxDecision = try securityContext.applySandbox(
            workspaceRoot: cwd.standardizedFileURL,
            cliProfile: options.common.permissions.sandboxProfile,
            persistedProfile: conversationRecord.sandboxProfile,
            environment: context.environment
        )
        conversationRecord.sandboxProfile = sandboxDecision.profileName
        let (samplingConfiguration, credential) = try await resolveSamplingConfiguration(
            options: options,
            profileModel: agentProfile?.model,
            conversationRecord: conversationRecord,
            environment: context.environment,
            workingDirectory: cwd,
            openGrokHome: openGrokHome,
            sessionID: sessionID
        )
        let telemetryBootstrapContext = LiveTelemetryBootstrapContext(
            zeroDataRetention: credential.telemetryContext.zeroDataRetention,
            userID: credential.telemetryContext.userID,
            teamID: credential.telemetryContext.teamID
        )
        let launchHistory = LiveConversationHistory(
            record: conversationRecord,
            store: conversationStore
        )
        try await launchHistory.reconcileRoute(
            modelID: samplingConfiguration.model,
            provider: samplingConfiguration.provider
        )
        conversationRecord = await launchHistory.snapshot()
        let feedback = try await LiveFeedbackComposition.production(
            sessionID: sessionID,
            openGrokHome: openGrokHome,
            environment: context.environment,
            boundary: await launchHistory.sharedExportBoundary,
            transport: dependencies.makeImageTransport()
        )
        let sampler = try dependencies.makeSampler(samplingConfiguration)
        let providerConfiguration = makeProviderConfiguration(
            sessionID: sessionID,
            sampling: samplingConfiguration,
            credential: credential,
            openGrokHome: openGrokHome,
            environment: context.environment,
            everUsedNonXAI: conversationRecord.everUsedNonXAI
        )
        let processBackend = dependencies.makeProcessBackend()
        // The coordinator is created unconditionally and gates on whether a
        // presenter ever attaches, so headless and non-TTY runs keep the
        // fail-closed denial without a second construction path. An ACP
        // session never attaches a presenter, so it inherits that same
        // fail-closed behavior for free.
        let sessionServices = await makeSessionServices(
            sessionID: sessionID,
            workingDirectory: cwd,
            openGrokHome: openGrokHome,
            conversationRecord: conversationRecord,
            environment: context.environment,
            experimentalMemory: options.agentOptions.experimentalMemory,
            noMemory: options.agentOptions.noMemory
        )
        let toolExecutor = try await LiveToolExecutor(
            processBackend: processBackend,
            sessionID: sessionID,
            workingDirectory: cwd,
            toolPolicy: agentProfile?.toolPolicy,
            telemetryBootstrapContext: telemetryBootstrapContext,
            fileAccessPolicy: fileAccessPolicy,
            environment: context.environment,
            imageToolContext: LiveImageToolContext(
                availability: LiveImageToolComposition.resolveAvailability(
                    workingDirectory: cwd,
                    openGrokHome: openGrokHome,
                    environment: context.environment,
                    samplingProvider: samplingConfiguration.provider,
                    samplingAPIKey: samplingConfiguration.apiKey,
                    samplingBaseURL: samplingConfiguration.baseURL
                ),
                transport: dependencies.makeImageTransport()
            ),
            webToolContext: LiveWebToolContext(
                availability: LiveWebToolComposition.resolveAvailability(
                    workingDirectory: cwd,
                    openGrokHome: openGrokHome,
                    environment: context.environment,
                    samplingProvider: samplingConfiguration.provider,
                    samplingAPIKey: samplingConfiguration.apiKey,
                    samplingBaseURL: samplingConfiguration.baseURL,
                    disableWebSearch: options.agentOptions.disableWebSearch
                ),
                // Web requests reuse the image transport: same HTTP stack, same
                // test seam. Nothing about it is image-specific.
                transport: dependencies.makeImageTransport()
            ),
            sandboxDecision: sandboxDecision,
            securityContext: securityContext,
            sessionServices: sessionServices,
            permissionOptions: options.common.permissions
        )
        conversationRecord.sandboxProfile = sandboxDecision.profileName
        try await conversationStore.save(conversationRecord)
        return LiveSessionFoundation(
            options: options,
            cwd: cwd,
            openGrokHome: openGrokHome,
            agentProfile: agentProfile,
            sessionID: sessionID,
            conversationRecord: conversationRecord,
            conversationStore: conversationStore,
            conversationHistory: launchHistory,
            securityContext: securityContext,
            sandboxDecision: sandboxDecision,
            samplingConfiguration: samplingConfiguration,
            sampler: sampler,
            providerConfiguration: providerConfiguration,
            processBackend: processBackend,
            permissionCoordinator: permissionCoordinator,
            telemetryBootstrapContext: telemetryBootstrapContext,
            toolExecutor: toolExecutor,
            discoveredSkills: discoveredSkills,
            skillCatalog: skillCatalog,
            feedback: feedback
        )
    }

    static func makeAgentStack(
        foundation: LiveSessionFoundation,
        context: CLIApplicationContext,
        dependencies: OpenGrokLiveCompositionDependencies,
        launchAutoUpdate: LiveLaunchAutoUpdate.Request? = nil
    ) async -> LiveAgentStack {
        // Code Mode is a session-wide decision: the tool surface it
        // projects is fixed for the life of the timeline, which is what
        // makes a `wait` after a yield resolvable.
        let toolMode = LiveCodeModeSettings.resolveToolMode(
            environment: context.environment,
            workingDirectory: foundation.cwd,
            openGrokHome: foundation.openGrokHome,
            runtimeCapability: dependencies.makeCodeModeCapability()
        )
        let toolSurface = LiveCodeModeToolSurface(
            mode: toolMode,
            baseTools: foundation.toolExecutor.tools
        )
        let codeMode = toolSurface.isCodeMode
            ? LiveCodeModeCoordinator(
                surface: toolSurface,
                toolExecutor: foundation.toolExecutor,
                sessionID: foundation.sessionID,
                workingDirectory: foundation.cwd
            )
            : nil
        let conversationHistory = foundation.conversationHistory
        // The store reads the session's environment and home, not the
        // process's: `--cwd`/injected-env launches (and hermetic tests) must
        // see the same credential and endpoint chain the session resolved.
        let catalogStore = LiveModelCatalogStore(
            input: liveCatalogResolutionInput(
                workingDirectory: foundation.cwd,
                environment: context.environment
            ),
            environment: context.environment,
            openGrokHome: foundation.openGrokHome
        )
        // Post-readiness one-shot remote catalog refresh, upstream's
        // `spawn_background_refresh` (agent/models.rs:1817-1835, fired from
        // acp/spawn.rs:210 and app.rs:194/:1250 after session readiness).
        // Never awaited: a slow or failing provider catalog must not delay
        // the first prompt.
        catalogStore.spawnBackgroundRefresh()
        let launchAutoUpdateTask = LiveLaunchAutoUpdate.spawnIfNeeded(
            request: launchAutoUpdate,
            environment: context.environment,
            streams: context.streams
        )
        let configuredProviderDefinitions = parseConfiguredModelCatalog(
            from: ((try? loadAuthorityComposition(
                cwd: foundation.cwd,
                environment: context.environment
            ).effective()) ?? .table(TOMLTable())),
            environment: context.environment
        ).authProviders
        // `/model` rebuilds the provider stack through this coordinator; the
        // shell, session and tool runtime below are provider-independent and
        // survive a switch untouched.
        let modelSwitch = LiveModelSwitchCoordinator(
            sampling: foundation.samplingConfiguration,
            sampler: foundation.sampler,
            resolver: LiveModelCatalogResolver(
                environment: context.environment,
                openGrokHome: foundation.openGrokHome,
                sessionID: foundation.sessionID,
                workingDirectory: foundation.cwd,
                catalogSource: { catalogStore.snapshot() },
                authProviderDefinitions: { configuredProviderDefinitions }
            ),
            makeSampler: dependencies.makeSampler,
            history: conversationHistory
        )
        // A provider change invalidates the cells and stored values the
        // old runtime holds (model_switch.rs:249).
        await modelSwitch.attachCodeMode(codeMode)
        let compaction = LiveCompactionCoordinator(
            history: conversationHistory,
            modelSwitch: modelSwitch,
            sessionID: foundation.sessionID,
            openGrokHome: foundation.openGrokHome
        )
        let turnDriver = ProviderSessionTurnDriver(
            sampler: LiveShellSamplingDriver(
                modelSwitch: modelSwitch,
                toolExecutor: foundation.toolExecutor,
                conversationHistory: conversationHistory,
                systemPrompt: foundation.agentProfile?.systemPrompt,
                skillsListing: LiveSkills.listing(foundation.discoveredSkills),
                toolSurface: toolSurface,
                codeMode: codeMode,
                compaction: compaction
            )
        )
        let shell = OpenGrokShell(configuration: OpenGrokShellConfiguration(
            openGrokHome: foundation.openGrokHome,
            processBackend: foundation.processBackend,
            providerFactory: ProviderSessionFactoryAdapter(),
            turnDriver: turnDriver
        ))
        return LiveAgentStack(
            toolSurface: toolSurface,
            codeMode: codeMode,
            conversationHistory: conversationHistory,
            catalogStore: catalogStore,
            modelSwitch: modelSwitch,
            compaction: compaction,
            turnDriver: turnDriver,
            shell: shell,
            launchAutoUpdateTask: launchAutoUpdateTask
        )
    }

    /// The prompt driver the `acp` route uses.
    ///
    /// Builds the identical stack a headless launch builds, then drives turns
    /// through it — so an ACP `session/prompt` gets the same tool gating,
    /// fail-closed write permissions, hooks and MCP tools. Nothing about the
    /// stack is ACP-specific; only the thing consuming it differs.
    static func liveACPServices(
        dependencies: OpenGrokLiveCompositionDependencies
    ) -> LiveACPServices {
        LiveACPServices(makeComponents: { launch in
            let context = CLIApplicationContext(
                environment: launch.environment,
                streams: launch.streams,
                control: .never
            )
            let foundation = try await makeSessionFoundation(
                options: launch.options,
                context: context,
                dependencies: dependencies
            )
            let stack = await makeAgentStack(
                foundation: foundation,
                context: context,
                dependencies: dependencies
            )
            let providerSession = try ProviderSessionFactoryAdapter().makeSession(
                for: OpenGrokShellSessionRequest(
                    sessionID: SessionID(foundation.sessionID),
                    cwd: foundation.cwd,
                    providerConfiguration: foundation.providerConfiguration
                )
            )
            let promptDriver = LiveACPPromptDriver(
                driver: ProviderBackedACPPromptDriver(
                    providerSession: providerSession,
                    turnDriver: stack.turnDriver
                ),
                availableCommands: LiveSkills.availableCommands(
                    builtins: OpenGrokPagerInteractiveController.builtinCommandCatalog,
                    skills: foundation.skillCatalog
                ),
                skillCatalog: foundation.skillCatalog,
                shutdown: {
                    await stack.codeMode?.shutdown()
                    await foundation.toolExecutor.shutdown()
                }
            )
            let extensionRouter = ACPExtensionMethodRouter()
                .register(
                    exact: LiveFeedbackACPHandler.method,
                    handler: LiveFeedbackACPHandler(composition: foundation.feedback)
                )
            return LiveACPLaunchComponents(
                promptDriver: promptDriver,
                extensionHandler: extensionRouter
            )
        })
    }

    private static func resolveConversationRecord(
        options: CLIExecutionOptions,
        lookupWorkingDirectory: URL,
        workingDirectory: URL,
        store: LiveConversationStore
    ) async throws -> LiveConversationRecord {
        if options.continueSession, options.resume != nil {
            throw CLIApplicationError.failed("--resume and --continue cannot be used together")
        }

        // `--load` is the hidden `--resume` alias, so both spellings have to
        // reach the same lookup; `sessionToResume` folds them and drops the
        // "resume most recent" sentinel.
        let requestedResumeID = options.sessionToResume?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceRecord: LiveConversationRecord?
        if let requestedResumeID, !requestedResumeID.isEmpty {
            sourceRecord = try await store.load(sessionID: requestedResumeID)
        } else if options.resume != nil || options.loadSession != nil
                    || options.continueSession || options.forkSession {
            sourceRecord = try await store.latest(workingDirectory: lookupWorkingDirectory)
        } else {
            sourceRecord = nil
        }

        if options.forkSession {
            guard let sourceRecord else {
                throw CLIApplicationError.failed("no session is available to fork")
            }
            let destinationID = options.sessionID ?? UUID().uuidString
            return try await store.fork(
                sourceSessionID: sourceRecord.sessionID,
                destinationSessionID: destinationID,
                workingDirectory: workingDirectory
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
        conversationRecord: LiveConversationRecord,
        environment: [String: String],
        workingDirectory: URL,
        openGrokHome: URL,
        sessionID: String
    ) async throws -> (OpenGrokLiveSamplingConfiguration, LiveResolvedCredential) {
        let requestedProvider = try options.common.provider.map(resolveProvider)
        let embedded = embeddedDefaultModels()
        let explicitModel = options.common.model ?? profileModel
        let restoresStoredRoute = explicitModel == nil && requestedProvider == nil
        if restoresStoredRoute,
           conversationRecord.currentModelID != nil,
           conversationRecord.currentProvider == nil {
            throw CLIApplicationError.failed(
                "session \(conversationRecord.sessionID) has a stored model without a stored provider; refusing to guess a provider"
            )
        }
        if restoresStoredRoute,
           conversationRecord.currentModelID == nil,
           conversationRecord.currentProvider != nil {
            throw CLIApplicationError.failed(
                "session \(conversationRecord.sessionID) has a stored provider without a stored model; refusing to guess a model"
            )
        }
        let requestedModel = explicitModel ?? (restoresStoredRoute ? conversationRecord.currentModelID : nil)
        let restoredProvider = restoresStoredRoute ? conversationRecord.currentProvider : nil
        let configuredCatalog = liveConfiguredModelCatalog(
            workingDirectory: workingDirectory,
            environment: environment
        )
        let configuredCatalogMap = resolveModelCatalog(input: liveCatalogResolutionInput(
            workingDirectory: workingDirectory,
            environment: environment
        ))
        let routeProvider = requestedProvider ?? restoredProvider
        let configuredEntry = requestedModel.flatMap { requested in
            if let routeProvider {
                return configuredCatalogMap.pairs().first { pair in
                    let entry = pair.1
                    return entry.info.provider == routeProvider
                        && (pair.0 == requested || entry.model == requested)
                }?.1
            }
            return findModelByID(configuredCatalogMap, modelID: requested)
        }
        let embeddedModel = requestedModel.flatMap { requested in
            let matches = embedded.models.filter { model in
                (model.id ?? model.model) == requested || model.model == requested
            }
            if let routeProvider {
                return matches.first { $0.provider == routeProvider }
            }
            return matches.first
        }
        let knownModel = configuredEntry.map(DefaultModelJSON.fromCatalogEntry) ?? embeddedModel
        if let effectiveProvider = routeProvider,
           let knownModel,
           knownModel.provider != effectiveProvider {
            throw CLIApplicationError.failed(
                "model '\(requestedModel ?? knownModel.model)' belongs to provider \(knownModel.provider.asString), not \(effectiveProvider.asString)"
            )
        }

        let provider = routeProvider ?? knownModel?.provider ?? .xai
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
        let baseURL: String
        if let configuredEntry {
            baseURL = configuredEntry.apiBaseURL
                ?? configuredEntry.info.baseURL
        } else {
            baseURL = resolveProviderBaseURL(
                provider: provider,
                model: selectedProfile,
                environment: environment,
                configuredXaiBaseURL: provider == .xai
                    ? configuredXaiAPIBaseURL(
                        workingDirectory: workingDirectory,
                        openGrokHome: openGrokHome,
                        environment: environment
                    )
                    : nil
            )
        }
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
        let namedAuthResolver: NamedAuthProviderResolver?
        if let authProvider = configuredEntry?.authProvider {
            guard let definition = configuredCatalog.authProviders.first(where: { $0.0 == authProvider })?.1 else {
                throw CLIApplicationError.failed("named auth provider '\(authProvider)' is unavailable")
            }
            namedAuthResolver = NamedAuthProviderResolver(configuration: definition)
        } else {
            namedAuthResolver = nil
        }
        let explicitAPIKey: String?
        if let configuredEntry, namedAuthResolver == nil {
            if let configuredCredential = configuredEntry.ownCredential(environment: environment)
                ?? configuredEntry.envKey?.resolveValue(environment: environment) {
                explicitAPIKey = configuredCredential
            } else {
                explicitAPIKey = try resolveProviderAPIKey(
                    provider: provider,
                    model: selectedProfile,
                    baseURL: baseURL,
                    environment: environment
                )
            }
        } else if namedAuthResolver != nil {
            explicitAPIKey = nil
        } else {
            explicitAPIKey = try resolveProviderAPIKey(
                provider: provider,
                model: selectedProfile,
                baseURL: baseURL,
                environment: environment
            )
        }
        let resolver = LiveCredentialResolver(
            environment: environment,
            openGrokHome: openGrokHome,
            codexRefreshService: .live(
                endpoints: CodexEndpoints.fromEnvironment(environment),
                transport: URLSessionHTTPTransport()
            )
        )
        let credential: LiveResolvedCredential
        if let namedAuthResolver {
            guard let token = namedAuthResolver.currentToken(), !token.isEmpty else {
                throw CLIApplicationError.failed("named auth provider did not return a usable credential")
            }
            credential = LiveResolvedCredential(
                provider: provider,
                scope: "cli:\(sessionID)",
                source: .namedAuthProvider,
                authKind: .apiKeyOnly,
                bearer: token,
                binding: .apiKey(scope: "cli:\(sessionID)", key: token)
            )
        } else {
            do {
                // The resolved endpoint travels with the request so a stored
                // provider key is withheld from an untrusted host (upstream
                // resolve_credentials, agent/config.rs:5486-5503).
                credential = try await resolver.resolve(
                    provider: provider,
                    explicitAPIKey: explicitAPIKey,
                    baseURL: baseURL,
                    scope: "cli:\(sessionID)"
                )
            } catch let error as LiveCredentialError {
                throw CLIApplicationError.failed(error.description)
            }
        }
        let headers = mergeCredentialHeaders(
            provider: provider,
            credentialHeaders: credential.extraHeaders,
            configuredHeaders: configuredEntry?.info.extraHeaders ?? []
        )
        // The assembled catalog entry for the selected model carries the
        // tuning facts (effort menu, summary policy, sampling scalars) the
        // sampler config needs. `configuredEntry` already is that entry when
        // the user named a model; the default-model path re-looks it up by
        // catalog key so the embedded profile's derived fields (Codex
        // `.detailed` summary, multiAgentV2) are not lost in the
        // DefaultModelJSON projection.
        let tuningEntry = configuredEntry ?? selectedProfile.flatMap { profile in
            findModelByID(configuredCatalogMap, modelID: profile.id ?? profile.model)
        }
        let effortOverride = try resolveStartupReasoningEffort(
            token: options.agentOptions.reasoningEffort,
            supportsReasoningEffort: tuningEntry?.info.supportsReasoningEffort
                ?? selectedProfile?.supportsReasoningEffort
                ?? false,
            declaredEfforts: tuningEntry?.info.reasoningEfforts
                ?? selectedProfile?.reasoningEfforts
                ?? []
        )
        let tuning: OpenGrokLiveSamplingTuning
        if let tuningEntry {
            tuning = OpenGrokLiveSamplingTuning(entry: tuningEntry, effortOverride: effortOverride)
        } else if let profile = selectedProfile {
            // No assembled entry (e.g. an allowlist filtered it out): derive
            // from the embedded profile with the same Codex rules as
            // `defaultModelConfigs` (DefaultModels.swift:486, :494-495).
            tuning = OpenGrokLiveSamplingTuning(
                reasoningEffort: profile.supportsReasoningEffort
                    ? (effortOverride ?? profile.reasoningEffort)
                    : nil,
                reasoningSummary: profile.provider == .codex ? .detailed : nil,
                codexMultiAgentV2: profile.provider == .codex
                    && profile.multiAgentVersion == "v2",
                temperature: profile.temperature,
                topP: profile.topP,
                maxCompletionTokens: profile.maxCompletionTokens,
                contextWindow: profile.contextWindow
            )
        } else {
            tuning = OpenGrokLiveSamplingTuning()
        }
        let sampling = OpenGrokLiveSamplingConfiguration(
            model: model,
            baseURL: baseURL,
            apiKey: credential.bearer,
            provider: provider,
            apiBackend: apiBackend,
            extraHeaders: headers,
            queryParams: configuredEntry?.queryParams ?? [:],
            tuning: tuning,
            bearerResolver: namedAuthResolver.map(NamedAuthBearerResolver.init),
            credentialProvider: credential.binding.authCredentialProvider
        )
        return (sampling, credential)
    }

    /// Validate `--effort`/`--reasoning-effort` against the startup model.
    ///
    /// Port of `apply_headless_model_and_effort` (xai-grok-pager
    /// headless.rs:744-800): a model with no effort support *soft-ignores*
    /// the flag (upstream only logs a warning and still applies `-m`), while
    /// a genuinely unknown token hard-fails with the classified error copy —
    /// silently sending an unvalidated level would 400 on the API instead.
    static func resolveStartupReasoningEffort(
        token: String?,
        supportsReasoningEffort: Bool,
        declaredEfforts: [ReasoningEffortOption]
    ) throws -> ReasoningEffort? {
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else { return nil }
        switch LiveModelEffort.resolve(
            token: token,
            supportsReasoningEffort: supportsReasoningEffort,
            declaredEfforts: declaredEfforts
        ) {
        case .success(let effort):
            return effort
        case .failure(.unsupported):
            return nil
        case .failure(let error):
            throw CLIApplicationError.failed(
                "--effort/--reasoning-effort: \(error.message)"
            )
        }
    }

    /// Credential-owned headers must never be replaced by model metadata.
    /// This is especially important for Codex account pinning: a configured
    /// model may carry stale `ChatGPT-Account-ID` or authorization fields, but
    /// the selected provider's credential snapshot is the sole authority.
    static func mergeCredentialHeaders(
        provider: ModelProvider,
        credentialHeaders: [String: String],
        configuredHeaders: [(String, String)]
    ) -> [String: String] {
        let reserved = Set([
            "authorization",
            "x-api-key",
            "chatgpt-account-id",
            "x-openai-fedramp",
            codexAuthAnchorHeader,
            codexAccountAnchorHeader,
            codexUserAnchorHeader,
            codexWorkspaceAnchorHeader,
        ].map { $0.lowercased() })
        var merged = credentialHeaders
        for (name, value) in configuredHeaders {
            guard !reserved.contains(name.lowercased()) else { continue }
            merged[name] = value
        }
        if provider != .codex {
            for name in codexReservedAuthHeaders {
                merged.removeValue(forKey: name)
                merged = merged.filter { $0.key.lowercased() != name.lowercased() }
            }
        }
        return merged
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
            toolPolicy: LiveAgentToolPolicy(definition: definition),
            discoverSkills: definition.discoverSkills
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
        // Union of two upstream alias sets, so a provider name that works in
        // config also works on the flag: `ModelProvider.init(from:)` decodes the
        // underscore spellings, and upstream's CLI `provider_action`
        // (slash/commands/login.rs:78) additionally accepts the hyphen forms
        // plus the short `opencode` / `go` selectors.
        case "deepseek", "deep_seek", "deep-seek", "deepseek_api", "deepseek-api":
            return .deepseek
        // Upstream accepts Meta at the CLI/pager level: `from_provider_name`
        // (app/app_view.rs:441-446: meta, meta_ai, meta-api) plus
        // `provider_action`'s meta-ai (login.rs:96); `ModelProvider` decode
        // adds meta_api. Rejecting it here was a B3-CLI-1 leftover from
        // before the Meta provider went end-to-end.
        case "meta", "meta_ai", "meta-ai", "meta_api", "meta-api":
            return .meta
        case "opencode_go", "opencode-go", "opencode", "go":
            return .openCodeGo
        case "wafer", "wafer_ai", "wafer-ai":
            return .wafer
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
        // Meta is Responses-only (types.rs:1349-1362), same reset target as
        // the provider-override mapping in agent/config.rs:4545-4553.
        case .codex, .meta:
            return .responses
        case .kimi, .fireworks, .deepseek, .openCodeGo, .wafer:
            return .chatCompletions
        }
    }

    /// `[endpoints] xai_api_base_url` — the only endpoint override upstream
    /// defines for the public xAI API (`agent/config.rs:233`).
    ///
    /// Upstream's precedence falls out of how it builds the table:
    /// `EndpointsConfig::from_config_value` (`agent/config.rs:365`) serializes
    /// `Default::default()` — whose `xai_api_base_url` reads
    /// `GROK_XAI_API_BASE_URL`, else the compiled default
    /// (`agent/config.rs:622`) — and then deep-merges the effective config's
    /// `[endpoints]` table over it. So the config file beats the environment,
    /// which beats the compiled default.
    ///
    /// Layering matches `LiveCodeModeSettings.resolveToolMode`: the project
    /// config chain first, then `$OPENGROK_HOME/config.toml`.
    static func configuredXaiAPIBaseURL(
        workingDirectory: URL,
        openGrokHome: URL,
        environment: [String: String]
    ) -> String? {
        let project = loadMergedProjectConfig(
            cwd: workingDirectory,
            environment: environment
        )
        if let value = endpointsXaiAPIBaseURL(in: project) { return value }
        let userConfig = try? loadConfigFile(
            at: openGrokHome.appendingPathComponent("config.toml")
        )
        if let userConfig, let value = endpointsXaiAPIBaseURL(in: userConfig) {
            return value
        }
        return nil
    }

    private static func endpointsXaiAPIBaseURL(in table: TOMLValue) -> String? {
        guard case .string(let raw)? = table[path: ["endpoints", "xai_api_base_url"]] else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The `[ui.display_refresh]` policy the paint cadence resolves from
    /// (`DisplayRefreshSettings`, UIConfig.swift:214-221 for the key names;
    /// defaults per `defaults_probe_on_auto_off`, display_refresh.rs:367-378).
    /// Read from the same config chain the rest of the session uses; a key
    /// with the wrong type falls back to its default, matching the tolerant
    /// decoder on the Codable twin.
    static func resolveDisplayRefreshPolicy(
        workingDirectory: URL,
        environment: [String: String]
    ) -> PagerDisplayRefreshPolicy {
        let document = (try? loadAuthorityComposition(
            cwd: workingDirectory,
            environment: environment
        ).effective()) ?? .table(TOMLTable())
        func flag(_ key: String) -> Bool? {
            document[path: ["ui", "display_refresh", key]]?.boolValue
        }
        func integer(_ key: String) -> Int? {
            document[path: ["ui", "display_refresh", key]]?.int64Value.map(Int.init)
        }
        let defaults = PagerDisplayRefreshPolicy()
        return PagerDisplayRefreshPolicy(
            probeEnabled: flag("probe_enabled") ?? defaults.probeEnabled,
            autoCadenceEnabled: flag("auto_cadence_enabled") ?? defaults.autoCadenceEnabled,
            floorMs: integer("floor_ms") ?? defaults.floorMs,
            ceilingMs: integer("ceiling_ms") ?? defaults.ceilingMs,
            minHz: integer("min_hz") ?? defaults.minHz,
            maxHz: integer("max_hz") ?? defaults.maxHz
        )
    }

    static func resolveProviderBaseURL(
        provider: ModelProvider,
        model: DefaultModelJSON?,
        environment: [String: String],
        configuredXaiBaseURL: String? = nil
    ) -> String {
        let overrideKey: String
        let fallback: String
        switch provider {
        case .xai:
            // Config beats env for xAI, per `from_config_value`'s deep merge.
            if let configuredXaiBaseURL { return configuredXaiBaseURL }
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
        case .deepseek:
            overrideKey = DeepSeekModels.apiBaseURLEnv
            fallback = model?.apiBaseURL ?? model?.baseURL ?? DeepSeekModels.apiBaseURLDefault
        case .openCodeGo:
            overrideKey = OpenCodeGoModels.apiBaseURLEnv
            fallback = model?.apiBaseURL ?? model?.baseURL ?? OpenCodeGoModels.apiBaseURLDefault
        case .wafer:
            overrideKey = WaferModels.apiBaseURLEnv
            fallback = model?.apiBaseURL ?? model?.baseURL ?? WaferModels.apiBaseURLDefault
        case .meta:
            // Meta endpoint constants (meta_models.rs:14-16): the
            // OPENGROK_META_API_BASE_URL override, else the model's own URL,
            // else https://api.meta.ai/v1 — the same ladder as the other
            // API-key providers.
            overrideKey = MetaModels.apiBaseURLEnv
            fallback = model?.apiBaseURL ?? model?.baseURL ?? MetaModels.apiBaseURLDefault
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
        case .deepseek:
            keys = [DeepSeekModels.apiKeyEnv]
        case .openCodeGo:
            keys = [OpenCodeGoModels.apiKeyEnv]
        case .wafer:
            keys = [WaferModels.apiKeyEnv]
        case .meta:
            // META_API_KEY (meta_models.rs:16, :74-76).
            keys = [MetaModels.apiKeyEnv]
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
        case .deepseek:
            return DeepSeekModels.apiKeyEnv
        case .meta:
            // Upstream's Meta credential env key (meta_models.rs:16).
            return "META_API_KEY"
        case .openCodeGo:
            return OpenCodeGoModels.apiKeyEnv
        case .wafer:
            return WaferModels.apiKeyEnv
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
        environment: [String: String],
        everUsedNonXAI: Bool?
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
            environment: environment,
            everUsedNonXAI: everUsedNonXAI
        )
    }
}

/// Rejects every prompt-requiring access with an actionable message instead of
/// hanging on a prompt no terminal is listening for.
struct LiveWriteDenialPrompter: PermissionPrompter {
    func prompt(
        access: AccessKind,
        toolName: String,
        toolCallId: String
    ) async -> PermissionDecision {
        _ = toolCallId
        return .reject(LiveWriteDenialPrompter.denialMessage(
            toolName: toolName,
            access: access
        ))
    }

    /// Shell commands reach this prompter too now that `run_terminal_cmd` is
    /// gated, and "would modify files" is the wrong sentence for one — so the
    /// message names the actual access.
    static func denialMessage(toolName: String, access: AccessKind? = nil) -> String {
        let suffix = " Set OPENGROK_ALLOW_WRITES=1 to allow them."
        switch access {
        case .bash:
            return "'\(toolName)' needs approval to run a shell command, and no "
                + "approval prompt is available in this session." + suffix
        case .edit, .none:
            return "'\(toolName)' would modify files, and file mutations are "
                + "disabled for this session." + suffix
        default:
            return "'\(toolName)' needs approval, and no approval prompt is "
                + "available in this session." + suffix
        }
    }
}

/// "Allow for the rest of the session", held outside the coordinator so a
/// second access never re-prompts once the user has said yes.
///
/// Scoped per access kind. A single `allowsAll` flag meant that approving one
/// file edit also pre-approved every later edit *and*, now that shell is gated,
/// every later shell command — which is not what "allow for this session" on a
/// write prompt says. Bash grants are held per command prefix, matching the
/// `bashPrefixGrants` the permission engine already models.
actor LiveSessionWritePolicy {
    private var allowsEdits = false
    private var bashPrefixGrants: [String] = []
    private var otherGrants: Set<String> = []

    init() {}

    func isAllowed(_ access: AccessKind) -> Bool {
        switch access {
        case .edit:
            return allowsEdits
        case .bash(let command):
            let trimmed = command.trimmingCharacters(in: .whitespaces)
            return bashPrefixGrants.contains { !$0.isEmpty && trimmed.hasPrefix($0) }
        case .read, .grep, .webSearch:
            return true
        case .webFetch(let url):
            return otherGrants.contains(url)
        case .mcpTool(let name, _):
            return otherGrants.contains(name)
        }
    }

    func allowForSession(_ access: AccessKind) {
        switch access {
        case .edit:
            allowsEdits = true
        case .bash(let command):
            // Grant the whole command as its own prefix: a session grant for
            // `npm test` must not also cover `npm publish`.
            let trimmed = command.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { bashPrefixGrants.append(trimmed) }
        case .webFetch(let url):
            otherGrants.insert(url)
        case .mcpTool(let name, _):
            otherGrants.insert(name)
        case .read, .grep, .webSearch:
            break
        }
    }
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
        if await sessionPolicy.isAllowed(access) { return .allow }
        guard await coordinator.hasPresenter else {
            return .reject(LiveWriteDenialPrompter.denialMessage(
                toolName: toolName,
                access: access
            ))
        }
        let request = PagerPermissionRequest(
            id: toolCallId.isEmpty ? UUID().uuidString : toolCallId,
            toolName: toolName,
            targetPath: Self.targetPath(for: access),
            detail: Self.detail(for: access)
        )
        switch await coordinator.decision(for: request) {
        case .allowOnce:
            return .allow
        case .allowSession:
            await sessionPolicy.allowForSession(access)
            return .allow
        case .deny:
            return .reject("'\(toolName)' was denied.")
        }
    }

    /// Second line of the sheet.
    ///
    /// For a protected edit target this is the reason that edit is dangerous —
    /// `.opengrok/hooks/**`, `.claude/settings.json`, a shell startup file and
    /// the rest all install something that runs later without a separate
    /// execution approval, and the user cannot weigh the prompt without being
    /// told that. The classifier existed but returned a bare `Bool`, so the
    /// explanation never reached anyone.
    private static func detail(for access: AccessKind) -> String? {
        guard case .edit(let path) = access else { return nil }
        return protectedEditReason(path, userGrokHome: userGrokHome()?.path)?.explanation
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

/// Config, folder trust, and the permission policy for one session, resolved
/// together because each depends on the one before it.
///
/// Before this existed the live path called `loadEffectiveConfigDiskOnly`,
/// which merges only systemManaged → managed → user → requirements: a repo's
/// `.opengrok/config.toml` was silently dropped, and nothing read `[permission]`
/// at all, so the rule engine ran over an empty policy.
struct LiveSecurityContext: Sendable {
    /// Full authority chain: built-ins < user < project < env < CLI + managed.
    var document: TOMLValue
    /// Whether this workspace may load repo-local code-exec config.
    var projectTrusted: Bool
    var permissions: ResolvedPermissions
    /// Requirements layers, kept so the sandbox can apply the same admin
    /// precedence the permission resolver did.
    var requirements: [TOMLValue]

    /// Resolve for `workspaceRoot`.
    ///
    /// Folder trust is decided **first** and gates the project tier: an
    /// untrusted repo's `.opengrok/config.toml` never enters the merge, so it
    /// can neither declare MCP servers nor widen its own permission rules.
    static func resolve(
        workspaceRoot: URL,
        environment: [String: String],
        isInteractive: Bool,
        // `--allow` / `--deny` / `--permission-mode` / `--always-approve` /
        // `--trust`, parsed by the root CLI parser. This is the tier that lets
        // a scripted user authorize a command through the supported path
        // instead of an environment-variable bypass.
        cli: CLIPermissionOptions = CLIPermissionOptions()
    ) -> LiveSecurityContext {
        // One disk load, reused for the trust flag, the merge and the sandbox.
        let layers = try? ConfigLayers.load(environment: environment)
        // The base chain without the project tier, used to read the folder
        // trust feature flag itself — a repo must not be able to switch off
        // the gate that is deciding whether to read it.
        let base = layers?.effectiveConfigBase() ?? .table(TOMLTable())

        let featureEnabled = folderTrustEnabled(document: base, environment: environment)
        let store = PersistentFolderTrustStore(environment: environment)
        let outcome = decideFolderTrust(
            featureEnabled: featureEnabled,
            inputs: FolderTrustDecideInputs(
                storeTrusted: store.isTrusted(workspaceRoot),
                repoConfigsPresent: repoConfigsPresent(at: workspaceRoot),
                isInteractive: isInteractive,
                keyRecordable: !isUnsafeTrustRoot(
                    workspaceRoot.path,
                    home: environment["HOME"]
                )
            )
        )
        // `.prompt` is "not yet decided". Until the pager can raise a trust
        // sheet, an undecided folder is treated as untrusted — the failure mode
        // is a repo whose servers do not start, not one whose servers run.
        // `--trust` is the explicit answer to that undecided case.
        let projectTrusted = outcome == .trusted || cli.trustFolder

        // Passing `cwd: nil` for an untrusted folder is the whole gate: the
        // project chain is never discovered, so its MCP servers, hooks and
        // permission rules cannot enter the merged document.
        let project: TOMLValue = projectTrusted
            ? loadMergedProjectConfig(
                cwd: workspaceRoot,
                userHome: userGrokHome(environment: environment),
                environment: environment
            )
            : .table(TOMLTable())
        let document = layers.map {
            AuthorityComposition.from(layers: $0, project: project).effective()
        } ?? base

        let requirements = [
            layers?.userRequirements,
            layers?.systemRequirements,
            layers?.mdmRequirements,
        ].compactMap { $0 }

        let home = URL(
            fileURLWithPath: environment["HOME"] ?? NSHomeDirectory()
        )
        // Each `[permission]` layer is passed separately with its own trust
        // tier, never as the merged document: `deepMergeTOML` replaces arrays,
        // so a user `config.toml` deny list would otherwise overwrite the
        // managed one instead of adding to it. Tiering matters too — only
        // system requirements and managed settings are admin tier, so a
        // *user's* requirements.toml cannot smuggle a catch-all allow past the
        // YOLO pin.
        var permissionLayers: [(document: TOMLValue, source: PermissionRuleSource)] = []
        if let systemRequirements = layers?.systemRequirements {
            permissionLayers.append((systemRequirements, .systemRequirements))
        }
        if let mdmRequirements = layers?.mdmRequirements {
            permissionLayers.append((mdmRequirements, .systemRequirements))
        }
        if let userRequirements = layers?.userRequirements {
            permissionLayers.append((userRequirements, .requirements))
        }
        if let systemManaged = layers?.systemManaged {
            permissionLayers.append((systemManaged, .managedConfig))
        }
        if let managed = layers?.managed {
            permissionLayers.append((managed, .managedConfig))
        }
        if let user = layers?.user {
            permissionLayers.append((user, .config))
        }
        // Absent entirely when the folder is untrusted.
        if projectTrusted {
            permissionLayers.append((project, .config))
        }

        let permissions = resolvePermissions(PermissionResolutionInputs(
            permissionLayers: permissionLayers,
            requirementsLayers: requirements,
            managedSettings: loadManagedSettingsPermissions(environment: environment),
            cwd: workspaceRoot,
            home: home,
            projectTrusted: projectTrusted,
            cliAllowRules: cli.allowRules,
            cliDenyRules: cli.denyRules,
            cliMode: cli.mode.map { DefaultPermissionMode(parsing: $0.rawValue) },
            cliAlwaysApprove: cli.alwaysApprove
        ))

        return LiveSecurityContext(
            document: document,
            projectTrusted: projectTrusted,
            permissions: permissions,
            requirements: requirements
        )
    }

    /// Apply the configured OS sandbox, if any.
    ///
    /// Returns the profile name to persist with the session so a resume cannot
    /// silently come back weaker. Throws `SandboxError` when a profile was
    /// requested and could not be enforced — never degrades silently.
    func applySandbox(
        workspaceRoot: URL,
        cliProfile: String?,
        persistedProfile: String?,
        environment: [String: String],
        runtime: (any LiveSandboxRuntime)? = nil
    ) throws -> LiveSandboxDecision {
        if let runtime {
            return try LiveSandboxComposition.bootstrap(
                workspaceRoot: workspaceRoot,
                document: document,
                requirements: requirements,
                cliProfile: cliProfile,
                persistedProfile: persistedProfile,
                environment: environment,
                runtime: runtime
            )
        }
        return try LiveSandboxComposition.bootstrap(
            workspaceRoot: workspaceRoot,
            document: document,
            requirements: requirements,
            cliProfile: cliProfile,
            persistedProfile: persistedProfile,
            environment: environment
        )
    }

    /// Vendor `managed-settings.json` — admin tier, so it is read regardless of
    /// folder trust.
    private static func loadManagedSettingsPermissions(
        environment: [String: String]
    ) -> ClaudeSettingsPermissions? {
        _ = environment
        guard let path = claudeManagedSettingsPath(),
              let data = try? Data(contentsOf: path) else { return nil }
        return parseClaudeSettingsJSON(data)
    }
}

struct LiveToolExecutor: Sendable {
    let tools: [ToolSpec]
    let workingDirectory: URL
    private let composition: OpenGrokShellToolRuntimeComposition
    private let fileToolBridge: ToolBridge
    private let registryToolNames: Set<String>
    /// The same gate the file tools run through. `run_terminal_cmd` used to
    /// dispatch straight to `composition.invoke`, so shell execution never saw
    /// a deny rule, a PreToolUse hook, or the permission modal.
    private let permissionPipeline: PermissionPipeline?
    private let hookPermissionGate: HookPermissionGate?
    /// The OS sandbox this session runs under. `profileName` is what a session
    /// writer persists so a resume is pinned to the same profile.
    let sandbox: LiveSandboxDecision
    /// Which of `get_task_output` / `wait_tasks` / `kill_task` this session
    /// actually advertised. Only an advertised name is dispatched, so a profile
    /// that filtered one out cannot reach it by calling it anyway.
    private let backgroundTaskToolNames: Set<String>
    private let mcpConnections: MCPSessionConnections
    /// Per-server connection outcomes recorded when the session brought its
    /// configured MCP servers online. `/mcps` renders these; before they were
    /// captured, `connectConfiguredServers`' report was discarded and the
    /// session had no way to say which server failed or why.
    let mcpServerConnections: [MCPServerConnection]
    /// Rewind snapshots, memory and goals. Optional so every construction site
    /// that predates them keeps compiling and simply advertises none of their
    /// tools; see `LiveSessionServices.swift`.
    let sessionServices: LiveSessionServices?
    let telemetryStatus: LiveTelemetryStatus

    init(
        processBackend: any ShellProcessBackend,
        sessionID: String,
        workingDirectory: URL,
        toolPolicy: LiveAgentToolPolicy?,
        telemetryBootstrapContext: LiveTelemetryBootstrapContext,
        fileAccessPolicy: FileToolAccessPolicy = .denyByDefault,
        // Hooks and MCP servers are discovered from config and environment, and
        // both of them *spawn processes*. Taking the environment as an argument
        // keeps that discovery bound to the caller's session rather than to
        // whatever `ProcessInfo` happens to hold, so a test can build an
        // executor without picking up the developer's real hooks and servers.
        environment: [String: String] = ProcessInfo.processInfo.environment,
        // Image-tool availability is a *credential* decision, so it needs the
        // session's resolved sampling identity. Defaulted so the many
        // construction sites that predate the image tools keep compiling; a
        // session that passes nothing simply never advertises them.
        imageToolContext: LiveImageToolContext? = nil,
        // Web-tool availability is likewise a credential decision — plus the
        // `--disable-web-search` switch. Defaulted so construction sites that
        // predate the web tools keep compiling and simply advertise nothing.
        webToolContext: LiveWebToolContext? = nil,
        // Foundation and workflow children pass the auth-derived policy from
        // the parent session; standalone fixtures must choose an explicit
        // context rather than silently defaulting to telemetry-enabled.
        sandboxDecision: LiveSandboxDecision? = nil,
        securityContext: LiveSecurityContext? = nil,
        // The `sandbox_profile` a resumed session was created under. A resume
        // that would weaken it is refused rather than silently downgraded.
        persistedSandboxProfile: String? = nil,
        // Rewind / memory / goals. Defaulted to nil so a session that opts into
        // none of them advertises no extra tools and writes nothing to disk.
        sessionServices: LiveSessionServices? = nil,
        // `common.permissions` from the root parser. Defaulted so the many
        // construction sites that predate the flags keep compiling; a session
        // that passes nothing simply has no CLI permission tier.
        permissionOptions: CLIPermissionOptions = CLIPermissionOptions(),
        sandboxAutoAllowBash: (@Sendable () -> Bool)? = nil
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
        let hooks = LiveHooksComposition.load(
            sessionId: sessionID,
            workspaceRoot: standardizedWorkingDirectory,
            environment: environment
        )
        // Config precedence, folder trust and the permission policy, resolved
        // once and shared by the file tools, `run_terminal_cmd` and MCP.
        let security = securityContext ?? LiveSecurityContext.resolve(
            workspaceRoot: standardizedWorkingDirectory,
            environment: environment,
            isInteractive: fileAccessPolicy.isInteractive,
            cli: permissionOptions
        )
        // Deliberately `bootstrapFromDisk` rather than the security context's
        // already-loaded document: that document carries the project tier, and
        // upstream has no project layer for telemetry. Passing it would let a
        // repo's checked-in `.opengrok/config.toml` enable telemetry for
        // everyone who clones it. Pinned by `projectConfigCannotEnableTelemetry`.
        self.telemetryStatus = LiveTelemetry.bootstrapFromDisk(
            environment: environment,
            zeroDataRetention: telemetryBootstrapContext.zeroDataRetention,
            userID: telemetryBootstrapContext.userID,
            teamID: telemetryBootstrapContext.teamID
        )
        // Applied before any tool can run. A configured-but-unenforceable
        // profile throws out of `init`, so the session refuses to start rather
        // than running unsandboxed after the user asked for one.
        if let sandboxDecision {
            self.sandbox = sandboxDecision
        } else {
            self.sandbox = try security.applySandbox(
                workspaceRoot: standardizedWorkingDirectory,
                cliProfile: permissionOptions.sandboxProfile,
                persistedProfile: persistedSandboxProfile,
                environment: environment
            )
        }
        let sandboxIsEnforced = self.sandbox.enforced
        let sandboxPredicate: @Sendable () -> Bool = sandboxAutoAllowBash ?? {
            sandboxIsEnforced && shouldAutoAllowBash()
        }
        let fileToolResources = FileToolSession.makeResources(
            workspaceRoot: standardizedWorkingDirectory.path,
            sessionId: sessionID,
            agentId: "main",
            policy: fileAccessPolicy,
            hooks: hooks.gate.map { $0 as any PreToolUseHookRunner } ?? FailOpenPreToolUseHookRunner(),
            resolved: security.permissions,
            sandboxAutoAllowBash: sandboxPredicate
        )
        // The build pack plus, when the session's credentials allow it, the
        // image tools. Both go through one `finalize`, so image tools inherit
        // the same capability filter, permission pipeline and dispatch path.
        var builder = FileToolPack.makeBuilder()
        var toolConfig = toolServerConfig(
            for: .build,
            catalogKinds: builder.knownToolKinds()
        )
        if let imageToolContext {
            let availability = imageToolContext.availability
            if availability.advertisesAnything,
               let imageClient = try? ImageGenClient(
                   config: availability.config,
                   transport: imageToolContext.transport
               ) {
                let handler = LiveImageToolHandler(client: imageClient)
                let kinds = BuiltinToolCatalog.mediaToolKinds
                if availability.imageGenEnabled {
                    builder.setHandler(
                        qualifiedId: BuiltinToolCatalog.imageGenQualifiedId,
                        handler: handler
                    )
                    toolConfig.tools.append(ToolConfig.fromId(
                        BuiltinToolCatalog.imageGenQualifiedId,
                        kind: kinds[BuiltinToolCatalog.imageGenQualifiedId]
                    ))
                }
                if availability.imageEditEnabled {
                    builder.setHandler(
                        qualifiedId: BuiltinToolCatalog.imageEditQualifiedId,
                        handler: handler
                    )
                    toolConfig.tools.append(ToolConfig.fromId(
                        BuiltinToolCatalog.imageEditQualifiedId,
                        kind: kinds[BuiltinToolCatalog.imageEditQualifiedId]
                    ))
                }
            }
        }
        // `todo_write` needs no credentials and no configuration — its whole
        // backing state is this session's in-memory list — so unlike the image
        // and web tools it is registered unconditionally and gated only by the
        // agent profile.
        builder.setHandler(
            qualifiedId: BuiltinToolCatalog.todoWriteQualifiedId,
            handler: LiveTodoToolHandler(store: LiveTodoStore())
        )
        toolConfig.tools.append(ToolConfig.fromId(
            BuiltinToolCatalog.todoWriteQualifiedId,
            kind: BuiltinToolCatalog.sessionStateToolKinds[BuiltinToolCatalog.todoWriteQualifiedId]
        ))
        if let webToolContext {
            let availability = webToolContext.availability
            if availability.advertisesAnything {
                // A session with `web_fetch` but no search backend still gets a
                // handler; `searchClient` stays nil and only the search arms
                // refuse. Fetching a URL needs no API key.
                let searchClient = availability.searchConfig.isEnabled
                    ? try? WebSearchClient(
                        configuration: availability.searchConfig,
                        transport: webToolContext.transport
                    )
                    : nil
                let handler = LiveWebToolHandler(
                    searchClient: searchClient,
                    fetchClient: WebFetchClient(
                        transport: webToolContext.transport,
                        environment: environment
                    )
                )
                let kinds = BuiltinToolCatalog.webToolKinds
                let advertised: [(Bool, String)] = [
                    (availability.webSearchEnabled && searchClient != nil,
                     BuiltinToolCatalog.webSearchQualifiedId),
                    (availability.webFetchEnabled,
                     BuiltinToolCatalog.webFetchQualifiedId),
                    (availability.xSearchEnabled && searchClient != nil,
                     BuiltinToolCatalog.xSearchQualifiedId),
                ]
                for (enabled, qualifiedId) in advertised where enabled {
                    builder.setHandler(qualifiedId: qualifiedId, handler: handler)
                    toolConfig.tools.append(ToolConfig.fromId(
                        qualifiedId,
                        kind: kinds[qualifiedId]
                    ))
                }
            }
        }
        let fileToolBridge = try ToolBridge.finalize(
            builder: builder,
            config: toolConfig,
            resources: fileToolResources,
            options: FinalizeOptions(
                capabilityMode: Self.capabilityMode(for: toolPolicy)
            )
        )
        let mcpConnections = MCPSessionConnections()
        // `security.document` already excludes the project tier when the folder
        // is untrusted, so a hostile repo's `.opengrok/config.toml` servers are
        // simply not present here — they never reach `makeTransport`, which is
        // what spawns the process.
        let mcpServerConnections = await LiveMCPComposition.connectConfiguredServers(
            document: security.document,
            toolset: fileToolBridge.toolset,
            connections: mcpConnections,
            environment: environment
        )
        let fileToolDefinitions = fileToolBridge.toolDefinitions()
        let allowedFileToolDefinitions = fileToolDefinitions.filter {
            toolPolicy?.allows(liveToolName: $0.name) ?? true
        }
        // The background-task consumers only make sense alongside the producer:
        // without `run_terminal_cmd` there is no task for them to read, wait on
        // or kill. Upstream registers all three in every preset that has bash
        // (`xai-grok-tools/src/registry/types.rs:694-701`) for the same reason.
        let backgroundTaskTools: [ToolSpec]
        let terminalTools: [ToolSpec]
        if toolPolicy?.allows(liveToolName: Self.runTerminalTool.name) == false {
            backgroundTaskTools = []
            terminalTools = []
        } else {
            backgroundTaskTools = LiveBackgroundTaskTools
                .toolSpecs(environment: environment)
                .filter { toolPolicy?.allows(liveToolName: $0.name) ?? true }
            terminalTools = [Self.runTerminalTool] + backgroundTaskTools
        }
        self.backgroundTaskToolNames = Set(backgroundTaskTools.map(\.name))
        self.permissionPipeline = fileToolResources.permissionPipeline
        self.hookPermissionGate = hooks.gate
        self.composition = composition
        self.fileToolBridge = fileToolBridge
        self.mcpConnections = mcpConnections
        self.mcpServerConnections = mcpServerConnections
        self.registryToolNames = Set(allowedFileToolDefinitions.map(\.name))
        self.workingDirectory = standardizedWorkingDirectory
        self.sessionServices = sessionServices
        // Session-service tools run through the same agent-profile gate as
        // every other tool, so a read-only profile that denies `memory_search`
        // does not get it back through this door.
        let sessionTools = (sessionServices?.toolSpecs ?? [])
            .filter { toolPolicy?.allows(liveToolName: $0.name) ?? true }
        // `invoke` checks the session-service branch BEFORE everything else, so
        // a session tool sharing a name with any other dispatched tool would
        // silently win — and win the wrong way. It matters differently for the
        // two branches it can shadow:
        //
        //   * a registry tool loses the capability filter, PreToolUse hooks and
        //     the permission pipeline that `ToolBridge` applies;
        //   * `run_terminal_cmd` or a background-task tool loses `gateTerminalCommand`
        //     / the `kill_task` gate — security checks someone deliberately
        //     wrote, which is strictly worse than being merely unfiltered.
        //
        // Precedence-first is the right trade only for session-state RPCs with
        // no filesystem or process surface (`memory_search`, `update_goal`),
        // where being shadowed by a same-named MCP tool is the real hazard.
        // Anything touching files or processes belongs in the registry so its
        // gating is structural. Assert rather than comment, so the day someone
        // adds a colliding name it fails loudly in debug instead of quietly
        // downgrading that tool's gating.
        let dispatchedToolNames = registryToolNames
            .union(backgroundTaskToolNames)
            .union([Self.runTerminalTool.name])
        assert(
            Set(sessionTools.map(\.name)).isDisjoint(with: dispatchedToolNames),
            """
            session-service tool name collides with a dispatched tool: \
            \(Set(sessionTools.map(\.name)).intersection(dispatchedToolNames)). \
            The session branch runs first and skips the capability filter and \
            hooks that registry tools get, and the permission gate that shell \
            and background-task tools get.
            """
        )
        self.tools = terminalTools + sessionTools + allowedFileToolDefinitions.map { definition in
            ToolSpec(
                name: definition.name,
                description: definition.description,
                parameters: definition.argumentsSchema ?? .object([
                    "type": .string("object")
                ])
            )
        }
    }

    func runStop(
        event: HookEvent = .stop,
        promptID: String?,
        payload: [String: HookJSONValue]
    ) async -> StopDispatchResult {
        guard let hookPermissionGate else { return StopDispatchResult() }
        return await hookPermissionGate.runStop(
            event: event,
            promptId: promptID,
            payload: payload
        )
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

        // Session tools are checked first so a same-named MCP tool cannot
        // shadow `memory_search` or `update_goal`.
        if let sessionServices, sessionServices.handles(call.name) {
            let output = await sessionServices.invoke(name: call.name, arguments: args)
            return .success(OpenGrokShellToolCallResult(
                value: .string(output),
                promptText: output
            ))
        }

        // Snapshot whatever this call is about to touch, before it touches it.
        // This is the only point in the live path that sees every file tool
        // invocation with its arguments resolved, which is what makes a rewind
        // point per prompt possible without a hook in each tool.
        await sessionServices?.noteToolCall(name: call.name, arguments: args)

        if registryToolNames.contains(call.name) {
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

        guard call.name == Self.runTerminalTool.name
            || backgroundTaskToolNames.contains(call.name)
        else {
            return .failure(.unsupported("unknown tool '\(call.name)'"))
        }

        // Shell execution goes through the same pipeline the file tools use:
        // PreToolUse hooks, `[permission]` deny/ask/allow with Rust's
        // bash-segment evaluation, the shell file-access escalation that stops
        // a `sed -i` from editing a denied path, and the interactive modal.
        // `kill_task` is gated too. Tearing a process down only de-escalates
        // the *process*; the workspace is what is at risk. A killed `git rebase`
        // leaves a detached HEAD and a half-applied stack, a killed install a
        // partially written store. Ownership-scoping bounds the blast radius to
        // this session's tasks — which are exactly the ones `run_terminal_cmd`
        // started, i.e. the destructive set.
        //
        // Matched on the canonical name, not the literal: dispatch also accepts
        // upstream's `kill_command_or_subagent` spelling — which is what the
        // agent profiles actually spell — so a string match would leave that
        // door open. `get_task_output` / `wait_tasks` stay ungated: they read
        // output from a task whose permission decision was already made.
        //
        // Chained rather than two independent `if`s. The two are disjoint today,
        // so it makes no behavioural difference — but the next gated tool will
        // be copied from the shape that is here.
        if call.name == Self.runTerminalTool.name {
            if let denial = await gateTerminalCommand(args: args, call: call) {
                return .failure(denial)
            }
        } else if LiveBackgroundTaskTools.canonicalName(for: call.name)
            == LiveBackgroundTaskTools.killTaskName {
            if let denial = await gateKillTask(args: args, call: call) {
                return .failure(denial)
            }
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

    /// Run `kill_task` through the permission pipeline.
    ///
    /// Modelled as `.bash("kill_task <id>")` so a user can express
    /// `deny = ["Bash(kill_task:*)"]`. With no matching rule the bash path
    /// falls through to the built-in safe classification, so the common case
    /// costs no prompt.
    ///
    /// Two `nil`-shaped situations that are NOT the same thing, and the
    /// distinction is the whole point of a gate:
    ///
    ///   * **No pipeline** — the gate *cannot* authorize, so it denies. Anything
    ///     else means a session with no permission machinery kills freely.
    ///   * **No `task_id`** — there is *nothing* to authorize, so it proceeds.
    ///     `LiveBackgroundTaskTools.killTask` rejects the call with
    ///     `.invalidCall` before it ever reaches `process.killTask`, so nothing
    ///     is killed; duplicating that check here would only produce two
    ///     different error messages for one malformed call.
    private func gateKillTask(
        args: JSONValue,
        call: ToolCall
    ) async -> OpenGrokShellToolRuntimeError? {
        guard let permissionPipeline else {
            return .failed(
                "'\(call.name)' has no permission gate configured for this session"
            )
        }
        guard case .object(let object) = args,
              case .string(let rawTaskID)? = object["task_id"]
        else { return nil }
        let taskID = rawTaskID.trimmingCharacters(in: .whitespacesAndNewlines)
        if taskID.isEmpty { return nil }

        let prepared = await permissionPipeline.prepare(PrepareToolAccessRequest(
            access: .bash("kill_task \(taskID)"),
            toolName: call.name,
            toolCallId: call.callId
        ))
        if prepared.mayDispatch { return nil }
        switch prepared.decision {
        case .policyDeny(let reason), .reject(let reason):
            return .failed(reason)
        case .cancelled:
            return .cancelled
        case .followupMessage(let message):
            return .failed(message)
        case .ask:
            return .failed("'\(call.name)' requires approval, and no prompter is available.")
        case .allow:
            return nil
        }
    }

    /// Run `run_terminal_cmd` through the permission pipeline.
    ///
    /// Returns the error to fail the call with, or nil to proceed. Fails closed
    /// on every path that is not an explicit allow: a session with no pipeline,
    /// a malformed command, a policy deny, a hook deny, and a bare `.ask` that
    /// no prompter resolved all stop the command.
    private func gateTerminalCommand(
        args: JSONValue,
        call: ToolCall
    ) async -> OpenGrokShellToolRuntimeError? {
        guard let permissionPipeline else {
            return .failed(
                "'\(call.name)' has no permission gate configured for this session"
            )
        }
        guard case .object(let object) = args,
              case .string(let command)? = object["command"],
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .invalidCall("run_terminal_cmd requires a non-empty command")
        }

        let prepared = await permissionPipeline.prepare(PrepareToolAccessRequest(
            access: .bash(command),
            toolName: call.name,
            toolCallId: call.callId
        ))
        if prepared.mayDispatch { return nil }

        switch prepared.decision {
        case .policyDeny(let reason), .reject(let reason):
            return .failed(reason)
        case .cancelled:
            return .cancelled
        case .followupMessage(let message):
            return .failed(message)
        case .ask:
            // The engine asked and nothing answered — deny rather than run.
            return .failed("'\(call.name)' requires approval, and no prompter is available.")
        case .allow:
            return nil
        }
    }

    func shutdown() async {
        await mcpConnections.shutdown()
        await composition.shutdown()
    }

    func registerSession(sessionID: String, workingDirectory: URL) async throws {
        try await composition.registerSession(
            sessionID: sessionID,
            workingDirectory: workingDirectory
        )
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
        if LiveBackgroundTaskTools.canonicalName(for: call.name) != nil {
            return await LiveBackgroundTaskTools.invoke(
                name: call.name,
                args: call.args,
                process: process
            )
        }
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
    var sandboxProfile: String?
    var currentModelID: String?
    var currentProvider: ModelProvider?
    var everUsedNonXAI: Bool?
    /// User-chosen session title (`/rename`, upstream rename.rs:42-53).
    /// `nil` means "never renamed"; readers derive a title from the first
    /// real user turn instead. Optional so records written before this field
    /// existed keep decoding unchanged.
    var title: String?

    init(
        sessionID: String,
        workingDirectory: String,
        parentSessionID: String?,
        createdAt: Date,
        updatedAt: Date,
        items: [ConversationItem],
        sandboxProfile: String? = nil,
        currentModelID: String? = nil,
        currentProvider: ModelProvider? = nil,
        everUsedNonXAI: Bool? = nil,
        title: String? = nil
    ) {
        self.sessionID = sessionID
        self.workingDirectory = workingDirectory
        self.parentSessionID = parentSessionID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.items = items
        self.sandboxProfile = sandboxProfile
        self.currentModelID = currentModelID
        self.currentProvider = currentProvider
        self.everUsedNonXAI = everUsedNonXAI
        self.title = title
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID
        case workingDirectory
        case parentSessionID
        case createdAt
        case updatedAt
        case items
        case sandboxProfile = "sandbox_profile"
        case currentModelID = "current_model_id"
        case currentProvider = "current_provider"
        case everUsedNonXAI = "ever_used_codex"
        case title
    }

    static func new(
        sessionID: String,
        workingDirectory: URL,
        sandboxProfile: String? = nil
    ) -> LiveConversationRecord {
        let now = Date()
        return LiveConversationRecord(
            sessionID: sessionID,
            workingDirectory: workingDirectory.standardizedFileURL.path,
            parentSessionID: nil,
            createdAt: now,
            updatedAt: now,
            items: [],
            sandboxProfile: sandboxProfile,
            currentModelID: nil,
            currentProvider: nil,
            everUsedNonXAI: false
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

    /// Copy one session as a coupled transcript/rewind artifact transaction.
    ///
    /// The export marker and provider route are copied before the child can be
    /// launched, and a rewind sidecar is copied byte-for-byte when present so
    /// the child coordinator resumes the parent's prompt numbering and points.
    /// A legacy source is refused because its export boundary cannot be safely
    /// inherited. Any partial child artifacts are removed before the error is
    /// returned, so a failed fork never leaves a misleading session behind.
    func fork(
        sourceSessionID: String,
        destinationSessionID: String,
        workingDirectory: URL
    ) throws -> LiveConversationRecord {
        try Self.validateSessionID(sourceSessionID)
        try Self.validateSessionID(destinationSessionID)
        guard sourceSessionID != destinationSessionID else {
            throw CLIApplicationError.failed("forked session ID must differ from the source session")
        }
        guard let source = try loadIfPresent(sessionID: sourceSessionID) else {
            throw CLIApplicationError.failed("session not found: \(sourceSessionID)")
        }
        guard source.everUsedNonXAI != nil else {
            throw CLIApplicationError.failed(
                "cannot fork legacy session \(sourceSessionID): its session record has no "
                    + "ever_used_codex export-boundary marker. Resume it once with this build "
                    + "to persist the boundary before forking."
            )
        }
        guard try loadIfPresent(sessionID: destinationSessionID) == nil else {
            throw CLIApplicationError.failed("session already exists: \(destinationSessionID)")
        }

        let destinationRecordURL = fileURL(sessionID: destinationSessionID)
        let sourceRewindURL = LiveRewindStore.rewindFileURL(
            openGrokHome: sessionsDirectory.deletingLastPathComponent(),
            sessionID: sourceSessionID
        )
        let destinationRewindURL = LiveRewindStore.rewindFileURL(
            openGrokHome: sessionsDirectory.deletingLastPathComponent(),
            sessionID: destinationSessionID
        )
        guard !fileManager.fileExists(atPath: destinationRewindURL.path) else {
            throw CLIApplicationError.failed("rewind state already exists: \(destinationSessionID)")
        }

        let now = Date()
        let child = LiveConversationRecord(
            sessionID: destinationSessionID,
            workingDirectory: workingDirectory.standardizedFileURL.path,
            parentSessionID: source.sessionID,
            createdAt: now,
            updatedAt: now,
            items: source.items,
            sandboxProfile: source.sandboxProfile,
            currentModelID: source.currentModelID,
            currentProvider: source.currentProvider,
            everUsedNonXAI: source.everUsedNonXAI,
            title: source.title
        )

        do {
            try fileManager.createDirectory(
                at: sessionsDirectory,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(child).write(to: destinationRecordURL, options: .atomic)
            if fileManager.fileExists(atPath: sourceRewindURL.path) {
                let rewindBytes = try Data(contentsOf: sourceRewindURL)
                try rewindBytes.write(to: destinationRewindURL, options: .atomic)
            }
        } catch {
            try? fileManager.removeItem(at: destinationRecordURL)
            try? fileManager.removeItem(at: destinationRewindURL)
            throw CLIApplicationError.failed(
                "failed to fork session \(sourceSessionID) as \(destinationSessionID): \(error)"
            )
        }
        return child
    }

    private func fileURL(sessionID: String) -> URL {
        sessionsDirectory.appendingPathComponent(sessionID).appendingPathExtension("json")
    }
}

struct LiveAgentProfile: Sendable, Equatable {
    let model: String?
    let systemPrompt: String?
    let toolPolicy: LiveAgentToolPolicy
    let discoverSkills: Bool
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

    private init(
        configuredTools: [String],
        allowlist: [String],
        denylist: [String],
        sessionAllowlist: [String]?,
        sessionDenylist: [String],
        capabilityMode: AgentCapabilityMode?
    ) {
        self.configuredTools = configuredTools
        self.allowlist = allowlist
        self.denylist = denylist
        self.sessionAllowlist = sessionAllowlist
        self.sessionDenylist = sessionDenylist
        self.capabilityMode = capabilityMode
    }

    /// A policy that constrains nothing except the capability mode.
    ///
    /// `allows(liveToolName:)` requires membership in `configuredTools`, so an
    /// "unrestricted" policy cannot express itself as an empty list — the
    /// sentinel below makes every name match instead. Used for a workflow child
    /// in a session that has no agent profile: the only thing to enforce is the
    /// clamped capability.
    init(unrestrictedWith capabilityMode: AgentCapabilityMode) {
        self.init(
            configuredTools: [Self.wildcard],
            allowlist: [],
            denylist: [],
            sessionAllowlist: nil,
            sessionDenylist: [],
            capabilityMode: capabilityMode
        )
    }

    /// The same policy with a different capability mode. Narrowing only: the
    /// caller (`LiveWorkflowLaunch.clampedPolicy`) has already clamped against
    /// the parent's mode.
    func withCapabilityMode(_ mode: AgentCapabilityMode) -> LiveAgentToolPolicy {
        LiveAgentToolPolicy(
            configuredTools: configuredTools,
            allowlist: allowlist,
            denylist: denylist,
            sessionAllowlist: sessionAllowlist,
            sessionDenylist: sessionDenylist,
            capabilityMode: mode
        )
    }

    static let wildcard = "*"

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
        // The live surface advertises upstream's production names
        // (`xai-grok-agent/src/config.rs:161-173`); permission rules may still
        // spell either the production name or the registry alias. Without both
        // spellings here, a profile that grants `get_task_output` would
        // silently fail to match the `get_command_or_subagent_output` the
        // session advertises.
        if let alias = Self.backgroundTaskAliases[liveToolName] {
            return [liveToolName, alias]
        }
        return [liveToolName]
    }

    private static let backgroundTaskAliases: [String: String] = [
        "get_command_or_subagent_output": "get_task_output",
        "wait_commands_or_subagents": "wait_tasks",
        "kill_command_or_subagent": "kill_task",
    ]

    private static func matches(_ entries: [String], aliases: Set<String>) -> Bool {
        entries.contains { entry in
            if entry == wildcard { return true }
            let shortName = entry.split(separator: ":").last.map(String.init) ?? entry
            return aliases.contains(entry) || aliases.contains(shortName)
        }
    }
}

actor LiveConversationHistory {
    private var record: LiveConversationRecord
    private let store: LiveConversationStore
    private var exportBoundary: ExportBoundary

    init(
        record: LiveConversationRecord,
        store: LiveConversationStore,
        exportBoundary: ExportBoundary? = nil
    ) {
        self.record = record
        self.store = store
        self.exportBoundary = exportBoundary ?? ExportBoundary(
            everUsedNonXAI: record.everUsedNonXAI != false
        )
    }

    var items: [ConversationItem] { record.items }

    var sessionID: String { record.sessionID }

    var sharedExportBoundary: ExportBoundary { exportBoundary }

    func snapshot() -> LiveConversationRecord { record }

    /// Switch the in-memory spine only after the replacement record is
    /// durably written. The old record remains available through the store.
    func replace(with record: LiveConversationRecord) throws {
        try LiveConversationStore.validateSessionID(record.sessionID)
        self.record = record
        self.exportBoundary = ExportBoundary(
            everUsedNonXAI: record.everUsedNonXAI != false
        )
    }

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
        var next = record
        next.items = sanitized
        next.updatedAt = Date()
        try await store.save(next)
        record = next
        return before.count - sanitized.count
    }

    /// Persist the route before the next provider can observe replayed history.
    /// A legacy record with no route metadata is treated as unsafe when it has
    /// opaque carriers; its unknown export marker remains nil rather than being
    /// rewritten to a falsely clean value.
    @discardableResult
    func reconcileRoute(modelID: String, provider: ModelProvider) async throws -> Int {
        let before = record
        let sanitized = liveProviderNeutralHistory(before.items)
        let hasOpaqueItems = sanitized != before.items
        let routeChanged = before.currentProvider != provider
        let legacyRoute = before.currentModelID == nil || before.currentProvider == nil
        let xAIExportClosed = provider.profile.allowsXaiServices && before.everUsedNonXAI == true
        let shouldSanitize = hasOpaqueItems && (routeChanged || legacyRoute || xAIExportClosed)

        var next = before
        if shouldSanitize {
            next.items = sanitized
        }
        next.currentModelID = modelID
        next.currentProvider = provider
        if !provider.profile.allowsXaiServices {
            next.everUsedNonXAI = true
        }
        if next != before {
            next.updatedAt = Date()
        }
        try await store.save(next)
        record = next
        exportBoundary.observe(provider)
        return shouldSanitize ? before.items.count - sanitized.count : 0
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

    /// `/rename` (upstream rename.rs:42-53): set the session's stored title
    /// and persist it.
    ///
    /// The write goes through this actor's own record — not a second reader
    /// of the same file — because the turn loop re-saves the whole record on
    /// every commit; a title written around this actor would silently vanish
    /// at the next turn's save.
    func rename(title: String) async throws {
        record.title = title
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
    let skillsListing: String?
    /// The tool list this session advertises. In Code Mode it carries `exec`
    /// and `wait` and, in `code_mode_only`, hides everything the cell can
    /// reach through `tools.*`.
    let toolSurface: LiveCodeModeToolSurface
    /// `nil` in `direct` mode, which leaves the turn loop byte-identical to a
    /// session that has never heard of Code Mode.
    let codeMode: LiveCodeModeCoordinator?
    /// Keeps the conversation under the model's context window. Optional only
    /// so a test can build a driver without a model catalog; a live session
    /// always has one, and without it a long session dies at the wall.
    let compaction: LiveCompactionCoordinator?

    func sample(
        context: OpenGrokShellProviderTurnContext,
        request: OpenGrokShellTurnRequest,
        emit: @escaping @Sendable (OpenGrokShellTurnUpdateKind) async -> Void
    ) async throws -> OpenGrokShellSamplingResult {
        // Open the rewind point around the whole turn, and close it on every
        // exit path — including a thrown error or a cancelled turn, because a
        // turn that died half-way through an edit is precisely the one worth
        // being able to undo. Awaited rather than deferred into a detached
        // task: a `Task { }` in a `defer` is unordered against the *next*
        // turn's `beginPrompt`, which would let a late close swallow the
        // following prompt's point.
        let services = toolExecutor.sessionServices
        await services?.beginPrompt(text: request.text)
        do {
            let result = try await sampleTurn(context: context, request: request, emit: emit)
            await services?.endPrompt()
            return result
        } catch {
            await services?.endPrompt()
            throw error
        }
    }

    private func sampleTurn(
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
        let combinedSystemPrompt = [systemPrompt, skillsListing]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: "\n\n")
        if !combinedSystemPrompt.isEmpty,
           !items.contains(where: {
               if case .system = $0 { return true }
               return false
           }) {
            items.insert(.system(combinedSystemPrompt), at: 0)
        }
        // Memory is injected after the system prompt exists so it has an item
        // to splice into, and before compaction runs so the injected block
        // counts toward the budget like everything else. No-ops on every turn
        // after the first, and on a resumed session whose transcript already
        // carries a `<memory-context>` block.
        let services = toolExecutor.sessionServices
        items = await services?.injectMemoryContext(into: items, prompt: request.text) ?? items

        var toolRoundCount = 0
        var stopHookContinuations = 0
        var stopHookActive = false
        var authRetrySchedule = AuthRetrySchedule()

        while true {
            try Task.checkCancellation()
            // Before every sample, not only the first: a tool round can add
            // more to the prompt than the whole preceding turn did, and the
            // request that dies at the context wall is usually the one after a
            // large tool result, not the one that opened the turn.
            items = await compactIfNeeded(items: items, emit: emit)
            var response: OpenGrokLiveSamplingResponse?
            while response == nil {
                do {
                    response = try await sampler.sample(OpenGrokLiveSamplingRequest(
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
                    authRetrySchedule.resetOnSuccess()
                } catch let error as SamplingError {
                    guard case .auth(_, let credential) = error else { throw error }
                    switch authRetrySchedule.onRecovered401(credential) {
                    case .unchargedResubmit:
                        await Task.yield()
                    case .backoff(_, let delaySeconds):
                        try await Task.sleep(
                            nanoseconds: UInt64(max(0, delaySeconds) * 1_000_000_000)
                        )
                    case .exhausted, .runawayGuard:
                        throw error
                    }
                }
            }
            guard let response else { throw CLIApplicationError.failed("sampling produced no response") }
            items.append(contentsOf: response.items)

            guard !response.toolCalls.isEmpty else {
                try Task.checkCancellation()
                if stopHookContinuations < 8 {
                    let stopResult = await toolExecutor.runStop(
                        promptID: request.promptID,
                        payload: [
                            "reason": .string("end_turn"),
                            "stopHookActive": .boolean(stopHookActive),
                            "lastAssistantMessage": .string(response.output),
                        ]
                    )
                    if stopResult.preventContinuation == nil,
                       stopResult.wantsContinuation {
                        stopHookContinuations += 1
                        stopHookActive = true
                        items.append(.autoContinue(formatLiveStopFeedback(stopResult)))
                        continue
                    }
                }
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

    /// Keep the prompt under the model's context window, reporting what it did.
    ///
    /// Never throws. A session that cannot compact still gets to take its turn
    /// and see the provider's own error — dying here would replace a
    /// recoverable "too long" with an unrecoverable one, which is the failure
    /// this whole path exists to remove.
    private func compactIfNeeded(
        items: [ConversationItem],
        emit: @escaping @Sendable (OpenGrokShellTurnUpdateKind) async -> Void
    ) async -> [ConversationItem] {
        guard let compaction else { return items }
        // No status for the check itself: it runs before every sample, so
        // announcing it would put a line on the status bar for a token count
        // that almost always comes back under the threshold. `willCompact`
        // fires only once the coordinator has decided, which is what makes
        // "Compacting…" true whenever it is on screen. It is the third
        // turn-status label, beside "Thinking…" and "Responding…", matching
        // upstream's `TurnActivity::AutoCompacting` (`views/turn_status.rs:704`)
        // — same ellipsis character, and the renderer already gives a
        // `.status(text)` the spinner and the phase timer.
        switch await compaction.compactIfNeeded(items: items, willCompact: {
            await emit(.status("Compacting\u{2026}"))
        }) {
        case .notNeeded:
            return items
        case .unableToCompact(let reason):
            await emit(.status("could not compact the conversation: \(reason)"))
            return items
        case .compacted(let replacement, let report):
            await emit(.status(report.notice))
            return replacement
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
    private var providerConfiguration: ProviderSessionConfiguration
    private let conversationHistory: LiveConversationHistory
    private let conversationStore: LiveConversationStore
    private let toolExecutor: LiveToolExecutor?
    private let compaction: LiveCompactionCoordinator?
    /// The route the next turn actually runs on. `/resume` reconciles the
    /// restored record against this rather than the launch configuration,
    /// because `/model` may have moved the session since launch.
    private let modelSwitch: LiveModelSwitchCoordinator?
    /// The one session id turns may currently run against, and every id this
    /// process has already created in the shell. Two values because `/resume`
    /// can revisit a session created earlier in this run — recreating it in
    /// the shell would fail, but switching back to it must not.
    private var activeShellSessionID: SessionID?
    private var createdSessionIDs: Set<SessionID> = []

    init(
        shell: OpenGrokShell,
        cwd: URL,
        providerConfiguration: ProviderSessionConfiguration,
        conversationHistory: LiveConversationHistory,
        conversationStore: LiveConversationStore,
        toolExecutor: LiveToolExecutor? = nil,
        compaction: LiveCompactionCoordinator? = nil,
        modelSwitch: LiveModelSwitchCoordinator? = nil
    ) {
        self.shell = shell
        self.cwd = cwd
        self.providerConfiguration = providerConfiguration
        self.conversationHistory = conversationHistory
        self.conversationStore = conversationStore
        self.toolExecutor = toolExecutor
        self.compaction = compaction
        self.modelSwitch = modelSwitch
    }

    func makeSession(
        for request: OpenGrokPagerMinimalRequest
    ) async throws -> any OpenGrokPagerMinimalSessionAdapter {
        _ = try await shell.start()
        let shellEvents = await shell.events()
        let sessionID = SessionID(request.sessionID ?? providerConfiguration.sessionID)
        if let activeShellSessionID {
            guard activeShellSessionID == sessionID else {
                throw CLIApplicationError.failed("interactive runtime cannot switch session IDs")
            }
        }
        if !createdSessionIDs.contains(sessionID) {
            _ = try await shell.createSession(OpenGrokShellSessionRequest(
                sessionID: sessionID,
                cwd: cwd,
                providerConfiguration: providerConfiguration,
                restorePersistedState: false
            ))
            createdSessionIDs.insert(sessionID)
        }
        activeShellSessionID = sessionID
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

    func replaceSession(from request: OpenGrokPagerRequest) async throws -> String {
        _ = request
        let newSessionID = UUID().uuidString
        try LiveConversationStore.validateSessionID(newSessionID)
        let record = LiveConversationRecord.new(
            sessionID: newSessionID,
            workingDirectory: cwd,
            sandboxProfile: toolExecutor?.sandbox.profileName
        )
        let configuration = ProviderSessionConfiguration(
            sessionID: newSessionID,
            modelCatalog: providerConfiguration.modelCatalog,
            initialModelID: providerConfiguration.initialModelID,
            credentialBindings: providerConfiguration.credentialBindings,
            fallbackModelIDs: providerConfiguration.fallbackModelIDs,
            auxiliaryModelIDs: providerConfiguration.auxiliaryModelIDs,
            toolRequest: providerConfiguration.toolRequest,
            retryPolicy: providerConfiguration.retryPolicy,
            openGrokHome: providerConfiguration.openGrokHome,
            environment: providerConfiguration.environment,
            everUsedNonXAI: record.everUsedNonXAI
        )

        _ = try await shell.start()
        _ = try await shell.createSession(OpenGrokShellSessionRequest(
            sessionID: SessionID(newSessionID),
            cwd: cwd,
            providerConfiguration: configuration,
            restorePersistedState: false
        ))
        try await conversationStore.save(record)
        try await toolExecutor?.registerSession(
            sessionID: newSessionID,
            workingDirectory: cwd
        )
        try await conversationHistory.replace(with: record)
        await compaction?.replaceSessionID(newSessionID)
        providerConfiguration = configuration
        createdSessionIDs.insert(SessionID(newSessionID))
        activeShellSessionID = SessionID(newSessionID)
        return newSessionID
    }

    /// `/resume`: swap the live conversation to the stored session
    /// `sessionID`, keeping the current provider stack.
    ///
    /// Ordering mirrors `replaceSession`: the shell session and the persisted
    /// record land before the in-memory spine flips, so a failure partway
    /// leaves the previous session fully live. The restored history is then
    /// reconciled against the route the session is *currently* running
    /// (`reconcileRoute`), which strips provider-opaque carriers when the
    /// stored record came from a different provider — the same isolation
    /// `/model` applies, because a resume across providers is the same seam.
    func resumeSession(sessionID: String) async throws -> String {
        try LiveConversationStore.validateSessionID(sessionID)
        guard var record = try await conversationStore.loadIfPresent(sessionID: sessionID) else {
            throw CLIApplicationError.failed("session not found: \(sessionID)")
        }
        // The session continues in this process's working directory, exactly
        // as a cold-start `--resume` rebinds it (`resolveConversationRecord`).
        record.workingDirectory = cwd.standardizedFileURL.path
        let configuration = ProviderSessionConfiguration(
            sessionID: sessionID,
            modelCatalog: providerConfiguration.modelCatalog,
            initialModelID: providerConfiguration.initialModelID,
            credentialBindings: providerConfiguration.credentialBindings,
            fallbackModelIDs: providerConfiguration.fallbackModelIDs,
            auxiliaryModelIDs: providerConfiguration.auxiliaryModelIDs,
            toolRequest: providerConfiguration.toolRequest,
            retryPolicy: providerConfiguration.retryPolicy,
            openGrokHome: providerConfiguration.openGrokHome,
            environment: providerConfiguration.environment,
            everUsedNonXAI: record.everUsedNonXAI
        )

        _ = try await shell.start()
        let shellSessionID = SessionID(sessionID)
        if !createdSessionIDs.contains(shellSessionID) {
            _ = try await shell.createSession(OpenGrokShellSessionRequest(
                sessionID: shellSessionID,
                cwd: cwd,
                providerConfiguration: configuration,
                restorePersistedState: false
            ))
            createdSessionIDs.insert(shellSessionID)
        }
        try await conversationStore.save(record)
        try await toolExecutor?.registerSession(
            sessionID: sessionID,
            workingDirectory: cwd
        )
        try await conversationHistory.replace(with: record)
        if let modelSwitch {
            let snapshot = await modelSwitch.snapshot()
            _ = try await conversationHistory.reconcileRoute(
                modelID: snapshot.modelID,
                provider: snapshot.provider
            )
        }
        await compaction?.replaceSessionID(sessionID)
        providerConfiguration = configuration
        activeShellSessionID = shellSessionID
        return sessionID
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
        hints.append(PagerShortcutHint(key: "Tab", label: "scrollback"))
        hints.append(PagerShortcutHint(key: "Ctrl+c", label: "quit", isPinned: true))
        return hints
    }

    /// Hints for the scrollback's own focus, mirroring upstream's per-context
    /// bar. The vim-only keys are listed only when vim mode is on, because
    /// with it off they genuinely do nothing.
    static func scrollbackHints(isVimMode: Bool) -> [PagerShortcutHint] {
        var hints: [PagerShortcutHint] = [
            PagerShortcutHint(keys: ["\u{2191}", "\u{2193}"], label: "select", isPinned: true),
            PagerShortcutHint(keys: ["\u{2190}", "\u{2192}"], label: "fold"),
            PagerShortcutHint(key: "Enter", label: "view")
        ]
        if isVimMode {
            hints.append(PagerShortcutHint(keys: ["y", "Y"], label: "copy"))
            hints.append(PagerShortcutHint(key: "r", label: "raw"))
            hints.append(PagerShortcutHint(keys: ["o", "O"], label: "link"))
        }
        hints.append(PagerShortcutHint(key: "Tab", label: "prompt", isPinned: true))
        return hints
    }

    /// Title for the block viewer.
    static func blockTitle(for item: PagerConversationItem) -> String {
        switch item {
        case .message(let message):
            switch message.role {
            case .user: return "Your prompt"
            case .assistant: return "Response"
            case .reasoning: return "Thinking"
            case .system: return "System"
            case .error: return "Error"
            }
        case .tool(let tool):
            return tool.name
        case .separator:
            return "Separator"
        }
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

    /// Drop everything from `index` on — what `/rewind` does to the visible
    /// transcript once the persisted history has been truncated.
    ///
    /// The streaming bookkeeping is reset rather than adjusted: a rewind can
    /// only run between turns, so there is no active assistant block to keep,
    /// and a stale `activeAssistantIndex` pointing past the new end is exactly
    /// how the next turn would append into the wrong block.
    mutating func truncate(to index: Int) {
        guard index >= 0, index < items.count else { return }
        items.removeSubrange(index...)
        activeAssistantIndex = nil
        toolIndicesByCallID.removeAll(keepingCapacity: true)
    }

    mutating func removeAll() {
        items.removeAll()
        activeAssistantIndex = nil
        toolIndicesByCallID.removeAll(keepingCapacity: true)
    }

    /// Rebuild the visible transcript from a persisted conversation — what
    /// `/resume` paints after the runtime swaps sessions.
    ///
    /// The projection matches what this renderer would have accumulated live:
    /// real user prompts, assistant prose (markdown-styled), and one settled
    /// tool card per assistant tool call with its result attached. Synthetic
    /// user turns, system prompts and reasoning payloads are provider/context
    /// plumbing and never rendered as blocks in a live session either.
    mutating func seed(from conversationItems: [ConversationItem]) {
        removeAll()
        // Pair tool calls with their results up front; an unpaired call
        // renders with no output rather than being dropped.
        var resultsByCallID: [String: String] = [:]
        for item in conversationItems {
            if case .toolResult(let result) = item {
                resultsByCallID[result.toolCallId] = result.content
            }
        }
        for item in conversationItems {
            switch item {
            case .user(let user):
                guard user.syntheticReason == nil else { continue }
                let text = user.content.compactMap { part -> String? in
                    if case .text(let value) = part { return value }
                    return nil
                }.joined(separator: "\n")
                guard !text.isEmpty else { continue }
                items.append(.message(PagerMessage(role: .user, text: text)))
            case .assistant(let assistant):
                let text = assistant.content
                if !text.isEmpty {
                    items.append(.message(PagerMessage(
                        role: .assistant,
                        text: text,
                        styledLines: styledLines(for: text)
                    )))
                }
                for call in assistant.toolCalls {
                    items.append(.tool(PagerToolCard(
                        name: call.name,
                        input: call.arguments,
                        output: resultsByCallID[call.id],
                        state: .succeeded
                    )))
                }
            case .system, .toolResult, .customToolOutput, .backendToolCall,
                 .reasoning:
                continue
            }
        }
    }

    /// In-place edit of the blocks, for the fold/raw effects the scrollback's
    /// selection applies. Deliberately narrow: nothing outside may append or
    /// remove through this, which would desynchronize the streaming indices.
    mutating func withItems<T>(_ body: (inout [PagerConversationItem]) -> T) -> T {
        let countBefore = items.count
        let result = body(&items)
        assert(items.count == countBefore, "scrollback edits must not change the block count")
        return result
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

    /// `atSeconds` is the motion clock's now, used to stamp
    /// `PagerToolCard.finishedAt` the first time a tool reaches a terminal
    /// state — the input to the 400 ms finish flash. `nil` (motion disabled,
    /// transcript paths) renders the block already-static.
    mutating func apply(_ tool: OpenGrokPagerToolUpdate, atSeconds seconds: TimeInterval? = nil) {
        let state = Self.renderState(for: tool.state)
        var finishedAt: TimeInterval?
        if state != .running, state != .pending {
            // First terminal update wins: a re-delivered terminal state must
            // not restart the flash.
            if let index = toolIndicesByCallID[tool.callID],
               items.indices.contains(index),
               case .tool(let existing) = items[index],
               let existingFinish = existing.finishedAt {
                finishedAt = existingFinish
            } else {
                finishedAt = seconds
            }
        }
        let card = PagerToolCard(
            name: tool.name,
            input: tool.input,
            output: tool.output,
            state: state,
            finishedAt: finishedAt
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

// Internal (not private) so the reachability suites can drive the real
// adapter: a command's overlay/effect only exists here, and a test that
// cannot construct the renderer can only test the registry.
actor LiveInteractiveControllerRenderer: OpenGrokPagerInteractiveRenderAdapter {
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
    private let modelCatalog: [LiveModelPickerEntry]
    private let catalogStore: LiveModelCatalogStore?
    /// Rebuilds the sampling stack when a picker row is chosen. `nil` in
    /// compositions with no provider session (tests, headless renders), where
    /// the picker degrades to a relabel.
    private let modelSwitch: LiveModelSwitchCoordinator?
    private let providerBoundarySync: (@Sendable (Bool) async throws -> Void)?
    /// Prompts waiting behind the running turn, as published by the controller.
    private var queuedPromptCount = 0
    private var turnActivity: String?
    private var turnStartedAt: Date?
    private var isCancelling = false

    /// The animation clock, fed exclusively by the controller's wall-clock
    /// ticker through `renderAnimationTick`. The old per-event counter is
    /// gone on purpose: an event-count "tick" froze the spinner on a silent
    /// turn and raced ahead on a chatty one.
    private var motion = PagerMotionSnapshot()
    /// Whether this terminal can animate at all, resolved once — a non-TTY or
    /// `TERM=dumb` renders still frames forever.
    private let motionEnabled: Bool
    /// Last shimmer frame painted for a `.slow` tick, so the welcome logo only
    /// repaints when its animation actually advanced (app_view.rs:5760-5766).
    private var lastShimmerFrame = -1
    /// One-shot timer for a repaint folded into the paint cadence window;
    /// without it a coalesced frame would never paint (see
    /// `PagerTerminalRenderer.scheduledFrameAt`).
    private var pendingFlushTask: Task<Void, Never>?
    /// Reports what is moving on screen to the controller's motion ticker.
    /// Installed by the composition after the controller exists; `nil` (tests,
    /// headless) simply never arms the ticker from render-side changes.
    private var motionSink: (@Sendable (PagerMotionState) async -> Void)?
    private var lastPublishedMotionState: PagerMotionState?
    /// Turn start on the motion clock, for the status row's elapsed readout.
    /// `turnStartedAt` (wall time) stays as the fallback for motion-disabled
    /// terminals, where no animation frame ever advances `motion.seconds`.
    private var turnStartedAtSeconds: TimeInterval?
    /// UTF-8 bytes of assistant output streamed this turn, for the status
    /// row's ⇣ token counter. An estimate (bytes/4) by design: this turn path
    /// carries no provider-reported `TokenUsage`, and the estimator is the
    /// same one `/usage` already documents as the honest option.
    private var turnOutputUTF8Count = 0
    /// The compaction coordinator's context accounting, refreshed at turn
    /// boundaries. Feeds the status bar's context ramp with the same numbers
    /// auto-compaction decides on.
    private var contextUsage: ContextUsage?
    /// Per-server MCP connection outcomes, recorded at session start; the
    /// read-only `/mcps` overlay renders them.
    private let mcpServers: [MCPServerConnection]
    /// The auth-store home the settings modal's secret saves write to — the
    /// same store `readProviderAPIKey` reads.
    private let openGrokHome: URL

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
    /// The background workflow registry, when this session has one. `/workflows`
    /// reads it live at present time rather than caching rows, so the dashboard
    /// reflects runs started after the session began — including ones another
    /// process on the same `OPENGROK_HOME` started.
    private let workflowRegistry: RhaiWorkflowRunRegistry?
    private let workflowsEnabled: Bool
    /// The turn loop's own coordinator, so a manual `/compact` and the
    /// automatic one share a compaction counter — which is the whole reason
    /// that instance is shared rather than rebuilt here.
    private let compaction: LiveCompactionCoordinator?
    /// The session this renderer belongs to, and the three things the
    /// session-scoped commands act on.
    ///
    /// `sessionServices` is the same aggregate the tool executor holds — the one
    /// `makeSessionServices` built — so `/rewind` acts on the snapshots the turn
    /// loop actually captured and `/remember` writes to the backend the
    /// `memory_search` tool reads. Rebuilding them here would produce a second
    /// store pointed at the same files, which is how two writers appear.
    private var sessionID: String
    private let sessionServices: LiveSessionServices?
    private let conversationHistory: LiveConversationHistory?
    private let sessionCatalog: LiveSessionCatalog?
    private var currentPermissionRequestID: String?
    private var hasStartedFirstTurn = false
    /// The scrollback's focus and selected block. `selection.isFocused` is what
    /// unfocuses the composer, so the two halves of the focus model cannot
    /// disagree.
    private var selection = LiveScrollbackSelection()
    /// Composer mode flags, carried as a whole snapshot so a missed event
    /// cannot leave the renderer disagreeing with the controller.
    private var inputModes = OpenGrokPagerInputModes()

    /// Mouse. `linesPerEvent` folds the terminal's reports-per-notch into a
    /// per-report line count, which is the whole of the port's wheel handling —
    /// the reference's acceleration bands are not ported.
    private let wheelTuning: MouseWheelTuning
    private var mouseReportingEnabled: Bool

    /// The palette every frame paints with, and the preference it came from.
    ///
    /// Resolved once at construction from `[ui] theme` plus what the terminal
    /// can actually render, then swapped live by `/theme`. Before this the port
    /// pinned `PagerRenderState.theme` to `.default`, which made the whole
    /// theme catalog unreachable at runtime.
    private var themePreference: PagerThemePreference
    private var renderTheme: PagerRenderTheme
    private let colorLevel: PagerColorLevel

    /// Reasoning effort for the active model, shown after the model name on the
    /// composer's bottom border. `nil` on models with no selectable effort.
    private var reasoningEffort: String?

    init(
        mode: OpenGrokPagerMode,
        terminal: OpenGrokLiveTerminal,
        sink: any PagerTerminalSink,
        workingDirectory: String = FileManager.default.currentDirectoryPath,
        modelName: String = "unknown",
        modelCatalog: [LiveModelPickerEntry] = [],
        catalogStore: LiveModelCatalogStore? = nil,
        modelSwitch: LiveModelSwitchCoordinator? = nil,
        providerBoundarySync: (@Sendable (Bool) async throws -> Void)? = nil,
        permissionCoordinator: PagerPermissionCoordinator? = nil,
        workflowRegistry: RhaiWorkflowRunRegistry? = nil,
        workflowsEnabled: Bool = true,
        terminalProgram: String? = nil,
        enableMouseReporting: Bool = true,
        themePreference: PagerThemePreference = .fixed(.grokNight),
        reasoningEffort: String? = nil,
        compaction: LiveCompactionCoordinator? = nil,
        sessionID: String = "",
        sessionServices: LiveSessionServices? = nil,
        conversationHistory: LiveConversationHistory? = nil,
        sessionCatalog: LiveSessionCatalog? = nil,
        mcpServers: [MCPServerConnection] = [],
        openGrokHome: URL? = nil,
        paintCadence: TimeInterval = PagerMotion.defaultPaintCadence
    ) {
        self.mode = mode
        self.sessionID = sessionID
        self.sessionServices = sessionServices
        self.conversationHistory = conversationHistory
        self.sessionCatalog = sessionCatalog
        self.mcpServers = mcpServers
        self.openGrokHome = openGrokHome ?? OpenGrokHomeResolver
            .resolve(environment: ProcessInfo.processInfo.environment)
        self.terminal = terminal
        self.sink = sink
        self.workingDirectory = workingDirectory
        self.modelName = modelName
        self.modelCatalog = modelCatalog.isEmpty
            ? [LiveModelPickerEntry(id: modelName, providerID: "", name: modelName)]
            : modelCatalog
        self.catalogStore = catalogStore
        self.modelSwitch = modelSwitch
        self.providerBoundarySync = providerBoundarySync
        self.permissionCoordinator = permissionCoordinator
        self.workflowRegistry = workflowRegistry
        self.workflowsEnabled = workflowsEnabled
        self.compaction = compaction
        self.wheelTuning = MouseWheelTuning(
            eventsPerTick: MouseWheelTuning.eventsPerTick(forTerminalProgram: terminalProgram)
        )
        self.mouseReportingEnabled = enableMouseReporting
        self.reasoningEffort = reasoningEffort

        // Minimal mode locks the terminal's own palette, matching the
        // reference's terminal-native lock. Everything else resolves the stored
        // preference against what this terminal can render, so a truecolor-only
        // theme degrades to GrokNight instead of to mush.
        let environment = ProcessInfo.processInfo.environment
        let level = pagerDetectColorLevel(environment: environment, isTTY: terminal.size() != nil)
        let resolution = pagerResolveTheme(
            preference: themePreference,
            colorLevel: level,
            appearance: themePreference == .auto ? PagerSystemAppearance.detect() : nil,
            terminalNativeLock: mode != .fullScreen
        )
        self.themePreference = themePreference
        self.renderTheme = resolution.theme
        self.colorLevel = level
        self.motionEnabled = PagerMotionState.motionEnabled(
            environment: environment,
            isTTY: terminal.isTTY()
        )

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
                useMouseReporting: enableMouseReporting,
                paintCadence: paintCadence
            )
        )
    }

    /// Install the controller-facing motion feed. Called by the composition
    /// after the controller exists (the renderer is constructed first), and
    /// immediately publishes the current state so a welcome logo that is
    /// already on screen arms the shimmer ticker without waiting for input.
    func setMotionStateSink(
        _ sink: (@Sendable (PagerMotionState) async -> Void)?
    ) {
        motionSink = sink
        lastPublishedMotionState = nil
        publishMotionState()
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
        await refreshContextUsage()
        try renderState()
    }

    func resize(to size: OpenGrokTerminalCore.TerminalSize) async throws {
        terminalSize = size
        try renderer.resize(to: size)
        try renderState()
    }

    func render(_ event: OpenGrokPagerInteractiveEvent) async throws {
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
            turnStartedAtSeconds = motion.seconds
            turnOutputUTF8Count = 0
            isCancelling = false
            await refreshContextUsage()
        case .session(let event):
            apply(event)
        case .turnFinished:
            finishAssistant()
            endTurn()
            await refreshContextUsage()
        case .sessionReplaced(let sessionID):
            resetForNewSession(sessionID: sessionID)
        case .sessionResumed(let sessionID):
            await applyResumedSession(sessionID: sessionID)
        case .notice(let message):
            appendMessage(PagerMessage(role: .system, text: message))
        case .focusChanged(let region):
            switch region {
            case .scrollback:
                selection.focus(itemCount: conversation.items.count)
                // Following the tail while a selection cursor exists would
                // yank the viewport away from the block the user just picked.
                followsBottom = false
            case .prompt:
                selection.unfocus()
            }
        case .modeChanged(let modes):
            inputModes = modes
        case .scrollback(let command):
            try await applyScrollback(command)
        case .global(let command):
            try await applyGlobal(command)
        case .queueChanged(let count):
            queuedPromptCount = count
        case .viewport(let command):
            applyViewport(command)
        case .overlay(let request):
            try await present(request)
        case .turnCancelled:
            finishAssistant()
            appendMessage(PagerMessage(role: .system, text: "Cancelled."))
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
            appendMessage(PagerMessage(role: .error, text: message))
            await resolveOutstandingPermissions()
            endTurn()
        }
        try renderState()
    }

    private func endTurn() {
        turnActivity = nil
        turnStartedAt = nil
        turnStartedAtSeconds = nil
        turnOutputUTF8Count = 0
        isCancelling = false
    }

    private func resetForNewSession(sessionID: String) {
        self.sessionID = sessionID
        conversation.removeAll()
        selection.unfocus()
        followsBottom = true
        scrollOffset = 0
        lastMaximumScrollOffset = 0
        queuedPromptCount = 0
        prompt = OpenGrokPagerInteractivePromptState()
        hasStartedFirstTurn = false
        currentPermissionRequestID = nil
        endTurn()
        overlays.removeAll()
        overlays.push(.welcome(
            PagerWelcomeOverlay(subtitle: LivePagerChrome.collapseHome(workingDirectory)),
            capturesInput: false
        ))
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
        // A flush firing after restore would paint into a torn-down screen;
        // `flushPendingFrameNow` also re-checks `restored` for the task that
        // is already past its sleep.
        pendingFlushTask?.cancel()
        pendingFlushTask = nil
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
            // Estimated bytes/4, not provider-reported: this event path
            // carries no `TokenUsage` (see `LiveUsageComposition.report`).
            turnOutputUTF8Count += text.utf8.count
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
        // Terminal states are stamped with the motion clock so the block gets
        // its 400 ms finish flash. `motion.seconds` is at most one tick stale
        // (~33 ms at 30 fps), well inside the flash window; with motion
        // disabled the stamp is 0 and the flash renderer treats it as
        // already-static.
        conversation.apply(tool, atSeconds: motionEnabled ? motion.seconds : nil)
        // While a tool runs, the turn-status row shows the tool's own title —
        // the reference has no separate "tool running" phrasing.
        if tool.state == .running {
            turnActivity = tool.name
        }
    }

    // MARK: - Scrollback selection

    private func applyScrollback(_ command: OpenGrokPagerScrollbackCommand) async throws {
        selection.clamp(itemCount: conversation.items.count)
        // `Enter` on the selected block opens it in the viewer, which is the
        // text modal the overlay layer already builds. Handled here rather than
        // in the selection value because only the renderer owns the stack.
        if command == .openBlockViewer {
            guard let index = selection.index,
                  conversation.items.indices.contains(index) else { return }
            let item = conversation.items[index]
            let body = LiveScrollbackSelection.content(of: item)
            overlays.push(.sessionInfo(
                id: "block-viewer",
                title: LivePagerChrome.blockTitle(for: item),
                lines: body
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { PagerStyledLine(text: String($0)) }
            ))
            return
        }

        let outcome = conversation.withItems { items in
            selection.apply(command, items: &items)
        }
        if let clipboard = outcome.clipboard {
            do {
                try LivePagerClipboard.copy(clipboard) { data in
                    try sink.write(String(decoding: data, as: UTF8.self))
                }
                try sink.flush()
            } catch {
                appendMessage(PagerMessage(
                    role: .error,
                    text: "Could not reach the clipboard: \(error)"
                ))
                return
            }
        }
        if let url = outcome.url {
            appendMessage(PagerMessage(role: .system, text: url))
        }
        if let notice = outcome.notice {
            appendMessage(PagerMessage(role: .system, text: notice))
        }
    }

    // MARK: - Global chords

    /// Route an application-level chord.
    ///
    /// The three that open overlays are the ones this renderer can service; the
    /// pane toggles and session chords have no backing state here yet and are
    /// explicit no-ops rather than silent misbehaviour.
    private func applyGlobal(_ command: OpenGrokPagerGlobalCommand) async throws {
        switch command {
        case .commandPalette:
            try await present(.commandPalette(rows: []))
        case .shortcutsHelp:
            try await present(.shortcutsHelp)
        case .modelPicker:
            try await present(.modelPicker(query: nil))
        case .toggleQueue:
            try await present(.promptQueue(entries: []))
        case .toggleTodos, .toggleTasks, .sendToBackground, .newSession,
             .cyclePermissionMode, .toggleAlwaysApprove, .openDashboard,
             .openSettings, .openSessions, .openExtensions:
            // Unbound in the controller's key table until the backing surface
            // exists, so these arrive only from a caller that built them by
            // hand. Nothing to do beats a misleading approximation.
            break
        }
    }

    // MARK: - Overlays

    private func present(_ request: OpenGrokPagerOverlayRequest) async throws {
        switch request {
        case .help:
            overlays.push(.help(lines: OpenGrokPagerInteractiveController.helpText(workflowsEnabled: workflowsEnabled)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { PagerStyledLine(text: String($0)) }))
        case .modelPicker(let query):
            let entries = catalogStore?.pickerEntries() ?? modelCatalog
            // A typed selector that names exactly one model switches directly:
            // showing a picker the user already answered would be a pointless
            // second step. Ambiguity and misses fall back to an error rather
            // than to the overlay, so `/model <typo>` never silently becomes
            // "pick something else" (upstream returns `Unknown model: …`).
            if let query, !query.isEmpty {
                // Whole-string match first: display names contain spaces
                // ("Grok 4.5"), so splitting the last token first would let a
                // shorter entry steal the prefix and treat "4.5" as an effort
                // (upstream model.rs:76-83).
                if let modelID = LiveModelPicker.resolve(
                    query: query,
                    entries: entries
                ) {
                    await switchModel(to: modelID)
                    return
                }
                // `/model <name> <effort>`: trailing effort token on a
                // reasoning model (upstream model.rs:85-104). A rejected
                // level surfaces the effort error with the model's offered
                // ids — not "Unknown model: … none".
                if let (prefix, token) = LiveModelPicker.splitTrailingToken(query),
                   let modelID = LiveModelPicker.resolve(query: prefix, entries: entries),
                   let entry = entries.first(where: { $0.id == modelID }),
                   entry.supportsReasoningEffort {
                    switch LiveModelEffort.resolve(
                        token: token,
                        supportsReasoningEffort: entry.supportsReasoningEffort,
                        declaredEfforts: entry.reasoningEfforts
                    ) {
                    case .success(let effort):
                        await switchModel(to: modelID, effort: effort)
                    case .failure(let error):
                        appendMessage(PagerMessage(
                            role: .error,
                            text: error.message
                        ))
                    }
                    return
                }
                appendMessage(PagerMessage(
                    role: .error,
                    text: LiveModelPicker.unknownModelMessage(query)
                ))
                return
            }
            overlays.push(LiveModelPicker.overlay(
                entries: entries,
                currentModelID: modelName
            ))
        case .toggleMouseReporting:
            mouseReportingEnabled.toggle()
            try renderer.setMouseReporting(mouseReportingEnabled)
            appendMessage(PagerMessage(
                role: .system,
                text: mouseReportingEnabled
                    ? "Mouse reporting on. Wheel scrolls the transcript; click selects overlay rows."
                    : "Mouse reporting off. Click and drag now selects text for your terminal's copy/paste."
            ))
        case .workflows:
            guard let workflowRegistry else {
                appendMessage(PagerMessage(
                    role: .system,
                    text: "No workflow runs in this session. Launch one with --workflow <file>."
                ))
                return
            }
            let views = (try? await workflowRegistry.views()) ?? []
            overlays.push(.workflows(rows: LiveWorkflowOverlayBuilder.rows(from: views)))
        case .commandPalette(let rows):
            overlays.push(.list(
                id: "command-palette",
                title: "Commands",
                rows: rows.isEmpty
                    ? LivePagerOverlayText.commandRows(workflowsEnabled: workflowsEnabled)
                    : rows.map {
                        PagerListRow(
                            id: $0.insertText,
                            label: $0.name,
                            summary: $0.summary,
                            isSelectable: $0.isAvailable
                        )
                    }
            ))
        case .promptHistory(let entries):
            guard !entries.isEmpty else {
                note("No prompt history in this session yet.")
                return
            }
            // Newest first: the entry you most likely want to re-run is the one
            // you just ran.
            overlays.push(.list(
                id: "prompt-history",
                title: "Prompt history",
                rows: entries.reversed().enumerated().map { index, entry in
                    PagerListRow(
                        id: "history-\(index)",
                        label: LivePagerOverlayText.singleLine(entry),
                        detail: entry.contains("\n") ? "multiline" : nil
                    )
                }
            ))
        case .promptQueue(let entries):
            guard !entries.isEmpty else {
                note("Nothing queued.")
                return
            }
            overlays.push(.list(
                id: "prompt-queue",
                title: "Queued prompts",
                rows: entries.enumerated().map { index, entry in
                    PagerListRow(
                        id: "queue-\(index)",
                        label: LivePagerOverlayText.singleLine(entry),
                        detail: "#\(index + 1)"
                    )
                }
            ))
        case .sessionInfo:
            overlays.push(.sessionInfo(lines: LivePagerOverlayText.sessionInfoLines(
                workingDirectory: LivePagerChrome.collapseHome(workingDirectory),
                modelName: modelName,
                itemCount: conversation.items.count,
                queuedPromptCount: queuedPromptCount,
                modes: inputModes
            )))
        case .contextUsage:
            // Real accounting now that the renderer shares the turn loop's
            // coordinator — the same numbers auto-compaction decides on, not a
            // character-count estimate. The estimate remains the fallback for
            // compositions with no coordinator (headless, tests), and says so
            // rather than presenting a guess as a measurement.
            guard let compaction else {
                overlays.push(.sessionInfo(
                    id: "context-usage",
                    title: "Context",
                    lines: LivePagerOverlayText.contextLines(
                        modelName: modelName,
                        itemCount: conversation.items.count,
                        transcriptCharacters: transcript.count
                    )
                ))
                return
            }
            let usage = await compaction.usage()
            overlays.push(.sessionInfo(
                id: "context-usage",
                title: "Context",
                lines: LivePagerContextReport.lines(
                    usage: usage,
                    itemCount: conversation.items.count
                )
            ))
        case .copyResponse(let index, let filePath):
            guard let response = LivePagerOverlayText.assistantResponse(
                fromLast: index,
                in: conversation.items
            ) else {
                note("No assistant response \(index) back to copy.")
                return
            }
            try deliver(response, to: filePath, label: "Response")
        case .exportConversation(let filePath):
            try deliver(transcript, to: filePath, label: "Conversation")
        case .scrollbackSearch(let query):
            guard let query, !query.isEmpty else {
                note("Usage: /find <text>")
                return
            }
            let matches = LivePagerOverlayText.search(query, in: conversation.items)
            guard !matches.isEmpty else {
                note("No matches for \(query).")
                return
            }
            overlays.push(.list(
                id: "scrollback-search",
                title: "Find: \(query)",
                rows: matches
            ))
        case .welcomeScreen:
            overlays.push(.welcome(
                PagerWelcomeOverlay(
                    subtitle: LivePagerChrome.collapseHome(workingDirectory)
                ),
                capturesInput: false
            ))
        case .shortcutsHelp:
            overlays.push(.help(
                id: "shortcuts-help",
                lines: LivePagerOverlayText.shortcutsLines()
            ))
        case .tutorial:
            overlays.push(.sessionInfo(
                id: "tutorial",
                title: "Getting started",
                lines: LivePagerOverlayText.tutorialLines()
            ))
        case .easterEgg:
            appendMessage(PagerMessage(
                role: .system,
                text: LivePagerOverlayText.easterEgg
            ))
        case .compact(let instructions):
            // Safe to run here only because the controller guarantees no turn
            // is in flight: `/compact` is `mutatesConversationHistory`, so a
            // mid-turn invocation is queued rather than dispatched. Without
            // that gate this would rewrite the item list a streaming sampler is
            // reading from.
            guard let compaction else {
                note("This session has no compaction coordinator, so /compact has nothing to act on.")
                return
            }
            note("Compacting\u{2026}")
            try renderState()
            switch await compaction.compactNow(userContext: instructions) {
            case .compacted(_, let report):
                // `compactNow` has already written the replacement back to the
                // persisted conversation, so there is nothing to apply here —
                // only to report.
                note(report.notice)
            case .notNeeded:
                note("Nothing to compact — the context is not close to full.")
            case .unableToCompact(let reason):
                appendMessage(PagerMessage(
                    role: .error,
                    text: "Could not compact: \(reason)"
                ))
            }
        case .settings(let deepLinkKey):
            overlays.push(.settings(settingsOverlay(deepLinkKey: deepLinkKey)))
        case .themePicker(let query):
            // A typed name that resolves applies straight away; only a miss or
            // a bare `/theme` opens the picker. Same rule as `/model`, and for
            // the same reason — showing a chooser the user already answered is
            // a pointless second step.
            if let query, !query.isEmpty {
                guard let message = applyTheme(named: query) else {
                    appendMessage(PagerMessage(
                        role: .error,
                        text: "Unknown theme: \(query). Try "
                            + availableThemeNames.joined(separator: ", ") + "."
                    ))
                    return
                }
                appendMessage(PagerMessage(role: .system, text: message))
                return
            }
            overlays.push(.list(
                id: "theme",
                title: "Select theme",
                rows: availableThemeNames.map { name in
                    PagerListRow(
                        id: name,
                        label: PagerThemePreference.named(name)?.displayName ?? name,
                        detail: themePreference == PagerThemePreference.named(name) ? "✓" : nil
                    )
                }
            ))
        case .rewind(let argument):
            // Safe to touch history here for the same reason `/compact` is:
            // `rewind` is `mutatesConversationHistory`, so the controller defers
            // it out of a running turn rather than dispatching it inline.
            await applyRewind(argument: argument)
        case .jumpPicker:
            guard mode == .fullScreen else {
                // Upstream's `ModeSupport::FullscreenOnly` remedy, verbatim in
                // substance: there is no viewport to move in minimal mode.
                note("/jump needs fullscreen mode — minimal scrolls with your terminal's native scrollback.")
                return
            }
            overlays.push(LiveJumpPicker.overlay(items: conversation.items))
        case .deleteSession(let confirmed):
            await deleteSession(confirmed: confirmed)
        case .remember(let text):
            note(await LiveMemoryCommands.remember(text, backend: sessionServices?.memory))
        case .recall(let query):
            note(await LiveMemoryCommands.recall(query, backend: sessionServices?.memory))
        case .flush(let text):
            note(await LiveMemoryCommands.flush(
                text,
                sessionID: sessionID,
                backend: sessionServices?.memory
            ))
        case .goal(let argument):
            guard let coordinator = sessionServices?.goal else {
                note("Goal tracking is not available in this session.")
                return
            }
            switch await LiveGoalCommands.run(argument: argument, coordinator: coordinator) {
            case .message(let text):
                note(text)
            case .submitPrompt(let text):
                // Setting a goal seeds the model with the goal instruction,
                // which is a turn rather than a message. The renderer cannot
                // start one, so it says what it did and hands the text to the
                // user rather than silently dropping it.
                note("Goal set. Send this to brief the model on it, or just keep going:")
                note(text)
            }
        case .sessionPicker:
            // `/resume` (upstream resume.rs:21-23). Row ids are session ids;
            // choosing one round-trips through the controller as
            // `/resume <id>`, which is what reaches the runtime swap.
            guard let sessionCatalog else {
                note("Session storage is unavailable in this session, so there is nothing to resume.")
                return
            }
            let listings = (try? sessionCatalog.list()) ?? []
            overlays.push(LiveSessionPicker.overlay(listings: listings))
        case .usage:
            // `/usage` (upstream usage.rs:59, `Action::ShowUsage`) rendered as
            // a text modal the way `/context` is. The numbers come from
            // `LiveUsageComposition`, which documents why they are estimates.
            let context: ContextUsage?
            if let compaction {
                context = await compaction.usage()
            } else {
                context = nil
            }
            let usageItems: [ConversationItem]
            if let conversationHistory {
                usageItems = await conversationHistory.items
            } else {
                usageItems = []
            }
            let report = await LiveUsageComposition.report(
                context: context,
                items: usageItems
            )
            overlays.push(.sessionInfo(
                id: "usage",
                title: "Usage",
                lines: LiveUsageComposition.render(report)
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { PagerStyledLine(text: String($0)) }
            ))
        case .mcpServers:
            overlays.push(.sessionInfo(
                id: "mcps",
                title: "MCP servers",
                lines: LiveMCPStatusOverlay.lines(connections: mcpServers)
                    .map { PagerStyledLine(text: $0) }
            ))
        case .reasoningEffort(let query):
            await applyEffortCommand(query: query)
        case .renameSession(let title):
            await renameSession(title: title)
        case .dismissAll:
            overlays.removeAll()
            currentPermissionRequestID = nil
        }
    }

    // MARK: - /resume, /effort, /rename

    /// Repaint the transcript the runtime just restored. The runtime has
    /// already swapped the conversation history, so this is a pure projection
    /// of what is now on disk.
    private func applyResumedSession(sessionID: String) async {
        self.sessionID = sessionID
        let items = await conversationHistory?.items ?? []
        conversation.seed(from: items)
        selection.unfocus()
        followsBottom = true
        scrollOffset = 0
        lastMaximumScrollOffset = 0
        queuedPromptCount = 0
        currentPermissionRequestID = nil
        endTurn()
        overlays.removeAll()
        hasStartedFirstTurn = !conversation.items.isEmpty
        if conversation.items.isEmpty {
            overlays.push(.welcome(
                PagerWelcomeOverlay(subtitle: LivePagerChrome.collapseHome(workingDirectory)),
                capturesInput: false
            ))
        }
        note("Resumed session \(String(sessionID.prefix(8))) — "
            + "\(conversation.items.count) block\(conversation.items.count == 1 ? "" : "s") restored.")
        await refreshContextUsage()
    }

    /// `/effort [level]` — reasoning effort on the current model, upstream
    /// effort.rs:57-92: the model id stays fixed and only the effort moves,
    /// through the same switch path `/model <name> <effort>` uses.
    private func applyEffortCommand(query: String?) async {
        // The composer border carries the wire model name; resolve it back to
        // its catalog entry for the effort menu. A model the catalog no
        // longer knows classifies as unsupported, which is also what
        // upstream's option-less menu resolves to.
        let entry = catalogStore?.entryForWireModel(modelName)
            ?? modelCatalog.first { $0.id == modelName }
        let supportsEffort = entry?.supportsReasoningEffort ?? false
        let declaredEfforts = entry?.reasoningEfforts ?? []

        guard let query, !query.isEmpty else {
            // Bare `/effort`: upstream's usage error listing the current
            // model's own option ids and the session's current effort
            // (effort.rs:63-81). The current effort reads through the
            // manager's session-level tracker (`currentReasoningEffortValue`),
            // seeded at launch and updated by every switch.
            let offered = LiveModelEffort.options(
                supportsReasoningEffort: supportsEffort,
                declaredEfforts: declaredEfforts
            ).map(\.id)
            let levels = offered.isEmpty ? "<level>" : offered.joined(separator: "|")
            let current = (catalogStore?.currentReasoningEffort()?.asString ?? reasoningEffort)
                .map { " (current: \($0))" } ?? ""
            appendMessage(PagerMessage(
                role: .error,
                text: "Usage: /effort <\(levels)>\(current)"
            ))
            return
        }
        switch LiveModelEffort.resolve(
            token: query,
            supportsReasoningEffort: supportsEffort,
            declaredEfforts: declaredEfforts
        ) {
        case .success(let effort):
            // Same wire path as `/model <name> <effort>` — the coordinator
            // treats an effort-only re-pick of the active model as a real
            // switch, and `switchModel` updates the composer's effort label.
            await switchModel(to: entry?.id ?? modelName, effort: effort)
        case .failure(let error):
            appendMessage(PagerMessage(role: .error, text: error.message))
        }
    }

    /// `/rename <title>` — one title-write through the conversation history
    /// actor (upstream rename.rs:42-53, `Action::RenameSession`).
    private func renameSession(title: String) async {
        guard let conversationHistory else {
            // Upstream's no-session refusal (rename.rs:43-45).
            appendMessage(PagerMessage(role: .error, text: "No active session"))
            return
        }
        do {
            try await conversationHistory.rename(title: title)
        } catch {
            appendMessage(PagerMessage(
                role: .error,
                text: "Could not rename the session: \(error)"
            ))
            return
        }
        note("Session renamed to \u{201C}\(title)\u{201D}.")
    }

    // MARK: - Session-scoped commands

    /// `/rewind` — picker on a bare invocation, dry run with a number, restore
    /// only with `--force`.
    ///
    /// The history the coordinator reasons about is the *persisted* one, not the
    /// rendered blocks: the rendered transcript drops nothing but also holds no
    /// tool results, so truncating it positionally is a projection of the real
    /// truncation, not the source of truth.
    private func applyRewind(argument: String) async {
        guard let coordinator = sessionServices?.rewind else {
            note("Rewind is disabled for this session (OPENGROK_REWIND=0).")
            return
        }
        let currentItems = await conversationHistory?.items ?? []
        switch await LiveSessionCommands.rewind(
            argument: argument,
            rewind: coordinator,
            currentItems: currentItems
        ) {
        case .message(let text):
            note(text)
        case .overlay(let overlay):
            overlays.push(overlay)
        case .rewound(let targetPromptIndex, _, let summary):
            await commitRewind(toPromptIndex: targetPromptIndex, summary: summary)
        }
    }

    /// Apply a rewind the coordinator has already performed on disk.
    ///
    /// `restore(force: true)` puts the *files* back; the conversation is the
    /// caller's to truncate, which is why this exists rather than living in the
    /// coordinator. Both halves land or neither is claimed: a failed commit is
    /// reported as an error rather than swallowed, because the files have
    /// already moved and a session whose history disagrees with its working tree
    /// is worse than one that says so.
    private func commitRewind(toPromptIndex targetPromptIndex: Int, summary: String) async {
        note(summary)
        guard let conversationHistory else { return }
        let truncated = liveTruncateConversation(
            await conversationHistory.items,
            toPromptIndex: targetPromptIndex
        )
        do {
            try await conversationHistory.commit(sessionID: sessionID, items: truncated)
        } catch {
            appendMessage(PagerMessage(
                role: .error,
                text: "Files were restored, but the conversation could not be truncated: \(error)"
            ))
            return
        }
        truncateRenderedTranscript(toPromptIndex: targetPromptIndex)
    }

    /// Drop rendered blocks from the `targetPromptIndex`-th user prompt onward.
    ///
    /// Counted positionally over user blocks, the same rule
    /// `liveTruncateConversation` applies to the persisted items — the two lists
    /// hold different things (the renderer has no tool results, the record has
    /// no system notices) but they agree on how many user turns have happened,
    /// which is the only thing the index means.
    private func truncateRenderedTranscript(toPromptIndex targetPromptIndex: Int) {
        var seen = 0
        var cut: Int?
        for (index, item) in conversation.items.enumerated() {
            guard case .message(let message) = item, message.role == .user else { continue }
            if seen == targetPromptIndex {
                cut = index
                break
            }
            seen += 1
        }
        guard let cut else { return }
        conversation.truncate(to: cut)
        selection.clamp(itemCount: conversation.items.count)
        followsBottom = true
    }

    /// `/delete` — remove this session's stored transcript.
    ///
    /// Two steps, because there is no second copy and no undo. The confirmed
    /// step clears the in-memory history *before* removing the file: without
    /// that, the next turn would re-commit the whole conversation and the file
    /// would reappear, so "deleted" would have been a lie with a delay on it.
    private func deleteSession(confirmed: Bool) async {
        guard let sessionCatalog, !sessionID.isEmpty else {
            note("No active session to delete.")
            return
        }
        guard confirmed else {
            overlays.push(LiveSessionDeleteConfirmation.overlay(
                sessionID: sessionID,
                itemCount: await conversationHistory?.items.count ?? 0
            ))
            return
        }
        if let conversationHistory {
            do {
                try await conversationHistory.commit(sessionID: sessionID, items: [])
            } catch {
                appendMessage(PagerMessage(
                    role: .error,
                    text: "Could not clear the in-memory conversation, so nothing was deleted: \(error)"
                ))
                return
            }
        }
        do {
            guard try sessionCatalog.delete(sessionID: sessionID) else {
                note("This session has not been written to disk yet, so there was nothing to delete.")
                return
            }
        } catch {
            appendMessage(PagerMessage(
                role: .error,
                text: "Could not delete the session: \(error)"
            ))
            return
        }
        conversation.removeAll()
        selection.unfocus()
        followsBottom = true
        note("Session deleted. This session keeps its id, so anything you send now starts its history over.")
        overlays.push(.welcome(
            PagerWelcomeOverlay(subtitle: LivePagerChrome.collapseHome(workingDirectory)),
            capturesInput: false
        ))
    }

    /// Scroll so the block at `index` sits at the top of the transcript.
    ///
    /// The offset is *measured*, not estimated: the frame function is pure, so
    /// laying out the blocks before `index` at this frame's width returns the
    /// exact line count they occupy — which is the offset that puts `index`
    /// first. Any arithmetic on character counts would drift the moment a block
    /// wrapped differently from the guess.
    private func revealBlock(at index: Int) throws {
        guard conversation.items.indices.contains(index) else { return }
        guard index > 0 else {
            followsBottom = false
            scrollOffset = 0
            return
        }
        let probe = renderState(conversation: Array(conversation.items.prefix(index)))
        followsBottom = false
        scrollOffset = renderPagerFrame(probe).layout.totalContentLines
    }

    private func note(_ text: String) {
        appendMessage(PagerMessage(role: .system, text: text))
    }

    /// The one door for transcript messages: the welcome overlay blanks the
    /// entire transcript area (contentRows = screenHeight in
    /// PagerOverlayRender), so a message appended while it is up paints
    /// underneath it and never reaches the screen. Upstream never has this
    /// problem because its welcome is a separate view whose command errors
    /// land in a visible agent transcript (app_view.rs ActiveView::Welcome vs
    /// Agent). Cost: a notice arriving on the welcome screen replaces the
    /// logo instead of toasting over it like upstream — visible words win.
    /// Deliberate welcome re-shows (session delete, `.welcomeScreen`) push
    /// *after* their notes, so append-time dismissal leaves them up.
    private func appendMessage(_ message: PagerMessage) {
        overlays.dismiss(id: "welcome")
        conversation.appendMessage(message)
    }

    /// Write to a file when one is named, otherwise to the clipboard.
    private func deliver(_ text: String, to filePath: String?, label: String) throws {
        guard let filePath, !filePath.isEmpty else {
            do {
                try LivePagerClipboard.copy(text) { data in
                    try sink.write(String(decoding: data, as: UTF8.self))
                }
                try sink.flush()
                appendMessage(PagerMessage(
                    role: .system,
                    text: "\(label) copied — \(text.count) characters."
                ))
            } catch {
                appendMessage(PagerMessage(
                    role: .error,
                    text: "Could not reach the clipboard: \(error)"
                ))
            }
            return
        }
        let url = LivePagerClipboard.resolve(filePath, relativeTo: workingDirectory)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            appendMessage(PagerMessage(
                role: .system,
                text: "\(label) written to \(url.path)."
            ))
        } catch {
            appendMessage(PagerMessage(
                role: .error,
                text: "Could not write \(url.path): \(error)"
            ))
        }
    }


    /// A control key from the dashboard (`p`/`r`/`x`). Reported as a row
    /// selection by the overlay because the render layer cannot reach a run.
    private func handleWorkflowSelection(rowID: String) async -> Bool {
        guard let workflowRegistry,
              let command = LiveWorkflowOverlayBuilder.command(forRowID: rowID)
        else { return false }
        let message = await LiveWorkflowOverlayBuilder.apply(command, registry: workflowRegistry)
        appendMessage(PagerMessage(role: .system, text: message))
        let views = (try? await workflowRegistry.views()) ?? []
        overlays.dismiss(id: "workflows")
        overlays.push(.workflows(rows: LiveWorkflowOverlayBuilder.rows(from: views)))
        return true
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
    ///
    /// Returns a slash command the *controller* should run, when the row is one
    /// — only the command palette produces that. The renderer cannot run a
    /// command itself: the vocabulary and the mid-turn deferral both live in the
    /// controller, and duplicating either here is how the two would drift.
    @discardableResult
    private func select(overlayID: String, rowID: String) async -> String? {
        if overlayID.hasPrefix("permission:") {
            // The sheet's row ids are `PagerPermissionDecision` raw values, so a
            // click resolves the request exactly as the keyboard would.
            guard let decision = PagerPermissionDecision(rawValue: rowID) else { return nil }
            await resolve(
                overlayID: overlayID,
                requestID: String(overlayID.dropFirst("permission:".count)),
                decision: decision
            )
            return nil
        }
        if overlayID == "workflows" {
            // The dashboard stays open: a control key acts on a run and
            // refreshes the rows, it does not close the surface the user is
            // working in.
            _ = await handleWorkflowSelection(rowID: rowID)
            return nil
        }
        overlays.dismiss(id: overlayID)
        switch overlayID {
        case "model":
            await switchModel(to: rowID)
        case LiveSessionPicker.overlayID:
            // Row ids are session ids ("none" is the empty-list placeholder).
            // The command round-trip is how the selection reaches the runtime:
            // only the controller owns it, so the row resolves to the exact
            // `/resume <id>` the controller's resume handler services.
            guard rowID != "none" else { return nil }
            guard rowID != sessionID else {
                note("Already in session \(String(rowID.prefix(8))).")
                return nil
            }
            return "/resume \(rowID)"
        case "theme":
            // The row id is the theme name, so a click takes the identical path
            // a typed `/theme <name>` does — including the downgrade notice on
            // a terminal that cannot render it.
            if let message = applyTheme(named: rowID) {
                appendMessage(PagerMessage(role: .system, text: message))
            }
        case "command-palette":
            // The row id is the command's insert text, so handing it back runs
            // exactly what the row named — upstream's
            // `SendSlashCommandPreservingDraft` (`app/modals.rs:932`). The
            // composer is untouched, which is the "preserving draft" half.
            return rowID
        case LiveJumpPicker.overlayID:
            guard let index = Int(rowID) else { return nil }
            try? revealBlock(at: index)
        case LiveSessionDeleteConfirmation.overlayID:
            // Any row but the confirm row cancels, so a row id this renderer
            // does not recognise can only fail closed.
            guard rowID == LiveSessionDeleteConfirmation.confirmRowID else { return nil }
            await deleteSession(confirmed: true)
        case LiveRewindPicker.overlayID:
            guard let target = Int(rowID), let coordinator = sessionServices?.rewind else {
                return nil
            }
            // Deliberately a dry run: selecting a row in a list must not restore
            // files, which is not undoable. The preview says how to apply it.
            switch await LiveSessionCommands.apply(
                target: target,
                mode: .all,
                force: false,
                coordinator: coordinator,
                currentItems: await conversationHistory?.items ?? []
            ) {
            case .message(let text):
                note(text)
            case .overlay(let overlay):
                overlays.push(overlay)
            case .rewound(let index, _, let summary):
                await commitRewind(toPromptIndex: index, summary: summary)
            }
        default:
            break
        }
        return nil
    }

    /// Rebuild the live sampling stack for `modelID` and record what happened.
    ///
    /// A refused switch is reported as an error row and leaves `modelName` — and
    /// therefore the composer's border and the next turn's provider — alone.
    ///
    /// `effort` is a validated `/model <name> <effort>` override; `nil` keeps
    /// the model's catalog default.
    private func switchModel(to modelID: String, effort: ReasoningEffort? = nil) async {
        guard let modelSwitch else {
            // No provider session behind this renderer; the picker can still
            // relabel, but it must not claim the session changed.
            modelName = modelID
            appendMessage(PagerMessage(
                role: .system,
                text: "Model set to \(modelID). It applies to new sessions — "
                    + "this session keeps its current model."
            ))
            return
        }
        switch await modelSwitch.apply(modelID: modelID, effort: effort) {
        case .unchanged:
            appendMessage(PagerMessage(
                role: .system,
                text: "Already using \(modelID)."
            ))
        case .switched(let summary):
            modelName = summary.modelID
            reasoningEffort = summary.reasoningEffort?.asString
            // Mirror of upstream `set_session_model`'s tail
            // (handlers/model_switch.rs:299-303): the manager's current
            // model/effort track the session so `/model` defaults and any
            // future `/effort` surface read the applied state.
            catalogStore?.noteModelSwitch(
                catalogID: summary.requestedID,
                effort: summary.reasoningEffort
            )
            if let providerBoundarySync {
                do {
                    let boundary = await conversationHistory?.sharedExportBoundary
                    try await providerBoundarySync(boundary?.everUsedNonXAI ?? false)
                } catch {
                    note("Provider boundary summary could not be persisted: \(error)")
                }
            }
            appendMessage(PagerMessage(
                role: .system,
                text: summary.transcriptMessage
            ))
        case .failed(let modelID, let message):
            appendMessage(PagerMessage(
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
                let command = await select(overlayID: id, rowID: rowID)
                try renderState()
                return command.map { .runCommand($0) } ?? .consumed
            case .permission(let id, let requestID, let decision):
                await resolve(overlayID: id, requestID: requestID, decision: decision)
                try renderState()
                return .consumed
            case .setting(_, let event):
                // The modal has already folded the change into its own state,
                // so the repaint is correct either way; this carries the change
                // out to the session and to config.toml.
                await applySetting(event)
                try renderState()
                return .consumed
            }
        case .mouse(let mouse):
            guard mouseReportingEnabled else { return .notHandled }
            let command = try await handleMouse(mouse)
            return command.map { .runCommand($0) } ?? .consumed
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

    /// Returns a slash command when the click landed on a command-palette row,
    /// exactly as the keyboard path does — a click and an Enter must resolve the
    /// same row the same way.
    private func handleMouse(_ event: MouseEvent) async throws -> String? {
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
                    return nil
                }
            }
            switch event.kind {
            case .scrollUp:
                scrollUp(by: wheelTuning.linesPerEvent)
            case .scrollDown:
                scrollDown(by: wheelTuning.linesPerEvent)
            case .scrollLeft, .scrollRight:
                return nil
            default:
                return nil
            }
            try renderState()
            return nil
        }

        guard event.kind == .down, event.resolvedButton == .left, let hit else { return nil }
        if let close = hit.closeButton, close.contains(x: event.x, y: event.y) {
            overlays.dismiss(id: hit.id)
            if currentPermissionRequestID.map({ "permission:\($0)" }) == hit.id {
                currentPermissionRequestID = nil
            }
            try renderState()
            return nil
        }
        if let row = hit.row(atX: event.x, y: event.y) {
            let command = await select(overlayID: hit.id, rowID: row.id)
            try renderState()
            return command
        }
        var command: String?
        if let hint = hit.hints.first(where: { $0.frame.contains(x: event.x, y: event.y) }),
           let key = Self.keyEvent(forHint: hint.key)
        {
            switch overlays.handle(key, viewportHeight: max(1, hit.content.height)) {
            case .selected(let id, let rowID):
                command = await select(overlayID: id, rowID: rowID)
            case .permission(let id, let requestID, let decision):
                await resolve(overlayID: id, requestID: requestID, decision: decision)
            case .setting(_, let event):
                await applySetting(event)
            case .ignored, .redraw, .consumed, .dismissed:
                break
            }
            try renderState()
        }
        return command
    }

    /// Session-side effects of a settings change.
    ///
    /// The modal owns its own state and has already applied the change to
    /// itself, so this carries only the effects that reach past the overlay:
    /// the two input modes this renderer reads directly, and then the write to
    /// disk and the live theme swap.
    private func applySetting(_ event: PagerSettingsEvent) async {
        if case .commit(let key, .bool(let flag)) = event {
            switch key {
            case "multiline_mode": inputModes.isMultiline = flag
            case "vim_mode": inputModes.isVimMode = flag
            default: break
            }
        }
        await applySettingsEvent(event)
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

    // MARK: - Theme and settings

    /// Switch the live palette. Returns the message to echo, or `nil` when the
    /// name did not resolve.
    ///
    /// The resolution runs through the same clamp-then-quantize path startup
    /// uses, so `/theme oscura` on a 16-color terminal lands on GrokNight and
    /// says so rather than painting an unreadable frame.
    func applyTheme(named name: String) -> String? {
        guard let preference = PagerThemePreference.named(name) else { return nil }
        let resolution = pagerResolveTheme(
            preference: preference,
            colorLevel: colorLevel,
            appearance: preference == .auto ? PagerSystemAppearance.detect() : nil,
            terminalNativeLock: mode != .fullScreen
        )
        themePreference = preference
        renderTheme = resolution.theme
        try? renderState()

        // Minimal mode locks the terminal's own palette, so the preference is
        // stored but nothing on screen changes. Saying "Theme: Tokyo Night"
        // while painting terminal-default would just look broken.
        if resolution.kind == .terminalDefault, preference != .fixed(.terminalDefault) {
            return "Saved \(preference.displayName). Minimal mode uses your "
                + "terminal's own colors; run fullscreen to see it."
        }
        if case .fixed(let requested) = preference, requested != resolution.kind {
            return "Theme \(requested.displayName) needs a truecolor terminal; "
                + "using \(resolution.kind.displayName)."
        }
        return "Theme: \(preference.displayName)"
    }

    /// Every theme `/theme` can offer on this terminal.
    var availableThemeNames: [String] {
        (["auto"] + PagerThemeKind.available(colorLevel: colorLevel).map(\.rawValue))
    }

    /// Build the settings modal from what is on disk right now.
    ///
    /// Read at open time rather than cached at startup: another process may
    /// have edited `config.toml` since, and a modal showing stale values would
    /// write them back on the next unrelated toggle.
    func settingsOverlay(deepLinkKey: String? = nil) -> PagerSettingsOverlay {
        let store = PagerSettingsStore(configPath: LiveInteractiveControllerRenderer.configPath())
        let activeCatalog = catalogStore?.pickerEntries() ?? modelCatalog
        var overlay = PagerSettingsOverlay(
            values: (try? store.load()) ?? [:],
            dynamicChoices: [
                .activeModelCatalog: LiveModelPicker.sorted(activeCatalog).map { entry in
                    PagerSettingChoice(
                        canonical: entry.id,
                        display: LiveModelPicker.providerLabel(forProviderID: entry.providerID)
                            .map { "\($0) · \(entry.name)" } ?? entry.name,
                        summary: LiveModelPicker.description(for: entry)
                    )
                }
            ],
            multiSelectEnabled: [
                "opencode_go_models": (try? store.loadMultiSelect(key: "opencode_go_models")) ?? []
            ],
            // Minimal mode hides the rows the reference marks `hidden_in_minimal`,
            // because none of them have a surface there to affect.
            minimalMode: mode != .fullScreen
        )
        if let deepLinkKey {
            let rows = overlay.visibleRows
            if let index = rows.firstIndex(where: { $0.settingKey == deepLinkKey }) {
                overlay.selectedIndex = index
                overlay.expandedKeys.insert(deepLinkKey)
            }
        }
        return overlay
    }

    /// Apply a decision the settings modal made.
    ///
    /// A failed write is reported into the transcript rather than swallowed: the
    /// modal has already redrawn the row as changed, so silence would leave the
    /// screen disagreeing with the disk.
    func applySettingsEvent(_ event: PagerSettingsEvent) async {
        let store = PagerSettingsStore(configPath: LiveInteractiveControllerRenderer.configPath())
        switch event {
        case .preview(let key, let value):
            // Only the theme rows preview, and a preview is display-only.
            guard key == "theme" || key == "auto_dark_theme" || key == "auto_light_theme",
                  case .string(let name) = value
            else { return }
            _ = applyTheme(named: name)

        case .commit(let key, let value):
            if key == "theme", case .string(let name) = value {
                _ = applyTheme(named: name)
            }
            do {
                try store.write(key: key, value: value)
                reloadCatalogInput()
            } catch PagerSettingsStoreError.notPersistable {
                // Session-local rows have no disk home by design; the modal's
                // own copy is the whole of their state.
                return
            } catch {
                appendMessage(PagerMessage(
                    role: .error,
                    text: "Could not save \(key): \(error)"
                ))
            }

        case .toggleMultiSelect(let key, let choice, let enabled):
            var current = (try? store.loadMultiSelect(key: key)) ?? []
            if enabled { current.insert(choice) } else { current.remove(choice) }
            do {
                try store.writeMultiSelect(key: key, enabled: current)
                reloadCatalogInput()
            } catch {
                appendMessage(PagerMessage(
                    role: .error,
                    text: "Could not save \(key): \(error)"
                ))
            }

        case .resetRequested(let key):
            // A secret row's reset is a credential *removal*, not a config
            // write — upstream maps `SecretStatus::Missing` to the provider's
            // Clear action (`dispatch/settings/ui.rs:1447-1448`). Routed here
            // because `store.reset` classifies secret rows `notPersistable`
            // and would silently swallow the request.
            if let meta = PagerSettingsRegistry.default.entries.first(where: { $0.key == key }),
               case .secretStore = meta.storage {
                applySecret(key: key, value: "")
                return
            }
            do {
                try store.reset(key: key)
                if key == "theme" { _ = applyTheme(named: "groknight") }
                reloadCatalogInput()
            } catch PagerSettingsStoreError.notPersistable {
                return
            } catch {
                appendMessage(PagerMessage(
                    role: .error,
                    text: "Could not reset \(key): \(error)"
                ))
            }

        case .secret(let key, let value):
            applySecret(key: key, value: value)
        }
    }

    /// Persist a settings-modal secret into the owner-protected auth store —
    /// the SAME store the live credential resolver reads
    /// (`readProviderAPIKey` over `providerAPIKeyScope`, Storage.swift:183),
    /// never `config.toml`. An empty value removes the key (upstream
    /// `SecretStatus::Missing` → the Clear action, ui.rs:1447-1448; write
    /// path `store_provider_api_key` / `clear_provider_api_key`,
    /// effects/mod.rs:832-843).
    private func applySecret(key: String, value: String) {
        guard let meta = PagerSettingsRegistry.default.entries.first(where: { $0.key == key }),
              case .secretStore(let account) = meta.storage
        else {
            appendMessage(PagerMessage(
                role: .error,
                text: "Setting \(key) has no secret storage; nothing was saved."
            ))
            return
        }
        // Row account → auth.json scope. Kimi Platform deliberately reuses
        // the historical `kimi::api_key` scope so existing logins keep
        // working (`kimi_api_key_scope`, ProviderScopes.swift:46-51); every
        // other account is its provider's own `<provider>::api_key`.
        let scope = account == "kimi_platform"
            ? kimiAPIKeyScope(.platform)
            : providerAPIKeyScope(account)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if trimmed.isEmpty {
                try clearScopedAPIKey(grokHome: openGrokHome, scope: scope)
                note("Removed \(meta.label). New sessions and model switches no longer see it.")
            } else {
                try storeScopedAPIKey(grokHome: openGrokHome, scope: scope, apiKey: trimmed)
                note("Saved \(meta.label). It applies to new sessions and model switches; "
                    + "the running session keeps its current credential.")
            }
        } catch {
            appendMessage(PagerMessage(
                role: .error,
                text: "Could not save \(meta.label): \(error)"
            ))
            return
        }
        // Make the change visible to the catalog publish gate and kick the
        // background refresh, mirroring upstream's post-store
        // `apply_meta_models` (effects/mod.rs:844-861). KNOWN DEFERRAL: the
        // upstream rebind of LIVE sessions after a credential change
        // (task_result.rs:1087-1300) is not ported — the new key reaches new
        // sessions and `/model` switches only.
        catalogStore?.refreshCredentialSnapshot()
        catalogStore?.spawnBackgroundRefresh()
    }

    /// `$OPENGROK_HOME/config.toml`, the user-level config the reference writes.
    private static func configPath() -> URL {
        OpenGrokHomeResolver
            .resolve(environment: ProcessInfo.processInfo.environment)
            .appendingPathComponent("config.toml")
    }

    private func reloadCatalogInput() {
        guard let catalogStore else { return }
        catalogStore.updateInput(liveCatalogResolutionInput(
            workingDirectory: URL(fileURLWithPath: workingDirectory, isDirectory: true),
            environment: ProcessInfo.processInfo.environment
        ))
    }

    /// Repaint through the coalesced path: however many state changes arrive
    /// inside one paint-cadence window fold into a single frame, and a folded
    /// frame is guaranteed to paint by the one-shot flush timer. This is the
    /// other half of the animation ticker — 30 fps of ticks plus per-event
    /// repaints must not become 30+ paints per second.
    private func renderState() throws {
        let result = layOutCurrentFrame()
        if try renderer.requestFrame(result, at: Self.monotonicNow()) == nil {
            armFlushTimerIfNeeded()
        }
        publishMotionState()
    }

    /// Run the frame function and refresh the geometry bookkeeping mouse
    /// routing reads. Split out of `renderState` because the flush timer
    /// re-lays-out at flush time — a folded frame must paint the *latest*
    /// state, not the one that was folded.
    private func layOutCurrentFrame() -> PagerRenderResult {
        let result = renderPagerFrame(renderState(conversation: conversation.items))
        // Fresh every frame: a modal that no longer fits publishes no bounds.
        lastOverlayBounds = result.overlays
        lastConversationHeight = max(1, result.layout.conversation.height)
        lastMaximumScrollOffset = max(
            0,
            result.layout.totalContentLines - result.layout.conversation.height
        )
        if followsBottom { scrollOffset = lastMaximumScrollOffset }
        return result
    }

    /// Arm a one-shot timer for `renderer.scheduledFrameAt`. Idempotent: at
    /// most one flush is ever pending, and a fresh request folded while one
    /// is armed rides the same flush.
    private func armFlushTimerIfNeeded() {
        guard pendingFlushTask == nil,
              let scheduled = renderer.scheduledFrameAt
        else { return }
        let delay = max(0, scheduled - Self.monotonicNow())
        // Inherits this actor's isolation; the sleep suspends without
        // holding it.
        pendingFlushTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000) + 1_000_000)
            self.flushPendingFrameNow()
        }
    }

    private func flushPendingFrameNow() {
        pendingFlushTask = nil
        guard !restored, renderer.scheduledFrameAt != nil else { return }
        let result = layOutCurrentFrame()
        // A throw here has the same recovery as the next event's repaint;
        // surfacing it has no channel that would not kill the run.
        _ = try? renderer.flushPendingFrame(result, at: Self.monotonicNow())
        // Not yet due (the timer raced a fresher fold): re-arm rather than
        // drop the frame.
        armFlushTimerIfNeeded()
    }

    /// Monotonic seconds for the paint clock. Only ever compared against
    /// itself, so the epoch (process uptime) does not matter.
    private static func monotonicNow() -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    // MARK: - Animation

    /// One wall-clock tick from the controller's motion ticker: sample the
    /// clock into the frame state and repaint through the coalesced path.
    func renderAnimationTick(_ frame: OpenGrokPagerAnimationFrame) async throws {
        motion = PagerMotionSnapshot(
            tick: frame.tick,
            seconds: frame.seconds,
            enabled: motionEnabled
        )
        if frame.demand == .slow {
            // The welcome shimmer advances at 12 fps of *frames*; a slow tick
            // that lands inside the same shimmer frame would repaint an
            // identical screen (app_view.rs:5760-5766).
            let shimmerFrame = PagerMotion.shimmerFrame(atSeconds: frame.seconds)
            guard shimmerFrame != lastShimmerFrame else { return }
            lastShimmerFrame = shimmerFrame
        }
        try renderState()
    }

    /// Report what is moving on screen to the controller's ticker whenever it
    /// changes. This is what turns the ticker on for the welcome shimmer with
    /// no turn running, and what lets it park when the screen goes still.
    private func publishMotionState() {
        let state = PagerMotionState(
            hasRunningTurn: turnActivity != nil,
            // Approximated as "a streaming block exists and the viewport
            // follows the tail". A block streaming above a scrolled-away
            // viewport misses the reference's finer visibility test and stays
            // animated; the cost is spare frames, never a frozen spinner.
            hasVisibleRunningBlock: followsBottom && hasStreamingBlock,
            hasBackgroundTasks: false,
            showsWelcomeLogo: overlays.contains(id: "welcome"),
            hasPendingFlash: hasPendingFlash,
            motionEnabled: motionEnabled
        )
        guard state != lastPublishedMotionState else { return }
        lastPublishedMotionState = state
        guard let motionSink else { return }
        Task { await motionSink(state) }
    }

    private var hasStreamingBlock: Bool {
        conversation.items.contains { item in
            switch item {
            case .message(let message): return message.isStreaming
            case .tool(let tool): return tool.state == .running || tool.state == .pending
            case .separator: return false
            }
        }
    }

    private var hasPendingFlash: Bool {
        guard motionEnabled else { return false }
        return conversation.items.contains { item in
            guard case .tool(let tool) = item, let finishedAt = tool.finishedAt else {
                return false
            }
            return PagerMotion.isFlashing(finishedAt: finishedAt, now: motion.seconds)
        }
    }

    /// Re-read the compaction coordinator's context accounting — the status
    /// bar's ramp shows the same numbers auto-compaction decides on. Called
    /// at turn boundaries; between turns the figures cannot move.
    private func refreshContextUsage() async {
        guard let compaction else { return }
        contextUsage = await compaction.usage()
    }

    /// The frame model for a given block list.
    ///
    /// Parameterised on the conversation so `revealBlock` can lay out a prefix
    /// through the identical chrome and measure where a block starts. Every
    /// other field is this frame's real state, which is what makes the
    /// measurement match the frame the user is looking at.
    private func renderState(conversation blocks: [PagerConversationItem]) -> PagerRenderState {
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
        // Elapsed rides the motion clock so the readout and the spinner agree
        // frame-for-frame; the wall-clock fallback only serves motion-disabled
        // terminals, where no animation frame ever advances `motion.seconds`.
        let elapsed: TimeInterval? = motionEnabled
            ? turnStartedAtSeconds.map { max(0, motion.seconds - $0) }
            : turnStartedAt.map { Date().timeIntervalSince($0) }
        let streamedTokens = Int(estimateTokens(bytes: turnOutputUTF8Count))
        return PagerRenderState(
            size: terminalSize,
            statusBar: PagerStatusBar(
                workingDirectory: LivePagerChrome.collapseHome(workingDirectory),
                contextUsedTokens: contextUsage.map { Int($0.usedTokens) },
                contextTotalTokens: contextUsage.map { Int($0.contextWindow) },
                queuedPromptCount: queuedPromptCount
            ),
            conversation: blocks,
            turnStatus: turnActivity.map { label in
                PagerTurnStatus(
                    label: isCancelling ? "Cancelling\u{2026}" : label,
                    isCancelling: isCancelling,
                    tick: motion.tick,
                    elapsed: elapsed,
                    tokenCount: streamedTokens > 0 ? streamedTokens : nil,
                    queuedPromptCount: queuedPromptCount,
                    // Bare Enter force-sends the head only when the composer is
                    // empty; with a draft, Enter queues it behind the others.
                    queueIsSendable: queuedPromptCount > 0 && prompt.text.isEmpty,
                    // The pulsing "waiting on you" diamond while a permission
                    // sheet blocks the turn (`turn_status.rs:484-486`). The
                    // idle-monitor pulse is deliberately not produced: this
                    // session has no idle-watcher feed, and a guessed monitor
                    // glyph would claim watchers that do not exist.
                    indicator: currentPermissionRequestID != nil
                        ? .pendingUserDiamond
                        : .spinner
                )
            },
            completions: completions,
            input: PagerComposerState(
                text: prompt.text,
                cursorCharacterOffset: prompt.cursorOffset,
                // The composer is unfocused exactly while the scrollback holds
                // a selection — the two halves of one focus model.
                isFocused: !selection.isFocused,
                cursorVisible: !selection.isFocused,
                modelName: modelName,
                reasoningEffort: reasoningEffort,
                isMultiline: inputModes.isMultiline,
                maximumHeight: max(3, terminalSize.height / 2)
            ),
            shortcuts: PagerShortcutsBar(
                // The bar follows the focus, the way upstream's does: it lists
                // the bindings of the region that will actually receive the
                // next key.
                hints: selection.isFocused
                    ? LivePagerChrome.scrollbackHints(isVimMode: inputModes.isVimMode)
                    : LivePagerChrome.shortcutHints(isTurnRunning: isTurnRunning),
                pendingKey: prompt.pendingConfirmationKey,
                pendingLabel: prompt.pendingConfirmationLabel
            ),
            scrollPosition: followsBottom ? .followTail : .offset(scrollOffset),
            theme: renderTheme,
            selectedBlockIndex: selection.index,
            overlays: overlays,
            motion: motion
        )
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
        // `--minimal` degrades here rather than refusing. This factory serves
        // the path with no interactive input, which `resolveInteractivePagerMode`
        // cannot see — it only knows whether a TTY exists, so a TTY with no
        // input sink still arrives as `.minimal`. Refusing produced
        // "unsupported: interactive pager mode minimal" where the flag used to
        // work. Inline is a faithful downgrade: minimal is scrollback-native,
        // and `LiveInteractivePagerRenderer` already renders every
        // non-fullscreen mode as inline. `.plain` has no interactive rendering
        // at all, so it keeps refusing.
        let resolved: OpenGrokPagerMode
        switch mode {
        case .fullScreen, .inline:
            resolved = mode
        case .minimal:
            resolved = .inline
        case .plain:
            throw CLIApplicationError.unsupported(route: "interactive pager mode \(mode.rawValue)")
        }
        return OpenGrokPagerForwardingFrontend(
            renderer: LiveInteractivePagerRenderer(mode: resolved, terminal: terminal, prompt: prompt),
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
