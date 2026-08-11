// OpenGrokSandboxTests.swift
import Foundation
import Testing
@testable import OpenGrokSandbox

@Suite("OpenGrokSandbox")
struct OpenGrokSandboxTests {
    @Test("canResume never weakens the persisted sandbox mode")
    func noSilentWeakening() {
        let enforcer = PlatformSandboxEnforcer()
        #expect(!enforcer.canResume(persisted: .restricted, candidate: .readOnly))
        #expect(!enforcer.canResume(persisted: .restricted, candidate: .none))
        #expect(!enforcer.canResume(persisted: .readOnly, candidate: .none))
        #expect(enforcer.canResume(persisted: .none, candidate: .readOnly))
        #expect(enforcer.canResume(persisted: .readOnly, candidate: .restricted))
        #expect(enforcer.canResume(persisted: .restricted, candidate: .restricted))
    }

    @Test("compile rejects traversable roots")
    func compileRejectsTraversal() {
        let enforcer = PlatformSandboxEnforcer()
        #expect(throws: SandboxError.self) {
            try enforcer.compile(
                mode: .readOnly,
                roots: [URL(fileURLWithPath: "/safe/..")],
                capabilities: []
            )
        }
    }

    @Test("compile accepts clean roots")
    func compileAcceptsCleanRoots() throws {
        let enforcer = PlatformSandboxEnforcer()
        let profile = try enforcer.compile(
            mode: .readOnly,
            roots: [URL(fileURLWithPath: "/safe")],
            capabilities: [.fileSystemWrite, .openGrokHomeAccess]
        )
        #expect(profile.mode == .readOnly)
        #expect(profile.capabilities.contains(.openGrokHomeAccess))
        #expect(profile.profileName == .readOnly)
    }

    @Test("bootstrap enforcer apply still reports unsupported for non-none")
    func bootstrapApplyUnsupported() async throws {
        let enforcer = BootstrapSandboxEnforcer()
        let profile = try enforcer.compile(
            mode: .readOnly,
            roots: [URL(fileURLWithPath: "/safe")],
            capabilities: []
        )
        do {
            try await enforcer.apply(profile)
            Issue.record("Expected unsupported")
        } catch SandboxError.unsupported {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("profile name parsing")
    func profileNameParsing() {
        #expect(ProfileName(parsing: "workspace") == .workspace)
        #expect(ProfileName(parsing: "read-only") == .readOnly)
        #expect(ProfileName(parsing: "readonly") == .readOnly)
        #expect(ProfileName(parsing: "off") == .off)
        #expect(ProfileName(parsing: "none") == .off)
        #expect(ProfileName(parsing: "my-custom") == .custom("my-custom"))
    }

    @Test("workspace profile resolves writable roots")
    func workspaceProfileResolve() throws {
        let ws = URL(fileURLWithPath: "/tmp/opengrok-sandbox-test-ws")
        let resolved = try ProfileName.workspace.resolve(
            workspace: ws,
            config: SandboxConfig()
        )
        #expect(resolved.defaultRead)
        #expect(!resolved.restrictNetwork)
        #expect(resolved.readWrite.contains(where: { $0.path == ws.path }))
    }

    @Test("off profile cannot be resolved as base")
    func offCannotResolve() {
        #expect(throws: SandboxError.self) {
            try ProfileName.off.resolve(
                workspace: URL(fileURLWithPath: "/tmp"),
                config: SandboxConfig()
            )
        }
    }

    @Test("project profiles cannot redefine global custom profiles")
    func projectMergeAdditiveOnly() {
        var global = SandboxConfig(profiles: [
            "secure": ProfileConfig(extends: "workspace", deny: [".env"]),
        ])
        let project = SandboxConfig(profiles: [
            "secure": ProfileConfig(extends: "workspace", deny: []),
            "local": ProfileConfig(extends: "read-only"),
        ])
        mergeProjectProfiles(into: &global, project: project)
        #expect(global.profiles["secure"]?.deny == [".env"])
        #expect(global.profiles["local"] != nil)
        let conflicts = mismatchedProfileNames(
            global: SandboxConfig(profiles: [
                "secure": ProfileConfig(extends: "workspace", deny: [".env"]),
            ]),
            project: project
        )
        #expect(conflicts == ["secure"])
    }

    @Test("website origin parse rejects IP and wildcards")
    func websiteOriginParse() throws {
        let origin = try WebsiteOrigin.parse("https://example.com")
        #expect(origin.hostname == "example.com")
        #expect(origin.port == 443)
        #expect(throws: WebsiteOriginError.self) {
            try WebsiteOrigin.parse("https://1.2.3.4")
        }
        #expect(throws: WebsiteOriginError.self) {
            try WebsiteOrigin.parse("https://*.example.com")
        }
        #expect(throws: WebsiteOriginError.self) {
            try WebsiteOrigin.parse("https://user:pass@example.com")
        }
    }

    @Test("website policy deny wins over allow")
    func websitePolicyDenyWins() throws {
        let o = try WebsiteOrigin.parse("https://evil.example")
        let policy = WebsitePolicy(allow: [o], deny: [o], defaultAction: .allow)
        #expect(policy.evaluate(o) == .deny)
    }

    @Test("child network policy from restrict flag")
    func childNetworkFromRestrict() {
        #expect(ChildNetworkPolicy.from(restrictNetwork: true) == .blocked)
        #expect(ChildNetworkPolicy.from(restrictNetwork: false) == .unrestricted)
    }

    @Test("pathIsUnderRoot lexical containment")
    func pathContainment() {
        #expect(pathIsUnderRoot(candidate: "/a/b/c", root: "/a/b"))
        #expect(!pathIsUnderRoot(candidate: "/a/bc", root: "/a/b"))
        #expect(pathIsUnderRoot(candidate: "/a/b", root: "/a/b"))
    }

    @Test("mode from profile")
    func modeFromProfile() {
        #expect(SandboxMode.from(profile: .off) == .none)
        #expect(SandboxMode.from(profile: .readOnly) == .readOnly)
        #expect(SandboxMode.from(profile: .workspace) == .restricted)
    }

    @Test("bwrap marker alone does not suppress reexec")
    func bwrapMarkerAloneDoesNotSuppressReexec() {
        let argv = bwrapReexecCommand(
            denyWrite: ["/tmp"],
            denyRead: [],
            environment: [bwrapEnvVar: "1"]
        )
        #expect(argv != nil)
    }

    @Test("verified bwrap receipt suppresses reexec")
    func verifiedBwrapReceiptSuppressesReexec() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenGrokBwrapReceipt-\(UUID().uuidString)", isDirectory: true)
        let environment = ["OPENGROK_HOME": home.path]
        defer { try? FileManager.default.removeItem(at: home) }

        let receipt = try createBwrapReceipt(environment: environment)
        var inside = environment
        inside[bwrapEnvVar] = "1"
        inside[bwrapReceiptPathEnvVar] = receipt.path
        inside[bwrapReceiptTokenEnvVar] = receipt.token
        #expect(isVerifiedInsideBwrap(environment: inside))
        #if os(Linux)
        #expect(PlatformSandboxSupport.supportInfo(environment: inside).isSupported)
        #expect(PlatformSandboxEnforcer().detectSupportedMode(environment: inside) == .restricted)
        #endif
        #expect(bwrapReexecCommand(
            denyWrite: ["/tmp"],
            denyRead: [],
            environment: inside
        ) == nil)
    }

    @Test("bwrap reexec builds argv outside")
    func bwrapOutside() {
        let argv = bwrapReexecCommand(
            denyWrite: ["/tmp"],
            denyRead: [],
            environment: [:],
            arguments: ["--help"],
            executable: URL(fileURLWithPath: "/bin/open-grok"),
            bwrapPath: "/usr/bin/bwrap"
        )
        #expect(argv != nil)
        #expect(argv?.first == "/usr/bin/bwrap")
        #expect(argv?.prefix(3).elementsEqual(["/usr/bin/bwrap", "--cap-drop", "ALL"]) == true)
        #expect(argv?.contains("--ro-bind") == true)
        #expect(argv?.suffix(2).elementsEqual(["/bin/open-grok", "--help"]) == true)
    }

    @Test("bwrap materializes profile roots before deny overlays")
    func bwrapMaterializesProfileRoots() {
        let argv = bwrapReexecCommand(
            denyWrite: ["/tmp"],
            denyRead: [],
            environment: [:],
            arguments: ["--help"],
            executable: URL(fileURLWithPath: "/bin/open-grok"),
            bwrapPath: "/usr/bin/bwrap",
            readOnly: ["/etc"],
            readWrite: ["/tmp"],
            defaultRead: true
        )
        #expect(argv != nil)
        #expect(argv?.contains("--cap-drop") == true)
        #expect(argv?.contains("ALL") == true)
        #expect(argv?.contains("--bind") == true)
        #expect(argv?.contains("--unshare-net") == false)
        if let argv {
            let denyIndex = argv.lastIndex(of: "/tmp") ?? -1
            let writableIndex = argv.firstIndex(of: "--bind") ?? -1
            #expect(writableIndex >= 0)
            #expect(denyIndex > writableIndex)
        }
    }

    @Test("requires read deny only for custom with deny list")
    func requiresReadDenyCustom() {
        let ws = URL(fileURLWithPath: "/tmp")
        let config = SandboxConfig(profiles: [
            "denytest": ProfileConfig(extends: "workspace", deny: [".env"]),
        ])
        #expect(requiresReadDeny(profile: .custom("denytest"), workspace: ws, config: config))
        #expect(!requiresReadDeny(profile: .workspace, workspace: ws, config: config))
        #expect(!requiresReadDeny(profile: .custom("missing"), workspace: ws, config: config))
    }

    @Test("sandbox logger metrics")
    func loggerMetrics() {
        let logger = SandboxLogger()
        logger.log(.fsViolation(profile: "workspace", target: "/etc/passwd", operation: "open"))
        logger.log(.netViolation(profile: "workspace", target: "1.2.3.4:80"))
        #expect(logger.metrics.fsViolationCount == 1)
        #expect(logger.metrics.netViolationCount == 1)
        #expect(logger.snapshot().count == 2)
    }

    @Test("validateResume throws modePinningViolation on downgrade attempt")
    func validateResumeDowngrade() {
        let enforcer = PlatformSandboxEnforcer()
        #expect(throws: SandboxError.self) {
            try enforcer.validateResume(persisted: .restricted, candidate: .readOnly)
        }
        #expect(throws: SandboxError.self) {
            try enforcer.validateResume(persisted: .restricted, candidate: .none)
        }
        #expect(throws: SandboxError.self) {
            try enforcer.validateResume(persisted: .readOnly, candidate: .none)
        }
        #expect(throws: Never.self) {
            try enforcer.validateResume(persisted: .readOnly, candidate: .restricted)
        }
    }

    @Test("rejectTraversableRoot rejects NUL bytes and empty components")
    func rejectHostileRoots() {
        #expect(throws: SandboxError.self) {
            try rejectTraversableRoot(URL(fileURLWithPath: "/workspace/..\0"))
        }
        #expect(throws: SandboxError.self) {
            try rejectTraversableRoot(URL(fileURLWithPath: "/workspace/../etc"))
        }
    }

    @Test("the NUL guard actually fires, on a root with no traversal to fall back on")
    func nulGuardIsLiveOnItsOwn() throws {
        // `/workspace/a\0b` has no ".." component, so only the NUL check can
        // reject it. Asserting the message pins *which* guard fired: the old
        // code tested the raw `URL.path`, where a NUL is always rendered
        // "%00", so this guard never ran on any platform and the sibling test
        // above passed on macOS purely via the traversal check.
        let hostile = URL(fileURLWithPath: "/workspace/a\0b")
        // Precondition for the test to mean anything.
        #expect(!hostile.path.contains("\0"), "URL.path is expected to encode NUL, not preserve it")

        do {
            try rejectTraversableRoot(hostile)
            Issue.record("a root containing NUL must be rejected")
        } catch let error as SandboxError {
            guard case .profileInvalid(let detail) = error, detail.contains("NUL") else {
                Issue.record("expected the NUL guard to fire, got \(error)")
                return
            }
        }
    }

    #if os(macOS)
    @Test("seatbelt profile keeps process network open for provider traffic")
    func seatbeltProcessNetworkAlwaysAllowed() {
        func build(restrictNetwork: Bool) -> String {
            let resolved = ResolvedSandboxProfile(
                name: "custom",
                readOnly: [],
                readWrite: [URL(fileURLWithPath: "/tmp/ws")],
                deny: [URL(fileURLWithPath: "/tmp/ws/.env")],
                denyEntries: ["**/*.pem"],
                defaultRead: true,
                restrictNetwork: restrictNetwork
            )
            return buildSeatbeltProfile(resolved, workspace: URL(fileURLWithPath: "/tmp/ws"))
        }

        for restrictNetwork in [true, false] {
            let sbpl = build(restrictNetwork: restrictNetwork)
            #expect(sbpl.contains("(allow network*)"))
            #expect(!sbpl.contains("(deny network*)"))
            #expect(sbpl.contains("deny file-write-data"))
            #expect(sbpl.contains("deny file-write-unlink"))
            #expect(sbpl.contains("deny file-write-create"))
            #expect(sbpl.contains("/private/tmp/ws/.env") || sbpl.contains("/tmp/ws/.env"))
        }
    }
    #else
    @Test("seatbelt profile builder reports unsupported on non-macOS")
    func seatbeltProfileNonMacOS() {
        let resolved = ResolvedSandboxProfile(
            name: "custom",
            readOnly: [],
            readWrite: [URL(fileURLWithPath: "/tmp/ws")],
            deny: [URL(fileURLWithPath: "/tmp/ws/.env")],
            denyEntries: ["**/*.pem"],
            defaultRead: true,
            restrictNetwork: true
        )
        let sbpl = buildSeatbeltProfile(resolved, workspace: URL(fileURLWithPath: "/tmp/ws"))
        #expect(sbpl.contains("unsupported"))
        #expect(throws: SandboxError.self) {
            try applySeatbeltProfile(sbpl)
        }
    }
    #endif

    @Test("child network policy launch transform")
    func childNetworkPolicyRestrictedLaunch() throws {
        // .unrestricted passes through everywhere.
        let (uExe, uArgs) = try ChildNetworkPolicy.unrestricted.restrictedLaunch(
            executable: "/bin/echo",
            arguments: ["hi"]
        )
        #expect(uExe == "/bin/echo")
        #expect(uArgs == ["hi"])

        // .websites is modeled upstream but never enforced
        // (xai-grok-sandbox/src/network_policy.rs:3), so the port must refuse
        // loudly on every platform rather than degrade to all-or-nothing.
        #expect(throws: SandboxError.self) {
            try ChildNetworkPolicy.websites(WebsitePolicy()).restrictedLaunch(
                executable: "/bin/echo",
                arguments: []
            )
        }

        let blocked = ChildNetworkPolicy.blocked
        #if os(Linux)
        // .blocked is real on Linux: wrapped through the network-denying
        // unshare re-exec when the host can enforce, typed unsupported when
        // it cannot — never a silent no-op. The probe decides which branch
        // this host is on; both are asserted, so an incapable host cannot
        // fake success and a capable host cannot silently stop enforcing.
        if LinuxChildNetworkRestriction.probeHost() != nil {
            let (exe, args) = try blocked.restrictedLaunch(
                executable: "/bin/echo",
                arguments: ["hi"]
            )
            #expect(exe.hasSuffix("unshare"))
            #expect(args.contains("--net"))
            #expect(Array(args.suffix(2)) == ["/bin/echo", "hi"])
        } else {
            #expect(throws: SandboxError.self) {
                try blocked.restrictedLaunch(executable: "/bin/echo", arguments: ["hi"])
            }
        }
        #else
        // Off Linux the per-child filter is a deliberate no-op, matching
        // upstream's non-Linux `Ok(())` (child_net.rs:226-229); macOS keeps
        // process-level network access available for provider sampling.
        let (bExe, bArgs) = try blocked.restrictedLaunch(
            executable: "/bin/echo",
            arguments: ["hi"]
        )
        #expect(bExe == "/bin/echo")
        #expect(bArgs == ["hi"])
        #endif
    }

    @Test("bwrap reexec never isolates provider network")
    func bwrapReexecKeepsProviderNetwork() {
        let argv = bwrapReexecCommand(
            denyWrite: [],
            denyRead: [],
            restrictNetwork: true,
            environment: [:]
        )
        #expect(argv?.contains("--unshare-net") == false)
        #expect(argv?.contains(bwrapEnvVar) == true)
    }

    @Test("bwrap marker without a receipt cannot claim enforcement")
    func bwrapMarkerRequiresReceipt() {
        #expect(throws: SandboxError.self) {
            try validateBwrapReceipt(environment: [bwrapEnvVar: "1"])
        }
    }

    @Test("bwrap receipt is one-use and scoped to the sandbox home")
    func bwrapReceiptValidation() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenGrokBwrapReceipt-\(UUID().uuidString)", isDirectory: true)
        let environment = ["OPENGROK_HOME": home.path]
        defer { try? FileManager.default.removeItem(at: home) }

        let receipt = try createBwrapReceipt(environment: environment)
        var inside = environment
        inside[bwrapEnvVar] = "1"
        inside[bwrapReceiptPathEnvVar] = receipt.path
        inside[bwrapReceiptTokenEnvVar] = receipt.token
        try validateBwrapReceipt(environment: inside)
        #expect(!FileManager.default.fileExists(atPath: receipt.path))
        #expect(throws: SandboxError.self) {
            try validateBwrapReceipt(environment: inside)
        }
    }

    @Test("glob validation accepts supported subset and rejects hostile/ambiguous globs")
    func globValidation() throws {
        #expect(throws: Never.self) { try validateDenyGlob("**/*.pem") }
        #expect(throws: Never.self) { try validateDenyGlob("secrets/**") }
        #expect(throws: Never.self) { try validateDenyGlob("[a-z].rs") }
        #expect(throws: Never.self) { try validateDenyGlob("[!a]b") }

        #expect(throws: SandboxError.self) { try validateDenyGlob("{a,b}") }
        #expect(throws: SandboxError.self) { try validateDenyGlob("a\\b") }
        #expect(throws: SandboxError.self) { try validateDenyGlob("a**b") }
        #expect(throws: SandboxError.self) { try validateDenyGlob("[[:alpha:]]") }
    }

    @Test("glob to seatbelt regex translation")
    func globRegexTranslation() throws {
        let regexes = try globToSeatbeltRegexes(workspace: URL(fileURLWithPath: "/ws"), glob: "**/*.pem")
        #expect(!regexes.isEmpty)
        #expect(regexes.contains(where: { $0.contains("(.*/)?") }))
    }

    @Test("bwrap plan for devbox write-denies /data")
    func bwrapPlanDevbox() {
        let ws = URL(fileURLWithPath: "/tmp/devbox-ws")
        let plan = bwrapDenyPlan(profile: .devbox, workspace: ws)
        #expect(plan != nil)
        #expect(plan?.denyWrite.contains("/data") == true)
        #expect(plan?.defaultRead == true)
        #expect(plan?.readWrite.contains(ws.path) == true)
    }

    @Test("bwrap blocked placeholder creates zero-permission path")
    func bwrapPlaceholder() {
        let env = ["OPENGROK_HOME": "/tmp/opengrok-test-placeholder-\(UUID().uuidString)"]
        defer { try? FileManager.default.removeItem(atPath: env["OPENGROK_HOME"]!) }
        let filePlaceholder = bwrapBlockedPlaceholder(name: "test-file", wantDir: false, environment: env)
        #expect(filePlaceholder != nil)
        #expect(FileManager.default.fileExists(atPath: filePlaceholder!.path))
    }

    @Test("windows sandbox creation functions throw unsupported")
    func windowsSeamsUnsupported() {
        let resolved = ResolvedSandboxProfile(
            name: "test",
            readOnly: [],
            readWrite: [],
            deny: [],
            defaultRead: true,
            restrictNetwork: false
        )
        #expect(throws: SandboxError.self) {
            try createRestrictedTokenSandbox(profile: resolved)
        }
        #expect(throws: SandboxError.self) {
            try createJobObjectSandbox(profile: resolved)
        }
    }

    @Test("YOLO mode autoAllowBash prompting control does not disable process-wide sandbox")
    func yoloModeControls() {
        setAutoAllowBash(true)
        // shouldAutoAllowBash is true only when sandbox is applied
        #expect(shouldAutoAllowBash() == isSandboxActive())
        setAutoAllowBash(false)
        #expect(!shouldAutoAllowBash())
    }

    @Test("sandboxProfileConflictWarnings generates project collision warning")
    func profileConflictWarningFormat() {
        let global = SandboxConfig(profiles: [
            "custom": ProfileConfig(extends: "workspace", deny: [".env"])
        ])
        let project = SandboxConfig(profiles: [
            "custom": ProfileConfig(extends: "workspace", deny: [])
        ])
        let conflicts = mismatchedProfileNames(global: global, project: project)
        #expect(conflicts == ["custom"])
    }

    @Test("support info is platform-labeled")
    func supportInfo() {
        let info = PlatformSandboxSupport.supportInfo()
        #expect(!info.details.isEmpty)
        #expect(PlatformSandboxSupport.platformLabel.contains("/"))
    }

    #if os(Linux)
    @Test("ordinary Linux capability remains unsupported until reexec verifies confinement")
    func ordinaryLinuxCapabilityIsUnsupported() {
        let environment = ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? ""]
        let info = PlatformSandboxSupport.supportInfo(environment: environment)
        #expect(!info.isSupported)
        #expect(info.backend == .none)
        #expect(info.details.contains("activation") || info.details.contains("re-exec"))
        #expect(PlatformSandboxEnforcer().detectSupportedMode() == .none)
    }

    @Test("caller supplied bwrap marker cannot authorize support or apply")
    func callerSuppliedBwrapMarkerCannotAuthorize() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenGrokBwrapSpoof-\(UUID().uuidString)", isDirectory: true)
        let environment = [
            "OPENGROK_HOME": home.path,
            bwrapEnvVar: "1",
        ]
        defer { try? FileManager.default.removeItem(at: home) }

        #expect(!isVerifiedInsideBwrap(environment: environment))
        #expect(!isInsideBwrap(environment: environment))
        #expect(!PlatformSandboxSupport.supportInfo(environment: environment).isSupported)
        #expect(PlatformSandboxEnforcer().detectSupportedMode() == .none)

        let workspace = home.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let resolved = try ProfileName.workspace.resolve(
            workspace: workspace,
            config: SandboxConfig()
        )
        let hooks = LinuxBwrapReexecHooks(
            environment: { environment },
            arguments: { [] },
            executable: { "/bin/open-grok" },
            supportInfo: { PlatformSandboxSupport.supportInfo(environment: environment) },
            discoverBubblewrap: { _ in nil },
            probe: { _ in false },
            exec: { _, _, _ in
                throw SandboxError.enforcementFailed("spoofed marker reached exec")
            }
        )
        #expect(throws: SandboxError.self) {
            try PlatformEnforcer.apply(
                resolved: resolved,
                workspace: workspace,
                profile: .workspace,
                linuxReexecHooks: hooks
            )
        }
    }
    #endif

    #if os(Linux)
    private final class LinuxReexecCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var path = ""
        private var arguments: [String] = []

        func record(path: String, arguments: [String]) {
            lock.lock(); defer { lock.unlock() }
            self.path = path
            self.arguments = arguments
        }

        func snapshot() -> (String, [String]) {
            lock.lock(); defer { lock.unlock() }
            return (path, arguments)
        }
    }

    @Test("Linux reexec uses an injected absolute bwrap handoff")
    func linuxReexecHandoffIsInjectable() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenGrokBwrap-\(UUID().uuidString)", isDirectory: true)
        let home = workspace.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        // A box rather than captured `var`s: the `exec` hook is `@Sendable`,
        // and Swift 6 rejects mutating captured locals from it. This test is
        // `#if os(Linux)`, so that rejection only ever appears on Linux.
        let captured = LinuxReexecCapture()
        let hooks = LinuxBwrapReexecHooks(
            environment: { ["OPENGROK_HOME": home.path] },
            arguments: { ["--child-arg"] },
            executable: { "/bin/open-grok" },
            supportInfo: {
                SandboxSupportInfo(
                    isSupported: true,
                    backend: .linuxBubblewrap,
                    details: "injected"
                )
            },
            discoverBubblewrap: { _ in "/usr/bin/bwrap" },
            probe: { _ in true },
            exec: { path, arguments, _ in
                captured.record(path: path, arguments: arguments)
                throw SandboxError.enforcementFailed("captured for test")
            }
        )

        let manager = SandboxManager(
            profile: .strict,
            workspace: workspace,
            linuxReexecHooks: hooks
        )
        #expect(throws: SandboxError.self) {
            try manager.apply(workspace: workspace)
        }
        let (path, arguments) = captured.snapshot()
        #expect(path == "/usr/bin/bwrap")
        #expect(arguments.contains("--"))
        #expect(arguments.suffix(2).elementsEqual(["/bin/open-grok", "--child-arg"]))
        #expect(!arguments.contains("--unshare-net"))
        #expect(!manager.applied)
    }
    #endif
}
