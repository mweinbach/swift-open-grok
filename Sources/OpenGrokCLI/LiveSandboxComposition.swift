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
//   * The profile is applied at first tool-executor construction rather than at
//     process start. Seatbelt is irreversible and process-wide, so applying it
//     here still covers every child `run_terminal_cmd` spawns — but any file
//     access the CLI performed *before* the first executor is built is outside
//     the sandbox.
//   * Linux is not enforced: `PlatformEnforcer` requires a bubblewrap re-exec
//     that is not implemented, so a non-off profile on Linux throws
//     `SandboxError.enforcementFailed` rather than degrading.
//   * `auto_allow_bash` is resolved and reported but is not yet allowed to skip
//     bash permission prompts — the permission gate stays the boundary.

import Foundation
import OpenGrokConfig
import OpenGrokSandbox

/// The sandbox decision for one session.
public struct LiveSandboxDecision: Sendable, Equatable {
    /// Profile name to persist with the session (`sandbox_profile`).
    public var profileName: String
    /// Coarse mode used for the resume pin ladder.
    public var mode: SandboxMode
    /// True when enforcement was actually installed in this process.
    public var enforced: Bool
    /// Set when the profile was requested but could not be enforced.
    public var unsupported: String?

    public init(
        profileName: String,
        mode: SandboxMode,
        enforced: Bool,
        unsupported: String? = nil
    ) {
        self.profileName = profileName
        self.mode = mode
        self.enforced = enforced
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
    /// config `[sandbox] profile` > `"off"`.
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
        return "off"
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
    /// Mirrors `resolve_startup_sandbox` (cli.rs:1004) and the `rank` ladder in
    /// `SandboxMode`: a session created under `strict` may not come back under
    /// `off`. Aliases (`readonly`/`read-only`, `none`/`off`) compare equal
    /// because both sides are parsed into `ProfileName` first.
    public static func validateResume(
        requested: String,
        persisted: String?
    ) throws {
        guard let persisted, !persisted.isEmpty else { return }
        let persistedMode = SandboxMode.from(profile: ProfileName(parsing: persisted))
        let requestedMode = SandboxMode.from(profile: ProfileName(parsing: requested))
        if requestedMode.rank < persistedMode.rank {
            throw SandboxError.modePinningViolation(
                "cannot resume this session under sandbox profile '\(requested)' — "
                    + "it was created with '\(persisted)'"
            )
        }
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
        let name = resolveProfileName(
            document: document,
            requirements: requirements,
            cliProfile: cliProfile,
            environment: environment
        )
        try validateResume(requested: name, persisted: persistedProfile)

        let profile = ProfileName(parsing: name)
        let mode = SandboxMode.from(profile: profile)

        if profile == .off {
            return LiveSandboxDecision(profileName: name, mode: mode, enforced: false)
        }
        if isSandboxActive() {
            return LiveSandboxDecision(
                profileName: activeProfileName() ?? name,
                mode: mode,
                enforced: true
            )
        }

        do {
            _ = try bootstrapSandbox(
                profileName: profile,
                workspace: workspaceRoot,
                apply: true,
                failClosed: true
            )
            return LiveSandboxDecision(profileName: name, mode: mode, enforced: true)
        } catch let error as SandboxError {
            // Surface the typed error. Never downgrade to "ran without a
            // sandbox" — the user asked for one.
            throw error
        }
    }
}
