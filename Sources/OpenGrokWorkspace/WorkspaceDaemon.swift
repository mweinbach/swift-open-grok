// WorkspaceDaemon.swift
//
// Self-daemonization and single-instance locking for the workspace-server.
// Ported from `xai-grok-workspace-daemon/src/daemonize.rs`.
//
// The server is launched fire-and-forget by the sandbox orchestrator, which
// only ever holds a handle to the originally-spawned PID / process group.
// After a double-fork + `setsid()` the surviving daemon lives in a new
// session and process group, so a later process-group kill on the original
// pgid cannot reach it.

import Foundation

#if canImport(Darwin)
import Darwin

@_silgen_name("fork")
private func sys_fork() -> pid_t

@_silgen_name("setsid")
private func sys_setsid() -> pid_t
#elseif canImport(Glibc)
import Glibc

@_silgen_name("fork")
private func sys_fork() -> pid_t

@_silgen_name("setsid")
private func sys_setsid() -> pid_t
#endif

// MARK: - Constants

#if os(Windows)
/// stdout + stderr redirect target when no `--log-file` is given.
public let DEFAULT_LOG_PATH: String = "C:\\Windows\\Temp\\workspace-server.log"
/// Single-instance lock file used when no `--pid-file` is given.
public let DEFAULT_PIDFILE_PATH: String = "C:\\Windows\\Temp\\workspace-server.pid"
#else
/// stdout + stderr redirect target when no `--log-file` is given.
public let DEFAULT_LOG_PATH: String = "/tmp/workspace-server.log"
/// Single-instance lock file used when no `--pid-file` is given.
public let DEFAULT_PIDFILE_PATH: String = "/tmp/workspace-server.pid"
#endif

/// How long a takeover waits for the gracefully-terminated predecessor to
/// release the pidfile lock before escalating to a forceful kill.
public let TAKEOVER_GRACE: TimeInterval = 2.0

/// How long a takeover waits for the lock after the forceful kill before declining.
public let TAKEOVER_KILL_GRACE: TimeInterval = 1.0

/// Poll interval while waiting for the predecessor to release the lock.
public let TAKEOVER_POLL: TimeInterval = 0.05

/// Invocation fragment identifying a pidfile holder as a workspace-server.
public let WORKSPACE_SERVER_NAME_FRAGMENT: String = "workspace-server"

/// `oom_score_adj` for the workspace-server when `--oom-protect` is set.
public let WORKSPACE_SERVER_OOM_SCORE_ADJ: Int32 = -900

/// `oom_score_adj` for the supervised preview-proxy.
public let PREVIEW_PROXY_OOM_SCORE_ADJ: Int32 = -500

/// Owner read/write mode used for daemon-owned files on Unix. Windows accepts
/// the value through the CRT open call but enforces access through the ACL.
public let DAEMON_OWNER_READ_WRITE_MODE: Int32 = 0o600

// MARK: - OOM Protection Storage

private final class OOMProtectMetrics: @unchecked Sendable {
    static let shared = OOMProtectMetrics()
    private let lock = NSLock()
    private var appliedCount = 0
    private var failedCount = 0

    func record(outcome: String) {
        lock.withLock {
            if outcome == "applied" {
                appliedCount += 1
            } else {
                failedCount += 1
            }
        }
    }

    func counts() -> (applied: Int, failed: Int) {
        lock.withLock {
            (appliedCount, failedCount)
        }
    }
}

public func recordOOMProtect(outcome: String) {
    OOMProtectMetrics.shared.record(outcome: outcome)
}

public func oomProtectCounts() -> (applied: Int, failed: Int) {
    OOMProtectMetrics.shared.counts()
}

/// Write `/proc/self/oom_score_adj`. Linux only; checked so a capability
/// regression surfaces as an error rather than silent no-op.
public func setOOMScoreAdj(_ adj: Int32) throws {
    #if os(Linux)
    let path = "/proc/self/oom_score_adj"
    let content = "\(adj)\n"
    try content.write(toFile: path, atomically: false, encoding: .utf8)
    #endif
}

/// Lower the workspace-server's `oom_score_adj` to `WORKSPACE_SERVER_OOM_SCORE_ADJ`.
/// Call after daemonize (double-fork) and before the runtime starts when `--oom-protect` is set.
public func applyWorkspaceOOMProtect() -> Bool {
    #if os(Linux)
    if let cur = try? String(contentsOfFile: "/proc/self/oom_score_adj", encoding: .utf8),
       let curVal = Int32(cur.trimmingCharacters(in: .whitespacesAndNewlines)),
       curVal == WORKSPACE_SERVER_OOM_SCORE_ADJ {
        recordOOMProtect(outcome: "applied")
        return true
    }
    #endif

    do {
        try setOOMScoreAdj(WORKSPACE_SERVER_OOM_SCORE_ADJ)
        recordOOMProtect(outcome: "applied")
        return true
    } catch {
        #if os(Linux)
        if let cur = try? String(contentsOfFile: "/proc/self/oom_score_adj", encoding: .utf8),
           let curVal = Int32(cur.trimmingCharacters(in: .whitespacesAndNewlines)),
           curVal == WORKSPACE_SERVER_OOM_SCORE_ADJ {
            recordOOMProtect(outcome: "applied")
            return true
        }
        #endif
        FileHandle.standardError.write(Data("failed to lower oom_score_adj to \(WORKSPACE_SERVER_OOM_SCORE_ADJ): \(error)\n".utf8))
        recordOOMProtect(outcome: "failed")
        return false
    }
}

// MARK: - File Open Posture

/// Open a daemon-owned file (log or pidfile) with defense-in-depth posture:
/// `O_NOFOLLOW` and mode `0600` (user read/write only).
public func daemonFileOpen(
    path: String,
    flags: Int32,
    mode: Int32 = DAEMON_OWNER_READ_WRITE_MODE
) throws -> Int32 {
    let url = URL(fileURLWithPath: path)
    let parent = url.deletingLastPathComponent()
    if !parent.path.isEmpty && parent.path != "/" {
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    #if os(Windows)
    let effectiveFlags = flags
    #else
    let effectiveFlags = flags | O_NOFOLLOW
    #endif

    #if os(Windows)
    let fd = open(path, effectiveFlags, mode)
    #else
    let fd = open(path, effectiveFlags, mode_t(mode))
    #endif
    if fd < 0 {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return fd
}

// MARK: - Self-Daemonization

/// Double-fork + `setsid()` into a new session, `chdir("/")`, and redirect
/// stdio (stdin <- `/dev/null`, stdout+stderr appended to `logPath`).
///
/// Must be called before any multi-threaded runtime/tasks start.
public func daemonize(logPath: String = DEFAULT_LOG_PATH) throws {
    #if os(Windows)
    // Windows daemonization: launcher backgrounds the process; redirect stdout/stderr.
    let url = URL(fileURLWithPath: logPath)
    let parent = url.deletingLastPathComponent()
    if !parent.path.isEmpty {
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }
    let fd = try daemonFileOpen(path: logPath, flags: O_CREAT | O_WRONLY | O_APPEND)
    _ = dup2(fd, STDOUT_FILENO)
    _ = dup2(fd, STDERR_FILENO)
    close(fd)
    #elseif canImport(Darwin) || canImport(Glibc)
    // First fork: the launcher-tracked parent exits, orphaning the child.
    try forkAndExitParent()

    // New session/process group, detaching the controlling terminal.
    if sys_setsid() == -1 {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
    }

    // Second fork: a non-session-leader can never reacquire a controlling tty.
    try forkAndExitParent()

    // Detach from the launch directory.
    if chdir("/") == -1 {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    try redirectStdio(logPath: logPath)
    #else
    throw POSIXError(.ENOTSUP)
    #endif
}

#if canImport(Darwin) || canImport(Glibc)
/// `fork()`; the parent exits 0, the child returns to continue.
private func forkAndExitParent() throws {
    let pid = sys_fork()
    if pid < 0 {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EAGAIN)
    } else if pid > 0 {
        exit(0)
    }
}

/// Open `/dev/null` for stdin and `logPath` for stdout+stderr.
public func openStdioTargets(logPath: String) throws -> (stdinFd: Int32, logFd: Int32) {
    let url = URL(fileURLWithPath: logPath)
    let parent = url.deletingLastPathComponent()
    if !parent.path.isEmpty && parent.path != "/" {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDir) {
            if !isDir.boolValue {
                throw POSIXError(.ENOTDIR)
            }
        } else {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
    }

    let stdinFd = open("/dev/null", O_RDONLY)
    if stdinFd < 0 {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    do {
        let logFd = try daemonFileOpen(path: logPath, flags: O_CREAT | O_WRONLY | O_APPEND)
        return (stdinFd, logFd)
    } catch {
        close(stdinFd)
        throw error
    }
}

/// Redirect stdin from `/dev/null`, and stdout + stderr to `logPath`.
public func redirectStdio(logPath: String) throws {
    let (stdinFd, logFd) = try openStdioTargets(logPath: logPath)
    defer {
        close(stdinFd)
        close(logFd)
    }

    if dup2(stdinFd, STDIN_FILENO) == -1 {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    if dup2(logFd, STDOUT_FILENO) == -1 {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    if dup2(logFd, STDERR_FILENO) == -1 {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
#endif
