import Foundation
import Testing
@testable import OpenGrokCLI

private func shareLauncherContext(home: URL, streams: CLIStreams) -> CLIApplicationContext {
    CLIApplicationContext(
        environment: ["OPENGROK_HOME": home.path],
        streams: streams,
        control: .never
    )
}

@Suite("share route is reachable from the launcher")
struct LiveShareLauncherReachabilityTests {
    @Test("parsed share reaches the live authorization refusal")
    func shareReachesLiveComposition() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-share-reachability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let command = try CLICommandParser.parseOrThrow(["share", "session-1"])
        let (streams, out, err) = CLIStreams.buffered()

        do {
            _ = try await OpenGrokLiveApplicationLauncher().launcher.start(
                command,
                shareLauncherContext(home: home, streams: streams)
            )
            Issue.record("expected the live share authorization gate to refuse")
        } catch let error as CLIApplicationError {
            #expect(error == .failed("Authentication required to share session"))
        } catch {
            Issue.record(
                "the launcher did not route `share` to LiveShareComposition: \(error)"
            )
        }

        #expect(out.contents.isEmpty)
        #expect(err.contents.isEmpty)
    }

    @Test("an unhooked utility remains unsupported")
    func unhookedUtilityRemainsUnsupported() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-share-negative-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let command = try CLICommandParser.parseOrThrow(["trace", "session-1"])
        let (streams, out, err) = CLIStreams.buffered()

        do {
            _ = try await OpenGrokLiveApplicationLauncher().launcher.start(
                command,
                shareLauncherContext(home: home, streams: streams)
            )
            Issue.record("expected the unhooked command to be refused")
        } catch let error as CLIApplicationError {
            #expect(error == .unsupported(route: "trace"))
        } catch {
            Issue.record("unexpected error for the negative control: \(error)")
        }

        #expect(out.contents.isEmpty)
        #expect(err.contents.isEmpty)
    }
}
