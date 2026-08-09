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

// MARK: - User question prompt

/// One choice within a question (`QuestionOption`,
/// `xai-grok-tools/src/implementations/grok_build/ask_user_question/mod.rs:144-167`).
public struct PagerQuestionOption: Sendable, Equatable, Hashable {
    public var label: String
    public var description: String
    /// Shown while the option is focused; single-select only upstream.
    public var preview: String?

    public init(label: String, description: String = "", preview: String? = nil) {
        self.label = label
        self.description = description
        self.preview = preview
    }
}

/// One question of an `ask_user_question` questionnaire (`Question`,
/// `ask_user_question/mod.rs:169-200`).
public struct PagerQuestion: Sendable, Equatable, Hashable {
    public var text: String
    public var options: [PagerQuestionOption]
    public var isMultiSelect: Bool

    public init(text: String, options: [PagerQuestionOption], isMultiSelect: Bool = false) {
        self.text = text
        self.options = options
        self.isMultiSelect = isMultiSelect
    }
}

/// A questionnaire awaiting the user's answers. The render layer reports a
/// `PagerQuestionOutcome`; `PagerQuestionCoordinator` joins it to the tool.
public struct PagerQuestionRequest: Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var toolCallID: String
    public var questions: [PagerQuestion]

    public init(
        id: String = UUID().uuidString,
        toolCallID: String,
        questions: [PagerQuestion]
    ) {
        self.id = id
        self.toolCallID = toolCallID
        self.questions = questions
    }
}

/// The user's answer to one question. The initializer takes the first label
/// separately so an answer with no selection cannot be constructed — the
/// question view refuses Enter on an empty multi-select instead of producing
/// an empty answer here.
public struct PagerQuestionAnswer: Sendable, Equatable, Hashable {
    public var question: String
    public private(set) var labels: [String]
    /// Free text typed on the "Other" row (`annotations[q].notes` upstream).
    public var notes: String?

    public init(question: String, label: String, extraLabels: [String] = [], notes: String? = nil) {
        self.question = question
        self.labels = [label] + extraLabels
        self.notes = notes
    }
}

/// What the user did with the questionnaire. There is no "submitted empty"
/// case: submit is only reachable by confirming every question, and each
/// confirmation carries at least one label (see `PagerQuestionAnswer`).
public enum PagerQuestionOutcome: Sendable, Equatable, Hashable {
    case answered([PagerQuestionAnswer])
    case cancelled
}

/// Interactive state for the question bottom sheet.
///
/// Divergence from upstream, recorded: `question_view.rs` renders one tab per
/// question with h/l/Tab jumping between them and allows submitting with some
/// questions unanswered (they are omitted from the answers map). This port
/// renders the questions *sequentially* — "Question i of n" in the header,
/// Enter on the last submits — with the same advance semantics and simpler
/// chrome. The cost: no jumping back to an earlier question, and therefore no
/// partially-answered submit; the only way out without answering everything
/// is cancelling the whole questionnaire. `answeredSoFar` is the structural
/// form of that decision — the current question index is its count, so a
/// "go back" bug cannot desynchronize the two.
public struct PagerQuestionPrompt: Sendable, Equatable {
    public enum Focus: Sendable, Equatable {
        /// Cursor moves over option rows and the "Other" row.
        case navigation
        /// Typing into the "Other" free-text row (`QuestionFocus::InputMode`,
        /// `question_view.rs:74-81`).
        case freeformInput
    }

    public var request: PagerQuestionRequest
    /// Confirmed answers for questions before the current one.
    public private(set) var answeredSoFar: [PagerQuestionAnswer]
    /// Toggled option indices for the current question. Single-select keeps
    /// at most one member (`toggle_option`, `question_view.rs:755-773`).
    public private(set) var selectedOptionIndices: Set<Int>
    /// Cursor over the current question's rows: options, then the Other row.
    public private(set) var cursor: Int
    public private(set) var freeformText: String
    /// Whether the Other row is part of the submission
    /// (`per_question_freeform_selected`, `question_view.rs:169-172`).
    public private(set) var freeformSelected: Bool
    public private(set) var focus: Focus

    public init(request: PagerQuestionRequest) {
        self.request = request
        self.answeredSoFar = []
        self.selectedOptionIndices = []
        self.cursor = 0
        self.freeformText = ""
        self.freeformSelected = false
        self.focus = .navigation
    }

    public var questionIndex: Int { answeredSoFar.count }

    public var currentQuestion: PagerQuestion? {
        let index = questionIndex
        guard request.questions.indices.contains(index) else { return nil }
        return request.questions[index]
    }

    /// `"Question i of n"` — the sequential header standing in for upstream's
    /// tab strip.
    public var title: String {
        "Question \(min(questionIndex + 1, request.questions.count)) of \(request.questions.count)"
    }

    /// Option rows plus the trailing Other row. Tool-driven questions always
    /// carry the freeform choice — the tool description promises it
    /// ("Every question automatically gets an \"Other\" choice",
    /// `ask_user_question/mod.rs:246-251`); upstream's `no_freeform` exists
    /// only for pager-local questions this overlay never hosts.
    public var rowCount: Int {
        (currentQuestion?.options.count ?? 0) + 1
    }

    public var isOnFreeformRow: Bool {
        cursor == rowCount - 1
    }

    public mutating func moveCursor(by delta: Int) {
        cursor = min(max(0, cursor + delta), max(0, rowCount - 1))
    }

    /// Space: toggle the cursor's option, or enter the Other row
    /// (`handle_question_key`, `agent_view/interactions.rs:466-485`).
    public mutating func toggleAtCursor() {
        guard let question = currentQuestion else { return }
        if isOnFreeformRow {
            enterFreeformInput()
            return
        }
        let index = cursor
        guard question.options.indices.contains(index) else { return }
        if question.isMultiSelect {
            if selectedOptionIndices.contains(index) {
                selectedOptionIndices.remove(index)
            } else {
                selectedOptionIndices.insert(index)
            }
        } else if selectedOptionIndices.contains(index) {
            selectedOptionIndices.remove(index)
        } else {
            selectedOptionIndices = [index]
            // Single-select exclusivity with the freeform row
            // (`toggle_option` caller, interactions.rs:474-483).
            freeformSelected = false
        }
    }

    public mutating func enterFreeformInput() {
        freeformSelected = true
        if let question = currentQuestion, !question.isMultiSelect {
            // `activate_freeform_input` clears the option selection on
            // single-select (`question_view.rs:803-819`).
            selectedOptionIndices = []
        }
        focus = .freeformInput
    }

    public mutating func appendFreeform(_ character: Character) {
        freeformText.append(character)
    }

    public mutating func deleteFreeformBackward() {
        guard !freeformText.isEmpty else { return }
        freeformText.removeLast()
    }

    /// Esc in input mode: stash the text and return to navigation; non-empty
    /// text keeps the Other row selected (`interactions.rs:308-339`).
    public mutating func leaveFreeformInput() {
        freeformSelected = !freeformText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if freeformSelected, let question = currentQuestion, !question.isMultiSelect {
            selectedOptionIndices = []
        }
        focus = .navigation
    }

    public enum ConfirmResult: Sendable, Equatable {
        /// Nothing selected on a multi-select — upstream requires at least
        /// one answer, so Enter is refused rather than recording an empty one.
        case refused
        /// Answer recorded; a later question is now current.
        case advanced
        /// Answer recorded on the last question; the questionnaire is done.
        case submitted([PagerQuestionAnswer])
    }

    /// Enter: confirm the current question and advance or submit
    /// (`interactions.rs:486-504`; single-select Enter takes the highlighted
    /// option exactly as upstream's `select_option` call does).
    public mutating func confirmAtCursor() -> ConfirmResult {
        guard let question = currentQuestion else { return .refused }
        if isOnFreeformRow, focus == .navigation {
            // Enter on the Other row opens the editor, like upstream
            // (`interactions.rs:487-489`); the *next* Enter confirms.
            enterFreeformInput()
            return .refused
        }
        if focus == .navigation, !question.isMultiSelect {
            selectedOptionIndices = [cursor]
            freeformSelected = false
        }
        return confirmCurrentQuestion(question)
    }

    /// Enter while typing in the Other row: commit the text and confirm
    /// (`EnterOutcome::Submit`, `interactions.rs:355-394`).
    public mutating func confirmFreeform() -> ConfirmResult {
        guard let question = currentQuestion else { return .refused }
        leaveFreeformInput()
        return confirmCurrentQuestion(question)
    }

    private mutating func confirmCurrentQuestion(_ question: PagerQuestion) -> ConfirmResult {
        let labels = selectedOptionIndices.sorted().compactMap { index in
            question.options.indices.contains(index) ? question.options[index].label : nil
        }
        let trimmedNotes = freeformText.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = freeformSelected && !trimmedNotes.isEmpty ? freeformText : nil
        let answer: PagerQuestionAnswer
        if let first = labels.first {
            answer = PagerQuestionAnswer(
                question: question.text,
                label: first,
                extraLabels: Array(labels.dropFirst()),
                notes: notes
            )
        } else if let notes {
            // Freeform-only: label "Other", typed text as notes
            // (`build_accepted_response`, `question_view.rs:879-959`).
            answer = PagerQuestionAnswer(question: question.text, label: "Other", notes: notes)
        } else {
            return .refused
        }
        answeredSoFar.append(answer)
        selectedOptionIndices = []
        cursor = 0
        freeformText = ""
        freeformSelected = false
        focus = .navigation
        if answeredSoFar.count == request.questions.count {
            return .submitted(answeredSoFar)
        }
        return .advanced
    }
}

// MARK: - Plan approval prompt

/// Placeholder body when `exit_plan_mode` arrives with no plan content.
/// Quoted verbatim from `EMPTY_PLAN_PLACEHOLDER`
/// (`xai-grok-pager/src/views/plan_approval_view.rs:15-23`).
public let pagerEmptyPlanPlaceholder = """
# No plan written yet

The agent exited plan mode without writing a plan.

- **Approve** — leave plan mode and start implementing
- **Request changes** — send the agent back to planning
- **Quit** — abandon and turn plan mode off

"""

/// A plan awaiting the user's approval. The render layer reports a
/// `PagerPlanApprovalOutcome`; `PagerPlanApprovalCoordinator` joins it to the
/// blocked `exit_plan_mode` call.
public struct PagerPlanApprovalRequest: Sendable, Equatable, Identifiable {
    public var id: String
    public var toolCallID: String
    /// `nil` means "no plan": the initializer normalizes whitespace-only
    /// bodies to `nil`, the same filter upstream applies on receipt
    /// (`plan_approval_view.rs:94`), so "has a plan" is one check with no
    /// second whitespace-only state to keep in sync.
    public private(set) var planContent: String?

    public init(
        id: String = UUID().uuidString,
        toolCallID: String,
        planContent: String?
    ) {
        self.id = id
        self.toolCallID = toolCallID
        let trimmed = planContent?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.planContent = (trimmed?.isEmpty ?? true) ? nil : planContent
    }
}

/// What the user did with the plan. Mirrors the view's three wire outcomes —
/// approved / cancelled-with-feedback / abandoned
/// (`plan_approval_view.rs:177-191`) — with `revise` carrying the typed
/// feedback the way upstream's prompt submit does.
public enum PagerPlanApprovalOutcome: Sendable, Equatable {
    case approved
    case revise(feedback: String)
    case abandoned
}

/// Interactive state for the plan-approval bottom sheet.
///
/// Divergence from upstream, recorded: `plan_approval_view.rs` hosts the plan
/// in the fullscreen line viewer with per-line commenting (`c`/Enter enter
/// commenting, comments become structured feedback) and an approve-with-
/// comments path that interjects into the next turn (`plan.rs:189-215`).
/// Neither commenting nor interject exists in this port, so the sheet is
/// deliberately smaller: a scrollable plan body plus upstream's `a`/`s`/`q`
/// grammar (`viewer.rs:151-166`), with `s` opening the same inline free-text
/// editor the question sheet's "Other" row uses. The cost: feedback is one
/// freeform message, never line-anchored comments.
public struct PagerPlanApprovalPrompt: Sendable, Equatable {
    public enum Focus: Sendable, Equatable {
        /// Keys act on the plan: scroll, `a`/`s`/`q`.
        case viewing
        /// Typing revision feedback (upstream's `PlanApprovalFocus::Prompt`,
        /// reached by `s`, `viewer.rs:157-162`).
        case feedbackInput
    }

    public var request: PagerPlanApprovalRequest
    public private(set) var focus: Focus
    public private(set) var feedbackText: String
    public var scrollOffset: Int

    public init(request: PagerPlanApprovalRequest) {
        self.request = request
        self.focus = .viewing
        self.feedbackText = ""
        self.scrollOffset = 0
    }

    public var hasPlan: Bool { request.planContent != nil }

    /// `plan_approval_status_label` (`plan_approval_view.rs:29-35`).
    public var statusLabel: String {
        hasPlan ? "Waiting on plan approval" : "No plan written — approve or request changes"
    }

    /// The plan body, or the empty-plan placeholder. Split on any newline
    /// (`Character.isNewline`) because plan files come off disk and may carry
    /// CRLF — AGENTS.md §2's delimiter trap.
    public var bodyLines: [String] {
        (request.planContent ?? pagerEmptyPlanPlaceholder)
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)
    }

    public mutating func enterFeedbackInput() {
        focus = .feedbackInput
    }

    /// Esc while typing: back to the plan, keeping the draft so `s` resumes it.
    public mutating func leaveFeedbackInput() {
        focus = .viewing
    }

    public mutating func appendFeedback(_ character: Character) {
        feedbackText.append(character)
    }

    public mutating func deleteFeedbackBackward() {
        guard !feedbackText.isEmpty else { return }
        feedbackText.removeLast()
    }
}

// MARK: - Overlay

public enum PagerOverlayContent: Sendable, Equatable {
    case list(PagerListOverlay)
    case text(PagerTextOverlay)
    case welcome(PagerWelcomeOverlay)
    case permission(PagerPermissionPrompt)
    case question(PagerQuestionPrompt)
    case planApproval(PagerPlanApprovalPrompt)
    case workflows(PagerWorkflowsOverlay)
    case settings(PagerSettingsOverlay)
    case extensions(PagerExtensionsOverlay)
    case agents(PagerAgentsOverlay)
    case personaDetail(PagerPersonaDetailOverlay)
}

public struct PagerOverlay: Sendable, Equatable {
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

    /// `/settings`, `/privacy`, and `F2` — the settings modal.
    ///
    /// Title and footer hints are recomputed from the modal's own mode at paint
    /// time, so the stored ones here are only what a caller sees before the
    /// first frame; nothing downstream reads them.
    public static func settings(
        _ settings: PagerSettingsOverlay,
        id: String = "settings"
    ) -> PagerOverlay {
        PagerOverlay(
            id: id,
            title: pagerSettingsTitle(settings),
            presentation: .centeredModal(PagerSettingsMetrics.sizing),
            hints: pagerSettingsHints(settings),
            content: .settings(settings),
            // Escape is routed into the modal, which decides whether it means
            // "back out" or "close" — see `PagerOverlayStack.handle`.
            dismissOnEscape: false
        )
    }

    /// `/hooks`, `/plugins`, `/marketplace`, `/skills`, and `Ctrl+L` — the
    /// read-only extensions modal.
    ///
    /// The title is empty on purpose: the tab bar identifies the modal
    /// contents (`extensions_modal.rs:3383-3384`). Footer hints are
    /// recomputed from the modal's own state at paint time.
    public static func extensions(
        _ extensions: PagerExtensionsOverlay,
        id: String = "extensions"
    ) -> PagerOverlay {
        PagerOverlay(
            id: id,
            title: "",
            presentation: .centeredModal(PagerExtensionsMetrics.sizing),
            hints: pagerExtensionsHints(extensions),
            content: .extensions(extensions),
            // Escape is routed into the modal, which decides whether it means
            // "clear the search" or "close" — see `PagerOverlayStack.handle`.
            dismissOnEscape: false
        )
    }

    /// `/config-agents` (alias `/agents`) and `/personas` — the read-only
    /// agents/personas modal (Wave 18 B9-b1).
    ///
    /// The title is upstream's `"Agents"` (`agents_modal.rs:2010,1029`).
    /// Footer hints are recomputed from the modal's own state at paint
    /// time.
    public static func agents(
        _ agents: PagerAgentsOverlay,
        id: String = "agents"
    ) -> PagerOverlay {
        PagerOverlay(
            id: id,
            title: "Agents",
            presentation: .centeredModal(PagerAgentsMetrics.sizing),
            hints: pagerAgentsHints(agents),
            content: .agents(agents),
            // Escape is routed into the modal, which decides whether it
            // means "clear the search" or "close" — see
            // `PagerOverlayStack.handle`.
            dismissOnEscape: false
        )
    }

    /// `Enter` on a persona in the agents modal — the persona detail/edit
    /// modal (Wave 18 B9-b3), pushed OVER the agents modal exactly as
    /// upstream keeps both alive (`agent_view/modals.rs:49-68`; closing
    /// the detail refreshes the list beneath, `:126-132`).
    ///
    /// The title is upstream's `"persona: {name}"`
    /// (`persona_detail.rs:382`); footer hints are recomputed from the
    /// modal's own state at paint time.
    public static func personaDetail(
        _ detail: PagerPersonaDetailOverlay,
        id: String = "persona-detail"
    ) -> PagerOverlay {
        PagerOverlay(
            id: id,
            title: "persona: \(detail.name)",
            presentation: .centeredModal(PagerPersonaDetailMetrics.sizing),
            hints: pagerPersonaDetailHints(detail),
            content: .personaDetail(detail),
            // Escape is routed into the modal: it cancels an open field
            // edit or collapses expanded instructions before it closes
            // (`persona_detail.rs:764-772`, `:840-843`).
            dismissOnEscape: false
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

    /// The `ask_user_question` bottom sheet. `dismissOnEscape` is false
    /// because Esc is not a dismissal here: it cancels the questionnaire,
    /// which must resolve the coordinator so the blocked tool call returns —
    /// a plain dismiss would leave the tool suspended forever.
    public static func question(
        _ request: PagerQuestionRequest,
        id: String? = nil
    ) -> PagerOverlay {
        PagerOverlay(
            id: id ?? "question:\(request.id)",
            title: "",
            presentation: .bottomSheet,
            hints: [
                PagerOverlayHint(key: "↑/↓", label: "nav"),
                PagerOverlayHint(key: "Space", label: "toggle"),
                PagerOverlayHint(key: "Enter", label: "confirm"),
                PagerOverlayHint(key: "Esc", label: "cancel")
            ],
            content: .question(PagerQuestionPrompt(request: request)),
            dismissOnEscape: false
        )
    }

    /// The `exit_plan_mode` plan-approval bottom sheet. `dismissOnEscape` is
    /// false for the question sheet's reason: Esc here is an *abandon
    /// outcome* the coordinator must see (the tool is blocked on it), never a
    /// plain dismissal that would leave the tool suspended forever.
    public static func planApproval(
        _ request: PagerPlanApprovalRequest,
        id: String? = nil
    ) -> PagerOverlay {
        PagerOverlay(
            id: id ?? "plan-approval:\(request.id)",
            title: "Plan approval",
            presentation: .bottomSheet,
            hints: [
                PagerOverlayHint(key: "a", label: "approve"),
                PagerOverlayHint(key: "s", label: "request changes"),
                PagerOverlayHint(key: "q", label: "abandon"),
                PagerOverlayHint(key: "↑/↓", label: "scroll")
            ],
            content: .planApproval(PagerPlanApprovalPrompt(request: request)),
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
    case question(id: String, requestID: String, outcome: PagerQuestionOutcome)
    case planApproval(id: String, requestID: String, outcome: PagerPlanApprovalOutcome)
    /// The settings modal decided something the session has to act on — commit
    /// a value, preview a theme, store a secret, apply a default.
    case setting(id: String, event: PagerSettingsEvent)
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

    /// Mutate an open settings overlay's state in place — the port's seam
    /// for upstream's `refresh_open_settings_modals`
    /// (dispatch/settings/ui.rs:96-160 at pin 650c1db7): an app-level value
    /// changed underneath an open modal and the modal's snapshot must
    /// follow, without rebuilding the overlay (a rebuild would reset the
    /// cursor and any open sub-pane). Returns false when no settings
    /// overlay with that id is open — upstream's early exit.
    @discardableResult
    public mutating func updateSettings(
        id: String = "settings",
        _ transform: (inout PagerSettingsOverlay) -> Void
    ) -> Bool {
        guard let index = overlays.firstIndex(where: { $0.id == id }),
              case .settings(var settings) = overlays[index].content
        else { return false }
        transform(&settings)
        overlays[index].content = .settings(settings)
        return true
    }

    /// Route a key to the topmost overlay.
    ///
    /// `viewportHeight` is the row budget the overlay's scrollable body has;
    /// page keys move by that many rows. Callers can read it back off
    /// `PagerOverlayBounds.content.height` from the previous frame.
    public mutating func handle(_ event: KeyEvent, viewportHeight: Int = 10) -> PagerOverlayOutcome {
        guard let index = overlays.lastIndex(where: \.capturesInput) else { return .ignored }
        var overlay = overlays[index]

        // The settings modal owns Escape outright: inside a chooser or an editor
        // it means "back out one level", and only browse-Escape closes. Handling
        // it here would collapse every sub-pane into a dismissal.
        // The question and plan-approval sheets own it too: Esc there is an
        // *outcome* the coordinator must see (the tool is blocked on it),
        // never a dismissal.
        // The extensions modal owns it too: with search active, Esc clears
        // the query instead of closing. The agents modal follows the same
        // rule (search-Esc resets the query, `agents_modal.rs:1986-1990`).
        // The persona detail owns it too: Esc there cancels an open field
        // edit or collapses expanded instructions before it closes.
        let ownsEscape: Bool
        switch overlay.content {
        case .settings, .question, .planApproval, .extensions, .agents, .personaDetail:
            ownsEscape = true
        default: ownsEscape = false
        }

        if event.key == .escape, event.modifiers.isEmpty, !ownsEscape {
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
        case .question(var prompt):
            outcome = handleQuestion(&prompt, overlay: overlay, event: event)
            overlay.content = .question(prompt)
        case .planApproval(var prompt):
            outcome = handlePlanApproval(
                &prompt,
                overlay: overlay,
                event: event,
                viewportHeight: viewportHeight
            )
            overlay.content = .planApproval(prompt)
        case .workflows(var runs):
            outcome = handleWorkflows(&runs, overlay: overlay, event: event, viewportHeight: viewportHeight)
            overlay.content = .workflows(runs)
        case .settings(var settings):
            let result = settings.handle(event)
            overlay.content = .settings(settings)
            switch result {
            case .redraw:
                outcome = .redraw
            case .consumed:
                outcome = .consumed
            case .close:
                overlays.remove(at: index)
                return .dismissed(id: overlay.id)
            case .event(let settingsEvent):
                outcome = .setting(id: overlay.id, event: settingsEvent)
            case .eventAndClose(let settingsEvent):
                overlays[index] = overlay
                overlays.remove(at: index)
                return .setting(id: overlay.id, event: settingsEvent)
            }
        case .extensions(var extensions):
            let result = extensions.handle(event)
            overlay.content = .extensions(extensions)
            switch result {
            case .redraw:
                outcome = .redraw
            case .consumed:
                outcome = .consumed
            case .close:
                overlays.remove(at: index)
                return .dismissed(id: overlay.id)
            case .reload(let tab):
                // The overlay cannot reach the loaders; the composition
                // rebuilds the snapshot. Rides the row-selection channel the
                // way the workflows overlay's p/r/x already do.
                outcome = .selected(id: overlay.id, rowID: "reload:\(tab.rawValue)")
            }
        case .agents(var agents):
            let result = agents.handle(event)
            overlay.content = .agents(agents)
            switch result {
            case .redraw:
                outcome = .redraw
            case .consumed:
                outcome = .consumed
            case .close:
                overlays.remove(at: index)
                return .dismissed(id: overlay.id)
            case .viewAgent(let entryIndex):
                // The overlay cannot read files; the composition resolves
                // the view payload from the (just-updated) snapshot and
                // pushes the document overlay ON TOP — upstream's
                // viewer-over-modal layering (`agent_view/modals.rs:27-47`).
                outcome = .selected(id: overlay.id, rowID: "view:agent:\(entryIndex)")
            case .viewPersona(let entryIndex):
                outcome = .selected(id: overlay.id, rowID: "view:persona:\(entryIndex)")
            case .toggleAgent(let entryIndex):
                // The B9-b2 mutation keys ride the same channel: the
                // composition owns the config writers and the in-place
                // snapshot refresh (`toggle_agent`/`set_default_agent`,
                // `agents_modal.rs:730-778`).
                outcome = .selected(id: overlay.id, rowID: "toggle:\(entryIndex)")
            case .setDefaultAgent(let entryIndex):
                outcome = .selected(id: overlay.id, rowID: "default:\(entryIndex)")
            case .createPersona:
                // The B9-b3 persona mutations too: the form/confirm state
                // rides the overlay snapshot the composition reads back.
                outcome = .selected(id: overlay.id, rowID: "persona:create")
            case .deletePersona:
                outcome = .selected(id: overlay.id, rowID: "persona:delete")
            }
        case .personaDetail(var detail):
            let result = detail.handle(event)
            overlay.content = .personaDetail(detail)
            switch result {
            case .redraw:
                outcome = .redraw
            case .consumed:
                outcome = .consumed
            case .close:
                overlays.remove(at: index)
                return .dismissed(id: overlay.id)
            case .save:
                // The committed value is already folded into the detail
                // snapshot; the composition writes it to the source file
                // (`save_to_file`, `persona_detail.rs:316-347`) and sets
                // the Saved/failed message on the replacement.
                outcome = .selected(id: overlay.id, rowID: "save")
            case .editInEditor:
                // `$EDITOR` over a suspended TUI — the composition owns
                // the suspend seam (`agent_view/modals.rs:134-140`).
                outcome = .selected(id: overlay.id, rowID: "edit-in-editor")
            }
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

    /// Keys for the question sheet (`handle_question_key`,
    /// `xai-grok-pager/src/app/agent_view/interactions.rs:301-619`, reduced to
    /// the sequential flow):
    /// Up/Down and j/k move the cursor, Space toggles, Enter confirms the
    /// current question (advancing, or submitting on the last), typing on the
    /// Other row opens free-text entry, Esc leaves it. Esc/Ctrl+C in
    /// navigation cancel the questionnaire — a deliberate divergence from
    /// upstream, where Esc clears the selection (interactions.rs:569-572) and
    /// only Ctrl+C/Ctrl+Y end it; with no tab strip to back out through, a
    /// selection-clearing Esc would leave no obvious cancel key at all.
    private func handleQuestion(
        _ prompt: inout PagerQuestionPrompt,
        overlay: PagerOverlay,
        event: KeyEvent
    ) -> PagerOverlayOutcome {
        func finish(_ outcome: PagerQuestionOutcome) -> PagerOverlayOutcome {
            .question(id: overlay.id, requestID: prompt.request.id, outcome: outcome)
        }
        func confirm(_ result: PagerQuestionPrompt.ConfirmResult) -> PagerOverlayOutcome {
            switch result {
            case .refused, .advanced:
                return .redraw
            case .submitted(let answers):
                return finish(.answered(answers))
            }
        }
        let isCtrlC = event.key == .char("c") && event.modifiers.contains(.control)

        switch prompt.focus {
        case .freeformInput:
            switch event.key {
            case .escape:
                prompt.leaveFreeformInput()
                return .redraw
            case .enter:
                return confirm(prompt.confirmFreeform())
            case .backspace:
                prompt.deleteFreeformBackward()
                return .redraw
            case .char(let character):
                if isCtrlC {
                    // Ctrl+C in input mode backs out to navigation, like
                    // upstream (interactions.rs:348-352); cancelling from
                    // there is one more Ctrl+C.
                    prompt.leaveFreeformInput()
                    return .redraw
                }
                guard event.modifiers.subtracting(.shift).isEmpty, !character.isNewline else {
                    return .consumed
                }
                prompt.appendFreeform(character)
                return .redraw
            default:
                return .consumed
            }
        case .navigation:
            if isCtrlC {
                return finish(.cancelled)
            }
            switch event.key {
            case .escape:
                return finish(.cancelled)
            case .up:
                prompt.moveCursor(by: -1)
                return .redraw
            case .down:
                prompt.moveCursor(by: 1)
                return .redraw
            case .enter:
                return confirm(prompt.confirmAtCursor())
            case .char(" "):
                prompt.toggleAtCursor()
                return .redraw
            case .char(let character) where event.modifiers.subtracting(.shift).isEmpty:
                if event.modifiers.isEmpty, character == "j" { prompt.moveCursor(by: 1); return .redraw }
                if event.modifiers.isEmpty, character == "k" { prompt.moveCursor(by: -1); return .redraw }
                if prompt.isOnFreeformRow {
                    // Typing on the Other row starts editing with that
                    // character, as upstream does (interactions.rs:420-428).
                    prompt.enterFreeformInput()
                    prompt.appendFreeform(character)
                    return .redraw
                }
                return .consumed
            default:
                return .consumed
            }
        }
    }

    /// Keys for the plan-approval sheet, upstream's grammar reduced to the
    /// port's sheet (`agent_view/viewer.rs:151-166`): `a` approves, `s`
    /// focuses the feedback editor, `q` abandons; arrows and the text-overlay
    /// vim keys scroll the plan body. Esc/Ctrl+C in viewing abandon — a
    /// deliberate divergence from upstream, where Esc on the plan viewer is a
    /// selection-clearing no-op (`viewer.rs:108-124`) and only `q` ends the
    /// review; with no fullscreen viewer to back out of, a do-nothing Esc
    /// would leave the sheet with no obvious dismissal at all. In the editor,
    /// Enter submits the typed text as the revise outcome (upstream's
    /// Enter-from-Prompt send, `plan.rs:244-271`) and Esc stashes the draft
    /// back to viewing.
    private func handlePlanApproval(
        _ prompt: inout PagerPlanApprovalPrompt,
        overlay: PagerOverlay,
        event: KeyEvent,
        viewportHeight: Int
    ) -> PagerOverlayOutcome {
        func finish(_ outcome: PagerPlanApprovalOutcome) -> PagerOverlayOutcome {
            .planApproval(id: overlay.id, requestID: prompt.request.id, outcome: outcome)
        }
        let isCtrlC = event.key == .char("c") && event.modifiers.contains(.control)

        switch prompt.focus {
        case .feedbackInput:
            switch event.key {
            case .escape:
                prompt.leaveFeedbackInput()
                return .redraw
            case .enter:
                // Empty feedback is a valid revise upstream: `send_cancelled`
                // filters it to no-feedback (`plan_approval_view.rs:154`) and
                // the shell answers with the ask-what-changes copy
                // (`tool_calls.rs:391-400`).
                return finish(.revise(
                    feedback: prompt.feedbackText
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            case .backspace:
                prompt.deleteFeedbackBackward()
                return .redraw
            case .char(let character):
                if isCtrlC {
                    // Ctrl+C in the editor backs out to viewing, mirroring
                    // the question sheet; abandoning from there is one more.
                    prompt.leaveFeedbackInput()
                    return .redraw
                }
                guard event.modifiers.subtracting(.shift).isEmpty, !character.isNewline else {
                    return .consumed
                }
                prompt.appendFeedback(character)
                return .redraw
            default:
                return .consumed
            }
        case .viewing:
            if isCtrlC {
                return finish(.abandoned)
            }
            let page = max(1, viewportHeight)
            let maximum = max(0, prompt.bodyLines.count - page)
            func scroll(by delta: Int) -> PagerOverlayOutcome {
                let target = min(max(0, prompt.scrollOffset + delta), maximum)
                guard target != prompt.scrollOffset else { return .consumed }
                prompt.scrollOffset = target
                return .redraw
            }
            switch event.key {
            case .escape:
                return finish(.abandoned)
            case .up: return scroll(by: -1)
            case .down: return scroll(by: 1)
            case .pageUp: return scroll(by: -page)
            case .pageDown: return scroll(by: page)
            case .home: return scroll(by: -maximum)
            case .end: return scroll(by: maximum)
            case .char(let character) where event.modifiers.isEmpty:
                switch character {
                case "a": return finish(.approved)
                case "s":
                    prompt.enterFeedbackInput()
                    return .redraw
                case "q": return finish(.abandoned)
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

// MARK: - Question coordinator

/// Joins the blocking `ask_user_question` tool call to the render loop —
/// `PagerPermissionCoordinator`'s shape with a questionnaire payload.
///
/// The tool `await`s `answers(for:)`, which suspends without touching the
/// renderer. The presenter callback pushes or pops the question sheet, and
/// `resolve(requestID:outcome:)` resumes the waiter — so a queued second
/// questionnaire surfaces as soon as the first is answered, which stands in
/// for upstream's cancel-and-replace on a new `x.ai/ask_user_question`
/// (`acp_handler/interactions.rs:57-96`): here the tool runtime serializes
/// calls, so the queue drains in order instead of displacing.
public actor PagerQuestionCoordinator {
    private struct Waiter {
        var request: PagerQuestionRequest
        var continuation: CheckedContinuation<PagerQuestionOutcome, Never>
    }

    private var queue: [Waiter] = []
    private var presenter: (@Sendable (PagerQuestionRequest?) async -> Void)?

    public init() {}

    /// The questionnaire the overlay should currently display, or `nil`.
    public var currentRequest: PagerQuestionRequest? { queue.first?.request }

    public var pendingCount: Int { queue.count }

    /// Whether anything is listening. A caller with no presenter would
    /// suspend forever, so the tool checks this and fails closed instead.
    public var hasPresenter: Bool { presenter != nil }

    /// Called whenever the head of the queue changes, so a controller can
    /// push or pop the overlay without polling.
    public func setPresenter(_ presenter: (@Sendable (PagerQuestionRequest?) async -> Void)?) async {
        self.presenter = presenter
        await presenter?(queue.first?.request)
    }

    /// Suspend until the user answers or cancels. Safe to call from any task.
    public func answers(for request: PagerQuestionRequest) async -> PagerQuestionOutcome {
        let wasIdle = queue.isEmpty
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<PagerQuestionOutcome, Never>) in
            queue.append(Waiter(request: request, continuation: continuation))
            if wasIdle, let presenter {
                Task { await presenter(request) }
            }
        }
        return result
    }

    /// Resolve the head request. Ignored when `requestID` is not the head, so
    /// a stale key from a previous overlay cannot resolve the wrong request.
    public func resolve(requestID: String, outcome: PagerQuestionOutcome) {
        guard let head = queue.first, head.request.id == requestID else { return }
        queue.removeFirst()
        head.continuation.resume(returning: outcome)
        let next = queue.first?.request
        if let presenter {
            Task { await presenter(next) }
        }
    }

    /// Cancel every outstanding questionnaire — session teardown, turn
    /// cancellation. Cancel, not an error: upstream treats a dismissed
    /// question as a normal user decision (`format.rs:16-22`) and the turn
    /// continues.
    public func resolveAll() {
        let waiters = queue
        queue.removeAll()
        for waiter in waiters {
            waiter.continuation.resume(returning: .cancelled)
        }
        if let presenter {
            Task { await presenter(nil) }
        }
    }
}

// MARK: - Plan approval coordinator

/// Joins the blocking `exit_plan_mode` approval to the render loop —
/// `PagerQuestionCoordinator`'s shape with a plan payload.
///
/// The tool `await`s `decision(for:)`, which suspends without touching the
/// renderer. The presenter callback pushes or pops the plan sheet, and
/// `resolve(requestID:outcome:)` resumes the waiter. Upstream cancels a stale
/// approval when a new one arrives (`acp_handler/interactions.rs:199-209`);
/// here the tool runtime serializes calls, so the queue drains in order
/// instead of displacing.
public actor PagerPlanApprovalCoordinator {
    private struct Waiter {
        var request: PagerPlanApprovalRequest
        var continuation: CheckedContinuation<PagerPlanApprovalOutcome, Never>
    }

    private var queue: [Waiter] = []
    private var presenter: (@Sendable (PagerPlanApprovalRequest?) async -> Void)?

    public init() {}

    /// The plan the overlay should currently display, or `nil`.
    public var currentRequest: PagerPlanApprovalRequest? { queue.first?.request }

    public var pendingCount: Int { queue.count }

    /// Whether anything is listening. A caller with no presenter would
    /// suspend forever, so the pipeline checks this and falls back to the
    /// generic permission sheet instead.
    public var hasPresenter: Bool { presenter != nil }

    /// Called whenever the head of the queue changes, so a controller can
    /// push or pop the overlay without polling.
    public func setPresenter(_ presenter: (@Sendable (PagerPlanApprovalRequest?) async -> Void)?) async {
        self.presenter = presenter
        await presenter?(queue.first?.request)
    }

    /// Suspend until the user decides. Safe to call from any task.
    public func decision(for request: PagerPlanApprovalRequest) async -> PagerPlanApprovalOutcome {
        let wasIdle = queue.isEmpty
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<PagerPlanApprovalOutcome, Never>) in
            queue.append(Waiter(request: request, continuation: continuation))
            if wasIdle, let presenter {
                Task { await presenter(request) }
            }
        }
        return result
    }

    /// Resolve the head request. Ignored when `requestID` is not the head, so
    /// a stale key from a previous overlay cannot resolve the wrong request.
    public func resolve(requestID: String, outcome: PagerPlanApprovalOutcome) {
        guard let head = queue.first, head.request.id == requestID else { return }
        queue.removeFirst()
        head.continuation.resume(returning: outcome)
        let next = queue.first?.request
        if let presenter {
            Task { await presenter(next) }
        }
    }

    /// Resolve every outstanding approval — session teardown, turn
    /// cancellation. The resolution is a no-feedback revise, upstream's
    /// stale-cancel: a torn-down approval sends `cancelled` with no feedback
    /// (`plan_approval_view.rs:189-191`), which the shell maps to *stay in
    /// plan mode* (`tool_calls.rs:347-368`, `:416-418`). Fail closed: the
    /// plan gate stays armed. Not `.abandoned` — that would disarm the gate
    /// on a teardown the user never chose, and not `.approved` for the same
    /// reason twice over.
    public func resolveAll() {
        let waiters = queue
        queue.removeAll()
        for waiter in waiters {
            waiter.continuation.resume(returning: .revise(feedback: ""))
        }
        if let presenter {
            Task { await presenter(nil) }
        }
    }
}
