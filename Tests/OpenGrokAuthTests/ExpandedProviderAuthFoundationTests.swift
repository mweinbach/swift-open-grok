import Foundation
import Testing
@testable import OpenGrokAuth

private enum ExpandedAuthFixture {
    static func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-expanded-auth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }
}

@Suite("RunInfra, Gemini, and OpenRouter isolated auth foundations")
struct ExpandedProviderAuthFoundationTests {
    @Test("new providers persist distinct canonical scopes without borrowing sibling accounts")
    func providerScopesRemainIsolated() throws {
        let home = try ExpandedAuthFixture.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try storeAPIKey(grokHome: home, apiKey: "xai-private")
        try storeRunInfraAPIKey(grokHome: home, apiKey: "  runinfra-private  ")
        try storeGeminiAPIKey(grokHome: home, apiKey: "gemini-private")
        try storeOpenRouterAPIKey(grokHome: home, apiKey: "openrouter-private")

        #expect(readRunInfraAPIKey(grokHome: home) == "runinfra-private")
        #expect(readGeminiAPIKey(grokHome: home) == "gemini-private")
        #expect(readOpenRouterAPIKey(grokHome: home) == "openrouter-private")
        #expect(readAPIKey(grokHome: home) == "xai-private")

        let store = try readAuthJSON(at: home.appendingPathComponent(OpenGrokAuthPaths.authFileName))
        #expect(store[runInfraAPIKeyScope]?.key == "runinfra-private")
        #expect(store[geminiAPIKeyScope]?.key == "gemini-private")
        #expect(store[openRouterAPIKeyScope]?.key == "openrouter-private")
        #expect(Set([runInfraAPIKeyScope, geminiAPIKeyScope, openRouterAPIKeyScope]).count == 3)
    }

    @Test("clearing or replacing one provider never modifies another provider")
    func clearingOneProviderPreservesSiblings() throws {
        let home = try ExpandedAuthFixture.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try storeRunInfraAPIKey(grokHome: home, apiKey: "runinfra-private")
        try storeGeminiAPIKey(grokHome: home, apiKey: "gemini-private")
        try storeOpenRouterAPIKey(grokHome: home, apiKey: "openrouter-private")

        try storeGeminiAPIKey(grokHome: home, apiKey: " \n\t ")
        #expect(!geminiAPIKeyIsConfigured(grokHome: home))
        #expect(runInfraAPIKeyIsConfigured(grokHome: home))
        #expect(openRouterAPIKeyIsConfigured(grokHome: home))

        try clearRunInfraAPIKey(grokHome: home)
        #expect(!runInfraAPIKeyIsConfigured(grokHome: home))
        #expect(readOpenRouterAPIKey(grokHome: home) == "openrouter-private")

        try clearOpenRouterAPIKey(grokHome: home)
        #expect(!openRouterAPIKeyIsConfigured(grokHome: home))
    }

    @Test("individual provider logout removes exactly its own canonical scope")
    func providerLogoutPreservesSiblingAccounts() async throws {
        let home = try ExpandedAuthFixture.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try storeRunInfraAPIKey(grokHome: home, apiKey: "runinfra-private")
        try storeGeminiAPIKey(grokHome: home, apiKey: "gemini-private")
        try storeOpenRouterAPIKey(grokHome: home, apiKey: "openrouter-private")

        let gemini = try await logout(target: .gemini, grokHome: home)
        #expect(gemini.provider == "gemini")
        #expect(gemini.removedScopes == [geminiAPIKeyScope])
        #expect(readRunInfraAPIKey(grokHome: home) == "runinfra-private")
        #expect(readOpenRouterAPIKey(grokHome: home) == "openrouter-private")

        let openRouter = try await logout(target: .openRouter, grokHome: home)
        #expect(openRouter.provider == "openrouter")
        #expect(openRouter.removedScopes == [openRouterAPIKeyScope])
        #expect(readRunInfraAPIKey(grokHome: home) == "runinfra-private")

        let runInfra = try await logout(target: .runinfra, grokHome: home)
        #expect(runInfra.provider == "runinfra")
        #expect(runInfra.removedScopes == [runInfraAPIKeyScope])
    }

    @Test("logout all includes every new isolated provider scope")
    func logoutAllClearsExpandedProviderScopes() async throws {
        let home = try ExpandedAuthFixture.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try storeRunInfraAPIKey(grokHome: home, apiKey: "runinfra-private")
        try storeGeminiAPIKey(grokHome: home, apiKey: "gemini-private")
        try storeOpenRouterAPIKey(grokHome: home, apiKey: "openrouter-private")

        let result = try await logout(target: .all, grokHome: home)
        #expect(result.removedScopes.contains(runInfraAPIKeyScope))
        #expect(result.removedScopes.contains(geminiAPIKeyScope))
        #expect(result.removedScopes.contains(openRouterAPIKeyScope))
        #expect(!runInfraAPIKeyIsConfigured(grokHome: home))
        #expect(!geminiAPIKeyIsConfigured(grokHome: home))
        #expect(!openRouterAPIKeyIsConfigured(grokHome: home))
    }

    @Test("provider environment aliases respect upstream precedence and ignore blank values")
    func environmentAliasPrecedence() {
        #expect(runInfraAPIKeyFromEnvironment([
            runInfraGatewayKeyEnv: " gateway-primary ",
            runInfraAPIKeyEnv: "gateway-fallback",
        ]) == "gateway-primary")
        #expect(runInfraAPIKeyFromEnvironment([
            runInfraGatewayKeyEnv: " \n ",
            runInfraAPIKeyEnv: "gateway-fallback",
        ]) == "gateway-fallback")

        #expect(geminiAPIKeyFromEnvironment([
            geminiAPIKeyEnv: " dedicated-gemini ",
            googleAPIKeyEnv: "generic-google",
        ]) == "dedicated-gemini")
        #expect(geminiAPIKeyFromEnvironment([
            geminiAPIKeyEnv: " \t ",
            googleAPIKeyEnv: "generic-google",
        ]) == "generic-google")

        #expect(openRouterAPIKeyFromEnvironment([
            openRouterAPIKeyEnv: " openrouter-key ",
        ]) == "openrouter-key")
        #expect(openRouterAPIKeyFromEnvironment([openRouterAPIKeyEnv: "  "]) == nil)
    }

    @Test("provider aliases normalize to canonical account targets without crossing scopes")
    func providerAliasesCanonicalize() {
        for alias in ["runinfra", "run_infra", "run-infra", "RUNINFRA"] {
            #expect(AuthAccountTarget(rawValue: alias) == .runinfra)
        }
        for alias in ["gemini", "google", "google_gemini", "ai_studio", "aistudio", "gemini-api"] {
            #expect(AuthAccountTarget(rawValue: alias) == .gemini)
        }
        for alias in ["openrouter", "open_router", "open-router", "OPENROUTER"] {
            #expect(AuthAccountTarget(rawValue: alias) == .openRouter)
        }
        #expect(AuthAccountTarget.runinfra.rawValue == "runinfra")
        #expect(AuthAccountTarget.gemini.rawValue == "gemini")
        #expect(AuthAccountTarget.openRouter.rawValue == "openrouter")
    }
}
