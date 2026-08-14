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

    public func isIndexEnabled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .closed:
            return false
        case .open:
            return true
        case .unapplied:
            let env = GrokEnvGates.sessionSearch(environment: ProcessInfo.processInfo.environment)
            let setting = Resolved<Bool>(value: env ?? true, source: env != nil ? .env : .default)
            if !setting.value {
                closedBy = setting.source
                state = .closed
                return false
            } else {
                state = .open
                return true
            }
        }
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
