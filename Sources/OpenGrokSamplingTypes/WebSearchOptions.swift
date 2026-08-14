// WebSearchOptions.swift
//
// Web search options and domain filtering for sampling requests.
// Port of `crates/codegen/xai-grok-sampling-types/src/tool_overrides.rs`.

import Foundation

public let MAX_WEB_SEARCH_DOMAINS: Int = 5

public enum WebSearchOptionsError: Error, Equatable, Sendable, CustomStringConvertible {
    case bothAllowedAndExcluded
    case tooManyDomains(field: String, count: Int)

    public var description: String {
        switch self {
        case .bothAllowedAndExcluded:
            return "web_search cannot set both allowed_domains and excluded_domains"
        case .tooManyDomains(let field, let count):
            return "web_search \(field) has \(count) domains; the web-search API allows at most \(MAX_WEB_SEARCH_DOMAINS)"
        }
    }
}

public struct WebSearchOptions: Sendable, Codable, Equatable, Hashable {
    public var allowedDomains: [String]?
    public var excludedDomains: [String]?

    public init(allowedDomains: [String]? = nil, excludedDomains: [String]? = nil) {
        self.allowedDomains = allowedDomains
        self.excludedDomains = excludedDomains
    }

    public var isEmpty: Bool {
        (allowedDomains?.isEmpty ?? true) && (excludedDomains?.isEmpty ?? true)
    }

    public func validate() throws {
        let hasAllowed = !(allowedDomains?.isEmpty ?? true)
        let hasExcluded = !(excludedDomains?.isEmpty ?? true)
        if hasAllowed && hasExcluded {
            throw WebSearchOptionsError.bothAllowedAndExcluded
        }
        if let allowed = allowedDomains, allowed.count > MAX_WEB_SEARCH_DOMAINS {
            throw WebSearchOptionsError.tooManyDomains(field: "allowed_domains", count: allowed.count)
        }
        if let excluded = excludedDomains, excluded.count > MAX_WEB_SEARCH_DOMAINS {
            throw WebSearchOptionsError.tooManyDomains(field: "excluded_domains", count: excluded.count)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case allowedDomains
        case excludedDomains
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.allowedDomains = try container.decodeIfPresent([String].self, forKey: .allowedDomains)
        self.excludedDomains = try container.decodeIfPresent([String].self, forKey: .excludedDomains)
        try self.validate()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(allowedDomains, forKey: .allowedDomains)
        try container.encodeIfPresent(excludedDomains, forKey: .excludedDomains)
    }
}
