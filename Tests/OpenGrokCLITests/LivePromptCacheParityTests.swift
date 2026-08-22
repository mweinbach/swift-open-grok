import Foundation
import OpenGrokACP
import OpenGrokACPRuntime
import OpenGrokChatState
import OpenGrokHTTP
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokSamplingTypes
import OpenGrokSessionRuntime
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase
import OpenGrokTestSupport
import Testing
@testable import OpenGrokCLI

private final class PromptCacheTerminalSink: PagerTerminalSink, @unchecked Sendable {
    var capabilities: PagerTerminalCapabilities { .standard }

    func write(bytes: [UInt8]) throws {}

    func flush() throws {}
}

private actor PromptCacheSamplingScript {
    private var responses: [OpenGrokLiveSamplingResponse]
    private(set) var requests: [OpenGrokLiveSamplingRequest] = []

    init(_ responses: [OpenGrokLiveSamplingResponse]) {
        self.responses = responses
    }

    func next(_ request: OpenGrokLiveSamplingRequest) throws -> OpenGrokLiveSamplingResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            throw CLIApplicationError.failed("prompt-cache sampler exhausted")
        }
        return responses.removeFirst()
    }
}

private struct LivePromptCacheFixture {
    let root: URL
    let home: URL
    let workspace: URL
    let server: MockInferenceServer
    let environment: [String: String]

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-prompt-cache-\(UUID().uuidString)",
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
        environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "XDG_STATE_HOME": home.appendingPathComponent("state").path,
            "XAI_API_KEY": "test-xai-key",
        ]
    }

    func options() throws -> CLIExecutionOptions {
        let command = try CLICommandParser.parseOrThrow([
            "headless", "--prompt", "hello", "--cwd", workspace.path,
            "--model", "grok-4.5",
        ])
        guard case .launch(let options) = command else {
            throw CLIApplicationError.failed("prompt-cache fixture did not parse a launch")
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

    func renderer(
        sessionID: String,
        history: LiveConversationHistory?
    ) -> LiveInteractiveControllerRenderer {
        LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: OpenGrokLiveTerminal(
                isTTY: { false },
                size: { OpenGrokLiveTerminalSize(width: 160, height: 45) },
                write: { _ in }
            ),
            sink: PromptCacheTerminalSink(),
            workingDirectory: workspace.path,
            modelName: "grok-4.5",
            sessionID: sessionID,
            conversationHistory: history,
            openGrokHome: home,
            environment: environment
        )
    }

    func dispose() {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("Live prompt-cache production parity", .serialized)
struct LivePromptCacheParityTests {
    @Test("real provider turns populate the live /cache overlay without counting cache writes as hits")
    func realProviderTurnsReachCacheOverlay() async throws {
        let fixture = try LivePromptCacheFixture()
        defer { fixture.dispose() }

        let script = PromptCacheSamplingScript([
            OpenGrokLiveSamplingResponse(
                output: "first answer",
                usage: TokenUsage(
                    promptTokens: 1_000,
                    completionTokens: 100,
                    totalTokens: 1_100,
                    cachedPromptTokens: 0,
                    cacheCreationPromptTokens: 250
                ),
                costUsdTicks: 111
            ),
            OpenGrokLiveSamplingResponse(
                output: "second answer",
                usage: TokenUsage(
                    promptTokens: 1_500,
                    completionTokens: 200,
                    totalTokens: 1_700,
                    cachedPromptTokens: 1_200,
                    cacheCreationPromptTokens: 175
                ),
                costUsdTicks: 222
            ),
        ])
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { request, _ in
                    try await script.next(request)
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

        for index in 1...2 {
            let handle = try await shell.submitTurn(
                sessionID: sessionID,
                request: OpenGrokShellTurnRequest(
                    promptID: "actual-prompt-\(index)",
                    text: "cache turn \(index)",
                    turnID: "actual-turn-\(index)"
                )
            )
            let completed = try await shell.waitForTurn(
                handle,
                timeout: ShellDuration(timeInterval: 30)
            )
            #expect(completed.turnID == "actual-turn-\(index)")
        }

        let renderer = fixture.renderer(
            sessionID: foundation.sessionID,
            history: stack.conversationHistory
        )
        let response = try #require(await renderer.sessionCacheResponse())
        #expect(response.summary.totalTurns == 2)
        #expect(response.summary.totalPromptTokens == 2_500)
        #expect(response.summary.cachedTokens == 1_200)
        #expect(response.summary.steadyInputTokens == 1_500)
        #expect(response.summary.steadyCachedTokens == 1_200)
        #expect(response.summary.supportedInputTokens == 1_500)
        #expect(response.summary.supportedCachedTokens == 1_200)
        #expect(response.summary.overallHitRatePct == 80)
        #expect(response.summary.supportedHitRatePct == 80)
        #expect(response.recentTurns.map(\.turnIdx) == ["1", "2"])
        #expect(response.recentTurns.map(\.provider) == [.xai, .xai])
        #expect(response.recentTurns.map(\.modelID) == ["grok-4.5", "grok-4.5"])

        let usage = try #require(await stack.conversationHistory.usageSnapshot)
        #expect(usage.totals.cachedReadTokens == 1_200)
        #expect(usage.totals.cacheCreationTokens == 425)
        #expect(usage.trustedCostUsdTicks == 333)

        try await renderer.begin()
        try await renderer.render(.overlay(.cache))
        let overlay = try #require(await renderer.overlays.focused)
        #expect(overlay.id == "cache")
        guard case .text(let body) = overlay.content else {
            Issue.record("/cache did not produce the live text overlay")
            return
        }
        let rendered = body.lines.map(\.text).joined(separator: "\n")
        #expect(rendered.contains("All-provider hit rate: 80.0%"))
        #expect(rendered.contains("Supported hit rate:    80.0%"))
        #expect(rendered.contains("1,200 of 1,500"))
        #expect(rendered.contains("Turn #1 (loop 0) — cold start"))
        #expect(rendered.contains("Turn #2 (loop 0) — 80.0% hit"))
        #expect(!rendered.contains("no turns recorded"))
        #expect(!rendered.contains("1,375 of"))

        try await renderer.restoreTerminal()
        let shutdown = await shell.shutdown()
        #expect(!shutdown.timedOut)
    }

    @Test("an unmetered successful response is visibly unavailable rather than invented zero usage")
    func unmeteredResponseIsReportedTruthfully() async throws {
        let fixture = try LivePromptCacheFixture()
        defer { fixture.dispose() }
        let sessionID = "unmetered-\(UUID().uuidString)"
        let history = LiveConversationHistory(
            record: .new(sessionID: sessionID, workingDirectory: fixture.workspace),
            store: LiveConversationStore(openGrokHome: fixture.home)
        )
        await LivePromptCacheTracking.shared.record(
            history: history,
            sessionID: sessionID,
            promptID: "unmetered-provider-prompt",
            loopIndex: 0,
            request: ConversationRequest(items: [.user("unmetered")]),
            usage: nil,
            provider: .gemini,
            modelID: "gemini-unmetered"
        )

        let renderer = fixture.renderer(sessionID: sessionID, history: history)
        try await renderer.begin()
        try await renderer.render(.overlay(.cache))
        let overlay = try #require(await renderer.overlays.focused)
        guard case .text(let body) = overlay.content else {
            Issue.record("unmetered /cache did not produce a text overlay")
            return
        }
        let rendered = body.lines.map(\.text).joined(separator: "\n")
        #expect(rendered.contains("provider did not report token usage"))
        #expect(rendered.contains("1 model request"))
        #expect(!rendered.contains("no turns recorded"))
        #expect(!rendered.contains("0.0%"))
        try await renderer.restoreTerminal()
    }

    @Test("same session spellings never mix distinct resident history actors")
    func identicalIDsRemainOwnerIsolated() async throws {
        let first = try LivePromptCacheFixture()
        defer { first.dispose() }
        let second = try LivePromptCacheFixture()
        defer { second.dispose() }
        let sharedID = "isolated-root-\(UUID().uuidString)"
        let historyA = LiveConversationHistory(
            record: .new(sessionID: sharedID, workingDirectory: first.workspace),
            store: LiveConversationStore(openGrokHome: first.home)
        )
        let historyB = LiveConversationHistory(
            record: .new(sessionID: sharedID, workingDirectory: second.workspace),
            store: LiveConversationStore(openGrokHome: second.home)
        )

        for (history, tokens, provider) in [
            (historyA, 111, ModelProvider.xai),
            (historyB, 222, ModelProvider.codex),
        ] {
            await LivePromptCacheTracking.shared.record(
                history: history,
                sessionID: sharedID,
                promptID: "same-prompt-spelling",
                loopIndex: 0,
                request: ConversationRequest(items: [.user("isolated")]),
                usage: TokenUsage(promptTokens: UInt32(tokens)),
                provider: provider,
                modelID: provider.rawValue
            )
        }

        let a = try #require(await LivePromptCacheTracking.shared.observation(
            history: historyA,
            sessionID: sharedID
        ))
        let b = try #require(await LivePromptCacheTracking.shared.observation(
            history: historyB,
            sessionID: sharedID
        ))
        #expect(a.response.summary.totalPromptTokens == 111)
        #expect(b.response.summary.totalPromptTokens == 222)
        #expect(a.response.recentTurns[0].provider == .xai)
        #expect(b.response.recentTurns[0].provider == .codex)
        guard case .ambiguous = await LivePromptCacheTracking.shared.lookup(sessionID: sharedID) else {
            Issue.record("ambiguous durable session identities must fail closed")
            return
        }
    }

    @Test("tool follow-up rounds retain the logical prompt index and increment only loop index")
    func toolRoundsRetainPromptIdentity() async throws {
        let fixture = try LivePromptCacheFixture()
        defer { fixture.dispose() }
        let sessionID = "tool-round-cache-\(UUID().uuidString)"
        let history = LiveConversationHistory(
            record: .new(sessionID: sessionID, workingDirectory: fixture.workspace),
            store: LiveConversationStore(openGrokHome: fixture.home)
        )

        for (promptID, loop, tokens, cached) in [
            ("logical-first", UInt32(0), UInt32(1_000), UInt32(0)),
            ("logical-first", UInt32(1), UInt32(1_500), UInt32(900)),
            ("logical-second", UInt32(0), UInt32(2_000), UInt32(1_500)),
        ] {
            await LivePromptCacheTracking.shared.record(
                history: history,
                sessionID: sessionID,
                promptID: promptID,
                loopIndex: loop,
                request: ConversationRequest(items: [.user(promptID)]),
                usage: TokenUsage(promptTokens: tokens, cachedPromptTokens: cached),
                provider: .xai,
                modelID: "grok-4.5"
            )
        }

        let observation = try #require(await LivePromptCacheTracking.shared.observation(
            history: history,
            sessionID: sessionID
        ))
        #expect(observation.response.summary.totalTurns == 3)
        #expect(observation.response.recentTurns.map(\.turnIdx) == ["1", "1", "2"])
        #expect(observation.response.recentTurns.map(\.loopIndex) == [0, 1, 0])
    }

    @Test("session replacement preserves each resident session and never transfers parent cache to a fork")
    func replacementAndForkRemainSessionScoped() async throws {
        let fixture = try LivePromptCacheFixture()
        defer { fixture.dispose() }
        let firstID = "first-\(UUID().uuidString)"
        let secondID = "second-\(UUID().uuidString)"
        let forkID = "fork-\(UUID().uuidString)"
        let first = LiveConversationRecord.new(
            sessionID: firstID,
            workingDirectory: fixture.workspace
        )
        let second = LiveConversationRecord.new(
            sessionID: secondID,
            workingDirectory: fixture.workspace
        )
        var fork = LiveConversationRecord.new(
            sessionID: forkID,
            workingDirectory: fixture.workspace
        )
        fork.parentSessionID = firstID
        fork.cacheAffinityID = firstID
        let store = LiveConversationStore(openGrokHome: fixture.home)
        let history = LiveConversationHistory(record: first, store: store)

        await LivePromptCacheTracking.shared.record(
            history: history,
            sessionID: firstID,
            promptID: "first-prompt",
            loopIndex: 0,
            request: ConversationRequest(items: [.user("first")]),
            usage: TokenUsage(promptTokens: 700),
            provider: .xai,
            modelID: "grok-root"
        )

        try await history.replace(with: second)
        let originalWhileSwapped = await LivePromptCacheTracking.shared.observation(
            history: history,
            sessionID: firstID
        )
        #expect(originalWhileSwapped == nil)

        await LivePromptCacheTracking.shared.record(
            history: history,
            sessionID: secondID,
            promptID: "second-prompt",
            loopIndex: 0,
            request: ConversationRequest(items: [.user("second")]),
            usage: TokenUsage(promptTokens: 300),
            provider: .codex,
            modelID: "gpt-codex"
        )
        let replacement = try #require(await LivePromptCacheTracking.shared.observation(
            history: history,
            sessionID: secondID
        ))
        #expect(replacement.response.summary.totalPromptTokens == 300)

        try await history.replace(with: first)
        let restored = try #require(await LivePromptCacheTracking.shared.observation(
            history: history,
            sessionID: firstID
        ))
        #expect(restored.response.summary.totalPromptTokens == 700)
        #expect(restored.response.recentTurns[0].provider == .xai)

        let child = LiveConversationHistory(record: fork, store: store)
        let childObservation = await LivePromptCacheTracking.shared.observation(
            history: child,
            sessionID: forkID
        )
        #expect(childObservation == nil)
    }

    @Test("ACP cache queries follow their owning wire connection and reject foreign session ids")
    func acpCacheQueryIsLiveAndConnectionScoped() async throws {
        let fixture = try LivePromptCacheFixture()
        defer { fixture.dispose() }
        let rootID = "acp-cache-root-\(UUID().uuidString)"
        let history = LiveConversationHistory(
            record: .new(sessionID: rootID, workingDirectory: fixture.workspace),
            store: LiveConversationStore(openGrokHome: fixture.home)
        )
        await LivePromptCacheTracking.shared.record(
            history: history,
            sessionID: rootID,
            promptID: "provider-prompt",
            loopIndex: 0,
            request: ConversationRequest(items: [.user("show cache")]),
            usage: TokenUsage(promptTokens: 640, cachedPromptTokens: 120),
            provider: .xai,
            modelID: "grok-acp"
        )

        let gateway = ACPNotificationGateway()
        let router = LiveACPExtensionRouter.build(
            feedback: nil,
            models: LiveModelsACPHandler(
                catalogStore: LiveModelCatalogStore(
                    input: .default,
                    environment: fixture.environment,
                    openGrokHome: fixture.home,
                    transport: MockHTTPTransport(responses: [])
                ),
                modelSwitch: nil
            ),
            sessionAdmin: LiveSessionAdminACPHandler(
                openGrokHome: fixture.home,
                gateway: gateway,
                liveSessionID: rootID
            )
        )
        let runtime = ACPAgentRuntime(
            store: InMemoryACPSessionStore(),
            extensionRouter: router,
            makeSessionId: { "owned-acp-wire-session" }
        )
        await gateway.attach(runtime)

        let initialized = await runtime.handle(.request(
            id: .string("initialize"),
            method: AgentMethodNames.initialize,
            params: try JSONValue.encode(InitializeRequest(protocolVersion: .v1))
        ))
        guard case .response(_, _, nil) = try #require(initialized.first) else {
            Issue.record("ACP cache runtime did not initialize: \(initialized)")
            return
        }
        let created = await runtime.handle(.request(
            id: .string("new"),
            method: AgentMethodNames.sessionNew,
            params: try JSONValue.encode(NewSessionRequest(cwd: fixture.workspace.path))
        ))
        guard case .response(_, _, nil) = try #require(created.first) else {
            Issue.record("ACP cache wire session was not created: \(created)")
            return
        }

        for method in SessionCacheQuery.methods {
            let output = await runtime.handle(.request(
                id: .string(method),
                method: method,
                params: .object(["sessionId": .string("owned-acp-wire-session")])
            ))
            guard case .response(_, let result?, nil) = try #require(output.first) else {
                Issue.record("ACP cache query did not return live diagnostics: \(output)")
                return
            }
            #expect(result["summary"]?["totalInputTokens"]?.int64Value == 640)
            #expect(result["summary"]?["totalCachedTokens"]?.int64Value == 120)
            #expect(result["recentTurns"]?[0]?["provider"]?.stringValue == "xai")
            #expect(result["recentTurns"]?[0]?["modelId"]?.stringValue == "grok-acp")
        }

        for foreignID in [rootID, "other-clients-wire-session"] {
            let output = await runtime.handle(.request(
                id: .string("foreign-\(foreignID)"),
                method: "x.ai/session/cache",
                params: .object(["sessionId": .string(foreignID)])
            ))
            guard case .response(_, nil, let error?) = try #require(output.first) else {
                Issue.record("ACP cache exposed another session: \(output)")
                return
            }
            #expect(error.code == .resourceNotFound)
        }
    }
}
