// AgentMailboxTests.swift
//
// Coordinator-side mailbox routing: roster scoping, target resolution, FIFO
// delivery, and teardown.
//
// Rust provenance (pin `9ed09e2a`, commit 7957721e):
//   * crates/codegen/xai-grok-tools/src/implementations/grok_build/task/coordinator.rs:536-763
//     — `list_agents`, `resolve_message_target`, `send_agent_message`,
//       `enqueue_agent_message`, `wait_agent_messages`.
//   * .../task/coordinator.rs:369-384 — `TeardownSession` drops the team's
//     mailboxes and closes its waiters as timed out.
//   * .../task/coordinator_tests.rs:1508-1608 —
//     `team_mailbox_lists_pending_child_and_delivers_fifo` and
//     `team_mailbox_rejects_foreign_scope_and_self_send`, which the two
//     routing tests below mirror.

import Foundation
import OpenGrokAgentControlTools
import OpenGrokToolTypes
import Testing

@testable import OpenGrokAgentCoordinator

@Suite("AgentMailbox")
struct AgentMailboxTests {
    private func message(
        _ id: String,
        from identity: AgentMailboxIdentity,
        to target: String,
        body: String,
        kind: AgentMailboxMessageKind = .message
    ) -> AgentMailboxMessage {
        AgentMailboxMessage(
            messageID: id,
            teamScopeID: identity.teamScopeID,
            fromAgentID: identity.agentID,
            toAgentID: target,
            kind: kind,
            body: body,
            createdAtMS: 1
        )
    }

    /// Spawns a child that stays running until the returned handle is
    /// cancelled, so the coordinator keeps it in `active`.
    private func spawnLiveChild(
        _ coordinator: OpenGrokAgentCoordinator,
        id: String,
        parent: String
    ) async throws {
        let request = OpenGrokChildRequest(id: id, parentSessionID: parent, owner: .task)
        try await coordinator.spawn(request) {
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            return OpenGrokChildResult(id: id, success: true)
        }
    }

    @Test("the roster is team-scoped and the mailbox delivers FIFO")
    func rosterAndFifoDelivery() async throws {
        let coordinator = OpenGrokAgentCoordinator()
        try await spawnLiveChild(coordinator, id: "mail-child", parent: "parent")
        try await spawnLiveChild(coordinator, id: "other-team-child", parent: "elsewhere")

        let root = AgentMailboxIdentity(teamScopeID: "parent", agentID: "parent")
        let roster = await coordinator.listAgents(identity: root)
        #expect(roster.teamScopeID == "parent")
        // The WITNESS path too: through the existential, the conformance
        // must resolve to the coordinator's real roster, not the protocol
        // extension's empty no-backend default — the overload trap that
        // silently emptied every direct call when the concrete signature
        // was synchronous.
        let backend: any AgentMailboxBackend = coordinator
        #expect(await backend.listAgents(identity: root).agents.map(\.agentID)
            == ["parent", "mail-child"])
        #expect(roster.agents.first?.isRoot == true)
        #expect(roster.agents.map(\.agentID) == ["parent", "mail-child"])
        #expect(roster.agents.contains { $0.agentID == "mail-child" && $0.status == "running" })

        for (id, body) in [("m1", "first"), ("m2", "second")] {
            let output = try await coordinator.sendAgentMessage(
                identity: root,
                target: "mail-child",
                message: message(id, from: root, to: "mail-child", body: body)
            )
            #expect(output.status == .queued)
            #expect(output.targetAgentID == "mail-child")
        }

        let child = AgentMailboxIdentity(teamScopeID: "parent", agentID: "mail-child")
        let inbox = await coordinator.waitAgentMessages(identity: child, timeoutMS: 0)
        #expect(inbox.timedOut == false)
        #expect(inbox.messages.map(\.body) == ["first", "second"])
        #expect(await coordinator.queuedMessageCount(identity: child) == 0)

        await coordinator.teardown(sessionID: "parent")
        await coordinator.teardown(sessionID: "elsewhere")
    }

    @Test("a foreign team and a self-send are both rejected")
    func foreignScopeAndSelfSendRejected() async throws {
        let coordinator = OpenGrokAgentCoordinator()
        try await spawnLiveChild(coordinator, id: "mail-child", parent: "parent")

        let foreign = AgentMailboxIdentity(
            teamScopeID: "foreign-parent", agentID: "foreign-parent"
        )
        await #expect(throws: AgentMailboxError.self) {
            try await coordinator.sendAgentMessage(
                identity: foreign,
                target: "mail-child",
                message: message("foreign", from: foreign, to: "mail-child", body: "no")
            )
        }

        let root = AgentMailboxIdentity(teamScopeID: "parent", agentID: "parent")
        await #expect(throws: AgentMailboxError.selfSend) {
            try await coordinator.sendAgentMessage(
                identity: root,
                target: "root",
                message: message("self", from: root, to: "root", body: "loop")
            )
        }

        // A message whose stamped identity disagrees with the caller is
        // refused before target resolution (coordinator.rs:643-647).
        await #expect(throws: AgentMailboxError.identityMismatch) {
            try await coordinator.sendAgentMessage(
                identity: root,
                target: "mail-child",
                message: message("spoof", from: foreign, to: "mail-child", body: "no")
            )
        }

        await coordinator.teardown(sessionID: "parent")
    }

    @Test("root is addressable by name and by scope id")
    func rootAliasResolution() async throws {
        let coordinator = OpenGrokAgentCoordinator()
        try await spawnLiveChild(coordinator, id: "mail-child", parent: "parent")
        let child = AgentMailboxIdentity(teamScopeID: "parent", agentID: "mail-child")

        for target in ["root", "ROOT", "parent"] {
            let output = try await coordinator.sendAgentMessage(
                identity: child,
                target: target,
                message: message("m-\(target)", from: child, to: target, body: "up")
            )
            #expect(output.targetAgentID == "parent")
            #expect(output.status == .queued)
        }

        let root = AgentMailboxIdentity(teamScopeID: "parent", agentID: "parent")
        let inbox = await coordinator.waitAgentMessages(identity: root, timeoutMS: 0)
        #expect(inbox.messages.count == 3)

        await coordinator.teardown(sessionID: "parent")
    }

    @Test("a parked wait_agent takes a send directly as delivered")
    func parkedWaiterReceivesDelivery() async throws {
        let coordinator = OpenGrokAgentCoordinator()
        try await spawnLiveChild(coordinator, id: "mail-child", parent: "parent")
        let root = AgentMailboxIdentity(teamScopeID: "parent", agentID: "parent")
        let child = AgentMailboxIdentity(teamScopeID: "parent", agentID: "mail-child")

        let waiting = Task {
            await coordinator.waitAgentMessages(identity: child, timeoutMS: 30_000)
        }
        // Let the waiter park before sending.
        while await coordinator.parkedWaiterCount == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        let output = try await coordinator.sendAgentMessage(
            identity: root,
            target: "mail-child",
            message: message("m1", from: root, to: "mail-child", body: "direct")
        )
        #expect(output.status == .delivered)

        let inbox = await waiting.value
        #expect(inbox.timedOut == false)
        #expect(inbox.messages.map(\.body) == ["direct"])

        await coordinator.teardown(sessionID: "parent")
    }

    @Test("a non-blocking poll of an empty inbox reports timed out")
    func emptyPollIsTimedOut() async {
        let coordinator = OpenGrokAgentCoordinator()
        let root = AgentMailboxIdentity(teamScopeID: "parent", agentID: "parent")
        let inbox = await coordinator.waitAgentMessages(identity: root, timeoutMS: 0)
        #expect(inbox.messages.isEmpty)
        #expect(inbox.timedOut)
    }

    @Test("wait_agent drains at most 20 messages per call")
    func drainCap() async throws {
        let coordinator = OpenGrokAgentCoordinator()
        try await spawnLiveChild(coordinator, id: "mail-child", parent: "parent")
        let root = AgentMailboxIdentity(teamScopeID: "parent", agentID: "parent")
        let child = AgentMailboxIdentity(teamScopeID: "parent", agentID: "mail-child")

        for index in 0..<25 {
            _ = try await coordinator.sendAgentMessage(
                identity: root,
                target: "mail-child",
                message: message("m\(index)", from: root, to: "mail-child", body: "b\(index)")
            )
        }
        let first = await coordinator.waitAgentMessages(identity: child, timeoutMS: 0)
        #expect(first.messages.count == agentMailboxMaxDrainMessages)
        #expect(first.messages.first?.body == "b0")
        let second = await coordinator.waitAgentMessages(identity: child, timeoutMS: 0)
        #expect(second.messages.count == 5)
        #expect(second.messages.first?.body == "b20")

        await coordinator.teardown(sessionID: "parent")
    }

    /// Thread-safe recorder for the delivery hook, which is `@Sendable`.
    private final class DeliveryRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(target: String, body: String)] = []

        func append(target: String, body: String) {
            lock.lock()
            defer { lock.unlock() }
            entries.append((target, body))
        }

        var recorded: [(target: String, body: String)] {
            lock.lock()
            defer { lock.unlock() }
            return entries
        }
    }

    @Test("a follow-up wakes a live recipient through the installed hook; a plain message never does")
    func followupDeliversThroughHook() async throws {
        let coordinator = OpenGrokAgentCoordinator()
        try await spawnLiveChild(coordinator, id: "mail-child", parent: "parent")
        let recorder = DeliveryRecorder()
        await coordinator.installMailboxHooks(deliverFollowup: { target, message in
            recorder.append(target: target, body: message.body)
            return true
        })

        let root = AgentMailboxIdentity(teamScopeID: "parent", agentID: "parent")
        let followup = try await coordinator.sendAgentMessage(
            identity: root,
            target: "mail-child",
            message: message("f1", from: root, to: "mail-child", body: "wake", kind: .followupTask)
        )
        // Rust routes only `wakes_recipient()` kinds through the delivery
        // hook (coordinator.rs:672-687); a successful hand-off is Delivered.
        #expect(followup.status == .delivered)
        #expect(recorder.recorded.map(\.target) == ["mail-child"])
        #expect(recorder.recorded.map(\.body) == ["wake"])
        // Delivered live, so nothing may also sit in the mailbox.
        let child = AgentMailboxIdentity(teamScopeID: "parent", agentID: "mail-child")
        #expect(await coordinator.queuedMessageCount(identity: child) == 0)

        let plain = try await coordinator.sendAgentMessage(
            identity: root,
            target: "mail-child",
            message: message("m1", from: root, to: "mail-child", body: "note", kind: .message)
        )
        #expect(plain.status == .queued)
        #expect(recorder.recorded.count == 1)

        await coordinator.teardown(sessionID: "parent")
    }

    @Test("an undeliverable follow-up to an active child queues instead of erroring")
    func undeliverableFollowupQueues() async throws {
        let coordinator = OpenGrokAgentCoordinator()
        try await spawnLiveChild(coordinator, id: "mail-child", parent: "parent")
        await coordinator.installMailboxHooks(deliverFollowup: { _, _ in false })

        let root = AgentMailboxIdentity(teamScopeID: "parent", agentID: "parent")
        let output = try await coordinator.sendAgentMessage(
            identity: root,
            target: "mail-child",
            message: message("f1", from: root, to: "mail-child", body: "later", kind: .followupTask)
        )
        // Rust queues an undelivered follow-up only for a `pending` child;
        // this coordinator has no pending phase, so root-plus-active is the
        // equivalent set (the recorded divergence in `sendAgentMessage`).
        #expect(output.status == .queued)
        let child = AgentMailboxIdentity(teamScopeID: "parent", agentID: "mail-child")
        #expect(await coordinator.queuedMessageCount(identity: child) == 1)

        await coordinator.teardown(sessionID: "parent")
    }

    @Test("a send to a finished child refuses with the resume hint, byte for byte")
    func finishedTargetCarriesResumeHint() async throws {
        let coordinator = OpenGrokAgentCoordinator()
        let request = OpenGrokChildRequest(id: "done-child", parentSessionID: "parent", owner: .task)
        try await coordinator.spawn(request) {
            OpenGrokChildResult(id: "done-child", success: true, output: "done")
        }
        // The completion hop is asynchronous; wait for the terminal record.
        while await coordinator.listCompleted().first(where: { $0.request.id == "done-child" }) == nil {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        let root = AgentMailboxIdentity(teamScopeID: "parent", agentID: "parent")
        for kind in [AgentMailboxMessageKind.message, .followupTask] {
            do {
                _ = try await coordinator.sendAgentMessage(
                    identity: root,
                    target: "done-child",
                    message: message("m-\(kind.rawValue)", from: root, to: "done-child", body: "more", kind: kind)
                )
                Issue.record("send to a finished child unexpectedly succeeded (\(kind))")
            } catch let error as AgentMailboxError {
                // The same refusal for BOTH kinds pins the reconciliation:
                // `followup_task` does not restart or append to a completed
                // child — upstream points at task(resume_from=…) instead
                // (coordinator.rs:649-660).
                #expect(error == .targetFinished("done-child"))
                #expect(error.description == "Agent 'done-child' has finished. Continue it with "
                    + "task(resume_from=\"done-child\") before sending more work.")
            }
        }

        await coordinator.teardown(sessionID: "parent")
    }

    @Test("session teardown drops the team's mailboxes and closes its waiters")
    func teardownClearsMailboxes() async throws {
        let coordinator = OpenGrokAgentCoordinator()
        try await spawnLiveChild(coordinator, id: "mail-child", parent: "parent")
        let root = AgentMailboxIdentity(teamScopeID: "parent", agentID: "parent")
        let child = AgentMailboxIdentity(teamScopeID: "parent", agentID: "mail-child")

        _ = try await coordinator.sendAgentMessage(
            identity: root,
            target: "mail-child",
            message: message("m1", from: root, to: "mail-child", body: "stale")
        )
        #expect(await coordinator.queuedMessageCount(identity: child) == 1)

        let waiting = Task {
            await coordinator.waitAgentMessages(identity: root, timeoutMS: 30_000)
        }
        while await coordinator.parkedWaiterCount == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        await coordinator.teardown(sessionID: "parent")
        #expect(await coordinator.queuedMessageCount(identity: child) == 0)
        let closed = await waiting.value
        #expect(closed.messages.isEmpty)
        #expect(closed.timedOut)
    }
}
