// OpenGrokPathsTests.swift
//
// Target-scoped Swift Testing suites for `OpenGrokPaths` (W0-S3).
//
// Tests translate the Rust `xai-grok-paths/src/lib.rs` `tests` module and add
// the W0-S3 acceptance cases for `OPENGROK_HOME` / `~/.opengrok` resolution
// and the `~/.grok` non-touch guarantee.

import Foundation
import Testing
@testable import OpenGrokPaths

@Suite("OpenGrokPaths")
struct OpenGrokPathsTests {

    // MARK: - AbsPath

    #if !os(Windows)
    @Test("AbsPath accepts an absolute path")
    func absPathNew() throws {
        let abs = try AbsPath("/home/user")
        #expect(abs.asString == "/home/user")
        #expect(abs.description == "/home/user")
        #expect(abs.fileSystemPath == "/home/user")
    }
    #endif

    @Test("AbsPath rejects a relative path")
    func absPathRejectsRelative() {
        do {
            _ = try AbsPath("relative/path")
            Issue.record("AbsPath should reject a relative path")
        } catch let error as AbsPathError {
            if case .notAbsolute(let input) = error {
                #expect(input == "relative/path")
            } else {
                Issue.record("Expected .notAbsolute but got \(error)")
            }
        } catch {
            Issue.record("Expected AbsPathError but got \(error)")
        }
    }

    #if !os(Windows)
    @Test("AbsPath.containsPath matches the Rust matrix")
    func absPathContainsPathMatrix() throws {
        let cwd = try AbsPath("/a/b")

        // Paths under cwd.
        #expect(cwd.containsPath(try AbsPath("/a/b/c")))
        #expect(cwd.containsPath(try AbsPath("/a/b/c/d")))

        // Exactly cwd.
        #expect(cwd.containsPath(try AbsPath("/a/b")))

        // Paths that escape via parent.
        #expect(!cwd.containsPath(try AbsPath("/a/b/..")))
        #expect(!cwd.containsPath(try AbsPath("/a/b/../c")))

        // Going above root and back normalizes to under cwd.
        #expect(cwd.containsPath(try AbsPath("/a/b/../../../a/b")))
        // Excessive above root still normalizes to root level (outside cwd).
        #expect(!cwd.containsPath(try AbsPath("/a/b/../../../../../c")))
    }
    #endif

    #if !os(Windows)
    @Test("containsPath does not normalize the stored root")
    func containsPathDoesNotNormalizeStoredRoot() throws {
        // `/a/b/..` is a non-normalized root. The Rust crate does NOT
        // normalize self when checking `starts_with`; the candidate `/a/c`
        // does not start with `/a/b/..`.
        let nonNormalizedRoot = try AbsPath("/a/b/..")
        let candidate = try AbsPath("/a/c")
        #expect(!nonNormalizedRoot.containsPath(candidate))
    }
    #endif

    // MARK: - normalizeLexically

    #if !os(Windows)
    @Test("lexical normalize resolves dot segments without filesystem access")
    func lexicalNormalizeResolvesDotSegments() {
        #expect(normalizeLexically("/work/project/src/./nested/../main.rs") == "/work/project/src/main.rs")
        #expect(normalizeLexically("../outside/./file.rs") == "../outside/file.rs")
        #expect(normalizeLexically("src/..") == ".")
        #expect(normalizeLexically("/../../tmp") == "/tmp")
    }
    #endif

    #if os(Windows)
    @Test("lexical normalize preserves Windows prefixes")
    func lexicalNormalizePreservesWindowsPrefixes() {
        #expect(normalizeLexically("C:\\work\\project\\..\\file.rs") == "C:\\work\\file.rs")
        #expect(normalizeLexically("C:\\..\\file.rs") == "C:\\file.rs")
        #expect(normalizeLexically("C:..\\outside.rs") == "C:..\\outside.rs")
    }
    #endif

    // MARK: - RelPath

    @Test("RelPath accepts a relative path")
    func relPathNew() throws {
        let rel = try RelPath("src/main.rs")
        #expect(rel.asString == "src/main.rs")
        #expect(rel.description == "src/main.rs")
    }

    @Test("RelPath rejects an absolute path")
    func relPathRejectsAbsolute() {
        do {
            _ = try RelPath("/absolute/path")
            Issue.record("RelPath should reject an absolute path")
        } catch let error as RelPathError {
            if case .notRelative(let input) = error {
                #expect(input == "/absolute/path")
            } else {
                Issue.record("Expected .notRelative but got \(error)")
            }
        } catch {
            Issue.record("Expected RelPathError but got \(error)")
        }
    }

    #if !os(Windows)
    @Test("RelPath.fromAbsolute strips the root prefix")
    func relPathFromAbsolute() throws {
        let root = "/home/user/project"
        let abs = "/home/user/project/src/main.rs"
        let rel = try RelPath.fromAbsolute(root: root, absPath: abs)
        #expect(rel.asString == "src/main.rs")
    }
    #endif

    #if !os(Windows)
    @Test("RelPath.fromAbsolute fails when not under root")
    func relPathFromAbsoluteNotUnderRoot() {
        let root = "/home/user/project"
        let abs = "/other/path/file.rs"
        #expect(throws: RelPathError.self) {
            _ = try RelPath.fromAbsolute(root: root, absPath: abs)
        }
    }
    #endif

    #if !os(Windows)
    @Test("RelPath.toAbsolute joins with root")
    func relPathToAbsolute() throws {
        let rel = try RelPath("src/main.rs")
        let root = "/home/user/project"
        #expect(rel.toAbsolute(root: root) == "/home/user/project/src/main.rs")
    }
    #endif

    #if !os(Windows)
    @Test("RelPath.fromAbsolute on the exact root yields the empty relative path")
    func relPathFromAbsoluteExactRoot() throws {
        let root = "/home/user/project"
        let rel = try RelPath.fromAbsolute(root: root, absPath: root)
        #expect(rel.asString == "")
        #expect(rel.toAbsolute(root: root) == root)
    }
    #endif

    @Test("RelPath conversions via String")
    func relPathConversions() throws {
        let rel = try RelPath("src/main.rs")
        let relString = rel.asString
        #expect(relString == "src/main.rs")
        let relFromString = try RelPath("src/main.rs")
        #expect(relFromString == rel)
    }

    // MARK: - Codable round-trip

    @Test("RelPath Codable round-trips through JSON")
    func relPathCodableRoundtrip() throws {
        let rel = try RelPath("src/main.rs")
        let encoder = JSONEncoder()
        let data = try encoder.encode(rel)
        // The JSON representation of a single string value is a quoted string.
        // Swift's `JSONEncoder` escapes `/` as `\/` (standard JSON escaping),
        // so the exact bytes differ from Rust's `serde_json` (which does not
        // escape slashes by default). The semantic round-trip is what matters
        // for wire compatibility.
        let decoded = try JSONDecoder().decode(RelPath.self, from: data)
        #expect(decoded == rel)
        #expect(decoded.asString == "src/main.rs")

        // Verify the encoded form is a quoted JSON string containing the path
        // payload (the Rust serde representation emits `"src/main.rs"`; Swift
        // emits `"src\/main.rs"` with slash escaping).
        if let raw = String(data: data, encoding: .utf8) {
            #expect(raw.contains("\""))
            #expect(raw.contains("main.rs"))
            #expect(raw.contains("src"))
        } else {
            Issue.record("Encoded JSON data was not valid UTF-8")
        }
    }

    @Test("RelPath Codable rejects an absolute string")
    func relPathCodableRejectsAbsolute() {
        let data = "\"/absolute/path\"".data(using: .utf8)!
        #expect(throws: RelPathError.self) {
            _ = try JSONDecoder().decode(RelPath.self, from: data)
        }
    }

    // MARK: - to_relative_path / from_relative_path

    #if !os(Windows)
    @Test("toRelativePath under root strips the prefix")
    func toRelativePathUnderRoot() {
        let root = "/home/user/project"
        let abs = "/home/user/project/src/main.rs"
        #expect(toRelativePath(root: root, absPath: abs) == "src/main.rs")
    }
    #endif

    #if !os(Windows)
    @Test("toRelativePath not under root returns the path unchanged")
    func toRelativePathNotUnderRoot() {
        let root = "/home/user/project"
        let abs = "/other/path/file.rs"
        #expect(toRelativePath(root: root, absPath: abs) == "/other/path/file.rs")
    }
    #endif

    #if !os(Windows)
    @Test("toRelativePath on the exact root yields empty")
    func toRelativePathExactRoot() {
        let root = "/home/user/project"
        #expect(toRelativePath(root: root, absPath: root) == "")
    }
    #endif

    #if !os(Windows)
    @Test("fromRelativePath joins relative with root")
    func fromRelativePathRelative() {
        let root = "/home/user/project"
        let rel = "src/main.rs"
        #expect(fromRelativePath(root: root, relPath: rel) == "/home/user/project/src/main.rs")
    }
    #endif

    #if !os(Windows)
    @Test("fromRelativePath preserves an already-absolute path")
    func fromRelativePathAlreadyAbsolute() {
        let root = "/home/user/project"
        let abs = "/other/path/file.rs"
        #expect(fromRelativePath(root: root, relPath: abs) == "/other/path/file.rs")
    }
    #endif

    // MARK: - ToAbsPath on String

    #if !os(Windows)
    @Test("String.toAbsPath joins relative with root")
    func stringToAbsPathRelative() {
        let root = "/home/user"
        let path: String = "src/main.rs"
        #expect(path.toAbsPath(root: root) == "/home/user/src/main.rs")
    }
    #endif

    #if !os(Windows)
    @Test("String.toAbsPath preserves an already-absolute path")
    func stringToAbsPathAbsolute() {
        let root = "/home/user"
        let path: String = "/other/path"
        #expect(path.toAbsPath(root: root) == "/other/path")
    }
    #endif

    // MARK: - W0-S3 acceptance: OPENGROK_HOME / ~/.opengrok

    @Test("OPENGROK_HOME override wins over HOME and USERPROFILE")
    func opengrokHomeOverrideWins() {
        let env = [
            "OPENGROK_HOME": "/tmp/og-home-xyz",
            "HOME": "/tmp/fake-home",
            "USERPROFILE": "/tmp/fake-profile",
        ]
        let home = OpenGrokStatePaths.stateDirectory(environment: env)
        #expect(home.path == "/tmp/og-home-xyz")
    }

    @Test("Fallback is ~/.opengrok when OPENGROK_HOME is unset")
    func fallbackIsOpgengrok() {
        let env = ["HOME": "/tmp/fake-home"]
        let home = OpenGrokStatePaths.stateDirectory(environment: env)
        #expect(home.path == "/tmp/fake-home/.opengrok")
    }

    @Test("Empty OPENGROK_HOME falls back to ~/.opengrok")
    func emptyOpengrokHomeFallsBack() {
        let env = ["OPENGROK_HOME": "", "HOME": "/tmp/fake-home"]
        let home = OpenGrokStatePaths.stateDirectory(environment: env)
        #expect(home.path == "/tmp/fake-home/.opengrok")
    }

    @Test("USERPROFILE is used when HOME is absent")
    func userProfileFallback() {
        let env: [String: String] = ["USERPROFILE": "/tmp/profile-home"]
        let home = OpenGrokStatePaths.userHomeDirectory(environment: env)
        #expect(home.path == "/tmp/profile-home")

        let state = OpenGrokStatePaths.stateDirectory(environment: env)
        #expect(state.path == "/tmp/profile-home/.opengrok")
    }

    @Test("The fallback is never ~/.grok")
    func neverLegacyGrok() {
        let env = ["HOME": "/tmp/fake-home"]
        let home = OpenGrokStatePaths.stateDirectory(environment: env)
        #expect(!OpenGrokStatePaths.isLegacyGrokPath(home, environment: env))
        #expect(!home.path.hasSuffix("/.grok"))
        #expect(home.path.hasSuffix("/.opengrok"))
        // Positive assertion: the resolved path is the canonical fallback.
        #expect(OpenGrokStatePaths.isFallbackOpenGrokPath(home, environment: env))
    }

    @Test("isLegacyGrokPath detects the forbidden legacy path")
    func isLegacyGrokPathDetects() {
        let env = ["HOME": "/tmp/fake-home"]
        let grok = URL(fileURLWithPath: "/tmp/fake-home/.grok")
        #expect(OpenGrokStatePaths.isLegacyGrokPath(grok, environment: env))
        let opengrok = URL(fileURLWithPath: "/tmp/fake-home/.opengrok")
        #expect(!OpenGrokStatePaths.isLegacyGrokPath(opengrok, environment: env))
    }

    @Test("Project-local state resolves to .opengrok")
    func projectStateDirectory() {
        let projectRoot = URL(fileURLWithPath: "/tmp/project")
        let projectState = OpenGrokStatePaths.projectStateDirectory(projectRoot: projectRoot)
        #expect(projectState.path == "/tmp/project/.opengrok")
    }

    @Test("Managed binary resolves under $OPENGROK_HOME/bin/open-grok")
    func managedBinaryUnderOpengrokHome() {
        let env = ["OPENGROK_HOME": "/tmp/og-home-test", "HOME": "/tmp/fake-home"]
        let managed = OpenGrokStatePaths.managedBinaryURL(environment: env)
        #expect(managed.path == "/tmp/og-home-test/bin/open-grok")
    }

    @Test("Managed binary never resolves under ~/.grok")
    func managedBinaryNeverUnderGrok() {
        let env = ["HOME": "/tmp/fake-home"]
        let managed = OpenGrokStatePaths.managedBinaryURL(environment: env)
        #expect(!OpenGrokStatePaths.isLegacyGrokPath(managed, environment: env))
        #expect(managed.path == "/tmp/fake-home/.opengrok/bin/open-grok")
    }

    @Test("Path policy constants match the Open Grok identity")
    func pathPolicyConstants() {
        #expect(OpenGrokPathPolicy.homeEnvironmentVariable == "OPENGROK_HOME")
        #expect(OpenGrokPathPolicy.fallbackStateDirectoryName == ".opengrok")
        #expect(OpenGrokPathPolicy.projectStateDirectoryName == ".opengrok")
        #expect(OpenGrokPathPolicy.managedBinarySubpath == "bin/open-grok")
        #expect(OpenGrokPathPolicy.legacyForbiddenStateDirectoryName == ".grok")
    }

    // MARK: - Path policy isolation summary

    @Test("OPENGROK_HOME / fallback / legacy are mutually distinct for every env shape")
    func isolationSummary() {
        let envs: [[String: String]] = [
            [:],
            ["HOME": "/tmp/h1"],
            ["HOME": "/tmp/h1", "USERPROFILE": "/tmp/p1"],
            ["OPENGROK_HOME": "/tmp/og", "HOME": "/tmp/h1"],
            ["OPENGROK_HOME": "", "HOME": "/tmp/h1"],
        ]
        for env in envs {
            let state = OpenGrokStatePaths.stateDirectory(environment: env)
            // The resolved state directory is never ~/.grok for any env shape.
            #expect(!OpenGrokStatePaths.isLegacyGrokPath(state, environment: env),
                    "Resolved state \(state.path) must never be the legacy ~/.grok for env \(env)")
            // The resolved state directory's last component is either
            // `.opengrok` or the operator-provided override (OPENGROK_HOME).
            let hasOverride = (env["OPENGROK_HOME"]?.isEmpty == false)
            if hasOverride {
                #expect(state.path == env["OPENGROK_HOME"])
            } else {
                #expect(state.path.hasSuffix("/.opengrok"))
            }
        }
    }
}
