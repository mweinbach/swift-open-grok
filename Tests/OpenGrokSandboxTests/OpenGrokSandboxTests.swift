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

    @Test("bwrap reexec returns nil when already inside")
    func bwrapInside() {
        let argv = bwrapReexecCommand(
            denyWrite: ["/tmp"],
            denyRead: [],
            environment: [bwrapEnvVar: "1"]
        )
        #expect(argv == nil)
    }

    @Test("bwrap reexec builds argv outside")
    func bwrapOutside() {
        let argv = bwrapReexecCommand(
            denyWrite: ["/tmp"],
            denyRead: [],
            environment: [:],
            arguments: ["--help"],
            executable: URL(fileURLWithPath: "/bin/open-grok")
        )
        #expect(argv != nil)
        #expect(argv?.first == "bwrap")
        #expect(argv?.contains("--ro-bind") == true)
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

    #if os(macOS)
    @Test("seatbelt profile includes deny and network rules")
    func seatbeltSBPL() {
        let resolved = ResolvedSandboxProfile(
            name: "workspace",
            readOnly: [],
            readWrite: [URL(fileURLWithPath: "/tmp/ws")],
            deny: [URL(fileURLWithPath: "/tmp/ws/.env")],
            defaultRead: true,
            restrictNetwork: false
        )
        let sbpl = buildSeatbeltProfile(resolved)
        #expect(sbpl.contains("(version 1)"))
        #expect(sbpl.contains("deny file-read*"))
        #expect(sbpl.contains("allow network*"))
    }
    #endif

    @Test("support info is platform-labeled")
    func supportInfo() {
        let info = PlatformSandboxSupport.supportInfo()
        #expect(!info.details.isEmpty)
        #expect(PlatformSandboxSupport.platformLabel.contains("/"))
    }
}
