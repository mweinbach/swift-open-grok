import Foundation
import OpenGrokTerminalCore

// MARK: - Conversation content

public enum PagerMessageRole: Sendable, Equatable, Hashable {
    case user
    case assistant
    case system
    case reasoning
    case error
}

public struct PagerMessage: Sendable, Equatable, Hashable {
    public var role: PagerMessageRole
    public var text: String
    public var isStreaming: Bool
    /// Pre-styled rendering of `text` (markdown, typically). When empty the
    /// frame falls back to painting `text` verbatim, so a producer that cannot
    /// style a message — or renders it into nothing — degrades to plain text.
    /// `text` stays authoritative for transcripts and copy-out.
    public var styledLines: [PagerStyledLine]
    /// Wall time the reasoning took, surfaced as `Thought for 1.4s` once the
    /// block stops streaming. Only meaningful for `.reasoning`.
    public var duration: TimeInterval?
    /// Reasoning blocks collapse to their one-line header when the turn ends,
    /// matching `thinking.rs`'s `finished_display_mode`.
    public var isCollapsed: Bool
    /// When this block was created — upstream's
    /// `ScrollbackEntry.created_at: Option<DateTime<Local>>` (`entry.rs:105`),
    /// stamped `Local::now()` at construction (`entry.rs:198,230`) and
    /// overwritten with the persisted instant on replay
    /// (`acp/tracker.rs:954,1384`). Painted by the `[ui] show_timestamps`
    /// overlay for user and assistant blocks only.
    ///
    /// `nil` paints no stamp, exactly upstream's `let Some(ts) =
    /// entry.created_at` gate (`entry_renderer.rs:939`) — the honest state for
    /// a block with no known instant. The cost of the `nil` DEFAULT here
    /// (rather than `Date()`, upstream's constructor behavior): a live
    /// producer that forgets to stamp silently paints no timestamp — the live
    /// stamping is pinned by `LiveTimestampsTests` for exactly that reason.
    /// (`Date()` as a default would also make every two frames unequal.)
    public var createdAt: Date?

    public init(
        role: PagerMessageRole,
        text: String,
        isStreaming: Bool = false,
        styledLines: [PagerStyledLine] = [],
        duration: TimeInterval? = nil,
        isCollapsed: Bool = false,
        createdAt: Date? = nil
    ) {
        self.role = role
        self.text = text
        self.isStreaming = isStreaming
        self.styledLines = styledLines
        self.duration = duration
        self.isCollapsed = isCollapsed
        self.createdAt = createdAt
    }
}

public enum PagerToolState: Sendable, Equatable, Hashable {
    case pending
    case running
    case succeeded
    case failed
    case cancelled
}

/// The tool families the reference gives a bespoke header verb to
/// (`scrollback/blocks/tool/`). Anything else renders through `.generic`,
/// which prints the bare tool name in bold like `other.rs:138-176` does.
public enum PagerToolKind: Sendable, Equatable, Hashable {
    case read
    case edit
    case create
    case execute
    case search
    case list
    case fetch
    case webSearch
    case generic

    /// Header label prefix, e.g. `"Read "`.
    var headerVerb: String? {
        switch self {
        case .read: return "Read"
        case .edit: return "Edit"
        case .create: return "Creating"
        case .execute: return "Run"
        case .search: return "Search"
        case .list: return "List"
        case .fetch: return "Fetch"
        case .webSearch: return "Web Search"
        case .generic: return nil
        }
    }

    /// Whether the argument after the verb is a filesystem path, which the
    /// reference paints in `theme.path` rather than the body color.
    var argumentIsPath: Bool {
        switch self {
        case .read, .edit, .create, .list: return true
        case .execute, .search, .fetch, .webSearch, .generic: return false
        }
    }

    /// Classify a raw tool name the way the reference's block factory does.
    public static func infer(fromToolNamed name: String) -> PagerToolKind {
        switch name.lowercased() {
        case "read", "read_file", "view", "cat": return .read
        case "edit", "edit_file", "apply_patch", "str_replace": return .edit
        case "write", "write_file", "create", "create_file": return .create
        case "bash", "shell", "execute", "run", "run_command", "terminal": return .execute
        case "grep", "search", "ripgrep", "search_files", "codebase_search": return .search
        case "ls", "list", "list_dir", "list_directory", "glob": return .list
        case "fetch", "web_fetch", "http", "curl": return .fetch
        case "web_search", "websearch", "search_web": return .webSearch
        default: return .generic
        }
    }
}

public struct PagerToolCard: Sendable, Equatable, Hashable {
    public var name: String
    public var kind: PagerToolKind
    /// The single argument summarized in the header — a path for file tools, a
    /// command for execute, a query for search.
    public var input: String
    public var output: String?
    /// Trailing parenthetical detail such as `"(12 matches)"` or `"(empty)"`.
    public var detail: String?
    public var state: PagerToolState
    public var isExpanded: Bool
    /// When the tool reached a terminal state, in `PagerMotionSnapshot.seconds`
    /// time. A just-finished block keeps its bright accent for the 400 ms
    /// finish flash (`scrollback/state/types.rs:84`); `nil` means "unknown",
    /// which renders as already-static — a producer that never stamps this
    /// simply gets no flash, not a stuck-bright block.
    public var finishedAt: TimeInterval?

    public init(
        name: String,
        kind: PagerToolKind? = nil,
        input: String = "",
        output: String? = nil,
        detail: String? = nil,
        state: PagerToolState = .pending,
        isExpanded: Bool = false,
        finishedAt: TimeInterval? = nil
    ) {
        self.name = name
        self.kind = kind ?? PagerToolKind.infer(fromToolNamed: name)
        self.input = input
        self.output = output
        self.detail = detail
        self.state = state
        self.isExpanded = isExpanded
        self.finishedAt = finishedAt
    }
}

public enum PagerConversationItem: Sendable, Equatable, Hashable {
    case message(PagerMessage)
    case tool(PagerToolCard)
    case separator(String)

    /// Groupable blocks pack with zero gap when consecutive and collapsed,
    /// per `scrollback/state/layout.rs:1375-1428`. User and assistant messages
    /// are deliberately not groupable.
    var isGroupable: Bool {
        switch self {
        case .tool: return true
        case .message(let message): return message.role == .reasoning || message.role == .system
        case .separator: return false
        }
    }

    var isCollapsed: Bool {
        switch self {
        case .tool(let tool): return !tool.isExpanded
        case .message(let message): return message.isCollapsed
        case .separator: return true
        }
    }
}

// MARK: - Status bar (top row)

public struct PagerStatusBar: Sendable, Equatable, Hashable {
    /// Current git branch. `nil` hides the git segment entirely.
    public var gitBranch: String?
    /// Rendered as `"⎇ detached"` when the branch name is unavailable.
    public var isDetached: Bool
    public var workingDirectory: String?
    public var isWorktree: Bool
    public var mainRepository: String?
    public var sandboxProfile: String?

    public var contextUsedTokens: Int?
    public var contextTotalTokens: Int?
    public var queuedPromptCount: Int
    public var isPlanMode: Bool
    public var backgroundTaskCount: Int
    /// The pointer is over the context segment — swap the tokens for the
    /// width-matched progress bar (`context_bar.rs:184-189`).
    public var contextBarHovered: Bool

    public init(
        gitBranch: String? = nil,
        isDetached: Bool = false,
        workingDirectory: String? = nil,
        isWorktree: Bool = false,
        mainRepository: String? = nil,
        sandboxProfile: String? = nil,
        contextUsedTokens: Int? = nil,
        contextTotalTokens: Int? = nil,
        queuedPromptCount: Int = 0,
        isPlanMode: Bool = false,
        backgroundTaskCount: Int = 0,
        contextBarHovered: Bool = false
    ) {
        self.gitBranch = gitBranch
        self.isDetached = isDetached
        self.workingDirectory = workingDirectory
        self.isWorktree = isWorktree
        self.mainRepository = mainRepository
        self.sandboxProfile = sandboxProfile
        self.contextUsedTokens = contextUsedTokens
        self.contextTotalTokens = contextTotalTokens
        self.queuedPromptCount = queuedPromptCount
        self.isPlanMode = isPlanMode
        self.backgroundTaskCount = backgroundTaskCount
        self.contextBarHovered = contextBarHovered
    }
}

// MARK: - Turn status row

/// Which glyph leads the turn-status row, and how it animates.
///
/// Upstream picks between three cues in `turn_status.rs`: the braille turn
/// spinner (`:420`), the pulsing "waiting on you" diamond (`:484-486`), and
/// the calm `○ ◎ ◉ ◎` monitor pulse for idle-with-watchers (`:322-325`).
public enum PagerTurnIndicator: Sendable, Equatable, Hashable {
    /// The braille spinner — a turn is actively running.
    case spinner
    /// `◆` pulsing dim→bright in `accent_user` — the turn is parked on the
    /// user (permission prompt, ask-user question, drain blocked).
    case pendingUserDiamond
    /// `○ ◎ ◉ ◎` at half the spinner's rate — the agent is idle but watcher
    /// work (background tasks, monitors) is still alive.
    case idleMonitor
}

public struct PagerTurnStatus: Sendable, Equatable, Hashable {
    /// One of the reference's fixed activity labels — `"Thinking…"`,
    /// `"Responding…"`, `"Cancelling…"`, a running tool's title, and so on.
    /// The reference has no randomized verbs.
    public var label: String
    public var isCancelling: Bool
    /// Monotonic animation tick; the spinner advances every fourth tick.
    /// Live producers should feed the wall-clock tick from the controller's
    /// animation frames, not an event counter.
    public var tick: Int
    public var elapsed: TimeInterval?
    public var tokenCount: Int?
    public var queuedPromptCount: Int
    /// Whether a bare Enter would force-send the top queued row.
    public var queueIsSendable: Bool
    public var indicator: PagerTurnIndicator

    public init(
        label: String,
        isCancelling: Bool = false,
        tick: Int = 0,
        elapsed: TimeInterval? = nil,
        tokenCount: Int? = nil,
        queuedPromptCount: Int = 0,
        queueIsSendable: Bool = false,
        indicator: PagerTurnIndicator = .spinner
    ) {
        self.label = label
        self.isCancelling = isCancelling
        self.tick = tick
        self.elapsed = elapsed
        self.tokenCount = tokenCount
        self.queuedPromptCount = queuedPromptCount
        self.queueIsSendable = queueIsSendable
        self.indicator = indicator
    }
}

// MARK: - Composer

/// A `" · "`-separated marker on the composer's bottom border.
public struct PagerComposerFlag: Sendable, Equatable, Hashable {
    public var label: String
    public var foreground: TerminalColor?
    public var isBold: Bool

    public init(label: String, foreground: TerminalColor? = nil, isBold: Bool = false) {
        self.label = label
        self.foreground = foreground
        self.isBold = isBold
    }
}

public struct PagerComposerState: Sendable, Equatable, Hashable {
    public var text: String
    public var cursorCharacterOffset: Int?
    public var isFocused: Bool
    public var cursorVisible: Bool
    /// Two columns wide by contract — `"❯ "`, `"! "`, `"● "`, `"? "`.
    public var prefix: String
    public var placeholder: String
    /// Inlined into the top border, right-aligned three cells from the edge.
    public var title: String?
    /// Left group of the bottom border.
    public var modelName: String?
    /// Reasoning effort for the active model, rendered as a parenthetical after
    /// the model name — `Grok Build (xhigh)` (`agent_view/render.rs:2344-2347`).
    /// `nil` on models that have no selectable effort.
    public var reasoningEffort: String?
    public var flags: [PagerComposerFlag]
    /// Right group of the bottom border.
    public var isMultiline: Bool
    public var showBorders: Bool
    /// Hard cap on the whole box including both border rows. The caller passes
    /// `area.height / 2`, mirroring `render.rs:887`.
    public var maximumHeight: Int

    public init(
        text: String = "",
        cursorCharacterOffset: Int? = nil,
        isFocused: Bool = true,
        cursorVisible: Bool = true,
        prefix: String = PagerGlyphs.promptArrow,
        placeholder: String = "Build anything",
        title: String? = nil,
        modelName: String? = nil,
        reasoningEffort: String? = nil,
        flags: [PagerComposerFlag] = [],
        isMultiline: Bool = false,
        showBorders: Bool = true,
        maximumHeight: Int = 8
    ) {
        self.text = text
        self.cursorCharacterOffset = cursorCharacterOffset
        self.isFocused = isFocused
        self.cursorVisible = cursorVisible
        self.prefix = prefix
        self.placeholder = placeholder
        self.title = title
        self.modelName = modelName
        self.reasoningEffort = reasoningEffort
        self.flags = flags
        self.isMultiline = isMultiline
        self.showBorders = showBorders
        self.maximumHeight = max(1, maximumHeight)
    }

    /// What the bottom border actually prints for the model: the name, plus the
    /// effort in parentheses when the model has one.
    public var modelDisplay: String? {
        guard let modelName, !modelName.isEmpty else { return nil }
        guard let effort = reasoningEffort?.trimmingCharacters(in: .whitespaces),
              !effort.isEmpty
        else { return modelName }
        return "\(modelName) (\(effort))"
    }
}

// MARK: - Slash completion menu

public struct PagerCompletionRow: Sendable, Equatable, Hashable {
    public var label: String
    public var summary: String
    public var isAvailable: Bool

    public init(label: String, summary: String, isAvailable: Bool = true) {
        self.label = label
        self.summary = summary
        self.isAvailable = isAvailable
    }
}

public struct PagerCompletionMenu: Sendable, Equatable, Hashable {
    public var rows: [PagerCompletionRow]
    public var selectedIndex: Int?
    public var scrollOffset: Int

    public init(rows: [PagerCompletionRow], selectedIndex: Int? = nil, scrollOffset: Int = 0) {
        self.rows = rows
        self.selectedIndex = selectedIndex
        self.scrollOffset = scrollOffset
    }

    public var isEmpty: Bool { rows.isEmpty }

    /// `MAX_DROPDOWN_ROWS = 6` (`views/slash_dropdown.rs:24`).
    public var visibleRowCount: Int {
        min(rows.count, PagerLayoutMetrics.maxDropdownRows)
    }
}

// MARK: - Shortcuts bar (bottom row)

public struct PagerShortcutHint: Sendable, Equatable, Hashable {
    /// Joined with `"/"` when a hint has several equivalent keys.
    public var keys: [String]
    public var label: String
    /// Pinned hints survive compaction (`shortcuts_bar.rs:274-302`).
    public var isPinned: Bool

    public init(keys: [String], label: String, isPinned: Bool = false) {
        self.keys = keys
        self.label = label
        self.isPinned = isPinned
    }

    public init(key: String, label: String, isPinned: Bool = false) {
        self.init(keys: [key], label: label, isPinned: isPinned)
    }

    var keyDisplay: String { keys.joined(separator: "/") }
}

public struct PagerShortcutsBar: Sendable, Equatable, Hashable {
    public var hints: [PagerShortcutHint]
    /// An armed double-press confirmation replaces the whole bar with
    /// `key:press again to {label}`.
    public var pendingKey: String?
    public var pendingLabel: String?
    /// `max_visible` for compaction; the agent view passes 5.
    public var maximumVisible: Int
    public var trailing: String?

    public init(
        hints: [PagerShortcutHint],
        pendingKey: String? = nil,
        pendingLabel: String? = nil,
        maximumVisible: Int = 5,
        trailing: String? = nil
    ) {
        self.hints = hints
        self.pendingKey = pendingKey
        self.pendingLabel = pendingLabel
        self.maximumVisible = max(1, maximumVisible)
        self.trailing = trailing
    }

    /// Pinned hints always survive; the remaining slots go to unpinned hints in
    /// original order. The reference appends the help hint last unconditionally,
    /// which callers model by pinning it.
    func effectiveHints() -> [PagerShortcutHint] {
        guard hints.count > maximumVisible else { return hints }
        let pinned = hints.filter(\.isPinned)
        var remaining = max(0, maximumVisible - pinned.count)
        var result: [PagerShortcutHint] = []
        for hint in hints {
            if hint.isPinned {
                result.append(hint)
            } else if remaining > 0 {
                result.append(hint)
                remaining -= 1
            }
        }
        return result
    }
}

// MARK: - Announcement banner

/// The single in-session announcement banner slot, plain data the renderer
/// paints without knowing where announcements come from. The composition
/// resolves the slot selection (critical wins over promo, first non-hidden),
/// expiry, hide-key state, and CTA usability through `OpenGrokAnnouncements`,
/// then hands the renderer this projection. Keeping the render module free of
/// the announcements dependency is what lets the banner slot live in the same
/// wave as the rest of the chrome (`OpenGrokPagerRender` cannot depend on
/// `OpenGrokAnnouncements` — see the wave-8 dep edge in `Package.swift`).
///
/// Layout mirrors `crates/codegen/xai-grok-pager/src/views/announcements.rs`:
/// critical is two rows (`! Title` + message), promo is one row. `dismissible`
/// (absent/`true` upstream) paints the `[hide]` button and `hide: /announcements
/// hide` affordance; `dismissible = false` pins the banner and reclaims those
/// columns. A promo's `message` is not painted on the banner — upstream paints
/// it on the roomier welcome hero — so only the CTA button (+ optional dim
/// `ctaCaption` for pinned promos) leads the row.
public struct PagerAnnouncementBanner: Sendable, Equatable, Hashable {
    public enum Severity: String, Sendable, Equatable, Hashable {
        case critical
        case promo
    }

    public var severity: Severity
    /// Trimmed non-empty or `nil`. Critical paints `! <title>` in error red.
    public var title: String?
    /// Trimmed non-empty or `nil`. The selection guarantees a visible message;
    /// `nil` here only when the critical has a title but no message body.
    public var message: String?
    /// `false` pins the banner (no hide affordances, columns reclaimed).
    public var dismissible: Bool
    /// Usable CTA `(label, url)` for a promo, trimmed non-empty. `nil` on a
    /// critical (it never paints a button) or a promo with no usable CTA.
    public var ctaLabel: String?
    public var ctaURL: String?
    /// Dim helper caption for a *pinned* promo (`dismissible == false`).
    /// Dismissible promos keep `Ctrl+O` on YOLO, so they suppress the caption.
    public var ctaCaption: String?

    public init(
        severity: PagerAnnouncementBanner.Severity,
        title: String? = nil,
        message: String? = nil,
        dismissible: Bool = true,
        ctaLabel: String? = nil,
        ctaURL: String? = nil,
        ctaCaption: String? = nil
    ) {
        self.severity = severity
        self.title = title
        self.message = message
        self.dismissible = dismissible
        self.ctaLabel = ctaLabel
        self.ctaURL = ctaURL
        self.ctaCaption = ctaCaption
    }

    /// Slot height in rows: 2 for a critical (title + message), 1 for a promo.
    public var height: Int {
        switch severity {
        case .critical: return 2
        case .promo: return 1
        }
    }
}

// MARK: - Frame state

public enum PagerScrollPosition: Sendable, Equatable, Hashable {
    case followTail
    case offset(Int)
}

public struct PagerRenderState: Sendable, Equatable {
    public var size: TerminalSize
    public var statusBar: PagerStatusBar?
    public var announcementBanner: PagerAnnouncementBanner?
    public var conversation: [PagerConversationItem]
    public var turnStatus: PagerTurnStatus?
    public var completions: PagerCompletionMenu?
    public var input: PagerComposerState
    public var shortcuts: PagerShortcutsBar?
    /// The Ctrl+G tasks pane (B1-t) — a full-width band between the status
    /// bar/banner and the transcript, upstream's `Constraint::Length(
    /// tasks_height)` slot (`views/agent.rs:210-213`). `nil` = hidden.
    public var tasksPane: PagerTasksPaneState?
    public var scrollPosition: PagerScrollPosition
    public var theme: PagerRenderTheme
    public var showScrollbar: Bool
    /// Index into `conversation` of the block the scrollback has selected.
    ///
    /// Non-nil is exactly "the scrollback holds the keyboard": the reference
    /// splits its binding table on `When::ScrollbackFocused` and marks the
    /// selected entry, and this one field carries both halves. The composer's
    /// own `input.isFocused` is what the caller clears alongside it.
    public var selectedBlockIndex: Int?
    /// Overlays layered above the transcript. A non-empty stack also holds
    /// input focus — see `PagerOverlayStack.handle`.
    public var overlays: PagerOverlayStack
    /// The animation clock this frame samples. Defaults to disabled, so a
    /// producer that never wires the tick loop renders the same still frame
    /// as before — see `PagerMotionSnapshot`.
    public var motion: PagerMotionSnapshot
    /// The DERIVED render-value compact flag — upstream's
    /// `AppearanceConfig.prompt.compact` (`appearance/config.rs:91-95`), which
    /// every compact paint site reads and which is never the user setting
    /// directly. Producers derive it per frame with `pagerEffectiveCompact`
    /// (user value OR'd with short-terminal auto-compact), the port of
    /// `AppView::apply_effective_compact` (`app_view.rs:2676-2690`). The cost
    /// of carrying the derived value rather than deriving here: a producer
    /// that passes the raw user value silently loses auto-compact on short
    /// terminals — the live composition's pass-through is pinned by the
    /// auto-compact toast test for exactly that reason.
    public var compactMode: Bool
    /// `[ui] show_timestamps` — upstream's `appearance.show_timestamps`
    /// (`appearance/config.rs:35`), which IS the user value: unlike
    /// `compactMode` there is no derivation, `set_timestamps_inner` copies the
    /// setting straight into the appearance snapshot (`setters.rs:1530-1541`).
    /// The SEMANTIC default is `true` (`TIMESTAMPS_DEFAULT`,
    /// `appearance/cache.rs:28`; `Option<bool>` unwrapped `.unwrap_or(true)`
    /// everywhere it is read). The `false` init default below exists so
    /// producers and tests from before this field render unchanged; the live
    /// composition's explicit pass-through — including the absent-config
    /// default of `true` — is pinned by `LiveTimestampsTests`.
    public var showTimestamps: Bool
    /// `[ui] show_timeline` — upstream's `appearance.show_timeline`
    /// (`appearance/config.rs:36-37`), the timeline sidebar's per-turn tick
    /// rail in place of the scrollbar. Like `showTimestamps` this IS the
    /// user value (`set_timeline_inner`, `setters.rs:1561-1572` copies it
    /// straight across); the rail's own eligibility gates (terminal width,
    /// turn count, scrollbar config, row budget) are applied at the paint
    /// site, never folded into this flag. The default is `false` — opt-in,
    /// `SHOW_TIMELINE_DEFAULT` (`ui_config.rs:392`) — so unlike
    /// `showTimestamps` the init default below is also the semantic one.
    public var showTimeline: Bool
    /// The privacy upsell banner claims the announcement-banner slot this
    /// frame — upstream's `BannerSlotParams.privacy_banner`
    /// (`agent_view/render.rs:717-724` at pin 650c1db7). Like upstream's
    /// render layer, a `true` here wins the slot even over a live
    /// announcement (the slot-ownership pin, `agent_view/links.rs:573-580`);
    /// the critical-outranks-privacy ranking lives with the PRODUCER, which
    /// must pass `false` while a critical announcement is live
    /// (`app_view.rs:4859-4863` — the live composition's pass-through).
    /// Default `false`: a producer that never wires the gate paints exactly
    /// the frames it painted before this field existed.
    public var privacyBanner: Bool

    public init(
        size: TerminalSize,
        statusBar: PagerStatusBar? = nil,
        announcementBanner: PagerAnnouncementBanner? = nil,
        conversation: [PagerConversationItem] = [],
        turnStatus: PagerTurnStatus? = nil,
        completions: PagerCompletionMenu? = nil,
        input: PagerComposerState = PagerComposerState(),
        shortcuts: PagerShortcutsBar? = nil,
        tasksPane: PagerTasksPaneState? = nil,
        scrollPosition: PagerScrollPosition = .followTail,
        theme: PagerRenderTheme = .default,
        showScrollbar: Bool = true,
        selectedBlockIndex: Int? = nil,
        overlays: PagerOverlayStack = PagerOverlayStack(),
        motion: PagerMotionSnapshot = PagerMotionSnapshot(),
        compactMode: Bool = false,
        showTimestamps: Bool = false,
        showTimeline: Bool = false,
        privacyBanner: Bool = false
    ) {
        self.overlays = overlays
        self.selectedBlockIndex = selectedBlockIndex
        self.size = size
        self.statusBar = statusBar
        self.announcementBanner = announcementBanner
        self.conversation = conversation
        self.turnStatus = turnStatus
        self.completions = completions
        self.input = input
        self.shortcuts = shortcuts
        self.tasksPane = tasksPane
        self.scrollPosition = scrollPosition
        self.theme = theme
        self.showScrollbar = showScrollbar
        self.motion = motion
        self.compactMode = compactMode
        self.showTimestamps = showTimestamps
        self.showTimeline = showTimeline
        self.privacyBanner = privacyBanner
    }
}

public struct PagerFrameLayout: Sendable, Equatable {
    public var bounds: TerminalRect
    public var statusBar: TerminalRect
    public var announcementBanner: TerminalRect
    public var conversation: TerminalRect
    public var completions: TerminalRect
    public var turnStatus: TerminalRect
    public var input: TerminalRect
    public var shortcuts: TerminalRect
    public var contentWidth: Int
    public var totalContentLines: Int
    public var visibleContentLines: Range<Int>
    public var scrollOffset: Int
    public var hasScrollbar: Bool
    /// The timeline rail this frame painted, exposed for mouse hit-testing
    /// the same way `overlays` is — upstream computes the geometry once per
    /// frame and both the renderer and `mouse.rs` consume that one value so
    /// they cannot drift (`views/timeline.rs:5-6`; the click resolution is
    /// `mouse.rs:415-427`). `nil` = no rail this frame (setting off, too few
    /// turns, narrow terminal, short viewport, or scrollbar config off), so
    /// a router never acts on a previous frame's geometry.
    public var timelineRail: PagerTimelineRail?
    /// The privacy banner's hit rects, on the rail's per-frame-geometry
    /// pattern above: what THIS frame painted, replaced wholesale every
    /// frame (upstream re-arms them on every draw,
    /// `agent_view/render.rs:2133-2148`, so a click never acts on stale
    /// geometry). `nil` = the banner did not own the slot this frame (flag
    /// off, or the slot shorter than its minimum height — upstream's
    /// `privacy_banner_owns_slot`, `render.rs:2128-2132`); inside, each
    /// button rect is `nil` when the row was too narrow to paint it whole.
    public var privacyBanner: PagerPrivacyBannerHitRects?
    /// The context-usage segment's painted cells in the status bar, for the
    /// hover router (B6: `context_bar.rs:4-8` — hover swaps tokens for a
    /// progress bar at the SAME width). `nil` when no context data painted.
    public var contextBar: TerminalRect?

    public init(
        bounds: TerminalRect,
        statusBar: TerminalRect,
        announcementBanner: TerminalRect,
        conversation: TerminalRect,
        completions: TerminalRect,
        turnStatus: TerminalRect,
        input: TerminalRect,
        shortcuts: TerminalRect,
        contentWidth: Int,
        totalContentLines: Int,
        visibleContentLines: Range<Int>,
        scrollOffset: Int,
        hasScrollbar: Bool,
        timelineRail: PagerTimelineRail? = nil,
        privacyBanner: PagerPrivacyBannerHitRects? = nil,
        contextBar: TerminalRect? = nil
    ) {
        self.bounds = bounds
        self.statusBar = statusBar
        self.announcementBanner = announcementBanner
        self.conversation = conversation
        self.completions = completions
        self.turnStatus = turnStatus
        self.input = input
        self.shortcuts = shortcuts
        self.contentWidth = contentWidth
        self.totalContentLines = totalContentLines
        self.visibleContentLines = visibleContentLines
        self.scrollOffset = scrollOffset
        self.hasScrollbar = hasScrollbar
        self.timelineRail = timelineRail
        self.privacyBanner = privacyBanner
        self.contextBar = contextBar
    }
}

public struct PagerRenderResult: Sendable, Equatable {
    public var buffer: CellBuffer
    public var layout: PagerFrameLayout
    public var cursorPosition: TerminalPoint?
    public var links: [LinkSpan]
    /// Screen geometry of every painted overlay, exposed for mouse hit-testing
    /// the same way `links` is. An overlay too small to draw publishes nothing,
    /// so a router never acts on a previous frame's bounds.
    public var overlays: [PagerOverlayBounds]

    public init(
        buffer: CellBuffer,
        layout: PagerFrameLayout,
        cursorPosition: TerminalPoint?,
        links: [LinkSpan] = [],
        overlays: [PagerOverlayBounds] = []
    ) {
        self.buffer = buffer
        self.layout = layout
        self.cursorPosition = cursorPosition
        self.links = links
        self.overlays = overlays
    }

    /// The topmost overlay containing a screen position, if any.
    public func overlay(atX x: Int, y: Int) -> PagerOverlayBounds? {
        overlays.last { $0.hitTest(x: x, y: y) }
    }

    public func snapshot(includeTrailingSpaces: Bool = false) -> String {
        guard buffer.width > 0, buffer.height > 0 else { return "" }
        var rows: [String] = []
        rows.reserveCapacity(buffer.height)
        for y in buffer.area.top..<buffer.area.bottom {
            var row = ""
            for x in buffer.area.left..<buffer.area.right {
                guard let cell = buffer.cell(x: x, y: y), !cell.skip else { continue }
                row += cell.grapheme
            }
            if !includeTrailingSpaces {
                while row.last == " " {
                    row.removeLast()
                }
            }
            rows.append(row)
        }
        return rows.joined(separator: "\n")
    }
}

public struct PagerRenderEngine: Sendable {
    public init() {}

    public func render(_ state: PagerRenderState) -> PagerRenderResult {
        renderPagerFrame(state)
    }
}

public enum PagerRenderer {
    public static func render(_ state: PagerRenderState) -> PagerRenderResult {
        renderPagerFrame(state)
    }
}
