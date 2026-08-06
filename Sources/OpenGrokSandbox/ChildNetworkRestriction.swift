// ChildNetworkRestriction.swift
//
// Real Linux child network denial at the process-spawn seam.
//
// Decision record (W10 sandbox slice). Upstream installs a classic-BPF
// seccomp filter in the child between fork and exec
// (`xai-grok-sandbox/src/child_net.rs:143-213`,
// `install_child_network_filter`), wired into every known Linux launch via
// `cmd.pre_exec` (`xai-grok-shell/src/terminal/streaming_local_terminal.rs:917-921`,
// `xai-grok-tools/src/computer/local/terminal.rs:711-714, 831-834, 3200-3203`).
// That exact mechanism is not reachable from this module: Foundation.Process
// exposes no pre-exec hook on any platform, installing the filter in the
// *parent* would cut the agent's own provider access, and a C trampoline
// target belongs to the package manifest, not this module. Upstream itself
// never uses `unshare` for this (it appears only as attack surface the
// namespace lockdown must defeat — `tests/deny_paths_e2e.rs:574-602`).
//
// The port therefore enforces the same capability outcome — the spawned
// child has no usable network — by re-execing the launch through util-linux
// `unshare(1)` into fresh user + network namespaces:
//
//     unshare --user --map-current-user --net -- <executable> <args...>
//
// PORT_PLAN W4-S1 permits this: "Exact platform enforcement may differ, but
// capability outcomes and failure policy may not." The failure policy is
// preserved exactly: a host that cannot create the namespaces (no unshare
// binary, unprivileged userns disabled, no CAP_SYS_ADMIN) fails closed with
// `SandboxError.unsupported` rather than spawning an unrestricted child.
//
// Costs of the tradeoff, named so they are weighed rather than discovered:
//   * The blocked child observes ENETUNREACH (an interface-less namespace)
//     instead of upstream's EPERM-from-seccomp; error-text sniffers see a
//     different message. The security property — no egress, no ingress — is
//     identical, and raw-socket egress is denied *more* strictly than the
//     upstream syscall list.
//   * A user namespace changes the child's credential view: with
//     `--map-root-user` the child sees uid 0 inside the namespace, and in
//     every candidate the child holds capabilities only over its own
//     namespaces. Setuid binaries lose their effect and uid-sensitive tools
//     can behave differently than under upstream's filter. The candidate
//     order puts the uid-preserving mapping first to minimize this.
//   * Each wrapped launch pays one extra exec (`unshare` itself).
//   * Enforcement depends on host namespace policy (Docker/AppArmor/sysctl),
//     which is why availability is probed by running the real thing once and
//     caching it, never assumed from kernel version strings.

import Foundation

#if os(Linux)
import Glibc
#endif

/// A resolved mechanism for denying a spawned child all network access on
/// Linux: re-exec through util-linux `unshare(1)`.
public struct ChildNetworkRestriction: Sendable, Equatable {
    /// Absolute path to a working `unshare` binary.
    public var unsharePath: String
    /// argv placed between `unshare` and the wrapped executable, ending in
    /// `--` so the wrapped argv is never re-parsed as unshare options.
    public var prefixArguments: [String]

    public init(unsharePath: String, prefixArguments: [String]) {
        self.unsharePath = unsharePath
        self.prefixArguments = prefixArguments
    }
}

/// Linux child network restriction: host probing and launch wrapping.
///
/// Off Linux every probe returns `nil` and `wrappedCommand` throws
/// `SandboxError.unsupported`; per-child network denial is a Linux seam
/// (upstream's filter is likewise `cfg(target_os = "linux")`). macOS keeps
/// process-level network access available for provider sampling.
public enum LinuxChildNetworkRestriction {
    /// Candidate namespace invocations, least surprising first:
    ///   1. uid-preserving user namespace (util-linux >= 2.33) — the child
    ///      keeps its uid and gains no capabilities anywhere.
    ///   2. classic unprivileged user namespace mapping the caller to root —
    ///      wider util-linux compatibility; the child is root only inside
    ///      its own namespaces and can affect nothing outside them.
    ///   3. bare network namespace for callers already holding CAP_SYS_ADMIN
    ///      (e.g. root on a host where userns creation is policy-blocked).
    static let candidatePrefixes: [[String]] = [
        ["--user", "--map-current-user", "--net", "--"],
        ["--user", "--map-root-user", "--net", "--"],
        ["--net", "--"],
    ]

    /// Probe whether this host can re-exec children through `unshare` into a
    /// network-denying namespace. Returns the working restriction on success,
    /// `nil` when enforcement is unavailable.
    ///
    /// The probe runs the real invocation (`unshare <prefix> /bin/sh -c :`)
    /// once per binary and caches the outcome; capability is never inferred
    /// from kernel versions or file presence alone. `/bin/sh` is used because
    /// it exists on every Linux userspace, including minimal containers and
    /// NixOS where `/bin/true` is absent.
    ///
    /// An explicit `unsharePath` is authoritative: a non-executable override
    /// probes as unsupported rather than silently falling back to discovery,
    /// so tests can pin the failure path.
    public static func probeHost(
        unsharePath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ChildNetworkRestriction? {
        #if os(Linux)
        let resolvedPath: String
        if let unsharePath {
            guard FileManager.default.isExecutableFile(atPath: unsharePath) else {
                return nil
            }
            resolvedPath = unsharePath
        } else {
            guard let discovered = discoverUnshare(environment: environment) else {
                return nil
            }
            resolvedPath = discovered
        }
        if let cached = probeCache.value(for: resolvedPath) {
            return cached
        }
        let probed = probeCandidates(unsharePath: resolvedPath)
        probeCache.store(probed, for: resolvedPath)
        return probed
        #else
        return nil
        #endif
    }

    /// Wrap a launch so the spawned child has no network access, failing
    /// closed with `SandboxError.unsupported` when the host cannot enforce.
    public static func wrappedCommand(
        executable: String,
        arguments: [String],
        unsharePath: String? = nil
    ) throws -> (executable: String, arguments: [String]) {
        guard let restriction = probeHost(unsharePath: unsharePath) else {
            throw SandboxError.unsupported(
                "cannot enforce child network denial on this host: util-linux "
                    + "unshare(1) with user+network namespace support is unavailable "
                    + "(binary missing, unprivileged userns disabled, or no "
                    + "CAP_SYS_ADMIN); refusing to spawn an unrestricted child"
            )
        }
        return wrap(executable: executable, arguments: arguments, restriction: restriction)
    }

    /// Pure argv transform: replace the launch with the `unshare` re-exec.
    /// The wrapped executable and its arguments follow `--` verbatim, so
    /// arguments that resemble unshare options cannot be re-parsed.
    public static func wrap(
        executable: String,
        arguments: [String],
        restriction: ChildNetworkRestriction
    ) -> (executable: String, arguments: [String]) {
        (
            executable: restriction.unsharePath,
            arguments: restriction.prefixArguments + [executable] + arguments
        )
    }

    #if os(Linux)
    /// Locked cache so concurrent spawns probe at most once per binary.
    private static let probeCache = ProbeCache()

    private static func discoverUnshare(environment: [String: String]) -> String? {
        let fixed = [
            "/usr/bin/unshare",
            "/bin/unshare",
            "/usr/sbin/unshare",
            "/sbin/unshare",
        ]
        for path in fixed where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = "\(directory)/unshare"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func probeCandidates(unsharePath: String) -> ChildNetworkRestriction? {
        for prefix in candidatePrefixes {
            if runProbe(executable: unsharePath, arguments: prefix + ["/bin/sh", "-c", ":"]) == 0 {
                return ChildNetworkRestriction(unsharePath: unsharePath, prefixArguments: prefix)
            }
        }
        return nil
    }

    /// Run a probe to completion with a bounded wait. Uses
    /// `terminationHandler` bridged to a semaphore: `Process.waitUntilExit()`
    /// can never return when the child exits before the calling thread's run
    /// loop arms the death notification (the suite has lost hours to this),
    /// and timeout escalates SIGTERM -> SIGKILL so a wedged probe cannot
    /// stall the spawner.
    private static func runProbe(
        executable: String,
        arguments: [String],
        timeoutSeconds: TimeInterval = 5
    ) -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        let status = LockedProbeStatus()
        process.terminationHandler = { child in
            status.set(child.terminationStatus)
            finished.signal()
        }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            return nil
        }
        if finished.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 2)
            }
            return nil
        }
        return status.get()
    }
    #endif
}

#if os(Linux)
/// Locked cache so concurrent spawns probe at most once per binary.
private final class ProbeCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: ChildNetworkRestriction?] = [:]

    /// Outer `nil` means "not yet probed"; inner `nil` means "probed,
    /// unsupported" — a cached negative must not re-probe on every spawn.
    func value(for key: String) -> ChildNetworkRestriction?? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key] else { return nil }
        return .some(entry)
    }

    func store(_ value: ChildNetworkRestriction?, for key: String) {
        lock.lock()
        entries[key] = value
        lock.unlock()
    }
}

private final class LockedProbeStatus: @unchecked Sendable {
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
#endif
