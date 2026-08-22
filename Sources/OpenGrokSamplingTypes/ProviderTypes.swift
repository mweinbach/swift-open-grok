// ProviderTypes.swift
//
// Open Grok — Swift port of the provider/backend/dialect/profile types in
// `crates/codegen/xai-grok-sampling-types/src/types.rs`.
//
// These are the provider-neutral contracts that downstream slices (sampler,
// auth, models, session) consume. They are pure data: no I/O, no HTTP, no
// credentials. The provider identity is explicit (not inferred from a model
// slug) so credential resolution and hosted-tool filtering can branch on it.

import Foundation
import OpenGrokShared

// MARK: - ApiBackend

/// Which API backend to use for model inference.
///
/// Wire form: `snake_case` (`"chat_completions"`, `"responses"`, `"messages"`),
/// matching the Rust `#[serde(rename_all = "snake_case")]` contract.
public enum ApiBackend: String, Codable, Sendable, Equatable, Hashable, Defaultable {
    /// Use the Chat Completions API (/v1/chat/completions).
    case chatCompletions
    /// Use the Responses API (/v1/responses).
    case responses
    /// Use the Anthropic Messages API (/v1/messages).
    case messages

    public static let defaultValue: ApiBackend = .chatCompletions

    /// Whether the backend enforces a response JSON schema natively alongside
    /// tool calls. The Messages API does not (a schema there blocks tool use),
    /// so structured output there goes through the StructuredOutput tool.
    public var supportsNativeSchema: Bool {
        switch self {
        case .chatCompletions, .responses: return true
        case .messages: return false
        }
    }
}

// MARK: - ModelProvider

/// First-party provider contract selected by a model catalog entry.
///
/// Wire form: `snake_case`. Accepts the listed aliases on decode so configs
/// written against upstream names (`"openai"`, `"moonshot"`, `"fireworks_ai"`)
/// round-trip cleanly.
public enum ModelProvider: String, Codable, Sendable, Equatable, Hashable, Defaultable {
    case xai
    case codex
    case kimi
    case fireworks
    case deepseek
    case meta
    case openCodeGo
    case wafer
    case zai
    case runinfra
    case gemini
    case openRouter = "openrouter"

    public static let defaultValue: ModelProvider = .xai

    public enum CodingKeys: String, CodingKey {
        case xai, codex, kimi, fireworks, deepseek, meta, wafer, zai, runinfra, gemini
        case openCodeGo = "opencode_go"
        case openRouter = "openrouter"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw.lowercased() {
        case "xai": self = .xai
        case "codex", "openai", "openai_codex": self = .codex
        case "kimi", "moonshot", "moonshot_ai": self = .kimi
        case "fireworks", "fireworks_ai": self = .fireworks
        case "deepseek", "deep_seek", "deepseek_api": self = .deepseek
        case "meta", "meta_ai", "meta_api": self = .meta
        case "opencode_go", "opencode-go": self = .openCodeGo
        case "wafer", "wafer_ai": self = .wafer
        case "zai", "z_ai", "z-ai", "zai_api", "glm": self = .zai
        case "runinfra", "run_infra", "run-infra": self = .runinfra
        case "gemini", "google", "google_gemini", "ai_studio", "aistudio", "gemini_api":
            self = .gemini
        case "openrouter", "open_router", "open-router": self = .openRouter
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unknown ModelProvider: \(raw)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(asString)
    }

    /// Stable provider identifier used in configuration and persistence.
    public var asString: String {
        switch self {
        case .xai: return "xai"
        case .codex: return "codex"
        case .kimi: return "kimi"
        case .fireworks: return "fireworks"
        case .deepseek: return "deepseek"
        case .meta: return "meta"
        case .openCodeGo: return "opencode_go"
        case .wafer: return "wafer"
        case .zai: return "zai"
        case .runinfra: return "runinfra"
        case .gemini: return "gemini"
        case .openRouter: return "openrouter"
        }
    }

    /// Human-readable provider name for UI and diagnostics.
    public var name: String {
        switch self {
        case .xai: return "xAI"
        case .codex: return "OpenAI Codex"
        case .kimi: return "Kimi"
        case .fireworks: return "Fireworks AI"
        case .deepseek: return "DeepSeek"
        case .meta: return "Meta API"
        case .openCodeGo: return "OpenCode Go"
        case .wafer: return "Wafer AI"
        case .zai: return "Z AI"
        case .runinfra: return "RunInfra"
        case .gemini: return "Google Gemini"
        case .openRouter: return "OpenRouter"
        }
    }

    public var isXai: Bool { self == .xai }
    public var isCodex: Bool { self == .codex }
    public var isKimi: Bool { self == .kimi }
    public var isFireworks: Bool { self == .fireworks }
    public var isDeepSeek: Bool { self == .deepseek }
    public var isMeta: Bool { self == .meta }
    public var isOpenCodeGo: Bool { self == .openCodeGo }
    public var isWafer: Bool { self == .wafer }
    public var isZai: Bool { self == .zai }
    public var isRuninfra: Bool { self == .runinfra }
    public var isGemini: Bool { self == .gemini }
    public var isOpenRouter: Bool { self == .openRouter }

    /// Return the built-in provider's complete behavior policy.
    public var profile: ProviderProfile {
        switch self {
        case .xai: return .xai
        case .codex: return .codex
        case .kimi: return .kimi
        case .fireworks: return .fireworks
        case .deepseek: return .deepseek
        case .meta: return .meta
        case .openCodeGo: return .openCodeGo
        case .wafer: return .wafer
        case .zai: return .zai
        case .runinfra: return .runinfra
        case .gemini: return .gemini
        case .openRouter: return .openRouter
        }
    }
}

// MARK: - ResponsesDialect

/// Provider-specific wire contract used by the Responses API.
///
/// This remains separate from `ApiBackend`: both built-in providers use the
/// Responses endpoint, but they require different request and replay shapes.
public enum ResponsesDialect: String, Codable, Sendable, Equatable, Hashable {
    case xai
    case codex
    /// DeepSeek's native OpenAI-compatible Responses API (V4 Flash and later).
    /// Stateless (`store: false`), with DeepSeek-owned reasoning-effort mapping.
    case deepSeek = "deepseek"
    /// Meta Model API's OpenAI-compatible, stateless Responses contract.
    case meta

    public var asString: String {
        switch self {
        case .xai: return "xai"
        case .codex: return "codex"
        case .deepSeek: return "deepseek"
        case .meta: return "meta"
        }
    }

    public var isXai: Bool { self == .xai }
    public var isCodex: Bool { self == .codex }
    public var isDeepSeek: Bool { self == .deepSeek }
    public var isMeta: Bool { self == .meta }
}

// MARK: - HostedToolDialect

/// Hosted-tool schema accepted by the selected provider.
///
/// `openAi` is intentionally broader than the built-in Codex provider: a
/// future provider may share OpenAI's hosted-tool wire contract without using
/// the Codex Responses dialect or Codex session authentication.
public enum HostedToolDialect: String, Codable, Sendable, Equatable, Hashable {
    case xai
    case openAi

    public enum CodingKeys: String, CodingKey {
        case xai
        // Rust serializes OpenAi as "open_ai".
        case openAi = "open_ai"
    }

    public var asString: String {
        switch self {
        case .xai: return "xai"
        case .openAi: return "open_ai"
        }
    }

    public var isXai: Bool { self == .xai }
    public var isOpenAi: Bool { self == .openAi }
}

// MARK: - CodeModeTransport

/// Wire representation used for Code Mode's client-executed `exec` tool.
public enum CodeModeTransport: String, Codable, Sendable, Equatable, Hashable {
    case nativeCustomGrammar
    case functionEnvelope
    case unsupported
}

// MARK: - RequestMetadataPolicy

/// Policy for provider-private request metadata and identity headers.
public enum RequestMetadataPolicy: String, Codable, Sendable, Equatable, Hashable {
    case xGrokHeaders
    case standardHeadersOnly

    public enum CodingKeys: String, CodingKey {
        case xGrokHeaders = "x_grok_headers"
        case standardHeadersOnly = "standard_headers_only"
    }

    public var asString: String {
        switch self {
        case .xGrokHeaders: return "x_grok_headers"
        case .standardHeadersOnly: return "standard_headers_only"
        }
    }

    public var sendsXGrokHeaders: Bool { self == .xGrokHeaders }
}

// MARK: - BuiltInSessionAuthKind

/// Built-in session credential source associated with a provider.
public enum BuiltInSessionAuthKind: String, Codable, Sendable, Equatable, Hashable {
    case apiKeyOnly
    case xaiSession
    case codexOAuth

    public enum CodingKeys: String, CodingKey {
        case apiKeyOnly = "api_key_only"
        case xaiSession = "xai_session"
        case codexOAuth = "codex_oauth"
    }

    public var asString: String {
        switch self {
        case .apiKeyOnly: return "api_key_only"
        case .xaiSession: return "xai_session"
        case .codexOAuth: return "codex_oauth"
        }
    }

    public var isApiKeyOnly: Bool { self == .apiKeyOnly }
    public var isXai: Bool { self == .xaiSession }
    public var isCodex: Bool { self == .codexOAuth }
}

// MARK: - XaiServicePolicy

/// Whether data from this provider may enter xAI-only export and service
/// paths such as feedback, persistence relay, and trace upload.
public enum XaiServicePolicy: String, Codable, Sendable, Equatable, Hashable {
    case allowed
    case denied

    public var allows: Bool { self == .allowed }
}

// MARK: - ProviderBackends

/// Wire protocols accepted by one provider.
public struct ProviderBackends: Codable, Sendable, Equatable, Hashable {
    public let chatCompletions: Bool
    public let responses: ResponsesDialect?
    public let messages: Bool

    public init(chatCompletions: Bool, responses: ResponsesDialect?, messages: Bool) {
        self.chatCompletions = chatCompletions
        self.responses = responses
        self.messages = messages
    }

    public func supports(_ backend: ApiBackend) -> Bool {
        switch backend {
        case .chatCompletions: return chatCompletions
        case .responses: return responses != nil
        case .messages: return messages
        }
    }

    public enum CodingKeys: String, CodingKey {
        case chatCompletions = "chat_completions"
        case responses
        case messages
    }
}

// MARK: - ProviderProfile

/// Complete behavior policy for one built-in model provider.
public struct ProviderProfile: Codable, Sendable, Equatable, Hashable {
    public let provider: ModelProvider
    public let backends: ProviderBackends
    public let codeModeTransport: CodeModeTransport
    public let hostedToolDialect: HostedToolDialect?
    public let nativeWebSearch: Bool
    public let requestMetadata: RequestMetadataPolicy
    public let sessionAuth: BuiltInSessionAuthKind
    public let xaiServices: XaiServicePolicy

    public init(
        provider: ModelProvider,
        backends: ProviderBackends,
        codeModeTransport: CodeModeTransport,
        hostedToolDialect: HostedToolDialect?,
        nativeWebSearch: Bool,
        requestMetadata: RequestMetadataPolicy,
        sessionAuth: BuiltInSessionAuthKind,
        xaiServices: XaiServicePolicy
    ) {
        self.provider = provider
        self.backends = backends
        self.codeModeTransport = codeModeTransport
        self.hostedToolDialect = hostedToolDialect
        self.nativeWebSearch = nativeWebSearch
        self.requestMetadata = requestMetadata
        self.sessionAuth = sessionAuth
        self.xaiServices = xaiServices
    }

    public var id: String { provider.asString }
    public var name: String { provider.name }
    public var isXai: Bool { provider.isXai }
    public var isCodex: Bool { provider.isCodex }
    public var isKimi: Bool { provider.isKimi }
    public var isFireworks: Bool { provider.isFireworks }
    public var isDeepSeek: Bool { provider.isDeepSeek }
    public var isMeta: Bool { provider.isMeta }
    public var isOpenCodeGo: Bool { provider.isOpenCodeGo }
    public var isWafer: Bool { provider.isWafer }
    public var isZai: Bool { provider.isZai }
    public var isRuninfra: Bool { provider.isRuninfra }
    public var isGemini: Bool { provider.isGemini }
    public var isOpenRouter: Bool { provider.isOpenRouter }
    public var allowsXaiServices: Bool { xaiServices.allows }
    public var hasNativeWebSearch: Bool { nativeWebSearch }
    public var responsesDialect: ResponsesDialect? { backends.responses }

    public func supportsBackend(_ backend: ApiBackend) -> Bool {
        backends.supports(backend)
    }

    // MARK: Built-in profiles (mirror Rust `ProviderProfile::XAI` etc.)

    public static let xai = ProviderProfile(
        provider: .xai,
        backends: ProviderBackends(chatCompletions: true, responses: .xai, messages: true),
        codeModeTransport: .functionEnvelope,
        hostedToolDialect: .xai,
        nativeWebSearch: true,
        requestMetadata: .xGrokHeaders,
        sessionAuth: .xaiSession,
        xaiServices: .allowed
    )

    public static let codex = ProviderProfile(
        provider: .codex,
        backends: ProviderBackends(chatCompletions: false, responses: .codex, messages: false),
        codeModeTransport: .nativeCustomGrammar,
        hostedToolDialect: .openAi,
        nativeWebSearch: true,
        requestMetadata: .standardHeadersOnly,
        sessionAuth: .codexOAuth,
        xaiServices: .denied
    )

    public static let kimi = ProviderProfile(
        provider: .kimi,
        backends: ProviderBackends(chatCompletions: true, responses: nil, messages: false),
        codeModeTransport: .unsupported,
        hostedToolDialect: nil,
        nativeWebSearch: false,
        requestMetadata: .standardHeadersOnly,
        sessionAuth: .apiKeyOnly,
        xaiServices: .denied
    )

    public static let fireworks = ProviderProfile(
        provider: .fireworks,
        backends: ProviderBackends(chatCompletions: true, responses: nil, messages: false),
        codeModeTransport: .unsupported,
        hostedToolDialect: nil,
        nativeWebSearch: false,
        requestMetadata: .standardHeadersOnly,
        sessionAuth: .apiKeyOnly,
        xaiServices: .denied
    )

    /// DeepSeek's direct OpenAI-compatible inference API. V4 Flash supports
    /// both Chat Completions and the stateless Responses API, including
    /// OpenAI-shaped hosted web search. Authentication remains isolated to a
    /// provider-owned API key.
    public static let deepseek = ProviderProfile(
        provider: .deepseek,
        backends: ProviderBackends(chatCompletions: true, responses: .deepSeek, messages: false),
        codeModeTransport: .functionEnvelope,
        hostedToolDialect: .openAi,
        nativeWebSearch: true,
        requestMetadata: .standardHeadersOnly,
        sessionAuth: .apiKeyOnly,
        xaiServices: .denied
    )

    /// Meta's OpenAI-compatible Responses API. Muse Spark models use standard
    /// function calls and OpenAI-shaped hosted web search with provider-local
    /// API-key authentication.
    public static let meta = ProviderProfile(
        provider: .meta,
        backends: ProviderBackends(chatCompletions: false, responses: .meta, messages: false),
        codeModeTransport: .functionEnvelope,
        hostedToolDialect: .openAi,
        nativeWebSearch: true,
        requestMetadata: .standardHeadersOnly,
        sessionAuth: .apiKeyOnly,
        xaiServices: .denied
    )

    /// OpenCode Go routes individual models over either OpenAI-compatible Chat
    /// Completions or Anthropic Messages while sharing one provider API key.
    public static let openCodeGo = ProviderProfile(
        provider: .openCodeGo,
        backends: ProviderBackends(chatCompletions: true, responses: nil, messages: true),
        codeModeTransport: .unsupported,
        hostedToolDialect: nil,
        nativeWebSearch: false,
        requestMetadata: .standardHeadersOnly,
        sessionAuth: .apiKeyOnly,
        xaiServices: .denied
    )

    /// Wafer AI's OpenAI-compatible Chat Completions API. Wafer supports
    /// ordinary client-side function tools but does not provide hosted tools,
    /// web search, Responses, or provider-managed OAuth authentication.
    public static let wafer = ProviderProfile(
        provider: .wafer,
        backends: ProviderBackends(chatCompletions: true, responses: nil, messages: false),
        codeModeTransport: .unsupported,
        hostedToolDialect: nil,
        nativeWebSearch: false,
        requestMetadata: .standardHeadersOnly,
        sessionAuth: .apiKeyOnly,
        xaiServices: .denied
    )

    /// Z AI's OpenAI-compatible Chat Completions API (GLM Coding Plan
    /// endpoint by default). Z AI supports ordinary client-side function
    /// tools and per-model reasoning ("thinking mode"), but does not provide
    /// hosted tools, web search, Responses, or provider-managed OAuth.
    public static let zai = ProviderProfile(
        provider: .zai,
        backends: ProviderBackends(chatCompletions: true, responses: nil, messages: false),
        codeModeTransport: .unsupported,
        hostedToolDialect: nil,
        nativeWebSearch: false,
        requestMetadata: .standardHeadersOnly,
        sessionAuth: .apiKeyOnly,
        xaiServices: .denied
    )

    /// RunInfra's hosted models accept ordinary Chat Completions function
    /// tools. Its `/v1/responses` compatibility adapter is not a first-class
    /// Responses dialect and must not expose provider-hosted tools.
    public static let runinfra = ProviderProfile(
        provider: .runinfra,
        backends: ProviderBackends(chatCompletions: true, responses: nil, messages: false),
        codeModeTransport: .unsupported,
        hostedToolDialect: nil,
        nativeWebSearch: false,
        requestMetadata: .standardHeadersOnly,
        sessionAuth: .apiKeyOnly,
        xaiServices: .denied
    )

    /// Google Gemini / AI Studio exposes only its OpenAI-compatible Chat
    /// Completions surface here; native Gemini tools and auth are separate.
    public static let gemini = ProviderProfile(
        provider: .gemini,
        backends: ProviderBackends(chatCompletions: true, responses: nil, messages: false),
        codeModeTransport: .unsupported,
        hostedToolDialect: nil,
        nativeWebSearch: false,
        requestMetadata: .standardHeadersOnly,
        sessionAuth: .apiKeyOnly,
        xaiServices: .denied
    )

    /// OpenRouter's explicitly enabled catalog uses provider-owned API keys
    /// and Chat Completions, never hosted search, Responses, or xAI exports.
    public static let openRouter = ProviderProfile(
        provider: .openRouter,
        backends: ProviderBackends(chatCompletions: true, responses: nil, messages: false),
        codeModeTransport: .unsupported,
        hostedToolDialect: nil,
        nativeWebSearch: false,
        requestMetadata: .standardHeadersOnly,
        sessionAuth: .apiKeyOnly,
        xaiServices: .denied
    )
}

// MARK: - Defaultable helper

/// A type with a canonical default value, mirroring Rust `#[derive(Default)]`
/// for enums that carry `#[default]` on one variant.
public protocol Defaultable {
    static var defaultValue: Self { get }
}
