// XtversionCollector.swift
//
// Injectable XTVERSION probe — runtime terminal self-identification via
// `CSI > 0 q` → `DCS > | <payload> ST`.
//
// Ports `xai-grok-pager-render/src/terminal/xtversion.rs` (38-65, gate,
// sanitize_payload) at reference 650c1db7. The probe runs fire-and-forget in
// the pager event loop (processed by XtversionFilter), but for the
// standalone doctor and diagnostics injection path we use a bounded
// synchronous write/read on the terminal fd with a short timeout.
//
// The collector protocol allows:
// - Tests to inject canned replies (parsed payload or unavailable).
// - The pager runtime to feed the already-collected OnceLock value.
// - The standalone doctor to run its own bounded probe when stdin is a TTY.
//
// This file does NOT port the other TUI collectors
// (kitty/fullscreen/notification/sandbox/voice).

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

import Foundation

// MARK: - Collector protocol

/// Injectable seam for XTVERSION evidence. The pager runtime and standalone
/// doctor both conform; tests inject fakes.
public protocol XtversionCollector: Sendable {
    /// Collect the terminal's XTVERSION reply. Returns `.unavailable` when
    /// stdin is not a TTY or the gate rejects the terminal/multiplexer,
    /// `.available(nil)` when the query was sent but no reply arrived within
    /// the timeout, `.available(someString)` with the sanitized payload.
    func collect(context: TerminalContext) -> RuntimeEvidence<String?>
}

// MARK: - Payload sanitizer (shared with pager reply decoder)

/// Strip control characters and trim whitespace; `nil` for empty payloads.
/// Ports `sanitize_payload` (xtversion.rs:128-135).
public func sanitizeXtversionPayload(_ payload: String) -> String? {
    let cleaned = String(payload.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
    let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? nil : trimmed
}

// MARK: - Gate

/// Brand allowlist for the XTVERSION probe: Unknown plus brands headfully
/// validated as clean responders. CSI-intercepting multiplexers skip — the
/// innermost layer answers as itself, which the `multiplexer` field already
/// records.
///
/// Ports `gate_allows_probe` (xtversion.rs:96-107).
public func gateAllowsXtversionProbe(_ ctx: TerminalContext) -> Bool {
    let brandAllowed: Bool
    switch ctx.brand {
    case .unknown, .kitty, .wezTerm, .ghostty, .iterm2, .rio:
        brandAllowed = true
    default:
        brandAllowed = false
    }
    return brandAllowed && !ctx.multiplexer.interceptsCsiQueries
}

// MARK: - Multiplexer CSI interception

extension MultiplexerKind {
    /// Whether this multiplexer intercepts CSI queries (e.g. XTVERSION)
    /// instead of passing them through to the outer terminal.
    /// Ports `intercepts_csi_queries` (terminal/mod.rs:198-203).
    public var interceptsCsiQueries: Bool {
        switch self {
        case .tmux, .screen, .zellij, .herdr: return true
        case .cmux, .undetected: return false
        }
    }
}

// MARK: - Live bounded collector

/// Standalone XTVERSION probe that writes `CSI > 0 q` to the terminal and
/// reads the DCS reply with a 2-second timeout. Reports `.unavailable` when
/// stdin is not a TTY or the gate rejects the terminal.
public struct LiveXtversionCollector: XtversionCollector {
    public init() {}

    public func collect(context: TerminalContext) -> RuntimeEvidence<String?> {
        guard gateAllowsXtversionProbe(context) else {
            return .unavailable
        }
        #if os(macOS) || os(Linux)
        guard isatty(STDIN_FILENO) != 0 else {
            return .unavailable
        }
        return .available(probeTerminal())
        #else
        return .unavailable
        #endif
    }

    #if os(macOS) || os(Linux)
    /// Write the query, read the DCS reply with a 2 s ceiling.
    private func probeTerminal() -> String? {
        let inputFd = STDIN_FILENO
        let outputFd: Int32
        if isatty(STDOUT_FILENO) != 0 {
            outputFd = STDOUT_FILENO
        } else if isatty(STDERR_FILENO) != 0 {
            outputFd = STDERR_FILENO
        } else {
            return nil
        }

        var original = termios()
        tcgetattr(inputFd, &original)
        var raw = original
        cfmakeraw(&raw)
        raw.c_cc.16 = 0   // VMIN = 0 (non-blocking)
        raw.c_cc.17 = 20  // VTIME = 2.0 s (in tenths)
        tcsetattr(inputFd, TCSANOW, &raw)
        defer { tcsetattr(inputFd, TCSANOW, &original) }

        // CSI > 0 q — XTVERSION query
        let query: [UInt8] = [0x1B, 0x5B, 0x3E, 0x30, 0x71]
        _ = write(outputFd, query, query.count)

        return readDcsReply(fd: inputFd)
    }

    /// Read bytes until we see DCS > | <payload> ST (or timeout).
    /// DCS = ESC P, ST = ESC \ (7-bit) or 0x9C (8-bit).
    private func readDcsReply(fd: Int32) -> String? {
        var buf = [UInt8](repeating: 0, count: 256)
        var accumulated = [UInt8]()
        let deadline = DispatchTime.now() + .seconds(2)

        while DispatchTime.now() < deadline {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            accumulated.append(contentsOf: buf[0..<n])
            if let payload = extractDcsPayload(accumulated) {
                return sanitizeXtversionPayload(payload)
            }
        }
        return nil
    }

    /// Extract payload from `ESC P > | <payload> ESC \` or `ESC P > | <payload> 0x9C`.
    private func extractDcsPayload(_ bytes: [UInt8]) -> String? {
        // Find DCS introducer: ESC P (0x1B 0x50) or 0x90
        var startIndex: Int?
        for i in 0..<bytes.count {
            if bytes[i] == 0x90 {
                startIndex = i + 1
                break
            }
            if bytes[i] == 0x1B && i + 1 < bytes.count && bytes[i + 1] == 0x50 {
                startIndex = i + 2
                break
            }
        }
        guard var start = startIndex else { return nil }

        // Expect "> |" after DCS introducer
        while start < bytes.count && bytes[start] == 0x20 { start += 1 }
        guard start < bytes.count && bytes[start] == 0x3E else { return nil } // '>'
        start += 1
        guard start < bytes.count && bytes[start] == 0x7C else { return nil } // '|'
        start += 1

        // Find ST: ESC \ (0x1B 0x5C) or 0x9C
        for i in start..<bytes.count {
            if bytes[i] == 0x9C {
                let payloadBytes = Array(bytes[start..<i])
                return String(bytes: payloadBytes, encoding: .utf8)
            }
            if bytes[i] == 0x1B && i + 1 < bytes.count && bytes[i + 1] == 0x5C {
                let payloadBytes = Array(bytes[start..<i])
                return String(bytes: payloadBytes, encoding: .utf8)
            }
        }
        return nil
    }
    #endif
}

// MARK: - Unavailable collector (non-TTY / standalone fallback)

/// Always reports `.unavailable` — used when there is no TTY or the runtime
/// knows the probe cannot run.
public struct UnavailableXtversionCollector: XtversionCollector {
    public init() {}

    public func collect(context: TerminalContext) -> RuntimeEvidence<String?> {
        .unavailable
    }
}

// MARK: - Prerecorded collector (pager runtime injection)

/// Injects a pre-collected XTVERSION result from the pager's event-loop
/// filter (the OnceLock value). The pager already ran the probe at startup;
/// doctor-in-TUI just reads the recorded answer.
public struct PrerecordedXtversionCollector: XtversionCollector {
    private let result: RuntimeEvidence<String?>

    public init(_ result: RuntimeEvidence<String?>) {
        self.result = result
    }

    /// Convenience: wrap a raw payload string (already sanitized by the
    /// event-loop filter).
    public init(payload: String?) {
        self.result = .available(payload)
    }

    public func collect(context: TerminalContext) -> RuntimeEvidence<String?> {
        result
    }
}
