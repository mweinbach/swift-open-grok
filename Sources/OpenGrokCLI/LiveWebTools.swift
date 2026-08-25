// LiveWebTools.swift
//
// Session wiring for `web_search`, `web_fetch` and `x_search`.
//
// `OpenGrokWebMediaTools` has carried finished clients for all three since W5-S2
// — `WebSearchClient`, `WebFetchClient` (with its own SSRF guard) — but nothing
// registered a handler, so the model was never offered any of them. On a
// non-xAI session that meant no search capability at all: Kimi, Fireworks,
// OpenCode Go and Wafer have no native hosted search to fall back on.
//
// This file mirrors `LiveImageTools.swift` exactly: availability is resolved
// from credentials first, and only an available tool is advertised. The
// registry knowing a tool and a session offering it stay separate decisions.
//
// Ports:
//   * `WebSearchToolConfigs::resolved_config_for`
//     (`xai-grok-shell/src/tools/config.rs:553-586`) — per-provider backend
//     selection, including the Perplexity fallback.
//   * `WebSearchSourceTarget::effective_source_for` (`config.rs:516-540`) —
//     the legacy Perplexity toggle is a Kimi-only alias; every other
//     non-Codex provider needs an explicit Perplexity selection.
//   * The `--disable-web-search` master kill switch.

import Foundation
import OpenGrokAuth
import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokHTTP
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRegistry
import OpenGrokToolRuntime
import OpenGrokWebMediaTools

// MARK: - Source selection

/// Which backend serves `web_search` for a session.
enum LiveWebSearchSource: String, Sendable, Equatable {
    /// The provider declares hosted search server-side; no client tool.
    case native
    case xai
    case perplexity

    static func fromCanonical(_ value: String) -> LiveWebSearchSource? {
        LiveWebSearchSource(rawValue: value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

// MARK: - Availability

/// The resolved web-tool decision for one session.
struct LiveWebToolAvailability: Sendable {
    var searchConfig: WebSearchConfig
    /// Owner-configured search domain policy is authoritative over model input.
    var searchFilter: WebSearchFilter = WebSearchFilter()
    /// X search always uses the independently authenticated xAI candidate.
    var xSearchConfig: WebSearchConfig = .disabled
    /// Frozen egress policy; executor construction must not replace its params.
    var fetchConfig: WebFetchConfig = .disabled
    /// Standalone Codex search is eligible only for the native source.
    var searchSource: LiveWebSearchSource = .native
    /// Advertise `web_search`.
    var webSearchEnabled: Bool
    /// Advertise `web_fetch` only after its feature and frozen policy resolve.
    var webFetchEnabled: Bool
    /// Advertise `x_search` independently of the generic search provider.
    var xSearchEnabled: Bool

    static let unavailable = LiveWebToolAvailability(
        searchConfig: .disabled,
        webSearchEnabled: false,
        webFetchEnabled: false,
        xSearchEnabled: false
    )

    var advertisesAnything: Bool { webSearchEnabled || webFetchEnabled || xSearchEnabled }
}

/// Everything `LiveToolExecutor` needs to build the web tools.
struct LiveWebToolContext: Sendable {
    var availability: LiveWebToolAvailability
    var transport: any HTTPTransport
    /// Absent means the model cannot see or invoke provider-authenticated search.
    var standaloneWebSearchBackend: (any LiveStandaloneWebSearchBackend)? = nil
}

// MARK: - Resolution

enum LiveWebToolComposition {
    /// Resolve the session's web-tool configuration.
    ///
    /// `disableWebSearch` is upstream's hard kill switch for every web surface.
    static func resolveAvailability(
        workingDirectory: URL,
        openGrokHome: URL,
        environment: [String: String],
        samplingProvider: ModelProvider,
        samplingAPIKey: String,
        samplingBaseURL: String,
        disableWebSearch: Bool,
        samplingContextWindow: UInt64? = nil,
        effectiveConfig: TOMLValue? = nil,
        requirements: [TOMLValue] = [],
        remoteSettings: RemoteSettings? = nil
    ) -> LiveWebToolAvailability {
        guard !disableWebSearch else {
            return .unavailable
        }

        let fetchConfig = resolveFetchConfig(
            workingDirectory: workingDirectory,
            openGrokHome: openGrokHome,
            environment: environment,
            contextWindowTokens: samplingContextWindow,
            effectiveConfig: effectiveConfig,
            requirements: requirements,
            remoteSettings: remoteSettings
        )

        let xaiConfig = resolveXaiSearchConfig(
            workingDirectory: workingDirectory,
            openGrokHome: openGrokHome,
            environment: environment,
            samplingProvider: samplingProvider,
            samplingAPIKey: samplingAPIKey,
            samplingBaseURL: samplingBaseURL,
            effectiveConfig: effectiveConfig
        )
        let perplexityConfig = resolvePerplexitySearchConfig(
            openGrokHome: openGrokHome,
            environment: environment
        )

        let source = effectiveSource(
            provider: samplingProvider,
            workingDirectory: workingDirectory,
            openGrokHome: openGrokHome,
            environment: environment,
            xaiAvailable: xaiConfig.isEnabled,
            perplexityAvailable: perplexityConfig != nil,
            effectiveConfig: effectiveConfig
        )

        let searchConfig: WebSearchConfig
        switch source {
        case .native:
            // Hosted search is a server-side declaration, not a client tool.
            // Only xAI treats "native" and its client tool as the same service.
            searchConfig = samplingProvider == .xai ? xaiConfig : .disabled
        case .xai:
            searchConfig = xaiConfig
        case .perplexity:
            searchConfig = perplexityConfig ?? .disabled
        }

        return LiveWebToolAvailability(
            searchConfig: searchConfig,
            searchFilter: WebSearchFilter(
                allowedDomains: configStringArray(
                    path: ["toolset", "web_search", "allowed_domains"],
                    workingDirectory: workingDirectory,
                    openGrokHome: openGrokHome,
                    environment: environment,
                    effectiveConfig: effectiveConfig
                ),
                excludedDomains: configStringArray(
                    path: ["toolset", "web_search", "excluded_domains"],
                    workingDirectory: workingDirectory,
                    openGrokHome: openGrokHome,
                    environment: environment,
                    effectiveConfig: effectiveConfig
                )
            ),
            xSearchConfig: xaiConfig,
            fetchConfig: fetchConfig,
            searchSource: source,
            webSearchEnabled: searchConfig.isEnabled,
            webFetchEnabled: fetchConfig.isEnabled,
            xSearchEnabled: xaiConfig.isEnabled && (
                configBool(
                    path: ["toolset", "x_search", "enabled"],
                    workingDirectory: workingDirectory,
                    openGrokHome: openGrokHome,
                    environment: environment,
                    effectiveConfig: effectiveConfig
                ) ?? true
            )
        )
    }

    /// Rust `agent_ops.rs:2405-2439`: feature defaults off; empty allowlists
    /// disable the tool rather than silently restoring the built-in defaults.
    static func resolveFetchConfig(
        workingDirectory: URL,
        openGrokHome: URL,
        environment: [String: String],
        contextWindowTokens: UInt64? = nil,
        effectiveConfig: TOMLValue? = nil,
        requirements: [TOMLValue] = [],
        remoteSettings: RemoteSettings? = nil
    ) -> WebFetchConfig {
        let reviewedRemote = remoteSettings.map(AllowlistedRemoteSettings.init(projecting:))
        let requirement = requirements.first {
            $0[path: ["features", "web_fetch"]]?.boolValue != nil
        }?[path: ["features", "web_fetch"]]?.boolValue
        if requirement == nil, reviewedRemote?.webFetchEnabled == false {
            return .disabled
        }
        let enabled = requirement
            ?? boolFromEnv(environment["GROK_WEB_FETCH"])
            ?? configBool(
                path: ["features", "web_fetch"],
                workingDirectory: workingDirectory,
                openGrokHome: openGrokHome,
                environment: environment,
                effectiveConfig: effectiveConfig
            )
            ?? reviewedRemote?.webFetchEnabled
            ?? false
        guard enabled else { return .disabled }

        let root = ["toolset", "web_fetch"]
        let configuredDomains = configStringArray(
            path: root + ["allowed_domains"],
            workingDirectory: workingDirectory,
            openGrokHome: openGrokHome,
            environment: environment,
            effectiveConfig: effectiveConfig
        )
        let domains: [String]?
        if let remoteDomains = reviewedRemote?.webFetchAllowedDomains {
            guard let restrictedDomains = intersectAllowedDomains(
                configured: configuredDomains,
                remote: remoteDomains
            ), !restrictedDomains.isEmpty else {
                return .disabled
            }
            domains = restrictedDomains
        } else {
            domains = configuredDomains
        }
        guard domains?.isEmpty != true else { return .disabled }

        func integer(_ key: String) -> Int? {
            configInteger(
                path: root + [key],
                workingDirectory: workingDirectory,
                openGrokHome: openGrokHome,
                environment: environment,
                effectiveConfig: effectiveConfig
            ).flatMap(Int.init(exactly:))
        }

        func unsigned(_ key: String) -> UInt64? {
            configInteger(
                path: root + [key],
                workingDirectory: workingDirectory,
                openGrokHome: openGrokHome,
                environment: environment,
                effectiveConfig: effectiveConfig
            ).flatMap(UInt64.init(exactly:))
        }

        let localProxy = configString(
            path: root + ["proxy_endpoint"],
            workingDirectory: workingDirectory,
            openGrokHome: openGrokHome,
            environment: environment,
            effectiveConfig: effectiveConfig
        ) ?? environment["GROK_WEB_FETCH_PROXY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let remoteProxy = reviewedRemote?.webFetchProxy?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let remoteProxy {
            guard !remoteProxy.isEmpty,
                  let components = URLComponents(string: remoteProxy),
                  ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
                  components.host?.isEmpty == false,
                  components.query == nil,
                  components.fragment == nil,
                  components.path.isEmpty || components.path == "/"
            else { return .disabled }
        }
        let proxy = remoteProxy ?? localProxy
        let allowLocal = configBool(
            path: root + ["allow_local"],
            workingDirectory: workingDirectory,
            openGrokHome: openGrokHome,
            environment: environment,
            effectiveConfig: effectiveConfig
        ) ?? boolFromEnv(environment["GROK_WEB_FETCH_ALLOW_LOCAL"])

        return .enabled(params: WebFetchParams(
            cacheTTLSeconds: unsigned("cache_ttl_secs"),
            maxCacheEntries: integer("max_cache_entries"),
            timeoutSeconds: unsigned("timeout_secs"),
            maxContentLength: integer("max_content_length"),
            maxMarkdownLength: integer("max_markdown_length"),
            contextWindowTokens: contextWindowTokens ?? unsigned("context_window_tokens"),
            allowedDomains: domains,
            proxyEndpoint: proxy,
            allowLocal: allowLocal
        ))
    }

    private static func intersectAllowedDomains(
        configured: [String]?,
        remote: [String]
    ) -> [String]? {
        guard !remote.isEmpty else { return nil }

        func normalized(_ raw: String) -> (host: String, path: String, rendered: String)? {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !value.isEmpty,
                  !value.contains("\\"), !value.contains("@"),
                  !value.contains("?"), !value.contains("#"),
                  !value.contains("%"), !value.contains(":"),
                  value.unicodeScalars.allSatisfy({ $0.isASCII })
            else { return nil }
            let parts = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            var host = String(parts[0])
            if host.hasPrefix("www.") { host.removeFirst(4) }
            let labels = host.split(separator: ".", omittingEmptySubsequences: false)
            guard labels.count > 1,
                  labels.allSatisfy({ label in
                      !label.isEmpty && !label.hasPrefix("-") && !label.hasSuffix("-")
                          && label.unicodeScalars.allSatisfy {
                              ($0.value >= 97 && $0.value <= 122)
                                  || ($0.value >= 48 && $0.value <= 57)
                                  || $0.value == 45
                          }
                  })
            else { return nil }
            let path = parts.count == 2
                ? "/" + parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                : ""
            guard !path.split(separator: "/").contains("..") else { return nil }
            let canonicalPath = path == "/" ? "" : path
            return (host, canonicalPath, host + canonicalPath)
        }

        let remoteEntries = remote.compactMap(normalized)
        guard remoteEntries.count == remote.count else { return nil }
        guard let configured else {
            return Array(Set(remoteEntries.map { $0.rendered })).sorted()
        }
        let configuredEntries = configured.compactMap(normalized)
        guard configuredEntries.count == configured.count else { return nil }

        var intersections = Set<String>()
        for local in configuredEntries {
            for authoritative in remoteEntries {
                let host: String
                if local.host == authoritative.host || local.host.hasSuffix(".\(authoritative.host)") {
                    host = local.host
                } else if authoritative.host.hasSuffix(".\(local.host)") {
                    host = authoritative.host
                } else {
                    continue
                }

                let path: String
                if local.path.isEmpty || authoritative.path == local.path
                    || authoritative.path.hasPrefix(local.path + "/") {
                    path = authoritative.path
                } else if authoritative.path.isEmpty
                    || local.path.hasPrefix(authoritative.path + "/") {
                    path = local.path
                } else {
                    continue
                }
                intersections.insert(host + path)
            }
        }
        return intersections.sorted()
    }

    /// `effective_source_for` (`config.rs:516-540`).
    ///
    /// An explicit `[toolset.web_search_source]` entry wins outright. Otherwise
    /// Kimi honours the legacy Perplexity toggle, Codex keeps its own native
    /// search unless a separately configured xAI search model explicitly opts
    /// in, and every other provider defaults to xAI — Fireworks included,
    /// which is why Fireworks needs an explicit Perplexity selection rather
    /// than inheriting Kimi's.
    static func effectiveSource(
        provider: ModelProvider,
        workingDirectory: URL,
        openGrokHome: URL,
        environment: [String: String],
        xaiAvailable: Bool,
        perplexityAvailable: Bool,
        effectiveConfig: TOMLValue? = nil
    ) -> LiveWebSearchSource {
        if let explicit = explicitSource(
            provider: provider,
            workingDirectory: workingDirectory,
            openGrokHome: openGrokHome,
            environment: environment,
            effectiveConfig: effectiveConfig
        ) {
            return explicit
        }
        switch provider {
        case .kimi:
            let legacyToggle = configBool(
                path: ["toolset", "perplexity_web_search", "enabled"],
                workingDirectory: workingDirectory,
                openGrokHome: openGrokHome,
                environment: environment,
                effectiveConfig: effectiveConfig
            ) ?? false
            return legacyToggle && perplexityAvailable ? .perplexity : .xai
        case .codex:
            let configuredModel = environment["GROK_WEB_SEARCH_MODEL"]?
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? configString(
                    path: ["toolset", "web_search", "model"],
                    workingDirectory: workingDirectory,
                    openGrokHome: openGrokHome,
                    environment: environment,
                    effectiveConfig: effectiveConfig
                )
            return xaiAvailable
                && configuredModel != nil
                && configuredModel != defaultWebSearchModel
                ? .xai
                : .native
        // Meta keeps its native hosted search (`effective_source_for`,
        // tools/config.rs:540); for a non-xAI provider "native" resolves to
        // no client search tool, so Meta stays inert here.
        case .meta:
            return .native
        case .xai, .fireworks, .deepseek, .wafer, .openCodeGo, .zai,
             .runinfra, .gemini, .openRouter:
            return .xai
        }
    }

    /// `[toolset.web_search_source] <target> = "native" | "xai" | "perplexity"`.
    ///
    /// Kimi Platform and Kimi Code are one `ModelProvider` but separate
    /// services with separate credentials, so upstream keys them independently;
    /// the endpoint decides which key this session reads.
    private static func explicitSource(
        provider: ModelProvider,
        workingDirectory: URL,
        openGrokHome: URL,
        environment: [String: String],
        effectiveConfig: TOMLValue?
    ) -> LiveWebSearchSource? {
        let key: String
        switch provider {
        case .xai: key = "xai"
        case .codex: key = "codex"
        case .kimi:
            key = kimiEndpoint(environment: environment) == .code ? "kimi_code" : "kimi_platform"
        case .fireworks: key = "fireworks"
        case .deepseek: key = "deepseek"
        case .meta: key = "meta"
        case .wafer: key = "wafer"
        case .openCodeGo: key = "opencode_go"
        case .zai: key = "zai"
        case .runinfra: key = "runinfra"
        case .gemini: key = "gemini"
        case .openRouter: key = "openrouter"
        }
        guard let raw = configString(
            path: ["toolset", "web_search_source", key],
            workingDirectory: workingDirectory,
            openGrokHome: openGrokHome,
            environment: environment,
            effectiveConfig: effectiveConfig
        ) else { return nil }
        return LiveWebSearchSource.fromCanonical(raw)
    }

    private static func kimiEndpoint(environment: [String: String]) -> KimiAPIEndpoint {
        guard let raw = environment["GROK_KIMI_API_ENDPOINT"],
              let parsed = KimiAPIEndpoint.fromCanonical(raw)
        else { return .platform }
        return parsed
    }

    /// The xAI Responses-backed search config.
    ///
    /// Reuses `xaiMediaAPIKey`'s provenance rule: a session bearer is only
    /// usable here when the session's own auth is xAI, otherwise a stored xAI
    /// key is required. A Codex or Kimi token must never reach an xAI endpoint.
    static func resolveXaiSearchConfig(
        workingDirectory: URL,
        openGrokHome: URL,
        environment: [String: String],
        samplingProvider: ModelProvider,
        samplingAPIKey: String,
        samplingBaseURL: String,
        effectiveConfig: TOMLValue? = nil
    ) -> WebSearchConfig {
        guard let apiKey = LiveImageToolComposition.xaiMediaAPIKey(
            samplingProvider: samplingProvider,
            samplingAPIKey: samplingAPIKey,
            environment: environment
        ) else { return .disabled }

        let configuredBaseURL: String?
        if let effectiveConfig {
            configuredBaseURL = configString(
                path: ["endpoints", "xai_api_base_url"],
                workingDirectory: workingDirectory,
                openGrokHome: openGrokHome,
                environment: environment,
                effectiveConfig: effectiveConfig
            )
        } else {
            configuredBaseURL = OpenGrokLiveApplicationLauncher.configuredXaiAPIBaseURL(
                workingDirectory: workingDirectory,
                openGrokHome: openGrokHome,
                environment: environment
            )
        }

        let baseURL = LiveImageToolComposition.xaiMediaBaseURL(
            samplingProvider: samplingProvider,
            samplingBaseURL: samplingBaseURL,
            configuredXaiBaseURL: configuredBaseURL,
            environment: environment
        )

        let model = environment["GROK_WEB_SEARCH_MODEL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? configString(
                path: ["toolset", "web_search", "model"],
                workingDirectory: workingDirectory,
                openGrokHome: openGrokHome,
                environment: environment,
                effectiveConfig: effectiveConfig
            )
            ?? defaultWebSearchModel

        return .enabled(apiKey: apiKey, baseURL: baseURL, model: model)
    }

    /// The Perplexity fallback. Its key lives in its own credential scope
    /// (`perplexity::api_key`), never in a provider's sampling credentials.
    static func resolvePerplexitySearchConfig(
        openGrokHome: URL,
        environment: [String: String]
    ) -> WebSearchConfig? {
        let key = environment["PERPLEXITY_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? readPerplexityAPIKey(grokHome: openGrokHome)
        guard let key, !key.isEmpty else { return nil }
        return .perplexity(apiKey: key)
    }

    static let defaultWebSearchModel = "grok-4-fast-non-reasoning"

    // MARK: Flag plumbing

    private static func boolFromEnv(_ raw: String?) -> Bool? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty
        else { return nil }
        switch raw {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return nil
        }
    }

    private static func configTables(
        workingDirectory: URL,
        openGrokHome: URL,
        environment: [String: String],
        effectiveConfig: TOMLValue?
    ) -> [TOMLValue] {
        if let effectiveConfig {
            return [effectiveConfig]
        }
        // Direct fixtures predate the authoritative document; a user-owned
        // config is safe to retain, but an untrusted project must never become
        // an alternate egress-policy authority through this compatibility path.
        guard let user = try? loadConfigFile(
            at: openGrokHome.appendingPathComponent("config.toml"),
            environment: environment
        ) else {
            return []
        }
        return [user]
    }

    private static func configString(
        path: [String],
        workingDirectory: URL,
        openGrokHome: URL,
        environment: [String: String],
        effectiveConfig: TOMLValue?
    ) -> String? {
        for table in configTables(
            workingDirectory: workingDirectory,
            openGrokHome: openGrokHome,
            environment: environment,
            effectiveConfig: effectiveConfig
        ) {
            guard case .string(let raw)? = table[path: path] else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func configBool(
        path: [String],
        workingDirectory: URL,
        openGrokHome: URL,
        environment: [String: String],
        effectiveConfig: TOMLValue?
    ) -> Bool? {
        for table in configTables(
            workingDirectory: workingDirectory,
            openGrokHome: openGrokHome,
            environment: environment,
            effectiveConfig: effectiveConfig
        ) {
            if case .boolean(let value)? = table[path: path] { return value }
        }
        return nil
    }

    private static func configInteger(
        path: [String],
        workingDirectory: URL,
        openGrokHome: URL,
        environment: [String: String],
        effectiveConfig: TOMLValue?
    ) -> Int64? {
        for table in configTables(
            workingDirectory: workingDirectory,
            openGrokHome: openGrokHome,
            environment: environment,
            effectiveConfig: effectiveConfig
        ) {
            if case .integer(let value)? = table[path: path], value >= 0 {
                return value
            }
        }
        return nil
    }

    private static func configStringArray(
        path: [String],
        workingDirectory: URL,
        openGrokHome: URL,
        environment: [String: String],
        effectiveConfig: TOMLValue?
    ) -> [String]? {
        for table in configTables(
            workingDirectory: workingDirectory,
            openGrokHome: openGrokHome,
            environment: environment,
            effectiveConfig: effectiveConfig
        ) {
            guard let configured = table[path: path] else { continue }
            guard case .array(let entries) = configured else { return [] }
            var domains: [String] = []
            domains.reserveCapacity(entries.count)
            for entry in entries {
                guard case .string(let value) = entry else { return [] }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return [] }
                domains.append(trimmed)
            }
            return domains
        }
        return nil
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Handler

/// `ToolHandler` for `web_search`, `web_fetch` and `x_search`.
///
/// Dispatch runs through `FinalizedToolset.prepareAndCall` like every other
/// registry tool, so hooks and permission evaluation happen before `invoke`.
struct LiveWebToolHandler: ToolHandler {
    /// nil when the session resolved no search backend — `web_fetch` alone is
    /// still a complete, useful tool, so this is not a construction failure.
    let searchClient: WebSearchClient?
    let xSearchClient: WebSearchClient?
    let fetchClient: WebFetchClient

    init(
        searchClient: WebSearchClient?,
        xSearchClient: WebSearchClient? = nil,
        fetchClient: WebFetchClient
    ) {
        self.searchClient = searchClient
        self.xSearchClient = xSearchClient ?? searchClient
        self.fetchClient = fetchClient
    }

    func invoke(
        clientName: String,
        args: JSONValue,
        ctx: ToolCallContext,
        resources: ToolResources
    ) async -> Result<TypedToolOutput, ToolError> {
        _ = ctx
        _ = resources
        guard let toolId = try? ToolId(clientName) else {
            return .failure(.invalidArguments("web tool name is not a valid ToolId"))
        }
        switch clientName {
        case webSearchToolName:
            return await search(toolId: toolId, args: args)
        case xSearchToolName:
            return await xSearch(toolId: toolId, args: args)
        case webFetchToolName:
            return await fetch(toolId: toolId, args: args)
        default:
            return .failure(.notImplemented("web tool handler does not implement \(clientName)"))
        }
    }

    private func search(
        toolId: ToolId,
        args: JSONValue
    ) async -> Result<TypedToolOutput, ToolError> {
        guard let searchClient else {
            return .failure(.custom(
                code: "web_search_unavailable",
                detail: "web search has no configured backend for this session"
            ))
        }
        guard let query = stringField(args, "query"),
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .failure(.invalidArguments("web_search requires a non-empty query"))
        }
        let allowedDomains = stringArrayField(args, "allowed_domains")
        do {
            let result = try await searchClient.search(
                query: query,
                allowedDomains: allowedDomains.isEmpty ? nil : allowedDomains
            )
            return .success(searchOutput(toolId: toolId, result: result))
        } catch let error as WebMediaToolError {
            return .failure(.custom(code: "web_search_failed", detail: error.description))
        } catch {
            return .failure(.custom(code: "web_search_failed", detail: String(describing: error)))
        }
    }

    private func xSearch(
        toolId: ToolId,
        args: JSONValue
    ) async -> Result<TypedToolOutput, ToolError> {
        guard let xSearchClient else {
            return .failure(.custom(
                code: "x_search_unavailable",
                detail: "x_search has no configured backend for this session"
            ))
        }
        guard let query = stringField(args, "query"),
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .failure(.invalidArguments("x_search requires a non-empty query"))
        }
        do {
            let result = try await xSearchClient.xSearch(query: query)
            return .success(searchOutput(toolId: toolId, result: result))
        } catch let error as WebMediaToolError {
            return .failure(.custom(code: "x_search_failed", detail: error.description))
        } catch {
            return .failure(.custom(code: "x_search_failed", detail: String(describing: error)))
        }
    }

    private func fetch(
        toolId: ToolId,
        args: JSONValue
    ) async -> Result<TypedToolOutput, ToolError> {
        guard let url = stringField(args, "url"),
              !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .failure(.invalidArguments("web_fetch requires a url"))
        }
        do {
            // `WebFetchClient.fetch` owns the SSRF guard: scheme allowlist,
            // private/loopback host rejection, and a redirect cap re-checked on
            // every hop. Nothing here may pre-empt or bypass it.
            let output = try await fetchClient.fetch(WebFetchInput(url: url))
            var value: [String: JSONValue] = [
                "content": .string(output.content),
                "final_url": .string(output.finalURL),
                "content_type": .string(output.contentType),
                "status_code": .number(.int64(Int64(output.statusCode))),
                "total_bytes": .number(.int64(Int64(output.totalBytes))),
                "truncated": .bool(output.truncated),
            ]
            if let artifact = output.artifact {
                value["artifact"] = .object([
                    "local_url": .string(artifact.localURL),
                    "mime_type": .string(artifact.mimeType),
                    "filename": .string(artifact.filename),
                ])
            }
            return .success(TypedToolOutput(
                toolId: toolId,
                value: .object(value),
                modelOutput: [.text(text: output.content)]
            ))
        } catch let error as WebMediaToolError {
            return .failure(.custom(code: "web_fetch_failed", detail: error.description))
        } catch {
            return .failure(.custom(code: "web_fetch_failed", detail: String(describing: error)))
        }
    }

    private func searchOutput(toolId: ToolId, result: WebSearchResult) -> TypedToolOutput {
        var text = result.content
        if !result.citations.isEmpty {
            let lines = result.citations.map { citation -> String in
                citation.title.isEmpty ? "- \(citation.url)" : "- \(citation.title): \(citation.url)"
            }
            text += "\n\nSources:\n" + lines.joined(separator: "\n")
        }
        return TypedToolOutput(
            toolId: toolId,
            value: .object([
                "content": .string(result.content),
                "citations": .array(result.citations.map {
                    .object(["title": .string($0.title), "url": .string($0.url)])
                }),
            ]),
            modelOutput: [.text(text: text)]
        )
    }

    private func stringField(_ args: JSONValue, _ key: String) -> String? {
        guard case .object(let obj) = args, case .string(let value)? = obj[key] else {
            return nil
        }
        return value
    }

    private func stringArrayField(_ args: JSONValue, _ key: String) -> [String] {
        guard case .object(let obj) = args else { return [] }
        switch obj[key] {
        case .string(let single):
            return [single]
        case .array(let items):
            return items.compactMap { item in
                if case .string(let value) = item { return value }
                return nil
            }
        default:
            return []
        }
    }
}

let webSearchToolName = "web_search"
let webFetchToolName = "web_fetch"
let xSearchToolName = "x_search"
