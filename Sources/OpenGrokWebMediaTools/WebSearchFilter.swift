// WebSearchFilter.swift
//
// Domain filtering and resolution for web search tools in Open Grok.
// Ported from `crates/codegen/xai-grok-tools/src/implementations/web_search/client.rs`.

import Foundation

/// Filter configuration and resolution for web search domain allowlisting and blocklisting.
///
/// A configured `WebSearchFilter` policy is **authoritative**:
/// - When the user/configuration sets `allowed_domains`, it governs and the model's per-call `allowed_domains` is ignored.
/// - When the user/configuration sets `excluded_domains`, the model cannot bypass it by naming a blocked domain in its own `allowed_domains`.
/// - Only when no configuration policy is set does the model's per-call allowlist apply.
/// - The resolved allowlist and blocklist are mutually exclusive (at most one is non-nil).
public struct WebSearchFilter: Sendable, Equatable, Hashable, Codable {
    /// Authoritative domain allowlist from `allowed_domains`.
    public var allowedDomains: [String]?

    /// Authoritative domain blocklist from `excluded_domains`.
    public var excludedDomains: [String]?

    public init(
        allowedDomains: [String]? = nil,
        excludedDomains: [String]? = nil
    ) {
        self.allowedDomains = Self.cleanDomainList(allowedDomains)
        self.excludedDomains = Self.cleanDomainList(excludedDomains)
    }

    /// Resolves the effective domain filters given optional model-requested allowed domains.
    ///
    /// - Parameter modelAllowed: The model's per-call requested allowed domains.
    /// - Returns: A tuple of `(allowedDomains: [String]?, excludedDomains: [String]?)`.
    ///   At most one of the returned lists is non-nil.
    public func resolveFilters(
        modelAllowed: [String]? = nil
    ) -> (allowedDomains: [String]?, excludedDomains: [String]?) {
        Self.resolveFilters(
            configAllowed: self.allowedDomains,
            configExcluded: self.excludedDomains,
            modelAllowed: modelAllowed
        )
    }

    /// Resolve the effective domain filters for a web search request.
    ///
    /// - Parameters:
    ///   - configAllowed: Configured domain allowlist.
    ///   - configExcluded: Configured domain blocklist.
    ///   - modelAllowed: Model per-call requested allowlist.
    /// - Returns: `(allowedDomains: [String]?, excludedDomains: [String]?)`
    public static func resolveFilters(
        configAllowed: [String]?,
        configExcluded: [String]?,
        modelAllowed: [String]?
    ) -> (allowedDomains: [String]?, excludedDomains: [String]?) {
        if let allowed = cleanDomainList(configAllowed) {
            return (allowed, nil)
        }
        if let excluded = cleanDomainList(configExcluded) {
            return (nil, excluded)
        }
        if let model = cleanDomainList(modelAllowed) {
            return (model, nil)
        }
        return (nil, nil)
    }

    /// Checks if a domain is allowed under the given resolved filters.
    ///
    /// - Parameters:
    ///   - domain: The host/domain name to check.
    ///   - allowedDomains: Effective allowed domains list.
    ///   - excludedDomains: Effective excluded domains list.
    /// - Returns: `true` if allowed, `false` if blocked.
    public static func isDomainAllowed(
        domain: String,
        allowedDomains: [String]?,
        excludedDomains: [String]?
    ) -> Bool {
        let normalized = normalizeDomain(domain)
        guard !normalized.isEmpty else { return false }

        if let excluded = cleanDomainList(excludedDomains) {
            for pattern in excluded {
                if matchesDomain(domain: normalized, pattern: pattern) {
                    return false
                }
            }
        }

        if let allowed = cleanDomainList(allowedDomains) {
            for pattern in allowed {
                if matchesDomain(domain: normalized, pattern: pattern) {
                    return true
                }
            }
            return false
        }

        return true
    }

    /// Checks if a specific URL is permitted under the resolved domain filters.
    public static func isURLAllowed(
        url: URL,
        allowedDomains: [String]?,
        excludedDomains: [String]?
    ) -> Bool {
        guard let host = url.host else { return false }
        return isDomainAllowed(domain: host, allowedDomains: allowedDomains, excludedDomains: excludedDomains)
    }

    /// Checks whether a given domain matches a filter pattern (exact or subdomain match).
    public static func matchesDomain(domain: String, pattern: String) -> Bool {
        let normDomain = normalizeDomain(domain)
        let normPattern = normalizeDomain(pattern)
        guard !normDomain.isEmpty, !normPattern.isEmpty else { return false }

        if normDomain == normPattern { return true }
        if normDomain.hasSuffix("." + normPattern) { return true }
        return false
    }

    /// Normalizes a single domain string by trimming, lowercasing, and stripping scheme/path/leading dots.
    public static func normalizeDomain(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.contains("://"), let url = URL(string: trimmed), let host = url.host {
            trimmed = host.lowercased()
        } else if let slashIdx = trimmed.firstIndex(of: "/") {
            trimmed = String(trimmed[..<slashIdx])
        }
        while trimmed.hasPrefix(".") {
            trimmed.removeFirst()
        }
        return trimmed
    }

    /// Cleans and filters an optional list of domain strings, deduplicating and omitting empty entries.
    public static func cleanDomainList(_ list: [String]?) -> [String]? {
        guard let list else { return nil }
        var seen = Set<String>()
        var result: [String] = []
        for item in list {
            let normalized = normalizeDomain(item)
            if !normalized.isEmpty, seen.insert(normalized).inserted {
                result.append(normalized)
            }
        }
        return result.isEmpty ? nil : result
    }

    /// Injects resolved domain filters into a JSON dictionary representation of a tool call.
    public static func injectFilters(
        into toolDict: inout [String: Any],
        allowedDomains: [String]?,
        excludedDomains: [String]?
    ) {
        var filters = (toolDict["filters"] as? [String: Any]) ?? [:]
        if let allowed = cleanDomainList(allowedDomains) {
            filters["allowed_domains"] = allowed
            filters.removeValue(forKey: "excluded_domains")
        } else if let excluded = cleanDomainList(excludedDomains) {
            filters["excluded_domains"] = excluded
            filters.removeValue(forKey: "allowed_domains")
        } else {
            filters.removeValue(forKey: "allowed_domains")
            filters.removeValue(forKey: "excluded_domains")
        }
        toolDict["filters"] = filters
    }
}
