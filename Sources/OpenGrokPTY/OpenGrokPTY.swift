// OpenGrokPTY.swift
//
// Pseudoterminal, process execution, and signal-handling contract.
// Port of the process/PTY surface of `ptyctl` (portable-pty spawn + lifecycle)
// for the Open Grok Swift port.
//
// Platform seams:
//   - macOS / Linux: C spawn shim (setsid + TIOCSCTTY + chdir) + PTY master I/O
//   - Windows: ConPTY + Job Objects when available; typed unsupported otherwise

import Foundation
import OpenGrokTTY
import OpenGrokPTYC

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Syscall aliases (portable Darwin/Glibc)

#if os(macOS) || os(Linux)
@inline(__always)
private func sysWrite(_ fd: Int32, _ buf: UnsafeRawPointer!, _ nbyte: Int) -> Int {
    write(fd, buf, nbyte)
}

@inline(__always)
private func sysRead(_ fd: Int32, _ buf: UnsafeMutableRawPointer!, _ nbyte: Int) -> Int {
    read(fd, buf, nbyte)
}

@inline(__always)
private func sysClose(_ fd: Int32) -> Int32 {
    close(fd)
}
#endif

// MARK: - Errors

/// PTY/process errors. `unsupported` is returned only for genuine OS gaps
/// (e.g. ConPTY semantics absent on a Windows build).
public enum PTYError: Error, Equatable, Sendable {
    case spawnFailed(String)
    case unsupported(String)
    case cancelled
    case timeout
    case ioFailed(String)
}

// MARK: - Signals / exit

/// A signal that can be delivered to a child process group.
public enum ProcessSignal: Sendable, Equatable, Codable {
    case terminate
    case kill
    case interrupt
    case hangup
    case windowChange
    /// Map to the portable integer representation used by the adapter.
    public var portableValue: Int {
        switch self {
        case .terminate: return 15
        case .kill: return 9
        case .interrupt: return 2
        case .hangup: return 1
        case .windowChange: return 28
        }
    }

    #if os(macOS) || os(Linux)
    public var posixValue: Int32 {
        switch self {
        case .terminate: return SIGTERM
        case .kill: return SIGKILL
        case .interrupt: return SIGINT
        case .hangup: return SIGHUP
        case .windowChange: return SIGWINCH
        }
    }
    #endif
}

/// How a process exited.
public enum ProcessExit: Sendable, Equatable {
    case code(Int32)
    case signal(Int32)
    case stillRunning
}

// MARK: - Spec

/// A child-process launch specification.
public struct ProcessSpec: Sendable, Equatable {
    public var command: String
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String?
    public var usePTY: Bool
    public var initialSize: TerminalSize?
    /// When true (default), start a new process group so signals target the
    /// whole tree (descendant cleanup).
    public var newProcessGroup: Bool
    /// Merge pager-suppression env when spawning under a TUI.
    public var applyPagerEnvironment: Bool

    public init(
        command: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: String? = nil,
        usePTY: Bool = false,
        initialSize: TerminalSize? = nil,
        newProcessGroup: Bool = true,
        applyPagerEnvironment: Bool = false
    ) {
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.usePTY = usePTY
        self.initialSize = initialSize
        self.newProcessGroup = newProcessGroup
        self.applyPagerEnvironment = applyPagerEnvironment
    }
}

/// Portable, testable preparation for CreateProcessW's command line and environment.
enum WindowsProcessLaunchSupport {
    static func commandLine(command: String, arguments: [String]) -> String {
        ([command] + arguments).map(quoteArgument).joined(separator: " ")
    }

    static func quoteArgument(_ argument: String) -> String {
        guard argument.isEmpty
            || argument.contains(where: \.isWhitespace)
            || argument.contains("\"")
        else { return argument }

        var result = "\""
        var backslashes = 0
        for scalar in argument.unicodeScalars {
            switch scalar.value {
            case 0x5c:
                backslashes += 1
            case 0x22:
                result += String(repeating: "\\", count: backslashes * 2 + 1)
                result.append("\"")
                backslashes = 0
            default:
                result += String(repeating: "\\", count: backslashes)
                result.unicodeScalars.append(scalar)
                backslashes = 0
            }
        }
        result += String(repeating: "\\", count: backslashes * 2)
        result.append("\"")
        return result
    }

    static func environmentBlock(
        inherited: [String: String],
        overrides: [String: String]
    ) throws -> [UInt16] {
        var entries: [String: (name: String, value: String)] = [:]
        for environment in [inherited, overrides] {
            for (name, value) in environment {
                guard !name.isEmpty,
                      !name.contains("="),
                      !name.utf8.contains(0),
                      !value.utf8.contains(0)
                else {
                    throw PTYError.spawnFailed("invalid Windows environment entry: \(name)")
                }
                entries[name.uppercased()] = (name, value)
            }
        }

        var result: [UInt16] = []
        for key in entries.keys.sorted() {
            guard let entry = entries[key] else { continue }
            result.append(contentsOf: "\(entry.name)=\(entry.value)".utf16)
            result.append(0)
        }
        result.append(0)
        if entries.isEmpty {
            result.append(0)
        }
        return result
    }
}

// MARK: - Process handle protocol

/// A running PTY/process handle.
public protocol PTYProcess: AnyObject, Sendable {
    var identifier: String { get }
    var processID: Int32? { get }
    func resize(to size: TerminalSize) async throws
    func write(_ data: Data) async throws
    /// Output events as an ordered, cancellable async sequence.
    func output() -> AsyncThrowingStream<Data, Error>
    func signal(_ signal: ProcessSignal) async throws
    func waitForExit() async throws -> ProcessExit
    func cancel() async
}

/// Process/PTY spawn + lifecycle adapter.
public protocol PTYAdapter: Sendable {
    func spawn(_ spec: ProcessSpec) async throws -> any PTYProcess
}

/// Signal-handling contract for forwarding termination requests to a process
/// group. POSIX uses process groups + signals; Windows uses Job Objects.
public protocol SignalHandling: Sendable {
    func deliver(_ signal: ProcessSignal, to processIdentifier: String) async throws
}

// MARK: - Wait status helpers (function-like macros are not imported into Swift)

#if os(macOS) || os(Linux)

private func statusIsExited(_ status: Int32) -> Bool {
    (status & 0o177) == 0
}

private func statusExitCode(_ status: Int32) -> Int32 {
    (status >> 8) & 0xff
}

private func statusIsSignaled(_ status: Int32) -> Bool {
    let term = status & 0o177
    return term != 0 && term != 0x7f
}

private func statusTermSignal(_ status: Int32) -> Int32 {
    status & 0o177
}

/// Portable mutex usable from sync and async contexts via nonisolated helpers.
private struct PortableMutex: @unchecked Sendable {
    #if canImport(Darwin)
    private let storage: UnsafeMutablePointer<os_unfair_lock>
    init() {
        storage = .allocate(capacity: 1)
        storage.initialize(to: os_unfair_lock())
    }
    func lock() { os_unfair_lock_lock(storage) }
    func unlock() { os_unfair_lock_unlock(storage) }
    #else
    private let storage: UnsafeMutablePointer<pthread_mutex_t>
    init() {
        storage = .allocate(capacity: 1)
        storage.initialize(to: pthread_mutex_t())
        pthread_mutex_init(storage, nil)
    }
    func lock() { pthread_mutex_lock(storage) }
    func unlock() { pthread_mutex_unlock(storage) }
    #endif

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

/// Dedicated reader for a PTY master (or pipe read end).
///
/// The reader is started *before* the child is spawned and parks in `poll(2)`, so bytes are
/// consumed as soon as they appear. macOS discards a terminal's output queue once the last
/// slave descriptor closes, so reading only at reap time loses a short-lived child's output.
///
/// The stream ends on whichever of two events arrives first: the descriptor reports the end of
/// the stream (EOF, or `EIO`, which is how macOS reports "last slave closed"), or the child is
/// reaped — after which a bounded final drain runs before finishing. Ending on EOF alone
/// deadlocks whenever an unrelated process has inherited a slave descriptor and holds it open;
/// ending at reap alone loses the bytes still queued.
///
/// The loop owns a real thread, never the cooperative pool, and owns `fd`: it closes the
/// descriptor when it completes.
final class PTYOutputReader: @unchecked Sendable {
    private let fd: Int32
    private let lock = PortableMutex()
    private var wakeRead: Int32 = -1
    private var wakeWrite: Int32 = -1
    private var sink: ((Data) -> Void)?
    private var onFinish: ((Error?) -> Void)?
    private var buffered: [Data] = []
    private var finished = false
    private var finishError: Error?
    private var reapDeadline: Date?
    private var stopRequested = false

    /// How long the post-reap drain may run before the stream is finished regardless. A
    /// surviving grandchild can keep the slave open and keep writing indefinitely.
    private static let drainBudget: TimeInterval = 0.1

    init(fd: Int32) {
        self.fd = fd
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
        var wake: [Int32] = [-1, -1]
        if pipe(&wake) == 0 {
            wakeRead = wake[0]
            wakeWrite = wake[1]
            for end in wake {
                let f = fcntl(end, F_GETFL)
                if f >= 0 { _ = fcntl(end, F_SETFL, f | O_NONBLOCK) }
            }
        }
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "opengrok.pty.reader"
        thread.stackSize = 512 * 1024
        thread.start()
    }

    /// Installs the consumer. Anything read before this point is replayed in order; if the
    /// stream already ended, `onFinish` fires immediately.
    func attach(sink: @escaping (Data) -> Void, onFinish: @escaping (Error?) -> Void) {
        var replay: [Data] = []
        var alreadyFinished = false
        var completionError: Error?
        lock.withLock {
            replay = buffered
            buffered.removeAll()
            if finished {
                alreadyFinished = true
                completionError = finishError
            } else {
                self.sink = sink
                self.onFinish = onFinish
            }
        }
        for chunk in replay { sink(chunk) }
        if alreadyFinished { onFinish(completionError) }
    }

    /// Child reaped: drain what is still queued, bounded, then finish the stream.
    func finishAfterReap() {
        lock.withLock {
            guard !finished, reapDeadline == nil else { return }
            reapDeadline = Date().addingTimeInterval(Self.drainBudget)
            wake()
        }
    }

    /// Stop now without draining (cancellation / teardown).
    func stop() {
        lock.withLock {
            guard !finished else { return }
            stopRequested = true
            wake()
        }
    }

    // MARK: Private

    /// Nudges the poll out of its wait. Caller holds `lock`.
    private func wake() {
        guard wakeWrite >= 0 else { return }
        var byte: UInt8 = 1
        _ = sysWrite(wakeWrite, &byte, 1)
    }

    private func run() {
        var buf = [UInt8](repeating: 0, count: 65_536)
        while true {
            enum Phase {
                case running
                case draining(Date)
                case stop
            }
            let phase: Phase = lock.withLock {
                if stopRequested || finished { return .stop }
                if let deadline = reapDeadline { return .draining(deadline) }
                return .running
            }
            var timeoutMS: Int32 = 50
            switch phase {
            case .stop:
                complete(nil)
                return
            case .draining(let deadline):
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 {
                    complete(nil)
                    return
                }
                timeoutMS = Int32(max(1, min(20, remaining * 1000)))
            case .running:
                break
            }

            var fds = [
                pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)
            ]
            let ready = poll(&fds, 2, timeoutMS)
            if ready < 0 {
                if errno == EINTR { continue }
                complete(PTYError.ioFailed("PTY poll failed: \(String(cString: strerror(errno)))"))
                return
            }
            if fds[1].revents != 0 { flushWake() }

            var readAny = false
            var ended = false
            var failure: Error?
            readLoop: while true {
                let n = buf.withUnsafeMutableBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return sysRead(fd, base, raw.count)
                }
                if n > 0 {
                    readAny = true
                    deliver(Data(buf[0..<n]))
                    continue
                }
                if n == 0 {
                    ended = true
                    break readLoop
                }
                let code = errno
                if code == EINTR { continue }
                if code == EAGAIN || code == EWOULDBLOCK { break readLoop }
                // macOS reports "the last slave descriptor closed" as EIO on the master.
                if code == EIO || code == EBADF || code == ENXIO {
                    ended = true
                    break readLoop
                }
                failure = PTYError.ioFailed("PTY read failed: \(String(cString: strerror(code)))")
                break readLoop
            }

            if ended || failure != nil {
                complete(failure)
                return
            }
            // Post-reap, a quiet poll means nothing more is queued: finish without
            // burning the rest of the drain budget.
            if case .draining = phase, !readAny, ready == 0 {
                complete(nil)
                return
            }
        }
    }

    private func flushWake() {
        guard wakeRead >= 0 else { return }
        var scratch = [UInt8](repeating: 0, count: 64)
        while true {
            let n = scratch.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return sysRead(wakeRead, base, raw.count)
            }
            if n <= 0 { return }
        }
    }

    /// Delivers under `lock` so replayed and live chunks cannot interleave out of order.
    private func deliver(_ data: Data) {
        lock.withLock {
            if let sink {
                sink(data)
            } else {
                buffered.append(data)
            }
        }
    }

    private func complete(_ error: Error?) {
        let completion: ((Error?) -> Void)? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            finishError = error
            let cb = onFinish
            onFinish = nil
            sink = nil
            if wakeRead >= 0 { _ = sysClose(wakeRead) }
            if wakeWrite >= 0 { _ = sysClose(wakeWrite) }
            wakeRead = -1
            wakeWrite = -1
            _ = sysClose(fd)
            return cb
        }
        completion?(error)
    }
}

#endif

// MARK: - POSIX implementation

#if os(macOS) || os(Linux)

/// Running POSIX child, optionally bound to a PTY master.
public final class PosixPTYProcess: PTYProcess, @unchecked Sendable {
    public let identifier: String
    public let processID: Int32?

    private let masterFD: Int32?
    private let childPID: pid_t
    private let processGroup: ProcessGroup
    private let state = PortableMutex()
    private var exitStatus: ProcessExit = .stillRunning
    private var cancelled = false
    private var pendingOutput: [Data] = []
    private var outputFinished = false
    private var outputError: Error?
    private var outputContinuation: AsyncThrowingStream<Data, Error>.Continuation?
    private let reader: PTYOutputReader?
    private var waiterTask: Task<Void, Never>?
    private var nextWaiterID: UInt64 = 1
    private var waitContinuations: [UInt64: CheckedContinuation<ProcessExit, Error>] = [:]
    private var accumulated = Data()

    /// `reader` must already have been started (before the child was spawned) and owns
    /// `masterFD`, including closing it.
    init(
        identifier: String,
        childPID: pid_t,
        masterFD: Int32?,
        reader: PTYOutputReader?,
        processGroup: ProcessGroup
    ) {
        self.identifier = identifier
        self.processID = childPID
        self.childPID = childPID
        self.masterFD = masterFD
        self.reader = reader
        self.processGroup = processGroup
        reader?.attach(
            sink: { [weak self] data in self?.deliverOutput(data) },
            onFinish: { [weak self] error in self?.finishOutput(error: error) }
        )
        startWaiter()
    }

    deinit {
        waiterTask?.cancel()
        reader?.stop()
        if case .stillRunning = snapshotExit() {
            try? processGroup.kill()
        }
    }

    /// Snapshot of all output collected so far.
    public var accumulatedOutput: Data {
        state.withLock { accumulated }
    }

    public func resize(to size: TerminalSize) async throws {
        guard let masterFD else {
            throw PTYError.unsupported("resize requires a PTY master")
        }
        var ws = winsize()
        ws.ws_row = UInt16(clamping: size.height)
        ws.ws_col = UInt16(clamping: size.width)
        ws.ws_xpixel = 0
        ws.ws_ypixel = 0
        let rc = ioctl(masterFD, UInt(TIOCSWINSZ), &ws)
        if rc != 0 {
            throw PTYError.ioFailed("TIOCSWINSZ failed: \(String(cString: strerror(errno)))")
        }
    }

    public func write(_ data: Data) async throws {
        if Task.isCancelled { throw PTYError.cancelled }
        let (isCancelled, fd) = state.withLock { (cancelled, masterFD) }
        if isCancelled { throw PTYError.cancelled }
        guard let fd else {
            throw PTYError.unsupported("write requires a PTY master or stdout pipe")
        }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            let total = raw.count
            while written < total {
                let n = sysWrite(fd, base.advanced(by: written), total - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN {
                        usleep(1_000)
                        continue
                    }
                    throw PTYError.ioFailed("PTY write failed: \(String(cString: strerror(errno)))")
                }
                if n == 0 { break }
                written += n
            }
        }
    }

    public func output() -> AsyncThrowingStream<Data, Error> {
        makeOutputStream()
    }

    private func makeOutputStream() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            enum Action {
                case alreadySubscribed
                case finishClean
                case finishError(Error)
                case keepOpen
            }
            let action: Action = self.state.withLock {
                if self.outputContinuation != nil {
                    return .alreadySubscribed
                }
                for chunk in self.pendingOutput {
                    continuation.yield(chunk)
                }
                self.pendingOutput.removeAll()
                if let err = self.outputError {
                    return .finishError(err)
                }
                if self.outputFinished {
                    return .finishClean
                }
                self.outputContinuation = continuation
                return .keepOpen
            }
            switch action {
            case .alreadySubscribed:
                continuation.finish(throwing: PTYError.ioFailed("output() already subscribed"))
            case .finishClean:
                continuation.finish()
            case .finishError(let err):
                continuation.finish(throwing: err)
            case .keepOpen:
                continuation.onTermination = { [weak self] _ in
                    guard let self else { return }
                    self.state.withLock {
                        if self.outputContinuation != nil {
                            self.outputContinuation = nil
                        }
                    }
                }
            }
        }
    }

    public func signal(_ signal: ProcessSignal) async throws {
        try processGroup.signal(signal.posixValue)
    }

    public func waitForExit() async throws -> ProcessExit {
        if let done = snapshotExitIfDone() {
            return done
        }
        let waiterID: UInt64 = state.withLock {
            let id = nextWaiterID
            nextWaiterID &+= 1
            return id
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { cont in
                enum Action {
                    case wait
                    case exit(ProcessExit)
                    case cancelled
                }
                let action: Action = self.state.withLock {
                    if self.exitStatus != .stillRunning {
                        return .exit(self.exitStatus)
                    }
                    if Task.isCancelled {
                        return .cancelled
                    }
                    self.waitContinuations[waiterID] = cont
                    return .wait
                }
                switch action {
                case .wait:
                    break
                case .exit(let exit):
                    cont.resume(returning: exit)
                case .cancelled:
                    cont.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let continuation = self.state.withLock {
                self.waitContinuations.removeValue(forKey: waiterID)
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    public func cancel() async {
        state.withLock { cancelled = true }
        try? processGroup.signal(SIGTERM)
        try? await Task.sleep(nanoseconds: 200_000_000)
        if snapshotExit() == .stillRunning {
            try? processGroup.kill()
        }
        let cont: AsyncThrowingStream<Data, Error>.Continuation? = state.withLock {
            outputFinished = true
            outputError = PTYError.cancelled
            let c = outputContinuation
            outputContinuation = nil
            return c
        }
        cont?.finish(throwing: PTYError.cancelled)
        reader?.stop()
    }

    // MARK: Private helpers

    private func snapshotExit() -> ProcessExit {
        state.withLock { exitStatus }
    }

    private func snapshotExitIfDone() -> ProcessExit? {
        state.withLock {
            exitStatus == .stillRunning ? nil : exitStatus
        }
    }

    private func deliverOutput(_ data: Data) {
        let cont: AsyncThrowingStream<Data, Error>.Continuation? = state.withLock {
            accumulated.append(data)
            if let cont = outputContinuation {
                return cont
            }
            pendingOutput.append(data)
            return nil
        }
        cont?.yield(data)
    }

    private func finishOutput(error: Error? = nil) {
        let cont: AsyncThrowingStream<Data, Error>.Continuation? = state.withLock {
            guard !outputFinished else { return nil }
            outputFinished = true
            outputError = error
            let c = outputContinuation
            outputContinuation = nil
            return c
        }
        if let cont {
            if let error {
                cont.finish(throwing: error)
            } else {
                cont.finish()
            }
        }
    }

    private func startWaiter() {
        waiterTask = Task.detached { [weak self] in
            guard let self else { return }
            var status: Int32 = 0
            while !Task.isCancelled {
                let rc = waitpid(self.childPID, &status, WNOHANG)
                if rc == self.childPID {
                    let exit: ProcessExit
                    if statusIsExited(status) {
                        exit = .code(statusExitCode(status))
                    } else if statusIsSignaled(status) {
                        exit = .signal(statusTermSignal(status))
                    } else {
                        exit = .code(-1)
                    }
                    self.finish(with: exit)
                    return
                } else if rc < 0 {
                    if errno == EINTR { continue }
                    self.finish(with: .code(-1))
                    return
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
    }

    private func finish(with exit: ProcessExit) {
        let waiters: [CheckedContinuation<ProcessExit, Error>] = state.withLock {
            guard exitStatus == .stillRunning else { return [] }
            exitStatus = exit
            let w = Array(waitContinuations.values)
            waitContinuations.removeAll()
            return w
        }
        // Bounded final drain on the reader thread, which then closes the master and finishes
        // the stream. Never block here: this runs on the cooperative pool.
        reader?.finishAfterReap()
        for w in waiters {
            w.resume(returning: exit)
        }
    }
}

// MARK: - POSIX adapter (C shim: setsid + TIOCSCTTY + chdir)

/// POSIX PTY / process adapter using the portable C spawn shim.
///
/// Child setup (in C, not Swift):
///   - PTY: `setsid()` + `TIOCSCTTY` so the slave becomes the controlling TTY
///   - process group: new session or `setpgid(0,0)` when requested
///   - CWD: `chdir` on **both** macOS and Linux before `execve`
public struct PosixPTYAdapter: PTYAdapter, SignalHandling, Sendable {
    private let scope: ProcessScope?

    public init(scope: ProcessScope? = nil) {
        self.scope = scope
    }

    public func spawn(_ spec: ProcessSpec) async throws -> any PTYProcess {
        if Task.isCancelled { throw PTYError.cancelled }
        if spec.usePTY {
            return try spawnWithPTY(spec)
        }
        return try spawnWithPipes(spec)
    }

    public func deliver(_ signal: ProcessSignal, to processIdentifier: String) async throws {
        guard processIdentifier.hasPrefix("pid:"),
              let pid = Int32(processIdentifier.dropFirst(4)),
              pid > 1
        else {
            throw PTYError.spawnFailed("invalid process identifier: \(processIdentifier)")
        }
        let group = ProcessGroup()
        try group.attach(pid: UInt32(pid))
        try group.signal(signal.posixValue)
    }

    private func spawnWithPTY(_ spec: ProcessSpec) throws -> PosixPTYProcess {
        let size = spec.initialSize ?? TerminalSize(width: 80, height: 24)
        var master: Int32 = -1
        var slave: Int32 = -1
        let openRC = opengrok_open_pty(
            &master,
            &slave,
            UInt16(clamping: size.height),
            UInt16(clamping: size.width)
        )
        guard openRC == 0 else {
            throw PTYError.spawnFailed(
                "openpty failed: \(String(cString: strerror(openRC)))"
            )
        }

        // Start reading the master before the child exists: macOS discards the terminal's
        // output queue when the last slave closes, so a short-lived child's bytes must be
        // consumed as they arrive, not after it is reaped.
        let reader = PTYOutputReader(fd: master)
        reader.start()

        do {
            // New session + controlling terminal for correct tty(1)/job control.
            let pid = try spawnChild(
                spec: spec,
                stdinFD: slave,
                stdoutFD: slave,
                stderrFD: slave,
                closeInChild: [master],
                newSession: true,
                setControllingTTY: true,
                newProcessGroup: false
            )
            _ = sysClose(slave)
            slave = -1
            let group = ProcessGroup()
            try group.attach(pid: UInt32(pid))
            scope?.register(group)
            return PosixPTYProcess(
                identifier: "pid:\(pid)",
                childPID: pid,
                masterFD: master,
                reader: reader,
                processGroup: group
            )
        } catch {
            // The reader owns the master descriptor and closes it when it stops.
            reader.stop()
            if slave >= 0 { _ = sysClose(slave) }
            throw error
        }
    }

    private func spawnWithPipes(_ spec: ProcessSpec) throws -> PosixPTYProcess {
        var outPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0 else {
            throw PTYError.spawnFailed("pipe failed: \(String(cString: strerror(errno)))")
        }
        var devnull = open("/dev/null", O_RDONLY)
        guard devnull >= 0 else {
            _ = sysClose(outPipe[0])
            _ = sysClose(outPipe[1])
            throw PTYError.spawnFailed("open /dev/null failed")
        }

        // Symmetric with the PTY path: the reader is parked on the read end before the writer
        // exists, so nothing depends on when the reader is first scheduled.
        let reader = PTYOutputReader(fd: outPipe[0])
        reader.start()

        do {
            let pid = try spawnChild(
                spec: spec,
                stdinFD: devnull,
                stdoutFD: outPipe[1],
                stderrFD: outPipe[1],
                closeInChild: [outPipe[0]],
                newSession: false,
                setControllingTTY: false,
                newProcessGroup: spec.newProcessGroup
            )
            _ = sysClose(devnull)
            devnull = -1
            _ = sysClose(outPipe[1])
            outPipe[1] = -1
            let group = ProcessGroup()
            try group.attach(pid: UInt32(pid))
            scope?.register(group)
            return PosixPTYProcess(
                identifier: "pid:\(pid)",
                childPID: pid,
                masterFD: outPipe[0],
                reader: reader,
                processGroup: group
            )
        } catch {
            reader.stop()
            if devnull >= 0 { _ = sysClose(devnull) }
            if outPipe[1] >= 0 { _ = sysClose(outPipe[1]) }
            throw error
        }
    }

    private func spawnChild(
        spec: ProcessSpec,
        stdinFD: Int32,
        stdoutFD: Int32,
        stderrFD: Int32,
        closeInChild: [Int32],
        newSession: Bool,
        setControllingTTY: Bool,
        newProcessGroup: Bool
    ) throws -> pid_t {
        // Build argv (ownership transferred temporarily to C via strdup).
        let argvStrings = [spec.command] + spec.arguments
        var argvOwned: [UnsafeMutablePointer<CChar>?] = argvStrings.map { strdup($0) }
        argvOwned.append(nil)
        defer {
            for p in argvOwned {
                if let p { free(p) }
            }
        }

        // Build envp.
        var env = ProcessInfo.processInfo.environment
        if spec.applyPagerEnvironment {
            for (k, v) in pagerEnvironment() { env[k] = v }
        }
        for (k, v) in spec.environment { env[k] = v }
        if spec.usePTY {
            if env["TERM"] == nil { env["TERM"] = "xterm-256color" }
            if env["COLORTERM"] == nil { env["COLORTERM"] = "truecolor" }
        }
        var envOwned: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") }
        envOwned.append(nil)
        defer {
            for p in envOwned {
                if let p { free(p) }
            }
        }

        let path = resolveExecutable(spec.command, path: env["PATH"])
        let cwd = spec.workingDirectory
        // Validate CWD up-front so a missing directory is a typed spawn error
        // on both macOS and Linux (rather than a silent child _exit(127)).
        if let cwd {
            var st = stat()
            let rc = cwd.withCString { stat($0, &st) }
            if rc != 0 || (st.st_mode & S_IFMT) != S_IFDIR {
                throw PTYError.spawnFailed(
                    "workingDirectory is not a directory: \(cwd)"
                )
            }
        }

        var closeFDs = closeInChild
        // Also close the originals after dup2 in the child (handled by C).
        for fd in [stdinFD, stdoutFD, stderrFD] where fd > STDERR_FILENO {
            if !closeFDs.contains(fd) {
                closeFDs.append(fd)
            }
        }

        var pid: pid_t = 0
        let rc: Int32 = path.withCString { pathC in
            cwd.withCStringOrNil { cwdC in
                argvOwned.withUnsafeMutableBufferPointer { argvBuf in
                    envOwned.withUnsafeMutableBufferPointer { envBuf in
                        closeFDs.withUnsafeBufferPointer { closeBuf in
                            opengrok_spawn_with_fds(
                                pathC,
                                argvBuf.baseAddress,
                                envBuf.baseAddress,
                                cwdC,
                                stdinFD,
                                stdoutFD,
                                stderrFD,
                                closeBuf.baseAddress,
                                closeBuf.count,
                                newSession ? 1 : 0,
                                setControllingTTY ? 1 : 0,
                                newProcessGroup ? 1 : 0,
                                &pid
                            )
                        }
                    }
                }
            }
        }

        if rc != 0 {
            throw PTYError.spawnFailed(
                "spawn(\(path)) failed: \(String(cString: strerror(rc)))"
            )
        }
        return pid
    }

    private func resolveExecutable(_ command: String, path: String?) -> String {
        if command.contains("/") { return command }
        let search = (path ?? "/usr/bin:/bin").split(separator: ":")
        for dir in search {
            let candidate = "\(dir)/\(command)"
            if access(candidate, X_OK) == 0 {
                return candidate
            }
        }
        return command
    }
}

private extension Optional where Wrapped == String {
    func withCStringOrNil<T>(_ body: (UnsafePointer<CChar>?) throws -> T) rethrows -> T {
        if let self {
            return try self.withCString { try body($0) }
        }
        return try body(nil)
    }
}

/// Preferred platform adapter.
public typealias PlatformPTYAdapter = PosixPTYAdapter

#elseif os(Windows)

// MARK: - Windows ConPTY + Job Object seam
//
// Full implementation requires WinSDK (CreatePseudoConsole, Job Objects,
// PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE). When those symbols are present the
// adapter spawns a ConPTY-backed child; otherwise spawn returns a typed
// unsupported error for the genuine capability gap.

#if canImport(WinSDK)
import WinSDK

private final class WindowsPTYOutputReader: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: HANDLE?
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var buffered: [Data] = []
    private var finished = false
    private var failure: (any Error)?
    private var stopping = false

    init(handle: HANDLE) {
        self.handle = handle
    }

    func start() {
        let thread = Thread { [self] in readLoop() }
        thread.name = "open-grok.windows-pty.output"
        thread.stackSize = 512 * 1024
        thread.start()
    }

    func output() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let snapshot = lock.withLock { () -> (chunks: [Data], finished: Bool, error: (any Error)?) in
                let chunks = buffered
                buffered.removeAll(keepingCapacity: false)
                if !finished {
                    self.continuation = continuation
                }
                return (chunks, finished, failure)
            }
            for chunk in snapshot.chunks {
                continuation.yield(chunk)
            }
            if snapshot.finished {
                if let error = snapshot.error {
                    continuation.finish(throwing: error)
                } else {
                    continuation.finish()
                }
            } else {
                continuation.onTermination = { [weak self] _ in self?.stop() }
            }
        }
    }

    func stop() {
        let pipe = lock.withLock { () -> HANDLE? in
            stopping = true
            return handle
        }
        guard let pipe else { return }
        if !CancelIoEx(pipe, nil), GetLastError() != DWORD(ERROR_NOT_FOUND) {
            complete(PTYError.ioFailed("CancelIoEx(ConPTY) failed: \(GetLastError())"))
        }
    }

    private func readLoop() {
        defer {
            let pipe = lock.withLock { () -> HANDLE? in
                let pipe = handle
                handle = nil
                return pipe
            }
            if let pipe { CloseHandle(pipe) }
        }

        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            guard let pipe = lock.withLock({ handle }) else {
                complete(nil)
                return
            }
            var count: DWORD = 0
            let read = buffer.withUnsafeMutableBytes { bytes -> Bool in
                guard let base = bytes.baseAddress else { return false }
                return ReadFile(pipe, base, DWORD(bytes.count), &count, nil)
            }
            if !read {
                let error = GetLastError()
                if error == DWORD(ERROR_BROKEN_PIPE)
                    || error == DWORD(ERROR_NO_DATA)
                    || lock.withLock({ stopping })
                {
                    complete(nil)
                } else {
                    complete(PTYError.ioFailed("ReadFile(ConPTY) failed: \(error)"))
                }
                return
            }
            guard count > 0 else {
                complete(nil)
                return
            }
            let chunk = Data(buffer.prefix(Int(count)))
            let consumer = lock.withLock { () -> AsyncThrowingStream<Data, Error>.Continuation? in
                if let continuation { return continuation }
                if !finished { buffered.append(chunk) }
                return nil
            }
            consumer?.yield(chunk)
        }
    }

    private func complete(_ error: (any Error)?) {
        let consumer = lock.withLock { () -> AsyncThrowingStream<Data, Error>.Continuation? in
            guard !finished else { return nil }
            finished = true
            failure = error
            let consumer = continuation
            continuation = nil
            return consumer
        }
        if let error {
            consumer?.finish(throwing: error)
        } else {
            consumer?.finish()
        }
    }
}
#endif

/// Windows process handle (ConPTY when the host exports the APIs).
public final class WindowsPTYProcess: PTYProcess, @unchecked Sendable {
    public let identifier: String
    public let processID: Int32?
    private let lock = NSLock()
    private var exitStatus: ProcessExit = .stillRunning
    private var cancelled = false
    #if canImport(WinSDK)
    private var processHandle: HANDLE?
    private var jobHandle: HANDLE?
    private var pseudoConsole: HPCON?
    private var inputWrite: HANDLE?
    private var outputReader: WindowsPTYOutputReader?
    #endif

    init(identifier: String, processID: Int32?) {
        self.identifier = identifier
        self.processID = processID
    }

    #if canImport(WinSDK)
    func adopt(
        process: HANDLE,
        job: HANDLE?,
        pseudoConsole: HPCON?,
        inputWrite: HANDLE?,
        outputRead: HANDLE?
    ) {
        let reader = outputRead.map(WindowsPTYOutputReader.init(handle:))
        lock.withLock {
            self.processHandle = process
            self.jobHandle = job
            self.pseudoConsole = pseudoConsole
            self.inputWrite = inputWrite
            self.outputReader = reader
        }
        reader?.start()
    }
    #endif

    deinit {
        #if canImport(WinSDK)
        if let h = jobHandle { CloseHandle(h) }
        if let h = pseudoConsole { ClosePseudoConsole(h) }
        outputReader?.stop()
        if let h = inputWrite { CloseHandle(h) }
        if let h = processHandle { CloseHandle(h) }
        #endif
    }

    public func resize(to size: TerminalSize) async throws {
        #if canImport(WinSDK)
        let hpc = lock.withLock { pseudoConsole }
        guard let hpc else {
            throw PTYError.unsupported("resize requires an active ConPTY")
        }
        var sz = COORD(X: Int16(clamping: size.width), Y: Int16(clamping: size.height))
        let hr = ResizePseudoConsole(hpc, sz)
        if hr < 0 {
            throw PTYError.ioFailed("ResizePseudoConsole failed: \(hr)")
        }
        #else
        _ = size
        throw PTYError.unsupported("ResizePseudoConsole is unavailable in this build.")
        #endif
    }

    public func write(_ data: Data) async throws {
        #if canImport(WinSDK)
        let pipe = lock.withLock { inputWrite }
        guard let pipe else {
            throw PTYError.unsupported("ConPTY input pipe is unavailable.")
        }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let requested = DWORD(min(raw.count - offset, Int(DWORD.max)))
                var written: DWORD = 0
                guard WriteFile(pipe, base.advanced(by: offset), requested, &written, nil) else {
                    throw PTYError.ioFailed("WriteFile(ConPTY) failed: \(GetLastError())")
                }
                guard written > 0, written <= requested else {
                    throw PTYError.ioFailed("WriteFile(ConPTY) returned an invalid byte count")
                }
                offset += Int(written)
            }
        }
        #else
        _ = data
        throw PTYError.unsupported("ConPTY write path is unavailable in this build.")
        #endif
    }

    public func output() -> AsyncThrowingStream<Data, Error> {
        #if canImport(WinSDK)
        guard let reader = lock.withLock({ outputReader }) else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: PTYError.unsupported("ConPTY output pipe missing"))
            }
        }
        return reader.output()
        #else
        AsyncThrowingStream { cont in
            cont.finish(throwing: PTYError.unsupported("ConPTY output path is unavailable."))
        }
        #endif
    }

    public func signal(_ signal: ProcessSignal) async throws {
        #if canImport(WinSDK)
        let (process, job) = lock.withLock { (processHandle, jobHandle) }
        guard let process, let job else {
            throw PTYError.ioFailed("ConPTY process has no mandatory Job Object")
        }
        if !TerminateJobObject(job, 1) {
            let failure = GetLastError()
            var code: DWORD = 0
            guard GetExitCodeProcess(process, &code), code != DWORD(STILL_ACTIVE) else {
                throw PTYError.ioFailed("TerminateJobObject failed: \(failure)")
            }
        }
        #else
        _ = signal
        throw PTYError.unsupported("Job Object signal delivery is unavailable in this build.")
        #endif
    }

    public func waitForExit() async throws -> ProcessExit {
        #if canImport(WinSDK)
        let current = lock.withLock { exitStatus }
        if current != .stillRunning { return current }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let thread = Thread { [self] in
                    waitOnDedicatedThread(continuation)
                }
                thread.name = "open-grok.windows-pty.wait"
                thread.stackSize = 512 * 1024
                thread.start()
            }
        } onCancel: {
            Task { await self.cancel() }
        }
        #else
        return lock.withLock { exitStatus }
        #endif
    }

    public func cancel() async {
        do {
            try await signal(.terminate)
        } catch {
            #if canImport(WinSDK)
            let handles = lock.withLock { (processHandle, jobHandle) }
            if let process = handles.0, !TerminateProcess(process, 1) {
                // Closing the mandatory kill-on-close job remains the final safeguard.
            }
            #endif
        }
        #if canImport(WinSDK)
        lock.withLock { outputReader }?.stop()
        #endif
        lock.withLock {
            cancelled = true
        }
    }

    #if canImport(WinSDK)
    private func waitOnDedicatedThread(_ continuation: CheckedContinuation<ProcessExit, any Error>) {
        guard let process = lock.withLock({ processHandle }) else {
            continuation.resume(throwing: PTYError.ioFailed("ConPTY process handle is unavailable"))
            return
        }
        let result = WaitForSingleObject(process, DWORD(INFINITE))
        guard result == DWORD(WAIT_OBJECT_0) else {
            continuation.resume(throwing: PTYError.ioFailed(
                "WaitForSingleObject failed: \(result), \(GetLastError())"
            ))
            return
        }
        var code: DWORD = 0
        guard GetExitCodeProcess(process, &code) else {
            continuation.resume(throwing: PTYError.ioFailed(
                "GetExitCodeProcess failed: \(GetLastError())"
            ))
            return
        }
        let status: ProcessExit = .code(Int32(bitPattern: code))
        lock.withLock { exitStatus = status }
        continuation.resume(returning: status)
    }
    #endif
}

/// Windows ConPTY adapter.
public struct PlatformPTYAdapter: PTYAdapter, SignalHandling, Sendable {
    private let scope: ProcessScope?

    public init(scope: ProcessScope? = nil) {
        self.scope = scope
    }

    public func spawn(_ spec: ProcessSpec) async throws -> any PTYProcess {
        if !WindowsConPTY.isAvailable {
            throw PTYError.unsupported(
                "ConPTY (CreatePseudoConsole) is not available on this Windows host/SDK."
            )
        }
        return try WindowsConPTY.spawn(spec, scope: scope)
    }

    public func deliver(_ signal: ProcessSignal, to processIdentifier: String) async throws {
        #if canImport(WinSDK)
        guard processIdentifier.hasPrefix("pid:"),
              let pid = UInt32(processIdentifier.dropFirst(4)),
              pid > 0
        else {
            throw PTYError.spawnFailed("invalid process identifier: \(processIdentifier)")
        }
        let handle = OpenProcess(DWORD(PROCESS_TERMINATE), false, pid)
        guard handle != nil, handle != INVALID_HANDLE_VALUE else {
            throw PTYError.ioFailed("OpenProcess failed: \(GetLastError())")
        }
        defer { CloseHandle(handle) }
        switch signal {
        case .kill, .terminate:
            guard TerminateProcess(handle, 1) else {
                throw PTYError.ioFailed("TerminateProcess failed: \(GetLastError())")
            }
        default:
            guard TerminateProcess(handle, 1) else {
                throw PTYError.ioFailed("TerminateProcess failed: \(GetLastError())")
            }
        }
        #else
        _ = signal
        _ = processIdentifier
        throw PTYError.unsupported(
            "Windows Job Object signal delivery requires a linked WinSDK build."
        )
        #endif
    }
}

/// ConPTY capability probe and spawn entry (compiled only for Windows).
enum WindowsConPTY {
    /// `true` when CreatePseudoConsole and friends are linkable.
    static var isAvailable: Bool {
        #if canImport(WinSDK)
        // Windows 10 1809+ exports CreatePseudoConsole from kernel32.
        true
        #else
        false
        #endif
    }

    static func spawn(_ spec: ProcessSpec, scope: ProcessScope?) throws -> WindowsPTYProcess {
        #if canImport(WinSDK)
        var inputRead: HANDLE?
        var inputWrite: HANDLE?
        var outputRead: HANDLE?
        var outputWrite: HANDLE?
        var pseudoConsole: HPCON?
        var jobHandle: HANDLE?
        var processInformation = PROCESS_INFORMATION()
        var processCreated = false
        var assignedToJob = false
        var ownershipTransferred = false

        defer {
            if let inputRead { CloseHandle(inputRead) }
            if let outputWrite { CloseHandle(outputWrite) }

            if !ownershipTransferred {
                if processCreated {
                    if assignedToJob, let jobHandle {
                        if !TerminateJobObject(jobHandle, 1),
                           !TerminateProcess(processInformation.hProcess, 1)
                        {
                            // Closing the configured kill-on-close job still contains descendants.
                        }
                    } else if !TerminateProcess(processInformation.hProcess, 1) {
                        // No resumed thread exists before successful job assignment.
                    }
                    CloseHandle(processInformation.hThread)
                    CloseHandle(processInformation.hProcess)
                }
                if let jobHandle { CloseHandle(jobHandle) }
                if let pseudoConsole { ClosePseudoConsole(pseudoConsole) }
                if let inputWrite { CloseHandle(inputWrite) }
                if let outputRead { CloseHandle(outputRead) }
            }
        }

        var sa = SECURITY_ATTRIBUTES()
        sa.nLength = DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size)
        sa.bInheritHandle = true
        guard CreatePipe(&inputRead, &inputWrite, &sa, 0),
              CreatePipe(&outputRead, &outputWrite, &sa, 0)
        else {
            throw PTYError.spawnFailed("CreatePipe failed: \(GetLastError())")
        }

        let size = spec.initialSize ?? TerminalSize(width: 80, height: 24)
        let coord = COORD(X: Int16(clamping: size.width), Y: Int16(clamping: size.height))
        let hr = CreatePseudoConsole(coord, inputRead, outputWrite, 0, &pseudoConsole)
        if let handle = inputRead { CloseHandle(handle); inputRead = nil }
        if let handle = outputWrite { CloseHandle(handle); outputWrite = nil }
        guard hr >= 0, let console = pseudoConsole else {
            throw PTYError.spawnFailed("CreatePseudoConsole failed: \(hr)")
        }

        let command = WindowsProcessLaunchSupport.commandLine(
            command: spec.command,
            arguments: spec.arguments
        )
        var cmdWide = Array(command.utf16)
        cmdWide.append(0)
        var environmentBlock = try WindowsProcessLaunchSupport.environmentBlock(
            inherited: ProcessInfo.processInfo.environment,
            overrides: spec.environment
        )

        guard let job = CreateJobObjectW(nil, nil), job != INVALID_HANDLE_VALUE else {
            throw PTYError.spawnFailed("CreateJobObjectW failed: \(GetLastError())")
        }
        jobHandle = job
        var info = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
        info.BasicLimitInformation.LimitFlags = DWORD(JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE)
        guard SetInformationJobObject(
            job,
            JobObjectExtendedLimitInformation,
            &info,
            DWORD(MemoryLayout<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>.size)
        ) else {
            throw PTYError.spawnFailed("SetInformationJobObject failed: \(GetLastError())")
        }

        var attrSize: SIZE_T = 0
        if InitializeProcThreadAttributeList(nil, 1, 0, &attrSize) || attrSize == 0 {
            throw PTYError.spawnFailed("InitializeProcThreadAttributeList size query failed")
        }
        let attrBuf = UnsafeMutableRawPointer.allocate(byteCount: Int(attrSize), alignment: 16)
        defer { attrBuf.deallocate() }
        let attrList = LPPROC_THREAD_ATTRIBUTE_LIST(attrBuf)
        guard InitializeProcThreadAttributeList(attrList, 1, 0, &attrSize) else {
            throw PTYError.spawnFailed(
                "InitializeProcThreadAttributeList failed: \(GetLastError())"
            )
        }
        defer { DeleteProcThreadAttributeList(attrList) }

        var hpcRef = console
        guard UpdateProcThreadAttribute(
            attrList,
            0,
            DWORD_PTR(PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE),
            &hpcRef,
            SIZE_T(MemoryLayout<HPCON>.size),
            nil,
            nil
        ) else {
            throw PTYError.spawnFailed("UpdateProcThreadAttribute failed: \(GetLastError())")
        }

        var si = STARTUPINFOEXW()
        si.StartupInfo.cb = DWORD(MemoryLayout<STARTUPINFOEXW>.size)
        si.lpAttributeList = attrList

        let cwdWide: [WCHAR]? = spec.workingDirectory.map { Array(($0 as String).utf16) + [0] }

        func createProcess(directory: UnsafePointer<WCHAR>?) -> Bool {
            cmdWide.withUnsafeMutableBufferPointer { command in
                environmentBlock.withUnsafeMutableBufferPointer { environment in
                    CreateProcessW(
                        nil,
                        command.baseAddress,
                        nil,
                        nil,
                        false,
                        DWORD(EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT | CREATE_SUSPENDED),
                        UnsafeMutableRawPointer(environment.baseAddress),
                        directory,
                        &si.StartupInfo,
                        &processInformation
                    )
                }
            }
        }

        let created: Bool
        if let cwdWide {
            created = cwdWide.withUnsafeBufferPointer { createProcess(directory: $0.baseAddress) }
        } else {
            created = createProcess(directory: nil)
        }

        guard created else {
            throw PTYError.spawnFailed("CreateProcessW failed: \(GetLastError())")
        }
        processCreated = true

        guard AssignProcessToJobObject(job, processInformation.hProcess) else {
            throw PTYError.spawnFailed("AssignProcessToJobObject failed: \(GetLastError())")
        }
        assignedToJob = true
        let previousSuspendCount = ResumeThread(processInformation.hThread)
        guard previousSuspendCount != DWORD.max else {
            throw PTYError.spawnFailed("ResumeThread failed: \(GetLastError())")
        }

        let process = WindowsPTYProcess(
            identifier: "pid:\(processInformation.dwProcessId)",
            processID: Int32(bitPattern: processInformation.dwProcessId)
        )
        process.adopt(
            process: processInformation.hProcess,
            job: job,
            pseudoConsole: console,
            inputWrite: inputWrite,
            outputRead: outputRead
        )
        CloseHandle(processInformation.hThread)
        ownershipTransferred = true
        _ = scope
        return process
        #else
        _ = spec
        _ = scope
        throw PTYError.unsupported("ConPTY spawn requires CreatePseudoConsole linkage.")
        #endif
    }
}

#else

/// Non-POSIX / non-Windows fallback.
public struct PlatformPTYAdapter: PTYAdapter, SignalHandling, Sendable {
    public init(scope: ProcessScope? = nil) {}
    public func spawn(_ spec: ProcessSpec) async throws -> any PTYProcess {
        throw PTYError.unsupported("PTY spawn is not available on this platform.")
    }
    public func deliver(_ signal: ProcessSignal, to processIdentifier: String) async throws {
        throw PTYError.unsupported("Signal delivery is not available on this platform.")
    }
}

#endif

// MARK: - Bootstrap adapter

/// Explicit stand-in that now delegates to the platform adapter.
public struct BootstrapPTYAdapter: PTYAdapter {
    public init() {}
    public func spawn(_ spec: ProcessSpec) async throws -> any PTYProcess {
        try await PlatformPTYAdapter().spawn(spec)
    }
}
