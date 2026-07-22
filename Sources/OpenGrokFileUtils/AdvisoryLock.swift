// AdvisoryLock.swift
//
// Exclusive advisory file locks for coordinated writers (auth.json.lock,
// managed_config.lock, session journals). Unix uses `flock(LOCK_EX)`;
// Windows exposes a typed seam that returns `unsupported` until a
// LockFileEx adapter lands — never a silent no-op.

import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// An exclusive advisory lock held for the lifetime of this value.
///
/// Release is idempotent: dropping the last reference closes the underlying
/// file descriptor / handle and releases the lock.
public final class AdvisoryLock: @unchecked Sendable {
    public let path: URL
    private var released = false
    private let lock = NSLock()
    #if os(Windows)
    private var handle: FileHandle?
    #else
    private var fd: Int32 = -1
    #endif

    fileprivate init(path: URL) {
        self.path = path
    }

    #if !os(Windows)
    fileprivate func attach(fd: Int32) {
        self.fd = fd
    }
    #else
    fileprivate func attach(handle: FileHandle) {
        self.handle = handle
    }
    #endif

    /// Release the lock early. Safe to call multiple times.
    public func release() {
        lock.lock(); defer { lock.unlock() }
        guard !released else { return }
        released = true
        #if os(Windows)
        try? handle?.close()
        handle = nil
        #else
        if fd >= 0 {
            // LOCK_UN then close — close also drops the flock.
            _ = flock(fd, LOCK_UN)
            close(fd)
            fd = -1
        }
        #endif
    }

    deinit {
        release()
    }
}

/// Advisory lock acquisition options.
public struct AdvisoryLockOptions: Sendable, Equatable {
    /// When true, fail immediately if the lock is held (`LOCK_NB`).
    public var nonBlocking: Bool
    /// Create the lock file if missing (default true).
    public var create: Bool
    /// Unix mode for a newly created lock file (default `0o600`).
    public var mode: UInt32

    public init(nonBlocking: Bool = false, create: Bool = true, mode: UInt32 = 0o600) {
        self.nonBlocking = nonBlocking
        self.create = create
        self.mode = mode
    }
}

/// Acquire exclusive advisory locks on lock files.
public enum AdvisoryFileLock: Sendable {
    /// Acquire an exclusive lock on `path` (typically `*.lock` beside the
    /// protected resource).
    public static func acquire(
        at path: URL,
        options: AdvisoryLockOptions = AdvisoryLockOptions()
    ) throws -> AdvisoryLock {
        #if os(Windows)
        _ = options
        // Explicit unsupported: never claim a lock that is not held.
        throw FileUtilsError.unsupported(
            "Windows LockFileEx advisory locks are not yet wired; refuse silent no-op"
        )
        #else
        try PathSecurity.rejectHostileLexical(path.path)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        var flags: Int32 = O_RDWR
        if options.create {
            flags |= O_CREAT
        }
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(Linux)
        flags |= O_NOFOLLOW
        #endif
        let fd = path.path.withCString { open($0, flags, mode_t(options.mode)) }
        guard fd >= 0 else {
            let detail = String(cString: strerror(errno))
            if errno == ELOOP {
                throw FileUtilsError.symlinkEncountered(path: path.path)
            }
            if errno == ENOENT {
                throw FileUtilsError.notFound(path: path.path)
            }
            if errno == EACCES || errno == EPERM {
                throw FileUtilsError.permissionDenied(path: path.path, detail: detail)
            }
            throw FileUtilsError.io(path: path.path, detail: "open lock: \(detail)")
        }

        // Tighten mode via fchmod (no symlink follow).
        _ = fchmod(fd, mode_t(options.mode))

        var op = LOCK_EX
        if options.nonBlocking {
            op |= LOCK_NB
        }
        if flock(fd, op) != 0 {
            let err = errno
            close(fd)
            let detail = String(cString: strerror(err))
            if err == EWOULDBLOCK || err == EAGAIN {
                throw FileUtilsError.lockFailed(path: path.path, detail: "busy: \(detail)")
            }
            throw FileUtilsError.lockFailed(path: path.path, detail: detail)
        }

        let held = AdvisoryLock(path: path)
        held.attach(fd: fd)
        return held
        #endif
    }

    /// Try to acquire without blocking. Returns `nil` when busy.
    public static func tryAcquire(at path: URL) throws -> AdvisoryLock? {
        do {
            return try acquire(at: path, options: AdvisoryLockOptions(nonBlocking: true))
        } catch let err as FileUtilsError {
            if case .lockFailed(_, let detail) = err, detail.hasPrefix("busy") {
                return nil
            }
            throw err
        }
    }
}
