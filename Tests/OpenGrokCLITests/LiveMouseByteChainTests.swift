// LiveMouseByteChainTests.swift
//
// The live mouse path from raw terminal bytes to pager InputEvents:
// PosixTerminalInput's escape decoder delivers an SGR or legacy X10 report as
// `.unknown` (its CSI parser has no mouse arm), and the composition's
// translate glue recovers the event through MouseReportDecoder. Every prior
// mouse test injected synthetic `.mouse` events, so this seam had zero
// coverage — a break here is invisible everywhere else and reads as "mouse
// doesn't work".

import Foundation
import OpenGrokTerminalCore
import OpenGrokTTY
import Testing
@testable import OpenGrokCLI

@Suite("Live mouse byte chain")
struct LiveMouseByteChainTests {
    /// Feed raw bytes through a real PosixTerminalInput over a pipe and
    /// return InputEvents the way the live reader maps them: `.text` becomes
    /// composer keys (the X10 leak path), everything else goes through
    /// `translate`.
    private func translated(_ bytes: [UInt8]) async throws -> [InputEvent] {
        var descriptors: [Int32] = [0, 0]
        #expect(pipe(&descriptors) == 0)
        defer { close(descriptors[1]) }
        let input = try PlatformTerminalInput(
            fd: descriptors[0],
            closeFileDescriptor: true
        )
        #expect(write(descriptors[1], bytes, bytes.count) == bytes.count)

        var events: [InputEvent] = []
        // One read per decoded event; the byte burst is already in the pipe,
        // so each readEvent resolves without blocking on more input.
        while events.count < 32 {
            guard let event = try await input.readEvent() else { break }
            let mapped: [InputEvent]
            switch event {
            case .text(let text):
                // Mirror LiveComposition's text → key path so an X10 payload
                // leak fails this suite as `.key` rather than vanishing in
                // `translate` (which drops `.text`).
                mapped = text.map { character in
                    .key(KeyEvent(key: .char(character), character: character))
                }
            default:
                mapped = OpenGrokLiveInteractiveInput.translate(event)
            }
            events.append(contentsOf: mapped)
            if !mapped.isEmpty { break }
        }
        await input.close()
        return events
    }

    /// `ESC [ M Cb Cx Cy`, each payload byte biased by 32.
    private func x10(_ button: Int, _ column: Int, _ row: Int) -> [UInt8] {
        [
            0x1b, 0x5b, 0x4d,
            UInt8(button + 32),
            UInt8(column + 32),
            UInt8(row + 32),
        ]
    }

    @Test("an SGR wheel report becomes a scroll InputEvent")
    func sgrWheelDecodes() async throws {
        let events = try await translated(Array("\u{1B}[<64;10;5M".utf8))
        #expect(events == [.mouse(MouseEvent(
            kind: .scrollUp,
            x: 9,
            y: 4,
            button: MouseEvent.noButton
        ))])
    }

    @Test("an SGR left click becomes a down InputEvent")
    func sgrClickDecodes() async throws {
        let events = try await translated(Array("\u{1B}[<0;3;7M".utf8))
        #expect(events == [.mouse(MouseEvent(kind: .down, x: 2, y: 6, button: 0))])
    }

    @Test("an X10 left click becomes one mouse InputEvent, never a key")
    func x10ClickDecodes() async throws {
        let events = try await translated(x10(0, 3, 7))
        #expect(events == [.mouse(MouseEvent(kind: .down, x: 2, y: 6, button: 0))])
        #expect(events.filter { if case .key = $0 { true } else { false } }.isEmpty)
    }

    @Test("an X10 release becomes up with no button attribution")
    func x10ReleaseDecodesAsUpNone() async throws {
        // Wire button code 3 → `.up` + `.none`. Live click-to-select arms on
        // left-down and must complete against this release shape.
        let events = try await translated(x10(3, 3, 7))
        #expect(events == [.mouse(MouseEvent(
            kind: .up,
            x: 2,
            y: 6,
            button: .none
        ))])
        guard case .mouse(let event) = events.first else {
            Issue.record("expected a mouse event")
            return
        }
        #expect(event.resolvedButton == .none)
        #expect(events.filter { if case .key = $0 { true } else { false } }.isEmpty)
    }

    @Test("an X10 wheel report becomes one scroll InputEvent, never a key")
    func x10WheelDecodes() async throws {
        let events = try await translated(x10(64, 10, 5))
        #expect(events == [.mouse(MouseEvent(
            kind: .scrollUp,
            x: 9,
            y: 4,
            button: MouseEvent.noButton
        ))])
        #expect(events.filter { if case .key = $0 { true } else { false } }.isEmpty)
    }

    @Test("a truncated X10 report does not hang the live reader")
    func x10TruncatedFinishes() async throws {
        var descriptors: [Int32] = [0, 0]
        #expect(pipe(&descriptors) == 0)
        let input = try PlatformTerminalInput(
            fd: descriptors[0],
            escapeSequenceTimeoutMilliseconds: 20,
            closeFileDescriptor: true
        )
        let partial: [UInt8] = [0x1b, 0x5b, 0x4d, 0x20]
        #expect(write(descriptors[1], partial, partial.count) == partial.count)
        close(descriptors[1])

        // Incomplete X10 must surface via timeout/EOF finish as `.unknown`,
        // which translate drops (malformed) — never a key, never a hang.
        let event = try await input.readEvent()
        guard let event else {
            Issue.record("truncated X10 should finish as unknown, not nil")
            await input.close()
            return
        }
        #expect(event == .unknown(Data(partial)))
        let mapped = OpenGrokLiveInteractiveInput.translate(event)
        #expect(mapped.isEmpty)
        #expect(mapped.filter { if case .key = $0 { true } else { false } }.isEmpty)

        let next = try await input.readEvent()
        #expect(next == nil)
        await input.close()
    }
}
