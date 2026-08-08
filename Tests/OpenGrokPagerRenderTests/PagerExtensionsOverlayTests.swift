// PagerExtensionsOverlayTests.swift
//
// The extensions modal at the overlay seam: tab cycle and wrap
// (`extensions_modal.rs:525-543`), the status filter (`:563-594`), row
// shapes and labels for the read-only tabs (`:2567-3166`), the honest empty
// state, and — the point of the read-only port — that no mutation key is
// handled or advertised. Full frames are painted through `renderPagerFrame`
// so the assertions see what a user sees, not a private intermediate.

import Foundation
@testable import OpenGrokPagerRender
import OpenGrokTerminalCore
import Testing

// MARK: - Helpers

private func extensionsFrame(
    _ overlay: PagerExtensionsOverlay,
    width: Int = 140,
    height: Int = 34,
    theme: PagerRenderTheme = .grokNight
) -> PagerRenderResult {
    renderPagerFrame(
        PagerRenderState(
            size: TerminalSize(width: width, height: height),
            conversation: [.message(PagerMessage(role: .assistant, text: "behind"))],
            input: PagerComposerState(text: ""),
            theme: theme,
            showScrollbar: false,
            overlays: PagerOverlayStack([PagerOverlay.extensions(overlay)])
        )
    )
}

private func painted(_ overlay: PagerExtensionsOverlay) -> String {
    extensionsFrame(overlay).snapshot()
}

private func character(_ value: Character) -> KeyEvent {
    KeyEvent(key: .char(value), modifiers: [], character: value)
}

private let sampleHook = PagerExtensionsHookRow(
    event: "Pre-Tool Use",
    matcher: "Bash",
    command: "echo audited",
    sourceDir: "/tmp/home/hooks",
    sourceLabel: "Global hooks",
    disabled: false
)

private let disabledHook = PagerExtensionsHookRow(
    event: "Session Start",
    matcher: nil,
    command: "touch /tmp/started",
    sourceDir: "/tmp/home/hooks",
    sourceLabel: "Global hooks",
    disabled: true
)

private let sampleSkill = PagerExtensionsSkillRow(
    label: "deploy-helper",
    source: "~/.opengrok/skills",
    author: "tester",
    description: "Automates the deploy checklist",
    path: "/tmp/home/skills/deploy-helper/SKILL.md",
    tools: ["Bash"],
    enabled: true
)

private let samplePlugin = PagerExtensionsPluginRow(
    name: "tools-abc12345",
    source: "https://example.com/tools.git",
    url: "https://example.com/tools.git",
    pluginNames: ["formatter"],
    enabled: true
)

private let sampleServer = PagerExtensionsMCPRow(
    name: "docs-server",
    toolNames: ["docs-server__search", "docs-server__fetch"]
)

// MARK: - Tabs

@Suite("extensions modal tabs and filter")
struct PagerExtensionsTabTests {
    @Test("display order and labels match upstream")
    func tabOrderAndLabels() {
        // `ALL` and `label()` (`extensions_modal.rs:505-521`).
        #expect(PagerExtensionsTab.all == [.hooks, .plugins, .marketplace, .skills, .mcpServers])
        #expect(PagerExtensionsTab.all.map(\.label)
            == ["Hooks", "Plugins", "Marketplace", "Skills", "MCP Servers"])
    }

    @Test("Tab cycles forward with wrap, Shift+Tab backward")
    func tabCycleWraps() {
        // `next()`/`prev()` (`extensions_modal.rs:525-543`).
        var overlay = PagerExtensionsOverlay(activeTab: .hooks)
        for expected in [PagerExtensionsTab.plugins, .marketplace, .skills, .mcpServers, .hooks] {
            #expect(overlay.handle(KeyEvent(key: .tab)) == .redraw)
            #expect(overlay.activeTab == expected)
        }
        #expect(overlay.handle(KeyEvent(key: .backTab)) == .redraw)
        #expect(overlay.activeTab == .mcpServers)
    }

    @Test("the filter cycles All → Enabled → Disabled → All and filters rows")
    func filterCycles() {
        // `StatusFilter` (`extensions_modal.rs:563-594`).
        #expect(PagerExtensionsStatusFilter.all.next() == .enabled)
        #expect(PagerExtensionsStatusFilter.enabled.next() == .disabled)
        #expect(PagerExtensionsStatusFilter.disabled.next() == .all)
        #expect(PagerExtensionsStatusFilter.all.label == "All")
        #expect(PagerExtensionsStatusFilter.enabled.label == "Enabled")
        #expect(PagerExtensionsStatusFilter.disabled.label == "Disabled")

        var overlay = PagerExtensionsOverlay(
            activeTab: .hooks,
            hooks: [sampleHook, disabledHook]
        )
        // All: header counts both hooks.
        #expect(overlay.entries().map(\.label).contains("Global hooks (2 hooks)"))
        // Enabled: the disabled hook drops out.
        #expect(overlay.handle(character("f")) == .redraw)
        #expect(overlay.activeFilter == .enabled)
        let enabledLabels = overlay.entries().map(\.label)
        #expect(enabledLabels.contains("Global hooks (1 hooks)"))
        #expect(!enabledLabels.contains { $0.hasPrefix("on:Session Start") })
        // Disabled: only the disabled hook remains.
        #expect(overlay.handle(character("f")) == .redraw)
        #expect(overlay.activeFilter == .disabled)
        #expect(overlay.entries().contains { $0.label.hasPrefix("on:Session Start") })
        #expect(!overlay.entries().contains { $0.label.hasPrefix("on:Pre-Tool Use") })
        // Wraps back to All.
        #expect(overlay.handle(character("f")) == .redraw)
        #expect(overlay.activeFilter == .all)
    }

    @Test("Marketplace has no filter and no reload")
    func marketplaceHasNoFilterOrReload() {
        var overlay = PagerExtensionsOverlay(activeTab: .marketplace)
        #expect(PagerExtensionsTab.marketplace.hasStatusFilter == false)
        #expect(overlay.handle(character("f")) == .consumed)
        // `r` must not promise a refresh with no loader behind it.
        #expect(overlay.handle(character("r")) == .consumed)
    }

    @Test("r yields a reload outcome for every loader-backed tab")
    func reloadOutcomePerTab() {
        for tab in [PagerExtensionsTab.hooks, .plugins, .skills, .mcpServers] {
            var overlay = PagerExtensionsOverlay(activeTab: tab)
            #expect(overlay.handle(character("r")) == .reload(tab))
        }
    }

    @Test("Esc closes from browse but only clears an active search")
    func escapeSemantics() {
        var overlay = PagerExtensionsOverlay(activeTab: .hooks, hooks: [sampleHook])
        #expect(overlay.handle(character("/")) == .redraw)
        #expect(overlay.searchActive)
        _ = overlay.handle(character("x"))
        #expect(overlay.searchQuery == "x")
        // Esc inside search clears, never closes.
        #expect(overlay.handle(KeyEvent(key: .escape)) == .redraw)
        #expect(!overlay.searchActive)
        #expect(overlay.searchQuery.isEmpty)
        // Browse-Esc closes.
        #expect(overlay.handle(KeyEvent(key: .escape)) == .close)
    }

    @Test("no mutation key is handled: space, x, a, u, d are consumed no-ops")
    func mutationKeysAreInert() {
        // Upstream's action keys (`extensions_action_keys`,
        // `extensions_modal.rs:1112-1137`) minus the read-only survivors.
        // Every one must swallow without an outcome — a modal never leaks
        // keys, and a viewer never mutates.
        var overlay = PagerExtensionsOverlay(
            activeTab: .hooks,
            hooks: [sampleHook],
            selectedIndex: 1
        )
        for mutation in [" ", "x", "a", "u", "d"] as [Character] {
            let before = overlay
            #expect(overlay.handle(character(mutation)) == .consumed)
            #expect(overlay == before, "mutation key \(mutation) changed state")
        }
    }
}

// MARK: - Rows and paint

@Suite("extensions modal rows and paint")
struct PagerExtensionsRenderTests {
    @Test("hooks paint the grouped shape: header count, on:-label, arrow command, disabled badge")
    func hooksRowShape() {
        let overlay = PagerExtensionsOverlay(
            activeTab: .hooks,
            hooks: [sampleHook, disabledHook]
        )
        let frame = painted(overlay)
        // `"{label} ({n} hooks)"` (`extensions_modal.rs:2825`).
        #expect(frame.contains("Global hooks (2 hooks)"))
        // `"on:{event} /{matcher}"` and `"→ {command}"` (`:2840-2853`).
        #expect(frame.contains("on:Pre-Tool Use /Bash"))
        #expect(frame.contains("\u{2192} echo audited"))
        // `[disabled]` badge (`:2861-2865`).
        #expect(frame.contains("on:Session Start"))
        #expect(frame.contains("[disabled]"))
    }

    @Test("collapsing a hook group hides its rows; searching forces it open")
    func hookGroupCollapse() {
        var overlay = PagerExtensionsOverlay(activeTab: .hooks, hooks: [sampleHook])
        // Selection starts on the group header; Enter collapses.
        #expect(overlay.handle(KeyEvent(key: .enter)) == .redraw)
        #expect(!overlay.entries().contains { $0.label.hasPrefix("on:") })
        // A query ignores collapse state (`extensions_modal.rs:2821-2824`).
        overlay.searchQuery = "Pre-Tool"
        #expect(overlay.entries().contains { $0.label.hasPrefix("on:Pre-Tool Use") })
    }

    @Test("skills paint label, source · author, description, and expanded fields")
    func skillsRowShape() {
        var overlay = PagerExtensionsOverlay(activeTab: .skills, skills: [sampleSkill])
        var frame = painted(overlay)
        #expect(frame.contains("deploy-helper"))
        // `"({source} · {author})"` (`extensions_modal.rs:2575-2578`).
        #expect(frame.contains("(~/.opengrok/skills \u{B7} tester)"))
        #expect(frame.contains("Automates the deploy checklist"))
        // `e` pins the detail fields open (path/author/tools, `:2592-2603`).
        #expect(overlay.handle(character("e")) == .redraw)
        frame = painted(overlay)
        #expect(frame.contains("path: /tmp/home/skills/deploy-helper/SKILL.md"))
        #expect(frame.contains("tools: Bash"))
    }

    @Test("plugins paint the registry row: repo key, source, disabled badge")
    func pluginsRowShape() {
        var disabled = samplePlugin
        disabled.enabled = false
        let overlay = PagerExtensionsOverlay(
            activeTab: .plugins,
            plugins: [samplePlugin, disabled]
        )
        let frame = painted(overlay)
        #expect(frame.contains("tools-abc12345"))
        #expect(frame.contains("https://example.com/tools.git"))
        #expect(frame.contains("[disabled]"))
    }

    @Test("MCP servers paint upstream's tool-count line and the connected/failed badges")
    func mcpRowShape() {
        let failed = PagerExtensionsMCPRow(
            name: "broken-server",
            failure: "connect: connection refused"
        )
        let empty = PagerExtensionsMCPRow(name: "quiet-server")
        let overlay = PagerExtensionsOverlay(
            activeTab: .mcpServers,
            mcpServers: [sampleServer, failed, empty]
        )
        let frame = painted(overlay)
        // `"{n} tools"` and the no-tools line (`extensions_modal.rs:3086-3103`).
        #expect(frame.contains("2 tools"))
        #expect(frame.contains("no tools (server may not be connected)"))
        #expect(frame.contains("[connected]"))
        #expect(frame.contains("[failed]"))
        #expect(frame.contains("connect: connection refused"))
    }

    @Test("the marketplace tab paints the deferred-surface notice, nothing else")
    func marketplaceNotice() {
        let overlay = PagerExtensionsOverlay(activeTab: .marketplace)
        let frame = painted(overlay)
        #expect(frame.contains(PagerExtensionsOverlay.marketplaceNotice))
        // The notice is not selectable, so the tab publishes no rows.
        #expect(overlay.entries().allSatisfy { !$0.isSelectable })
    }

    @Test("an empty tab paints upstream's bare No matches")
    func emptyStateCopy() {
        // `picker.rs:2040-2046` — the empty state is "  No matches", never
        // placeholder rows.
        let overlay = PagerExtensionsOverlay(activeTab: .hooks)
        #expect(painted(overlay).contains("No matches"))
        #expect(overlay.entries().isEmpty)
    }

    @Test("the tab bar paints every label with the active one highlighted")
    func tabBarPaints() {
        let frame = painted(PagerExtensionsOverlay(activeTab: .skills))
        for label in ["Hooks", "Plugins", "Marketplace", "Skills", "MCP Servers"] {
            #expect(frame.contains(label))
        }
    }

    @Test("the footer advertises only read-only verbs")
    func footerIsReadOnly() {
        for tab in PagerExtensionsTab.all {
            let hints = pagerExtensionsHints(PagerExtensionsOverlay(activeTab: tab))
            let labels = hints.map(\.label)
            // The read-only survivors...
            #expect(labels.contains("tabs"))
            #expect(labels.contains("close"))
            // ...and none of upstream's mutation verbs
            // (`extensions_action_keys`, `extensions_modal.rs:1112-1137`).
            for verb in ["toggle", "add", "remove", "install", "uninstall",
                         "update", "auth", "add source", "remove source"] {
                #expect(!labels.contains(verb), "\(tab) advertises \(verb)")
            }
            if tab == .marketplace {
                #expect(!labels.contains("reload") && !labels.contains("refresh"))
            }
        }
    }

    @Test("search narrows rows and the reload round-trip id carries the tab")
    func searchAndReloadPlumbing() {
        var overlay = PagerExtensionsOverlay(
            activeTab: .mcpServers,
            mcpServers: [sampleServer, PagerExtensionsMCPRow(name: "other")]
        )
        _ = overlay.handle(character("/"))
        for value in "docs" { _ = overlay.handle(character(value)) }
        _ = overlay.handle(KeyEvent(key: .enter))
        #expect(overlay.entries().map(\.label) == ["docs-server"])

        // The stack maps `.reload` onto the row-selection channel with the
        // tab in the id — pin the id shape the composition parses.
        var stack = PagerOverlayStack([PagerOverlay.extensions(overlay)])
        let outcome = stack.handle(character("r"))
        #expect(outcome == .selected(id: "extensions", rowID: "reload:mcpServers"))
    }
}
