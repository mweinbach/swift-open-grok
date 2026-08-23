// LiveLeaderSandboxPolicy.swift
//
// A leader executes tools in a separate shared process. A sandbox installed in
// this client therefore cannot prove that those tools remain confined. Rust
// resolves that incompatibility before connecting to the leader
// (`xai-grok-pager/src/app/mod.rs:426-484`, reference 538a16dfb).

import Foundation
import OpenGrokSandbox

enum LiveLeaderSandboxPolicy {
    /// Refuse leader mode whenever the effective sandbox profile is confined.
    ///
    /// This intentionally resolves security without honoring `--trust`: a
    /// request that will be refused must not persist folder trust as a side
    /// effect. The ordinary launch path performs the real trust decision only
    /// after this policy admits an explicitly unconfined leader launch.
    static func enforce(
        options: CLIExecutionOptions,
        workingDirectory: URL,
        environment: [String: String]
    ) throws {
        guard options.common.leader else { return }

        var securityOptions = options
        securityOptions.common.permissions.trustFolder = false
        let security = LiveSecurityContext.resolve(
            workspaceRoot: workingDirectory,
            environment: environment,
            isInteractive: securityOptions.mode == .interactive,
            cli: securityOptions.common.permissions
        )
        let profile = ProfileName(parsing: LiveSandboxComposition.resolveProfileName(
            document: security.document,
            requirements: security.requirements,
            cliProfile: securityOptions.common.permissions.sandboxProfile,
            environment: environment
        ))
        guard profile.description == ProfileName.off.description else {
            throw CLIApplicationError.failed(refusalMessage(profile: profile.description))
        }
    }

    static func refusalMessage(profile: String) -> String {
        "leader mode is unavailable under sandbox profile '\(profile)': the leader is a "
            + "separate, shared process this client cannot prove is confined by that "
            + "profile, so tools are not guaranteed to stay inside it. Disable the "
            + "profile at the source that selected it (CLI, env, config, or a managed "
            + "requirement)"
    }
}
