import Foundation
import Testing
@testable import OpenGrokUpdate

// These cover the parts of self-update where a mistake is expensive: the
// platform gate that decides which asset is fetched, and the symlink target the
// managed binary ends up pointing at.

@Suite("release platform gate")
struct ReleasePlatformTests {
    @Test("only the two published targets are installable")
    func supportedTargets() {
        #expect(ReleasePlatform(operatingSystem: "macos", architecture: "aarch64")
            .isSupportedForRelease)
        #expect(ReleasePlatform(operatingSystem: "windows", architecture: "x86_64")
            .isSupportedForRelease)
        // Anything else has no asset published, so it must fail with a clear
        // message rather than 404 on a synthesized name.
        #expect(ReleasePlatform(operatingSystem: "linux", architecture: "x86_64")
            .isSupportedForRelease == false)
        #expect(ReleasePlatform(operatingSystem: "macos", architecture: "x86_64")
            .isSupportedForRelease == false)
    }

    @Test("asset names match the published release assets")
    func assetNames() {
        #expect(ReleasePlatform(operatingSystem: "macos", architecture: "aarch64").assetName
            == "open-grok-macos-aarch64")
        #expect(ReleasePlatform(operatingSystem: "windows", architecture: "x86_64").assetName
            == "open-grok-windows-x86_64.exe")
    }

    @Test("the versioned platform infix keeps the download name parseable")
    func versionedPlatform() {
        let platform = ReleasePlatform(operatingSystem: "macos", architecture: "aarch64")
        #expect(platform.versionedPlatform == "macos-aarch64")
        #expect(platform.binaryExtension == "")
    }
}

@Suite("download destinations")
struct UpdatePathsTests {
    @Test("downloads land beside the managed binary under OPENGROK_HOME")
    func downloadPath() {
        let paths = UpdatePaths(environment: ["OPENGROK_HOME": "/tmp/og-home"])
        let url = paths.downloadURL(
            version: "0.1.220",
            platform: ReleasePlatform(operatingSystem: "macos", architecture: "aarch64")
        )
        #expect(url.lastPathComponent == "open-grok-0.1.220-macos-aarch64")
        #expect(url.deletingLastPathComponent().lastPathComponent == "downloads")
    }
}

@Suite("managed link target")
struct RelativeTargetTests {
    @Test("sibling directories produce a relative target that survives a move")
    func siblingRelative() {
        let binary = URL(fileURLWithPath: "/home/.opengrok/downloads/open-grok-1.0.0-macos-aarch64")
        let link = URL(fileURLWithPath: "/home/.opengrok/bin/open-grok")
        #expect(ReleaseInstallService.relativeTarget(from: binary, to: link)
            == "../downloads/open-grok-1.0.0-macos-aarch64")
    }

    @Test("same directory produces a bare filename")
    func sameDirectory() {
        let binary = URL(fileURLWithPath: "/home/.opengrok/bin/open-grok-1.0.0")
        let link = URL(fileURLWithPath: "/home/.opengrok/bin/open-grok")
        #expect(ReleaseInstallService.relativeTarget(from: binary, to: link) == "open-grok-1.0.0")
    }

    @Test("unrelated trees fall back to an absolute path")
    func unrelatedAbsolute() {
        let binary = URL(fileURLWithPath: "/opt/builds/open-grok")
        let link = URL(fileURLWithPath: "/home/.opengrok/bin/open-grok")
        #expect(ReleaseInstallService.relativeTarget(from: binary, to: link) == "/opt/builds/open-grok")
    }
}

@Suite("published checksum parsing")
struct PublishedChecksumTests {
    private let digest = String(repeating: "a", count: 64)

    @Test("accepts a bare digest and a digest with the asset name")
    func acceptsBothForms() throws {
        let bare = try UpdateChecksum.parsePublishedChecksum(digest, expectedAsset: "asset")
        #expect(bare.digest == digest)

        let named = try UpdateChecksum.parsePublishedChecksum(
            "\(digest)  *asset", expectedAsset: "asset"
        )
        #expect(named.digest == digest)
    }

    @Test("refuses a checksum that names a different asset")
    func refusesWrongAsset() {
        // Accepting this would let a checksum published for one artifact
        // validate a different one.
        #expect(throws: OpenGrokUpdateError.self) {
            try UpdateChecksum.parsePublishedChecksum(
                "\(digest)  other-asset", expectedAsset: "asset"
            )
        }
    }

    @Test("refuses malformed and empty digests")
    func refusesMalformed() {
        #expect(throws: OpenGrokUpdateError.self) {
            try UpdateChecksum.parsePublishedChecksum("", expectedAsset: "asset")
        }
        #expect(throws: OpenGrokUpdateError.self) {
            try UpdateChecksum.parsePublishedChecksum("deadbeef", expectedAsset: "asset")
        }
        #expect(throws: OpenGrokUpdateError.self) {
            try UpdateChecksum.parsePublishedChecksum(
                String(repeating: "z", count: 64), expectedAsset: "asset"
            )
        }
    }
}
