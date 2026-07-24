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
public final class ResourceLockToken: @unchecked Sendable {
    private let manager: PathResourceLockManager
    private let kind: ResourceLockKind
    private let lock = NSLock()
    private var released = false

    init(manager: PathResourceLockManager, kind: ResourceLockKind) {
        self.manager = manager
        self.kind = kind
    }

    public func release() async {
        lock.lock()
        let already = released
        released = true
        lock.unlock()
        guard !already else { return }
        await manager.release(kind)
    }

    deinit {
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
        let k = canonicalizeKey(key)
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
        if hasExclusiveWaiterAhead() { return false }
        switch kind {
        case .path(let p):
            return !lockedPaths.contains(p)
        case .exclusive:
            return lockedPaths.isEmpty && processKeys.isEmpty && !exclusiveActive
        case .process(let k):
            return !processKeys.contains(k)
        }
    }

    private func hasExclusiveWaiterAhead() -> Bool {
        waiters.contains {
            if case .exclusive = $0.kind { return true }
            return false
        }
    }

    private func drainWaiters() {
        var remaining: [Waiter] = []
        for waiter in waiters {
            if canGrant(waiter.kind) {
                switch waiter.kind {
                case .path(let p): lockedPaths.insert(p)
                case .exclusive: exclusiveActive = true
                case .process(let k): processKeys.insert(k)
                }
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }

    private func canonicalizeKey(_ path: String) -> String {
        normalizeLexically(path)
    }
}
