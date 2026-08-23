import Foundation
import OpenGrokACPRuntime
import OpenGrokConfigTypes
import OpenGrokWorkspace
import Testing
@testable import OpenGrokCLI

private final class WorkspaceSandboxRouteProbe: WorkspaceControlChannel, @unchecked Sendable {
    let advertisedCapabilities: ACPLeaderCapabilities? = ACPLeaderCapabilities(workspaceExposure: true)
    private let lock = NSLock()
    private let marker: URL
    private var remoteSettingsReads = 0
    private var leaderConnections = 0
    private var providerFactories = 0
    private var receivedCommands: [WorkspaceControlCommand] = []

    init(marker: URL) {
        self.marker = marker
    }

    func loadedSettings() -> RemoteSettings {
        lock.withLock { remoteSettingsReads += 1 }
        var settings = RemoteSettings()
        settings.workspaceCommandEnabled = true
        return settings
    }

    func connected() throws {
        lock.withLock { leaderConnections += 1 }
        try Data("leader contacted".utf8).write(to: marker)
    }

    func madeProvider() {
        lock.withLock { providerFactories += 1 }
    }

    func send(_ command: WorkspaceControlCommand) async throws -> WorkspaceStatusPayload {
        lock.withLock { receivedCommands.append(command) }
        let state: String
        switch command {
        case .stop: state = "none"
        case .pause: state = "paused"
        case .status: state = "running"
        case .resume, .start: state = "running"
        }
        return WorkspaceStatusPayload(state: state, pid: 8181)
    }

    func close() async {}

    var settingsCalls: Int { lock.withLock { remoteSettingsReads } }
    var connections: Int { lock.withLock { leaderConnections } }
    var samplers: Int { lock.withLock { providerFactories } }
    var commands: [WorkspaceControlCommand] { lock.withLock { receivedCommands } }
}

private struct WorkspaceSandboxRouteFixture {
    let root: URL
    let owner: URL
    let state: URL
    let workspace: URL
    let environment: [String: String]

    var connectionMarker: URL { root.appendingPathComponent("leader-connection-marker") }
    var trustPath: URL { state.appendingPathComponent("trusted_folders.toml") }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-workspace-sandbox-route-\(UUID().uuidString)")
        owner = root.appendingPathComponent("owner")
        state = owner.appendingPathComponent(".opengrok")
        workspace = root.appendingPathComponent("workspace")
        for directory in [state, workspace] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        environment = [
            "HOME": owner.path,
            "OPENGROK_HOME": state.path,
            "GROK_WORKSPACE_COMMAND": "1",
            "GROK_FOLDER_TRUST": "1",
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        ]
    }

    func dispose() {
        try? FileManager.default.removeItem(at: root)
    }

    func writeProfile(_ profile: String, filename: String = "config.toml", project: Bool = false) throws {
        let directory = project ? workspace.appendingPathComponent(".opengrok") : state
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "[sandbox]\nprofile = \"\(profile)\"\n".write(
            to: directory.appendingPathComponent(filename),
            atomically: true,
            encoding: .utf8
        )
    }

    func launch(
        action: String,
        prefix: [String] = [],
        environment override: [String: String]? = nil,
        probe: WorkspaceSandboxRouteProbe? = nil
    ) async throws -> WorkspaceSandboxRouteProbe {
        let probe = probe ?? WorkspaceSandboxRouteProbe(marker: connectionMarker)
        let effectiveEnvironment = override ?? environment
        let route = LiveWorkspaceRouteDependencies(
            loadRemoteSettings: { _ in probe.loadedSettings() },
            connect: { _ in
                try probe.connected()
                return probe
            }
        )
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                probe.madeProvider()
                return OpenGrokLiveSampler { _, _ in
                    OpenGrokLiveSamplingResponse(output: "workspace control does not sample")
                }
            },
            workspaceRoute: route
        )
        let command = try CLICommandParser.parseOrThrow(
            prefix + ["workspace", action, "--cwd", workspace.path],
            environment: effectiveEnvironment
        )
        let context = CLIApplicationContext(
            environment: effectiveEnvironment,
            streams: CLIStreams(out: { _ in }, err: { _ in }),
            control: .never
        )
        let session = try await OpenGrokLiveApplicationLauncher(dependencies: dependencies)
            .launcher.start(command, context)
        try await session.waitForExit()
        await session.shutdown()
        return probe
    }

    func requireRefusal(
        action: String,
        profile: String,
        prefix: [String] = [],
        environment override: [String: String]? = nil
    ) async {
        let probe = WorkspaceSandboxRouteProbe(marker: connectionMarker)
        do {
            let connected = try await launch(
                action: action,
                prefix: prefix,
                environment: override,
                probe: probe
            )
            Issue.record("confined workspace \(action) unexpectedly connected \(connected.connections) time(s)")
        } catch let error as WorkspaceRouteError {
            #expect(error.message.contains("sandbox profile '\(profile)'"))
            #expect(error.message.contains("start/restart/resume is unavailable"))
        } catch {
            Issue.record("expected a typed sandbox refusal, got \(error)")
        }
        #expect(probe.settingsCalls == 0)
        #expect(probe.connections == 0)
        #expect(probe.samplers == 0)
        #expect(probe.commands.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: connectionMarker.path))
    }
}

@Suite("live workspace control routes respect resolved sandbox authority")
struct LiveWorkspaceSandboxRouteParityTests {
    @Test("the default workspace profile refuses every exposure-activating route", arguments: [
        "start", "restart", "resume",
    ])
    func defaultProfileRejectsActivatingRoutes(_ action: String) async throws {
        let fixture = try WorkspaceSandboxRouteFixture()
        defer { fixture.dispose() }
        var environment = fixture.environment
        environment.removeValue(forKey: "GROK_WORKSPACE_COMMAND")

        await fixture.requireRefusal(action: action, profile: "workspace", environment: environment)
    }

    @Test("explicit --sandbox off admits all exposure-activating routes", arguments: [
        "start", "restart", "resume",
    ])
    func explicitOffAdmitsActivatingRoutes(_ action: String) async throws {
        let fixture = try WorkspaceSandboxRouteFixture()
        defer { fixture.dispose() }

        let probe = try await fixture.launch(action: action, prefix: ["--sandbox", "off"])

        #expect(probe.connections == 1)
        #expect(probe.samplers == 0)
        #expect(FileManager.default.fileExists(atPath: fixture.connectionMarker.path))
        if action == "restart" {
            #expect(probe.commands.count == 2)
            #expect(probe.commands.first == .stop)
        } else {
            #expect(probe.commands.count == 1)
        }
    }

    @Test("the supported none alias is normalized to an unconfined off profile")
    func noneAliasAdmitsActivation() async throws {
        let fixture = try WorkspaceSandboxRouteFixture()
        defer { fixture.dispose() }

        let probe = try await fixture.launch(action: "start", prefix: ["--sandbox", "none"])

        #expect(probe.connections == 1)
        #expect(FileManager.default.fileExists(atPath: fixture.connectionMarker.path))
    }

    @Test("owner-controlled GROK_SANDBOX=off disables default confinement")
    func environmentOffAdmitsActivation() async throws {
        let fixture = try WorkspaceSandboxRouteFixture()
        defer { fixture.dispose() }
        var environment = fixture.environment
        environment["GROK_SANDBOX"] = "off"

        let probe = try await fixture.launch(action: "resume", environment: environment)

        #expect(probe.commands == [.resume])
        #expect(FileManager.default.fileExists(atPath: fixture.connectionMarker.path))
    }

    @Test("owner configuration can explicitly select the unconfined off profile")
    func ownerConfigurationOffAdmitsActivation() async throws {
        let fixture = try WorkspaceSandboxRouteFixture()
        defer { fixture.dispose() }
        try fixture.writeProfile("off")

        let probe = try await fixture.launch(action: "start")

        #expect(probe.connections == 1)
    }

    @Test("an explicit off flag overrides stricter environment and owner configuration")
    func explicitOffOverridesEnvironmentAndOwnerConfig() async throws {
        let fixture = try WorkspaceSandboxRouteFixture()
        defer { fixture.dispose() }
        try fixture.writeProfile("readonly")
        var environment = fixture.environment
        environment["GROK_SANDBOX"] = "strict"

        let probe = try await fixture.launch(
            action: "start",
            prefix: ["--sandbox", "off"],
            environment: environment
        )

        #expect(probe.connections == 1)
    }

    @Test("managed requirement pins defeat explicit --sandbox off", arguments: [
        "start", "restart", "resume",
    ])
    func managedRequirementsRejectExplicitOff(_ action: String) async throws {
        let fixture = try WorkspaceSandboxRouteFixture()
        defer { fixture.dispose() }
        try fixture.writeProfile("strict", filename: "requirements.toml")

        await fixture.requireRefusal(action: action, profile: "strict", prefix: ["--sandbox", "off"])
    }

    @Test("managed workspace pins defeat environment and owner-config off selections")
    func managedRequirementsOverrideEveryUntrustedOffSource() async throws {
        let fixture = try WorkspaceSandboxRouteFixture()
        defer { fixture.dispose() }
        try fixture.writeProfile("off")
        try fixture.writeProfile("workspace", filename: "requirements.toml")
        var environment = fixture.environment
        environment["GROK_SANDBOX"] = "none"

        await fixture.requireRefusal(action: "resume", profile: "workspace", environment: environment)
    }

    @Test("configured restrictive profiles are normalized before the exposure refusal", arguments: [
        "strict", "readonly", "devbox", "custom-team-profile",
    ])
    func restrictiveConfiguredProfilesRefuse(_ configured: String) async throws {
        let fixture = try WorkspaceSandboxRouteFixture()
        defer { fixture.dispose() }
        try fixture.writeProfile(configured)

        let expected = configured == "readonly" ? "read-only" : configured
        await fixture.requireRefusal(action: "start", profile: expected)
    }

    @Test("status, list, pause, and stop remain available under restrictive managed pins", arguments: [
        "status", "list", "pause", "stop",
    ])
    func nonactivatingActionsRemainAvailable(_ action: String) async throws {
        let fixture = try WorkspaceSandboxRouteFixture()
        defer { fixture.dispose() }
        try fixture.writeProfile("strict", filename: "requirements.toml")

        let probe = try await fixture.launch(action: action)

        #expect(probe.connections == 1)
        #expect(probe.commands.count == 1)
        #expect(FileManager.default.fileExists(atPath: fixture.connectionMarker.path))
    }

    @Test("explicit off reaches the ordinary account feature gate after confinement is resolved")
    func explicitOffStillHonorsDisabledFeatureGate() async throws {
        let fixture = try WorkspaceSandboxRouteFixture()
        defer { fixture.dispose() }
        var environment = fixture.environment
        environment["GROK_WORKSPACE_COMMAND"] = "0"
        let probe = WorkspaceSandboxRouteProbe(marker: fixture.connectionMarker)

        do {
            let connected = try await fixture.launch(
                action: "start",
                prefix: ["--sandbox", "off"],
                environment: environment,
                probe: probe
            )
            Issue.record("disabled workspace feature unexpectedly connected \(connected.connections) time(s)")
        } catch let error as WorkspaceRouteError {
            #expect(error.message.contains("not enabled for this account"))
            #expect(!error.message.contains("sandbox profile"))
        }

        #expect(probe.settingsCalls == 0)
        #expect(probe.connections == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.connectionMarker.path))
    }

    @Test("an untrusted checkout cannot disable confinement in repository-owned config")
    func untrustedProjectCannotSelectOff() async throws {
        let fixture = try WorkspaceSandboxRouteFixture()
        defer { fixture.dispose() }
        try fixture.writeProfile("off", project: true)

        await fixture.requireRefusal(action: "start", profile: "workspace")
    }

    @Test("a previously trusted repository may contribute its reviewed off configuration")
    func durablyTrustedProjectCanSelectOff() async throws {
        let fixture = try WorkspaceSandboxRouteFixture()
        defer { fixture.dispose() }
        try fixture.writeProfile("off", project: true)
        var store = PersistentFolderTrustStore(environment: fixture.environment)
        try store.record(fixture.workspace, trusted: true)

        let probe = try await fixture.launch(action: "start")

        #expect(probe.connections == 1)
    }

    @Test("a sandbox-refused route cannot durably grant folder trust as a side effect")
    func refusedRouteNeverWritesTrustDecision() async throws {
        let fixture = try WorkspaceSandboxRouteFixture()
        defer { fixture.dispose() }
        try fixture.writeProfile("off", project: true)

        await fixture.requireRefusal(action: "start", profile: "workspace", prefix: ["--trust"])

        #expect(!FileManager.default.fileExists(atPath: fixture.trustPath.path))
        #expect(!PersistentFolderTrustStore(environment: fixture.environment).isTrusted(fixture.workspace))
    }
}
