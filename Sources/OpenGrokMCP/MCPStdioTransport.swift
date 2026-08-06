// MCPStdioTransport.swift
//
// Child-process stdio transport for the MCP client.
//
// Framing is newline-delimited JSON on the child's stdin/stdout, per the MCP
// stdio transport spec: one JSON-RPC message per line, no embedded newlines,
// and stderr reserved for the server's own logging (never protocol traffic).
//
// The `MCPTransport` seam is request/response shaped while stdio is a
// full-duplex stream, so `send` writes the line and then drains inbound lines
// until the response whose id matches the request arrives. Server-initiated
// notifications and requests seen while draining are discarded rather than
// treated as protocol errors — a server that logs progress mid-call must not
// break the caller.

import Foundation
import OpenGrokSandbox
import OpenGrokToolProtocol

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct MCPStdioTransportConfiguration: Sendable, Equatable {
    /// Executable to spawn. Resolved through `PATH` when not an absolute path.
    public var command: String
    public var arguments: [String]
    /// Extra variables layered over the inherited environment. `nil` inherits
    /// the parent environment unchanged.
    public var environment: [String: String]?
    public var currentDirectoryPath: String?
    /// Per-request ceiling. A server that never answers must not wedge a turn.
    public var requestTimeout: TimeInterval

    public init(
        command: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectoryPath: String? = nil,
        requestTimeout: TimeInterval = 60
    ) {
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.currentDirectoryPath = currentDirectoryPath
        self.requestTimeout = requestTimeout
    }
}

// MARK: - Line sink

/// Accumulates the child's stdout into whole lines and hands them to at most
/// one waiter at a time. Fed from `FileHandle.readabilityHandler`, which runs
/// on a private dispatch queue, so every access is lock-guarded.
private final class MCPStdioLineSink: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String] = []
    private var buffer = Data()
    private var closed = false
    private var waiter: CheckedContinuation<String?, Never>?
    /// Set when a waiter is cancelled before it managed to register, so the
    /// continuation resumes immediately instead of parking forever.
    private var cancelPending = false

    /// Guards against a runaway server emitting one unbounded line.
    private static let maxLineBytes = 32 * 1024 * 1024

    func ingest(_ data: Data) {
        var resume: CheckedContinuation<String?, Never>?
        var value: String?

        lock.lock()
        if data.isEmpty {
            closed = true
            resume = waiter
            waiter = nil
            value = pending.isEmpty ? nil : pending.removeFirst()
        } else {
            buffer.append(data)
            if buffer.count > Self.maxLineBytes {
                buffer.removeAll(keepingCapacity: false)
                closed = true
            }
            while let index = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer[buffer.startIndex..<index]
                buffer.removeSubrange(buffer.startIndex...index)
                let line = String(decoding: lineData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty { pending.append(line) }
            }
            if let continuation = waiter, !pending.isEmpty {
                resume = continuation
                waiter = nil
                value = pending.removeFirst()
            }
        }
        lock.unlock()

        resume?.resume(returning: value)
    }

    func close() {
        ingest(Data())
    }

    /// Resume any parked waiter with `nil`. Called when the surrounding task is
    /// cancelled — a `CheckedContinuation` is not itself cancellable, so
    /// without this a timed-out read would keep its task group alive until the
    /// child process happened to exit.
    func cancelWaiter() {
        lock.lock()
        let parked = waiter
        waiter = nil
        if parked == nil { cancelPending = true }
        lock.unlock()
        parked?.resume(returning: nil)
    }

    /// Next complete line, or `nil` once the stream is drained and closed (or
    /// the calling task is cancelled).
    func nextLine() async -> String? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                lock.lock()
                if !pending.isEmpty {
                    let line = pending.removeFirst()
                    lock.unlock()
                    continuation.resume(returning: line)
                    return
                }
                if closed || cancelPending {
                    cancelPending = false
                    lock.unlock()
                    continuation.resume(returning: nil)
                    return
                }
                // A second concurrent waiter would be a caller bug; the
                // transport actor serialises `send`, so only one can exist.
                waiter?.resume(returning: nil)
                waiter = continuation
                lock.unlock()
            }
        } onCancel: {
            cancelWaiter()
        }
    }
}

// MARK: - Transport

public actor MCPStdioTransport: MCPTransport {
    private let configuration: MCPStdioTransportConfiguration
    private let launchTransform: ChildLaunchTransform
    private let process: Process
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let sink = MCPStdioLineSink()
    private var started = false
    private var isClosed = false

    public init(
        configuration: MCPStdioTransportConfiguration,
        launchTransform: @escaping ChildLaunchTransform = childNetworkRestrictedLaunch
    ) {
        self.configuration = configuration
        self.launchTransform = launchTransform
        self.process = Process()
    }

    /// Spawns the child. Safe to call repeatedly; only the first call starts it.
    public func start() throws {
        guard !started else { return }
        guard !isClosed else { throw MCPError.transportClosed }

        let resolvedExecutable = Self.resolveExecutable(
            configuration.command,
            environment: configuration.environment ?? ProcessInfo.processInfo.environment
        )
        let launch: (executable: String, arguments: [String])
        do {
            launch = try launchTransform(resolvedExecutable.path, configuration.arguments)
        } catch {
            isClosed = true
            throw MCPError.transport(
                "unable to launch MCP server '\(configuration.command)': (error)"
            )
        }
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        if let environment = configuration.environment {
            var merged = ProcessInfo.processInfo.environment
            for (key, value) in environment { merged[key] = value }
            process.environment = merged
        }
        if let cwd = configuration.currentDirectoryPath {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let sink = self.sink
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            sink.ingest(handle.availableData)
        }
        // Drain stderr so a chatty server cannot fill the pipe and deadlock.
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        process.terminationHandler = { _ in
            sink.close()
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            isClosed = true
            throw MCPError.transport(
                "unable to launch MCP server '\(configuration.command)': \(error.localizedDescription)"
            )
        }
        // A server that has already exited leaves a closed read end; writing to
        // it must return EPIPE rather than raising SIGPIPE and killing us.
        #if canImport(Darwin)
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        #else
        _ = signal(SIGPIPE, SIG_IGN)
        #endif
        started = true
    }

    public func send(_ message: MCPWireMessage) async throws -> MCPWireMessage? {
        guard !isClosed else { throw MCPError.transportClosed }
        if !started { try start() }

        var line = try MCPWireCodec.encode(message)
        line.append(UInt8(ascii: "\n"))
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: line)
        } catch {
            throw MCPError.transport("MCP stdio write failed: \(error.localizedDescription)")
        }

        guard case .request(let request) = message else { return nil }
        return try await awaitResponse(id: request.id, method: request.method)
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        try? stdinPipe.fileHandleForWriting.close()
        if started && process.isRunning {
            process.terminate()
        }
        sink.close()
    }

    /// Exit status once the child has terminated, `nil` while it is running.
    public func terminationStatus() -> Int32? {
        guard started, !process.isRunning else { return nil }
        return process.terminationStatus
    }

    // MARK: Internals

    private func awaitResponse(id: JsonRpcId, method: String) async throws -> MCPWireMessage {
        let deadline = Date().addingTimeInterval(configuration.requestTimeout)
        while true {
            if Date() >= deadline {
                throw MCPError.transport(
                    "MCP stdio request '\(method)' timed out after \(Int(configuration.requestTimeout))s"
                )
            }
            let line = try await withThrowingTaskGroup(of: String?.self) { group in
                let sink = self.sink
                group.addTask { await sink.nextLine() }
                group.addTask {
                    let remaining = deadline.timeIntervalSinceNow
                    if remaining > 0 {
                        try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                    }
                    throw MCPError.transport(
                        "MCP stdio request '\(method)' timed out after \(Int(self.configuration.requestTimeout))s"
                    )
                }
                let first = try await group.next()
                group.cancelAll()
                return first ?? nil
            }
            guard let line else {
                throw MCPError.transport("MCP server closed stdout before answering '\(method)'")
            }
            // A malformed line is the server's problem, not a reason to abort
            // the call: skip it and keep draining toward our response.
            guard let decoded = try? MCPWireCodec.decodeString(line) else { continue }
            guard case .response(let response) = decoded, response.id == id else { continue }
            return decoded
        }
    }

    private static func resolveExecutable(_ command: String, environment: [String: String]) -> URL {
        if command.contains("/") {
            return URL(fileURLWithPath: command)
        }
        let searchPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin"
        for directory in searchPath.split(separator: ":") where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        // Let `Process.run` surface the not-found error with the real name.
        return URL(fileURLWithPath: command)
    }
}
