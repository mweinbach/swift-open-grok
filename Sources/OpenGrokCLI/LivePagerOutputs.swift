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


actor LivePagerRuntimeAdapter: OpenGrokPagerMinimalRuntimeAdapter, OpenGrokPagerRuntimeAdapter {
    let shell: OpenGrokShell
    let cwd: URL
    private var providerConfiguration: ProviderSessionConfiguration
    private let conversationHistory: LiveConversationHistory
    private let conversationStore: LiveConversationStore
    private let toolExecutor: LiveToolExecutor?
    private let compaction: LiveCompactionCoordinator?
    /// The route the next turn actually runs on. `/resume` reconciles the
    /// restored record against this rather than the launch configuration,
    /// because `/model` may have moved the session since launch.
    private let modelSwitch: LiveModelSwitchCoordinator?
    private let registerExportBoundary: (@Sendable (String, ExportBoundary) -> Void)?
    /// The one session id turns may currently run against, and every id this
    /// process has already created in the shell. Two values because `/resume`
    /// can revisit a session created earlier in this run — recreating it in
    /// the shell would fail, but switching back to it must not.
    private var activeShellSessionID: SessionID?
    private var createdSessionIDs: Set<SessionID> = []
    private var retainedRecords: [String: LiveConversationRecord] = [:]
    private var activeWorkingDirectory: URL

    init(
        shell: OpenGrokShell,
        cwd: URL,
        providerConfiguration: ProviderSessionConfiguration,
        conversationHistory: LiveConversationHistory,
        conversationStore: LiveConversationStore,
        toolExecutor: LiveToolExecutor? = nil,
        compaction: LiveCompactionCoordinator? = nil,
        modelSwitch: LiveModelSwitchCoordinator? = nil,
        registerExportBoundary: (@Sendable (String, ExportBoundary) -> Void)? = nil
    ) {
        self.shell = shell
        self.cwd = cwd
        self.providerConfiguration = providerConfiguration
        self.conversationHistory = conversationHistory
        self.conversationStore = conversationStore
        self.toolExecutor = toolExecutor
        self.compaction = compaction
        self.modelSwitch = modelSwitch
        self.registerExportBoundary = registerExportBoundary
        self.activeWorkingDirectory = cwd.standardizedFileURL
    }

    func makeSession(
        for request: OpenGrokPagerMinimalRequest
    ) async throws -> any OpenGrokPagerMinimalSessionAdapter {
        _ = try await shell.start()
        let shellEvents = await shell.events()
        let sessionID = SessionID(request.sessionID ?? providerConfiguration.sessionID)
        let record = await conversationHistory.snapshot()
        guard record.sessionID == sessionID.rawValue else {
            throw CLIApplicationError.failed(
                "interactive runtime session mismatch: \(sessionID.rawValue)"
            )
        }
        let sessionDirectory = URL(
            fileURLWithPath: record.workingDirectory,
            isDirectory: true
        ).standardizedFileURL
        if !createdSessionIDs.contains(sessionID) {
            _ = try await shell.createSession(OpenGrokShellSessionRequest(
                sessionID: sessionID,
                cwd: sessionDirectory,
                providerConfiguration: providerConfiguration,
                restorePersistedState: false
            ))
            try await toolExecutor?.registerSession(
                sessionID: sessionID.rawValue,
                workingDirectory: sessionDirectory
            )
            createdSessionIDs.insert(sessionID)
            // The record is born carrying the boundary's CURRENT truth, not
            // the launch configuration's snapshot — upstream marks the store
            // at session open (`initialize_provider_boundary`, persistence.rs
            // :2745-2758) for the same reason. Without this, a pre-first-turn
            // `/model` switch to a non-xAI provider (deferred below because
            // no record existed yet) would create a shell summary claiming
            // the session never left xAI.
            if await conversationHistory.sharedExportBoundary.everUsedNonXAI {
                try await shell.synchronizeProviderBoundary(
                    sessionID: sessionID,
                    everUsedNonXAI: true
                )
            }
        }
        activeWorkingDirectory = sessionDirectory
        retainedRecords[sessionID.rawValue] = record
        activeShellSessionID = sessionID
        // A Cron turn arrives with the RAW stored prompt plus scheduler
        // metadata; this seam frames the model text and stamps the
        // `scheduler-fired-` prompt id — the port of upstream's Cron drain
        // arm (`app/dispatch/queue.rs:518-560`: `format_cron_prompt` on the
        // wire text, raw text kept for display). The prompt-id prefix is what
        // the turn loop later maps to the `.schedulerFired` persisted item
        // (`PromptOrigin::from_prompt_id`, session/mod.rs:126-127).
        let promptID = request.metadata[
            OpenGrokPagerInteractiveController.promptIDMetadataKey
        ] ?? UUID().uuidString
        let turnRequest: OpenGrokShellTurnRequest
        if let cronTaskID = request.metadata[
            OpenGrokPagerInteractiveController.cronTaskIDMetadataKey
        ] {
            let humanSchedule = request.metadata[
                OpenGrokPagerInteractiveController.cronHumanScheduleMetadataKey
            ] ?? "unknown"
            turnRequest = OpenGrokShellTurnRequest(
                promptID: promptID,
                text: formatScheduledTaskPrompt(
                    request.prompt,
                    taskID: cronTaskID,
                    humanSchedule: humanSchedule
                )
            )
        } else if request.metadata[
            OpenGrokPagerInteractiveController.monitorTaskIDMetadataKey
        ] != nil {
            // A monitor turn's text is already the full `<monitor-event …>`
            // wrap — upstream's InjectNotification prompt blocks carry it
            // verbatim (notification_bridge.rs:776-789) — so no framing
            // here; only the `monitor-{task}-{uuid}` prompt-id shape.
            // `from_prompt_id` has no `monitor-` arm upstream
            // (session/mod.rs:103-133), so the turn persists as a plain
            // user item, which is what the port's default mapping does too.
            turnRequest = OpenGrokShellTurnRequest(
                promptID: promptID,
                text: request.prompt
            )
        } else {
            turnRequest = OpenGrokShellTurnRequest(promptID: promptID, text: request.prompt)
        }
        let handle = try await shell.submitTurn(
            sessionID: sessionID,
            request: turnRequest
        )
        return LivePagerSession(shell: shell, handle: handle, shellEvents: shellEvents)
    }

    /// Mirror the live export boundary into the shell session's persisted
    /// summary, the port of the persistence actor's `observe_provider` leg
    /// on a model switch (`PersistenceMsg::CurrentModel`, persistence.rs:
    /// 2179-2187 → `mark_ever_used_codex`).
    ///
    /// Before the first prompt no shell session exists — the port creates it
    /// lazily in `makeSession`, where upstream's `init_session` runs at
    /// session open (persistence.rs:2775) — so there is nothing to mirror
    /// into yet and the sync defers: `makeSession` seeds the record from the
    /// same shared `ExportBoundary` at creation, so the deferred value cannot
    /// be lost. Once a session exists, a failure here is a real persistence
    /// failure and still propagates to the caller's warning row.
    func synchronizeProviderBoundary(everUsedNonXAI: Bool) async throws {
        guard let sessionID = activeShellSessionID else { return }
        try await shell.synchronizeProviderBoundary(
            sessionID: sessionID,
            everUsedNonXAI: everUsedNonXAI
        )
    }

    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        try await makeSession(for: request.sessionRequest)
    }

    func replaceSession(from request: OpenGrokPagerRequest) async throws -> String {
        try await replaceSession(from: request, workingDirectory: nil)
    }

    func replaceSession(
        from request: OpenGrokPagerRequest,
        workingDirectory: String?
    ) async throws -> String {
        _ = request
        await retainActiveRecord()
        let newSessionID = UUID().uuidString
        try LiveConversationStore.validateSessionID(newSessionID)
        let newWorkingDirectory: URL
        if let workingDirectory {
            newWorkingDirectory = URL(
                fileURLWithPath: workingDirectory,
                isDirectory: true
            ).standardizedFileURL
        } else {
            newWorkingDirectory = activeWorkingDirectory
        }
        let record = LiveConversationRecord.new(
            sessionID: newSessionID,
            workingDirectory: newWorkingDirectory,
            sandboxProfile: toolExecutor?.sandbox.profileName
        )
        let configuration = ProviderSessionConfiguration(
            sessionID: newSessionID,
            modelCatalog: providerConfiguration.modelCatalog,
            initialModelID: providerConfiguration.initialModelID,
            credentialBindings: providerConfiguration.credentialBindings,
            fallbackModelIDs: providerConfiguration.fallbackModelIDs,
            auxiliaryModelIDs: providerConfiguration.auxiliaryModelIDs,
            toolRequest: providerConfiguration.toolRequest,
            retryPolicy: providerConfiguration.retryPolicy,
            openGrokHome: providerConfiguration.openGrokHome,
            environment: providerConfiguration.environment,
            everUsedNonXAI: record.everUsedNonXAI
        )

        _ = try await shell.start()
        _ = try await shell.createSession(OpenGrokShellSessionRequest(
            sessionID: SessionID(newSessionID),
            cwd: newWorkingDirectory,
            providerConfiguration: configuration,
            restorePersistedState: false
        ))
        try await conversationStore.save(record)
        try await toolExecutor?.registerSession(
            sessionID: newSessionID,
            workingDirectory: newWorkingDirectory
        )
        try await conversationHistory.replace(with: record)
        let boundary = await conversationHistory.sharedExportBoundary
        registerExportBoundary?(newSessionID, boundary)
        await compaction?.replaceSessionID(newSessionID)
        providerConfiguration = configuration
        createdSessionIDs.insert(SessionID(newSessionID))
        retainedRecords[newSessionID] = record
        activeWorkingDirectory = newWorkingDirectory
        activeShellSessionID = SessionID(newSessionID)
        return newSessionID
    }

    /// `/resume`: swap the live conversation to the stored session
    /// `sessionID`, keeping the current provider stack.
    ///
    /// Ordering mirrors `replaceSession`: the shell session and the persisted
    /// record land before the in-memory spine flips, so a failure partway
    /// leaves the previous session fully live. The restored history is then
    /// reconciled against the route the session is *currently* running
    /// (`reconcileRoute`), which strips provider-opaque carriers when the
    /// stored record came from a different provider — the same isolation
    /// `/model` applies, because a resume across providers is the same seam.
    func resumeSession(sessionID: String) async throws -> String {
        try LiveConversationStore.validateSessionID(sessionID)
        await retainActiveRecord()
        let storedRecord = try await conversationStore.loadIfPresent(sessionID: sessionID)
        guard let record = retainedRecords[sessionID] ?? storedRecord else {
            throw CLIApplicationError.failed("session not found: \(sessionID)")
        }
        let sessionDirectory = URL(
            fileURLWithPath: record.workingDirectory,
            isDirectory: true
        ).standardizedFileURL
        let configuration = ProviderSessionConfiguration(
            sessionID: sessionID,
            modelCatalog: providerConfiguration.modelCatalog,
            initialModelID: providerConfiguration.initialModelID,
            credentialBindings: providerConfiguration.credentialBindings,
            fallbackModelIDs: providerConfiguration.fallbackModelIDs,
            auxiliaryModelIDs: providerConfiguration.auxiliaryModelIDs,
            toolRequest: providerConfiguration.toolRequest,
            retryPolicy: providerConfiguration.retryPolicy,
            openGrokHome: providerConfiguration.openGrokHome,
            environment: providerConfiguration.environment,
            everUsedNonXAI: record.everUsedNonXAI
        )

        _ = try await shell.start()
        let shellSessionID = SessionID(sessionID)
        if !createdSessionIDs.contains(shellSessionID) {
            _ = try await shell.createSession(OpenGrokShellSessionRequest(
                sessionID: shellSessionID,
                cwd: sessionDirectory,
                providerConfiguration: configuration,
                restorePersistedState: true
            ))
            createdSessionIDs.insert(shellSessionID)
        }
        try await conversationStore.save(record)
        try await toolExecutor?.registerSession(
            sessionID: sessionID,
            workingDirectory: sessionDirectory
        )
        try await conversationHistory.replace(with: record)
        let resumedBoundary = await conversationHistory.sharedExportBoundary
        registerExportBoundary?(sessionID, resumedBoundary)
        if let modelSwitch {
            let snapshot = await modelSwitch.snapshot()
            _ = try await conversationHistory.reconcileRoute(
                modelID: snapshot.modelID,
                provider: snapshot.provider
            )
        }
        await compaction?.replaceSessionID(sessionID)
        providerConfiguration = configuration
        retainedRecords[sessionID] = await conversationHistory.snapshot()
        activeWorkingDirectory = sessionDirectory
        activeShellSessionID = shellSessionID
        return sessionID
    }

    func renameRetainedSession(sessionID: String, title: String) async throws -> Bool {
        let activeSessionID = await conversationHistory.sessionID
        if sessionID == activeSessionID {
            try await conversationHistory.rename(title: title)
            retainedRecords[sessionID] = await conversationHistory.snapshot()
            return true
        }
        guard try await conversationStore.renameStored(sessionID: sessionID, title: title) else {
            retainedRecords.removeValue(forKey: sessionID)
            return false
        }
        if var record = retainedRecords[sessionID] {
            record.title = title
            record.updatedAt = Date()
            retainedRecords[sessionID] = record
        }
        return true
    }

    func retainedSessionIDs() -> Set<String> {
        Set(retainedRecords.keys)
    }

    func workingDirectory(sessionID: String) async -> URL? {
        let activeSessionID = await conversationHistory.sessionID
        if sessionID == activeSessionID {
            return activeWorkingDirectory
        }
        if let record = retainedRecords[sessionID] {
            return URL(fileURLWithPath: record.workingDirectory, isDirectory: true)
                .standardizedFileURL
        }
        let storedRecord: LiveConversationRecord?
        do {
            storedRecord = try await conversationStore.loadIfPresent(sessionID: sessionID)
        } catch {
            return nil
        }
        guard let storedRecord else { return nil }
        return URL(
            fileURLWithPath: storedRecord.workingDirectory,
            isDirectory: true
        ).standardizedFileURL
    }

    private func retainActiveRecord() async {
        let record = await conversationHistory.snapshot()
        retainedRecords[record.sessionID] = record
        activeWorkingDirectory = URL(
            fileURLWithPath: record.workingDirectory,
            isDirectory: true
        ).standardizedFileURL
    }
}

final class LivePagerSession: OpenGrokPagerMinimalSessionAdapter, @unchecked Sendable {
    let sessionID: String?
    let events: AsyncThrowingStream<OpenGrokPagerMinimalEvent, Error>

    private let shell: OpenGrokShell
    private let handle: OpenGrokShellTurnHandle
    private let eventTask: Task<Void, Never>

    init(
        shell: OpenGrokShell,
        handle: OpenGrokShellTurnHandle,
        shellEvents: AsyncThrowingStream<OpenGrokShellEvent, Error>
    ) {
        self.shell = shell
        self.handle = handle
        self.sessionID = handle.sessionID.rawValue
        var continuation: AsyncThrowingStream<OpenGrokPagerMinimalEvent, Error>.Continuation!
        self.events = AsyncThrowingStream { continuation = $0 }
        self.eventTask = Task {
            do {
                for try await event in shellEvents {
                    switch event {
                    case .turnUpdate(let update) where update.turnID == handle.turnID:
                        switch update.kind {
                        case .assistantText(let text): continuation.yield(.output(text))
                        case .status(let status): continuation.yield(.status(status))
                        case .tool(let tool):
                            let state: OpenGrokPagerToolState
                            switch tool.state {
                            case .running: state = .running
                            case .succeeded: state = .succeeded
                            case .failed: state = .failed
                            case .cancelled: state = .cancelled
                            }
                            let outputOp: OpenGrokPagerToolOutputOp =
                                tool.outputOp == .append ? .append : .replace
                            continuation.yield(.tool(OpenGrokPagerToolUpdate(
                                callID: tool.callID,
                                name: tool.name,
                                input: tool.input,
                                output: tool.output,
                                structuredOutput: tool.structuredOutput,
                                isBashMode: tool.isBashMode,
                                state: state,
                                outputOp: outputOp
                            )))
                        case .reasoning(let text):
                            continuation.yield(.reasoning(text))
                        case .responseStarted(
                            let messageID, let model, let inputTokens,
                            let cacheReadInputTokens, let cacheCreationInputTokens
                        ):
                            continuation.yield(.responseStarted(
                                messageID: messageID,
                                model: model,
                                inputTokens: inputTokens,
                                cacheReadInputTokens: cacheReadInputTokens,
                                cacheCreationInputTokens: cacheCreationInputTokens
                            ))
                        case .reasoningCompleted(let signature):
                            continuation.yield(.reasoningCompleted(signature: signature))
                        case .toolCallDelta(
                            let toolIndex, let id, let name, let argumentsDelta
                        ):
                            continuation.yield(.toolCallDelta(
                                toolIndex: toolIndex,
                                id: id,
                                name: name,
                                argumentsDelta: argumentsDelta
                            ))
                        case .retrying(
                            let attempt, let maxRetries, let kind, let reason
                        ):
                            continuation.yield(.retrying(
                                attempt: attempt,
                                maxRetries: maxRetries,
                                kind: kind,
                                reason: reason
                            ))
                        case .samplingFailed(
                            let kind, let message, let isRetryable, let statusCode
                        ):
                            continuation.yield(.samplingFailed(
                                kind: kind,
                                message: message,
                                isRetryable: isRetryable,
                                statusCode: statusCode
                            ))
                        case .backendToolStarted(let callID, let name):
                            continuation.yield(.tool(OpenGrokPagerToolUpdate(
                                callID: callID,
                                name: name,
                                input: "",
                                state: .running
                            )))
                        case .backendToolCompleted(let callID, let name, let result):
                            continuation.yield(.tool(OpenGrokPagerToolUpdate(
                                callID: callID,
                                name: name,
                                input: "",
                                output: result,
                                state: .succeeded
                            )))
                        }
                    case .turnCompleted(let result) where result.turnID == handle.turnID:
                        continuation.yield(.responseCompleted(
                            messageID: result.messageID,
                            stopReason: result.rawStopReason ?? result.stopReason,
                            stopSequence: result.stopSequence,
                            inputTokens: result.inputTokens,
                            outputTokens: result.outputTokens,
                            cacheReadInputTokens: result.cacheReadInputTokens,
                            cacheCreationInputTokens: result.cacheCreationInputTokens
                        ))
                        continuation.yield(.completed(OpenGrokPagerMinimalCompletion(
                            sessionID: handle.sessionID.rawValue,
                            summary: result.stopReason,
                            messageID: result.messageID,
                            rawStopReason: result.rawStopReason,
                            stopSequence: result.stopSequence,
                            inputTokens: result.inputTokens,
                            outputTokens: result.outputTokens,
                            cacheReadInputTokens: result.cacheReadInputTokens,
                            cacheCreationInputTokens: result.cacheCreationInputTokens
                        )))
                        continuation.finish()
                        return
                    case .turnCancelled(let cancelled) where cancelled == handle:
                        continuation.yield(.cancelled)
                        continuation.finish()
                        return
                    case .turnFailed(let failed, let message) where failed == handle:
                        continuation.finish(throwing: CLIApplicationError.failed(message))
                        return
                    default:
                        continue
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    func cancel() async {
        eventTask.cancel()
        try? await shell.cancelTurn(handle)
    }

    func close() async {
        eventTask.cancel()
    }
}

actor LiveInteractiveInputResource {
    private let input: any TerminalInput
    private let resizeSource: any TerminalResizeSource
    /// Swapped on suspend/resume: `beginSuspension` releases it (upstream's
    /// `disable_raw_mode`, event_loop.rs:399) and `endSuspension` stores the
    /// fresh lease from re-entry (event_loop.rs:401).
    private var lease: any RawModeLease
    /// The adapter the lease came from, kept for raw re-entry after a child
    /// owned the tty. `nil` in constructions that never suspend.
    private let rawModeTTY: (any TTYAdapter)?
    private var inputTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var closed = false
    private var suspended = false

    init(
        input: any TerminalInput,
        resizeSource: any TerminalResizeSource,
        lease: any RawModeLease,
        rawModeTTY: (any TTYAdapter)? = nil
    ) {
        self.input = input
        self.resizeSource = resizeSource
        self.lease = lease
        self.rawModeTTY = rawModeTTY
    }

    func install(
        inputTask: Task<Void, Never>,
        resizeTask: Task<Void, Never>
    ) {
        self.inputTask = inputTask
        self.resizeTask = resizeTask
    }

    /// Park the reader, then release the raw-mode lease — the input half of
    /// `suspend_for_child` (event_loop.rs:365-371 + :399). Single attempt:
    /// a park timeout changes nothing here and returns `false` for the
    /// caller to report; upstream instead requeues the request on a deferred
    /// retry timer (event_loop.rs:646-671, 700-712). Cost of the divergence:
    /// a reader busy at the wrong 500 ms means the user re-runs the command
    /// rather than it firing later on its own.
    func beginSuspension() async -> Bool {
        guard !closed, !suspended else { return false }
        guard await input.pauseReads() else { return false }
        suspended = true
        await lease.release()
        return true
    }

    /// Re-enter raw mode and swap the lease, then discard the bytes the
    /// terminal buffered while the child ran (DA/DSR replies,
    /// event_loop.rs:407-411), then resume the reader. Raw comes first:
    /// resuming reads into a cooked terminal would hand the user's next
    /// keystrokes to the shell's line discipline.
    func endSuspension() async throws {
        guard suspended else { return }
        if let rawModeTTY {
            // A failed re-entry is a genuinely broken terminal: leave the
            // reader paused and surface the error rather than resuming into
            // a cooked tty silently.
            lease = try await rawModeTTY.enterRawMode()
        }
        suspended = false
        input.discardPendingInput()
        input.resumeReads()
    }

    func close() async {
        guard !closed else { return }
        closed = true
        await input.close()
        resizeSource.stop()
        inputTask?.cancel()
        resizeTask?.cancel()
        if let inputTask {
            _ = await inputTask.value
        }
        if let resizeTask {
            _ = await resizeTask.value
        }
        await lease.release()
    }
}

final class LiveInteractiveInputEmitter: @unchecked Sendable {
    private let continuation: AsyncThrowingStream<InputEvent, Error>.Continuation

    init(continuation: AsyncThrowingStream<InputEvent, Error>.Continuation) {
        self.continuation = continuation
    }

    func yield(_ event: InputEvent) {
        continuation.yield(event)
    }

    func finish(throwing error: Error? = nil) {
        continuation.finish(throwing: error)
    }
}

final class FileHandlePagerTerminalSink: PagerTerminalSink, @unchecked Sendable {
    let capabilities = PagerTerminalCapabilities.standard
    private let handle: FileHandle
    private let lock = NSLock()

    init(handle: FileHandle = .standardOutput) {
        self.handle = handle
    }

    func write(bytes: [UInt8]) throws {
        guard !bytes.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        try handle.write(contentsOf: Data(bytes))
    }

    func flush() throws {
        lock.lock()
        defer { lock.unlock() }
        try handle.synchronize()
    }
}

/// Chrome the live TUI composes for every frame.
///
/// The reference builds its shortcut hints from an action registry
/// (`src/actions/defaults.rs`); this port lists only the bindings the Swift
/// controller actually honors, so the bar never advertises a key that does
/// nothing.
enum LivePagerChrome {
    static func collapseHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    static func shortcutHints(isTurnRunning: Bool) -> [PagerShortcutHint] {
        var hints: [PagerShortcutHint] = [
            // The submit label flips to "queue" while a turn is in flight,
            // matching `views/agent.rs:992`.
            PagerShortcutHint(key: "Enter", label: isTurnRunning ? "queue" : "send", isPinned: true)
        ]
        if isTurnRunning {
            hints.append(PagerShortcutHint(key: "Esc", label: "cancel", isPinned: true))
        } else {
            hints.append(PagerShortcutHint(key: "\u{2191}", label: "history"))
            hints.append(PagerShortcutHint(key: "/", label: "commands"))
        }
        hints.append(PagerShortcutHint(keys: ["PgUp", "PgDn"], label: "scroll"))
        hints.append(PagerShortcutHint(key: "Tab", label: "scrollback"))
        hints.append(PagerShortcutHint(key: "Ctrl+c", label: "quit", isPinned: true))
        return hints
    }

    /// Hints for the scrollback's own focus, mirroring upstream's per-context
    /// bar. The vim-only keys are listed only when vim mode is on, because
    /// with it off they genuinely do nothing.
    static func scrollbackHints(isVimMode: Bool) -> [PagerShortcutHint] {
        var hints: [PagerShortcutHint] = [
            PagerShortcutHint(keys: ["\u{2191}", "\u{2193}"], label: "select", isPinned: true),
            PagerShortcutHint(keys: ["\u{2190}", "\u{2192}"], label: "fold"),
            PagerShortcutHint(key: "Enter", label: "view")
        ]
        if isVimMode {
            hints.append(PagerShortcutHint(keys: ["y", "Y"], label: "copy"))
            hints.append(PagerShortcutHint(key: "r", label: "raw"))
            hints.append(PagerShortcutHint(keys: ["o", "O"], label: "link"))
        }
        hints.append(PagerShortcutHint(key: "Tab", label: "prompt", isPinned: true))
        return hints
    }

    /// Title for the block viewer.
    static func blockTitle(for item: PagerConversationItem) -> String {
        switch item {
        case .message(let message):
            switch message.role {
            case .user: return "Your prompt"
            case .assistant: return "Response"
            case .reasoning: return "Thinking"
            case .system: return "System"
            case .error: return "Error"
            }
        case .tool(let tool):
            return tool.name
        case .block(let block):
            return block.displayTitle
        case .separator:
            return "Separator"
        }
    }

}

struct LivePagerConversationState {
    private(set) var items: [PagerConversationItem] = []
    private var activeAssistantIndex: Int?
    private var activeReasoningIndex: Int?
    private var toolIndicesByCallID: [String: Int] = [:]
    /// Accumulated provisional tool-argument fragments keyed by stream call id.
    /// Never persisted; only hydrates the live card header.
    private var provisionalToolArguments: [String: String] = [:]
    /// Renders assistant messages as markdown for frame painting. `nil` leaves
    /// them as plain text, which is what the inline and transcript paths want.
    private let markdown: PagerMarkdownRenderer?
    private var markdownRenderersByItemIndex: [Int: PagerStreamingMarkdownRenderer] = [:]
    private var markdownWidth: Int?
    private var keepCompletedReasoningExpanded = false
    private var reasoningStartedAt: Date?

    init(markdown: PagerMarkdownRenderer? = nil) {
        self.markdown = markdown
    }

    private func styledLines(for text: String) -> [PagerStyledLine] {
        guard let markdown, !text.isEmpty else { return [] }
        var renderer = markdown.makeStreamingRenderer(maxTableWidth: markdownWidth)
        renderer.pushAndRender(text)
        return renderer.finish()
    }

    private func makeStreamingMarkdownRenderer() -> PagerStreamingMarkdownRenderer? {
        markdown?.makeStreamingRenderer(maxTableWidth: markdownWidth)
    }

    private mutating func appendMarkdown(
        _ text: String,
        at index: Int
    ) -> [PagerStyledLine] {
        guard var renderer = markdownRenderersByItemIndex[index] ?? makeStreamingMarkdownRenderer()
        else { return [] }
        let lines = renderer.pushAndRender(text)
        markdownRenderersByItemIndex[index] = renderer
        return lines
    }

    private mutating func finishMarkdown(at index: Int, fallback text: String) -> [PagerStyledLine] {
        guard var renderer = markdownRenderersByItemIndex[index] else {
            return styledLines(for: text)
        }
        let lines = renderer.finish()
        markdownRenderersByItemIndex[index] = renderer
        return lines
    }

    private mutating func rebuildMarkdownRenderers() {
        markdownRenderersByItemIndex.removeAll(keepingCapacity: true)
        guard markdown != nil else { return }
        for index in items.indices {
            guard case .message(var message) = items[index],
                  message.role == .assistant || message.role == .reasoning,
                  !message.text.isEmpty,
                  var renderer = makeStreamingMarkdownRenderer()
            else { continue }
            renderer.pushAndRender(message.text)
            message.styledLines = renderer.finish()
            items[index] = .message(message)
            markdownRenderersByItemIndex[index] = renderer
        }
    }

    @discardableResult
    mutating func setMarkdownWidth(_ width: Int?) -> Bool {
        let normalized = width.map { max(1, $0) }
        guard markdown != nil, markdownWidth != normalized else { return false }
        markdownWidth = normalized
        for index in markdownRenderersByItemIndex.keys.sorted() {
            guard var renderer = markdownRenderersByItemIndex[index],
                  items.indices.contains(index),
                  case .message(var message) = items[index]
            else { continue }
            message.styledLines = renderer.setMaxTableWidth(normalized)
            items[index] = .message(message)
            markdownRenderersByItemIndex[index] = renderer
        }
        return true
    }

    mutating func setCompletedReasoningExpanded(_ expanded: Bool) {
        keepCompletedReasoningExpanded = expanded
    }

    private mutating func rebuildMarkdownRendererIfNeeded(at index: Int) {
        guard markdown != nil,
              items.indices.contains(index),
              case .message(var message) = items[index],
              message.role == .assistant || message.role == .reasoning,
              !message.text.isEmpty,
              var renderer = makeStreamingMarkdownRenderer()
        else { return }
        let rendered = renderer.pushAndRender(message.text)
        message.styledLines = message.isStreaming ? rendered : renderer.finish()
        items[index] = .message(message)
        markdownRenderersByItemIndex[index] = renderer
    }

    private mutating func removeMarkdownRenderer(at removedIndex: Int) {
        var shifted: [Int: PagerStreamingMarkdownRenderer] = [:]
        shifted.reserveCapacity(markdownRenderersByItemIndex.count)
        for (index, renderer) in markdownRenderersByItemIndex {
            if index < removedIndex {
                shifted[index] = renderer
            } else if index > removedIndex {
                shifted[index - 1] = renderer
            }
        }
        markdownRenderersByItemIndex = shifted
    }

    mutating func startTurn(
        prompt: String,
        promptKind: PagerPromptKind = .standard,
        paintUserBlock: Bool = true
    ) {
        toolIndicesByCallID.removeAll(keepingCapacity: true)
        provisionalToolArguments.removeAll(keepingCapacity: true)
        activeReasoningIndex = nil
        reasoningStartedAt = nil
        // Both blocks carry the construction instant for the `/timestamps`
        // overlay — upstream's `ScrollbackEntry` constructors stamp
        // `created_at: Some(Local::now())` on push (`entry.rs:198,230`).
        //
        // `paintUserBlock: false` is the interjection-fallback turn: the
        // dispatch already painted the text as a user block, so the turn's
        // own echo stays persist-only (interjection.rs:20-25).
        if paintUserBlock {
            items.append(.message(PagerMessage(
                role: .user,
                promptKind: promptKind,
                text: prompt,
                createdAt: Date()
            )))
        }
        items.append(.message(PagerMessage(
            role: .assistant,
            text: "",
            isStreaming: true,
            createdAt: Date()
        )))
        activeAssistantIndex = items.indices.last
        if let activeAssistantIndex,
           let renderer = makeStreamingMarkdownRenderer() {
            markdownRenderersByItemIndex[activeAssistantIndex] = renderer
        }
    }

    mutating func appendMessage(_ message: PagerMessage) {
        items.append(.message(message))
        rebuildMarkdownRendererIfNeeded(at: items.count - 1)
    }

    /// Append any conversation item (including separators). Live-seam tests
    /// use this to inject non-selectable blocks; production paths prefer the
    /// typed appenders above so streaming indices stay coherent.
    mutating func appendItem(_ item: PagerConversationItem) {
        items.append(item)
    }

    mutating func upsertBlock(_ block: PagerTranscriptBlock) {
        if let index = items.firstIndex(where: { item in
            guard case .block(let existing) = item else { return false }
            return existing.stableID == block.stableID
        }) {
            items[index] = .block(block)
        } else {
            items.append(.block(block))
        }
    }

    mutating func attachHooks(_ hooks: [PagerHookRun], toCallID callID: String) {
        guard let index = toolIndicesByCallID[callID],
              items.indices.contains(index),
              case .tool(var tool) = items[index]
        else { return }
        tool.hooks = hooks
        items[index] = .tool(tool)
    }

    mutating func attachStopHooks(_ hooks: [PagerHookRun], toBlockID blockID: String) {
        guard let index = items.firstIndex(where: { item in
            guard case .block(let block) = item else { return false }
            return block.stableID == blockID
        }), case .block(.sessionEvent(var block)) = items[index]
        else { return }
        block.stopHooks = hooks
        items[index] = .block(.sessionEvent(block))
    }

    mutating func removeBlock(id: String) {
        guard let index = items.firstIndex(where: { item in
            guard case .block(let block) = item else { return false }
            return block.stableID == id
        }) else { return }
        items.remove(at: index)
        removeMarkdownRenderer(at: index)
        if let activeAssistantIndex, activeAssistantIndex > index {
            self.activeAssistantIndex = activeAssistantIndex - 1
        }
        if let activeReasoningIndex, activeReasoningIndex > index {
            self.activeReasoningIndex = activeReasoningIndex - 1
        }
        toolIndicesByCallID = toolIndicesByCallID.mapValues { value in
            value > index ? value - 1 : value
        }
    }

    /// Drop everything from `index` on — what `/rewind` does to the visible
    /// transcript once the persisted history has been truncated.
    ///
    /// The streaming bookkeeping is reset rather than adjusted: a rewind can
    /// only run between turns, so there is no active assistant block to keep,
    /// and a stale `activeAssistantIndex` pointing past the new end is exactly
    /// how the next turn would append into the wrong block.
    mutating func truncate(to index: Int) {
        guard index >= 0, index < items.count else { return }
        items.removeSubrange(index...)
        activeAssistantIndex = nil
        activeReasoningIndex = nil
        toolIndicesByCallID.removeAll(keepingCapacity: true)
        provisionalToolArguments.removeAll(keepingCapacity: true)
        reasoningStartedAt = nil
        markdownRenderersByItemIndex = markdownRenderersByItemIndex.filter { $0.key < index }
    }

    mutating func removeAll() {
        items.removeAll()
        activeAssistantIndex = nil
        activeReasoningIndex = nil
        toolIndicesByCallID.removeAll(keepingCapacity: true)
        provisionalToolArguments.removeAll(keepingCapacity: true)
        markdownRenderersByItemIndex.removeAll(keepingCapacity: true)
        reasoningStartedAt = nil
    }

    /// Rebuild the visible transcript from a persisted conversation — what
    /// `/resume` paints after the runtime swaps sessions.
    ///
    /// The projection matches what this renderer would have accumulated live:
    /// real user prompts, assistant prose (markdown-styled), reasoning,
    /// backend tool cards, custom-tool output paired onto calls, and one
    /// settled tool card per assistant tool call with its result attached.
    /// Synthetic user turns and system prompts remain provider/context
    /// plumbing and are not painted.
    ///
    /// `toolOutcomes` is the session sidecar (`LiveConversationRecord.toolOutcomes`);
    /// a missing entry is `.pending` when output is nil, otherwise `.succeeded`.
    /// Never invent success for unpaired calls.
    ///
    /// `promptInstants` carries the persisted instant of each restored user
    /// turn, keyed by POSITIONAL prompt index — turns counted over
    /// `startsPromptTurn` user items, the same rule `liveTruncateConversation`
    /// and the rewind numbering use. The instants come from the session's
    /// rewind sidecar (`LiveRewindPoint.createdAt`, stamped when the turn
    /// opened) — the port of upstream restoring `created_at` from the replay
    /// meta's `turn_start_ms` (`acp/tracker.rs:1380-1385`). Empty means "no
    /// instants known": restored blocks paint no stamp, upstream's
    /// `created_at: None` behavior (`entry_renderer.rs:939`), never load time.
    mutating func seed(
        from conversationItems: [ConversationItem],
        promptInstants: [Int: Date] = [:],
        toolOutcomes: ToolCallOutcomeMap = ToolCallOutcomeMap()
    ) {
        removeAll()
        let projected = LiveTranscriptProjection.project(
            conversationItems,
            promptInstants: promptInstants,
            toolOutcomes: toolOutcomes,
            styleAssistant: { [self] text in self.styledLines(for: text) }
        )
        items = projected.items
        toolIndicesByCallID = projected.toolIndicesByCallID
        rebuildMarkdownRenderers()
    }

    /// In-place edit of the blocks, for the fold/raw effects the scrollback's
    /// selection applies. Deliberately narrow: nothing outside may append or
    /// remove through this, which would desynchronize the streaming indices.
    mutating func withItems<T>(_ body: (inout [PagerConversationItem]) -> T) -> T {
        let countBefore = items.count
        let result = body(&items)
        assert(items.count == countBefore, "scrollback edits must not change the block count")
        return result
    }

    mutating func appendAssistant(_ text: String) {
        finishReasoning()
        guard let activeAssistantIndex,
              items.indices.contains(activeAssistantIndex),
              case .message(var message) = items[activeAssistantIndex]
        else {
            let index = items.count
            items.append(.message(PagerMessage(
                role: .assistant,
                text: text,
                isStreaming: true,
                styledLines: [],
                createdAt: Date()
            )))
            markdownRenderersByItemIndex[index] = makeStreamingMarkdownRenderer()
            if case .message(var created) = items[index] {
                created.styledLines = appendMarkdown(text, at: index)
                items[index] = .message(created)
            }
            self.activeAssistantIndex = index
            return
        }
        message.text += text
        message.isStreaming = true
        message.styledLines = appendMarkdown(text, at: activeAssistantIndex)
        items[activeAssistantIndex] = .message(message)
    }

    mutating func finishAssistant(removingIfEmpty: Bool = false) {
        finishReasoning()
        guard let activeAssistantIndex,
              items.indices.contains(activeAssistantIndex),
              case .message(var message) = items[activeAssistantIndex]
        else { return }
        if removingIfEmpty, message.text.isEmpty {
            items.remove(at: activeAssistantIndex)
            removeMarkdownRenderer(at: activeAssistantIndex)
            self.activeAssistantIndex = nil
            return
        }
        message.isStreaming = false
        message.styledLines = finishMarkdown(at: activeAssistantIndex, fallback: message.text)
        items[activeAssistantIndex] = .message(message)
        self.activeAssistantIndex = nil
    }

    /// Append a reasoning/thought channel delta as a streaming
    /// `PagerMessage(role: .reasoning)`. Painter paints via `appendThinking`.
    mutating func appendReasoning(_ text: String) {
        guard !text.isEmpty else { return }
        guard let activeReasoningIndex,
              items.indices.contains(activeReasoningIndex),
              case .message(var message) = items[activeReasoningIndex],
              message.role == .reasoning
        else {
            // Reasoning interrupts a provisional empty assistant streaming
            // block the same way a tool card does.
            finishAssistant(removingIfEmpty: true)
            items.append(.message(PagerMessage(
                role: .reasoning,
                text: text,
                isStreaming: true,
                styledLines: [],
                createdAt: Date()
            )))
            let index = items.count - 1
            markdownRenderersByItemIndex[index] = makeStreamingMarkdownRenderer()
            if case .message(var created) = items[index] {
                created.styledLines = appendMarkdown(text, at: index)
                items[index] = .message(created)
            }
            reasoningStartedAt = Date()
            self.activeReasoningIndex = index
            return
        }
        message.text += text
        message.isStreaming = true
        message.styledLines = appendMarkdown(text, at: activeReasoningIndex)
        items[activeReasoningIndex] = .message(message)
    }

    mutating func finishReasoning() {
        guard let activeReasoningIndex,
              items.indices.contains(activeReasoningIndex),
              case .message(var message) = items[activeReasoningIndex],
              message.role == .reasoning
        else {
            self.activeReasoningIndex = nil
            return
        }
        message.isStreaming = false
        message.styledLines = finishMarkdown(at: activeReasoningIndex, fallback: message.text)
        if message.duration == nil, let reasoningStartedAt {
            message.duration = max(0, Date().timeIntervalSince(reasoningStartedAt))
        }
        message.isCollapsed = !keepCompletedReasoningExpanded
        items[activeReasoningIndex] = .message(message)
        self.activeReasoningIndex = nil
        reasoningStartedAt = nil
    }

    /// Hydrate a provisional tool card from a sampler tool-call delta.
    /// Partial argument JSON is kept only in memory for the card header —
    /// never executed, never written to history.
    mutating func applyToolCallDelta(
        toolIndex: UInt32,
        id: String?,
        name: String?,
        argumentsDelta: String?
    ) {
        let callID = id ?? "stream-tool-\(toolIndex)"
        if let argumentsDelta, !argumentsDelta.isEmpty {
            provisionalToolArguments[callID, default: ""] += argumentsDelta
        }
        let accumulated = provisionalToolArguments[callID] ?? ""
        let existingName: String?
        if let index = toolIndicesByCallID[callID],
           items.indices.contains(index),
           case .tool(let existing) = items[index] {
            existingName = existing.name
        } else {
            existingName = nil
        }
        let resolvedName = {
            if let name, !name.isEmpty { return name }
            if let existingName, !existingName.isEmpty, existingName != "tool" {
                return existingName
            }
            return "tool"
        }()
        let displayInput = LiveToolCardMerge.displayInput(
            name: resolvedName,
            raw: accumulated
        )
        apply(OpenGrokPagerToolUpdate(
            callID: callID,
            name: resolvedName,
            input: displayInput,
            state: .running
        ))
    }

    /// `atSeconds` is the motion clock's now, used to stamp
    /// `PagerToolCard.finishedAt` the first time a tool reaches a terminal
    /// state — the input to the 400 ms finish flash. `nil` (motion disabled,
    /// transcript paths) renders the block already-static.
    ///
    /// Upsert by call ID (A4/A5/A6): merge sparse name/input, replace-or-keep
    /// output without resetting fold, preserve first `finishedAt` and
    /// existing `detail` unless a richer update supplies replacements.
    mutating func apply(_ tool: OpenGrokPagerToolUpdate, atSeconds seconds: TimeInterval? = nil) {
        finishReasoning()
        let state = Self.renderState(for: tool.state)
        let existing: PagerToolCard?
        if let index = toolIndicesByCallID[tool.callID],
           items.indices.contains(index),
           case .tool(let card) = items[index] {
            existing = card
        } else {
            existing = nil
        }

        let name = LiveToolCardMerge.mergedName(
            incoming: tool.name,
            existing: existing?.name
        )
        let rawInput = LiveToolCardMerge.mergedInput(
            incoming: tool.input,
            existing: existing?.input
        )
        // A5: append progress chunks onto the running body; a nil output
        // keeps the existing tail so expansion is not wiped. Terminal
        // updates default to replace (full promptText).
        let output: String?
        if let incoming = tool.output {
            if tool.outputOp == .append, let previous = existing?.output, !previous.isEmpty {
                output = previous + incoming
            } else {
                output = incoming
            }
        } else {
            output = existing?.output
        }
        let detail = existing?.detail
        let structuredOutput = tool.structuredOutput ?? existing?.structuredOutput
        let isBashMode = tool.isBashMode ?? existing?.isBashMode
        var isExpanded = existing?.isExpanded ?? false
        var isFullyExpanded = existing?.isFullyExpanded ?? false
        if isBashMode == true {
            isExpanded = true
            if state != .running, state != .pending {
                isFullyExpanded = true
            }
        }

        var finishedAt = existing?.finishedAt
        if finishedAt == nil, state != .running, state != .pending {
            // First terminal update wins: a re-delivered terminal state must
            // not restart the flash.
            finishedAt = seconds
        }

        let card = PagerToolCard.make(
            name: name,
            rawInput: rawInput,
            output: output,
            state: state,
            isExpanded: isExpanded,
            isFullyExpanded: isFullyExpanded,
            finishedAt: finishedAt,
            detail: detail,
            isBashMode: isBashMode,
            structuredOutput: structuredOutput
        )
        if let index = toolIndicesByCallID[tool.callID], items.indices.contains(index) {
            items[index] = .tool(card)
        } else {
            finishAssistant(removingIfEmpty: true)
            items.append(.tool(card))
            toolIndicesByCallID[tool.callID] = items.indices.last
        }
        if state != .running {
            provisionalToolArguments.removeValue(forKey: tool.callID)
            mergeAdjacentEditCardIfNeeded(callID: tool.callID)
        }
    }

    /// Apply a file-scoped syntax result only if the call still resolves to
    /// the same visible edit card. A stale/latest-loses worker result simply
    /// returns false and never mutates a newer card.
    @discardableResult
    mutating func applyEditHighlights(
        callID: String,
        files highlightedFiles: [PagerEditFile]
    ) -> Bool {
        guard let index = toolIndicesByCallID[callID],
              items.indices.contains(index),
              case .tool(var card) = items[index],
              card.kind == .edit || card.kind == .create
        else { return false }
        let highlightsByPath = Dictionary(uniqueKeysWithValues: highlightedFiles.map {
            ($0.path, $0.highlights)
        })
        guard !highlightsByPath.isEmpty else { return false }
        var files = card.editFiles ?? card.editHunks.map {
            [PagerEditFile(
                path: card.editPath ?? card.input,
                hunks: $0,
                isNewFile: card.isNewFileForEdit ?? false
            )]
        } ?? []
        var changed = false
        for fileIndex in files.indices {
            guard let highlights = highlightsByPath[files[fileIndex].path] else { continue }
            files[fileIndex].highlights = highlights
            changed = true
        }
        guard changed else { return false }
        card.editFiles = files
        card.editHunks = files.first?.hunks
        items[index] = .tool(card)
        return true
    }

    private mutating func mergeAdjacentEditCardIfNeeded(callID: String) {
        guard let index = toolIndicesByCallID[callID], index > 0,
              items.indices.contains(index),
              case .tool(let current) = items[index],
              current.state != .running, current.state != .pending,
              let currentFile = Self.singleEditFile(current),
              case .tool(var previous) = items[index - 1],
              previous.state != .running, previous.state != .pending,
              let previousFile = Self.singleEditFile(previous),
              Self.normalizedEditPath(previousFile.path) == Self.normalizedEditPath(currentFile.path)
        else { return }

        let mergedFile = PagerEditFile(
            path: currentFile.path,
            hunks: stitchOverlappingHunks(previousFile.hunks + currentFile.hunks),
            isNewFile: previousFile.isNewFile && currentFile.isNewFile,
            highlights: currentFile.highlights.isEmpty
                ? previousFile.highlights
                : currentFile.highlights
        )
        previous.editFiles = [mergedFile]
        previous.editPath = mergedFile.path
        previous.editHunks = mergedFile.hunks
        previous.isNewFileForEdit = mergedFile.isNewFile
        previous.kind = mergedFile.isNewFile ? .create : .edit
        previous.editLinesAdded = Self.sum(previous.editLinesAdded, current.editLinesAdded)
        previous.editLinesRemoved = Self.sum(previous.editLinesRemoved, current.editLinesRemoved)
        previous.editCount = Self.sum(previous.editCount, current.editCount)
        previous.editIsTrusted = previous.editIsTrusted == true && current.editIsTrusted == true
        previous.output = current.output ?? previous.output
        previous.state = current.state
        previous.finishedAt = current.finishedAt ?? previous.finishedAt
        previous.isExpanded = previous.isExpanded || current.isExpanded
        previous.structuredOutput = current.structuredOutput ?? previous.structuredOutput
        items[index - 1] = .tool(previous)
        items.remove(at: index)
        removeMarkdownRenderer(at: index)

        for (mappedCallID, mappedIndex) in toolIndicesByCallID {
            if mappedIndex == index {
                toolIndicesByCallID[mappedCallID] = index - 1
            } else if mappedIndex > index {
                toolIndicesByCallID[mappedCallID] = mappedIndex - 1
            }
        }
    }

    private static func singleEditFile(_ card: PagerToolCard) -> PagerEditFile? {
        guard card.kind == .edit || card.kind == .create else { return nil }
        if let files = card.editFiles {
            return files.count == 1 ? files[0] : nil
        }
        guard let hunks = card.editHunks else { return nil }
        return PagerEditFile(
            path: card.editPath ?? card.input,
            hunks: hunks,
            isNewFile: card.isNewFileForEdit ?? false
        )
    }

    private static func normalizedEditPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func sum(_ lhs: Int?, _ rhs: Int?) -> Int? {
        guard lhs != nil || rhs != nil else { return nil }
        return (lhs ?? 0) + (rhs ?? 0)
    }

    /// Narrow test probe: tool card by call id.
    func testingToolCard(callID: String) -> PagerToolCard? {
        guard let index = toolIndicesByCallID[callID],
              items.indices.contains(index),
              case .tool(let tool) = items[index]
        else { return nil }
        return tool
    }

    var transcript: String {
        let lines = items.flatMap(Self.transcriptLines(for:))
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    /// Narrow test probe: the motion-clock stamp on a tool card, when known.
    func testingFinishedAt(callID: String) -> TimeInterval? {
        guard let index = toolIndicesByCallID[callID],
              items.indices.contains(index),
              case .tool(let tool) = items[index]
        else { return nil }
        return tool.finishedAt
    }

    static func transcript(for tool: OpenGrokPagerToolUpdate) -> String {
        transcriptLines(for: .tool(PagerToolCard.make(
            name: tool.name,
            rawInput: tool.input,
            output: tool.output,
            state: renderState(for: tool.state)
        ))).joined(separator: "\n") + "\n"
    }

    private static func renderState(for state: OpenGrokPagerToolState) -> PagerToolState {
        switch state {
        case .running: return .running
        case .succeeded: return .succeeded
        case .failed: return .failed
        case .cancelled: return .cancelled
        }
    }

    /// The plain transcript replayed to the real terminal after the alt-screen
    /// is torn down. This is deliberately *not* the on-screen presentation: it
    /// is a labeled plain-text log that other composition paths and their
    /// tests share.
    private static func transcriptLines(for item: PagerConversationItem) -> [String] {
        switch item {
        case .message(let message):
            let label: String
            switch message.role {
            case .user: label = "You"
            case .assistant: label = "Grok"
            case .system: label = "System"
            case .reasoning: label = "Reasoning"
            case .error: label = "Error"
            }
            return ["\(label): \(message.text)"]
        case .tool(let tool):
            var lines = ["Tool \(tool.name) [\(transcriptState(tool.state))]"]
            if !tool.input.isEmpty {
                lines.append("  input: \(tool.input)")
            }
            if let output = tool.output, !output.isEmpty {
                lines.append("  result: \(output)")
            }
            return lines
        case .block(let block):
            let content = block.plainText
            return content.isEmpty ? [block.displayTitle] : content.components(separatedBy: "\n")
        case .separator(let text):
            return [text]
        }
    }

    private static func transcriptState(_ state: PagerToolState) -> String {
        switch state {
        case .pending: return "pending"
        case .running: return "running"
        case .succeeded: return "done"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        }
    }
}

/// Shared seed/resume projection for live conversation state and dashboard peek.
enum LiveTranscriptProjection {
    struct Result: Sendable {
        var items: [PagerConversationItem]
        var toolIndicesByCallID: [String: Int]
    }

    static func project(
        _ conversationItems: [ConversationItem],
        promptInstants: [Int: Date] = [:],
        toolOutcomes: ToolCallOutcomeMap = ToolCallOutcomeMap(),
        styleAssistant: (String) -> [PagerStyledLine] = { _ in [] }
    ) -> Result {
        var resultsByCallID: [String: String] = [:]
        var customOutputsByCallID: [String: String] = [:]
        for item in conversationItems {
            switch item {
            case .toolResult(let result):
                resultsByCallID[result.toolCallId] = result.content
            case .customToolOutput(let output):
                if let text = customOutputText(output) {
                    customOutputsByCallID[output.callId] = text
                }
            default:
                continue
            }
        }

        var items: [PagerConversationItem] = []
        var toolIndicesByCallID: [String: Int] = [:]
        var promptCount = 0

        for item in conversationItems {
            switch item {
            case .user(let user):
                // Count EVERY turn-starting user item — synthetic
                // turn-starters (scheduler fires, drains) spend a prompt slot
                // in the rewind numbering even though they are not painted.
                let startsTurn = user.syntheticReason.map(\.startsPromptTurn) ?? true
                let promptIndex = promptCount
                if startsTurn { promptCount += 1 }
                guard user.syntheticReason == nil else { continue }
                let text = user.content.compactMap { part -> String? in
                    if case .text(let value) = part { return value }
                    return nil
                }.joined(separator: "\n")
                guard !text.isEmpty else { continue }
                items.append(.message(PagerMessage(
                    role: .user,
                    text: text,
                    createdAt: promptInstants[promptIndex]
                )))
            case .assistant(let assistant):
                let text = assistant.content
                if !text.isEmpty {
                    // RECORDED DIVERGENCE: restored assistant blocks carry no
                    // instant. Upstream replays them with the original
                    // `agentTimestampMs` from its notification journal
                    // (`acp/tracker.rs:950-955`); this port's session store
                    // persists no per-assistant-item instant, so the honest
                    // projection paints no stamp (upstream's `created_at:
                    // None` gate) rather than a load-time or turn-start lie.
                    items.append(.message(PagerMessage(
                        role: .assistant,
                        text: text,
                        styledLines: styleAssistant(text)
                    )))
                }
                for call in assistant.toolCalls {
                    let output = resultsByCallID[call.id] ?? customOutputsByCallID[call.id]
                    let state = seedToolState(
                        callID: call.id,
                        output: output,
                        outcomes: toolOutcomes
                    )
                    let detail = toolOutcomes.record(for: call.id)?.detail
                    items.append(.tool(PagerToolCard.make(
                        name: call.name,
                        rawInput: call.arguments,
                        output: output,
                        state: state,
                        detail: detail
                    )))
                    toolIndicesByCallID[call.id] = items.indices.last
                }
            case .reasoning(let reasoning):
                let text = reasoningText(reasoning)
                guard !text.isEmpty else { continue }
                items.append(.message(PagerMessage(
                    role: .reasoning,
                    text: text,
                    isCollapsed: true
                )))
            case .backendToolCall(let call):
                let callID = call.id
                let name = backendToolName(call)
                let output = resultsByCallID[callID] ?? customOutputsByCallID[callID]
                let state = seedToolState(
                    callID: callID,
                    output: output,
                    outcomes: toolOutcomes
                )
                items.append(.tool(PagerToolCard.make(
                    name: name,
                    rawInput: call.textSummary(),
                    output: output,
                    state: state,
                    detail: toolOutcomes.record(for: callID)?.detail
                )))
                toolIndicesByCallID[callID] = items.indices.last
            case .customToolOutput(let output):
                // Pair onto the matching call when an earlier card exists;
                // otherwise project a standalone card so custom output is not
                // dropped.
                let text = customOutputText(output)
                if let index = toolIndicesByCallID[output.callId],
                   items.indices.contains(index),
                   case .tool(var card) = items[index] {
                    if card.output == nil || card.output?.isEmpty == true {
                        card.output = text
                    }
                    if card.state == .pending, text != nil {
                        card.state = pagerState(
                            for: toolOutcomes.outcome(for: output.callId) ?? .succeeded
                        )
                    }
                    items[index] = .tool(card)
                } else {
                    let state = seedToolState(
                        callID: output.callId,
                        output: text,
                        outcomes: toolOutcomes
                    )
                    items.append(.tool(PagerToolCard.make(
                        name: output.name ?? "custom_tool",
                        rawInput: "",
                        output: text,
                        state: state,
                        detail: toolOutcomes.record(for: output.callId)?.detail
                    )))
                    toolIndicesByCallID[output.callId] = items.indices.last
                }
            case .system, .toolResult:
                continue
            }
        }
        return Result(items: items, toolIndicesByCallID: toolIndicesByCallID)
    }

    /// Missing outcome → `.pending` when unpaired, `.succeeded` when a result
    /// body exists. Never sniff prompt text for the word "failed".
    static func seedToolState(
        callID: String,
        output: String?,
        outcomes: ToolCallOutcomeMap
    ) -> PagerToolState {
        if let outcome = outcomes.outcome(for: callID) {
            return pagerState(for: outcome)
        }
        if output == nil {
            return .pending
        }
        return .succeeded
    }

    static func pagerState(for outcome: ToolCallDisplayOutcome) -> PagerToolState {
        switch outcome {
        case .succeeded: return .succeeded
        case .failed, .denied: return .failed
        case .cancelled: return .cancelled
        case .pending: return .pending
        }
    }

    private static func reasoningText(_ reasoning: ReasoningItem) -> String {
        if let content = reasoning.content, !content.isEmpty {
            let joined = content.map(\.text).joined()
            if !joined.isEmpty { return joined }
        }
        return reasoning.summary.map(\.text).joined(separator: "\n")
    }

    private static func customOutputText(_ output: CustomToolOutputItem) -> String? {
        let parts = output.content.compactMap { part -> String? in
            switch part {
            case .text(let text): return text
            case .image: return nil
            }
        }
        let joined = parts.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    private static func backendToolName(_ call: BackendToolCallItem) -> String {
        switch call.kind {
        case .webSearch: return "web_search"
        case .xSearch: return "x_search"
        case .codeInterpreter: return "code_interpreter"
        case .codexRawInput: return "backend_tool"
        }
    }
}

/// Sparse merge + header extraction for live tool-card upserts (A4/A6).
enum LiveToolCardMerge {
    static func isSparseName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "tool"
    }

    static func isSparseInput(_ input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "{}" || trimmed == "null" || trimmed == "nil"
    }

    static func mergedName(incoming: String, existing: String?) -> String {
        if !isSparseName(incoming) { return incoming }
        if let existing, !isSparseName(existing) { return existing }
        return isSparseName(incoming) ? (existing ?? incoming) : incoming
    }

    static func mergedInput(incoming: String, existing: String?) -> String {
        if !isSparseInput(incoming) { return incoming }
        if let existing, !isSparseInput(existing) { return existing }
        return incoming
    }

    /// Prefer path/command/query fields from JSON tool arguments over raw JSON
    /// when WAVE-A-MODEL factory glue is not yet landed.
    static func displayInput(name: String, raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "{}" else { return raw }
        guard let data = trimmed.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = value.objectValue
        else {
            return raw
        }

        let kind = PagerToolKind.infer(fromToolNamed: name)
        switch kind {
        case .execute:
            if case .string(let command) = object["command"], !command.isEmpty {
                return command
            }
        case .read, .edit, .create, .list:
            for key in ["file_path", "filePath", "target_file", "path"] {
                if case .string(let path) = object[key], !path.isEmpty {
                    return path
                }
            }
        case .search, .webSearch, .xSearch, .memorySearch, .integrationSearch:
            for key in ["query", "pattern", "glob"] {
                if case .string(let query) = object[key], !query.isEmpty {
                    return query
                }
            }
        case .fetch:
            if case .string(let url) = object["url"], !url.isEmpty {
                return url
            }
        case .useTool:
            for key in ["tool_name", "toolName", "name"] {
                if case .string(let toolName) = object[key], !toolName.isEmpty {
                    return toolName
                }
            }
        case .skill:
            for key in ["skill", "skill_name", "name"] {
                if case .string(let skill) = object[key], !skill.isEmpty {
                    return skill
                }
            }
        case .generic:
            for key in ["command", "file_path", "filePath", "target_file", "path", "query", "url"] {
                if case .string(let value) = object[key], !value.isEmpty {
                    return value
                }
            }
        }
        return raw
    }
}

// Internal (not private) so the reachability suites can drive the real
// adapter: a command's overlay/effect only exists here, and a test that
// cannot construct the renderer can only test the registry.
struct LiveDashboardRendererSnapshot: Sendable, Equatable {
    let isOpen: Bool
    let searchQuery: String?
    let selectedRowID: String?
    let cachedSessionIDs: Set<String>
    let dormantSessionIDs: Set<String>
    let inputText: String
    let dispatchWorkingDirectory: String
    let rowLabels: [String: String]
}

enum LiveDashboardInputMode: Sendable, Equatable {
    case compose(rowID: String)
    case rename(rowID: String)
    case worktree(prompt: String)
}

struct LiveDashboardQuestionSnapshot: Sendable, Equatable {
    let overlayID: String
    let requestID: String
    let prompt: String
    let options: [String]
    let selectedIndex: Int
    let freeformText: String
    let freeformFocused: Bool
    let requiresAttach: Bool
}

/// Installs / retires the shared `LiveActiveBackgroundWorkSink` on every
/// lifecycle source a live composition owns. Absent sources are skipped —
/// never stubbed. Scheduler and workflow installs reseed currently-visible
/// ids; shell/monitor share one `.shell` composition path.
enum LiveActiveBackgroundWorkWiring {
    static func install(
        sink: @escaping LiveActiveBackgroundWorkSink,
        toolExecutor: LiveToolExecutor,
        workflowRegistry: RhaiWorkflowRunRegistry?
    ) async {
        await toolExecutor.setActiveBackgroundWorkSink(sink)
        if let subagentHost = toolExecutor.subagentHost {
            await subagentHost.setActiveBackgroundWorkSink(sink)
        }
        if let schedulerHost = toolExecutor.schedulerHost {
            await schedulerHost.setActiveBackgroundWorkSink(sink)
        }
        if let workflowRegistry {
            await LiveWorkflowActiveBackgroundWork.setActiveBackgroundWorkSink(
                on: workflowRegistry,
                sink
            )
        }
    }

    /// Clear host sinks so late lifecycle edges cannot reach a restored
    /// renderer. Does not emit removes — the renderer clears its cache and
    /// publishes final motion during `restoreTerminal`.
    static func clear(
        toolExecutor: LiveToolExecutor,
        workflowRegistry: RhaiWorkflowRunRegistry?
    ) async {
        await toolExecutor.setActiveBackgroundWorkSink(nil)
        if let subagentHost = toolExecutor.subagentHost {
            await subagentHost.setActiveBackgroundWorkSink(nil)
        }
        if let schedulerHost = toolExecutor.schedulerHost {
            await schedulerHost.setActiveBackgroundWorkSink(nil)
        }
        if let workflowRegistry {
            await LiveWorkflowActiveBackgroundWork.setActiveBackgroundWorkSink(
                on: workflowRegistry,
                nil
            )
        }
    }
}


struct SilentLiveInteractiveOutput: OpenGrokPagerInteractiveOutputAdapter, Sendable {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws {
        _ = event
    }
}

struct PlainLivePagerRenderer: OpenGrokPagerMinimalRenderAdapter, Sendable {
    func begin() async throws {}
    func render(_ event: OpenGrokPagerMinimalEvent) async throws {}
    func restoreTerminal() async throws {}
}

struct LiveInteractiveFrontendFactory: OpenGrokPagerFrontendFactory, Sendable {
    let terminal: OpenGrokLiveTerminal
    let prompt: String

    func makeFrontend(for mode: OpenGrokPagerMode) async throws -> any OpenGrokPagerFrontend {
        // `--minimal` degrades here rather than refusing. This factory serves
        // the path with no interactive input, which `resolveInteractivePagerMode`
        // cannot see — it only knows whether a TTY exists, so a TTY with no
        // input sink still arrives as `.minimal`. Refusing produced
        // "unsupported: interactive pager mode minimal" where the flag used to
        // work. Inline is a faithful downgrade: minimal is scrollback-native,
        // and `LiveInteractivePagerRenderer` already renders every
        // non-fullscreen mode as inline. `.plain` has no interactive rendering
        // at all, so it keeps refusing.
        let resolved: OpenGrokPagerMode
        switch mode {
        case .fullScreen, .inline:
            resolved = mode
        case .minimal:
            resolved = .inline
        case .plain:
            throw CLIApplicationError.unsupported(route: "interactive pager mode \(mode.rawValue)")
        }
        return OpenGrokPagerForwardingFrontend(
            renderer: LiveInteractivePagerRenderer(mode: resolved, terminal: terminal, prompt: prompt),
            output: SilentLivePagerOutput()
        )
    }
}

actor LiveInteractivePagerRenderer: OpenGrokPagerRenderAdapter {
    private let mode: OpenGrokPagerMode
    private let terminal: OpenGrokLiveTerminal
    private let prompt: String
    private let renderEngine = PagerRenderEngine()

    private var conversation: LivePagerConversationState
    private var output = ""
    private var status = "Starting"
    private var inlineBegan = false
    private var inlineEnded = false
    private var inlineNeedsAssistantPrefix = false
    private var restored = false
    private var renderTick = 0

    init(mode: OpenGrokPagerMode, terminal: OpenGrokLiveTerminal, prompt: String) {
        self.mode = mode
        self.terminal = terminal
        self.prompt = prompt
        // Inline mode streams raw text straight to the terminal and only uses
        // the conversation state for its plain transcript, so markdown is
        // rendered for the full-screen frame path only.
        conversation = LivePagerConversationState(
            markdown: mode == .fullScreen ? PagerMarkdownRenderer() : nil
        )
        conversation.startTurn(prompt: prompt)
    }

    func begin() async throws {
        switch mode {
        case .fullScreen:
            try await terminal.write("\u{1B}[?1049h\u{1B}[?25l")
            try await renderFullScreen()
        case .inline:
            inlineBegan = true
            try await terminal.write("You: \(prompt)\nGrok: ")
        case .minimal, .plain:
            throw CLIApplicationError.unsupported(route: "interactive pager mode \(mode.rawValue)")
        }
    }

    func render(_ event: OpenGrokPagerEvent) async throws {
        switch event {
        case .lifecycle(.starting):
            status = "Starting"
        case .lifecycle(.running):
            status = "Thinking"
        case .lifecycle(let lifecycle):
            status = lifecycle.rawValue
        case .output(let text):
            output += text
            conversation.appendAssistant(text)
            status = "Responding"
            if mode == .inline {
                if inlineNeedsAssistantPrefix {
                    inlineNeedsAssistantPrefix = false
                    try await terminal.write("Grok: ")
                }
                try await terminal.write(text)
            }
        case .status(let value):
            status = value
        case .tool(let tool):
            conversation.apply(tool)
            status = "Tool \(tool.name) \(tool.state.rawValue)"
            if mode == .inline, tool.state != .running {
                try await terminal.write("\n")
                try await terminal.write(LivePagerConversationState.transcript(for: tool))
                inlineNeedsAssistantPrefix = true
            }
        case .reasoning(let text):
            conversation.appendReasoning(text)
            status = "Thinking"
        case .toolCallDelta(let toolIndex, let id, let name, let argumentsDelta):
            conversation.applyToolCallDelta(
                toolIndex: toolIndex,
                id: id,
                name: name,
                argumentsDelta: argumentsDelta
            )
            status = "Preparing tool"
        case .retrying(let attempt, let maxRetries, _, let reason):
            status = "Retrying (\(attempt)/\(maxRetries)): \(reason)"
        case .samplingFailed(let kind, let message, _, _):
            status = "Failed (\(kind)): \(message)"
        case .permissionRequested(let request):
            status = "Permission required: \(request.prompt)"
        case .responseStarted, .reasoningCompleted, .responseCompleted:
            break
        case .completed:
            conversation.finishAssistant()
            status = "Completed"
            if mode == .inline {
                try await finishInline()
            }
        case .cancelled:
            conversation.finishAssistant()
            status = "Cancelled"
            if mode == .inline {
                try await finishInline()
            }
        }
        if mode == .fullScreen {
            try await renderFullScreen()
        }
    }

    func restoreTerminal() async throws {
        guard !restored else { return }
        restored = true
        switch mode {
        case .fullScreen:
            try await terminal.write(TerminalRestore.fullRestore)
            try await terminal.write(finalTranscript)
        case .inline:
            try await finishInline()
        case .minimal, .plain:
            break
        }
    }

    private func renderFullScreen() async throws {
        renderTick += 1
        let terminalSize = terminal.size() ?? OpenGrokLiveTerminalSize(width: 80, height: 24)
        var result = renderEngine.render(PagerRenderState(
            size: OpenGrokTerminalCore.TerminalSize(
                width: terminalSize.width,
                height: terminalSize.height
            ),
            statusBar: PagerStatusBar(
                workingDirectory: LivePagerChrome.collapseHome(
                    FileManager.default.currentDirectoryPath
                )
            ),
            conversation: conversation.items,
            turnStatus: PagerTurnStatus(label: status, tick: renderTick),
            input: PagerComposerState(
                text: "",
                isFocused: false,
                cursorVisible: false,
                placeholder: "",
                maximumHeight: 3
            ),
            shortcuts: PagerShortcutsBar(
                hints: [PagerShortcutHint(key: "Ctrl+c", label: "cancel", isPinned: true)]
            ),
            groupToolVerbs: true
        ))
        if conversation.setMarkdownWidth(result.layout.contentWidth) {
            result = renderEngine.render(PagerRenderState(
                size: OpenGrokTerminalCore.TerminalSize(
                    width: terminalSize.width,
                    height: terminalSize.height
                ),
                statusBar: PagerStatusBar(
                    workingDirectory: LivePagerChrome.collapseHome(
                        FileManager.default.currentDirectoryPath
                    )
                ),
                conversation: conversation.items,
                turnStatus: PagerTurnStatus(label: status, tick: renderTick),
                input: PagerComposerState(
                    text: "",
                    isFocused: false,
                    cursorVisible: false,
                    placeholder: "",
                    maximumHeight: 3
                ),
                shortcuts: PagerShortcutsBar(
                    hints: [PagerShortcutHint(key: "Ctrl+c", label: "cancel", isPinned: true)]
                ),
                groupToolVerbs: true
            ))
            if conversation.setMarkdownWidth(result.layout.contentWidth) {
                result = renderEngine.render(PagerRenderState(
                    size: OpenGrokTerminalCore.TerminalSize(
                        width: terminalSize.width,
                        height: terminalSize.height
                    ),
                    statusBar: PagerStatusBar(
                        workingDirectory: LivePagerChrome.collapseHome(
                            FileManager.default.currentDirectoryPath
                        )
                    ),
                    conversation: conversation.items,
                    turnStatus: PagerTurnStatus(label: status, tick: renderTick),
                    input: PagerComposerState(
                        text: "",
                        isFocused: false,
                        cursorVisible: false,
                        placeholder: "",
                        maximumHeight: 3
                    ),
                    shortcuts: PagerShortcutsBar(
                        hints: [PagerShortcutHint(key: "Ctrl+c", label: "cancel", isPinned: true)]
                    ),
                    groupToolVerbs: true
                ))
            }
        }
        let frame = ANSIOutput.beginSynchronizedUpdate
            + ANSIOutput.moveTo(column: 0, row: 0)
            + result.snapshot(includeTrailingSpaces: true)
            + ANSIOutput.clearFromCursorDown
            + ANSIOutput.endSynchronizedUpdate
        try await terminal.write(frame)
    }

    private func finishInline() async throws {
        guard inlineBegan, !inlineEnded else { return }
        inlineEnded = true
        if !output.hasSuffix("\n") {
            try await terminal.write("\n")
        }
    }

    private var finalTranscript: String {
        conversation.transcript
    }
}

struct SilentLivePagerOutput: OpenGrokPagerOutputAdapter, Sendable {
    func forward(_ event: OpenGrokPagerEvent) async throws {}
}

actor LivePagerOutput: OpenGrokPagerMinimalOutputAdapter {
    private let streams: CLIStreams
    private let format: CLIOutputFormat
    private var nativeMessages: NativeMessagesOutputReducer?
    private var collectedOutput = ""
    private var wrotePlainOutput = false

    init(
        streams: CLIStreams,
        format: CLIOutputFormat,
        includePartialMessages: Bool = false,
        sessionID: String? = nil,
        model: String? = nil,
        workingDirectory: String? = nil,
        tools: [String] = [],
        slashCommands: [String] = [],
        skills: [String] = [],
        permissionMode: String? = nil,
        apiKeySource: String = "user"
    ) {
        self.streams = streams
        self.format = format
        if format == .streamingMessagesJSON {
            self.nativeMessages = NativeMessagesOutputReducer(
                sessionID: sessionID ?? "",
                model: model,
                workingDirectory: workingDirectory ?? "",
                includePartialMessages: includePartialMessages,
                tools: tools,
                slashCommands: slashCommands,
                skills: skills,
                permissionMode: permissionMode,
                apiKeySource: apiKeySource
            )
        }
    }

    func forward(_ event: OpenGrokPagerMinimalEvent) async throws {
        switch format {
        case .plain:
            forwardPlain(event)
        case .json:
            try forwardJSON(event)
        case .streamingJSON:
            try forwardStreamingJSON(event)
        case .streamingMessagesJSON:
            guard var reducer = nativeMessages else { return }
            let lines = reducer.reduce(event)
            nativeMessages = reducer
            for line in lines {
                streams.out(try Self.jsonLine(line))
            }
        }
    }

    private func forwardPlain(_ event: OpenGrokPagerMinimalEvent) {
        switch event {
        case .output(let text):
            collectedOutput += text
            wrotePlainOutput = true
            streams.out(text)
        case .completed:
            if wrotePlainOutput, !collectedOutput.hasSuffix("\n") {
                streams.out("\n")
            }
        case .status(let status):
            streams.err("open-grok: \(status)\n")
        case .permissionRequested(let request):
            streams.err("open-grok: permission required: \(request.prompt)\n")
        case .cancelled:
            streams.err("open-grok: cancelled\n")
        case .reasoning(let text):
            streams.err("open-grok: reasoning: \(text)\n")
        case .retrying(let attempt, let maxRetries, _, let reason):
            streams.err("open-grok: retry \(attempt)/\(maxRetries): \(reason)\n")
        case .samplingFailed(let kind, let message, _, _):
            streams.err("open-grok: failed (\(kind)): \(message)\n")
        case .lifecycle, .tool, .toolCallDelta, .responseStarted,
             .reasoningCompleted, .responseCompleted:
            break
        }
    }

    private func forwardJSON(_ event: OpenGrokPagerMinimalEvent) throws {
        switch event {
        case .output(let text):
            collectedOutput += text
        case .completed(let completion):
            streams.out(try Self.jsonLine([
                "type": "completed",
                "session_id": completion.sessionID as Any,
                "output": collectedOutput,
                "summary": completion.summary as Any
            ]))
        case .cancelled:
            streams.out(try Self.jsonLine(["type": "cancelled"]))
        case .reasoning(let text):
            collectedOutput += text
        case .samplingFailed(let kind, let message, let isRetryable, let statusCode):
            streams.out(try Self.jsonLine([
                "type": "failed",
                "kind": kind,
                "message": message,
                "is_retryable": isRetryable,
                "status_code": statusCode as Any
            ]))
        case .lifecycle, .status, .tool, .toolCallDelta, .retrying,
             .permissionRequested, .responseStarted, .reasoningCompleted,
             .responseCompleted:
            break
        }
    }

    private func forwardStreamingJSON(_ event: OpenGrokPagerMinimalEvent) throws {
        switch event {
        case .output(let text):
            collectedOutput += text
            streams.out(try Self.jsonLine([
                "type": "output",
                "content": text
            ]))
        case .status(let status):
            streams.out(try Self.jsonLine(["type": "status", "status": status]))
        case .tool(let tool):
            streams.out(try Self.jsonLine([
                "type": "tool",
                "call_id": tool.callID,
                "name": tool.name,
                "input": tool.input,
                "output": tool.output as Any,
                "state": tool.state.rawValue
            ]))
        case .reasoning(let text):
            streams.out(try Self.jsonLine(["type": "reasoning", "content": text]))
        case .retrying(let attempt, let maxRetries, let kind, let reason):
            streams.out(try Self.jsonLine([
                "type": "retrying",
                "attempt": attempt,
                "max_retries": maxRetries,
                "kind": kind,
                "reason": reason
            ]))
        case .samplingFailed(let kind, let message, let isRetryable, let statusCode):
            streams.out(try Self.jsonLine([
                "type": "failed",
                "kind": kind,
                "message": message,
                "is_retryable": isRetryable,
                "status_code": statusCode as Any
            ]))
        case .completed(let completion):
            streams.out(try Self.jsonLine([
                "type": "completed",
                "session_id": completion.sessionID as Any,
                "summary": completion.summary as Any
            ]))
        case .cancelled:
            streams.out(try Self.jsonLine(["type": "cancelled"]))
        case .permissionRequested(let request):
            streams.out(try Self.jsonLine([
                "type": "permission_requested",
                "id": request.id,
                "prompt": request.prompt
            ]))
        case .lifecycle, .toolCallDelta, .responseStarted, .reasoningCompleted,
             .responseCompleted:
            break
        }
    }

    private static func jsonLine(_ object: [String: Any]) throws -> String {
        let normalized = object.compactMapValues { value -> Any? in
            if value is NSNull { return value }
            let mirror = Mirror(reflecting: value)
            if mirror.displayStyle == .optional {
                return mirror.children.first?.value ?? NSNull()
            }
            return value
        }
        let data = try JSONSerialization.data(
            withJSONObject: normalized,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}

/// Native Messages API NDJSON frames; upstream keeps this reducer independent
/// from `streaming-json` because flattening deltas destroys response identity,
/// ordered content blocks, tool-result pairing, and prompt-cache accounting.
private struct NativeMessagesOutputReducer {
    private enum TextKind { case text, thinking }

    private struct Usage {
        var inputTokens: UInt64 = 0
        var outputTokens: UInt64 = 0
        var cacheReadInputTokens: UInt64 = 0
        var cacheCreationInputTokens: UInt64 = 0

        var fields: [String: Any] {
            [
                "input_tokens": inputTokens,
                "output_tokens": outputTokens,
                "cache_read_input_tokens": cacheReadInputTokens,
                "cache_creation_input_tokens": cacheCreationInputTokens,
            ]
        }

        var isEmpty: Bool {
            inputTokens == 0 && outputTokens == 0
                && cacheReadInputTokens == 0 && cacheCreationInputTokens == 0
        }

        mutating func add(_ other: Usage) {
            inputTokens += other.inputTokens
            outputTokens += other.outputTokens
            cacheReadInputTokens += other.cacheReadInputTokens
            cacheCreationInputTokens += other.cacheCreationInputTokens
        }
    }

    private struct ToolResult {
        var order: Int
        var identifier: String
        var content: String
        var isError: Bool
    }

    private var sessionID: String
    private var model: String
    private let workingDirectory: String
    private let includePartialMessages: Bool
    private let tools: [String]
    private let slashCommands: [String]
    private let skills: [String]
    private let permissionMode: String
    private let apiKeySource: String
    private let startedAt: UInt64

    private var initialized = false
    private var terminalEmitted = false
    private var responseStarted = false
    private var responseCompleted = false
    private var responseID: String?
    private var responseModel: String?
    private var responseStopReason: String?
    private var responseStopSequence: String?
    private var responseUsage = Usage()
    private var initialUsage = Usage()
    private var aggregateUsage = Usage()
    private var usageByModel: [String: Usage] = [:]
    private var completedResponses = 0
    private var assistantFrames = 0
    private var nextMessageNumber = 0
    private var lastText = ""
    private var lastResponseStopReason: String?

    private var blocks: [[String: Any]] = []
    private var openKind: TextKind?
    private var openText = ""
    private var openSignature: String?
    private var partialMessageOpen = false
    private var partialBlockKind: TextKind?
    private var partialBlockIndex: Int?

    private var nextToolOrder = 0
    private var pendingToolOrders: [String: Int] = [:]
    private var completedToolIDs: Set<String> = []
    private var pendingToolResults: [ToolResult] = []
    private var pendingWebSearches: [String: OpenGrokPagerToolUpdate] = [:]
    private var webSearchRequests: UInt64 = 0

    init(
        sessionID: String,
        model: String?,
        workingDirectory: String,
        includePartialMessages: Bool,
        tools: [String],
        slashCommands: [String],
        skills: [String],
        permissionMode: String?,
        apiKeySource: String
    ) {
        self.sessionID = sessionID
        self.model = model.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
        self.workingDirectory = workingDirectory
        self.includePartialMessages = includePartialMessages
        self.tools = tools
        self.slashCommands = slashCommands
        self.skills = skills
        switch permissionMode {
        case "acceptEdits", "bypassPermissions", "plan", "dontAsk":
            self.permissionMode = permissionMode ?? "default"
        default:
            self.permissionMode = "default"
        }
        self.apiKeySource = apiKeySource == "oauth" ? "oauth" : "user"
        self.startedAt = DispatchTime.now().uptimeNanoseconds
    }

    mutating func reduce(_ event: OpenGrokPagerMinimalEvent) -> [[String: Any]] {
        guard !terminalEmitted else { return [] }
        var lines: [[String: Any]] = []

        switch event {
        case .responseStarted(
            let messageID, let model, let inputTokens,
            let cacheReadInputTokens, let cacheCreationInputTokens
        ):
            if hasPendingResponse {
                ensureInitialized(into: &lines)
                flushAssistant(defaultStopReason: "end_turn", into: &lines)
                flushToolResults(into: &lines)
            }
            responseStarted = true
            responseCompleted = false
            responseID = messageID
            responseModel = model.isEmpty ? nil : model
            if !model.isEmpty { self.model = model }
            initialUsage = Usage(
                inputTokens: inputTokens,
                cacheReadInputTokens: cacheReadInputTokens,
                cacheCreationInputTokens: cacheCreationInputTokens
            )
            responseUsage = initialUsage
        case .reasoningCompleted(let signature):
            guard !signature.isEmpty else { return lines }
            if openSignature != nil {
                closePartialBlock(into: &lines)
                finalizeOpenBlock()
            }
            openSignature = signature
        case .responseCompleted(
            let messageID, let stopReason, let stopSequence, let inputTokens,
            let outputTokens, let cacheReadInputTokens, let cacheCreationInputTokens
        ):
            if let current = responseID, let messageID, current != messageID,
               responseStarted {
                return lines
            }
            if let messageID { responseID = messageID }
            responseStopReason = stopReason
            responseStopSequence = stopSequence
            lastResponseStopReason = stopReason
            let usage = Usage(
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheReadInputTokens: cacheReadInputTokens,
                cacheCreationInputTokens: cacheCreationInputTokens
            )
            responseUsage = usage.isEmpty ? initialUsage : usage
            if !responseCompleted {
                responseCompleted = true
                completedResponses += 1
                if !responseUsage.isEmpty {
                    aggregateUsage.add(responseUsage)
                    usageByModel[activeModel, default: Usage()].add(responseUsage)
                }
            }
        case .output(let text):
            guard !text.isEmpty else { return lines }
            ensureInitialized(into: &lines)
            flushToolResults(into: &lines)
            appendText(text, kind: .text, into: &lines)
        case .reasoning(let text):
            guard !text.isEmpty else { return lines }
            ensureInitialized(into: &lines)
            flushToolResults(into: &lines)
            appendText(text, kind: .thinking, into: &lines)
        case .tool(let update):
            ensureInitialized(into: &lines)
            handleTool(update, into: &lines)
        case .samplingFailed(_, let message, _, _):
            finish(stopReason: nil, error: message, completion: nil, into: &lines)
        case .cancelled:
            finish(stopReason: "cancelled", error: "cancelled", completion: nil, into: &lines)
        case .completed(let completion):
            if sessionID.isEmpty, let identifier = completion.sessionID {
                sessionID = identifier
            }
            if !responseCompleted, completion.messageID != nil
                || completion.inputTokens != 0 || completion.outputTokens != 0
                || completion.cacheReadInputTokens != 0
                || completion.cacheCreationInputTokens != 0 {
                let terminal = OpenGrokPagerMinimalEvent.responseCompleted(
                    messageID: completion.messageID,
                    stopReason: completion.rawStopReason ?? completion.summary,
                    stopSequence: completion.stopSequence,
                    inputTokens: completion.inputTokens,
                    outputTokens: completion.outputTokens,
                    cacheReadInputTokens: completion.cacheReadInputTokens,
                    cacheCreationInputTokens: completion.cacheCreationInputTokens
                )
                lines.append(contentsOf: reduce(terminal))
            }
            let stopReason = completion.summary ?? lastResponseStopReason ?? "end_turn"
            let error = stopReason == "refusal" ? "The model refused to continue" : nil
            finish(stopReason: stopReason, error: error, completion: completion, into: &lines)
        case .lifecycle:
            ensureInitialized(into: &lines)
        case .status, .toolCallDelta, .retrying, .permissionRequested:
            break
        }
        return lines
    }

    private var activeModel: String {
        responseModel.flatMap { $0.isEmpty ? nil : $0 } ?? model
    }

    private var hasPendingResponse: Bool {
        responseStarted || responseCompleted || !blocks.isEmpty || !openText.isEmpty
            || openSignature != nil || !pendingToolResults.isEmpty
    }

    private mutating func ensureInitialized(into lines: inout [[String: Any]]) {
        guard !initialized else { return }
        initialized = true
        lines.append([
            "type": "system",
            "subtype": "init",
            "session_id": sessionID,
            "apiKeySource": apiKeySource,
            "model": model,
            "cwd": workingDirectory,
            "permissionMode": permissionMode,
            "tools": tools,
            "slash_commands": slashCommands,
            "mcp_servers": [[String: Any]](),
            "skills": skills,
            "uuid": UUID().uuidString.lowercased(),
        ])
    }

    private mutating func appendText(
        _ text: String,
        kind: TextKind,
        into lines: inout [[String: Any]]
    ) {
        if let current = openKind, current != kind {
            closePartialBlock(into: &lines)
            finalizeOpenBlock()
        } else if openKind == nil, openSignature != nil, kind == .text {
            appendSignatureOnlyBlock(into: &lines)
        }
        openKind = kind
        openText += text
        guard includePartialMessages else { return }
        openPartialMessage(into: &lines)
        if partialBlockIndex == nil {
            let index = blocks.count
            let contentBlock: [String: Any] = kind == .text
                ? ["type": "text", "text": ""]
                : ["type": "thinking", "thinking": "", "signature": ""]
            appendPartial([
                "type": "content_block_start",
                "index": index,
                "content_block": contentBlock,
            ], into: &lines)
            partialBlockKind = kind
            partialBlockIndex = index
        }
        let delta: [String: Any] = kind == .text
            ? ["type": "text_delta", "text": text]
            : ["type": "thinking_delta", "thinking": text]
        appendPartial([
            "type": "content_block_delta",
            "index": partialBlockIndex!,
            "delta": delta,
        ], into: &lines)
    }

    private mutating func finalizeOpenBlock() {
        guard let kind = openKind else {
            if let signature = openSignature {
                blocks.append(["type": "thinking", "thinking": "", "signature": signature])
                openSignature = nil
            }
            return
        }
        let text = openText
        let signature = openSignature
        openKind = nil
        openText = ""
        openSignature = nil
        switch kind {
        case .text where !text.isEmpty:
            blocks.append(["type": "text", "text": text])
        case .thinking where !text.isEmpty || signature != nil:
            blocks.append([
                "type": "thinking",
                "thinking": text,
                "signature": signature ?? "",
            ])
        default:
            break
        }
    }

    private mutating func openPartialMessage(into lines: inout [[String: Any]]) {
        guard includePartialMessages, !partialMessageOpen else { return }
        let identifier = messageIdentifier()
        appendPartial([
            "type": "message_start",
            "message": [
                "id": identifier,
                "type": "message",
                "role": "assistant",
                "model": activeModel,
                "content": [[String: Any]](),
                "stop_reason": NSNull(),
                "stop_sequence": NSNull(),
                "usage": initialUsage.fields,
            ] as [String: Any],
        ], into: &lines)
        partialMessageOpen = true
    }

    private mutating func closePartialBlock(into lines: inout [[String: Any]]) {
        guard let index = partialBlockIndex else { return }
        if partialBlockKind == .thinking, let signature = openSignature {
            appendPartial([
                "type": "content_block_delta",
                "index": index,
                "delta": ["type": "signature_delta", "signature": signature],
            ], into: &lines)
        }
        appendPartial(["type": "content_block_stop", "index": index], into: &lines)
        partialBlockKind = nil
        partialBlockIndex = nil
    }

    private mutating func appendSignatureOnlyBlock(into lines: inout [[String: Any]]) {
        guard let signature = openSignature, openKind == nil else { return }
        if includePartialMessages {
            openPartialMessage(into: &lines)
            let index = blocks.count
            appendPartial([
                "type": "content_block_start",
                "index": index,
                "content_block": ["type": "thinking", "thinking": "", "signature": ""],
            ], into: &lines)
            appendPartial([
                "type": "content_block_delta",
                "index": index,
                "delta": ["type": "signature_delta", "signature": signature],
            ], into: &lines)
            appendPartial(["type": "content_block_stop", "index": index], into: &lines)
        }
        blocks.append(["type": "thinking", "thinking": "", "signature": signature])
        openSignature = nil
    }

    private mutating func appendPartial(
        _ event: [String: Any],
        into lines: inout [[String: Any]]
    ) {
        guard includePartialMessages else { return }
        lines.append([
            "type": "stream_event",
            "event": event,
            "parent_tool_use_id": NSNull(),
            "session_id": sessionID,
            "uuid": UUID().uuidString.lowercased(),
        ])
    }

    private mutating func messageIdentifier() -> String {
        if let responseID { return responseID }
        let identifier = "msg_\(nextMessageNumber)"
        nextMessageNumber += 1
        responseID = identifier
        return identifier
    }

    private mutating func handleTool(
        _ update: OpenGrokPagerToolUpdate,
        into lines: inout [[String: Any]]
    ) {
        guard !completedToolIDs.contains(update.callID) else { return }
        switch update.state {
        case .running:
            guard pendingToolOrders[update.callID] == nil,
                  pendingWebSearches[update.callID] == nil else { return }
            if update.name == "web_search" {
                pendingWebSearches[update.callID] = update
                return
            }
            flushToolResults(into: &lines)
            appendToolUse(update, into: &lines)
        case .succeeded, .failed, .cancelled:
            if let search = pendingWebSearches.removeValue(forKey: update.callID) {
                completeWebSearch(started: search, update: update, into: &lines)
                completedToolIDs.insert(update.callID)
                return
            }
            if pendingToolOrders[update.callID] == nil {
                appendToolUse(update, into: &lines)
            }
            let order = pendingToolOrders.removeValue(forKey: update.callID) ?? nextOrder()
            flushAssistant(defaultStopReason: "tool_use", into: &lines)
            pendingToolResults.append(ToolResult(
                order: order,
                identifier: update.callID,
                content: update.output ?? update.structuredOutput ?? "",
                isError: update.state != .succeeded
            ))
            completedToolIDs.insert(update.callID)
        }
    }

    private mutating func appendToolUse(
        _ update: OpenGrokPagerToolUpdate,
        into lines: inout [[String: Any]]
    ) {
        closePartialBlock(into: &lines)
        finalizeOpenBlock()
        let input = Self.object(from: update.input)
        let index = blocks.count
        blocks.append([
            "type": "tool_use",
            "id": update.callID,
            "name": update.name,
            "input": input,
        ])
        pendingToolOrders[update.callID] = nextOrder()
        guard includePartialMessages else { return }
        openPartialMessage(into: &lines)
        appendPartial([
            "type": "content_block_start",
            "index": index,
            "content_block": [
                "type": "tool_use", "id": update.callID,
                "name": update.name, "input": [String: Any](),
            ] as [String: Any],
        ], into: &lines)
        let encoded = Self.compactJSON(input)
        appendPartial([
            "type": "content_block_delta",
            "index": index,
            "delta": ["type": "input_json_delta", "partial_json": encoded],
        ], into: &lines)
        appendPartial(["type": "content_block_stop", "index": index], into: &lines)
    }

    private mutating func completeWebSearch(
        started: OpenGrokPagerToolUpdate,
        update: OpenGrokPagerToolUpdate,
        into lines: inout [[String: Any]]
    ) {
        let parsed = Self.object(from: update.output ?? update.structuredOutput ?? "")
        let action = parsed["action"] as? [String: Any] ?? parsed
        let query = action["query"] as? String ?? ""
        let sources = action["sources"] as? [[String: Any]] ?? []
        let hits: [[String: Any]] = sources.compactMap { source in
            guard let url = source["url"] as? String else { return nil }
            let title = (source["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url
            return ["type": "web_search_result", "url": url, "title": title]
        }
        if update.state == .succeeded, query.isEmpty, hits.isEmpty {
            appendToolUse(started, into: &lines)
            let order = pendingToolOrders.removeValue(forKey: update.callID) ?? nextOrder()
            flushAssistant(defaultStopReason: "tool_use", into: &lines)
            pendingToolResults.append(ToolResult(
                order: order, identifier: update.callID,
                content: update.output ?? "", isError: false
            ))
            return
        }
        closePartialBlock(into: &lines)
        finalizeOpenBlock()
        let useIndex = blocks.count
        let input: [String: Any] = ["query": query]
        blocks.append([
            "type": "server_tool_use", "id": update.callID,
            "name": "web_search", "input": input,
        ])
        let content: Any
        if update.state == .succeeded {
            webSearchRequests += 1
            content = hits
        } else {
            content = ["type": "web_search_tool_result_error", "error_code": "unavailable"]
        }
        let resultIndex = blocks.count
        blocks.append([
            "type": "web_search_tool_result",
            "tool_use_id": update.callID,
            "content": content,
        ])
        guard includePartialMessages else { return }
        openPartialMessage(into: &lines)
        appendPartial([
            "type": "content_block_start", "index": useIndex,
            "content_block": [
                "type": "server_tool_use", "id": update.callID,
                "name": "web_search", "input": [String: Any](),
            ] as [String: Any],
        ], into: &lines)
        appendPartial([
            "type": "content_block_delta", "index": useIndex,
            "delta": ["type": "input_json_delta", "partial_json": Self.compactJSON(input)],
        ], into: &lines)
        appendPartial(["type": "content_block_stop", "index": useIndex], into: &lines)
        appendPartial([
            "type": "content_block_start", "index": resultIndex,
            "content_block": [
                "type": "web_search_tool_result",
                "tool_use_id": update.callID,
                "content": content,
            ] as [String: Any],
        ], into: &lines)
        appendPartial(["type": "content_block_stop", "index": resultIndex], into: &lines)
    }

    private mutating func nextOrder() -> Int {
        defer { nextToolOrder += 1 }
        return nextToolOrder
    }

    private mutating func flushAssistant(
        defaultStopReason: String?,
        into lines: inout [[String: Any]]
    ) {
        closePartialBlock(into: &lines)
        if openKind == nil, openSignature != nil {
            appendSignatureOnlyBlock(into: &lines)
        }
        finalizeOpenBlock()
        let resolvedStopReason: Any = defaultStopReason == nil
            ? NSNull()
            : responseStopReason ?? defaultStopReason!
        if includePartialMessages, !partialMessageOpen, responseStarted {
            openPartialMessage(into: &lines)
        }
        if partialMessageOpen {
            appendPartial([
                "type": "message_delta",
                "delta": [
                    "stop_reason": resolvedStopReason,
                    "stop_sequence": Self.nullable(responseStopSequence),
                ] as [String: Any],
                "usage": responseUsage.fields,
            ], into: &lines)
            appendPartial(["type": "message_stop"], into: &lines)
            partialMessageOpen = false
        }
        guard !blocks.isEmpty else {
            clearResponse()
            return
        }
        let content = blocks
        blocks.removeAll(keepingCapacity: true)
        lastText = content.compactMap { block in
            block["type"] as? String == "text" ? block["text"] as? String : nil
        }.joined()
        lines.append([
            "type": "assistant",
            "message": [
                "id": messageIdentifier(),
                "type": "message",
                "role": "assistant",
                "model": activeModel,
                "content": content,
                "stop_reason": resolvedStopReason,
                "stop_sequence": Self.nullable(responseStopSequence),
                "usage": responseUsage.fields,
            ] as [String: Any],
            "parent_tool_use_id": NSNull(),
            "session_id": sessionID,
            "uuid": UUID().uuidString.lowercased(),
        ])
        assistantFrames += 1
        clearResponse()
    }

    private mutating func clearResponse() {
        responseStarted = false
        responseCompleted = false
        responseID = nil
        responseModel = nil
        responseStopReason = nil
        responseStopSequence = nil
        responseUsage = Usage()
        initialUsage = Usage()
        openSignature = nil
    }

    private mutating func flushToolResults(into lines: inout [[String: Any]]) {
        guard !pendingToolResults.isEmpty else { return }
        let content: [[String: Any]] = pendingToolResults
            .sorted { $0.order < $1.order }
            .map { result in
                [
                    "type": "tool_result",
                    "tool_use_id": result.identifier,
                    "content": result.content,
                    "is_error": result.isError,
                ]
            }
        pendingToolResults.removeAll(keepingCapacity: true)
        lines.append([
            "type": "user",
            "message": ["role": "user", "content": content] as [String: Any],
            "parent_tool_use_id": NSNull(),
            "session_id": sessionID,
            "uuid": UUID().uuidString.lowercased(),
        ])
    }

    private mutating func finish(
        stopReason: String?,
        error: String?,
        completion: OpenGrokPagerMinimalCompletion?,
        into lines: inout [[String: Any]]
    ) {
        ensureInitialized(into: &lines)
        let unresolvedSearches = Array(pendingWebSearches.values)
        for search in unresolvedSearches {
            completeWebSearch(
                started: search,
                update: OpenGrokPagerToolUpdate(
                    callID: search.callID,
                    name: search.name,
                    input: search.input,
                    state: .failed
                ),
                into: &lines
            )
        }
        pendingWebSearches.removeAll(keepingCapacity: false)
        let defaultStopReason = error == nil
            ? (stopReason == "max_tokens" ? "max_tokens" : "end_turn")
            : nil
        flushAssistant(defaultStopReason: defaultStopReason, into: &lines)
        let unresolvedTools = Array(pendingToolOrders)
        for (identifier, order) in unresolvedTools {
            pendingToolResults.append(ToolResult(
                order: order,
                identifier: identifier,
                content: "tool call did not complete",
                isError: true
            ))
        }
        pendingToolOrders.removeAll(keepingCapacity: false)
        flushToolResults(into: &lines)

        var usage = aggregateUsage.fields
        usage["server_tool_use"] = ["web_search_requests": webSearchRequests]
        let modelUsage: [String: Any] = usageByModel.mapValues { usage in
            [
                "inputTokens": usage.inputTokens,
                "outputTokens": usage.outputTokens,
                "cacheReadInputTokens": usage.cacheReadInputTokens,
                "cacheCreationInputTokens": usage.cacheCreationInputTokens,
                "webSearchRequests": webSearchRequests,
                "costUSD": 0.0,
            ] as [String: Any]
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
        var result: [String: Any] = [
            "type": "result",
            "subtype": error == nil ? "success" : "error_during_execution",
            "is_error": error != nil,
            "duration_ms": elapsed / 1_000_000,
            "duration_api_ms": 0,
            "num_turns": completedResponses == 0 ? assistantFrames : completedResponses,
            "stop_reason": Self.nullable(stopReason),
            "total_cost_usd": 0.0,
            "usage": usage,
            "modelUsage": modelUsage,
            "session_id": completion?.sessionID ?? sessionID,
            "uuid": UUID().uuidString.lowercased(),
        ]
        if let error {
            result["errors"] = [error]
        } else {
            result["result"] = lastText
        }
        lines.append(result)
        terminalEmitted = true
    }

    private static func object(from value: String) -> [String: Any] {
        guard let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return [:]
        }
        return dictionary
    }

    private static func nullable(_ value: String?) -> Any {
        guard let value else { return NSNull() }
        return value
    }

    private static func compactJSON(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}
