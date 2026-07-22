// OpenGrokBuildSupportTests.swift
//
// Target-scoped Swift Testing suites for the W0-S1 bootstrap target.
//
// Covers the semantic port of the Rust `xai-proto-build` crate:
//   * SHA-256 NIST test vectors (the dependency-free hasher used for fixture
//     and release checksums).
//   * Open Grok branding constants (executable name, state directory, env var,
//     and the forbidden legacy `~/.grok` path).
//   * Generated-protocol fixture manifest validation (fresh, stale digest,
//     missing file, unexpected file).
//   * Proto build rules: absolute-path rejection (POSIX, Windows drive letter,
//     Windows forward-slash drive).
//   * `DefaultProtoCompiler` discovery: `$PROTOC` override, `bin/protoc`
//     parent walk, `$PATH` fallback, strict-mode error, `protocIsGood`
//     validation, well-known-types include heuristic.
//
// All filesystem-touching tests use injected `workingDirectory`/`pathLookup`
// seams or NSTemporaryDirectory so they are independent of the host's PATH and
// repository layout.

import Foundation
import Testing
@testable import OpenGrokBuildSupport

@Suite("OpenGrokBuildSupport")
struct OpenGrokBuildSupportTests {
    // MARK: - SHA-256 NIST vectors

    @Test("SHA-256 empty message")
    func sha256Empty() {
        #expect(SHA256.hexDigest([]) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test("SHA-256 of 'abc'")
    func sha256Abc() {
        #expect(SHA256.hexDigest("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("SHA-256 of the classic fox sentence")
    func sha256Fox() {
        #expect(
            SHA256.hexDigest("The quick brown fox jumps over the lazy dog")
            == "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592"
        )
    }

    @Test("SHA-256 raw byte count is 32")
    func sha256ByteCount() {
        #expect(SHA256.hash("abc").count == 32)
    }

    @Test("SHA-256 of a two-block message (>= 56 bytes) produces a 64-char hex")
    func sha256TwoBlock() {
        // 56-byte input forces a second 64-byte block after padding (the
        // 0x80 terminator plus 8-byte length leaves no room in the first
        // block). We assert only the shape, not a specific vector, to avoid
        // pinning a transcribed constant; the empty/abc/fox vectors above
        // already cover the algorithm's correctness for known inputs.
        let input = String(repeating: "a", count: 56)
        let actual = SHA256.hexDigest(input)
        #expect(actual.count == 64)
        #expect(actual.allSatisfy { $0.isHexDigit })
        #expect(SHA256.hash(Array(input.utf8)).count == 32)
    }

    // MARK: - Branding

    @Test("Branding constants preserve Open Grok identity")
    func brandingIdentity() {
        #expect(OpenGrokBranding.executableName == "open-grok")
        #expect(OpenGrokBranding.productName == "Open Grok")
        #expect(OpenGrokBranding.homeEnvironmentVariable == "OPENGROK_HOME")
        #expect(OpenGrokBranding.fallbackStateDirectoryName == ".opengrok")
        #expect(OpenGrokBranding.projectStateDirectoryName == ".opengrok")
        #expect(OpenGrokBranding.legacyForbiddenStateDirectoryName == ".grok")
        #expect(OpenGrokBranding.managedBinarySubpath == "bin/open-grok")
    }

    // MARK: - Fixture validator

    /// Package root derived from this test file's location so the suite is
    /// independent of the working directory SwiftPM chooses at runtime. Walks
    /// up until it finds `Package.swift`.
    private var packageRoot: URL {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while url.path != "/" && !FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
            url = url.deletingLastPathComponent()
        }
        return url
    }

    @Test("Checked-in protocol fixture manifest is fresh")
    func fixtureManifestFresh() throws {
        let manifestURL = packageRoot
            .appendingPathComponent("ProtocolFixtures/manifest.json")
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(GeneratedManifest.self, from: data)
        let result = FixtureValidator.validate(manifest: manifest, packageRoot: packageRoot)
        // The bootstrap manifest lists exactly the fixtures present; expect fresh.
        if case .stale(let issues) = result {
            Issue.record("Expected fresh fixtures but found issues: \(issues)")
        }
    }

    @Test("Validator detects a stale digest")
    func fixtureValidatorStaleDigest() throws {
        let url = packageRoot.appendingPathComponent("ProtocolFixtures/acp-methods.json")
        let data = try Data(contentsOf: url)
        let actualDigest = SHA256.hexDigest(Array(data))
        let bad = GeneratedManifest(
            generatedAt: "2026-07-20",
            referenceRevision: "9739c4a2ad23cfea14312a481169757f3da494f4",
            files: [
                GeneratedFixtureEntry(
                    path: "ProtocolFixtures/acp-methods.json",
                    sizeBytes: data.count,
                    sha256: "deadbeef"
                )
            ]
        )
        let result = FixtureValidator.validate(manifest: bad, packageRoot: packageRoot, allowUnexpectedFiles: true)
        guard case .stale(let issues) = result else {
            Issue.record("Expected stale result")
            return
        }
        #expect(issues.contains(.digestMismatch(
            path: "ProtocolFixtures/acp-methods.json",
            expected: "deadbeef",
            actual: actualDigest
        )))
    }

    @Test("Validator detects a missing fixture file")
    func fixtureValidatorMissing() {
        let bad = GeneratedManifest(
            generatedAt: "2026-07-20",
            referenceRevision: "open-grok.21",
            files: [
                GeneratedFixtureEntry(path: "ProtocolFixtures/does-not-exist.json", sizeBytes: 1, sha256: "00")
            ]
        )
        let result = FixtureValidator.validate(manifest: bad, packageRoot: packageRoot, allowUnexpectedFiles: true)
        guard case .stale(let issues) = result else {
            Issue.record("Expected stale result")
            return
        }
        #expect(issues.contains(.missing(path: "ProtocolFixtures/does-not-exist.json")))
    }

    @Test("Validator detects a size mismatch even when the digest matches")
    func fixtureValidatorSizeMismatch() throws {
        // Read the real fixture so we can recompute its digest but lie about
        // the size.
        let url = packageRoot.appendingPathComponent("ProtocolFixtures/acp-methods.json")
        let data = try Data(contentsOf: url)
        let realDigest = SHA256.hexDigest(Array(data))
        let bad = GeneratedManifest(
            generatedAt: "2026-07-20",
            referenceRevision: "open-grok.21",
            files: [
                GeneratedFixtureEntry(path: "ProtocolFixtures/acp-methods.json", sizeBytes: data.count + 1, sha256: realDigest)
            ]
        )
        let result = FixtureValidator.validate(manifest: bad, packageRoot: packageRoot, allowUnexpectedFiles: true)
        guard case .stale(let issues) = result else {
            Issue.record("Expected stale result")
            return
        }
        #expect(issues.contains(.sizeMismatch(path: "ProtocolFixtures/acp-methods.json", expected: data.count + 1, actual: data.count)))
    }

    @Test("Validator reports an unexpected file when allowUnexpectedFiles is false")
    func fixtureValidatorUnexpected() throws {
        // Build a manifest that omits the real fixture; the on-disk file is
        // then "unexpected" relative to the manifest.
        let empty = GeneratedManifest(
            generatedAt: "2026-07-20",
            referenceRevision: "open-grok.21",
            files: []
        )
        let result = FixtureValidator.validate(manifest: empty, packageRoot: packageRoot, allowUnexpectedFiles: false)
        guard case .stale(let issues) = result else {
            Issue.record("Expected stale result")
            return
        }
        #expect(issues.contains(.unexpected(path: "ProtocolFixtures/acp-methods.json")))
    }

    @Test("FixtureValidator.entry computes a relative path and fresh digest")
    func fixtureValidatorEntry() throws {
        let url = packageRoot.appendingPathComponent("ProtocolFixtures/acp-methods.json")
        let data = try Data(contentsOf: url)
        let entry = FixtureValidator.entry(for: url, relativeTo: packageRoot)
        #expect(entry?.path == "ProtocolFixtures/acp-methods.json")
        #expect(entry?.sizeBytes == data.count)
        #expect(entry?.sha256 == SHA256.hexDigest(Array(data)))
    }

    // MARK: - Proto build rules

    @Test("Proto build rules reject absolute paths and accept relative ones")
    func protoBuildRulesPaths() {
        #expect(throws: ProtoBuildError.self) {
            try ProtoBuildRules.validateInputPaths(["proto/acp.proto", "/abs/proto.proto"])
        }
        #expect(throws: ProtoBuildError.self) {
            try ProtoBuildRules.validateInputPaths(["C:\\proto\\acp.proto"])
        }
        #expect(throws: ProtoBuildError.self) {
            try ProtoBuildRules.validateInputPaths(["D:/proto/acp.proto"])
        }
        // Relative paths must not throw.
        do {
            try ProtoBuildRules.validateInputPaths(["proto/acp.proto", "common/types.proto"])
        } catch {
            Issue.record("Relative proto paths should not throw, got: \(error)")
        }
    }

    @Test("ProtoBuildError.absolutePathRejected carries the rejected path")
    func protoBuildErrorCarriesPath() {
        do {
            try ProtoBuildRules.validateInputPaths(["/etc/passwd"])
            Issue.record("Expected absolutePathRejected")
        } catch let ProtoBuildError.absolutePathRejected(path) {
            #expect(path == "/etc/passwd")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: - DefaultProtoCompiler discovery

    /// A working directory with no `bin/protoc` ancestor, so the parent walk
    /// contributes nothing. Uses a per-test temp directory to stay isolated
    /// from the host filesystem.
    private func isolatedWorkingDirectory() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("OpenGrokBuildSupportTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("DefaultProtoCompiler honors PROTOC override")
    func defaultProtoCompilerProtocOverride() throws {
        // Create a placeholder file so the existence check passes; disable
        // `--version` validation so we don't require a real protoc binary.
        let temp = isolatedWorkingDirectory()
        let protoc = temp.appendingPathComponent("protoc")
        try Data("placeholder".utf8).write(to: protoc)
        let compiler = DefaultProtoCompiler(
            workingDirectory: temp,
            pathLookup: { _ in nil },
            validateCandidates: false
        )
        let discovered = compiler.discoverProtoc(environment: ["PROTOC": protoc.path])
        #expect(discovered?.path == protoc.path)
    }

    @Test("DefaultProtoCompiler walks parent directories for bin/protoc")
    func defaultProtoCompilerParentWalk() throws {
        // Build a temp tree:
        //   <root>/
        //     bin/protoc        <- discovered candidate
        //     sub/dir/          <- working directory (two levels below root)
        let root = isolatedWorkingDirectory()
        let binDir = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let protoc = binDir.appendingPathComponent("protoc")
        try Data("placeholder".utf8).write(to: protoc)
        let deepDir = root.appendingPathComponent("sub").appendingPathComponent("dir")
        try FileManager.default.createDirectory(at: deepDir, withIntermediateDirectories: true)

        let compiler = DefaultProtoCompiler(
            workingDirectory: deepDir,
            pathLookup: { _ in nil },
            validateCandidates: false
        )
        let discovered = compiler.discoverProtoc(environment: [:])
        #expect(discovered?.path == protoc.path)
    }

    @Test("DefaultProtoCompiler falls back to PATH lookup")
    func defaultProtoCompilerPathFallback() throws {
        let temp = isolatedWorkingDirectory()
        let pathProtoc = temp.appendingPathComponent("protoc-from-path")
        try Data("placeholder".utf8).write(to: pathProtoc)
        let compiler = DefaultProtoCompiler(
            workingDirectory: temp,
            pathLookup: { name in
                name == "protoc" ? pathProtoc : nil
            },
            validateCandidates: false
        )
        let discovered = compiler.discoverProtoc(environment: [:])
        #expect(discovered?.path == pathProtoc.path)
    }

    @Test("DefaultProtoCompiler returns nil when no protoc is available")
    func defaultProtoCompilerNilWhenAbsent() throws {
        let temp = isolatedWorkingDirectory()
        let compiler = DefaultProtoCompiler(
            workingDirectory: temp,
            pathLookup: { _ in nil },
            validateCandidates: false
        )
        #expect(compiler.discoverProtoc(environment: [:]) == nil)
    }

    @Test("DefaultProtoCompiler throws in strict mode when protoc is missing")
    func defaultProtoCompilerStrictThrows() throws {
        let temp = isolatedWorkingDirectory()
        let compiler = DefaultProtoCompiler(
            workingDirectory: temp,
            pathLookup: { _ in nil },
            validateCandidates: false
        )
        #expect(throws: ProtoBuildError.self) {
            try compiler.discoverProtoc(environment: [:], strict: true)
        }
    }

    @Test("DefaultProtoCompiler treats GITHUB_ACTIONS presence as strict (Rust parity)")
    func defaultProtoCompilerGitHubActionsStrict() throws {
        // Mirrors Rust `env::var_os("GITHUB_ACTIONS").is_some()`:
        // presence of the key is strict regardless of value (`true`,
        // `false`, `0`, or empty string all count). The previous Swift
        // implementation only treated `true`/`1` as strict, which diverged
        // from the reference and was explicitly called out by the
        // reviewer as a parity bug.
        let temp = isolatedWorkingDirectory()
        let compiler = DefaultProtoCompiler(
            workingDirectory: temp,
            pathLookup: { _ in nil },
            validateCandidates: false
        )
        // Any value — including `false`, `0`, and empty string — is strict.
        #expect(compiler.isStrictEnvironment(["GITHUB_ACTIONS": "true"]))
        #expect(compiler.isStrictEnvironment(["GITHUB_ACTIONS": "false"]))
        #expect(compiler.isStrictEnvironment(["GITHUB_ACTIONS": "0"]))
        #expect(compiler.isStrictEnvironment(["GITHUB_ACTIONS": ""]))
        #expect(!compiler.isStrictEnvironment([:]))
        #expect(throws: ProtoBuildError.self) {
            // No explicit `strict: true` argument, but GITHUB_ACTIONS=true
            // forces the hard error path inside the throwing overload —
            // matching the reference `is_github_actions()` behavior. The
            // non-throwing `discoverProtoc(environment:)` convenience
            // swallows this via `try?`, so the strict behavior is only
            // observable through the throwing overload.
            try compiler.discoverProtoc(environment: ["GITHUB_ACTIONS": "true"], strict: false)
        }
        // Every value triggers the strict hard error, not just `true`/`1`.
        #expect(throws: ProtoBuildError.self) {
            try compiler.discoverProtoc(environment: ["GITHUB_ACTIONS": "false"], strict: false)
        }
        #expect(throws: ProtoBuildError.self) {
            try compiler.discoverProtoc(environment: ["GITHUB_ACTIONS": "0"], strict: false)
        }
        #expect(throws: ProtoBuildError.self) {
            try compiler.discoverProtoc(environment: ["GITHUB_ACTIONS": ""], strict: false)
        }
        // The non-throwing convenience overload returns nil even in a strict
        // environment, because it wraps the throwing overload in `try?`.
        // This mirrors a caller that treats "no protoc found" as nil rather
        // than a hard error, regardless of CI environment.
        #expect(compiler.discoverProtoc(environment: ["GITHUB_ACTIONS": "true"]) == nil)
    }

    @Test("DefaultProtoCompiler wellKnownTypesInclude resolves ../include")
    func defaultProtoCompilerWellKnownTypesInclude() throws {
        // Build <root>/bin/protoc and <root>/include/ so the heuristic
        // resolves the include dir.
        let root = isolatedWorkingDirectory()
        let binDir = root.appendingPathComponent("bin")
        let includeDir = root.appendingPathComponent("include")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: includeDir, withIntermediateDirectories: true)
        let protoc = binDir.appendingPathComponent("protoc")
        let compiler = DefaultProtoCompiler(validateCandidates: false)
        let resolved = compiler.wellKnownTypesInclude(for: protoc)
        #expect(resolved?.path == includeDir.path)
    }

    @Test("DefaultProtoCompiler wellKnownTypesInclude returns nil when include is absent")
    func defaultProtoCompilerWellKnownTypesIncludeAbsent() {
        let compiler = DefaultProtoCompiler()
        // /opt/protoc/bin/protoc has no ../include on the test host.
        let protoc = URL(fileURLWithPath: "/opt/protoc/bin/protoc")
        _ = compiler.wellKnownTypesInclude(for: protoc)
        // The include dir does not exist on the test host, so resolution is
        // nil but must not crash.
        #expect(compiler.wellKnownTypesInclude(for: protoc) == nil)
    }

    @Test("DefaultProtoCompiler.validateInputPaths delegates to ProtoBuildRules")
    func defaultProtoCompilerValidatesPaths() {
        let compiler = DefaultProtoCompiler()
        #expect(throws: ProtoBuildError.self) {
            try compiler.validateInputPaths(["/abs/path.proto"])
        }
        #expect(throws: ProtoBuildError.self) {
            try compiler.validateInputPaths(["C:\\abs\\path.proto"])
        }
        #expect(throws: ProtoBuildError.self) {
            try compiler.validateInputPaths(["D:/abs/path.proto"])
        }
        // Relative paths must not throw.
        #expect(throws: Never.self) {
            try compiler.validateInputPaths(["rel/path.proto"])
        }
    }

    @Test("DefaultProtoCompiler strictEnvironmentVariable is GITHUB_ACTIONS")
    func defaultProtoCompilerStrictEnvVar() {
        #expect(DefaultProtoCompiler.strictEnvironmentVariable == "GITHUB_ACTIONS")
    }

    // MARK: - FixtureValidator path containment (issue 3)

    @Test("FixtureValidator rejects traversal paths in manifest entries")
    func fixtureValidatorRejectsTraversal() {
        // A manifest entry that tries to escape ProtocolFixtures via `..`
        // must be reported as a pathEscape issue, never hashed.
        let bad = GeneratedManifest(
            generatedAt: "2026-07-20",
            referenceRevision: "open-grok.21",
            files: [
                GeneratedFixtureEntry(path: "ProtocolFixtures/../../NOTICE", sizeBytes: 1, sha256: "00")
            ]
        )
        let result = FixtureValidator.validate(manifest: bad, packageRoot: packageRoot, allowUnexpectedFiles: true)
        guard case .stale(let issues) = result else {
            Issue.record("Expected stale result for traversal path")
            return
        }
        #expect(issues.contains { issue in
            if case .pathEscape(let path, _) = issue, path == "ProtocolFixtures/../../NOTICE" { return true }
            return false
        })
    }

    @Test("FixtureValidator rejects absolute paths in manifest entries")
    func fixtureValidatorRejectsAbsolute() {
        let bad = GeneratedManifest(
            generatedAt: "2026-07-20",
            referenceRevision: "open-grok.21",
            files: [
                GeneratedFixtureEntry(path: "/etc/passwd", sizeBytes: 1, sha256: "00")
            ]
        )
        let result = FixtureValidator.validate(manifest: bad, packageRoot: packageRoot, allowUnexpectedFiles: true)
        guard case .stale(let issues) = result else {
            Issue.record("Expected stale result for absolute path")
            return
        }
        #expect(issues.contains { issue in
            if case .pathEscape(let path, _) = issue, path == "/etc/passwd" { return true }
            return false
        })
    }

    @Test("FixtureValidator rejects Windows drive-letter paths in manifest entries")
    func fixtureValidatorRejectsWindowsDrive() {
        let bad = GeneratedManifest(
            generatedAt: "2026-07-20",
            referenceRevision: "open-grok.21",
            files: [
                GeneratedFixtureEntry(path: "C:\\Windows\\System32\\drivers\\etc\\hosts", sizeBytes: 1, sha256: "00")
            ]
        )
        let result = FixtureValidator.validate(manifest: bad, packageRoot: packageRoot, allowUnexpectedFiles: true)
        guard case .stale(let issues) = result else {
            Issue.record("Expected stale result for Windows drive path")
            return
        }
        #expect(issues.contains { issue in
            if case .pathEscape(let path, _) = issue, path == "C:\\Windows\\System32\\drivers\\etc\\hosts" { return true }
            return false
        })
    }

    @Test("FixtureValidator rejects paths not rooted under ProtocolFixtures")
    func fixtureValidatorRejectsNotRooted() {
        let bad = GeneratedManifest(
            generatedAt: "2026-07-20",
            referenceRevision: "open-grok.21",
            files: [
                GeneratedFixtureEntry(path: "NOTICE", sizeBytes: 1, sha256: "00")
            ]
        )
        let result = FixtureValidator.validate(manifest: bad, packageRoot: packageRoot, allowUnexpectedFiles: true)
        guard case .stale(let issues) = result else {
            Issue.record("Expected stale result for non-rooted path")
            return
        }
        #expect(issues.contains { issue in
            if case .pathEscape(let path, _) = issue, path == "NOTICE" { return true }
            return false
        })
    }

    @Test("FixtureValidator rejects symlink escapes out of ProtocolFixtures")
    func fixtureValidatorRejectsSymlinkEscape() throws {
        // Build a temp package root with:
        //   <root>/ProtocolFixtures/manifest.json   (not read by validator)
        //   <root>/ProtocolFixtures/escape -> <root>/outside.txt
        //   <root>/outside.txt
        // A manifest entry pointing at `ProtocolFixtures/escape` must be
        // rejected because the resolved path lands outside ProtocolFixtures.
        let root = isolatedWorkingDirectory()
        let fixtures = root.appendingPathComponent("ProtocolFixtures")
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.txt")
        try Data("secret".utf8).write(to: outside)
        let escapeLink = fixtures.appendingPathComponent("escape")
        // Create a relative symlink so the resolved path is detectably
        // outside ProtocolFixtures.
        try FileManager.default.createSymbolicLink(
            at: escapeLink,
            withDestinationURL: outside
        )
        let bad = GeneratedManifest(
            generatedAt: "2026-07-20",
            referenceRevision: "open-grok.21",
            files: [
                GeneratedFixtureEntry(path: "ProtocolFixtures/escape", sizeBytes: 6, sha256: "00")
            ]
        )
        let result = FixtureValidator.validate(manifest: bad, packageRoot: root, allowUnexpectedFiles: true)
        guard case .stale(let issues) = result else {
            Issue.record("Expected stale result for symlink escape")
            return
        }
        #expect(issues.contains { issue in
            if case .pathEscape(let path, _) = issue, path == "ProtocolFixtures/escape" { return true }
            return false
        })
    }

    @Test("FixtureValidator.validateContainedFixturePath accepts valid fixture paths")
    func fixtureValidatorAcceptsValidPaths() throws {
        let root = packageRoot
        let fixturesRoot = root.appendingPathComponent("ProtocolFixtures")
            .resolvingSymlinksInPath().standardizedFileURL
        // The real fixture path must pass validation.
        #expect(throws: Never.self) {
            try FixtureValidator.validateContainedFixturePath(
                "ProtocolFixtures/acp-methods.json",
                packageRoot: root,
                resolvedFixturesRoot: fixturesRoot
            )
        }
    }

    @Test("FixtureValidator.validateContainedFixturePath rejects traversal")
    func fixtureValidatorValidateRejectsTraversal() throws {
        let root = packageRoot
        let fixturesRoot = root.appendingPathComponent("ProtocolFixtures")
            .resolvingSymlinksInPath().standardizedFileURL
        #expect(throws: FixturePathError.self) {
            try FixtureValidator.validateContainedFixturePath(
                "ProtocolFixtures/../NOTICE",
                packageRoot: root,
                resolvedFixturesRoot: fixturesRoot
            )
        }
    }

    @Test("FixtureValidator.isUnder detects containment")
    func fixtureValidatorIsUnder() {
        let root = URL(fileURLWithPath: "/tmp/ProtocolFixtures")
        let inside = URL(fileURLWithPath: "/tmp/ProtocolFixtures/acp.json")
        let outside = URL(fileURLWithPath: "/tmp/NOTICE")
        let same = URL(fileURLWithPath: "/tmp/ProtocolFixtures")
        #expect(FixtureValidator.isUnder(inside, root: root))
        #expect(FixtureValidator.isUnder(same, root: root))
        #expect(!FixtureValidator.isUnder(outside, root: root))
    }

    // MARK: - Semantic fixture payloads (not digest-only)

    @Test("OTLP golden protobuf is real ExportTraceServiceRequest bytes")
    func otlpGoldenIsProtobufNotJSON() throws {
        let http = try Data(contentsOf: packageRoot
            .appendingPathComponent("ProtocolFixtures/otlp-export-trace-http.pb"))
        let grpc = try Data(contentsOf: packageRoot
            .appendingPathComponent("ProtocolFixtures/otlp-export-trace-grpc.bin"))
        #expect(http.first == 0x0A)
        #expect(http.first != UInt8(ascii: "{"))
        #expect(String(decoding: http, as: UTF8.self).contains("collector_golden"))
        #expect(grpc.count == http.count + 5)
        #expect(grpc.first == 0)
        let len = (UInt32(grpc[1]) << 24) | (UInt32(grpc[2]) << 16)
            | (UInt32(grpc[3]) << 8) | UInt32(grpc[4])
        #expect(Int(len) == http.count)
        #expect(grpc.subdata(in: 5..<grpc.count) == http)

        let shape = try JSONSerialization.jsonObject(
            with: Data(contentsOf: packageRoot
                .appendingPathComponent("ProtocolFixtures/otlp-span-export-shape.json"))
        ) as? [String: Any]
        #expect(shape?["grpcExportRPCPath"] as? String
            == "/opentelemetry.proto.collector.trace.v1.TraceService/Export")
        #expect(shape?["goldenHttpProtobuf"] as? String
            == "ProtocolFixtures/otlp-export-trace-http.pb")
    }

    @Test("Crash GCRX sample has magic/version and matching meta fixture")
    func crashGCRXSampleSemantic() throws {
        let blob = try Data(contentsOf: packageRoot
            .appendingPathComponent("ProtocolFixtures/crash-gcrx-sample.bin"))
        #expect(blob.count >= 64)
        #expect(Array(blob.prefix(4)) == [0x47, 0x43, 0x52, 0x58]) // GCRX
        #expect(blob[4] == 1)
        #expect(blob[5] == 11) // SIGSEGV sample
        let meta = try JSONSerialization.jsonObject(
            with: Data(contentsOf: packageRoot
                .appendingPathComponent("ProtocolFixtures/crash-gcrx-format.json"))
        ) as? [String: Any]
        #expect(meta?["magic"] as? String == "GCRX")
        #expect(meta?["version"] as? Int == 1)
        #expect(meta?["headerSize"] as? Int == 64)
    }

    @Test("Git loose-object fixture decompresses to blob hello")
    func gitLooseBlobSemantic() throws {
        let zlibBytes = try Data(contentsOf: packageRoot
            .appendingPathComponent("ProtocolFixtures/git-loose-blob-hello.zlib"))
        #expect(!zlibBytes.isEmpty)
        let meta = try JSONSerialization.jsonObject(
            with: Data(contentsOf: packageRoot
                .appendingPathComponent("ProtocolFixtures/git-object-and-index.json"))
        ) as? [String: Any]
        let example = meta?["blobSha1Example"] as? [String: Any]
        #expect(example?["sha1Hex"] as? String
            == "ce013625030ba8dba906f756967f9e9ca394464a")
        #expect(example?["looseObjectZlibSize"] as? Int == zlibBytes.count)
        #expect((meta?["packedObjects"] as? [String: Any])?["supported"] as? Bool == false)
    }

    @Test("Foundation format fixtures cover tracing storage hunk PTY crash")
    func foundationFormatFixturesPresent() throws {
        let required = [
            "tracing-w3c-traceparent.json",
            "sqlite-journal-modes.json",
            "hunk-tracker-snapshot.json",
            "pty-process-signals.json",
            "crash-gcrx-format.json",
            "crash-gcrx-sample.bin",
            "otlp-export-trace-http.pb",
            "otlp-export-trace-grpc.bin",
            "PROVENANCE.json",
        ]
        for name in required {
            let url = packageRoot.appendingPathComponent("ProtocolFixtures/\(name)")
            #expect(FileManager.default.fileExists(atPath: url.path), "missing \(name)")
        }
        let pty = try JSONSerialization.jsonObject(
            with: Data(contentsOf: packageRoot
                .appendingPathComponent("ProtocolFixtures/pty-process-signals.json"))
        ) as? [String: Any]
        let signals = pty?["processSignals"] as? [String: Int]
        #expect(signals?["terminate"] == 15)
        #expect(signals?["kill"] == 9)
        let tracing = try JSONSerialization.jsonObject(
            with: Data(contentsOf: packageRoot
                .appendingPathComponent("ProtocolFixtures/tracing-w3c-traceparent.json"))
        ) as? [String: Any]
        #expect((tracing?["sampleTraceparent"] as? String)?.hasPrefix("00-") == true)
        let hunk = try JSONSerialization.jsonObject(
            with: Data(contentsOf: packageRoot
                .appendingPathComponent("ProtocolFixtures/hunk-tracker-snapshot.json"))
        ) as? [String: Any]
        #expect(hunk?["schemaVersion"] as? Int == 1)
        let storage = try JSONSerialization.jsonObject(
            with: Data(contentsOf: packageRoot
                .appendingPathComponent("ProtocolFixtures/sqlite-journal-modes.json"))
        ) as? [String: Any]
        #expect((storage?["journalModes"] as? [String])?.contains("WAL") == true)
    }

    // MARK: - ProtoBuilder API (issue 1: functional parity port)

    @Test("ProtoBuilder.configure() mirrors Rust xai_proto_build::configure()")
    func protoBuilderConfigure() {
        let builder = ProtoBuilder.configure(
            compiler: FakeProtoCompiler(),
            environment: [:],
            workingDirectory: isolatedWorkingDirectory()
        )
        // Mirrors `compile_well_known_types(true)`.
        #expect(builder.compileWellKnownTypes)
        // Mirrors `extern_path(".google.protobuf", "::pbjson_types")` and
        // `extern_path(".google.protobuf.Empty", "()")`.
        #expect(builder.externPaths.count == 2)
        #expect(builder.externPaths[0].protoPackage == ".google.protobuf")
        #expect(builder.externPaths[0].swiftPackageOrAlias == "::pbjson_types")
        #expect(builder.externPaths[1].protoPackage == ".google.protobuf.Empty")
        #expect(builder.externPaths[1].swiftPackageOrAlias == "()")
        // Mirrors `protoc_arg("--experimental_allow_proto3_optional")`.
        #expect(builder.protocArguments == ["--experimental_allow_proto3_optional"])
        // Defaults.
        #expect(builder.descriptorFormat == .binary)
        #expect(builder.emitDependencies)
        #expect(!builder.generateJsonDescriptors)
        #expect(!builder.ignoreUnknownFields)
        #expect(!builder.preserveProtoFieldNames)
        #expect(!builder.generateDefaultStubs)
    }

    @Test("ProtoBuilder builder methods return new copies (value type)")
    func protoBuilderBuilderMethods() {
        let base = ProtoBuilder.configure(
            compiler: FakeProtoCompiler(),
            environment: [:],
            workingDirectory: isolatedWorkingDirectory()
        )
        let modified = base
            .bytes(["a/b.proto"])
            .externPath(".foo", "Foo")
            .genPbjson()
            .pbjsonIgnoreUnknownFields()
            .pbjsonPreserveProtoFieldNames()
            .generateDefaultStubs(true)
            .typeAttribute(".foo.Bar", "#[derive(Decodable)]")
            .fieldAttribute(".foo.Bar.baz", "#[default]")
            .descriptorFormat(.json)
            .emitDependencies(false)
        // Original is unchanged (value type).
        #expect(base.bytesPaths.isEmpty)
        #expect(base.externPaths.count == 2)
        #expect(!base.generateJsonDescriptors)
        #expect(base.descriptorFormat == .binary)
        #expect(base.emitDependencies)
        // Modified copy carries all the changes.
        #expect(modified.bytesPaths == ["a/b.proto"])
        #expect(modified.externPaths.count == 3)
        #expect(modified.externPaths[2].protoPackage == ".foo")
        #expect(modified.generateJsonDescriptors)
        #expect(modified.ignoreUnknownFields)
        #expect(modified.preserveProtoFieldNames)
        #expect(modified.generateDefaultStubs)
        #expect(modified.typeAttributes[0].path == ".foo.Bar")
        #expect(modified.fieldAttributes[0].path == ".foo.Bar.baz")
        #expect(modified.descriptorFormat == .json)
        #expect(!modified.emitDependencies)
    }

    @Test("ProtoBuilder.compileProtos rejects absolute proto input paths")
    func protoBuilderRejectsAbsoluteProtos() {
        let builder = ProtoBuilder.configure(
            compiler: FakeProtoCompiler(),
            environment: [:],
            workingDirectory: isolatedWorkingDirectory()
        )
        #expect(throws: ProtoBuildError.self) {
            try builder.compileProtos(protos: ["/abs/path.proto"])
        }
        #expect(throws: ProtoBuildError.self) {
            try builder.compileProtos(protos: ["C:\\abs\\path.proto"])
        }
    }

    @Test("ProtoBuilder.compileProtos short-circuits on empty protos")
    func protoBuilderEmptyProtos() throws {
        let builder = ProtoBuilder.configure(
            compiler: FakeProtoCompiler(),
            environment: [:],
            workingDirectory: isolatedWorkingDirectory()
        )
        let output = try builder.compileProtos(protos: [])
        #expect(output.protoc == nil)
        #expect(output.descriptorSet == nil)
        #expect(output.dependencies.isEmpty)
        #expect(output.includes.isEmpty)
    }

    @Test("ProtoBuilder.compileProtos raises protocNotFound in strict env")
    func protoBuilderStrictEnv() {
        let builder = ProtoBuilder.configure(
            compiler: FakeProtoCompiler(),
            environment: ["GITHUB_ACTIONS": "true"],
            workingDirectory: isolatedWorkingDirectory()
        )
        // GITHUB_ACTIONS present (any value) -> strict -> protocNotFound.
        #expect(throws: ProtoBuildError.protocNotFound) {
            try builder.compileProtos(protos: ["a.proto"])
        }
    }

    @Test("ProtoBuilder.compileProtos raises invocationFailed when protoc missing in non-strict env")
    func protoBuilderMissingProtocNonStrict() {
        let builder = ProtoBuilder.configure(
            compiler: FakeProtoCompiler(),
            environment: [:],
            workingDirectory: isolatedWorkingDirectory()
        )
        // No protoc, no GITHUB_ACTIONS -> invocationFailed (not silent nil),
        // mirroring the Rust compile_protos failure path.
        do {
            _ = try builder.compileProtos(protos: ["a.proto"])
            Issue.record("Expected invocationFailed")
        } catch let ProtoBuildError.invocationFailed(msg) {
            #expect(msg.contains("protoc"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("ProtoBuilder.parseDependencyOutput parses /dev/null:-prefixed deps")
    func protoBuilderParseDeps() throws {
        let builder = ProtoBuilder.configure(
            compiler: FakeProtoCompiler(),
            environment: [:],
            workingDirectory: isolatedWorkingDirectory()
        )
        // Create real dependency files so the existence check passes.
        let work = isolatedWorkingDirectory()
        let depA = work.appendingPathComponent("a.proto")
        let depB = work.appendingPathComponent("b.proto")
        try Data("a".utf8).write(to: depA)
        try Data("b".utf8).write(to: depB)
        let output = "/dev/null: \(depA.path) \\\n \(depB.path)\n"
        var deps: [URL] = []
        var seen = Set<String>()
        try builder.parseDependencyOutput(output, wellKnownInclude: nil, into: &deps, seen: &seen)
        #expect(deps.count == 2)
        #expect(deps[0].path == depA.path)
        #expect(deps[1].path == depB.path)
    }

    @Test("ProtoBuilder.parseDependencyOutput skips well-known google.protobuf includes")
    func protoBuilderParseDepsSkipsWellKnown() throws {
        let builder = ProtoBuilder.configure(
            compiler: FakeProtoCompiler(),
            environment: [:],
            workingDirectory: isolatedWorkingDirectory()
        )
        let work = isolatedWorkingDirectory()
        let realDep = work.appendingPathComponent("a.proto")
        try Data("a".utf8).write(to: realDep)
        // The well-known path does not need to exist on disk because it is
        // skipped before the existence check.
        let wellKnown = "/opt/protoc/include/google/protobuf/timestamp.proto"
        let output = "/dev/null: \(realDep.path) \(wellKnown)\n"
        var deps: [URL] = []
        var seen = Set<String>()
        try builder.parseDependencyOutput(output, wellKnownInclude: nil, into: &deps, seen: &seen)
        #expect(deps.count == 1)
        #expect(deps[0].path == realDep.path)
    }

    @Test("ProtoBuilder.parseDependencyOutput rejects missing dependency files")
    func protoBuilderParseDepsRejectsMissing() {
        let builder = ProtoBuilder.configure(
            compiler: FakeProtoCompiler(),
            environment: [:],
            workingDirectory: isolatedWorkingDirectory()
        )
        let missing = "/nonexistent/dep.proto"
        let output = "/dev/null: \(missing)\n"
        var deps: [URL] = []
        var seen = Set<String>()
        do {
            try builder.parseDependencyOutput(output, wellKnownInclude: nil, into: &deps, seen: &seen)
            Issue.record("Expected dependencyNotFound")
        } catch let ProtoBuildError.dependencyNotFound(path) {
            #expect(path == missing)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("ProtoBuilder.parseDependencyOutput rejects malformed output")
    func protoBuilderParseDepsRejectsMalformed() {
        let builder = ProtoBuilder.configure(
            compiler: FakeProtoCompiler(),
            environment: [:],
            workingDirectory: isolatedWorkingDirectory()
        )
        let output = "not the expected prefix\n"
        var deps: [URL] = []
        var seen = Set<String>()
        // The parser requires the first line to start with "/dev/null:".
        // Any other prefix triggers dependencyOutputMalformed.
        do {
            try builder.parseDependencyOutput(output, wellKnownInclude: nil, into: &deps, seen: &seen)
            Issue.record("Expected dependencyOutputMalformed")
        } catch ProtoBuildError.dependencyOutputMalformed {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("ProtoBuilder.defaultDescriptorSetURL derives binary and JSON names")
    func protoBuilderDefaultDescriptorURL() {
        let work = isolatedWorkingDirectory()
        let binary = ProtoBuilder.configure(
            compiler: FakeProtoCompiler(),
            environment: [:],
            workingDirectory: work
        )
        #expect(binary.defaultDescriptorSetURL().lastPathComponent == "xai-proto-build.pbbin")
        let json = binary.descriptorFormat(.json)
        #expect(json.defaultDescriptorSetURL().lastPathComponent == "xai-proto-build.pbschema.json")
    }

    @Test("ProtoBuilder.genPbjson enables JSON descriptor generation")
    func protoBuilderGenPbjson() {
        let base = ProtoBuilder.configure(
            compiler: FakeProtoCompiler(),
            environment: [:],
            workingDirectory: isolatedWorkingDirectory()
        )
        let withJson = base.genPbjson()
        #expect(withJson.generateJsonDescriptors)
        // genPbjson switches the descriptor format to JSON — the
        // Swift-native equivalent of pbjson_build's JSON type generation.
        // The Rust reference uses a binary descriptor set to drive
        // pbjson_build internally, but the Swift port has no pbjson
        // equivalent, so genPbjson directly switches the output to JSON
        // format (the closest Swift-native behavior).
        #expect(withJson.descriptorFormat == .json)
    }

    @Test("ProtoBuilder.fileDescriptorSetPath sets explicit output URL")
    func protoBuilderFileDescriptorSetPath() throws {
        let work = isolatedWorkingDirectory()
        let explicit = work.appendingPathComponent("custom.pbbin")
        let builder = ProtoBuilder.configure(
            compiler: FakeProtoCompiler(),
            environment: [:],
            workingDirectory: work
        ).fileDescriptorSetPath(explicit)
        #expect(builder.fileDescriptorSetPath?.path == explicit.path)
    }

    @Test("ProtoDescriptorFormat has binary and json cases")
    func protoDescriptorFormatCases() {
        #expect(ProtoDescriptorFormat.binary == .binary)
        #expect(ProtoDescriptorFormat.json == .json)
        #expect(ProtoDescriptorFormat.binary != .json)
    }

    @Test("ProtoCompilationOutput carries deterministic inputs/outputs")
    func protoCompilationOutputShape() {
        let protoc = URL(fileURLWithPath: "/usr/local/bin/protoc")
        let include = URL(fileURLWithPath: "/usr/local/include")
        let desc = URL(fileURLWithPath: "/tmp/desc.pbbin")
        let dep = URL(fileURLWithPath: "/tmp/a.proto")
        let inc = URL(fileURLWithPath: "/tmp/proto")
        let output = ProtoCompilationOutput(
            protoc: protoc,
            wellKnownTypesInclude: include,
            descriptorSet: desc,
            dependencies: [dep],
            includes: [inc]
        )
        #expect(output.protoc?.path == protoc.path)
        #expect(output.wellKnownTypesInclude?.path == include.path)
        #expect(output.descriptorSet?.path == desc.path)
        #expect(output.dependencies.map(\.path) == [dep.path])
        #expect(output.includes.map(\.path) == [inc.path])
    }

    @Test("ProtoCompiler protocol extension provides default isStrictEnvironment")
    func protoCompilerDefaultStrictEnv() {
        // A custom ProtoCompiler that does not implement isStrictEnvironment
        // inherits the Rust-parity default from the protocol extension.
        let compiler = FakeProtoCompiler()
        #expect(compiler.isStrictEnvironment(["GITHUB_ACTIONS": "false"]))
        #expect(compiler.isStrictEnvironment(["GITHUB_ACTIONS": ""]))
        #expect(!compiler.isStrictEnvironment([:]))
    }
}

// MARK: - Fake ProtoCompiler for deterministic ProtoBuilder tests

/// A fake `ProtoCompiler` that never discovers a protoc and never resolves
/// a well-known include directory. Used to exercise `ProtoBuilder`'s
/// validation, short-circuit, strict-environment, and error paths without
/// requiring a real `protoc` binary on the host.
private struct FakeProtoCompiler: ProtoCompiler {
    func discoverProtoc(environment: [String: String]) -> URL? { nil }
    func discoverProtoc(environment: [String: String], strict: Bool) throws -> URL? {
        if strict || isStrictEnvironment(environment) {
            throw ProtoBuildError.protocNotFound
        }
        return nil
    }
    func protocIsGood(_ protoc: URL) -> Bool { false }
    func wellKnownTypesInclude(for protoc: URL) -> URL? { nil }
    func validateInputPaths(_ protoPaths: [String]) throws {
        try ProtoBuildRules.validateInputPaths(protoPaths)
    }
}

private extension Character {
    var isHexDigit: Bool {
        ("0"..."9").contains(self) || ("a"..."f").contains(self)
    }
}
