// ACPStdioHost.swift
//
// Running an `ACPAgentRuntime` over real process stdin/stdout.
//
// `ACPWireTransport.swift` already supplies the framing (`ACPStdioTransport`:
// one JSON-RPC object per line) and the injection seam (`ACPLineIO`). What was
// missing is a conformer bound to the actual process handles, which is what
// `agent stdio` needs. This file adds that, plus a small host that owns the
// reader thread's lifetime.
//
// Rust reference (`/Users/mweinbach/Projects/grok-build`):
//
//   * `crates/codegen/xai-acp-lib/src/stdin_reader.rs:1-60`
//     (`spawn_stdin_line_reader`) — upstream reads stdin on a dedicated OS
//     thread doing blocking `std::io` line reads and forwards complete lines
//     into the async runtime. The comment there is explicit that this is not
//     an optimization: `tokio::io::stdin()` cannot be reliably cancelled, and
//     on Windows a redirected pipe only flushes at EOF otherwise. The same
//     constraint applies here — a blocking `read(2)` must never run on a
//     Swift concurrency cooperative thread — so this port also uses a
//     dedicated `Thread`.
//   * `crates/codegen/xai-grok-shell/src/agent/app.rs:290-334`
//     (`run_stdio_agent`) — stdout is the outgoing writer and stdin stays open
//     for the life of the session; the process exits when stdin reaches EOF.
//   * Framing is newline-delimited JSON-RPC 2.0 (same file), which is what
//     `ACPStdioTransport` implements.
//
// Not ported: upstream's `normalize_json_line` escaped-slash workaround
// (`xai-acp-lib/src/normalize.rs`), which exists for a specific ACP 0.6
// client quirk, and the Linux `PR_SET_PDEATHSIG` parent-death binding
// (`app.rs:296-311`), which has no macOS equivalent and no Linux consumer in
// this port yet.

import Foundation

#if os(Windows)
import WinSDK
#endif

// MARK: - Line mailbox

/// Hand-off point between the blocking reader thread and the async loop.
///
/// The thread only ever calls `deliver`/`finish` (both non-isolated entry
/// points that hop onto the actor); the async side only ever awaits `next()`.
actor ACPLineMailbox {
    private var pending: [String] = []
    private var waiter: CheckedContinuation<String?, Never>?
    private var finished = false

    func deliver(_ line: String) {
        guard !finished else { return }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: line)
        } else {
            pending.append(line)
        }
    }

    /// Close the mailbox. Queued lines are still drained before `next()`
    /// starts reporting end-of-stream, so a final message that arrived with
    /// the EOF is not dropped.
    func finish() {
        guard !finished else { return }
        finished = true
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: nil)
        }
    }

    func next() async -> String? {
        if !pending.isEmpty { return pending.removeFirst() }
        if finished { return nil }
        return await withCheckedContinuation { continuation in
            if !pending.isEmpty {
                continuation.resume(returning: pending.removeFirst())
            } else if finished {
                continuation.resume(returning: nil)
            } else {
                waiter = continuation
            }
        }
    }
}

// MARK: - Standard IO

/// `ACPLineIO` bound to real file descriptors.
///
/// Reads run on a dedicated thread so a blocking `read(2)` can never stall a
/// cooperative executor thread. Writes are serialized through an actor because
/// two concurrent notifications must not interleave halfway through a line.
public struct ACPStandardIO: ACPLineIO {
    private let mailbox: ACPLineMailbox
    private let writer: ACPLineWriter
    private let reader: ACPLineReader

    /// Bind to the process's own stdin/stdout.
    public init() {
        self.init(input: .standardInput, output: .standardOutput)
    }

    /// Bind to arbitrary file handles. Tests use a pair of `Pipe` instances;
    /// the production path uses `init()`.
    public init(input: FileHandle, output: FileHandle) {
        let mailbox = ACPLineMailbox()
        self.mailbox = mailbox
        #if os(Windows)
        self.writer = ACPLineWriter(handle: output)
        self.reader = ACPLineReader(handle: input, mailbox: mailbox)
        #else
        self.writer = ACPLineWriter(descriptor: output.fileDescriptor)
        self.reader = ACPLineReader(descriptor: input.fileDescriptor, mailbox: mailbox)
        #endif
        reader.start()
    }

    /// Bind to arbitrary descriptors on POSIX hosts.
    #if !os(Windows)
    public init(input: Int32, output: Int32) {
        let mailbox = ACPLineMailbox()
        self.mailbox = mailbox
        self.writer = ACPLineWriter(descriptor: output)
        self.reader = ACPLineReader(descriptor: input, mailbox: mailbox)
        reader.start()
    }
    #endif

    public func readLine() async throws -> String? {
        // A blank line is not a protocol violation, just noise from a client
        // that terminates its frames generously. Skipping here keeps
        // `ACPStdioTransport.receive()` from raising `.invalidLine` and
        // tearing the session down over a stray newline.
        while let line = await mailbox.next() {
            if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return line }
        }
        return nil
    }

    public func writeLine(_ line: String) async throws {
        try await writer.write(line + "\n")
    }

    public func close() async {
        reader.stop()
        await mailbox.finish()
    }
}

/// Serializes writes to one descriptor.
private actor ACPLineWriter {
    #if os(Windows)
    private let handle: FileHandle

    init(handle: FileHandle) { self.handle = handle }
    #else
    private let descriptor: Int32

    init(descriptor: Int32) { self.descriptor = descriptor }
    #endif

    func write(_ string: String) throws {
        let bytes = Array(string.utf8)
        var offset = 0
        while offset < bytes.count {
            #if os(Windows)
            var count: DWORD = 0
            let succeeded = bytes.withUnsafeBytes { buffer in
                WriteFile(
                    handle._handle,
                    buffer.baseAddress! + offset,
                    DWORD(buffer.count - offset),
                    &count,
                    nil
                )
            }
            guard succeeded, count > 0 else { throw ACPTransportError.closed }
            offset += Int(count)
            #else
            let written = bytes.withUnsafeBytes { buffer in
                Foundation.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
            }
            if written > 0 {
                offset += written
                continue
            }
            if written < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            throw ACPTransportError.closed
            #endif
        }
    }
}

/// Owns the blocking reader thread.
///
/// `@unchecked Sendable` with an `NSLock`-guarded stop flag: the thread body
/// and `stop()` are the only two things touching it, and the descriptor is
/// read-only after construction.
private final class ACPLineReader: @unchecked Sendable {
    #if os(Windows)
    private let handle: FileHandle
    #else
    private let descriptor: Int32
    #endif
    private let mailbox: ACPLineMailbox
    private let lock = NSLock()
    private var stopped = false

    #if os(Windows)
    init(handle: FileHandle, mailbox: ACPLineMailbox) {
        self.handle = handle
        self.mailbox = mailbox
    }
    #else
    init(descriptor: Int32, mailbox: ACPLineMailbox) {
        self.descriptor = descriptor
        self.mailbox = mailbox
    }
    #endif

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        #if os(Windows)
        _ = CancelIoEx(handle._handle, nil)
        #endif
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "acp-stdin-reader"
        thread.stackSize = 512 * 1024
        thread.start()
    }

    private func run() {
        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while !isStopped {
            #if os(Windows)
            var requestedCount = chunk.count
            if GetFileType(handle._handle) == FILE_TYPE_PIPE {
                var available: DWORD = 0
                let peeked = PeekNamedPipe(handle._handle, nil, 0, nil, &available, nil)
                if !peeked { break }
                if available == 0 {
                    Sleep(10)
                    continue
                }
                requestedCount = min(requestedCount, Int(available))
            }
            var count: DWORD = 0
            let succeeded = chunk.withUnsafeMutableBytes { pointer in
                ReadFile(handle._handle, pointer.baseAddress, DWORD(requestedCount), &count, nil)
            }
            if !succeeded {
                if GetLastError() == ERROR_BROKEN_PIPE { break }
                break
            }
            let byteCount = Int(count)
            #else
            let count = chunk.withUnsafeMutableBytes { pointer in
                read(descriptor, pointer.baseAddress, pointer.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                break
            }
            let byteCount = count
            #endif
            if byteCount == 0 { break }
            buffer.append(contentsOf: chunk[0..<byteCount])
            deliverCompleteLines(from: &buffer)
        }
        // A client that closes without a trailing newline still sent a frame.
        if !buffer.isEmpty {
            let line = String(decoding: buffer, as: UTF8.self)
            deliver(line)
        }
        finishMailbox()
    }

    private func deliverCompleteLines(from buffer: inout [UInt8]) {
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineBytes = Array(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            // A CRLF client leaves the carriage return behind.
            let trimmed = lineBytes.last == UInt8(ascii: "\r") ? lineBytes.dropLast() : lineBytes[...]
            let line = String(decoding: trimmed, as: UTF8.self)
            deliver(line)
        }
    }

    private func deliver(_ line: String) {
        let completed = DispatchSemaphore(value: 0)
        let mailbox = self.mailbox
        Task {
            await mailbox.deliver(line)
            completed.signal()
        }
        completed.wait()
    }

    private func finishMailbox() {
        let completed = DispatchSemaphore(value: 0)
        let mailbox = self.mailbox
        Task {
            await mailbox.finish()
            completed.signal()
        }
        completed.wait()
    }
}

// MARK: - Host

/// Runs one `ACPAgentRuntime` over a transport until the peer disconnects.
///
/// This exists so callers do not have to reimplement the shutdown ordering:
/// `serve` returns when the transport closes, and `shutdown()` closes the
/// runtime first (so in-flight prompts are cancelled) and then the transport.
public struct ACPStdioHost: Sendable {
    private let runtime: ACPAgentRuntime
    private let transport: any ACPTransport

    public init(runtime: ACPAgentRuntime, transport: any ACPTransport) {
        self.runtime = runtime
        self.transport = transport
    }

    /// Bind a runtime to the process's own stdin/stdout.
    public init(runtime: ACPAgentRuntime) {
        self.init(runtime: runtime, transport: ACPStdioTransport(io: ACPStandardIO()))
    }

    /// Serve until stdin reaches EOF or the peer closes, mirroring
    /// `run_stdio_agent` (`agent/app.rs:290`).
    public func run() async {
        await runtime.serve(transport)
    }

    public func shutdown() async {
        await runtime.close()
        await transport.close()
    }
}
