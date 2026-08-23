// SessionSearchGate.swift
//
// Whether this process may keep a session-search index or execute session searches.
// Port of `crates/codegen/xai-grok-shell/src/session/storage/search_gate.rs`.

import Foundation
import OpenGrokConfigTypes

public enum SessionSearchGateState: UInt8, Sendable, Equatable {
    case unapplied = 0
    case `open` = 1
    case closed = 2
}

/// Resolve the actual launch's disk and deployment authority; ambient process
/// variables belong to another tenant when multiple sessions share a leader.
public func resolveSessionSearchSetting(
    environment: [String: String],
    document: TOMLValue? = nil,
    requirements: [TOMLValue]? = nil,
    remote: Bool? = nil
) -> Resolved<Bool> {
    let layers: ConfigLayers?
    do {
        layers = try ConfigLayers.load(environment: environment)
    } catch {
        layers = nil
    }

    let suppliedRequirements = requirements?.reversed()
        .compactMap { sessionSearchFeature($0) }
        .first
    let diskRequirements = layers.flatMap { loaded in
        [loaded.mdmRequirements, loaded.systemRequirements, loaded.userRequirements]
            .compactMap { $0 }
            .compactMap { sessionSearchFeature($0) }
            .first
    } ?? loadMergedRequirements(environment: environment).flatMap { sessionSearchFeature($0) }
    if let pinned = diskRequirements ?? suppliedRequirements {
        return Resolved(value: pinned, source: .requirement)
    }

    let managed: TOMLValue?
    let systemManaged: TOMLValue?
    if let layers {
        managed = layers.managed
        systemManaged = layers.systemManaged
    } else {
        managed = try? loadManagedConfig(environment: environment)
        systemManaged = try? loadSystemManagedConfig(environment: environment)
    }
    if sessionSearchFeature(managed) == false {
        return Resolved(value: false, source: .managedConfig)
    }
    if sessionSearchFeature(systemManaged) == false {
        return Resolved(value: false, source: .systemManagedConfig)
    }

    if let value = GrokEnvGates.sessionSearch(environment: environment) {
        return Resolved(value: value, source: .env)
    }
    if let value = sessionSearchFeature(document) {
        return Resolved(value: value, source: .config)
    }
    if let value = layers.flatMap({ sessionSearchFeature($0.user) }) {
        return Resolved(value: value, source: .userConfig)
    }
    if let value = sessionSearchFeature(managed) {
        return Resolved(value: value, source: .managedConfig)
    }
    if let value = sessionSearchFeature(systemManaged) {
        return Resolved(value: value, source: .systemManagedConfig)
    }
    if let remote {
        return Resolved(value: remote, source: .remote)
    }
    return Resolved(value: true, source: .default)
}

private func sessionSearchFeature(_ document: TOMLValue?) -> Bool? {
    guard case let .boolean(value)? = document?[path: ["features", "session_search"]] else {
        return nil
    }
    return value
}

/// One latch for the process, so the first workspace to turn search off turns it
/// off for every workspace hosted beside it.
public final class SessionSearchGate: @unchecked Sendable {
    public static let shared = SessionSearchGate()

    private let lock = NSLock()
    private var state: SessionSearchGateState = .unapplied
    private var closedBy: ConfigSource?

    public init() {}

    /// Off only: turning it back on would serve an index missing everything written meanwhile.
    public func applyGate(_ setting: Resolved<Bool>) {
        lock.lock()
        defer { lock.unlock() }

        if !setting.value {
            if closedBy == nil {
                closedBy = setting.source
            }
            state = .closed
            return
        }

        if state == .unapplied {
            state = .open
        }
    }

    /// Names the setting that turned search off, for a message like `off (a requirements.toml pin)`.
    public static func sessionSearchOffReason(_ source: ConfigSource) -> String {
        switch source {
        case .requirement:
            return "a requirements.toml pin or an MDM policy"
        case .env:
            return "the GROK_SESSION_SEARCH environment variable"
        case .remote:
            return "a remote setting"
        case .config, .userConfig, .managedConfig, .systemManagedConfig:
            return "the session_search key in a Grok config file"
        case .cli, .default:
            return "a local setting"
        }
    }

    public func closedBySource() -> ConfigSource? {
        lock.lock()
        defer { lock.unlock() }
        return closedBy
    }

    public func isIndexEnabled(environment: [String: String]) -> Bool {
        isIndexEnabled(
            environment: environment,
            resolved: resolveSessionSearchSetting(environment: environment)
        )
    }

    public func isIndexEnabled(
        environment: [String: String],
        resolved: Resolved<Bool>
    ) -> Bool {
        // Apply on every access: a newly arrived requirements deny or remote
        // update may close an already-open process gate, but can never reopen it.
        applyGate(resolved)
        lock.lock()
        defer { lock.unlock() }
        return state != .closed
    }

    public func sessionSearchTurnedOffBy() -> String? {
        guard let source = closedBySource() else { return nil }
        return Self.sessionSearchOffReason(source)
    }

    public func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        state = .unapplied
        closedBy = nil
    }
}
