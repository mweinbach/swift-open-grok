import Foundation
import Testing
@testable import OpenGrokPluginMarketplace

// The SHA-pinning trust model is the only integrity control on remote plugin
// code, so these tests pin the policy composition rules rather than just the
// happy path. A regression here would silently weaken the trust model below the
// Rust reference.

@Suite("plugin require_sha policy")
struct PluginRequireSHAPolicyTests {
    @Test("defaults off so existing unpinned catalogs keep installing")
    func defaultsOff() {
        #expect(PluginTrustPolicy.requireSHA(configuredValue: nil, environment: [:]) == false)
        #expect(PluginTrustPolicy.requireSHA(configuredValue: false, environment: [:]) == false)
    }

    @Test("config alone enables")
    func configEnables() {
        #expect(PluginTrustPolicy.requireSHA(configuredValue: true, environment: [:]))
    }

    @Test("either environment variable alone enables")
    func environmentEnables() {
        #expect(PluginTrustPolicy.requireSHA(
            configuredValue: nil,
            environment: ["OPENGROK_MARKETPLACE_REQUIRE_SHA": "1"]
        ))
        #expect(PluginTrustPolicy.requireSHA(
            configuredValue: nil,
            environment: ["GROK_MARKETPLACE_REQUIRE_SHA": "true"]
        ))
    }

    @Test("a falsy environment value cannot relax a config that asked for pinning")
    func tightenOnly() {
        // This is the property that makes the OR correct rather than a
        // precedence: an attacker-controlled environment must not be able to
        // switch off an administrator's policy.
        for falsy in ["0", "false", "no", "off", "disabled"] {
            #expect(
                PluginTrustPolicy.requireSHA(
                    configuredValue: true,
                    environment: ["OPENGROK_MARKETPLACE_REQUIRE_SHA": falsy]
                ),
                "falsy env '\(falsy)' must not relax config-set policy"
            )
        }
    }

    @Test("unrecognized environment values do not enable")
    func unrecognizedEnvironment() {
        #expect(PluginTrustPolicy.requireSHA(
            configuredValue: nil,
            environment: ["OPENGROK_MARKETPLACE_REQUIRE_SHA": "maybe"]
        ) == false)
    }
}

@Suite("plugin commit SHA validation")
struct PluginPinTests {
    @Test("accepts exactly 40 and 64 hex characters")
    func acceptsFullSHAs() {
        #expect(PluginPin.isFullCommitSHA(String(repeating: "a", count: 40)))
        #expect(PluginPin.isFullCommitSHA(String(repeating: "0", count: 64)))
        #expect(PluginPin.isFullCommitSHA(String(repeating: "A", count: 40)))
    }

    @Test("rejects short prefixes, branches, and tags")
    func rejectsMutableRefs() {
        // Short prefixes and names are mutable or forgeable, so pinning to one
        // proves nothing about what gets checked out.
        #expect(PluginPin.isFullCommitSHA(String(repeating: "a", count: 39)) == false)
        #expect(PluginPin.isFullCommitSHA(String(repeating: "a", count: 41)) == false)
        #expect(PluginPin.isFullCommitSHA("main") == false)
        #expect(PluginPin.isFullCommitSHA("v1.2.3") == false)
        #expect(PluginPin.isFullCommitSHA("") == false)
        #expect(PluginPin.isFullCommitSHA(String(repeating: "z", count: 40)) == false)
    }

    @Test("a full-hex ref is hoisted into the sha slot")
    func hoistsPin() {
        let sha = String(repeating: "b", count: 40)
        let hoisted = PluginPin.hoistPinSlots(ref: sha, sha: nil)
        #expect(hoisted.sha == sha)
        #expect(hoisted.ref == nil)
    }

    @Test("an explicit sha is never displaced by a ref")
    func explicitSHAWins() {
        let sha = String(repeating: "c", count: 40)
        let hoisted = PluginPin.hoistPinSlots(ref: "main", sha: sha)
        #expect(hoisted.sha == sha)
        #expect(hoisted.ref == "main")
    }
}

@Suite("plugin pin gate")
struct PluginPinGateTests {
    @Test("permits anything when pinning is off")
    func offPermits() throws {
        try PluginPinGate.ensurePinned(
            requireSHA: false, sha: nil, plugin: "p", url: "https://example.com/p.git"
        )
    }

    @Test("permits a pinned remote when pinning is on")
    func pinnedPermitted() throws {
        try PluginPinGate.ensurePinned(
            requireSHA: true,
            sha: String(repeating: "d", count: 40),
            plugin: "p",
            url: "https://example.com/p.git"
        )
    }

    @Test("refuses an unpinned remote as a hard failure, not a skip")
    func unpinnedRefused() {
        #expect(throws: PluginInstallError.self) {
            try PluginPinGate.ensurePinned(
                requireSHA: true, sha: nil, plugin: "p", url: "https://example.com/p.git"
            )
        }
        #expect(throws: PluginInstallError.self) {
            try PluginPinGate.ensurePinned(
                requireSHA: true, sha: "main", plugin: "p", url: "https://example.com/p.git"
            )
        }
    }
}

@Suite("plugin install source parsing")
struct PluginInstallSourceTests {
    private var cwd: URL { URL(fileURLWithPath: "/tmp/project") }

    @Test("owner/repo shorthand expands to a GitHub remote")
    func githubShorthand() {
        let source = PluginInstallSource.parse("owner/repo", cwd: cwd)
        #expect(source == .git(url: "https://github.com/owner/repo.git", ref: nil, subdirectory: nil))
        #expect(source.isRemote)
    }

    @Test("https URLs stay remote and carry ref and subdirectory")
    func httpsWithRefAndSubdir() {
        let source = PluginInstallSource.parse(
            "https://example.com/o/p.git@abc#tools", cwd: cwd
        )
        #expect(source == .git(url: "https://example.com/o/p.git", ref: "abc", subdirectory: "tools"))
    }

    @Test("relative paths resolve against cwd and stay local")
    func relativeLocal() {
        let source = PluginInstallSource.parse("./local-plugin", cwd: cwd)
        #expect(source == .local(path: "/tmp/project/local-plugin", subdirectory: nil))
        // Local installs are exempt from pinning; there is nothing to pin.
        #expect(source.isRemote == false)
    }

    @Test("distinct sources never share an install directory key")
    func repoKeysAreDistinct() {
        let a = PluginInstallLocation.repoKey(sourceIdentifier: "https://github.com/one/plugin.git")
        let b = PluginInstallLocation.repoKey(sourceIdentifier: "https://gitlab.com/two/plugin.git")
        // Both basenames are "plugin"; only the hashed suffix keeps them apart.
        #expect(a != b)
        #expect(a.hasPrefix("plugin-"))
        #expect(b.hasPrefix("plugin-"))
    }
}

@Suite("git operand validation")
struct PluginGitOperandTests {
    @Test("rejects operands git would read as options")
    func rejectsOptionLike() {
        #expect(throws: PluginInstallError.self) {
            try PluginGitClient.validateOperand("--upload-pack=evil")
        }
        #expect(throws: PluginInstallError.self) {
            try PluginGitClient.validateOperand("")
        }
        #expect(throws: PluginInstallError.self) {
            try PluginGitClient.validateOperand("ok\0injected")
        }
    }

    @Test("accepts ordinary URLs")
    func acceptsURLs() throws {
        try PluginGitClient.validateOperand("https://github.com/owner/repo.git")
        try PluginGitClient.validateOperand(String(repeating: "a", count: 40))
    }
}
