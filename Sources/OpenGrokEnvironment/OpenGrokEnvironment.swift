// OpenGrokEnvironment.swift
//
// Open Grok — Swift port of `xai-grok-env`.
//
// Backend environment presets for the Open Grok crate family: endpoint URL
// defaults, environment selection, and env-var test support.
//
// Public builds expose production endpoints. Values resolve as a `GROK_*`
// env-var override when set, else the compiled production default. This
// mirrors the Rust crate's `GrokBuildEnvironment` and `GrokBuildEndpoints`
// types and the `EnvVarGuard` RAII test helper.
//
// The endpoint set is intentionally minimal: only `Production` is exposed
// (matching the Rust crate, where `from_flags` always returns `Production`).
// The Swift port adds an injectable `environment` parameter to every endpoint
// resolver so tests are deterministic without mutating the real process
// environment.

import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(ucrt)
import ucrt
#endif

// MARK: - Endpoint set

/// The endpoint set for one backend environment.
public struct GrokBuildEndpoints: Sendable, Equatable, Hashable {
    public let cliChatProxyBaseURL: String
    public let assetServerURL: String
    public let relayWsURL: String
    public let gatewayWsURL: String
    public let wsOrigin: String

    public init(
        cliChatProxyBaseURL: String,
        assetServerURL: String,
        relayWsURL: String,
        gatewayWsURL: String,
        wsOrigin: String
    ) {
        self.cliChatProxyBaseURL = cliChatProxyBaseURL
        self.assetServerURL = assetServerURL
        self.relayWsURL = relayWsURL
        self.gatewayWsURL = gatewayWsURL
        self.wsOrigin = wsOrigin
    }

    /// Compiled production endpoints, matching
    /// `PRODUCTION_ENDPOINTS` in `xai-grok-env/src/lib.rs`.
    public static let production = GrokBuildEndpoints(
        cliChatProxyBaseURL: "https://cli-chat-proxy.grok.com/v1",
        assetServerURL: "https://assets.grok.com",
        relayWsURL: "wss://code.grok.com/ws/code-agent",
        gatewayWsURL: "wss://grok.com/ws/gw/",
        wsOrigin: "https://grok.com"
    )
}

// MARK: - Compiled production constants

/// Compiled production CLI chat proxy base URL.
public let PROD_CLI_CHAT_PROXY_BASE_URL: String = GrokBuildEndpoints.production.cliChatProxyBaseURL
/// Compiled production asset server URL.
public let PROD_ASSET_SERVER_URL: String = GrokBuildEndpoints.production.assetServerURL
/// Compiled production relay WebSocket URL.
public let PROD_RELAY_WS_URL: String = GrokBuildEndpoints.production.relayWsURL
/// Compiled production gateway WebSocket URL.
public let PROD_GATEWAY_WS_URL: String = GrokBuildEndpoints.production.gatewayWsURL
/// Compiled production WebSocket origin.
public let PROD_WS_ORIGIN: String = GrokBuildEndpoints.production.wsOrigin

// MARK: - Environment

/// Backend environment selector. Only `Production` is exposed by public
/// builds, matching `xai-grok-env` where `from_flags` always returns
/// `Production`.
public enum GrokBuildEnvironment: Sendable, Equatable, Hashable, CustomStringConvertible, Defaultable {

    /// The production environment.
    case production

    /// Swift `Defaultable` conformance for `Defaultable`-aware callers.
    public static var defaultValue: GrokBuildEnvironment { .production }

    /// Resolve an environment from dev/staging flags. Always returns
    /// `.production` in public builds (matching the Rust crate).
    public static func fromFlags(dev: Bool = false, staging: Bool = false) -> GrokBuildEnvironment {
        _ = dev
        _ = staging
        return .production
    }

    /// Indicator string for display; `nil` for Production.
    public var indicator: String? {
        switch self {
        case .production:
            return nil
        }
    }

    /// `true` when this is the production environment.
    public var isProduction: Bool {
        self == .production
    }

    /// Env-var prefix for overrides (`GROK_PRODUCTION_*`).
    public var envPrefix: String {
        switch self {
        case .production:
            return "GROK_PRODUCTION"
        }
    }

    /// Compiled endpoint set for this environment.
    public func endpoints() -> GrokBuildEndpoints {
        switch self {
        case .production:
            return .production
        }
    }

    /// Env-var override when the key is present, else the compiled endpoint.
    ///
    /// Mirrors the Rust `resolve` exactly: `std::env::var(key).unwrap_or_else(|_| compiled)`
    /// returns the environment value whenever the key is present, including an
    /// empty string (`""`). An explicitly empty override does NOT fall back to
    /// the compiled default; it returns `""`. This matches
    /// `std::env::var(...).unwrap_or_else(...)` semantics, where `VarError`
    /// is only returned for absent (not empty) keys.
    private func resolve(
        varSuffix: String,
        compiled: String,
        environment: [String: String]
    ) -> String {
        let key = "\(envPrefix)\(varSuffix)"
        if let override = environment[key] {
            return override
        }
        return compiled
    }

    /// The CLI chat proxy base URL, with `GROK_PRODUCTION_CLI_CHAT_PROXY_BASE_URL`
    /// override taking precedence over the compiled default.
    public func cliChatProxyBaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        resolve(
            varSuffix: "_CLI_CHAT_PROXY_BASE_URL",
            compiled: endpoints().cliChatProxyBaseURL,
            environment: environment
        )
    }

    /// The WebSocket origin, with `GROK_PRODUCTION_WS_ORIGIN` override taking
    /// precedence over the compiled default.
    public func wsOrigin(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        resolve(
            varSuffix: "_WS_ORIGIN",
            compiled: endpoints().wsOrigin,
            environment: environment
        )
    }

    /// The asset server URL, with `GROK_PRODUCTION_ASSET_SERVER_URL` override
    /// taking precedence over the compiled default.
    public func assetServerURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        resolve(
            varSuffix: "_ASSET_SERVER_URL",
            compiled: endpoints().assetServerURL,
            environment: environment
        )
    }

    /// The relay WebSocket URL (Web Frontend at `grok.com/code` driving a
    /// local agent). Not the cloud-sandbox gateway (`gatewayWsURL`); the two
    /// speak different protocols. `GROK_PRODUCTION_WS_URL` override takes
    /// precedence over the compiled default.
    public func relayWsURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        resolve(
            varSuffix: "_WS_URL",
            compiled: endpoints().relayWsURL,
            environment: environment
        )
    }

    /// The gateway WebSocket URL for `/cloud new` sandboxes. The
    /// `GROK_PRODUCTION_GATEWAY_WS_URL` opt-in takes precedence over the
    /// compiled default.
    public func gatewayWsURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        resolve(
            varSuffix: "_GATEWAY_WS_URL",
            compiled: endpoints().gatewayWsURL,
            environment: environment
        )
    }

    public var description: String {
        switch self {
        case .production:
            return "production"
        }
    }
}

/// Lightweight `Defaultable` protocol so callers can default to
/// `GrokBuildEnvironment.production` without depending on Swift's
/// `Defaultable` if it is unavailable.
public protocol Defaultable {
    static var defaultValue: Self { get }
}

// MARK: - EnvVarGuard (test support)

/// Serializes env-var mutation across tests; `setenv`/`unsetenv` mutate the
/// process-wide environment and are not thread-safe under Swift 6 strict
/// concurrency, so all access is funneled through this recursive lock.
///
/// `NSRecursiveLock` is used (rather than `NSLock`) so that a guard holding
/// the lock can still call `readEnvVar`/`setEnvVar`/`unsetEnvVar` on the same
/// thread without deadlocking — mirroring the Rust `MutexGuard` + `set_value`
/// pattern where the guard retains the mutex and `set_value` mutates under
/// the held lock.
private let envVarLock = NSRecursiveLock()

@usableFromInline
internal func readEnvVar(_ key: String) -> String? {
    envVarLock.lock()
    defer { envVarLock.unlock() }
    #if canImport(ucrt) || os(Windows)
    // `_dupenv_s` would be the Windows-native path; on Windows, getenv reads
    // the C runtime view that _putenv_s mutates, which is sufficient here.
    if let raw = getenv(key) {
        return String(cString: raw)
    }
    return nil
    #else
    if let raw = getenv(key) {
        return String(cString: raw)
    }
    return nil
    #endif
}

@usableFromInline
internal func setEnvVar(_ key: String, _ value: String) {
    envVarLock.lock()
    defer { envVarLock.unlock() }
    #if canImport(ucrt) || os(Windows)
    _ = _putenv_s(key, value)
    #else
    // `setenv(name, value, overwrite=1)` replaces any existing value.
    setenv(key, value, 1)
    #endif
}

@usableFromInline
internal func unsetEnvVar(_ key: String) {
    envVarLock.lock()
    defer { envVarLock.unlock() }
    #if canImport(ucrt) || os(Windows)
    // Setting to empty string is the canonical Windows way to "unset" via
    // the CRT environment block; `_putenv_s(key, "")` removes the entry.
    _ = _putenv_s(key, "")
    #else
    unsetenv(key)
    #endif
}

/// RAII env-var override for tests: constructors snapshot the prior value
/// under the global env lock and hold the lock for the guard's entire
/// lifetime, `restore()` (or `deinit`) restores the prior value and releases
/// the lock. This mirrors the Rust `EnvVarGuard`, which retains the
/// `MutexGuard` until `Drop` and restores exactly once.
///
/// **Concurrency semantics:** The guard holds `envVarLock` for its entire
/// lifetime, so concurrent guards cannot interleave or snapshot one another's
/// temporary values. The guard is NOT `Sendable` because it owns a non-Sendable
/// lock resource (the held `NSRecursiveLock`); it must be used within a single
/// concurrency domain. This matches the Rust `EnvVarGuard`, which is not
/// `Sendable` because it owns a `MutexGuard<'static, ()>`.
///
/// **Restore-once semantics:** `restore()` and `deinit` together restore
/// exactly once. An explicit `restore()` releases the lock and restores the
/// prior value; `deinit` is a no-op if `restore()` was already called. If
/// `restore()` was not called, `deinit` restores and releases the lock.
public final class EnvVarGuard {

    public let key: String
    private let previous: String?
    /// Tracks whether `restore()` has already run (explicitly or via `deinit`).
    /// Access is safe without additional synchronization because the guard is
    /// not `Sendable` and must be used within a single concurrency domain.
    private var restored: Bool = false

    private init(key: String, previous: String?) {
        self.key = key
        self.previous = previous
        // The lock was acquired by the static factory (`set`/`remove`) before
        // calling this initializer; the guard retains it until `restore()` or
        // `deinit`.
    }

    /// Set `key` to `value`, snapshotting the prior value and acquiring
    /// `envVarLock` for the guard's lifetime. The lock is held until
    /// `restore()` or `deinit`.
    public static func set(_ key: String, _ value: String) -> EnvVarGuard {
        envVarLock.lock()
        let prev = readEnvVar(key)
        setEnvVar(key, value)
        return EnvVarGuard(key: key, previous: prev)
    }

    /// Remove `key`, snapshotting the prior value and acquiring `envVarLock`
    /// for the guard's lifetime. The lock is held until `restore()` or
    /// `deinit`.
    public static func remove(_ key: String) -> EnvVarGuard {
        envVarLock.lock()
        let prev = readEnvVar(key)
        unsetEnvVar(key)
        return EnvVarGuard(key: key, previous: prev)
    }

    /// Update the value while still holding the env lock. Mirrors the Rust
    /// `EnvVarGuard::set_value`, which mutates under the held mutex.
    public func setValue(_ value: String) {
        // The guard holds `envVarLock`; `setEnvVar` re-enters the recursive
        // lock (no-op since it's already held by this thread) and mutates.
        setEnvVar(key, value)
    }

    /// Explicitly restore the prior value and release the env lock. Safe to
    /// call multiple times; only the first call has effect. `deinit` will be
    /// a no-op after this.
    public func restore() {
        guard !restored else { return }
        restored = true
        if let prev = previous {
            setEnvVar(key, prev)
        } else {
            unsetEnvVar(key)
        }
        envVarLock.unlock()
    }

    deinit {
        // Restore on scope exit if `restore()` was not called explicitly.
        // `deinit` runs when the last reference is released; for deterministic
        // restoration in tests, call `restore()` explicitly or let the guard
        // go out of scope.
        if !restored {
            restored = true
            if let prev = previous {
                setEnvVar(key, prev)
            } else {
                unsetEnvVar(key)
            }
            envVarLock.unlock()
        }
    }
}
