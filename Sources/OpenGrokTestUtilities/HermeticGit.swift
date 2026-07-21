// HermeticGit.swift
//
// Port of `xai-test-utils/src/git.rs`. Provides hermetic git helpers for
// tests that need throwaway git repos. The Rust reference prepends a
// Bazel-provided static `git` binary to `PATH` via `GIT_BIN_PATH`; under
// SwiftPM there is no Bazel runfiles tree, so `ensureHermeticGitOnPath`
// honors `GIT_BIN_PATH` (used when a CI hermetic git is available) but
// otherwise lets `git` resolve from `PATH`.
//
// All git commands mask the developer's global/system git config
// (`GIT_CONFIG_GLOBAL=/dev/null` / `NUL`, `GIT_CONFIG_NOSYSTEM=1`) and disable
// credential prompts (`GIT_TERMINAL_PROMPT=0`), so a developer's
// `commit.gpgsign`, `core.hooksPath`, or `rebase.autoSquash` settings can
// never change test behavior — the same invariant the Rust source documents.

import Foundation

/// Hermetic git helpers.
public enum HermeticGit {
    /// The env var naming a hermetic git binary directory (mirrors Rust's
    /// `GIT_BIN_PATH`). When set, the directory is prepended to `PATH` for
    /// spawned git processes so `git` resolves to it.
    public static let gitBinPathEnv = "GIT_BIN_PATH"

    /// Prepend the hermetic git binary directory to `PATH` (read-only).
    /// Returns the `PATH` value callers should pass to spawned git commands.
    /// When `GIT_BIN_PATH` is set, its parent directory is prepended so
    /// `git` resolves to the hermetic binary; otherwise `PATH` is returned
    /// unchanged. Unlike the Rust reference, this helper does NOT mutate the
    /// live process environment (Swift 6 forbids `setenv` from concurrent
    /// code); callers pass the returned `PATH` explicitly to every spawned
    /// git command via `baseGitEnvironment`.
    public static func hermeticPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        guard let bin = environment[gitBinPathEnv], !bin.isEmpty else {
            return environment["PATH"] ?? ""
        }
        let binDir = (bin as NSString).deletingLastPathComponent
        let current = environment["PATH"] ?? ""
        if binDir.isEmpty { return current }
        #if os(Windows)
        return "\(binDir);\(current)"
        #else
        return "\(binDir):\(current)"
        #endif
    }

    /// Read-only parity with the Rust `ensure_hermetic_git_on_path`: returns
    /// the hermetic `PATH` value. Kept as a separate symbol so callers that
    /// mirror the Rust call site read identically.
    public static func ensureHermeticGitOnPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        return hermeticPath(environment: environment)
    }

    /// Resolve the git binary path. Honors `GIT_BIN_PATH` when set, else
    /// returns `git` (resolved by the OS at spawn time).
    public static func gitBinary(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let bin = environment[gitBinPathEnv], !bin.isEmpty {
            return bin
        }
        return "git"
    }

    /// The base environment for hermetic git commands: author/committer
    /// identity pinned, global/system config masked, credential prompts
    /// disabled. Callers add their own vars on top.
    public static func baseGitEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env = environment
        env["PATH"] = hermeticPath(environment: environment)
        env["GIT_AUTHOR_NAME"] = "Test User"
        env["GIT_AUTHOR_EMAIL"] = "test@test.com"
        env["GIT_COMMITTER_NAME"] = "Test User"
        env["GIT_COMMITTER_EMAIL"] = "test@test.com"
        #if os(Windows)
        env["GIT_CONFIG_GLOBAL"] = "NUL"
        #else
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        #endif
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_TERMINAL_PROMPT"] = "0"
        return env
    }

    /// Run a git command in `directory` with the hermetic base env, asserting
    /// success, and return trimmed stdout.
    @discardableResult
    public static func runGit(
        in directory: URL,
        arguments: [String],
        extraEnvironment: [String: String] = [:],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        try runGitWithEnv(
            in: directory,
            arguments: arguments,
            extraEnvironment: extraEnvironment,
            environment: environment
        )
    }

    /// Like `runGit` with extra env vars applied on top of the hermetic base
    /// (e.g. `GIT_SEQUENCE_EDITOR`). Mirrors `run_git_with_env`.
    ///
    /// The git binary is resolved via `gitBinary(environment:)`: when
    /// `GIT_BIN_PATH` is set it points directly at the hermetic binary,
    /// otherwise the literal `"git"` is resolved through the supplied
    /// `PATH` at spawn time. This is platform-neutral (no `/usr/bin/env`,
    /// which does not exist on Windows) and matches the Rust
    /// `Command::new("git")` behavior under a `PATH`-prepended environment.
    public static func runGitWithEnv(
        in directory: URL,
        arguments: [String],
        extraEnvironment: [String: String] = [:],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        var env = baseGitEnvironment(environment: environment)
        for (k, v) in extraEnvironment {
            env[k] = v
        }
        let binary = gitBinary(environment: environment)
        let resolved = resolveGitExecutable(binary: binary, environment: env)
        let process = Process()
        // `resolved` is always an absolute, file-URL to an existing
        // executable (or `binary` itself when no PATH entry matched — in
        // which case `Process.run` will surface the missing-binary error
        // with a clear message). No `/usr/bin/env` indirection: that path
        // does not exist on Windows, and `Command::new("git")` in the Rust
        // reference resolves via PATH directly.
        process.executableURL = URL(fileURLWithPath: resolved)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw HermeticGitError.commandFailed(
                args: [binary] + arguments,
                status: Int(process.terminationStatus),
                stderr: stderrText
            )
        }
        let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""
        return stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Resolve `binary` to an absolute executable path. When `binary` is
    /// already an absolute path (e.g. from `GIT_BIN_PATH`) or a relative
    /// path containing a path separator, it is returned verbatim (the OS
    /// resolves relative paths against the process's CWD). When `binary`
    /// is a bare name like `"git"`, it is searched across `environment["PATH"]`
    /// using the platform's path separator (`:` on POSIX, `;` on Windows)
    /// and the platform's executable-extension list (`PATHEXT` on Windows,
    /// `[""]` on POSIX). The first existing executable entry wins; if none
    /// matches, `binary` is returned unchanged so `Process.run` surfaces
    /// the missing-binary error rather than masking it.
    ///
    /// This is the platform-neutral equivalent of Rust's
    /// `Command::new("git")` PATH search and avoids `/usr/bin/env`
    /// (which does not exist on Windows).
    static func resolveGitExecutable(binary: String, environment: [String: String]) -> String {
        // Absolute path or path-with-separator: use verbatim.
        if binary.hasPrefix("/") || binary.contains("/") {
            return binary
        }
        #if os(Windows)
        let pathSeparator: Character = ";"
        let pathExt = environment["PATHEXT"]
            ?? ".EXE;.CMD;.BAT"
        let extensions = pathExt.split(separator: ";").map(String.init)
        let executableExtensions = extensions.isEmpty ? [""] : extensions
        #else
        let pathSeparator: Character = ":"
        let executableExtensions = [""]
        #endif
        let pathValue = environment["PATH"]
            ?? environment["Path"]
            ?? ProcessInfo.processInfo.environment["PATH"]
            ?? ProcessInfo.processInfo.environment["Path"]
            ?? ""
        let fm = FileManager.default
        for dir in pathValue.split(separator: pathSeparator, omittingEmptySubsequences: true) {
            let dirString = String(dir)
            for ext in executableExtensions {
                let candidate = (dirString as NSString).appendingPathComponent(binary + ext)
                if fm.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        // No PATH entry matched: return the bare name so `Process.run`
        // surfaces a clear "no such file" error to the caller (matching
        // `Command::new("git")` when git is not installed).
        return binary
    }

    /// Initialise a fresh git repository at `path` with the dummy user config
    /// the hermetic env already pins. Idempotent: re-running `git init` on an
    /// existing repo is safe.
    public static func initGitRepo(
        at path: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        try runGit(in: path, arguments: ["init"], environment: environment)
        try runGit(in: path, arguments: ["config", "user.email", "test@test.com"], environment: environment)
        try runGit(in: path, arguments: ["config", "user.name", "Test"], environment: environment)
    }

    /// Stage all files and create a commit with `message`.
    public static func gitCommitAll(
        at path: URL,
        message: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        try runGit(in: path, arguments: ["add", "."], environment: environment)
        try runGit(in: path, arguments: ["commit", "-m", message], environment: environment)
    }

    /// Write a grouped fan-out tree of ~`files` files (`filesPerDir` per
    /// directory, directories bucketed 100 per group) under `directory`. No
    /// git operations — callers stage/commit as needed. Mirrors
    /// `write_fanout_tree`.
    public static func writeFanoutTree(
        in directory: URL,
        files: Int,
        filesPerDir: Int
    ) throws {
        let dirs = (files + filesPerDir - 1) / filesPerDir
        for d in 0..<dirs {
            let sub = directory
                .appendingPathComponent("g\(d / 100)", isDirectory: true)
                .appendingPathComponent("d\(d)", isDirectory: true)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            for f in 0..<filesPerDir {
                let fileURL = sub.appendingPathComponent("file_\(f).txt")
                let content = "content \(d) \(f)\n"
                try content.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Create a `feature` branch with `picks` one-file commits off the
    /// current HEAD, advance the base branch by one commit (so a rebase has
    /// work), and leave `feature` checked out. Returns the base branch name.
    @discardableResult
    public static func makeFeatureBranch(
        at directory: URL,
        picks: Int,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        let base = try runGit(in: directory, arguments: ["rev-parse", "--abbrev-ref", "HEAD"], environment: environment)
        try runGit(in: directory, arguments: ["checkout", "-b", "feature"], environment: environment)
        for k in 0..<picks {
            let name = "pick_\(k).txt"
            let fileURL = directory.appendingPathComponent(name)
            try "pick \(k)\n".write(to: fileURL, atomically: true, encoding: .utf8)
            try runGit(in: directory, arguments: ["add", name], environment: environment)
            try runGit(in: directory, arguments: ["commit", "-m", "pick \(k)"], environment: environment)
        }
        try runGit(in: directory, arguments: ["checkout", base], environment: environment)
        let advanceURL = directory.appendingPathComponent("base_advance.txt")
        try "advance\n".write(to: advanceURL, atomically: true, encoding: .utf8)
        try runGit(in: directory, arguments: ["add", "base_advance.txt"], environment: environment)
        try runGit(in: directory, arguments: ["commit", "-m", "advance base"], environment: environment)
        try runGit(in: directory, arguments: ["checkout", "feature"], environment: environment)
        return base
    }
}

/// Errors thrown by hermetic git helpers.
public enum HermeticGitError: Error, Equatable, CustomStringConvertible {
    case commandFailed(args: [String], status: Int, stderr: String)

    public var description: String {
        switch self {
        case let .commandFailed(args, status, stderr):
            return "git \(args.dropFirst().joined(separator: " ")) failed (exit \(status)): \(stderr)"
        }
    }
}
