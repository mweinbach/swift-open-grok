// LiveSchedulerFireTests.swift
//
// The in-session fire path END TO END through the LIVE seams (AGENTS.md §3):
// the real `makeSessionFoundation` (interactive surface on, so the executor
// carries the real scheduler host) → `scheduler_create` through real tool
// dispatch → the host's deterministic fire trigger → the interactive
// controller's Cron queue entry → a REAL turn through `LivePagerRuntimeAdapter`
// and the real `OpenGrokShell` turn loop — with the evidence read off the
// sampler REQUEST (the items the model is actually offered) and the persisted
// session record on disk.
//
// Determinism: the task is created with `fire_immediately: true` (due at
// creation) and the fire is triggered by installing the sink — the host's
// wiring-grace delivery — so NO test here waits a scheduler interval on the
// wall clock.
//
// Fixture pattern follows `LiveInterjectionTests.swift` (canned sampler over
// the real stack, hermetic home, bounded polls).

import Foundation
import Testing
import OpenGrokPager
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase
import OpenGrokTerminalCore
import OpenGrokTestSupport
@testable import OpenGrokCLI

// MARK: - Fixture

private struct SchedulerFireFixture {
    let home: URL
    let workspace: URL
    let server: MockInferenceServer
    let environment: [String: String]

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-schedfire-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        server = try MockInferenceServer()
        try """
        [endpoints]
        xai_api_base_url = "\(server.url)"
        """.write(
            to: home.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
        environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "XDG_STATE_HOME": home.appendingPathComponent("state").path,
            "XAI_API_KEY": "test-xai-key",
        ]
    }

    func dispose() {
        server.stop()
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    func launchOptions() throws -> CLIExecutionOptions {
        let command = try CLICommandParser.parseOrThrow(
            ["headless", "--prompt", "hello", "--cwd", workspace.path, "--model", "grok-4.5"]
        )
        guard case .launch(let options) = command else {
            throw CLIApplicationError.failed("fixture did not parse to a launch")
        }
        return options
    }

    func context() -> CLIApplicationContext {
        CLIApplicationContext(
            environment: environment,
            streams: CLIStreams(out: { _ in }, err: { _ in }),
            control: .never
        )
    }
}

/// Records every agent-turn request; answers "done" with no tool calls.
private actor FireSamplerStore {
    private(set) var agentRequests: [OpenGrokLiveSamplingRequest] = []

    func next(_ request: OpenGrokLiveSamplingRequest) -> OpenGrokLiveSamplingResponse {
        if request.tools.isEmpty || request.turnID.hasPrefix("compaction-") {
            return OpenGrokLiveSamplingResponse(output: "compacted summary")
        }
        agentRequests.append(request)
        return OpenGrokLiveSamplingResponse(output: "done")
    }
}

private func waitUntil(
    seconds: Double = 15,
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await condition()
}

private actor FireSilentRenderer: OpenGrokPagerInteractiveRenderAdapter {
    func begin() {}
    func restoreTerminal() {}
    func render(_ event: OpenGrokPagerInteractiveEvent) { _ = event }
}

private struct FireSilentOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws { _ = event }
}

/// Whether `item` is the persisted scheduler-fired user item carrying `text`.
private func isSchedulerFiredItem(_ item: ConversationItem, text: String) -> Bool {
    guard case .user(let user) = item else { return false }
    return user.syntheticReason == .schedulerFired
        && user.content == [.text(text: text)]
}

// MARK: - The fire, end to end

@Suite("scheduler fire: Cron enqueue → drain → real turn → persistence", .serialized)
struct LiveSchedulerFireTests {
    @Test("a deterministic fire runs a real turn carrying the framed prompt and persists it")
    func fireDrainsIntoRealTurnAndPersists() async throws {
        let fixture = try SchedulerFireFixture()
        defer { fixture.dispose() }
        let store = FireSamplerStore()
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in OpenGrokLiveSampler { request, _ in await store.next(request) } }
        )
        // Interactive surface ON: this is the composition shape whose
        // executor carries the REAL scheduler host — the same one the
        // scheduler_* tools mutate and the fire sink drains.
        let foundation = try await OpenGrokLiveApplicationLauncher.makeSessionFoundation(
            options: fixture.launchOptions(),
            context: fixture.context(),
            dependencies: dependencies,
            interactiveSurfaceAvailable: true
        )
        let stack = await OpenGrokLiveApplicationLauncher.makeAgentStack(
            foundation: foundation,
            context: fixture.context(),
            dependencies: dependencies
        )
        let schedulerHost = try #require(
            foundation.toolExecutor.schedulerHost,
            "an interactive foundation must construct the scheduler host"
        )

        // 1. `scheduler_create` through REAL dispatch, `fire_immediately`
        //    so the task is due at creation — no wall-clock interval.
        let created = await foundation.toolExecutor.invoke(
            sessionID: foundation.sessionID,
            workingDirectory: foundation.cwd,
            call: ToolCall(
                id: "sched-e2e",
                name: "scheduler_create",
                arguments: #"{"interval":"5m","prompt":"check deploy status","fire_immediately":true}"#
            )
        )
        guard case .success = created else {
            Issue.record("scheduler_create failed through live dispatch: \(created)")
            return
        }
        let taskID = try #require(await schedulerHost.list().first).id

        // 2. The interactive controller over the REAL runtime adapter — the
        //    exact pair the interactive composition wires.
        let runtime = LivePagerRuntimeAdapter(
            shell: stack.shell,
            cwd: foundation.cwd,
            providerConfiguration: foundation.providerConfiguration,
            conversationHistory: stack.conversationHistory,
            conversationStore: foundation.conversationStore,
            toolExecutor: foundation.toolExecutor,
            compaction: stack.compaction,
            modelSwitch: stack.modelSwitch
        )
        let controller = OpenGrokPagerInteractiveController(
            input: AsyncStream<InputEvent> { _ in },
            runtime: runtime,
            renderer: FireSilentRenderer(),
            output: FireSilentOutput()
        )
        let runTask = Task { try await controller.run(.init(prompt: "", mode: .inline)) }
        #expect(await waitUntil { await controller.state().lifecycle == .editing })

        // 3. Installing the sink delivers the due fire (the wiring-grace
        //    path) — the deterministic trigger, no timer sleep involved.
        await schedulerHost.setFireSink { [weak controller] fire in
            guard let controller else { return }
            switch await controller.enqueueCronPrompt(
                prompt: fire.prompt,
                taskID: fire.taskID,
                humanSchedule: fire.humanSchedule
            ) {
            case .enqueued, .skippedTaskAlreadyQueued, .skippedTaskAlreadyRunning:
                break
            }
        }

        // 4. The fire drains into a REAL turn. Wire evidence: the sampler
        //    request's last user item is the schedulerFired synthetic item
        //    carrying the FRAMED prompt (reminders.rs:49-61) — the model
        //    sees the framing, and the persistence tag rides the
        //    `scheduler-fired-` prompt id.
        #expect(await waitUntil { await store.agentRequests.count >= 1 })
        let framed = formatScheduledTaskPrompt(
            "check deploy status",
            taskID: taskID,
            humanSchedule: "every 5 minutes"
        )
        let request = try #require(await store.agentRequests.first)
        #expect(
            isSchedulerFiredItem(try #require(request.items.last), text: framed),
            "the turn's user item must be the framed schedulerFired item, got \(request.items)"
        )

        // 5. Persistence: the fired prompt lands in the committed session
        //    record like any user item — in memory and on disk.
        #expect(await waitUntil {
            await stack.conversationHistory.items.contains {
                isSchedulerFiredItem($0, text: framed)
            }
        })
        let reloaded = try await LiveConversationStore(openGrokHome: fixture.home)
            .loadIfPresent(sessionID: foundation.sessionID)
        #expect(
            reloaded?.items.contains { isSchedulerFiredItem($0, text: framed) } == true,
            "the fired prompt must persist to the session record"
        )

        await controller.shutdown()
        _ = try? await runTask.value
        await foundation.toolExecutor.shutdown()
    }
}
