import Foundation
import OpenGrokConfig
import Testing
@testable import OpenGrokWorkspace

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private struct ProjectPermissionApprovalFixture {
    let root: URL
    let ownerHome: URL
    let stateHome: URL
    let repository: URL
    let nested: URL
    let otherRepository: URL
    let environment: [String: String]

    init() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-project-permissions-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        root = temporaryRoot.standardizedFileURL.resolvingSymlinksInPath()
        ownerHome = root.appendingPathComponent("owner", isDirectory: true)
        stateHome = ownerHome.appendingPathComponent(".opengrok", isDirectory: true)
        repository = root.appendingPathComponent("repository", isDirectory: true)
        nested = repository.appendingPathComponent("nested/deeper", isDirectory: true)
        otherRepository = root.appendingPathComponent("other-repository", isDirectory: true)

        for directory in [ownerHome, stateHome, nested, otherRepository] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try Self.initializeRepository(repository)
        try Self.initializeRepository(otherRepository)

        environment = [
            "HOME": ownerHome.path,
            "OPENGROK_HOME": stateHome.path,
        ]
    }

    func dispose() {
        try? FileManager.default.removeItem(at: root)
    }

    func permissions(
        at workingDirectory: URL? = nil,
        remember: Bool = true,
        config: PermissionConfig = PermissionConfig(),
        clientIdentifier: String? = nil
    ) async throws -> PermissionHandle {
        let directory = workingDirectory ?? repository
        let permissions = PermissionHandle(
            config: config,
            shellCwd: directory.path,
            rememberToolApprovals: remember
        )
        try await permissions.configureProjectApprovalPersistence(
            workingDirectory: directory,
            openGrokHome: stateHome,
            environment: environment,
            clientIdentifier: clientIdentifier
        )
        return permissions
    }

    static func initializeRepository(_ directory: URL) throws {
        let git = directory.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(
            at: git,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try "ref: refs/heads/main\n".write(
            to: git.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
    }

    func writeState(_ contents: String, directory: URL? = nil) throws -> URL {
        let stateDirectory = directory ?? sessionsCwdDir(repository.path, environment: environment)
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: stateDirectory.deletingLastPathComponent().path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: stateDirectory.path
        )
        let document = stateDirectory.appendingPathComponent("permission.toml")
        try contents.write(to: document, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: document.path
        )
        return document
    }
}

@Suite("owner-private Rust-compatible project permission persistence")
struct ProjectPermissionApprovalPersistenceParityTests {
    @Test("configuration is read-only and remembered approvals default to disabled")
    func readOnlyConfigurationDoesNotCreateProjectState() async throws {
        let fixture = try ProjectPermissionApprovalFixture()
        defer { fixture.dispose() }

        let permissions = try await fixture.permissions(remember: false)
        let stateURL = try #require(await permissions.projectApprovalStateURL)

        #expect(stateURL.lastPathComponent == "permission.toml")
        #expect(!FileManager.default.fileExists(atPath: stateURL.path))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.stateHome.appendingPathComponent("sessions").path
        ))
        let accepted = await permissions.grant(SessionGrant(
            access: .bash("project-audit inspect"),
            scope: .project
        ))
        #expect(!accepted)
        #expect(!FileManager.default.fileExists(atPath: stateURL.path))
    }

    @Test("bash, domain, and exact MCP approvals survive a real permission-handle restart")
    func persistedApprovalsAuthorizeActualRequestsAfterRestart() async throws {
        let fixture = try ProjectPermissionApprovalFixture()
        defer { fixture.dispose() }
        let first = try await fixture.permissions()

        let bashApproved = await first.grant(SessionGrant(
            access: .bash("project-audit inspect"),
            scope: .project,
            pattern: "project-audit inspect"
        ))
        let fetchApproved = await first.grant(SessionGrant(
            access: .webFetch("https://docs.example.com/reference"),
            scope: .project,
            pattern: "docs.example.com"
        ))
        let mcpApproved = await first.grant(SessionGrant(
            access: .mcpTool(name: "notion__fetch", input: .null),
            scope: .project,
            pattern: "notion__fetch"
        ))
        #expect(bashApproved)
        #expect(fetchApproved)
        #expect(mcpApproved)

        let stateURL = try #require(await first.projectApprovalStateURL)
        let document = try parseTOML(Data(contentsOf: stateURL))
        #expect(document["edit_policy"]?.stringValue == "ask")
        #expect(document["allowed_bash_commands"]?.arrayValue == [.string("project-audit inspect")])
        #expect(document["allowed_web_fetch_domains"]?.arrayValue == [.string("docs.example.com")])
        #expect(document["allowed_mcp_tools"]?.arrayValue == [.string("notion__fetch")])
        #expect(document["validated_mcp_server_grants_version"]?.int64Value == 1)

        #if !os(Windows)
        let attributes = try FileManager.default.attributesOfItem(atPath: stateURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let parent = try FileManager.default.attributesOfItem(
            atPath: stateURL.deletingLastPathComponent().path
        )
        #expect((parent[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #endif

        let resumed = try await fixture.permissions()
        let bash = await resumed.request(
            access: .bash("project-audit inspect"),
            toolName: "run_terminal_command",
            toolCallId: "persisted-bash"
        )
        let fetch = await resumed.request(
            access: .webFetch("https://sub.docs.example.com/next"),
            toolName: "web_fetch",
            toolCallId: "persisted-fetch"
        )
        let mcp = await resumed.request(
            access: .mcpTool(name: "notion__fetch", input: .null),
            toolName: "notion__fetch",
            toolCallId: "persisted-mcp"
        )
        let differentTool = await resumed.request(
            access: .mcpTool(name: "notion__delete", input: .null),
            toolName: "notion__delete",
            toolCallId: "persisted-mcp-other"
        )

        #expect(bash == .allow)
        #expect(fetch == .allow)
        #expect(mcp == .allow)
        #expect(!differentTool.isAllow)
    }

    @Test("git-root and nested sessions share approvals without leaking into another project")
    func gitRootSharesWithSubdirectoriesOnly() async throws {
        let fixture = try ProjectPermissionApprovalFixture()
        defer { fixture.dispose() }
        let nested = try await fixture.permissions(at: fixture.nested)
        let accepted = await nested.grant(SessionGrant(
            access: .bash("project-audit inspect"),
            scope: .project
        ))
        #expect(accepted)

        let root = try await fixture.permissions()
        let other = try await fixture.permissions(at: fixture.otherRepository)
        #expect(await nested.projectApprovalStateURL == root.projectApprovalStateURL)
        #expect(await root.projectApprovalStateURL != other.projectApprovalStateURL)

        let shared = await root.request(
            access: .bash("project-audit inspect"),
            toolName: "bash",
            toolCallId: "repo-root"
        )
        let isolated = await other.request(
            access: .bash("project-audit inspect"),
            toolName: "bash",
            toolCallId: "other-root"
        )
        #expect(shared == .allow)
        #expect(!isolated.isAllow)
    }

    @Test("linked git worktrees remain distinct approval scopes")
    func linkedWorktreeDoesNotInheritMainWorktreeApprovals() async throws {
        let fixture = try ProjectPermissionApprovalFixture()
        defer { fixture.dispose() }
        let worktree = fixture.root.appendingPathComponent("linked-worktree", isDirectory: true)
        let metadata = fixture.repository
            .appendingPathComponent(".git/worktrees/linked", isDirectory: true)
        for directory in [worktree, metadata] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try "gitdir: \(metadata.path)\n".write(
            to: worktree.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )
        try "../..\n".write(
            to: metadata.appendingPathComponent("commondir"),
            atomically: true,
            encoding: .utf8
        )
        try "ref: refs/heads/feature\n".write(
            to: metadata.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )

        let main = try await fixture.permissions()
        let accepted = await main.grant(SessionGrant(
            access: .bash("project-audit inspect"),
            scope: .project
        ))
        #expect(accepted)

        let linked = try await fixture.permissions(at: worktree)
        let decision = await linked.request(
            access: .bash("project-audit inspect"),
            toolName: "bash",
            toolCallId: "linked-worktree"
        )
        #expect(await main.projectApprovalStateURL != linked.projectApprovalStateURL)
        #expect(!decision.isAllow)
    }

    @Test("a dotfiles repository at HOME remains keyed to each working directory")
    func homeRepositoryDoesNotShareEverySubdirectory() async throws {
        let fixture = try ProjectPermissionApprovalFixture()
        defer { fixture.dispose() }
        try ProjectPermissionApprovalFixture.initializeRepository(fixture.ownerHome)
        let firstDirectory = fixture.ownerHome.appendingPathComponent("first", isDirectory: true)
        let secondDirectory = fixture.ownerHome.appendingPathComponent("second", isDirectory: true)
        for directory in [firstDirectory, secondDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let first = try await fixture.permissions(at: firstDirectory)
        let approved = await first.grant(SessionGrant(
            access: .bash("project-audit inspect"),
            scope: .project
        ))
        #expect(approved)

        let second = try await fixture.permissions(at: secondDirectory)
        let decision = await second.request(
            access: .bash("project-audit inspect"),
            toolName: "bash",
            toolCallId: "dotfiles-other"
        )
        #expect(await first.projectApprovalStateURL != second.projectApprovalStateURL)
        #expect(!decision.isAllow)
    }

    @Test("disabled settings never activate persisted approvals but persisted denials still bind")
    func disabledApprovalsRetainOnlyDurableDenies() async throws {
        let fixture = try ProjectPermissionApprovalFixture()
        defer { fixture.dispose() }
        let enabled = try await fixture.permissions()
        let approved = await enabled.grant(SessionGrant(
            access: .bash("project-audit inspect"),
            scope: .project
        ))
        #expect(approved)
        await enabled.disallowBashPrefix("project-audit blocked")

        let disabled = try await fixture.permissions(remember: false)
        let remembered = await disabled.request(
            access: .bash("project-audit inspect"),
            toolName: "bash",
            toolCallId: "disabled-approval"
        )
        let denied = await disabled.request(
            access: .bash("project-audit blocked"),
            toolName: "bash",
            toolCallId: "disabled-deny"
        )
        #expect(!remembered.isAllow)
        #expect(!denied.isAllow)
        #expect(await disabled.sessionGrants.isEmpty)
        #expect(await disabled.bashDisallows.contains("project-audit blocked"))
    }

    @Test("managed ask and deny remain binding over project-durable approvals", arguments: ["ask", "deny"])
    func managedPolicyAlwaysBeatsPersistedApprovals(_ action: String) async throws {
        let fixture = try ProjectPermissionApprovalFixture()
        defer { fixture.dispose() }
        let initial = try await fixture.permissions()
        let accepted = await initial.grant(SessionGrant(
            access: .bash("project-audit inspect"),
            scope: .project
        ))
        #expect(accepted)

        let managedAction: RuleAction = action == "ask" ? .ask : .deny
        let managed = try await fixture.permissions(config: PermissionConfig(rules: [
            PermissionRule(
                action: managedAction,
                tool: .bash,
                pattern: "project-audit inspect",
                source: .managedSettings
            ),
        ]))
        let decision = await managed.request(
            access: .bash("project-audit inspect"),
            toolName: "bash",
            toolCallId: "managed-\(action)"
        )
        #expect(!decision.isAllow)
        #expect(await managed.lastMatchedRuleSource == .managedSettings)
    }

    @Test("edit-session and one-shot approvals never become durable project grants")
    func editsAndSingleUseApprovalsCannotSurviveRestart() async throws {
        let fixture = try ProjectPermissionApprovalFixture()
        defer { fixture.dispose() }
        let first = try await fixture.permissions()
        let rejectedEdit = await first.grant(SessionGrant(
            access: .edit(fixture.repository.appendingPathComponent("secret.swift").path),
            scope: .project
        ))
        #expect(!rejectedEdit)

        let sessionEdit = await first.grant(SessionGrant(
            access: .edit(fixture.repository.appendingPathComponent("safe.swift").path),
            scope: .session
        ))
        let singleUse = await first.grant(SessionGrant(
            access: .bash("project-audit inspect"),
            scope: .once
        ))
        #expect(sessionEdit)
        #expect(singleUse)
        #expect(await first.allowEditsForSession)
        let document = try #require(await first.projectApprovalStateURL)
        #expect(!FileManager.default.fileExists(atPath: document.path))

        let resumed = try await fixture.permissions()
        #expect(await resumed.allowEditsForSession == false)
        let edit = await resumed.request(
            access: .edit(fixture.repository.appendingPathComponent("safe.swift").path),
            toolName: "search_replace",
            toolCallId: "resumed-edit"
        )
        #expect(!edit.isAllow)
    }

    @Test("reset revokes persisted grants and prevents stale legacy documents from reviving them")
    func resetLeavesAnAuthoritativeEmptyProjectDocument() async throws {
        let fixture = try ProjectPermissionApprovalFixture()
        defer { fixture.dispose() }
        let legacy = sessionsCwdDir(fixture.nested.path, environment: fixture.environment)
        let legacyDocument = try fixture.writeState("""
        edit_policy = "allow"
        allowed_bash_commands = ["project-audit legacy"]
        """, directory: legacy)

        let initial = try await fixture.permissions(at: fixture.nested)
        let legacyDecision = await initial.request(
            access: .bash("project-audit legacy"),
            toolName: "bash",
            toolCallId: "legacy-before-reset"
        )
        #expect(legacyDecision == .allow)
        #expect(await initial.allowEditsForSession == false)

        await initial.resetState()
        #expect(FileManager.default.fileExists(atPath: legacyDocument.path))

        let restarted = try await fixture.permissions(at: fixture.nested)
        let revoked = await restarted.request(
            access: .bash("project-audit legacy"),
            toolName: "bash",
            toolCallId: "legacy-after-reset"
        )
        #expect(!revoked.isAllow)
        #expect(await restarted.sessionGrants.isEmpty)
    }

    @Test("simultaneous project sessions merge remembered approvals rather than erasing each other")
    func concurrentSessionSnapshotsMergeOnPersist() async throws {
        let fixture = try ProjectPermissionApprovalFixture()
        defer { fixture.dispose() }
        let first = try await fixture.permissions()
        let second = try await fixture.permissions(at: fixture.nested)

        let firstAccepted = await first.grant(SessionGrant(
            access: .bash("project-audit first"),
            scope: .project
        ))
        let secondAccepted = await second.grant(SessionGrant(
            access: .bash("project-audit second"),
            scope: .project
        ))
        #expect(firstAccepted)
        #expect(secondAccepted)

        let resumed = try await fixture.permissions()
        let firstDecision = await resumed.request(
            access: .bash("project-audit first"),
            toolName: "bash",
            toolCallId: "merged-first"
        )
        let secondDecision = await resumed.request(
            access: .bash("project-audit second"),
            toolName: "bash",
            toolCallId: "merged-second"
        )
        #expect(firstDecision == .allow)
        #expect(secondDecision == .allow)
    }

    @Test("client identifiers are sanitized and scoped without allowing path traversal")
    func clientSpecificDocumentsRemainIsolated() async throws {
        let fixture = try ProjectPermissionApprovalFixture()
        defer { fixture.dispose() }
        let first = try await fixture.permissions(clientIdentifier: "editor/../../one")
        let accepted = await first.grant(SessionGrant(
            access: .bash("project-audit inspect"),
            scope: .project
        ))
        #expect(accepted)
        let firstURL = try #require(await first.projectApprovalStateURL)
        #expect(firstURL.lastPathComponent == "permission_editor_______one.toml")

        let second = try await fixture.permissions(clientIdentifier: "other-client")
        let denied = await second.request(
            access: .bash("project-audit inspect"),
            toolName: "bash",
            toolCallId: "different-client"
        )
        #expect(!denied.isAllow)
    }

    @Test("legacy unvalidated server-wide MCP grants are never activated")
    func legacyMCPServerGrantsFailClosed() async throws {
        let fixture = try ProjectPermissionApprovalFixture()
        defer { fixture.dispose() }
        let document = try fixture.writeState("""
        allowed_mcp_servers = ["notion"]
        allowed_mcp_tools = ["notion__read"]
        """)

        let permissions = try await fixture.permissions()
        let exact = await permissions.request(
            access: .mcpTool(name: "notion__read", input: .null),
            toolName: "notion__read",
            toolCallId: "legacy-exact"
        )
        let broad = await permissions.request(
            access: .mcpTool(name: "notion__delete", input: .null),
            toolName: "notion__delete",
            toolCallId: "legacy-broad"
        )
        #expect(FileManager.default.fileExists(atPath: document.path))
        #expect(exact == .allow)
        #expect(!broad.isAllow)
    }

    @Test("validated server grants require exactly one non-overlapping qualified-ID delimiter")
    func validatedServerGrantsRejectMalformedMCPNames() async throws {
        let fixture = try ProjectPermissionApprovalFixture()
        defer { fixture.dispose() }
        try fixture.writeState("""
        allowed_mcp_servers = ["notion"]
        validated_mcp_server_grants_version = 1
        """)

        let permissions = try await fixture.permissions()
        let allowed = await permissions.request(
            access: .mcpTool(name: "notion__read", input: .null),
            toolName: "notion__read",
            toolCallId: "validated-server"
        )
        let malformed = await permissions.request(
            access: .mcpTool(name: "notion___read", input: .null),
            toolName: "notion___read",
            toolCallId: "overlap-server"
        )
        #expect(allowed == .allow)
        #expect(!malformed.isAllow)
    }

    @Test("hostile state documents fail closed", arguments: ["symlink", "hardlink", "public", "malformed"])
    func insecurePermissionDocumentsNeverAuthorize(_ attack: String) async throws {
        #if !os(Windows)
        let fixture = try ProjectPermissionApprovalFixture()
        defer { fixture.dispose() }
        let document = try fixture.writeState("""
        allowed_bash_commands = ["project-audit inspect"]
        """)

        switch attack {
        case "symlink":
            let target = fixture.root.appendingPathComponent("attacker-state")
            try FileManager.default.moveItem(at: document, to: target)
            try FileManager.default.createSymbolicLink(at: document, withDestinationURL: target)
        case "hardlink":
            try FileManager.default.linkItem(
                at: document,
                to: fixture.root.appendingPathComponent("attacker-hardlink")
            )
        case "public":
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: document.path
            )
        case "malformed":
            try "allowed_bash_commands = [true]\n".write(
                to: document,
                atomically: true,
                encoding: .utf8
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: document.path
            )
        default:
            Issue.record("unknown hostile document fixture")
            return
        }

        do {
            _ = try await fixture.permissions()
            Issue.record("hostile \(attack) permission document was accepted")
        } catch {}
        #endif
    }

    @Test("symlinked state roots are rejected without creating files outside the owner boundary")
    func symlinkedSessionDirectoryFailsClosed() async throws {
        #if !os(Windows)
        let fixture = try ProjectPermissionApprovalFixture()
        defer { fixture.dispose() }
        let attacker = fixture.root.appendingPathComponent("attacker", isDirectory: true)
        try FileManager.default.createDirectory(at: attacker, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: fixture.stateHome.appendingPathComponent("sessions"),
            withDestinationURL: attacker
        )

        do {
            _ = try await fixture.permissions()
            Issue.record("symlinked permission root was accepted")
        } catch {}
        #expect(try FileManager.default.contentsOfDirectory(atPath: attacker.path).isEmpty)
        #endif
    }

    @Test("dangerous shells, wildcard domains, and edit grants cannot be persisted")
    func projectApprovalInputsFailClosed() async throws {
        let fixture = try ProjectPermissionApprovalFixture()
        defer { fixture.dispose() }
        let permissions = try await fixture.permissions()

        let dangerous = await permissions.grant(SessionGrant(
            access: .bash("python -c 'print(1)'"),
            scope: .project
        ))
        let broadDomain = await permissions.grant(SessionGrant(
            access: .webFetch("https://trusted.example/path"),
            scope: .project,
            pattern: "example"
        ))
        let editing = await permissions.grant(SessionGrant(
            access: .edit("/outside/secret"),
            scope: .project
        ))

        #expect(!dangerous)
        #expect(!broadDomain)
        #expect(!editing)
        let path = try #require(await permissions.projectApprovalStateURL)
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }
}
