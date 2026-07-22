// Errors.swift
//
// Auth error types. Messages never include secret material.

import Foundation
import OpenGrokSecrets

/// Why a token refresh terminally failed (OAuth2 IdP codes).
public enum RefreshTokenFailedReason: String, Sendable, Equatable, Hashable {
    /// `invalid_grant` — refresh token expired, reused, or revoked.
    case refreshTokenRejected
    /// `invalid_client` — client credential rejected.
    case clientRejected
    /// Escalation from repeated transient failures.
    case other

    /// Sticky until credential changes (`RefreshTokenRejected`).
    public var isSticky: Bool {
        switch self {
        case .refreshTokenRejected: return true
        case .clientRejected, .other: return false
        }
    }

    public var userMessage: String {
        switch self {
        case .refreshTokenRejected:
            return "Your session has expired. Run `open-grok login` to sign in again."
        case .clientRejected:
            return "Authentication is temporarily unavailable. Run `open-grok login` if this persists."
        case .other:
            return "Authentication could not be refreshed. Run `open-grok login` to sign in again."
        }
    }
}

/// Terminal refresh failure.
public struct RefreshTokenFailedError: Error, Sendable, Equatable, CustomStringConvertible {
    public var reason: RefreshTokenFailedReason
    public init(reason: RefreshTokenFailedReason) { self.reason = reason }
    public var description: String { reason.userMessage }
}

/// Recoverability axis of a token-refresh attempt.
public enum RefreshTokenError: Error, Sendable, Equatable, CustomStringConvertible {
    case permanent(RefreshTokenFailedError)
    case transient(String)

    public var description: String {
        switch self {
        case .permanent(let e): return e.description
        case .transient(let message): return "auth refresh failed: \(SecretSafe.message(message))"
        }
    }

    public var isPermanent: Bool {
        if case .permanent = self { return true }
        return false
    }
}

/// Top-level authentication errors.
public enum AuthError: Error, Sendable, Equatable, CustomStringConvertible {
    case notLoggedIn
    case tokenExpiredNoRefresh
    case serverRejectedNoRecovery
    case recoveryExhausted
    case pinnedTeamMismatch(message: String)
    case apiKeyAuthDisabled
    case refresh(RefreshTokenError)
    case cancelled
    case storage(String)
    case protocolError(String)

    public var description: String {
        switch self {
        case .notLoggedIn:
            return "Not logged in. Run `open-grok login`."
        case .tokenExpiredNoRefresh:
            return "Token expired. Run `open-grok login` to re-authenticate."
        case .serverRejectedNoRecovery:
            return "Authentication rejected by server. Run `open-grok login` to re-authenticate."
        case .recoveryExhausted:
            return "Auth recovery exhausted; re-authentication required."
        case .pinnedTeamMismatch(let message):
            return "\(message) Run `open-grok login` to sign in with the required team."
        case .apiKeyAuthDisabled:
            return "API-key auth is disabled by your administrator. Run `open-grok login` to authenticate."
        case .refresh(let e):
            return e.description
        case .cancelled:
            return "Authentication cancelled."
        case .storage(let detail):
            return "Auth storage error: \(SecretSafe.message(detail))"
        case .protocolError(let detail):
            return "Auth protocol error: \(SecretSafe.message(detail))"
        }
    }

    public static func transient(_ message: String) -> AuthError {
        .refresh(.transient(message))
    }

    public static func permanent(_ reason: RefreshTokenFailedReason) -> AuthError {
        .refresh(.permanent(RefreshTokenFailedError(reason: reason)))
    }
}

/// Best-effort scrub of free-form error messages before they surface.
enum SecretSafe {
    static func message(_ input: String) -> String {
        SecretSanitizer.redactSecrets(input)
    }
}
