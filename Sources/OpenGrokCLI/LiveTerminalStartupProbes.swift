// LiveTerminalStartupProbes.swift
//
// DA2 + Kitty keyboard startup glue. The read owns stdin, so it must run
// after `enterRawMode()` and before `PlatformTerminalInput` / EventStream
// exists (da2.rs:16-19, app/mod.rs:1356-1361 at pin 650c1db7).
//
// Parse/unpack stay in OpenGrokTerminalCore so tests never grab stdin.
// This file is the live write + poll-bounded read, plus the pure gate
// that decides whether to touch the TTY at all.

import Foundation
import OpenGrokDiagnostics
import OpenGrokTerminalCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Gate (da2.rs:76-83)

/// Pin `gate_allows_probe`: Alacritty is the only brand whose version is
/// otherwise unreachable, and CSI-intercepting multiplexers skip — tmux
/// answers DA2 as itself (da2.rs:76-83). Pure; no TTY check.
public func shouldProbeDa2(
    brand: OpenGrokDiagnostics.TerminalName,
    multiplexerInterceptsCsi: Bool
) -> Bool {
    brand == .alacritty && !multiplexerInterceptsCsi
}

// MARK: - Kitty push (kitty_keyboard.rs:64-76, app/mod.rs:1357-1380)

/// Negotiated flags plus the CSI push sequence, or `nil` sequence when
/// nothing should be written. Empty flags must not become `CSI > 0 u`.
public struct KittyKeyboardApplication: Sendable, Equatable {
    public let flags: KeyboardEnhancementFlags
    /// `nil` when `flags` is empty — a skip writes nothing, teardown owes
    /// no pop (kitty_keyboard.rs:155-166).
    public let pushSequence: String?

    public init(flags: KeyboardEnhancementFlags, pushSequence: String?) {
        self.flags = flags
        self.pushSequence = pushSequence
    }
}

/// `negotiated_kitty_flags` + `PushKeyboardEnhancementFlags`.
///
/// Silence (`da2Packed == nil`) must stay `nil` and must not be rewritten
/// as packed `0`: `0` is a positively identified broken Alacritty and
/// withholds `reportEventTypes`; `nil` is the common skipped/unix-off
/// case and keeps release events (kitty_keyboard.rs:58-61, 146-153).
public func applyKittyKeyboard(
    da2Packed: UInt32?,
    skipReason: String?
) -> KittyKeyboardApplication {
    let flags = negotiatedKittyFlags(skipReason: skipReason, da2Packed: da2Packed)
    let pushSequence = flags.isEmpty ? nil : KittyKeyboardSequences.pushFlags(flags)
    return KittyKeyboardApplication(flags: flags, pushSequence: pushSequence)
}

// MARK: - Testable DA2 probe (no stdin)

/// Consume a canned reply buffer the same way the Unix timed read would,
/// then parse. Does not read stdin.
///
/// `nil` is silence or a rejected shape — never packed `0`.
public func probeDa2Packed(fromReply bytes: [UInt8]) -> UInt32? {
    parseDa2Reply(consumeDa2Reply(bytes))?.packed
}

/// Combined gate + parse + Kitty negotiation, still without I/O.
/// When the DA2 gate rejects the brand/mux, `replyBytes` are ignored
/// (no query would have been sent) and packed stays `nil`.
public func decideTerminalStartupProbes(
    brand: OpenGrokDiagnostics.TerminalName,
    multiplexerInterceptsCsi: Bool,
    skipReason: String?,
    replyBytes: [UInt8]?
) -> KittyKeyboardApplication {
    let da2Packed: UInt32?
    if shouldProbeDa2(brand: brand, multiplexerInterceptsCsi: multiplexerInterceptsCsi),
       let replyBytes
    {
        da2Packed = probeDa2Packed(fromReply: replyBytes)
    } else {
        da2Packed = nil
    }
    return applyKittyKeyboard(da2Packed: da2Packed, skipReason: skipReason)
}

// MARK: - XTVERSION query bytes (xtversion.rs:5-9, 80-93)

/// Fire-and-forget XTVERSION query bytes. Callers write these after raw
/// mode and before EventStream; this function does not write and does
/// not timed-read. The reply is swallowed by the event-loop filter
/// (`event_loop.rs:1648-1650`), which is not this slice.
public func writeXtversionQueryBytes() -> [UInt8] {
    XTVERSION_QUERY
}

// MARK: - Live startup (app/mod.rs:1356-1380)

/// After raw mode, before `PlatformTerminalInput` owns stdin: optional
/// DA2 query + poll-bounded read, then Kitty flag push.
///
/// Timed read uses `poll`, not `sleep`. A silent Alacritty waits up to
/// `DA2_REPLY_TIMEOUT_MILLISECONDS` (500); every other brand returns
/// immediately because the gate skips the query. Windows / non-TTY
/// skip the read (da2.rs:114-117).
///
/// Leftover vs pin: crossterm `supports_keyboard_enhancement` is not
/// probed here — `skipReason` is env `kitty_skip_reason` only. A
/// terminal that env-allows KKP but cannot speak it still gets a push.
enum LiveTerminalStartupProbes {
    static func probeDa2AndPushKittyKeyboard(
        writeFallback: @escaping @Sendable (Data) async throws -> Void
    ) async {
        let ctx = standaloneTerminalContext()
        let shouldProbe = shouldProbeDa2(
            brand: ctx.brand,
            multiplexerInterceptsCsi: ctx.multiplexer.interceptsCsiQueries
        )
        var da2Packed: UInt32?
        if shouldProbe {
            if await writeQuery(DA2_QUERY, fallback: writeFallback) {
                da2Packed = readDa2PackedFromStdinIfTTY()
            }
        }
        let applied = applyKittyKeyboard(
            da2Packed: da2Packed,
            skipReason: ctx.kittySkipReason
        )
        if let sequence = applied.pushSequence {
            let didPush = await writeQuery(Array(sequence.utf8), fallback: writeFallback)
            if !didPush {
                // Pin still records the negotiated set after a failed
                // `execute!(PushKeyboardEnhancementFlags)` (app/mod.rs:1369-1380).
            }
        }
        KittyKeyboardState.shared.setPushedFlags(applied.flags)
    }

    /// Fire-and-forget XTVERSION (`CSI > 0 q`) after the input filter is
    /// armed. Do not timed-read — `PlatformTerminalInput` swallows the DCS
    /// reply (`xtversion.rs:5-9`, `event_loop.rs:1648-1650`).
    static func writeXtversionQueryIfAllowed(
        writeFallback: @escaping @Sendable (Data) async throws -> Void
    ) async {
        let ctx = standaloneTerminalContext()
        guard gateAllowsXtversionProbe(ctx) else { return }
        _ = await writeQuery(writeXtversionQueryBytes(), fallback: writeFallback)
    }
}

// MARK: - Query write

/// Prefer stderr (pin `write_query` locks the TUI stderr fd), then
/// stdout, then the caller-supplied TTY write (stdin is bidirectional
/// on a real TTY).
private func writeQuery(
    _ bytes: [UInt8],
    fallback: @escaping @Sendable (Data) async throws -> Void
) async -> Bool {
    if writeToOutputTTY(bytes) {
        return true
    }
    do {
        try await fallback(Data(bytes))
        return true
    } catch {
        return false
    }
}

private func writeToOutputTTY(_ bytes: [UInt8]) -> Bool {
#if os(macOS) || os(Linux)
    for fd: Int32 in [STDERR_FILENO, STDOUT_FILENO] {
        if isatty(fd) != 0 {
            return writeAll(fd: fd, bytes: bytes)
        }
    }
#endif
    return false
}

#if os(macOS) || os(Linux)
private func writeAll(fd: Int32, bytes: [UInt8]) -> Bool {
    guard !bytes.isEmpty else { return false }
    return bytes.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return false }
        var written = 0
        let total = raw.count
        while written < total {
            let n = write(fd, base.advanced(by: written), total - written)
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            if n == 0 { return false }
            written += n
        }
        return true
    }
}
#endif

// MARK: - Poll-bounded stdin read (probe.rs:52-164)

/// `read_tty_reply` + `parse_version` on stdin. `nil` when stdin is not
/// a TTY, the platform has no poll path, or the reply is silence/reject.
private func readDa2PackedFromStdinIfTTY() -> UInt32? {
#if os(macOS) || os(Linux)
    guard isatty(STDIN_FILENO) != 0 else { return nil }
    let reply = readTTYReply(
        fd: STDIN_FILENO,
        timeoutMilliseconds: DA2_REPLY_TIMEOUT_MILLISECONDS,
        isTerminated: da2ReplyIsComplete
    )
    return parseDa2Reply(reply)?.packed
#else
    return nil
#endif
}

#if os(macOS) || os(Linux)

private enum PollRead {
    case byte(UInt8)
    case interrupted
    case timeout
    case error
}

/// Pin `read_tty_reply` (probe.rs:52-80). Returns `nil` when nothing
/// arrived; a partial buffer is returned so it is not left for EventStream.
private func readTTYReply(
    fd: Int32,
    timeoutMilliseconds: UInt64,
    isTerminated: ([UInt8], UInt8) -> Bool
) -> [UInt8]? {
    let start = DispatchTime.now()
    let timeoutNs = timeoutMilliseconds &* 1_000_000
    var buf: [UInt8] = []
    buf.reserveCapacity(64)

    while true {
        let elapsed = DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds
        if elapsed >= timeoutNs {
            return finishAfterDeadline(fd: fd, buffer: buf, isTerminated: isTerminated)
        }
        let remainingNs = timeoutNs &- elapsed
        let remainingMs = Int32(clamping: (remainingNs &+ 999_999) / 1_000_000)
        switch pollReadByte(fd: fd, timeoutMilliseconds: remainingMs) {
        case .byte(let byte):
            buf.append(byte)
            if buf.count >= DA2_MAX_PROBE_RESPONSE || isTerminated(buf, byte) {
                return buf
            }
        case .interrupted:
            continue
        case .timeout:
            return finishAfterDeadline(fd: fd, buffer: buf, isTerminated: isTerminated)
        case .error:
            return buf.isEmpty ? nil : buf
        }
    }
}

/// Pin `finish_after_deadline` (probe.rs:89-114): drain an in-flight
/// ESC reply through the grace window so its tail cannot type into the
/// composer; a buffer with no ESC is returned immediately.
private func finishAfterDeadline(
    fd: Int32,
    buffer: [UInt8],
    isTerminated: ([UInt8], UInt8) -> Bool
) -> [UInt8]? {
    if buffer.isEmpty { return nil }
    if !buffer.contains(0x1B) { return buffer }
    var buf = buffer
    let graceStart = DispatchTime.now()
    let graceNs = DA2_LATE_REPLY_GRACE_MILLISECONDS &* 1_000_000
    while DispatchTime.now().uptimeNanoseconds &- graceStart.uptimeNanoseconds < graceNs {
        switch pollReadByte(fd: fd, timeoutMilliseconds: DA2_LATE_REPLY_QUIET_MILLISECONDS) {
        case .byte(let byte):
            buf.append(byte)
            if buf.count >= DA2_MAX_PROBE_RESPONSE || isTerminated(buf, byte) {
                return buf
            }
        case .interrupted:
            continue
        case .timeout, .error:
            return buf
        }
    }
    return buf
}

/// Pin `poll_read_byte` (probe.rs:126-157).
private func pollReadByte(fd: Int32, timeoutMilliseconds: Int32) -> PollRead {
    var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    let ready = withUnsafeMutablePointer(to: &descriptor) { pointer in
        poll(pointer, 1, timeoutMilliseconds)
    }
    if ready == 0 { return .timeout }
    if ready < 0 {
        return errno == EINTR ? .interrupted : .error
    }
    var byte: UInt8 = 0
    while true {
        let n = withUnsafeMutablePointer(to: &byte) { pointer in
            read(fd, pointer, 1)
        }
        if n == 1 { return .byte(byte) }
        if n < 0 && errno == EINTR { continue }
        return .error
    }
}

#endif
