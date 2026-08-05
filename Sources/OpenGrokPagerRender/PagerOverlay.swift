import Foundation
import OpenGrokTerminalCore

// MARK: - Presentation

/// Sizing for a floating centered modal, mirroring `ModalSizing`
/// (`views/modal_window.rs:105-136`).
public struct PagerModalSizing: Sendable, Equatable, Hashable {
    public var widthFraction: Double
    public var maximumWidth: Int
    public var minimumWidth: Int
    public var verticalMargin: Int
    public var horizontalPadding: Int
    public var verticalPadding: Int
    public var footerLines: Int

    public init(
        widthFraction: Double = 0.9,
        maximumWidth: Int = 140,
        minimumWidth: Int = 60,
        verticalMargin: Int = 7,
        horizontalPadding: Int = 2,
        verticalPadding: Int = 2,
        footerLines: Int = 2
    ) {
        self.widthFraction = widthFraction
        self.maximumWidth = maximumWidth
        self.minimumWidth = minimumWidth
        self.verticalMargin = verticalMargin
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.footerLines = footerLines
    }

    /// `ModalSizing::default()` / `large()`.
    public static let large = PagerModalSizing()

    /// `ModalSizing::medium()` (`modal_window.rs:141-151`) — picker lists.
    public static let medium = PagerModalSizing(
        widthFraction: 0.60,
        maximumWidth: 120,
        minimumWidth: 44,
        verticalMargin: 4,
        horizontalPadding: 2,
        verticalPadding: 1,
        footerLines: 2
    )

    /// The help modal's own sizing (`views/shortcuts_help.rs:1129-1142`).
    public static let help = PagerModalSizing(
        widthFraction: 0.70,
        maximumWidth: 80,
        minimumWidth: 44,
        verticalMargin: 4,
        horizontalPadding: 2,
        verticalPadding: 1,
        footerLines: 2
    )

    /// `compute_modal_dims` (`modal_window.rs:631-641`), then centered.
    ///
    /// Returns `nil` on the reference's bail-out branch — a popup narrower than
    /// 20 columns or shorter than 6 rows is not drawn at all, and callers must
    /// drop any cached hit-test bounds when that happens (`:301-309`).
    public func frame(in area: TerminalRect) -> TerminalRect? {
        guard area.width > 0, area.height > 0 else { return nil }
        let ceiling = min(max(0, area.width - 4), maximumWidth)
        let preferred = Int((Double(area.width) * widthFraction).rounded(.down))
        let width = min(max(min(preferred, ceiling), minimumWidth), area.width)
        let height = max(0, area.height - verticalMargin * 2)
        guard width >= 20, height >= 6 else { return nil }
        return TerminalRect(
            x: area.x + (area.width - width) / 2,
            y: area.y + (area.height - height) / 2,
            width: width,
            height: height
        )
    }
}

/// The three overlay shapes the reference actually has. See spec §16.0 — a port
/// that collapses these into one gets the permission prompt visibly wrong.
public enum PagerOverlayPresentation: Sendable, Equatable, Hashable {
    /// Floating bordered popup (`render_modal_window`).
    case centeredModal(PagerModalSizing)
    /// Borderless block in the prompt area with a `┃` accent rail
    /// (`overlay_list.rs`, `permission_view.rs`).
    case bottomSheet
    /// Takeover of the region above the composer (welcome screen).
    case fullScreen
}

// MARK: - Footer hints

/// One footer hint. The reference packs key and label into a single string and
/// splits at the first space (`modal_window.rs:685-690`); carrying them apart
/// makes the same render unambiguous for labels that contain spaces.
public struct PagerOverlayHint: Sendable, Equatable, Hashable {
    public var key: String
    public var label: String

    public init(key: String, label: String) {
        self.key = key
        self.label = label
    }

    /// `"Esc close"` — the form the reference stores.
    public var display: String {
        label.isEmpty ? key : "\(key) \(label)"
    }
}

// MARK: - List overlay

public struct PagerListRow: Sendable, Equatable, Hashable {
    public var id: String
    public var label: String
    /// Right-aligned meta column, painted in `gray` (`picker.rs:1090-1100`).
    public var detail: String?
    /// Indented sub-line beneath the label (`DESC_INDENT = 4`, `picker.rs:900`).
    public var summary: String?
    public var isSelectable: Bool
    /// Section headers render as a bold label followed by a `─` rule and are
    /// skipped by cursor movement (`picker.rs:1240-1259`).
    public var isHeader: Bool

    public init(
        id: String,
        label: String,
        detail: String? = nil,
        summary: String? = nil,
        isSelectable: Bool = true,
        isHeader: Bool = false
    ) {
        self.id = id
        self.label = label
        self.detail = detail
        self.summary = summary
        self.isSelectable = isHeader ? false : isSelectable
        self.isHeader = isHeader
    }
}

/// The reusable list-selection primitive: a title, optionally filterable rows,
/// a `❯` cursor, and enter/esc semantics.
///
/// The cursor glyph is the reference's *dropdown* marker (`slash_dropdown.rs`,
/// spec §13) rather than the picker's background-only selection
/// (`picker.rs:944-947`); the selected row still gets the `bg_visual` band, so
/// the two cues reinforce rather than replace each other.
public struct PagerListOverlay: Sendable, Equatable, Hashable {
    public var rows: [PagerListRow]
    public var isFilterable: Bool
    public var filterQuery: String
    /// Index into `filteredRows`, not `rows`.
    public var selectedIndex: Int
    public var scrollOffset: Int
    /// `picker.rs:2039-2045`.
    public var emptyMessage: String

    public init(
        rows: [PagerListRow],
        isFilterable: Bool = true,
        filterQuery: String = "",
        selectedIndex: Int = 0,
        scrollOffset: Int = 0,
        emptyMessage: String = "No matches"
    ) {
        self.rows = rows
        self.isFilterable = isFilterable
        self.filterQuery = filterQuery
        self.selectedIndex = selectedIndex
        self.scrollOffset = scrollOffset
        self.emptyMessage = emptyMessage
        clampSelection()
    }

    /// Rows after filtering. An empty query keeps everything, headers included;
    /// a non-empty query drops headers because a section label that no longer
    /// heads anything is noise.
    public var filteredRows: [PagerListRow] {
        let needle = filterQuery.lowercased()
        guard isFilterable, !needle.isEmpty else { return rows }
        return rows.filter { row in
            guard !row.isHeader else { return false }
            let haystack = ([row.label, row.detail ?? "", row.summary ?? ""])
                .joined(separator: " ")
                .lowercased()
            return pagerFuzzyMatches(needle: needle, haystack: haystack)
        }
    }

    public var selectedRow: PagerListRow? {
        let visible = filteredRows
        guard visible.indices.contains(selectedIndex) else { return nil }
        return visible[selectedIndex]
    }

    mutating func clampSelection() {
        let visible = filteredRows
        guard !visible.isEmpty else {
            selectedIndex = 0
            scrollOffset = 0
            return
        }
        selectedIndex = min(max(selectedIndex, 0), visible.count - 1)
        if !visible[selectedIndex].isSelectable {
            // Land on the nearest selectable row, searching forward then back.
            if let forward = visible[selectedIndex...].firstIndex(where: \.isSelectable) {
                selectedIndex = forward
            } else if let back = visible[...selectedIndex].lastIndex(where: \.isSelectable) {
                selectedIndex = back
            }
        }
        scrollOffset = max(0, scrollOffset)
    }

    mutating func moveSelection(by delta: Int) {
        let visible = filteredRows
        guard !visible.isEmpty else { return }
        var index = selectedIndex
        let step = delta > 0 ? 1 : -1
        for _ in 0..<abs(delta) {
            var next = index + step
            while visible.indices.contains(next), !visible[next].isSelectable {
                next += step
            }
            guard visible.indices.contains(next) else { break }
            index = next
        }
        selectedIndex = index
    }
}

/// Case-insensitive subsequence match — the cheap stand-in for the reference's
/// nucleo fuzzy matcher (`slash/matcher.rs`). Ranking is not reproduced;
/// filtered rows keep their original order.
func pagerFuzzyMatches(needle: String, haystack: String) -> Bool {
    guard !needle.isEmpty else { return true }
    var cursor = haystack.startIndex
    for character in needle {
        guard let found = haystack[cursor...].firstIndex(of: character) else { return false }
        cursor = haystack.index(after: found)
    }
    return true
}

// MARK: - Workflows overlay

/// One agent in a run's roster, as `/workflows` shows it.
public struct PagerWorkflowAgent: Sendable, Equatable, Hashable {
    public var name: String
    /// `running`, `ok`, `failed`, `cancelled`, or a terminal reason such as
    /// `budget_exceeded`.
    public var state: String
    public var phase: String?
    public var tokensUsed: UInt64

    public init(name: String, state: String, phase: String? = nil, tokensUsed: UInt64 = 0) {
        self.name = name
        self.state = state
        self.phase = phase
        self.tokensUsed = tokensUsed
    }
}

/// One run in the dashboard. Mirrors the columns of the reference's `/workflows`
/// run dashboard — display name, phase, agent roster, progress, result
/// (`docs/user-guide/04-slash-commands.md`, `/workflows`).
public struct PagerWorkflowRow: Sendable, Equatable, Hashable {
    public var runID: String
    /// The display name. Upstream numbers duplicate handles (`review-changes-2`)
    /// and never surfaces internal run ids in commands; this carries whatever
    /// the caller resolved.
    public var name: String
    public var status: String
    public var phase: String?
    public var agentsFinished: Int
    /// The run's agent-call budget — the denominator upstream shows as progress.
    public var agentBudget: UInt64
    public var tokensUsed: UInt64
    public var message: String?
    public var result: String?
    public var agents: [PagerWorkflowAgent]

    public init(
        runID: String,
        name: String,
        status: String,
        phase: String? = nil,
        agentsFinished: Int = 0,
        agentBudget: UInt64 = 0,
        tokensUsed: UInt64 = 0,
        message: String? = nil,
        result: String? = nil,
        agents: [PagerWorkflowAgent] = []
    ) {
        self.runID = runID
        self.name = name
        self.status = status
        self.phase = phase
        self.agentsFinished = agentsFinished
        self.agentBudget = agentBudget
        self.tokensUsed = tokensUsed
        self.message = message
        self.result = result
        self.agents = agents
    }
}

/// The `/workflows` run dashboard: active and retained runs, with a per-run
/// detail view reached by `enter` and left by `esc`.
///
/// This is a *run* dashboard, not a catalog of saved workflow definitions —
/// the distinction upstream draws explicitly.
public struct PagerWorkflowsOverlay: Sendable, Equatable, Hashable {
    public var rows: [PagerWorkflowRow]
    public var selectedIndex: Int
    public var scrollOffset: Int
    /// `true` while the selected run's detail view is open. `esc` closes the
    /// detail first and the overlay second, so a user never loses the dashboard
    /// by pressing escape once.
    public var isDetailOpen: Bool
    public var emptyMessage: String

    public init(
        rows: [PagerWorkflowRow],
        selectedIndex: Int = 0,
        scrollOffset: Int = 0,
        isDetailOpen: Bool = false,
        emptyMessage: String = "No workflow runs"
    ) {
        self.rows = rows
        self.selectedIndex = selectedIndex
        self.scrollOffset = scrollOffset
        self.isDetailOpen = isDetailOpen
        self.emptyMessage = emptyMessage
        clampSelection()
    }

    public var selectedRow: PagerWorkflowRow? {
        rows.indices.contains(selectedIndex) ? rows[selectedIndex] : nil
    }

    mutating func clampSelection() {
        guard !rows.isEmpty else {
            selectedIndex = 0
            scrollOffset = 0
            isDetailOpen = false
            return
        }
        selectedIndex = min(max(selectedIndex, 0), rows.count - 1)
        scrollOffset = max(0, scrollOffset)
    }

    mutating func moveSelection(by delta: Int) {
        guard !rows.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), rows.count - 1)
    }

    /// The lines the detail view renders for the selected run.
    public var detailLines: [String] {
        guard let row = selectedRow else { return [] }
        var lines = [
            "run:      \(row.runID)",
            "workflow: \(row.name)",
            "status:   \(row.status)",
        ]
        if let phase = row.phase { lines.append("phase:    \(phase)") }
        lines.append("agents:   \(row.agentsFinished) done of \(row.agentBudget) budget")
        if row.tokensUsed > 0 { lines.append("tokens:   ~\(row.tokensUsed)") }
        if let message = row.message { lines.append("message:  \(message)") }
        if !row.agents.isEmpty {
            lines.append("")
            lines.append("agents")
            for agent in row.agents {
                var line = "  \(agent.name) — \(agent.state)"
                if let phase = agent.phase { line += " [\(phase)]" }
                if agent.tokensUsed > 0 { line += " ~\(agent.tokensUsed)t" }
                lines.append(line)
            }
        }
        if let result = row.result {
            lines.append("")
            lines.append("result")
            lines.append("  \(result)")
        }
        return lines
    }
}

// MARK: - Text overlay

/// A scrollable body of pre-styled lines — `/help` output, session info.
public struct PagerTextOverlay: Sendable, Equatable, Hashable {
    public var lines: [PagerStyledLine]
    public var scrollOffset: Int

    public init(lines: [PagerStyledLine], scrollOffset: Int = 0) {
        self.lines = lines
        self.scrollOffset = scrollOffset
    }
}

// MARK: - Welcome overlay

public struct PagerWelcomeMenuItem: Sendable, Equatable, Hashable {
    public var id: String
    /// Right-flush key hint, e.g. `"ctrl+s"`. Empty for click-only rows.
    public var key: String
    public var label: String

    public init(id: String, key: String, label: String) {
        self.id = id
        self.key = key
        self.label = label
    }
}

/// The braille logo + hero box shown when a session starts with no history
/// (`views/welcome/`).
public struct PagerWelcomeOverlay: Sendable, Equatable, Hashable {
    public var productName: String
    public var version: String
    public var subtitle: String
    public var menu: [PagerWelcomeMenuItem]
    public var selectedIndex: Int

    public init(
        productName: String = "Open Grok Beta",
        version: String = "",
        subtitle: String = "Thanks for trying Open Grok, give feedback with /feedback!",
        menu: [PagerWelcomeMenuItem] = [],
        selectedIndex: Int = 0
    ) {
        self.productName = productName
        self.version = version
        self.subtitle = subtitle
        self.menu = menu
        self.selectedIndex = selectedIndex
    }
}

/// `assets/logo/logo07.txt` and `logo05.txt`. Blanks are U+2800 BRAILLE PATTERN
/// BLANK, not U+0020 — substituting spaces would change the column count.
public enum PagerWelcomeLogo {
    public static let full: [String] = [
        "⠀⠀⠀⠀⠀⠀⣀⣀⡀⠀⠀⠀⢀⠄",
        "⠀⠀⠀⣠⣾⠿⠛⠛⠛⠛⢀⡴⠁⠀",
        "⠀⠀⣼⡟⠁⠀⠀⠀⢀⡴⠻⣿⡀⠀",
        "⠀⠀⣿⡇⠀⠀⠀⠔⠁⠀⠀⣿⡇⠀",
        "⠀⠀⢹⣷⠀⠀⠀⠀⠀⢀⣴⡿⠀⠀",
        "⠀⢀⠞⠁⠠⢶⣶⣶⣶⠿⠋⠀⠀⠀",
        "⠐⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀"
    ]

    public static let small: [String] = [
        "⠀⠀⠀⣀⣤⣤⣀⠀⠀⡠",
        "⠀⢀⡾⠋⠁⠀⢁⢴⡎⠀",
        "⠀⢸⡇⠀⠀⠐⠁⢀⣿⠀",
        "⠀⢈⠗⢀⣀⣀⣠⡾⠃⠀",
        "⠐⠁⠀⠈⠉⠉⠉⠀⠀⠀"
    ]

    /// `SMALL_LOGO_MIN_HEIGHT = 22`, `FULL_LOGO_MIN_HEIGHT = 26`
    /// (`welcome/logo.rs:19-36`).
    public static let smallMinimumHeight = 22
    public static let fullMinimumHeight = 26

    /// `HERO_BOX_MIN_WIDTH = 90` (`welcome/hero_box.rs:14`).
    public static let heroBoxMinimumWidth = 90

    public static func art(forHeight height: Int) -> [String]? {
        if height >= fullMinimumHeight { return full }
        if height >= smallMinimumHeight { return small }
        return nil
    }
}

// MARK: - Permission prompt

public struct PagerDiffLine: Sendable, Equatable, Hashable {
    public enum Kind: Sendable, Equatable, Hashable {
        case added
        case removed
        case context
    }

    public var kind: Kind
    public var text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

public enum PagerPermissionDecision: String, Sendable, Equatable, Hashable, Codable {
    case allowOnce
    case allowSession
    case deny
}

public struct PagerPermissionOption: Sendable, Equatable, Hashable {
    public var decision: PagerPermissionDecision
    public var label: String

    public init(decision: PagerPermissionDecision, label: String) {
        self.decision = decision
        self.label = label
    }
}

/// A tool mutation awaiting the user's approval.
///
/// Nothing here reaches back into the tool pipeline: the component renders the
/// request and reports a `PagerPermissionDecision`, and
/// `PagerPermissionCoordinator` is what joins the two.
public struct PagerPermissionRequest: Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var toolName: String
    /// File the tool would mutate, painted in `theme.path`.
    public var targetPath: String?
    /// Free-form second line — a shell command, an MCP argument summary.
    public var detail: String?
    public var diffPreview: [PagerDiffLine]
    public var options: [PagerPermissionOption]

    public init(
        id: String = UUID().uuidString,
        toolName: String,
        targetPath: String? = nil,
        detail: String? = nil,
        diffPreview: [PagerDiffLine] = [],
        options: [PagerPermissionOption] = PagerPermissionRequest.defaultOptions
    ) {
        self.id = id
        self.toolName = toolName
        self.targetPath = targetPath
        self.detail = detail
        self.diffPreview = diffPreview
        self.options = options.isEmpty ? PagerPermissionRequest.defaultOptions : options
    }

    /// The reference's option set for an edit permission
    /// (`workspace/src/permission/prompter.rs:380-406`), shortened to the three
    /// the integration owner asked for.
    public static let defaultOptions: [PagerPermissionOption] = [
        PagerPermissionOption(decision: .allowSession, label: "Yes, allow all edits during this session"),
        PagerPermissionOption(decision: .allowOnce, label: "Yes"),
        PagerPermissionOption(decision: .deny, label: "No, and tell Grok what to do differently")
    ]

    /// `acp_handler/permissions.rs:245-319` title shapes.
    public var title: String {
        if let targetPath, !targetPath.isEmpty {
            return "Allow \(toolName) to \(targetPath)?"
        }
        return "Allow \(toolName)?"
    }
}

public struct PagerPermissionPrompt: Sendable, Equatable, Hashable {
    public var request: PagerPermissionRequest
    public var selectedIndex: Int
    public var diffScrollOffset: Int

    public init(request: PagerPermissionRequest, selectedIndex: Int = 0, diffScrollOffset: Int = 0) {
        self.request = request
        self.selectedIndex = selectedIndex
        self.diffScrollOffset = diffScrollOffset
    }

    /// Diff rows shown before truncation, mirroring the reference's collapsed
    /// argument budget (`MCP_ARGS_COLLAPSED_ROWS = 5`, `permission_view.rs:415`).
    public static let collapsedDiffRows = 5
}

// MARK: - Overlay

public enum PagerOverlayContent: Sendable, Equatable, Hashable {
    case list(PagerListOverlay)
    case text(PagerTextOverlay)
    case welcome(PagerWelcomeOverlay)
    case permission(PagerPermissionPrompt)
    case workflows(PagerWorkflowsOverlay)
}

public struct PagerOverlay: Sendable, Equatable, Hashable {
    public var id: String
    public var title: String
    public var presentation: PagerOverlayPresentation
    public var hints: [PagerOverlayHint]
    public var content: PagerOverlayContent
    /// The permission prompt sets this false: the reference deliberately makes
    /// `Esc` a no-op there, because dismissing an approval has no safe default
    /// (`app/agent_view/interactions.rs:70-166`).
    public var dismissOnEscape: Bool
    /// Whether the overlay takes input focus. The reference separates *visible*
    /// from *focused* (`OverlayState`, `views/overlay.rs:52-57`) — the welcome
    /// screen, for one, is painted over the transcript while the composer stays
    /// live beneath it.
    public var capturesInput: Bool

    public init(
        id: String,
        title: String,
        presentation: PagerOverlayPresentation,
        hints: [PagerOverlayHint] = [],
        content: PagerOverlayContent,
        dismissOnEscape: Bool = true,
        capturesInput: Bool = true
    ) {
        self.id = id
        self.title = title
        self.presentation = presentation
        self.hints = hints
        self.content = content
        self.dismissOnEscape = dismissOnEscape
        self.capturesInput = capturesInput
    }
}

// MARK: - Factories

extension PagerOverlay {
    /// The reusable list-selection modal.
    public static func list(
        id: String,
        title: String,
        rows: [PagerListRow],
        isFilterable: Bool = true,
        sizing: PagerModalSizing = .medium,
        hints: [PagerOverlayHint]? = nil
    ) -> PagerOverlay {
        let defaultHints: [PagerOverlayHint] = [
            PagerOverlayHint(key: "↑/↓", label: "nav"),
            PagerOverlayHint(key: "Enter", label: "select"),
            PagerOverlayHint(key: "Esc", label: "close")
        ]
        return PagerOverlay(
            id: id,
            title: title,
            presentation: .centeredModal(sizing),
            hints: hints ?? defaultHints,
            content: .list(PagerListOverlay(rows: rows, isFilterable: isFilterable))
        )
    }

    /// `/model` — the embedded catalog as a filterable list, with the active
    /// model pre-selected and marked in the meta column.
    ///
    /// The render layer deliberately does not know what a model *is*: the
    /// caller passes ids and provider labels, and handles the resulting
    /// `.selected` outcome. There is no live model-switch path in the current
    /// composition, so that handler is a no-op for now — see
    /// `INTEGRATION-overlays.md`.
    public static func modelPicker(
        id: String = "model",
        title: String = "Select model",
        models: [(id: String, provider: String)],
        currentModelID: String? = nil
    ) -> PagerOverlay {
        let rows = models.map { model in
            PagerListRow(
                id: model.id,
                label: model.id,
                detail: model.id == currentModelID ? "\(model.provider)  ✓" : model.provider
            )
        }
        var overlay = PagerOverlay.list(id: id, title: title, rows: rows)
        if case .list(var list) = overlay.content,
           let current = currentModelID,
           let index = rows.firstIndex(where: { $0.id == current }) {
            list.selectedIndex = index
            overlay.content = .list(list)
        }
        return overlay
    }

    /// `/workflows` — the live run dashboard.
    ///
    /// A modal rather than a bottom sheet: it is a workspace the user navigates
    /// (rows, then a detail view), not a prompt to answer, and upstream makes it
    /// fullscreen-only for the same reason.
    public static func workflows(
        id: String = "workflows",
        title: String = "Workflow Runs",
        rows: [PagerWorkflowRow]
    ) -> PagerOverlay {
        PagerOverlay(
            id: id,
            title: title,
            presentation: .centeredModal(.medium),
            hints: [
                PagerOverlayHint(key: "↑/↓", label: "select"),
                PagerOverlayHint(key: "Enter", label: "detail"),
                PagerOverlayHint(key: "p/r/x", label: "pause/resume/stop"),
                PagerOverlayHint(key: "Esc", label: "close")
            ],
            content: .workflows(PagerWorkflowsOverlay(rows: rows))
        )
    }

    /// `/help` — a modal, not a transcript dump (spec §16.5).
    public static func help(
        id: String = "help",
        title: String = "Keyboard Shortcuts",
        lines: [PagerStyledLine]
    ) -> PagerOverlay {
        PagerOverlay(
            id: id,
            title: title,
            presentation: .centeredModal(.help),
            hints: [
                PagerOverlayHint(key: "↑/↓", label: "scroll"),
                PagerOverlayHint(key: "Esc", label: "close")
            ],
            content: .text(PagerTextOverlay(lines: lines))
        )
    }

    /// Session info — the same text modal under a different title.
    public static func sessionInfo(
        id: String = "session-info",
        title: String = "Session",
        lines: [PagerStyledLine]
    ) -> PagerOverlay {
        PagerOverlay(
            id: id,
            title: title,
            presentation: .centeredModal(.medium),
            hints: [
                PagerOverlayHint(key: "↑/↓", label: "scroll"),
                PagerOverlayHint(key: "Esc", label: "close")
            ],
            content: .text(PagerTextOverlay(lines: lines))
        )
    }

    /// Pass `capturesInput: false` to keep the composer live beneath the
    /// welcome screen, the way the reference's welcome view does — its menu
    /// rows are app-level chords, not overlay-focused keys.
    public static func welcome(
        id: String = "welcome",
        _ welcome: PagerWelcomeOverlay,
        capturesInput: Bool = true
    ) -> PagerOverlay {
        PagerOverlay(
            id: id,
            title: "",
            presentation: .fullScreen,
            hints: [],
            content: .welcome(welcome),
            capturesInput: capturesInput
        )
    }

    /// The permission modal component. Not wired to any tool pipeline — see
    /// `PagerPermissionCoordinator`.
    public static func permission(
        _ request: PagerPermissionRequest,
        id: String? = nil
    ) -> PagerOverlay {
        PagerOverlay(
            id: id ?? "permission:\(request.id)",
            title: request.title,
            presentation: .bottomSheet,
            hints: [
                PagerOverlayHint(key: "↑/↓", label: "nav"),
                PagerOverlayHint(key: "1-9", label: "select"),
                PagerOverlayHint(key: "Enter", label: "confirm")
            ],
            content: .permission(PagerPermissionPrompt(request: request)),
            dismissOnEscape: false
        )
    }
}

// MARK: - Focus routing

public enum PagerOverlayOutcome: Sendable, Equatable {
    /// No overlay is active; the key belongs to the composer.
    case ignored
    /// Consumed, state changed, repaint.
    case redraw
    /// Consumed with no state change — swallowed so it cannot reach the
    /// composer (the reference's "an active modal consumes everything" rule).
    case consumed
    case dismissed(id: String)
    case selected(id: String, rowID: String)
    case permission(id: String, requestID: String, decision: PagerPermissionDecision)
}

/// The overlay stack, layered above the transcript.
///
/// Focus rule: a non-empty stack consumes **every** key. `Esc` dismisses the
/// topmost dismissable overlay; when the stack empties the composer regains
/// focus on its own, because `handle` starts returning `.ignored`.
public struct PagerOverlayStack: Sendable, Equatable {
    public private(set) var overlays: [PagerOverlay]

    public init(_ overlays: [PagerOverlay] = []) {
        self.overlays = overlays
    }

    public var isEmpty: Bool { overlays.isEmpty }
    /// True while some overlay holds input focus. A stack that only contains
    /// non-capturing overlays is painted but leaves the composer focused.
    public var isActive: Bool { overlays.contains(where: \.capturesInput) }
    public var topmost: PagerOverlay? { overlays.last }
    /// The overlay keys route to — the topmost *capturing* one.
    public var focused: PagerOverlay? { overlays.last(where: \.capturesInput) }

    public mutating func push(_ overlay: PagerOverlay) {
        if let existing = overlays.firstIndex(where: { $0.id == overlay.id }) {
            overlays.remove(at: existing)
        }
        overlays.append(overlay)
    }

    @discardableResult
    public mutating func dismissTopmost() -> PagerOverlay? {
        overlays.popLast()
    }

    @discardableResult
    public mutating func dismiss(id: String) -> PagerOverlay? {
        guard let index = overlays.firstIndex(where: { $0.id == id }) else { return nil }
        return overlays.remove(at: index)
    }

    public mutating func removeAll() {
        overlays.removeAll()
    }

    public func contains(id: String) -> Bool {
        overlays.contains { $0.id == id }
    }

    /// Route a key to the topmost overlay.
    ///
    /// `viewportHeight` is the row budget the overlay's scrollable body has;
    /// page keys move by that many rows. Callers can read it back off
    /// `PagerOverlayBounds.content.height` from the previous frame.
    public mutating func handle(_ event: KeyEvent, viewportHeight: Int = 10) -> PagerOverlayOutcome {
        guard let index = overlays.lastIndex(where: \.capturesInput) else { return .ignored }
        var overlay = overlays[index]

        if event.key == .escape, event.modifiers.isEmpty {
            // A run's detail view is a layer inside the overlay, not a second
            // overlay, so escape has to unwind it first — otherwise one keypress
            // from the detail view throws away the dashboard too.
            if case .workflows(var runs) = overlay.content, runs.isDetailOpen {
                runs.isDetailOpen = false
                runs.scrollOffset = 0
                overlay.content = .workflows(runs)
                overlays[index] = overlay
                return .redraw
            }
            guard overlay.dismissOnEscape else { return .consumed }
            overlays.remove(at: index)
            return .dismissed(id: overlay.id)
        }

        let outcome: PagerOverlayOutcome
        switch overlay.content {
        case .list(var list):
            outcome = handleList(&list, overlay: overlay, event: event, viewportHeight: viewportHeight)
            overlay.content = .list(list)
        case .text(var text):
            outcome = handleText(&text, event: event, viewportHeight: viewportHeight)
            overlay.content = .text(text)
        case .welcome(var welcome):
            outcome = handleWelcome(&welcome, overlay: overlay, event: event)
            overlay.content = .welcome(welcome)
        case .permission(var prompt):
            outcome = handlePermission(&prompt, overlay: overlay, event: event)
            overlay.content = .permission(prompt)
        case .workflows(var runs):
            outcome = handleWorkflows(&runs, overlay: overlay, event: event, viewportHeight: viewportHeight)
            overlay.content = .workflows(runs)
        }

        overlays[index] = overlay
        return outcome
    }

    private func handleList(
        _ list: inout PagerListOverlay,
        overlay: PagerOverlay,
        event: KeyEvent,
        viewportHeight: Int
    ) -> PagerOverlayOutcome {
        let page = max(1, viewportHeight)
        switch event.key {
        case .up:
            list.moveSelection(by: -1)
            return .redraw
        case .down:
            list.moveSelection(by: 1)
            return .redraw
        case .pageUp:
            list.moveSelection(by: -page)
            return .redraw
        case .pageDown:
            list.moveSelection(by: page)
            return .redraw
        case .home:
            list.selectedIndex = 0
            list.clampSelection()
            return .redraw
        case .end:
            list.selectedIndex = max(0, list.filteredRows.count - 1)
            list.clampSelection()
            return .redraw
        case .enter:
            guard let row = list.selectedRow, row.isSelectable else { return .consumed }
            return .selected(id: overlay.id, rowID: row.id)
        case .backspace:
            guard list.isFilterable, !list.filterQuery.isEmpty else { return .consumed }
            list.filterQuery.removeLast()
            list.selectedIndex = 0
            list.scrollOffset = 0
            list.clampSelection()
            return .redraw
        case .char(let character):
            // `j`/`k` navigate only when there is no filter field competing for
            // the keystroke, matching the reference's vim gate (`picker.rs`).
            if !list.isFilterable, event.modifiers.isEmpty {
                if character == "j" { list.moveSelection(by: 1); return .redraw }
                if character == "k" { list.moveSelection(by: -1); return .redraw }
            }
            guard list.isFilterable,
                  event.modifiers.subtracting(.shift).isEmpty,
                  !character.isNewline
            else { return .consumed }
            list.filterQuery.append(character)
            list.selectedIndex = 0
            list.scrollOffset = 0
            list.clampSelection()
            return .redraw
        default:
            return .consumed
        }
    }

    private func handleWorkflows(
        _ runs: inout PagerWorkflowsOverlay,
        overlay: PagerOverlay,
        event: KeyEvent,
        viewportHeight: Int
    ) -> PagerOverlayOutcome {
        let page = max(1, viewportHeight)
        if runs.isDetailOpen {
            // In the detail view the arrows scroll the run's own body rather
            // than moving between runs.
            let maximum = max(0, runs.detailLines.count - page)
            func scroll(by delta: Int) -> PagerOverlayOutcome {
                let target = min(max(0, runs.scrollOffset + delta), maximum)
                guard target != runs.scrollOffset else { return .consumed }
                runs.scrollOffset = target
                return .redraw
            }
            switch event.key {
            case .up: return scroll(by: -1)
            case .down: return scroll(by: 1)
            case .pageUp: return scroll(by: -page)
            case .pageDown: return scroll(by: page)
            case .home: return scroll(by: -maximum)
            case .end: return scroll(by: maximum)
            case .char(let character) where event.modifiers.isEmpty:
                switch character {
                case "j": return scroll(by: 1)
                case "k": return scroll(by: -1)
                // `p` pauses, `r` resumes, `x` stops. The overlay reports the
                // intent as a row selection and the session performs it: the
                // render layer has no way to reach a run, and giving it one
                // would put session control in the frame model.
                case "p", "r", "x":
                    guard let row = runs.selectedRow else { return .consumed }
                    return .selected(id: overlay.id, rowID: "\(character):\(row.runID)")
                default: return .consumed
                }
            default:
                return .consumed
            }
        }
        switch event.key {
        case .up:
            runs.moveSelection(by: -1)
            return .redraw
        case .down:
            runs.moveSelection(by: 1)
            return .redraw
        case .pageUp:
            runs.moveSelection(by: -page)
            return .redraw
        case .pageDown:
            runs.moveSelection(by: page)
            return .redraw
        case .home:
            runs.selectedIndex = 0
            runs.clampSelection()
            return .redraw
        case .end:
            runs.selectedIndex = max(0, runs.rows.count - 1)
            runs.clampSelection()
            return .redraw
        case .enter:
            guard runs.selectedRow != nil else { return .consumed }
            runs.isDetailOpen = true
            runs.scrollOffset = 0
            return .redraw
        case .char(let character) where event.modifiers.isEmpty:
            switch character {
            case "j": runs.moveSelection(by: 1); return .redraw
            case "k": runs.moveSelection(by: -1); return .redraw
            case "p", "r", "x":
                guard let row = runs.selectedRow else { return .consumed }
                return .selected(id: overlay.id, rowID: "\(character):\(row.runID)")
            default: return .consumed
            }
        default:
            return .consumed
        }
    }

    private func handleText(
        _ text: inout PagerTextOverlay,
        event: KeyEvent,
        viewportHeight: Int
    ) -> PagerOverlayOutcome {
        let page = max(1, viewportHeight)
        let maximum = max(0, text.lines.count - page)
        func scroll(by delta: Int) -> PagerOverlayOutcome {
            let target = min(max(0, text.scrollOffset + delta), maximum)
            guard target != text.scrollOffset else { return .consumed }
            text.scrollOffset = target
            return .redraw
        }
        switch event.key {
        case .up: return scroll(by: -1)
        case .down: return scroll(by: 1)
        case .pageUp: return scroll(by: -page)
        case .pageDown: return scroll(by: page)
        case .home:
            guard text.scrollOffset != 0 else { return .consumed }
            text.scrollOffset = 0
            return .redraw
        case .end:
            guard text.scrollOffset != maximum else { return .consumed }
            text.scrollOffset = maximum
            return .redraw
        case .char(let character) where event.modifiers.isEmpty:
            switch character {
            case "j": return scroll(by: 1)
            case "k": return scroll(by: -1)
            case "g": return scroll(by: -maximum)
            case "G": return scroll(by: maximum)
            default: return .consumed
            }
        default:
            return .consumed
        }
    }

    private func handleWelcome(
        _ welcome: inout PagerWelcomeOverlay,
        overlay: PagerOverlay,
        event: KeyEvent
    ) -> PagerOverlayOutcome {
        guard !welcome.menu.isEmpty else { return .consumed }
        switch event.key {
        case .up:
            welcome.selectedIndex = max(0, welcome.selectedIndex - 1)
            return .redraw
        case .down:
            welcome.selectedIndex = min(welcome.menu.count - 1, welcome.selectedIndex + 1)
            return .redraw
        case .enter:
            guard welcome.menu.indices.contains(welcome.selectedIndex) else { return .consumed }
            return .selected(id: overlay.id, rowID: welcome.menu[welcome.selectedIndex].id)
        default:
            return .consumed
        }
    }

    private func handlePermission(
        _ prompt: inout PagerPermissionPrompt,
        overlay: PagerOverlay,
        event: KeyEvent
    ) -> PagerOverlayOutcome {
        let options = prompt.request.options
        func select(_ index: Int) -> PagerOverlayOutcome {
            guard options.indices.contains(index) else { return .consumed }
            return .permission(
                id: overlay.id,
                requestID: prompt.request.id,
                decision: options[index].decision
            )
        }
        switch event.key {
        case .up:
            prompt.selectedIndex = max(0, prompt.selectedIndex - 1)
            return .redraw
        case .down:
            prompt.selectedIndex = min(max(0, options.count - 1), prompt.selectedIndex + 1)
            return .redraw
        case .enter:
            return select(prompt.selectedIndex)
        case .char(let character) where event.modifiers.isEmpty:
            // Digits select directly, as in `interactions.rs:96-104`.
            if let digit = character.wholeNumberValue, (1...9).contains(digit) {
                return select(digit - 1)
            }
            if character == "j" {
                prompt.selectedIndex = min(max(0, options.count - 1), prompt.selectedIndex + 1)
                return .redraw
            }
            if character == "k" {
                prompt.selectedIndex = max(0, prompt.selectedIndex - 1)
                return .redraw
            }
            return .consumed
        default:
            return .consumed
        }
    }
}

// MARK: - Permission coordinator

/// Joins an `async` tool-pipeline caller to the render loop.
///
/// The caller `await`s `decision(for:)`, which suspends without touching the
/// renderer. The controller polls `currentRequest` each frame to decide whether
/// to push the overlay, and calls `resolve(requestID:decision:)` when the user
/// answers — so the render loop never blocks on a decision, and a queued second
/// request surfaces as soon as the first is answered.
public actor PagerPermissionCoordinator {
    private struct Waiter {
        var request: PagerPermissionRequest
        var continuation: CheckedContinuation<PagerPermissionDecision, Never>
    }

    private var queue: [Waiter] = []
    private var presenter: (@Sendable (PagerPermissionRequest?) async -> Void)?

    public init() {}

    /// The request the overlay should currently display, or `nil`.
    public var currentRequest: PagerPermissionRequest? { queue.first?.request }

    public var pendingCount: Int { queue.count }

    /// Whether anything is listening. A caller with no presenter would suspend
    /// forever, so the mutation gate uses this to fail closed instead.
    public var hasPresenter: Bool { presenter != nil }

    /// Called whenever the head of the queue changes, so a controller can push
    /// or pop the overlay without polling.
    public func setPresenter(_ presenter: (@Sendable (PagerPermissionRequest?) async -> Void)?) async {
        self.presenter = presenter
        await presenter?(queue.first?.request)
    }

    /// Suspend until the user decides. Safe to call from any task.
    public func decision(for request: PagerPermissionRequest) async -> PagerPermissionDecision {
        let wasIdle = queue.isEmpty
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<PagerPermissionDecision, Never>) in
            queue.append(Waiter(request: request, continuation: continuation))
            if wasIdle, let presenter {
                Task { await presenter(request) }
            }
        }
        return result
    }

    /// Answer the head request. Ignored when `requestID` is not the head, so a
    /// stale key from a previous overlay cannot resolve the wrong request.
    public func resolve(requestID: String, decision: PagerPermissionDecision) {
        guard let head = queue.first, head.request.id == requestID else { return }
        queue.removeFirst()
        head.continuation.resume(returning: decision)
        let next = queue.first?.request
        if let presenter {
            Task { await presenter(next) }
        }
    }

    /// Fail every outstanding request — session teardown, turn cancellation.
    public func resolveAll(with decision: PagerPermissionDecision = .deny) {
        let waiters = queue
        queue.removeAll()
        for waiter in waiters {
            waiter.continuation.resume(returning: decision)
        }
        if let presenter {
            Task { await presenter(nil) }
        }
    }
}
