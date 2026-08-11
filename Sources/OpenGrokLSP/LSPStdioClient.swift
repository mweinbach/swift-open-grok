import Foundation
import OpenGrokShared

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private final class LSPMessageBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var closed = false
    private var waiter: CheckedContinuation<Data?, Never>?
    private var cancelPending = false

    func ingest(_ data: Data) {
        var resume: CheckedContinuation<Data?, Never>?
        var value: Data?

        lock.lock()
        if data.isEmpty {
            closed = true
            resume = waiter
            waiter = nil
            value = takeNextLocked()
        } else {
            buffer.append(data)
            if let continuation = waiter, let next = takeNextLocked() {
                resume = continuation
                waiter = nil
                value = next
            }
        }
        lock.unlock()

        resume?.resume(returning: value)
    }

    func close() {
        ingest(Data())
    }

    func cancelWaiter() {
        lock.lock()
        let parked = waiter
        waiter = nil
        if parked == nil { cancelPending = true }
        lock.unlock()
        parked?.resume(returning: nil)
    }

    func nextMessage() async -> Data? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
                lock.lock()
                if let next = takeNextLocked() {
                    lock.unlock()
                    continuation.resume(returning: next)
                    return
                }
                if closed || cancelPending {
                    cancelPending = false
                    lock.unlock()
                    continuation.resume(returning: nil)
                    return
                }
                waiter?.resume(returning: nil)
                waiter = continuation
                lock.unlock()
            }
        } onCancel: {
            cancelWaiter()
        }
    }

    private func takeNextLocked() -> Data? {
        LSPMessageFraming.takeMessage(from: &buffer)
    }
}

public struct LSPStdioClientConfiguration: Sendable, Equatable {
    public var command: String
    public var arguments: [String]
    public var environment: [String: String]?
    public var currentDirectoryPath: String?
    public var requestTimeout: TimeInterval

    public init(
        command: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectoryPath: String? = nil,
        requestTimeout: TimeInterval = 10
    ) {
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.currentDirectoryPath = currentDirectoryPath
        self.requestTimeout = requestTimeout
    }
}

public actor LSPStdioClient {
    private let configuration: LSPStdioClientConfiguration
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let buffer = LSPMessageBuffer()
    private var started = false
    private var closed = false
    private var nextRequestID = 1
    private var pendingResponses: [Int: CheckedContinuation<LSPJSONRPCResponse, Error>] = [:]

    public init(configuration: LSPStdioClientConfiguration) {
        self.configuration = configuration
    }

    public func start() async throws {
        guard !started else { return }
        guard !closed else { throw LSPError.transportClosed }

        process.executableURL = URL(fileURLWithPath: configuration.command)
        process.arguments = configuration.arguments
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

        let buffer = self.buffer
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            buffer.ingest(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        process.terminationHandler = { _ in
            buffer.close()
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            closed = true
            throw LSPError.transport("unable to launch LSP server '\(configuration.command)': \(error.localizedDescription)")
        }

        #if canImport(Darwin)
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        #else
        _ = signal(SIGPIPE, SIG_IGN)
        #endif

        started = true
        Task { await self.readLoop() }
    }

    public func request(method: String, params: JSONValue? = nil) async throws -> JSONValue {
        if !started { try await start() }
        guard !closed else { throw LSPError.transportClosed }

        let requestID = nextID()
        let body = try LSPJSONRPCRequest(id: requestID, method: method, params: params).encoded()
        let packet = LSPMessageFraming.encode(body)
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: packet)
        } catch {
            throw LSPError.transport("LSP stdio write failed: \(error.localizedDescription)")
        }

        let response = try await withThrowingTaskGroup(of: LSPJSONRPCResponse.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    Task { await self.storeContinuation(continuation, for: requestID) }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(self.configuration.requestTimeout * 1_000_000_000))
                throw LSPError.timeout(method: method)
            }
            guard let first = try await group.next() else {
                throw LSPError.transport("LSP request ended without a response")
            }
            group.cancelAll()
            return first
        }

        switch response {
        case .result(_, let value):
            return value
        case .error(_, let code, let message):
            if code == LSPJSONRPCErrorCode.methodNotFound {
                throw LSPError.methodNotFound(message)
            }
            throw LSPError.server("LSP error \(code): \(message)")
        }
    }

    private func request(_ request: LSPJSONRPCRequest) async throws -> JSONValue {
        try await self.request(method: request.method, params: request.params)
    }

    public func notify(_ notification: LSPJSONRPCNotification) async throws {
        if !started { try await start() }
        guard !closed else { throw LSPError.transportClosed }
        let body = try notification.encoded()
        let packet = LSPMessageFraming.encode(body)
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: packet)
        } catch {
            throw LSPError.transport("LSP stdio write failed: \(error.localizedDescription)")
        }
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        buffer.close()
        if process.isRunning {
            process.terminate()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                process.terminationHandler = { _ in
                    continuation.resume()
                }
            }
        }
        failPending(with: LSPError.transportClosed)
    }

    private func readLoop() async {
        while !closed {
            guard let data = await buffer.nextMessage() else {
                if !process.isRunning {
                    closed = true
                    failPending(with: LSPError.transportClosed)
                }
                continue
            }
            do {
                let message = try LSPJSONRPCResponse.decode(from: data)
                await deliver(message)
            } catch {
                continue
            }
        }
    }

    private func storeContinuation(
        _ continuation: CheckedContinuation<LSPJSONRPCResponse, Error>,
        for id: Int
    ) {
        pendingResponses[id] = continuation
    }

    private func deliver(_ message: LSPJSONRPCResponse) {
        switch message {
        case .result(let id, _):
            if let continuation = pendingResponses.removeValue(forKey: id) {
                continuation.resume(returning: message)
            }
        case .error(let id, _, _):
            if let id, let continuation = pendingResponses.removeValue(forKey: id) {
                continuation.resume(returning: message)
            }
        }
    }

    private func failPending(with error: Error) {
        let pending = pendingResponses
        pendingResponses.removeAll()
        for continuation in pending.values {
            continuation.resume(throwing: error)
        }
    }
}

extension LSPStdioClient {
    public func initialize(rootURI: String) async throws {
        let params: JSONValue = .object([
            "processId": .null,
            "rootUri": .string(rootURI),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string("open-grok"),
                "version": .string("0.0.0"),
            ]),
        ])
        _ = try await request(
            method: "initialize",
            params: params
        )
        try await notify(LSPJSONRPCNotification(method: "initialized"))
    }

    private func nextID() -> Int {
        defer { nextRequestID += 1 }
        return nextRequestID
    }
}
