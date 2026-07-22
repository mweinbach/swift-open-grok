// OpenGrokAuth.swift
//
// Open Grok — provider authentication and credential isolation.
//
// Ports:
//   * `xai-grok-auth` DI seam (HttpAuth, AuthCredentialProvider,
//     CredentialSnapshot, StaticAuthCredentialProvider, AuthRetryMiddleware)
//   * shell auth modules: models, storage, AuthManager, OIDC/device/external
//     login, refresh, logout, API-key/deployment-key precedence
//   * isolated Codex OAuth store (`codex-auth.json`) that never mutates xAI
//     `auth.json` or ACP primary-auth state
//
// Invariants:
//   * Bearer + identity fields always come from one atomic CredentialSnapshot.
//   * Deployment key outranks user/OAuth token and sends bare Bearer.
//   * Exactly one 401 refresh is attempted for cloneable requests; partial /
//     non-idempotent streams are never replayed.
//   * Cancellation leaves prior durable credentials intact unless a
//     replacement was committed.
//   * Secrets never appear in description, errors, logs, or fixtures.
//   * Codex and xAI stores are path-isolated under OPENGROK_HOME.

import Foundation
import OpenGrokPaths

/// Module-level constants for auth path policy.
public enum OpenGrokAuthPaths {
    /// Primary xAI / multi-scope credential store (under OPENGROK_HOME).
    public static let authFileName = "auth.json"
    /// Isolated Codex OAuth store — never shares scopes with `auth.json`.
    public static let codexAuthFileName = "codex-auth.json"
    /// Advisory lock sibling for `auth.json`.
    public static let authLockFileName = "auth.json.lock"
    /// Advisory lock sibling for `codex-auth.json`.
    public static let codexAuthLockFileName = "codex-auth.json.lock"

    /// Resolve `$OPENGROK_HOME/auth.json` (or OPENGROK_AUTH_PATH override).
    public static func authFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["OPENGROK_AUTH_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return OpenGrokStatePaths.stateDirectory(environment: environment)
            .appendingPathComponent(authFileName)
    }

    /// Resolve `$OPENGROK_HOME/codex-auth.json`.
    public static func codexAuthFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        OpenGrokStatePaths.stateDirectory(environment: environment)
            .appendingPathComponent(codexAuthFileName)
    }
}
