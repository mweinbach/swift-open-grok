import Foundation
import OpenGrokSamplingTypes
import OpenGrokSessionPersistence
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase
import OpenGrokTestSupport
import Testing
@testable import OpenGrokCLI

private struct LiveSessionEventFixture {
    let root: URL
    let home: URL
    let workspace: URL
    let server: MockInferenceServer

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-live-events-\(UUID().uuidString)",
            isDirectory: true
        )
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
    }

    func cleanup() {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    func context() -> CLIApplicationContext {
        CLIApplicationContext(
            environment: [
                "HOME": home.path,
                "OPENGROK_HOME": home.path,
                "XDG_STATE_HOME": home.appendingPathComponent("state").path,
                "XAI_API_KEY": "test-xai-key",
            ],
            streams: CLIStreams(out: { _ in }, err: { _ in }),
            control: .never
        )
    }

    func options() throws -> CLIExecutionOptions {
        let command = try CLICommandParser.parseOrThrow([
            "headless", "--prompt", "hello", "--cwd", workspace.path, "--model", "grok-4.5",
        ])
        guard case .launch(let options) = command else {
            throw CLIApplicationError.failed("event fixture did not parse a launch")
        }
        return options
    }
}

private actor LiveSessionEventSampler {
    private var requestCount = 0
    private let executesTool: Bool

    init(executesTool: Bool) {
        self.executesTool = executesTool
    }

    func sample(
        _ request: OpenGrokLiveSamplingRequest,
        emit: @escaping OpenGrokLiveSampler.Emit
    ) async -> OpenGrokLiveSamplingResponse {
        requestCount += 1
        if executesTool && requestCount == 1 {
            await emit(.reasoning("EVENT_SECRET_REASONING"))
            await emit(.output("EVENT_SECRET_ASSISTANT"))
            return OpenGrokLiveSamplingResponse(
                output: "EVENT_SECRET_ASSISTANT",
                toolCalls: [ToolCall(
                    id: "event-tool-1",
                    name: "todo_write",
                    arguments: #"{"todos":[{"id":"1","content":"EVENT_SECRET_ARGUMENT","status":"pending"}]}"#
                )]
            )
        }

        await emit(.output("EVENT_SECRET_FINAL"))
        return OpenGrokLiveSamplingResponse(output: "EVENT_SECRET_FINAL")
    }
}

@Suite("Live durable session event-log parity", .serialized)
struct LiveSessionEventLogParityTests {
    @Test("real session turns create private canonical events without prompt, output, or arguments")
    func realTurnWritesCanonicalPrivateEvents() async throws {
        let fixture = try LiveSessionEventFixture()
        defer { fixture.cleanup() }
        let sampler = LiveSessionEventSampler(executesTool: true)
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { request, emit in
                    await sampler.sample(request, emit: emit)
                }
            }
        )
        let foundation = try await OpenGrokLiveApplicationLauncher.makeSessionFoundation(
            options: fixture.options(),
            context: fixture.context(),
            dependencies: dependencies
        )
        let stack = await OpenGrokLiveApplicationLauncher.makeAgentStack(
            foundation: foundation,
            context: fixture.context(),
            dependencies: dependencies
        )
        let documents = SessionDocumentStore(grokHome: fixture.home)
        let directory = try documents.sessionDirectory(
            sessionID: foundation.sessionID,
            cwd: fixture.workspace.path
        )
        let eventFile = directory.appendingPathComponent("events.jsonl")
        #expect(!FileManager.default.fileExists(atPath: eventFile.path))

        let shell = stack.shell
        #expect(try await shell.start().state == .running)
        let sessionID = SessionID(foundation.sessionID)
        let descriptor = try await shell.createSession(OpenGrokShellSessionRequest(
            sessionID: sessionID,
            cwd: foundation.cwd,
            providerConfiguration: foundation.providerConfiguration
        ))
        #expect(descriptor.sessionID == sessionID)
        let handle = try await shell.submitTurn(
            sessionID: sessionID,
            request: OpenGrokShellTurnRequest(
                promptID: "event-prompt",
                text: "EVENT_SECRET_PROMPT",
                turnID: "event-turn"
            )
        )
        let result = try await shell.waitForTurn(
            handle,
            timeout: ShellDuration(timeInterval: 30)
        )
        #expect(result.turnID == "event-turn")

        let values = try documents.readEvents(
            sessionID: foundation.sessionID,
            cwd: fixture.workspace.path
        )
        let types = values.compactMap { $0["type"]?.stringValue }
        #expect(types.first == "turn_started")
        #expect(types.last == "turn_ended")
        #expect(types.filter { $0 == "loop_started" }.count == 2)
        #expect(types.filter { $0 == "first_token" }.count == 2)
        #expect(types.filter { $0 == "tool_started" }.count == 1)
        #expect(types.filter { $0 == "tool_completed" }.count == 1)
        #expect(values.first?["session_id"] == .string(foundation.sessionID))
        #expect(values.first?["turn_number"]?.uint64Value == 0)
        #expect(values.first?["conversation_message_count"]?.uint64Value == 0)
        #expect(values.last?["outcome"] == .string("completed"))
        let tool = try #require(values.first { $0["type"]?.stringValue == "tool_completed" })
        #expect(tool["tool_call_id"] == .string("event-tool-1"))
        #expect(tool["outcome"] == .string("success"))
        #expect(tool["source"] == nil)

        let contents = try String(contentsOf: eventFile, encoding: .utf8)
        #expect(!contents.contains("EVENT_SECRET_"))
        let attributes = try FileManager.default.attributesOfItem(atPath: eventFile.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(await stack.conversationHistory.eventLoggingFailure == nil)

        #expect(await shell.shutdown().timedOut == false)
        await foundation.toolExecutor.shutdown()
    }

    @Test("resumed turns append monotonically and forks do not inherit parent events")
    func resumedNumberingAndForkIsolation() async throws {
        let fixture = try LiveSessionEventFixture()
        defer { fixture.cleanup() }
        let sampler = LiveSessionEventSampler(executesTool: false)
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { request, emit in
                    await sampler.sample(request, emit: emit)
                }
            }
        )
        let foundation = try await OpenGrokLiveApplicationLauncher.makeSessionFoundation(
            options: fixture.options(),
            context: fixture.context(),
            dependencies: dependencies
        )
        let stack = await OpenGrokLiveApplicationLauncher.makeAgentStack(
            foundation: foundation,
            context: fixture.context(),
            dependencies: dependencies
        )
        let shell = stack.shell
        #expect(try await shell.start().state == .running)
        let sessionID = SessionID(foundation.sessionID)
        let created = try await shell.createSession(OpenGrokShellSessionRequest(
            sessionID: sessionID,
            cwd: foundation.cwd,
            providerConfiguration: foundation.providerConfiguration
        ))
        #expect(created.sessionID == sessionID)

        for index in 0..<2 {
            let handle = try await shell.submitTurn(
                sessionID: sessionID,
                request: OpenGrokShellTurnRequest(
                    promptID: "event-prompt-\(index)",
                    text: "run \(index)",
                    turnID: "event-turn-\(index)"
                )
            )
            let completed = try await shell.waitForTurn(
                handle,
                timeout: ShellDuration(timeInterval: 30)
            )
            #expect(completed.turnID == "event-turn-\(index)")
        }

        let documents = SessionDocumentStore(grokHome: fixture.home)
        let restored = try await foundation.conversationStore.load(sessionID: foundation.sessionID)
        let resumed = LiveConversationHistory(record: restored, store: foundation.conversationStore)
        await resumed.beginEventTurn(modelID: "grok-4.5", yoloMode: false)
        await resumed.endEventTurn(outcome: .completed)
        let parentEvents = try documents.readEvents(
            sessionID: foundation.sessionID,
            cwd: fixture.workspace.path
        )
        #expect(parentEvents.compactMap { event in
            event["type"]?.stringValue == "turn_started"
                ? event["turn_number"]?.uint64Value
                : nil
        } == [0, 1, 2])

        let child = try await foundation.conversationStore.fork(
            sourceSessionID: foundation.sessionID,
            destinationSessionID: "event-child",
            workingDirectory: fixture.workspace
        )
        let childDirectory = try documents.sessionDirectory(
            sessionID: child.sessionID,
            cwd: fixture.workspace.path
        )
        #expect(!FileManager.default.fileExists(
            atPath: childDirectory.appendingPathComponent("events.jsonl").path
        ))
        let childHistory = LiveConversationHistory(
            record: child,
            store: foundation.conversationStore
        )
        await childHistory.beginEventTurn(modelID: "grok-4.5", yoloMode: false)
        await childHistory.endEventTurn(outcome: .completed)
        let childEvents = try documents.readEvents(
            sessionID: child.sessionID,
            cwd: fixture.workspace.path
        )
        #expect(childEvents.first?["session_id"] == .string(child.sessionID))
        #expect(childEvents.count == 2)
        #expect(try documents.readEvents(
            sessionID: foundation.sessionID,
            cwd: fixture.workspace.path
        ).count == parentEvents.count)

        #expect(await shell.shutdown().timedOut == false)
        await foundation.toolExecutor.shutdown()
    }

    @Test("provider errors publish an error terminal without exposing error or prompt contents")
    func providerFailureEndsTurnWithoutSecrets() async throws {
        let fixture = try LiveSessionEventFixture()
        defer { fixture.cleanup() }
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { _, _ in
                    throw CLIApplicationError.failed("EVENT_SECRET_PROVIDER_FAILURE")
                }
            }
        )
        let foundation = try await OpenGrokLiveApplicationLauncher.makeSessionFoundation(
            options: fixture.options(),
            context: fixture.context(),
            dependencies: dependencies
        )
        let stack = await OpenGrokLiveApplicationLauncher.makeAgentStack(
            foundation: foundation,
            context: fixture.context(),
            dependencies: dependencies
        )
        let shell = stack.shell
        #expect(try await shell.start().state == .running)
        let sessionID = SessionID(foundation.sessionID)
        let descriptor = try await shell.createSession(OpenGrokShellSessionRequest(
            sessionID: sessionID,
            cwd: foundation.cwd,
            providerConfiguration: foundation.providerConfiguration
        ))
        #expect(descriptor.sessionID == sessionID)
        let handle = try await shell.submitTurn(
            sessionID: sessionID,
            request: OpenGrokShellTurnRequest(
                promptID: "failure-prompt",
                text: "EVENT_SECRET_PROMPT",
                turnID: "failure-turn"
            )
        )
        do {
            let unexpected = try await shell.waitForTurn(
                handle,
                timeout: ShellDuration(timeInterval: 30)
            )
            Issue.record("failing provider unexpectedly completed \(unexpected.turnID)")
        } catch OpenGrokShellError.turnFailed {
            // The provider failure remains user-visible while logging stays observational.
        }

        let documents = SessionDocumentStore(grokHome: fixture.home)
        let values = try documents.readEvents(
            sessionID: foundation.sessionID,
            cwd: fixture.workspace.path
        )
        #expect(values.first?["type"] == .string("turn_started"))
        #expect(values.last?["type"] == .string("turn_ended"))
        #expect(values.last?["outcome"] == .string("error"))
        #expect(values.filter { $0["type"] == .string("turn_ended") }.count == 1)
        let directory = try documents.sessionDirectory(
            sessionID: foundation.sessionID,
            cwd: fixture.workspace.path
        )
        let contents = try String(
            contentsOf: directory.appendingPathComponent("events.jsonl"),
            encoding: .utf8
        )
        #expect(!contents.contains("EVENT_SECRET_"))

        #expect(await shell.shutdown().timedOut == false)
        await foundation.toolExecutor.shutdown()
    }
}
