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

actor LiveInteractiveControllerRenderer: OpenGrokPagerInteractiveRenderAdapter {
    struct ResolvedUIConfiguration: Sendable {
        let config: UiConfig
        let inputModes: OpenGrokPagerInputModes
        /// Startup-cached opt-in for `Ctrl+R` / `/toggle-mouse-reporting`.
        /// Resolved once from env + effective `[ui]` — restart-required in
        /// the settings modal; live `mouseReportingEnabled` is separate.
        let mouseReportingToggleEnabled: Bool
    }

    /// Actor-local mirror of the four live `[ui]` scroll keys. Cold start
    /// seeds from effective `UiConfig`; commits/resets update this snapshot
    /// and rebuild `scrollConfig` without a restart.
    struct LiveScrollSettings: Sendable, Equatable {
        /// `nil` = unset → pricing uses speed 50 (1.0×).
        var speed: Int?
        /// Parsed mode; malformed / absent → `.auto`.
        var mode: ScrollInputMode
        /// `nil` = unset → per-terminal wheel/trackpad lines stay in charge.
        var lines: Int?
        var invert: Bool

        init(uiConfig: UiConfig) {
            if let raw = uiConfig.scrollSpeed {
                speed = min(100, max(1, Int(raw)))
            } else {
                speed = nil
            }
            mode = LiveInteractiveControllerRenderer.parseScrollMode(uiConfig.scrollMode)
            if let raw = uiConfig.scrollLines {
                lines = min(10, max(1, Int(raw)))
            } else {
                lines = nil
            }
            invert = uiConfig.invertScroll ?? false
        }

        func asOverrides() -> ScrollConfigOverrides {
            let linesOverride = lines.map { UInt16(clamping: $0) }
            return ScrollConfigOverrides(
                wheelLinesPerTick: linesOverride,
                trackpadLinesPerTick: linesOverride,
                mode: mode == .auto ? nil : mode,
                invertDirection: invert,
                speedMultiplier: mouseScrollSpeedToMultiplier(speed ?? 50)
            )
        }
    }

    let mode: OpenGrokPagerMode
    let terminal: OpenGrokLiveTerminal
    let sink: any PagerTerminalSink
    let renderer: PagerTerminalRenderer
    /// B2-M4: the scrollback-native frame program, constructed instead of
    /// driving `renderer` when the session resolved `.minimal`. The
    /// controller's frame states route to `minimalHost.draw` and the
    /// finalized blocks print once into the terminal's own scrollback;
    /// `renderer` stays idle (never `start()`ed — no alt screen, no mouse
    /// capture, the guard.rs stance).
    let minimalHost: PagerMinimalFrameHost?
    /// B2-S2: the accepted `/minimal`//`/fullscreen` relaunch, recorded by
    /// the event arm and read by the composition root AFTER the loop ends
    /// and the terminal is restored (upstream's `app.relaunch` stash,
    /// `router.rs:199-209`).
    var pendingScreenModeRelaunch: (sessionID: String, minimal: Bool)?

    /// One-shot read of the recorded relaunch request.
    func takePendingScreenModeRelaunch() -> (sessionID: String, minimal: Bool)? {
        defer { pendingScreenModeRelaunch = nil }
        return pendingScreenModeRelaunch
    }

    func dashboardSnapshotForTesting() -> LiveDashboardRendererSnapshot {
        LiveDashboardRendererSnapshot(
            isOpen: overlays.contains(id: LiveDashboardOverlay.overlayID),
            searchQuery: dashboardSearchQuery,
            selectedRowID: selectedDashboardListRowID(),
            cachedSessionIDs: Set(dashboardPeekCache.items.keys),
            dormantSessionIDs: Set(dashboardDormant.map(\.sessionID)),
            inputText: dashboardInputText,
            dispatchWorkingDirectory: dashboardDispatchWorkingDirectory,
            rowLabels: dashboardRowLabelsForTesting()
        )
    }

    /// B1-t: the Ctrl+G tasks pane — nil = hidden. A full-width chrome band
    /// (upstream's AgentPane::Tasks), coexisting with the composer; keys
    /// route to it only while `focused`.
    var tasksPane: PagerTasksPaneState?
    /// Bounded refresh while the pane is visible. Upstream rebuilds rows
    /// every frame off actor-free state; this port's feeds are actors, so
    /// the pane refreshes on open, on action, and on this once-a-second
    /// tick — recorded divergence, cost: states up to ~1s stale.
    var tasksPaneRefresh: Task<Void, Never>?

    /// B6: the context segment's painted cells from the LAST frame, for the
    /// hover router (per-frame geometry, the rail's rule).
    var lastContextBarRect: TerminalRect?
    /// Pointer-over state driving the width-matched bar swap.
    var contextBarHovered = false

    /// B1-m: the session tab registry — the in-process roster the dashboard
    /// lists. One turn is active at a time, while the runtime retains each
    /// tab's history, shell state, and cwd for later dispatch or attachment.
    var sessionTabs: [LiveSessionTab] = []
    /// Typed leader FleetView state. Empty in the local composition; the
    /// leader client replaces it from the initial snapshot and every delta.
    var leaderRoster: [ACPLeaderRosterEntry] = []

    /// The dashboard peek's transcript snapshot, built ONCE when the roster
    /// opens. Held only while the modal is up (see `handleOverlayDismissal`):
    /// retaining every session's items for the life of the process would be a
    /// leak with no reader.
    var dashboardPeekCache = LiveDashboardPeekCache()
    /// The subagent snapshot the open roster was built from, so armed-close
    /// and post-delete rebuilds repaint the same child rows without another
    /// actor round-trip.
    var dashboardSubagents: [LiveSubagentSnapshot] = []
    /// The C-1 close arm's press-again state — the port's no-timer analog of
    /// upstream's 2 s arm window (`arm_or_delete`, dashboard.rs:2125-2140):
    /// pressing `x` on a DIFFERENT row re-arms instead of deleting.
    var armedCloseSessionID: String?
    /// B1-w2: the state machinery behind the open roster. Rebuilt FRESH at
    /// every open — filter/search/collapse/idle-expand are per-open state by
    /// upstream's persistence contract; grouping/pins/reorder re-enter
    /// through the `[dashboard]` load.
    var dashboardState = PagerDashboardState()
    /// The dormant catalog listings the open roster was built from — the
    /// same one-pass-at-open rule as the peek cache.
    var dashboardDormant: [LiveSessionListing] = []
    /// Search-mode text (`enter_search_mode`, state.rs:3533-3540). Non-nil
    /// while Ctrl+/ search is live; `dashboardState.searchActive` mirrors it
    /// for the line builder's fold suppression.
    var dashboardSearchQuery: String?
    var dashboardInputMode: LiveDashboardInputMode?
    var dashboardInputText = ""
    var dashboardDispatchWorkingDirectory: String
    var dashboardWorktreeEnabled = false
    /// The active-only divergence still keeps the dashboard visible for a
    /// send-without-open: the session switch replaces the transcript but the
    /// roster remains foregrounded and follows the new active tab.
    var preserveDashboardOnNextSessionSwitch = false
    var pendingDashboardWorktree: LiveWorktreePreparation?
    /// The ON-DISK `[dashboard].enabled`, threaded into every persist so a
    /// deliberate `enabled = false` is never overwritten by a pin
    /// (`dispatch_dashboard_persist`, dashboard.rs:2369-2384).
    var dashboardPersistedEnabled = true

    var conversation = LivePagerConversationState(markdown: PagerMarkdownRenderer())
    var prompt = OpenGrokPagerInteractivePromptState()
    var terminalSize: OpenGrokTerminalCore.TerminalSize
    var restored = false
    /// Voice dictation state for `/voice` and Ctrl+Space. Capabilities are
    /// resolved once at construction from the audited environment.
    var voiceState = LiveVoiceSessionState()
    /// Drains `VoicePipeline.events` into the composer while listening.
    var voiceEventTask: Task<Void, Never>?
    /// Forwards voice finals into the controller's editor (not only the
    /// renderer's copy), so Send sees the dictated text.
    var voicePromptSink: (@Sendable (String) async -> Void)?

    /// Frame chrome. `turnActivity` is `nil` whenever no turn is in flight,
    /// which is what hides the turn-status row — the reference gives that row
    /// zero height when idle.
    var workingDirectory: String
    var modelName: String
    /// `(id, provider)` pairs the `/model` picker lists.
    let modelCatalog: [LiveModelPickerEntry]
    let catalogStore: LiveModelCatalogStore?
    /// Rebuilds the sampling stack when a picker row is chosen. `nil` in
    /// compositions with no provider session (tests, headless renders), where
    /// the picker degrades to a relabel.
    let modelSwitch: LiveModelSwitchCoordinator?
    let providerBoundarySync: (@Sendable (Bool) async throws -> Void)?
    /// Prompts waiting behind the running turn, as published by the controller.
    var queuedPromptCount = 0
    var turnActivity: String?
    var turnStartedAt: Date?
    var isCancelling = false

    /// The animation clock, fed exclusively by the controller's wall-clock
    /// ticker through `renderAnimationTick`. The old per-event counter is
    /// gone on purpose: an event-count "tick" froze the spinner on a silent
    /// turn and raced ahead on a chatty one.
    var motion = PagerMotionSnapshot()
    /// Last painted motion-clock seconds paired with the monotonic instant
    /// they were sampled. Between ticks `motion.seconds` freezes; turn-start
    /// / tool-finish stamps and flash/elapsed reads extrapolate from this
    /// pair so an idle gap cannot inflate elapsed or erase a finish flash
    /// before the ticker resumes. Same epoch as `PagerMotionSnapshot.seconds`
    /// (controller `DispatchTime` uptime minus motion epoch).
    var motionClockAnchorSeconds: TimeInterval = 0
    var motionClockAnchorMonotonic: TimeInterval?
    /// Whether this terminal can animate at all, resolved once — a non-TTY or
    /// `TERM=dumb` renders still frames forever.
    let motionEnabled: Bool
    /// `[animation].wave_rows` from `$OPENGROK_HOME/pager.toml`, loaded once
    /// at construction (`appearance/watcher.rs:46-54`). Default 32 keeps
    /// pre-reader paint byte-identical. Minimal hosts ignore this (no wave).
    var waveRows: Int = PagerMotion.defaultWaveRows
    /// `[animation].fps` from the same one-shot load — composition calls
    /// `controller.setMotionFPS` with this before `run`.
    var animationFPS: Int = PagerMotion.defaultFPS
    /// `[scrollback.display].sticky_headers` from the same `$OPENGROK_HOME/pager.toml`
    /// one-shot (`watcher.rs:46-54`, `config.rs:1429` unwrap_or(true) at pin
    /// 650c1db7). Default true. No env. No settings-modal row — file edits
    /// are restart-only. Compact still suppresses regardless.
    var stickyHeadersEnabled = true
    /// One-shot parse/type diagnostics from the sticky_headers loader.
    /// Emptied after `begin()` posts them as system notes. Absent file / absent
    /// key stay empty — no note.
    var stickyHeadersStartupDiagnostics: [String] = []
    /// Last shimmer frame painted for a `.slow` tick, so the welcome logo only
    /// repaints when its animation actually advanced (app_view.rs:5760-5766).
    var lastShimmerFrame = -1
    /// One-shot timer for a repaint folded into the paint cadence window;
    /// without it a coalesced frame would never paint (see
    /// `PagerTerminalRenderer.scheduledFrameAt`).
    var pendingFlushTask: Task<Void, Never>?
    /// Bumped on arm and on `cancelPendingFlushTask` so a stale cancelled
    /// task cannot `nil` a newer timer's slot (`flushPendingFrameNow`).
    var pendingFlushGeneration: UInt64 = 0
    /// Reports what is moving on screen to the controller's motion ticker.
    /// Installed by the composition after the controller exists; `nil` (tests,
    /// headless) simply never arms the ticker from render-side changes.
    var motionSink: (@Sendable (PagerMotionState) async -> Void)?
    /// Latest motion state waiting for the ordered publisher. Always the
    /// newest value — a late `.none` must not be overwritten by a stale
    /// high-demand delivery that was already in flight.
    var pendingMotionDelivery: PagerMotionState?
    /// Single in-flight delivery loop for `motionSink`. Replaces the old
    /// per-update `Task { await sink(...) }` fire-and-forget, which could
    /// reorder and re-arm a parked ticker from a stale `.fast`.
    var motionDeliveryTask: Task<Void, Never>?
    /// Bumped on sink install/removal so an in-flight delivery stops talking
    /// to a replaced or cleared sink.
    var motionSinkEpoch: UInt64 = 0
    /// Actor-owned status-chip membership. Hosts push idempotent upsert/remove
    /// events; paint and motion read only this cache (never re-query hosts).
    var activeBackgroundWork = LiveActiveBackgroundWorkCache()
    /// Bumped when the composition retires the shared host sink (teardown /
    /// restore) so an in-flight `await sink(event)` that resumes after a
    /// replacement cannot re-arm the chip against a restored screen.
    var activeBackgroundWorkSinkGeneration: UInt64 = 0
    /// Carries settings-modal commits into the controller's actor-isolated mode
    /// snapshot. Controller-originated mode events never invoke it, which keeps
    /// slash-command updates from bouncing back through this bridge.
    var inputModesSink: (
        @Sendable (OpenGrokPagerInputModes) async -> Void
    )?
    /// `/transcript`'s suspend host: the input-suspension entry point and the
    /// audited environment, both owned by the composition. `nil` (tests,
    /// headless) makes the command report instead of suspending.
    var suspendHost: LiveTUISuspendHost?
    var lastPublishedMotionState: PagerMotionState?
    /// Turn start on the motion clock, for the status row's elapsed readout.
    /// `turnStartedAt` (wall time) stays as the fallback for motion-disabled
    /// terminals, where no animation frame ever advances `motion.seconds`.
    var turnStartedAtSeconds: TimeInterval?
    /// UTF-8 bytes of assistant output streamed this turn, for the status
    /// row's ⇣ token counter. An estimate (bytes/4) by design: this turn path
    /// carries no provider-reported `TokenUsage`, and the estimator is the
    /// same one `/usage` already documents as the honest option.
    var turnOutputUTF8Count = 0
    /// The compaction coordinator's context accounting, refreshed at turn
    /// boundaries. Feeds the status bar's context ramp with the same numbers
    /// auto-compaction decides on.
    var contextUsage: ContextUsage?
    /// Per-server MCP connection outcomes, recorded at session start; the
    /// read-only `/mcps` overlay renders them.
    let mcpServers: [MCPServerConnection]
    /// The auth-store home the settings modal's secret saves write to — the
    /// same store `readProviderAPIKey` reads.
    let openGrokHome: URL
    /// The audited environment (AGENTS.md §2's process-default trap applies
    /// to env too): auth-file paths, Codex endpoints, and the picker's
    /// env-override statuses all resolve against this copy.
    let environment: [String: String]
    /// Injectable side effects of `/login codex` and `/logout codex` —
    /// transport, browser flow, browser opener. Tests substitute fakes so no
    /// socket, browser, or network is touched.
    let authServices: LivePagerAuthServices
    /// URL opener for `openExternalURL` (transcript link clicks, banner
    /// Terms/Policy, welcome CTA, `/docs` OpenURL). Defaults to
    /// `authServices.openBrowser` (production system browser). Tests inject
    /// a capture so no shell/browser side effect runs.
    let urlOpener: (@Sendable (URL) -> Void)?
    /// The in-flight `/login codex` browser flow. Single-flight: upstream's
    /// only guard is the fixed-port listener bind (`codex_auth.rs:706-714`,
    /// second flow lands on the fallback port), so a second dispatch here
    /// would bind a second callback server; this port refuses it with a
    /// notice instead.
    var codexLoginTask: Task<Void, Never>?
    /// The in-flight `/login xai` browser flow. Same single-flight shape as
    /// the codex task above: upstream instead ABORTS the prior attempt and
    /// starts fresh (`abort_prior_xai_auth`, dispatch/auth.rs:685); this port
    /// has no cancellation plumbing into the blocking listener thread, so a
    /// second dispatch is refused with a notice (recorded divergence).
    var xaiLoginTask: Task<Void, Never>?
    /// The in-flight `/recap` side-call, if any — the port of upstream's
    /// `recap_in_flight` claim (recap.rs:294-306): manual re-requests while
    /// one is generating answer with the unavailable copy instead of
    /// stacking side-calls.
    var recapTask: Task<Void, Never>?
    /// Bumped when a new turn starts or the session is swapped, so a recap
    /// that finishes late is discarded instead of painting into a
    /// conversation it no longer describes — upstream's `recap_epoch`
    /// cancellation (recap.rs:509-517, :430-455).
    var recapEpoch: UInt64 = 0

    /// Viewport state. Conversation height / max offset track the latest
    /// layout (including coalesced). PageUp/PageDown recompute sticky
    /// header rows at action time (see `currentPageScrollRows`);
    /// `lastHeaderScreenRows` is last-*painted* only for mouse/probes.
    var followsBottom = true
    var scrollOffset = 0
    var lastConversationHeight = 1
    var lastMaximumScrollOffset = 0
    /// Sticky `headerScreenRows` from the last painted frame
    /// (`PagerFrameLayout.headerScreenRows`). Replace-wholesale in
    /// `recordPaintedGeometry` for mouse hit geometry / probes — never
    /// consulted by PageUp/PageDown (those recompute at action time like
    /// Rust `current_header_screen_rows`). 0 when compact / no sticky /
    /// no paint yet.
    var lastHeaderScreenRows = 0

    /// Overlay stack and the geometry the last frame published for it. Bounds
    /// are replaced wholesale every frame and never cached across one: a modal
    /// that no longer fits (below 20×6) publishes nothing, so a stale rect
    /// would hit-test against an overlay that is not on screen.
    var overlays = PagerOverlayStack()
    /// Internal (not private) so the live-seam tests can drive mouse events
    /// against the rects the REAL frame published — per AGENTS.md §3, the
    /// welcome menu's click/hover proofs hit-test these bounds instead of
    /// guessing coordinates.
    var lastOverlayBounds: [PagerOverlayBounds] = []
    /// The timeline rail the last frame painted, refreshed alongside
    /// `lastOverlayBounds` on the same replace-wholesale rule: upstream
    /// computes the geometry once per frame and mouse routing consumes that
    /// one value (`views/timeline.rs:5-6`, `mouse.rs:415-427`), so a frame
    /// with no rail clears this and a click can never act on a previous
    /// frame's ticks.
    var lastTimelineRail: PagerTimelineRail?
    /// The privacy banner's hit rects from the last painted frame, on the
    /// rail's replace-wholesale rule (upstream re-arms them every draw and
    /// clears them whenever the banner does not own the slot,
    /// `agent_view/render.rs:2128-2148` at pin 650c1db7) — a click can
    /// never act on a frame that no longer shows the banner. Internal (not
    /// private) so the live-seam tests can pin what the REAL frame
    /// published, per AGENTS.md §3.
    var lastPrivacyBannerHits: PagerPrivacyBannerHitRects?
    /// Conversation click-to-select geometry from the last painted frame,
    /// replaced wholesale with the rail/banner caches so a click never acts
    /// on a previous frame's block starts. Updated only when
    /// `requestFrame` / `flushPendingFrame` actually paints — never on a
    /// coalesced layout pass. Internal for live-seam tests.
    var lastConversationHit: PagerConversationHitModel?
    /// Transcript scrollbar geometry from the last painted frame — `nil`
    /// when the rail owns the gutter or the scrollbar did not paint.
    /// Replace-wholesale with the other mouse caches; drag maps against
    /// this (last-painted) model, never against unpainted layout.
    /// Internal for live-seam tests.
    var lastScrollbarHit: PagerScrollbarHitModel?
    /// Composer click-to-focus / cursor-place geometry from the last painted
    /// frame. Replace-wholesale with the other mouse caches; `nil` when the
    /// input slot was too small to paint. Internal for live-seam tests.
    var lastComposerHit: PagerComposerHitModel?
    /// Prompt-owned TextArea gesture: content down arms it; drag/up keep
    /// forwarding even outside the pane (edge autoscroll). Cleared on up,
    /// restore, suspend, capturing overlay, and a new non-composer down.
    var promptOwnedComposerGesture = false
    /// Last content rect from a painted composer hit or an armed gesture.
    /// Survives a frame that cannot paint the slot (`width < 4`) so a
    /// prompt-owned up can still finish against the last known geometry.
    var lastKnownComposerContentRect: TextAreaRect?
    /// Hyperlink spans from the last painted frame (`PagerRenderResult.links`),
    /// replace-wholesale with the other mouse caches. Updated only in
    /// `recordPaintedGeometry` after a real paint — never on a coalesced
    /// nil layout — and cleared on restore so a click cannot open a URL
    /// from a screen the user is no longer looking at. Internal for
    /// live-seam tests (AGENTS.md §3).
    var lastPaintedLinks: [LinkSpan] = []
    /// Scrollbar drag latch (`scrollbar_dragging`, `mouse.rs:410` /
    /// `:803-804` / selection.rs:525-527 at pin 650c1db7). Left down in
    /// the gutter arms it; left/X10-none up clears; scroll / non-left /
    /// overlay / suspend / restore also clear.
    var scrollbarDragging = false
    /// Pending left-button down for click-to-select: screen cell plus the
    /// exact hit model visible at down. Up remaps through this snapshot
    /// (not live `scrollOffset` / layout). Cleared on real drag,
    /// overlay/rail/banner hits, and non-left buttons — upstream's
    /// `pending_scrollback_click` (`mouse.rs:742`, `:830`), without the
    /// same-cell-up gate Rust dropped for selection (jitter still selects
    /// the down cell when no drag committed).
    var pendingScrollbackClick: (
        x: Int,
        y: Int,
        hit: PagerConversationHitModel
    )?
    /// Pending left-button down for transcript link open
    /// (`pending_link_click`, `mouse.rs:446-448` / `:734-736` / `:823-828`
    /// at pin 650c1db7): screen cell plus the URL frozen at down. Up opens
    /// only when the release is the exact same cell AND that cell still
    /// publishes the same URL in `lastPaintedLinks`. Cleared on drag,
    /// move-with-button, non-left, scroll, suspend, restore, and any down
    /// that does not re-arm.
    var pendingLinkClick: (x: Int, y: Int, url: String)?
    /// Last-painted text-selection model (`layout.textSelection`),
    /// replace-wholesale with the other mouse caches. Sticky-header band
    /// is excluded from hits. Table cell/grid kinds require a matching
    /// `tableSelectionGeometry` sidecar (no table claim without it).
    var lastTextSelection: PagerTextSelectionModel?
    /// Pending left-down text drag before the ≥1 cell threshold
    /// (`PendingTextDrag`, selection.rs:369-374 at pin 650c1db7).
    var pendingTextDrag: PagerPendingTextDrag?
    /// Active text drag after threshold / chrome→text conversion
    /// (`ActiveTextDrag` / `drag_selection`).
    var activeTextDrag: PagerActiveTextDrag?
    /// Persistent highlight after a successful copy (`PersistentTextSelection`).
    var persistentTextSelection: PagerPersistentTextSelection?
    /// Multi-click identity within `pagerTextSelectionMultiClickTimeoutMs`.
    var lastTextClick: PagerTextClickIdentity?
    /// Last drag pointer for autoscroll reclamp (`last_drag_mouse`).
    var lastDragPointer: (col: Int, row: Int)?
    /// Edge autoscroll while an active text drag is held (`drag_autoscroll`).
    var dragAutoscroll: PagerTextSelectionAutoScrollState?
    /// Anchor-less press that may convert to text when the pointer enters
    /// selectable text (`deferred_text_press`, selection.rs:458-493).
    var deferredTextPress: (col: Int, row: Int)?
    /// Full selection model frozen at drag-arm wrap width — copy reconstructs
    /// against this so a mid-drag resize cannot shift `blockLineIndex`.
    var frozenDragTextSelection: PagerTextSelectionModel?
    /// Table grid frozen at drag-arm / triple-click, keyed to entry+range.
    /// Paint/copy consult it; a stale or missing sidecar cannot claim table.
    /// Threaded onto `PagerRenderState.tableSelectionGeometry` each frame so
    /// live paint uses this keyed sidecar instead of re-detecting.
    var tableSelectionGeometry: PagerTableSelectionGeometry?
    /// Flash-highlight expiry task + generation (cancel+await; no defer Task).
    var textSelectionFlashTask: Task<Void, Never>?
    var textSelectionFlashGeneration: UInt64 = 0
    /// Monotonic deadline for flash clear (`createdAt + TTL`). Survives suspend
    /// task cancel so resume can clear or re-arm remaining TTL.
    var textSelectionFlashDeadlineMs: UInt64?
    /// When the persistent highlight was created (monotonic ms). Mode changes
    /// to `.flash` reconcile age against this — never a timeless flash.
    var textSelectionCreatedAtMs: UInt64?
    /// Actor-local `[ui].keep_text_selection` mirror (live-apply like scroll).
    var keepTextSelectionMode: PagerKeepTextSelectionMode = .flash
    /// Injected monotonic ms for multi-click / flash tests; `nil` → wall clock.
    var testingTextSelectionNowMs: UInt64?
    /// When set, flash Task sleeps this many ns instead of the remaining TTL.
    /// Injected-clock tests use this without spinning when the clock is frozen.
    var testingFlashSleepNanos: UInt64?
    /// 16ms text-drag autoscroll cadence (event_loop redraw cadence).
    static let textDragAutoscrollCadence: TimeInterval = 0.016
    /// Local gate that makes `renderAnimationTick` a no-op while a suspended
    /// child owns the tty. Set before `host.suspendMotion` and cleared only
    /// after resume on every path — distinct from `motionEnabled`, which is
    /// a terminal capability, not a lifecycle flag.
    var localMotionHold = false
    let permissionCoordinator: PagerPermissionCoordinator?
    /// The `ask_user_question` surface, presenter-installed in `begin()`
    /// exactly like the permission coordinator. `nil` in compositions with
    /// no question surface (tests that opt out, headless).
    let questionCoordinator: PagerQuestionCoordinator?
    /// The `exit_plan_mode` plan-approval surface, presenter-installed in
    /// `begin()` exactly like the question coordinator. `nil` in
    /// compositions with no plan-approval surface (tests that opt out,
    /// headless), which keeps exit approval on the generic permission sheet.
    let planApprovalCoordinator: PagerPlanApprovalCoordinator?
    /// Live permission-mode handle shared with the tool executor's pipeline.
    let permissionMode: LiveSessionPermissionMode?
    /// Composer border flags derived from `permissionMode`; refreshed whenever
    /// the mode changes so `renderState` stays synchronous.
    var permissionModeFlags: [PagerComposerFlag] = []
    /// The background workflow registry, when this session has one. `/workflows`
    /// reads it live at present time rather than caching rows, so the dashboard
    /// reflects runs started after the session began — including ones another
    /// process on the same `OPENGROK_HOME` started.
    let workflowRegistry: RhaiWorkflowRunRegistry?
    let workflowsEnabled: Bool
    /// Startup-cached opt-in for `/toggle-mouse-reporting` and scrollback
    /// `Ctrl+R`. Distinct from `mouseReportingEnabled` (whether capture is
    /// currently on the wire).
    let mouseReportingToggleEnabled: Bool
    /// The turn loop's own coordinator, so a manual `/compact` and the
    /// automatic one share a compaction counter — which is the whole reason
    /// that instance is shared rather than rebuilt here.
    let compaction: LiveCompactionCoordinator?
    /// The tool executor whose hook gate the `/compact` command fires
    /// `PreCompact`/`PostCompact` through. `nil` in constructions that
    /// predate the hook wiring (tests, non-interactive minimal sessions),
    /// in which case `/compact` compacts without firing hooks.
    let toolExecutor: LiveToolExecutor?
    let pagerRuntime: LivePagerRuntimeAdapter?
    /// The session this renderer belongs to, and the three things the
    /// session-scoped commands act on.
    ///
    /// `sessionServices` is the same aggregate the tool executor holds — the one
    /// `makeSessionServices` built — so `/rewind` acts on the snapshots the turn
    /// loop actually captured and `/remember` writes to the backend the
    /// `memory_search` tool reads. Rebuilding them here would produce a second
    /// store pointed at the same files, which is how two writers appear.
    var sessionID: String
    let sessionServices: LiveSessionServices?
    let conversationHistory: LiveConversationHistory?
    let sessionCatalog: LiveSessionCatalog?
    /// The session store `/fork` copies records through — the SAME instance
    /// the runtime adapter persists with (`foundation.conversationStore`),
    /// never a rebuilt one, for the same one-writer reason as
    /// `sessionServices` above. `nil` in compositions with no session
    /// persistence (tests that opt out, headless), where `/fork` refuses.
    let conversationStore: LiveConversationStore?
    var currentPermissionRequestID: String?
    /// The question sheet currently on screen, and the one parked behind an
    /// open permission sheet. Permission outranks question — upstream renders
    /// the permission prompt above the question view and routes keys to it
    /// first (`app/agent_view/input.rs:879-1112`, `render.rs:906-927`) — so a
    /// questionnaire arriving mid-approval waits here and presents when the
    /// permission queue drains.
    var currentQuestionRequestID: String?
    var pendingQuestionRequest: PagerQuestionRequest?
    /// The plan-approval sheet currently on screen, and the one parked behind
    /// an open permission sheet — the question sheet's parking pattern, for
    /// the same reason: permission outranks everything below it
    /// (`app/agent_view/input.rs:879-1112`). A plan sheet and a question
    /// sheet cannot coexist because the tool runtime serializes calls.
    var currentPlanApprovalRequestID: String?
    var pendingPlanApprovalRequest: PagerPlanApprovalRequest?
    var hasStartedFirstTurn = false
    /// The scrollback's focus and selected block. `selection.isFocused` is what
    /// unfocuses the composer, so the two halves of the focus model cannot
    /// disagree.
    var selection = LiveScrollbackSelection()
    /// Composer mode flags, carried as a whole snapshot so a missed event
    /// cannot leave the renderer disagreeing with the controller.
    var inputModes = OpenGrokPagerInputModes()
    /// The USER's `[ui] compact_mode` value — upstream's
    /// `current_ui.compact_mode` (`ui_config.rs:82`), hydrated from the
    /// effective config at construction (`event_loop.rs:1492` reads it into
    /// the first frame) and flipped by `/compact-mode` and the settings
    /// modal. The RENDER value is derived from this per paint in
    /// `renderState(conversation:)` (auto-compact on short terminals), so this
    /// var is never written by a resize — growing the window restores the
    /// user's choice, exactly upstream's rule (`app_view.rs:2670-2675`).
    var userCompactMode = false
    /// `[ui] show_timestamps` — upstream's `appearance.show_timestamps`
    /// (`appearance/config.rs:35`), hydrated from the effective config at
    /// construction (`event_loop.rs:1496`: `initial_config.show_timestamps =
    /// load_timestamps()`) and flipped by `/timestamps` and the settings
    /// modal (`set_timestamps_inner`, `setters.rs:1530-1541`). Unlike
    /// `userCompactMode` there is no derivation — the render value IS the
    /// user value, passed straight into every frame.
    var userShowTimestamps = true
    /// `[ui] show_timeline` — upstream's `appearance.show_timeline`
    /// (`appearance/config.rs:36-37`), hydrated from the effective config at
    /// construction (`event_loop.rs:1497`: `initial_config.show_timeline =
    /// load_show_timeline()`) and flipped by `/timeline` and the settings
    /// modal (`set_timeline_inner`, `setters.rs:1561-1572`). Like
    /// timestamps, no derivation — but the frame flag is gated on fullscreen
    /// at the pass-through, because upstream's rail render path exists only
    /// in the fullscreen agent view (`agent_view/render.rs:1157`; minimal
    /// mode has no interactive scrollback pane for it).
    var userShowTimeline = false
    /// `[ui] page_flip_on_send` — upstream's `current_ui.page_flip_on_send`
    /// (`ui_config.rs:118`), hydrated from the effective config at
    /// construction (`event_loop.rs:1541-1542` via `load_page_flip_on_send`,
    /// `appearance/cache.rs:149-163`) and flipped by the settings modal
    /// (`set_page_flip_on_send_inner`, `setters.rs:1594-1596`). No derivation
    /// — the render seam reads this var on each send in `turnStarted`.
    var userPageFlipOnSend = true
    /// While set, every frame re-pins this user block to the viewport top —
    /// upstream's `follow_preserve_scroll` after `follow_new_turn`
    /// (`nav.rs:608-613`, `layout.rs:1637`). A one-shot pin at send is not
    /// enough when the new turn's tail is shorter than the viewport: the
    /// maximum scroll offset grows as the assistant block streams, so the
    /// target offset becomes reachable only after a few frames.
    var pageFlipUserBlockIndex: Int?

    /// Live mouse-scroll normalizer (`MouseScrollState` + rebuildable
    /// `ScrollConfig`). Brand/multiplexer are fixed at construction from
    /// `TERM_PROGRAM` + mux env markers; the four `[ui]` scroll keys rebuild
    /// `scrollConfig` without dropping the per-terminal profile on nil reset.
    let scrollBrand: MouseScrollTerminalBrand
    let scrollMultiplexer: MouseScrollMultiplexer
    var mouseScrollState: MouseScrollState
    var scrollConfig: ScrollConfig
    /// Actor-local mirror of the four live scroll settings. Settings commits
    /// do not mutate a shared `UiConfig` value — this snapshot is what the
    /// hot path rebuilds from (effective `UiConfig` seeds it at init).
    var scrollSettings: LiveScrollSettings
    var mouseReportingEnabled: Bool
    /// Release-safe FPS HUD (`/debug fps`, `GROK_FPS`). One instance per
    /// session; live layouts snapshot `currentOverlay` (nonmutating). After a
    /// real paint, `record` then `refreshOverlayCache` for the next frame.
    /// `[animation].show_fps` does not feed this. Minimal mode never snapshots
    /// or records (`AppView::draw_inner` early return at `app_view.rs:4850-4854`).
    var fpsHud: PagerFpsHud
    /// Count of `fpsHud.record` calls after a real paint (not coalesced).
    var fpsHudRecordCount = 0
    var lastLaidOutFpsHud: PagerFpsHudOverlay?
    var lastPaintedFpsHud: PagerFpsHudOverlay?
    /// Canonical sticky banner (scrollback copy). Display swap is per-frame.
    var stickyToast: String?
    var transientToast: String?
    var transientToastExpiresAt: TimeInterval?
    var lastLaidOutToast: String?
    var lastPaintedToast: String?
    var lastToastOccluder: TerminalRect?
    /// Test-injected monotonic seconds for overlay refresh / toast expiry /
    /// paint-clock `at:`. FPS *duration* still uses wall `monotonicNow()`.
    var injectedMonotonicNow: TimeInterval?

    /// The palette every frame paints with, and the preference it came from.
    ///
    /// Resolved once at construction from `[ui] theme` plus what the terminal
    /// can actually render, then swapped live by `/theme`. Before this the port
    /// pinned `PagerRenderState.theme` to `.default`, which made the whole
    /// theme catalog unreachable at runtime.
    var themePreference: PagerThemePreference
    var renderTheme: PagerRenderTheme
    let colorLevel: PagerColorLevel
    /// Auto-theme companions loaded from `[ui] auto_{dark,light}_theme` at
    /// startup and passed through `pagerResolveTheme` whenever preference is
    /// `.auto` (system_appearance.rs:95-104 via PagerSystemAppearance.themeKind).
    var autoDarkThemeKind: PagerThemeKind?
    var autoLightThemeKind: PagerThemeKind?

    /// Reasoning effort for the active model, shown after the model name on the
    /// composer's bottom border. `nil` on models with no selectable effort.
    var reasoningEffort: String?

    /// The announcements surface for this session: fetch → cache → banner plus
    /// the hide dismissal. `nil` in compositions without a live announcements
    /// feed (tests, headless launches); the renderer treats `nil` as "no
    /// banner slot." The banner projection is pulled from the composition
    /// (`refreshAnnouncementBanner`) and cached here so a frame never blocks
    /// on the hide-key state store.
    let announcements: LiveAnnouncementsComposition?
    /// The last-derived announcement banner projection. `nil` means "no slot
    /// this frame" — either the composition is absent, the cache is empty, or
    /// every live announcement is hidden.
    var announcementBanner: PagerAnnouncementBanner?

    /// The privacy banner's gate state — the `announcementBanner` shape for
    /// the SECOND tenant of the frame builder's banner slot, resolved but
    /// deliberately unconsumed by any frame this slice (Wave 18 B9-c1: the
    /// rollout flag defaults false and the banner render is gated on the
    /// retention write client). `nil` means "never hydrated" (headless
    /// tests that skip `begin()`); a hydrated state answers
    /// `shouldShow()` from upstream's gate (app_view.rs:1705-1731 at pin
    /// 650c1db7). Internal (not private) so the live-seam tests can pin
    /// what the REAL renderer resolved, per AGENTS.md §3.
    var privacyBanner: PagerPrivacyBannerState?

    /// The `/release-notes` changelog client — CDN fetch, disk cache under
    /// `$OPENGROK_HOME`, and the recorded export-boundary gate (the
    /// announcements precedent). `nil` in compositions that never passed
    /// one; the dispatch then builds a cache-only manager from this
    /// renderer's environment, upstream's offline arm.
    let changelog: ChangelogManager?
    /// The startup prefetch's markdown — upstream's `app.changelog_markdown`
    /// (`app/app_view.rs:836-837` at pin 650c1db7, stored by the
    /// `ChangelogFetched` arm, `dispatch/task_result.rs:3097-3101`). `nil`
    /// until the prefetch completes; what the welcome CTA/menu row and
    /// `/release-notes` serve without re-fetching.
    var changelogMarkdown: String?
    /// Upstream's `app.changelog_bullets = bullets_from_entries(&entries, 3)`
    /// (`task_result.rs:3099-3100`) — the welcome hero info slot's content.
    /// Empty until the prefetch completes; empty paints no slot.
    var changelogBullets: [String] = []
    /// The one-shot startup prefetch — upstream's post-auth
    /// `Effect::FetchChangelog` (`app/event_loop.rs:1811-1816`), spawned
    /// once from `begin()` and never from a frame. Internal (not private)
    /// so live-seam tests can await the REAL spawned fetch instead of
    /// polling (the `pendingCodingDataWrite` precedent); `/release-notes`
    /// awaits it too, so a command racing the prefetch is deterministic.
    var changelogPrefetch: Task<Void, Never>?

    /// The coding-data retention write client (Wave 18 B9-c2) — what makes
    /// the `coding_data_sharing` settings row a real control instead of the
    /// non-persistable viewer §4 found. `nil` in compositions without a
    /// live transport; a commit then rolls back and reports the refusal —
    /// never a fake success (§5: this is a consent write to a server).
    let codingDataRetention: LiveCodingDataRetentionClient?
    /// Newest retention-write generation — upstream's
    /// `coding_data_write_seq` (app_view.rs:1277-1279, claimed per write at
    /// dispatch/status.rs:87-92). Writes to this endpoint run concurrently
    /// and can land out of order; a reply carrying a stale generation must
    /// not touch state, because applying its rollback would silently undo
    /// whatever the user did since (status.rs:96-110).
    var codingDataWriteSeq: UInt64 = 0
    /// The spawned modal-commit write, upstream's Effect task
    /// (effects/mod.rs:5366-5433 spawns; the commit handler returns
    /// immediately so a slow proxy never blocks the input loop). Internal
    /// (not private) so the live-seam tests await the real spawned write
    /// instead of polling frames; the outcome is fully self-reported
    /// (rollback + toast happen inside `setCodingDataSharing`). The
    /// banner's `[Opt in]`/`[Opt out]` writes ride the same slot, so the
    /// tests await those too.
    var pendingCodingDataWrite: Task<LiveCodingDataSharingOutcome, Never>?
    /// `privacy_banner_opt_in_inflight` (app_view.rs:1275-1276): armed when
    /// the banner's `[Opt in]` dispatches its write, so a second click
    /// while the round trip is out is ignored (dispatch/status.rs:502) —
    /// the debounce that keeps a double-click from issuing two consent
    /// PUTs. Cleared when the write completes, success or failure alike
    /// (status.rs:446-447, :487), so a failed opt-in leaves the banner up
    /// AND clickable.
    var privacyBannerOptInInflight = false

    init(
        mode: OpenGrokPagerMode,
        terminal: OpenGrokLiveTerminal,
        sink: any PagerTerminalSink,
        workingDirectory: String = FileManager.default.currentDirectoryPath,
        modelName: String = "unknown",
        modelCatalog: [LiveModelPickerEntry] = [],
        catalogStore: LiveModelCatalogStore? = nil,
        modelSwitch: LiveModelSwitchCoordinator? = nil,
        providerBoundarySync: (@Sendable (Bool) async throws -> Void)? = nil,
        permissionCoordinator: PagerPermissionCoordinator? = nil,
        questionCoordinator: PagerQuestionCoordinator? = nil,
        planApprovalCoordinator: PagerPlanApprovalCoordinator? = nil,
        permissionMode: LiveSessionPermissionMode? = nil,
        workflowRegistry: RhaiWorkflowRunRegistry? = nil,
        workflowsEnabled: Bool = true,
        mouseReportingToggleEnabled: Bool? = nil,
        terminalProgram: String? = nil,
        enableMouseReporting: Bool = true,
        uiConfiguration: ResolvedUIConfiguration? = nil,
        themePreference: PagerThemePreference? = nil,
        reasoningEffort: String? = nil,
        compaction: LiveCompactionCoordinator? = nil,
        sessionID: String = "",
        sessionServices: LiveSessionServices? = nil,
        conversationHistory: LiveConversationHistory? = nil,
        sessionCatalog: LiveSessionCatalog? = nil,
        conversationStore: LiveConversationStore? = nil,
        mcpServers: [MCPServerConnection] = [],
        openGrokHome: URL? = nil,
        announcements: LiveAnnouncementsComposition? = nil,
        changelog: ChangelogManager? = nil,
        codingDataRetention: LiveCodingDataRetentionClient? = nil,
        paintCadence: TimeInterval = PagerMotion.defaultPaintCadence,
        environment: [String: String]? = nil,
        toolExecutor: LiveToolExecutor? = nil,
        pagerRuntime: LivePagerRuntimeAdapter? = nil,
        authServices: LivePagerAuthServices = .production,
        urlOpener: (@Sendable (URL) -> Void)? = nil
    ) {
        self.mode = mode
        self.sessionID = sessionID
        self.sessionServices = sessionServices
        self.conversationHistory = conversationHistory
        self.sessionCatalog = sessionCatalog
        self.conversationStore = conversationStore
        self.mcpServers = mcpServers
        self.openGrokHome = openGrokHome ?? OpenGrokHomeResolver
            .resolve(environment: ProcessInfo.processInfo.environment)
        self.announcements = announcements
        self.changelog = changelog
        self.codingDataRetention = codingDataRetention
        self.terminal = terminal
        self.sink = sink
        self.workingDirectory = workingDirectory
        self.modelName = modelName
        self.modelCatalog = modelCatalog.isEmpty
            ? [LiveModelPickerEntry(id: modelName, providerID: "", name: modelName)]
            : modelCatalog
        self.catalogStore = catalogStore
        self.modelSwitch = modelSwitch
        self.providerBoundarySync = providerBoundarySync
        self.permissionCoordinator = permissionCoordinator
        self.questionCoordinator = questionCoordinator
        self.planApprovalCoordinator = planApprovalCoordinator
        self.permissionMode = permissionMode
        self.workflowRegistry = workflowRegistry
        self.workflowsEnabled = workflowsEnabled
        self.compaction = compaction
        self.toolExecutor = toolExecutor
        self.pagerRuntime = pagerRuntime
        self.dashboardDispatchWorkingDirectory = workingDirectory
        self.mouseReportingEnabled = enableMouseReporting
        self.reasoningEffort = reasoningEffort

        // Minimal mode locks the terminal's own palette, matching the
        // reference's terminal-native lock. Everything else resolves the stored
        // preference against what this terminal can render, so a truecolor-only
        // theme degrades to GrokNight instead of to mush.
        let environment = environment ?? ProcessInfo.processInfo.environment
        self.environment = environment
        self.fpsHud = PagerFpsHud(
            environmentValue: environment[pagerFpsHudEnvironmentVariable]
        )
        self.authServices = authServices
        // Prefer an explicit opener (tests) over the auth-services default so
        // link-click proofs never touch the real browser seam.
        self.urlOpener = urlOpener ?? authServices.openBrowser
        self.voiceState = LiveVoiceSessionState(
            capabilities: LiveVoiceComposition.resolveCapabilities(environment: environment)
        )
        let resolvedUIConfiguration = uiConfiguration ?? Self.resolveUIConfig(
            workingDirectory: URL(fileURLWithPath: workingDirectory, isDirectory: true),
            environment: environment
        )
        // Explicit init override wins (tests); otherwise the startup-resolved
        // gate from effective UiConfig / env. Never re-read process cwd here.
        self.mouseReportingToggleEnabled =
            mouseReportingToggleEnabled ?? resolvedUIConfiguration.mouseReportingToggleEnabled
        inputModes = resolvedUIConfiguration.inputModes
        let uiConfig = resolvedUIConfiguration.config
        // Scroll normalizer: brand from TERM_PROGRAM, multiplexer from the
        // pinned env markers (TMUX/STY/ZELLIJ/cmux/herdr), overrides from the
        // effective `[ui]` scroll keys. Profile stays in charge while
        // `scroll_lines` is unset.
        let brand = MouseScrollTerminalBrand.from(termProgram: terminalProgram)
        let multiplexer = Self.mouseScrollMultiplexer(from: environment)
        let settings = LiveScrollSettings(uiConfig: uiConfig)
        self.scrollBrand = brand
        self.scrollMultiplexer = multiplexer
        self.scrollSettings = settings
        self.scrollConfig = ScrollConfig.from(
            brand: brand,
            multiplexer: multiplexer,
            overrides: settings.asOverrides()
        )
        // Same uptime epoch as live mouse events / controller scroll clock —
        // a zero origin would make the first real event look centuries overdue
        // for the 16 ms redraw cadence.
        self.mouseScrollState = MouseScrollState(now: Self.monotonicNow())
        // `[ui].keep_text_selection` with legacy precedence
        // (`text_selection_from_ui`, appearance/cache.rs at 650c1db7).
        self.keepTextSelectionMode = PagerKeepTextSelectionMode.fromCanonical(
            uiConfig.resolvedKeepTextSelection()
        ) ?? .flash
        // `[animation]` from `$OPENGROK_HOME/pager.toml` — one-shot before
        // first frame (`ConfigWatcher::start_static`, watcher.rs:46-54).
        // Path is the resolved home already on this renderer, never process
        // cwd. `show_fps` is parsed inert; the FPS HUD is `GROK_FPS` /
        // `/debug fps`, not this key.
        let animation = PagerAnimationConfigLoader.load(openGrokHome: self.openGrokHome)
        self.animationFPS = animation.config.fps
        self.waveRows = animation.config.waveRows
        // `[scrollback.display].sticky_headers` — same one-shot pager.toml
        // load as animation (`ConfigWatcher::start_static`, watcher.rs:46-54).
        // Path is the resolved home already on this renderer, never process
        // cwd and never project `.opengrok/`. Absent key → true.
        let stickyHeaders = PagerStickyHeadersConfigLoader.load(openGrokHome: self.openGrokHome)
        self.stickyHeadersEnabled = stickyHeaders.config.enabled
        self.stickyHeadersStartupDiagnostics = stickyHeaders.diagnostics
        // `[ui] compact_mode` reaches the first frame the same way the theme
        // does — hydrated here, before `begin()` paints anything (upstream
        // seeds the initial appearance from the user value + terminal rows at
        // `event_loop.rs:1492`). `UIConfig.compactMode` round-trips the key
        // (UIConfig.swift:420,468), so absent means the `false` default.
        userCompactMode = uiConfig.compactMode
        // `[ui] show_timestamps` hydrates the same way (`event_loop.rs:1496`
        // via `load_timestamps`, `appearance/cache.rs:96-108`). The key is
        // `Option<bool>` (`ui_config.rs:110`) and ABSENT MEANS ON —
        // `TIMESTAMPS_DEFAULT = true` (`appearance/cache.rs:28`), the same
        // `unwrap_or(true)` every upstream read applies.
        userShowTimestamps = uiConfig.showTimestamps ?? true
        // `[ui] show_timeline` hydrates the same way (`event_loop.rs:1497`
        // via `load_show_timeline`, `appearance/cache.rs:122-134`). The key
        // is `Option<bool>` (`ui_config.rs:114`) and ABSENT MEANS OFF — the
        // rail is opt-in, `SHOW_TIMELINE_DEFAULT = false` (`ui_config.rs:392`,
        // the single source `show_timeline_enabled()` resolves through).
        userShowTimeline = uiConfig.showTimeline ?? false
        // `[ui] page_flip_on_send` hydrates the same way (`event_loop.rs:1541-1542`
        // via `load_page_flip_on_send`, `appearance/cache.rs:149-163`). The key
        // is `Option<bool>` (`ui_config.rs:118`) and ABSENT MEANS ON —
        // `PAGE_FLIP_ON_SEND_DEFAULT = true` (`appearance/cache.rs:145`), the
        // same default `page_flip_on_send_enabled()` resolves through.
        userPageFlipOnSend = uiConfig.pageFlipOnSendEnabled()
        let autoDark = Self.themeKind(from: uiConfig.autoDarkTheme)
        let autoLight = Self.themeKind(from: uiConfig.autoLightTheme)
        self.autoDarkThemeKind = autoDark
        self.autoLightThemeKind = autoLight
        let resolvedPreference = themePreference ?? Self.themePreference(from: uiConfig)
        let level = pagerDetectColorLevel(environment: environment, isTTY: terminal.size() != nil)
        let resolution = pagerResolveTheme(
            preference: resolvedPreference,
            colorLevel: level,
            appearance: resolvedPreference == .auto ? PagerSystemAppearance.detect() : nil,
            darkTheme: autoDark,
            lightTheme: autoLight,
            terminalNativeLock: mode != .fullScreen
        )
        self.themePreference = resolvedPreference
        self.renderTheme = resolution.theme
        self.colorLevel = level
        self.motionEnabled = PagerMotionState.motionEnabled(
            environment: environment,
            isTTY: terminal.isTTY()
        )

        let size = terminal.size() ?? OpenGrokLiveTerminalSize(width: 80, height: 24)
        self.terminalSize = OpenGrokTerminalCore.TerminalSize(
            width: size.width,
            height: size.height
        )
        self.renderer = PagerTerminalRenderer(
            sink: sink,
            configuration: PagerTerminalRendererConfiguration(
                mode: mode == .fullScreen
                    ? .fullscreen
                    : .inline(height: max(1, min(12, size.height))),
                useAlternateScreen: mode == .fullScreen,
                useSynchronizedOutput: true,
                useMouseReporting: enableMouseReporting,
                paintCadence: paintCadence
            )
        )
        // B2-M4: `.minimal` gets the real scrollback-native frontend instead
        // of the degraded inline strip it fell to before. The host owns its
        // own inline `Terminal` over the same sink; a failed construction
        // (a sink with no usable size is not one of them — the provider
        // falls back) degrades to the strip rather than refusing the launch.
        if mode == .minimal {
            self.minimalHost = try? PagerMinimalFrameHost(
                sink: sink,
                sizeProvider: { [terminal] in
                    let size = terminal.size() ?? OpenGrokLiveTerminalSize(width: 80, height: 24)
                    return OpenGrokTerminalCore.TerminalSize(
                        width: size.width, height: size.height
                    )
                },
                welcome: MinimalWelcomeCardInfo(
                    version: OpenGrokVersion.compiledVersion,
                    workingDirectory: LivePagerChrome.collapseHome(workingDirectory),
                    model: modelName
                )
            )
        } else {
            self.minimalHost = nil
        }
    }

    /// Effective `[ui]` from the same config chain as `resolveDisplayRefreshPolicy`.
    /// A malformed section falls back to `UiConfig()` defaults rather than
    /// blocking startup — matching the tolerant decoders on the Codable twin.
    ///
    /// Also seeds the mouse-reporting toggle gate from the same document +
    /// environment so the controller never re-reads the process cwd.
    nonisolated static func resolveUIConfig(
        workingDirectory: URL,
        environment: [String: String]
    ) -> ResolvedUIConfiguration {
        let document = (try? loadAuthorityComposition(
            cwd: workingDirectory,
            environment: environment
        ).effective()) ?? .table(TOMLTable())
        guard let ui = document[path: ["ui"]] else {
            let config = UiConfig()
            return ResolvedUIConfiguration(
                config: config,
                inputModes: OpenGrokPagerInputModes(),
                mouseReportingToggleEnabled: resolveMouseReportingToggle(
                    document: document,
                    ui: config,
                    environment: environment
                ).value
            )
        }
        let config = (try? jsonValue(from: ui).decode(UiConfig.self)) ?? UiConfig()
        return ResolvedUIConfiguration(
            config: config,
            inputModes: OpenGrokPagerInputModes(
                isMultiline: false,
                isVimMode: config.vimMode ?? false,
                enterSteers: boolValue(ui[path: ["enter_steers"]]),
                combineQueuedPrompts: boolValue(ui[path: ["combine_queued_prompts"]])
            ),
            mouseReportingToggleEnabled: resolveMouseReportingToggle(
                document: document,
                ui: config,
                environment: environment
            ).value
        )
    }

    nonisolated static func boolValue(_ value: TOMLValue?) -> Bool {
        guard let value, case .boolean(let flag) = value else { return false }
        return flag
    }

    static func themePreference(from ui: UiConfig) -> PagerThemePreference {
        guard let raw = ui.theme?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let preference = PagerThemePreference.named(raw)
        else { return .fixed(.grokNight) }
        return preference
    }

    static func themeKind(from name: String?) -> PagerThemeKind? {
        guard let raw = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        return PagerThemeKind.named(raw)
    }

    /// Bridge the effective-config TOML subtree into `UiConfig`'s JSON decoder.
    /// Wrong-typed leaves become absent fields upstream would treat as inherit.
    static func jsonValue(from toml: TOMLValue) -> JSONValue {
        switch toml {
        case .string(let value):
            return .string(value)
        case .integer(let value):
            return .number(.int64(value))
        case .float(let value):
            return .number(.double(value))
        case .boolean(let value):
            return .bool(value)
        case .datetime(let value):
            return .string(value)
        case .array(let values):
            return .array(values.map { jsonValue(from: $0) })
        case .table(let table):
            var object: [String: JSONValue] = [:]
            for (key, value) in table.pairs {
                object[key] = jsonValue(from: value)
            }
            return .object(object)
        }
    }

    /// Install the controller-facing motion feed. Called by the composition
    /// after the controller exists (the renderer is constructed first), and
    /// immediately publishes the current state so a welcome logo that is
    /// already on screen arms the shimmer ticker without waiting for input.
    ///
    /// Single-flight teardown: cancel and *await* the prior delivery so an
    /// already-entered sink await cannot publish into a replaced controller.
    /// Cancellation alone cannot interrupt that await. The install epoch
    /// guards concurrent replacements that hop in while this method awaits —
    /// an older setter must not overwrite a newer one after its await.
    func setMotionStateSink(
        _ sink: (@Sendable (PagerMotionState) async -> Void)?
    ) async {
        motionSinkEpoch &+= 1
        let installEpoch = motionSinkEpoch
        let priorDelivery = motionDeliveryTask
        motionDeliveryTask = nil
        pendingMotionDelivery = nil
        motionSink = nil
        lastPublishedMotionState = nil
        priorDelivery?.cancel()
        // Actor is free while awaiting: the delivery task is typically parked
        // inside the old sink. Sinks must not re-enter `setMotionStateSink`
        // or they deadlock against this await.
        await priorDelivery?.value
        guard installEpoch == motionSinkEpoch else { return }
        motionSink = sink
        guard sink != nil else { return }
        publishMotionState()
    }

    /// Shared host→renderer sink for one live composition. Captures `self`
    /// weakly and the install generation so teardown/replacement cannot form
    /// a strong cycle or re-arm after restore.
    func makeActiveBackgroundWorkSink() -> LiveActiveBackgroundWorkSink {
        activeBackgroundWorkSinkGeneration &+= 1
        let generation = activeBackgroundWorkSinkGeneration
        return { [weak self] event in
            await self?.applyActiveBackgroundWork(event, generation: generation)
        }
    }

    /// Retire the current host sink generation without touching motion. The
    /// composition clears host sinks first; restore then clears the cache and
    /// publishes final demand before `setMotionStateSink(nil)`.
    func retireActiveBackgroundWorkSinkGeneration() {
        activeBackgroundWorkSinkGeneration &+= 1
    }

    /// Apply one host event idempotently. Count changes publish motion and
    /// repaint (fullscreen/inline). Minimal keeps the cache for probes but
    /// never arms motion or paints a status chip the scrollback host lacks.
    /// Restored / stale-generation events are ignored.
    func applyActiveBackgroundWork(
        _ event: LiveActiveBackgroundWorkEvent,
        generation: UInt64? = nil
    ) {
        if let generation, generation != activeBackgroundWorkSinkGeneration {
            return
        }
        guard !restored else { return }
        guard activeBackgroundWork.apply(event) else { return }
        // Minimal: membership stays accurate for probes / tear-down, but the
        // scrollback frontend has no chip and must not force a fast ticker.
        guard minimalHost == nil else { return }
        publishMotionState()
        try? renderState()
    }

    /// Drop every tracked id. Caller publishes motion while the sink is still
    /// installed so a final `.none` (background-only) can land ordered.
    func clearActiveBackgroundWorkCache() {
        activeBackgroundWork.removeAll()
    }

    /// Install the settings-to-controller mode bridge after both actors exist.
    /// The whole value crosses at once so no frame can observe a mixed snapshot.
    func setInputModesSink(
        _ sink: (@Sendable (OpenGrokPagerInputModes) async -> Void)?
    ) {
        inputModesSink = sink
    }

    /// Install `/transcript`'s suspend host. Post-construction like
    /// `setMotionStateSink`, because both halves live in the composition: the
    /// input resource owns park/lease, and the environment is the context's
    /// audited copy rather than `ProcessInfo` (AGENTS.md §2's process-global
    /// trap, applied to env).
    func setSuspendHost(_ host: LiveTUISuspendHost?) {
        suspendHost = host
    }

    /// Install the voice→composer bridge so dictated finals land in the
    /// controller's editor, not only this renderer's painted copy.
    func setVoicePromptSink(_ sink: (@Sendable (String) async -> Void)?) {
        voicePromptSink = sink
    }

    /// `/dream` — consolidate session logs through the auxiliary sampler route.
    func runDreamCommand() async {
        let dreamConfig = sessionServices?.memory?.configuration.dream ?? MemoryDreamConfig()
        let sampler: LiveMemoryDreamSampler?
        if let modelSwitch {
            let sessionID = self.sessionID
            sampler = LiveMemoryDreamSampler { systemPrompt, userMessage in
                let route = await modelSwitch.auxiliaryRecapRoute(explicitModelID: nil)
                var items: [ConversationItem] = []
                if !systemPrompt.isEmpty {
                    items.append(.system(systemPrompt))
                }
                items.append(.user(userMessage))
                let response = try await route.sampler.sample(
                    OpenGrokLiveSamplingRequest(
                        sessionID: sessionID,
                        turnID: "xai-dream-\(UUID().uuidString)",
                        model: route.configuration.model,
                        prompt: userMessage,
                        items: items,
                        tools: []
                    )
                ) { _ in }
                return response.output
            }
        } else {
            sampler = nil
        }
        note(await LiveMemoryCommands.dream(
            backend: sessionServices?.memory,
            dreamConfig: dreamConfig,
            sessionID: sessionID,
            sampler: sampler
        ))
    }

    /// `/voice` — toggle microphone dictation into the prompt (no auto-send).
    func runVoiceCommand() async {
        // Copy out of actor isolation: `inout` across an async call is illegal
        // on an isolated stored property.
        var state = voiceState
        let result = await LiveVoiceCommands.toggle(state: &state)
        voiceState = state
        if let message = result.message {
            note(message)
        } else {
            switch result.action {
            case .startedListening:
                note("Listening… (/voice again to stop)")
                startVoiceEventDrain()
            case .stoppedListening:
                note("Voice dictation stopped.")
                voiceEventTask?.cancel()
                voiceEventTask = nil
            case .unavailable, .ignored:
                break
            }
        }
        try? renderState()
    }

    func startVoiceEventDrain() {
        voiceEventTask?.cancel()
        guard let pipeline = voiceState.pipeline?.pipeline else { return }
        voiceEventTask = Task { [weak self] in
            for await event in pipeline.events {
                guard let self else { return }
                await self.applyVoiceEvent(event)
            }
        }
    }

    func applyVoiceEvent(_ event: VoiceEvent) async {
        var interim = ""
        var draft = prompt.text
        let redraw = LiveVoiceEventHandling.apply(event, interim: &interim, prompt: &draft)
        guard redraw else { return }
        if case .utteranceFinal = event {
            prompt = OpenGrokPagerInteractivePromptState(
                text: draft,
                cursorOffset: draft.count
            )
            if let voicePromptSink {
                await voicePromptSink(draft)
            }
        } else if case .error(let message, _) = event, !message.isEmpty {
            note(message)
        }
        try? renderState()
    }

    /// Pull the current announcement banner from the live composition into
    /// the cached projection the renderer paints. Called after construction
    /// (so the first frame shows a cached banner without blocking on the
    /// hide-key store) and after a hide dismissal (so the next non-hidden
    /// announcement, if any, takes the slot). A no-op when the composition is
    /// absent — the banner stays `nil` and the slot is closed.
    func refreshAnnouncementBanner() async {
        guard let announcements else { return }
        announcementBanner = await announcements.refreshVisibleBanner()
        // The welcome hero shows the same slot selection in its info slot
        // (`app_view.rs:4937-4964` at pin 650c1db7), so a hide/show that
        // changed the slot must swap the OPEN welcome's arm in place —
        // announcement to next-or-changelog — through the W2
        // prefetch-completion seam (no visible change, no repaint).
        refreshWelcomeInPlace()
    }

    /// Hydrate the privacy banner's gate state from what this session can
    /// actually see — upstream's startup resolution (event_loop.rs:1007-1029
    /// at pin 650c1db7), run from `begin()` because that is this port's
    /// pager-startup seam.
    ///
    /// Inputs, and where each one honestly comes from at this seam:
    ///  - Auth metadata (team, role, ZDR, retention opt-out) reads the REAL
    ///    credential through `AuthManager` over the injected home and
    ///    audited env — the same construction `/login`/`/logout` use, which
    ///    is how auth-derived state flows to this renderer (there is no
    ///    separate auth-metadata channel). An xAI credential applies its
    ///    metadata (`apply_auth_meta`, app_view.rs:1753-1762); a non-xAI
    ///    credential gets upstream's cleared access controls
    ///    (`clear_xai_access_controls`, app_view.rs:1662-1675 — opt-out
    ///    FALSE, so the banner cannot upsell a Codex-only session); no
    ///    credential keeps the construction defaults with auth not Done.
    ///  - `remoteSettings` is nil today: the interactive composition has no
    ///    `/v1/settings` fetch (the recorded LiveShareComposition gap), so
    ///    the rollout resolves FALSE — this slice ships dark — while the
    ///    env overrides (`GROK_PRIVACY_NOTICE_ROLLOUT`,
    ///    `GROK_PRIVACY_BANNER_RESHOW_DAYS`) stay live. When a settings
    ///    fetch lands, it feeds this parameter and the same resolvers keep
    ///    upstream's env-over-remote precedence
    ///    (acp_handler/settings.rs:135-150).
    ///  - `trustDone` is true because this port decides folder trust
    ///    synchronously before the renderer exists
    ///    (`LiveSecurityContext.resolve`; undecided is treated untrusted) —
    ///    there is no pending trust question for a live renderer to wait
    ///    on, unlike upstream's `TrustState`.
    func refreshPrivacyBannerState(remoteSettings: RemoteSettings? = nil) async {
        let env = environment
        let manager = AuthManager(
            grokHome: openGrokHome,
            config: GrokComConfig.default(environment: env),
            environment: env
        )
        let auth = await manager.currentOrExpired()
        let acked = PagerPrivacyBannerAckStore(
            configPath: openGrokHome.appendingPathComponent("config.toml")
        ).read()
        // Privacy / access fields reach the banner only through the
        // allowlisted projection (RemoteSettingsAllowlist).
        let allowed = remoteSettings.map { AllowlistedRemoteSettings(projecting: $0) }
        var projectedRemote = RemoteSettings()
        if let allowed {
            projectedRemote.privacyNoticeRollout = allowed.privacyNoticeRollout
            projectedRemote.privacyBannerReshowDays = allowed.privacyBannerReshowDays
        }

        var state = PagerPrivacyBannerState(
            minimalMode: mode == .minimal,
            privacyNoticeRollout: resolvePrivacyNoticeRollout(
                remoteSettings: remoteSettings == nil ? nil : projectedRemote,
                environment: env
            ),
            privacyBannerReshowDays: resolvePrivacyBannerReshowDays(
                remoteSettings: remoteSettings == nil ? nil : projectedRemote,
                environment: env
            ),
            privacyBannerAcked: acked,
            zdrAccessEnabled: allowed?.zdrAccessEnabled ?? false,
            // `has_access()` is "no gate": a gate exists only when remote
            // settings carry a non-empty `gate_message`
            // (`gate_from_settings`, app_view.rs:1739-1746).
            hasAccess: allowed?.gateMessage?.isEmpty ?? true,
            trustDone: true
        )
        if let auth {
            state.authDone = true
            if auth.isXAIAuth {
                state.teamName = auth.teamName
                state.teamRole = auth.teamRole
                state.isZDR = auth.isZDRTeam
                state.codingDataRetentionOptOut = auth.codingDataRetentionOptOut
            } else {
                state.codingDataRetentionOptOut = false
            }
        }
        privacyBanner = state
    }

    // MARK: - Coding-data retention write (Wave 18 B9-c2)

    static let codingDataSharingKey = "coding_data_sharing"

    static let welcomeOverlayID = "welcome"
    static let welcomeResumeRowID = "resume"
    static let welcomeChangelogRowID = "changelog"
    static let welcomeQuitRowID = "quit"

    /// Route frontend terminal-ownership transitions to whichever frontend
    /// is live: the minimal frame host or the frame renderer.
    func frontendRestore() throws {
        if let minimalHost {
            try minimalHost.restore()
        } else {
            try renderer.restore()
        }
    }

    func frontendSuspendToChild() throws {
        if let minimalHost {
            try minimalHost.suspendToChild()
        } else {
            try renderer.suspendToChild()
        }
    }

    func frontendResumeFromChild() throws {
        if let minimalHost {
            try minimalHost.resumeFromChild()
        } else {
            try renderer.resumeFromChild()
        }
    }

    func render(_ event: OpenGrokPagerInteractiveEvent) async throws {
        switch event {
        case .lifecycle(let lifecycle):
            if lifecycle == .cancelling { isCancelling = true }
        case .promptChanged(let prompt):
            self.prompt = prompt
        case .turnStarted(let request):
            // A real prompt invalidates an in-flight recap: a late recap must
            // not land mid-turn (cancel_pending_recap_for_new_prompt,
            // recap.rs:509-512).
            recapEpoch &+= 1
            // The welcome screen's lifetime is exactly "before the first turn".
            if !hasStartedFirstTurn {
                hasStartedFirstTurn = true
                overlays.dismiss(id: "welcome")
            }
            let paintUserBlock = request.metadata[
                OpenGrokPagerInteractiveController.interjectionFallbackMetadataKey
            ] == nil
            conversation.startTurn(
                prompt: request.prompt,
                // An interjection-fallback turn's text was already painted at
                // dispatch; a second user block here would duplicate it.
                paintUserBlock: paintUserBlock
            )
            // Pin the just-sent prompt at the viewport top when page-flip is
            // on — upstream's `follow_new_turn(Some(prompt_idx), flip)`
            // (`queue.rs:420-421`, `nav.rs:608-619`). Interjection-fallback
            // turns have no fresh user block to snap (`paintUserBlock:
            // false`).
            if userPageFlipOnSend, paintUserBlock {
                let userIndex = conversation.items.count - 2
                pageFlipUserBlockIndex = userIndex
                try revealBlock(at: userIndex)
            } else {
                pageFlipUserBlockIndex = nil
            }
            turnActivity = "Thinking\u{2026}"
            turnStartedAt = Date()
            // Extrapolated motion clock, not the last painted tick: after an
            // idle gap `motion.seconds` is stale and would bake the gap into
            // the status-row elapsed readout.
            turnStartedAtSeconds = motionEnabled ? currentMotionSeconds() : nil
            turnOutputUTF8Count = 0
            isCancelling = false
            await refreshContextUsage()
        case .session(let event):
            apply(event)
        case .turnFinished:
            finishAssistant()
            endTurn()
            await refreshContextUsage()
        case .sessionReplaced(let sessionID):
            // A swapped conversation invalidates an in-flight recap the same
            // way a new prompt does — it no longer describes this session.
            recapEpoch &+= 1
            let preserveDashboard = preserveDashboardOnNextSessionSwitch
            preserveDashboardOnNextSessionSwitch = false
            registerSessionTab(sessionID)
            resetForNewSession(sessionID: sessionID)
            await synchronizeRendererWorkingDirectory(sessionID: sessionID)
            if let preparation = pendingDashboardWorktree {
                pendingDashboardWorktree = nil
                do {
                    try LiveWorktreeLaunch.attachSession(preparation, sessionID: sessionID)
                } catch {
                    note(String(describing: error))
                }
            }
            if preserveDashboard {
                restoreDashboardAfterSessionSwitch()
            }
        case .sessionResumed(let sessionID):
            recapEpoch &+= 1
            let preserveDashboard = preserveDashboardOnNextSessionSwitch
            preserveDashboardOnNextSessionSwitch = false
            registerSessionTab(sessionID)
            await applyResumedSession(sessionID: sessionID)
            await synchronizeRendererWorkingDirectory(sessionID: sessionID)
            if preserveDashboard {
                restoreDashboardAfterSessionSwitch()
            }
        case .notice(let message):
            appendMessage(PagerMessage(role: .system, text: message))
        case .interjected(let text):
            // The mid-turn interjection echo: a standard user prompt block,
            // upstream's `RenderBlock::interjection_prompt`
            // (acp_handler/mod.rs:743-745), stamped at push like every
            // entry (`entry.rs:198`).
            appendMessage(PagerMessage(role: .user, text: text, createdAt: Date()))
        case .focusChanged(let region):
            switch region {
            case .scrollback:
                selection.focus(itemCount: conversation.items.count)
                // Following the tail while a selection cursor exists would
                // yank the viewport away from the block the user just picked.
                followsBottom = false
            case .prompt:
                selection.unfocus()
            }
        case .modeChanged(let modes):
            // This is controller-to-renderer feedback only. Calling
            // `inputModesSink` here would send `/multiline` and `/vim-mode`
            // straight back to the controller.
            inputModes = modes
        case .scrollback(let command):
            try await applyScrollback(command)
        case .global(let command):
            try await applyGlobal(command)
        case .queueChanged(let count):
            queuedPromptCount = count
        case .viewport(let command):
            applyViewport(command)
        case .overlay(let request):
            try await present(request)
        case .turnCancelled:
            finishAssistant()
            appendMessage(PagerMessage(role: .system, text: "Cancelled."))
            // A cancelled turn must not leave a tool parked on a sheet the user
            // just walked away from.
            await resolveOutstandingPermissions()
            await resolveOutstandingQuestions()
            await resolveOutstandingPlanApprovals()
            endTurn()
        case .turnFailed(let message):
            finishAssistant()
            // Upstream's marker wording (`session_event.rs:172`). The session
            // stays open; the run-ending `.failed` arm below is the only one
            // that may end the transcript.
            appendMessage(PagerMessage(role: .error, text: "Turn failed: \(message)"))
            // Same rule as a cancel: the turn that raised a sheet is gone.
            await resolveOutstandingPermissions()
            await resolveOutstandingQuestions()
            await resolveOutstandingPlanApprovals()
            endTurn()
        case .eof, .shutdown:
            await resolveOutstandingPermissions()
            await resolveOutstandingQuestions()
            await resolveOutstandingPlanApprovals()
            endTurn()
        case .cancelled:
            finishAssistant()
            await resolveOutstandingPermissions()
            await resolveOutstandingQuestions()
            await resolveOutstandingPlanApprovals()
            endTurn()
        case .failed(let message):
            finishAssistant()
            appendMessage(PagerMessage(role: .error, text: message))
            await resolveOutstandingPermissions()
            await resolveOutstandingQuestions()
            await resolveOutstandingPlanApprovals()
            endTurn()
        }
        // `/debug fps` must paint now so the overlay appears this keystroke,
        // but not also ride the coalesced final `renderState` — that pair
        // recorded two HUD samples for one toggle.
        if case .overlay(.debug(let argument)) = event,
           argument.trimmingCharacters(in: .whitespacesAndNewlines) == "fps" {
            try await paintImmediately()
        } else {
            try renderState()
        }
    }

    func endTurn() {
        turnActivity = nil
        turnStartedAt = nil
        turnStartedAtSeconds = nil
        turnOutputUTF8Count = 0
        isCancelling = false
        pageFlipUserBlockIndex = nil
    }

    func resetForNewSession(sessionID: String) {
        self.sessionID = sessionID
        conversation.removeAll()
        selection.unfocus()
        followsBottom = true
        scrollOffset = 0
        lastMaximumScrollOffset = 0
        lastHeaderScreenRows = 0
        queuedPromptCount = 0
        prompt = OpenGrokPagerInteractivePromptState()
        hasStartedFirstTurn = false
        currentPermissionRequestID = nil
        currentQuestionRequestID = nil
        pendingQuestionRequest = nil
        currentPlanApprovalRequestID = nil
        pendingPlanApprovalRequest = nil
        endTurn()
        overlays.removeAll()
        overlays.push(.welcome(welcomeOverlay(), capturesInput: false))
    }

    func synchronizeRendererWorkingDirectory(sessionID: String) async {
        let directory: URL?
        if let entry = leaderRoster.first(where: { $0.sessionId == sessionID }) {
            directory = URL(fileURLWithPath: entry.cwd, isDirectory: true).standardizedFileURL
            if let modelID = entry.modelId { modelName = modelID }
        } else {
            directory = await pagerRuntime?.workingDirectory(sessionID: sessionID)
        }
        guard let directory else { return }
        workingDirectory = directory.path
        if let index = sessionTabs.firstIndex(where: { $0.sessionID == sessionID }) {
            sessionTabs[index].cwd = directory.path
        }
    }

    func restoreDashboardAfterSessionSwitch() {
        dashboardInputMode = nil
        dashboardInputText = ""
        overlays.removeAll()
        overlays.push(buildDashboardOverlay())
        refreshDashboardPeek()
    }

    /// Move the transcript viewport.
    ///
    /// Follow-bottom mirrors `scrollback/state/nav.rs`: scrolling up always
    /// breaks follow, and a downward scroll re-engages it only once it arrives
    /// already clamped at the bottom — the reference's overscroll gesture. A
    /// scroll that merely *lands* at the bottom moved real rows and does not
    /// re-engage.
    ///
    /// Full-page uses `pagerPageScrollRows` at the CURRENT scrollOffset
    /// (content viewport minus sticky header, less a 2-row overlap —
    /// `nav.rs:430-436` / `current_header_screen_rows`). Half-page matches
    /// Rust `half_page_up/down` (`nav.rs:517-524`): `viewport_height / 2`
    /// of the full conversation rect, not half of the post-header content
    /// band — sticky does not change Ctrl-U/Ctrl-D stride.
    func applyViewport(_ command: OpenGrokPagerViewportCommand) {
        // Nav clears a held text highlight (`navigate_scrollback`, ctx.rs:118-126).
        clearPersistentTextSelectionHighlight()
        // Rust: `self.viewport_height / 2` — full pane, not content-after-header.
        let half = max(1, lastConversationHeight / 2)
        switch command {
        case .top:
            followsBottom = false
            scrollOffset = 0
        case .bottom:
            followsBottom = true
            scrollOffset = lastMaximumScrollOffset
        case .lineUp:
            scrollUp(by: 1)
        case .lineDown:
            scrollDown(by: 1)
        case .halfPageUp:
            scrollUp(by: half)
        case .halfPageDown:
            scrollDown(by: half)
        case .pageUp:
            scrollUp(by: currentPageScrollRows())
        case .pageDown:
            scrollDown(by: currentPageScrollRows())
        }
    }

    /// Action-time page stride (Rust `page_scroll_rows`). One layout snapshot
    /// at the current scrollOffset supplies BOTH viewport height and sticky
    /// `headerScreenRows` — never last-painted `lastHeaderScreenRows`, which
    /// goes stale when frames coalesce. Does **not** refresh mouse /
    /// last-painted caches, and uses `fpsHud.currentOverlay` so it cannot
    /// consume the 250ms HUD refresh or record a sample.
    func currentPageScrollRows() -> Int {
        let snapshot = renderPagerFrame(renderState(conversation: conversation.items))
        return pagerPageScrollRows(
            viewportHeight: max(1, snapshot.layout.conversation.height),
            headerScreenRows: snapshot.layout.headerScreenRows
        )
    }

    func scrollUp(by rows: Int) {
        let current = followsBottom ? lastMaximumScrollOffset : scrollOffset
        followsBottom = false
        scrollOffset = max(0, current - rows)
    }

    func scrollDown(by rows: Int) {
        guard !followsBottom else { return }
        let target = min(lastMaximumScrollOffset, scrollOffset + rows)
        if target == scrollOffset {
            // The gesture arrived already clamped at the bottom: re-engage.
            followsBottom = true
        }
        scrollOffset = target
    }

    /// Apply signed normalizer output: negative = up, positive = down.
    func applySignedScrollLines(_ lines: Int) {
        if lines != 0 {
            // Wheel/trackpad scroll dismisses a held highlight (hold mode
            // description: Esc / click / scroll).
            clearPersistentTextSelectionHighlight()
        }
        if lines < 0 {
            scrollUp(by: -lines)
        } else if lines > 0 {
            scrollDown(by: lines)
        }
    }

    /// Price one vertical wheel/trackpad event through `MouseScrollState`
    /// and paint only when the flush returns a nonzero delta.
    @discardableResult
    func applyTranscriptScroll(
        direction: ScrollDirection,
        at now: TimeInterval
    ) throws -> ScrollUpdate {
        let priced = scrollConfig.withViewportHeight(
            UInt16(clamping: max(0, lastConversationHeight))
        )
        let update = mouseScrollState.onScrollEvent(
            now: now,
            direction: direction,
            config: priced
        )
        applySignedScrollLines(update.lines)
        if update.lines != 0 {
            try renderState()
        }
        return update
    }

    /// Shared scroll-clock tick body (protocol + test seam). Returns applied
    /// signed lines so callers never drop the status.
    @discardableResult
    func applyScrollClockTick(at now: TimeInterval) throws -> Int {
        if restored || localMotionHold || overlays.isActive {
            mouseScrollState.cancelStream()
            dragAutoscroll = nil
            return 0
        }
        let update = mouseScrollState.onTick(now: now)
        applySignedScrollLines(update.lines)
        if update.lines != 0 {
            try renderState()
        }
        return update.lines
    }

    /// Edge autoscroll while an active text drag is held — speed ladder
    /// 1/2/3/5, then reclamp head against an **action-time** selection model
    /// at the new `scrollOffset` (`tick_drag_autoscroll` + post-scroll
    /// reclamp). Must not read stale `lastTextSelection` when `renderState`
    /// coalesces (nil paint → caches unchanged).
    func applyTextDragAutoscrollTick() throws {
        guard !restored, !localMotionHold, !overlays.isActive,
              activeTextDrag != nil,
              let autoscroll = dragAutoscroll
        else { return }
        followsBottom = false
        switch autoscroll.direction {
        case .up: scrollUp(by: autoscroll.speed)
        case .down: scrollDown(by: autoscroll.speed)
        }
        // Layout at the new offset without touching last-painted mouse caches.
        let actionModel = layOutCurrentFrame().layout.textSelection
        reclampActiveTextDragHead(against: actionModel)
        if let pointer = lastDragPointer, let model = actionModel {
            dragAutoscroll = pagerComputeTextSelectionAutoscroll(
                mouseRow: pointer.row,
                contentArea: model.conversationArea
            )
        }
        // One coalesced paint carries the remapped head; do not rely on
        // requestFrame having painted before the reclamp.
        try renderState()
    }

    /// Reclamp the active drag head from `lastDragPointer` against `live`
    /// (action-time or last-painted). Stores frozen-identity endpoints.
    func reclampActiveTextDragHead(against live: PagerTextSelectionModel?) {
        guard activeTextDrag != nil, let pointer = lastDragPointer else { return }
        updateActiveTextDrag(col: pointer.col, row: pointer.row, liveModel: live)
    }

    func rebuildScrollConfig() {
        // A live settings rebuild must not leave an old-profile stream
        // pricing residual ticks / gap-finalize under the new overrides.
        mouseScrollState.cancelStream()
        scrollConfig = ScrollConfig.from(
            brand: scrollBrand,
            multiplexer: scrollMultiplexer,
            overrides: scrollSettings.asOverrides()
        )
    }

    /// After a successful user-file clear of any scroll key, rebuild the
    /// actor snapshot from effective `[ui]` so project/managed layers that
    /// were shadowed by the user leaf become live immediately. Other user
    /// keys still present in `$OPENGROK_HOME/config.toml` survive via the
    /// authority merge (user < project < …).
    func reloadScrollSettingsFromEffectiveConfig() {
        let resolved = Self.resolveUIConfig(
            workingDirectory: URL(fileURLWithPath: workingDirectory, isDirectory: true),
            environment: environment
        )
        scrollSettings = LiveScrollSettings(uiConfig: resolved.config)
        rebuildScrollConfig()
        syncOpenSettingsScrollValuesFromSnapshot()
    }

    /// Push the actor scroll snapshot into an open settings modal so a reset
    /// that reveals a project/managed value is visible without reopening.
    func syncOpenSettingsScrollValuesFromSnapshot() {
        overlays.updateSettings { settings in
            if let speed = scrollSettings.speed {
                settings.values["scroll_speed"] = .integer(speed)
            } else {
                settings.values.removeValue(forKey: "scroll_speed")
            }
            if scrollSettings.mode != .auto {
                settings.values["scroll_mode"] = .string(scrollSettings.mode.label)
            } else {
                settings.values.removeValue(forKey: "scroll_mode")
            }
            if let lines = scrollSettings.lines {
                settings.values["scroll_lines"] = .integer(lines)
            } else {
                settings.values.removeValue(forKey: "scroll_lines")
            }
            if scrollSettings.invert {
                settings.values["invert_scroll"] = .bool(true)
            } else {
                settings.values.removeValue(forKey: "invert_scroll")
            }
        }
    }

    static let scrollSettingKeys: Set<String> = [
        "scroll_speed", "scroll_mode", "scroll_lines", "invert_scroll",
    ]

    /// Map diagnostics mux detection onto the scroll normalizer's mux enum
    /// (`detect_multiplexer_from_env`, terminal/mod.rs:903-944).
    nonisolated static func mouseScrollMultiplexer(
        from environment: [String: String]
    ) -> MouseScrollMultiplexer {
        switch detectMultiplexerFromEnv(environment) {
        case .tmux: return .tmux
        case .screen: return .screen
        case .zellij: return .zellij
        case .cmux: return .cmux
        case .herdr: return .herdr
        case .undetected: return .undetected
        }
    }

    /// Canonical `auto`/`wheel`/`trackpad`; unrecognized → `.auto` (silent —
    /// no existing LiveComposition diagnostic pattern for this enum).
    nonisolated static func parseScrollMode(_ raw: String?) -> ScrollInputMode {
        guard let raw else { return .auto }
        switch raw {
        case "auto": return .auto
        case "wheel": return .wheel
        case "trackpad": return .trackpad
        default: return .auto
        }
    }

    func cancelScrollStreamForLifecycle() {
        mouseScrollState.cancelStream()
    }

    func restoreTerminal() async throws {
        guard !restored else { return }
        restored = true
        // A restore mid-gutter-drag must not leave the latch armed for a
        // later session on the same renderer instance.
        clearScrollbarDragLatch()
        // Painted link / composer geometry and click latches are screen-
        // owned: clear so a post-restore synthetic event cannot act on the
        // torn-down frame (same replace-wholesale rule as "no paint").
        lastPaintedLinks = []
        lastComposerHit = nil
        lastKnownComposerContentRect = nil
        promptOwnedComposerGesture = false
        lastToastOccluder = nil
        lastTextSelection = nil
        pendingLinkClick = nil
        pendingScrollbackClick = nil
        clearTextSelectionLatches()
        tableSelectionGeometry = nil
        // Disarm the scroll normalizer before tearing down — residual ticks
        // must not flush into a restored / child-owned screen.
        cancelScrollStreamForLifecycle()
        // A flush firing after restore would paint into a torn-down screen;
        // cancel+await the inherited-actor task (releasing this actor while
        // awaiting) and let `flushPendingFrameNow` re-check `restored`.
        await cancelPendingFlushTask()
        // Restore/shutdown: cancel+await flash Task and drop highlight +
        // deadline — never re-arm into a torn-down screen.
        await cancelTextSelectionFlashTask()
        persistentTextSelection = nil
        tableSelectionGeometry = nil
        textSelectionFlashDeadlineMs = nil
        textSelectionCreatedAtMs = nil
        // Retire the background-work generation and cache *before* clearing
        // the motion sink so (1) late host events cannot re-arm and (2) the
        // ordered publisher still delivers a final `.none` when background
        // alone was holding `.fast`. `setMotionStateSink(nil)` cancels and
        // drops `pendingMotionDelivery`, so we must await the in-flight
        // delivery loop first — otherwise the none never reaches the sink.
        // Host sinks are cleared by composition shutdown before/around restore.
        retireActiveBackgroundWorkSinkGeneration()
        clearActiveBackgroundWorkCache()
        publishMotionState()
        await motionDeliveryTask?.value
        // Retire motion delivery before tearing the screen down — same
        // single-flight await as sink replacement, so a blocked sink cannot
        // publish into a controller after restore.
        await setMotionStateSink(nil)
        // Detach the presenter first, so a tool that asks after this point
        // fails closed instead of suspending on a sheet nobody will paint.
        await permissionCoordinator?.setPresenter(nil)
        await permissionCoordinator?.resolveAll(with: .deny)
        // Same order for questions; the resolution is cancel, not deny — a
        // torn-down questionnaire is a user walking away, which upstream
        // treats as a normal decision (`format.rs:16-22`).
        await questionCoordinator?.setPresenter(nil)
        await questionCoordinator?.resolveAll()
        // Same order for plan approvals: presenter detached first, then the
        // outstanding approvals resolve as upstream's stale cancel — plan
        // mode stays armed (fail closed; see the coordinator's `resolveAll`).
        await planApprovalCoordinator?.setPresenter(nil)
        await planApprovalCoordinator?.resolveAll()
        overlays.removeAll()
        currentPermissionRequestID = nil
        currentQuestionRequestID = nil
        pendingQuestionRequest = nil
        currentPlanApprovalRequestID = nil
        pendingPlanApprovalRequest = nil
        try frontendRestore()
        if mode == .fullScreen {
            try sink.write(transcript)
            try sink.flush()
        }
    }

    func apply(_ event: OpenGrokPagerEvent) {
        switch event {
        case .lifecycle(let lifecycle):
            if lifecycle == .running, turnActivity == nil {
                turnActivity = "Thinking\u{2026}"
                turnStartedAt = turnStartedAt ?? Date()
            }
        case .output(let text):
            appendAssistant(text)
            // Estimated bytes/4, not provider-reported: this event path
            // carries no `TokenUsage` (see `LiveUsageComposition.report`).
            turnOutputUTF8Count += text.utf8.count
            turnActivity = "Responding\u{2026}"
        case .status(let text):
            turnActivity = text
        case .tool(let tool):
            apply(tool)
        case .permissionRequested(let request):
            turnActivity = "Permission required: \(request.prompt)"
        case .completed:
            finishAssistant()
            endTurn()
        case .cancelled:
            finishAssistant()
            endTurn()
        }
    }

    func appendAssistant(_ text: String) {
        conversation.appendAssistant(text)
    }

    func finishAssistant(removingIfEmpty: Bool = false) {
        conversation.finishAssistant(removingIfEmpty: removingIfEmpty)
    }

    func apply(_ tool: OpenGrokPagerToolUpdate) {
        // Terminal states are stamped with the extrapolated motion clock so
        // the 400 ms finish flash survives an idle gap: stamping the last
        // painted tick makes the flash already expired when the ticker
        // resumes. Motion-disabled terminals leave the stamp nil so the
        // block renders already-static.
        conversation.apply(
            tool,
            atSeconds: motionEnabled ? currentMotionSeconds() : nil
        )
        // While a tool runs, the turn-status row shows the tool's own title —
        // the reference has no separate "tool running" phrasing.
        if tool.state == .running {
            turnActivity = tool.name
        }
    }

    // MARK: - Scrollback selection

    func applyScrollback(_ command: OpenGrokPagerScrollbackCommand) async throws {
        // Keyboard nav clears a held text highlight (`navigate_scrollback`).
        clearPersistentTextSelectionHighlight()
        selection.clamp(itemCount: conversation.items.count)
        // `Enter` on the selected block opens it in the viewer, which is the
        // text modal the overlay layer already builds. Handled here rather than
        // in the selection value because only the renderer owns the stack.
        if command == .openBlockViewer {
            guard let index = selection.index,
                  conversation.items.indices.contains(index) else { return }
            let item = conversation.items[index]
            let body = LiveScrollbackSelection.content(of: item)
            overlays.push(.sessionInfo(
                id: "block-viewer",
                title: LivePagerChrome.blockTitle(for: item),
                lines: body
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { PagerStyledLine(text: String($0)) }
            ))
            return
        }

        let outcome = conversation.withItems { items in
            selection.apply(command, items: &items)
        }
        if let clipboard = outcome.clipboard {
            do {
                try LivePagerClipboard.copy(clipboard) { data in
                    try sink.write(String(decoding: data, as: UTF8.self))
                }
                try sink.flush()
            } catch {
                appendMessage(PagerMessage(
                    role: .error,
                    text: "Could not reach the clipboard: \(error)"
                ))
                return
            }
        }
        if let url = outcome.url {
            appendMessage(PagerMessage(role: .system, text: url))
        }
        if let notice = outcome.notice {
            appendMessage(PagerMessage(role: .system, text: notice))
        }
    }

    // MARK: - Overlays

    /// Sticky banner while mouse reporting is off (`MOUSE_OFF_HINT_SCROLLBACK`,
    /// `app/mod.rs:304-307`). Stored in this form; prompt-focused paint swaps
    /// to `mouseOffHintPrompt`.
    static let mouseOffHintScrollback =
        "Ctrl+r to enable mouse reporting and restore TUI features"
    static let mouseOffHintPrompt =
        "/toggle-mouse-reporting to enable mouse reporting and restore TUI features"
    static let mouseReportingOnToast = "Mouse reporting on"
    /// 90 ticks at 30fps (`show_toast`, notices.rs:15-19).
    static let transientToastDuration: TimeInterval = 3.0

    // MARK: - /fork, /tasks

    /// `/fork` — the honest subset of upstream's peer-agent fork
    /// (`dispatch_fork_resolved`): a REAL on-disk copy of the current
    /// session through `LiveConversationStore.fork` (transcript, rewind
    /// sidecar, `parentSessionID`, export boundary), plus the exact
    /// commands that open it. The destination id is generated the way the
    /// CLI's `--fork-session` route generates it
    /// (`resolveConversationRecord`: `options.sessionID ?? UUID().uuidString`)
    /// — one id scheme, not two.
    ///
    /// Arms this port cannot back refuse by name (`LivePagerForkCommand`):
    /// `--worktree` (no fork-into-worktree backing) and a directive (no
    /// persisted first-prompt channel). Upstream's bare-`/fork` worktree
    /// question modal is skipped — with the worktree arm refused, the
    /// question has exactly one honest answer, so bare `/fork` and
    /// `--no-worktree` both fork in place (recorded divergence).
    func performFork(worktreeOverride: Bool?, directive: String?) async {
        guard !sessionID.isEmpty else {
            note(LivePagerForkCommand.noActiveSession)
            return
        }
        guard let conversationStore else {
            // A session with no persistence (headless and test
            // compositions) has no record to copy — saying "no active
            // session" here would be false.
            note("Session forking is unavailable: this session has no session store.")
            return
        }
        if worktreeOverride == true {
            note(LivePagerForkCommand.worktreeRefusal)
            return
        }
        if directive != nil {
            // Refused BEFORE the disk fork: forking and dropping the
            // directive would silently lose user text (AGENTS.md §3).
            note(LivePagerForkCommand.directiveRefusal)
            return
        }
        let destinationID = UUID().uuidString
        do {
            let child = try await conversationStore.fork(
                sourceSessionID: sessionID,
                destinationSessionID: destinationID,
                workingDirectory: URL(fileURLWithPath: workingDirectory, isDirectory: true)
            )
            note(LivePagerForkCommand.forkedNote(sessionID: child.sessionID))
        } catch let error as CLIApplicationError {
            // The store's own copy — "session not found", the legacy
            // boundary refusal — is already user-facing.
            note(error.description)
        } catch {
            note("failed to fork session \(sessionID): \(error)")
        }
    }

    /// `/tasks` — upstream `dispatch_show_tasks`
    /// (`app/dispatch/status.rs:362-370`): the `tasks_block_text` block
    /// committed to the transcript. The three sources the port has are read
    /// live at present time — the workflow registry (like `/workflows`),
    /// the subagent host's children, and the session's owner-scoped shell
    /// background tasks.
    func presentTasksBlock() async {
        // `tasks.rs:33-35`, byte for byte — the one session-less state.
        guard !sessionID.isEmpty else {
            note(LivePagerForkCommand.noActiveSession)
            return
        }
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
        // The scheduled `/loop` rows, read from the SAME host the
        // `scheduler_*` tools mutate — provisional previews included.
        var scheduled: [ScheduledTaskInfo] = []
        if let schedulerHost = toolExecutor?.schedulerHost {
            scheduled = await schedulerHost.displayInfos()
        }
        note(LivePagerTasksBlock.text(
            workflows: workflowViews,
            subagents: subagents,
            tasks: shellTasks,
            scheduled: scheduled
        ))
    }

    // MARK: - /doctor

    /// `/doctor` — the render-layer half. Upstream's TUI dispatch
    /// (`dispatch_doctor`, `app/dispatch/prompt.rs:87-117`) folds LIVE TUI
    /// evidence (fullscreen state, pushed kitty flags, xtversion, runtime
    /// notification findings) into the report before formatting. Wave 20 S12
    /// wires the injectable XTVERSION collector here; the other TUI-only
    /// collectors (kitty/fullscreen/notification) stay honestly Unavailable
    /// until their OnceLock feeds exist.
    func presentDoctor(_ request: OpenGrokPagerDoctorRequest) {
        let terminal = standaloneTerminalContext(environment: environment)
        switch request {
        case .report:
            // `DoctorRequest::Report` → a system scrollback block of
            // `format_doctor` (prompt.rs:96-103) — a multi-section report
            // belongs in the transcript, not a toast (the `/tasks` shape).
            let snapshot = collectStandalone(terminal: terminal, environment: environment)
            note(formatDoctor(DiagnosticsEngine.report(
                snapshot: doctorDiagnosticSnapshot(
                    standalone: snapshot,
                    terminal: terminal
                )
            )))
        case .listFixes:
            // `DoctorRequest::ListFixes` → `format_applicable_automatic_fixes`
            // delivered as a scrollback message (`effects/mod.rs:3900-3908`,
            // `dispatch/task_result.rs:3152-3154`). The bounded live tmux
            // probe runs only when the terminal is tmux-backed, exactly as
            // the CLI list path does.
            let snapshot = collectStandaloneFix(terminal: terminal, id: nil, environment: environment)
            let report = DiagnosticsEngine.report(snapshot: doctorDiagnosticSnapshot(
                standalone: snapshot,
                terminal: terminal
            ))
            note(formatApplicableAutomaticFixes(
                report: report, terminal: terminal, environment: environment
            ))
        case .fix(let value):
            // Resolution first, so a typo gets upstream's parse-time copy
            // (doctor.rs:110-112) rather than the refusal below.
            let id: OpenGrokDiagnostics.DiagnosticId
            do {
                id = try resolveFixID(value)
            } catch {
                note("\(error)\n\(OpenGrokPagerDoctorRequest.usage)")
                return
            }
            // RECORDED DIVERGENCE — honest refusal instead of upstream's
            // confirm-then-apply question (`open_doctor_fix_question`,
            // prompt.rs:120-176). Applying a fix writes the user's shell or
            // tmux config, and upstream never does that without an explicit
            // confirmation; this port's question seam
            // (PagerQuestionCoordinator) is scoped to tool calls mid-turn
            // and is not reachable from the idle slash path, so the honest
            // arms here are refuse or apply-unconfirmed — and an
            // unconfirmed home-config write is the exact thing the
            // confirmation gate exists to prevent (AGENTS.md §5). Cost: a
            // TUI user types one CLI command instead of pressing "Apply".
            let handle = automaticFixChoices().first { $0.0 == id }?.1 ?? id.description
            note(
                "Applying fixes inside the session is not supported in this port yet.\n"
                    + "Preview and apply from your shell instead: open-grok doctor fix \(handle) --yes"
            )
        }
    }

    // MARK: - /login, /logout

    /// `/login codex` — the browser OAuth flow into the isolated Codex store,
    /// spawned so the turn loop keeps running while the user is in the
    /// browser (upstream spawns the same way, `effects/mod.rs:1684-1709`).
    func startCodexLogin() {
        guard codexLoginTask == nil else {
            // Single-flight. Upstream would bind a second callback server on
            // the fallback port (`codex_auth.rs:706-714`); this port refuses
            // the second flow outright (recorded divergence).
            note("A Codex sign-in is already in progress. Finish it in your browser, or wait for it to time out.")
            return
        }
        // Upstream's dispatch notice (`dispatch/auth.rs:119-121`).
        note("Opening your browser to connect OpenAI Codex\u{2026}")
        let authFile = OpenGrokAuthPaths.codexAuthFileURL(environment: environment)
        let endpoints = CodexEndpoints.fromEnvironment(environment)
        let transport = authServices.makeTransport()
        let flow = authServices.codexBrowserLogin
        let openBrowser = authServices.openBrowser
        codexLoginTask = Task {
            let result: Result<CodexCredentials, any Error>
            do {
                let credentials = try await flow(authFile, endpoints, transport, { url in
                    // The auth URL lands in the transcript — upstream's CLI
                    // announce copy (`codex_auth.rs:823-824`), which its
                    // raw-terminal TUI path cannot print (recorded
                    // divergence: upstream's TUI shows no URL at all).
                    Task { await self.announceCodexAuthURL(url) }
                    openBrowser?(url)
                })
                result = .success(credentials)
            } catch {
                result = .failure(error)
            }
            self.finishCodexLogin(result)
        }
    }

    func announceCodexAuthURL(_ url: URL) {
        note("Open this URL if your browser does not open automatically:\n  \(url.absoluteString)")
        try? renderState()
    }

    /// Completion messages are upstream's, byte for byte
    /// (`dispatch/task_result.rs:3853-3871`).
    func finishCodexLogin(_ result: Result<CodexCredentials, any Error>) {
        codexLoginTask = nil
        switch result {
        case .success(let credentials):
            note(liveCodexConnectedMessage(
                email: credentials.email,
                planType: credentials.planType
            ))
            // Upstream refreshes the Codex model catalog on login
            // (`effects/mod.rs:1690-1699`); this is the settings secret-save
            // path's equivalent. Without it the login "succeeds" and `/model`
            // still offers no Codex rows.
            catalogStore?.refreshCredentialSnapshot()
            catalogStore?.spawnBackgroundRefresh()
            Task { await self.reconcileModelStateAfterCatalogRefresh() }
        case .failure(let error):
            appendMessage(PagerMessage(
                role: .error,
                text: "OpenAI Codex login failed: \(LiveAuthComposition.describe(error))"
            ))
        }
        try? renderState()
    }

    /// `/login xai` — upstream `Action::Login`'s browser OAuth arm
    /// (`dispatch_login`, dispatch/auth.rs:668-706 → `run_auth_flow_interactive`
    /// → `oidc::run_login_flow_with_config`), spawned non-blocking like the
    /// codex flow so the turn loop keeps running while the user is in the
    /// browser. The credential lands in the REAL store (auth.json via
    /// `AuthManager` under its file lock) — the same store `/logout` clears.
    ///
    /// RECORDED DIVERGENCES: upstream renders this flow on the welcome screen
    /// with a paste box and aborts a prior attempt on re-dispatch; this port's
    /// transcript is the channel (start header, URL announce, completion),
    /// there is no manual paste channel, and a second dispatch is refused.
    /// The external-auth-provider / devbox pre-flight arms and the opt-in
    /// device transport (flow.rs:640-724) are not wired at this seam.
    func startXAILogin() {
        guard xaiLoginTask == nil else {
            note("An xAI sign-in is already in progress. Finish it in your browser, or wait for it to time out.")
            return
        }
        // Upstream's loopback-arm welcome header (views/welcome/mod.rs:1022).
        note("A browser window will open for authentication.")
        let env = environment
        let manager = AuthManager(
            grokHome: openGrokHome,
            config: GrokComConfig.default(environment: env),
            environment: env
        )
        let transport = authServices.makeTransport()
        let flow = authServices.xaiBrowserLogin
        let openBrowser = authServices.openBrowser
        xaiLoginTask = Task {
            let result: Result<GrokAuth, any Error>
            do {
                let auth = try await flow(manager, env, transport, { url in
                    // The CLI announce copy (oidc/login.rs:439-440); upstream's
                    // TUI paints the same URL on the welcome screen, which this
                    // port does not have.
                    Task { await self.announceXAIAuthURL(url) }
                    openBrowser?(url)
                })
                result = .success(auth)
            } catch {
                result = .failure(error)
            }
            self.finishXAILogin(result)
        }
    }

    func announceXAIAuthURL(_ url: URL) {
        note("Open this URL to sign in:\n  \(url.absoluteString)")
        try? renderState()
    }

    /// Success copy is the CLI's `report_signed_in` (auth/flow.rs:872-878);
    /// upstream's TUI shows no transcript toast — completion repaints the
    /// welcome view — so the CLI line is the only upstream connected copy.
    /// Failure copy is the TUI's startup-arm format (task_result.rs:3231).
    func finishXAILogin(_ result: Result<GrokAuth, any Error>) {
        xaiLoginTask = nil
        switch result {
        case .success(let auth):
            if let email = auth.email, !email.trimmingCharacters(in: .whitespaces).isEmpty {
                note("✓ Signed in as \(email)")
            } else {
                note("✓ Signed in")
            }
            // Same post-login pair as the codex arm: recompute the credential
            // snapshot and fire the background catalog refresh
            // (effects/mod.rs:1690-1699's equivalent at this seam). The LIVE
            // session's sampler keeps its old bearer until the first 401
            // adopts the new disk credential (`AuthManager` sibling adoption
            // via `refreshAfterUnauthorized`); a `/model` re-pick resolves
            // fresh from disk immediately.
            catalogStore?.refreshCredentialSnapshot()
            catalogStore?.spawnBackgroundRefresh()
            Task { await self.reconcileModelStateAfterCatalogRefresh() }
        case .failure(let error):
            appendMessage(PagerMessage(
                role: .error,
                text: "xAI Grok login failed: \(LiveAuthComposition.describe(error))"
            ))
        }
        try? renderState()
    }

    // MARK: - /recap

    /// `/recap` — kick off the session-recap side-call (the manual arm of
    /// `handle_recap`, acp_session_impl/recap.rs:250-507). One read-only
    /// snapshot of the live conversation, ONE tool-free model call on the
    /// independently resolved recap route, and a display-only transcript
    /// line; the conversation is never touched. Spawned so the sample never
    /// blocks the input loop, single-flight like upstream's `recap_in_flight`
    /// claim (recap.rs:294-306).
    func startRecap() async {
        let workingDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        // The shell-side gate is authoritative; default ON
        // (resolve_session_recap, agent/config.rs:2657-2667). Refusal copy is
        // the pager's skip arm (dispatch_send_recap, notes.rs:372-377).
        guard LiveRecap.enabled(
            workingDirectory: workingDirectoryURL,
            openGrokHome: openGrokHome,
            environment: environment
        ) else {
            note("Session recap is not enabled")
            return
        }
        // No live sampling stack or conversation behind this renderer means
        // no session to recap (notes.rs:379-384).
        guard let modelSwitch, let conversationHistory else {
            note("No active session")
            return
        }
        guard recapTask == nil else {
            // Another recap is generating; upstream's in-flight skip answers
            // the manual re-request through the unavailable toast
            // (recap.rs:296-302 → notes.rs:331-340).
            note(LiveRecap.unavailableToast(hasUserMessages: true))
            return
        }
        let conversation = await conversationHistory.items
        // recap_gate's manual arm (session_recap.rs:232-241): nothing to
        // summarize yet — the empty-state copy, and no request leaves the
        // machine.
        guard LiveRecap.mainTurnCount(conversation) > 0 else {
            note(LiveRecap.unavailableToast(hasUserMessages: false))
            return
        }
        // RECORDED DIVERGENCE on the in-progress presentation: upstream shows
        // a loading block whose "Recap" header carries an animated sidebar
        // and is filled in place (notes.rs:398-420, apply_recap_block). This
        // port's transcript has no fill-in-place channel, so the running
        // state is a note in the `/compact` "Compacting…" convention. Cost:
        // the running line stays in scrollback above the result.
        note("Recap\u{2026}")
        try? renderState()

        let configured = LiveRecap.configuredModel(
            workingDirectory: workingDirectoryURL,
            openGrokHome: openGrokHome,
            environment: environment
        )
        let epoch = recapEpoch
        let sessionID = self.sessionID
        recapTask = Task {
            // Explicit `[models] recap` wins; Automatic picks the economical
            // model for the active provider; anything unresolvable falls back
            // to the active session route (sampler_turn.rs:1100-1197).
            let route = await modelSwitch.auxiliaryRecapRoute(explicitModelID: configured)
            // Reasoning strips only where the backend rejects replayed
            // thinking blocks (Anthropic Messages); every other backend keeps
            // the prefix verbatim so the provider prompt cache stays warm
            // (session_recap.rs:62-74).
            let items = LiveRecap.buildItems(
                conversation: conversation,
                tag: "system-reminder",
                stripReasoning: route.configuration.apiBackend == .messages
            )
            // Tool-free request: `tools: []` serializes NO tools field.
            // RECORDED DIVERGENCE: upstream ships the main turn's tool specs
            // unchanged so the cached token prefix matches, and suppresses
            // tool USE through the instruction text alone (recap.rs:354-358);
            // this render layer has no reach into the live tool surface, so
            // the side-call goes tool-free like the compaction sampler
            // (LiveCompaction.swift:69). Cost: the provider's prefix cache
            // diverges from the main turn at the tools block.
            let result: Result<String, any Error>
            do {
                let response = try await route.sampler.sample(
                    OpenGrokLiveSamplingRequest(
                        sessionID: sessionID,
                        turnID: "xai-recap-\(UUID().uuidString)",
                        model: route.configuration.model,
                        prompt: LiveRecap.instruction(tag: "system-reminder"),
                        items: items,
                        tools: []
                    )
                ) { _ in
                    // Display-only side-call: deltas must never stream into
                    // the transcript as assistant text.
                }
                result = .success(response.output)
            } catch {
                result = .failure(error)
            }
            self.finishRecap(epoch: epoch, result: result)
        }
    }

    /// Land the recap. The conversation is deliberately untouched on every
    /// arm — a recap is generated from a read-only snapshot and surfaced for
    /// display only (session_recap.rs:1-12).
    func finishRecap(epoch: UInt64, result: Result<String, any Error>) {
        recapTask = nil
        // A prompt accepted (or a session swapped) while generating: keep the
        // late recap out of a conversation it no longer describes; the manual
        // path still clears its feedback (recap.rs:430-455).
        guard epoch == recapEpoch else {
            note(LiveRecap.unavailableToast(hasUserMessages: true))
            try? renderState()
            return
        }
        switch result {
        case .success(let raw):
            let summary = LiveRecap.cleanText(raw)
            if summary.isEmpty {
                // Empty after the tidy pass reads as no recap
                // (recap.rs:405-428).
                note(LiveRecap.unavailableToast(hasUserMessages: true))
            } else {
                // The pager owns the label — manual and auto render the same
                // "Recap — {summary}" line (SessionEvent::Recap `message()`,
                // scrollback/blocks/session_event.rs:253-256).
                note("Recap \u{2014} \(summary)")
            }
        case .failure:
            // A failed side-call must never break the session: the failure
            // copy paints and the session keeps working (recap.rs:378-401 →
            // recap_unavailable_toast, notes.rs:331-340). The error detail is
            // deliberately not painted — upstream sends it to tracing, never
            // to the client.
            note(LiveRecap.unavailableToast(hasUserMessages: true))
        }
        try? renderState()
    }

    // MARK: - /btw

    /// `/btw <question>` — the side-question side-call
    /// (`handle_side_question`, acp_session_impl/recap.rs:70-180). ONE
    /// read-only snapshot of the live conversation, ONE tool-free model call
    /// on the ACTIVE session route — upstream's
    /// `prepare_chat_completion(false)` + session `sampling_config` model
    /// (recap.rs:81-84, :110-112), never the recap helper route — and a
    /// display-only transcript block; the conversation is never touched.
    /// Every question appends a record to the session's `btw_history.jsonl`,
    /// answered or failed. Spawned so a mid-turn `/btw` samples CONCURRENTLY
    /// with the running turn; there is deliberately no single-flight claim
    /// and no epoch cancel — upstream spawns each side question
    /// independently (run_loop.rs:1913-1919) and carries neither.
    ///
    /// Recorded divergences (beyond the shared tool-free one at the call):
    ///   * No overload-only retry (recap.rs:9-28): the port has no
    ///     sampling-error classification seam, so the call is one-shot and
    ///     the persisted `attempts` is honestly always 1. Cost: a transient
    ///     overload fails a side question upstream would have retried twice.
    ///   * Presentation: upstream shows a dismissible panel
    ///     (`BtwOverlayState`, views/btw_overlay.rs) titled
    ///     "/btw <question>"; this port has no side panel, so the running
    ///     state paints "/btw <question>…" as a note and the answer paints
    ///     as one self-contained note in the panel's scrollback-persist
    ///     shape — header then body (`BtwBlock`, scrollback/blocks/
    ///     btw.rs:48-73). Cost: the running line stays in scrollback above
    ///     the result, and mid-turn output can interleave between the two.
    func startSideQuestion(_ question: String) async {
        // No live sampling stack or conversation behind this renderer means
        // no session to ask against (dispatch_send_btw, notes.rs:293-304).
        guard let modelSwitch, let conversationHistory else {
            note("No active session")
            try? renderState()
            return
        }
        note("/btw \(question)\u{2026}")
        try? renderState()

        let sessionID = self.sessionID
        let store = LiveBtwHistoryStore(openGrokHome: openGrokHome)
        Task {
            let btwSessionID = LiveBtw.makeBtwSessionID()
            let askedAt = Date()
            let route = await modelSwitch.snapshot()
            // Snapshot at dispatch; `/btw` can fire mid-turn, so the
            // trailing incomplete tool run is truncated and reasoning strips
            // only where the backend rejects replayed thinking blocks
            // (recap.rs:86-108).
            let items = LiveBtw.buildItems(
                conversation: await conversationHistory.items,
                question: question,
                tag: "system-reminder",
                stripReasoning: route.configuration.apiBackend == .messages
            )
            // Tool-free request: `tools: []` serializes NO tools field.
            // RECORDED DIVERGENCE (shared with `/recap`): upstream ships the
            // main turn's tool specs unchanged so the cached token prefix
            // matches, and suppresses tool USE through the instruction text
            // alone (recap.rs:106-108, :210-219); this render layer has no
            // reach into the live tool surface. Cost: the provider's prefix
            // cache diverges from the main turn at the tools block.
            let result: Result<String, any Error>
            do {
                let response = try await route.sampler.sample(
                    OpenGrokLiveSamplingRequest(
                        sessionID: sessionID,
                        turnID: LiveBtw.makeRequestID(),
                        model: route.configuration.model,
                        prompt: LiveBtw.instruction(
                            tag: "system-reminder",
                            question: question
                        ),
                        items: items,
                        tools: []
                    )
                ) { _ in
                    // Display-only side-call: deltas must never stream into
                    // the transcript as assistant text.
                }
                result = .success(response.output)
            } catch {
                result = .failure(error)
            }
            // Persist BEFORE painting, success and failure alike — the
            // history file is the question's only durable record
            // (handle_side_question's `persist` closure, recap.rs:114-128,
            // :162-179). An append failure is warn-and-continue upstream
            // (persistence.rs:2430-2434); this port has no tracing at this
            // seam, so the miss is silent by the same policy — the answer
            // that already exists must still paint.
            let record: LiveBtwEntry
            switch result {
            case .success(let answer) where !answer.isEmpty:
                record = LiveBtwEntry(
                    btwSessionId: btwSessionID,
                    parentSessionId: sessionID,
                    askedAt: askedAt,
                    question: question,
                    answer: answer,
                    model: route.configuration.model,
                    success: true,
                    error: nil
                )
            case .success:
                record = LiveBtwEntry(
                    btwSessionId: btwSessionID,
                    parentSessionId: sessionID,
                    askedAt: askedAt,
                    question: question,
                    answer: "",
                    model: route.configuration.model,
                    success: false,
                    error: LiveBtw.emptyResponseCopy
                )
            case .failure(let error):
                record = LiveBtwEntry(
                    btwSessionId: btwSessionID,
                    parentSessionId: sessionID,
                    askedAt: askedAt,
                    question: question,
                    answer: "",
                    model: route.configuration.model,
                    success: false,
                    error: "side question model call failed: \(String(describing: error))"
                )
            }
            do {
                try await store.append(record)
            } catch {
                // See the persist note above.
            }
            self.finishSideQuestion(question: question, record: record)
        }
    }

    /// Land the side question. The conversation is deliberately untouched on
    /// every arm — the answer is generated from a read-only snapshot and
    /// surfaced for display only, off-conversation by contract
    /// (commands.rs:734-740).
    func finishSideQuestion(question: String, record: LiveBtwEntry) {
        if record.success {
            // The panel's scrollback-persist shape: "/btw <question>" header
            // then the response body (`BtwBlock::output`, scrollback/blocks/
            // btw.rs:48-73) — one self-contained block, so mid-turn output
            // interleaving cannot orphan the answer from its question.
            note("/btw \(question)\n\(record.answer)")
        } else {
            // Upstream's error arm paints the failure into the panel with
            // the "side question failed: …" prefix (effects/mod.rs:
            // 5641-5649); the empty-answer arm carries EmptyResponse's own
            // copy (commands.rs:34-35).
            note(LiveBtw.failureCopy(record.error ?? LiveBtw.emptyResponseCopy))
        }
        try? renderState()
    }

    /// `/logout` — remove the xAI credential from `auth.json`, the same
    /// deletion the CLI route performs (`AuthManager.clear()`). Local file
    /// surgery only, so it runs inline; the notice is upstream's completion
    /// copy (`dispatch/task_result.rs:3798`, `:3826`), chosen by whether the
    /// isolated Codex store survives.
    func performXAILogout() async {
        let manager = AuthManager(
            grokHome: openGrokHome,
            config: GrokComConfig.default(environment: environment),
            environment: environment
        )
        let result: LogoutResult
        do {
            result = try await manager.clear()
        } catch {
            appendMessage(PagerMessage(
                role: .error,
                text: "xAI logout failed: \(LiveAuthComposition.describe(error))"
            ))
            return
        }
        let codexRemains = isCodexLoggedIn(
            at: OpenGrokAuthPaths.codexAuthFileURL(environment: environment)
        )
        note(codexRemains
            ? "xAI Grok disconnected. ChatGPT Codex remains connected."
            : "xAI Grok is disconnected. Sign in to ChatGPT Codex or xAI Grok to continue.")
        // Not upstream copy (its pager logout is an ACP revocation): after a
        // local deletion an env key silently keeps authenticating, which is
        // exactly the "succeeds, does nothing" trap — say so, as the CLI
        // route does.
        if result.apiKeyStillSet {
            note("XAI_API_KEY is still set in your environment and will continue to authenticate requests.")
        }
    }

    /// `/logout codex` — best-effort token revoke, then store deletion
    /// (`logoutCodex`, CodexAuth.swift). Spawned because the revoke leg is a
    /// network call; the completion notice is upstream's
    /// (`dispatch/task_result.rs:3890-3894`).
    func startCodexLogout() {
        let authFile = OpenGrokAuthPaths.codexAuthFileURL(environment: environment)
        let endpoints = CodexEndpoints.fromEnvironment(environment)
        let transport = authServices.makeTransport()
        Task {
            let message: PagerMessage
            var storeRemoved = false
            do {
                storeRemoved = try await logoutCodex(
                    at: authFile,
                    endpoints: endpoints,
                    transport: transport
                )
                message = PagerMessage(
                    role: .system,
                    text: storeRemoved
                        ? "OpenAI Codex disconnected."
                        : "OpenAI Codex was not connected."
                )
            } catch {
                message = PagerMessage(
                    role: .error,
                    text: "OpenAI Codex logout failed: \(LiveAuthComposition.describe(error))"
                )
            }
            self.appendMessage(message)
            if storeRemoved {
                // Upstream clears the Codex catalog on logout
                // (`effects/mod.rs:1721-1725`): the credential snapshot must
                // stop resolving Codex before the republish.
                self.catalogStore?.refreshCredentialSnapshot()
                self.catalogStore?.spawnBackgroundRefresh()
                Task { await self.reconcileModelStateAfterCatalogRefresh() }
            }
            try? self.renderState()
        }
    }

    // MARK: - /resume, /effort, /rename

    /// Repaint the transcript the runtime just restored. The runtime has
    /// already swapped the conversation history, so this is a pure projection
    /// of what is now on disk.
    func applyResumedSession(sessionID: String) async {
        self.sessionID = sessionID
        let items = await conversationHistory?.items ?? []
        // The restored user prompts' original instants, for the
        // `/timestamps` overlay — upstream restores `created_at` from the
        // replay meta's `turn_start_ms` (`acp/tracker.rs:1380-1385`), whose
        // durable source in this port is the rewind sidecar: one point per
        // prompt turn, `created_at` stamped when the turn opened
        // (`LiveRewindPoint`, LiveSessionRecovery.swift). A session with no
        // sidecar (never wrote files, pruned, pre-rewind) restores with no
        // stamps — upstream's `created_at: None` paints nothing — which is
        // honest where re-stamping `Date()` would show load time.
        let rewindPoints = await LiveRewindStore(
            openGrokHome: openGrokHome,
            sessionID: sessionID
        ).load()
        let promptInstants = Dictionary(
            rewindPoints.map { ($0.promptIndex, $0.createdAt) },
            uniquingKeysWith: { first, _ in first }
        )
        conversation.seed(from: items, promptInstants: promptInstants)
        selection.unfocus()
        followsBottom = true
        scrollOffset = 0
        lastMaximumScrollOffset = 0
        lastHeaderScreenRows = 0
        queuedPromptCount = 0
        currentPermissionRequestID = nil
        endTurn()
        overlays.removeAll()
        hasStartedFirstTurn = !conversation.items.isEmpty
        if conversation.items.isEmpty {
            overlays.push(.welcome(welcomeOverlay(), capturesInput: false))
        }
        note("Resumed session \(String(sessionID.prefix(8))) — "
            + "\(conversation.items.count) block\(conversation.items.count == 1 ? "" : "s") restored.")
        await refreshContextUsage()
    }

    /// `/rename <title>` — one title-write through the conversation history
    /// actor (upstream rename.rs:42-53, `Action::RenameSession`).
    func renameSession(title: String) async {
        guard let conversationHistory else {
            // Upstream's no-session refusal (rename.rs:43-45).
            appendMessage(PagerMessage(role: .error, text: "No active session"))
            return
        }
        do {
            try await conversationHistory.rename(title: title)
        } catch {
            appendMessage(PagerMessage(
                role: .error,
                text: "Could not rename the session: \(error)"
            ))
            return
        }
        note("Session renamed to \u{201C}\(title)\u{201D}.")
    }

    // MARK: - Session-scoped commands

    /// `/rewind` — picker on a bare invocation, dry run with a number, restore
    /// only with `--force`.
    ///
    /// The history the coordinator reasons about is the *persisted* one, not the
    /// rendered blocks: the rendered transcript drops nothing but also holds no
    /// tool results, so truncating it positionally is a projection of the real
    /// truncation, not the source of truth.
    func applyRewind(argument: String) async {
        guard let coordinator = sessionServices?.rewind else {
            note("Rewind is disabled for this session (OPENGROK_REWIND=0).")
            return
        }
        let currentItems = await conversationHistory?.items ?? []
        switch await LiveSessionCommands.rewind(
            argument: argument,
            rewind: coordinator,
            currentItems: currentItems
        ) {
        case .message(let text):
            note(text)
        case .overlay(let overlay):
            overlays.push(overlay)
        case .rewound(let targetPromptIndex, _, let summary):
            await commitRewind(toPromptIndex: targetPromptIndex, summary: summary)
        }
    }

    /// Apply a rewind the coordinator has already performed on disk.
    ///
    /// `restore(force: true)` puts the *files* back; the conversation is the
    /// caller's to truncate, which is why this exists rather than living in the
    /// coordinator. Both halves land or neither is claimed: a failed commit is
    /// reported as an error rather than swallowed, because the files have
    /// already moved and a session whose history disagrees with its working tree
    /// is worse than one that says so.
    func commitRewind(toPromptIndex targetPromptIndex: Int, summary: String) async {
        note(summary)
        guard let conversationHistory else { return }
        let sessionDir = openGrokHome.appendingPathComponent("sessions").appendingPathComponent(sessionID)
        let truncated = liveTruncateConversation(
            await conversationHistory.items,
            toPromptIndex: targetPromptIndex,
            sessionDir: sessionDir
        )
        do {
            try await conversationHistory.commit(sessionID: sessionID, items: truncated)
        } catch {
            appendMessage(PagerMessage(
                role: .error,
                text: "Files were restored, but the conversation could not be truncated: \(error)"
            ))
            return
        }
        let marker = SessionUpdateRecord.rewindMarker(targetPromptIndex: targetPromptIndex)
        if let data = try? JSONEncoder().encode(marker),
           let line = String(data: data, encoding: .utf8) {
            let updatesURL = sessionDir.appendingPathComponent("updates.jsonl")
            if let handle = try? FileHandle(forWritingTo: updatesURL) {
                handle.seekToEndOfFile()
                if let lineData = (line + "\n").data(using: .utf8) {
                    handle.write(lineData)
                }
                try? handle.close()
            }
        }
        truncateRenderedTranscript(toPromptIndex: targetPromptIndex)
    }

    /// `/delete` — remove this session's stored transcript.
    ///
    /// Two steps, because there is no second copy and no undo. The confirmed
    /// step clears the in-memory history *before* removing the file: without
    /// that, the next turn would re-commit the whole conversation and the file
    /// would reappear, so "deleted" would have been a lie with a delay on it.
    func deleteSession(confirmed: Bool) async {
        guard let sessionCatalog, !sessionID.isEmpty else {
            note("No active session to delete.")
            return
        }
        guard confirmed else {
            overlays.push(LiveSessionDeleteConfirmation.overlay(
                sessionID: sessionID,
                itemCount: await conversationHistory?.items.count ?? 0
            ))
            return
        }
        if let conversationHistory {
            do {
                try await conversationHistory.commit(sessionID: sessionID, items: [])
            } catch {
                appendMessage(PagerMessage(
                    role: .error,
                    text: "Could not clear the in-memory conversation, so nothing was deleted: \(error)"
                ))
                return
            }
        }
        do {
            guard try sessionCatalog.delete(sessionID: sessionID) else {
                note("This session has not been written to disk yet, so there was nothing to delete.")
                return
            }
        } catch {
            appendMessage(PagerMessage(
                role: .error,
                text: "Could not delete the session: \(error)"
            ))
            return
        }
        conversation.removeAll()
        selection.unfocus()
        followsBottom = true
        note("Session deleted. This session keeps its id, so anything you send now starts its history over.")
        overlays.push(.welcome(welcomeOverlay(), capturesInput: false))
    }

    /// Scroll so the block at `index` sits at the top of the transcript.
    ///
    /// The offset is *measured*, not estimated: the frame function is pure, so
    /// laying out the blocks before `index` at this frame's width returns the
    /// exact line count they occupy — which is the offset that puts `index`
    /// first. Any arithmetic on character counts would drift the moment a block
    /// wrapped differently from the guess.
    func revealBlock(at index: Int) throws {
        guard conversation.items.indices.contains(index) else { return }
        guard index > 0 else {
            followsBottom = false
            scrollOffset = 0
            return
        }
        let probe = renderState(conversation: Array(conversation.items.prefix(index)))
        followsBottom = false
        scrollOffset = renderPagerFrame(probe).layout.totalContentLines
    }

    func note(_ text: String) {
        appendMessage(PagerMessage(role: .system, text: text))
    }

    /// The one door for transcript messages: the welcome overlay blanks the
    /// entire transcript area (contentRows = screenHeight in
    /// PagerOverlayRender), so a message appended while it is up paints
    /// underneath it and never reaches the screen. Upstream never has this
    /// problem because its welcome is a separate view whose command errors
    /// land in a visible agent transcript (app_view.rs ActiveView::Welcome vs
    /// Agent). Cost: a notice arriving on the welcome screen replaces the
    /// logo instead of toasting over it like upstream — visible words win.
    /// Deliberate welcome re-shows (session delete, `.welcomeScreen`) push
    /// *after* their notes, so append-time dismissal leaves them up.
    func appendMessage(_ message: PagerMessage) {
        overlays.dismiss(id: "welcome")
        conversation.appendMessage(message)
        if message.role == .user {
            touchSessionTab(sessionID, title: message.text)
        }
    }

    /// `/transcript` — write the transcript to a temp file and open `$PAGER`
    /// over a suspended TUI (`dispatch/transcript.rs:239-279`; the suspend
    /// sequence is `suspend_for_child`, `event_loop.rs:356-423`, consumed by
    /// the `$PAGER` arm at `event_loop.rs:739-814`).
    ///
    /// Upstream's cursor-position probes around the child
    /// (`event_loop.rs:388-393, 412-418`) are skipped: they exist to
    /// re-anchor minimal mode's inline viewport, and this port's inline
    /// renderer repaints with absolute positioning, so the forced full
    /// redraw after resume recovers on its own. Cost: none for fullscreen;
    /// for inline, a pager that printed to the main screen leaves that text
    /// above the repainted viewport instead of being re-anchored under it.
    func presentTranscriptPager() async throws {
        let content = transcript
        // dispatch/transcript.rs:256-263.
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            note("No conversation transcript to view yet")
            return
        }
        guard let suspendHost else {
            note("This session has no suspendable terminal input, so /transcript cannot open $PAGER.")
            return
        }
        // dispatch/transcript.rs:265-277.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-transcript-\(UUID().uuidString).md")
        do {
            try content.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            note("Failed to write transcript: \(error)")
            return
        }
        let pager = LiveTUISuspendHost.resolvePager(environment: suspendHost.environment)

        // Blocking this path is correct — upstream blocks its event loop in
        // `run_child` (event_loop.rs:400). Local motion hold + host
        // `suspendMotion` keep interleaved ticks from painting; see
        // `runSuspendedChild`.
        let outcome = try await runSuspendedChild(
            host: suspendHost,
            program: pager.program,
            arguments: pager.arguments + [file.path],
            suspendFailPrefix: "Could not suspend the terminal for $PAGER"
        )
        switch outcome {
        case .parkTimedOut:
            note("terminal input reader did not park before suspend")
            try? FileManager.default.removeItem(at: file)
            return
        case .suspendFailed:
            try? FileManager.default.removeItem(at: file)
            return
        case .completed(let launchError):
            if let launchError {
                // Deliberate divergence: upstream discards the pager's status
                // entirely (event_loop.rs:783-786). A launch failure here says
                // why the screen flickered and showed nothing.
                note("Could not run pager \(pager.program): \(launchError)")
            }
            try? FileManager.default.removeItem(at: file) // event_loop.rs:807
            // `resumeFromChild` dropped the previous frame, so the repaint at the
            // end of `render(_:)` is the full-viewport redraw upstream requests
            // after a child (event_loop.rs:811-812, :717-721).
        }
    }

    /// The persona detail's `i` — open a config file in `$VISUAL`/`$EDITOR`
    /// over a suspended TUI. The `$EDITOR` arm of `run_pending_suspends`
    /// (`event_loop.rs:677-736`) on the same suspend seam `/transcript`
    /// uses; the exit status is logged-and-ignored upstream
    /// (`external_editor.rs:274-276`) — the caller refreshes the modal tab
    /// regardless, so an aborted edit still repaints what disk holds.
    ///
    /// Unlike the transcript path there is no temp file: the child edits
    /// the persona file in place (`PendingEditorRequest::ConfigFile`,
    /// `external_editor.rs:36-40`, materializes nothing).
    func suspendForEditor(path: String) async throws {
        guard let suspendHost else {
            note("This session has no suspendable terminal input, so $EDITOR cannot open.")
            return
        }
        // `resolve_editor_argv` (`external_editor.rs:131-137`); a failed
        // parse surfaces upstream's copy through the transcript notice,
        // this port's `report_config_failure` surface (`:246-262`).
        guard let editor = LiveTUISuspendHost.resolveEditor(
            environment: suspendHost.environment
        ) else {
            note("could not parse $VISUAL or $EDITOR")
            return
        }
        let outcome = try await runSuspendedChild(
            host: suspendHost,
            program: editor.program,
            arguments: editor.arguments + [path],
            suspendFailPrefix: "Could not suspend the terminal for $EDITOR"
        )
        switch outcome {
        case .parkTimedOut:
            note("terminal input reader did not park before suspend")
        case .suspendFailed:
            break
        case .completed(let launchError):
            if let launchError {
                // Deliberate divergence, matching the pager arm: upstream only
                // logs a child failure (`external_editor.rs:274-276`); a
                // launch failure here says why the screen flickered and the
                // file never changed.
                note("Could not run editor \(editor.program): \(launchError)")
            }
        }
    }

    enum SuspendedChildOutcome: Sendable {
        case parkTimedOut
        case suspendFailed
        case completed(launchError: (any Error)?)
    }

    /// Cancel the coalesced paint timer and await it without actor deadlock:
    /// bump generation so a stale body cannot `nil` a newer slot, clear the
    /// slot, cancel, then `await` (releasing this actor) so the
    /// inherited-isolation task can exit on cancellation.
    func cancelPendingFlushTask() async {
        pendingFlushGeneration &+= 1
        let flush = pendingFlushTask
        pendingFlushTask = nil
        flush?.cancel()
        if let flush {
            _ = await flush.value
        }
    }

    /// Write to a file when one is named, otherwise to the clipboard.
    func deliver(_ text: String, to filePath: String?, label: String) throws {
        guard let filePath, !filePath.isEmpty else {
            do {
                try LivePagerClipboard.copy(text) { data in
                    try sink.write(String(decoding: data, as: UTF8.self))
                }
                try sink.flush()
                appendMessage(PagerMessage(
                    role: .system,
                    text: "\(label) copied — \(text.count) characters."
                ))
            } catch {
                appendMessage(PagerMessage(
                    role: .error,
                    text: "Could not reach the clipboard: \(error)"
                ))
            }
            return
        }
        let url = LivePagerClipboard.resolve(filePath, relativeTo: workingDirectory)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            appendMessage(PagerMessage(
                role: .system,
                text: "\(label) written to \(url.path)."
            ))
        } catch {
            appendMessage(PagerMessage(
                role: .error,
                text: "Could not write \(url.path): \(error)"
            ))
        }
    }


    /// A control key from the dashboard (`p`/`r`/`x`). Reported as a row
    /// selection by the overlay because the render layer cannot reach a run.
    func handleWorkflowSelection(rowID: String) async -> Bool {
        guard let workflowRegistry,
              let command = LiveWorkflowOverlayBuilder.command(forRowID: rowID)
        else { return false }
        let message = await LiveWorkflowOverlayBuilder.apply(command, registry: workflowRegistry)
        appendMessage(PagerMessage(role: .system, text: message))
        let views = (try? await workflowRegistry.views()) ?? []
        overlays.dismiss(id: "workflows")
        overlays.push(.workflows(rows: LiveWorkflowOverlayBuilder.rows(from: views)))
        return true
    }

    /// Push or replace the permission sheet. Driven by the coordinator's
    /// presenter callback, so `nil` means "the queue drained".
    func showPermission(_ request: PagerPermissionRequest?) async {
        if let current = currentPermissionRequestID {
            overlays.dismiss(id: "permission:\(current)")
            currentPermissionRequestID = nil
        }
        if let request {
            overlays.push(.permission(request))
            currentPermissionRequestID = request.id
        } else if let parked = pendingPlanApprovalRequest {
            // The approval the plan sheet was waiting behind is resolved;
            // surface the parked plan now. (At most one of the two parked
            // slots is occupied — the tool runtime serializes calls.)
            pendingPlanApprovalRequest = nil
            overlays.push(.planApproval(parked))
            currentPlanApprovalRequestID = parked.id
        } else if let parked = pendingQuestionRequest {
            // The approval the question was waiting behind is resolved;
            // surface the parked questionnaire now.
            pendingQuestionRequest = nil
            pushQuestionOverlay(parked)
            currentQuestionRequestID = parked.id
        }
        try? renderState()
    }

    /// Push or replace the question sheet. Driven by the question
    /// coordinator's presenter callback; `nil` means its queue drained.
    /// Permission outranks question (`input.rs:879-1112`): while an approval
    /// sheet is up the questionnaire parks in `pendingQuestionRequest` and
    /// `showPermission(nil)` presents it when the approvals drain.
    ///
    /// No composer stash: upstream stashes and restores the prompt draft
    /// around the question because its view *replaces* the composer
    /// (`acp_handler/interactions.rs:98-108`); this sheet renders above the
    /// composer like the permission sheet does, so the draft survives
    /// untouched without one.
    func showQuestion(_ request: PagerQuestionRequest?) async {
        if let current = currentQuestionRequestID {
            overlays.dismiss(id: "question:\(current)")
            currentQuestionRequestID = nil
        }
        pendingQuestionRequest = nil
        if let request {
            if currentPermissionRequestID != nil {
                pendingQuestionRequest = request
            } else {
                pushQuestionOverlay(request)
                currentQuestionRequestID = request.id
            }
        }
        try? renderState()
    }

    func pushQuestionOverlay(_ request: PagerQuestionRequest) {
        guard let dashboard = overlays.dismiss(id: LiveDashboardOverlay.overlayID) else {
            overlays.push(.question(request))
            return
        }
        overlays.push(.question(request))
        overlays.push(dashboard)
        refreshDashboardPeek()
    }

    /// Push or replace the plan-approval sheet. Driven by the plan
    /// coordinator's presenter callback; `nil` means its queue drained.
    /// Permission outranks it (`input.rs:879-1112`), so a plan arriving
    /// mid-approval parks in `pendingPlanApprovalRequest` and
    /// `showPermission(nil)` presents it when the approvals drain.
    func showPlanApproval(_ request: PagerPlanApprovalRequest?) async {
        if let current = currentPlanApprovalRequestID {
            overlays.dismiss(id: "plan-approval:\(current)")
            currentPlanApprovalRequestID = nil
        }
        pendingPlanApprovalRequest = nil
        if let request {
            if currentPermissionRequestID != nil {
                pendingPlanApprovalRequest = request
            } else {
                overlays.push(.planApproval(request))
                currentPlanApprovalRequestID = request.id
            }
        }
        try? renderState()
    }

    /// `/view-plan` — upstream `dispatch_show_plan` (`dispatch/modes.rs:16-25`):
    /// a pending plan approval reopens its decision sheet; otherwise the
    /// saved plan opens in a preview, or the "No plan written yet." toast.
    func showPlan() async {
        // Reopen first (`modes.rs:18-19`, `reopen_plan_approval`): the head
        // of the coordinator queue is a suspended `exit_plan_mode` call, and
        // re-presenting it restores the decision surface (a/s/q).
        // `showPlanApproval` dismisses any stale copy of the sheet before
        // re-pushing and keeps the permission-outranks parking rule.
        if let pending = await planApprovalCoordinator?.currentRequest {
            await showPlanApproval(pending)
            return
        }
        // `show_plan_preview` (`agent_view/plan.rs:125-146`), reduced to the
        // body sources this port has: approval-carried content is the branch
        // above, there is no inline-plan-content channel (upstream's
        // `latest_inline_plan_content`, `plan.rs:102-108` — recorded
        // divergence), which leaves the on-disk plan file — read at the live
        // tracker's resolved path, the same file the plan-file auto-approval
        // gate compares edits against.
        let planPath = await toolExecutor?.planFileResolvedPath()
        let content = planPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        guard let content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Upstream's toast, byte for byte (`agent_view/plan.rs:144`).
            note("No plan written yet.")
            return
        }
        // Upstream opens a fullscreen markdown line viewer titled `plan.md`
        // (`plan.rs:147-153`); this is the port's read-only text modal over
        // the same body. Markdown that renders to nothing paints raw — the
        // renderer's own contract — split on `Character.isNewline` because
        // plan files come off disk and may carry CRLF (AGENTS.md §2).
        let rendered = PagerMarkdownRenderer().render(content)
        let lines = rendered.isEmpty
            ? content
                .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                .map { PagerStyledLine(text: String($0)) }
            : rendered
        overlays.push(.sessionInfo(id: "plan-preview", title: "plan.md", lines: lines))
    }

    /// Apply the outcome of a row choice, whether it came from `Enter` or a
    /// click. Overlay row ids are domain ids, so both paths land here.
    ///
    /// Returns a slash command the *controller* should run, when the row is one
    /// — only the command palette produces that. The renderer cannot run a
    /// command itself: the vocabulary and the mid-turn deferral both live in the
    /// controller, and duplicating either here is how the two would drift.
    /// Rebuild one extensions tab's rows from its live loader and swap them
    /// into the open modal. The row id carries the tab
    /// (`"reload:{tab}"` — see `PagerOverlayStack.handle`'s `.extensions`
    /// arm); an id this function does not recognize does nothing, because a
    /// stale click must never fabricate a reload.
    func reloadExtensionsOverlay(rowID: String) {
        guard rowID.hasPrefix(LiveExtensionsComposition.reloadRowPrefix),
              let tab = PagerExtensionsTab(
                  rawValue: String(rowID.dropFirst(LiveExtensionsComposition.reloadRowPrefix.count))
              ),
              let existing = overlays.overlays.first(
                  where: { $0.id == LiveExtensionsComposition.overlayID }
              ),
              case .extensions(let current) = existing.content
        else { return }
        overlays.push(.extensions(LiveExtensionsComposition.reloaded(
            current,
            tab: tab,
            workingDirectory: workingDirectory,
            openGrokHome: openGrokHome,
            sessionID: sessionID,
            connections: mcpServers,
            environment: environment
        )))
    }

    /// The current model's `agentType`, from the SAME catalog the model
    /// switch resolves against — upstream's `model_agent_type_from_info`
    /// (`dispatch/transcript.rs:534-543`), empty filtered out. Read at
    /// modal open and again at each `s` re-resolution; upstream stows the
    /// open-time value on the modal state (`model_agent_type`, `:262-264`)
    /// but the model cannot change while the modal captures input, so the
    /// two reads agree.
    var agentsModalModelAgentType: String? {
        catalogStore
            .flatMap { findModelByID($0.snapshot(), modelID: modelName)?.info.agentType }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    @discardableResult
    func select(overlayID: String, rowID: String) async throws -> String? {
        if overlayID.hasPrefix("permission:") {
            // The sheet's row ids are `PagerPermissionDecision` raw values, so a
            // click resolves the request exactly as the keyboard would.
            guard let decision = PagerPermissionDecision(rawValue: rowID) else { return nil }
            await resolve(
                overlayID: overlayID,
                requestID: String(overlayID.dropFirst("permission:".count)),
                decision: decision
            )
            return nil
        }
        if overlayID == LiveDashboardOverlay.overlayID {
            if rowID.hasPrefix(LiveDashboardOverlay.closePrefix + ":") {
                await handleDashboardClose(rowID: rowID)
                return nil
            }
            // Enter on a focused section header toggles its collapse
            // (`render.rs:1490-1516` focusables); on the idle fold it flips
            // `idle_show_all`. Neither dismisses the roster.
            if let sectionKey = LiveDashboardOverlay.sectionKey(forListRowID: rowID) {
                dashboardState.toggleSection(sectionKey)
                rebuildDashboardRows()
                return nil
            }
            if rowID == LiveDashboardOverlay.idleOverflowRowID {
                dashboardState.idleShowAll.toggle()
                rebuildDashboardRows()
                return nil
            }
            let target: String
            if rowID.hasPrefix(LiveDashboardOverlay.attachPrefix) {
                target = String(rowID.dropFirst(LiveDashboardOverlay.attachPrefix.count))
            } else if rowID.hasPrefix(LiveDashboardOverlay.subagentPrefix) {
                target = String(rowID.dropFirst(LiveDashboardOverlay.subagentPrefix.count))
                guard dashboardPeekCache.items[target] != nil else {
                    note("Subagent attach is available after its transcript is persisted.")
                    rebuildDashboardRows()
                    return nil
                }
            } else if rowID == LiveDashboardOverlay.newAgentRowID {
                dashboardInputMode = .compose(rowID: rowID)
                dashboardInputText = ""
                rebuildDashboardRows()
                return nil
            } else {
                return nil
            }
            overlays.dismiss(id: LiveDashboardOverlay.overlayID)
            // Attaching to the ACTIVE session is just closing the roster;
            // any other row rides the same `/resume <id>` the sessions
            // picker dispatches, so attach can never bypass the resume
            // machinery's refusals.
            guard target != sessionID else { return nil }
            return "/resume \(target)"
        }
        if overlayID == "dashboard-location" {
            guard rowID.hasPrefix("location:") else { return nil }
            let path = String(rowID.dropFirst("location:".count))
            overlays.dismiss(id: overlayID)
            changeDashboardDispatchLocation(path)
            rebuildDashboardRows()
            return nil
        }
        if overlayID == "workflows" {
            // The dashboard stays open: a control key acts on a run and
            // refreshes the rows, it does not close the surface the user is
            // working in.
            _ = await handleWorkflowSelection(rowID: rowID)
            return nil
        }
        if overlayID == LiveExtensionsComposition.overlayID {
            // `r` reload: rebuild the active tab's rows from the live
            // loaders and swap them in. The modal stays open and keeps its
            // navigation state — reload is a data refresh, not a reset.
            reloadExtensionsOverlay(rowID: rowID)
            return nil
        }
        if overlayID == LiveAgentsComposition.overlayID {
            guard let existing = overlays.overlays.first(
                      where: { $0.id == LiveAgentsComposition.overlayID }
                  ),
                  case .agents(let current) = existing.content
            else { return nil }
            // `t`/`s` (B9-b2) and the persona create/delete (B9-b3): the
            // writers run here, then the refreshed snapshot — rebuilt
            // list after `t` (`rebuild_agents`, `agents_modal.rs:322-328`),
            // re-resolved default + inline message after `s` (`:2161-2179`),
            // refreshed personas + success message after a create/delete
            // (`:2372-2385`, `:2399-2410`) — replaces the open modal in
            // place; navigation state rides the snapshot. A failed write
            // refreshes nothing, so the modal keeps stating what disk
            // still holds, plus the error message.
            if let updated = LiveAgentsComposition.applyingMutation(
                rowID: rowID,
                to: current,
                workingDirectory: workingDirectory,
                openGrokHome: openGrokHome,
                modelAgentType: agentsModalModelAgentType,
                environment: environment
            ) {
                overlays.push(.agents(updated))
                return nil
            }
            // `Enter`/`o` on a persona (B9-b3): the structured detail
            // modal pushed ON TOP of the agents modal — upstream keeps
            // both alive (`agent_view/modals.rs:49-68`) and refreshes the
            // list when the detail closes (`:126-132`, the dismissal hook
            // in `handleInput`). A load failure paints upstream's copy on
            // the modal beneath (`:61-67`).
            if rowID.hasPrefix(LiveAgentsComposition.viewPersonaRowPrefix) {
                guard let index = Int(
                          rowID.dropFirst(LiveAgentsComposition.viewPersonaRowPrefix.count)
                      ),
                      current.personas.indices.contains(index)
                else { return nil }
                let entry = current.personas[index]
                if let detail = LiveAgentsComposition.personaDetail(
                    for: entry,
                    workingDirectory: workingDirectory,
                    openGrokHome: openGrokHome,
                    environment: environment
                ) {
                    overlays.push(.personaDetail(detail))
                } else {
                    var updated = current
                    updated.message = .error("Failed to load persona '\(entry.name)'")
                    overlays.push(.agents(updated))
                }
                return nil
            }
            // `Enter`/`o` view on an agent: resolve the payload from the
            // OPEN modal's snapshot and push the document overlay ON TOP —
            // the agents modal stays beneath, upstream's viewer-over-modal
            // layering (Esc closes the viewer and the modal is still
            // there, `agent_view/modals.rs:33-36`). A stale or unreadable
            // target opens nothing, upstream's own silent `open_markdown`
            // → None arm.
            guard let payload = LiveAgentsComposition.viewPayload(
                rowID: rowID, overlay: current
            ) else { return nil }
            overlays.push(LiveHowtoGuidesPicker.viewerOverlay(
                title: payload.title,
                content: payload.content
            ))
            return nil
        }
        if overlayID == LiveAgentsComposition.personaDetailOverlayID {
            guard let existing = overlays.overlays.first(
                      where: { $0.id == LiveAgentsComposition.personaDetailOverlayID }
                  ),
                  case .personaDetail(let detail) = existing.content
            else { return nil }
            if rowID == LiveAgentsComposition.personaDetailSaveRowID {
                // The committed value is already in the detail snapshot;
                // `save_to_file` runs here and the replacement overlay
                // carries `"Saved"` / `"Save failed: {e}"`
                // (`persona_detail.rs:855-864`). The list beneath is NOT
                // refreshed per save — upstream refreshes only on detail
                // close (`agent_view/modals.rs:126-132`).
                overlays.push(.personaDetail(
                    LiveAgentsComposition.savingPersonaDetail(detail)
                ))
                return nil
            }
            if rowID == LiveAgentsComposition.personaDetailEditInEditorRowID {
                // `i` (`persona_detail.rs:824-828`): upstream closes the
                // detail before queueing the suspend
                // (`agent_view/modals.rs:134-140`), edits over the shared
                // suspend seam, and refreshes the Personas tab on return
                // (`external_editor.rs:277-283` — refresh even when the
                // editor exits non-zero).
                overlays.dismiss(id: LiveAgentsComposition.personaDetailOverlayID)
                if let path = detail.sourcePath {
                    try await suspendForEditor(path: path)
                }
                refreshAgentsPersonasSnapshot()
                return nil
            }
            return nil
        }
        if overlayID == Self.welcomeOverlayID {
            // The welcome stays up: upstream's welcome view survives its own
            // menu actions — only the first turn replaces it. Index dispatch
            // is `dispatch_menu_action` (`app/app_view.rs:4584-4620` at pin
            // 650c1db7); rows this port omitted (import, worktree) have no
            // ids to arrive here.
            switch rowID {
            case Self.welcomeResumeRowID:
                // `Action::FetchSessionList` (`:4608-4610`) — the exact
                // picker `/resume` opens, honest refusal included when the
                // composition has no session catalog.
                try await present(.sessionPicker)
            case Self.welcomeChangelogRowID, PagerWelcomeOverlay.changelogCTARowID:
                // The menu row (`:4607-4614`) and the info-block CTA
                // (`:4380-4388`) dispatch the same
                // `Action::ShowReleaseNotes { "Release Notes", md.trim() }`
                // from ALREADY-AVAILABLE markdown — the prefetch's
                // in-memory copy first (upstream's only source), the disk
                // cache as this port's pre-prefetch fallback. Neither
                // fetches: a vanished cache is upstream's `Unchanged`
                // no-op, never a 3 s CDN wait from a click.
                guard let markdown = changelogMarkdown
                    ?? ChangelogManager.fromEnvironment(environment).cachedMarkdown()
                else { return nil }
                overlays.push(LiveHowtoGuidesPicker.viewerOverlay(
                    title: "Release Notes",
                    content: markdown.trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            case Self.welcomeQuitRowID:
                // `Action::Quit` (`:4619`). A mouse-dispatched quit is
                // immediate upstream too (`apply_quit_confirmation` with no
                // key event, `:3620-3621`); the round-trip is the same
                // controller-owned `/quit` the command palette takes.
                return "/quit"
            case PagerWelcomeOverlay.announcementRowID:
                // Click anywhere on the announcement block toggles inline
                // expansion (`app_view.rs:4389-4395`). The painter publishes
                // this row ONLY while `truncated || expanded` — upstream's
                // gate at the click site — so arriving here IS the gate.
                overlays.updateWelcome { welcome in
                    welcome.announcementExpanded.toggle()
                }
            case PagerWelcomeOverlay.announcementCTARowID:
                // `Action::AnnouncementsOpenCta(Welcome)` (`:4349-4355`) →
                // the router re-resolves the target through the slot gate
                // and opens it (`dispatch/router.rs:1006-1018`), so a
                // critical preempting the promo between paint and click
                // no-ops. The opener is the same seam `Action::OpenUrl`
                // takes (`openExternalURL`). Upstream's
                // `AnnouncementCtaClicked` telemetry is omitted with the
                // rest of this port's dark telemetry.
                if let url = await announcements?.promoCTATargetURL() {
                    openExternalURL(url)
                }
            default:
                break
            }
            return nil
        }
        overlays.dismiss(id: overlayID)
        switch overlayID {
        case "model":
            await switchModel(to: rowID)
        case LiveSessionPicker.overlayID:
            // Row ids are session ids ("none" is the empty-list placeholder).
            // The command round-trip is how the selection reaches the runtime:
            // only the controller owns it, so the row resolves to the exact
            // `/resume <id>` the controller's resume handler services.
            guard rowID != "none" else { return nil }
            guard rowID != sessionID else {
                note("Already in session \(String(rowID.prefix(8))).")
                return nil
            }
            return "/resume \(rowID)"
        case "theme":
            // The row id is the theme name, so a click takes the identical path
            // a typed `/theme <name>` does — including the downgrade notice on
            // a terminal that cannot render it.
            if let message = applyTheme(named: rowID) {
                appendMessage(PagerMessage(role: .system, text: message))
            }
        case "command-palette":
            // The row id is the command's insert text, so handing it back runs
            // exactly what the row named — upstream's
            // `SendSlashCommandPreservingDraft` (`app/modals.rs:932`). The
            // composer is untouched, which is the "preserving draft" half.
            return rowID
        case LiveLoginProviderPicker.overlayID:
            // The row id is the provider token, so a click dispatches the
            // exact typed form through the controller's alias table —
            // upstream shares `provider_action` between both paths
            // (`login.rs:82-84`).
            return "/login \(rowID)"
        case LiveHowtoGuidesPicker.overlayID:
            // Row ids are doc titles; selecting one opens that guide in the
            // content viewer — upstream's DocPicker → DocViewer hand-off
            // (`app/modals.rs:1327-1345`). Upstream's Esc-returns-to-list
            // shuttle is not ported (the overlay stack has no
            // previous-modal channel — recorded divergence; cost: Esc
            // closes the viewer outright and `/docs` reopens the list).
            guard let doc = PagerDocs.find(title: rowID) else { return nil }
            overlays.push(LiveHowtoGuidesPicker.viewerOverlay(
                title: doc.title,
                content: doc.content
            ))
        case LiveJumpPicker.overlayID:
            guard let index = Int(rowID) else { return nil }
            try? revealBlock(at: index)
        case LiveSessionDeleteConfirmation.overlayID:
            // Any row but the confirm row cancels, so a row id this renderer
            // does not recognise can only fail closed.
            guard rowID == LiveSessionDeleteConfirmation.confirmRowID else { return nil }
            await deleteSession(confirmed: true)
        case LiveRewindPicker.overlayID:
            guard let target = Int(rowID), let coordinator = sessionServices?.rewind else {
                return nil
            }
            // Deliberately a dry run: selecting a row in a list must not restore
            // files, which is not undoable. The preview says how to apply it.
            switch await LiveSessionCommands.apply(
                target: target,
                mode: .all,
                force: false,
                coordinator: coordinator,
                currentItems: await conversationHistory?.items ?? []
            ) {
            case .message(let text):
                note(text)
            case .overlay(let overlay):
                overlays.push(overlay)
            case .rewound(let index, _, let summary):
                await commitRewind(toPromptIndex: index, summary: summary)
            }
        default:
            break
        }
        return nil
    }

    /// Await the in-flight background catalog refresh, then reconcile the
    /// session's effort/tier against the published catalog
    /// (`ModelState::update_catalog`, acp/model_state.rs:155-192). Quiet:
    /// composer labels update on rebuild, but no "Switched to…" row — a
    /// catalog broadcast is not a user `/model` action.
    func reconcileModelStateAfterCatalogRefresh() async {
        guard let catalogStore, let modelSwitch else { return }
        await catalogStore.backgroundRefreshTask?.value
        let before = await modelSwitch.snapshot()
        guard let result = await applyLiveModelCatalogReconcile(
            catalogStore: catalogStore,
            modelSwitch: modelSwitch
        ), result.samplerNeedsRebuild else {
            return
        }
        let after = await modelSwitch.snapshot()
        modelName = after.modelID
        reasoningEffort = after.configuration.reasoningEffort?.asString
        // Only repaint when the wire-visible route actually moved; a no-op
        // rebuild is not expected here because samplerNeedsRebuild gated it.
        if before.modelID != after.modelID
            || before.configuration.reasoningEffort != after.configuration.reasoningEffort
            || before.configuration.serviceTier != after.configuration.serviceTier {
            try? renderState()
        }
    }

    // MARK: - Input routing

    func handleInput(_ event: InputEvent) async throws -> OpenGrokPagerInputRouting {
        switch event {
        case .key(let key):
            // Esc clears a persistent text highlight before the controller's
            // cancel ladder (`no_esc_consumer_pending`, input.rs:239-247).
            // First refusal lives here — no controller Esc fork required.
            if key.key == .escape, clearPersistentTextSelectionHighlight() {
                try renderState()
                return .consumed
            }
            if let welcomeRouting = try await handleWelcomeChord(key) {
                return welcomeRouting
            }
            // A focused pane owns the keys the composer would otherwise get
            // (`AgentPane::Tasks` routing, `agent_view/input.rs:1152`).
            if var pane = tasksPane, pane.focused, !overlays.isActive {
                let outcome = pane.handle(key)
                tasksPane = pane
                switch outcome {
                case .redraw, .consumed:
                    try renderState()
                    return .consumed
                case .close:
                    closeTasksPane()
                    try renderState()
                    return .consumed
                case .focusPrompt:
                    tasksPane?.focused = false
                    try renderState()
                    return .consumed
                case .action(let action):
                    return try await performTasksPaneAction(action)
                }
            }
            guard overlays.isActive else { return .notHandled }
            // Dashboard-scoped chords run BEFORE the generic overlay
            // routing — upstream registers the dashboard's bindings over
            // the globals while it has focus (`defaults.rs:997-1017`).
            if let dashboardRouting = try await handleDashboardChord(key) {
                return dashboardRouting
            }
            switch overlays.handle(key, viewportHeight: overlayViewportHeight) {
            case .ignored:
                return .notHandled
            case .redraw, .consumed:
                // Arrows and filter typing both land here; the peek has to
                // follow the cursor before the frame paints.
                refreshDashboardPeek()
                try renderState()
                return .consumed
            case .dismissed(let id):
                handleOverlayDismissal(id)
                try renderState()
                return .consumed
            case .selected(let id, let rowID):
                let command = try await select(overlayID: id, rowID: rowID)
                try renderState()
                return command.map { .runCommand($0) } ?? .consumed
            case .permission(let id, let requestID, let decision):
                await resolve(overlayID: id, requestID: requestID, decision: decision)
                try renderState()
                return .consumed
            case .question(let id, let requestID, let outcome):
                await resolveQuestion(overlayID: id, requestID: requestID, outcome: outcome)
                try renderState()
                return .consumed
            case .planApproval(let id, let requestID, let outcome):
                await resolvePlanApproval(overlayID: id, requestID: requestID, outcome: outcome)
                try renderState()
                return .consumed
            case .setting(_, let event):
                // The modal has already folded the change into its own state,
                // so the repaint is correct either way; this carries the change
                // out to the session and to config.toml.
                await applySetting(event)
                try renderState()
                return .consumed
            }
        case .mouse(let mouse):
            guard mouseReportingEnabled else { return .notHandled }
            return try await handleMouse(mouse)
        case .paste:
            // A modal swallows pasted text for the same reason it swallows
            // keys: nothing typed while it is up belongs to the composer.
            return overlays.isActive ? .consumed : .notHandled
        default:
            return .notHandled
        }
    }

    /// Clear persistent highlight (+ cancel flash). Returns whether anything
    /// was present (Esc first-refusal).
    @discardableResult

    func convertDeferredTextPress(col: Int, row: Int) -> Bool {
        guard deferredTextPress != nil,
              let model = lastTextSelection,
              let hit = model.hitTestSelectableRange(col: col, row: row)
        else { return false }
        deferredTextPress = nil
        pendingTextDrag = nil
        pendingScrollbackClick = nil
        armTextDrag(
            anchor: hit,
            head: hit,
            anchorContentWidth: model.visibleBlockContentWidth(entryIndex: hit.entryIndex),
            col: col,
            row: row
        )
        return true
    }

    func selectWordAt(
        _ hit: PagerTextRangeHit,
        model: PagerTextSelectionModel,
        nowMs: UInt64,
        clickCount: UInt8
    ) throws {
        guard let semantic = pagerSemanticSelectionAt(model: model, hit: hit) else {
            lastTextClick = nil
            return
        }
        let endCol = max(semantic.cols.lowerBound, semantic.cols.upperBound - 1)
        let persistent = PagerPersistentTextSelection(
            entryIndex: hit.entryIndex,
            rangeID: hit.rangeID,
            anchor: PagerTextSelectionEndpoint(
                blockLineIndex: hit.blockLineIndex,
                colWithinRange: semantic.cols.lowerBound
            ),
            head: PagerTextSelectionEndpoint(
                blockLineIndex: hit.blockLineIndex,
                colWithinRange: endCol
            ),
            origin: .doubleClick,
            kind: .linear
        )
        if !semantic.text.isEmpty {
            copyTextSelectionToClipboard(semantic.text)
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
    }

    /// Triple-click on a table: cell interior copies the cell (wrapped
    /// fragments space-joined); border/divider copies the whole grid as TSV.
    /// `false` when detect fails (malformed / no grid) — caller falls back
    /// to line selection.
    func selectCellAt(
        _ hit: PagerTextRangeHit,
        model: PagerTextSelectionModel,
        nowMs: UInt64,
        clickCount: UInt8
    ) throws -> Bool {
        guard let sidecar = computeDragTableGeometry(anchor: hit, model: model) else {
            return false
        }
        let geom = sidecar.geometry
        if let cell = geom.cellAt(line: hit.blockLineIndex, col: hit.colWithinRange) {
            guard let range = model.range(entryIndex: hit.entryIndex, rangeID: hit.rangeID)
            else { return false }
            var texts: [Int: String] = [:]
            texts.reserveCapacity(range.lines.count)
            for line in range.lines {
                texts[line.blockLineIndex] = line.text
            }
            let clipboard = geom.cellText(cell, textAt: { texts[$0] })
            let lines = geom.rowLines(cell.row)
            let band = geom.band(cell.col)
            tableSelectionGeometry = sidecar
            let persistent = PagerPersistentTextSelection(
                entryIndex: hit.entryIndex,
                rangeID: hit.rangeID,
                anchor: PagerTextSelectionEndpoint(
                    blockLineIndex: lines.lowerBound,
                    colWithinRange: band.lowerBound
                ),
                head: PagerTextSelectionEndpoint(
                    blockLineIndex: max(lines.lowerBound, lines.upperBound - 1),
                    colWithinRange: max(band.lowerBound, band.upperBound - 1)
                ),
                origin: .tripleClick,
                kind: .tableCell
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
        return try selectWholeTableAt(
            hit,
            sidecar: sidecar,
            model: model,
            nowMs: nowMs,
            clickCount: clickCount
        )
    }

    func selectLineAt(
        _ hit: PagerTextRangeHit,
        model: PagerTextSelectionModel,
        nowMs: UInt64,
        clickCount: UInt8
    ) throws {
        guard let line = model.line(for: hit),
              let bounds = pagerLineBounds(for: line),
              !bounds.isEmpty
        else {
            lastTextClick = nil
            return
        }
        let endCol = max(bounds.lowerBound, bounds.upperBound - 1)
        let text = pagerSliceDisplayCols(
            line.text,
            start: bounds.lowerBound,
            end: bounds.upperBound
        )
        let persistent = PagerPersistentTextSelection(
            entryIndex: hit.entryIndex,
            rangeID: hit.rangeID,
            anchor: PagerTextSelectionEndpoint(
                blockLineIndex: hit.blockLineIndex,
                colWithinRange: bounds.lowerBound
            ),
            head: PagerTextSelectionEndpoint(
                blockLineIndex: hit.blockLineIndex,
                colWithinRange: endCol
            ),
            origin: .tripleClick,
            kind: .linear
        )
        if !text.isEmpty {
            copyTextSelectionToClipboard(text)
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
    }

    /// Left / X10-none up half of transcript link open
    /// (`mouse.rs:823-828` at pin 650c1db7). Returns `true` when a pending
    /// link click existed and was resolved (opened or no-op), so the block
    /// select path does not also run. Same-cell + still-matching URL opens
    /// via `openExternalURL`; different cell, occluded, or vanished link
    /// clears pending without opening.
    func completePendingLinkClick(_ event: MouseEvent) -> Bool {
        guard let pending = pendingLinkClick else { return false }
        switch event.resolvedButton {
        case .left, .none:
            break
        case .middle, .right, .other:
            pendingLinkClick = nil
            return true
        }
        pendingLinkClick = nil
        guard !overlays.isActive else { return true }
        // Exact same cell — unlike block select, jitter does not open.
        guard event.x == pending.x, event.y == pending.y else { return true }
        // Re-hit last-painted links so a repaint that moved/removed the span
        // cannot open a stale URL frozen at down.
        guard let link = paintedLink(atX: pending.x, y: pending.y),
              link.url == pending.url
        else { return true }
        openExternalURL(pending.url)
        return true
    }

    /// Hit-test against last-painted `LinkSpan`s (absolute viewport cells).
    /// `colEnd` is exclusive, matching `paintSpans` emission.
    func paintedLink(atX x: Int, y: Int) -> LinkSpan? {
        lastPaintedLinks.first { span in
            span.row == y && x >= span.colStart && x < span.colEnd
        }
    }

    /// Platform link-action modifier for app-owned open when OSC 8 is off
    /// (`is_link_modifier_held`, `agent_view/mod.rs:469-477` at pin 650c1db7).
    /// Control matches the non-macOS wire path; meta/superKey stand in for
    /// macOS Cmd when present on the event. Shift/alt never count.
    nonisolated static func isLinkModifierHeld(_ modifiers: KeyModifiers) -> Bool {
        modifiers.contains(.control)
            || modifiers.contains(.meta)
            || modifiers.contains(.superKey)
    }

    /// Left-button up half of click-to-select: pending down cell + frozen
    /// hit model, no drag committed → select + `.focusScrollback`. Up may
    /// jitter off the down cell; remapping always uses the down snapshot
    /// (`mouse.rs:830-947` — selection reads `click_row`, not the up row).
    ///
    /// X10 releases decode as `.up` with `resolvedButton == .none` (wire
    /// code 3, no button attribution). Complete against the frozen left-down
    /// pending snapshot for `.left` or `.none`; middle/right still clear
    /// pending and refuse.
    func completeScrollbackClick(
        _ event: MouseEvent,
        hadPendingTextDrag: Bool = false
    ) async throws -> OpenGrokPagerInputRouting {
        switch event.resolvedButton {
        case .left, .none:
            break
        case .middle, .right, .other:
            pendingScrollbackClick = nil
            lastTextClick = nil
            return .consumed
        }
        guard let pending = pendingScrollbackClick else { return .consumed }
        pendingScrollbackClick = nil
        // Real drag already cleared pending; a jittered up without a drag
        // event still completes against the down cell (up coordinates are
        // intentionally ignored for the hit remap).
        guard !overlays.isActive else { return .consumed }

        // word_select multi-click: exact text hit on the down cell within
        // 300ms (`mouse.rs:832-873`). flash/hold keep the block-select path
        // (no invented fold on double-click).
        if keepTextSelectionMode.selectsWord,
           let textModel = lastTextSelection,
           let exact = textModel.hitTestTextExact(col: pending.x, row: pending.y)
        {
            let nowMs = textSelectionNowMs()
            let clickCount = pagerCountTextClick(previous: lastTextClick, hit: exact, nowMs: nowMs)
            switch clickCount {
            case 1:
                clearPersistentTextSelectionHighlight()
                lastTextClick = pagerMakeTextClickIdentity(
                    hit: exact, nowMs: nowMs, clickCount: 1
                )
                guard conversation.items.indices.contains(exact.entryIndex),
                      conversation.items[exact.entryIndex].isMouseSelectable
                else { return .consumed }
                selection.select(at: exact.entryIndex, itemCount: conversation.items.count)
                followsBottom = false
                try renderState()
                return .focusScrollback
            case 2:
                try selectWordAt(exact, model: textModel, nowMs: nowMs, clickCount: 2)
                return .focusScrollback
            case 3:
                if try selectCellAt(exact, model: textModel, nowMs: nowMs, clickCount: 3) {
                    return .focusScrollback
                }
                try selectLineAt(exact, model: textModel, nowMs: nowMs, clickCount: 3)
                return .focusScrollback
            default:
                lastTextClick = nil
            }
        } else {
            lastTextClick = nil
            _ = hadPendingTextDrag
        }

        guard let index = pending.hit.blockIndex(atScreenY: pending.y),
              conversation.items.indices.contains(index),
              conversation.items[index].isMouseSelectable
        else { return .consumed }
        selection.select(at: index, itemCount: conversation.items.count)
        // Following the tail while a selection cursor exists would yank the
        // viewport away from the block the user just picked.
        followsBottom = false
        try renderState()
        return .focusScrollback
    }

    /// Per-overlay dismissal side effects. Closing the persona detail
    /// refreshes the personas list beneath in case edits were made —
    /// upstream's `PersonaDetailOutcome::Close` arm
    /// (`agent_view/modals.rs:126-132`, mouse close `:165-170`).
    func handleOverlayDismissal(_ id: String) {
        if id == LiveAgentsComposition.personaDetailOverlayID {
            refreshAgentsPersonasSnapshot()
        }
        if id == LiveDashboardOverlay.overlayID {
            // The snapshots are only valid while the roster is up, and
            // search text must never leak into the next open.
            dashboardPeekCache = LiveDashboardPeekCache()
            dashboardDormant = []
            dashboardSearchQuery = nil
        }
    }

    /// Rebuild the OPEN agents modal's personas tab from the live loader
    /// — `refresh_personas` (`agents_modal.rs:330-336`), also serving
    /// `refresh_after_editor`'s Personas arm (`:337-343`). No open modal,
    /// nothing to refresh.
    func refreshAgentsPersonasSnapshot() {
        guard let existing = overlays.overlays.first(
                  where: { $0.id == LiveAgentsComposition.overlayID }
              ),
              case .agents(let current) = existing.content
        else { return }
        overlays.push(.agents(LiveAgentsComposition.refreshingPersonas(
            current,
            workingDirectory: workingDirectory,
            openGrokHome: openGrokHome,
            environment: environment
        )))
    }

    /// Session-side effects of a settings change.
    ///
    /// The modal owns its own state and has already applied the change to
    /// itself, so this carries only the effects that reach past the overlay:
    /// the full input-mode snapshot shared with the controller, and then the
    /// write to disk and the live theme swap.
    func applySetting(_ event: PagerSettingsEvent) async {
        if case .commit(let key, .string(let choice)) = event,
           key == "permission_mode" {
            // Session-local row: apply the live classifier/yolo seam and skip
            // the config store (`.sessionLocal` → notPersistable).
            let mode: LiveSessionPermissionMode.DisplayMode?
            switch choice {
            case "auto": mode = .auto
            case "always-approve": mode = .alwaysApprove
            case "ask", "default": mode = .ask
            default: mode = nil
            }
            if let mode, let permissionMode {
                if let notice = await permissionMode.applyPermissionMode(mode) {
                    appendMessage(PagerMessage(role: .error, text: notice))
                }
            }
            return
        }
        if case .commit(let key, .string(let choice)) = event,
           key == Self.codingDataSharingKey {
            // The consent row persists to the xAI service through the
            // retention client, never to config.toml (`.authMetadata`
            // storage) — falling through to the shared store write would
            // hit its notPersistable arm and silently do nothing, the
            // exact "row that cannot change anything" the B9 research
            // found. Choice mapping is upstream's modal commit
            // (settings_modal/state.rs:1148-1151); an unknown choice maps
            // to no action there and is dropped the same way here. The
            // write is SPAWNED like upstream's Effect (status.rs:179-183
            // → effects/mod.rs:5366) so a slow proxy never blocks the
            // input loop; the guards and the optimistic flip inside run
            // before the first await, so the row repaints instantly.
            let optedIn: Bool
            switch choice {
            case "opt-in": optedIn = true
            case "opt-out": optedIn = false
            default: return
            }
            pendingCodingDataWrite = Task {
                await self.setCodingDataSharing(optedIn: optedIn)
            }
            return
        }
        if case .commit(let key, .integer(let number)) = event {
            if key == "scroll_speed" {
                scrollSettings.speed = min(100, max(1, number))
                rebuildScrollConfig()
                await applySettingsEvent(event)
                return
            }
            if key == "scroll_lines" {
                // Committing any value — even the display default 3 — switches
                // permanently to an explicit override of BOTH wheel and
                // trackpad lines (`ScrollConfigOverrides.from_settings_caches`).
                scrollSettings.lines = min(10, max(1, number))
                rebuildScrollConfig()
                await applySettingsEvent(event)
                return
            }
        }
        if case .commit(let key, .string(let choice)) = event, key == "scroll_mode" {
            scrollSettings.mode = Self.parseScrollMode(choice)
            rebuildScrollConfig()
            await applySettingsEvent(event)
            return
        }
        if case .commit(let key, .string(let choice)) = event, key == "keep_text_selection" {
            // Atomic persist first (`settings_writes.rs` set_keep_text_selection):
            // write canonical + clear legacy keys; live-apply only after success.
            let mode = PagerKeepTextSelectionMode.fromCanonical(choice) ?? .flash
            let store = PagerSettingsStore(
                configPath: openGrokHome.appendingPathComponent("config.toml")
            )
            do {
                try store.writeKeepTextSelection(mode.canonical)
                keepTextSelectionMode = mode
                reconcilePersistentSelectionForModeChange(now: textSelectionNowMs())
                reloadCatalogInput()
                syncOpenSettingsKeepTextSelectionFromSnapshot()
            } catch {
                appendMessage(PagerMessage(
                    role: .error,
                    text: "Could not save keep_text_selection: \(error)"
                ))
            }
            return
        }
        if case .commit(let key, .bool(let flag)) = event {
            if key == "invert_scroll" {
                scrollSettings.invert = flag
                rebuildScrollConfig()
                await applySettingsEvent(event)
                return
            }
            if key == "compact_mode" {
                // The live half of the modal toggle — upstream routes it
                // through the same `set_compact_mode` the slash command uses
                // (`ui.rs:1207`: `("compact_mode", Bool) →
                // Action::SetCompactMode`), so the very next paint re-derives
                // the render value. The persist half is the shared store
                // write below.
                userCompactMode = flag
                await applySettingsEvent(event)
                return
            }
            if key == "show_timestamps" {
                // Same routing for timestamps — upstream's modal commit maps
                // `("show_timestamps", Bool) → Action::SetTimestamps`
                // (`ui.rs:1208`) into the same `set_timestamps` the slash
                // command reaches, so the very next paint reads the new
                // value. The persist half is the shared store write below.
                userShowTimestamps = flag
                await applySettingsEvent(event)
                return
            }
            if key == "show_timeline" {
                // Same routing for the timeline rail — upstream's modal
                // commit maps `("show_timeline", Bool) → Action::SetTimeline`
                // (`ui.rs:1209`) into the same `set_timeline` the slash
                // command reaches (`ui.rs:1506`: `set_timeline_inner`), so
                // the very next paint reads the new value. The persist half
                // is the shared store write below.
                userShowTimeline = flag
                await applySettingsEvent(event)
                return
            }
            if key == "page_flip_on_send" {
                // Same routing for page-flip — upstream's modal commit maps
                // `("page_flip_on_send", Bool) → Action::SetPageFlipOnSend`
                // (`ui.rs:1210`) into `set_page_flip_on_send_inner`
                // (`setters.rs:1594-1596`), so the very next send reads the
                // new value. The persist half is the shared store write below.
                userPageFlipOnSend = flag
                await applySettingsEvent(event)
                return
            }
            if key == "swarm_mode" {
                // The settings row applies live, exactly like `/swarm on|off`
                // — the row's own promise ("Active sessions update
                // immediately", settings/defs.rs:776-784); upstream routes
                // the modal toggle through `Action::SetSwarmMode`
                // (views/settings_modal/state.rs). The persist half is the
                // shared store write below.
                if let toolExecutor {
                    if flag {
                        await toolExecutor.swarmMode.enter(.manual)
                    } else {
                        await toolExecutor.swarmMode.exit()
                    }
                }
                await applySettingsEvent(event)
                return
            }
            if key == "plan_mode" {
                // Same live-then-persist shape as `swarm_mode`: the settings
                // row arms/disarms the session plan gate immediately
                // (upstream `Action::SetPlanMode`), then the shared store
                // write persists `ui.plan_mode`. No toast here — the modal
                // commit path for swarm likewise stays silent; `/plan` owns
                // the slash toast. There is no `/plan off` slash path in
                // this port (only `.planModeOn` / `.enterPlanMode`).
                if let toolExecutor {
                    if flag {
                        if await !toolExecutor.planModeActive() {
                            guard await toolExecutor.armPlanMode() else {
                                // No pipeline — preference still persists so
                                // the next full session can honor it.
                                await applySettingsEvent(event)
                                return
                            }
                        }
                    } else if await toolExecutor.planModeActive() {
                        guard await toolExecutor.disarmPlanMode() else {
                            await applySettingsEvent(event)
                            return
                        }
                    }
                }
                await applySettingsEvent(event)
                return
            }
            switch key {
            case "multiline_mode": inputModes.isMultiline = flag
            case "vim_mode": inputModes.isVimMode = flag
            case "enter_steers": inputModes.enterSteers = flag
            case "combine_queued_prompts": inputModes.combineQueuedPrompts = flag
            default:
                await applySettingsEvent(event)
                return
            }
            if let inputModesSink {
                await inputModesSink(inputModes)
            }
        }
        await applySettingsEvent(event)
    }

    /// Footer hints label the key they stand for, so a click on one replays it.
    /// Range and arrow hints (`1-9`, `↑/↓`) name no single key and do nothing.
    static func keyEvent(forHint key: String) -> KeyEvent? {
        switch key.lowercased() {
        case "esc": return KeyEvent(key: .escape)
        case "enter": return KeyEvent(key: .enter)
        default: return nil
        }
    }

    // MARK: - Theme and settings

    /// Switch the live palette. Returns the message to echo, or `nil` when the
    /// name did not resolve.
    ///
    /// The resolution runs through the same clamp-then-quantize path startup
    /// uses, so `/theme oscura` on a 16-color terminal lands on GrokNight and
    /// says so rather than painting an unreadable frame.
    func applyTheme(named name: String) -> String? {
        guard let preference = PagerThemePreference.named(name) else { return nil }
        let resolution = pagerResolveTheme(
            preference: preference,
            colorLevel: colorLevel,
            appearance: preference == .auto ? PagerSystemAppearance.detect() : nil,
            darkTheme: autoDarkThemeKind,
            lightTheme: autoLightThemeKind,
            terminalNativeLock: mode != .fullScreen
        )
        themePreference = preference
        renderTheme = resolution.theme
        try? renderState()

        // Minimal mode locks the terminal's own palette, so the preference is
        // stored but nothing on screen changes. Saying "Theme: Tokyo Night"
        // while painting terminal-default would just look broken.
        if resolution.kind == .terminalDefault, preference != .fixed(.terminalDefault) {
            return "Saved \(preference.displayName). Minimal mode uses your "
                + "terminal's own colors; run fullscreen to see it."
        }
        if case .fixed(let requested) = preference, requested != resolution.kind {
            return "Theme \(requested.displayName) needs a truecolor terminal; "
                + "using \(resolution.kind.displayName)."
        }
        return "Theme: \(preference.displayName)"
    }

    /// Every theme `/theme` can offer on this terminal.
    var availableThemeNames: [String] {
        (["auto"] + PagerThemeKind.available(colorLevel: colorLevel).map(\.rawValue))
    }

    /// Build the settings modal from what is on disk right now.
    ///
    /// Read at open time rather than cached at startup: another process may
    /// have edited `config.toml` since, and a modal showing stale values would
    /// write them back on the next unrelated toggle.
    func settingsOverlay(deepLinkKey: String? = nil) -> PagerSettingsOverlay {
        let store = PagerSettingsStore(
            configPath: openGrokHome.appendingPathComponent("config.toml")
        )
        let activeCatalog = catalogStore?.pickerEntries() ?? modelCatalog
        var values = (try? store.load()) ?? [:]
        var locks: [String: PagerSettingLock] = [:]
        // The consent row's value lives in auth metadata, not config.toml
        // (`.authMetadata` storage), so `store.load()` never carries it —
        // upstream feeds the modal snapshot from the app mirror instead
        // (`coding_data_sharing_opt_out: app.coding_data_retention_opt_out`,
        // dispatch/settings/ui.rs:1097), which this renderer keeps in the
        // privacy-banner gate state hydrated at `begin()`. Locks mirror
        // `coding_data_sharing_lock()` (app_view.rs:1693-1703): a ZDR team
        // or non-admin member sees the row locked with the reason, and the
        // modal refuses to open its chooser. Before `begin()` (headless
        // constructions) the mirror is nil and the row falls back to its
        // registered default, exactly as it did before this seam existed.
        if let privacy = privacyBanner {
            values[Self.codingDataSharingKey] = .string(
                privacy.codingDataRetentionOptOut ? "opt-out" : "opt-in"
            )
            if let lock = privacy.codingDataSharingLock {
                locks[Self.codingDataSharingKey] = lock
            }
        }
        // Seed the four live scroll rows from the actor-local snapshot when
        // the user config.toml leaf is absent — effective `[ui]` (project
        // layers) hydrates cold-start pricing, and the open modal must show
        // the same fields. Store values win when present.
        if values["scroll_speed"] == nil, let speed = scrollSettings.speed {
            values["scroll_speed"] = .integer(speed)
        }
        if values["scroll_mode"] == nil, scrollSettings.mode != .auto {
            values["scroll_mode"] = .string(scrollSettings.mode.label)
        }
        if values["scroll_lines"] == nil, let lines = scrollSettings.lines {
            values["scroll_lines"] = .integer(lines)
        }
        if values["invert_scroll"] == nil, scrollSettings.invert {
            values["invert_scroll"] = .bool(true)
        }
        // Seed keep_text_selection from the actor-local snapshot (effective
        // `[ui]` / legacy precedence) when the user leaf is absent.
        if values["keep_text_selection"] == nil {
            values["keep_text_selection"] = .string(keepTextSelectionMode.canonical)
        }
        var overlay = PagerSettingsOverlay(
            values: values,
            dynamicChoices: [
                .activeModelCatalog: LiveModelPicker.sorted(activeCatalog).map { entry in
                    PagerSettingChoice(
                        canonical: entry.id,
                        display: LiveModelPicker.providerLabel(forProviderID: entry.providerID)
                            .map { "\($0) · \(entry.name)" } ?? entry.name,
                        summary: LiveModelPicker.description(for: entry)
                    )
                }
            ],
            multiSelectEnabled: [
                "opencode_go_models": (try? store.loadMultiSelect(key: "opencode_go_models")) ?? []
            ],
            locks: locks,
            hiddenKeys: LiveVoiceCapabilities.hiddenSettingsKeys(when: voiceState.capabilities)
                .union(LiveAntigravityCapabilities.hiddenSettingsKeys(
                    when: LiveAntigravityComposition.resolveCapabilities(environment: environment)
                )),
            // Auto-mode is live via HeuristicPermissionClassifier on every
            // PermissionHandle; dream and LSP rows are unhidden now that their
            // live seams exist. Voice rows stay capability-gated above.
            gatedChoices: [:],
            // Minimal mode hides the rows the reference marks `hidden_in_minimal`,
            // because none of them have a surface there to affect.
            minimalMode: mode != .fullScreen
        )
        if let deepLinkKey {
            let rows = overlay.visibleRows
            if let index = rows.firstIndex(where: { $0.settingKey == deepLinkKey }) {
                overlay.selectedIndex = index
                overlay.expandedKeys.insert(deepLinkKey)
            }
        }
        return overlay
    }

    /// The frame model for a given block list.
    ///
    /// Parameterised on the conversation so `revealBlock` can lay out a prefix
    /// through the identical chrome and measure where a block starts. Every
    /// other field is this frame's real state, which is what makes the
    /// measurement match the frame the user is looking at.
    func renderState(conversation blocks: [PagerConversationItem]) -> PagerRenderState {
        let isTurnRunning = turnActivity != nil
        let completions = prompt.completions.isEmpty
            ? nil
            : PagerCompletionMenu(
                rows: prompt.completions.map {
                    PagerCompletionRow(
                        label: $0.name,
                        summary: $0.summary,
                        isAvailable: $0.isAvailable
                    )
                },
                selectedIndex: prompt.selectedCompletion
            )
        // Elapsed rides the extrapolated motion clock so the readout and the
        // spinner agree without baking an idle gap into the first paint after
        // resume; the wall-clock fallback only serves motion-disabled
        // terminals, where no animation frame ever advances the motion clock.
        let paintClock = paintMotion
        let elapsed: TimeInterval? = motionEnabled
            ? turnStartedAtSeconds.map { max(0, paintClock.seconds - $0) }
            : turnStartedAt.map { Date().timeIntervalSince($0) }
        let streamedTokens = Int(estimateTokens(bytes: turnOutputUTF8Count))
        let now = clockNow()
        expireTransientToast(at: now)
        // Nonmutating snapshot — coalesced layouts and PageUp's
        // `currentPageScrollRows` must not consume the 250ms refresh.
        // Minimal never snapshots (`draw_inner` early return).
        let fpsOverlay = minimalHost == nil ? fpsHud.currentOverlay(topOffset: 0) : nil
        lastLaidOutFpsHud = fpsOverlay
        lastLaidOutToast = pagerActiveToastMessage(
            transient: transientToast,
            sticky: displayedStickyToast()
        )
        return PagerRenderState(
            size: terminalSize,
            statusBar: PagerStatusBar(
                workingDirectory: LivePagerChrome.collapseHome(workingDirectory),
                contextUsedTokens: contextUsage.map { Int($0.usedTokens) },
                contextTotalTokens: contextUsage.map { Int($0.contextWindow) },
                queuedPromptCount: queuedPromptCount,
                backgroundTaskCount: activeBackgroundWork.count,
                contextBarHovered: contextBarHovered
            ),
            announcementBanner: announcementBanner,
            conversation: blocks,
            turnStatus: turnActivity.map { label in
                PagerTurnStatus(
                    label: isCancelling ? "Cancelling\u{2026}" : label,
                    isCancelling: isCancelling,
                    tick: paintClock.tick,
                    elapsed: elapsed,
                    tokenCount: streamedTokens > 0 ? streamedTokens : nil,
                    queuedPromptCount: queuedPromptCount,
                    // Bare Enter force-sends the head only when the composer is
                    // empty; with a draft, Enter queues it behind the others.
                    queueIsSendable: queuedPromptCount > 0 && prompt.text.isEmpty,
                    // The pulsing "waiting on you" diamond while a permission
                    // sheet blocks the turn (`turn_status.rs:484-486`). The
                    // idle-monitor pulse is deliberately not produced: this
                    // session has no idle-watcher feed, and a guessed monitor
                    // glyph would claim watchers that do not exist.
                    indicator: currentPermissionRequestID != nil
                        ? .pendingUserDiamond
                        : .spinner
                )
            },
            completions: completions,
            input: PagerComposerState(
                text: prompt.text,
                cursorCharacterOffset: prompt.cursorOffset,
                cursorUTF8: prompt.cursorUTF8,
                selectionUTF8: prompt.selectionUTF8,
                selectedText: prompt.selectedText,
                textAreaState: prompt.textAreaState,
                scrollOverride: prompt.scrollOverride,
                // The composer is unfocused exactly while the scrollback holds
                // a selection — the two halves of one focus model.
                isFocused: !selection.isFocused,
                cursorVisible: !selection.isFocused,
                modelName: modelName,
                reasoningEffort: reasoningEffort,
                flags: permissionModeFlags,
                isMultiline: inputModes.isMultiline,
                maximumHeight: max(3, terminalSize.height / 2)
            ),
            shortcuts: PagerShortcutsBar(
                // The bar follows the focus, the way upstream's does: it lists
                // the bindings of the region that will actually receive the
                // next key.
                hints: selection.isFocused
                    ? LivePagerChrome.scrollbackHints(isVimMode: inputModes.isVimMode)
                    : LivePagerChrome.shortcutHints(isTurnRunning: isTurnRunning),
                pendingKey: prompt.pendingConfirmationKey,
                pendingLabel: prompt.pendingConfirmationLabel
            ),
            tasksPane: tasksPane,
            scrollPosition: followsBottom ? .followTail : .offset(scrollOffset),
            theme: renderTheme,
            selectedBlockIndex: selection.index,
            overlays: overlays,
            motion: paintClock,
            waveRows: waveRows,
            // Derived per frame from the user value and the live terminal
            // height — the port of `AppView::apply_effective_compact`
            // (`app_view.rs:2676-2690`), collapsed to a pure read because this
            // renderer rebuilds the whole frame state on every paint anyway.
            compactMode: pagerEffectiveCompact(
                userCompact: userCompactMode,
                terminalRows: terminalSize.height
            ),
            stickyHeadersEnabled: stickyHeadersEnabled,
            // NOT derived — upstream's appearance value IS the user setting
            // (`set_timestamps_inner`, `setters.rs:1530-1541` copies it
            // straight across; contrast the compact derivation above).
            showTimestamps: userShowTimestamps,
            // The user value gated on fullscreen, NOT a derivation of the
            // value itself: upstream's rail render path exists only in the
            // fullscreen agent view (`agent_view/render.rs:1157`; the
            // minimal renderer has no scrollback pane), while this port's
            // inline mode rides the same frame builder — without the gate a
            // `show_timeline = true` config would paint a rail into the
            // ≤12-row inline strip that upstream never grows.
            showTimeline: mode == .fullScreen && userShowTimeline,
            // Gate state and slot availability resolved HERE, per frame —
            // the E19-E21 pass-through shape: the renderer receives the
            // decided flag and never re-derives the gate
            // (app_view.rs:4859-4863; see `privacyBannerVisible`).
            privacyBanner: privacyBannerVisible,
            // Active drag wins over a persistent highlight for paint
            // (`textSelectionHighlight` → `pagerPaintTextSelectionHighlight`).
            textSelectionHighlight: currentTextSelectionHighlight(),
            tableSelectionGeometry: tableSelectionGeometry,
            fpsHud: fpsOverlay,
            toast: transientToast,
            stickyToast: displayedStickyToast()
        )
    }

    func currentTextSelectionHighlight() -> PagerTextSelectionHighlight? {
        // Table kinds ride the highlight plus `PagerRenderState.tableSelectionGeometry`.
        // Paint uses that keyed sidecar (live structural match at the paint
        // site); a stream/reflow mismatch paints nothing rather than another
        // grid or a linear sweep.
        if let active = activeTextDrag {
            // Paint against the live model: map frozen-identity endpoints when
            // a mid-drag reflow shifted blockLineIndex. Kind stays the frozen
            // sidecar resolution (hysteresis).
            if let frozen = frozenDragTextSelection, let live = lastTextSelection,
               let liveAnchor = pagerMapTextHit(active.anchor, from: frozen, to: live),
               let liveHead = pagerMapTextHit(active.head, from: frozen, to: live)
            {
                return .active(PagerActiveTextDrag(
                    anchor: liveAnchor,
                    head: liveHead,
                    kind: active.kind,
                    anchorContentWidth: active.anchorContentWidth
                ))
            }
            return .active(active)
        }
        if let persistent = persistentTextSelection {
            return .persistent(persistent)
        }
        return nil
    }

    var transcript: String { conversation.transcript }

}
