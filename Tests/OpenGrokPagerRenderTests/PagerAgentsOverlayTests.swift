// PagerAgentsOverlayTests.swift
//
// The agents/personas modal at the overlay seam (Wave 18 B9-b1/b2): tab
// cycle (`agents_modal.rs:27-55` at upstream 650c1db7), selection clamping
// and filter recovery (`:907-981`), search filtering (`:892-905`,
// `:941-959`), the painted row shapes for BOTH tabs (`:1278-1494`,
// `:1496-1758`), the b2 mutation keys `t`/`s` on the Agents tab ONLY
// (`:2152-2196`) with the inline-message machinery (`:67-99`, `:1978`,
// `:1946-1959`), and that the b3 keys (`n`, `d`) stay unhandled and
// unadvertised. Full frames are painted through `renderPagerFrame` so the
// assertions see what a user sees.

import Foundation
@testable import OpenGrokPagerRender
import OpenGrokTerminalCore
import Testing

// MARK: - Helpers

private func agentsFrame(
    _ overlay: PagerAgentsOverlay,
    width: Int = 120,
    height: Int = 36,
    theme: PagerRenderTheme = .grokNight
) -> PagerRenderResult {
    renderPagerFrame(
        PagerRenderState(
            size: TerminalSize(width: width, height: height),
            conversation: [.message(PagerMessage(role: .assistant, text: "behind"))],
            input: PagerComposerState(text: ""),
            theme: theme,
            showScrollbar: false,
            overlays: PagerOverlayStack([PagerOverlay.agents(overlay)])
        )
    )
}

private func painted(_ overlay: PagerAgentsOverlay) -> String {
    agentsFrame(overlay).snapshot()
}

private func character(_ value: Character, modifiers: KeyModifiers = []) -> KeyEvent {
    KeyEvent(key: .char(value), modifiers: modifiers, character: value)
}

/// The five user-visible built-ins in upstream's order
/// (`user_visible_builtins`, `agents_modal.rs:275-283`), as the CLI
/// snapshot layer would deliver them.
private func builtinEntries(toggledOff: Set<String> = []) -> [PagerAgentsListEntry] {
    [
        ("grok-build", "Grok Build agent for software engineering tasks."),
        ("general-purpose", "General purpose agent for multi-step tasks."),
        ("explore", "Fast, read-only agent specialized for codebase exploration."),
        ("plan", "Software architect for planning implementation strategies."),
        ("browser-use", "Web browsing and interaction agent."),
    ].map { name, description in
        PagerAgentsListEntry(
            name: name,
            description: description,
            scope: .builtIn,
            enabled: !toggledOff.contains(name),
            isBuiltin: true,
            detailLines: ["  Model: inherit", "  Prompt mode: extend"],
            viewContent: "*\(name) prompt body*"
        )
    }
}

private func projectEntry(
    name: String = "reviewer",
    description: String = "Reviews code changes"
) -> PagerAgentsListEntry {
    PagerAgentsListEntry(
        name: name,
        description: description,
        scope: .project,
        sourcePath: "/tmp/proj/.opengrok/agents/\(name).md",
        detailLines: ["  Model: inherit", "  Scope: project"]
    )
}

private func samplePersonas() -> [PagerAgentsPersonaEntry] {
    [
        PagerAgentsPersonaEntry(
            name: "socratic",
            description: "Asks questions before answering",
            hasInputs: true,
            hasOutputs: true,
            sourcePath: "/tmp/home/personas/socratic.toml",
            scopeLabel: "user"
        ),
        PagerAgentsPersonaEntry(
            name: "auditor",
            description: "Reviews everything twice",
            sourcePath: "/tmp/proj/.opengrok/personas/auditor.toml",
            scopeLabel: "project"
        ),
        PagerAgentsPersonaEntry(
            name: "inline-one",
            description: nil,
            scopeLabel: "config",
            viewContent: "instructions = \"be inline\""
        ),
    ]
}

// MARK: - Tabs and keys

@Suite("agents modal tabs and keys")
struct PagerAgentsTabTests {
    @Test("display order, labels, and the wrapping cycle match upstream")
    func tabOrderAndCycle() {
        // `ALL`/`label()`/`next()`/`prev()` (`agents_modal.rs:27-55`).
        #expect(PagerAgentsTab.all == [.agents, .personas])
        #expect(PagerAgentsTab.all.map(\.label) == ["Agents", "Personas"])
        #expect(PagerAgentsTab.agents.next() == .personas)
        #expect(PagerAgentsTab.personas.next() == .agents)
        #expect(PagerAgentsTab.agents.previous() == .personas)
    }

    @Test("scope priority matches upstream's dedup order")
    func scopePriority() {
        // `scope_priority` (`agents_modal.rs:404-411`).
        #expect(PagerAgentsScope.project.priority == 3)
        #expect(PagerAgentsScope.user.priority == 2)
        #expect(PagerAgentsScope.bundled.priority == 1)
        #expect(PagerAgentsScope.builtIn.priority == 0)
    }

    @Test("Tab switches tab and resets the shared search")
    func tabResetsSearch() {
        // `switch_agents_tab` (`agents_modal.rs:1970-1975`).
        var overlay = PagerAgentsOverlay(agents: builtinEntries(), personas: samplePersonas())
        _ = overlay.handle(character("/"))
        _ = overlay.handle(character("x"))
        #expect(overlay.searchQuery == "x")
        #expect(overlay.handle(KeyEvent(key: .tab)) == .redraw)
        #expect(overlay.activeTab == .personas)
        #expect(overlay.searchQuery.isEmpty)
        #expect(!overlay.searchActive)
        #expect(overlay.handle(KeyEvent(key: .backTab)) == .redraw)
        #expect(overlay.activeTab == .agents)
    }

    @Test("j/k clamp at the ends and recover a filtered-out selection")
    func selectionClampsAndRecovers() {
        // `select_next`/`select_prev` (`agents_modal.rs:907-927`).
        var overlay = PagerAgentsOverlay(agents: builtinEntries())
        _ = overlay.handle(character("k"))
        #expect(overlay.selectedAgent == 0, "no wrap past the first entry")
        for _ in 0..<10 { _ = overlay.handle(character("j")) }
        #expect(overlay.selectedAgent == 4, "no wrap past the last entry")
        // A selection that fell out of the filter recovers to the first
        // visible entry on next (`unwrap_or(0)`).
        overlay.searchQuery = "grok-build"
        _ = overlay.handle(character("j"))
        #expect(overlay.selectedAgent == 0)
    }

    @Test("Ctrl+D/U and PageDown/PageUp move the selection by ten")
    func pagingMovesTen() {
        // `:2100-2123`.
        var entries = builtinEntries()
        for index in 0..<20 {
            entries.append(PagerAgentsListEntry(
                name: "agent-\(index)", description: "", scope: .user
            ))
        }
        var overlay = PagerAgentsOverlay(agents: entries)
        #expect(overlay.handle(character("d", modifiers: [.control])) == .redraw)
        #expect(overlay.selectedAgent == 10)
        #expect(overlay.handle(KeyEvent(key: .pageDown)) == .redraw)
        #expect(overlay.selectedAgent == 20)
        #expect(overlay.handle(character("u", modifiers: [.control])) == .redraw)
        #expect(overlay.selectedAgent == 10)
        #expect(overlay.handle(KeyEvent(key: .pageUp)) == .redraw)
        #expect(overlay.selectedAgent == 0)
    }

    @Test("both / and i activate search on both tabs; modified i does not")
    func searchActivation() {
        // `/` and `i`, empty modifiers only (`agents_modal.rs:2147-2150`,
        // `:2283-2286`) — at the pin `i` is search-focus on BOTH tabs,
        // never an editor key (`EditInEditor` is only produced by the b3
        // persona detail modal, `persona_detail.rs:827`).
        for tab in PagerAgentsTab.all {
            for key in ["/", "i"] as [Character] {
                var overlay = PagerAgentsOverlay(
                    activeTab: tab,
                    agents: builtinEntries(),
                    personas: samplePersonas()
                )
                #expect(overlay.handle(character(key)) == .redraw)
                #expect(overlay.searchActive, "\(key) must activate search on \(tab)")
            }
            var overlay = PagerAgentsOverlay(
                activeTab: tab, agents: builtinEntries(), personas: samplePersonas()
            )
            #expect(overlay.handle(character("i", modifiers: [.control])) == .consumed)
            #expect(!overlay.searchActive)
        }
    }

    @Test("search text changes re-anchor the selection; Esc clears, Enter commits")
    func searchSemantics() {
        // `reset_selection_after_search_change` (`:365-378`) and the
        // search-mode Esc/Enter arms (`:1985-1994`).
        var overlay = PagerAgentsOverlay(agents: builtinEntries(), selectedAgent: 4)
        _ = overlay.handle(character("/"))
        for value in "plan" { _ = overlay.handle(character(value)) }
        #expect(overlay.searchQuery == "plan")
        #expect(overlay.selectedAgent == 3, "selection re-anchors on the first match")
        #expect(overlay.filteredAgentIndices() == [3])
        _ = overlay.handle(KeyEvent(key: .enter))
        #expect(!overlay.searchActive)
        #expect(overlay.searchQuery == "plan", "Enter commits, keeping the query")
        _ = overlay.handle(character("/"))
        #expect(overlay.handle(KeyEvent(key: .escape)) == .redraw)
        #expect(overlay.searchQuery.isEmpty, "search-Esc resets the query")
        // Browse-Esc closes; `q` too (`:2151`, `:2287`).
        #expect(overlay.handle(KeyEvent(key: .escape)) == .close)
        #expect(overlay.handle(character("q")) == .close)
    }

    @Test("persona search matches name and description")
    func personaFilter() {
        // `filtered_persona_indices` (`agents_modal.rs:941-959`).
        var overlay = PagerAgentsOverlay(activeTab: .personas, personas: samplePersonas())
        overlay.searchQuery = "twice"
        #expect(overlay.filteredPersonaIndices() == [1])
        overlay.searchQuery = "socratic"
        #expect(overlay.filteredPersonaIndices() == [0])
        overlay.searchQuery = "zzz"
        #expect(overlay.filteredPersonaIndices().isEmpty)
    }

    @Test("Enter/o view: file-backed and body-backed entries produce view outcomes, bare ones are inert")
    func enterViewOutcomes() {
        // `ViewAgent` (`:2124-2146`) and the personas Enter arm
        // (`:2244-2260`, routed through the document overlay in b1).
        var overlay = PagerAgentsOverlay(
            agents: builtinEntries() + [projectEntry()],
            personas: samplePersonas()
        )
        #expect(overlay.handle(KeyEvent(key: .enter)) == .viewAgent(index: 0))
        overlay.selectedAgent = 5
        #expect(overlay.handle(character("o")) == .viewAgent(index: 5))
        // An entry with neither path nor content is silently inert
        // (upstream's `Unchanged` arm).
        var bare = PagerAgentsOverlay(agents: [
            PagerAgentsListEntry(name: "empty", description: "", scope: .builtIn)
        ])
        #expect(bare.handle(KeyEvent(key: .enter)) == .consumed)
        // Personas tab.
        overlay.activeTab = .personas
        overlay.selectedPersona = 2
        #expect(overlay.handle(KeyEvent(key: .enter)) == .viewPersona(index: 2))
    }

    @Test("t and s emit mutation outcomes on the Agents tab, for every entry kind")
    func mutationKeysEmitOutcomes() {
        // `t` (`:2183-2196`) and `s` (`:2152-2181`): upstream applies NO
        // per-entry-kind guard — a builtin toggles like a project agent,
        // and a disabled entry can still be `s`-selected (the disabled/
        // default interplay is unguarded at the pin). The write itself is
        // the composition's; the overlay only names the entry.
        var overlay = PagerAgentsOverlay(
            agents: builtinEntries(toggledOff: ["explore"]) + [projectEntry()]
        )
        // Builtin (index 0).
        #expect(overlay.handle(character("t")) == .toggleAgent(index: 0))
        #expect(overlay.handle(character("s")) == .setDefaultAgent(index: 0))
        // A DISABLED entry (explore, index 2) still takes both keys.
        overlay.selectedAgent = 2
        #expect(overlay.handle(character("t")) == .toggleAgent(index: 2))
        #expect(overlay.handle(character("s")) == .setDefaultAgent(index: 2))
        // A file-based project entry (index 5).
        overlay.selectedAgent = 5
        #expect(overlay.handle(character("t")) == .toggleAgent(index: 5))
        #expect(overlay.handle(character("s")) == .setDefaultAgent(index: 5))
        // An empty list is upstream's silent fall-through to `Changed`
        // (`:2153`, `:2184` — the `if let` guard, then `:2180`/`:2196`).
        var empty = PagerAgentsOverlay()
        #expect(empty.handle(character("t")) == .redraw)
        #expect(empty.handle(character("s")) == .redraw)
    }

    @Test("the b3 keys n and d stay consumed no-ops; t and s do nothing on the Personas tab")
    func unbackedKeysStayInert() {
        // `n` new (`:2261-2264`) and `d` delete (`:2265-2282`) are B9-b3.
        // On the Personas tab upstream's handler has NO `t`/`s` arms
        // (`:2202-2290`), so all four swallow there.
        var agents = PagerAgentsOverlay(agents: builtinEntries())
        for mutation in ["n", "d"] as [Character] {
            let before = agents
            #expect(agents.handle(character(mutation)) == .consumed)
            #expect(agents == before, "b3 key \(mutation) changed Agents-tab state")
        }
        var personas = PagerAgentsOverlay(activeTab: .personas, personas: samplePersonas())
        for mutation in ["t", "s", "n", "d"] as [Character] {
            let before = personas
            #expect(personas.handle(character(mutation)) == .consumed)
            #expect(personas == before, "key \(mutation) changed Personas-tab state")
        }
    }

    @Test("the inline message clears on the next key, whatever it is")
    func messageClearsOnNextKey() {
        // `handle_agents_key` sets `state.message = None` before anything
        // else (`:1978`) — a status line lives exactly one keypress.
        var overlay = PagerAgentsOverlay(
            agents: builtinEntries(),
            message: .info("New sessions will start with 'grok-build'")
        )
        _ = overlay.handle(character("j"))
        #expect(overlay.message == nil, "a nav key must clear the message")
        overlay.message = .error("Could not read or parse config.toml")
        _ = overlay.handle(KeyEvent(key: .tab))
        #expect(overlay.message == nil, "a tab switch must clear the message")
        overlay.message = .error("stale")
        _ = overlay.handle(character("/"))
        #expect(overlay.message == nil, "entering search must clear the message")
    }

    @Test("the stack maps view and mutation outcomes onto the row-selection channel by index")
    func stackViewPlumbing() {
        var stack = PagerOverlayStack([PagerOverlay.agents(PagerAgentsOverlay(
            agents: builtinEntries(),
            personas: samplePersonas()
        ))])
        #expect(stack.handle(KeyEvent(key: .enter))
            == .selected(id: "agents", rowID: "view:agent:0"))
        // The b2 mutation rows ride the same channel.
        #expect(stack.handle(character("t"))
            == .selected(id: "agents", rowID: "toggle:0"))
        #expect(stack.handle(character("s"))
            == .selected(id: "agents", rowID: "default:0"))
        // Switch to Personas and view the first persona.
        _ = stack.handle(KeyEvent(key: .tab))
        #expect(stack.handle(KeyEvent(key: .enter))
            == .selected(id: "agents", rowID: "view:persona:0"))
        // Esc closes through the stack (the modal owns Escape).
        #expect(stack.handle(KeyEvent(key: .escape)) == .dismissed(id: "agents"))
        #expect(stack.isEmpty)
    }
}

// MARK: - Paint

@Suite("agents modal paint")
struct PagerAgentsRenderTests {
    @Test("the Agents tab paints the built-ins in upstream's order under the Built-in header")
    func builtinOrderPaints() {
        let frame = painted(PagerAgentsOverlay(agents: builtinEntries()))
        // Section header (`:1339`).
        #expect(frame.contains("\u{2500}\u{2500} Built-in \u{2500}\u{2500}"))
        // The five user-visible built-ins (`:275-283`), in order.
        let names = ["grok-build", "general-purpose", "explore", "plan", "browser-use"]
        var searchRange = frame.startIndex..<frame.endIndex
        for name in names {
            let range = frame.range(of: "\u{25CF} \(name)", range: searchRange)
            #expect(range != nil, "\(name) missing or out of order")
            guard let range else { return }
            searchRange = range.upperBound..<frame.endIndex
        }
        // Descriptions paint under their rows (`:1287-1295`).
        #expect(frame.contains("Grok Build agent for software engineering tasks."))
    }

    @Test("scope tags, the default marker, and the toggle state paint on the agent row")
    func markersPaint() {
        var overlay = PagerAgentsOverlay(
            agents: builtinEntries(toggledOff: ["explore"]) + [projectEntry()],
            defaultAgentName: "grok-build"
        )
        let frame = painted(overlay)
        // Scope badges (`scope_badge`, `:995-1008`) and headers.
        #expect(frame.contains(" built-in "))
        #expect(frame.contains("\u{2500}\u{2500} Project \u{2500}\u{2500}"))
        #expect(frame.contains(" project "))
        // The default marker (`:1428-1443`).
        #expect(frame.contains("grok-build default"))
        // The toggle state: hollow dot + ` [off]` (`:1380-1396`,
        // `:1444-1456`).
        #expect(frame.contains("\u{25CB} explore"))
        #expect(frame.contains("explore [off]"))
        // Expansion shows the precomputed detail lines (`:1487-1491`).
        overlay.selectedAgent = 5
        _ = overlay.handle(character("e"))
        let expanded = painted(overlay)
        #expect(expanded.contains("Scope: project"))
        #expect(expanded.contains("\u{25BC} \u{25CF} reviewer"))
    }

    @Test("the Personas tab paints the blurbs, scope tags, inline descriptions, and expanded tags")
    func personasPaint() {
        var overlay = PagerAgentsOverlay(activeTab: .personas, personas: samplePersonas())
        let frame = painted(overlay)
        // The two blurb lines (`:1521-1526`), byte-exact.
        #expect(frame.contains(
            "Personas shape subagent behavior via the persona parameter on spawn_subagent."
        ))
        #expect(frame.contains(
            "Used by skills (e.g. /implement) and by the model when spawning subagents."
        ))
        // Collapsed row: name, scope tag, ` — description` (`:1637-1688`).
        // Two spaces before the dash: the badge is `" {scope} "`
        // (`:1661`) and the separator `" — "` (`:1673`).
        #expect(frame.contains("\u{25B6} socratic user  \u{2014} Asks questions before answering"))
        #expect(frame.contains("\u{25B6} auditor project  \u{2014} Reviews everything twice"))
        #expect(frame.contains("inline-one config"))
        // Expanded: wrapped description, capability tags, view hint
        // (`:1553-1584`).
        _ = overlay.handle(character("e"))
        let expanded = painted(overlay)
        #expect(expanded.contains("[accepts structured inputs \u{00B7} produces structured outputs]"))
        #expect(expanded.contains("Enter to view full definition"))
    }

    @Test("search narrows the painted list and the empty states carry upstream's copy")
    func searchAndEmptyStates() {
        var overlay = PagerAgentsOverlay(agents: builtinEntries())
        _ = overlay.handle(character("/"))
        for value in "browser" { _ = overlay.handle(character(value)) }
        let frame = painted(overlay)
        #expect(frame.contains("browser-use"))
        #expect(!frame.contains("\u{25CF} grok-build"))
        // `No matching agents` (`:1268-1275`).
        for value in "zzz" { _ = overlay.handle(character(value)) }
        #expect(painted(overlay).contains("No matching agents"))
        // `No agents found` / `No personas available` (`:1269-1273`,
        // `:1545-1549`).
        #expect(painted(PagerAgentsOverlay()).contains("No agents found"))
        #expect(painted(PagerAgentsOverlay(activeTab: .personas))
            .contains("No personas available"))
        var personas = PagerAgentsOverlay(activeTab: .personas, personas: samplePersonas())
        personas.searchQuery = "zzz"
        #expect(painted(personas).contains("No matching personas"))
    }

    @Test("the Agents footer advertises t toggle and s default in upstream's slot; Personas does not")
    func footerHonesty() {
        // The Agents tab carries upstream's `t toggle`/`s default`
        // (`build_agents_tab_shortcuts`, `:1080-1088`) between `/ search`
        // and `Tab switch tab`, live as of b2. The Personas tab's
        // mutation verbs (`n new`/`d delete`, `:1163-1172`) are B9-b3 and
        // stay absent, as does `t`/`s` there (upstream's personas footer
        // has no such rows). `i` stays un-advertised on both (upstream
        // only shows it under the vim hint, `push_vim_nav_search_hint`).
        let agentsHints = pagerAgentsHints(PagerAgentsOverlay(activeTab: .agents))
        #expect(agentsHints.map(\.key) == [
            "j/k", "e/\u{2192}", "E/\u{2190}", "Enter", "/", "t", "s", "Tab", "Esc",
        ])
        #expect(agentsHints.map(\.label) == [
            "nav", "expand", "collapse", "view", "search",
            "toggle", "default", "switch tab", "close",
        ])
        let personasHints = pagerAgentsHints(PagerAgentsOverlay(activeTab: .personas))
        let personasKeys = personasHints.map(\.key)
        let personasLabels = personasHints.map(\.label)
        #expect(personasKeys.contains("j/k"))
        #expect(personasLabels.contains("view"))
        for verb in ["toggle", "default", "new", "delete", "edit"] {
            #expect(!personasLabels.contains(verb), "Personas footer advertises \(verb)")
        }
        for key in ["t", "s", "n", "d", "i"] {
            #expect(!personasKeys.contains(key), "Personas footer advertises key \(key)")
        }
        // The painted frames agree with the hint lists.
        let agentsFrame = painted(PagerAgentsOverlay(agents: builtinEntries()))
        #expect(agentsFrame.contains("t toggle"))
        #expect(agentsFrame.contains("s default"))
        #expect(!agentsFrame.contains("n new"))
        #expect(!agentsFrame.contains("d delete"))
        let personasFrame = painted(PagerAgentsOverlay(
            activeTab: .personas, personas: samplePersonas()
        ))
        #expect(!personasFrame.contains("t toggle"))
        #expect(!personasFrame.contains("s default"))
        #expect(!personasFrame.contains("n new"))
        #expect(!personasFrame.contains("d delete"))
    }

    @Test("the inline message paints one line above the tab content on both tabs")
    func messagePaints() {
        // `render_modal_message_line` (`:1946-1959`) at the top of each
        // tab's content (`:1249-1251`, `:1519`), then a blank separator.
        let info = painted(PagerAgentsOverlay(
            agents: builtinEntries(),
            message: .info("New sessions will start with 'grok-build'")
        ))
        #expect(info.contains("New sessions will start with 'grok-build'"))
        let error = painted(PagerAgentsOverlay(
            agents: builtinEntries(),
            message: .error("Could not read or parse config.toml")
        ))
        #expect(error.contains("Could not read or parse config.toml"))
        // The Personas tab paints it too, above the blurbs (`:1519-1521`).
        let personas = painted(PagerAgentsOverlay(
            activeTab: .personas,
            personas: samplePersonas(),
            message: .error("Cannot delete bundled personas")
        ))
        #expect(personas.contains("Cannot delete bundled personas"))
        let messageRow = personas.split(separator: "\n").firstIndex {
            $0.contains("Cannot delete bundled personas")
        }
        let blurbRow = personas.split(separator: "\n").firstIndex {
            $0.contains("Personas shape subagent behavior")
        }
        if let messageRow, let blurbRow {
            #expect(messageRow < blurbRow, "the message paints above the blurbs")
        } else {
            Issue.record("message or blurb row missing from the painted frame")
        }
    }

    @Test("word wrap breaks at spaces and never hard-breaks a long word")
    func wordWrapContract() {
        // `word_wrap` (`agents_modal.rs:830-856`).
        #expect(agentsWordWrap("one two three", maxWidth: 7) == ["one two", "three"])
        #expect(agentsWordWrap("superlongword ok", maxWidth: 5) == ["superlongword", "ok"])
        #expect(agentsWordWrap("", maxWidth: 5) == [""])
    }
}
