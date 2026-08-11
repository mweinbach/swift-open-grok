// Shell.swift
//
// Port of `xai-grok-config/src/shell.rs`.
//
// Cross-platform shell detection: Unix shell path resolution (bash/zsh) and
// Windows shell detection (pwsh / powershell / Git Bash / cmd). The Unix
// cascade mirrors the Rust reference:
//
//   1. `$GROK_SHELL` override, if it names the requested kind and is runnable.
//   2. `$SHELL`, if it names the requested kind and is runnable.
//   3. `which(name)` — walks `$PATH`.
//   4. A fixed candidate list: `{/bin, /usr/bin, /usr/local/bin,
//      /opt/homebrew/bin} × {bash,zsh}`.
//   5. Hardcoded `/bin/<name>` — historical behavior, only reached when every
//      earlier step has failed.
//
// The result is cached per kind for the process lifetime.
//
// Windows shell detection requires `xai-tty-utils::detach_std_command` (W2-S4
// `OpenGrokTTY`) to detach the `where` probe from the controlling TTY. Since
// `OpenGrokConfig` cannot depend on W2-S4, the Windows shell detection is
// stubbed here: `detectWindowsShell` returns `.powerShell` (the Rust fallback)
// on Windows, and the Unix shell path resolution is fully implemented on
// Unix. W2-S4 (or a later integration slice) may consolidate by adding the
// `OpenGrokTTY` edge to `OpenGrokConfig` and re-implementing the Windows
// probe. The Windows shell command-line shape (`ampersandSemantics`,
// `chainSeparator` on Windows) is still defined here as pure data so callers
// that know their shell kind can use it.
//
// `isCommandAvailable` uses FileManager checks rather than the Rust
// `which::which` crate. The production resolver covers PATH on Unix and
// PATH/PATHEXT on Windows; Windows App Execution Aliases remain delegated to
// the operating system when commands are spawned.

import Foundation
import OpenGrokConfigTypes

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Unix shell kind

/// Which Unix shell we're asking about. Bash and zsh are the only kinds
/// supported by the persistent shell-state backend (the dump scripts are
/// bash/zsh-specific). Fish / dash / ksh users fall through to bash.
public enum UnixShellKind: Sendable, Equatable, Hashable {
    case bash
    case zsh

    /// Binary file name (`"bash"` / `"zsh"`).
    public var name: String {
        switch self {
        case .bash: return "bash"
        case .zsh: return "zsh"
        }
    }

    /// Hardcoded historical default. Only used as the last-resort fallback.
    var hardcodedDefault: String {
        switch self {
        case .bash: return "/bin/bash"
        case .zsh: return "/bin/zsh"
        }
    }
}

/// Detect the user's preferred Unix shell kind from `$SHELL`. Defaults to
/// `Bash` when `$SHELL` is unset or unrecognized. Cheap; not cached.
public func detectUnixShellKind(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> UnixShellKind {
    if let s = environment["SHELL"], s.contains("zsh") { return .zsh }
    return .bash
}

// MARK: - Unix shell path resolution

/// Per-kind cache for `unixShellPath`. Holds the resolved path string so
/// repeated calls return the same value (pointer-equal in the Rust reference;
/// here we return a fresh `String` per call but the value is the same).
private let unixShellCache: UnixShellCache = UnixShellCache()

private final class UnixShellCache: @unchecked Sendable {
    private let lock = NSLock()
    private var bash: String?
    private var zsh: String?
    func get(_ kind: UnixShellKind) -> String? {
        lock.lock(); defer { lock.unlock() }
        switch kind {
        case .bash: return bash
        case .zsh: return zsh
        }
    }
    func set(_ kind: UnixShellKind, _ value: String) {
        lock.lock(); defer { lock.unlock() }
        switch kind {
        case .bash: bash = value
        case .zsh: zsh = value
        }
    }
}

/// Absolute path to the requested Unix shell binary, computed via the cascade
/// above. Cached for the process lifetime.
public func unixShellPath(
    _ kind: UnixShellKind,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> String {
    if let cached = unixShellCache.get(kind) { return cached }
    let resolved = resolveUnixShellPath(kind, environment: environment)
    unixShellCache.set(kind, resolved)
    return resolved
}

/// Pure resolver (no caching). Used by `unixShellPath` and tests.
func resolveUnixShellPath(
    _ kind: UnixShellKind,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> String {
    let name = kind.name
    let matchesKind: (String) -> Bool = { path in
        URL(fileURLWithPath: path).lastPathComponent == name
    }

    // 1) Explicit override via $GROK_SHELL.
    if let s = environment["GROK_SHELL"] {
        if matchesKind(s) && isExecutable(URL(fileURLWithPath: s)) {
            return s
        }
    }

    // 2) $SHELL, when it matches the requested kind.
    if let s = environment["SHELL"] {
        if matchesKind(s) && isExecutable(URL(fileURLWithPath: s)) {
            return s
        }
    }

    // 3) `which` walks $PATH (handles NixOS, Homebrew, custom profiles).
    if let p = which(name, environment: environment) {
        if isExecutable(URL(fileURLWithPath: p)) {
            return p
        }
    }

    // 4) Common install dirs.
    for dir in ["/bin", "/usr/bin", "/usr/local/bin", "/opt/homebrew/bin"] {
        let p = URL(fileURLWithPath: dir).appendingPathComponent(name)
        if isExecutable(p) {
            return p.path
        }
    }

    // 5) Hardcoded fallback — same as historical behavior. Spawn will fail at
    //    runtime on a pure NixOS host with no bash, but that's no worse than
    //    before this resolver existed.
    return kind.hardcodedDefault
}

/// Whether `path` is an executable file. First tries the file's mode bits
/// (any-x). The `--version` fallback in the Rust reference is omitted here
/// (it requires `xai-tty-utils::detach_std_command` to avoid leaking escapes
/// onto the parent TTY during interactive pager startup); the mode-bit check
/// is sufficient on every mainstream Unix filesystem.
func isExecutable(_ path: URL) -> Bool {
    #if canImport(Darwin) || canImport(Glibc)
    guard FileManager.default.fileExists(atPath: path.path) else { return false }
    guard FileManager.default.isReadableFile(atPath: path.path) else { return false }
    var st = stat()
    let result = path.path.withCString { stat($0, &st) }
    if result != 0 { return false }
    // S_IFMT & S_IFREG → regular file; any-x bit → executable.
    let isRegular = (Int32(st.st_mode) & 0o170000) == 0o100000
    let anyX = (Int32(st.st_mode) & 0o111) != 0
    return isRegular && anyX
    #else
    // Windows: Foundation's `isExecutableFile` doesn't expose a per-file
    // executable bit; treat any existing file as executable.
    return FileManager.default.fileExists(atPath: path.path)
    #endif
}

enum ExecutableSearchPlatform: Sendable, Equatable {
    case posix
    case windows

    static var current: Self {
        #if os(Windows)
        return .windows
        #else
        return .posix
        #endif
    }

    var pathSeparator: Character {
        switch self {
        case .posix: return ":"
        case .windows: return ";"
        }
    }

    func pathValue(environment: [String: String]) -> String? {
        switch self {
        case .posix:
            return environment["PATH"]
        case .windows:
            return environment["PATH"] ?? environment["Path"]
        }
    }

    func executableSuffixes(name: String, environment: [String: String]) -> [String] {
        guard self == .windows else { return [""] }
        let pathExt = environment["PATHEXT"] ?? ".EXE;.CMD;.BAT"
        let suffixes = pathExt.split(separator: ";").map(String.init)
        guard !suffixes.isEmpty else { return [""] }
        if suffixes.contains(where: { name.lowercased().hasSuffix($0.lowercased()) }) {
            return [""]
        }
        return suffixes
    }

    func appendingPathComponent(_ component: String, to directory: String) -> String {
        switch self {
        case .posix:
            return URL(fileURLWithPath: directory).appendingPathComponent(component).path
        case .windows:
            if directory.hasSuffix("\\") || directory.hasSuffix("/") {
                return directory + component
            }
            return directory + "\\" + component
        }
    }
}

/// Locate `name` on `$PATH`. Returns the first matching executable, or `nil`.
/// Mirrors the Rust `which::which(name)` behavior used by the live command
/// availability seam, including ordered PATHEXT lookup on Windows.
func which(
    _ name: String,
    environment: [String: String],
    platform: ExecutableSearchPlatform = .current,
    isExecutableFile: (String) -> Bool = { isExecutable(URL(fileURLWithPath: $0)) }
) -> String? {
    guard let path = platform.pathValue(environment: environment) else { return nil }
    let suffixes = platform.executableSuffixes(name: name, environment: environment)
    for directory in path.split(separator: platform.pathSeparator, omittingEmptySubsequences: true) {
        for suffix in suffixes {
            let candidate = platform.appendingPathComponent(name + suffix, to: String(directory))
            if isExecutableFile(candidate) {
                return candidate
            }
        }
    }
    return nil
}

// MARK: - Windows shell (stubbed; see module doc)

/// Detected Windows shell and how to invoke it.
public enum WindowsShell: Sendable, Equatable {
    case gitBash(String)
    case pwsh
    case powerShell
    case cmd
}

/// Detect the best available shell on Windows.
///
/// **Stubbed on non-Windows** (returns `nil`). On Windows, returns
/// `WindowsShell.powerShell` (the Rust fallback) without probing for pwsh or
/// Git Bash. The probe requires `xai-tty-utils::detach_std_command`
/// (W2-S4 `OpenGrokTTY`); W2-S4 or a later integration slice may add the
/// `OpenGrokTTY` edge and re-implement the cascade.
public func detectWindowsShell(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> WindowsShell? {
    #if os(Windows)
    // Honor an explicit $GROK_SHELL override without a TTY-detached probe.
    if let val = environment["GROK_SHELL"] {
        switch val.trimmingCharacters(in: .whitespaces).lowercased() {
        case "pwsh": return .pwsh
        case "powershell": return .powerShell
        case "cmd", "cmd.exe": return .cmd
        case "bash", "gitbash", "git-bash":
            // Without a probe, return the canonical Git Bash install path
            // (the Rust `find_git_bash` candidates list). If none exists the
            // caller will fail at spawn time, no worse than the Rust path
            // when no Git Bash is installed.
            if let pf = environment["PROGRAMFILES"],
               FileManager.default.fileExists(atPath: "\(pf)\\Git\\bin\\bash.exe") {
                return .gitBash("\(pf)\\Git\\bin\\bash.exe")
            }
            return .powerShell
        default:
            return .powerShell
        }
    }
    return .powerShell
    #else
    return nil
    #endif
}

extension WindowsShell {
    /// Short display name for user-facing contexts (e.g. "bash", "pwsh").
    public var name: String {
        switch self {
        case .gitBash: return "bash"
        case .pwsh: return "pwsh"
        case .powerShell: return "powershell"
        case .cmd: return "cmd.exe"
        }
    }

    /// Whether this shell supports the `&&` pipeline chain operator for
    /// error-propagating command chaining.
    public var supportsChainOperator: Bool {
        switch self {
        case .pwsh, .gitBash: return true
        case .powerShell, .cmd: return false
        }
    }

    /// Whether `grep`, `head`, `tail`, `sed`, `awk`, `find` are usable from
    /// this shell. True for Git Bash (MSYS2 bundles them); false for
    /// PowerShell and `cmd.exe`.
    public var hasUnixUtilities: Bool {
        if case .gitBash = self { return true }
        return false
    }

    /// How this shell interprets a bare `&` token.
    public var ampersandSemantics: AmpersandSemantics {
        switch self {
        case .gitBash: return .posixBackground
        case .pwsh: return .powerShellCore
        case .powerShell: return .windowsPowerShell
        case .cmd: return .cmdSeparator
        }
    }
}

// MARK: - AmpersandSemantics

/// How a shell interprets a bare `&` token. Drives `run_terminal_cmd`
/// background-operator detection and remediation, which must differ per shell.
public enum AmpersandSemantics: Sendable, Equatable, Hashable {
    /// Bash/POSIX: a bare `&` backgrounds the command (Unix shells, Git Bash).
    case posixBackground
    /// PowerShell 7+ (`pwsh`): a *leading* `&` is the call/invocation operator;
    /// a *trailing* `&` starts a background job.
    case powerShellCore
    /// Windows PowerShell 5.1 (`powershell.exe`): a *leading* `&` is the call
    /// operator; a *trailing* `&` is a parse error.
    case windowsPowerShell
    /// `cmd.exe`: `&` is an unconditional sequential command separator.
    case cmdSeparator
}

// MARK: - Cross-platform shell helpers

/// Returns the appropriate command chaining separator for the current
/// platform and detected shell.
///
/// - Unix: always `"&&"` (bash/zsh).
/// - Windows with pwsh or Git Bash: `"&&"` (both support pipeline chain
///   operators).
/// - Windows with powershell.exe (5.1) or cmd.exe: `";"`.
public func chainSeparator(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> String {
    #if os(Windows)
    if let shell = detectWindowsShell(environment: environment), shell.supportsChainOperator {
        return "&&"
    }
    return ";"
    #else
    return "&&"
    #endif
}

/// Whether `grep`, `head`, `tail`, `sed`, `awk`, `find` are usable from the
/// active shell. True on Unix and Windows + Git Bash; false on Windows +
/// PowerShell or `cmd.exe`.
public func hasUnixUtilities(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> Bool {
    #if os(Windows)
    return detectWindowsShell(environment: environment)?.hasUnixUtilities ?? false
    #else
    return true
    #endif
}

/// Whether `name` resolves to an executable on the current `$PATH`.
///
/// Probes the base environment (tool server is co-located with the shell tool
/// in production). Per-session `export PATH` mutations inside the persistent
/// shell are not reflected (uncommon for `jq`/`python`/`sed`/`cut`).
public func isCommandAvailable(
    _ name: String,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> Bool {
    return which(name, environment: environment) != nil
}

/// The resolved absolute path of `name` on `$PATH`, or `nil`.
///
/// The public counterpart to `isCommandAvailable` for callers that must hand a
/// concrete path to `Process.executableURL` — `/usr/bin/env` is not available
/// on Windows, so a spawner that needs PATH resolution cannot delegate it to
/// the OS the way a POSIX-only one can.
public func resolveExecutablePath(
    _ name: String,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> String? {
    which(name, environment: environment)
}

func isCommandAvailable(
    _ name: String,
    environment: [String: String],
    platform: ExecutableSearchPlatform,
    isExecutableFile: (String) -> Bool
) -> Bool {
    which(
        name,
        environment: environment,
        platform: platform,
        isExecutableFile: isExecutableFile
    ) != nil
}

/// How the active shell interprets a bare `&`. Unix shells are always
/// `posixBackground`; on Windows it depends on the detected shell.
public func ampersandSemantics(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> AmpersandSemantics {
    #if os(Windows)
    return detectWindowsShell(environment: environment)?.ampersandSemantics ?? .cmdSeparator
    #else
    return .posixBackground
    #endif
}
