import Foundation
import OpenGrokUpdate
import Testing

struct OpenGrokUpdateTests {

    @Test("version normalization strips release tag prefix and whitespace")
    func normalizesReleaseTags() throws {
        #expect(try UpdateVersion.normalize("  v1.2.3-alpha.4  ") == "1.2.3-alpha.4")
        #expect(try UpdateVersion.maximum("1.2.3-alpha.4", "v1.2.3") == "1.2.3")
        #expect(throws: OpenGrokUpdateError.self) {
            _ = try UpdateVersion.normalize("not-a-version")
        }
    }

    @Test("alpha resolution selects the semver maximum of alpha and stable")
    func alphaResolutionIsDeterministic() throws {
        let pointers = try ReleasePointers(stable: "0.2.7", alpha: "0.2.8-alpha.1")
        #expect(try pointers.resolvedVersion(for: .stable) == "0.2.7")
        #expect(try pointers.resolvedVersion(for: .alpha) == "0.2.8-alpha.1")
        #expect(try ReleaseSelector.resolvedVersion(
            channel: .alpha,
            stable: "0.2.8",
            alpha: "0.2.7-alpha.9"
        ) == "0.2.8")
    }

    @Test("release selection ignores drafts and selects the highest eligible stable")
    func releaseSelectionFiltersUnsafeCandidates() throws {
        let releases = try [
            ReleaseCandidate(tagName: "v0.2.9-alpha.1", version: "0.2.9-alpha.1", isPrerelease: true),
            ReleaseCandidate(tagName: "v0.2.8", version: "0.2.8"),
            ReleaseCandidate(tagName: "v0.2.7", version: "0.2.7", isDraft: true),
            ReleaseCandidate(tagName: "v0.2.6", version: "0.2.6"),
            ReleaseCandidate(tagName: "v0.2.5-alpha.1", version: "0.2.5-alpha.1")
        ]
        let selected = try ReleaseSelector.latest(channel: .stable, releases: releases)
        #expect(selected.version == "0.2.8")
        let alpha = try ReleaseSelector.latest(channel: .alpha, releases: releases)
        #expect(alpha.version == "0.2.9-alpha.1")
        #expect(throws: OpenGrokUpdateError.self) {
            _ = try ReleaseSelector.asset(named: "missing", in: selected)
        }
        #expect(throws: OpenGrokUpdateError.self) {
            _ = try ReleaseSelector.latest(channel: .unsupported("canary"), releases: releases)
        }
    }

    @Test("authoritative installers allow rollback while npm rejects stale registry downgrades")
    func installerRollbackMatrix() {
        let internalDecision = UpdatePlanner.decide(
            current: "0.2.8",
            target: "0.2.7",
            channel: .stable,
            installer: .internalInstaller
        )
        #expect(internalDecision.eligibility == .rollback)
        #expect(internalDecision.shouldUpdate)

        let npmDecision = UpdatePlanner.decide(
            current: "0.2.8",
            target: "0.2.7",
            channel: .stable,
            installer: .npm
        )
        #expect(npmDecision.eligibility == .rollbackRejected)
        #expect(!npmDecision.shouldUpdate)

        let prereleaseRecovery = UpdatePlanner.decide(
            current: "0.2.9-alpha.1",
            target: "0.2.8",
            channel: .stable,
            installer: .npm
        )
        #expect(prereleaseRecovery.eligibility == .prereleaseRecovery)
        #expect(prereleaseRecovery.shouldUpdate)
        #expect(!prereleaseRecovery.isDowngrade)

        let upgrade = UpdatePlanner.decide(
            current: "0.2.7",
            target: "0.2.8",
            channel: .stable,
            installer: .npm
        )
        #expect(upgrade.eligibility == .upgrade)
    }

    @Test("stable channels reject ordinary prerelease candidates")
    func stablePrereleaseSafety() {
        let rejected = UpdatePlanner.decide(
            current: "0.2.7",
            target: "0.2.8-alpha.1",
            channel: .stable,
            installer: .openGrok
        )
        #expect(rejected.eligibility == .stablePrereleaseRejected)
        #expect(!rejected.shouldUpdate)

        let acceptedOpenGrokPrerelease = UpdatePlanner.decide(
            current: "0.2.7",
            target: "0.2.8-open-grok.1",
            channel: .stable,
            installer: .openGrok
        )
        #expect(acceptedOpenGrokPrerelease.eligibility == .upgrade)
    }

    @Test("version policy blocks targets outside hard and updater bounds")
    func policyBoundsAreAppliedBeforeDirection() throws {
        let policy = try VersionPolicy.fromStrings(
            minimum: "0.2.6",
            maximum: "0.2.9",
            requiredMinimum: "0.2.7",
            requiredMaximum: "0.2.10"
        )
        let hardFloor = UpdatePlanner.decide(
            current: "0.2.8",
            target: "0.2.6",
            channel: .stable,
            installer: .internalInstaller,
            policy: policy
        )
        #expect(hardFloor.targetVersion == "0.2.7")
        #expect(hardFloor.eligibility == .rollback)

        let softCeiling = UpdatePlanner.decide(
            current: "0.2.8",
            target: "0.3.0",
            channel: .stable,
            installer: .internalInstaller,
            policy: policy
        )
        #expect(softCeiling.targetVersion == "0.2.9")
        #expect(softCeiling.eligibility == .upgrade)

        let softFloor = try VersionPolicy.fromStrings(minimum: "0.2.7")
        let skipped = UpdatePlanner.decide(
            current: "0.2.8",
            target: "0.2.6",
            channel: .stable,
            installer: .internalInstaller,
            policy: softFloor
        )
        #expect(skipped.eligibility == .belowMinimum)
        #expect(!skipped.shouldUpdate)

        let contradictory = try VersionPolicy.fromStrings(
            requiredMinimum: "0.3.0",
            requiredMaximum: "0.2.0"
        )
        let failOpen = UpdatePlanner.decide(
            current: "0.2.7",
            target: "0.2.8",
            channel: .stable,
            installer: .npm,
            policy: contradictory
        )
        #expect(failOpen.eligibility == .upgrade)
    }

    @Test("status uses the Rust-compatible camelCase JSON contract")
    func statusWireShape() throws {
        let decision = UpdatePlanner.decide(
            current: "0.2.7",
            target: "0.2.8",
            channel: .stable,
            installer: .openGrok
        )
        let data = try JSONEncoder().encode(UpdateStatus(decision: decision, autoUpdate: true))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["currentVersion"] as? String == "0.2.7")
        #expect(object["latestVersion"] as? String == "0.2.8")
        #expect(object["updateAvailable"] as? Bool == true)
        #expect(object["installer"] as? String == "open-grok")
        #expect(object["channel"] as? String == "stable")
        #expect(object["autoUpdate"] as? Bool == true)

        let unavailable = UpdateStatus(
            currentVersion: "0.2.7",
            latestVersion: nil,
            updateAvailable: false,
            installer: nil,
            channel: "stable",
            autoUpdate: nil,
            error: "network unavailable"
        )
        let unavailableData = try JSONEncoder().encode(unavailable)
        let unavailableObject = try #require(
            JSONSerialization.jsonObject(with: unavailableData) as? [String: Any]
        )
        #expect(unavailableObject["latestVersion"] is NSNull)
        #expect(unavailableObject["installer"] is NSNull)
        #expect(unavailableObject["autoUpdate"] is NSNull)
    }

    @Test("cache preserves version.json fields and applies strict freshness boundaries")
    func versionCacheWireAndTTL() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = ["OPENGROK_HOME": root.path]
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = VersionCacheStore(environment: environment)

        try await store.record(
            version: "v0.2.8-alpha.1",
            stableVersion: "0.2.7",
            checkedAt: now
        )
        let loaded = try await store.load()
        #expect(loaded?.version == "0.2.8-alpha.1")
        #expect(loaded?.stableVersion == "0.2.7")
        #expect(loaded?.isFresh(at: now.addingTimeInterval(29 * 60), ttl: 30 * 60) == true)
        #expect(loaded?.isFresh(at: now.addingTimeInterval(30 * 60), ttl: 30 * 60) == false)
        #expect(loaded?.isFresh(at: now.addingTimeInterval(-1), ttl: 30 * 60) == false)

        let data = try Data(contentsOf: await store.cacheURL)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["version"] as? String == "0.2.8-alpha.1")
        #expect(object["stable_version"] as? String == "0.2.7")
        #expect(object["checked_at"] as? String != nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("version.json.tmp").path))
    }

    @Test("malformed cache is never treated as fresh")
    func malformedCacheFailsClosed() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = ["OPENGROK_HOME": root.path]
        let store = VersionCacheStore(environment: environment)
        let cacheURL = await store.cacheURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"version":"0.2.8","checked_at":"tomorrow"}"#.utf8).write(to: cacheURL)

        #expect(await store.isFresh(at: Date(), ttl: 30 * 60) == false)
        #expect(try await store.load()?.isFresh(at: Date(), ttl: 30 * 60) == false)

        try Data(#"{"version":"not-semver","checked_at":"2026-01-01T00:00:00Z"}"#.utf8)
            .write(to: cacheURL)
        #expect(await store.isFresh(at: Date(), ttl: 30 * 60) == false)
        await #expect(throws: OpenGrokUpdateError.self) {
            _ = try await store.load()
        }
    }

    @Test("checksum parsing accepts standard and binary checksum formats")
    func checksumParser() throws {
        let digest = String(repeating: "A", count: 64)
        let standard = try UpdateChecksum.parsePublishedChecksum(
            "\(digest)  open-grok-macos-aarch64\n",
            expectedAsset: "open-grok-macos-aarch64"
        )
        #expect(standard.digest == String(repeating: "a", count: 64))

        let binary = try UpdateChecksum.parsePublishedChecksum(
            "\n\(digest) *open-grok-macos-aarch64\n",
            expectedAsset: "open-grok-macos-aarch64"
        )
        #expect(binary.assetName == "open-grok-macos-aarch64")
        #expect(throws: OpenGrokUpdateError.self) {
            _ = try UpdateChecksum.parsePublishedChecksum(
                "\(digest)  another-asset\n",
                expectedAsset: "open-grok-macos-aarch64"
            )
        }
        #expect(throws: OpenGrokUpdateError.self) {
            _ = try UpdateChecksum.parsePublishedChecksum("bad", expectedAsset: "asset")
        }
    }

    @Test("signature requirements create a plan but never activate an artifact")
    func verificationPlanIsNonMutating() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let asset = ReleaseAsset(
            name: "open-grok-macos-aarch64",
            downloadURL: URL(string: "https://example.invalid/open-grok")!,
            checksumURL: URL(string: "https://example.invalid/open-grok.sha256")!,
            signatureURL: URL(string: "https://example.invalid/open-grok.sig")!
        )
        let verification = try ArtifactVerificationPlan(
            asset: asset,
            publishedChecksum: "\(String(repeating: "b", count: 64))  \(asset.name)",
            signature: .required(keyID: "open-grok-release")
        )
        let decision = UpdatePlanner.decide(
            current: "0.2.7",
            target: "0.2.8",
            channel: .stable,
            installer: .openGrok
        )
        let plan = try UpdateInstallPlan(decision: decision, artifact: verification, environment: ["OPENGROK_HOME": root.path])
        #expect(plan.requiresExternalActivation)
        #expect(plan.destinationURL?.path == root.appendingPathComponent("bin/open-grok").path)
        #expect(!FileManager.default.fileExists(atPath: root.path))

        let missingSignatureAsset = ReleaseAsset(
            name: asset.name,
            downloadURL: asset.downloadURL
        )
        #expect(throws: OpenGrokUpdateError.self) {
            _ = try ArtifactVerificationPlan(
                asset: missingSignatureAsset,
                publishedChecksum: "\(String(repeating: "b", count: 64))  \(asset.name)",
                signature: .required(keyID: "open-grok-release")
            )
        }
        #expect(throws: OpenGrokUpdateError.self) {
            _ = try ArtifactVerificationPlan(
                asset: asset,
                publishedChecksum: "\(String(repeating: "b", count: 64))  \(asset.name)",
                signature: .required(keyID: " ")
            )
        }
        let unsafeAsset = ReleaseAsset(
            name: asset.name,
            downloadURL: URL(string: "file:///tmp/open-grok")!,
            checksumURL: asset.checksumURL,
            signatureURL: asset.signatureURL
        )
        #expect(throws: OpenGrokUpdateError.self) {
            _ = try ArtifactVerificationPlan(
                asset: unsafeAsset,
                publishedChecksum: "\(String(repeating: "b", count: 64))  \(asset.name)"
            )
        }
    }

    private func temporaryDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("open-grok-update-\(UUID().uuidString)", isDirectory: true)
    }
}
