import Foundation
import Testing
@testable import OpenGrokWorkspace

private actor FoundationLockEvents {
    private var values: [String] = []

    func record(_ value: String) {
        values.append(value)
    }

    func snapshot() -> [String] {
        values
    }
}

private actor FoundationLockGate {
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func open() {
        isOpen = true
        waiter?.resume()
        waiter = nil
    }
}

private func waitForFoundationLockEvent(
    _ value: String,
    in events: FoundationLockEvents
) async -> Bool {
    for _ in 0..<200 {
        if await events.snapshot().contains(value) {
            return true
        }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return false
}

private func withFoundationSecurityDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("workspace-foundation-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try body(directory.resolvingSymlinksInPath())
}

@Suite("workspace managed policy preflight")
struct WorkspaceManagedPolicyPreflightTests {
    @Test("managed denies remain authoritative for allow-all handles")
    func managedDenyBeatsAllowAll() async {
        let handle = PermissionHandle(
            config: PermissionConfig(rules: [
                PermissionRule(action: .deny, tool: .read, pattern: "**/.env"),
            ]),
            allowAll: true,
            shellCwd: "/workspace"
        )

        let decision = await handle.request(
            access: .read("/workspace/.env"),
            toolName: "read_file",
            toolCallId: "managed-deny"
        )

        guard case .policyDeny = decision else {
            Issue.record("an allow-all handle must not bypass a managed deny: \(decision)")
            return
        }
    }

    @Test("broad Bash allowances cannot bypass denied file reads")
    func broadBashAllowCannotReadDeniedFile() async {
        let handle = PermissionHandle(
            config: PermissionConfig(rules: [
                PermissionRule(action: .allow, tool: .bash, pattern: nil),
                PermissionRule(action: .deny, tool: .read, pattern: "**/.env"),
            ]),
            shellCwd: "/workspace"
        )

        let decision = await handle.request(
            access: .bash("cat /workspace/.env"),
            toolName: "bash",
            toolCallId: "shell-read-deny"
        )

        guard case .policyDeny = decision else {
            Issue.record("Bash(*) must not expose a denied file: \(decision)")
            return
        }
    }

    @Test("broad Bash allowances cannot bypass denied shell redirects")
    func broadBashAllowCannotWriteDeniedFile() async {
        let handle = PermissionHandle(
            config: PermissionConfig(rules: [
                PermissionRule(action: .allow, tool: .bash, pattern: nil),
                PermissionRule(action: .deny, tool: .edit, pattern: "**/.env"),
            ]),
            shellCwd: "/workspace"
        )

        let decision = await handle.request(
            access: .bash("echo exposed > /workspace/.env"),
            toolName: "bash",
            toolCallId: "shell-write-deny"
        )

        guard case .policyDeny = decision else {
            Issue.record("Bash(*) must not bypass a denied redirect: \(decision)")
            return
        }
    }

    @Test("broad Bash allowances cannot bypass denied later command segments")
    func broadBashAllowCannotHideDeniedSegment() async {
        let handle = PermissionHandle(
            config: PermissionConfig(rules: [
                PermissionRule(action: .allow, tool: .bash, pattern: nil),
                PermissionRule(action: .deny, tool: .bash, pattern: "rm *"),
            ]),
            shellCwd: "/workspace"
        )

        let decision = await handle.request(
            access: .bash("echo safe && rm /workspace/important.txt"),
            toolName: "bash",
            toolCallId: "shell-segment-deny"
        )

        guard case .policyDeny = decision else {
            Issue.record("Bash(*) must not hide a denied later segment: \(decision)")
            return
        }
    }

    @Test("file ask floors remain binding under broad Bash and allow-all")
    func fileAskCannotBeAutoApproved() async {
        let handle = PermissionHandle(
            config: PermissionConfig(rules: [
                PermissionRule(action: .allow, tool: .bash, pattern: nil),
                PermissionRule(action: .ask, tool: .read, pattern: "**/.env"),
            ]),
            allowAll: true,
            shellCwd: "/workspace"
        )

        let decision = await handle.request(
            access: .bash("cat /workspace/.env"),
            toolName: "bash",
            toolCallId: "shell-read-ask"
        )

        guard case .reject = decision else {
            Issue.record("a managed ask must reach the fail-closed headless prompt: \(decision)")
            return
        }
        #expect(await handle.events.last?.decisionReason == "policy_ask")
    }

    @Test("managed YOLO pins disable the allow-all bypass")
    func yoloPinDisablesAllowAll() async {
        let handle = PermissionHandle(
            yoloPinReason: yoloPinReasonRequirements,
            allowAll: true,
            shellCwd: "/workspace"
        )

        #expect(await handle.allowAll == false)
        let decision = await handle.request(
            access: .bash("rm -rf /workspace"),
            toolName: "bash",
            toolCallId: "pinned-allow-all"
        )
        #expect(decision.isAllow == false)
    }
}

@Suite("workspace resource-lock queue")
struct WorkspaceResourceLockQueueTests {
    @Test("queued exclusive locks run before later path readers")
    func queuedExclusiveHasWriterPriority() async {
        let manager = PathResourceLockManager()
        let first = await manager.acquirePath("/workspace/first")
        let events = FoundationLockEvents()
        let writerGate = FoundationLockGate()

        let writer = Task {
            await events.record("writer-waiting")
            let token = await manager.acquireExclusive()
            await events.record("writer-acquired")
            await writerGate.wait()
            await token.release()
        }
        #expect(await waitForFoundationLockEvent("writer-waiting", in: events))
        await Task.yield()

        let laterReader = Task {
            await events.record("reader-waiting")
            let token = await manager.acquirePath("/workspace/second")
            await events.record("reader-acquired")
            await token.release()
        }
        #expect(await waitForFoundationLockEvent("reader-waiting", in: events))
        await Task.yield()
        #expect(await events.snapshot() == ["writer-waiting", "reader-waiting"])

        await first.release()
        #expect(await waitForFoundationLockEvent("writer-acquired", in: events))
        #expect(await events.snapshot().contains("reader-acquired") == false)

        await writerGate.open()
        #expect(await waitForFoundationLockEvent("reader-acquired", in: events))
        await writer.value
        await laterReader.value
    }

    @Test("an exclusive waiter also waits for active process resources")
    func exclusiveWaitsForProcessResource() async {
        let manager = PathResourceLockManager()
        let process = await manager.acquireProcess("running-process")
        let events = FoundationLockEvents()

        let writer = Task {
            await events.record("writer-waiting")
            let token = await manager.acquireExclusive()
            await events.record("writer-acquired")
            await token.release()
        }
        #expect(await waitForFoundationLockEvent("writer-waiting", in: events))
        await Task.yield()
        #expect(await events.snapshot() == ["writer-waiting"])

        await process.release()
        #expect(await waitForFoundationLockEvent("writer-acquired", in: events))
        await writer.value
    }

    @Test("existing and newly created files serialize through symlink aliases", arguments: [false, true])
    func symlinkAliasesShareResourceLocks(existingLeaf: Bool) async throws {
        #if !os(Windows)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-lock-alias-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let actual = directory.appendingPathComponent("actual")
        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        let actualFile = actual.appendingPathComponent("file.txt")
        if existingLeaf {
            try Data("existing".utf8).write(to: actualFile)
        }

        let manager = PathResourceLockManager()
        let first = await manager.acquirePath(actualFile.path)
        let events = FoundationLockEvents()
        let second = Task {
            await events.record("alias-waiting")
            let token = await manager.acquirePath(alias.appendingPathComponent("file.txt").path)
            await events.record("alias-acquired")
            await token.release()
        }

        #expect(await waitForFoundationLockEvent("alias-waiting", in: events))
        await Task.yield()
        #expect(await events.snapshot() == ["alias-waiting"])

        await first.release()
        #expect(await waitForFoundationLockEvent("alias-acquired", in: events))
        await second.value
        #endif
    }
}

@Suite("workspace durable folder-trust integrity")
struct WorkspaceDurableFolderTrustIntegrityTests {
    @Test("unsafe pretrusted roots cannot bypass trust-store registration checks")
    func unsafePretrustedRootsAreRejected() {
        let root = URL(fileURLWithPath: "/")
        guard let homePath = ProcessInfo.processInfo.environment["HOME"] else {
            let store = FolderTrustStore(trustedRoots: [root])
            #expect(store.state(for: root) == .untrusted)
            return
        }
        let home = URL(fileURLWithPath: homePath)
        let store = FolderTrustStore(trustedRoots: [root, home])

        #expect(store.state(for: root) == .untrusted)
        #expect(store.state(for: home) == .untrusted)
    }

    @Test("trust decisions canonicalize symlink aliases in both directions")
    func trustCanonicalizesAliases() throws {
        #if !os(Windows)
        try withFoundationSecurityDirectory { root in
            let repository = root.appendingPathComponent("repository")
            let alias = root.appendingPathComponent("alias")
            try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: repository)

            var exact = FolderTrustStore()
            exact.trust(alias)
            #expect(exact.state(for: repository) == .trusted)

            var store = PersistentFolderTrustStore(
                path: root.appendingPathComponent("trusted_folders.toml"),
                home: root.path
            )
            try store.record(alias, trusted: true)
            #expect(store.isTrusted(repository))
            #expect(store.isTrusted(alias))
        }
        #endif
    }

    @Test("an explicit child denial through a symlink overrides trusted parent cascade")
    func childDenialCannotBeBypassedThroughAlias() throws {
        #if !os(Windows)
        try withFoundationSecurityDirectory { root in
            let parent = root.appendingPathComponent("parent")
            let child = parent.appendingPathComponent("child")
            let alias = root.appendingPathComponent("child-alias")
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: child)

            var store = PersistentFolderTrustStore(
                path: root.appendingPathComponent("trusted_folders.toml"),
                home: root.path
            )
            try store.record(parent, trusted: true)
            try store.record(alias, trusted: false)

            #expect(store.isTrusted(parent))
            #expect(store.isTrusted(child) == false)
            #expect(store.isTrusted(alias) == false)
        }
        #endif
    }

    @Test("independently loaded trust writers preserve each other's decisions")
    func staleWritersMergeDurableDecisions() throws {
        try withFoundationSecurityDirectory { root in
            let storePath = root.appendingPathComponent("trusted_folders.toml")
            let firstRepository = root.appendingPathComponent("first")
            let secondRepository = root.appendingPathComponent("second")
            try FileManager.default.createDirectory(at: firstRepository, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: secondRepository, withIntermediateDirectories: true)

            var first = PersistentFolderTrustStore(path: storePath, home: root.path)
            var second = PersistentFolderTrustStore(path: storePath, home: root.path)
            try first.record(firstRepository, trusted: true)
            try second.record(secondRepository, trusted: true)

            let reloaded = PersistentFolderTrustStore(path: storePath, home: root.path)
            #expect(reloaded.isTrusted(firstRepository))
            #expect(reloaded.isTrusted(secondRepository))
        }
    }

    @Test("failed durable writes never publish a trust grant in memory")
    func failedWriteDoesNotGrantTrust() throws {
        try withFoundationSecurityDirectory { root in
            let storePath = root.appendingPathComponent("trusted_folders.toml")
            let repository = root.appendingPathComponent("repository")
            try FileManager.default.createDirectory(at: storePath, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)

            var store = PersistentFolderTrustStore(path: storePath, home: root.path)
            #expect(throws: (any Error).self) {
                try store.record(repository, trusted: true)
            }
            #expect(store.isTrusted(repository) == false)
        }
    }

    @Test("a trust store without a durable backing path never trusts")
    func missingBackingStoreDoesNotGrantTrust() throws {
        var store = PersistentFolderTrustStore(path: nil, home: "/home/user")
        try store.record(URL(fileURLWithPath: "/workspace/repository"), trusted: true)
        #expect(store.isTrusted(URL(fileURLWithPath: "/workspace/repository")) == false)
    }

    @Test("contradictory canonical trust aliases fail closed")
    func contradictoryAliasesFailClosed() throws {
        #if !os(Windows)
        try withFoundationSecurityDirectory { root in
            let repository = root.appendingPathComponent("repository")
            let alias = root.appendingPathComponent("alias")
            let storePath = root.appendingPathComponent("trusted_folders.toml")
            try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: repository)
            try Data("""
            [folders."\(repository.path)"]
            trusted = true

            [folders."\(alias.path)"]
            trusted = false
            """.utf8).write(to: storePath)

            let store = PersistentFolderTrustStore(path: storePath, home: root.path)
            #expect(store.isTrusted(repository) == false)
            #expect(store.isTrusted(alias) == false)
        }
        #endif
    }

    @Test("a symlink alias of the home directory cannot become a trusted root")
    func homeAliasCannotBeTrusted() throws {
        #if !os(Windows)
        try withFoundationSecurityDirectory { root in
            let home = root.appendingPathComponent("home")
            let alias = root.appendingPathComponent("home-alias")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: home)

            var store = PersistentFolderTrustStore(
                path: root.appendingPathComponent("trusted_folders.toml"),
                home: home.path
            )
            try store.record(alias, trusted: true)
            #expect(store.isTrusted(home) == false)
            #expect(store.isTrusted(alias) == false)
        }
        #endif
    }
}

@Suite("workspace sandbox-required fail-closed")
struct WorkspaceSandboxRequiredFailClosedTests {
    @Test("a required sandbox rejects non-sandbox isolation even with remote policy")
    func requiredSandboxRejectsUnconfinedPipeline() async {
        let pipeline = PermissionPipeline(
            permissions: PermissionHandle(allowAll: true),
            remotePolicyAvailable: true,
            requireSandbox: true,
            isolation: .none
        )

        let prepared = await pipeline.prepare(
            PrepareToolAccessRequest(
                access: .bash("cat /workspace/.env"),
                toolName: "bash",
                toolCallId: "unconfined-pipeline"
            )
        )

        #expect(prepared.source == .sandboxRequired)
        #expect(prepared.mayDispatch == false)
    }

    @Test("required sandbox rejects local process fallback from a worktree")
    func requiredSandboxRejectsUnconfinedProcess() async {
        let operations = LocalWorkspaceOps(
            config: WorkspaceConfig(
                root: URL(fileURLWithPath: "/workspace"),
                isolation: .worktree,
                permissionConfig: PermissionConfig(rules: [
                    PermissionRule(action: .allow, tool: .bash, pattern: nil),
                ]),
                requireSandbox: true
            ),
            remotePolicyAvailable: true
        )

        do {
            try await operations.authorizeProcess(
                ProcessSpawnRequest(command: "cat", arguments: [".env"], toolCallId: "unconfined-process")
            )
            Issue.record("a required sandbox must not be replaced with worktree isolation")
        } catch WorkspaceRuntimeError.sandboxRequired {
            // The enforcement boundary refuses before dispatch.
        } catch {
            Issue.record("unexpected failure while enforcing required sandbox: \(error)")
        }
    }
}
