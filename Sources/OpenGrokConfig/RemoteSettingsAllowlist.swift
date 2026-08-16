// RemoteSettingsAllowlist.swift
//
// Explicit reviewed allowlist for `RemoteSettings` → runtime authority.
//
// `RemoteSettings` decodes the full wire schema from `/v1/settings`.
// Most of those fields have no Swift consumer: they are parsed, retained
// for forward-compatible re-serialization, and MUST NOT influence runtime
// behavior. This module defines the narrow set that MAY override local
// policy, field by field, with the consumer cited for each.
//
// Fail-closed: a field not on the allowlist is inert by construction.
// Adding a new field requires adding it here with a consumer citation,
// and the negative test suite (`RemoteSettingsAllowlistTests`) asserts
// that every non-allowlisted field stays nil in the projected view.
//
// Rust reference (config.rs:2468-2725): each `resolve_*` method reads a
// specific remote field via `self.remote_settings.as_ref().and_then(…)`.
// This allowlist mirrors that pattern: only fields with a live Swift
// resolver are projected.

import Foundation
import OpenGrokConfigTypes

// MARK: - Allowlisted remote settings

/// The subset of `RemoteSettings` fields that have reviewed Swift
/// consumers and are permitted to influence runtime behavior.
///
/// Every field here has a cited consumer. Fields absent from this struct
/// are inert: `RemoteSettings` parses and retains them, but no resolver
/// reads them.
public struct AllowlistedRemoteSettings: Sendable, Equatable {

    // -- Telemetry (TelemetryModeResolver, ExternalOtelRemotePolicy) --

    /// `telemetry_mode` — consumed by `TelemetryModeResolver.resolve()`.
    public var telemetryMode: String?
    /// `telemetry_enabled` — consumed by `TelemetryModeResolver.resolve()`.
    public var telemetryEnabled: Bool?
    /// `external_otel_disabled` — consumed by `ExternalOtelRemotePolicy.init`.
    public var externalOtelDisabled: Bool?
    /// `external_otel_content_gates_locked` — consumed by `ExternalOtelRemotePolicy.init`.
    public var externalOtelContentGatesLocked: Bool?

    // -- Privacy banner (PagerPrivacyBanner) --

    /// `privacy_notice_rollout` — consumed by `resolvePrivacyNoticeRollout()`.
    public var privacyNoticeRollout: Bool?
    /// `privacy_banner_reshow_days` — consumed by `resolvePrivacyBannerReshowDays()`.
    public var privacyBannerReshowDays: UInt64?

    // -- Announcements (LiveAnnouncementsComposition) --

    /// `announcements` — consumed by `LiveAnnouncementsComposition`.
    public var announcements: [RemoteAnnouncement]?

    // -- Sharing (LiveShareComposition) --

    /// `sharing_enabled` — consumed by `LiveShareComposition`.
    public var sharingEnabled: Bool?

    // -- Workspace (LiveWorkspaceComposition) --

    /// `workspace_command_enabled` — consumed by `workspaceCommandGate()`.
    public var workspaceCommandEnabled: Bool?

    // -- Access gate (LiveComposition privacy banner state) --

    /// `zdr_access_enabled` — consumed by `refreshPrivacyBannerState()`.
    public var zdrAccessEnabled: Bool?
    /// `gate_message` — consumed by `refreshPrivacyBannerState()`.
    public var gateMessage: String?

    // -- Session recap (LiveRecap / EffectiveFeatures) --

    /// `session_recap` — consumed by `EffectiveFeatures.resolve` →
    /// `LiveRecap.enabled` (`resolve_session_recap`, config.rs:2657-2667).
    public var sessionRecap: Bool?

    // -- Session feature authority (EffectiveFeatures) --

    public var traceUploadEnabled: Bool?
    public var twoPassCompactionEnabled: Bool?
    public var askUserQuestionEnabled: Bool?
    public var writeFileEnabled: Bool?
    public var cancelRewindEnabled: Bool?
    public var compactionMode: String?
    public var compactionDetail: String?

    public init() {}
}

// MARK: - Projection

extension AllowlistedRemoteSettings {
    /// Project only the allowlisted fields from a full `RemoteSettings`.
    ///
    /// Every field not listed here is dropped. This is the ONLY path
    /// through which remote settings should reach runtime resolvers.
    public init(projecting remote: RemoteSettings) {
        self.telemetryMode = remote.telemetryMode
        self.telemetryEnabled = remote.telemetryEnabled
        self.externalOtelDisabled = remote.externalOtelDisabled
        self.externalOtelContentGatesLocked = remote.externalOtelContentGatesLocked
        self.privacyNoticeRollout = remote.privacyNoticeRollout
        self.privacyBannerReshowDays = remote.privacyBannerReshowDays
        self.announcements = remote.announcements
        self.sharingEnabled = remote.sharingEnabled
        self.workspaceCommandEnabled = remote.workspaceCommandEnabled
        self.zdrAccessEnabled = remote.zdrAccessEnabled
        self.gateMessage = remote.gateMessage
        self.sessionRecap = remote.sessionRecap
        self.traceUploadEnabled = remote.traceUploadEnabled
        self.twoPassCompactionEnabled = remote.twoPassCompactionEnabled
        self.askUserQuestionEnabled = remote.askUserQuestionEnabled
        self.writeFileEnabled = remote.writeFileEnabled
        self.cancelRewindEnabled = remote.cancelRewindEnabled
        self.compactionMode = remote.compactionMode
        self.compactionDetail = remote.compactionDetail
    }
}

// MARK: - Allowlist membership check

/// The set of `RemoteSettings.CodingKeys` wire names that are on the
/// allowlist. Used by negative tests to assert that every field NOT in
/// this set stays inert.
public let remoteSettingsAllowlistedWireNames: Set<String> = [
    "telemetry_mode",
    "telemetry_enabled",
    "external_otel_disabled",
    "external_otel_content_gates_locked",
    "privacy_notice_rollout",
    "privacy_banner_reshow_days",
    "announcements",
    "sharing_enabled",
    "workspace_command_enabled",
    "zdr_access_enabled",
    "gate_message",
    "session_recap",
    "trace_upload_enabled",
    "two_pass_compaction_enabled",
    "ask_user_question_enabled",
    "write_file_enabled",
    "cancel_rewind_enabled",
    "compaction_mode",
    "compaction_detail",
]
