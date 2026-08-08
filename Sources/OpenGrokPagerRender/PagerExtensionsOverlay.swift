// PagerExtensionsOverlay.swift
//
// The extensions modal's state and key handling — the tabbed viewer behind
// `/hooks`, `/plugins`, `/marketplace`, `/skills` and `Ctrl+L`.
// Ports `xai-grok-pager/src/views/extensions_modal.rs` at upstream 650c1db7,
// restricted to the READ-ONLY surface: tab order and labels (`:495-521`),
// Tab/Shift+Tab wrap (`:525-543`), the status filter (`:563-594`), and the
// per-tab row shapes (`:2567-3166`). None of upstream's mutation keys
// (add/remove/toggle/install/auth) are handled or advertised here — a key on
// the footer whose backing does not exist is exactly the no-op row AGENTS.md
// §4 forbids. `r` survives because it re-calls the live loader; that is a
// real reload, not a promise.
//
// Like `PagerSettingsOverlay`, this is a value type that owns navigation,
// search, filter, and expansion, and never touches the data sources: the CLI
// layer builds the row snapshots (`LiveExtensionsComposition`) and handles the
// one outward-facing outcome, `.reload`.

import Foundation
import OpenGrokTerminalCore

// MARK: - Tabs

/// `ExtensionsTab` (`extensions_modal.rs:495-554`): display order, labels,
/// and wrapping Tab/Shift+Tab cycle, all byte-faithful.
public enum PagerExtensionsTab: String, Sendable, Equatable, Hashable, CaseIterable {
    case hooks
    case plugins
    case marketplace
    case skills
    case mcpServers

    /// All tabs in display order (`ALL`, `:505-511`).
    public static let all: [PagerExtensionsTab] = [
        .hooks, .plugins, .marketplace, .skills, .mcpServers
    ]

    /// Display label for the tab bar (`label()`, `:514-521`).
    public var label: String {
        switch self {
        case .hooks: return "Hooks"
        case .plugins: return "Plugins"
        case .marketplace: return "Marketplace"
        case .skills: return "Skills"
        case .mcpServers: return "MCP Servers"
        }
    }

    /// Next tab, wrapping (`next()`, `:525-533`).
    public func next() -> PagerExtensionsTab {
        switch self {
        case .hooks: return .plugins
        case .plugins: return .marketplace
        case .marketplace: return .skills
        case .skills: return .mcpServers
        case .mcpServers: return .hooks
        }
    }

    /// Previous tab, wrapping (`prev()`, `:535-543`).
    public func previous() -> PagerExtensionsTab {
        switch self {
        case .hooks: return .mcpServers
        case .plugins: return .hooks
        case .marketplace: return .plugins
        case .skills: return .marketplace
        case .mcpServers: return .skills
        }
    }

    /// Whether the tab offers the enabled/disabled status filter
    /// (`has_filter`, `:2518-2524` — every tab but Marketplace).
    public var hasStatusFilter: Bool { self != .marketplace }
}

// MARK: - Status filter

/// `StatusFilter` (`extensions_modal.rs:563-594`).
public enum PagerExtensionsStatusFilter: Sendable, Equatable, Hashable {
    case all
    case enabled
    case disabled

    public var label: String {
        switch self {
        case .all: return "All"
        case .enabled: return "Enabled"
        case .disabled: return "Disabled"
        }
    }

    public func next() -> PagerExtensionsStatusFilter {
        switch self {
        case .all: return .enabled
        case .enabled: return .disabled
        case .disabled: return .all
        }
    }

    public func matches(_ enabled: Bool) -> Bool {
        switch self {
        case .all: return true
        case .enabled: return enabled
        case .disabled: return !enabled
        }
    }
}

// MARK: - Row data

/// One loaded hook, as the Hooks tab paints it (`HookInfo` fields consumed at
/// `extensions_modal.rs:2840-2871`). `sourceLabel` is precomputed by the CLI
/// layer because deriving it needs `$OPENGROK_HOME` (`derive_source_label`,
/// `:2238-2303`).
public struct PagerExtensionsHookRow: Sendable, Equatable, Hashable {
    public var event: String
    public var matcher: String?
    /// Command or URL; the painter falls back to upstream's "(no command)".
    public var command: String?
    public var sourceDir: String
    public var sourceLabel: String
    public var disabled: Bool

    public init(
        event: String,
        matcher: String? = nil,
        command: String? = nil,
        sourceDir: String,
        sourceLabel: String,
        disabled: Bool = false
    ) {
        self.event = event
        self.matcher = matcher
        self.command = command
        self.sourceDir = sourceDir
        self.sourceLabel = sourceLabel
        self.disabled = disabled
    }
}

/// One discovered skill (`extensions_modal.rs:2567-2616`). `source` is the
/// precomputed `skill_source_str` (`:2351-2381`).
public struct PagerExtensionsSkillRow: Sendable, Equatable, Hashable {
    public var label: String
    public var source: String
    public var author: String?
    public var description: String
    public var path: String
    public var tools: [String]
    public var enabled: Bool

    public init(
        label: String,
        source: String,
        author: String? = nil,
        description: String,
        path: String,
        tools: [String] = [],
        enabled: Bool = true
    ) {
        self.label = label
        self.source = source
        self.author = author
        self.description = description
        self.path = path
        self.tools = tools
        self.enabled = enabled
    }
}

/// One installed plugin repository from `registry.json` — the honest subset
/// this port can back (`PluginInstallRegistry`). Upstream's Plugins tab shows
/// per-plugin component counts from the shell (`:2700-2797`); this port has
/// no shell channel for those, so the row carries what the registry knows.
public struct PagerExtensionsPluginRow: Sendable, Equatable, Hashable {
    public var name: String
    public var source: String
    public var url: String?
    public var path: String?
    public var ref: String?
    public var sha: String?
    public var pluginNames: [String]
    public var enabled: Bool

    public init(
        name: String,
        source: String,
        url: String? = nil,
        path: String? = nil,
        ref: String? = nil,
        sha: String? = nil,
        pluginNames: [String] = [],
        enabled: Bool = true
    ) {
        self.name = name
        self.source = source
        self.url = url
        self.path = path
        self.ref = ref
        self.sha = sha
        self.pluginNames = pluginNames
        self.enabled = enabled
    }
}

/// One session MCP server — the same facts `/mcps` shows (name,
/// connected/failed, tool count). Upstream's tab additionally groups servers
/// into config-source sections and shows enable state (`:3020-3151`); this
/// port's session connections carry neither, a recorded honest subset.
public struct PagerExtensionsMCPRow: Sendable, Equatable, Hashable {
    public var name: String
    public var toolNames: [String]
    public var failure: String?

    public init(name: String, toolNames: [String] = [], failure: String? = nil) {
        self.name = name
        self.toolNames = toolNames
        self.failure = failure
    }

    public var isConnected: Bool { failure == nil }
}

// MARK: - Entries

/// One painted line-group in the list: a collapsible group header or a data
/// row. The shared shape both the painter and the key handler derive from
/// state, so what the cursor skips is exactly what the eye sees.
public struct PagerExtensionsField: Sendable, Equatable, Hashable {
    public var label: String
    public var value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

public enum PagerExtensionsBadge: Sendable, Equatable, Hashable {
    case none
    /// `[disabled]` in the error accent (`:2861-2870`).
    case disabled
    /// `[connected]` in the success accent.
    case connected
    /// `[failed]` in the error accent.
    case failed

    public var text: String {
        switch self {
        case .none: return ""
        case .disabled: return "[disabled]"
        case .connected: return "[connected]"
        case .failed: return "[failed]"
        }
    }
}

public struct PagerExtensionsEntry: Sendable, Equatable {
    public var id: String
    public var label: String
    public var rightLabel: String
    public var descriptionLines: [String]
    public var fields: [PagerExtensionsField]
    public var indent: Int
    public var badge: PagerExtensionsBadge
    /// Non-nil marks a collapsible group header (hooks source groups).
    public var groupKey: String?
    public var dimmed: Bool
    /// The Marketplace notice is painted but never focused.
    public var isSelectable: Bool

    public init(
        id: String,
        label: String,
        rightLabel: String = "",
        descriptionLines: [String] = [],
        fields: [PagerExtensionsField] = [],
        indent: Int = 0,
        badge: PagerExtensionsBadge = .none,
        groupKey: String? = nil,
        dimmed: Bool = false,
        isSelectable: Bool = true
    ) {
        self.id = id
        self.label = label
        self.rightLabel = rightLabel
        self.descriptionLines = descriptionLines
        self.fields = fields
        self.indent = indent
        self.badge = badge
        self.groupKey = groupKey
        self.dimmed = dimmed
        self.isSelectable = isSelectable
    }
}

// MARK: - Outcome

/// What a keystroke decided. `.reload` is the only outward-facing outcome:
/// the overlay cannot reach the loaders, so the composition rebuilds the
/// snapshot and swaps it in.
public enum PagerExtensionsOutcome: Sendable, Equatable {
    case redraw
    case consumed
    case close
    case reload(PagerExtensionsTab)
}

// MARK: - Overlay state

/// The extensions modal. Read-only: every state change here is navigation,
/// never data.
public struct PagerExtensionsOverlay: Sendable, Equatable {
    public var activeTab: PagerExtensionsTab

    public var hooks: [PagerExtensionsHookRow]
    public var skills: [PagerExtensionsSkillRow]
    public var plugins: [PagerExtensionsPluginRow]
    public var mcpServers: [PagerExtensionsMCPRow]

    /// Per-tab filters, mirroring upstream's independent `hooks_filter` /
    /// `plugins_filter` / `skills_filter` / `mcps_filter` (`:2525-2530`).
    public var hooksFilter: PagerExtensionsStatusFilter
    public var pluginsFilter: PagerExtensionsStatusFilter
    public var skillsFilter: PagerExtensionsStatusFilter
    public var mcpsFilter: PagerExtensionsStatusFilter

    public var searchQuery: String
    public var searchActive: Bool
    /// Index into `entries()`.
    public var selectedIndex: Int
    public var scrollOffset: Int
    /// Entry ids whose detail fields are pinned open.
    public var expandedRows: Set<String>
    /// Collapsed group keys (hook source directories).
    public var collapsedGroups: Set<String>

    public init(
        activeTab: PagerExtensionsTab = .hooks,
        hooks: [PagerExtensionsHookRow] = [],
        skills: [PagerExtensionsSkillRow] = [],
        plugins: [PagerExtensionsPluginRow] = [],
        mcpServers: [PagerExtensionsMCPRow] = [],
        hooksFilter: PagerExtensionsStatusFilter = .all,
        pluginsFilter: PagerExtensionsStatusFilter = .all,
        skillsFilter: PagerExtensionsStatusFilter = .all,
        mcpsFilter: PagerExtensionsStatusFilter = .all,
        searchQuery: String = "",
        searchActive: Bool = false,
        selectedIndex: Int = 0,
        scrollOffset: Int = 0,
        expandedRows: Set<String> = [],
        collapsedGroups: Set<String> = []
    ) {
        self.activeTab = activeTab
        self.hooks = hooks
        self.skills = skills
        self.plugins = plugins
        self.mcpServers = mcpServers
        self.hooksFilter = hooksFilter
        self.pluginsFilter = pluginsFilter
        self.skillsFilter = skillsFilter
        self.mcpsFilter = mcpsFilter
        self.searchQuery = searchQuery
        self.searchActive = searchActive
        self.selectedIndex = selectedIndex
        self.scrollOffset = scrollOffset
        self.expandedRows = expandedRows
        self.collapsedGroups = collapsedGroups
    }

    // MARK: Derived state

    public var activeFilter: PagerExtensionsStatusFilter {
        switch activeTab {
        case .hooks: return hooksFilter
        case .plugins: return pluginsFilter
        case .skills: return skillsFilter
        case .mcpServers: return mcpsFilter
        case .marketplace: return .all
        }
    }

    /// Substring match on the entry's searchable text. Upstream uses a
    /// subsequence fuzzy match (`fuzzy_matches`); this port matches on
    /// case-insensitive substring — recorded divergence, same result for
    /// every prefix query.
    private func matchesQuery(_ haystacks: [String?]) -> Bool {
        let query = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return true }
        return haystacks.contains { $0?.lowercased().contains(query) == true }
    }

    /// The visible entry list for the active tab. Row shapes and labels are
    /// upstream's (`:2567-3166`), restricted to what the port's snapshots
    /// carry.
    public func entries() -> [PagerExtensionsEntry] {
        switch activeTab {
        case .hooks: return hookEntries()
        case .skills: return skillEntries()
        case .plugins: return pluginEntries()
        case .marketplace: return marketplaceEntries()
        case .mcpServers: return mcpEntries()
        }
    }

    /// Hooks grouped by source dir, sorted — upstream's `BTreeMap` order
    /// (`:2799-2872`). Searching forces groups open, exactly as upstream
    /// ignores collapse state mid-search (`:2821-2824`).
    private func hookEntries() -> [PagerExtensionsEntry] {
        var groups: [String: [(Int, PagerExtensionsHookRow)]] = [:]
        for (index, hook) in hooks.enumerated() {
            guard matchesQuery([hook.event, hook.matcher, hook.command, hook.sourceLabel]) else { continue }
            guard hooksFilter.matches(!hook.disabled) else { continue }
            groups[hook.sourceDir, default: []].append((index, hook))
        }
        let searching = !searchQuery.isEmpty
        var entries: [PagerExtensionsEntry] = []
        for sourceDir in groups.keys.sorted() {
            guard let grouped = groups[sourceDir], let first = grouped.first else { continue }
            // `"{label} ({n} hooks)"` (`:2825`).
            entries.append(PagerExtensionsEntry(
                id: "hookgroup:\(sourceDir)",
                label: "\(first.1.sourceLabel) (\(grouped.count) hooks)",
                groupKey: sourceDir
            ))
            let collapsed = !searching && collapsedGroups.contains(sourceDir)
            guard !collapsed else { continue }
            for (index, hook) in grouped {
                // `"on:{event}{ /matcher}"` and `"→ {command}"` (`:2840-2853`).
                let matcher = hook.matcher.map { " /\($0)" } ?? ""
                entries.append(PagerExtensionsEntry(
                    id: "hook:\(sourceDir):\(index)",
                    label: "on:\(hook.event)\(matcher)",
                    descriptionLines: ["\u{2192} \(hook.command ?? "(no command)")"],
                    indent: 1,
                    badge: hook.disabled ? .disabled : .none,
                    dimmed: hook.disabled
                ))
            }
        }
        return entries
    }

    /// Skills, name-hits ranked ahead of description-hits
    /// (`filter_and_sort_skills`, `:2315-2349`; row shape `:2567-2616`).
    /// Upstream's trailing "Workflows" section (`:2631-2698`) is not ported:
    /// this port's workflow surface is `/workflows`, a different feature.
    private func skillEntries() -> [PagerExtensionsEntry] {
        var nameMatches: [PagerExtensionsSkillRow] = []
        var descriptionMatches: [PagerExtensionsSkillRow] = []
        let query = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        for skill in skills {
            guard skillsFilter.matches(skill.enabled) else { continue }
            if query.isEmpty {
                nameMatches.append(skill)
                continue
            }
            let nameHit = skill.label.lowercased().contains(query)
            let authorHit = skill.author?.lowercased().contains(query) == true
            let descriptionHit = skill.description.lowercased().contains(query)
            if nameHit || authorHit {
                nameMatches.append(skill)
            } else if descriptionHit {
                descriptionMatches.append(skill)
            }
        }
        return (nameMatches + descriptionMatches).map { skill in
            // `"({source} · {author})"` / `"({source})"` (`:2575-2578`).
            let right: String
            if let author = skill.author, !author.isEmpty {
                right = "(\(skill.source) \u{B7} \(author))"
            } else {
                right = "(\(skill.source))"
            }
            var fields = [PagerExtensionsField(label: "path", value: skill.path)]
            if let author = skill.author, !author.isEmpty {
                fields.append(PagerExtensionsField(label: "author", value: author))
            }
            if !skill.tools.isEmpty {
                fields.append(PagerExtensionsField(
                    label: "tools",
                    value: skill.tools.joined(separator: ", ")
                ))
            }
            return PagerExtensionsEntry(
                id: "skill:\(skill.path)",
                label: skill.label,
                rightLabel: right,
                descriptionLines: skill.description.isEmpty ? [] : [skill.description],
                fields: fields,
                badge: skill.enabled ? .none : .disabled,
                dimmed: !skill.enabled
            )
        }
    }

    /// The install registry, one row per repository. Upstream groups shell
    /// plugins by origin and shows component counts (`:2700-2783`); the
    /// registry knows name, enabled, and source — the honest subset.
    private func pluginEntries() -> [PagerExtensionsEntry] {
        var entries: [PagerExtensionsEntry] = []
        for plugin in plugins {
            guard matchesQuery([plugin.name, plugin.source] + plugin.pluginNames) else { continue }
            guard pluginsFilter.matches(plugin.enabled) else { continue }
            var fields = [PagerExtensionsField(label: "source", value: plugin.source)]
            if let url = plugin.url { fields.append(PagerExtensionsField(label: "url", value: url)) }
            if let path = plugin.path { fields.append(PagerExtensionsField(label: "path", value: path)) }
            if let ref = plugin.ref { fields.append(PagerExtensionsField(label: "ref", value: ref)) }
            if let sha = plugin.sha { fields.append(PagerExtensionsField(label: "sha", value: sha)) }
            if !plugin.pluginNames.isEmpty {
                fields.append(PagerExtensionsField(
                    label: "plugins",
                    value: plugin.pluginNames.joined(separator: ", ")
                ))
            }
            entries.append(PagerExtensionsEntry(
                id: "plugin:\(plugin.name)",
                label: plugin.name,
                descriptionLines: [plugin.source],
                fields: fields,
                badge: plugin.enabled ? .none : .disabled,
                dimmed: !plugin.enabled
            ))
        }
        return entries
    }

    /// Deferred: upstream's Marketplace tab is a live multi-source install
    /// surface (`:2888-3018`). This port has no marketplace fetch channel in
    /// the TUI, so the tab says where the real surface lives instead of
    /// faking a source list.
    static let marketplaceNotice =
        "Marketplace management runs in the CLI: open-grok plugin marketplace"

    private func marketplaceEntries() -> [PagerExtensionsEntry] {
        [PagerExtensionsEntry(
            id: "marketplace-notice",
            label: Self.marketplaceNotice,
            dimmed: true,
            isSelectable: false
        )]
    }

    /// Session MCP servers, sorted by name like `/mcps`. Desc-line shapes are
    /// upstream's (`"{n} tools"` / `"no tools (server may not be connected)"`,
    /// `:3086-3103`); the connected/failed badge stands in for upstream's
    /// richer status set because a session connection knows only those two.
    private func mcpEntries() -> [PagerExtensionsEntry] {
        var entries: [PagerExtensionsEntry] = []
        for server in mcpServers.sorted(by: { $0.name < $1.name }) {
            guard matchesQuery([server.name]) else { continue }
            guard mcpsFilter.matches(server.isConnected) else { continue }
            let description: String
            if let failure = server.failure {
                description = failure
            } else if server.toolNames.isEmpty {
                description = "no tools (server may not be connected)"
            } else {
                description = "\(server.toolNames.count) tools"
            }
            var fields: [PagerExtensionsField] = []
            if !server.toolNames.isEmpty {
                fields.append(PagerExtensionsField(
                    label: "tools",
                    value: server.toolNames.sorted().joined(separator: ", ")
                ))
            }
            entries.append(PagerExtensionsEntry(
                id: "mcp:\(server.name)",
                label: server.name,
                descriptionLines: [description],
                fields: fields,
                badge: server.isConnected ? .connected : .failed,
                dimmed: !server.isConnected
            ))
        }
        return entries
    }

    // MARK: Selection

    mutating func clampSelection() {
        let list = entries()
        guard !list.isEmpty else {
            selectedIndex = 0
            scrollOffset = 0
            return
        }
        selectedIndex = min(max(0, selectedIndex), list.count - 1)
        if !list[selectedIndex].isSelectable {
            if let forward = list[selectedIndex...].firstIndex(where: \.isSelectable) {
                selectedIndex = forward
            } else if let back = list[...selectedIndex].lastIndex(where: \.isSelectable) {
                selectedIndex = back
            }
        }
    }

    mutating func move(by delta: Int) {
        let list = entries()
        guard !list.isEmpty, delta != 0 else { return }
        let step = delta > 0 ? 1 : -1
        var index = selectedIndex
        for _ in 0..<abs(delta) {
            var next = index + step
            while list.indices.contains(next), !list[next].isSelectable { next += step }
            guard list.indices.contains(next) else { break }
            index = next
        }
        selectedIndex = index
    }

    mutating func moveToEdge(last: Bool) {
        let list = entries()
        let target = last
            ? list.lastIndex(where: \.isSelectable)
            : list.firstIndex(where: \.isSelectable)
        guard let target else { return }
        selectedIndex = target
    }

    mutating func switchTab(_ tab: PagerExtensionsTab) {
        activeTab = tab
        selectedIndex = 0
        scrollOffset = 0
        clampSelection()
    }

    mutating func cycleActiveFilter() {
        switch activeTab {
        case .hooks: hooksFilter = hooksFilter.next()
        case .plugins: pluginsFilter = pluginsFilter.next()
        case .skills: skillsFilter = skillsFilter.next()
        case .mcpServers: mcpsFilter = mcpsFilter.next()
        case .marketplace: return
        }
        selectedIndex = 0
        scrollOffset = 0
        clampSelection()
    }

    // MARK: Key handling

    /// `PageUp`/`PageDown` step, matching the settings modal's fixed stride.
    static let pageStep = 10

    public mutating func handle(_ event: KeyEvent) -> PagerExtensionsOutcome {
        if searchActive { return handleSearch(event) }

        switch event.key {
        case .escape:
            // Browse-Esc closes; a committed query does not survive the
            // modal, so there is nothing to unwind first.
            return .close
        case .tab:
            switchTab(activeTab.next())
            return .redraw
        case .backTab:
            switchTab(activeTab.previous())
            return .redraw
        case .up:
            move(by: -1); return .redraw
        case .down:
            move(by: 1); return .redraw
        case .pageUp:
            move(by: -Self.pageStep); return .redraw
        case .pageDown:
            move(by: Self.pageStep); return .redraw
        case .home:
            moveToEdge(last: false); return .redraw
        case .end:
            moveToEdge(last: true); return .redraw
        case .enter:
            return toggleSelectedExpansion()
        case .backspace:
            // Edits the committed query in place, like the settings modal.
            guard !searchQuery.isEmpty else { return .consumed }
            searchQuery.removeLast()
            selectedIndex = 0
            clampSelection()
            return .redraw
        case .char(let character) where event.modifiers.subtracting(.shift).isEmpty:
            switch character {
            case "j": move(by: 1); return .redraw
            case "k": move(by: -1); return .redraw
            case "g": moveToEdge(last: false); return .redraw
            case "G": moveToEdge(last: true); return .redraw
            case "e": return toggleSelectedExpansion()
            case "/", "i":
                searchActive = true
                return .redraw
            case "f":
                guard activeTab.hasStatusFilter else { return .consumed }
                cycleActiveFilter()
                return .redraw
            case "r":
                // Honest reload only: the composition re-calls the live
                // loader and swaps the rows. Marketplace has no loader to
                // call, so `r` there is a no-op rather than a lie.
                guard activeTab != .marketplace else { return .consumed }
                return .reload(activeTab)
            default:
                return .consumed
            }
        default:
            return .consumed
        }
    }

    private mutating func handleSearch(_ event: KeyEvent) -> PagerExtensionsOutcome {
        switch event.key {
        case .escape:
            // Clears the query and returns to the list — never closes the
            // modal from inside search.
            searchQuery = ""
            searchActive = false
            selectedIndex = 0
            clampSelection()
            return .redraw
        case .enter:
            searchActive = false
            clampSelection()
            return .redraw
        case .up:
            move(by: -1); return .redraw
        case .down:
            move(by: 1); return .redraw
        case .backspace:
            guard !searchQuery.isEmpty else { return .consumed }
            searchQuery.removeLast()
            selectedIndex = 0
            clampSelection()
            return .redraw
        case .char(let character) where event.modifiers.subtracting(.shift).isEmpty:
            guard !character.isNewline,
                  character.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F })
            else { return .consumed }
            searchQuery.append(character)
            selectedIndex = 0
            clampSelection()
            return .redraw
        default:
            return .consumed
        }
    }

    /// `e`/Enter: a group header collapses or expands its group; a data row
    /// pins its detail fields open or shut. Read-only in both cases.
    private mutating func toggleSelectedExpansion() -> PagerExtensionsOutcome {
        let list = entries()
        guard list.indices.contains(selectedIndex) else { return .consumed }
        let entry = list[selectedIndex]
        if let groupKey = entry.groupKey {
            if collapsedGroups.remove(groupKey) == nil {
                collapsedGroups.insert(groupKey)
            }
            clampSelection()
            return .redraw
        }
        guard !entry.fields.isEmpty else { return .consumed }
        if expandedRows.remove(entry.id) == nil {
            expandedRows.insert(entry.id)
        }
        return .redraw
    }
}
