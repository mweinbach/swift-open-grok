// MultiProviderAuthTests.swift
//
// Tests for multi-provider auth scopes, storage isolation, and logout orchestration.

import Foundation
import Testing
@testable import OpenGrokAuth
import OpenGrokHTTP
import OpenGrokPaths

private func tempHome() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("opengrok-multi-auth-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite("Multi-Provider Scoped Keys Storage and Reads")
struct MultiProviderScopedKeysStorageTests {

    @Test("Fireworks API key store, read, isConfigured, and whitespace trim clearing")
    func testFireworksScope() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        #expect(!fireworksAPIKeyIsConfigured(grokHome: home))
        #expect(readFireworksAPIKey(grokHome: home) == nil)

        try storeFireworksAPIKey(grokHome: home, apiKey: "fw-secret-key-123")
        #expect(fireworksAPIKeyIsConfigured(grokHome: home))
        #expect(readFireworksAPIKey(grokHome: home) == "fw-secret-key-123")

        // Whitespace-only clears key
        try storeFireworksAPIKey(grokHome: home, apiKey: "   \n\t ")
        #expect(!fireworksAPIKeyIsConfigured(grokHome: home))
        #expect(readFireworksAPIKey(grokHome: home) == nil)

        // Store and explicit clear
        try storeFireworksAPIKey(grokHome: home, apiKey: "fw-another-key")
        #expect(readFireworksAPIKey(grokHome: home) == "fw-another-key")
        try clearFireworksAPIKey(grokHome: home)
        #expect(!fireworksAPIKeyIsConfigured(grokHome: home))
        #expect(readFireworksAPIKey(grokHome: home) == nil)
    }

    @Test("DeepSeek API key store, read, isConfigured, and trim clearing")
    func testDeepSeekScope() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        #expect(!deepseekAPIKeyIsConfigured(grokHome: home))
        #expect(readDeepSeekAPIKey(grokHome: home) == nil)

        try storeDeepSeekAPIKey(grokHome: home, apiKey: "sk-deepseek-abc")
        #expect(deepseekAPIKeyIsConfigured(grokHome: home))
        #expect(readDeepSeekAPIKey(grokHome: home) == "sk-deepseek-abc")

        try storeDeepSeekAPIKey(grokHome: home, apiKey: "  ")
        #expect(!deepseekAPIKeyIsConfigured(grokHome: home))

        try storeDeepSeekAPIKey(grokHome: home, apiKey: "sk-deepseek-def")
        try clearDeepSeekAPIKey(grokHome: home)
        #expect(!deepseekAPIKeyIsConfigured(grokHome: home))
    }

    @Test("Meta API key store, read, isConfigured, and trim clearing")
    func testMetaScope() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        #expect(!metaAPIKeyIsConfigured(grokHome: home))
        #expect(readMetaAPIKey(grokHome: home) == nil)

        try storeMetaAPIKey(grokHome: home, apiKey: "meta-api-token-789")
        #expect(metaAPIKeyIsConfigured(grokHome: home))
        #expect(readMetaAPIKey(grokHome: home) == "meta-api-token-789")

        try storeMetaAPIKey(grokHome: home, apiKey: "")
        #expect(!metaAPIKeyIsConfigured(grokHome: home))

        try storeMetaAPIKey(grokHome: home, apiKey: "meta-api-token-xyz")
        try clearMetaAPIKey(grokHome: home)
        #expect(!metaAPIKeyIsConfigured(grokHome: home))
    }

    @Test("OpenCode Go API key store, read, isConfigured, and trim clearing")
    func testOpenCodeGoScope() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        #expect(!openCodeGoAPIKeyIsConfigured(grokHome: home))
        #expect(readOpenCodeGoAPIKey(grokHome: home) == nil)

        try storeOpenCodeGoAPIKey(grokHome: home, apiKey: "opencode-go-tok-555")
        #expect(openCodeGoAPIKeyIsConfigured(grokHome: home))
        #expect(readOpenCodeGoAPIKey(grokHome: home) == "opencode-go-tok-555")

        try storeOpenCodeGoAPIKey(grokHome: home, apiKey: "  \n  ")
        #expect(!openCodeGoAPIKeyIsConfigured(grokHome: home))

        try storeOpenCodeGoAPIKey(grokHome: home, apiKey: "opencode-go-tok-999")
        try clearOpenCodeGoAPIKey(grokHome: home)
        #expect(!openCodeGoAPIKeyIsConfigured(grokHome: home))
    }

    @Test("Kimi, Wafer, Zai, and Perplexity scopes work consistently")
    func testOtherSupportedScopes() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try storeKimiAPIKey(grokHome: home, endpoint: .platform, apiKey: "kimi-plat-1")
        try storeKimiAPIKey(grokHome: home, endpoint: .code, apiKey: "kimi-code-1")
        try storeWaferAPIKey(grokHome: home, apiKey: "wafer-key-1")
        try storeZaiAPIKey(grokHome: home, apiKey: "zai-key-1")
        try storePerplexityAPIKey(grokHome: home, apiKey: "pplx-key-1")

        #expect(readKimiAPIKey(grokHome: home, endpoint: .platform) == "kimi-plat-1")
        #expect(readKimiAPIKey(grokHome: home, endpoint: .code) == "kimi-code-1")
        #expect(readWaferAPIKey(grokHome: home) == "wafer-key-1")
        #expect(readZaiAPIKey(grokHome: home) == "zai-key-1")
        #expect(readPerplexityAPIKey(grokHome: home) == "pplx-key-1")
    }
}

@Suite("Multi-Provider Sibling Isolation")
struct MultiProviderIsolationTests {

    @Test("Storing all provider keys simultaneously and clearing each leaves siblings intact")
    func testSiblingIsolation() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        // Store keys for all providers
        try storeAPIKey(grokHome: home, apiKey: "xai-key")
        try storeKimiAPIKey(grokHome: home, endpoint: .platform, apiKey: "kimi-platform-key")
        try storeKimiAPIKey(grokHome: home, endpoint: .code, apiKey: "kimi-code-key")
        try storeFireworksAPIKey(grokHome: home, apiKey: "fireworks-key")
        try storeDeepSeekAPIKey(grokHome: home, apiKey: "deepseek-key")
        try storeMetaAPIKey(grokHome: home, apiKey: "meta-key")
        try storeOpenCodeGoAPIKey(grokHome: home, apiKey: "opencode-go-key")
        try storeWaferAPIKey(grokHome: home, apiKey: "wafer-key")
        try storeZaiAPIKey(grokHome: home, apiKey: "zai-key")
        try storePerplexityAPIKey(grokHome: home, apiKey: "perplexity-key")

        // Verify all exist
        #expect(readAPIKey(grokHome: home) == "xai-key")
        #expect(readKimiAPIKey(grokHome: home, endpoint: .platform) == "kimi-platform-key")
        #expect(readKimiAPIKey(grokHome: home, endpoint: .code) == "kimi-code-key")
        #expect(readFireworksAPIKey(grokHome: home) == "fireworks-key")
        #expect(readDeepSeekAPIKey(grokHome: home) == "deepseek-key")
        #expect(readMetaAPIKey(grokHome: home) == "meta-key")
        #expect(readOpenCodeGoAPIKey(grokHome: home) == "opencode-go-key")
        #expect(readWaferAPIKey(grokHome: home) == "wafer-key")
        #expect(readZaiAPIKey(grokHome: home) == "zai-key")
        #expect(readPerplexityAPIKey(grokHome: home) == "perplexity-key")

        // Clear Fireworks alone
        try clearFireworksAPIKey(grokHome: home)
        #expect(readFireworksAPIKey(grokHome: home) == nil)
        #expect(readAPIKey(grokHome: home) == "xai-key")
        #expect(readDeepSeekAPIKey(grokHome: home) == "deepseek-key")
        #expect(readMetaAPIKey(grokHome: home) == "meta-key")
        #expect(readOpenCodeGoAPIKey(grokHome: home) == "opencode-go-key")
        #expect(readWaferAPIKey(grokHome: home) == "wafer-key")
        #expect(readZaiAPIKey(grokHome: home) == "zai-key")
        #expect(readKimiAPIKey(grokHome: home, endpoint: .platform) == "kimi-platform-key")
        #expect(readKimiAPIKey(grokHome: home, endpoint: .code) == "kimi-code-key")
        #expect(readPerplexityAPIKey(grokHome: home) == "perplexity-key")

        // Clear DeepSeek alone
        try clearDeepSeekAPIKey(grokHome: home)
        #expect(readDeepSeekAPIKey(grokHome: home) == nil)
        #expect(readMetaAPIKey(grokHome: home) == "meta-key")
        #expect(readOpenCodeGoAPIKey(grokHome: home) == "opencode-go-key")

        // Clear Kimi Code alone, Platform remains
        try clearKimiAPIKey(grokHome: home, endpoint: .code)
        #expect(readKimiAPIKey(grokHome: home, endpoint: .code) == nil)
        #expect(readKimiAPIKey(grokHome: home, endpoint: .platform) == "kimi-platform-key")

        // Clear Meta alone
        try clearMetaAPIKey(grokHome: home)
        #expect(readMetaAPIKey(grokHome: home) == nil)
        #expect(readOpenCodeGoAPIKey(grokHome: home) == "opencode-go-key")
        #expect(readWaferAPIKey(grokHome: home) == "wafer-key")
        #expect(readZaiAPIKey(grokHome: home) == "zai-key")

        // Clear OpenCode Go alone
        try clearOpenCodeGoAPIKey(grokHome: home)
        #expect(readOpenCodeGoAPIKey(grokHome: home) == nil)
        #expect(readWaferAPIKey(grokHome: home) == "wafer-key")
        #expect(readZaiAPIKey(grokHome: home) == "zai-key")
        #expect(readAPIKey(grokHome: home) == "xai-key")
    }
}

@Suite("Multi-Target Logout Orchestration")
struct MultiTargetLogoutTests {

    @Test("logout(target: .xai) clears xAI via manager and preserves other scopes")
    func testLogoutXAI() async throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try storeAPIKey(grokHome: home, apiKey: "xai-active-key")
        try storeFireworksAPIKey(grokHome: home, apiKey: "fw-keep-key")
        let manager = AuthManager(grokHome: home, environment: [:])

        let result = try await logout(target: .xai, manager: manager)
        #expect(result.provider == "xai")
        #expect(result.xai?.wasLoggedIn == true)
        #expect(readAPIKey(grokHome: home) == nil)
        #expect(readFireworksAPIKey(grokHome: home) == "fw-keep-key")
    }

    @Test("logout(target: .codex) deletes codex-auth.json and preserves auth.json")
    func testLogoutCodex() async throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let codexFile = home.appendingPathComponent("codex-auth.json")
        try persistCodexTokens(
            at: codexFile,
            idToken: buildTestJWT(payload: ["sub": "test-user"]),
            accessToken: "acc",
            refreshToken: "ref"
        )
        try storeFireworksAPIKey(grokHome: home, apiKey: "fw-keep")

        let result = try await logout(target: .codex, codexAuthFile: codexFile)
        #expect(result.provider == "codex")
        #expect(result.codexRemoved == true)
        #expect(!FileManager.default.fileExists(atPath: codexFile.path))
        #expect(readFireworksAPIKey(grokHome: home) == "fw-keep")
    }

    @Test("logout(target: .kimi) clears platform and code scopes")
    func testLogoutKimi() async throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try storeKimiAPIKey(grokHome: home, endpoint: .platform, apiKey: "plat-key")
        try storeKimiAPIKey(grokHome: home, endpoint: .code, apiKey: "code-key")
        try storeDeepSeekAPIKey(grokHome: home, apiKey: "ds-keep")

        let result = try await logout(target: .kimi, grokHome: home)
        #expect(result.provider == "kimi")
        #expect(result.removedScopes.contains("kimi::api_key"))
        #expect(result.removedScopes.contains("kimi_code::api_key"))
        #expect(readKimiAPIKey(grokHome: home, endpoint: .platform) == nil)
        #expect(readKimiAPIKey(grokHome: home, endpoint: .code) == nil)
        #expect(readDeepSeekAPIKey(grokHome: home) == "ds-keep")
    }

    @Test("logout(target: .fireworks) clears fireworks scope")
    func testLogoutFireworks() async throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try storeFireworksAPIKey(grokHome: home, apiKey: "fw-key")
        try storeMetaAPIKey(grokHome: home, apiKey: "meta-keep")

        let result = try await logout(target: .fireworks, grokHome: home)
        #expect(result.provider == "fireworks")
        #expect(result.removedScopes == ["fireworks::api_key"])
        #expect(readFireworksAPIKey(grokHome: home) == nil)
        #expect(readMetaAPIKey(grokHome: home) == "meta-keep")
    }

    @Test("logout(target: .deepseek) clears deepseek scope")
    func testLogoutDeepSeek() async throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try storeDeepSeekAPIKey(grokHome: home, apiKey: "ds-key")
        try storeZaiAPIKey(grokHome: home, apiKey: "zai-keep")

        let result = try await logout(target: .deepseek, grokHome: home)
        #expect(result.provider == "deepseek")
        #expect(result.removedScopes == ["deepseek::api_key"])
        #expect(readDeepSeekAPIKey(grokHome: home) == nil)
        #expect(readZaiAPIKey(grokHome: home) == "zai-keep")
    }

    @Test("logout(target: .meta) clears meta scope")
    func testLogoutMeta() async throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try storeMetaAPIKey(grokHome: home, apiKey: "meta-key")
        try storeWaferAPIKey(grokHome: home, apiKey: "wafer-keep")

        let result = try await logout(target: .meta, grokHome: home)
        #expect(result.provider == "meta")
        #expect(result.removedScopes == ["meta::api_key"])
        #expect(readMetaAPIKey(grokHome: home) == nil)
        #expect(readWaferAPIKey(grokHome: home) == "wafer-keep")
    }

    @Test("logout(target: .openCodeGo) clears opencode_go scope")
    func testLogoutOpenCodeGo() async throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try storeOpenCodeGoAPIKey(grokHome: home, apiKey: "opencode-key")
        try storeFireworksAPIKey(grokHome: home, apiKey: "fw-keep")

        let result = try await logout(target: .openCodeGo, grokHome: home)
        #expect(result.provider == "opencode_go")
        #expect(result.removedScopes == ["opencode_go::api_key"])
        #expect(readOpenCodeGoAPIKey(grokHome: home) == nil)
        #expect(readFireworksAPIKey(grokHome: home) == "fw-keep")
    }

    @Test("logout(target: .wafer) clears wafer scope")
    func testLogoutWafer() async throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try storeWaferAPIKey(grokHome: home, apiKey: "wafer-key")
        try storeZaiAPIKey(grokHome: home, apiKey: "zai-keep")

        let result = try await logout(target: .wafer, grokHome: home)
        #expect(result.provider == "wafer")
        #expect(result.removedScopes == ["wafer::api_key"])
        #expect(readWaferAPIKey(grokHome: home) == nil)
        #expect(readZaiAPIKey(grokHome: home) == "zai-keep")
    }

    @Test("logout(target: .zai) clears zai scope")
    func testLogoutZai() async throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try storeZaiAPIKey(grokHome: home, apiKey: "zai-key")
        try storeFireworksAPIKey(grokHome: home, apiKey: "fw-keep")

        let result = try await logout(target: .zai, grokHome: home)
        #expect(result.provider == "zai")
        #expect(result.removedScopes == ["zai::api_key"])
        #expect(readZaiAPIKey(grokHome: home) == nil)
        #expect(readFireworksAPIKey(grokHome: home) == "fw-keep")
    }

    @Test("logout(target: .all) clears xAI, Codex, and all provider scopes")
    func testLogoutAll() async throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        // Set up xAI
        try storeAPIKey(grokHome: home, apiKey: "xai-key")
        let manager = AuthManager(grokHome: home, environment: [:])

        // Set up Codex
        let codexFile = home.appendingPathComponent("codex-auth.json")
        try persistCodexTokens(
            at: codexFile,
            idToken: buildTestJWT(payload: ["sub": "test-user"]),
            accessToken: "acc",
            refreshToken: "ref"
        )

        // Set up all provider keys
        try storeKimiAPIKey(grokHome: home, endpoint: .platform, apiKey: "kimi-plat")
        try storeKimiAPIKey(grokHome: home, endpoint: .code, apiKey: "kimi-code")
        try storeFireworksAPIKey(grokHome: home, apiKey: "fw")
        try storeDeepSeekAPIKey(grokHome: home, apiKey: "ds")
        try storeMetaAPIKey(grokHome: home, apiKey: "meta")
        try storeOpenCodeGoAPIKey(grokHome: home, apiKey: "opencode")
        try storeWaferAPIKey(grokHome: home, apiKey: "wafer")
        try storeZaiAPIKey(grokHome: home, apiKey: "zai")
        try storePerplexityAPIKey(grokHome: home, apiKey: "pplx")

        let result = try await logout(
            target: .all,
            manager: manager,
            codexAuthFile: codexFile,
            grokHome: home
        )

        #expect(result.provider == "all")
        #expect(result.xai?.wasLoggedIn == true)
        #expect(result.codexRemoved == true)
        #expect(!FileManager.default.fileExists(atPath: codexFile.path))

        // All scopes should be cleared
        #expect(readAPIKey(grokHome: home) == nil)
        #expect(readKimiAPIKey(grokHome: home, endpoint: .platform) == nil)
        #expect(readKimiAPIKey(grokHome: home, endpoint: .code) == nil)
        #expect(readFireworksAPIKey(grokHome: home) == nil)
        #expect(readDeepSeekAPIKey(grokHome: home) == nil)
        #expect(readMetaAPIKey(grokHome: home) == nil)
        #expect(readOpenCodeGoAPIKey(grokHome: home) == nil)
        #expect(readWaferAPIKey(grokHome: home) == nil)
        #expect(readZaiAPIKey(grokHome: home) == nil)
        #expect(readPerplexityAPIKey(grokHome: home) == nil)
    }
}

@Suite("AuthAccountTarget Parsing and Values")
struct AuthAccountTargetTests {

    @Test("Raw values and case-insensitive initialization")
    func testRawValuesAndParsing() {
        #expect(AuthAccountTarget(rawValue: "xai") == .xai)
        #expect(AuthAccountTarget(rawValue: "XAI") == .xai)
        #expect(AuthAccountTarget(rawValue: "codex") == .codex)
        #expect(AuthAccountTarget(rawValue: "kimi") == .kimi)
        #expect(AuthAccountTarget(rawValue: "fireworks") == .fireworks)
        #expect(AuthAccountTarget(rawValue: "deepseek") == .deepseek)
        #expect(AuthAccountTarget(rawValue: "meta") == .meta)
        #expect(AuthAccountTarget(rawValue: "opencode_go") == .openCodeGo)
        #expect(AuthAccountTarget(rawValue: "opencode-go") == .openCodeGo)
        #expect(AuthAccountTarget(rawValue: "opencodego") == .openCodeGo)
        #expect(AuthAccountTarget(rawValue: "openCodeGo") == .openCodeGo)
        #expect(AuthAccountTarget(rawValue: "wafer") == .wafer)
        #expect(AuthAccountTarget(rawValue: "zai") == .zai)
        #expect(AuthAccountTarget(rawValue: "all") == .all)
        #expect(AuthAccountTarget(rawValue: "ALL") == .all)

        #expect(AuthAccountTarget(rawValue: "nonexistent") == nil)
        #expect(AuthAccountTarget(rawValue: "google") == nil)

        #expect(AuthAccountTarget.allCases.count == 10)
    }
}
