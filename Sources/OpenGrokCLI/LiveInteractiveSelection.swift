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

    // MARK: - Global chords

    /// Route an application-level chord.
    func applyGlobal(_ command: OpenGrokPagerGlobalCommand) async throws {
        switch command {
        case .commandPalette:
            try await present(.commandPalette(rows: []))
        case .shortcutsHelp:
            try await present(.shortcutsHelp)
        case .modelPicker:
            try await present(.modelPicker(query: nil))
        case .toggleQueue:
            try await present(.promptQueue(entries: []))
        case .cyclePermissionMode:
            guard let permissionMode else { return }
            if let notice = await permissionMode.cyclePermissionMode() {
                appendMessage(PagerMessage(role: .system, text: notice))
            }
            permissionModeFlags = await permissionMode.composerFlags()
            try renderState()
        case .toggleAlwaysApprove:
            guard let permissionMode else { return }
            if let notice = await permissionMode.toggleAlwaysApprove() {
                appendMessage(PagerMessage(role: .system, text: notice))
            }
            permissionModeFlags = await permissionMode.composerFlags()
            try renderState()
        case .openExtensions:
            // `Ctrl+L` — upstream opens the extensions modal on the Plugins
            // tab (`agent_view/input.rs:1266-1271`).
            try await present(.extensions(tab: .plugins))
        case .toggleTasks:
            // Ctrl+G (`defaults.rs:44-55`) — minimal has no pane surface
            // (upstream's Ctrl+G means external editor there; toggling state
            // nothing paints would be the dead-key class), and a modal owns
            // the keys while active. EXCEPT the roster: in-dashboard Ctrl+G
            // toggles GROUPING (`defaults.rs:997-1017` scopes the binding
            // over the global while the dashboard has focus) and persists.
            guard minimalHost == nil else { return }
            if overlays.focused?.id == LiveDashboardOverlay.overlayID {
                dashboardState.toggleGrouping()
                rebuildDashboardRows()
                persistDashboardState()
                try renderState()
                return
            }
            guard !overlays.isActive else { return }
            try await toggleTasksPane()
        case .toggleTodos:
            guard !overlays.isActive else { return }
            if minimalHost == nil {
                todoPaneVisible.toggle()
            } else {
                todoPaneVisible = true
                todoForceVisible.toggle()
            }
            await refreshTodoPane()
            try renderState()
        case .toggleTodoCompleted:
            guard !overlays.isActive else { return }
            todoPaneVisible = true
            todoShowCompleted.toggle()
            await refreshTodoPane()
            try renderState()
        case .openDashboard:
            try await presentDashboard()
        case .sendToBackground, .newSession,
             .openSettings, .openSessions:
            // Unbound in the controller's key table until the backing surface
            // exists, so these arrive only from a caller that built them by
            // hand. Nothing to do beats a misleading approximation.
            break
        }
    }

    /// Resolve kind from the frozen sidecar (hysteresis via `prev`).
    /// Border / malformed / missing geometry → linear.
    func resolveDragKind(
        anchor: PagerTextRangeHit,
        head: PagerTextRangeHit,
        prev: PagerTextSelectionKind
    ) -> PagerTextSelectionKind {
        let geom = matchingTableGeometry(
            entryIndex: anchor.entryIndex,
            rangeID: anchor.rangeID
        )
        return pagerResolveTableDragKind(geom, anchor: anchor, head: head, prev: prev)
    }

    /// Table copy when kind is table-shaped and the frozen sidecar still
    /// matches the copy model exactly. A valid reconstruct of `""` stays on
    /// the table path (empty cell / padding). Linear fallback only when
    /// geometry is missing or stale (`nil`), never because the text is empty.
    func reconstructDragCopy(
        model: PagerTextSelectionModel,
        drag: PagerActiveTextDrag
    ) -> (text: String, kind: PagerTextSelectionKind)? {
        switch drag.kind {
        case .linear:
            break
        case .tableCell, .tableGrid:
            if let geom = matchingTableGeometry(
                entryIndex: drag.anchor.entryIndex,
                rangeID: drag.anchor.rangeID
            ) {
                let detected = pagerDetectTableGeometry(
                    in: model,
                    entryIndex: drag.anchor.entryIndex,
                    rangeID: drag.anchor.rangeID,
                    atLine: drag.anchor.blockLineIndex
                )
                if detected == geom,
                   let text = pagerReconstructSelectionText(
                    model: model,
                    drag: drag,
                    table: geom
                   )
                {
                    return (text, drag.kind)
                }
            }
            tableSelectionGeometry = nil
            var linear = drag
            linear.kind = .linear
            guard let text = pagerReconstructSelectionText(model: model, drag: linear),
                  !text.isEmpty
            else { return nil }
            return (text, .linear)
        }
        guard let text = pagerReconstructSelectionText(model: model, drag: drag),
              !text.isEmpty
        else { return nil }
        return (text, .linear)
    }
    func clearPersistentTextSelectionHighlight() -> Bool {
        let had = persistentTextSelection != nil
        persistentTextSelection = nil
        tableSelectionGeometry = nil
        textSelectionFlashDeadlineMs = nil
        textSelectionCreatedAtMs = nil
        textSelectionFlashGeneration &+= 1
        if let task = textSelectionFlashTask {
            textSelectionFlashTask = nil
            task.cancel()
        }
        return had
    }

    /// Cancel flash Task and invalidate generation (restore/shutdown). Does
    /// not clear a held highlight by itself — callers that tear down the
    /// screen also nil `persistentTextSelection` / deadline.
    func cancelTextSelectionFlashTask() async {
        let task = textSelectionFlashTask
        textSelectionFlashTask = nil
        textSelectionFlashGeneration &+= 1
        task?.cancel()
        await task?.value
    }

    /// Suspend-path flash cancel: drop the Task but keep highlight + deadline
    /// so resume can reconcile without stranding or painting under hold.
    func suspendTextSelectionFlashTask() async {
        let task = textSelectionFlashTask
        textSelectionFlashTask = nil
        task?.cancel()
        await task?.value
    }

    /// After child restore / park abort: if flash deadline elapsed while
    /// suspended, clear; else re-arm remaining TTL. No-op when hold/word_select
    /// or no deadline.
    func reconcileTextSelectionFlashAfterResume() {
        guard persistentTextSelection != nil, !keepTextSelectionMode.holds else { return }
        guard let deadline = textSelectionFlashDeadlineMs else { return }
        if textSelectionNowMs() >= deadline {
            persistentTextSelection = nil
            tableSelectionGeometry = nil
            textSelectionFlashDeadlineMs = nil
            textSelectionCreatedAtMs = nil
            textSelectionFlashGeneration &+= 1
            if !localMotionHold, !restored {
                try? renderState()
            }
            return
        }
        textSelectionFlashGeneration &+= 1
        armTextSelectionFlashExpiryTask(generation: textSelectionFlashGeneration)
    }

    /// Drag motion: promote pending (≥1), convert deferred chrome→text, or
    /// update active head + autoscroll (`handle_scrollback_drag_motion`).
    /// Returns `true` when the gesture was owned by text selection.
    func handleTextSelectionDragMotion(_ event: MouseEvent) throws -> Bool {
        if activeTextDrag != nil {
            updateActiveTextDrag(col: event.x, row: event.y)
            try renderState()
            return true
        }
        if convertDeferredTextPress(col: event.x, row: event.y) {
            // Text wins over deferred block — clear block/link pending.
            pendingScrollbackClick = nil
            pendingLinkClick = nil
            try renderState()
            return true
        }
        if let pending = pendingTextDrag,
           pagerTextDragThresholdExceeded(pending: pending, col: event.x, row: event.y)
        {
            let model = lastTextSelection
            let head = model?.hitTestNearestInRange(
                anchor: pending.anchor,
                col: event.x,
                row: event.y
            ) ?? pending.anchor
            armTextDrag(
                anchor: pending.anchor,
                head: head,
                anchorContentWidth: pending.anchorContentWidth,
                col: event.x,
                row: event.y
            )
            pendingTextDrag = nil
            deferredTextPress = nil
            pendingScrollbackClick = nil
            pendingLinkClick = nil
            try renderState()
            return true
        }
        if pendingTextDrag != nil || deferredTextPress != nil {
            // Below threshold / deferred miss — own the gesture so block
            // click is not cleared until promote or chrome→text convert.
            return true
        }
        return false
    }

    func armTextDrag(
        anchor: PagerTextRangeHit,
        head: PagerTextRangeHit,
        anchorContentWidth: Int?,
        col: Int,
        row: Int
    ) {
        // Prefer the press-time freeze (pending path); deferred chrome→text
        // arms without a prior freeze and snapshots here.
        if frozenDragTextSelection == nil {
            frozenDragTextSelection = lastTextSelection
        }
        let detectModel = frozenDragTextSelection ?? lastTextSelection
        tableSelectionGeometry = computeDragTableGeometry(anchor: anchor, model: detectModel)
        let kind = resolveDragKind(anchor: anchor, head: head, prev: .linear)
        activeTextDrag = PagerActiveTextDrag(
            anchor: anchor,
            head: head,
            kind: kind,
            anchorContentWidth: anchorContentWidth
        )
        lastDragPointer = (col, row)
        refreshDragAutoscroll(mouseRow: row)
        mouseScrollState.cancelStream()
    }

    func updateActiveTextDrag(
        col: Int,
        row: Int,
        liveModel: PagerTextSelectionModel? = nil
    ) {
        guard var drag = activeTextDrag else { return }
        // Prefer an explicit action-time model (autoscroll after scrollOffset
        // change); fall back to last-painted for ordinary drag motion.
        let live = liveModel ?? lastTextSelection
        // Resolve the head against the live (possibly scrolled/reflowed)
        // model, then translate into frozen wrap identity via joined-text
        // UTF-8 offsets.
        let liveAnchor: PagerTextRangeHit
        if let frozen = frozenDragTextSelection, let live {
            liveAnchor = pagerMapTextHit(drag.anchor, from: frozen, to: live) ?? drag.anchor
        } else {
            liveAnchor = drag.anchor
        }
        let liveHead = live?.hitTestNearestInRange(
            anchor: liveAnchor,
            col: col,
            row: row
        ) ?? drag.head
        if let frozen = frozenDragTextSelection, let live,
           let mapped = pagerMapTextHit(liveHead, from: live, to: frozen)
        {
            drag.head = mapped
        } else {
            drag.head = liveHead
        }
        drag.kind = resolveDragKind(anchor: drag.anchor, head: drag.head, prev: drag.kind)
        activeTextDrag = drag
        lastDragPointer = (col, row)
        refreshDragAutoscroll(mouseRow: row, model: live)
    }

    func refreshDragAutoscroll(
        mouseRow: Int,
        model: PagerTextSelectionModel? = nil
    ) {
        // Full conversation pane (sticky included) — upstream uses
        // `pane_areas.scrollback`, not the sticky-excluded content band.
        guard let model = model ?? lastTextSelection else {
            dragAutoscroll = nil
            return
        }
        dragAutoscroll = pagerComputeTextSelectionAutoscroll(
            mouseRow: mouseRow,
            contentArea: model.conversationArea
        )
    }

    func finishActiveTextDrag(
        _ event: MouseEvent
    ) throws -> OpenGrokPagerInputRouting {
        switch event.resolvedButton {
        case .left, .none:
            break
        case .middle, .right, .other:
            clearTextSelectionLatches()
            tableSelectionGeometry = nil
            pendingScrollbackClick = nil
            return .consumed
        }
        guard let drag = activeTextDrag else {
            clearTextSelectionLatches()
            return .consumed
        }
        // Prefer frozen arm-time model (uses `anchorContentWidth` wrap). Fall
        // back to last-painted only when freeze was unavailable.
        let copyModel = frozenDragTextSelection ?? lastTextSelection ?? PagerTextSelectionModel()
        var copyDrag = drag
        if let frozen = frozenDragTextSelection, let live = lastTextSelection {
            // Endpoints are stored in frozen identity; if a head somehow
            // remained live-only, map it before reconstruct.
            if pagerAbsoluteTextUTF8Offset(in: frozen, hit: drag.head) == nil,
               let mapped = pagerMapTextHit(drag.head, from: live, to: frozen)
            {
                copyDrag.head = mapped
            }
            if pagerAbsoluteTextUTF8Offset(in: frozen, hit: drag.anchor) == nil,
               let mapped = pagerMapTextHit(drag.anchor, from: live, to: frozen)
            {
                copyDrag.anchor = mapped
            }
        }
        let copied = reconstructDragCopy(model: copyModel, drag: copyDrag)
        let entryIndex = copyDrag.anchor.entryIndex
        clearTextSelectionLatches(droppingOrphanSidecar: false)
        pendingScrollbackClick = nil
        pendingLinkClick = nil
        guard let copied else {
            tableSelectionGeometry = nil
            try renderState()
            return .consumed
        }
        // Empty table reconstruct is a valid table path: no OSC52, no persist
        // chrome. Linear fallback already happened only on nil geometry.
        if copied.text.isEmpty {
            tableSelectionGeometry = nil
            try renderState()
            return .consumed
        }
        copyTextSelectionToClipboard(copied.text)
        // Persist highlight in live-model identity when available so paint
        // after reflow still lands on the copied span. Kind is the copied
        // shape (linear when a table copy fell through).
        var persistDrag = PagerActiveTextDrag(
            anchor: copyDrag.anchor,
            head: copyDrag.head,
            kind: copied.kind,
            anchorContentWidth: copyDrag.anchorContentWidth
        )
        if let live = lastTextSelection,
           let liveAnchor = pagerMapTextHit(copyDrag.anchor, from: copyModel, to: live),
           let liveHead = pagerMapTextHit(copyDrag.head, from: copyModel, to: live)
        {
            persistDrag.anchor = liveAnchor
            persistDrag.head = liveHead
        }
        let persistKind = persistableSelectionKind(
            persistDrag.kind,
            entryIndex: persistDrag.anchor.entryIndex,
            rangeID: persistDrag.anchor.rangeID
        )
        if !isTableShaped(persistKind) {
            tableSelectionGeometry = nil
        }
        persistDrag.kind = persistKind
        let persistent = PagerPersistentTextSelection(
            entryIndex: persistDrag.anchor.entryIndex,
            rangeID: persistDrag.anchor.rangeID,
            anchor: PagerTextSelectionEndpoint(
                blockLineIndex: persistDrag.anchor.blockLineIndex,
                colWithinRange: persistDrag.anchor.colWithinRange
            ),
            head: PagerTextSelectionEndpoint(
                blockLineIndex: persistDrag.head.blockLineIndex,
                colWithinRange: persistDrag.head.colWithinRange
            ),
            origin: .drag,
            kind: persistKind
        )
        setPersistentTextSelection(persistent)
        var focusScrollback = false
        if conversation.items.indices.contains(entryIndex),
           conversation.items[entryIndex].isMouseSelectable
        {
            selection.select(at: entryIndex, itemCount: conversation.items.count)
            followsBottom = false
            focusScrollback = true
        }
        try renderState()
        return focusScrollback ? .focusScrollback : .consumed
    }

    func selectWholeTableAt(
        _ hit: PagerTextRangeHit,
        sidecar: PagerTableSelectionGeometry,
        model: PagerTextSelectionModel,
        nowMs: UInt64,
        clickCount: UInt8
    ) throws -> Bool {
        let geom = sidecar.geometry
        guard geom.rowCount > 0, geom.columnCount > 0 else { return false }
        let anchorCell = PagerTableCellRef(row: 0, col: 0)
        let headCell = PagerTableCellRef(row: geom.rowCount - 1, col: geom.columnCount - 1)
        guard let range = model.range(entryIndex: hit.entryIndex, rangeID: hit.rangeID)
        else { return false }
        var texts: [Int: String] = [:]
        texts.reserveCapacity(range.lines.count)
        for line in range.lines {
            texts[line.blockLineIndex] = line.text
        }
        let clipboard = geom.gridTSV(anchorCell, headCell, textAt: { texts[$0] })
        let first = geom.rowLines(0)
        let last = geom.rowLines(headCell.row)
        let lastBand = geom.band(headCell.col)
        tableSelectionGeometry = sidecar
        let persistent = PagerPersistentTextSelection(
            entryIndex: hit.entryIndex,
            rangeID: hit.rangeID,
            anchor: PagerTextSelectionEndpoint(
                blockLineIndex: first.lowerBound,
                colWithinRange: geom.band(0).lowerBound
            ),
            head: PagerTextSelectionEndpoint(
                blockLineIndex: max(last.lowerBound, last.upperBound - 1),
                colWithinRange: max(lastBand.lowerBound, lastBand.upperBound - 1)
            ),
            origin: .tripleClick,
            kind: .tableGrid(anchor: anchorCell, head: headCell)
        )
        if !clipboard.isEmpty {
            copyTextSelectionToClipboard(clipboard)
        }
        setPersistentTextSelection(persistent)
        lastTextClick = pagerMakeTextClickIdentity(
            hit: hit, nowMs: nowMs, clickCount: clickCount
        )
        if conversation.items.indices.contains(hit.entryIndex),
           conversation.items[hit.entryIndex].isMouseSelectable
        {
            selection.select(at: hit.entryIndex, itemCount: conversation.items.count)
            followsBottom = false
        }
        try renderState()
        return true
    }

    func setPersistentTextSelection(_ selection: PagerPersistentTextSelection) {
        let kind = persistableSelectionKind(
            selection.kind,
            entryIndex: selection.entryIndex,
            rangeID: selection.rangeID
        )
        var stored = selection
        stored.kind = kind
        if !isTableShaped(kind) {
            tableSelectionGeometry = nil
        }
        persistentTextSelection = stored
        let created = textSelectionNowMs()
        textSelectionCreatedAtMs = created
        textSelectionFlashGeneration &+= 1
        let generation = textSelectionFlashGeneration
        if let prior = textSelectionFlashTask {
            textSelectionFlashTask = nil
            prior.cancel()
        }
        textSelectionFlashDeadlineMs = nil
        guard !keepTextSelectionMode.holds else { return }
        // Deadline is anchored to creation time (not a floating "now + TTL"
        // that forgets age across mode changes).
        textSelectionFlashDeadlineMs = created &+ pagerTextSelectionFlashTTLMs
        armTextSelectionFlashExpiryTask(generation: generation)
    }

    /// After commit/reset/reload of `keep_text_selection`: flash reconciles
    /// an existing highlight from its original `createdAt`; hold/word_select
    /// cancel the deadline but keep the highlight. No timeless flash.
    func reconcilePersistentSelectionForModeChange(now: UInt64) {
        if let prior = textSelectionFlashTask {
            textSelectionFlashTask = nil
            prior.cancel()
        }
        textSelectionFlashGeneration &+= 1

        if keepTextSelectionMode.holds {
            textSelectionFlashDeadlineMs = nil
            return
        }

        // Flash.
        guard persistentTextSelection != nil else {
            tableSelectionGeometry = nil
            textSelectionFlashDeadlineMs = nil
            textSelectionCreatedAtMs = nil
            return
        }
        guard let created = textSelectionCreatedAtMs else {
            // Missing creation time → cannot honor TTL; clear rather than
            // invent a timeless flash.
            persistentTextSelection = nil
            tableSelectionGeometry = nil
            textSelectionFlashDeadlineMs = nil
            return
        }
        if now >= created &+ pagerTextSelectionFlashTTLMs {
            persistentTextSelection = nil
            tableSelectionGeometry = nil
            textSelectionFlashDeadlineMs = nil
            textSelectionCreatedAtMs = nil
            return
        }
        textSelectionFlashDeadlineMs = created &+ pagerTextSelectionFlashTTLMs
        armTextSelectionFlashExpiryTask(generation: textSelectionFlashGeneration)
    }

    /// Arm / re-arm flash clear against `textSelectionFlashDeadlineMs`.
    /// Injected-clock tests sleep `testingFlashSleepNanos` once then re-check
    /// the deadline (no spin when the clock is frozen).
    func armTextSelectionFlashExpiryTask(generation: UInt64) {
        guard let deadline = textSelectionFlashDeadlineMs else { return }
        let now = textSelectionNowMs()
        if now >= deadline {
            persistentTextSelection = nil
            tableSelectionGeometry = nil
            textSelectionFlashDeadlineMs = nil
            textSelectionCreatedAtMs = nil
            textSelectionFlashTask = nil
            if !localMotionHold, !restored {
                try? renderState()
            }
            return
        }
        let remainingMs = deadline - now
        let sleepNanos = testingFlashSleepNanos ?? (remainingMs * 1_000_000)
        textSelectionFlashTask = Task {
            do {
                try await Task.sleep(nanoseconds: sleepNanos)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard generation == self.textSelectionFlashGeneration else { return }
            if let deadline = self.textSelectionFlashDeadlineMs,
               self.textSelectionNowMs() < deadline
            {
                // Injected clock did not advance through sleep — park until
                // resume/reconcile or a later arm; do not spin.
                if self.testingFlashSleepNanos != nil {
                    self.textSelectionFlashTask = nil
                    return
                }
                self.armTextSelectionFlashExpiryTask(generation: generation)
                return
            }
            self.persistentTextSelection = nil
            self.tableSelectionGeometry = nil
            self.textSelectionFlashDeadlineMs = nil
            self.textSelectionCreatedAtMs = nil
            self.textSelectionFlashTask = nil
            if !self.localMotionHold, !self.restored {
                try? self.renderState()
            }
        }
    }

    func copyTextSelectionToClipboard(_ text: String) {
        do {
            try LivePagerClipboard.copy(text) { data in
                try sink.write(String(decoding: data, as: UTF8.self))
            }
            try sink.flush()
        } catch {
            appendMessage(PagerMessage(
                role: .error,
                text: "Could not reach the clipboard: \(error)"
            ))
        }
    }

    func reloadKeepTextSelectionFromEffectiveConfig() {
        let resolved = Self.resolveUIConfig(
            workingDirectory: URL(fileURLWithPath: workingDirectory, isDirectory: true),
            environment: environment
        )
        keepTextSelectionMode = PagerKeepTextSelectionMode.fromCanonical(
            resolved.config.resolvedKeepTextSelection()
        ) ?? .flash
        reconcilePersistentSelectionForModeChange(now: textSelectionNowMs())
        syncOpenSettingsKeepTextSelectionFromSnapshot()
    }

    func syncOpenSettingsKeepTextSelectionFromSnapshot() {
        overlays.updateSettings { settings in
            settings.values["keep_text_selection"] = .string(keepTextSelectionMode.canonical)
        }
    }

}
