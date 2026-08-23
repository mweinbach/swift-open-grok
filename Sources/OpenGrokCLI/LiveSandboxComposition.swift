// LiveSandboxComposition.swift
//
// Wires `OpenGrokSandbox` into the live session. The module is a real port —
// `sandbox_init` + SBPL on macOS, seccomp network filtering on Linux, mode-pin
// validation on resume — but until this file existed it had zero importers
// outside its own tests, so no sandbox was ever enforced.
//
// Rust applies the sandbox once at pager startup
// (`xai-grok-pager-bin/src/main.rs:1787` → `xai_grok_shell::config::apply_sandbox`)
// and persists the profile with the session
// (`session/persistence.rs:979` `sandbox_profile`) so a resumed session cannot
// silently come back weaker.
//
// KNOWN DIVERGENCES from Rust, deliberate and bounded:
//   * The process-wide sandbox manager is wrapped by a CLI-owned runtime seam so
//     lifecycle tests can model activation without installing Seatbelt/bwrap.

import Foundation
import OpenGrokConfig
import OpenGrokSandbox

public protocol LiveSandboxRuntime: Sendable {
    func apply(profileName: ProfileName, workspaceRoot: URL) throws
    func isSandboxActive() -> Bool
    func activeProfileName() -> String?
    func setAutoAllowBash(_ enabled: Bool)
    func shouldAutoAllowBash() -> Bool
}

public struct LiveSandboxRuntimeAdapter: LiveSandboxRuntime {
    public init() {}

    public func apply(profileName: ProfileName, workspaceRoot: URL) throws {
        _ = try bootstrapSandbox(
            profileName: profileName,
            workspace: workspaceRoot,
            apply: true,
            failClosed: true
        )
    }

    public func isSandboxActive() -> Bool { OpenGrokSandbox.isSandboxActive() }
    public func activeProfileName() -> String? { OpenGrokSandbox.activeProfileName() }
    public func setAutoAllowBash(_ enabled: Bool) { OpenGrokSandbox.setAutoAllowBash(enabled) }
    public func shouldAutoAllowBash() -> Bool { OpenGrokSandbox.shouldAutoAllowBash() }
}

/// The sandbox decision for one session.
public struct LiveSandboxDecision: Sendable, Equatable {
    /// Profile name to persist with the session (`sandbox_profile`).
    public var profileName: String
    /// Coarse mode used for the resume pin ladder.
    public var mode: SandboxMode
    /// True when enforcement was actually installed in this process.
    public var enforced: Bool
    /// True only when the resolved setting was activated after enforcement.
    public var autoAllowBash: Bool
    /// Set when the profile was requested but could not be enforced.
    public var unsupported: String?

    public init(
        profileName: String,
        mode: SandboxMode,
        enforced: Bool,
        autoAllowBash: Bool = false,
        unsupported: String? = nil
    ) {
        self.profileName = profileName
        self.mode = mode
        self.enforced = enforced
        self.autoAllowBash = autoAllowBash
        self.unsupported = unsupported
    }
}

public enum LiveSandboxComposition {
    /// Env var Rust binds to `--sandbox` (`xai-grok-pager/src/app/cli.rs:700`).
    static let profileEnvVar = "GROK_SANDBOX"
    static let autoAllowBashEnvVar = "GROK_SANDBOX_AUTO_ALLOW_BASH"

    /// Resolve the profile name.
    ///
    /// Precedence, highest first (`agent/config.rs:1267-1285`):
    /// requirements `[sandbox] profile` > CLI `--sandbox` > env `GROK_SANDBOX` >
    /// config `[sandbox] profile` > `"workspace"`.
    public static func resolveProfileName(
        document: TOMLValue?,
        requirements: [TOMLValue] = [],
        cliProfile: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        for layer in requirements {
            if case .string(let name)? = layer[path: ["sandbox", "profile"]], !name.isEmpty {
                return name
            }
        }
        if let cliProfile, !cliProfile.isEmpty { return cliProfile }
        if let fromEnv = environment[profileEnvVar]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !fromEnv.isEmpty {
            return fromEnv
        }
        if case .string(let name)? = document?[path: ["sandbox", "profile"]], !name.isEmpty {
            return name
        }
        return "workspace"
    }

    /// `[sandbox] auto_allow_bash`, same precedence shape.
    public static func resolveAutoAllowBash(
        document: TOMLValue?,
        requirements: [TOMLValue] = [],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        for layer in requirements {
            if case .boolean(let value)? = layer[path: ["sandbox", "auto_allow_bash"]] {
                return value
            }
        }
        if let fromEnv = envBool(autoAllowBashEnvVar, environment: environment) {
            return fromEnv
        }
        if case .boolean(let value)? = document?[path: ["sandbox", "auto_allow_bash"]] {
            return value
        }
        return false
    }

    /// Refuse a resume that would weaken the sandbox.
    ///
    /// Mirrors `resolve_startup_sandbox` (cli.rs:1004): a persisted profile is
    /// pinned exactly, while aliases (`readonly`/`read-only`, `none`/`off`)
    /// compare equal because both sides are parsed into `ProfileName` first.
    public static func validateResume(
        requested: String,
        persisted: String?
    ) throws {
        guard let persisted, !persisted.isEmpty else { return }
        let persistedProfile = ProfileName(parsing: persisted)
        let requestedProfile = ProfileName(parsing: requested)
        let persistedName = persistedProfile.description
        let requestedName = requestedProfile.description
        guard requestedName != persistedName else { return }

        let persistedMode = SandboxMode.from(profile: persistedProfile)
        let requestedMode = SandboxMode.from(profile: requestedProfile)
        if requestedMode.rank < persistedMode.rank {
            throw SandboxError.modePinningViolation(
                "cannot resume this session under sandbox profile '\(requested)' — "
                    + "it was created with '\(persisted)'"
            )
        }
        throw SandboxError.configConflict(
            "cannot resume this session with sandbox profile '\(requested)' — "
                + "it was created with '\(persisted)'"
        )
    }

    /// Resolve and, when the profile is not `off`, apply the sandbox.
    ///
    /// Fail-closed by contract: a requested profile that cannot be enforced on
    /// this platform throws the typed `SandboxError.unsupported` rather than
    /// running unsandboxed. `off` never throws.
    ///
    /// Idempotent — a second call (a subagent building its own executor) sees
    /// the process sandbox already active and reports the installed profile
    /// instead of calling `sandbox_init` twice.
    @discardableResult
    public static func bootstrap(
        workspaceRoot: URL,
        document: TOMLValue?,
        requirements: [TOMLValue] = [],
        cliProfile: String? = nil,
        persistedProfile: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> LiveSandboxDecision {
        try bootstrap(
            workspaceRoot: workspaceRoot,
            document: document,
            requirements: requirements,
            cliProfile: cliProfile,
            persistedProfile: persistedProfile,
            environment: environment,
            runtime: LiveSandboxRuntimeAdapter()
        )
    }

    static func bootstrap(
        workspaceRoot: URL,
        document: TOMLValue?,
        requirements: [TOMLValue] = [],
        cliProfile: String? = nil,
        persistedProfile: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        runtime: any LiveSandboxRuntime
    ) throws -> LiveSandboxDecision {
        let resolvedAutoAllowBash = resolveAutoAllowBash(
            document: document,
            requirements: requirements,
            environment: environment
        )
        runtime.setAutoAllowBash(false)

        let persistedName = persistedProfile.map { ProfileName(parsing: $0).description }
        let requiredName = requirements.compactMap { layer -> String? in
            guard case .string(let value)? = layer[path: ["sandbox", "profile"]],
                  !value.isEmpty else { return nil }
            return ProfileName(parsing: value).description
        }.first
        let requestedName: String
        if let persistedName {
            if let cliProfile, !cliProfile.isEmpty,
               ProfileName(parsing: cliProfile).description != persistedName {
                throw SandboxError.configConflict(
                    "cannot resume this session with sandbox profile '\(cliProfile)' — "
                        + "it was created with '\(persistedName)'"
                )
            }
            if let requiredName, requiredName != persistedName {
                throw SandboxError.configConflict(
                    "cannot resume this session under required sandbox profile '\(requiredName)' — "
                        + "it was created with '\(persistedName)'"
                )
            }
            requestedName = persistedName
        } else {
            requestedName = ProfileName(parsing: resolveProfileName(
                document: document,
                requirements: requirements,
                cliProfile: cliProfile,
                environment: environment
            )).description
        }
        try validateResume(requested: requestedName, persisted: persistedName)

        let profile = ProfileName(parsing: requestedName)
        let mode = SandboxMode.from(profile: profile)

        if profile == .off {
            guard !runtime.isSandboxActive() else {
                throw SandboxError.configConflict(
                    "an active process sandbox cannot be disabled for another session"
                )
            }
            return LiveSandboxDecision(
                profileName: profile.description,
                mode: mode,
                enforced: false,
                autoAllowBash: false
            )
        }
        if runtime.isSandboxActive() {
            guard let activeName = runtime.activeProfileName(),
                  ProfileName(parsing: activeName).description == profile.description else {
                throw SandboxError.configConflict(
                    "the active process sandbox does not match requested profile '\(profile.description)'"
                )
            }
            runtime.setAutoAllowBash(resolvedAutoAllowBash)
            return LiveSandboxDecision(
                profileName: activeName,
                mode: mode,
                enforced: true,
                autoAllowBash: runtime.shouldAutoAllowBash()
            )
        }

        do {
            let canonicalWorkspaceRoot = workspaceRoot.standardizedFileURL
                .resolvingSymlinksInPath()
                .standardizedFileURL
            try runtime.apply(profileName: profile, workspaceRoot: canonicalWorkspaceRoot)
            guard runtime.isSandboxActive() else {
                runtime.setAutoAllowBash(false)
                throw SandboxError.enforcementFailed(
                    "sandbox bootstrap returned without active enforcement"
                )
            }
            guard let activeName = runtime.activeProfileName(),
                  ProfileName(parsing: activeName).description == profile.description else {
                runtime.setAutoAllowBash(false)
                throw SandboxError.enforcementFailed(
                    "sandbox bootstrap activated a different profile than required '\(profile.description)'"
                )
            }
            runtime.setAutoAllowBash(resolvedAutoAllowBash)
            return LiveSandboxDecision(
                profileName: profile.description,
                mode: mode,
                enforced: true,
                autoAllowBash: runtime.shouldAutoAllowBash()
            )
        } catch let error as SandboxError {
            runtime.setAutoAllowBash(false)
            // Surface the typed error. Never downgrade to "ran without a
            // sandbox" — the user asked for one.
            throw error
        } catch {
            runtime.setAutoAllowBash(false)
            throw error
        }
    }
}
