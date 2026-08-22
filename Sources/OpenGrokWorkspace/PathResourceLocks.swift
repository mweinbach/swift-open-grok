// PathResourceLocks.swift
//
// Canonical path / resource locks for local FS and process mediation.
// Ported from `xai-grok-tools` `FileOperationLockManager` semantics:
// per-path locks serialize same-path ops; exclusive lock blocks all paths.

import Foundation
import OpenGrokPaths

/// Kind of resource lock held by a workspace operation.
public enum ResourceLockKind: Sendable, Equatable {
    case path(String)
    case exclusive
    case process(String)
}

/// RAII-style async lock token. Release is idempotent.
public actor ResourceLockToken {
    private let manager: PathResourceLockManager
    private let kind: ResourceLockKind
    private var released = false

    init(manager: PathResourceLockManager, kind: ResourceLockKind) {
        self.manager = manager
        self.kind = kind
    }

    public func release() async {
        guard !released else { return }
        released = true
        await manager.release(kind)
    }

    deinit {
        guard !released else { return }
        // Best-effort: if caller forgot to release, schedule async release.
        let manager = self.manager
        let kind = self.kind
        Task { await manager.release(kind) }
    }
}

/// Serializes concurrent filesystem and process operations by canonical path.
public actor PathResourceLockManager {
    private var lockedPaths: Set<String> = []
    private var exclusiveActive = false
    private var processKeys: Set<String> = []
    private var waiters: [Waiter] = []

    private struct Waiter {
        var kind: ResourceLockKind
        var continuation: CheckedContinuation<Void, Never>
    }

    public init() {}

    /// Acquire a per-path lock. Canonicalize first so aliases serialize together.
    public func acquirePath(_ path: String) async -> ResourceLockToken {
        let key = canonicalizeKey(path)
        await waitUntilAvailable(for: .path(key))
        lockedPaths.insert(key)
        return ResourceLockToken(manager: self, kind: .path(key))
    }

    /// Exclusive lock: blocks all per-path and process locks.
    public func acquireExclusive() async -> ResourceLockToken {
        await waitUntilAvailable(for: .exclusive)
        exclusiveActive = true
        return ResourceLockToken(manager: self, kind: .exclusive)
    }

    /// Process / resource key lock (e.g. shell session id or command fingerprint).
    public func acquireProcess(_ key: String) async -> ResourceLockToken {
        let k = normalizeLexically(key)
        await waitUntilAvailable(for: .process(k))
        processKeys.insert(k)
        return ResourceLockToken(manager: self, kind: .process(k))
    }

    fileprivate func release(_ kind: ResourceLockKind) {
        switch kind {
        case .path(let p):
            lockedPaths.remove(p)
        case .exclusive:
            exclusiveActive = false
        case .process(let k):
            processKeys.remove(k)
        }
        drainWaiters()
    }

    private func waitUntilAvailable(for kind: ResourceLockKind) async {
        if canGrant(kind) { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(Waiter(kind: kind, continuation: cont))
        }
    }

    private func canGrant(_ kind: ResourceLockKind) -> Bool {
        if exclusiveActive { return false }
        switch kind {
        case .path(let p):
            return !hasExclusiveWaiterAhead() && !lockedPaths.contains(p)
        case .exclusive:
            return !hasExclusiveWaiterAhead() && lockedPaths.isEmpty && processKeys.isEmpty
        case .process(let k):
            return !hasExclusiveWaiterAhead() && !processKeys.contains(k)
        }
    }

    private func hasExclusiveWaiterAhead() -> Bool {
        waiters.contains {
            if case .exclusive = $0.kind { return true }
            return false
        }
    }

    private func drainWaiters() {
        while let waiter = waiters.first {
            switch waiter.kind {
            case .path(let path):
                guard !exclusiveActive, !lockedPaths.contains(path) else { return }
                waiters.removeFirst()
                lockedPaths.insert(path)
                waiter.continuation.resume()

            case .process(let key):
                guard !exclusiveActive, !processKeys.contains(key) else { return }
                waiters.removeFirst()
                processKeys.insert(key)
                waiter.continuation.resume()

            case .exclusive:
                guard !exclusiveActive, lockedPaths.isEmpty, processKeys.isEmpty else { return }
                waiters.removeFirst()
                exclusiveActive = true
                waiter.continuation.resume()
                return
            }
        }
    }

    private func canonicalizeKey(_ path: String) -> String {
        canonicalWorkspacePathKey(path)
    }
}
