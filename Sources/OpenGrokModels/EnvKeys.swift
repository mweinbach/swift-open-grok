// EnvKeys.swift
//
// Port of `EnvKeys` from `xai-grok-shell/src/agent/config.rs`.
//
// One or more environment variable names that may hold a model API key.
// Wire form is untagged: a string or an array of strings. At resolve time
// the first set, non-blank value wins.

import Foundation

/// Environment variable name(s) that may hold a provider API key.
public enum EnvKeys: Sendable, Hashable, Codable, CustomStringConvertible {
    case one(String)
    case many([String])

    /// Single-name convenience constructor.
    public static func single(_ name: String) -> EnvKeys { .one(name) }

    /// Construct from an ordered list (empty names dropped).
    public static func new(_ names: [String]) -> EnvKeys {
        let cleaned = names.filter { !$0.isEmpty }
        switch cleaned.count {
        case 0: return .many([])
        case 1: return .one(cleaned[0])
        default: return .many(cleaned)
        }
    }

    public var isEmpty: Bool {
        switch self {
        case .one(let s): return s.isEmpty
        case .many(let v): return v.isEmpty
        }
    }

    /// Configured names in priority order.
    public var names: [String] {
        switch self {
        case .one(let s): return [s]
        case .many(let v): return v
        }
    }

    /// First non-empty name, if any.
    public var primary: String? {
        names.first { !$0.isEmpty }
    }

    public var description: String { names.joined(separator: ", ") }

    /// Resolve the first set, non-blank value among configured names.
    public func resolveValue(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        resolveValue { environment[$0] }
    }

    /// Testable resolve with an injected getenv.
    public func resolveValue(_ getenv: (String) -> String?) -> String? {
        for name in names {
            if let value = getenv(name), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            self = .one(s)
            return
        }
        if let arr = try? container.decode([String].self) {
            self = .many(arr)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "EnvKeys expects a string or array of strings"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .one(let s): try container.encode(s)
        case .many(let v): try container.encode(v)
        }
    }

    public static func == (lhs: EnvKeys, rhs: EnvKeys) -> Bool {
        lhs.names == rhs.names
    }

    public func hash(into hasher: inout Hasher) {
        for n in names { hasher.combine(n) }
    }
}
