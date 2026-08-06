import Foundation

#if canImport(Dispatch)
import Dispatch
#endif

#if os(macOS) || os(Linux)
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@inline(__always)
private func terminalClose(_ fd: Int32) {
#if canImport(Darwin)
    _ = Darwin.close(fd)
#elseif canImport(Glibc)
    _ = Glibc.close(fd)
#endif
}
#endif

public enum TerminalInputError: Error, Equatable, Sendable {
    case cancelled
    case closed
    case concurrentRead
    case invalidUTF8
    case ioFailed(String)
    case unsupported(String)
}

public struct TerminalKeyModifiers: OptionSet, Sendable, Equatable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let shift = TerminalKeyModifiers(rawValue: 1 << 0)
    public static let alt = TerminalKeyModifiers(rawValue: 1 << 1)
    public static let control = TerminalKeyModifiers(rawValue: 1 << 2)
    public static let meta = TerminalKeyModifiers(rawValue: 1 << 3)
}

public enum TerminalNamedKey: Sendable, Equatable, Hashable {
    case up
    case down
    case left
    case right
    case home
    case end
    case pageUp
    case pageDown
    case insert
    case delete
    case function(Int)
}

public enum TerminalKey: Sendable, Equatable, Hashable {
    case named(TerminalNamedKey, modifiers: TerminalKeyModifiers)
    case character(String, modifiers: TerminalKeyModifiers)
}

public enum TerminalControlKey: Sendable, Equatable, Hashable {
    case null
    case character(UInt8)
    case backspace
    case tab
    case enter
    case escape
    case eof
    case interrupt
    case suspend
    case delete
}

public enum TerminalInputEvent: Sendable, Equatable {
    case text(String)
    case key(TerminalKey)
    case control(TerminalControlKey)
    case pasteStart
    case pasteEnd
    case resize(TerminalSize)
    case unknown(Data)
}

public protocol TerminalInput: Sendable {
    var identifier: String? { get }
    func readByte() async throws -> UInt8?
    func readEvent() async throws -> TerminalInputEvent?
    func close() async
}

public protocol TerminalResizeSource: Sendable {
    func events() -> AsyncStream<TerminalSize>
    func stop()
}

public struct TerminalInputDecoder: Sendable {
    private enum State: Sendable {
        case normal
        case utf8(bytes: [UInt8], expectedLength: Int)
        case escape(bytes: [UInt8])
        case altText(bytes: [UInt8])
    }

    private var state: State = .normal
    private let maxSequenceLength: Int

    public init(maxSequenceLength: Int = 256) {
        precondition(maxSequenceLength >= 4)
        self.maxSequenceLength = maxSequenceLength
    }

    public var hasPendingEscapeSequence: Bool {
        switch state {
        case .escape, .altText:
            return true
        case .normal, .utf8:
            return false
        }
    }

    public mutating func feed(_ byte: UInt8) throws -> [TerminalInputEvent] {
        switch state {
        case .normal:
            return try feedNormal(byte)
        case .utf8(let bytes, let expectedLength):
            return try feedUTF8(byte, bytes: bytes, expectedLength: expectedLength)
        case .escape(let bytes):
            return try feedEscapeByte(byte, bytes: bytes)
        case .altText(let bytes):
            return try feedAltText(byte, bytes: bytes)
        }
    }

    public mutating func finish() throws -> [TerminalInputEvent] {
        switch state {
        case .normal:
            return []
        case .utf8:
            state = .normal
            throw TerminalInputError.invalidUTF8
        case .escape(let bytes):
            state = .normal
            if bytes == [0x1b] {
                return [.control(.escape)]
            }
            return [.unknown(Data(bytes))]
        case .altText(let bytes):
            state = .normal
            return [.unknown(Data(bytes))]
        }
    }

    private mutating func feedNormal(_ byte: UInt8) throws -> [TerminalInputEvent] {
        switch byte {
        case 0x00:
            return [.control(.null)]
        case 0x01...0x1a:
            switch byte {
            case 0x03:
                return [.control(.interrupt)]
            case 0x04:
                return [.control(.eof)]
            case 0x08:
                return [.control(.backspace)]
            case 0x09:
                return [.control(.tab)]
            case 0x0a, 0x0d:
                return [.control(.enter)]
            case 0x1a:
                return [.control(.suspend)]
            default:
                return [.control(.character(byte))]
            }
        case 0x1b:
            state = .escape(bytes: [byte])
            return []
        case 0x7f:
            return [.control(.backspace)]
        case 0x20...0x7e:
            return [.text(String(UnicodeScalar(byte)))]
        case 0xc2...0xdf:
            state = .utf8(bytes: [byte], expectedLength: 2)
            return []
        case 0xe0...0xef:
            state = .utf8(bytes: [byte], expectedLength: 3)
            return []
        case 0xf0...0xf4:
            state = .utf8(bytes: [byte], expectedLength: 4)
            return []
        default:
            throw invalidUTF8AndReset()
        }
    }

    private mutating func feedUTF8(
        _ byte: UInt8,
        bytes: [UInt8],
        expectedLength: Int
    ) throws -> [TerminalInputEvent] {
        guard (0x80...0xbf).contains(byte) else {
            state = .normal
            throw TerminalInputError.invalidUTF8
        }

        var nextBytes = bytes
        nextBytes.append(byte)
        guard nextBytes.count == expectedLength else {
            state = .utf8(bytes: nextBytes, expectedLength: expectedLength)
            return []
        }

        guard let text = String(bytes: nextBytes, encoding: .utf8) else {
            state = .normal
            throw TerminalInputError.invalidUTF8
        }
        state = .normal
        return [.text(text)]
    }

    private mutating func feedEscapeByte(
        _ byte: UInt8,
        bytes: [UInt8]
    ) throws -> [TerminalInputEvent] {
        if bytes.count == 1 {
            if byte == 0x1b {
                state = .escape(bytes: [byte])
                return [.control(.escape)]
            }
            if byte == 0x5b || byte == 0x4f {
                state = .escape(bytes: bytes + [byte])
                return []
            }
            if byte >= 0x20 && byte <= 0x2f {
                state = .escape(bytes: bytes + [byte])
                return []
            }
            if byte >= 0xc2 && byte <= 0xf4 {
                state = .altText(bytes: bytes + [byte])
                return []
            }
            if byte >= 0x20 && byte <= 0x7e {
                state = .normal
                return [.key(.character(String(UnicodeScalar(byte)), modifiers: .alt))]
            }

            state = .normal
            return [.unknown(Data(bytes + [byte]))]
        }

        return feedEscapeSequenceByte(byte, bytes: bytes)
    }

    private mutating func feedAltText(
        _ byte: UInt8,
        bytes: [UInt8]
    ) throws -> [TerminalInputEvent] {
        guard let firstByte = bytes.last else {
            state = .normal
            throw TerminalInputError.invalidUTF8
        }
        let expectedLength: Int
        switch firstByte {
        case 0xc2...0xdf:
            expectedLength = 2
        case 0xe0...0xef:
            expectedLength = 3
        case 0xf0...0xf4:
            expectedLength = 4
        default:
            state = .normal
            throw TerminalInputError.invalidUTF8
        }

        guard (0x80...0xbf).contains(byte) else {
            state = .normal
            throw TerminalInputError.invalidUTF8
        }
        var nextBytes = bytes
        nextBytes.append(byte)
        guard nextBytes.count == expectedLength + 1 else {
            state = .altText(bytes: nextBytes)
            return []
        }

        let textBytes = Array(nextBytes.dropFirst())
        guard let text = String(bytes: textBytes, encoding: .utf8) else {
            state = .normal
            throw TerminalInputError.invalidUTF8
        }
        state = .normal
        return [.key(.character(text, modifiers: .alt))]
    }

    private mutating func feedEscapeSequenceByte(
        _ byte: UInt8,
        bytes: [UInt8]
    ) -> [TerminalInputEvent] {
        var nextBytes = bytes
        nextBytes.append(byte)
        if nextBytes.count > maxSequenceLength {
            state = .normal
            return [.unknown(Data(nextBytes))]
        }
        let introducer = nextBytes[1]
        let isFinalByte = byte >= 0x40 && byte <= 0x7e
        if (introducer == 0x5b || introducer == 0x4f) && isFinalByte {
            state = .normal
            return parseEscape(nextBytes)
        }
        state = .escape(bytes: nextBytes)
        return []
    }

    private mutating func parseEscape(_ bytes: [UInt8]) -> [TerminalInputEvent] {
        guard bytes.count >= 2 else { return [] }
        if bytes[1] == 0x4f {
            return parseSS3(bytes)
        }
        guard bytes[1] == 0x5b else {
            return [.unknown(Data(bytes))]
        }

        let finalByte = bytes.last!
        let bodyBytes = bytes.dropFirst(2).dropLast()
        let body = String(decoding: bodyBytes, as: UTF8.self)
        let parts = body.split(separator: ";", omittingEmptySubsequences: false)
        let firstParameter = Int(String(parts.first ?? "")) ?? 1
        let modifierValue = parts.count > 1 ? Int(String(parts[1])) ?? 1 : 1
        let modifiers = modifiers(for: modifierValue)

        switch finalByte {
        case 0x41:
            return [.key(.named(.up, modifiers: modifiers))]
        case 0x42:
            return [.key(.named(.down, modifiers: modifiers))]
        case 0x43:
            return [.key(.named(.right, modifiers: modifiers))]
        case 0x44:
            return [.key(.named(.left, modifiers: modifiers))]
        case 0x48:
            return [.key(.named(.home, modifiers: modifiers))]
        case 0x46:
            return [.key(.named(.end, modifiers: modifiers))]
        case 0x7e:
            switch firstParameter {
            case 1, 7:
                return [.key(.named(.home, modifiers: modifiers))]
            case 2:
                return [.key(.named(.insert, modifiers: modifiers))]
            case 3:
                return [.key(.named(.delete, modifiers: modifiers))]
            case 4, 8:
                return [.key(.named(.end, modifiers: modifiers))]
            case 5:
                return [.key(.named(.pageUp, modifiers: modifiers))]
            case 6:
                return [.key(.named(.pageDown, modifiers: modifiers))]
            case 11...15:
                return [.key(.named(.function(firstParameter - 10), modifiers: modifiers))]
            case 17...21:
                return [.key(.named(.function(firstParameter - 11), modifiers: modifiers))]
            case 23, 24:
                return [.key(.named(.function(firstParameter - 12), modifiers: modifiers))]
            case 200:
                return [.pasteStart]
            case 201:
                return [.pasteEnd]
            default:
                return [.unknown(Data(bytes))]
            }
        default:
            return [.unknown(Data(bytes))]
        }
    }

    private func parseSS3(_ bytes: [UInt8]) -> [TerminalInputEvent] {
        guard let finalByte = bytes.last else { return [.unknown(Data(bytes))] }
        switch finalByte {
        case 0x41:
            return [.key(.named(.up, modifiers: []))]
        case 0x42:
            return [.key(.named(.down, modifiers: []))]
        case 0x43:
            return [.key(.named(.right, modifiers: []))]
        case 0x44:
            return [.key(.named(.left, modifiers: []))]
        case 0x48:
            return [.key(.named(.home, modifiers: []))]
        case 0x46:
            return [.key(.named(.end, modifiers: []))]
        case 0x50...0x53:
            return [.key(.named(.function(Int(finalByte - 0x4f)), modifiers: []))]
        default:
            return [.unknown(Data(bytes))]
        }
    }

    private func modifiers(for parameter: Int) -> TerminalKeyModifiers {
        switch parameter {
        case 2:
            return .shift
        case 3:
            return .alt
        case 4:
            return [.shift, .alt]
        case 5:
            return .control
        case 6:
            return [.shift, .control]
        case 7:
            return [.alt, .control]
        case 8:
            return [.shift, .alt, .control]
        case 9:
            return .meta
        case 10:
            return [.shift, .meta]
        case 11:
            return [.alt, .meta]
        case 12:
            return [.shift, .alt, .meta]
        case 13:
            return [.control, .meta]
        case 14:
            return [.shift, .control, .meta]
        case 15:
            return [.alt, .control, .meta]
        case 16:
            return [.shift, .alt, .control, .meta]
        default:
            return []
        }
    }

    private mutating func invalidUTF8AndReset() -> TerminalInputError {
        state = .normal
        return .invalidUTF8
    }
}

#if os(macOS) || os(Linux)

private enum PosixByteReadResult: Sendable {
    case byte(UInt8)
    case endOfFile
    case timedOut
}

private struct PosixPendingRead {
    let token: UInt64
    let continuation: CheckedContinuation<PosixByteReadResult, Error>
    var cancelled = false
}

public final class PosixTerminalInput: TerminalInput, @unchecked Sendable {
    public let identifier: String?

    private let inputFD: Int32
    private let closeFileDescriptor: Bool
    private let escapeSequenceTimeoutMilliseconds: Int32
    private let stateLock = NSLock()
    private var wakeReadFD: Int32 = -1
    private var wakeWriteFD: Int32 = -1
    private var nextReadToken: UInt64 = 1
    private var pendingRead: PosixPendingRead?
    private var closed = false
    private var decoder = TerminalInputDecoder()

    public init(
        fd: Int32 = STDIN_FILENO,
        escapeSequenceTimeoutMilliseconds: Int32 = 50,
        closeFileDescriptor: Bool = false,
        identifier: String? = nil
    ) throws {
        guard escapeSequenceTimeoutMilliseconds >= 0 else {
            throw TerminalInputError.unsupported("escape sequence timeout cannot be negative")
        }
        self.inputFD = fd
        self.escapeSequenceTimeoutMilliseconds = escapeSequenceTimeoutMilliseconds
        self.closeFileDescriptor = closeFileDescriptor
        self.identifier = identifier ?? "fd:\(fd)"

        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else {
            throw TerminalInputError.ioFailed(
                "pipe failed: \(String(cString: strerror(errno)))"
            )
        }
        guard makeWakePipeNonBlocking(readFD: descriptors[0], writeFD: descriptors[1]) else {
            terminalClose(descriptors[0])
            terminalClose(descriptors[1])
            throw TerminalInputError.ioFailed("failed to configure the input wake pipe")
        }
        self.wakeReadFD = descriptors[0]
        self.wakeWriteFD = descriptors[1]
    }

    deinit {
        stateLock.lock()
        let readFD = wakeReadFD
        let writeFD = wakeWriteFD
        wakeReadFD = -1
        wakeWriteFD = -1
        let shouldCloseInput = closeFileDescriptor
        stateLock.unlock()

        if readFD >= 0 { terminalClose(readFD) }
        if writeFD >= 0 { terminalClose(writeFD) }
        if shouldCloseInput { terminalClose(inputFD) }
    }

    public func readByte() async throws -> UInt8? {
        let result = try await waitForByte(timeoutMilliseconds: nil)
        switch result {
        case .byte(let byte):
            return byte
        case .endOfFile, .timedOut:
            return nil
        }
    }

    public func readEvent() async throws -> TerminalInputEvent? {
        while true {
            let timeout = decoder.hasPendingEscapeSequence
                ? escapeSequenceTimeoutMilliseconds
                : nil
            let result = try await waitForByte(timeoutMilliseconds: timeout)
            switch result {
            case .byte(let byte):
                let events = try decoder.feed(byte)
                if let event = events.first {
                    return event
                }
            case .timedOut:
                let events = try decoder.finish()
                if let event = events.first {
                    return event
                }
            case .endOfFile:
                let events = try decoder.finish()
                if let event = events.first {
                    return event
                }
                return nil
            }
        }
    }

    public func close() async {
        markClosed()
    }

    private func markClosed() {
        stateLock.lock()
        closed = true
        pendingRead?.cancelled = true
        stateLock.unlock()
        signalWake()
    }

    private func waitForByte(timeoutMilliseconds: Int32?) async throws -> PosixByteReadResult {
        if Task.isCancelled {
            throw TerminalInputError.cancelled
        }

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                beginRead(timeoutMilliseconds: timeoutMilliseconds, continuation: continuation)
            }
        }, onCancel: {
            cancelPendingRead()
        })
    }

    private func beginRead(
        timeoutMilliseconds: Int32?,
        continuation: CheckedContinuation<PosixByteReadResult, Error>
    ) {
        if Task.isCancelled {
            continuation.resume(throwing: TerminalInputError.cancelled)
            return
        }

        stateLock.lock()
        if closed {
            stateLock.unlock()
            continuation.resume(throwing: TerminalInputError.closed)
            return
        }
        guard pendingRead == nil else {
            stateLock.unlock()
            continuation.resume(throwing: TerminalInputError.concurrentRead)
            return
        }
        let token = nextReadToken
        nextReadToken &+= 1
        pendingRead = PosixPendingRead(token: token, continuation: continuation)
        stateLock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            pollForByte(token: token, timeoutMilliseconds: timeoutMilliseconds)
        }
    }

    private func pollForByte(token: UInt64, timeoutMilliseconds: Int32?) {
        while true {
            if pendingReadIsCancelled(token: token) {
                finishRead(token: token, result: nil, error: .cancelled)
                return
            }

            var descriptors = [
                pollfd(
                    fd: inputFD,
                    events: Int16(POLLIN | POLLHUP | POLLERR),
                    revents: 0
                ),
                pollfd(fd: wakeReadFDSnapshot(), events: Int16(POLLIN), revents: 0),
            ]
            let pollResult = descriptors.withUnsafeMutableBufferPointer { buffer in
                poll(buffer.baseAddress, nfds_t(buffer.count), timeoutMilliseconds ?? -1)
            }

            if pollResult < 0 {
                if errno == EINTR { continue }
                finishRead(
                    token: token,
                    result: nil,
                    error: .ioFailed("poll failed: \(String(cString: strerror(errno)))")
                )
                return
            }
            if pollResult == 0 {
                finishRead(token: token, result: .timedOut, error: nil)
                return
            }

            if descriptors[1].revents != 0 {
                drainWakePipe()
                if pendingReadIsCancelled(token: token) {
                    finishRead(token: token, result: nil, error: .cancelled)
                    return
                }
            }

            let inputEvents = descriptors[0].revents
            if inputEvents == 0 { continue }
            if (inputEvents & Int16(POLLNVAL)) != 0 {
                finishRead(token: token, result: nil, error: .closed)
                return
            }
            if (inputEvents & Int16(POLLIN | POLLHUP | POLLERR)) != 0 {
                var byte: UInt8 = 0
                let bytesRead = withUnsafeMutableBytes(of: &byte) { raw in
                    read(inputFD, raw.baseAddress, 1)
                }
                if bytesRead == 1 {
                    finishRead(token: token, result: .byte(byte), error: nil)
                    return
                }
                if bytesRead == 0 {
                    finishRead(token: token, result: .endOfFile, error: nil)
                    return
                }
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                    continue
                }
                finishRead(
                    token: token,
                    result: nil,
                    error: .ioFailed("read failed: \(String(cString: strerror(errno)))")
                )
                return
            }
        }
    }

    private func finishRead(
        token: UInt64,
        result: PosixByteReadResult?,
        error: TerminalInputError?
    ) {
        stateLock.lock()
        guard let pendingRead, pendingRead.token == token else {
            stateLock.unlock()
            return
        }
        self.pendingRead = nil
        stateLock.unlock()

        if let error {
            pendingRead.continuation.resume(throwing: error)
        } else if let result {
            pendingRead.continuation.resume(returning: result)
        } else {
            pendingRead.continuation.resume(throwing: TerminalInputError.closed)
        }
    }

    private func pendingReadIsCancelled(token: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let pendingRead, pendingRead.token == token else { return true }
        return pendingRead.cancelled || closed
    }

    private func cancelPendingRead() {
        stateLock.lock()
        let hasPendingRead = pendingRead != nil
        pendingRead?.cancelled = true
        stateLock.unlock()
        if hasPendingRead { signalWake() }
    }

    private func wakeReadFDSnapshot() -> Int32 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return wakeReadFD
    }

    private func signalWake() {
        stateLock.lock()
        let writeFD = wakeWriteFD
        stateLock.unlock()
        guard writeFD >= 0 else { return }
        var marker: UInt8 = 1
        _ = withUnsafeBytes(of: &marker) { raw in
            write(writeFD, raw.baseAddress, 1)
        }
    }

    private func drainWakePipe() {
        let readFD = wakeReadFDSnapshot()
        guard readFD >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 64)
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { raw in
                read(readFD, raw.baseAddress, raw.count)
            }
            if bytesRead <= 0 || bytesRead < buffer.count { return }
        }
    }
}

private func makeWakePipeNonBlocking(readFD: Int32, writeFD: Int32) -> Bool {
    let readFlags = fcntl(readFD, F_GETFL, 0)
    let writeFlags = fcntl(writeFD, F_GETFL, 0)
    guard readFlags >= 0, writeFlags >= 0 else { return false }
    let readResult = fcntl(readFD, F_SETFL, readFlags | O_NONBLOCK)
    let writeResult = fcntl(writeFD, F_SETFL, writeFlags | O_NONBLOCK)
    return readResult == 0 && writeResult == 0
}

public final class PosixTerminalResizeMonitor: TerminalResizeSource, @unchecked Sendable {
    private let fd: Int32
    private let intervalNanoseconds: UInt64
    private let stateLock = NSLock()
    private var streamContinuation: AsyncStream<TerminalSize>.Continuation?
    private var monitorTask: Task<Void, Never>?
    private var stopped = false

    public init(fd: Int32, pollIntervalMilliseconds: UInt64 = 100) {
        self.fd = fd
        self.intervalNanoseconds = max(pollIntervalMilliseconds, 1) * 1_000_000
    }

    deinit {
        stop()
    }

    public func events() -> AsyncStream<TerminalSize> {
        stateLock.lock()
        let alreadyStopped = stopped
        let alreadyStarted = monitorTask != nil
        stateLock.unlock()
        if alreadyStopped || alreadyStarted {
            return AsyncStream { continuation in
                continuation.finish()
            }
        }

        let stream = AsyncStream<TerminalSize> { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            self.stateLock.lock()
            self.streamContinuation = continuation
            self.stateLock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.stop()
            }
        }

        stateLock.lock()
        if stopped || monitorTask != nil {
            stateLock.unlock()
            return AsyncStream { continuation in
                continuation.finish()
            }
        }
        monitorTask = Task { [weak self] in
            guard let self else { return }
            await self.monitorLoop()
        }
        stateLock.unlock()
        return stream
    }

    public func stop() {
        stateLock.lock()
        stopped = true
        let task = monitorTask
        monitorTask = nil
        let continuation = streamContinuation
        streamContinuation = nil
        stateLock.unlock()
        task?.cancel()
        continuation?.finish()
    }

    private func monitorLoop() async {
        var lastSize: TerminalSize?
        while !Task.isCancelled {
            if let currentSize = terminalSize(fd: fd), currentSize != lastSize {
                lastSize = currentSize
                let snapshot = resizeStateSnapshot()
                let continuation = snapshot.continuation
                let shouldStop = snapshot.stopped
                if shouldStop { return }
                continuation?.yield(currentSize)
            }
            do {
                try await Task.sleep(nanoseconds: intervalNanoseconds)
            } catch {
                return
            }
        }
    }

    private func resizeStateSnapshot() -> (
        continuation: AsyncStream<TerminalSize>.Continuation?,
        stopped: Bool
    ) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (streamContinuation, stopped)
    }
}

private func terminalSize(fd: Int32) -> TerminalSize? {
    var window = winsize()
    guard ioctl(fd, UInt(TIOCGWINSZ), &window) == 0 else { return nil }
    let width = Int(window.ws_col)
    let height = Int(window.ws_row)
    guard width > 0, height > 0 else { return nil }
    return TerminalSize(width: width, height: height)
}

public typealias PlatformTerminalInput = PosixTerminalInput
public typealias PlatformTerminalResizeMonitor = PosixTerminalResizeMonitor

#else

public struct UnsupportedTerminalInput: TerminalInput, Sendable {
    public let identifier: String?

    public init(fd: Int32 = 0, identifier: String? = nil) {
        _ = fd
        self.identifier = identifier
    }

    public func readByte() async throws -> UInt8? {
        throw TerminalInputError.unsupported("Terminal input is unavailable on this platform.")
    }

    public func readEvent() async throws -> TerminalInputEvent? {
        throw TerminalInputError.unsupported("Terminal input is unavailable on this platform.")
    }

    public func close() async {}
}

public typealias PlatformTerminalInput = UnsupportedTerminalInput

public struct UnsupportedTerminalResizeMonitor: TerminalResizeSource, Sendable {
    public init(fd: Int32 = 0) {
        _ = fd
    }

    public func events() -> AsyncStream<TerminalSize> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    public func stop() {}
}

public typealias PlatformTerminalResizeMonitor = UnsupportedTerminalResizeMonitor

#endif
