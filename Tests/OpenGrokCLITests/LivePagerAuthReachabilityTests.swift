// Depends on OIDCTestJWTFixture, which needs Apple CryptoKit + Security.
// Compiled out on Linux; see PORT_STATUS.md for the coverage gap this leaves.
#if canImport(CryptoKit) && canImport(Security)

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
        authServices: LivePagerAuthServices,
        catalogStore: LiveModelCatalogStore? = nil
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
            catalogStore: catalogStore,
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

    func waitForAuthState(
        timeout: TimeInterval = 5,
        matching predicate: @Sendable (PagerWelcomeAuthState?) -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(await renderer.testingWelcomeAuthState()) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return predicate(await renderer.testingWelcomeAuthState())
    }
}

private final class CapturedAuthBrowser: @unchecked Sendable {
    private let lock = NSLock()
    private var openedURL: URL?

    func open(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        openedURL = url
    }

    func waitForURL(timeout: TimeInterval = 5) async -> URL? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let url = lock.withLock { openedURL }
            if let url { return url }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return lock.withLock { openedURL }
    }
}

/// Services whose network legs are scripted and whose browser is a no-op.
/// The codex login flow itself defaults to the REAL `loginCodexBrowser`, and
/// the xAI flow to the REAL `loginXAIBrowser` (the seam's own default).
private func fakeAuthServices(
    transport: any HTTPTransport,
    openBrowser: (@Sendable (URL) -> Void)? = nil,
    codexBrowserLogin: LivePagerAuthServices.CodexLoginFlow? = nil,
    xaiBrowserLogin: LivePagerAuthServices.XAILoginFlow? = nil
) -> LivePagerAuthServices {
    var services = LivePagerAuthServices(
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
    if let xaiBrowserLogin {
        services.xaiBrowserLogin = xaiBrowserLogin
    }
    return services
}

/// Hermeticity pins for the xAI flow (the Wave 14.1 rule): the issuer — the
/// only endpoint env the flow reads — points at a dead loopback port, and
/// the constructed dictionary carries no `GROK_OIDC_*`, `GROK_LOCAL_AUTH`,
/// `XAI_API_KEY`, or `OPENGROK_AUTH*`.
private let xaiPinnedEnvironment: [String: String] = [
    "GROK_OAUTH2_ISSUER": "http://127.0.0.1:9",
    "GROK_OAUTH2_CLIENT_ID": "pager-client",
]

/// Scripted xAI IdP: discovery + JWKS + token exchange. The id_token is
/// RS256-signed against the JWKS this transport serves — browser login now
/// requires JWKS validation before persist (`protocol.rs:639-715`).
private final class PagerXAIIdPTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var nonce: String?
    private let rsa: OIDCTestJWTFixture.RSAFixture
    private let issuer = "http://127.0.0.1:9"
    private let clientID = "pager-client"

    init() throws {
        rsa = try OIDCTestJWTFixture.rsa()
    }

    func setNonce(_ value: String?) {
        lock.lock(); nonce = value; lock.unlock()
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let path = request.url.path
        if path.hasSuffix("/.well-known/openid-configuration") {
            let body = OIDCTestJWTFixture.discoveryJSON(
                issuer: issuer,
                jwksURI: "\(issuer)/jwks",
                supportedAlgs: ["RS256"]
            )
            return HTTPResponse(
                metadata: HTTPResponseMetadata(statusCode: 200),
                body: Data(body.utf8)
            )
        }
        if path.hasSuffix("/jwks") {
            let body = OIDCTestJWTFixture.rsaJWKSJSON(n: rsa.jwkN, e: rsa.jwkE)
            return HTTPResponse(
                metadata: HTTPResponseMetadata(statusCode: 200),
                body: Data(body.utf8)
            )
        }
        if path.hasSuffix("/token") {
            let currentNonce = lock.withLock { nonce ?? "" }
            var claims = OIDCTestJWTFixture.personalClaims(
                nonce: currentNonce,
                issuer: issuer,
                clientID: clientID
            )
            claims["sub"] = "user-7"
            claims["email"] = "tui@x.ai"
            let idToken = try OIDCTestJWTFixture.signRS256(
                payload: claims,
                privateKey: rsa.privateKey
            )
            let body = """
            {"access_token":"pager-xai-access","refresh_token":"pager-xai-refresh",\
            "expires_in":3600,"id_token":"\(idToken)"}
            """
            return HTTPResponse(
                metadata: HTTPResponseMetadata(statusCode: 200),
                body: Data(body.utf8)
            )
        }
        return HTTPResponse(
            metadata: HTTPResponseMetadata(statusCode: 404),
            body: Data()
        )
    }

    func stream(_ request: HTTPRequest) -> AsyncThrowingStream<HTTPStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let response = try await send(request)
                    continuation.yield(.metadata(response.metadata))
                    continuation.yield(.body(response.body))
                    continuation.yield(.end)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

/// Build the callback for the xAI flow after the test has observed the exact
/// authorization URL on the typed trust screen.
private func xaiCallbackURL(
    for authURL: URL,
    transport: PagerXAIIdPTransport
) -> URL? {
    guard let components = URLComponents(url: authURL, resolvingAgainstBaseURL: false),
          let items = components.queryItems else { return nil }
    let value = { (name: String) in items.first(where: { $0.name == name })?.value }
    transport.setNonce(value("nonce"))
    guard let redirect = value("redirect_uri"),
          let redirectURL = URL(string: redirect),
          let port = redirectURL.port,
          let state = value("state")
    else { return nil }
    return URL(string: "http://127.0.0.1:\(port)/callback?code=mock-code&state=\(state)")
}

private func codexCallbackURL(for authURL: URL) -> URL? {
    guard let components = URLComponents(url: authURL, resolvingAgainstBaseURL: false),
          let redirect = components.queryItems?
            .first(where: { $0.name == "redirect_uri" })?.value,
          let state = components.queryItems?
            .first(where: { $0.name == "state" })?.value,
          let redirectURL = URL(string: redirect),
          let port = redirectURL.port
    else { return nil }
    return URL(string: "http://127.0.0.1:\(port)/auth/callback?code=mock-code&state=\(state)")
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
        #expect(statuses["zai"] == .missing)

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
            "DeepSeek", "Meta API", "OpenCode Go", "Wafer AI", "Z AI",
        ])
        #expect(list.rows.map(\.id) == [
            "xai", "codex", "kimi", "fireworks",
            "deepseek", "meta", "opencode-go", "wafer", "zai",
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

    @Test("selecting the xAI row hands back the typed form that starts the flow")
    func pickerSelectsXAIRow() async throws {
        let fixture = try AuthRendererFixture(
            authServices: fakeAuthServices(transport: MockHTTPTransport())
        )
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        try await fixture.renderer.render(.overlay(.loginProviderPicker))
        #expect(await fixture.waitForFrame(containing: "Grok"))

        // Row 0 IS the xAI row; its "Sign in with xAI" description is now
        // literal — the controller routes the returned typed form to
        // `.overlay(.loginXAI)`, which runs the browser flow (no more
        // CLI-route notice).
        let selected = try await fixture.renderer.handleInput(
            .key(KeyEvent(key: .enter))
        )
        #expect(selected == .runCommand("/login xai"))
        try await fixture.renderer.restoreTerminal()
    }
}

// MARK: - xAI login flow

@Suite("Live /login xai browser flow", .serialized)
struct LiveXAILoginFlowTests {
    @Test("the xai flow runs against the real listener and lands in the real auth.json")
    func xaiFlowLandsCredentials() async throws {
        let transport = try PagerXAIIdPTransport()
        let browser = CapturedAuthBrowser()
        // A catalog store so the post-login refresh pair is observable at its
        // own seam. Hermetic: no provider key env, so every background
        // partition skips before any network I/O.
        let storeHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-xai-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storeHome) }
        let catalogStore = LiveModelCatalogStore(
            input: liveCatalogResolutionInput(
                workingDirectory: storeHome,
                environment: xaiPinnedEnvironment
            ),
            environment: xaiPinnedEnvironment,
            openGrokHome: storeHome
        )
        let fixture = try AuthRendererFixture(
            extraEnvironment: xaiPinnedEnvironment,
            authServices: fakeAuthServices(
                transport: transport,
                openBrowser: { browser.open($0) }
            ),
            catalogStore: catalogStore
        )
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        try await fixture.renderer.render(.overlay(.loginXAI))

        let authURL = try #require(await browser.waitForURL())
        #expect(await fixture.waitForAuthState { state in
            state?.phase == .trust && state?.url == authURL.absoluteString
        })
        let callbackURL = try #require(xaiCallbackURL(for: authURL, transport: transport))
        URLSession.shared.dataTask(with: callbackURL).resume()

        // Completion: the credential is in the REAL store file under the
        // OAuth scope, and the connected copy is the CLI's `report_signed_in`
        // (auth/flow.rs:872-878).
        let xaiFile = fixture.xaiAuthFile
        #expect(await fixture.wait {
            (try? String(contentsOf: xaiFile, encoding: .utf8))?
                .contains("pager-xai-access") == true
        })
        // Parse, don't substring: the auth encoder escapes forward slashes
        // (JSON "http:\/\/…"), so a raw contains() on the scope key can
        // never match the file bytes.
        let storeKeys = (try JSONSerialization.jsonObject(
            with: Data(contentsOf: xaiFile)
        ) as? [String: Any])?.keys.sorted() ?? []
        #expect(storeKeys.contains("http://127.0.0.1:9::pager-client"))
        #expect(await fixture.waitForAuthState { state in
            state?.phase == .starting && state?.message?.contains("tui@x.ai") == true
        })

        // The post-login pair fired: the background catalog refresh task
        // exists (the codex arm's effects/mod.rs:1690-1699 equivalent).
        #expect(await fixture.wait { catalogStore.backgroundRefreshTask != nil })
        await catalogStore.backgroundRefreshTask?.value

        // Round-trip: `/logout` clears exactly what this flow wrote.
        try await fixture.renderer.render(.overlay(.logout(account: .xai)))
        #expect(await fixture.wait {
            !FileManager.default.fileExists(atPath: xaiFile.path)
        })
        try await fixture.renderer.restoreTerminal()
    }

    @Test("a second /login xai while one flow is pending is refused, single-flight")
    func pendingXAIFlowIsSingleFlight() async throws {
        let counter = FlowCounter()
        let blockedFlow: LivePagerAuthServices.XAILoginFlow = { _, _, _, _ in
            await counter.increment()
            // Park long enough for the second dispatch to hit the guard.
            try await Task.sleep(nanoseconds: 5_000_000_000)
            throw CancellationError()
        }
        let fixture = try AuthRendererFixture(
            extraEnvironment: xaiPinnedEnvironment,
            authServices: fakeAuthServices(
                transport: MockHTTPTransport(),
                xaiBrowserLogin: blockedFlow
            )
        )
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        try await fixture.renderer.render(.overlay(.loginXAI))
        try await fixture.renderer.render(.overlay(.loginXAI))

        #expect(await fixture.waitForFrame(containing: "progress"))
        // Bounded poll before the read: the spawned flow's increment races a
        // one-shot read under parallel-suite load (the D1 lesson).
        let deadline = Date().addingTimeInterval(5)
        while await counter.started < 1, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await counter.started == 1)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("a failed flow reports upstream's failure copy")
    func failureArmCarriesUpstreamCopy() async throws {
        // The timeout arm: `OidcError::CallbackTimeout`'s display text inside
        // the TUI failure format (task_result.rs:3231).
        let failingFlow: LivePagerAuthServices.XAILoginFlow = { _, _, _, _ in
            throw XAILoginFlowError.callbackTimeout
        }
        let fixture = try AuthRendererFixture(
            extraEnvironment: xaiPinnedEnvironment,
            authServices: fakeAuthServices(
                transport: MockHTTPTransport(),
                xaiBrowserLogin: failingFlow
            )
        )
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        try await fixture.renderer.render(.overlay(.loginXAI))

        // "xAI Grok login failed: Login timed out after 10 minutes. Please
        // try again." — single-token needles.
        #expect(await fixture.waitForFrame(containing: "failed:"))
        #expect(await fixture.waitForFrame(containing: "timed"))
        #expect(!FileManager.default.fileExists(atPath: fixture.xaiAuthFile.path))
        try await fixture.renderer.restoreTerminal()
    }
}

// MARK: - Codex login flow

@Suite("Live /login codex browser flow", .serialized)
struct LiveCodexLoginFlowTests {
    @Test("the codex flow runs against the real listener and lands credentials on disk")
    func codexFlowLandsCredentials() async throws {
        let browser = CapturedAuthBrowser()
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
        let fixture = try AuthRendererFixture(
            authServices: fakeAuthServices(
                transport: transport,
                openBrowser: { browser.open($0) }
            )
        )
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        try await fixture.renderer.render(.overlay(.loginCodex))

        let authURL = try #require(await browser.waitForURL())
        #expect(await fixture.waitForAuthState { state in
            state?.phase == .trust && state?.url == authURL.absoluteString
        })
        let callbackURL = try #require(codexCallbackURL(for: authURL))
        URLSession.shared.dataTask(with: callbackURL).resume()
        // Completion: the store is real and the notice carries the account
        // (`task_result.rs:3853-3869`).
        let codexFile = fixture.codexAuthFile
        #expect(await fixture.wait { isCodexLoggedIn(at: codexFile) })
        #expect(await fixture.waitForAuthState { state in
            state?.phase == .starting && state?.message?.contains("tui@openai.com") == true
        })
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

#endif /* canImport(CryptoKit) && canImport(Security) */
