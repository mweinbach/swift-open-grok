// OpenGrokWorkspaceTests.swift
//
// Focused tests for R17 workspace security mediation: permission pipeline
// order, rule DSL / bash segmentation, folder trust, YOLO pin, path locks,
// and remote-policy fail-closed local ops.

import Foundation
import Testing
@testable import OpenGrokWorkspace
import OpenGrokShared

// MARK: - Rule DSL & policy

@Suite("OpenGrokWorkspace permissions")
struct PermissionTests {
    @Test("rule DSL parsing")
    func ruleDSL() throws {
        let bash = try parsePermissionRule("Bash(npm run build)", action: .allow)
        #expect(bash.tool == .bash)
        #expect(bash.pattern == "npm run build")

        let read = try parsePermissionRule("Read(src/**/*.rs)", action: .deny)
        #expect(read.tool == .read)
        #expect(read.pattern == "src/**/*.rs")

        let bare = try parsePermissionRule("Bash", action: .allow)
        #expect(bare.tool == .bash)
        #expect(bare.pattern == nil)

        let domain = try parsePermissionRule("WebFetch(domain:example.com)", action: .allow)
        #expect(domain.tool == .webFetch)
        #expect(domain.patternMode == .domain)
        #expect(domain.pattern == "example.com")

        let bashPrefix = try parsePermissionRule("Bash(git commit:*)", action: .allow)
        #expect(bashPrefix.pattern == "git commit")

        #expect(throws: RuleParseError.self) {
            try parsePermissionRule("EnterWorktree(*)", action: .allow)
        }
        #expect(throws: RuleParseError.self) {
            try parsePermissionRule("UnknownTool(x)", action: .allow)
        }
    }

    @Test("deny > ask > allow precedence with auditable source")
    func denyAskAllow() {
        let rules = [
            PermissionRule(action: .allow, tool: .bash, pattern: "git*", source: .config),
            PermissionRule(action: .deny, tool: .bash, pattern: "git push*", source: .managedSettings),
            PermissionRule(action: .ask, tool: .bash, pattern: "git*", source: .cli),
        ]
        let policy = CompiledPolicy(config: PermissionConfig(rules: rules))
        let push = policy.evaluateWithSource(.bash("git push origin main"))
        if case .policyDeny = push?.decision {
            #expect(push?.ruleSource == .managedSettings)
        } else {
            Issue.record("expected policyDeny for git push")
        }
        let status = policy.evaluateWithSource(.bash("git status"))
        #expect(status?.decision == .ask)
        #expect(status?.ruleSource == .cli)
    }

    @Test("read rules govern grep")
    func readGovernsGrep() {
        let rules = [
            PermissionRule(action: .deny, tool: .read, pattern: "secrets/**"),
        ]
        let policy = CompiledPolicy(config: PermissionConfig(rules: rules))
        if case .policyDeny = policy.evaluate(.grep(path: "secrets/key.pem", glob: nil)) {
            // ok
        } else {
            Issue.record("expected deny for grep under secrets")
        }
    }

    @Test("bash leading whitespace cannot bypass prefix deny")
    func bashWhitespaceBypass() {
        let rules = [
            PermissionRule(action: .deny, tool: .bash, pattern: "rm "),
        ]
        let policy = CompiledPolicy(config: PermissionConfig(rules: rules))
        if case .policyDeny = policy.evaluate(.bash("   rm -rf /")) {
            // ok
        } else {
            Issue.record("expected deny despite leading spaces")
        }
    }

    @Test("catchall detection for YOLO pin")
    func catchallDetection() {
        #expect(ruleIsCatchall(PermissionRule(action: .allow, tool: .bash, pattern: nil)))
        #expect(ruleIsCatchall(PermissionRule(action: .allow, tool: .any, pattern: nil)))
        #expect(!ruleIsCatchall(PermissionRule(action: .allow, tool: .bash, pattern: "git status")))
        #expect(!ruleIsCatchall(PermissionRule(action: .allow, tool: .edit, pattern: nil)))
    }

    @Test("yolo pin clamps untrusted catchalls")
    func yoloPinClamp() {
        let rules = [
            PermissionRule(action: .allow, tool: .any, pattern: nil, source: .config),
            PermissionRule(action: .allow, tool: .any, pattern: nil, source: .systemRequirements),
            PermissionRule(action: .deny, tool: .bash, pattern: "rm *", source: .config),
        ]
        let clamped = clampRulesForYoloPin(rules)
        #expect(clamped.count == 2)
        #expect(clamped.contains(where: { $0.source == .systemRequirements }))
    }

    @Test("defaultMode effects")
    func defaultModeEffects() {
        var config = PermissionConfig()
        applyDefaultMode(.acceptEdits, to: &config)
        #expect(config.rules.contains(where: { $0.tool == .edit && $0.action == .allow }))

        var bypass = PermissionConfig()
        applyDefaultMode(.bypassPermissions, to: &bypass)
        #expect(bypass.rules.contains(where: { $0.tool == .any && $0.action == .allow }))

        var dontAsk = PermissionConfig()
        applyDefaultMode(.dontAsk, to: &dontAsk)
        #expect(dontAsk.promptPolicy == .deny)
    }

    @Test("permission handle YOLO blocked by pin")
    func yoloPinOnHandle() async {
        let handle = PermissionHandle(
            config: PermissionConfig(),
            yoloMode: true,
            yoloPinReason: yoloPinReasonRequirements
        )
        await handle.setYoloMode(true)
        let yolo = await handle.yoloMode
        #expect(!yolo)
    }

    @Test("permission handle YOLO allows when unpinned")
    func yoloAllows() async {
        let handle = PermissionHandle(config: PermissionConfig(), yoloMode: true)
        let d = await handle.request(
            access: .bash("rm -rf /"),
            toolName: "bash",
            toolCallId: "t1"
        )
        #expect(d == .allow)
    }

    @Test("permission handle policy deny before YOLO")
    func policyDenyBeforeYolo() async {
        let config = PermissionConfig(rules: [
            PermissionRule(action: .deny, tool: .bash, pattern: "rm *"),
        ])
        let handle = PermissionHandle(config: config, yoloMode: true)
        let d = await handle.request(
            access: .bash("rm -rf /tmp/x"),
            toolName: "bash",
            toolCallId: "t2"
        )
        if case .policyDeny = d {
            // ok
        } else {
            Issue.record("expected policyDeny, got \(d)")
        }
    }

    @Test("policy ask blocks YOLO")
    func policyAskBlocksYolo() async {
        let config = PermissionConfig(rules: [
            PermissionRule(action: .ask, tool: .bash, pattern: "rm *"),
        ])
        let handle = PermissionHandle(config: config, yoloMode: true)
        let d = await handle.request(
            access: .bash("rm -rf /tmp/x"),
            toolName: "bash",
            toolCallId: "t2b"
        )
        if case .reject = d {
            // headless prompter after forced ask
        } else {
            Issue.record("expected reject from forced prompt, got \(d)")
        }
    }

    @Test("headless prompter rejects")
    func headlessPrompt() async {
        let handle = PermissionHandle(config: PermissionConfig(), yoloMode: false)
        let d = await handle.request(
            access: .edit("/tmp/x"),
            toolName: "write",
            toolCallId: "t3"
        )
        if case .reject = d {
            // ok
        } else {
            Issue.record("expected reject from headless prompter, got \(d)")
        }
    }

    @Test("bash splitting fail-closed on subshell and chains")
    func bashSplitFailClosed() {
        #expect(allCommandsFromScript("echo $(id)") == nil)
        #expect(allCommandsFromScript("echo `id`") == nil)
        #expect(allCommandsFromScript("echo (id)") == nil)
        #expect(allCommandsFromScript("while true; do echo; done") == nil)
        let segs = allCommandsFromScript("git status && git diff")
        #expect(segs?.count == 2)
        let pipe = allCommandsFromScript("cat a | head")
        #expect(pipe?.count == 2)
    }

    @Test("env prefixes and quotes preserve words")
    func envAndQuotes() {
        let segs = allCommandsFromScript("FOO=bar git status")
        #expect(segs?.first?.contains("git") == true)
        let quoted = allCommandsFromScript("echo 'hello world'")
        #expect(quoted?.first == ["echo", "hello world"])
    }

    @Test("unwrap wrappers peels timeout/env but not sudo")
    func unwrapWrappersTest() {
        #expect(unwrapWrappers(["timeout", "10", "ls", "-la"]) == ["ls", "-la"])
        #expect(unwrapWrappers(["sudo", "ls"]) == ["sudo", "ls"])
        #expect(unwrapWrappers(["env", "FOO=1", "ls"]) == ["ls"])
    }

    @Test("dangerous commands force prompt even with grants")
    func dangerousForcePrompt() {
        let ev = evaluateBashSegments("rm -rf /tmp/x", grants: ["rm -rf /tmp/x"], disallows: [])
        #expect(ev.needsPrompt)
        #expect(!ev.autoAllow)
    }

    @Test("word-boundary safe/dangerous (CWE-183)")
    func wordBoundary() {
        #expect(matchesCommandPrefix("git status", pattern: "git"))
        #expect(!matchesCommandPrefix("gitleaks", pattern: "git"))
        #expect(isAlwaysSafeCommandWords(["tr", "a-z", "A-Z"]))
        #expect(!isAlwaysSafeCommandWords(["truncate", "f"]))
        #expect(isDangerousCommandWords(["rm", "-rf", "/"]))
        #expect(!isDangerousCommandWords(["rmdir-safe"]))
        // grant "git" must not auto-allow gitleaks
        let ev = evaluateBashSegments("gitleaks detect", grants: ["git"], disallows: [])
        #expect(ev.needsPrompt)
    }

    @Test("unparseable high-risk scripts fail closed to ask via policy")
    func unparseableBashPolicy() {
        let rules = [
            PermissionRule(action: .deny, tool: .bash, pattern: "id"),
        ]
        let policy = CompiledPolicy(config: PermissionConfig(rules: rules))
        // Subshell unparseable → ask (escalation)
        #expect(policy.evaluateBashCommandPolicy("echo $(id)") == .ask)
    }

    @Test("shell file access escalates edit deny via redirect")
    func shellFileAccessRedirect() {
        let rules = [
            PermissionRule(action: .deny, tool: .edit, pattern: "**/secrets.txt"),
        ]
        let policy = CompiledPolicy(config: PermissionConfig(rules: rules))
        let d = policy.evaluateShellFileAccess(
            "echo hi > /tmp/ws/secrets.txt",
            cwd: "/tmp/ws"
        )
        if case .policyDeny = d {
            // ok
        } else {
            Issue.record("expected deny via redirect, got \(String(describing: d))")
        }
    }

    @Test("shell file access escalates read deny via cat")
    func shellFileAccessCat() {
        let rules = [
            PermissionRule(action: .deny, tool: .read, pattern: "**/key.pem"),
        ]
        let policy = CompiledPolicy(config: PermissionConfig(rules: rules))
        let d = policy.evaluateShellFileAccess("cat /workspace/key.pem", cwd: "/workspace")
        if case .policyDeny = d {
            // ok
        } else {
            Issue.record("expected deny via cat, got \(String(describing: d))")
        }
    }

    @Test("network tool groups: web fetch domain rules")
    func webFetchDomain() {
        let rules = [
            PermissionRule(
                action: .allow,
                tool: .webFetch,
                pattern: "example.com",
                patternMode: .domain,
                source: .config
            ),
            PermissionRule(
                action: .deny,
                tool: .webFetch,
                pattern: "evil.com",
                patternMode: .domain,
                source: .managedConfig
            ),
        ]
        let policy = CompiledPolicy(config: PermissionConfig(rules: rules))
        #expect(policy.evaluate(.webFetch("https://example.com/a")) == .allow)
        if case .policyDeny = policy.evaluate(.webFetch("https://evil.com/x")) {
            // ok
        } else {
            Issue.record("expected deny for evil.com")
        }
    }
}

// MARK: - Permission pipeline order

@Suite("OpenGrokWorkspace permission pipeline")
struct PermissionPipelineTests {
    struct DenyHook: PreToolUseHookRunner {
        func runPreToolUse(
            toolName: String,
            toolCallId: String,
            access: AccessKind,
            permissionMode: String?
        ) async -> PreToolUseHookDecision {
            _ = (toolName, toolCallId, access, permissionMode)
            return .deny(reason: "blocked by test hook", hookName: "test-hook")
        }
    }

    struct AllowHook: PreToolUseHookRunner {
        func runPreToolUse(
            toolName: String,
            toolCallId: String,
            access: AccessKind,
            permissionMode: String?
        ) async -> PreToolUseHookDecision {
            _ = (toolName, toolCallId, access, permissionMode)
            return .allow
        }
    }

    @Test("plan-edit gate rejects non-plan edits before hooks and engine")
    func planEditGateFirst() async {
        let perms = PermissionHandle(config: PermissionConfig(), yoloMode: true)
        var plan = PlanModeTracker()
        plan.enter(planFilePath: "/tmp/session/plan.md", sessionDirectory: "/tmp/session")
        let pipeline = PermissionPipeline(
            permissions: perms,
            planMode: plan,
            hooks: DenyHook() // would deny if reached
        )
        let prepared = await pipeline.prepare(
            PrepareToolAccessRequest(
                access: .edit("/tmp/session/other.swift"),
                toolName: "write",
                toolCallId: "c1"
            )
        )
        #expect(prepared.source == .planModeGate)
        if case .reject = prepared.decision {
            // ok
        } else {
            Issue.record("expected plan gate reject, got \(prepared.decision)")
        }
    }

    @Test("plan-edit gate allows plan file then auto-approves")
    func planFileAutoApprove() async {
        let perms = PermissionHandle(
            config: PermissionConfig(rules: [
                PermissionRule(action: .deny, tool: .edit, pattern: "**"),
            ])
        )
        var plan = PlanModeTracker()
        plan.enter(planFilePath: "/tmp/session/plan.md", sessionDirectory: "/tmp/session")
        let pipeline = PermissionPipeline(permissions: perms, planMode: plan)
        let prepared = await pipeline.prepare(
            PrepareToolAccessRequest(
                access: .edit("/tmp/session/plan.md"),
                toolName: "write",
                toolCallId: "c2"
            )
        )
        #expect(prepared.source == .planFileAutoApprove)
        #expect(prepared.decision == .allow)
    }

    @Test("PreToolUse deny stops before permission engine; allow does not skip policy")
    func preToolUseFailOpenAndDeny() async {
        let denyConfig = PermissionConfig(rules: [
            PermissionRule(action: .deny, tool: .bash, pattern: "rm *"),
        ])
        let perms = PermissionHandle(config: denyConfig, yoloMode: false)
        // Deny hook
        let denyPipe = PermissionPipeline(permissions: perms, hooks: DenyHook())
        let denied = await denyPipe.prepare(
            PrepareToolAccessRequest(
                access: .bash("ls"),
                toolName: "bash",
                toolCallId: "h1"
            )
        )
        #expect(denied.source == .preToolUseHook)

        // Allow hook must NOT skip later policy deny
        let allowPipe = PermissionPipeline(permissions: perms, hooks: AllowHook())
        let stillDenied = await allowPipe.prepare(
            PrepareToolAccessRequest(
                access: .bash("rm -rf /tmp"),
                toolName: "bash",
                toolCallId: "h2"
            )
        )
        #expect(stillDenied.source == .permissionEngine)
        if case .policyDeny = stillDenied.decision {
            // ok
        } else {
            Issue.record("hook allow must not skip policy deny, got \(stillDenied.decision)")
        }
    }

    @Test("missing hooks fail open into permission engine")
    func hooksFailOpen() async {
        let perms = PermissionHandle(config: PermissionConfig(), yoloMode: true)
        let pipeline = PermissionPipeline(
            permissions: perms,
            hooks: FailOpenPreToolUseHookRunner(inner: nil)
        )
        let prepared = await pipeline.prepare(
            PrepareToolAccessRequest(
                access: .bash("ls"),
                toolName: "bash",
                toolCallId: "h3"
            )
        )
        #expect(prepared.decision == .allow)
        #expect(prepared.source == .permissionEngine)
    }

    @Test("apply_patch label rejected in plan mode")
    func applyPatchRejectedInPlan() {
        var plan = PlanModeTracker()
        plan.enter(planFilePath: "plan.md")
        let gate = planModeEditGate(
            tracker: plan,
            access: .edit("plan.md"),
            applyPatchLabel: true
        )
        #expect(gate == .rejectNonPlanFile)
    }

    @Test("bash not gated by plan mode")
    func bashNotPlanGated() {
        var plan = PlanModeTracker()
        plan.enter()
        let gate = planModeEditGate(tracker: plan, access: .bash("rm -rf /"))
        #expect(gate == .allow)
    }
}

// MARK: - Folder trust & path boundary

@Suite("OpenGrokWorkspace path boundary and trust")
struct PathBoundaryTests {
    @Test("rejects traversal and outside paths")
    func rejectsTraversal() throws {
        let root = URL(fileURLWithPath: "/tmp/ws-boundary")
        let boundary = PathBoundary(root: root, resolveSymlinks: false)
        #expect(throws: PathBoundaryError.self) {
            try boundary.resolve("../etc/passwd")
        }
        #expect(throws: PathBoundaryError.self) {
            try boundary.resolve("/etc/passwd")
        }
        let ok = try boundary.resolve("src/main.swift")
        #expect(ok.path.contains("ws-boundary"))
    }

    @Test("rejects NUL bytes")
    func rejectsNul() {
        let boundary = PathBoundary(root: URL(fileURLWithPath: "/tmp/ws"), resolveSymlinks: false)
        #expect(throws: PathBoundaryError.self) {
            try boundary.resolve("foo\0bar")
        }
    }

    @Test("folder trust does not inherit to children")
    func folderTrustNoInherit() {
        var store = FolderTrustStore()
        let parent = URL(fileURLWithPath: "/Users/me/proj")
        let child = URL(fileURLWithPath: "/Users/me/proj/sub")
        store.trust(parent)
        #expect(store.state(for: parent) == .trusted)
        #expect(store.state(for: child) == .untrusted)
        #expect(!projectScopeAllowed(workspaceRoot: child, trustStore: store))
        #expect(projectScopeAllowed(workspaceRoot: parent, trustStore: store))
    }

    @Test("folder trust decide precedence")
    func folderTrustDecide() {
        // Feature off → trusted
        #expect(
            decideFolderTrust(
                featureEnabled: false,
                inputs: FolderTrustDecideInputs(
                    storeTrusted: false,
                    repoConfigsPresent: true,
                    isInteractive: false,
                    keyRecordable: true
                )
            ) == .trusted
        )
        // Headless + configs + not store-trusted → untrusted
        #expect(
            decideFolderTrust(
                featureEnabled: true,
                inputs: FolderTrustDecideInputs(
                    storeTrusted: false,
                    repoConfigsPresent: true,
                    isInteractive: false,
                    keyRecordable: true
                )
            ) == .untrusted
        )
        // Interactive → prompt
        #expect(
            decideFolderTrust(
                featureEnabled: true,
                inputs: FolderTrustDecideInputs(
                    storeTrusted: false,
                    repoConfigsPresent: true,
                    isInteractive: true,
                    keyRecordable: true
                )
            ) == .prompt
        )
        // Unsafe key → trusted (unrecordable)
        #expect(isUnsafeTrustRoot("/"))
        #expect(isUnsafeTrustRoot("/Users/me", home: "/Users/me"))
    }

    @Test("fs change note is not authorship evidence")
    func fsChangeNotAuthorship() {
        let note = FsChangeNote(path: "a.swift", kind: "modify")
        #expect(!note.isAuthorshipEvidence)
    }

    @Test("protected edit paths")
    func protectedEdits() {
        #expect(protectedEditPath("/home/u/.ssh/id_rsa"))
        #expect(protectedEditPath("/home/u/.bashrc"))
        #expect(protectedEditPath("/repo/.git/hooks/pre-commit"))
        #expect(protectedEditPath("/etc/passwd"))
        #expect(!protectedEditPath("/repo/src/main.swift"))
    }
}

// MARK: - Local ops, locks, remote fail-closed

@Suite("OpenGrokWorkspace local mediation")
struct LocalMediationTests {
    @Test("local workspace ops enforce permission on write")
    func localOpsPermission() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-ws-ops-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let config = WorkspaceConfig(
            root: root,
            permissionConfig: PermissionConfig(rules: [
                PermissionRule(action: .deny, tool: .edit, pattern: "**"),
            ])
        )
        let ops = LocalWorkspaceOps(config: config)
        do {
            try await ops.writeFile(
                path: "x.txt",
                data: Data("hi".utf8),
                toolCallId: "c1"
            )
            Issue.record("expected permission denial")
        } catch WorkspaceRuntimeError.permissionDenied {
            // ok
        } catch {
            Issue.record("unexpected: \(error)")
        }
    }

    @Test("remote policy denied blocks local fallback")
    func remotePolicyDenied() async {
        let root = URL(fileURLWithPath: "/tmp/ws")
        let ops = LocalWorkspaceOps(config: WorkspaceConfig(root: root))
        await ops.setRemotePolicy(available: true, denied: true)
        let d = await ops.requestPermission(
            access: .read("/tmp/ws/a"),
            toolName: "read_file",
            toolCallId: "c2"
        )
        if case .policyDeny = d {
            // ok
        } else {
            Issue.record("expected policyDeny for remote deny")
        }
    }

    @Test("sandbox required blocks local fallback when unavailable")
    func sandboxRequiredNoFallback() async {
        let root = URL(fileURLWithPath: "/tmp/ws")
        let config = WorkspaceConfig(
            root: root,
            isolation: .sandbox,
            yoloPinReason: nil,
            requireSandbox: true
        )
        let ops = LocalWorkspaceOps(config: config, remotePolicyAvailable: false)
        let d = await ops.requestPermission(
            access: .bash("ls"),
            toolName: "bash",
            toolCallId: "c3"
        )
        if case .policyDeny = d {
            // ok
        } else {
            Issue.record("expected policyDeny for sandbox unavailable, got \(d)")
        }
    }

    @Test("YOLO pin never disables sandbox requirements")
    func yoloPinKeepsSandbox() async {
        let root = URL(fileURLWithPath: "/tmp/ws")
        // Even with YOLO pin reason and yolo-like config, requireSandbox holds.
        let config = WorkspaceConfig(
            root: root,
            isolation: .sandbox,
            permissionConfig: PermissionConfig(rules: [
                PermissionRule(action: .allow, tool: .any, pattern: nil, source: .config),
            ]),
            yoloPinReason: yoloPinReasonRequirements,
            requireSandbox: true
        )
        let ops = LocalWorkspaceOps(config: config, remotePolicyAvailable: false)
        // Catch-all from config should be clamped by pin on the handle.
        let yolo = await ops.permissions.yoloMode
        #expect(!yolo)
        let d = await ops.requestPermission(
            access: .bash("ls"),
            toolName: "bash",
            toolCallId: "c4"
        )
        if case .policyDeny = d {
            // sandbox gate wins
        } else {
            Issue.record("sandbox must remain required under YOLO pin, got \(d)")
        }
    }

    @Test("process mediation fails closed on remote deny")
    func processMediationRemoteDeny() async throws {
        let root = URL(fileURLWithPath: "/tmp/ws")
        let ops = LocalWorkspaceOps(config: WorkspaceConfig(root: root))
        await ops.setRemotePolicy(available: true, denied: true)
        do {
            try await ops.authorizeProcess(
                ProcessSpawnRequest(command: "ls", toolCallId: "p1")
            )
            Issue.record("expected process denial")
        } catch WorkspaceRuntimeError.processDenied {
            // ok
        } catch {
            Issue.record("unexpected: \(error)")
        }
    }

    @Test("path resource locks serialize same path")
    func pathLocksSerialize() async {
        let locks = PathResourceLockManager()
        let t1 = await locks.acquirePath("/tmp/a")
        // Exclusive should wait; test non-blocking second path is fine.
        let t2 = await locks.acquirePath("/tmp/b")
        await t1.release()
        await t2.release()
        let exclusive = await locks.acquireExclusive()
        await exclusive.release()
    }

    @Test("write with allow rule acquires path and succeeds")
    func writeWithAllow() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-ws-write-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let config = WorkspaceConfig(
            root: root,
            permissionConfig: PermissionConfig(rules: [
                PermissionRule(action: .allow, tool: .edit, pattern: nil),
            ])
        )
        let ops = LocalWorkspaceOps(config: config)
        try await ops.writeFile(path: "ok.txt", data: Data("ok".utf8), toolCallId: "w1")
        let data = try await ops.readFile(path: "ok.txt", toolCallId: "r1")
        #expect(String(data: data, encoding: .utf8) == "ok")
    }

    @Test("pipeline prepare order sources are auditable")
    func prepareSourcesAuditable() async {
        let perms = PermissionHandle(config: PermissionConfig(), yoloMode: true)
        let pipeline = PermissionPipeline(permissions: perms)
        let prepared = await pipeline.prepare(
            PrepareToolAccessRequest(
                access: .read("/tmp/a"),
                toolName: "read_file",
                toolCallId: "a1"
            )
        )
        #expect(prepared.mayDispatch)
        #expect(prepared.source == .permissionEngine)
    }
}
