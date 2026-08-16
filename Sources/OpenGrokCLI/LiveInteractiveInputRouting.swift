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

    /// The welcome screen's app-level chords — the port of upstream's
    /// welcome-scoped key arms (`handle_welcome_input`,
    /// `app/app_view.rs:4110-4134` at pin 650c1db7), which live OUTSIDE the
    /// overlay-focus system exactly as these do: the welcome never captures
    /// input, so plain typing and Enter keep falling through to the live
    /// composer (upstream: text promotes to a session and forwards,
    /// `:4173-4177`; a plain Enter always starts the session, `:4104-4109`).
    ///
    /// Only the chords whose rows landed are bound: `ctrl+s` resume
    /// (`:4119-4121`) and `ctrl+q` quit. Upstream's `ctrl+w` worktree
    /// (`:4116-4118`) and `ctrl+i` import (`:4128-4130`) go with their
    /// omitted rows. `ctrl+q` reaches upstream's Quit through the global
    /// action registry with a press-again confirmation
    /// (`defaults.rs:764-785`, `app_view.rs:3598-3603`); this port's welcome
    /// binding quits on ONE press — recorded divergence. Cost: an accidental
    /// ctrl+q on the welcome exits immediately — of an empty, pre-first-turn
    /// session, which is also what upstream's mouse quit does.
    ///
    /// A capturing overlay above the welcome owns the keys first
    /// (`!overlays.isActive`), upstream's modal-blocks-welcome ordering.
    func handleWelcomeChord(_ key: KeyEvent) async throws -> OpenGrokPagerInputRouting? {
        guard !overlays.isActive,
              overlays.contains(id: Self.welcomeOverlayID),
              key.modifiers.contains(.control),
              case .char(let character) = key.key
        else { return nil }
        switch character.lowercased() {
        case "s":
            try await present(.sessionPicker)
            try renderState()
            return .consumed
        case "q":
            return .runCommand("/quit")
        default:
            return nil
        }
    }

    /// Row budget for the focused overlay's page keys, read off the last painted
    /// frame. Falls back to the transcript height when that overlay published no
    /// bounds, which is what a viewport too small to hold a modal looks like.
    var overlayViewportHeight: Int {
        guard let focused = overlays.focused?.id,
              let bounds = lastOverlayBounds.last(where: { $0.id == focused })
        else { return max(1, lastConversationHeight) }
        return max(1, bounds.content.height)
    }

    /// Last-painted toast slot. Hits here must not fall through to
    /// transcript or composer routing.
    func toastOccluderContains(_ event: MouseEvent) -> Bool {
        if lastConversationHit?.containsToastOccluder(x: event.x, y: event.y) == true {
            return true
        }
        return lastToastOccluder?.contains(x: event.x, y: event.y) == true
    }

    /// Mouse routing against last-painted geometry. Capturing overlay /
    /// banner first; scrollbar gutter before timeline rail / link / block
    /// (`mouse.rs:408-426` at pin 650c1db7); composer pane after those
    /// (disjoint) and before generic overlay-row handling. Collapsed-
    /// unfocused / prefix / chrome → `.focusComposer`. Focused content
    /// down arms a prompt-owned gesture and returns `.composerMouse` with
    /// the last-painted content rect; drag/up keep forwarding even outside
    /// the pane. A left down+up on an unoccluded `LinkSpan` opens via
    /// `openExternalURL` (same-cell up); a left down+up on a conversation
    /// content cell (no drag, not a link) selects that block and returns
    /// `.focusScrollback` so controller Tab focus matches. Returns a slash
    /// command routing when an overlay row is a command, exactly as the
    /// keyboard path does.
    func handleMouse(_ event: MouseEvent) async throws -> OpenGrokPagerInputRouting {
        let hit = lastOverlayBounds.last { $0.hitTest(x: event.x, y: event.y) }
        if event.isScroll {
            // Capturing overlays are scroll-blocking (`is_scroll_blocking_modal_open`,
            // app_view.rs:3016-3033 / :5619-5638): wheel never reaches the
            // transcript while any modal captures input. Over the focused
            // overlay, one vertical notch still moves selection by one row —
            // the reference's split between dropdown navigation and scrollback.
            // Horizontal scroll (`scrollLeft`/`scrollRight`) is also in
            // `isScroll`; map only up→up and down→down so left/right are
            // consumed without shifting selection or the transcript.
            // Overlay path never prices through the normalizer and cancels any
            // active transcript stream so residual ticks cannot flush later.
            pendingScrollbackClick = nil
            pendingLinkClick = nil
            clearScrollbarDragLatch()
            // Wheel mid-gesture cancels text-drag latches (not edge autoscroll).
            clearTextSelectionLatches()
            if overlays.isActive {
                mouseScrollState.cancelStream()
                if let hit, hit.id == overlays.focused?.id {
                    let key: KeyEvent?
                    switch event.kind {
                    case .scrollUp:
                        key = KeyEvent(key: .up)
                    case .scrollDown:
                        key = KeyEvent(key: .down)
                    case .scrollLeft, .scrollRight:
                        key = nil
                    default:
                        key = nil
                    }
                    if let key {
                        switch overlays.handle(key, viewportHeight: max(1, hit.content.height)) {
                        case .ignored:
                            break
                        default:
                            refreshDashboardPeek()
                            try renderState()
                        }
                    }
                }
                return .consumed
            }
            if let composerRoute = routeComposerWheel(event) {
                return composerRoute
            }
            switch event.kind {
            case .scrollUp:
                try applyTranscriptScroll(direction: .up, at: Self.monotonicNow())
            case .scrollDown:
                try applyTranscriptScroll(direction: .down, at: Self.monotonicNow())
            case .scrollLeft, .scrollRight:
                return .consumed
            default:
                return .consumed
            }
            return .consumed
        }

        if event.kind == .move {
            // Move-with-button clears a pending link click the way Rust's
            // `Moved` + `left_mouse_down` arm does (`links.rs:1427-1452` at
            // pin 650c1db7). Pure hover (no button) leaves it armed.
            if event.resolvedButton == .left {
                pendingLinkClick = nil
            }
            // B6: the context-bar hover swap (`context_bar.rs:4-8`) — the
            // pointer over the segment's last-frame cells flips the flag,
            // change-only repaint. A capturing overlay blocks it like every
            // hover.
            let overContext = !overlays.isActive
                && lastContextBarRect.map {
                    event.y == $0.y && event.x >= $0.x && event.x < $0.right
                } == true
            if overContext != contextBarHovered {
                contextBarHovered = overContext
                try renderState()
            }
            // Hover moves the welcome menu highlight — upstream's
            // `MouseEventKind::Moved` arm (`app/app_view.rs:4428-4443` at pin
            // 650c1db7): the selection becomes the row under the pointer, or
            // NONE off the rows, and only a change repaints. The `?1003`
            // any-event tracking the driver enables is what delivers motion
            // with no button held. A capturing overlay blocks hover exactly
            // as it blocks the rail (`overlay_blocks_rail_hover`).
            guard !overlays.isActive,
                  let welcomeBounds = lastOverlayBounds.last(
                      where: { $0.id == Self.welcomeOverlayID }
                  )
            else { return .consumed }
            let hoveredRowID = welcomeBounds.row(atX: event.x, y: event.y)?.id
            var changed = false
            overlays.updateWelcome { welcome in
                let target = hoveredRowID.flatMap { id in
                    welcome.menu.firstIndex { $0.id == id }
                }
                if welcome.selectedIndex != target {
                    welcome.selectedIndex = target
                    changed = true
                }
                // Hover over the changelog info block brightens it —
                // upstream's `over_cta != on_changelog_cta` change-only
                // repaint (`app/app_view.rs:4447-4452` at pin 650c1db7).
                // The CTA row is only published while the block is
                // clickable, so the flag can never brighten an inert slot.
                let overCTA = hoveredRowID == PagerWelcomeOverlay.changelogCTARowID
                if welcome.changelogHovered != overCTA {
                    welcome.changelogHovered = overCTA
                    changed = true
                }
            }
            if changed { try renderState() }
            return .consumed
        }

        if event.kind == .drag {
            pendingLinkClick = nil
            // Scrollbar drag continuously remaps against the current
            // last-painted model (updated after each real paint; never
            // ahead-of-paint layout) — `handle_scrollback_drag_motion`,
            // selection.rs:525-527.
            if scrollbarDragging {
                if overlays.isActive {
                    clearScrollbarDragLatch()
                    clearTextSelectionLatches()
                    return .consumed
                }
                if let sb = lastScrollbarHit {
                    applyScrollbarClick(screenY: event.y, geometry: sb)
                    try renderState()
                }
                return .consumed
            }
            if overlays.isActive {
                promptOwnedComposerGesture = false
                clearTextSelectionLatches()
                pendingScrollbackClick = nil
                return .consumed
            }
            if let composerRoute = routePromptOwnedComposer(event) {
                return composerRoute
            }
            if try handleTextSelectionDragMotion(event) {
                return .consumed
            }
            // Non-text drag: clear pending block click so release cannot select
            // (legacy block-select path has no block-drag promote yet).
            if pendingTextDrag == nil, deferredTextPress == nil, activeTextDrag == nil {
                pendingScrollbackClick = nil
            }
            return .consumed
        }

        if event.kind == .up {
            if scrollbarDragging {
                // Left and X10 up-none clear the latch (`mouse.rs:793-805`);
                // any other button also clears so a sticky drag cannot
                // survive a mismatched release.
                clearScrollbarDragLatch()
                pendingLinkClick = nil
                clearTextSelectionLatches()
                return .consumed
            }
            if overlays.isActive {
                promptOwnedComposerGesture = false
            }
            if let composerRoute = routePromptOwnedComposer(event) {
                return composerRoute
            }
            // Active text drag finishes before link/block (`mouse.rs:807-812`).
            if activeTextDrag != nil {
                return try finishActiveTextDrag(event)
            }
            // Drop a pending text drag that never crossed the threshold —
            // multi-click / block select still run against pendingScrollbackClick.
            let hadPendingTextDrag = pendingTextDrag != nil
            pendingTextDrag = nil
            deferredTextPress = nil
            dragAutoscroll = nil
            lastDragPointer = nil
            // No active drag → press-time freeze is obsolete.
            if activeTextDrag == nil {
                frozenDragTextSelection = nil
            }
            if !overlays.isActive, toastOccluderContains(event) {
                pendingScrollbackClick = nil
                pendingLinkClick = nil
                return .consumed
            }
            // Link completion precedes block select (`mouse.rs:823-828` before
            // `:830`): a pending link click owns the up even when the cell is
            // also a selectable block.
            if completePendingLinkClick(event) {
                return .consumed
            }
            return try await completeScrollbackClick(event, hadPendingTextDrag: hadPendingTextDrag)
        }

        guard event.kind == .down else { return .consumed }
        guard event.resolvedButton == .left else {
            pendingScrollbackClick = nil
            pendingLinkClick = nil
            clearScrollbarDragLatch()
            clearTextSelectionLatches()
            promptOwnedComposerGesture = false
            return .consumed
        }
        // New left down clears a held persistent highlight
        // (`mouse.rs:725-727` at pin 650c1db7).
        clearPersistentTextSelectionHighlight()
        promptOwnedComposerGesture = false
        // A capturing modal owns the press — clear any sticky gutter latch
        // before overlay row routing.
        if overlays.isActive {
            clearScrollbarDragLatch()
            pendingLinkClick = nil
            clearTextSelectionLatches()
            pendingScrollbackClick = nil
        }
        // Toast slot is a frame occluder (`layout.toastOccluder`): swallow
        // before transcript/composer so a click cannot select or focus
        // through the banner. Capturing overlays still win.
        if hit == nil, !overlays.isActive, toastOccluderContains(event) {
            pendingScrollbackClick = nil
            pendingLinkClick = nil
            clearScrollbarDragLatch()
            clearTextSelectionLatches()
            return .consumed
        }
        // The privacy banner's four click targets, resolved against the
        // rects the LAST frame published (the rail's per-frame-geometry
        // rule below) — upstream's banner-slot hit handling
        // (`agent_view/links.rs:610-651`: opt-in/opt-out dispatch the
        // banner actions, terms/policy dispatch `Action::OpenUrl`). A
        // capturing overlay blocks the banner exactly as it blocks the
        // rail (upstream's `overlay_blocks_rail_hover` family,
        // `agent_view/render.rs:1195-1200`), and `hit == nil` keeps clicks
        // inside ANY published overlay bounds — including the non-capturing
        // welcome hero that overpaints this slot before the first turn —
        // from reaching a banner that is not visibly on screen.
        //
        // Mouse-only by lead ruling, because upstream is (§4: no invented
        // keyboard affordance). Cost: with mouse reporting off
        // (`/toggle-mouse-reporting`, or a terminal without it), the
        // banner cannot be dismissed here — only the `/privacy` settings
        // row changes the preference, and only an ack hides the banner.
        // `hit == nil` OR the non-capturing welcome: banner rects publish
        // ONLY from a visible paint (the chrome slot with no welcome up, or
        // the W4 tip slot painted OVER the welcome), so a rect that exists
        // is a banner the user can see — routing under the welcome cannot
        // reopen the invisible-banner click-through hazard this guard
        // exists for (B9-c3). Capturing overlays still block via
        // `!overlays.isActive`, upstream's modal rule.
        if hit == nil || hit?.id == Self.welcomeOverlayID,
           !overlays.isActive, let banner = lastPrivacyBannerHits {
            if let rect = banner.optIn, rect.contains(x: event.x, y: event.y) {
                pendingScrollbackClick = nil
                pendingLinkClick = nil
                clearScrollbarDragLatch()
                clearTextSelectionLatches()
                dispatchPrivacyBannerOptIn()
                return .consumed
            }
            if let rect = banner.optOut, rect.contains(x: event.x, y: event.y) {
                pendingScrollbackClick = nil
                pendingLinkClick = nil
                clearScrollbarDragLatch()
                clearTextSelectionLatches()
                dispatchPrivacyBannerOptOut()
                return .consumed
            }
            if let rect = banner.terms, rect.contains(x: event.x, y: event.y) {
                pendingScrollbackClick = nil
                pendingLinkClick = nil
                clearScrollbarDragLatch()
                clearTextSelectionLatches()
                openExternalURL(pagerPrivacyBannerTermsURL)
                try renderState()
                return .consumed
            }
            if let rect = banner.policy, rect.contains(x: event.x, y: event.y) {
                pendingScrollbackClick = nil
                pendingLinkClick = nil
                clearScrollbarDragLatch()
                clearTextSelectionLatches()
                openExternalURL(pagerPrivacyBannerPolicyURL)
                try renderState()
                return .consumed
            }
        }
        // Scrollbar gutter click/drag latch (`mouse.rs:408-413`) — BEFORE
        // the timeline rail and before click-to-select arming, so the gutter
        // never selects a block. Uses the last-painted hit model only.
        if hit == nil, !overlays.isActive, let sb = lastScrollbarHit,
           sb.contains(x: event.x, y: event.y)
        {
            pendingScrollbackClick = nil
            pendingLinkClick = nil
            clearTextSelectionLatches()
            scrollbarDragging = true
            applyScrollbarClick(screenY: event.y, geometry: sb)
            try renderState()
            return .focusScrollback
        }
        // The timeline rail's click-to-jump (`mouse.rs:415-427`): resolve the
        // hit through the same `pagerTimelineChevronTarget` that dimmed the
        // chevrons at paint time, then jump through the `/jump` seam — both
        // roads go through the one turn enumeration and the one reveal, so a
        // tick click and a picker row cannot land differently. A capturing
        // overlay blocks the rail exactly as upstream's modals do
        // (`overlay_blocks_rail_hover`, `agent_view/render.rs:1195-1200`);
        // a click on the rail that resolves no target (dim chevron, gap row)
        // is consumed without acting (`mouse.rs:424-426`).
        if hit == nil, !overlays.isActive, let rail = lastTimelineRail,
           rail.rect.contains(x: event.x, y: event.y)
        {
            pendingScrollbackClick = nil
            pendingLinkClick = nil
            clearScrollbarDragLatch()
            clearTextSelectionLatches()
            if let railHit = rail.hit(x: event.x, y: event.y),
               let turnIndex = pagerTimelineChevronTarget(rail, railHit)
            {
                let turnBlocks = pagerTimelineTurnBlockIndices(conversation.items)
                if turnBlocks.indices.contains(turnIndex) {
                    try? revealBlock(at: turnBlocks[turnIndex])
                    try renderState()
                }
            }
            return .consumed
        }
        // Transcript link click arm (`mouse.rs:728-737` at pin 650c1db7) —
        // AFTER overlay / banner / scrollbar / rail, BEFORE pending block /
        // text select. Uses last-painted `PagerRenderResult.links` only
        // (Standard-scheme filtered at paint).
        //
        // Gate = upstream `!has_native_link_hover() && is_link_modifier_held`:
        // - `supportsHyperlinks` stands in for native OSC 8 ownership: when
        //   the sink advertises hyperlinks, the terminal owns activation and
        //   we never arm `pendingLinkClick`, so ordinary left clicks reach
        //   text/block selection (word_select URL multi-click). Cost vs pin:
        //   Rust's `native_link_hover` is a narrower brand flag (VS Code
        //   family); this port has no separate hover probe, so the existing
        //   capability bit is the portable proxy.
        // - When hyperlinks are unavailable, arm only if a link modifier is
        //   held. Upstream uses Cmd via CoreGraphics on macOS and Ctrl from
        //   the mouse event elsewhere; we accept control / meta / superKey
        //   on the event (SGR wire reports control; meta/superKey cover Cmd
        //   when a driver stamps them). Shift and alt alone never qualify —
        //   do not invent CoreGraphics Cmd polling.
        if hit == nil, !overlays.isActive,
           !sink.capabilities.supportsHyperlinks,
           Self.isLinkModifierHeld(event.modifiers),
           let link = paintedLink(atX: event.x, y: event.y)
        {
            clearScrollbarDragLatch()
            pendingScrollbackClick = nil
            clearTextSelectionLatches()
            pendingLinkClick = (event.x, event.y, link.url)
            return .consumed
        }
        // Click-to-select + text-drag pending arm: only when no overlay owns
        // the cell, no capturing modal is up, and the point is inside the
        // last painted content/chrome band — strictly after scrollbar/rail/
        // link. Freeze the painted hit model with the down cell so up cannot
        // remap against a later scroll. Nearest same-row text arms alongside
        // block pending when selectable; chrome miss sets deferred_text_press
        // so a later drag into text can convert (`mouse.rs:742-758`).
        if hit == nil, !overlays.isActive,
           let model = lastConversationHit,
           model.containsSelectablePoint(x: event.x, y: event.y)
        {
            clearScrollbarDragLatch()
            pendingLinkClick = nil
            pendingScrollbackClick = (event.x, event.y, model)
            // Left-down that can promote to a drag cancels residual wheel
            // so one clock wake cannot apply stream lines plus autoscroll.
            mouseScrollState.cancelStream()
            if let textModel = lastTextSelection,
               let textHit = textModel.hitTestSelectableRange(col: event.x, row: event.y)
            {
                pendingTextDrag = PagerPendingTextDrag(
                    anchor: textHit,
                    startCol: event.x,
                    startRow: event.y,
                    anchorContentWidth: textModel.visibleBlockContentWidth(
                        entryIndex: textHit.entryIndex
                    )
                )
                // Freeze at press (not only promote) so a resize before the
                // drag threshold cannot orphan pending blockLineIndex values.
                frozenDragTextSelection = textModel
                deferredTextPress = nil
                activeTextDrag = nil
            } else {
                pendingTextDrag = nil
                activeTextDrag = nil
                frozenDragTextSelection = nil
                deferredTextPress = (event.x, event.y)
            }
            return .consumed
        }
        // Composer left-down (Rust prompt `handle_mouse` on down,
        // `mouse.rs:525-552` at pin 650c1db7): after overlay / banner /
        // scrollbar / rail / link / block arming. Pane is disjoint from the
        // transcript gutter so those priorities stay intact. Capturing
        // modals never focus the composer underneath. Clears pending
        // scrollbar/link/block/text latches. Collapsed-unfocused and
        // border/prefix → `.focusComposer` (focus only). Content cell arms
        // a prompt-owned gesture and returns `.composerMouse` with the
        // last-painted content rect.
        if hit == nil, !overlays.isActive,
           let composer = lastComposerHit,
           composer.containsPane(x: event.x, y: event.y)
        {
            pendingScrollbackClick = nil
            pendingLinkClick = nil
            clearScrollbarDragLatch()
            clearTextSelectionLatches()
            selection.unfocus()
            try renderState()
            if !composer.isFocused {
                promptOwnedComposerGesture = false
                return .focusComposer
            }
            switch composer.hit(x: event.x, y: event.y) {
            case .content:
                promptOwnedComposerGesture = true
                lastKnownComposerContentRect = composer.contentRect
                // A leftover wheel stream must not share the next clock wake
                // with composer edge autoscroll.
                mouseScrollState.cancelStream()
                return .composerMouse(OpenGrokPagerComposerMouse(
                    event: event,
                    content: composer.contentRect
                ))
            case .focusOnly, .none:
                promptOwnedComposerGesture = false
                return .focusComposer
            }
        }
        promptOwnedComposerGesture = false
        pendingScrollbackClick = nil
        pendingLinkClick = nil
        clearScrollbarDragLatch()
        clearTextSelectionLatches()
        guard let hit else { return .consumed }
        if let close = hit.closeButton, close.contains(x: event.x, y: event.y) {
            overlays.dismiss(id: hit.id)
            if currentPermissionRequestID.map({ "permission:\($0)" }) == hit.id {
                currentPermissionRequestID = nil
            }
            handleOverlayDismissal(hit.id)
            try renderState()
            return .consumed
        }
        if let row = hit.row(atX: event.x, y: event.y) {
            let command = try await select(overlayID: hit.id, rowID: row.id)
            try renderState()
            return command.map { .runCommand($0) } ?? .consumed
        }
        var command: String?
        if let hint = hit.hints.first(where: { $0.frame.contains(x: event.x, y: event.y) }),
           let key = Self.keyEvent(forHint: hint.key)
        {
            switch overlays.handle(key, viewportHeight: max(1, hit.content.height)) {
            case .selected(let id, let rowID):
                command = try await select(overlayID: id, rowID: rowID)
            case .permission(let id, let requestID, let decision):
                await resolve(overlayID: id, requestID: requestID, decision: decision)
            case .question(let id, let requestID, let outcome):
                await resolveQuestion(overlayID: id, requestID: requestID, outcome: outcome)
            case .planApproval(let id, let requestID, let outcome):
                await resolvePlanApproval(overlayID: id, requestID: requestID, outcome: outcome)
            case .setting(_, let event):
                await applySetting(event)
            case .dismissed(let id):
                handleOverlayDismissal(id)
            case .ignored, .redraw, .consumed:
                break
            }
            try renderState()
        }
        return command.map { .runCommand($0) } ?? .consumed
    }

    /// Prompt-owned drag/up: keep forwarding even outside the pane so
    /// TextArea edge autoscroll sees the pointer. A prompt-owned up always
    /// forwards using the last known content rect even if the current hit
    /// model is nil (resize below the paint gate), then clears the latch.
    /// `nil` when no gesture.
    func routePromptOwnedComposer(_ event: MouseEvent) -> OpenGrokPagerInputRouting? {
        guard promptOwnedComposerGesture else { return nil }
        let content = lastComposerHit?.contentRect ?? lastKnownComposerContentRect
        if event.kind == .up {
            promptOwnedComposerGesture = false
        }
        guard let content else {
            promptOwnedComposerGesture = false
            return .consumed
        }
        return .composerMouse(OpenGrokPagerComposerMouse(
            event: event,
            content: content
        ))
    }

    /// Wheel over the composer pane (or during a prompt-owned gesture) goes
    /// to TextArea, never the transcript. Unfocused / collapsed still
    /// forwards (`panes.rs:669-685` at pin 650c1db7: `prompt.handle_mouse`
    /// without `set_active_pane`). The controller must not `setFocus(.prompt)`
    /// on scroll kinds, so j/k stay on the scrollback.
    func routeComposerWheel(_ event: MouseEvent) -> OpenGrokPagerInputRouting? {
        guard !overlays.isActive else { return nil }
        if promptOwnedComposerGesture {
            return routePromptOwnedComposer(event)
        }
        guard let composer = lastComposerHit,
              composer.containsPane(x: event.x, y: event.y)
        else { return nil }
        pendingScrollbackClick = nil
        pendingLinkClick = nil
        clearScrollbarDragLatch()
        clearTextSelectionLatches()
        return .composerMouse(OpenGrokPagerComposerMouse(
            event: event,
            content: composer.contentRect
        ))
    }

    // MARK: - Transcript text selection (linear + table; pin 650c1db7)

    func textSelectionNowMs() -> UInt64 {
        if let injected = testingTextSelectionNowMs { return injected }
        return DispatchTime.now().uptimeNanoseconds / 1_000_000
    }

    /// Clear pending/active drag latches without touching a held highlight.
    /// Orphan sidecar (no persistent table claim) drops with the latches;
    /// `finishActiveTextDrag` passes `false` so copy/persist can still use it.
    func clearTextSelectionLatches(droppingOrphanSidecar: Bool = true) {
        pendingTextDrag = nil
        activeTextDrag = nil
        deferredTextPress = nil
        dragAutoscroll = nil
        lastDragPointer = nil
        frozenDragTextSelection = nil
        if droppingOrphanSidecar {
            dropTableSidecarUnlessPersistentTable()
        }
    }

    /// Cheap pre-gate matching pin 650c1db7 (`compute_drag_table_geometry`):
    /// prose without box-drawing must not run full-range detect.
    func textLineLooksLikeTable(_ text: String) -> Bool {
        text.contains { char in
            char == "\u{2502}" || char == "\u{250C}" || char == "\u{251C}" || char == "\u{2514}"
        }
    }

    func isTableShaped(_ kind: PagerTextSelectionKind) -> Bool {
        switch kind {
        case .linear:
            return false
        case .tableCell, .tableGrid:
            return true
        }
    }

    /// Table kinds require a sidecar keyed to this selection; otherwise linear.
    func persistableSelectionKind(
        _ kind: PagerTextSelectionKind,
        entryIndex: Int,
        rangeID: UInt16
    ) -> PagerTextSelectionKind {
        switch kind {
        case .linear:
            return .linear
        case .tableCell, .tableGrid:
            if matchingTableGeometry(entryIndex: entryIndex, rangeID: rangeID) != nil {
                return kind
            }
            tableSelectionGeometry = nil
            return .linear
        }
    }

    func matchingTableGeometry(entryIndex: Int, rangeID: UInt16) -> PagerTableGeometry? {
        tableSelectionGeometry?.forSelection(entryIndex: entryIndex, rangeID: rangeID)
    }

    func dropTableSidecarUnlessPersistentTable() {
        switch persistentTextSelection?.kind {
        case .tableCell, .tableGrid:
            break
        case .linear, nil:
            tableSelectionGeometry = nil
        }
    }

    /// Detect the grid under `anchor` from a full selectable-range's lines
    /// (off-screen included). `nil` when the cheap gate fails, detect fails,
    /// or the range is missing — callers then stay linear.
    func computeDragTableGeometry(
        anchor: PagerTextRangeHit,
        model: PagerTextSelectionModel?
    ) -> PagerTableSelectionGeometry? {
        guard let model, let line = model.line(for: anchor),
              textLineLooksLikeTable(line.text)
        else { return nil }
        guard let geometry = pagerDetectTableGeometry(
            in: model,
            entryIndex: anchor.entryIndex,
            rangeID: anchor.rangeID,
            atLine: anchor.blockLineIndex
        ) else { return nil }
        return PagerTableSelectionGeometry(
            entryIndex: anchor.entryIndex,
            rangeID: anchor.rangeID,
            geometry: geometry
        )
    }

    func noteMotionClockAnchor(seconds: TimeInterval) {
        motionClockAnchorSeconds = seconds
        motionClockAnchorMonotonic = Self.monotonicNow()
    }

    /// Snapshot for paints: tick stays at the last painted frame (spinner
    /// cadence), but `seconds` extrapolates so finish-flash and elapsed stay
    /// honest between ticks and across idle gaps.
    var paintMotion: PagerMotionSnapshot {
        PagerMotionSnapshot(
            tick: motion.tick,
            seconds: motionEnabled ? currentMotionSeconds() : motion.seconds,
            enabled: motion.enabled
        )
    }

    /// Report what is moving on screen to the controller's ticker whenever it
    /// changes. This is what turns the ticker on for the welcome shimmer with
    /// no turn running, and what lets it park when the screen goes still.
    func publishMotionState() {
        let state = PagerMotionState(
            hasRunningTurn: turnActivity != nil,
            // Approximated as "a streaming block exists and the viewport
            // follows the tail". A block streaming above a scrolled-away
            // viewport misses the reference's finer visibility test and stays
            // animated; the cost is spare frames, never a frozen spinner.
            hasVisibleRunningBlock: followsBottom && hasStreamingBlock,
            // Minimal keeps the cache for probes but must not arm a fast
            // ticker the scrollback frontend never consumes.
            hasBackgroundTasks: minimalHost == nil && (activeBackgroundWork.hasActive || gboom != nil),
            showsWelcomeLogo: overlays.contains(id: "welcome"),
            hasPendingFlash: hasPendingFlash,
            motionEnabled: motionEnabled
        )
        guard state != lastPublishedMotionState else { return }
        lastPublishedMotionState = state
        guard motionSink != nil else { return }
        pendingMotionDelivery = state
        guard motionDeliveryTask == nil else { return }
        let epoch = motionSinkEpoch
        motionDeliveryTask = Task {
            await self.deliverMotionStates(epoch: epoch)
        }
    }

    /// Ordered, coalescing delivery: at most one await on the sink at a time,
    /// always forwarding the newest pending state. Never awaited from the
    /// event-mutation path that called `publishMotionState`.
    func deliverMotionStates(epoch: UInt64) async {
        while !Task.isCancelled {
            guard let packet = takePendingMotionDelivery(epoch: epoch) else { break }
            await packet.sink(packet.state)
        }
        finishMotionDelivery(epoch: epoch)
    }

    func takePendingMotionDelivery(
        epoch: UInt64
    ) -> (state: PagerMotionState, sink: @Sendable (PagerMotionState) async -> Void)? {
        // Stale loops must not clear a newer epoch's pending coalesce slot.
        guard epoch == motionSinkEpoch, let sink = motionSink else {
            return nil
        }
        guard let state = pendingMotionDelivery else { return nil }
        pendingMotionDelivery = nil
        return (state, sink)
    }

    func finishMotionDelivery(epoch: UInt64) {
        guard epoch == motionSinkEpoch else { return }
        motionDeliveryTask = nil
        // A publish may have landed after the last take returned nil and
        // before this clear — re-arm so the newest state is not stranded.
        guard pendingMotionDelivery != nil, motionSink != nil else { return }
        let nextEpoch = motionSinkEpoch
        motionDeliveryTask = Task {
            await self.deliverMotionStates(epoch: nextEpoch)
        }
    }

    var hasStreamingBlock: Bool {
        conversation.items.contains { item in
            switch item {
            case .message(let message): return message.isStreaming
            case .tool(let tool): return tool.state == .running || tool.state == .pending
            case .block(let block): return block.isRunning
            case .separator: return false
            }
        }
    }

    var hasPendingFlash: Bool {
        if motionEnabled, transientToast != nil { return true }
        guard motionEnabled else { return false }
        let now = currentMotionSeconds()
        return conversation.items.contains { item in
            guard case .tool(let tool) = item, let finishedAt = tool.finishedAt else {
                return false
            }
            return PagerMotion.isFlashing(finishedAt: finishedAt, now: now)
        }
    }

    /// Re-read the compaction coordinator's context accounting — the status
    /// bar's ramp shows the same numbers auto-compaction decides on. Called
    /// at turn boundaries; between turns the figures cannot move.
    func refreshContextUsage() async {
        guard let compaction else { return }
        contextUsage = await compaction.usage()
    }

}
