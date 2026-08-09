// PagerAgentsOverlayTests.swift
//
// The agents/personas modal at the overlay seam (Wave 18 B9-b1/b2/b3): tab
// cycle (`agents_modal.rs:27-55` at upstream 650c1db7), selection clamping
// and filter recovery (`:907-981`), search filtering (`:892-905`,
// `:941-959`), the painted row shapes for BOTH tabs (`:1278-1494`,
// `:1496-1758`), the b2 mutation keys `t`/`s` on the Agents tab ONLY
// (`:2152-2196`) with the inline-message machinery (`:67-99`, `:1978`,
// `:1946-1959`), and the b3 persona create form (`:149-228`, `:2336-2391`,
// painted per `:1823-1896`) and delete confirm (`:2265-2282`, `:2393-2419`,
// painted per `:1898-1930`). Full frames are painted through
// `renderPagerFrame` so the assertions see what a user sees.

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
            scopeLabel: "user",
            deletable: true
        ),
        PagerAgentsPersonaEntry(
            name: "auditor",
            description: "Reviews everything twice",
            sourcePath: "/tmp/proj/.opengrok/personas/auditor.toml",
            scopeLabel: "project",
            deletable: true
        ),
        PagerAgentsPersonaEntry(
            name: "inline-one",
            description: nil,
            scopeLabel: "config"
        ),
    ]
}

/// A bundled persona: file-backed but failing the deletable guard.
private func bundledPersona() -> PagerAgentsPersonaEntry {
    PagerAgentsPersonaEntry(
        name: "shipping",
        description: "Ships with the CLI",
        sourcePath: "/tmp/home/bundled/personas/shipping.toml",
        scopeLabel: "bundled",
        deletable: false
    )
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

    @Test("Enter/o view: file-backed and body-backed agents produce view outcomes; every persona opens the detail")
    func enterViewOutcomes() {
        // `ViewAgent` (`:2124-2146`) and the personas `OpenPersonaDetail`
        // arm (`:2244-2260`).
        var overlay = PagerAgentsOverlay(
            agents: builtinEntries() + [projectEntry()],
            personas: samplePersonas()
        )
        #expect(overlay.handle(KeyEvent(key: .enter)) == .viewAgent(index: 0))
        overlay.selectedAgent = 5
        #expect(overlay.handle(character("o")) == .viewAgent(index: 5))
        // An AGENT with neither path nor content is silently inert
        // (upstream's `Unchanged` arm).
        var bare = PagerAgentsOverlay(agents: [
            PagerAgentsListEntry(name: "empty", description: "", scope: .builtIn)
        ])
        #expect(bare.handle(KeyEvent(key: .enter)) == .consumed)
        // Personas tab: EVERY entry opens the detail, path-backed or not —
        // upstream matches any `Some(persona)` (`:2245`); the path-less
        // route is `from_name_only` (`agent_view/modals.rs:58-59`).
        overlay.activeTab = .personas
        overlay.selectedPersona = 2
        #expect(overlay.handle(KeyEvent(key: .enter)) == .viewPersona(index: 2))
        overlay.selectedPersona = 0
        #expect(overlay.handle(character("o")) == .viewPersona(index: 0))
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

    @Test("n and d act only on the Personas tab; t and s still do nothing there")
    func personaKeysPerTab() {
        // On the AGENTS tab upstream's handler has no `n`/`d` arms
        // (`:2082-2199`), and on Personas no `t`/`s` (`:2202-2290`).
        var agents = PagerAgentsOverlay(agents: builtinEntries())
        for mutation in ["n", "d"] as [Character] {
            let before = agents
            #expect(agents.handle(character(mutation)) == .consumed)
            #expect(agents == before, "key \(mutation) changed Agents-tab state")
        }
        var personas = PagerAgentsOverlay(activeTab: .personas, personas: samplePersonas())
        for mutation in ["t", "s"] as [Character] {
            let before = personas
            #expect(personas.handle(character(mutation)) == .consumed)
            #expect(personas == before, "key \(mutation) changed Personas-tab state")
        }
        // `n` (`:2261-2264`) opens the form, fields empty, name focused,
        // scope user.
        #expect(personas.handle(character("n")) == .redraw)
        #expect(personas.personaCreateForm == PagerPersonaCreateForm())
        _ = personas.handle(KeyEvent(key: .escape))
        // `d` on a deletable persona (`:2265-2276`) arms the confirm with
        // the entry's name and path.
        #expect(personas.handle(character("d")) == .redraw)
        #expect(personas.personaDeleteConfirm == PagerPersonaDeleteConfirm(
            name: "socratic", path: "/tmp/home/personas/socratic.toml"
        ))
    }

    @Test("d refuses non-deletable personas with upstream's copy and never arms the confirm")
    func deleteGuardsAtTheKey() {
        // `:2267-2271`: the guard rejection paints
        // `Cannot delete bundled personas` — upstream's one copy for ANY
        // entry `persona_is_deletable` refuses, bundled or path-less.
        var overlay = PagerAgentsOverlay(
            activeTab: .personas,
            personas: [bundledPersona(), samplePersonas()[2]]
        )
        #expect(overlay.handle(character("d")) == .redraw)
        #expect(overlay.message == .error("Cannot delete bundled personas"))
        #expect(overlay.personaDeleteConfirm == nil)
        // The inline config persona (no path, not deletable): same arm.
        overlay.selectedPersona = 1
        #expect(overlay.handle(character("d")) == .redraw)
        #expect(overlay.message == .error("Cannot delete bundled personas"))
        #expect(overlay.personaDeleteConfirm == nil)
        // An empty list falls through to Changed (`:2266` if-let, `:2281`).
        var empty = PagerAgentsOverlay(activeTab: .personas)
        #expect(empty.handle(character("d")) == .redraw)
        #expect(empty.message == nil)
    }

    @Test("the create form cycles fields, toggles scope, and cancels on Esc")
    func createFormMachine() {
        // `handle_persona_create_form_key` (`:2336-2391`) with the field
        // cycle (`:1767-1781`) and the scope toggle (`:2298-2314`).
        var overlay = PagerAgentsOverlay(activeTab: .personas, personas: samplePersonas())
        _ = overlay.handle(character("n"))
        // Tab cycles name → description → instructions → scope → name.
        for expected in [PagerPersonaCreateField.description, .instructions, .scope, .name] {
            _ = overlay.handle(KeyEvent(key: .tab))
            #expect(overlay.personaCreateForm?.activeField == expected)
        }
        // Shift-Tab goes backwards (name → scope).
        _ = overlay.handle(KeyEvent(key: .backTab))
        #expect(overlay.personaCreateForm?.activeField == .scope)
        // Space/←/→ toggle scope only on the scope row.
        _ = overlay.handle(character(" "))
        #expect(overlay.personaCreateForm?.scope == .project)
        _ = overlay.handle(KeyEvent(key: .left))
        #expect(overlay.personaCreateForm?.scope == .user)
        _ = overlay.handle(KeyEvent(key: .right))
        #expect(overlay.personaCreateForm?.scope == .project)
        // Up/Down navigate fields (`:2315-2324`).
        _ = overlay.handle(KeyEvent(key: .down))
        #expect(overlay.personaCreateForm?.activeField == .name)
        _ = overlay.handle(KeyEvent(key: .up))
        #expect(overlay.personaCreateForm?.activeField == .scope)
        // Typed characters land in the ACTIVE text field; the scope row
        // has no editor (upstream's `active_editor_mut` → None).
        _ = overlay.handle(character("x"))
        #expect(overlay.personaCreateForm?.name.isEmpty == true)
        _ = overlay.handle(KeyEvent(key: .down)) // scope → name
        for value in "review pal" { _ = overlay.handle(character(value)) }
        #expect(overlay.personaCreateForm?.name == "review pal")
        _ = overlay.handle(KeyEvent(key: .backspace))
        #expect(overlay.personaCreateForm?.name == "review pa")
        // Space on a TEXT field types a space, never toggles scope.
        #expect(overlay.personaCreateForm?.scope == .project)
        // Tab is field-cycling while the form is open — never a tab
        // switch (`:1979-1981` route before the chrome).
        _ = overlay.handle(KeyEvent(key: .tab))
        #expect(overlay.activeTab == .personas)
        #expect(overlay.personaCreateForm != nil)
        // Esc cancels the form, not the modal (`:2344-2347`).
        #expect(overlay.handle(KeyEvent(key: .escape)) == .redraw)
        #expect(overlay.personaCreateForm == nil)
    }

    @Test("Enter in the form requires a name locally and emits the create outcome otherwise")
    func createFormEnter() {
        // `:2363-2371`: the empty-name refusal never leaves the overlay;
        // a named form emits `.createPersona` for the composition.
        var overlay = PagerAgentsOverlay(activeTab: .personas, personas: samplePersonas())
        _ = overlay.handle(character("n"))
        #expect(overlay.handle(KeyEvent(key: .enter)) == .redraw)
        #expect(overlay.message == .error("Name is required"))
        #expect(overlay.personaCreateForm != nil, "a refused create keeps the form open")
        // Whitespace-only is still empty after upstream's trim (`:2364`).
        for value in "   " { _ = overlay.handle(character(value)) }
        #expect(overlay.handle(KeyEvent(key: .enter)) == .redraw)
        #expect(overlay.message == .error("Name is required"))
        for value in "pal" { _ = overlay.handle(character(value)) }
        #expect(overlay.handle(KeyEvent(key: .enter)) == .createPersona)
        // The form stays on the overlay for the composition to read; only
        // a successful write clears it (`:2373-2380`).
        #expect(overlay.personaCreateForm?.name == "   pal")
    }

    @Test("the delete confirm resolves y, cancels n/N/Esc, and swallows everything else")
    func deleteConfirmMachine() {
        // `handle_persona_confirm_key` (`:2393-2419`).
        var overlay = PagerAgentsOverlay(activeTab: .personas, personas: samplePersonas())
        _ = overlay.handle(character("d"))
        #expect(overlay.personaDeleteConfirm != nil)
        // `q` and navigation do NOT close or move anything — upstream's
        // fall-through to Unchanged.
        #expect(overlay.handle(character("q")) == .consumed)
        #expect(overlay.handle(character("j")) == .consumed)
        #expect(overlay.selectedPersona == 0)
        // n cancels (`:2413-2416`).
        #expect(overlay.handle(character("n")) == .redraw)
        #expect(overlay.personaDeleteConfirm == nil)
        #expect(overlay.personaCreateForm == nil, "n in a confirm cancels, never opens the form")
        // Esc cancels too.
        _ = overlay.handle(character("d"))
        #expect(overlay.handle(KeyEvent(key: .escape)) == .redraw)
        #expect(overlay.personaDeleteConfirm == nil)
        // y (and Y) emit the delete for the composition; the confirm
        // stays on the overlay for it to read (upstream `take()`s it in
        // the same breath as the delete — here that IS the composition's
        // resolution step).
        _ = overlay.handle(character("d"))
        #expect(overlay.handle(character("y")) == .deletePersona)
        _ = overlay.handle(character("d"))
        #expect(overlay.handle(character("Y", modifiers: [.shift])) == .deletePersona)
    }

    @Test("switching to the Agents tab clears the form and confirm")
    func tabSwitchClearsPersonaOverlays() {
        // `clear_overlays_for_tab` (`:1960-1968`): the create/confirm
        // state belongs to the Personas tab and clears when the
        // destination is Agents. (With a form open Tab cycles fields, so
        // the switch path here is the programmatic one mouse tabs would
        // take.)
        var overlay = PagerAgentsOverlay(activeTab: .personas, personas: samplePersonas())
        _ = overlay.handle(character("d"))
        #expect(overlay.personaDeleteConfirm != nil)
        overlay.switchTab(.agents)
        #expect(overlay.personaDeleteConfirm == nil)
        overlay.switchTab(.personas)
        _ = overlay.handle(character("n"))
        overlay.switchTab(.agents)
        #expect(overlay.personaCreateForm == nil)
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
        // The b3 persona mutations ride the same channel: `d` arms the
        // confirm (state change only), `y` emits the delete row; `n`
        // opens the form, Enter with a name emits the create row.
        #expect(stack.handle(character("d")) == .redraw)
        #expect(stack.handle(character("y"))
            == .selected(id: "agents", rowID: "persona:delete"))
        _ = stack.handle(KeyEvent(key: .escape)) // cancel the (still-armed) confirm
        #expect(stack.handle(character("n")) == .redraw)
        for value in "pal" { _ = stack.handle(character(value)) }
        #expect(stack.handle(KeyEvent(key: .enter))
            == .selected(id: "agents", rowID: "persona:create"))
        _ = stack.handle(KeyEvent(key: .escape)) // cancel the form
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

    @Test("the Agents footer advertises t toggle and s default; Personas advertises n new and d delete")
    func footerHonesty() {
        // The Agents tab carries upstream's `t toggle`/`s default`
        // (`build_agents_tab_shortcuts`, `:1080-1088`) between `/ search`
        // and `Tab switch tab`, and no `n`/`d` (upstream's agents footer
        // has none). The Personas tab carries `n new`/`d delete`
        // (`:1163-1172`) in upstream's slot, and no `t`/`s`. `i` stays
        // un-advertised on both (upstream only shows it under the vim
        // hint, `push_vim_nav_search_hint`).
        let agentsHints = pagerAgentsHints(PagerAgentsOverlay(activeTab: .agents))
        #expect(agentsHints.map(\.key) == [
            "j/k", "e/\u{2192}", "E/\u{2190}", "Enter", "/", "t", "s", "Tab", "Esc",
        ])
        #expect(agentsHints.map(\.label) == [
            "nav", "expand", "collapse", "view", "search",
            "toggle", "default", "switch tab", "close",
        ])
        let personasHints = pagerAgentsHints(PagerAgentsOverlay(activeTab: .personas))
        #expect(personasHints.map(\.key) == [
            "j/k", "e/\u{2192}", "E/\u{2190}", "Enter", "/", "n", "d", "Tab", "Esc",
        ])
        #expect(personasHints.map(\.label) == [
            "nav", "expand", "collapse", "view", "search",
            "new", "delete", "switch tab", "close",
        ])
        #expect(!personasHints.map(\.key).contains("i"))
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
        #expect(personasFrame.contains("n new"))
        #expect(personasFrame.contains("d delete"))
    }

    @Test("the form and confirm footers replace the browse set while either is up")
    func modeFooters() {
        // `build_personas_tab_shortcuts` branches (`:1105-1135`).
        var overlay = PagerAgentsOverlay(activeTab: .personas, personas: samplePersonas())
        _ = overlay.handle(character("n"))
        #expect(pagerAgentsHints(overlay).map(\.label) == ["switch field", "create", "cancel"])
        _ = overlay.handle(KeyEvent(key: .escape))
        _ = overlay.handle(character("d"))
        let confirmHints = pagerAgentsHints(overlay)
        #expect(confirmHints.map(\.key) == ["y", "n/Esc"])
        #expect(confirmHints.map(\.label) == ["confirm", "cancel"])
    }

    @Test("the create form paints title, fields, scope, hint, and the inline error inside it")
    func createFormPaints() {
        // `render_persona_create_form` (`:1823-1896`), copy byte-parity.
        var overlay = PagerAgentsOverlay(activeTab: .personas, personas: samplePersonas())
        _ = overlay.handle(character("n"))
        for value in "review pal" { _ = overlay.handle(character(value)) }
        var frame = painted(overlay)
        #expect(frame.contains("Create New Persona"))
        #expect(frame.contains("Name: review pal"))
        #expect(frame.contains("Description: "))
        #expect(frame.contains("Instructions: "))
        #expect(frame.contains("Scope: [user]"))
        #expect(frame.contains(
            "Tab/\u{2191}\u{2193}: field | Space/\u{2190}\u{2192} on scope: "
                + "user/project | Enter: create | Esc: cancel"
        ))
        // The list is replaced, not layered under (`:1502-1511` early
        // return).
        #expect(!frame.contains("\u{25B6} socratic"))
        // The scope toggle repaints `[project]`.
        for _ in 0..<3 { _ = overlay.handle(KeyEvent(key: .tab)) } // → scope
        _ = overlay.handle(character(" "))
        #expect(painted(overlay).contains("Scope: [project]"))
        // A validation error paints INSIDE the form (`:1839-1846`),
        // error-styled, form still up. Enter commits from any field.
        overlay.personaCreateForm?.name = ""
        _ = overlay.handle(KeyEvent(key: .enter))
        frame = painted(overlay)
        #expect(frame.contains("Name is required"))
        #expect(frame.contains("Create New Persona"))
    }

    @Test("the delete confirm paints title, question, path, and hint")
    func confirmPaints() {
        // `render_persona_confirm_dialog` (`:1898-1930`), copy byte-parity.
        var overlay = PagerAgentsOverlay(activeTab: .personas, personas: samplePersonas())
        _ = overlay.handle(character("d"))
        let frame = painted(overlay)
        #expect(frame.contains("Delete Persona"))
        #expect(frame.contains("Delete persona 'socratic'?"))
        #expect(frame.contains("  /tmp/home/personas/socratic.toml"))
        #expect(frame.contains("y: confirm | n/Esc: cancel"))
        #expect(!frame.contains("\u{25B6} auditor"), "the confirm replaces the list")
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
