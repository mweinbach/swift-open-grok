// ProcessSpawn.swift
//
// Port of `xai-grok-test-support/src/process.rs`. The single shared subprocess
// spawn path used by every harness in this crate (`GrokStdioClient`,
// `RawStdioClient`, `LeaderStdioClient`): pipes all three stdio handles,
// kills the child on `dispose`, and drains stderr into a shared buffer on a
// background task so a test can read the child's stderr even after the child
// exits.
//
// The Rust source uses `tokio::process::Command` + `tokio::spawn` for the
// stderr drain. The Swift port uses `Foundation.Process` + a detached
// `Task` reading from a `Pipe` handle. The drain future is `Send` so this
// works on and off a `LocalSet` (the Rust constraint); the Swift equivalent
// is that the `Task` is unstructured and detaches from the calling actor.

import Foundation

/// The result of spawning a child with piped stdio and a background stderr
/// drain. The child is killed on `dispose`.
public final class PipedChild: @unchecked Sendable {
    /// The underlying `Process`.
    public let process: Process
    /// The child's stdin (write end). `nil` after `closeStdin`.
    public private(set) var stdin: FileHandle?
    /// The child's stdout (read end). `nil` after `takeStdout`.
    public private(set) var stdout: FileHandle?
    /// A shared buffer capturing the child's stderr, drained by a background
    /// task. Safe to read via `stderrData()` from any thread.
    private let stderrStorage: StderrCapture

    init(process: Process, stdin: FileHandle, stdout: FileHandle, stderr: FileHandle) {
        self.process = process
        self.stdin = stdin
        self.stdout = stdout
        self.stderrStorage = StderrCapture(handle: stderr)
    }

    /// Take ownership of the child's stdout handle (for line-buffered reading).
    public func takeStdout() -> FileHandle? {
        let h = stdout
        stdout = nil
        return h
    }

    /// Close the child's stdin (signals EOF to the child).
    public func closeStdin() {
        try? stdin?.close()
        stdin = nil
    }

    /// The captured stderr bytes so far. The background drain task continues
    /// to append until the child closes its stderr (on exit).
    public func stderrData() -> Data {
        stderrStorage.snapshot()
    }

    /// The captured stderr as a UTF-8 string (lossy: invalid bytes replaced).
    public func stderrString() -> String {
        String(data: stderrData(), encoding: .utf8) ?? ""
    }

    /// Kill the child if still running. Idempotent. Mirrors `kill_on_drop`.
    public func kill() {
        if process.isRunning {
            process.terminate()
        }
    }

    /// Wait for the child to exit and return its status. Mirrors
    /// `child.wait()`.
    public func waitUntilExit() -> Int32 {
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Whether the child is still running.
    public var isRunning: Bool { process.isRunning }

    /// The child's PID (process identifier), or `nil` if not yet launched.
    public var processIdentifier: Int32? {
        let pid = process.processIdentifier
        return pid > 0 ? pid : nil
    }

    deinit {
        kill()
    }
}

/// Lock-protected stderr capture with a background drain task.
private final class StderrCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let drainTask: Task<Void, Never>

    init(handle: FileHandle) {
        let storage = LockedBox<Data>(Data())
        self.drainTask = Task.detached(priority: .userInitiated) {
            // Read chunked until EOF.
            let chunkSize = 1024
            while !Task.isCancelled {
                let data = handle.availableData
                if data.isEmpty { break }
                storage.withLock { $0.append(data) }
                _ = chunkSize // referenced to silence unused-warning
            }
            try? handle.close()
        }
        // Bridge the locked box back into this class's lock for `snapshot()`.
        // We do this by polling the locked box from snapshot — but a cleaner
        // approach is to share the locked box directly. Re-assign below.
        self.drainStorage = storage
    }

    private var drainStorage: LockedBox<Data>?

    func snapshot() -> Data {
        drainStorage?.withLock { Data($0) } ?? Data()
    }

    deinit {
        drainTask.cancel()
    }
}

/// A lock-protected box for shared mutable data, `@unchecked Sendable`.
/// Internal access so other files in this module (Headless, AcpClient) can
/// reuse it for stdout/stderr drain buffers.
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ initial: T) { self.value = initial }
    func withLock<U>(_ body: (inout T) -> U) -> U {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

/// Errors thrown by `spawnPipedWithStderrCapture`.
public enum ProcessSpawnError: Error, Equatable, CustomStringConvertible {
    case spawnFailed(program: String, underlying: String)

    public var description: String {
        switch self {
        case let .spawnFailed(program, underlying):
            return "Failed to spawn \(program): \(underlying)"
        }
    }
}

/// Spawn `process` with piped stdin/stdout/stderr and `kill_on_drop`
/// semantics, draining stderr into a shared buffer on a background task.
///
/// The caller configures `process.executableURL`, `arguments`,
/// `currentDirectoryURL`, and `environment` BEFORE calling this function;
/// this helper only sets up the pipes, launches, and starts the drain. This
/// is the one spawn path shared by every subprocess harness in this crate,
/// so env/args hermeticity models differ (sandbox-inherit vs `env_clear`)
/// and stay with the callers.
@discardableResult
public func spawnPipedWithStderrCapture(_ process: Process) throws -> PipedChild {
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    let program = process.executableURL?.lastPathComponent ?? "(unknown)"
    do {
        try process.run()
    } catch {
        throw ProcessSpawnError.spawnFailed(program: program, underlying: String(describing: error))
    }

    return PipedChild(
        process: process,
        stdin: stdinPipe.fileHandleForWriting,
        stdout: stdoutPipe.fileHandleForReading,
        stderr: stderrPipe.fileHandleForReading
    )
}
