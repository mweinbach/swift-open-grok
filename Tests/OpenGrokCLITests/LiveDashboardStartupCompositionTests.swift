import Foundation
import OpenGrokAuth
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokCLI

private actor DashboardStartupLaunchRecorder {
    struct Invocation: Sendable {
        let command: CLICommand
        let environment: [String: String]
    }

    private(set) var invocations: [Invocation] = []

    func record(command: CLICommand, environment: [String: String]) {
        invocations.append(Invocation(command: command, environment: environment))
    }
}

private final class DashboardStartupDiscardingSink: PagerTerminalSink, @unchecked Sendable {
    var capabilities: PagerTerminalCapabilities { .standard }

    func write(bytes: [UInt8]) throws {}

    func flush() throws {}
}

private struct DashboardStartupFixture {
    let home: URL
    let environment: [String: String]

    init(
        extraEnvironment: [String: String] = [:],
        config: String? = nil
    ) throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "opengrok-dashboard-startup-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        if let config {
            try config.write(
                to: home.appendingPathComponent("config.toml"),
                atomically: true,
                encoding: .utf8
            )
        }

        var environment = ["HOME": home.path, "OPENGROK_HOME": home.path]
        environment.merge(extraEnvironment) { _, replacement in replacement }
        self.environment = environment
    }

    func makeRenderer() -> LiveInteractiveControllerRenderer {
        LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: OpenGrokLiveTerminal(
                isTTY: { false },
                size: { OpenGrokLiveTerminalSize(width: 100, height: 40) },
                write: { _ in }
            ),
            sink: DashboardStartupDiscardingSink(),
            workingDirectory: home.path,
            sessionID: "dashboard-startup-session",
            sessionCatalog: LiveSessionCatalog(openGrokHome: home),
            conversationStore: LiveConversationStore(openGrokHome: home),
            openGrokHome: home,
            paintCadence: PagerMotion.minimumPaintCadence,
            environment: environment
        )
    }

    func seedAuthentication() async throws {
        let manager = AuthManager(
            grokHome: home,
            config: GrokComConfig.default(environment: environment),
            environment: environment
        )
        try await manager.update(GrokAuth(
            key: "dashboard-startup-test-key",
            authMode: .apiKey,
            userID: "dashboard-startup-user"
        ))
    }

    func dispose() {
        try? FileManager.default.removeItem(at: home)
    }
}

private func dashboardStartupApplication(
    recording recorder: DashboardStartupLaunchRecorder
) -> OpenGrokApplication {
    OpenGrokApplication(
        launcher: CLIApplicationLauncher { command, context in
            await recorder.record(command: command, environment: context.environment)
            return CLIApplicationSession(
                waitForExit: {},
                shutdown: {}
            )
        },
        control: .never
    )
}

private func dashboardStartupEventuallyOpens(
    _ renderer: LiveInteractiveControllerRenderer
) async -> Bool {
    for _ in 0..<100 {
        if await renderer.dashboardSnapshotForTesting().isOpen {
            return true
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await renderer.dashboardSnapshotForTesting().isOpen
}

@Suite("dashboard startup live composition", .serialized)
struct LiveDashboardStartupCompositionTests {
    @Test("dashboard reaches the regular interactive launcher with a local startup flag")
    func dashboardLaunchesInteractively() async throws {
        let fixture = try DashboardStartupFixture()
        defer { fixture.dispose() }
        let recorder = DashboardStartupLaunchRecorder()
        let (streams, out, err) = CLIStreams.buffered()
        let processFlag = ProcessInfo.processInfo.environment[
            LiveDashboardStartupComposition.startupEnvironmentVariable
        ]

        let exitCode = await CLIRunner.run(
            ["dashboard"],
            environment: fixture.environment,
            streams: streams,
            application: dashboardStartupApplication(recording: recorder)
        )

        #expect(exitCode == CLIRunner.ExitCode.success.rawValue)
        #expect(out.contents.isEmpty)
        #expect(err.contents.isEmpty)
        let invocations = await recorder.invocations
        #expect(invocations.count == 1)
        let invocation = try #require(invocations.first)
        guard case .launch(let options) = invocation.command else {
            Issue.record("dashboard must be normalized into the live interactive launch route")
            return
        }
        #expect(options.mode == .interactive)
        #expect(!options.common.leader)
        #expect(invocation.environment[
            LiveDashboardStartupComposition.startupEnvironmentVariable
        ] == "1")
        #expect(fixture.environment[
            LiveDashboardStartupComposition.startupEnvironmentVariable
        ] == nil)
        #expect(ProcessInfo.processInfo.environment[
            LiveDashboardStartupComposition.startupEnvironmentVariable
        ] == processFlag)
    }

    @Test("dashboard preserves --no-leader without forcing leader mode")
    func dashboardPreservesNoLeader() async throws {
        let fixture = try DashboardStartupFixture()
        defer { fixture.dispose() }
        let recorder = DashboardStartupLaunchRecorder()
        let (streams, _, err) = CLIStreams.buffered()

        let exitCode = await CLIRunner.run(
            ["--no-leader", "dashboard"],
            environment: fixture.environment,
            streams: streams,
            application: dashboardStartupApplication(recording: recorder)
        )

        #expect(exitCode == CLIRunner.ExitCode.success.rawValue)
        #expect(err.contents.isEmpty)
        let invocation = try #require(await recorder.invocations.first)
        guard case .launch(let options) = invocation.command else {
            Issue.record("expected the interactive launcher")
            return
        }
        #expect(options.mode == .interactive)
        #expect(options.common.noLeader)
        #expect(!options.common.leader)
    }

    @Test("environment kill-switch refuses dashboard before the launcher starts")
    func environmentKillSwitchRefusesBeforeLaunch() async throws {
        let fixture = try DashboardStartupFixture(
            extraEnvironment: ["GROK_AGENT_DASHBOARD": "0"]
        )
        defer { fixture.dispose() }
        let recorder = DashboardStartupLaunchRecorder()
        let (streams, out, err) = CLIStreams.buffered()

        let exitCode = await CLIRunner.run(
            ["dashboard"],
            environment: fixture.environment,
            streams: streams,
            application: dashboardStartupApplication(recording: recorder)
        )

        #expect(exitCode == CLIRunner.ExitCode.failure.rawValue)
        #expect(out.contents.isEmpty)
        #expect(err.contents.contains("Agent Dashboard is disabled"))
        #expect(err.contents.contains("GROK_AGENT_DASHBOARD=0"))
        #expect(await recorder.invocations.isEmpty)
    }

    @Test("persisted dashboard.enabled=false refuses before the launcher starts")
    func persistedKillSwitchRefusesBeforeLaunch() async throws {
        let fixture = try DashboardStartupFixture(config: """
            [dashboard]
            enabled = false
            """)
        defer { fixture.dispose() }
        let recorder = DashboardStartupLaunchRecorder()
        let (streams, out, err) = CLIStreams.buffered()

        let exitCode = await CLIRunner.run(
            ["dashboard"],
            environment: fixture.environment,
            streams: streams,
            application: dashboardStartupApplication(recording: recorder)
        )

        #expect(exitCode == CLIRunner.ExitCode.failure.rawValue)
        #expect(out.contents.isEmpty)
        #expect(err.contents.contains("Agent Dashboard is disabled"))
        #expect(err.contents.contains("[dashboard] enabled = false"))
        #expect(await recorder.invocations.isEmpty)
    }

    @Test("authenticated startup opens the dashboard during the real renderer begin")
    func authenticatedStartupOpensImmediately() async throws {
        let fixture = try DashboardStartupFixture(extraEnvironment: [
            LiveDashboardStartupComposition.startupEnvironmentVariable: "1"
        ])
        defer { fixture.dispose() }
        try await fixture.seedAuthentication()
        let renderer = fixture.makeRenderer()

        try await renderer.begin()

        #expect(await renderer.privacyBanner?.authDone == true)
        #expect(await renderer.dashboardSnapshotForTesting().isOpen)
        #expect(!(await renderer.pendingDashboardStartup))
        try await renderer.restoreTerminal()
    }

    @Test("unauthenticated dashboard startup survives login and is consumed exactly once")
    func unauthenticatedStartupDefersUntilAuthSuccess() async throws {
        let fixture = try DashboardStartupFixture(extraEnvironment: [
            LiveDashboardStartupComposition.startupEnvironmentVariable: "1"
        ])
        defer { fixture.dispose() }
        let renderer = fixture.makeRenderer()

        try await renderer.begin()
        #expect(await renderer.privacyBanner?.authDone == false)
        #expect(await renderer.pendingDashboardStartup)
        #expect(!(await renderer.dashboardSnapshotForTesting().isOpen))

        try await fixture.seedAuthentication()
        await renderer.beginWaveEAuth(providerName: "xAI Grok")
        await renderer.finishWaveEAuthSuccess("Signed in")

        #expect(await dashboardStartupEventuallyOpens(renderer))
        #expect(await renderer.privacyBanner?.authDone == true)
        #expect(!(await renderer.pendingDashboardStartup))

        #expect(try await renderer.handleInput(.key(KeyEvent(key: .escape))) == .consumed)
        #expect(!(await renderer.dashboardSnapshotForTesting().isOpen))
        await renderer.finishWaveEAuthSuccess("Signed in again")
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(!(await renderer.dashboardSnapshotForTesting().isOpen))
        #expect(!(await renderer.pendingDashboardStartup))

        let presentation = await renderer.authPresentationTask
        presentation?.cancel()
        try await renderer.restoreTerminal()
    }

    @Test("failed authentication leaves the dashboard deferred and unopened")
    func failedAuthenticationDoesNotOpenDashboard() async throws {
        let fixture = try DashboardStartupFixture(extraEnvironment: [
            LiveDashboardStartupComposition.startupEnvironmentVariable: "1"
        ])
        defer { fixture.dispose() }
        let renderer = fixture.makeRenderer()

        try await renderer.begin()
        await renderer.beginWaveEAuth(providerName: "xAI Grok")
        await renderer.finishWaveEAuthFailure("Sign-in failed")

        #expect(await renderer.privacyBanner?.authDone == false)
        #expect(await renderer.pendingDashboardStartup)
        #expect(!(await renderer.dashboardSnapshotForTesting().isOpen))
        try await renderer.restoreTerminal()
    }

    @Test("successful Codex-only authentication opens the deferred dashboard")
    func codexOnlyAuthenticationCompletesDeferredStartup() async throws {
        let fixture = try DashboardStartupFixture(extraEnvironment: [
            LiveDashboardStartupComposition.startupEnvironmentVariable: "1"
        ])
        defer { fixture.dispose() }
        let renderer = fixture.makeRenderer()

        try await renderer.begin()
        await renderer.beginWaveEAuth(providerName: "OpenAI Codex")
        await renderer.finishWaveEAuthSuccess("Connected OpenAI Codex")

        #expect(await dashboardStartupEventuallyOpens(renderer))
        #expect(await renderer.privacyBanner?.authDone == true)
        #expect(!(await renderer.pendingDashboardStartup))

        let presentation = await renderer.authPresentationTask
        presentation?.cancel()
        try await renderer.restoreTerminal()
    }
}
