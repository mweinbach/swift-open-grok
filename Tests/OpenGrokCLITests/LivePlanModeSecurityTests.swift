import Foundation
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase
import OpenGrokWorkspace
import Testing
@testable import OpenGrokCLI

@Suite("Live plan-mode exact-file authorization")
struct LivePlanModeSecurityTests {
    @Test("managed edit denial remains effective while only the real plan write bypasses it")
    func managedDenyCannotBeBypassedWithAnotherPlanFilename() async throws {
        let fixture = try await LivePlanModeSecurityFixture()
        defer { fixture.cleanup() }
        let permissions = try #require(await fixture.executor.permissionHandle())
        let configuredRules = await permissions.config.rules
        #expect(configuredRules.contains {
            $0.action == .deny && $0.tool == .edit && $0.source == .managedConfig
        })

        let beforePlanMode = try await fixture.write(
            "src/plan.md",
            content: "unauthorized before planning",
            callID: "managed-before-plan"
        )
        guard case .failure = beforePlanMode else {
            Issue.record("managed administrator edit deny must reject the real model write")
            return
        }
        #expect(await permissions.lastMatchedRuleSource == .managedConfig)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("src/plan.md").path))

        try await fixture.enterPlanMode()
        let malicious = try await fixture.write(
            "src/plan.md",
            content: "bypass managed deny",
            callID: "managed-plan-basename-bypass"
        )
        guard case .failure(let error) = malicious else {
            Issue.record("a different plan.md must never acquire real session-plan authorization")
            return
        }
        #expect(String(describing: error).contains("plan mode"))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("src/plan.md").path))

        let authorized = try await fixture.write(
            ".opengrok/plan.md",
            content: "# authorized implementation plan\n",
            callID: "managed-real-plan"
        )
        guard case .success = authorized else {
            Issue.record("the exact authorized plan must remain auto-approved despite managed Edit deny")
            return
        }
        #expect(try String(contentsOf: fixture.plan, encoding: .utf8) == "# authorized implementation plan\n")
        await fixture.shutdown()
    }

    @Test("real model writes using basename, traversal, sibling, or absolute collisions stay blocked")
    func collidingModelWritePathsNeverTouchDisk() async throws {
        let fixture = try await LivePlanModeSecurityFixture()
        defer { fixture.cleanup() }
        try await fixture.enterPlanMode()
        let siblingPlan = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("external/plan.md")
        try "protected".write(to: siblingPlan, atomically: true, encoding: .utf8)

        for (offset, path) in [
            "plan.md",
            "src/plan.md",
            "other/plan.md",
            ".opengrok/../src/plan.md",
            "../external/plan.md",
            siblingPlan.path,
        ].enumerated() {
            let result = try await fixture.write(
                path,
                content: "hostile overwrite \(offset)",
                callID: "hostile-plan-path-\(offset)"
            )
            guard case .failure = result else {
                Issue.record("model write unexpectedly escaped the exact plan gate: \(path)")
                continue
            }
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("plan.md").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("src/plan.md").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("other/plan.md").path))
        #expect(try String(contentsOf: siblingPlan, encoding: .utf8) == "protected")
        await fixture.shutdown()
    }

    @Test("a deleted authorized plan can still be recreated by the live registered write tool")
    func missingAuthorizedPlanCanBeCreated() async throws {
        let fixture = try await LivePlanModeSecurityFixture()
        defer { fixture.cleanup() }
        try await fixture.enterPlanMode()
        try FileManager.default.removeItem(at: fixture.plan)
        #expect(!FileManager.default.fileExists(atPath: fixture.plan.path))

        let result = try await fixture.write(
            ".opengrok/plan.md",
            content: "recreated safely",
            callID: "recreate-real-plan"
        )
        guard case .success = result else {
            Issue.record("missing authorized session plan must remain creatable")
            return
        }
        #expect(try String(contentsOf: fixture.plan, encoding: .utf8) == "recreated safely")
        await fixture.shutdown()
    }

    @Test("an exact-looking authorized plan symlink cannot redirect model writes outside the workspace")
    func livePlanSymlinkEscapeFailsClosed() async throws {
        #if !os(Windows)
        let fixture = try await LivePlanModeSecurityFixture()
        defer { fixture.cleanup() }
        try await fixture.enterPlanMode()
        let protected = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("external/protected.md")
        try "administrator protected".write(to: protected, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: fixture.plan)
        try FileManager.default.createSymbolicLink(at: fixture.plan, withDestinationURL: protected)

        let result = try await fixture.write(
            ".opengrok/plan.md",
            content: "overwrite external target",
            callID: "authorized-symlink-escape"
        )
        guard case .failure = result else {
            Issue.record("plan-file auto-approval must not follow an outbound symlink")
            return
        }
        #expect(try String(contentsOf: protected, encoding: .utf8) == "administrator protected")
        await fixture.shutdown()
        #endif
    }
}

private struct LivePlanModeSecurityFixture {
    let root: URL
    let plan: URL
    let executor: LiveToolExecutor
    let backend: LocalShellProcessBackend
    private let base: URL
    private static let sessionID = "live-plan-mode-security"

    init() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-live-plan-security-\(UUID().uuidString)")
        root = base.appendingPathComponent("workspace", isDirectory: true)
        let home = base.appendingPathComponent("home", isDirectory: true)
        let grokHome = home.appendingPathComponent(".opengrok", isDirectory: true)
        let external = base.appendingPathComponent("external", isDirectory: true)
        for directory in [root, root.appendingPathComponent("src"), root.appendingPathComponent("other"), home, grokHome, external] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try """
        [permission]
        deny = ["Edit(**)"]
        """.write(
            to: grokHome.appendingPathComponent("managed_config.toml"),
            atomically: true,
            encoding: .utf8
        )
        let environment = [
            "HOME": home.path,
            "OPENGROK_HOME": grokHome.path,
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        ]
        plan = root.appendingPathComponent(".opengrok/plan.md")
        backend = LocalShellProcessBackend(inheritedEnvironment: environment)
        executor = try await LiveToolExecutor(
            processBackend: backend,
            sessionID: Self.sessionID,
            workingDirectory: root,
            toolPolicy: nil,
            telemetryBootstrapContext: .empty,
            fileAccessPolicy: .allowAll,
            environment: environment,
            permissionOptions: CLIPermissionOptions(alwaysApprove: true)
        )
    }

    func enterPlanMode() async throws {
        let result = await executor.invoke(
            sessionID: Self.sessionID,
            workingDirectory: root,
            call: ToolCall(id: "enter-real-plan-mode", name: "enter_plan_mode", arguments: "{}")
        )
        guard case .success = result else {
            Issue.record("the live registered enter_plan_mode tool failed: \(result)")
            throw CancellationError()
        }
        #expect(await executor.planModeActive())
        #expect(FileManager.default.fileExists(atPath: plan.path))
    }

    func write(
        _ path: String,
        content: String,
        callID: String
    ) async throws -> Result<OpenGrokShellToolCallResult, OpenGrokShellToolRuntimeError> {
        let arguments = try JSONEncoder().encode(JSONValue.object([
            "file_path": .string(path),
            "content": .string(content),
        ]))
        return await executor.invoke(
            sessionID: Self.sessionID,
            workingDirectory: root,
            call: ToolCall(
                id: callID,
                name: "write",
                arguments: String(decoding: arguments, as: UTF8.self)
            )
        )
    }

    func shutdown() async {
        await executor.shutdown()
        await backend.killAllBackgroundTasks()
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: base)
    }
}
