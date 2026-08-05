// OpenGrokCompatibilityTests.swift
//
// W11-S2's pin discipline: the checked-in protocol fixtures must all name the
// reference revision the repository is actually pinned to, and each must carry
// an explicit verdict explaining how that was established.
//
// PORT_STATUS.md's release gate wording is "unexplained drift blocks release".
// The way that turns into a test is: no fixture may quietly keep an older ref,
// and no fixture may claim a verdict without evidence.
//
// Digest freshness is deliberately NOT re-checked here —
// `Tests/OpenGrokBuildSupportTests` already validates every manifest digest
// through `FixtureValidator`, and this target has no dependency edge to the
// package's SHA-256 implementation. This suite checks the things that test
// does not: the pin, the verdicts, and manifest/provenance agreement.

import Foundation
import Testing

import OpenGrokACP

/// The revision `PORT_STATUS.md` pins the Rust reference to.
private let pinnedReferenceRevision = "80dff0a9dcb24121b976b9f920fbe442af40ea88"

/// The revision the fixtures were originally captured at, before the
/// 2026-08-04 re-pin. No fixture may still name it.
private let supersededReferenceRevision = "9739c4a2ad23cfea14312a481169757f3da494f4"

private let acceptedVerdicts: Set<String> = ["unchanged (verified)", "recaptured"]

// MARK: - Fixture corpus access

private enum FixtureCorpus {
    /// Walk up from this source file to the package root.
    static var packageRoot: URL {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while url.path != "/" {
            if FileManager.default.fileExists(
                atPath: url.appendingPathComponent("ProtocolFixtures").path
            ) {
                return url
            }
            url = url.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    }

    static var fixturesDirectory: URL {
        packageRoot.appendingPathComponent("ProtocolFixtures", isDirectory: true)
    }

    static func url(_ name: String) -> URL {
        fixturesDirectory.appendingPathComponent(name)
    }

    static func json(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: url(name))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return object
    }

    /// Every checked-in JSON fixture except the manifest, which is generated.
    static var jsonFixtureNames: [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            atPath: fixturesDirectory.path
        )) ?? []
        return contents
            .filter { $0.hasSuffix(".json") && $0 != "manifest.json" && $0 != "PROVENANCE.json" }
            .sorted()
    }
}

// MARK: - Pin discipline

@Suite("Protocol fixture pin")
struct ProtocolFixturePinTests {
    @Test("the fixture corpus is non-empty and discoverable")
    func corpusIsDiscoverable() {
        #expect(!FixtureCorpus.jsonFixtureNames.isEmpty)
    }

    @Test("the generated manifest names the pinned reference revision")
    func manifestNamesPin() throws {
        let manifest = try FixtureCorpus.json("manifest.json")
        #expect(manifest["referenceRevision"] as? String == pinnedReferenceRevision)
    }

    @Test("the provenance index names the pinned reference revision")
    func provenanceNamesPin() throws {
        let provenance = try FixtureCorpus.json("PROVENANCE.json")
        #expect(provenance["referenceRevision"] as? String == pinnedReferenceRevision)
        #expect(
            provenance["previousReferenceRevision"] as? String == supersededReferenceRevision
        )
    }

    @Test("every JSON fixture names the pinned reference revision at top level")
    func fixturesNamePin() throws {
        for name in FixtureCorpus.jsonFixtureNames {
            let fixture = try FixtureCorpus.json(name)
            #expect(
                fixture["referenceRevision"] as? String == pinnedReferenceRevision,
                "\(name) does not name the pinned reference revision"
            )
        }
    }

    @Test("no fixture still names the superseded pre-re-pin revision")
    func noSupersededRevisionRemains() throws {
        for name in FixtureCorpus.jsonFixtureNames + ["PROVENANCE.json", "manifest.json"] {
            let data = try Data(contentsOf: FixtureCorpus.url(name))
            let text = String(decoding: data, as: UTF8.self)
            if name == "PROVENANCE.json" || FixtureCorpus.jsonFixtureNames.contains(name) {
                // The old ref may appear only as `previousReferenceRevision` or
                // inside recorded evidence, never as the fixture's own pin.
                let fixture = try FixtureCorpus.json(name)
                #expect(fixture["referenceRevision"] as? String != supersededReferenceRevision)
            } else {
                #expect(
                    !text.contains(supersededReferenceRevision),
                    "\(name) still names the superseded revision"
                )
            }
        }
    }
}

// MARK: - Verdicts

@Suite("Protocol fixture recapture verdicts")
struct ProtocolFixtureVerdictTests {
    @Test("every JSON fixture carries an accepted pin verdict")
    func fixturesCarryVerdicts() throws {
        for name in FixtureCorpus.jsonFixtureNames {
            let fixture = try FixtureCorpus.json(name)
            guard let provenance = fixture["provenance"] as? [String: Any] else {
                Issue.record("\(name) has no provenance block")
                continue
            }
            guard let verdict = provenance["pinVerdict"] as? String else {
                Issue.record("\(name) has no provenance.pinVerdict")
                continue
            }
            #expect(acceptedVerdicts.contains(verdict), "\(name) has an unrecognized verdict: \(verdict)")
        }
    }

    @Test("every verdict is backed by recorded evidence")
    func verdictsHaveEvidence() throws {
        for name in FixtureCorpus.jsonFixtureNames {
            let fixture = try FixtureCorpus.json(name)
            let provenance = fixture["provenance"] as? [String: Any] ?? [:]
            let evidence = provenance["evidence"] as? [String] ?? []
            #expect(!evidence.isEmpty, "\(name) states a verdict with no evidence")
            #expect(
                evidence.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
                "\(name) has a blank evidence line"
            )
        }
    }

    @Test("every fixture records the revision it was previously captured at")
    func verdictsNamePreviousRevision() throws {
        for name in FixtureCorpus.jsonFixtureNames {
            let fixture = try FixtureCorpus.json(name)
            let provenance = fixture["provenance"] as? [String: Any] ?? [:]
            #expect(
                provenance["previousReferenceRevision"] as? String == supersededReferenceRevision,
                "\(name) does not record its previous capture revision"
            )
        }
    }

    @Test("the provenance index gives every corpus file a verdict")
    func provenanceCoversEveryFile() throws {
        let provenance = try FixtureCorpus.json("PROVENANCE.json")
        let listedFiles = Set(provenance["files"] as? [String] ?? [])
        let entries = provenance["entries"] as? [[String: Any]] ?? []
        let entryFiles = Set(entries.compactMap { $0["file"] as? String })

        #expect(!entries.isEmpty)
        #expect(entryFiles == listedFiles, "PROVENANCE entries and files list disagree")

        for entry in entries {
            let file = entry["file"] as? String ?? "<unnamed>"
            guard let verdict = entry["verdict"] as? String else {
                Issue.record("PROVENANCE entry for \(file) has no verdict")
                continue
            }
            #expect(acceptedVerdicts.contains(verdict), "\(file): unrecognized verdict \(verdict)")
            if file != "PROVENANCE.json" {
                let evidence = entry["evidence"] as? String ?? ""
                #expect(!evidence.isEmpty, "PROVENANCE entry for \(file) has no evidence")
            }
        }
    }

    @Test("the provenance index and the on-disk corpus agree")
    func provenanceMatchesDisk() throws {
        let provenance = try FixtureCorpus.json("PROVENANCE.json")
        let listedFiles = Set(provenance["files"] as? [String] ?? [])
        let onDisk = Set(
            (try FileManager.default.contentsOfDirectory(atPath: FixtureCorpus.fixturesDirectory.path))
                .filter { $0 != "manifest.json" }
        )
        #expect(listedFiles == onDisk, "PROVENANCE files list drifted from ProtocolFixtures/")
    }
}

// MARK: - Manifest agreement

@Suite("Protocol fixture manifest agreement")
struct ProtocolFixtureManifestTests {
    private struct Entry {
        let path: String
        let sizeBytes: Int
    }

    private func manifestEntries() throws -> [Entry] {
        let manifest = try FixtureCorpus.json("manifest.json")
        let files = manifest["files"] as? [[String: Any]] ?? []
        return files.compactMap { raw in
            guard let path = raw["path"] as? String,
                  let size = raw["sizeBytes"] as? Int else { return nil }
            return Entry(path: path, sizeBytes: size)
        }
    }

    @Test("the manifest lists exactly the corpus, and nothing else")
    func manifestCoversCorpus() throws {
        let entries = try manifestEntries()
        #expect(!entries.isEmpty)

        let manifestNames = Set(entries.map { URL(fileURLWithPath: $0.path).lastPathComponent })
        let onDisk = Set(
            (try FileManager.default.contentsOfDirectory(atPath: FixtureCorpus.fixturesDirectory.path))
                .filter { $0 != "manifest.json" }
        )
        #expect(manifestNames == onDisk)
    }

    @Test("every manifest entry is rooted under ProtocolFixtures/ and exists")
    func manifestEntriesResolve() throws {
        for entry in try manifestEntries() {
            #expect(entry.path.hasPrefix("ProtocolFixtures/"), "\(entry.path) is not rooted correctly")
            let url = FixtureCorpus.packageRoot.appendingPathComponent(entry.path)
            #expect(
                FileManager.default.fileExists(atPath: url.path),
                "\(entry.path) is listed but missing"
            )
        }
    }

    @Test("recorded sizes match the files on disk")
    func manifestSizesAreFresh() throws {
        for entry in try manifestEntries() {
            let url = FixtureCorpus.packageRoot.appendingPathComponent(entry.path)
            let data = try Data(contentsOf: url)
            #expect(
                data.count == entry.sizeBytes,
                "\(entry.path): manifest says \(entry.sizeBytes) bytes, file is \(data.count)"
            )
        }
    }
}

// MARK: - Recaptured content

@Suite("Recaptured fixture content")
struct RecapturedFixtureContentTests {
    @Test("the ACP method surface survived the re-pin unchanged")
    func acpMethodsStillMatchThePort() throws {
        let fixture = try FixtureCorpus.json("acp-methods.json")
        let methods = fixture["methods"] as? [String] ?? []
        #expect(!methods.isEmpty)
        for method in methods {
            #expect(
                OpenGrokACPMethodCatalog.contains(method),
                "\(method) is in the fixture but not in the Swift catalog"
            )
        }
    }

    @Test("the version fixture records the release pinned at the new ref")
    func versionFixtureNamesPinnedRelease() throws {
        let fixture = try FixtureCorpus.json("cli-version-and-home.json")
        #expect(fixture["referencePinnedRelease"] as? String == "0.1.220-open-grok.53")
        // Home policy did not move with the pin.
        #expect(fixture["homeEnv"] as? String == "OPENGROK_HOME")
        #expect(fixture["homeFallback"] as? String == "~/.opengrok")
        #expect(fixture["legacyHomeForbidden"] as? String == "~/.grok")
    }

    @Test("the crash fixture records the SIGABRT capture added at the new ref")
    func crashFixtureRecordsSigabrt() throws {
        let fixture = try FixtureCorpus.json("crash-gcrx-format.json")
        let signals = fixture["capturedSignals"] as? [String: Any] ?? [:]
        let unix = signals["unix"] as? [String] ?? []
        #expect(unix.contains("SIGABRT"))
        #expect(unix.contains("SIGSEGV"))
        #expect(unix.contains("SIGBUS"))
        // The blob layout itself did not change.
        #expect(fixture["headerSize"] as? Int == 64)
        #expect(fixture["maxFrames"] as? Int == 64)
        #expect(fixture["versionStringLength"] as? Int == 32)
    }

    @Test("the GCRX binary golden decodes to the recaptured sample")
    func crashSampleDecodes() throws {
        let fixture = try FixtureCorpus.json("crash-gcrx-format.json")
        let sample = fixture["sample"] as? [String: Any] ?? [:]
        let data = try Data(contentsOf: FixtureCorpus.url("crash-gcrx-sample.bin"))
        let bytes = [UInt8](data)

        #expect(bytes.count == 64)
        #expect(Array(bytes[0..<4]) == Array("GCRX".utf8))
        #expect(bytes[4] == 1)
        #expect(Int(bytes[5]) == sample["signal"] as? Int)

        func readLE(_ offset: Int, _ width: Int) -> UInt64 {
            var value: UInt64 = 0
            for index in stride(from: width - 1, through: 0, by: -1) {
                value = (value << 8) | UInt64(bytes[offset + index])
            }
            return value
        }

        #expect(Int(readLE(6, 4)) == sample["siCode"] as? Int)
        #expect(readLE(10, 8) == 0x1000)
        #expect(Int(readLE(18, 4)) == sample["pid"] as? Int)
        #expect(Int(readLE(22, 8)) == sample["timestamp"] as? Int)
        #expect(Int(readLE(30, 2)) == sample["nFrames"] as? Int)

        let versionBytes = Array(bytes[32..<64]).prefix { $0 != 0 }
        let appVersion = String(decoding: versionBytes, as: UTF8.self)
        #expect(appVersion == sample["appVersion"] as? String)
        #expect(appVersion == "0.1.220-open-grok.53")
    }

    @Test("the config/permission fixture carries per-key Rust provenance")
    func configFixtureIsGrounded() throws {
        let fixture = try FixtureCorpus.json("config-workspace-codemode-keys.json")
        let provenance = fixture["provenance"] as? [String: Any] ?? [:]
        let keyProvenance = provenance["keyProvenance"] as? [String: String] ?? [:]

        // Every substantive key set must name the Rust source it came from.
        for key in ["configSourceOrder", "permissionRuleActions", "codeModeRuntimeDefaults"] {
            #expect(fixture[key] != nil, "\(key) is missing from the fixture")
            #expect(keyProvenance[key] != nil, "\(key) has no recorded Rust provenance")
        }

        // The one value that genuinely moved at this pin.
        let defaults = fixture["codeModeRuntimeDefaults"] as? [String: Int] ?? [:]
        #expect(defaults["DEFAULT_EXEC_YIELD_TIME_MS"] == 30000)

        // deny > ask > allow, unchanged.
        #expect(fixture["workspacePermissionOrder"] as? [String] == ["deny", "ask", "allow"])
        #expect(fixture["permissionRuleActionDefault"] as? String == "deny")
    }

    @Test("known Swift-port drift is recorded rather than hidden")
    func portDriftIsRecorded() throws {
        // Both fixtures whose upstream value moved ahead of the Swift port must
        // say so explicitly, and the provenance index must list the same drift.
        for name in ["cli-version-and-home.json", "config-workspace-codemode-keys.json"] {
            let fixture = try FixtureCorpus.json(name)
            let drift = fixture["portDrift"] as? [String: Any] ?? [:]
            #expect(!drift.isEmpty, "\(name) recaptured a moved value without recording port drift")
        }

        let provenance = try FixtureCorpus.json("PROVENANCE.json")
        let openDrift = provenance["openPortDrift"] as? [String] ?? []
        #expect(openDrift.count == 2)
        #expect(openDrift.contains { $0.contains("CompiledVersion.generated.swift") })
        #expect(openDrift.contains { $0.contains("DEFAULT_EXEC_YIELD_TIME_MS") })
    }
}
