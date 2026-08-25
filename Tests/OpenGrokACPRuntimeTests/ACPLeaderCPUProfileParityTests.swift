import Foundation
import OpenGrokACP
import OpenGrokHTTP
import Testing

@testable import OpenGrokACPRuntime

private final class CPUProfileBackendProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0
    private var frequencies: [Int32] = []
    private var stopGate: DispatchSemaphore?
    var escapeRoot = false
    var samples: UInt64 = 3
    var stopFailure: ACPLeaderControlError?

    var startCount: Int { lock.withLock { starts } }
    var stopCount: Int { lock.withLock { stops } }
    var observedFrequencies: [Int32] { lock.withLock { frequencies } }

    func blockNextStop() {
        lock.withLock { stopGate = DispatchSemaphore(value: 0) }
    }

    func releaseStop() {
        lock.withLock { stopGate?.signal() }
    }

    func backend(supported: Bool = true) -> ACPLeaderCPUProfiler.Backend {
        ACPLeaderCPUProfiler.Backend(
            isSupported: supported,
            start: { [self] home, output, frequency in
                lock.withLock {
                    starts += 1
                    frequencies.append(frequency)
                }
                let directory = escapeRoot
                    ? URL(fileURLWithPath: home).deletingLastPathComponent()
                    : URL(fileURLWithPath: home).appendingPathComponent("profiles")
                return directory.appendingPathComponent(output ?? "mock.folded").path
            },
            stop: { [self] in
                let gate = lock.withLock { () -> DispatchSemaphore? in
                    stops += 1
                    return stopGate
                }
                if let gate, gate.wait(timeout: .now() + .seconds(3)) == .timedOut {
                    throw ACPLeaderControlError(
                        code: ACPLeaderControlErrorCode.internalError,
                        message: "mock CPU profile finalization timed out"
                    )
                }
                if let stopFailure { throw stopFailure }
                return samples
            }
        )
    }
}

private struct CPUProfilePromptDriver: ACPPromptDriver {
    func run(
        context: ACPPromptContext,
        emit: @escaping @Sendable (SessionNotification, ACPNotificationDisposition) async -> Void
    ) async throws -> PromptResponse {
        _ = (context, emit)
        return PromptResponse(stopReason: .endTurn)
    }

    func cancel(sessionId: AcpSessionId) async {
        _ = sessionId
    }
}

private actor CPUProfileWireClient {
    private let channel: InMemoryWebSocketChannel
    private let reader: ACPLeaderChannelReader

    init(channel: InMemoryWebSocketChannel) {
        self.channel = channel
        self.reader = ACPLeaderChannelReader(
            channel: channel,
            maximumMessageSize: ACPLeaderProtocolLimits.maximumMessageSize
        )
    }

    func send(_ message: ACPLeaderClientMessage) async throws {
        try await channel.write(try ACPLeaderCodec.encode(message))
    }

    func next() async throws -> ACPLeaderServerMessage {
        let timeout = Task { [channel] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await channel.close()
        }
        defer { timeout.cancel() }
        guard let message = try await reader.next(ACPLeaderServerMessage.self) else {
            throw ACPLeaderProtocolError.connectionClosed
        }
        return message
    }

    func close() async {
        await channel.close()
    }
}

@Suite("Leader runtime CPU profiling Rust parity", .serialized)
struct ACPLeaderCPUProfileParityTests {
    private let timestamp = "20260825T120000.123456Z"

    private func makeHome() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-cpu-profile-\(UUID().uuidString)")
        #if os(Windows)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        #else
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        #endif
        return directory
    }

    private func mockProfiler(
        home: URL,
        probe: CPUProfileBackendProbe,
        supported: Bool = true
    ) -> ACPLeaderCPUProfiler {
        ACPLeaderCPUProfiler(
            openGrokHome: home,
            backend: probe.backend(supported: supported),
            now: { "20260825T120000.123456Z" }
        )
    }

    private func expectFailure(
        _ outcome: ACPLeaderControlOutcome,
        code expectedCode: Int
    ) {
        guard case .failure(let actualCode, _) = outcome else {
            Issue.record("expected control failure \(expectedCode), got \(outcome)")
            return
        }
        #expect(actualCode == expectedCode)
    }

    private func waitUntilStopping(_ profiler: ACPLeaderCPUProfiler) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !profiler.status().stopping && ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(profiler.status().stopping)
    }

    @Test("cpu_profile_started exactly matches the pinned Rust payload")
    func startedWireGolden() throws {
        let payload = ACPLeaderControlPayload.cpuProfileStarted(
            ACPLeaderCpuProfileStarted(
                pid: 4242,
                svgPath: "/private/home/profiles/leader.folded",
                frequencyHz: 1000,
                startedAt: timestamp
            )
        )
        let bytes = try ACPLeaderCodec.encode(payload)
        #expect(
            String(decoding: bytes.dropFirst(4), as: UTF8.self)
                == #"{"frequency_hz":1000,"pid":4242,"started_at":"20260825T120000.123456Z","svg_path":"/private/home/profiles/leader.folded","type":"cpu_profile_started"}"#
        )
        #expect(
            try ACPLeaderCodec.decode(ACPLeaderControlPayload.self, from: Array(bytes.dropFirst(4)))
                == payload
        )
    }

    @Test("cpu_profile_stopped exactly matches the pinned Rust payload")
    func stoppedWireGolden() throws {
        let payload = ACPLeaderControlPayload.cpuProfileStopped(
            ACPLeaderCpuProfileStopped(
                pid: 4242,
                svgPath: "/private/home/profiles/leader.folded",
                startedAt: timestamp,
                stoppedAt: "20260825T120001.654321Z"
            )
        )
        let bytes = try ACPLeaderCodec.encode(payload)
        #expect(
            String(decoding: bytes.dropFirst(4), as: UTF8.self)
                == #"{"pid":4242,"started_at":"20260825T120000.123456Z","stopped_at":"20260825T120001.654321Z","svg_path":"/private/home/profiles/leader.folded","type":"cpu_profile_stopped"}"#
        )
        #expect(
            try ACPLeaderCodec.decode(ACPLeaderControlPayload.self, from: Array(bytes.dropFirst(4)))
                == payload
        )
    }

    @Test("profile payloads reject absent required fields")
    func profilePayloadsRequireEveryRustField() {
        for malformed in [
            #"{"type":"cpu_profile_started","pid":1,"svg_path":"p","started_at":"t"}"#,
            #"{"type":"cpu_profile_stopped","pid":1,"svg_path":"p","started_at":"t"}"#,
        ] {
            #expect(throws: (any Error).self) {
                try ACPLeaderCodec.decode(
                    ACPLeaderControlPayload.self,
                    from: Array(malformed.utf8)
                )
            }
        }
    }

    @Test("constructing the production profiler never creates state")
    func constructorDoesNotCreateHomeOrProfiles() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-cpu-missing-\(UUID().uuidString)")
        let profiler = ACPLeaderCPUProfiler(openGrokHome: missing)
        _ = profiler.isSupported
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test("uninjected and unavailable profilers refuse starts and stops")
    func unsupportedBackendsFailClosed() async throws {
        let plain = ACPLeaderControlPlane()
        expectFailure(
            await plain.run(["type": "start_cpu_profile"]),
            code: ACPLeaderControlErrorCode.unsupportedCommand
        )
        expectFailure(
            await plain.run(["type": "stop_cpu_profile"]),
            code: ACPLeaderControlErrorCode.unsupportedCommand
        )

        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let probe = CPUProfileBackendProbe()
        let unavailable = mockProfiler(home: home, probe: probe, supported: false)
        let plane = ACPLeaderControlPlane(profiler: unavailable)
        expectFailure(
            await plane.run(["type": "start_cpu_profile"]),
            code: ACPLeaderControlErrorCode.unsupportedCommand
        )
        #expect(probe.startCount == 0)
        #expect(!unavailable.isSupported)
    }

    @Test("metadata alone cannot claim an uninjected profiling capability")
    func metadataCannotInventCapability() async {
        let plane = ACPLeaderControlPlane(
            metadata: ACPLeaderControlMetadata(
                profilingSupported: true,
                profilingCompiledIn: true,
                profileFormats: ["folded"]
            )
        )
        guard case .success(.leaderInfo(let info)) = await plane.run(["type": "get_leader_info"])
        else {
            Issue.record("leader_info was not returned")
            return
        }
        #expect(!info.profilingSupported)
        #expect(!info.profilingCompiledIn)
        #expect(info.profileFormats.isEmpty)
    }

    @Test("frequency validation rejects out-of-range values before native start")
    func invalidFrequenciesNeverReachBackend() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let probe = CPUProfileBackendProbe()
        let plane = ACPLeaderControlPlane(profiler: mockProfiler(home: home, probe: probe))

        for frequency in [Int.min, -1, 0, 4_001, Int.max] {
            expectFailure(
                await plane.run(["type": "start_cpu_profile", "frequency_hz": String(frequency)]),
                code: ACPLeaderControlErrorCode.invalidFrequency
            )
        }
        #expect(probe.startCount == 0)
    }

    @Test("frequency defaults to 1000 and includes both Rust boundaries")
    func defaultAndBoundaryFrequencies() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let probe = CPUProfileBackendProbe()
        let profiler = mockProfiler(home: home, probe: probe)

        for frequency in [nil, 1, 4_000] as [Int?] {
            let started = try profiler.start(pid: 7, output: nil, frequencyHz: frequency)
            #expect(started.frequencyHz == Int32(frequency ?? 1_000))
            let stopped = try await profiler.stop(pid: 7)
            #expect(stopped.svgPath == started.svgPath)
        }
        #expect(probe.observedFrequencies == [1_000, 1, 4_000])
    }

    @Test("remote output paths cannot escape the private profiles root")
    func hostileOutputNamesNeverReachBackend() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let probe = CPUProfileBackendProbe()
        let plane = ACPLeaderControlPlane(profiler: mockProfiler(home: home, probe: probe))

        let hostile = [
            "/tmp/foreign.folded",
            "../foreign.folded",
            "nested/foreign.folded",
            "nested\\foreign.folded",
            ".",
            "..",
            "name with spaces.folded",
            "name:stream.folded",
            "safe\0foreign.folded",
            String(repeating: "a", count: 256),
        ]
        for output in hostile {
            expectFailure(
                await plane.run(["type": "start_cpu_profile", "output": output]),
                code: ACPLeaderControlErrorCode.artifactWriteFailed
            )
        }
        #expect(probe.startCount == 0)
    }

    @Test("a missing root is rejected without creating it")
    func missingHomeFailsClosed() async {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-cpu-absent-\(UUID().uuidString)")
        let probe = CPUProfileBackendProbe()
        let plane = ACPLeaderControlPlane(profiler: mockProfiler(home: home, probe: probe))
        expectFailure(
            await plane.run(["type": "start_cpu_profile"]),
            code: ACPLeaderControlErrorCode.artifactWriteFailed
        )
        #expect(probe.startCount == 0)
        #expect(!FileManager.default.fileExists(atPath: home.path))
    }

    @Test("an escaped backend artifact is refused and its reservation is released")
    func backendArtifactEscapeFailsClosed() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let probe = CPUProfileBackendProbe()
        probe.escapeRoot = true
        let profiler = mockProfiler(home: home, probe: probe)
        let plane = ACPLeaderControlPlane(profiler: profiler)
        expectFailure(
            await plane.run(["type": "start_cpu_profile"]),
            code: ACPLeaderControlErrorCode.artifactWriteFailed
        )
        #expect(probe.startCount == 1)
        #expect(probe.stopCount == 1)
        #expect(!profiler.status().active)
    }

    @Test("a second start is declined without replacing the active profile")
    func duplicateStartPreservesOriginal() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let probe = CPUProfileBackendProbe()
        let profiler = mockProfiler(home: home, probe: probe)
        let first = try profiler.start(pid: 7, output: "first.folded", frequencyHz: 250)
        let plane = ACPLeaderControlPlane(profiler: profiler)

        expectFailure(
            await plane.run([
                "type": "start_cpu_profile", "output": "second.folded", "frequency_hz": "500",
            ]),
            code: ACPLeaderControlErrorCode.profileAlreadyActive
        )
        #expect(profiler.status().svgPath == first.svgPath)
        #expect(probe.startCount == 1)
        _ = try await profiler.stop(pid: 7)
    }

    @Test("stop with no active profile returns the exact typed failure")
    func stoppingInactiveProfileIsTyped() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let probe = CPUProfileBackendProbe()
        let plane = ACPLeaderControlPlane(profiler: mockProfiler(home: home, probe: probe))
        expectFailure(
            await plane.run(["type": "stop_cpu_profile"]),
            code: ACPLeaderControlErrorCode.profileNotActive
        )
        #expect(probe.stopCount == 0)
    }

    @Test("status and leader info expose the real active lifecycle")
    func activeStatusAndLeaderInfo() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let probe = CPUProfileBackendProbe()
        let profiler = mockProfiler(home: home, probe: probe)
        let plane = ACPLeaderControlPlane(
            metadata: ACPLeaderControlMetadata(pid: 42),
            profiler: profiler
        )
        let outcome = await plane.run([
            "type": "start_cpu_profile", "output": "active.folded", "frequency_hz": "250",
        ])
        guard case .success(.cpuProfileStarted(let started)) = outcome else {
            Issue.record("expected cpu_profile_started, got \(outcome)")
            return
        }
        #expect(started.pid == 42)
        #expect(started.startedAt == timestamp)
        #expect(started.frequencyHz == 250)

        guard case .success(.cpuProfileStatus(let status)) = await plane.run([
            "type": "cpu_profile_status",
        ]) else {
            Issue.record("expected active cpu_profile_status")
            return
        }
        #expect(status.active)
        #expect(!status.stopping)
        #expect(status.startedAt == timestamp)
        #expect(status.svgPath == started.svgPath)

        guard case .success(.leaderInfo(let info)) = await plane.run(["type": "get_leader_info"])
        else {
            Issue.record("expected leader_info")
            return
        }
        #expect(info.profilingSupported)
        #expect(info.profilingCompiledIn)
        #expect(info.cpuProfileActive)
        #expect(!info.cpuProfileStopping)
        #expect(info.profileStartedAt == timestamp)
        #expect(info.profileFormats.isEmpty)

        guard case .success(.cpuProfileStopped(let stopped)) = await plane.run([
            "type": "stop_cpu_profile",
        ]) else {
            Issue.record("expected cpu_profile_stopped")
            return
        }
        #expect(stopped.pid == 42)
        #expect(stopped.svgPath == started.svgPath)
        #expect(!profiler.status().active)
    }

    @Test("in-flight stop stays observable and rejects duplicate starts and stops")
    func stoppingLifecycleAndBusyErrors() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let probe = CPUProfileBackendProbe()
        probe.blockNextStop()
        defer { probe.releaseStop() }
        let profiler = mockProfiler(home: home, probe: probe)
        let plane = ACPLeaderControlPlane(profiler: profiler)
        _ = try profiler.start(pid: 9, output: "blocked.folded", frequencyHz: 250)

        let firstStop = Task { await plane.run(["type": "stop_cpu_profile"]) }
        try await waitUntilStopping(profiler)

        let stopping = profiler.status()
        #expect(!stopping.active)
        #expect(stopping.stopping)
        #expect(stopping.startedAt == timestamp)
        #expect(stopping.frequencyHz == 250)

        guard case .success(.leaderInfo(let info)) = await plane.run(["type": "get_leader_info"])
        else {
            Issue.record("leader_info blocked behind CPU profile finalization")
            return
        }
        #expect(!info.cpuProfileActive)
        #expect(info.cpuProfileStopping)
        #expect(info.profileStartedAt == timestamp)
        expectFailure(
            await plane.run(["type": "start_cpu_profile"]),
            code: ACPLeaderControlErrorCode.profileStopInProgress
        )
        expectFailure(
            await plane.run(["type": "stop_cpu_profile"]),
            code: ACPLeaderControlErrorCode.profileStopInProgress
        )

        probe.releaseStop()
        guard case .success(.cpuProfileStopped) = await firstStop.value else {
            Issue.record("first stop did not complete")
            return
        }
        #expect(!profiler.status().active)
        #expect(!profiler.status().stopping)
        #expect(probe.stopCount == 1)
    }

    @Test("failed finalization clears stopping and never reports an empty artifact")
    func failedAndEmptyFinalizationRecover() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let failed = CPUProfileBackendProbe()
        failed.stopFailure = ACPLeaderControlError(
            code: ACPLeaderControlErrorCode.artifactWriteFailed,
            message: "artifact write failed"
        )
        let failedProfiler = mockProfiler(home: home, probe: failed)
        let failedPlane = ACPLeaderControlPlane(profiler: failedProfiler)
        _ = try failedProfiler.start(pid: 1, output: nil, frequencyHz: nil)
        expectFailure(
            await failedPlane.run(["type": "stop_cpu_profile"]),
            code: ACPLeaderControlErrorCode.artifactWriteFailed
        )
        #expect(!failedProfiler.status().stopping)

        let empty = CPUProfileBackendProbe()
        empty.samples = 0
        let emptyProfiler = mockProfiler(home: home, probe: empty)
        let emptyPlane = ACPLeaderControlPlane(profiler: emptyProfiler)
        _ = try emptyProfiler.start(pid: 1, output: nil, frequencyHz: nil)
        expectFailure(
            await emptyPlane.run(["type": "stop_cpu_profile"]),
            code: ACPLeaderControlErrorCode.artifactWriteFailed
        )
        #expect(!emptyProfiler.status().active)
        #expect(!emptyProfiler.status().stopping)
    }

    @Test("shutdown finalizes active profiles and joins in-flight stops")
    func shutdownFinalization() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let activeProbe = CPUProfileBackendProbe()
        let activeProfiler = mockProfiler(home: home, probe: activeProbe)
        _ = try activeProfiler.start(pid: 1, output: nil, frequencyHz: nil)
        await ACPLeaderControlPlane(profiler: activeProfiler).finalize()
        #expect(activeProbe.stopCount == 1)
        #expect(!activeProfiler.status().active)

        let stoppingProbe = CPUProfileBackendProbe()
        stoppingProbe.blockNextStop()
        defer { stoppingProbe.releaseStop() }
        let stoppingProfiler = mockProfiler(home: home, probe: stoppingProbe)
        _ = try stoppingProfiler.start(pid: 1, output: nil, frequencyHz: nil)
        let first = Task { try await stoppingProfiler.stop(pid: 1) }
        try await waitUntilStopping(stoppingProfiler)
        let finalization = Task { await stoppingProfiler.finalize() }
        stoppingProbe.releaseStop()
        _ = try await first.value
        await finalization.value
        #expect(stoppingProbe.stopCount == 1)
        #expect(!stoppingProfiler.status().stopping)
    }

    @Test("registration and all control replies traverse the real leader IPC host")
    func genuineInMemoryLeaderSeam() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let probe = CPUProfileBackendProbe()
        let profiler = mockProfiler(home: home, probe: probe)
        let plane = ACPLeaderControlPlane(
            metadata: ACPLeaderControlMetadata(pid: 77),
            profiler: profiler
        )
        let host = ACPLeaderIPCHost(
            runtime: ACPAgentRuntime(promptDriver: CPUProfilePromptDriver()),
            configuration: ACPLeaderIPCConfiguration(
                capabilities: ACPLeaderCapabilities(
                    controlV1: true,
                    runtimeCPUProfile: profiler.isSupported,
                    profileFormats: [],
                    workspaceExposure: true,
                    relaunchV1: true
                ),
                controlPlane: plane
            )
        )
        let channels = InMemoryWebSocketChannel.makePair()
        let served = Task { await host.serve(channel: channels.a) }
        defer { served.cancel() }
        let client = CPUProfileWireClient(channel: channels.b)

        try await client.send(
            .register(
                clientType: "grok-profile-cli",
                mode: .stdio,
                capabilities: ACPLeaderClientCapabilities()
            )
        )
        guard case .registered(_, _, _, _, let capabilities) = try await client.next() else {
            Issue.record("client did not register")
            return
        }
        #expect(capabilities?.runtimeCPUProfile == true)
        #expect(capabilities?.profileFormats.isEmpty == true)

        try await client.send(
            .control(
                requestID: "start",
                command: ["type": "start_cpu_profile", "frequency_hz": "250"]
            )
        )
        guard case .controlResult("start", .cpuProfileStarted(let started)) = try await client.next()
        else {
            Issue.record("leader did not return cpu_profile_started")
            return
        }
        #expect(started.pid == 77)

        try await client.send(.control(requestID: "status", command: ["type": "cpu_profile_status"]))
        guard case .controlResult("status", .cpuProfileStatus(let status)) = try await client.next()
        else {
            Issue.record("leader did not return cpu_profile_status")
            return
        }
        #expect(status.active)

        try await client.send(.control(requestID: "stop", command: ["type": "stop_cpu_profile"]))
        guard case .controlResult("stop", .cpuProfileStopped(let stopped)) = try await client.next()
        else {
            Issue.record("leader did not return cpu_profile_stopped")
            return
        }
        #expect(stopped.svgPath == started.svgPath)
        #expect(probe.startCount == 1)
        #expect(probe.stopCount == 1)
        await host.stop()
        await client.close()
    }

    #if !os(Windows)
    @Test("a symlink in the final home component cannot redirect profiling")
    func finalHomeSymlinkIsRejected() async throws {
        let realHome = try makeHome()
        defer { try? FileManager.default.removeItem(at: realHome) }
        let alias = realHome.deletingLastPathComponent()
            .appendingPathComponent("opengrok-cpu-alias-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: realHome)
        defer { try? FileManager.default.removeItem(at: alias) }

        let probe = CPUProfileBackendProbe()
        let plane = ACPLeaderControlPlane(profiler: mockProfiler(home: alias, probe: probe))
        expectFailure(
            await plane.run(["type": "start_cpu_profile"]),
            code: ACPLeaderControlErrorCode.artifactWriteFailed
        )
        #expect(probe.startCount == 0)
        #expect(!FileManager.default.fileExists(atPath: realHome.appendingPathComponent("profiles").path))
    }
    #endif

    #if (os(macOS) || os(Linux)) && (arch(x86_64) || arch(arm64))
    private func burnRealCPU() {
        let deadline = DispatchTime.now().uptimeNanoseconds + 180_000_000
        var accumulator: UInt64 = 0x9e3779b97f4a7c15
        repeat {
            for index in 0..<512 {
                accumulator = (accumulator &* 6364136223846793005)
                    &+ UInt64(index)
                accumulator ^= accumulator >> 17
            }
        } while DispatchTime.now().uptimeNanoseconds < deadline
        withExtendedLifetime(accumulator) {}
    }

    @Test("the native profiler captures genuine folded stacks into owner-private state")
    func nativeSamplerProducesRealPrivateArtifact() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let profiler = ACPLeaderCPUProfiler(openGrokHome: home)
        guard profiler.isSupported else {
            Issue.record("native CPU sampler is unavailable on a supported Unix architecture")
            return
        }

        let started = try profiler.start(pid: 123, output: "genuine.svg", frequencyHz: 1_000)
        #expect(started.svgPath.hasSuffix("/profiles/genuine.folded"))
        burnRealCPU()
        let stopped = try await profiler.stop(pid: 123)
        #expect(stopped.svgPath == started.svgPath)
        #expect(!profiler.status().active)

        let artifact = URL(fileURLWithPath: stopped.svgPath)
        let contents = try String(contentsOf: artifact, encoding: .utf8)
        let lines = contents.split(whereSeparator: \.isNewline)
        #expect(!lines.isEmpty)
        for line in lines {
            let fields = line.split(separator: " ")
            #expect(fields.count == 2)
            #expect((Int(fields.last ?? "") ?? 0) > 0)
            #expect(!(fields.first ?? "").isEmpty)
        }

        let artifactAttributes = try FileManager.default.attributesOfItem(atPath: artifact.path)
        let profileAttributes = try FileManager.default.attributesOfItem(
            atPath: artifact.deletingLastPathComponent().path
        )
        #expect((artifactAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((profileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(artifact.deletingLastPathComponent().deletingLastPathComponent().path
            == home.resolvingSymlinksInPath().path)
    }

    @Test("native start never overwrites a preexisting artifact")
    func nativeArtifactCollisionFailsClosed() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let profiles = home.appendingPathComponent("profiles")
        try FileManager.default.createDirectory(
            at: profiles,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        let existing = profiles.appendingPathComponent("existing.folded")
        try Data("untouched".utf8).write(to: existing)
        let profiler = ACPLeaderCPUProfiler(openGrokHome: home)
        let plane = ACPLeaderControlPlane(profiler: profiler)

        expectFailure(
            await plane.run(["type": "start_cpu_profile", "output": "existing.folded"]),
            code: ACPLeaderControlErrorCode.outputPathCollision
        )
        #expect(try String(contentsOf: existing, encoding: .utf8) == "untouched")
        #expect(!profiler.status().active)
    }

    @Test("native start rejects a public home and a redirected profiles directory")
    func nativeUnsafeDirectoriesFailClosed() async throws {
        let publicHome = try makeHome()
        defer { try? FileManager.default.removeItem(at: publicHome) }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: publicHome.path
        )
        let publicPlane = ACPLeaderControlPlane(
            profiler: ACPLeaderCPUProfiler(openGrokHome: publicHome)
        )
        expectFailure(
            await publicPlane.run(["type": "start_cpu_profile"]),
            code: ACPLeaderControlErrorCode.artifactWriteFailed
        )

        let privateHome = try makeHome()
        defer { try? FileManager.default.removeItem(at: privateHome) }
        let foreign = try makeHome()
        defer { try? FileManager.default.removeItem(at: foreign) }
        try FileManager.default.createSymbolicLink(
            at: privateHome.appendingPathComponent("profiles"),
            withDestinationURL: foreign
        )
        let redirectedPlane = ACPLeaderControlPlane(
            profiler: ACPLeaderCPUProfiler(openGrokHome: privateHome)
        )
        expectFailure(
            await redirectedPlane.run(["type": "start_cpu_profile"]),
            code: ACPLeaderControlErrorCode.artifactWriteFailed
        )
        #expect(try FileManager.default.contentsOfDirectory(atPath: foreign.path).isEmpty)
    }

    @Test("a post-start hardlink alias prevents unsafe artifact finalization")
    func nativeHardlinkReplacementFailsClosed() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let profiler = ACPLeaderCPUProfiler(openGrokHome: home)
        let started = try profiler.start(pid: 7, output: "tampered.folded", frequencyHz: 1_000)
        let artifact = URL(fileURLWithPath: started.svgPath)
        let alias = home.appendingPathComponent("unexpected-alias.folded")
        try FileManager.default.linkItem(at: artifact, to: alias)
        burnRealCPU()

        let plane = ACPLeaderControlPlane(profiler: profiler)
        expectFailure(
            await plane.run(["type": "stop_cpu_profile"]),
            code: ACPLeaderControlErrorCode.artifactWriteFailed
        )
        #expect(!profiler.status().active)
        #expect(!profiler.status().stopping)
    }
    #endif
}
