import Foundation
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokCLI

private final class WaveETerminalSink: PagerTerminalSink, @unchecked Sendable {
    private let lock = NSLock()
    private var output = ""

    var capabilities: PagerTerminalCapabilities { .standard }

    func write(bytes: [UInt8]) throws {
        lock.lock()
        output += String(decoding: bytes, as: UTF8.self)
        lock.unlock()
    }

    func flush() throws {}

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return output
    }
}

@Suite("Wave E live reachability", .serialized)
struct WaveELiveReachabilityTests {
    @Test("recap updates its original transcript item in place")
    func recapUpsertsInPlace() {
        var conversation = LivePagerConversationState()
        conversation.upsertBlock(.sessionEvent(PagerSessionEventBlock(
            id: "recap-1",
            event: .recap(summary: nil, auto: true)
        )))
        conversation.upsertBlock(.sessionEvent(PagerSessionEventBlock(
            id: "recap-1",
            event: .recap(summary: "The completed recap", auto: true),
            isExpanded: true
        )))

        #expect(conversation.items.count == 1)
        guard case .block(.sessionEvent(let recap)) = conversation.items.first else {
            Issue.record("expected the typed recap block")
            return
        }
        #expect(recap.event == .recap(summary: "The completed recap", auto: true))
        #expect(recap.isExpanded)
    }

    @Test("lifecycle blocks cannot receive later tool or stop hooks")
    func lifecycleHookIsolation() {
        var conversation = LivePagerConversationState()
        conversation.upsertBlock(.lifecycle(PagerLifecycleBlock(
            id: "session-start",
            kind: .sessionStart,
            state: .succeeded,
            hooks: [PagerHookRun(name: "startup", phase: .pre, state: .succeeded)]
        )))
        conversation.attachHooks(
            [PagerHookRun(name: "tool", phase: .post, state: .failed)],
            toCallID: "session-start"
        )
        conversation.attachStopHooks(
            [PagerHookRun(name: "stop", phase: .stop, state: .failed)],
            toBlockID: "session-start"
        )

        guard case .block(.lifecycle(let lifecycle)) = conversation.items.first else {
            Issue.record("expected the lifecycle block")
            return
        }
        #expect(lifecycle.hooks.map(\.name) == ["startup"])
    }

    @Test("live subagent mapping preserves turns, tools, duration and outcome")
    func subagentCountersReachTranscriptBlock() {
        let startedAt = Date(timeIntervalSince1970: 100)
        let snapshot = LiveSubagentSnapshot(
            subagentID: "child-1",
            subagentType: "explore",
            description: "map the tree",
            status: "completed",
            output: "mapped",
            startedAt: startedAt,
            durationMS: 12_500,
            exitCode: 0,
            turnCount: 4,
            toolCallCount: 7
        )
        let block = LiveInteractiveControllerRenderer.waveESubagentBlock(
            snapshot,
            now: Date(timeIntervalSince1970: 999)
        )

        #expect(block.id == "subagent-child-1")
        #expect(block.label == "explore · map the tree")
        #expect(block.state == .succeeded)
        #expect(block.turnCount == 4)
        #expect(block.toolCount == 7)
        #expect(block.duration == 12.5)
        #expect(block.outcome == "mapped")
    }

    @Test("credit-limit classifier reaches all three typed actions")
    func creditLimitClassifier() {
        #expect(LiveWaveECreditLimitClassifier.action(
            message: "Pay-as-you-go is disabled"
        ) == .enablePayAsYouGo)
        #expect(LiveWaveECreditLimitClassifier.action(
            message: "Your spending cap was reached"
        ) == .increasePayAsYouGoLimit)
        #expect(LiveWaveECreditLimitClassifier.action(
            message: "Weekly limit reached; purchase credits"
        ) == .purchaseCredits)
        #expect(LiveWaveECreditLimitClassifier.action(message: "ordinary failure") == nil)
        #expect(LiveWaveECreditLimitClassifier.accountURL == "https://grok.com?_s=usage")
    }

    @Test("turn phases classify status text and expose honest cancellation")
    func turnPhaseStateMachine() {
        let cases: [(String, LiveWaveETurnPhase, Bool)] = [
            ("Compacting context", .compacting, true),
            ("Starting MCP: docs", .mcpStartup("Starting MCP: docs"), true),
            ("Running bash", .bash("Running bash"), true),
            ("Waiting for queued work", .drainBlocked, true),
            ("Watcher parked", .watcher("Watcher parked"), false),
            ("Waiting for permission", .waiting("Waiting for permission"), true),
            ("Cancelling", .cancelling, false),
        ]
        for (text, expected, canCancel) in cases {
            let phase = LiveWaveETurnPhase.status(text)
            #expect(phase == expected)
            #expect(phase.allowsCancel == canCancel)
        }
        #expect(!LiveWaveETurnPhase.failed("auth").allowsCancel)
    }

    @Test("scroll log environment resolves disabled, default and explicit paths")
    func scrollLogURLResolution() {
        let home = URL(fileURLWithPath: "/tmp/opengrok-wave-e", isDirectory: true)
        #expect(LiveInteractiveControllerRenderer.waveEScrollLogURL(
            environmentValue: nil,
            openGrokHome: home
        ) == nil)
        #expect(LiveInteractiveControllerRenderer.waveEScrollLogURL(
            environmentValue: "0",
            openGrokHome: home
        ) == nil)
        let defaultURL = LiveInteractiveControllerRenderer.waveEScrollLogURL(
            environmentValue: "1",
            openGrokHome: home
        )
        #expect(defaultURL?.deletingLastPathComponent().path
            == home.appendingPathComponent("logs").path)
        #expect(defaultURL?.lastPathComponent.hasPrefix("scroll-log-") == true)
        #expect(defaultURL?.pathExtension == "jsonl")
        #expect(LiveInteractiveControllerRenderer.waveEScrollLogURL(
            environmentValue: "/tmp/custom-scroll.jsonl",
            openGrokHome: home
        )?.path == "/tmp/custom-scroll.jsonl")
    }

    @Test("raw auth mode disables mouse and failure restores it")
    func authMouseLifecycle() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-wave-e-auth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let sink = WaveETerminalSink()
        let terminal = OpenGrokLiveTerminal(
            isTTY: { false },
            size: { OpenGrokLiveTerminalSize(width: 80, height: 24) },
            write: { _ in }
        )
        let renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: terminal,
            sink: sink,
            workingDirectory: home.path,
            enableMouseReporting: true,
            sessionID: "wave-e-auth",
            openGrokHome: home,
            environment: ["HOME": home.path, "OPENGROK_HOME": home.path]
        )
        try await renderer.begin()
        #expect(await renderer.testingIsMouseReportingEnabled())

        await renderer.beginWaveEAuth(providerName: "xAI Grok")
        #expect(await renderer.testingWelcomeAuthState()?.phase == .signingIn)
        await renderer.announceWaveEAuthURL(try #require(URL(
            string: "https://example.com/device?user_code=ABCD-1234&payload=long"
        )))
        let trust = await renderer.testingWelcomeAuthState()
        #expect(trust?.phase == .trust)
        #expect(trust?.deviceCode == "ABCD-1234")
        #expect(trust?.rawURLMode == true)
        #expect(!(await renderer.testingIsMouseReportingEnabled()))

        await renderer.finishWaveEAuthFailure("Sign-in failed")
        #expect(await renderer.testingWelcomeAuthState()?.phase == .failed)
        #expect(await renderer.testingIsMouseReportingEnabled())
        #expect(sink.text.contains(ANSIMouse.disableReporting))
        #expect(sink.text.contains(ANSIMouse.enableReporting))
        try await renderer.restoreTerminal()
    }
}
