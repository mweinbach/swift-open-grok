import Foundation
import Testing
@testable import OpenGrokTTY

#if os(Windows) && canImport(WinSDK)
import WinSDK
#endif

@Suite("Windows console input and mode parity", .serialized)
struct WindowsConsoleParityTests {
    @Test("raw console mode preserves unrelated flags and disables QuickEdit")
    func rawConsoleMode() {
        let unrelated: UInt32 = 0x4000
        let original = unrelated
            | WindowsConsoleMode.processedInput
            | WindowsConsoleMode.lineInput
            | WindowsConsoleMode.echoInput
            | WindowsConsoleMode.quickEditMode
            | WindowsConsoleMode.insertMode
            | WindowsConsoleMode.virtualTerminalInput
        let raw = WindowsConsoleMode.rawInputMode(original)

        #expect(raw & unrelated == unrelated)
        #expect(raw & WindowsConsoleMode.processedInput == 0)
        #expect(raw & WindowsConsoleMode.lineInput == 0)
        #expect(raw & WindowsConsoleMode.echoInput == 0)
        #expect(raw & WindowsConsoleMode.quickEditMode == 0)
        #expect(raw & WindowsConsoleMode.insertMode == 0)
        #expect(raw & WindowsConsoleMode.virtualTerminalInput == 0)
        #expect(raw & WindowsConsoleMode.windowInput != 0)
        #expect(raw & WindowsConsoleMode.mouseInput != 0)
        #expect(raw & WindowsConsoleMode.extendedFlags != 0)
        #expect(WindowsConsoleMode.rawInputMode(raw) == raw)
    }

    @Test("minimal console mode restores native selection ownership")
    func nativeSelectionMode() {
        let original = WindowsConsoleMode.mouseInput
            | WindowsConsoleMode.processedInput
            | WindowsConsoleMode.virtualTerminalInput
        let selection = WindowsConsoleMode.nativeSelectionMode(original)

        #expect(selection & WindowsConsoleMode.mouseInput == 0)
        #expect(selection & WindowsConsoleMode.quickEditMode != 0)
        #expect(selection & WindowsConsoleMode.extendedFlags != 0)
        #expect(selection & WindowsConsoleMode.windowInput != 0)
        #expect(selection & WindowsConsoleMode.processedInput != 0)
        #expect(selection & WindowsConsoleMode.virtualTerminalInput != 0)
        #expect(WindowsConsoleMode.nativeSelectionMode(selection) == selection)
    }

    @Test("console output preserves flags while enabling processed VT output")
    func outputMode() {
        let unrelated: UInt32 = 0x0010
        let mode = WindowsConsoleMode.virtualTerminalOutputMode(unrelated)
        #expect(mode & unrelated != 0)
        #expect(mode & WindowsConsoleMode.processedOutput != 0)
        #expect(mode & WindowsConsoleMode.virtualTerminalProcessing != 0)
    }

    @Test("UTF-16 surrogate pairs produce exactly one complete Unicode scalar")
    func surrogatePairs() {
        var decoder = WindowsConsoleEventDecoder()
        #expect(decoder.decode(.key(.init(utf16CodeUnit: 0xd83e))) == [])
        #expect(decoder.decode(.key(.init(utf16CodeUnit: 0xdd8a))) == [.text("🦊")])
        #expect(decoder.decode(.key(.init(utf16CodeUnit: 0xdd8a))) == [])

        #expect(decoder.decode(.key(.init(utf16CodeUnit: 0xd83d))) == [])
        #expect(decoder.decode(.key(.init(utf16CodeUnit: 0x61))) == [.text("a")])
        #expect(decoder.decode(.key(.init(utf16CodeUnit: 0xde00))) == [])
    }

    @Test("virtual keys, repeat counts, and all Win32 modifier bits survive")
    func namedKeysAndModifiers() {
        var decoder = WindowsConsoleEventDecoder()
        let modified = WindowsConsoleKeyRecord(
            utf16CodeUnit: 0,
            virtualKeyCode: 0x26,
            controlKeyState: 0x0010 | 0x0002 | 0x0004
        )
        #expect(decoder.decode(.key(modified)) == [
            .key(.named(.up, modifiers: [.shift, .alt, .control]))
        ])
        #expect(decoder.decode(.key(.init(
            utf16CodeUnit: 0,
            virtualKeyCode: 0x87
        ))) == [.key(.named(.function(24), modifiers: []))])
        #expect(decoder.decode(.key(.init(
            utf16CodeUnit: 0x78,
            virtualKeyCode: 0x58,
            repeatCount: 3
        ))) == [.text("x"), .text("x"), .text("x")])
        #expect(decoder.decode(.key(.init(
            utf16CodeUnit: 0x78,
            virtualKeyCode: 0x58,
            keyDown: false
        ))) == [])
    }

    @Test("control characters and Alt-code release preserve upstream behavior")
    func controlsAndAltCodes() {
        var decoder = WindowsConsoleEventDecoder()
        #expect(decoder.decode(.key(.init(
            utf16CodeUnit: 3,
            virtualKeyCode: 0x43,
            controlKeyState: 0x0008
        ))) == [.control(.interrupt)])
        #expect(decoder.decode(.key(.init(
            utf16CodeUnit: 4,
            virtualKeyCode: 0x44,
            controlKeyState: 0x0004
        ))) == [.control(.eof)])
        #expect(decoder.decode(.key(.init(
            utf16CodeUnit: 0x65,
            virtualKeyCode: 0x12,
            keyDown: false
        ))) == [.text("e")])
        #expect(decoder.decode(.key(.init(
            utf16CodeUnit: 0x35,
            virtualKeyCode: 0x65,
            controlKeyState: 0x0002
        ))) == [])
    }

    @Test("mouse button transitions synthesize the live SGR protocol")
    func mouseButtonReports() {
        var decoder = WindowsConsoleEventDecoder()
        #expect(decoder.decode(.mouse(.init(
            column: 9,
            row: 25,
            buttonState: 0x0001,
            windowTop: 20
        ))) == [.unknown(Data("\u{1b}[<0;10;6M".utf8))])
        #expect(decoder.decode(.mouse(.init(
            column: 9,
            row: 25,
            buttonState: 0,
            windowTop: 20
        ))) == [.unknown(Data("\u{1b}[<0;10;6m".utf8))])
        #expect(decoder.decode(.mouse(.init(
            column: 0,
            row: 0,
            buttonState: 0x0004,
            controlKeyState: 0x0010 | 0x0002 | 0x0008
        ))) == [.unknown(Data("\u{1b}[<29;1;1M".utf8))])
    }

    @Test("mouse move, drag, vertical wheel, and horizontal wheel encode correctly")
    func mouseMotionAndWheel() {
        var decoder = WindowsConsoleEventDecoder()
        #expect(decoder.decode(.mouse(.init(
            column: 2,
            row: 3,
            buttonState: 0,
            eventFlags: 0x0001
        ))) == [.unknown(Data("\u{1b}[<35;3;4M".utf8))])
        #expect(decoder.decode(.mouse(.init(
            column: 2,
            row: 3,
            buttonState: 0x0002,
            eventFlags: 0x0001
        ))) == [.unknown(Data("\u{1b}[<34;3;4M".utf8))])
        #expect(decoder.decode(.mouse(.init(
            column: 2,
            row: 3,
            buttonState: UInt32(UInt16(bitPattern: 120)) << 16,
            eventFlags: 0x0004
        ))) == [.unknown(Data("\u{1b}[<64;3;4M".utf8))])
        #expect(decoder.decode(.mouse(.init(
            column: 2,
            row: 3,
            buttonState: UInt32(UInt16(bitPattern: -120)) << 16,
            eventFlags: 0x0004
        ))) == [.unknown(Data("\u{1b}[<65;3;4M".utf8))])
        #expect(decoder.decode(.mouse(.init(
            column: 2,
            row: 3,
            buttonState: UInt32(UInt16(bitPattern: -120)) << 16,
            eventFlags: 0x0008
        ))) == [.unknown(Data("\u{1b}[<66;3;4M".utf8))])
        #expect(decoder.decode(.mouse(.init(
            column: 2,
            row: 3,
            buttonState: UInt32(UInt16(bitPattern: 120)) << 16,
            eventFlags: 0x0008
        ))) == [.unknown(Data("\u{1b}[<67;3;4M".utf8))])
    }

    @Test("native focus and visible resize records become terminal events")
    func focusAndResize() {
        var decoder = WindowsConsoleEventDecoder()
        #expect(decoder.decode(.focus(true)) == [.focusGained])
        #expect(decoder.decode(.focus(false)) == [.focusLost])
        #expect(decoder.decode(.resize(width: 120, height: 40)) == [
            .resize(TerminalSize(width: 120, height: 40))
        ])
        #expect(decoder.decode(.resize(width: 0, height: 40)) == [])
    }

    #if os(Windows) && canImport(WinSDK)
    @Test("native console leases restore exactly and injected input reaches the reader")
    func nativeConsoleRoundTrip() async throws {
        let alreadyAttached = WindowsConsole.isAttached(fd: 0)
        if !alreadyAttached {
            guard AllocConsole() else { return }
        }
        defer {
            if !alreadyAttached {
                _ = FreeConsole()
            }
        }

        guard let input = GetStdHandle(STD_INPUT_HANDLE),
              input != INVALID_HANDLE_VALUE
        else {
            Issue.record("allocated console has no standard input handle")
            return
        }
        var originalMode: DWORD = 0
        guard GetConsoleMode(input, &originalMode) else {
            Issue.record("allocated console input mode is unavailable")
            return
        }
        let originalInputCodePage = GetConsoleCP()
        let originalOutputCodePage = GetConsoleOutputCP()

        let firstAdapter = PlatformTTYAdapter(fd: 0)
        let secondAdapter = PlatformTTYAdapter(fd: 0)
        #expect(firstAdapter.identifier == "fd:0")
        #expect(firstAdapter.isATTY())

        let first = try await firstAdapter.enterRawMode()
        let second = try await secondAdapter.enterRawMode()
        await first.release()

        var activeMode: DWORD = 0
        #expect(GetConsoleMode(input, &activeMode))
        #expect(activeMode == DWORD(WindowsConsoleMode.rawInputMode(UInt32(originalMode))))
        #expect(GetConsoleCP() == 65_001)
        #expect(GetConsoleOutputCP() == 65_001)

        #expect(FlushConsoleInputBuffer(input))
        let reader = try PlatformTerminalInput()
        var record = INPUT_RECORD()
        record.EventType = 0x0001
        record.Event.KeyEvent.bKeyDown = true
        record.Event.KeyEvent.wRepeatCount = 1
        record.Event.KeyEvent.wVirtualKeyCode = 0x41
        record.Event.KeyEvent.uChar.UnicodeChar = 0x61
        var written: DWORD = 0
        guard WriteConsoleInputW(input, &record, 1, &written), written == 1 else {
            await reader.close()
            await second.release()
            Issue.record("WriteConsoleInputW failed: \(GetLastError())")
            return
        }
        #expect(try await reader.readEvent() == .text("a"))

        let cancelledRead = Task {
            try await reader.readEvent()
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        cancelledRead.cancel()
        do {
            _ = try await cancelledRead.value
            Issue.record("cancelled console read unexpectedly completed")
        } catch TerminalInputError.cancelled {
            // The wake handle must interrupt WaitForMultipleObjects promptly.
        }
        await reader.close()
        await second.release()
        await second.release()

        var restoredMode: DWORD = 0
        #expect(GetConsoleMode(input, &restoredMode))
        #expect(restoredMode == originalMode)
        #expect(GetConsoleCP() == originalInputCodePage)
        #expect(GetConsoleOutputCP() == originalOutputCodePage)
    }
    #endif
}
