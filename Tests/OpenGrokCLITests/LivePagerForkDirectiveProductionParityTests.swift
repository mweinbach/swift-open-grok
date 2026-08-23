import Foundation
import OpenGrokPagerRender
import OpenGrokSamplingTypes
import OpenGrokTerminalCore
import Testing

@testable import OpenGrokCLI

private actor ForkDirectiveProductionSampling {
    struct Observation: Sendable {
        let request: OpenGrokLiveSamplingRequest
        let pendingAlreadyCleared: Bool
        let persistedUserCount: Int
    }

    private var observations: [Observation] = []

    func record(_ request: OpenGrokLiveSamplingRequest, persisted: LiveConversationRecord?) {
        let count = persisted?.items.reduce(into: 0) { result, item in
            guard case .user(let user) = item,
                  user.syntheticReason == nil,
                  item.textContent() == request.prompt
            else { return }
            result += 1
        } ?? 0
        observations.append(Observation(
            request: request,
            pendingAlreadyCleared: persisted?.pendingFirstPrompt == nil,
            persistedUserCount: count
        ))
    }

    var all: [Observation] { observations }
}

private final class ForkDirectiveProductionInput: PagerTerminalSink, @unchecked Sendable {
    private let stream: AsyncThrowingStream<InputEvent, Error>
    private let continuation: AsyncThrowingStream<InputEvent, Error>.Continuation

    init(finished: Bool = false) {
        let pair = AsyncThrowingStream<InputEvent, Error>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
        if finished { continuation.finish() }
    }

    var capabilities: PagerTerminalCapabilities { .standard }

    func write(bytes: [UInt8]) throws {}
    func flush() throws {}

    func makeInput() -> OpenGrokLiveInteractiveInput {
        OpenGrokLiveInteractiveInput(events: stream, close: { [self] in
            continuation.finish()
        })
    }

    func send(_ event: InputEvent) {
        continuation.yield(event)
    }

    func finish() {
        continuation.finish()
    }
}

private struct ForkDirectiveProductionFixture {
    let root: URL
    let home: URL
    let workspace: URL
    let environment: [String: String]
    let capture = ForkDirectiveProductionSampling()

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-fork-directive-live-\(UUID().uuidString)")
            .standardizedFileURL.resolvingSymlinksInPath()
        home = root.appendingPathComponent("home", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try "[features]\nremote_fetch = false\n".write(
            to: home.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
        environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "GROK_SANDBOX": "off",
            "XDG_STATE_HOME": home.appendingPathComponent("state").path,
            "XAI_API_KEY": "fork-directive-production-test-key",
            "GROK_FOLDER_TRUST": "0",
            "GROK_MANAGED_CONFIG": "0",
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        ]
    }

    func dispose() {
        try? FileManager.default.removeItem(at: root)
    }

    func seed(directive: String) async throws -> (parent: LiveConversationRecord, child: LiveConversationRecord) {
        let store = LiveConversationStore(openGrokHome: home)
        var parent = LiveConversationRecord.new(
            sessionID: "fork-directive-production-parent",
            workingDirectory: workspace
        )
        parent.currentModelID = "grok-4.5"
        parent.currentProvider = .xai
        parent.items = [
            .user("the original parent request"),
            .assistant(AssistantItem(content: "the original parent answer")),
        ]
        try await store.save(parent)
        let child = try await store.fork(
            sourceSessionID: parent.sessionID,
            destinationSessionID: "fork-directive-production-child",
            workingDirectory: workspace,
            pendingFirstPrompt: directive
        )
        return (parent, child)
    }

    func launch(
        sessionID: String,
        input: ForkDirectiveProductionInput,
        extraArguments: [String] = []
    ) async throws -> CLIApplicationSession {
        let capture = capture
        let home = home
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { request, emit in
                    let persisted: LiveConversationRecord?
                    do {
                        persisted = try await LiveConversationStore(openGrokHome: home)
                            .load(sessionID: request.sessionID)
                    } catch {
                        persisted = nil
                    }
                    await capture.record(request, persisted: persisted)
                    await emit(.output("fork directive completed"))
                    input.finish()
                    return OpenGrokLiveSamplingResponse(output: "fork directive completed")
                }
            },
            terminal: OpenGrokLiveTerminal(
                isTTY: { true },
                size: { OpenGrokLiveTerminalSize(width: 100, height: 32) },
                write: { _ in }
            ),
            makeInteractiveInput: { input.makeInput() },
            makeTerminalSink: { input }
        )
        let command = try CLICommandParser.parseOrThrow(
            ["--resume", sessionID, "--cwd", workspace.path,
             "--model", "grok-4.5", "--no-auto-update"] + extraArguments
        )
        let context = CLIApplicationContext(
            environment: environment,
            streams: CLIStreams(out: { _ in }, err: { _ in }),
            control: .never
        )
        return try await OpenGrokLiveApplicationLauncher(dependencies: dependencies)
            .launcher.start(command, context)
    }

    func wait(_ session: CLIApplicationSession, input: ForkDirectiveProductionInput) async throws {
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            input.finish()
        }
        defer { watchdog.cancel() }
        try await session.waitForExit()
        await session.shutdown()
    }
}

@Suite("Live fork directive production launch", .serialized)
struct LivePagerForkDirectiveProductionParityTests {
    @Test("real --resume submits the child directive once and clears it before provider sampling")
    func resumedForkInvokesActualProviderExactlyOnce() async throws {
        let fixture = try ForkDirectiveProductionFixture()
        defer { fixture.dispose() }
        let directive = "investigate only the forked rate-limit hypothesis"
        let seeded = try await fixture.seed(directive: directive)

        let firstInput = ForkDirectiveProductionInput()
        let first = try await fixture.launch(
            sessionID: seeded.child.sessionID,
            input: firstInput,
            extraArguments: ["--system-prompt", "trusted framework instructions"]
        )
        try await fixture.wait(first, input: firstInput)

        let firstObservations = await fixture.capture.all
        try #require(firstObservations.count == 1)
        let observation = firstObservations[0]
        #expect(observation.request.sessionID == seeded.child.sessionID)
        #expect(observation.request.prompt == directive)
        #expect(observation.pendingAlreadyCleared)
        #expect(observation.persistedUserCount == 1)
        #expect(observation.request.items.contains { item in
            guard case .system = item else { return false }
            return item.textContent().contains("trusted framework instructions")
        })
        #expect(observation.request.items.contains { item in
            guard case .user(let user) = item else { return false }
            return user.syntheticReason == nil && item.textContent() == directive
        })

        let freshStore = LiveConversationStore(openGrokHome: fixture.home)
        let child = try await freshStore.load(sessionID: seeded.child.sessionID)
        let parent = try await freshStore.load(sessionID: seeded.parent.sessionID)
        #expect(child.pendingFirstPrompt == nil)
        #expect(parent.items == seeded.parent.items)
        #expect(!parent.items.contains { $0.textContent() == directive })

        let secondInput = ForkDirectiveProductionInput(finished: true)
        let second = try await fixture.launch(sessionID: seeded.child.sessionID, input: secondInput)
        try await fixture.wait(second, input: secondInput)
        #expect(await fixture.capture.all.count == 1)
    }

    @Test("an in-pager /resume drains the queued directive as a genuine child user turn")
    func interactiveResumeDispatchesDirectiveThroughRealUserQueue() async throws {
        let fixture = try ForkDirectiveProductionFixture()
        defer { fixture.dispose() }
        let directive = "continue the isolated session from its durable directive"
        let seeded = try await fixture.seed(directive: directive)
        let input = ForkDirectiveProductionInput()
        let session = try await fixture.launch(sessionID: seeded.parent.sessionID, input: input)

        input.send(.paste("/resume \(seeded.child.sessionID)"))
        input.send(.key(KeyEvent(key: .enter)))
        try await fixture.wait(session, input: input)

        let observations = await fixture.capture.all
        try #require(observations.count == 1)
        #expect(observations[0].request.sessionID == seeded.child.sessionID)
        #expect(observations[0].request.prompt == directive)
        #expect(observations[0].pendingAlreadyCleared)
        #expect(observations[0].persistedUserCount == 1)
        let reloaded = try await LiveConversationStore(openGrokHome: fixture.home)
            .load(sessionID: seeded.child.sessionID)
        #expect(reloaded.pendingFirstPrompt == nil)
    }
}
