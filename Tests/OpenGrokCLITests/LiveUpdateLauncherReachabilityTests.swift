import Foundation
import Testing
@testable import OpenGrokCLI
import OpenGrokUpdate

private actor UpdateCallCounter {
    private var fetches = 0
    private var installs = 0

    func recordFetch() {
        fetches += 1
    }

    func recordInstall() {
        installs += 1
    }

    func counts() -> (fetches: Int, installs: Int) {
        (fetches, installs)
    }
}

@Suite("update route is reachable from the launcher")
struct LiveUpdateLauncherReachabilityTests {
    @Test("parsed update check reaches LiveUpdateComposition")
    func updateCheckReachesTheRoute() async throws {
        let counter = UpdateCallCounter()
        let release = try ReleaseCandidate(tagName: "v9.9.9", version: "9.9.9")
        let services = LiveUpdateServices(
            fetchLatestRelease: { _ in
                await counter.recordFetch()
                return release
            },
            install: { _, _, _, _ in
                await counter.recordInstall()
                throw CLIApplicationError.failed("install should not run during --check")
            }
        )
        let (streams, out, err) = CLIStreams.buffered()
        let application = OpenGrokApplication(
            launcher: OpenGrokLiveApplicationLauncher(updateServices: services).launcher,
            control: .never
        )

        let exitCode = await CLIRunner.run(
            ["update", "--check", "--json"],
            environment: ["GROK_TEST_VERSION": "0.1.0"],
            streams: streams,
            application: application
        )

        #expect(exitCode == CLIRunner.ExitCode.success.rawValue)
        #expect(err.contents.isEmpty)
        let status = try JSONDecoder().decode(
            UpdateStatus.self,
            from: Data(out.contents.utf8)
        )
        #expect(status.latestVersion == "9.9.9")
        #expect(status.updateAvailable)
        #expect(status.error == nil)

        let counts = await counter.counts()
        #expect(counts.fetches == 1)
        #expect(counts.installs == 0)
    }
}
