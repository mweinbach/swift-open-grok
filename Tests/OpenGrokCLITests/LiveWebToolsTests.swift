// LiveWebToolsTests.swift
//
// Covers the availability rules for `web_search` / `web_fetch` / `x_search`.
//
// The registry has always known these tools; what was missing was the decision
// about whether a session offers them. That decision is credential-shaped, so
// the assertions here are about which sessions get search and which do not —
// in particular that a non-xAI provider with no xAI key gets nothing rather
// than a tool that will fail on first use.

import Foundation
import OpenGrokSamplingTypes
import OpenGrokToolRegistry
import Testing
@testable import OpenGrokCLI

private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("web-tools-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// An environment with no inherited credentials, so a test never picks up the
/// developer's real keys and silently asserts the wrong branch.
private let hermeticEnvironment: [String: String] = ["HOME": "/nonexistent"]

private func availability(
    provider: ModelProvider = .xai,
    apiKey: String = "",
    environment: [String: String] = hermeticEnvironment,
    disableWebSearch: Bool = false
) -> LiveWebToolAvailability {
    let directory = temporaryDirectory()
    return LiveWebToolComposition.resolveAvailability(
        workingDirectory: directory,
        openGrokHome: directory,
        environment: environment,
        samplingProvider: provider,
        samplingAPIKey: apiKey,
        samplingBaseURL: "https://api.x.ai/v1",
        disableWebSearch: disableWebSearch
    )
}

// MARK: - The kill switch

@Test func disableWebSearchSuppressesSearchButNotFetch() {
    let resolved = availability(apiKey: "xai-key", disableWebSearch: true)
    #expect(!resolved.webSearchEnabled)
    #expect(!resolved.xSearchEnabled)
    #expect(resolved.searchConfig.isEnabled == false)
    // `--disable-web-search` governs the search config. Fetching a URL the user
    // supplied is a different capability and survives the flag.
    #expect(resolved.webFetchEnabled)
}

// MARK: - Credentials gate advertisement

@Test func anXaiSessionWithItsOwnBearerGetsSearch() {
    let resolved = availability(provider: .xai, apiKey: "xai-key")
    #expect(resolved.webSearchEnabled)
    #expect(resolved.xSearchEnabled)
}

@Test func aSessionWithNoUsableKeyAdvertisesNoSearch() {
    // No tool is better than a tool that 401s on first use.
    let resolved = availability(provider: .xai, apiKey: "")
    #expect(!resolved.webSearchEnabled)
    #expect(!resolved.xSearchEnabled)
    // Fetch needs no API key, so it is still on offer.
    #expect(resolved.webFetchEnabled)
}

@Test func aNonXaiSessionMayNotBorrowItsOwnBearerForXaiSearch() {
    // A Kimi token must never be sent to an xAI endpoint, so a Kimi session
    // with only its own sampling key resolves to no search at all.
    let resolved = availability(provider: .kimi, apiKey: "kimi-key")
    #expect(!resolved.webSearchEnabled)
}

@Test func aNonXaiSessionCanUseAStoredXaiKey() {
    // A stored xAI key is xAI-provenanced by construction, so it is allowed
    // where the session's own bearer is not.
    var environment = hermeticEnvironment
    environment["XAI_API_KEY"] = "stored-xai-key"
    let resolved = availability(provider: .kimi, apiKey: "kimi-key", environment: environment)
    #expect(resolved.webSearchEnabled)
}

// MARK: - Perplexity fallback

@Test func perplexityBacksASessionThatSelectsIt() {
    var environment = hermeticEnvironment
    environment["PERPLEXITY_API_KEY"] = "pplx-key"
    let directory = temporaryDirectory()
    let source = LiveWebToolComposition.effectiveSource(
        provider: .fireworks,
        workingDirectory: directory,
        openGrokHome: directory,
        environment: environment,
        xaiAvailable: false,
        perplexityAvailable: true
    )
    // Fireworks does not inherit Kimi's legacy toggle; without an explicit
    // `[toolset.web_search_source] fireworks = "perplexity"` it still defaults
    // to xAI, and so resolves to nothing when no xAI key exists.
    #expect(source == .xai)

    let resolved = LiveWebToolComposition.resolvePerplexitySearchConfig(
        openGrokHome: directory,
        environment: environment
    )
    #expect(resolved?.isPerplexity == true)
}

@Test func perplexityIsUnavailableWithoutAKey() {
    let directory = temporaryDirectory()
    #expect(
        LiveWebToolComposition.resolvePerplexitySearchConfig(
            openGrokHome: directory,
            environment: hermeticEnvironment
        ) == nil
    )
}

@Test func aPerplexityBackedSessionDoesNotAdvertiseXSearch() {
    // `x_search` hard-requires the xAI Responses backend; offering it on a
    // Perplexity session would guarantee a failed call.
    let directory = temporaryDirectory()
    guard let perplexity = LiveWebToolComposition.resolvePerplexitySearchConfig(
        openGrokHome: directory,
        environment: ["PERPLEXITY_API_KEY": "pplx-key"]
    ) else {
        Issue.record("expected a Perplexity config")
        return
    }
    #expect(perplexity.isEnabled)
    #expect(perplexity.isPerplexity)
}

// MARK: - Source defaults

@Test func codexFallsBackToItsNativeSearchWhenNoXaiKeyExists() {
    let directory = temporaryDirectory()
    #expect(
        LiveWebToolComposition.effectiveSource(
            provider: .codex,
            workingDirectory: directory,
            openGrokHome: directory,
            environment: hermeticEnvironment,
            xaiAvailable: false,
            perplexityAvailable: false
        ) == .native
    )
    #expect(
        LiveWebToolComposition.effectiveSource(
            provider: .codex,
            workingDirectory: directory,
            openGrokHome: directory,
            environment: hermeticEnvironment,
            xaiAvailable: true,
            perplexityAvailable: false
        ) == .xai
    )
}

@Test func everyOtherProviderDefaultsToXai() {
    let directory = temporaryDirectory()
    for provider in [ModelProvider.xai, .fireworks, .deepseek, .wafer, .openCodeGo] {
        #expect(
            LiveWebToolComposition.effectiveSource(
                provider: provider,
                workingDirectory: directory,
                openGrokHome: directory,
                environment: hermeticEnvironment,
                xaiAvailable: true,
                perplexityAvailable: true
            ) == .xai
        )
    }
}

// MARK: - Catalog

@Test func webToolsAreCataloguedWithTheirKinds() {
    let ids = Set(BuiltinToolCatalog.webTools.map(\.qualifiedId))
    #expect(ids == [
        BuiltinToolCatalog.webSearchQualifiedId,
        BuiltinToolCatalog.webFetchQualifiedId,
        BuiltinToolCatalog.xSearchQualifiedId,
    ])
    let kinds = BuiltinToolCatalog.webToolKinds
    #expect(kinds[BuiltinToolCatalog.webSearchQualifiedId] == .webSearch)
    #expect(kinds[BuiltinToolCatalog.webFetchQualifiedId] == .webFetch)
    #expect(kinds[BuiltinToolCatalog.xSearchQualifiedId] == .webSearch)
}
