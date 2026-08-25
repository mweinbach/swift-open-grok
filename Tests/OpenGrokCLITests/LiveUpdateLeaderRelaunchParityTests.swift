import Foundation
import OpenGrokACPRuntime
import OpenGrokConfig
import OpenGrokFileUtils
import OpenGrokHTTP
import Testing

@testable import OpenGrokCLI
@testable import OpenGrokUpdate

private final class UpdateLeaderFixture: @unchecked Sendable {
    let home: URL
    private var listeners: [(
        path: URL,
        listener: ACPLeaderSocketListener,
        incoming: AsyncStream<any WebSocketByteChannel>
    )] = []

    #if os(Windows)
    private var locks: [AdvisoryLock] = []
    #endif

    init() throws {
        let requested = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ogu-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        #if os(Windows)
        try OpenGrokConfig.createDirAllOwnerOnly(requested, stateRoot: requested)
        #else
        try OpenGrokConfig.createDirAllOwnerOnly(requested)
        #endif
        home = requested.standardizedFileURL.resolvingSymlinksInPath()
    }

    var environment: [String: String] {
        [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "GROK_TEST_VERSION": "1.0.0",
        ]
    }

    func endpoint(_ stem: String = "leader") async throws -> URL {
        let path = home.appendingPathComponent(stem + ".sock")
        #if os(Windows)
        let lock = try AdvisoryFileLock.acquire(
            at: home.appendingPathComponent(stem + ".lock"),
            options: AdvisoryLockOptions(nonBlocking: true, create: true, mode: 0o600)
        )
        locks.append(lock)
        #endif
        let listener = ACPLeaderSocketListener(path: path)
        let incoming = try await listener.start()
        listeners.append((path: path, listener: listener, incoming: incoming))
        return path
    }

    func serve(_ endpoint: URL, host: ACPLeaderIPCHost) throws -> Task<Void, Never> {
        guard let entry = listeners.first(where: { $0.path == endpoint }) else {
            throw CLIApplicationError.failed("missing leader listener fixture")
        }
        return Task {
            for await channel in entry.incoming {
                await host.serve(channel: channel)
            }
        }
    }

    func cleanup() async {
        for entry in listeners {
            await entry.listener.stop()
        }
        listeners.removeAll()
        #if os(Windows)
        for lock in locks {
            lock.release()
        }
        locks.removeAll()
        #endif
        try? FileManager.default.removeItem(at: home)
    }
}

private func withUpdateLeaderFixture(
    _ operation: (UpdateLeaderFixture) async throws -> Void
) async throws {
    let fixture = try UpdateLeaderFixture()
    do {
        try await operation(fixture)
    } catch {
        await fixture.cleanup()
        throw error
    }
    await fixture.cleanup()
}

private actor UpdateLeaderDialHarness {
    private var hosts: [String: ACPLeaderIPCHost] = [:]
    private var scripted: [String: UpdateScriptedLeader] = [:]
    private var refused: Set<String> = []
    private var connections: [String] = []
    private var tasks: [Task<Void, Never>] = []

    func register(_ endpoint: URL, host: ACPLeaderIPCHost) {
        hosts[endpoint.path] = host
    }

    func register(_ endpoint: URL, scripted leader: UpdateScriptedLeader) {
        scripted[endpoint.path] = leader
    }

    func refuse(_ endpoint: URL) {
        refused.insert(endpoint.path)
    }

    func dial(_ endpoint: URL, timeout: Double) async throws -> any WebSocketByteChannel {
        connections.append(endpoint.path)
        guard timeout > 0, !refused.contains(endpoint.path) else {
            throw CLIApplicationError.failed("fixture refused direct dial")
        }

        let pair = InMemoryWebSocketChannel.makePair()
        if let host = hosts[endpoint.path] {
            tasks.append(Task { await host.serve(channel: pair.a) })
        } else if let leader = scripted[endpoint.path] {
            tasks.append(Task { await leader.serve(channel: pair.a) })
        } else {
            await pair.a.close()
            throw CLIApplicationError.failed("fixture has no running leader")
        }
        return pair.b
    }

    func paths() -> [String] {
        connections
    }

    func shutdown() async {
        for host in hosts.values {
            await host.stop()
        }
        for task in tasks {
            task.cancel()
        }
    }
}

private actor UpdateScriptedLeader {
    enum Reply: Sendable {
        case acknowledged(from: String, to: String, grace: UInt64)
        case declined(String)
    }

    private let version: String
    private let capabilities: ACPLeaderCapabilities
    private let reply: Reply
    private var registrationTypes: [String] = []
    private var commands: [[String: String]] = []

    init(
        version: String,
        capabilities: ACPLeaderCapabilities = .supported,
        reply: Reply
    ) {
        self.version = version
        self.capabilities = capabilities
        self.reply = reply
    }

    func serve(channel: any WebSocketByteChannel) async {
        let reader = ACPLeaderChannelReader(
            channel: channel,
            maximumMessageSize: ACPLeaderProtocolLimits.maximumMessageSize
        )
        do {
            guard let registration = try await reader.next(ACPLeaderClientMessage.self),
                  case .register(let clientType, let mode, _) = registration,
                  mode == .stdio
            else { return }
            registrationTypes.append(clientType)
            try await channel.write(try ACPLeaderCodec.encode(
                ACPLeaderServerMessage.registered(
                    clientID: 1,
                    ready: true,
                    protocolVersion: ACPLeaderProtocolLimits.protocolVersion,
                    binaryVersion: version,
                    capabilities: capabilities
                )
            ))

            guard let message = try await reader.next(ACPLeaderClientMessage.self),
                  case .control(let requestID, let command) = message
            else { return }
            commands.append(command)

            let payload: ACPLeaderControlPayload
            switch reply {
            case .acknowledged(let from, let to, let grace):
                payload = .relaunching(
                    fromVersion: from,
                    toVersion: to,
                    graceMilliseconds: grace
                )
            case .declined(let reason):
                payload = .relaunchDeclined(reason: reason)
            }
            try await channel.write(try ACPLeaderCodec.encode(
                ACPLeaderServerMessage.controlResult(requestID: requestID, payload: payload)
            ))
        } catch {
            return
        }
    }

    func observed() -> (registrations: [String], commands: [[String: String]]) {
        (registrationTypes, commands)
    }
}

private actor UpdateNotificationEvents {
    private var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }

    func snapshot() -> [String] {
        events
    }
}

private func updateLeaderHost(
    version: String,
    capabilities: ACPLeaderCapabilities = .supported,
    log: @escaping @Sendable (String) -> Void = { _ in }
) -> ACPLeaderIPCHost {
    ACPLeaderIPCHost(
        runtime: ACPAgentRuntime(),
        configuration: ACPLeaderIPCConfiguration(
            binaryVersion: version,
            capabilities: capabilities
        ),
        log: log
    )
}

private func updateLeaderRelease(_ version: String) throws -> ReleaseCandidate {
    let platform = ReleasePlatform.current
    return try ReleaseCandidate(
        tagName: "v\(version)",
        version: version,
        assets: [
            ReleaseAsset(
                name: platform.assetName,
                downloadURL: URL(string: "https://example.invalid/\(platform.assetName)")!
            ),
        ]
    )
}

@Suite("explicit update leader relaunch parity", .serialized)
struct LiveUpdateLeaderRelaunchParityTests {
    @Test("an empty private home never creates sockets, locks, or a leader")
    func absentLeaderNeverSpawns() async throws {
        try await withUpdateLeaderFixture { fixture in
            let initial = try FileManager.default.contentsOfDirectory(
                at: fixture.home,
                includingPropertiesForKeys: nil
            )
            #expect(initial.isEmpty)
            let (streams, _, err) = CLIStreams.buffered()

            await LiveUpdateLeaderRelaunch.notify(
                installedVersion: "2.0.0",
                environment: fixture.environment,
                streams: streams
            )

            let remaining = try FileManager.default.contentsOfDirectory(
                at: fixture.home,
                includingPropertiesForKeys: nil
            )
            #expect(remaining.isEmpty)
            #expect(err.contents.isEmpty)
        }
    }

    @Test("private production discovery directly reaches the running leader and prints Rust's exact notice")
    func productionSocketDiscoveryAndControl() async throws {
        try await withUpdateLeaderFixture { fixture in
            let endpoint = try await fixture.endpoint()
            let registrations = BufferedStream()
            let host = updateLeaderHost(version: "1.0.0") { registrations.write($0 + "\n") }
            let served = try fixture.serve(endpoint, host: host)
            let (streams, out, err) = CLIStreams.buffered()

            await LiveUpdateLeaderRelaunch.notify(
                installedVersion: "2.0.0",
                environment: fixture.environment,
                streams: streams
            )

            #expect(out.contents.isEmpty)
            #expect(err.contents == "  ↻ Relaunching shared session (leader 1.0.0 → 2.0.0)…\n")
            #expect(registrations.contents.contains("grok-pager-update, stdio"))

            await host.stop()
            served.cancel()
        }
    }

    @Test("duplicate discovery entries send the exact upstream control once")
    func duplicateHostsAreContactedOnlyOnce() async throws {
        try await withUpdateLeaderFixture { fixture in
            let endpoint = try await fixture.endpoint()
            let leader = UpdateScriptedLeader(
                version: "1.2.3",
                reply: .acknowledged(from: "1.2.3", to: "2.0.0", grace: 10_000)
            )
            let harness = UpdateLeaderDialHarness()
            await harness.register(endpoint, scripted: leader)
            let (streams, _, err) = CLIStreams.buffered()

            await LiveUpdateLeaderRelaunch.notify(
                installedVersion: "2.0.0",
                environment: fixture.environment,
                streams: streams,
                dependencies: LiveUpdateLeaderRelaunchDependencies(
                    discover: { _ in [endpoint, endpoint, endpoint] },
                    dial: { path, timeout in try await harness.dial(path, timeout: timeout) }
                )
            )

            #expect(await harness.paths() == [endpoint.path])
            let observed = await leader.observed()
            #expect(observed.registrations == ["grok-pager-update"])
            #expect(observed.commands == [[
                "type": "relaunch_for_update",
                "to_version": "2.0.0",
            ]])
            #expect(err.contents == "  ↻ Relaunching shared session (leader 1.2.3 → 2.0.0)…\n")
            await harness.shutdown()
        }
    }

    @Test(arguments: [
        "2.0.0",
        "2.0.1",
        "2.0.0+different-build",
        "unknown",
        "v1.0.0",
        " 1.0.0",
        "1.0.0 ",
    ])
    func nonOlderOrMalformedLeaderIsNeverRelaunched(_ version: String) async throws {
        try await withUpdateLeaderFixture { fixture in
            let endpoint = try await fixture.endpoint()
            let leader = UpdateScriptedLeader(
                version: version,
                reply: .acknowledged(from: version, to: "2.0.0", grace: 10_000)
            )
            let harness = UpdateLeaderDialHarness()
            await harness.register(endpoint, scripted: leader)
            let (streams, _, err) = CLIStreams.buffered()

            await LiveUpdateLeaderRelaunch.notify(
                installedVersion: "2.0.0",
                environment: fixture.environment,
                streams: streams,
                dependencies: LiveUpdateLeaderRelaunchDependencies(
                    dial: { path, timeout in try await harness.dial(path, timeout: timeout) }
                )
            )

            #expect(await harness.paths() == [endpoint.path])
            #expect(await leader.observed().commands.isEmpty)
            #expect(err.contents.isEmpty)
            await harness.shutdown()
        }
    }

    @Test("leaders lacking advertised relaunch support never receive a control command")
    func capabilityIsMandatory() async throws {
        try await withUpdateLeaderFixture { fixture in
            let endpoint = try await fixture.endpoint()
            let leader = UpdateScriptedLeader(
                version: "1.0.0",
                capabilities: ACPLeaderCapabilities(controlV1: true, relaunchV1: false),
                reply: .acknowledged(from: "1.0.0", to: "2.0.0", grace: 10_000)
            )
            let harness = UpdateLeaderDialHarness()
            await harness.register(endpoint, scripted: leader)
            let (streams, _, err) = CLIStreams.buffered()

            await LiveUpdateLeaderRelaunch.notify(
                installedVersion: "2.0.0",
                environment: fixture.environment,
                streams: streams,
                dependencies: LiveUpdateLeaderRelaunchDependencies(
                    dial: { path, timeout in try await harness.dial(path, timeout: timeout) }
                )
            )

            #expect(await leader.observed().commands.isEmpty)
            #expect(err.contents.isEmpty)
            await harness.shutdown()
        }
    }

    @Test("declines and mismatched acknowledgements never claim a relaunch")
    func declinedAndMismatchedAcknowledgements() async throws {
        try await withUpdateLeaderFixture { fixture in
            let declined = try await fixture.endpoint("leader-declined")
            let wrongVersion = try await fixture.endpoint("leader-wrong")
            let wrongGrace = try await fixture.endpoint("leader-grace")
            let harness = UpdateLeaderDialHarness()
            await harness.register(
                declined,
                scripted: UpdateScriptedLeader(version: "1.0.0", reply: .declined("busy"))
            )
            await harness.register(
                wrongVersion,
                scripted: UpdateScriptedLeader(
                    version: "1.0.0",
                    reply: .acknowledged(from: "1.0.0", to: "3.0.0", grace: 10_000)
                )
            )
            await harness.register(
                wrongGrace,
                scripted: UpdateScriptedLeader(
                    version: "1.0.0",
                    reply: .acknowledged(from: "1.0.0", to: "2.0.0", grace: 9_999)
                )
            )
            let (streams, _, err) = CLIStreams.buffered()

            await LiveUpdateLeaderRelaunch.notify(
                installedVersion: "2.0.0",
                environment: fixture.environment,
                streams: streams,
                dependencies: LiveUpdateLeaderRelaunchDependencies(
                    dial: { path, timeout in try await harness.dial(path, timeout: timeout) }
                )
            )

            #expect((await harness.paths()).count == 3)
            #expect(err.contents.isEmpty)
            await harness.shutdown()
        }
    }

    @Test("unreachable leaders are skipped and later discoverable leaders still relaunch")
    func failedDialDoesNotPreventTheNextLeader() async throws {
        try await withUpdateLeaderFixture { fixture in
            let failed = try await fixture.endpoint("leader-a")
            let healthy = try await fixture.endpoint("leader-b")
            let harness = UpdateLeaderDialHarness()
            await harness.refuse(failed)
            await harness.register(healthy, host: updateLeaderHost(version: "1.0.0"))
            let (streams, _, err) = CLIStreams.buffered()

            await LiveUpdateLeaderRelaunch.notify(
                installedVersion: "2.0.0",
                environment: fixture.environment,
                streams: streams,
                dependencies: LiveUpdateLeaderRelaunchDependencies(
                    dial: { path, timeout in try await harness.dial(path, timeout: timeout) }
                )
            )

            #expect(await harness.paths() == [failed.path, healthy.path])
            #expect(err.contents == "  ↻ Relaunching shared session (leader 1.0.0 → 2.0.0)…\n")
            await harness.shutdown()
        }
    }

    @Test("missing authority, malformed names, outside paths, and oversized discovery never dial or spawn")
    func hostileDiscoveryFailsClosed() async throws {
        try await withUpdateLeaderFixture { fixture in
            let endpoint = try await fixture.endpoint()
            let harness = UpdateLeaderDialHarness()
            await harness.register(endpoint, host: updateLeaderHost(version: "1.0.0"))
            let (streams, _, err) = CLIStreams.buffered()
            let dependencies = LiveUpdateLeaderRelaunchDependencies(
                discover: { root in
                    [
                        root.appendingPathComponent("leadership.sock"),
                        root.appendingPathComponent("leader-.sock"),
                        root.appendingPathComponent("leader-bad.sock.tmp"),
                        root.deletingLastPathComponent().appendingPathComponent("leader.sock"),
                    ]
                },
                dial: { path, timeout in try await harness.dial(path, timeout: timeout) }
            )

            await LiveUpdateLeaderRelaunch.notify(
                installedVersion: "2.0.0",
                environment: [:],
                streams: streams,
                dependencies: dependencies
            )
            await LiveUpdateLeaderRelaunch.notify(
                installedVersion: " v2.0.0 ",
                environment: fixture.environment,
                streams: streams,
                dependencies: dependencies
            )
            await LiveUpdateLeaderRelaunch.notify(
                installedVersion: "2.0.0",
                environment: fixture.environment,
                streams: streams,
                dependencies: dependencies
            )
            await LiveUpdateLeaderRelaunch.notify(
                installedVersion: "2.0.0",
                environment: fixture.environment,
                streams: streams,
                dependencies: LiveUpdateLeaderRelaunchDependencies(
                    discover: { _ in
                        Array(
                            repeating: endpoint,
                            count: LiveUpdateLeaderRelaunch.maximumDirectoryEntries + 1
                        )
                    },
                    dial: { path, timeout in try await harness.dial(path, timeout: timeout) }
                )
            )

            #expect(await harness.paths().isEmpty)
            #expect(err.contents.isEmpty)
            await harness.shutdown()
        }
    }

    #if canImport(Darwin) || canImport(Glibc)
    @Test("non-private homes and symlinked sockets are never followed")
    func unixPrivateDirectoryAndSocketGuards() async throws {
        try await withUpdateLeaderFixture { fixture in
            let endpoint = try await fixture.endpoint()
            let alias = fixture.home.appendingPathComponent("leader-escape.sock")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: endpoint)
            let harness = UpdateLeaderDialHarness()
            await harness.register(endpoint, host: updateLeaderHost(version: "1.0.0"))
            let (streams, _, err) = CLIStreams.buffered()

            await LiveUpdateLeaderRelaunch.notify(
                installedVersion: "2.0.0",
                environment: fixture.environment,
                streams: streams,
                dependencies: LiveUpdateLeaderRelaunchDependencies(
                    discover: { _ in [alias] },
                    dial: { path, timeout in try await harness.dial(path, timeout: timeout) }
                )
            )

            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: fixture.home.path
            )
            await LiveUpdateLeaderRelaunch.notify(
                installedVersion: "2.0.0",
                environment: fixture.environment,
                streams: streams,
                dependencies: LiveUpdateLeaderRelaunchDependencies(
                    dial: { path, timeout in try await harness.dial(path, timeout: timeout) }
                )
            )

            #expect(await harness.paths().isEmpty)
            #expect(err.contents.isEmpty)
            await harness.shutdown()
        }
    }
    #endif

    #if (os(macOS) && arch(arm64)) || (os(Linux) && arch(x86_64)) || (os(Windows) && arch(x86_64))
    @Test("a successful real update route directly relaunches its discoverable older shared leader")
    func successfulLauncherInstallReachesProductionLeaderNotifier() async throws {
        try await withUpdateLeaderFixture { fixture in
            let endpoint = try await fixture.endpoint()
            let host = updateLeaderHost(version: "1.0.0")
            let served = try fixture.serve(endpoint, host: host)
            let release = try updateLeaderRelease("2.0.0")
            let services = LiveUpdateServices(
                fetchLatestRelease: { _ in release },
                install: { version, _, _, _ in
                    ReleaseInstallService.InstallResult(
                        version: version,
                        stagedBinary: fixture.home.appendingPathComponent("staged"),
                        managedLink: fixture.home.appendingPathComponent("managed")
                    )
                }
            )
            let (streams, out, err) = CLIStreams.buffered()
            let application = OpenGrokApplication(
                launcher: OpenGrokLiveApplicationLauncher(updateServices: services).launcher,
                control: .never
            )

            let code = await CLIRunner.run(
                ["update"],
                environment: fixture.environment,
                streams: streams,
                application: application
            )

            #expect(code == CLIRunner.ExitCode.success.rawValue)
            #expect(out.contents.contains("✓ Open Grok v2.0.0 installed successfully!"))
            #expect(err.contents == "  ↻ Relaunching shared session (leader 1.0.0 → 2.0.0)…\n")

            await host.stop()
            served.cancel()
        }
    }

    @Test("the live update launcher notifies only after a committed install and preserves success on notification failure")
    func successfulLauncherInstallNotifiesAfterCommit() async throws {
        try await withUpdateLeaderFixture { fixture in
            let events = UpdateNotificationEvents()
            let release = try updateLeaderRelease("2.0.0")
            let services = LiveUpdateServices(
                fetchLatestRelease: { _ in
                    await events.record("fetch")
                    return release
                },
                install: { version, _, _, _ in
                    await events.record("install:\(version)")
                    return ReleaseInstallService.InstallResult(
                        version: version,
                        stagedBinary: fixture.home.appendingPathComponent("staged"),
                        managedLink: fixture.home.appendingPathComponent("managed")
                    )
                },
                notifyInstalledLeaders: { version, environment, _ in
                    await events.record("notify:\(version):\(environment["OPENGROK_HOME"] ?? "")")
                    throw CLIApplicationError.failed("best-effort discovery deliberately failed")
                }
            )
            let (streams, out, err) = CLIStreams.buffered()
            let application = OpenGrokApplication(
                launcher: OpenGrokLiveApplicationLauncher(updateServices: services).launcher,
                control: .never
            )

            let code = await CLIRunner.run(
                ["update"],
                environment: fixture.environment,
                streams: streams,
                application: application
            )

            #expect(code == CLIRunner.ExitCode.success.rawValue)
            #expect(err.contents.isEmpty)
            #expect(out.contents.contains("✓ Open Grok v2.0.0 installed successfully!"))
            #expect(await events.snapshot() == [
                "fetch",
                "install:2.0.0",
                "notify:2.0.0:\(fixture.home.path)",
            ])
        }
    }

    @Test(arguments: ["check", "current", "failed"])
    func nonInstalledLauncherRoutesNeverNotify(_ route: String) async throws {
        try await withUpdateLeaderFixture { fixture in
            let events = UpdateNotificationEvents()
            let release = try updateLeaderRelease(route == "current" ? "1.0.0" : "2.0.0")
            let services = LiveUpdateServices(
                fetchLatestRelease: { _ in
                    await events.record("fetch")
                    return release
                },
                install: { _, _, _, _ in
                    await events.record("install")
                    throw CLIApplicationError.failed("fixture installation failed")
                },
                notifyInstalledLeaders: { _, _, _ in
                    await events.record("notify")
                }
            )
            let (streams, _, _) = CLIStreams.buffered()
            let application = OpenGrokApplication(
                launcher: OpenGrokLiveApplicationLauncher(updateServices: services).launcher,
                control: .never
            )

            let code = await CLIRunner.run(
                route == "check" ? ["update", "--check"] : ["update"],
                environment: fixture.environment,
                streams: streams,
                application: application
            )

            #expect(code == (
                route == "failed"
                    ? CLIRunner.ExitCode.failure.rawValue
                    : CLIRunner.ExitCode.success.rawValue
            ))
            let recorded = await events.snapshot()
            #expect(!recorded.contains("notify"))
            #expect(recorded.contains("install") == (route == "failed"))
        }
    }
    #endif
}
