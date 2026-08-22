import Foundation
@testable import OpenGrokPager
import OpenGrokPagerCommandUI
import OpenGrokTerminalCore
import Testing

/// The focus model, the key table it splits, and the slash commands the
/// controller services itself.
///
/// These drive the real controller through its input stream rather than poking
/// at the editor, because the thing worth pinning is the routing: which region
/// a key reaches, and what it turns into on the way out.
@Suite("Pager focus model and command routing")
struct PagerFocusAndCommandTests {
    // MARK: - Focus

    @Test("Tab hands the keyboard to the scrollback and Tab hands it back")
    func tabTogglesFocus() async throws {
        let harness = try await Harness.run([
            .key(KeyEvent(key: .tab)),
            .key(KeyEvent(key: .tab)),
        ])

        #expect(await harness.focusChanges == [.scrollback, .prompt])
        #expect(await harness.controllerFocus == .prompt)
    }

    @Test("Tab accepts a completion instead of switching focus while the dropdown is open")
    func tabAcceptsCompletionBeforeFocus() async throws {
        let harness = try await Harness.run([
            .paste("/hel"),
            .key(KeyEvent(key: .tab)),
        ])

        // The dropdown was open on `/help`, so Tab committed it and left focus
        // exactly where it was.
        #expect(await harness.focusChanges.isEmpty)
        #expect(await harness.lastPromptText == "/help")
    }

    @Test("Enter completes an argument-required command into its argument phase instead of sending")
    func enterCompletesArgsRequiredCommand() async throws {
        // Upstream's `is_command_complete` gate: `/effort` requires a level,
        // so Enter on its dropdown row completes the draft to "/effort " and
        // stays in the argument phase rather than dispatching an incomplete
        // command (`app/agent_view/prompt.rs:186-274`).
        let harness = try await Harness.run([
            .paste("/eff"),
            .key(KeyEvent(key: .enter)),
        ])

        #expect(await harness.lastPromptText == "/effort ")
        #expect(await harness.turnPrompts.isEmpty)
        #expect(await harness.overlayRequests.isEmpty)
    }

    @Test("Enter on a complete command row accepts and sends on the same press")
    func enterSendsCompleteCommandRow() async throws {
        let harness = try await Harness.run([
            .paste("/hel"),
            .key(KeyEvent(key: .enter)),
        ])

        #expect(await harness.overlayRequests == [.help])
        #expect(await harness.lastPromptText == "")
    }

    @Test("the usage grammar pins exactly the argument-required builtins")
    func argumentRequiredBuiltinsArePinned() {
        // `requiresArguments` derives from the usage string's `<placeholder>`
        // markers; this pin makes a reworded usage that silently flips a
        // command's Enter behavior fail here instead of in someone's session.
        let required = OpenGrokPagerInteractiveController.builtinCommands
            .filter(\.requiresArguments)
            .map(\.name)
        #expect(Set(required) == Set(["effort", "rename", "btw", "recall", "flush"]))
    }

    @Test("the focused scrollback never leaks a keystroke to the composer")
    func scrollbackSwallowsTypedText() async throws {
        let harness = try await Harness.run([
            .key(KeyEvent(key: .tab)),
            .paste("this should not reach the composer"),
            .key(KeyEvent(key: .char("q"), character: "q")),
        ])

        #expect(await harness.lastPromptText == "")
        #expect(await harness.scrollbackCommands.isEmpty)
    }

    @Test("arrows, Enter and Ctrl+E work in the scrollback without vim mode")
    func scrollbackNonVimBindings() async throws {
        let harness = try await Harness.run([
            .key(KeyEvent(key: .tab)),
            .key(KeyEvent(key: .down)),
            .key(KeyEvent(key: .up)),
            .key(KeyEvent(key: .left)),
            .key(KeyEvent(key: .right)),
            .key(KeyEvent(key: .right, modifiers: [.shift])),
            .key(KeyEvent(key: .left, modifiers: [.shift])),
            .key(KeyEvent(key: .enter)),
            .key(KeyEvent(key: .char("e"), modifiers: [.control], character: "e")),
        ])

        #expect(await harness.scrollbackCommands == [
            .selectNext,
            .selectPrevious,
            .collapse,
            .expand,
            .nextTurn,
            .previousTurn,
            .openBlockViewer,
            .expandAllThinking,
        ])
    }

    @Test("bare-letter scrollback bindings are suppressed until vim mode is on")
    func vimModeGatesBareLetters() async throws {
        let off = try await Harness.run([
            .key(KeyEvent(key: .tab)),
            .key(KeyEvent(key: .char("j"), character: "j")),
            .key(KeyEvent(key: .char("y"), character: "y")),
        ])
        #expect(await off.scrollbackCommands.isEmpty)

        let on = try await Harness.run(
            [
                .key(KeyEvent(key: .tab)),
                .key(KeyEvent(key: .char("j"), character: "j")),
                .key(KeyEvent(key: .char("y"), character: "y")),
                .key(KeyEvent(key: .char("Y"), character: "Y")),
                .key(KeyEvent(key: .char("r"), character: "r")),
                .key(KeyEvent(key: .char("G"), character: "G")),
            ],
            modes: OpenGrokPagerInputModes(isVimMode: true)
        )
        #expect(await on.scrollbackCommands == [
            .selectNext,
            .copyBlockContent,
            .copyBlockMetadata,
            .toggleRaw,
            .selectLast,
        ])
    }

    @Test("i and Space leave the scrollback in vim mode, matching Tab")
    func vimExitKeys() async throws {
        let harness = try await Harness.run(
            [
                .key(KeyEvent(key: .tab)),
                .key(KeyEvent(key: .char("i"), character: "i")),
                .key(KeyEvent(key: .tab)),
                .key(KeyEvent(key: .char(" "), character: " ")),
            ],
            modes: OpenGrokPagerInputModes(isVimMode: true)
        )

        #expect(await harness.focusChanges == [.scrollback, .prompt, .scrollback, .prompt])
    }

    @Test("scrolling still reaches the viewport from the scrollback")
    func scrollbackViewportBindings() async throws {
        // Ctrl-K/U are `When::ScrollbackFocused` (`defaults.rs:192-226`).
        // Prompt-focused they are readline (Stage 3); after Tab they still page.
        let harness = try await Harness.run([
            .key(KeyEvent(key: .tab)),
            .key(KeyEvent(key: .pageUp)),
            .key(KeyEvent(key: .char("k"), modifiers: [.control], character: "k")),
            .key(KeyEvent(key: .char("u"), modifiers: [.control], character: "u")),
        ])

        #expect(await harness.viewportCommands == [.pageUp, .lineUp, .halfPageUp])
    }

    // MARK: - Multiline

    @Test("Shift+Enter inserts a newline and Enter still sends")
    func shiftEnterInsertsNewline() async throws {
        let harness = try await Harness.run([
            .paste("first"),
            .key(KeyEvent(key: .enter, modifiers: [.shift])),
            .paste("second"),
        ])

        #expect(await harness.lastPromptText == "first\nsecond")
        #expect(await harness.submittedPrompts.isEmpty)
    }

    @Test("multiline mode swaps what Enter and Shift+Enter do")
    func multilineSwapsEnter() async throws {
        let harness = try await Harness.run(
            [
                .paste("first"),
                .key(KeyEvent(key: .enter)),
                .paste("second"),
                .key(KeyEvent(key: .enter, modifiers: [.shift])),
            ],
            modes: OpenGrokPagerInputModes(isMultiline: true)
        )

        #expect(await harness.submittedPrompts == ["first\nsecond"])
    }

    @Test("a trailing backslash continues the line on terminals that cannot report Shift+Enter")
    func backslashContinuation() async throws {
        let harness = try await Harness.run([
            .paste("first\\"),
            .key(KeyEvent(key: .enter)),
            .paste("second"),
        ])

        // The backslash is consumed, not carried into the prompt.
        #expect(await harness.lastPromptText == "first\nsecond")
    }

    @Test("wrap host image paste creates one atomic image chip")
    func wrapHostImagePasteCreatesChip() async throws {
        let image = Data([0x89, 0x50, 0x4E, 0x47])
        let harness = try await Harness.run([
            .paste(encodeWrapImagePayload(data: image, mimeType: "image/png")),
        ])
        let prompt = await harness.lastPromptState

        #expect(prompt.text == "[Image #1]")
        #expect(prompt.pastedImages.count == 1)
        #expect(prompt.pastedImages[0].displayNumber == 1)
        #expect(prompt.pastedImages[0].mimeType == "image/png")
        #expect(prompt.pastedImages[0].encodedBytes == image)
    }

    @Test("malformed wrap host frames never become composer text")
    func malformedWrapHostFrameIsSwallowed() async throws {
        let harness = try await Harness.run([
            .paste("\(MAGIC_IMG)\nimage/png\n!!!notbase64!!!"),
        ])
        let prompt = await harness.lastPromptState

        #expect(prompt.text.isEmpty)
        #expect(prompt.pastedImages.isEmpty)
    }

    @Test("Ctrl+M toggles multiline and says which way it went")
    func ctrlMTogglesMultiline() async throws {
        let harness = try await Harness.run([
            .key(KeyEvent(key: .char("m"), modifiers: [.control], character: "m")),
        ])

        #expect(await harness.modeSnapshots.last?.isMultiline == true)
        #expect(await harness.notices.contains { $0.hasPrefix("Multiline on.") })
    }

    // MARK: - Global chords

    @Test("Ctrl+P moves an open dropdown and opens the palette when none is open")
    func ctrlPFallsThroughToPalette() async throws {
        // With a dropdown open it is a selection move — no palette.
        let moving = try await Harness.run([
            .paste("/"),
            .key(KeyEvent(key: .char("p"), modifiers: [.control], character: "p")),
        ])
        #expect(await moving.overlayRequests.isEmpty)

        // On an empty composer the same chord reaches `CommandPalette`.
        let opening = try await Harness.run([
            .key(KeyEvent(key: .char("p"), modifiers: [.control], character: "p")),
        ])
        let rows: [OpenGrokPagerCommandSuggestion]? = await opening.overlayRequests
            .compactMap { request in
                if case .commandPalette(let rows) = request { return rows }
                return nil
            }
            .first
        #expect(rows?.isEmpty == false)
        // A hidden command is resolvable but never listed.
        #expect(rows?.contains { $0.name == "/gboom" } == false)
    }

    @Test("Ctrl+N needs a second press before it replaces the session")
    func ctrlNConfirms() async throws {
        let single = try await Harness.run([
            .key(KeyEvent(key: .char("n"), modifiers: [.control], character: "n")),
        ])
        #expect(await single.notices.contains("started a new session") == false)

        let confirmed = try await Harness.run([
            .key(KeyEvent(key: .char("n"), modifiers: [.control], character: "n")),
            .key(KeyEvent(key: .char("n"), modifiers: [.control], character: "n")),
        ])
        #expect(await confirmed.notices.contains("started a new session") == false)
        #expect(await confirmed.sessionReplacements.count == 1)
    }

    @Test("Ctrl+. and Ctrl+X both open the shortcuts sheet")
    func shortcutsHelpChords() async throws {
        for character in ["." , "x"] {
            let harness = try await Harness.run([
                .key(KeyEvent(
                    key: .char(Character(character)),
                    modifiers: [.control],
                    character: Character(character)
                )),
            ])
            #expect(await harness.overlayRequests.contains(.shortcutsHelp))
        }
    }

    // MARK: - Slash commands

    @Test("every registered command dispatches to something other than 'unknown'")
    func noRegisteredCommandIsUnknown() async throws {
        for command in OpenGrokPagerInteractiveController.builtinCommands {
            // `/quit` and `/new` end or reset the run rather than emitting an
            // overlay, and are covered by their own tests.
            guard command.name != "quit" else { continue }
            let harness = try await Harness.run([
                .paste("/\(command.name)"),
                .key(KeyEvent(key: .enter)),
            ])
            let notices = await harness.notices
            #expect(
                notices.contains { $0.hasPrefix("unknown command") } == false,
                "/\(command.name) fell through to the unknown-command branch"
            )
        }
    }

    @Test("/history opens the overlay with the prompts already sent")
    func historyOverlayCarriesEntries() async throws {
        let harness = try await Harness.run([
            .paste("first prompt"),
            .key(KeyEvent(key: .enter)),
            .paste("/history"),
            .key(KeyEvent(key: .enter)),
        ])

        let entries = await harness.overlayRequests.compactMap { request -> [String]? in
            if case .promptHistory(let entries) = request { return entries }
            return nil
        }
        #expect(entries.first == ["first prompt"])
    }

    @Test("/queue reports the prompts waiting behind a running turn")
    func queueOverlayCarriesEntries() async throws {
        let session = HoldingSession(sessionID: "held")
        let harness = try await Harness.run(
            [
                .paste("opening"),
                .key(KeyEvent(key: .enter)),
                .paste("queued behind it"),
                .key(KeyEvent(key: .enter)),
                .paste("/queue"),
                .key(KeyEvent(key: .enter)),
            ],
            sessions: [session]
        )

        let entries = await harness.overlayRequests.compactMap { request -> [String]? in
            if case .promptQueue(let entries) = request { return entries }
            return nil
        }
        #expect(entries.first == ["queued behind it"])
    }

    @Test("/vim-mode publishes a mode snapshot both ways")
    func vimModeCommandTogglesBothWays() async throws {
        let harness = try await Harness.run([
            .paste("/vim-mode"),
            .key(KeyEvent(key: .enter)),
            .paste("/vim-mode"),
            .key(KeyEvent(key: .enter)),
        ])

        #expect(await harness.modeSnapshots.map(\.isVimMode) == [true, false])
    }

    @Test("/copy parses an index, a file, or both")
    func copyArgumentParsing() {
        #expect(OpenGrokPagerInteractiveController.parseCopyArguments([]).index == 1)
        #expect(OpenGrokPagerInteractiveController.parseCopyArguments([]).filePath == nil)

        let indexed = OpenGrokPagerInteractiveController.parseCopyArguments(["3"])
        #expect(indexed.index == 3)
        #expect(indexed.filePath == nil)

        let fileOnly = OpenGrokPagerInteractiveController.parseCopyArguments(["out.md"])
        #expect(fileOnly.index == 1)
        #expect(fileOnly.filePath == "out.md")

        let both = OpenGrokPagerInteractiveController.parseCopyArguments(["2", "out.md"])
        #expect(both.index == 2)
        #expect(both.filePath == "out.md")

        // A zero or negative count is not an index; it is a filename.
        #expect(OpenGrokPagerInteractiveController.parseCopyArguments(["0"]).index == 1)
    }

    @Test("hidden commands resolve but never appear in the dropdown")
    func hiddenCommandsAreNotSuggested() async throws {
        let registry = PagerCommandRegistry(
            commands: OpenGrokPagerInteractiveController.builtinCommands
        )
        #expect(registry.completions(for: "/gboom").isEmpty)
        if case .available = registry.resolve(PagerCommandInvocation(name: "gboom")) {
            // resolvable, as upstream's `visible() == false` commands are
        } else {
            Issue.record("/gboom should still resolve")
        }
    }

    @Test("bare gboom opens the hidden modal while arguments pass through")
    func gboomDispatchContract() async throws {
        let bare = try await Harness.run([
            .paste("/gboom"),
            .key(KeyEvent(key: .enter)),
        ])
        #expect(await bare.overlayRequests.contains(.easterEgg))
        #expect(bare.submittedPrompts.isEmpty)

        let withArguments = try await Harness.run([
            .paste("/gboom guide me"),
            .key(KeyEvent(key: .enter)),
        ], expectedTurns: 1)
        #expect(withArguments.submittedPrompts == ["/gboom guide me"])
        #expect(await withArguments.overlayRequests.contains(.easterEgg) == false)
    }

    /// `/q` ties `quit` and `queue` at the same fuzzy score; upstream's
    /// ranked dropdown settles ties by recency, then display order
    /// (`slash/mod.rs:996-1003`), so a cold `/q` offers `queue` first and a
    /// recently used `quit` overtakes it. The old port resolved this with an
    /// invented per-command `priority` knob; that was a divergence, removed
    /// with the move to the fuzzy pipeline.
    @Test("an ambiguous query resolves ties by recency, then display order")
    func ambiguousQueryTiebreaks() {
        let registry = PagerCommandRegistry(
            commands: OpenGrokPagerInteractiveController.builtinCommands
        )
        #expect(registry.completions(for: "/q").first?.commandName == "queue")
        #expect(
            registry.completions(for: "/q", recency: ["quit": 100])
                .first?.commandName == "quit"
        )
        // A fully typed name matches only itself.
        #expect(registry.completions(for: "/queue").first?.commandName == "queue")
        #expect(registry.completions(for: "/h").first?.commandName == "help")
    }

    @Test("registered summaries match the reference verbatim")
    func summariesMatchReference() {
        let byName = Dictionary(
            uniqueKeysWithValues: OpenGrokPagerInteractiveController.builtinCommands
                .map { ($0.name, $0.summary) }
        )
        #expect(byName["quit"] == "Quit the application")
        #expect(byName["new"] == "Start a new session")
        #expect(byName["home"] == "Return to the welcome screen")
        #expect(byName["history"] == "Search prompt history")
        #expect(byName["context"] == "View context usage")
        #expect(byName["find"] == "Search the conversation scrollback")
        #expect(byName["queue"] == "List the prompts queued behind the running turn")
        #expect(byName["export"] == "Export the current conversation to a file or clipboard")
        #expect(byName["copy"] == "Copy last response to clipboard or file (/copy [N] [file])")
        #expect(byName["multiline"] == "Toggle multiline input mode (swap Enter and Shift+Enter)")
        #expect(byName["session-info"] == "Show session info")
        #expect(byName["tutorial"] == "Quick tips to get the most out of Open Grok")
    }

    // MARK: - History-mutation safety

    /// The invariant this whole flag exists for.
    ///
    /// Dispatching slash commands inline mid-turn is what makes `/queue` and
    /// `/context` useful, but `/compact` rewrites the item list the sampler is
    /// streaming from. Upstream never has this problem because `/compact` alone
    /// returns `CommandResult::QueueCommand`; this port has to enforce it, so
    /// it gets a test rather than a comment.
    @Test("/compact cannot execute while a turn is in flight")
    func compactIsDeferredDuringATurn() async throws {
        let held = HoldingSession(sessionID: "streaming")
        let harness = try await Harness.run(
            [
                .paste("write me a function"),
                .key(KeyEvent(key: .enter)),
                .paste("/compact"),
                .key(KeyEvent(key: .enter)),
            ],
            sessions: [held]
        )

        // It did NOT run: no compact overlay request was emitted while the turn
        // was open.
        let compactRequests = await harness.overlayRequests.filter { request in
            if case .compact = request { return true }
            return false
        }
        #expect(compactRequests.isEmpty, "/compact executed mid-turn")

        // It was deferred rather than dropped, and the user was told why.
        #expect(await harness.notices.contains { $0.contains("will run when this turn finishes") })
    }

    @Test("a UI-only command still runs mid-turn")
    func uiCommandsStillDispatchDuringATurn() async throws {
        let held = HoldingSession(sessionID: "streaming")
        let harness = try await Harness.run(
            [
                .paste("do a thing"),
                .key(KeyEvent(key: .enter)),
                .paste("/context"),
                .key(KeyEvent(key: .enter)),
            ],
            sessions: [held]
        )

        // The whole point of inline dispatch — this must not have regressed
        // while closing the /compact hole.
        #expect(await harness.overlayRequests.contains(.contextUsage))
    }

    /// The flag is a whitelist, not a description: anything that rewrites the
    /// item list a streaming sampler is reading from has to carry it, and this
    /// pins the membership so a new command cannot join silently. `/rewind`
    /// earns it for the same reason `/compact` does — a forced rewind truncates
    /// history and restores files underneath the running turn — and `/resume`
    /// because swapping in a stored session replaces the whole conversation,
    /// the same deferral `/new` takes.
    @Test("only history-mutating commands carry the deferral flag")
    func onlyCompactMutatesHistory() {
        let mutating = OpenGrokPagerInteractiveController.builtinCommands
            .filter(\.mutatesConversationHistory)
            .map(\.name)
            .sorted()
        #expect(mutating == ["compact", "new", "resume", "rewind"])
    }

    @Test("/rewind cannot execute while a turn is in flight")
    func rewindIsDeferredDuringATurn() async throws {
        let held = HoldingSession(sessionID: "streaming")
        let harness = try await Harness.run(
            [
                .paste("edit some files"),
                .key(KeyEvent(key: .enter)),
                .paste("/rewind 2 --force"),
                .key(KeyEvent(key: .enter)),
            ],
            sessions: [held]
        )
        let rewinds = await harness.overlayRequests.filter { request in
            if case .rewind = request { return true }
            return false
        }
        #expect(rewinds.isEmpty, "/rewind executed mid-turn")
        #expect(await harness.notices.contains { $0.contains("will run when this turn finishes") })
    }

    // MARK: - Session-scoped commands

    @Test("/rewind carries its whole argument string through untouched")
    func rewindCarriesItsArgument() async throws {
        let harness = try await Harness.run([
            .paste("/rewind 3 --mode=files --force"),
            .key(KeyEvent(key: .enter)),
        ])
        #expect(await harness.overlayRequests
            .contains(.rewind(argument: "3 --mode=files --force")))
    }

    @Test("/undo is /rewind")
    func undoAliasesRewind() async throws {
        let harness = try await Harness.run([
            .paste("/undo"),
            .key(KeyEvent(key: .enter)),
        ])
        #expect(await harness.overlayRequests.contains(.rewind(argument: "")))
    }

    /// Deleting a transcript is not undoable, so the command itself must never
    /// carry the confirmed form — only the modal's own row does. If this ever
    /// flipped, `/delete` would erase a session on one keystroke.
    @Test("/delete asks before it deletes")
    func deleteAsksFirst() async throws {
        let harness = try await Harness.run([
            .paste("/delete"),
            .key(KeyEvent(key: .enter)),
        ])
        #expect(await harness.overlayRequests.contains(.deleteSession(confirmed: false)))
        #expect(await harness.overlayRequests.contains(.deleteSession(confirmed: true)) == false)
    }

    @Test("/jump asks for the turn picker")
    func jumpOpensThePicker() async throws {
        let harness = try await Harness.run([
            .paste("/jump"),
            .key(KeyEvent(key: .enter)),
        ])
        #expect(await harness.overlayRequests.contains(.jumpPicker))
    }

    @Test("the memory and goal commands carry their prose argument whole")
    func memoryCommandsCarryProse() async throws {
        let harness = try await Harness.run([
            .paste("/remember this project pins swift 6.1"),
            .key(KeyEvent(key: .enter)),
            .paste("/recall swift version"),
            .key(KeyEvent(key: .enter)),
            .paste("/flush wrapped up the parser work"),
            .key(KeyEvent(key: .enter)),
            .paste("/goal finish the port"),
            .key(KeyEvent(key: .enter)),
        ])
        let requests = await harness.overlayRequests
        #expect(requests.contains(.remember(text: "this project pins swift 6.1")))
        #expect(requests.contains(.recall(query: "swift version")))
        #expect(requests.contains(.flush(text: "wrapped up the parser work")))
        #expect(requests.contains(.goal(argument: "finish the port")))
    }

    // MARK: - Command palette

    /// The palette used to be display-only because the renderer had no way to
    /// hand a picked command back. `.runCommand` is that way, and this asserts
    /// the round trip actually *runs* the command rather than describing it —
    /// which was the whole failure mode.
    @Test("a command-palette row runs its command and leaves the draft alone")
    func paletteRowRunsItsCommand() async throws {
        let harness = try await Harness.run(
            [
                .paste("half-written prompt"),
                .key(KeyEvent(key: .f(1))),
            ],
            stagedCommand: "/context"
        )
        #expect(await harness.overlayRequests.contains(.contextUsage))
        // "Preserving draft": nothing the palette did touched the composer.
        #expect(await harness.lastPromptText == "half-written prompt")
    }

    @Test("a palette row naming a history-mutating command is deferred too")
    func paletteRespectsTheMidTurnGate() async throws {
        let held = HoldingSession(sessionID: "streaming")
        let harness = try await Harness.run(
            [
                .paste("start something"),
                .key(KeyEvent(key: .enter)),
                .key(KeyEvent(key: .f(1))),
            ],
            sessions: [held],
            stagedCommand: "/compact"
        )
        let compacts = await harness.overlayRequests.filter { request in
            if case .compact = request { return true }
            return false
        }
        #expect(compacts.isEmpty, "the palette bypassed the mid-turn deferral")
        #expect(await harness.notices.contains { $0.contains("will run when this turn finishes") })
    }

    // MARK: - Settings, privacy and theme

    @Test("/settings, /privacy and F2 all reach the settings modal")
    func settingsEntryPoints() async throws {
        let viaCommand = try await Harness.run([
            .paste("/settings"),
            .key(KeyEvent(key: .enter)),
        ])
        #expect(await viaCommand.overlayRequests.contains(.settings(deepLinkKey: nil)))

        // `/privacy` is the same modal aimed at one row.
        let viaPrivacy = try await Harness.run([
            .paste("/privacy"),
            .key(KeyEvent(key: .enter)),
        ])
        #expect(await viaPrivacy.overlayRequests.contains(
            .settings(deepLinkKey: "coding_data_sharing")
        ))

        let viaKey = try await Harness.run([
            .key(KeyEvent(key: .f(2))),
        ])
        #expect(await viaKey.overlayRequests.contains(.settings(deepLinkKey: nil)))
    }

    @Test("/theme carries a typed name through and opens the picker without one")
    func themeCommandCarriesItsArgument() async throws {
        let bare = try await Harness.run([
            .paste("/theme"),
            .key(KeyEvent(key: .enter)),
        ])
        #expect(await bare.overlayRequests.contains(.themePicker(query: nil)))

        let named = try await Harness.run([
            .paste("/theme tokyonight"),
            .key(KeyEvent(key: .enter)),
        ])
        #expect(await named.overlayRequests.contains(.themePicker(query: "tokyonight")))
    }

    @Test("the settings aliases all resolve")
    func settingsAliases() {
        let registry = PagerCommandRegistry(
            commands: OpenGrokPagerInteractiveController.builtinCommands
        )
        for alias in ["settings", "config", "preferences", "prefs"] {
            guard case .available(let command) = registry.resolve(
                PagerCommandInvocation(name: alias)
            ) else {
                Issue.record("/\(alias) did not resolve")
                continue
            }
            #expect(command.name == "settings")
        }
        guard case .available(let theme) = registry.resolve(
            PagerCommandInvocation(name: "t")
        ) else {
            Issue.record("/t did not resolve")
            return
        }
        #expect(theme.name == "theme")
    }

    // MARK: - Queue and interjection

    @Test("combine_queued_prompts runs the whole backlog as one turn")
    func combineQueuedPrompts() async throws {
        let held = HoldingSession(sessionID: "held")
        let harness = try await Harness.run(
            [
                .paste("opening"),
                .key(KeyEvent(key: .enter)),
                .paste("second"),
                .key(KeyEvent(key: .enter)),
                .paste("third"),
                .key(KeyEvent(key: .enter)),
            ],
            sessions: [held],
            modes: OpenGrokPagerInputModes(combineQueuedPrompts: true),
            releaseAfterQueueReaches: 2,
            expectedTurns: 2
        )

        // `second` and `third` went in one prompt rather than two turns.
        #expect(await harness.turnPrompts.contains("second\n\nthird"))
    }

    @Test("enter_steers cancels the turn and runs the draft before queued follow-ups")
    func enterSteersSendsNow() async throws {
        let held = HoldingSession(sessionID: "held")
        let harness = try await Harness.run(
            [
                .paste("opening"),
                .key(KeyEvent(key: .enter)),
                .paste("/defer"),
                .key(KeyEvent(key: .enter)),
                .paste("send this now"),
                .key(KeyEvent(key: .enter)),
            ],
            sessions: [held],
            modes: OpenGrokPagerInputModes(enterSteers: true),
            expectedTurns: 3,
            generatedPrompt: "already queued"
        )

        #expect(await held.cancellationCount() == 1)
        #expect(await harness.turnPrompts == [
            "opening",
            "send this now",
            "already queued",
        ])
        #expect(await harness.notices.contains("sending the queued prompt now"))
    }

    @Test("with enter_steers off, mid-turn drafts stay in tail order")
    func enterSteersOffQueuesAtTail() async throws {
        let held = HoldingSession(sessionID: "held")
        let harness = try await Harness.run(
            [
                .paste("opening"),
                .key(KeyEvent(key: .enter)),
                .paste("first follow-up"),
                .key(KeyEvent(key: .enter)),
                .paste("second follow-up"),
                .key(KeyEvent(key: .enter)),
            ],
            sessions: [held],
            releaseAfterQueueReaches: 2,
            expectedTurns: 3
        )

        #expect(await held.cancellationCount() == 0)
        #expect(await harness.turnPrompts == [
            "opening",
            "first follow-up",
            "second follow-up",
        ])
    }
}

// MARK: - Harness

/// One controller run, with everything the assertions need collected off the
/// renderer.
private actor Harness {
    private let renderer: FocusRecordingRenderer
    private let runtime: FocusTestRuntime
    let controllerFocus: OpenGrokPagerFocusRegion
    let submittedPrompts: [String]

    private init(
        renderer: FocusRecordingRenderer,
        runtime: FocusTestRuntime,
        controllerFocus: OpenGrokPagerFocusRegion,
        submittedPrompts: [String]
    ) {
        self.renderer = renderer
        self.runtime = runtime
        self.controllerFocus = controllerFocus
        self.submittedPrompts = submittedPrompts
    }

    var focusChanges: [OpenGrokPagerFocusRegion] { get async { await renderer.focusChanges } }
    var scrollbackCommands: [OpenGrokPagerScrollbackCommand] {
        get async { await renderer.scrollbackCommands }
    }
    var viewportCommands: [OpenGrokPagerViewportCommand] {
        get async { await renderer.viewportCommands }
    }
    var overlayRequests: [OpenGrokPagerOverlayRequest] {
        get async { await renderer.overlayRequests }
    }
    var modeSnapshots: [OpenGrokPagerInputModes] { get async { await renderer.modeSnapshots } }
    var notices: [String] { get async { await renderer.notices } }
    var sessionReplacements: [String] { get async { await renderer.sessionReplacements } }
    var lastPromptText: String { get async { await renderer.lastPromptText } }
    var lastPromptState: OpenGrokPagerInteractivePromptState {
        get async { await renderer.lastPromptState }
    }
    var turnPrompts: [String] { get async { await runtime.requests.map(\.prompt) } }

    static func run(
        _ events: [InputEvent],
        sessions: [HoldingSession] = [],
        modes: OpenGrokPagerInputModes = OpenGrokPagerInputModes(),
        releaseAfterQueueReaches: Int? = nil,
        expectedTurns: Int? = nil,
        stagedCommand: String? = nil,
        generatedPrompt: String? = nil
    ) async throws -> Harness {
        let renderer = FocusRecordingRenderer()
        if let stagedCommand { await renderer.stageCommand(stagedCommand) }
        let runtime = FocusTestRuntime(held: sessions)
        let customCommands = generatedPrompt == nil
            ? []
            : [OpenGrokPagerCommandRegistration(
                name: "defer",
                summary: "Queue a generated test prompt"
            )]
        let customCommandHandler: OpenGrokPagerInteractiveController.CustomCommandHandler?
        if let generatedPrompt {
            customCommandHandler = { @Sendable _ in generatedPrompt }
        } else {
            customCommandHandler = nil
        }
        // A test that waits for a *later* turn cannot let the input stream
        // finish: exhaustion ends the run from inside the turn loop, which
        // would race the drain it is trying to observe. Those tests keep the
        // stream open and shut the controller down once the turn has landed.
        // A finite script with an intentionally endless held session needs an
        // explicit Ctrl+D: natural EOF preserves queued prompts and waits for
        // the current turn, which this fixture would otherwise never finish.
        let scriptedEvents = !sessions.isEmpty && expectedTurns == nil
            ? events + [.key(KeyEvent(key: .char("d"), modifiers: [.control], character: "d"))]
            : events
        let controller = OpenGrokPagerInteractiveController(
            input: expectedTurns == nil ? makeStream(scriptedEvents) : makeOpenStream(scriptedEvents),
            runtime: runtime,
            renderer: renderer,
            output: SilentOutput(),
            customCommands: customCommands,
            customCommandHandler: customCommandHandler
        )
        await controller.setInputModes(modes)

        // A held session needs releasing only when the test wants the turn to
        // finish on its own; otherwise the explicit EOF above ends the run,
        // and releasing early would race the very thing under test.
        let releaser: Task<Void, Never>? = releaseAfterQueueReaches.map { threshold in
            Task {
                await renderer.waitForQueueCount(atLeast: threshold)
                for session in sessions { session.finish() }
            }
        }
        let stopper: Task<Void, Never>? = expectedTurns.map { turns in
            Task {
                await runtime.waitForRequestCount(atLeast: turns)
                await controller.shutdown()
            }
        }

        let result = try await controller.run(.init(prompt: "", mode: .inline))
        releaser?.cancel()
        stopper?.cancel()
        let state = await controller.state()
        return Harness(
            renderer: renderer,
            runtime: runtime,
            controllerFocus: state.focus,
            submittedPrompts: result.submittedPrompts
        )
    }
}

private actor FocusRecordingRenderer: OpenGrokPagerInteractiveRenderAdapter {
    private var events: [OpenGrokPagerInteractiveEvent] = []
    private var queueWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var highestQueueCount = 0

    /// Stands in for a selected command-palette row: the next input event the
    /// renderer sees resolves to this command instead of falling through to the
    /// composer, which is exactly what `select(overlayID:rowID:)` does in the
    /// live renderer.
    private var stagedCommand: String?

    func begin() {}
    func restoreTerminal() {}

    func stageCommand(_ text: String) { stagedCommand = text }

    /// Only `F1` stands in for the palette selection. Claiming every event
    /// would swallow the composer input the same tests type, which is the
    /// behaviour the live renderer has too: it consumes a key only when an
    /// overlay is actually up.
    func handleInput(_ event: InputEvent) async throws -> OpenGrokPagerInputRouting {
        guard case .key(let key) = event, key.key == .f(1) else { return .notHandled }
        guard let staged = stagedCommand else { return .notHandled }
        stagedCommand = nil
        return .runCommand(staged)
    }

    func render(_ event: OpenGrokPagerInteractiveEvent) {
        events.append(event)
        if case .queueChanged(let count) = event {
            highestQueueCount = max(highestQueueCount, count)
            let ready = queueWaiters.filter { $0.0 <= highestQueueCount }
            queueWaiters.removeAll { $0.0 <= highestQueueCount }
            for waiter in ready { waiter.1.resume() }
        }
    }

    /// Suspends until the queue has reached `count`, so a test can hold a turn
    /// open exactly long enough to type behind it.
    func waitForQueueCount(atLeast count: Int) async {
        guard count > 0 else { return }
        guard highestQueueCount < count else { return }
        await withCheckedContinuation { queueWaiters.append((count, $0)) }
    }

    var focusChanges: [OpenGrokPagerFocusRegion] {
        events.compactMap { if case .focusChanged(let region) = $0 { return region } else { return nil } }
    }

    var scrollbackCommands: [OpenGrokPagerScrollbackCommand] {
        events.compactMap { if case .scrollback(let command) = $0 { return command } else { return nil } }
    }

    var viewportCommands: [OpenGrokPagerViewportCommand] {
        events.compactMap { if case .viewport(let command) = $0 { return command } else { return nil } }
    }

    var overlayRequests: [OpenGrokPagerOverlayRequest] {
        events.compactMap { if case .overlay(let request) = $0 { return request } else { return nil } }
    }

    var modeSnapshots: [OpenGrokPagerInputModes] {
        events.compactMap { if case .modeChanged(let modes) = $0 { return modes } else { return nil } }
    }

    var notices: [String] {
        events.compactMap { if case .notice(let message) = $0 { return message } else { return nil } }
    }

    var sessionReplacements: [String] {
        events.compactMap {
            if case .sessionReplaced(let sessionID) = $0 { return sessionID }
            return nil
        }
    }

    var lastPromptText: String {
        events.reversed().compactMap {
            if case .promptChanged(let state) = $0 { return state.text } else { return nil }
        }.first ?? ""
    }

    var lastPromptState: OpenGrokPagerInteractivePromptState {
        events.reversed().compactMap {
            if case .promptChanged(let state) = $0 { return state }
            return nil
        }.first ?? OpenGrokPagerInteractivePromptState()
    }
}

private struct SilentOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws { _ = event }
}

/// A session that stays open until the test finishes it, so prompts typed
/// behind it land in the queue rather than starting their own turn.
private final class HoldingSession: OpenGrokPagerSessionAdapter, @unchecked Sendable {
    let sessionID: String?
    let events: AsyncThrowingStream<OpenGrokPagerEvent, Error>
    private let continuation: AsyncThrowingStream<OpenGrokPagerEvent, Error>.Continuation
    private let cancellationRecorder = CancellationRecorder()

    init(sessionID: String) {
        self.sessionID = sessionID
        var captured: AsyncThrowingStream<OpenGrokPagerEvent, Error>.Continuation!
        events = AsyncThrowingStream { captured = $0 }
        continuation = captured
    }

    func finish() {
        continuation.yield(.completed(.init(sessionID: sessionID)))
        continuation.finish()
    }

    func cancel() async {
        await cancellationRecorder.record()
        continuation.yield(.cancelled)
        continuation.finish()
    }

    func cancellationCount() async -> Int {
        await cancellationRecorder.count
    }

    func close() async {
        continuation.finish()
    }
}

private actor CancellationRecorder {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

private actor FocusTestRuntime: OpenGrokPagerRuntimeAdapter {
    private(set) var requests: [OpenGrokPagerRequest] = []
    private var held: [HoldingSession]

    init(held: [HoldingSession]) {
        self.held = held
    }

    private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    /// Suspends until `makeSession` has been called `count` times.
    func waitForRequestCount(atLeast count: Int) async {
        guard requests.count < count else { return }
        await withCheckedContinuation { requestWaiters.append((count, $0)) }
    }

    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        requests.append(request)
        let ready = requestWaiters.filter { $0.0 <= requests.count }
        requestWaiters.removeAll { $0.0 <= requests.count }
        for waiter in ready { waiter.1.resume() }
        if !held.isEmpty {
            return held.removeFirst()
        }
        // Everything after the held sessions completes immediately, so a drain
        // finishes instead of hanging.
        let session = HoldingSession(sessionID: request.sessionID ?? "auto")
        session.finish()
        return session
    }

    func replaceSession(from request: OpenGrokPagerRequest) async throws -> String {
        _ = request
        return "replacement-\(UUID().uuidString)"
    }
}

/// Yields `events` and then stays open, so only an explicit shutdown ends the
/// run.
private func makeOpenStream(_ events: [InputEvent]) -> AsyncStream<InputEvent> {
    AsyncStream { continuation in
        for event in events { continuation.yield(event) }
    }
}

private func makeStream(_ events: [InputEvent]) -> AsyncStream<InputEvent> {
    AsyncStream { continuation in
        for event in events { continuation.yield(event) }
        continuation.finish()
    }
}
