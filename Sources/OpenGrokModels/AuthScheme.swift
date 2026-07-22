// AuthScheme.swift
//
// Catalog-side copy of the sampler `AuthScheme` contract. OpenGrokSampler
// (same wave) cannot be imported; OpenGrokModels owns the wire/catalog view
// so capability and credential-header planning remain independently testable.
// R14 may re-export or converge on a single definition later without changing
// catalog persistence.

import Foundation
import OpenGrokSamplingTypes

/// How an API key is presented on outbound model requests.
///
/// Wire form: `snake_case` (`"bearer"`, `"x_api_key"`).
public enum AuthScheme: String, Codable, Sendable, Equatable, Hashable {
    case bearer
    case xApiKey = "x_api_key"

    public static let defaultValue: AuthScheme = .bearer
}

/// Effective auth scheme for a provider, matching
/// `effective_auth_scheme` in the Rust shell: Codex always uses Bearer.
public func effectiveAuthScheme(
    provider: ModelProvider,
    configured: AuthScheme
) -> AuthScheme {
    if provider.profile.sessionAuth.isCodex {
        return .bearer
    }
    return configured
}
