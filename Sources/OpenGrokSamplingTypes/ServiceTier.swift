// ServiceTier.swift
//
// Open Grok — Swift port of the service-tier surface in
// `crates/codegen/xai-grok-sampling-types/src/types.rs` (Codex Fast / Flex
// routing).
//
// A service tier is a routing decision carried on the Responses wire as
// `service_tier`. Standard routing is expressed by omitting the field, so the
// catalog id `"default"` normalizes to nil rather than to a wire value.

import Foundation
import OpenGrokShared

/// Selected service-tier id in ACP model meta (`priority`, `flex`, …).
public let SERVICE_TIER_META_KEY = "serviceTier"
/// Catalog of service tiers available for a model.
public let SERVICE_TIERS_META_KEY = "serviceTiers"
/// Explicit standard routing — not a catalog id. Omits `service_tier` on the wire.
public let SERVICE_TIER_DEFAULT_REQUEST_VALUE = "default"
/// Wire/request value for Fast mode (Codex `ServiceTier::Fast`).
public let SERVICE_TIER_FAST_REQUEST_VALUE = "priority"
/// Slash-command / catalog display name for Fast mode.
public let SERVICE_TIER_FAST_NAME = "fast"

/// Responses API `service_tier` enum.
public enum ResponsesServiceTier: String, Codable, Sendable, Equatable, Hashable {
    case auto
    case `default`
    case flex
    case scale
    /// Codex Fast mode. The wire value is `priority`; `fast` is its alias.
    case priority
}

/// Map a catalog or request service-tier id to the Responses API enum.
/// Returns nil for ids the Responses API does not define.
public func serviceTierToResponsesAPI(_ tier: String) -> ResponsesServiceTier? {
    switch tier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "auto": return .auto
    case "default": return .default
    case "flex": return .flex
    case "scale": return .scale
    // Codex Fast mode uses the wire value `priority` (alias `fast`).
    case "priority", "fast": return .priority
    default: return nil
    }
}

/// Reduce a configured tier id to the value that belongs on the wire.
///
/// Empty and `"default"` mean standard routing, which is the absence of the
/// field. `"fast"` normalizes to its wire spelling `"priority"`.
public func normalizedServiceTier(_ tier: String?) -> String? {
    guard let trimmed = tier?.trimmingCharacters(in: .whitespacesAndNewlines),
          !trimmed.isEmpty
    else { return nil }
    if trimmed.lowercased() == SERVICE_TIER_DEFAULT_REQUEST_VALUE { return nil }
    if trimmed.lowercased() == SERVICE_TIER_FAST_NAME { return SERVICE_TIER_FAST_REQUEST_VALUE }
    return trimmed
}

/// One selectable service tier advertised by a model catalog entry.
public struct ModelServiceTier: Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var name: String
    public var description: String?

    public init(id: String, name: String, description: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
    }

    public var isFast: Bool {
        id == SERVICE_TIER_FAST_REQUEST_VALUE
            || name.lowercased() == SERVICE_TIER_FAST_NAME
            || id.lowercased() == SERVICE_TIER_FAST_NAME
    }

    public enum CodingKeys: String, CodingKey {
        case id, name, description
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(description, forKey: .description)
    }
}

/// Parse the `serviceTiers` catalog from ACP model meta, dropping entries with
/// a blank id and defaulting a blank name to the id.
public func parseServiceTiersMeta(_ meta: [String: JSONValue]?) -> [ModelServiceTier]? {
    guard let raw = meta?[SERVICE_TIERS_META_KEY], case .array(let arr) = raw else {
        return nil
    }
    var tiers: [ModelServiceTier] = []
    for element in arr {
        guard let obj = element.objectValue else { continue }
        guard let id = obj["id"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty
        else { continue }
        let rawName = obj["name"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let description = obj["description"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        tiers.append(
            ModelServiceTier(
                id: id,
                name: rawName.isEmpty ? id : rawName,
                description: (description?.isEmpty ?? true) ? nil : description
            )
        )
    }
    return tiers.isEmpty ? nil : tiers
}

/// Whether the model meta advertises at least one Fast / priority service tier.
public func supportsFastServiceTierMeta(_ meta: [String: JSONValue]?) -> Bool {
    (parseServiceTiersMeta(meta) ?? []).contains { $0.isFast }
}

/// Parse the current session service-tier selection from model meta.
///
/// - Returns `nil` when the key is absent (the caller may preserve a prior
///   selection), `.some(nil)` for explicit `"default"` / empty (standard
///   routing), and `.some(.some(id))` for a concrete tier such as `"priority"`.
public func parseServiceTierMeta(_ meta: [String: JSONValue]?) -> String??  {
    guard let raw = meta?[SERVICE_TIER_META_KEY] else { return nil }
    // A non-string value is malformed meta, not a selection: ignore it.
    guard let s = raw.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) else {
        return nil
    }
    if s.isEmpty || s.lowercased() == SERVICE_TIER_DEFAULT_REQUEST_VALUE {
        return .some(nil)
    }
    return .some(s)
}
