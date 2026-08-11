// Platform.swift
//
// Platform sandbox support probes and enforcement backends:
//   * macOS — Seatbelt (sandbox_init + SBPL)
//   * Linux — backend-honest bubblewrap capability probe + process re-exec
//   * Windows — restricted-token / Job Object (compile-checked unsupported)
//
// R15 acceptance: fail closed when a non-off mode cannot be enforced.

import Foundation

#if canImport(Darwin)
import Darwin
#endif

#if os(Linux)
import Glibc
#endif

// MARK: - Support probe

/// Result of probing OS sandbox capability.
public struct SandboxSupportInfo: Sendable, Equatable {
    public var isSupported: Bool
    public var backend: SandboxBackend
    public var details: String

    public init(isSupported: Bool, backend: SandboxBackend, details: String) {
        self.isSupported = isSupported
        self.backend = backend
        self.details = details
    }
}

/// Kernel / userspace sandbox backend.
public enum SandboxBackend: String, Sendable, Equatable, Codable {
    case none
    case macosSeatbelt = "macos/seatbelt"
    case linuxLandlock = "linux/landlock"
    case linuxBubblewrap = "linux/bubblewrap"
    case windowsRestrictedToken = "windows/restricted-token"
    case windowsJobObject = "windows/job-object"
}

public enum PlatformSandboxSupport {
    public static var platformLabel: String {
        #if os(macOS)
        return SandboxBackend.macosSeatbelt.rawValue
        #elseif os(Linux)
        return SandboxBackend.linuxLandlock.rawValue
        #elseif os(Windows)
        return SandboxBackend.windowsRestrictedToken.rawValue
        #else
        return SandboxBackend.none.rawValue
        #endif
    }

    /// Probe whether the current process can apply a real OS sandbox.
    public static func supportInfo(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SandboxSupportInfo {
        #if os(macOS)
        // sandbox_init is present on all supported macOS versions.
        return SandboxSupportInfo(
            isSupported: true,
            backend: .macosSeatbelt,
            details: "macOS Seatbelt (sandbox_init) available"
        )
        #elseif os(Linux)
        // A bwrap executable is launch availability, not current-process
        // enforcement. Only a process that re-entered with a process-owned
        // receipt may advertise restricted support to capability consumers.
        if isVerifiedInsideBwrap(environment: environment) {
            let bwrap = findBubblewrap(environment: environment)?.description ?? "bubblewrap"
            return SandboxSupportInfo(
                isSupported: true,
                backend: .linuxBubblewrap,
                details: "bubblewrap confinement verified in the current process (\(bwrap))"
            )
        }
        let bwrapAvailable = findBubblewrap(environment: environment) != nil
        let landlock = landlockSupported()
        return SandboxSupportInfo(
            isSupported: false,
            backend: .none,
            details: bwrapAvailable
                ? "Linux bubblewrap is available, but this process is not verified inside the re-exec; activation/re-exec is required"
                : landlock
                    ? "Linux Landlock is detectable but no implemented filesystem backend is available; activation/re-exec is required"
                    : "Linux process-wide sandbox activation is unavailable; bubblewrap re-exec is required"
        )
        #elseif os(Windows)
        // Restricted tokens / Job Objects exist but are not yet wired.
        return SandboxSupportInfo(
            isSupported: false,
            backend: .windowsRestrictedToken,
            details: "Windows restricted-token/Job Object enforcement is not yet implemented; fail closed"
        )
        #else
        return SandboxSupportInfo(
            isSupported: false,
            backend: .none,
            details: "no sandbox backend for this platform"
        )
        #endif
    }

    #if os(Linux)
    /// Landlock create_ruleset syscall number varies by arch; probe via
    /// `/sys/kernel/security/landlock` or a best-effort syscall attempt marker.
    private static func landlockSupported() -> Bool {
        // Landlock is advertised through the securityfs node when mounted.
        if FileManager.default.fileExists(atPath: "/sys/kernel/security/landlock") {
            return true
        }
        // Fallback: kernel version heuristic is intentionally avoided — prefer
        // explicit absence so we fail closed rather than optimistically claim support.
        return false
    }
    #endif
}

// MARK: - Seatbelt SBPL

/// Specific Seatbelt write sub-actions denied for a denied path.
public let seatbeltWriteDenyActions: [String] = [
    "file-write-data",
    "file-write-unlink",
    "file-write-create",
    "file-write-mode",
    "file-write-owner",
    "file-write-flags",
    "file-write-times",
    "file-write-setugid",
]

#if os(macOS)
/// Build a Seatbelt profile language (SBPL) string for the resolved profile.
public func buildSeatbeltProfile(_ resolved: ResolvedSandboxProfile, workspace: URL? = nil) -> String {
    var lines: [String] = [
        "(version 1)",
        "(deny default)",
        "(allow process*)",
        "(allow signal)",
        "(allow sysctl-read)",
        "(allow mach-lookup)",
        "(allow mach-register)",
        "(allow ipc-posix*)",
        "(allow system-socket)",
        "(allow file-ioctl)",
        // Device essentials
        "(allow file-read* file-write* file-ioctl (literal \"/dev/null\"))",
        "(allow file-read* file-write* file-ioctl (literal \"/dev/zero\"))",
        "(allow file-read* file-write* file-ioctl (literal \"/dev/random\"))",
        "(allow file-read* file-write* file-ioctl (literal \"/dev/urandom\"))",
        "(allow file-read* file-write* file-ioctl (literal \"/dev/tty\"))",
        "(allow file-read* file-write* file-ioctl (literal \"/dev/ptmx\"))",
    ]

    if resolved.defaultRead {
        lines.append("(allow file-read* (subpath \"/\"))")
    } else {
        for path in resolved.readOnly {
            let escaped = seatbeltEscape(path.path)
            lines.append("(allow file-read* (subpath \"\(escaped)\"))")
        }
    }

    for path in resolved.readWrite {
        let escaped = seatbeltEscape(path.path)
        lines.append("(allow file-read* file-write* (subpath \"\(escaped)\"))")
    }

    // Exact deny paths with macOS firmlink alias expansion and write sub-actions
    for path in resolved.deny {
        let aliases = macosDenyAliases(path)
        for alias in aliases {
            let escaped = seatbeltEscape(alias.path)
            let filter = denyPathIsDir(alias) ? "(subpath \"\(escaped)\")" : "(literal \"\(escaped)\")"
            lines.append("(deny file-read* \(filter))")
            lines.append("(deny file-write* \(filter))")
            for action in seatbeltWriteDenyActions {
                lines.append("(deny \(action) \(filter))")
            }
        }
    }

    // Glob deny entries as regexes covering all firmlink root aliases and write sub-actions
    let ws = workspace ?? URL(fileURLWithPath: "/")
    for entry in resolved.denyEntries where isGlobPattern(entry) {
        if let regexes = try? globToSeatbeltRegexes(workspace: ws, glob: entry) {
            for regex in regexes {
                let filter = "(regex #\"\(regex)\"#)"
                lines.append("(deny file-read* \(filter))")
                lines.append("(deny file-write* \(filter))")
                for action in seatbeltWriteDenyActions {
                    lines.append("(deny \(action) \(filter))")
                }
            }
        }
    }

    // Keep provider/LLM traffic available in the agent process. Network
    // restriction is enforced at known Linux child launches instead.
    lines.append("(allow network*)")

    return lines.joined(separator: "\n")
}
#else
/// Build a Seatbelt profile language (SBPL) string for the resolved profile.
/// On non-macOS platforms, returns an explicit unsupported profile string.
public func buildSeatbeltProfile(_ resolved: ResolvedSandboxProfile, workspace: URL? = nil) -> String {
    _ = resolved
    _ = workspace
    return "; Seatbelt SBPL is unsupported on non-macOS platforms"
}
#endif

private func seatbeltEscape(_ path: String) -> String {
    path
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

#if os(macOS)
/// Apply a Seatbelt SBPL profile via `sandbox_init`. Irreversible.
public func applySeatbeltProfile(_ sbpl: String) throws {
    typealias SandboxInitFn = @convention(c) (UnsafePointer<CChar>, UInt64, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
    typealias SandboxFreeErrorFn = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void

    guard let handle = dlopen(nil, RTLD_NOW) else {
        throw SandboxError.enforcementFailed("dlopen failed for sandbox_init")
    }
    guard let initSym = dlsym(handle, "sandbox_init") else {
        throw SandboxError.unsupported("sandbox_init not available")
    }
    let sandboxInit = unsafeBitCast(initSym, to: SandboxInitFn.self)
    let freeSym = dlsym(handle, "sandbox_free_error")
    let sandboxFreeError: SandboxFreeErrorFn? = freeSym.map { unsafeBitCast($0, to: SandboxFreeErrorFn.self) }

    var errorBuf: UnsafeMutablePointer<CChar>? = nil
    let rc = sbpl.withCString { cstr in
        sandboxInit(cstr, 0, &errorBuf)
    }
    if rc != 0 {
        let message: String
        if let errorBuf {
            message = String(cString: errorBuf)
            sandboxFreeError?(errorBuf)
        } else {
            message = "sandbox_init returned \(rc)"
        }
        throw SandboxError.enforcementFailed(message)
    }
}
#else
/// Apply a Seatbelt profile. On non-macOS platforms, throws `SandboxError.unsupported`.
public func applySeatbeltProfile(_ sbpl: String) throws {
    _ = sbpl
    throw SandboxError.unsupported("macOS Seatbelt (sandbox_init) is not supported on non-macOS platforms")
}
#endif

// MARK: - Bubblewrap plan (Linux)

/// A complete mount plan for re-exec under bubblewrap.
public struct BwrapDenyPlan: Sendable, Equatable {
    public var denyWrite: [String]
    public var denyRead: [String]
    public var hasGlobs: Bool
    public var restrictNetwork: Bool
    public var readOnly: [String]
    public var readWrite: [String]
    public var defaultRead: Bool

    public init(
        denyWrite: [String],
        denyRead: [String],
        hasGlobs: Bool,
        restrictNetwork: Bool = false,
        readOnly: [String] = [],
        readWrite: [String] = [],
        defaultRead: Bool = true
    ) {
        self.denyWrite = denyWrite
        self.denyRead = denyRead
        self.hasGlobs = hasGlobs
        self.restrictNetwork = restrictNetwork
        self.readOnly = readOnly
        self.readWrite = readWrite
        self.defaultRead = defaultRead
    }
}

public let bwrapEnvVar = "__GROK_INSIDE_BWRAP"
public let bwrapReceiptPathEnvVar = "__GROK_BWRAP_RECEIPT_PATH"
public let bwrapReceiptTokenEnvVar = "__GROK_BWRAP_RECEIPT_TOKEN"

/// Return true only for a verified bwrap re-entry. The environment marker is
/// deliberately not exposed as a standalone capability signal.
public func isInsideBwrap(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
    isVerifiedInsideBwrap(environment: environment)
}

/// Return true only after the bwrap handoff marker is paired with the
/// process-owned, one-use receipt installed before `execve`. Marker presence
/// by itself is intentionally not security evidence.
public func isVerifiedInsideBwrap(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> Bool {
    guard environment[bwrapEnvVar] == "1",
          let receiptPath = environment[bwrapReceiptPathEnvVar],
          let receiptToken = environment[bwrapReceiptTokenEnvVar],
          !receiptPath.isEmpty,
          !receiptToken.isEmpty else {
        return false
    }

    let expectedDirectory = sandboxGrokHome(environment: environment)
        .appendingPathComponent("sandbox-receipts", isDirectory: true)
        .resolvingSymlinksInPath()
        .standardizedFileURL
        .path
    let actualURL = URL(fileURLWithPath: receiptPath)
        .resolvingSymlinksInPath()
        .standardizedFileURL
    guard actualURL.path.hasPrefix(expectedDirectory + "/"),
          actualURL.lastPathComponent == receiptToken,
          let contents = try? String(contentsOf: actualURL, encoding: .utf8),
          contents == receiptToken else {
        return false
    }
    return true
}

/// Discover bubblewrap by absolute path. Executable-file presence is only a
/// discovery step; callers must still run `probeBubblewrap` before claiming
/// enforcement capability.
public func findBubblewrap(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> String? {
    let fixed = ["/usr/bin/bwrap", "/bin/bwrap", "/usr/local/bin/bwrap"]
    for path in fixed where FileManager.default.isExecutableFile(atPath: path) {
        return path
    }
    for directory in (environment["PATH"] ?? "").split(separator: ":") {
        let candidate = "\(directory)/bwrap"
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }
    return nil
}

/// Run the exact minimal bubblewrap invocation used by the production
/// re-exec. A successful process exit is the only capability signal accepted.
public func probeBubblewrap(path: String) -> Bool {
    guard FileManager.default.isExecutableFile(atPath: path) else { return false }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = [
        "--cap-drop", "ALL",
        "--ro-bind", "/", "/",
        "--dev-bind", "/dev", "/dev",
        "--proc", "/proc",
        "--", "/bin/sh", "-c", ":",
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let finished = DispatchSemaphore(value: 0)
    let status = LockedProcessStatus()
    process.terminationHandler = { child in
        status.set(child.terminationStatus)
        finished.signal()
    }
    do {
        try process.run()
    } catch {
        process.terminationHandler = nil
        return false
    }
    if finished.wait(timeout: .now() + 5) == .timedOut {
        process.terminate()
        if finished.wait(timeout: .now() + 1) == .timedOut {
            #if os(Linux)
            kill(process.processIdentifier, SIGKILL)
            #endif
            _ = finished.wait(timeout: .now() + 2)
        }
        return false
    }
    return status.get() == 0
}

/// Injectable seams for the process-replacing Linux handoff. Production uses
/// the current argv/environment and `execve`; tests can capture the planned
/// command without replacing the test runner.
public struct LinuxBwrapReexecHooks: Sendable {
    public var environment: @Sendable () -> [String: String]
    public var arguments: @Sendable () -> [String]
    public var executable: @Sendable () -> String
    public var supportInfo: @Sendable () -> SandboxSupportInfo
    public var discoverBubblewrap: @Sendable ([String: String]) -> String?
    public var probe: @Sendable (String) -> Bool
    public var exec: @Sendable (String, [String], [String: String]) throws -> Void

    public init(
        environment: @escaping @Sendable () -> [String: String],
        arguments: @escaping @Sendable () -> [String],
        executable: @escaping @Sendable () -> String,
        supportInfo: @escaping @Sendable () -> SandboxSupportInfo,
        discoverBubblewrap: @escaping @Sendable ([String: String]) -> String?,
        probe: @escaping @Sendable (String) -> Bool,
        exec: @escaping @Sendable (String, [String], [String: String]) throws -> Void
    ) {
        self.environment = environment
        self.arguments = arguments
        self.executable = executable
        self.supportInfo = supportInfo
        self.discoverBubblewrap = discoverBubblewrap
        self.probe = probe
        self.exec = exec
    }

    public static let production = LinuxBwrapReexecHooks(
        environment: { ProcessInfo.processInfo.environment },
        arguments: { Array(CommandLine.arguments.dropFirst()) },
        executable: {
            guard let first = CommandLine.arguments.first, !first.isEmpty else {
                return "/proc/self/exe"
            }
            if first.hasPrefix("/") { return first }
            return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(first)
                .standardizedFileURL
                .path
        },
        supportInfo: {
            PlatformSandboxSupport.supportInfo(environment: ProcessInfo.processInfo.environment)
        },
        discoverBubblewrap: { environment in findBubblewrap(environment: environment) },
        probe: { probeBubblewrap(path: $0) },
        exec: { executable, arguments, environment in
            try replaceProcess(executable: executable, arguments: arguments, environment: environment)
        }
    )
}

private final class LockedProcessStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32?

    func set(_ newValue: Int32) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Create a zero-permission placeholder path for bwrap read-deny bind-overs.
public func bwrapBlockedPlaceholder(
    name: String,
    wantDir: Bool,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> URL? {
    let pid = ProcessInfo.processInfo.processIdentifier
    let path = sandboxGrokHome(environment: environment).appendingPathComponent("\(name).\(pid)")
    let parent = path.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    if wantDir {
        try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    } else {
        if !FileManager.default.fileExists(atPath: path.path) {
            FileManager.default.createFile(atPath: path.path, contents: Data())
        }
    }
    #if canImport(Darwin) || canImport(Glibc)
    chmod(path.path, 0000)
    #endif
    return path
}

/// Expand deny globs into concrete existing matching file paths on Linux.
public func expandDenyGlobs(
    workspace: URL,
    globs: [String],
    maxDepth: Int = 64,
    maxMatches: Int = 4096,
    maxEntries: Int = 200000
) -> [String]? {
    var matches: [String] = []
    var visited = 0
    let fm = FileManager.default
    for glob in globs {
        if (try? validateDenyGlob(glob)) == nil {
            return nil
        }
        let (root, tail) = splitGlobRoot(workspace: workspace, glob: glob)
        guard fm.fileExists(atPath: root.path) else { continue }
        let tailRegexStr = globTailToRegex(tail)
        guard let regex = try? NSRegularExpression(pattern: "^\(tailRegexStr)$") else { return nil }
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants],
            errorHandler: { _, error in
                let nsError = error as NSError
                // Skip permission denied errors, fail closed on other errors
                if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoPermissionError {
                    return true
                }
                return false
            }
        ) else { return nil }

        for case let fileURL as URL in enumerator {
            visited += 1
            if visited > maxEntries { return nil }
            if enumerator.level > maxDepth { return nil }

            let relPath: String
            if root.path == "/" {
                relPath = String(fileURL.path.dropFirst())
            } else {
                relPath = String(fileURL.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }

            let range = NSRange(location: 0, length: relPath.utf16.count)
            if regex.firstMatch(in: relPath, options: [], range: range) != nil {
                matches.append(fileURL.path)
                if matches.count > maxMatches { return nil }
            }
        }
    }
    return Array(Set(matches)).sorted()
}

/// Build argv for `bwrap` re-exec. Returns `nil` if already inside bwrap.
public func bwrapReexecCommand(
    denyWrite: [String],
    denyRead: [String],
    restrictNetwork: Bool = false,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    arguments: [String] = Array(CommandLine.arguments.dropFirst()),
    executable: URL? = nil,
    bwrapPath: String = "bwrap",
    receiptPath: String? = nil,
    receiptToken: String? = nil,
    readOnly: [String] = [],
    readWrite: [String] = [],
    defaultRead: Bool = true
) -> [String]? {
    if isVerifiedInsideBwrap(environment: environment) { return nil }
    _ = restrictNetwork
    let selfExe: String
    if let executable {
        selfExe = executable.path
    } else {
        selfExe = CommandLine.arguments.first ?? "/proc/self/exe"
    }
    var argv: [String] = [bwrapPath, "--cap-drop", "ALL"]
    if defaultRead {
        argv.append(contentsOf: ["--ro-bind", "/", "/"])
    } else {
        // A strict profile starts from an empty root and explicitly mounts its
        // read-only/read-write roots below. This is the only way to preserve
        // `defaultRead == false` instead of turning it into a writable host.
        argv.append(contentsOf: ["--tmpfs", "/"])
    }
    for path in readOnly where path != "/" {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        argv.append(contentsOf: ["--ro-bind", path, path])
    }
    for path in readWrite where path != "/" {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        argv.append(contentsOf: ["--bind", path, path])
    }
    // The agent retains provider network access. Child-only network denial is
    // armed later through LocalShellProcessBackend after successful apply.
    argv.append(contentsOf: ["--setenv", bwrapEnvVar, "1"])
    if let receiptPath, let receiptToken {
        argv.append(contentsOf: [
            "--setenv", bwrapReceiptPathEnvVar, receiptPath,
            "--setenv", bwrapReceiptTokenEnvVar, receiptToken,
        ])
    }
    // Device and proc mounts are established before deny overlays so explicit
    // denies remain the final authority for every profile root.
    argv.append(contentsOf: ["--dev-bind", "/dev", "/dev", "--proc", "/proc"])
    for path in denyWrite {
        if FileManager.default.fileExists(atPath: path) {
            argv.append(contentsOf: ["--ro-bind", path, path])
        }
    }
    for path in denyRead {
        let isDir = denyPathIsDir(URL(fileURLWithPath: path))
        if let placeholder = bwrapBlockedPlaceholder(name: isDir ? "sandbox-blocked-dir" : "sandbox-blocked", wantDir: isDir, environment: environment) {
            argv.append(contentsOf: ["--ro-bind", placeholder.path, path])
        } else {
            return nil
        }
    }
    argv.append(contentsOf: ["--", selfExe])
    argv.append(contentsOf: arguments)
    return argv
}

/// Resolve a profile's full bwrap deny plan.
public func bwrapDenyPlan(
    profile: ProfileName,
    workspace: URL,
    config: SandboxConfig? = nil
) -> BwrapDenyPlan? {
    let cfg = config ?? loadSandboxConfig(workspace: workspace)
    var denyWrite: [String] = []
    var readOnly: [String] = []
    var readWrite: [String] = []
    var defaultRead = true
    if isDevboxBased(profile: profile, config: cfg) {
        denyWrite.append("/data")
    }
    var denyRead: [String] = []
    var hasGlobs = false
    var restrictNet = profile.restrictsNetwork
    if profile != .off {
        guard let resolved = try? profile.resolve(workspace: workspace, config: cfg) else {
            return nil
        }
        readOnly = resolved.readOnly.map(\.path)
        readWrite = resolved.readWrite.map(\.path)
        defaultRead = resolved.defaultRead
        restrictNet = resolved.restrictNetwork
        let (exact, globs) = partitionDenyEntries(resolved.denyEntries)
        hasGlobs = !globs.isEmpty
        for entry in exact {
            let pathStr = entry.hasPrefix("/") ? entry : workspace.appendingPathComponent(entry).path
            denyRead.append(pathStr)
        }
        for d in resolved.deny {
            if !denyRead.contains(d.path) {
                denyRead.append(d.path)
            }
        }
        if hasGlobs {
            if let expanded = expandDenyGlobs(workspace: workspace, globs: globs) {
                denyRead.append(contentsOf: expanded)
            } else {
                // Fail closed if glob expansion failed or exceeded limits
                return nil
            }
        }
    }
    let uniqueRead = Array(Set(denyRead)).sorted()
    return BwrapDenyPlan(
        denyWrite: denyWrite,
        denyRead: uniqueRead,
        hasGlobs: hasGlobs,
        restrictNetwork: restrictNet,
        readOnly: Array(Set(readOnly)).sorted(),
        readWrite: Array(Set(readWrite)).sorted(),
        defaultRead: defaultRead
    )
}

/// Create the one-use receipt that proves this process initiated the
/// bubblewrap handoff. A caller-supplied environment marker without this
/// receipt is never accepted as successful enforcement.
func createBwrapReceipt(environment: [String: String]) throws -> (path: String, token: String) {
    let token = UUID().uuidString
    let directory = sandboxGrokHome(environment: environment)
        .appendingPathComponent("sandbox-receipts", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent(token).path
    try Data(token.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    #if canImport(Darwin) || canImport(Glibc)
    _ = chmod(path, 0o600)
    #endif
    return (path, token)
}

/// Consume and validate the receipt installed by bubblewrap's `--setenv`.
func validateBwrapReceipt(environment: [String: String]) throws {
    guard isVerifiedInsideBwrap(environment: environment) else {
        throw SandboxError.enforcementFailed("bubblewrap handoff marker is absent")
    }
    guard let path = environment[bwrapReceiptPathEnvVar],
          let token = environment[bwrapReceiptTokenEnvVar],
          !path.isEmpty,
          !token.isEmpty else {
        throw SandboxError.enforcementFailed(
            "bubblewrap marker was present without a process-owned enforcement receipt"
        )
    }
    let expectedDirectory = sandboxGrokHome(environment: environment)
        .appendingPathComponent("sandbox-receipts", isDirectory: true)
        .standardizedFileURL
        .path
    let actualPath = URL(fileURLWithPath: path).standardizedFileURL.path
    guard actualPath.hasPrefix(expectedDirectory + "/") else {
        throw SandboxError.enforcementFailed("bubblewrap receipt path is outside the sandbox receipt directory")
    }
    guard let contents = try? String(contentsOfFile: actualPath, encoding: .utf8),
          contents == token,
          URL(fileURLWithPath: actualPath).lastPathComponent == token else {
        throw SandboxError.enforcementFailed("bubblewrap enforcement receipt is invalid")
    }
    try? FileManager.default.removeItem(atPath: actualPath)
}

private func replaceProcess(
    executable: String,
    arguments: [String],
    environment: [String: String]
) throws {
    #if os(Linux) || os(macOS)
    let argumentPointers = ([executable] + arguments).map { strdup($0) }
    let environmentPointers = environment
        .sorted { $0.key < $1.key }
        .map { strdup("\($0.key)=\($0.value)") }
    defer {
        for pointer in argumentPointers { if let pointer { free(pointer) } }
        for pointer in environmentPointers { if let pointer { free(pointer) } }
    }
    var argv = argumentPointers + [nil]
    var envp = environmentPointers + [nil]
    // `baseAddress` is optional, and Glibc's `execve` takes it non-optional
    // while Darwin's is implicitly unwrapped — so passing the optional through
    // compiles on macOS and fails only on Linux, which is why this never
    // surfaced in a local gate. Unwrap once here so both platforms take the
    // same code path.
    let result: Int32 = argv.withUnsafeMutableBufferPointer { argvBuffer -> Int32 in
        envp.withUnsafeMutableBufferPointer { envBuffer -> Int32 in
            guard let argvBase = argvBuffer.baseAddress,
                  let envBase = envBuffer.baseAddress
            else {
                errno = EINVAL
                return -1
            }
            return executable.withCString { path in
                #if os(Linux)
                Glibc.execve(path, argvBase, envBase)
                #else
                Darwin.execve(path, argvBase, envBase)
                #endif
            }
        }
    }
    let message = String(cString: strerror(errno))
    _ = result
    throw SandboxError.enforcementFailed("execve(\(executable)) failed: \(message)")
    #else
    _ = executable
    _ = arguments
    _ = environment
    throw SandboxError.unsupported("bubblewrap re-exec is only available on Linux")
    #endif
}

// MARK: - Windows seams (compile-checked)

/// Placeholder for restricted-token creation. Always returns unsupported
/// until the Windows backend is implemented.
public func createRestrictedTokenSandbox(profile: ResolvedSandboxProfile) throws {
    _ = profile
    throw SandboxError.unsupported(
        "Windows restricted-token sandbox is not yet implemented; refusing to run unsandboxed"
    )
}

/// Placeholder for Job Object confinement.
public func createJobObjectSandbox(profile: ResolvedSandboxProfile) throws {
    _ = profile
    throw SandboxError.unsupported(
        "Windows Job Object sandbox is not yet implemented; refusing to run unsandboxed"
    )
}
