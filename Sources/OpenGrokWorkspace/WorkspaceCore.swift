// WorkspaceCore.swift
//
// Workspace configuration, handle, and operation boundary.
// Partial port of `xai-grok-workspace` focused on security-critical seams.

import Foundation
import OpenGrokPaths
import OpenGrokShared

// MARK: - Errors

public enum WorkspaceRuntimeError: Error, Equatable, Sendable, CustomStringConvertible {
    case notConnected
    case permissionDenied(String)
    case pathBoundary(String)
    case sandboxRequired(String)
    case cancelled
    case io(String)
    case remoteUnavailable(String)
    case unsupported(String)

    public var description: String {
        switch self {
        case .notConnected: return "workspace not connected"
        case .permissionDenied(let d): return "permission denied: \(d)"
        case .pathBoundary(let d): return "path boundary: \(d)"
        case .sandboxRequired(let d): return "sandbox required: \(d)"
        case .cancelled: return "cancelled"
        case .io(let d): return "io: \(d)"
        case .remoteUnavailable(let d): return "remote unavailable: \(d)"
        case .unsupported(let d): return "unsupported: \(d)"
        }
    }
}

// MARK: - Config

public enum IsolationMode: String, Codable, Sendable, Equatable {
    case none
    case worktree
    case sandbox
}

public struct WorkspaceConfig: Sendable, Equatable {
    public var root: URL
    public var openGrokHome: URL
    public var isolation: IsolationMode
    public var permissionConfig: PermissionConfig
    public var yoloPinReason: String?
    public var requireSandbox: Bool

    public init(
        root: URL,
        openGrokHome: URL = OpenGrokStatePaths.stateDirectory(
            environment: ProcessInfo.processInfo.environment
        ),
        isolation: IsolationMode = .none,
        permissionConfig: PermissionConfig = PermissionConfig(),
        yoloPinReason: String? = nil,
        requireSandbox: Bool = false
    ) {
        self.root = root
        self.openGrokHome = openGrokHome
        self.isolation = isolation
        self.permissionConfig = permissionConfig
        self.yoloPinReason = yoloPinReason
        self.requireSandbox = requireSandbox
    }
}

// MARK: - Capability

public enum CapabilityMode: String, Codable, Sendable, Equatable {
    case full
    case readOnly
    case restricted
}

// MARK: - Workspace ops boundary

/// Local workspace operations with permission + path boundary enforcement.
///
/// Every filesystem operation crosses the same permission and path-boundary
/// checks. Local fallback must never bypass a denied or unavailable remote
/// policy.
public actor LocalWorkspaceOps {
    public nonisolated let root: URL
    public nonisolated let boundary: PathBoundary
    public let permissions: PermissionHandle
    public let config: WorkspaceConfig
    /// When set, remote policy is authoritative; local fallback must not bypass.
    public private(set) var remotePolicyAvailable: Bool
    public private(set) var remotePolicyDenied: Bool

    public init(config: WorkspaceConfig, remotePolicyAvailable: Bool = false) {
        self.config = config
        self.root = config.root
        self.boundary = PathBoundary(root: config.root)
        self.permissions = PermissionHandle(
            config: config.permissionConfig,
            yoloPinReason: config.yoloPinReason
        )
        self.remotePolicyAvailable = remotePolicyAvailable
        self.remotePolicyDenied = false
    }

    public func setRemotePolicy(available: Bool, denied: Bool = false) {
        remotePolicyAvailable = available
        remotePolicyDenied = denied
    }

    public nonisolated func resolvePath(_ raw: String) throws -> URL {
        do {
            return try boundary.resolve(raw)
        } catch {
            throw WorkspaceRuntimeError.pathBoundary("\(error)")
        }
    }

    public func requestPermission(
        access: AccessKind,
        toolName: String,
        toolCallId: String
    ) async -> PermissionDecision {
        // Local fallback must never bypass a denied or unavailable remote policy.
        if remotePolicyDenied {
            return .policyDeny("remote policy denied this operation")
        }
        if config.requireSandbox && remotePolicyAvailable == false
            && config.isolation == .sandbox
        {
            // Remote sandbox policy missing — fail closed rather than open local.
            return .policyDeny("sandbox policy unavailable; refusing local fallback")
        }
        return await permissions.request(
            access: access,
            toolName: toolName,
            toolCallId: toolCallId
        )
    }

    public func readFile(path: String, toolCallId: String) async throws -> Data {
        let url = try resolvePath(path)
        let decision = await requestPermission(
            access: .read(url.path),
            toolName: "read_file",
            toolCallId: toolCallId
        )
        try ensureAllowed(decision)
        do {
            return try Data(contentsOf: url)
        } catch {
            throw WorkspaceRuntimeError.io("\(error)")
        }
    }

    public func writeFile(path: String, data: Data, toolCallId: String) async throws {
        let url = try resolvePath(path)
        let decision = await requestPermission(
            access: .edit(url.path),
            toolName: "write",
            toolCallId: toolCallId
        )
        try ensureAllowed(decision)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            throw WorkspaceRuntimeError.io("\(error)")
        }
    }

    public func listDirectory(path: String, toolCallId: String) async throws -> [String] {
        let url = try resolvePath(path)
        let decision = await requestPermission(
            access: .read(url.path),
            toolName: "list_dir",
            toolCallId: toolCallId
        )
        try ensureAllowed(decision)
        do {
            return try FileManager.default.contentsOfDirectory(atPath: url.path)
        } catch {
            throw WorkspaceRuntimeError.io("\(error)")
        }
    }

    private func ensureAllowed(_ decision: PermissionDecision) throws {
        switch decision {
        case .allow:
            return
        case .policyDeny(let r), .reject(let r):
            throw WorkspaceRuntimeError.permissionDenied(r)
        case .cancelled:
            throw WorkspaceRuntimeError.cancelled
        case .ask:
            throw WorkspaceRuntimeError.permissionDenied("permission ask unresolved")
        case .followupMessage(let m):
            throw WorkspaceRuntimeError.permissionDenied(m)
        }
    }
}

// MARK: - Handle

/// Lightweight workspace handle used by higher layers.
public struct WorkspaceHandle: Sendable {
    public var config: WorkspaceConfig
    public var capability: CapabilityMode

    public init(config: WorkspaceConfig, capability: CapabilityMode = .full) {
        self.config = config
        self.capability = capability
    }

    public static func connectLocal(root: URL) -> WorkspaceHandle {
        WorkspaceHandle(config: WorkspaceConfig(root: root))
    }
}

/// Filesystem notifications must not be treated as authorship evidence.
public struct FsChangeNote: Sendable, Equatable {
    public var path: String
    public var kind: String
    /// Explicitly NOT authorship — attribution requires VCS/hunk tracker.
    public var isAuthorshipEvidence: Bool { false }

    public init(path: String, kind: String) {
        self.path = path
        self.kind = kind
    }
}
