// LiveAuthCompositionTests.swift
//
// Command-level behavior of `open-grok login` / `open-grok logout` with an
// injected auth service. No browser, socket, terminal, or network is touched,
// and every case runs against an isolated OPENGROK_HOME under the system temp
// directory so the developer's real ~/.opengrok is never read or written.

import Foundation
import Testing
@testable import OpenGrokCLI
import OpenGrokAuth
import OpenGrokHTTP

private struct AuthCommandFixture {
    let home: URL
    let environment: [String: String]

    var authFile: URL { home.appendingPathComponent(OpenGrokAuthPaths.authFileName) }
    var codexFile: URL { home.appendingPathComponent(OpenGrokAuthPaths.codexAuthFileName) }

    init(extraEnvironment: [String: String] = [:]) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-auth-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        home = root
        var env = extraEnvironment
        env["OPENGROK_HOME"] = root.path
        env["HOME"] = root.path
        environment = env
    }

    func dispose() {
        try? FileManager.default.removeItem(at: home)
    }

    func writeCodexCredentials(account: String = "acct-1") throws {
        let idToken = buildTestJWT(payload: [
            "email": "person@openai.com",
            "https://api.openai.com/auth": [
                "chatgpt_account_id": account,
                "chatgpt_plan_type": "plus",
                "chatgpt_user_id": "user-1",
            ],
            "exp": Int(Date().addingTimeInterval(3600).timeIntervalSince1970),
        ])
        let access = buildTestJWT(payload: [
            "exp": Int(Date().addingTimeInterval(3600).timeIntervalSince1970),
        ])
        try persistCodexTokens(
            at: codexFile,
            idToken: idToken,
            accessToken: access,
            refreshToken: "codex-refresh",
            accountID: account
        )
    }
}

/// Records which Codex flow ran and persists a canned credential set.
private final class CodexFlowRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var flows: [String] = []
    private var browserFailure: AuthError?

    init(browserFailure: AuthError? = nil) {
        self.browserFailure = browserFailure
    }

    var invokedFlows: [String] {
        lock.lock()
        defer { lock.unlock() }
        return flows
    }

    func record(_ name: String) {
        lock.lock()
        flows.append(name)
        lock.unlock()
    }

    var services: LiveAuthServices {
        let recorder = self
        let failure = browserFailure
        return LiveAuthServices(
            makeTransport: { MockHTTPTransport(responses: []) },
            codexBrowserLogin: { authFile, _, _, openBrowser in
                recorder.record("browser")
                openBrowser?(URL(string: "https://auth.example/oauth/authorize")!)
                if let failure { throw failure }
                return try CodexFlowRecorder.persist(at: authFile)
            },
            codexDeviceLogin: { authFile, _, _, _ in
                recorder.record("device")
                return try CodexFlowRecorder.persist(at: authFile)
            },
            openBrowser: nil,
            readSecretLine: { nil },
            isInteractive: { false }
        )
    }

    private static func persist(at authFile: URL) throws -> CodexCredentials {
        let idToken = buildTestJWT(payload: [
            "email": "person@openai.com",
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct-1",
                "chatgpt_plan_type": "plus",
                "chatgpt_user_id": "user-1",
            ],
            "exp": Int(Date().addingTimeInterval(3600).timeIntervalSince1970),
        ])
        try persistCodexTokens(
            at: authFile,
            idToken: idToken,
            accessToken: buildTestJWT(payload: [
                "exp": Int(Date().addingTimeInterval(3600).timeIntervalSince1970),
            ]),
            refreshToken: "codex-refresh",
            accountID: "acct-1"
        )
        guard let credentials = try loadCodexCredentials(at: authFile) else {
            throw AuthError.storage("test fixture failed to persist codex tokens")
        }
        return credentials
    }
}

private func authOptions(_ name: String, values: [String] = [], flags: [String] = [], json: Bool = false) -> CLIUtilityOptions {
    var options: [String: String] = [:]
    for flag in flags {
        options[flag] = "true"
    }
    return CLIUtilityOptions(name: name, values: values, options: options, json: json)
}

@Suite("Live auth composition")
struct LiveAuthCompositionTests {
    @Test("bare login stores an xAI API key and leaves the codex store absent")
    func loginXAIWithPositionalKey() async throws {
        let fixture = try AuthCommandFixture()
        defer { fixture.dispose() }
        let (streams, out, err) = CLIStreams.buffered()

        try await LiveAuthComposition.run(
            options: authOptions("login", values: ["xai-cli-key"]),
            environment: fixture.environment,
            streams: streams,
            services: CodexFlowRecorder().services
        )

        #expect(readAPIKey(grokHome: fixture.home) == "xai-cli-key")
        #expect(!FileManager.default.fileExists(atPath: fixture.codexFile.path))
        #expect(out.contents.contains("Signed in to xAI"))
        #expect(out.contents.contains("xAI: authenticated"))
        #expect(out.contents.contains("Codex: not authenticated"))
        #expect(err.contents.isEmpty)
        // The stored key never appears in the transcript.
        #expect(!out.contents.contains("xai-cli-key"))
    }

    @Test("login reads XAI_API_KEY when no key is passed")
    func loginXAIFromEnvironment() async throws {
        let fixture = try AuthCommandFixture(extraEnvironment: ["XAI_API_KEY": "env-key"])
        defer { fixture.dispose() }
        let (streams, _, _) = CLIStreams.buffered()

        try await LiveAuthComposition.run(
            options: authOptions("login"),
            environment: fixture.environment,
            streams: streams,
            services: CodexFlowRecorder().services
        )
        #expect(readAPIKey(grokHome: fixture.home) == "env-key")
    }

    @Test("non-interactive login without a key fails with guidance")
    func loginXAIWithoutKeyFails() async throws {
        let fixture = try AuthCommandFixture()
        defer { fixture.dispose() }
        let (streams, _, _) = CLIStreams.buffered()

        await #expect(throws: CLIApplicationError.self) {
            try await LiveAuthComposition.run(
                options: authOptions("login"),
                environment: fixture.environment,
                streams: streams,
                services: CodexFlowRecorder().services
            )
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.authFile.path))
    }

    @Test("login --codex runs the browser flow and writes only codex-auth.json")
    func loginCodexUsesBrowserFlow() async throws {
        let fixture = try AuthCommandFixture()
        defer { fixture.dispose() }
        let recorder = CodexFlowRecorder()
        let (streams, out, _) = CLIStreams.buffered()

        try await LiveAuthComposition.run(
            options: authOptions("login", flags: ["--codex"]),
            environment: fixture.environment,
            streams: streams,
            services: recorder.services
        )

        #expect(recorder.invokedFlows == ["browser"])
        #expect(isCodexLoggedIn(at: fixture.codexFile))
        #expect(!FileManager.default.fileExists(atPath: fixture.authFile.path))
        #expect(out.contents.contains("Signed in to Codex as person@openai.com"))
        #expect(out.contents.contains("https://auth.example/oauth/authorize"))
    }

    @Test("login --codex falls back to the device flow when the browser flow fails")
    func loginCodexFallsBackToDeviceFlow() async throws {
        let fixture = try AuthCommandFixture()
        defer { fixture.dispose() }
        let recorder = CodexFlowRecorder(
            browserFailure: AuthError.protocolError("could not bind callback listener")
        )
        let (streams, _, err) = CLIStreams.buffered()

        try await LiveAuthComposition.run(
            options: authOptions("login", flags: ["--codex"]),
            environment: fixture.environment,
            streams: streams,
            services: recorder.services
        )

        #expect(recorder.invokedFlows == ["browser", "device"])
        #expect(isCodexLoggedIn(at: fixture.codexFile))
        #expect(err.contents.contains("falling back to the device code flow"))
    }

    @Test("login --codex --device-code skips the browser flow entirely")
    func loginCodexHonorsDeviceCodeFlag() async throws {
        let fixture = try AuthCommandFixture()
        defer { fixture.dispose() }
        let recorder = CodexFlowRecorder()
        let (streams, _, _) = CLIStreams.buffered()

        try await LiveAuthComposition.run(
            options: authOptions("login", flags: ["--codex", "--device-code"]),
            environment: fixture.environment,
            streams: streams,
            services: recorder.services
        )
        #expect(recorder.invokedFlows == ["device"])
    }

    @Test("logout --codex clears only the codex store")
    func logoutCodexOnly() async throws {
        let fixture = try AuthCommandFixture()
        defer { fixture.dispose() }
        try storeAPIKey(grokHome: fixture.home, apiKey: "xai-key")
        try fixture.writeCodexCredentials()
        let (streams, out, _) = CLIStreams.buffered()

        try await LiveAuthComposition.run(
            options: authOptions("logout", flags: ["--codex"]),
            environment: fixture.environment,
            streams: streams,
            services: CodexFlowRecorder().services
        )

        #expect(!isCodexLoggedIn(at: fixture.codexFile))
        #expect(readAPIKey(grokHome: fixture.home) == "xai-key")
        #expect(out.contents.contains("Signed out of Codex"))
        #expect(out.contents.contains("xAI: authenticated"))
    }

    @Test("bare logout clears only the xAI store")
    func logoutXAIOnly() async throws {
        let fixture = try AuthCommandFixture()
        defer { fixture.dispose() }
        try storeAPIKey(grokHome: fixture.home, apiKey: "xai-key")
        try fixture.writeCodexCredentials()
        let (streams, out, _) = CLIStreams.buffered()

        try await LiveAuthComposition.run(
            options: authOptions("logout"),
            environment: fixture.environment,
            streams: streams,
            services: CodexFlowRecorder().services
        )

        #expect(readAPIKey(grokHome: fixture.home) == nil)
        #expect(isCodexLoggedIn(at: fixture.codexFile))
        #expect(out.contents.contains("Codex: authenticated"))
    }

    @Test("logout all clears both stores independently")
    func logoutAllClearsBoth() async throws {
        let fixture = try AuthCommandFixture()
        defer { fixture.dispose() }
        try storeAPIKey(grokHome: fixture.home, apiKey: "xai-key")
        try fixture.writeCodexCredentials()
        let (streams, out, _) = CLIStreams.buffered()

        try await LiveAuthComposition.run(
            options: authOptions("logout", values: ["all"]),
            environment: fixture.environment,
            streams: streams,
            services: CodexFlowRecorder().services
        )

        #expect(readAPIKey(grokHome: fixture.home) == nil)
        #expect(!isCodexLoggedIn(at: fixture.codexFile))
        #expect(out.contents.contains("xAI: not authenticated"))
        #expect(out.contents.contains("Codex: not authenticated"))
    }

    @Test("--all and --codex together are refused")
    func conflictingTargetsAreRefused() throws {
        #expect(throws: CLIApplicationError.self) {
            _ = try LiveAuthComposition.target(
                for: authOptions("logout", flags: ["--all", "--codex"])
            )
        }
    }

    @Test("--json emits machine-readable status with no secrets")
    func jsonStatusOutput() async throws {
        let fixture = try AuthCommandFixture()
        defer { fixture.dispose() }
        try fixture.writeCodexCredentials()
        let (streams, out, _) = CLIStreams.buffered()

        try await LiveAuthComposition.run(
            options: authOptions("login", values: ["xai-cli-key"], json: true),
            environment: fixture.environment,
            streams: streams,
            services: CodexFlowRecorder().services
        )

        let json = out.contents
        #expect(json.contains("\"authenticated\":true"))
        #expect(json.contains("\"source\":\"oauth\""))
        #expect(!json.contains("xai-cli-key"))
        #expect(!json.contains("codex-refresh"))
    }

    @Test("status reflects an isolated home with no credentials")
    func statusOnEmptyHome() throws {
        let fixture = try AuthCommandFixture()
        defer { fixture.dispose() }
        let status = LiveAuthComposition.status(environment: fixture.environment)
        #expect(!status.xai.authenticated)
        #expect(!status.codex.authenticated)
        #expect(LiveAuthComposition.statusLines(environment: fixture.environment)
            .allSatisfy { $0.contains("not authenticated") })
    }

    @Test("the launcher only claims the login and logout routes")
    func handlesOnlyAuthRoutes() {
        #expect(LiveAuthComposition.handles(.utility(authOptions("login"))))
        #expect(LiveAuthComposition.handles(.utility(authOptions("logout"))))
        #expect(!LiveAuthComposition.handles(.utility(authOptions("update"))))
        #expect(!LiveAuthComposition.handles(.doctor))
    }
}
