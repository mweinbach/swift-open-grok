// OpenGrokSandbox.swift
//
// OS-level sandboxing for Open Grok (Swift port of `xai-grok-sandbox`).
//
// Applied once at process startup. Covers in-process filesystem access and
// child processes via platform backends:
//   * macOS Seatbelt (`sandbox_init` + SBPL)
//   * Linux bubblewrap capability probe + process-replacing re-exec
//   * Windows restricted-token / Job Object seams (typed unsupported)
//
// YOLO (`--dangerously-skip-permissions`) affects permission prompts only and
// NEVER disables the process-wide sandbox selected at startup.
//
// Unavailable guarantees produce explicit `SandboxError` / fail-closed results
// — never a silent weakening of a persisted sandbox mode.

import Foundation

// Module surface is composed of:
//   Types.swift, Paths.swift, Profiles.swift, NetworkPolicy.swift,
//   ChildNetworkRestriction.swift, Platform.swift, Manager.swift
//
// This file re-exports the primary entry points for discoverability.

/// Create and optionally apply a sandbox for `workspace` under `profileName`.
///
/// When `apply` is true and the profile is not `.off`, enforcement is
/// attempted and installed. Failures throw when `failClosed` is true.
public func bootstrapSandbox(
    profileName: ProfileName,
    workspace: URL,
    apply: Bool = true,
    failClosed: Bool = true
) throws -> SandboxManager {
    setConfiguredProfile(profileName.description)
    let manager = SandboxManager(
        profile: profileName,
        workspace: workspace,
        failClosed: failClosed
    )
    if apply {
        try manager.apply(workspace: workspace)
    }
    manager.install()
    return manager
}
