// OpenGrokSandbox.swift
//
// Sandbox policy and enforcement contract (W4-S1 bootstrap scaffold). macOS
// uses Seatbelt, Linux uses capability/Landlock/bubblewrap-style enforcement,
// Windows uses restricted-token/job/filesystem seams. Unavailable guarantees
// produce explicit `SandboxError.unsupported`/fail-closed results — never a
// silent weakening of a persisted sandbox mode.
//
// YOLO (`--dangerously-skip-permissions`) affects permission prompts only and
// NEVER disables the process-wide sandbox selected at startup.
//
// The owning slice (W4-S1) replaces `BootstrapSandboxEnforcer` with the real
// platform enforcer. Reference: xai-grok-sandbox.

import Foundation

/// Sandbox errors.
public enum SandboxError: Error, Equatable, Sendable {
    case profileInvalid(String)
    case enforcementFailed(String)
    case unsupported(String)
    case modePinningViolation(String)
}

/// The sandbox mode selected before agent work and persisted with the session.
public enum SandboxMode: Sendable, Equatable, Codable {
    case none
    case readOnly
    case restricted
}

/// A capability granted (or denied) by a sandbox profile.
public enum SandboxCapability: Sendable, Equatable, Codable {
    case networkAccess
    case processSpawn
    case fileSystemWrite
    case tempDirectoryAccess
    case openGrokHomeAccess
    case toolBundleAccess
}

/// A compiled sandbox profile: the set of allowed roots and capabilities.
public struct SandboxProfile: Sendable, Equatable {
    public var mode: SandboxMode
    public var allowedRoots: [URL]
    public var capabilities: Set<SandboxCapability>
    public init(mode: SandboxMode, allowedRoots: [URL], capabilities: Set<SandboxCapability>) {
        self.mode = mode
        self.allowedRoots = allowedRoots
        self.capabilities = capabilities
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
}

/// Bootstrap enforcer that reports `unsupported` for enforcement and conservatively
/// refuses to weaken modes. The owning slice (W4-S1) provides the real adapter.
public struct BootstrapSandboxEnforcer: SandboxEnforcer {
    public init() {}

    public func detectSupportedMode() -> SandboxMode {
        // Real detection probes Seatbelt/Landlock/restricted-token availability.
        return .none
    }

    public func compile(mode: SandboxMode, roots: [URL], capabilities: Set<SandboxCapability>) throws -> SandboxProfile {
        for root in roots {
            // Reject parent-directory components in the raw path to prevent
            // symlink/path-traversal escapes. (standardizedFileURL would
            // lexically resolve `..` away and hide the attack.)
            let components = root.path.split(separator: "/")
            if components.contains("..") {
                throw SandboxError.profileInvalid("Refusing profile with traversable root: \(root.path)")
            }
        }
        return SandboxProfile(mode: mode, allowedRoots: roots, capabilities: capabilities)
    }

    public func apply(_ profile: SandboxProfile) async throws {
        throw SandboxError.unsupported("BootstrapSandboxEnforcer does not enforce; W4-S1 provides the platform enforcer.")
    }

    public func canResume(persisted: SandboxMode, candidate: SandboxMode) -> Bool {
        // A mode may never weaken on resume. none < readOnly < restricted.
        func rank(_ m: SandboxMode) -> Int {
            switch m { case .none: return 0; case .readOnly: return 1; case .restricted: return 2 }
        }
        return rank(candidate) >= rank(persisted)
    }
}
