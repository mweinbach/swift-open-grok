// SessionInfo.swift
//
// Session identity and directory resolution. Ported from
// xai-grok-shared/src/session/{mod.rs, info.rs}.
//
// The Rust `Info` struct carries a session's `id` (ACP SessionId) and `cwd`.
// The `session_dir` helper resolves the per-session directory under
// `$OPENGROK_HOME/sessions/<cwd-hash>/`.
//
// In the Swift port, `SessionInfo` uses the canonical `SessionID` type from
// Identifiers.swift. The `sessionDir` helper is deferred to W0-S3
// (OpenGrokPaths) integration — this target defines the pure shape and a
// protocol for path resolution so later waves can wire the concrete
// `OpenGrokPaths` implementation.

import Foundation

/// Session identity: `id` + `cwd`.
///
/// Swift equivalent of Rust `xai_grok_shared::session::Info`.
/// Serializes as `{"id":"sess-123","cwd":"/path"}`.
public struct SessionInfo: Hashable, Sendable, Codable {
    /// The unique session identifier.
    public var id: SessionID

    /// The current working directory of the session.
    public var cwd: String

    public init(id: SessionID, cwd: String) {
        self.id = id
        self.cwd = cwd
    }

    // MARK: CodingKeys (snake_case to match Rust serde default)

    private enum CodingKeys: String, CodingKey {
        case id
        case cwd
    }
}

/// Protocol for resolving per-session directories.
///
/// The concrete implementation lives in `OpenGrokPaths` (W0-S3). This
/// protocol lets `OpenGrokShared` reference the resolution without importing
/// the paths target (W0-S4 has no dependencies).
public protocol SessionDirectoryResolver: Sendable {
    /// Resolve the base sessions directory for a given cwd.
    ///
    /// In Rust this is `grok_home::sessions_cwd_dir(cwd)`, which produces
    /// `$OPENGROK_HOME/sessions/<encoded-cwd>/`. The encoding is
    /// URL-encoding for short paths (≤ 255 bytes) and a
    /// `{slug}-{blake3_hex16}` fallback for long paths — see
    /// `xai_grok_config::paths::encode_cwd_dirname`.
    func sessionsCWDDirectory(cwd: String) -> URL

    /// Resolve the per-session directory for a given `SessionInfo`.
    ///
    /// Combines `sessionsCWDDirectory(info.cwd)` with `info.id`.
    func sessionDirectory(for info: SessionInfo) -> URL
}

// MARK: - Placeholder resolver (unavailable)
//
// The previous `PlaceholderSessionDirectoryResolver` used FNV-1a hashing to
// produce a per-cwd subdirectory. That is **semantically incompatible** with
// the Rust `sessions_cwd_dir` contract, which uses URL-encoding for short
// paths and a `{slug}-{blake3_hex16}` fallback for long paths (see
// `xai_grok_config::paths::encode_cwd_dirname`). A session persisted via the
// FNV-1a resolver would land in a different directory than the real
// OpenGrokPaths-backed resolver, breaking resume/search across the two
// implementations.
//
// W0-S4 has no dependency edges, so this target cannot import `OpenGrokPaths`
// or a `blake3` implementation to provide a compatible resolver. Rather than
// ship a default that silently diverges from Rust, the placeholder resolver
// is marked `@available(*, unavailable)` so callers cannot accidentally use
// it. Production code must inject a concrete `SessionDirectoryResolver`
// backed by the real `OpenGrokPaths` hashing contract; tests that need a
// stand-in should define their own resolver inline.
@available(*, unavailable, message: "PlaceholderSessionDirectoryResolver uses FNV-1a which is incompatible with Rust's sessions_cwd_dir (URL-encoding + blake3). Inject a SessionDirectoryResolver backed by OpenGrokPaths instead.")
public struct PlaceholderSessionDirectoryResolver: SessionDirectoryResolver {
    public let baseDirectory: URL

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    public func sessionsCWDDirectory(cwd: String) -> URL {
        fatalError("PlaceholderSessionDirectoryResolver is unavailable; inject an OpenGrokPaths-backed resolver instead.")
    }

    public func sessionDirectory(for info: SessionInfo) -> URL {
        fatalError("PlaceholderSessionDirectoryResolver is unavailable; inject an OpenGrokPaths-backed resolver instead.")
    }
}
