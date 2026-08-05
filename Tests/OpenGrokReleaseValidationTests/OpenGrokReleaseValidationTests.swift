// OpenGrokReleaseValidationTests.swift
//
// The release gate must fail closed. Each suite below pins one of the
// reference's own failure modes rather than only its happy path.

import Foundation
import Testing

@testable import OpenGrokReleaseValidation

private let emptyDigest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
private let otherDigest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

@Suite("Validation report")
struct ReleaseValidationReportTests {
    @Test("severity ordering is info < warning < failure")
    func severityOrdering() {
        #expect(ReleaseValidationSeverity.info < .warning)
        #expect(ReleaseValidationSeverity.warning < .failure)
        #expect([ReleaseValidationSeverity.info, .failure, .warning].max() == .failure)
    }

    @Test("only failures block; warnings do not")
    func passedSemantics() {
        var report = ReleaseValidationReport()
        #expect(report.passed)

        report.record(ReleaseValidationFinding(
            id: "x.warn", severity: .warning, subject: "s", message: "m"
        ))
        #expect(report.passed)
        #expect(report.highestSeverity == .warning)

        report.record(ReleaseValidationFinding(
            id: "x.fail", severity: .failure, subject: "s", message: "m"
        ))
        #expect(!report.passed)
        #expect(report.highestSeverity == .failure)
    }

    @Test("findings can be filtered by severity floor")
    func severityFilter() {
        var report = ReleaseValidationReport()
        report.record(ReleaseValidationFinding(id: "a", severity: .info, subject: "s", message: "m"))
        report.record(ReleaseValidationFinding(id: "b", severity: .warning, subject: "s", message: "m"))
        report.record(ReleaseValidationFinding(id: "c", severity: .failure, subject: "s", message: "m"))
        #expect(report.findings(atLeast: .warning).map(\.id) == ["b", "c"])
        #expect(report.findings(atLeast: .failure).map(\.id) == ["c"])
    }

    @Test("merging preserves order")
    func merge() {
        var first = ReleaseValidationReport()
        first.record(ReleaseValidationFinding(id: "a", severity: .info, subject: "s", message: "m"))
        var second = ReleaseValidationReport()
        second.record(ReleaseValidationFinding(id: "b", severity: .info, subject: "s", message: "m"))
        first.merge(second)
        #expect(first.findings.map(\.id) == ["a", "b"])
    }

    @Test("rendering is stable and readable")
    func rendering() {
        var report = ReleaseValidationReport()
        #expect(report.render() == "release validation: no findings")
        report.record(ReleaseValidationFinding(
            id: "checksum.mismatch",
            severity: .failure,
            subject: "open-grok-macos-aarch64",
            message: "boom"
        ))
        #expect(report.render() == "[failure] checksum.mismatch (open-grok-macos-aarch64): boom")
    }
}

@Suite("Checksum validation")
struct ChecksumValidationTests {
    @Test("expected digest comes from the first line's first field")
    func expectedDigestExtraction() {
        #expect(
            ChecksumValidation.expectedDigest(
                fromSidecar: "\(emptyDigest)  open-grok-macos-aarch64\n\(otherDigest)  other\n"
            ) == emptyDigest
        )
        #expect(ChecksumValidation.expectedDigest(fromSidecar: "") == nil)
        #expect(ChecksumValidation.expectedDigest(fromSidecar: "short  name\n") == nil)
    }

    @Test("a CRLF-terminated sidecar is read correctly")
    func crlfSidecar() {
        #expect(
            ChecksumValidation.expectedDigest(
                fromSidecar: "\(emptyDigest)  open-grok-windows-x86_64.exe\r\nignored\r\n"
            ) == emptyDigest
        )
    }

    @Test("digests are compared case-insensitively")
    func caseInsensitive() {
        let report = ChecksumValidation.validate(ChecksumClaim(
            artifactName: "open-grok-macos-aarch64",
            sidecarContents: "\(emptyDigest.uppercased())  open-grok-macos-aarch64\n",
            actualDigest: emptyDigest
        ))
        #expect(report.passed)
        #expect(report.findings.map(\.id) == ["checksum.verified"])
    }

    @Test("a mismatch is a blocking failure that names both digests")
    func mismatchBlocks() {
        let report = ChecksumValidation.validate(ChecksumClaim(
            artifactName: "open-grok-macos-aarch64",
            sidecarContents: "\(emptyDigest)  open-grok-macos-aarch64\n",
            actualDigest: otherDigest
        ))
        #expect(!report.passed)
        let finding = report.findings.first
        #expect(finding?.id == "checksum.mismatch")
        #expect(finding?.message.contains(emptyDigest) == true)
        #expect(finding?.message.contains(otherDigest) == true)
    }

    @Test("a malformed sidecar fails before any comparison")
    func malformedSidecarBlocks() {
        let report = ChecksumValidation.validate(ChecksumClaim(
            artifactName: "open-grok-macos-aarch64",
            sidecarContents: "not-a-digest  open-grok-macos-aarch64\n",
            actualDigest: emptyDigest
        ))
        #expect(!report.passed)
        #expect(report.findings.map(\.id) == ["checksum.malformed"])
    }

    @Test("a malformed computed digest is also a failure")
    func malformedActualBlocks() {
        let report = ChecksumValidation.validate(ChecksumClaim(
            artifactName: "open-grok-macos-aarch64",
            sidecarContents: "\(emptyDigest)  open-grok-macos-aarch64\n",
            actualDigest: "zzz"
        ))
        #expect(!report.passed)
        #expect(report.findings.map(\.id) == ["checksum.actualMalformed"])
    }

    @Test("a release with no artifacts fails rather than passing vacuously")
    func emptyReleaseBlocks() {
        let report = ChecksumValidation.validate(all: [])
        #expect(!report.passed)
        #expect(report.findings.map(\.id) == ["checksum.noArtifacts"])
    }

    @Test("one bad artifact fails the whole release")
    func oneBadArtifactBlocks() {
        let report = ChecksumValidation.validate(all: [
            ChecksumClaim(
                artifactName: "open-grok-macos-aarch64",
                sidecarContents: "\(emptyDigest)  open-grok-macos-aarch64\n",
                actualDigest: emptyDigest
            ),
            ChecksumClaim(
                artifactName: "open-grok-windows-x86_64.exe",
                sidecarContents: "\(emptyDigest)  open-grok-windows-x86_64.exe\n",
                actualDigest: otherDigest
            ),
        ])
        #expect(!report.passed)
        #expect(report.findings(atLeast: .failure).map(\.subject) == ["open-grok-windows-x86_64.exe"])
    }
}

@Suite("Notice validation")
struct NoticeValidationTests {
    private static func complete() -> [LegalAsset] {
        [
            LegalAsset(name: "LICENSE", contents: "Apache License, Version 2.0"),
            LegalAsset(name: "THIRD-PARTY-NOTICES", contents: "THIRD PARTY NOTICES"),
            LegalAsset(name: "NOTICE", contents: "Open Grok\nCopyright 2023-2026 SpaceXAI"),
        ]
    }

    @Test("the required set separates reference assets from the port-added NOTICE")
    func requiredSets() {
        #expect(NoticeValidation.referenceRequiredNames == ["LICENSE", "THIRD-PARTY-NOTICES"])
        #expect(NoticeValidation.portAddedRequiredNames == ["NOTICE"])
        #expect(NoticeValidation.requiredNames.count == 3)
    }

    @Test("a complete legal set passes")
    func completePasses() {
        let report = NoticeValidation.validate(assets: Self.complete())
        #expect(report.passed)
        #expect(report.findings.allSatisfy { $0.id == "notices.present" })
        #expect(report.findings.count == 3)
    }

    @Test("a missing file blocks the release")
    func missingBlocks() {
        let assets = Self.complete().filter { $0.name != "THIRD-PARTY-NOTICES" }
        let report = NoticeValidation.validate(assets: assets)
        #expect(!report.passed)
        let failure = report.findings(atLeast: .failure).first
        #expect(failure?.id == "notices.missing")
        #expect(failure?.subject == "THIRD-PARTY-NOTICES")
    }

    @Test("a file present with nil contents counts as missing")
    func nilContentsIsMissing() {
        var assets = Self.complete().filter { $0.name != "LICENSE" }
        assets.append(LegalAsset(name: "LICENSE", contents: nil))
        let report = NoticeValidation.validate(assets: assets)
        #expect(!report.passed)
        #expect(report.findings(atLeast: .failure).first?.subject == "LICENSE")
    }

    @Test("a whitespace-only file blocks: presence alone is not attribution")
    func emptyBlocks() {
        var assets = Self.complete().filter { $0.name != "NOTICE" }
        assets.append(LegalAsset(name: "NOTICE", contents: "  \n\t\n"))
        let report = NoticeValidation.validate(assets: assets)
        #expect(!report.passed)
        let failure = report.findings(atLeast: .failure).first
        #expect(failure?.id == "notices.empty")
        #expect(failure?.subject == "NOTICE")
    }

    @Test("the port-added NOTICE is labelled as such")
    func portAddedLabelled() {
        let report = NoticeValidation.validate(assets: Self.complete())
        let notice = report.findings.first { $0.subject == "NOTICE" }
        #expect(notice?.message.contains("port-added") == true)
    }
}

@Suite("Executable smoke validation")
struct SmokeValidationTests {
    @Test("version tokens are recognized with the reference's pattern")
    func versionShape() {
        #expect(SmokeValidation.isWellFormedVersion("0.1.220-open-grok.53"))
        #expect(SmokeValidation.isWellFormedVersion("1.0.0"))
        #expect(SmokeValidation.isWellFormedVersion("0.1.150-alpha-1"))
        #expect(!SmokeValidation.isWellFormedVersion("1.2"))
        #expect(!SmokeValidation.isWellFormedVersion("1.2.3+build"))
        #expect(!SmokeValidation.isWellFormedVersion("(abc1234)"))
        #expect(!SmokeValidation.isWellFormedVersion(""))
    }

    @Test("the reported version is the first version-shaped token in the output")
    func reportedVersionExtraction() {
        #expect(
            SmokeValidation.reportedVersion(in: "open-grok 0.1.220-open-grok.53 (abc1234)")
                == "0.1.220-open-grok.53"
        )
        #expect(SmokeValidation.reportedVersion(in: "open-grok\n0.2.5\n") == "0.2.5")
        #expect(SmokeValidation.reportedVersion(in: "no version here") == nil)
    }

    @Test("output carrying both the version and the short commit passes")
    func versionAndCommitPass() {
        let report = SmokeValidation.validateVersionOutput(
            "open-grok 0.1.220-open-grok.53 (abc1234)",
            expectedVersion: "0.1.220-open-grok.53",
            expectedShortCommit: "abc1234"
        )
        #expect(report.passed)
        #expect(report.findings.map(\.id) == ["smoke.versionMatches", "smoke.commitPresent"])
    }

    @Test("a version mismatch blocks, exactly as the builder's check does")
    func versionMismatchBlocks() {
        let report = SmokeValidation.validateVersionOutput(
            "open-grok 0.1.220-open-grok.21 (abc1234)",
            expectedVersion: "0.1.220-open-grok.53",
            expectedShortCommit: "abc1234"
        )
        #expect(!report.passed)
        #expect(report.findings(atLeast: .failure).map(\.id) == ["smoke.versionMismatch"])
    }

    @Test("a missing build commit blocks")
    func missingCommitBlocks() {
        let report = SmokeValidation.validateVersionOutput(
            "open-grok 0.1.220-open-grok.53",
            expectedVersion: "0.1.220-open-grok.53",
            expectedShortCommit: "abc1234"
        )
        #expect(!report.passed)
        #expect(report.findings(atLeast: .failure).map(\.id) == ["smoke.commitMissing"])
    }

    @Test("output with no version token at all blocks")
    func unparseableOutputBlocks() {
        let report = SmokeValidation.validateVersionOutput(
            "Segmentation fault",
            expectedVersion: "0.1.220-open-grok.53",
            expectedShortCommit: nil
        )
        #expect(!report.passed)
        #expect(report.findings.map(\.id) == ["smoke.versionMalformed"])
    }

    @Test("the commit assertion is skipped when no commit is supplied")
    func commitOptional() {
        let report = SmokeValidation.validateVersionOutput(
            "open-grok 0.1.220-open-grok.53",
            expectedVersion: "0.1.220-open-grok.53",
            expectedShortCommit: nil
        )
        #expect(report.passed)
        #expect(report.findings.map(\.id) == ["smoke.versionMatches"])
    }
}

@Suite("Isolated-home validation")
struct IsolatedHomeValidationTests {
    @Test("the release workflow isolates both home variables")
    func isolationVariables() {
        #expect(SmokeValidation.isolationEnvironmentVariables == ["OPENGROK_HOME", "OPEN_GROK_BIN_DIR"])
    }

    @Test("paths inside the isolated root pass")
    func containedPaths() {
        let report = SmokeValidation.validateIsolatedHome(
            isolatedRoot: "/tmp/smoke.XXXX",
            touchedPaths: [
                "/tmp/smoke.XXXX/home/.opengrok",
                "/tmp/smoke.XXXX/home/downloads/open-grok-0.1.220-open-grok.53-macos-aarch64",
                "/tmp/smoke.XXXX/bin/open-grok",
            ]
        )
        #expect(report.passed)
        #expect(report.findings.allSatisfy { $0.id == "isolation.contained" })
    }

    @Test("a write outside the isolated root blocks")
    func escapedPathBlocks() {
        let report = SmokeValidation.validateIsolatedHome(
            isolatedRoot: "/tmp/smoke.XXXX",
            touchedPaths: ["/tmp/smoke.XXXX/bin/open-grok", "/usr/local/bin/open-grok"]
        )
        #expect(!report.passed)
        let failure = report.findings(atLeast: .failure).first
        #expect(failure?.id == "isolation.escaped")
        #expect(failure?.subject == "/usr/local/bin/open-grok")
    }

    @Test("a sibling directory sharing the root's prefix is not 'inside' it")
    func siblingPrefixIsNotContained() {
        let report = SmokeValidation.validateIsolatedHome(
            isolatedRoot: "/tmp/smoke",
            touchedPaths: ["/tmp/smoke-other/bin/open-grok"]
        )
        #expect(!report.passed)
        #expect(report.findings(atLeast: .failure).first?.id == "isolation.escaped")
    }

    @Test("touching the legacy ~/.grok tree blocks even inside the isolated root")
    func legacyHomeBlocks() {
        let report = SmokeValidation.validateIsolatedHome(
            isolatedRoot: "/tmp/smoke.XXXX",
            touchedPaths: ["/tmp/smoke.XXXX/.grok/config.toml"]
        )
        #expect(!report.passed)
        #expect(report.findings(atLeast: .failure).first?.id == "isolation.legacyHome")
    }

    @Test(".opengrok is not mistaken for the forbidden .grok")
    func opengrokIsNotLegacy() {
        #expect(!SmokeValidation.isLegacyHomePath("/Users/someone/.opengrok/bin/open-grok"))
        #expect(SmokeValidation.isLegacyHomePath("/Users/someone/.grok/bin/open-grok"))
        // A path component that merely contains ".grok" is not the legacy tree.
        #expect(!SmokeValidation.isLegacyHomePath("/Users/someone/my.grok.backup/x"))
    }

    @Test("observing no paths at all fails: the smoke proved nothing")
    func noPathsBlocks() {
        let report = SmokeValidation.validateIsolatedHome(
            isolatedRoot: "/tmp/smoke.XXXX",
            touchedPaths: []
        )
        #expect(!report.passed)
        #expect(report.findings.map(\.id) == ["isolation.noPathsObserved"])
    }

    @Test("a relative isolated root is rejected")
    func relativeRootBlocks() {
        let report = SmokeValidation.validateIsolatedHome(
            isolatedRoot: "smoke",
            touchedPaths: ["smoke/bin/open-grok"]
        )
        #expect(!report.passed)
        #expect(report.findings.map(\.id) == ["isolation.rootNotAbsolute"])
    }
}

@Suite("Reference pin")
struct ReleaseValidationPinTests {
    @Test("the target names the current pin")
    func pin() {
        #expect(
            OpenGrokReleaseValidation.referenceRevision
                == "80dff0a9dcb24121b976b9f920fbe442af40ea88"
        )
    }
}
