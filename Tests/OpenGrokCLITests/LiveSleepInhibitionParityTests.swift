import Foundation
import OpenGrokConfig
import OpenGrokDiagnostics
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokSystemPower
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokCLI

private final class SleepRecordingAdapter: PowerAdapter, @unchecked Sendable {
    struct Counts: Sendable, Equatable {
        var acquisitions = 0
        var releases = 0
    }

    private let lock = NSLock()
    private var counts = Counts()
    private let fails: Bool

    init(fails: Bool = false) {
        self.fails = fails
    }

    var snapshot: Counts {
        withCounts { $0 }
    }

    func acquire(kind: PowerLeaseKind, reason: String) async throws -> any PowerLease {
        withCounts { $0.acquisitions += 1 }
        if fails {
            throw PowerError.unsupported("test platform unavailable")
        }
        return SleepRecordingLease(kind: kind, reason: reason, owner: self)
    }

    fileprivate func didRelease() {
        withCounts { $0.releases += 1 }
    }

    private func withCounts<Value>(_ operation: (inout Counts) -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return operation(&counts)
    }
}

private final class SleepRecordingLease: PowerLease, @unchecked Sendable {
    let kind: PowerLeaseKind
    let reason: String
    private let owner: SleepRecordingAdapter
    private let lock = NSLock()
    private var released = false

    init(kind: PowerLeaseKind, reason: String, owner: SleepRecordingAdapter) {
        self.kind = kind
        self.reason = reason
        self.owner = owner
    }

    func release() async {
        releaseOnce()
    }

    private func releaseOnce() {
        lock.lock()
        defer { lock.unlock() }
        guard !released else { return }
        released = true
        owner.didRelease()
    }
}

private final class SleepTerminalSink: PagerTerminalSink, @unchecked Sendable {
    var capabilities: PagerTerminalCapabilities { .standard }
    func write(bytes: [UInt8]) throws {}
    func flush() throws {}
}

private extension LiveInteractiveControllerRenderer {
    func installSleepInhibitionForTesting(_ inhibition: LiveSleepInhibition) {
        terminalNotifications.sleepInhibition.shutdown()
        terminalNotifications.sleepInhibition = inhibition
    }
}

private struct SleepRendererFixture {
    let home: URL
    let adapter: SleepRecordingAdapter
    let inhibition: LiveSleepInhibition
    let renderer: LiveInteractiveControllerRenderer

    init(enabled: Bool = true, tty: Bool = true) throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-sleep-parity-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try "[ui.notifications]\nsleep_prevention = \(enabled)\n".write(
            to: home.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
        adapter = SleepRecordingAdapter()
        inhibition = LiveSleepInhibition(enabled: enabled, adapter: adapter)
        renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: OpenGrokLiveTerminal(
                isTTY: { tty },
                size: { OpenGrokLiveTerminalSize(width: 100, height: 30) },
                write: { _ in }
            ),
            sink: SleepTerminalSink(),
            workingDirectory: home.path,
            modelName: "sleep-parity-model",
            sessionID: "sleep-parity-session",
            openGrokHome: home,
            paintCadence: PagerMotion.minimumPaintCadence,
            environment: [
                "HOME": home.path,
                "OPENGROK_HOME": home.path,
                "TERM": "xterm-256color",
                "GROK_NO_MOTION": "1",
            ]
        )
    }

    func begin() async throws {
        await renderer.installSleepInhibitionForTesting(inhibition)
        try await renderer.begin()
    }

    func startTurn() async throws {
        try await renderer.render(.turnStarted(OpenGrokPagerRequest(
            prompt: "stay awake",
            mode: .fullScreen
        )))
        await inhibition.waitUntilSettled()
    }

    func finishTurn() async throws {
        try await renderer.render(.turnFinished(OpenGrokPagerRuntimeResult(
            lifecycle: .completed,
            sessionID: "sleep-parity-session",
            forwardedEventCount: 1,
            terminalRestored: false
        )))
        await inhibition.waitUntilSettled()
    }

    func cleanup() async {
        try? await renderer.restoreTerminal()
        await inhibition.waitUntilSettled()
        try? FileManager.default.removeItem(at: home)
    }
}

@Suite("Live sleep-inhibition Rust parity")
struct LiveSleepInhibitionParityTests {
    @Test("notification configuration defaults to enabled and honors explicit disable")
    func configuredDefaultAndDisable() throws {
        #expect(LiveTerminalNotificationConfiguration().sleepPrevention)
        let document = try parseTOML("[ui.notifications]\nsleep_prevention = false\n")
        #expect(!LiveTerminalNotificationConfiguration.resolve(document: document).sleepPrevention)

        let notifications = LiveTerminalNotifications(
            configuration: LiveTerminalNotificationConfiguration.resolve(document: document),
            terminalContext: TerminalContext(),
            powerAdapter: SleepRecordingAdapter()
        )
        #expect(!notifications.sleepInhibition.snapshot.enabled)
    }

    @Test("busy and idle transitions acquire and release exactly one lease")
    func acquireReleaseIdempotence() async {
        let adapter = SleepRecordingAdapter()
        let inhibition = LiveSleepInhibition(enabled: true, adapter: adapter)

        inhibition.synchronize(anyAgentBusy: true)
        inhibition.synchronize(anyAgentBusy: true)
        await inhibition.waitUntilSettled()
        #expect(adapter.snapshot == .init(acquisitions: 1, releases: 0))
        #expect(inhibition.snapshot.active)

        inhibition.synchronize(anyAgentBusy: false)
        inhibition.synchronize(anyAgentBusy: false)
        await inhibition.waitUntilSettled()
        #expect(adapter.snapshot == .init(acquisitions: 1, releases: 1))
        #expect(!inhibition.snapshot.active)
    }

    @Test("disabled configurations never acquire even across lifecycle transitions")
    func disabledNeverAcquires() async {
        let adapter = SleepRecordingAdapter()
        let inhibition = LiveSleepInhibition(enabled: false, adapter: adapter)
        inhibition.synchronize(anyAgentBusy: true)
        inhibition.suspend()
        inhibition.resume(anyAgentBusy: true)
        inhibition.shutdown()
        await inhibition.waitUntilSettled()
        #expect(adapter.snapshot == .init())
        #expect(!inhibition.snapshot.active)
    }

    @Test("unsupported platforms are attempted and reported only once")
    func platformFailureLatches() async {
        let adapter = SleepRecordingAdapter(fails: true)
        let inhibition = LiveSleepInhibition(enabled: true, adapter: adapter)

        inhibition.synchronize(anyAgentBusy: true)
        await inhibition.waitUntilSettled()
        inhibition.synchronize(anyAgentBusy: false)
        inhibition.synchronize(anyAgentBusy: true)
        inhibition.suspend()
        inhibition.resume(anyAgentBusy: true)
        await inhibition.waitUntilSettled()

        #expect(adapter.snapshot.acquisitions == 1)
        #expect(inhibition.snapshot.platformUnavailable)
        #expect(!inhibition.snapshot.active)
    }

    @Test("suspending releases the lease and resuming a busy turn reacquires")
    func suspendAndResume() async {
        let adapter = SleepRecordingAdapter()
        let inhibition = LiveSleepInhibition(enabled: true, adapter: adapter)
        inhibition.synchronize(anyAgentBusy: true)
        await inhibition.waitUntilSettled()

        inhibition.suspend()
        inhibition.suspend()
        await inhibition.waitUntilSettled()
        #expect(adapter.snapshot == .init(acquisitions: 1, releases: 1))

        inhibition.resume(anyAgentBusy: true)
        await inhibition.waitUntilSettled()
        #expect(adapter.snapshot == .init(acquisitions: 2, releases: 1))

        inhibition.shutdown()
        await inhibition.waitUntilSettled()
        #expect(adapter.snapshot == .init(acquisitions: 2, releases: 2))
    }

    @Test("shutdown releases permanently and rejects later busy or resume events")
    func shutdownIsTerminal() async {
        let adapter = SleepRecordingAdapter()
        let inhibition = LiveSleepInhibition(enabled: true, adapter: adapter)
        inhibition.synchronize(anyAgentBusy: true)
        await inhibition.waitUntilSettled()
        inhibition.shutdown()
        inhibition.shutdown()
        inhibition.synchronize(anyAgentBusy: true)
        inhibition.resume(anyAgentBusy: true)
        await inhibition.waitUntilSettled()
        #expect(adapter.snapshot == .init(acquisitions: 1, releases: 1))
        #expect(inhibition.snapshot.shutdown)
    }

    @Test("real interactive turn start and completion control the injected platform lease")
    func liveTurnLifecycle() async throws {
        let fixture = try SleepRendererFixture()
        do {
            try await fixture.begin()
            #expect(await fixture.renderer.terminalNotifications.configuration.sleepPrevention)
            #expect(fixture.adapter.snapshot == .init())
            try await fixture.startTurn()
            #expect(fixture.adapter.snapshot == .init(acquisitions: 1, releases: 0))
            try await fixture.finishTurn()
            #expect(fixture.adapter.snapshot == .init(acquisitions: 1, releases: 1))
        } catch {
            await fixture.cleanup()
            throw error
        }
        await fixture.cleanup()
    }

    @Test("live turn cancellation and terminal teardown release immediately")
    func liveCancellationAndShutdown() async throws {
        let fixture = try SleepRendererFixture()
        do {
            try await fixture.begin()
            try await fixture.startTurn()
            try await fixture.renderer.render(.turnCancelled)
            await fixture.inhibition.waitUntilSettled()
            #expect(fixture.adapter.snapshot == .init(acquisitions: 1, releases: 1))

            try await fixture.startTurn()
            try await fixture.renderer.restoreTerminal()
            await fixture.inhibition.waitUntilSettled()
            #expect(fixture.adapter.snapshot == .init(acquisitions: 2, releases: 2))
        } catch {
            await fixture.cleanup()
            throw error
        }
        await fixture.cleanup()
    }

    @Test("live project configuration can disable inhibition without disabling turns")
    func liveConfiguredDisable() async throws {
        let fixture = try SleepRendererFixture(enabled: false)
        do {
            try await fixture.begin()
            #expect(await !fixture.renderer.terminalNotifications.configuration.sleepPrevention)
            try await fixture.startTurn()
            try await fixture.finishTurn()
            #expect(fixture.adapter.snapshot == .init())
        } catch {
            await fixture.cleanup()
            throw error
        }
        await fixture.cleanup()
    }

    @Test("background subagents inhibit while shell and scheduled work remain idle")
    func liveBackgroundAgentAggregation() async throws {
        let fixture = try SleepRendererFixture()
        do {
            try await fixture.begin()
            let shell = try #require(LiveActiveBackgroundWorkEvent.upsert(
                kind: .shell,
                id: "shell-only"
            ))
            await fixture.renderer.applyActiveBackgroundWork(shell)
            await fixture.inhibition.waitUntilSettled()
            #expect(fixture.adapter.snapshot == .init())

            let agent = try #require(LiveActiveBackgroundWorkEvent.upsert(
                kind: .subagent,
                id: "child-one"
            ))
            await fixture.renderer.applyActiveBackgroundWork(agent)
            await fixture.inhibition.waitUntilSettled()
            #expect(fixture.adapter.snapshot == .init(acquisitions: 1, releases: 0))

            let removeAgent = try #require(LiveActiveBackgroundWorkEvent.remove(
                kind: .subagent,
                id: "child-one"
            ))
            await fixture.renderer.applyActiveBackgroundWork(removeAgent)
            await fixture.inhibition.waitUntilSettled()
            #expect(fixture.adapter.snapshot == .init(acquisitions: 1, releases: 1))
        } catch {
            await fixture.cleanup()
            throw error
        }
        await fixture.cleanup()
    }
}
