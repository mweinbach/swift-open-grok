// UIConfig.swift
//
// User-selected tool presentation and UI configuration. Ported from
// xai-grok-shared/src/ui_config.rs.
//
// The Rust `UiConfig` depends on `DisplayRefreshSettings` from
// `xai-grok-config-types` (W1-S5 / OpenGrokConfigTypes). Since W0-S4 has no
// dependencies, a self-contained `DisplayRefreshSettings` is defined locally
// here so `UiConfig` is complete and testable. W1-S5 may consolidate this
// into `OpenGrokConfigTypes` or re-export it; the wire form is stable.
//
// Key behavior preserved from Rust:
//   * `ToolModePreference` deserializes legacy booleans: `false` → `.direct`,
//     `true` → `.codeMode`, and canonical strings `"direct"`, `"code_mode"`,
//     `"code_mode_only"`. Unknown strings are rejected (not silently
//     downgraded).
//   * `keep_text_selection` deserializes legacy bool (`true` → `"hold"`,
//     `false` → `"flash"`) alongside canonical strings.
//   * `DisplayRefreshSettings` is field-wise tolerant (wrong types → `nil`)
//     and retains unknown keys in `extra`.
//   * `ContextualHints.isDefault()` lets the section stay absent from config
//     until the user toggles a tip.
//   * `SHOW_TIMELINE_DEFAULT` and `PAGE_FLIP_ON_SEND_DEFAULT` are the single
//     sources of truth for those defaults.

import Foundation

// MARK: - ToolModePreference

/// User-selected tool presentation for Responses-backed sessions.
///
/// The custom deserializer preserves compatibility with the original boolean
/// setting: `false` meant direct tools and `true` meant mixed Code Mode.
public enum ToolModePreference: String, Sendable, Codable, Equatable, Defaultable {
    case direct
    case codeMode = "code_mode"
    case codeModeOnly = "code_mode_only"

    public static let defaultValue = ToolModePreference.direct

    /// The canonical string representation.
    public var canonical: String { rawValue }

    /// Parse a canonical string, returning `nil` for unknown values.
    public static func fromCanonical(_ value: String) -> ToolModePreference? {
        switch value {
        case "direct": return .direct
        case "code_mode": return .codeMode
        case "code_mode_only": return .codeModeOnly
        default: return nil
        }
    }

    // MARK: Codable — legacy bool migration + canonical string

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Try bool first (legacy form).
        if let bool = try? container.decode(Bool.self) {
            self = bool ? .codeMode : .direct
            return
        }
        // Try string (canonical form).
        let str = try container.decode(String.self)
        guard let mode = ToolModePreference.fromCanonical(str) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unknown variant: \(str) (expected: direct, code_mode, code_mode_only)"
            )
        }
        self = mode
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A type with a default value, used for serde `#[default]` compatibility.
public protocol Defaultable {
    static var defaultValue: Self { get }
}

// MARK: - ContextualHints

/// User-config opt-outs for the per-tip contextual hints.
public struct ContextualHints: Hashable, Sendable, Codable, Equatable {
    public var undo: Bool?
    public var planMode: Bool?
    public var imageInput: Bool?
    public var sendNow: Bool?
    public var smallScreen: Bool?
    public var wordSelect: Bool?
    public var sshWrap: Bool?

    public init() {
        self.undo = nil
        self.planMode = nil
        self.imageInput = nil
        self.sendNow = nil
        self.smallScreen = nil
        self.wordSelect = nil
        self.sshWrap = nil
    }

    public init(
        undo: Bool?, planMode: Bool?, imageInput: Bool?,
        sendNow: Bool?, smallScreen: Bool?, wordSelect: Bool?, sshWrap: Bool?
    ) {
        self.undo = undo
        self.planMode = planMode
        self.imageInput = imageInput
        self.sendNow = sendNow
        self.smallScreen = smallScreen
        self.wordSelect = wordSelect
        self.sshWrap = sshWrap
    }

    /// `true` when no tip has a user-explicit value (all inherit).
    public var isDefault: Bool {
        undo == nil && planMode == nil && imageInput == nil
            && sendNow == nil && smallScreen == nil && wordSelect == nil
            && sshWrap == nil
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
        let container = try decoder.container(keyedBy: CodingKeys.self)
        undo = try container.decodeIfPresent(Bool.self, forKey: .undo)
        planMode = try container.decodeIfPresent(Bool.self, forKey: .planMode)
        imageInput = try container.decodeIfPresent(Bool.self, forKey: .imageInput)
        sendNow = try container.decodeIfPresent(Bool.self, forKey: .sendNow)
        smallScreen = try container.decodeIfPresent(Bool.self, forKey: .smallScreen)
        wordSelect = try container.decodeIfPresent(Bool.self, forKey: .wordSelect)
        sshWrap = try container.decodeIfPresent(Bool.self, forKey: .sshWrap)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(undo, forKey: .undo)
        try container.encodeIfPresent(planMode, forKey: .planMode)
        try container.encodeIfPresent(imageInput, forKey: .imageInput)
        try container.encodeIfPresent(sendNow, forKey: .sendNow)
        try container.encodeIfPresent(smallScreen, forKey: .smallScreen)
        try container.encodeIfPresent(wordSelect, forKey: .wordSelect)
        try container.encodeIfPresent(sshWrap, forKey: .sshWrap)
    }
}

// MARK: - DisplayRefreshSettings (local; W1-S5 may consolidate)

/// Display-refresh probe + auto-cadence settings.
///
/// Field-wise tolerant: wrong types decode as `nil`; unknown keys are
/// retained in `extra` so config rewrite cannot drop future knobs.
///
/// **Note:** This is defined locally in `OpenGrokShared` because `UiConfig`
/// references it and W0-S4 has no dependencies. W1-S5 (`OpenGrokConfigTypes`)
/// should either re-export this type or provide a compatible replacement;
/// the wire form (snake_case keys, tolerant parsing, `extra` retention) is
/// stable and matches the Rust contract.
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
        let container = try decoder.container(keyedBy: CodingKeys.self)
        probeEnabled = try Self.decodeTolerantBool(from: container, forKey: .probeEnabled)
        autoCadenceEnabled = try Self.decodeTolerantBool(from: container, forKey: .autoCadenceEnabled)
        floorMs = try Self.decodeTolerantU32(from: container, forKey: .floorMs)
        ceilingMs = try Self.decodeTolerantU32(from: container, forKey: .ceilingMs)
        minHz = try Self.decodeTolerantU32(from: container, forKey: .minHz)
        maxHz = try Self.decodeTolerantU32(from: container, forKey: .maxHz)
        // Retain unknown keys.
        let knownKeys: Set<String> = [
            CodingKeys.probeEnabled.stringValue,
            CodingKeys.autoCadenceEnabled.stringValue,
            CodingKeys.floorMs.stringValue,
            CodingKeys.ceilingMs.stringValue,
            CodingKeys.minHz.stringValue,
            CodingKeys.maxHz.stringValue,
        ]
        extra = try UnknownFields.decode(from: decoder, knownKeyStrings: knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(probeEnabled, forKey: .probeEnabled)
        try container.encodeIfPresent(autoCadenceEnabled, forKey: .autoCadenceEnabled)
        try container.encodeIfPresent(floorMs, forKey: .floorMs)
        try container.encodeIfPresent(ceilingMs, forKey: .ceilingMs)
        try container.encodeIfPresent(minHz, forKey: .minHz)
        try container.encodeIfPresent(maxHz, forKey: .maxHz)
        // Encode unknown fields.
        if !extra.isEmpty {
            var anyContainer = encoder.container(keyedBy: AnyCodingKey.self)
            try UnknownFields.encode(extra, into: &anyContainer)
        }
    }

    // MARK: Tolerant decoders

    /// Decode a `Bool?` tolerantly: wrong types → `nil` (not an error).
    private static func decodeTolerantBool(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> Bool? {
        guard container.contains(key) else { return nil }
        // Try Bool first.
        if let bool = try? container.decode(Bool.self, forKey: key) {
            return bool
        }
        // Wrong type → nil (tolerant).
        return nil
    }

    /// Decode a `UInt32?` tolerantly: wrong types → `nil` (not an error).
    private static func decodeTolerantU32(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> UInt32? {
        guard container.contains(key) else { return nil }
        if let int = try? container.decode(Int.self, forKey: key), int >= 0 {
            return UInt32(exactly: int)
        }
        if let double = try? container.decode(Double.self, forKey: key), double >= 0 {
            return UInt32(exactly: double)
        }
        return nil
    }
}

// MARK: - UiConfig

/// User-interface configuration. Ported from `xai_grok_shared::ui_config::UiConfig`.
///
/// Many fields are `Optional` to distinguish "unset" (inherit remote/default)
/// from "explicitly set to `false`". Fields with `#[serde(skip_serializing_if)]`
/// are omitted from the wire when `nil`.
public struct UiConfig: Hashable, Sendable, Codable, Equatable {
    /// Default max thoughts width.
    private static let defaultMaxThoughtsWidth: UInt16 = 120

    public var maxThoughtsWidth: UInt16
    public var theme: String?
    public var forkSecondaryModel: String
    public var yolo: Bool
    public var uiTheme: String?
    public var compactMode: Bool
    public var simpleMode: Bool?
    public var swarmMode: Bool?
    public var permissionMode: String?
    public var approvalMode: String?
    public var defaultSelectedPermission: String?
    public var showTimestamps: Bool?
    public var showTimeline: Bool?
    public var pageFlipOnSend: Bool?
    public var autoDarkTheme: String?
    public var autoLightTheme: String?
    public var scrollSpeed: UInt8?
    public var scrollMode: String?
    public var invertScroll: Bool?
    public var scrollLines: UInt8?
    public var vimMode: Bool?
    public var renderMermaid: String?
    public var hunkTrackerMode: String?
    public var voiceCaptureMode: String?
    public var voiceSttLanguage: String?
    public var mouseReportingToggle: Bool?
    public var cancelSubagentsOnTurnCancel: String?
    public var rememberToolApprovals: Bool?
    public var codeMode: ToolModePreference?
    public var keepTextSelection: String?
    public var selectionHighlightDurationMs: UInt64?
    public var showThinkingBlocks: Bool?
    public var groupToolVerbs: Bool?
    public var collapsedEditBlocks: Bool?
    public var promptSuggestions: Bool?
    public var cursorBlink: Bool?
    public var screenMode: String?
    public var doubleClickAction: String?
    public var contextualHints: ContextualHints
    public var displayRefresh: DisplayRefreshSettings

    public init() {
        self.maxThoughtsWidth = Self.defaultMaxThoughtsWidth
        self.theme = nil
        self.forkSecondaryModel = "grok-3" // matches xai_grok_models::default_model()
        self.yolo = false
        self.uiTheme = nil
        self.compactMode = false
        self.simpleMode = nil
        self.swarmMode = nil
        self.permissionMode = nil
        self.approvalMode = nil
        self.defaultSelectedPermission = nil
        self.showTimestamps = nil
        self.showTimeline = nil
        self.pageFlipOnSend = nil
        self.autoDarkTheme = nil
        self.autoLightTheme = nil
        self.scrollSpeed = nil
        self.scrollMode = nil
        self.invertScroll = nil
        self.scrollLines = nil
        self.vimMode = nil
        self.renderMermaid = nil
        self.hunkTrackerMode = nil
        self.voiceCaptureMode = nil
        self.voiceSttLanguage = nil
        self.mouseReportingToggle = nil
        self.cancelSubagentsOnTurnCancel = nil
        self.rememberToolApprovals = nil
        self.codeMode = nil
        self.keepTextSelection = nil
        self.selectionHighlightDurationMs = nil
        self.showThinkingBlocks = nil
        self.groupToolVerbs = nil
        self.collapsedEditBlocks = nil
        self.promptSuggestions = nil
        self.cursorBlink = nil
        self.screenMode = nil
        self.doubleClickAction = nil
        self.contextualHints = ContextualHints()
        self.displayRefresh = DisplayRefreshSettings()
    }

    // MARK: Resolved defaults

    /// The single source of truth for the timeline-sidebar default (opt-in).
    public static let showTimelineDefault = false

    /// Resolved timeline-sidebar setting.
    public func showTimelineEnabled() -> Bool {
        showTimeline ?? Self.showTimelineDefault
    }

    /// Default for `pageFlipOnSend` when unset.
    public static let pageFlipOnSendDefault = true

    /// Resolved page-flip-on-send setting.
    public func pageFlipOnSendEnabled() -> Bool {
        pageFlipOnSend ?? Self.pageFlipOnSendDefault
    }

    /// `true` when the highlight should not timer-dismiss (`hold` / `word_select`,
    /// or legacy duration 0).
    public func keepTextSelectionEnabled() -> Bool {
        if let s = keepTextSelection {
            return s == "hold" || s == "word_select"
        }
        return selectionHighlightDurationMs == 0
    }

    // MARK: CodingKeys

    private enum CodingKeys: String, CodingKey {
        case maxThoughtsWidth = "max_thoughts_width"
        case theme
        case forkSecondaryModel = "fork_secondary_model"
        case yolo
        case uiTheme = "ui_theme"
        case compactMode = "compact_mode"
        case simpleMode = "simple_mode"
        case swarmMode = "swarm_mode"
        case permissionMode = "permission_mode"
        case approvalMode = "approval_mode"
        case defaultSelectedPermission = "default_selected_permission"
        case showTimestamps = "show_timestamps"
        case showTimeline = "show_timeline"
        case pageFlipOnSend = "page_flip_on_send"
        case autoDarkTheme = "auto_dark_theme"
        case autoLightTheme = "auto_light_theme"
        case scrollSpeed = "scroll_speed"
        case scrollMode = "scroll_mode"
        case invertScroll = "invert_scroll"
        case scrollLines = "scroll_lines"
        case vimMode = "vim_mode"
        case renderMermaid = "render_mermaid"
        case hunkTrackerMode = "hunk_tracker_mode"
        case voiceCaptureMode = "voice_capture_mode"
        case voiceSttLanguage = "voice_stt_language"
        case mouseReportingToggle = "mouse_reporting_toggle"
        case cancelSubagentsOnTurnCancel = "cancel_subagents_on_turn_cancel"
        case rememberToolApprovals = "remember_tool_approvals"
        case codeMode = "code_mode"
        case keepTextSelection = "keep_text_selection"
        case selectionHighlightDurationMs = "selection_highlight_duration_ms"
        case showThinkingBlocks = "show_thinking_blocks"
        case groupToolVerbs = "group_tool_verbs"
        case collapsedEditBlocks = "collapsed_edit_blocks"
        case promptSuggestions = "prompt_suggestions"
        case cursorBlink = "cursor_blink"
        case screenMode = "screen_mode"
        case doubleClickAction = "double_click_action"
        case contextualHints = "contextual_hints"
        case displayRefresh = "display_refresh"
    }

    // MARK: Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        maxThoughtsWidth = try container.decodeIfPresent(UInt16.self, forKey: .maxThoughtsWidth)
            ?? Self.defaultMaxThoughtsWidth
        theme = try container.decodeIfPresent(String.self, forKey: .theme)
        forkSecondaryModel = try container.decodeIfPresent(String.self, forKey: .forkSecondaryModel)
            ?? "grok-3"
        yolo = try container.decodeIfPresent(Bool.self, forKey: .yolo) ?? false
        uiTheme = try container.decodeIfPresent(String.self, forKey: .uiTheme)
        compactMode = try container.decodeIfPresent(Bool.self, forKey: .compactMode) ?? false
        simpleMode = try container.decodeIfPresent(Bool.self, forKey: .simpleMode)
        swarmMode = try container.decodeIfPresent(Bool.self, forKey: .swarmMode)
        permissionMode = try container.decodeIfPresent(String.self, forKey: .permissionMode)
        approvalMode = try container.decodeIfPresent(String.self, forKey: .approvalMode)
        defaultSelectedPermission = try container.decodeIfPresent(String.self, forKey: .defaultSelectedPermission)
        showTimestamps = try container.decodeIfPresent(Bool.self, forKey: .showTimestamps)
        showTimeline = try container.decodeIfPresent(Bool.self, forKey: .showTimeline)
        pageFlipOnSend = try container.decodeIfPresent(Bool.self, forKey: .pageFlipOnSend)
        autoDarkTheme = try container.decodeIfPresent(String.self, forKey: .autoDarkTheme)
        autoLightTheme = try container.decodeIfPresent(String.self, forKey: .autoLightTheme)
        scrollSpeed = try container.decodeIfPresent(UInt8.self, forKey: .scrollSpeed)
        scrollMode = try container.decodeIfPresent(String.self, forKey: .scrollMode)
        invertScroll = try container.decodeIfPresent(Bool.self, forKey: .invertScroll)
        scrollLines = try container.decodeIfPresent(UInt8.self, forKey: .scrollLines)
        vimMode = try container.decodeIfPresent(Bool.self, forKey: .vimMode)
        renderMermaid = try container.decodeIfPresent(String.self, forKey: .renderMermaid)
        hunkTrackerMode = try container.decodeIfPresent(String.self, forKey: .hunkTrackerMode)
        voiceCaptureMode = try container.decodeIfPresent(String.self, forKey: .voiceCaptureMode)
        voiceSttLanguage = try container.decodeIfPresent(String.self, forKey: .voiceSttLanguage)
        mouseReportingToggle = try container.decodeIfPresent(Bool.self, forKey: .mouseReportingToggle)
        cancelSubagentsOnTurnCancel = try container.decodeIfPresent(String.self, forKey: .cancelSubagentsOnTurnCancel)
        rememberToolApprovals = try container.decodeIfPresent(Bool.self, forKey: .rememberToolApprovals)
        codeMode = try container.decodeIfPresent(ToolModePreference.self, forKey: .codeMode)
        // keep_text_selection: legacy bool (true → "hold", false → "flash") + string
        keepTextSelection = try Self.decodeKeepTextSelection(from: container, forKey: .keepTextSelection)
        selectionHighlightDurationMs = try container.decodeIfPresent(UInt64.self, forKey: .selectionHighlightDurationMs)
        showThinkingBlocks = try container.decodeIfPresent(Bool.self, forKey: .showThinkingBlocks)
        groupToolVerbs = try container.decodeIfPresent(Bool.self, forKey: .groupToolVerbs)
        collapsedEditBlocks = try container.decodeIfPresent(Bool.self, forKey: .collapsedEditBlocks)
        promptSuggestions = try container.decodeIfPresent(Bool.self, forKey: .promptSuggestions)
        cursorBlink = try container.decodeIfPresent(Bool.self, forKey: .cursorBlink)
        screenMode = try container.decodeIfPresent(String.self, forKey: .screenMode)
        doubleClickAction = try container.decodeIfPresent(String.self, forKey: .doubleClickAction)
        contextualHints = try container.decodeIfPresent(ContextualHints.self, forKey: .contextualHints)
            ?? ContextualHints()
        displayRefresh = try container.decodeIfPresent(DisplayRefreshSettings.self, forKey: .displayRefresh)
            ?? DisplayRefreshSettings()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(maxThoughtsWidth, forKey: .maxThoughtsWidth)
        try container.encodeIfPresent(theme, forKey: .theme)
        try container.encode(forkSecondaryModel, forKey: .forkSecondaryModel)
        try container.encode(yolo, forKey: .yolo)
        try container.encodeIfPresent(uiTheme, forKey: .uiTheme)
        try container.encode(compactMode, forKey: .compactMode)
        try container.encodeIfPresent(simpleMode, forKey: .simpleMode)
        try container.encodeIfPresent(swarmMode, forKey: .swarmMode)
        try container.encodeIfPresent(permissionMode, forKey: .permissionMode)
        try container.encodeIfPresent(approvalMode, forKey: .approvalMode)
        try container.encodeIfPresent(defaultSelectedPermission, forKey: .defaultSelectedPermission)
        try container.encodeIfPresent(showTimestamps, forKey: .showTimestamps)
        try container.encodeIfPresent(showTimeline, forKey: .showTimeline)
        try container.encodeIfPresent(pageFlipOnSend, forKey: .pageFlipOnSend)
        try container.encodeIfPresent(autoDarkTheme, forKey: .autoDarkTheme)
        try container.encodeIfPresent(autoLightTheme, forKey: .autoLightTheme)
        try container.encodeIfPresent(scrollSpeed, forKey: .scrollSpeed)
        try container.encodeIfPresent(scrollMode, forKey: .scrollMode)
        try container.encodeIfPresent(invertScroll, forKey: .invertScroll)
        try container.encodeIfPresent(scrollLines, forKey: .scrollLines)
        try container.encodeIfPresent(vimMode, forKey: .vimMode)
        try container.encodeIfPresent(renderMermaid, forKey: .renderMermaid)
        try container.encodeIfPresent(hunkTrackerMode, forKey: .hunkTrackerMode)
        try container.encodeIfPresent(voiceCaptureMode, forKey: .voiceCaptureMode)
        try container.encodeIfPresent(voiceSttLanguage, forKey: .voiceSttLanguage)
        try container.encodeIfPresent(mouseReportingToggle, forKey: .mouseReportingToggle)
        try container.encodeIfPresent(cancelSubagentsOnTurnCancel, forKey: .cancelSubagentsOnTurnCancel)
        try container.encodeIfPresent(rememberToolApprovals, forKey: .rememberToolApprovals)
        try container.encodeIfPresent(codeMode, forKey: .codeMode)
        try container.encodeIfPresent(keepTextSelection, forKey: .keepTextSelection)
        try container.encodeIfPresent(selectionHighlightDurationMs, forKey: .selectionHighlightDurationMs)
        try container.encodeIfPresent(showThinkingBlocks, forKey: .showThinkingBlocks)
        try container.encodeIfPresent(groupToolVerbs, forKey: .groupToolVerbs)
        try container.encodeIfPresent(collapsedEditBlocks, forKey: .collapsedEditBlocks)
        try container.encodeIfPresent(promptSuggestions, forKey: .promptSuggestions)
        try container.encodeIfPresent(cursorBlink, forKey: .cursorBlink)
        try container.encodeIfPresent(screenMode, forKey: .screenMode)
        try container.encodeIfPresent(doubleClickAction, forKey: .doubleClickAction)
        if !contextualHints.isDefault {
            try container.encode(contextualHints, forKey: .contextualHints)
        }
        if !displayRefresh.isDefault {
            try container.encode(displayRefresh, forKey: .displayRefresh)
        }
    }

    // MARK: Custom decoder for keep_text_selection (legacy bool + string)

    private static func decodeKeepTextSelection(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> String? {
        guard container.contains(key) else { return nil }
        // Try bool first (legacy form).
        if let bool = try? container.decode(Bool.self, forKey: key) {
            return bool ? "hold" : "flash"
        }
        // Try string (canonical form).
        return try container.decodeIfPresent(String.self, forKey: key)
    }
}
