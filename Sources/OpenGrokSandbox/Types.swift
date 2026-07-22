// Types.swift
//
// Sandbox events, metrics, and mode contracts. Ported from
// `xai-grok-sandbox/src/types.rs` with the W4-S1 bootstrap mode ladder
// preserved for session resume pinning.

import Foundation

// MARK: - Errors

/// Sandbox errors.
public enum SandboxError: Error, Equatable, Sendable, CustomStringConvertible {
    case profileInvalid(String)
    case enforcementFailed(String)
    case unsupported(String)
    case modePinningViolation(String)
    case capabilityLost(String)
    case configConflict(String)

    public var description: String {
        switch self {
        case .profileInvalid(let d): return "sandbox profile invalid: \(d)"
        case .enforcementFailed(let d): return "sandbox enforcement failed: \(d)"
        case .unsupported(let d): return "sandbox unsupported: \(d)"
        case .modePinningViolation(let d): return "sandbox mode pin violation: \(d)"
        case .capabilityLost(let d): return "sandbox capability lost: \(d)"
        case .configConflict(let d): return "sandbox config conflict: \(d)"
        }
    }
}

// MARK: - Mode / capability (session pin ladder)

/// The sandbox mode selected before agent work and persisted with the session.
///
/// Ordering for resume pinning: `none < readOnly < restricted`. A resumed
/// session may never weaken relative to the persisted mode.
public enum SandboxMode: String, Sendable, Equatable, Codable, CaseIterable {
    case none
    case readOnly
    case restricted

    public var rank: Int {
        switch self {
        case .none: return 0
        case .readOnly: return 1
        case .restricted: return 2
        }
    }

    /// Map a profile name into the coarser session-pin mode ladder.
    public static func from(profile: ProfileName) -> SandboxMode {
        switch profile {
        case .off: return .none
        case .readOnly: return .readOnly
        case .workspace, .devbox, .strict, .custom: return .restricted
        }
    }
}

/// A capability granted (or denied) by a sandbox profile.
public enum SandboxCapability: String, Sendable, Equatable, Codable, Hashable {
    case networkAccess
    case processSpawn
    case fileSystemWrite
    case tempDirectoryAccess
    case openGrokHomeAccess
    case toolBundleAccess
}

// MARK: - Events / metrics

/// Discriminator for sandbox telemetry events.
public enum SandboxEventType: String, Codable, Sendable, Hashable {
    case profileApplied = "profile_applied"
    case applyFailed = "apply_failed"
    case fsViolation = "fs_violation"
    case netViolation = "net_violation"
    case bypassGranted = "bypass_granted"
    case bypassDenied = "bypass_denied"
    case capabilityProbe = "capability_probe"
}

/// A recorded sandbox event for telemetry and debugging.
public struct SandboxEvent: Codable, Sendable, Equatable {
    public var timestamp: Date
    public var eventType: SandboxEventType
    public var profile: String
    public var workspace: String?
    public var platform: String?
    public var enforced: Bool?
    public var restrictNetwork: Bool?
    public var readWritePaths: [String]?
    public var readOnlyPaths: [String]?
    public var denyPaths: [String]?
    public var operation: String?
    public var target: String?
    public var command: String?
    public var toolCallId: String?
    public var error: String?

    public init(
        timestamp: Date = Date(),
        eventType: SandboxEventType,
        profile: String,
        workspace: String? = nil,
        platform: String? = nil,
        enforced: Bool? = nil,
        restrictNetwork: Bool? = nil,
        readWritePaths: [String]? = nil,
        readOnlyPaths: [String]? = nil,
        denyPaths: [String]? = nil,
        operation: String? = nil,
        target: String? = nil,
        command: String? = nil,
        toolCallId: String? = nil,
        error: String? = nil
    ) {
        self.timestamp = timestamp
        self.eventType = eventType
        self.profile = profile
        self.workspace = workspace
        self.platform = platform
        self.enforced = enforced
        self.restrictNetwork = restrictNetwork
        self.readWritePaths = readWritePaths
        self.readOnlyPaths = readOnlyPaths
        self.denyPaths = denyPaths
        self.operation = operation
        self.target = target
        self.command = command
        self.toolCallId = toolCallId
        self.error = error
    }

    public static func profileApplied(
        profile: String,
        workspace: URL,
        resolved: ResolvedSandboxProfile
    ) -> SandboxEvent {
        SandboxEvent(
            eventType: .profileApplied,
            profile: profile,
            workspace: workspace.path,
            platform: PlatformSandboxSupport.platformLabel,
            enforced: true,
            restrictNetwork: resolved.restrictNetwork,
            readWritePaths: resolved.readWrite.map(\.path),
            readOnlyPaths: resolved.readOnly.isEmpty ? nil : resolved.readOnly.map(\.path),
            denyPaths: resolved.deny.isEmpty ? nil : resolved.deny.map(\.path)
        )
    }

    public static func applyFailed(
        profile: String,
        workspace: URL,
        error: String
    ) -> SandboxEvent {
        SandboxEvent(
            eventType: .applyFailed,
            profile: profile,
            workspace: workspace.path,
            platform: PlatformSandboxSupport.platformLabel,
            enforced: false,
            error: error
        )
    }

    public static func fsViolation(profile: String, target: String, operation: String) -> SandboxEvent {
        SandboxEvent(
            eventType: .fsViolation,
            profile: profile,
            operation: operation,
            target: target
        )
    }

    public static func netViolation(profile: String, target: String) -> SandboxEvent {
        SandboxEvent(
            eventType: .netViolation,
            profile: profile,
            operation: "connect",
            target: target
        )
    }
}

/// Counters for sandbox activity.
public final class SandboxMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var _fsViolations: UInt64 = 0
    private var _netViolations: UInt64 = 0
    private var _bypassesGranted: UInt64 = 0
    private var _bypassesDenied: UInt64 = 0

    public init() {}

    public func incFsViolation() { lock.withLock { _fsViolations += 1 } }
    public func incNetViolation() { lock.withLock { _netViolations += 1 } }
    public func incBypassGranted() { lock.withLock { _bypassesGranted += 1 } }
    public func incBypassDenied() { lock.withLock { _bypassesDenied += 1 } }

    public var fsViolationCount: UInt64 { lock.withLock { _fsViolations } }
    public var netViolationCount: UInt64 { lock.withLock { _netViolations } }
    public var bypassesGrantedCount: UInt64 { lock.withLock { _bypassesGranted } }
    public var bypassesDeniedCount: UInt64 { lock.withLock { _bypassesDenied } }
}

// MARK: - Logger

/// In-memory sandbox event logger with optional on-disk append.
public final class SandboxLogger: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [SandboxEvent] = []
    public let metrics = SandboxMetrics()
    public var logDirectory: URL?

    public init(logDirectory: URL? = nil) {
        self.logDirectory = logDirectory
    }

    public func log(_ event: SandboxEvent) {
        lock.withLock {
            events.append(event)
            switch event.eventType {
            case .fsViolation: metrics.incFsViolation()
            case .netViolation: metrics.incNetViolation()
            case .bypassGranted: metrics.incBypassGranted()
            case .bypassDenied: metrics.incBypassDenied()
            default: break
            }
        }
    }

    public func snapshot() -> [SandboxEvent] {
        lock.withLock { events }
    }

    public func flushToDisk() throws {
        guard let dir = logDirectory else { return }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("sandbox-events.jsonl")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let batch = lock.withLock { events }
        var data = Data()
        for event in batch {
            let line = try encoder.encode(event)
            data.append(line)
            data.append(0x0A)
        }
        if FileManager.default.fileExists(atPath: path.path) {
            let handle = try FileHandle(forWritingTo: path)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: path, options: .atomic)
        }
        lock.withLock { events.removeAll(keepingCapacity: true) }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
