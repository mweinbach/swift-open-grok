// PidFile.swift
//
// Single-instance lock backed by an advisory `flock` on a pidfile.
// Ported from `xai-grok-workspace-daemon/src/daemonize.rs`.
//
// Dropping/closing it releases the advisory lock. The pidfile itself is left
// on disk for diagnostics.

import Foundation

#if canImport(Darwin)
import Darwin

@_silgen_name("proc_pidpath")
private func sys_proc_pidpath(_ pid: Int32, _ buffer: UnsafeMutableRawPointer, _ buffersize: UInt32) -> Int32
#elseif canImport(Glibc)
import Glibc
#endif

/// Single-instance lock backed by an advisory `flock` on a pidfile, held for
/// the daemon's lifetime. Dropping it closes the file, releasing the lock; the
/// pidfile itself is left on disk for diagnostics.
public final class PidFile: @unchecked Sendable {
    private var fd: Int32
    public let path: String
    private let lock = NSLock()

    public init(fd: Int32, path: String) {
        self.fd = fd
        self.path = path
    }

    deinit {
        close()
    }

    /// Close the pidfile handle and release the flock.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        if fd >= 0 {
            #if !os(Windows)
            Darwin_or_Glibc_close(fd)
            #endif
            fd = -1
        }
    }

    /// Take the exclusive lock and record the current PID.
    ///
    /// - `PidFile` — lock acquired; hold the returned guard.
    /// - `nil` — another live process holds the lock (caller should exit cleanly).
    /// - throws — an I/O error opening or locking the file.
    public static func acquire(path: String) throws -> PidFile? {
        let fd = try daemonFileOpen(path: path, flags: O_RDWR | O_CREAT, mode: S_IRUSR | S_IWUSR)

        #if !os(Windows)
        let flockResult = flock(fd, LOCK_EX | LOCK_NB)
        if flockResult != 0 {
            let err = errno
            Darwin_or_Glibc_close(fd)
            if err == EWOULDBLOCK || err == EAGAIN {
                return nil
            }
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }

        // PID contents are advisory diagnostics; the flock provides exclusion.
        // `ftruncate(fd, 0)` clears any stale (possibly longer) value first.
        if ftruncate(fd, 0) != 0 {
            let err = errno
            Darwin_or_Glibc_close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }

        let pidStr = "\(getpid())\n"
        let data = pidStr.utf8
        let bytesWritten = pidStr.withCString { ptr in
            write(fd, ptr, data.count)
        }
        if bytesWritten < 0 {
            let err = errno
            Darwin_or_Glibc_close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
        fsync(fd)
        #endif

        return PidFile(fd: fd, path: path)
    }

    /// Acquire the lock, taking over from a live predecessor workspace-server
    /// if one holds it: graceful termination (SIGTERM), `grace` to release the lock,
    /// then a forceful kill (SIGKILL). The lock is never bypassed — a guard is
    /// returned only with the flock held.
    public static func acquireOrTakeOver(path: String, grace: TimeInterval = TAKEOVER_GRACE) throws -> PidFile? {
        try acquireOrTakeOverMatching(path: path, grace: grace, nameFragment: WORKSPACE_SERVER_NAME_FRAGMENT)
    }

    /// `acquireOrTakeOver` with an injectable name fragment so tests can match
    /// their own predecessor processes.
    public static func acquireOrTakeOverMatching(
        path: String,
        grace: TimeInterval,
        nameFragment: String
    ) throws -> PidFile? {
        if let guardFile = try acquire(path: path) {
            return guardFile
        }

        guard let pid = readPidfilePid(path) else {
            return nil
        }
        if pid == getpid() {
            return nil
        }
        guard let predecessor = PredecessorTarget.open(pid: pid, fragment: nameFragment) else {
            return nil
        }

        fputs("taking over from predecessor workspace-server (pid \(pid))\n", stderr)
        do {
            try predecessor.signal(forceful: false)
        } catch {
            fputs("failed to signal predecessor (pid \(pid)): \(error)\n", stderr)
        }

        if let guardFile = try pollAcquire(path: path, budget: grace) {
            return guardFile
        }

        fputs("predecessor (pid \(pid)) did not release the pidfile lock in time; killing it\n", stderr)
        do {
            try predecessor.signal(forceful: true)
        } catch {
            fputs("failed to kill predecessor (pid \(pid)): \(error)\n", stderr)
        }

        if let guardFile = try pollAcquire(path: path, budget: TAKEOVER_KILL_GRACE) {
            return guardFile
        }

        fputs("pidfile lock is still held after killing pid \(pid); exiting\n", stderr)
        return nil
    }

    /// Retry `acquire` until it succeeds or `budget` elapses.
    public static func pollAcquire(path: String, budget: TimeInterval) throws -> PidFile? {
        let deadline = Date().addingTimeInterval(budget)
        while true {
            if let guardFile = try acquire(path: path) {
                return guardFile
            }
            if Date() >= deadline {
                return nil
            }
            Thread.sleep(forTimeInterval: TAKEOVER_POLL)
        }
    }
}

// MARK: - Helpers

@inline(__always)
private func Darwin_or_Glibc_close(_ fd: Int32) {
    #if canImport(Darwin)
    Darwin.close(fd)
    #elseif canImport(Glibc)
    Glibc.close(fd)
    #endif
}

/// Advisory PID recorded in the pidfile by its holder; `nil` if unreadable
/// or not a positive integer.
public func readPidfilePid(_ path: String) -> pid_t? {
    guard let str = try? String(contentsOfFile: path, encoding: .utf8) else {
        return nil
    }
    let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let pid = pid_t(trimmed), pid > 0 else {
        return nil
    }
    return pid
}

/// True if the basename of `name` (path separators `/` and `\` both count)
/// contains `fragment`. Matching the basename rather than the whole path
/// keeps a directory component like `/var/lib/workspace-server-data/foo` from
/// satisfying the kill gate.
public func basenameContains(name: String, fragment: String) -> Bool {
    let components = name.split { $0 == "/" || $0 == "\\" }
    guard let last = components.last else { return false }
    return String(last).lowercased().contains(fragment.lowercased())
}

// MARK: - Predecessor Target

/// Verified target handle for predecessor process signaling.
public struct PredecessorTarget: Sendable {
    public let pid: pid_t

    /// Pin `pid` and verify its executable basename matches `fragment`.
    /// Returns `nil` if the process is gone, inaccessible, or not a match.
    public static func open(pid: pid_t, fragment: String) -> PredecessorTarget? {
        #if canImport(Darwin)
        var buffer = [CChar](repeating: 0, count: 4096)
        let ret = sys_proc_pidpath(Int32(pid), &buffer, UInt32(buffer.count))
        if ret > 0 {
            let procPath = String(cString: buffer)
            if !fragment.isEmpty && !basenameContains(name: procPath, fragment: fragment) {
                return nil
            }
            return PredecessorTarget(pid: pid)
        } else {
            // Fallback: check kill(pid, 0)
            if kill(pid, 0) == 0 || errno == EPERM {
                if fragment.isEmpty {
                    return PredecessorTarget(pid: pid)
                }
            }
            return nil
        }
        #elseif os(Linux)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: "/proc/\(pid)/cmdline")) else {
            return nil
        }
        let argv0Bytes = data.prefix { $0 != 0 }
        guard let argv0 = String(data: argv0Bytes, encoding: .utf8) else {
            return nil
        }
        if !fragment.isEmpty && !basenameContains(name: argv0, fragment: fragment) {
            return nil
        }
        return PredecessorTarget(pid: pid)
        #else
        return nil
        #endif
    }

    /// Deliver graceful (SIGTERM) or forceful (SIGKILL) termination to the
    /// target process. Already dead is treated as success.
    public func signal(forceful: Bool) throws {
        #if !os(Windows)
        let sig = forceful ? SIGKILL : SIGTERM
        let ret = kill(pid, sig)
        if ret == 0 {
            return
        }
        let err = errno
        if err == ESRCH {
            // Already dead is OK.
            return
        }
        throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        #endif
    }
}
