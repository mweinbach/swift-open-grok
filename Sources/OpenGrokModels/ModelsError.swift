// ModelsError.swift
//
// Errors produced by the model catalog layer.

import Foundation

public enum ModelsError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidDefaultModels(String)
    case invalidGlob(field: String, patterns: [String])
    case allowlistMatchesNothing(patterns: String)
    case allowlistExcludesDefault(id: String, source: String, patterns: String)
    case cacheCorrupt(String)
    case remoteMalformed(String)
    case cancelled
    case unsupportedProviderCatalog(String)

    public var description: String {
        switch self {
        case .invalidDefaultModels(let detail):
            return "invalid default models: \(detail)"
        case .invalidGlob(let field, let patterns):
            return "\(field): invalid glob(s): \(patterns.joined(separator: ", "))"
        case .allowlistMatchesNothing(let patterns):
            return "None of your available models match allowed_models (\(patterns)). Broaden the patterns or remove allowed_models, then try again."
        case .allowlistExcludesDefault(let id, let source, let patterns):
            return "\"\(id)\" (your \(source)) isn't allowed by allowed_models (\(patterns)). Add it to allowed_models, or set a different model."
        case .cacheCorrupt(let detail):
            return "models cache corrupt: \(detail)"
        case .remoteMalformed(let detail):
            return "remote models response malformed: \(detail)"
        case .cancelled:
            return "model catalog operation cancelled"
        case .unsupportedProviderCatalog(let detail):
            return "unsupported provider catalog: \(detail)"
        }
    }
}
