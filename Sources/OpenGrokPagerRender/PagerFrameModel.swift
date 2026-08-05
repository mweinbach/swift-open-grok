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

    public init(
        role: PagerMessageRole,
        text: String,
        isStreaming: Bool = false,
        styledLines: [PagerStyledLine] = [],
        duration: TimeInterval? = nil,
        isCollapsed: Bool = false
    ) {
        self.role = role
        self.text = text
        self.isStreaming = isStreaming
        self.styledLines = styledLines
        self.duration = duration
        self.isCollapsed = isCollapsed
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

    public init(
        name: String,
        kind: PagerToolKind? = nil,
        input: String = "",
        output: String? = nil,
        detail: String? = nil,
        state: PagerToolState = .pending,
        isExpanded: Bool = false
    ) {
        self.name = name
        self.kind = kind ?? PagerToolKind.infer(fromToolNamed: name)
        self.input = input
        self.output = output
        self.detail = detail
        self.state = state
        self.isExpanded = isExpanded
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
        backgroundTaskCount: Int = 0
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
    }
}

// MARK: - Turn status row

public struct PagerTurnStatus: Sendable, Equatable, Hashable {
    /// One of the reference's fixed activity labels — `"Thinking…"`,
    /// `"Responding…"`, `"Cancelling…"`, a running tool's title, and so on.
    /// The reference has no randomized verbs.
    public var label: String
    public var isCancelling: Bool
    /// Monotonic animation tick; the spinner advances every fourth tick.
    public var tick: Int
    public var elapsed: TimeInterval?
    public var tokenCount: Int?
    public var queuedPromptCount: Int
    /// Whether a bare Enter would force-send the top queued row.
    public var queueIsSendable: Bool

    public init(
        label: String,
        isCancelling: Bool = false,
        tick: Int = 0,
        elapsed: TimeInterval? = nil,
        tokenCount: Int? = nil,
        queuedPromptCount: Int = 0,
        queueIsSendable: Bool = false
    ) {
        self.label = label
        self.isCancelling = isCancelling
        self.tick = tick
        self.elapsed = elapsed
        self.tokenCount = tokenCount
        self.queuedPromptCount = queuedPromptCount
        self.queueIsSendable = queueIsSendable
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
        self.flags = flags
        self.isMultiline = isMultiline
        self.showBorders = showBorders
        self.maximumHeight = max(1, maximumHeight)
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

// MARK: - Frame state

public enum PagerScrollPosition: Sendable, Equatable, Hashable {
    case followTail
    case offset(Int)
}

public struct PagerRenderState: Sendable, Equatable {
    public var size: TerminalSize
    public var statusBar: PagerStatusBar?
    public var conversation: [PagerConversationItem]
    public var turnStatus: PagerTurnStatus?
    public var completions: PagerCompletionMenu?
    public var input: PagerComposerState
    public var shortcuts: PagerShortcutsBar?
    public var scrollPosition: PagerScrollPosition
    public var theme: PagerRenderTheme
    public var showScrollbar: Bool
    /// Overlays layered above the transcript. A non-empty stack also holds
    /// input focus — see `PagerOverlayStack.handle`.
    public var overlays: PagerOverlayStack

    public init(
        size: TerminalSize,
        statusBar: PagerStatusBar? = nil,
        conversation: [PagerConversationItem] = [],
        turnStatus: PagerTurnStatus? = nil,
        completions: PagerCompletionMenu? = nil,
        input: PagerComposerState = PagerComposerState(),
        shortcuts: PagerShortcutsBar? = nil,
        scrollPosition: PagerScrollPosition = .followTail,
        theme: PagerRenderTheme = .default,
        showScrollbar: Bool = true,
        overlays: PagerOverlayStack = PagerOverlayStack()
    ) {
        self.overlays = overlays
        self.size = size
        self.statusBar = statusBar
        self.conversation = conversation
        self.turnStatus = turnStatus
        self.completions = completions
        self.input = input
        self.shortcuts = shortcuts
        self.scrollPosition = scrollPosition
        self.theme = theme
        self.showScrollbar = showScrollbar
    }
}

public struct PagerFrameLayout: Sendable, Equatable {
    public var bounds: TerminalRect
    public var statusBar: TerminalRect
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

    public init(
        bounds: TerminalRect,
        statusBar: TerminalRect,
        conversation: TerminalRect,
        completions: TerminalRect,
        turnStatus: TerminalRect,
        input: TerminalRect,
        shortcuts: TerminalRect,
        contentWidth: Int,
        totalContentLines: Int,
        visibleContentLines: Range<Int>,
        scrollOffset: Int,
        hasScrollbar: Bool
    ) {
        self.bounds = bounds
        self.statusBar = statusBar
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
