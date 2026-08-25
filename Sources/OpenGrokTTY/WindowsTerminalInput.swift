import Foundation

struct WindowsConsoleKeyRecord: Sendable, Equatable {
    var utf16CodeUnit: UInt16
    var virtualKeyCode: UInt16
    var keyDown: Bool
    var repeatCount: UInt16
    var controlKeyState: UInt32

    init(
        utf16CodeUnit: UInt16,
        virtualKeyCode: UInt16 = 0,
        keyDown: Bool = true,
        repeatCount: UInt16 = 1,
        controlKeyState: UInt32 = 0
    ) {
        self.utf16CodeUnit = utf16CodeUnit
        self.virtualKeyCode = virtualKeyCode
        self.keyDown = keyDown
        self.repeatCount = repeatCount
        self.controlKeyState = controlKeyState
    }
}

struct WindowsConsoleMouseRecord: Sendable, Equatable {
    var column: Int
    var row: Int
    var buttonState: UInt32
    var controlKeyState: UInt32
    var eventFlags: UInt32
    var windowTop: Int

    init(
        column: Int,
        row: Int,
        buttonState: UInt32,
        controlKeyState: UInt32 = 0,
        eventFlags: UInt32 = 0,
        windowTop: Int = 0
    ) {
        self.column = column
        self.row = row
        self.buttonState = buttonState
        self.controlKeyState = controlKeyState
        self.eventFlags = eventFlags
        self.windowTop = windowTop
    }
}

enum WindowsConsoleInputRecord: Sendable, Equatable {
    case key(WindowsConsoleKeyRecord)
    case mouse(WindowsConsoleMouseRecord)
    case resize(width: Int, height: Int)
    case focus(Bool)
}

/// Platform-neutral projection of Win32 INPUT_RECORD. Keeping translation out
/// of WinSDK lets the regular host suite exercise surrogate and mouse parity.
struct WindowsConsoleEventDecoder: Sendable {
    private enum Modifier {
        static let rightAlt: UInt32 = 0x0001
        static let leftAlt: UInt32 = 0x0002
        static let rightControl: UInt32 = 0x0004
        static let leftControl: UInt32 = 0x0008
        static let shift: UInt32 = 0x0010
    }

    private enum Mouse {
        static let left: UInt32 = 0x0001
        static let right: UInt32 = 0x0002
        static let middle: UInt32 = 0x0004
        static let moved: UInt32 = 0x0001
        static let doubleClick: UInt32 = 0x0002
        static let verticalWheel: UInt32 = 0x0004
        static let horizontalWheel: UInt32 = 0x0008
    }

    private var pendingHighSurrogate: UInt16?
    private var pressedMouseButtons: UInt32 = 0

    mutating func reset() {
        pendingHighSurrogate = nil
        pressedMouseButtons = 0
    }

    mutating func decode(_ record: WindowsConsoleInputRecord) -> [TerminalInputEvent] {
        switch record {
        case .key(let key):
            return decodeKey(key)
        case .mouse(let mouse):
            guard let encoded = encodeMouse(mouse) else { return [] }
            return [.unknown(Data(encoded.utf8))]
        case .resize(let width, let height):
            guard width > 0, height > 0 else { return [] }
            return [.resize(TerminalSize(width: width, height: height))]
        case .focus(let gained):
            return [gained ? .focusGained : .focusLost]
        }
    }

    private mutating func decodeKey(_ record: WindowsConsoleKeyRecord) -> [TerminalInputEvent] {
        let isAltCodeRelease = record.virtualKeyCode == 0x12
            && !record.keyDown
            && record.utf16CodeUnit != 0
        guard record.keyDown || isAltCodeRelease else { return [] }

        let modifiers = Self.modifiers(for: record.controlKeyState)
        if (0x60...0x69).contains(record.virtualKeyCode),
           modifiers.contains(.alt),
           !modifiers.contains(.shift),
           !modifiers.contains(.control)
        {
            return []
        }

        if let named = Self.namedKey(record.virtualKeyCode) {
            pendingHighSurrogate = nil
            let event: TerminalInputEvent
            if modifiers.isEmpty {
                switch named {
                case .enter: event = .control(.enter)
                case .tab: event = .control(.tab)
                case .backspace: event = .control(.backspace)
                case .escape: event = .control(.escape)
                default: event = .key(.named(named, modifiers: modifiers))
                }
            } else {
                event = .key(.named(named, modifiers: modifiers))
            }
            return repeated(event, count: record.repeatCount)
        }

        if [UInt16(0x10), 0x11, 0x12].contains(record.virtualKeyCode),
           !isAltCodeRelease
        {
            return []
        }

        let codeUnit = record.utf16CodeUnit
        if (0xd800...0xdbff).contains(codeUnit) {
            pendingHighSurrogate = codeUnit
            return []
        }
        if (0xdc00...0xdfff).contains(codeUnit) {
            guard let high = pendingHighSurrogate else { return [] }
            pendingHighSurrogate = nil
            let scalarValue = 0x1_0000
                + ((UInt32(high) - 0xd800) << 10)
                + (UInt32(codeUnit) - 0xdc00)
            guard let scalar = UnicodeScalar(scalarValue) else { return [] }
            return repeated(characterEvent(String(scalar), modifiers: modifiers), count: record.repeatCount)
        }
        pendingHighSurrogate = nil

        if codeUnit <= 0x1f {
            if modifiers == .control {
                let control: TerminalControlKey
                switch codeUnit {
                case 0: control = .null
                case 3: control = .interrupt
                case 4: control = .eof
                case 26: control = .suspend
                default: control = .character(UInt8(codeUnit))
                }
                return repeated(.control(control), count: record.repeatCount)
            }
            guard (0x41...0x5a).contains(record.virtualKeyCode),
                  let scalar = UnicodeScalar(UInt32(record.virtualKeyCode + 0x20))
            else {
                return []
            }
            return repeated(characterEvent(String(scalar), modifiers: modifiers), count: record.repeatCount)
        }

        guard let scalar = UnicodeScalar(UInt32(codeUnit)) else { return [] }
        return repeated(characterEvent(String(scalar), modifiers: modifiers), count: record.repeatCount)
    }

    private func characterEvent(
        _ value: String,
        modifiers: TerminalKeyModifiers
    ) -> TerminalInputEvent {
        modifiers.isEmpty ? .text(value) : .key(.character(value, modifiers: modifiers))
    }

    private func repeated(_ event: TerminalInputEvent, count: UInt16) -> [TerminalInputEvent] {
        Array(repeating: event, count: max(1, Int(count)))
    }

    private static func namedKey(_ virtualKeyCode: UInt16) -> TerminalNamedKey? {
        switch virtualKeyCode {
        case 0x08: return .backspace
        case 0x09: return .tab
        case 0x0d: return .enter
        case 0x1b: return .escape
        case 0x21: return .pageUp
        case 0x22: return .pageDown
        case 0x23: return .end
        case 0x24: return .home
        case 0x25: return .left
        case 0x26: return .up
        case 0x27: return .right
        case 0x28: return .down
        case 0x2d: return .insert
        case 0x2e: return .delete
        case 0x70...0x87: return .function(Int(virtualKeyCode) - 0x6f)
        default: return nil
        }
    }

    private static func modifiers(for state: UInt32) -> TerminalKeyModifiers {
        var result: TerminalKeyModifiers = []
        if state & Modifier.shift != 0 { result.insert(.shift) }
        if state & (Modifier.leftAlt | Modifier.rightAlt) != 0 { result.insert(.alt) }
        if state & (Modifier.leftControl | Modifier.rightControl) != 0 {
            result.insert(.control)
        }
        return result
    }

    private mutating func encodeMouse(_ record: WindowsConsoleMouseRecord) -> String? {
        let previous = pressedMouseButtons
        let current = record.buttonState & 0xffff
        var code: Int
        var final = "M"

        switch record.eventFlags {
        case Mouse.verticalWheel:
            let delta = Int16(bitPattern: UInt16(truncatingIfNeeded: record.buttonState >> 16))
            guard delta != 0 else { return nil }
            code = delta > 0 ? 64 : 65
        case Mouse.horizontalWheel:
            let delta = Int16(bitPattern: UInt16(truncatingIfNeeded: record.buttonState >> 16))
            guard delta != 0 else { return nil }
            code = delta > 0 ? 67 : 66
        case Mouse.moved:
            if current & Mouse.right != 0 {
                code = 34
            } else if current & Mouse.middle != 0 {
                code = 33
            } else if current & Mouse.left != 0 {
                code = 32
            } else {
                code = 35
            }
        case 0, Mouse.doubleClick:
            if current & Mouse.left != 0, previous & Mouse.left == 0 {
                code = 0
            } else if current & Mouse.left == 0, previous & Mouse.left != 0 {
                code = 0
                final = "m"
            } else if current & Mouse.right != 0, previous & Mouse.right == 0 {
                code = 2
            } else if current & Mouse.right == 0, previous & Mouse.right != 0 {
                code = 2
                final = "m"
            } else if current & Mouse.middle != 0, previous & Mouse.middle == 0 {
                code = 1
            } else if current & Mouse.middle == 0, previous & Mouse.middle != 0 {
                code = 1
                final = "m"
            } else if record.eventFlags == Mouse.doubleClick {
                if current & Mouse.left != 0 {
                    code = 0
                } else if current & Mouse.right != 0 {
                    code = 2
                } else if current & Mouse.middle != 0 {
                    code = 1
                } else {
                    return nil
                }
            } else {
                return nil
            }
        default:
            return nil
        }

        pressedMouseButtons = current
        let modifiers = Self.modifiers(for: record.controlKeyState)
        if modifiers.contains(.shift) { code |= 4 }
        if modifiers.contains(.alt) { code |= 8 }
        if modifiers.contains(.control) { code |= 16 }

        let column = max(0, min(record.column, Int(UInt16.max) - 1)) + 1
        let row = max(0, min(record.row - record.windowTop, Int(UInt16.max) - 1)) + 1
        return "\u{1b}[<\(code);\(column);\(row)\(final)"
    }
}

#if os(Windows) && canImport(WinSDK)
import Dispatch
import OpenGrokTerminalCore
import WinSDK

private struct WindowsPendingRead {
    let token: Foundation.UUID
    let continuation: CheckedContinuation<TerminalInputEvent?, Error>
}

private final class WindowsConsoleInputState: @unchecked Sendable {
    private let lock = NSLock()
    private let inputHandle: HANDLE
    private let closeInputHandle: Bool
    private let escapeTimeoutMilliseconds: DWORD
    private var wakeHandle: HANDLE?
    private var decoder = WindowsConsoleEventDecoder()
    private var byteDecoder = TerminalInputDecoder()
    private var xtversionFilter: XtversionReplyFilter
    private var xtversionPayload: String?
    private var eventQueue: [TerminalInputEvent] = []
    private var byteQueue: [UInt8] = []
    private var pendingRead: WindowsPendingRead?
    private var parkWaiter: CheckedContinuation<Bool, Never>?
    private var closed = false
    private var paused = false
    private var workerParked = false

    init(
        inputHandle: HANDLE,
        closeInputHandle: Bool,
        escapeTimeoutMilliseconds: Int32,
        swallowXtversionReply: Bool
    ) throws {
        guard let wake = CreateEventW(nil, true, false, nil),
              wake != INVALID_HANDLE_VALUE
        else {
            throw TerminalInputError.ioFailed("CreateEventW failed: \(GetLastError())")
        }
        self.inputHandle = inputHandle
        self.closeInputHandle = closeInputHandle
        self.escapeTimeoutMilliseconds = DWORD(escapeTimeoutMilliseconds)
        self.wakeHandle = wake
        self.xtversionFilter = XtversionReplyFilter(armed: swallowXtversionReply)
    }

    func startWorker() {
        Thread.detachNewThread { [self] in
            workerLoop()
        }
    }

    func nextEvent() async throws -> TerminalInputEvent? {
        if Task.isCancelled { throw TerminalInputError.cancelled }
        let token = Foundation.UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                installRead(token: token, continuation: continuation)
            }
        }, onCancel: {
            cancelRead(token: token)
        })
    }

    func nextByte() async throws -> UInt8? {
        if let byte = takeQueuedByte() { return byte }
        while let event = try await nextEvent() {
            let bytes: [UInt8]
            switch event {
            case .text(let value): bytes = Array(value.utf8)
            case .key(.character(let value, _)): bytes = Array(value.utf8)
            case .unknown(let data): bytes = Array(data)
            case .control(.null): bytes = [0]
            case .control(.character(let byte)): bytes = [byte]
            case .control(.interrupt): bytes = [3]
            case .control(.eof): bytes = [4]
            case .control(.backspace): bytes = [8]
            case .control(.tab): bytes = [9]
            case .control(.enter): bytes = [13]
            case .control(.escape): bytes = [27]
            case .control(.suspend): bytes = [26]
            case .control(.delete): bytes = [127]
            default: continue
            }
            guard let first = bytes.first else { continue }
            appendQueuedBytes(Array(bytes.dropFirst()))
            return first
        }
        return nil
    }

    func requestClose() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        let read = pendingRead
        pendingRead = nil
        let waiter = parkWaiter
        parkWaiter = nil
        signalWakeLocked()
        lock.unlock()
        read?.continuation.resume(throwing: TerminalInputError.closed)
        waiter?.resume(returning: false)
    }

    func pause() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            if closed || workerParked {
                paused = true
                lock.unlock()
                continuation.resume(returning: true)
                return
            }
            paused = true
            if let previous = parkWaiter {
                parkWaiter = continuation
                signalWakeLocked()
                lock.unlock()
                previous.resume(returning: false)
            } else {
                parkWaiter = continuation
                signalWakeLocked()
                lock.unlock()
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.expirePark()
            }
        }
    }

    func resume() {
        lock.lock()
        paused = false
        let waiter = parkWaiter
        parkWaiter = nil
        signalWakeLocked()
        lock.unlock()
        waiter?.resume(returning: false)
    }

    func discardPendingInput() {
        lock.lock()
        guard paused, workerParked, !closed else {
            lock.unlock()
            return
        }
        _ = FlushConsoleInputBuffer(inputHandle)
        decoder.reset()
        byteDecoder = TerminalInputDecoder()
        xtversionFilter = XtversionReplyFilter(armed: xtversionFilter.armed)
        eventQueue.removeAll()
        byteQueue.removeAll()
        lock.unlock()
    }

    var lastXtversionPayload: String? {
        lock.lock()
        defer { lock.unlock() }
        return xtversionPayload
    }

    var isXtversionArmed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return xtversionFilter.armed
    }

    func setXtversionArmed(_ enabled: Bool) {
        lock.lock()
        xtversionFilter = XtversionReplyFilter(armed: enabled)
        lock.unlock()
    }

    private func installRead(
        token: Foundation.UUID,
        continuation: CheckedContinuation<TerminalInputEvent?, Error>
    ) {
        if Task.isCancelled {
            continuation.resume(throwing: TerminalInputError.cancelled)
            return
        }
        lock.lock()
        if closed {
            lock.unlock()
            continuation.resume(throwing: TerminalInputError.closed)
        } else if pendingRead != nil {
            lock.unlock()
            continuation.resume(throwing: TerminalInputError.concurrentRead)
        } else if !eventQueue.isEmpty {
            let event = eventQueue.removeFirst()
            lock.unlock()
            continuation.resume(returning: event)
        } else {
            pendingRead = WindowsPendingRead(token: token, continuation: continuation)
            lock.unlock()
        }
    }

    private func cancelRead(token: Foundation.UUID) {
        lock.lock()
        guard let read = pendingRead, read.token == token else {
            lock.unlock()
            return
        }
        pendingRead = nil
        signalWakeLocked()
        lock.unlock()
        read.continuation.resume(throwing: TerminalInputError.cancelled)
    }

    private func expirePark() {
        lock.lock()
        guard let waiter = parkWaiter else {
            lock.unlock()
            return
        }
        parkWaiter = nil
        paused = false
        signalWakeLocked()
        lock.unlock()
        waiter.resume(returning: false)
    }

    private func workerLoop() {
        defer { finishWorker() }
        while true {
            lock.lock()
            guard !closed, let wake = wakeHandle else {
                lock.unlock()
                return
            }
            if paused {
                workerParked = true
                let waiter = parkWaiter
                parkWaiter = nil
                lock.unlock()
                waiter?.resume(returning: true)
                let wait = WaitForSingleObject(wake, DWORD.max)
                guard wait == 0 else {
                    failWorker("WaitForSingleObject failed: \(GetLastError())")
                    return
                }
                _ = ResetEvent(wake)
                lock.lock()
                workerParked = false
                lock.unlock()
                continue
            }

            let timeout = (xtversionFilter.holding || byteDecoder.hasPendingEscapeSequence)
                ? escapeTimeoutMilliseconds
                : DWORD.max
            lock.unlock()

            let handles: [HANDLE?] = [wake, inputHandle]
            let wait = handles.withUnsafeBufferPointer { buffer in
                WaitForMultipleObjects(DWORD(buffer.count), buffer.baseAddress, false, timeout)
            }
            switch wait {
            case 0:
                _ = ResetEvent(wake)
            case 1:
                guard let native = readConsoleRecord() else { return }
                deliver(native)
            case 0x0000_0102:
                flushHeldEscape()
            default:
                failWorker("WaitForMultipleObjects failed: \(GetLastError())")
                return
            }
        }
    }

    private func readConsoleRecord() -> WindowsConsoleInputRecord? {
        var record = INPUT_RECORD()
        var read: DWORD = 0
        guard ReadConsoleInputW(inputHandle, &record, 1, &read), read == 1 else {
            failWorker("ReadConsoleInputW failed: \(GetLastError())")
            return nil
        }

        switch record.EventType {
        case 0x0001:
            let key = record.Event.KeyEvent
            return .key(WindowsConsoleKeyRecord(
                utf16CodeUnit: key.uChar.UnicodeChar,
                virtualKeyCode: key.wVirtualKeyCode,
                keyDown: key.bKeyDown.boolValue,
                repeatCount: key.wRepeatCount,
                controlKeyState: key.dwControlKeyState
            ))
        case 0x0002:
            let mouse = record.Event.MouseEvent
            return .mouse(WindowsConsoleMouseRecord(
                column: Int(mouse.dwMousePosition.X),
                row: Int(mouse.dwMousePosition.Y),
                buttonState: mouse.dwButtonState,
                controlKeyState: mouse.dwControlKeyState,
                eventFlags: mouse.dwEventFlags,
                windowTop: WindowsConsole.screenWindowTop()
            ))
        case 0x0004:
            let size = record.Event.WindowBufferSizeEvent.dwSize
            let visible = WindowsConsole.screenSize(fd: 1)
            return .resize(
                width: visible?.width ?? Int(size.X),
                height: visible?.height ?? Int(size.Y)
            )
        case 0x0010:
            return .focus(record.Event.FocusEvent.bSetFocus.boolValue)
        default:
            // Menu records do not correspond to interactive input.
            return .resize(width: 0, height: 0)
        }
    }

    private func deliver(_ native: WindowsConsoleInputRecord) {
        lock.lock()
        let events = decoder.decode(native)
        var produced: [TerminalInputEvent] = []
        for event in events {
            switch event {
            case .text(let text):
                appendFiltered(Array(text.utf8), into: &produced)
            case .control(.escape):
                appendFiltered([0x1b], into: &produced)
            default:
                produced.append(event)
            }
        }
        eventQueue.append(contentsOf: produced)
        let pending = takeReadyReadLocked()
        lock.unlock()

        for event in produced {
            if case .resize(let size) = event {
                WindowsConsoleResizeRegistry.shared.publish(size)
            }
        }
        pending?.continuation.resume(returning: pending?.event)
    }

    private func appendFiltered(_ bytes: [UInt8], into output: inout [TerminalInputEvent]) {
        for byte in bytes {
            let step = xtversionFilter.feed([byte])
            if let payload = step.completedPayload {
                xtversionPayload = payload
            }
            for residual in step.residual {
                if let events = try? byteDecoder.feed(residual) {
                    output.append(contentsOf: events)
                }
            }
        }
    }

    private func flushHeldEscape() {
        lock.lock()
        var produced: [TerminalInputEvent] = []
        if xtversionFilter.holding {
            for byte in xtversionFilter.resolveDeadHold() {
                if let events = try? byteDecoder.feed(byte) {
                    produced.append(contentsOf: events)
                }
            }
        }
        if let events = try? byteDecoder.finish() {
            produced.append(contentsOf: events)
        }
        eventQueue.append(contentsOf: produced)
        let pending = takeReadyReadLocked()
        lock.unlock()
        pending?.continuation.resume(returning: pending?.event)
    }

    private func takeReadyReadLocked() -> (
        continuation: CheckedContinuation<TerminalInputEvent?, Error>,
        event: TerminalInputEvent
    )? {
        guard let pendingRead, !eventQueue.isEmpty else { return nil }
        self.pendingRead = nil
        return (pendingRead.continuation, eventQueue.removeFirst())
    }

    private func takeQueuedByte() -> UInt8? {
        lock.lock()
        defer { lock.unlock() }
        guard !byteQueue.isEmpty else { return nil }
        return byteQueue.removeFirst()
    }

    private func appendQueuedBytes(_ bytes: [UInt8]) {
        lock.lock()
        byteQueue.append(contentsOf: bytes)
        lock.unlock()
    }

    private func failWorker(_ message: String) {
        lock.lock()
        closed = true
        let read = pendingRead
        pendingRead = nil
        let waiter = parkWaiter
        parkWaiter = nil
        lock.unlock()
        read?.continuation.resume(throwing: TerminalInputError.ioFailed(message))
        waiter?.resume(returning: false)
    }

    private func finishWorker() {
        lock.lock()
        let wake = wakeHandle
        wakeHandle = nil
        lock.unlock()
        if let wake { _ = CloseHandle(wake) }
        if closeInputHandle { _ = CloseHandle(inputHandle) }
    }

    private func signalWakeLocked() {
        if let wake = wakeHandle {
            _ = SetEvent(wake)
        }
    }
}

public final class WindowsTerminalInput: TerminalInput, @unchecked Sendable {
    public let identifier: String?
    private let state: WindowsConsoleInputState

    public init(
        fd: Int32 = 0,
        escapeSequenceTimeoutMilliseconds: Int32 = 50,
        closeFileDescriptor: Bool = false,
        identifier: String? = nil,
        swallowXtversionReply: Bool = true
    ) throws {
        guard escapeSequenceTimeoutMilliseconds >= 0 else {
            throw TerminalInputError.unsupported("escape sequence timeout cannot be negative")
        }
        guard fd == 0, WindowsConsole.isAttached(fd: fd),
              let handle = WindowsConsole.standardHandle(fd: fd)
        else {
            throw TerminalInputError.unsupported("stdin is not an attached Windows console")
        }
        self.identifier = identifier ?? "fd:\(fd)"
        self.state = try WindowsConsoleInputState(
            inputHandle: handle,
            closeInputHandle: closeFileDescriptor,
            escapeTimeoutMilliseconds: escapeSequenceTimeoutMilliseconds,
            swallowXtversionReply: swallowXtversionReply
        )
        state.startWorker()
    }

    deinit {
        state.requestClose()
    }

    public func readByte() async throws -> UInt8? {
        try await state.nextByte()
    }

    public func readEvent() async throws -> TerminalInputEvent? {
        try await state.nextEvent()
    }

    public func close() async {
        state.requestClose()
    }

    public func pauseReads() async -> Bool {
        await state.pause()
    }

    public func resumeReads() {
        state.resume()
    }

    public func discardPendingInput() {
        state.discardPendingInput()
    }

    public var lastSwallowedXtversionPayload: String? {
        state.lastXtversionPayload
    }

    public var isXtversionReplyFilterArmed: Bool {
        state.isXtversionArmed
    }

    public func setSwallowXtversionReply(_ enabled: Bool) {
        state.setXtversionArmed(enabled)
    }
}

private final class WindowsConsoleResizeRegistry: @unchecked Sendable {
    static let shared = WindowsConsoleResizeRegistry()

    private let lock = NSLock()
    private var callbacks: [Foundation.UUID: @Sendable (TerminalSize) -> Void] = [:]

    func register(id: Foundation.UUID, callback: @escaping @Sendable (TerminalSize) -> Void) {
        lock.lock()
        callbacks[id] = callback
        lock.unlock()
    }

    func remove(id: Foundation.UUID) {
        lock.lock()
        callbacks.removeValue(forKey: id)
        lock.unlock()
    }

    func publish(_ size: TerminalSize) {
        lock.lock()
        let snapshot = Array(callbacks.values)
        lock.unlock()
        for callback in snapshot {
            callback(size)
        }
    }
}

public final class WindowsTerminalResizeMonitor: TerminalResizeSource, @unchecked Sendable {
    private let fd: Int32
    private let intervalNanoseconds: UInt64
    private let id = Foundation.UUID()
    private let lock = NSLock()
    private var continuation: AsyncStream<TerminalSize>.Continuation?
    private var pollTask: Task<Void, Never>?
    private var lastSize: TerminalSize?
    private var started = false
    private var stopped = false

    public init(fd: Int32 = 0, pollIntervalMilliseconds: UInt64 = 100) {
        self.fd = fd
        self.intervalNanoseconds = max(1, pollIntervalMilliseconds) * 1_000_000
    }

    deinit {
        stop()
    }

    public func events() -> AsyncStream<TerminalSize> {
        lock.lock()
        guard !started, !stopped else {
            lock.unlock()
            return AsyncStream<TerminalSize>(bufferingPolicy: .unbounded) { $0.finish() }
        }
        started = true
        lock.unlock()

        return AsyncStream<TerminalSize>(bufferingPolicy: .unbounded) { continuation in
            lock.lock()
            guard !stopped else {
                lock.unlock()
                continuation.finish()
                return
            }
            self.continuation = continuation
            lock.unlock()

            WindowsConsoleResizeRegistry.shared.register(id: id) { [weak self] size in
                self?.emit(size)
            }
            if let size = WindowsConsole.screenSize(fd: fd) {
                emit(size)
            }
            continuation.onTermination = { [weak self] _ in
                self?.stop()
            }
            installPollingTask()
        }
    }

    public func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        let stream = continuation
        continuation = nil
        let task = pollTask
        pollTask = nil
        lock.unlock()

        WindowsConsoleResizeRegistry.shared.remove(id: id)
        task?.cancel()
        stream?.finish()
    }

    private func emit(_ size: TerminalSize) {
        lock.lock()
        guard !stopped, size != lastSize else {
            lock.unlock()
            return
        }
        lastSize = size
        let stream = continuation
        lock.unlock()
        stream?.yield(size)
    }

    private func installPollingTask() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        let interval = intervalNanoseconds
        let descriptor = fd
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    return
                }
                if let size = WindowsConsole.screenSize(fd: descriptor) {
                    self?.emit(size)
                }
            }
        }
        lock.unlock()
    }
}
#endif
