// EffectiveFeatures.swift
//
// Resolved feature snapshot combining env gates, local TOML config, and
// allowlisted remote settings with documented precedence.
//
// Precedence (highest wins, matching Rust `BoolFlag` in config.rs:2468+):
//   requirement > cli > env > config(TOML) > managed > remote > default
//
// This module implements only the features that have live Swift consumers.
// Fields without a consumer are not represented, and remote settings
// fields not on the `RemoteSettingsAllowlist` cannot contribute.
//
// The resolver is pure: all inputs are injected as values, so tests are
// deterministic without touching process state.

import Foundation
import OpenGrokConfigTypes

// MARK: - Feature inputs

/// Everything the feature resolver is allowed to read.
///
/// Passing layers as values keeps the resolver pure: a test can construct
/// any combination of tiers and assert the outcome without touching the
/// process environment or the filesystem.
public struct FeatureResolutionInputs: Sendable {
    /// The effective config root (merged TOML layers). The resolver reads
    /// `[features].<key>` from this tree.
    public var effectiveConfig: TOMLValue

    /// Requirements-pinned feature flags (from `requirements.toml`).
    /// Keys match the `[features]` namespace. A non-nil value outranks
    /// every other tier.
    public var requirements: [String: Bool]

    /// Allowlisted remote settings projection.
    public var remote: AllowlistedRemoteSettings

    /// Process environment (injectable for tests).
    public var environment: [String: String]

    public init(
        effectiveConfig: TOMLValue = .table(TOMLTable()),
        requirements: [String: Bool] = [:],
        remote: AllowlistedRemoteSettings = AllowlistedRemoteSettings(),
        environment: [String: String] = [:]
    ) {
        self.effectiveConfig = effectiveConfig
        self.requirements = requirements
        self.remote = remote
        self.environment = environment
    }
}

// MARK: - Resolved features

/// Resolved feature states for fields with live Swift consumers.
///
/// Each field carries the resolved value and the tier that decided it.
/// Fields that have no consumer in the Swift tree are not represented.
public struct EffectiveFeatures: Sendable, Equatable {

    // -- Telemetry --
    // Telemetry mode has its own dedicated resolver (`TelemetryModeResolver`)
    // because its precedence includes managed-settings pre-mutation and a
    // mode string (not just a bool). It is NOT duplicated here.

    // -- Feature gates --

    /// Session recap (`/recap` + auto return-from-away). Default ON.
    public var sessionRecap: Resolved<Bool>

    /// Web fetch tool. Default ON.
    public var webFetch: Resolved<Bool>

    /// Image generation tool. Default ON.
    public var imageGen: Resolved<Bool>

    /// Image edit tool. Default ON.
    public var imageEdit: Resolved<Bool>

    /// Feedback. Default ON.
    public var feedback: Resolved<Bool>

    /// Workspace command. Default OFF.
    public var workspaceCommand: Resolved<Bool>

    /// Folder trust. Default ON.
    public var folderTrust: Resolved<Bool>

    /// Workflows engine. Default OFF.
    public var workflows: Resolved<Bool>

    /// Sharing. Default OFF.
    public var sharing: Resolved<Bool>

    public init(
        sessionRecap: Resolved<Bool> = Resolved(value: true, source: .default),
        webFetch: Resolved<Bool> = Resolved(value: true, source: .default),
        imageGen: Resolved<Bool> = Resolved(value: true, source: .default),
        imageEdit: Resolved<Bool> = Resolved(value: true, source: .default),
        feedback: Resolved<Bool> = Resolved(value: true, source: .default),
        workspaceCommand: Resolved<Bool> = Resolved(value: false, source: .default),
        folderTrust: Resolved<Bool> = Resolved(value: true, source: .default),
        workflows: Resolved<Bool> = Resolved(value: false, source: .default),
        sharing: Resolved<Bool> = Resolved(value: false, source: .default)
    ) {
        self.sessionRecap = sessionRecap
        self.webFetch = webFetch
        self.imageGen = imageGen
        self.imageEdit = imageEdit
        self.feedback = feedback
        self.workspaceCommand = workspaceCommand
        self.folderTrust = folderTrust
        self.workflows = workflows
        self.sharing = sharing
    }
}

// MARK: - Resolver

extension EffectiveFeatures {
    /// Resolve all features from the supplied inputs.
    ///
    /// Precedence per field: requirement > env > config > remote > default.
    /// This matches the Rust `BoolFlag` pattern (config.rs:2468+), minus
    /// the `cli` and `managed` tiers which are not independently wired for
    /// these features in the Swift tree today.
    public static func resolve(_ inputs: FeatureResolutionInputs) -> EffectiveFeatures {
        EffectiveFeatures(
            sessionRecap: resolveFlag(
                key: "session_recap",
                envVar: "GROK_SESSION_RECAP",
                remoteValue: nil,
                defaultValue: true,
                inputs: inputs
            ),
            webFetch: resolveFlag(
                key: "web_fetch",
                envVar: "GROK_WEB_FETCH",
                remoteValue: nil,
                defaultValue: true,
                inputs: inputs
            ),
            imageGen: resolveFlag(
                key: "image_gen",
                envVar: "GROK_IMAGE_GEN",
                remoteValue: nil,
                defaultValue: true,
                inputs: inputs
            ),
            imageEdit: resolveFlag(
                key: "image_edit",
                envVar: "GROK_IMAGE_EDIT",
                remoteValue: nil,
                defaultValue: true,
                inputs: inputs
            ),
            feedback: resolveFlag(
                key: "feedback",
                envVar: "GROK_FEEDBACK_ENABLED",
                remoteValue: nil,
                defaultValue: true,
                inputs: inputs
            ),
            workspaceCommand: resolveFlag(
                key: "workspace_command",
                envVar: "GROK_WORKSPACE_COMMAND",
                remoteValue: inputs.remote.workspaceCommandEnabled,
                defaultValue: false,
                inputs: inputs
            ),
            folderTrust: resolveFlag(
                key: "folder_trust",
                envVar: "GROK_FOLDER_TRUST",
                remoteValue: nil,
                defaultValue: true,
                inputs: inputs
            ),
            workflows: resolveFlag(
                key: "workflows",
                envVar: "GROK_WORKFLOWS",
                remoteValue: nil,
                defaultValue: false,
                inputs: inputs
            ),
            sharing: resolveFlag(
                key: "sharing",
                envVar: "",
                remoteValue: inputs.remote.sharingEnabled,
                defaultValue: false,
                inputs: inputs
            )
        )
    }

    /// Single-field resolution matching the `BoolFlag` precedence chain.
    private static func resolveFlag(
        key: String,
        envVar: String,
        remoteValue: Bool?,
        defaultValue: Bool,
        inputs: FeatureResolutionInputs
    ) -> Resolved<Bool> {
        if let req = inputs.requirements[key] {
            return Resolved(value: req, source: .requirement)
        }
        if !envVar.isEmpty, let env = envBool(envVar, environment: inputs.environment) {
            return Resolved(value: env, source: .env)
        }
        if let toml = inputs.effectiveConfig[path: ["features", key]]?.boolValue {
            return Resolved(value: toml, source: .config)
        }
        if let remote = remoteValue {
            return Resolved(value: remote, source: .remote)
        }
        return Resolved(value: defaultValue, source: .default)
    }
}
