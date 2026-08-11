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

/// Exactly-once bridge from a `terminationHandler` callback to a continuation.
///
/// Both orderings have to work: the handler firing after the continuation is
/// armed, and the child already being dead before we look. Resuming a checked
/// continuation twice traps and resuming it zero times hangs, so the guard is
/// the whole point.
private final class TerminationOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var fired = false

    func arm(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if fired {
            lock.unlock()
            continuation.resume()
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func fire() {
        lock.lock()
        if fired {
            lock.unlock()
            return
        }
        fired = true
        let parked = continuation
        continuation = nil
        lock.unlock()
        parked?.resume()
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
    private var notificationHandler: (@Sendable (String, JSONValue?) async -> Void)?

    public init(configuration: LSPStdioClientConfiguration) {
        self.configuration = configuration
    }

    /// Route server notifications (e.g. `textDocument/publishDiagnostics`).
    public func setNotificationHandler(
        _ handler: (@Sendable (String, JSONValue?) async -> Void)?
    ) {
        notificationHandler = handler
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

        // The timeout is a plain task, not a task-group sibling. A group does
        // not return until every child finishes, and the child parked in
        // `withCheckedThrowingContinuation` is not cancellable — so
        // `cancelAll()` on timeout left the group waiting forever for a child
        // nothing could resume. That converts a slow server into a permanent
        // hang, which is strictly worse than the timeout it was implementing.
        let timeout = configuration.requestTimeout
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.failPending(id: requestID, with: LSPError.timeout(method: method))
        }
        defer { timeoutTask.cancel() }

        // Register the pending slot and write in the SAME actor-isolated step.
        // Storing it through `Task { await self.storeContinuation(...) }` after
        // the write let a fast server's response reach `deliver` while
        // `pendingResponses` was still empty: the response was dropped, and the
        // continuation stored a moment later had nothing left to resume it.
        let response: LSPJSONRPCResponse = try await withCheckedThrowingContinuation { continuation in
            pendingResponses[requestID] = continuation
            do {
                try stdinPipe.fileHandleForWriting.write(contentsOf: packet)
            } catch {
                if let pending = pendingResponses.removeValue(forKey: requestID) {
                    pending.resume(throwing: LSPError.transport(
                        "LSP stdio write failed: \(error.localizedDescription)"
                    ))
                }
            }
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
            // This await used to be unbounded, and it hung the Linux CI suite
            // until the wrapper's ceiling: `terminate()` returned, the child
            // survived, and `terminationHandler` never fired, so nothing ever
            // resumed the continuation.
            //
            // Three separate hazards, all closed here rather than reasoned
            // away, because §2's rule is not to trust a death notification:
            //   1. The handler was installed AFTER `terminate()`. If the child
            //      dies in between, the notification is already spent and the
            //      new handler never runs.
            //   2. The child may already be dead when we look, so `isRunning`
            //      is re-checked once the handler is in place.
            //   3. SIGTERM may simply not land. The child is escalated to
            //      SIGKILL, and the waiter is released unconditionally after
            //      that.
            //
            // Cost: on a child that survives both signals, `close()` returns
            // after ~4s without having reaped it, so a caller cannot treat
            // return as proof the child is gone. That is the right trade — a
            // leaked child is recoverable, a wedged suite is not. Do not
            // "simplify" this back to awaiting the handler alone.
            let once = TerminationOnce()
            let pid = process.processIdentifier
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                once.arm(continuation)
                process.terminationHandler = { _ in once.fire() }
                if !process.isRunning { once.fire() }
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    kill(pid, SIGKILL)
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        once.fire()
                    }
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
                switch try LSPInboundMessage.decode(from: data) {
                case .response(let message):
                    deliver(message)
                case .notification(let method, let params):
                    if let notificationHandler {
                        await notificationHandler(method, params)
                    }
                }
            } catch {
                continue
            }
        }
    }

    private func failPending(id: Int, with error: Error) {
        if let continuation = pendingResponses.removeValue(forKey: id) {
            continuation.resume(throwing: error)
        }
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
    /// Client capabilities advertised at initialize.
    ///
    /// Rust reference: `client.rs` `client_capabilities` — sync, publish,
    /// and pull diagnostic support. Hover/goto omitted in this slice.
    public static var clientCapabilities: JSONValue {
        .object([
            "textDocument": .object([
                "synchronization": .object([
                    "dynamicRegistration": .bool(false),
                    "willSave": .bool(false),
                    "willSaveWaitUntil": .bool(false),
                    "didSave": .bool(true),
                ]),
                "publishDiagnostics": .object([
                    "relatedInformation": .bool(true),
                ]),
                "diagnostic": .object([
                    "dynamicRegistration": .bool(false),
                    "relatedDocumentSupport": .bool(false),
                ]),
            ]),
            "workspace": .object([
                "diagnostic": .object([
                    "refreshSupport": .bool(true),
                ]),
            ]),
        ])
    }

    public func initialize(rootURI: String) async throws {
        let params: JSONValue = .object([
            "processId": .null,
            "rootUri": .string(rootURI),
            "capabilities": Self.clientCapabilities,
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
