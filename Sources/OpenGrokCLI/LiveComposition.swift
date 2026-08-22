import Foundation
import OpenGrokAgentCoordinator
import OpenGrokAgentDefinitions
import OpenGrokACPRuntime
import OpenGrokAuth
import OpenGrokCodeMode
import OpenGrokCompaction
import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokDiagnostics
import OpenGrokFileTools
import OpenGrokFastWorktree
import OpenGrokHTTP
import OpenGrokHooks
import OpenGrokHooksPluginTypes
import OpenGrokHunkTracker
import OpenGrokInterjection
import OpenGrokLSP
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
import OpenGrokScheduler
import OpenGrokSessionRuntime
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase
import OpenGrokShellSessionSupport
import OpenGrokSubagentResolution
import OpenGrokTerminalCore
import OpenGrokTextArea
import OpenGrokToolRegistry
import OpenGrokToolTypes
import OpenGrokToolsAPI
import OpenGrokTTY
import OpenGrokVersion
import OpenGrokVoice
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
    /// Session-selected service-tier id (`"priority"` when `/fast` is on).
    /// `nil` is standard routing — the field is then absent on the wire.
    /// Upstream carries this on the session's sampling config
    /// (spawn.rs:723-736, sampler_turn.rs:834-850) and the sampler backfills
    /// requests from it (client.rs:1806-1808, :3234-3236).
    public var serviceTier: String?
    public var codexMultiAgentV2: Bool
    public var temperature: Float?
    public var topP: Float?
    public var maxCompletionTokens: UInt32?
    public var contextWindow: UInt64?

    public init(
        reasoningEffort: ReasoningEffort? = nil,
        reasoningSummary: ReasoningSummary? = nil,
        serviceTier: String? = nil,
        codexMultiAgentV2: Bool = false,
        temperature: Float? = nil,
        topP: Float? = nil,
        maxCompletionTokens: UInt32? = nil,
        contextWindow: UInt64? = nil
    ) {
        self.reasoningEffort = reasoningEffort
        self.reasoningSummary = reasoningSummary
        self.serviceTier = serviceTier
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
    ///
    /// `serviceTier` is the session's tier selection (`/fast`). It applies
    /// only when the entry advertises that tier id — a model without the tier
    /// keeps `nil`, which is how upstream clears a stale selection on switch
    /// (`set_current`, pager acp/model_state.rs:199-212).
    public init(
        entry: ModelEntry,
        effortOverride: ReasoningEffort? = nil,
        serviceTier: String? = nil
    ) {
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
            serviceTier: serviceTier.flatMap { tier in
                info.serviceTiers.contains { $0.id == tier } ? tier : nil
            },
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
    /// The actually enforced execution policy, disclosed only to Codex.
    public let codexPermissions: CodexPermissions?
    public let bearerResolver: (any BearerResolver)?
    public let credentialProvider: (any AuthCredentialProvider)?
    public let transport: (any HTTPTransport)?

    public var reasoningEffort: ReasoningEffort? { tuning.reasoningEffort }
    /// Session-selected service-tier id (`/fast`); `nil` = standard routing.
    public var serviceTier: String? { tuning.serviceTier }

    public init(
        model: String,
        baseURL: String,
        apiKey: String,
        provider: ModelProvider = .xai,
        apiBackend: ApiBackend = .chatCompletions,
        extraHeaders: [String: String] = [:],
        queryParams: [String: String] = [:],
        tuning: OpenGrokLiveSamplingTuning = OpenGrokLiveSamplingTuning(),
        codexPermissions: CodexPermissions? = nil,
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
        self.codexPermissions = provider == .codex ? codexPermissions : nil
        self.bearerResolver = bearerResolver
        self.credentialProvider = credentialProvider
        self.transport = transport
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model == rhs.model && lhs.baseURL == rhs.baseURL && lhs.apiKey == rhs.apiKey &&
        lhs.provider == rhs.provider && lhs.apiBackend == rhs.apiBackend &&
        lhs.extraHeaders == rhs.extraHeaders && lhs.queryParams == rhs.queryParams &&
        lhs.tuning == rhs.tuning && lhs.codexPermissions == rhs.codexPermissions
    }

    func withCodexPermissions(_ permissions: CodexPermissions?) -> Self {
        Self(
            model: model,
            baseURL: baseURL,
            apiKey: apiKey,
            provider: provider,
            apiBackend: apiBackend,
            extraHeaders: extraHeaders,
            queryParams: queryParams,
            tuning: tuning,
            codexPermissions: permissions,
            bearerResolver: bearerResolver,
            credentialProvider: credentialProvider,
            transport: transport
        )
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
    /// Durable routing identity shared by forks; distinct from actual session identity.
    public let cacheAffinityID: String?
    public let turnID: String
    /// Stable logical turn shared by its compaction and tool-follow-up requests.
    public let logicalTurnID: String?
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
    /// Per-request reasoning effort override. When set, wins over the
    /// sampler config default in `SamplingClient.applyConversationDefaults`
    /// (nil request field → config fills in). Child subagent turns use this
    /// for `runtime.reasoningEffort` (Rust handle_request.rs:705-714).
    public let reasoningEffort: ReasoningEffort?
    /// Session policy for this turn. Child requests can override the parent's
    /// snapshot without exposing Codex metadata to a non-Codex provider.
    public let codexPermissions: CodexPermissions?

    public init(
        sessionID: String,
        cacheAffinityID: String? = nil,
        turnID: String,
        logicalTurnID: String? = nil,
        model: String,
        prompt: String,
        items: [ConversationItem]? = nil,
        tools: [ToolSpec] = [],
        jsonSchema: JSONValue? = nil,
        reasoningEffort: ReasoningEffort? = nil,
        codexPermissions: CodexPermissions? = nil
    ) {
        self.sessionID = sessionID
        self.cacheAffinityID = cacheAffinityID
        self.turnID = turnID
        self.logicalTurnID = logicalTurnID
        self.model = model
        self.prompt = prompt
        self.items = items ?? [.user(prompt)]
        self.tools = tools
        self.jsonSchema = jsonSchema
        self.reasoningEffort = reasoningEffort
        self.codexPermissions = codexPermissions
    }
}

public enum OpenGrokLiveSamplingEvent: Sendable, Equatable {
    case output(String)
    case status(String)
    case reasoning(String)
    case responseStarted(
        messageID: String,
        model: String,
        inputTokens: UInt64,
        cacheReadInputTokens: UInt64,
        cacheCreationInputTokens: UInt64
    )
    case reasoningCompleted(signature: String)
    case toolCallDelta(
        toolIndex: UInt32,
        id: String?,
        name: String?,
        argumentsDelta: String?
    )
    case toolCallArgumentsComplete(toolIndex: UInt32, id: String?, name: String?)
    case retrying(
        attempt: UInt32,
        maxRetries: UInt32,
        kind: SamplingErrorKind,
        reason: String
    )
    /// Typed failure from the sampler. Keep `SamplingErrorInfo` intact so
    /// consumers can branch on kind (auth/rate-limit/…) rather than a flat
    /// message string alone.
    case failed(SamplingErrorInfo)
    case backendToolCallStarted(callId: String, name: String)
    case backendToolCallCompleted(callId: String, name: String, result: JSONValue?)
}

/// Pure mapping from a layer-2 `SamplingEvent` to the live sampler surface.
/// Extracted so unit tests can assert event forwarding without spinning a TUI.
enum LiveSamplingStreamMapper {
    enum Action: Sendable, Equatable {
        case emit(OpenGrokLiveSamplingEvent)
        case completed(ConversationResponse)
        case failed(SamplingErrorInfo)
    }

    /// Returns `nil` for events the live turn ignores (streamStarted,
    /// firstToken, modelMetadata, empty channel tokens).
    static func map(_ event: SamplingEvent) -> Action? {
        switch event {
        case .responseStarted(
            _,
            let messageID,
            let model,
            let inputTokens,
            let cacheReadInputTokens,
            let cacheCreationInputTokens
        ):
            return .emit(.responseStarted(
                messageID: messageID,
                model: model,
                inputTokens: inputTokens,
                cacheReadInputTokens: cacheReadInputTokens,
                cacheCreationInputTokens: cacheCreationInputTokens
            ))
        case .reasoningCompleted(_, let signature):
            return .emit(.reasoningCompleted(signature: signature))
        case .channelToken(_, .text, let text, _):
            guard !text.isEmpty else { return nil }
            return .emit(.output(text))
        case .channelToken(_, .reasoning, let text, _):
            guard !text.isEmpty else { return nil }
            return .emit(.reasoning(text))
        case .toolCallDelta(_, let toolIndex, let id, let name, let argumentsDelta):
            return .emit(.toolCallDelta(
                toolIndex: toolIndex,
                id: id,
                name: name,
                argumentsDelta: argumentsDelta
            ))
        case .toolCallArgumentsComplete(_, let toolIndex, let id, let name):
            return .emit(.toolCallArgumentsComplete(
                toolIndex: toolIndex,
                id: id,
                name: name
            ))
        case .retrying(_, let attempt, let maxRetries, let kind, let reason, _, _):
            return .emit(.retrying(
                attempt: attempt,
                maxRetries: maxRetries,
                kind: kind,
                reason: reason
            ))
        case .backendToolCallStarted(_, let callId, let name):
            return .emit(.backendToolCallStarted(callId: callId, name: name))
        case .backendToolCallCompleted(_, let callId, let name, let result):
            return .emit(.backendToolCallCompleted(callId: callId, name: name, result: result))
        case .completed(_, let response, _):
            return .completed(response)
        case .failed(_, let error):
            return .failed(error)
        case .streamStarted, .firstToken, .modelMetadata:
            return nil
        }
    }
}

public struct OpenGrokLiveSamplingResponse: Sendable, Equatable {
    public let output: String
    public let stopReason: String?
    public let items: [ConversationItem]
    public let toolCalls: [ToolCall]
    public let usage: TokenUsage?
    public let costUsdTicks: Int64?
    public let messageID: String?
    public let rawStopReason: String?
    public let stopSequence: String?

    public init(
        output: String,
        stopReason: String? = nil,
        items: [ConversationItem]? = nil,
        toolCalls: [ToolCall] = [],
        usage: TokenUsage? = nil,
        costUsdTicks: Int64? = nil,
        messageID: String? = nil,
        rawStopReason: String? = nil,
        stopSequence: String? = nil
    ) {
        self.output = output
        self.stopReason = stopReason
        self.usage = usage
        self.costUsdTicks = costUsdTicks
        self.messageID = messageID
        self.rawStopReason = rawStopReason
        self.stopSequence = stopSequence
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

private final class LiveCodexTurnStateRegistry: @unchecked Sendable {
    private struct CurrentTurn {
        let turnID: String
        let cell: CodexTurnStateCell
    }

    private let lock = NSLock()
    private var currentTurns: [String: CurrentTurn] = [:]

    func state(sessionID: String, turnID: String) -> CodexTurnStateCell {
        lock.lock()
        defer { lock.unlock() }

        if let current = currentTurns[sessionID], current.turnID == turnID {
            return current.cell
        }
        let cell = CodexTurnStateCell()
        currentTurns[sessionID] = CurrentTurn(turnID: turnID, cell: cell)
        return cell
    }
}

public struct OpenGrokLiveSampler: Sendable {
    public typealias Emit = @Sendable (OpenGrokLiveSamplingEvent) async -> Void

    private let sampleOperation: @Sendable (
        OpenGrokLiveSamplingRequest,
        @escaping Emit
    ) async throws -> OpenGrokLiveSamplingResponse
    private let codexTurnStateRegistry: LiveCodexTurnStateRegistry?

    public init(
        sample: @escaping @Sendable (
            OpenGrokLiveSamplingRequest,
            @escaping Emit
        ) async throws -> OpenGrokLiveSamplingResponse
    ) {
        self.sampleOperation = sample
        self.codexTurnStateRegistry = nil
    }

    private init(
        codexTurnStateRegistry: LiveCodexTurnStateRegistry?,
        sample: @escaping @Sendable (
            OpenGrokLiveSamplingRequest,
            @escaping Emit
        ) async throws -> OpenGrokLiveSamplingResponse
    ) {
        self.sampleOperation = sample
        self.codexTurnStateRegistry = codexTurnStateRegistry
    }

    public func sample(
        _ request: OpenGrokLiveSamplingRequest,
        emit: @escaping Emit
    ) async throws -> OpenGrokLiveSamplingResponse {
        try await sampleOperation(request, emit)
    }

    func codexTurnState(sessionID: String, turnID: String) -> CodexTurnStateCell? {
        codexTurnStateRegistry?.state(sessionID: sessionID, turnID: turnID)
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
        let configuredReasoningEffort = configuration.provider == .gemini
            ? configuration.tuning.reasoningEffort.flatMap {
                GeminiModels.normalizedReasoningEffort(
                    modelID: configuration.model,
                    effort: $0
                )
            }
            : configuration.tuning.reasoningEffort
        // The tuning fields ride on the config, not per-request: the sampler
        // backfills them in `applyConversationDefaults`, which is upstream's
        // `apply_defaults` seam (xai-grok-sampler client.rs:1148, :1460,
        // :3231-3233). Dropping any of them here silently reverts the model
        // to provider defaults — the audit that motivated this found NO
        // effort ever reaching an outbound request.
        let samplerConfig = SamplerConfig(
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
            reasoningEffort: configuredReasoningEffort,
            serviceTier: configuration.tuning.serviceTier,
            reasoningSummary: configuration.tuning.reasoningSummary,
            codexMultiAgentV2: configuration.tuning.codexMultiAgentV2,
            codexPermissions: configuration.codexPermissions,
            bearerResolver: bearerResolver
        )
        let client = try SamplingClient(config: samplerConfig, transport: transport)
        let codexTurnStateRegistry = configuration.provider == .codex
            ? LiveCodexTurnStateRegistry()
            : nil
        return OpenGrokLiveSampler(codexTurnStateRegistry: codexTurnStateRegistry) { request, emit in
            await emit(.status("sampling"))
            let turnClient: SamplingClient
            if let codexTurnStateRegistry {
                let state = codexTurnStateRegistry.state(
                    sessionID: request.sessionID,
                    turnID: request.logicalTurnID ?? request.turnID
                )
                turnClient = try SamplingClient(
                    config: samplerConfig,
                    transport: transport,
                    codexTurnState: state
                )
            } else {
                turnClient = client
            }
            // Streamed events (text, reasoning, tool deltas, retries, backend
            // tools, typed failures) are forwarded as they arrive; the
            // collected response carries the final assistant bytes, so nothing
            // is re-emitted once the turn completes.
            let requestedReasoningEffort = configuration.provider == .gemini
                ? request.reasoningEffort.flatMap {
                    GeminiModels.normalizedReasoningEffort(
                        modelID: request.model,
                        effort: $0
                    )
                }
                : request.reasoningEffort
            let response = try await turnClient.streamConversation(ConversationRequest(
                items: request.items,
                tools: request.tools,
                toolChoice: request.tools.isEmpty ? nil : .auto,
                model: request.model,
                xGrokReqId: request.turnID,
                xGrokSessionId: request.sessionID,
                xGrokCacheAffinityId: request.cacheAffinityID,
                xGrokTurnIdx: request.turnID,
                reasoningEffort: requestedReasoningEffort,
                jsonSchema: request.jsonSchema
            ), codexPermissions: request.codexPermissions ?? configuration.codexPermissions) { event in
                await emit(event)
            }
            let output = response.assistantText()
            return OpenGrokLiveSamplingResponse(
                output: output,
                stopReason: response.stopReason?.asString,
                items: response.items,
                toolCalls: response.assistant()?.toolCalls ?? [],
                usage: response.usage,
                costUsdTicks: response.costUsdTicks,
                messageID: response.messageID,
                rawStopReason: response.rawStopReason,
                stopSequence: response.stopSequence
            )
        }
    }
}

extension SamplingClient {
    /// Run one turn over the backend's streaming API, forwarding live sampler
    /// events (text, reasoning, tool-call deltas, retries, backend tools,
    /// typed failures) as they arrive.
    ///
    /// The returned response is the same value ``conversationCollect`` would
    /// have produced — both drain the identical layer-2 event stream and read
    /// the terminal `completed` event — so persisted history is unaffected by
    /// streaming. Cancellation propagates through the underlying `AsyncStream`,
    /// which tears down the in-flight HTTP request on termination.
    ///
    /// Partial tool-argument JSON is forwarded only as UI hydration; callers
    /// must not persist or execute from `.toolCallDelta`.
    fileprivate func streamConversation(
        _ request: ConversationRequest,
        requestId: RequestId = .random(),
        idleTimeout: MonotonicDuration = .seconds(300),
        codexPermissions: CodexPermissions? = nil,
        onEvent: @escaping @Sendable (OpenGrokLiveSamplingEvent) async -> Void
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
                try await conversationStreamResponses(request, codexPermissions: codexPermissions)
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

        var textCoalescer = LiveTextDeltaCoalescer()
        var reasoningCoalescer = LiveTextDeltaCoalescer()
        // Coalesce tool-argument delta fragments into header-sized batches so
        // a fast JSON stream does not force one repaint per byte. Never execute.
        var toolDeltaCoalescer = LiveTextDeltaCoalescer()
        var pendingToolDelta: (
            toolIndex: UInt32,
            id: String?,
            name: String?,
            arguments: String
        )?

        for await event in events {
            try Task.checkCancellation()
            switch LiveSamplingStreamMapper.map(event) {
            case .emit(.output(let text)):
                if var buffer = pendingToolDelta {
                    if let flushed = toolDeltaCoalescer.flush() {
                        buffer.arguments += flushed
                    }
                    if !buffer.arguments.isEmpty {
                        await onEvent(.toolCallDelta(
                            toolIndex: buffer.toolIndex,
                            id: buffer.id,
                            name: buffer.name,
                            argumentsDelta: buffer.arguments
                        ))
                    }
                    pendingToolDelta = nil
                    toolDeltaCoalescer = LiveTextDeltaCoalescer()
                }
                if let batch = reasoningCoalescer.flush() {
                    await onEvent(.reasoning(batch))
                }
                if let batch = textCoalescer.push(text) {
                    await onEvent(.output(batch))
                }
            case .emit(.reasoning(let text)):
                if var buffer = pendingToolDelta {
                    if let flushed = toolDeltaCoalescer.flush() {
                        buffer.arguments += flushed
                    }
                    if !buffer.arguments.isEmpty {
                        await onEvent(.toolCallDelta(
                            toolIndex: buffer.toolIndex,
                            id: buffer.id,
                            name: buffer.name,
                            argumentsDelta: buffer.arguments
                        ))
                    }
                    pendingToolDelta = nil
                    toolDeltaCoalescer = LiveTextDeltaCoalescer()
                }
                if let batch = textCoalescer.flush() {
                    await onEvent(.output(batch))
                }
                if let batch = reasoningCoalescer.push(text) {
                    await onEvent(.reasoning(batch))
                }
            case .emit(.toolCallDelta(let toolIndex, let id, let name, let argumentsDelta)):
                if let batch = textCoalescer.flush() {
                    await onEvent(.output(batch))
                }
                if let batch = reasoningCoalescer.flush() {
                    await onEvent(.reasoning(batch))
                }
                var buffer = pendingToolDelta ?? (
                    toolIndex: toolIndex,
                    id: id,
                    name: name,
                    arguments: ""
                )
                if buffer.toolIndex != toolIndex {
                    if let flushed = toolDeltaCoalescer.flush() {
                        buffer.arguments += flushed
                    }
                    await onEvent(.toolCallDelta(
                        toolIndex: buffer.toolIndex,
                        id: buffer.id,
                        name: buffer.name,
                        argumentsDelta: buffer.arguments.isEmpty ? nil : buffer.arguments
                    ))
                    buffer = (toolIndex: toolIndex, id: id, name: name, arguments: "")
                    toolDeltaCoalescer = LiveTextDeltaCoalescer()
                }
                if let id { buffer.id = id }
                if let name, !name.isEmpty { buffer.name = name }
                if let argumentsDelta, !argumentsDelta.isEmpty {
                    if let batch = toolDeltaCoalescer.push(argumentsDelta) {
                        buffer.arguments += batch
                        await onEvent(.toolCallDelta(
                            toolIndex: buffer.toolIndex,
                            id: buffer.id,
                            name: buffer.name,
                            argumentsDelta: buffer.arguments
                        ))
                        buffer.arguments = ""
                    }
                } else if id != nil || name != nil {
                    // Name/id-only delta: surface the provisional header without
                    // waiting for argument bytes.
                    await onEvent(.toolCallDelta(
                        toolIndex: buffer.toolIndex,
                        id: buffer.id,
                        name: buffer.name,
                        argumentsDelta: nil
                    ))
                }
                pendingToolDelta = buffer
            case .emit(.toolCallArgumentsComplete(let toolIndex, let id, let name)):
                if let batch = textCoalescer.flush() {
                    await onEvent(.output(batch))
                }
                if let batch = reasoningCoalescer.flush() {
                    await onEvent(.reasoning(batch))
                }
                if var buffer = pendingToolDelta {
                    if let flushed = toolDeltaCoalescer.flush() {
                        buffer.arguments += flushed
                    }
                    if !buffer.arguments.isEmpty {
                        await onEvent(.toolCallDelta(
                            toolIndex: buffer.toolIndex,
                            id: buffer.id,
                            name: buffer.name,
                            argumentsDelta: buffer.arguments.isEmpty ? nil : buffer.arguments
                        ))
                    }
                    pendingToolDelta = nil
                    toolDeltaCoalescer = LiveTextDeltaCoalescer()
                }
                await onEvent(.toolCallArgumentsComplete(
                    toolIndex: toolIndex,
                    id: id,
                    name: name
                ))
            case .emit(let other):
                if let batch = textCoalescer.flush() {
                    await onEvent(.output(batch))
                }
                if let batch = reasoningCoalescer.flush() {
                    await onEvent(.reasoning(batch))
                }
                if var buffer = pendingToolDelta {
                    if let flushed = toolDeltaCoalescer.flush() {
                        buffer.arguments += flushed
                    }
                    if !buffer.arguments.isEmpty {
                        await onEvent(.toolCallDelta(
                            toolIndex: buffer.toolIndex,
                            id: buffer.id,
                            name: buffer.name,
                            argumentsDelta: buffer.arguments
                        ))
                    }
                    pendingToolDelta = nil
                    toolDeltaCoalescer = LiveTextDeltaCoalescer()
                }
                await onEvent(other)
            case .completed(let response):
                if let batch = textCoalescer.flush() {
                    await onEvent(.output(batch))
                }
                if let batch = reasoningCoalescer.flush() {
                    await onEvent(.reasoning(batch))
                }
                if var buffer = pendingToolDelta {
                    if let flushed = toolDeltaCoalescer.flush() {
                        buffer.arguments += flushed
                    }
                    if !buffer.arguments.isEmpty {
                        await onEvent(.toolCallDelta(
                            toolIndex: buffer.toolIndex,
                            id: buffer.id,
                            name: buffer.name,
                            argumentsDelta: buffer.arguments.isEmpty ? nil : buffer.arguments
                        ))
                    }
                }
                return response
            case .failed(let error):
                if let batch = textCoalescer.flush() {
                    await onEvent(.output(batch))
                }
                if let batch = reasoningCoalescer.flush() {
                    await onEvent(.reasoning(batch))
                }
                if var buffer = pendingToolDelta {
                    if let flushed = toolDeltaCoalescer.flush() {
                        buffer.arguments += flushed
                    }
                    if !buffer.arguments.isEmpty {
                        await onEvent(.toolCallDelta(
                            toolIndex: buffer.toolIndex,
                            id: buffer.id,
                            name: buffer.name,
                            argumentsDelta: buffer.arguments
                        ))
                    }
                }
                // Emit typed failure before throwing so the UI can show kind
                // (auth/rate-limit/…) rather than only `Turn failed: …`.
                await onEvent(.failed(error))
                throw CLIApplicationError.failed(error.message)
            case .none:
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
    public let shareRoute: LiveShareRouteDependencies
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
        shareRoute: LiveShareRouteDependencies = .production(),
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
        self.shareRoute = shareRoute
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
        shareRoute: .production(),
        makeLeaderClient: { configuration in
            try await LiveLeaderClientAcquisition.production.connectOrSpawn(configuration)
        }
    )
}

public struct OpenGrokLiveInteractiveInput: Sendable {
    public let events: AsyncThrowingStream<InputEvent, Error>
    private let closeOperation: @Sendable () async -> Void
    /// Suspend-for-child entry point (`suspend_for_child`,
    /// event_loop.rs:356-423). `nil` on inputs that cannot suspend, which is
    /// every construction that does not own a real reader and raw-mode lease.
    private let suspendControl: (@Sendable () async -> LiveInputSuspension?)?

    public init(
        events: AsyncThrowingStream<InputEvent, Error>,
        close: @escaping @Sendable () async -> Void,
        suspendControl: (@Sendable () async -> LiveInputSuspension?)? = nil
    ) {
        self.events = events
        self.closeOperation = close
        self.suspendControl = suspendControl
    }

    public func close() async {
        await closeOperation()
    }

    /// Park the terminal reader and release the raw-mode lease. `nil` when
    /// this input cannot suspend or the reader did not park within its
    /// bounded wait; the returned one-shot ticket's `end()` is the only way
    /// back to a reading input.
    public func beginSuspension() async -> LiveInputSuspension? {
        guard let suspendControl else { return nil }
        return await suspendControl()
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
        // DA2 owns stdin after raw mode and before EventStream
        // (da2.rs:16-19, app/mod.rs:1356-1361). Poll-bounded; no sleep.
        await LiveTerminalStartupProbes.probeDa2AndPushKittyKeyboard { data in
            try await inputTTY.write(data)
        }
        let input: any TerminalInput
        do {
            input = try PlatformTerminalInput()
        } catch {
            await lease.release()
            throw error
        }
        // Filter is armed. Write CSI > 0 q once; do not timed-read.
        await LiveTerminalStartupProbes.writeXtversionQueryIfAllowed { data in
            try await inputTTY.write(data)
        }

        var continuation: AsyncThrowingStream<InputEvent, Error>.Continuation!
        let events = AsyncThrowingStream<InputEvent, Error> { continuation = $0 }
        let emitter = LiveInteractiveInputEmitter(continuation: continuation)
        let resizeSource: any TerminalResizeSource = PlatformTerminalResizeMonitor(fd: 1)
        let resource = LiveInteractiveInputResource(
            input: input,
            resizeSource: resizeSource,
            lease: lease,
            rawModeTTY: inputTTY
        )
        let wrapClipboardPaste = LiveWrapClipboardPasteCoordinator { data in
            try await inputTTY.write(data)
        }
        let inputTask = Task {
            var pasteBuffer: String?
            do {
                while let event = try await input.readEvent() {
                    if pasteBuffer == nil,
                       let pasteEvents = await wrapClipboardPaste.handle(event)
                    {
                        for pasteEvent in pasteEvents {
                            emitter.yield(pasteEvent)
                        }
                        continue
                    }
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
            close: { await resource.close() },
            suspendControl: {
                guard await resource.beginSuspension() else { return nil }
                return LiveInputSuspension(end: { try await resource.endSuspension() })
            }
        )
    }

    /// Internal (not private) so the live byte chain — PosixTerminalInput
    /// decode into pager InputEvents — can be regression-tested end to end;
    /// synthetic `.mouse` injections in the parity tests never exercise it.
    static func translate(_ event: TerminalInputEvent) -> [InputEvent] {
        switch event {
        case .key(let key):
            return translate(key)
        case .control(let control):
            return [translate(control)]
        case .focusGained:
            return [.focusGained]
        case .focusLost:
            return [.focusLost]
        case .resize(let size):
            return [.resize(OpenGrokTerminalCore.TerminalSize(
                width: size.width,
                height: size.height
            ))]
        case .unknown(let data):
            // `TerminalInputDecoder` has no mouse handling of its own: it
            // preserves full SGR (`ESC [ < b ; x ; y M|m`) and X10
            // (`ESC [ M` + three coordinate bytes) reports as `.unknown`
            // Data. `MouseReportDecoder` recovers both shapes here without a
            // new module dependency. The driver still enables `?1006h` last so
            // terminals that understand SGR prefer that mode.
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
            case .enter: keyCode = .enter
            case .tab: keyCode = modifiers.contains(.shift) ? .backTab : .tab
            case .backspace: keyCode = .backspace
            case .escape: keyCode = .escape
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
        if modifiers.contains(.superKey) { translated.insert(.superKey) }
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
                    },
                    routeDependencies: dependencies.shareRoute
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
                    services: Self.liveACPServices(
                        dependencies: dependencies,
                        liveBoundaries: { sessionID in
                            exportBoundaries.boundary(for: sessionID)
                        },
                        registerExportBoundary: { sessionID, boundary in
                            exportBoundaries.register(sessionID: sessionID, boundary: boundary)
                        }
                    )
                )
            }
            if LiveServeComposition.handles(command) {
                return try await LiveServeComposition.session(
                    for: command,
                    context: context,
                    services: Self.liveACPServices(
                        dependencies: dependencies,
                        liveBoundaries: { sessionID in
                            exportBoundaries.boundary(for: sessionID)
                        },
                        registerExportBoundary: { sessionID, boundary in
                            exportBoundaries.register(sessionID: sessionID, boundary: boundary)
                        }
                    )
                )
            }
            if LiveACPComposition.handles(command) {
                return try await LiveACPComposition.session(
                    for: command,
                    context: context,
                    services: Self.liveACPServices(
                        dependencies: dependencies,
                        liveBoundaries: { sessionID in
                            exportBoundaries.boundary(for: sessionID)
                        },
                        registerExportBoundary: { sessionID, boundary in
                            exportBoundaries.register(sessionID: sessionID, boundary: boundary)
                        }
                    )
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
                let interactiveInput = options.mode == .interactive
                    && dependencies.terminal.isTTY()
                    ? try await dependencies.makeInteractiveInput()
                    : nil
                do {
                    return try await Self.makeLeaderLaunchSession(
                        options: options,
                        prompt: prompt,
                        workingDirectory: cwd,
                        lease: lease,
                        context: context,
                        terminal: dependencies.terminal,
                        interactiveInput: interactiveInput,
                        makeTerminalSink: dependencies.makeTerminalSink
                    )
                } catch {
                    await interactiveInput?.close()
                    await lease.close()
                    throw error
                }
            }
            // The interactive surface is created BEFORE the foundation so the
            // ask-user/plan-approval coordinators can be gated on what will
            // actually exist: stdout being a TTY says nothing about stdin, and
            // a coordinator without its presenter advertises a tool no one can
            // answer (wave 14 review finding). Cost: raw mode is entered a few
            // hundred milliseconds earlier, so a foundation error printed to
            // stderr renders staircased — error paths only, and the input is
            // closed on that throw below.
            let interactiveInput = options.mode == .interactive && dependencies.terminal.isTTY()
                ? try await dependencies.makeInteractiveInput()
                : nil
            let interactiveSink = interactiveInput != nil ? dependencies.makeTerminalSink() : nil
            let foundation: LiveSessionFoundation
            do {
                foundation = try await Self.makeSessionFoundation(
                    options: options,
                    context: context,
                    dependencies: dependencies,
                    interactiveSurfaceAvailable: interactiveInput != nil && interactiveSink != nil
                )
            } catch {
                await interactiveInput?.close()
                throw error
            }
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
                        toolPolicy: LiveAgentToolPolicy.resolveLaunchPolicy(
                            tools: options.agentOptions.tools,
                            disallowedTools: options.agentOptions.disallowedTools,
                            profile: agentProfile?.toolPolicy
                        ),
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
            // `/announcements` — the banner's keyboard control: `hide` is
            // the dismissal the banner advertises (`hide: /announcements
            // hide`), `show` clears the session's persisted hide keys so the
            // banner comes back (upstream `AnnouncementsCommand`,
            // `announcements.rs:12-63`; router arms at `router.rs:974-1005`).
            // Registered only when a live announcements surface exists — a
            // headless launch with no transport has no banner to control, so
            // the row would be dead. The gate deliberately diverges from
            // upstream's has-announcements visibility; the copy, arms, and
            // the divergence's cost live on `LiveAnnouncementsSlashCommand`.
            let announcementsCommands = LiveAnnouncementsSlashCommand.registrations(
                surfaceAvailable: stack.announcements != nil
            )
            // `/imagine` — registered only when this session's advertised
            // toolset actually carries `image_gen` (upstream's
            // `required_tools`, `imagine.rs:8`). The gate reads the same
            // list the model is offered (`toolExecutor.tools`), so the row
            // exists exactly when the injection it produces can be acted on.
            let imagineCommands = LiveImagineCommand.registrations(
                advertisedToolNames: Set(toolExecutor.tools.map(\.name))
            )
            // `/loop` — registered only when this session's advertised
            // toolset actually carries `scheduler_create` (upstream's
            // `required_tools`, loop_cmd.rs:12,107-109). Same gate shape as
            // `/imagine`: the row exists exactly when the injection it
            // produces can be acted on.
            let loopCommands = LiveLoopCommand.registrations(
                advertisedToolNames: Set(toolExecutor.tools.map(\.name))
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
                // One effective-config read seeds the screen-mode resolution
                // AND both halves of the mode snapshot below. Multiline
                // remains session-local, while vim and the two steering
                // settings start from `[ui]`.
                let uiConfiguration = LiveInteractiveControllerRenderer.resolveUIConfig(
                    workingDirectory: cwd,
                    environment: context.environment
                )
                let pagerMode = try Self.resolveInteractivePagerMode(
                    options: options,
                    terminal: dependencies.terminal,
                    configScreenMode: uiConfiguration.config.screenMode,
                    screenModeEnvOverride: LiveScreenModeRelaunch.takeScreenModeEnvOverride()
                )
                if let interactiveInput, let terminalSink = interactiveSink {
                    let initialInputModes = uiConfiguration.inputModes
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
                        // Routed through the runtime adapter, not the shell
                        // directly: the adapter knows whether the (lazily
                        // created) shell session exists yet and targets the
                        // session the runtime is actually on after `/new` or
                        // `/resume` — a direct shell call with the launch
                        // session id threw "session not found" on every
                        // pre-first-turn `/model` switch.
                        providerBoundarySync: { everUsedNonXAI in
                            try await runtime.synchronizeProviderBoundary(
                                everUsedNonXAI: everUsedNonXAI
                            )
                        },
                        permissionCoordinator: permissionCoordinator,
                        questionCoordinator: foundation.questionCoordinator,
                        planApprovalCoordinator: foundation.planApprovalCoordinator,
                        permissionMode: toolExecutor.sessionPermissionMode,
                        workflowRegistry: workflowRegistry,
                        workflowsEnabled: workflowsEnabled,
                        terminalProgram: context.environment["TERM_PROGRAM"],
                        uiConfiguration: uiConfiguration,
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
                        // `/fork` copies records through the SAME store the
                        // runtime adapter persists with — a rebuilt store
                        // pointed at the same files is how two writers
                        // appear.
                        conversationStore: foundation.conversationStore,
                        // The connection outcomes `/mcps` renders — the tool
                        // executor recorded them when it brought the session's
                        // configured servers online.
                        mcpServers: toolExecutor.mcpServerConnections,
                        openGrokHome: openGrokHome,
                        // The announcements surface: fetch → cache → banner plus
                        // the `/announcements hide` dismissal. `nil` only when
                        // the session has no live transport (headless launches),
                        // in which case the renderer closes the banner slot.
                        announcements: stack.announcements,
                        // The `/release-notes` changelog client, on the same
                        // transport the sampler/catalog/announcements use and
                        // gated on the same export boundary: a Codex
                        // (xAI-export-denied) session issues no `x.ai`
                        // changelog request (recorded divergence — upstream's
                        // changelog fetch is ungated; see PORT_STATUS.md
                        // Wave 18 B9).
                        changelog: ChangelogManager.fromEnvironment(
                            context.environment,
                            transport: foundation.samplingConfiguration.transport,
                            exportPolicy: foundation.samplingConfiguration
                                .provider.profile.xaiServices
                        ),
                        // The coding-data retention write client (B9-c2):
                        // same transport and frozen export policy as the
                        // changelog/announcements, same proxy-base
                        // resolution as announcements, plus the session's
                        // LIVE boundary so a mid-session switch to an
                        // xAI-export-denied provider closes the write
                        // without waiting for a rebuild.
                        codingDataRetention: LiveCodingDataRetentionClient(
                            transport: foundation.samplingConfiguration.transport,
                            exportPolicy: foundation.samplingConfiguration
                                .provider.profile.xaiServices,
                            proxyBaseURL: URL(string:
                                foundation.options.advanced.cliChatProxyBaseURL
                                    ?? context.environment["GROK_CLI_CHAT_PROXY_BASE_URL"]
                                    ?? CLI_CHAT_PROXY_BASE_URL_DEFAULT
                            ),
                            liveBoundary: sharedExportBoundary,
                            tokenHeader: GrokComConfig
                                .default(environment: context.environment)
                                .tokenHeader
                        ),
                        // The paint ceiling: `GROK_MIN_DRAW_MS` wins, then the
                        // `[ui.display_refresh]` auto-cadence policy fed by a
                        // one-shot display-refresh probe (macOS CoreGraphics;
                        // SSH/WSL/noninteractive/auto-off skip → nil Hz /
                        // upstream `probe_skip`), then the 16 ms default.
                        paintCadence: Self.resolveStartupPaintCadence(
                            environment: context.environment,
                            workingDirectory: cwd
                        ),
                        // The audited env, not ProcessInfo: `/login` and
                        // `/logout` resolve auth paths and env-override
                        // statuses against it (AGENTS.md §2, applied to env).
                        environment: context.environment,
                        toolExecutor: toolExecutor
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
                        // Local registration order is upstream's display
                        // order for this subset: feedback, announcements,
                        // loop, imagine (`slash/commands/mod.rs:121-135`).
                        localCommands: feedbackCommands + announcementsCommands
                            + loopCommands + imagineCommands,
                        localCommandHandler: { invocation in
                            switch invocation.name {
                            case "announcements":
                                // Dispatch, store mutation (hide persists the
                                // selected banner's key; show clears the
                                // session's keys) and the renderer refresh
                                // live on `LiveAnnouncementsSlashCommand` so
                                // tests reach the same arms. The controller
                                // re-renders off the returned notice, so the
                                // banner swaps, closes, or returns in the
                                // same frame.
                                return await LiveAnnouncementsSlashCommand.run(
                                    rawArgumentTail: OpenGrokPagerInteractiveController
                                        .rawArgumentTail(of: invocation),
                                    surface: stack.announcements,
                                    refreshBanner: {
                                        await renderer.refreshAnnouncementBanner()
                                    }
                                )
                            case "imagine":
                                // The argument is prose: the raw tail as
                                // typed (upstream's `args` slice), never the
                                // tokenizer's unquoted rejoin. Empty → the
                                // usage notice; otherwise `.submit` carries
                                // `imagineInstruction(prompt)` into the same
                                // enqueue path the skill commands use.
                                return LiveImagineCommand.outcome(
                                    rawArgumentTail: OpenGrokPagerInteractiveController
                                        .rawArgumentTail(of: invocation)
                                )
                            case "loop":
                                // `/loop` — empty args echo the usage
                                // message; otherwise the schedule instruction
                                // becomes the turn's prompt (the model calls
                                // `scheduler_create`) and the provisional
                                // preview seeds the tasks pane before the
                                // round-trip (`app/dispatch/prompt.rs:775-794`).
                                // The fire mode is the session's resolved
                                // `background_loops` — the same value the
                                // scheduler host consults at fire time, so
                                // the instruction describes the runtime the
                                // fire will actually get (upstream reads its
                                // seeded copy the same way, loop_cmd.rs:116-120).
                                switch LiveLoopCommand.dispatch(
                                    rawArgumentTail: OpenGrokPagerInteractiveController
                                        .rawArgumentTail(of: invocation),
                                    fireMode: foundation.schedulerBackgroundLoops
                                        ? .detached
                                        : .inSession
                                ) {
                                case .usage(let message):
                                    return .notice(message)
                                case .schedule(let instruction, let preview):
                                    await toolExecutor.schedulerHost?.insertProvisional(
                                        prompt: preview.prompt,
                                        humanSchedule: preview.humanSchedule
                                    )
                                    return .submit(instruction)
                                }
                            case "feedback":
                                let text = invocation.arguments.joined(separator: " ")
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !text.isEmpty else {
                                    return .notice("usage: /feedback <text>")
                                }
                                let outcome = try await foundation.feedback.submitText(text)
                                switch outcome {
                                case .persistedLocally:
                                    return .notice(
                                        "feedback saved locally; this session is not eligible for upload"
                                    )
                                case .persistedAndUploaded:
                                    return .notice("feedback uploaded")
                                case .persistedButUploadFailed:
                                    return .notice("feedback saved locally; upload failed")
                                }
                            default:
                                return nil
                            }
                        },
                        bashCommandHandler: { command in
                            try await LiveUserBashCommand.start(
                                command: command,
                                sessionID: sessionID,
                                workingDirectory: cwd,
                                toolExecutor: toolExecutor,
                                renderer: renderer
                            )
                        },
                        workflowsEnabled: workflowsEnabled,
                        mouseReportingToggleEnabled: uiConfiguration.mouseReportingToggleEnabled
                    )
                    // `[animation].fps` before first frame — must precede
                    // `run` so tick derivation never jumps mid-session
                    // (`setMotionFPS`, InteractiveController). Loaded once
                    // with wave_rows from `$OPENGROK_HOME/pager.toml`.
                    await controller.setMotionFPS(await renderer.animationFPS)
                    await controller.setInputModes(initialInputModes)
                    // Controller-originated `.modeChanged` events only refresh
                    // the renderer's copy. They do not call this sink, or
                    // `/multiline` and `/vim-mode` would bounce a second update
                    // back into the controller.
                    await renderer.setInputModesSink { [weak controller] modes in
                        await controller?.setInputModes(modes)
                    }
                    await renderer.setVoicePromptSink { [weak controller] text in
                        await controller?.replacePromptDraft(text)
                    }
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
                    // Status-bar background-task chip + motion. One weak
                    // renderer sink is shared across every lifecycle source
                    // that exists for this composition; absent sources are
                    // skipped honestly. Scheduler/workflow install reseeds
                    // currently-visible ids (no polling). Shell/monitor share
                    // the composition's single `.shell` path.
                    let activeBackgroundWorkSink =
                        await renderer.makeActiveBackgroundWorkSink()
                    await LiveActiveBackgroundWorkWiring.install(
                        sink: activeBackgroundWorkSink,
                        toolExecutor: toolExecutor,
                        workflowRegistry: workflowRegistry
                    )
                    // Pull the cached announcement banner into the renderer's
                    // projection so the first frame can show it. The composition
                    // already spawned the post-readiness refresh; this reads the
                    // cache (sync, local) and the persistent hide-key set (async,
                    // local), so it does not block on the network.
                    await renderer.refreshAnnouncementBanner()
                    // `/transcript`'s suspend host. The environment is the
                    // context's audited copy, passed explicitly — reading
                    // `ProcessInfo` inside the renderer would resolve `$PAGER`
                    // against process-global state (AGENTS.md §2's
                    // process-default trap, applied to env).
                    await renderer.setSuspendHost(LiveTUISuspendHost(
                        beginInputSuspension: { await interactiveInput.beginSuspension() },
                        environment: context.environment,
                        // Weak like the motion sink: the controller owns the
                        // renderer, and a cycle here would keep both alive
                        // past shutdown. Pause the ticker before tty
                        // teardown; re-arm only after restore — never via
                        // lying about `motionEnabled`.
                        suspendMotion: { [weak controller] in
                            await controller?.suspendMotionTicker()
                        },
                        resumeMotion: { [weak controller] in
                            await controller?.resumeMotionTicker()
                        }
                    ))
                    // Slash-command recency persists at
                    // `<opengrok home>/slash-mru.json`, upstream's grok_home
                    // location (`mru.rs:78-80`).
                    await controller.setSlashMru(PagerSlashMru(directory: openGrokHome))
                    // `/plan <description>`'s already-in-plan refusal
                    // (`dispatch/modes.rs:48-52`) reads the live plan tracker
                    // through the executor — the same tracker the
                    // `enter_plan_mode` tool arms — so the slash path and the
                    // tool path can never disagree about the session's mode.
                    await controller.setPlanModeStateProvider {
                        await toolExecutor.planModeActive()
                    }
                    // `/swarm`'s bare toggle resolves against the SAME
                    // tracker the tool trigger and the turn reminders read
                    // (upstream reads `ctx.pager_state.swarm_mode`,
                    // swarm.rs:45-48).
                    await controller.setSwarmModeStateProvider {
                        await toolExecutor.swarmMode.enabled
                    }
                    // The send-now cancel exemption: while an `agent_swarm`
                    // cohort holds the turn in an orchestration wait, an
                    // arriving prompt is promoted, never cancelled
                    // (prompt_queue.rs:222-233). Read straight off the live
                    // host's wait state — the same counter `runSwarm`
                    // raises around its scheduler.
                    if let host = toolExecutor.subagentHost {
                        await controller.setOrchestrationWaitStateProvider {
                            host.foregroundWait.orchestrationDepth > 0
                        }
                    }
                    // Persisted swarm preference seeds the session the way
                    // upstream's `session_swarm_mode` spawn flag does
                    // (spawn.rs:773-775): a restored session keeps only the
                    // manual trigger. This is `ui.swarm_mode`'s reader —
                    // the key parsed with no consumer until this slice.
                    if uiConfiguration.config.swarmMode == true {
                        await toolExecutor.swarmMode.enter(.manual)
                    }
                    // The mid-turn interjection seam: the subagent
                    // collaboration quartet delivers into the RUNNING turn's
                    // buffer (drained between sampler rounds by
                    // `LiveShellSamplingDriver`), and turn-end stranded
                    // entries flow back for the fallback-prompt conversion.
                    // The single-process port of `x.ai/interject` →
                    // `SessionCommand::Interject` (run_loop.rs:1947-1990).
                    // `/btw` no longer produces here — it is a real side
                    // question (`.sideQuestion` → `startSideQuestion`).
                    let interjections = stack.interjections
                    await controller.setInterjectionSeam(OpenGrokPagerInterjectionSeam(
                        deliver: { text in await interjections.interject(text) },
                        collectStranded: { await interjections.collectStranded() }
                    ))
                    // The scheduler fire seam: a due task's in-session fire
                    // enqueues a Cron prompt through the controller's queue
                    // and wakes the idle loop to drain it — the port of
                    // `x.ai/scheduled_task_inject_prompt` →
                    // `enqueue_cron_prompt` → `maybe_drain_queue`
                    // (acp_handler/background.rs:439-509). Installed here,
                    // after the controller exists, so a task that came due
                    // during startup fires now instead of being lost
                    // (upstream's wiring-grace shape, actor.rs:224-253).
                    // NEVER the PagerMotion ticker or the interjection seam:
                    // the ticker parks on a still screen and the seam only
                    // exists mid-turn — both drop fires exactly when the
                    // session is idle.
                    if let schedulerHost = toolExecutor.schedulerHost {
                        // The Detached spawn seam, installed BEFORE the fire
                        // sink: the sink install delivers fires held over
                        // from startup, and a due Detached task must already
                        // see its spawner then (the wiring-grace window,
                        // actor.rs:224-253). The seam drives the SAME
                        // subagent host `spawn_subagent` dispatches through,
                        // so a loop iteration is a real child in every
                        // observable way — `/tasks`, `get_task_output`,
                        // `kill_task`, `resume_from`.
                        if let subagentHost = toolExecutor.subagentHost {
                            await schedulerHost.setLoopSpawner(LiveSchedulerLoopSpawner(
                                probePrevious: { [weak subagentHost] subagentID in
                                    // The actor's `SubagentEvent::Query` read
                                    // (actor.rs:522-580) against the real
                                    // coordinator. A torn-down host is
                                    // upstream's closed channel: unknown,
                                    // so the fire skips.
                                    guard let subagentHost else { return .unknown }
                                    let coordinator = subagentHost.coordinator
                                    let active = await coordinator.listActive(
                                        parentSessionID: subagentHost.context.sessionID
                                    )
                                    if active.contains(where: { $0.request.id == subagentID }) {
                                        return .running
                                    }
                                    guard let completed = await coordinator.listCompleted()
                                        .first(where: { $0.request.id == subagentID }),
                                        completed.state == "completed",
                                        let result = completed.result
                                    else {
                                        // Evicted, failed, or cancelled: the
                                        // anchor is unusable and the next
                                        // iteration starts fresh
                                        // (actor.rs:620-632).
                                        return .gone
                                    }
                                    // The RAW completion output — the
                                    // 600-char restart summary's source
                                    // (actor.rs:629-631), never the
                                    // meta-footered task_output rendering.
                                    return .completed(output: result.output)
                                },
                                spawn: { [weak subagentHost, weak schedulerHost] request in
                                    guard let subagentHost else { return false }
                                    var arguments: [String: JSONValue] = [
                                        "prompt": .string(request.framedPrompt),
                                        "description": .string(request.description),
                                        // `subagent_type: "general-purpose"`,
                                        // `run_in_background: true` — the
                                        // actor's request verbatim
                                        // (actor.rs:658-680).
                                        "subagent_type": .string("general-purpose"),
                                        "background": .bool(true),
                                        "task_id": .string(request.subagentID),
                                    ]
                                    if let resumeFrom = request.resumeFrom {
                                        arguments["resume_from"] = .string(resumeFrom)
                                    }
                                    // No PreToolUse gate here on purpose: a
                                    // fire is not a tool call — upstream's
                                    // actor sends `SubagentEvent::Spawn`
                                    // straight to the coordinator
                                    // (actor.rs:682-688). The spawned
                                    // child's OWN tool calls pass through
                                    // the child executor's full permission
                                    // pipeline (LiveSubagentHost.runChild),
                                    // built from this session's security
                                    // context — that is the authorization
                                    // surface, same as a Cron turn's.
                                    switch await subagentHost.spawn(
                                        args: .object(arguments),
                                        toolCallID: "scheduler-fire-\(request.subagentID)"
                                    ) {
                                    case .success:
                                        // The spawn-result watcher
                                        // (actor.rs:707-730): a failed
                                        // iteration clears the chain anchor
                                        // so the next fire starts fresh
                                        // instead of resuming a broken chain.
                                        let coordinator = subagentHost.coordinator
                                        let spawnedID = request.subagentID
                                        Task { [weak schedulerHost] in
                                            guard let result = try? await coordinator
                                                .awaitResult(spawnedID) else { return }
                                            guard result.error != nil else { return }
                                            await schedulerHost?.clearChainAnchor(
                                                spawnedSubagentID: spawnedID
                                            )
                                        }
                                        return true
                                    case .failure:
                                        return false
                                    }
                                }
                            ))
                        }
                        await schedulerHost.setFireSink { [weak controller] fire in
                            guard let controller else { return }
                            switch await controller.enqueueCronPrompt(
                                prompt: fire.prompt,
                                taskID: fire.taskID,
                                humanSchedule: fire.humanSchedule
                            ) {
                            case .enqueued,
                                 .skippedTaskAlreadyQueued,
                                 .skippedTaskAlreadyRunning:
                                // The skips are upstream's de-dup guards
                                // (background.rs:483-496): a re-fire of a
                                // queued or still-running task must not pile
                                // up. Both are by-design no-ops here.
                                break
                            }
                        }
                    }
                    // The monitor event seam: mid-turn events ride the
                    // interjection buffer (the round-boundary drain,
                    // upstream's `MonitorEventBuffer`, monitor/types.rs:139-155);
                    // an idle session gets a notification prompt turn
                    // through the controller's queue (upstream's
                    // `SessionCommand::InjectNotification`,
                    // notification_bridge.rs:776-789).
                    if let monitorHost = toolExecutor.monitorHost {
                        let monitorInterjections = stack.interjections
                        await monitorHost.setEventSink { [weak controller] event in
                            if await monitorInterjections.interject(event.eventText) {
                                return
                            }
                            guard let controller else { return }
                            await controller.enqueueMonitorPrompt(
                                taskID: event.taskID,
                                eventText: event.eventText
                            )
                        }
                        // Wave 20 S5 — TaskCompleted auto-wake: exactly-once
                        // completion messages for monitors (via tick) and
                        // bash background tasks (via the 1s poll). Same
                        // interjection / idle-prompt delivery as monitor
                        // events (task_completion.rs:164-195).
                        let completionWake = LiveTaskCompletionWake(
                            ownerSessionID: foundation.sessionID
                        )
                        await monitorHost.setCompletionWake(completionWake)
                        await completionWake.setWakeSink { [weak controller] message in
                            if await monitorInterjections.interject(message) {
                                return
                            }
                            guard let controller else { return }
                            await controller.enqueueMonitorPrompt(
                                taskID: "task-completed",
                                eventText: message
                            )
                        }
                        if let process = await toolExecutor.processExecution(
                            sessionID: foundation.sessionID,
                            workingDirectory: cwd
                        ) {
                            await completionWake.startWatching(process: process)
                        }
                    }
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
                        case "swarm":
                            // Upstream `SwarmCommand::suggest_args`
                            // (swarm.rs:25-40): the on/off rows filtered by
                            // the trimmed prefix; the task arm is free prose
                            // and gets no rows.
                            let prefix = query.trimmingCharacters(in: .whitespacesAndNewlines)
                            return [
                                ("on", "Enable swarm mode persistently"),
                                ("off", "Disable swarm mode persistently"),
                            ]
                            .filter { $0.0.hasPrefix(prefix) }
                            .map { value, description in
                                OpenGrokPagerCommandSuggestion(
                                    name: value,
                                    summary: description,
                                    insertText: "/swarm \(value)"
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
                    let fileSearchMatcher = FuzzyMatcher()
                    let fileSearchRoot = suggestionCWD
                    await controller.setFileSearchSuggestions { query, isDir, hidden in
                        let walkerEntries = FuzzyFileTreeWalker.walk(
                            root: fileSearchRoot,
                            hidden: hidden,
                            respectGitignore: true
                        )
                        let filtered = walkerEntries.filter { entry in
                            if isDir && !entry.isDir { return false }
                            return true
                        }
                        if query.isEmpty {
                            return filtered.prefix(20).map { entry in
                                OpenGrokPagerCommandSuggestion(
                                    name: "@\(entry.relativePath)",
                                    summary: entry.isDir ? "dir" : "",
                                    isAvailable: true,
                                    insertText: entry.relativePath
                                )
                            }
                        }
                        var matched: [(path: String, score: UInt32, isDir: Bool)] = []
                        for entry in filtered {
                            if let res = fileSearchMatcher.match(pattern: query, candidate: entry.relativePath, isDir: entry.isDir) {
                                matched.append((entry.relativePath, res.score, entry.isDir))
                            }
                        }
                        matched.sort { lhs, rhs in
                            if lhs.score != rhs.score { return lhs.score > rhs.score }
                            return lhs.path < rhs.path
                        }
                        return matched.prefix(20).map { item in
                            OpenGrokPagerCommandSuggestion(
                                name: "@\(item.path)",
                                summary: item.isDir ? "dir" : "",
                                isAvailable: true,
                                insertText: item.path
                            )
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
                            // B2-S2: an accepted /minimal · /fullscreen switch
                            // execs HERE — after the controller loop ended and
                            // its teardown restored the terminal, upstream's
                            // quit → restore → exec order (event loop drains,
                            // then `exec_screen_mode_relaunch`). The session
                            // stack is shut down first so stores flush; exec
                            // then replaces the process image, which is why
                            // this must be the last thing the run does. On
                            // exec failure the pasteable resume hint is the
                            // fallback (`screen_mode_relaunch.rs:206-214`).
                            if let relaunch = await renderer.takePendingScreenModeRelaunch() {
                                await LiveActiveBackgroundWorkWiring.clear(
                                    toolExecutor: toolExecutor,
                                    workflowRegistry: workflowRegistry
                                )
                                await controller.shutdown()
                                await interactiveInput.close()
                                stack.sessionBusObserver?.cancel()
                                await foundation.sessionBus.stop()
                                _ = await shell.shutdown(timeout: ShellDuration(timeInterval: 1))
                                await codeMode?.shutdown()
                                await toolExecutor.shutdown()
                                exportBoundaries.remove(sessionID: sessionID)
                                let failure = LiveScreenModeRelaunch.exec(
                                    sessionID: relaunch.sessionID,
                                    wantMinimal: relaunch.minimal
                                )
                                FileHandle.standardError.write(Data((
                                    "Could not reopen the session automatically (\(failure)).\n"
                                    + "Run: \(LiveScreenModeRelaunch.resumeHint(sessionID: relaunch.sessionID, wantMinimal: relaunch.minimal))\n"
                                ).utf8))
                            }
                        },
                        shutdown: {
                            task.cancel()
                            // Retire host sinks before restore so a late
                            // upsert cannot re-arm the chip after the
                            // terminal is torn down. Renderer cache + final
                            // motion `.none` land inside `restoreTerminal`.
                            await LiveActiveBackgroundWorkWiring.clear(
                                toolExecutor: toolExecutor,
                                workflowRegistry: workflowRegistry
                            )
                            await controller.shutdown()
                            await interactiveInput.close()
                            stack.sessionBusObserver?.cancel()
                            await foundation.sessionBus.stop()
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
                        stack.sessionBusObserver?.cancel()
                        await foundation.sessionBus.stop()
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
                    output: LivePagerOutput(
                        streams: context.streams,
                        format: options.outputFormat,
                        includePartialMessages: options.includePartialMessages,
                        sessionID: sessionID,
                        model: samplingConfiguration.model,
                        workingDirectory: cwd.path,
                        tools: toolExecutor.tools.map(\.name),
                        slashCommands: OpenGrokPagerInteractiveController.builtinCommandNames.sorted(),
                        skills: foundation.skillCatalog.map(\.commandName),
                        permissionMode: options.common.permissions.mode?.rawValue,
                        apiKeySource: samplingConfiguration.provider == .codex ? "oauth" : "user"
                    )
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
                        stack.sessionBusObserver?.cancel()
                        await foundation.sessionBus.stop()
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
        terminal: OpenGrokLiveTerminal,
        interactiveInput: OpenGrokLiveInteractiveInput?,
        makeTerminalSink: @escaping @Sendable () -> (any PagerTerminalSink)?
    ) async throws -> CLIApplicationSession {
        let runtime = LiveLeaderPagerRuntimeAdapter(
            client: lease.client,
            workingDirectory: workingDirectory
        )

        if options.mode == .interactive {
            let uiConfiguration = LiveInteractiveControllerRenderer.resolveUIConfig(
                workingDirectory: workingDirectory,
                environment: context.environment
            )
            let pagerMode = try Self.resolveInteractivePagerMode(
                options: options,
                terminal: terminal,
                // The leader launch reads the same effective `[ui]` document
                // the local composition does — one screen-mode rule, both
                // launch paths.
                configScreenMode: uiConfiguration.config.screenMode,
                screenModeEnvOverride: LiveScreenModeRelaunch.takeScreenModeEnvOverride()
            )
            if let interactiveInput, let terminalSink = makeTerminalSink() {
                let baseRequest = OpenGrokPagerRequest(
                    prompt: prompt,
                    mode: pagerMode,
                    metadata: ["mode": options.mode.rawValue]
                )
                let initialSession: (any OpenGrokPagerSessionAdapter)?
                if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    initialSession = nil
                } else {
                    initialSession = try await runtime.makeSession(for: baseRequest)
                }
                let request = OpenGrokPagerRequest(
                    prompt: prompt,
                    mode: pagerMode,
                    sessionID: initialSession?.sessionID,
                    metadata: baseRequest.metadata
                )
                let openGrokHome = Self.resolveOpenGrokHome(environment: context.environment)
                let renderer = LiveInteractiveControllerRenderer(
                    mode: pagerMode,
                    terminal: terminal,
                    sink: terminalSink,
                    workingDirectory: workingDirectory.path,
                    modelName: "leader",
                    terminalProgram: context.environment["TERM_PROGRAM"],
                    uiConfiguration: uiConfiguration,
                    sessionID: initialSession?.sessionID ?? "",
                    openGrokHome: openGrokHome,
                    environment: context.environment
                )
                let controller = OpenGrokPagerInteractiveController(
                    input: interactiveInput.events,
                    runtime: runtime,
                    renderer: renderer,
                    output: SilentLiveInteractiveOutput(),
                    mouseReportingToggleEnabled: uiConfiguration.mouseReportingToggleEnabled
                )
                // Leader composition: same one-shot `[animation].fps` wire as
                // the local fullScreen/inline path (before `run`).
                await controller.setMotionFPS(await renderer.animationFPS)
                await controller.setInputModes(uiConfiguration.inputModes)
                await renderer.setInputModesSink { [weak controller] modes in
                    await controller?.setInputModes(modes)
                }
                await renderer.setMotionStateSink { [weak controller] state in
                    await controller?.setMotionState(state)
                }
                await renderer.setSuspendHost(LiveTUISuspendHost(
                    beginInputSuspension: { await interactiveInput.beginSuspension() },
                    environment: context.environment,
                    suspendMotion: { [weak controller] in
                        await controller?.suspendMotionTicker()
                    },
                    resumeMotion: { [weak controller] in
                        await controller?.resumeMotionTicker()
                    }
                ))
                await controller.setSlashMru(PagerSlashMru(directory: openGrokHome))

                let rosterEvents = try await runtime.rosterEvents()
                let rosterTask = Task {
                    do {
                        for try await event in rosterEvents {
                            guard !Task.isCancelled else { return }
                            await renderer.applyLeaderRosterEvent(event)
                        }
                    } catch is CancellationError {
                    } catch {
                        await renderer.reportLeaderRosterFailure(String(describing: error))
                    }
                }
                let task = Task {
                    do {
                        let result: OpenGrokPagerInteractiveResult
                        if let initialSession {
                            result = try await controller.run(
                                initialSession: initialSession,
                                request: request
                            )
                        } else {
                            result = try await controller.run(request)
                        }
                        rosterTask.cancel()
                        await runtime.stopRosterEvents()
                        await rosterTask.value
                        await interactiveInput.close()
                        return result
                    } catch {
                        rosterTask.cancel()
                        await runtime.stopRosterEvents()
                        await rosterTask.value
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
                        rosterTask.cancel()
                        await runtime.stopRosterEvents()
                        await rosterTask.value
                        await interactiveInput.close()
                        await lease.close()
                    }
                )
            }

            await interactiveInput?.close()
            guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CLIApplicationError.failed(
                    "interactive leader mode requires terminal input or a prompt"
                )
            }
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
            output: LivePagerOutput(
                streams: context.streams,
                format: options.outputFormat,
                includePartialMessages: options.includePartialMessages,
                sessionID: options.sessionID,
                model: options.common.model,
                workingDirectory: workingDirectory.path,
                permissionMode: options.common.permissions.mode?.rawValue
            )
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
    /// - `--no-auto-update`: honored by the launch update composition.
    /// - `--no-subagents`: honored as the spawn-surface kill switch in the
    ///   subagent host, so it is a real control, not an ignored flag.
    /// - Everything under `common.permissions`, which the permission and
    ///   sandbox layer consumes.
    /// `--max-turns` is honored by `LiveShellSamplingDriver.runTurn` at turn-
    /// driver construction — not refused here.
    /// `--reasoning-effort` left this list when `resolveSamplingConfiguration`
    /// started validating and applying it to the initial session.

    private static func unhonoredLaunchFlag(_ options: CLIExecutionOptions) -> String? {
        // `--tools` / `--disallowed-tools` are honored by
        // `LiveAgentToolPolicy.resolveLaunchPolicy` at tool-executor
        // construction — not refused here.
        if options.agentOptions.agent != nil { return "--agent" }
        if options.agentOptions.agentsJSON != nil { return "--agents" }
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
        if options.chat && options.common.leader {
            throw CLIApplicationError.failed(
                "gateway chat mode (--chat) cannot run with leader mode; "
                    + "pass --no-leader or disable [cli] use_leader in config"
            )
        }
        if options.chat && options.forkSession {
            throw CLIApplicationError.failed("--fork-session is not supported with --chat")
        }
        if options.chat && options.restoreCode {
            throw CLIApplicationError.failed("--restore-code is not supported with --chat")
        }
        if options.localWorkspace != nil
            || options.localWorkspaceAttach != nil
            || options.localWorkspaceCWD != nil
        {
            throw CLIApplicationError.unsupported(
                route: "local-workspace gateway integration, which is unavailable in this build"
            )
        }
        if options.chat {
            throw CLIApplicationError.unsupported(
                route: "--chat gateway frontend, which is unavailable in this build"
            )
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

    /// Parse a `[ui] screen_mode` value with upstream's exact grammar
    /// (`parse_screen_mode`, `app/screen_mode_relaunch.rs:316-328` at pin
    /// 650c1db7): trimmed, case-insensitive `minimal` → minimal;
    /// `fullscreen` / `full` → fullscreen; empty or ANYTHING ELSE → `nil`,
    /// and normal resolution continues. Inline is deliberately not a valid
    /// value — env/config can never force Inline (upstream rejects
    /// `inline`/`auto`/`default`, pinned by its `parse_screen_mode_values`
    /// test at `:733-771`).
    static func parseConfiguredScreenMode(_ value: String?) -> OpenGrokPagerMode? {
        guard let raw = value?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return nil
        }
        if raw.caseInsensitiveCompare("minimal") == .orderedSame {
            return .minimal
        }
        if raw.caseInsensitiveCompare("fullscreen") == .orderedSame
            || raw.caseInsensitiveCompare("full") == .orderedSame {
            return .fullScreen
        }
        return nil
    }

    // Internal (not private) so the resolution matrix is pinnable by tests
    // without a full composition launch — the flag/config/TTY interplay is
    // exactly the class of table upstream pins in `parse_screen_mode_values`
    // and its resolution tests (`screen_mode_relaunch.rs:733-826`).
    static func resolveInteractivePagerMode(
        options: CLIExecutionOptions,
        terminal: OpenGrokLiveTerminal,
        configScreenMode: String? = nil,
        screenModeEnvOverride: String? = nil
    ) throws -> OpenGrokPagerMode {
        // B2-S2: the consume-once GROK_SCREEN_MODE override, set ONLY by the
        // `/minimal`//`/fullscreen` re-exec. It WINS over CLI flags and
        // config (`take_screen_mode_env_override`,
        // `screen_mode_relaunch.rs:337-341`): a preserved `--no-alt-screen`
        // or a config `screen_mode = "minimal"` must not keep a
        // `/fullscreen` relaunch out of fullscreen. Same grammar as the
        // config key; off a TTY it degrades to inline like the S1 arm — a
        // relaunch always has a TTY in practice, and the degrade beats
        // throwing from an env var no user typed.
        if let forced = parseConfiguredScreenMode(screenModeEnvOverride) {
            return terminal.isTTY() ? forced : .inline
        }
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
        // `[ui] screen_mode` — B2-S1, the key's FIRST reader (it was a
        // registered settings row writing a dead key). CLI flags beat config,
        // upstream's resolution order (`app/mod.rs:790-855`: env override →
        // CLI → `[ui] screen_mode` → legacy pager.toml → auto-minimal →
        // alt-screen policy; the env override lands with S2's relaunch, which
        // is the only thing that sets it, and the two legacy/auto inputs have
        // no port ground — recorded). A configured mode degrades to inline
        // off a TTY exactly like the flags' arms above; it never THROWS like
        // `--fullscreen`, because ambient config must not break piped runs
        // the way an explicit flag's contradiction should.
        if let configured = parseConfiguredScreenMode(configScreenMode) {
            return terminal.isTTY() ? configured : .inline
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
        try liveResolveWorkingDirectory(path)
    }

    private static func resolveURL(_ path: String, relativeTo cwd: String) -> URL {
        liveResolveURL(path, relativeTo: cwd)
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
        /// The `ask_user_question` surface. Unlike the permission coordinator
        /// (constructed unconditionally, gating on `hasPresenter`), this one
        /// exists only for interactive TTY launches: its absence is what keeps
        /// the tool off the advertised list everywhere no one could answer —
        /// upstream's `with_ask_user_question_enabled(false)` strip
        /// (`xai-grok-agent/src/builder.rs:819-825`), driven by composition
        /// shape instead of a flag.
        let questionCoordinator: PagerQuestionCoordinator?
        /// The `exit_plan_mode` plan-approval surface, gated exactly like the
        /// question coordinator: interactive TTY launches only. Its absence
        /// leaves the pipeline's dedicated-view slot empty, which keeps exit
        /// approval on the generic permission sheet — never an auto-approve.
        let planApprovalCoordinator: PagerPlanApprovalCoordinator?
        let telemetryBootstrapContext: LiveTelemetryBootstrapContext
        let toolExecutor: LiveToolExecutor
        let sessionBus: LiveSessionBus
        /// The subagent stack for this root session: one coordinator plus the
        /// child runner. `nil` when gated off (`--no-subagents` or an empty
        /// roster); the tool executor holds the same reference.
        let subagentHost: LiveSubagentHost?
        let discoveredSkills: [SkillInfo]
        let skillCatalog: [LiveSkills.SkillCommand]
        let feedback: LiveFeedbackComposition
        /// The session's resolved `[scheduler] background_loops` — the value
        /// the scheduler host consults at fire time, re-read here by `/loop`
        /// for its instruction mode (upstream's
        /// `scheduler_background_loops_seed`, app/event_loop.rs:1333-1338).
        let schedulerBackgroundLoops: Bool
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
        /// The mid-turn interjection seam: the subagent collaboration
        /// quartet produces into it, the turn loop drains it between sampler
        /// rounds. (`/btw` left this seam when it became a real side
        /// question — see `startSideQuestion`.)
        let interjections: LiveSessionInterjections
        let sessionBusObserver: Task<Void, Never>?
        /// Retained only so reachability tests can await the post-readiness
        /// launch update check; production callers ignore it.
        let launchAutoUpdateTask: Task<Void, Never>?
        /// The announcements surface for this session: fetch → cache → banner
        /// plus the hide dismissal. `nil` only in compositions that opt out of
        /// the live announcements feed (tests, headless launches without a
        /// transport); the renderer treats `nil` as "no banner slot."
        let announcements: LiveAnnouncementsComposition?
    }

    private actor LiveACPBusPresenceRegistry {
        private let bus: LiveSessionBus
        private let rootSessionID: String
        private let workingDirectory: URL
        private let model: String
        private var openSessions: Set<String> = []

        init(
            bus: LiveSessionBus,
            rootSessionID: String,
            workingDirectory: URL,
            model: String
        ) {
            self.bus = bus
            self.rootSessionID = rootSessionID
            self.workingDirectory = workingDirectory
            self.model = model
        }

        func opened(_ wireSessionID: String) async {
            guard await bus.busEnabled else { return }
            let wasEmpty = openSessions.isEmpty
            openSessions.insert(wireSessionID)
            guard wasEmpty else { return }
            do {
                try await bus.registerRootSession(
                    sessionID: rootSessionID,
                    cwd: workingDirectory,
                    model: model,
                    title: nil
                )
            } catch {
                openSessions.remove(wireSessionID)
                await bus.disable()
            }
        }

        func closed(_ wireSessionID: String) async {
            openSessions.remove(wireSessionID)
            guard openSessions.isEmpty else { return }
            await bus.unregisterRootSession(rootSessionID)
        }
    }

    static func makeSessionFoundation(
        options: CLIExecutionOptions,
        context: CLIApplicationContext,
        dependencies: OpenGrokLiveCompositionDependencies,
        /// Whether the interactive controller renderer — the only presenter
        /// for question and plan-approval sheets — will actually be
        /// constructed. The caller derives it from the real input and sink,
        /// not from stdout TTY-ness; a `false` here keeps `ask_user_question`
        /// off the advertised list and plan approval on the generic sheet.
        interactiveSurfaceAvailable: Bool = false
    ) async throws -> LiveSessionFoundation {
        let sourceCwd = try resolveWorkingDirectory(options.common.cwd)
        let openGrokHome = resolveOpenGrokHome(environment: context.environment)
        let autoGCPolicy = WorktreeAutoGCPolicy(
            enabled: GrokEnvGates.worktreeAutoGc(environment: context.environment) ?? true,
            maxAge: GrokEnvGates.worktreeAutoGcMaxAge(environment: context.environment)
                ?? WorktreeAutoGCPolicy.defaultMaxAge,
            dryRun: GrokEnvGates.worktreeAutoGcDryRun(environment: context.environment) ?? false,
            rebuildRegistry: GrokEnvGates.worktreeAutoGcRebuild(environment: context.environment) ?? false
        )
        _ = try? WorktreeAutoGC.runIfDue(
            registry: WorktreeRegistry(openGrokHome: openGrokHome),
            policy: autoGCPolicy,
            protectedPaths: [sourceCwd]
        )
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
                .union(["feedback", "announcements"])
        )
        let conversationStore = LiveConversationStore(openGrokHome: openGrokHome)
        var conversationRecord = try await resolveConversationRecord(
            options: options,
            lookupWorkingDirectory: sourceCwd,
            workingDirectory: cwd,
            openGrokHome: openGrokHome,
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
        let (resolvedSamplingConfiguration, credential) = try await resolveSamplingConfiguration(
            options: options,
            profileModel: agentProfile?.model,
            conversationRecord: conversationRecord,
            environment: context.environment,
            workingDirectory: cwd,
            openGrokHome: openGrokHome,
            sessionID: sessionID
        )
        let samplingConfiguration = resolvedSamplingConfiguration.withCodexPermissions(
            LiveToolExecutor.codexPermissions(
                provider: resolvedSamplingConfiguration.provider,
                sandbox: sandboxDecision,
                workingDirectory: cwd,
                environment: context.environment,
                alwaysApprove: securityContext.permissions.alwaysApprove
                    && securityContext.permissions.yoloPinReason == nil,
                autoReviewEnabled: securityContext.permissions.defaultMode == .auto
            )
        )
        let telemetryBootstrapContext = LiveTelemetryBootstrapContext(
            zeroDataRetention: credential.telemetryContext.zeroDataRetention,
            userID: credential.telemetryContext.userID,
            teamID: credential.telemetryContext.teamID
        )
        let historySamplingConfiguration = OpenGrokSamplingTypes.SamplingConfig(
            baseURL: samplingConfiguration.baseURL,
            model: samplingConfiguration.model,
            maxCompletionTokens: samplingConfiguration.tuning.maxCompletionTokens,
            temperature: samplingConfiguration.tuning.temperature,
            topP: samplingConfiguration.tuning.topP,
            apiBackend: samplingConfiguration.apiBackend,
            provider: samplingConfiguration.provider,
            extraHeaders: samplingConfiguration.extraHeaders
                .sorted { $0.key < $1.key }
                .map { ($0.key, $0.value) },
            contextWindow: samplingConfiguration.tuning.contextWindow ?? 0,
            reasoningEffort: samplingConfiguration.tuning.reasoningEffort
        )
        let launchHistory = LiveConversationHistory(
            record: conversationRecord,
            store: conversationStore,
            samplingConfig: historySamplingConfiguration
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
        let imageToolContext = LiveImageToolContext(
            availability: LiveImageToolComposition.resolveAvailability(
                workingDirectory: cwd,
                openGrokHome: openGrokHome,
                environment: context.environment,
                samplingProvider: samplingConfiguration.provider,
                samplingAPIKey: samplingConfiguration.apiKey,
                samplingBaseURL: samplingConfiguration.baseURL
            ),
            transport: dependencies.makeImageTransport()
        )
        let videoToolContext = LiveVideoToolContext(
            availability: LiveVideoToolComposition.resolveAvailability(
                workingDirectory: cwd,
                openGrokHome: openGrokHome,
                environment: context.environment,
                samplingProvider: samplingConfiguration.provider,
                samplingAPIKey: samplingConfiguration.apiKey,
                samplingBaseURL: samplingConfiguration.baseURL
            ),
            transport: dependencies.makeImageTransport()
        )
        let webToolContext = LiveWebToolContext(
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
        )
        let subagentHost = Self.makeSubagentHost(
            options: options,
            cwd: cwd,
            sessionID: sessionID,
            parentCacheAffinityID: conversationRecord.cacheAffinityID ?? sessionID,
            openGrokHome: openGrokHome,
            agentProfile: agentProfile,
            samplingConfiguration: samplingConfiguration,
            sampler: sampler,
            conversationStore: conversationStore,
            processBackend: processBackend,
            securityContext: securityContext,
            sandboxDecision: sandboxDecision,
            fileAccessPolicy: fileAccessPolicy,
            telemetryBootstrapContext: telemetryBootstrapContext,
            imageToolContext: imageToolContext,
            webToolContext: webToolContext,
            environment: context.environment,
            makeSampler: dependencies.makeSampler
        )
        if let subagentHost {
            await subagentHost.installParentUsageHistory(launchHistory)
        }
        // `ask_user_question` needs a human at a terminal. The caller passes
        // `interactiveSurfaceAvailable` derived from the constructed input and
        // sink, so the coordinator — and with it the advertised tool — exists
        // precisely when the pager renderer (the only presenter) will be too.
        // Headless (`-p`), non-TTY, and ACP launches get `nil`, which the
        // executor treats as "do not advertise", the same absence-means-
        // absence shape `spawn_subagent` uses. Upstream's equivalent gate
        // strips the tool from the config when disabled (`builder.rs:819-825`).
        let questionCoordinator: PagerQuestionCoordinator? =
            interactiveSurfaceAvailable ? PagerQuestionCoordinator() : nil
        // Same gate for the plan-approval view: it exists exactly when the
        // pager renderer (its only presenter) will be constructed. Absence
        // keeps `exit_plan_mode` approval on the generic permission sheet.
        // `interactiveSurfaceAvailable` is derived from the real input+sink
        // (stdin AND stdout), not stdout alone — the wave 14 review found the
        // stdout-only probe advertised `ask_user_question` in
        // `open-grok < file` launches where no presenter could ever attach.
        let planApprovalCoordinator: PagerPlanApprovalCoordinator? =
            interactiveSurfaceAvailable ? PagerPlanApprovalCoordinator() : nil
        // `[scheduler] background_loops`, resolved once at session build —
        // upstream resolves the same value at session spawn and hands it to
        // the scheduler as a resource (`resolve_scheduler_background_loops`,
        // acp_session_impl/spawn.rs:1208-1212 → agent_rebuild.rs:540-545).
        // Both readers — the host's fire-mode selection and `/loop`'s
        // instruction mode — consume this one resolve, so they can never
        // disagree. The remote tier is passed nil: the interactive
        // composition performs no startup remote-settings fetch (recorded
        // divergence; the resolver carries the tier for the composition
        // that does).
        let schedulerBackgroundLoops = loadResolvedSchedulerBackgroundLoops(
            remote: nil,
            environment: context.environment
        ).value
        // The scheduler runtime, gated exactly like the question coordinator:
        // it exists precisely when the interactive controller (the only
        // in-session fire path) will be constructed. Headless (`-p`),
        // non-TTY, and ACP launches get `nil`, which strips `scheduler_*`
        // from the advertised list — a create whose fires can never run is
        // worse than an absent tool (AGENTS.md §4). Headless/ACP scheduler
        // support is a deferred slice.
        //
        // Persistence binds the host to the session directory's
        // `resources_state.json` — upstream's `state_path.parent().join(
        // "resources_state.json")` (registry/types.rs:1134-1140) under
        // `sessions/<id>/` (spawn.rs:946-947) — so durable tasks survive a
        // `--resume` of this session: the host loads the file at
        // construction and every mutation writes it back. The same
        // `sessions/<sessionID>` directory the monitor host uses; the id is
        // path-safe because every id reaching this point passed
        // `LiveConversationStore.validateSessionID`.
        let schedulerHost: LiveSchedulerHost? =
            interactiveSurfaceAvailable
                ? LiveSchedulerHost(
                    backgroundLoopsEnabled: schedulerBackgroundLoops,
                    persistence: LiveSchedulerPersistence.forSessionDirectory(
                        openGrokHome
                            .appendingPathComponent("sessions", isDirectory: true)
                            .appendingPathComponent(sessionID, isDirectory: true)
                    )
                )
                : nil
        // The monitor runtime, same gate: its event sink's idle half is the
        // interactive controller's queue, so a composition without the
        // controller has no path to deliver events and must not advertise
        // the tool (AGENTS.md §4). Upstream registers `monitor` in every
        // preset — headless included — because its notification bridge
        // reaches every session shape; this port's narrower advertisement
        // is a recorded divergence, the E18 headless-scheduler precedent.
        let monitorHost: LiveMonitorHost? = interactiveSurfaceAvailable
            ? LiveMonitorHost(context: LiveMonitorHost.Context(
                sessionID: sessionID,
                // The port's analog of upstream's session_folder/terminal/
                // (tool.rs:110-112): a per-session directory next to the
                // session record.
                outputDirectory: openGrokHome
                    .appendingPathComponent("sessions", isDirectory: true)
                    .appendingPathComponent(sessionID, isDirectory: true)
                    .appendingPathComponent("terminal", isDirectory: true)
            ))
            : nil
        let sessionBus = LiveSessionBus(
            openGrokHome: openGrokHome,
            cwd: cwd,
            sessionID: sessionID,
            model: samplingConfiguration.model,
            provider: samplingConfiguration.provider.asString,
            enabled: securityContext.document[path: ["session_bus", "enabled"]]?.boolValue ?? true
        )
        let toolExecutor = try await LiveToolExecutor(
            processBackend: processBackend,
            sessionID: sessionID,
            workingDirectory: cwd,
            toolPolicy: LiveAgentToolPolicy.resolveLaunchPolicy(
                tools: options.agentOptions.tools,
                disallowedTools: options.agentOptions.disallowedTools,
                profile: agentProfile?.toolPolicy
            ),
            telemetryBootstrapContext: telemetryBootstrapContext,
            fileAccessPolicy: fileAccessPolicy,
            environment: context.environment,
            imageToolContext: imageToolContext,
            videoToolContext: videoToolContext,
            webToolContext: webToolContext,
            sandboxDecision: sandboxDecision,
            securityContext: securityContext,
            sessionServices: sessionServices,
            permissionOptions: options.common.permissions,
            subagentHost: subagentHost,
            sessionCollaborationBackend: sessionBus,
            userQuestions: questionCoordinator.map { LiveUserQuestionBroker(coordinator: $0) },
            planApprovals: planApprovalCoordinator.map { LivePlanApprovalBroker(coordinator: $0) },
            schedulerHost: schedulerHost,
            monitorHost: monitorHost
        )
        if let subagentHost,
           let permissions = await toolExecutor.permissionHandle()
        {
            await subagentHost.installParentPermissionHandle(permissions)
        }
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
            questionCoordinator: questionCoordinator,
            planApprovalCoordinator: planApprovalCoordinator,
            telemetryBootstrapContext: telemetryBootstrapContext,
            toolExecutor: toolExecutor,
            sessionBus: sessionBus,
            subagentHost: subagentHost,
            discoveredSkills: discoveredSkills,
            skillCatalog: skillCatalog,
            feedback: feedback,
            schedulerBackgroundLoops: schedulerBackgroundLoops
        )
    }

    /// The session's subagent host, or `nil` when the spawn surface is gated
    /// off. The gates are upstream's (`AgentBuilder::build`,
    /// `xai-grok-agent/src/builder.rs:848-896`): subagents disabled
    /// (`--no-subagents`) strips the surface, and so does an empty roster —
    /// every built-in toggled off in `[subagents.toggle]` with nothing
    /// discovered means there is nothing to spawn, so there is nothing to
    /// advertise.
    ///
    /// Toggles are read from the trust-gated security document, not a raw
    /// config load: an untrusted repo's `.opengrok/config.toml` must not
    /// reach this decision any more than it reaches permissions.
    private static func makeSubagentHost(
        options: CLIExecutionOptions,
        cwd: URL,
        sessionID: String,
        parentCacheAffinityID: String,
        openGrokHome: URL,
        agentProfile: LiveAgentProfile?,
        samplingConfiguration: OpenGrokLiveSamplingConfiguration,
        sampler: OpenGrokLiveSampler,
        conversationStore: LiveConversationStore,
        processBackend: any ShellProcessBackend,
        securityContext: LiveSecurityContext,
        sandboxDecision: LiveSandboxDecision,
        fileAccessPolicy: FileToolAccessPolicy,
        telemetryBootstrapContext: LiveTelemetryBootstrapContext,
        imageToolContext: LiveImageToolContext,
        webToolContext: LiveWebToolContext,
        environment: [String: String],
        makeSampler: @escaping @Sendable (OpenGrokLiveSamplingConfiguration) throws -> OpenGrokLiveSampler
    ) -> LiveSubagentHost? {
        guard !options.agentOptions.noSubagents else { return nil }
        var toggles: [String: Bool] = [:]
        if let table = securityContext.document[path: ["subagents", "toggle"]]?.table {
            for (key, value) in table.pairs {
                if let enabled = value.boolValue { toggles[key] = enabled }
            }
        }
        let definitionContext = DefinitionResolutionContext(
            cwd: cwd,
            toggles: toggles,
            includeFilesystemDefinitions: true,
            environment: environment
        )
        guard !availableAgentNames(context: definitionContext).isEmpty else { return nil }
        return LiveSubagentHost(context: LiveSubagentHost.Context(
            sampler: sampler,
            parentModel: samplingConfiguration.model,
            workingDirectory: cwd,
            sessionID: sessionID,
            openGrokHome: openGrokHome,
            conversationStore: conversationStore,
            processBackend: processBackend,
            securityContext: securityContext,
            sandboxDecision: sandboxDecision,
            permissionOptions: options.common.permissions,
            fileAccessPolicy: fileAccessPolicy,
            telemetryBootstrapContext: telemetryBootstrapContext,
            imageToolContext: imageToolContext,
            webToolContext: webToolContext,
            environment: environment,
            parentCapabilityCeiling: agentProfile?.toolPolicy.capabilityMode.map { mode in
                switch mode {
                case .readOnly: return OpenGrokSubagentResolution.SubagentCapabilityMode.readOnly
                case .readWrite: return OpenGrokSubagentResolution.SubagentCapabilityMode.readWrite
                case .execute: return OpenGrokSubagentResolution.SubagentCapabilityMode.execute
                case .all: return OpenGrokSubagentResolution.SubagentCapabilityMode.all
                }
            },
            definitionContext: definitionContext,
            modelSlugs: LiveModelCatalogResolver.catalog().map(\.id),
            antigravitySelectable: LiveAntigravityComposition
                .antigravitySelectable(environment: environment),
            // The trust-independent persona base: inline [subagents.personas]
            // from the SAME trust-gated document the toggles read, plus the
            // session home's `personas/` and `bundled/personas/` dirs
            // (upstream resolve_subagents, agent/config.rs:2255-2263).
            // Loaded once here; the trusted project overlay is per-spawn
            // inside the host. The session's resolved home, never the
            // process's — a `--cwd`/injected-env launch must read the same
            // persona files the rest of the session resolved against.
            basePersonas: SubagentPersonaLoader.basePersonas(
                configDocument: securityContext.document,
                openGrokHome: openGrokHome
            ),
            parentCacheAffinityID: parentCacheAffinityID,
            parentProvider: samplingConfiguration.provider,
            parentCodexPermissions: LiveToolExecutor.codexPermissions(
                provider: .codex,
                sandbox: sandboxDecision,
                workingDirectory: cwd,
                environment: environment,
                alwaysApprove: securityContext.permissions.alwaysApprove
                    && securityContext.permissions.yoloPinReason == nil,
                autoReviewEnabled: securityContext.permissions.defaultMode == .auto
            ),
            childSamplerFactory: { model, inheritedPermissions in
                let resolution = try await LiveModelCatalogResolver(
                    environment: environment,
                    openGrokHome: openGrokHome,
                    sessionID: sessionID,
                    workingDirectory: cwd
                ).resolve(modelID: model)
                let provider = resolution.sampling.provider
                let childConfiguration = resolution.sampling.withCodexPermissions(
                    provider == .codex ? inheritedPermissions : nil
                )
                return LiveSubagentHost.ChildSamplerRoute(
                    sampler: try makeSampler(childConfiguration),
                    provider: provider,
                    codexPermissions: childConfiguration.codexPermissions
                )
            }
        ))
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
        let launchedCatalogID = catalogStore.entryForWireModel(
            foundation.samplingConfiguration.model,
            provider: foundation.samplingConfiguration.provider
        )?.id ?? foundation.samplingConfiguration.model
        catalogStore.noteModelSwitch(
            catalogID: launchedCatalogID,
            effort: foundation.samplingConfiguration.reasoningEffort
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
        // Announcements: same post-readiness spawn pattern, upstream's
        // `spawn_announcements_refresh` (agent_ops.rs:1830). The feed rides
        // the chat proxy's `/v1/settings`; the export-boundary and
        // `features.remote_fetch` gates are checked before any request, so a
        // Codex (xAI-export-denied) or firewalled session issues nothing. The
        // transport is the same one the sampler/catalog use; `nil` (headless
        // compositions without a transport) opts out of the live feed and the
        // renderer treats the absence as "no banner slot."
        let announcements: LiveAnnouncementsComposition? = {
            guard let transport = foundation.samplingConfiguration.transport else {
                return nil
            }
            // The chat-proxy base the announcements feed rides. Same resolution
            // order as the catalog/feedback transports: the `--cli-chat-proxy-
            // base-url` flag, then `GROK_CLI_CHAT_PROXY_BASE_URL`, then the
            // built-in default. `AnnouncementsService` appends the full
            // `v1/settings` path, so the `/v1` suffix the default carries is
            // stripped inside the composition.
            let proxyBase = foundation.options.advanced.cliChatProxyBaseURL
                ?? context.environment["GROK_CLI_CHAT_PROXY_BASE_URL"]
                ?? CLI_CHAT_PROXY_BASE_URL_DEFAULT
            let authorization = foundation.samplingConfiguration.apiKey.isEmpty
                ? nil
                : "Bearer \(foundation.samplingConfiguration.apiKey)"
            let composition = LiveAnnouncementsComposition.live(
                transport: transport,
                openGrokHome: foundation.openGrokHome,
                environment: context.environment,
                provider: foundation.samplingConfiguration.provider,
                proxyBaseURL: proxyBase,
                authorization: authorization
            )
            // Spawn is non-blocking and gated internally; a denied provider
            // or `remote_fetch = false` issues no request.
            composition.spawnBackgroundRefresh()
            return composition
        }()
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
        // Auto-mode LLM side-query: install when the pager/ACP/settings enter
        // `.auto`. Heuristic remains the PermissionHandle default until then.
        if let permissionMode = foundation.toolExecutor.sessionPermissionMode {
            let permissions = await foundation.toolExecutor.permissionHandle()
            let sessionID = foundation.sessionID
            await permissionMode.setAutoModeHooks(
                install: {
                    guard let permissions else { return }
                    await LiveAutoModeComposition.installLLMClassifier(
                        on: permissions,
                        sessionID: sessionID,
                        modelSwitch: modelSwitch
                    )
                },
                uninstall: {
                    guard let permissions else { return }
                    await LiveAutoModeComposition.uninstallLLMClassifier(on: permissions)
                }
            )
        }
        // A provider change invalidates the cells and stored values the
        // old runtime holds (model_switch.rs:249).
        await modelSwitch.attachCodeMode(codeMode)
        // After the fire-and-forget background catalog refresh publishes,
        // reconcile the session's effort/tier against the new catalog
        // (`ModelState::update_catalog`, acp/model_state.rs:155-192). The
        // refresh must not delay first prompt, so this awaits on a side
        // task — same shape as upstream's models_changed subscription.
        Task {
            await catalogStore.backgroundRefreshTask?.value
            await applyLiveModelCatalogReconcile(
                catalogStore: catalogStore,
                modelSwitch: modelSwitch
            )
        }
        let remoteCompactionV2Enabled = OpenGrokConfig.envBool(
            "OPENGROK_REMOTE_COMPACTION_V2",
            environment: context.environment
        ) ?? foundation.securityContext.document[
            path: ["features", "remote_compaction_v2"]
        ]?.boolValue ?? true
        let compaction = LiveCompactionCoordinator(
            history: conversationHistory,
            modelSwitch: modelSwitch,
            sessionID: foundation.sessionID,
            openGrokHome: foundation.openGrokHome,
            toolExecutor: foundation.toolExecutor,
            codexRemoteV2Enabled: remoteCompactionV2Enabled
        )
        let interjections = LiveSessionInterjections()
        // Follow-up delivery needs the interjection actor, which is born
        // here, after the foundation — so the routing installs late. Until
        // this line the coordinator queues every follow-up, its no-hook
        // default; nothing can have raced it, because the turn driver that
        // makes children reachable does not exist yet either.
        if let subagentHost = foundation.subagentHost {
            await subagentHost.installCollaborationRouting(rootInterjections: interjections)
        }
        let turnDriver = ProviderSessionTurnDriver(
            sampler: LiveShellSamplingDriver(
                modelSwitch: modelSwitch,
                toolExecutor: foundation.toolExecutor,
                conversationHistory: conversationHistory,
                systemPrompt: foundation.agentProfile?.systemPrompt,
                skillsListing: LiveSkills.listing(foundation.discoveredSkills),
                toolSurface: toolSurface,
                codeMode: codeMode,
                compaction: compaction,
                interjections: interjections,
                maxTurns: foundation.options.agentOptions.maxTurns
            )
        )
        let shell = OpenGrokShell(configuration: OpenGrokShellConfiguration(
            openGrokHome: foundation.openGrokHome,
            processBackend: foundation.processBackend,
            providerFactory: ProviderSessionFactoryAdapter(),
            turnDriver: turnDriver
        ))
        let sessionBusObserver = await startSessionBus(
            bus: foundation.sessionBus,
            shell: shell,
            interjections: interjections,
            rootSessionID: foundation.sessionID
        )
        let stack = LiveAgentStack(
            toolSurface: toolSurface,
            codeMode: codeMode,
            conversationHistory: conversationHistory,
            catalogStore: catalogStore,
            modelSwitch: modelSwitch,
            compaction: compaction,
            turnDriver: turnDriver,
            shell: shell,
            interjections: interjections,
            sessionBusObserver: sessionBusObserver,
            launchAutoUpdateTask: launchAutoUpdateTask,
            announcements: announcements
        )
        // SessionStart fires once the agent stack is ready — the tool
        // surface, Code Mode, history, model switch, compaction and turn
        // driver all exist — matching upstream's post-readiness dispatch
        // (run_loop.rs:1836-1857). Source is "startup"; modelId and
        // agentType are omitted (nil) to match the fire site
        // (event.rs:343-349).
        foundation.toolExecutor.fireObserveHook(
            event: .sessionStart,
            payload: ["source": .string("startup")]
        )
        return stack
    }

    private static func startSessionBus(
        bus: LiveSessionBus,
        shell: OpenGrokShell,
        interjections: LiveSessionInterjections,
        rootSessionID: String
    ) async -> Task<Void, Never>? {
        let events = await shell.events()
        do {
            try await bus.start { [weak bus] message in
                guard let bus else { return .rejected }
                let targetID = SessionID(message.targetSession)
                guard let session = await shell.lookupSession(targetID) else {
                    // ACP roots have no shell-owned turn queue. They remain
                    // discoverable/readable but reject peer wakeups until a
                    // serialized, agent-authored ACP prompt path exists.
                    return message.targetSession == rootSessionID ? .rejected : .unknownSession
                }

                if session.phase != .idle {
                    try await bus.recordInboundDelivery(
                        message,
                        status: .deliveredInterjection
                    )
                    return await interjections.interject(message.prompt)
                        ? .accepted
                        : .rejected
                }

                try await bus.recordInboundDelivery(message, status: .deliveredWake)
                let promptID = "peer-message-\(message.messageID)"
                do {
                    let submittedTurn = try await shell.submitTurn(
                        sessionID: targetID,
                        request: OpenGrokShellTurnRequest(
                            promptID: promptID,
                            text: message.prompt,
                            turnID: promptID
                        )
                    )
                    guard submittedTurn.sessionID == targetID,
                          submittedTurn.turnID == promptID else {
                        return .rejected
                    }
                    return .accepted
                } catch let error as OpenGrokShellError {
                    if case .turnAlreadyActive = error,
                       await interjections.interject(message.prompt) {
                        return .accepted
                    }
                    return .rejected
                } catch {
                    return .rejected
                }
            }
        } catch {
            await bus.disable()
            return nil
        }
        guard await bus.busEnabled else { return nil }

        return Task {
            do {
                for try await event in events {
                    switch event {
                    case .sessionCreated(let session):
                        guard session.sessionID.rawValue == rootSessionID else { continue }
                        try await bus.registerRootSession(
                            sessionID: session.sessionID.rawValue,
                            cwd: session.cwd,
                            model: session.modelID,
                            title: nil
                        )
                    case .turnAccepted(let turn), .turnStarted(let turn):
                        guard turn.sessionID.rawValue == rootSessionID else { continue }
                        try await bus.updateStatus(.busy, sessionID: rootSessionID)
                    case .turnCompleted(let turn):
                        guard turn.sessionID.rawValue == rootSessionID else { continue }
                        try await bus.updateStatus(.idle, sessionID: rootSessionID)
                    case .turnCancelled(let turn), .turnFailed(let turn, _):
                        guard turn.sessionID.rawValue == rootSessionID else { continue }
                        try await bus.updateStatus(.idle, sessionID: rootSessionID)
                    case .sessionClosed(let sessionID):
                        guard sessionID.rawValue == rootSessionID else { continue }
                        await bus.unregisterRootSession(sessionID.rawValue)
                    case .shutdownBegan, .shutdownCompleted:
                        await bus.stop()
                        return
                    default:
                        continue
                    }
                }
            } catch {
                await bus.disable()
            }
        }
    }

    /// The prompt driver the `acp` route uses.
    ///
    /// Builds the identical stack a headless launch builds, then drives turns
    /// through it — so an ACP `session/prompt` gets the same tool gating,
    /// fail-closed write permissions, hooks and MCP tools. Nothing about the
    /// stack is ACP-specific; only the thing consuming it differs.
    static func liveACPServices(
        dependencies: OpenGrokLiveCompositionDependencies,
        liveBoundaries: (@Sendable (String) -> ExportBoundary?)? = nil,
        registerExportBoundary: (@Sendable (String, ExportBoundary) -> Void)? = nil
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
            // The ACP reverse permission bridge. Upstream's agent ALWAYS asks
            // the client (`AcpPrompter::request`, permission/prompter.rs:775-781);
            // this port answered ACP sessions from the local pager or refused
            // outright, so a connected client could not approve anything. The
            // prompter denies whenever the reverse channel cannot answer, so
            // installing it never widens what a silent client authorizes.
            let acpPermissionPrompter = LiveACPPermissionPrompter()
            let permissionPipeline = foundation.toolExecutor.toolPermissionPipeline()
            if let permissions = await foundation.toolExecutor.permissionHandle() {
                await permissions.setPrompter(acpPermissionPrompter)
            }
            let mouseReportingToggleEnabled = LiveInteractiveControllerRenderer
                .resolveUIConfig(
                    workingDirectory: foundation.cwd,
                    environment: context.environment
                ).mouseReportingToggleEnabled
            let promptDriver = LiveACPPromptDriver(
                driver: ProviderBackedACPPromptDriver(
                    providerSession: providerSession,
                    turnDriver: stack.turnDriver
                ),
                availableCommands: LiveSkills.availableCommands(
                    builtins: OpenGrokPagerInteractiveController.visibleBuiltinCommandCatalog(
                        workflowsEnabled: true,
                        mouseReportingToggleEnabled: mouseReportingToggleEnabled
                    ),
                    skills: foundation.skillCatalog
                ),
                skillCatalog: foundation.skillCatalog,
                permissionPrompter: acpPermissionPrompter,
                shutdown: {
                    stack.sessionBusObserver?.cancel()
                    await foundation.sessionBus.stop()
                    await stack.codeMode?.shutdown()
                    await foundation.toolExecutor.shutdown()
                }
            )
            // The notification gateway (Wave 15 item 5): the outbound handle
            // the emitters below hold. The carrier composition attaches the
            // runtime it builds, so everything emitted here rides the same
            // stdio/ws channel `session/update` rides.
            let gateway = ACPNotificationGateway()
            // The mailbox's accepted-send observer → client-facing
            // `SubagentMessage` on the root session's channel
            // (`on_agent_message`, subagent_coordinator.rs:154-193). Installed
            // AFTER `makeAgentStack` wired `deliverFollowup`, through the
            // observer-only seam, so live follow-up routing stays intact.
            if let subagentHost = foundation.subagentHost {
                await subagentHost.installAgentMessageObserver { message, status in
                    let update = LiveXaiSessionUpdates.subagentMessage(message, status: status)
                    let rootSessionID = message.teamScopeID
                    Task {
                        await gateway.sendXaiSessionUpdate(
                            sessionID: rootSessionID,
                            update: update
                        )
                    }
                }
            }
            // The ext-method surface (acp_agent.rs:3794+ dispatch): feedback,
            // the `open-grok/*/models` credential family — bound to THIS
            // stack's catalog store and switch coordinator so an applied key
            // reaches the running session's sampler, not a parallel copy —
            // and `x.ai/recap` + `x.ai/btw`, whose backings read the SAME
            // conversation spine the turn driver appends to (recap samples
            // the auxiliary recap route, btw the ACTIVE route). Unregistered
            // methods get upstream's unknown-method error from the router's
            // terminal arm — see LiveACPExtensionMethods.swift for the
            // routed/refused table.
            let history = stack.conversationHistory
            let modelSwitch = stack.modelSwitch
            // The `x.ai/mcp/*` family operates on the RUNNING session's MCP
            // surfaces: the executor's retained client pool, its live
            // toolset, and its composition-time connect outcomes — never a
            // parallel pool (Wave 15 item 3). `userGrokHome` is the same
            // resolution the `mcp add`/`login` CLI verbs edit and read, so
            // an ext-method upsert and a CLI add land in the same file.
            let mcpUserHome = userGrokHome(environment: launch.environment)
                ?? launch.openGrokHome
            let mcpHandler = LiveMCPACPHandler(
                gateway: gateway,
                state: LiveMCPACPState(
                    connections: foundation.toolExecutor.mcpSessionConnections,
                    toolset: foundation.toolExecutor.mcpToolset,
                    outcomes: foundation.toolExecutor.mcpServerConnections
                ),
                declarations: LiveMCPACPHandler.trustGatedDeclarationSource(
                    workspaceRoot: foundation.cwd,
                    environment: launch.environment,
                    cli: launch.options.common.permissions
                ),
                userConfigPath: mcpUserHome.appendingPathComponent("config.toml"),
                openGrokHome: mcpUserHome,
                environment: launch.environment
            )
            await mcpHandler.attachLifecycle(sessionID: foundation.sessionID)
            let acpBusPresence = LiveACPBusPresenceRegistry(
                bus: foundation.sessionBus,
                rootSessionID: foundation.sessionID,
                workingDirectory: foundation.cwd,
                model: foundation.samplingConfiguration.model
            )
            // The session-admin trio operates on the SAME on-disk store the
            // launch path resumes from; the resident session's rename goes
            // through the live history actor so the next turn commit cannot
            // clobber the title (Wave 15 item 6). Wave 20 S4 adds info/state/
            // close over the same spine; close is latched so a second call
            // reports notResident (session_lifecycle.rs:26-39).
            let sessionCloseLatch = LiveSessionCloseLatch()
            let sessionAdmin = LiveSessionAdminACPHandler(
                openGrokHome: foundation.openGrokHome,
                gateway: gateway,
                liveSessionID: foundation.sessionID,
                renameLive: { title in try await history.rename(title: title) },
                sessionInfoSnapshot: {
                    let snapshot = await history.snapshot()
                    let route = await modelSwitch.snapshot()
                    let userTurns = snapshot.items.reduce(into: 0) { count, item in
                        if case .user = item { count += 1 }
                    }
                    return LiveSessionInfoSnapshot(
                        modelID: route.modelID,
                        modelDisplayName: nil,
                        resolvedModelID: route.modelID,
                        cwd: snapshot.workingDirectory,
                        conversationID: foundation.sessionID,
                        turns: userTurns,
                        turnIndex: snapshot.items.count,
                        context: LiveSessionContextInfo(
                            maxContextTokens: Int(route.configuration.tuning.contextWindow ?? 0),
                            currentTokens: 0
                        )
                    )
                },
                closeLive: { sessionCloseLatch.close() }
            )
            // Same registry the headless `share` route consults: register
            // the resident ACP session's boundary so `x.ai/share_session`
            // and a concurrent CLI share see the live gate (share.rs:69-76).
            let sharedExportBoundary = await history.sharedExportBoundary
            registerExportBoundary?(foundation.sessionID, sharedExportBoundary)
            let shareHandler = LiveShareACPHandler(
                environment: launch.environment,
                liveBoundaries: liveBoundaries ?? { sessionID in
                    sessionID == foundation.sessionID ? sharedExportBoundary : nil
                },
                routeDependencies: dependencies.shareRoute
            )
            let extensionRouter = LiveACPExtensionRouter.build(
                feedback: LiveFeedbackACPHandler(composition: foundation.feedback),
                models: LiveModelsACPHandler(
                    catalogStore: stack.catalogStore,
                    modelSwitch: modelSwitch
                ),
                recap: LiveRecapACPHandler(
                    gateway: gateway,
                    conversation: { await history.items },
                    recapRoute: { explicit in
                        await modelSwitch.auxiliaryRecapRoute(explicitModelID: explicit)
                    },
                    workingDirectory: launch.workingDirectory,
                    openGrokHome: launch.openGrokHome,
                    environment: launch.environment
                ),
                // `x.ai/btw` answers synchronously — the answer rides the
                // ext response itself (feedback.rs:46-93), so unlike recap
                // it needs the gateway only for the session lookup. It
                // samples the SAME conversation spine on the coordinator's
                // ACTIVE route (upstream's prepare_chat_completion +
                // session model, recap.rs:81-84, :110-112) and appends to
                // the real `btw_history.jsonl` under the session directory.
                btw: LiveBtwACPHandler(
                    gateway: gateway,
                    conversation: { await history.items },
                    activeRoute: { await modelSwitch.snapshot() },
                    history: LiveBtwHistoryStore(openGrokHome: launch.openGrokHome)
                ),
                mcp: mcpHandler,
                sessionAdmin: sessionAdmin,
                share: shareHandler
            )
            // Inbound ext notifications land on the LIVE state, never a
            // mirror: yolo on the session permission-mode handle, swarm on
            // the E8 tracker, permissions/reset on the pipeline's
            // `PermissionHandle` (LiveACPNotificationGateway.swift).
            let extensionNotifications = LiveACPInboundNotifications.build(
                permissionMode: foundation.toolExecutor.sessionPermissionMode,
                permissions: await foundation.toolExecutor.permissionHandle(),
                swarmMode: foundation.toolExecutor.swarmMode,
                gateway: gateway,
                permissionPrompter: acpPermissionPrompter
            )
            return LiveACPLaunchComponents(
                promptDriver: promptDriver,
                extensionHandler: extensionRouter,
                extensionNotifications: extensionNotifications,
                notificationGateway: gateway,
                permissionPrompter: acpPermissionPrompter,
                onSessionOpened: { sessionID, meta in
                    try await mcpHandler.openSDKServers(sessionID: sessionID, meta: meta)
                    await acpBusPresence.opened(sessionID.rawValue)
                },
                onSessionClosed: { sessionID in
                    await mcpHandler.closeSDKServers(sessionID: sessionID)
                    await acpBusPresence.closed(sessionID.rawValue)
                },
                permissionPipeline: permissionPipeline
            )
        })
    }

    private static func resolveConversationRecord(
        options: CLIExecutionOptions,
        lookupWorkingDirectory: URL,
        workingDirectory: URL,
        openGrokHome: URL,
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
            if LiveSessionTitleResolver.looksLikeSessionID(requestedResumeID) {
                sourceRecord = try await store.load(sessionID: requestedResumeID)
            } else {
                let isSafeID: Bool
                do {
                    try LiveConversationStore.validateSessionID(requestedResumeID)
                    isSafeID = true
                } catch {
                    isSafeID = false
                }
                if isSafeID,
                   let record = try await store.loadIfPresent(sessionID: requestedResumeID)
                {
                    sourceRecord = record
                } else {
                    let listings = try LiveSessionCatalog(openGrokHome: openGrokHome).list()
                    let sessionID = try LiveSessionTitleResolver.resolve(
                        value: requestedResumeID,
                        in: listings,
                        workingDirectory: lookupWorkingDirectory
                    )
                    sourceRecord = try await store.load(sessionID: sessionID)
                }
            }
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
        let catalogInput = liveCatalogResolutionInput(
            workingDirectory: workingDirectory,
            environment: environment
        )
        let configuredCatalogMap = resolveModelCatalog(input: catalogInput)
        let routeProvider = requestedProvider ?? restoredProvider
        var configuredEntry = requestedModel.flatMap { requested in
            if let routeProvider {
                return configuredCatalogMap.pairs().first { pair in
                    let entry = pair.1
                    return entry.info.provider == routeProvider
                        && (pair.0 == requested || entry.model == requested)
                }?.1
            }
            return findModelByID(configuredCatalogMap, modelID: requested)
        }
        if requestedModel == nil,
           let routeProvider,
           routeProvider == .runinfra || routeProvider == .gemini || routeProvider == .openRouter {
            configuredEntry = configuredCatalogMap.pairs().first {
                $0.1.info.provider == routeProvider
            }?.1
        }
        if routeProvider == .openRouter, let requestedModel {
            let normalizedModel = requestedModel.hasPrefix("openrouter:")
                ? String(requestedModel.dropFirst("openrouter:".count))
                : requestedModel
            let allowed = Set(catalogInput.models.openRouterEnabledModels)
            guard !normalizedModel.isEmpty,
                  allowed.contains(requestedModel)
                    || allowed.contains(normalizedModel)
                    || allowed.contains(OpenRouterModels.catalogKey(modelID: normalizedModel))
            else {
                throw CLIApplicationError.failed(
                    "OpenRouter model '\(requestedModel)' is not enabled in [models].openrouter_enabled_models"
                )
            }
            if configuredEntry == nil {
                let catalogKey = OpenRouterModels.catalogKey(modelID: normalizedModel)
                var info = ModelInfo.fallback(slug: catalogKey)
                info.id = catalogKey
                info.model = normalizedModel
                info.provider = .openRouter
                info.apiBackend = .chatCompletions
                info.baseURL = OpenRouterModels.apiBaseURL(environment: environment)
                info.authScheme = .bearer
                info.toolMode = .direct
                info.extraHeaders = [
                    ("HTTP-Referer", OpenRouterModels.httpReferer),
                    ("X-Title", OpenRouterModels.appTitle),
                ]
                configuredEntry = ModelEntry(
                    info: info,
                    envKey: .single(OpenRouterModels.apiKeyEnv)
                )
            }
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
        if provider == .openRouter {
            if !merged.keys.contains(where: { $0.caseInsensitiveCompare("HTTP-Referer") == .orderedSame }) {
                merged["HTTP-Referer"] = "https://github.com/mweinbach/open-grok"
            }
            if !merged.keys.contains(where: { $0.caseInsensitiveCompare("X-Title") == .orderedSame }) {
                merged["X-Title"] = "Open Grok"
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
        case "zai", "z_ai", "z-ai", "zai_api", "zai-api", "glm":
            return .zai
        case "runinfra", "run_infra", "run-infra":
            return .runinfra
        case "gemini", "google", "google_gemini", "google-gemini", "ai_studio", "aistudio", "gemini_api":
            return .gemini
        case "openrouter", "open_router", "open-router":
            return .openRouter
        default:
            throw CLIApplicationError.unsupported(route: "provider \(value)")
        }
    }

    private static func defaultModelProfile(
        provider: ModelProvider,
        embedded: EmbeddedDefaultModels,
        environment: [String: String]
    ) throws -> DefaultModelJSON {
        switch provider {
        case .runinfra:
            guard let entry = RunInfraModels.curatedCatalog(
                baseURL: RunInfraModels.apiBaseURL(environment: environment)
            ).pairs().first?.1 else {
                throw CLIApplicationError.failed("RunInfra has no reviewed default model")
            }
            return DefaultModelJSON.fromCatalogEntry(entry)
        case .gemini:
            guard let entry = GeminiModels.curatedCatalog(
                baseURL: GeminiModels.apiBaseURL(environment: environment)
            ).pairs().first?.1 else {
                throw CLIApplicationError.failed("Google Gemini has no reviewed default model")
            }
            return DefaultModelJSON.fromCatalogEntry(entry)
        case .openRouter:
            throw CLIApplicationError.failed(
                "OpenRouter has no enabled discovered model; enable a model in [models].openrouter_enabled_models"
            )
        default:
            break
        }
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
        case .kimi, .fireworks, .deepseek, .openCodeGo, .wafer, .zai,
             .runinfra, .gemini, .openRouter:
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

    /// One-shot startup paint cadence: resolve policy, probe the primary
    /// display at most once, and feed only the numeric Hz into
    /// `PagerFrameClock.cadence` (`display_refresh_startup.rs:68-103`).
    ///
    /// `platform` is injectable so live tests can pin 120 Hz without touching
    /// CoreGraphics; production leaves it nil.
    static func resolveStartupPaintCadence(
        environment: [String: String],
        workingDirectory: URL,
        isInteractive: Bool? = nil,
        platform: (any PagerDisplayRefreshPlatformProbing)? = nil
    ) -> TimeInterval {
        let policy = resolveDisplayRefreshPolicy(
            workingDirectory: workingDirectory,
            environment: environment
        )
        return resolveStartupPaintCadence(
            environment: environment,
            policy: policy,
            isInteractive: isInteractive,
            platform: platform
        )
    }

    /// Policy + probe → paint cadence. Package-visible for the live cadence
    /// seam test (120 Hz → 8 ms through the existing resolver).
    static func resolveStartupPaintCadence(
        environment: [String: String],
        policy: PagerDisplayRefreshPolicy,
        isInteractive: Bool? = nil,
        host: PagerDisplayRefreshHost = PagerDisplayRefreshHost.current(),
        platform: (any PagerDisplayRefreshPlatformProbing)? = nil
    ) -> TimeInterval {
        let probe = PagerDisplayRefreshProbe.probe(
            environment: environment,
            autoCadenceEnabled: policy.autoCadenceEnabled,
            probeEnabled: policy.probeEnabled,
            minHz: policy.minHz,
            maxHz: policy.maxHz,
            isInteractive: isInteractive,
            host: host,
            platform: platform
        )
        return PagerFrameClock.cadence(
            environment: environment,
            policy: policy,
            probedRefreshHz: probe.hz
        )
    }

    /// The per-provider base-URL environment override, or nil when unset —
    /// one source of truth for the ladder's top rung, shared by the cold
    /// start (`resolveProviderBaseURL`) and the `/model` switch path so the
    /// same model cannot reach a different endpoint depending on whether the
    /// session started on it or switched to it.
    static func providerBaseURLEnvironmentOverride(
        provider: ModelProvider,
        environment: [String: String]
    ) -> String? {
        let overrideKey: String
        switch provider {
        case .xai: overrideKey = "GROK_XAI_API_BASE_URL"
        case .codex: overrideKey = "GROK_CODEX_INFERENCE_BASE_URL"
        case .kimi: overrideKey = KimiModels.apiBaseURLEnv
        case .fireworks: overrideKey = FireworksModels.apiBaseURLEnv
        case .deepseek: overrideKey = DeepSeekModels.apiBaseURLEnv
        case .openCodeGo: overrideKey = OpenCodeGoModels.apiBaseURLEnv
        case .wafer: overrideKey = WaferModels.apiBaseURLEnv
        case .zai: overrideKey = ZaiModels.apiBaseURLEnv
        case .runinfra: overrideKey = RunInfraModels.apiBaseURLEnv
        case .gemini: overrideKey = GeminiModels.apiBaseURLEnv
        case .openRouter: overrideKey = OpenRouterModels.apiBaseURLEnv
        case .meta:
            // Meta endpoint constants (meta_models.rs:14-16): the
            // OPENGROK_META_API_BASE_URL override, else the model's own URL,
            // else https://api.meta.ai/v1 — the same ladder as the other
            // API-key providers.
            overrideKey = MetaModels.apiBaseURLEnv
        }
        return nonEmptyEnvironmentValue(overrideKey, environment: environment)
    }

    static func resolveProviderBaseURL(
        provider: ModelProvider,
        model: DefaultModelJSON?,
        environment: [String: String],
        configuredXaiBaseURL: String? = nil
    ) -> String {
        let fallback: String
        switch provider {
        case .xai:
            // Config beats env for xAI, per `from_config_value`'s deep merge.
            if let configuredXaiBaseURL { return configuredXaiBaseURL }
            fallback = model?.apiBaseURL ?? model?.baseURL ?? XAI_API_BASE_URL_DEFAULT
        case .codex:
            fallback = model?.apiBaseURL ?? model?.baseURL ?? CodexModels.defaultInferenceBaseURL
        case .kimi:
            fallback = model?.apiBaseURL ?? model?.baseURL ?? KimiModels.platformAPIBaseURL
        case .fireworks:
            fallback = model?.apiBaseURL ?? model?.baseURL ?? FireworksModels.apiBaseURLDefault
        case .deepseek:
            fallback = model?.apiBaseURL ?? model?.baseURL ?? DeepSeekModels.apiBaseURLDefault
        case .openCodeGo:
            fallback = model?.apiBaseURL ?? model?.baseURL ?? OpenCodeGoModels.apiBaseURLDefault
        case .wafer:
            fallback = model?.apiBaseURL ?? model?.baseURL ?? WaferModels.apiBaseURLDefault
        case .zai:
            fallback = model?.apiBaseURL ?? model?.baseURL ?? ZaiModels.apiBaseURLDefault
        case .runinfra:
            fallback = model?.apiBaseURL ?? model?.baseURL ?? RunInfraModels.apiBaseURLDefault
        case .gemini:
            fallback = model?.apiBaseURL ?? model?.baseURL ?? GeminiModels.apiBaseURLDefault
        case .openRouter:
            fallback = model?.apiBaseURL ?? model?.baseURL ?? OpenRouterModels.apiBaseURLDefault
        case .meta:
            fallback = model?.apiBaseURL ?? model?.baseURL ?? MetaModels.apiBaseURLDefault
        }
        return providerBaseURLEnvironmentOverride(provider: provider, environment: environment)
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
        case .zai:
            keys = [ZaiModels.apiKeyEnv]
        case .runinfra:
            keys = [RunInfraModels.gatewayKeyEnv, RunInfraModels.apiKeyEnv]
        case .gemini:
            keys = [GeminiModels.apiKeyEnv, GeminiModels.googleAPIKeyEnv]
        case .openRouter:
            keys = [OpenRouterModels.apiKeyEnv]
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
        case .zai:
            return ZaiModels.apiKeyEnv
        case .runinfra:
            return "\(RunInfraModels.gatewayKeyEnv) or \(RunInfraModels.apiKeyEnv)"
        case .gemini:
            return "\(GeminiModels.apiKeyEnv) or \(GeminiModels.googleAPIKeyEnv)"
        case .openRouter:
            return OpenRouterModels.apiKeyEnv
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
