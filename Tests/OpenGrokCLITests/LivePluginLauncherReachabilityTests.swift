import Foundation
import Testing
@testable import OpenGrokCLI

private func pluginLauncherContext(
    home: URL,
    streams: CLIStreams
) -> CLIApplicationContext {
    CLIApplicationContext(
        environment: ["OPENGROK_HOME": home.path],
        streams: streams,
        control: .never
    )
}

@Suite("plugin route is reachable from the launcher")
struct LivePluginLauncherReachabilityTests {
    @Test("parsed plugin list reaches LivePluginComposition")
    func pluginListReachesTheRoute() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-plugin-reachability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let command = try CLICommandParser.parseOrThrow(["plugin", "list"])
        let (streams, out, err) = CLIStreams.buffered()
        let session = try await OpenGrokLiveApplicationLauncher().launcher.start(
            command,
            pluginLauncherContext(home: home, streams: streams)
        )
        try await session.waitForExit()
        await session.shutdown()

        #expect(out.contents == "No plugins installed.\n")
        #expect(err.contents.isEmpty)
    }

    @Test("a non-plugin command does not reach the plugin handler")
    func nonPluginCommandRemainsUnclaimed() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-plugin-negative-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let command = try CLICommandParser.parseOrThrow(["trace", "--local"])
        let (streams, out, err) = CLIStreams.buffered()

        do {
            _ = try await OpenGrokLiveApplicationLauncher().launcher.start(
                command,
                pluginLauncherContext(home: home, streams: streams)
            )
            Issue.record("expected the unhooked command to be refused")
        } catch let error as CLIApplicationError {
            #expect(error == .unsupported(route: "trace"))
        }

        #expect(out.contents.isEmpty)
        #expect(err.contents.isEmpty)
    }
}
