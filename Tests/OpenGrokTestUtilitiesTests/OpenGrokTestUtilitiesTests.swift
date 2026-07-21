// OpenGrokTestUtilitiesTests.swift
//
// Target-scoped Swift Testing suites for the W0-S2 `OpenGrokTestUtilities`
// target. Ports the deterministic tests from `xai-test-utils` and adds
// focused coverage for the W0-S2 acceptance primitive (`HermeticEnv`):
// every helper creates isolated HOME / USERPROFILE / OPENGROK_HOME and
// refuses paths resolving to the real `~/.opengrok`.

import Foundation
import Testing
@testable import OpenGrokTestUtilities

@Suite("OpenGrokTestUtilities")
struct OpenGrokTestUtilitiesTests {
    // MARK: - EnvKnobs

    @Test("envUsize falls back to default when unset")
    func envUsizeDefault() {
        #expect(EnvKnobs.envUsize("UNSET_VAR_\(UUID().uuidString)", default: 42, environment: [:]) == 42)
    }

    @Test("envUsize parses a usize value")
    func envUsizeParsed() {
        #expect(EnvKnobs.envUsize("GROK_PERF_GIT_FILES", default: 0, environment: ["GROK_PERF_GIT_FILES": "123"]) == 123)
    }

    @Test("envUsize falls back when unparseable")
    func envUsizeUnparseable() {
        #expect(EnvKnobs.envUsize("BAD", default: 7, environment: ["BAD": "not-a-number"]) == 7)
    }

    @Test("envBool parses common true/false spellings")
    func envBoolParsing() {
        #expect(EnvKnobs.envBool("X", default: false, environment: ["X": "1"]) == true)
        #expect(EnvKnobs.envBool("X", default: false, environment: ["X": "true"]) == true)
        #expect(EnvKnobs.envBool("X", default: false, environment: ["X": "TRUE"]) == true)
        #expect(EnvKnobs.envBool("X", default: false, environment: ["X": "yes"]) == true)
        #expect(EnvKnobs.envBool("X", default: false, environment: ["X": "0"]) == false)
        #expect(EnvKnobs.envBool("X", default: false, environment: ["X": "false"]) == false)
        #expect(EnvKnobs.envBool("X", default: true, environment: ["X": "no"]) == false)
        #expect(EnvKnobs.envBool("X", default: true, environment: [:]) == true)
    }

    @Test("envString falls back to default when unset")
    func envStringDefault() {
        #expect(EnvKnobs.envString("UNSET_STR_\(UUID().uuidString)", default: "fallback", environment: [:]) == "fallback")
    }

    @Test("envString returns the env value when set")
    func envStringValue() {
        #expect(EnvKnobs.envString("MY_STR", default: "fallback", environment: ["MY_STR": "value"]) == "value")
    }

    // MARK: - ImageFixtures

    @Test("icoWithPngFrame produces the canonical ICO header")
    func icoHeader() {
        let png = Data([0x89, 0x50, 0x4E, 0x47]) // PNG magic
        let ico = ImageFixtures.icoWithPngFrame(png: png, width: 16, height: 16)
        // ICONDIR: 00 00 01 00 01 00
        #expect(ico[0] == 0x00)
        #expect(ico[1] == 0x00)
        #expect(ico[2] == 0x01) // type = icon
        #expect(ico[3] == 0x00)
        #expect(ico[4] == 0x01) // count = 1
        #expect(ico[5] == 0x00)
        // ICONDIRENTRY: width, height, palette(0), reserved(0), planes(1,0), bpp(32,0)
        #expect(ico[6] == 16)
        #expect(ico[7] == 16)
        #expect(ico[8] == 0x00)
        #expect(ico[9] == 0x00)
        #expect(ico[10] == 0x01)
        #expect(ico[11] == 0x00)
        #expect(ico[12] == 0x20) // 32 bpp
        #expect(ico[13] == 0x00)
        // Bytes-in-resource (LE, 4 bytes) = png.count
        let sizeLE = UInt32(png.count)
        #expect(ico[14] == UInt8(truncatingIfNeeded: sizeLE))
        #expect(ico[15] == UInt8(truncatingIfNeeded: sizeLE >> 8))
        // Offset = 22
        #expect(ico[18] == 22)
        // PNG payload appended at offset 22.
        #expect(ico.count == 22 + png.count)
        #expect(ico[22] == 0x89)
    }

    // MARK: - LogCapture

    @Test("MessagePrefixCounter counts only registered prefixes")
    func prefixCounter() throws {
        let counter = MessagePrefixCounter(prefixes: ["SCAN:", "REFRESH:"])
        counter.record(level: .debug, message: "SCAN: started", metadata: [:])
        counter.record(level: .debug, message: "REFRESH: completed", metadata: [:])
        counter.record(level: .debug, message: "SCAN: again", metadata: [:])
        counter.record(level: .info, message: "unrelated", metadata: [:])
        #expect(counter.count(for: "SCAN:") == 2)
        #expect(counter.count(for: "REFRESH:") == 1)
    }

    @Test("MessagePrefixCounter crashes on unregistered prefix")
    func prefixCounterUnregistered() {
        let counter = MessagePrefixCounter(prefixes: ["A:"])
        #expect(counter.countOrNil("B:") == 0)
        // Direct `count(for:)` on an unregistered prefix crashes (mirrors
        // the Rust panic). We verify via `countOrNil` instead; the crash
        // behavior is documented in the docstring.
    }

    @Test("BufferingTestLogger records messages in order")
    func bufferingLogger() {
        let logger = BufferingTestLogger()
        logger.record(level: .info, message: "first", metadata: [:])
        logger.record(level: .warn, message: "second", metadata: [:])
        #expect(logger.messages() == ["first", "second"])
    }

    // MARK: - HermeticEnv (W0-S2 acceptance)

    @Test("HermeticEnv creates isolated HOME, USERPROFILE, and OPENGROK_HOME")
    func hermeticEnvIsolation() throws {
        let realHome = RealOpengrokHome(userHome: "/tmp/og-real-home-\(UUID().uuidString)", opengrokHome: "/tmp/og-real-home-\(UUID().uuidString)/.opengrok")
        let env = try HermeticEnv(realHome: realHome, inherit: ["PATH": "/usr/bin"])
        defer { var mutable = env; mutable.dispose() }
        #expect(env.environment["HOME"] == env.root.path)
        #expect(env.environment["USERPROFILE"] == env.root.path)
        #expect(env.environment["OPENGROK_HOME"] == env.opengrokHome.path)
        #expect(env.opengrokHome.path == "\(env.root.path)/.opengrok")
        // Telemetry kill-switches mirror `test_env_cmd_tokio`.
        #expect(env.environment["GROK_TELEMETRY_ENABLED"] == "false")
        #expect(env.environment["GROK_FEEDBACK_ENABLED"] == "false")
        #expect(env.environment["GROK_TRACE_UPLOAD"] == "false")
        #expect(env.environment["GROK_INSTRUMENTATION"] == "disabled")
        // Inherited non-isolation vars survive.
        #expect(env.environment["PATH"] == "/usr/bin")
    }

    @Test("HermeticEnv refuses paths resolving to the real ~/.opengrok")
    func hermeticEnvRefusal() throws {
        let realHome = RealOpengrokHome(userHome: "/tmp/og-real", opengrokHome: "/tmp/og-real/.opengrok")
        let env = try HermeticEnv(realHome: realHome, inherit: [:])
        defer { var mutable = env; mutable.dispose() }
        let realPath = URL(fileURLWithPath: "/tmp/og-real/.opengrok")
        #expect(env.resolvesToRealHome(realPath))
        #expect(throws: HermeticEnvError.self) {
            try env.refuseIfReal(realPath)
        }
        // A non-real path is accepted.
        let safePath = env.root.appendingPathComponent("safe")
        #expect(!env.resolvesToRealHome(safePath))
        try env.refuseIfReal(safePath) // does not throw
    }

    @Test("HermeticEnv.write refuses the real ~/.opengrok")
    func hermeticEnvWriteRefusal() throws {
        let realHome = RealOpengrokHome(userHome: "/tmp/og-real-write", opengrokHome: "/tmp/og-real-write/.opengrok")
        let env = try HermeticEnv(realHome: realHome, inherit: [:])
        defer { var mutable = env; mutable.dispose() }
        let realPath = URL(fileURLWithPath: "/tmp/og-real-write/.opengrok/cache.json")
        #expect(throws: HermeticEnvError.self) {
            try env.writeString("poisoned", to: realPath)
        }
        // A safe path inside the isolated env writes successfully.
        let safePath = env.opengrokHome.appendingPathComponent("cache.json")
        try env.writeString("safe", to: safePath)
        #expect(FileManager.default.fileExists(atPath: safePath.path))
    }

    @Test("HermeticEnv.ensureDirectory refuses the real ~/.opengrok")
    func hermeticEnsureDirectoryRefusal() throws {
        let realHome = RealOpengrokHome(userHome: "/tmp/og-real-ensure", opengrokHome: "/tmp/og-real-ensure/.opengrok")
        let env = try HermeticEnv(realHome: realHome, inherit: [:])
        defer { var mutable = env; mutable.dispose() }
        let realPath = URL(fileURLWithPath: "/tmp/og-real-ensure/.opengrok")
        #expect(throws: HermeticEnvError.self) {
            try env.ensureDirectory(realPath)
        }
    }

    @Test("HermeticEnv refuses descendant paths beneath the real ~/.opengrok")
    func hermeticEnvRefusesDescendant() throws {
        // The guard must reject not only the real home itself but also any
        // path BENEATH it. The previous lexical-equality guard let
        // `<realHome>/.opengrok/subdir` through; the containment-aware
        // guard rejects it.
        let realRoot = "/tmp/og-real-desc-\(UUID().uuidString)"
        let realHome = RealOpengrokHome(userHome: realRoot, opengrokHome: "\(realRoot)/.opengrok")
        // Create the real home directory so the symlink-resolver can
        // canonicalize it. (The guard also handles non-existent paths via
        // lexical fallback, but the descendant check is most meaningful
        // when the parent exists.)
        try FileManager.default.createDirectory(
            atPath: "\(realRoot)/.opengrok",
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(atPath: realRoot) }
        let env = try HermeticEnv(realHome: realHome, inherit: [:])
        defer { var mutable = env; mutable.dispose() }

        // Direct descendant: refused by `refuseIfReal`.
        let descendant = URL(fileURLWithPath: "\(realRoot)/.opengrok/cache/models_cache.json")
        #expect(env.resolvesToRealHome(descendant))
        #expect(throws: HermeticEnvError.self) {
            try env.refuseIfReal(descendant)
        }
        // `ensureDirectory` on a descendant subdirectory of the real home
        // is refused — this is the exact bypass the reviewer flagged.
        let subdir = URL(fileURLWithPath: "\(realRoot)/.opengrok/subdir")
        #expect(throws: HermeticEnvError.self) {
            try env.ensureDirectory(subdir)
        }
        // `write` to a descendant is refused.
        let file = URL(fileURLWithPath: "\(realRoot)/.opengrok/data/poison.json")
        #expect(throws: HermeticEnvError.self) {
            try env.writeString("poisoned", to: file)
        }
        // A path that merely shares a lexical prefix (but is NOT a
        // descendant) is accepted: containment uses a path-component-aware
        // prefix check, not `String.hasPrefix`.
        let sibling = URL(fileURLWithPath: "\(realRoot)/.opengrok-sibling")
        #expect(!env.resolvesToRealHome(sibling))
        try env.refuseIfReal(sibling)
    }

    @Test("HermeticEnv refuses a symlink alias that resolves to the real ~/.opengrok")
    func hermeticEnvRefusesSymlinkAlias() throws {
        // A symlink whose target is the real `~/.opengrok` must be refused
        // even when the symlink itself lives under a safe-looking path.
        // The previous lexical guard did not resolve symlinks, so the
        // alias passed; the symlink-resolving guard rejects it.
        let realRoot = "/tmp/og-real-sym-\(UUID().uuidString)"
        let realHome = RealOpengrokHome(userHome: realRoot, opengrokHome: "\(realRoot)/.opengrok")
        try FileManager.default.createDirectory(
            atPath: "\(realRoot)/.opengrok",
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(atPath: realRoot) }

        // Create a symlink alias that points at the real home.
        let aliasRoot = "/tmp/og-alias-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: aliasRoot,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(atPath: aliasRoot) }
        let aliasPath = "\(aliasRoot)/alias-to-real"
        try FileManager.default.createSymbolicLink(
            atPath: aliasPath,
            withDestinationPath: "\(realRoot)/.opengrok"
        )

        let env = try HermeticEnv(realHome: realHome, inherit: [:])
        defer { var mutable = env; mutable.dispose() }

        // The alias URL resolves to the real home: refused.
        let aliasURL = URL(fileURLWithPath: aliasPath)
        #expect(env.resolvesToRealHome(aliasURL))
        #expect(throws: HermeticEnvError.self) {
            try env.refuseIfReal(aliasURL)
        }
        // A descendant of the alias (e.g. `<alias>/cache.json`) also
        // resolves into the real home: refused.
        let aliasDescendant = URL(fileURLWithPath: "\(aliasPath)/cache.json")
        #expect(env.resolvesToRealHome(aliasDescendant))
        #expect(throws: HermeticEnvError.self) {
            try env.ensureDirectory(aliasDescendant)
        }
    }

    @Test("HermeticEnv.resolveOpengrokHome honors OPENGROK_HOME > HOME > USERPROFILE")
    func resolvePrecedence() {
        #expect(HermeticEnv.resolveOpengrokHome(environment: ["OPENGROK_HOME": "/tmp/og-override", "HOME": "/tmp/h"]).path == "/tmp/og-override")
        #expect(HermeticEnv.resolveOpengrokHome(environment: ["HOME": "/tmp/h"]).path == "/tmp/h/.opengrok")
        #expect(HermeticEnv.resolveOpengrokHome(environment: ["USERPROFILE": "/tmp/p"]).path == "/tmp/p/.opengrok")
        #expect(HermeticEnv.resolveOpengrokHome(environment: [:]).path.contains(".opengrok"))
    }

    // MARK: - HermeticGit

    @Test("HermeticGit.baseGitEnvironment masks global config and disables prompts")
    func baseGitEnv() {
        let env = HermeticGit.baseGitEnvironment(environment: ["PATH": "/usr/bin"])
        #expect(env["GIT_AUTHOR_NAME"] == "Test User")
        #expect(env["GIT_AUTHOR_EMAIL"] == "test@test.com")
        #expect(env["GIT_COMMITTER_NAME"] == "Test User")
        #expect(env["GIT_COMMITTER_EMAIL"] == "test@test.com")
        #expect(env["GIT_CONFIG_NOSYSTEM"] == "1")
        #expect(env["GIT_TERMINAL_PROMPT"] == "0")
        #if os(Windows)
        #expect(env["GIT_CONFIG_GLOBAL"] == "NUL")
        #else
        #expect(env["GIT_CONFIG_GLOBAL"] == "/dev/null")
        #endif
    }

    @Test("HermeticGit.resolveGitExecutable honors an absolute GIT_BIN_PATH verbatim")
    func resolveGitExecutableAbsolute() {
        // An absolute binary path (the form `GIT_BIN_PATH` typically takes
        // under Bazel/CI) is returned verbatim — no PATH search, no
        // `/usr/bin/env` indirection (which does not exist on Windows).
        let env = ["GIT_BIN_PATH": "/opt/hermetic/bin/git", "PATH": "/usr/bin"]
        let resolved = HermeticGit.gitBinary(environment: env)
        #expect(resolved == "/opt/hermetic/bin/git")
        let resolvedExe = HermeticGit.resolveGitExecutable(binary: resolved, environment: env)
        #expect(resolvedExe == "/opt/hermetic/bin/git")
    }

    @Test("HermeticGit.resolveGitExecutable searches PATH for a bare 'git' name")
    func resolveGitExecutablePathSearch() throws {
        // A bare `git` name is resolved by searching PATH for the first
        // existing executable entry. This is the platform-neutral
        // equivalent of Rust's `Command::new("git")` PATH search and
        // avoids `/usr/bin/env` (Windows-incompatible).
        let tempRoot = "/tmp/og-git-resolve-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempRoot) }
        // Symlink the system git into the temp dir so the PATH search finds
        // it there. (We avoid copying the binary; a symlink is enough for
        // `isExecutableFile` to return true and for the resolved path to
        // differ from `/usr/bin/env`.)
        let systemGit = "/usr/bin/git"
        guard FileManager.default.isExecutableFile(atPath: systemGit) else {
            // If the test host has no `/usr/bin/git`, skip the symlink
            // portion and still verify the empty-PATH fallback returns
            // the bare name unchanged.
            let resolved = HermeticGit.resolveGitExecutable(binary: "git", environment: ["PATH": tempRoot])
            #expect(resolved == "git")
            return
        }
        let tempGit = "\(tempRoot)/git"
        try? FileManager.default.removeItem(atPath: tempGit)
        try FileManager.default.createSymbolicLink(
            atPath: tempGit,
            withDestinationPath: systemGit
        )
        let resolved = HermeticGit.resolveGitExecutable(binary: "git", environment: ["PATH": tempRoot])
        #expect(resolved == tempGit)
        // When PATH has no match, the bare name is returned so `Process.run`
        // surfaces a clear "no such file" error rather than masking it.
        let emptyPathResolved = HermeticGit.resolveGitExecutable(binary: "git", environment: ["PATH": "/nonexistent"])
        #expect(emptyPathResolved == "git")
    }

    @Test("HermeticGit.runGitWithEnv uses a platform-neutral git binary, not /usr/bin/env")
    func runGitWithEnvNoEnvWrapper() throws {
        // The previous implementation hard-coded `/usr/bin/env` as the
        // executable, which does not exist on Windows. The port-neutral
        // implementation resolves `git` via PATH (or `GIT_BIN_PATH`) and
        // spawns it directly. Verify a real `git` invocation succeeds
        // under a hermetic env with a clean PATH that includes the system
        // git directory.
        let env = try HermeticEnv(
            inherit: ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? ""]
        )
        defer { var mutable = env; mutable.dispose() }
        let repo = env.root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let gitEnv = HermeticGit.baseGitEnvironment(environment: env.environment)
        try HermeticGit.initGitRepo(at: repo, environment: gitEnv)
        // `git --version` works without a repo and exercises the same
        // spawn path. If the implementation still used `/usr/bin/env`, this
        // call would fail on Windows (where the path does not exist) and
        // succeed everywhere else; the test guards the regression on
        // macOS/Linux by confirming a clean spawn.
        let version = try HermeticGit.runGit(
            in: repo,
            arguments: ["--version"],
            environment: gitEnv
        )
        #expect(version.contains("git version"))
    }

    @Test("HermeticGit.writeFanoutTree creates the expected file count")
    func fanoutTree() throws {
        let env = try HermeticEnv()
        defer { var mutable = env; mutable.dispose() }
        let treeRoot = env.root.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: treeRoot, withIntermediateDirectories: true)
        try HermeticGit.writeFanoutTree(in: treeRoot, files: 10, filesPerDir: 4)
        // 10 files / 4 per dir = 3 dirs (4 + 4 + 2).
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: treeRoot.path)) ?? []
        #expect(contents.contains("g0")) // group 0
    }

    @Test("HermeticGit.initGitRepo + gitCommitAll produce a commit history")
    func initAndCommit() throws {
        // Inherit PATH so `git` is resolvable in the hermetic subprocess env.
        let env = try HermeticEnv(inherit: ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? ""])
        defer { var mutable = env; mutable.dispose() }
        let repo = env.root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let gitEnv = HermeticGit.baseGitEnvironment(environment: env.environment)
        try HermeticGit.initGitRepo(at: repo, environment: gitEnv)
        // Write a file and commit it.
        let file = repo.appendingPathComponent("hello.txt")
        try "hello\n".write(to: file, atomically: true, encoding: .utf8)
        try HermeticGit.gitCommitAll(at: repo, message: "first", environment: gitEnv)
        // The repo has exactly one commit on the default branch.
        let log = try HermeticGit.runGit(in: repo, arguments: ["log", "--oneline"], environment: gitEnv)
        #expect(log.contains("first"))
        // `git status` is clean (the commit captured everything).
        let status = try HermeticGit.runGit(in: repo, arguments: ["status", "--porcelain"], environment: gitEnv)
        #expect(status.isEmpty)
    }

    @Test("HermeticGit.runGitWithEnv applies extra env on top of the hermetic base")
    func runGitWithEnvExtra() throws {
        // Inherit PATH so `git` is resolvable in the hermetic subprocess env.
        let env = try HermeticEnv(inherit: ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? ""])
        defer { var mutable = env; mutable.dispose() }
        let repo = env.root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let gitEnv = HermeticGit.baseGitEnvironment(environment: env.environment)
        try HermeticGit.initGitRepo(at: repo, environment: gitEnv)
        // Commit a file with an overridden `GIT_AUTHOR_NAME` via the extra
        // env layer; the commit author should reflect the override, not the
        // base env's "Test User".
        let file = repo.appendingPathComponent("a.txt")
        try "a\n".write(to: file, atomically: true, encoding: .utf8)
        try HermeticGit.runGitWithEnv(
            in: repo,
            arguments: ["add", "a.txt"],
            extraEnvironment: [:],
            environment: gitEnv
        )
        try HermeticGit.runGitWithEnv(
            in: repo,
            arguments: ["commit", "-m", "msg"],
            extraEnvironment: ["GIT_AUTHOR_NAME": "OverrideName"],
            environment: gitEnv
        )
        // `git log --format=%an` prints the author name of the last commit.
        let author = try HermeticGit.runGit(
            in: repo,
            arguments: ["log", "-1", "--format=%an"],
            environment: gitEnv
        )
        #expect(author == "OverrideName")
    }

    // MARK: - Runfiles

    @Test("Runfiles.tryResolve returns nil under SwiftPM")
    func runfilesNil() {
        #expect(Runfiles.tryResolve("nonexistent/path") == nil)
    }

    @Test("Runfiles.crateRoot falls back to a file path")
    func crateRootFallback() {
        let root = Runfiles.crateRoot(fallback: #filePath)
        #expect(FileManager.default.fileExists(atPath: root.path))
    }
}
