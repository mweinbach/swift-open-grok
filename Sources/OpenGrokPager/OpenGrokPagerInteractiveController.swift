import Dispatch
import Foundation
import OpenGrokPagerCommandUI
import OpenGrokPagerMinimal
import OpenGrokPagerRender
import OpenGrokPromptQueue
import OpenGrokTerminalCore
import OpenGrokTextArea

/// What a host-backed ("local") slash command resolved to.
///
/// `.notice` lands on the transcript notice channel — the port's mapping for
/// upstream's toasts and `CommandResult::Error` / `Message` copy. `.submit`
/// sends the text as the turn's prompt — upstream's
/// `CommandResult::InjectSkill` shape (`/imagine`,
/// `slash/commands/imagine.rs:47-54`), riding the same enqueue path the
/// skill commands use, so a host command can expand into a model prompt
/// without the controller knowing which command it was.
public enum PagerLocalCommandOutcome: Sendable, Equatable {
    case notice(String)
    case submit(String)
}

/// The single-process stand-in for upstream's `x.ai/interject` wire hop: the
/// composition installs closures that reach the live session actor directly.
///
/// `deliver` is the `SessionCommand::Interject` decision
/// (run_loop.rs:1962-1989): `true` means the text was buffered into an
/// actually-running turn and the turn loop will merge it at the next safe
/// drain point; `false` means no turn runs and the CONTROLLER must queue the
/// text as its own front-of-queue prompt turn (the queue lives on this side
/// in this port). `collectStranded` drains interjections that raced past the
/// completed turn's final drain, for the completion-arm flush
/// (`flush_stranded_interjections`, run_loop.rs:432-447).
public struct OpenGrokPagerInterjectionSeam: Sendable {
    public let deliver: @Sendable (String) async -> Bool
    public let collectStranded: @Sendable () async -> [String]

    public init(
        deliver: @escaping @Sendable (String) async -> Bool,
        collectStranded: @escaping @Sendable () async -> [String]
    ) {
        self.deliver = deliver
        self.collectStranded = collectStranded
    }
}

public actor OpenGrokPagerInteractiveController: OpenGrokPagerInteractiveFrontend {
    public typealias CustomCommandHandler = @Sendable (
        PagerCommandInvocation
    ) async throws -> String?
    public typealias LocalCommandHandler = @Sendable (
        PagerCommandInvocation
    ) async throws -> PagerLocalCommandOutcome?

    private enum Control: Sendable {
        /// A user Esc or Ctrl+C, fast-pathed ahead of queued input so it lands
        /// promptly during a busy turn.
        case interrupt(isEscape: Bool)
        /// An external `cancel()` — unlike an interrupt this always ends the run.
        case cancel
        case eof
        case shutdown
        /// A slash command the renderer resolved on the controller's behalf —
        /// today, a command-palette row. It travels as a control signal rather
        /// than as input so it lands in the same dispatch the composer's own
        /// submit uses, including the mid-turn deferral for history-rewriting
        /// commands.
        case command(String)
        /// A dashboard dispatch/reply targeting a retained session tab.
        case dispatch(sessionID: String, prompt: String)
        /// A dashboard dispatch that creates a retained top-level session.
        case dispatchNew(prompt: String, workingDirectory: String?)
        /// A scheduler fire enqueued a Cron prompt from outside the input
        /// loop. Idle, the loop must start the drain — the port of
        /// `maybe_drain_queue` after `enqueue_cron_prompt`
        /// (acp_handler/background.rs:499-507). Mid-turn it is a no-op: the
        /// entry waits in the queue and the completion arm's `.drainNext`
        /// picks it up.
        case cronEnqueued
    }

    /// What an Esc or Ctrl+C resolved to.
    private enum InterruptOutcome: Sendable {
        /// Handled inside the prompt; redraw and keep going.
        case consumed
        case cancelTurn
        case quit
    }

    private enum PromptAction: Sendable {
        case changed
        case submit
        /// A bare `Esc`. What it means depends on whether a turn is running and
        /// whether the composer holds a draft — see `resolveEscape`.
        case escape
        /// `Ctrl+C`.
        case interrupt
        /// `Ctrl+D`.
        case eof
        case resize(TerminalSize)
        case historyPrevious
        case historyNext
        case completionMove(Int)
        case completionAccept
        /// `Enter` with the dropdown open — accept the highlighted row, then
        /// either send it (complete command) or stay open for its required
        /// arguments. Never escapes `applyEditorEvent`, which rewrites it to
        /// `.submit` or `.changed` (upstream's `is_command_complete` gate,
        /// `app/agent_view/prompt.rs:186-274`).
        case completionCommit
        case viewport(OpenGrokPagerViewportCommand)
        /// `Tab` on a closed dropdown — hand the keyboard to the scrollback.
        case focusScrollback
        /// `Ctrl+M` in the composer (`defaults.rs:702`).
        case toggleMultiline
        /// An application chord that is not the composer's to service.
        case global(OpenGrokPagerGlobalCommand)
        case ignored
    }

    private enum TurnOutcome: Sendable {
        case finished(OpenGrokPagerRuntimeResult)
        case eof
        /// The user cancelled the turn; the run continues at the prompt.
        case turnCancelled
        /// The turn's session failed. The failure is rendered as a transcript
        /// marker and the run continues at the prompt — upstream pushes
        /// `SessionEvent::TurnFailed` and keeps the event loop alive
        /// (`dispatch/prompt.rs:1399-1402`); ending the run here is how one
        /// bad provider request used to take the whole TUI down.
        case turnFailed(message: String)
        /// A bare `Enter` on an empty composer force-sent the head of the
        /// queue. The turn ends the same way a cancel does, but the queue keeps
        /// draining instead of parking at the composer.
        case turnPreempted
        /// An external cancel or a fatal condition; the run ends.
        case cancelled
        case shutdown
    }

    /// What the run loop should do once a turn has been accounted for.
    private enum TurnDisposition: Sendable {
        /// Back to the composer, leaving anything queued queued.
        case keepEditing
        /// Start the next queued prompt immediately.
        case drainNext
        case end(OpenGrokPagerInteractiveLifecycle)
    }

    private enum StreamRead<Element: Sendable>: Sendable {
        case element(Element)
        case end
        case failure(String)
        case cancelled
    }

    private enum Signal: Sendable {
        /// `generation` is the turn that owns the event. A preempted turn's
        /// dying session races its `.cancelled` into the mailbox after the
        /// loop has already decided `.turnPreempted`; the send-now drain goes
        /// straight into the next turn without passing the idle loop (which
        /// swallows stale session signals), so an untagged event would be
        /// adopted by the next turn, reported as that turn's cancellation,
        /// and end the whole run with the queue discarded.
        case session(generation: UInt64, StreamRead<OpenGrokPagerEvent>)
        case input(StreamRead<InputEvent>)
        case control(Control)
    }

    /// Composer draft. Not `Sendable`: the sole store is a `TextArea` class,
    /// and the controller actor owns this object so it never crosses actors.
    ///
    /// Stage 3 host-policy order matches `handle_prompt_key`
    /// (`app/agent_view/prompt.rs` at pin 650c1db7): slash/menu keys, empty
    /// Up history, Enter send/newline, Tab, Esc, Ctrl+C/D, and app-global /
    /// viewport / tasks / plan / queue chords never reach `TextArea.input`.
    /// Remaining editor keys (Ctrl-A/E/W/U/K/Y, undo/redo, Alt-word, Home/End,
    /// arrows, backspace/delete, printable) go through that API once.
    private final class PromptEditor {
        /// The only text / cursor / selection / undo buffer. UTF-8 internally;
        /// Character offsets exist only at `state()` / `placeCursor(at:)`.
        private let area: TextArea
        /// Open slash-command dropdown. When non-empty, `↑`/`↓` move the
        /// selection instead of recalling history, matching the reference's
        /// dropdown intercept ahead of the history step.
        var completions: [OpenGrokPagerCommandSuggestion] = []
        var selectedCompletion: Int?
        /// Esc closed the dropdown (`slash_close`, `prompt.rs:229-233`); it
        /// stays closed until the text actually changes. Without the latch,
        /// the refresh that follows any `.changed` action — cursor moves
        /// included — would reopen the menu the same keystroke that closed it.
        var completionsDismissed = false
        /// Set while history browsing is open. Without it, `Down` would stop
        /// browsing the moment `Up` filled the composer with a recalled prompt.
        var isBrowsingHistory = false
        /// Mirrors `OpenGrokPagerInputModes.isMultiline`. Held here because it
        /// changes what `Enter` means, which only the editor can decide.
        var isMultiline = false

        init(text: String) {
            let area = TextArea()
            // Default tabWidth is 4 and would expand pasted tabs; Stage 1
            // keyboard paste must keep the bytes the user handed us.
            area.tabWidth = 0
            // Composer chrome owns the prefix; the TextArea content rect
            // has no inner scrollbar (transcript gutter is separate).
            area.showScrollbar = false
            area.keepSelectionAfterMouseUp = true
            self.area = area
            loadBuffer(text)
        }

        var text: String { area.text }
        var isEmpty: Bool { area.isEmpty }

        func state(
            pendingKey: String? = nil,
            pendingLabel: String? = nil
        ) -> OpenGrokPagerInteractivePromptState {
            let contents = area.text
            return OpenGrokPagerInteractivePromptState(
                text: contents,
                cursorOffset: characterOffset(fromUTF8: area.cursor, in: contents),
                cursorUTF8: area.cursor,
                selectionUTF8: area.selectionRange,
                selectedText: area.selectedText(),
                textAreaState: TextAreaState(scroll: area.scrollOverrideValue ?? 0),
                scrollOverride: area.scrollOverrideValue,
                completions: completions,
                selectedCompletion: selectedCompletion,
                pendingConfirmationKey: pendingKey,
                pendingConfirmationLabel: pendingLabel
            )
        }

        func apply(_ event: InputEvent) -> PromptAction {
            switch event {
            case .paste(let value):
                insert(value)
                return value.isEmpty ? .ignored : .changed
            case .key(let key):
                return apply(key)
            case .resize(let size):
                return .resize(size)
            case .mouse, .focusGained, .focusLost:
                return .ignored
            }
        }

        func reset() {
            loadBuffer("")
            completions = []
            selectedCompletion = nil
        }

        func expandPasteElementAtCursor() -> Bool {
            area.expandPasteElementAtCursor()
        }

        func fileRefElementAtCursor() -> (path: String, lineRange: Range<Int>?)? {
            area.fileRefElementAtCursor()
        }

        func replace(with value: String) {
            loadBuffer(value)
        }

        /// Place the cursor at a Character / grapheme offset from composer
        /// mouse hit mapping. Clamped — never traps past the draft ends.
        func placeCursor(at offset: Int) {
            area.setCursor(utf8Offset(fromCharacter: offset, in: area.text))
        }

        /// Apply `TextArea.handleMouse` against the last-painted content rect.
        /// Returns the mouse action plus any clipboard payload the TextArea
        /// staged (double-click / drag-up copy).
        func handleMouse(_ event: MouseEvent, content: TextAreaRect) -> MouseAction {
            let state = TextAreaState(scroll: area.scrollOverrideValue ?? 0)
            return area.handleMouse(event, area: content, state: state)
        }

        func tick(content: TextAreaRect) -> MouseAction {
            let state = TextAreaState(scroll: area.scrollOverrideValue ?? 0)
            return area.tick(area: content, state: state)
        }

        func pollTimeoutMs() -> UInt64? {
            area.pollTimeoutMs()
        }

        /// Drop an in-flight TextArea gesture without copying. Overlay /
        /// suspend / restore / a non-composer routing must call this so
        /// `pendingDragScroll` cannot keep the scroll clock armed.
        func cancelMouseGesture() {
            area.cancelMouseGesture()
        }

        func takeClipboard() -> String? {
            area.takeClipboard()
        }

        /// Close the dropdown, latching it shut until the text changes.
        /// Returns whether there was anything to close, so the Esc handler
        /// can fall through to the cancel/clear ladder when there was not.
        func dismissCompletions() -> Bool {
            guard !completions.isEmpty else { return false }
            completions = []
            selectedCompletion = nil
            completionsDismissed = true
            return true
        }

        private func apply(_ event: KeyEvent) -> PromptAction {
            if let control = controlAction(for: event) {
                return control
            }
            if let global = Self.globalAction(for: event) {
                return .global(global)
            }

            switch event.key {
            case .enter:
                // Enter submits and Shift+Enter (or Alt+Enter, which is what
                // terminals without the Kitty protocol can actually report)
                // inserts a newline — multiline mode swaps the two, which is
                // the whole of `/multiline` upstream.
                return resolveEnter(modifiers: event.modifiers)
            case .escape:
                // Unreachable in a live run: the input pump classifies a bare
                // Esc as a control signal before the editor sees the event.
                // The dropdown intercept therefore lives in
                // `handleInterrupt`, not here — an editor-side close was
                // landed once and silently did nothing.
                return .escape
            case .tab:
                // Tab accepts the highlighted completion; with the dropdown
                // closed it is the focus switch (`defaults.rs:488`). Letting
                // Enter accept instead would make a fully typed command name
                // need two presses, since its own row stays in the menu.
                return completions.isEmpty ? .focusScrollback : .completionAccept
            case .backTab:
                return .global(.cyclePermissionMode)
            case .up:
                if !completions.isEmpty { return .completionMove(-1) }
                // `Up` recalls history only on an empty composer
                // (`app/agent_view/prompt.rs:465-486`). A nonempty draft
                // falls through to textarea vertical motion — not viewport
                // line-up (`When::ScrollbackFocused` only, `defaults.rs:192`).
                if isEmpty || isBrowsingHistory { return .historyPrevious }
                return routeEditorKey(event)
            case .down:
                if !completions.isEmpty { return .completionMove(1) }
                // Down never opens history (`prompt.rs`: "Down never opens
                // the panel"); once browsing it steps toward the newest.
                if isBrowsingHistory { return .historyNext }
                return routeEditorKey(event)
            case .pageUp:
                // With the dropdown open the paging keys page the menu
                // (`prompt.rs:187-198`), one visible window per press.
                if !completions.isEmpty {
                    return .completionMove(-PagerLayoutMetrics.maxDropdownRows)
                }
                return .viewport(.pageUp)
            case .pageDown:
                if !completions.isEmpty {
                    return .completionMove(PagerLayoutMetrics.maxDropdownRows)
                }
                return .viewport(.pageDown)
            case .char(let character):
                if character == "\r" || character == "\n" {
                    return resolveEnter(modifiers: event.modifiers)
                }
                if character == "\u{3}" {
                    return .interrupt
                }
                if character == "\u{4}" {
                    return .eof
                }
                return routeEditorKey(event)
            default:
                return routeEditorKey(event)
            }
        }

        /// Snapshot → `TextArea.input` → `.changed` only when text, cursor, or
        /// selection actually moved. Matches `prompt_widget/mod.rs:1787-1802`
        /// (text/cursor) plus this port's published `selectionUTF8`.
        private func routeEditorKey(_ event: KeyEvent) -> PromptAction {
            let beforeText = area.text
            let beforeCursor = area.cursor
            let beforeSelection = area.selectionRange
            area.input(event)
            let textChanged = area.text != beforeText
            if textChanged {
                completionsDismissed = false
            }
            if textChanged
                || area.cursor != beforeCursor
                || area.selectionRange != beforeSelection
            {
                return .changed
            }
            return .ignored
        }

        /// What `Enter` means right now.
        ///
        /// Three inputs decide it: the multiline mode, whether the report
        /// carried Shift or Alt, and whether the draft ends in a backslash.
        /// The backslash is upstream's rescue for terminals that cannot
        /// distinguish `Shift+Enter` from `Enter` at all
        /// (`views/prompt_widget/mod.rs:2137-2142`) — it eats the backslash and
        /// continues the line, so multiline stays reachable everywhere.
        private func resolveEnter(modifiers: KeyModifiers) -> PromptAction {
            let wantsNewline = modifiers.contains(.shift) || modifiers.contains(.alt)
            if isMultiline != wantsNewline {
                insert("\n")
                return .changed
            }
            // The dropdown owns a sending Enter in the COMMAND phase: accept
            // the highlighted row, then send only if the command is complete
            // — upstream's dropdown intercept ahead of the send path
            // (`prompt.rs:186-274`). The argument phase deliberately keeps
            // Enter as plain send: a typed argument must pass through as
            // typed ("/theme tokyonight" stays tokyonight), and Tab remains
            // the explicit accept for a suggestion.
            if !completions.isEmpty, !area.text.contains(where: \.isWhitespace) {
                return .completionCommit
            }
            // This press would have sent. A line ending in a backslash says
            // "not yet" — the rescue only applies here, on the send path, and
            // only with the cursor at the end, which is where it is when
            // someone types a line and reaches for Enter.
            let contents = area.text
            let end = contents.utf8.count
            guard contents.last == "\\", area.cursor == end else { return .submit }
            area.replaceRange((end - 1)..<end, with: "")
            insert("\n")
            return .changed
        }

        /// Application chords that mean the same thing wherever they land.
        ///
        /// Only the ones this port routes to a real surface are bound. The
        /// unbound half of upstream's `AgentScreen` table — `Ctrl+T` todos,
        /// `Ctrl+G` tasks, `Ctrl+B` background, `Ctrl+S` sessions,
        /// `Ctrl+\` dashboard — stays inert on purpose, for the same reason
        /// the dropdown lists no no-op command. `Ctrl+L` extensions joined
        /// the bound half when the read-only extensions modal landed.
        static func globalAction(for event: KeyEvent) -> OpenGrokPagerGlobalCommand? {
            // `F2` carries no modifier, so it is resolved ahead of the Ctrl
            // gate (`defaults.rs:839`). The bare form only: a modified `F2` is
            // a different chord and must not silently open settings. The
            // `Ctrl+,` / `Cmd+,` alternates are left unbound because most
            // terminals cannot report either.
            if case .f(2) = event.key, event.modifiers.isEmpty { return .openSettings }
            guard event.modifiers.contains(.control) else { return nil }
            let character: Character?
            switch event.key {
            case .char(let value): character = value
            default: character = event.character
            }
            switch character?.lowercased() {
            // `Ctrl+.` primary with `Ctrl+X` as the alternate, both bound
            // because `ctrl_dot_unreliable()` terminals swap them
            // (`defaults.rs:801-823`).
            case ".", "x": return .shortcutsHelp
            // `Ctrl+;` primary, `Ctrl+'` alternate (`defaults.rs:551-578`).
            case ";", "'": return .toggleQueue
            // Upstream's send-now chord is Ctrl+Enter with Ctrl+I, Ctrl+O, or
            // Ctrl+L alternates (`defaults.rs:635-651`). Ctrl+Enter is the same
            // CR byte as Enter here, Ctrl+I is Tab, Ctrl+O already toggles
            // always-approve, and Ctrl+L stays reserved for extensions. Send-now
            // is therefore reachable through `enter_steers` or an empty-composer
            // force-send. The cost is no one-keystroke send-now for a full
            // composer while `enter_steers` is off.
            case "o": return .toggleAlwaysApprove
            // `Ctrl+L` opens the extensions modal on the Plugins tab
            // (`defaults.rs:594-613`, dispatched at
            // `agent_view/input.rs:1266-1271`). Upstream unbinds it in the
            // VS Code terminal family, where Ctrl+L is the interject chord;
            // this port has no per-family key table, so the chord is bound
            // unconditionally — recorded divergence.
            case "l": return .openExtensions
            // `Ctrl+G` toggles the tasks pane (`defaults.rs:44-55`) — bound
            // now that the B1-t pane exists.
            case "g": return .toggleTasks
            // `Ctrl+\` opens the Agent Dashboard (`defaults.rs:890`).
            // Terminals report the chord as the raw FS byte; both spellings
            // land here (the Ctrl+C `\u{3}` precedent in `controlAction`).
            case "\\", "\u{1c}": return .openDashboard
            default: return nil
            }
        }

        private func controlAction(for event: KeyEvent) -> PromptAction? {
            guard event.modifiers.contains(.control) else { return nil }
            let character: Character?
            switch event.key {
            case .char(let value):
                character = value
            default:
                character = event.character
            }
            switch character?.lowercased() {
            case "c": return .interrupt
            case "d": return .eof
            // Ctrl-U/J/K are `When::ScrollbackFocused` only (`defaults.rs:192-
            // 226`). Prompt-focused they are readline (kill / newline) via
            // `TextArea.input` — do not intercept them here.
            // Not a mis-assignment against the reference, as it first looks:
            // upstream hard-codes the same dropdown intercept ahead of the
            // action registry (`app/agent_view/prompt.rs:212-221`), so
            // `Ctrl+P`/`Ctrl+N` move the menu while one is open and otherwise
            // fall through to `CommandPalette` (`defaults.rs:786`) and
            // `NewSession` (`:748`). That fall-through is what was missing.
            case "p": return completions.isEmpty ? .global(.commandPalette) : .completionMove(-1)
            case "n": return completions.isEmpty ? .global(.newSession) : .completionMove(1)
            // `Ctrl+M` toggles multiline in the prompt and opens the model
            // picker outside it. Upstream registers both in different `When`
            // contexts and resolves by focus (`defaults.rs:702` and `:824`);
            // this branch is the prompt half. Must stay ahead of
            // `TextArea.input`, which would otherwise insert a newline.
            case "m": return .toggleMultiline
            default: return nil
            }
        }

        /// Replace the whole buffer. `setText` leaves the caret at the
        /// previous UTF-8 offset (0 on a fresh area), so this always parks
        /// it at the end — matching the old `[Character]` replace.
        /// Selection and undo are dropped so history / slash / submit cannot
        /// resurrect a prior draft. Mouse gestures go through `handleMouse`
        /// on this same `TextArea`; load must not leave a stale drag/selection.
        private func loadBuffer(_ value: String) {
            area.setText(value)
            area.setCursor(utf8Offset(fromCharacter: value.count, in: area.text))
            area.clearSelection()
            area.clearHistory()
            completionsDismissed = false
        }

        private func insert(_ value: String) {
            guard !value.isEmpty else { return }
            // Host-owned mutations (bracketed paste, Enter-as-newline) do not
            // go through `TextArea.input`, which is what replaces a selection
            // before inserting. Mirror that here so paste/newline still
            // overwrite a highlighted range.
            if let range = area.selectionRange, !range.isEmpty {
                let deleted = area.deleteSelection()
                if !deleted {
                    area.clearSelection()
                }
            }
            area.insertStr(value)
            // New text lifts the Esc dismissal: typing after closing the
            // dropdown is a fresh query.
            completionsDismissed = false
        }
    }

    private actor StreamChannel<Element: Sendable> {
        private var queued: [StreamRead<Element>] = []
        private var waiter: (UUID, CheckedContinuation<StreamRead<Element>, Never>)?
        private var isFinished = false

        func send(_ value: StreamRead<Element>) {
            guard !isFinished else { return }
            if let waiter {
                self.waiter = nil
                waiter.1.resume(returning: value)
            } else {
                queued.append(value)
            }
        }

        func next() async -> StreamRead<Element> {
            if !queued.isEmpty { return queued.removeFirst() }
            if isFinished { return .end }
            let waiterID = UUID()
            return await withTaskCancellationHandler(operation: {
                await withCheckedContinuation { continuation in
                    if !queued.isEmpty {
                        continuation.resume(returning: queued.removeFirst())
                    } else if isFinished {
                        continuation.resume(returning: .end)
                    } else {
                        waiter = (waiterID, continuation)
                    }
                }
            }, onCancel: {
                Task { await self.cancelWaiter(waiterID) }
            })
        }

        func finish() {
            guard !isFinished else { return }
            isFinished = true
            waiter?.1.resume(returning: .end)
            waiter = nil
        }

        private func cancelWaiter(_ waiterID: UUID) {
            guard waiter?.0 == waiterID, let waiter else { return }
            self.waiter = nil
            waiter.1.resume(returning: .cancelled)
        }
    }

    private actor ThrowingStreamReader<Element: Sendable> {
        private let channel: StreamChannel<Element>
        private let producer: Task<Void, Never>

        init(_ stream: AsyncThrowingStream<Element, Error>) {
            let channel = StreamChannel<Element>()
            self.channel = channel
            self.producer = Task {
                do {
                    for try await element in stream {
                        await channel.send(.element(element))
                    }
                    await channel.send(.end)
                } catch is CancellationError {
                    await channel.send(.cancelled)
                } catch {
                    await channel.send(.failure(String(describing: error)))
                }
                await channel.finish()
            }
        }

        func next() async -> StreamRead<Element> {
            await channel.next()
        }

        func cancel() async {
            producer.cancel()
            await channel.finish()
        }
    }

    private actor SignalMailbox {
        private var queued: [Signal] = []
        private var waiter: (UUID, CheckedContinuation<Signal?, Never>)?
        private var isClosed = false

        func send(_ signal: Signal, priority: Bool = false) {
            guard !isClosed else { return }
            if let waiter {
                self.waiter = nil
                waiter.1.resume(returning: signal)
            } else if priority {
                queued.insert(signal, at: 0)
            } else {
                queued.append(signal)
            }
        }

        func next() async -> Signal? {
            if let signal = dequeue() { return signal }
            if isClosed { return nil }
            let waiterID = UUID()
            return await withTaskCancellationHandler(operation: {
                await withCheckedContinuation { continuation in
                    if let signal = dequeue() {
                        continuation.resume(returning: signal)
                    } else if isClosed {
                        continuation.resume(returning: nil)
                    } else {
                        waiter = (waiterID, continuation)
                    }
                }
            }, onCancel: {
                Task { await self.cancelWaiter(waiterID) }
            })
        }

        func close() {
            guard !isClosed else { return }
            isClosed = true
            waiter?.1.resume(returning: nil)
            waiter = nil
            queued.removeAll(keepingCapacity: false)
        }

        private func dequeue() -> Signal? {
            if let index = queued.firstIndex(where: { signal in
                if case .control = signal { return true }
                return false
            }) {
                return queued.remove(at: index)
            }
            if let index = queued.firstIndex(where: { signal in
                if case .session = signal { return true }
                return false
            }) {
                return queued.remove(at: index)
            }
            guard !queued.isEmpty else { return nil }
            return queued.removeFirst()
        }

        private func cancelWaiter(_ waiterID: UUID) {
            guard waiter?.0 == waiterID, let waiter else { return }
            self.waiter = nil
            waiter.1.resume(returning: nil)
        }
    }

    private actor InputPumpGate {
        private var isAllowed = true
        private var isClosed = false
        private var waiter: (UUID, CheckedContinuation<Bool, Never>)?

        func pause() {
            isAllowed = false
        }

        func resume() {
            guard !isClosed else { return }
            isAllowed = true
            waiter?.1.resume(returning: true)
            waiter = nil
        }

        func waitUntilAllowed() async -> Bool {
            if isClosed { return false }
            if isAllowed { return true }
            let waiterID = UUID()
            return await withTaskCancellationHandler(operation: {
                await withCheckedContinuation { continuation in
                    if isClosed {
                        continuation.resume(returning: false)
                    } else if isAllowed {
                        continuation.resume(returning: true)
                    } else {
                        waiter = (waiterID, continuation)
                    }
                }
            }, onCancel: {
                Task { await self.cancelWaiter(waiterID) }
            })
        }

        func close() {
            guard !isClosed else { return }
            isClosed = true
            waiter?.1.resume(returning: false)
            waiter = nil
        }

        private func cancelWaiter(_ waiterID: UUID) {
            guard waiter?.0 == waiterID, let waiter else { return }
            self.waiter = nil
            waiter.1.resume(returning: false)
        }
    }

    private let input: AsyncThrowingStream<InputEvent, Error>
    private let runtime: any OpenGrokPagerRuntimeAdapter
    private let renderer: any OpenGrokPagerInteractiveRenderAdapter
    private let output: any OpenGrokPagerInteractiveOutputAdapter

    private var lifecycle: OpenGrokPagerInteractiveLifecycle = .idle
    private var editor = PromptEditor(text: "")
    /// Last content rect applied via `.composerMouse` or queried from the
    /// renderer on a drag-autoscroll tick. Never a second TextArea.
    private var lastComposerContentRect: TextAreaRect?
    private var lastPromptClickTime: Date?
    private var submittedPrompts: [String] = []
    private var completedTurnCount = 0
    private var currentRequest: OpenGrokPagerRequest?
    private var activeSessionID: String?
    private var lastSessionID: String?
    /// The render mode this run launched under, for the `/minimal` /
    /// `/fullscreen` ModeSupport gate (`mode_support.rs:30-36` at pin
    /// 650c1db7: FullscreenOnly means NOT-minimal — inline counts as the
    /// fullscreen family). Session-fixed: a mode switch is a re-exec, never
    /// an in-process transition.
    private var activePagerMode: OpenGrokPagerMode?
    /// The launch request's session id — the relaunch fallback when no turn
    /// has run yet (`activeSessionID`/`lastSessionID` are still nil on a
    /// fresh interactive session that has typed only the switch command).
    private var launchSessionID: String?
    private var terminalRestored = false
    private var running = false
    private var rendererBegan = false
    private var shutdownRequested = false
    private var activeSession: (any OpenGrokPagerSessionAdapter)?
    private var activeSessionCancelled = false
    private var activeSessionClosed = false
    /// Monotonic turn counter stamped onto `.session` signals; see `Signal`.
    private var turnGeneration: UInt64 = 0
    private var signalMailbox: SignalMailbox?
    private var inputPumpGate: InputPumpGate?
    private var inputPump: Task<Void, Never>?

    /// Every prompt the user submits goes through the queue, whether the shell
    /// was idle or busy when they pressed Enter. An idle submit enqueues and
    /// drains in the same breath, so there is a single ordering authority and
    /// the drain path is not a second, subtly different code path.
    private let promptQueue = PromptQueue(sessionId: "interactive")
    private var nextPromptSequence = 0
    /// Cross-tab dashboard dispatches that arrived while a turn was active.
    /// They run in arrival order after the active turn settles; the runtime
    /// activates each retained session before its prompt is enqueued.
    private enum DeferredDashboardDispatch: Sendable {
        case existing(sessionID: String, prompt: String)
        case new(prompt: String, workingDirectory: String?)
    }

    private var deferredSessionDispatches: [DeferredDashboardDispatch] = []

    /// Prompt history, oldest first. `historyIndex` is the browse cursor;
    /// `historySavedDraft` is the composer text stashed when browsing opened,
    /// restored when the user pages back past the newest entry.
    private var history: [String] = []
    private var historyIndex: Int?
    private var historySavedDraft: String?

    /// An armed double-press confirmation and the instant it expires.
    private var pendingConfirmation: (key: String, label: String, deadline: Date)?

    /// What the render layer last reported as moving on screen. Merged with
    /// the controller's own turn state in `currentMotionDemand()`; the
    /// controller cannot see a visible running block or the welcome logo, and
    /// the renderer cannot see a turn that has produced no events yet, so
    /// neither view alone is the truth.
    private var externalMotionState = PagerMotionState()
    /// `[animation].fps` (`appearance/config.rs:371-397`), clamped 1...60.
    private var motionFPS = PagerMotion.defaultFPS
    /// The motion epoch, as monotonic uptime nanoseconds. The animation tick
    /// is `elapsed / tickInterval` — derived from this wall clock, never from
    /// an event counter, so a silent turn cannot freeze the spinner.
    private var motionEpochNanos: UInt64?
    /// The demand-driven ticker (`schedule_tick`, `event_loop.rs:3172-3189`).
    /// `nil` exactly when no tick is armed, which is the idle case and the
    /// reason a still screen costs no wakeups.
    private var motionTicker: Task<Void, Never>?
    /// Explicit hold for `/transcript` / `$EDITOR` suspend: forces demand to
    /// `.none` and blocks `armMotionTickerIfNeeded` so a mid-suspend
    /// `setMotionState(.fast)` cannot re-arm wakeups into a torn-down tty.
    /// Cleared by `resumeMotionTicker`. Distinct from `PagerMotionState.motionEnabled`
    /// (terminal capability) and from `motionShutdownLatched` (run teardown).
    private var motionSuspended = false
    /// Permanent-for-run latch set at teardown so a racing
    /// `resumeMotionTicker` from a suspended child cannot clear the ordinary
    /// suspend hold and re-arm while `running` is still true. Cleared only at
    /// the next `run` start — never by resume.
    private var motionShutdownLatched = false
    /// Bumped each time a ticker Task is armed. Suspend/teardown await the
    /// cancelled generation and only nil `motionTicker` when it still matches,
    /// so a reentrant resume that armed a newer task is not erased.
    private var motionTickerGeneration: UInt64 = 0

    /// Dedicated mouse-scroll flush clock. Never shares the motion ticker:
    /// scroll coalescing must keep waking while motion demand is `.none`.
    /// `nil` exactly when no scroll deadline is armed.
    private var scrollTicker: Task<Void, Never>?
    /// Same generation discipline as `motionTickerGeneration`: suspend /
    /// teardown / re-arm cancel the prior task and only nil the slot when the
    /// cancelled generation still owns it.
    private var scrollTickerGeneration: UInt64 = 0

    /// Slash-command recency. Defaults to the in-memory store, exactly like
    /// upstream's default controllers (`mru.rs:9-10`); the live composition
    /// injects the disk-backed store via `setSlashMru`.
    private var slashMru = PagerSlashMru()

    /// Which region owns the keyboard. `Tab` moves it; nothing else does.
    private var focus: OpenGrokPagerFocusRegion = .prompt
    private var modes = OpenGrokPagerInputModes()

    /// The live mid-turn interjection seam, installed by the composition.
    /// The controller consumes it only at turn end (`collectStranded` →
    /// fallback prompt turns); the producers live in the render layer's
    /// stack (the subagent collaboration quartet). `nil` means no live
    /// session and nothing to flush. Enter-steers does not come here: it is
    /// cancel-and-send per upstream (`prompt.rs:616-631`,
    /// `defaults.rs:630-632`).
    private var interjectionSeam: OpenGrokPagerInterjectionSeam?

    /// The scheduler task id of the RUNNING cron turn, if any — upstream's
    /// `agent.cron_task_id` (`app/dispatch/queue.rs:340-344`), the second
    /// half of the fire de-dup: a re-fire of the task that is currently
    /// executing is skipped, not queued.
    private var runningCronTaskID: String?

    private let commands: PagerCommandRegistry
    private let paletteRows: [OpenGrokPagerCommandSuggestion]
    private let customCommandNames: Set<String>
    private let customCommandHandler: CustomCommandHandler?
    private let localCommandNames: Set<String>
    private let localCommandHandler: LocalCommandHandler?
    /// Startup-cached `[ui] mouse_reporting_toggle` / `GROK_MOUSE_REPORTING_TOGGLE`
    /// gate. Seeds command visibility and the scrollback-only `Ctrl+R`
    /// binding; live `mouse_reporting` enable/disable is a separate flag on
    /// the render layer.
    private let mouseReportingToggleEnabled: Bool

    /// Completions for the *arguments* of a command whose name is already
    /// typed, as `(command, argumentQuery) -> rows`.
    ///
    /// The controller owns the command vocabulary but none of the vocabularies
    /// the arguments come from — it cannot name a model any more than the
    /// render layer can. So the host supplies this and does its own matching;
    /// the controller only decides *when* the prompt is in the argument phase.
    /// Upstream's equivalent is `SlashCommand::suggest_args`
    /// (`slash/command.rs`), which `/model` implements by listing the catalog.
    private var argumentSuggestions: (
        @Sendable (String, String) -> [OpenGrokPagerCommandSuggestion]
    )?

    /// Whether the session is effectively in plan mode right now, read from
    /// the live plan tracker — the same one the `enter_plan_mode` tool arms —
    /// so `/plan <description>`'s already-in-plan refusal
    /// (`dispatch/modes.rs:48-52`) and the tool path can never disagree. A
    /// controller-side mirror would be exactly the parallel flag the tool
    /// path cannot see. `nil` (compositions with no live plan state)
    /// resolves to false, so `/plan <description>` arms-and-sends there.
    private var planModeState: (@Sendable () async -> Bool)?

    /// Live swarm-mode state for `/swarm`'s bare toggle — the controller
    /// resolves the target state against the tracker the session actually
    /// consults, never a controller-side mirror the tool trigger cannot
    /// see. `nil` (compositions with no live swarm state) resolves to
    /// false, so a bare `/swarm` there enables.
    private var swarmModeState: (@Sendable () async -> Bool)?

    /// Whether the running turn is parked in an orchestration wait (an
    /// `agent_swarm` cohort). The send-now paths read it: an arriving
    /// prompt is promoted to run next but must NOT cancel the turn,
    /// because cancelling would kill every live member — upstream's
    /// `cancel_running_turn = send_now && … && !orchestrating`
    /// (prompt_queue.rs:222-233). `nil` resolves to false: without a live
    /// wait state, send-now keeps its cancel-and-run behavior.
    private var orchestrationWaitState: (@Sendable () async -> Bool)?

    public init(
        input: AsyncThrowingStream<InputEvent, Error>,
        runtime: any OpenGrokPagerRuntimeAdapter,
        renderer: any OpenGrokPagerInteractiveRenderAdapter,
        output: any OpenGrokPagerInteractiveOutputAdapter,
        customCommands: [OpenGrokPagerCommandRegistration] = [],
        customCommandHandler: CustomCommandHandler? = nil,
        localCommands: [OpenGrokPagerCommandRegistration] = [],
        localCommandHandler: LocalCommandHandler? = nil,
        workflowsEnabled: Bool = true,
        mouseReportingToggleEnabled: Bool = false
    ) {
        self.input = input
        self.runtime = runtime
        self.renderer = renderer
        self.output = output
        self.mouseReportingToggleEnabled = mouseReportingToggleEnabled
        let definitions = customCommands.map { registration in
            PagerCommandDefinition(
                name: registration.name,
                aliases: registration.aliases,
                summary: registration.summary,
                usage: registration.usage
            )
        }
        let builtinCommands = Self.sessionBuiltinCommands(
            workflowsEnabled: workflowsEnabled,
            mouseReportingToggleEnabled: mouseReportingToggleEnabled
        )
        self.commands = PagerCommandRegistry(
            commands: builtinCommands + definitions + localCommands.map { registration in
                PagerCommandDefinition(
                    name: registration.name,
                    aliases: registration.aliases,
                    summary: registration.summary,
                    usage: registration.usage
                )
            }
        )
        self.paletteRows = builtinCommands
            .filter { !$0.isHidden }
            .map { command in
                OpenGrokPagerCommandSuggestion(
                    name: "/\(command.name)",
                    summary: command.summary,
                    insertText: "/\(command.name)"
                )
            }
        self.customCommandNames = Set(definitions.map(\.name))
        self.customCommandHandler = customCommandHandler
        self.localCommandNames = Set(localCommands.map { PagerCommandDefinition.normalize($0.name) })
        self.localCommandHandler = localCommandHandler
    }

    public init(
        input: AsyncStream<InputEvent>,
        runtime: any OpenGrokPagerRuntimeAdapter,
        renderer: any OpenGrokPagerInteractiveRenderAdapter,
        output: any OpenGrokPagerInteractiveOutputAdapter,
        customCommands: [OpenGrokPagerCommandRegistration] = [],
        customCommandHandler: CustomCommandHandler? = nil,
        localCommands: [OpenGrokPagerCommandRegistration] = [],
        localCommandHandler: LocalCommandHandler? = nil,
        workflowsEnabled: Bool = true,
        mouseReportingToggleEnabled: Bool = false
    ) {
        self.init(
            input: Self.makeThrowingStream(from: input),
            runtime: runtime,
            renderer: renderer,
            output: output,
            customCommands: customCommands,
            customCommandHandler: customCommandHandler,
            localCommands: localCommands,
            localCommandHandler: localCommandHandler,
            workflowsEnabled: workflowsEnabled,
            mouseReportingToggleEnabled: mouseReportingToggleEnabled
        )
    }

    /// Install the argument-completion source. Call before `run`.
    public func setArgumentSuggestions(
        _ provider: (@Sendable (String, String) -> [OpenGrokPagerCommandSuggestion])?
    ) {
        argumentSuggestions = provider
    }

    /// Install the live plan-mode state source for `/plan <description>`'s
    /// already-in-plan refusal. Call before `run`.
    public func setPlanModeStateProvider(
        _ provider: (@Sendable () async -> Bool)?
    ) {
        planModeState = provider
    }

    /// Install the live swarm-mode state source for `/swarm`'s bare
    /// toggle. Call before `run`.
    public func setSwarmModeStateProvider(
        _ provider: (@Sendable () async -> Bool)?
    ) {
        swarmModeState = provider
    }

    /// Install the live orchestration-wait source for the send-now cancel
    /// exemption. Call before `run`.
    public func setOrchestrationWaitStateProvider(
        _ provider: (@Sendable () async -> Bool)?
    ) {
        orchestrationWaitState = provider
    }

    /// Install the live mid-turn interjection seam. Call before `run`.
    /// The controller's only remaining use is the turn-end stranded flush:
    /// the seam's producers live below the controller (the subagent
    /// collaboration quartet in the render layer's stack). `/btw` no longer
    /// produces here — it is a SIDE question routed through the
    /// `.sideQuestion` overlay intent, never into the running turn.
    public func setInterjectionSeam(_ seam: OpenGrokPagerInterjectionSeam?) {
        interjectionSeam = seam
    }

    /// Prompt-id prefix for interjections converted into standalone prompt
    /// turns (arrived while idle, or stranded past the running turn's final
    /// drain). Byte-identical to upstream's `INTERJECT_FALLBACK_PROMPT_PREFIX`
    /// (interjection.rs:25); the prefix keeps the fallback turn's user echo
    /// persist-only, because the pager already painted the text at dispatch.
    public static let interjectFallbackPromptPrefix = "interject-fallback-"

    /// Metadata key stamped onto a fallback turn's request so the renderer
    /// skips the user-block half of the turn-start paint — this port's
    /// carrier for upstream's persist-only user echo (interjection.rs:20-24).
    /// The value is the queue entry's full `interject-fallback-…` id.
    public static let interjectionFallbackMetadataKey = "interjectionFallbackPromptID"

    /// Queue-entry kind for a scheduler-fired ("cron") prompt — upstream's
    /// `QueueEntryKind::Cron` wire label (`views/queue_pane.rs:102-108`).
    public static let cronQueueEntryKind = "cron"

    /// Prompt-id prefix for a cron turn, byte-identical to upstream's
    /// `scheduler-fired-` (`app/dispatch/queue.rs:519`). The runtime adapter
    /// stamps it on the shell turn request, and the turn loop derives the
    /// `schedulerFired` persistence tag from it — the port of
    /// `PromptOrigin::from_prompt_id` (`session/mod.rs:126-127`).
    public static let schedulerFiredPromptIDPrefix = "scheduler-fired-"

    /// Metadata keys stamped onto a cron turn's request. The runtime adapter
    /// reads them to frame the model prompt (`format_scheduled_task_prompt`)
    /// and tag the turn's persistence; the request's own `prompt` stays the
    /// RAW text so the turn-start user echo paints what the user scheduled
    /// (upstream's `DISPLAY_TEXT` meta, `app/dispatch/queue.rs:538-546`).
    public static let cronTaskIDMetadataKey = "schedulerCronTaskID"
    public static let cronHumanScheduleMetadataKey = "schedulerCronHumanSchedule"

    /// Queue-entry kind for a monitor-event wake. RECORDED DIVERGENCE from
    /// upstream, which never routes monitor events through the pager queue:
    /// its bridge sends `SessionCommand::InjectNotification` into the
    /// SESSION's own prompt machinery (`notification_bridge.rs:776-789`),
    /// invisible to the queue pane. This port's controller queue is its only
    /// idle-wake seam, so an idle monitor event rides it as its own entry
    /// (briefly visible in the `+n` count — the named cost).
    public static let monitorQueueEntryKind = "monitor"

    /// Prompt-id prefix for a monitor-event turn — upstream's
    /// `format!("monitor-{task_id}-{uuid}")` (notification_bridge.rs:776).
    /// `PromptOrigin::from_prompt_id` has no `monitor-` arm upstream
    /// (session/mod.rs:103-133), so these turns persist as plain user items
    /// there and here.
    public static let monitorPromptIDPrefix = "monitor-"

    /// Metadata key stamped onto a monitor turn's request: the runtime
    /// adapter sends the (already `<monitor-event>`-wrapped) text verbatim
    /// under a `monitor-` prompt id instead of framing it as a cron prompt.
    public static let monitorTaskIDMetadataKey = "monitorEventTaskID"

    /// Report what the render layer knows is in motion — visible running
    /// blocks, the welcome logo, background-task chips, and whether the
    /// terminal can animate at all. Callable at any time, including mid-run;
    /// a rising demand arms the ticker, a falling one lets it park itself.
    /// While `suspendMotionTicker` holds, the state is recorded but the
    /// ticker stays dark — resume re-arms from whatever demand is current.
    public func setMotionState(_ state: PagerMotionState) {
        externalMotionState = state
        armMotionTickerIfNeeded()
    }

    /// Set the animation tick rate (`[animation].fps`). Call before `run`;
    /// the tick derivation divides wall time by this, so changing it mid-run
    /// would make the tick counter jump.
    public func setMotionFPS(_ fps: Int) {
        motionFPS = min(max(fps, PagerMotion.minimumFPS), PagerMotion.maximumFPS)
    }

    /// Park the wall-clock motion ticker and the dedicated scroll ticker for
    /// a suspended-TUI child (`/transcript`, `$EDITOR`). Cancel+await both
    /// in-flight tasks so no further `renderAnimationTick` /
    /// `handleScrollClockTick` can race terminal teardown; keep the motion
    /// epoch, `externalMotionState`, and the renderer's `MouseScrollState`
    /// so resume continues the same clocks. Idempotent: a second suspend
    /// while held is a no-op once both tickers are already nil. Safe after
    /// shutdown — `running` is already false and the tickers are gone. Does
    /// not touch `motionShutdownLatched`.
    public func suspendMotionTicker() async {
        motionSuspended = true
        cancelComposerMouseGesture()
        let motionGeneration = motionTickerGeneration
        let cancelledMotion = motionTicker
        cancelledMotion?.cancel()
        let scrollGeneration = scrollTickerGeneration
        let cancelledScroll = scrollTicker
        cancelledScroll?.cancel()
        if let cancelledMotion {
            _ = await cancelledMotion.value
        }
        if let cancelledScroll {
            _ = await cancelledScroll.value
        }
        // A reentrant `resumeMotionTicker` may have armed a newer task while
        // we awaited; only clear when this suspend still owns the slot.
        if motionTickerGeneration == motionGeneration {
            motionTicker = nil
        }
        if scrollTickerGeneration == scrollGeneration {
            scrollTicker = nil
        }
    }

    /// Lift the ordinary suspend hold, re-arm motion from current demand, and
    /// re-query the renderer's scroll deadline (tty is restored; an active
    /// scroll stream must keep flushing). Idempotent when already resumed.
    /// A no-op when teardown has latched `motionShutdownLatched` — must not
    /// clear that latch or re-arm into a run that is restoring the terminal.
    /// After a clean shutdown, arm helpers also require `running`.
    public func resumeMotionTicker() async {
        guard !motionShutdownLatched else { return }
        motionSuspended = false
        armMotionTickerIfNeeded()
        await refreshScrollClockFromRenderer()
    }

    /// Install the slash-command MRU store. Call before `run`. Without this
    /// the controller uses an isolated in-memory store — recency boosts work
    /// within the session but do not persist, mirroring upstream's default
    /// controllers (`mru.rs:9-10`).
    public func setSlashMru(_ mru: PagerSlashMru) {
        slashMru = mru
    }

    public func state() -> OpenGrokPagerInteractiveState {
        OpenGrokPagerInteractiveState(
            lifecycle: lifecycle,
            prompt: promptState(),
            submittedPrompts: submittedPrompts,
            completedTurnCount: completedTurnCount,
            activeSessionID: activeSessionID,
            lastSessionID: lastSessionID,
            terminalRestored: terminalRestored,
            focus: focus,
            modes: modes
        )
    }

    /// Replace the runtime-toggleable mode snapshot before or during `run`.
    ///
    /// A mid-run call is safe because the controller is an actor and the input
    /// loop reads `modes` at await points. The cost is that a mode flip lands
    /// between keystrokes, never midway through one keystroke.
    public func setInputModes(_ newModes: OpenGrokPagerInputModes) {
        modes = newModes
        editor.isMultiline = newModes.isMultiline
    }

    /// Replace the composer draft (voice finals, paste helpers). Emits
    /// `.promptChanged` so the renderer stays in sync with the editor.
    public func replacePromptDraft(_ text: String) async {
        editor.replace(with: text)
        do {
            try await emit(.promptChanged(promptState()))
        } catch {
            // A failed prompt publish must not kill the voice pipeline; the
            // next keystroke will refresh from the editor anyway.
        }
    }

    public func run(_ request: OpenGrokPagerRequest) async throws -> OpenGrokPagerInteractiveResult {
        try await run(initialSession: nil, request: request)
    }

    public func run(
        initialSession: any OpenGrokPagerSessionAdapter,
        request: OpenGrokPagerRequest
    ) async throws -> OpenGrokPagerInteractiveResult {
        try await run(initialSession: Optional(initialSession), request: request)
    }

    public func cancel() async {
        guard running else { return }
        lifecycle = .cancelling
        await signalMailbox?.send(.control(.cancel), priority: true)
        await cancelActiveSession()
    }

    public func shutdown() async {
        shutdownRequested = true
        guard running else {
            lifecycle = .shutdown
            return
        }
        lifecycle = .cancelling
        await signalMailbox?.send(.control(.shutdown), priority: true)
        await cancelActiveSession()
    }

    private func run(
        initialSession: (any OpenGrokPagerSessionAdapter)?,
        request: OpenGrokPagerRequest
    ) async throws -> OpenGrokPagerInteractiveResult {
        guard !running else { throw OpenGrokPagerInteractiveError.alreadyRunning }
        guard !shutdownRequested else { throw OpenGrokPagerInteractiveError.shutdown }

        running = true
        // A prior run's teardown sets `motionShutdownLatched` (and may leave
        // `motionSuspended`) so a racing resume cannot re-arm into restore;
        // clear both for this run before anything can demand frames.
        motionShutdownLatched = false
        motionSuspended = false
        deferredSessionDispatches.removeAll(keepingCapacity: true)
        currentRequest = request
        activePagerMode = request.mode
        launchSessionID = request.sessionID
        rendererBegan = false
        terminalRestored = false
        // One epoch per run: every animation frame's tick and seconds are
        // measured from here, so all motion styles share one clock.
        motionEpochNanos = DispatchTime.now().uptimeNanoseconds
        let mailbox = SignalMailbox()
        signalMailbox = mailbox
        let inputReader = ThrowingStreamReader(input)
        let inputPumpGate = InputPumpGate()
        self.inputPumpGate = inputPumpGate
        let renderer = self.renderer
        // Session-fixed (a mode switch is a re-exec), so the pump captures
        // the value instead of hopping the actor per keystroke.
        let minimalInterceptsKeys = request.mode == .minimal
        inputPump = Task {
            while !Task.isCancelled {
                guard await inputPumpGate.waitUntilAllowed() else { return }
                let read = await inputReader.next()
                await inputPumpGate.pause()
                switch read {
                case .element(let event):
                    // Overlays and the mouse router get first refusal, ahead of
                    // both the interrupt classifier and the prompt state
                    // machine. Ctrl+C / Ctrl+D are deliberately exempt so a
                    // modal can never trap the session.
                    let isEscapeHatch: Bool
                    switch Self.controlAction(for: event) {
                    case .some(.interrupt), .some(.eof): isEscapeHatch = true
                    default: isEscapeHatch = false
                    }
                    if !isEscapeHatch {
                        // Do not `try?` here: a swallowed restore/terminal
                        // failure would leave local and controller motion
                        // holds latched while the run continues. Surface the
                        // error like other pump I/O failures and stop.
                        let routing: OpenGrokPagerInputRouting
                        do {
                            routing = try await renderer.handleInput(event)
                        } catch {
                            await mailbox.send(
                                .input(.failure(String(describing: error))),
                                priority: true
                            )
                            return
                        }
                        switch routing {
                        case .consumed:
                            self.cancelComposerMouseGesture()
                            // Scroll coalescing lives in the renderer
                            // (`MouseScrollState`). Re-query after cancel so
                            // a dropped composer pollTimeout parks the ticker.
                            await self.refreshScrollClockFromRenderer()
                            await inputPumpGate.resume()
                            continue
                        case .focusScrollback:
                            self.cancelComposerMouseGesture()
                            await self.refreshScrollClockFromRenderer()
                            // Click-to-select (and any other render-side focus
                            // claim) must move the controller's focus region
                            // so Tab/j/k agree with the painted selection.
                            // `setFocus` emits `.focusChanged`, which is what
                            // keeps the renderer's selection state in sync;
                            // when focus is already on the scrollback it is
                            // a no-op and the index the renderer just set
                            // stays. Propagate emit failures through the
                            // mailbox like other pump I/O errors — a silent
                            // `try?` would leave composer focus with a
                            // painted scrollback selection (Tab/j/k disagree).
                            do {
                                try await self.setFocus(.scrollback)
                            } catch {
                                await mailbox.send(
                                    .input(.failure(String(describing: error))),
                                    priority: true
                                )
                                return
                            }
                            await inputPumpGate.resume()
                            continue
                        case .focusComposer:
                            self.cancelComposerMouseGesture()
                            await self.refreshScrollClockFromRenderer()
                            // Chrome / prefix / collapsed-unfocused: focus
                            // the prompt without moving the caret.
                            do {
                                try await self.applyFocusComposer()
                            } catch {
                                await mailbox.send(
                                    .input(.failure(String(describing: error))),
                                    priority: true
                                )
                                return
                            }
                            await inputPumpGate.resume()
                            continue
                        case .composerMouse(let claim):
                            do {
                                try await self.applyComposerMouse(claim)
                            } catch {
                                await mailbox.send(
                                    .input(.failure(String(describing: error))),
                                    priority: true
                                )
                                return
                            }
                            // Re-arm AFTER apply: TextArea may have just set
                            // `pendingDragScroll` / `pollTimeoutMs`. Querying
                            // before apply misses a newly armed edge autoscroll.
                            await self.refreshScrollClockFromRenderer()
                            await inputPumpGate.resume()
                            continue
                        case .runCommand(let text):
                            self.cancelComposerMouseGesture()
                            await self.refreshScrollClockFromRenderer()
                            // The gate stays paused: whichever loop services the
                            // control signal resumes it, exactly as for an
                            // interrupt.
                            await mailbox.send(.control(.command(text)), priority: true)
                            continue
                        case .dispatchPrompt(let sessionID, let prompt):
                            self.cancelComposerMouseGesture()
                            await self.refreshScrollClockFromRenderer()
                            await mailbox.send(
                                .control(.dispatch(sessionID: sessionID, prompt: prompt)),
                                priority: true
                            )
                            continue
                        case .dispatchNew(let prompt, let workingDirectory):
                            self.cancelComposerMouseGesture()
                            await self.refreshScrollClockFromRenderer()
                            await mailbox.send(
                                .control(.dispatchNew(
                                    prompt: prompt,
                                    workingDirectory: workingDirectory
                                )),
                                priority: true
                            )
                            continue
                        case .notHandled:
                            self.cancelComposerMouseGesture()
                            await self.refreshScrollClockFromRenderer()
                            break
                        }
                    }
                    // Minimal-only Ctrl+E, intercepted BEFORE the composer —
                    // upstream's `minimal_key_intercept`
                    // (`app_view.rs:4758-4759`, gated on `is_minimal()` at
                    // `:3261`). It rides the `/expand` command signal so the
                    // dispatch (and its ring) stays in one place. Cost,
                    // upstream's own: the composer's readline end-of-line
                    // chord is unavailable in minimal (Home/End remain).
                    // Overlays kept first refusal above, so a modal still
                    // sees its own keys.
                    if minimalInterceptsKeys,
                       case .key(let keyEvent) = event,
                       keyEvent.modifiers.contains(.control),
                       Self.controlCharacter(of: keyEvent) == "e" {
                        await mailbox.send(.control(.command("/expand")), priority: true)
                        continue
                    }
                    switch Self.controlAction(for: event) {
                    case .some(.escape):
                        await mailbox.send(.control(.interrupt(isEscape: true)), priority: true)
                    case .some(.interrupt):
                        await mailbox.send(.control(.interrupt(isEscape: false)), priority: true)
                    case .some(.eof):
                        await mailbox.send(.control(.eof), priority: true)
                    default:
                        await mailbox.send(.input(read))
                    }
                case .end, .failure, .cancelled:
                    await mailbox.send(.input(read))
                    return
                }
            }
        }
        var outcome: OpenGrokPagerInteractiveLifecycle = .completed
        var runError: Error?

        do {
            try await renderer.begin()
            rendererBegan = true
            try await transition(to: .starting)
            editor = PromptEditor(text: request.prompt)
            // A fresh editor starts in single-line mode; anything seeded by
            // `setInputModes` has to survive the rebuild or `/multiline` would
            // silently reset itself at the top of every run.
            editor.isMultiline = modes.isMultiline
            try await emit(.promptChanged(promptState()))

            if let initialSession {
                let initialRequest = request
                if !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    submittedPrompts.append(request.prompt)
                }
                // The opening turn owns a session the caller already built, so
                // it cannot go through the drain loop; only what it leaves
                // behind in the queue can.
                editor.reset()
                let turnOutcome = try await runTurn(
                    session: initialSession,
                    request: initialRequest,
                    mailbox: mailbox,
                    inputPumpGate: inputPumpGate
                )
                switch try await apply(
                    turnOutcome: turnOutcome,
                    inputPumpGate: inputPumpGate
                ) {
                case .end(let lifecycle):
                    outcome = lifecycle
                case .keepEditing:
                    break
                case .drainNext:
                    if let lifecycle = try await drainQueue(
                        request: request,
                        mailbox: mailbox,
                        inputPumpGate: inputPumpGate
                    ) {
                        outcome = lifecycle
                    }
                }
            } else {
                try await transition(to: .editing)
            }

            while outcome == .completed {
                try Task.checkCancellation()
                guard let signal = await mailbox.next() else {
                    try await discardQueue(reason: "input ended")
                    try await emit(.eof)
                    outcome = .eof
                    continue
                }
                switch signal {
                case .session:
                    continue
                case .control(let control):
                    switch control {
                    case .interrupt(let isEscape):
                        switch handleInterrupt(isEscape: isEscape, isTurnRunning: false) {
                        case .quit:
                            try await discardQueue(reason: "quitting")
                            try await emit(.cancelled)
                            outcome = .cancelled
                        case .consumed, .cancelTurn:
                            try await emit(.promptChanged(promptState()))
                            await inputPumpGate.resume()
                        }
                    case .cancel:
                        try await discardQueue(reason: "run cancelled")
                        try await emit(.cancelled)
                        outcome = .cancelled
                    case .eof:
                        try await discardQueue(reason: "input ended")
                        try await emit(.eof)
                        outcome = .eof
                    case .shutdown:
                        try await discardQueue(reason: "shutting down")
                        try await emit(.shutdown)
                        outcome = .shutdown
                    case .command(let text):
                        switch try await runSlashCommand(text) {
                        case .quit:
                            try await discardQueue(reason: "quitting")
                            try await emit(.shutdown)
                            outcome = .shutdown
                        case .submit(let generatedPrompt):
                            try await enqueue(generatedPrompt, historyText: text)
                            if let lifecycle = try await drainQueue(
                                request: request,
                                mailbox: mailbox,
                                inputPumpGate: inputPumpGate
                            ) {
                                outcome = lifecycle
                            }
                        case .drain:
                            // An interjection fallback prompt waits at the
                            // front; idle means this loop must start it.
                            if let lifecycle = try await drainQueue(
                                request: request,
                                mailbox: mailbox,
                                inputPumpGate: inputPumpGate
                            ) {
                                outcome = lifecycle
                            }
                        case .handled, .notACommand:
                            // The draft is deliberately untouched — upstream's
                            // `SendSlashCommandPreservingDraft`.
                            try await emit(.promptChanged(promptState()))
                            await inputPumpGate.resume()
                        }
                    case .dispatch(let sessionID, let prompt):
                        if let lifecycle = try await dispatchDashboardPrompt(
                            sessionID: sessionID,
                            prompt: prompt,
                            request: request,
                            mailbox: mailbox,
                            inputPumpGate: inputPumpGate
                        ) {
                            outcome = lifecycle
                        }
                    case .dispatchNew(let prompt, let workingDirectory):
                        if let lifecycle = try await dispatchNewDashboardPrompt(
                            prompt: prompt,
                            workingDirectory: workingDirectory,
                            request: request,
                            mailbox: mailbox,
                            inputPumpGate: inputPumpGate
                        ) {
                            outcome = lifecycle
                        }
                    case .cronEnqueued:
                        // A scheduler fire queued a Cron prompt while idle;
                        // this loop must start it (the `.drain` shape) — the
                        // port of `maybe_drain_queue` running the cron entry
                        // when no turn holds the session.
                        if let lifecycle = try await drainQueue(
                            request: request,
                            mailbox: mailbox,
                            inputPumpGate: inputPumpGate
                        ) {
                            outcome = lifecycle
                        }
                    }
                case .input(let read):
                    switch read {
                    case .element(let event):
                        // The scrollback gets the key first when it has focus,
                        // and never hands one back to the composer.
                        if try await handleScrollbackEvent(event) {
                            await inputPumpGate.resume()
                            continue
                        }
                        let action = applyEditorEvent(event)
                        switch action {
                        case .changed, .historyPrevious, .historyNext,
                             .completionMove, .completionAccept,
                             // `.completionCommit` is rewritten to `.submit`
                             // or `.changed` inside `applyEditorEvent`; listed
                             // for exhaustiveness, reached never.
                             .completionCommit:
                            try await emit(.promptChanged(promptState()))
                            await inputPumpGate.resume()
                        case .focusScrollback:
                            try await setFocus(.scrollback)
                            await inputPumpGate.resume()
                        case .toggleMultiline:
                            try await setMultiline(!modes.isMultiline)
                            await inputPumpGate.resume()
                        case .global(let command):
                            try await handleGlobal(command, isTurnRunning: false)
                            await inputPumpGate.resume()
                        case .viewport(let command):
                            try await emit(.viewport(command))
                            await inputPumpGate.resume()
                        case .escape, .interrupt:
                            let isEscape: Bool
                            if case .escape = action { isEscape = true } else { isEscape = false }
                            switch handleInterrupt(isEscape: isEscape, isTurnRunning: false) {
                            case .quit:
                                try await discardQueue(reason: "quitting")
                                try await emit(.cancelled)
                                outcome = .cancelled
                                continue
                            case .consumed, .cancelTurn:
                                try await emit(.promptChanged(promptState()))
                                await inputPumpGate.resume()
                            }
                        case .submit:
                            let prompt = editor.text
                            guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                                // Nothing to send and nothing queued — the
                                // send-now path only exists during a turn.
                                try await emit(.notice("prompt cannot be empty"))
                                await inputPumpGate.resume()
                                continue
                            }
                            switch try await runSlashCommand(prompt) {
                            case .quit:
                                try await discardQueue(reason: "quitting")
                                try await emit(.shutdown)
                                outcome = .shutdown
                                continue
                            case .submit(let generatedPrompt):
                                try await enqueue(generatedPrompt, historyText: prompt)
                                if let lifecycle = try await drainQueue(
                                    request: request,
                                    mailbox: mailbox,
                                    inputPumpGate: inputPumpGate
                                ) {
                                    outcome = lifecycle
                                }
                                continue
                            case .drain:
                                // An interjection fallback prompt waits at
                                // the front; idle means this loop must start
                                // it — the port of `maybe_start_running_task`
                                // (run_loop.rs:1984-1988).
                                recordHistory(prompt)
                                editor.reset()
                                try await emit(.promptChanged(promptState()))
                                if let lifecycle = try await drainQueue(
                                    request: request,
                                    mailbox: mailbox,
                                    inputPumpGate: inputPumpGate
                                ) {
                                    outcome = lifecycle
                                }
                                continue
                            case .handled:
                                recordHistory(prompt)
                                editor.reset()
                                try await emit(.promptChanged(promptState()))
                                await inputPumpGate.resume()
                                continue
                            case .notACommand:
                                break
                            }
                            try await enqueue(prompt)
                            if let lifecycle = try await drainQueue(
                                request: request,
                                mailbox: mailbox,
                                inputPumpGate: inputPumpGate
                            ) {
                                outcome = lifecycle
                            }
                        case .eof:
                            try await discardQueue(reason: "input ended")
                            try await emit(.eof)
                            outcome = .eof
                        case .resize(let size):
                            try await renderer.resize(to: size)
                            await inputPumpGate.resume()
                        case .ignored:
                            await inputPumpGate.resume()
                            continue
                        }
                    case .end:
                        try await discardQueue(reason: "input ended")
                        try await emit(.eof)
                        outcome = .eof
                    case .failure(let message):
                        throw OpenGrokPagerInteractiveError.inputFailed(message)
                    case .cancelled:
                        throw CancellationError()
                    }
                }
            }
        } catch is CancellationError {
            outcome = .cancelled
            runError = CancellationError()
            await cancelActiveSession()
            try? await emit(.cancelled)
        } catch {
            outcome = .failed
            runError = error
            await cancelActiveSession()
            try? await emit(.failed(String(describing: error)))
        }

        // Stop the motion ticker and the dedicated scroll ticker and wait for
        // both to land before touching the terminal: a tick racing
        // `restoreTerminal` could paint into a restored screen. Awaiting is
        // safe — the tickers' sleeps are actor suspensions, so they observe
        // cancellation promptly. The shutdown latch is permanent for this
        // run so a late `resumeMotionTicker` from a racing child-restore
        // path cannot clear an ordinary suspend hold and re-arm either
        // ticker while `running` is still true.
        motionShutdownLatched = true
        motionSuspended = true
        cancelComposerMouseGesture()
        let teardownMotionGeneration = motionTickerGeneration
        let teardownMotion = motionTicker
        teardownMotion?.cancel()
        let teardownScrollGeneration = scrollTickerGeneration
        let teardownScroll = scrollTicker
        teardownScroll?.cancel()
        if let teardownMotion {
            _ = await teardownMotion.value
        }
        if let teardownScroll {
            _ = await teardownScroll.value
        }
        if motionTickerGeneration == teardownMotionGeneration {
            motionTicker = nil
        }
        if scrollTickerGeneration == teardownScrollGeneration {
            scrollTicker = nil
        }

        await closeActiveSession()
        inputPump?.cancel()
        await inputPumpGate.close()
        await inputReader.cancel()
        if let inputPump {
            _ = await inputPump.value
        }
        self.inputPump = nil
        self.inputPumpGate = nil
        await mailbox.close()
        signalMailbox = nil

        if rendererBegan {
            do {
                try await renderer.restoreTerminal()
                terminalRestored = true
            } catch {
                outcome = .failed
                if runError == nil {
                    runError = OpenGrokPagerInteractiveError.terminalRestorationFailed(String(describing: error))
                }
            }
        }

        running = false
        activeSessionID = nil
        lifecycle = outcome

        let result = OpenGrokPagerInteractiveResult(
            lifecycle: outcome,
            sessionID: lastSessionID ?? request.sessionID,
            submittedPrompts: submittedPrompts,
            completedTurnCount: completedTurnCount,
            terminalRestored: terminalRestored
        )
        if let runError {
            throw runError
        }
        return result
    }

    private func runTurn(
        session: any OpenGrokPagerSessionAdapter,
        request: OpenGrokPagerRequest,
        mailbox: SignalMailbox,
        inputPumpGate: InputPumpGate
    ) async throws -> TurnOutcome {
        activeSession = session
        activeSessionID = session.sessionID ?? request.sessionID
        activeSessionCancelled = false
        activeSessionClosed = false
        try await emit(.turnStarted(request))
        try await transition(to: .running)

        turnGeneration &+= 1
        let generation = turnGeneration
        let sessionTask = Task {
            var reachedTerminalEvent = false
            do {
                for try await event in session.events {
                    await mailbox.send(.session(generation: generation, .element(event)))
                    if isTerminal(event) {
                        reachedTerminalEvent = true
                        break
                    }
                }
                if !reachedTerminalEvent {
                    await mailbox.send(.session(generation: generation, .end))
                }
            } catch is CancellationError {
                return
            } catch {
                await mailbox.send(.session(
                    generation: generation,
                    .failure(String(describing: error))
                ))
            }
        }
        await Task.yield()
        await inputPumpGate.resume()
        var eventCount = 0
        var terminalLifecycle: OpenGrokPagerMinimalLifecycle = .completed
        var turnOutcome: TurnOutcome?

        do {
            while turnOutcome == nil {
                try Task.checkCancellation()
                guard let signal = await mailbox.next() else {
                    turnOutcome = .eof
                    continue
                }
                switch signal {
                case .session(let signalGeneration, let read):
                    // A stale signal is a previous turn's death, not this
                    // turn's; adopting it would cancel this turn and discard
                    // the queue (see `Signal.session`).
                    guard signalGeneration == generation else { continue }
                    switch read {
                    case .element(let event):
                        try await emit(.session(event))
                        eventCount += 1
                        switch event {
                        case .completed:
                            terminalLifecycle = .completed
                        case .cancelled:
                            terminalLifecycle = .cancelled
                        case .lifecycle, .output, .status, .tool, .permissionRequested:
                            continue
                        }
                        let result = OpenGrokPagerRuntimeResult(
                            lifecycle: terminalLifecycle,
                            sessionID: session.sessionID ?? request.sessionID,
                            forwardedEventCount: eventCount,
                            terminalRestored: false
                        )
                        try await emit(.turnFinished(result))
                        turnOutcome = .finished(result)
                    case .end:
                        let result = OpenGrokPagerRuntimeResult(
                            lifecycle: terminalLifecycle,
                            sessionID: session.sessionID ?? request.sessionID,
                            forwardedEventCount: eventCount,
                            terminalRestored: false
                        )
                        try await emit(.turnFinished(result))
                        turnOutcome = .finished(result)
                    case .failure(let message):
                        // A failed turn is not a failed run. Surface it and
                        // hand control back to the composer; only input death
                        // and external cancels may end the run from here.
                        turnOutcome = .turnFailed(message: message)
                    case .cancelled:
                        throw CancellationError()
                    }
                case .input(let read):
                    switch read {
                    case .element(let event):
                        if case .resize(let size) = event {
                            try await renderer.resize(to: size)
                            await inputPumpGate.resume()
                            continue
                        }
                        switch Self.controlAction(for: event) {
                        case .some(.escape), .some(.interrupt):
                            var isEscape = false
                            if case .some(.escape) = Self.controlAction(for: event) { isEscape = true }
                            switch handleInterrupt(isEscape: isEscape, isTurnRunning: true) {
                            case .cancelTurn:
                                await cancelActiveSession()
                                turnOutcome = .turnCancelled
                            case .consumed, .quit:
                                try await emit(.promptChanged(promptState()))
                                await inputPumpGate.resume()
                            }
                        case .some(.eof):
                            await cancelActiveSession()
                            turnOutcome = .eof
                        default:
                            if try await handleScrollbackEvent(event) {
                                await inputPumpGate.resume()
                                continue
                            }
                            // The composer stays live while a turn runs — that
                            // is the whole point of the send→queue flip in the
                            // shortcuts bar.
                            switch applyEditorEvent(event) {
                            case .submit:
                                let prompt = editor.text
                                if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    // Bare Enter on an empty composer with a
                                    // follow-up waiting force-sends the head of
                                    // the queue. Send-now cancels the running
                                    // turn and lets `.turnPreempted` drain that
                                    // already-frontmost prompt next.
                                    if await promptQueue.isEmpty {
                                        try await emit(.notice("prompt cannot be empty"))
                                        await inputPumpGate.resume()
                                    } else if await orchestrationWaitState?() == true {
                                        // An `agent_swarm` cohort is parked in
                                        // an orchestration wait: the prompt is
                                        // promoted (it is already at the head)
                                        // but the turn is NOT cancelled —
                                        // aborting would kill every live
                                        // member (prompt_queue.rs:222-233).
                                        // The queue drains when the swarm turn
                                        // ends.
                                        await inputPumpGate.resume()
                                    } else {
                                        await cancelActiveSession()
                                        turnOutcome = .turnPreempted
                                    }
                                } else {
                                    // A UI-only slash command runs now rather
                                    // than queueing behind the turn — `/queue`
                                    // is only ever useful *here*, and queueing
                                    // it would make it unreachable at the one
                                    // moment it answers a real question.
                                    //
                                    // A history-mutating one must NOT: it would
                                    // rewrite the item list underneath a
                                    // streaming sampler. Those go to the queue,
                                    // which is what upstream does for the whole
                                    // category via `CommandResult::QueueCommand`.
                                    switch try await runSlashCommand(
                                        prompt,
                                        isTurnRunning: true
                                    ) {
                                    case .quit:
                                        await cancelActiveSession()
                                        turnOutcome = .shutdown
                                    case .submit(let generatedPrompt):
                                        try await enqueue(generatedPrompt, historyText: prompt)
                                        await inputPumpGate.resume()
                                    case .handled:
                                        recordHistory(prompt)
                                        editor.reset()
                                        try await emit(.promptChanged(promptState()))
                                        await inputPumpGate.resume()
                                    case .drain:
                                        // The fallback prompt waits at the
                                        // front of the queue; it drains when
                                        // this turn ends (`.drainNext`).
                                        recordHistory(prompt)
                                        editor.reset()
                                        try await emit(.promptChanged(promptState()))
                                        await inputPumpGate.resume()
                                    case .notACommand where modes.enterSteers:
                                        // With `enter_steers` on, Enter takes
                                        // upstream's cancel-and-send role
                                        // (`defaults.rs:630-632`): the draft
                                        // runs next, ahead of waiting follow-ups.
                                        try await enqueue(prompt, insertion: .front)
                                        if await orchestrationWaitState?() == true {
                                            // Promote-without-cancel: the swarm
                                            // turn keeps the wheel; the steered
                                            // prompt still runs first after it
                                            // (prompt_queue.rs:222-233 — the
                                            // same shape upstream's actor test
                                            // pins for explicit send-now).
                                            await inputPumpGate.resume()
                                        } else {
                                            await cancelActiveSession()
                                            turnOutcome = .turnPreempted
                                        }
                                    case .notACommand:
                                        try await enqueue(prompt)
                                        await inputPumpGate.resume()
                                    }
                                }
                            case .viewport(let command):
                                try await emit(.viewport(command))
                                await inputPumpGate.resume()
                            case .focusScrollback:
                                try await setFocus(.scrollback)
                                await inputPumpGate.resume()
                            case .toggleMultiline:
                                try await setMultiline(!modes.isMultiline)
                                await inputPumpGate.resume()
                            case .global(let command):
                                try await handleGlobal(command, isTurnRunning: true)
                                await inputPumpGate.resume()
                            case .ignored:
                                await inputPumpGate.resume()
                            case .changed, .historyPrevious, .historyNext,
                                 .completionMove, .completionAccept,
                                 // Rewritten inside `applyEditorEvent`;
                                 // listed for exhaustiveness, reached never.
                                 .completionCommit,
                                 .escape, .interrupt, .eof, .resize:
                                try await emit(.promptChanged(promptState()))
                                await inputPumpGate.resume()
                            }
                        }
                    case .end:
                        await cancelActiveSession()
                        turnOutcome = .eof
                    case .failure(let message):
                        throw OpenGrokPagerInteractiveError.inputFailed(message)
                    case .cancelled:
                        throw CancellationError()
                    }
                case .control(let control):
                    switch control {
                    case .interrupt(let isEscape):
                        switch handleInterrupt(isEscape: isEscape, isTurnRunning: true) {
                        case .cancelTurn:
                            await cancelActiveSession()
                            turnOutcome = .turnCancelled
                        case .consumed, .quit:
                            try await emit(.promptChanged(promptState()))
                            await inputPumpGate.resume()
                        }
                    case .cancel:
                        await cancelActiveSession()
                        turnOutcome = .cancelled
                    case .eof:
                        await cancelActiveSession()
                        turnOutcome = .eof
                    case .shutdown:
                        await cancelActiveSession()
                        turnOutcome = .shutdown
                    case .command(let text):
                        switch try await runSlashCommand(text, isTurnRunning: true) {
                        case .quit:
                            await cancelActiveSession()
                            turnOutcome = .shutdown
                        case .submit(let generatedPrompt):
                            try await enqueue(generatedPrompt, historyText: text)
                            await inputPumpGate.resume()
                        case .drain, .handled, .notACommand:
                            // `.drain` mid-turn: the fallback prompt waits at
                            // the front; the queue drains at turn end.
                            try await emit(.promptChanged(promptState()))
                            await inputPumpGate.resume()
                        }
                    case .dispatch(let sessionID, let prompt):
                        let target = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
                        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !target.isEmpty, !text.isEmpty else {
                            try await emit(.notice("dashboard reply cannot be empty"))
                            await inputPumpGate.resume()
                            break
                        }
                        let current = activeSessionID ?? lastSessionID ?? request.sessionID
                        if current == target {
                            try await enqueue(text)
                        } else {
                            deferredSessionDispatches.append(.existing(
                                sessionID: target,
                                prompt: text
                            ))
                            try await emit(.notice(
                                "Queued dashboard reply for \(target); it will run when this turn finishes."
                            ))
                        }
                        await inputPumpGate.resume()
                    case .dispatchNew(let prompt, let workingDirectory):
                        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else {
                            try await emit(.notice("dashboard dispatch cannot be empty"))
                            await inputPumpGate.resume()
                            break
                        }
                        deferredSessionDispatches.append(.new(
                            prompt: text,
                            workingDirectory: workingDirectory
                        ))
                        try await emit(.notice(
                            "Queued dashboard dispatch; it will start when this turn finishes."
                        ))
                        await inputPumpGate.resume()
                    case .cronEnqueued:
                        // Mid-turn a cron entry just waits its turn in the
                        // queue; the completion arm's `.drainNext` starts it
                        // (upstream: the busy-agent case leaves the entry
                        // queued, acp_handler/tests/scheduled_tasks.rs:150).
                        // No pump interaction: this signal never came from
                        // the input pump, so there is nothing to resume.
                        break
                    }
                }
            }
        } catch {
            sessionTask.cancel()
            _ = await sessionTask.value
            throw error
        }

        sessionTask.cancel()
        _ = await sessionTask.value
        await closeActiveSession()
        return turnOutcome ?? .eof
    }

    // MARK: - Queue

    private enum QueueInsertion {
        case front
        case tail
    }

    /// Put a prompt in the queue and clear the composer.
    ///
    /// Normal follow-ups use the tail. Send-now uses the front, then cancels the
    /// active turn so the existing drain path runs it next.
    private func enqueue(
        _ prompt: String,
        historyText: String? = nil,
        insertion: QueueInsertion = .tail
    ) async throws {
        nextPromptSequence += 1
        let entry = QueueEntryMeta(
            id: "prompt-\(nextPromptSequence)",
            kind: "prompt",
            text: prompt
        )
        switch insertion {
        case .front:
            await promptQueue.enqueueFront(entry)
        case .tail:
            await promptQueue.enqueue(entry)
        }
        recordHistory(historyText ?? prompt)
        editor.reset()
        try await emit(.promptChanged(promptState()))
        try await emit(.queueChanged(queuedPromptCount: await promptQueue.count))
    }

    /// What `enqueueCronPrompt` did with a fire. The two skip cases are
    /// upstream's de-dup guards (`handle_scheduled_task_inject_prompt`,
    /// acp_handler/background.rs:483-496): a re-fire of a task that is
    /// already queued or already running must not pile up.
    public enum CronEnqueueOutcome: Sendable, Equatable {
        case enqueued
        case skippedTaskAlreadyQueued
        case skippedTaskAlreadyRunning
    }

    /// Enqueue a scheduler-fired prompt as a Cron queue entry and, when the
    /// controller is idle, wake the run loop to drain it — the single-process
    /// port of `x.ai/scheduled_task_inject_prompt` → `enqueue_cron_prompt` →
    /// `maybe_drain_queue` (acp_handler/background.rs:439-509). `prompt` is
    /// the RAW stored text; framing for the model happens at the send seam.
    public func enqueueCronPrompt(
        prompt: String,
        taskID: String,
        humanSchedule: String
    ) async -> CronEnqueueOutcome {
        if runningCronTaskID == taskID {
            return .skippedTaskAlreadyRunning
        }
        let alreadyQueued = await promptQueue.entries.contains { $0.taskID == taskID }
        if alreadyQueued {
            return .skippedTaskAlreadyQueued
        }
        await promptQueue.enqueue(QueueEntryMeta(
            id: Self.schedulerFiredPromptIDPrefix + UUID().uuidString,
            kind: Self.cronQueueEntryKind,
            text: prompt,
            taskID: taskID,
            humanSchedule: humanSchedule
        ))
        // Best-effort chrome: a failed emit only means the `+n` queue count
        // missed a beat — the entry is already queued, and the run loop
        // surfaces a dead output stream on its next own emit. Deliberately
        // not propagated: the caller is the scheduler timer, which has no
        // recovery for a render error.
        try? await emit(.queueChanged(queuedPromptCount: await promptQueue.count))
        await signalMailbox?.send(.control(.cronEnqueued))
        return .enqueued
    }

    /// Enqueue a monitor event as a notification prompt turn and, when the
    /// controller is idle, wake the run loop to drain it — this port's
    /// single-process seam for upstream's `SessionCommand::InjectNotification`
    /// with `NotificationPriority::Next` (notification_bridge.rs:776-789).
    /// `eventText` is the full `<monitor-event …>` wrap; the model receives
    /// it verbatim, exactly as upstream's prompt blocks carry it. No de-dup
    /// on purpose: each event is its own wake upstream too — the monitor's
    /// rate limiter is what bounds the flow, not the queue.
    public func enqueueMonitorPrompt(taskID: String, eventText: String) async {
        await promptQueue.enqueue(QueueEntryMeta(
            id: Self.monitorPromptIDPrefix + taskID + "-" + UUID().uuidString,
            kind: Self.monitorQueueEntryKind,
            text: eventText,
            taskID: taskID,
            humanSchedule: nil
        ))
        try? await emit(.queueChanged(queuedPromptCount: await promptQueue.count))
        // The same idle-wake control the cron path uses: its meaning is
        // "an out-of-band entry landed; drain if idle", not "cron".
        await signalMailbox?.send(.control(.cronEnqueued))
    }

    /// Convert an interjection with no running turn into a queued prompt
    /// turn at the FRONT of the queue — send-now semantics: the user asked
    /// for "now", queued rows asked for "later". The port of
    /// `queue_interjection_fallback_prompt` (interjection.rs:46-99). The
    /// raw text rides as the prompt, never the `formatInterjection`
    /// envelope — upstream's fallback blocks carry the bare text too
    /// (interjection.rs:53). Upstream re-validates front placement against a
    /// running front row; this port's queue never contains the running
    /// prompt (`beginNext` removes it), so a plain front insert cannot
    /// displace one.
    private func queueInterjectionFallbackPrompt(_ text: String) async throws {
        let entry = QueueEntryMeta(
            id: Self.interjectFallbackPromptPrefix + UUID().uuidString,
            kind: "prompt",
            text: text
        )
        await promptQueue.enqueueFront(entry)
        try await emit(.queueChanged(queuedPromptCount: await promptQueue.count))
    }

    /// Flush interjections that raced past the completed (or failed) turn's
    /// final drain into front-of-queue prompt turns, original order. The
    /// port of `flush_stranded_interjections` (interjection.rs:105-116) at
    /// the completion arm's call site (run_loop.rs:432-447). Reversed
    /// front-inserts keep entry 0 front-most. Cancelled turns never come
    /// here: the driver already cleared the buffer (run_loop.rs:989-991).
    private func flushStrandedInterjections() async throws {
        guard let interjectionSeam else { return }
        let stranded = await interjectionSeam.collectStranded()
        guard !stranded.isEmpty else { return }
        for text in stranded.reversed() {
            try await queueInterjectionFallbackPrompt(text)
        }
    }

    /// Throw away everything still queued. Reserved for the ways a run *ends* —
    /// quit, EOF, external cancel. Cancelling a turn deliberately does not come
    /// here: the reference keeps follow-ups across an interrupt.
    private func discardQueue(reason: String) async throws {
        let discarded = await promptQueue.removeAll()
        guard !discarded.isEmpty else { return }
        let plural = discarded.count == 1 ? "prompt" : "prompts"
        try await emit(.notice("discarded \(discarded.count) queued \(plural) — \(reason)"))
        try await emit(.queueChanged(queuedPromptCount: 0))
    }

    /// Run queued prompts in order until the queue empties or something ends
    /// the run. Returns the terminal lifecycle, or `nil` to continue editing.
    private func drainQueue(
        request: OpenGrokPagerRequest,
        mailbox: SignalMailbox,
        inputPumpGate: InputPumpGate
    ) async throws -> OpenGrokPagerInteractiveLifecycle? {
        while true {
            if await promptQueue.count == 0,
               let dispatch = deferredSessionDispatches.first {
                deferredSessionDispatches.removeFirst()
                switch dispatch {
                case .existing(let sessionID, let prompt):
                    let activated = try await activateStoredSession(
                        sessionID: sessionID,
                        clearQueue: false
                    )
                    guard activated else { continue }
                    try await enqueue(prompt)
                case .new(let prompt, let workingDirectory):
                    let replaced = try await replaceSession(
                        request: request,
                        workingDirectory: workingDirectory,
                        clearQueue: false
                    )
                    guard replaced else { continue }
                    try await enqueue(prompt)
                }
            }
            let entry: QueueEntryMeta
            do {
                entry = try await promptQueue.beginNext()
            } catch {
                // `.empty` is the normal exit; `.alreadyRunning` cannot happen
                // because every path below clears the running marker.
                return nil
            }
            // A queued slash command is a command, not a prompt. This is the
            // other half of the mid-turn deferral: `/compact` was put here
            // precisely so it would run against a settled conversation, and
            // sending its text to the model instead would be worse than having
            // run it early. A Cron entry is exempt: its text is the stored
            // task prompt and is sent to the model even when it starts with
            // "/" (upstream's Cron drain arm never parses commands,
            // app/dispatch/queue.rs:518-560). A monitor entry is exempt for
            // the same reason — its text is a wrapped event, never a command.
            if entry.kind != Self.cronQueueEntryKind,
               entry.kind != Self.monitorQueueEntryKind,
               case .command = PagerCommandParser.parse(entry.text) {
                await promptQueue.completeRunning()
                switch try await runSlashCommand(entry.text) {
                case .submit(let generatedPrompt):
                    try await enqueue(generatedPrompt, historyText: entry.text)
                case .drain, .quit, .handled, .notACommand:
                    // `.drain`: the fallback prompt is already at the front;
                    // this loop picks it up on the next iteration.
                    break
                }
                try await emit(.queueChanged(queuedPromptCount: await promptQueue.count))
                continue
            }

            // `combine_queued_prompts` (`defs.rs:708`): take the whole backlog
            // as one turn rather than one turn each. Only the entries already
            // waiting are folded in — anything enqueued during the turn stays
            // for the next drain, so a fast typist cannot starve the model.
            // Cron entries never merge, in either direction: upstream's
            // combine gate admits only plain `Prompt` rows
            // (`agent.rs:1085-1098`), so the fold takes the plain-prompt
            // prefix and stops at the first Cron row, and a Cron front runs
            // alone. Monitor entries share the rule — upstream's notification
            // prompts never enter the pager queue at all, so they can never
            // have merged.
            var promptText = entry.text
            var foldedBacklog = false
            if modes.combineQueuedPrompts,
               entry.kind != Self.cronQueueEntryKind,
               entry.kind != Self.monitorQueueEntryKind {
                var rest: [String] = []
                for waiting in await promptQueue.entries {
                    if waiting.kind == Self.cronQueueEntryKind
                        || waiting.kind == Self.monitorQueueEntryKind { break }
                    guard let removed = try? await promptQueue.remove(id: waiting.id) else {
                        continue
                    }
                    rest.append(removed.text)
                }
                if !rest.isEmpty {
                    promptText = ([entry.text] + rest).joined(separator: "\n\n")
                    foldedBacklog = true
                }
            }
            try await emit(.queueChanged(queuedPromptCount: await promptQueue.count))

            // A fallback interjection turn keeps its user echo persist-only:
            // the interject dispatch already painted the text as a user
            // block, so the renderer must not paint it a second time at turn
            // start (upstream's `interject-fallback-` prompt-id contract,
            // interjection.rs:20-25). Not when the combine fold changed the
            // body — that combined text was never painted.
            var turnMetadata = request.metadata
            if !foldedBacklog,
               entry.id.hasPrefix(Self.interjectFallbackPromptPrefix) {
                turnMetadata[Self.interjectionFallbackMetadataKey] = entry.id
            }
            // A Cron turn carries its scheduler identity in metadata: the
            // runtime adapter frames the model prompt from it and stamps the
            // `scheduler-fired-` prompt id, while `promptText` stays the RAW
            // stored prompt for the user echo — upstream's split between
            // `RenderBlock::cron_prompt` and the framed wire blocks
            // (app/dispatch/queue.rs:518-560). "unknown" fallbacks are
            // upstream's own (acp_handler/background.rs:458-459).
            if entry.kind == Self.cronQueueEntryKind {
                turnMetadata[Self.cronTaskIDMetadataKey] = entry.taskID ?? "unknown"
                turnMetadata[Self.cronHumanScheduleMetadataKey] =
                    entry.humanSchedule ?? "unknown"
            }
            // A monitor turn carries its task id in metadata: the runtime
            // adapter sends the wrapped event verbatim under a `monitor-`
            // prompt id instead of framing it as a cron prompt.
            if entry.kind == Self.monitorQueueEntryKind {
                turnMetadata[Self.monitorTaskIDMetadataKey] = entry.taskID ?? "unknown"
            }
            let turnRequest = OpenGrokPagerRequest(
                prompt: promptText,
                mode: request.mode,
                sessionID: lastSessionID ?? request.sessionID,
                metadata: turnMetadata
            )
            let session = try await runtime.makeSession(for: turnRequest)
            submittedPrompts.append(promptText)
            if entry.kind == Self.cronQueueEntryKind {
                runningCronTaskID = entry.taskID
            }
            let turnOutcome: TurnOutcome
            do {
                turnOutcome = try await runTurn(
                    session: session,
                    request: turnRequest,
                    mailbox: mailbox,
                    inputPumpGate: inputPumpGate
                )
                // The cron turn is over; a re-fire of the same task may
                // queue again from here on. Cleared on the throw path too —
                // a stale id would suppress that task's fires for the rest
                // of the session.
                runningCronTaskID = nil
            } catch {
                runningCronTaskID = nil
                throw error
            }
            switch try await apply(turnOutcome: turnOutcome, inputPumpGate: inputPumpGate) {
            case .drainNext:
                continue
            case .keepEditing:
                return nil
            case .end(let lifecycle):
                return lifecycle
            }
        }
    }

    /// Account for a finished turn: clear the queue's running marker, emit the
    /// matching event, and say whether the queue should keep draining.
    private func apply(
        turnOutcome: TurnOutcome,
        inputPumpGate: InputPumpGate
    ) async throws -> TurnDisposition {
        switch turnOutcome {
        case .finished(let result):
            await promptQueue.completeRunning()
            lastSessionID = result.sessionID ?? lastSessionID
            if result.lifecycle == .cancelled {
                try await discardQueue(reason: "run cancelled")
                try await emit(.cancelled)
                return .end(.cancelled)
            }
            completedTurnCount += 1
            // Interjections that raced past the turn's final drain become
            // front-of-queue prompt turns before `.drainNext` picks the next
            // entry — upstream's completion-arm flush (run_loop.rs:432-447).
            try await flushStrandedInterjections()
            try await transition(to: .editing)
            try await emit(.promptChanged(promptState()))
            return .drainNext
        case .eof:
            await promptQueue.cancelRunning()
            try await discardQueue(reason: "input ended")
            try await emit(.eof)
            return .end(.eof)
        case .turnCancelled:
            // Cancelling a turn returns to the prompt and keeps the queue; only
            // an external cancel ends the run.
            await promptQueue.cancelRunning()
            try await emit(.turnCancelled)
            try await transition(to: .editing)
            try await emit(.promptChanged(promptState()))
            await inputPumpGate.resume()
            return .keepEditing
        case .turnPreempted:
            await promptQueue.cancelRunning()
            try await emit(.notice("sending the queued prompt now"))
            try await transition(to: .editing)
            try await emit(.promptChanged(promptState()))
            await inputPumpGate.resume()
            return .drainNext
        case .turnFailed(let message):
            // The failed prompt is consumed, not requeued, and queued
            // follow-ups still drain — upstream runs `maybe_drain_queue`
            // on the generic error path too (`dispatch/prompt.rs:1622`);
            // only its dedicated-modal failures skip the drain.
            await promptQueue.completeRunning()
            // A failed turn flushes stranded interjections exactly like a
            // completed one — upstream's completion arm handles Err results
            // too (run_loop.rs:416-447). Cancelled turns never reach here:
            // the driver cleared the buffer (run_loop.rs:989-991).
            try await flushStrandedInterjections()
            try await emit(.turnFailed(message: message))
            try await transition(to: .editing)
            try await emit(.promptChanged(promptState()))
            await inputPumpGate.resume()
            return .drainNext
        case .cancelled:
            await promptQueue.cancelRunning()
            try await discardQueue(reason: "run cancelled")
            try await emit(.cancelled)
            return .end(.cancelled)
        case .shutdown:
            await promptQueue.cancelRunning()
            try await discardQueue(reason: "shutting down")
            try await emit(.shutdown)
            return .end(.shutdown)
        }
    }

    // MARK: - Scrollback focus

    /// What the scrollback does with a key while it holds focus.
    private enum ScrollbackRouting: Sendable {
        case focusPrompt
        case command(OpenGrokPagerScrollbackCommand)
        case viewport(OpenGrokPagerViewportCommand)
        /// Opt-in mouse-reporting toggle — same overlay seam as
        /// `/toggle-mouse-reporting` (`Action::ToggleMouseCapture`).
        case toggleMouseReporting
        /// The scrollback has focus and declines to act, but a focused region
        /// never leaks a keystroke to the composer — upstream's rule for
        /// modals, applied to the focus split for the same reason.
        case swallowed
    }

    /// Map a key under `When::ScrollbackFocused` (`defaults.rs:84-460,475`).
    ///
    /// Bare-letter and Shift-letter bindings are suppressed unless vim mode is
    /// on, mirroring `lookup_with_mode` (`actions/mod.rs:397-430`). With vim
    /// off the region is still fully usable through the arrows, `Enter`, `Tab`,
    /// the paging keys and the `Ctrl` chords — which is the point of the gate:
    /// typing `y` at a transcript should not silently copy something.
    private func scrollbackRouting(for event: InputEvent) -> ScrollbackRouting {
        guard case .key(let key) = event else { return .swallowed }

        if key.modifiers.contains(.control) {
            let character: Character?
            switch key.key {
            case .char(let value): character = value
            default: character = key.character
            }
            switch character?.lowercased() {
            case "k": return .viewport(.lineUp)
            case "j": return .viewport(.lineDown)
            case "u": return .viewport(.halfPageUp)
            case "e": return .command(.expandAllThinking)
            // `Ctrl+R` toggles mouse capture only while scrollback is
            // focused and only when the opt-in gate is on
            // (`defaults.rs:854-877`, `When::ScrollbackFocused`). Prompt
            // focus must not steal this chord — history search / parity
            // stay on the prompt path.
            case "r" where mouseReportingToggleEnabled:
                return .toggleMouseReporting
            default: return .swallowed
            }
        }

        let isShifted = key.modifiers.contains(.shift)
        switch key.key {
        case .tab:
            return .focusPrompt
        case .enter:
            return .command(.openBlockViewer)
        case .up:
            return .command(.selectPrevious)
        case .down:
            return .command(.selectNext)
        case .left:
            return isShifted ? .command(.previousTurn) : .command(.collapse)
        case .right:
            return isShifted ? .command(.nextTurn) : .command(.expand)
        case .pageUp:
            return .viewport(.pageUp)
        case .pageDown:
            return .viewport(.pageDown)
        case .home:
            return .command(.selectFirst)
        case .end:
            return .command(.selectLast)
        case .char(let character):
            guard modes.isVimMode else { return .swallowed }
            return Self.vimRouting(for: character)
        default:
            return .swallowed
        }
    }

    private static func vimRouting(for character: Character) -> ScrollbackRouting {
        switch character {
        case "j": return .command(.selectNext)
        case "k": return .command(.selectPrevious)
        case "L": return .command(.nextTurn)
        case "H": return .command(.previousTurn)
        case "J": return .command(.nextResponse)
        case "K": return .command(.previousResponse)
        case "g": return .command(.selectFirst)
        case "G": return .command(.selectLast)
        case "h": return .command(.collapse)
        case "l": return .command(.expand)
        case "e": return .command(.toggleFold)
        case "E": return .command(.toggleExpandAll)
        case "r": return .command(.toggleRaw)
        case "y": return .command(.copyBlockContent)
        case "Y": return .command(.copyBlockMetadata)
        case "o": return .command(.openNextLink)
        case "O": return .command(.openPreviousLink)
        case "x": return .command(.killBackgroundTask)
        // `d`/`u` are the VS Code family's half-page bindings upstream
        // (`defaults.rs:231-235`); this port keeps `Ctrl+D` on EOF
        // unconditionally so a focus region can never trap the session, and
        // takes the bare-letter form instead.
        case "d": return .viewport(.halfPageDown)
        case "u": return .viewport(.halfPageUp)
        // `i` and `Space` enter the prompt but, unlike `Tab`, do not leave it
        // (`defaults.rs:475-487`).
        case "i", " ": return .focusPrompt
        default: return .swallowed
        }
    }

    /// Apply one key while the scrollback holds focus. Returns false when the
    /// caller should fall through to the composer — which only happens when
    /// focus was not on the scrollback to begin with.
    private func handleScrollbackEvent(_ event: InputEvent) async throws -> Bool {
        guard focus == .scrollback else { return false }
        if case .resize(let size) = event {
            try await renderer.resize(to: size)
            return true
        }
        switch scrollbackRouting(for: event) {
        case .focusPrompt:
            try await setFocus(.prompt)
        case .command(let command):
            try await emit(.scrollback(command))
        case .viewport(let command):
            try await emit(.viewport(command))
        case .toggleMouseReporting:
            try await emit(.overlay(.toggleMouseReporting))
        case .swallowed:
            break
        }
        return true
    }

    private func setFocus(_ region: OpenGrokPagerFocusRegion) async throws {
        guard focus != region else { return }
        focus = region
        // A focus change disarms anything the composer had pending: the arming
        // key is no longer the one the next press would hit.
        pendingConfirmation = nil
        try await emit(.focusChanged(region))
        try await emit(.promptChanged(promptState()))
    }

    /// Apply a renderer `.focusComposer` claim: focus the prompt without
    /// moving the caret, and emit `.promptChanged` so a chrome click that
    /// only changes focus still syncs the paint.
    private func applyFocusComposer() async throws {
        let wasPrompt = focus == .prompt
        try await setFocus(.prompt)
        if wasPrompt {
            try await emit(.promptChanged(promptState()))
        }
    }

    /// Apply `.composerMouse`: TextArea.handleMouse on the last-painted
    /// content rect. Down/drag/up focus the prompt and OSC 52 copy when
    /// the TextArea staged a clipboard payload. Wheel may scroll the
    /// TextArea but must not `setFocus(.prompt)` — pin `panes.rs:669-685`
    /// calls `prompt.handle_mouse` without `set_active_pane`.
    private func applyComposerMouse(_ claim: OpenGrokPagerComposerMouse) async throws {
        lastComposerContentRect = claim.content
        let action = editor.handleMouse(claim.event, content: claim.content)
        if claim.event.kind == .down, claim.event.resolvedButton == .left {
            let now = Date()
            if let last = lastPromptClickTime, now.timeIntervalSince(last) < 0.400 {
                if let fileRef = editor.fileRefElementAtCursor() {
                    try await emit(.overlay(.openLineViewer(path: fileRef.path, lineRange: fileRef.lineRange)))
                } else if editor.expandPasteElementAtCursor() {
                    try await emit(.promptChanged(promptState()))
                }
            }
            lastPromptClickTime = now
        }
        if claim.event.isScroll {
            if action != .nothing {
                try await emit(.promptChanged(promptState()))
            }
            return
        }
        let wasPrompt = focus == .prompt
        try await setFocus(.prompt)
        if wasPrompt {
            try await emit(.promptChanged(promptState()))
        }
        let copied = editor.takeClipboard()
        if action == .selectionFinished, let copied, !copied.isEmpty {
            try await renderer.copyToClipboard(copied)
        }
    }

    /// Drop TextArea drag/scrollbar state without copying. Idempotent.
    private func cancelComposerMouseGesture() {
        editor.cancelMouseGesture()
    }

    private func setMultiline(_ isOn: Bool) async throws {
        guard modes.isMultiline != isOn else { return }
        modes.isMultiline = isOn
        editor.isMultiline = isOn
        try await emit(.modeChanged(modes))
        try await emit(.notice(isOn
            ? "Multiline on. Enter inserts a newline; Shift+Enter sends."
            : "Multiline off. Enter sends; Shift+Enter inserts a newline."))
    }

    // MARK: - Prompt behavior

    /// Feed one input event to the composer and apply the bookkeeping every
    /// caller shares — confirmation disarming, history detach, completion
    /// movement. Returns the action for the caller to act on.
    private func applyEditorEvent(_ event: InputEvent) -> PromptAction {
        let action = editor.apply(event)
        // Any key other than the armed one clears a pending confirmation,
        // matching `app_view.rs`'s arm lifetime. `.global` is exempt because a
        // confirming chord's second press *is* the armed key — disarming here
        // would make `Ctrl+N` unconfirmable — so `handleGlobal` owns the
        // lifetime for those.
        switch action {
        case .escape, .interrupt, .ignored, .resize, .global:
            break
        default:
            pendingConfirmation = nil
        }
        switch action {
        case .changed:
            detachHistory()
            refreshCompletions()
        case .historyPrevious:
            browseHistory(offset: -1)
        case .historyNext:
            browseHistory(offset: 1)
        case .completionMove(let offset):
            if !editor.completions.isEmpty {
                let count = editor.completions.count
                let current = editor.selectedCompletion ?? 0
                if abs(offset) == 1 {
                    // Arrow steps wrap (`slash_move_selection`).
                    editor.selectedCompletion = ((current + offset) % count + count) % count
                } else {
                    // Page steps clamp at the ends, no wrap-around
                    // (`slash_scroll_selection`, `prompt_widget/mod.rs:1185-1190`).
                    editor.selectedCompletion = min(max(current + offset, 0), count - 1)
                }
            }
        case .completionAccept:
            acceptSelectedCompletion()
            editor.completions = []
            editor.selectedCompletion = nil
        case .completionCommit:
            // Enter on a row: accept it, then upstream's `is_command_complete`
            // gate decides. A command whose usage requires an argument
            // (`/effort <level>`) completes into the argument phase — the
            // draft becomes "/effort " with the argument dropdown open — and
            // a complete command sends on this same press.
            let accepted = acceptSelectedCompletion()
            if let accepted,
               case .available(let command) = commands.resolve(
                   PagerCommandInvocation(name: accepted.name)
               ),
               command.requiresArguments,
               Self.argumentPhase(for: editor.text) == nil {
                editor.replace(with: editor.text + " ")
                refreshCompletions()
                return .changed
            }
            editor.completions = []
            editor.selectedCompletion = nil
            return .submit
        default:
            break
        }
        return action
    }

    /// Replace the draft with the highlighted row's insert text, recording
    /// MRU for command-phase accepts. Returns the accepted row, or nil when
    /// no row was highlighted (the caller then treats the press as if the
    /// dropdown were closed).
    @discardableResult
    private func acceptSelectedCompletion() -> OpenGrokPagerCommandSuggestion? {
        guard let index = editor.selectedCompletion,
              editor.completions.indices.contains(index) else { return nil }
        let suggestion = editor.completions[index]
        // Accepting a *command* row records MRU; an argument row does
        // not (`record_mru = snap.cursor_in_command`,
        // `prompt_widget/mod.rs:1206-1211`).
        if Self.argumentPhase(for: editor.text) == nil {
            recordSlashMruUse(commandNamed: suggestion.name)
        }
        editor.replace(with: suggestion.insertText)
        return suggestion
    }

    /// Record an accepted slash command in the MRU and hand a persistence
    /// snapshot to the serialized writer. The write happens off this actor; a
    /// failed write re-marks the store dirty so the next accept retries —
    /// upstream's exact recovery (`prompt_widget/mod.rs:1268`, `mru.rs:
    /// 411-421`).
    private func recordSlashMruUse(commandNamed name: String) {
        slashMru.touch(name, now: UInt64(Date().timeIntervalSince1970))
        guard let snapshot = slashMru.takePersistSnapshot() else { return }
        Task {
            // The Task inherits this actor's isolation, so re-marking dirty
            // after a failed write mutates the store race-free.
            let written = await PagerSlashMruWriter.shared.write(snapshot)
            if !written {
                self.slashMru.markDirty()
            }
        }
    }

    /// Slash commands the TUI honors locally. The reference registers ~71 and
    /// routes most of them to a pager `Action`; this port lists only the ones
    /// backed by working Swift wiring, so the dropdown never offers a no-op.
    ///
    /// Summaries are upstream's verbatim (`src/slash/commands/*.rs`) so the
    /// dropdown reads identically for every command both sides have.
    ///
    /// `/debug` listing tracks Swift `DEBUG` the way upstream's
    /// `LISTED_IN_COMPLETIONS = cfg!(debug_assertions)` tracks the binary
    /// profile (`debug.rs:24-29`). Always registered; hidden in release.
    public static let debugCommandListedInCompletions: Bool = {
        #if DEBUG
        true
        #else
        false
        #endif
    }()

    static let builtinCommands: [PagerCommandDefinition] = [
        // Registration order is display order: a bare `/` lists exactly this
        // sequence, mirroring upstream's `builtin_commands()` ("in display
        // order", `slash/commands/mod.rs:78-81`). `quit` and `help` lead for
        // the same reason they lead upstream. Ranked queries no longer read
        // an explicit priority — ordering is fuzzy score, then recency, then
        // display (`slash/mod.rs:996-1003`), so `/q` resolves its tie by
        // display order, exactly as upstream's dropdown does.
        PagerCommandDefinition(
            name: "quit",
            aliases: ["exit"],
            summary: "Quit the application"
        ),
        PagerCommandDefinition(
            name: "help",
            summary: "Browse commands and keyboard shortcuts"
        ),
        // `/docs` follows `/help`, upstream's display order
        // (`slash/commands/mod.rs:84-85`). Name, aliases, description and
        // usage are verbatim (`docs.rs:18-32`); the argument is optional
        // (`args_required() == false`, docs.rs:38-40), so a bare Enter
        // dispatches. Upstream's `arg_placeholder("[web|title]")`
        // (docs.rs:42-44) has no port channel — `PagerCommandDefinition`
        // carries no placeholder field — so the usage string is the only
        // argument hint (recorded divergence, shared with `/plan`/`/fork`).
        PagerCommandDefinition(
            name: "docs",
            aliases: ["howto", "guides"],
            summary: "Open How-to Guides or online Build docs",
            usage: "/docs [web|title]"
        ),
        PagerCommandDefinition(
            name: "home",
            aliases: ["welcome"],
            summary: "Return to the welcome screen"
        ),
        PagerCommandDefinition(
            name: "new",
            aliases: ["clear"],
            summary: "Start a new session",
            mutatesConversationHistory: true
        ),
        // `/fork` follows `/new`, upstream's display order
        // (`slash/commands/mod.rs:88-89`). Name, summary and usage are
        // verbatim (`fork.rs:102-116`); both flags and the directive are
        // optional (`args_required() == false`, `fork.rs:122-124`), so a
        // bare Enter dispatches. Upstream's `arg_placeholder("[directive]")`
        // (`fork.rs:126-128`) has no port channel —
        // `PagerCommandDefinition` carries no placeholder field — so the
        // usage string is the only argument hint (recorded divergence,
        // shared with `/plan`).
        PagerCommandDefinition(
            name: "fork",
            summary: "Branch the current session into a peer agent",
            usage: "/fork [--worktree|--no-worktree] [directive]"
        ),
        // `/resume` (`slash/commands/resume.rs:9-19`). Committing a picked
        // session replaces the live conversation, so it takes the same
        // mid-turn deferral `/new` does.
        PagerCommandDefinition(
            name: "resume",
            summary: "Resume a previous session",
            usage: "/resume",
            mutatesConversationHistory: true
        ),
        PagerCommandDefinition(
            name: "copy",
            summary: "Copy last response to clipboard or file (/copy [N] [file])",
            usage: "/copy [N] [file]"
        ),
        PagerCommandDefinition(
            name: "find",
            summary: "Search the conversation scrollback",
            usage: "/find [text]"
        ),
        PagerCommandDefinition(
            name: "history",
            summary: "Search prompt history"
        ),
        PagerCommandDefinition(
            name: "export",
            summary: "Export the current conversation to a file or clipboard",
            usage: "/export [filename]"
        ),
        // `/transcript`, alias `/log` (`slash/commands/transcript.rs:16-34`);
        // summary is upstream's description verbatim (`transcript.rs:24-26`),
        // placed after `/export` in upstream's display order
        // (`slash/commands/mod.rs:94-95`). Not history-mutating: the pager
        // view is read-only, so upstream dispatches it mid-turn too.
        PagerCommandDefinition(
            name: "transcript",
            aliases: ["log"],
            summary: "View the full conversation transcript in your pager ($PAGER)",
            usage: "/transcript"
        ),
        // `/expand` sits between `/transcript` and `/context`, upstream's
        // registry order minus the absent `/edit-prompt`
        // (`slash/commands/mod.rs:95-98`). Copy verbatim from
        // `expand.rs:19-33`; no aliases upstream. Its
        // `ModeSupport::MinimalOnly(UseInstead)` gate lives with the
        // dispatch arm, the `/timeline` precedent.
        PagerCommandDefinition(
            name: "expand",
            summary: "Re-print the last collapsed block, fully expanded (minimal mode)",
            usage: "/expand"
        ),
        PagerCommandDefinition(
            name: "context",
            summary: "View context usage"
        ),
        // `/usage`, alias `/cost` (`slash/commands/usage.rs:10-16`). The
        // usage string is the non-consumer grammar (`usage.rs:57-61`, bare
        // `/usage` only): this port has no billing surface, so advertising
        // upstream's `[show|manage]` arms would register rows with no
        // backing.
        PagerCommandDefinition(
            name: "usage",
            aliases: ["cost"],
            summary: "View session token usage",
            usage: "/usage"
        ),
        PagerCommandDefinition(
            name: "cache",
            aliases: ["cache-status", "prompt-cache"],
            summary: "View prompt cache hit rates, prefix divergence, and break diagnostics",
            usage: "/cache"
        ),
        // B2-S2: the screen-mode switchers, upstream's registry position —
        // after `/context`, before `/model` (`slash/commands/mod.rs:99-101`).
        // Name, alias, description, and usage verbatim
        // (`screen_mode_switch.rs:36-60`). Upstream hides each in its own
        // mode ("visible only in the opposite mode"); this port's
        // `PagerCommandDefinition` has no mode-visibility channel — the
        // `/timeline` precedent — so both rows list everywhere and the
        // dispatch refuses with upstream's AlreadyInMode copy
        // (`mode_support.rs:55`). Recorded divergence.
        PagerCommandDefinition(
            name: "minimal",
            summary: "Reopen this session in minimal (scrollback-native) mode — switch back with /fullscreen",
            usage: "/minimal"
        ),
        PagerCommandDefinition(
            name: "fullscreen",
            aliases: ["full"],
            summary: "Reopen this session in fullscreen mode — switch back with /minimal",
            usage: "/fullscreen"
        ),
        PagerCommandDefinition(
            name: "model",
            aliases: ["m"],
            summary: "Switch the active model",
            usage: "/model [name]"
        ),
        // `/effort` (`slash/commands/effort.rs:14-30`): reasoning effort on
        // the current model without re-picking it.
        PagerCommandDefinition(
            name: "effort",
            summary: "Set reasoning effort for the current model",
            usage: "/effort <level>"
        ),
        // `/fast` (`slash/commands/fast.rs:11-29`); name, description and
        // usage verbatim, placed immediately after `/effort`
        // (`slash/commands/mod.rs:102-105`, "Immediately after /model (Codex
        // catalogs expose Fast as a service tier)"). Divergence: upstream's
        // `visible()` hides the row unless the current model supports Fast
        // (fast.rs:27-29); this registry is fixed at construction, so the row
        // is always registered and dispatch answers a non-supporting model
        // with upstream's error copy (fast.rs:36) instead.
        PagerCommandDefinition(
            name: "fast",
            summary: "Toggle Fast mode (priority routing) for the current model",
            usage: "/fast"
        ),
        // `/always-approve` (`slash/commands/always_approve.rs:16-32`);
        // summary is upstream's description verbatim (`always_approve.rs:21-23`),
        // placed after `/fast` and before `/multiline` because this port
        // has no `/auto` (`slash/commands/mod.rs:106-109`).
        PagerCommandDefinition(
            name: "always-approve",
            summary: "Toggle always-approve mode (skip all permission prompts)",
            usage: "/always-approve"
        ),
        PagerCommandDefinition(
            name: "multiline",
            aliases: ["ml"],
            summary: "Toggle multiline input mode (swap Enter and Shift+Enter)"
        ),
        // `/compact-mode` between `/multiline` and `/vim-mode`, upstream's
        // display order (`slash/commands/mod.rs:108-110`). Name, description,
        // and usage verbatim (`compact_mode.rs:16-27`); no aliases upstream.
        PagerCommandDefinition(
            name: "compact-mode",
            summary: "Toggle compact UI (less padding, more content)",
            usage: "/compact-mode"
        ),
        PagerCommandDefinition(
            name: "vim-mode",
            summary: "Toggle vim-style scrollback keybindings (j/k, h/l, g/G, y/Y, …)"
        ),
        // `/hooks`, `/plugins`, `/marketplace`, `/skills`
        // (`slash/commands/plugin.rs:15-106`): names, descriptions and usage
        // verbatim, in upstream's display order after `/vim-mode`
        // (`slash/commands/mod.rs:110-114`; upstream's `/share` neighbor is
        // not ported). All four open the tabbed extensions modal on their
        // tab — a read-only viewer here, so the modal advertises no
        // add/remove/toggle/install keys (recorded divergence).
        PagerCommandDefinition(
            name: "hooks",
            summary: "View hooks",
            usage: "/hooks"
        ),
        PagerCommandDefinition(
            name: "plugins",
            summary: "View plugins",
            usage: "/plugins"
        ),
        PagerCommandDefinition(
            name: "marketplace",
            summary: "View marketplace",
            usage: "/marketplace"
        ),
        PagerCommandDefinition(
            name: "skills",
            summary: "View skills",
            usage: "/skills"
        ),
        PagerCommandDefinition(
            name: "session-info",
            summary: "Show session info"
        ),
        PagerCommandDefinition(
            name: "workflows",
            summary: "Show workflow runs (phases, agents, progress)"
        ),
        // `/mcps` (`slash/commands/mcps.rs:7-17`).
        PagerCommandDefinition(
            name: "mcps",
            summary: "Show MCP server status",
            usage: "/mcps"
        ),
        // `/timestamps`, `/timeline`, `/toggle-mouse-reporting` — upstream's
        // display order, three adjacent rows (`slash/commands/mod.rs:137-139`;
        // `/imagine`/`/imagine-video` before them are CLI-layer commands in
        // this port). Name, description, and usage verbatim
        // (`timestamps.rs:12-23`); no aliases upstream. Upstream's
        // `arg_placeholder` "on/off" (`timestamps.rs:25-27`) has no
        // `PagerCommandDefinition` channel — and `run` ignores its args
        // either way (`timestamps.rs:29`, `_args`).
        PagerCommandDefinition(
            name: "timestamps",
            summary: "Toggle message timestamps on/off",
            usage: "/timestamps"
        ),
        // Copy verbatim from `timeline.rs:13-19,27-29`; no aliases and no
        // `arg_placeholder` upstream. Upstream's
        // `ModeSupport::FullscreenOnly` (`timeline.rs:21-25`) has no
        // `PagerCommandDefinition` channel; the mode gate lives with the
        // render layer's toggle handler, the `/jump` precedent.
        PagerCommandDefinition(
            name: "timeline",
            summary: "Toggle the timeline sidebar",
            usage: "/timeline"
        ),
        // Gated at session construction on `[ui] mouse_reporting_toggle` /
        // `GROK_MOUSE_REPORTING_TOGGLE` (`toggle_mouse_reporting.rs:32-46`):
        // hidden + unavailable when the opt-in flag is off; the static row
        // stays here so registry order pins keep the adjacent triple.
        PagerCommandDefinition(
            name: "toggle-mouse-reporting",
            summary: "Toggle terminal mouse reporting (native click-drag copy/paste)"
        ),
        PagerCommandDefinition(
            name: "queue",
            summary: "List the prompts queued behind the running turn"
        ),
        // `/tasks` follows `/queue`, upstream's display order
        // (`slash/commands/mod.rs:148-149`). Name, summary and usage are
        // verbatim (`tasks.rs:16-30`).
        PagerCommandDefinition(
            name: "tasks",
            summary: "List background tasks, subagents, and scheduled tasks",
            usage: "/tasks"
        ),
        // `/release-notes` follows `/tasks`, upstream's registry order
        // (`slash/commands/mod.rs:150`, between `/tasks` and `/tutorial`;
        // `/tutorial` sits further down this table, so the pinned RELATIVE
        // pair is `/tasks` → `/release-notes` — the E20/E21 convention).
        // Name, alias, description and usage are verbatim
        // (`release_notes.rs:10-25`).
        PagerCommandDefinition(
            name: "release-notes",
            aliases: ["changelog"],
            summary: "View release notes for the current version",
            usage: "/release-notes"
        ),
        // `/btw` (`slash/commands/btw.rs:12-38`). Upstream fires an ACP ext
        // method that bypasses the prompt queue (`x.ai/btw` →
        // `handle_side_question`); this port emits the `.sideQuestion`
        // intent and the render layer runs the same off-conversation side
        // sample — mid-turn or idle, the question never waits behind the
        // backlog and never mutates the conversation.
        PagerCommandDefinition(
            name: "btw",
            summary: "Ask a side question without interrupting",
            usage: "/btw <question>"
        ),
        // `/recap` follows `/btw`, upstream's display order
        // (`slash/commands/mod.rs:130-131`). Name, alias, description and
        // usage are verbatim (`recap.rs:14-32`). Divergence, shared with
        // `/fast`: upstream's registry hides the row until the shell
        // advertises `session_recap` (default ON, `agent/config.rs:2657-2667`);
        // this registry is fixed at construction, so the row is always
        // registered and the render layer answers a disabled or session-less
        // invocation with upstream's copy instead.
        PagerCommandDefinition(
            name: "recap",
            aliases: ["summarize"],
            summary: "Summarize the session so far",
            usage: "/recap"
        ),
        // `/doctor` follows `/recap`, upstream's display order
        // (`slash/commands/mod.rs:131-132`). Name, aliases, description
        // and usage are verbatim (`doctor.rs:45-59`).
        PagerCommandDefinition(
            name: "doctor",
            aliases: ["terminal-setup", "terminal-check", "terminal-info"],
            summary: "Check this session and show available fixes",
            usage: "/doctor [fix [FIX]]"
        ),
        PagerCommandDefinition(
            name: "compact",
            summary: "Compact conversation history",
            usage: "/compact [instructions]",
            // The one command that must never run inline: it rewrites the
            // items a streaming turn is sampling from.
            mutatesConversationHistory: true
        ),
        PagerCommandDefinition(
            name: "settings",
            aliases: ["config", "preferences", "prefs"],
            summary: "Open the settings modal"
        ),
        PagerCommandDefinition(
            name: "privacy",
            summary: "Open coding data, retention, and training settings"
        ),
        PagerCommandDefinition(
            name: "theme",
            aliases: ["t"],
            summary: "Switch the color theme",
            usage: "/theme [name]"
        ),
        PagerCommandDefinition(
            name: "tutorial",
            aliases: ["tour", "onboarding"],
            summary: "Quick tips to get the most out of Open Grok"
        ),
        // `/config-agents` and `/personas` follow `/tutorial`, upstream's
        // registry order (`slash/commands/mod.rs:150-153`). Names, alias,
        // descriptions and usage are verbatim (`config_agents.rs:10-24`,
        // `personas.rs:11-25`) — including the mutation verbs in the
        // `/personas` description, which are upstream's own copy; this
        // port's b1 modal browses read-only (create/edit/delete are
        // B9-b2/b3) and its FOOTER advertises only the keys it handles.
        PagerCommandDefinition(
            name: "config-agents",
            aliases: ["agents"],
            summary: "Manage agent definitions",
            usage: "/config-agents"
        ),
        PagerCommandDefinition(
            name: "personas",
            summary: "Manage personas (create, edit, delete)",
            usage: "/personas"
        ),
        PagerCommandDefinition(
            name: "rewind",
            aliases: ["undo"],
            summary: "Rewind to a previous turn",
            usage: "/rewind [n] [--mode=all|files|conversation] [--force]",
            // A forced rewind rewrites history and restores files. Running that
            // against the item list a turn is sampling from is the same hazard
            // `/compact` carries, so it takes the same deferral.
            mutatesConversationHistory: true
        ),
        PagerCommandDefinition(
            name: "jump",
            summary: "Jump to a turn in the conversation"
        ),
        // `/login` and `/logout` sit after `/jump`, upstream's display order
        // (`slash/commands/mod.rs:143-145`). Summaries and usage are verbatim
        // (`login.rs:108-114`, `logout.rs:13-19`); both arguments are
        // optional (`[...]`), so a bare Enter dispatches instead of parking
        // in the argument phase.
        PagerCommandDefinition(
            name: "login",
            summary: "Connect xAI, OpenAI Codex, Kimi, Fireworks AI, DeepSeek, Meta API, Wafer AI, or OpenCode Go",
            usage: "/login [xai|codex|kimi|fireworks|deepseek|meta|wafer|opencode-go]"
        ),
        PagerCommandDefinition(
            name: "logout",
            summary: "Log out of xAI or OpenAI Codex",
            usage: "/logout [codex]"
        ),
        PagerCommandDefinition(
            name: "delete",
            summary: "Delete this session and return home"
        ),
        // `/rename`, alias `/title` (`slash/commands/rename.rs:10-28`).
        PagerCommandDefinition(
            name: "rename",
            aliases: ["title"],
            summary: "Rename the current session",
            usage: "/rename <title>"
        ),
        // B1-d: `/dashboard` follows `/rename`, upstream's registry order
        // (`slash/commands/mod.rs:117-118` — `/cd` sits between it and
        // `/theme` upstream but is dashboard-only and lands with B1-c).
        // Name, aliases, description, usage verbatim (`dashboard.rs:27-52`);
        // `/sessions` survives the sessions-modal removal as an alias. The
        // minimal ModeSupport refusal lives with the dispatch arm; the
        // feature gate with the render layer, which owns the environment.
        PagerCommandDefinition(
            name: "dashboard",
            aliases: ["agents-dashboard", "sessions"],
            summary: "Open the Agent Dashboard — a fullscreen overview of every running session",
            usage: "/dashboard"
        ),
        PagerCommandDefinition(
            name: "remember",
            summary: "Save a memory note",
            usage: "/remember [text]"
        ),
        // `/plan`, `/swarm` and `/view-plan` sit after `/remember`, in
        // upstream's display order (`slash/commands/mod.rs:123-126`). Names,
        // aliases, summaries and usage are verbatim (`plan.rs:15-43`,
        // `swarm.rs:9-23`, `view_plan.rs:10-28`). All three arguments are
        // optional, so a bare Enter dispatches. Upstream's
        // `arg_placeholder` hints (`plan.rs:41-43`, `swarm.rs:21-23`) have
        // no port channel — `PagerCommandDefinition` carries no placeholder
        // field — so the usage string is the only argument hint (recorded
        // divergence).
        PagerCommandDefinition(
            name: "plan",
            summary: "Enter plan mode",
            usage: "/plan [description]"
        ),
        PagerCommandDefinition(
            name: "swarm",
            summary: "Toggle swarm mode or run a one-shot swarm task",
            usage: "/swarm [on|off|task]"
        ),
        PagerCommandDefinition(
            name: "view-plan",
            aliases: ["show-plan", "plan-view"],
            summary: "View the current plan",
            usage: "/view-plan"
        ),
        PagerCommandDefinition(
            name: "recall",
            summary: "Search workspace memory",
            usage: "/recall <query>"
        ),
        PagerCommandDefinition(
            name: "flush",
            summary: "Write notes to this session's memory log",
            usage: "/flush <notes>"
        ),
        PagerCommandDefinition(
            name: "dream",
            summary: "Consolidate session logs into durable memory",
            usage: "/dream"
        ),
        PagerCommandDefinition(
            name: "voice",
            summary: "Toggle microphone dictation into the prompt",
            usage: "/voice"
        ),
        PagerCommandDefinition(
            name: "goal",
            summary: "Set or inspect the session goal",
            usage: "/goal [objective|status|pause|resume|clear]"
        ),
        // `/debug [fps]` — always registered and routable; listed only on
        // debug binaries (`debug.rs:24-29` `LISTED_IN_COMPLETIONS =
        // cfg!(debug_assertions)`). Scroll/log HUD surfaces are absent, so
        // usage is `[fps]` only — no no-op subcommand rows.
        PagerCommandDefinition(
            name: "debug",
            summary: "Toggle debug overlays",
            usage: "/debug [fps]",
            isHidden: {
                #if DEBUG
                false
                #else
                true
                #endif
            }()
        ),
        PagerCommandDefinition(
            name: "gboom",
            summary: "Hidden easter egg",
            isHidden: true
        )
    ]

    public static var builtinCommandCatalog: [OpenGrokPagerCommandRegistration] {
        builtinCommands.map { command in
            OpenGrokPagerCommandRegistration(
                name: command.name,
                aliases: command.aliases,
                summary: command.summary,
                usage: command.usage
            )
        }
    }

    /// Builtin rows advertised to the model / ACP client after applying the
    /// same startup gates the interactive controller uses for the slash
    /// dropdown (`workflows` kill-switch + mouse-reporting toggle opt-in).
    public static func visibleBuiltinCommandCatalog(
        workflowsEnabled: Bool = true,
        mouseReportingToggleEnabled: Bool = false
    ) -> [OpenGrokPagerCommandRegistration] {
        sessionBuiltinCommands(
            workflowsEnabled: workflowsEnabled,
            mouseReportingToggleEnabled: mouseReportingToggleEnabled
        )
        .filter { !$0.isHidden && $0.availability.isAvailable }
        .map { command in
            OpenGrokPagerCommandRegistration(
                name: command.name,
                aliases: command.aliases,
                summary: command.summary,
                usage: command.usage
            )
        }
    }

    public static var builtinCommandNames: Set<String> {
        Set(builtinCommands.flatMap(\.allNames))
    }

    /// Hint returned when `/toggle-mouse-reporting` is invoked while the
    /// opt-in gate is off — byte-identical to upstream
    /// `toggle_mouse_reporting.rs:42-44`.
    public static let mouseReportingToggleUnavailableMessage =
        "Mouse reporting toggle is off. Set `[ui] mouse_reporting_toggle = true` "
        + "in ~/.opengrok/config.toml to enable it."

    /// Apply the session-scoped feature gates to the static builtin table.
    /// `/workflows` is dropped when disabled; `/toggle-mouse-reporting` stays
    /// resolvable but hidden and unavailable so a direct invoke is honest.
    static func sessionBuiltinCommands(
        workflowsEnabled: Bool,
        mouseReportingToggleEnabled: Bool
    ) -> [PagerCommandDefinition] {
        builtinCommands.compactMap { command in
            if command.name == "workflows", !workflowsEnabled {
                return nil
            }
            if command.name == "toggle-mouse-reporting", !mouseReportingToggleEnabled {
                return PagerCommandDefinition(
                    name: command.name,
                    summary: command.summary,
                    usage: command.usage,
                    availability: .unavailable(
                        reason: mouseReportingToggleUnavailableMessage
                    ),
                    isHidden: true
                )
            }
            return command
        }
    }

    /// The settings row `/privacy` deep-links to
    /// (`PagerSettingsRegistry.swift:856`), matching upstream's
    /// `CODING_DATA_SHARING_KEY`.
    static let codingDataSharingKey = "coding_data_sharing"

    /// `PendingAction::TTL` (`app_view.rs:591`) — a confirmation stays armed
    /// for one second and any other key clears it.
    private static let confirmationTimeToLive: TimeInterval = 1.0

    private func promptState() -> OpenGrokPagerInteractivePromptState {
        expirePendingConfirmation()
        return editor.state(
            pendingKey: pendingConfirmation?.key,
            pendingLabel: pendingConfirmation?.label
        )
    }

    private func expirePendingConfirmation() {
        if let pending = pendingConfirmation, pending.deadline <= Date() {
            pendingConfirmation = nil
        }
    }

    /// Returns true when `key` was already armed, i.e. this is the confirming
    /// second press.
    private func confirm(key: String, label: String) -> Bool {
        expirePendingConfirmation()
        if let pending = pendingConfirmation, pending.key == key {
            pendingConfirmation = nil
            return true
        }
        pendingConfirmation = (
            key: key,
            label: label,
            deadline: Date().addingTimeInterval(Self.confirmationTimeToLive)
        )
        return false
    }

    private func refreshCompletions() {
        // Esc closed the menu; it stays closed until the text changes.
        guard !editor.completionsDismissed else {
            editor.completions = []
            editor.selectedCompletion = nil
            return
        }
        let suggestions: [OpenGrokPagerCommandSuggestion]
        if let argumentPhase = Self.argumentPhase(for: editor.text) {
            // Once the command name is settled the dropdown belongs to the
            // arguments — `commands.completions` would return nothing here
            // anyway, since it refuses any input containing whitespace. The
            // host's provider gets first refusal; commands whose argument
            // vocabulary lives pager-side fall through to the built-ins.
            let provided = argumentSuggestions?(argumentPhase.command, argumentPhase.query) ?? []
            suggestions = provided.isEmpty
                ? Self.builtinArgumentSuggestions(
                    command: argumentPhase.command,
                    query: argumentPhase.query
                )
                : provided
        } else {
            // Recency scores resolved in one pass, keyed by canonical name —
            // one keystroke, one store read (`slash/mod.rs:985-992`).
            let now = UInt64(Date().timeIntervalSince1970)
            var recency: [String: UInt64] = [:]
            for command in commands.commands where !command.isHidden {
                let score = slashMru.rankScore(command.name, now: now)
                if score > 0 { recency[command.name] = score }
            }
            suggestions = commands
                .completions(for: editor.text, recency: recency)
                .map {
                    OpenGrokPagerCommandSuggestion(
                        name: $0.displayName,
                        summary: $0.summary,
                        isAvailable: $0.availability.isAvailable
                    )
                }
        }
        // No row cap: every match rides through and the dropdown renderer
        // scrolls the six-row window ("No cap here -- the dropdown renderer
        // handles scrolling", `slash/mod.rs:866-867`). The old `prefix(6)`
        // here is what made `/theme` unreachable from a bare `/`.
        editor.completions = suggestions
        editor.selectedCompletion = editor.completions.isEmpty ? nil : 0
    }

    /// Argument rows for commands whose vocabulary lives inside the pager
    /// targets: `/theme` (`ThemeCommand::suggest_args`,
    /// `slash/commands/theme.rs:81-110`, run through the arg matcher,
    /// `slash/mod.rs:1070-1085`), `/login`, and `/logout` (their provider
    /// tables live in `PagerLoginProviders`).
    ///
    /// The `(active)` marker upstream appends to `/theme` rows is
    /// deliberately absent: the controller does not own the live theme (the
    /// render layer does), and a guessed marker would be wrong exactly when
    /// it matters.
    static func builtinArgumentSuggestions(
        command: String,
        query: String
    ) -> [OpenGrokPagerCommandSuggestion] {
        switch command {
        case "theme", "t":
            let names = ["auto"] + PagerThemeKind.selectable.map(\.displayName)
            let rows = names.map { name in
                OpenGrokPagerCommandSuggestion(
                    name: name,
                    summary: name == "auto" ? "auto (follow system)" : name,
                    // The row commits the whole composer text, not the bare
                    // argument — accepting must leave `/theme Tokyo Night`.
                    insertText: "/theme \(name)"
                )
            }
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return rows }
            let matcher = PagerFuzzyMatcher()
            return matcher
                .rank(rows, query: trimmed, limit: rows.count) { $0.name }
                .map { rows[$0.index] }
        case "docs", "howto", "guides":
            // `DocsCommand::suggest_args` (`docs.rs:46-68`) — "how-to" and
            // "web" first, then every guide title. The corpus lives in this
            // module (`PagerDocs`), so the rows do too. Aliases are
            // enumerated because the argument phase hands over the typed
            // name, not the canonical one — the `/theme`/`/t` convention.
            return PagerDocs.argumentSuggestions(query: query)
        case "login":
            // `LoginCommand::suggest_args` (`login.rs:124-126`) — the eight
            // providers with the provider-neutral descriptions; live secret
            // statuses belong to the bare-`/login` modal only.
            return PagerLoginProviders.suggestions(query: query)
        case "logout":
            // `LogoutCommand::suggest_args` (`logout.rs:29-36`).
            return PagerLoginProviders.logoutSuggestions(query: query)
        case "debug":
            // Only `fps` — scroll/log HUD surfaces are absent, so those
            // subcommands are not offered (no no-op entries).
            let rows = [
                OpenGrokPagerCommandSuggestion(
                    name: "fps",
                    summary: "Toggle the FPS overlay",
                    insertText: "/debug fps"
                )
            ]
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return rows }
            let matcher = PagerFuzzyMatcher()
            return matcher
                .rank(rows, query: trimmed, limit: rows.count) { $0.name }
                .map { rows[$0.index] }
        default:
            return []
        }
    }

    /// `/model codex:` → `(command: "model", query: "codex:")`.
    ///
    /// The phase opens at the first whitespace after the command name, which is
    /// upstream's rule too: a trailing space is what moves the `/model`
    /// dropdown from the model list into the effort sub-menu. So `/model ` is a
    /// real query that happens to be empty, not an absent one — the whitespace
    /// decides the phase before it is trimmed out of the query.
    static func argumentPhase(for input: String) -> (command: String, query: String)? {
        let leading = input.drop { $0.isWhitespace }
        guard leading.first == "/" else { return nil }
        let body = leading.dropFirst()
        guard let split = body.firstIndex(where: { $0.isWhitespace }) else { return nil }
        let command = PagerCommandDefinition.normalize(String(body[..<split]))
        guard !command.isEmpty else { return nil }
        let query = body[body.index(after: split)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (command, query)
    }

    /// Step to an older (`offset < 0`) or newer prompt. Paging past the newest
    /// entry closes browsing and restores the stashed draft, mirroring
    /// `close_history_restoring_saved` (`prompt.rs:997`).
    private func browseHistory(offset: Int) {
        guard !history.isEmpty else { return }
        guard let current = historyIndex else {
            // Down never opens browsing — only Up does.
            guard offset < 0 else { return }
            historySavedDraft = editor.text
            historyIndex = history.count - 1
            editor.isBrowsingHistory = true
            editor.replace(with: history[history.count - 1])
            refreshCompletions()
            return
        }
        let candidate = current + (offset < 0 ? -1 : 1)
        guard candidate < history.count else {
            editor.replace(with: historySavedDraft ?? "")
            detachHistory()
            refreshCompletions()
            return
        }
        let index = max(0, candidate)
        historyIndex = index
        editor.replace(with: history[index])
        refreshCompletions()
    }

    private func detachHistory() {
        historyIndex = nil
        historySavedDraft = nil
        editor.isBrowsingHistory = false
    }

    private func recordHistory(_ prompt: String) {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if history.last != prompt { history.append(prompt) }
        detachHistory()
    }

    /// Esc / Ctrl+C policy, mirroring `try_handle_esc_policy`
    /// (`app/agent_view/prompt.rs:841`) and the Ctrl+C handler
    /// (`app/agent_view/input.rs:1359`).
    ///
    /// The load-bearing asymmetries: Esc cancels a running turn even with a
    /// draft in the composer, while Ctrl+C clears the draft first and only
    /// cancels on the second press. When idle, Esc arms a clear and is
    /// otherwise swallowed — it never exits — whereas Ctrl+C on an empty
    /// composer arms a quit.
    private func handleInterrupt(isEscape: Bool, isTurnRunning: Bool) -> InterruptOutcome {
        // The dropdown intercepts Esc ahead of the whole cancel/clear ladder
        // (`prompt.rs:229-233`), idle or mid-turn: close the menu, keep the
        // draft, arm nothing. This must live here rather than in the
        // editor's key map — the input pump classifies a bare Esc as a
        // control signal before the editor ever sees the event, so an
        // editor-side close is unreachable in a live run.
        if isEscape, editor.dismissCompletions() {
            return .consumed
        }
        if isTurnRunning {
            if !isEscape, !editor.text.isEmpty {
                editor.reset()
                detachHistory()
                pendingConfirmation = nil
                return .consumed
            }
            return .cancelTurn
        }
        if !editor.text.isEmpty {
            if isEscape {
                if confirm(key: "Esc", label: "clear") {
                    editor.reset()
                    detachHistory()
                }
            } else {
                editor.reset()
                detachHistory()
                pendingConfirmation = nil
            }
            return .consumed
        }
        guard !isEscape else { return .consumed }
        return confirm(key: "Ctrl+c", label: "quit") ? .quit : .consumed
    }

    /// The outcome of a locally handled slash command.
    private enum SlashOutcome {
        case notACommand
        case handled
        case quit
        case submit(String)
        /// The command already put work at the front of the queue — an idle
        /// caller must kick the drain, the port of
        /// `maybe_start_running_task` after the fallback enqueue
        /// (run_loop.rs:1984-1988). Mid-turn callers treat it as `.handled`:
        /// the queue drains when the running turn ends. No command returns
        /// this since `/btw` became a real side question (the stranded-flush
        /// path enqueues outside the slash grammar); the arm stays for the
        /// next front-inserting command.
        case drain
    }

    /// Run a slash command.
    ///
    /// `isTurnRunning` is what keeps a history-mutating command from firing
    /// while the sampler is streaming. It is deliberately a parameter rather
    /// than read from state: the two callers are the idle-loop submit and the
    /// mid-turn submit, and making each say which it is means the guarantee
    /// cannot be lost again by someone adding a third caller.
    private func runSlashCommand(
        _ text: String,
        isTurnRunning: Bool = false
    ) async throws -> SlashOutcome {
        guard case .command(let invocation) = PagerCommandParser.parse(text) else {
            return .notACommand
        }
        switch commands.resolve(invocation) {
        case .unknown(let name):
            try await emit(.notice("unknown command: /\(name)"))
            return .handled
        case .unavailable(_, let reason):
            try await emit(.notice(reason))
            return .handled
        case .available(let command) where isTurnRunning
            && command.mutatesConversationHistory:
            // Queue it as written, so it runs against a settled conversation
            // once the turn ends — upstream's `CommandResult::QueueCommand`.
            try await enqueue(text)
            try await emit(.notice(
                "/\(command.name) edits the conversation, so it will run when this turn finishes."
            ))
            return .handled
        case .available(let command):
            if localCommandNames.contains(command.name) {
                guard let localCommandHandler else {
                    try await emit(.notice("/\(command.name) is unavailable in this session"))
                    return .handled
                }
                switch try await localCommandHandler(invocation) {
                case .notice(let notice)?:
                    if !notice.isEmpty {
                        try await emit(.notice(notice))
                    }
                    return .handled
                case .submit(let generatedPrompt)?:
                    // The host command expanded into a model prompt
                    // (upstream's `CommandResult::InjectSkill` — `/imagine`).
                    // Returning `.submit` here rides the same enqueue path
                    // the skill commands use, including the mid-turn
                    // deferral at every call site.
                    return .submit(generatedPrompt)
                case nil:
                    return .handled
                }
            }
            if customCommandNames.contains(command.name) {
                guard let customCommandHandler else {
                    try await emit(.notice("/\(command.name) is unavailable in this session"))
                    return .handled
                }
                guard let generatedPrompt = try await customCommandHandler(invocation) else {
                    try await emit(.notice("/\(command.name) could not load its skill definition"))
                    return .handled
                }
                return .submit(generatedPrompt)
            }
            switch command.name {
            case "quit":
                return .quit
            case "new":
                try await startNewSession()
                return .handled
            case "help":
                try await emit(.overlay(.help))
                return .handled
            case "docs":
                // `DocsCommand::run` (`docs.rs:70-87`). The argument is the
                // raw tail trimmed — upstream's `args.trim()` — NOT the
                // tokenizer's rejoin: a quoted or double-spaced title must
                // fail the lookup exactly as it does upstream, and the
                // unknown-target echo must quote what the user typed.
                let target = Self.rawArgumentTail(of: invocation)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if target.isEmpty || PagerDocs.isHowtoListArgument(target) {
                    try await emit(.overlay(.howtoGuides))
                    return .handled
                }
                if PagerDocs.isWebArgument(target) {
                    try await emit(.overlay(.openURL(PagerDocs.buildDocsURL)))
                    return .handled
                }
                if let doc = PagerDocs.find(title: target) {
                    try await emit(.overlay(.showDocument(
                        title: doc.title,
                        content: doc.content
                    )))
                    return .handled
                }
                // `CommandResult::Error` (docs.rs:83-85) on the notice
                // channel, like every command error here; copy byte-exact
                // including the Rust `{:?}` quoting.
                try await emit(.notice(PagerDocs.unknownTargetMessage(target)))
                return .handled
            case "home":
                try await emit(.overlay(.welcomeScreen))
                return .handled
            case "workflows":
                try await emit(.overlay(.workflows))
                return .handled
            case "history":
                try await emit(.overlay(.promptHistory(entries: history)))
                return .handled
            case "queue":
                try await emit(.overlay(.promptQueue(
                    entries: await promptQueue.orderedTexts
                )))
                return .handled
            case "context":
                try await emit(.overlay(.contextUsage))
                return .handled
            case "usage":
                // Non-consumer arm only (`usage.rs:57-61`): bare `/usage`
                // shows the readout; any argument is refused with upstream's
                // copy. `show`/`manage` belong to the billing surface this
                // port does not have.
                let usageArgument = Self.rejoined(invocation.arguments)
                guard usageArgument.isEmpty else {
                    try await emit(.notice(
                        "Unknown argument: \(usageArgument). Use /usage"
                    ))
                    return .handled
                }
                try await emit(.overlay(.usage))
                return .handled
            case "cache", "cache-status", "prompt-cache":
                let cacheArgument = Self.rejoined(invocation.arguments)
                guard cacheArgument.isEmpty else {
                    try await emit(.notice(
                        "Unknown argument: \(cacheArgument). Use /cache"
                    ))
                    return .handled
                }
                try await emit(.overlay(.cache))
                return .handled
            case "resume":
                // Bare `/resume` opens the picker (`resume.rs:21-23`); the
                // argument form exists only as the picker's return path — a
                // selected row round-trips as `/resume <session-id>`.
                let sessionArgument = Self.rejoined(invocation.arguments)
                guard !sessionArgument.isEmpty else {
                    try await emit(.overlay(.sessionPicker))
                    return .handled
                }
                try await resumeStoredSession(sessionID: sessionArgument)
                return .handled
            case "btw":
                let question = Self.rejoined(invocation.arguments)
                guard !question.isEmpty else {
                    try await emit(.notice("Usage: /btw <question>"))
                    return .handled
                }
                // The real side-question semantics (`Action::SendBtw`,
                // btw.rs:40-42 → `x.ai/btw` → `handle_side_question`,
                // acp_session_impl/recap.rs:70-180): the question is
                // answered OFF-conversation over a snapshot — mid-turn or
                // idle, it bypasses the prompt queue and never touches the
                // running turn. The snapshot, the model route and the
                // render live in the render layer, which owns the live
                // sampling stack. (E5 routed this through the interjection
                // seam — a recorded divergence this slice closes; the seam
                // itself stays for the subagent collaboration producers.)
                try await emit(.overlay(.sideQuestion(question: question)))
                return .handled
            case "recap":
                // Arguments are ignored — upstream's `RecapCommand::run`
                // declares none and discards what it gets (recap.rs:34,
                // `_args`). The snapshot, the helper model, and the failure
                // copy all live in the render layer, which owns the live
                // sampling stack.
                try await emit(.overlay(.recap))
                return .handled
            case "doctor":
                // `DoctorCommand::run` (doctor.rs:104-117): the grammar runs
                // on whitespace-split tokens of the RAW tail — upstream's
                // `args.split_whitespace()` never unquotes, so re-splitting
                // the tokenizer's unquoted arguments would accept forms
                // upstream rejects. `fix <value>` ships the selector raw;
                // the render layer owns `resolve_fix_id` and answers a typo
                // with upstream's error + usage copy.
                let doctorTokens = Self.rawArgumentTail(of: invocation)
                    .split(whereSeparator: { $0.isWhitespace })
                    .map(String.init)
                if doctorTokens.isEmpty {
                    try await emit(.overlay(.doctor(request: .report)))
                } else if doctorTokens == ["fix"] {
                    try await emit(.overlay(.doctor(request: .listFixes)))
                } else if doctorTokens.count == 2, doctorTokens[0] == "fix" {
                    try await emit(.overlay(.doctor(request: .fix(id: doctorTokens[1]))))
                } else {
                    // `CommandResult::Error(USAGE)` (doctor.rs:114-116) on
                    // the notice channel, like every command error here.
                    try await emit(.notice(OpenGrokPagerDoctorRequest.usage))
                }
                return .handled
            case "mcps":
                try await emit(.overlay(.mcpServers))
                return .handled
            case "hooks", "plugins", "marketplace", "skills":
                // Arguments are ignored — upstream's four commands declare
                // none and discard what they get (`plugin.rs:28,52,76,100`,
                // `_args`); each dispatches `Action::OpenExtensionsModal`
                // with its tab. The snapshots live in the render layer,
                // which owns the loaders.
                let tab: OpenGrokPagerExtensionsTab
                switch command.name {
                case "hooks": tab = .hooks
                case "plugins": tab = .plugins
                case "marketplace": tab = .marketplace
                default: tab = .skills
                }
                try await emit(.overlay(.extensions(tab: tab)))
                return .handled
            case "fork":
                // The grammar runs on the raw argument tail, not the
                // tokenizer's unquoted `arguments`: flags are recognized
                // only at the start and an unknown token conservatively
                // starts the directive (`parse_fork_args`, fork.rs:34-49),
                // so re-splitting would corrupt it. A parse error is
                // upstream's `CommandResult::Error` (fork.rs:133), mapped
                // onto the notice channel like every command error here.
                switch PagerForkArguments.parse(Self.rawArgumentTail(of: invocation)) {
                case .success(let arguments):
                    try await emit(.overlay(.fork(
                        worktreeOverride: arguments.worktreeOverride,
                        directive: arguments.directive
                    )))
                case .failure(let error):
                    try await emit(.notice(error.message))
                }
                return .handled
            case "tasks":
                // Arguments are ignored — upstream's `TasksCommand::run`
                // declares none and discards what it gets (tasks.rs:32-37).
                // Its "No active session" arm lives in the live renderer,
                // the only layer that owns a session id here.
                try await emit(.overlay(.showTasks))
                return .handled
            case "dashboard":
                // `ModeSupport::FullscreenOnly(SwitchMode)` with upstream's
                // why-fragment verbatim (`dashboard.rs:55-59` over
                // `mode_support.rs:47-51`). The inline strip keeps the
                // command — the roster is a modal this port can paint there.
                guard activePagerMode != .minimal else {
                    try await emit(.notice(
                        "/dashboard isn't available in minimal mode (minimal is single-session). Run /fullscreen to switch this session."
                    ))
                    return .handled
                }
                try await emit(.overlay(.showDashboard))
                return .handled
            case "release-notes":
                // Arguments are ignored — upstream's `ReleaseNotesCommand::run`
                // declares `_args` (release_notes.rs:27). The fetch, the
                // `Action::ShowReleaseNotes` arm, and the offline error copy
                // (release_notes.rs:28-34) all live with the render layer:
                // the controller cannot do network.
                try await emit(.overlay(.releaseNotes))
                return .handled
            case "effort":
                let level = Self.rejoined(invocation.arguments)
                try await emit(.overlay(.reasoningEffort(
                    query: level.isEmpty ? nil : level
                )))
                return .handled
            case "fast":
                // Arguments are ignored — upstream's `FastCommand::run`
                // declares none and discards what it gets (fast.rs:31,
                // `_args`). The toggle itself needs the catalog and the live
                // sampling stack, both of which live in the render layer.
                try await emit(.overlay(.fastMode))
                return .handled
            case "always-approve":
                // Arguments are ignored — same dispatch either way
                // (`always_approve.rs:29-32`, `Action::SetYoloMode(!current)`).
                // Routes through the same global chord Ctrl+O already uses;
                // the live handle owns the flip.
                try await handleGlobal(.toggleAlwaysApprove, isTurnRunning: isTurnRunning)
                return .handled
            case "rename":
                let title = Self.rejoined(invocation.arguments)
                guard !title.isEmpty else {
                    // Upstream's empty-title refusal (`rename.rs:48-50`).
                    try await emit(.notice("Usage: /rename <new title>"))
                    return .handled
                }
                try await emit(.overlay(.renameSession(title: title)))
                return .handled
            case "session-info":
                try await emit(.overlay(.sessionInfo))
                return .handled
            case "copy":
                let (index, path) = Self.parseCopyArguments(invocation.arguments)
                try await emit(.overlay(.copyResponse(index: index, filePath: path)))
                return .handled
            case "export":
                let path = invocation.arguments.first
                try await emit(.overlay(.exportConversation(filePath: path)))
                return .handled
            case "transcript":
                // Arguments are ignored — same dispatch either way
                // (`transcript.rs:36-41`, `Action::OpenTranscriptPager`).
                try await emit(.overlay(.transcriptPager))
                return .handled
            case "find":
                let query = invocation.arguments
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                try await emit(.overlay(.scrollbackSearch(query: query.isEmpty ? nil : query)))
                return .handled
            case "multiline":
                try await setMultiline(!modes.isMultiline)
                return .handled
            case "vim-mode":
                modes.isVimMode.toggle()
                try await emit(.modeChanged(modes))
                try await emit(.notice(modes.isVimMode
                    ? "Vim scrollback keys on — Tab to focus the scrollback, then j/k/h/l/e/y."
                    : "Vim scrollback keys off — the scrollback still takes arrows, Enter and the Ctrl chords."))
                return .handled
            case "compact-mode":
                // Arguments are ignored — upstream's `CompactModeCommand::run`
                // declares none and discards what it gets
                // (`compact_mode.rs:28`, `_args`). The toggle itself reads the
                // USER value, which lives with the render layer alongside the
                // persist path, so the intent carries no target state.
                try await emit(.overlay(.toggleCompactMode))
                return .handled
            case "compact":
                let instructions = invocation.arguments
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                try await emit(.overlay(.compact(
                    instructions: instructions.isEmpty ? nil : instructions
                )))
                return .handled
            case "settings":
                try await emit(.overlay(.settings(deepLinkKey: nil)))
                return .handled
            case "privacy":
                // The same modal aimed at one row — upstream's
                // `OpenSettingsFocus{key: CODING_DATA_SHARING_KEY}`.
                try await emit(.overlay(.settings(deepLinkKey: Self.codingDataSharingKey)))
                return .handled
            case "theme":
                let name = invocation.arguments
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                try await emit(.overlay(.themePicker(query: name.isEmpty ? nil : name)))
                return .handled
            case "tutorial":
                try await emit(.overlay(.tutorial))
                return .handled
            case "config-agents":
                // Arguments are ignored — upstream's `ConfigAgentsCommand::run`
                // declares `_args` (`config_agents.rs:26-28`) and always
                // opens with no initial tab (Agents).
                try await emit(.overlay(.agentsModal(initialTab: nil)))
                return .handled
            case "personas":
                // `personas.rs:27-29` — the same modal opened on the
                // Personas tab.
                try await emit(.overlay(.agentsModal(initialTab: .personas)))
                return .handled
            case "rewind":
                try await emit(.overlay(.rewind(
                    argument: invocation.arguments.joined(separator: " ")
                )))
                return .handled
            case "jump":
                try await emit(.overlay(.jumpPicker))
                return .handled
            case "delete":
                // Never confirmed from the command itself — the renderer raises
                // a confirmation and only its row sends `confirmed: true`.
                try await emit(.overlay(.deleteSession(confirmed: false)))
                return .handled
            case "remember":
                try await emit(.overlay(.remember(text: Self.rejoined(invocation.arguments))))
                return .handled
            case "recall":
                try await emit(.overlay(.recall(query: Self.rejoined(invocation.arguments))))
                return .handled
            case "flush":
                try await emit(.overlay(.flush(text: Self.rejoined(invocation.arguments))))
                return .handled
            case "dream":
                try await emit(.overlay(.dream))
                return .handled
            case "voice":
                try await emit(.overlay(.voice))
                return .handled
            case "goal":
                try await emit(.overlay(.goal(argument: Self.rejoined(invocation.arguments))))
                return .handled
            case "plan":
                // `/plan` (`plan.rs:45-53`): bare or whitespace-only args arm
                // plan mode; a description enters plan mode and then starts a
                // turn with it. The parser's rejoin collapses interior
                // whitespace runs where upstream's `args.trim()` keeps them —
                // recorded divergence, shared with every prose-argument
                // command here (`/remember`, `/btw`, `/rename`).
                let description = Self.rejoined(invocation.arguments)
                guard !description.isEmpty else {
                    try await emit(.overlay(.planModeOn))
                    return .handled
                }
                if await planModeState?() == true {
                    // Upstream stops without re-arming or sending the prompt
                    // (`dispatch/modes.rs:48-52`); copy byte-identical.
                    try await emit(.notice(
                        "Already in plan mode. Use /view-plan to view the current plan."
                    ))
                    return .handled
                }
                // ORDERING IS LOAD-BEARING (`dispatch/modes.rs:31-36`):
                // upstream bundles the mode switch and the prompt into one
                // sequential `SetModeThenPrompt` effect so the switch
                // completes before the prompt dispatches. Here the guarantee
                // is that `emit` awaits the renderer's `.enterPlanMode`
                // handling — which arms the live plan gate — before the
                // returned `.submit` enqueues the description. Reversed, the
                // description's turn could start sampling with the gate
                // disarmed, and the model's first edits would not be
                // plan-gated.
                try await emit(.overlay(.enterPlanMode))
                return .submit(description)
            case "swarm":
                // `/swarm` (`swarm.rs:42-62`): bare toggles the persisted
                // mode, `on`/`off` set it, anything else is a one-shot swarm
                // task. The bare toggle resolves against the LIVE tracker
                // (upstream reads `ctx.pager_state.swarm_mode`), so the
                // emitted intent always carries the resolved target state.
                // Same rejoin-vs-trim divergence as `/plan` on the task arm.
                let argument = Self.rejoined(invocation.arguments)
                switch argument {
                case "":
                    let enabled = await swarmModeState?() ?? false
                    try await emit(.overlay(.setSwarmMode(enabled: !enabled)))
                    return .handled
                case "on":
                    try await emit(.overlay(.setSwarmMode(enabled: true)))
                    return .handled
                case "off":
                    try await emit(.overlay(.setSwarmMode(enabled: false)))
                    return .handled
                default:
                    // ORDERING IS LOAD-BEARING (`router.rs:1052-1093`):
                    // upstream replaces the prompt send with one ordered
                    // `SwarmModeThenPrompt` effect so the session observes
                    // swarm mode before it receives the prompt. Here the
                    // guarantee is that `emit` awaits the renderer's
                    // `.swarmTaskMode` handling — which enters the one-shot
                    // task mode on the live tracker — before the returned
                    // `.submit` enqueues the task. Reversed, the task's turn
                    // could start sampling without the swarm reminder, and
                    // the mode toggle would change nothing this turn.
                    try await emit(.overlay(.swarmTaskMode))
                    return .submit(argument)
                }
            case "view-plan":
                // Arguments are ignored — upstream's `ViewPlanCommand::run`
                // declares none and discards what it gets
                // (`view_plan.rs:30-32`).
                try await emit(.overlay(.showPlan))
                return .handled
            case "gboom":
                try await emit(.overlay(.easterEgg))
                return .handled
            case "model":
                // The parser has already split and unquoted the arguments;
                // rejoining on a single space is what upstream resolves against
                // (`model.rs` trims `args` and matches the whole string first,
                // so a multi-word display name like `Grok 4.5` survives).
                let selector = invocation.arguments
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                try await emit(.overlay(.modelPicker(query: selector.isEmpty ? nil : selector)))
                return .handled
            case "timestamps":
                // Arguments are ignored — upstream's `TimestampsCommand::run`
                // declares `_args` and computes the toggle itself from the
                // current cached value (`timestamps.rs:29-31`), so
                // `/timestamps on` is the same toggle, never a setter. The
                // current value lives with the render layer alongside the
                // persist path, so the intent carries no target state.
                try await emit(.overlay(.toggleTimestamps))
                return .handled
            case "timeline":
                // Arguments are ignored — upstream's `TimelineCommand::run`
                // declares `_args` and computes the toggle itself from the
                // cached value (`timeline.rs:31-34`), so `/timeline on` is
                // the same toggle, never a setter. The fullscreen-only gate
                // rides with the toggle handler on the render side, which is
                // the half that knows the session's mode.
                try await emit(.overlay(.toggleTimeline))
                return .handled
            case "minimal", "fullscreen":
                // B2-S2, the screen-mode switch (`screen_mode_switch.rs:73-84`
                // + `mode_support.rs:30-57`) with the AlreadyInMode remedy
                // copy verbatim (`mode_support.rs:55`). The inline ruling,
                // deferred from the B2 research to this slice: upstream
                // treats inline as the fullscreen family (its inline IS the
                // full layout, so `/fullscreen` there refuses), but THIS
                // port's `.inline` is a degraded ≤12-row strip — from it,
                // BOTH switchers are real transitions, so the gate is mode
                // identity, not family. Cost of the divergence: an explicit
                // `--no-alt-screen` user can `/fullscreen` into the alt
                // screen they opted out of — by name, which is upstream's
                // own env-override rationale ("`/fullscreen` always reopens
                // in alt-screen fullscreen … even under a preserved
                // `--no-alt-screen`", screen_mode_relaunch.rs:337-341).
                let wantMinimal = command.name == "minimal"
                if wantMinimal, activePagerMode == .minimal {
                    try await emit(.notice("You're already in minimal mode."))
                    return .handled
                }
                if !wantMinimal, activePagerMode == .fullScreen {
                    try await emit(.notice("You're already in fullscreen mode."))
                    return .handled
                }
                guard let sessionID = activeSessionID ?? lastSessionID ?? launchSessionID else {
                    try await emit(.notice(
                        "No active session to reopen in \(command.name) mode"
                    ))
                    return .handled
                }
                // Record the accepted relaunch for the composition root,
                // then quit the loop — upstream's router stashes the request
                // on the app and pushes `Effect::Quit` (`router.rs:199-209`);
                // the exec happens after the terminal is restored.
                try await emit(.overlay(.relaunchInScreenMode(
                    minimal: wantMinimal, sessionID: sessionID
                )))
                return .quit
            case "expand":
                // `expand.rs:35-46` + the `ModeSupport::MinimalOnly(
                // UseInstead)` refusal (`mode_support.rs:52-56`): outside
                // minimal the fold is a live scrollback affordance, so the
                // remedy names it instead of the mode switch.
                guard activePagerMode == .minimal else {
                    try await emit(.notice(
                        "/expand isn't available in fullscreen mode — press Tab to focus the scrollback, then → on the block."
                    ))
                    return .handled
                }
                guard (activeSessionID ?? lastSessionID ?? launchSessionID) != nil else {
                    try await emit(.notice("No active session"))
                    return .handled
                }
                try await emit(.overlay(.minimalExpandLast))
                return .handled
            case "toggle-mouse-reporting":
                try await emit(.overlay(.toggleMouseReporting))
                return .handled
            case "debug":
                try await emit(.overlay(.debug(argument: Self.rejoined(invocation.arguments))))
                return .handled
            case "login":
                // Bare `/login` opens the provider picker
                // (`login.rs:129-131`); a typed provider resolves through the
                // alias table (`provider_action`, `login.rs:85-101`), whose
                // unknown-provider error echoes the argument as typed.
                let typed = Self.rejoined(invocation.arguments)
                guard !typed.isEmpty else {
                    try await emit(.overlay(.loginProviderPicker))
                    return .handled
                }
                guard let provider = PagerLoginProviders.resolve(typed) else {
                    try await emit(.notice(
                        PagerLoginProviders.unknownProviderMessage(typed)
                    ))
                    return .handled
                }
                switch provider.route {
                case .xai:
                    try await emit(.overlay(.loginXAI))
                case .codex:
                    try await emit(.overlay(.loginCodex))
                case .apiKey(let settingsKey):
                    // Upstream opens a dedicated per-provider key editor
                    // (`Action::Open*ApiKeyEditor`); the port deep-links the
                    // settings modal at the same row — the identical save
                    // path (recorded divergence).
                    try await emit(.overlay(.settings(deepLinkKey: settingsKey)))
                }
                return .handled
            case "logout":
                // `logout.rs:38-45`: bare → xAI, exactly `codex` → Codex
                // (case-sensitive upstream, kept), anything else errors.
                let account = Self.rejoined(invocation.arguments)
                switch account {
                case "":
                    try await emit(.overlay(.logout(account: .xai)))
                case "codex":
                    try await emit(.overlay(.logout(account: .codex)))
                default:
                    try await emit(.notice(
                        PagerLoginProviders.unknownAccountMessage(account)
                    ))
                }
                return .handled
            default:
                try await emit(.notice("unknown command: /\(command.name)"))
                return .handled
            }
        }
    }

    /// Put a parsed argument list back together as the user typed it.
    ///
    /// The parser splits and unquotes; every command whose argument is prose
    /// rather than a token list wants the whole tail back, and rejoining on a
    /// single space is what upstream's `args.trim()` receives.
    private static func rejoined(_ arguments: [String]) -> String {
        arguments.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The raw argument tail after the command token — upstream's
    /// `parse_invocation` slice (`slash/mod.rs:1236-1258`): everything after
    /// the first whitespace run, leading whitespace dropped, interior
    /// whitespace and quotes untouched. `/fork` needs this because its
    /// grammar is position- and whitespace-sensitive; the tokenizer's
    /// `arguments` would unquote and re-space it. Public because host-side
    /// local commands whose argument is prose (`/imagine`) or a raw token
    /// stream (`/announcements`) need the same slice upstream's `run(args)`
    /// receives.
    public static func rawArgumentTail(of invocation: PagerCommandInvocation) -> String {
        let line = invocation.rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let boundary = line.firstIndex(where: \.isWhitespace) else { return "" }
        return String(line[line.index(after: boundary)...].drop(while: \.isWhitespace))
    }

    private func startNewSession() async throws {
        guard let currentRequest else {
            throw OpenGrokPagerInteractiveError.sessionFailed("no active request for new session")
        }
        let sessionID = try await runtime.replaceSession(from: currentRequest)
        lastSessionID = sessionID
        activeSessionID = nil
        editor.reset()
        await promptQueue.removeAll()
        try await emit(.sessionReplaced(sessionID: sessionID))
    }

    /// Commit a `/resume` selection: swap the runtime to the stored session
    /// and tell the renderer to paint its transcript.
    ///
    /// A refused resume is a notice, not a run failure — the current session
    /// is untouched on every error path because the runtime mutates nothing
    /// until its own swap succeeds. The queue is cleared like `/new`: it was
    /// written against the conversation being left behind. (Interjections
    /// need no clear here: the session-side buffer only holds entries while
    /// a turn runs, and both swaps happen from the idle loop.)
    private func resumeStoredSession(sessionID: String) async throws {
        _ = try await activateStoredSession(sessionID: sessionID, clearQueue: true)
    }

    @discardableResult
    private func replaceSession(
        request: OpenGrokPagerRequest,
        workingDirectory: String?,
        clearQueue: Bool
    ) async throws -> Bool {
        let newSessionID: String
        do {
            newSessionID = try await runtime.replaceSession(
                from: request,
                workingDirectory: workingDirectory
            )
        } catch {
            try await emit(.notice("Could not create dashboard session: \(error)"))
            return false
        }
        lastSessionID = newSessionID
        activeSessionID = nil
        editor.reset()
        if clearQueue { await promptQueue.removeAll() }
        try await emit(.sessionReplaced(sessionID: newSessionID))
        return true
    }

    @discardableResult
    private func activateStoredSession(
        sessionID: String,
        clearQueue: Bool
    ) async throws -> Bool {
        let resumedID: String
        do {
            resumedID = try await runtime.resumeSession(sessionID: sessionID)
        } catch {
            try await emit(.notice(
                "Could not resume session \(sessionID): \(String(describing: error))"
            ))
            return false
        }
        lastSessionID = resumedID
        activeSessionID = nil
        editor.reset()
        if clearQueue { await promptQueue.removeAll() }
        try await emit(.sessionResumed(sessionID: resumedID))
        return true
    }

    private func dispatchDashboardPrompt(
        sessionID: String,
        prompt: String,
        request: OpenGrokPagerRequest,
        mailbox: SignalMailbox,
        inputPumpGate: InputPumpGate
    ) async throws -> OpenGrokPagerInteractiveLifecycle? {
        let target = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, !text.isEmpty else {
            try await emit(.notice("dashboard reply cannot be empty"))
            await inputPumpGate.resume()
            return nil
        }
        let current = lastSessionID ?? request.sessionID
        if current != target {
            guard try await activateStoredSession(sessionID: target, clearQueue: true) else {
                await inputPumpGate.resume()
                return nil
            }
        }
        try await enqueue(text)
        return try await drainQueue(
            request: request,
            mailbox: mailbox,
            inputPumpGate: inputPumpGate
        )
    }

    private func dispatchNewDashboardPrompt(
        prompt: String,
        workingDirectory: String?,
        request: OpenGrokPagerRequest,
        mailbox: SignalMailbox,
        inputPumpGate: InputPumpGate
    ) async throws -> OpenGrokPagerInteractiveLifecycle? {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            try await emit(.notice("dashboard dispatch cannot be empty"))
            await inputPumpGate.resume()
            return nil
        }
        guard try await replaceSession(
            request: request,
            workingDirectory: workingDirectory,
            clearQueue: true
        ) else {
            await inputPumpGate.resume()
            return nil
        }
        try await enqueue(text)
        return try await drainQueue(
            request: request,
            mailbox: mailbox,
            inputPumpGate: inputPumpGate
        )
    }

    /// `/copy [N] [file]` — `N` is 1-based and counts back from the newest
    /// response, so a bare `/copy` is `/copy 1`. A single non-numeric argument
    /// is the file, which is what upstream's parse does too.
    static func parseCopyArguments(_ arguments: [String]) -> (index: Int, filePath: String?) {
        var index = 1
        var remaining = arguments[...]
        if let first = remaining.first, let parsed = Int(first), parsed > 0 {
            index = parsed
            remaining = remaining.dropFirst()
        }
        let path = remaining.first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return (index, path?.isEmpty == false ? path : nil)
    }

    /// Service an application chord. Only the commands the port routes
    /// somewhere real are ever bound, so the remaining cases are unreachable
    /// rather than silently ignored.
    private func handleGlobal(
        _ command: OpenGrokPagerGlobalCommand,
        isTurnRunning: Bool = false
    ) async throws {
        switch command {
        case .commandPalette:
            try await emit(.overlay(.commandPalette(rows: paletteRows)))
        case .shortcutsHelp:
            try await emit(.overlay(.shortcutsHelp))
        case .toggleQueue:
            try await emit(.overlay(.promptQueue(entries: await promptQueue.orderedTexts)))
        case .modelPicker:
            try await emit(.overlay(.modelPicker(query: nil)))
        case .openSettings:
            try await emit(.overlay(.settings(deepLinkKey: nil)))
        case .newSession:
            // `requires_confirmation` upstream (`defaults.rs:758`) — throwing
            // away a session on one keystroke is not recoverable.
            guard confirm(key: "Ctrl+n", label: "start a new session") else {
                try await emit(.promptChanged(promptState()))
                return
            }
            if isTurnRunning {
                try await enqueue("/new")
                try await emit(.notice(
                    "/new edits the conversation, so it will run when this turn finishes."
                ))
                return
            }
            try await startNewSession()
        case .cyclePermissionMode, .toggleAlwaysApprove:
            try await emit(.global(command))
        case .toggleTasks, .openDashboard:
            // The render layer owns both surfaces (the B1-t pane state and
            // the dashboard roster/feature gate), so the chords forward the
            // way the permission-mode pair does.
            try await emit(.global(command))
        case .openExtensions:
            // `Ctrl+L` — upstream opens the extensions modal on the Plugins
            // tab (`agent_view/input.rs:1266-1271`).
            try await emit(.overlay(.extensions(tab: .plugins)))
        case .toggleTodos, .sendToBackground, .openSessions:
            // Unbound in `globalAction(for:)` until the backing surface exists.
            break
        }
    }

    /// Body of the `/help` modal. Public so the render layer can lay it out as
    /// a text overlay without duplicating the vocabulary.
    public static let helpText = """
    Commands
      /help                     Browse commands and keyboard shortcuts
      /docs [web|title]         Open How-to Guides or online Build docs
      /model [name]  /m         Switch the active model
      /effort <level>           Set reasoning effort for the current model
      /fast                     Toggle Fast mode (priority routing) for the current model
      /always-approve           Toggle always-approve mode (skip all permission prompts)
      /new    /clear            Start a new session
      /fork [directive]         Branch the current session into a peer agent
      /resume                   Resume a previous session
      /rename <title>  /title   Rename the current session
      /home   /welcome          Return to the welcome screen
      /history                  Search prompt history
      /queue                    Prompts queued behind the running turn
      /tasks                    List background tasks, subagents, and scheduled tasks
      /dashboard  /sessions     Open the Agent Dashboard session roster
      /btw <question>           Ask a side question without interrupting
      /expand                   Re-print the last collapsed block, fully expanded (minimal)
      /context                  View context usage
      /usage  /cost             View session token usage
      /minimal                  Reopen this session in minimal (scrollback-native) mode
      /fullscreen  /full        Reopen this session in fullscreen mode
      /session-info             Show session info
      /mcps                     Show MCP server status
      /doctor [fix [FIX]]       Check this session and show available fixes
      /copy [N] [file]          Copy a response to the clipboard or a file
      /export [file]            Export the conversation
      /transcript  /log         View the transcript in your pager ($PAGER)
      /find [text]              Search the conversation scrollback
      /jump                     Jump to a turn in the conversation
      /rewind [n]  /undo        Rewind to before a previous turn
      /delete                   Delete this session's stored transcript
      /compact [instructions]   Compact conversation history
      /remember [text]          Save a memory note
      /recall <query>           Search workspace memory
      /flush <notes>            Write notes to this session's memory log
      /goal [objective]         Set or inspect the session goal
      /plan [description]       Enter plan mode
      /swarm [on|off|task]      Toggle swarm mode or run a one-shot swarm task
      /view-plan  /show-plan    View the current plan
      /multiline  /ml           Swap what Enter and Shift+Enter do
      /compact-mode             Toggle compact UI (less padding, more content)
      /vim-mode                 Vim keys for the focused scrollback
      /hooks                    View hooks
      /plugins                  View plugins
      /marketplace              View marketplace
      /skills                   View skills
      /settings   /config       Open the settings modal
      /privacy                  Coding data, retention and training settings
      /login [provider]         Connect xAI, OpenAI Codex, or an API-key provider
      /logout [codex]           Log out of xAI or OpenAI Codex
      /theme [name]  /t         Switch the color theme
      /release-notes /changelog View release notes for the current version
      /tutorial                 Quick tips
      /config-agents  /agents   Manage agent definitions
      /personas                 Manage personas (create, edit, delete)
      /workflows                Show workflow runs
      /timestamps               Toggle message timestamps on/off
      /timeline                 Toggle the timeline sidebar
      /toggle-mouse-reporting   Toggle mouse reporting (native copy/paste)
      /quit   /exit             Quit the application

    Composer
      Enter            send (queue while a turn is running)
      Shift+Enter      insert a newline — or a trailing \\ before Enter
      Ctrl+m           toggle multiline (swaps the two above)
      Tab              accept a completion, else focus the scrollback
      Esc              cancel the running turn; press twice to clear a draft
      Ctrl+c           cancel the running turn, or press twice to quit
      Ctrl+d           end input
      Ctrl+p           command palette (moves the dropdown while it is open)
      Ctrl+n           new session (moves the dropdown while it is open)
      Ctrl+.  Ctrl+x   this shortcuts sheet
      Ctrl+;  Ctrl+'   show the prompt queue
      Up / Down        prompt history on an empty composer
      PgUp / PgDn      scroll the transcript
      Home / End       jump to the top or bottom of the transcript
      Ctrl+u           scroll up half a page

    Scrollback (Tab to focus it)
      ↑ / ↓            select the previous or next block
      ← / →            collapse or expand the selected block
      Shift+← / →      previous or next turn
      Enter            open the selected block in the viewer
      Ctrl+e           expand or collapse all thinking
      Ctrl+j / Ctrl+k  scroll a line
      Tab              back to the composer
      With /vim-mode:  j k h l g G e E r y Y o O x d u, i or Space to exit

    Mouse
      Wheel            scroll the transcript, or the open overlay
      Click            choose a row in an overlay
    """

    public static func helpText(
        workflowsEnabled: Bool = true,
        mouseReportingToggleEnabled: Bool = false
    ) -> String {
        var lines = helpText.split(separator: "\n", omittingEmptySubsequences: false)
        if !workflowsEnabled {
            lines = lines.filter {
                !$0.trimmingCharacters(in: .whitespaces).hasPrefix("/workflows")
            }
        }
        if !mouseReportingToggleEnabled {
            lines = lines.filter {
                !$0.trimmingCharacters(in: .whitespaces).hasPrefix("/toggle-mouse-reporting")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func transition(to newLifecycle: OpenGrokPagerInteractiveLifecycle) async throws {
        lifecycle = newLifecycle
        try await emit(.lifecycle(newLifecycle))
        // A lifecycle change is a demand change: `.running` raises fast
        // demand even before the render layer has seen a single event.
        armMotionTickerIfNeeded()
    }

    // MARK: - Motion ticker

    /// The demand right now: the render layer's report, plus what only the
    /// controller knows — that a turn is running (`tick_demand`,
    /// `app_view.rs:6078-6120` folds the same two kinds of source). Ordinary
    /// suspend and the teardown latch both force `.none` without touching
    /// `externalMotionState`, so a successful resume sees the same demand
    /// the render layer last reported.
    private func currentMotionDemand() -> PagerTickDemand {
        guard !motionSuspended, !motionShutdownLatched else { return .none }
        var state = externalMotionState
        state.hasRunningTurn = state.hasRunningTurn || lifecycle == .running
        return state.demand
    }

    /// Arm the ticker when demanded and none is pending — `schedule_tick`
    /// (`event_loop.rs:3172-3189`). Idempotent; called from every place the
    /// demand can rise (run start, lifecycle transitions, `setMotionState`,
    /// `resumeMotionTicker`). Ordinary suspend and the teardown latch both
    /// block arming even when the recorded external state would otherwise
    /// demand frames.
    private func armMotionTickerIfNeeded() {
        guard running,
              !motionSuspended,
              !motionShutdownLatched,
              motionTicker == nil,
              currentMotionDemand() != .none
        else {
            return
        }
        // The unstructured Task inherits the actor's isolation, so the loop
        // body runs on the controller and `Task.sleep` suspends without
        // holding it.
        motionTickerGeneration &+= 1
        let generation = motionTickerGeneration
        motionTicker = Task { await self.runMotionTicker(generation: generation) }
    }

    private func runMotionTicker(generation: UInt64) async {
        defer {
            // Only the generation that still owns the slot may clear it —
            // otherwise a reentrant resume's newer task is erased when this
            // cancelled loop exits.
            if motionTickerGeneration == generation {
                motionTicker = nil
            }
        }
        while !Task.isCancelled, running {
            let demand = currentMotionDemand()
            // Demand fell to none: park. The next `armMotionTickerIfNeeded`
            // re-arms — this loop never spins on an idle screen.
            guard demand != .none else { return }
            // `.slow` is the welcome shimmer's ~12 fps (`SLOW_TICK_INTERVAL`,
            // `app_view.rs:259`); `.fast` is the configured animation fps.
            // A demand change mid-sleep is picked up on the next wake, so a
            // slow→fast rise can lag one slow interval (≤83 ms) — the same
            // bound upstream accepts between `schedule_tick` re-arms.
            let interval = demand == .slow
                ? PagerMotion.slowTickInterval
                : PagerMotion.tickInterval(fps: motionFPS)
            do {
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled, running, currentMotionDemand() != .none else { return }
            do {
                try await renderer.renderAnimationTick(makeAnimationFrame(demand: demand))
            } catch {
                // A renderer that throws on a tick gets no more ticks: a
                // still UI beats a 30 Hz error loop. The cost is deliberate —
                // motion stays off for the rest of the run even if the
                // renderer recovers, because a tick has no channel to report
                // failure without failing the run itself.
                return
            }
        }
    }

    private func makeAnimationFrame(demand: PagerTickDemand) -> OpenGrokPagerAnimationFrame {
        // DispatchTime is the monotonic clock available at this package's
        // macOS 12 floor (ContinuousClock is 13+).
        let nowNanos = DispatchTime.now().uptimeNanoseconds
        let epoch = motionEpochNanos ?? nowNanos
        if motionEpochNanos == nil { motionEpochNanos = epoch }
        let seconds = Double(nowNanos &- epoch) / 1_000_000_000
        let tick = Int(seconds / PagerMotion.tickInterval(fps: motionFPS))
        return OpenGrokPagerAnimationFrame(tick: tick, seconds: seconds, demand: demand)
    }

    // MARK: - Scroll clock

    /// Floor for an overdue scroll deadline (`0`). A bare `Task.yield`
    /// still lets a renderer that keeps returning `0` burn the core; one
    /// millisecond is the cost of not spinning. Matches the spirit of
    /// `MouseScrollState`'s 16 ms redraw cadence without inventing a second
    /// poll loop.
    private static let scrollClockOverdueSleepNanos: UInt64 = 1_000_000

    /// Monotonic uptime seconds for scroll-clock queries. Same clock family
    /// as motion ticks (`DispatchTime`); the renderer maps it onto
    /// `MouseScrollState`'s injected `now`.
    private func scrollClockNow() -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    /// Re-query the renderer's relative scroll deadline, min'd with the
    /// TextArea drag-autoscroll poll, and arm, reschedule, or disarm the
    /// dedicated scroll ticker. Called after every successful `handleInput`
    /// and from `resumeMotionTicker`. Ordinary suspend and the shutdown latch
    /// both block arming; a `nil` deadline cancels any armed ticker without
    /// awaiting (the cancelled generation exits itself).
    private func refreshScrollClockFromRenderer() async {
        guard running, !motionSuspended, !motionShutdownLatched else { return }
        let delay = await combinedScrollClockDelay()
        guard let delay else {
            cancelScrollTicker()
            return
        }
        armScrollTicker(delay: delay)
    }

    private func combinedScrollClockDelay() async -> TimeInterval? {
        let rendererDelay = await renderer.scrollClockDeadline(at: scrollClockNow())
        let composerDelay = editor.pollTimeoutMs().map { TimeInterval($0) / 1_000 }
        switch (rendererDelay, composerDelay) {
        case (let r?, let c?): return min(r, c)
        case (let r?, nil): return r
        case (nil, let c?): return c
        case (nil, nil): return nil
        }
    }

    /// TextArea drag-edge autoscroll. Re-reads the last-painted content rect
    /// so a resize mid-drag cannot keep applying the down-time wrap.
    private func tickComposerDragScroll() async throws {
        guard editor.pollTimeoutMs() != nil else { return }
        let rect = await renderer.lastComposerContentRect() ?? lastComposerContentRect
        guard let rect else { return }
        lastComposerContentRect = rect
        let action = editor.tick(content: rect)
        if action != .nothing {
            try await emit(.promptChanged(promptState()))
        }
        let copied = editor.takeClipboard()
        if action == .selectionFinished, let copied, !copied.isEmpty {
            try await renderer.copyToClipboard(copied)
        }
    }

    /// Cancel the armed scroll ticker without awaiting. Bumps generation so
    /// a racing loop body cannot tick after disarm, and so a later arm is
    /// not erased when the cancelled task's `defer` runs.
    private func cancelScrollTicker() {
        scrollTickerGeneration &+= 1
        scrollTicker?.cancel()
        scrollTicker = nil
    }

    /// Arm (or replace) the dedicated scroll ticker for `delay` relative
    /// seconds. Always bumps generation and cancels any prior task so two
    /// scroll events cannot leave duplicate wakeups. Suspend / shutdown
    /// latch / not-running all no-op.
    private func armScrollTicker(delay: TimeInterval) {
        guard running, !motionSuspended, !motionShutdownLatched else { return }
        scrollTickerGeneration &+= 1
        let generation = scrollTickerGeneration
        scrollTicker?.cancel()
        scrollTicker = Task {
            await self.runScrollTicker(generation: generation, initialDelay: delay)
        }
    }

    private func runScrollTicker(generation: UInt64, initialDelay: TimeInterval) async {
        defer {
            if scrollTickerGeneration == generation {
                scrollTicker = nil
            }
        }
        var delay = initialDelay
        while !Task.isCancelled, running {
            guard !motionSuspended, !motionShutdownLatched else { return }
            guard scrollTickerGeneration == generation else { return }
            let sleepNanos: UInt64
            if delay <= 0 {
                sleepNanos = Self.scrollClockOverdueSleepNanos
            } else {
                let requested = delay * 1_000_000_000
                if requested >= Double(UInt64.max) {
                    sleepNanos = UInt64.max
                } else {
                    sleepNanos = UInt64(requested)
                }
            }
            do {
                try await Task.sleep(nanoseconds: sleepNanos)
            } catch {
                return
            }
            guard !Task.isCancelled, running else { return }
            guard !motionSuspended, !motionShutdownLatched else { return }
            guard scrollTickerGeneration == generation else { return }
            do {
                try await tickComposerDragScroll()
                try await renderer.handleScrollClockTick(at: scrollClockNow())
                guard !Task.isCancelled, running else { return }
                guard !motionSuspended, !motionShutdownLatched else { return }
                guard scrollTickerGeneration == generation else { return }
                guard let next = await combinedScrollClockDelay() else {
                    return
                }
                delay = next
            } catch {
                // Surface like `handleInput` failures — a swallowed tick
                // error would leave scroll state armed with no wakeups, or
                // worse keep the run green after a restore failure inside
                // the renderer's tick path.
                await signalMailbox?.send(
                    .input(.failure(String(describing: error))),
                    priority: true
                )
                return
            }
        }
    }

    private func emit(_ event: OpenGrokPagerInteractiveEvent) async throws {
        if case .overlay = event {
            // Capturing overlay activation must drop a TextArea gesture
            // without synthesizing a copy (`cancelMouseGesture`).
            cancelComposerMouseGesture()
        }
        try await renderer.render(event)
        try await output.forward(event)
        if case .overlay = event {
            await refreshScrollClockFromRenderer()
        }
    }

    private func cancelActiveSession() async {
        guard let activeSession, !activeSessionCancelled else { return }
        activeSessionCancelled = true
        await activeSession.cancel()
    }

    private func closeActiveSession() async {
        guard let activeSession, !activeSessionClosed else { return }
        activeSessionClosed = true
        await activeSession.close()
        self.activeSession = nil
        activeSessionID = nil
    }

    private func isTerminal(_ event: OpenGrokPagerEvent) -> Bool {
        switch event {
        case .completed, .cancelled:
            return true
        case .lifecycle, .output, .status, .tool, .permissionRequested:
            return false
        }
    }

    /// The lowercase character of a Ctrl-chord key, whichever field the
    /// terminal reported it in (the same two-field read the settings chord
    /// dispatcher uses).
    private static func controlCharacter(of key: KeyEvent) -> String? {
        let character: Character?
        switch key.key {
        case .char(let value): character = value
        default: character = key.character
        }
        return character.map { String($0).lowercased() }
    }

    private static func controlAction(for event: InputEvent) -> PromptAction? {
        guard case .key(let key) = event else { return nil }
        if key.key == .escape { return .escape }
        guard key.modifiers.contains(.control) else {
            if key.key == .char("\u{3}") { return .interrupt }
            if key.key == .char("\u{4}") { return .eof }
            return nil
        }
        switch key.key {
        case .char("c"), .char("C"):
            return .interrupt
        case .char("d"), .char("D"):
            return .eof
        default:
            return nil
        }
    }

    private static func makeThrowingStream(
        from stream: AsyncStream<InputEvent>
    ) -> AsyncThrowingStream<InputEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                for await event in stream {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }
}
