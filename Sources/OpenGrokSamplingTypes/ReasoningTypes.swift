// ReasoningTypes.swift
//
// Open Grok — Swift port of the reasoning-effort and reasoning-summary types
// in `crates/codegen/xai-grok-sampling-types/src/types.rs`.
//
// These enums drive model-side thinking budget and summary detail across all
// three backends (Chat Completions, Responses, Messages). Wire form is
// lowercase strings (`"xhigh"`, `"detailed"`, etc.) matching the Rust
// `#[serde(rename_all = "lowercase")]` contract.

import Foundation
import OpenGrokShared

/// Reasoning effort level. `none`/`minimal` are omitted on the Anthropic
/// Messages API.
public enum ReasoningEffort: String, Codable, Sendable, Equatable, Hashable, Defaultable {
    case none
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max
    case ultra

    public static let defaultValue: ReasoningEffort = .medium

    public var asString: String { rawValue }

    /// Anthropic Messages API `output_config.effort` string; `nil` for
    /// unsupported variants.
    public var messagesAPI: String? {
        switch self {
        case .none, .minimal: return nil
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        case .xhigh, .max, .ultra: return "max"
        }
    }
}

extension ReasoningEffort: CustomStringConvertible {
    public var description: String { rawValue }
}

/// Reasoning-summary detail requested from a Responses API model.
///
/// `none` is a local sentinel: callers omit `reasoning.summary` rather than
/// serializing the string `"none"` on the wire.
public enum ReasoningSummary: String, Codable, Sendable, Equatable, Hashable, Defaultable {
    case auto
    case concise
    case detailed
    case none

    public static let defaultValue: ReasoningSummary = .detailed

    /// Responses API wire value, or `nil` when summaries are disabled.
    public var wireValue: String? {
        switch self {
        case .auto: return "auto"
        case .concise: return "concise"
        case .detailed: return "detailed"
        case .none: return nil
        }
    }
}

/// How client-executed tools are exposed to the model.
public enum ToolMode: String, Codable, Sendable, Equatable, Hashable, Defaultable {
    case direct
    case codeMode
    case codeModeOnly

    public static let defaultValue: ToolMode = .direct
}

// MARK: - Reasoning-effort meta helpers
//
// Mirror `parse_canonical_effort_token`, `parse_reasoning_effort_meta`,
// `reasoning_effort_meta_value`, `parse_reasoning_efforts_meta`, and
// `reasoning_efforts_meta_value` in the Rust types.rs. These read the
// `reasoningEffort` / `reasoningEfforts` keys on an ACP `meta` object.

public let REASONING_EFFORT_META_KEY = "reasoningEffort"
public let SUPPORTS_REASONING_EFFORT_META_KEY = "supportsReasoningEffort"
public let REASONING_EFFORTS_META_KEY = "reasoningEfforts"

/// `true` when `meta` carries `supportsReasoningEffort: true`.
public func supportsReasoningEffortMeta(_ meta: [String: JSONValue]?) -> Bool {
    guard let meta, let v = meta[SUPPORTS_REASONING_EFFORT_META_KEY] else { return false }
    return v.boolValue ?? false
}

/// Canonical effort parse only; remapped menu ids need a model catalog.
/// Returns `nil` on unknown variant.
public func parseCanonicalEffortToken(_ token: String) -> ReasoningEffort? {
    ReasoningEffort(rawValue: token.lowercased())
}

/// Returns `nil` on type-mismatch or unknown variant (a warn-worthy condition
/// in Rust; here we silently return `nil` so the caller can keep the user's
/// persisted preference).
public func parseReasoningEffortMeta(_ meta: [String: JSONValue]?) -> ReasoningEffort? {
    guard let meta, let raw = meta[REASONING_EFFORT_META_KEY] else { return nil }
    guard let s = raw.stringValue else { return nil }
    return parseCanonicalEffortToken(s)
}

public func reasoningEffortMetaValue(_ effort: ReasoningEffort) -> JSONValue {
    .string(effort.asString)
}

/// One selectable reasoning-effort option for a model.
public struct ReasoningEffortOption: Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var value: ReasoningEffort
    public var label: String
    public var description: String?
    public var isDefault: Bool

    public init(id: String, value: ReasoningEffort, label: String, description: String?, isDefault: Bool) {
        self.id = id
        self.value = value
        self.label = label
        self.description = description
        self.isDefault = isDefault
    }

    public enum CodingKeys: String, CodingKey {
        case id, value, label, description
        case isDefault = "default"
    }

    /// Accept either a bare canonical value string (`"xhigh"`) or a table
    /// with `value` required and everything else optional, mirroring the
    /// Rust `#[serde(untagged)] RawReasoningEffortOption`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bare = try? container.decode(String.self) {
            guard let value = ReasoningEffort(rawValue: bare.lowercased()) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "invalid reasoning effort: \(bare)"
                )
            }
            let id = value.asString
            self.init(id: id, value: value, label: humanizeEffortID(id), description: nil, isDefault: false)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let value = try c.decode(ReasoningEffort.self, forKey: .value)
        let id = try c.decodeIfPresent(String.self, forKey: .id) ?? value.asString
        let label = try c.decodeIfPresent(String.self, forKey: .label) ?? humanizeEffortID(id)
        let description = try c.decodeIfPresent(String.self, forKey: .description)
        let isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        self.init(id: id, value: value, label: label, description: description, isDefault: isDefault)
    }
}

/// Uppercase the first character of an id for a default label; `"xhigh"`
/// becomes `"Xhigh"`, `"deep"` becomes `"Deep"`.
private func humanizeEffortID(_ id: String) -> String {
    guard let first = id.first else { return "" }
    return String(first.uppercased()) + id.dropFirst()
}

/// Parse a JSON array of reasoning-effort options element-by-element,
/// skipping any entry whose `value` fails to parse (forward-compat for tiers
/// a newer server introduces). The single home for the skip-invalid rule.
public func parseReasoningEffortOptions(_ arr: [JSONValue]) -> [ReasoningEffortOption] {
    var out: [ReasoningEffortOption] = []
    for el in arr {
        if let opt = try? JSONDecoder().decode(ReasoningEffortOption.self, from: JSONEncoder().encode(el)) {
            out.append(opt)
        }
    }
    return out
}

/// Parse the per-model reasoning-effort menu from a model's ACP `meta`.
/// Returns `nil` when the key is absent, is not an array, or yields no usable
/// options after skip-invalid — so "absent" and "present-but-unusable"
/// collapse to the same fallback path.
public func parseReasoningEffortsMeta(_ meta: [String: JSONValue]?) -> [ReasoningEffortOption]? {
    guard let meta, let raw = meta[REASONING_EFFORTS_META_KEY] else { return nil }
    guard let arr = raw.arrayValue else { return nil }
    let opts = parseReasoningEffortOptions(arr)
    return opts.isEmpty ? nil : opts
}

public func reasoningEffortsMetaValue(_ opts: [ReasoningEffortOption]) -> JSONValue {
    (try? JSONValue.encode(opts)) ?? .array([])
}
