import Foundation
import OpenGrokAuth
import OpenGrokConfigTypes
import OpenGrokHTTP
import OpenGrokPager
import OpenGrokPagerRender
import Testing
@testable import OpenGrokCLI

private final class ForcedAuthenticationSink: PagerTerminalSink, @unchecked Sendable {
    var capabilities: PagerTerminalCapabilities { .standard }
    func write(bytes: [UInt8]) throws {}
    func flush() throws {}
}

private final class ForcedAuthenticationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var xaiCount = 0
    private var codexCount = 0
    private var openerCount = 0

    var counts: (xai: Int, codex: Int, browser: Int) {
        lock.withLock { (xaiCount, codexCount, openerCount) }
    }

    func recordXAI() { lock.withLock { xaiCount += 1 } }
    func recordCodex() { lock.withLock { codexCount += 1 } }
    func recordBrowser() { lock.withLock { openerCount += 1 } }
}

private struct ForcedAuthenticationFixture {
    let root: URL
    let home: URL
    let environment: [String: String]
    let recorder: ForcedAuthenticationRecorder
    let renderer: LiveInteractiveControllerRenderer

    init(
        provider: String? = nil,
        replacement: GrokAuth? = nil,
        failure: (any Error & Sendable)? = nil
    ) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "open-grok-forced-auth-\(UUID().uuidString)",
            isDirectory: true
        )
        home = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        environment = [
            "HOME": root.path,
            "OPENGROK_HOME": home.path,
            "GROK_MANAGED_CONFIG": "false",
        ]

        let recorder = ForcedAuthenticationRecorder()
        self.recorder = recorder
        let transport = MockHTTPTransport()
        let resolved = replacement ?? ForcedAuthenticationFixture.auth(
            userID: "replacement-user",
            principal: "replacement-team"
        )
        let services = LivePagerAuthServices(
            makeTransport: { transport },
            codexBrowserLogin: { _, _, _, _ in
                recorder.recordCodex()
                throw AuthError.notLoggedIn
            },
            xaiBrowserLogin: { manager, _, _, _ in
                recorder.recordXAI()
                if let failure { throw failure }
                try await manager.loginWithSession(resolved)
                return resolved
            },
            openBrowser: { _ in recorder.recordBrowser() }
        )
        let terminal = OpenGrokLiveTerminal(
            isTTY: { true },
            size: { OpenGrokLiveTerminalSize(width: 100, height: 30) },
            write: { _ in }
        )
        renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: terminal,
            sink: ForcedAuthenticationSink(),
            workingDirectory: root.path,
            modelName: provider == "codex" ? "gpt-5.6" : "grok-4.6",
            openGrokHome: home,
            environment: environment,
            authServices: services
        )
    }

    func dispose() {
        LiveManagedPolicyLifecycle.stop(environment: environment)
        try? FileManager.default.removeItem(at: root)
    }

    func options(
        forceLogin: Bool = true,
        mode: CLIRunMode = .interactive,
        provider: String? = nil,
        leader: Bool = false
    ) -> CLIExecutionOptions {
        CLIExecutionOptions(
            mode: mode,
            common: CLICommonOptions(provider: provider, leader: leader),
            advanced: CLIAdvancedOptions(forceLogin: forceLogin)
        )
    }

    var authFile: URL { home.appendingPathComponent("auth.json") }
    var codexFile: URL { home.appendingPathComponent("codex-auth.json") }

    static func auth(
        userID: String,
        principal: String,
        zdr: Bool = false
    ) -> GrokAuth {
        GrokAuth(
            key: buildTestJWT(payload: [
                "sub": userID,
                "principal_type": "Team",
                "principal_id": principal,
                "exp": 9_999_999_999,
            ]),
            authMode: .oidc,
            userID: userID,
            principalType: "Team",
            principalID: principal,
            teamID: principal,
            teamBlockedReasons: zdr ? ["BLOCKED_REASON_NO_LOGS"] : [],
            codingDataRetentionOptOut: true,
            expiresAt: Date().addingTimeInterval(3600),
            oidcIssuer: xaiOAuth2Issuer,
            oidcClientID: defaultOAuth2ClientID
        )
    }

    func persist(_ auth: GrokAuth) throws {
        let config = try LiveAuthComposition.effectiveGrokComConfig(environment: environment)
        try writeAuthJSON(at: authFile, store: [config.authScope: auth])
    }

    func awaitLogin() async {
        if let task = await renderer.xaiLoginTask {
            await task.value
        }
    }
}

@Suite("Forced interactive xAI authentication parity", .serialized)
struct LiveForcedAuthenticationParityTests {
    @Test("interactive force-login starts the real xAI renderer flow and replaces credentials")
    func forceLoginStartsRealXAIRendererFlow() async throws {
        let fixture = try ForcedAuthenticationFixture()
        defer { fixture.dispose() }
        try fixture.persist(ForcedAuthenticationFixture.auth(
            userID: "previous-user",
            principal: "previous-team"
        ))

        try await LiveForcedAuthentication.startIfRequested(
            options: fixture.options(),
            renderer: fixture.renderer,
            interactiveSurfaceAvailable: true,
            remoteSettings: nil
        )
        await fixture.awaitLogin()

        let counts = fixture.recorder.counts
        #expect(counts.xai == 1)
        #expect(counts.codex == 0)
        #expect(counts.browser == 0)
        let store = try readAuthJSON(at: fixture.authFile)
        #expect(store.count == 1)
        #expect(store.values.first?.userID == "replacement-user")
    }

    @Test("force-login stays first-party even when the selected model and account are Codex")
    func codexSelectionNeverInvokesOrChangesCodexAuthentication() async throws {
        let fixture = try ForcedAuthenticationFixture(provider: "codex")
        defer { fixture.dispose() }
        let codexBytes = Data("independent-codex-account".utf8)
        try codexBytes.write(to: fixture.codexFile)

        try await LiveForcedAuthentication.startIfRequested(
            options: fixture.options(provider: "codex"),
            renderer: fixture.renderer,
            interactiveSurfaceAvailable: true,
            remoteSettings: nil
        )
        await fixture.awaitLogin()

        #expect(fixture.recorder.counts.xai == 1)
        #expect(fixture.recorder.counts.codex == 0)
        #expect(try Data(contentsOf: fixture.codexFile) == codexBytes)
    }

    @Test("normal interactive launches never start browser or provider authentication")
    func unrequestedLoginHasNoSideEffects() async throws {
        let fixture = try ForcedAuthenticationFixture()
        defer { fixture.dispose() }

        try await LiveForcedAuthentication.startIfRequested(
            options: fixture.options(forceLogin: false),
            renderer: fixture.renderer,
            interactiveSurfaceAvailable: false,
            remoteSettings: nil
        )

        #expect(fixture.recorder.counts.xai == 0)
        #expect(fixture.recorder.counts.codex == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.authFile.path))
    }

    @Test("missing terminal surface fails closed without browser or credential mutation")
    func unavailableSurfaceCannotAuthenticate() async throws {
        let fixture = try ForcedAuthenticationFixture()
        defer { fixture.dispose() }
        try fixture.persist(ForcedAuthenticationFixture.auth(
            userID: "preserved-user",
            principal: "preserved-team"
        ))
        let original = try Data(contentsOf: fixture.authFile)

        do {
            try LiveForcedAuthentication.validateSurface(
                options: fixture.options(),
                interactiveSurfaceAvailable: false
            )
            Issue.record("expected missing interactive surface to reject forced login")
        } catch let error as CLIApplicationError {
            #expect(String(describing: error).contains("interactive terminal"))
        }

        #expect(fixture.recorder.counts.xai == 0)
        #expect(fixture.recorder.counts.browser == 0)
        #expect(try Data(contentsOf: fixture.authFile) == original)
    }

    @Test("headless and leader launches never initiate hidden browser authentication")
    func unsupportedSurfacesRemainFailClosed() throws {
        let fixture = try ForcedAuthenticationFixture()
        defer { fixture.dispose() }

        for options in [
            fixture.options(mode: .headless),
            fixture.options(leader: true),
        ] {
            do {
                try LiveForcedAuthentication.validateSurface(
                    options: options,
                    interactiveSurfaceAvailable: true
                )
                Issue.record("expected unsupported forced-login surface to fail closed")
            } catch is CLIApplicationError {}
        }

        #expect(fixture.recorder.counts.xai == 0)
        #expect(fixture.recorder.counts.codex == 0)
    }

    @Test("an administrator account gate blocks login before any browser flow")
    func remoteAccountGatePreventsAuthentication() async throws {
        let fixture = try ForcedAuthenticationFixture()
        defer { fixture.dispose() }
        var remote = RemoteSettings()
        remote.gateMessage = "Administrator access is disabled."

        do {
            try await LiveForcedAuthentication.startIfRequested(
                options: fixture.options(),
                renderer: fixture.renderer,
                interactiveSurfaceAvailable: true,
                remoteSettings: remote
            )
            Issue.record("expected authenticated remote account gate to reject login")
        } catch let error as CLIApplicationError {
            #expect(String(describing: error).contains("Administrator access is disabled"))
        }

        #expect(fixture.recorder.counts.xai == 0)
        #expect(fixture.recorder.counts.browser == 0)
    }

    @Test("zero-data-retention policy remains closed unless remote access explicitly permits it")
    func zdrAccountPolicyCannotBeBypassedByForcedLogin() async throws {
        let fixture = try ForcedAuthenticationFixture()
        defer { fixture.dispose() }
        try fixture.persist(ForcedAuthenticationFixture.auth(
            userID: "private-user",
            principal: "private-team",
            zdr: true
        ))
        let original = try Data(contentsOf: fixture.authFile)

        do {
            try await LiveForcedAuthentication.startIfRequested(
                options: fixture.options(),
                renderer: fixture.renderer,
                interactiveSurfaceAvailable: true,
                remoteSettings: nil
            )
            Issue.record("expected the ZDR account restriction to reject forced login")
        } catch let error as CLIApplicationError {
            #expect(String(describing: error).contains("zero-data-retention"))
        }

        #expect(fixture.recorder.counts.xai == 0)
        #expect(try Data(contentsOf: fixture.authFile) == original)
    }

    @Test("authenticated remote ZDR permission allows first-party login without weakening privacy")
    func authorizedZDRAccountCanReplaceItsSession() async throws {
        let fixture = try ForcedAuthenticationFixture()
        defer { fixture.dispose() }
        try fixture.persist(ForcedAuthenticationFixture.auth(
            userID: "private-user",
            principal: "private-team",
            zdr: true
        ))
        var remote = RemoteSettings()
        remote.zdrAccessEnabled = true

        try await LiveForcedAuthentication.startIfRequested(
            options: fixture.options(),
            renderer: fixture.renderer,
            interactiveSurfaceAvailable: true,
            remoteSettings: remote
        )
        await fixture.awaitLogin()

        #expect(fixture.recorder.counts.xai == 1)
        #expect(fixture.recorder.counts.codex == 0)
        #expect(try readAuthJSON(at: fixture.authFile).values.first?.userID == "replacement-user")
    }

    @Test("failed reauthentication retains the previous usable xAI and Codex credentials")
    func authenticationFailureNeverClearsExistingAccounts() async throws {
        let fixture = try ForcedAuthenticationFixture(failure: AuthError.notLoggedIn)
        defer { fixture.dispose() }
        try fixture.persist(ForcedAuthenticationFixture.auth(
            userID: "preserved-user",
            principal: "preserved-team"
        ))
        let previousXAI = try Data(contentsOf: fixture.authFile)
        let previousCodex = Data("preserved-codex-account".utf8)
        try previousCodex.write(to: fixture.codexFile)

        try await LiveForcedAuthentication.startIfRequested(
            options: fixture.options(),
            renderer: fixture.renderer,
            interactiveSurfaceAvailable: true,
            remoteSettings: nil
        )
        await fixture.awaitLogin()

        #expect(fixture.recorder.counts.xai == 1)
        #expect(fixture.recorder.counts.codex == 0)
        #expect(try Data(contentsOf: fixture.authFile) == previousXAI)
        #expect(try Data(contentsOf: fixture.codexFile) == previousCodex)
    }

    @Test("signed replacement principals must satisfy the existing administrator team pin")
    func managedTeamMismatchPreservesTheUsableCredential() async throws {
        let fixture = try ForcedAuthenticationFixture()
        defer { fixture.dispose() }
        try "[auth]\nforce_login_team_uuid = \"required-team\"\n".write(
            to: fixture.home.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
        try fixture.persist(ForcedAuthenticationFixture.auth(
            userID: "previous-user",
            principal: "required-team"
        ))
        let original = try Data(contentsOf: fixture.authFile)

        try await LiveForcedAuthentication.startIfRequested(
            options: fixture.options(),
            renderer: fixture.renderer,
            interactiveSurfaceAvailable: true,
            remoteSettings: nil
        )
        await fixture.awaitLogin()

        #expect(fixture.recorder.counts.xai == 1)
        #expect(try Data(contentsOf: fixture.authFile) == original)
        #expect(try readAuthJSON(at: fixture.authFile).values.first?.principalID == "required-team")
    }

    @Test("empty managed team allowlists fail closed before an xAI browser is opened")
    func impossibleManagedTeamPinStartsNoAuthFlow() async throws {
        let fixture = try ForcedAuthenticationFixture()
        defer { fixture.dispose() }
        try "[auth]\nforce_login_team_uuid = []\n".write(
            to: fixture.home.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )

        do {
            try await LiveForcedAuthentication.startIfRequested(
                options: fixture.options(),
                renderer: fixture.renderer,
                interactiveSurfaceAvailable: true,
                remoteSettings: nil
            )
            Issue.record("expected empty managed team allowlist to reject startup")
        } catch let error as AuthError {
            guard case .pinnedTeamMismatch = error else {
                Issue.record("unexpected authentication error: \(error)")
                return
            }
        }

        #expect(fixture.recorder.counts.xai == 0)
        #expect(fixture.recorder.counts.browser == 0)
    }
}
