// CodexCredentialProviderTests.swift
//
// Hermetic coverage for the Codex `AuthCredentialProvider` adapter: store
// isolation from auth.json, refresh-on-expiry through an injected transport,
// fail-closed behavior on account drift, and no stale-token fallback.

import Foundation
import Testing
@testable import OpenGrokAuth
import OpenGrokHTTP

private func codexProviderTempHome() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("opengrok-codex-provider-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func codexIDToken(
    account: String = "acct-1",
    user: String = "user-1",
    email: String = "person@openai.com",
    plan: String = "plus"
) -> String {
    buildTestJWT(payload: [
        "email": email,
        "https://api.openai.com/auth": [
            "chatgpt_account_id": account,
            "chatgpt_plan_type": plan,
            "chatgpt_user_id": user,
        ],
        "exp": Int(Date().addingTimeInterval(3600).timeIntervalSince1970),
    ])
}

private func expiredAccessToken() -> String {
    buildTestJWT(payload: [
        "exp": Int(Date().addingTimeInterval(-120).timeIntervalSince1970),
    ])
}

private func freshAccessToken() -> String {
    buildTestJWT(payload: [
        "exp": Int(Date().addingTimeInterval(3600).timeIntervalSince1970),
    ])
}

@Suite("Codex credential provider")
struct CodexCredentialProviderTests {
    @Test("provider never reads the xAI store")
    func neverReadsAuthJSON() throws {
        let home = try codexProviderTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try storeAPIKey(grokHome: home, apiKey: "xai-only-key")

        let codexPath = home.appendingPathComponent(OpenGrokAuthPaths.codexAuthFileName)
        let provider = CodexAuthCredentialProvider(authFile: codexPath)

        #expect(!provider.hasUsableCredential())
        #expect(provider.snapshot().token == nil)

        var headers = ["Authorization": "Bearer leftover", "ChatGPT-Account-ID": "stale"]
        provider.apply(to: &headers, baseURL: "https://chatgpt.com")
        #expect(headers["Authorization"] == nil)
        #expect(headers["ChatGPT-Account-ID"] == nil)

        // The xAI store is still intact and was never consulted for a bearer.
        #expect(readAPIKey(grokHome: home) == "xai-only-key")
    }

    @Test("bearer and account headers come from the codex store")
    func appliesCodexHeaders() throws {
        let home = try codexProviderTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let codexPath = home.appendingPathComponent(OpenGrokAuthPaths.codexAuthFileName)
        try persistCodexTokens(
            at: codexPath,
            idToken: codexIDToken(),
            accessToken: freshAccessToken(),
            refreshToken: "refresh-1",
            accountID: "acct-1"
        )

        let provider = CodexAuthCredentialProvider(authFile: codexPath)
        #expect(provider.hasUsableCredential())
        #expect(provider.snapshot().userID == "user-1")
        #expect(!provider.needsTokenAuthHeader())

        var headers: [String: String] = [:]
        provider.apply(to: &headers, baseURL: "https://chatgpt.com")
        #expect(headers["Authorization"]?.hasPrefix("Bearer ") == true)
        #expect(headers["ChatGPT-Account-ID"] == "acct-1")
    }

    @Test("an expired access token is refreshed before use")
    func refreshesOnExpiry() async throws {
        let home = try codexProviderTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let codexPath = home.appendingPathComponent(OpenGrokAuthPaths.codexAuthFileName)
        let idToken = codexIDToken()
        try persistCodexTokens(
            at: codexPath,
            idToken: idToken,
            accessToken: expiredAccessToken(),
            refreshToken: "refresh-1",
            accountID: "acct-1"
        )

        let body = """
        {"access_token":"refreshed-access","id_token":"\(idToken)","refresh_token":"refresh-2"}
        """
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 200), body: Data(body.utf8)),
        ])
        let provider = CodexAuthCredentialProvider(
            authFile: codexPath,
            refreshService: .live(
                endpoints: CodexEndpoints(issuer: "https://auth.example"),
                transport: transport
            )
        )

        let credentials = try await provider.ensureFreshCredentials()
        #expect(credentials.accessToken == "refreshed-access")
        #expect(transport.recordedRequests.count == 1)

        // The renewed token is durable, not just in memory.
        let persisted = try loadCodexCredentials(at: codexPath)
        #expect(persisted?.accessToken == "refreshed-access")
    }

    @Test("a fresh access token is used without contacting the IdP")
    func skipsRefreshWhenFresh() async throws {
        let home = try codexProviderTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let codexPath = home.appendingPathComponent(OpenGrokAuthPaths.codexAuthFileName)
        let access = freshAccessToken()
        try persistCodexTokens(
            at: codexPath,
            idToken: codexIDToken(),
            accessToken: access,
            refreshToken: "refresh-1",
            accountID: "acct-1"
        )

        let transport = MockHTTPTransport(responses: [])
        let provider = CodexAuthCredentialProvider(
            authFile: codexPath,
            refreshService: .live(
                endpoints: CodexEndpoints(issuer: "https://auth.example"),
                transport: transport
            )
        )
        let credentials = try await provider.ensureFreshCredentials()
        #expect(credentials.accessToken == access)
        #expect(transport.recordedRequests.isEmpty)
    }

    @Test("a failed refresh throws instead of falling back to the stale token")
    func failsClosedOnRefreshFailure() async throws {
        let home = try codexProviderTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let codexPath = home.appendingPathComponent(OpenGrokAuthPaths.codexAuthFileName)
        try persistCodexTokens(
            at: codexPath,
            idToken: codexIDToken(),
            accessToken: expiredAccessToken(),
            refreshToken: "revoked",
            accountID: "acct-1"
        )

        let transport = MockHTTPTransport(responses: [
            .init(
                metadata: HTTPResponseMetadata(statusCode: 401),
                body: Data(#"{"error":{"code":"refresh_token_expired"}}"#.utf8)
            ),
        ])
        let provider = CodexAuthCredentialProvider(
            authFile: codexPath,
            refreshService: .live(
                endpoints: CodexEndpoints(issuer: "https://auth.example"),
                transport: transport
            )
        )
        await #expect(throws: AuthError.self) {
            _ = try await provider.ensureFreshCredentials()
        }
    }

    @Test("credentials for another account are rejected, not adopted")
    func failsClosedOnAccountDrift() throws {
        let home = try codexProviderTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let codexPath = home.appendingPathComponent(OpenGrokAuthPaths.codexAuthFileName)
        try persistCodexTokens(
            at: codexPath,
            idToken: codexIDToken(account: "acct-1", user: "user-1"),
            accessToken: freshAccessToken(),
            refreshToken: "refresh-1",
            accountID: "acct-1"
        )
        let initial = try loadCodexCredentials(at: codexPath)
        let pinned = try #require(initial).identity
        let provider = CodexAuthCredentialProvider(authFile: codexPath, expectedIdentity: pinned)
        #expect(provider.hasUsableCredential())

        // The store is swapped to a different ChatGPT account underneath us.
        try persistCodexTokens(
            at: codexPath,
            idToken: codexIDToken(account: "acct-2", user: "user-2"),
            accessToken: freshAccessToken(),
            refreshToken: "refresh-2",
            accountID: "acct-2"
        )
        #expect(!provider.hasUsableCredential())
        #expect(provider.resolvedBearer() == nil)

        var headers: [String: String] = [:]
        provider.apply(to: &headers, baseURL: "https://chatgpt.com")
        #expect(headers["Authorization"] == nil)
    }

    @Test("logout is observed immediately by an existing provider")
    func observesLogout() async throws {
        let home = try codexProviderTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try storeAPIKey(grokHome: home, apiKey: "xai-key")
        let codexPath = home.appendingPathComponent(OpenGrokAuthPaths.codexAuthFileName)
        try persistCodexTokens(
            at: codexPath,
            idToken: codexIDToken(),
            accessToken: freshAccessToken(),
            refreshToken: "refresh-1",
            accountID: "acct-1"
        )
        let provider = CodexAuthCredentialProvider(authFile: codexPath)
        #expect(provider.hasUsableCredential())

        let removed = try await logoutCodex(at: codexPath, transport: nil)
        #expect(removed)
        #expect(!provider.hasUsableCredential())
        // Codex logout leaves the xAI store alone.
        #expect(readAPIKey(grokHome: home) == "xai-key")
    }
}
