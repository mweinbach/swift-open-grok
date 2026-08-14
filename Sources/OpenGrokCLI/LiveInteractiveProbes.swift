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

    // MARK: - Narrow live-seam test probes

    /// Extrapolated motion-clock seconds (same epoch as painted ticks).
    func testingMotionSeconds() -> TimeInterval { currentMotionSeconds() }

    /// Last painted motion tick (not extrapolated) — for proving
    /// `renderAnimationTick` no-ops under the local suspend hold.
    func testingPaintedMotionTick() -> Int { motion.tick }

    /// Turn elapsed on the motion clock, or `nil` when no turn is running.
    func testingTurnElapsed() -> TimeInterval? {
        guard motionEnabled else {
            return turnStartedAt.map { Date().timeIntervalSince($0) }
        }
        return turnStartedAtSeconds.map { max(0, currentMotionSeconds() - $0) }
    }

    /// `PagerToolCard.finishedAt` for a call id, when present.
    func testingToolFinishedAt(callID: String) -> TimeInterval? {
        conversation.testingFinishedAt(callID: callID)
    }

    /// Whether any tool card is still inside its finish-flash window.
    func testingHasPendingFlash() -> Bool { hasPendingFlash }

    /// Transcript scroll offset (0 at top). Follow-tail reports the last
    /// painted maximum so tests can assert wheel quarantine without parsing
    /// paint bytes.
    func testingTranscriptScrollOffset() -> Int {
        followsBottom ? lastMaximumScrollOffset : scrollOffset
    }

    /// Latest layout max scroll offset (`totalContentLines - conversationHeight`).
    /// Updated on every `layOutCurrentFrame`, including coalesced paints — the
    /// live seam for proving transcript overflow without scraping the sink.
    func testingMaximumScrollOffset() -> Int { lastMaximumScrollOffset }

    /// Sticky header screen rows from the last *painted* frame (0 when
    /// compact / sticky_headers off / inactive / no paint). Mouse/probe
    /// seam only — PageUp / PageDown recompute via `testingCurrentPageScrollRows`.
    func testingLastHeaderScreenRows() -> Int { lastHeaderScreenRows }

    /// Actor-local `[scrollback.display].sticky_headers` from the one-shot
    /// `$OPENGROK_HOME/pager.toml` load (default true). Not a settings-modal
    /// value — there is no row at pin 650c1db7.
    func testingStickyHeadersEnabled() -> Bool { stickyHeadersEnabled }

    /// Latest laid-out conversation viewport height (including coalesced
    /// layouts). Half-page still uses this; full-page uses the action-time
    /// snapshot inside `testingCurrentPageScrollRows`.
    func testingLastConversationHeight() -> Int { lastConversationHeight }

    /// Action-time page stride (same path as PageUp/PageDown). Lays out
    /// current scrollOffset once; does **not** refresh last-painted mouse
    /// / header caches — for proving coalesced-stale `lastHeaderScreenRows`
    /// is not consulted.
    func testingCurrentPageScrollRows() -> Int { currentPageScrollRows() }

    /// Action-time sticky `headerScreenRows` from a fresh layout snapshot
    /// at the current scrollOffset. Does not update last-painted caches.
    func testingCurrentHeaderScreenRows() -> Int {
        renderPagerFrame(renderState(conversation: conversation.items))
            .layout.headerScreenRows
    }

    func testingFollowsBottom() -> Bool { followsBottom }

    /// Whether a scrollbar gutter drag latch is armed.
    func testingScrollbarDragging() -> Bool { scrollbarDragging }

    /// Scrollback selection index after click-to-select / Tab focus.
    func testingScrollbackSelectedIndex() -> Int? { selection.index }

    /// Whether the local suspend motion hold is latched (ticks no-op).
    func testingLocalMotionHold() -> Bool { localMotionHold }

    /// Whether `restoreTerminal` has latched this renderer down.
    func testingRestored() -> Bool { restored }

    /// Active-background-work membership count (cache). Prefer
    /// `testingPagerStatusBar` / motion demand for live-seam proofs — this
    /// probe is for kind-split and idempotency only.
    func testingActiveBackgroundWorkCount() -> Int { activeBackgroundWork.count }

    /// Per-kind active count from the actor-owned cache.
    func testingActiveBackgroundWorkCount(
        of kind: LiveActiveBackgroundWorkKind
    ) -> Int {
        activeBackgroundWork.count(of: kind)
    }

    /// Live `PagerStatusBar` from the frame state builder (same value the
    /// next paint consumes). Prefer this over scraping ANSI from the sink.
    func testingPagerStatusBar() -> PagerStatusBar? {
        renderState(conversation: conversation.items).statusBar
    }

    /// `PagerStatusBar.backgroundTaskCount` from the live frame state builder.
    /// Absent status bar → 0.
    func testingStatusBarBackgroundTaskCount() -> Int {
        testingPagerStatusBar()?.backgroundTaskCount ?? 0
    }

    /// Last published `PagerMotionState.hasBackgroundTasks`, when any publish
    /// has occurred.
    func testingPublishedHasBackgroundTasks() -> Bool? {
        lastPublishedMotionState?.hasBackgroundTasks
    }

    /// Last published motion demand, when any publish has occurred.
    func testingPublishedMotionDemand() -> PagerTickDemand? {
        lastPublishedMotionState?.demand
    }

    /// Dismiss the welcome overlay so background-only motion demand is not
    /// masked by `.slow` shimmer. Live-seam test helper only.
    func testingDismissWelcomeOverlay() throws {
        _ = overlays.dismiss(id: Self.welcomeOverlayID)
        try renderState()
    }

    /// Whether terminal mouse reporting is currently enabled on the live
    /// renderer — the mid-session flag `/toggle-mouse-reporting` flips, not
    /// the restart-required opt-in gate.
    func testingIsMouseReportingEnabled() -> Bool { mouseReportingEnabled }

    /// Startup-cached opt-in gate for `/toggle-mouse-reporting` / scrollback
    /// `Ctrl+R`. Live-seam probe only.
    func testingMouseReportingToggleEnabled() -> Bool { mouseReportingToggleEnabled }

    func testingFpsHudEnabled() -> Bool { fpsHud.isEnabled }

    func testingLastPaintedFpsHud() -> PagerFpsHudOverlay? { lastPaintedFpsHud }

    /// Real paints that called `fpsHud.record` (coalesced requests do not).
    func testingFpsHudRecordCount() -> Int { fpsHudRecordCount }

    func testingStickyToast() -> String? { stickyToast }

    func testingTransientToast() -> String? { transientToast }

    func testingLastPaintedToast() -> String? { lastPaintedToast }

    func testingLastToastOccluder() -> TerminalRect? { lastToastOccluder }

    func testingSystemMessageTexts() -> [String] {
        conversation.items.compactMap { item in
            guard case .message(let message) = item, message.role == .system else {
                return nil
            }
            return message.text
        }
    }

    func testingErrorMessageTexts() -> [String] {
        conversation.items.compactMap { item in
            guard case .message(let message) = item, message.role == .error else {
                return nil
            }
            return message.text
        }
    }

    func testingSetMonotonicNow(_ now: TimeInterval?) {
        injectedMonotonicNow = now
    }

    func testingShowTransientToast(_ message: String) async throws {
        showTransientToast(message, at: clockNow())
        try await paintImmediately()
    }

    func testingForcePaint() async throws {
        try await paintImmediately()
    }

    /// Whether a coalesced flush Task is currently armed.
    func testingHasPendingFlushTask() -> Bool { pendingFlushTask != nil }

    /// Generation of the armed flush task (or the last cancel bump).
    func testingPendingFlushGeneration() -> UInt64 { pendingFlushGeneration }

    /// Simulate a stale flush-task body completing with `generation`.
    /// Must not `nil` a newer timer when the generation does not match.
    func testingCompleteFlushTask(generation: UInt64) {
        flushPendingFrameNow(generation: generation)
    }

    /// Invoke the pending-flush path directly — live-seam probe for hold /
    /// restored gates on paint and re-arm (AGENTS.md §3).
    func testingFlushPendingFrameNow() {
        flushPendingFrameNow()
    }

    /// Paint-clock monotonic seconds (same source as `requestFrame` / flush).
    func testingMonotonicNow() -> TimeInterval { Self.monotonicNow() }

    /// Force a coalesced paint at an injected future monotonic `now` (e.g.
    /// a synthetic clock advanced by `paintCadence + ε` each time). Returns
    /// whether a paint was recorded. Does not re-arm the flush timer.
    @discardableResult
    func testingFlushPendingFrame(at now: TimeInterval) -> Bool {
        flushPendingFrame(at: now)
    }

    /// Selected row index of the focused capturing overlay, when it exposes one.
    func testingFocusedOverlaySelectedIndex() -> Int? {
        guard let focused = overlays.focused else { return nil }
        switch focused.content {
        case .list(let list):
            return list.selectedIndex
        case .workflows(let runs):
            return runs.selectedIndex
        case .permission(let prompt):
            return prompt.selectedIndex
        case .question(let prompt):
            return prompt.cursor
        case .text, .welcome, .planApproval, .settings, .extensions, .agents,
             .personaDetail:
            return nil
        }
    }

    /// Focused capturing overlay id, for live mouse hit-tests in tests.
    func testingFocusedOverlayID() -> String? { overlays.focused?.id }

    /// Append a transcript block and request a repaint — live-seam injection
    /// for system/separator click-to-select gates (AGENTS.md §3).
    func testingAppendConversationItem(_ item: PagerConversationItem) throws {
        conversation.appendItem(item)
        try renderState()
    }

    /// Conversation item count after live appends / turns.
    func testingConversationItemCount() -> Int { conversation.items.count }

    /// Whether a coalesced frame is waiting on the paint-cadence flush timer.
    func testingHasScheduledFrame() -> Bool { renderer.scheduledFrameAt != nil }

    /// Due instant for the coalesced frame, when one is scheduled.
    func testingScheduledFrameAt() -> TimeInterval? { renderer.scheduledFrameAt }

    // MARK: - Scroll-normalizer live-seam probes

    /// Live settings commit/reset path (same as the modal's `.setting` arm).
    func testingApplySetting(_ event: PagerSettingsEvent) async {
        await applySetting(event)
    }

    /// Replace `MouseScrollState` at an injected origin so tests can drive
    /// `sec(...)` events against a fresh last-redraw epoch. Production keeps
    /// the uptime-initialized state; this seam must be called explicitly.
    func testingResetMouseScrollState(at now: TimeInterval) {
        mouseScrollState = MouseScrollState(now: now)
    }

    /// Feed one vertical transcript scroll at an injected monotonic time
    /// (no sleeps). Clears pending block/link click latches like the live
    /// mouse path. Returns `ScrollUpdate.lines` — callers must assert the
    /// status.
    func testingApplyTranscriptScroll(
        direction: ScrollDirection,
        at now: TimeInterval
    ) throws -> Int {
        pendingScrollbackClick = nil
        pendingLinkClick = nil
        clearScrollbarDragLatch()
        clearTextSelectionLatches()
        return try applyTranscriptScroll(direction: direction, at: now).lines
    }

    /// Whether a transcript link click is armed (live-seam tests).
    func testingPendingLinkClick() -> (x: Int, y: Int, url: String)? {
        pendingLinkClick
    }

    /// Whether a block click-to-select is armed (cleared when text drag promotes).
    func testingPendingScrollbackClick() -> (x: Int, y: Int)? {
        pendingScrollbackClick.map { ($0.0, $0.1) }
    }

    /// Whether a composer content gesture is armed (live-seam tests).
    func testingComposerGestureArmed() -> Bool {
        promptOwnedComposerGesture
    }

    /// Protocol `scrollClockDeadline` with an injected clock.
    func testingScrollClockDeadline(at now: TimeInterval) async -> TimeInterval? {
        await scrollClockDeadline(at: now)
    }

    /// Protocol `handleScrollClockTick` with an injected clock.
    /// Returns applied signed lines — callers must assert the status.
    /// Also applies text-drag autoscroll when armed (same as live tick).
    func testingHandleScrollClockTick(at now: TimeInterval) async throws -> Int {
        try await tickScrollClock(at: now)
    }

    // MARK: - Text-selection live-seam probes

    func testingKeepTextSelectionMode() -> PagerKeepTextSelectionMode {
        keepTextSelectionMode
    }

    func testingSetKeepTextSelectionMode(_ mode: PagerKeepTextSelectionMode) {
        keepTextSelectionMode = mode
        reconcilePersistentSelectionForModeChange(now: textSelectionNowMs())
    }

    func testingReconcilePersistentSelectionForModeChange() {
        reconcilePersistentSelectionForModeChange(now: textSelectionNowMs())
    }

    func testingTextSelectionCreatedAtMs() -> UInt64? {
        textSelectionCreatedAtMs
    }

    func testingLastTextSelection() -> PagerTextSelectionModel? { lastTextSelection }

    /// Action-time selection model at the current `scrollOffset` — does **not**
    /// update last-painted mouse caches (same shape as autoscroll reclamp).
    func testingActionTimeTextSelection() -> PagerTextSelectionModel? {
        layOutCurrentFrame().layout.textSelection
    }

    func testingLastDragPointer() -> (col: Int, row: Int)? { lastDragPointer }

    func testingPendingTextDrag() -> PagerPendingTextDrag? { pendingTextDrag }

    func testingActiveTextDrag() -> PagerActiveTextDrag? { activeTextDrag }

    func testingPersistentTextSelection() -> PagerPersistentTextSelection? {
        persistentTextSelection
    }

    func testingTableSelectionGeometry() -> PagerTableSelectionGeometry? {
        tableSelectionGeometry
    }

    /// Sidecar the live frame builder actually puts on `PagerRenderState`
    /// (not only the actor field). Proves paint receives the keyed sidecar.
    func testingRenderStateTableSelectionGeometry() -> PagerTableSelectionGeometry? {
        renderState(conversation: conversation.items).tableSelectionGeometry
    }

    func testingCurrentTextSelectionHighlight() -> PagerTextSelectionHighlight? {
        currentTextSelectionHighlight()
    }

    func testingDeferredTextPress() -> (col: Int, row: Int)? { deferredTextPress }

    func testingDragAutoscroll() -> PagerTextSelectionAutoScrollState? { dragAutoscroll }

    func testingLastTextClick() -> PagerTextClickIdentity? { lastTextClick }

    /// Inject monotonic ms for multi-click window tests (`nil` clears).
    func testingSetTextSelectionNowMs(_ ms: UInt64?) {
        testingTextSelectionNowMs = ms
    }

    /// Inject flash Task sleep; `0` expires on the next scheduling hop.
    func testingSetFlashSleepNanos(_ nanos: UInt64?) {
        testingFlashSleepNanos = nanos
    }

    func testingTextSelectionFlashDeadlineMs() -> UInt64? {
        textSelectionFlashDeadlineMs
    }

    /// Suspend-path flash cancel (keep highlight + deadline; no paint).
    func testingSuspendTextSelectionFlash() async {
        localMotionHold = true
        await suspendTextSelectionFlashTask()
    }

    /// Resume-path flash reconcile after an injected-clock suspend probe.
    func testingResumeTextSelectionFlash() async throws {
        localMotionHold = false
        reconcileTextSelectionFlashAfterResume()
        try renderState()
    }

    /// Re-check flash deadline against the injected/wall clock (post-resume
    /// remaining-TTL proofs without waiting on Task.sleep alone).
    func testingReconcileTextSelectionFlashDeadline() async throws {
        reconcileTextSelectionFlashAfterResume()
        if !localMotionHold, !restored {
            try renderState()
        }
    }

    func testingFrozenDragTextSelection() -> PagerTextSelectionModel? {
        frozenDragTextSelection
    }

    /// Await + force-clear a flash highlight (hold/word_select untouched).
    /// Table-selection tests must not use this: advance injected time past
    /// the deadline and call `testingReconcileTextSelectionFlashDeadline`.
    func testingForceFlashExpiry() async throws {
        await cancelTextSelectionFlashTask()
        guard !keepTextSelectionMode.holds else { return }
        persistentTextSelection = nil
        tableSelectionGeometry = nil
        textSelectionFlashDeadlineMs = nil
        textSelectionCreatedAtMs = nil
        try renderState()
    }

    /// Await flash Task cleanup (restore/suspend symmetry for tests).
    func testingAwaitTextSelectionFlashCleanup() async {
        await cancelTextSelectionFlashTask()
    }

    /// Viewport-stamped config the live hot path passes into `onScrollEvent`.
    func testingPricedScrollConfig() -> ScrollConfig {
        scrollConfig.withViewportHeight(UInt16(clamping: max(0, lastConversationHeight)))
    }

    /// Whether the normalizer still holds an active stream.
    func testingHasActiveScrollStream() -> Bool { mouseScrollState.hasActiveStream }

    /// Current rebuildable scroll config (viewport height unstamped).
    func testingScrollConfig() -> ScrollConfig { scrollConfig }

    /// Cancel the active stream and latch the local suspend hold — live
    /// probe for suspend disarming the scroll clock without spawning a child.
    func testingSuspendScrollClock() {
        localMotionHold = true
        cancelScrollStreamForLifecycle()
    }

    /// Clear the local suspend hold (resume side of `testingSuspendScrollClock`).
    func testingResumeScrollClock() {
        localMotionHold = false
    }

}
