// LiveMouseByteChainTests.swift
//
// The live mouse path from raw terminal bytes to pager InputEvents:
// PosixTerminalInput's escape decoder delivers an SGR report as `.unknown`
// (its CSI parser has no mouse arm), and the composition's translate glue
// recovers the event through MouseReportDecoder. Every prior mouse test
// injected synthetic `.mouse` events, so this seam had zero coverage — a
// break here is invisible everywhere else and reads as "mouse doesn't work".

import Foundation
import OpenGrokTerminalCore
import OpenGrokTTY
import Testing
@testable import OpenGrokCLI

@Suite("Live mouse byte chain")
struct LiveMouseByteChainTests {
    /// Feed raw bytes through a real PosixTerminalInput over a pipe and
    /// return every InputEvent the live translate glue produces.
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
            let mapped = OpenGrokLiveInteractiveInput.translate(event)
            events.append(contentsOf: mapped)
            if !mapped.isEmpty { break }
        }
        await input.close()
        return events
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
}
