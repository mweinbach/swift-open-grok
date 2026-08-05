// RemoteSettings.swift
//
// Port of `xai-grok-config-types/src/lib.rs` (the remote-settings half) plus
// the local `RemoteAnnouncement` (mirroring `xai-grok-announcements`).
//
// `RemoteSettings` is the typed shape of cli-chat-proxy `GET /v1/settings`.
// All fields are `Optional` with `decodeIfPresent` defaults so:
//   * Missing fields from old servers are gracefully ignored.
//   * New fields added in the future don't break existing clients.
//   * Callers can distinguish "server said false" from "server didn't say".

import Foundation
import OpenGrokShared

// MARK: - RemoteAnnouncement (local; see module doc)

/// Announcement from remote settings or local override.
///
/// This is the wire-compatible local copy of `xai_grok_announcements::RemoteAnnouncement`.
/// All fields are optional; unknown fields are retained in `extra` so a future
/// server field can't be silently dropped. See the module doc for the
/// consolidation plan with `OpenGrokAnnouncements` (W5-S6).
public struct RemoteAnnouncement: Hashable, Sendable, Codable, Equatable {
    public var id: String?
    public var message: String?
    public var severity: String?
    public var title: String?
    public var cta: AnnouncementCta?
    public var updatedAt: String?
    public var expiresAt: String?
    public var dismissible: Bool?
    public var persistent: Bool?
    public var extra: [String: JSONValue]

    public init() {
        self.id = nil
        self.message = nil
        self.severity = nil
        self.title = nil
        self.cta = nil
        self.updatedAt = nil
        self.expiresAt = nil
        self.dismissible = nil
        self.persistent = nil
        self.extra = [:]
    }

    public init(
        id: String?, message: String?, severity: String?, title: String?,
        cta: AnnouncementCta?, updatedAt: String?, expiresAt: String?,
        dismissible: Bool?, persistent: Bool?, extra: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.message = message
        self.severity = severity
        self.title = title
        self.cta = cta
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
        self.dismissible = dismissible
        self.persistent = persistent
        self.extra = extra
    }

    private enum CodingKeys: String, CodingKey {
        case id, message, severity, title, cta
        case updatedAt = "updated_at"
        case expiresAt = "expires_at"
        case dismissible, persistent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        severity = try c.decodeIfPresent(String.self, forKey: .severity)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        cta = try c.decodeIfPresent(AnnouncementCta.self, forKey: .cta)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
        expiresAt = try c.decodeIfPresent(String.self, forKey: .expiresAt)
        dismissible = try c.decodeIfPresent(Bool.self, forKey: .dismissible)
        persistent = try c.decodeIfPresent(Bool.self, forKey: .persistent)
        let known: Set<String> = [
            CodingKeys.id.stringValue, CodingKeys.message.stringValue,
            CodingKeys.severity.stringValue, CodingKeys.title.stringValue,
            CodingKeys.cta.stringValue, CodingKeys.updatedAt.stringValue,
            CodingKeys.expiresAt.stringValue, CodingKeys.dismissible.stringValue,
            CodingKeys.persistent.stringValue,
        ]
        extra = try UnknownFields.decode(from: decoder, knownKeyStrings: known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encodeIfPresent(message, forKey: .message)
        try c.encodeIfPresent(severity, forKey: .severity)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(cta, forKey: .cta)
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(expiresAt, forKey: .expiresAt)
        try c.encodeIfPresent(dismissible, forKey: .dismissible)
        try c.encodeIfPresent(persistent, forKey: .persistent)
        if !extra.isEmpty {
            var any = encoder.container(keyedBy: AnyCodingKey.self)
            try UnknownFields.encode(extra, into: &any)
        }
    }
}

/// Optional call-to-action on an announcement.
public struct AnnouncementCta: Hashable, Sendable, Codable, Equatable {
    public var label: String?
    public var url: String?
    public var caption: String?

    public init(label: String? = nil, url: String? = nil, caption: String? = nil) {
        self.label = label
        self.url = url
        self.caption = caption
    }

    private enum CodingKeys: String, CodingKey { case label, url, caption }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        caption = try c.decodeIfPresent(String.self, forKey: .caption)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encodeIfPresent(caption, forKey: .caption)
    }
}

// MARK: - CampaignOverride

/// A remote `campaigns[]` entry: an `id` gate plus a full-power flattened
/// config patch (the JSON sibling of a `[[campaigns]]` TOML override).
public struct CampaignOverride: Hashable, Sendable, Codable, Equatable {
    public var id: String?
    /// The flattened patch object (every key other than `id`/`campaign_id`).
    public var patch: [String: JSONValue]

    public init(id: String? = nil, patch: [String: JSONValue] = [:]) {
        self.id = id
        self.patch = patch
    }

    /// Tolerant decoder: `id` accepts `id` or `campaign_id` (Rust `alias`);
    /// every other key lands in `patch`.
    public init(from decoder: Decoder) throws {
        let dynamic = try decoder.container(keyedBy: AnyCodingKey.self)
        var id: String? = nil
        var patch: [String: JSONValue] = [:]
        for key in dynamic.allKeys {
            let value = try dynamic.decode(JSONValue.self, forKey: key)
            switch key.stringValue {
            case "id", "campaign_id":
                if case .string(let s) = value { id = s }
            default:
                patch[key.stringValue] = value
            }
        }
        self.id = id
        self.patch = patch
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        if let id = id { try c.encode(JSONValue.string(id), forKey: AnyCodingKey("id")) }
        for (k, v) in patch { try c.encode(v, forKey: AnyCodingKey(k)) }
    }
}

// MARK: - DoomLoopRecoverySettings

/// Doom-loop recovery settings: ONE struct serves both the local
/// `[doom_loop_recovery]` TOML table and the remote settings
/// `doom_loop_recovery` JSON object, so the two stay 1:1. All fields are
/// `Optional` with per-field defaults (a partial object never fails the
/// parse, and unknown future keys are ignored); unset fields fall through
/// per-field in the resolver (env > TOML > remote > default).
public struct DoomLoopRecoverySettings: Hashable, Sendable, Codable, Equatable {
    /// Send the `x-grok-doom-loop-check` header and parse the reported
    /// triggers. `Some(false)` is a kill-switch; absent ⇒ client default (off).
    public var enabled: Bool?
    /// Highest `tail_repetition` threshold considered confident (clamped to
    /// 2..=64). Absent ⇒ client default (8).
    public var maxThreshold: UInt32?
    /// Resample budget per turn (clamped to 0..=5). Absent ⇒ client default (2).
    public var maxRetries: UInt32?

    public init(enabled: Bool? = nil, maxThreshold: UInt32? = nil, maxRetries: UInt32? = nil) {
        self.enabled = enabled
        self.maxThreshold = maxThreshold
        self.maxRetries = maxRetries
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case maxThreshold = "max_threshold"
        case maxRetries = "max_retries"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled)
        maxThreshold = try c.decodeIfPresent(UInt32.self, forKey: .maxThreshold)
        maxRetries = try c.decodeIfPresent(UInt32.self, forKey: .maxRetries)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(enabled, forKey: .enabled)
        try c.encodeIfPresent(maxThreshold, forKey: .maxThreshold)
        try c.encodeIfPresent(maxRetries, forKey: .maxRetries)
    }
}

// MARK: - DisplayRefreshSettings

/// Display-refresh probe + auto-cadence settings. Field-wise tolerant
/// deserialize (wrong types → `nil`); unknown keys kept in `extra` so
/// settings save cannot drop future knobs. Resolved by the caller's
/// `resolve_display_refresh`. Client defaults: probe on, auto off, floor 8 ms,
/// ceiling 16 ms, Hz band 55–165.
///
/// **Note:** `OpenGrokShared.DisplayRefreshSettings` (W0-S4) is the
/// `UiConfig`-facing copy; this is the `RemoteSettings.display_refresh`-facing
/// copy. The wire form is identical. A future consolidation wave may unify
/// them under `OpenGrokConfigTypes` and have `OpenGrokShared` re-export.
public struct DisplayRefreshSettings: Hashable, Sendable, Codable, Equatable {
    public var probeEnabled: Bool?
    public var autoCadenceEnabled: Bool?
    public var floorMs: UInt32?
    public var ceilingMs: UInt32?
    public var minHz: UInt32?
    public var maxHz: UInt32?
    public var extra: [String: JSONValue]

    public init() {
        self.probeEnabled = nil
        self.autoCadenceEnabled = nil
        self.floorMs = nil
        self.ceilingMs = nil
        self.minHz = nil
        self.maxHz = nil
        self.extra = [:]
    }

    public init(
        probeEnabled: Bool?, autoCadenceEnabled: Bool?,
        floorMs: UInt32?, ceilingMs: UInt32?,
        minHz: UInt32?, maxHz: UInt32?,
        extra: [String: JSONValue] = [:]
    ) {
        self.probeEnabled = probeEnabled
        self.autoCadenceEnabled = autoCadenceEnabled
        self.floorMs = floorMs
        self.ceilingMs = ceilingMs
        self.minHz = minHz
        self.maxHz = maxHz
        self.extra = extra
    }

    /// `true` when no field is set (all inherit remote/default).
    public var isDefault: Bool {
        probeEnabled == nil && autoCadenceEnabled == nil
            && floorMs == nil && ceilingMs == nil
            && minHz == nil && maxHz == nil
            && extra.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case probeEnabled = "probe_enabled"
        case autoCadenceEnabled = "auto_cadence_enabled"
        case floorMs = "floor_ms"
        case ceilingMs = "ceiling_ms"
        case minHz = "min_hz"
        case maxHz = "max_hz"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        probeEnabled = try Self.decodeTolerantBool(from: c, forKey: .probeEnabled)
        autoCadenceEnabled = try Self.decodeTolerantBool(from: c, forKey: .autoCadenceEnabled)
        floorMs = try Self.decodeTolerantU32(from: c, forKey: .floorMs)
        ceilingMs = try Self.decodeTolerantU32(from: c, forKey: .ceilingMs)
        minHz = try Self.decodeTolerantU32(from: c, forKey: .minHz)
        maxHz = try Self.decodeTolerantU32(from: c, forKey: .maxHz)
        let known: Set<String> = [
            CodingKeys.probeEnabled.stringValue,
            CodingKeys.autoCadenceEnabled.stringValue,
            CodingKeys.floorMs.stringValue,
            CodingKeys.ceilingMs.stringValue,
            CodingKeys.minHz.stringValue,
            CodingKeys.maxHz.stringValue,
        ]
        extra = try UnknownFields.decode(from: decoder, knownKeyStrings: known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(probeEnabled, forKey: .probeEnabled)
        try c.encodeIfPresent(autoCadenceEnabled, forKey: .autoCadenceEnabled)
        try c.encodeIfPresent(floorMs, forKey: .floorMs)
        try c.encodeIfPresent(ceilingMs, forKey: .ceilingMs)
        try c.encodeIfPresent(minHz, forKey: .minHz)
        try c.encodeIfPresent(maxHz, forKey: .maxHz)
        if !extra.isEmpty {
            var any = encoder.container(keyedBy: AnyCodingKey.self)
            try UnknownFields.encode(extra, into: &any)
        }
    }

    private static func decodeTolerantBool(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> Bool? {
        guard container.contains(key) else { return nil }
        if let b = try? container.decode(Bool.self, forKey: key) { return b }
        return nil
    }

    private static func decodeTolerantU32(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> UInt32? {
        guard container.contains(key) else { return nil }
        if let i = try? container.decode(Int.self, forKey: key), i >= 0 {
            return UInt32(exactly: i)
        }
        if let d = try? container.decode(Double.self, forKey: key), d >= 0 {
            return UInt32(exactly: d)
        }
        return nil
    }
}

// MARK: - ContextualHintsRemote

/// Remote enable tier for the per-tip contextual hints (mirrors the client's
/// `[ui.contextual_hints]` shape). Each field is a soft default for one tip;
/// `nil` defers to the client default (on).
public struct ContextualHintsRemote: Hashable, Sendable, Codable, Equatable {
    public var undo: Bool?
    public var planMode: Bool?
    public var imageInput: Bool?
    public var sendNow: Bool?
    public var smallScreen: Bool?
    public var wordSelect: Bool?
    public var sshWrap: Bool?

    public init() {
        self.undo = nil; self.planMode = nil; self.imageInput = nil
        self.sendNow = nil; self.smallScreen = nil; self.wordSelect = nil; self.sshWrap = nil
    }

    public init(
        undo: Bool?, planMode: Bool?, imageInput: Bool?,
        sendNow: Bool?, smallScreen: Bool?, wordSelect: Bool?, sshWrap: Bool?
    ) {
        self.undo = undo; self.planMode = planMode; self.imageInput = imageInput
        self.sendNow = sendNow; self.smallScreen = smallScreen; self.wordSelect = wordSelect
        self.sshWrap = sshWrap
    }

    private enum CodingKeys: String, CodingKey {
        case undo
        case planMode = "plan_mode"
        case imageInput = "image_input"
        case sendNow = "send_now"
        case smallScreen = "small_screen"
        case wordSelect = "word_select"
        case sshWrap = "ssh_wrap"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        undo = try c.decodeIfPresent(Bool.self, forKey: .undo)
        planMode = try c.decodeIfPresent(Bool.self, forKey: .planMode)
        imageInput = try c.decodeIfPresent(Bool.self, forKey: .imageInput)
        sendNow = try c.decodeIfPresent(Bool.self, forKey: .sendNow)
        smallScreen = try c.decodeIfPresent(Bool.self, forKey: .smallScreen)
        wordSelect = try c.decodeIfPresent(Bool.self, forKey: .wordSelect)
        sshWrap = try c.decodeIfPresent(Bool.self, forKey: .sshWrap)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(undo, forKey: .undo)
        try c.encodeIfPresent(planMode, forKey: .planMode)
        try c.encodeIfPresent(imageInput, forKey: .imageInput)
        try c.encodeIfPresent(sendNow, forKey: .sendNow)
        try c.encodeIfPresent(smallScreen, forKey: .smallScreen)
        try c.encodeIfPresent(wordSelect, forKey: .wordSelect)
        try c.encodeIfPresent(sshWrap, forKey: .sshWrap)
    }
}

// MARK: - GoalRoleModel

/// A model + the harness whose system prompt / toolset flavor that model must
/// run against. The pair is the atomic configurable unit because a model is
/// only guaranteed to work with a compatible harness (cursor vs grok-build).
public struct GoalRoleModel: Hashable, Sendable, Codable, Equatable {
    public var model: String
    public var agentType: String

    public init(model: String, agentType: String) {
        self.model = model
        self.agentType = agentType
    }

    private enum CodingKeys: String, CodingKey {
        case model
        case agentType = "agent_type"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decode(String.self, forKey: .model)
        agentType = try c.decode(String.self, forKey: .agentType)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(model, forKey: .model)
        try c.encode(agentType, forKey: .agentType)
    }
}

// MARK: - RemoteSettings

/// Remote settings fetched from cli-chat-proxy `GET /v1/settings`.
///
/// All fields are `Optional` so:
///   * Missing fields from old servers are gracefully ignored.
///   * New fields added in the future don't break existing clients.
///   * Callers can distinguish "server said false" from "server didn't say".
///
/// This is the full Rust `RemoteSettings` surface. Malformed `announcements`
/// items are dropped (tolerant); malformed `goal_planner_model` /
/// `goal_strategist_model` / `goal_skeptic_models` are dropped to `nil`/`[]`
/// rather than failing the whole parse, mirroring the Rust tolerant
/// deserializers.
public struct RemoteSettings: Hashable, Sendable, Codable, Equatable {
    public var leaderMode: Bool?
    public var maxUploadFileBytes: UInt64?
    public var maxUploadUntrackedBytes: UInt64?
    public var nonGitWorkspaceCapture: Bool?
    public var loginShellCapture: Bool?
    /// When `false`, scheduled task fires run as main-conversation turns
    /// instead of background subagents. lib.rs:461-464.
    public var schedulerBackgroundLoops: Bool?
    public var releaseChannel: String?
    public var locTracking: Bool?
    public var memoryEnabled: Bool?
    public var memorySearchMaxResults: UInt32?
    public var memorySearchMinScore: Float?
    public var memoryInitialInjectionEnabled: Bool?
    public var memoryInitialInjectionMinScore: Float?
    public var memoryEmbeddingModel: String?
    public var memoryEmbeddingDimensions: UInt32?
    public var pruningEnabled: Bool?
    public var pruningKeepLastNTurns: UInt32?
    public var pruningSoftTrimThreshold: UInt32?
    public var flushEnabled: Bool?
    public var flushSoftThresholdTokens: UInt64?
    public var flushIdleTimeoutSecs: UInt64?
    public var flushSemanticDedupThreshold: Double?
    public var memoryTemporalDecayEnabled: Bool?
    public var memoryTemporalDecayHalfLifeDays: Double?
    public var memoryMmrEnabled: Bool?
    public var memoryMmrLambda: Double?
    public var memoryWatcherEnabled: Bool?
    public var dreamEnabled: Bool?
    public var dreamMinHours: UInt64?
    public var dreamMinSessions: UInt64?
    public var dreamCheckIntervalSecs: UInt64?
    public var subscriptionWatchIntervalSecs: UInt64?
    public var writebackEnabled: Bool?
    public var oauth2Issuer: String?
    public var oauth2ClientId: String?
    public var grokOauthEnabled: Bool?
    public var lspToolsEnabled: Bool?
    public var folderTrustEnabled: Bool?
    public var writeFileEnabled: Bool?
    public var fileToolset: String?
    public var inferenceIdleTimeoutSecs: UInt64?
    public var mcpStartupTimeoutSecs: UInt64?
    public var maxMcpOutputBytes: UInt64?
    public var sessionRegistryEnabled: Bool?
    public var doomLoopRecovery: DoomLoopRecoverySettings?
    /// Automatic worktree GC policy. Absent ⇒ every knob falls through to
    /// TOML/defaults; a partial object falls through per-field; a
    /// present-but-malformed nested value drops to `nil` without failing the
    /// whole parse. Platform age-expiry policy is client-hardcoded and not
    /// remote-overridable. lib.rs:610-616.
    public var worktreeAutoGc: WorktreeAutoGcSettings?
    public var todoGateEnabled: Bool?
    public var todoGateMaxFiresPerPrompt: UInt32?
    public var autoWakeEnabled: Bool?
    public var cursorSkillsEnabled: Bool?
    public var cursorRulesEnabled: Bool?
    public var cursorAgentsEnabled: Bool?
    public var claudeSkillsEnabled: Bool?
    public var claudeRulesEnabled: Bool?
    public var claudeAgentsEnabled: Bool?
    public var cursorMcpsEnabled: Bool?
    public var cursorHooksEnabled: Bool?
    public var claudeMcpsEnabled: Bool?
    public var claudeHooksEnabled: Bool?
    public var cursorSessionsEnabled: Bool?
    public var claudeSessionsEnabled: Bool?
    public var codexSessionsEnabled: Bool?
    public var goalEnabled: Bool?
    public var goalClassifierEnabled: Bool?
    public var goalPlannerEnabled: Bool?
    public var goalSummaryEnabled: Bool?
    public var goalVerifierCount: UInt32?
    public var goalClassifierMaxRuns: UInt32?
    public var goalStrategistEvery: UInt32?
    public var goalPlannerModel: GoalRoleModel?
    public var goalStrategistModel: GoalRoleModel?
    public var goalSkepticModels: [GoalRoleModel]
    /// lib.rs:725-726.
    public var workflowsEnabled: Bool?
    public var managedMcpsEnabled: Bool?
    public var managedMcpGatewayToolsEnabled: Bool?
    public var externalOtelDisabled: Bool?
    public var externalOtelContentGatesLocked: Bool?
    /// `false` disarms managed-config signature verification (remote
    /// kill-switch). lib.rs:747-749.
    public var managedConfigSignatureVerification: Bool?
    public var telemetryEnabled: Bool?
    public var telemetryMode: String?
    public var traceUploadEnabled: Bool?
    public var feedbackEnabled: Bool?
    public var twoPassCompactionEnabled: Bool?
    public var tips: [String]?
    /// Free-form per-command tags (e.g. `new`, `beta`) rendered as a
    /// bracketed label in the slash dropdown, keyed by canonical command
    /// name. Present-but-malformed → `nil` (does not fail the whole parse);
    /// local `[slash_command_tags]` overrides per key. lib.rs:777-782.
    public var slashCommandTags: [String: String]?
    public var nonGitWarning: Bool?
    public var officialMarketplaceAutoRegister: Bool?
    public var pluginCta: Bool?
    public var announcements: [RemoteAnnouncement]?
    public var webSearchModel: String?
    public var sessionSummaryModel: String?
    public var imageDescriptionModel: String?
    public var promptSuggestionModel: String?
    public var defaultModel: String?
    public var campaigns: [CampaignOverride]
    public var autoBackgroundOnTimeout: Bool?
    public var allowBackgroundOperator: Bool?
    public var askUserQuestionTimeoutEnabled: Bool?
    public var askUserQuestionTimeoutSecs: UInt64?
    public var subagentWorktreeSnapshotEnabled: Bool?
    public var imageGenEnabled: Bool?
    public var imageGenModelOverride: String?
    /// Optional Imagine model override for `image_edit`. Absent/empty →
    /// default. lib.rs:858-860.
    public var imageEditModelOverride: String?
    public var videoGenEnabled: Bool?
    public var imageNormalizeCacheEnabled: Bool?
    public var pathNotFoundHints: Bool?
    public var contextualHints: ContextualHintsRemote?
    public var worktreeType: String?
    public var restoreCode: Bool?
    public var cancelRewindEnabled: Bool?
    public var sessionRecap: Bool?
    public var askUserQuestionEnabled: Bool?
    public var webFetchEnabled: Bool?
    public var webFetchProxy: String?
    public var webFetchAllowedDomains: [String]?
    public var showResolvedModel: Bool?
    public var sharingEnabled: Bool?
    public var voiceModeEnabled: Bool?
    public var zdrAccessEnabled: Bool?
    /// When `true`, the client may show the coding-data sharing upsell
    /// banner. Absent means off, so older servers and missing flags keep the
    /// banner hidden. lib.rs:930-935.
    public var privacyNoticeRollout: Bool?
    /// Days after a privacy-banner dismiss before it may re-show for users
    /// who remain coding-data opted-out. `nil` / `0` = never re-show after
    /// dismiss. lib.rs:936-940.
    public var privacyBannerReshowDays: UInt64?
    public var rememberToolApprovals: Bool?
    public var crashHandlerEnabled: Bool?
    public var showThinkingBlocks: Bool?
    public var groupToolVerbs: Bool?
    public var collapsedEditBlocks: Bool?
    public var displayRefresh: DisplayRefreshSettings?
    public var autoMode: JSONValue?
    public var permissionMode: String?
    public var subscriptionTier: String?
    public var gateMessage: String?
    public var gateUrl: String?
    public var gateLabel: String?
    public var sessionPickerGrouped: Bool?
    public var allowAccess: Bool?
    public var subscriptionTierDisplay: String?
    public var onDemandEnabled: Bool?
    public var usageBillingRedirectUrl: String?
    public var suggestionsEnabled: Bool?
    public var suggestionsAiEnabled: Bool?
    public var autoCompactThresholdPercent: UInt8?
    /// Max subagent nesting depth (`grok_build_settings.subagents_max_depth`).
    /// lib.rs:1038-1040.
    public var subagentsMaxDepth: UInt32?
    public var systemPromptLabel: String?
    public var compactionWallClockBudgetSecs: UInt64?
    public var compactionMode: String?
    public var compactionDetail: String?
    public var compactionVerbatimInput: Bool?
    public var compactionToolChoice: String?
    public var imagineToolsDisabled: [String]?
    public var workspaceCommandEnabled: Bool?
    public var jemallocHeapProfileEnabled: Bool?
    public var jemallocHeapProfileThresholdsBytes: [UInt64]?
    public var jemallocHeapProfilePollIntervalSecs: UInt64?

    public init() {
        self.campaigns = []
        self.goalSkepticModels = []
    }

    /// Denylist check for an optional imagine tool. Returns `true` when the
    /// server sent `imagine_tools_disabled` and it contains `tool`
    /// (force-off); otherwise `false` (defer to the tool's own default).
    public func imagineToolDisabled(_ tool: String) -> Bool {
        guard let list = imagineToolsDisabled else { return false }
        return list.contains(tool)
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case leaderMode = "leader_mode"
        case maxUploadFileBytes = "max_upload_file_bytes"
        case maxUploadUntrackedBytes = "max_upload_untracked_bytes"
        case nonGitWorkspaceCapture = "non_git_workspace_capture"
        case loginShellCapture = "login_shell_capture"
        case schedulerBackgroundLoops = "scheduler_background_loops"
        case releaseChannel = "release_channel"
        case locTracking = "loc_tracking"
        case memoryEnabled = "memory_enabled"
        case memorySearchMaxResults = "memory_search_max_results"
        case memorySearchMinScore = "memory_search_min_score"
        case memoryInitialInjectionEnabled = "memory_initial_injection_enabled"
        case memoryInitialInjectionMinScore = "memory_initial_injection_min_score"
        case memoryEmbeddingModel = "memory_embedding_model"
        case memoryEmbeddingDimensions = "memory_embedding_dimensions"
        case pruningEnabled = "pruning_enabled"
        case pruningKeepLastNTurns = "pruning_keep_last_n_turns"
        case pruningSoftTrimThreshold = "pruning_soft_trim_threshold"
        case flushEnabled = "flush_enabled"
        case flushSoftThresholdTokens = "flush_soft_threshold_tokens"
        case flushIdleTimeoutSecs = "flush_idle_timeout_secs"
        case flushSemanticDedupThreshold = "flush_semantic_dedup_threshold"
        case memoryTemporalDecayEnabled = "memory_temporal_decay_enabled"
        case memoryTemporalDecayHalfLifeDays = "memory_temporal_decay_half_life_days"
        case memoryMmrEnabled = "memory_mmr_enabled"
        case memoryMmrLambda = "memory_mmr_lambda"
        case memoryWatcherEnabled = "memory_watcher_enabled"
        case dreamEnabled = "dream_enabled"
        case dreamMinHours = "dream_min_hours"
        case dreamMinSessions = "dream_min_sessions"
        case dreamCheckIntervalSecs = "dream_check_interval_secs"
        case subscriptionWatchIntervalSecs = "subscription_watch_interval_secs"
        case writebackEnabled = "writeback_enabled"
        case oauth2Issuer = "oauth2_issuer"
        case oauth2ClientId = "oauth2_client_id"
        case grokOauthEnabled = "grok_oauth_enabled"
        case lspToolsEnabled = "lsp_tools_enabled"
        case folderTrustEnabled = "folder_trust_enabled"
        case writeFileEnabled = "write_file_enabled"
        case fileToolset = "file_toolset"
        case inferenceIdleTimeoutSecs = "inference_idle_timeout_secs"
        case mcpStartupTimeoutSecs = "mcp_startup_timeout_secs"
        case maxMcpOutputBytes = "max_mcp_output_bytes"
        case sessionRegistryEnabled = "session_registry_enabled"
        case doomLoopRecovery = "doom_loop_recovery"
        case worktreeAutoGc = "worktree_auto_gc"
        case todoGateEnabled = "todo_gate_enabled"
        case todoGateMaxFiresPerPrompt = "todo_gate_max_fires_per_prompt"
        case autoWakeEnabled = "auto_wake_enabled"
        case cursorSkillsEnabled = "cursor_skills_enabled"
        case cursorRulesEnabled = "cursor_rules_enabled"
        case cursorAgentsEnabled = "cursor_agents_enabled"
        case claudeSkillsEnabled = "claude_skills_enabled"
        case claudeRulesEnabled = "claude_rules_enabled"
        case claudeAgentsEnabled = "claude_agents_enabled"
        case cursorMcpsEnabled = "cursor_mcps_enabled"
        case cursorHooksEnabled = "cursor_hooks_enabled"
        case claudeMcpsEnabled = "claude_mcps_enabled"
        case claudeHooksEnabled = "claude_hooks_enabled"
        case cursorSessionsEnabled = "cursor_sessions_enabled"
        case claudeSessionsEnabled = "claude_sessions_enabled"
        case codexSessionsEnabled = "codex_sessions_enabled"
        case goalEnabled = "goal_enabled"
        case goalClassifierEnabled = "goal_classifier_enabled"
        case goalPlannerEnabled = "goal_planner_enabled"
        case goalSummaryEnabled = "goal_summary_enabled"
        case goalVerifierCount = "goal_verifier_count"
        case goalClassifierMaxRuns = "goal_classifier_max_runs"
        case goalStrategistEvery = "goal_strategist_every"
        case goalPlannerModel = "goal_planner_model"
        case goalStrategistModel = "goal_strategist_model"
        case goalSkepticModels = "goal_skeptic_models"
        case workflowsEnabled = "workflows_enabled"
        case managedMcpsEnabled = "managed_mcps_enabled"
        case managedMcpGatewayToolsEnabled = "managed_mcp_gateway_tools_enabled"
        case externalOtelDisabled = "external_otel_disabled"
        case externalOtelContentGatesLocked = "external_otel_content_gates_locked"
        case managedConfigSignatureVerification = "managed_config_signature_verification"
        case telemetryEnabled = "telemetry_enabled"
        case telemetryMode = "telemetry_mode"
        case traceUploadEnabled = "trace_upload_enabled"
        case feedbackEnabled = "feedback_enabled"
        case twoPassCompactionEnabled = "two_pass_compaction_enabled"
        case tips
        case slashCommandTags = "slash_command_tags"
        case nonGitWarning = "non_git_warning"
        case officialMarketplaceAutoRegister = "official_marketplace_auto_register"
        case pluginCta = "plugin_cta"
        case announcements
        case webSearchModel = "web_search_model"
        case sessionSummaryModel = "session_summary_model"
        case imageDescriptionModel = "image_description_model"
        case promptSuggestionModel = "prompt_suggestion_model"
        case defaultModel = "default_model"
        case campaigns
        case autoBackgroundOnTimeout = "auto_background_on_timeout"
        case allowBackgroundOperator = "allow_background_operator"
        case askUserQuestionTimeoutEnabled = "ask_user_question_timeout_enabled"
        case askUserQuestionTimeoutSecs = "ask_user_question_timeout_secs"
        case subagentWorktreeSnapshotEnabled = "subagent_worktree_snapshot_enabled"
        case imageGenEnabled = "image_gen_enabled"
        case imageGenModelOverride = "image_gen_model_override"
        case imageEditModelOverride = "image_edit_model_override"
        case videoGenEnabled = "video_gen_enabled"
        case imageNormalizeCacheEnabled = "image_normalize_cache_enabled"
        case pathNotFoundHints = "path_not_found_hints"
        case contextualHints = "contextual_hints"
        case worktreeType = "worktree_type"
        case restoreCode = "restore_code"
        case cancelRewindEnabled = "cancel_rewind_enabled"
        case sessionRecap = "session_recap"
        case askUserQuestionEnabled = "ask_user_question_enabled"
        case webFetchEnabled = "web_fetch_enabled"
        case webFetchProxy = "web_fetch_proxy"
        case webFetchAllowedDomains = "web_fetch_allowed_domains"
        case showResolvedModel = "show_resolved_model"
        case sharingEnabled = "sharing_enabled"
        case voiceModeEnabled = "voice_mode_enabled"
        case zdrAccessEnabled = "zdr_access_enabled"
        case privacyNoticeRollout = "privacy_notice_rollout"
        case privacyBannerReshowDays = "privacy_banner_reshow_days"
        case rememberToolApprovals = "remember_tool_approvals"
        case crashHandlerEnabled = "crash_handler_enabled"
        case showThinkingBlocks = "show_thinking_blocks"
        case groupToolVerbs = "group_tool_verbs"
        case collapsedEditBlocks = "collapsed_edit_blocks"
        case displayRefresh = "display_refresh"
        case autoMode = "auto_mode"
        case permissionMode = "permission_mode"
        case subscriptionTier = "subscription_tier"
        case gateMessage = "gate_message"
        case gateUrl = "gate_url"
        case gateLabel = "gate_label"
        case sessionPickerGrouped = "session_picker_grouped"
        case allowAccess = "allow_access"
        case subscriptionTierDisplay = "subscription_tier_display"
        case onDemandEnabled = "on_demand_enabled"
        case usageBillingRedirectUrl = "usage_billing_redirect_url"
        case suggestionsEnabled = "suggestions_enabled"
        case suggestionsAiEnabled = "suggestions_ai_enabled"
        case autoCompactThresholdPercent = "auto_compact_threshold_percent"
        case subagentsMaxDepth = "subagents_max_depth"
        case systemPromptLabel = "system_prompt_label"
        case compactionWallClockBudgetSecs = "compaction_wall_clock_budget_secs"
        case compactionMode = "compaction_mode"
        case compactionDetail = "compaction_detail"
        case compactionVerbatimInput = "compaction_verbatim_input"
        case compactionToolChoice = "compaction_tool_choice"
        case imagineToolsDisabled = "imagine_tools_disabled"
        case workspaceCommandEnabled = "workspace_command_enabled"
        case jemallocHeapProfileEnabled = "jemalloc_heap_profile_enabled"
        case jemallocHeapProfileThresholdsBytes = "jemalloc_heap_profile_thresholds_bytes"
        case jemallocHeapProfilePollIntervalSecs = "jemalloc_heap_profile_poll_interval_secs"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        leaderMode = try c.decodeIfPresent(Bool.self, forKey: .leaderMode)
        maxUploadFileBytes = try c.decodeIfPresent(UInt64.self, forKey: .maxUploadFileBytes)
        maxUploadUntrackedBytes = try c.decodeIfPresent(UInt64.self, forKey: .maxUploadUntrackedBytes)
        nonGitWorkspaceCapture = try c.decodeIfPresent(Bool.self, forKey: .nonGitWorkspaceCapture)
        loginShellCapture = try c.decodeIfPresent(Bool.self, forKey: .loginShellCapture)
        schedulerBackgroundLoops = try c.decodeIfPresent(Bool.self, forKey: .schedulerBackgroundLoops)
        releaseChannel = try c.decodeIfPresent(String.self, forKey: .releaseChannel)
        locTracking = try c.decodeIfPresent(Bool.self, forKey: .locTracking)
        memoryEnabled = try c.decodeIfPresent(Bool.self, forKey: .memoryEnabled)
        memorySearchMaxResults = try c.decodeIfPresent(UInt32.self, forKey: .memorySearchMaxResults)
        memorySearchMinScore = try c.decodeIfPresent(Float.self, forKey: .memorySearchMinScore)
        memoryInitialInjectionEnabled = try c.decodeIfPresent(Bool.self, forKey: .memoryInitialInjectionEnabled)
        memoryInitialInjectionMinScore = try c.decodeIfPresent(Float.self, forKey: .memoryInitialInjectionMinScore)
        memoryEmbeddingModel = try c.decodeIfPresent(String.self, forKey: .memoryEmbeddingModel)
        memoryEmbeddingDimensions = try c.decodeIfPresent(UInt32.self, forKey: .memoryEmbeddingDimensions)
        pruningEnabled = try c.decodeIfPresent(Bool.self, forKey: .pruningEnabled)
        pruningKeepLastNTurns = try c.decodeIfPresent(UInt32.self, forKey: .pruningKeepLastNTurns)
        pruningSoftTrimThreshold = try c.decodeIfPresent(UInt32.self, forKey: .pruningSoftTrimThreshold)
        flushEnabled = try c.decodeIfPresent(Bool.self, forKey: .flushEnabled)
        flushSoftThresholdTokens = try c.decodeIfPresent(UInt64.self, forKey: .flushSoftThresholdTokens)
        flushIdleTimeoutSecs = try c.decodeIfPresent(UInt64.self, forKey: .flushIdleTimeoutSecs)
        flushSemanticDedupThreshold = try c.decodeIfPresent(Double.self, forKey: .flushSemanticDedupThreshold)
        memoryTemporalDecayEnabled = try c.decodeIfPresent(Bool.self, forKey: .memoryTemporalDecayEnabled)
        memoryTemporalDecayHalfLifeDays = try c.decodeIfPresent(Double.self, forKey: .memoryTemporalDecayHalfLifeDays)
        memoryMmrEnabled = try c.decodeIfPresent(Bool.self, forKey: .memoryMmrEnabled)
        memoryMmrLambda = try c.decodeIfPresent(Double.self, forKey: .memoryMmrLambda)
        memoryWatcherEnabled = try c.decodeIfPresent(Bool.self, forKey: .memoryWatcherEnabled)
        dreamEnabled = try c.decodeIfPresent(Bool.self, forKey: .dreamEnabled)
        dreamMinHours = try c.decodeIfPresent(UInt64.self, forKey: .dreamMinHours)
        dreamMinSessions = try c.decodeIfPresent(UInt64.self, forKey: .dreamMinSessions)
        dreamCheckIntervalSecs = try c.decodeIfPresent(UInt64.self, forKey: .dreamCheckIntervalSecs)
        subscriptionWatchIntervalSecs = try c.decodeIfPresent(UInt64.self, forKey: .subscriptionWatchIntervalSecs)
        writebackEnabled = try c.decodeIfPresent(Bool.self, forKey: .writebackEnabled)
        oauth2Issuer = try c.decodeIfPresent(String.self, forKey: .oauth2Issuer)
        oauth2ClientId = try c.decodeIfPresent(String.self, forKey: .oauth2ClientId)
        grokOauthEnabled = try c.decodeIfPresent(Bool.self, forKey: .grokOauthEnabled)
        lspToolsEnabled = try c.decodeIfPresent(Bool.self, forKey: .lspToolsEnabled)
        folderTrustEnabled = try c.decodeIfPresent(Bool.self, forKey: .folderTrustEnabled)
        writeFileEnabled = try c.decodeIfPresent(Bool.self, forKey: .writeFileEnabled)
        fileToolset = try c.decodeIfPresent(String.self, forKey: .fileToolset)
        inferenceIdleTimeoutSecs = try c.decodeIfPresent(UInt64.self, forKey: .inferenceIdleTimeoutSecs)
        mcpStartupTimeoutSecs = try c.decodeIfPresent(UInt64.self, forKey: .mcpStartupTimeoutSecs)
        maxMcpOutputBytes = try c.decodeIfPresent(UInt64.self, forKey: .maxMcpOutputBytes)
        sessionRegistryEnabled = try c.decodeIfPresent(Bool.self, forKey: .sessionRegistryEnabled)
        doomLoopRecovery = try c.decodeIfPresent(DoomLoopRecoverySettings.self, forKey: .doomLoopRecovery)
        worktreeAutoGc = Self.decodeTolerantWorktreeAutoGc(from: c, forKey: .worktreeAutoGc)
        todoGateEnabled = try c.decodeIfPresent(Bool.self, forKey: .todoGateEnabled)
        todoGateMaxFiresPerPrompt = try c.decodeIfPresent(UInt32.self, forKey: .todoGateMaxFiresPerPrompt)
        autoWakeEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoWakeEnabled)
        cursorSkillsEnabled = try c.decodeIfPresent(Bool.self, forKey: .cursorSkillsEnabled)
        cursorRulesEnabled = try c.decodeIfPresent(Bool.self, forKey: .cursorRulesEnabled)
        cursorAgentsEnabled = try c.decodeIfPresent(Bool.self, forKey: .cursorAgentsEnabled)
        claudeSkillsEnabled = try c.decodeIfPresent(Bool.self, forKey: .claudeSkillsEnabled)
        claudeRulesEnabled = try c.decodeIfPresent(Bool.self, forKey: .claudeRulesEnabled)
        claudeAgentsEnabled = try c.decodeIfPresent(Bool.self, forKey: .claudeAgentsEnabled)
        cursorMcpsEnabled = try c.decodeIfPresent(Bool.self, forKey: .cursorMcpsEnabled)
        cursorHooksEnabled = try c.decodeIfPresent(Bool.self, forKey: .cursorHooksEnabled)
        claudeMcpsEnabled = try c.decodeIfPresent(Bool.self, forKey: .claudeMcpsEnabled)
        claudeHooksEnabled = try c.decodeIfPresent(Bool.self, forKey: .claudeHooksEnabled)
        cursorSessionsEnabled = try c.decodeIfPresent(Bool.self, forKey: .cursorSessionsEnabled)
        claudeSessionsEnabled = try c.decodeIfPresent(Bool.self, forKey: .claudeSessionsEnabled)
        codexSessionsEnabled = try c.decodeIfPresent(Bool.self, forKey: .codexSessionsEnabled)
        goalEnabled = try c.decodeIfPresent(Bool.self, forKey: .goalEnabled)
        goalClassifierEnabled = try c.decodeIfPresent(Bool.self, forKey: .goalClassifierEnabled)
        goalPlannerEnabled = try c.decodeIfPresent(Bool.self, forKey: .goalPlannerEnabled)
        goalSummaryEnabled = try c.decodeIfPresent(Bool.self, forKey: .goalSummaryEnabled)
        goalVerifierCount = try c.decodeIfPresent(UInt32.self, forKey: .goalVerifierCount)
        goalClassifierMaxRuns = try c.decodeIfPresent(UInt32.self, forKey: .goalClassifierMaxRuns)
        goalStrategistEvery = try c.decodeIfPresent(UInt32.self, forKey: .goalStrategistEvery)
        goalPlannerModel = try Self.decodeTolerantGoalRoleModel(from: c, forKey: .goalPlannerModel)
        goalStrategistModel = try Self.decodeTolerantGoalRoleModel(from: c, forKey: .goalStrategistModel)
        goalSkepticModels = try Self.decodeTolerantGoalSkepticModels(from: c, forKey: .goalSkepticModels)
        workflowsEnabled = try c.decodeIfPresent(Bool.self, forKey: .workflowsEnabled)
        managedMcpsEnabled = try c.decodeIfPresent(Bool.self, forKey: .managedMcpsEnabled)
        managedMcpGatewayToolsEnabled = try c.decodeIfPresent(Bool.self, forKey: .managedMcpGatewayToolsEnabled)
        externalOtelDisabled = try c.decodeIfPresent(Bool.self, forKey: .externalOtelDisabled)
        externalOtelContentGatesLocked = try c.decodeIfPresent(Bool.self, forKey: .externalOtelContentGatesLocked)
        managedConfigSignatureVerification = try c.decodeIfPresent(Bool.self, forKey: .managedConfigSignatureVerification)
        telemetryEnabled = try c.decodeIfPresent(Bool.self, forKey: .telemetryEnabled)
        telemetryMode = try c.decodeIfPresent(String.self, forKey: .telemetryMode)
        traceUploadEnabled = try c.decodeIfPresent(Bool.self, forKey: .traceUploadEnabled)
        feedbackEnabled = try c.decodeIfPresent(Bool.self, forKey: .feedbackEnabled)
        twoPassCompactionEnabled = try c.decodeIfPresent(Bool.self, forKey: .twoPassCompactionEnabled)
        tips = try c.decodeIfPresent([String].self, forKey: .tips)
        slashCommandTags = Self.decodeTolerantSlashCommandTags(from: c, forKey: .slashCommandTags)
        nonGitWarning = try c.decodeIfPresent(Bool.self, forKey: .nonGitWarning)
        officialMarketplaceAutoRegister = try c.decodeIfPresent(Bool.self, forKey: .officialMarketplaceAutoRegister)
        pluginCta = try c.decodeIfPresent(Bool.self, forKey: .pluginCta)
        announcements = try Self.decodeTolerantAnnouncements(from: c, forKey: .announcements)
        webSearchModel = try c.decodeIfPresent(String.self, forKey: .webSearchModel)
        sessionSummaryModel = try c.decodeIfPresent(String.self, forKey: .sessionSummaryModel)
        imageDescriptionModel = try c.decodeIfPresent(String.self, forKey: .imageDescriptionModel)
        promptSuggestionModel = try c.decodeIfPresent(String.self, forKey: .promptSuggestionModel)
        defaultModel = try c.decodeIfPresent(String.self, forKey: .defaultModel)
        campaigns = try c.decodeIfPresent([CampaignOverride].self, forKey: .campaigns) ?? []
        autoBackgroundOnTimeout = try c.decodeIfPresent(Bool.self, forKey: .autoBackgroundOnTimeout)
        allowBackgroundOperator = try c.decodeIfPresent(Bool.self, forKey: .allowBackgroundOperator)
        askUserQuestionTimeoutEnabled = try c.decodeIfPresent(Bool.self, forKey: .askUserQuestionTimeoutEnabled)
        askUserQuestionTimeoutSecs = try c.decodeIfPresent(UInt64.self, forKey: .askUserQuestionTimeoutSecs)
        subagentWorktreeSnapshotEnabled = try c.decodeIfPresent(Bool.self, forKey: .subagentWorktreeSnapshotEnabled)
        imageGenEnabled = try c.decodeIfPresent(Bool.self, forKey: .imageGenEnabled)
        imageGenModelOverride = try c.decodeIfPresent(String.self, forKey: .imageGenModelOverride)
        imageEditModelOverride = try c.decodeIfPresent(String.self, forKey: .imageEditModelOverride)
        videoGenEnabled = try c.decodeIfPresent(Bool.self, forKey: .videoGenEnabled)
        imageNormalizeCacheEnabled = try c.decodeIfPresent(Bool.self, forKey: .imageNormalizeCacheEnabled)
        pathNotFoundHints = try c.decodeIfPresent(Bool.self, forKey: .pathNotFoundHints)
        contextualHints = try c.decodeIfPresent(ContextualHintsRemote.self, forKey: .contextualHints)
        worktreeType = try c.decodeIfPresent(String.self, forKey: .worktreeType)
        restoreCode = try c.decodeIfPresent(Bool.self, forKey: .restoreCode)
        cancelRewindEnabled = try c.decodeIfPresent(Bool.self, forKey: .cancelRewindEnabled)
        sessionRecap = try c.decodeIfPresent(Bool.self, forKey: .sessionRecap)
        askUserQuestionEnabled = try c.decodeIfPresent(Bool.self, forKey: .askUserQuestionEnabled)
        webFetchEnabled = try c.decodeIfPresent(Bool.self, forKey: .webFetchEnabled)
        webFetchProxy = try c.decodeIfPresent(String.self, forKey: .webFetchProxy)
        webFetchAllowedDomains = try c.decodeIfPresent([String].self, forKey: .webFetchAllowedDomains)
        showResolvedModel = try c.decodeIfPresent(Bool.self, forKey: .showResolvedModel)
        sharingEnabled = try c.decodeIfPresent(Bool.self, forKey: .sharingEnabled)
        voiceModeEnabled = try c.decodeIfPresent(Bool.self, forKey: .voiceModeEnabled)
        zdrAccessEnabled = try c.decodeIfPresent(Bool.self, forKey: .zdrAccessEnabled)
        privacyNoticeRollout = try c.decodeIfPresent(Bool.self, forKey: .privacyNoticeRollout)
        privacyBannerReshowDays = try c.decodeIfPresent(UInt64.self, forKey: .privacyBannerReshowDays)
        rememberToolApprovals = try c.decodeIfPresent(Bool.self, forKey: .rememberToolApprovals)
        crashHandlerEnabled = try c.decodeIfPresent(Bool.self, forKey: .crashHandlerEnabled)
        showThinkingBlocks = try c.decodeIfPresent(Bool.self, forKey: .showThinkingBlocks)
        groupToolVerbs = try c.decodeIfPresent(Bool.self, forKey: .groupToolVerbs)
        collapsedEditBlocks = try c.decodeIfPresent(Bool.self, forKey: .collapsedEditBlocks)
        displayRefresh = try c.decodeIfPresent(DisplayRefreshSettings.self, forKey: .displayRefresh)
        autoMode = try c.decodeIfPresent(JSONValue.self, forKey: .autoMode)
        permissionMode = try c.decodeIfPresent(String.self, forKey: .permissionMode)
        subscriptionTier = try c.decodeIfPresent(String.self, forKey: .subscriptionTier)
        gateMessage = try c.decodeIfPresent(String.self, forKey: .gateMessage)
        gateUrl = try c.decodeIfPresent(String.self, forKey: .gateUrl)
        gateLabel = try c.decodeIfPresent(String.self, forKey: .gateLabel)
        sessionPickerGrouped = try c.decodeIfPresent(Bool.self, forKey: .sessionPickerGrouped)
        allowAccess = try c.decodeIfPresent(Bool.self, forKey: .allowAccess)
        subscriptionTierDisplay = try c.decodeIfPresent(String.self, forKey: .subscriptionTierDisplay)
        onDemandEnabled = try c.decodeIfPresent(Bool.self, forKey: .onDemandEnabled)
        usageBillingRedirectUrl = try c.decodeIfPresent(String.self, forKey: .usageBillingRedirectUrl)
        suggestionsEnabled = try c.decodeIfPresent(Bool.self, forKey: .suggestionsEnabled)
        suggestionsAiEnabled = try c.decodeIfPresent(Bool.self, forKey: .suggestionsAiEnabled)
        autoCompactThresholdPercent = try c.decodeIfPresent(UInt8.self, forKey: .autoCompactThresholdPercent)
        subagentsMaxDepth = try c.decodeIfPresent(UInt32.self, forKey: .subagentsMaxDepth)
        systemPromptLabel = try c.decodeIfPresent(String.self, forKey: .systemPromptLabel)
        compactionWallClockBudgetSecs = try c.decodeIfPresent(UInt64.self, forKey: .compactionWallClockBudgetSecs)
        compactionMode = try c.decodeIfPresent(String.self, forKey: .compactionMode)
        compactionDetail = try c.decodeIfPresent(String.self, forKey: .compactionDetail)
        compactionVerbatimInput = try c.decodeIfPresent(Bool.self, forKey: .compactionVerbatimInput)
        compactionToolChoice = try c.decodeIfPresent(String.self, forKey: .compactionToolChoice)
        imagineToolsDisabled = try c.decodeIfPresent([String].self, forKey: .imagineToolsDisabled)
        workspaceCommandEnabled = try c.decodeIfPresent(Bool.self, forKey: .workspaceCommandEnabled)
        jemallocHeapProfileEnabled = try c.decodeIfPresent(Bool.self, forKey: .jemallocHeapProfileEnabled)
        jemallocHeapProfileThresholdsBytes = try c.decodeIfPresent([UInt64].self, forKey: .jemallocHeapProfileThresholdsBytes)
        jemallocHeapProfilePollIntervalSecs = try c.decodeIfPresent(UInt64.self, forKey: .jemallocHeapProfilePollIntervalSecs)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(leaderMode, forKey: .leaderMode)
        try c.encodeIfPresent(maxUploadFileBytes, forKey: .maxUploadFileBytes)
        try c.encodeIfPresent(maxUploadUntrackedBytes, forKey: .maxUploadUntrackedBytes)
        try c.encodeIfPresent(nonGitWorkspaceCapture, forKey: .nonGitWorkspaceCapture)
        try c.encodeIfPresent(loginShellCapture, forKey: .loginShellCapture)
        try c.encodeIfPresent(schedulerBackgroundLoops, forKey: .schedulerBackgroundLoops)
        try c.encodeIfPresent(releaseChannel, forKey: .releaseChannel)
        try c.encodeIfPresent(locTracking, forKey: .locTracking)
        try c.encodeIfPresent(memoryEnabled, forKey: .memoryEnabled)
        try c.encodeIfPresent(memorySearchMaxResults, forKey: .memorySearchMaxResults)
        try c.encodeIfPresent(memorySearchMinScore, forKey: .memorySearchMinScore)
        try c.encodeIfPresent(memoryInitialInjectionEnabled, forKey: .memoryInitialInjectionEnabled)
        try c.encodeIfPresent(memoryInitialInjectionMinScore, forKey: .memoryInitialInjectionMinScore)
        try c.encodeIfPresent(memoryEmbeddingModel, forKey: .memoryEmbeddingModel)
        try c.encodeIfPresent(memoryEmbeddingDimensions, forKey: .memoryEmbeddingDimensions)
        try c.encodeIfPresent(pruningEnabled, forKey: .pruningEnabled)
        try c.encodeIfPresent(pruningKeepLastNTurns, forKey: .pruningKeepLastNTurns)
        try c.encodeIfPresent(pruningSoftTrimThreshold, forKey: .pruningSoftTrimThreshold)
        try c.encodeIfPresent(flushEnabled, forKey: .flushEnabled)
        try c.encodeIfPresent(flushSoftThresholdTokens, forKey: .flushSoftThresholdTokens)
        try c.encodeIfPresent(flushIdleTimeoutSecs, forKey: .flushIdleTimeoutSecs)
        try c.encodeIfPresent(flushSemanticDedupThreshold, forKey: .flushSemanticDedupThreshold)
        try c.encodeIfPresent(memoryTemporalDecayEnabled, forKey: .memoryTemporalDecayEnabled)
        try c.encodeIfPresent(memoryTemporalDecayHalfLifeDays, forKey: .memoryTemporalDecayHalfLifeDays)
        try c.encodeIfPresent(memoryMmrEnabled, forKey: .memoryMmrEnabled)
        try c.encodeIfPresent(memoryMmrLambda, forKey: .memoryMmrLambda)
        try c.encodeIfPresent(memoryWatcherEnabled, forKey: .memoryWatcherEnabled)
        try c.encodeIfPresent(dreamEnabled, forKey: .dreamEnabled)
        try c.encodeIfPresent(dreamMinHours, forKey: .dreamMinHours)
        try c.encodeIfPresent(dreamMinSessions, forKey: .dreamMinSessions)
        try c.encodeIfPresent(dreamCheckIntervalSecs, forKey: .dreamCheckIntervalSecs)
        try c.encodeIfPresent(subscriptionWatchIntervalSecs, forKey: .subscriptionWatchIntervalSecs)
        try c.encodeIfPresent(writebackEnabled, forKey: .writebackEnabled)
        try c.encodeIfPresent(oauth2Issuer, forKey: .oauth2Issuer)
        try c.encodeIfPresent(oauth2ClientId, forKey: .oauth2ClientId)
        try c.encodeIfPresent(grokOauthEnabled, forKey: .grokOauthEnabled)
        try c.encodeIfPresent(lspToolsEnabled, forKey: .lspToolsEnabled)
        try c.encodeIfPresent(folderTrustEnabled, forKey: .folderTrustEnabled)
        try c.encodeIfPresent(writeFileEnabled, forKey: .writeFileEnabled)
        try c.encodeIfPresent(fileToolset, forKey: .fileToolset)
        try c.encodeIfPresent(inferenceIdleTimeoutSecs, forKey: .inferenceIdleTimeoutSecs)
        try c.encodeIfPresent(mcpStartupTimeoutSecs, forKey: .mcpStartupTimeoutSecs)
        try c.encodeIfPresent(maxMcpOutputBytes, forKey: .maxMcpOutputBytes)
        try c.encodeIfPresent(sessionRegistryEnabled, forKey: .sessionRegistryEnabled)
        try c.encodeIfPresent(doomLoopRecovery, forKey: .doomLoopRecovery)
        try c.encodeIfPresent(worktreeAutoGc, forKey: .worktreeAutoGc)
        try c.encodeIfPresent(todoGateEnabled, forKey: .todoGateEnabled)
        try c.encodeIfPresent(todoGateMaxFiresPerPrompt, forKey: .todoGateMaxFiresPerPrompt)
        try c.encodeIfPresent(autoWakeEnabled, forKey: .autoWakeEnabled)
        try c.encodeIfPresent(cursorSkillsEnabled, forKey: .cursorSkillsEnabled)
        try c.encodeIfPresent(cursorRulesEnabled, forKey: .cursorRulesEnabled)
        try c.encodeIfPresent(cursorAgentsEnabled, forKey: .cursorAgentsEnabled)
        try c.encodeIfPresent(claudeSkillsEnabled, forKey: .claudeSkillsEnabled)
        try c.encodeIfPresent(claudeRulesEnabled, forKey: .claudeRulesEnabled)
        try c.encodeIfPresent(claudeAgentsEnabled, forKey: .claudeAgentsEnabled)
        try c.encodeIfPresent(cursorMcpsEnabled, forKey: .cursorMcpsEnabled)
        try c.encodeIfPresent(cursorHooksEnabled, forKey: .cursorHooksEnabled)
        try c.encodeIfPresent(claudeMcpsEnabled, forKey: .claudeMcpsEnabled)
        try c.encodeIfPresent(claudeHooksEnabled, forKey: .claudeHooksEnabled)
        try c.encodeIfPresent(cursorSessionsEnabled, forKey: .cursorSessionsEnabled)
        try c.encodeIfPresent(claudeSessionsEnabled, forKey: .claudeSessionsEnabled)
        try c.encodeIfPresent(codexSessionsEnabled, forKey: .codexSessionsEnabled)
        try c.encodeIfPresent(goalEnabled, forKey: .goalEnabled)
        try c.encodeIfPresent(goalClassifierEnabled, forKey: .goalClassifierEnabled)
        try c.encodeIfPresent(goalPlannerEnabled, forKey: .goalPlannerEnabled)
        try c.encodeIfPresent(goalSummaryEnabled, forKey: .goalSummaryEnabled)
        try c.encodeIfPresent(goalVerifierCount, forKey: .goalVerifierCount)
        try c.encodeIfPresent(goalClassifierMaxRuns, forKey: .goalClassifierMaxRuns)
        try c.encodeIfPresent(goalStrategistEvery, forKey: .goalStrategistEvery)
        try c.encodeIfPresent(goalPlannerModel, forKey: .goalPlannerModel)
        try c.encodeIfPresent(goalStrategistModel, forKey: .goalStrategistModel)
        if !goalSkepticModels.isEmpty { try c.encode(goalSkepticModels, forKey: .goalSkepticModels) }
        try c.encodeIfPresent(workflowsEnabled, forKey: .workflowsEnabled)
        try c.encodeIfPresent(managedMcpsEnabled, forKey: .managedMcpsEnabled)
        try c.encodeIfPresent(managedMcpGatewayToolsEnabled, forKey: .managedMcpGatewayToolsEnabled)
        try c.encodeIfPresent(externalOtelDisabled, forKey: .externalOtelDisabled)
        try c.encodeIfPresent(externalOtelContentGatesLocked, forKey: .externalOtelContentGatesLocked)
        try c.encodeIfPresent(managedConfigSignatureVerification, forKey: .managedConfigSignatureVerification)
        try c.encodeIfPresent(telemetryEnabled, forKey: .telemetryEnabled)
        try c.encodeIfPresent(telemetryMode, forKey: .telemetryMode)
        try c.encodeIfPresent(traceUploadEnabled, forKey: .traceUploadEnabled)
        try c.encodeIfPresent(feedbackEnabled, forKey: .feedbackEnabled)
        try c.encodeIfPresent(twoPassCompactionEnabled, forKey: .twoPassCompactionEnabled)
        try c.encodeIfPresent(tips, forKey: .tips)
        try c.encodeIfPresent(slashCommandTags, forKey: .slashCommandTags)
        try c.encodeIfPresent(nonGitWarning, forKey: .nonGitWarning)
        try c.encodeIfPresent(officialMarketplaceAutoRegister, forKey: .officialMarketplaceAutoRegister)
        try c.encodeIfPresent(pluginCta, forKey: .pluginCta)
        try c.encodeIfPresent(announcements, forKey: .announcements)
        try c.encodeIfPresent(webSearchModel, forKey: .webSearchModel)
        try c.encodeIfPresent(sessionSummaryModel, forKey: .sessionSummaryModel)
        try c.encodeIfPresent(imageDescriptionModel, forKey: .imageDescriptionModel)
        try c.encodeIfPresent(promptSuggestionModel, forKey: .promptSuggestionModel)
        try c.encodeIfPresent(defaultModel, forKey: .defaultModel)
        try c.encode(campaigns, forKey: .campaigns)
        try c.encodeIfPresent(autoBackgroundOnTimeout, forKey: .autoBackgroundOnTimeout)
        try c.encodeIfPresent(allowBackgroundOperator, forKey: .allowBackgroundOperator)
        try c.encodeIfPresent(askUserQuestionTimeoutEnabled, forKey: .askUserQuestionTimeoutEnabled)
        try c.encodeIfPresent(askUserQuestionTimeoutSecs, forKey: .askUserQuestionTimeoutSecs)
        try c.encodeIfPresent(subagentWorktreeSnapshotEnabled, forKey: .subagentWorktreeSnapshotEnabled)
        try c.encodeIfPresent(imageGenEnabled, forKey: .imageGenEnabled)
        try c.encodeIfPresent(imageGenModelOverride, forKey: .imageGenModelOverride)
        try c.encodeIfPresent(imageEditModelOverride, forKey: .imageEditModelOverride)
        try c.encodeIfPresent(videoGenEnabled, forKey: .videoGenEnabled)
        try c.encodeIfPresent(imageNormalizeCacheEnabled, forKey: .imageNormalizeCacheEnabled)
        try c.encodeIfPresent(pathNotFoundHints, forKey: .pathNotFoundHints)
        try c.encodeIfPresent(contextualHints, forKey: .contextualHints)
        try c.encodeIfPresent(worktreeType, forKey: .worktreeType)
        try c.encodeIfPresent(restoreCode, forKey: .restoreCode)
        try c.encodeIfPresent(cancelRewindEnabled, forKey: .cancelRewindEnabled)
        try c.encodeIfPresent(sessionRecap, forKey: .sessionRecap)
        try c.encodeIfPresent(askUserQuestionEnabled, forKey: .askUserQuestionEnabled)
        try c.encodeIfPresent(webFetchEnabled, forKey: .webFetchEnabled)
        try c.encodeIfPresent(webFetchProxy, forKey: .webFetchProxy)
        try c.encodeIfPresent(webFetchAllowedDomains, forKey: .webFetchAllowedDomains)
        try c.encodeIfPresent(showResolvedModel, forKey: .showResolvedModel)
        try c.encodeIfPresent(sharingEnabled, forKey: .sharingEnabled)
        try c.encodeIfPresent(voiceModeEnabled, forKey: .voiceModeEnabled)
        try c.encodeIfPresent(zdrAccessEnabled, forKey: .zdrAccessEnabled)
        try c.encodeIfPresent(privacyNoticeRollout, forKey: .privacyNoticeRollout)
        try c.encodeIfPresent(privacyBannerReshowDays, forKey: .privacyBannerReshowDays)
        try c.encodeIfPresent(rememberToolApprovals, forKey: .rememberToolApprovals)
        try c.encodeIfPresent(crashHandlerEnabled, forKey: .crashHandlerEnabled)
        try c.encodeIfPresent(showThinkingBlocks, forKey: .showThinkingBlocks)
        try c.encodeIfPresent(groupToolVerbs, forKey: .groupToolVerbs)
        try c.encodeIfPresent(collapsedEditBlocks, forKey: .collapsedEditBlocks)
        try c.encodeIfPresent(displayRefresh, forKey: .displayRefresh)
        try c.encodeIfPresent(autoMode, forKey: .autoMode)
        try c.encodeIfPresent(permissionMode, forKey: .permissionMode)
        try c.encodeIfPresent(subscriptionTier, forKey: .subscriptionTier)
        try c.encodeIfPresent(gateMessage, forKey: .gateMessage)
        try c.encodeIfPresent(gateUrl, forKey: .gateUrl)
        try c.encodeIfPresent(gateLabel, forKey: .gateLabel)
        try c.encodeIfPresent(sessionPickerGrouped, forKey: .sessionPickerGrouped)
        try c.encodeIfPresent(allowAccess, forKey: .allowAccess)
        try c.encodeIfPresent(subscriptionTierDisplay, forKey: .subscriptionTierDisplay)
        try c.encodeIfPresent(onDemandEnabled, forKey: .onDemandEnabled)
        try c.encodeIfPresent(usageBillingRedirectUrl, forKey: .usageBillingRedirectUrl)
        try c.encodeIfPresent(suggestionsEnabled, forKey: .suggestionsEnabled)
        try c.encodeIfPresent(suggestionsAiEnabled, forKey: .suggestionsAiEnabled)
        try c.encodeIfPresent(autoCompactThresholdPercent, forKey: .autoCompactThresholdPercent)
        try c.encodeIfPresent(subagentsMaxDepth, forKey: .subagentsMaxDepth)
        try c.encodeIfPresent(systemPromptLabel, forKey: .systemPromptLabel)
        try c.encodeIfPresent(compactionWallClockBudgetSecs, forKey: .compactionWallClockBudgetSecs)
        try c.encodeIfPresent(compactionMode, forKey: .compactionMode)
        try c.encodeIfPresent(compactionDetail, forKey: .compactionDetail)
        try c.encodeIfPresent(compactionVerbatimInput, forKey: .compactionVerbatimInput)
        try c.encodeIfPresent(compactionToolChoice, forKey: .compactionToolChoice)
        try c.encodeIfPresent(imagineToolsDisabled, forKey: .imagineToolsDisabled)
        try c.encodeIfPresent(workspaceCommandEnabled, forKey: .workspaceCommandEnabled)
        try c.encodeIfPresent(jemallocHeapProfileEnabled, forKey: .jemallocHeapProfileEnabled)
        try c.encodeIfPresent(jemallocHeapProfileThresholdsBytes, forKey: .jemallocHeapProfileThresholdsBytes)
        try c.encodeIfPresent(jemallocHeapProfilePollIntervalSecs, forKey: .jemallocHeapProfilePollIntervalSecs)
    }

    // MARK: Tolerant decoders

    /// Tolerant `Option<[RemoteAnnouncement]>`: parse as `[JSONValue]`, try
    /// each as `RemoteAnnouncement`, drop failures (one bad item must not
    /// poison the whole `RemoteSettings`). Mirrors Rust
    /// `deserialize_tolerant_announcements`.
    private static func decodeTolerantAnnouncements(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> [RemoteAnnouncement]? {
        guard container.contains(key) else { return nil }
        // Decode as JSONValue to be tolerant of null/non-array.
        let raw = try? container.decode(JSONValue.self, forKey: key)
        guard let raw = raw else { return nil }
        guard case .array(let arr) = raw else { return nil }
        var out: [RemoteAnnouncement] = []
        out.reserveCapacity(arr.count)
        for item in arr {
            if let a = try? item.decode(RemoteAnnouncement.self) {
                out.append(a)
            }
            // else: drop malformed item (Rust `tracing::warn!`).
        }
        return out
    }

    /// Tolerant `Option<GoalRoleModel>`: a present-but-malformed value (or
    /// explicit `null`) maps to `nil`, never a parse error. Mirrors Rust
    /// `deserialize_tolerant_goal_role_model`.
    private static func decodeTolerantGoalRoleModel(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> GoalRoleModel? {
        guard container.contains(key) else { return nil }
        let raw = try? container.decode(JSONValue.self, forKey: key)
        guard let raw = raw, !raw.isNull else { return nil }
        return try? raw.decode(GoalRoleModel.self)
    }

    /// Tolerant nested `worktree_auto_gc`: present-but-malformed → `nil`
    /// (Rust warns and falls through to TOML/defaults) so one bad nested
    /// value cannot fail the whole `RemoteSettings` parse.
    /// `deserialize_tolerant_worktree_auto_gc`, lib.rs:396.
    private static func decodeTolerantWorktreeAutoGc(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> WorktreeAutoGcSettings? {
        guard container.contains(key),
              let raw = try? container.decode(JSONValue.self, forKey: key),
              !raw.isNull
        else { return nil }
        return try? raw.decode(WorktreeAutoGcSettings.self)
    }

    /// Tolerant nested `slash_command_tags`: present-but-malformed → `nil`,
    /// falling through to local config / none.
    /// `deserialize_tolerant_slash_command_tags`, lib.rs:419.
    private static func decodeTolerantSlashCommandTags(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> [String: String]? {
        guard container.contains(key),
              let raw = try? container.decode(JSONValue.self, forKey: key),
              !raw.isNull
        else { return nil }
        return try? raw.decode([String: String].self)
    }

    /// Tolerant `[GoalRoleModel]`: a non-array value yields `[]`; within an
    /// array each malformed entry is dropped (order preserved). Mirrors Rust
    /// `deserialize_tolerant_goal_skeptic_models`.
    private static func decodeTolerantGoalSkepticModels(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> [GoalRoleModel] {
        guard container.contains(key) else { return [] }
        let raw = try? container.decode(JSONValue.self, forKey: key)
        guard let raw = raw, case .array(let arr) = raw else { return [] }
        var out: [GoalRoleModel] = []
        out.reserveCapacity(arr.count)
        for item in arr {
            if let m = try? item.decode(GoalRoleModel.self) { out.append(m) }
        }
        return out
    }
}
