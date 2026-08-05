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
        self.init(input: FileHandle.standardInput.fileDescriptor, output: FileHandle.standardOutput.fileDescriptor)
    }

    /// Bind to arbitrary descriptors. Tests use a `pipe(2)` pair here; the
    /// production path uses `init()`.
    public init(input: Int32, output: Int32) {
        let mailbox = ACPLineMailbox()
        self.mailbox = mailbox
        self.writer = ACPLineWriter(descriptor: output)
        self.reader = ACPLineReader(descriptor: input, mailbox: mailbox)
        reader.start()
    }

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
    private let descriptor: Int32

    init(descriptor: Int32) { self.descriptor = descriptor }

    func write(_ string: String) throws {
        var bytes = Array(string.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { buffer -> Int in
                Foundation.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
            }
            if written > 0 {
                offset += written
                continue
            }
            if written < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            throw ACPTransportError.closed
        }
    }
}

/// Owns the blocking reader thread.
///
/// `@unchecked Sendable` with an `NSLock`-guarded stop flag: the thread body
/// and `stop()` are the only two things touching it, and the descriptor is
/// read-only after construction.
private final class ACPLineReader: @unchecked Sendable {
    private let descriptor: Int32
    private let mailbox: ACPLineMailbox
    private let lock = NSLock()
    private var stopped = false

    init(descriptor: Int32, mailbox: ACPLineMailbox) {
        self.descriptor = descriptor
        self.mailbox = mailbox
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
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
            let count = chunk.withUnsafeMutableBytes { pointer in
                read(descriptor, pointer.baseAddress, pointer.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                break
            }
            if count == 0 { break }
            buffer.append(contentsOf: chunk[0..<count])
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineBytes = Array(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                // A CRLF client leaves the carriage return behind.
                let trimmed = lineBytes.last == UInt8(ascii: "\r") ? lineBytes.dropLast() : lineBytes[...]
                let line = String(decoding: trimmed, as: UTF8.self)
                let mailbox = self.mailbox
                Task { await mailbox.deliver(line) }
            }
        }
        // A client that closes without a trailing newline still sent a frame.
        if !buffer.isEmpty {
            let line = String(decoding: buffer, as: UTF8.self)
            let mailbox = self.mailbox
            Task { await mailbox.deliver(line) }
        }
        let mailbox = self.mailbox
        Task { await mailbox.finish() }
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
