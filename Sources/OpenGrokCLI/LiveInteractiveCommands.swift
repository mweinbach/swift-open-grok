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

    /// Fold the injectable XTVERSION collector into an otherwise-standalone
    /// diagnostic snapshot. Other TUI-only runtime probes stay Unavailable.
    func doctorDiagnosticSnapshot(
        standalone: StandaloneDiagnosticSnapshot,
        terminal: TerminalContext
    ) -> DiagnosticSnapshot {
        let xtversion = LiveXtversionCollector().collect(context: terminal)
        return DiagnosticSnapshot(
            common: standalone.common,
            clipboard: standalone.clipboard,
            hostOs: standalone.hostOs,
            displayServer: standalone.displayServer,
            containerNoDisplay: standalone.containerNoDisplay,
            colorLevel: standalone.colorLevel,
            runtime: DiagnosticRuntimeEvidence(
                fullscreenActive: .unavailable,
                kittyFlagsPushed: .unavailable,
                xtversion: xtversion
            )
        )
    }

    /// `/effort [level]` — reasoning effort on the current model, upstream
    /// effort.rs:57-92: the model id stays fixed and only the effort moves,
    /// through the same switch path `/model <name> <effort>` uses.
    func applyEffortCommand(query: String?) async {
        // The composer border carries the wire model name; resolve it back to
        // its catalog entry for the effort menu. A model the catalog no
        // longer knows classifies as unsupported, which is also what
        // upstream's option-less menu resolves to.
        let entry = catalogStore?.entryForWireModel(modelName)
            ?? modelCatalog.first { $0.id == modelName }
        let supportsEffort = entry?.supportsReasoningEffort ?? false
        let declaredEfforts = entry?.reasoningEfforts ?? []

        guard let query, !query.isEmpty else {
            // Bare `/effort`: upstream's usage error listing the current
            // model's own option ids and the session's current effort
            // (effort.rs:63-81). The current effort reads through the
            // manager's session-level tracker (`currentReasoningEffortValue`),
            // seeded at launch and updated by every switch.
            let offered = LiveModelEffort.options(
                supportsReasoningEffort: supportsEffort,
                declaredEfforts: declaredEfforts
            ).map(\.id)
            let levels = offered.isEmpty ? "<level>" : offered.joined(separator: "|")
            let current = (catalogStore?.currentReasoningEffort()?.asString ?? reasoningEffort)
                .map { " (current: \($0))" } ?? ""
            appendMessage(PagerMessage(
                role: .error,
                text: "Usage: /effort <\(levels)>\(current)"
            ))
            return
        }
        switch LiveModelEffort.resolve(
            token: query,
            supportsReasoningEffort: supportsEffort,
            declaredEfforts: declaredEfforts
        ) {
        case .success(let effort):
            // Same wire path as `/model <name> <effort>` — the coordinator
            // treats an effort-only re-pick of the active model as a real
            // switch, and `switchModel` updates the composer's effort label.
            await switchModel(to: entry?.id ?? modelName, effort: effort)
        case .failure(let error):
            appendMessage(PagerMessage(role: .error, text: error.message))
        }
    }

    /// `/fast` — toggle Fast mode (priority routing) on the current model,
    /// upstream fast.rs:31-52: an `Action::SwitchModel` to the SAME model with
    /// the session effort preserved and only the service tier moved. Enabling
    /// selects the model's fast tier id; disabling sends the explicit
    /// standard-routing clear (`Some(None)`, fast.rs:39-44) so a prior
    /// selection cannot linger.
    func applyFastCommand() async {
        guard let modelSwitch else {
            // No live sampling stack behind this renderer — upstream's
            // no-current-model refusal (fast.rs:32-34).
            appendMessage(PagerMessage(role: .error, text: "No active model"))
            return
        }
        let entry = catalogStore?.entryForWireModel(modelName)
            ?? modelCatalog.first { $0.id == modelName }
        guard let fastID = entry?.fastServiceTierID else {
            // Upstream's unsupported-model refusal, byte-exact (fast.rs:35-37).
            appendMessage(PagerMessage(
                role: .error,
                text: "current model does not support Fast mode"
            ))
            return
        }
        // The toggle state derives from the live coordinator — the tier the
        // sampler is actually built with — never a renderer-side mirror.
        let fastOn = liveFastModeEnabled(
            serviceTier: await modelSwitch.activeServiceTier,
            supportsFast: true
        )
        // Preserve the session effort when only the service tier changes
        // (fast.rs:48-49); `nil` would re-resolve the catalog default and
        // silently drop a `/effort` override.
        let currentEffort = await modelSwitch.snapshot().configuration.reasoningEffort
        await switchModel(
            to: entry?.id ?? modelName,
            effort: currentEffort,
            serviceTier: fastOn ? String??.some(nil) : String??.some(fastID)
        )
    }

    /// Drop rendered blocks from the `targetPromptIndex`-th user prompt onward.
    ///
    /// Counted positionally over user blocks, the same rule
    /// `liveTruncateConversation` applies to the persisted items — the two lists
    /// hold different things (the renderer has no tool results, the record has
    /// no system notices) but they agree on how many user turns have happened,
    /// which is the only thing the index means.
    func truncateRenderedTranscript(toPromptIndex targetPromptIndex: Int) {
        var seen = 0
        var cut: Int?
        for (index, item) in conversation.items.enumerated() {
            guard case .message(let message) = item, message.role == .user else { continue }
            if seen == targetPromptIndex {
                cut = index
                break
            }
            seen += 1
        }
        guard let cut else { return }
        conversation.truncate(to: cut)
        selection.clamp(itemCount: conversation.items.count)
        followsBottom = true
    }

    /// Shared `/transcript` + `$EDITOR` suspend order: local motion hold →
    /// cancel+await pending flush → await `host.suspendMotion` → park input →
    /// tear down the tty → run the child → restore tty/input →
    /// `host.resumeMotion` → clear the hold. Park / pre-ownership suspend
    /// failures resume motion and clear the hold (`motionEnabled` is never
    /// lied about). A terminal/input restore failure keeps the hold,
    /// best-effort `frontendRestore`, and does **not** call `resumeMotion` —
    /// re-arming into a broken restore races teardown.
    func runSuspendedChild(
        host: LiveTUISuspendHost,
        program: String,
        arguments: [String],
        suspendFailPrefix: String
    ) async throws -> SuspendedChildOutcome {
        localMotionHold = true
        // Suspend clears scrollbar drag the same way it cancels the scroll
        // stream — a child-owned tty must not resume into a sticky latch.
        clearScrollbarDragLatch()
        // Link / block click latches must not survive a child-owned tty —
        // a release after restore would open or select against stale cells.
        pendingLinkClick = nil
        pendingScrollbackClick = nil
        clearTextSelectionLatches()
        promptOwnedComposerGesture = false
        // Suspend cancels any active transcript scroll stream so the
        // controller's scroll clock disarms (deadline nil) and cannot flush
        // into the child-owned tty.
        cancelScrollStreamForLifecycle()
        await cancelPendingFlushTask()
        // Cancel the flash Task but keep highlight + monotonic deadline —
        // resume reconciles (clear if elapsed, else re-arm remaining TTL).
        // No paint while `localMotionHold` is set.
        await suspendTextSelectionFlashTask()
        await host.suspendMotion()

        // Park the reader and drop raw mode (event_loop.rs:365-371, :399; the
        // port releases the lease with the park so the input resource stays
        // the single owner of termios — escape output is unaffected by the
        // cooked/raw order swap). On timeout, upstream's error text, nothing
        // torn down, and the suspend aborts; see
        // `LiveInteractiveInputResource.beginSuspension` for what the
        // single-attempt divergence costs.
        guard let suspension = await host.beginInputSuspension() else {
            // Ownership never moved — safe to resume the controller ticker.
            await host.resumeMotion()
            localMotionHold = false
            reconcileTextSelectionFlashAfterResume()
            return .parkTimedOut
        }
        do {
            try frontendSuspendToChild()
        } catch {
            // Suspend-to-child failed before the child owned the tty; park is
            // rolled back and motion may resume.
            try? await suspension.end()
            await host.resumeMotion()
            localMotionHold = false
            reconcileTextSelectionFlashAfterResume()
            note("\(suspendFailPrefix): \(error)")
            return .suspendFailed
        }

        let launchError = await LiveTUISuspendHost.runChild(
            program: program,
            arguments: arguments,
            environment: host.environment
        )
        do {
            try frontendResumeFromChild()
            try await suspension.end()
        } catch {
            // Either the tty rejected the re-entry writes or raw mode failed:
            // a genuinely broken terminal. Keep `localMotionHold` so ticks and
            // pending flushes stay dark, best-effort restore the frontend, and
            // do not `resumeMotion` into a restore failure (controller shutdown
            // latch / hold must stay shutdown-safe).
            try? frontendRestore()
            throw error
        }
        await host.resumeMotion()
        localMotionHold = false
        reconcileTextSelectionFlashAfterResume()
        return .completed(launchError: launchError)
    }

    func resolveOutstandingPermissions() async {
        guard let permissionCoordinator else { return }
        await permissionCoordinator.resolveAll(with: .deny)
        if let current = currentPermissionRequestID {
            overlays.dismiss(id: "permission:\(current)")
            currentPermissionRequestID = nil
        }
    }

    /// Cancel every outstanding questionnaire — the question analog of
    /// `resolveOutstandingPermissions`, with cancel (not deny) as the
    /// resolution because upstream treats a dismissed question as a normal
    /// user decision (`format.rs:16-22`).
    func resolveOutstandingQuestions() async {
        guard let questionCoordinator else { return }
        await questionCoordinator.resolveAll()
        if let current = currentQuestionRequestID {
            overlays.dismiss(id: "question:\(current)")
            currentQuestionRequestID = nil
        }
        pendingQuestionRequest = nil
    }

    /// Resolve every outstanding plan approval — teardown, turn
    /// cancellation. The coordinator resolves them as upstream's stale
    /// cancel (no-feedback revise), so the plan gate stays armed — fail
    /// closed, never an approve or an abandon the user did not choose.
    func resolveOutstandingPlanApprovals() async {
        guard let planApprovalCoordinator else { return }
        await planApprovalCoordinator.resolveAll()
        if let current = currentPlanApprovalRequestID {
            overlays.dismiss(id: "plan-approval:\(current)")
            currentPlanApprovalRequestID = nil
        }
        pendingPlanApprovalRequest = nil
    }

    // MARK: - /plan, /view-plan

    /// Arm plan mode for `/plan`, through `LiveToolExecutor.armPlanMode()` →
    /// `PermissionPipeline.enterPlanMode` — the SAME seam the
    /// `enter_plan_mode` tool handler mutates, so the slash path and the
    /// tool path share one tracker and one plan-file path. Idempotent like
    /// upstream's `set_plan_mode` (`dispatch/modes.rs:152-159`): an armed
    /// session gets the toast without a second arm. The toast copy is
    /// `save_success_toast("Plan mode", true)` byte for byte
    /// (`settings/ui.rs:89-92`).
    func armPlanModeFromSlash() async {
        guard let toolExecutor else {
            // Upstream's refusal when the mode switch has nowhere to land
            // (`dispatch/modes.rs:144-147`), copy byte-identical. The
            // interactive composition always passes an executor, so this arm
            // is reachable only from partial (test/headless) constructions.
            note("No active session")
            return
        }
        if await !toolExecutor.planModeActive() {
            guard await toolExecutor.armPlanMode() else {
                // Executor without a pipeline: the arm has nowhere to land.
                // Refusing here (instead of noting "on") keeps the note
                // truthful — same copy as the executor-nil arm above.
                note("No active session")
                return
            }
        }
        note("\u{2713} Plan mode: on")
    }

    // MARK: - /swarm

    /// `/swarm [on|off]` — upstream `set_swarm_mode(persist: true)`
    /// (`dispatch/modes.rs:199-248`): the live tracker moves first (the
    /// session-notify half, `SessionCommand::SetSwarmMode` →
    /// `enter_swarm_mode`/`exit`, run_loop.rs:1120-1138), then the
    /// preference persists to `ui.swarm_mode` through the same settings
    /// store the modal row writes, then the
    /// `save_success_toast("Swarm mode", enabled)` copy byte for byte
    /// (`settings/ui.rs:89-92`). A manual disable exits whatever trigger is
    /// current — upstream's non-task disable arm (run_loop.rs:1128-1132).
    func setSwarmModeFromSlash(enabled: Bool) async {
        if let toolExecutor {
            if enabled {
                await toolExecutor.swarmMode.enter(.manual)
            } else {
                await toolExecutor.swarmMode.exit()
            }
        }
        await applySettingsEvent(.commit(key: "swarm_mode", value: .bool(enabled)))
        note("\u{2713} Swarm mode: \(enabled ? "on" : "off")")
    }

    /// `/swarm <task>`'s mode-switch half — the session-observing side of
    /// upstream's ordered `SwarmModeThenPrompt` effect (`router.rs:1052-1093`,
    /// `effects/mod.rs:3148-3188`): the one-shot `task` trigger enters the
    /// live tracker BEFORE the controller enqueues the task prompt (the
    /// controller awaits this render). Nothing persists — upstream's task
    /// arm never touches `ui.swarm_mode`. The toast is `router.rs:1090`'s,
    /// byte for byte.
    func enterSwarmTaskModeFromSlash() async {
        guard let toolExecutor else {
            // The mode switch has nowhere to land — same refusal copy as
            // the plan arm (`dispatch/modes.rs:144-147`). Without it the
            // task would run as a plain prompt while claiming to be a
            // swarm task.
            note("No active session")
            return
        }
        await toolExecutor.swarmMode.enter(.task)
        note("Starting swarm task...")
    }

    /// Rebuild the live sampling stack for `modelID` and record what happened.
    ///
    /// A refused switch is reported as an error row and leaves `modelName` — and
    /// therefore the composer's border and the next turn's provider — alone.
    ///
    /// `effort` is a validated `/model <name> <effort>` override; `nil` keeps
    /// the model's catalog default.
    ///
    /// `serviceTier` follows the coordinator's `SwitchModel` semantics: outer
    /// `nil` preserves the session tier (a `/model` switch keeps Fast on when
    /// the target still supports it), `.some(nil)` clears to standard
    /// routing, `.some(.some(id))` selects a tier — the `/fast` toggle.
    func switchModel(
        to modelID: String,
        effort: ReasoningEffort? = nil,
        serviceTier: String?? = nil
    ) async {
        guard let modelSwitch else {
            // No provider session behind this renderer; the picker can still
            // relabel, but it must not claim the session changed.
            modelName = modelID
            appendMessage(PagerMessage(
                role: .system,
                text: "Model set to \(modelID). It applies to new sessions — "
                    + "this session keeps its current model."
            ))
            return
        }
        switch await modelSwitch.apply(
            modelID: modelID,
            effort: effort,
            serviceTier: serviceTier
        ) {
        case .unchanged:
            appendMessage(PagerMessage(
                role: .system,
                text: "Already using \(modelID)."
            ))
        case .switched(let summary):
            modelName = summary.modelID
            reasoningEffort = summary.reasoningEffort?.asString
            // Mirror of upstream `set_session_model`'s tail
            // (handlers/model_switch.rs:299-303): the manager's current
            // model/effort track the session so `/model` defaults and any
            // future `/effort` surface read the applied state.
            catalogStore?.noteModelSwitch(
                catalogID: summary.requestedID,
                effort: summary.reasoningEffort
            )
            if let providerBoundarySync {
                do {
                    let boundary = await conversationHistory?.sharedExportBoundary
                    try await providerBoundarySync(boundary?.everUsedNonXAI ?? false)
                } catch {
                    note("Provider boundary summary could not be persisted: \(error)")
                }
            }
            appendMessage(PagerMessage(
                role: .system,
                text: summary.transcriptMessage
            ))
        case .failed(let modelID, let message):
            appendMessage(PagerMessage(
                role: .error,
                text: "Could not switch to \(modelID): \(message). "
                    + "Staying on \(modelName)."
            ))
        }
    }

    func resolve(
        overlayID: String,
        requestID: String,
        decision: PagerPermissionDecision
    ) async {
        overlays.dismiss(id: overlayID)
        if currentPermissionRequestID == requestID { currentPermissionRequestID = nil }
        await permissionCoordinator?.resolve(requestID: requestID, decision: decision)
    }

    func resolveQuestion(
        overlayID: String,
        requestID: String,
        outcome: PagerQuestionOutcome
    ) async {
        overlays.dismiss(id: overlayID)
        if currentQuestionRequestID == requestID { currentQuestionRequestID = nil }
        await questionCoordinator?.resolve(requestID: requestID, outcome: outcome)
    }

    func resolvePlanApproval(
        overlayID: String,
        requestID: String,
        outcome: PagerPlanApprovalOutcome
    ) async {
        overlays.dismiss(id: overlayID)
        if currentPlanApprovalRequestID == requestID { currentPlanApprovalRequestID = nil }
        await planApprovalCoordinator?.resolve(requestID: requestID, outcome: outcome)
    }

}
