// MCPStdioTransport.swift
//
// Child-process stdio transport for the MCP client.
//
// Framing is newline-delimited JSON on the child's stdin/stdout, per the MCP
// stdio transport spec: one JSON-RPC message per line, no embedded newlines,
// and stderr reserved for the server's own logging (never protocol traffic).
//
// The `MCPTransport` seam is request/response shaped while stdio is a
// full-duplex stream. Multiple sends can overlap because the transport actor
// becomes reentrant while waiting, so inbound responses must be correlated by
// JSON-RPC id rather than handed to whichever caller happens to read next.

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

/// Accumulates the child's stdout into complete messages and hands responses
/// directly to the waiter registered for their JSON-RPC id. Fed from
/// `FileHandle.readabilityHandler`, which runs on a private dispatch queue,
/// so every access is lock-guarded.
private final class MCPStdioLineSink: @unchecked Sendable {
    private let lock = NSLock()
    private var activeRequests: Set<JsonRpcId> = []
    private var pending: [JsonRpcId: MCPWireMessage] = [:]
    private var buffer = Data()
    private var closed = false
    private var waiters: [JsonRpcId: CheckedContinuation<MCPWireMessage?, Never>] = [:]
    /// Cancellation can run before `withCheckedContinuation` registers.
    private var cancelledRequests: Set<JsonRpcId> = []

    /// Guards against a runaway server emitting one unbounded line.
    private static let maxLineBytes = 32 * 1024 * 1024

    func ingest(_ data: Data) {
        var resumptions: [(CheckedContinuation<MCPWireMessage?, Never>, MCPWireMessage?)] = []

        lock.lock()
        if data.isEmpty {
            closed = true
            resumptions = waiters.values.map { ($0, nil) }
            waiters.removeAll()
        } else {
            buffer.append(data)
            while let index = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer[buffer.startIndex..<index]
                if lineData.count > Self.maxLineBytes {
                    buffer.removeAll(keepingCapacity: false)
                    closed = true
                    break
                }
                buffer.removeSubrange(buffer.startIndex...index)
                let line = String(decoding: lineData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty,
                      let message = try? MCPWireCodec.decodeString(line),
                      case .response(let response) = message,
                      activeRequests.contains(response.id) else {
                    continue
                }
                if let continuation = waiters.removeValue(forKey: response.id) {
                    resumptions.append((continuation, message))
                } else {
                    pending[response.id] = message
                }
            }
            if buffer.count > Self.maxLineBytes {
                buffer.removeAll(keepingCapacity: false)
                closed = true
            }
            if closed {
                resumptions.append(contentsOf: waiters.values.map { ($0, nil) })
                waiters.removeAll()
            }
        }
        lock.unlock()

        for (continuation, message) in resumptions {
            continuation.resume(returning: message)
        }
    }

    func close() {
        ingest(Data())
    }

    func register(_ id: JsonRpcId) {
        lock.lock()
        activeRequests.insert(id)
        lock.unlock()
    }

    func unregister(_ id: JsonRpcId) {
        lock.lock()
        activeRequests.remove(id)
        pending.removeValue(forKey: id)
        cancelledRequests.remove(id)
        let parked = waiters.removeValue(forKey: id)
        lock.unlock()
        parked?.resume(returning: nil)
    }

    /// A timed-out request must unblock its own continuation without waking
    /// or consuming the response for another request on the same transport.
    func cancelWaiter(for id: JsonRpcId) {
        lock.lock()
        let parked = waiters.removeValue(forKey: id)
        if parked == nil, activeRequests.contains(id) {
            cancelledRequests.insert(id)
        }
        lock.unlock()
        parked?.resume(returning: nil)
    }

    /// The matching response, or `nil` if this request is cancelled or the
    /// shared stream closes.
    func nextResponse(for id: JsonRpcId) async -> MCPWireMessage? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<MCPWireMessage?, Never>) in
                lock.lock()
                if let message = pending.removeValue(forKey: id) {
                    lock.unlock()
                    continuation.resume(returning: message)
                    return
                }
                if closed || cancelledRequests.remove(id) != nil {
                    lock.unlock()
                    continuation.resume(returning: nil)
                    return
                }
                waiters[id] = continuation
                lock.unlock()
            }
        } onCancel: {
            cancelWaiter(for: id)
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
    private var pendingRequestIDs: Set<JsonRpcId> = []

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
        #elseif canImport(Glibc)
        _ = signal(SIGPIPE, SIG_IGN)
        #endif
        started = true
    }

    public func send(_ message: MCPWireMessage) async throws -> MCPWireMessage? {
        guard !isClosed else { throw MCPError.transportClosed }
        if !started { try start() }

        var line = try MCPWireCodec.encode(message)
        line.append(UInt8(ascii: "\n"))

        guard case .request(let request) = message else {
            try write(line)
            return nil
        }

        guard pendingRequestIDs.insert(request.id).inserted else {
            throw MCPError.invalidRequest("duplicate MCP request id: \(request.id)")
        }
        sink.register(request.id)
        defer {
            pendingRequestIDs.remove(request.id)
            sink.unregister(request.id)
        }

        try write(line)
        return try await awaitResponse(id: request.id, method: request.method)
    }

    private func write(_ line: Data) throws {
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: line)
        } catch {
            throw MCPError.transport("MCP stdio write failed: \(error.localizedDescription)")
        }
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
        if Date() >= deadline {
            throw MCPError.transport(
                "MCP stdio request '\(method)' timed out after \(Int(configuration.requestTimeout))s"
            )
        }
        let message = try await withThrowingTaskGroup(of: MCPWireMessage?.self) { group in
            let sink = self.sink
            group.addTask { await sink.nextResponse(for: id) }
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
        guard let message else {
            throw MCPError.transport("MCP server closed stdout before answering '\(method)'")
        }
        return message
    }

    private static func resolveExecutable(_ command: String, environment: [String: String]) -> URL {
        if command.contains("/") || command.contains("\\") {
            return URL(fileURLWithPath: command)
        }

        #if os(Windows)
        let searchPath = environment["PATH"] ?? ""
        var candidateNames = [command]
        if URL(fileURLWithPath: command).pathExtension.isEmpty {
            let executableExtensions = (environment["PATHEXT"] ?? ".COM;.EXE")
                .split(separator: ";")
                .map(String.init)
                .filter { !$0.isEmpty }
            candidateNames.append(contentsOf: executableExtensions.map { command + $0 })
        }
        for rawDirectory in searchPath.split(separator: ";") where !rawDirectory.isEmpty {
            let directory = rawDirectory.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            for name in candidateNames {
                let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        #else
        let searchPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin"
        for directory in searchPath.split(separator: ":") where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        #endif
        // Let `Process.run` surface the not-found error with the real name.
        return URL(fileURLWithPath: command)
    }
}
