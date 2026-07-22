// Events.swift
//
// Public event types for OpenGrokFSNotify — port of xai-fsnotify `event.rs`.
// Pure data: no I/O. Safe for workspace translation layers.

import Foundation

/// Kind of a workspace file change. Access/Any/Other OS events are filtered
/// before they reach this type.
public enum FsEventKind: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case created
    case modified
    case removed
    case renamed
}

/// Git metadata surface that consumers care about.
public enum GitMetaKind: String, Sendable, Equatable, Hashable, Codable, CaseIterable, Comparable {
    case headChanged = "head_changed"
    case indexChanged = "index_changed"
    case refsChanged = "refs_changed"
    case fetchHeadChanged = "fetch_head_changed"

    public static func < (lhs: GitMetaKind, rhs: GitMetaKind) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One semantic event from the local workspace. Causal order on the source's
/// broadcast channel. `filesChanged` paths share a single `kind` per debounce
/// window.
public enum FsEvent: Sendable, Equatable {
    /// Workspace file changes; all paths share `kind`. Paths under `git_dir`
    /// are excluded (metadata surfaces as `gitMetaChanged`; lock files drop).
    case filesChanged(paths: [String], kind: FsEventKind)

    /// A git metadata file changed (HEAD, index, refs/, FETCH_HEAD).
    case gitMetaChanged(kind: GitMetaKind)

    /// VCS lock activity observed (`index.lock` / `gc.pid` / Sapling `wlock`).
    case gitOperationStarted

    /// Lock has been gone for `settleMilliseconds`; rapid lock cycles merge
    /// into one operation. `headChanged` reports whether HEAD differs from
    /// its value when the operation's first lock appeared.
    case gitOperationCompleted(headChanged: Bool)

    /// Platform overflow / rescan signal (watcher dropped events).
    case overflow

    /// Explicit rescan request (e.g. after overflow or restart).
    case rescan
}

/// Low-level normalized OS event kind used by platform adapters before the
/// semantic layer classifies git metadata / lock state.
public enum WatchEventKind: String, Sendable, Equatable, Codable, CaseIterable {
    case create
    case modify
    case remove
    case rename
    case overflow
    case rescan
}

/// A single normalized filesystem event from a platform adapter.
public struct WatchEvent: Sendable, Equatable {
    public var kind: WatchEventKind
    public var path: String

    public init(kind: WatchEventKind, path: String) {
        self.kind = kind
        self.path = path
    }

    /// Map to semantic `FsEventKind` when the low-level kind is a file change.
    public var fsEventKind: FsEventKind? {
        switch kind {
        case .create: return .created
        case .modify: return .modified
        case .remove: return .removed
        case .rename: return .renamed
        case .overflow, .rescan: return nil
        }
    }
}
