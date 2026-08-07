// PagerLoginLogoutCommandTests.swift
//
// `/login` and `/logout` at the controller seam (AGENTS.md §3): real input
// events into the real controller, asserted on the overlay requests and
// notices that land on the render adapter — never on registry membership
// alone. The upstream contract is `slash/commands/login.rs` and
// `slash/commands/logout.rs`; every copy assertion here is byte-exact.

import Foundation
@testable import OpenGrokPager
import OpenGrokTerminalCore
import Testing

@Suite("/login and /logout at the controller seam")
struct PagerLoginLogoutCommandTests {
    // MARK: - Registry

    @Test("registry rows carry upstream's description and usage verbatim")
    func registryRowsAreVerbatim() {
        let commands = OpenGrokPagerInteractiveController.builtinCommands
        let login = commands.first { $0.name == "login" }
        // `login.rs:108-114`.
        #expect(login?.summary
            == "Connect xAI, OpenAI Codex, Kimi, Fireworks AI, DeepSeek, Meta API, Wafer AI, or OpenCode Go")
        #expect(login?.usage
            == "/login [xai|codex|kimi|fireworks|deepseek|meta|wafer|opencode-go]")
        #expect(login?.aliases.isEmpty == true)
        // The argument is optional, so Enter on a bare `/login` dispatches.
        #expect(login?.requiresArguments == false)

        let logout = commands.first { $0.name == "logout" }
        // `logout.rs:13-19`.
        #expect(logout?.summary == "Log out of xAI or OpenAI Codex")
        #expect(logout?.usage == "/logout [codex]")
        #expect(logout?.aliases.isEmpty == true)
        #expect(logout?.requiresArguments == false)
    }

    // MARK: - /login dispatch

    @Test("bare /login opens the provider picker")
    func bareLoginOpensPicker() async throws {
        let harness = try await AuthCommandHarness.run(submitting: ["/login"])
        #expect(await harness.overlayRequests == [.loginProviderPicker])
    }

    @Test("the codex aliases all dispatch the browser flow, case-insensitively")
    func codexAliasesDispatch() async throws {
        // `provider_action` lowercases before matching (`login.rs:86-89`).
        let harness = try await AuthCommandHarness.run(
            submitting: ["/login codex", "/login openai", "/login chatgpt", "/login CODEX"]
        )
        #expect(await harness.overlayRequests == [
            .loginCodex, .loginCodex, .loginCodex, .loginCodex,
        ])
    }

    @Test("the xai aliases dispatch the xAI route")
    func xaiAliasesDispatch() async throws {
        let harness = try await AuthCommandHarness.run(
            submitting: ["/login xai", "/login grok"]
        )
        #expect(await harness.overlayRequests == [.loginXAI, .loginXAI])
    }

    @Test("API-key providers deep-link the settings modal at their key row")
    func apiKeyProvidersDeepLinkSettings() async throws {
        // The full alias table (`login.rs:90-95`), one spelling per line.
        let harness = try await AuthCommandHarness.run(submitting: [
            "/login kimi", "/login moonshot",
            "/login fireworks",
            "/login deepseek", "/login deep-seek", "/login deepseek-api",
            "/login meta", "/login meta-ai", "/login meta_ai", "/login meta-api",
            "/login opencode", "/login opencode-go", "/login opencode_go", "/login go",
            "/login wafer", "/login wafer-ai", "/login wafer_ai",
        ])
        #expect(await harness.overlayRequests == [
            .settings(deepLinkKey: "kimi_api_endpoint"),
            .settings(deepLinkKey: "kimi_api_endpoint"),
            .settings(deepLinkKey: "fireworks_api_key"),
            .settings(deepLinkKey: "deepseek_api_key"),
            .settings(deepLinkKey: "deepseek_api_key"),
            .settings(deepLinkKey: "deepseek_api_key"),
            .settings(deepLinkKey: "meta_api_key"),
            .settings(deepLinkKey: "meta_api_key"),
            .settings(deepLinkKey: "meta_api_key"),
            .settings(deepLinkKey: "meta_api_key"),
            .settings(deepLinkKey: "opencode_go_api_key"),
            .settings(deepLinkKey: "opencode_go_api_key"),
            .settings(deepLinkKey: "opencode_go_api_key"),
            .settings(deepLinkKey: "opencode_go_api_key"),
            .settings(deepLinkKey: "wafer_api_key"),
            .settings(deepLinkKey: "wafer_api_key"),
            .settings(deepLinkKey: "wafer_api_key"),
        ])
    }

    @Test("the alias table resolves exactly upstream's arms")
    func aliasTableIsPinned() {
        // `provider_action` (`login.rs:88-95`), spelling by spelling. Pinned
        // directly on the resolver because the composer's dropdown accepts a
        // fuzzy-matched row for many of these spellings, which would mask a
        // regression in the typed path.
        let arms: [(String, String)] = [
            ("xai", "xai"), ("grok", "xai"),
            ("codex", "codex"), ("openai", "codex"), ("chatgpt", "codex"),
            ("kimi", "kimi"), ("moonshot", "kimi"),
            ("fireworks", "fireworks"),
            ("deepseek", "deepseek"), ("deep-seek", "deepseek"), ("deepseek-api", "deepseek"),
            ("meta", "meta"), ("meta-ai", "meta"), ("meta_ai", "meta"), ("meta-api", "meta"),
            ("opencode", "opencode-go"), ("opencode-go", "opencode-go"),
            ("opencode_go", "opencode-go"), ("go", "opencode-go"),
            ("wafer", "wafer"), ("wafer-ai", "wafer"), ("wafer_ai", "wafer"),
        ]
        for (spelling, expected) in arms {
            #expect(PagerLoginProviders.resolve(spelling)?.insertText == expected)
        }
        #expect(PagerLoginProviders.resolve("deep_seek") == nil)
        // Trim + ASCII-lowercase, upstream's normalization (`login.rs:86`).
        #expect(PagerLoginProviders.resolve("  ChatGPT  ")?.insertText == "codex")
    }

    @Test("an unknown provider is refused with upstream's copy, argument echoed as typed")
    func unknownProviderCopy() async throws {
        let harness = try await AuthCommandHarness.run(submitting: ["/login FooBar"])
        #expect(await harness.overlayRequests.isEmpty)
        // `login.rs:96-99`, byte for byte — the echo keeps the typed case.
        #expect(await harness.notices == [
            "Unknown provider: FooBar. Use /login xai, /login codex, /login kimi, "
                + "/login fireworks, /login deepseek, /login meta, /login wafer, "
                + "or /login opencode-go"
        ])
    }

    // MARK: - /logout dispatch

    @Test("bare /logout targets xAI and /logout codex targets the codex store")
    func logoutTargets() async throws {
        let harness = try await AuthCommandHarness.run(
            submitting: ["/logout", "/logout codex"]
        )
        #expect(await harness.overlayRequests == [
            .logout(account: .xai),
            .logout(account: .codex),
        ])
    }

    @Test("an unknown account is refused with upstream's copy")
    func unknownAccountCopy() async throws {
        // Upstream matches `codex` exactly, so `Codex` errors
        // (`logout.rs:38-45`) — this pins the kept case-sensitivity.
        let harness = try await AuthCommandHarness.run(submitting: ["/logout Codex"])
        #expect(await harness.overlayRequests.isEmpty)
        // `logout.rs:42-44`, byte for byte.
        #expect(await harness.notices == [
            "Unknown account: Codex. Use /logout or /logout codex"
        ])
    }

    // MARK: - Argument completion

    @Test("/login offers the eight providers with neutral descriptions and ranks over match_text")
    func loginArgumentSuggestions() async throws {
        let harness = try await AuthCommandHarness.run(events: [
            .paste("/login "),
            .paste("moonshot"),
        ])
        let states = await harness.promptStates
        // Bare phase: all eight, upstream's picker order with the
        // provider-neutral descriptions (`suggest_args`, `login.rs:124-126`).
        let opened = states.first { $0.text == "/login " && !$0.completions.isEmpty }
        #expect(opened?.completions.map(\.name) == [
            "xAI Grok", "ChatGPT Codex", "Kimi", "Fireworks AI",
            "DeepSeek", "Meta API", "OpenCode Go", "Wafer AI",
        ])
        #expect(opened?.completions.first?.summary == "Sign in with xAI")
        #expect(opened?.completions.first?.insertText == "/login xai")
        #expect(opened?.completions.last?.summary == "Configure an API key and query models")
        // `moonshot` only appears in Kimi's match_text, never its display.
        let filtered = states.first { $0.text == "/login moonshot" && !$0.completions.isEmpty }
        #expect(filtered?.completions.first?.name == "Kimi")
        #expect(filtered?.completions.first?.insertText == "/login kimi")
    }

    @Test("/logout offers the single codex row")
    func logoutArgumentSuggestions() async throws {
        let harness = try await AuthCommandHarness.run(events: [.paste("/logout ")])
        let states = await harness.promptStates
        let opened = states.first { $0.text == "/logout " && !$0.completions.isEmpty }
        // `logout.rs:29-36`.
        #expect(opened?.completions.map(\.name) == ["codex"])
        #expect(opened?.completions.first?.summary == "Disconnect the OpenAI Codex account")
        #expect(opened?.completions.first?.insertText == "/logout codex")
    }
}

// MARK: - Harness

private actor AuthCommandHarness {
    private let renderer: AuthRecordingRenderer

    private init(renderer: AuthRecordingRenderer) {
        self.renderer = renderer
    }

    var overlayRequests: [OpenGrokPagerOverlayRequest] {
        get async { await renderer.overlayRequests }
    }
    var notices: [String] { get async { await renderer.notices } }
    var promptStates: [OpenGrokPagerInteractivePromptState] {
        get async { await renderer.promptStates }
    }

    /// Type a line, close the dropdown, and press Enter. The Esc matters:
    /// with the dropdown open, Enter accepts the highlighted suggestion row
    /// instead of the typed text, so an alias like `go` could dispatch as
    /// whatever row the fuzzy matcher ranked first. Closing it first makes
    /// every submission exercise the typed path — `provider_action` itself.
    static func run(submitting lines: [String]) async throws -> AuthCommandHarness {
        var events: [InputEvent] = []
        for line in lines {
            events.append(.paste(line))
            events.append(.key(KeyEvent(key: .escape)))
            events.append(.key(KeyEvent(key: .enter)))
        }
        return try await run(events: events)
    }

    static func run(events: [InputEvent]) async throws -> AuthCommandHarness {
        let renderer = AuthRecordingRenderer()
        let controller = OpenGrokPagerInteractiveController(
            input: AsyncStream { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish()
            },
            runtime: AuthInertRuntime(),
            renderer: renderer,
            output: AuthSilentOutput()
        )
        _ = try await controller.run(.init(prompt: "", mode: .inline))
        return AuthCommandHarness(renderer: renderer)
    }
}

private actor AuthRecordingRenderer: OpenGrokPagerInteractiveRenderAdapter {
    private var events: [OpenGrokPagerInteractiveEvent] = []

    func begin() {}
    func restoreTerminal() {}

    func render(_ event: OpenGrokPagerInteractiveEvent) {
        events.append(event)
    }

    var overlayRequests: [OpenGrokPagerOverlayRequest] {
        events.compactMap { if case .overlay(let request) = $0 { return request } else { return nil } }
    }

    var notices: [String] {
        events.compactMap { if case .notice(let message) = $0 { return message } else { return nil } }
    }

    var promptStates: [OpenGrokPagerInteractivePromptState] {
        events.compactMap { if case .promptChanged(let state) = $0 { return state } else { return nil } }
    }
}

private struct AuthInertRuntime: OpenGrokPagerRuntimeAdapter {
    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        _ = request
        throw CancellationError()
    }
}

private struct AuthSilentOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws { _ = event }
}
