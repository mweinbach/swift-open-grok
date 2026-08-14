// OpenGrokVersionTests.swift
//
// Target-scoped Swift Testing suites for `OpenGrokVersion` (W0-S3).
//
// Tests translate the Rust `xai-grok-version/src/lib.rs` `tests` module and
// add coverage for the minimal semver parser, the `GROK_TEST_VERSION` runtime
// override, and the Open Grok prerelease format `0.1.220-open-grok.58`.

import Foundation
import Testing
@testable import OpenGrokVersion

@Suite("OpenGrokVersion")
struct OpenGrokVersionTests {

    private var expectedCompiledVersion: String {
        ProcessInfo.processInfo.environment["GROK_TEST_EXPECTED_COMPILED_VERSION"]
            ?? "1.0.0-open-grok.63"
    }

    // MARK: - Compiled version constant

    @Test("Compiled version matches the reference OPEN_GROK_VERSION")
    func compiledVersionMatchesReference() {
        #expect(OpenGrokVersion.compiledVersion == expectedCompiledVersion)
    }

    @Test("package-root OPEN_GROK_VERSION matches the compiled default")
    func packageRootVersionMarkerMatchesCompiledDefault() throws {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while root.path != "/",
              !FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) {
            root.deleteLastPathComponent()
        }
        let marker = try String(
            contentsOf: root.appendingPathComponent("OPEN_GROK_VERSION"),
            encoding: .utf8
        )
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? ""
        #expect(marker == "1.0.0-open-grok.63")
        #expect(OpenGrokVersion.compiledVersion == marker)
    }

    @Test("compiledVersion is driven by the build-tool plugin (GROK_VERSION injection)")
    func compiledVersionDrivenByGeneratedFile() throws {
        // The `OpenGrokVersionBuildPlugin` build-tool plugin generates
        // `CompiledVersion.generated.swift` from the `GROK_VERSION`
        // environment variable at build time — the SwiftPM equivalent of
        // the Rust crate's `option_env!("GROK_VERSION")`.
        //
        // This test verifies that `compiledVersion` is a non-empty string
        // that matches the build's expected version. The checked-in
        // `Sources/OpenGrokVersion/CompiledVersion.generated.swift` is now
        // excluded from target compilation (the plugin generates the real
        // version into the build output), so this test checks the compiled
        // value directly rather than reading the source tree file.
        #expect(!OpenGrokVersion.compiledVersion.isEmpty,
                "compiledVersion must be a non-empty string injected at build time")
        #expect(OpenGrokVersion.compiledVersion == expectedCompiledVersion,
                "compiledVersion must match the expected build value (got \(OpenGrokVersion.compiledVersion))")
    }

    @Test("testVersionEnvironmentVariable matches Rust TEST_VERSION_ENV")
    func testVersionEnvMatches() {
        #expect(OpenGrokVersion.testVersionEnvironmentVariable == "GROK_TEST_VERSION")
    }

    @Test("compileTimeVersionEnvironmentVariable documents the GROK_VERSION build-time var")
    func compileTimeVersionEnvDocumented() {
        #expect(OpenGrokVersion.compileTimeVersionEnvironmentVariable == "GROK_VERSION")
    }

    // MARK: - installed()

    @Test("installed() returns the compiled version when no override is set")
    func installedReturnsCompiledDefault() {
        #expect(OpenGrokVersion.installed(environment: [:]) == OpenGrokVersion.compiledVersion)
    }

    @Test("installed() honors GROK_TEST_VERSION override")
    func installedHonorsOverride() {
        let env = ["GROK_TEST_VERSION": "9.9.9-test"]
        #expect(OpenGrokVersion.installed(environment: env) == "9.9.9-test")
    }

    @Test("installed() trims whitespace from the override")
    func installedTrimsOverride() {
        let env = ["GROK_TEST_VERSION": "  1.2.3  \n"]
        #expect(OpenGrokVersion.installed(environment: env) == "1.2.3")
    }

    @Test("installed() returns empty string for empty GROK_TEST_VERSION override (Rust parity)")
    func installedEmptyOverrideReturnsEmpty() {
        // The Rust reference treats any present `GROK_TEST_VERSION` value as
        // the override, trimming it and returning the result. An empty value
        // yields `""`, and `installed_semver()` subsequently reports a parse
        // error. This mirrors
        // `std::env::var(TEST_VERSION_ENV).map(|v| v.trim().to_string())`.
        let env = ["GROK_TEST_VERSION": ""]
        #expect(OpenGrokVersion.installed(environment: env) == "")
    }

    @Test("installed() returns empty string for whitespace-only GROK_TEST_VERSION override")
    func installedWhitespaceOnlyOverrideReturnsEmpty() {
        let env = ["GROK_TEST_VERSION": "   \n\t  "]
        #expect(OpenGrokVersion.installed(environment: env) == "")
    }

    @Test("installedSemVer() throws on an empty GROK_TEST_VERSION override (Rust parity)")
    func installedSemVerThrowsOnEmptyOverride() {
        let env = ["GROK_TEST_VERSION": ""]
        #expect(throws: OpenGrokVersionError.self) {
            _ = try OpenGrokVersion.installedSemVer(environment: env)
        }
    }

    // MARK: - installedSemVer()

    @Test("installedSemVer() parses the compiled Open Grok version")
    func installedSemVerParsesCompiled() throws {
        let version = try OpenGrokVersion.installedSemVer(environment: [:])
        let expected = try SemVerVersion.parse(expectedCompiledVersion)
        #expect(version == expected)
        #expect(version.hasPrerelease == expected.hasPrerelease)
        #expect(version.hasBuild == expected.hasBuild)
    }

    @Test("installedSemVer() parses a GROK_TEST_VERSION override")
    func installedSemVerParsesOverride() throws {
        let env = ["GROK_TEST_VERSION": "1.2.3-alpha.1+build.42"]
        let version = try OpenGrokVersion.installedSemVer(environment: env)
        #expect(version.major == 1)
        #expect(version.minor == 2)
        #expect(version.patch == 3)
        #expect(version.prerelease == ["alpha", "1"])
        #expect(version.build == ["build", "42"])
    }

    @Test("installedSemVer() throws on an invalid override")
    func installedSemVerThrowsOnInvalid() {
        let env = ["GROK_TEST_VERSION": "not-a-version"]
        #expect(throws: OpenGrokVersionError.self) {
            _ = try OpenGrokVersion.installedSemVer(environment: env)
        }
    }

    // MARK: - display_version / display_version_with_commit matrix

    @Test("display_version_with_commit formatting matrix (Rust parity)")
    func displayVersionWithCommitMatrix() {
        let cases: [(String, String, String)] = [
            ("0.2.5 (abc1234)", " [alpha]", "0.2.5 (abc1234) [alpha]"),
            ("0.2.5 (abc1234)", " [stable]", "0.2.5 (abc1234) [stable]"),
            ("0.2.5 (abc1234)", "", "0.2.5 (abc1234)"),
            ("0.1.220-alpha.2 (def0)", " [alpha]", "0.1.220-alpha.2 (def0) [alpha]"),
        ]
        for (vwc, label, expected) in cases {
            #expect(OpenGrokVersion.displayVersionWithCommit(vwc, channelLabel: label) == expected,
                    "displayVersionWithCommit(\(vwc), \(label))")
        }
    }

    @Test("display_version appends the channel label to the compiled version")
    func displayVersionAppendsLabel() {
        #expect(OpenGrokVersion.displayVersion(channelLabel: "") == OpenGrokVersion.compiledVersion)
        #expect(OpenGrokVersion.displayVersion(channelLabel: " [stable]").hasSuffix("[stable]"))
        #expect(
            OpenGrokVersion.displayVersion(channelLabel: " [alpha]")
                == "\(OpenGrokVersion.compiledVersion) [alpha]"
        )
    }

    // MARK: - SemVerVersion parser

    @Test("SemVerVersion parses a plain major.minor.patch")
    func semverParsesPlain() throws {
        let v = try SemVerVersion.parse("1.2.3")
        #expect(v.major == 1)
        #expect(v.minor == 2)
        #expect(v.patch == 3)
        #expect(v.prerelease == [])
        #expect(v.build == [])
        #expect(v.description == "1.2.3")
    }

    @Test("SemVerVersion parses with prerelease")
    func semverParsesPrerelease() throws {
        let v = try SemVerVersion.parse("1.2.3-alpha.1")
        #expect(v.prerelease == ["alpha", "1"])
        #expect(v.description == "1.2.3-alpha.1")
    }

    @Test("SemVerVersion parses with build metadata")
    func semverParsesBuild() throws {
        let v = try SemVerVersion.parse("1.2.3+build.42")
        #expect(v.build == ["build", "42"])
        #expect(v.description == "1.2.3+build.42")
    }

    @Test("SemVerVersion parses with prerelease and build")
    func semverParsesPrereleaseAndBuild() throws {
        let v = try SemVerVersion.parse("1.2.3-alpha.1+build.42")
        #expect(v.prerelease == ["alpha", "1"])
        #expect(v.build == ["build", "42"])
        #expect(v.description == "1.2.3-alpha.1+build.42")
    }

    @Test("SemVerVersion parses the Open Grok release string")
    func semverParsesOpenGrokRelease() throws {
        let v = try SemVerVersion.parse("0.1.220-open-grok.58")
        #expect(v.major == 0)
        #expect(v.minor == 1)
        #expect(v.patch == 220)
        #expect(v.prerelease == ["open-grok", "58"])
        #expect(v.description == "0.1.220-open-grok.58")
    }

    @Test("SemVerVersion trims surrounding whitespace")
    func semverTrimsWhitespace() throws {
        let v = try SemVerVersion.parse("  1.2.3  \n")
        #expect(v.major == 1)
        #expect(v.minor == 2)
        #expect(v.patch == 3)
    }

    @Test("SemVerVersion rejects empty input")
    func semverRejectsEmpty() {
        #expect(throws: OpenGrokVersionError.self) {
            _ = try SemVerVersion.parse("")
        }
        #expect(throws: OpenGrokVersionError.self) {
            _ = try SemVerVersion.parse("   ")
        }
    }

    @Test("SemVerVersion rejects a non-numeric core")
    func semverRejectsNonNumericCore() {
        #expect(throws: OpenGrokVersionError.self) {
            _ = try SemVerVersion.parse("a.b.c")
        }
        #expect(throws: OpenGrokVersionError.self) {
            _ = try SemVerVersion.parse("1.2")
        }
        #expect(throws: OpenGrokVersionError.self) {
            _ = try SemVerVersion.parse("1.2.3.4")
        }
    }

    @Test("SemVerVersion rejects leading zeros in numeric core parts")
    func semverRejectsLeadingZeros() {
        #expect(throws: OpenGrokVersionError.self) {
            _ = try SemVerVersion.parse("01.2.3")
        }
        #expect(throws: OpenGrokVersionError.self) {
            _ = try SemVerVersion.parse("1.02.3")
        }
        #expect(throws: OpenGrokVersionError.self) {
            _ = try SemVerVersion.parse("1.2.03")
        }
    }

    @Test("SemVerVersion rejects empty prerelease after dash")
    func semverRejectsEmptyPrerelease() {
        #expect(throws: OpenGrokVersionError.self) {
            _ = try SemVerVersion.parse("1.2.3-")
        }
        #expect(throws: OpenGrokVersionError.self) {
            _ = try SemVerVersion.parse("1.2.3-alpha..beta")
        }
    }

    @Test("SemVerVersion rejects invalid identifier characters")
    func semverRejectsInvalidIdentifierChars() {
        #expect(throws: OpenGrokVersionError.self) {
            _ = try SemVerVersion.parse("1.2.3-alpha_beta")
        }
        #expect(throws: OpenGrokVersionError.self) {
            _ = try SemVerVersion.parse("1.2.3-alpha/beta")
        }
    }

    @Test("SemVerVersion rejects leading zeros in numeric prerelease identifiers")
    func semverRejectsLeadingZerosPrerelease() {
        #expect(throws: OpenGrokVersionError.self) {
            _ = try SemVerVersion.parse("1.2.3-01")
        }
    }

    @Test("SemVerVersion accepts numeric zero as a prerelease identifier")
    func semverAcceptsZeroPrerelease() throws {
        let v = try SemVerVersion.parse("1.2.3-0")
        #expect(v.prerelease == ["0"])
    }

    // MARK: - UInt64 boundary parity (Rust semver::Version supports u64)

    @Test("SemVerVersion accepts core components above Int.max (UInt64 range)")
    func semverAcceptsAboveIntMax() throws {
        // Rust `semver::Version` supports the full `u64` version-component
        // range. `Int.max` on 64-bit platforms is `9223372036854775807`;
        // `Int.max + 1` is `9223372036854775808`, which overflows a signed
        // `Int` but is a valid `UInt64` (and a valid Rust semver component).
        let aboveIntMax = "9223372036854775808"
        let v = try SemVerVersion.parse("\(aboveIntMax).0.0")
        #expect(v.major == 9223372036854775808)
        #expect(v.minor == 0)
        #expect(v.patch == 0)
        #expect(v.description == "\(aboveIntMax).0.0")
    }

    @Test("SemVerVersion accepts UInt64.max as a core component")
    func semverAcceptsUInt64Max() throws {
        let max = "18446744073709551615"
        let v = try SemVerVersion.parse("\(max).\(max).\(max)")
        #expect(v.major == UInt64.max)
        #expect(v.minor == UInt64.max)
        #expect(v.patch == UInt64.max)
        #expect(v.description == "\(max).\(max).\(max)")
    }

    @Test("SemVerVersion accepts numeric prerelease identifiers above Int.max")
    func semverAcceptsPrereleaseAboveIntMax() throws {
        let aboveIntMax = "9223372036854775808"
        let v = try SemVerVersion.parse("1.0.0-\(aboveIntMax)")
        #expect(v.prerelease == [aboveIntMax])
    }

    @Test("SemVerVersion accepts UInt64.max as a numeric prerelease identifier")
    func semverAcceptsPrereleaseUInt64Max() throws {
        let max = "18446744073709551615"
        let v = try SemVerVersion.parse("1.0.0-\(max)")
        #expect(v.prerelease == [max])
    }

    @Test("SemVerVersion orders UInt64 components correctly above Int.max")
    func semverOrdersAboveIntMax() throws {
        let v1 = try SemVerVersion.parse("9223372036854775807.0.0")
        let v2 = try SemVerVersion.parse("9223372036854775808.0.0")
        #expect(v1 < v2, "UInt64 ordering must hold above Int.max")
        #expect(!(v2 < v1))
    }

    @Test("SemVerVersion orders numeric prerelease identifiers above Int.max")
    func semverOrdersPrereleaseAboveIntMax() throws {
        let v1 = try SemVerVersion.parse("1.0.0-9223372036854775807")
        let v2 = try SemVerVersion.parse("1.0.0-9223372036854775808")
        #expect(v1 < v2, "UInt64 prerelease ordering must hold above Int.max")
        #expect(!(v2 < v1))
    }

    @Test("SemVerVersion rejects core components exceeding UInt64.max")
    func semverRejectsAboveUInt64Max() {
        #expect(throws: OpenGrokVersionError.self) {
            _ = try SemVerVersion.parse("18446744073709551616.0.0")
        }
    }

    // MARK: - SemVer ordering

    @Test("SemVer ordering: 1.0.0 < 2.0.0 < 2.1.0 < 2.1.1")
    func semverOrderingCore() throws {
        let v1 = try SemVerVersion.parse("1.0.0")
        let v2 = try SemVerVersion.parse("2.0.0")
        let v3 = try SemVerVersion.parse("2.1.0")
        let v4 = try SemVerVersion.parse("2.1.1")
        #expect(v1 < v2)
        #expect(v2 < v3)
        #expect(v3 < v4)
        #expect(v1 < v4)
    }

    @Test("SemVer ordering: prerelease is lower than the same version without")
    func semverOrderingPrereleaseLowerThanRelease() throws {
        let pre = try SemVerVersion.parse("1.0.0-alpha")
        let release = try SemVerVersion.parse("1.0.0")
        #expect(pre < release)
    }

    @Test("SemVer ordering: numeric prerelease identifiers are lower than alphanumeric")
    func semverOrderingNumericLowerThanAlpha() throws {
        let numeric = try SemVerVersion.parse("1.0.0-1")
        let alpha = try SemVerVersion.parse("1.0.0-alpha")
        #expect(numeric < alpha)
    }

    @Test("SemVer ordering: shorter prerelease is lower when prefix matches")
    func semverOrderingShorterPrereleaseLower() throws {
        let shorter = try SemVerVersion.parse("1.0.0-alpha")
        let longer = try SemVerVersion.parse("1.0.0-alpha.1")
        #expect(shorter < longer)
    }

    @Test("SemVer ordering: build metadata is ignored for precedence")
    func semverOrderingBuildIgnored() throws {
        let a = try SemVerVersion.parse("1.0.0+build.1")
        let b = try SemVerVersion.parse("1.0.0+build.2")
        // Build metadata is ignored for ordering: neither is less than the other.
        #expect(!(a < b))
        #expect(!(b < a))
        // Rust's `semver::Version` `Eq` compares build metadata; distinct build
        // strings are not equal. This matches the Rust crate's `PartialEq`.
        #expect(a != b)
        // Same major/minor/patch/prerelease means same precedence.
        #expect(a.major == b.major)
        #expect(a.minor == b.minor)
        #expect(a.patch == b.patch)
        #expect(a.prerelease == b.prerelease)
    }

    @Test("SemVer open-grok release ordering: prerelease < stable")
    func semverOpenGrokReleaseOrdering() throws {
        let release = try SemVerVersion.parse("0.1.220")
        let pre = try SemVerVersion.parse("0.1.220-open-grok.58")
        #expect(pre < release)
    }

    // MARK: - GROK_VERSION build-time injection verification

    @Test("regenerate-compiled-version.sh injects distinct GROK_VERSION values (build-time injection parity)")
    func regenerateCompiledVersionInjectsDistinctVersions() throws {
        // The Rust crate reads `GROK_VERSION` at compile time via
        // `option_env!("GROK_VERSION")` and rebuilds when the env var changes
        // (`cargo:rerun-if-env-changed=GROK_VERSION`). The Swift port
        // regenerates `CompiledVersion.generated.swift` via
        // `Sources/OpenGrokVersion/regenerate-compiled-version.sh`. This test
        // proves the injection path: two distinct `GROK_VERSION` values produce
        // distinct version strings in the generated file, matching the Rust
        // build-time injection semantics.
        //
        // To avoid mutating the real source file (which would change the
        // compiled `compiledVersion` on the next build), the script is copied
        // to a temporary directory and run there. The script computes its
        // output path relative to its own location, so the temp-copy writes to
        // the temp directory.
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // OpenGrokVersionTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // package root
        let script = packageRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("OpenGrokVersion")
            .appendingPathComponent("regenerate-compiled-version.sh")

        #expect(FileManager.default.fileExists(atPath: script.path),
                "regenerate-compiled-version.sh must exist at \(script.path)")

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-version-inject-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let tempScript = tempDir.appendingPathComponent("regenerate-compiled-version.sh")
        try FileManager.default.copyItem(at: script, to: tempScript)

        func runRegenerate(version: String) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [tempScript.path]
            process.environment = ["GROK_VERSION": version]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            process.waitUntilExit()
            let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8) ?? ""
            #expect(process.terminationStatus == 0,
                    "regenerate-compiled-version.sh must exit 0 for GROK_VERSION=\(version); output: \(output)")
            let generatedFile = tempDir.appendingPathComponent("CompiledVersion.generated.swift")
            return try String(contentsOf: generatedFile, encoding: .utf8)
        }

        func extractVersion(from source: String) throws -> String {
            let pattern = #"internal static let version: String = "([^"]*)""#
            let regex = try NSRegularExpression(pattern: pattern)
            let nsSource = source as NSString
            guard let match = regex.firstMatch(
                in: source,
                range: NSRange(location: 0, length: nsSource.length)
            ), let range = Range(match.range(at: 1), in: source) else {
                Issue.record("Generated file must contain a version string literal")
                return ""
            }
            return String(source[range])
        }

        let source1 = try runRegenerate(version: "1.2.3-alpha.1")
        let version1 = try extractVersion(from: source1)
        #expect(version1 == "1.2.3-alpha.1",
                "Generated file must embed GROK_VERSION=1.2.3-alpha.1 (got \(version1))")

        let source2 = try runRegenerate(version: "9.9.9-beta.42+build.7")
        let version2 = try extractVersion(from: source2)
        #expect(version2 == "9.9.9-beta.42+build.7",
                "Generated file must embed GROK_VERSION=9.9.9-beta.42+build.7 (got \(version2))")

        #expect(version1 != version2,
                "Two distinct GROK_VERSION values must produce distinct compiled version strings")
        #expect(source1 != source2,
                "Two distinct GROK_VERSION values must produce distinct generated file contents")
    }

    @Test("regenerate-compiled-version.sh falls back to OPEN_GROK_VERSION file when GROK_VERSION is unset")
    func regenerateFallsBackToVersionFile() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // OpenGrokVersionTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // package root
        let script = packageRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("OpenGrokVersion")
            .appendingPathComponent("regenerate-compiled-version.sh")
        let versionFile = packageRoot.appendingPathComponent("OPEN_GROK_VERSION")

        #expect(FileManager.default.fileExists(atPath: script.path),
                "regenerate-compiled-version.sh must exist at \(script.path)")

        // Copy the script to a temp directory so it does not mutate the real
        // source file. Also copy OPEN_GROK_VERSION into the temp package root
        // so the fallback path can be exercised.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-version-fallback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // The script computes `package_root` as `script_dir/../..`. To make
        // that resolve to `tempDir`, create `tempDir/Sources/OpenGrokVersion/`
        // and place the script there.
        let tempScriptDir = tempDir
            .appendingPathComponent("Sources")
            .appendingPathComponent("OpenGrokVersion")
        try FileManager.default.createDirectory(
            at: tempScriptDir,
            withIntermediateDirectories: true
        )
        let tempScript = tempScriptDir.appendingPathComponent("regenerate-compiled-version.sh")
        try FileManager.default.copyItem(at: script, to: tempScript)

        // Copy OPEN_GROK_VERSION into the temp package root if it exists.
        if FileManager.default.fileExists(atPath: versionFile.path) {
            try FileManager.default.copyItem(
                at: versionFile,
                to: tempDir.appendingPathComponent("OPEN_GROK_VERSION")
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [tempScript.path]
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "GROK_VERSION")
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(process.terminationStatus == 0,
                "regenerate-compiled-version.sh must exit 0 when GROK_VERSION is unset; output: \(output)")

        let generatedFile = tempScriptDir.appendingPathComponent("CompiledVersion.generated.swift")
        let source = try String(contentsOf: generatedFile, encoding: .utf8)
        let pattern = #"internal static let version: String = "([^"]*)""#
        let regex = try NSRegularExpression(pattern: pattern)
        let nsSource = source as NSString
        guard let match = regex.firstMatch(
            in: source,
            range: NSRange(location: 0, length: nsSource.length)
        ), let range = Range(match.range(at: 1), in: source) else {
            Issue.record("Generated file must contain a version string literal")
            return
        }
        let version = String(source[range])
        #expect(!version.isEmpty,
                "Generated file must embed a non-empty version when GROK_VERSION is unset")

        // If the package root has an OPEN_GROK_VERSION file (copied into the
        // temp package root), the script must use its first line. Otherwise it
        // uses the default `0.1.220-open-grok.58`.
        let tempVersionFile = tempDir.appendingPathComponent("OPEN_GROK_VERSION")
        if FileManager.default.fileExists(atPath: tempVersionFile.path),
           let fileContents = try? String(contentsOf: tempVersionFile, encoding: .utf8) {
            let firstLine = fileContents
                .split(separator: "\n", omittingEmptySubsequences: false)
                .first
                .map(String.init)
            if let trimmed = firstLine?.trimmingCharacters(in: .whitespacesAndNewlines),
               !trimmed.isEmpty {
                #expect(version == trimmed,
                        "Generated version must match OPEN_GROK_VERSION file when GROK_VERSION is unset")
            }
        } else {
            // No OPEN_GROK_VERSION file in the package root: the script falls
            // back to the default version.
            #expect(version == "1.0.0-open-grok.62",
                    "Generated version must be the default when no OPEN_GROK_VERSION file exists")
        }
    }
}
