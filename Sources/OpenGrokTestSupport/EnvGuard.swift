// EnvGuard.swift
//
// Port of `xai-grok-test-support/src/env.rs`. Provides:
//   * `EnvGuard` — RAII environment-variable snapshot/restore for serial tests
//     (the Rust callers are `#[serial_test::serial]` because
//     `set_var`/`remove_var` are `unsafe` under concurrent access; the Swift
//     port enforces the same serialization via a global coordinator and is
//     deliberately NON-Sendable — see below).
//   * `grokBinary()` — resolve the `open-grok` binary: `GROK_BINARY` env
//     (CI) → `CARGO_BIN_EXE_open-grok` → local build.
//   * `gitWorkdir()` — temp directory with a git repo + one committed file.
//   * `applyTestEnv` — the canonical hermetic env for spawned subprocesses:
//     isolated HOME/USERPROFILE/OPENGROK_HOME, mock endpoints, telemetry
//     kill-switches, autoupdater disabled.
//
// All path-producing helpers refuse to return or operate on the real
// `~/.opengrok` via `HermeticEnv`.

import Foundation
import OpenGrokTestUtilities

/// RAII guard for a single environment variable in serial tests: snapshots
/// the prior value on construction, applies the change, then restores the
/// prior value (or unsets it) on `dispose` — even if an assertion throws.
///
/// Port of `xai-grok-test-support/src/env.rs::EnvGuard`. The Rust callers are
/// `#[serial_test::serial]` because `set_var`/`remove_var` are `unsafe` under
/// concurrent access. Swift `Foundation`'s `setenv`/`unsetenv` have the same
/// constraint, so this guard is **deliberately non-`Sendable`** and enforces
/// serialization through a global coordinator:
///
///   * Every live-process `EnvGuard` acquires the GLOBAL coordinator lock for
///     its whole lifetime (creation through `dispose`). The environment is
///     process-global, so the Rust contract requires globally serial
///     access — not per-key serialization. Two guards on DIFFERENT keys
///     therefore also serialize, matching `#[serial]` semantics for the
///     process environment as a whole.
///   * The lock is held across the guard's lifetime, not just individual
///     set/unset calls, so unrelated code cannot read or mutate the
///     environment between guarded operations.
///   * The guard is non-`Sendable`: it must live on the test thread that
///     created it. Swift Testing runs tests concurrently, so a guard that
///     crosses task boundaries would race. Use the guard only within a
///     single test function's synchronous scope and dispose it before
///     returning.
///
/// For tests that need environment mutation across spawned subprocesses
/// (the common case), prefer passing an explicit `environment:
/// [String: String]` to the child `Process` and avoid live-process
/// mutation entirely. `EnvGuard.snapshot` provides restore semantics for
/// such owned dictionaries without touching the live environment.
///
/// Because the guard holds a lock for its lifetime, dispose it promptly
/// (typically via `defer`). Forgetting to dispose will deadlock subsequent
/// tests that touch any environment variable.
public final class EnvGuard {
    /// The environment variable being guarded.
    public let key: String
    private let prior: String?
    private let isLiveProcessEnv: Bool

    /// Track whether `dispose()` has already run so that `deinit` does not
    /// double-restore and double-release the lock. The previous
    /// implementation had no disposed/restored state: `dispose()` restored
    /// and unlocked, then `deinit` restored and unlocked the same lock
    /// again. If another guard acquired the key between those events, the
    /// first guard's `deinit` could clobber the second guard's value and
    /// release its lock. This flag ensures restore-and-release happens
    /// exactly once.
    private var disposed: Bool = false

    /// Set `key` to `value` for the guard's lifetime, in the live process
    /// environment. Snapshots the prior value for restore.
    ///
    /// Blocks until any other `EnvGuard` on ANY key is disposed (the
    /// serial-test invariant: the environment is process-global). Use
    /// `defer` to dispose promptly.
    public static func set(_ key: String, _ value: String) -> EnvGuard {
        // Acquire the GLOBAL lock for the guard's whole lifetime so
        // overlapping guards on ANY key serialize. The environment is
        // process-global, so per-key serialization is insufficient —
        // concurrent setenv/unsetenv on different keys still races with
        // readers of the global environ.
        EnvGuardCoordinator.shared.acquireGlobal()
        let prior = ProcessInfo.processInfo.environment[key]
        setenv(key, value, 1)
        return EnvGuard(key: key, prior: prior, isLiveProcessEnv: true)
    }

    /// Unset `key` for the guard's lifetime, in the live process environment.
    ///
    /// Blocks until any other `EnvGuard` on ANY key is disposed (the
    /// serial-test invariant). Use `defer` to dispose promptly.
    public static func unset(_ key: String) -> EnvGuard {
        EnvGuardCoordinator.shared.acquireGlobal()
        let prior = ProcessInfo.processInfo.environment[key]
        unsetenv(key)
        return EnvGuard(key: key, prior: prior, isLiveProcessEnv: true)
    }

    /// Construct a guard that snapshots but does NOT mutate the live process
    /// env — used by helpers that want restore semantics for an
    /// `environment: [String: String]` dictionary they own. Does not take
    /// the coordinator lock (no live-process mutation occurs).
    public static func snapshot(_ key: String, in environment: [String: String]) -> EnvGuard {
        return EnvGuard(key: key, prior: environment[key], isLiveProcessEnv: false)
    }

    private init(key: String, prior: String?, isLiveProcessEnv: Bool) {
        self.key = key
        self.prior = prior
        self.isLiveProcessEnv = isLiveProcessEnv
    }

    /// Restore the prior value (or unset it). Idempotent. Safe to call from
    /// `defer`. Releases the global coordinator lock so a queued guard on
    /// any key can proceed.
    public func dispose() {
        guard isLiveProcessEnv, !disposed else { return }
        disposed = true
        if let prior {
            setenv(key, prior, 1)
        } else {
            unsetenv(key)
        }
        EnvGuardCoordinator.shared.releaseGlobal()
    }

    deinit {
        // Best-effort restore if the caller forgot `defer`. The
        // `disposed` flag ensures restore-and-release happens exactly once
        // even if `dispose()` was already called, so a guard that was
        // explicitly disposed does NOT re-restore or re-release the lock
        // (which would clobber a subsequent guard's value).
        if isLiveProcessEnv, !disposed {
            if let prior {
                setenv(key, prior, 1)
            } else {
                unsetenv(key)
            }
            EnvGuardCoordinator.shared.releaseGlobal()
        }
    }
}

/// Global coordinator serializing ALL `EnvGuard` mutations of the live
/// process environment. `@unchecked Sendable` via an internal global lock.
///
/// The environment is process-global (`environ`), so the Rust contract
/// requires globally serial access — not per-key serialization. The
/// previous per-key implementation allowed different tests to call
/// setenv/unsetenv concurrently for different keys, which races with any
/// reader of the global environment. This single global lock mirrors the
/// `#[serial_test::serial]` invariant: one live-process env mutation at a
/// time across the entire process.
private final class EnvGuardCoordinator: @unchecked Sendable {
    static let shared = EnvGuardCoordinator()
    private let globalLock = NSLock()

    fileprivate func acquireGlobal() {
        globalLock.lock()
    }

    fileprivate func releaseGlobal() {
        globalLock.unlock()
    }
}

/// Environment helpers for the Open Grok test support package.
public enum TestEnv {
    /// Env var naming the `open-grok` binary for CI lifecycle tests
    /// (`GROK_BINARY` in the Rust reference).
    public static let grokBinaryEnv = "GROK_BINARY"

    /// Env var naming the cargo-built `open-grok` binary
    /// (`CARGO_BIN_EXE_open-grok`).
    public static let cargoBinExeEnv = "CARGO_BIN_EXE_open-grok"

    /// Env var naming the leader-electing binary in a two-binary test
    /// (`GROK_BINARY_LEADER`).
    public static let leaderBinaryEnv = "GROK_BINARY_LEADER"

    /// Env var naming the client binary in a two-binary test
    /// (`GROK_BINARY_CLIENT`).
    public static let clientBinaryEnv = "GROK_BINARY_CLIENT"

    /// Resolve the `open-grok` binary path: `GROK_BINARY` env (CI) →
    /// `CARGO_BIN_EXE_open-grok` env → a local build under `.build/debug/`.
    /// Throws if `GROK_BINARY` is set but the path does not exist.
    public static func grokBinary(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        if let path = environment[grokBinaryEnv], !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw TestEnvError.binaryNotFound(envVar: grokBinaryEnv, path: url.path)
            }
            return url
        }
        if let path = environment[cargoBinExeEnv], !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        // Fall back to a SwiftPM local build under `.build/<arch>/debug/open-grok`.
        // The Swift port's executable product is `open-grok`.
        let packageRoot = Self.packageRoot(environment: environment)
        let candidate = packageRoot
            .appendingPathComponent(".build")
            .appendingPathComponent("debug")
            .appendingPathComponent("open-grok")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        // The SwiftPM `Executable` product may also live under
        // `.build/arm64-apple-macosx/debug/open-grok` etc.
        let productsDir = packageRoot.appendingPathComponent(".build").appendingPathComponent("debug")
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: productsDir.path) {
            for entry in entries where entry.hasPrefix("open-grok") {
                let candidate = productsDir.appendingPathComponent(entry)
                if (candidate.pathExtension.isEmpty) {
                    return candidate
                }
            }
        }
        throw TestEnvError.binaryNotFound(envVar: grokBinaryEnv, path: "(local build at \(candidate.path))")
    }

    /// Resolve the binary for `role` (`leader` / `client`) in a two-binary
    /// version-skew test, falling back to `grokBinary()`.
    public static func roleBinary(
        role: String,
        envVar: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        if let path = environment[envVar], !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw TestEnvError.binaryNotFound(envVar: envVar, path: url.path)
            }
            return url
        }
        return try grokBinary(environment: environment)
    }

    /// Create a temp directory with a git repo + one committed file. Forces
    /// a full `git init` (the codepath that breaks with bad git linking on
    /// some CI hosts). The repo is created inside a `HermeticEnv` so the
    /// git process never touches the developer's real `~/.opengrok` or
    /// global git config.
    public static func gitWorkdir(
        realHome: RealOpengrokHome = RealOpengrokHome(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> (HermeticEnv, URL) {
        var env = try HermeticEnv(realHome: realHome, inherit: environment)
        let repoPath = env.root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repoPath, withIntermediateDirectories: true)
        let gitEnv = HermeticGit.baseGitEnvironment(environment: env.environment)
        try HermeticGit.initGitRepo(at: repoPath, environment: gitEnv)
        let readme = repoPath.appendingPathComponent("README.md")
        try env.writeString("test file\n", to: readme)
        try HermeticGit.runGit(in: repoPath, arguments: ["add", "-A"], environment: gitEnv)
        try HermeticGit.runGit(in: repoPath, arguments: ["commit", "-m", "init", "--no-gpg-sign"], environment: gitEnv)
        return (env, repoPath)
    }

    /// Apply the canonical hermetic test env to `process`: isolated
    /// HOME/USERPROFILE/OPENGROK_HOME, mock endpoints, telemetry
    /// kill-switches, autoupdater disabled. Mirrors `test_env_cmd_tokio`.
    ///
    /// `hermetic` provides the isolated HOME/USERPROFILE/OPENGROK_HOME (and
    /// the refusal guard against the real `~/.opengrok`). `mockURL` is the
    /// base URL of a `MockInferenceServer`. The API keys are stripped so a
    /// developer's exported key never leaks into a spawned child.
    public static func applyTestEnv(
        to process: Process,
        hermetic: HermeticEnv,
        mockURL: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        var env = hermetic.environment
        // Strip inherited provider API keys so a developer's exported key
        // never leaks into a spawned child (mirrors the Rust kill-list).
        for key in ["MOONSHOT_API_KEY", "KIMI_CODE_API_KEY", "KIMI_API_KEY", "OPENAI_API_KEY"] {
            env.removeValue(forKey: key)
        }
        env["GROK_CLI_CHAT_PROXY_BASE_URL"] = mockURL
        env["GROK_XAI_API_BASE_URL"] = mockURL
        env["XAI_API_KEY"] = "test-key-for-ci"
        // Telemetry/feedback/trace/instrumentation kill-switches are already
        // in hermetic.environment; keep them.
        process.environment = env
    }

    /// The package root, derived from this file's location at runtime so the
    /// helper is independent of the working directory SwiftPM chooses.
    public static func packageRoot(environment: [String: String]) -> URL {
        // Walk up from #filePath to find Package.swift.
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while url.path != "/" && !FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
            url = url.deletingLastPathComponent()
        }
        return url
    }
}

/// Errors thrown by `TestEnv`.
public enum TestEnvError: Error, Equatable, CustomStringConvertible {
    case binaryNotFound(envVar: String, path: String)

    public var description: String {
        switch self {
        case let .binaryNotFound(envVar, path):
            return "Open Grok binary not found via \(envVar) at \(path)."
        }
    }
}
