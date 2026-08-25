import Foundation
import Testing

@testable import OpenGrokCLI

private actor VersionPolicyLaunchRecorder {
    private var routes: [String] = []

    func record(_ route: String) {
        routes.append(route)
    }

    func snapshot() -> [String] {
        routes
    }
}

private struct VersionPolicyConfigFailureFixture {
    let root: URL
    let home: URL
    let workspace: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-version-policy-\(UUID().uuidString)",
            isDirectory: true
        )
        home = root.appendingPathComponent("state", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)

        for directory in [home, workspace] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    func environment(
        currentVersion: String,
        overrides: [String: String] = [:]
    ) -> [String: String] {
        var values = [
            "HOME": root.path,
            "OPENGROK_HOME": home.path,
            "PWD": workspace.path,
            "GROK_TEST_VERSION": currentVersion,
        ]
        values.merge(overrides) { _, override in override }
        return values
    }

    func write(_ contents: String, filename: String) throws {
        try contents.write(
            to: home.appendingPathComponent(filename),
            atomically: true,
            encoding: .utf8
        )
    }

    func run(
        _ arguments: [String] = ["headless", "--prompt", "version policy gate"],
        environment: [String: String]
    ) async -> (status: Int32, output: String, errors: String, launches: [String]) {
        let recorder = VersionPolicyLaunchRecorder()
        let launcher = CLIApplicationLauncher { command, _ in
            await recorder.record(command.routeName)
            return CLIApplicationSession(waitForExit: {}, shutdown: {})
        }
        let application = OpenGrokApplication(launcher: launcher, control: .never)
        let (streams, output, errors) = CLIStreams.buffered()
        let status = await CLIRunner.run(
            arguments,
            environment: environment,
            streams: streams,
            application: application
        )
        let launches = await recorder.snapshot()
        return (status, output.contents, errors.contents, launches)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("managed version policy survives owner configuration failures")
struct LiveVersionPolicyConfigFailureParityTests {
    @Test("malformed user config cannot bypass a managed minimum version")
    func malformedUserConfigPreservesManagedMinimum() async throws {
        let fixture = try VersionPolicyConfigFailureFixture()
        defer { fixture.cleanup() }
        try fixture.write(
            "[credentials]\napi_key = \"private-user-secret\"\n[cli\n",
            filename: "config.toml"
        )
        try fixture.write(
            "[cli]\nrequired_minimum_version = \"2.0.0\"\n",
            filename: "managed_config.toml"
        )
        let environment = fixture.environment(currentVersion: "1.0.0")
        let command = CLICommandParser.parse(
            ["headless", "--prompt", "version policy gate"],
            environment: environment
        )

        let refusal = LiveVersionPolicyGate.refusal(for: command, environment: environment)
        #expect(refusal?.contains("minimum required by your organization (2.0.0)") == true)

        let result = await fixture.run(environment: environment)

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(result.output.isEmpty)
        #expect(result.errors.contains("Grok (1.0.0)"))
        #expect(result.errors.contains("minimum required by your organization (2.0.0)"))
        #expect(!result.errors.contains("private-user-secret"))
        #expect(result.launches.isEmpty)
    }

    @Test("malformed user config cannot bypass a managed maximum version")
    func malformedUserConfigPreservesManagedMaximum() async throws {
        let fixture = try VersionPolicyConfigFailureFixture()
        defer { fixture.cleanup() }
        try fixture.write("[cli\n", filename: "config.toml")
        try fixture.write(
            "[cli]\nrequired_maximum_version = \"2.0.0\"\n",
            filename: "managed_config.toml"
        )

        let result = await fixture.run(
            environment: fixture.environment(currentVersion: "3.0.0")
        )

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(result.output.isEmpty)
        #expect(result.errors.contains("Grok (3.0.0)"))
        #expect(result.errors.contains("maximum allowed by your organization (2.0.0)"))
        #expect(result.launches.isEmpty)
    }

    @Test("malformed user config and contradictory environment cannot erase managed requirements")
    func malformedUserConfigPreservesRequirementsMinimum() async throws {
        let fixture = try VersionPolicyConfigFailureFixture()
        defer { fixture.cleanup() }
        try fixture.write("[cli\n", filename: "config.toml")
        try fixture.write(
            "[cli]\nrequired_minimum_version = \"2.0.0\"\n",
            filename: "requirements.toml"
        )

        let result = await fixture.run(
            environment: fixture.environment(
                currentVersion: "1.0.0",
                overrides: ["GROK_REQUIRED_MAXIMUM_VERSION": "0.5.0"]
            )
        )

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(result.output.isEmpty)
        #expect(result.errors.contains("minimum required by your organization (2.0.0)"))
        #expect(result.launches.isEmpty)
    }

    @Test("a malformed managed configuration fails closed without exposing secrets")
    func malformedManagedConfigRefusesStartup() async throws {
        let fixture = try VersionPolicyConfigFailureFixture()
        defer { fixture.cleanup() }
        try fixture.write("[cli]\nminimum_version = \"1.0.0\"\n", filename: "config.toml")
        try fixture.write(
            "[credentials]\napi_key = \"private-managed-secret\"\n[cli\n",
            filename: "managed_config.toml"
        )

        let result = await fixture.run(
            environment: fixture.environment(currentVersion: "2.0.0")
        )

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(result.output.isEmpty)
        #expect(result.errors.contains("Managed version policy could not be verified"))
        #expect(result.errors.contains("managed_config.toml"))
        #expect(result.errors.contains("open-grok setup"))
        #expect(!result.errors.contains("private-managed-secret"))
        #expect(result.launches.isEmpty)
    }

    @Test("a malformed requirements artifact fails closed without exposing secrets")
    func malformedRequirementsRefuseStartup() async throws {
        let fixture = try VersionPolicyConfigFailureFixture()
        defer { fixture.cleanup() }
        try fixture.write(
            "[cli]\nrequired_minimum_version = \"1.0.0\"\n",
            filename: "managed_config.toml"
        )
        try fixture.write(
            "[credentials]\napi_key = \"private-requirements-secret\"\n[cli\n",
            filename: "requirements.toml"
        )

        let result = await fixture.run(
            environment: fixture.environment(currentVersion: "2.0.0")
        )

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(result.output.isEmpty)
        #expect(result.errors.contains("Managed version policy could not be verified"))
        #expect(result.errors.contains("requirements.toml"))
        #expect(!result.errors.contains("private-requirements-secret"))
        #expect(result.launches.isEmpty)
    }

    @Test("valid managed and user policy still admits an in-range binary")
    func validPolicyStillReachesTheLauncher() async throws {
        let fixture = try VersionPolicyConfigFailureFixture()
        defer { fixture.cleanup() }
        try fixture.write(
            "[cli]\nrequired_minimum_version = \"1.0.0\"\n"
                + "required_maximum_version = \"3.0.0\"\n",
            filename: "managed_config.toml"
        )
        try fixture.write(
            "[cli]\nrequired_minimum_version = \"2.0.0\"\n"
                + "required_maximum_version = \"2.5.0\"\n",
            filename: "config.toml"
        )

        let result = await fixture.run(
            environment: fixture.environment(currentVersion: "2.1.0")
        )

        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        #expect(result.output.isEmpty)
        #expect(result.errors.isEmpty)
        #expect(result.launches == ["headless"])
    }

    @Test("version inspection remains reachable when mandatory policy is malformed")
    func malformedPolicyDoesNotBlockRecoveryAndInspectionRoutes() async throws {
        let fixture = try VersionPolicyConfigFailureFixture()
        defer { fixture.cleanup() }
        try fixture.write("[cli\n", filename: "managed_config.toml")

        let result = await fixture.run(
            ["version"],
            environment: fixture.environment(currentVersion: "2.0.0")
        )

        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        #expect(result.output.hasPrefix("Open Grok 2.0.0"))
        #expect(result.errors.isEmpty)
        #expect(result.launches.isEmpty)
    }
}
