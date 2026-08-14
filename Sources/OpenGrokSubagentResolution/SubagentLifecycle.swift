// SubagentLifecycle.swift
//
// Deduplication and deferred buffering for persisted subagent spawn/finish notifications.
// Port of `crates/codegen/xai-grok-pager/src/app/acp_handler/subagent_lifecycle.rs`.

import Foundation

public let MAX_DEFERRED_SUBAGENT_FINISHES: Int = 256
public let DEFERRED_FINISH_TTL: TimeInterval = 60.0 // 60s

public enum SubagentLifecycle: String, Sendable, Codable, Equatable, Hashable {
    case spawned
    case finished

    public var asStr: String { rawValue }
}

public enum LifecycleOrigin: String, Sendable, Codable, Equatable, Hashable {
    case stream
    case reconciliation
}

public struct SubagentLifecycleUpdate: Sendable, Equatable {
    public var childSessionID: String
    public var transition: SubagentLifecycle
    public var origin: LifecycleOrigin

    public init(childSessionID: String, transition: SubagentLifecycle, origin: LifecycleOrigin) {
        self.childSessionID = childSessionID
        self.transition = transition
        self.origin = origin
    }
}

public enum LifecycleDelivery: Sendable, Equatable, Hashable {
    case apply
    case dropDuplicate
    case awaitSpawn
}

public struct DeferredSubagentFinish<Payload: Sendable>: Sendable {
    public var notification: Payload
    public var insertedAt: Date

    public init(notification: Payload, insertedAt: Date = Date()) {
        self.notification = notification
        self.insertedAt = insertedAt
    }
}

public struct SubagentLifecycleState: Sendable, Equatable {
    public var isFinished: Bool
    public var hasRenderedRow: Bool

    public init(isFinished: Bool, hasRenderedRow: Bool) {
        self.isFinished = isFinished
        self.hasRenderedRow = hasRenderedRow
    }
}

public func decideSubagentLifecycleDelivery(
    existingState: SubagentLifecycleState?,
    childSessionID: String,
    transition: SubagentLifecycle,
    isReplay: Bool,
    origin: LifecycleOrigin
) -> LifecycleDelivery {
    guard let info = existingState else {
        switch transition {
        case .spawned:
            return .apply
        case .finished:
            return .awaitSpawn
        }
    }

    switch (transition, origin) {
    case (.spawned, _) where !isReplay || info.hasRenderedRow:
        return .dropDuplicate
    case (.spawned, _):
        return .apply
    case (.finished, .reconciliation):
        return .apply
    case (.finished, .stream) where info.isFinished:
        return .dropDuplicate
    case (.finished, .stream):
        return .apply
    }
}

public final class DeferredSubagentFinishBuffer<Payload: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var deferred: [String: DeferredSubagentFinish<Payload>] = [:]

    public init() {}

    public func deferFinish(
        childSessionID: String,
        payload: Payload,
        now: Date = Date()
    ) -> LifecycleDelivery {
        lock.lock()
        defer { lock.unlock() }

        pruneInternal(now: now)
        if deferred[childSessionID] == nil && deferred.count >= MAX_DEFERRED_SUBAGENT_FINISHES {
            evictOldestInternal()
        }
        deferred[childSessionID] = DeferredSubagentFinish(notification: payload, insertedAt: now)
        return .awaitSpawn
    }

    public func takeDeferredFinish(
        childSessionID: String,
        now: Date = Date()
    ) -> Payload? {
        lock.lock()
        defer { lock.unlock() }

        guard let entry = deferred.removeValue(forKey: childSessionID) else {
            return nil
        }
        if now.timeIntervalSince(entry.insertedAt) >= DEFERRED_FINISH_TTL {
            return nil
        }
        return entry.notification
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return deferred.count
    }

    private func pruneInternal(now: Date) {
        deferred = deferred.filter { _, entry in
            now.timeIntervalSince(entry.insertedAt) < DEFERRED_FINISH_TTL
        }
    }

    private func evictOldestInternal() {
        if let oldestKey = deferred.min(by: { $0.value.insertedAt < $1.value.insertedAt })?.key {
            deferred.removeValue(forKey: oldestKey)
        }
    }
}
