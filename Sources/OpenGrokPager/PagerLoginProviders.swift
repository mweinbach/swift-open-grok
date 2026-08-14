// PagerLoginProviders.swift
//
// The `/login` provider vocabulary — one table drives the argument
// completions, the typed-alias resolution, the unknown-provider error, and
// the provider picker's rows (the render layer adds live secret statuses).
// Upstream keeps the same single source of truth in
// `slash/commands/login.rs` (`provider_items` + `provider_action`).

import OpenGrokPagerCommandUI

/// One row of upstream's provider table (`login.rs:30-79`), plus the alias
/// arms of `provider_action` (`login.rs:85-101`) and where the port routes
/// the selection.
public struct PagerLoginProvider: Sendable, Equatable {
    /// Where a resolved provider dispatches.
    public enum Route: Sendable, Equatable {
        /// Upstream `Action::Login` — the xAI OAuth flow.
        case xai
        /// Upstream `Action::LoginCodex` — the Codex browser OAuth flow.
        case codex
        /// Upstream's dedicated per-provider API-key editor
        /// (`Action::Open*ApiKeyEditor`). The port routes these to the
        /// settings modal deep-linked at the provider's key row, which is
        /// the same save path (recorded divergence; see PagerSettingsRegistry).
        case apiKey(settingsKey: String)
    }

    /// Canonical token — upstream's `insert_text`, and the picker row id.
    public let insertText: String
    /// Upstream's `display` string, verbatim.
    public let display: String
    /// Upstream's `match_text`, verbatim — what argument completion ranks on.
    public let matchText: String
    /// The provider-neutral description upstream's inline completion shows
    /// (`login.rs:20-23`: the API-key rows only gain a live status inside the
    /// modal, which the render layer owns).
    public let neutralDescription: String
    /// Every spelling `provider_action` accepts for this provider.
    public let aliases: [String]
    public let route: Route

    /// Whether the picker row shows a live API-key status ("API key · …").
    public var isAPIKeyProvider: Bool {
        if case .apiKey = route { return true }
        return false
    }
}

public enum PagerLoginProviders {
    /// Upstream's neutral API-key row description (`login.rs:22`).
    static let apiKeyNeutralDescription = "Configure an API key and query models"

    /// The eight providers in upstream's picker order (`login.rs:30-79`).
    ///
    /// Settings keys reference `PagerSettingsRegistry.default` rows. Kimi
    /// deep-links to the `kimi_api_endpoint` service chooser rather than one
    /// of its two key rows because upstream's Kimi editor also starts at the
    /// service picker (`dispatch/tests/settings.rs:691`).
    public static let all: [PagerLoginProvider] = [
        PagerLoginProvider(
            insertText: "xai",
            display: "xAI Grok",
            matchText: "xai grok oauth",
            neutralDescription: "Sign in with xAI",
            aliases: ["xai", "grok"],
            route: .xai
        ),
        PagerLoginProvider(
            insertText: "codex",
            display: "ChatGPT Codex",
            matchText: "codex openai chatgpt oauth",
            neutralDescription: "Connect an OpenAI Codex account",
            aliases: ["codex", "openai", "chatgpt"],
            route: .codex
        ),
        PagerLoginProvider(
            insertText: "kimi",
            display: "Kimi",
            matchText: "kimi moonshot api key coding",
            neutralDescription: apiKeyNeutralDescription,
            aliases: ["kimi", "moonshot"],
            route: .apiKey(settingsKey: "kimi_api_endpoint")
        ),
        PagerLoginProvider(
            insertText: "fireworks",
            display: "Fireworks AI",
            matchText: "fireworks ai api key glm deepseek",
            neutralDescription: apiKeyNeutralDescription,
            aliases: ["fireworks"],
            route: .apiKey(settingsKey: "fireworks_api_key")
        ),
        PagerLoginProvider(
            insertText: "deepseek",
            display: "DeepSeek",
            matchText: "deepseek api direct key",
            neutralDescription: apiKeyNeutralDescription,
            aliases: ["deepseek", "deep-seek", "deepseek-api"],
            route: .apiKey(settingsKey: "deepseek_api_key")
        ),
        PagerLoginProvider(
            insertText: "meta",
            display: "Meta API",
            matchText: "meta ai api key muse spark responses web search",
            neutralDescription: apiKeyNeutralDescription,
            aliases: ["meta", "meta-ai", "meta_ai", "meta-api"],
            route: .apiKey(settingsKey: "meta_api_key")
        ),
        PagerLoginProvider(
            insertText: "opencode-go",
            display: "OpenCode Go",
            matchText: "opencode go api key dynamic models",
            neutralDescription: apiKeyNeutralDescription,
            aliases: ["opencode", "opencode-go", "opencode_go", "go"],
            route: .apiKey(settingsKey: "opencode_go_api_key")
        ),
        PagerLoginProvider(
            insertText: "wafer",
            display: "Wafer AI",
            matchText: "wafer wafer ai api key chat completions dynamic models",
            neutralDescription: apiKeyNeutralDescription,
            aliases: ["wafer", "wafer-ai", "wafer_ai"],
            route: .apiKey(settingsKey: "wafer_api_key")
        ),
        PagerLoginProvider(
            insertText: "zai",
            display: "Z AI",
            matchText: "z ai zai api key glm coding plan chat completions dynamic models",
            neutralDescription: apiKeyNeutralDescription,
            aliases: ["zai", "z-ai", "z_ai"],
            route: .apiKey(settingsKey: "zai_api_key")
        ),
    ]

    /// `provider_action`'s matching rule (`login.rs:85-87`): trim, ASCII
    /// lowercase, exact alias match.
    public static func resolve(_ token: String) -> PagerLoginProvider? {
        let needle = token
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return all.first { $0.aliases.contains(needle) }
    }

    /// Upstream's unknown-provider error, byte for byte (`login.rs:96-99`) —
    /// the argument echoes back as typed, only trimmed.
    public static func unknownProviderMessage(_ token: String) -> String {
        "Unknown provider: \(token.trimmingCharacters(in: .whitespacesAndNewlines)). "
            + "Use /login xai, /login codex, /login kimi, /login fireworks, "
            + "/login deepseek, /login meta, /login wafer, /login zai, or /login opencode-go"
    }

    /// Upstream's unknown-account error for `/logout` (`logout.rs:42-44`).
    public static func unknownAccountMessage(_ token: String) -> String {
        "Unknown account: \(token). Use /logout or /logout codex"
    }

    /// `/login` argument rows — `LoginCommand::suggest_args` (`login.rs:124-126`)
    /// passes no statuses, so the inline dropdown always shows the neutral
    /// descriptions. Ranked over `match_text`, upstream's arg-matcher input.
    public static func suggestions(query: String) -> [OpenGrokPagerCommandSuggestion] {
        let rows = all.map { provider in
            OpenGrokPagerCommandSuggestion(
                name: provider.display,
                summary: provider.neutralDescription,
                insertText: "/login \(provider.insertText)"
            )
        }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return rows }
        // `rows` parallels `all`, so ranking the providers over `match_text`
        // indexes straight into the built rows.
        let matcher = PagerFuzzyMatcher()
        return matcher
            .rank(all, query: trimmed, limit: all.count) { $0.matchText }
            .map { rows[$0.index] }
    }

    /// `/logout` argument rows — `LogoutCommand::suggest_args`
    /// (`logout.rs:29-36`): one `codex` row.
    public static func logoutSuggestions(query: String) -> [OpenGrokPagerCommandSuggestion] {
        let row = OpenGrokPagerCommandSuggestion(
            name: "codex",
            summary: "Disconnect the OpenAI Codex account",
            insertText: "/logout codex"
        )
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard trimmed.isEmpty || "codex openai chatgpt".contains(trimmed) else { return [] }
        return [row]
    }
}
