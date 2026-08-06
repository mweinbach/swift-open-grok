import Foundation
import OpenGrokSamplingTypes
import Testing
@testable import OpenGrokCLI

private final class LiveWebToolSamplingRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [OpenGrokLiveSamplingRequest] = []

    func record(_ request: OpenGrokLiveSamplingRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }

    var firstRequest: OpenGrokLiveSamplingRequest? {
        lock.lock()
        defer { lock.unlock() }
        return requests.first
    }
}

@Suite("live web-tool launch reachability")
struct LiveWebToolLaunchReachabilityTests {
    @Test("--disable-web-search launches and hides search without hiding fetch")
    func disableWebSearchReachesLiveToolSurface() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-web-tools-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let recorder = LiveWebToolSamplingRecorder()
        let application = OpenGrokApplication.live(
            dependencies: OpenGrokLiveCompositionDependencies(
                makeSampler: { _ in
                    OpenGrokLiveSampler { request, emit in
                        recorder.record(request)
                        await emit(.output("search disabled"))
                        return OpenGrokLiveSamplingResponse(
                            output: "search disabled",
                            stopReason: "stop"
                        )
                    }
                }
            ),
            control: .never
        )
        let (streams, _, err) = CLIStreams.buffered()
        let home = root.appendingPathComponent("home")
        let environment = [
            "HOME": home.path,
            "OPENGROK_HOME": root.appendingPathComponent("state").path,
            "XAI_API_KEY": "test-xai-key",
        ]

        let code = await CLIRunner.run(
            [
                "headless",
                "--disable-web-search",
                "--prompt", "verify web tool reachability",
                "--cwd", root.path,
            ],
            environment: environment,
            streams: streams,
            application: application
        )

        let names = Set(recorder.firstRequest?.tools.map(\.name) ?? [])
        #expect(code == CLIRunner.ExitCode.success.rawValue)
        #expect(!err.contents.contains("--disable-web-search"))
        #expect(recorder.firstRequest != nil)
        #expect(!names.contains("web_search"))
        #expect(!names.contains("x_search"))
        #expect(names.contains("web_fetch"))
    }
}
