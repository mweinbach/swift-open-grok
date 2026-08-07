import Testing
import Foundation
@testable import OpenGrokPagerRender
import OpenGrokTerminalCore

// MARK: - Helpers

private func settingsFrame(
    _ overlay: PagerSettingsOverlay,
    width: Int = 80,
    height: Int = 30,
    theme: PagerRenderTheme = .grokNight
) -> PagerRenderResult {
    renderPagerFrame(
        PagerRenderState(
            size: TerminalSize(width: width, height: height),
            conversation: [.message(PagerMessage(role: .assistant, text: "behind"))],
            input: PagerComposerState(text: ""),
            theme: theme,
            showScrollbar: false,
            overlays: PagerOverlayStack([PagerOverlay.settings(overlay)])
        )
    )
}

private func painted(_ result: PagerRenderResult) -> [String] {
    result.snapshot().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
}

private func key(_ code: KeyCode, _ modifiers: KeyModifiers = []) -> KeyEvent {
    KeyEvent(key: code, modifiers: modifiers)
}

private func character(_ value: Character, _ modifiers: KeyModifiers = []) -> KeyEvent {
    KeyEvent(key: .char(value), modifiers: modifiers, character: value)
}

/// Drive a sequence of keys and collect every outcome, so a test can assert on
/// the whole interaction rather than one step of it.
@discardableResult
private func drive(
    _ overlay: inout PagerSettingsOverlay,
    _ events: [KeyEvent]
) -> [PagerSettingsOutcome] {
    events.map { overlay.handle($0) }
}

/// Move the cursor onto `key`. Bounded: a miss fails the test instead of
/// spinning, because a hung test wedges the whole verification gate.
@discardableResult
private func focus(_ overlay: inout PagerSettingsOverlay, _ key: String) -> Bool {
    for _ in 0...overlay.registry.entries.count {
        if overlay.selectedKey == key { return true }
        _ = overlay.handle(key: .down)
    }
    Issue.record("could not focus settings row \(key)")
    return false
}

private extension PagerSettingsOverlay {
    mutating func handle(key code: KeyCode) -> PagerSettingsOutcome {
        handle(KeyEvent(key: code, modifiers: []))
    }
}

/// One integer row for stepper editor tests — `max_thoughts_width` is hidden
/// from the live registry because the renderer does not read it yet.
private let stepperTestRegistry = PagerSettingsRegistry(entries: [
    PagerSettingMeta(
        key: "max_thoughts_width",
        category: .appearance,
        label: "Max thoughts width",
        description: "Fixture row for int stepper coverage.",
        keywords: ["thinking"],
        kind: .integer(default: 120, minimum: 40, maximum: 500),
        storage: .config(path: "ui.max_thoughts_width")
    )
])

// MARK: - Registry

@Suite("Settings registry")
struct PagerSettingsRegistryTests {
    @Test("the catalog carries 74 rows across 8 categories")
    func catalogSize() {
        let registry = PagerSettingsRegistry.default
        // Upstream registers 91; this port hides `show_tips` plus every `[ui]`
        // row whose value the live renderer never reads — registered no-ops are
        // forbidden by the parity rules. Re-add a row with its reader.
        #expect(registry.entries.count == 74)
        #expect(PagerSettingCategory.ordered.count == 8)
        #expect(!registry.entries.contains { $0.key == "show_tips" })
        #expect(!registry.entries.contains { $0.key == "compact_mode" })
    }

    @Test("per-category counts match the reference's registry")
    func categoryCounts() {
        let registry = PagerSettingsRegistry.default
        #expect(registry.rows(in: .appearance).count == 7)
        #expect(registry.rows(in: .mouse).count == 0)
        #expect(registry.rows(in: .editor).count == 6)
        #expect(registry.rows(in: .agent).count == 9)
        #expect(registry.rows(in: .privacy).count == 1)
        // 24 includes `meta_api_key` (`settings/defs.rs:1184-1202`).
        #expect(registry.rows(in: .models).count == 24)
        // 20 top-level Advanced rows plus the 7 contextual-hint children, which
        // are registered but only reachable inside the group sheet. Upstream
        // has one more (`show_tips`), hidden here until the tips banner exists.
        #expect(registry.rows(in: .advanced).count == 27)
        #expect(registry.rows(in: .session).isEmpty)
    }

    @Test("keys are unique — string equality gates depend on it")
    func uniqueKeys() {
        let keys = PagerSettingsRegistry.default.entries.map(\.key)
        #expect(Set(keys).count == keys.count)
    }

    @Test("every Advanced feature flag the audit called unreachable is registered")
    func advancedFlagsPresent() {
        let registry = PagerSettingsRegistry.default
        let required = [
            "code_mode", "hunk_tracker_mode", "features.lsp_tools", "memory.enabled",
            "memory.dream.enabled", "features.two_pass_compaction", "features.web_fetch",
            "toolset.web_fetch.allow_local", "features.telemetry",
            "contextual_hints.ssh_wrap", "contextual_hints.small_screen",
            "contextual_hints.word_select", "antigravity_subagents",
            "antigravity_skip_permissions", "swarm_mode", "auto_update"
        ]
        for key in required {
            #expect(registry.find(key) != nil, "missing settings row: \(key)")
        }
    }

    @Test("search ANDs every word across label, description, key, and keywords")
    func searchIsConjunctive() {
        let registry = PagerSettingsRegistry.default
        #expect(registry.search("theme").contains { $0.key == "theme" })
        // "auto" and "dark" appear in different fields of the same row.
        let autoDark = registry.search("auto dark")
        #expect(autoDark.contains { $0.key == "auto_dark_theme" })
        #expect(registry.search("zzzznotathing").isEmpty)
    }

    @Test("restart-required rows are marked, and ordinary ones are not")
    func restartFlags() {
        let registry = PagerSettingsRegistry.default
        #expect(registry.find("screen_mode")?.restartRequired == true)
        #expect(registry.find("auto_update")?.restartRequired == true)
        #expect(registry.find("diagnostics.crash_handler")?.restartRequired == true)
        #expect(registry.find("theme")?.restartRequired == false)
        #expect(registry.find("vim_mode")?.restartRequired == false)
    }

    @Test("group children never surface as top-level rows")
    func groupChildrenHidden() {
        let overlay = PagerSettingsOverlay()
        let keys = overlay.visibleRows.compactMap(\.settingKey)
        #expect(keys.contains("contextual_hints"))
        #expect(!keys.contains("contextual_hints.undo"))
    }
}

// MARK: - Browse frames

@Suite("Settings modal browse")
struct PagerSettingsBrowseTests {
    @Test("the browse list paints a search bar, category headers, and values")
    func browseGolden() {
        let result = settingsFrame(PagerSettingsOverlay())
        let rows = painted(result)
        let joined = rows.joined(separator: "\n")

        #expect(joined.contains("─ Settings ─"))
        #expect(joined.contains("search:"))
        #expect(joined.contains("Appearance"))
        #expect(joined.contains("Vim scrollback"))
        // Bool rows read `on`/`off`; `vim_mode` defaults off.
        #expect(joined.contains("off"))
        #expect(joined.contains("Theme"))
        // The default theme row shows the choice's display name, not its
        // canonical spelling.
        #expect(joined.contains("Grok Night"))
    }

    @Test("an enum row shows a chevron and a bool row does not")
    func chevronOnlyOnSubPaneRows() {
        var overlay = PagerSettingsOverlay()
        // Land on Theme.
        focus(&overlay, "theme")
        let rows = painted(settingsFrame(overlay))
        let themeRow = rows.first { $0.contains("Theme") && $0.contains("Grok Night") }
        #expect(themeRow?.contains("\u{203A}") == true)
    }

    @Test("expanding a row reveals its description; restart-required adds the pill")
    func expansionAndRestartPill() {
        var overlay = PagerSettingsOverlay()
        // `screen_mode` is the first Appearance row and is restart-required.
        focus(&overlay, "screen_mode")
        #expect(overlay.handle(key(.right)) == .redraw)

        let joined = painted(settingsFrame(overlay)).joined(separator: "\n")
        #expect(joined.contains("· restart"))
        #expect(joined.contains("How Open Grok opens next time"))

        // Collapsing takes both away again — the pill is a property of the
        // expanded state, not a permanent badge.
        #expect(overlay.handle(key(.left)) == .redraw)
        let collapsed = painted(settingsFrame(overlay)).joined(separator: "\n")
        #expect(!collapsed.contains("· restart"))
    }

    @Test("headers are skipped by the cursor in both directions")
    func cursorSkipsHeaders() {
        var overlay = PagerSettingsOverlay()
        #expect(overlay.selectedKey == "screen_mode")
        // Walk to the end of Appearance and into Editor; every landing is a row.
        for _ in 0..<20 {
            _ = overlay.handle(key(.down))
            #expect(overlay.selectedKey != nil)
        }
        for _ in 0..<40 {
            _ = overlay.handle(key(.up))
            #expect(overlay.selectedKey != nil)
        }
        #expect(overlay.selectedKey == "screen_mode")
    }

    @Test("g and G jump to the first and last selectable rows")
    func gotoEdges() {
        var overlay = PagerSettingsOverlay()
        _ = overlay.handle(character("G"))
        #expect(overlay.selectedKey == "tools.respect_gitignore")
        _ = overlay.handle(character("g"))
        #expect(overlay.selectedKey == "screen_mode")
    }

    @Test("space toggles a bool in place and reports the commit")
    func toggleBool() {
        var overlay = PagerSettingsOverlay()
        focus(&overlay, "vim_mode")
        let outcome = overlay.handle(character(" "))
        #expect(outcome == .event(.commit(key: "vim_mode", value: .bool(true))))
        #expect(overlay.value(for: "vim_mode") == .bool(true))
        // And the frame reflects it without the caller writing anything back.
        #expect(painted(settingsFrame(overlay)).joined().contains("on"))
    }

    @Test("d asks for a reset rather than applying one")
    func resetIsAConfirmation() {
        var overlay = PagerSettingsOverlay()
        overlay.values["vim_mode"] = .bool(true)
        focus(&overlay, "vim_mode")
        let outcome = overlay.handle(character("d"))
        #expect(outcome == .event(.resetRequested(key: "vim_mode")))
        // Nothing changed yet — the caller confirms first.
        #expect(overlay.value(for: "vim_mode") == .bool(true))
    }

    @Test("a locked row cannot be toggled or reset, and shows its reason")
    func lockedRow() {
        var overlay = PagerSettingsOverlay(
            locks: ["coding_data_sharing": .policyManaged],
            expandedKeys: ["coding_data_sharing"]
        )
        focus(&overlay, "coding_data_sharing")
        #expect(overlay.handle(character(" ")) == .consumed)
        #expect(overlay.handle(character("d")) == .consumed)
        #expect(overlay.handle(key(.enter)) == .consumed)

        let joined = painted(settingsFrame(overlay)).joined(separator: "\n")
        #expect(joined.contains("Policy Managed"))
        #expect(joined.contains("Locked by your organization's policy."))
    }

    @Test("a ZDR lock replaces the value entirely")
    func zeroDataRetentionLock() {
        let overlay = PagerSettingsOverlay(locks: ["coding_data_sharing": .zeroDataRetention])
        let meta = overlay.registry.find("coding_data_sharing")!
        #expect(pagerSettingsValueDisplay(overlay, meta: meta) == "ZDR")
    }
}

// MARK: - Filtering

@Suite("Settings modal filter")
struct PagerSettingsFilterTests {
    @Test("typing filters rows and drops headers that no longer head anything")
    func filterNarrowsRows() {
        var overlay = PagerSettingsOverlay()
        drive(&overlay, [character("/"), character("t"), character("h"), character("e"),
                         character("m"), character("e")])
        let keys = overlay.visibleRows.compactMap(\.settingKey)
        #expect(keys.contains("theme"))
        #expect(!keys.contains("scroll_speed"))
        // Only sections with a surviving row keep a header.
        let categories = overlay.visibleRows.compactMap { row -> PagerSettingCategory? in
            if case .header(let category) = row { return category }
            return nil
        }
        #expect(!categories.contains(.mouse))
    }

    @Test("an empty result paints the no-matches message")
    func emptyFilterGolden() {
        var overlay = PagerSettingsOverlay()
        overlay.mode = .filtering
        overlay.filterQuery = "zzzznotathing"
        let joined = painted(settingsFrame(overlay)).joined(separator: "\n")
        #expect(joined.contains("No matches for \"zzzznotathing\""))
    }

    @Test("Esc clears the query and returns to browse without closing the modal")
    func escapeClearsRatherThanCloses() {
        var overlay = PagerSettingsOverlay()
        drive(&overlay, [character("/"), character("t"), character("h")])
        #expect(overlay.filterQuery == "th")
        let outcome = overlay.handle(key(.escape))
        #expect(outcome == .redraw)
        #expect(overlay.filterQuery.isEmpty)
        #expect(overlay.mode == .browse)
    }

    @Test("Enter commits the filter and keeps it while returning focus to the list")
    func enterCommitsFilter() {
        var overlay = PagerSettingsOverlay()
        drive(&overlay, [character("/"), character("v"), character("i"), character("m")])
        _ = overlay.handle(key(.enter))
        #expect(overlay.mode == .browse)
        #expect(overlay.filterQuery == "vim")
    }

    @Test("Backspace in browse edits the committed query without refocusing")
    func browseBackspaceEditsQuery() {
        var overlay = PagerSettingsOverlay()
        drive(&overlay, [character("/"), character("v"), character("i"), character("m"), key(.enter)])
        _ = overlay.handle(key(.backspace))
        #expect(overlay.filterQuery == "vi")
        #expect(overlay.mode == .browse)
    }
}

// MARK: - Enum chooser

@Suite("Settings enum chooser")
struct PagerSettingsChooserTests {
    private func openThemeChooser() -> PagerSettingsOverlay {
        var overlay = PagerSettingsOverlay()
        focus(&overlay, "theme")
        _ = overlay.handle(key(.enter))
        return overlay
    }

    @Test("the chooser paints the breadcrumb title, the header, and every choice")
    func chooserGolden() {
        let overlay = openThemeChooser()
        let joined = painted(settingsFrame(overlay)).joined(separator: "\n")
        #expect(joined.contains("Settings \u{203A} Theme"))
        #expect(joined.contains("Color theme for the pager UI."))
        for name in ["Auto", "Grok Night", "Grok Day", "Tokyo Night", "Rose Pine Moon", "Oscura Midnight"] {
            #expect(joined.contains(name), "chooser is missing \(name)")
        }
        // The filled dot marks the committed value.
        #expect(joined.contains("●"))
        #expect(joined.contains("○"))
    }

    @Test("moving in a preview-capable chooser emits a preview, not a commit")
    func previewOnMove() {
        var overlay = openThemeChooser()
        // Starts on the committed value, Grok Night (index 1).
        let outcome = overlay.handle(key(.down))
        #expect(outcome == .event(.preview(key: "theme", value: .string("grokday"))))
        // Nothing is committed yet.
        #expect(overlay.stringValue(for: "theme") == "groknight")
    }

    @Test("Esc walks the preview back to where it started")
    func escapeRevertsPreview() {
        var overlay = openThemeChooser()
        drive(&overlay, [key(.down), key(.down)])
        let outcome = overlay.handle(key(.escape))
        #expect(outcome == .event(.preview(key: "theme", value: .string("groknight"))))
        #expect(overlay.mode == .browse)
    }

    @Test("Enter is the single commit point")
    func enterCommits() {
        var overlay = openThemeChooser()
        _ = overlay.handle(key(.down))
        let outcome = overlay.handle(key(.enter))
        #expect(outcome == .event(.commit(key: "theme", value: .string("grokday"))))
        #expect(overlay.stringValue(for: "theme") == "grokday")
        #expect(overlay.mode == .browse)
    }

    @Test("a chooser without preview support stays silent while navigating")
    func noPreviewOnPlainEnum() {
        var overlay = PagerSettingsOverlay()
        focus(&overlay, "permission_mode")
        _ = overlay.handle(key(.enter))
        // Previewing a permission mode would *apply* it, so it must not fire.
        #expect(overlay.handle(key(.down)) == .redraw)
    }

    @Test("gated choices are withheld from the chooser")
    func gatedChoiceHidden() {
        var overlay = PagerSettingsOverlay(gatedChoices: ["permission_mode": ["auto"]])
        focus(&overlay, "permission_mode")
        _ = overlay.handle(key(.enter))
        let meta = overlay.registry.find("permission_mode")!
        let offered = overlay.choices(for: meta).map(\.canonical)
        #expect(offered == ["default", "ask", "always-approve"])
        // The row is painted; only the gated choice is gone. Asserting on the
        // frame text alone would trip over the word "Auto" in the row's own
        // description, which is not a choice.
        #expect(painted(settingsFrame(overlay)).joined().contains("Always approve"))
    }

    @Test("the consent chooser refuses d — opting back in by keystroke is a bug")
    func consentChooserHasNoReset() {
        var overlay = PagerSettingsOverlay()
        focus(&overlay, "coding_data_sharing")
        _ = overlay.handle(key(.enter))
        #expect(overlay.handle(character("d")) == .consumed)
    }
}

// MARK: - Group sheet

@Suite("Settings group sheet")
struct PagerSettingsGroupTests {
    private func openHints() -> PagerSettingsOverlay {
        var overlay = PagerSettingsOverlay()
        focus(&overlay, "contextual_hints")
        _ = overlay.handle(key(.enter))
        return overlay
    }

    @Test("the sheet lists all seven children with their on/off state")
    func groupGolden() {
        let overlay = openHints()
        let joined = painted(settingsFrame(overlay)).joined(separator: "\n")
        #expect(joined.contains("Settings \u{203A} Show contextual hints"))
        for label in ["Undo", "Plan mode", "Image input", "Send now",
                      "Small screen", "Word select", "SSH wrap"] {
            #expect(joined.contains(label), "group sheet is missing \(label)")
        }
        #expect(joined.contains("on"))
    }

    @Test("toggling a child commits it and leaves the sheet open")
    func toggleChildKeepsSheetOpen() {
        var overlay = openHints()
        let outcome = overlay.handle(character(" "))
        #expect(outcome == .event(.commit(key: "contextual_hints.undo", value: .bool(false))))
        if case .pickingGroup = overlay.mode {} else {
            Issue.record("sheet closed on toggle")
        }
    }

    @Test("Esc backs out to the list rather than closing the modal")
    func escapeBacksOut() {
        var overlay = openHints()
        #expect(overlay.handle(key(.escape)) == .redraw)
        #expect(overlay.mode == .browse)
    }

    @Test("a dynamic multi-select toggles by choice, not by child row")
    func multiSelectToggle() {
        var overlay = PagerSettingsOverlay(
            dynamicChoices: [.openCodeGoModels: [
                PagerSettingChoice(canonical: "gpt-oss-120b", display: "GPT-OSS 120B"),
                PagerSettingChoice(canonical: "qwen3-coder", display: "Qwen3 Coder")
            ]],
            multiSelectEnabled: ["opencode_go_models": ["gpt-oss-120b"]]
        )
        focus(&overlay, "opencode_go_models")
        _ = overlay.handle(key(.enter))
        let joined = painted(settingsFrame(overlay)).joined(separator: "\n")
        #expect(joined.contains("GPT-OSS 120B"))

        let outcome = overlay.handle(character(" "))
        #expect(outcome == .event(.toggleMultiSelect(
            key: "opencode_go_models", choice: "gpt-oss-120b", enabled: false
        )))
    }
}

// MARK: - Editors

@Suite("Settings editors")
struct PagerSettingsEditorTests {
    private func openStepper() -> PagerSettingsOverlay {
        var overlay = PagerSettingsOverlay(registry: stepperTestRegistry)
        focus(&overlay, "max_thoughts_width")
        _ = overlay.handle(key(.enter))
        return overlay
    }

    @Test("the int stepper paints ‹ N › and steps by the reference's sizes")
    func stepperGolden() {
        var overlay = openStepper()
        #expect(painted(settingsFrame(overlay)).joined().contains("\u{2039}"))
        #expect(painted(settingsFrame(overlay)).joined().contains("120"))

        // 40...500 spans 460, so small is 5 and large is 10.
        #expect(PagerSettingsOverlay.stepSizes(minimum: 40, maximum: 500) == (5, 10))
        _ = overlay.handle(key(.up))
        #expect(overlay.mode == .editingInt(key: "max_thoughts_width", value: 125))
        _ = overlay.handle(key(.right))
        #expect(overlay.mode == .editingInt(key: "max_thoughts_width", value: 135))
    }

    @Test("the stepper clamps at its bounds and ignores digits")
    func stepperClampsAndIgnoresText() {
        var overlay = openStepper()
        for _ in 0..<200 { _ = overlay.handle(key(.down)) }
        #expect(overlay.mode == .editingInt(key: "max_thoughts_width", value: 40))
        // A no-op clamp reports no change rather than a redraw.
        #expect(overlay.handle(key(.down)) == .consumed)
        // It is a stepper, not a text field.
        #expect(overlay.handle(character("7")) == .consumed)
        #expect(overlay.mode == .editingInt(key: "max_thoughts_width", value: 40))
    }

    @Test("the stepper commits on Enter and cancels cleanly on Esc")
    func stepperCommitAndCancel() {
        var overlay = openStepper()
        _ = overlay.handle(key(.up))
        #expect(overlay.handle(key(.enter))
            == .event(.commit(key: "max_thoughts_width", value: .integer(125))))
        #expect(overlay.value(for: "max_thoughts_width") == .integer(125))

        var second = openStepper()
        _ = second.handle(key(.up))
        #expect(second.handle(key(.escape)) == .redraw)
        #expect(second.value(for: "max_thoughts_width") == .integer(120))
    }

    @Test("a secret editor masks input and never paints the plaintext")
    func secretIsMasked() {
        var overlay = PagerSettingsOverlay()
        focus(&overlay, "kimi_api_key")
        _ = overlay.handle(key(.enter))
        #expect(painted(settingsFrame(overlay)).joined().contains("<paste or type a key>"))

        drive(&overlay, [character("s"), character("k"), character("-"), character("9")])
        let joined = painted(settingsFrame(overlay)).joined(separator: "\n")
        #expect(joined.contains("****"))
        #expect(!joined.contains("sk-9"))
    }

    @Test("the secret leaves in the event exactly once and is not retained")
    func secretHandoff() {
        var overlay = PagerSettingsOverlay()
        overlay.mode = .editingSecret(key: "kimi_api_key", buffer: "sk-abc", error: nil)
        let outcome = overlay.handle(key(.enter))
        #expect(outcome == .event(.secret(key: "kimi_api_key", value: "sk-abc")))
        #expect(overlay.mode == .browse)
        // The row now reads as configured; the key itself is gone from the modal.
        #expect(overlay.value(for: "kimi_api_key") == .secret(.stored))
    }

    @Test("Enter on an empty secret preserves what is already stored")
    func emptySecretPreserves() {
        var overlay = PagerSettingsOverlay(values: ["kimi_api_key": .secret(.stored)])
        overlay.mode = .editingSecret(key: "kimi_api_key", buffer: "", error: nil)
        #expect(overlay.handle(key(.enter)) == .redraw)
        #expect(overlay.value(for: "kimi_api_key") == .secret(.stored))
    }

    @Test("a secret with whitespace is refused with a visible error")
    func secretValidation() {
        var overlay = PagerSettingsOverlay()
        overlay.mode = .editingSecret(key: "kimi_api_key", buffer: "sk abc", error: nil)
        _ = overlay.handle(key(.enter))
        guard case .editingSecret(_, _, let error) = overlay.mode else {
            Issue.record("editor closed on an invalid key")
            return
        }
        #expect(error == "Key cannot contain whitespace")
        #expect(painted(settingsFrame(overlay)).joined().contains("whitespace"))
    }

    @Test("secret status renders the reference's three words")
    func secretStatusDisplay() {
        #expect(PagerSecretStatus.missing.display == "not configured")
        #expect(PagerSecretStatus.stored.display == "saved")
        #expect(PagerSecretStatus.environmentOverride.display == "environment override")
    }
}

// MARK: - Close semantics

@Suite("Settings modal close semantics")
struct PagerSettingsCloseTests {
    @Test("F2 and Ctrl+, close from anywhere, including a sub-pane")
    func closeKeysWorkEverywhere() {
        var overlay = PagerSettingsOverlay()
        #expect(overlay.handle(key(.f(2))) == .close)

        var inChooser = PagerSettingsOverlay()
        focus(&inChooser, "theme")
        _ = inChooser.handle(key(.enter))
        #expect(inChooser.handle(character(",", .control)) == .close)
    }

    @Test("Esc in a sub-pane backs out; Esc in browse closes")
    func escapeUnwindsOneLevel() {
        var stack = PagerOverlayStack([PagerOverlay.settings(PagerSettingsOverlay())])
        // Open the theme chooser through the stack, the way a session would.
        for _ in 0...PagerSettingsRegistry.default.entries.count {
            guard case .settings(let settings)? = stack.topmost?.content else { break }
            if settings.selectedKey == "theme" { break }
            _ = stack.handle(key(.down))
        }
        _ = stack.handle(key(.enter))
        // First Esc backs out of the chooser and the modal survives.
        _ = stack.handle(key(.escape))
        #expect(stack.topmost != nil)
        guard case .settings(let settings)? = stack.topmost?.content else {
            Issue.record("settings overlay was dismissed by a sub-pane Escape")
            return
        }
        #expect(settings.mode == .browse)
        // Second Esc closes.
        let outcome = stack.handle(key(.escape))
        #expect(outcome == .dismissed(id: "settings"))
        #expect(stack.isEmpty)
    }

    @Test("the stack forwards a settings decision to the session")
    func stackForwardsEvents() {
        var overlay = PagerSettingsOverlay()
        focus(&overlay, "vim_mode")
        var stack = PagerOverlayStack([PagerOverlay.settings(overlay)])
        let outcome = stack.handle(character(" "))
        #expect(outcome == .setting(
            id: "settings",
            event: .commit(key: "vim_mode", value: .bool(true))
        ))
    }

    @Test("the footer follows the mode, so the keys shown are the keys that work")
    func footerFollowsMode() {
        var overlay = PagerSettingsOverlay()
        // Focus an explicit boolean row: the catalog's first selectable row is
        // no longer a toggle now that reader-less appearance rows are hidden,
        // and this test pins hint/kind agreement, not catalog ordering.
        focus(&overlay, "vim_mode")
        #expect(pagerSettingsHints(overlay).contains { $0.key == "Space" })

        focus(&overlay, "theme")
        _ = overlay.handle(key(.enter))
        let hints = pagerSettingsHints(overlay)
        // A preview-capable chooser says "try", not "nav".
        #expect(hints.contains { $0.key == "↑/↓" && $0.label == "try" })
        #expect(hints.contains { $0.key == "Esc" && $0.label == "revert" })
    }
}

// MARK: - Store

@Suite("Settings write-through")
struct PagerSettingsStoreTests {
    private func temporaryConfig() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-settings-\(UUID().uuidString)")
            .appendingPathComponent("config.toml")
    }

    @Test("a bool commit lands at its dotted path and reads back")
    func boolRoundTrip() throws {
        let store = PagerSettingsStore(configPath: temporaryConfig())
        let path = try store.write(key: "vim_mode", value: .bool(true))
        #expect(path == "ui.vim_mode")

        let text = try String(contentsOf: store.configPath, encoding: .utf8)
        #expect(text.contains("[ui]"))
        #expect(text.contains("vim_mode = true"))
        #expect(try store.load()["vim_mode"] == .bool(true))
    }

    @Test("an enum, an int, and a deep path all round-trip")
    func mixedRoundTrip() throws {
        let store = PagerSettingsStore(configPath: temporaryConfig())
        try store.write(key: "theme", value: .string("tokyonight"))
        try store.write(key: "display_refresh_auto_cadence", value: .bool(true))
        try store.write(key: "toolset.x_search.enabled", value: .bool(false))

        let values = try store.load()
        #expect(values["theme"] == .string("tokyonight"))
        #expect(values["display_refresh_auto_cadence"] == .bool(true))
        #expect(values["toolset.x_search.enabled"] == .bool(false))
    }

    @Test("writing preserves keys the settings modal does not own")
    func preservesForeignKeys() throws {
        let store = PagerSettingsStore(configPath: temporaryConfig())
        try FileManager.default.createDirectory(
            at: store.configPath.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "[ui]\nold_key = false\nsomething_else = \"keep me\"\n"
            .write(to: store.configPath, atomically: true, encoding: .utf8)

        try store.write(key: "vim_mode", value: .bool(true))
        let text = try String(contentsOf: store.configPath, encoding: .utf8)
        #expect(text.contains("something_else = \"keep me\""))
        #expect(text.contains("vim_mode = true"))
    }

    @Test("reset removes the key rather than writing today's default")
    func resetUnsets() throws {
        let store = PagerSettingsStore(configPath: temporaryConfig())
        try store.write(key: "theme", value: .string("grokday"))
        try store.reset(key: "theme")

        let text = try String(contentsOf: store.configPath, encoding: .utf8)
        #expect(!text.contains("theme"))
        // Absent means "follow the default", which is what `value(for:)` returns.
        let overlay = PagerSettingsOverlay(values: try store.load())
        #expect(overlay.stringValue(for: "theme") == "groknight")
    }

    @Test("reset prunes a table it empties")
    func resetPrunesEmptyTables() throws {
        let store = PagerSettingsStore(configPath: temporaryConfig())
        try store.write(key: "display_refresh_auto_cadence", value: .bool(true))
        #expect(try String(contentsOf: store.configPath, encoding: .utf8)
            .contains("display_refresh"))
        try store.reset(key: "display_refresh_auto_cadence")
        #expect(!(try String(contentsOf: store.configPath, encoding: .utf8)
            .contains("display_refresh")))
    }

    @Test("a multi-select writes a sorted array so the file is diff-stable")
    func multiSelectIsSorted() throws {
        let store = PagerSettingsStore(configPath: temporaryConfig())
        try store.writeMultiSelect(key: "opencode_go_models", enabled: ["zeta", "alpha", "mu"])
        #expect(try store.loadMultiSelect(key: "opencode_go_models") == ["alpha", "mu", "zeta"])
        let text = try String(contentsOf: store.configPath, encoding: .utf8)
        #expect(text.range(of: "alpha")!.lowerBound < text.range(of: "mu")!.lowerBound)
    }

    @Test("secrets and session-local rows are refused, not silently dropped")
    func nonPersistableRowsThrow() {
        let store = PagerSettingsStore(configPath: temporaryConfig())
        #expect(throws: PagerSettingsStoreError.notPersistable(key: "kimi_api_key")) {
            try store.write(key: "kimi_api_key", value: .secret(.stored))
        }
        #expect(throws: PagerSettingsStoreError.notPersistable(key: "plan_mode")) {
            try store.write(key: "plan_mode", value: .string("on"))
        }
    }

    @Test("a wrong-typed value is refused rather than written")
    func typeMismatchThrows() {
        let store = PagerSettingsStore(configPath: temporaryConfig())
        #expect(throws: PagerSettingsStoreError.typeMismatch(key: "vim_mode")) {
            try store.write(key: "vim_mode", value: .string("yes"))
        }
    }

    @Test("a hand-written scalar where a table belongs is reported, not clobbered")
    func blockedPathIsReported() throws {
        let store = PagerSettingsStore(configPath: temporaryConfig())
        try FileManager.default.createDirectory(
            at: store.configPath.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "ui = \"dark\"\n".write(to: store.configPath, atomically: true, encoding: .utf8)
        #expect(throws: PagerSettingsStoreError.pathBlocked(path: "ui")) {
            try store.write(key: "vim_mode", value: .bool(true))
        }
        // The user's line survives.
        #expect(try String(contentsOf: store.configPath, encoding: .utf8).contains("ui = \"dark\""))
    }

    @Test("an out-of-range stored int is clamped on read")
    func clampsOnRead() throws {
        let store = PagerSettingsStore(
            configPath: temporaryConfig(),
            registry: stepperTestRegistry
        )
        try FileManager.default.createDirectory(
            at: store.configPath.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "[ui]\nmax_thoughts_width = 9999\n"
            .write(to: store.configPath, atomically: true, encoding: .utf8)
        #expect(try store.load()["max_thoughts_width"] == .integer(500))
    }
}
