// PagerSettingsRegistry.swift
//
// The settings catalog: every row the settings modal can show, what kind of
// value it holds, and where it lives on disk.
//
// Ports `xai-grok-pager/src/settings/registry.rs` (types) and
// `src/settings/defs.rs` (the catalog) at upstream 9ed09e2a.
//
// The registry is deliberately pure metadata. It does not read config, does not
// write config, and does not know what a theme or a model is — it says a row
// named `theme` is an enum over these choices and lives at `[ui] theme`, and
// `PagerSettingsStore` is what turns that into a file edit. Keeping the two
// apart is what lets the whole 90-row catalog be golden-tested without a disk.

import Foundation

// MARK: - Categories

/// `SettingCategory` (`registry.rs:36-45`), in the reference's render order.
public enum PagerSettingCategory: String, Sendable, Equatable, Hashable, CaseIterable {
    case appearance
    case mouse
    case editor
    case agent
    case privacy
    case models
    case session
    case advanced

    /// Section-header text (`registry.rs:61-72`).
    public var label: String {
        switch self {
        case .appearance: return "Appearance"
        case .mouse: return "Mouse"
        case .editor: return "Editor & Input"
        case .agent: return "Agent & Approval"
        case .privacy: return "Privacy"
        case .models: return "Models"
        case .session: return "Session"
        case .advanced: return "Advanced"
        }
    }

    /// `ALL` (`registry.rs:49-59`). `session` is registered upstream but has no
    /// rows; it is kept so a future row lands in the reference's slot rather
    /// than at the end.
    public static let ordered: [PagerSettingCategory] = [
        .appearance, .mouse, .editor, .agent, .privacy, .models, .session, .advanced
    ]
}

// MARK: - Values

/// One option in an enum row (`EnumChoice`, `registry.rs:77-85`).
public struct PagerSettingChoice: Sendable, Equatable, Hashable {
    /// What is written to disk.
    public var canonical: String
    /// What the chooser sheet shows.
    public var display: String
    /// The `" · "`-separated tail on the chooser row. Often empty.
    public var summary: String

    public init(canonical: String, display: String, summary: String = "") {
        self.canonical = canonical
        self.display = display
        self.summary = summary
    }
}

/// Where an enum's choices come from when they are not a fixed list
/// (`DynamicEnumSource`, `registry.rs:135-147`).
public enum PagerSettingDynamicSource: String, Sendable, Equatable, Hashable {
    /// The models available in the active session.
    case activeModelCatalog
    /// Economical models for background work — recaps, memory.
    case auxiliaryModelCatalog
    /// The multi-select of discovered OpenCode Go models.
    case openCodeGoModels
}

/// `StringValidator` (`registry.rs:196-207`).
public enum PagerSettingValidator: String, Sendable, Equatable, Hashable {
    case any
    case nonEmptyToken
    case knownModel
}

/// `SettingKind` (`registry.rs:210-256`).
public enum PagerSettingKind: Sendable, Equatable, Hashable {
    case bool(default: Bool)
    case string(default: String, validator: PagerSettingValidator)
    /// A credential. Never round-trips through the row value: the modal shows a
    /// status, and the editor's plaintext goes straight to the secret store.
    case secret
    case enumeration(default: String, choices: [PagerSettingChoice], supportsPreview: Bool)
    case integer(default: Int, minimum: Int, maximum: Int)
    case dynamicEnum(default: String, source: PagerSettingDynamicSource, supportsPreview: Bool)
    /// A row that only opens a sub-sheet of child rows; it has no value itself.
    case group(children: [String])
    case dynamicMultiSelect(source: PagerSettingDynamicSource)

    public var isEditable: Bool {
        switch self {
        case .group, .dynamicMultiSelect: return false
        default: return true
        }
    }
}

/// `SecretStatus` (`registry.rs:284-298`) — what the modal shows in place of a
/// key it will never display.
public enum PagerSecretStatus: String, Sendable, Equatable, Hashable {
    case missing
    case stored
    case environmentOverride

    public var display: String {
        switch self {
        case .missing: return "not configured"
        case .stored: return "saved"
        case .environmentOverride: return "environment override"
        }
    }
}

/// `SettingValue` (`registry.rs:306-317`) — the current state of one row.
public enum PagerSettingValue: Sendable, Equatable, Hashable {
    case bool(Bool)
    case string(String)
    case integer(Int)
    case secret(PagerSecretStatus)
}

/// Why a row cannot be changed (`CodingDataSharingLock`, `registry.rs:319-336`).
///
/// A locked row is shown, not hidden: a user who cannot change data sharing
/// still needs to see what it is set to and why.
public enum PagerSettingLock: Sendable, Equatable, Hashable {
    case zeroDataRetention
    case policyManaged

    public var reason: String {
        switch self {
        case .zeroDataRetention: return "Your team has Zero Data Retention."
        case .policyManaged: return "Locked by your organization's policy."
        }
    }
}

// MARK: - Row metadata

/// Where a row's value is persisted. The reference splits this across a shell
/// config, a pager-local snapshot, and an auth store; this enum names the same
/// three destinations so `PagerSettingsStore` can route a write without a
/// second key→destination table drifting out of sync with this one.
public enum PagerSettingStorage: Sendable, Equatable, Hashable {
    /// A dotted path into `config.toml`, e.g. `ui.theme`.
    case config(path: String)
    /// A dotted boolean feature flag in `config.toml`, written by raw TOML
    /// surgery rather than through a typed config struct
    /// (`settings_writes.rs:173-189`).
    case featureFlag(path: String)
    /// Held for the session only — never written.
    case sessionLocal
    /// An owner-protected credential store, not `config.toml`.
    case secretStore(account: String)
    /// Auth metadata rather than config (`coding_data_sharing`).
    case authMetadata(key: String)
}

/// `SettingMeta` (`registry.rs:260-282`).
public struct PagerSettingMeta: Sendable, Equatable, Hashable, Identifiable {
    public var key: String
    public var category: PagerSettingCategory
    public var label: String
    public var description: String
    /// Extra terms the filter matches on beyond label, description, and key.
    public var keywords: [String]
    public var kind: PagerSettingKind
    public var storage: PagerSettingStorage
    /// Metadata only: the reference renders a `· restart` pill on an expanded
    /// row and tracks nothing else (`render.rs:2517-2523`).
    public var restartRequired: Bool
    /// Hidden while the pager runs in minimal (scrollback-native) mode.
    public var hiddenInMinimal: Bool

    public var id: String { key }

    public init(
        key: String,
        category: PagerSettingCategory,
        label: String,
        description: String,
        keywords: [String] = [],
        kind: PagerSettingKind,
        storage: PagerSettingStorage,
        restartRequired: Bool = false,
        hiddenInMinimal: Bool = false
    ) {
        self.key = key
        self.category = category
        self.label = label
        self.description = description
        self.keywords = keywords
        self.kind = kind
        self.storage = storage
        self.restartRequired = restartRequired
        self.hiddenInMinimal = hiddenInMinimal
    }

    /// `default_value_for` (`registry.rs:960-980`). Group and multi-select rows
    /// have no scalar value; the reference returns a dummy that is never read,
    /// and this returns `nil` so a caller cannot read one by accident.
    public var defaultValue: PagerSettingValue? {
        switch kind {
        case .bool(let value): return .bool(value)
        case .string(let value, _): return .string(value)
        case .integer(let value, _, _): return .integer(value)
        case .enumeration(let value, _, _): return .string(value)
        case .dynamicEnum(let value, _, _): return .string(value)
        case .secret: return .secret(.missing)
        case .group, .dynamicMultiSelect: return nil
        }
    }

    /// The text a search query is matched against
    /// (`build_search_haystack`, `registry.rs:654`).
    var searchHaystack: String {
        ([label, description, key] + keywords).joined(separator: " ").lowercased()
    }
}

// MARK: - Choice catalogs

/// The fixed enum catalogs (`defs.rs:41-599`).
public enum PagerSettingChoices {
    /// `THEME_CHOICES` (`defs.rs:41`).
    public static let theme: [PagerSettingChoice] = [
        PagerSettingChoice(canonical: "auto", display: "Auto",
                           summary: "Follow system dark/light appearance."),
        PagerSettingChoice(canonical: "groknight", display: "Grok Night",
                           summary: "Neutral dark with magenta accent."),
        PagerSettingChoice(canonical: "grokday", display: "Grok Day",
                           summary: "Light theme for bright environments."),
        PagerSettingChoice(canonical: "tokyonight", display: "Tokyo Night",
                           summary: "Dark + blue-tinted; needs truecolor."),
        PagerSettingChoice(canonical: "rosepine-moon", display: "Rose Pine Moon",
                           summary: "Muted dark with mauve accents; needs truecolor."),
        PagerSettingChoice(canonical: "oscura-midnight", display: "Oscura Midnight",
                           summary: "Deep dark with warm accents; needs truecolor.")
    ]

    /// `CONCRETE_THEME_CHOICES` (`defs.rs:528`) — the theme list without `auto`,
    /// used by the two auto-mode overrides so they cannot recurse.
    public static let concreteTheme: [PagerSettingChoice] = Array(theme.dropFirst())

    /// `PERMISSION_MODE_CHOICES` (`defs.rs:95-117`).
    public static let permissionMode: [PagerSettingChoice] = [
        PagerSettingChoice(canonical: "default", display: "Default",
                           summary: "Use the agent's built-in behavior."),
        PagerSettingChoice(canonical: "ask", display: "Ask",
                           summary: "Prompt before each tool action."),
        PagerSettingChoice(canonical: "auto", display: "Auto",
                           summary: "An LLM classifier approves safe tools."),
        PagerSettingChoice(canonical: "always-approve", display: "Always approve",
                           summary: "Grant every permission automatically.")
    ]

    /// `CODE_MODE_CHOICES` (`defs.rs:119`).
    public static let codeMode: [PagerSettingChoice] = [
        PagerSettingChoice(canonical: "direct", display: "Direct"),
        PagerSettingChoice(canonical: "code_mode", display: "Code Mode"),
        PagerSettingChoice(canonical: "code_mode_only", display: "Code Mode Only")
    ]

    /// `IMAGE_GENERATION_PROVIDER_CHOICES` (`defs.rs:137`).
    public static let imageGenerationProvider: [PagerSettingChoice] = [
        PagerSettingChoice(canonical: "grok", display: "Grok Imagine"),
        PagerSettingChoice(canonical: "openai", display: "OpenAI Images")
    ]

    /// `CODING_DATA_SHARING_CHOICES` (`defs.rs:158`).
    public static let codingDataSharing: [PagerSettingChoice] = [
        PagerSettingChoice(canonical: "opt-in", display: "Opt in"),
        PagerSettingChoice(canonical: "opt-out", display: "Opt out")
    ]

    /// `KIMI_API_ENDPOINT_CHOICES` (`defs.rs:176`).
    public static let kimiEndpoint: [PagerSettingChoice] = [
        PagerSettingChoice(canonical: "platform", display: "Kimi Platform"),
        PagerSettingChoice(canonical: "code", display: "Kimi Code")
    ]

    /// `DEFAULT_SELECTED_PERMISSION_CHOICES` (`defs.rs:226`).
    public static let defaultSelectedPermission: [PagerSettingChoice] = [
        PagerSettingChoice(canonical: "always-allow-all-sessions", display: "Always allow (all sessions)"),
        PagerSettingChoice(canonical: "allow-command-always", display: "Allow this command always"),
        PagerSettingChoice(canonical: "allow-once", display: "Allow once"),
        PagerSettingChoice(canonical: "reject", display: "Reject")
    ]

    /// `PLAN_MODE_CHOICES` (`defs.rs:246`).
    public static let planMode: [PagerSettingChoice] = [
        PagerSettingChoice(canonical: "off", display: "Off"),
        PagerSettingChoice(canonical: "on", display: "On")
    ]

    /// `RENDER_MERMAID_CHOICES` (`defs.rs:265`).
    public static let renderMermaid: [PagerSettingChoice] = [
        PagerSettingChoice(canonical: "auto", display: "Auto"),
        PagerSettingChoice(canonical: "on", display: "On"),
        PagerSettingChoice(canonical: "off", display: "Off")
    ]

    /// `SCROLL_MODE_CHOICES` (`defs.rs:284`).
    public static let scrollMode: [PagerSettingChoice] = [
        PagerSettingChoice(canonical: "auto", display: "Auto-detect"),
        PagerSettingChoice(canonical: "wheel", display: "Mouse wheel"),
        PagerSettingChoice(canonical: "trackpad", display: "Trackpad")
    ]

    /// `TEXT_SELECTION_CHOICES` (`defs.rs:302`).
    public static let textSelection: [PagerSettingChoice] = [
        PagerSettingChoice(canonical: "flash", display: "Flash after copy"),
        PagerSettingChoice(canonical: "hold", display: "Hold until dismissed"),
        PagerSettingChoice(canonical: "word-select", display: "Word select (terminal-like)")
    ]

    /// `HUNK_TRACKER_MODE_CHOICES` (`defs.rs:322`). `disabled` parses as an
    /// alias for `off` upstream but is not offered as a choice.
    public static let hunkTrackerMode: [PagerSettingChoice] = [
        PagerSettingChoice(canonical: "agent_only", display: "Agent only"),
        PagerSettingChoice(canonical: "all_dirty", display: "All dirty"),
        PagerSettingChoice(canonical: "off", display: "Off")
    ]

    /// `SCREEN_MODE_CHOICES` (`defs.rs:340`).
    public static let screenMode: [PagerSettingChoice] = [
        PagerSettingChoice(canonical: "fullscreen", display: "Fullscreen"),
        PagerSettingChoice(canonical: "minimal", display: "Minimal")
    ]

    /// `VOICE_CAPTURE_MODE_CHOICES` (`defs.rs:357`). `hold` needs a terminal
    /// that reports key releases, and is gated at display time rather than
    /// removed from the catalog.
    public static let voiceCaptureMode: [PagerSettingChoice] = [
        PagerSettingChoice(canonical: "toggle", display: "Toggle"),
        PagerSettingChoice(canonical: "hold", display: "Hold to talk")
    ]

    /// `VOICE_STT_LANGUAGE_CHOICES` (`defs.rs:375-525`) — in the reference's
    /// own order, which puts English first and System second rather than
    /// sorting alphabetically.
    public static let voiceLanguage: [PagerSettingChoice] = [
        PagerSettingChoice(canonical: "en", display: "English"),
        PagerSettingChoice(canonical: "auto", display: "System",
                           summary: "Use your locale when the model supports it."),
        PagerSettingChoice(canonical: "ar", display: "Arabic"),
        PagerSettingChoice(canonical: "cs", display: "Czech"),
        PagerSettingChoice(canonical: "da", display: "Danish"),
        PagerSettingChoice(canonical: "nl", display: "Dutch"),
        PagerSettingChoice(canonical: "fil", display: "Filipino"),
        PagerSettingChoice(canonical: "fr", display: "French"),
        PagerSettingChoice(canonical: "de", display: "German"),
        PagerSettingChoice(canonical: "hi", display: "Hindi"),
        PagerSettingChoice(canonical: "id", display: "Indonesian"),
        PagerSettingChoice(canonical: "it", display: "Italian"),
        PagerSettingChoice(canonical: "ja", display: "Japanese"),
        PagerSettingChoice(canonical: "ko", display: "Korean"),
        PagerSettingChoice(canonical: "mk", display: "Macedonian"),
        PagerSettingChoice(canonical: "ms", display: "Malay"),
        PagerSettingChoice(canonical: "fa", display: "Persian"),
        PagerSettingChoice(canonical: "pl", display: "Polish"),
        PagerSettingChoice(canonical: "pt", display: "Portuguese"),
        PagerSettingChoice(canonical: "ro", display: "Romanian"),
        PagerSettingChoice(canonical: "ru", display: "Russian"),
        PagerSettingChoice(canonical: "es", display: "Spanish"),
        PagerSettingChoice(canonical: "sv", display: "Swedish"),
        PagerSettingChoice(canonical: "th", display: "Thai"),
        PagerSettingChoice(canonical: "tr", display: "Turkish"),
        PagerSettingChoice(canonical: "vi", display: "Vietnamese")
    ]

    /// `WEB_SEARCH_SOURCE_XAI_DEFAULT_CHOICES` (`defs.rs:571`).
    public static let webSearchSourceXAI: [PagerSettingChoice] = [
        PagerSettingChoice(canonical: "xai", display: "xAI"),
        PagerSettingChoice(canonical: "perplexity", display: "Perplexity")
    ]

    /// `WEB_SEARCH_SOURCE_CODEX_CHOICES` (`defs.rs:585`).
    public static let webSearchSourceCodex: [PagerSettingChoice] = [
        PagerSettingChoice(canonical: "native", display: "Native"),
        PagerSettingChoice(canonical: "xai", display: "xAI"),
        PagerSettingChoice(canonical: "perplexity", display: "Perplexity")
    ]
}

// MARK: - Registry

/// `SettingsRegistry` (`registry.rs:580-635`).
public struct PagerSettingsRegistry: Sendable, Equatable {
    public let entries: [PagerSettingMeta]
    private let index: [String: Int]

    /// Keys must be unique — several behaviors gate on string equality, and a
    /// duplicate would make which one they hit depend on ordering. The
    /// reference asserts this at construction (`assert_unique_keys`,
    /// `registry.rs:637`); a debug trap plus last-wins is the Swift equivalent
    /// that still leaves a release build usable.
    public init(entries: [PagerSettingMeta]) {
        self.entries = entries
        var index: [String: Int] = [:]
        for (offset, entry) in entries.enumerated() {
            assert(index[entry.key] == nil, "duplicate settings key: \(entry.key)")
            index[entry.key] = offset
        }
        self.index = index
    }

    public static let `default` = PagerSettingsRegistry(entries: pagerDefaultSettings)

    public func find(_ key: String) -> PagerSettingMeta? {
        index[key].map { entries[$0] }
    }

    public func rows(in category: PagerSettingCategory) -> [PagerSettingMeta] {
        entries.filter { $0.category == category }
    }

    /// Multi-word AND search over label, description, key, and keywords
    /// (`search`, `registry.rs:618-635`). Every word must appear somewhere;
    /// none has to appear in the same field.
    public func search(_ query: String) -> [PagerSettingMeta] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return entries }
        return entries.filter { entry in
            let haystack = entry.searchHaystack
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    /// Every key that is a child of some group row, so the browse list can skip
    /// them — a group's children only appear inside its sub-sheet
    /// (`build_rows`, `state.rs:993-1035`).
    public var groupChildKeys: Set<String> {
        var keys: Set<String> = []
        for entry in entries {
            if case .group(let children) = entry.kind {
                keys.formUnion(children)
            }
        }
        return keys
    }
}

// MARK: - The catalog

/// The `contextual_hints.*` children (`CONTEXTUAL_HINTS_CHILDREN`, `defs.rs:561`).
private let contextualHintsChildren = [
    "contextual_hints.undo",
    "contextual_hints.plan_mode",
    "contextual_hints.image_input",
    "contextual_hints.send_now",
    "contextual_hints.small_screen",
    "contextual_hints.word_select",
    "contextual_hints.ssh_wrap"
]

/// `default_settings()` (`defs.rs:604-2427`) — all 90 rows upstream; this
/// port registers fewer because rows without a live renderer reader are hidden
/// (same rule as `show_tips`).
public let pagerDefaultSettings: [PagerSettingMeta] = {
    var rows: [PagerSettingMeta] = []

    // MARK: Appearance (7 — upstream 17 minus 10 without live readers)

    rows += [
        // Hidden until the renderer reads them (config round-trips; modal omits):
        // `compact_mode`, `show_timestamps`, `show_timeline`, `page_flip_on_send`,
        // `simple_mode`, `render_mermaid`, `max_thoughts_width`, `show_thinking_blocks`,
        // `group_tool_verbs`, `collapsed_edit_blocks`.
        PagerSettingMeta(
            key: "screen_mode",
            category: .appearance,
            label: "Default screen mode",
            description: "How Open Grok opens next time: Fullscreen (default when unset) or Minimal. Writes [ui] screen_mode in config.toml. Restart required. Switch this session only with /minimal or /fullscreen.",
            keywords: ["fullscreen", "minimal"],
            kind: .enumeration(default: "fullscreen", choices: PagerSettingChoices.screenMode, supportsPreview: false),
            storage: .config(path: "ui.screen_mode"),
            restartRequired: true
        ),
        PagerSettingMeta(
            key: "vim_mode",
            category: .appearance,
            label: "Vim scrollback navigation",
            description: "Enable vim keys (h/j/k/l, gg/G, /) for navigating the scrollback. Does not affect the input prompt.",
            keywords: ["vim", "scrollback", "navigation"],
            kind: .bool(default: false),
            storage: .config(path: "ui.vim_mode")
        ),
        PagerSettingMeta(
            key: "theme",
            category: .appearance,
            label: "Theme",
            description: "Color theme for the pager UI.",
            keywords: ["color", "palette", "dark", "light"],
            kind: .enumeration(default: "groknight", choices: PagerSettingChoices.theme, supportsPreview: true),
            storage: .config(path: "ui.theme"),
            hiddenInMinimal: true
        ),
        PagerSettingMeta(
            key: "auto_dark_theme",
            category: .appearance,
            label: "Auto dark theme",
            description: "Theme to use when the system is in dark mode (only with theme=auto).",
            keywords: ["color", "dark", "auto"],
            kind: .enumeration(default: "groknight", choices: PagerSettingChoices.concreteTheme, supportsPreview: true),
            storage: .config(path: "ui.auto_dark_theme"),
            hiddenInMinimal: true
        ),
        PagerSettingMeta(
            key: "auto_light_theme",
            category: .appearance,
            label: "Auto light theme",
            description: "Theme to use when the system is in light mode (only with theme=auto).",
            keywords: ["color", "light", "auto"],
            kind: .enumeration(default: "grokday", choices: PagerSettingChoices.concreteTheme, supportsPreview: true),
            storage: .config(path: "ui.auto_light_theme"),
            hiddenInMinimal: true
        ),
        PagerSettingMeta(
            key: "respect_manual_folds",
            category: .appearance,
            label: "Respect manual folds",
            description: "Keep manually folded blocks as-is while streaming and stop auto-scroll when expanding a block. Experimental.",
            keywords: ["fold", "collapse", "scroll"],
            kind: .bool(default: false),
            storage: .sessionLocal
        ),
        PagerSettingMeta(
            key: "display_refresh_auto_cadence",
            category: .appearance,
            label: "Match display refresh rate",
            description: "On high-refresh displays, the TUI will stream/scroll faster to match the display. Off keeps the classic ~60 Hz cadence. Restart required.",
            keywords: ["fps", "refresh", "cadence"],
            kind: .bool(default: false),
            storage: .config(path: "ui.display_refresh.auto_cadence_enabled"),
            restartRequired: true,
            hiddenInMinimal: true
        )
    ]

    // MARK: Mouse (0 — upstream 5; scroll/selection rows have no live reader)

    // Hidden: `scroll_speed`, `scroll_mode`, `scroll_lines`, `invert_scroll`,
    // `keep_text_selection` — the port's wheel handler does not read them yet.

    // MARK: Editor & Input (6 — upstream 7 minus `prompt_suggestions`)

    rows += [
        PagerSettingMeta(
            key: "combine_queued_prompts",
            category: .editor,
            label: "Combine queued prompts",
            description: "Merge consecutive plain follow-ups into one model turn (TUI shows one bubble each). Stops at bash, slash commands, cron, expanded skills, image follow-ups, or a row under edit. Default off; applies on local drain and shell promote.",
            keywords: ["queue", "batch"],
            kind: .bool(default: false),
            storage: .config(path: "ui.combine_queued_prompts")
        ),
        PagerSettingMeta(
            key: "enter_steers",
            category: .editor,
            label: "Enter steers mid-turn",
            description: "When a turn is running, swap Enter and the send-now chord (Ctrl+Enter, or Ctrl+O / Ctrl+L on some terminals). Off (default): Enter queues a follow-up; the chord sends now (cancels the turn). On: Enter sends now; the chord queues.",
            keywords: ["queue", "steer", "interject"],
            kind: .bool(default: false),
            storage: .config(path: "ui.enter_steers")
        ),
        PagerSettingMeta(
            key: "multiline_mode",
            category: .editor,
            label: "Multiline",
            description: "When on, Enter inserts a newline and Shift+Enter sends. Resets each session.",
            keywords: ["newline", "enter"],
            kind: .bool(default: false),
            storage: .sessionLocal
        ),
        // Hidden: `prompt_suggestions` — no ghost-text reader in this port yet.
        PagerSettingMeta(
            key: "voice_keybind_enabled",
            category: .editor,
            label: "Voice shortcut",
            description: "Enable the Ctrl+Space / F8 shortcut for voice dictation. When off, the keys are ignored; /voice still starts dictation.",
            keywords: ["voice", "dictation", "shortcut"],
            kind: .bool(default: true),
            storage: .config(path: "ui.voice_keybind_enabled")
        ),
        PagerSettingMeta(
            key: "voice_capture_mode",
            category: .editor,
            label: "Voice capture",
            description: "How the voice chord (Ctrl+Space / F8) behaves: Toggle (press to start/stop) or Hold to talk (hold to record, release to stop; needs a Kitty-protocol terminal).",
            keywords: ["voice", "dictation", "hold"],
            kind: .enumeration(default: "hold", choices: PagerSettingChoices.voiceCaptureMode, supportsPreview: false),
            storage: .config(path: "ui.voice_capture_mode")
        ),
        PagerSettingMeta(
            key: "voice_stt_language",
            category: .editor,
            label: "Voice language",
            description: "Speech-to-text language for voice dictation (Grok STT). English by default; System uses your locale when supported. Sets formatting language for numbers and currencies.",
            keywords: ["voice", "language", "stt"],
            kind: .enumeration(default: "en", choices: PagerSettingChoices.voiceLanguage, supportsPreview: false),
            storage: .config(path: "ui.voice_stt_language")
        )
    ]

    // MARK: Agent & Approval (9)

    rows += [
        PagerSettingMeta(
            key: "swarm_mode",
            category: .agent,
            label: "Swarm mode",
            description: "Enable coordinated subagent swarms by default. Active sessions update immediately; manual approvals can slow a swarm.",
            keywords: ["subagent", "swarm"],
            kind: .bool(default: false),
            storage: .config(path: "ui.swarm_mode")
        ),
        PagerSettingMeta(
            key: "antigravity_subagents",
            category: .agent,
            label: "Antigravity subagents",
            description: "Let Antigravity CLI (agy) models serve as subagents for task, swarm, and workflow tools. Requires being signed in to agy. Subagents run with full access by default; set [antigravity] skip_permissions = false to force read-only. Restart required.",
            keywords: ["antigravity", "agy", "subagent"],
            kind: .bool(default: false),
            storage: .config(path: "ui.antigravity_subagents"),
            restartRequired: true
        ),
        PagerSettingMeta(
            key: "antigravity_skip_permissions",
            category: .agent,
            label: "Antigravity full access",
            description: "Antigravity (agy) subagents run with agy's skip-permissions flag by default — they may write to the workspace and execute commands. Toggle OFF to force read-only researcher subagents; callers that pin a read-only capability mode stay read-only either way. Restart required.",
            keywords: ["antigravity", "agy", "permissions"],
            kind: .bool(default: true),
            storage: .config(path: "antigravity.skip_permissions"),
            restartRequired: true
        ),
        PagerSettingMeta(
            key: "permission_mode",
            category: .agent,
            label: "Permission mode",
            description: "Default uses the agent's built-in behavior; Ask prompts for each tool action; Auto uses an LLM classifier for risky tools; Always approve grants all permissions automatically.",
            keywords: ["approval", "yolo", "ask"],
            kind: .enumeration(default: "ask", choices: PagerSettingChoices.permissionMode, supportsPreview: false),
            storage: .sessionLocal
        ),
        PagerSettingMeta(
            key: "remember_tool_approvals",
            category: .agent,
            label: "Remember tool approvals",
            description: "Show \"Always allow\" options in permission prompts so you can stop being re-asked about a specific command or tool. Applies in ask and auto; Always-approve still skips all prompts. Restart required.",
            keywords: ["approval", "always allow"],
            kind: .bool(default: false),
            storage: .config(path: "ui.remember_tool_approvals"),
            restartRequired: true
        ),
        PagerSettingMeta(
            key: "code_mode",
            category: .agent,
            label: "Code mode",
            description: "Choose direct tools, mixed Code Mode, or Code Mode Only for Responses-backed sessions. OpenAI Codex models may require Code Mode Only. Restart Open Grok to apply.",
            keywords: ["tools", "code mode"],
            kind: .enumeration(default: "direct", choices: PagerSettingChoices.codeMode, supportsPreview: false),
            storage: .config(path: "ui.code_mode"),
            restartRequired: true
        ),
        PagerSettingMeta(
            key: "default_selected_permission",
            category: .agent,
            label: "Default selected permission",
            description: "Which row the cursor preselects on permission prompts.",
            keywords: ["approval", "default"],
            kind: .enumeration(default: "always-allow-all-sessions", choices: PagerSettingChoices.defaultSelectedPermission, supportsPreview: false),
            storage: .config(path: "ui.default_selected_permission")
        ),
        PagerSettingMeta(
            key: "toolset.ask_user_question.timeout_enabled",
            category: .agent,
            label: "Ask-Question timeout",
            description: "When on, the ask_user_question tool will time out after a set period of time instead of infinitely blocking.",
            keywords: ["question", "timeout"],
            kind: .bool(default: true),
            storage: .config(path: "toolset.ask_user_question.timeout_enabled"),
            restartRequired: true
        ),
        PagerSettingMeta(
            key: "plan_mode",
            category: .agent,
            label: "Plan mode",
            description: "When on, the agent summarises a plan before running tools or making edits.",
            keywords: ["plan"],
            kind: .enumeration(default: "off", choices: PagerSettingChoices.planMode, supportsPreview: false),
            storage: .sessionLocal
        )
    ]

    // MARK: Privacy (1)

    rows += [
        PagerSettingMeta(
            key: "coding_data_sharing",
            category: .privacy,
            label: "Coding data, retention, and training",
            description: "Opt-in to provide SpaceXAI the ability to retain and train on coding data, e.g., prompts, traces, & metrics, for training and debugging purposes. We may still collect simple user metrics, e.g. how many times you use the product or a feature.",
            keywords: ["privacy", "training", "retention", "telemetry"],
            kind: .enumeration(default: "opt-out", choices: PagerSettingChoices.codingDataSharing, supportsPreview: false),
            storage: .authMetadata(key: "coding_data_sharing")
        )
    ]

    // MARK: Models (24)

    rows += [
        PagerSettingMeta(
            key: "image_generation_provider",
            category: .models,
            label: "Image generation",
            description: "Choose Grok Imagine or OpenAI Images for image generation and editing. OpenAI Images requires `open-grok login --codex` and a supported paid ChatGPT plan. Restart Open Grok to apply.",
            keywords: ["image", "imagine"],
            kind: .enumeration(default: "grok", choices: PagerSettingChoices.imageGenerationProvider, supportsPreview: false),
            storage: .config(path: "ui.image_generation_provider"),
            restartRequired: true
        ),
        PagerSettingMeta(
            key: "default_model",
            category: .models,
            label: "Default model",
            description: "Model used for new sessions. Changing this also switches the active session. Pick `(no override)` to clear.",
            keywords: ["model"],
            kind: .dynamicEnum(default: "", source: .activeModelCatalog, supportsPreview: false),
            storage: .config(path: "models.default_model")
        ),
        PagerSettingMeta(
            key: "kimi_api_endpoint",
            category: .models,
            label: "Kimi service",
            description: "Choose Kimi Platform (pay-as-you-go) or Kimi Code (membership). Each service keeps its own API key and model catalog.",
            keywords: ["kimi", "moonshot"],
            kind: .enumeration(default: "platform", choices: PagerSettingChoices.kimiEndpoint, supportsPreview: false),
            storage: .config(path: "models.kimi_endpoint")
        ),
        PagerSettingMeta(
            key: "kimi_api_key",
            category: .models,
            label: "Kimi Platform API key",
            description: "Pay-as-you-go key for Kimi Platform. Saving queries the Platform model catalog; resetting leaves the Kimi Code key untouched.",
            keywords: ["kimi", "api key"],
            kind: .secret,
            storage: .secretStore(account: "kimi_platform")
        ),
        PagerSettingMeta(
            key: "kimi_code_api_key",
            category: .models,
            label: "Kimi Code API key",
            description: "Membership key from the Kimi Code console. Resetting leaves the Kimi Platform key untouched.",
            keywords: ["kimi", "api key"],
            kind: .secret,
            storage: .secretStore(account: "kimi_code")
        ),
        PagerSettingMeta(
            key: "fireworks_api_key",
            category: .models,
            label: "Fireworks AI API key",
            description: "API key from the Fireworks AI console. Saving refreshes the curated Fireworks model catalog.",
            keywords: ["fireworks", "api key"],
            kind: .secret,
            storage: .secretStore(account: "fireworks")
        ),
        PagerSettingMeta(
            key: "deepseek_api_key",
            category: .models,
            label: "DeepSeek API key",
            description: "API key from the DeepSeek platform. Saving refreshes the curated direct DeepSeek model catalog.",
            keywords: ["deepseek", "api key"],
            kind: .secret,
            storage: .secretStore(account: "deepseek")
        ),
        // `meta_api_key` (`settings/defs.rs:1184-1202`): between the DeepSeek
        // and OpenCode Go rows, exactly upstream's registry order.
        PagerSettingMeta(
            key: "meta_api_key",
            category: .models,
            label: "Meta API key",
            description: "API key for Meta's Model API. Saving refreshes the curated Muse Spark model catalog.",
            keywords: ["meta", "muse", "spark", "api", "key", "credential", "models"],
            kind: .secret,
            storage: .secretStore(account: "meta")
        ),
        PagerSettingMeta(
            key: "opencode_go_api_key",
            category: .models,
            label: "OpenCode Go API key",
            description: "API key for OpenCode Go. Saving queries its live model catalog; no models are enabled automatically.",
            keywords: ["opencode", "api key"],
            kind: .secret,
            storage: .secretStore(account: "opencode_go")
        ),
        PagerSettingMeta(
            key: "wafer_api_key",
            category: .models,
            label: "Wafer AI API key",
            description: "API key for Wafer AI. Saving refreshes its dynamic model catalog from pass.wafer.ai.",
            keywords: ["wafer", "api key"],
            kind: .secret,
            storage: .secretStore(account: "wafer")
        ),
        PagerSettingMeta(
            key: "opencode_go_models",
            category: .models,
            label: "OpenCode Go models",
            description: "Choose which discovered OpenCode Go models appear in model settings and are available to subagents.",
            keywords: ["opencode", "models"],
            kind: .dynamicMultiSelect(source: .openCodeGoModels),
            storage: .config(path: "models.opencode_go_enabled_models")
        ),
        PagerSettingMeta(
            key: "toolset.perplexity_web_search.enabled",
            category: .models,
            label: "Perplexity web search",
            description: "Add the local web_search fallback to authenticated Kimi sessions. Grok and Codex keep their native search declarations.",
            keywords: ["perplexity", "search"],
            kind: .bool(default: false),
            storage: .config(path: "toolset.perplexity_web_search.enabled")
        ),
        PagerSettingMeta(
            key: "perplexity_api_key",
            category: .models,
            label: "Perplexity API key",
            description: "API key for the Perplexity Search API. Stored only in owner-protected auth.json and applied live to Kimi sessions.",
            keywords: ["perplexity", "api key"],
            kind: .secret,
            storage: .secretStore(account: "perplexity")
        ),
        PagerSettingMeta(
            key: "toolset.web_search_source.xai",
            category: .models,
            label: "Web search — xAI models",
            description: "Search backend for xAI (Grok) sessions. Applies to new sessions.",
            keywords: ["search", "xai"],
            kind: .enumeration(default: "xai", choices: PagerSettingChoices.webSearchSourceXAI, supportsPreview: false),
            storage: .config(path: "toolset.web_search_source.xai")
        ),
        PagerSettingMeta(
            key: "toolset.web_search_source.codex",
            category: .models,
            label: "Web search — Codex models",
            description: "Search backend for OpenAI Codex sessions. Non-native choices replace the native declaration when their credentials resolve. Applies to new sessions.",
            keywords: ["search", "codex"],
            kind: .enumeration(default: "native", choices: PagerSettingChoices.webSearchSourceCodex, supportsPreview: false),
            storage: .config(path: "toolset.web_search_source.codex")
        ),
        PagerSettingMeta(
            key: "toolset.web_search_source.kimi_platform",
            category: .models,
            label: "Web search — Kimi Platform",
            description: "Search backend for Kimi Platform sessions. Falls back to none when neither xAI nor Perplexity is signed in. Applies to new sessions.",
            keywords: ["search", "kimi"],
            kind: .enumeration(default: "xai", choices: PagerSettingChoices.webSearchSourceXAI, supportsPreview: false),
            storage: .config(path: "toolset.web_search_source.kimi_platform")
        ),
        PagerSettingMeta(
            key: "toolset.web_search_source.kimi_code",
            category: .models,
            label: "Web search — Kimi Code",
            description: "Search backend for Kimi Code sessions. Falls back to none when neither xAI nor Perplexity is signed in. Applies to new sessions.",
            keywords: ["search", "kimi"],
            kind: .enumeration(default: "xai", choices: PagerSettingChoices.webSearchSourceXAI, supportsPreview: false),
            storage: .config(path: "toolset.web_search_source.kimi_code")
        ),
        PagerSettingMeta(
            key: "toolset.web_search_source.fireworks",
            category: .models,
            label: "Web search — Fireworks AI",
            description: "Search backend for Fireworks AI sessions. Falls back to none when neither xAI nor Perplexity is signed in. Applies to new sessions.",
            keywords: ["search", "fireworks"],
            kind: .enumeration(default: "xai", choices: PagerSettingChoices.webSearchSourceXAI, supportsPreview: false),
            storage: .config(path: "toolset.web_search_source.fireworks")
        ),
        PagerSettingMeta(
            key: "toolset.web_search_source.deepseek",
            category: .models,
            label: "Web search — DeepSeek",
            description: "Search backend for direct DeepSeek sessions. Falls back to none when neither xAI nor Perplexity is signed in. Applies to new sessions.",
            keywords: ["search", "deepseek"],
            kind: .enumeration(default: "xai", choices: PagerSettingChoices.webSearchSourceXAI, supportsPreview: false),
            storage: .config(path: "toolset.web_search_source.deepseek")
        ),
        PagerSettingMeta(
            key: "toolset.web_search_source.opencode_go",
            category: .models,
            label: "Web search — OpenCode Go",
            description: "Search backend for OpenCode Go sessions. Falls back to none when neither xAI nor Perplexity is signed in. Applies to new sessions.",
            keywords: ["search", "opencode"],
            kind: .enumeration(default: "xai", choices: PagerSettingChoices.webSearchSourceXAI, supportsPreview: false),
            storage: .config(path: "toolset.web_search_source.opencode_go")
        ),
        PagerSettingMeta(
            key: "toolset.x_search.enabled",
            category: .models,
            label: "X search",
            description: "Give every model the client x_search tool for posts on X, backed by the xAI API. Only registered when xAI is signed in; xAI sessions keep their native declaration. Applies to new sessions.",
            keywords: ["x", "twitter", "search"],
            kind: .bool(default: true),
            storage: .config(path: "toolset.x_search.enabled")
        ),
        PagerSettingMeta(
            key: "recap_model",
            category: .models,
            label: "Recap model",
            description: "Model used for conversation recaps. Automatic chooses an economical model for the active provider.",
            keywords: ["recap", "summary", "model"],
            kind: .dynamicEnum(default: "", source: .auxiliaryModelCatalog, supportsPreview: false),
            storage: .config(path: "models.recap_model")
        ),
        PagerSettingMeta(
            key: "memory_model",
            category: .models,
            label: "Memory model",
            description: "Model used for memory generation and consolidation. Automatic chooses an economical model for the active provider.",
            keywords: ["memory", "model"],
            kind: .dynamicEnum(default: "", source: .auxiliaryModelCatalog, supportsPreview: false),
            storage: .config(path: "models.memory_model")
        ),
        PagerSettingMeta(
            key: "fork_secondary_model",
            category: .models,
            label: "Fork secondary model",
            description: "Model used for the secondary agent when forking. Pick `(no override)` to clear.",
            keywords: ["fork", "model"],
            kind: .dynamicEnum(default: "", source: .activeModelCatalog, supportsPreview: false),
            storage: .config(path: "models.fork_secondary_model")
        )
    ]

    // MARK: Advanced (27 — upstream's 28 minus the hidden `show_tips`)

    rows += [
        // `show_tips` (`cli.show_tips`, upstream's tip-of-the-day banner) is
        // deliberately NOT registered: the Swift port has no tips/ephemeral
        // banner surface, so the row would be a knob with no reader — the
        // same registered-no-op the house parity rule forbids on dropdowns.
        // Re-add the row together with the banner, not before. The cost of
        // hiding it: a config file carrying `cli.show_tips` keeps the value
        // (storage round-trips unknown keys) but the modal will not show it
        // until the feature exists.
        PagerSettingMeta(
            key: "contextual_hints",
            category: .advanced,
            label: "Show contextual hints",
            description: "Show brief, in-context keyboard hints as you work; toggle each one individually.",
            keywords: ["hints"],
            kind: .group(children: contextualHintsChildren),
            storage: .config(path: "ui.contextual_hints")
        ),
        PagerSettingMeta(
            key: "auto_update",
            category: .advanced,
            label: "Auto-update",
            description: "Automatically download and install pager updates on startup. Restart required.",
            keywords: ["update"],
            kind: .bool(default: true),
            storage: .config(path: "cli.auto_update"),
            restartRequired: true
        ),
        PagerSettingMeta(
            key: "hunk_tracker_mode",
            category: .advanced,
            label: "Hunk tracker",
            description: "Which file changes the agent tracks as hunks. Off disables tracking (and LOC stats) entirely. Restart required.",
            keywords: ["hunk", "diff", "loc"],
            kind: .enumeration(default: "agent_only", choices: PagerSettingChoices.hunkTrackerMode, supportsPreview: false),
            storage: .config(path: "ui.hunk_tracker_mode"),
            restartRequired: true
        ),
        PagerSettingMeta(
            key: "memory.enabled",
            category: .advanced,
            label: "Memory tools",
            description: "Turn on cross-session memory so the agent can store and recall notes with /memory, /remember, and /dream. Off by default; restart after enabling so new sessions load the memory tools.",
            keywords: ["memory", "remember"],
            kind: .bool(default: false),
            storage: .featureFlag(path: "memory.enabled"),
            restartRequired: true
        ),
        PagerSettingMeta(
            key: "memory.dream.enabled",
            category: .advanced,
            label: "Automatic memory dreaming",
            description: "When Memory tools are on, periodically consolidate recent sessions into durable MEMORY.md notes in the background. Disable if you only want manual /remember and /dream.",
            keywords: ["memory", "dream"],
            kind: .bool(default: true),
            storage: .featureFlag(path: "memory.dream.enabled"),
            restartRequired: true
        ),
        PagerSettingMeta(
            key: "features.telemetry",
            category: .advanced,
            label: "Product telemetry",
            description: "Send anonymous product-analytics events (feature usage counts, not your prompts or code). Separate from Privacy → coding-data sharing. Restart required.",
            keywords: ["telemetry", "analytics"],
            kind: .bool(default: false),
            storage: .featureFlag(path: "features.telemetry"),
            restartRequired: true
        ),
        PagerSettingMeta(
            key: "features.lsp_tools",
            category: .advanced,
            label: "LSP tools",
            description: "Expose language-server tools so the agent can jump to definitions, find references, and use other IDE-style code intelligence from configured LSP servers. Restart required.",
            keywords: ["lsp", "language server"],
            kind: .bool(default: false),
            storage: .featureFlag(path: "features.lsp_tools"),
            restartRequired: true
        ),
        PagerSettingMeta(
            key: "features.web_fetch",
            category: .advanced,
            label: "Web fetch tool",
            description: "Let the agent fetch a specific URL and read the page as markdown (beyond search snippets). Off by default; applies to new sessions after restart.",
            keywords: ["fetch", "web"],
            kind: .bool(default: false),
            storage: .featureFlag(path: "features.web_fetch"),
            restartRequired: true
        ),
        PagerSettingMeta(
            key: "toolset.web_fetch.allow_local",
            category: .advanced,
            label: "Web fetch allow localhost",
            description: "When Web fetch is on, also allow fetches to explicit loopback hosts (localhost, 127.0.0.0/8, ::1) — useful for local docs servers. Private LAN and cloud-metadata addresses stay blocked.",
            keywords: ["fetch", "localhost"],
            kind: .bool(default: false),
            storage: .featureFlag(path: "toolset.web_fetch.allow_local"),
            restartRequired: true
        ),
        PagerSettingMeta(
            key: "features.two_pass_compaction",
            category: .advanced,
            label: "Two-pass compaction",
            description: "Before context fills up, prefire a background summary of older history, then compact NOTE + recent tail when the threshold hits. Can improve long-session continuity; restart required.",
            keywords: ["compaction", "context"],
            kind: .bool(default: false),
            storage: .featureFlag(path: "features.two_pass_compaction"),
            restartRequired: true
        ),
        PagerSettingMeta(
            key: "features.non_git_warning",
            category: .advanced,
            label: "Non-Git workspace warning",
            description: "Show a blocking startup warning when the working directory is not a Git repo, so you can quit before losing rewind/hunk tracking that depends on Git. Restart required.",
            keywords: ["git", "warning"],
            kind: .bool(default: false),
            storage: .featureFlag(path: "features.non_git_warning"),
            restartRequired: true
        ),
        PagerSettingMeta(
            key: "features.remember_mode",
            category: .advanced,
            label: "Remember-mode shortcut",
            description: "On an empty prompt, press # to enter remember mode and save the next line as a memory note (same as /remember with no args). Applies immediately; Memory tools still need to be enabled for notes to persist.",
            keywords: ["remember", "memory"],
            kind: .bool(default: false),
            storage: .featureFlag(path: "features.remember_mode")
        ),
        PagerSettingMeta(
            key: "doom_loop_recovery.enabled",
            category: .advanced,
            label: "Doom-loop recovery",
            description: "When the model repeats the same failing tool pattern, inject recovery guidance and retry the turn instead of spinning. On by default; turn off only if you want raw unassisted retries. Restart required.",
            keywords: ["loop", "recovery", "retry"],
            kind: .bool(default: true),
            storage: .featureFlag(path: "doom_loop_recovery.enabled"),
            restartRequired: true
        ),
        PagerSettingMeta(
            key: "features.subagent_worktree_snapshot",
            category: .advanced,
            label: "Subagent worktree snapshots",
            description: "After an isolated subagent finishes, snapshot its worktree into a durable Git ref and remove the temp directory so you can resume later without keeping every worktree on disk. Restart required.",
            keywords: ["worktree", "subagent", "snapshot"],
            kind: .bool(default: false),
            storage: .featureFlag(path: "features.subagent_worktree_snapshot"),
            restartRequired: true
        ),
        PagerSettingMeta(
            key: "diagnostics.crash_handler",
            category: .advanced,
            label: "Crash handler",
            description: "Install a richer crash/panic handler that captures stack traces and restores the terminal more reliably after a hard failure. Off by default; restart required to install.",
            keywords: ["crash", "panic", "diagnostics"],
            kind: .bool(default: false),
            storage: .featureFlag(path: "diagnostics.crash_handler"),
            restartRequired: true
        ),
        PagerSettingMeta(
            key: "ui.mouse_reporting_toggle",
            category: .advanced,
            label: "Mouse reporting toggle",
            description: "Register Ctrl+R (scrollback focused) and /toggle-mouse-reporting so you can turn terminal mouse capture off for native click-drag copy/paste, then turn TUI mouse features back on. Restart required.",
            keywords: ["mouse", "reporting"],
            kind: .bool(default: false),
            storage: .featureFlag(path: "ui.mouse_reporting_toggle"),
            restartRequired: true
        ),
        PagerSettingMeta(
            key: "suggestions.enabled",
            category: .advanced,
            label: "Shell command suggestions",
            description: "While typing shell/bash-style input, show inline suggestions from command history and path completion. Distinct from Appearance → Prompt suggestions. Restart required.",
            keywords: ["shell", "suggestions", "history"],
            kind: .bool(default: false),
            storage: .featureFlag(path: "suggestions.enabled"),
            restartRequired: true
        ),
        PagerSettingMeta(
            key: "suggestions.ai_enabled",
            category: .advanced,
            label: "AI shell suggestions",
            description: "When Shell command suggestions are on, also ask a small model for command completions. Uses extra tokens; leave off if you only want history/path matches. Restart required.",
            keywords: ["shell", "suggestions", "ai"],
            kind: .bool(default: false),
            storage: .featureFlag(path: "suggestions.ai_enabled"),
            restartRequired: true
        ),
        PagerSettingMeta(
            key: "sandbox.auto_allow_bash",
            category: .advanced,
            label: "Sandbox auto-allow bash",
            description: "When an OS sandbox profile is active, auto-approve bash tool calls that the sandbox already confines — fewer permission prompts, still blocked outside the sandbox. Restart required.",
            keywords: ["sandbox", "bash", "approval"],
            kind: .bool(default: false),
            storage: .featureFlag(path: "sandbox.auto_allow_bash"),
            restartRequired: true
        ),
        PagerSettingMeta(
            key: "tools.respect_gitignore",
            category: .advanced,
            label: "Respect .gitignore in tools",
            description: "Make search, find, and other file tools skip paths listed in .gitignore by default (build artifacts, node_modules, etc.). Restart required.",
            keywords: ["gitignore", "search", "tools"],
            kind: .bool(default: false),
            storage: .featureFlag(path: "tools.respect_gitignore"),
            restartRequired: true
        )
    ]

    // The `contextual_hints` children. Registered as ordinary rows so filter
    // and reset reach them, but never listed at top level — `build_rows` skips
    // anything that is some group's child (`state.rs:993-1035`).
    let hintDescriptions: [(String, String, String)] = [
        ("contextual_hints.undo", "Undo",
         "Remind you that Ctrl+Z restores the prompt after you clear it."),
        ("contextual_hints.plan_mode", "Plan mode",
         "Suggest plan mode (Shift+Tab) when your prompt looks like a planning request."),
        ("contextual_hints.image_input", "Image input",
         "Offer to paste an image when one is on the clipboard and the model accepts images."),
        ("contextual_hints.send_now", "Send now",
         "After you queue a follow-up mid-turn, remind you that Enter on an empty prompt sends the top queued item now."),
        ("contextual_hints.small_screen", "Small screen",
         "Suggest /compact-mode once per run when the terminal is short on rows."),
        ("contextual_hints.word_select", "Word select",
         "After double-clicking conversation text while Text selection is fold/nav, remind you that Word select lives in Settings."),
        ("contextual_hints.ssh_wrap", "SSH wrap",
         "At session load over SSH, recommend `open-grok wrap ssh` for clipboard forwarding and terminal restore.")
    ]
    rows += hintDescriptions.map { key, label, description in
        PagerSettingMeta(
            key: key,
            category: .advanced,
            label: label,
            description: description,
            keywords: ["hint"],
            kind: .bool(default: true),
            storage: .config(path: "ui.\(key)")
        )
    }

    return rows
}()
