import Foundation
import Testing
@testable import OpenGrokPagerModel

private func makeState() -> PagerState {
    PagerState(sessionID: "session-1", viewport: PagerViewportState(height: 10, contentHeight: 40))
}

@Suite("Pager reducer prompt lifecycle")
struct PagerPromptLifecycleTests {
    @Test("submit creates a deterministic turn, user item, and start command")
    func submitPrompt() {
        let transition = PagerReducer.reduce(makeState(), .submitPrompt("hello"))
        #expect(!transition.ignored)
        #expect(transition.commands == [.startTurn(turnID: PagerTurnID("turn-1"), prompt: "hello")])
        #expect(transition.state.activeTurnID == PagerTurnID("turn-1"))
        #expect(transition.state.mode == .streaming)
        #expect(transition.state.conversation.count == 1)
        guard case .message(let item) = transition.state.conversation[0] else {
            Issue.record("expected user message")
            return
        }
        #expect(item.role == .user)
        #expect(item.text == "hello")
        #expect(item.turnID == PagerTurnID("turn-1"))
    }

    @Test("blank prompts and duplicate submits while busy are ignored")
    func rejectsInvalidSubmit() {
        let initial = makeState()
        #expect(PagerReducer.reduce(initial, .submitPrompt(" \n ")).ignored)
        let started = PagerReducer.reduce(initial, .submitPrompt("hello"))
        let duplicate = PagerReducer.reduce(started.state, .submitPrompt("again"))
        #expect(duplicate.ignored)
        #expect(duplicate.commands.isEmpty)
        #expect(duplicate.state.conversation.count == 1)
    }

    @Test("turn completion closes streaming messages and returns to prompt editing")
    func completesTurn() {
        var store = PagerStore(state: makeState())
        let start = store.dispatch(.submitPrompt("hello"))
        let turnID = start.state.activeTurnID!
        _ = store.receive(.streamStarted(turnID: turnID, itemID: PagerItemID("assistant-1")))
        _ = store.receive(.streamDelta(turnID: turnID, itemID: PagerItemID("assistant-1"), text: "world"))
        let finish = store.receive(.turnCompleted(turnID, message: "done"))
        #expect(!finish.ignored)
        #expect(store.state.activeTurnID == nil)
        #expect(store.state.mode == .editing)
        #expect(store.state.status.phase == .completed)
        guard case .message(let item) = store.state.item(with: PagerItemID("assistant-1")) else {
            Issue.record("expected assistant item")
            return
        }
        #expect(item.text == "world")
        #expect(!item.isStreaming)
    }
}

@Suite("Pager streaming and stale events")
struct PagerStreamingTests {
    @Test("stream deltas append in order and duplicate start is idempotent")
    func streamingUpdates() {
        var store = PagerStore(state: makeState())
        let turnID = store.dispatch(.submitPrompt("write")).state.activeTurnID!
        let itemID = PagerItemID("assistant-1")
        #expect(!store.receive(.streamStarted(turnID: turnID, itemID: itemID)).ignored)
        #expect(store.receive(.streamStarted(turnID: turnID, itemID: itemID)).ignored)
        _ = store.receive(.streamDelta(turnID: turnID, itemID: itemID, text: "one"))
        _ = store.receive(.streamDelta(turnID: turnID, itemID: itemID, text: " two"))
        guard case .message(let item) = store.state.item(with: itemID) else {
            Issue.record("expected assistant stream")
            return
        }
        #expect(item.text == "one two")
        #expect(item.isStreaming)
    }

    @Test("events from another turn and events after cancellation cannot mutate state")
    func staleEventsAreIgnored() {
        var store = PagerStore(state: makeState())
        let turnID = store.dispatch(.submitPrompt("write")).state.activeTurnID!
        let wrongTurn = PagerTurnID("old-turn")
        let itemID = PagerItemID("assistant-1")
        #expect(store.receive(.streamDelta(turnID: wrongTurn, itemID: itemID, text: "stale")).ignored)
        _ = store.dispatch(.cancel(reason: "user"))
        #expect(store.receive(.streamDelta(turnID: turnID, itemID: itemID, text: "late")).ignored)
        _ = store.receive(.turnCancelled(turnID, reason: "user"))
        #expect(store.receive(.turnCompleted(turnID, message: nil)).ignored)
        #expect(store.state.conversation.isEmpty == false)
        #expect(store.state.status.phase == .cancelled)
    }
}

@Suite("Pager focus, mode, and viewport")
struct PagerFocusAndViewportTests {
    @Test("focus and mode transitions enforce valid boundaries")
    func focusAndMode() {
        var store = PagerStore(state: makeState())
        #expect(store.dispatch(.setMode(.searching)).ignored)
        #expect(!store.dispatch(.focus(.scrollback)).ignored)
        #expect(!store.dispatch(.setMode(.searching)).ignored)
        #expect(!store.dispatch(.setSearchQuery("tool")).ignored)
        #expect(store.state.searchQuery == "tool")
        #expect(store.dispatch(.setMode(.streaming)).ignored)
        #expect(!store.dispatch(.focus(.prompt)).ignored)
        #expect(store.state.mode == .idle)
        store.dispatch(.updateDraft("next"))
        #expect(store.state.mode == .editing)
    }

    @Test("viewport clamps, pages, and follows new output only at bottom")
    func viewport() {
        var store = PagerStore(state: makeState())
        #expect(store.state.viewport.offset == 30)
        _ = store.dispatch(.scroll(.up(5)))
        #expect(store.state.viewport.offset == 25)
        #expect(!store.state.viewport.followsOutput)
        _ = store.dispatch(.setViewport(height: 10, contentHeight: 80))
        #expect(store.state.viewport.offset == 25)
        _ = store.dispatch(.scroll(.bottom))
        #expect(store.state.viewport.offset == 70)
        #expect(store.state.viewport.followsOutput)
        _ = store.dispatch(.setViewport(height: 20, contentHeight: 100))
        #expect(store.state.viewport.offset == 80)
    }
}

@Suite("Pager tools and permissions")
struct PagerToolsAndPermissionsTests {
    @Test("tool cards upsert and retain live output")
    func toolCards() {
        var store = PagerStore(state: makeState())
        let turnID = store.dispatch(.submitPrompt("inspect")).state.activeTurnID!
        let tool = PagerToolCard(
            id: PagerItemID("tool-1"),
            turnID: turnID,
            toolCallID: "call-1",
            name: "read_file",
            status: .running
        )
        _ = store.receive(.toolStarted(tool))
        _ = store.receive(.toolUpdated(
            turnID: turnID,
            itemID: tool.id,
            status: .completed,
            input: nil,
            output: "contents"
        ))
        guard case .tool(let card) = store.state.item(with: tool.id) else {
            Issue.record("expected tool card")
            return
        }
        #expect(card.status == .completed)
        #expect(card.output == "contents")
        let wasExpanded = card.isExpanded
        _ = store.dispatch(.toggleTool(tool.id))
        guard case .tool(let updated) = store.state.item(with: tool.id) else {
            Issue.record("expected updated tool card")
            return
        }
        #expect(updated.isExpanded != wasExpanded)
    }

    @Test("permission request changes focus and resolution emits a command")
    func permissionCard() {
        var store = PagerStore(state: makeState())
        let turnID = store.dispatch(.submitPrompt("edit")).state.activeTurnID!
        let card = PagerPermissionCard(
            id: PagerItemID("permission-1"),
            turnID: turnID,
            requestID: "request-1",
            toolCallID: "call-1",
            title: "Allow edit?",
            options: [
                PagerPermissionOption(id: "allow", label: "Allow"),
                PagerPermissionOption(id: "deny", label: "Deny", isDestructive: true)
            ]
        )
        _ = store.receive(.permissionRequested(card))
        #expect(store.state.mode == .awaitingPermission)
        #expect(store.state.focus == .permission("request-1"))
        let resolution = store.dispatch(.resolvePermission(requestID: "request-1", optionID: "allow"))
        #expect(resolution.commands == [.resolvePermission(requestID: "request-1", optionID: "allow")])
        #expect(store.state.pendingPermissionCards.isEmpty)
        #expect(store.state.mode == .streaming)
        guard case .permission(let resolved) = store.state.item(with: card.id) else {
            Issue.record("expected resolved permission")
            return
        }
        #expect(resolved.resolution == .allowed)
        #expect(resolved.selectedOptionID == "allow")
    }

    @Test("cancellation resolves pending permissions and remains observable")
    func cancellationFacingState() {
        var store = PagerStore(state: makeState())
        let turnID = store.dispatch(.submitPrompt("edit")).state.activeTurnID!
        let card = PagerPermissionCard(
            id: PagerItemID("permission-1"),
            turnID: turnID,
            requestID: "request-1",
            toolCallID: "call-1",
            title: "Allow edit?",
            options: [PagerPermissionOption(id: "allow", label: "Allow")]
        )
        _ = store.receive(.permissionRequested(card))
        let cancel = store.dispatch(.cancel(reason: "escape"))
        #expect(cancel.commands == [.cancelTurn(turnID: turnID)])
        #expect(store.state.mode == .cancelling)
        #expect(store.state.cancellation?.phase == .requested)
        #expect(store.state.pendingPermissionCards.isEmpty)
        _ = store.receive(.turnCancelled(turnID, reason: "escape"))
        #expect(store.state.cancellation?.phase == .acknowledged)
        #expect(store.state.activeTurnID == nil)
        #expect(store.state.status.phase == .cancelled)
    }
}

@Suite("Pager error state")
struct PagerErrorTests {
    @Test("terminal errors are retained and dismissible")
    func terminalError() {
        var store = PagerStore(state: makeState())
        let turnID = store.dispatch(.submitPrompt("fail")).state.activeTurnID!
        let error = PagerErrorState(code: .provider, message: "provider unavailable", turnID: turnID)
        _ = store.receive(.error(error, terminal: true))
        #expect(store.state.activeTurnID == nil)
        #expect(store.state.mode == .failed)
        #expect(store.state.error == error)
        _ = store.dispatch(.dismissError)
        #expect(store.state.error == nil)
        #expect(store.state.mode == .editing)
    }

    @Test("non-terminal errors do not end the active turn")
    func recoverableError() {
        var store = PagerStore(state: makeState())
        let turnID = store.dispatch(.submitPrompt("retry")).state.activeTurnID!
        let error = PagerErrorState(code: .transport, message: "retrying", turnID: turnID)
        _ = store.receive(.error(error, terminal: false))
        #expect(store.state.activeTurnID == turnID)
        #expect(store.state.mode == .streaming)
        #expect(store.state.error == error)
    }
}
