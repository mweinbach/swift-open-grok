// LiveLaunchAutoUpdateReachabilityTests.swift
//
// Reachability of the post-readiness launch update check through the live
// seam (AGENTS.md §3). Upstream fires `run_update_if_available` NonBlocking
// after session readiness; this test drives `makeAgentStack` with a mocked
// release feed and asserts the notice reaches stderr and the fetch ran.

import Foundation
import Testing
import OpenGrokTestSupport
@testable import OpenGrokCLI
import OpenGrokUpdate

private actor LaunchUpdateCallCounter {
    private var fetches = 0
    private var installs = 0

    func recordFetch() { fetches += 1 }
    func recordInstall() { installs += 1 }
    func counts() -> (fetches: Int, installs: Int) { (fetches, installs) }
}

private func mockRelease(version: String) throws -> ReleaseCandidate {
    let platform = ReleasePlatform.current
    return try ReleaseCandidate(
        tagName: "v\(version)",
        version: version,
        assets: [
            ReleaseAsset(
                name: platform.assetName,
                downloadURL: URL(string: "https://example.com/\(platform.assetName)")!
            )
        ]
    )
}

@Suite("Live launch auto-update check", .serialized)
struct LiveLaunchAutoUpdateReachabilityTests {
    private func makeFixture(
        extraEnvironment: [String: String] = [:],
        configContents: String? = nil
    ) throws -> (
        home: URL,
        workspace: URL,
        environment: [String: String],
        dispose: () -> Void
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-launch-update-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        if let configContents {
            try configContents.write(
                to: home.appendingPathComponent("config.toml"),
                atomically: true,
                encoding: .utf8
            )
        }
        var environment: [String: String] = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "XDG_STATE_HOME": home.appendingPathComponent("state").path,
            "GROK_TEST_VERSION": "0.1.0",
            "OPENGROK_TEST_LAUNCH_UPDATE": "1",
            "XAI_API_KEY": "test-xai-key",
        ]
        for (key, value) in extraEnvironment { environment[key] = value }
        return (
            home,
            workspace,
            environment,
            { try? FileManager.default.removeItem(at: root) }
        )
    }

    private func launchOptions(workspace: URL, arguments: [String] = []) throws -> CLIExecutionOptions {
        let command = try CLICommandParser.parseOrThrow(
            ["headless", "--prompt", "hello", "--cwd", workspace.path] + arguments
        )
        guard case .launch(let options) = command else {
            throw CLIApplicationError.failed("fixture did not parse to a launch")
        }
        return options
    }

    private func makeStack(
        options: CLIExecutionOptions,
        environment: [String: String],
        services: LiveUpdateServices,
        err: BufferedStream
    ) async throws -> OpenGrokLiveApplicationLauncher.LiveAgentStack {
        let context = CLIApplicationContext(
            environment: environment,
            streams: CLIStreams(out: { _ in }, err: { string in err.write(string) }),
            control: .never
        )
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { _, _ in OpenGrokLiveSamplingResponse(output: "ok") }
            }
        )
        let foundation = try await OpenGrokLiveApplicationLauncher.makeSessionFoundation(
            options: options,
            context: context,
            dependencies: dependencies
        )
        return await OpenGrokLiveApplicationLauncher.makeAgentStack(
            foundation: foundation,
            context: context,
            dependencies: dependencies,
            launchAutoUpdate: LiveLaunchAutoUpdate.Request(
                noAutoUpdate: options.advanced.noAutoUpdate,
                services: services
            )
        )
    }

    @Test("post-readiness check surfaces update notice when a newer release exists")
    func updateNoticeReachesStderrAfterReadiness() async throws {
        let counter = LaunchUpdateCallCounter()
        let release = try mockRelease(version: "9.9.9")
        let services = LiveUpdateServices(
            fetchLatestRelease: { _ in
                await counter.recordFetch()
                return release
            },
            install: { _, _, _, _ in
                await counter.recordInstall()
                throw CLIApplicationError.failed("install stub")
            }
        )
        let fixture = try makeFixture()
        defer { fixture.dispose() }
        let err = BufferedStream()
        let options = try launchOptions(workspace: fixture.workspace)
        let stack = try await makeStack(
            options: options,
            environment: fixture.environment,
            services: services,
            err: err
        )

        #expect(stack.launchAutoUpdateTask != nil)
        await stack.launchAutoUpdateTask?.value

        let counts = await counter.counts()
        #expect(counts.fetches == 1)
        #expect(counts.installs == 1)
        #expect(err.contents.contains("A new version of Open Grok is available: 0.1.0 -> 9.9.9 [stable]"))
        await stack.codeMode?.shutdown()
    }

    @Test("--no-auto-update suppresses the launch check")
    func noAutoUpdateFlagSuppressesCheck() async throws {
        let counter = LaunchUpdateCallCounter()
        let release = try mockRelease(version: "9.9.9")
        let services = LiveUpdateServices(
            fetchLatestRelease: { _ in
                await counter.recordFetch()
                return release
            },
            install: { _, _, _, _ in
                await counter.recordInstall()
                throw CLIApplicationError.failed("install stub")
            }
        )
        let fixture = try makeFixture()
        defer { fixture.dispose() }
        let err = BufferedStream()
        let options = try launchOptions(workspace: fixture.workspace, arguments: ["--no-auto-update"])
        #expect(options.advanced.noAutoUpdate)
        let stack = try await makeStack(
            options: options,
            environment: fixture.environment,
            services: services,
            err: err
        )

        #expect(stack.launchAutoUpdateTask == nil)
        let counts = await counter.counts()
        #expect(counts.fetches == 0)
        #expect(err.contents.isEmpty)
        await stack.codeMode?.shutdown()
    }

    @Test("[cli] auto_update = false suppresses the launch check")
    func configAutoUpdateFalseSuppressesCheck() async throws {
        let counter = LaunchUpdateCallCounter()
        let release = try mockRelease(version: "9.9.9")
        let services = LiveUpdateServices(
            fetchLatestRelease: { _ in
                await counter.recordFetch()
                return release
            },
            install: { _, _, _, _ in
                await counter.recordInstall()
                throw CLIApplicationError.failed("install stub")
            }
        )
        let fixture = try makeFixture(configContents: """
            [cli]
            auto_update = false
            """)
        defer { fixture.dispose() }
        let err = BufferedStream()
        let options = try launchOptions(workspace: fixture.workspace)
        let stack = try await makeStack(
            options: options,
            environment: fixture.environment,
            services: services,
            err: err
        )

        #expect(stack.launchAutoUpdateTask != nil)
        await stack.launchAutoUpdateTask?.value
        let counts = await counter.counts()
        #expect(counts.fetches == 0)
        #expect(err.contents.isEmpty)
        await stack.codeMode?.shutdown()
    }

    @Test("version cache cadence suppresses a second launch check")
    func cadenceCacheSuppressesSecondCheck() async throws {
        let counter = LaunchUpdateCallCounter()
        let release = try mockRelease(version: "9.9.9")
        let services = LiveUpdateServices(
            fetchLatestRelease: { _ in
                await counter.recordFetch()
                return release
            },
            install: { _, _, _, _ in
                await counter.recordInstall()
                throw CLIApplicationError.failed("install stub")
            }
        )
        let fixture = try makeFixture()
        defer { fixture.dispose() }
        try await writeVersionCache(version: "9.9.9", environment: fixture.environment)
        let err = BufferedStream()
        let options = try launchOptions(workspace: fixture.workspace)
        let stack = try await makeStack(
            options: options,
            environment: fixture.environment,
            services: services,
            err: err
        )

        #expect(stack.launchAutoUpdateTask != nil)
        await stack.launchAutoUpdateTask?.value
        let counts = await counter.counts()
        #expect(counts.fetches == 0)
        #expect(err.contents.isEmpty)
        await stack.codeMode?.shutdown()
    }

    @Test("a failing release feed is silent and never breaks launch")
    func failingFeedIsSilent() async throws {
        let counter = LaunchUpdateCallCounter()
        let services = LiveUpdateServices(
            fetchLatestRelease: { _ in
                await counter.recordFetch()
                throw UpdateServiceError.releaseFetchFailed("network down")
            },
            install: { _, _, _, _ in
                await counter.recordInstall()
                throw CLIApplicationError.failed("install should not run")
            }
        )
        let fixture = try makeFixture()
        defer { fixture.dispose() }
        let err = BufferedStream()
        let options = try launchOptions(workspace: fixture.workspace)
        let stack = try await makeStack(
            options: options,
            environment: fixture.environment,
            services: services,
            err: err
        )

        #expect(stack.launchAutoUpdateTask != nil)
        await stack.launchAutoUpdateTask?.value
        let counts = await counter.counts()
        #expect(counts.fetches == 1)
        #expect(counts.installs == 0)
        #expect(err.contents.isEmpty)
        await stack.codeMode?.shutdown()
    }

    @Test("shouldCheckForUpdates honors env kill switches")
    func environmentKillSwitchSuppressesCheck() {
        #expect(!LiveLaunchAutoUpdate.shouldCheckForUpdates(
            noAutoUpdateFlag: false,
            environment: ["OPENGROK_DISABLE_AUTOUPDATER": "1"]
        ))
        #expect(!LiveLaunchAutoUpdate.shouldCheckForUpdates(
            noAutoUpdateFlag: false,
            environment: ["GROK_DISABLE_AUTOUPDATER": "yes"]
        ))
    }
}
