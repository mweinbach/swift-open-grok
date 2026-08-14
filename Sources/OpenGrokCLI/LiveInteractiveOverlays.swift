import Foundation
import OpenGrokAgentCoordinator
import OpenGrokAgentDefinitions
import OpenGrokACPRuntime
import OpenGrokAuth
import OpenGrokCodeMode
import OpenGrokCompaction
import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokDiagnostics
import OpenGrokFileTools
import OpenGrokFastWorktree
import OpenGrokHTTP
import OpenGrokHooks
import OpenGrokHooksPluginTypes
import OpenGrokHunkTracker
import OpenGrokInterjection
import OpenGrokLSP
import OpenGrokModels
import OpenGrokPager
import OpenGrokPagerCommandUI
import OpenGrokPagerMinimal
import OpenGrokPagerRender
import OpenGrokTokenEstimation
import OpenGrokProviderSession
import OpenGrokSampler
import OpenGrokSamplingTypes
import OpenGrokSandbox
import OpenGrokScheduler
import OpenGrokSessionRuntime
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase
import OpenGrokShellSessionSupport
import OpenGrokSubagentResolution
import OpenGrokTerminalCore
import OpenGrokTextArea
import OpenGrokToolRegistry
import OpenGrokToolTypes
import OpenGrokToolsAPI
import OpenGrokTTY
import OpenGrokVersion
import OpenGrokVoice
import OpenGrokWebMediaTools
import OpenGrokWorkspace

extension LiveInteractiveControllerRenderer {

    func dashboardRowLabelsForTesting() -> [String: String] {
        guard let overlay = overlays.overlays.first(
                  where: { $0.id == LiveDashboardOverlay.overlayID }
              ),
              case .list(let list) = overlay.content
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: list.rows.map { ($0.id, $0.label) })
    }

    var dashboardStore: PagerDashboardStore {
        PagerDashboardStore(
            configPath: openGrokHome.appendingPathComponent("config.toml")
        )
    }

    func registerSessionTab(_ id: String) {
        guard !id.isEmpty, !sessionTabs.contains(where: { $0.sessionID == id }) else {
            touchSessionTab(id)
            return
        }
        let rosterEntry = leaderRoster.first { $0.sessionId == id }
        let rosterTitle = rosterEntry?.title.flatMap { title -> String? in
            let line = LivePagerTasksBlock.firstNonEmptyLine(title)
            return line.isEmpty ? nil : line
        }
        sessionTabs.append(LiveSessionTab(
            sessionID: id,
            title: rosterTitle ?? "New session",
            lastActivity: rosterEntry.map {
                Date(timeIntervalSince1970: TimeInterval($0.lastChangeUnixMs) / 1_000)
            } ?? Date(),
            cwd: rosterEntry?.cwd ?? workingDirectory
        ))
    }

    func applyLeaderRosterEvent(_ event: LiveLeaderRosterEvent) {
        switch event {
        case .snapshot(let sessions), .changed(let sessions, _):
            leaderRoster = sessions
        }
        for entry in leaderRoster {
            guard let index = sessionTabs.firstIndex(where: { $0.sessionID == entry.sessionId }) else {
                continue
            }
            if let title = entry.title {
                let line = LivePagerTasksBlock.firstNonEmptyLine(title)
                if !line.isEmpty { sessionTabs[index].title = line }
            }
            sessionTabs[index].cwd = entry.cwd
            sessionTabs[index].lastActivity = Date(
                timeIntervalSince1970: TimeInterval(entry.lastChangeUnixMs) / 1_000
            )
            if entry.sessionId == sessionID, let modelID = entry.modelId {
                modelName = modelID
            }
        }
        guard overlays.contains(id: LiveDashboardOverlay.overlayID) else { return }
        let candidates = dashboardCandidateRowIDs()
        dashboardState.gcStaleRefs { candidates.contains($0) }
        if let armedCloseSessionID,
           !candidates.contains(where: { $0.owningSessionID == armedCloseSessionID }) {
            self.armedCloseSessionID = nil
        }
        rebuildDashboardRows()
        try? renderState()
    }

    func reportLeaderRosterFailure(_ message: String) {
        note("Leader roster unavailable: \(message)")
        try? renderState()
    }

    /// Stamp activity (and adopt the first user prompt as the roster title —
    /// upstream titles rows the same way, `dashboard/row.rs` first-prompt
    /// labels).
    func touchSessionTab(_ id: String, title: String? = nil) {
        guard let index = sessionTabs.firstIndex(where: { $0.sessionID == id }) else { return }
        sessionTabs[index].lastActivity = Date()
        if let title, sessionTabs[index].title == "New session" {
            sessionTabs[index].title = LivePagerTasksBlock.firstNonEmptyLine(title)
        }
    }

    /// `/dashboard` / Ctrl+\ — the roster overlay. The feature gate is
    /// upstream's `dashboard_enabled` (`dashboard/mod.rs:88-100`): the
    /// `GROK_AGENT_DASHBOARD=0` env kill-switch WINS, then the persisted
    /// `[dashboard].enabled`, then the enabled default. The minimal refusal
    /// lives with the controller's dispatch, the ModeSupport seam.
    func presentDashboard() async throws {
        guard environment["GROK_AGENT_DASHBOARD"] != "0" else {
            note("The Agent Dashboard is disabled (GROK_AGENT_DASHBOARD=0).")
            try renderState()
            return
        }
        guard dashboardStore.loadEnabled() != false else {
            note("The Agent Dashboard is disabled ([dashboard].enabled = false in config.toml).")
            try renderState()
            return
        }
        registerSessionTab(sessionID)
        var subagents: [LiveSubagentSnapshot] = []
        if let host = toolExecutor?.subagentHost {
            for id in await host.knownSubagentIDs() {
                if let snapshot = await host.subagentSnapshot(id: id) {
                    subagents.append(snapshot)
                }
            }
        }
        // ONE local-catalog pass for the modal's whole lifetime. Leader roster
        // state is push-driven separately and rebuilds the open rows on every
        // typed delta; there is no per-arrow file read or roster polling.
        let catalogRecords = (try? sessionCatalog?.records()) ?? nil
        dashboardPeekCache = LiveDashboardPeekCache.build(from: catalogRecords ?? [])
        dashboardSubagents = subagents
        dashboardDormant = (try? sessionCatalog?.list()) ?? []
        armedCloseSessionID = nil
        dashboardSearchQuery = nil
        // Fresh per-open state, then the persisted grouping/pins/reorder
        // resolved against what exists RIGHT NOW and gc'd — `gc_stale_refs`
        // on open (state.rs:1736-1780).
        dashboardState = PagerDashboardState()
        dashboardState.home = environment["HOME"]
        let persisted = dashboardStore.load()
        dashboardPersistedEnabled = persisted?.enabled ?? true
        let candidates = dashboardCandidateRowIDs()
        if let persisted {
            dashboardState.apply(persisted, resolvingAgainst: candidates)
        }
        dashboardState.gcStaleRefs { candidates.contains($0) }
        overlays.push(buildDashboardOverlay())
        refreshDashboardPeek()
        try renderState()
    }

    /// The dashboard's scoped key table (`state.rs:3533-3540`,
    /// `dispatch/dashboard.rs:2329-2367`, `defaults.rs:997-1017`), consulted
    /// while the roster is the FOCUSED overlay. Returns nil to fall through
    /// to the generic overlay routing (arrows, Enter, x, Esc-dismiss).
    ///
    /// Search mode (Ctrl+/, arriving as the raw 0x1F byte) owns every key
    /// while live: chars/backspace live-reparse the filter grammar, Enter
    /// confirms KEEPING the filter, Esc or a second Ctrl+/ cancels clearing
    /// it. Outside search: Ctrl+T pins, Shift+↑/↓ reorder, Left/Right
    /// collapse a focused header (Enter rides the select arm), and Esc with
    /// an active filter clears the filter FIRST instead of dismissing
    /// (`esc_clears_active_filter`, state.rs:7347).
    func handleDashboardChord(_ event: KeyEvent) async throws -> OpenGrokPagerInputRouting? {
        guard overlays.focused?.id == LiveDashboardOverlay.overlayID else { return nil }
        if var query = dashboardSearchQuery {
            switch event.key {
            case .enter:
                dashboardSearchQuery = nil
                dashboardState.searchActive = false
            case .escape:
                dashboardSearchQuery = nil
                dashboardState.searchActive = false
                dashboardState.filter = .none
            case .backspace:
                if !query.isEmpty { query.removeLast() }
                dashboardSearchQuery = query
                dashboardState.filter = .from(PagerDashboardFilter.parse(query))
            case .char(let character)
                where event.modifiers.contains(.control) && Self.isSearchChordCharacter(character):
                dashboardSearchQuery = nil
                dashboardState.searchActive = false
                dashboardState.filter = .none
            case .char(let character)
                where event.modifiers.subtracting(.shift).isEmpty && !character.isNewline:
                query.append(character)
                dashboardSearchQuery = query
                dashboardState.filter = .from(PagerDashboardFilter.parse(query))
            default:
                break
            }
            rebuildDashboardRows()
            try renderState()
            return .consumed
        }
        if let question = dashboardPeekQuestion,
           selectedDashboardListRowID() == LiveDashboardOverlay.attachPrefix + sessionID,
           let routing = try await handleDashboardQuestionChord(event, question: question) {
            return routing
        }
        if let mode = dashboardInputMode {
            if event.key == .char("w"), event.modifiers.contains(.control),
               case .compose(let rowID) = mode,
               rowID == LiveDashboardOverlay.newAgentRowID {
                toggleDashboardWorktree()
                rebuildDashboardRows()
                try renderState()
                return .consumed
            }
            switch event.key {
            case .escape:
                if case .worktree(let prompt) = mode {
                    dashboardInputMode = .compose(rowID: LiveDashboardOverlay.newAgentRowID)
                    dashboardInputText = prompt
                } else {
                    dashboardInputMode = nil
                    dashboardInputText = ""
                }
                rebuildDashboardRows()
                try renderState()
                return .consumed
            case .backspace:
                if !dashboardInputText.isEmpty { dashboardInputText.removeLast() }
            case .enter:
                return try await commitDashboardInput(mode)
            case .char(let character)
                where event.modifiers.subtracting(.shift).isEmpty && !character.isNewline:
                dashboardInputText.append(character)
            default:
                return .consumed
            }
            rebuildDashboardRows()
            try renderState()
            return .consumed
        }
        switch event.key {
        case .char(let character) where event.modifiers.contains(.control):
            if Self.isSearchChordCharacter(character) {
                // `enter_search_mode` clears the previous filter
                // (state.rs:3533-3540).
                dashboardSearchQuery = ""
                dashboardState.searchActive = true
                dashboardState.filter = .none
                rebuildDashboardRows()
                try renderState()
                return .consumed
            }
            if String(character).lowercased() == "t" {
                if let target = selectedDashboardRowID() {
                    dashboardState.togglePin(target)
                    rebuildDashboardRows()
                    persistDashboardState()
                    try renderState()
                }
                return .consumed
            }
            if String(character).lowercased() == "r" {
                guard let rowID = selectedDashboardListRowID(),
                      rowID.hasPrefix(LiveDashboardOverlay.attachPrefix)
                else {
                    note("Only top-level session rows can be renamed.")
                    try renderState()
                    return .consumed
                }
                dashboardInputMode = .rename(rowID: rowID)
                dashboardInputText = ""
                rebuildDashboardRows()
                try renderState()
                return .consumed
            }
            if String(character).lowercased() == "x" {
                guard let rowID = selectedDashboardListRowID(),
                      rowID.hasPrefix(LiveDashboardOverlay.attachPrefix)
                else { return .consumed }
                await handleDashboardClose(
                    rowID: LiveDashboardOverlay.closePrefix + ":" + rowID
                )
                return .consumed
            }
            if String(character).lowercased() == "l" {
                presentDashboardLocationPicker()
                try renderState()
                return .consumed
            }
            if String(character).lowercased() == "w" {
                toggleDashboardWorktree()
                rebuildDashboardRows()
                try renderState()
                return .consumed
            }
            return nil
        case .up where event.modifiers.contains(.shift),
             .down where event.modifiers.contains(.shift):
            if let target = selectedDashboardRowID() {
                dashboardState.reorderRow(target, up: event.key == .up)
                rebuildDashboardRows()
                persistDashboardState()
                try renderState()
            }
            return .consumed
        case .left, .right:
            guard let key = selectedDashboardSectionKey() else { return nil }
            dashboardState.toggleSection(key)
            rebuildDashboardRows()
            try renderState()
            return .consumed
        case .escape:
            guard dashboardState.filter.isActive else { return nil }
            dashboardState.filter = .none
            rebuildDashboardRows()
            try renderState()
            return .consumed
        case .char(let character)
            where event.modifiers.subtracting(.shift).isEmpty && !character.isNewline:
            guard let rowID = selectedDashboardListRowID() else { return .consumed }
            dashboardInputMode = .compose(rowID: rowID)
            dashboardInputText = String(character)
            rebuildDashboardRows()
            try renderState()
            return .consumed
        default:
            return nil
        }
    }

    func commitDashboardInput(
        _ mode: LiveDashboardInputMode
    ) async throws -> OpenGrokPagerInputRouting {
        let text = dashboardInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch mode {
        case .rename(let rowID):
            dashboardInputMode = nil
            dashboardInputText = ""
            guard !text.isEmpty else {
                rebuildDashboardRows()
                try renderState()
                return .consumed
            }
            let sessionID = String(rowID.dropFirst(LiveDashboardOverlay.attachPrefix.count))
            let title = LivePagerTasksBlock.firstNonEmptyLine(text)
            let renamed: Bool
            if let pagerRuntime {
                renamed = (try? await pagerRuntime.renameRetainedSession(
                    sessionID: sessionID,
                    title: title
                )) == true
            } else if sessionID == self.sessionID, let conversationHistory {
                do {
                    try await conversationHistory.rename(title: title)
                    renamed = true
                } catch {
                    renamed = false
                }
            } else {
                renamed = (try? await conversationStore?.renameStored(
                    sessionID: sessionID,
                    title: title
                )) == true
            }
            if renamed {
                if let index = sessionTabs.firstIndex(where: { $0.sessionID == sessionID }) {
                    sessionTabs[index].title = title
                }
                if let index = dashboardDormant.firstIndex(where: { $0.sessionID == sessionID }) {
                    dashboardDormant[index].title = title
                }
            } else {
                note("Session no longer exists.")
            }
            rebuildDashboardRows()
            try renderState()
            return .consumed

        case .worktree(let prompt):
            do {
                let preparation = try LiveWorktreeLaunch.prepare(
                    options: CLIExecutionOptions(worktree: text),
                    sourceDirectory: URL(
                        fileURLWithPath: dashboardDispatchWorkingDirectory,
                        isDirectory: true
                    ).standardizedFileURL,
                    openGrokHome: openGrokHome,
                    isCancelled: { false }
                )
                guard let preparation else {
                    throw CLIApplicationError.failed("dashboard worktree preparation was not requested")
                }
                pendingDashboardWorktree = preparation
                dashboardInputMode = nil
                dashboardInputText = ""
                dashboardWorktreeEnabled = false
                preserveDashboardOnNextSessionSwitch = true
                return .dispatchNew(
                    prompt: prompt,
                    workingDirectory: preparation.effectiveDirectory.path
                )
            } catch {
                note(String(describing: error))
                dashboardInputMode = .compose(rowID: LiveDashboardOverlay.newAgentRowID)
                dashboardInputText = prompt
                dashboardWorktreeEnabled = true
            }
            rebuildDashboardRows()
            try renderState()
            return .consumed

        case .compose(let rowID):
            guard !text.isEmpty else {
                dashboardInputMode = nil
                dashboardInputText = ""
                rebuildDashboardRows()
                try renderState()
                return .consumed
            }
            if text == "/cd" {
                dashboardInputMode = nil
                dashboardInputText = ""
                presentDashboardLocationPicker()
                try renderState()
                return .consumed
            }
            if text.hasPrefix("/cd ") {
                dashboardInputMode = nil
                dashboardInputText = ""
                changeDashboardDispatchLocation(String(text.dropFirst(4)))
                rebuildDashboardRows()
                try renderState()
                return .consumed
            }
            dashboardInputMode = nil
            dashboardInputText = ""
            preserveDashboardOnNextSessionSwitch = true
            if rowID == LiveDashboardOverlay.newAgentRowID {
                if dashboardWorktreeEnabled {
                    dashboardInputMode = .worktree(prompt: text)
                    preserveDashboardOnNextSessionSwitch = false
                    rebuildDashboardRows()
                    try renderState()
                    return .consumed
                }
                return .dispatchNew(
                    prompt: text,
                    workingDirectory: dashboardDispatchWorkingDirectory
                )
            }
            if rowID.hasPrefix(LiveDashboardOverlay.subagentPrefix) {
                note("Subagent peeks are read-only; attach before sending a prompt.")
                preserveDashboardOnNextSessionSwitch = false
                rebuildDashboardRows()
                try renderState()
                return .consumed
            }
            guard rowID.hasPrefix(LiveDashboardOverlay.attachPrefix) else {
                preserveDashboardOnNextSessionSwitch = false
                return .consumed
            }
            return .dispatchPrompt(
                sessionID: String(rowID.dropFirst(LiveDashboardOverlay.attachPrefix.count)),
                prompt: text
            )
        }
    }

    func selectDashboardListRow(id: String) {
        overlays.updateList(id: LiveDashboardOverlay.overlayID) { list in
            guard let index = list.rows.firstIndex(where: { $0.id == id }) else { return }
            list.selectedIndex = index
        }
    }

    func presentDashboardLocationPicker() {
        var paths = [dashboardDispatchWorkingDirectory]
        let current = URL(
            fileURLWithPath: dashboardDispatchWorkingDirectory,
            isDirectory: true
        ).standardizedFileURL
        paths.append(current.deletingLastPathComponent().path)
        if let home = environment["HOME"] { paths.append(home) }
        paths.append(contentsOf: sessionTabs.map(\.cwd))
        paths.append(contentsOf: dashboardDormant.map(\.workingDirectory))
        paths.append(contentsOf: leaderRoster.map(\.cwd))
        var seen: Set<String> = []
        let rows = paths.compactMap { path -> PagerListRow? in
            let normalized = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            return PagerListRow(
                id: "location:" + normalized,
                label: LivePagerChrome.collapseHome(normalized)
            )
        }
        overlays.push(.list(
            id: "dashboard-location",
            title: "Choose dashboard location",
            rows: rows,
            isFilterable: true,
            hints: [
                PagerOverlayHint(key: "enter", label: "select"),
                PagerOverlayHint(key: "esc", label: "back"),
            ]
        ))
    }

    func changeDashboardDispatchLocation(_ input: String) {
        let expanded = (input as NSString).expandingTildeInPath
        let candidate = URL(fileURLWithPath: expanded, relativeTo: URL(
            fileURLWithPath: dashboardDispatchWorkingDirectory,
            isDirectory: true
        )).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: candidate.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            note("Directory not found: \(input)")
            return
        }
        guard FileManager.default.changeCurrentDirectoryPath(candidate.path) else {
            note("Could not set working directory: \(candidate.path)")
            return
        }
        dashboardDispatchWorkingDirectory = candidate.path
        note("\u{2192} \(LivePagerChrome.collapseHome(candidate.path))")
    }

    func toggleDashboardWorktree() {
        let sourceDirectory = URL(
            fileURLWithPath: dashboardDispatchWorkingDirectory,
            isDirectory: true
        ).standardizedFileURL
        do {
            guard try discoverGitRepo(at: sourceDirectory).toplevel != nil else {
                note("New worktrees require a git repository.")
                dashboardWorktreeEnabled = false
                return
            }
        } catch {
            note("Could not inspect repository: \(error)")
            dashboardWorktreeEnabled = false
            return
        }
        dashboardWorktreeEnabled.toggle()
        selectDashboardListRow(id: LiveDashboardOverlay.newAgentRowID)
    }

    /// Ctrl+/ reaches the decoder as the raw unit-separator byte; the
    /// literal `/` spelling is kept for adapters that report the pair —
    /// the Ctrl+\ dual-spelling precedent.
    static func isSearchChordCharacter(_ character: Character) -> Bool {
        character == "/" || character == "\u{1f}"
    }

    func selectedDashboardListRowID() -> String? {
        guard let focused = overlays.focused,
              focused.id == LiveDashboardOverlay.overlayID,
              case .list(let list) = focused.content
        else { return nil }
        return list.selectedRow?.id
    }

    func selectedDashboardRowID() -> PagerDashboardRowID? {
        guard let rowID = selectedDashboardListRowID() else { return nil }
        return LiveDashboardOverlay.dashboardRowID(
            forListRowID: rowID,
            activeSessionID: sessionID,
            liveSessionIDs: Set(sessionTabs.map(\.sessionID))
        )
    }

    func selectedDashboardSectionKey() -> PagerDashboardSectionKey? {
        guard let rowID = selectedDashboardListRowID() else { return nil }
        return LiveDashboardOverlay.sectionKey(forListRowID: rowID)
    }

    /// The active session shows NEEDS INPUT exactly when an approval is
    /// waiting under the roster — the port of `classify_top_level`'s
    /// permission/question arm (`row.rs:375-380`) over the overlay stack,
    /// the same signal the composer's focus follows.
    var dashboardActiveNeedsInput: Bool {
        overlays.overlays.contains { overlay in
            switch overlay.content {
            case .permission, .question, .planApproval: return true
            default: return false
            }
        }
    }

    func buildDashboardOverlay() -> PagerOverlay {
        let editingRowID: String?
        switch dashboardInputMode {
        case .compose(let rowID), .rename(let rowID): editingRowID = rowID
        case .worktree: editingRowID = LiveDashboardOverlay.newAgentRowID
        case nil: editingRowID = nil
        }
        return LiveDashboardOverlay.overlay(
            tabs: sessionTabs,
            activeSessionID: sessionID,
            activeTurnRunning: turnActivity != nil,
            activeNeedsInput: dashboardActiveNeedsInput,
            subagents: dashboardSubagents,
            dormant: dashboardDormant,
            roster: leaderRoster,
            state: dashboardState,
            armedCloseSessionID: armedCloseSessionID,
            searchQuery: dashboardSearchQuery,
            editingRowID: editingRowID,
            editingText: dashboardInputText,
            dispatchWorkingDirectory: LivePagerChrome.collapseHome(
                dashboardDispatchWorkingDirectory
            ),
            worktreeEnabled: dashboardWorktreeEnabled
        )
    }

    func dashboardCandidateRowIDs() -> [PagerDashboardRowID] {
        LiveDashboardOverlay.rowInputs(
            tabs: sessionTabs,
            activeSessionID: sessionID,
            activeTurnRunning: turnActivity != nil,
            activeNeedsInput: dashboardActiveNeedsInput,
            subagents: dashboardSubagents,
            dormant: dashboardDormant,
            roster: leaderRoster
        ).map(\.id)
    }

    /// `dispatch_dashboard_persist` (`dashboard.rs:2369-2384`): thread the
    /// ON-DISK enabled — never a hardcoded `true` — and swallow write
    /// failures (warn-only upstream; the mutation already took effect in
    /// memory, and failing the keystroke over a read-only config would be
    /// worse than losing the persistence).
    func persistDashboardState() {
        try? dashboardStore.write(
            dashboardState.toPersisted(enabled: dashboardPersistedEnabled)
        )
    }

    /// The `x` close verb (B1 C-1): the port of upstream's Ctrl+X DELETE leg
    /// only (`dispatch_dashboard_stop` -> `arm_or_delete` -> `delete_dashboard_row`,
    /// dispatch/dashboard.rs:1980-2242). The busy-stop leg has no analog —
    /// background tabs are idle by construction, and the ACTIVE session
    /// refuses with its real deletion route, the resident-delete rule
    /// (`LiveSessionAdminACPHandlers.swift:38-43`: no live-actor teardown
    /// seam — `/delete` owns that flow's confirmation).
    func handleDashboardClose(rowID: String) async {
        let stripped = String(rowID.dropFirst(LiveDashboardOverlay.closePrefix.count + 1))
        guard stripped.hasPrefix(LiveDashboardOverlay.attachPrefix) else { return }
        let target = String(stripped.dropFirst(LiveDashboardOverlay.attachPrefix.count))
        guard target != sessionID else {
            note("The attached session can't be deleted from the roster — use /delete.")
            armedCloseSessionID = nil
            try? renderState()
            return
        }
        guard armedCloseSessionID == target else {
            // First press (or a press on a different row): arm, never delete —
            // upstream re-checks the armed row is still the selected row for
            // the same reason (dashboard.rs:2141-2161).
            armedCloseSessionID = target
            rebuildDashboardRows()
            try? renderState()
            return
        }
        // Second press on the same row: delete for real. The catalog file is
        // the on-disk record; the tab/dormant entries are this process's
        // metadata, and the state refs must not linger as phantoms.
        armedCloseSessionID = nil
        let deleted = (try? sessionCatalog?.delete(sessionID: target)) ?? false
        sessionTabs.removeAll { $0.sessionID == target }
        dashboardDormant.removeAll { $0.sessionID == target }
        dashboardState.gcStaleRefs { $0.owningSessionID != target }
        persistDashboardState()
        rebuildDashboardRows()
        note(deleted ? "Deleting session\u{2026}" : "Session file was already gone.")
        try? renderState()
    }

    /// Rebuild the open roster's rows IN PLACE (cursor and filter preserved —
    /// the updateList contract), clamping the cursor so it lands on the
    /// neighbor row after a deletion the way upstream's
    /// `dashboard_neighbor_row` keeps the cursor "in place" as rows shift up
    /// (dashboard.rs:1924-1979).
    func rebuildDashboardRows() {
        let fresh = buildDashboardOverlay()
        guard case .list(let rebuilt) = fresh.content else { return }
        overlays.updateList(id: LiveDashboardOverlay.overlayID) { list in
            let previousIndex = list.selectedIndex
            list.rows = rebuilt.rows
            list.selectedIndex = min(previousIndex, max(0, list.filteredRows.count - 1))
        }
        // The rebuilt title carries the live search text / filter chip.
        overlays.retitle(id: LiveDashboardOverlay.overlayID, title: fresh.title)
        refreshDashboardPeek()
    }

    /// Follow the selection cursor: the peek is rebuilt from the selected row
    /// on every refresh, never toggled (`render.rs:212-283`). Editing the open
    /// overlay IN PLACE is load-bearing — `push` would reset the cursor and
    /// the filter query, i.e. destroy the selection the peek follows. A
    /// no-op when the roster is not the open list.
    func refreshDashboardPeek() {
        let replyState: (rowID: String, text: String?)?
        if case .compose(let rowID) = dashboardInputMode,
           rowID != LiveDashboardOverlay.newAgentRowID {
            replyState = (rowID, dashboardInputText)
        } else {
            replyState = nil
        }
        let question = dashboardPeekQuestion
        overlays.updateList(id: LiveDashboardOverlay.overlayID) { list in
            list.peek = list.selectedRow.flatMap { row in
                LiveDashboardPeek.peek(
                    forRowID: row.id,
                    cache: dashboardPeekCache,
                    activeSessionID: sessionID,
                    activeItems: conversation.items,
                    activeLastActivity: sessionTabs
                        .first { $0.sessionID == sessionID }?.lastActivity,
                    turnActivity: turnActivity,
                    subagentStatuses: Dictionary(
                        uniqueKeysWithValues: dashboardSubagents.map {
                            ($0.subagentID, $0.status)
                        }
                    ),
                    subagentHints: Dictionary(
                        uniqueKeysWithValues: dashboardSubagents.map {
                            ($0.subagentID, $0.output)
                        }
                    ),
                    replyRowID: replyState?.rowID,
                    replyDraft: replyState?.text,
                    questionPrompt: row.id == LiveDashboardOverlay.attachPrefix + sessionID
                        ? question?.prompt
                        : nil,
                    questionOptions: row.id == LiveDashboardOverlay.attachPrefix + sessionID
                        ? question?.options ?? []
                        : [],
                    questionSelectedIndex: row.id == LiveDashboardOverlay.attachPrefix + sessionID
                        ? question?.selectedIndex
                        : nil,
                    questionFreeformText: row.id == LiveDashboardOverlay.attachPrefix + sessionID
                        ? question?.freeformText ?? ""
                        : "",
                    questionFreeformFocused: row.id == LiveDashboardOverlay.attachPrefix + sessionID
                        ? question?.freeformFocused ?? false
                        : false,
                    questionRequiresAttach: row.id == LiveDashboardOverlay.attachPrefix + sessionID
                        ? question?.requiresAttach ?? false
                        : false
                )
            }
        }
    }

    var dashboardPeekQuestion: LiveDashboardQuestionSnapshot? {
        for overlay in overlays.overlays.reversed() {
            guard case .question(let prompt) = overlay.content,
                  let question = prompt.currentQuestion
            else { continue }
            return LiveDashboardQuestionSnapshot(
                overlayID: overlay.id,
                requestID: prompt.request.id,
                prompt: question.text,
                options: question.options.map(\.label) + ["Other"],
                selectedIndex: prompt.cursor,
                freeformText: prompt.freeformText,
                freeformFocused: prompt.focus == .freeformInput,
                requiresAttach: question.isMultiSelect
            )
        }
        return nil
    }

    func handleDashboardQuestionChord(
        _ event: KeyEvent,
        question snapshot: LiveDashboardQuestionSnapshot
    ) async throws -> OpenGrokPagerInputRouting? {
        if snapshot.requiresAttach {
            if event.key == .escape { return nil }
            switch event.key {
            case .enter, .char(" "):
                note("Open the session to answer multi-select questions.")
                try renderState()
            case .char(let character)
                where character.wholeNumberValue != nil:
                note("Open the session to answer multi-select questions.")
                try renderState()
            default:
                break
            }
            return .consumed
        }

        if event.key == .escape, !snapshot.freeformFocused { return nil }
        var confirmation: PagerQuestionPrompt.ConfirmResult?
        let updated = overlays.updateQuestion(id: snapshot.overlayID) { prompt in
            switch prompt.focus {
            case .freeformInput:
                switch event.key {
                case .escape:
                    prompt.leaveFreeformInput()
                case .enter:
                    confirmation = prompt.confirmFreeform()
                case .backspace:
                    prompt.deleteFreeformBackward()
                case .char(let character)
                    where event.modifiers.subtracting(.shift).isEmpty && !character.isNewline:
                    prompt.appendFreeform(character)
                default:
                    break
                }
            case .navigation:
                switch event.key {
                case .up:
                    prompt.moveCursor(by: -1)
                case .down:
                    prompt.moveCursor(by: 1)
                case .enter:
                    confirmation = prompt.confirmAtCursor()
                case .char(" "):
                    prompt.toggleAtCursor()
                case .char(let character)
                    where event.modifiers.subtracting(.shift).isEmpty && !character.isNewline:
                    if let number = character.wholeNumberValue,
                       number > 0,
                       number <= prompt.rowCount {
                        prompt.moveCursor(by: number - 1 - prompt.cursor)
                        confirmation = prompt.confirmAtCursor()
                    } else if prompt.isOnFreeformRow {
                        prompt.enterFreeformInput()
                        prompt.appendFreeform(character)
                    }
                default:
                    break
                }
            }
        }
        guard updated else { return .consumed }
        if case .submitted(let answers) = confirmation {
            await resolveQuestion(
                overlayID: snapshot.overlayID,
                requestID: snapshot.requestID,
                outcome: .answered(answers)
            )
        }
        rebuildDashboardRows()
        try renderState()
        return .consumed
    }

    /// Ctrl+G (`agent_view/input.rs:1230-1231`): closed → open focused;
    /// open but unfocused → take focus; focused → close.
    func toggleTasksPane() async throws {
        if tasksPane == nil {
            tasksPane = PagerTasksPaneState(focused: true)
            await refreshTasksPaneEntries()
            armTasksPaneRefresh()
        } else if tasksPane?.focused == false {
            tasksPane?.focused = true
        } else {
            closeTasksPane()
        }
        try renderState()
    }

    func closeTasksPane() {
        tasksPane = nil
        tasksPaneRefresh?.cancel()
        tasksPaneRefresh = nil
    }

    func armTasksPaneRefresh() {
        tasksPaneRefresh?.cancel()
        tasksPaneRefresh = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                guard await self.tasksPaneIsVisible() else { return }
                await self.refreshTasksPaneEntries()
                await self.repaintForTasksPane()
            }
        }
    }

    func tasksPaneIsVisible() -> Bool {
        tasksPane != nil
    }

    func repaintForTasksPane() {
        try? renderState()
    }

    /// Rebuild the pane's entries from the same four feeds `/tasks` reads
    /// (`presentTasksBlock`), preserving collapse and selection.
    func refreshTasksPaneEntries() async {
        guard tasksPane != nil else { return }
        var workflowViews: [RhaiWorkflowRunView] = []
        if let workflowRegistry {
            workflowViews = (try? await workflowRegistry.views()) ?? []
        }
        var subagents: [LiveSubagentSnapshot] = []
        if let host = toolExecutor?.subagentHost {
            for id in await host.knownSubagentIDs() {
                if let snapshot = await host.subagentSnapshot(id: id) {
                    subagents.append(snapshot)
                }
            }
        }
        let shellTasks = await toolExecutor?.backgroundTaskSnapshots(
            sessionID: sessionID,
            workingDirectory: URL(fileURLWithPath: workingDirectory, isDirectory: true)
        ) ?? []
        var scheduled: [ScheduledTaskInfo] = []
        if let schedulerHost = toolExecutor?.schedulerHost {
            scheduled = await schedulerHost.displayInfos()
        }
        tasksPane?.updateEntries(LiveTasksPane.entries(
            workflows: workflowViews,
            subagents: subagents,
            tasks: shellTasks,
            scheduled: scheduled
        ))
    }

    /// The pane's `x` dispatch (`panes.rs:384-420`), each through its
    /// backing; the workflow stop rides the slash dispatch exactly as
    /// upstream's `SendSlashCommandPreservingDraft` does.
    func performTasksPaneAction(
        _ action: PagerTaskPaneAction
    ) async throws -> OpenGrokPagerInputRouting {
        switch action {
        case .killBgTask(let taskID):
            let killed = await toolExecutor?.killBackgroundTask(
                sessionID: sessionID,
                workingDirectory: URL(fileURLWithPath: workingDirectory, isDirectory: true),
                taskID: taskID
            ) ?? false
            if !killed {
                note("Task \(taskID) had already exited.")
            }
        case .killSubagent(let subagentID):
            if let host = toolExecutor?.subagentHost {
                _ = await host.cancelSubagent(id: subagentID)
            }
        case .cancelScheduled(let taskID):
            if let schedulerHost = toolExecutor?.schedulerHost {
                _ = try? await schedulerHost.deleteTask(id: taskID)
            }
        case .stopWorkflow(let name):
            // The command path owns confirmation and copy; preserve the
            // user's draft exactly as upstream's dispatch does.
            return .runCommand("/workflow stop \(name)")
        case .copyBgTaskOutput(let taskID):
            // Re-read the feed instead of trusting the row the user was
            // looking at: the pane refreshes on a one-second timer, so the
            // snapshot that built the row can already be stale.
            let snapshots = await toolExecutor?.backgroundTaskSnapshots(
                sessionID: sessionID,
                workingDirectory: URL(fileURLWithPath: workingDirectory, isDirectory: true)
            ) ?? []
            guard let snapshot = snapshots.first(where: { $0.taskID == taskID }) else {
                note("Task \(taskID) is no longer in this session's task list.")
                break
            }
            guard !snapshot.output.isEmpty else {
                // The builder applies upstream's `!task.stdout.is_empty()`
                // gate (`panes.rs:427`), so this only fires when the output
                // went away between the row and the keypress.
                note("Task \(taskID) has no output to copy.")
                break
            }
            do {
                // The OSC 52 seam `/copy` and `/export` already ride
                // (`deliver`): one write into the sink in hand, which is
                // what also works over SSH and inside tmux.
                try LivePagerClipboard.copy(snapshot.output) { data in
                    try sink.write(String(decoding: data, as: UTF8.self))
                }
                try sink.flush()
                // Upstream classifies copy delivery and reports the tier; this
                // leg has only OSC 52, so the note is upstream's "Unverified"
                // by construction — a terminal with OSC 52 switched off
                // swallows the write and nothing here can tell. A truncated
                // snapshot copies what the snapshot holds.
                note("Copied task output — \(snapshot.output.count) characters.")
            } catch {
                appendMessage(PagerMessage(
                    role: .error,
                    text: "Could not reach the clipboard: \(error)"
                ))
            }
        case .openBgTaskOutput(let taskID):
            let snapshots = await toolExecutor?.backgroundTaskSnapshots(
                sessionID: sessionID,
                workingDirectory: URL(fileURLWithPath: workingDirectory, isDirectory: true)
            ) ?? []
            guard let snapshot = snapshots.first(where: { $0.taskID == taskID }) else {
                note("Task \(taskID) is no longer in this session's task list.")
                break
            }
            // Split on `Character.isNewline`, NOT on "\n": Swift clusters CRLF
            // into ONE Character, so `split(separator: "\n")` finds no
            // separator at all in CRLF output and paints the whole log as a
            // single line (AGENTS.md §2).
            let lines: [PagerStyledLine] = snapshot.output.isEmpty
                ? [PagerStyledLine(text: "(no output yet)")]
                : snapshot.output
                    .split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
                    .map { PagerStyledLine(text: String($0)) }
            // A static snapshot modal, not upstream's BlockViewerPane: no
            // tailing while the task runs, no in-viewer search, no visual
            // select. Recorded divergence.
            overlays.push(.sessionInfo(
                id: "block-viewer",
                title: LivePagerTasksBlock.firstNonEmptyLine(
                    snapshot.displayCommand ?? snapshot.command
                ),
                lines: lines
            ))
        case .openWorkflowDetail(let name):
            guard let workflowRegistry else {
                note("No workflow runs in this session.")
                break
            }
            let views = (try? await workflowRegistry.views()) ?? []
            let rows = LiveWorkflowOverlayBuilder.rows(from: views)
            // Rows are newest-first, so a name shared by several runs opens the
            // newest — upstream's `open_workflow_detail(&name)` is name-keyed
            // the same way.
            guard let index = rows.firstIndex(where: { $0.name == name }) else {
                note("Workflow \(name) is no longer in this session's run list.")
                break
            }
            var overlay = PagerOverlay.workflows(rows: rows)
            // Land ON the run's detail rather than on the dashboard listing it:
            // the pane row the user pressed Enter on already named the run.
            // The overlay id stays "workflows", so `p`/`r`/`x` keep routing
            // through `handleWorkflowSelection`.
            overlay.content = .workflows(PagerWorkflowsOverlay(
                rows: rows,
                selectedIndex: index,
                isDetailOpen: true
            ))
            overlays.push(overlay)
        }
        await refreshTasksPaneEntries()
        try renderState()
        return .consumed
    }

    /// Stamp `[privacy].privacy_banner_acked` in memory and on disk —
    /// upstream's `ack_privacy_banner` (dispatch/status.rs:491-496) plus
    /// its persist effect, collapsed to one seam because this port has no
    /// dispatch/effect split. No production caller yet: the banner's
    /// buttons are the B9-c3 slice; landing the ack here means c3 wires
    /// clicks to a tested write instead of inventing one.
    ///
    /// KEPT DIVERGENCE (lead-ruled): a failed write rolls the in-memory
    /// ack back, this renderer's `rollback_value` convention (the
    /// compact-mode/timestamps/timeline writes above) — upstream only
    /// warns (effects/mod.rs:3989-4001), leaving memory claiming an ack
    /// the disk never recorded. Cost: where upstream hides the banner
    /// until next launch after a failed write, this port re-shows it
    /// immediately; the open direction re-asks a question rather than
    /// recording an answer that did not land.
    @discardableResult
    func ackPrivacyBanner(now: Date = Date()) -> Bool {
        guard var state = privacyBanner else { return false }
        let previous = state.privacyBannerAcked
        let ackedAt = privacyBannerAckTimestamp(now: now)
        state.privacyBannerAcked = ackedAt
        privacyBanner = state
        do {
            try PagerPrivacyBannerAckStore(
                configPath: openGrokHome.appendingPathComponent("config.toml")
            ).write(ackedAt: ackedAt)
            return true
        } catch {
            state.privacyBannerAcked = previous
            privacyBanner = state
            return false
        }
    }

    /// Set the coding-data-sharing preference — the port of
    /// `set_coding_data_sharing_with_source` (dispatch/status.rs:137-183 at
    /// pin 650c1db7) fused with its two task-result handlers
    /// (`handle_coding_data_sharing_updated` :424-455,
    /// `handle_coding_data_sharing_failed` :457-491), in upstream's exact
    /// order: guards → idempotent skip → OPTIMISTIC flip → server write →
    /// re-anchor on success / rollback + toast on failure. The write
    /// generation (`codingDataWriteSeq`) is claimed before the await and
    /// re-checked after it, so a reply superseded by a newer write touches
    /// nothing — success or failure alike (status.rs:96-110, :462-467).
    ///
    /// This is also the seam B9-c3's banner `[Opt in]` calls with its
    /// inflight guard: `.refused`/`.unchanged` mean no request was issued
    /// (upstream's empty-effects arm, status.rs:513-516), `.saved` is the
    /// ack trigger, `.failed` leaves the banner up. No banner code lands
    /// in this slice.
    ///
    /// Success is silent (status.rs:167-168: "Success is silent; only the
    /// refusals above and the failure handler toast"); every refusal and
    /// failure toasts, mapped onto a transcript note like every toast in
    /// this port.
    @discardableResult
    func setCodingDataSharing(optedIn: Bool) async -> LiveCodingDataSharingOutcome {
        // The guards read the same mirror the banner gate reads. A
        // renderer that never hydrated (headless constructions that skip
        // `begin()`) hydrates now, from the same auth store — evaluating
        // consent guards against a default-constructed state would let a
        // ZDR team's write through.
        if privacyBanner == nil { await refreshPrivacyBannerState() }
        guard let state = privacyBanner else { return .refused }
        // ── Guard 1: Enterprise ZDR (status.rs:141-145) ──
        if state.isZDR {
            note("\u{2717} Cannot change: Zero Data Retention enabled")
            try? renderState()
            return .refused
        }
        // ── Guard 2: non-admin team member (status.rs:146-156) ──
        if state.isTeamNonAdmin {
            note("\u{2717} Data sharing is controlled by your team admin")
            try? renderState()
            return .refused
        }
        let previousOptedIn = !state.codingDataRetentionOptOut
        // Idempotent path: skip the round-trip (status.rs:163-166).
        if previousOptedIn == optedIn { return .unchanged }

        // Optimistic mutation + open-modal refresh (status.rs:169-170).
        applyCodingDataSharingMirror(optOut: !optedIn)
        try? renderState()

        // Claim this write's generation BEFORE suspending (status.rs:87-92).
        codingDataWriteSeq &+= 1
        let seq = codingDataWriteSeq

        switch await performCodingDataRetentionWrite(optOut: !optedIn) {
        case .success(let confirmedOptOut):
            // Superseded success: a newer write owns the state
            // (status.rs:429-431 via is_current_coding_data_write). The
            // server did accept THIS write; only the re-anchor is dropped.
            guard seq == codingDataWriteSeq else { return .saved }
            // Re-anchor to the CONFIRMED value (status.rs:432-435).
            applyCodingDataSharingMirror(optOut: confirmedOptOut)
            try? renderState()
            return .saved
        case .failure(let error):
            // A superseded failure must not revert — its rollback predates
            // the newer write — and must not toast: nothing the user is
            // looking at failed (status.rs:462-467).
            guard seq == codingDataWriteSeq else { return .failed }
            // Revert the optimistic mutation: inner → refresh → toast
            // (status.rs:468-479), with upstream's scrub on the way to the
            // painted surface (status.rs:481-483).
            applyCodingDataSharingMirror(optOut: !previousOptedIn)
            note("\u{2717} Couldn't update coding data sharing: "
                + pagerScrubErrorForToast(error.description))
            try? renderState()
            return .failed
        }
    }

    /// What the OPEN settings modal currently shows for one row. Internal
    /// (not private) for the live-seam tests: an async re-anchor or
    /// rollback must be asserted against the modal the user is looking at,
    /// not against a freshly built one — a fresh build would read the
    /// mirror and pass even if the open overlay was never refreshed (§3).
    /// `nil` when no settings modal is open or the row has no explicit
    /// value in it.
    func openSettingsRowValue(forKey key: String) -> PagerSettingValue? {
        for overlay in overlays.overlays.reversed()
        where overlay.id == "settings" {
            if case .settings(let settings) = overlay.content {
                return settings.values[key]
            }
        }
        return nil
    }

    /// Flip the in-memory mirrors together: the banner-gate state (what
    /// B9-c1's `shouldShow` reads — the row and the gate must never
    /// disagree) and the open settings modal's row, upstream's
    /// `set_coding_data_sharing_inner` + `refresh_open_settings_modals`
    /// pair (status.rs:71-74 and :170).
    func applyCodingDataSharingMirror(optOut: Bool) {
        if var state = privacyBanner {
            state.codingDataRetentionOptOut = optOut
            privacyBanner = state
        }
        overlays.updateSettings { settings in
            settings.values[Self.codingDataSharingKey] = .string(
                optOut ? "opt-out" : "opt-in"
            )
        }
    }

    /// Resolve the credential, PUT the flag, and mirror the confirmed value
    /// into auth metadata — upstream's shell handler half
    /// (extensions/privacy.rs:29-90). Every arm reports; nothing here can
    /// silently succeed or silently drop the write.
    func performCodingDataRetentionWrite(
        optOut: Bool
    ) async -> Result<Bool, LiveCodingDataRetentionError> {
        guard let client = codingDataRetention else {
            return .failure(.unavailable)
        }
        // The same AuthManager construction the gate hydration uses
        // (`refreshPrivacyBannerState`), so the credential this write rides
        // is the credential the gate state came from. `auth()` is
        // upstream's `auth_manager.auth().await` (privacy.rs:29-34): any
        // failure maps to the auth-required arm and its exact copy.
        let manager = AuthManager(
            grokHome: openGrokHome,
            config: GrokComConfig.default(environment: environment),
            environment: environment
        )
        let auth: GrokAuth
        do {
            auth = try await manager.auth()
        } catch {
            return .failure(.notAuthenticated)
        }
        let result = await client.setOptOut(optOut, bearerToken: auth.key)
        if case .success(let confirmedOptOut) = result {
            // Update local auth state to match (privacy.rs:83-89). The
            // port's `update` IS upstream's `save_without_enrichment` —
            // no background `/user` enrichment exists here to race the
            // flag. Best-effort exactly as upstream's `let _ =`
            // (privacy.rs:90): the server accepted the consent, so a
            // failed disk write must not roll the UI back. Cost, stated:
            // if this write fails, the NEXT launch hydrates the pre-write
            // value from disk until a login or upstream-style enrichment
            // refreshes it; this session's mirrors stay correct.
            var updated = auth
            updated.codingDataRetentionOptOut = confirmedOptOut
            _ = try? await manager.update(updated)
        }
        return result
    }

    // MARK: - Privacy banner surface (Wave 18 B9-c3)

    /// Whether THIS frame offers the banner the announcement slot —
    /// upstream's `privacy_banner_agent` (app_view.rs:4859-4863 at pin
    /// 650c1db7): the gate says show AND no critical announcement holds
    /// the slot. The render layer takes a `true` at face value (the
    /// slot-ownership pin, agent_view/links.rs:573-580), so the
    /// critical-outranks-privacy ranking lives HERE, where the resolved
    /// announcement projection is. A promo does NOT outrank the banner —
    /// upstream's fold gives the privacy banner the slot over one.
    ///
    /// Gated on fullscreen like `showTimeline`: upstream's banner slot
    /// exists only in the fullscreen agent view (`agent_view/render.rs:
    /// 888-892`; minimal has no banner chrome, and this port's inline
    /// strip is a ≤12-row surface upstream never grows a consent banner
    /// into). Cost: an inline session is never upsold and can only change
    /// the setting from the `/privacy` row.
    var privacyBannerVisible: Bool {
        mode == .fullScreen
            && privacyBanner?.shouldShow() == true
            && announcementBanner?.severity != .critical
    }

    /// `[Opt in]` — `dispatch_privacy_banner_opt_in` (dispatch/status.rs:
    /// 501-514): opt in via the settings path; ack only after the write
    /// confirms, so a failed round trip leaves the banner up instead of
    /// recording a change that did not happen.
    ///
    /// The inflight arm mirrors upstream's `!effects.is_empty()`
    /// (status.rs:510-513): `shouldShow()` already guarantees the
    /// opted-out + unguarded state (its ZDR/team/opt-out arms are the same
    /// mirror the write's guards read), so a click that passes it is
    /// exactly a click whose effects would be non-empty — a `[Opt in]` on
    /// an already-opted-in state never arms, because `shouldShow` is
    /// already false (the `.unchanged` arm of c2's contract). If the state
    /// flips between the click and the spawned write (a concurrent modal
    /// commit), the write self-reports `.refused`/`.unchanged` and the
    /// completion clears the flag, upstream's leave-it-clickable outcome.
    func dispatchPrivacyBannerOptIn() {
        guard !privacyBannerOptInInflight,
              privacyBanner?.shouldShow() == true else { return }
        privacyBannerOptInInflight = true
        // Spawned like the modal commit (status.rs:179-183 → the Effect
        // task): a slow proxy must not block the input loop under a
        // consent click either.
        pendingCodingDataWrite = Task {
            let outcome = await self.setCodingDataSharing(optedIn: true)
            self.finishPrivacyBannerOptIn(outcome)
            return outcome
        }
    }

    /// The banner half of upstream's task-result handlers: clear inflight
    /// (both arms — `handle_coding_data_sharing_updated` status.rs:446-447,
    /// `handle_coding_data_sharing_failed` :487), and ack only a confirmed
    /// opt-in (:448-450). The `opted_in` upstream reads there is the
    /// CURRENT write's confirmed value; this port reads the live mirror
    /// after the write instead, which lands the same place — and when a
    /// concurrent opt-out superseded this write, the mirror says opt-out
    /// and the banner correctly stays.
    func finishPrivacyBannerOptIn(_ outcome: LiveCodingDataSharingOutcome) {
        privacyBannerOptInInflight = false
        guard outcome == .saved,
              privacyBanner?.codingDataRetentionOptOut == false else {
            // `.failed`: c2 already rolled back and toasted; the banner
            // stays up because no ack was recorded. `.refused`/`.unchanged`
            // (a guard regressed between click and write): nothing to ack.
            return
        }
        // Ack the banner (c1's seam). Deliberately no branch on the Bool:
        // a failed disk write rolls the in-memory ack back inside
        // `ackPrivacyBanner`, so the repaint below re-shows the banner —
        // the failure announces itself on the surface it concerns (the c1
        // recorded divergence from upstream's warn-and-hide).
        ackPrivacyBanner()
        try? renderState()
    }

    /// `[Opt out]` — `dispatch_privacy_banner_opt_out` (dispatch/status.rs:
    /// 516-546): ack locally, then record the decline.
    ///
    /// The ack does NOT wait on the server, unlike `[Opt in]`'s: the user
    /// asked for no change, so gating dismissal on a round trip would only
    /// re-ask a question they answered (upstream's comment, :518-520).
    ///
    /// The decline deliberately BYPASSES `setCodingDataSharing`, whose
    /// idempotent guard would skip it — the user is already opted out, and
    /// recording that is the point (:522-525). Consent-source telemetry
    /// (upstream's `log_coding_data_consent_selected`, :531-535) stays
    /// lead-deferred with the rest of B9's telemetry.
    func dispatchPrivacyBannerOptOut() {
        guard !privacyBannerOptInInflight,
              privacyBanner?.shouldShow() == true else { return }
        // Immediate local ack. No branch on the Bool for the same reason
        // as the opt-in completion: a failed write already rolled the
        // in-memory ack back, so the repaint below keeps the banner up —
        // this port's self-announcing arm of upstream's fire-and-forget
        // persist effect (:536).
        ackPrivacyBanner()
        pendingCodingDataWrite = Task {
            await self.declinePrivacyBannerCodingDataSharing()
        }
        try? renderState()
    }

    /// The `[Opt out]` decline's envelope — upstream's directly-built
    /// `Effect::SetCodingDataSharing { opted_in: false,
    /// rollback_to_opted_in: false, seq: next }` (status.rs:537-544) plus
    /// the halves of the shared task-result handlers it reaches: no
    /// optimistic flip (the mirror already says opt-out), a claimed write
    /// generation, success re-anchoring to the confirmed value
    /// (status.rs:432-435), and failure applying the no-op `false`
    /// rollback and the generic scrubbed toast (status.rs:469-477) — the
    /// failure is NOT a banner concern: the ack already landed and the
    /// banner stays dismissed, exactly upstream (nothing in the failure
    /// handler touches the ack). A superseded reply touches nothing
    /// (status.rs:429-431, :462-467).
    func declinePrivacyBannerCodingDataSharing() async -> LiveCodingDataSharingOutcome {
        codingDataWriteSeq &+= 1
        let seq = codingDataWriteSeq
        switch await performCodingDataRetentionWrite(optOut: true) {
        case .success(let confirmedOptOut):
            guard seq == codingDataWriteSeq else { return .saved }
            applyCodingDataSharingMirror(optOut: confirmedOptOut)
            try? renderState()
            return .saved
        case .failure(let error):
            guard seq == codingDataWriteSeq else { return .failed }
            // `rollback_to_opted_in: false` — already opted out, so the
            // revert is a no-op (upstream's comment, :540-542).
            applyCodingDataSharingMirror(optOut: true)
            note("\u{2717} Couldn't update coding data sharing: "
                + pagerScrubErrorForToast(error.description))
            try? renderState()
            return .failed
        }
    }

    /// The welcome hero, menu included — upstream's authenticated row set
    /// (`views/welcome/mod.rs:1755-1787` at pin 650c1db7) filtered per row
    /// to what this port can actually dispatch (Wave 18 B2 lead ruling d —
    /// never paint a row without a backing):
    ///
    /// - `Import Claude settings` (`ctrl+i  [x]`, conditional): OMITTED —
    ///   the port has no Claude-import surface (upstream's
    ///   `Action::ImportClaudeSettings` → `import_claude_modal`).
    /// - `New worktree` (`ctrl+w`): OMITTED — upstream opens a labeled
    ///   worktree dialog (`Action::OpenNewWorktreeDialog` →
    ///   `NewWorktreeSession`); the port's only worktree verb, `/fork
    ///   --worktree`, REFUSES by name (`LivePagerForkCommand`), so there is
    ///   no end-to-end backing.
    /// - `Resume session` (`ctrl+s`): landed when a session catalog exists
    ///   — the row reaches the same picker `/resume` opens
    ///   (`Action::FetchSessionList`, `app/app_view.rs:4608-4610`).
    /// - `Changelog` (click-only, no key — `("", "Changelog")`,
    ///   `mod.rs:1783-1785`): upstream's availability rule is
    ///   `has_access && !show_picker` (`mod.rs:1755`) — painted from the
    ///   first frame, dispatch no-ops until the startup prefetch fills
    ///   `changelog_md` (`app/app_view.rs:4607-4614`). This port's welcome
    ///   only exists authenticated (`has_access` ≡ true here) and its
    ///   picker is a modal above the welcome, not a welcome mode
    ///   (`!show_picker` ≡ true) — so the remaining gate is data
    ///   availability: markdown in memory (the B2-W2 prefetch) OR on disk
    ///   (a prior session's cache), keeping lead ruling (d)'s "no painted
    ///   row without a working dispatch" while the prefetch closes W1's
    ///   recorded first-run gap as soon as it lands.
    /// - `Quit` (`ctrl+q`): landed — the `/quit` round-trip. Upstream swaps
    ///   the hint to `ctrl+d` in VS Code-family embeds
    ///   (`is_vscode_family`, `pager-render/src/terminal/mod.rs:120-127`);
    ///   the port has no terminal-brand seam (only a raw TERM_PROGRAM
    ///   string), so the variant is omitted and `ctrl+q` paints
    ///   unconditionally.
    ///
    /// The gate-menu variant (`!has_access`: `[cta] / Logout / Quit`,
    /// `mod.rs:1760-1762`) is absent with the rest of the gated welcome:
    /// this port never renders a pre-access welcome (no `AuthState` model;
    /// the overlay only exists inside an authenticated session).
    ///
    /// Version is upstream's hero-inline badge value (`render_version_badge`
    /// `HeroInline`, `mod.rs:462-489` paints `xai_grok_version::VERSION`);
    /// the port's analog honors the `GROK_TEST_VERSION` override.
    func welcomeOverlay() -> PagerWelcomeOverlay {
        var menu: [PagerWelcomeMenuItem] = []
        if sessionCatalog != nil {
            menu.append(PagerWelcomeMenuItem(
                id: Self.welcomeResumeRowID,
                key: "ctrl+s",
                label: "Resume session"
            ))
        }
        let markdownAvailable = changelogMarkdown != nil
            || ChangelogManager.fromEnvironment(environment).cachedMarkdown() != nil
        if markdownAvailable {
            menu.append(PagerWelcomeMenuItem(
                id: Self.welcomeChangelogRowID,
                key: "",
                label: "Changelog"
            ))
        }
        menu.append(PagerWelcomeMenuItem(
            id: Self.welcomeQuitRowID,
            key: "ctrl+q",
            label: "Quit"
        ))
        return PagerWelcomeOverlay(
            version: OpenGrokCLIVersion.installed(environment: environment),
            subtitle: LivePagerChrome.collapseHome(workingDirectory),
            menu: menu,
            // The hero info slot's changelog arm (`render_hero_box`,
            // `hero_box.rs:349-378`): bullets from the startup prefetch
            // (`app_view.rs:5004`), clickability from markdown availability.
            // Upstream's `changelog_has_full_notes` is in-memory-only
            // (`:5005`); the disk arm here matches this port's row gate so
            // the CTA and the row can never disagree about whether a click
            // has something to open.
            changelogBullets: changelogBullets,
            changelogHasFullNotes: markdownAvailable,
            // The info slot's announcement arm: the SAME slot selection the
            // chrome banner paints (the cached `firstSessionAnnouncement`
            // projection, refreshed by `refreshAnnouncementBanner`) —
            // upstream's hero picks `promo_cta(...)` owner, else
            // `first_session_announcement(...)` (`app_view.rs:4937-4948`),
            // which collapse to the one slot gate because the promo-CTA
            // owner IS the slot selection. Present ⇒ the changelog arm is
            // suppressed entirely by the painters. Upstream's third leg —
            // the sticky random `self.announcement` pick over ALL severities
            // (`:4949`, fed by `apply_announcements_update`,
            // `acp_handler/settings.rs:485-492`) — is a deliberate omission:
            // this port's pipeline has no per-launch random-pick seam (its
            // upstream feeder is the ACP settings push), and inventing a
            // nondeterministic surface here would be UX upstream's port
            // ground doesn't carry. Cost: an info/warning-only feed shows
            // the changelog where upstream would show a random announcement.
            announcement: announcementBanner
        )
    }

    /// Internal (not private) so the live-seam hover test can pin the
    /// selection the REAL mouse router computed (AGENTS.md §3) — the
    /// highlight itself is a background attribute the text-stripping test
    /// sink cannot observe.
    var welcomeMenuSelectionForTesting: Int? {
        for overlay in overlays.overlays where overlay.id == Self.welcomeOverlayID {
            if case .welcome(let welcome) = overlay.content {
                return welcome.selectedIndex
            }
        }
        return nil
    }

    /// Spawn the one-shot changelog prefetch (`Effect::FetchChangelog`,
    /// `app/effects/mod.rs:3958-3977` at pin 650c1db7). One-shot by the
    /// guard: upstream fires it once from event-loop startup
    /// (`event_loop.rs:1811-1816`; its auth.rs re-dispatch sites re-arm on
    /// login transitions this port's renderer never goes through — the
    /// welcome only exists authenticated). The fetch goes through the B9-a
    /// client, so the recorded export-boundary gate applies before any
    /// request is built: a Codex (xAI-export-denied) session issues
    /// nothing and takes the cache-only arm — no bullets unless a prior
    /// xAI session's disk cache exists, which is the honest answer.
    func spawnChangelogPrefetch() {
        guard changelogPrefetch == nil else { return }
        changelogPrefetch = Task { [weak self] in
            await self?.completeChangelogPrefetch()
        }
    }

    /// The fetch + store half of the prefetch — upstream's
    /// `TaskResult::ChangelogFetched` arm (`dispatch/task_result.rs:
    /// 3097-3101`): markdown verbatim, bullets via
    /// `bulletsFromEntries(entries, 3)`. Completion pushes the update into
    /// an OPEN welcome: upstream repaints per-frame so bullets appear on
    /// the next frame automatically; this port renders on events, so the
    /// push is explicit (the W1 `updateWelcome` seam).
    func completeChangelogPrefetch() async {
        let manager = changelog ?? ChangelogManager.fromEnvironment(environment)
        let fetched = await manager.fetch(environment: environment)
        changelogMarkdown = fetched.markdown
        changelogBullets = bulletsFromEntries(fetched.entries ?? [], max: 3)
        refreshWelcomeInPlace()
    }

    /// Rebuild an open welcome overlay in place with the current changelog
    /// state — bullets, CTA clickability, and the (possibly newly
    /// available) Changelog menu row — preserving hover state across the
    /// swap: the selection is remapped by row id, because inserting the
    /// Changelog row above Quit would otherwise silently move a highlight
    /// sitting on Quit. No welcome open (the first turn already dismissed
    /// it), nothing to do; no visible change, no repaint.
    func refreshWelcomeInPlace() {
        let rebuilt = welcomeOverlay()
        var changed = false
        overlays.updateWelcome { welcome in
            var next = rebuilt
            let selectedID = welcome.selectedIndex.flatMap { index in
                welcome.menu.indices.contains(index) ? welcome.menu[index].id : nil
            }
            next.selectedIndex = selectedID.flatMap { id in
                next.menu.firstIndex { $0.id == id }
            }
            next.changelogHovered = welcome.changelogHovered
            // The expand toggle and hover flags are app-side state upstream
            // keeps across frames (`welcome_announcement`, app_view.rs:1011;
            // only a login transition resets `expanded`,
            // `dispatch/ctx.rs:158`) — a refresh must not collapse an
            // expanded announcement or drop a hover mid-pointer.
            next.announcementExpanded = welcome.announcementExpanded
            next.announcementHovered = welcome.announcementHovered
            next.announcementCTAHovered = welcome.announcementCTAHovered
            if welcome != next {
                welcome = next
                changed = true
            }
        }
        if changed { try? renderState() }
    }

    func begin() async throws {
        if let minimalHost {
            // Fresh sessions get the one-shot scrollback card; a resumed
            // transcript replays into scrollback instead (welcome.rs:11-13).
            minimalHost.setWelcomePending(conversation.items.isEmpty)
            try minimalHost.begin()
        } else {
            try renderer.start()
        }
        if let permissionCoordinator {
            await permissionCoordinator.setPresenter { [weak self] request in
                await self?.showPermission(request)
            }
        }
        if let questionCoordinator {
            await questionCoordinator.setPresenter { [weak self] request in
                await self?.showQuestion(request)
            }
        }
        if let planApprovalCoordinator {
            await planApprovalCoordinator.setPresenter { [weak self] request in
                await self?.showPlanApproval(request)
            }
        }
        // Seed the motion-clock anchor before any painted tick. A resumed
        // session with no welcome shimmer never receives `renderAnimationTick`
        // until the first turn arms the ticker; without this, idle before that
        // turn leaves `currentMotionSeconds()` at 0 and the first controller
        // frame (run age) inflates elapsed.
        if motionEnabled {
            motion = PagerMotionSnapshot(tick: 0, seconds: 0, enabled: true)
            noteMotionClockAnchor(seconds: 0)
        }
        // The welcome screen only makes sense on an empty session, and it must
        // not capture input: the reference paints a live composer beneath it.
        // Minimal skips the full-screen welcome entirely — the scrollback
        // card above stands in for it (welcome.rs:3-8), and a pushed overlay
        // here would be an invisible input-routing surface.
        if conversation.items.isEmpty, minimalHost == nil {
            overlays.push(.welcome(welcomeOverlay(), capturesInput: false))
        }
        registerSessionTab(sessionID)
        // The changelog startup prefetch — upstream's one-shot post-auth
        // effect, off the render path, "so the welcome screen can display
        // bullets and /release-notes uses the cached result"
        // (`app/event_loop.rs:1811-1816` at pin 650c1db7). Unconditional
        // like upstream's (fired whether or not the welcome is up: the
        // command consumes the result too); never awaited here — a slow or
        // unreachable CDN costs zero launch time (the announcements spawn
        // shape).
        spawnChangelogPrefetch()
        // Privacy-banner gate state, hydrated at the pager-startup seam like
        // upstream's event_loop resolution (event_loop.rs:1007-1029). Local
        // file reads only (auth store + config.toml); nothing consumes it in
        // a frame yet — see `privacyBanner`.
        await refreshPrivacyBannerState()
        await refreshContextUsage()
        if let permissionMode {
            permissionModeFlags = await permissionMode.composerFlags()
        }
        // One-shot sticky_headers parse/type diagnostics — user-visible
        // system notes, not a silent loader. Absent file / absent key produce
        // none. `note` dismisses welcome when it fires (visible words win).
        for diagnostic in stickyHeadersStartupDiagnostics {
            note(diagnostic)
        }
        stickyHeadersStartupDiagnostics.removeAll(keepingCapacity: false)
        try renderState()
    }

    func resize(to size: OpenGrokTerminalCore.TerminalSize) async throws {
        terminalSize = size
        // The minimal host adopts the size at the top of every draw
        // (lib.rs:71-80 — the stale-width commit hazard is why it happens
        // there, inside the synchronized update, not here).
        if minimalHost == nil {
            try renderer.resize(to: size)
        }
        // Mid-drag reflow must not hit-test the unmoved pointer through the
        // live wrap — that rewrites frozen endpoints and truncates linear
        // reconstruct (`resizeMidDragFrozenCopy`). Kind may still be
        // re-resolved from the frozen endpoints + sidecar; only table kinds
        // consult geometry. Autoscroll still reclamps via the pointer.
        if var drag = activeTextDrag {
            drag.kind = resolveDragKind(
                anchor: drag.anchor,
                head: drag.head,
                prev: drag.kind
            )
            activeTextDrag = drag
        }
        try renderState()
    }

    func clockNow() -> TimeInterval {
        injectedMonotonicNow ?? Self.monotonicNow()
    }

    @discardableResult
    func expireTransientToast(at now: TimeInterval) -> Bool {
        guard let deadline = transientToastExpiresAt, now >= deadline else {
            return false
        }
        transientToast = nil
        transientToastExpiresAt = nil
        return true
    }

    /// Remaining delay until the transient toast TTL elapses. `0` when already
    /// due so the dedicated scroll clock wakes immediately. `nil` when no
    /// transient is armed.
    func remainingTransientToastDelay(at now: TimeInterval) -> TimeInterval? {
        guard let deadline = transientToastExpiresAt else { return nil }
        return max(0, deadline - now)
    }

    func minNonnilDelay(_ delays: TimeInterval?...) -> TimeInterval? {
        delays.compactMap { $0 }.min()
    }

    /// Prompt-focused paint advertises `/toggle-mouse-reporting`; scrollback
    /// (or a selected block) advertises `Ctrl+r`. Storage stays scrollback.
    func displayedStickyToast() -> String? {
        guard let sticky = stickyToast else { return nil }
        if sticky == Self.mouseOffHintScrollback, !selection.isFocused {
            return Self.mouseOffHintPrompt
        }
        return sticky
    }

    func showTransientToast(_ message: String, at now: TimeInterval) {
        transientToast = message
        transientToastExpiresAt = now + Self.transientToastDuration
    }

    /// `/debug [fps]` — always routable. Scroll/log surfaces are absent, so
    /// bare status reports only fps, and unknown args list `[fps]` only.
    /// `fps` only toggles; `render(_:)` paints immediately instead of the
    /// coalesced final `renderState`. Bare/unknown ride that normal render.
    func presentDebug(argument: String) {
        switch argument.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "":
            let on = fpsHud.isEnabled ? "on" : "off"
            note(
                "debug toggles: fps \(on) \u{2014} toggle with /debug fps"
            )
        case "fps":
            fpsHud.toggle()
        default:
            appendMessage(PagerMessage(
                role: .error,
                text: "Unknown /debug option '\(argument.trimmingCharacters(in: .whitespacesAndNewlines))'. Usage: /debug [fps]"
            ))
        }
    }

    /// Paint now, bypassing coalescing so `/debug fps` cannot leave a stale
    /// overlay until the cadence flush. Actor-safe: cancel+await any armed
    /// flush task before the direct request/flush so a stale wakeup cannot
    /// `nil` a newer timer. One committed submit: a due `requestFrame`
    /// records immediately; a coalesced request is flushed once at
    /// `scheduledFrameAt + ε` and is the only record. Minimal mode draws
    /// without an FPS overlay snapshot or `record`.
    func paintImmediately() async throws {
        await cancelPendingFlushTask()
        if let minimalHost {
            lastLaidOutFpsHud = nil
            lastPaintedFpsHud = nil
            minimalHost.draw(renderState(conversation: conversation.items))
            lastPaintedToast = lastLaidOutToast
            publishMotionState()
            return
        }
        let scheduled = renderer.scheduledFrameAt
        let at = scheduled.map { max(clockNow(), $0 + 0.001) } ?? clockNow()
        let flush = scheduled != nil
        if !(try paintCurrentFrame(at: at, flush: flush)),
           let due = renderer.scheduledFrameAt
        {
            _ = try paintCurrentFrame(at: max(clockNow(), due + 0.001), flush: true)
        }
        publishMotionState()
    }

    func present(_ request: OpenGrokPagerOverlayRequest) async throws {
        switch request {
        case .help:
            overlays.push(.help(lines: OpenGrokPagerInteractiveController.helpText(
                workflowsEnabled: workflowsEnabled,
                mouseReportingToggleEnabled: mouseReportingToggleEnabled
            )
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { PagerStyledLine(text: String($0)) }))
        case .modelPicker(let query):
            let entries = catalogStore?.pickerEntries() ?? modelCatalog
            // A typed selector that names exactly one model switches directly:
            // showing a picker the user already answered would be a pointless
            // second step. Ambiguity and misses fall back to an error rather
            // than to the overlay, so `/model <typo>` never silently becomes
            // "pick something else" (upstream returns `Unknown model: …`).
            if let query, !query.isEmpty {
                // Whole-string match first: display names contain spaces
                // ("Grok 4.5"), so splitting the last token first would let a
                // shorter entry steal the prefix and treat "4.5" as an effort
                // (upstream model.rs:76-83).
                if let modelID = LiveModelPicker.resolve(
                    query: query,
                    entries: entries
                ) {
                    await switchModel(to: modelID)
                    return
                }
                // `/model <name> <effort>`: trailing effort token on a
                // reasoning model (upstream model.rs:85-104). A rejected
                // level surfaces the effort error with the model's offered
                // ids — not "Unknown model: … none".
                if let (prefix, token) = LiveModelPicker.splitTrailingToken(query),
                   let modelID = LiveModelPicker.resolve(query: prefix, entries: entries),
                   let entry = entries.first(where: { $0.id == modelID }),
                   entry.supportsReasoningEffort {
                    switch LiveModelEffort.resolve(
                        token: token,
                        supportsReasoningEffort: entry.supportsReasoningEffort,
                        declaredEfforts: entry.reasoningEfforts
                    ) {
                    case .success(let effort):
                        await switchModel(to: modelID, effort: effort)
                    case .failure(let error):
                        appendMessage(PagerMessage(
                            role: .error,
                            text: error.message
                        ))
                    }
                    return
                }
                appendMessage(PagerMessage(
                    role: .error,
                    text: LiveModelPicker.unknownModelMessage(query)
                ))
                return
            }
            overlays.push(LiveModelPicker.overlay(
                entries: entries,
                currentModelID: modelName
            ))
        case .toggleMouseReporting:
            // Minimal never captures the mouse (the guard.rs stance): the
            // terminal's native selection and scrollback own it, which is
            // the mode's point. Refuse honestly instead of toggling a flag
            // no capture sequence would ever back. No sticky — the banner
            // would advertise a re-enable that cannot land.
            if minimalHost != nil {
                appendMessage(PagerMessage(
                    role: .system,
                    text: "Mouse capture stays off in minimal mode — the terminal's native selection and scrollback own the mouse."
                ))
                return
            }
            // Wire first, then memory: a failed `setMouseReporting` write must
            // not flip `mouseReportingEnabled`, or the next toggle aims the
            // wrong direction and restore can skip the disable sequence.
            // Toast/sticky follow the same rule — a thrown write rolls back
            // and must not set or clear either surface.
            let nextEnabled = !mouseReportingEnabled
            try renderer.setMouseReporting(nextEnabled)
            mouseReportingEnabled = nextEnabled
            if nextEnabled {
                stickyToast = nil
                showTransientToast(Self.mouseReportingOnToast, at: clockNow())
            } else {
                stickyToast = Self.mouseOffHintScrollback
            }
        case .debug(let argument):
            presentDebug(argument: argument)
        case .toggleCompactMode:
            // The toggle flips the USER value (`dispatch_toggle_compact_mode`,
            // `ui.rs:815-820`); the next paint re-derives the render value.
            userCompactMode.toggle()
            // Persist through the same store the settings modal writes —
            // upstream's `Effect::PersistSetting{key: "compact_mode"}`
            // (`setters.rs:1523-1528`) lands in `[ui] compact_mode` via
            // `update_config` (`settings_writes.rs:230-232`). A failed write
            // rolls the in-memory flip back, upstream's `rollback_value`
            // semantics: a toggle that claims "on" while the file still says
            // "off" would silently revert at next launch.
            let store = PagerSettingsStore(
                configPath: openGrokHome.appendingPathComponent("config.toml")
            )
            do {
                try store.write(key: "compact_mode", value: .bool(userCompactMode))
            } catch {
                userCompactMode.toggle()
                appendMessage(PagerMessage(
                    role: .error,
                    text: "Could not save compact_mode: \(error)"
                ))
                return
            }
            // Toast copy from `set_compact_mode` (`setters.rs:1516-1522`):
            // turning the setting off while the short-terminal derivation
            // holds keeps the UI compact; say so instead of implying the
            // layout will loosen. Mapped onto a transcript note like every
            // toast in this port.
            if !userCompactMode, pagerEffectiveCompact(
                userCompact: false,
                terminalRows: terminalSize.height
            ) {
                note("\u{2713} Compact mode: off (auto-compact active on small terminal)")
            } else {
                note("\u{2713} Compact mode: \(userCompactMode ? "on" : "off")")
            }
        case .toggleTimestamps:
            // The toggle: upstream's command computes `!load_timestamps()`
            // and dispatches `Action::SetTimestamps` (`timestamps.rs:29-31`),
            // which flips both the `current_ui` snapshot and the appearance
            // value the paint sites read (`set_timestamps_inner`,
            // `setters.rs:1530-1541`). The next paint reads the new value.
            userShowTimestamps.toggle()
            // Persist `[ui] show_timestamps` through the same store the
            // settings modal writes — upstream's
            // `Effect::PersistSetting{key: "show_timestamps"}`
            // (`setters.rs:1553-1558`) lands via `set_show_timestamps`
            // (`settings_writes.rs:237-239`). A failed write rolls the
            // in-memory flip back, upstream's `rollback_value` semantics.
            let timestampsStore = PagerSettingsStore(
                configPath: openGrokHome.appendingPathComponent("config.toml")
            )
            do {
                try timestampsStore.write(
                    key: "show_timestamps",
                    value: .bool(userShowTimestamps)
                )
            } catch {
                userShowTimestamps.toggle()
                appendMessage(PagerMessage(
                    role: .error,
                    text: "Could not save show_timestamps: \(error)"
                ))
                return
            }
            // Toast copy from `set_timestamps` (`setters.rs:1551`):
            // `save_success_toast("Timestamps", new)` (`ui.rs:89-92`) — no
            // conditional arm, unlike compact's. Mapped onto a transcript
            // note like every toast in this port.
            note("\u{2713} Timestamps: \(userShowTimestamps ? "on" : "off")")
        case .relaunchInScreenMode(let minimal, let sessionID):
            // The accepted `/minimal`//`/fullscreen` switch — the controller
            // gated and resolved it; this side only records the request for
            // the composition root, which execs AFTER the loop ends and the
            // terminal is restored (upstream's router.rs:199-209 stash +
            // `Effect::Quit` shape).
            pendingScreenModeRelaunch = (sessionID: sessionID, minimal: minimal)
        case .minimalExpandLast:
            // Ctrl+E / `/expand` — the controller already applied the
            // minimal-only gate, so a nil host here is a routing bug worth a
            // note rather than silence.
            if let minimalHost {
                minimalHost.expandMostRecentFolded()
            } else {
                note("/expand isn't available in fullscreen mode — press Tab to focus the scrollback, then → on the block.")
            }
        case .toggleTimeline:
            // Upstream's `ModeSupport::FullscreenOnly` refusal, byte-parity
            // with `mode_support.rs:47-51` over `timeline.rs:21-25`'s
            // remedy: outside fullscreen the command errors BEFORE any flip
            // or persist, so the config never changes from a mode that
            // cannot paint the rail. B2-S2 ruling: upstream's line is
            // NOT-minimal (its inline is the full layout), but THIS port's
            // `.inline` is a ≤12-row strip whose render gate keeps the rail
            // out (`showTimeline: mode == .fullScreen`) — flipping the key
            // from inline would be a dead toggle, the S1 class. The gate
            // stays capability-true, and the refusal's `/fullscreen` remedy
            // is now REAL from both refused modes (recorded divergence:
            // upstream refuses `/fullscreen` from inline as AlreadyInMode;
            // this port relaunches, because its inline is not the full
            // layout upstream's is).
            guard mode == .fullScreen else {
                note("/timeline isn't available in minimal mode (the timeline rail needs the interactive scrollback pane). Run /fullscreen to switch this session.")
                return
            }
            // The toggle: upstream computes `!load_show_timeline()` and
            // dispatches `Action::SetTimeline` (`timeline.rs:31-34`), which
            // flips both the `current_ui` snapshot and the appearance value
            // the rail renders from (`set_timeline_inner`,
            // `setters.rs:1561-1572`). The next paint reads the new value.
            userShowTimeline.toggle()
            // Persist `[ui] show_timeline` through the same store the
            // settings modal writes — upstream's
            // `Effect::PersistSetting{key: "show_timeline"}`
            // (`setters.rs:1586-1590`) lands via `set_show_timeline`
            // (`settings_writes.rs:241-245`). A failed write rolls the
            // in-memory flip back, upstream's `rollback_value` semantics.
            let timelineStore = PagerSettingsStore(
                configPath: openGrokHome.appendingPathComponent("config.toml")
            )
            do {
                try timelineStore.write(
                    key: "show_timeline",
                    value: .bool(userShowTimeline)
                )
            } catch {
                userShowTimeline.toggle()
                appendMessage(PagerMessage(
                    role: .error,
                    text: "Could not save show_timeline: \(error)"
                ))
                return
            }
            // Toast copy from `set_timeline` (`setters.rs:1586`):
            // `save_success_toast("Timeline sidebar", new)` (`ui.rs:89-92`)
            // — plain arm like timestamps', no conditional. Mapped onto a
            // transcript note like every toast in this port.
            note("\u{2713} Timeline sidebar: \(userShowTimeline ? "on" : "off")")
        case .workflows:
            guard let workflowRegistry else {
                appendMessage(PagerMessage(
                    role: .system,
                    text: "No workflow runs in this session. Launch one with --workflow <file>."
                ))
                return
            }
            let views = (try? await workflowRegistry.views()) ?? []
            overlays.push(.workflows(rows: LiveWorkflowOverlayBuilder.rows(from: views)))
        case .commandPalette(let rows):
            overlays.push(.list(
                id: "command-palette",
                title: "Commands",
                rows: rows.isEmpty
                    ? LivePagerOverlayText.commandRows(
                        workflowsEnabled: workflowsEnabled,
                        mouseReportingToggleEnabled: mouseReportingToggleEnabled
                    )
                    : rows.map {
                        PagerListRow(
                            id: $0.insertText,
                            label: $0.name,
                            summary: $0.summary,
                            isSelectable: $0.isAvailable
                        )
                    }
            ))
        case .promptHistory(let entries):
            guard !entries.isEmpty else {
                note("No prompt history in this session yet.")
                return
            }
            // Newest first: the entry you most likely want to re-run is the one
            // you just ran.
            overlays.push(.list(
                id: "prompt-history",
                title: "Prompt history",
                rows: entries.reversed().enumerated().map { index, entry in
                    PagerListRow(
                        id: "history-\(index)",
                        label: LivePagerOverlayText.singleLine(entry),
                        detail: entry.contains("\n") ? "multiline" : nil
                    )
                }
            ))
        case .promptQueue(let entries):
            guard !entries.isEmpty else {
                note("Nothing queued.")
                return
            }
            overlays.push(.list(
                id: "prompt-queue",
                title: "Queued prompts",
                rows: entries.enumerated().map { index, entry in
                    PagerListRow(
                        id: "queue-\(index)",
                        label: LivePagerOverlayText.singleLine(entry),
                        detail: "#\(index + 1)"
                    )
                }
            ))
        case .sessionInfo:
            overlays.push(.sessionInfo(lines: LivePagerOverlayText.sessionInfoLines(
                workingDirectory: LivePagerChrome.collapseHome(workingDirectory),
                modelName: modelName,
                itemCount: conversation.items.count,
                queuedPromptCount: queuedPromptCount,
                modes: inputModes
            )))
        case .contextUsage:
            // Real accounting now that the renderer shares the turn loop's
            // coordinator — the same numbers auto-compaction decides on, not a
            // character-count estimate. The estimate remains the fallback for
            // compositions with no coordinator (headless, tests), and says so
            // rather than presenting a guess as a measurement.
            guard let compaction else {
                overlays.push(.sessionInfo(
                    id: "context-usage",
                    title: "Context",
                    lines: LivePagerOverlayText.contextLines(
                        modelName: modelName,
                        itemCount: conversation.items.count,
                        transcriptCharacters: transcript.count
                    )
                ))
                return
            }
            let usage = await compaction.usage()
            overlays.push(.sessionInfo(
                id: "context-usage",
                title: "Context",
                lines: LivePagerContextReport.lines(
                    usage: usage,
                    itemCount: conversation.items.count
                )
            ))
        case .copyResponse(let index, let filePath):
            guard let response = LivePagerOverlayText.assistantResponse(
                fromLast: index,
                in: conversation.items
            ) else {
                note("No assistant response \(index) back to copy.")
                return
            }
            try deliver(response, to: filePath, label: "Response")
        case .exportConversation(let filePath):
            try deliver(transcript, to: filePath, label: "Conversation")
        case .transcriptPager:
            try await presentTranscriptPager()
        case .scrollbackSearch(let query):
            guard let query, !query.isEmpty else {
                note("Usage: /find <text>")
                return
            }
            let matches = LivePagerOverlayText.search(query, in: conversation.items)
            guard !matches.isEmpty else {
                note("No matches for \(query).")
                return
            }
            overlays.push(.list(
                id: "scrollback-search",
                title: "Find: \(query)",
                rows: matches
            ))
        case .welcomeScreen:
            overlays.push(.welcome(welcomeOverlay(), capturesInput: false))
        case .shortcutsHelp:
            overlays.push(.help(
                id: "shortcuts-help",
                lines: LivePagerOverlayText.shortcutsLines()
            ))
        case .tutorial:
            overlays.push(.sessionInfo(
                id: "tutorial",
                title: "Getting started",
                lines: LivePagerOverlayText.tutorialLines()
            ))
        case .easterEgg:
            appendMessage(PagerMessage(
                role: .system,
                text: LivePagerOverlayText.easterEgg
            ))
        case .compact(let instructions):
            // Safe to run here only because the controller guarantees no turn
            // is in flight: `/compact` is `mutatesConversationHistory`, so a
            // mid-turn invocation is queued rather than dispatched. Without
            // that gate this would rewrite the item list a streaming sampler is
            // reading from.
            guard let compaction else {
                note("This session has no compaction coordinator, so /compact has nothing to act on.")
                return
            }
            // PreCompact fires before the manual compaction begins; source is
            // "manual" (event.rs:493-496).
            toolExecutor?.fireObserveHook(
                event: .preCompact,
                payload: ["source": .string("manual")]
            )
            note("Compacting\u{2026}")
            try renderState()
            switch await compaction.compactNow(userContext: instructions) {
            case .compacted(_, let report):
                // `compactNow` has already written the replacement back to the
                // persisted conversation, so there is nothing to apply here —
                // only to report.
                toolExecutor?.fireObserveHook(
                    event: .postCompact,
                    payload: ["source": .string("manual")]
                )
                note(report.notice)
            case .notNeeded:
                note("Nothing to compact — the context is not close to full.")
            case .unableToCompact(let reason):
                appendMessage(PagerMessage(
                    role: .error,
                    text: "Could not compact: \(reason)"
                ))
            }
        case .settings(let deepLinkKey):
            overlays.push(.settings(settingsOverlay(deepLinkKey: deepLinkKey)))
        case .themePicker(let query):
            // A typed name that resolves applies straight away; only a miss or
            // a bare `/theme` opens the picker. Same rule as `/model`, and for
            // the same reason — showing a chooser the user already answered is
            // a pointless second step.
            if let query, !query.isEmpty {
                guard let message = applyTheme(named: query) else {
                    appendMessage(PagerMessage(
                        role: .error,
                        text: "Unknown theme: \(query). Try "
                            + availableThemeNames.joined(separator: ", ") + "."
                    ))
                    return
                }
                appendMessage(PagerMessage(role: .system, text: message))
                return
            }
            overlays.push(.list(
                id: "theme",
                title: "Select theme",
                rows: availableThemeNames.map { name in
                    PagerListRow(
                        id: name,
                        label: PagerThemePreference.named(name)?.displayName ?? name,
                        detail: themePreference == PagerThemePreference.named(name) ? "✓" : nil
                    )
                }
            ))
        case .rewind(let argument):
            // Safe to touch history here for the same reason `/compact` is:
            // `rewind` is `mutatesConversationHistory`, so the controller defers
            // it out of a running turn rather than dispatching it inline.
            await applyRewind(argument: argument)
        case .jumpPicker:
            guard mode == .fullScreen else {
                // Upstream's `ModeSupport::FullscreenOnly` remedy, verbatim in
                // substance: there is no viewport to move in minimal mode.
                note("/jump needs fullscreen mode — minimal scrolls with your terminal's native scrollback.")
                return
            }
            overlays.push(LiveJumpPicker.overlay(items: conversation.items))
        case .deleteSession(let confirmed):
            await deleteSession(confirmed: confirmed)
        case .remember(let text):
            note(await LiveMemoryCommands.remember(text, backend: sessionServices?.memory))
        case .recall(let query):
            note(await LiveMemoryCommands.recall(query, backend: sessionServices?.memory))
        case .flush(let text):
            note(await LiveMemoryCommands.flush(
                text,
                sessionID: sessionID,
                backend: sessionServices?.memory
            ))
        case .dream:
            await runDreamCommand()
        case .voice:
            await runVoiceCommand()
        case .goal(let argument):
            guard let coordinator = sessionServices?.goal else {
                note("Goal tracking is not available in this session.")
                return
            }
            switch await LiveGoalCommands.run(argument: argument, coordinator: coordinator) {
            case .message(let text):
                note(text)
            case .submitPrompt(let text):
                // Setting a goal seeds the model with the goal instruction,
                // which is a turn rather than a message. The renderer cannot
                // start one, so it says what it did and hands the text to the
                // user rather than silently dropping it.
                note("Goal set. Send this to brief the model on it, or just keep going:")
                note(text)
            }
        case .showDashboard:
            try await presentDashboard()
        case .sessionPicker:
            // `/resume` (upstream resume.rs:21-23). Row ids are session ids;
            // choosing one round-trips through the controller as
            // `/resume <id>`, which is what reaches the runtime swap.
            guard let sessionCatalog else {
                note("Session storage is unavailable in this session, so there is nothing to resume.")
                return
            }
            let listings = (try? sessionCatalog.list()) ?? []
            overlays.push(LiveSessionPicker.overlay(listings: listings))
        case .usage:
            // `/usage` (upstream usage.rs:59, `Action::ShowUsage`) rendered as
            // a text modal the way `/context` is. The numbers come from
            // `LiveUsageComposition`, which documents why they are estimates.
            let context: ContextUsage?
            if let compaction {
                context = await compaction.usage()
            } else {
                context = nil
            }
            let usageItems: [ConversationItem]
            if let conversationHistory {
                usageItems = await conversationHistory.items
            } else {
                usageItems = []
            }
            let report = await LiveUsageComposition.report(
                context: context,
                items: usageItems
            )
            overlays.push(.sessionInfo(
                id: "usage",
                title: "Usage",
                lines: LiveUsageComposition.render(report)
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { PagerStyledLine(text: String($0)) }
            ))
        case .cache:
            // `/cache` (upstream Action::ShowCache, slash/commands/cache.rs)
            overlays.push(.sessionInfo(
                id: "cache",
                title: "Prompt Cache",
                lines: LiveCacheComposition.render(
                    cacheHitRate: nil,
                    totalPromptTokens: 0,
                    cachedTokens: 0,
                    breakEvents: []
                )
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { PagerStyledLine(text: String($0)) }
            ))
        case .mcpServers:
            overlays.push(.sessionInfo(
                id: "mcps",
                title: "MCP servers",
                lines: LiveMCPStatusOverlay.lines(connections: mcpServers)
                    .map { PagerStyledLine(text: $0) }
            ))
        case .extensions(let tab):
            // `/hooks`, `/plugins`, `/marketplace`, `/skills`, `Ctrl+L` —
            // the read-only extensions modal, every data tab snapshotted
            // fresh from the live loaders at open. Re-running the command
            // while open replaces the modal on the requested tab, exactly
            // what pushing the shared id does.
            // Mutual exclusivity: opening extensions closes the agents
            // modal (`dispatch/transcript.rs:463-464` at pin 650c1db7).
            overlays.dismiss(id: LiveAgentsComposition.overlayID)
            overlays.push(.extensions(LiveExtensionsComposition.overlay(
                tab: LiveExtensionsComposition.tab(for: tab),
                workingDirectory: workingDirectory,
                openGrokHome: openGrokHome,
                sessionID: sessionID,
                connections: mcpServers,
                environment: environment
            )))
        case .agentsModal(let initialTab):
            // `/config-agents` (alias `/agents`) and `/personas` — the
            // read-only agents/personas modal (B9-b1), both tabs
            // snapshotted fresh at open (`dispatch_open_config_agents_modal`,
            // `dispatch/transcript.rs:486-531`). Mutual exclusivity runs
            // the other way too: opening agents closes extensions
            // (`transcript.rs:500-501`). Upstream additionally fires
            // `Effect::FetchSessionAgentName` for the ` active` marker
            // (`:525-530`) — the recorded B9 deferral: this port has no
            // session-agent-name channel, so only the resolved default is
            // shown.
            overlays.dismiss(id: LiveExtensionsComposition.overlayID)
            overlays.push(.agents(LiveAgentsComposition.overlay(
                initialTab: initialTab.map(LiveAgentsComposition.tab(for:)) ?? .agents,
                workingDirectory: workingDirectory,
                openGrokHome: openGrokHome,
                modelAgentType: agentsModalModelAgentType,
                environment: environment
            )))
        case .reasoningEffort(let query):
            await applyEffortCommand(query: query)
        case .fastMode:
            await applyFastCommand()
        case .sideQuestion(let question):
            await startSideQuestion(question)
        case .recap:
            await startRecap()
        case .doctor(let request):
            presentDoctor(request)
        case .renameSession(let title):
            await renameSession(title: title)
        case .loginProviderPicker:
            // Upstream's ArgPicker over `provider_items` with live secret
            // statuses (`dispatch/auth.rs:26-51`). Statuses are read fresh at
            // open so a key saved through settings shows up immediately.
            overlays.push(LiveLoginProviderPicker.overlay(
                statuses: LiveLoginProviderPicker.statuses(
                    openGrokHome: openGrokHome,
                    environment: environment
                )
            ))
        case .loginXAI:
            startXAILogin()
        case .loginCodex:
            startCodexLogin()
        case .logout(let account):
            switch account {
            case .xai:
                await performXAILogout()
            case .codex:
                startCodexLogout()
            }
        case .planModeOn:
            // Bare `/plan` — upstream `set_plan_mode(On)`
            // (`dispatch/modes.rs:122-195`): idempotent (already armed →
            // toast only, no second arm), toast via
            // `save_success_toast("Plan mode", true)` (`settings/ui.rs:89-92`),
            // mapped onto a transcript note like every toast here.
            await armPlanModeFromSlash()
        case .enterPlanMode:
            // `/plan <description>`'s mode-switch half
            // (`dispatch/modes.rs:37-120`). The controller AWAITS this render
            // before it enqueues the description, so returning with the gate
            // armed IS the port of upstream's `SetModeThenPrompt` ordering.
            // RECORDED DIVERGENCE on the note: upstream toasts nothing here —
            // its composer paints a persistent plan indicator off
            // `plan_mode_pending` — but this port has no plan chip, so a
            // silent arm would leave the mode switch with no announcement at
            // all. Cost: one transcript line upstream does not print.
            await armPlanModeFromSlash()
        case .showPlan:
            await showPlan()
        case .setSwarmMode(let enabled):
            await setSwarmModeFromSlash(enabled: enabled)
        case .swarmTaskMode:
            await enterSwarmTaskModeFromSlash()
        case .fork(let worktreeOverride, let directive):
            await performFork(worktreeOverride: worktreeOverride, directive: directive)
        case .showTasks:
            await presentTasksBlock()
        case .howtoGuides:
            // Upstream's "How-to Guides" DocPicker, toggled closed if
            // already open (`dispatch_open_howto_guides`,
            // `dispatch/settings/ui.rs:248-262`). The toggle must be
            // explicit: `overlays.push` on an existing id *replaces* the
            // overlay (resetting its filter state), it does not dismiss it.
            if overlays.dismiss(id: LiveHowtoGuidesPicker.overlayID) == nil {
                overlays.push(LiveHowtoGuidesPicker.overlay())
            }
        case .openURL(let url):
            openExternalURL(url)
        case .showDocument(let title, let content):
            overlays.push(LiveHowtoGuidesPicker.viewerOverlay(
                title: title,
                content: content
            ))
        case .openLineViewer(let path, let lineRange):
            let fileURL = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: workingDirectory)).standardizedFileURL
            let content = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            let allLines = content.split(separator: "\n", omittingEmptySubsequences: false)
            let styledLines: [PagerStyledLine]
            if let lineRange {
                let start = max(0, min(lineRange.lowerBound - 1, allLines.count))
                let end = max(start, min(lineRange.upperBound, allLines.count))
                styledLines = allLines[start..<end].map { PagerStyledLine(text: String($0)) }
            } else {
                styledLines = allLines.map { PagerStyledLine(text: String($0)) }
            }
            overlays.push(.sessionInfo(
                id: "line-viewer",
                title: path,
                lines: styledLines
            ))
        case .releaseNotes:
            await presentReleaseNotes()
        case .dismissAll:
            overlays.removeAll()
            currentPermissionRequestID = nil
        }
    }

    /// `Action::OpenUrl` for standard schemes (`dispatch/router.rs:1208-1223`
    /// → `open_url_or_show`, `dispatch/ctx.rs:43-59`): opened silently on
    /// success. The opener is the injectable `urlOpener` seam (defaults to
    /// `LivePagerAuthServices.openBrowser`), so tests substitute a capture
    /// and no real browser launches.
    ///
    /// Scheme gate is `pagerURLIsSafeToOpen` (`.standard` —
    /// http/https/mailto only), matching upstream `try_open_url` +
    /// `SchemeFilter::Standard` (`ctx.rs:52-57`, `link_opener.rs:292-296` at
    /// pin 650c1db7). Paint already drops unsafe LinkSpans; this is defense
    /// in depth for banner/CTA/docs paths. `RejectedScheme` is silent —
    /// never surface an unsafe URL as "open this manually".
    ///
    /// A composition with no opener (after the scheme passes) is this port's
    /// "browser unavailable" arm, answered with upstream's agent-view copy
    /// (`browser_unavailable_message`, `pager-render/src/link_opener.rs:52-54`)
    /// minus the best-effort clipboard leg (no OSC 52 channel here —
    /// recorded divergence; cost: SSH users copy the URL by hand).
    func openExternalURL(_ url: String) {
        guard pagerURLIsSafeToOpen(url) else { return }
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let openBrowser = urlOpener,
              let parsed = URL(string: trimmed) else {
            note("Could not open a browser. Open this URL manually:\n\(trimmed)")
            return
        }
        openBrowser(parsed)
    }

    // MARK: - /release-notes

    /// `/release-notes` — upstream `ReleaseNotesCommand::run`
    /// (`release_notes.rs:27-35`): fetch through `ChangelogManager`, show
    /// the markdown as `Action::ShowReleaseNotes { title: "Release Notes",
    /// content: trimmed }`, or answer `CommandResult::Error` with the exact
    /// offline copy. The viewer is the SAME document overlay `/docs` routes
    /// through (`LiveHowtoGuidesPicker.viewerOverlay`) — upstream's
    /// DocViewer reuse, no second render seam. The error rides `note`, this
    /// port's channel for `CommandResult::Error` (the `/docs`
    /// unknown-target precedent).
    ///
    /// The fetch re-resolves `$OPENGROK_HOME` and `GROK_CHANGELOG_OFFLINE`
    /// from this renderer's audited environment on every call (upstream
    /// re-runs `from_env_home` inside `fetch`), so a harness-injected home
    /// always wins. A composition constructed without a client gets a
    /// cache-only manager: with no transport there is nothing to fetch
    /// with, which is exactly upstream's offline arm.
    ///
    /// POST-PREFETCH, this serves the startup prefetch's stored result and
    /// does not refetch — a recorded divergence from upstream's command
    /// mechanics, kept for upstream's stated intent. Upstream's prefetch
    /// comment says it exists so "/release-notes uses the cached result"
    /// (`app/event_loop.rs:1811-1812` at pin 650c1db7), but its command
    /// re-runs `ChangelogManager::new().fetch()` (`release_notes.rs:26`) —
    /// a fresh CDN round-trip whose "cached result" is only the warm DISK
    /// fallback when the CDN is unreachable (a 3 s stall when offline, per
    /// invocation). Upstream's welcome CTA and menu row already serve the
    /// in-memory copy (`app_view.rs:4380-4388`, `:4607-4614`); this port
    /// unifies the command on the same store. Cost of the divergence: a
    /// changelog republished to the CDN mid-session is not picked up by a
    /// later /release-notes in that session — bounded to nil in practice,
    /// because the artifact is version-keyed (`{VERSION}.external.md`) and
    /// this binary's version does not change mid-session. Awaiting the
    /// in-flight prefetch (never nil after `begin()`) keeps a command
    /// racing the startup fetch deterministic instead of double-fetching.
    func presentReleaseNotes() async {
        await changelogPrefetch?.value
        let markdown: String?
        if let prefetched = changelogMarkdown {
            markdown = prefetched
        } else {
            let manager = changelog ?? ChangelogManager.fromEnvironment(environment)
            markdown = await manager.fetch(environment: environment).markdown
        }
        guard let markdown else {
            // Byte-exact upstream copy (release_notes.rs:33).
            note("No release notes available (offline).")
            return
        }
        overlays.push(LiveHowtoGuidesPicker.viewerOverlay(
            title: "Release Notes",
            content: markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        ))
    }

    /// Apply a decision the settings modal made.
    ///
    /// A failed write is reported into the transcript rather than swallowed: the
    /// modal has already redrawn the row as changed, so silence would leave the
    /// screen disagreeing with the disk.
    func applySettingsEvent(_ event: PagerSettingsEvent) async {
        let store = PagerSettingsStore(
            configPath: openGrokHome.appendingPathComponent("config.toml")
        )
        switch event {
        case .preview(let key, let value):
            // Only the theme rows preview, and a preview is display-only.
            guard key == "theme" || key == "auto_dark_theme" || key == "auto_light_theme",
                  case .string(let name) = value
            else { return }
            _ = applyTheme(named: name)

        case .commit(let key, let value):
            if key == "theme", case .string(let name) = value {
                _ = applyTheme(named: name)
            }
            do {
                // Defense in depth: keep_text_selection always goes through
                // the atomic legacy-clearing write (settings_writes.rs:528-536).
                if key == "keep_text_selection", case .string(let choice) = value {
                    let mode = PagerKeepTextSelectionMode.fromCanonical(choice) ?? .flash
                    try store.writeKeepTextSelection(mode.canonical)
                    reloadCatalogInput()
                    return
                }
                try store.write(key: key, value: value)
                reloadCatalogInput()
            } catch PagerSettingsStoreError.notPersistable {
                // Session-local rows have no disk home by design; the modal's
                // own copy is the whole of their state.
                return
            } catch {
                appendMessage(PagerMessage(
                    role: .error,
                    text: "Could not save \(key): \(error)"
                ))
            }

        case .toggleMultiSelect(let key, let choice, let enabled):
            var current = (try? store.loadMultiSelect(key: key)) ?? []
            if enabled { current.insert(choice) } else { current.remove(choice) }
            do {
                try store.writeMultiSelect(key: key, enabled: current)
                reloadCatalogInput()
            } catch {
                appendMessage(PagerMessage(
                    role: .error,
                    text: "Could not save \(key): \(error)"
                ))
            }

        case .resetRequested(let key):
            // A secret row's reset is a credential *removal*, not a config
            // write — upstream maps `SecretStatus::Missing` to the provider's
            // Clear action (`dispatch/settings/ui.rs:1447-1448`). Routed here
            // because `store.reset` classifies secret rows `notPersistable`
            // and would silently swallow the request.
            if let meta = PagerSettingsRegistry.default.entries.first(where: { $0.key == key }),
               case .secretStore = meta.storage {
                applySecret(key: key, value: "")
                return
            }
            do {
                // keep_text_selection reset also clears legacy keys in one
                // write so word_select / duration 0 cannot resurrect.
                if key == "keep_text_selection" {
                    try store.resetKeepTextSelection()
                    reloadKeepTextSelectionFromEffectiveConfig()
                    reloadCatalogInput()
                    return
                }
                try store.reset(key: key)
                if key == "theme" { _ = applyTheme(named: "groknight") }
                // A confirmed reset re-derives the render value from the
                // registered default, upstream's reset-confirm path
                // (`ui.rs:1504`: rollback/reset routes through
                // `set_compact_mode_inner`). The default is `false`
                // (`ui_config.rs:339`).
                if key == "compact_mode" { userCompactMode = false }
                // Same path for timestamps (`ui.rs:1505`:
                // `set_timestamps_inner`); the default is `true` — the key is
                // `Option<bool>` with `None` read as on (`ui_config.rs:110`,
                // `defs.rs:666-667` `unwrap_or(true)`).
                if key == "show_timestamps" { userShowTimestamps = true }
                // Same path for the timeline rail (`ui.rs:1506`:
                // `set_timeline_inner`); the default is `false` — opt-in,
                // `SHOW_TIMELINE_DEFAULT` (`ui_config.rs:392`, resolved by
                // `show_timeline_enabled()`, the row default's single source
                // `defs.rs:680-681`).
                if key == "show_timeline" { userShowTimeline = false }
                // Same path for page-flip (`ui.rs:1510`: `set_page_flip_on_send_inner`);
                // the default is `true` — absent means on (`ui_config.rs:407-411`,
                // `defs.rs:698-699` `page_flip_on_send_enabled()`).
                if key == "page_flip_on_send" { userPageFlipOnSend = true }
                // Scroll keys: only after the user-file leaf is cleared,
                // re-resolve effective `[ui]` so a project/managed value
                // under that key becomes live. Do not invent registry
                // defaults here — unset means profile / lower-layer merge.
                if Self.scrollSettingKeys.contains(key) {
                    reloadScrollSettingsFromEffectiveConfig()
                }
                reloadCatalogInput()
            } catch PagerSettingsStoreError.notPersistable {
                return
            } catch {
                appendMessage(PagerMessage(
                    role: .error,
                    text: "Could not reset \(key): \(error)"
                ))
            }

        case .secret(let key, let value):
            applySecret(key: key, value: value)
        }
    }

    /// Persist a settings-modal secret into the owner-protected auth store —
    /// the SAME store the live credential resolver reads
    /// (`readProviderAPIKey` over `providerAPIKeyScope`, Storage.swift:183),
    /// never `config.toml`. An empty value removes the key (upstream
    /// `SecretStatus::Missing` → the Clear action, ui.rs:1447-1448; write
    /// path `store_provider_api_key` / `clear_provider_api_key`,
    /// effects/mod.rs:832-843).
    func applySecret(key: String, value: String) {
        guard let meta = PagerSettingsRegistry.default.entries.first(where: { $0.key == key }),
              case .secretStore(let account) = meta.storage
        else {
            appendMessage(PagerMessage(
                role: .error,
                text: "Setting \(key) has no secret storage; nothing was saved."
            ))
            return
        }
        // Row account → auth.json scope. Kimi Platform deliberately reuses
        // the historical `kimi::api_key` scope so existing logins keep
        // working (`kimi_api_key_scope`, ProviderScopes.swift:46-51); every
        // other account is its provider's own `<provider>::api_key`.
        let scope = account == "kimi_platform"
            ? kimiAPIKeyScope(.platform)
            : providerAPIKeyScope(account)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if trimmed.isEmpty {
                try clearScopedAPIKey(grokHome: openGrokHome, scope: scope)
                note("Removed \(meta.label). New sessions and model switches no longer see it.")
            } else {
                try storeScopedAPIKey(grokHome: openGrokHome, scope: scope, apiKey: trimmed)
                note("Saved \(meta.label). It applies to new sessions and model switches; "
                    + "the running session keeps its current credential.")
            }
        } catch {
            appendMessage(PagerMessage(
                role: .error,
                text: "Could not save \(meta.label): \(error)"
            ))
            return
        }
        // Make the change visible to the catalog publish gate and kick the
        // background refresh, mirroring upstream's post-store
        // `apply_meta_models` (effects/mod.rs:844-861). KNOWN DEFERRAL: the
        // upstream rebind of LIVE sessions after a credential change
        // (task_result.rs:1087-1300) is not ported — the new key reaches new
        // sessions and `/model` switches only. Effort/tier reconcile against
        // the refreshed catalog still runs (model_state.rs:155-192).
        catalogStore?.refreshCredentialSnapshot()
        catalogStore?.spawnBackgroundRefresh()
        Task { await self.reconcileModelStateAfterCatalogRefresh() }
    }

    func reloadCatalogInput() {
        guard let catalogStore else { return }
        catalogStore.updateInput(liveCatalogResolutionInput(
            workingDirectory: URL(fileURLWithPath: workingDirectory, isDirectory: true),
            environment: ProcessInfo.processInfo.environment
        ))
    }

    /// Repaint through the coalesced path: however many state changes arrive
    /// inside one paint-cadence window fold into a single frame, and a folded
    /// frame is guaranteed to paint by the one-shot flush timer. This is the
    /// other half of the animation ticker — 30 fps of ticks plus per-event
    /// repaints must not become 30+ paints per second.
    func renderState() throws {
        if let minimalHost {
            // The minimal frame program consumes the STATE, not laid-out
            // cells: commits and the live region are its own ordered walk
            // (lib.rs:91-108). Mouse-geometry bookkeeping is skipped —
            // minimal is keyboard-only by design (guard.rs stance). Frame
            // coalescing is the renderer's; the host paints per event and
            // relies on `insertBefore`'s print-once frontier for the heavy
            // rows (recorded in the ledger with its cost).
            // Upstream `draw_inner` returns before FPS overlay/record
            // (`app_view.rs:4850-4854`). `/debug fps` may still toggle.
            lastLaidOutFpsHud = nil
            lastPaintedFpsHud = nil
            minimalHost.draw(renderState(conversation: conversation.items))
            lastPaintedToast = lastLaidOutToast
            publishMotionState()
            return
        }
        if !(try paintCurrentFrame(at: clockNow(), flush: false)) {
            // Only a real paint may refresh mouse hit caches — a coalesced
            // request must not claim unpainted geometry.
            armFlushTimerIfNeeded()
        }
        publishMotionState()
    }

    /// Layout + terminal request/flush. FPS wall time starts *before*
    /// `renderPagerFrame` and ends after writer handoff; `record` only when
    /// the report is non-nil. Coalesced / action-time layouts do not record.
    /// After a committed paint, refresh the overlay cache for a *future*
    /// frame (one-frame lag / pinned sampling).
    @discardableResult
    func paintCurrentFrame(at now: TimeInterval, flush: Bool) throws -> Bool {
        let measure = fpsHud.isEnabled
        let started = measure ? Self.monotonicNow() : nil
        let result = layOutCurrentFrame()
        let painted = try submitPaint(result, at: now, flush: flush)
        if painted, let started {
            fpsHud.record(Self.monotonicNow() - started)
            fpsHudRecordCount += 1
            fpsHud.refreshOverlayCache(now: clockNow())
        }
        return painted
    }

    /// Run the frame function and refresh scroll-state bookkeeping. Split
    /// out of `renderState` because the flush timer re-lays-out at flush
    /// time — a folded frame must paint the *latest* state, not the one
    /// that was folded. Does **not** update last-painted mouse geometry;
    /// that waits for `recordPaintedGeometry` after a non-nil paint.
    func layOutCurrentFrame() -> PagerRenderResult {
        if let index = pageFlipUserBlockIndex {
            try? revealBlock(at: index)
        }
        let result = renderPagerFrame(renderState(conversation: conversation.items))
        // Max-scroll / follow-tail are scroll *state*, not hit geometry —
        // they must track the latest layout even when the paint coalesces,
        // or the viewport drifts from content growth.
        lastConversationHeight = max(1, result.layout.conversation.height)
        lastMaximumScrollOffset = max(
            0,
            result.layout.totalContentLines - result.layout.conversation.height
        )
        if followsBottom { scrollOffset = lastMaximumScrollOffset }
        return result
    }

    /// Replace-wholesale the last-painted mouse caches (overlay / rail /
    /// banner / context bar / conversation hit / scrollbar / composer /
    /// links / sticky header rows for probes). Call only when
    /// `requestFrame` or `flushPendingFrame` returned a report — never on
    /// a coalesced nil, or clicks map against geometry the user has not
    /// seen. PageUp/PageDown do **not** read `lastHeaderScreenRows`.
    func recordPaintedGeometry(_ result: PagerRenderResult) {
        lastOverlayBounds = result.overlays
        lastTimelineRail = result.layout.timelineRail
        lastPrivacyBannerHits = result.layout.privacyBanner
        lastContextBarRect = result.layout.contextBar
        lastConversationHit = result.layout.conversationHit
        lastScrollbarHit = result.layout.scrollbarHit
        lastComposerHit = result.layout.composerHit
        if let hit = result.layout.composerHit {
            lastKnownComposerContentRect = hit.contentRect
        }
        lastPaintedLinks = result.links
        // Replace-wholesale — never merge with a prior frame's ranges.
        lastTextSelection = result.layout.textSelection
        // Painted sticky header rows for mouse/probes only. Page scroll
        // recomputes at action time via `currentPageScrollRows`.
        lastHeaderScreenRows = result.layout.headerScreenRows
        lastPaintedFpsHud = lastLaidOutFpsHud
        lastPaintedToast = lastLaidOutToast
        lastToastOccluder = result.layout.toastOccluder
    }

    /// Map a scrollbar-track screen row onto transcript scroll state using
    /// last-painted geometry. Bottom cell re-engages follow
    /// (`goto_bottom`, `nav.rs:540-546`); every other cell clears it
    /// (`goto_top` / `set_scroll_offset`).
    func applyScrollbarClick(screenY: Int, geometry: PagerScrollbarHitModel) {
        let offset = geometry.offset(atScreenY: screenY)
        let maximumOffset = max(0, geometry.totalContentLines - geometry.viewportHeight)
        scrollOffset = min(maximumOffset, max(0, offset))
        followsBottom = geometry.isBottomCell(atScreenY: screenY)
    }

    func clearScrollbarDragLatch() {
        scrollbarDragging = false
    }

    /// Arm a one-shot timer for `renderer.scheduledFrameAt`. Idempotent: at
    /// most one flush is ever pending, and a fresh request folded while one
    /// is armed rides the same flush. Suspend hold and restore both block
    /// arming — a cancelled timer must not be replaced while the child owns
    /// the tty or after teardown.
    func armFlushTimerIfNeeded() {
        guard !restored,
              !localMotionHold,
              pendingFlushTask == nil,
              let scheduled = renderer.scheduledFrameAt
        else { return }
        let delay = max(0, scheduled - Self.monotonicNow())
        pendingFlushGeneration &+= 1
        let generation = pendingFlushGeneration
        // Inherits this actor's isolation; the sleep suspends without
        // holding it. Exit on cancellation so `cancelPendingFlushTask`'s
        // await cannot deadlock waiting for a post-sleep paint hop.
        pendingFlushTask = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000) + 1_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self.flushPendingFrameNow(generation: generation)
        }
    }

    func flushPendingFrameNow(generation: UInt64? = nil) {
        if let generation, generation != pendingFlushGeneration {
            return
        }
        pendingFlushTask = nil
        guard !restored, !localMotionHold, renderer.scheduledFrameAt != nil else { return }
        // A throw here has the same recovery as the next event's repaint;
        // surfacing it has no channel that would not kill the run.
        _ = try? paintCurrentFrame(at: Self.monotonicNow(), flush: true)
        // Not yet due (the timer raced a fresher fold): re-arm rather than
        // drop the frame — but never while held/restored.
        armFlushTimerIfNeeded()
    }

    /// Test-only flush at an injected monotonic `now` so a long `paintCadence`
    /// can be forced due. Relays out latest state, records painted geometry
    /// on a non-nil report, and does **not** re-arm the wall-clock flush timer
    /// (production `flushPendingFrameNow` still rearms).
    /// Returns whether a paint report was recorded.
    @discardableResult
    func flushPendingFrame(at now: TimeInterval) -> Bool {
        pendingFlushTask = nil
        guard !restored, !localMotionHold, renderer.scheduledFrameAt != nil else { return false }
        return (try? paintCurrentFrame(at: now, flush: true)) == true
    }

    /// Submit a laid-out frame to the terminal renderer. Returns whether this
    /// request actually painted (not coalesced / not-yet-due). FPS duration
    /// is measured by `paintCurrentFrame` around layout+this handoff.
    @discardableResult
    func submitPaint(
        _ result: PagerRenderResult,
        at now: TimeInterval,
        flush: Bool
    ) throws -> Bool {
        let report: PagerTerminalRenderReport?
        if flush {
            report = try renderer.flushPendingFrame(result, at: now)
        } else {
            report = try renderer.requestFrame(result, at: now)
        }
        guard report != nil else { return false }
        recordPaintedGeometry(result)
        return true
    }

    /// Monotonic seconds for the paint clock. Only ever compared against
    /// itself, so the epoch (process uptime) does not matter.
    static func monotonicNow() -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    // MARK: - Animation

    /// One wall-clock tick from the controller's motion ticker: sample the
    /// clock into the frame state and repaint through the coalesced path.
    func renderAnimationTick(_ frame: OpenGrokPagerAnimationFrame) async throws {
        // Suspended child or post-restore teardown: ticks that interleave at
        // an await must not mutate the motion clock or paint. Distinct from
        // `motionEnabled` — that is capability, this is lifecycle.
        guard !localMotionHold, !restored else { return }
        motion = PagerMotionSnapshot(
            tick: frame.tick,
            seconds: frame.seconds,
            enabled: motionEnabled
        )
        // Re-anchor every painted tick so idle extrapolation stays on the
        // same epoch as `PagerMotionSnapshot.seconds`.
        noteMotionClockAnchor(seconds: frame.seconds)
        if frame.demand == .slow {
            // The welcome shimmer advances at 12 fps of *frames*; a slow tick
            // that lands inside the same shimmer frame would repaint an
            // identical screen (app_view.rs:5760-5766).
            let shimmerFrame = PagerMotion.shimmerFrame(atSeconds: frame.seconds)
            guard shimmerFrame != lastShimmerFrame else { return }
            lastShimmerFrame = shimmerFrame
        }
        try renderState()
    }

    /// Relative delay until the next mouse-scroll flush, text-drag
    /// autoscroll tick, or transient-toast expiry. Returns the min of those
    /// remaining delays. Restore / local suspend return `nil` (stream
    /// cancelled, toast does not tick). A capturing overlay still returns
    /// remaining toast TTL so idle expiry does not wait on user input.
    func scrollClockDeadline(at now: TimeInterval) async -> TimeInterval? {
        if restored || localMotionHold {
            mouseScrollState.cancelStream()
            dragAutoscroll = nil
            return nil
        }
        let toastDelay = remainingTransientToastDelay(at: now)
        if overlays.isActive {
            mouseScrollState.cancelStream()
            dragAutoscroll = nil
            return toastDelay
        }
        let scrollDeadline = mouseScrollState.deadline(now: now)
        let autoscrollDeadline: TimeInterval? =
            (activeTextDrag != nil && dragAutoscroll != nil)
            ? Self.textDragAutoscrollCadence
            : nil
        return minNonnilDelay(scrollDeadline, autoscrollDeadline, toastDelay)
    }

    /// One wake of the dedicated scroll clock. Applies residual signed lines
    /// and/or text-drag edge autoscroll; expires a due transient toast and
    /// repaints so sticky can return without user input. The controller
    /// re-queries the deadline.
    func handleScrollClockTick(at now: TimeInterval) async throws {
        _ = try await tickScrollClock(at: now)
    }

    /// Shared scroll-clock body (protocol + test seam). Restore/suspend stay
    /// quiet. Overlay capturing still expires toast. Toast expiry paints
    /// immediately so a coalesced fold cannot leave the expired banner on
    /// screen until the next keystroke.
    @discardableResult
    func tickScrollClock(at now: TimeInterval) async throws -> Int {
        if restored || localMotionHold {
            mouseScrollState.cancelStream()
            dragAutoscroll = nil
            return 0
        }
        let toastExpired = expireTransientToast(at: now)
        if overlays.isActive {
            mouseScrollState.cancelStream()
            dragAutoscroll = nil
            if toastExpired {
                try await paintImmediately()
            }
            return 0
        }
        let lines = try applyScrollClockTick(at: now)
        try applyTextDragAutoscrollTick()
        if toastExpired {
            try await paintImmediately()
        }
        return lines
    }

    func lastComposerContentRect() async -> TextAreaRect? {
        lastComposerHit?.contentRect ?? lastKnownComposerContentRect
    }

    func copyToClipboard(_ text: String) async throws {
        copyTextSelectionToClipboard(text)
    }

    /// Motion-clock "now": last anchored seconds plus monotonic time since
    /// that anchor. `begin()` seeds the anchor at seconds 0 so idle before
    /// the first painted tick still advances; each `renderAnimationTick`
    /// re-anchors to the controller frame's seconds.
    func currentMotionSeconds() -> TimeInterval {
        guard motionEnabled, let anchorMonotonic = motionClockAnchorMonotonic else {
            return motion.seconds
        }
        let delta = Self.monotonicNow() - anchorMonotonic
        return motionClockAnchorSeconds + max(0, delta)
    }

}
