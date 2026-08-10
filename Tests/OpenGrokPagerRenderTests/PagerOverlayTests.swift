import Testing
@testable import OpenGrokPagerRender
import OpenGrokTerminalCore

private func frame(
    _ overlays: PagerOverlayStack,
    width: Int = 60,
    height: Int = 24
) -> PagerRenderResult {
    renderPagerFrame(
        PagerRenderState(
            size: TerminalSize(width: width, height: height),
            conversation: [.message(PagerMessage(role: .assistant, text: "behind"))],
            input: PagerComposerState(text: "draft"),
            shortcuts: PagerShortcutsBar(hints: [PagerShortcutHint(key: "Enter", label: "send")]),
            showScrollbar: false,
            overlays: overlays
        )
    )
}

private func rows(_ result: PagerRenderResult) -> [String] {
    result.snapshot().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
}

private func key(_ code: KeyCode, _ modifiers: KeyModifiers = []) -> KeyEvent {
    KeyEvent(key: code, modifiers: modifiers)
}

private func character(_ value: Character) -> KeyEvent {
    KeyEvent(key: .char(value), character: value)
}

private let modelRows = [
    PagerListRow(id: "grok-4", label: "grok-4", detail: "xai"),
    PagerListRow(id: "grok-4-fast", label: "grok-4-fast", detail: "xai"),
    PagerListRow(id: "sonnet", label: "claude-sonnet-4", detail: "anthropic")
]

// MARK: - Modal chrome

@Suite("Pager overlay chrome")
struct PagerOverlayChromeTests {
    @Test("a list modal draws a square border, an inlined bold title, and a close button")
    func listModalChrome() {
        let overlay = PagerOverlay.list(id: "model", title: "Select model", rows: modelRows)
        let result = frame(PagerOverlayStack([overlay]))
        let painted = rows(result)

        guard let bounds = result.overlays.first else {
            Issue.record("expected overlay bounds")
            return
        }
        let top = painted[bounds.frame.y]
        #expect(top.contains("┌"))
        #expect(top.contains("─ Select model ─"))
        #expect(top.contains("[✗]"))
        #expect(painted[bounds.frame.bottom - 1].contains("└"))
        #expect(painted[bounds.frame.bottom - 1].contains("┘"))
    }

    @Test("the search row, divider and ❯ cursor land in the modal body")
    func listModalBody() {
        let overlay = PagerOverlay.list(id: "model", title: "Select model", rows: modelRows)
        let result = frame(PagerOverlayStack([overlay]))
        let painted = rows(result)
        guard let bounds = result.overlays.first else {
            Issue.record("expected overlay bounds")
            return
        }

        #expect(painted[bounds.content.y].contains("search:"))
        #expect(painted[bounds.content.y].contains("/ to search"))
        #expect(painted[bounds.content.y + 1].contains("──"))
        #expect(painted[bounds.content.y + 2].contains("❯ grok-4"))
        #expect(painted[bounds.content.y + 3].contains("  grok-4-fast"))
        // The right-aligned meta column.
        #expect(painted[bounds.content.y + 2].hasSuffix("xai │") == false)
        #expect(painted[bounds.content.y + 2].contains("xai"))
    }

    @Test("footer hints join with the modal separator and stay centered")
    func footerSeparator() {
        let overlay = PagerOverlay.list(id: "model", title: "Models", rows: modelRows)
        let result = frame(PagerOverlayStack([overlay]))
        let painted = rows(result)
        guard let bounds = result.overlays.first else {
            Issue.record("expected overlay bounds")
            return
        }
        let footer = painted[bounds.footer.bottom - 1]
        // `"  |  "` (ASCII pipe), not the shortcuts bar's `"  │  "`. The only
        // `│` on this row is the modal's own side border, so the hint run
        // itself must be free of it.
        #expect(footer.contains("↑/↓ nav  |  Enter select  |  Esc close"))
        let hintRun = footer.drop { $0 != "↑" }.prefix { $0 != "│" }
        #expect(!hintRun.contains("│"))
    }

    @Test("a modal too small to draw publishes no bounds")
    func tooSmallPublishesNothing() {
        let overlay = PagerOverlay.list(id: "model", title: "Models", rows: modelRows)
        let result = frame(PagerOverlayStack([overlay]), width: 18, height: 8)
        #expect(result.overlays.isEmpty)
    }

    @Test("an empty filter result shows the reference's empty-state literal")
    func emptyState() {
        var list = PagerListOverlay(rows: modelRows)
        list.filterQuery = "zzzz"
        let overlay = PagerOverlay(
            id: "model",
            title: "Models",
            presentation: .centeredModal(.medium),
            content: .list(list)
        )
        let result = frame(PagerOverlayStack([overlay]))
        #expect(rows(result).contains { $0.contains("No matches") })
    }

    @Test("the model picker preselects and marks the active model")
    func modelPicker() {
        let overlay = PagerOverlay.modelPicker(
            models: [
                (id: "grok-4", provider: "xai"),
                (id: "grok-4-fast", provider: "xai"),
                (id: "claude-sonnet-4", provider: "anthropic")
            ],
            currentModelID: "grok-4-fast"
        )
        guard case .list(let list) = overlay.content else {
            Issue.record("expected a list overlay")
            return
        }
        #expect(list.selectedIndex == 1)
        #expect(list.rows[1].detail == "xai  ✓")

        let result = frame(PagerOverlayStack([overlay]), width: 70, height: 24)
        let painted = rows(result)
        #expect(painted.contains { $0.contains("❯ grok-4-fast") })
        #expect(painted.contains { $0.contains("claude-sonnet-4") })
    }

    @Test("the help overlay is a modal, not a transcript dump")
    func helpOverlay() {
        let overlay = PagerOverlay.help(lines: [
            PagerStyledLine(text: "Enter    send"),
            PagerStyledLine(text: "Esc      cancel")
        ])
        let result = frame(PagerOverlayStack([overlay]))
        let painted = rows(result)
        #expect(painted.contains { $0.contains("─ Keyboard Shortcuts ─") })
        #expect(painted.contains { $0.contains("Enter    send") })
        #expect(painted.contains { $0.contains("Esc close") })
    }

    @Test("the slash dropdown paints over the welcome screen")
    func completionsPaintOverWelcome() {
        // Regression: the full-screen welcome hero used to be painted after
        // the completions band, so typing `/` on a fresh session showed no
        // dropdown until the first message dismissed the hero.
        let result = renderPagerFrame(
            PagerRenderState(
                size: TerminalSize(width: 80, height: 30),
                conversation: [],
                completions: PagerCompletionMenu(
                    rows: [PagerCompletionRow(label: "/help", summary: "Browse commands")],
                    selectedIndex: 0
                ),
                input: PagerComposerState(text: "/"),
                overlays: PagerOverlayStack([
                    .welcome(PagerWelcomeOverlay(subtitle: "~/repo"), capturesInput: false)
                ])
            )
        )
        let painted = result.snapshot()
        #expect(painted.contains("/help"))
        #expect(painted.contains("Browse commands"))
    }

    @Test("the welcome screen paints the braille logo and hero box")
    func welcomeOverlay() {
        let welcome = PagerWelcomeOverlay(
            version: "0.1.0",
            menu: [
                PagerWelcomeMenuItem(id: "resume", key: "ctrl+s", label: "Resume session"),
                PagerWelcomeMenuItem(id: "quit", key: "ctrl+q", label: "Quit")
            ]
        )
        let result = frame(PagerOverlayStack([.welcome(welcome)]), width: 100, height: 30)
        let painted = rows(result)
        #expect(painted.contains { $0.contains(PagerWelcomeLogo.full[1]) })
        #expect(painted.contains { $0.contains("Open Grok Beta") })
        #expect(painted.contains { $0.contains("Resume session") })
        #expect(painted.contains { $0.contains("╭") })
    }

    @Test("below 22 rows the welcome screen drops the logo entirely")
    func welcomeLogoGate() {
        #expect(PagerWelcomeLogo.art(forHeight: 21) == nil)
        #expect(PagerWelcomeLogo.art(forHeight: 22) == PagerWelcomeLogo.small)
        #expect(PagerWelcomeLogo.art(forHeight: 26) == PagerWelcomeLogo.full)
    }

    @Test("the permission prompt is a bottom sheet with an accent rail, not a floating box")
    func permissionSheet() {
        let request = PagerPermissionRequest(
            id: "req-1",
            toolName: "Edit",
            targetPath: "src/main.swift",
            detail: "apply 2 hunks",
            diffPreview: [
                PagerDiffLine(kind: .removed, text: "let x = 1"),
                PagerDiffLine(kind: .added, text: "let x = 2")
            ]
        )
        let result = frame(PagerOverlayStack([.permission(request)]), width: 70, height: 24)
        let painted = rows(result)
        guard let bounds = result.overlays.first else {
            Issue.record("expected overlay bounds")
            return
        }

        // Every row of the sheet carries the `┃` rail in column 0.
        for y in bounds.frame.y..<bounds.frame.bottom {
            #expect(painted[y].hasPrefix("┃"), "row \(y) is missing the accent rail")
        }
        #expect(painted.contains { $0.contains("Allow Edit to src/main.swift?") })
        #expect(painted.contains { $0.contains("- let x = 1") })
        #expect(painted.contains { $0.contains("+ let x = 2") })
        // Numbered radio rows, cursor on the first.
        #expect(painted.contains { $0.contains("1 (●) Yes, allow all edits during this session") })
        #expect(painted.contains { $0.contains("2 (○) Yes") })
        #expect(painted.contains { $0.contains("3 (○) No, and tell Grok what to do differently") })
        // No border glyphs anywhere in the sheet.
        for y in bounds.frame.y..<bounds.frame.bottom {
            #expect(!painted[y].contains("┌") && !painted[y].contains("└"))
        }
    }

    @Test("a long diff truncates at the collapsed budget with a hidden-line marker")
    func permissionDiffTruncation() {
        let diff = (1...12).map { PagerDiffLine(kind: .added, text: "line \($0)") }
        let request = PagerPermissionRequest(
            id: "req-2",
            toolName: "Edit",
            targetPath: "big.swift",
            diffPreview: diff
        )
        let result = frame(PagerOverlayStack([.permission(request)]), width: 70, height: 30)
        let painted = rows(result)
        #expect(painted.contains { $0.contains("+ line 5") })
        #expect(!painted.contains { $0.contains("+ line 6") })
        #expect(painted.contains { $0.contains("… +7 lines") })
    }
}

// MARK: - Bounds exposure

@Suite("Pager overlay bounds")
struct PagerOverlayBoundsTests {
    @Test("row bounds hit-test back to the row that produced them")
    func rowHitTest() {
        let overlay = PagerOverlay.list(id: "model", title: "Models", rows: modelRows)
        let result = frame(PagerOverlayStack([overlay]))
        guard let bounds = result.overlays.first else {
            Issue.record("expected overlay bounds")
            return
        }
        #expect(bounds.rows.map(\.id) == ["grok-4", "grok-4-fast", "sonnet"])
        let target = bounds.rows[1]
        #expect(bounds.row(atX: target.frame.x + 2, y: target.frame.y)?.id == "grok-4-fast")
        #expect(bounds.row(atX: target.frame.x + 2, y: bounds.frame.y) == nil)
    }

    @Test("the frame hit-test rejects positions outside the popup")
    func frameHitTest() {
        let overlay = PagerOverlay.list(id: "model", title: "Models", rows: modelRows)
        let result = frame(PagerOverlayStack([overlay]))
        guard let bounds = result.overlays.first else {
            Issue.record("expected overlay bounds")
            return
        }
        #expect(bounds.hitTest(x: bounds.frame.x, y: bounds.frame.y))
        #expect(!bounds.hitTest(x: bounds.frame.x - 1, y: bounds.frame.y))
        #expect(result.overlay(atX: bounds.frame.x + 1, y: bounds.frame.y + 1)?.id == "model")
        #expect(result.overlay(atX: 0, y: 0) == nil)
    }

    @Test("footer hint bounds are published for click routing")
    func hintBounds() {
        let overlay = PagerOverlay.list(id: "model", title: "Models", rows: modelRows)
        let result = frame(PagerOverlayStack([overlay]))
        guard let bounds = result.overlays.first else {
            Issue.record("expected overlay bounds")
            return
        }
        #expect(bounds.hints.map(\.key) == ["↑/↓", "Enter", "Esc"])
        #expect(bounds.hints.allSatisfy { $0.frame.width > 0 })
    }

    @Test("permission option rows expose their decision as the row id")
    func permissionRowBounds() {
        let request = PagerPermissionRequest(id: "r", toolName: "Write", targetPath: "a.txt")
        let result = frame(PagerOverlayStack([.permission(request)]), width: 70, height: 24)
        guard let bounds = result.overlays.first else {
            Issue.record("expected overlay bounds")
            return
        }
        #expect(bounds.rows.map(\.id) == ["allowSession", "allowOnce", "deny"])
    }
}

// MARK: - Focus routing

@Suite("Pager overlay focus routing")
struct PagerOverlayFocusTests {
    @Test("an empty stack ignores keys so the composer keeps focus")
    func emptyStackIgnores() {
        var stack = PagerOverlayStack()
        #expect(!stack.isActive)
        #expect(stack.handle(character("a")) == .ignored)
    }

    @Test("an active overlay consumes every key, including ones it does not act on")
    func activeStackConsumes() {
        var stack = PagerOverlayStack([
            .help(lines: [PagerStyledLine(text: "one")])
        ])
        #expect(stack.isActive)
        #expect(stack.handle(key(.tab)) == .consumed)
        #expect(stack.handle(key(.f(5))) == .consumed)
    }

    @Test("an active overlay unfocuses the composer and takes the terminal cursor")
    func overlayTakesCursor() {
        let bare = frame(PagerOverlayStack())
        #expect(bare.cursorPosition != nil)
        let covered = frame(PagerOverlayStack([.help(lines: [PagerStyledLine(text: "x")])]))
        #expect(covered.cursorPosition == nil)
    }

    @Test("a non-capturing overlay paints but leaves the composer focused")
    func visibleButUnfocused() {
        let welcome = PagerWelcomeOverlay(menu: [
            PagerWelcomeMenuItem(id: "quit", key: "ctrl+q", label: "Quit")
        ])
        var stack = PagerOverlayStack([.welcome(welcome, capturesInput: false)])
        #expect(!stack.isActive)
        #expect(stack.focused == nil)
        #expect(stack.handle(character("a")) == .ignored)

        let result = frame(stack, width: 100, height: 30)
        // Painted — but the composer keeps the cursor.
        #expect(!result.overlays.isEmpty)
        #expect(result.cursorPosition != nil)
    }

    @Test("keys route past a non-capturing overlay to the capturing one below it")
    func routingSkipsNonCapturing() {
        var stack = PagerOverlayStack()
        stack.push(.list(id: "model", title: "Models", rows: modelRows))
        stack.push(.welcome(PagerWelcomeOverlay(), capturesInput: false))
        #expect(stack.focused?.id == "model")
        #expect(stack.handle(key(.down)) == .redraw)
        #expect(stack.handle(key(.enter)) == .selected(id: "model", rowID: "grok-4-fast"))
        // Esc dismisses the focused overlay, not the topmost painted one.
        #expect(stack.handle(key(.escape)) == .dismissed(id: "model"))
        #expect(stack.overlays.map(\.id) == ["welcome"])
    }

    @Test("arrow keys move the list cursor and Enter reports the selected row")
    func listSelection() {
        var stack = PagerOverlayStack([
            .list(id: "model", title: "Models", rows: modelRows)
        ])
        #expect(stack.handle(key(.down)) == .redraw)
        #expect(stack.handle(key(.enter)) == .selected(id: "model", rowID: "grok-4-fast"))
    }

    @Test("typing filters a filterable list and resets the cursor to the top")
    func listFiltering() {
        var stack = PagerOverlayStack([
            .list(id: "model", title: "Models", rows: modelRows)
        ])
        _ = stack.handle(key(.down))
        _ = stack.handle(key(.down))
        #expect(stack.handle(character("s")) == .redraw)
        #expect(stack.handle(character("o")) == .redraw)
        guard case .list(let list)? = stack.topmost?.content else {
            Issue.record("expected a list overlay")
            return
        }
        #expect(list.filterQuery == "so")
        #expect(list.filteredRows.map(\.id) == ["sonnet"])
        #expect(list.selectedIndex == 0)
        #expect(stack.handle(key(.enter)) == .selected(id: "model", rowID: "sonnet"))
    }

    @Test("backspace walks the filter back")
    func filterBackspace() {
        var stack = PagerOverlayStack([
            .list(id: "model", title: "Models", rows: modelRows)
        ])
        _ = stack.handle(character("x"))
        #expect(stack.handle(key(.backspace)) == .redraw)
        guard case .list(let list)? = stack.topmost?.content else {
            Issue.record("expected a list overlay")
            return
        }
        #expect(list.filterQuery.isEmpty)
        #expect(list.filteredRows.count == modelRows.count)
        // Nothing left to delete: consumed, not bubbled to the composer.
        #expect(stack.handle(key(.backspace)) == .consumed)
    }

    @Test("j/k navigate only when no filter field is competing for the key")
    func vimGate() {
        var filterable = PagerOverlayStack([
            .list(id: "a", title: "A", rows: modelRows, isFilterable: true)
        ])
        _ = filterable.handle(character("j"))
        guard case .list(let filtered)? = filterable.topmost?.content else {
            Issue.record("expected a list overlay")
            return
        }
        #expect(filtered.filterQuery == "j")
        #expect(filtered.selectedIndex == 0)

        var plain = PagerOverlayStack([
            .list(id: "b", title: "B", rows: modelRows, isFilterable: false)
        ])
        #expect(plain.handle(character("j")) == .redraw)
        #expect(plain.handle(key(.enter)) == .selected(id: "b", rowID: "grok-4-fast"))
    }

    @Test("text overlays scroll and clamp at both ends")
    func textScroll() {
        let lines = (1...40).map { PagerStyledLine(text: "line \($0)") }
        var stack = PagerOverlayStack([.help(lines: lines)])
        #expect(stack.handle(key(.up), viewportHeight: 10) == .consumed)
        #expect(stack.handle(key(.down), viewportHeight: 10) == .redraw)
        #expect(stack.handle(key(.end), viewportHeight: 10) == .redraw)
        guard case .text(let text)? = stack.topmost?.content else {
            Issue.record("expected a text overlay")
            return
        }
        #expect(text.scrollOffset == 30)
        #expect(stack.handle(key(.end), viewportHeight: 10) == .consumed)
    }

    @Test("welcome menu selection reports the menu item id")
    func welcomeSelection() {
        let welcome = PagerWelcomeOverlay(menu: [
            PagerWelcomeMenuItem(id: "resume", key: "ctrl+s", label: "Resume session"),
            PagerWelcomeMenuItem(id: "quit", key: "ctrl+q", label: "Quit")
        ])
        var stack = PagerOverlayStack([.welcome(welcome)])
        // No selection until navigation — upstream's `welcome_menu_index`
        // starts `None` (app/app_view.rs:1912) and Enter with no selection
        // dispatches nothing (`:4163-4165` requires `Some`).
        #expect(stack.handle(key(.enter)) == .consumed)
        // Down from no selection lands on the FIRST row; Up wraps to the
        // last (`handle_menu_nav`, app/app_view.rs:4518-4540).
        #expect(stack.handle(key(.down)) == .redraw)
        #expect(stack.handle(key(.down)) == .redraw)
        #expect(stack.handle(key(.enter)) == .selected(id: "welcome", rowID: "quit"))
        // Wrap: Down from the last row returns to the first.
        #expect(stack.handle(key(.down)) == .redraw)
        #expect(stack.handle(key(.enter)) == .selected(id: "welcome", rowID: "resume"))
        // Up from the first row wraps to the last.
        #expect(stack.handle(key(.up)) == .redraw)
        #expect(stack.handle(key(.up)) == .redraw)
        #expect(stack.handle(key(.enter)) == .selected(id: "welcome", rowID: "resume"))
    }
}

// MARK: - Dismiss semantics

@Suite("Pager overlay dismiss semantics")
struct PagerOverlayDismissTests {
    @Test("Esc dismisses the topmost overlay and the composer regains focus once empty")
    func escapeDismissesTopmost() {
        var stack = PagerOverlayStack()
        stack.push(.list(id: "first", title: "First", rows: modelRows))
        stack.push(.help(lines: [PagerStyledLine(text: "help")]))

        #expect(stack.handle(key(.escape)) == .dismissed(id: "help"))
        #expect(stack.topmost?.id == "first")
        #expect(stack.isActive)

        #expect(stack.handle(key(.escape)) == .dismissed(id: "first"))
        #expect(!stack.isActive)
        // Focus is back on the composer: further keys are no longer consumed.
        #expect(stack.handle(character("a")) == .ignored)
    }

    @Test("Esc is a no-op on the permission prompt — dismissing an approval has no safe default")
    func escapeSuppressedOnPermission() {
        let request = PagerPermissionRequest(id: "req", toolName: "Write", targetPath: "a.txt")
        var stack = PagerOverlayStack([.permission(request)])
        #expect(stack.handle(key(.escape)) == .consumed)
        #expect(stack.isActive)
        #expect(stack.topmost?.id == "permission:req")
    }

    @Test("Esc with a modifier does not dismiss")
    func modifiedEscapeDoesNotDismiss() {
        var stack = PagerOverlayStack([.help(lines: [PagerStyledLine(text: "x")])])
        #expect(stack.handle(key(.escape, .shift)) == .consumed)
        #expect(stack.isActive)
    }

    @Test("pushing an overlay that is already present re-raises it instead of duplicating")
    func pushDeduplicates() {
        var stack = PagerOverlayStack()
        stack.push(.list(id: "a", title: "A", rows: modelRows))
        stack.push(.help(lines: [PagerStyledLine(text: "h")]))
        stack.push(.list(id: "a", title: "A", rows: modelRows))
        #expect(stack.overlays.map(\.id) == ["help", "a"])
    }

    @Test("dismiss(id:) removes a buried overlay without disturbing the top")
    func dismissByIdentifier() {
        var stack = PagerOverlayStack()
        stack.push(.list(id: "a", title: "A", rows: modelRows))
        stack.push(.help(lines: [PagerStyledLine(text: "h")]))
        #expect(stack.dismiss(id: "a")?.id == "a")
        #expect(stack.topmost?.id == "help")
        #expect(stack.dismiss(id: "missing") == nil)
    }
}

// MARK: - Permission decisions

@Suite("Pager permission modal")
struct PagerPermissionTests {
    @Test("arrows move the radio cursor and Enter reports the decision")
    func enterReportsDecision() {
        let request = PagerPermissionRequest(id: "req", toolName: "Edit", targetPath: "a.swift")
        var stack = PagerOverlayStack([.permission(request)])
        #expect(stack.handle(key(.down)) == .redraw)
        #expect(
            stack.handle(key(.enter))
                == .permission(id: "permission:req", requestID: "req", decision: .allowOnce)
        )
    }

    @Test("digits select an option directly")
    func digitsSelectDirectly() {
        let request = PagerPermissionRequest(id: "req", toolName: "Edit", targetPath: "a.swift")
        var stack = PagerOverlayStack([.permission(request)])
        #expect(
            stack.handle(character("3"))
                == .permission(id: "permission:req", requestID: "req", decision: .deny)
        )
        // A digit past the option count is swallowed, not misrouted.
        #expect(stack.handle(character("9")) == .consumed)
    }

    @Test("the coordinator suspends the caller until the decision arrives")
    func coordinatorResolves() async {
        let coordinator = PagerPermissionCoordinator()
        let request = PagerPermissionRequest(id: "req", toolName: "Write", targetPath: "a.txt")

        async let decision = coordinator.decision(for: request)
        // Spin until the request is queued, then answer it the way the key
        // handler would.
        while await coordinator.currentRequest == nil {
            await Task.yield()
        }
        await coordinator.resolve(requestID: "req", decision: .allowSession)
        #expect(await decision == .allowSession)
        #expect(await coordinator.currentRequest == nil)
    }

    @Test("a stale request id cannot resolve the head request")
    func staleResolveIgnored() async {
        let coordinator = PagerPermissionCoordinator()
        let request = PagerPermissionRequest(id: "req", toolName: "Write")

        async let decision = coordinator.decision(for: request)
        while await coordinator.currentRequest == nil {
            await Task.yield()
        }
        await coordinator.resolve(requestID: "other", decision: .allowOnce)
        #expect(await coordinator.pendingCount == 1)
        await coordinator.resolve(requestID: "req", decision: .deny)
        #expect(await decision == .deny)
    }

    @Test("queued requests surface one at a time in arrival order")
    func coordinatorQueues() async {
        let coordinator = PagerPermissionCoordinator()
        let first = PagerPermissionRequest(id: "one", toolName: "Write")
        let second = PagerPermissionRequest(id: "two", toolName: "Edit")

        async let firstDecision = coordinator.decision(for: first)
        while await coordinator.currentRequest?.id != "one" {
            await Task.yield()
        }
        async let secondDecision = coordinator.decision(for: second)
        while await coordinator.pendingCount < 2 {
            await Task.yield()
        }
        #expect(await coordinator.currentRequest?.id == "one")

        await coordinator.resolve(requestID: "one", decision: .allowOnce)
        #expect(await firstDecision == .allowOnce)
        #expect(await coordinator.currentRequest?.id == "two")

        await coordinator.resolve(requestID: "two", decision: .deny)
        #expect(await secondDecision == .deny)
    }

    @Test("resolveAll denies every outstanding request on teardown")
    func coordinatorResolvesAll() async {
        let coordinator = PagerPermissionCoordinator()
        async let decision = coordinator.decision(for: PagerPermissionRequest(id: "x", toolName: "Write"))
        while await coordinator.currentRequest == nil {
            await Task.yield()
        }
        await coordinator.resolveAll()
        #expect(await decision == .deny)
        #expect(await coordinator.pendingCount == 0)
    }
}

@Suite("Dashboard peek at the overlay seam")
struct PagerOverlayPeekTests {
    private func frame(_ overlay: PagerOverlay, height: Int = 36) -> PagerRenderResult {
        renderPagerFrame(PagerRenderState(
            size: TerminalSize(width: 100, height: height),
            conversation: [.message(PagerMessage(role: .assistant, text: "behind"))],
            input: PagerComposerState(text: ""),
            showScrollbar: false,
            overlays: PagerOverlayStack([overlay])
        ))
    }

    private func roster(peek: PagerDashboardPeek?) -> PagerOverlay {
        var overlay = PagerOverlay.list(
            id: "dashboard",
            title: "Agent Dashboard",
            rows: (0..<6).map { PagerListRow(id: "r\($0)", label: "session \($0)") }
        )
        if case .list(var list) = overlay.content {
            list.peek = peek
            overlay.content = .list(list)
        }
        return overlay
    }

    /// Inertness: the field costs nothing to every list that has no peek.
    @Test("a nil peek renders byte-identically to a list without the field")
    func nilPeekIsInert() {
        let withField = frame(roster(peek: nil)).snapshot()
        let plain = frame(PagerOverlay.list(
            id: "dashboard",
            title: "Agent Dashboard",
            rows: (0..<6).map { PagerListRow(id: "r\($0)", label: "session \($0)") }
        )).snapshot()
        #expect(withField == plain)
    }

    @Test("the band paints between the list and the footer")
    func bandPaintsBelowTheList() {
        let painted = frame(roster(peek: PagerDashboardPeek(
            statusLabel: "Working",
            timeAgo: "12s",
            items: [
                .message(PagerMessage(role: .user, text: "peekpin")),
                .message(PagerMessage(role: .assistant, text: "peekbody")),
            ]
        ))).snapshot()
        let rows = painted.split(separator: "\n", omittingEmptySubsequences: false)
        guard let listRow = rows.firstIndex(where: { $0.contains("session 0") }),
              let pinRow = rows.firstIndex(where: { $0.contains("peekpin") })
        else {
            Issue.record("expected list and peek rows: \(painted)")
            return
        }
        #expect(listRow < pinRow, "the band sits below the list rows")
        #expect(painted.contains("peekbody"))
    }

    /// List-first refusal (`allocate_peek`, layout.rs:143-149): under the
    /// floor the roster keeps the whole modal rather than sharing it with a
    /// band too small to say anything.
    @Test("no band under the list floor")
    func listFirstRefusal() {
        let painted = frame(roster(peek: PagerDashboardPeek(
            statusLabel: "Working",
            items: [.message(PagerMessage(role: .user, text: "peekpin"))]
        )), height: 20).snapshot()
        #expect(!painted.contains("peekpin"))
    }

    /// `push` would reset both; `updateList` must not.
    @Test("updateList swaps the peek preserving selectedIndex and filterQuery")
    func updateListPreservesCursorAndFilter() {
        var stack = PagerOverlayStack([roster(peek: nil)])
        stack.updateList(id: "dashboard") { list in
            list.filterQuery = "session"
            list.selectedIndex = 3
        }
        stack.updateList(id: "dashboard") { list in
            list.peek = PagerDashboardPeek(statusLabel: "Idle")
        }
        guard case .list(let list) = stack.overlays[0].content else {
            Issue.record("expected a list overlay")
            return
        }
        #expect(list.selectedIndex == 3)
        #expect(list.filterQuery == "session")
        #expect(list.peek?.statusLabel == "Idle")
        #expect(!stack.updateList(id: "not-open") { $0.peek = nil })
    }
}

// MARK: - Row actions

// The list's row-verb table (B1 C-1): a bound bare key acts on the SELECTED
// row before the filter can take the character, dispatching
// `<prefix>:<rowID>` through the same `.selected` channel Enter uses. The
// recorded cost — the bound key no longer types into that overlay's filter —
// is pinned here alongside the guards that keep the verb off headers,
// placeholders, and modified keystrokes.
@Suite("Pager list row actions")
struct PagerListRowActionTests {
    private func roster(rows rosterRows: [PagerListRow]) -> PagerOverlayStack {
        var overlay = PagerOverlay.list(
            id: "dashboard",
            title: "Agent Dashboard",
            rows: rosterRows,
            isFilterable: true
        )
        if case .list(var list) = overlay.content {
            list.rowActions = [PagerListRowAction(key: "x", rowIDPrefix: "close")]
            overlay.content = .list(list)
        }
        return PagerOverlayStack([overlay])
    }

    @Test("a bound key dispatches prefix:rowID for the selected row, not the filter")
    func boundKeyDispatchesThroughThePrefix() {
        var stack = roster(rows: [
            PagerListRow(id: "attach:one", label: "one"),
            PagerListRow(id: "attach:two", label: "two"),
        ])
        #expect(stack.handle(character("x")) == .selected(id: "dashboard", rowID: "close:attach:one"))
        guard case .list(let list) = stack.overlays[0].content else {
            Issue.record("expected a list overlay")
            return
        }
        #expect(list.filterQuery.isEmpty, "the bound key must never leak into the filter")
    }

    @Test("the verb never fires on a non-selectable selection; the filter takes the key")
    func nonSelectableSelectionFallsThroughToTheFilter() {
        var stack = roster(rows: [
            PagerListRow(id: "subagent:sub-1", label: "child", isSelectable: false)
        ])
        #expect(stack.handle(character("x")) == .redraw)
        guard case .list(let list) = stack.overlays[0].content else {
            Issue.record("expected a list overlay")
            return
        }
        #expect(list.filterQuery == "x", "a verb on a row that dispatches nowhere must not dispatch")
    }

    @Test("unbound characters still type into the filter on an action-bearing list")
    func unboundCharactersStillFilter() {
        var stack = roster(rows: [
            PagerListRow(id: "attach:one", label: "one")
        ])
        #expect(stack.handle(character("a")) == .redraw)
        guard case .list(let list) = stack.overlays[0].content else {
            Issue.record("expected a list overlay")
            return
        }
        #expect(list.filterQuery == "a")
    }

    @Test("a modified keystroke bypasses the verb table")
    func modifiedKeystrokeBypassesTheVerb() {
        var stack = roster(rows: [
            PagerListRow(id: "attach:one", label: "one")
        ])
        let outcome = stack.handle(
            KeyEvent(key: .char("x"), modifiers: [.control], character: "x")
        )
        #expect(outcome == .consumed, "ctrl+x is neither the verb nor filter input")
    }
}

// The in-place retitle seam (B1-w2): a search query living in the modal
// title must repaint without re-pushing — push would reset the cursor.
@Suite("Pager overlay retitle")
struct PagerOverlayRetitleTests {
    @Test("retitle edits the open overlay in place and refuses unknown ids")
    func retitleInPlace() {
        var stack = PagerOverlayStack([
            .list(id: "dashboard", title: "Agent Dashboard", rows: [
                PagerListRow(id: "r0", label: "row"),
            ])
        ])
        stack.updateList(id: "dashboard") { $0.selectedIndex = 0 }
        let retitled = stack.retitle(id: "dashboard", title: "Agent Dashboard — /s:idle")
        let unknown = stack.retitle(id: "not-open", title: "x")
        #expect(retitled)
        #expect(stack.overlays[0].title == "Agent Dashboard — /s:idle")
        #expect(!unknown)
        guard case .list(let list) = stack.overlays[0].content else {
            Issue.record("expected a list overlay")
            return
        }
        #expect(list.selectedIndex == 0, "retitle never touches the list state")
    }
}
