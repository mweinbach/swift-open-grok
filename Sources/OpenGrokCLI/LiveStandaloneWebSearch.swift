import Foundation
import OpenGrokAuth
import OpenGrokHTTP
import OpenGrokProviderSession
import OpenGrokSampler
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRegistry
import OpenGrokToolRuntime

protocol LiveStandaloneWebSearchBackend: Sendable {
    func search(commands: JSONValue) async throws -> String
}

enum LiveStandaloneWebSearchError: Error, Sendable, Equatable, CustomStringConvertible {
    case unavailable
    case sessionIdentityChanged

    var description: String {
        switch self {
        case .unavailable:
            return "standalone web search has no authenticated Codex backend for this session"
        case .sessionIdentityChanged:
            return "standalone web search cannot cross session or provider boundaries"
        }
    }
}

enum LiveStandaloneWebSearchComposition {
    static let assistantContextTokenLimit = 1_000
    static let defaultOutputTokenBudget: UInt64 = 10_000

    /// Rust `session/agent_rebuild.rs:137-146`; OAuth identity is checked in
    /// addition to provider spelling so a named/API-key route cannot opt in.
    static func isEnabled(
        disableWebSearch: Bool,
        provider: ModelProvider,
        apiBackend: ApiBackend,
        authKind: BuiltInSessionAuthKind,
        supportsStandaloneWebSearch: Bool,
        searchSource: LiveWebSearchSource,
        backendAvailable: Bool = true
    ) -> Bool {
        !disableWebSearch
            && provider == .codex
            && apiBackend == .responses
            && authKind == .codexOAuth
            && supportsStandaloneWebSearch
            && searchSource == .native
            && backendAvailable
    }

    static func makeBackend(
        configuration: OpenGrokLiveSamplingConfiguration,
        credential: LiveResolvedCredential,
        conversationHistory: LiveConversationHistory,
        sessionID: String,
        availability: LiveWebToolAvailability,
        disableWebSearch: Bool,
        supportsStandaloneWebSearch: Bool
    ) throws -> SamplerStandaloneWebSearchBackend? {
        guard isEnabled(
            disableWebSearch: disableWebSearch,
            provider: configuration.provider,
            apiBackend: configuration.apiBackend,
            authKind: credential.authKind,
            supportsStandaloneWebSearch: supportsStandaloneWebSearch,
            searchSource: availability.searchSource,
            backendAvailable: credential.provider == configuration.provider
                && configuration.credentialProvider != nil
        ) else {
            return nil
        }

        guard let credentialProvider = configuration.credentialProvider else {
            return nil
        }
        let resolver = configuration.bearerResolver
            ?? CredentialBearerResolver(provider: credentialProvider)
        let transport = AuthRetryTransport(
            transport: configuration.transport ?? URLSessionHTTPTransport(),
            credentials: credentialProvider,
            maxRetries: 1
        )
        let samplerConfig = SamplerConfig(
            apiKey: configuration.apiKey,
            baseURL: configuration.baseURL,
            model: configuration.model,
            apiBackend: configuration.apiBackend,
            provider: configuration.provider,
            extraHeaders: configuration.extraHeaders
                .sorted { $0.key < $1.key }
                .map { (name: $0.key, value: $0.value) },
            queryParams: configuration.queryParams,
            envHTTPHeaders: configuration.envHTTPHeaders,
            contextWindow: configuration.tuning.contextWindow ?? 0,
            maxRetries: configuration.tuning.maxRetries,
            idleTimeoutSecs: configuration.tuning.inferenceIdleTimeoutSecs,
            reasoningEffort: configuration.tuning.reasoningEffort,
            serviceTier: configuration.tuning.serviceTier,
            reasoningSummary: configuration.tuning.reasoningSummary,
            supportsBackendSearch: configuration.tuning.supportsBackendSearch,
            supportsStandaloneWebSearch: supportsStandaloneWebSearch,
            codexMultiAgentV2: configuration.tuning.codexMultiAgentV2,
            codexPermissions: configuration.codexPermissions,
            doomLoopRecovery: configuration.doomLoopRecovery,
            bearerResolver: resolver
        )
        return try SamplerStandaloneWebSearchBackend(
            configuration: samplerConfig,
            conversationHistory: conversationHistory,
            sessionID: sessionID,
            transport: transport
        )
    }

    /// The two most recent genuine user turns plus intervening assistant text.
    /// Synthetic reminders, systems, tools, reasoning, and trailing assistants
    /// cannot leak into a provider-authenticated external search request.
    static func requestInput(from conversation: [ConversationItem]) -> StandaloneSearchInput? {
        var visible: [(Role, String)] = []
        var userIndices: [Int] = []

        for item in conversation {
            let text = item.textContent()
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            switch item {
            case .user(let user) where user.syntheticReason == nil:
                userIndices.append(visible.count)
                visible.append((.user, text))
            case .assistant:
                visible.append((.assistant, text))
            default:
                continue
            }
        }

        guard let lastUserIndex = userIndices.last else { return nil }
        let firstUserIndex = userIndices.dropLast().last ?? lastUserIndex
        var assistantTokensRemaining = assistantContextTokenLimit
        var messages: [StandaloneSearchMessage] = []

        for (role, text) in visible[firstUserIndex...lastUserIndex] {
            switch role {
            case .user:
                messages.append(.user(text))
            case .assistant where assistantTokensRemaining > 0:
                let tokens = approximateTokenCount(text)
                if tokens <= assistantTokensRemaining {
                    assistantTokensRemaining -= tokens
                    messages.append(.assistant(text))
                } else {
                    messages.append(.assistant(truncateMiddle(
                        text,
                        tokenBudget: assistantTokensRemaining
                    )))
                    assistantTokensRemaining = 0
                }
            default:
                continue
            }
        }

        return .items(messages)
    }

    static func approximateTokenCount(_ text: String) -> Int {
        let bytes = text.utf8.count
        return bytes / 4 + (bytes.isMultiple(of: 4) ? 0 : 1)
    }

    static func truncateMiddle(_ text: String, tokenBudget: Int) -> String {
        guard !text.isEmpty else { return "" }
        let maxBytes = max(0, tokenBudget) * 4
        guard maxBytes > 0 else {
            return "…\(approximateTokenCount(text)) tokens truncated…"
        }
        guard text.utf8.count > maxBytes else { return text }

        let prefix = utf8Prefix(text, budget: maxBytes / 2)
        let suffix = utf8Suffix(text, budget: maxBytes - maxBytes / 2)
        let removedBytes = text.utf8.count - maxBytes
        let removedTokens = removedBytes / 4 + (removedBytes.isMultiple(of: 4) ? 0 : 1)
        return "\(prefix)…\(removedTokens) tokens truncated…\(suffix)"
    }

    private static func utf8Prefix(_ text: String, budget: Int) -> String {
        var remaining = budget
        var output = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let width = String(scalar).utf8.count
            guard width <= remaining else { break }
            output.append(scalar)
            remaining -= width
        }
        return String(output)
    }

    private static func utf8Suffix(_ text: String, budget: Int) -> String {
        var remaining = budget
        var scalars: [Unicode.Scalar] = []
        for scalar in text.unicodeScalars.reversed() {
            let width = String(scalar).utf8.count
            guard width <= remaining else { break }
            scalars.append(scalar)
            remaining -= width
        }
        var output = String.UnicodeScalarView()
        for scalar in scalars.reversed() {
            output.append(scalar)
        }
        return String(output)
    }
}

struct SamplerStandaloneWebSearchBackend: LiveStandaloneWebSearchBackend {
    let client: SamplingClient
    let conversationHistory: LiveConversationHistory
    let sessionID: String
    let model: String

    init(
        configuration: SamplerConfig,
        conversationHistory: LiveConversationHistory,
        sessionID: String,
        transport: any HTTPTransport = URLSessionHTTPTransport()
    ) throws {
        guard configuration.provider == .codex,
              configuration.apiBackend == .responses,
              configuration.supportsStandaloneWebSearch
        else {
            throw LiveStandaloneWebSearchError.unavailable
        }
        self.client = try SamplingClient(config: configuration, transport: transport)
        self.conversationHistory = conversationHistory
        self.sessionID = sessionID
        self.model = configuration.model
    }

    init(
        client: SamplingClient,
        conversationHistory: LiveConversationHistory,
        sessionID: String,
        model: String
    ) throws {
        guard client.provider == .codex,
              client.apiBackend == .responses,
              client.supportsStandaloneWebSearch
        else {
            throw LiveStandaloneWebSearchError.unavailable
        }
        self.client = client
        self.conversationHistory = conversationHistory
        self.sessionID = sessionID
        self.model = model
    }

    func buildRequest(commands: JSONValue) async throws -> StandaloneSearchRequest {
        let snapshot = await conversationHistory.snapshot()
        guard snapshot.sessionID == sessionID,
              snapshot.currentProvider == nil || snapshot.currentProvider == .codex
        else {
            throw LiveStandaloneWebSearchError.sessionIdentityChanged
        }
        return StandaloneSearchRequest(
            id: sessionID,
            model: snapshot.currentModelID ?? model,
            input: LiveStandaloneWebSearchComposition.requestInput(from: snapshot.items),
            commands: commands,
            settings: .directWithExternalWebAccess(),
            maxOutputTokens: LiveStandaloneWebSearchComposition.defaultOutputTokenBudget
        )
    }

    func search(commands: JSONValue) async throws -> String {
        let request = try await buildRequest(commands: commands)
        return try await client.standaloneWebSearch(request).output
    }
}

struct LiveStandaloneWebSearchHandler: ToolHandler {
    let backend: any LiveStandaloneWebSearchBackend

    func invoke(
        clientName: String,
        args: JSONValue,
        ctx: ToolCallContext,
        resources: ToolResources
    ) async -> Result<TypedToolOutput, ToolError> {
        guard clientName == "web__run",
              let toolID = try? ToolId(clientName)
        else {
            return .failure(.invalidArguments("standalone web search tool name is invalid"))
        }
        guard case .object(let commands) = args else {
            return .failure(.invalidArguments("web__run requires a JSON object"))
        }
        guard !containsNull(args) else {
            return .failure(.invalidArguments(
                "web__run arguments cannot contain null; omit absent fields instead"
            ))
        }
        if case .array(let queries)? = commands["search_query"], queries.count > 4 {
            return .failure(.invalidArguments(
                "web__run accepts at most four search_query entries per call"
            ))
        }

        do {
            let output = try await backend.search(commands: args)
            return .success(TypedToolOutput(
                toolId: toolID,
                value: .object(["output": .string(output)]),
                modelOutput: [.text(text: output)]
            ))
        } catch {
            return .failure(.custom(
                code: "standalone_web_search_failed",
                detail: String(describing: error)
            ))
        }
    }

    private func containsNull(_ value: JSONValue) -> Bool {
        switch value {
        case .null:
            return true
        case .array(let values):
            return values.contains(where: containsNull)
        case .object(let values):
            return values.values.contains(where: containsNull)
        default:
            return false
        }
    }
}
