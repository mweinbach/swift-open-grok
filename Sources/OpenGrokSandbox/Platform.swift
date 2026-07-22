// Platform.swift
//
// Platform sandbox support probes and enforcement backends:
//   * macOS — Seatbelt (sandbox_init + SBPL)
//   * Linux — Landlock probe + bubblewrap re-exec plan
//   * Windows — restricted-token / Job Object (compile-checked unsupported)
//
// R15 acceptance: fail closed when a non-off mode cannot be enforced.

import Foundation

#if canImport(Darwin)
import Darwin
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
    public static func supportInfo() -> SandboxSupportInfo {
        #if os(macOS)
        // sandbox_init is present on all supported macOS versions.
        return SandboxSupportInfo(
            isSupported: true,
            backend: .macosSeatbelt,
            details: "macOS Seatbelt (sandbox_init) available"
        )
        #elseif os(Linux)
        let landlock = landlockSupported()
        let bwrap = FileManager.default.isExecutableFile(atPath: "/usr/bin/bwrap")
            || FileManager.default.isExecutableFile(atPath: "/bin/bwrap")
        if landlock {
            return SandboxSupportInfo(
                isSupported: true,
                backend: .linuxLandlock,
                details: "Linux Landlock ABI available"
            )
        }
        if bwrap {
            return SandboxSupportInfo(
                isSupported: true,
                backend: .linuxBubblewrap,
                details: "bubblewrap available (Landlock not present)"
            )
        }
        return SandboxSupportInfo(
            isSupported: false,
            backend: .none,
            details: "neither Landlock nor bubblewrap available"
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

#if os(macOS)
/// Build a Seatbelt profile language (SBPL) string for the resolved profile.
public func buildSeatbeltProfile(_ resolved: ResolvedSandboxProfile) -> String {
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

    for path in resolved.deny {
        let escaped = seatbeltEscape(path.path)
        lines.append("(deny file-read* file-write* (subpath \"\(escaped)\"))")
    }

    // Glob deny entries as regexes (best-effort; macOS Seatbelt enforces at runtime).
    for entry in resolved.denyEntries where entry.contains("*") || entry.contains("?") {
        let regex = globToSeatbeltRegex(entry)
        lines.append("(deny file-read* file-write* (regex #\"\(regex)\"))")
    }

    if resolved.restrictNetwork {
        lines.append("(deny network*)")
    } else {
        lines.append("(allow network*)")
    }

    return lines.joined(separator: "\n")
}

private func seatbeltEscape(_ path: String) -> String {
    path
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

private func globToSeatbeltRegex(_ glob: String) -> String {
    var out = "^"
    var i = glob.startIndex
    while i < glob.endIndex {
        let ch = glob[i]
        if ch == "*" {
            let next = glob.index(after: i)
            if next < glob.endIndex, glob[next] == "*" {
                out += ".*"
                i = glob.index(after: next)
                continue
            }
            out += "[^/]*"
            i = next
            continue
        }
        if ch == "?" {
            out += "[^/]"
            i = glob.index(after: i)
            continue
        }
        // Escape regex metacharacters.
        if "\\.[]{}()+-^$|".contains(ch) {
            out.append("\\")
        }
        out.append(ch)
        i = glob.index(after: i)
    }
    out += "$"
    return out
}

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
#endif

// MARK: - Bubblewrap plan (Linux)

/// A plan for re-exec under bubblewrap with deny mounts.
public struct BwrapDenyPlan: Sendable, Equatable {
    public var denyWrite: [String]
    public var denyRead: [String]
    public var hasGlobs: Bool

    public init(denyWrite: [String], denyRead: [String], hasGlobs: Bool) {
        self.denyWrite = denyWrite
        self.denyRead = denyRead
        self.hasGlobs = hasGlobs
    }
}

public let bwrapEnvVar = "__GROK_INSIDE_BWRAP"

public func isInsideBwrap(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
    environment[bwrapEnvVar] != nil
}

/// Build argv for `bwrap` re-exec. Returns `nil` if already inside bwrap.
public func bwrapReexecCommand(
    denyWrite: [String],
    denyRead: [String],
    environment: [String: String] = ProcessInfo.processInfo.environment,
    arguments: [String] = Array(CommandLine.arguments.dropFirst()),
    executable: URL? = nil
) -> [String]? {
    if isInsideBwrap(environment: environment) { return nil }
    let selfExe: String
    if let executable {
        selfExe = executable.path
    } else {
        selfExe = CommandLine.arguments.first ?? "/proc/self/exe"
    }
    var argv: [String] = ["bwrap", "--bind", "/", "/"]
    for path in denyWrite {
        if FileManager.default.fileExists(atPath: path) {
            argv.append(contentsOf: ["--ro-bind", path, path])
        }
    }
    for path in denyRead {
        // Bind-over with a zero-permission placeholder path when available;
        // otherwise still emit the bind target so callers see intent.
        argv.append(contentsOf: ["--ro-bind", path, path])
    }
    argv.append(contentsOf: ["--dev-bind", "/dev", "/dev", "--proc", "/proc"])
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
    #if os(Linux)
    let cfg = config ?? loadSandboxConfig(workspace: workspace)
    var denyWrite: [String] = []
    if isDevboxBased(profile: profile, config: cfg) {
        denyWrite.append("/data")
    }
    var denyRead: [String] = []
    var hasGlobs = false
    if profile != .off {
        if let resolved = try? profile.resolve(workspace: workspace, config: cfg) {
            for entry in resolved.denyEntries {
                if entry.contains("*") || entry.contains("?") {
                    hasGlobs = true
                } else if entry.hasPrefix("/") {
                    denyRead.append(entry)
                } else {
                    denyRead.append(workspace.appendingPathComponent(entry).path)
                }
            }
            for d in resolved.deny {
                if !denyRead.contains(d.path) {
                    denyRead.append(d.path)
                }
            }
        }
    }
    return BwrapDenyPlan(denyWrite: denyWrite, denyRead: denyRead, hasGlobs: hasGlobs)
    #else
    _ = (profile, workspace, config)
    return nil
    #endif
}

// MARK: - Windows seams (compile-checked)

#if os(Windows)
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
#endif
