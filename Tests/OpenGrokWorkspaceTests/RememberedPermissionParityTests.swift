import Foundation
import OpenGrokConfig
import Testing
@testable import OpenGrokWorkspace

@Suite("trusted remembered permission settings and session identity")
struct RememberedPermissionParityTests {
    @Test("permission settings default to no persistence and allow-once")
    func settingsDefaultToLeastPrivilege() {
        let settings = PermissionPromptSettings.resolve(
            document: nil,
            environment: [:]
        )

        #expect(settings.rememberToolApprovals == false)
        #expect(settings.defaultSelectedPermission == "allow_once")
    }

    @Test("trusted requirements override inherited environment and user settings")
    func requirementPinsBeatUserAndEnvironment() throws {
        let user = try parseTOML("""
        [ui]
        remember_tool_approvals = true
        default_selected_permission = "allow_command_always"
        """)
        let requirement = try parseTOML("""
        [ui]
        remember_tool_approvals = false
        default_selected_permission = "reject"
        """)

        let settings = PermissionPromptSettings.resolve(
            document: user,
            requirements: [requirement],
            environment: [
                "GROK_REMEMBER_TOOL_APPROVALS": "1",
                "GROK_DEFAULT_SELECTED_PERMISSION": "allow_once",
            ],
            remoteRememberToolApprovals: true
        )

        #expect(settings.rememberToolApprovals == false)
        #expect(settings.defaultSelectedPermission == "reject")
    }

    @Test("environment overrides effective user settings below requirement authority")
    func environmentOverridesUnpinnedUserSettings() throws {
        let user = try parseTOML("""
        [ui]
        remember_tool_approvals = false
        default_selected_permission = "reject"
        """)

        let settings = PermissionPromptSettings.resolve(
            document: user,
            environment: [
                "GROK_REMEMBER_TOOL_APPROVALS": "true",
                "GROK_DEFAULT_SELECTED_PERMISSION": "ALLOW-ONCE",
            ]
        )

        #expect(settings.rememberToolApprovals)
        #expect(settings.defaultSelectedPermission == "allow_once")
    }

    @Test("malformed trusted values fail closed instead of widening approval")
    func malformedSettingsFailClosed() throws {
        let malformed = try parseTOML("""
        [ui]
        remember_tool_approvals = "true"
        default_selected_permission = "grant_everything"
        """)

        let settings = PermissionPromptSettings.resolve(
            document: malformed,
            environment: [:],
            remoteRememberToolApprovals: true
        )

        #expect(settings.rememberToolApprovals == false)
        #expect(settings.defaultSelectedPermission == "allow_once")
    }

    @Test("remembered grants satisfy an explicit ask only when the trusted gate is enabled")
    func explicitAskRespectsRememberGate() async {
        let command = "project-audit inspect"
        let config = PermissionConfig(rules: [
            PermissionRule(action: .ask, tool: .bash, pattern: command),
        ])

        let disabled = PermissionHandle(
            config: config,
            shellCwd: "/workspace",
            rememberToolApprovals: false
        )
        await disabled.grant(SessionGrant(access: .bash(command), scope: .session))
        let denied = await disabled.request(
            access: .bash(command),
            toolName: "bash",
            toolCallId: "remember-disabled"
        )
        #expect(denied.isAllow == false)

        let enabled = PermissionHandle(
            config: config,
            shellCwd: "/workspace",
            rememberToolApprovals: true
        )
        await enabled.grant(SessionGrant(access: .bash(command), scope: .session))
        let allowed = await enabled.request(
            access: .bash(command),
            toolName: "bash",
            toolCallId: "remember-enabled"
        )

        #expect(allowed == .allow)
        #expect(await enabled.events.last?.decisionReason == "session_grant")
    }

    @Test("disabling remembered approvals revokes remembered shell grants")
    func disablingRememberedApprovalsRevokesExistingGrants() async {
        let command = "project-audit inspect"
        let permissions = PermissionHandle(
            shellCwd: "/workspace",
            rememberToolApprovals: true
        )
        await permissions.grant(SessionGrant(access: .bash(command), scope: .session))
        await permissions.setRememberToolApprovals(false)

        #expect(await permissions.bashPrefixGrants.isEmpty)
        #expect(await permissions.sessionGrants.isEmpty)
        let decision = await permissions.request(
            access: .bash(command),
            toolName: "bash",
            toolCallId: "remember-revoked"
        )
        #expect(decision.isAllow == false)
    }

    @Test("one-shot grants are consumed and cannot authorize a second request")
    func oneShotGrantNeverBecomesSessionPermission() async {
        let command = "project-audit inspect"
        let permissions = PermissionHandle(shellCwd: "/workspace")
        await permissions.grant(SessionGrant(access: .bash(command), scope: .once))

        let first = await permissions.request(
            access: .bash(command),
            toolName: "bash",
            toolCallId: "one-shot-first"
        )
        let second = await permissions.request(
            access: .bash(command),
            toolName: "bash",
            toolCallId: "one-shot-second"
        )

        #expect(first == .allow)
        #expect(second.isAllow == false)
        #expect(await permissions.sessionGrants.isEmpty)
    }

    @Test("managed deny always outranks remembered approval")
    func managedDenyBeatsRememberedGrant() async {
        let command = "project-audit inspect"
        let permissions = PermissionHandle(
            config: PermissionConfig(rules: [
                PermissionRule(
                    action: .deny,
                    tool: .bash,
                    pattern: command,
                    source: .managedSettings
                ),
            ]),
            shellCwd: "/workspace",
            rememberToolApprovals: true
        )
        await permissions.grant(SessionGrant(access: .bash(command), scope: .session))

        let decision = await permissions.request(
            access: .bash(command),
            toolName: "bash",
            toolCallId: "remember-managed-deny"
        )

        guard case .policyDeny = decision else {
            Issue.record("managed deny must outrank a remembered grant")
            return
        }
        #expect(await permissions.lastMatchedRuleSource == .managedSettings)
    }

    @Test("authenticated directory grants require exact session identity and revoke immediately")
    func directoryGrantRequiresExactSessionIdentity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("remembered-directory-" + UUID().uuidString)
        let allowed = root.appendingPathComponent("allowed")
        let sibling = root.appendingPathComponent("allowed-sibling")
        for directory in [allowed, sibling] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let permissions = PermissionHandle(shellCwd: root.path)
        await permissions.replaceWorkingDirectoryRules(sessionID: "root-a", roots: [allowed])
        #expect(await permissions.workingDirectoryRoots(sessionID: "root-a").count == 1)
        #expect(await permissions.workingDirectoryRoots(sessionID: "root-b").isEmpty)

        let target = allowed.appendingPathComponent("safe.swift").path
        let allowedDecision = await permissions.request(
            access: .edit(target),
            toolName: "search_replace",
            toolCallId: "directory-allowed",
            sessionID: "root-a"
        )
        #expect(allowedDecision == .allow)
        #expect(await permissions.events.last?.decisionReason == "session_directory_grant")

        let allowedRead = await permissions.request(
            access: .read(target),
            toolName: "read_file",
            toolCallId: "directory-read",
            sessionID: "root-a"
        )
        #expect(allowedRead == .allow)
        #expect(await permissions.events.last?.decisionReason == "session_directory_grant")

        let missingIdentity = await permissions.request(
            access: .edit(target),
            toolName: "search_replace",
            toolCallId: "directory-missing"
        )
        let wrongIdentity = await permissions.request(
            access: .edit(target),
            toolName: "search_replace",
            toolCallId: "directory-wrong",
            sessionID: "root-b"
        )
        let siblingDecision = await permissions.request(
            access: .edit(sibling.appendingPathComponent("outside.swift").path),
            toolName: "search_replace",
            toolCallId: "directory-sibling",
            sessionID: "root-a"
        )
        #expect(missingIdentity.isAllow == false)
        #expect(wrongIdentity.isAllow == false)
        #expect(siblingDecision.isAllow == false)

        await permissions.replaceWorkingDirectoryRules(sessionID: "root-a", roots: [])
        #expect(await permissions.workingDirectoryRoots(sessionID: "root-a").isEmpty)
        let revoked = await permissions.request(
            access: .edit(target),
            toolName: "search_replace",
            toolCallId: "directory-revoked",
            sessionID: "root-a"
        )
        #expect(revoked.isAllow == false)
    }

    @Test("resetting permissions atomically revokes every authenticated directory grant")
    func resettingPermissionStateRevokesDirectoryGrants() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("remembered-directory-reset-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let permissions = PermissionHandle(shellCwd: root.path)
        await permissions.replaceWorkingDirectoryRules(sessionID: "root-a", roots: [root])
        await permissions.replaceWorkingDirectoryRules(sessionID: "root-b", roots: [root])
        await permissions.resetState()

        #expect(await permissions.workingDirectoryRoots(sessionID: "root-a").isEmpty)
        #expect(await permissions.workingDirectoryRoots(sessionID: "root-b").isEmpty)

        let decision = await permissions.request(
            access: .edit(root.appendingPathComponent("revoked.swift").path),
            toolName: "search_replace",
            toolCallId: "directory-reset-revoked",
            sessionID: "root-a"
        )
        #expect(decision.isAllow == false)
    }

    @Test("directory grants never bypass managed asks, denies, protected edits, or symlink escape")
    func directoryGrantPreservesEveryPolicyFloor() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("remembered-directory-floor-" + UUID().uuidString)
        let allowed = root.appendingPathComponent("allowed")
        let outside = root.appendingPathComponent("outside")
        let hooks = allowed.appendingPathComponent(".opengrok/hooks")
        for directory in [allowed, outside, hooks] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let askedPath = allowed.appendingPathComponent("ask.swift").path
        let deniedPath = allowed.appendingPathComponent("deny.swift").path
        let permissions = PermissionHandle(
            config: PermissionConfig(rules: [
                PermissionRule(
                    action: .ask,
                    tool: .edit,
                    pattern: askedPath,
                    source: .managedSettings
                ),
                PermissionRule(
                    action: .deny,
                    tool: .edit,
                    pattern: deniedPath,
                    source: .managedSettings
                ),
            ]),
            shellCwd: root.path
        )
        await permissions.replaceWorkingDirectoryRules(sessionID: "root-a", roots: [allowed])

        let asked = await permissions.request(
            access: .edit(askedPath),
            toolName: "search_replace",
            toolCallId: "directory-ask",
            sessionID: "root-a"
        )
        let denied = await permissions.request(
            access: .edit(deniedPath),
            toolName: "search_replace",
            toolCallId: "directory-deny",
            sessionID: "root-a"
        )
        let protected = await permissions.request(
            access: .edit(hooks.appendingPathComponent("hook.sh").path),
            toolName: "search_replace",
            toolCallId: "directory-protected",
            sessionID: "root-a"
        )
        #expect(asked.isAllow == false)
        #expect(denied.isAllow == false)
        #expect(protected.isAllow == false)

        #if !os(Windows)
        let link = allowed.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let escaped = await permissions.request(
            access: .edit(link.appendingPathComponent("outside.swift").path),
            toolName: "search_replace",
            toolCallId: "directory-symlink",
            sessionID: "root-a"
        )
        #expect(escaped.isAllow == false)
        #endif
    }
}
