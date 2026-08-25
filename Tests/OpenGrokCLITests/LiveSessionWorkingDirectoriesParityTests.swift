import Foundation
import OpenGrokFileTools
import OpenGrokSamplingTypes
import OpenGrokSandbox
import OpenGrokSessionPersistence
import OpenGrokShell
import OpenGrokShellBase
import OpenGrokToolRegistry
import OpenGrokWorkspace
import Testing
@testable import OpenGrokCLI

private actor LiveWorkingDirectoryUpdates {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

private struct LiveSessionWorkingDirectoryFixture {
    let root: URL
    let owner: URL
    let state: URL
    let workspace: URL
    let approved: URL
    let outside: URL
    let sessionID: String
    let environment: [String: String]

    init(managedPolicy: String? = nil) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-live-working-directories-\(UUID().uuidString)")
            .standardizedFileURL.resolvingSymlinksInPath()
        owner = root.appendingPathComponent("owner")
        state = owner.appendingPathComponent(".opengrok")
        workspace = root.appendingPathComponent("workspace")
        approved = root.appendingPathComponent("approved", isDirectory: true)
        outside = root.appendingPathComponent("outside")
        sessionID = "working-directory-\(UUID().uuidString)"
        for directory in [state, workspace, approved, outside] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        if let managedPolicy {
            try managedPolicy.write(
                to: state.appendingPathComponent("managed_config.toml"),
                atomically: true,
                encoding: .utf8
            )
        }
        environment = [
            "HOME": owner.path,
            "OPENGROK_HOME": state.path,
            "GROK_SANDBOX": "off",
            "GROK_FOLDER_TRUST": "0",
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        ]
    }

    func dispose() {
        try? FileManager.default.removeItem(at: root)
    }

    func makeExecutor(
        sessionID override: String? = nil,
        workspace directory: URL? = nil,
        inheritedPermissionHandle: PermissionHandle? = nil,
        authorizationScope: ToolResourceAuthorizationScope? = nil,
        sandbox: LiveSandboxDecision? = nil
    ) async throws -> LiveToolExecutor {
        try await LiveToolExecutor(
            processBackend: LocalShellProcessBackend(inheritedEnvironment: environment),
            sessionID: override ?? sessionID,
            workingDirectory: directory ?? workspace,
            toolPolicy: nil,
            telemetryBootstrapContext: .empty,
            fileAccessPolicy: .prompt(HeadlessPermissionPrompter()),
            environment: environment,
            sandboxDecision: sandbox,
            inheritedPermissionHandle: inheritedPermissionHandle,
            authorizationScope: authorizationScope
        )
    }

    func makeBackend(
        executor: LiveToolExecutor,
        updates: LiveWorkingDirectoryUpdates? = nil
    ) async throws -> LiveSessionWorkingDirectories {
        let environmentUpdateSink: (@Sendable (String) async throws -> Void)?
        if let updates {
            environmentUpdateSink = { value in await updates.append(value) }
        } else {
            environmentUpdateSink = nil
        }

        return try await LiveSessionWorkingDirectories(
            sessionID: sessionID,
            workingDirectory: workspace,
            openGrokHome: state,
            environment: environment,
            executor: executor,
            environmentUpdateSink: environmentUpdateSink
        )
    }

    func invokeRead(
        executor: LiveToolExecutor,
        path: URL,
        sessionID override: String? = nil,
        workingDirectory directory: URL? = nil
    ) async -> Result<OpenGrokShellToolCallResult, OpenGrokShellToolRuntimeError> {
        let arguments = String(
            decoding: (try? JSONSerialization.data(withJSONObject: ["target_file": path.path])) ?? Data(),
            as: UTF8.self
        )
        return await executor.invoke(
            sessionID: override ?? sessionID,
            workingDirectory: directory ?? workspace,
            call: ToolCall(id: UUID().uuidString, name: "read_file", arguments: arguments)
        )
    }

    func invokeEdit(
        executor: LiveToolExecutor,
        path: URL,
        original: String,
        replacement: String,
        sessionID override: String? = nil,
        workingDirectory directory: URL? = nil
    ) async -> Result<OpenGrokShellToolCallResult, OpenGrokShellToolRuntimeError> {
        let arguments = String(
            decoding: (try? JSONSerialization.data(withJSONObject: [
                "file_path": path.path,
                "old_string": original,
                "new_string": replacement,
            ])) ?? Data(),
            as: UTF8.self
        )
        return await executor.invoke(
            sessionID: override ?? sessionID,
            workingDirectory: directory ?? workspace,
            call: ToolCall(id: UUID().uuidString, name: "search_replace", arguments: arguments)
        )
    }
}

@Suite("authenticated live session working-directory scope")
struct LiveSessionWorkingDirectoriesParityTests {
    @Test("a real directory gains Read/Edit scope, persists, and revokes immediately")
    func liveReadEditGrantAndRevocation() async throws {
        let fixture = try LiveSessionWorkingDirectoryFixture()
        defer { fixture.dispose() }
        let executor = try await fixture.makeExecutor()
        let updates = LiveWorkingDirectoryUpdates()
        let backend = try await fixture.makeBackend(executor: executor, updates: updates)
        let document = fixture.approved.appendingPathComponent("message.txt")
        try "before".write(to: document, atomically: true, encoding: .utf8)

        guard case .failure = await fixture.invokeRead(executor: executor, path: document) else {
            Issue.record("an ungranted external file was readable")
            await executor.shutdown()
            return
        }

        let granted = try await backend.add(
            path: "../approved",
            workingDirectory: fixture.workspace,
            environment: fixture.environment
        )
        #expect(granted.changed)
        #expect(granted.directories == [fixture.approved])
        #expect(granted.environmentUpdate.contains("<environment-update source=\"working_set\">"))
        #expect(granted.environmentUpdate.contains(fixture.approved.path))
        #expect(executor.additionalWorkingDirectories() == [fixture.approved])

        guard case .success(let readable) = await fixture.invokeRead(executor: executor, path: document) else {
            Issue.record("an explicitly approved file was not readable")
            await executor.shutdown()
            return
        }
        #expect(readable.promptText.contains("before"))
        guard case .success = await fixture.invokeEdit(
            executor: executor,
            path: document,
            original: "before",
            replacement: "after"
        ) else {
            Issue.record("an explicitly approved file was not editable")
            await executor.shutdown()
            return
        }
        #expect(try String(contentsOf: document, encoding: .utf8) == "after")

        let persisted = try SessionWorkingDirectoriesStore(
            grokHome: fixture.state,
            sessionID: fixture.sessionID,
            workingDirectory: fixture.workspace
        )
        #expect(try persisted.load() == [fixture.approved])

        let revoked = try await backend.remove(
            path: fixture.approved.path,
            workingDirectory: fixture.workspace,
            environment: fixture.environment
        )
        #expect(revoked.changed)
        #expect(revoked.directories.isEmpty)
        #expect(revoked.environmentUpdate.contains("only in-scope root"))
        #expect(executor.additionalWorkingDirectories().isEmpty)
        #expect(try persisted.load().isEmpty)
        #expect(await updates.values.count == 2)
        guard case .failure = await fixture.invokeRead(executor: executor, path: document) else {
            Issue.record("a revoked external file remained readable")
            await executor.shutdown()
            return
        }
        await executor.shutdown()
    }

    @Test("duplicate grants and unknown removals are idempotent")
    func duplicateAndUnknownMutationsDoNotCreateUpdates() async throws {
        let fixture = try LiveSessionWorkingDirectoryFixture()
        defer { fixture.dispose() }
        let executor = try await fixture.makeExecutor()
        let updates = LiveWorkingDirectoryUpdates()
        let backend = try await fixture.makeBackend(executor: executor, updates: updates)

        let first = try await backend.add(
            path: fixture.approved.path,
            workingDirectory: fixture.workspace,
            environment: fixture.environment
        )
        let duplicate = try await backend.add(
            path: fixture.approved.path,
            workingDirectory: fixture.workspace,
            environment: fixture.environment
        )
        let unknown = try await backend.remove(
            path: fixture.outside.path,
            workingDirectory: fixture.workspace,
            environment: fixture.environment
        )

        #expect(first.changed)
        #expect(!duplicate.changed)
        #expect(!unknown.changed)
        #expect(await updates.values.count == 1)
        await executor.shutdown()
    }

    @Test("persisted grants are restored before the resumed executor's first file call")
    func resumedSessionRestoresScopedRootsWithoutDuplicateDisclosure() async throws {
        let fixture = try LiveSessionWorkingDirectoryFixture()
        defer { fixture.dispose() }
        let original = try await fixture.makeExecutor()
        let initial = try await fixture.makeBackend(executor: original)
        _ = try await initial.add(
            path: fixture.approved.path,
            workingDirectory: fixture.workspace,
            environment: fixture.environment
        )
        try await initial.revoke()
        await original.shutdown()

        let updates = LiveWorkingDirectoryUpdates()
        let resumed = try await fixture.makeExecutor()
        let restored = try await fixture.makeBackend(executor: resumed, updates: updates)

        #expect(await restored.additionalDirectories == [fixture.approved])
        #expect(resumed.additionalWorkingDirectories() == [fixture.approved])
        #expect(await updates.values.isEmpty)
        await resumed.shutdown()
    }

    @Test(arguments: ["deny", "ask"])
    func managedPolicyRemainsBindingForGrantedEdits(_ action: String) async throws {
        let fixture = try LiveSessionWorkingDirectoryFixture(
            managedPolicy: "[permission]\n\(action) = [\"Edit(**)\"]\n"
        )
        defer { fixture.dispose() }
        let executor = try await fixture.makeExecutor()
        let backend = try await fixture.makeBackend(executor: executor)
        let document = fixture.approved.appendingPathComponent("protected.txt")
        try "unchanged".write(to: document, atomically: true, encoding: .utf8)
        _ = try await backend.add(
            path: fixture.approved.path,
            workingDirectory: fixture.workspace,
            environment: fixture.environment
        )

        guard case .failure = await fixture.invokeEdit(
            executor: executor,
            path: document,
            original: "unchanged",
            replacement: "compromised"
        ) else {
            Issue.record("a scoped working-directory grant bypassed managed \(action)")
            await executor.shutdown()
            return
        }
        #expect(try String(contentsOf: document, encoding: .utf8) == "unchanged")
        await executor.shutdown()
    }

    @Test("session identity, workspace identity, and owner state cannot be substituted")
    func crossSessionAndOwnerRequestsFailClosed() async throws {
        let fixture = try LiveSessionWorkingDirectoryFixture()
        defer { fixture.dispose() }
        let executor = try await fixture.makeExecutor()
        let backend = try await fixture.makeBackend(executor: executor)
        let permissions = try #require(await executor.permissionHandle())
        _ = try await backend.add(
            path: fixture.approved.path,
            workingDirectory: fixture.workspace,
            environment: fixture.environment
        )
        let target = fixture.approved.appendingPathComponent("identity.txt").path

        let ownerDecision = await permissions.request(
            access: .edit(target),
            toolName: "search_replace",
            toolCallId: "owner",
            sessionID: fixture.sessionID
        )
        let foreignDecision = await permissions.request(
            access: .edit(target),
            toolName: "search_replace",
            toolCallId: "foreign",
            sessionID: "unrelated-session"
        )
        let anonymousDecision = await permissions.request(
            access: .edit(target),
            toolName: "search_replace",
            toolCallId: "anonymous"
        )
        #expect(ownerDecision.isAllow)
        #expect(!foreignDecision.isAllow)
        #expect(!anonymousDecision.isAllow)

        do {
            _ = try await backend.add(
                path: fixture.outside.path,
                workingDirectory: fixture.outside,
                environment: fixture.environment
            )
            Issue.record("a foreign workspace reused session authority")
        } catch {}

        var otherOwner = fixture.environment
        otherOwner["OPENGROK_HOME"] = fixture.outside.path
        do {
            _ = try await backend.add(
                path: fixture.outside.path,
                workingDirectory: fixture.workspace,
                environment: otherOwner
            )
            Issue.record("a foreign owner reused session authority")
        } catch {}
        #expect(executor.additionalWorkingDirectories() == [fixture.approved])
        await executor.shutdown()
    }

    @Test("shared root grants reach authenticated children without exposing child worktrees")
    func authenticatedChildInheritsOnlyTheSharedWorkingSet() async throws {
        let fixture = try LiveSessionWorkingDirectoryFixture()
        defer { fixture.dispose() }
        let rootExecutor = try await fixture.makeExecutor()
        let backend = try await fixture.makeBackend(executor: rootExecutor)
        _ = try await backend.add(
            path: fixture.approved.path,
            workingDirectory: fixture.workspace,
            environment: fixture.environment
        )
        let childWorkspace = fixture.root.appendingPathComponent("child-worktree")
        try FileManager.default.createDirectory(at: childWorkspace, withIntermediateDirectories: true)
        let childID = "authenticated-child-\(UUID().uuidString)"
        let child = try await fixture.makeExecutor(
            sessionID: childID,
            workspace: childWorkspace,
            inheritedPermissionHandle: try #require(await rootExecutor.permissionHandle()),
            authorizationScope: rootExecutor.resourceAuthorizationScope
        )

        #expect(child.resourceAuthorizationScope === rootExecutor.resourceAuthorizationScope)
        #expect(child.mcpToolset.resources.allowedRoots.contains(fixture.approved.path))
        #expect(child.mcpToolset.resources.allowedRoots.contains(childWorkspace.path))
        #expect(!rootExecutor.mcpToolset.resources.allowedRoots.contains(childWorkspace.path))

        _ = try await backend.remove(
            path: fixture.approved.path,
            workingDirectory: fixture.workspace,
            environment: fixture.environment
        )
        #expect(!child.mcpToolset.resources.allowedRoots.contains(fixture.approved.path))
        await child.shutdown()
        await rootExecutor.shutdown()
    }

    @Test("an enforced operating-system sandbox never silently expands outside its workspace")
    func enforcedSandboxRejectsExternalRootsAndRollsBackPersistence() async throws {
        let fixture = try LiveSessionWorkingDirectoryFixture()
        defer { fixture.dispose() }
        let executor = try await fixture.makeExecutor(
            sandbox: LiveSandboxDecision(
                profileName: "workspace",
                mode: .restricted,
                enforced: true
            )
        )
        let backend = try await fixture.makeBackend(executor: executor)

        do {
            _ = try await backend.add(
                path: fixture.approved.path,
                workingDirectory: fixture.workspace,
                environment: fixture.environment
            )
            Issue.record("a process-wide sandbox was widened after activation")
        } catch {}

        #expect(executor.additionalWorkingDirectories().isEmpty)
        let persisted = try SessionWorkingDirectoriesStore(
            grokHome: fixture.state,
            sessionID: fixture.sessionID,
            workingDirectory: fixture.workspace
        )
        #expect(try persisted.load().isEmpty)
        await executor.shutdown()
    }

    @Test("a symlink inside an approved root cannot escape to an unapproved sibling")
    func approvedRootDoesNotAuthorizeSymlinkEscape() async throws {
        #if !os(Windows)
        let fixture = try LiveSessionWorkingDirectoryFixture()
        defer { fixture.dispose() }
        let executor = try await fixture.makeExecutor()
        let backend = try await fixture.makeBackend(executor: executor)
        let secret = fixture.outside.appendingPathComponent("secret.txt")
        try "external secret".write(to: secret, atomically: true, encoding: .utf8)
        let escape = fixture.approved.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: fixture.outside)
        _ = try await backend.add(
            path: fixture.approved.path,
            workingDirectory: fixture.workspace,
            environment: fixture.environment
        )

        guard case .failure = await fixture.invokeRead(
            executor: executor,
            path: escape.appendingPathComponent("secret.txt")
        ) else {
            Issue.record("an approved root followed a symlink outside its boundary")
            await executor.shutdown()
            return
        }
        await executor.shutdown()
        #endif
    }

    @Test("registry teardown synchronously revokes session and inherited child scope")
    func registryTeardownRevokesScopeAndRefusesFutureMutations() async throws {
        let fixture = try LiveSessionWorkingDirectoryFixture()
        defer { fixture.dispose() }
        let executor = try await fixture.makeExecutor()
        let backend = try await fixture.makeBackend(executor: executor)
        let registry = LiveSessionWorkingDirectoryRegistry()
        try await registry.register(backend)
        _ = try await registry.add(
            path: fixture.approved.path,
            sessionID: fixture.sessionID,
            workingDirectory: fixture.workspace,
            environment: fixture.environment
        )

        try await registry.unregister(sessionID: fixture.sessionID)

        #expect(executor.additionalWorkingDirectories().isEmpty)
        #expect(await registry.backend(sessionID: fixture.sessionID) == nil)
        do {
            _ = try await registry.add(
                path: fixture.approved.path,
                sessionID: fixture.sessionID,
                workingDirectory: fixture.workspace,
                environment: fixture.environment
            )
            Issue.record("an unregistered session retained its working-directory backend")
        } catch {}
        await executor.shutdown()
    }

    @Test("missing paths, the session root, and filesystem root cannot widen scope")
    func invalidDirectoryRootsFailClosed() async throws {
        let fixture = try LiveSessionWorkingDirectoryFixture()
        defer { fixture.dispose() }
        let executor = try await fixture.makeExecutor()
        let backend = try await fixture.makeBackend(executor: executor)

        for rejected in ["", fixture.workspace.path, "/", fixture.root.appendingPathComponent("missing").path] {
            do {
                _ = try await backend.add(
                    path: rejected,
                    workingDirectory: fixture.workspace,
                    environment: fixture.environment
                )
                Issue.record("unsafe working directory was accepted: \(rejected)")
            } catch {}
        }

        #expect(executor.additionalWorkingDirectories().isEmpty)
        await executor.shutdown()
    }
}
