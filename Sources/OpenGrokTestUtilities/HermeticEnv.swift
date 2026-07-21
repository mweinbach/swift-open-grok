// HermeticEnv.swift
//
// Central hermetic-environment primitive for Open Grok's Swift test suite.
// Ports and consolidates the environment-isolation behavior scattered through
// the Rust reference (`xai-grok-test-support/src/env.rs::test_env_cmd_tokio`,
// `xai-grok-pager-pty-harness/src/content.rs::env_for_pager`,
// `xai-grok-test-support/src/leader.rs::spawn`, and the `~/.opengrok` refusal
// invariant threaded through every Rust helper).
//
// W0-S2 acceptance: every test helper creates isolated HOME, USERPROFILE, and
// OPENGROK_HOME directories and refuses paths resolving to the real
// `~/.opengrok`. `HermeticEnv` is the single source of truth for that
// invariant — every other helper in this module and in `OpenGrokTestSupport`
// either returns a `HermeticEnv` or accepts one and never reads the real
// `~/.opengrok`.

import Foundation

/// Errors thrown when a test helper is asked to operate on a path that would
/// break hermeticity.
public enum HermeticEnvError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The candidate path resolves to the developer's real `~/.opengrok` or
    /// to a path beneath it.
    ///
    /// Tests must never read or write the real state directory: a poisoned
    /// `models_cache.json`, auth token, or session there would leak across
    /// tests and across developers on a shared CI host.
    case realOpengrokHomeRefused(realPath: String, candidatePath: String)

    /// `OPENGROK_HOME` was inherited from the ambient environment rather than
    /// set explicitly by the test. Refused so a developer's `OPENGROK_HOME`
    /// export can never silently point a test at their real state directory.
    case inheritedOpengrokHomeNotOverridden(inheritedPath: String)

    /// A temp directory could not be created.
    case tempDirectoryCreationFailed(underlying: String)

    public var description: String {
        switch self {
        case let .realOpengrokHomeRefused(realPath, candidatePath):
            return "Refused path \(candidatePath) because it resolves to the real ~/.opengrok at \(realPath)."
        case let .inheritedOpengrokHomeNotOverridden(path):
            return "Refused inherited OPENGROK_HOME=\(path); tests must override it with an isolated temp dir."
        case let .tempDirectoryCreationFailed(underlying):
            return "Failed to create hermetic temp directory: \(underlying)"
        }
    }
}

/// A snapshot of the developer's *real* Open Grok state directory, captured
/// once at process start before any test mutates the environment.
///
/// This is the path the hermeticity guard refuses to touch. It is computed
/// from the real user home directory (Foundation's
/// `homeDirectoryForCurrentUser`), NOT from `HOME`/`USERPROFILE`, because
/// tests override those to point at temp dirs — using the overridden values
/// would make the guard a no-op.
public struct RealOpengrokHome: Sendable, Equatable {
    /// The absolute, standardized path to the developer's real `~/.opengrok`.
    public let path: String

    /// The user home directory `path` is relative to.
    public let userHome: String

    /// Capture the real `~/.opengrok` from Foundation's home-for-current-user
    /// resolver. This is process-stable and independent of `HOME` overrides.
    public init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
            .standardizedFileURL.path
        self.userHome = home
        self.path = (home as NSString).appendingPathComponent(".opengrok")
    }

    /// Explicit construction for tests of the guard itself.
    public init(userHome: String, opengrokHome: String) {
        self.userHome = userHome
        self.path = opengrokHome
    }
}

/// A hermetic test environment: an isolated temp directory plus the
/// `HOME` / `USERPROFILE` / `OPENGROK_HOME` environment entries that point at
/// it.
///
/// Behavior preserved from the Rust reference (`xai-grok-test-support/src/env.rs`):
///   * `HOME` is set to the temp root (POSIX home).
///   * `USERPROFILE` is set to the temp root (Windows resolves `~` via Known
///     Folders / `USERPROFILE`; without it, every spawned child shares the
///     real `%USERPROFILE%\.opengrok` — the windows-x86_64 lifecycle
///     "prompt timed out" failure documented in the Rust source).
///   * `OPENGROK_HOME` is set to `<tempRoot>/.opengrok` so the product never
///     reads or writes the developer's real `~/.opengrok`.
///
/// `Drop`-style cleanup is provided by `dispose()`: callers (typically
/// `defer` in a test) remove the temp tree. `HermeticEnv` is a value type
/// wrapping a class-owned temp directory so it can be `Sendable` and shared
/// across tasks without races on the directory handle.
public struct HermeticEnv: Sendable {
    /// The temp root that `HOME` / `USERPROFILE` point at.
    public let root: URL

    /// The isolated `OPENGROK_HOME` (`<root>/.opengrok`).
    public let opengrokHome: URL

    /// The environment dictionary to pass to a spawned `Process` / child actor.
    public let environment: [String: String]

    /// The real `~/.opengrok` this env refuses to touch.
    public let realHome: RealOpengrokHome

    /// The owned temp directory; removed when `dispose()` is called.
    private let storage: TempStorage

    /// Construct a fresh hermetic env under a unique temp root.
    ///
    /// - Parameters:
    ///   - realHome: The real `~/.opengrok` to refuse. Defaults to a snapshot
    ///     captured at process start.
    ///   - baseDirectory: The base under which the unique temp root is
    ///     created. Defaults to the system temp directory.
    ///   - prefix: The temp directory name prefix.
    ///   - inherit: Optional ambient environment to inherit non-isolation
    ///     variables (e.g. `PATH`) from. `HOME`, `USERPROFILE`, and
    ///     `OPENGROK_HOME` are ALWAYS overwritten and never inherited. If
    ///     `inherit` carries `OPENGROK_HOME`, the env is still safe (the
    ///     isolated value wins) — the refusal only fires when a CALLER tries
    ///     to pass a path that resolves to `realHome`.
    public init(
        realHome: RealOpengrokHome = RealOpengrokHome(),
        baseDirectory: URL? = nil,
        prefix: String = "opengrok-test",
        inherit: [String: String]? = nil
    ) throws {
        self.realHome = realHome
        let base = baseDirectory ?? Self.systemTempRoot()
        let storage = try TempStorage.createUnique(
            base: base,
            prefix: prefix,
            realHome: realHome
        )
        self.storage = storage
        self.root = storage.rootURL
        self.opengrokHome = storage.rootURL.appendingPathComponent(".opengrok")

        // The OPENGROK_HOME directory is created eagerly so that tests reading
        // it (e.g. for cache invalidation) do not race a lazy writer. The
        // containment-aware guard below rejects the real `~/.opengrok` and
        // every path beneath it.
        try Self.ensureDirectory(self.opengrokHome, realHome: realHome)

        var env = inherit ?? [:]
        // Isolation overrides — always win, never inherited.
        env["HOME"] = root.path
        env["USERPROFILE"] = root.path
        env["OPENGROK_HOME"] = opengrokHome.path
        // Telemetry/feedback kill-switches mirror `test_env_cmd_tokio` so any
        // child that *does* run (a real `open-grok` binary in later waves)
        // never phones home from a test.
        env["GROK_TELEMETRY_ENABLED"] = "false"
        env["GROK_FEEDBACK_ENABLED"] = "false"
        env["GROK_TRACE_UPLOAD"] = "false"
        env["GROK_INSTRUMENTATION"] = "disabled"
        env["GROK_DISABLE_AUTOUPDATER"] = "1"
        self.environment = env
    }

    /// The system temp directory (cross-platform).
    public static func systemTempRoot() -> URL {
        let nsTemp = NSTemporaryDirectory()
        return URL(fileURLWithPath: nsTemp, isDirectory: true)
    }

    /// Remove the temp tree. Idempotent. Safe to call from `defer`.
    public mutating func dispose() {
        storage.dispose()
    }

    /// Returns `true` if `candidate` resolves to the real `~/.opengrok` or
    /// to a path beneath it.
    ///
    /// Resolution walks the candidate path component-by-component, resolving
    /// symlinks for each ancestor that exists on disk (Foundation's
    /// `resolvingSymlinksInPath` only resolves the leaf when the file exists;
    /// we walk ancestors so a symlinked directory containing the real home
    /// is caught even when the final path does not yet exist). This mirrors
    /// the Rust `std::path::Path::canonicalize`-based containment check and
    /// its lexical fallback for non-existent paths.
    public func resolvesToRealHome(_ candidate: URL) -> Bool {
        return Self.pathResolvesToRealHome(candidate, realHome: realHome)
    }

    /// Throw `realOpengrokHomeRefused` if `candidate` resolves to the real
    /// `~/.opengrok` or to a path beneath it. Every helper that accepts a
    /// path parameter calls this before touching the filesystem.
    public func refuseIfReal(_ candidate: URL) throws {
        if resolvesToRealHome(candidate) {
            throw HermeticEnvError.realOpengrokHomeRefused(
                realPath: realHome.path,
                candidatePath: candidate.path
            )
        }
    }

    /// Resolve `OPENGROK_HOME` from an environment dictionary using the same
    /// precedence as `OpenGrokHomeResolver` (W0-S3): `OPENGROK_HOME` wins,
    /// then `<HOME>/.opengrok`, then `<USERPROFILE>/.opengrok`, then the
    /// Foundation home. Returns the resolved URL.
    public static func resolveOpengrokHome(environment: [String: String]) -> URL {
        if let override = environment["OPENGROK_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let home: URL
        if let h = environment["HOME"], !h.isEmpty {
            home = URL(fileURLWithPath: h)
        } else if let p = environment["USERPROFILE"], !p.isEmpty {
            home = URL(fileURLWithPath: p)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser
        }
        return home.appendingPathComponent(".opengrok")
    }

    /// Create `url` if missing, refusing first if it resolves to the real
    /// `~/.opengrok` or to a path beneath it.
    public func ensureDirectory(_ url: URL) throws {
        try refuseIfReal(url)
        try Self.ensureDirectory(url, realHome: realHome)
    }

    /// Write `data` to `url`, refusing first if it resolves to the real
    /// `~/.opengrok` or to a path beneath it. Creates parent directories as
    /// needed (each parent is also refused).
    public func write(_ data: Data, to url: URL) throws {
        try refuseIfReal(url)
        let parent = url.deletingLastPathComponent()
        try Self.ensureDirectory(parent, realHome: realHome)
        try data.write(to: url, options: .atomic)
    }

    /// Write a UTF-8 string to `url`, refusing first if it resolves to the
    /// real `~/.opengrok` or to a path beneath it.
    public func writeString(_ string: String, to url: URL) throws {
        try write(Data(string.utf8), to: url)
    }

    // MARK: - Internal helpers

    /// Containment-aware, symlink-resolving guard. Rejects the real home
    /// itself and every path beneath it. Walks each ancestor of `url` that
    /// exists on disk and resolves its symlinks; for ancestors that do not
    /// yet exist (e.g. a not-yet-created descendant), falls back to lexical
    /// standardization. This catches both direct paths (`/real/.opengrok`)
    /// and descendants (`/real/.opengrok/subdir/cache.json`), as well as
    /// symlink aliases (`/tmp/alias → /real/.opengrok`).
    ///
    /// Used as the single guard before every filesystem operation so all
    /// helpers share one refusal invariant.
    static func pathResolvesToRealHome(_ candidate: URL, realHome: RealOpengrokHome) -> Bool {
        // Resolve the real home itself as far as the filesystem allows, then
        // fall back to lexical standardization. The real home almost always
        // exists (it is the developer's state dir), but tests of the guard
        // construct synthetic `RealOpengrokHome` values pointing at
        // non-existent paths, so the lexical fallback matters.
        let realResolved = Self.resolveAsFarAsExists(URL(fileURLWithPath: realHome.path))
        let realStandardized = realResolved.standardizedFileURL.path

        // Resolve the candidate the same way, then check both exact equality
        // and containment (the candidate is the real home OR lives beneath it).
        let candidateResolved = Self.resolveAsFarAsExists(candidate)
        let candidateStandardized = candidateResolved.standardizedFileURL.path

        if candidateStandardized == realStandardized {
            return true
        }
        // Containment: candidate begins with `<realStandardized>/`. We use a
        // path-component-aware prefix check (string `hasPrefix` would treat
        // `/tmp/og-real-bad` as beneath `/tmp/og-real`, which it is not).
        let realWithSlash = realStandardized.hasSuffix("/") ? realStandardized : realStandardized + "/"
        if candidateStandardized.hasPrefix(realWithSlash) {
            return true
        }
        return false
    }

    /// Resolve symlinks for `url` as far as the filesystem currently allows.
    ///
    /// Foundation's `URL.resolvingSymlinksInPath()` only resolves the *leaf*
    /// and only if the leaf itself exists; for partial paths or
    /// intermediate-directory symlinks it leaves the URL unchanged. To match
    /// the Rust `Path::canonicalize`-with-fallback containment behavior, we
    /// walk ancestors rootward, canonicalizing each existing ancestor and
    /// appending the remaining leaf components lexically. This catches a
    /// symlinked directory that points at the real `~/.opengrok` even when
    /// the final path does not yet exist.
    static func resolveAsFarAsExists(_ url: URL) -> URL {
        let fm = FileManager.default
        // First, try a full canonicalization — fast path when the entire
        // path exists on disk.
        let canonical = url.resolvingSymlinksInPath()
        // `resolvingSymlinksInPath` returns the input unchanged when the
        // leaf does not exist; distinguish by checking existence.
        if fm.fileExists(atPath: canonical.path) {
            return canonical
        }
        // Walk rootward from the leaf, finding the longest existing prefix.
        // Foundation path helpers operate on `URL` components; collect them.
        var components: [String] = []
        var current: URL = url.standardizedFileURL
        while current.path != "/" && !current.path.isEmpty {
            components.insert(current.lastPathComponent, at: 0)
            current = current.deletingLastPathComponent()
        }
        // `current` is now the root ("/" or the volume root). Re-build the
        // path component by component, canonicalizing once we hit a
        // component whose ancestor exists on disk.
        var resolved = current
        var stopCanonicalizing = false
        for component in components {
            let next = resolved.appendingPathComponent(component)
            if stopCanonicalizing {
                resolved = next
                continue
            }
            if fm.fileExists(atPath: next.path) {
                // Resolve symlinks at this depth; if Foundation cannot (e.g.
                // a symlink chain it does not chase), keep the lexical form.
                let canonical = next.resolvingSymlinksInPath()
                if fm.fileExists(atPath: canonical.path) {
                    resolved = canonical
                } else {
                    resolved = next
                }
            } else {
                // First non-existent component: from here on, append lexically.
                resolved = next
                stopCanonicalizing = true
            }
        }
        return resolved
    }

    /// Create `url` if missing, after running the containment-aware guard.
    /// This is the single filesystem-entry point used by every helper in
    /// this file.
    private static func ensureDirectory(_ url: URL, realHome: RealOpengrokHome) throws {
        if pathResolvesToRealHome(url, realHome: realHome) {
            throw HermeticEnvError.realOpengrokHomeRefused(
                realPath: realHome.path,
                candidatePath: url.path
            )
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

/// Owned temp directory storage. `Sendable` via a lock-protected disposition
/// flag; the directory itself is uniquely named and never shared across
/// `HermeticEnv` instances.
private final class TempStorage: @unchecked Sendable {
    let rootURL: URL
    private let lock = NSLock()
    private var disposed = false

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    static func createUnique(
        base: URL,
        prefix: String,
        realHome: RealOpengrokHome
    ) throws -> TempStorage {
        let fm = FileManager.default
        let unique = "\(prefix)-\(UUID().uuidString)"
        let root = base.appendingPathComponent(unique, isDirectory: true)
        // The containment-aware guard rejects not only the real home itself
        // but also any path beneath it. This catches the (unlikely) case
        // where the system temp dir resolves into the developer's
        // `~/.opengrok` via a symlink chain.
        if HermeticEnv.pathResolvesToRealHome(root, realHome: realHome) {
            throw HermeticEnvError.realOpengrokHomeRefused(
                realPath: realHome.path,
                candidatePath: root.path
            )
        }
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw HermeticEnvError.tempDirectoryCreationFailed(underlying: String(describing: error))
        }
        // Pin to 0700 on POSIX to keep other users on a shared CI host out.
        #if !os(Windows)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        #endif
        return TempStorage(rootURL: root)
    }

    func dispose() {
        lock.lock()
        defer { lock.unlock() }
        guard !disposed else { return }
        disposed = true
        try? FileManager.default.removeItem(at: rootURL)
    }

    deinit {
        // Best-effort cleanup if the owner forgot `defer env.dispose()`.
        dispose()
    }
}
