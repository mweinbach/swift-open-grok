// ExportBoundary.swift
//
// The monotonic xAI export authorization boundary and the share-session wire
// types. Ported from the Rust reference at pin 9ed09e2a:
//
//   * `ProviderBoundary` —
//     `crates/codegen/xai-grok-shell/src/session/persistence.rs:1631-1668`.
//     One shared, monotonic guard: the first time a provider whose profile
//     denies xAI-only services is observed, the boundary closes and NEVER
//     reopens for the life of the session. Persistence, feedback, and trace
//     upload all consult the same guard so a mid-session provider switch is
//     visible to every export path immediately.
//   * `ShareSessionRequest` / `ShareSessionResponse` —
//     `crates/codegen/xai-grok-shell/src/session/mod.rs:295-306`, the
//     `x.ai/share_session` ACP extension payload.
//
// Naming: upstream calls the flag `ever_used_codex` because Codex was the
// first boundary-closing provider, but the semantics are profile-driven —
// "any provider whose profile denies xAI services"
// (persistence.rs:1650-1652 deliberately avoids a provider-specific boolean
// so new providers need no new flag). This port already spells that
// `everUsedNonXAI` in `OpenGrokProviderSession` (`canExportToXAI`), so the
// same spelling is used here.

import Foundation
import OpenGrokSamplingTypes

/// Shared, monotonic guard for xAI-only session exports.
///
/// Reference-type semantics are the port of upstream's `Arc<AtomicBool>`:
/// every handed-out reference to one instance observes the same flag, which
/// is what lets a persistence actor, a feedback manager, and a trace/upload
/// path see a provider switch the moment it happens
/// (persistence.rs:1633-1634). Do not add a `copy()` — a value-copy would
/// silently detach a consumer from the session's real boundary, which is
/// exactly the "succeeds, does nothing, says nothing" failure this type
/// exists to prevent.
public final class ExportBoundary: @unchecked Sendable {
    private let lock = NSLock()
    private var closed: Bool

    /// `ProviderBoundary::new` (persistence.rs:1641-1645). Pass the persisted
    /// `ever_used_codex` summary value when rehydrating a session; a session
    /// that crossed the boundary in a previous process stays closed.
    public init(everUsedNonXAI: Bool = false) {
        self.closed = everUsedNonXAI
    }

    /// Observe a provider; returns `true` only on the call that first closes
    /// the boundary (persistence.rs:1653-1659, including its "first close"
    /// contract). The decision is taken from the provider PROFILE, not the
    /// provider identity, so a new provider with `xaiServices: .denied`
    /// closes the boundary with no edit here.
    @discardableResult
    public func observe(_ provider: ModelProvider) -> Bool {
        guard !provider.profile.allowsXaiServices else { return false }
        lock.lock()
        defer { lock.unlock() }
        if closed { return false }
        closed = true
        return true
    }

    /// In-place monotonic synchronization with a persisted or external marker.
    /// Once closed, it can never be reopened.
    public func sync(everUsedNonXAI: Bool) {
        guard everUsedNonXAI else { return }
        lock.lock()
        defer { lock.unlock() }
        closed = true
    }

    /// Upstream `ever_used_codex()` (persistence.rs:1661-1663).
    public var everUsedNonXAI: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    /// Upstream `allows_xai_export()` (persistence.rs:1665-1667). Every
    /// xAI-only export gate — share, feedback, trace upload — reads this
    /// immediately before acting, never a cached copy.
    public var allowsXaiExport: Bool {
        !everUsedNonXAI
    }
}

// MARK: - `x.ai/share_session` wire types

/// Request to share a session via URL (session/mod.rs:297-300).
public struct ShareSessionRequest: Codable, Sendable, Equatable, Hashable {
    public var sessionID: String

    public init(sessionID: String) {
        self.sessionID = sessionID
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
    }
}

/// Response containing the shareable URL (session/mod.rs:301-305).
public struct ShareSessionResponse: Codable, Sendable, Equatable, Hashable {
    public var shareURL: String

    public init(shareURL: String) {
        self.shareURL = shareURL
    }

    private enum CodingKeys: String, CodingKey {
        case shareURL = "share_url"
    }
}

public enum ShareSessionWireCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
