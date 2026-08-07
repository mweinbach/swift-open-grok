// LivePagerAuthReachabilityTests.swift
//
// The render-layer half of `/login` and `/logout`, through the LIVE adapter
// (AGENTS.md §3): the real `LiveInteractiveControllerRenderer` painting into
// a captured sink, with effects asserted where they land — the painted frame
// and the credential stores on disk. The codex browser flow runs the REAL
// `loginCodexBrowser` listener; only the HTTP transport and the browser
// opener are fakes. The controller half (dispatch → overlay request) is
// pinned in `Tests/OpenGrokPagerTests/PagerLoginLogoutCommandTests.swift`.

import Foundation
import OpenGrokAuth
import OpenGrokHTTP
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokCLI

// MARK: - Fixture

private final class AuthCapturingSink: PagerTerminalSink, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []

    var capabilities: PagerTerminalCapabilities { .standard }

    func write(bytes newBytes: [UInt8]) throws {
        lock.lock(); defer { lock.unlock() }
        bytes.append(contentsOf: newBytes)
    }

    func flush() throws {}

    var strippedText: String {
        lock.lock(); defer { lock.unlock() }
        return stripANSI(bytes)
    }

    private func stripANSI(_ data: [UInt8]) -> String {
        var output = ""
        var index = 0
        while index < data.count {
            guard data[index] == 0x1B else {
                output.unicodeScalars.append(Unicode.Scalar(data[index]))
                index += 1
                continue
            }
            index += 1
            guard index < data.count else { break }
            switch data[index] {
            case UInt8(ascii: "["):
                index += 1
                while index < data.count, !(0x40...0x7E).contains(data[index]) {
                    index += 1
                }
                index += 1
            case UInt8(ascii: "]"):
                index += 1
                while index < data.count {
                    if data[index] == 0x07 { index += 1; break }
                    if data[index] == 0x1B, index + 1 < data.count,
                       data[index + 1] == UInt8(ascii: "\\") {
                        index += 2
                        break
                    }
                    index += 1
                }
            default:
                index += 1
            }
        }
        return output
    }
}

private struct AuthRendererFixture {
    let home: URL
    let sink: AuthCapturingSink
    let renderer: LiveInteractiveControllerRenderer
    let environment: [String: String]

    init(
        extraEnvironment: [String: String] = [:],
        authServices: LivePagerAuthServices
    ) throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-pager-auth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
        ]
        environment.merge(extraEnvironment) { _, new in new }
        self.environment = environment
        sink = AuthCapturingSink()
        let terminal = OpenGrokLiveTerminal(
            isTTY: { false },
            size: { OpenGrokLiveTerminalSize(width: 100, height: 30) },
            write: { _ in }
        )
        renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: terminal,
            sink: sink,
            workingDirectory: home.path,
            sessionID: "live-auth-session",
            openGrokHome: home,
            paintCadence: PagerMotion.minimumPaintCadence,
            environment: environment,
            authServices: authServices
        )
    }

    func dispose() {
        try? FileManager.default.removeItem(at: home)
    }

    var codexAuthFile: URL {
        OpenGrokAuthPaths.codexAuthFileURL(environment: environment)
    }

    var xaiAuthFile: URL {
        home.appendingPathComponent(OpenGrokAuthPaths.authFileName)
    }

    func waitForFrame(containing needle: String, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if sink.strippedText.contains(needle) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return sink.strippedText.contains(needle)
    }

    /// Poll until `predicate` holds, for disk effects landed by spawned tasks.
    func wait(
        timeout: TimeInterval = 5,
        for predicate: @Sendable () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return predicate()
    }
}

/// Services whose network legs are scripted and whose browser is a no-op.
/// The codex login flow itself defaults to the REAL `loginCodexBrowser`.
private func fakeAuthServices(
    transport: MockHTTPTransport,
    openBrowser: (@Sendable (URL) -> Void)? = nil,
    codexBrowserLogin: LivePagerAuthServices.CodexLoginFlow? = nil
) -> LivePagerAuthServices {
    LivePagerAuthServices(
        makeTransport: { transport },
        codexBrowserLogin: codexBrowserLogin ?? { authFile, endpoints, flowTransport, opener in
            try await loginCodexBrowser(
                authFile: authFile,
                endpoints: endpoints,
                transport: flowTransport,
                announce: false,
                openBrowser: opener
            )
        },
        openBrowser: openBrowser
    )
}

/// A structurally valid unsigned JWT — `persistCodexTokens` validates shape,
/// not signature.
private func makeTestJWT(payload: [String: Any]) -> String {
    func b64url(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    return "\(b64url(["alg": "none"])).\(b64url(payload)).sig"
}

private actor FlowCounter {
    private(set) var started = 0
    func increment() { started += 1 }
}

// MARK: - Provider picker

@Suite("Live /login provider picker", .serialized)
struct LiveLoginPickerTests {
    @Test("the overlay model carries all eight rows with live statuses")
    func overlayModelCarriesStatuses() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-login-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        // A stored Fireworks key (the settings modal's own save path) and a
        // Kimi env override; everything else missing.
        try storeScopedAPIKey(
            grokHome: home,
            scope: providerAPIKeyScope("fireworks"),
            apiKey: "fw-1"
        )
        let statuses = LiveLoginProviderPicker.statuses(
            openGrokHome: home,
            environment: ["MOONSHOT_API_KEY": "env-kimi"]
        )
        #expect(statuses["fireworks"] == .stored)
        #expect(statuses["kimi"] == .environmentOverride)
        #expect(statuses["deepseek"] == .missing)
        #expect(statuses["meta"] == .missing)
        #expect(statuses["opencode-go"] == .missing)
        #expect(statuses["wafer"] == .missing)

        let overlay = LiveLoginProviderPicker.overlay(statuses: statuses)
        guard case .list(let list) = overlay.content else {
            Issue.record("expected a list overlay")
            return
        }
        // Upstream's picker order and copy (`login.rs:30-79`): OAuth rows
        // keep fixed descriptions, API-key rows show "API key · <status>".
        // The status must ride in `detail` — the painted channel — not
        // `summary`, which the list painter never draws.
        #expect(list.rows.map(\.label) == [
            "xAI Grok", "ChatGPT Codex", "Kimi", "Fireworks AI",
            "DeepSeek", "Meta API", "OpenCode Go", "Wafer AI",
        ])
        #expect(list.rows.map(\.id) == [
            "xai", "codex", "kimi", "fireworks",
            "deepseek", "meta", "opencode-go", "wafer",
        ])
        #expect(list.rows[0].detail == "Sign in with xAI")
        #expect(list.rows[1].detail == "Connect an OpenAI Codex account")
        #expect(list.rows[2].detail == "API key · environment override")
        #expect(list.rows[3].detail == "API key · saved")
        #expect(list.rows[4].detail == "API key · not configured")
    }

    @Test("the picker paints and selecting the codex row round-trips the typed form")
    func pickerPaintsAndSelects() async throws {
        let fixture = try AuthRendererFixture(
            authServices: fakeAuthServices(transport: MockHTTPTransport())
        )
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        try await fixture.renderer.render(.overlay(.loginProviderPicker))
        // Single-token needles: the cell differ can split multi-word strings.
        #expect(await fixture.waitForFrame(containing: "Grok"))
        #expect(await fixture.waitForFrame(containing: "Codex"))
        #expect(await fixture.waitForFrame(containing: "configured"))

        // Row 0 is xAI; one step down is the codex row. Selecting it must
        // hand back the exact typed form (`login.rs:82-84` — one
        // `provider_action` for both paths).
        let moved = try await fixture.renderer.handleInput(
            .key(KeyEvent(key: .down))
        )
        #expect(moved == .consumed)
        let selected = try await fixture.renderer.handleInput(
            .key(KeyEvent(key: .enter))
        )
        #expect(selected == .runCommand("/login codex"))
        try await fixture.renderer.restoreTerminal()
    }
}

// MARK: - Codex login flow

@Suite("Live /login codex browser flow", .serialized)
struct LiveCodexLoginFlowTests {
    @Test("the codex flow runs against the real listener and lands credentials on disk")
    func codexFlowLandsCredentials() async throws {
        let idToken = makeTestJWT(payload: [
            "email": "tui@openai.com",
            "https://api.openai.com/auth": ["chatgpt_plan_type": "plus"],
        ])
        let exchangeJSON = """
        {"id_token":"\(idToken)","access_token":"tui-access","refresh_token":"tui-refresh","account_id":"tui-acct"}
        """
        let transport = MockHTTPTransport(responses: [
            .init(
                metadata: HTTPResponseMetadata(statusCode: 200),
                body: Data(exchangeJSON.utf8)
            ),
        ])
        // The fake "browser": pull the redirect port and state out of the
        // authorize URL and drive the REAL callback listener, the way
        // `Tests/OpenGrokAuthTests` codexBrowserLoginFlow does.
        let openBrowser: @Sendable (URL) -> Void = { authURL in
            guard let components = URLComponents(url: authURL, resolvingAgainstBaseURL: false),
                  let redirect = components.queryItems?
                      .first(where: { $0.name == "redirect_uri" })?.value,
                  let state = components.queryItems?
                      .first(where: { $0.name == "state" })?.value,
                  let redirectURL = URL(string: redirect),
                  let port = redirectURL.port,
                  let cbURL = URL(
                    string: "http://127.0.0.1:\(port)/auth/callback?code=mock-code&state=\(state)"
                  )
            else { return }
            URLSession.shared.dataTask(with: cbURL).resume()
        }
        let fixture = try AuthRendererFixture(
            authServices: fakeAuthServices(transport: transport, openBrowser: openBrowser)
        )
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        try await fixture.renderer.render(.overlay(.loginCodex))

        // The dispatch notice (`dispatch/auth.rs:119-121`) and the auth URL
        // announce land in the transcript.
        #expect(await fixture.waitForFrame(containing: "Opening"))
        #expect(await fixture.waitForFrame(containing: "automatically:"))
        // Completion: the store is real and the notice carries the account
        // (`task_result.rs:3853-3869`).
        let codexFile = fixture.codexAuthFile
        #expect(await fixture.wait { isCodexLoggedIn(at: codexFile) })
        #expect(await fixture.waitForFrame(containing: "tui@openai.com"))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("a second /login codex while one flow is pending is refused, single-flight")
    func pendingFlowIsSingleFlight() async throws {
        let counter = FlowCounter()
        let blockedFlow: LivePagerAuthServices.CodexLoginFlow = { _, _, _, _ in
            await counter.increment()
            // Park long enough for the second dispatch to hit the guard.
            try await Task.sleep(nanoseconds: 5_000_000_000)
            throw CancellationError()
        }
        let fixture = try AuthRendererFixture(
            authServices: fakeAuthServices(
                transport: MockHTTPTransport(),
                codexBrowserLogin: blockedFlow
            )
        )
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        try await fixture.renderer.render(.overlay(.loginCodex))
        try await fixture.renderer.render(.overlay(.loginCodex))

        #expect(await fixture.waitForFrame(containing: "progress"))
        // The second dispatch must not have bound a second callback flow.
        // Poll first: the spawned flow's increment races this read under
        // parallel-suite load (a one-shot read here flaked at 0), and both
        // dispatches have already completed, so once the count reaches 1 a
        // broken guard would have spawned its second task long ago.
        let deadline = Date().addingTimeInterval(5)
        while await counter.started < 1, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await counter.started == 1)
        try await fixture.renderer.restoreTerminal()
    }
}

// MARK: - Logout

@Suite("Live /logout credential removal", .serialized)
struct LiveLogoutTests {
    @Test("/logout codex revokes best-effort and deletes the real store file")
    func codexLogoutDeletesStore() async throws {
        // Revoke gets a 200; the deletion is the effect under test.
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 200)),
        ])
        let fixture = try AuthRendererFixture(
            authServices: fakeAuthServices(transport: transport)
        )
        defer { fixture.dispose() }
        try persistCodexTokens(
            at: fixture.codexAuthFile,
            idToken: makeTestJWT(payload: ["email": "gone@openai.com"]),
            accessToken: "gone-access",
            refreshToken: "gone-refresh"
        )
        try await fixture.renderer.begin()
        try await fixture.renderer.render(.overlay(.logout(account: .codex)))

        let codexFile = fixture.codexAuthFile
        #expect(await fixture.wait {
            !FileManager.default.fileExists(atPath: codexFile.path)
        })
        // `task_result.rs:3891`.
        #expect(await fixture.waitForFrame(containing: "disconnected."))
        // The revoke leg carried the refresh token to the mock, best-effort.
        #expect(transport.recordedRequests.count == 1)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("/logout codex with no store reports it was not connected")
    func codexLogoutWithoutStore() async throws {
        let fixture = try AuthRendererFixture(
            authServices: fakeAuthServices(transport: MockHTTPTransport())
        )
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        try await fixture.renderer.render(.overlay(.logout(account: .codex)))
        // `task_result.rs:3892`.
        #expect(await fixture.waitForFrame(containing: "was"))
        #expect(await fixture.waitForFrame(containing: "connected."))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("/logout removes the xAI credential and reports the provider-chooser copy")
    func xaiLogoutDeletesCredential() async throws {
        let fixture = try AuthRendererFixture(
            authServices: fakeAuthServices(transport: MockHTTPTransport())
        )
        defer { fixture.dispose() }
        // Seed through the same manager the logout path uses.
        let seed = AuthManager(
            grokHome: fixture.home,
            config: GrokComConfig.default(environment: fixture.environment),
            environment: fixture.environment
        )
        try await loginXAIWithAPIKey(manager: seed, apiKey: "sk-xai-live")
        #expect(FileManager.default.fileExists(atPath: fixture.xaiAuthFile.path))

        try await fixture.renderer.begin()
        try await fixture.renderer.render(.overlay(.logout(account: .xai)))

        // The deletion is synchronous with the render: the emptied store is
        // removed outright (`AuthManager.clear`).
        #expect(!FileManager.default.fileExists(atPath: fixture.xaiAuthFile.path))
        // No codex store survives, so the neither-provider copy paints
        // (`task_result.rs:3826`).
        #expect(await fixture.waitForFrame(containing: "continue."))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("/logout with a surviving codex store reports Codex remains connected")
    func xaiLogoutKeepsCodex() async throws {
        let fixture = try AuthRendererFixture(
            authServices: fakeAuthServices(transport: MockHTTPTransport())
        )
        defer { fixture.dispose() }
        let seed = AuthManager(
            grokHome: fixture.home,
            config: GrokComConfig.default(environment: fixture.environment),
            environment: fixture.environment
        )
        try await loginXAIWithAPIKey(manager: seed, apiKey: "sk-xai-live")
        try persistCodexTokens(
            at: fixture.codexAuthFile,
            idToken: makeTestJWT(payload: ["email": "stay@openai.com"]),
            accessToken: "stay-access",
            refreshToken: "stay-refresh"
        )

        try await fixture.renderer.begin()
        try await fixture.renderer.render(.overlay(.logout(account: .xai)))

        #expect(!FileManager.default.fileExists(atPath: fixture.xaiAuthFile.path))
        let codexFile = fixture.codexAuthFile
        #expect(FileManager.default.fileExists(atPath: codexFile.path))
        // `task_result.rs:3798`.
        #expect(await fixture.waitForFrame(containing: "remains"))
        try await fixture.renderer.restoreTerminal()
    }
}
