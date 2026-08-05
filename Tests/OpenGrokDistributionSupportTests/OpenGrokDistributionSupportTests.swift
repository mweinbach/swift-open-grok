// OpenGrokDistributionSupportTests.swift
//
// Every expectation here is anchored to a concrete line in the Rust reference
// at 80dff0a9dcb24121b976b9f920fbe442af40ea88 (see the target's source
// comments for the file:line citations).

import Foundation
import Testing

@testable import OpenGrokDistributionSupport
import OpenGrokUpdate

@Suite("Release version and tag rules")
struct ReleaseVersionTests {
    @Test("accepts the versions the reference actually ships")
    func acceptsShippedVersions() {
        for raw in [
            "0.1.220-open-grok.53",
            "0.1.220-open-grok.21",
            "0.1.220-alpha.4",
            "0.2.5",
            "1.0.0",
            "0.1.150-alpha-1",
        ] {
            #expect(ReleaseVersion(raw)?.value == raw, "should accept \(raw)")
        }
    }

    @Test("rejects strings the reference's regex rejects")
    func rejectsMalformed() {
        for raw in [
            "",
            "1.2",
            "1.2.3.4",
            "v",
            "1.2.3-",
            "1.2.3-alpha..1",
            "1.2.3+build",        // build metadata is outside the pattern
            "1.2.3-alpha_1",      // underscore is not [0-9A-Za-z.-]
            "01.2.3-α",
            "abc",
        ] {
            #expect(ReleaseVersion(raw) == nil, "should reject \(raw)")
        }
    }

    @Test("strips an optional leading v and reconstructs the tag")
    func tagRoundTrip() throws {
        let version = try #require(ReleaseVersion("v0.1.220-open-grok.53"))
        #expect(version.value == "0.1.220-open-grok.53")
        #expect(version.tag == "v0.1.220-open-grok.53")
        #expect(ReleaseVersion("0.1.220-open-grok.53") == version)
    }

    @Test("prerelease is everything after the first dash")
    func prereleaseComponent() throws {
        let pre = try #require(ReleaseVersion("0.1.220-open-grok.53"))
        #expect(pre.prerelease == "open-grok.53")
        #expect(pre.isPrerelease)

        let stable = try #require(ReleaseVersion("1.0.0"))
        #expect(stable.prerelease == nil)
        #expect(!stable.isPrerelease)
    }

    @Test("tag must agree with OPEN_GROK_VERSION, as the release workflow requires")
    func tagAnchoring() {
        #expect(ReleaseVersion.tagMatchesVersionFile(
            tag: "v0.1.220-open-grok.53",
            versionFileContents: "0.1.220-open-grok.53\n"
        ))
        // The workflow reads only the first line and trims it.
        #expect(ReleaseVersion.tagMatchesVersionFile(
            tag: "v0.1.220-open-grok.53",
            versionFileContents: "0.1.220-open-grok.53\r\ntrailing junk\n"
        ))
        // A tag naming a different release must not pass.
        #expect(!ReleaseVersion.tagMatchesVersionFile(
            tag: "v0.1.220-open-grok.21",
            versionFileContents: "0.1.220-open-grok.53\n"
        ))
        // A tag without the `v` prefix is not the tag form the workflow creates.
        #expect(!ReleaseVersion.tagMatchesVersionFile(
            tag: "0.1.220-open-grok.53",
            versionFileContents: "0.1.220-open-grok.53\n"
        ))
    }
}

@Suite("Release platform naming")
struct ReleasePlatformTests {
    @Test("artifact names match the two release builders byte for byte")
    func artifactNames() {
        #expect(ReleasePlatform.macOSAppleSilicon.artifactName == "open-grok-macos-aarch64")
        #expect(ReleasePlatform.windowsX86_64.artifactName == "open-grok-windows-x86_64.exe")
    }

    @Test("checksum sidecar appends .sha256 to the artifact name")
    func checksumNames() {
        #expect(
            ReleasePlatform.macOSAppleSilicon.checksumAssetName
                == "open-grok-macos-aarch64.sha256"
        )
        // The Windows sidecar keeps the `.exe` in the middle: the builder
        // appends to `$artifactPath`, it does not replace the extension.
        #expect(
            ReleasePlatform.windowsX86_64.checksumAssetName
                == "open-grok-windows-x86_64.exe.sha256"
        )
    }

    @Test("target triples match the release build invocations")
    func targetTriples() {
        #expect(ReleasePlatform.macOSAppleSilicon.targetTriple == "aarch64-apple-darwin")
        #expect(ReleasePlatform.windowsX86_64.targetTriple == "x86_64-pc-windows-msvc")
    }

    @Test("installer asset differs per platform")
    func installerAssets() {
        #expect(ReleasePlatform.macOSAppleSilicon.installerAssetName == "install.sh")
        #expect(ReleasePlatform.windowsX86_64.installerAssetName == "install.ps1")
    }

    @Test("the POSIX installer accepts only Apple Silicon macOS")
    func posixHostDetection() {
        #expect(ReleasePlatform.forPosixHost(unameS: "Darwin", unameM: "arm64") == .macOSAppleSilicon)
        #expect(ReleasePlatform.forPosixHost(unameS: "Darwin", unameM: "aarch64") == .macOSAppleSilicon)
        #expect(ReleasePlatform.forPosixHost(unameS: "Darwin", unameM: "x86_64") == nil)
        #expect(ReleasePlatform.forPosixHost(unameS: "Linux", unameM: "aarch64") == nil)
        #expect(!ReleasePlatform.windowsX86_64.isSupportedByPosixInstaller)
    }
}

@Suite("Checksum sidecar generation and verification")
struct ReleaseChecksumTests {
    /// SHA-256 of the empty input, a NIST-published vector — this pins that the
    /// digest really is computed rather than echoed back.
    static let emptyDigest =
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    @Test("generated sidecar uses the two-space shasum line format")
    func sidecarFormat() throws {
        let checksum = try #require(
            ReleaseChecksum.generate(for: [UInt8](), artifactName: "open-grok-macos-aarch64")
        )
        #expect(checksum.digest == Self.emptyDigest)
        #expect(checksum.fileContents == "\(Self.emptyDigest)  open-grok-macos-aarch64\n")
        // Exactly two spaces, not one and not a tab.
        #expect(checksum.fileContents.contains("  open-grok"))
        #expect(!checksum.fileContents.contains("\t"))
    }

    @Test("digest normalization enforces 64 hex characters and lower-cases")
    func digestNormalization() {
        #expect(ReleaseChecksum.normalizedDigest(Self.emptyDigest.uppercased()) == Self.emptyDigest)
        #expect(ReleaseChecksum.normalizedDigest("  \(Self.emptyDigest)  ") == Self.emptyDigest)
        #expect(ReleaseChecksum.normalizedDigest(String(Self.emptyDigest.dropLast())) == nil)
        #expect(ReleaseChecksum.normalizedDigest(Self.emptyDigest + "a") == nil)
        #expect(ReleaseChecksum.normalizedDigest(String(repeating: "z", count: 64)) == nil)
        #expect(ReleaseChecksum.normalizedDigest("") == nil)
    }

    @Test("parsing reads only the first line's first field")
    func parseFirstLineOnly() throws {
        let contents = """
        \(Self.emptyDigest)  open-grok-macos-aarch64
        deadbeef  some-other-file
        """
        let parsed = try ReleaseChecksum.parse(
            fileContents: contents,
            fallbackArtifactName: "fallback"
        ).get()
        #expect(parsed.digest == Self.emptyDigest)
        #expect(parsed.artifactName == "open-grok-macos-aarch64")
    }

    @Test("parsing falls back to the caller's name when the line carries none")
    func parseNameFallback() throws {
        let parsed = try ReleaseChecksum.parse(
            fileContents: "\(Self.emptyDigest)\n",
            fallbackArtifactName: "open-grok-macos-aarch64"
        ).get()
        #expect(parsed.artifactName == "open-grok-macos-aarch64")
    }

    @Test("a malformed digest is rejected before any comparison")
    func parseRejectsMalformed() {
        let result = ReleaseChecksum.parse(
            fileContents: "not-a-digest  open-grok-macos-aarch64\n",
            fallbackArtifactName: "open-grok-macos-aarch64"
        )
        guard case .failure(let failure) = result else {
            Issue.record("expected a parse failure")
            return
        }
        #expect(failure == .malformedDigest("not-a-digest"))
    }

    @Test("a CRLF-terminated sidecar parses; Swift models \\r\\n as one Character")
    func parseHandlesCRLF() throws {
        let parsed = try ReleaseChecksum.parse(
            fileContents: "\(Self.emptyDigest)  open-grok-windows-x86_64.exe\r\nignored\r\n",
            fallbackArtifactName: "fallback"
        ).get()
        #expect(parsed.digest == Self.emptyDigest)
        #expect(parsed.artifactName == "open-grok-windows-x86_64.exe")
    }

    @Test("empty sidecar is rejected")
    func parseRejectsEmpty() {
        let result = ReleaseChecksum.parse(fileContents: "", fallbackArtifactName: "x")
        guard case .failure(let failure) = result else {
            Issue.record("expected a parse failure")
            return
        }
        #expect(failure == .empty)
    }

    @Test("verification matches on identical bytes and reports both digests on drift")
    func verification() throws {
        let payload = Array("open grok release artifact".utf8)
        let checksum = try #require(
            ReleaseChecksum.generate(for: payload, artifactName: "open-grok-macos-aarch64")
        )
        #expect(checksum.verify(payload) == .matched)

        var tampered = payload
        tampered[0] ^= 0x01
        guard case .mismatched(let expected, let actual) = checksum.verify(tampered) else {
            Issue.record("tampered bytes must not verify")
            return
        }
        #expect(expected == checksum.digest)
        #expect(actual != checksum.digest)
    }

    @Test("an upper-case sidecar still verifies, as install.sh lower-cases both sides")
    func caseInsensitiveVerification() throws {
        let payload = Array("payload".utf8)
        let generated = try #require(
            ReleaseChecksum.generate(for: payload, artifactName: "open-grok-macos-aarch64")
        )
        let upperSidecar = "\(generated.digest.uppercased())  open-grok-macos-aarch64\n"
        let parsed = try ReleaseChecksum.parse(
            fileContents: upperSidecar,
            fallbackArtifactName: "open-grok-macos-aarch64"
        ).get()
        #expect(parsed.verify(payload) == .matched)
    }
}

@Suite("Release artifact layout and download URLs")
struct ReleaseArtifactLayoutTests {
    @Test("the macOS asset set matches what the reference builder stages")
    func macOSReferenceAssets() throws {
        let version = try #require(ReleaseVersion("0.1.220-open-grok.53"))
        let layout = ReleaseArtifactLayout(platform: .macOSAppleSilicon, version: version)
        #expect(layout.referenceAssetNames == [
            "open-grok-macos-aarch64",
            "open-grok-macos-aarch64.sha256",
            "install.sh",
            "LICENSE",
            "THIRD-PARTY-NOTICES",
        ])
    }

    @Test("the Windows asset set matches what the reference builder stages")
    func windowsReferenceAssets() throws {
        let version = try #require(ReleaseVersion("0.1.220-open-grok.53"))
        let layout = ReleaseArtifactLayout(platform: .windowsX86_64, version: version)
        #expect(layout.referenceAssetNames == [
            "open-grok-windows-x86_64.exe",
            "open-grok-windows-x86_64.exe.sha256",
            "install.ps1",
            "LICENSE",
            "THIRD-PARTY-NOTICES",
        ])
    }

    @Test("NOTICE is port-added, not part of the reference asset set")
    func noticeIsPortAdded() throws {
        let version = try #require(ReleaseVersion("0.1.220-open-grok.53"))
        let layout = ReleaseArtifactLayout(platform: .macOSAppleSilicon, version: version)
        #expect(!layout.referenceAssetNames.contains("NOTICE"))
        #expect(layout.assetNames.contains("NOTICE"))
        #expect(ReleaseArtifactLayout.portAddedLegalAssetNames == ["NOTICE"])
    }

    @Test("dist paths are rooted at dist/")
    func distPaths() throws {
        let version = try #require(ReleaseVersion("1.0.0"))
        let layout = ReleaseArtifactLayout(platform: .macOSAppleSilicon, version: version)
        #expect(layout.distPath(for: "LICENSE") == "dist/LICENSE")
    }

    @Test("base URL resolution follows install.sh's three-way branch")
    func baseURLResolution() throws {
        let version = try #require(ReleaseVersion("0.1.220-open-grok.53"))

        #expect(
            ReleaseArtifactLayout.releaseBaseURL(overrideBaseURL: nil, version: version)
                == "https://github.com/mweinbach/open-grok/releases/download/v0.1.220-open-grok.53"
        )
        #expect(
            ReleaseArtifactLayout.releaseBaseURL(overrideBaseURL: nil, version: nil)
                == "https://github.com/mweinbach/open-grok/releases/latest/download"
        )
        // The override wins over an explicit version, and its trailing slash is
        // stripped exactly like "${OPEN_GROK_RELEASE_BASE_URL%/}".
        #expect(
            ReleaseArtifactLayout.releaseBaseURL(
                overrideBaseURL: "file:///tmp/dist/",
                version: version
            ) == "file:///tmp/dist"
        )
        // An empty override is treated as unset, matching the shell's -n test.
        #expect(
            ReleaseArtifactLayout.releaseBaseURL(overrideBaseURL: "", version: nil)
                == "https://github.com/mweinbach/open-grok/releases/latest/download"
        )
    }

    @Test("asset URLs join base and name with a single slash")
    func assetURLs() {
        #expect(
            ReleaseArtifactLayout.assetURL(
                baseURL: "file:///tmp/dist",
                assetName: "open-grok-macos-aarch64.sha256"
            ) == "file:///tmp/dist/open-grok-macos-aarch64.sha256"
        )
    }
}

@Suite("Install layout")
struct InstallLayoutTests {
    @Test("OPENGROK_HOME wins over the ~/.opengrok fallback")
    func homeResolution() throws {
        let explicit = try InstallLayout.resolve(
            openGrokHome: "/tmp/isolated/home",
            userHome: "/Users/someone"
        ).get()
        #expect(explicit.home == "/tmp/isolated/home")
        #expect(explicit.managedBinDirectory == "/tmp/isolated/home/bin")
        #expect(explicit.downloadDirectory == "/tmp/isolated/home/downloads")
        #expect(explicit.managedBinaryPath == "/tmp/isolated/home/bin/open-grok")

        let fallback = try InstallLayout.resolve(
            openGrokHome: nil,
            userHome: "/Users/someone"
        ).get()
        #expect(fallback.home == "/Users/someone/.opengrok")
        #expect(fallback.binDirectory == "/Users/someone/.opengrok/bin")
    }

    @Test("OPEN_GROK_BIN_DIR overrides only the PATH-facing directory")
    func binDirectoryOverride() throws {
        let layout = try InstallLayout.resolve(
            openGrokHome: "/tmp/isolated/home",
            userHome: "/Users/someone",
            binDirectoryOverride: "/tmp/isolated/bin"
        ).get()
        #expect(layout.binDirectory == "/tmp/isolated/bin")
        // The managed binary still lands under OPENGROK_HOME.
        #expect(layout.managedBinaryPath == "/tmp/isolated/home/bin/open-grok")
    }

    @Test("neither HOME nor OPENGROK_HOME is a hard failure")
    func noHome() {
        let result = InstallLayout.resolve(openGrokHome: nil, userHome: nil)
        guard case .failure(let failure) = result else {
            Issue.record("expected a resolution failure")
            return
        }
        #expect(failure == .noHomeAvailable)
    }

    @Test("bin directories must be absolute")
    func relativeBinDirectory() {
        let result = InstallLayout.resolve(
            openGrokHome: "relative/home",
            userHome: "/Users/someone"
        )
        guard case .failure(let failure) = result else {
            Issue.record("expected a resolution failure")
            return
        }
        #expect(failure == .binDirectoryNotAbsolute("relative/home/bin"))
    }

    @Test("bin directories reject colon, newline, and carriage return")
    func unsupportedCharacters() {
        for bad in ["/tmp/a:b", "/tmp/a\nb", "/tmp/a\rb"] {
            let result = InstallLayout.resolve(
                openGrokHome: "/tmp/home",
                userHome: nil,
                binDirectoryOverride: bad
            )
            guard case .failure(let failure) = result else {
                Issue.record("expected a resolution failure for \(bad.debugDescription)")
                continue
            }
            #expect(failure == .binDirectoryHasUnsupportedCharacters(bad))
        }
    }

    @Test("the legacy ~/.grok home is refused outright")
    func legacyHomeRefused() {
        let result = InstallLayout.resolve(
            openGrokHome: "/Users/someone/.grok",
            userHome: "/Users/someone"
        )
        guard case .failure(let failure) = result else {
            Issue.record("expected a resolution failure")
            return
        }
        #expect(failure == .legacyHomeForbidden("/Users/someone/.grok"))
    }

    @Test("versioned download name splices the version into the artifact name")
    func versionedDownloadName() throws {
        let version = try #require(ReleaseVersion("0.1.220-open-grok.53"))
        #expect(
            InstallLayout.versionedDownloadName(version: version, platform: .macOSAppleSilicon)
                == "open-grok-0.1.220-open-grok.53-macos-aarch64"
        )
        // Windows keeps `.exe` last so the staged file stays executable.
        #expect(
            InstallLayout.versionedDownloadName(version: version, platform: .windowsX86_64)
                == "open-grok-0.1.220-open-grok.53-windows-x86_64.exe"
        )

        let layout = try InstallLayout.resolve(
            openGrokHome: "/tmp/home",
            userHome: nil
        ).get()
        #expect(
            layout.versionedDownloadPath(version: version, platform: .macOSAppleSilicon)
                == "/tmp/home/downloads/open-grok-0.1.220-open-grok.53-macos-aarch64"
        )
    }
}

@Suite("Release channel semantics")
struct ReleaseChannelPolicyTests {
    @Test("the default channel is stable")
    func defaultChannel() {
        #expect(ReleaseChannelPolicy.defaultChannel == .stable)
    }

    @Test("channel labels are bracketed with a leading space; no channel means no label")
    func channelLabels() {
        #expect(ReleaseChannelPolicy.channelLabel(for: .alpha) == " [alpha]")
        #expect(ReleaseChannelPolicy.channelLabel(for: .stable) == " [stable]")
        #expect(ReleaseChannelPolicy.channelLabel(for: nil) == "")
    }

    @Test("display version concatenates version and label")
    func displayVersion() {
        #expect(
            ReleaseChannelPolicy.displayVersion("0.2.5", channel: .alpha) == "0.2.5 [alpha]"
        )
        #expect(
            ReleaseChannelPolicy.displayVersion("0.2.5 (abc1234)", channel: .stable)
                == "0.2.5 (abc1234) [stable]"
        )
        #expect(ReleaseChannelPolicy.displayVersion("0.2.5", channel: nil) == "0.2.5")
    }

    @Test("alpha consults both pointers; every other channel consults only its own")
    func pointersToConsult() {
        #expect(ReleaseChannelPolicy.pointersToConsult(for: .alpha) == [.alpha, .stable])
        #expect(ReleaseChannelPolicy.pointersToConsult(for: .stable) == [.stable])
        #expect(ReleaseChannelPolicy.pointersToConsult(for: .enterprise) == [.enterprise])
    }

    @Test("alpha resolves to the semver-greater of the alpha and stable pointers")
    func alphaTakesMax() {
        // The case the reference's comment calls out: a newer stable shipped
        // without the alpha dist-tag moving. Alpha users must not get stuck.
        #expect(
            ReleaseChannelPolicy.resolveTarget(
                channel: .alpha,
                pointers: [.alpha: "0.1.220-alpha.4", .stable: "0.1.221"]
            ) == "0.1.221"
        )
        // And the ordinary case where alpha genuinely leads.
        #expect(
            ReleaseChannelPolicy.resolveTarget(
                channel: .alpha,
                pointers: [.alpha: "0.1.221-alpha.1", .stable: "0.1.220"]
            ) == "0.1.221-alpha.1"
        )
    }

    @Test("stable ignores the alpha pointer entirely")
    func stableIgnoresAlpha() {
        #expect(
            ReleaseChannelPolicy.resolveTarget(
                channel: .stable,
                pointers: [.alpha: "0.1.221-alpha.1", .stable: "0.1.220"]
            ) == "0.1.220"
        )
    }

    @Test("a release outranks its own prerelease")
    func semverPrecedence() {
        #expect(ReleaseChannelPolicy.semverMax(["0.1.148-alpha.3", "0.1.148"]) == "0.1.148")
        #expect(ReleaseChannelPolicy.semverMax([]) == nil)
    }

    @Test("an unparseable pointer is skipped rather than failing the resolve")
    func unparseablePointerIsSkipped() {
        #expect(
            ReleaseChannelPolicy.resolveTarget(
                channel: .alpha,
                pointers: [.alpha: "not-a-version", .stable: "0.1.220"]
            ) == "0.1.220"
        )
    }
}

@Suite("Completions packaging")
struct CompletionsPackageTests {
    @Test("filenames follow each shell's own convention")
    func fileNames() {
        #expect(ShellCompletion.bash.fileName == "open-grok.bash")
        #expect(ShellCompletion.zsh.fileName == "_open-grok")
        #expect(ShellCompletion.fish.fileName == "open-grok.fish")
        #expect(ShellCompletion.powershell.fileName == "open-grok.ps1")
    }

    @Test("packaged paths are namespaced per shell")
    func packagedPaths() {
        #expect(ShellCompletion.zsh.packagedPath == "completions/zsh/_open-grok")
    }

    @Test("PORT_PLAN requires all four shells")
    func requiredShells() {
        #expect(Set(CompletionsPackage.requiredShells) == Set(ShellCompletion.allCases))
        #expect(CompletionsPackage.requiredShells.count == 4)
    }

    @Test("a bundle missing a shell is incomplete")
    func missingShell() {
        let package = CompletionsPackage(scripts: [.bash: "# bash", .zsh: "# zsh"])
        #expect(!package.isComplete)
        #expect(Set(package.missingShells) == [.fish, .powershell])
    }

    @Test("a shell whose generator emitted only whitespace is a packaging failure")
    func emptyShell() {
        let package = CompletionsPackage(scripts: [
            .bash: "# bash",
            .zsh: "# zsh",
            .fish: "# fish",
            .powershell: "   \n  ",
        ])
        #expect(!package.isComplete)
        #expect(package.emptyShells == [.powershell])
        #expect(package.missingShells.isEmpty)
    }

    @Test("a full bundle is complete and lists its paths deterministically")
    func completeBundle() {
        let package = CompletionsPackage(scripts: [
            .bash: "# bash",
            .zsh: "# zsh",
            .fish: "# fish",
            .powershell: "# pwsh",
        ])
        #expect(package.isComplete)
        #expect(package.packagedPaths == [
            "completions/bash/open-grok.bash",
            "completions/fish/open-grok.fish",
            "completions/powershell/open-grok.ps1",
            "completions/zsh/_open-grok",
        ])
    }

    @Test("completions are not claimed as reference release assets")
    func completionsAreNotUpstream() throws {
        // The Rust reference ships no completions at 80dff0a9; a parity check
        // against upstream must not expect them in the published asset set.
        let version = try #require(ReleaseVersion("0.1.220-open-grok.53"))
        let layout = ReleaseArtifactLayout(platform: .macOSAppleSilicon, version: version)
        #expect(!layout.referenceAssetNames.contains { $0.contains("completion") })
        #expect(!layout.assetNames.contains { $0.contains("completion") })
    }
}

@Suite("Reference pin")
struct ReferencePinTests {
    @Test("the target names the current pin and its release")
    func pin() {
        #expect(
            OpenGrokDistributionSupport.referenceRevision
                == "80dff0a9dcb24121b976b9f920fbe442af40ea88"
        )
        #expect(
            ReleaseVersion(OpenGrokDistributionSupport.referencePinnedRelease)?.value
                == "0.1.220-open-grok.53"
        )
    }
}
