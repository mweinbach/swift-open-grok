import Foundation
import OpenGrokACP
import OpenGrokACPRuntime
import OpenGrokAgentCoordinator
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase
import Testing

@testable import OpenGrokCLI

private actor ACPTaskControlSampler {
    private let blocksChildren: Bool
    private var requestSessionIDs: [String] = []

    init(blocksChildren: Bool) {
        self.blocksChildren = blocksChildren
    }

    func sample(_ request: OpenGrokLiveSamplingRequest) async -> OpenGrokLiveSamplingResponse {
        requestSessionIDs.append(request.sessionID)
        if blocksChildren {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
        }
        return OpenGrokLiveSamplingResponse(output: "raw child answer")
    }

    var requests: [String] {
        requestSessionIDs
    }
}

private final class ACPTaskControlSessionIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String]

    init(_ values: [String]) {
        self.values = values
    }

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        return values.isEmpty ? "unexpected-wire-session" : values.removeFirst()
    }
}

private struct ACPTaskControlFixture: Sendable {
    let root: URL
    let home: URL
    let workspace: URL
    let environment: [String: String]
    let foundation: OpenGrokLiveApplicationLauncher.LiveSessionFoundation
    let persistence: LiveSchedulerPersistence
    let scheduler: LiveSchedulerHost
    let gateway: ACPNotificationGateway
    let handler: LiveACPTaskControlHandler
    let runtime: ACPAgentRuntime
    let wireSessionID: String
    let leaderOwner: String?
    let sampler: ACPTaskControlSampler

    static func start(
        blocksChildren: Bool = false,
        leaderOwned: Bool = false
    ) async throws -> ACPTaskControlFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-acp-task-control-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let rootSessionID = "root-\(UUID().uuidString)"
        let wireSessionID = "wire-\(UUID().uuidString)"
        let leaderOwner = leaderOwned ? "owner-driver" : nil
        let environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "XDG_STATE_HOME": home.appendingPathComponent("state").path,
            "XAI_API_KEY": "acp-control-test-key",
            // The test runner is shared across suites; never apply a real
            // irreversible process sandbox to it while constructing roots.
            "GROK_SANDBOX": "off",
        ]
        let parsed = try CLICommandParser.parseOrThrow([
            "acp",
            "--cwd", workspace.path,
            "--session-id", rootSessionID,
            "--model", "grok-4.5",
            "--always-approve",
        ])
        guard case .launch(let options) = parsed else {
            throw CLIApplicationError.failed("ACP task-control fixture did not parse its launch")
        }

        let sampler = ACPTaskControlSampler(blocksChildren: blocksChildren)
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { request, _ in
                    await sampler.sample(request)
                }
            }
        )
        let foundation = try await OpenGrokLiveApplicationLauncher.makeSessionFoundation(
            options: options,
            context: CLIApplicationContext(
                environment: environment,
                streams: CLIStreams(out: { _ in }, err: { _ in }),
                control: .never
            ),
            dependencies: dependencies
        )
        let sessionDirectory = home
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(rootSessionID, isDirectory: true)
        guard let persistence = LiveSchedulerPersistence.forSessionDirectory(sessionDirectory) else {
            await foundation.toolExecutor.shutdown()
            throw CLIApplicationError.failed("ACP fixture could not create scheduler persistence")
        }
        let scheduler = LiveSchedulerHost(persistence: persistence)
        let gateway = ACPNotificationGateway()
        let handler = LiveACPTaskControlHandler(
            gateway: gateway,
            ownerRootSessionID: rootSessionID,
            workingDirectory: workspace,
            toolExecutor: foundation.toolExecutor,
            schedulerHost: scheduler
        )
        var router = ACPExtensionMethodRouter()
        for method in LiveACPTaskControlHandler.methods {
            router = router.register(exact: method, handler: handler)
        }

        let runtime = ACPAgentRuntime(
            extensionRouter: router,
            onSessionOpened: { sessionID, _ in
                await handler.opened(sessionID)
            },
            onSessionClosed: { sessionID in
                await handler.closed(sessionID)
            },
            makeSessionId: { wireSessionID }
        )
        await gateway.attach(runtime)
        await runtime.setReverseSender { _ in }
        if leaderOwned {
            await runtime.setSessionOwnerVerifier { sessionID, clientID in
                sessionID.rawValue == wireSessionID && clientID == "owner-driver"
            }
        }

        let initialized = try await ACPLeaderRequestAuthority.$clientID.withValue(leaderOwner) {
            await runtime.handle(.request(
                id: .string("initialize-task-control"),
                method: AgentMethodNames.initialize,
                params: try JSONValue.encode(InitializeRequest(protocolVersion: .v1))
            ))
        }
        guard case .response(_, _?, nil)? = initialized.last else {
            await runtime.close()
            await scheduler.shutdown()
            await foundation.toolExecutor.shutdown()
            throw CLIApplicationError.failed("ACP task-control fixture could not initialize")
        }

        let opened = await ACPLeaderRequestAuthority.$clientID.withValue(leaderOwner) {
            await runtime.handle(.request(
                id: .string("open-task-control"),
                method: AgentMethodNames.sessionNew,
                params: .object([
                    "cwd": .string(workspace.path),
                    "mcpServers": .array([]),
                ])
            ))
        }
        guard case .response(_, let payload?, nil)? = opened.last,
              payload["sessionId"]?.stringValue == wireSessionID
        else {
            await runtime.close()
            await scheduler.shutdown()
            await foundation.toolExecutor.shutdown()
            throw CLIApplicationError.failed("ACP task-control fixture could not open its wire session")
        }

        return ACPTaskControlFixture(
            root: root,
            home: home,
            workspace: workspace,
            environment: environment,
            foundation: foundation,
            persistence: persistence,
            scheduler: scheduler,
            gateway: gateway,
            handler: handler,
            runtime: runtime,
            wireSessionID: wireSessionID,
            leaderOwner: leaderOwner,
            sampler: sampler
        )
    }

    func call(
        _ method: String,
        params: JSONValue,
        clientID: String? = nil
    ) async -> (value: JSONValue?, error: AcpError?) {
        let effectiveClientID = clientID ?? leaderOwner
        let responses = await ACPLeaderRequestAuthority.$clientID.withValue(effectiveClientID) {
            await runtime.handle(.request(
                id: .string(UUID().uuidString),
                method: method,
                params: params
            ))
        }
        guard case .response(_, let value, let error)? = responses.last else {
            return (nil, AcpError.internalError("ACP task-control fixture received no response"))
        }
        return (value, error)
    }

    func startRealBackgroundTask(
        executor: LiveToolExecutor? = nil,
        rootSessionID: String? = nil
    ) async throws -> String {
        #if os(Windows)
        let command = "Start-Sleep -Seconds 30"
        #else
        let command = "sleep 30"
        #endif
        let actualExecutor = executor ?? foundation.toolExecutor
        let actualRootID = rootSessionID ?? foundation.sessionID
        let result = await actualExecutor.invoke(
            sessionID: actualRootID,
            workingDirectory: workspace,
            call: ToolCall(
                id: "spawn-process-\(UUID().uuidString)",
                name: "run_terminal_cmd",
                arguments: #"{"command":"\#(command)","is_background":true,"description":"ACP-owned process"}"#
            )
        )
        guard case .success(let value) = result,
              let taskID = value.value["task_id"]?.stringValue
        else {
            throw CLIApplicationError.failed("could not start a real ACP-owned process: \(result)")
        }
        return taskID
    }

    func spawnRealChild() async throws -> String {
        let result = await foundation.toolExecutor.invoke(
            sessionID: foundation.sessionID,
            workingDirectory: workspace,
            call: ToolCall(
                id: "spawn-child-\(UUID().uuidString)",
                name: "spawn_subagent",
                arguments: #"{"prompt":"ACP task control child","description":"ACP child","subagent_type":"general-purpose","background":true}"#
            )
        )
        guard case .success(let value) = result,
              let childID = value.value["subagent_id"]?.stringValue
        else {
            throw CLIApplicationError.failed("could not spawn a real ACP-owned subagent: \(result)")
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if await sampler.requests.contains(childID) {
                return childID
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw CLIApplicationError.failed("ACP-owned child never reached its real sampler")
    }

    func shutdown() async {
        await runtime.close()
        await scheduler.shutdown()
        await foundation.toolExecutor.shutdown()
        try? FileManager.default.removeItem(at: root)
    }
}

private func withACPTaskControlFixture<T>(
    blocksChildren: Bool = false,
    leaderOwned: Bool = false,
    _ operation: (ACPTaskControlFixture) async throws -> T
) async throws -> T {
    let fixture = try await ACPTaskControlFixture.start(
        blocksChildren: blocksChildren,
        leaderOwned: leaderOwned
    )
    do {
        let value = try await operation(fixture)
        await fixture.shutdown()
        return value
    } catch {
        await fixture.shutdown()
        throw error
    }
}

@Suite("ACP task, subagent, and scheduler control parity", .serialized)
struct LiveACPTaskControlParityTests {
    @Test("a real owner-scoped process is listed with Rust wire fields and actually killed")
    func realBackgroundProcessListAndKill() async throws {
        try await withACPTaskControlFixture { fixture in
            #expect(fixture.wireSessionID != fixture.foundation.sessionID)
            let taskID = try await fixture.startRealBackgroundTask()

            let listed = await fixture.call(
                "x.ai/task/list",
                params: .object(["sessionId": .string(fixture.wireSessionID)])
            )
            #expect(listed.error == nil)
            let task = try #require(listed.value?["result"]?["tasks"]?[0])
            #expect(task["task_id"]?.stringValue == taskID)
            #expect(task["taskId"] == nil)
            #expect(task["owner_session_id"]?.stringValue == fixture.foundation.sessionID)
            #expect(task["start_time"]?["secs_since_epoch"]?.uint64Value != nil)
            #expect(task["start_time"]?["nanos_since_epoch"]?.uint64Value != nil)
            #expect(task["completed"]?.boolValue == false)
            #expect(task["kind"]?.stringValue == "bash")

            let killed = await fixture.call(
                "x.ai/task/kill",
                params: .object([
                    "sessionId": .string(fixture.wireSessionID),
                    "taskId": .string(taskID),
                ])
            )
            #expect(killed.error == nil)
            #expect(killed.value == .object([
                "result": .object([
                    "taskId": .string(taskID),
                    "outcome": .string("killed"),
                ]),
            ]))

            let process = try #require(await fixture.foundation.toolExecutor.processExecution(
                sessionID: fixture.foundation.sessionID,
                workingDirectory: fixture.workspace
            ))
            let observed = await process.taskSnapshot(taskID)
            #expect(observed?.completed == true)

            let repeated = await fixture.call(
                "x.ai/task/kill",
                params: .object([
                    "sessionId": .string(fixture.wireSessionID),
                    "taskId": .string(taskID),
                    "source": .string("teardown"),
                ])
            )
            #expect(repeated.value?["result"]?["outcome"]?.stringValue == "already_exited")

            let unknown = await fixture.call(
                "x.ai/task/kill",
                params: .object([
                    "sessionId": .string(fixture.wireSessionID),
                    "taskId": .string("never-created"),
                ])
            )
            #expect(unknown.value?["result"]?["outcome"]?.stringValue == "not_found")
        }
    }

    @Test("one shared shell backend never reveals or kills another root's background process")
    func sharedBackendRemainsRootOwnerScoped() async throws {
        try await withACPTaskControlFixture { fixture in
            let foreignRootID = "foreign-\(UUID().uuidString)"
            let foreign = try await LiveToolExecutor(
                processBackend: fixture.foundation.processBackend,
                sessionID: foreignRootID,
                workingDirectory: fixture.workspace,
                toolPolicy: nil,
                telemetryBootstrapContext: .empty,
                fileAccessPolicy: .allowAll,
                environment: fixture.environment,
                permissionOptions: CLIPermissionOptions(alwaysApprove: true)
            )
            do {
                let foreignTaskID = try await fixture.startRealBackgroundTask(
                    executor: foreign,
                    rootSessionID: foreignRootID
                )
                let listed = await fixture.call(
                    "x.ai/task/list",
                    params: .object(["sessionId": .string(fixture.wireSessionID)])
                )
                let rows = listed.value?["result"]?["tasks"]?.arrayValue ?? []
                #expect(!rows.contains { $0["task_id"]?.stringValue == foreignTaskID })

                let refused = await fixture.call(
                    "x.ai/task/kill",
                    params: .object([
                        "sessionId": .string(fixture.wireSessionID),
                        "taskId": .string(foreignTaskID),
                    ])
                )
                #expect(refused.value?["result"]?["outcome"]?.stringValue == "not_found")
                let foreignProcess = try #require(await foreign.processExecution(
                    sessionID: foreignRootID,
                    workingDirectory: fixture.workspace
                ))
                let alive = await foreignProcess.taskSnapshot(foreignTaskID)
                #expect(alive?.completed == false)
                await foreign.shutdown()
            } catch {
                await foreign.shutdown()
                throw error
            }
        }
    }

    @Test("the real spawned child supports running/get/timeout/cancel through authenticated ACP")
    func realSubagentControlAndBoundedWait() async throws {
        try await withACPTaskControlFixture(blocksChildren: true) { fixture in
            let childID = try await fixture.spawnRealChild()

            let running = await fixture.call(
                "x.ai/subagent/list_running",
                params: .object(["sessionId": .string(fixture.wireSessionID)])
            )
            let live = try #require(running.value?["result"]?["subagents"]?[0])
            #expect(live["subagentId"]?.stringValue == childID)
            #expect(live["parentSessionId"]?.stringValue == fixture.foundation.sessionID)
            #expect(live["childSessionId"]?.stringValue == childID)
            #expect(live["turnCount"]?.uint64Value != nil)

            let immediate = await fixture.call(
                "x.ai/subagent/get",
                params: .object([
                    "subagentId": .string(childID),
                    "block": .bool(true),
                    "timeoutMs": .number(.uint64(0)),
                ])
            )
            #expect(immediate.value?["result"]?["snapshot"]?["status"]?.stringValue == "running")

            let started = Date()
            let timed = await fixture.call(
                "x.ai/subagent/get",
                params: .object([
                    "subagentId": .string(childID),
                    "block": .bool(true),
                    "timeoutMs": .number(.uint64(25)),
                ])
            )
            #expect(Date().timeIntervalSince(started) < 2)
            #expect(timed.value?["result"]?["snapshot"]?["status"]?.stringValue == "running")
            let host = try #require(fixture.foundation.subagentHost)
            let remainsActive = await host.coordinator.listActive(
                parentSessionID: fixture.foundation.sessionID
            ).contains { $0.request.id == childID }
            #expect(remainsActive)
            #expect(LiveACPTaskControlHandler.maximumSubagentWaitMilliseconds == 30_000)

            let cancelled = await fixture.call(
                "x.ai/subagent/cancel",
                params: .object(["subagentId": .string(childID)])
            )
            #expect(cancelled.value == .object([
                "result": .object([
                    "subagentId": .string(childID),
                    "cancelled": .bool(true),
                    "outcome": .object(["kind": .string("cancelled")]),
                ]),
            ]))

            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                let completed = await host.coordinator.listCompleted().contains {
                    $0.request.id == childID
                }
                if completed { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }

            let repeated = await fixture.call(
                "x.ai/subagent/cancel",
                params: .object(["subagentId": .string(childID)])
            )
            #expect(repeated.value?["result"]?["cancelled"]?.boolValue == false)
            #expect(repeated.value?["result"]?["outcome"]?["kind"]?.stringValue == "already_finished")
        }
    }

    @Test("completed child inspection returns raw output, not the model tool's decorated footer")
    func completedSubagentReturnsRawResult() async throws {
        try await withACPTaskControlFixture { fixture in
            let host = try #require(fixture.foundation.subagentHost)
            let childID = "completed-\(UUID().uuidString)"
            let request = OpenGrokChildRequest(
                id: childID,
                parentSessionID: fixture.foundation.sessionID,
                subagentType: "general-purpose",
                description: "completed ACP child",
                owner: .task
            )
            let spawned = try await host.coordinator.spawn(request) {
                OpenGrokChildResult(
                    id: childID,
                    success: true,
                    output: "raw child answer"
                )
            }
            #expect(spawned == childID)
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if await host.coordinator.listCompleted().contains(where: {
                    $0.request.id == childID
                }) {
                    break
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }

            let observed = await fixture.call(
                "x.ai/subagent/get",
                params: .object(["subagentId": .string(childID)])
            )
            let snapshot = try #require(observed.value?["result"]?["snapshot"])
            #expect(snapshot["status"]?.stringValue == "completed")
            #expect(snapshot["output"]?.stringValue == "raw child answer")
            #expect(snapshot["output"]?.stringValue?.contains("<subagent_meta>") == false)
        }
    }

    @Test("scheduler deletion mutates the actual durable root-session state and persists removal")
    func schedulerDeleteUsesRealDurableHost() async throws {
        try await withACPTaskControlFixture { fixture in
            let task = try await fixture.scheduler.createTask(
                intervalSecs: 300,
                prompt: "keep checking deployment status",
                durable: true,
                foreground: false,
                fireImmediately: false
            )
            let before = await fixture.scheduler.list()
            #expect(before.contains { $0.id == task.id })

            let deleted = await fixture.call(
                "x.ai/scheduler/delete",
                params: .object([
                    "sessionId": .string(fixture.wireSessionID),
                    "taskId": .string(task.id),
                ])
            )
            #expect(deleted.error == nil)
            #expect(deleted.value == .object([
                "result": .object([
                    "taskId": .string(task.id),
                    "deleted": .bool(true),
                ]),
            ]))

            let reloaded = LiveSchedulerHost(persistence: fixture.persistence)
            let persisted = await reloaded.list()
            #expect(!persisted.contains { $0.id == task.id })
            await reloaded.shutdown()

            let missing = await fixture.call(
                "x.ai/scheduler/delete",
                params: .object([
                    "sessionId": .string(fixture.wireSessionID),
                    "taskId": .string(task.id),
                ])
            )
            #expect(missing.value?["result"]?["deleted"]?.boolValue == false)
        }
    }

    @Test("a foreign leader subscriber cannot control processes, children, or durable tasks")
    func foreignLeaderClientCannotControlOwnedResources() async throws {
        try await withACPTaskControlFixture(
            blocksChildren: true,
            leaderOwned: true
        ) { fixture in
            let taskID = try await fixture.startRealBackgroundTask()
            let childID = try await fixture.spawnRealChild()
            let schedule = try await fixture.scheduler.createTask(
                intervalSecs: 300,
                prompt: "private recurring work",
                durable: true,
                foreground: false,
                fireImmediately: false
            )

            let foreignTask = await fixture.call(
                "x.ai/task/kill",
                params: .object([
                    "sessionId": .string(fixture.wireSessionID),
                    "taskId": .string(taskID),
                    "_meta": .object([
                        "x.ai/leaderClientId": .string("owner-driver"),
                    ]),
                ]),
                clientID: "foreign-subscriber"
            )
            #expect(foreignTask.error != nil)

            let foreignChild = await fixture.call(
                "x.ai/subagent/cancel",
                params: .object(["subagentId": .string(childID)]),
                clientID: "foreign-subscriber"
            )
            #expect(foreignChild.value?["result"]?["outcome"]?["kind"]?.stringValue == "not_found")

            let foreignRead = await fixture.call(
                "x.ai/subagent/get",
                params: .object(["subagentId": .string(childID)]),
                clientID: "foreign-subscriber"
            )
            #expect(foreignRead.value?["result"]?["snapshot"] == .null)

            let foreignSchedule = await fixture.call(
                "x.ai/scheduler/delete",
                params: .object([
                    "sessionId": .string(fixture.wireSessionID),
                    "taskId": .string(schedule.id),
                ]),
                clientID: "foreign-subscriber"
            )
            #expect(foreignSchedule.error != nil)

            let process = try #require(await fixture.foundation.toolExecutor.processExecution(
                sessionID: fixture.foundation.sessionID,
                workingDirectory: fixture.workspace
            ))
            let task = await process.taskSnapshot(taskID)
            #expect(task?.completed == false)
            let host = try #require(fixture.foundation.subagentHost)
            let active = await host.coordinator.listActive(
                parentSessionID: fixture.foundation.sessionID
            )
            #expect(active.contains { $0.request.id == childID })
            let retained = await fixture.scheduler.list()
            #expect(retained.contains { $0.id == schedule.id })

            let ownerCancel = await fixture.call(
                "x.ai/subagent/cancel",
                params: .object(["subagentId": .string(childID)])
            )
            #expect(ownerCancel.value?["result"]?["cancelled"]?.boolValue == true)
        }
    }

    @Test("the first authenticated opening leader pins the entire root capability")
    func firstAuthenticatedLeaderPinsRootAcrossWireSessions() async throws {
        try await withACPTaskControlFixture(leaderOwned: true) { fixture in
            let secondWireSessionID = "wire-second-\(UUID().uuidString)"
            let sessionIDs = ACPTaskControlSessionIDs([
                fixture.wireSessionID,
                secondWireSessionID,
            ])
            let runtime = ACPAgentRuntime(
                extensionHandler: fixture.handler,
                onSessionOpened: { sessionID, _ in
                    await fixture.handler.opened(sessionID)
                },
                onSessionClosed: { sessionID in
                    await fixture.handler.closed(sessionID)
                },
                makeSessionId: { sessionIDs.next() }
            )
            await fixture.gateway.attach(runtime)
            await runtime.setReverseSender { _ in }
            await runtime.setSessionOwnerVerifier { sessionID, clientID in
                switch sessionID.rawValue {
                case fixture.wireSessionID:
                    return clientID == "owner-driver"
                case secondWireSessionID:
                    return clientID == "second-driver"
                default:
                    return false
                }
            }

            let initialized = try await ACPLeaderRequestAuthority.$clientID.withValue("owner-driver") {
                await runtime.handle(.request(
                    id: .string("pin-initialize"),
                    method: AgentMethodNames.initialize,
                    params: try JSONValue.encode(InitializeRequest(protocolVersion: .v1))
                ))
            }
            guard case .response(_, _?, nil)? = initialized.last else {
                await runtime.close()
                throw CLIApplicationError.failed("pin fixture could not initialize")
            }

            let firstOpened = await ACPLeaderRequestAuthority.$clientID.withValue("owner-driver") {
                await runtime.handle(.request(
                    id: .string("pin-first-open"),
                    method: AgentMethodNames.sessionNew,
                    params: .object([
                        "cwd": .string(fixture.workspace.path),
                        "mcpServers": .array([]),
                    ])
                ))
            }
            guard case .response(_, let firstPayload?, nil)? = firstOpened.last,
                  firstPayload["sessionId"]?.stringValue == fixture.wireSessionID
            else {
                await runtime.close()
                throw CLIApplicationError.failed("first leader could not open its wire session")
            }

            let secondOpened = await ACPLeaderRequestAuthority.$clientID.withValue("second-driver") {
                await runtime.handle(.request(
                    id: .string("pin-second-open"),
                    method: AgentMethodNames.sessionNew,
                    params: .object([
                        "cwd": .string(fixture.workspace.path),
                        "mcpServers": .array([]),
                    ])
                ))
            }
            guard case .response(_, let secondPayload?, nil)? = secondOpened.last,
                  secondPayload["sessionId"]?.stringValue == secondWireSessionID
            else {
                await runtime.close()
                throw CLIApplicationError.failed("second leader did not own its separate wire session")
            }

            let taskID = try await fixture.startRealBackgroundTask()
            let refused = await ACPLeaderRequestAuthority.$clientID.withValue("second-driver") {
                await runtime.handle(.request(
                    id: .string("pin-second-kill"),
                    method: "x.ai/task/kill",
                    params: .object([
                        "sessionId": .string(secondWireSessionID),
                        "taskId": .string(taskID),
                    ])
                ))
            }
            guard case .response(_, let refusedValue?, nil)? = refused.last else {
                await runtime.close()
                throw CLIApplicationError.failed("second leader control probe had no response")
            }
            #expect(refusedValue["error"]?.stringValue == "session not found")

            let process = try #require(await fixture.foundation.toolExecutor.processExecution(
                sessionID: fixture.foundation.sessionID,
                workingDirectory: fixture.workspace
            ))
            #expect(await process.taskSnapshot(taskID)?.completed == false)

            let admitted = await ACPLeaderRequestAuthority.$clientID.withValue("owner-driver") {
                await runtime.handle(.request(
                    id: .string("pin-owner-kill"),
                    method: "x.ai/task/kill",
                    params: .object([
                        "sessionId": .string(fixture.wireSessionID),
                        "taskId": .string(taskID),
                    ])
                ))
            }
            guard case .response(_, let admittedValue?, nil)? = admitted.last else {
                await runtime.close()
                throw CLIApplicationError.failed("root owner control probe had no response")
            }
            #expect(admittedValue["result"]?["outcome"]?.stringValue == "killed")
            await runtime.close()
        }
    }

    @Test("closed wire sessions and disconnected carriers fail closed before any mutation")
    func closedOrDisconnectedSessionCannotControlResources() async throws {
        try await withACPTaskControlFixture { fixture in
            let taskID = try await fixture.startRealBackgroundTask()
            await fixture.handler.closed(AcpSessionId(fixture.wireSessionID))

            let closed = await fixture.call(
                "x.ai/task/kill",
                params: .object([
                    "sessionId": .string(fixture.wireSessionID),
                    "taskId": .string(taskID),
                ])
            )
            #expect(closed.value == .object([
                "result": .null,
                "error": .string("session not found"),
            ]))

            await fixture.handler.opened(AcpSessionId(fixture.wireSessionID))
            await fixture.runtime.setReverseSender(nil)
            let disconnected = await fixture.call(
                "x.ai/task/kill",
                params: .object([
                    "sessionId": .string(fixture.wireSessionID),
                    "taskId": .string(taskID),
                ])
            )
            #expect(disconnected.value?["error"]?.stringValue == "session not found")

            let process = try #require(await fixture.foundation.toolExecutor.processExecution(
                sessionID: fixture.foundation.sessionID,
                workingDirectory: fixture.workspace
            ))
            let task = await process.taskSnapshot(taskID)
            #expect(task?.completed == false)
        }
    }

    @Test("missing fields, invalid kill source, and invalid wait timeout are ACP invalid params")
    func malformedRequestsFailBeforeControlOperations() async throws {
        try await withACPTaskControlFixture { fixture in
            let malformed: [(String, JSONValue)] = [
                ("x.ai/task/list", .object([:])),
                ("x.ai/task/kill", .object([
                    "sessionId": .string(fixture.wireSessionID),
                    "taskId": .string("task"),
                    "source": .string("modelTool"),
                ])),
                ("x.ai/subagent/get", .object([
                    "subagentId": .string("child"),
                    "timeoutMs": .number(.int64(-1)),
                ])),
                ("x.ai/scheduler/delete", .object([
                    "sessionId": .string(fixture.wireSessionID),
                ])),
            ]

            for (method, params) in malformed {
                let response = await fixture.call(method, params: params)
                #expect(response.value == nil)
                #expect(response.error?.code == .invalidParams)
                #expect(response.error?.data?.stringValue?.hasPrefix("invalid params:") == true)
            }
        }
    }

    @Test("the real ACP composition advertises and routes all backed task-control methods")
    func productionACPCompositionRegistersRealControlSurface() async throws {
        try await withACPTaskControlFixture { fixture in
            let rootSessionID = "production-\(UUID().uuidString)"
            let wireSessionID = "production-wire-\(UUID().uuidString)"
            let parsed = try CLICommandParser.parseOrThrow([
                "acp",
                "--cwd", fixture.workspace.path,
                "--session-id", rootSessionID,
                "--model", "grok-4.5",
                "--always-approve",
            ])
            guard case .launch(let options) = parsed else {
                throw CLIApplicationError.failed("production ACP task fixture did not parse")
            }
            let dependencies = OpenGrokLiveCompositionDependencies(
                makeSampler: { _ in
                    OpenGrokLiveSampler { _, _ in
                        OpenGrokLiveSamplingResponse(output: "unused")
                    }
                }
            )
            let components = try await OpenGrokLiveApplicationLauncher
                .liveACPServices(dependencies: dependencies)
                .makeComponents(LiveACPLaunch(
                    workingDirectory: fixture.workspace,
                    openGrokHome: fixture.home,
                    environment: fixture.environment,
                    streams: CLIStreams(out: { _ in }, err: { _ in }),
                    options: options
                ))
            let runtime = ACPAgentRuntime(
                promptDriver: components.promptDriver,
                extensionHandler: components.extensionHandler,
                onSessionOpened: components.onSessionOpened,
                onSessionClosed: components.onSessionClosed,
                makeSessionId: { wireSessionID }
            )
            do {
                guard let gateway = components.notificationGateway else {
                    throw CLIApplicationError.failed("production ACP has no notification gateway")
                }
                await gateway.attach(runtime)
                await runtime.setReverseSender { _ in }
                let initialized = await runtime.handle(.request(
                    id: .string("production-task-initialize"),
                    method: AgentMethodNames.initialize,
                    params: try JSONValue.encode(InitializeRequest(protocolVersion: .v1))
                ))
                guard case .response(_, _?, nil)? = initialized.last else {
                    throw CLIApplicationError.failed("production ACP could not initialize")
                }
                let opened = await runtime.handle(.request(
                    id: .string("production-task-open"),
                    method: AgentMethodNames.sessionNew,
                    params: .object([
                        "cwd": .string(fixture.workspace.path),
                        "mcpServers": .array([]),
                    ])
                ))
                guard case .response(_, _?, nil)? = opened.last else {
                    throw CLIApplicationError.failed("production ACP could not open its session")
                }

                let probes: [(String, JSONValue, String)] = [
                    ("x.ai/task/list", .object([
                        "sessionId": .string(wireSessionID),
                    ]), "tasks"),
                    ("x.ai/task/kill", .object([
                        "sessionId": .string(wireSessionID),
                        "taskId": .string("absent"),
                    ]), "outcome"),
                    ("x.ai/subagent/cancel", .object([
                        "subagentId": .string("absent"),
                    ]), "cancelled"),
                    ("x.ai/subagent/get", .object([
                        "subagentId": .string("absent"),
                    ]), "snapshot"),
                    ("x.ai/subagent/list_running", .object([
                        "sessionId": .string(wireSessionID),
                    ]), "subagents"),
                    ("x.ai/scheduler/delete", .object([
                        "sessionId": .string(wireSessionID),
                        "taskId": .string("absent"),
                    ]), "deleted"),
                ]
                for (method, params, resultKey) in probes {
                    let messages = await runtime.handle(.request(
                        id: .string("production-\(method)"),
                        method: method,
                        params: params
                    ))
                    guard case .response(_, let result?, nil)? = messages.last else {
                        Issue.record("production ACP did not route \(method): \(messages)")
                        continue
                    }
                    #expect(result["result"]?[resultKey] != nil)
                }
                await runtime.close()
                await components.promptDriver.shutdown()
            } catch {
                await runtime.close()
                await components.promptDriver.shutdown()
                throw error
            }
        }
    }
}
