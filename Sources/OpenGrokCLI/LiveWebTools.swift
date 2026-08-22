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
    /// Advertise `web_search`.
    var webSearchEnabled: Bool
    /// Advertise `web_fetch`. Independent of search credentials — fetching a
    /// URL needs no API key, only the SSRF guard `WebFetchClient` already has.
    var webFetchEnabled: Bool
    /// Advertise `x_search`. Upstream registers it but puts it in no preset, and
    /// `WebSearchClient.xSearch` hard-requires the xAI Responses backend, so it
    /// only ever appears on an xAI-backed search config.
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
}

// MARK: - Resolution

enum LiveWebToolComposition {
    /// Resolve the session's web-tool configuration.
    ///
    /// `disableWebSearch` is the `--disable-web-search` master switch. It kills
    /// `web_search` and `x_search`; `web_fetch` survives it, matching upstream,
    /// where the flag governs the search config and not the fetch tool.
    static func resolveAvailability(
        workingDirectory: URL,
        openGrokHome: URL,
        environment: [String: String],
        samplingProvider: ModelProvider,
        samplingAPIKey: String,
        samplingBaseURL: String,
        disableWebSearch: Bool
    ) -> LiveWebToolAvailability {
        let webFetchEnabled = boolFromEnv(environment["GROK_WEB_FETCH"]) ?? true

        guard !disableWebSearch else {
            return LiveWebToolAvailability(
                searchConfig: .disabled,
                webSearchEnabled: false,
                webFetchEnabled: webFetchEnabled,
                xSearchEnabled: false
            )
        }

        let xaiConfig = resolveXaiSearchConfig(
            workingDirectory: workingDirectory,
            openGrokHome: openGrokHome,
            environment: environment,
            samplingProvider: samplingProvider,
            samplingAPIKey: samplingAPIKey,
            samplingBaseURL: samplingBaseURL
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
            perplexityAvailable: perplexityConfig != nil
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
            webSearchEnabled: searchConfig.isEnabled,
            webFetchEnabled: webFetchEnabled,
            // `x_search` needs the xAI Responses backend specifically; a
            // Perplexity-backed session must not advertise it.
            xSearchEnabled: searchConfig.isEnabled && !searchConfig.isPerplexity
        )
    }

    /// `effective_source_for` (`config.rs:516-540`).
    ///
    /// An explicit `[toolset.web_search_source]` entry wins outright. Otherwise
    /// Kimi honours the legacy Perplexity toggle, Codex prefers xAI when a key
    /// is present and falls back to its own native search, and every other
    /// provider defaults to xAI — Fireworks included, which is why Fireworks
    /// needs an explicit Perplexity selection rather than inheriting Kimi's.
    static func effectiveSource(
        provider: ModelProvider,
        workingDirectory: URL,
        openGrokHome: URL,
        environment: [String: String],
        xaiAvailable: Bool,
        perplexityAvailable: Bool
    ) -> LiveWebSearchSource {
        if let explicit = explicitSource(
            provider: provider,
            workingDirectory: workingDirectory,
            openGrokHome: openGrokHome,
            environment: environment
        ) {
            return explicit
        }
        switch provider {
        case .kimi:
            let legacyToggle = configBool(
                path: ["toolset", "perplexity_web_search", "enabled"],
                workingDirectory: workingDirectory,
                openGrokHome: openGrokHome,
                environment: environment
            ) ?? false
            return legacyToggle && perplexityAvailable ? .perplexity : .xai
        case .codex:
            return xaiAvailable ? .xai : .native
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
        environment: [String: String]
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
            environment: environment
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
        samplingBaseURL: String
    ) -> WebSearchConfig {
        guard let apiKey = LiveImageToolComposition.xaiMediaAPIKey(
            samplingProvider: samplingProvider,
            samplingAPIKey: samplingAPIKey,
            environment: environment
        ) else { return .disabled }

        let baseURL = LiveImageToolComposition.xaiMediaBaseURL(
            samplingProvider: samplingProvider,
            samplingBaseURL: samplingBaseURL,
            configuredXaiBaseURL: OpenGrokLiveApplicationLauncher.configuredXaiAPIBaseURL(
                workingDirectory: workingDirectory,
                openGrokHome: openGrokHome,
                environment: environment
            ),
            environment: environment
        )

        let model = environment["GROK_WEB_SEARCH_MODEL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? configString(
                path: ["toolset", "web_search", "model"],
                workingDirectory: workingDirectory,
                openGrokHome: openGrokHome,
                environment: environment
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
        environment: [String: String]
    ) -> [TOMLValue] {
        var tables = [loadMergedProjectConfig(cwd: workingDirectory, environment: environment)]
        if let user = try? loadConfigFile(
            at: openGrokHome.appendingPathComponent("config.toml")
        ) {
            tables.append(user)
        }
        return tables
    }

    private static func configString(
        path: [String],
        workingDirectory: URL,
        openGrokHome: URL,
        environment: [String: String]
    ) -> String? {
        for table in configTables(
            workingDirectory: workingDirectory,
            openGrokHome: openGrokHome,
            environment: environment
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
        environment: [String: String]
    ) -> Bool? {
        for table in configTables(
            workingDirectory: workingDirectory,
            openGrokHome: openGrokHome,
            environment: environment
        ) {
            if case .boolean(let value)? = table[path: path] { return value }
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
    let fetchClient: WebFetchClient

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
        guard let searchClient else {
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
            let result = try await searchClient.xSearch(query: query)
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
