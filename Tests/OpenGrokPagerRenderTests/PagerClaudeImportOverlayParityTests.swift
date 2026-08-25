import OpenGrokTerminalCore
import Testing

@testable import OpenGrokPagerRender

@Suite("Claude import modal rendering and selection")
struct PagerClaudeImportOverlayParityTests {
    @Test("scopes and categories follow the pinned upstream grouping order")
    func groupsScopesAndCategories() {
        let overlay = PagerClaudeImportOverlay(items: sampleItems())
        #expect(overlay.selectedCount == 4)
        #expect(overlay.totalCount == 5)
        #expect(overlay.title == "Import Claude settings (4/5)")
        #expect(overlay.rows.map(\.id) == [
            "scope:global",
            "category:global:permission",
            "item:global-permission",
            "category:global:environment",
            "item:global-env",
            "category:global:mcpServer",
            "item:global-blocked",
            "scope:project",
            "category:project:mcpServer",
            "item:project-mcp",
            "category:project:hook",
            "item:project-hook",
        ])
        #expect(overlay.rows.first?.label == "[x] Global")
        let blocked = overlay.rows.first { $0.id == "item:global-blocked" }
        #expect(blocked?.label.contains("[!]") == true)
        #expect(blocked?.isSelectable == false)
        #expect(blocked?.detail == "blocked by administrator")
    }

    @Test("scope and category bulk toggles preserve stable per-item identities")
    func groupTogglesUseStableItemIDs() {
        var overlay = PagerClaudeImportOverlay(items: sampleItems())
        let permissionToggled = overlay.toggle(rowID: "category:global:permission")
        #expect(permissionToggled)
        #expect(!overlay.selectedIDs.contains("global-permission"))
        #expect(overlay.selectedIDs.contains("global-env"))
        #expect(overlay.rows.first?.label == "[-] Global")

        let globalToggled = overlay.toggle(rowID: "scope:global")
        #expect(globalToggled)
        #expect(overlay.selectedIDs.contains("global-permission"))
        #expect(overlay.selectedIDs.contains("global-env"))
        #expect(!overlay.selectedIDs.contains("global-blocked"))

        let projectToggled = overlay.toggle(rowID: "scope:project")
        #expect(projectToggled)
        #expect(!overlay.selectedIDs.contains("project-mcp"))
        #expect(!overlay.selectedIDs.contains("project-hook"))
        #expect(overlay.selectedIDs.contains("global-permission"))
    }

    @Test("select-all and select-none never enable managed-policy-blocked rows")
    func selectAllRespectsDisabledRows() {
        var overlay = PagerClaudeImportOverlay(items: sampleItems())
        overlay.selectNone()
        #expect(overlay.selectedIDs.isEmpty)
        #expect(overlay.rows.first?.label == "[ ] Global")

        overlay.selectAll()
        #expect(overlay.selectedCount == 4)
        #expect(!overlay.selectedIDs.contains("global-blocked"))
        let blockedToggled = overlay.toggle(rowID: "item:global-blocked")
        #expect(!blockedToggled)
        #expect(!overlay.selectedIDs.contains("global-blocked"))
    }

    @Test("production list painter renders the actual modal, checkbox rows, and confirmation hints")
    func productionPainterRendersModal() {
        let model = PagerClaudeImportOverlay(items: sampleItems())
        let overlay = model.makeOverlay()
        #expect(overlay.id == PagerClaudeImportOverlay.overlayID)
        #expect(overlay.capturesInput)
        #expect(overlay.hints.map(\.key) == ["↑/↓", "Space", "a", "n", "Enter", "Esc"])

        let frame = renderPagerFrame(PagerRenderState(
            size: TerminalSize(width: 120, height: 36),
            conversation: [.message(PagerMessage(role: .assistant, text: "behind modal"))],
            input: PagerComposerState(text: "draft"),
            shortcuts: PagerShortcutsBar(hints: []),
            showScrollbar: false,
            overlays: PagerOverlayStack([overlay])
        ))
        let snapshot = frame.snapshot()
        #expect(snapshot.contains("Import Claude settings (4/5)"))
        #expect(snapshot.contains("Permissions"))
        #expect(snapshot.contains("MCP servers"))
        #expect(snapshot.contains("API_KEY = <redacted, 12 chars>"))
        #expect(!snapshot.contains("actual-secret"))
        #expect(frame.overlays.first?.id == PagerClaudeImportOverlay.overlayID)
    }

    @Test("the existing production overlay stack navigates rows and cancels without selection")
    func realOverlayStackRoutesNavigationAndEscape() {
        var stack = PagerOverlayStack([
            PagerClaudeImportOverlay(items: sampleItems()).makeOverlay(),
        ])
        #expect(stack.isActive)
        let moved = stack.handle(KeyEvent(key: .down), viewportHeight: 8)
        #expect(moved == .redraw)
        let dismissed = stack.handle(KeyEvent(key: .escape), viewportHeight: 8)
        #expect(dismissed == .dismissed(id: PagerClaudeImportOverlay.overlayID))
        #expect(!stack.isActive)
    }

    private func sampleItems() -> [PagerClaudeImportItem] {
        [
            PagerClaudeImportItem(
                id: "project-mcp",
                scope: .project,
                category: .mcpServer,
                label: "project-server"
            ),
            PagerClaudeImportItem(
                id: "global-env",
                scope: .global,
                category: .environment,
                label: "API_KEY = <redacted, 12 chars>"
            ),
            PagerClaudeImportItem(
                id: "global-blocked",
                scope: .global,
                category: .mcpServer,
                label: "denied-server",
                isEnabled: false,
                blockedReason: "blocked by administrator"
            ),
            PagerClaudeImportItem(
                id: "project-hook",
                scope: .project,
                category: .hook,
                label: "PreToolUse [Bash] echo safe"
            ),
            PagerClaudeImportItem(
                id: "global-permission",
                scope: .global,
                category: .permission,
                label: "allow Bash(git status)"
            ),
        ]
    }
}
