import Foundation
import OpenGrokSamplingTypes
import OpenGrokShellBase
import Testing

@testable import OpenGrokCLI

@Suite("live Git-ignore policy reaches the actual model-visible file tools")
struct LiveGitIgnoreAccessPolicyParityTests {
    @Test("environment enables ignored-secret protection in the live executor")
    func environmentEnablesProtection() async throws {
        try await assertSecretAccess(environmentFlag: "true", expectedAllowed: false)
    }

    @Test("the upstream default keeps ignored files readable")
    func defaultDoesNotInventAdditionalRestrictions() async throws {
        try await assertSecretAccess(environmentFlag: nil, expectedAllowed: true)
    }

    @Test("environment false overrides ordinary user configuration")
    func environmentOverridesUserConfiguration() async throws {
        try await assertSecretAccess(
            environmentFlag: "false",
            configuration: "[tools]\nrespect_gitignore = true\n",
            expectedAllowed: true
        )
    }

    @Test("managed requirement cannot be disabled by process environment")
    func requirementOverridesEnvironment() async throws {
        try await assertSecretAccess(
            environmentFlag: "false",
            requirements: "[tools]\nrespect_gitignore = true\n",
            expectedAllowed: false
        )
    }

    private func assertSecretAccess(
        environmentFlag: String?,
        configuration: String? = nil,
        requirements: String? = nil,
        expectedAllowed: Bool
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "open-grok-live-gitignore-\(UUID().uuidString)",
            isDirectory: true
        )
        let home = root.appendingPathComponent("state", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try ".env\n".write(
            to: workspace.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        try "TOP_SECRET=value\n".write(
            to: workspace.appendingPathComponent(".env"),
            atomically: true,
            encoding: .utf8
        )
        if let configuration {
            try configuration.write(
                to: home.appendingPathComponent("config.toml"),
                atomically: true,
                encoding: .utf8
            )
        }
        if let requirements {
            try requirements.write(
                to: home.appendingPathComponent("requirements.toml"),
                atomically: true,
                encoding: .utf8
            )
        }

        var environment = [
            "HOME": root.path,
            "OPENGROK_HOME": home.path,
            "GROK_SANDBOX": "off",
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        ]
        if let environmentFlag {
            environment["GROK_RESPECT_GITIGNORE"] = environmentFlag
        }
        let sessionID = UUID().uuidString
        let executor = try await LiveToolExecutor(
            processBackend: LocalShellProcessBackend(inheritedEnvironment: environment),
            sessionID: sessionID,
            workingDirectory: workspace,
            toolPolicy: nil,
            telemetryBootstrapContext: .empty,
            fileAccessPolicy: .allowAll,
            environment: environment
        )
        let outcome = await executor.invoke(
            sessionID: sessionID,
            workingDirectory: workspace,
            call: ToolCall(
                id: UUID().uuidString,
                name: "read_file",
                arguments: #"{"target_file":".env"}"#
            )
        )
        switch outcome {
        case .success(let result):
            #expect(expectedAllowed)
            #expect(result.promptText.contains("TOP_SECRET=value"))
        case .failure(let error):
            #expect(!expectedAllowed)
            #expect(String(describing: error).contains("ignored by .gitignore"))
        }
    }
}
