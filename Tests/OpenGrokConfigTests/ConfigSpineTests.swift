// ConfigSpineTests.swift
//
// Tests for the config authority spine: RemoteSettingsAllowlist,
// GrokEnvGates, and EffectiveFeatures.
//
// Three categories:
//   1. Precedence: requirement > env > config > remote > default
//   2. Negative/inert: non-allowlisted remote fields cannot override
//   3. Live-seam proofs: at least announcements, telemetry mode, and
//      one other consumer

import Foundation
import Testing
@testable import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokShared

// MARK: - RemoteSettingsAllowlist

@Suite("RemoteSettingsAllowlist")
struct RemoteSettingsAllowlistTests {

    @Test("projection carries allowlisted fields")
    func projectionCarriesAllowlisted() {
        var rs = RemoteSettings()
        rs.telemetryMode = "enabled"
        rs.telemetryEnabled = true
        rs.externalOtelDisabled = true
        rs.externalOtelContentGatesLocked = true
        rs.privacyNoticeRollout = true
        rs.privacyBannerReshowDays = 30
        rs.sharingEnabled = true
        rs.workspaceCommandEnabled = true
        rs.zdrAccessEnabled = true
        rs.gateMessage = "upgrade required"
        let ann = RemoteAnnouncement(
            id: "a1", message: "hello", severity: "info", title: "Hi",
            cta: nil, updatedAt: nil, expiresAt: nil, dismissible: true,
            persistent: false
        )
        rs.announcements = [ann]

        let projected = AllowlistedRemoteSettings(projecting: rs)

        #expect(projected.telemetryMode == "enabled")
        #expect(projected.telemetryEnabled == true)
        #expect(projected.externalOtelDisabled == true)
        #expect(projected.externalOtelContentGatesLocked == true)
        #expect(projected.privacyNoticeRollout == true)
        #expect(projected.privacyBannerReshowDays == 30)
        #expect(projected.sharingEnabled == true)
        #expect(projected.workspaceCommandEnabled == true)
        #expect(projected.zdrAccessEnabled == true)
        #expect(projected.gateMessage == "upgrade required")
        #expect(projected.announcements?.count == 1)
        #expect(projected.announcements?.first?.id == "a1")
    }

    @Test("projection from empty RemoteSettings yields all nil")
    func projectionFromEmptyIsAllNil() {
        let rs = RemoteSettings()
        let projected = AllowlistedRemoteSettings(projecting: rs)

        #expect(projected.telemetryMode == nil)
        #expect(projected.telemetryEnabled == nil)
        #expect(projected.externalOtelDisabled == nil)
        #expect(projected.externalOtelContentGatesLocked == nil)
        #expect(projected.privacyNoticeRollout == nil)
        #expect(projected.privacyBannerReshowDays == nil)
        #expect(projected.announcements == nil)
        #expect(projected.sharingEnabled == nil)
        #expect(projected.workspaceCommandEnabled == nil)
        #expect(projected.zdrAccessEnabled == nil)
        #expect(projected.gateMessage == nil)
    }

    @Test("non-allowlisted fields cannot reach AllowlistedRemoteSettings")
    func nonAllowlistedFieldsInert() {
        var rs = RemoteSettings()

        rs.leaderMode = true
        rs.maxUploadFileBytes = 999
        rs.memoryEnabled = true
        rs.lspToolsEnabled = true
        rs.folderTrustEnabled = false
        rs.writeFileEnabled = false
        rs.fileToolset = "restricted"
        rs.sessionRecap = false
        rs.webFetchEnabled = false
        rs.imageGenEnabled = false
        rs.videoGenEnabled = false
        rs.feedbackEnabled = false
        rs.compactionMode = "aggressive"
        rs.twoPassCompactionEnabled = true
        rs.defaultModel = "grok-5"
        rs.subscriptionTier = "premium"
        rs.permissionMode = "auto"
        rs.autoMode = .bool(true)
        rs.suggestionsEnabled = true

        let projected = AllowlistedRemoteSettings(projecting: rs)

        #expect(projected.telemetryMode == nil)
        #expect(projected.telemetryEnabled == nil)
        #expect(projected.externalOtelDisabled == nil)
        #expect(projected.externalOtelContentGatesLocked == nil)
        #expect(projected.privacyNoticeRollout == nil)
        #expect(projected.privacyBannerReshowDays == nil)
        #expect(projected.announcements == nil)
        #expect(projected.sharingEnabled == nil)
        #expect(projected.workspaceCommandEnabled == nil)
        #expect(projected.zdrAccessEnabled == nil)
        #expect(projected.gateMessage == nil)
    }

    @Test("allowlisted wire name set is complete")
    func wireNameSetComplete() {
        #expect(remoteSettingsAllowlistedWireNames.count == 11)
        #expect(remoteSettingsAllowlistedWireNames.contains("telemetry_mode"))
        #expect(remoteSettingsAllowlistedWireNames.contains("telemetry_enabled"))
        #expect(remoteSettingsAllowlistedWireNames.contains("external_otel_disabled"))
        #expect(remoteSettingsAllowlistedWireNames.contains("external_otel_content_gates_locked"))
        #expect(remoteSettingsAllowlistedWireNames.contains("privacy_notice_rollout"))
        #expect(remoteSettingsAllowlistedWireNames.contains("privacy_banner_reshow_days"))
        #expect(remoteSettingsAllowlistedWireNames.contains("announcements"))
        #expect(remoteSettingsAllowlistedWireNames.contains("sharing_enabled"))
        #expect(remoteSettingsAllowlistedWireNames.contains("workspace_command_enabled"))
        #expect(remoteSettingsAllowlistedWireNames.contains("zdr_access_enabled"))
        #expect(remoteSettingsAllowlistedWireNames.contains("gate_message"))
    }

    @Test("non-allowlisted wire names are not in the set")
    func nonAllowlistedWireNamesAbsent() {
        let shouldNotBeAllowlisted: [String] = [
            "leader_mode", "max_upload_file_bytes",
            "memory_enabled", "lsp_tools_enabled", "folder_trust_enabled",
            "write_file_enabled", "file_toolset", "session_recap",
            "web_fetch_enabled", "image_gen_enabled", "video_gen_enabled",
            "feedback_enabled", "compaction_mode", "two_pass_compaction_enabled",
            "default_model", "subscription_tier", "permission_mode",
            "auto_mode", "suggestions_enabled", "auto_compact_threshold_percent",
            "compaction_wall_clock_budget_secs", "subagents_max_depth",
        ]
        for name in shouldNotBeAllowlisted {
            #expect(
                !remoteSettingsAllowlistedWireNames.contains(name),
                "\(name) should not be on the allowlist"
            )
        }
    }
}

// MARK: - GrokEnvGates

@Suite("GrokEnvGates")
struct GrokEnvGatesTests {

    @Test("telemetryEnabled parses OPENGROK spelling first")
    func telemetryOpengrokSpelling() {
        let env = [
            "OPENGROK_TELEMETRY_ENABLED": "true",
            "GROK_TELEMETRY_ENABLED": "false",
        ]
        #expect(GrokEnvGates.telemetryEnabled(environment: env) == true)
    }

    @Test("telemetryEnabled falls through to GROK spelling")
    func telemetryGrokSpelling() {
        let env = ["GROK_TELEMETRY_ENABLED": "false"]
        #expect(GrokEnvGates.telemetryEnabled(environment: env) == false)
    }

    @Test("telemetryEnabled returns nil when absent")
    func telemetryAbsent() {
        #expect(GrokEnvGates.telemetryEnabled(environment: [:]) == nil)
    }

    @Test("sessionRecap parses correctly")
    func sessionRecap() {
        #expect(GrokEnvGates.sessionRecap(environment: ["GROK_SESSION_RECAP": "0"]) == false)
        #expect(GrokEnvGates.sessionRecap(environment: ["GROK_SESSION_RECAP": "1"]) == true)
        #expect(GrokEnvGates.sessionRecap(environment: [:]) == nil)
    }

    @Test("webFetch parses correctly")
    func webFetch() {
        #expect(GrokEnvGates.webFetch(environment: ["GROK_WEB_FETCH": "true"]) == true)
        #expect(GrokEnvGates.webFetch(environment: [:]) == nil)
    }

    @Test("imageGen parses correctly")
    func imageGen() {
        #expect(GrokEnvGates.imageGen(environment: ["GROK_IMAGE_GEN": "disabled"]) == false)
        #expect(GrokEnvGates.imageGen(environment: [:]) == nil)
    }

    @Test("workspaceCommand parses correctly")
    func workspaceCommand() {
        #expect(GrokEnvGates.workspaceCommand(environment: ["GROK_WORKSPACE_COMMAND": "on"]) == true)
        #expect(GrokEnvGates.workspaceCommand(environment: [:]) == nil)
    }

    @Test("worktreeAutoGc parses correctly")
    func worktreeAutoGc() {
        #expect(GrokEnvGates.worktreeAutoGc(environment: ["GROK_WORKTREE_AUTO_GC": "false"]) == false)
        #expect(GrokEnvGates.worktreeAutoGc(environment: [:]) == nil)
    }

    @Test("crashHandler prefers OPENGROK spelling")
    func crashHandlerSpelling() {
        let env = ["OPENGROK_CRASH_HANDLER": "0", "GROK_CRASH_HANDLER": "1"]
        #expect(GrokEnvGates.crashHandler(environment: env) == false)
    }

    @Test("shell returns raw string")
    func shellRaw() {
        #expect(GrokEnvGates.shell(environment: ["GROK_SHELL": "/bin/fish"]) == "/bin/fish")
        #expect(GrokEnvGates.shell(environment: [:]) == nil)
    }
}

// MARK: - EffectiveFeatures precedence

@Suite("EffectiveFeatures precedence")
struct EffectiveFeaturesPrecedenceTests {

    @Test("requirement wins over all tiers")
    func requirementWins() {
        let config = try! parseTOML("""
        [features]
        session_recap = true
        """)
        var remote = AllowlistedRemoteSettings()
        remote.workspaceCommandEnabled = true

        let inputs = FeatureResolutionInputs(
            effectiveConfig: config,
            requirements: ["session_recap": false, "workspace_command": false],
            remote: remote,
            environment: ["GROK_SESSION_RECAP": "true"]
        )
        let features = EffectiveFeatures.resolve(inputs)

        #expect(features.sessionRecap.value == false)
        #expect(features.sessionRecap.source == .requirement)
        #expect(features.workspaceCommand.value == false)
        #expect(features.workspaceCommand.source == .requirement)
    }

    @Test("env wins over config and remote")
    func envWins() {
        let config = try! parseTOML("""
        [features]
        web_fetch = false
        """)
        let inputs = FeatureResolutionInputs(
            effectiveConfig: config,
            environment: ["GROK_WEB_FETCH": "true"]
        )
        let features = EffectiveFeatures.resolve(inputs)

        #expect(features.webFetch.value == true)
        #expect(features.webFetch.source == .env)
    }

    @Test("config wins over remote and default")
    func configWins() {
        var remote = AllowlistedRemoteSettings()
        remote.workspaceCommandEnabled = true

        let config = try! parseTOML("""
        [features]
        workspace_command = false
        """)
        let inputs = FeatureResolutionInputs(
            effectiveConfig: config,
            remote: remote
        )
        let features = EffectiveFeatures.resolve(inputs)

        #expect(features.workspaceCommand.value == false)
        #expect(features.workspaceCommand.source == .config)
    }

    @Test("remote wins over default")
    func remoteWinsOverDefault() {
        var remote = AllowlistedRemoteSettings()
        remote.workspaceCommandEnabled = true

        let inputs = FeatureResolutionInputs(remote: remote)
        let features = EffectiveFeatures.resolve(inputs)

        #expect(features.workspaceCommand.value == true)
        #expect(features.workspaceCommand.source == .remote)
    }

    @Test("remote sharing_enabled wins over default")
    func remoteSharingWinsOverDefault() {
        var remote = AllowlistedRemoteSettings()
        remote.sharingEnabled = true

        let inputs = FeatureResolutionInputs(remote: remote)
        let features = EffectiveFeatures.resolve(inputs)

        #expect(features.sharing.value == true)
        #expect(features.sharing.source == .remote)
    }

    @Test("default used when nothing set")
    func defaultsApplied() {
        let features = EffectiveFeatures.resolve(FeatureResolutionInputs())

        #expect(features.sessionRecap.value == true)
        #expect(features.sessionRecap.source == .default)
        #expect(features.webFetch.value == true)
        #expect(features.webFetch.source == .default)
        #expect(features.imageGen.value == true)
        #expect(features.imageGen.source == .default)
        #expect(features.imageEdit.value == true)
        #expect(features.imageEdit.source == .default)
        #expect(features.feedback.value == true)
        #expect(features.feedback.source == .default)
        #expect(features.workspaceCommand.value == false)
        #expect(features.workspaceCommand.source == .default)
        #expect(features.folderTrust.value == true)
        #expect(features.folderTrust.source == .default)
        #expect(features.workflows.value == false)
        #expect(features.workflows.source == .default)
        #expect(features.sharing.value == false)
        #expect(features.sharing.source == .default)
    }

    @Test("full precedence chain: requirement > env > config > remote > default")
    func fullChain() {
        var remote = AllowlistedRemoteSettings()
        remote.workspaceCommandEnabled = true
        remote.sharingEnabled = true

        let config = try! parseTOML("""
        [features]
        image_gen = false
        workspace_command = false
        """)
        let inputs = FeatureResolutionInputs(
            effectiveConfig: config,
            requirements: ["feedback": false],
            remote: remote,
            environment: ["GROK_SESSION_RECAP": "false"]
        )
        let features = EffectiveFeatures.resolve(inputs)

        #expect(features.feedback.value == false)
        #expect(features.feedback.source == .requirement)

        #expect(features.sessionRecap.value == false)
        #expect(features.sessionRecap.source == .env)

        #expect(features.imageGen.value == false)
        #expect(features.imageGen.source == .config)

        #expect(features.workspaceCommand.value == false)
        #expect(features.workspaceCommand.source == .config)

        #expect(features.sharing.value == true)
        #expect(features.sharing.source == .remote)

        #expect(features.webFetch.value == true)
        #expect(features.webFetch.source == .default)
    }
}

// MARK: - Negative inert tests

@Suite("Remote fields inertness")
struct RemoteFieldsInertnessTests {

    @Test("non-allowlisted remote sessionRecap cannot override EffectiveFeatures")
    func sessionRecapInert() {
        var rs = RemoteSettings()
        rs.sessionRecap = false
        let projected = AllowlistedRemoteSettings(projecting: rs)

        let inputs = FeatureResolutionInputs(remote: projected)
        let features = EffectiveFeatures.resolve(inputs)

        #expect(features.sessionRecap.value == true)
        #expect(features.sessionRecap.source == .default)
    }

    @Test("non-allowlisted remote webFetchEnabled cannot override EffectiveFeatures")
    func webFetchInert() {
        var rs = RemoteSettings()
        rs.webFetchEnabled = false
        let projected = AllowlistedRemoteSettings(projecting: rs)

        let inputs = FeatureResolutionInputs(remote: projected)
        let features = EffectiveFeatures.resolve(inputs)

        #expect(features.webFetch.value == true)
        #expect(features.webFetch.source == .default)
    }

    @Test("non-allowlisted remote imageGenEnabled cannot override EffectiveFeatures")
    func imageGenInert() {
        var rs = RemoteSettings()
        rs.imageGenEnabled = false
        let projected = AllowlistedRemoteSettings(projecting: rs)

        let inputs = FeatureResolutionInputs(remote: projected)
        let features = EffectiveFeatures.resolve(inputs)

        #expect(features.imageGen.value == true)
        #expect(features.imageGen.source == .default)
    }

    @Test("non-allowlisted remote feedbackEnabled cannot override EffectiveFeatures")
    func feedbackInert() {
        var rs = RemoteSettings()
        rs.feedbackEnabled = false
        let projected = AllowlistedRemoteSettings(projecting: rs)

        let inputs = FeatureResolutionInputs(remote: projected)
        let features = EffectiveFeatures.resolve(inputs)

        #expect(features.feedback.value == true)
        #expect(features.feedback.source == .default)
    }

    @Test("non-allowlisted remote compactionMode cannot reach AllowlistedRemoteSettings")
    func compactionModeInert() {
        var rs = RemoteSettings()
        rs.compactionMode = "aggressive"
        rs.twoPassCompactionEnabled = true
        rs.compactionWallClockBudgetSecs = 30

        let projected = AllowlistedRemoteSettings(projecting: rs)

        #expect(projected.telemetryMode == nil)
        #expect(projected.announcements == nil)
    }

    @Test("non-allowlisted remote folderTrustEnabled cannot override EffectiveFeatures")
    func folderTrustInert() {
        var rs = RemoteSettings()
        rs.folderTrustEnabled = false
        let projected = AllowlistedRemoteSettings(projecting: rs)

        let inputs = FeatureResolutionInputs(remote: projected)
        let features = EffectiveFeatures.resolve(inputs)

        #expect(features.folderTrust.value == true)
        #expect(features.folderTrust.source == .default)
    }

    @Test("non-allowlisted remote lspToolsEnabled cannot override EffectiveFeatures")
    func lspToolsInert() {
        var rs = RemoteSettings()
        rs.lspToolsEnabled = true
        let projected = AllowlistedRemoteSettings(projecting: rs)

        #expect(projected.telemetryMode == nil)
        #expect(projected.workspaceCommandEnabled == nil)
    }
}

// MARK: - Live-seam consumer proofs

@Suite("Live-seam consumer proofs")
struct LiveSeamConsumerProofTests {

    @Test("announcements remote_fetch: projected announcements are readable")
    func announcementsProjection() {
        var rs = RemoteSettings()
        let ann = RemoteAnnouncement(
            id: "test-1", message: "Maintenance window", severity: "critical",
            title: "Alert", cta: nil, updatedAt: "2026-08-10", expiresAt: nil,
            dismissible: true, persistent: false
        )
        rs.announcements = [ann]

        let projected = AllowlistedRemoteSettings(projecting: rs)
        let announcements = projected.announcements ?? []

        #expect(announcements.count == 1)
        #expect(announcements[0].id == "test-1")
        #expect(announcements[0].severity == "critical")
    }

    @Test("telemetry mode: telemetryMode and telemetryEnabled project correctly")
    func telemetryProjection() {
        var rs = RemoteSettings()
        rs.telemetryMode = "session_metrics"
        rs.telemetryEnabled = true

        let projected = AllowlistedRemoteSettings(projecting: rs)

        #expect(projected.telemetryMode == "session_metrics")
        #expect(projected.telemetryEnabled == true)
    }

    @Test("workspace command: workspaceCommandEnabled resolves through EffectiveFeatures")
    func workspaceCommandLiveSeam() {
        var remote = AllowlistedRemoteSettings()
        remote.workspaceCommandEnabled = true

        let inputs = FeatureResolutionInputs(remote: remote)
        let features = EffectiveFeatures.resolve(inputs)

        #expect(features.workspaceCommand.value == true)
        #expect(features.workspaceCommand.source == .remote)
    }

    @Test("sharing: sharingEnabled resolves through EffectiveFeatures")
    func sharingLiveSeam() {
        var remote = AllowlistedRemoteSettings()
        remote.sharingEnabled = true

        let inputs = FeatureResolutionInputs(remote: remote)
        let features = EffectiveFeatures.resolve(inputs)

        #expect(features.sharing.value == true)
        #expect(features.sharing.source == .remote)
    }

    @Test("privacy banner: privacyNoticeRollout and privacyBannerReshowDays project")
    func privacyBannerProjection() {
        var rs = RemoteSettings()
        rs.privacyNoticeRollout = true
        rs.privacyBannerReshowDays = 14

        let projected = AllowlistedRemoteSettings(projecting: rs)

        #expect(projected.privacyNoticeRollout == true)
        #expect(projected.privacyBannerReshowDays == 14)
    }
}
