// WebSearchFilterTests.swift
//
// Unit tests for WebSearchFilter domain filtering and precedence logic.

import Foundation
import Testing
@testable import OpenGrokWebMediaTools

@Suite("WebSearchFilterTests")
struct WebSearchFilterTests {

    @Test("Config allowlist takes precedence over model requested allowlist")
    func configAllowlistWinsOverModel() {
        let filter = WebSearchFilter(allowedDomains: ["config.com"], excludedDomains: nil)
        let (allowed, excluded) = filter.resolveFilters(modelAllowed: ["model.com"])
        #expect(allowed == ["config.com"])
        #expect(excluded == nil)
    }

    @Test("Config allowlist is used when model requests no filter")
    func configAllowlistWhenModelSilent() {
        let filter = WebSearchFilter(allowedDomains: ["config.com"], excludedDomains: nil)
        let (allowed, excluded) = filter.resolveFilters(modelAllowed: nil)
        #expect(allowed == ["config.com"])
        #expect(excluded == nil)
    }

    @Test("Config blocklist applies when no allowlist is configured")
    func configBlocklistAppliesWhenNoAllowlist() {
        let filter = WebSearchFilter(allowedDomains: nil, excludedDomains: ["reddit.com"])
        let (allowed, excluded) = filter.resolveFilters(modelAllowed: nil)
        #expect(allowed == nil)
        #expect(excluded == ["reddit.com"])
    }

    @Test("Config blocklist cannot be bypassed by model naming blocked domain")
    func configBlocklistCannotBeBypassedByModel() {
        let filter = WebSearchFilter(allowedDomains: nil, excludedDomains: ["github.com"])
        let (allowed, excluded) = filter.resolveFilters(modelAllowed: ["github.com"])
        #expect(allowed == nil, "Model allowlist must not override the blocklist")
        #expect(excluded == ["github.com"])
    }

    @Test("No config policy honors model allowlist")
    func noConfigHonorsModelAllowlist() {
        let filter = WebSearchFilter(allowedDomains: nil, excludedDomains: nil)
        let (allowed, excluded) = filter.resolveFilters(modelAllowed: ["model.com"])
        #expect(allowed == ["model.com"])
        #expect(excluded == nil)
    }

    @Test("Empty list inputs are treated as nil and fall back properly")
    func emptyListInputsFallback() {
        // Empty config allowlist falls back to config blocklist
        let (allowed1, excluded1) = WebSearchFilter.resolveFilters(
            configAllowed: [],
            configExcluded: ["reddit.com"],
            modelAllowed: ["example.com"]
        )
        #expect(allowed1 == nil)
        #expect(excluded1 == ["reddit.com"])

        // Empty config allowlist and blocklist fall back to model
        let (allowed2, excluded2) = WebSearchFilter.resolveFilters(
            configAllowed: [],
            configExcluded: [],
            modelAllowed: ["model.com"]
        )
        #expect(allowed2 == ["model.com"])
        #expect(excluded2 == nil)

        // All empty or nil returns nil, nil
        let (allowed3, excluded3) = WebSearchFilter.resolveFilters(
            configAllowed: nil,
            configExcluded: [],
            modelAllowed: []
        )
        #expect(allowed3 == nil)
        #expect(excluded3 == nil)
    }

    @Test("Domain matching handles exact matches and subdomains")
    func domainMatching() {
        #expect(WebSearchFilter.matchesDomain(domain: "docs.x.ai", pattern: "docs.x.ai"))
        #expect(WebSearchFilter.matchesDomain(domain: "api.docs.x.ai", pattern: "docs.x.ai"))
        #expect(WebSearchFilter.matchesDomain(domain: "docs.x.ai", pattern: "x.ai"))
        #expect(!WebSearchFilter.matchesDomain(domain: "notx.ai", pattern: "x.ai"))
        #expect(!WebSearchFilter.matchesDomain(domain: "x.ai", pattern: "docs.x.ai"))
    }

    @Test("Domain normalization strips schemes, paths, whitespace, leading dots, and lowercases")
    func domainNormalization() {
        #expect(WebSearchFilter.normalizeDomain("  https://DOCS.x.ai/path/to/page  ") == "docs.x.ai")
        #expect(WebSearchFilter.normalizeDomain("...sub.example.com/  ") == "sub.example.com")
        #expect(WebSearchFilter.normalizeDomain("HTTP://GITHUB.COM") == "github.com")
    }

    @Test("isDomainAllowed respects allowlist and blocklist rules")
    func isDomainAllowedRules() {
        // Blocklist test
        #expect(!WebSearchFilter.isDomainAllowed(domain: "reddit.com", allowedDomains: nil, excludedDomains: ["reddit.com"]))
        #expect(!WebSearchFilter.isDomainAllowed(domain: "old.reddit.com", allowedDomains: nil, excludedDomains: ["reddit.com"]))
        #expect(WebSearchFilter.isDomainAllowed(domain: "github.com", allowedDomains: nil, excludedDomains: ["reddit.com"]))

        // Allowlist test
        #expect(WebSearchFilter.isDomainAllowed(domain: "docs.x.ai", allowedDomains: ["x.ai"], excludedDomains: nil))
        #expect(!WebSearchFilter.isDomainAllowed(domain: "google.com", allowedDomains: ["x.ai"], excludedDomains: nil))

        // URL check
        let validURL = URL(string: "https://docs.x.ai/api/intro")!
        let blockedURL = URL(string: "https://reddit.com/r/swift")!
        #expect(WebSearchFilter.isURLAllowed(url: validURL, allowedDomains: ["x.ai"], excludedDomains: nil))
        #expect(!WebSearchFilter.isURLAllowed(url: blockedURL, allowedDomains: ["x.ai"], excludedDomains: nil))
    }

    @Test("cleanDomainList deduplicates and drops empty items")
    func cleanDomainListDeduplication() {
        let cleaned = WebSearchFilter.cleanDomainList(["docs.x.ai", "  ", "DOCS.X.AI", "github.com", ""])
        #expect(cleaned == ["docs.x.ai", "github.com"])
    }

    @Test("injectFilters mutates tool dictionary correctly")
    func injectFiltersMutation() {
        var toolDict: [String: Any] = ["type": "web_search"]

        // Inject allowed
        WebSearchFilter.injectFilters(into: &toolDict, allowedDomains: ["docs.x.ai"], excludedDomains: nil)
        let filters1 = toolDict["filters"] as? [String: Any]
        #expect(filters1?["allowed_domains"] as? [String] == ["docs.x.ai"])
        #expect(filters1?["excluded_domains"] == nil)

        // Inject excluded (overwrites allowed)
        WebSearchFilter.injectFilters(into: &toolDict, allowedDomains: nil, excludedDomains: ["reddit.com"])
        let filters2 = toolDict["filters"] as? [String: Any]
        #expect(filters2?["excluded_domains"] as? [String] == ["reddit.com"])
        #expect(filters2?["allowed_domains"] == nil)

        // Inject nil cleans filters
        WebSearchFilter.injectFilters(into: &toolDict, allowedDomains: nil, excludedDomains: nil)
        let filters3 = toolDict["filters"] as? [String: Any]
        #expect(filters3?["allowed_domains"] == nil)
        #expect(filters3?["excluded_domains"] == nil)
    }

    @Test("WebSearchFilter Codable serialization roundtrips")
    func codableRoundtrip() throws {
        let filter = WebSearchFilter(allowedDomains: ["docs.x.ai"], excludedDomains: ["reddit.com"])
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(filter)
        let decoded = try decoder.decode(WebSearchFilter.self, from: data)
        #expect(decoded == filter)
    }
}
