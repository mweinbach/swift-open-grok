import Foundation
import OpenGrokConfig
import OpenGrokSandbox
import OpenGrokShellBase
import Testing
@testable import OpenGrokCLI

private final class DefaultWorkspaceRecordingSandboxRuntime: LiveSandboxRuntime, @unchecked Sendable {
    private struct State {
        var activeProfile: String?
        var appliedWorkspaces: [URL] = []
        var autoAllow = false
        var shouldFail: Bool
        var appliedProfileOverride: String?
    }

    private let lock = NSLock()
    private var state: State

    init(
        activeProfile: String? = nil,
        shouldFail: Bool = false,
        appliedProfileOverride: String? = nil
    ) {
        state = State(
            activeProfile: activeProfile,
            shouldFail: shouldFail,
            appliedProfileOverride: appliedProfileOverride
        )
    }

    var appliedWorkspaces: [URL] {
        lock.withLock { state.appliedWorkspaces }
    }

    func apply(profileName: ProfileName, workspaceRoot: URL) throws {
        try lock.withLock {
            state.appliedWorkspaces.append(workspaceRoot)
            if state.shouldFail {
                throw SandboxError.unsupported("test sandbox backend unavailable")
            }
            state.activeProfile = state.appliedProfileOverride ?? profileName.description
        }
    }

    func isSandboxActive() -> Bool {
        lock.withLock { state.activeProfile != nil }
    }

    func activeProfileName() -> String? {
        lock.withLock { state.activeProfile }
    }

    func setAutoAllowBash(_ enabled: Bool) {
        lock.withLock { state.autoAllow = enabled }
    }

    func shouldAutoAllowBash() -> Bool {
        lock.withLock { state.autoAllow && state.activeProfile != nil }
    }
}

private struct DefaultWorkspaceSandboxFixture {
    let root: URL
    let workspace: URL
    let home: URL
    let state: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "open-grok-default-workspace-sandbox-\(UUID().uuidString)",
            isDirectory: true
        )
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        home = root.appendingPathComponent("owner", isDirectory: true)
        state = home.appendingPathComponent(".opengrok", isDirectory: true)
        for directory in [workspace, state] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    var environment: [String: String] {
        [
            "HOME": home.path,
            "OPENGROK_HOME": state.path,
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            "XAI_API_KEY": "default-workspace-sandbox-test-key",
        ]
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func table(_ contents: String) throws -> TOMLValue {
        .table(try parseTOMLTable(contents))
    }
}

@Suite("default workspace sandbox Rust commit 448a2af security parity")
struct LiveDefaultWorkspaceSandboxParityTests {
    @Test("a fresh session defaults to workspace confinement instead of no sandbox")
    func freshSessionDefaultsToWorkspace() {
        #expect(LiveSandboxComposition.resolveProfileName(
            document: nil,
            environment: [:]
        ) == "workspace")
    }

    @Test("sandbox authority resolves requirements, CLI, environment, config, then workspace")
    func profileAuthorityOrderMatchesRust() throws {
        let fixture = try DefaultWorkspaceSandboxFixture()
        defer { fixture.cleanup() }
        let document = try fixture.table("[sandbox]\nprofile = \"devbox\"\n")
        let requirement = try fixture.table("[sandbox]\nprofile = \"strict\"\n")

        #expect(LiveSandboxComposition.resolveProfileName(
            document: document,
            requirements: [requirement],
            cliProfile: "off",
            environment: ["GROK_SANDBOX": "read-only"]
        ) == "strict")
        #expect(LiveSandboxComposition.resolveProfileName(
            document: document,
            cliProfile: "off",
            environment: ["GROK_SANDBOX": "read-only"]
        ) == "off")
        #expect(LiveSandboxComposition.resolveProfileName(
            document: document,
            environment: ["GROK_SANDBOX": "read-only"]
        ) == "read-only")
        #expect(LiveSandboxComposition.resolveProfileName(
            document: document,
            environment: [:]
        ) == "devbox")
        #expect(LiveSandboxComposition.resolveProfileName(
            document: nil,
            environment: ["GROK_SANDBOX": "  "]
        ) == "workspace")
    }

    @Test("MDM requirements outrank conflicting system requirements and owner preferences")
    func managedRequirementLayersRetainDescendingAuthority() throws {
        let fixture = try DefaultWorkspaceSandboxFixture()
        defer { fixture.cleanup() }
        let mdm = try fixture.table("[sandbox]\nprofile = \"strict\"\n")
        let system = try fixture.table("[sandbox]\nprofile = \"read-only\"\n")
        let owner = try fixture.table("[sandbox]\nprofile = \"off\"\n")

        #expect(LiveSandboxComposition.resolveProfileName(
            document: owner,
            requirements: [mdm, system, owner],
            cliProfile: "off",
            environment: ["GROK_SANDBOX": "workspace"]
        ) == "strict")
    }

    @Test("explicit CLI and owner config off both opt out of the workspace default")
    func explicitOptOutRemainsSupported() throws {
        let fixture = try DefaultWorkspaceSandboxFixture()
        defer { fixture.cleanup() }
        let configured = try fixture.table("[sandbox]\nprofile = \"off\"\n")

        #expect(LiveSandboxComposition.resolveProfileName(
            document: nil,
            cliProfile: "off",
            environment: [:]
        ) == "off")
        #expect(LiveSandboxComposition.resolveProfileName(
            document: configured,
            environment: [:]
        ) == "off")
    }

    @Test("the default profile is applied to the canonical session workspace")
    func defaultBootstrapActuallyAppliesWorkspace() throws {
        let fixture = try DefaultWorkspaceSandboxFixture()
        defer { fixture.cleanup() }
        let runtime = DefaultWorkspaceRecordingSandboxRuntime()

        let decision = try LiveSandboxComposition.bootstrap(
            workspaceRoot: fixture.workspace,
            document: nil,
            environment: fixture.environment,
            runtime: runtime
        )

        #expect(decision.profileName == "workspace")
        #expect(decision.mode == .restricted)
        #expect(decision.enforced)
        #expect(runtime.appliedWorkspaces == [
            fixture.workspace.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL,
        ])
    }

    @Test("managed requirements cannot be bypassed using an explicit --sandbox off")
    func managedRequirementOverridesExplicitOptOut() throws {
        let fixture = try DefaultWorkspaceSandboxFixture()
        defer { fixture.cleanup() }
        let requirement = try fixture.table("[sandbox]\nprofile = \"strict\"\n")
        let runtime = DefaultWorkspaceRecordingSandboxRuntime()

        let decision = try LiveSandboxComposition.bootstrap(
            workspaceRoot: fixture.workspace,
            document: nil,
            requirements: [requirement],
            cliProfile: "off",
            environment: fixture.environment,
            runtime: runtime
        )

        #expect(decision.profileName == "strict")
        #expect(decision.enforced)
        #expect(runtime.activeProfileName() == "strict")
    }

    @Test("a real disk-loaded owner requirement still beats CLI and owner config")
    func liveSecurityContextPreservesLoadedRequirementAuthority() throws {
        let fixture = try DefaultWorkspaceSandboxFixture()
        defer { fixture.cleanup() }
        try "[sandbox]\nprofile = \"strict\"\n".write(
            to: fixture.state.appendingPathComponent("requirements.toml"),
            atomically: true,
            encoding: .utf8
        )
        try "[sandbox]\nprofile = \"off\"\n".write(
            to: fixture.state.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
        let permissions = CLIPermissionOptions(sandboxProfile: "off")
        let security = LiveSecurityContext.resolve(
            workspaceRoot: fixture.workspace,
            environment: fixture.environment,
            isInteractive: false,
            cli: permissions
        )
        let runtime = DefaultWorkspaceRecordingSandboxRuntime()

        let decision = try security.applySandbox(
            workspaceRoot: fixture.workspace,
            cliProfile: permissions.sandboxProfile,
            persistedProfile: nil,
            environment: fixture.environment,
            runtime: runtime
        )

        #expect(decision.profileName == "strict")
        #expect(decision.enforced)
        #expect(runtime.appliedWorkspaces.count == 1)
    }

    @Test("a previously unsandboxed saved session is never silently upgraded")
    func savedOffProfileRemainsImmutableAcrossTheNewDefault() throws {
        let fixture = try DefaultWorkspaceSandboxFixture()
        defer { fixture.cleanup() }
        let runtime = DefaultWorkspaceRecordingSandboxRuntime()

        let decision = try LiveSandboxComposition.bootstrap(
            workspaceRoot: fixture.workspace,
            document: nil,
            persistedProfile: "none",
            environment: fixture.environment,
            runtime: runtime
        )

        #expect(decision.profileName == "off")
        #expect(decision.enforced == false)
        #expect(runtime.appliedWorkspaces.isEmpty)
    }

    @Test("an explicit resume mismatch fails before any process sandbox is applied")
    func explicitResumeOverrideCannotChangeSavedProfile() throws {
        let fixture = try DefaultWorkspaceSandboxFixture()
        defer { fixture.cleanup() }
        let runtime = DefaultWorkspaceRecordingSandboxRuntime()

        #expect(throws: SandboxError.self) {
            try LiveSandboxComposition.bootstrap(
                workspaceRoot: fixture.workspace,
                document: nil,
                cliProfile: "off",
                persistedProfile: "workspace",
                environment: fixture.environment,
                runtime: runtime
            )
        }
        #expect(runtime.appliedWorkspaces.isEmpty)
    }

    @Test("a newly conflicting managed requirement cannot silently rewrite a saved profile")
    func managedRequirementConflictingWithResumeFailsClosed() throws {
        let fixture = try DefaultWorkspaceSandboxFixture()
        defer { fixture.cleanup() }
        let requirement = try fixture.table("[sandbox]\nprofile = \"strict\"\n")
        let runtime = DefaultWorkspaceRecordingSandboxRuntime()

        #expect(throws: SandboxError.self) {
            try LiveSandboxComposition.bootstrap(
                workspaceRoot: fixture.workspace,
                document: nil,
                requirements: [requirement],
                persistedProfile: "off",
                environment: fixture.environment,
                runtime: runtime
            )
        }
        #expect(runtime.appliedWorkspaces.isEmpty)
    }

    @Test("an unavailable workspace backend fails closed instead of claiming confinement")
    func unsupportedDefaultWorkspaceNeverDowngrades() throws {
        let fixture = try DefaultWorkspaceSandboxFixture()
        defer { fixture.cleanup() }
        let runtime = DefaultWorkspaceRecordingSandboxRuntime(shouldFail: true)

        #expect(throws: SandboxError.self) {
            try LiveSandboxComposition.bootstrap(
                workspaceRoot: fixture.workspace,
                document: nil,
                environment: fixture.environment,
                runtime: runtime
            )
        }
        #expect(runtime.isSandboxActive() == false)
        #expect(runtime.appliedWorkspaces.count == 1)
    }

    @Test("an active backend profile different from managed requirements is never reported as enforced")
    func backendApplyingDifferentProfileFailsClosed() throws {
        let fixture = try DefaultWorkspaceSandboxFixture()
        defer { fixture.cleanup() }
        let requirement = try fixture.table("[sandbox]\nprofile = \"strict\"\n")
        let runtime = DefaultWorkspaceRecordingSandboxRuntime(
            appliedProfileOverride: "workspace"
        )

        #expect(throws: SandboxError.self) {
            try LiveSandboxComposition.bootstrap(
                workspaceRoot: fixture.workspace,
                document: nil,
                requirements: [requirement],
                environment: fixture.environment,
                runtime: runtime
            )
        }
        #expect(runtime.activeProfileName() == "workspace")
        #expect(runtime.shouldAutoAllowBash() == false)
    }

    @Test("child sessions may inherit an active profile but cannot replace its authority")
    func inheritedProcessSandboxMustMatchTheChildRequest() throws {
        let fixture = try DefaultWorkspaceSandboxFixture()
        defer { fixture.cleanup() }
        let active = DefaultWorkspaceRecordingSandboxRuntime(activeProfile: "workspace")

        let inherited = try LiveSandboxComposition.bootstrap(
            workspaceRoot: fixture.workspace,
            document: nil,
            environment: fixture.environment,
            runtime: active
        )
        #expect(inherited.profileName == "workspace")
        #expect(inherited.enforced)
        #expect(active.appliedWorkspaces.isEmpty)

        #expect(throws: SandboxError.self) {
            try LiveSandboxComposition.bootstrap(
                workspaceRoot: fixture.workspace,
                document: nil,
                cliProfile: "strict",
                environment: fixture.environment,
                runtime: active
            )
        }
        #expect(throws: SandboxError.self) {
            try LiveSandboxComposition.bootstrap(
                workspaceRoot: fixture.workspace,
                document: nil,
                cliProfile: "off",
                environment: fixture.environment,
                runtime: active
            )
        }
        #expect(active.appliedWorkspaces.isEmpty)
    }

    @Test("the real headless CLI launches with workspace confinement and persists its profile")
    func liveCLIEnforcesAndPersistsTheWorkspaceDefault() async throws {
        let fixture = try DefaultWorkspaceSandboxFixture()
        defer { fixture.cleanup() }
        let runtime = DefaultWorkspaceRecordingSandboxRuntime()
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { _, emit in
                    await emit(.output("sandboxed turn complete"))
                    return OpenGrokLiveSamplingResponse(output: "sandboxed turn complete")
                }
            },
            makeSandboxRuntime: { runtime }
        )
        let streams = CLIStreams.buffered()
        let sessionID = UUID().uuidString.lowercased()

        let status = await CLIRunner.run(
            [
                "headless", "--prompt", "verify sandbox", "--cwd", fixture.workspace.path,
                "--model", "grok-4.5", "--session-id", sessionID,
            ],
            environment: fixture.environment,
            streams: streams.0,
            application: .live(dependencies: dependencies, control: .never)
        )

        #expect(status == CLIRunner.ExitCode.success.rawValue)
        #expect(runtime.activeProfileName() == "workspace")
        #expect(runtime.appliedWorkspaces.count == 1)
        let persisted = try await LiveConversationStore(openGrokHome: fixture.state)
            .load(sessionID: sessionID)
        #expect(persisted.sandboxProfile == "workspace")
        #expect(streams.1.contents.contains("sandboxed turn complete"))
    }

    @Test("the real headless CLI preserves an intentional --sandbox off opt-out")
    func liveCLIHonorsExplicitSandboxOff() async throws {
        let fixture = try DefaultWorkspaceSandboxFixture()
        defer { fixture.cleanup() }
        let runtime = DefaultWorkspaceRecordingSandboxRuntime()
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { _, _ in
                    OpenGrokLiveSamplingResponse(output: "explicitly unrestricted")
                }
            },
            makeSandboxRuntime: { runtime }
        )
        let streams = CLIStreams.buffered()
        let sessionID = UUID().uuidString.lowercased()

        let status = await CLIRunner.run(
            [
                "headless", "--prompt", "verify explicit opt-out", "--cwd", fixture.workspace.path,
                "--model", "grok-4.5", "--sandbox", "off", "--session-id", sessionID,
            ],
            environment: fixture.environment,
            streams: streams.0,
            application: .live(dependencies: dependencies, control: .never)
        )

        #expect(status == CLIRunner.ExitCode.success.rawValue)
        #expect(runtime.appliedWorkspaces.isEmpty)
        let persisted = try await LiveConversationStore(openGrokHome: fixture.state)
            .load(sessionID: sessionID)
        #expect(persisted.sandboxProfile == "off")
    }

    @Test("the real headless CLI respects an owner-configured sandbox off override")
    func liveCLIHonorsConfiguredSandboxOff() async throws {
        let fixture = try DefaultWorkspaceSandboxFixture()
        defer { fixture.cleanup() }
        try "[sandbox]\nprofile = \"off\"\n".write(
            to: fixture.state.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
        let runtime = DefaultWorkspaceRecordingSandboxRuntime()
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { _, _ in
                    OpenGrokLiveSamplingResponse(output: "configured sandbox opt-out")
                }
            },
            makeSandboxRuntime: { runtime }
        )
        let streams = CLIStreams.buffered()
        let sessionID = UUID().uuidString.lowercased()

        let status = await CLIRunner.run(
            [
                "headless", "--prompt", "verify configured opt-out", "--cwd", fixture.workspace.path,
                "--model", "grok-4.5", "--session-id", sessionID,
            ],
            environment: fixture.environment,
            streams: streams.0,
            application: .live(dependencies: dependencies, control: .never)
        )

        #expect(status == CLIRunner.ExitCode.success.rawValue)
        #expect(runtime.appliedWorkspaces.isEmpty)
        let persisted = try await LiveConversationStore(openGrokHome: fixture.state)
            .load(sessionID: sessionID)
        #expect(persisted.sandboxProfile == "off")
    }

    @Test("a real resumed legacy session retains its persisted off profile")
    func liveCLIResumePreservesLegacySandboxPolicy() async throws {
        let fixture = try DefaultWorkspaceSandboxFixture()
        defer { fixture.cleanup() }
        let runtime = DefaultWorkspaceRecordingSandboxRuntime()
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { _, _ in
                    OpenGrokLiveSamplingResponse(output: "legacy session remains unrestricted")
                }
            },
            makeSandboxRuntime: { runtime }
        )
        let sessionID = UUID().uuidString.lowercased()
        let first = CLIStreams.buffered()
        let created = await CLIRunner.run(
            [
                "headless", "--prompt", "create legacy session", "--cwd", fixture.workspace.path,
                "--model", "grok-4.5", "--sandbox", "off", "--session-id", sessionID,
            ],
            environment: fixture.environment,
            streams: first.0,
            application: .live(dependencies: dependencies, control: .never)
        )
        #expect(created == CLIRunner.ExitCode.success.rawValue)

        let second = CLIStreams.buffered()
        let resumed = await CLIRunner.run(
            [
                "headless", "--prompt", "resume legacy session", "--cwd", fixture.workspace.path,
                "--model", "grok-4.5", "--resume", sessionID,
            ],
            environment: fixture.environment,
            streams: second.0,
            application: .live(dependencies: dependencies, control: .never)
        )

        #expect(resumed == CLIRunner.ExitCode.success.rawValue)
        #expect(runtime.appliedWorkspaces.isEmpty)
        let persisted = try await LiveConversationStore(openGrokHome: fixture.state)
            .load(sessionID: sessionID)
        #expect(persisted.sandboxProfile == "off")
    }

    @Test("the real shell subprocess cannot write outside the workspace Seatbelt profile")
    func actualChildProcessIsConfinedToWorkspaceWritableRoots() async throws {
        #if os(macOS)
        let fixture = try DefaultWorkspaceSandboxFixture()
        defer { fixture.cleanup() }
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let escaped = repository.appendingPathComponent(
            ".open-grok-sandbox-escape-\(UUID().uuidString)"
        )
        let allowed = fixture.workspace.appendingPathComponent("allowed.txt")
        defer { try? FileManager.default.removeItem(at: escaped) }

        let profile = try ProfileName.workspace.resolve(
            workspace: fixture.workspace,
            config: SandboxConfig(),
            environment: fixture.environment
        )
        let sbpl = buildSeatbeltProfile(profile, workspace: fixture.workspace)
        let profilePath = fixture.root.appendingPathComponent("workspace.sb")
        try sbpl.write(to: profilePath, atomically: true, encoding: .utf8)

        func quoted(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let script = "printf allowed > \"$1\"; "
            + "if printf escaped > \"$2\" 2>/dev/null; then exit 91; fi; "
            + "test -f \"$1\""
        let command = "/usr/bin/sandbox-exec -f \(quoted(profilePath.path)) "
            + "/bin/sh -c \(quoted(script)) probe \(quoted(allowed.path)) \(quoted(escaped.path))"
        let backend = LocalShellProcessBackend(inheritedEnvironment: fixture.environment)
        let result = try await backend.run(ShellCommandRequest(
            command: command,
            workingDirectory: fixture.workspace,
            timeout: .seconds(10),
            toolCallID: "real-default-workspace-confinement"
        ))
        await backend.killAllBackgroundTasks()

        #expect(result.exitCode == 0)
        #expect(try String(contentsOf: allowed, encoding: .utf8) == "allowed")
        #expect(FileManager.default.fileExists(atPath: escaped.path) == false)
        #endif
    }
}
