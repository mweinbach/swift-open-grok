import Foundation
import OpenGrokACPRuntime
import OpenGrokHTTP
import Testing

@testable import OpenGrokCLI

@Suite("Live leader CPU profiling composition", .serialized)
struct LiveLeaderCPUProfileParityTests {
    @Test("the production leader advertises and executes only its genuine native profiler")
    func productionLeaderRunsRealOwnerPrivateProfiling() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-live-profile-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        #if !os(Windows)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: home.path
        )
        #endif
        defer { try? FileManager.default.removeItem(at: home) }

        let configuration = LiveLeaderComposition.productionIPCConfiguration(
            paths: (
                socket: home.appendingPathComponent("leader.sock"),
                lock: home.appendingPathComponent("leader.lock")
            ),
            relayURL: "wss://relay.example/ws",
            environment: ["OPENGROK_HOME": home.path],
            productionExposureConnector: { _, _ in
                throw CLIApplicationError.failed("workspace exposure was not requested")
            }
        )

        #if os(Windows)
        #expect(!configuration.capabilities.runtimeCPUProfile)
        let plane = try #require(configuration.controlPlane)
        let result = await plane.run(["type": "start_cpu_profile"])
        guard case .failure(let code, _) = result else {
            Issue.record("Windows advertised or started an unsupported CPU profiler")
            return
        }
        #expect(code == ACPLeaderControlErrorCode.unsupportedCommand)
        #else
        #expect(configuration.capabilities.runtimeCPUProfile)
        #expect(configuration.capabilities.profileFormats.isEmpty)

        let host = ACPLeaderIPCHost(runtime: ACPAgentRuntime(), configuration: configuration)
        let pair = InMemoryWebSocketChannel.makePair()
        let served = Task { await host.serve(channel: pair.a) }
        let deadline = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            await pair.b.close()
        }
        defer {
            deadline.cancel()
            served.cancel()
            Task {
                await host.stop()
                await pair.b.close()
            }
        }

        let reader = ACPLeaderChannelReader(
            channel: pair.b,
            maximumMessageSize: ACPLeaderProtocolLimits.maximumMessageSize
        )
        try await pair.b.write(try ACPLeaderCodec.encode(ACPLeaderClientMessage.register(
            clientType: "live-cpu-profile-regression",
            mode: .stdio,
            capabilities: ACPLeaderClientCapabilities()
        )))
        let registration = try #require(try await reader.next(ACPLeaderServerMessage.self))
        guard case .registered(_, _, _, _, let advertised) = registration else {
            Issue.record("production leader did not register its profiling client")
            return
        }
        #expect(advertised?.runtimeCPUProfile == true)
        #expect(advertised?.profileFormats.isEmpty == true)

        try await pair.b.write(try ACPLeaderCodec.encode(ACPLeaderClientMessage.control(
            requestID: "live-profile-start",
            command: ["type": "start_cpu_profile", "frequency_hz": "1000"]
        )))
        let startedMessage = try #require(try await reader.next(ACPLeaderServerMessage.self))
        guard case .controlResult(
            "live-profile-start",
            .cpuProfileStarted(let started)
        ) = startedMessage else {
            Issue.record("production leader failed to start genuine native CPU profiling")
            return
        }
        #expect(started.frequencyHz == 1_000)

        var accumulator: UInt64 = 1
        let samplingDeadline = DispatchTime.now().uptimeNanoseconds + 250_000_000
        while DispatchTime.now().uptimeNanoseconds < samplingDeadline {
            for value in UInt64(1)...256 {
                accumulator = accumulator &* 1_664_525 &+ value
            }
        }
        #expect(accumulator != 0)

        try await pair.b.write(try ACPLeaderCodec.encode(ACPLeaderClientMessage.control(
            requestID: "live-profile-stop",
            command: ["type": "stop_cpu_profile"]
        )))
        let stoppedMessage = try #require(try await reader.next(ACPLeaderServerMessage.self))
        guard case .controlResult(
            "live-profile-stop",
            .cpuProfileStopped(let stopped)
        ) = stoppedMessage else {
            Issue.record("production leader failed to finalize its genuine CPU samples")
            return
        }
        #expect(stopped.svgPath == started.svgPath)
        let artifact = URL(fileURLWithPath: stopped.svgPath)
        #expect(artifact.deletingLastPathComponent().lastPathComponent == "profiles")
        #expect(artifact.deletingLastPathComponent().deletingLastPathComponent()
            .resolvingSymlinksInPath() == home.resolvingSymlinksInPath())
        let contents = try String(contentsOf: artifact, encoding: .utf8)
        #expect(!contents.isEmpty)
        #expect(contents.contains(";"))
        let attributes = try FileManager.default.attributesOfItem(atPath: artifact.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o600)

        await pair.b.close()
        await host.stop()
        #endif
    }
}
