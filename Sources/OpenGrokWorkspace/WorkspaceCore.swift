// WorkspaceCore.swift
//
// Workspace configuration, handle, and operation boundary.
// Partial port of `xai-grok-workspace` focused on security-critical seams:
// permission pipeline, path boundary, path/resource locks, remote fail-closed.

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
    case processDenied(String)

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
        case .processDenied(let d): return "process denied: \(d)"
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

// MARK: - Process mediation request

public struct ProcessSpawnRequest: Sendable, Equatable {
    public var command: String
    public var arguments: [String]
    public var workingDirectory: String?
    public var toolCallId: String

    public init(
        command: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        toolCallId: String
    ) {
        self.command = command
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.toolCallId = toolCallId
    }

    public var bashForm: String {
        if arguments.isEmpty { return command }
        let args = arguments.map { arg -> String in
            if arg.contains(" ") || arg.contains("\"") {
                return "\"\(arg.replacingOccurrences(of: "\"", with: "\\\""))\""
            }
            return arg
        }
        return ([command] + args).joined(separator: " ")
    }
}

// MARK: - Workspace ops boundary

/// Local workspace operations with permission + path boundary + resource locks.
///
/// Every filesystem / process operation crosses the same permission pipeline
/// and path-boundary checks. Local fallback must never bypass a denied or
/// unavailable remote policy. YOLO never disables `requireSandbox`.
public actor LocalWorkspaceOps {
    public nonisolated let root: URL
    public nonisolated let boundary: PathBoundary
    public let permissions: PermissionHandle
    public nonisolated let pipeline: PermissionPipeline
    public let locks: PathResourceLockManager
    public let config: WorkspaceConfig
    /// When set, remote policy is authoritative; local fallback must not bypass.
    public private(set) var remotePolicyAvailable: Bool
    public private(set) var remotePolicyDenied: Bool
    public var folderTrust: FolderTrustStore
    public func currentPlanMode() async -> PlanModeTracker {
        await pipeline.planMode
    }

    public init(
        config: WorkspaceConfig,
        remotePolicyAvailable: Bool = false,
        hooks: any PreToolUseHookRunner = FailOpenPreToolUseHookRunner(),
        folderTrust: FolderTrustStore = FolderTrustStore()
    ) {
        self.config = config
        self.root = config.root
        self.boundary = PathBoundary(root: config.root)
        let perms = PermissionHandle(
            config: config.permissionConfig,
            yoloPinReason: config.yoloPinReason,
            shellCwd: config.root.path
        )
        self.permissions = perms
        self.pipeline = PermissionPipeline(
            permissions: perms,
            hooks: hooks,
            remotePolicyDenied: false,
            remotePolicyAvailable: remotePolicyAvailable,
            requireSandbox: config.requireSandbox,
            isolation: config.isolation,
            yoloPinReason: config.yoloPinReason
        )
        self.locks = PathResourceLockManager()
        self.remotePolicyAvailable = remotePolicyAvailable
        self.remotePolicyDenied = false
        self.folderTrust = folderTrust
    }

    public func setRemotePolicy(available: Bool, denied: Bool = false) async {
        remotePolicyAvailable = available
        remotePolicyDenied = denied
        await pipeline.setRemotePolicy(available: available, denied: denied)
    }

    public func setPlanMode(_ tracker: PlanModeTracker) async {
        await pipeline.setPlanMode(tracker)
    }

    public nonisolated func resolvePath(_ raw: String) throws -> URL {
        do {
            return try boundary.resolve(raw)
        } catch {
            throw WorkspaceRuntimeError.pathBoundary("\(error)")
        }
    }

    /// Full prepare path (plan gate → hooks → plan auto-approve → engine).
    public func prepareAccess(
        access: AccessKind,
        toolName: String,
        toolCallId: String,
        applyPatchLabel: Bool = false
    ) async -> PreparedToolAccess {
        await pipeline.prepare(
            PrepareToolAccessRequest(
                access: access,
                toolName: toolName,
                toolCallId: toolCallId,
                applyPatchLabel: applyPatchLabel
            )
        )
    }

    public func requestPermission(
        access: AccessKind,
        toolName: String,
        toolCallId: String
    ) async -> PermissionDecision {
        let prepared = await prepareAccess(
            access: access,
            toolName: toolName,
            toolCallId: toolCallId
        )
        return prepared.decision
    }

    public func readFile(path: String, toolCallId: String) async throws -> Data {
        let url = try resolvePath(path)
        let prepared = await prepareAccess(
            access: .read(url.path),
            toolName: "read_file",
            toolCallId: toolCallId
        )
        try ensureAllowed(prepared.decision)
        let token = await locks.acquirePath(url.path)
        do {
            let data = try Data(contentsOf: url)
            await token.release()
            return data
        } catch {
            await token.release()
            throw WorkspaceRuntimeError.io("\(error)")
        }
    }

    public func writeFile(path: String, data: Data, toolCallId: String) async throws {
        let url = try resolvePath(path)
        let prepared = await prepareAccess(
            access: .edit(url.path),
            toolName: "write",
            toolCallId: toolCallId
        )
        try ensureAllowed(prepared.decision)
        // Path lock for mutations (serialize concurrent edits on same path).
        let token = await locks.acquirePath(url.path)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            await token.release()
        } catch {
            await token.release()
            throw WorkspaceRuntimeError.io("\(error)")
        }
    }

    public func listDirectory(path: String, toolCallId: String) async throws -> [String] {
        let url = try resolvePath(path)
        let prepared = await prepareAccess(
            access: .read(url.path),
            toolName: "list_dir",
            toolCallId: toolCallId
        )
        try ensureAllowed(prepared.decision)
        let token = await locks.acquirePath(url.path)
        do {
            let entries = try FileManager.default.contentsOfDirectory(atPath: url.path)
            await token.release()
            return entries
        } catch {
            await token.release()
            throw WorkspaceRuntimeError.io("\(error)")
        }
    }

    /// Mediated process spawn: permission + resource lock; never local fallback
    /// when remote policy is denied or sandbox policy is unavailable.
    public func authorizeProcess(_ request: ProcessSpawnRequest) async throws {
        if remotePolicyDenied {
            throw WorkspaceRuntimeError.processDenied("remote policy denied this operation")
        }
        if config.requireSandbox && !remotePolicyAvailable && config.isolation == .sandbox {
            throw WorkspaceRuntimeError.sandboxRequired(
                "sandbox policy unavailable; refusing local process fallback"
            )
        }
        // YOLO pin never clears requireSandbox (checked above).
        let prepared = await prepareAccess(
            access: .bash(request.bashForm),
            toolName: "bash",
            toolCallId: request.toolCallId
        )
        try ensureAllowed(prepared.decision)
        // Hold process resource lock for the duration of authorization handoff.
        let token = await locks.acquireProcess(request.toolCallId)
        await token.release()
    }

    /// Whether project-scoped MCP/hooks are allowed for this workspace root.
    /// Folder trust does **not** inherit to child workspace roots.
    public func projectScopeAllowed() -> Bool {
        OpenGrokWorkspace.projectScopeAllowed(workspaceRoot: root, trustStore: folderTrust)
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
