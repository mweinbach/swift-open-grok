import Foundation
import Testing
@testable import OpenGrokCLI

private final class WorkflowSamplerCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

@Suite("Live workflow kill switch")
struct LiveWorkflowKillSwitchTests {
    private func scratchDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-kill-switch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("workflow list refuses through the live launcher when disabled")
    func routeRefusesWhenDisabled() async throws {
        let home = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let (streams, _, error) = CLIStreams.buffered()

        let code = await CLIRunner.run(
            ["workflow", "list"],
            environment: [
                "HOME": home.path,
                "OPENGROK_HOME": home.path,
                "GROK_WORKFLOWS": "0",
            ],
            streams: streams,
            application: OpenGrokApplication.live(control: .never)
        )

        #expect(code == CLIRunner.ExitCode.failure.rawValue)
        #expect(error.contents.contains("workflows are disabled"))
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent("workflow-runs.json").path) == false)
    }

    @Test("disabled --workflow refuses before sampler construction")
    func launchRefusesBeforeSampler() async throws {
        let home = try scratchDirectory()
        let workspace = try scratchDirectory()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: workspace)
        }
        let counter = WorkflowSamplerCounter()
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                counter.increment()
                return OpenGrokLiveSampler { _, _ in
                    throw CLIApplicationError.failed("unexpected sampler use")
                }
            }
        )
        let (streams, _, error) = CLIStreams.buffered()

        let code = await CLIRunner.run(
            [
                "headless", "--prompt", "should not run",
                "--cwd", workspace.path,
                "--workflow", workspace.appendingPathComponent("missing.rhai").path,
            ],
            environment: [
                "HOME": home.path,
                "OPENGROK_HOME": home.path,
                "GROK_WORKFLOWS": "0",
            ],
            streams: streams,
            application: OpenGrokApplication.live(dependencies: dependencies, control: .never)
        )

        #expect(code == CLIRunner.ExitCode.failure.rawValue)
        #expect(error.contents.contains("workflows are disabled"))
        #expect(counter.value == 0)
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent("workflow-runs.json").path) == false)
    }
}
