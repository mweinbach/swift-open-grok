import Foundation
import OpenGrokACP
import OpenGrokACPRuntime
import OpenGrokConfig
import OpenGrokPagerRender
import OpenGrokShared
import OpenGrokWorkspace
import Testing
@testable import OpenGrokCLI

private actor RememberedPermissionReverseClient: ACPPermissionReverseClient {
    private var responses: [RequestPermissionResponse]
    private var requests: [RequestPermissionRequest] = []

    init(_ optionIDs: [String]) {
        responses = optionIDs.map { optionID in
            RequestPermissionResponse(outcome: .selected(
                SelectedPermissionOutcome(optionId: PermissionOptionId(optionID))
            ))
        }
    }

    func requestClient(method: String, params: JSONValue) async throws -> JSONValue {
        guard method == ClientMethodNames.sessionRequestPermission else {
            throw ACPRuntimeError.transport("unexpected reverse request")
        }
        requests.append(try params.decode(RequestPermissionRequest.self))
        guard !responses.isEmpty else {
            throw ACPRuntimeError.transport("no remembered-permission response remains")
        }
        return try JSONValue.encode(responses.removeFirst())
    }

    func requestCount() -> Int { requests.count }

    func optionIDs(at index: Int = 0) -> [String] {
        guard requests.indices.contains(index) else { return [] }
        return requests[index].options.map { $0.optionId.rawValue }
    }

    func sessionIDs() -> [String] {
        requests.map { $0.sessionId.rawValue }
    }
}

@Suite("live ACP remembered approvals never widen shell or session authority")
struct LiveRememberedPermissionParityTests {
    @Test("an actual ACP always-allow decision survives a new project session")
    func actualACPApprovalPersistsAndRestoresProjectGrant() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-project-approval-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let home = root.appendingPathComponent("state", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let environment = ["HOME": root.path, "OPENGROK_HOME": home.path]

        let permissions = PermissionHandle(
            shellCwd: workspace.path,
            rememberToolApprovals: true
        )
        try await permissions.configureProjectApprovalPersistence(
            workingDirectory: workspace,
            openGrokHome: home,
            environment: environment,
            clientIdentifier: nil
        )
        let client = RememberedPermissionReverseClient(["always-allow"])
        let prompter = LiveACPPermissionPrompter(
            client: client,
            sessionId: AcpSessionId("first-project-session"),
            timeoutSeconds: 5,
            rememberToolApprovals: true
        )
        await prompter.attachPermissionHandle(permissions)

        let decision = await prompter.prompt(
            access: .bash("project-audit inspect"),
            toolName: "bash",
            toolCallId: "persisted-acp-approval"
        )
        #expect(decision == .allow)

        let file = try #require(await permissions.projectApprovalStateURL)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #if !os(Windows)
        let permissionsMode = try #require(
            FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
                as? NSNumber
        )
        #expect((permissionsMode.intValue & 0o777) == 0o600)
        #endif

        let restarted = PermissionHandle(
            shellCwd: workspace.path,
            rememberToolApprovals: true
        )
        try await restarted.configureProjectApprovalPersistence(
            workingDirectory: workspace,
            openGrokHome: home,
            environment: environment,
            clientIdentifier: nil
        )
        #expect(await restarted.sessionGrants.contains {
            $0.scope == .project && $0.pattern == "project-audit inspect"
        })
        let restored = await restarted.request(
            access: .bash("project-audit inspect --json"),
            toolName: "bash",
            toolCallId: "restored-acp-approval"
        )
        #expect(restored == .allow)
    }

    @Test("the actual pager persists approved commands but never session-only edits")
    func actualPagerApprovalPersistsCommandsWithoutPersistingEdits() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-pager-project-approval-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let home = root.appendingPathComponent("state", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let environment = ["HOME": root.path, "OPENGROK_HOME": home.path]

        let permissions = PermissionHandle(
            shellCwd: workspace.path,
            rememberToolApprovals: true
        )
        try await permissions.configureProjectApprovalPersistence(
            workingDirectory: workspace,
            openGrokHome: home,
            environment: environment,
            clientIdentifier: nil
        )
        let sessionPolicy = LiveSessionWritePolicy()
        await sessionPolicy.attachProjectPermissionHandle(permissions)
        let coordinator = PagerPermissionCoordinator()
        await coordinator.setPresenter { request in
            guard let request else { return }
            await coordinator.resolve(requestID: request.id, decision: .allowSession)
        }
        let prompter = LivePermissionModalPrompter(
            coordinator: coordinator,
            sessionPolicy: sessionPolicy,
            rememberToolApprovals: true
        )
        let file = try #require(await permissions.projectApprovalStateURL)

        let edited = await prompter.prompt(
            access: .edit(workspace.appendingPathComponent("safe.swift").path),
            toolName: "search_replace",
            toolCallId: "session-only-edit"
        )
        #expect(edited == .allow)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        let approved = await prompter.prompt(
            access: .bash("project-audit inspect"),
            toolName: "bash",
            toolCallId: "durable-pager-command"
        )
        #expect(approved == .allow)
        #expect(FileManager.default.fileExists(atPath: file.path))

        let restarted = PermissionHandle(
            shellCwd: workspace.path,
            rememberToolApprovals: true
        )
        try await restarted.configureProjectApprovalPersistence(
            workingDirectory: workspace,
            openGrokHome: home,
            environment: environment,
            clientIdentifier: nil
        )
        #expect(await restarted.sessionGrants.contains {
            $0.scope == .project && $0.pattern == "project-audit inspect"
        })
        #expect(await restarted.allowEditsForSession == false)
    }

    @Test("remember disabled withholds persistent Bash choices and rejects forged selections")
    func disabledGateRefusesPersistentBashOption() async {
        let client = RememberedPermissionReverseClient(["always-allow"])
        let prompter = LiveACPPermissionPrompter(
            client: client,
            sessionId: AcpSessionId("remember-disabled"),
            timeoutSeconds: 5,
            rememberToolApprovals: false
        )

        let decision = await prompter.prompt(
            access: .bash("project-audit inspect"),
            toolName: "bash",
            toolCallId: "remember-disabled"
        )

        #expect(decision.isAllow == false)
        #expect(await client.optionIDs() == ["allow-once", "reject-once"])
    }

    @Test("allow-once never creates a reusable approval")
    func oneTimeApprovalAlwaysPromptsAgain() async {
        let client = RememberedPermissionReverseClient([
            "allow-once",
            "reject-once",
        ])
        let prompter = LiveACPPermissionPrompter(
            client: client,
            sessionId: AcpSessionId("allow-once"),
            timeoutSeconds: 5,
            rememberToolApprovals: true
        )

        let first = await prompter.prompt(
            access: .bash("project-audit inspect"),
            toolName: "bash",
            toolCallId: "allow-once-first"
        )
        let second = await prompter.prompt(
            access: .bash("project-audit inspect"),
            toolName: "bash",
            toolCallId: "allow-once-second"
        )

        #expect(first == .allow)
        #expect(second.isAllow == false)
        #expect(await client.requestCount() == 2)
    }

    @Test("remember disabled still exposes upstream's explicit edit-session choice")
    func editSessionChoiceRemainsAvailableWithoutPersistence() async {
        let client = RememberedPermissionReverseClient(["allow-edits-session"])
        let prompter = LiveACPPermissionPrompter(
            client: client,
            sessionId: AcpSessionId("edit-session"),
            timeoutSeconds: 5,
            rememberToolApprovals: false
        )

        let first = await prompter.prompt(
            access: .edit("/workspace/first.swift"),
            toolName: "search_replace",
            toolCallId: "edit-session-first"
        )
        let second = await prompter.prompt(
            access: .edit("/workspace/second.swift"),
            toolName: "search_replace",
            toolCallId: "edit-session-second"
        )

        #expect(first == .allow)
        #expect(second == .allow)
        #expect(await client.optionIDs().contains("allow-edits-session"))
        #expect(await client.requestCount() == 1)
    }

    @Test("enabled Bash approval remembers only the exact safe argv prefix")
    func rememberedBashApprovalIsCommandScoped() async {
        let client = RememberedPermissionReverseClient([
            "always-allow",
            "reject-once",
        ])
        let prompter = LiveACPPermissionPrompter(
            client: client,
            sessionId: AcpSessionId("bash-scope"),
            timeoutSeconds: 5,
            rememberToolApprovals: true
        )

        let first = await prompter.prompt(
            access: .bash("project-audit inspect"),
            toolName: "bash",
            toolCallId: "bash-scope-first"
        )
        let sameCommand = await prompter.prompt(
            access: .bash("project-audit inspect --json"),
            toolName: "bash",
            toolCallId: "bash-scope-same"
        )
        let differentCommand = await prompter.prompt(
            access: .bash("project-audit inspectevil"),
            toolName: "bash",
            toolCallId: "bash-scope-different"
        )

        #expect(first == .allow)
        #expect(sameCommand == .allow)
        #expect(differentCommand.isAllow == false)
        #expect(await client.requestCount() == 2)
    }

    @Test("remembered Bash approval never covers chained commands")
    func rememberedBashApprovalCannotHideChainedPayload() async {
        let client = RememberedPermissionReverseClient([
            "always-allow",
            "reject-once",
        ])
        let prompter = LiveACPPermissionPrompter(
            client: client,
            sessionId: AcpSessionId("bash-chain"),
            timeoutSeconds: 5,
            rememberToolApprovals: true
        )

        let approved = await prompter.prompt(
            access: .bash("project-audit inspect"),
            toolName: "bash",
            toolCallId: "bash-chain-approved"
        )
        let injected = await prompter.prompt(
            access: .bash("project-audit inspect; rm -rf /tmp/remembered-grant"),
            toolName: "bash",
            toolCallId: "bash-chain-injected"
        )

        #expect(approved == .allow)
        #expect(injected.isAllow == false)
        #expect(await client.requestCount() == 2)
    }

    @Test("dangerous shell commands never offer an always-allow row")
    func dangerousCommandsCannotMintPersistentApproval() async {
        let client = RememberedPermissionReverseClient(["always-allow"])
        let prompter = LiveACPPermissionPrompter(
            client: client,
            sessionId: AcpSessionId("dangerous"),
            timeoutSeconds: 5,
            rememberToolApprovals: true
        )

        let decision = await prompter.prompt(
            access: .bash("rm -rf /tmp/remembered-grant"),
            toolName: "bash",
            toolCallId: "dangerous-remember"
        )

        #expect(decision.isAllow == false)
        #expect(await client.optionIDs().contains("always-allow") == false)
        #expect(await client.optionIDs().contains("reject-always"))
    }

    @Test("explicit persistent denial is command-scoped and beats any remembered allow")
    func rememberedDenialDoesNotDenyUnrelatedCommands() async {
        let client = RememberedPermissionReverseClient([
            "reject-always",
            "allow-once",
        ])
        let prompter = LiveACPPermissionPrompter(
            client: client,
            sessionId: AcpSessionId("deny-scope"),
            timeoutSeconds: 5,
            rememberToolApprovals: true
        )

        let denied = await prompter.prompt(
            access: .bash("project-audit inspect"),
            toolName: "bash",
            toolCallId: "deny-scope-first"
        )
        let deniedAgain = await prompter.prompt(
            access: .bash("project-audit inspect --json"),
            toolName: "bash",
            toolCallId: "deny-scope-repeat"
        )
        let unrelated = await prompter.prompt(
            access: .bash("project-audit report"),
            toolName: "bash",
            toolCallId: "deny-scope-unrelated"
        )

        #expect(denied.isAllow == false)
        #expect(deniedAgain.isAllow == false)
        #expect(unrelated == .allow)
        #expect(await client.requestCount() == 2)
    }

    @Test("remembered grants never leak between ACP sessions")
    func grantsRemainBoundToTheApprovingSession() async {
        let client = RememberedPermissionReverseClient([
            "always-allow",
            "reject-once",
        ])
        let prompter = LiveACPPermissionPrompter(
            client: client,
            timeoutSeconds: 5,
            rememberToolApprovals: true
        )

        await prompter.bindSession(AcpSessionId("session-a"))
        let first = await prompter.prompt(
            access: .bash("project-audit inspect"),
            toolName: "bash",
            toolCallId: "session-a-approval"
        )
        await prompter.bindSession(AcpSessionId("session-b"))
        let other = await prompter.prompt(
            access: .bash("project-audit inspect"),
            toolName: "bash",
            toolCallId: "session-b-approval"
        )

        #expect(first == .allow)
        #expect(other.isAllow == false)
        #expect(await client.sessionIDs() == ["session-a", "session-b"])
    }

    @Test("disabling remembered approvals revokes session-local grants immediately")
    func disablingRememberedApprovalsRevokesLiveGrants() async {
        let client = RememberedPermissionReverseClient([
            "always-allow",
            "reject-once",
        ])
        let prompter = LiveACPPermissionPrompter(
            client: client,
            sessionId: AcpSessionId("revoke"),
            timeoutSeconds: 5,
            rememberToolApprovals: true
        )

        let first = await prompter.prompt(
            access: .bash("project-audit inspect"),
            toolName: "bash",
            toolCallId: "revoke-first"
        )
        await prompter.setRememberToolApprovals(false)
        let afterRevocation = await prompter.prompt(
            access: .bash("project-audit inspect"),
            toolName: "bash",
            toolCallId: "revoke-second"
        )

        #expect(first == .allow)
        #expect(afterRevocation.isAllow == false)
        #expect(await client.requestCount() == 2)
    }

    @Test("MCP approvals remain exact-tool scoped and cannot authorize web fetch")
    func rememberedMCPGrantCannotCrossAccessKinds() async {
        let client = RememberedPermissionReverseClient([
            "always-allow",
            "reject-once",
        ])
        let prompter = LiveACPPermissionPrompter(
            client: client,
            sessionId: AcpSessionId("mcp-scope"),
            timeoutSeconds: 5,
            rememberToolApprovals: true
        )

        let first = await prompter.prompt(
            access: .mcpTool(name: "server__inspect", input: .null),
            toolName: "mcp",
            toolCallId: "mcp-first"
        )
        let sameTool = await prompter.prompt(
            access: .mcpTool(name: "server__inspect", input: .object([:])),
            toolName: "mcp",
            toolCallId: "mcp-second"
        )
        let wrongKind = await prompter.prompt(
            access: .webFetch("server__inspect"),
            toolName: "web_fetch",
            toolCallId: "mcp-cross-kind"
        )

        #expect(first == .allow)
        #expect(sameTool == .allow)
        #expect(wrongKind.isAllow == false)
        #expect(await client.requestCount() == 2)
    }

    @Test("remembered web approvals match one exact URL, never its prefix or another host")
    func rememberedWebApprovalRemainsExactURLScoped() async {
        let client = RememberedPermissionReverseClient([
            "always-allow",
            "reject-once",
        ])
        let prompter = LiveACPPermissionPrompter(
            client: client,
            sessionId: AcpSessionId("web-scope"),
            timeoutSeconds: 5,
            rememberToolApprovals: true
        )

        let first = await prompter.prompt(
            access: .webFetch("https://example.com/safe"),
            toolName: "web_fetch",
            toolCallId: "web-scope-first"
        )
        let exactReplay = await prompter.prompt(
            access: .webFetch("https://example.com/safe"),
            toolName: "web_fetch",
            toolCallId: "web-scope-replay"
        )
        let extendedURL = await prompter.prompt(
            access: .webFetch("https://example.com/safe/private"),
            toolName: "web_fetch",
            toolCallId: "web-scope-extended"
        )

        #expect(first == .allow)
        #expect(exactReplay == .allow)
        #expect(extendedURL.isAllow == false)
        #expect(await client.requestCount() == 2)
    }

    @Test("new managed denies revoke already-remembered ACP approvals")
    func refreshedManagedDenyBeatsRememberedApproval() async {
        let command = "project-audit inspect"
        let client = RememberedPermissionReverseClient([
            "always-allow",
            "reject-once",
        ])
        let prompter = LiveACPPermissionPrompter(
            client: client,
            sessionId: AcpSessionId("managed-revoke"),
            timeoutSeconds: 5,
            rememberToolApprovals: true
        )
        let permissions = PermissionHandle(
            shellCwd: "/workspace",
            rememberToolApprovals: true
        )
        await prompter.attachPermissionHandle(permissions)

        let approved = await prompter.prompt(
            access: .bash(command),
            toolName: "bash",
            toolCallId: "managed-revoke-first"
        )
        await permissions.replaceConfig(PermissionConfig(rules: [
            PermissionRule(
                action: .deny,
                tool: .bash,
                pattern: command,
                source: .managedSettings
            ),
        ]))
        let denied = await prompter.prompt(
            access: .bash(command),
            toolName: "bash",
            toolCallId: "managed-revoke-second"
        )

        #expect(approved == .allow)
        #expect(denied.isAllow == false)
        #expect(await client.requestCount() == 2)
    }

    @Test("attached permission authority keeps managed shell-file asks prompt-required")
    func shellFileAskCannotBeBypassedByPrompterLocalGrant() async {
        let client = RememberedPermissionReverseClient([
            "always-allow",
            "reject-once",
        ])
        let prompter = LiveACPPermissionPrompter(
            client: client,
            sessionId: AcpSessionId("shell-file-floor"),
            timeoutSeconds: 5,
            rememberToolApprovals: true
        )
        let permissions = PermissionHandle(
            config: PermissionConfig(rules: [
                PermissionRule(action: .ask, tool: .read, pattern: "**/.env"),
            ]),
            shellCwd: "/workspace",
            rememberToolApprovals: true
        )
        await prompter.attachPermissionHandle(permissions)

        let first = await prompter.prompt(
            access: .bash("cat /workspace/.env"),
            toolName: "bash",
            toolCallId: "shell-file-first"
        )
        let second = await prompter.prompt(
            access: .bash("cat /workspace/.env"),
            toolName: "bash",
            toolCallId: "shell-file-second"
        )

        #expect(first == .allow)
        #expect(second.isAllow == false)
        #expect(await client.requestCount() == 2)
    }
}
