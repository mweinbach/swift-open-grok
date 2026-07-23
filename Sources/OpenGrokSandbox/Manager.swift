// Manager.swift
//
// Process-wide sandbox manager. Apply once at startup, then install for
// session-lifetime violation logging. Ported from `xai-grok-sandbox/src/lib.rs`
// with R15 fail-closed semantics for non-off profiles.

import Foundation

// MARK: - Global state

private final class GlobalSandboxState: @unchecked Sendable {
    let profile: String
    let logger: SandboxLogger
    let applied: Bool
    let restrictNetworkAtKnownLinuxLaunches: Bool

    init(
        profile: String,
        logger: SandboxLogger,
        applied: Bool,
        restrictNetworkAtKnownLinuxLaunches: Bool
    ) {
        self.profile = profile
        self.logger = logger
        self.applied = applied
        self.restrictNetworkAtKnownLinuxLaunches = restrictNetworkAtKnownLinuxLaunches
    }
}

private let globalLock = NSLock()
private var globalSandbox: GlobalSandboxState?
private var configuredProfileName: String?
private var autoAllowBash: Bool = false

/// Whether known Linux child launch paths should install a network filter.
public func shouldRestrictChildNetwork() -> Bool {
    globalLock.lock()
    defer { globalLock.unlock() }
    return globalSandbox?.restrictNetworkAtKnownLinuxLaunches ?? false
}

/// Whether bash commands should be auto-approved when the sandbox is active.
public func shouldAutoAllowBash() -> Bool {
    globalLock.lock()
    defer { globalLock.unlock() }
    return autoAllowBash && (globalSandbox?.applied ?? false)
}

public func setAutoAllowBash(_ enabled: Bool) {
    globalLock.lock()
    defer { globalLock.unlock() }
    autoAllowBash = enabled
}

/// Record the resolved sandbox profile at process startup (including `"off"`).
public func setConfiguredProfile(_ name: String) {
    globalLock.lock()
    defer { globalLock.unlock() }
    if configuredProfileName == nil {
        configuredProfileName = name
    }
}

public func configuredProfile() -> String? {
    globalLock.lock()
    defer { globalLock.unlock() }
    return configuredProfileName
}

/// Whether the sandbox was successfully applied to this process.
public func isSandboxActive() -> Bool {
    globalLock.lock()
    defer { globalLock.unlock() }
    return globalSandbox?.applied ?? false
}

/// The active sandbox profile name, or `nil` if not applied.
public func activeProfileName() -> String? {
    globalLock.lock()
    defer { globalLock.unlock() }
    guard let state = globalSandbox, state.applied else { return nil }
    return state.profile
}

/// Log a sandbox violation. No-op if sandbox is not active.
public func logSandboxViolation(target: String, operation: String) {
    globalLock.lock()
    let state = globalSandbox
    globalLock.unlock()
    guard let state else { return }
    state.logger.log(.fsViolation(profile: state.profile, target: target, operation: operation))
    try? state.logger.flushToDisk()
}

public func flushSandboxEvents() {
    globalLock.lock()
    let state = globalSandbox
    globalLock.unlock()
    try? state?.logger.flushToDisk()
}

public func sandboxMetrics() -> SandboxMetrics? {
    globalLock.lock()
    defer { globalLock.unlock() }
    return globalSandbox?.logger.metrics
}

func restrictNetworkAtKnownLinuxLaunches(applied: Bool, configured: Bool) -> Bool {
    #if os(Linux)
    return applied && configured
    #else
    return false
    #endif
}

// MARK: - Manager

/// Manages the OS-level sandbox. Call `apply` then `install`.
public final class SandboxManager: @unchecked Sendable {
    public private(set) var profile: ProfileName
    public let logger: SandboxLogger
    private var netRestricted: Bool
    public private(set) var applied: Bool = false
    /// When true, non-off apply failures throw instead of degrading.
    public var failClosed: Bool

    public init(
        profile: ProfileName,
        workspace: URL,
        logger: SandboxLogger = SandboxLogger(),
        failClosed: Bool = true
    ) {
        self.profile = profile
        self.logger = logger
        self.netRestricted = profile.restrictsNetwork
        self.failClosed = failClosed
        _ = workspace
    }

    public var restrictChildNetwork: Bool {
        restrictNetworkAtKnownLinuxLaunches(applied: applied, configured: netRestricted)
    }

    /// Apply the sandbox to the current process. Prefer fail-closed for
    /// non-off profiles per R15 acceptance.
    public func apply(workspace: URL) throws {
        if profile == .off {
            applied = false
            return
        }

        let config = loadSandboxConfig(workspace: workspace)
        let resolved = try profile.resolve(workspace: workspace, config: config)
        netRestricted = resolved.restrictNetwork

        let support = PlatformSandboxSupport.supportInfo()
        if !support.isSupported {
            logger.log(.applyFailed(
                profile: profile.description,
                workspace: workspace,
                error: support.details
            ))
            if failClosed || requiresReadDeny(profile: profile, workspace: workspace, config: config) {
                throw SandboxError.unsupported(support.details)
            }
            applied = false
            return
        }

        do {
            try PlatformEnforcer.apply(resolved: resolved, workspace: workspace, profile: profile)
            applied = true
            logger.log(.profileApplied(
                profile: profile.description,
                workspace: workspace,
                resolved: resolved
            ))
        } catch {
            logger.log(.applyFailed(
                profile: profile.description,
                workspace: workspace,
                error: "\(error)"
            ))
            if failClosed || requiresReadDeny(profile: profile, workspace: workspace, config: config) {
                throw error
            }
            applied = false
        }
    }

    /// Store globally for session-lifetime violation logging.
    public func install() {
        try? logger.flushToDisk()
        let state = GlobalSandboxState(
            profile: profile.description,
            logger: logger,
            applied: applied,
            restrictNetworkAtKnownLinuxLaunches: restrictNetworkAtKnownLinuxLaunches(
                applied: applied,
                configured: netRestricted
            )
        )
        globalLock.lock()
        if globalSandbox == nil {
            globalSandbox = state
        }
        globalLock.unlock()
    }
}

/// Execute a child process pre-exec action, installing the Linux seccomp network filter if child network restriction is enabled.
public func applyChildNetworkRestrictionToLaunch(preExec: (() throws -> Void)? = nil) throws {
    if shouldRestrictChildNetwork() {
        try installChildNetworkFilter()
    }
    try preExec?()
}

// MARK: - Platform enforcer dispatch

enum PlatformEnforcer {
    static func apply(resolved: ResolvedSandboxProfile, workspace: URL, profile: ProfileName) throws {
        #if os(macOS)
        let sbpl = buildSeatbeltProfile(resolved, workspace: workspace)
        try applySeatbeltProfile(sbpl)
        #elseif os(Linux)
        if isInsideBwrap() {
            return
        }
        let plan = bwrapDenyPlan(profile: profile, workspace: workspace)
        let planDetails = plan != nil ? "deny_write=\(plan!.denyWrite) deny_read=\(plan!.denyRead.count) has_globs=\(plan!.hasGlobs) restrict_network=\(plan!.restrictNetwork)" : "none"
        throw SandboxError.enforcementFailed(
            "Linux sandbox requires bubblewrap re-exec before apply; cannot enforce in-process without bwrap (\(planDetails))"
        )
        #elseif os(Windows)
        try createRestrictedTokenSandbox(profile: resolved)
        #else
        throw SandboxError.unsupported("no sandbox backend")
        #endif
    }
}


// MARK: - SandboxEnforcer protocol (session pin surface)

/// A compiled sandbox profile for the coarser session-mode ladder.
public struct SandboxProfile: Sendable, Equatable {
    public var mode: SandboxMode
    public var allowedRoots: [URL]
    public var capabilities: Set<SandboxCapability>
    public var profileName: ProfileName
    public var resolved: ResolvedSandboxProfile?

    public init(
        mode: SandboxMode,
        allowedRoots: [URL],
        capabilities: Set<SandboxCapability>,
        profileName: ProfileName = .workspace,
        resolved: ResolvedSandboxProfile? = nil
    ) {
        self.mode = mode
        self.allowedRoots = allowedRoots
        self.capabilities = capabilities
        self.profileName = profileName
        self.resolved = resolved
    }
}

/// Sandbox enforcement. Mode is selected before agent work, persisted with the
/// session, and cannot silently weaken on resume.
public protocol SandboxEnforcer: Sendable {
    /// Detect the strongest sandbox mode the current platform supports.
    func detectSupportedMode() -> SandboxMode
    /// Compile a profile, rejecting path traversal / symlink escapes.
    func compile(mode: SandboxMode, roots: [URL], capabilities: Set<SandboxCapability>) throws -> SandboxProfile
    /// Apply `profile` to the process; fail closed if enforcement is unavailable.
    func apply(_ profile: SandboxProfile) async throws
    /// Returns `true` if `mode` cannot weaken on resume given `persisted`.
    func canResume(persisted: SandboxMode, candidate: SandboxMode) -> Bool
    /// Validate resume capability, throwing `SandboxError.modePinningViolation` on downgrade.
    func validateResume(persisted: SandboxMode, candidate: SandboxMode) throws
}

public extension SandboxEnforcer {
    func validateResume(persisted: SandboxMode, candidate: SandboxMode) throws {
        guard canResume(persisted: persisted, candidate: candidate) else {
            throw SandboxError.modePinningViolation(
                "resumed sandbox mode '\(candidate)' weakens persisted mode '\(persisted)'"
            )
        }
    }
}

/// Real platform enforcer replacing the bootstrap scaffold.
public struct PlatformSandboxEnforcer: SandboxEnforcer {
    public var failClosed: Bool

    public init(failClosed: Bool = true) {
        self.failClosed = failClosed
    }

    public func detectSupportedMode() -> SandboxMode {
        let info = PlatformSandboxSupport.supportInfo()
        if !info.isSupported { return .none }
        #if os(macOS)
        return .restricted
        #elseif os(Linux)
        return info.backend == .linuxLandlock || info.backend == .linuxBubblewrap
            ? .restricted
            : .none
        #else
        return .none
        #endif
    }

    public func compile(
        mode: SandboxMode,
        roots: [URL],
        capabilities: Set<SandboxCapability>
    ) throws -> SandboxProfile {
        for root in roots {
            try rejectTraversableRoot(root)
        }
        let profileName: ProfileName
        switch mode {
        case .none: profileName = .off
        case .readOnly: profileName = .readOnly
        case .restricted: profileName = .workspace
        }
        var resolved: ResolvedSandboxProfile?
        if mode != .none, let workspace = roots.first {
            let config = loadSandboxConfig(workspace: workspace)
            resolved = try? profileName.resolve(workspace: workspace, config: config)
        }
        return SandboxProfile(
            mode: mode,
            allowedRoots: roots,
            capabilities: capabilities,
            profileName: profileName,
            resolved: resolved
        )
    }

    public func apply(_ profile: SandboxProfile) async throws {
        if profile.mode == .none { return }
        guard let workspace = profile.allowedRoots.first else {
            throw SandboxError.profileInvalid("no workspace root provided")
        }
        let manager = SandboxManager(
            profile: profile.profileName,
            workspace: workspace,
            failClosed: failClosed
        )
        try manager.apply(workspace: workspace)
        manager.install()
        setConfiguredProfile(profile.profileName.description)
        if !manager.applied && failClosed {
            throw SandboxError.enforcementFailed(
                "sandbox apply did not take effect for profile \(profile.profileName)"
            )
        }
    }

    public func canResume(persisted: SandboxMode, candidate: SandboxMode) -> Bool {
        candidate.rank >= persisted.rank
    }
}

/// Compatibility enforcer that refuses `apply` for non-off modes.
/// Prefer `PlatformSandboxEnforcer` for real kernel enforcement.
public struct BootstrapSandboxEnforcer: SandboxEnforcer {
    public init() {}

    public func detectSupportedMode() -> SandboxMode {
        PlatformSandboxEnforcer().detectSupportedMode()
    }

    public func compile(
        mode: SandboxMode,
        roots: [URL],
        capabilities: Set<SandboxCapability>
    ) throws -> SandboxProfile {
        try PlatformSandboxEnforcer().compile(mode: mode, roots: roots, capabilities: capabilities)
    }

    public func apply(_ profile: SandboxProfile) async throws {
        // Historical bootstrap behavior: report unsupported so callers do not
        // assume enforcement. Prefer PlatformSandboxEnforcer for real apply.
        if profile.mode == .none { return }
        throw SandboxError.unsupported(
            "BootstrapSandboxEnforcer does not enforce; use PlatformSandboxEnforcer"
        )
    }

    public func canResume(persisted: SandboxMode, candidate: SandboxMode) -> Bool {
        candidate.rank >= persisted.rank
    }
}

