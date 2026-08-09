// PagerAgentsOverlay.swift
//
// The agents/personas modal's state and key handling — the tabbed viewer
// behind `/config-agents` (alias `/agents`) and `/personas`.
// Ports `xai-grok-pager/src/views/agents_modal.rs` at upstream 650c1db7:
// tabs (`:27-55`), the entry shapes (`:57-66`, `PersonaDetail`
// consumption `:451-567`), search filtering (`:892-905`, `:941-959`),
// selection (`:907-981`), expand/collapse, the inline-message machinery
// (`:67-99`, cleared on every key at `:1978`), and the per-tab key
// handlers (`:2082-2199`, `:2202-2290`). The Agents tab's mutation keys
// `t` (toggle, `:2183-2196`) and `s` (default, `:2152-2181`) are live as
// of B9-b2: the overlay owns no file IO, so each emits an outcome the
// composition resolves against the real config writers
// (`PagerAgentsConfigStore`) before refreshing this snapshot in place.
// `n` (new), `d` (delete), and the persona detail modal are B9-b3 —
// those keys stay unhandled and unadvertised, because a footer verb with
// no backing is exactly the no-op row AGENTS.md §4 forbids. `i` IS
// handled: at the pin it is search-focus on BOTH tabs (`:2147`, `:2283`
// — `Char('/') | Char('i')` with empty modifiers), not an editor key;
// `EditInEditor` is only ever produced by the b3 persona detail modal
// (`views/persona_detail.rs:827`).
//
// Like `PagerExtensionsOverlay`, this is a value type that owns
// navigation, search, and expansion, and never touches the data sources:
// the CLI layer builds the row snapshots (`LiveAgentsComposition`) and
// resolves the one outward-facing outcome, `Enter`/`o` view, through the
// existing `.showDocument` document overlay (upstream opens its line
// viewer ON TOP of the modal, `app/agent_view/modals.rs:27-47`; the
// port's overlay stack layers the same way).

import Foundation
import OpenGrokTerminalCore

// MARK: - Tabs

/// `AgentsTab` (`agents_modal.rs:27-55`): display order, labels, and the
/// wrapping next/prev cycle, all byte-faithful (two tabs, so next == prev).
public enum PagerAgentsTab: String, Sendable, Equatable, Hashable, CaseIterable {
    case agents
    case personas

    /// All tabs in display order (`ALL`, `:33`).
    public static let all: [PagerAgentsTab] = [.agents, .personas]

    /// Display label for the tab bar (`label()`, `:35-40`).
    public var label: String {
        switch self {
        case .agents: return "Agents"
        case .personas: return "Personas"
        }
    }

    /// Next tab, wrapping (`next()`, `:42-47`).
    public func next() -> PagerAgentsTab {
        switch self {
        case .agents: return .personas
        case .personas: return .agents
        }
    }

    /// Previous tab, wrapping (`prev()`, `:49-54`).
    public func previous() -> PagerAgentsTab {
        switch self {
        case .agents: return .personas
        case .personas: return .agents
        }
    }
}

// MARK: - Scopes

/// `AgentScope` as the modal paints it: section headers (`:1338-1343`) and
/// inline badges (`scope_badge`, `:995-1008`). A render-layer mirror of the
/// definitions module's scope so this target keeps its no-data-imports rule.
public enum PagerAgentsScope: String, Sendable, Equatable, Hashable, CaseIterable {
    case builtIn
    case project
    case user
    case bundled

    /// Dedup priority (`scope_priority`, `:404-411`) — kept here so tests
    /// can pin the ordering contract next to the type, even though the
    /// dedup itself runs in the CLI snapshot builder.
    public var priority: Int {
        switch self {
        case .project: return 3
        case .user: return 2
        case .bundled: return 1
        case .builtIn: return 0
        }
    }

    /// Section header label (`render_agents_tab`, `:1338-1343`).
    public var headerLabel: String {
        switch self {
        case .builtIn: return "\u{2500}\u{2500} Built-in \u{2500}\u{2500}"
        case .project: return "\u{2500}\u{2500} Project \u{2500}\u{2500}"
        case .user: return "\u{2500}\u{2500} User \u{2500}\u{2500}"
        case .bundled: return "\u{2500}\u{2500} Bundled \u{2500}\u{2500}"
        }
    }

    /// Inline badge text, padded exactly as upstream pads it
    /// (`scope_badge`, `:996-1001`).
    public var badgeLabel: String {
        switch self {
        case .builtIn: return " built-in "
        case .project: return " project "
        case .user: return " user "
        case .bundled: return " bundled "
        }
    }
}

// MARK: - Entries

/// `AgentListEntry` (`agents_modal.rs:57-66`), carrying precomputed display
/// strings instead of the definition itself: `detailLines` is
/// `format_agent_detail` (`:780-826`) and `viewContent` is
/// `synthesize_agent_markdown` (`:863-872`), both built by the CLI snapshot
/// layer, which owns the definition types.
public struct PagerAgentsListEntry: Sendable, Equatable {
    public var name: String
    public var description: String
    public var scope: PagerAgentsScope
    public var sourcePath: String?
    public var enabled: Bool
    public var isBuiltin: Bool
    /// Expanded detail lines (`format_agent_detail`, `:780-826`).
    public var detailLines: [String]
    /// `Enter` fallback for built-ins with a prompt body
    /// (`synthesize_agent_markdown`, `:863-872`); file-based entries view
    /// their `sourcePath` instead (`:2124-2133`).
    public var viewContent: String?

    public init(
        name: String,
        description: String,
        scope: PagerAgentsScope,
        sourcePath: String? = nil,
        enabled: Bool = true,
        isBuiltin: Bool = false,
        detailLines: [String] = [],
        viewContent: String? = nil
    ) {
        self.name = name
        self.description = description
        self.scope = scope
        self.sourcePath = sourcePath
        self.enabled = enabled
        self.isBuiltin = isBuiltin
        self.detailLines = detailLines
        self.viewContent = viewContent
    }
}

/// `PersonaDetail` as the Personas tab consumes it (`agents_modal.rs:
/// 451-567`): name, sniffed description, capability flags, source path,
/// scope tag. `viewContent` is the b1 stand-in for the b3 persona detail
/// modal: inline `[subagents.personas]` entries have no file to open, so
/// the CLI layer precomputes their definition text.
public struct PagerAgentsPersonaEntry: Sendable, Equatable {
    public var name: String
    public var description: String?
    public var hasInputs: Bool
    public var hasOutputs: Bool
    public var sourcePath: String?
    public var scopeLabel: String?
    public var viewContent: String?

    public init(
        name: String,
        description: String? = nil,
        hasInputs: Bool = false,
        hasOutputs: Bool = false,
        sourcePath: String? = nil,
        scopeLabel: String? = nil,
        viewContent: String? = nil
    ) {
        self.name = name
        self.description = description
        self.hasInputs = hasInputs
        self.hasOutputs = hasOutputs
        self.sourcePath = sourcePath
        self.scopeLabel = scopeLabel
        self.viewContent = viewContent
    }
}

// MARK: - Messages

/// `AgentsModalMessageKind` (`agents_modal.rs:67-73`). All three kinds
/// exist at the pin; b2 produces only `.info` (the `s` success copy) and
/// `.error` (writer failures) — `.success` arrives with b3's persona
/// create/delete arms and is carried now so the style map
/// (`message_line_style`, `:1938-1945`) ports whole.
public enum PagerAgentsMessageKind: Sendable, Equatable {
    case error
    case success
    case info
}

/// `AgentsModalMessage` (`:74-99`): the one inline status line, shown
/// until the next keypress clears it (`handle_agents_key`, `:1978`).
public struct PagerAgentsMessage: Sendable, Equatable {
    public var kind: PagerAgentsMessageKind
    public var text: String

    public init(kind: PagerAgentsMessageKind, text: String) {
        self.kind = kind
        self.text = text
    }

    public static func error(_ text: String) -> PagerAgentsMessage {
        PagerAgentsMessage(kind: .error, text: text)
    }

    public static func success(_ text: String) -> PagerAgentsMessage {
        PagerAgentsMessage(kind: .success, text: text)
    }

    public static func info(_ text: String) -> PagerAgentsMessage {
        PagerAgentsMessage(kind: .info, text: text)
    }
}

// MARK: - Outcome

/// What a keystroke decided. The outward-facing outcomes exist because
/// the overlay cannot touch files: the composition resolves each against
/// the real loaders/writers. The stack maps them onto the row-selection
/// channel by index (`"view:agent:{i}"`, `"toggle:{i}"`, …), the
/// extensions `.reload` pattern.
public enum PagerAgentsOutcome: Sendable, Equatable {
    case redraw
    case consumed
    case close
    /// `Enter`/`o` on the Agents tab (`ViewAgent`, `:2124-2146`).
    case viewAgent(index: Int)
    /// `Enter`/`o` on the Personas tab. Upstream opens the persona detail
    /// modal here (`:2244-2260`); that modal is B9-b3, so this slice
    /// routes the definition through the document overlay instead.
    case viewPersona(index: Int)
    /// `t` on the Agents tab (`:2183-2196`): flip the selected entry's
    /// `[subagents.toggle]` state. The composition writes and rebuilds
    /// the list from disk (`rebuild_agents`, `:322-328`).
    case toggleAgent(index: Int)
    /// `s` on the Agents tab (`:2152-2181`): set the selected entry as
    /// `[agent] name`, or clear the key when it already IS the explicit
    /// config name. The composition writes and re-resolves the default.
    case setDefaultAgent(index: Int)
}

// MARK: - Overlay state

/// The agents/personas modal. Read-only: every state change here is
/// navigation, never data.
public struct PagerAgentsOverlay: Sendable, Equatable {
    public var activeTab: PagerAgentsTab
    public var agents: [PagerAgentsListEntry]
    public var personas: [PagerAgentsPersonaEntry]

    /// Index into `agents` (`selected`, `:240`) — an entry index, not a
    /// painted-row index, exactly as upstream keeps it.
    public var selectedAgent: Int
    /// Index into `personas` (`persona_selected`, `:266`).
    public var selectedPersona: Int

    public var searchQuery: String
    public var searchActive: Bool

    /// Expanded agent entries. Upstream stores an `expanded` bool on each
    /// entry (`:64`); a set over indexes is the same information without
    /// making every navigation key rewrite entry rows.
    public var expandedAgents: Set<Int>
    /// Expanded persona entries (`persona_expanded`, `:269`).
    public var expandedPersonas: Set<Int>

    /// The resolved startup-agent name (`default_agent`, `:257-259`) —
    /// `[agent]` → `GROK_AGENT` → model agentType → built-in default,
    /// resolved by the CLI layer (`resolve_default_agent_name`, `:712-722`).
    public var defaultAgentName: String

    /// Inline status line (`message`, `:251-252`), set by the composition
    /// after a `t`/`s` write resolves and cleared here on the next key
    /// (`:1978`).
    public var message: PagerAgentsMessage?

    public init(
        activeTab: PagerAgentsTab = .agents,
        agents: [PagerAgentsListEntry] = [],
        personas: [PagerAgentsPersonaEntry] = [],
        selectedAgent: Int = 0,
        selectedPersona: Int = 0,
        searchQuery: String = "",
        searchActive: Bool = false,
        expandedAgents: Set<Int> = [],
        expandedPersonas: Set<Int> = [],
        defaultAgentName: String = "",
        message: PagerAgentsMessage? = nil
    ) {
        self.activeTab = activeTab
        self.agents = agents
        self.personas = personas
        self.selectedAgent = selectedAgent
        self.selectedPersona = selectedPersona
        self.searchQuery = searchQuery
        self.searchActive = searchActive
        self.expandedAgents = expandedAgents
        self.expandedPersonas = expandedPersonas
        self.defaultAgentName = defaultAgentName
        self.message = message
    }

    // MARK: Filtering (`filtered_indices`, `:892-905`; personas `:941-959`)

    public func filteredAgentIndices() -> [Int] {
        guard !searchQuery.isEmpty else { return Array(agents.indices) }
        let query = searchQuery.lowercased()
        return agents.indices.filter { index in
            agents[index].name.lowercased().contains(query)
                || agents[index].description.lowercased().contains(query)
        }
    }

    public func filteredPersonaIndices() -> [Int] {
        guard !searchQuery.isEmpty else { return Array(personas.indices) }
        let query = searchQuery.lowercased()
        return personas.indices.filter { index in
            personas[index].name.lowercased().contains(query)
                || (personas[index].description ?? "").lowercased().contains(query)
        }
    }

    // MARK: Selection (`select_next`/`select_prev`, `:907-927`; personas `:961-981`)

    /// Clamps at the ends (no wrap); a selection that fell out of the
    /// filter recovers to the first (next) or last (prev) visible entry —
    /// upstream's `unwrap_or` arms.
    mutating func selectNextAgent() {
        let indices = filteredAgentIndices()
        guard !indices.isEmpty else { return }
        let position = indices.firstIndex(of: selectedAgent)
        let next = position.map { min($0 + 1, indices.count - 1) } ?? 0
        selectedAgent = indices[next]
    }

    mutating func selectPreviousAgent() {
        let indices = filteredAgentIndices()
        guard !indices.isEmpty else { return }
        let position = indices.firstIndex(of: selectedAgent)
        let previous = position.map { max($0 - 1, 0) } ?? (indices.count - 1)
        selectedAgent = indices[previous]
    }

    mutating func selectNextPersona() {
        let indices = filteredPersonaIndices()
        guard !indices.isEmpty else { return }
        let position = indices.firstIndex(of: selectedPersona)
        let next = position.map { min($0 + 1, indices.count - 1) } ?? 0
        selectedPersona = indices[next]
    }

    mutating func selectPreviousPersona() {
        let indices = filteredPersonaIndices()
        guard !indices.isEmpty else { return }
        let position = indices.firstIndex(of: selectedPersona)
        let previous = position.map { max($0 - 1, 0) } ?? (indices.count - 1)
        selectedPersona = indices[previous]
    }

    /// A text change re-anchors the selection on the first visible entry
    /// of the ACTIVE tab (`reset_selection_after_search_change`,
    /// `:365-378`); cursor-only edits do not.
    mutating func resetSelectionAfterSearchChange() {
        switch activeTab {
        case .agents:
            if let first = filteredAgentIndices().first { selectedAgent = first }
        case .personas:
            if let first = filteredPersonaIndices().first { selectedPersona = first }
        }
    }

    /// `switch_agents_tab` (`:1970-1975`): the shared search resets on
    /// every tab switch. (The create/confirm overlay clearing in the same
    /// function is b3 state this slice does not carry.)
    mutating func switchTab(_ tab: PagerAgentsTab) {
        activeTab = tab
        searchQuery = ""
        searchActive = false
    }

    // MARK: Key handling

    /// Ctrl+D/U and PageDown/PageUp step — ten selection moves
    /// (`:2100-2123`, `:2220-2243`).
    static let pageStep = 10

    public mutating func handle(_ event: KeyEvent) -> PagerAgentsOutcome {
        // Every key clears the inline message first (`handle_agents_key`,
        // `:1978`) — a status line lives exactly one keypress.
        message = nil
        if searchActive { return handleSearch(event) }

        // Chrome keys shared by both tabs (`handle_agents_key`,
        // `:2008-2038`): Esc closes (the modal-window CloseRequested arm),
        // Tab/Shift+Tab cycle tabs.
        switch event.key {
        case .escape:
            return .close
        case .tab:
            switchTab(activeTab.next())
            return .redraw
        case .backTab:
            switchTab(activeTab.previous())
            return .redraw
        default:
            break
        }

        switch activeTab {
        case .agents: return handleAgentsTabKey(event)
        case .personas: return handlePersonasTabKey(event)
        }
    }

    /// `handle_agents_tab_key` (`:2082-2199`). The mutation arms `t`
    /// (`:2183-2196`) and `s` (`:2152-2181`) emit outcomes for the
    /// composition's writers; upstream applies NO per-entry-kind guard on
    /// either — a builtin toggles like a file agent, and a disabled entry
    /// can still be set default — so neither does this handler.
    private mutating func handleAgentsTabKey(_ event: KeyEvent) -> PagerAgentsOutcome {
        if event.modifiers.contains(.control) {
            switch event.key {
            case .char("d"):
                for _ in 0..<Self.pageStep { selectNextAgent() }
                return .redraw
            case .char("u"):
                for _ in 0..<Self.pageStep { selectPreviousAgent() }
                return .redraw
            default:
                return .consumed
            }
        }
        switch event.key {
        case .down, .char("j"):
            selectNextAgent()
            return .redraw
        case .up, .char("k"):
            selectPreviousAgent()
            return .redraw
        case .right, .char("e"):
            // `expand` (`:929-933`).
            if agents.indices.contains(selectedAgent) { expandedAgents.insert(selectedAgent) }
            return .redraw
        case .left, .char("E"):
            if agents.indices.contains(selectedAgent) { expandedAgents.remove(selectedAgent) }
            return .redraw
        case .pageDown:
            for _ in 0..<Self.pageStep { selectNextAgent() }
            return .redraw
        case .pageUp:
            for _ in 0..<Self.pageStep { selectPreviousAgent() }
            return .redraw
        case .enter, .char("o"):
            // `ViewAgent` (`:2124-2146`): a file-based entry views its
            // source, a built-in with a prompt body views the synthesized
            // markdown, anything else is silently inert (upstream's
            // `Unchanged` arm).
            guard agents.indices.contains(selectedAgent) else { return .consumed }
            let entry = agents[selectedAgent]
            guard entry.sourcePath != nil || entry.viewContent != nil else { return .consumed }
            return .viewAgent(index: selectedAgent)
        case .char("/"), .char("i"):
            // Both are search-focus, empty modifiers only (`:2147-2150`).
            guard event.modifiers.isEmpty else { return .consumed }
            searchActive = true
            return .redraw
        case .char("q"):
            return .close
        case .char("s"):
            // `s` (`:2152-2181`): the whole set/clear decision — including
            // the fresh `[agent] name` read it hinges on — runs in the
            // composition, which owns config IO. An empty list is
            // upstream's silent fall-through to `Changed` (`:2153,:2180`).
            guard agents.indices.contains(selectedAgent) else { return .redraw }
            return .setDefaultAgent(index: selectedAgent)
        case .char("t"):
            // `t` (`:2183-2196`): flip the selected entry. The composition
            // writes `!entry.enabled` and rebuilds the list from disk.
            guard agents.indices.contains(selectedAgent) else { return .redraw }
            return .toggleAgent(index: selectedAgent)
        default:
            return .consumed
        }
    }

    /// `handle_personas_tab_key` (`:2202-2290`), mutation arms excluded:
    /// `n` new (`:2261-2264`) and `d` delete (`:2265-2282`) are B9-b3.
    /// `t`/`s` do NOT exist on this tab upstream — the Personas handler
    /// has no such arms — so they fall to the swallow default here.
    private mutating func handlePersonasTabKey(_ event: KeyEvent) -> PagerAgentsOutcome {
        if event.modifiers.contains(.control) {
            switch event.key {
            case .char("d"):
                for _ in 0..<Self.pageStep { selectNextPersona() }
                return .redraw
            case .char("u"):
                for _ in 0..<Self.pageStep { selectPreviousPersona() }
                return .redraw
            default:
                return .consumed
            }
        }
        switch event.key {
        case .down, .char("j"):
            selectNextPersona()
            return .redraw
        case .up, .char("k"):
            selectPreviousPersona()
            return .redraw
        case .right, .char("e"):
            guard personas.indices.contains(selectedPersona) else { return .consumed }
            expandedPersonas.insert(selectedPersona)
            return .redraw
        case .left, .char("E"):
            expandedPersonas.remove(selectedPersona)
            return .redraw
        case .pageDown:
            for _ in 0..<Self.pageStep { selectNextPersona() }
            return .redraw
        case .pageUp:
            for _ in 0..<Self.pageStep { selectPreviousPersona() }
            return .redraw
        case .enter, .char("o"):
            guard personas.indices.contains(selectedPersona) else { return .consumed }
            let entry = personas[selectedPersona]
            guard entry.sourcePath != nil || entry.viewContent != nil else { return .consumed }
            return .viewPersona(index: selectedPersona)
        case .char("/"), .char("i"):
            guard event.modifiers.isEmpty else { return .consumed }
            searchActive = true
            return .redraw
        case .char("q"):
            return .close
        default:
            return .consumed
        }
    }

    /// Search-mode keys (`handle_agents_key`, `:1985-2006`): Esc resets
    /// the query AND leaves search; Enter commits (query kept);
    /// Tab/Shift+Tab still switch tabs (which resets the search). Editing
    /// is append/backspace — the extensions modal's recorded simplification
    /// of upstream's cursor-bearing `LineEditor`.
    private mutating func handleSearch(_ event: KeyEvent) -> PagerAgentsOutcome {
        switch event.key {
        case .escape:
            searchQuery = ""
            searchActive = false
            resetSelectionAfterSearchChange()
            return .redraw
        case .enter:
            searchActive = false
            return .redraw
        case .tab:
            switchTab(activeTab.next())
            return .redraw
        case .backTab:
            switchTab(activeTab.previous())
            return .redraw
        case .backspace:
            guard !searchQuery.isEmpty else { return .consumed }
            searchQuery.removeLast()
            resetSelectionAfterSearchChange()
            return .redraw
        case .char(let character) where event.modifiers.subtracting(.shift).isEmpty:
            guard !character.isNewline,
                  character.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F })
            else { return .consumed }
            searchQuery.append(character)
            resetSelectionAfterSearchChange()
            return .redraw
        default:
            return .consumed
        }
    }
}
