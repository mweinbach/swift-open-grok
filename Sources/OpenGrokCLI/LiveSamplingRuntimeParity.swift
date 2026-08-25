import Foundation
import OpenGrokHTTP
import OpenGrokSampler
import OpenGrokSamplingTypes
import OpenGrokShared

/// Rich terminal outcome from the production actor-backed sampling seam.
struct LiveSamplingRuntimeResult: Sendable {
    let response: ConversationResponse
    let metrics: InferenceLatencyStats
}

/// The executable's bridge into the sampler's authoritative request task.
///
/// Directly consuming layer-2 streams skips retry classification, configured
/// idle deadlines, image recovery, sticky HTTP/1 fallback, and attempt metrics.
/// One actor and one event consumer per request retain those behaviors without
/// mixing concurrent session events or replacing a session-owned Codex cell.
struct LiveSamplingRuntime: Sendable {
    private let config: SamplerConfig
    private let transport: any HTTPTransport
    private let validatedClient: SamplingClient
    private let samplingLog: LiveSamplingLog?

    init(
        config: SamplerConfig,
        transport: any HTTPTransport,
        samplingLog: LiveSamplingLog? = nil
    ) throws {
        self.validatedClient = try SamplingClient(config: config, transport: transport)
        self.config = config
        self.transport = transport
        self.samplingLog = samplingLog
    }

    func sample(
        _ request: ConversationRequest,
        codexTurnState: CodexTurnStateCell? = nil,
        codexPermissions: CodexPermissions? = nil,
        retryOnlyBeforeOutput: Bool = false,
        onEvent: @escaping @Sendable (OpenGrokLiveSamplingEvent) async -> Void
    ) async throws -> LiveSamplingRuntimeResult {
        try Task.checkCancellation()

        let requestID = RequestId.random()
        let requestLog = try samplingLog?.begin(
            config: config,
            request: request,
            requestID: requestID
        )

        var effectiveConfig = config
        effectiveConfig.codexPermissions = validatedClient.provider == .codex
            ? codexPermissions
            : nil
        if effectiveConfig.attributionCallback == nil {
            effectiveConfig.attributionCallback = LiveSamplingAuth401Attribution(
                resolver: effectiveConfig.bearerResolver,
                staticBearer: effectiveConfig.apiKey
            )
        }

        let retryPolicy = OpenGrokSampler.RetryPolicy(
            maxRetries: effectiveConfig.maxRetries ?? DEFAULT_MAX_RETRIES,
            retryOnlyBeforeOutput: retryOnlyBeforeOutput
        )
        let actor = SamplerActor.spawn(
            config: effectiveConfig,
            retryPolicy: retryPolicy,
            transport: transport
        )
        if let codexTurnState, validatedClient.provider == .codex {
            actor.handle.submit(
                requestId: requestID,
                request: request,
                codexTurnState: codexTurnState
            )
        } else {
            actor.handle.submit(requestId: requestID, request: request)
        }

        return try await withTaskCancellationHandler {
            defer { actor.handle.shutdown() }
            var forwarder = LiveSamplingRuntimeEventForwarder()

            for await event in actor.events {
                try Task.checkCancellation()
                try requestLog?.observe(event)
                switch event {
                case .completed(_, let response, let metrics):
                    await forwarder.flush(onEvent: onEvent)
                    return LiveSamplingRuntimeResult(response: response, metrics: metrics)

                case .failed(_, let error):
                    await forwarder.flush(onEvent: onEvent)
                    await onEvent(.failed(error))
                    throw CLIApplicationError.failed(error.message)

                default:
                    guard case .emit(let output)? = LiveSamplingStreamMapper.map(event) else {
                        continue
                    }
                    await forwarder.forward(output, onEvent: onEvent)
                }
            }

            try Task.checkCancellation()
            try requestLog?.failUnexpectedly()
            throw CLIApplicationError.failed("sampling stream ended without a response")
        } onCancel: {
            requestLog?.cancel()
            actor.handle.cancel(requestId: requestID)
            actor.handle.shutdown()
        }
    }
}

/// Constant-time request-path attribution; export happens outside the 401 arm.
final class LiveSamplingAuth401Attribution: Auth401AttributionCallback, @unchecked Sendable {
    typealias Observer = @Sendable (Auth401AttributionRecord) -> Void

    private let resolver: (any BearerResolver)?
    private let staticBearerSuffix: String?
    private let observer: Observer?

    init(
        resolver: (any BearerResolver)?,
        staticBearer: String?,
        observer: Observer? = nil
    ) {
        self.resolver = resolver
        self.staticBearerSuffix = staticBearer.map(scrubbedBearerSuffix)
        self.observer = observer
    }

    func record401(consumer: SamplingConsumer, sentBearerPrefix: String?) {
        let currentBearerSuffix: String?
        if let resolver {
            if let bearer = resolver.currentBearer() {
                currentBearerSuffix = scrubbedBearerSuffix(bearer)
            } else if resolver.failClosedOnMissing {
                currentBearerSuffix = nil
            } else {
                currentBearerSuffix = staticBearerSuffix
            }
        } else {
            currentBearerSuffix = staticBearerSuffix
        }

        let record = Auth401AttributionRecord(
            consumer: consumer,
            sentBearer: sentBearerPrefix,
            currentBearer: currentBearerSuffix
        )
        let observer = observer
        Task {
            observer?(record)
            await LiveTelemetry.logSessionEvent(
                "auth_401_attribution",
                metadata: [
                    "consumer": .string("OaiCompatClient.\(record.consumer.asEndpoint)"),
                    // Upstream preserves these legacy field names even though
                    // their values are the distinguishing credential tails.
                    "sent_key_prefix": .string(record.sentBearerSuffix ?? ""),
                    "current_key_prefix": .string(record.currentBearerSuffix ?? ""),
                    "is_stale_snapshot": .bool(record.isStaleSnapshot),
                ]
            )
        }
    }
}

private struct LiveSamplingRuntimeEventForwarder {
    private struct PendingToolDelta {
        var index: UInt32
        var id: String?
        var name: String?
        var arguments: String
    }

    private var text = LiveTextDeltaCoalescer()
    private var reasoning = LiveTextDeltaCoalescer()
    private var toolArguments = LiveTextDeltaCoalescer()
    private var pendingTool: PendingToolDelta?

    mutating func forward(
        _ event: OpenGrokLiveSamplingEvent,
        onEvent: @escaping @Sendable (OpenGrokLiveSamplingEvent) async -> Void
    ) async {
        switch event {
        case .output(let fragment):
            await flushTool(onEvent: onEvent)
            if let batch = reasoning.flush() {
                await onEvent(.reasoning(batch))
            }
            if let batch = text.push(fragment) {
                await onEvent(.output(batch))
            }

        case .reasoning(let fragment):
            await flushTool(onEvent: onEvent)
            if let batch = text.flush() {
                await onEvent(.output(batch))
            }
            if let batch = reasoning.push(fragment) {
                await onEvent(.reasoning(batch))
            }

        case .toolCallDelta(let index, let id, let name, let arguments):
            await flushText(onEvent: onEvent)
            if let pendingTool, pendingTool.index != index {
                await flushTool(onEvent: onEvent)
            }
            var pending = pendingTool ?? PendingToolDelta(
                index: index,
                id: id,
                name: name,
                arguments: ""
            )
            if let id { pending.id = id }
            if let name, !name.isEmpty { pending.name = name }
            if let arguments, !arguments.isEmpty {
                if let batch = toolArguments.push(arguments) {
                    pending.arguments += batch
                    await onEvent(.toolCallDelta(
                        toolIndex: pending.index,
                        id: pending.id,
                        name: pending.name,
                        argumentsDelta: pending.arguments
                    ))
                    pending.arguments = ""
                }
            } else if id != nil || name != nil {
                await onEvent(.toolCallDelta(
                    toolIndex: pending.index,
                    id: pending.id,
                    name: pending.name,
                    argumentsDelta: nil
                ))
            }
            pendingTool = pending

        case .toolCallArgumentsComplete:
            await flushText(onEvent: onEvent)
            await flushTool(onEvent: onEvent)
            await onEvent(event)

        default:
            await flush(onEvent: onEvent)
            await onEvent(event)
        }
    }

    mutating func flush(
        onEvent: @escaping @Sendable (OpenGrokLiveSamplingEvent) async -> Void
    ) async {
        await flushText(onEvent: onEvent)
        await flushTool(onEvent: onEvent)
    }

    private mutating func flushText(
        onEvent: @escaping @Sendable (OpenGrokLiveSamplingEvent) async -> Void
    ) async {
        if let batch = text.flush() {
            await onEvent(.output(batch))
        }
        if let batch = reasoning.flush() {
            await onEvent(.reasoning(batch))
        }
    }

    private mutating func flushTool(
        onEvent: @escaping @Sendable (OpenGrokLiveSamplingEvent) async -> Void
    ) async {
        guard var pending = pendingTool else { return }
        if let batch = toolArguments.flush() {
            pending.arguments += batch
        }
        if !pending.arguments.isEmpty {
            await onEvent(.toolCallDelta(
                toolIndex: pending.index,
                id: pending.id,
                name: pending.name,
                argumentsDelta: pending.arguments
            ))
        }
        pendingTool = nil
        toolArguments = LiveTextDeltaCoalescer()
    }
}
