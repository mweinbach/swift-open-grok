// OpenGrokWorkspaceTests.swift
import Foundation
import Testing
@testable import OpenGrokWorkspace
import OpenGrokShared

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

    @Test("deny > ask > allow precedence")
    func denyAskAllow() {
        let rules = [
            PermissionRule(action: .allow, tool: .bash, pattern: "git*"),
            PermissionRule(action: .deny, tool: .bash, pattern: "git push*"),
            PermissionRule(action: .ask, tool: .bash, pattern: "git*"),
        ]
        let policy = CompiledPolicy(config: PermissionConfig(rules: rules))
        if case .policyDeny = policy.evaluate(.bash("git push origin main")) {
            // ok
        } else {
            Issue.record("expected policyDeny for git push")
        }
        #expect(policy.evaluate(.bash("git status")) == .ask)
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

    @Test("bash splitting fail-closed on subshell")
    func bashSplitFailClosed() {
        #expect(allCommandsFromScript("echo $(id)") == nil)
        #expect(allCommandsFromScript("echo `id`") == nil)
        let segs = allCommandsFromScript("git status && git diff")
        #expect(segs?.count == 2)
    }

    @Test("unwrap wrappers peels timeout/env but not sudo")
    func unwrapWrappersTest() {
        #expect(unwrapWrappers(["timeout", "10", "ls", "-la"]) == ["ls", "-la"])
        #expect(unwrapWrappers(["sudo", "ls"]) == ["sudo", "ls"])
    }

    @Test("dangerous commands force prompt")
    func dangerousForcePrompt() {
        let ev = evaluateBashSegments("rm -rf /tmp/x", grants: ["rm -rf /tmp/x"], disallows: [])
        #expect(ev.needsPrompt)
    }
}

@Suite("OpenGrokWorkspace path boundary")
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
    }

    @Test("fs change note is not authorship evidence")
    func fsChangeNotAuthorship() {
        let note = FsChangeNote(path: "a.swift", kind: "modify")
        #expect(!note.isAuthorshipEvidence)
    }

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
}
