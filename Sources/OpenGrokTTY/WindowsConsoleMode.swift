import Foundation

/// Console-mode arithmetic stays platform independent so the Windows contract
/// remains regression-testable from the ordinary macOS and Linux test suites.
public enum WindowsConsoleMode {
    public static let processedInput: UInt32 = 0x0001
    public static let lineInput: UInt32 = 0x0002
    public static let echoInput: UInt32 = 0x0004
    public static let windowInput: UInt32 = 0x0008
    public static let mouseInput: UInt32 = 0x0010
    public static let insertMode: UInt32 = 0x0020
    public static let quickEditMode: UInt32 = 0x0040
    public static let extendedFlags: UInt32 = 0x0080
    public static let virtualTerminalInput: UInt32 = 0x0200

    public static let processedOutput: UInt32 = 0x0001
    public static let virtualTerminalProcessing: UInt32 = 0x0004

    /// Native input records require mouse/window delivery, not translated VT
    /// input. Extended flags make disabling QuickEdit effective on conhost.
    public static func rawInputMode(_ original: UInt32) -> UInt32 {
        let disabled = processedInput | lineInput | echoInput
            | quickEditMode | insertMode | virtualTerminalInput
        return (original & ~disabled) | windowInput | mouseInput | extendedFlags
    }

    /// Upstream's minimal-mode setting gives selection ownership back to the
    /// console while retaining native resize notifications.
    public static func nativeSelectionMode(_ original: UInt32) -> UInt32 {
        (original & ~mouseInput) | extendedFlags | quickEditMode | windowInput
    }

    public static func virtualTerminalOutputMode(_ original: UInt32) -> UInt32 {
        original | processedOutput | virtualTerminalProcessing
    }
}

#if os(Windows) && canImport(WinSDK)
import WinSDK

enum WindowsConsole {
    static func standardHandle(fd: Int32) -> HANDLE? {
        let selector: DWORD
        switch fd {
        case 0: selector = STD_INPUT_HANDLE
        case 1: selector = STD_OUTPUT_HANDLE
        case 2: selector = STD_ERROR_HANDLE
        default: return nil
        }
        guard let handle = GetStdHandle(selector), handle != INVALID_HANDLE_VALUE else {
            return nil
        }
        return handle
    }

    static func mode(fd: Int32) -> (handle: HANDLE, value: DWORD)? {
        guard let handle = standardHandle(fd: fd) else { return nil }
        var mode: DWORD = 0
        guard GetConsoleMode(handle, &mode) else { return nil }
        return (handle, mode)
    }

    static func isAttached(fd: Int32) -> Bool {
        mode(fd: fd) != nil
    }

    static func screenSize(fd: Int32) -> TerminalSize? {
        let candidates: [Int32] = fd == 0 ? [1, 2] : [fd]
        for candidate in candidates {
            guard let handle = standardHandle(fd: candidate) else { continue }
            var information = CONSOLE_SCREEN_BUFFER_INFO()
            guard GetConsoleScreenBufferInfo(handle, &information) else { continue }
            let width = Int(information.srWindow.Right)
                - Int(information.srWindow.Left) + 1
            let height = Int(information.srWindow.Bottom)
                - Int(information.srWindow.Top) + 1
            guard width > 0, height > 0 else { continue }
            return TerminalSize(width: width, height: height)
        }
        return nil
    }

    static func screenWindowTop() -> Int {
        for fd: Int32 in [1, 2] {
            guard let handle = standardHandle(fd: fd) else { continue }
            var information = CONSOLE_SCREEN_BUFFER_INFO()
            if GetConsoleScreenBufferInfo(handle, &information) {
                return Int(information.srWindow.Top)
            }
        }
        return 0
    }

    static func write(_ data: Data, fd: Int32) throws {
        // POSIX tty descriptors are bidirectional; Windows separates console
        // input from its output handle. Startup probes still write through the
        // input adapter, so route only fd 0 to the actual output stream.
        let outputFD: Int32 = fd == 0 ? 1 : fd
        guard let handle = standardHandle(fd: outputFD) else {
            throw TTYError.ioFailed("standard handle \(outputFD) is unavailable")
        }

        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let remaining = bytes.count - offset
                let requested = DWORD(min(remaining, Int(DWORD.max)))
                var written: DWORD = 0
                guard WriteFile(
                    handle,
                    base.advanced(by: offset),
                    requested,
                    &written,
                    nil
                ) else {
                    throw TTYError.ioFailed("WriteFile failed: \(GetLastError())")
                }
                guard written > 0 else {
                    throw TTYError.ioFailed("WriteFile returned zero bytes")
                }
                offset += Int(written)
            }
        }
    }
}

private struct WindowsConsoleSnapshot {
    let inputHandle: HANDLE
    let inputMode: DWORD
    let outputModes: [(handle: HANDLE, mode: DWORD)]
    let inputCodePage: UINT
    let outputCodePage: UINT
}

final class WindowsConsoleModeCoordinator: @unchecked Sendable {
    static let shared = WindowsConsoleModeCoordinator()

    private let lock = NSLock()
    private var generations: Set<UInt64> = []
    private var nextGeneration: UInt64 = 1
    private var snapshot: WindowsConsoleSnapshot?

    private init() {}

    func enter(fd: Int32) throws -> any RawModeLease {
        lock.lock()
        defer { lock.unlock() }

        guard WindowsConsole.isAttached(fd: fd),
              let input = WindowsConsole.mode(fd: 0)
        else {
            throw TTYError.notATTY
        }

        if snapshot == nil {
            try applyRawMode(input: input)
        }

        let generation = nextGeneration
        nextGeneration &+= 1
        generations.insert(generation)
        return WindowsRawModeLease(generation: generation, coordinator: self)
    }

    func release(generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard generations.remove(generation) != nil,
              generations.isEmpty,
              let original = snapshot
        else {
            return
        }
        restore(original)
        snapshot = nil
    }

    private func applyRawMode(input: (handle: HANDLE, value: DWORD)) throws {
        let outputModes = [Int32(1), Int32(2)].compactMap { fd in
            WindowsConsole.mode(fd: fd).map { (handle: $0.handle, mode: $0.value) }
        }
        let original = WindowsConsoleSnapshot(
            inputHandle: input.handle,
            inputMode: input.value,
            outputModes: outputModes,
            inputCodePage: GetConsoleCP(),
            outputCodePage: GetConsoleOutputCP()
        )

        guard SetConsoleMode(
            original.inputHandle,
            DWORD(WindowsConsoleMode.rawInputMode(UInt32(original.inputMode)))
        ) else {
            throw TTYError.ioFailed("SetConsoleMode(input) failed: \(GetLastError())")
        }

        for output in original.outputModes {
            guard SetConsoleMode(
                output.handle,
                DWORD(WindowsConsoleMode.virtualTerminalOutputMode(UInt32(output.mode)))
            ) else {
                restore(original)
                throw TTYError.ioFailed("SetConsoleMode(output) failed: \(GetLastError())")
            }
        }

        if original.inputCodePage != 0,
           !SetConsoleCP(UINT(65_001))
        {
            restore(original)
            throw TTYError.ioFailed("SetConsoleCP(UTF-8) failed: \(GetLastError())")
        }
        if original.outputCodePage != 0,
           !SetConsoleOutputCP(UINT(65_001))
        {
            restore(original)
            throw TTYError.ioFailed("SetConsoleOutputCP(UTF-8) failed: \(GetLastError())")
        }

        snapshot = original
    }

    private func restore(_ original: WindowsConsoleSnapshot) {
        _ = SetConsoleMode(original.inputHandle, original.inputMode)
        for output in original.outputModes {
            _ = SetConsoleMode(output.handle, output.mode)
        }
        if original.inputCodePage != 0 {
            _ = SetConsoleCP(original.inputCodePage)
        }
        if original.outputCodePage != 0 {
            _ = SetConsoleOutputCP(original.outputCodePage)
        }
    }
}

private final class WindowsRawModeLease: RawModeLease, @unchecked Sendable {
    private let generation: UInt64
    private let coordinator: WindowsConsoleModeCoordinator
    private let lock = NSLock()
    private var released = false

    init(generation: UInt64, coordinator: WindowsConsoleModeCoordinator) {
        self.generation = generation
        self.coordinator = coordinator
    }

    deinit {
        releaseNow()
    }

    func release() async {
        releaseNow()
    }

    private func releaseNow() {
        lock.lock()
        guard !released else {
            lock.unlock()
            return
        }
        released = true
        lock.unlock()
        coordinator.release(generation: generation)
    }
}
#endif
