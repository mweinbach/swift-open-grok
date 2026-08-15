import Foundation
import OpenGrokTerminalCore
import OpenGrokTextArea

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
///
/// Extra kinds (`memorySearch`, `integrationSearch`, `useTool`, `skill`) match
/// `ToolCallBlock::from_name` / specialized blocks in the pin so the live seam
/// can route them later without inventing painters here.
public enum PagerToolKind: Sendable, Equatable, Hashable {
    case read
    case edit
    case create
    case execute
    case search
    case list
    case fetch
    case webSearch
    case memorySearch
    case integrationSearch
    case useTool
    case skill
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
        case .memorySearch: return "Memory Search"
        case .integrationSearch: return "Search Tools"
        // UseTool paints titleized server/action segments in the specialized
        // painter; generic fallback shows the bare tool name like Other.
        case .useTool: return nil
        case .skill: return "Skill"
        case .generic: return nil
        }
    }

    /// Whether the argument after the verb is a filesystem path, which the
    /// reference paints in `theme.path` rather than the body color.
    var argumentIsPath: Bool {
        switch self {
        case .read, .edit, .create, .list: return true
        case .execute, .search, .fetch, .webSearch,
             .memorySearch, .integrationSearch, .useTool, .skill, .generic:
            return false
        }
    }

    /// Classify a raw tool name the way the reference's block factory does
    /// (`ToolCallBlock::from_name`, pin `tool/mod.rs`).
    public static func infer(fromToolNamed name: String) -> PagerToolKind {
        switch name.lowercased() {
        case "run_terminal_command", "run_terminal_cmd", "bash", "shell", "execute",
             "run", "run_command", "terminal":
            return .execute
        case "read_file", "read", "view", "cat":
            return .read
        case "search_replace", "edit", "edit_file", "apply_patch", "strreplace",
             "str_replace", "hashline_edit":
            return .edit
        // write → Edit with "Creating " prefix upstream; port keeps a distinct
        // kind so the existing generic painter can emit the Creating verb.
        case "write", "write_file", "create", "create_file":
            return .create
        case "list_dir", "ls", "list", "list_directory":
            return .list
        // glob is Search in the pin (not ListDir).
        case "grep", "search", "glob", "ripgrep", "search_files", "codebase_search":
            return .search
        case "web_fetch", "fetch", "http", "curl":
            return .fetch
        case "web_search", "websearch", "search_web":
            return .webSearch
        case "search_tool":
            return .integrationSearch
        case "use_tool":
            return .useTool
        case "memory_search":
            return .memorySearch
        case "skill":
            return .skill
        default:
            return .generic
        }
    }
}

public struct PagerToolCard: Sendable, Equatable, Hashable {
    public var name: String
    public var kind: PagerToolKind
    /// The single argument summarized in the header — a path for file tools, a
    /// command for execute, a query for search. Factory-built cards put the
    /// display form here so existing painters keep working without reading
    /// `headerText`.
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
    /// Full raw tool arguments as received (JSON or plain string). Empty when
    /// the producer only supplied a pre-summarized `input`.
    public var rawInput: String
    /// Explicit display header argument when a producer wants it distinct from
    /// `input`. Empty/`nil` means "use `input`".
    public var headerText: String?

    public init(
        name: String,
        kind: PagerToolKind? = nil,
        input: String = "",
        output: String? = nil,
        detail: String? = nil,
        state: PagerToolState = .pending,
        isExpanded: Bool = false,
        finishedAt: TimeInterval? = nil,
        rawInput: String = "",
        headerText: String? = nil
    ) {
        self.name = name
        self.kind = kind ?? PagerToolKind.infer(fromToolNamed: name)
        self.input = input
        self.output = output
        self.detail = detail
        self.state = state
        self.isExpanded = isExpanded
        self.finishedAt = finishedAt
        self.rawInput = rawInput
        self.headerText = headerText
    }

    /// Build a card from a tool name + raw arguments the way the ACP tracker
    /// factory does: infer kind, extract path/command/description/url/query,
    /// prefer description over command for execute headers, peel a redundant
    /// `cd <cwd> &&` from the *header only*, and elide cwd from displayed paths.
    ///
    /// Full `rawInput` is retained on the card; only `input`/`headerText` are
    /// display-peeled.
    public static func make(
        name: String,
        rawInput: String = "",
        cwd: String? = nil,
        output: String? = nil,
        state: PagerToolState = .pending,
        isExpanded: Bool = false,
        finishedAt: TimeInterval? = nil,
        detail: String? = nil
    ) -> PagerToolCard {
        let kind = PagerToolKind.infer(fromToolNamed: name)
        let fields = PagerToolRawFields.parse(rawInput)
        let display = fields.displayHeader(kind: kind, rawInput: rawInput, cwd: cwd)
        return PagerToolCard(
            name: name,
            kind: kind,
            input: display,
            output: output,
            detail: detail,
            state: state,
            isExpanded: isExpanded,
            finishedAt: finishedAt,
            rawInput: rawInput,
            headerText: display
        )
    }
}

/// Parsed tool-argument fields used only by `PagerToolCard.make`.
private struct PagerToolRawFields {
    var path: String?
    var command: String?
    var description: String?
    var url: String?
    var query: String?
    var toolName: String?
    var skillName: String?

    static func parse(_ raw: String) -> PagerToolRawFields {
        var fields = PagerToolRawFields()
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any]
        else {
            return fields
        }

        func string(keys: String...) -> String? {
            for key in keys {
                if let value = dict[key] as? String {
                    let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { return t }
                }
            }
            return nil
        }

        fields.path = string(
            keys: "file_path", "filePath", "target_file", "path", "target_directory"
        )
        fields.command = string(keys: "command")
        fields.description = string(keys: "description")
        fields.url = string(keys: "url")
        fields.query = string(keys: "query", "pattern", "glob_pattern")
        fields.toolName = string(keys: "tool_name", "toolName")
        fields.skillName = string(keys: "skill", "name", "skill_name")
        return fields
    }

    func displayHeader(kind: PagerToolKind, rawInput: String, cwd: String?) -> String {
        let plain = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let looksLikeJSON = plain.first == "{" || plain.first == "["

        switch kind {
        case .execute:
            // Description-first (tracker execute path); peel cd only for the
            // command form that lands in the header.
            if let description, !description.isEmpty {
                return description
            }
            if let command, !command.isEmpty {
                return Self.stripRedundantSessionCd(command, cwd: cwd)
            }
            if !looksLikeJSON, !plain.isEmpty {
                return Self.stripRedundantSessionCd(plain, cwd: cwd)
            }
            return ""

        case .read, .edit, .create, .list:
            if let path {
                return Self.elideCwd(from: path, cwd: cwd)
            }
            if !looksLikeJSON, !plain.isEmpty {
                return Self.elideCwd(from: plain, cwd: cwd)
            }
            return ""

        case .fetch:
            if let url { return url }
            if !looksLikeJSON, !plain.isEmpty { return plain }
            return ""

        case .search, .webSearch, .memorySearch, .integrationSearch:
            if let query { return query }
            if !looksLikeJSON, !plain.isEmpty { return plain }
            return ""

        case .useTool:
            if let toolName { return toolName }
            if !looksLikeJSON, !plain.isEmpty { return plain }
            return ""

        case .skill:
            if let skillName { return skillName }
            if let description { return description }
            if !looksLikeJSON, !plain.isEmpty { return plain }
            return ""

        case .generic:
            // Prefer a human field over dumping partial JSON.
            if let description { return description }
            if let path { return Self.elideCwd(from: path, cwd: cwd) }
            if let query { return query }
            if let url { return url }
            if let command {
                return Self.stripRedundantSessionCd(command, cwd: cwd)
            }
            if !looksLikeJSON, !plain.isEmpty { return plain }
            return ""
        }
    }

    /// Display-only peel of a leading `cd <session cwd> &&|;` (subset of
    /// `strip_redundant_session_cd` in the tools util crate). Keeps the full
    /// command available via `rawInput`.
    static func stripRedundantSessionCd(_ command: String, cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return command }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: \.isNewline)
        else { return command }

        var rest = trimmed[...]
        // Optional single outer `( … )`.
        if rest.first == "(", rest.last == ")", rest.count >= 2 {
            let inner = rest.dropFirst().dropLast()
            if !inner.contains(where: { $0 == "(" || $0 == ")" }) {
                rest = inner.trimmingCharacters(in: .whitespaces)[...]
            }
        }

        guard let cdWord = takeShellWord(&rest), cdWord.lowercased() == "cd" else {
            return command
        }
        // Optional Windows `cd /d`.
        if let flag = peekShellWord(rest), flag == "/d" || flag == "/D" {
            _ = takeShellWord(&rest)
        }
        guard let pathToken = takePathToken(&rest) else { return command }
        guard let unquoted = unquotePathToken(pathToken) else { return command }
        guard isAbsoluteShaped(unquoted), isAbsoluteShaped(cwd) else { return command }
        guard pathsEqualForDisplay(unquoted, cwd) else { return command }

        rest = rest.drop(while: { $0.isWhitespace })
        if rest.hasPrefix("&&") {
            rest = rest.dropFirst(2).drop(while: { $0.isWhitespace })
        } else if rest.first == ";" {
            rest = rest.dropFirst().drop(while: { $0.isWhitespace })
        } else {
            return command
        }
        let remainder = String(rest)
        return remainder.isEmpty ? command : remainder
    }

    static func elideCwd(from path: String, cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return path }
        let normalizedCwd = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        if path == normalizedCwd || path == normalizedCwd + "/" {
            return "."
        }
        let prefix = normalizedCwd + "/"
        if path.hasPrefix(prefix) {
            let rel = String(path.dropFirst(prefix.count))
            return rel.isEmpty ? "." : rel
        }
        return path
    }

    private static func isAbsoluteShaped(_ path: String) -> Bool {
        if path.hasPrefix("/") { return true }
        let utf8 = path.utf8
        if utf8.count >= 2 {
            let b0 = utf8[utf8.startIndex]
            let b1 = utf8[utf8.index(after: utf8.startIndex)]
            if (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(b0)
                || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(b0),
               b1 == UInt8(ascii: ":")
            {
                return true
            }
            if b0 == UInt8(ascii: "\\"), b1 == UInt8(ascii: "\\") {
                return true
            }
        }
        return false
    }

    private static func pathsEqualForDisplay(_ a: String, _ b: String) -> Bool {
        let aSegs = pathSegments(a)
        let bSegs = pathSegments(b)
        guard aSegs.count == bSegs.count else { return false }
        let caseInsensitive = isWindowsShaped(a) || isWindowsShaped(b)
        for (as_, bs) in zip(aSegs, bSegs) {
            if caseInsensitive {
                if as_.lowercased() != bs.lowercased() { return false }
            } else if as_ != bs {
                return false
            }
        }
        return true
    }

    private static func isWindowsShaped(_ s: String) -> Bool {
        let utf8 = s.utf8
        guard utf8.count >= 2 else { return false }
        let b0 = utf8[utf8.startIndex]
        let b1 = utf8[utf8.index(after: utf8.startIndex)]
        if ((UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(b0)
            || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(b0)),
           b1 == UInt8(ascii: ":")
        {
            return true
        }
        return b0 == UInt8(ascii: "\\") && b1 == UInt8(ascii: "\\")
    }

    private static func pathSegments(_ s: String) -> [Substring] {
        let trimmed = s.trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
        return trimmed.split { $0 == "/" || $0 == "\\" }.filter { !$0.isEmpty }
    }

    private static func peekShellWord(_ s: Substring) -> String? {
        var copy = s
        return takeShellWord(&copy)
    }

    private static func takeShellWord(_ s: inout Substring) -> String? {
        s = s.drop(while: { $0.isWhitespace })
        guard let first = s.first else { return nil }
        if first == "'" || first == "\"" { return nil }
        if let end = s.firstIndex(where: { $0.isWhitespace }) {
            let word = String(s[..<end])
            s = s[end...]
            return word.isEmpty ? nil : word
        }
        let word = String(s)
        s = s[s.endIndex...]
        return word.isEmpty ? nil : word
    }

    private static func takePathToken(_ s: inout Substring) -> String? {
        s = s.drop(while: { $0.isWhitespace })
        guard let first = s.first else { return nil }
        if first == "'" || first == "\"" {
            let quote = first
            s = s.dropFirst()
            guard let close = s.firstIndex(of: quote) else { return nil }
            let token = String(s[..<close])
            s = s[s.index(after: close)...]
            return String(quote) + token + String(quote)
        }
        var end = s.startIndex
        while end < s.endIndex {
            let ch = s[end]
            if ch.isWhitespace || ch == ";" { break }
            if ch == "&", s.index(after: end) < s.endIndex, s[s.index(after: end)] == "&" {
                break
            }
            end = s.index(after: end)
        }
        guard end > s.startIndex else { return nil }
        let token = String(s[..<end])
        s = s[end...]
        return token
    }

    private static func unquotePathToken(_ token: String) -> String? {
        guard let first = token.first else { return nil }
        if first == "'" || first == "\"" {
            guard token.count >= 2, token.last == first else { return nil }
            return String(token.dropFirst().dropLast())
        }
        return token
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

    /// Whether a mouse click may select this block. Mirrors upstream
    /// `BlockContent::is_selectable` for the cases this port paints:
    /// system messages are never navigable (`system.rs:88-90`), and
    /// separators are chrome, not entries. Tools / user / assistant /
    /// reasoning / error remain selectable.
    public var isMouseSelectable: Bool {
        switch self {
        case .separator:
            return false
        case .message(let message):
            return message.role != .system
        case .tool:
            return true
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
    /// UTF-8 caret. When `nil`, derived from `cursorCharacterOffset`.
    public var cursorUTF8: Int?
    public var selectionUTF8: Range<Int>?
    public var selectedText: String?
    public var textAreaState: TextAreaState
    public var scrollOverride: Int?
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
        cursorUTF8: Int? = nil,
        selectionUTF8: Range<Int>? = nil,
        selectedText: String? = nil,
        textAreaState: TextAreaState = TextAreaState(),
        scrollOverride: Int? = nil,
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
        self.cursorUTF8 = cursorUTF8
        self.selectionUTF8 = selectionUTF8
        self.selectedText = selectedText
        self.textAreaState = textAreaState
        self.scrollOverride = scrollOverride
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
    /// `[animation].wave_rows` — rows per accent-wave cycle
    /// (`appearance/config.rs:377`, clamped `max(1)` at
    /// `config.rs:1456`). Default matches `PagerMotion.defaultWaveRows` so
    /// producers that never wire the pager.toml reader paint the same wave
    /// span as before this field existed.
    public var waveRows: Int
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
    /// `[scrollback.display].sticky_headers` from `$OPENGROK_HOME/pager.toml`
    /// (`appearance/config.rs:158-160, 1429` at pin 650c1db7). Default
    /// **true** — absent key / absent file / producers that never wire the
    /// reader keep the forced-on behavior this field replaced. Compact
    /// still suppresses sticky regardless (`scrollback_pane.rs:395-401`).
    /// No env, no settings-modal row (`defs.rs` has none).
    public var stickyHeadersEnabled: Bool
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
    /// Active or persistent text-selection highlight to paint after the
    /// conversation base pass (`render_active_selection_overlay` /
    /// `render_persistent_selection_overlay`). `nil` = no text highlight.
    /// Sticky header rows are not drag-startable/selectable in this phase.
    public var textSelectionHighlight: PagerTextSelectionHighlight?
    /// Keyed table-selection sidecar for this frame. Table kinds paint only
    /// from a matching sidecar (plus live structural equality when the
    /// model still detects a grid); mismatch paints nothing — never a
    /// re-detected replacement grid or a linear sweep. `nil` = no table
    /// claim. Copy uses the same frozen sidecar; this field is how paint
    /// sees it (pin 650c1db7).
    public var tableSelectionGeometry: PagerTableSelectionGeometry?
    /// Preformatted FPS HUD snapshot for this frame (`FpsOverlay`). `nil` =
    /// HUD off / not painted. Carry the formatted body here, never
    /// `PagerFpsHud` itself (that type is mutable session state).
    public var fpsHud: PagerFpsHudOverlay?
    /// Transient toast (Copied!, etc.). Wins over `stickyToast` while set.
    /// Tick/expiry and focus-specific copy (mouse-off hint swap) are
    /// live-layer concerns — pass the already-chosen strings.
    public var toast: String?
    /// Sticky status banner (mouse-off hint, reconnecting). Shown when
    /// `toast` is nil. Default nil: producers that never wire a banner
    /// paint the frames they painted before this field existed.
    public var stickyToast: String?

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
        waveRows: Int = PagerMotion.defaultWaveRows,
        compactMode: Bool = false,
        stickyHeadersEnabled: Bool = true,
        showTimestamps: Bool = false,
        showTimeline: Bool = false,
        privacyBanner: Bool = false,
        textSelectionHighlight: PagerTextSelectionHighlight? = nil,
        tableSelectionGeometry: PagerTableSelectionGeometry? = nil,
        fpsHud: PagerFpsHudOverlay? = nil,
        toast: String? = nil,
        stickyToast: String? = nil
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
        self.waveRows = max(1, waveRows)
        self.compactMode = compactMode
        self.stickyHeadersEnabled = stickyHeadersEnabled
        self.showTimestamps = showTimestamps
        self.showTimeline = showTimeline
        self.privacyBanner = privacyBanner
        self.textSelectionHighlight = textSelectionHighlight
        self.tableSelectionGeometry = tableSelectionGeometry
        self.fpsHud = fpsHud
        self.toast = toast
        self.stickyToast = stickyToast
    }

    /// Message currently drawn in the toast slot: transient wins while
    /// set, otherwise sticky (`active_toast_message` without the
    /// focus-specific mouse-off copy swap — that swap is live-layer).
    public var activeToastMessage: String? {
        pagerActiveToastMessage(transient: toast, sticky: stickyToast)
    }
}

/// Transient wins while set; otherwise sticky. Focus-specific copy
/// selection (mouse-off scrollback vs prompt hint) is a live-layer
/// concern — pass the already-chosen sticky string.
public func pagerActiveToastMessage(transient: String?, sticky: String?) -> String? {
    if let transient { return transient }
    return sticky
}

/// Pad `message` for the toast slot, truncating with a trailing ellipsis
/// when it cannot fit (`fit_toast_text`, `agent_view/render.rs:4515-4526`
/// at pin 650c1db7). ` {msg} `; available width `< 5` yields `nil`.
public func pagerFitToastText(_ message: String, availableWidth: Int) -> String? {
    let maxMsgChars = max(0, availableWidth - 4)
    if maxMsgChars == 0 { return nil }
    if message.count <= maxMsgChars {
        return " \(message) "
    }
    var truncated = String(message.prefix(max(0, maxMsgChars - 1)))
    while let last = truncated.last, last.isWhitespace {
        truncated.removeLast()
    }
    return " \(truncated)… "
}

/// Fitted toast text plus the one-row bottom-right rect inside
/// `conversation`, or `nil` when the slot is too narrow / empty / zero
/// height (`render.rs:2007-2028`).
public struct PagerToastPaintPlan: Sendable, Equatable {
    public var text: String
    public var rect: TerminalRect

    public init(text: String, rect: TerminalRect) {
        self.text = text
        self.rect = rect
    }
}

public func pagerToastPaintPlan(
    message: String?,
    conversation: TerminalRect
) -> PagerToastPaintPlan? {
    guard conversation.height > 0, conversation.width > 0 else { return nil }
    guard let message, let text = pagerFitToastText(message, availableWidth: conversation.width)
    else { return nil }
    let width = text.count
    // `sb.right().saturating_sub(w + 1)` / `sb.bottom().saturating_sub(1)`.
    let x = max(0, conversation.right - (width + 1))
    let y = max(0, conversation.bottom - 1)
    return PagerToastPaintPlan(
        text: text,
        rect: TerminalRect(x: x, y: y, width: width, height: 1)
    )
}

/// Last-frame conversation click-to-select geometry — area, scroll offset,
/// painted content width, and per-block content starts/heights from the
/// exact layout that painted. Gap rows are deliberately outside every
/// `start..<start+height` so a click there selects nothing (upstream
/// `entry_at_content_y`, `scrollback/state/layout.rs:100-124`). Sticky
/// header rows route through `sticky.entryAtHeaderRow` first
/// (`entry_index_at_screen_row`, layout.rs:280-311). Not text-drag geometry.
public struct PagerConversationHitModel: Sendable, Equatable {
    public var conversation: TerminalRect
    public var scrollOffset: Int
    /// Painted text-column width (excludes accent/pad chrome and the
    /// scrollbar/rail gutter). Same value `renderConversation` / the rail
    /// use for `scrollbarX` / `railX` —
    /// `conversation.x + chromeWidth + contentWidth` is the first gutter
    /// column and must not arm click-to-select.
    public var contentWidth: Int
    public var blockStartLines: [Int]
    public var blockHeights: [Int]
    /// Sticky header layout from THIS frame — header hits map via
    /// `entryAtHeaderRow`; empty when sticky is gated off or inactive.
    public var sticky: PagerStickyHeaderLayout
    /// Toast slot painted this frame (`frame_occluder_rects` push at
    /// `render.rs:2022-2027`). `nil` when no toast fitted. Mouse must not
    /// fall through these cells onto transcript selection.
    public var toastOccluder: TerminalRect?

    public init(
        conversation: TerminalRect,
        scrollOffset: Int,
        contentWidth: Int,
        blockStartLines: [Int],
        blockHeights: [Int],
        sticky: PagerStickyHeaderLayout = .empty,
        toastOccluder: TerminalRect? = nil
    ) {
        self.conversation = conversation
        self.scrollOffset = scrollOffset
        self.contentWidth = contentWidth
        self.blockStartLines = blockStartLines
        self.blockHeights = blockHeights
        self.sticky = sticky
        self.toastOccluder = toastOccluder
    }

    /// Exclusive screen X of the content/chrome band — first scrollbar or
    /// rail-gutter column. Clicks at or past this X are not transcript
    /// selection targets (upstream clears/handles `hit_scrollbar` before
    /// arming `pending_scrollback_click`, `mouse.rs:408-414`).
    public var selectableEndX: Int {
        conversation.x + PagerLayoutMetrics.chromeWidth + max(0, contentWidth)
    }

    /// True when `(x, y)` sits inside the conversation pane's content/chrome
    /// band and strictly before the scrollbar/rail gutter. Toast cells are
    /// excluded so a click there does not fall through to block select.
    public func containsSelectablePoint(x: Int, y: Int) -> Bool {
        guard conversation.contains(x: x, y: y) else { return false }
        if toastOccluder?.contains(x: x, y: y) == true { return false }
        return x < selectableEndX
    }

    /// True when `(x, y)` is the painted toast slot this frame.
    public func containsToastOccluder(x: Int, y: Int) -> Bool {
        toastOccluder?.contains(x: x, y: y) ?? false
    }

    /// Block index under `screenY`, or `nil` for gaps / outside / malformed.
    /// Header rows (including the post-pinned gap) use sticky mapping; content
    /// identity matches Rust: `contentY = viewportY + scrollOffset` after the
    /// header short-circuit (layout.rs:301-310).
    public func blockIndex(atScreenY screenY: Int) -> Int? {
        guard conversation.height > 0,
              screenY >= conversation.y,
              screenY < conversation.y + conversation.height
        else { return nil }

        let viewportY = screenY - conversation.y
        let headerRows = sticky.headerScreenRows
        if sticky.hasHeader, viewportY >= 0, viewportY < headerRows {
            return sticky.entryAtHeaderRow(viewportY)
        }

        return pagerConversationBlockIndex(
            screenY: screenY,
            conversation: conversation,
            scrollOffset: scrollOffset,
            blockStartLines: blockStartLines,
            blockHeights: blockHeights
        )
    }
}

/// One soft-wrapped (or empty) visual row of the composer, with UTF-8
/// offsets into the full draft. Soft wraps split mid-physical-line; hard
/// `\n` boundaries produce a new row. Ranges come from `composerWrapOptions`
/// / `wrapRanges`, not `wrapDisplayLinesWithRanges`.
public struct PagerComposerWrappedLine: Sendable, Equatable {
    /// Inclusive UTF-8 offset of this row's first byte in the draft.
    public var startOffset: Int
    /// Exclusive UTF-8 offset — past EOL / soft-wrap boundary.
    public var endOffset: Int
    public var text: String

    public init(startOffset: Int, endOffset: Int, text: String) {
        self.startOffset = max(0, startOffset)
        self.endOffset = max(self.startOffset, endOffset)
        self.text = text
    }

    public var utf8Range: Range<Int> { startOffset..<endOffset }
}

/// Result of hit-testing a screen cell against a painted composer.
public enum PagerComposerHitResult: Sendable, Equatable {
    /// Inside the pane but on border / prefix / gutter chrome — focus only.
    case focusOnly
    /// Inside the text content columns. The controller forwards the mouse
    /// event to `TextArea.handleMouse`; this case does not carry an offset.
    case content
}

/// Last-painted composer click geometry — full input pane, the inner text
/// box `renderComposer` paints into, and wrap rows from the same
/// `projectComposerGeometry` snapshot the paint used. Published
/// replace-wholesale with the other mouse caches so a click never maps
/// against an unpainted layout.
///
/// Prefix/chrome sit outside the content rect. Collapsed-unfocused clicks
/// are focus-only at the router (see `isFocused`).
public struct PagerComposerHitModel: Sendable, Equatable {
    /// Full composer chrome rect (`PagerFrameLayout.input`).
    public var pane: TerminalRect
    /// Inner text box (excludes top/bottom border rows and left/right border
    /// + gutter columns). Prefix cells live at the leading edge of this rect.
    public var textArea: TerminalRect
    /// Columns reserved for the prompt prefix (`PagerGlyphs.promptArrowWidth`).
    public var prefixWidth: Int
    /// Wrap width passed to `composerWrapOptions`.
    public var textWidth: Int
    /// First wrapped-line index painted at `textArea.y` — TextArea effective
    /// scroll from the same projection the paint used.
    public var firstVisibleRow: Int
    public var lines: [PagerComposerWrappedLine]
    /// Last-painted focus. Unfocused (collapsed) pane clicks are focus-only.
    public var isFocused: Bool

    public init(
        pane: TerminalRect,
        textArea: TerminalRect,
        prefixWidth: Int,
        textWidth: Int,
        firstVisibleRow: Int,
        lines: [PagerComposerWrappedLine],
        isFocused: Bool = true
    ) {
        self.pane = pane
        self.textArea = textArea
        self.prefixWidth = max(0, prefixWidth)
        self.textWidth = max(1, textWidth)
        self.firstVisibleRow = max(0, firstVisibleRow)
        self.lines = lines
        self.isFocused = isFocused
    }

    /// Content rect passed to `TextArea.handleMouse` — prefix excluded.
    public var contentRect: TextAreaRect {
        TextAreaRect(
            x: textArea.x + prefixWidth,
            y: textArea.y,
            width: textWidth,
            height: textArea.height
        )
    }

    public func containsPane(x: Int, y: Int) -> Bool {
        pane.contains(x: x, y: y)
    }

    /// `nil` outside the pane; `.focusOnly` on border/prefix/gutter; `.content`
    /// for a cell inside the wrap/hit projection. Trap-free under empty
    /// models, zero-height text areas, and out-of-range rows.
    public func hit(x: Int, y: Int) -> PagerComposerHitResult? {
        guard pane.width > 0, pane.height > 0, pane.contains(x: x, y: y) else {
            return nil
        }
        guard textArea.width > 0, textArea.height > 0, textArea.contains(x: x, y: y) else {
            return .focusOnly
        }
        let contentX = textArea.x + prefixWidth
        guard x >= contentX else { return .focusOnly }
        let contentRight = contentX + textWidth
        guard x < contentRight else { return .focusOnly }

        let visualRow = y - textArea.y
        guard visualRow >= 0, visualRow < textArea.height else { return .focusOnly }
        return .content
    }
}

/// Map a display column onto a Character offset within one wrapped line.
/// Wide graphemes snap to their start (no mid-glyph offset); columns past
/// the line's display width clamp to `line.endOffset`.
public func pagerComposerCursorOffset(
    atDisplayColumn column: Int,
    line: PagerComposerWrappedLine
) -> Int {
    let target = max(0, column)
    var widthSoFar = 0
    var offset = line.startOffset
    for grapheme in line.text {
        let graphemeWidth = max(0, UnicodeDisplayWidth.width(ofGrapheme: String(grapheme)))
        if widthSoFar + graphemeWidth > target {
            return offset
        }
        widthSoFar += graphemeWidth
        offset += 1
    }
    return line.endOffset
}

/// Last-painted transcript scrollbar geometry — published only when the
/// scrollbar actually paints and the timeline rail is absent (upstream
/// `hit_scrollbar.set` / `.clear`, `agent_view/render.rs:1917-1926` at pin
/// 650c1db7). Routers consume this replace-wholesale cache so a click never
/// maps against a previous frame's gutter or against layout that has not
/// painted yet.
public struct PagerScrollbarHitModel: Sendable, Equatable {
    public var rect: TerminalRect
    public var totalContentLines: Int
    public var viewportHeight: Int
    /// Thumb height / start from the same paint math as
    /// `renderConversation` — useful for tests and drag diagnostics; the
    /// inverse helper does not need them at the call site.
    public var thumbHeight: Int
    public var thumbStart: Int

    public init(
        rect: TerminalRect,
        totalContentLines: Int,
        viewportHeight: Int,
        thumbHeight: Int,
        thumbStart: Int
    ) {
        self.rect = rect
        self.totalContentLines = totalContentLines
        self.viewportHeight = viewportHeight
        self.thumbHeight = thumbHeight
        self.thumbStart = thumbStart
    }

    public func contains(x: Int, y: Int) -> Bool {
        rect.contains(x: x, y: y)
    }

    /// Content scroll offset for a screen row — inverse of this frame's
    /// thumb paint (`pagerScrollbarOffset`).
    public func offset(atScreenY screenY: Int) -> Int {
        let cellIndex = screenY - rect.y
        return pagerScrollbarOffset(
            cellIndex: cellIndex,
            trackHeight: rect.height,
            total: totalContentLines,
            viewport: viewportHeight
        )
    }

    /// True when `screenY` is the bottom track cell that Rust's
    /// `ScrollbarClickResult::Bottom` / `goto_bottom` re-engages follow on
    /// (`scrollbar.rs:188-189`, `nav.rs:540-546`). A one-row track is Top
    /// only (`cell_index == 0` wins), so it never reports bottom.
    public func isBottomCell(atScreenY screenY: Int) -> Bool {
        let height = rect.height
        guard height > 1 else { return false }
        let cellIndex = screenY - rect.y
        return cellIndex > 0 && cellIndex >= height - 1
    }
}

/// Thumb height matching `renderConversation`'s paint
/// (`max(1, (viewport * viewport) / max(total, 1))`). Trap-free: empty /
/// non-positive inputs collapse to a 1-cell thumb.
public func pagerScrollbarThumbHeight(total: Int, viewport: Int) -> Int {
    let content = max(total, 1)
    let view = max(viewport, 0)
    guard view > 0 else { return 1 }
    return max(1, (view * view) / content)
}

/// Thumb start row matching `renderConversation`'s paint, clamped to the
/// track travel. Trap-free under zero travel / zero max offset.
public func pagerScrollbarThumbStart(
    scrollOffset: Int,
    total: Int,
    viewport: Int,
    trackHeight: Int
) -> Int {
    let thumbHeight = pagerScrollbarThumbHeight(total: total, viewport: viewport)
    let maximumOffset = max(0, total - max(0, viewport))
    let travel = max(0, trackHeight - thumbHeight)
    guard maximumOffset > 0, travel > 0 else { return 0 }
    return min(travel, (max(0, scrollOffset) * travel) / maximumOffset)
}

/// Map a scrollbar-track cell to a content scroll offset — exact inverse of
/// `renderConversation`'s thumb placement, with Rust's top/bottom edge
/// shortcuts (`scrollbar_click_to_offset`, `scrollbar.rs:173-207` at pin
/// 650c1db7: first cell → 0, last cell → max). Mid-track centers the thumb
/// on the clicked cell (JumpToClick) then inverts
/// `thumbStart = (offset * travel) / maxOffset`. Clamped / trap-free for
/// malformed inputs (`total <= viewport`, one-row track, negative cells,
/// zero track).
public func pagerScrollbarOffset(
    cellIndex: Int,
    trackHeight: Int,
    total: Int,
    viewport: Int
) -> Int {
    let track = max(0, trackHeight)
    guard track > 0 else { return 0 }
    let view = max(0, viewport)
    let content = max(0, total)
    let maximumOffset = max(0, content - view)
    guard maximumOffset > 0 else { return 0 }

    // First row → top (also wins a one-row track over the bottom arm).
    if cellIndex <= 0 { return 0 }
    // Last row → bottom.
    if cellIndex >= track - 1 { return maximumOffset }

    let thumbHeight = pagerScrollbarThumbHeight(total: content, viewport: view)
    let travel = max(0, track - thumbHeight)
    guard travel > 0 else { return 0 }

    let halfThumb = thumbHeight / 2
    let thumbStart = min(travel, max(0, cellIndex - halfThumb))
    return min(maximumOffset, (thumbStart * maximumOffset) / travel)
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
    /// Sticky header layout for THIS frame (`StickyHeaderLayout` from
    /// `compute_sticky_layout`). Empty when compact / gated off / scroll 0.
    public var sticky: PagerStickyHeaderLayout
    /// `sticky.headerScreenRows` — content paints below this band. Published
    /// so live page-scroll can call `pagerPageScrollRows` without recompute.
    public var headerScreenRows: Int
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
    /// Conversation click-to-select geometry from the layout THIS frame
    /// painted. `nil` only for synthetic layouts that never laid out a
    /// transcript (e.g. minimal host overlay scoping); a live frame always
    /// publishes it so a router never acts on a previous frame's starts.
    public var conversationHit: PagerConversationHitModel?
    /// Transcript scrollbar hit geometry from THIS frame's paint, or `nil`
    /// when the rail owns the gutter / the scrollbar did not paint
    /// (`hit_scrollbar` clear arm, `agent_view/render.rs:1924-1926`).
    public var scrollbarHit: PagerScrollbarHitModel?
    /// Composer click-to-focus / cursor-place geometry from THIS frame's
    /// paint. `nil` when the input slot is too small to paint (same gate as
    /// `renderComposer`).
    public var composerHit: PagerComposerHitModel?
    /// Linear transcript text-selection model from THIS frame's paint —
    /// replace-wholesale each frame so hits/copy never act on stale geometry
    /// (`RenderOutput.selection_model`, selection.rs / scrollback/render.rs).
    /// Includes off-screen line text/joiners for reconstruction; sticky header
    /// rows are not published as selectable (deferred sticky drag).
    public var textSelection: PagerTextSelectionModel?
    /// Toast occluder from THIS frame's paint (`frame_occluder_rects`).
    /// `nil` when no toast fitted. Same rect as
    /// `conversationHit?.toastOccluder` so mouse routers that only hold
    /// layout still see it.
    public var toastOccluder: TerminalRect?

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
        sticky: PagerStickyHeaderLayout = .empty,
        headerScreenRows: Int = 0,
        timelineRail: PagerTimelineRail? = nil,
        privacyBanner: PagerPrivacyBannerHitRects? = nil,
        contextBar: TerminalRect? = nil,
        conversationHit: PagerConversationHitModel? = nil,
        scrollbarHit: PagerScrollbarHitModel? = nil,
        composerHit: PagerComposerHitModel? = nil,
        textSelection: PagerTextSelectionModel? = nil,
        toastOccluder: TerminalRect? = nil
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
        self.sticky = sticky
        self.headerScreenRows = max(0, headerScreenRows)
        self.timelineRail = timelineRail
        self.privacyBanner = privacyBanner
        self.contextBar = contextBar
        self.conversationHit = conversationHit
        self.scrollbarHit = scrollbarHit
        self.composerHit = composerHit
        self.textSelection = textSelection
        self.toastOccluder = toastOccluder
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
