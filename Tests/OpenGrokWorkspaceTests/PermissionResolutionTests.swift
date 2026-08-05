// PermissionResolutionTests.swift
//
// Covers the sourcing layer that feeds the permission rule engine — the
// `[permission]` TOML section, Claude-compatible settings JSON, folder-trust
// gating of project-scoped inputs, cwd/symlink path anchoring, and the widened
// protected-file list.

import Foundation
import OpenGrokConfig
import Testing
@testable import OpenGrokWorkspace

private func withTemporaryDirectory<T>(_ body: (URL) throws -> T) rethrows -> T {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("permission-resolution-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // macOS hands out `/var/...`, a symlink to `/private/var`; resolve it so a
    // test asserting on canonical paths is comparing like with like.
    return try body(root.resolvingSymlinksInPath())
}

// MARK: - `[permission]` TOML

@Suite("permission config sourcing")
struct PermissionConfigSourcingTests {
    @Test("compact deny/allow/ask arrays parse into rules")
    func compactForm() throws {
        let document = try parseTOML("""
        [permission]
        deny = ["Bash(rm:*)", "Read(./.env)"]
        allow = ["Bash(npm run build)"]
        ask = ["WebFetch(domain:example.com)"]
        """)
        let permission = try #require(document["permission"])
        let parsed = parseTOMLPermissionSection(permission, source: .config)

        #expect(parsed.rules.count == 4)
        #expect(parsed.skipped.isEmpty)
        let deny = parsed.rules.filter { $0.action == .deny }
        #expect(deny.contains { $0.tool == .bash && $0.pattern == "rm" })
        #expect(deny.contains { $0.tool == .read && $0.pattern == "./.env" })
        #expect(parsed.rules.contains {
            $0.action == .ask && $0.tool == .webFetch && $0.patternMode == .domain
        })
    }

    @Test("a bad rule string is skipped with a reason, not dropped silently")
    func malformedRuleIsReported() throws {
        let document = try parseTOML("""
        [permission]
        deny = ["Bash(rm:*)", "NotATool(x)"]
        """)
        let permission = try #require(document["permission"])
        let parsed = parseTOMLPermissionSection(permission, source: .config)

        #expect(parsed.rules.count == 1)
        #expect(parsed.skipped.count == 1)
        #expect(parsed.skipped[0].rule == "NotATool(x)")
    }

    @Test("verbose [[permission.rules]] form with snake_case fields")
    func verboseForm() throws {
        let document = try parseTOML("""
        [permission]
        prompt_policy = "deny"

        [[permission.rules]]
        action = "deny"
        tool = "webfetch"
        pattern = "evil.example.com"
        pattern_mode = "domain"
        """)
        let permission = try #require(document["permission"])
        let parsed = parseTOMLPermissionSection(permission, source: .config)

        #expect(parsed.promptPolicy == .deny)
        #expect(parsed.rules.count == 1)
        // Rust's `rename_all = "lowercase"` spells this `webfetch`.
        #expect(parsed.rules[0].tool == .webFetch)
        #expect(parsed.rules[0].patternMode == .domain)
    }

    @Test("compact form wins outright over verbose in the same table")
    func compactShortCircuitsVerbose() throws {
        let document = try parseTOML("""
        [permission]
        deny = ["Bash(rm:*)"]

        [[permission.rules]]
        action = "allow"
        tool = "bash"
        """)
        let permission = try #require(document["permission"])
        let parsed = parseTOMLPermissionSection(permission, source: .config)

        #expect(parsed.rules.count == 1)
        #expect(parsed.rules[0].action == .deny)
    }
}

// MARK: - Claude-compatible settings

@Suite("claude settings permissions")
struct ClaudeSettingsTests {
    @Test("permissions arrays and nested defaultMode")
    func parsesPermissions() throws {
        let json = Data("""
        {"permissions": {"deny": ["Bash(curl:*)"], "allow": ["Read(src/**)"],
         "defaultMode": "acceptEdits", "additionalDirectories": ["/tmp/extra"]}}
        """.utf8)
        let parsed = try #require(parseClaudeSettingsJSON(json))

        #expect(parsed.deny == ["Bash(curl:*)"])
        #expect(parsed.allow == ["Read(src/**)"])
        #expect(parsed.defaultMode == "acceptEdits")
        #expect(parsed.claimsDefaultMode)
        #expect(parsed.additionalDirectories == ["/tmp/extra"])
    }

    @Test("a non-string array element is skipped, the rest survive")
    func tolerantArrayParsing() throws {
        let json = Data(#"{"permissions": {"deny": ["Bash(rm:*)", 42]}}"#.utf8)
        let parsed = try #require(parseClaudeSettingsJSON(json))

        #expect(parsed.deny == ["Bash(rm:*)"])
        #expect(parsed.skipped.count == 1)
    }

    @Test("a present-but-non-string nested defaultMode does not revive the root key")
    func nestedDefaultModeDoesNotFallBack() throws {
        let json = Data(#"{"defaultMode": "bypassPermissions", "permissions": {"defaultMode": 7}}"#.utf8)
        let parsed = try #require(parseClaudeSettingsJSON(json))

        #expect(parsed.claimsDefaultMode)
        #expect(parsed.defaultMode == nil)
    }
}

// MARK: - Full resolution + trust gating

@Suite("permission resolution")
struct PermissionResolutionTests {
    /// Reads only from an in-memory map so the developer's real `~/.claude`
    /// can never leak into a test.
    private func reader(_ files: [String: String]) -> @Sendable (URL) -> Data? {
        { url in files[url.path].map { Data($0.utf8) } }
    }

    @Test("config [permission] deny reaches the compiled policy")
    func configDenyIsEnforced() throws {
        let document = try parseTOML("""
        [permission]
        deny = ["Bash(rm:*)"]
        """)
        let resolved = resolvePermissions(PermissionResolutionInputs(
            permissionLayers: [(document, .config)],
            cwd: URL(fileURLWithPath: "/work"),
            home: URL(fileURLWithPath: "/home/u"),
            readFile: reader([:])
        ))
        let policy = CompiledPolicy(config: resolved.config)

        guard case .policyDeny = policy.evaluate(.bash("rm -rf /")) else {
            Issue.record("expected a policy deny for `rm -rf /`")
            return
        }
        #expect(policy.evaluate(.bash("ls")) == nil)
    }

    @Test("an untrusted folder's project .claude/settings.json is not read")
    func untrustedProjectSettingsIgnored() throws {
        let cwd = URL(fileURLWithPath: "/repo")
        let home = URL(fileURLWithPath: "/home/u")
        let files = [
            "/repo/.claude/settings.json": #"{"permissions":{"allow":["Bash(curl:*)"]}}"#
        ]

        let trusted = resolvePermissions(PermissionResolutionInputs(
            cwd: cwd, home: home, projectTrusted: true, readFile: reader(files)
        ))
        let untrusted = resolvePermissions(PermissionResolutionInputs(
            cwd: cwd, home: home, projectTrusted: false, readFile: reader(files)
        ))

        #expect(trusted.config.rules.contains { $0.action == .allow && $0.tool == .bash })
        #expect(untrusted.config.rules.isEmpty)
    }

    @Test("managed defaultMode outranks a user file's")
    func managedDefaultModeWins() throws {
        var managed = ClaudeSettingsPermissions()
        managed.defaultMode = "dontAsk"
        managed.claimsDefaultMode = true

        let resolved = resolvePermissions(PermissionResolutionInputs(
            managedSettings: managed,
            cwd: URL(fileURLWithPath: "/repo"),
            home: URL(fileURLWithPath: "/home/u"),
            readFile: reader([
                "/home/u/.claude/settings.json": #"{"permissions":{"defaultMode":"bypassPermissions"}}"#
            ])
        ))

        #expect(resolved.defaultMode == .dontAsk)
        #expect(resolved.config.promptPolicy == .deny)
    }

    @Test("an admin YOLO pin blocks bypassPermissions and drops catch-all allows")
    func yoloPinClampsPolicy() throws {
        let requirements = try parseTOML("""
        [ui]
        disable_bypass_permissions_mode = true

        [permission]
        allow = []
        """)
        let document = try parseTOML("""
        [permission]
        allow = ["Bash"]
        """)
        let resolved = resolvePermissions(PermissionResolutionInputs(
            permissionLayers: [(document, .config)],
            requirementsLayers: [requirements],
            cwd: URL(fileURLWithPath: "/repo"),
            home: URL(fileURLWithPath: "/home/u"),
            readFile: reader([
                "/home/u/.claude/settings.json": #"{"permissions":{"defaultMode":"bypassPermissions"}}"#
            ])
        ))

        #expect(resolved.yoloPinReason == yoloPinReasonRequirementsMessage)
        // The untrusted catch-all `allow Bash` must not survive the pin.
        #expect(!resolved.config.rules.contains { $0.action == .allow && $0.tool == .bash })
        #expect(resolved.skipped.contains { $0.rule == "defaultMode=bypassPermissions" })
    }

    @Test("legacy [ui] yolo = false also arms the pin")
    func legacyYoloPin() throws {
        let requirements = try parseTOML("[ui]\nyolo = false\n")
        #expect(
            resolveYoloPolicyBlock(requirementsLayers: [requirements])
                == yoloPinReasonLegacyYoloMessage
        )
    }

    @Test("a user config deny list adds to the managed one instead of replacing it")
    func layersConcatenateRatherThanMerge() throws {
        // `deepMergeTOML` replaces arrays. Sourcing `[permission]` from the
        // merged document would let this user layer wipe the admin deny rule;
        // passing the layers separately is what keeps both.
        let managed = try parseTOML("""
        [permission]
        deny = ["Bash(rm:*)"]
        """)
        let user = try parseTOML("""
        [permission]
        deny = ["Bash(curl:*)"]
        """)
        let resolved = resolvePermissions(PermissionResolutionInputs(
            permissionLayers: [(managed, .managedConfig), (user, .config)],
            cwd: URL(fileURLWithPath: "/work"),
            home: URL(fileURLWithPath: "/home/u"),
            readFile: reader([:])
        ))
        let policy = CompiledPolicy(config: resolved.config)

        // The admin rule must survive the presence of a user rule.
        guard case .policyDeny = policy.evaluate(.bash("rm -rf /")) else {
            Issue.record("the managed deny rule was lost when a user layer was present")
            return
        }
        guard case .policyDeny = policy.evaluate(.bash("curl http://x")) else {
            Issue.record("the user deny rule should also apply")
            return
        }
    }

    @Test("CLI allow/deny rules land in the policy under the cli source tier")
    func cliRulesAreSourced() throws {
        let resolved = resolvePermissions(PermissionResolutionInputs(
            cwd: URL(fileURLWithPath: "/work"),
            home: URL(fileURLWithPath: "/home/u"),
            cliAllowRules: ["Bash(npm run build)"],
            cliDenyRules: ["Bash(rm:*)"],
            readFile: reader([:])
        ))
        #expect(resolved.config.rules.allSatisfy { $0.source == .cli })

        let policy = CompiledPolicy(config: resolved.config)
        guard case .policyDeny = policy.evaluate(.bash("rm -rf /")) else {
            Issue.record("--deny must reach the compiled policy")
            return
        }
        #expect(policy.evaluate(.bash("npm run build"))?.isAllow == true)
    }

    @Test("a malformed CLI rule is reported rather than silently dropped")
    func malformedCLIRuleIsReported() throws {
        let resolved = resolvePermissions(PermissionResolutionInputs(
            cwd: URL(fileURLWithPath: "/work"),
            home: URL(fileURLWithPath: "/home/u"),
            cliAllowRules: ["NotATool(x)"],
            readFile: reader([:])
        ))
        #expect(resolved.config.rules.isEmpty)
        #expect(resolved.skipped.contains { $0.rule == "NotATool(x)" })
    }

    @Test("a CLI catch-all allow is not admin tier and is dropped under the pin")
    func cliAllowIsNotAdminTier() throws {
        let pin = try parseTOML("[ui]\ndisable_bypass_permissions_mode = true\n")
        let resolved = resolvePermissions(PermissionResolutionInputs(
            requirementsLayers: [pin],
            cwd: URL(fileURLWithPath: "/work"),
            home: URL(fileURLWithPath: "/home/u"),
            cliAllowRules: ["Bash"],
            readFile: reader([:])
        ))
        #expect(!resolved.config.rules.contains { $0.action == .allow && $0.tool == .bash })
    }

    @Test("--permission-mode sits below managed settings and above user files")
    func cliModePrecedence() throws {
        let userFile = ["/home/u/.claude/settings.json":
            #"{"permissions":{"defaultMode":"acceptEdits"}}"#]

        // No managed mode: the CLI flag wins over the user file.
        let cliWins = resolvePermissions(PermissionResolutionInputs(
            cwd: URL(fileURLWithPath: "/repo"),
            home: URL(fileURLWithPath: "/home/u"),
            cliMode: .dontAsk,
            readFile: reader(userFile)
        ))
        #expect(cliWins.defaultMode == .dontAsk)

        // Managed sets one: it outranks the CLI flag.
        var managed = ClaudeSettingsPermissions()
        managed.defaultMode = "plan"
        managed.claimsDefaultMode = true
        let managedWins = resolvePermissions(PermissionResolutionInputs(
            managedSettings: managed,
            cwd: URL(fileURLWithPath: "/repo"),
            home: URL(fileURLWithPath: "/home/u"),
            cliMode: .dontAsk,
            readFile: reader(userFile)
        ))
        #expect(managedWins.defaultMode == .plan)
    }

    @Test("--always-approve is vetoed by an admin pin, and the veto is reported")
    func alwaysApproveVetoedByPin() throws {
        let unpinned = resolvePermissions(PermissionResolutionInputs(
            cwd: URL(fileURLWithPath: "/work"),
            home: URL(fileURLWithPath: "/home/u"),
            cliAlwaysApprove: true,
            readFile: reader([:])
        ))
        #expect(unpinned.alwaysApprove)

        let pin = try parseTOML("[ui]\ndisable_bypass_permissions_mode = true\n")
        let pinned = resolvePermissions(PermissionResolutionInputs(
            requirementsLayers: [pin],
            cwd: URL(fileURLWithPath: "/work"),
            home: URL(fileURLWithPath: "/home/u"),
            cliAlwaysApprove: true,
            readFile: reader([:])
        ))
        #expect(pinned.alwaysApprove == false)
        #expect(pinned.skipped.contains { $0.rule == "--always-approve" })
    }

    @Test("a user requirements.toml is not admin tier and cannot dodge the pin")
    func userRequirementsAreNotAdminTier() throws {
        let pinLayer = try parseTOML("[ui]\ndisable_bypass_permissions_mode = true\n")
        let userRequirements = try parseTOML("""
        [permission]
        allow = ["Bash"]
        """)
        let systemRequirements = try parseTOML("""
        [permission]
        allow = ["Bash"]
        """)

        // Tagged `.requirements` (user tier) — the clamp must drop it.
        let asUser = resolvePermissions(PermissionResolutionInputs(
            permissionLayers: [(userRequirements, .requirements)],
            requirementsLayers: [pinLayer],
            cwd: URL(fileURLWithPath: "/work"),
            home: URL(fileURLWithPath: "/home/u"),
            readFile: reader([:])
        ))
        #expect(!asUser.config.rules.contains { $0.action == .allow && $0.tool == .bash })

        // Tagged `.systemRequirements` (admin tier) — it survives.
        let asAdmin = resolvePermissions(PermissionResolutionInputs(
            permissionLayers: [(systemRequirements, .systemRequirements)],
            requirementsLayers: [pinLayer],
            cwd: URL(fileURLWithPath: "/work"),
            home: URL(fileURLWithPath: "/home/u"),
            readFile: reader([:])
        ))
        #expect(asAdmin.config.rules.contains { $0.action == .allow && $0.tool == .bash })
    }
}

// MARK: - Path anchoring (audit gap 9)

@Suite("path rule anchoring")
struct PathRuleAnchoringTests {
    @Test("a relative rule matches the absolute path a tool receives")
    func relativeRuleMatchesAbsolutePath() {
        let rule = PermissionRule(action: .deny, tool: .edit, pattern: "src/**")
        let policy = CompiledPolicy(
            config: PermissionConfig(rules: [rule]),
            pathContext: PathRuleContext(cwd: "/work/repo", home: "/home/u")
        )

        guard case .policyDeny = policy.evaluate(.edit("/work/repo/src/main.swift")) else {
            Issue.record("a relative deny rule must match the absolute tool argument")
            return
        }
        #expect(policy.evaluate(.edit("/work/other/src/main.swift")) == nil)
    }

    @Test("without a context the raw-string behaviour is unchanged")
    func noContextKeepsRawMatching() {
        let rule = PermissionRule(action: .deny, tool: .edit, pattern: "src/**")
        let policy = CompiledPolicy(config: PermissionConfig(rules: [rule]))
        #expect(policy.evaluate(.edit("/work/repo/src/main.swift")) == nil)
    }

    @Test("~ in a rule expands against home")
    func tildeExpansion() {
        let rule = PermissionRule(action: .deny, tool: .read, pattern: "~/.aws/**")
        let policy = CompiledPolicy(
            config: PermissionConfig(rules: [rule]),
            pathContext: PathRuleContext(cwd: "/work", home: "/home/u")
        )
        guard case .policyDeny = policy.evaluate(.read("/home/u/.aws/credentials")) else {
            Issue.record("`~` must expand so the deny rule matches")
            return
        }
    }

    @Test("a symlink cannot dodge a deny rule")
    func symlinkIsCanonicalized() throws {
        try withTemporaryDirectory { root in
            let secrets = root.appendingPathComponent("secrets")
            let link = root.appendingPathComponent("link")
            try FileManager.default.createDirectory(at: secrets, withIntermediateDirectories: true)
            try Data("k".utf8).write(to: secrets.appendingPathComponent("key.txt"))
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secrets)

            let rule = PermissionRule(
                action: .deny, tool: .read,
                pattern: secrets.appendingPathComponent("**").path
            )
            let policy = CompiledPolicy(
                config: PermissionConfig(rules: [rule]),
                pathContext: PathRuleContext(cwd: root.path, home: root.path)
            )

            let throughLink = link.appendingPathComponent("key.txt").path
            guard case .policyDeny = policy.evaluate(.read(throughLink)) else {
                Issue.record("reading through a symlink must still hit the deny rule")
                return
            }
        }
    }
}

// MARK: - Protected files (audit gap 5)

@Suite("protected edit targets")
struct ProtectedEditTests {
    @Test("the paths Rust protects that Swift previously missed")
    func widenedCoverage() {
        #expect(protectedEditReason("/repo/.opengrok/hooks/pre.sh") == .hookRoot)
        #expect(protectedEditReason("/repo/.opengrok/hooks-paths") == .hookRoot)
        #expect(protectedEditReason("/repo/.claude/settings.json") == .claudeSettings)
        #expect(protectedEditReason("/repo/.claude/settings.local.json") == .claudeSettings)
        #expect(protectedEditReason("/repo/.cursor/hooks.json") == .cursorHooks)
        #expect(protectedEditReason("/repo/.git/modules/sub/hooks/pre-commit") == .gitHooks)
        #expect(protectedEditReason("/repo/.opengrok/managed_config.toml") == .grokConfig)
        #expect(protectedEditReason("/repo/.opengrok/requirements.toml") == .grokConfig)
        #expect(protectedEditReason("/repo/.opengrok/sandbox.toml") == .grokSandbox)
        // Previously missing from the startup-file list.
        #expect(protectedEditReason("/home/u/.xprofile") == .startupFile)
    }

    @Test("the coverage that already existed still holds")
    func existingCoverage() {
        #expect(protectedEditReason("/home/u/.zshrc") == .startupFile)
        #expect(protectedEditReason("/home/u/.ssh/id_rsa") == .ssh)
        #expect(protectedEditReason("/repo/.git/hooks/pre-commit") == .gitHooks)
        #expect(protectedEditReason("/repo/.opengrok/config.toml") == .grokConfig)
        #expect(protectedEditReason("/etc/hosts") == .etc)
        #expect(protectedEditReason("/repo/src/main.swift") == nil)
        #expect(protectedEditPath("/repo/src/main.swift") == false)
    }

    @Test("config files in the user grok home are protected too")
    func userGrokHomeConfig() {
        #expect(
            protectedEditReason("/home/u/.opengrok-home/config.toml",
                                userGrokHome: "/home/u/.opengrok-home") == .grokConfig
        )
        #expect(protectedEditReason("/home/u/.opengrok-home/config.toml") == nil)
    }

    @Test("every classified reason but .sensitive carries user-facing copy")
    func explanationsAreSurfaced() {
        for reason in [
            ProtectedEditReason.hookRoot, .gitHooks, .ssh, .startupFile, .etc,
            .grokConfig, .grokSandbox, .claudeSettings, .cursorHooks,
        ] {
            #expect(reason.explanation?.hasPrefix("Note: ") == true)
        }
        #expect(ProtectedEditReason.sensitive.explanation == nil)
    }

    @Test("a relative path is unclassifiable and fails closed")
    func relativePathIsSensitive() {
        #expect(editTargetProtection("src/main.swift") == .sensitive)
    }
}

// MARK: - Rule DSL escaping

@Suite("rule escaping")
struct RuleEscapingTests {
    @Test("only \\( \\) and \\\\ are unescaped; a \\* stays literal")
    func literalAsteriskSurvives() throws {
        // Stripping this backslash would turn the pattern into a glob, widening
        // allow rules and narrowing deny rules.
        let rule = try parsePermissionRule(#"Bash(find . -name \*.rs)"#, action: .allow)
        #expect(rule.pattern == #"find . -name \*.rs"#)

        let parens = try parsePermissionRule(#"Bash(echo \(hi\))"#, action: .allow)
        #expect(parens.pattern == "echo (hi)")
    }
}

// MARK: - Folder trust persistence

@Suite("folder trust persistence")
struct FolderTrustPersistenceTests {
    @Test("a trust decision round-trips through trusted_folders.toml")
    func roundTrip() throws {
        try withTemporaryDirectory { root in
            let storePath = root.appendingPathComponent("trusted_folders.toml")
            let repo = root.appendingPathComponent("repo")

            var store = PersistentFolderTrustStore(path: storePath, home: root.path)
            #expect(store.isTrusted(repo) == false)
            try store.record(repo, trusted: true)

            let reloaded = PersistentFolderTrustStore(path: storePath, home: root.path)
            #expect(reloaded.isTrusted(repo))
            // Trust cascades to subdirectories.
            #expect(reloaded.isTrusted(repo.appendingPathComponent("sub")))
        }
    }

    @Test("an over-broad root in the file is ignored on read")
    func unsafeRootsDropped() throws {
        try withTemporaryDirectory { root in
            let storePath = root.appendingPathComponent("trusted_folders.toml")
            try Data("""
            [folders."/"]
            trusted = true
            """.utf8).write(to: storePath)

            let store = PersistentFolderTrustStore(path: storePath, home: "/home/u")
            #expect(store.isTrusted(URL(fileURLWithPath: "/anything")) == false)
        }
    }

    @Test("the feature flag honours env over config")
    func featureFlagPrecedence() throws {
        let document = try parseTOML("[folder_trust]\nenabled = false\n")
        #expect(folderTrustEnabled(document: document, environment: [:]) == false)
        #expect(
            folderTrustEnabled(document: document, environment: ["GROK_FOLDER_TRUST": "1"])
        )
        #expect(folderTrustEnabled(document: nil, environment: [:]))
    }

    @Test("an untrusted repo with code-exec configs resolves to untrusted when headless")
    func headlessUntrusted() {
        let outcome = decideFolderTrust(
            featureEnabled: true,
            inputs: FolderTrustDecideInputs(
                storeTrusted: false,
                repoConfigsPresent: true,
                isInteractive: false,
                keyRecordable: true
            )
        )
        #expect(outcome == .untrusted)
    }
}
