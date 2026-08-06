import Foundation
import OpenGrokConfig
import OpenGrokSandbox
import Testing

@testable import OpenGrokCLI

private final class RecordingSandboxRuntime: LiveSandboxRuntime, @unchecked Sendable {
    var active = false
    var profile: String?
    var autoAllow = false
    var applyCount = 0
    var failApply = false

    func apply(profileName: ProfileName, workspaceRoot: URL) throws {
        _ = workspaceRoot
        applyCount += 1
        if failApply {
            throw SandboxError.enforcementFailed("test failure")
        }
        active = true
        profile = profileName.description
    }

    func isSandboxActive() -> Bool { active }
    func activeProfileName() -> String? { profile }
    func setAutoAllowBash(_ enabled: Bool) { autoAllow = enabled }
    func shouldAutoAllowBash() -> Bool { autoAllow && active }
}

@Suite("live sandbox composition")
struct LiveSandboxCompositionTests {
    @Test("the parsed CLI sandbox profile reaches live bootstrap")
    func cliProfileReachesBootstrap() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenGrokLiveSandbox-\(UUID().uuidString)", isDirectory: true)
        let home = workspace.appendingPathComponent("home", isDirectory: true)
        let openGrokHome = home.appendingPathComponent(".opengrok", isDirectory: true)
        try FileManager.default.createDirectory(at: openGrokHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let environment = [
            "HOME": home.path,
            "OPENGROK_HOME": openGrokHome.path,
            "GROK_SANDBOX": "strict",
        ]
        let cli = CLIPermissionOptions(sandboxProfile: "off")
        let security = LiveSecurityContext.resolve(
            workspaceRoot: workspace,
            environment: environment,
            isInteractive: false,
            cli: cli
        )

        let decision = try security.applySandbox(
            workspaceRoot: workspace,
            cliProfile: cli.sandboxProfile,
            persistedProfile: nil,
            environment: environment
        )

        #expect(decision.profileName == "off")
        #expect(!decision.enforced)
    }

    @Test("a saved profile wins when resume has no explicit sandbox override")
    func persistedProfileWinsOverDefaults() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenGrokLiveSandbox-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let environment = ["GROK_SANDBOX": "strict"]
        let security = LiveSecurityContext.resolve(
            workspaceRoot: workspace,
            environment: environment,
            isInteractive: false,
            cli: CLIPermissionOptions()
        )
        let decision = try security.applySandbox(
            workspaceRoot: workspace,
            cliProfile: nil,
            persistedProfile: "none",
            environment: environment
        )

        #expect(decision.profileName == "off")
        #expect(!decision.enforced)
    }

    @Test("an explicit resume profile must match the saved profile after alias normalization")
    func explicitResumeProfileConflict() {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenGrokLiveSandbox-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let security = LiveSecurityContext.resolve(
            workspaceRoot: workspace,
            environment: [:],
            isInteractive: false,
            cli: CLIPermissionOptions()
        )
        #expect(throws: SandboxError.self) {
            try security.applySandbox(
                workspaceRoot: workspace,
                cliProfile: "strict",
                persistedProfile: "off",
                environment: [:]
            )
        }
        let normalized = try? security.applySandbox(
            workspaceRoot: workspace,
            cliProfile: "none",
            persistedProfile: "off",
            environment: [:]
        )
        #expect(normalized?.profileName == "off")
    }

    @Test("a non-off sandbox success is reported as enforced")
    func nonOffBootstrapEnforces() throws {
        let runtime = RecordingSandboxRuntime()

        let decision = try LiveSandboxComposition.bootstrap(
            workspaceRoot: URL(fileURLWithPath: "/tmp"),
            document: nil,
            cliProfile: "strict",
            runtime: runtime
        )

        #expect(runtime.applyCount == 1)
        #expect(runtime.active)
        #expect(decision.profileName == "strict")
        #expect(decision.enforced)
    }

    @Test("a non-off sandbox failure is surfaced instead of downgraded")
    func nonOffBootstrapFailsClosed() {
        let runtime = RecordingSandboxRuntime()
        runtime.failApply = true

        #expect(throws: SandboxError.self) {
            try LiveSandboxComposition.bootstrap(
                workspaceRoot: URL(fileURLWithPath: "/tmp"),
                document: nil,
                cliProfile: "strict",
                runtime: runtime
            )
        }

        #expect(runtime.applyCount == 1)
        #expect(!runtime.active)
        #expect(!runtime.autoAllow)
    }

    @Test("resume pins the exact profile while accepting aliases")
    func resumeProfilePinning() {
        #expect(throws: SandboxError.self) {
            try LiveSandboxComposition.validateResume(
                requested: "off",
                persisted: "strict"
            )
        }
        #expect(throws: SandboxError.self) {
            try LiveSandboxComposition.validateResume(
                requested: "workspace",
                persisted: "strict"
            )
        }
        #expect(throws: Never.self) {
            try LiveSandboxComposition.validateResume(
                requested: "readonly",
                persisted: "read-only"
            )
        }
        #expect(throws: Never.self) {
            try LiveSandboxComposition.validateResume(
                requested: "none",
                persisted: "off"
            )
        }
    }

    @Test("a decoded persisted profile rejects a weaker CLI before runtime apply")
    func persistedRecordRejectsWeakerSelectionBeforeTools() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenGrokLiveSandbox-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let store = LiveConversationStore(openGrokHome: home)
        let record = LiveConversationRecord.new(
            sessionID: "sandbox-pinned",
            workingDirectory: workspace,
            sandboxProfile: "strict"
        )
        try await store.save(record)
        let resumed = try await store.load(sessionID: record.sessionID)
        let runtime = RecordingSandboxRuntime()
        let security = LiveSecurityContext.resolve(
            workspaceRoot: workspace,
            environment: [:],
            isInteractive: false,
            cli: CLIPermissionOptions()
        )

        #expect(throws: SandboxError.self) {
            try security.applySandbox(
                workspaceRoot: workspace,
                cliProfile: "off",
                persistedProfile: resumed.sandboxProfile,
                environment: [:],
                runtime: runtime
            )
        }
        #expect(runtime.applyCount == 0)
    }

    @Test("auto-allow activates only after successful sandbox enforcement")
    func autoAllowFollowsSuccessfulActivation() throws {
        let runtime = RecordingSandboxRuntime()
        let document = TOMLValue.table(try parseTOMLTable("""
        [sandbox]
        auto_allow_bash = false
        """))
        let requirement = TOMLValue.table(try parseTOMLTable("""
        [sandbox]
        auto_allow_bash = true
        """))

        let decision = try LiveSandboxComposition.bootstrap(
            workspaceRoot: URL(fileURLWithPath: "/tmp"),
            document: document,
            requirements: [requirement],
            cliProfile: "workspace",
            environment: ["GROK_SANDBOX_AUTO_ALLOW_BASH": "false"],
            runtime: runtime
        )

        #expect(runtime.applyCount == 1)
        #expect(runtime.active)
        #expect(runtime.autoAllow)
        #expect(decision.enforced)
        #expect(decision.autoAllowBash)
    }

    @Test("failed or off sandbox bootstrap clears process auto-allow state")
    func failedAndOffBootstrapClearAutoAllow() throws {
        let runtime = RecordingSandboxRuntime()
        runtime.autoAllow = true
        runtime.failApply = true

        #expect(throws: SandboxError.self) {
            try LiveSandboxComposition.bootstrap(
                workspaceRoot: URL(fileURLWithPath: "/tmp"),
                document: nil,
                cliProfile: "workspace",
                environment: ["GROK_SANDBOX_AUTO_ALLOW_BASH": "true"],
                runtime: runtime
            )
        }
        #expect(!runtime.autoAllow)

        runtime.failApply = false
        let decision = try LiveSandboxComposition.bootstrap(
            workspaceRoot: URL(fileURLWithPath: "/tmp"),
            document: nil,
            cliProfile: "off",
            environment: ["GROK_SANDBOX_AUTO_ALLOW_BASH": "true"],
            runtime: runtime
        )
        #expect(!decision.enforced)
        #expect(!decision.autoAllowBash)
        #expect(!runtime.autoAllow)
    }
}
