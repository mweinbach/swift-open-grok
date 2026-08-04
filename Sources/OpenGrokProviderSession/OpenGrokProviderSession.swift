import Foundation
import OpenGrokAuth
import OpenGrokChatState
import OpenGrokCompaction
import OpenGrokModels
import OpenGrokSampler
import OpenGrokSamplingTypes

public enum ProviderSessionError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidSessionID(String)
    case unknownModel(String)
    case noRoute(candidates: [String], reasons: [String])
    case unsupportedBackend(modelID: String, provider: ModelProvider, backend: ApiBackend)
    case invalidAuthSource(provider: ModelProvider, expected: BuiltInSessionAuthKind, actual: BuiltInSessionAuthKind)
    case missingCredential(provider: ModelProvider, scope: String)
    case unsupportedCodeMode(provider: ModelProvider, transport: CodeModeTransport)
    case unsupportedToolCapability(provider: ModelProvider, capability: ProviderToolCapability)
    case turnAlreadyActive(String)
    case turnNotActive(String)
    case staleTurn(String)
    case cancelled

    public var description: String {
        switch self {
        case .invalidSessionID(let id): return "invalid Open Grok session id: \(id)"
        case .unknownModel(let id): return "model is not in the session catalog: \(id)"
        case .noRoute(let candidates, let reasons):
            return "no provider route for [\(candidates.joined(separator: ", "))]: \(reasons.joined(separator: "; "))"
        case .unsupportedBackend(let modelID, let provider, let backend):
            return "model \(modelID) selects unsupported \(backend.rawValue) backend for \(provider.asString)"
        case .invalidAuthSource(let provider, let expected, let actual):
            return "auth source \(actual.asString) cannot authenticate \(provider.asString); expected \(expected.asString)"
        case .missingCredential(let provider, let scope):
            return "missing credential for \(provider.asString) scope \(scope)"
        case .unsupportedCodeMode(let provider, let transport):
            return "Code Mode is unsupported for \(provider.asString) (transport \(transport.rawValue))"
        case .unsupportedToolCapability(let provider, let capability):
            return "tool capability \(capability.rawValue) is unsupported for \(provider.asString)"
        case .turnAlreadyActive(let id): return "provider session turn already active: \(id)"
        case .turnNotActive(let id): return "provider session turn is not active: \(id)"
        case .staleTurn(let id): return "provider session turn is stale: \(id)"
        case .cancelled: return "provider session operation cancelled"
        }
    }

    fileprivate var canFallback: Bool {
        switch self {
        case .unknownModel, .unsupportedBackend, .invalidAuthSource, .missingCredential,
             .unsupportedCodeMode, .unsupportedToolCapability:
            return true
        default:
            return false
        }
    }
}

public enum ProviderToolCapability: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case directTools = "direct_tools"
    case codeMode = "code_mode"
    case codeModeOnly = "code_mode_only"
    case hostedWebSearch = "hosted_web_search"
    case imageInput = "image_input"
    case remoteMCP = "remote_mcp"
    case xaiServices = "xai_services"
}

public struct ProviderToolRequest: Sendable, Equatable {
    public var mode: ToolMode?
    public var capabilities: Set<ProviderToolCapability>
    public var strictCapabilities: Bool

    public init(
        mode: ToolMode? = nil,
        capabilities: Set<ProviderToolCapability> = [],
        strictCapabilities: Bool = false
    ) {
        self.mode = mode
        self.capabilities = capabilities
        self.strictCapabilities = strictCapabilities
    }
}

public struct ProviderToolSurface: Sendable, Equatable {
    public let mode: ToolMode
    public let codeModeTransport: CodeModeTransport
    public let hostedToolDialect: HostedToolDialect?
    public let nativeWebSearch: Bool
    public let enabledCapabilities: Set<ProviderToolCapability>
    public let hiddenCapabilities: Set<ProviderToolCapability>

    public var codeModeEnabled: Bool {
        mode == .codeMode || mode == .codeModeOnly
    }

    public var supportsHostedWebSearch: Bool {
        enabledCapabilities.contains(.hostedWebSearch)
    }

    public init(
        mode: ToolMode,
        codeModeTransport: CodeModeTransport,
        hostedToolDialect: HostedToolDialect?,
        nativeWebSearch: Bool,
        enabledCapabilities: Set<ProviderToolCapability>,
        hiddenCapabilities: Set<ProviderToolCapability>
    ) {
        self.mode = mode
        self.codeModeTransport = codeModeTransport
        self.hostedToolDialect = hostedToolDialect
        self.nativeWebSearch = nativeWebSearch
        self.enabledCapabilities = enabledCapabilities
        self.hiddenCapabilities = hiddenCapabilities
    }
}

public struct ProviderCredentialBinding: Sendable {
    public let scope: String
    public let kind: BuiltInSessionAuthKind
    private let source: any AuthCredentialProvider

    public init(scope: String, kind: BuiltInSessionAuthKind, source: any AuthCredentialProvider) {
        self.scope = scope
        self.kind = kind
        self.source = source
    }

    public static func apiKey(
        scope: String,
        key: String
    ) -> ProviderCredentialBinding {
        ProviderCredentialBinding(
            scope: scope,
            kind: .apiKeyOnly,
            source: StaticAuthCredentialProvider(bearer: key)
        )
    }

    public static func deploymentKey(
        scope: String,
        key: String
    ) -> ProviderCredentialBinding {
        ProviderCredentialBinding(
            scope: scope,
            kind: .apiKeyOnly,
            source: StaticAuthCredentialProvider.deploymentKey(key)
        )
    }

    public var hasUsableCredential: Bool {
        source.hasUsableCredential()
    }

    public var credentialIdentity: String? {
        let snapshot = source.snapshot()
        return snapshot.deploymentID ?? snapshot.apiKeyID ?? snapshot.userID ?? snapshot.teamID
    }

    fileprivate var credentialProvider: any AuthCredentialProvider { source }
}

public struct ProviderSessionConfiguration: Sendable {
    public let sessionID: String
    public let modelCatalog: [String: ModelEntry]
    public let initialModelID: String
    public let credentialBindings: [ModelProvider: ProviderCredentialBinding]
    public let fallbackModelIDs: [String]
    public let auxiliaryModelIDs: [ProviderAuxiliaryRole: String]
    public let toolRequest: ProviderToolRequest
    public let retryPolicy: RetryPolicy
    public let openGrokHome: URL
    public let environment: [String: String]

    public init(
        sessionID: String,
        modelCatalog: [String: ModelEntry],
        initialModelID: String,
        credentialBindings: [ModelProvider: ProviderCredentialBinding] = [:],
        fallbackModelIDs: [String] = [],
        auxiliaryModelIDs: [ProviderAuxiliaryRole: String] = [:],
        toolRequest: ProviderToolRequest = ProviderToolRequest(),
        retryPolicy: RetryPolicy = .default,
        openGrokHome: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.sessionID = sessionID
        self.modelCatalog = modelCatalog
        self.initialModelID = initialModelID
        self.credentialBindings = credentialBindings
        self.fallbackModelIDs = fallbackModelIDs
        self.auxiliaryModelIDs = auxiliaryModelIDs
        self.toolRequest = toolRequest
        self.retryPolicy = retryPolicy
        self.environment = environment
        self.openGrokHome = openGrokHome
            ?? ProviderSession.defaultOpenGrokHome(environment: environment)
    }

    public init(
        sessionID: String,
        catalog: OrderedModelMap,
        initialModelID: String,
        credentialBindings: [ModelProvider: ProviderCredentialBinding] = [:],
        fallbackModelIDs: [String] = [],
        auxiliaryModelIDs: [ProviderAuxiliaryRole: String] = [:],
        toolRequest: ProviderToolRequest = ProviderToolRequest(),
        retryPolicy: RetryPolicy = .default,
        openGrokHome: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.init(
            sessionID: sessionID,
            modelCatalog: Dictionary(uniqueKeysWithValues: catalog.pairs()),
            initialModelID: initialModelID,
            credentialBindings: credentialBindings,
            fallbackModelIDs: fallbackModelIDs,
            auxiliaryModelIDs: auxiliaryModelIDs,
            toolRequest: toolRequest,
            retryPolicy: retryPolicy,
            openGrokHome: openGrokHome,
            environment: environment
        )
    }
}

public enum ProviderSessionState: Sendable, Equatable {
    case ready(modelID: String, provider: ModelProvider, generation: UInt64)
    case switching(fromModelID: String, toModelID: String)
    case sampling(turnID: String, modelID: String, attempt: UInt32)
    case completed(turnID: String, modelID: String)
    case failed(turnID: String, modelID: String)
    case cancelled(turnID: String, modelID: String)
}

public struct ProviderStateTransition: Sendable, Equatable {
    public let sequence: UInt64
    public let operation: String
    public let from: ProviderSessionState
    public let to: ProviderSessionState

    public init(
        sequence: UInt64,
        operation: String,
        from: ProviderSessionState,
        to: ProviderSessionState
    ) {
        self.sequence = sequence
        self.operation = operation
        self.from = from
        self.to = to
    }
}

public struct ProviderRouteSummary: Sendable, Equatable {
    public let modelID: String
    public let model: String
    public let provider: ModelProvider
    public let profileID: String
    public let authScope: String
    public let authKind: BuiltInSessionAuthKind
    public let toolSurface: ProviderToolSurface
    public let compactionBudget: CompactionBudget
    public let canExportToXAI: Bool

    fileprivate init(route: ProviderRoute) {
        self.modelID = route.modelID
        self.model = route.model
        self.provider = route.provider
        self.profileID = route.profile.id
        self.authScope = route.authScope
        self.authKind = route.authKind
        self.toolSurface = route.toolSurface
        self.compactionBudget = route.compactionBudget
        self.canExportToXAI = route.canExportToXAI
    }
}

public enum ProviderAuxiliaryRole: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case webSearch = "web_search"
    case imageDescription = "image_description"
    case sessionSummary = "session_summary"
    case recap
    case compaction
}

public struct ProviderUsageRecord: Sendable, Equatable, Hashable {
    public let provider: ModelProvider
    public let modelID: String
    public let totals: UsageTotals

    public init(provider: ModelProvider, modelID: String, totals: UsageTotals) {
        self.provider = provider
        self.modelID = modelID
        self.totals = totals
    }
}

public struct ProviderQuotaWindow: Sendable, Equatable, Hashable {
    public let provider: ModelProvider
    public let used: UInt64
    public let limit: UInt64?
    public let resetAt: Date?
    public let durationSeconds: UInt64?

    public init(
        provider: ModelProvider,
        used: UInt64,
        limit: UInt64? = nil,
        resetAt: Date? = nil,
        durationSeconds: UInt64? = nil
    ) {
        self.provider = provider
        self.used = used
        self.limit = limit
        self.resetAt = resetAt
        self.durationSeconds = durationSeconds
    }
}

public struct ProviderUsageFailure: Error, Sendable, Equatable, Hashable, CustomStringConvertible {
    public let provider: ModelProvider
    public let message: String

    public init(provider: ModelProvider, message: String) {
        self.provider = provider
        self.message = message
    }

    public var description: String { "\(provider.asString) usage failed: \(message)" }
}

public struct CombinedProviderUsage: Sendable, Equatable {
    public let windows: [ProviderQuotaWindow]
    public let failures: [ProviderUsageFailure]

    public init(windows: [ProviderQuotaWindow], failures: [ProviderUsageFailure]) {
        self.windows = windows
        self.failures = failures
    }
}

public protocol ProviderUsageSource: Sendable {
    func fetchUsage() async throws -> ProviderQuotaWindow
}

public func fetchCombinedProviderUsage(
    sources: [ModelProvider: any ProviderUsageSource]
) async -> CombinedProviderUsage {
    let results = await withTaskGroup(of: Result<ProviderQuotaWindow, ProviderUsageFailure>.self) { group in
        for (provider, source) in sources {
            group.addTask {
                do {
                    return .success(try await source.fetchUsage())
                } catch {
                    return .failure(ProviderUsageFailure(provider: provider, message: "usage request failed"))
                }
            }
        }
        var collected: [Result<ProviderQuotaWindow, ProviderUsageFailure>] = []
        for await result in group {
            collected.append(result)
        }
        return collected
    }
    var windows = results.compactMap { result -> ProviderQuotaWindow? in
        if case .success(let window) = result { return window }
        return nil
    }
    var failures = results.compactMap { result -> ProviderUsageFailure? in
        if case .failure(let failure) = result { return failure }
        return nil
    }
    windows.sort { $0.provider.asString < $1.provider.asString }
    failures.sort { $0.provider.asString < $1.provider.asString }
    return CombinedProviderUsage(windows: windows, failures: failures)
}

public struct ProviderSessionSnapshot: Sendable, Equatable {
    public let sessionID: String
    public let sessionDirectory: URL
    public let state: ProviderSessionState
    public let route: ProviderRouteSummary
    public let generation: UInt64
    public let completedTurns: UInt64
    public let historyRevision: UInt64
    public let everUsedNonXAI: Bool
    public let usage: [ProviderUsageRecord]

    fileprivate init(
        sessionID: String,
        sessionDirectory: URL,
        state: ProviderSessionState,
        route: ProviderRoute,
        generation: UInt64,
        completedTurns: UInt64,
        historyRevision: UInt64,
        everUsedNonXAI: Bool,
        usage: [ProviderUsageRecord]
    ) {
        self.sessionID = sessionID
        self.sessionDirectory = sessionDirectory
        self.state = state
        self.route = ProviderRouteSummary(route: route)
        self.generation = generation
        self.completedTurns = completedTurns
        self.historyRevision = historyRevision
        self.everUsedNonXAI = everUsedNonXAI
        self.usage = usage
    }
}

public struct ProviderTurnContext: Sendable {
    public let sessionID: String
    public let turnID: String
    public let route: ProviderRoute
    public let cancellation: OpenGrokSampler.CancellationToken
    public let attempt: UInt32

    fileprivate init(
        sessionID: String,
        turnID: String,
        route: ProviderRoute,
        cancellation: OpenGrokSampler.CancellationToken,
        attempt: UInt32
    ) {
        self.sessionID = sessionID
        self.turnID = turnID
        self.route = route
        self.cancellation = cancellation
        self.attempt = attempt
    }
}

public struct ProviderRoute: Sendable {
    public let modelID: String
    public let model: String
    public let provider: ModelProvider
    public let profile: ProviderProfile
    public let authScope: String
    public let authKind: BuiltInSessionAuthKind
    public let hasUsableCredential: Bool
    public let toolSurface: ProviderToolSurface
    public let compactionBudget: CompactionBudget
    public let samplingConfig: SamplerConfig
    public let canExportToXAI: Bool
    private let credentialProvider: any AuthCredentialProvider

    fileprivate init(
        modelID: String,
        model: String,
        provider: ModelProvider,
        profile: ProviderProfile,
        authScope: String,
        authKind: BuiltInSessionAuthKind,
        hasUsableCredential: Bool,
        toolSurface: ProviderToolSurface,
        compactionBudget: CompactionBudget,
        samplingConfig: SamplerConfig,
        canExportToXAI: Bool,
        credentialProvider: any AuthCredentialProvider
    ) {
        self.modelID = modelID
        self.model = model
        self.provider = provider
        self.profile = profile
        self.authScope = authScope
        self.authKind = authKind
        self.hasUsableCredential = hasUsableCredential
        self.toolSurface = toolSurface
        self.compactionBudget = compactionBudget
        self.samplingConfig = samplingConfig
        self.canExportToXAI = canExportToXAI
        self.credentialProvider = credentialProvider
    }

    public var summary: ProviderRouteSummary {
        ProviderRouteSummary(route: self)
    }

    public var credentialIdentity: String? {
        let snapshot = credentialProvider.snapshot()
        return snapshot.deploymentID ?? snapshot.apiKeyID ?? snapshot.userID ?? snapshot.teamID
    }

    public func refreshAfterUnauthorized() async -> Bool {
        await credentialProvider.refreshAfterUnauthorized()
    }
}

public enum ProviderRequestDisposition: Sendable {
    case retry(RetryDecision)
    case recoverAuthentication
    case terminal
}

public actor ProviderSession {
    private struct ActiveTurn: Sendable {
        let turnID: String
        let modelID: String
        let cancellation: OpenGrokSampler.CancellationToken
        var attempt: UInt32
    }

    private let sessionID: String
    private let sessionDirectory: URL
    private let modelCatalog: [String: ModelEntry]
    private let credentialBindings: [ModelProvider: ProviderCredentialBinding]
    private let fallbackModelIDs: [String]
    private let auxiliaryModelIDs: [ProviderAuxiliaryRole: String]
    private let toolRequest: ProviderToolRequest
    private let retryPolicy: RetryPolicy
    private let environment: [String: String]
    private var route: ProviderRoute
    private var state: ProviderSessionState
    private var activeTurn: ActiveTurn?
    private var generation: UInt64 = 0
    private var transitionSequence: UInt64 = 0
    private var transitions: [ProviderStateTransition] = []
    private var completedTurns: UInt64 = 0
    private var historyRevision: UInt64 = 0
    private var everUsedNonXAI: Bool
    private var usageByRoute: [String: ProviderUsageRecord] = [:]

    public init(configuration: ProviderSessionConfiguration) throws {
        guard ProviderSession.isValidSessionID(configuration.sessionID) else {
            throw ProviderSessionError.invalidSessionID(configuration.sessionID)
        }
        self.sessionID = configuration.sessionID
        self.sessionDirectory = configuration.openGrokHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(configuration.sessionID, isDirectory: true)
        self.modelCatalog = configuration.modelCatalog
        self.credentialBindings = configuration.credentialBindings
        self.fallbackModelIDs = configuration.fallbackModelIDs
        self.auxiliaryModelIDs = configuration.auxiliaryModelIDs
        self.toolRequest = configuration.toolRequest
        self.retryPolicy = configuration.retryPolicy
        self.environment = configuration.environment
        let initial = try ProviderSession.resolveRoute(
            candidates: [configuration.initialModelID] + configuration.fallbackModelIDs,
            catalog: configuration.modelCatalog,
            credentialBindings: configuration.credentialBindings,
            toolRequest: configuration.toolRequest,
            retryPolicy: configuration.retryPolicy,
            environment: configuration.environment,
            everUsedNonXAI: false
        )
        self.route = initial.route
        self.state = .ready(modelID: initial.route.modelID, provider: initial.route.provider, generation: 0)
        self.everUsedNonXAI = !initial.route.profile.isXai
    }

    public init(
        sessionID: String,
        modelsManager: ModelsManager,
        initialModelID: String? = nil,
        credentialBindings: [ModelProvider: ProviderCredentialBinding] = [:],
        fallbackModelIDs: [String] = [],
        auxiliaryModelIDs: [ProviderAuxiliaryRole: String] = [:],
        toolRequest: ProviderToolRequest = ProviderToolRequest(),
        retryPolicy: RetryPolicy = .default,
        openGrokHome: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        let current = modelsManager.currentModel()
        try self.init(configuration: ProviderSessionConfiguration(
            sessionID: sessionID,
            modelCatalog: Dictionary(uniqueKeysWithValues: modelsManager.catalogSnapshot().pairs()),
            initialModelID: initialModelID ?? current.id,
            credentialBindings: credentialBindings,
            fallbackModelIDs: fallbackModelIDs,
            auxiliaryModelIDs: auxiliaryModelIDs,
            toolRequest: toolRequest,
            retryPolicy: retryPolicy,
            openGrokHome: openGrokHome,
            environment: environment
        ))
    }

    public static func defaultOpenGrokHome(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let value = environment["OPENGROK_HOME"], !value.isEmpty {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        let home = environment["HOME"] ?? environment["USERPROFILE"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".opengrok", isDirectory: true)
    }

    public func currentRoute() -> ProviderRoute { route }

    public func snapshot() -> ProviderSessionSnapshot {
        ProviderSessionSnapshot(
            sessionID: sessionID,
            sessionDirectory: sessionDirectory,
            state: state,
            route: route,
            generation: generation,
            completedTurns: completedTurns,
            historyRevision: historyRevision,
            everUsedNonXAI: everUsedNonXAI,
            usage: usageSnapshot()
        )
    }

    public func stateHistory() -> [ProviderStateTransition] { transitions }

    public func usageSnapshot() -> [ProviderUsageRecord] {
        usageByRoute.values.sorted {
            if $0.provider != $1.provider { return $0.provider.asString < $1.provider.asString }
            return $0.modelID < $1.modelID
        }
    }

    public func isTurnActive() -> Bool { activeTurn != nil }

    public func beginTurn(turnID: String = UUID().uuidString) throws -> ProviderTurnContext {
        if Task.isCancelled { throw ProviderSessionError.cancelled }
        guard activeTurn == nil else {
            throw ProviderSessionError.turnAlreadyActive(activeTurn?.turnID ?? turnID)
        }
        let token = OpenGrokSampler.CancellationToken()
        activeTurn = ActiveTurn(turnID: turnID, modelID: route.modelID, cancellation: token, attempt: 0)
        transition(
            to: .sampling(turnID: turnID, modelID: route.modelID, attempt: 0),
            operation: "begin_turn"
        )
        return ProviderTurnContext(
            sessionID: sessionID,
            turnID: turnID,
            route: route,
            cancellation: token,
            attempt: 0
        )
    }

    public func beginRetry(turnID: String) throws -> ProviderTurnContext {
        if Task.isCancelled { throw ProviderSessionError.cancelled }
        guard var activeTurn, activeTurn.turnID == turnID else {
            throw ProviderSessionError.turnNotActive(turnID)
        }
        if activeTurn.cancellation.isCancelled { throw ProviderSessionError.cancelled }
        activeTurn.attempt &+= 1
        self.activeTurn = activeTurn
        transition(
            to: .sampling(turnID: turnID, modelID: activeTurn.modelID, attempt: activeTurn.attempt),
            operation: "begin_retry"
        )
        return ProviderTurnContext(
            sessionID: sessionID,
            turnID: turnID,
            route: route,
            cancellation: activeTurn.cancellation,
            attempt: activeTurn.attempt
        )
    }

    public func finishTurn(turnID: String) throws {
        guard let activeTurn, activeTurn.turnID == turnID else {
            throw ProviderSessionError.staleTurn(turnID)
        }
        if activeTurn.cancellation.isCancelled {
            self.activeTurn = nil
            transition(
                to: .cancelled(turnID: turnID, modelID: activeTurn.modelID),
                operation: "finish_cancelled_turn"
            )
            throw ProviderSessionError.cancelled
        }
        self.activeTurn = nil
        completedTurns &+= 1
        historyRevision &+= 1
        transition(
            to: .completed(turnID: turnID, modelID: activeTurn.modelID),
            operation: "finish_turn"
        )
    }

    public func recordUsage(
        turnID: String,
        usage: TokenUsage,
        apiDurationMS: UInt64? = nil,
        costUSDTicks: Int64? = nil
    ) throws {
        guard let activeTurn, activeTurn.turnID == turnID else {
            throw ProviderSessionError.staleTurn(turnID)
        }
        let normalizedCost = normalizedCostTicks(costUSDTicks)
        let call = ProviderUsageRecord(
            provider: route.provider,
            modelID: route.modelID,
            totals: UsageTotals(
                inputTokens: UInt64(usage.promptTokens),
                outputTokens: UInt64(usage.completionTokens),
                cachedReadTokens: UInt64(usage.cachedPromptTokens),
                reasoningTokens: UInt64(usage.reasoningTokens),
                modelCalls: 1,
                apiDurationMs: apiDurationMS ?? 0,
                costUsdTicks: normalizedCost,
                costMissingCalls: normalizedCost == nil ? 1 : 0
            )
        )
        let key = "\(route.provider.asString):\(route.modelID)"
        if let existing = usageByRoute[key] {
            usageByRoute[key] = ProviderUsageRecord(
                provider: existing.provider,
                modelID: existing.modelID,
                totals: mergeUsageTotals(existing.totals, call.totals)
            )
        } else {
            usageByRoute[key] = call
        }
    }

    public func failTurn(turnID: String) throws {
        guard let activeTurn, activeTurn.turnID == turnID else {
            throw ProviderSessionError.staleTurn(turnID)
        }
        self.activeTurn = nil
        transition(
            to: .failed(turnID: turnID, modelID: activeTurn.modelID),
            operation: "fail_turn"
        )
    }

    @discardableResult
    public func cancelActiveTurn() -> Bool {
        guard let activeTurn else { return false }
        activeTurn.cancellation.cancel()
        self.activeTurn = nil
        transition(
            to: .cancelled(turnID: activeTurn.turnID, modelID: activeTurn.modelID),
            operation: "cancel_turn"
        )
        return true
    }

    @discardableResult
    public func cancelTurn(turnID: String) throws -> Bool {
        guard let activeTurn else { return false }
        guard activeTurn.turnID == turnID else {
            throw ProviderSessionError.staleTurn(turnID)
        }
        return cancelActiveTurn()
    }

    public func switchModel(
        to modelID: String,
        fallbackModelIDs: [String]? = nil
    ) throws -> ProviderRoute {
        guard activeTurn == nil else {
            throw ProviderSessionError.turnAlreadyActive(activeTurn?.turnID ?? "")
        }
        let candidates = [modelID] + (fallbackModelIDs ?? self.fallbackModelIDs)
        let resolved = try ProviderSession.resolveRoute(
            candidates: candidates,
            catalog: modelCatalog,
            credentialBindings: credentialBindings,
            toolRequest: toolRequest,
            retryPolicy: retryPolicy,
            environment: environment,
            everUsedNonXAI: everUsedNonXAI
        )
        let previous = route
        transition(
            to: .switching(fromModelID: previous.modelID, toModelID: resolved.route.modelID),
            operation: "switch_model"
        )
        generation &+= 1
        if !resolved.route.profile.isXai { everUsedNonXAI = true }
        route = resolved.route
        historyRevision &+= 1
        transition(
            to: .ready(modelID: route.modelID, provider: route.provider, generation: generation),
            operation: "install_model_route"
        )
        return route
    }

    public func auxiliaryRoute(for role: ProviderAuxiliaryRole) throws -> ProviderRoute {
        let requested = auxiliaryModelIDs[role] ?? Self.defaultAuxiliaryModelID(for: role)
        return try ProviderSession.resolveRoute(
            candidates: [requested, route.modelID],
            catalog: modelCatalog,
            credentialBindings: credentialBindings,
            toolRequest: ProviderToolRequest(mode: .direct),
            retryPolicy: retryPolicy,
            environment: environment,
            everUsedNonXAI: everUsedNonXAI
        ).route
    }

    public func retryDecision(
        for error: SamplingError,
        retryCount: UInt32
    ) -> RetryDecision {
        classifyError(
            error,
            retryCount: retryCount,
            maxRetries: route.samplingConfig.maxRetries ?? retryPolicy.maxRetries,
            rateLimitThreshold: retryPolicy.rateLimitRetryThreshold
        )
    }

    public func requestDisposition(
        for error: SamplingError,
        retryCount: UInt32
    ) -> ProviderRequestDisposition {
        if error.isAuthError { return .recoverAuthentication }
        let decision = retryDecision(for: error, retryCount: retryCount)
        switch decision {
        case .retry, .retryWithBackoff, .retryWithImageStrip, .retryWithClientRebuild:
            return .retry(decision)
        case .emitToSession, .fatal:
            return .terminal
        }
    }

    public func recoverAuthentication() async throws -> Bool {
        if Task.isCancelled { throw ProviderSessionError.cancelled }
        return await route.refreshAfterUnauthorized()
    }

    private func transition(to next: ProviderSessionState, operation: String) {
        transitionSequence &+= 1
        let event = ProviderStateTransition(
            sequence: transitionSequence,
            operation: operation,
            from: state,
            to: next
        )
        transitions.append(event)
        state = next
    }

    private struct ResolvedRoute: Sendable {
        let route: ProviderRoute
        let failures: [ProviderSessionError]
    }

    private static func resolveRoute(
        candidates: [String],
        catalog: [String: ModelEntry],
        credentialBindings: [ModelProvider: ProviderCredentialBinding],
        toolRequest: ProviderToolRequest,
        retryPolicy: RetryPolicy,
        environment: [String: String],
        everUsedNonXAI: Bool
    ) throws -> ResolvedRoute {
        var orderedCandidates: [String] = []
        var seen: Set<String> = []
        for candidate in candidates where !candidate.isEmpty && seen.insert(candidate).inserted {
            orderedCandidates.append(candidate)
        }
        var failures: [ProviderSessionError] = []
        for candidate in orderedCandidates {
            do {
                let route = try makeRoute(
                    modelID: candidate,
                    catalog: catalog,
                    credentialBindings: credentialBindings,
                    toolRequest: toolRequest,
                    retryPolicy: retryPolicy,
                    environment: environment,
                    everUsedNonXAI: everUsedNonXAI
                )
                return ResolvedRoute(route: route, failures: failures)
            } catch let error as ProviderSessionError where error.canFallback {
                failures.append(error)
            } catch let error as ProviderSessionError {
                throw error
            }
        }
        if orderedCandidates.isEmpty {
            throw ProviderSessionError.noRoute(candidates: [], reasons: ["no model candidates supplied"])
        }
        throw ProviderSessionError.noRoute(
            candidates: orderedCandidates,
            reasons: failures.map(\.description)
        )
    }

    private static func makeRoute(
        modelID: String,
        catalog: [String: ModelEntry],
        credentialBindings: [ModelProvider: ProviderCredentialBinding],
        toolRequest: ProviderToolRequest,
        retryPolicy: RetryPolicy,
        environment: [String: String],
        everUsedNonXAI: Bool
    ) throws -> ProviderRoute {
        let resolvedID: String
        let entry: ModelEntry
        if let direct = catalog[modelID] {
            resolvedID = modelID
            entry = direct
        } else if let match = catalog.first(where: { $0.value.info.model == modelID }) {
            resolvedID = match.key
            entry = match.value
        } else {
            throw ProviderSessionError.unknownModel(modelID)
        }
        let info = entry.info
        let profile = info.provider.profile
        guard profile.supportsBackend(info.apiBackend) else {
            throw ProviderSessionError.unsupportedBackend(
                modelID: resolvedID,
                provider: info.provider,
                backend: info.apiBackend
            )
        }

        let binding: ProviderCredentialBinding
        let authKind: BuiltInSessionAuthKind
        if let configured = credentialBindings[info.provider] {
            guard configured.kind == profile.sessionAuth || configured.kind == .apiKeyOnly else {
                throw ProviderSessionError.invalidAuthSource(
                    provider: info.provider,
                    expected: profile.sessionAuth,
                    actual: configured.kind
                )
            }
            binding = configured
            authKind = configured.kind
        } else if let ownCredential = entry.ownCredential(environment: environment) {
            binding = ProviderCredentialBinding.apiKey(scope: "model:\(resolvedID)", key: ownCredential)
            authKind = .apiKeyOnly
        } else {
            throw ProviderSessionError.missingCredential(provider: info.provider, scope: profile.sessionAuth.asString)
        }
        guard binding.hasUsableCredential else {
            throw ProviderSessionError.missingCredential(provider: info.provider, scope: binding.scope)
        }

        let requestedMode = toolRequest.mode ?? info.toolMode ?? .direct
        let codeModeRequested = requestedMode == .codeMode || requestedMode == .codeModeOnly
        let codeModeSupported = profile.codeModeTransport != .unsupported
        if codeModeRequested && !codeModeSupported && requestedMode == .codeModeOnly {
            throw ProviderSessionError.unsupportedCodeMode(
                provider: info.provider,
                transport: profile.codeModeTransport
            )
        }
        let effectiveMode: ToolMode = codeModeRequested && !codeModeSupported ? .direct : requestedMode
        let enabled = enabledCapabilities(
            mode: effectiveMode,
            profile: profile,
            requested: toolRequest.capabilities,
            everUsedNonXAI: everUsedNonXAI
        )
        let hidden = Set(ProviderToolCapability.allCases.filter { !enabled.contains($0) })
        if toolRequest.strictCapabilities {
            for capability in toolRequest.capabilities where !enabled.contains(capability) {
                if capability == .codeMode || capability == .codeModeOnly {
                    throw ProviderSessionError.unsupportedCodeMode(
                        provider: info.provider,
                        transport: profile.codeModeTransport
                    )
                }
                throw ProviderSessionError.unsupportedToolCapability(
                    provider: info.provider,
                    capability: capability
                )
            }
        }
        let surface = ProviderToolSurface(
            mode: effectiveMode,
            codeModeTransport: profile.codeModeTransport,
            hostedToolDialect: profile.hostedToolDialect,
            nativeWebSearch: profile.nativeWebSearch,
            enabledCapabilities: enabled,
            hiddenCapabilities: hidden
        )

        let resolver = ProviderBearerResolver(
            source: binding.credentialProvider,
            sendsXGrokHeaders: profile.requestMetadata.sendsXGrokHeaders
        )
        let baseURL = authKind == .apiKeyOnly ? (entry.apiBaseURL ?? info.baseURL) : info.baseURL
        let effectiveCatalogAuthScheme = OpenGrokModels.effectiveAuthScheme(
            provider: info.provider,
            configured: info.authScheme
        )
        let samplerAuthScheme: OpenGrokSampler.AuthScheme = effectiveCatalogAuthScheme.rawValue == "x_api_key"
            ? .xApiKey
            : .bearer
        let samplingConfig = SamplerConfig(
            baseURL: baseURL,
            model: info.model,
            maxCompletionTokens: info.maxCompletionTokens,
            temperature: info.temperature,
            topP: info.topP,
            apiBackend: info.apiBackend,
            provider: info.provider,
            authScheme: samplerAuthScheme,
            extraHeaders: info.extraHeaders.map { (name: $0.0, value: $0.1) },
            contextWindow: info.contextWindow,
            maxRetries: info.maxRetries ?? retryPolicy.maxRetries,
            streamToolCalls: info.streamToolCalls ?? false,
            idleTimeoutSecs: info.inferenceIdleTimeoutSecs,
            reasoningEffort: info.reasoningEffort,
            supportsBackendSearch: info.supportsBackendSearch,
            codexMultiAgentV2: info.codexMultiAgentV2,
            compactionsRemaining: info.compactionsRemaining,
            compactionAtTokens: info.compactionAtTokens,
            bearerResolver: resolver
        )
        let compactionThreshold = info.autoCompactThresholdPercent ?? DEFAULT_AUTO_COMPACT_THRESHOLD_PERCENT
        let compactionTokenLimit = info.compactionAtTokens?.resolve(
            contextWindow: info.contextWindow,
            thresholdPercent: compactionThreshold
        )
        let compactionBudget = resolveCompactionBudget(
            contextWindow: info.contextWindow,
            defaultThresholdPercent: compactionThreshold,
            explicitTokenLimit: compactionTokenLimit
        )
        return ProviderRoute(
            modelID: resolvedID,
            model: info.model,
            provider: info.provider,
            profile: profile,
            authScope: binding.scope,
            authKind: authKind,
            hasUsableCredential: binding.hasUsableCredential,
            toolSurface: surface,
            compactionBudget: compactionBudget,
            samplingConfig: samplingConfig,
            canExportToXAI: profile.allowsXaiServices && !everUsedNonXAI,
            credentialProvider: binding.credentialProvider
        )
    }

    private static func enabledCapabilities(
        mode: ToolMode,
        profile: ProviderProfile,
        requested: Set<ProviderToolCapability>,
        everUsedNonXAI: Bool
    ) -> Set<ProviderToolCapability> {
        var enabled: Set<ProviderToolCapability> = []
        if mode != .codeModeOnly { enabled.insert(.directTools) }
        if mode == .codeMode || mode == .codeModeOnly {
            enabled.insert(.codeMode)
            if mode == .codeModeOnly { enabled.insert(.codeModeOnly) }
        }
        if profile.nativeWebSearch && (requested.contains(.hostedWebSearch) || requested.isEmpty) {
            enabled.insert(.hostedWebSearch)
        }
        if profile.hostedToolDialect != nil && requested.contains(.imageInput) {
            enabled.insert(.imageInput)
        }
        if mode != .codeModeOnly && requested.contains(.remoteMCP) {
            enabled.insert(.remoteMCP)
        }
        if profile.allowsXaiServices && !everUsedNonXAI && requested.contains(.xaiServices) {
            enabled.insert(.xaiServices)
        }
        return enabled
    }

    private static func defaultAuxiliaryModelID(for role: ProviderAuxiliaryRole) -> String {
        switch role {
        case .webSearch: return defaultModel(for: .webSearch)
        case .imageDescription: return defaultModel(for: .imageDescription)
        case .sessionSummary, .recap: return defaultModel(for: .sessionSummary)
        case .compaction: return DEFAULT_COMPACTION_MODEL_NAME
        }
    }

    private static func isValidSessionID(_ id: String) -> Bool {
        guard !id.isEmpty, id != ".", id != ".." else { return false }
        return id.unicodeScalars.allSatisfy { scalar in
            let value = scalar.value
            return (65...90).contains(value)
                || (97...122).contains(value)
                || (48...57).contains(value)
                || value == 95
                || value == 45
        }
    }
}

private func normalizedCostTicks(_ value: Int64?) -> Int64? {
    guard let value, value > 0 else { return nil }
    return value
}

private func mergeUsageTotals(_ lhs: UsageTotals, _ rhs: UsageTotals) -> UsageTotals {
    let (input, inputOverflow) = lhs.inputTokens.addingReportingOverflow(rhs.inputTokens)
    let (output, outputOverflow) = lhs.outputTokens.addingReportingOverflow(rhs.outputTokens)
    let (cached, cachedOverflow) = lhs.cachedReadTokens.addingReportingOverflow(rhs.cachedReadTokens)
    let (reasoning, reasoningOverflow) = lhs.reasoningTokens.addingReportingOverflow(rhs.reasoningTokens)
    let (calls, callsOverflow) = lhs.modelCalls.addingReportingOverflow(rhs.modelCalls)
    let (duration, durationOverflow) = lhs.apiDurationMs.addingReportingOverflow(rhs.apiDurationMs)
    let (missing, missingOverflow) = lhs.costMissingCalls.addingReportingOverflow(rhs.costMissingCalls)
    let cost: Int64?
    switch (lhs.costUsdTicks, rhs.costUsdTicks) {
    case (nil, nil): cost = nil
    default:
        let (sum, overflow) = (lhs.costUsdTicks ?? 0).addingReportingOverflow(rhs.costUsdTicks ?? 0)
        cost = overflow ? Int64.max : sum
    }
    return UsageTotals(
        inputTokens: inputOverflow ? UInt64.max : input,
        outputTokens: outputOverflow ? UInt64.max : output,
        cachedReadTokens: cachedOverflow ? UInt64.max : cached,
        reasoningTokens: reasoningOverflow ? UInt64.max : reasoning,
        modelCalls: callsOverflow ? UInt64.max : calls,
        apiDurationMs: durationOverflow ? UInt64.max : duration,
        costUsdTicks: cost,
        costMissingCalls: missingOverflow ? UInt64.max : missing
    )
}

private final class ProviderBearerResolver: BearerResolver, @unchecked Sendable {
    private let source: any AuthCredentialProvider
    private let sendsXGrokHeaders: Bool

    init(source: any AuthCredentialProvider, sendsXGrokHeaders: Bool) {
        self.source = source
        self.sendsXGrokHeaders = sendsXGrokHeaders
    }

    func currentBearer() -> String? {
        source.snapshot().token
    }

    func currentAuth() -> ResolvedBearerAuth? {
        let snapshot = source.snapshot()
        guard let token = snapshot.token else { return nil }
        let extraHeaders: [(name: String, value: String)]
        if sendsXGrokHeaders && source.needsTokenAuthHeader() {
            extraHeaders = [(name: xaiTokenAuthHeader, value: xaiTokenAuthValue)]
        } else {
            extraHeaders = []
        }
        return ResolvedBearerAuth(bearer: token, extraHeaders: extraHeaders)
    }

    var reservedHeaders: [String] {
        sendsXGrokHeaders ? [xaiTokenAuthHeader] : []
    }

    var failClosedOnMissing: Bool { true }
}
