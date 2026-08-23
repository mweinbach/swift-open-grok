import Foundation
import Testing
@testable import OpenGrokCLI

private struct LeaderSandboxParityFixture {
    let root: URL
    let owner: URL
    let state: URL
    let workspace: URL
    let environment: [String: String]

    var leaderMarker: URL { root.appendingPathComponent("leader-contacted") }
    var trustPath: URL { state.appendingPathComponent("trusted_folders.toml") }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-leader-sandbox-\(UUID().uuidString)")
        owner = root.appendingPathComponent("owner")
        state = owner.appendingPathComponent(".opengrok")
        workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        environment = [
            "HOME": owner.path,
            "OPENGROK_HOME": state.path,
            "GROK_FOLDER_TRUST": "0",
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        ]
    }

    func dispose() {
        try? FileManager.default.removeItem(at: root)
    }

    func writeOwnerProfile(_ profile: String, requirements: Bool = false) throws {
        let name = requirements ? "requirements.toml" : "config.toml"
        try "[sandbox]\nprofile = \"\(profile)\"\n".write(
            to: state.appendingPathComponent(name),
            atomically: true,
            encoding: .utf8
        )
    }

    func options(_ arguments: [String], environment override: [String: String]? = nil) throws -> CLIExecutionOptions {
        let command = try CLICommandParser.parseOrThrow(
            ["headless", "--prompt", "leader parity", "--cwd", workspace.path, "--leader"]
                + arguments,
            environment: override ?? environment
        )
        guard case .launch(let options) = command else {
            throw CLIApplicationError.failed("leader sandbox fixture did not parse a launch")
        }
        return options
    }

    func launch(
        _ arguments: [String],
        environment override: [String: String]? = nil
    ) async throws {
        let launchEnvironment = override ?? environment
        let marker = leaderMarker
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                throw CLIApplicationError.failed("sandbox policy reached the sampler")
            },
            makeLeaderClient: { _ in
                try Data("leader contacted".utf8).write(to: marker)
                throw CLIApplicationError.failed("leader marker reached")
            }
        )
        let command = try CLICommandParser.parseOrThrow(
            ["headless", "--prompt", "leader parity", "--cwd", workspace.path, "--leader"]
                + arguments,
            environment: launchEnvironment
        )
        let context = CLIApplicationContext(
            environment: launchEnvironment,
            streams: CLIStreams(out: { _ in }, err: { _ in }),
            control: .never
        )
        let session = try await OpenGrokLiveApplicationLauncher(dependencies: dependencies)
            .launcher.start(command, context)
        await session.shutdown()
    }
}

@Suite("leader launches cannot bypass effective sandbox confinement")
struct LiveLeaderSandboxParityTests {
    @Test("the workspace default refuses before leader IPC")
    func workspaceDefaultRefusesBeforeLeader() async throws {
        let fixture = try LeaderSandboxParityFixture()
        defer { fixture.dispose() }

        do {
            try await fixture.launch([])
            Issue.record("the default-confined leader launch unexpectedly succeeded")
        } catch let error as CLIApplicationError {
            #expect(error == .failed(LiveLeaderSandboxPolicy.refusalMessage(profile: "workspace")))
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.leaderMarker.path))
    }

    @Test("explicit off reaches the ordinary leader connection")
    func explicitOffReachesLeader() async throws {
        let fixture = try LeaderSandboxParityFixture()
        defer { fixture.dispose() }

        do {
            try await fixture.launch(["--sandbox", "off"])
            Issue.record("the marker leader unexpectedly returned a session")
        } catch let error as CLIApplicationError {
            #expect(error == .failed("leader marker reached"))
        }
        #expect(FileManager.default.fileExists(atPath: fixture.leaderMarker.path))
    }

    @Test("the none alias is normalized to authorized off")
    func noneAliasIsOff() throws {
        let fixture = try LeaderSandboxParityFixture()
        defer { fixture.dispose() }

        try LiveLeaderSandboxPolicy.enforce(
            options: fixture.options(["--sandbox", "none"]),
            workingDirectory: fixture.workspace,
            environment: fixture.environment
        )
    }

    @Test("managed requirements outrank an explicit off flag")
    func managedRequirementRejectsExplicitOff() throws {
        let fixture = try LeaderSandboxParityFixture()
        defer { fixture.dispose() }
        try fixture.writeOwnerProfile("strict", requirements: true)

        #expect(throws: CLIApplicationError.failed(
            LiveLeaderSandboxPolicy.refusalMessage(profile: "strict")
        )) {
            try LiveLeaderSandboxPolicy.enforce(
                options: fixture.options(["--sandbox", "off"]),
                workingDirectory: fixture.workspace,
                environment: fixture.environment
            )
        }
    }

    @Test("CLI off outranks environment and owner configuration")
    func explicitOffOutranksOwnerSources() throws {
        let fixture = try LeaderSandboxParityFixture()
        defer { fixture.dispose() }
        try fixture.writeOwnerProfile("read-only")
        var environment = fixture.environment
        environment["GROK_SANDBOX"] = "strict"

        try LiveLeaderSandboxPolicy.enforce(
            options: fixture.options(["--sandbox", "off"], environment: environment),
            workingDirectory: fixture.workspace,
            environment: environment
        )
    }

    @Test("a refused --trust launch cannot persist trust before failing")
    func refusalDoesNotPersistTrust() throws {
        let fixture = try LeaderSandboxParityFixture()
        defer { fixture.dispose() }
        var environment = fixture.environment
        environment["GROK_FOLDER_TRUST"] = "1"

        #expect(throws: CLIApplicationError.self) {
            try LiveLeaderSandboxPolicy.enforce(
                options: fixture.options(["--trust"], environment: environment),
                workingDirectory: fixture.workspace,
                environment: environment
            )
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.trustPath.path))
        #expect(!PersistentFolderTrustStore(environment: environment).isTrusted(fixture.workspace))
    }

    @Test("non-leader launches are outside this policy")
    func localLaunchIsUnaffected() throws {
        let fixture = try LeaderSandboxParityFixture()
        defer { fixture.dispose() }
        var options = try fixture.options([])
        options.common.leader = false

        try LiveLeaderSandboxPolicy.enforce(
            options: options,
            workingDirectory: fixture.workspace,
            environment: fixture.environment
        )
    }
}
