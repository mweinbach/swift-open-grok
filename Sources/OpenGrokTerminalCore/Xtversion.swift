// Xtversion.swift
//
// Runtime XTVERSION protocol: `CSI > 0 q` → `DCS > | text ST`.
// Fire-and-forget: query bytes plus a filter that swallows the DCS reply
// from a chunked byte stream and returns residual keystrokes.
//
// Pin: `xai-grok-pager-render/src/terminal/xtversion.rs` at 650c1db7.
// The pager's crossterm *event* filter (`xt_filter.rs`) stays in the pager;
// this is the reusable byte-level protocol. Cost: two parsers until the
// event loop feeds this filter or maps events onto it.

import Foundation

// MARK: - Query (xtversion.rs:42)

/// XTVERSION query alone — no DA1 sentinel (`xtversion.rs:38-42`).
public let XTVERSION_QUERY: [UInt8] = [0x1B, 0x5B, 0x3E, 0x30, 0x71]

/// Same query as a string for writers that take `String`.
public let XTVERSION_QUERY_STRING = "\u{1B}[>0q"

// MARK: - Brand / mux gate (xtversion.rs:96-107, mod.rs:198-200)

/// Crush-style brand allowlist for the XTVERSION probe.
/// `other` is every brand the pin does not probe (Alacritty, JediTerm, …).
public enum XtversionProbeBrand: Sendable, Equatable, Hashable {
    case unknown
    case kitty
    case wezTerm
    case ghostty
    case iterm2
    case rio
    case other

    /// Pin `gate_allows_probe` brand arm (xtversion.rs:103-106).
    public var allowsXtversionProbe: Bool {
        switch self {
        case .unknown, .kitty, .wezTerm, .ghostty, .iterm2, .rio:
            return true
        case .other:
            return false
        }
    }
}

/// Multiplexer kinds the pin's CSI-intercept predicate distinguishes.
public enum XtversionProbeMultiplexer: Sendable, Equatable, Hashable {
    case tmux
    case screen
    case zellij
    case herdr
    case cmux
    case undetected

    /// Pin `intercepts_csi_queries` (terminal/mod.rs:198-200).
    public var interceptsCsiQueries: Bool {
        switch self {
        case .tmux, .screen, .zellij, .herdr:
            return true
        case .cmux, .undetected:
            return false
        }
    }
}

/// Pin `gate_allows_probe` (xtversion.rs:101-107): allowlisted brand and a
/// multiplexer that does not intercept CSI. Pure — no TTY check.
public func gateAllowsXtversionProbe(
    brand: XtversionProbeBrand,
    multiplexer: XtversionProbeMultiplexer
) -> Bool {
    brand.allowsXtversionProbe && !multiplexer.interceptsCsiQueries
}

// MARK: - Sanitize / parse (xtversion.rs:128-135)

/// Strip controls and trim; `nil` for an empty payload.
/// Pin `sanitize_payload` (xtversion.rs:128-135).
public func sanitizeXtversionPayload(_ payload: String) -> String? {
    let cleaned = String(payload.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
    let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? nil : trimmed
}

/// Extract a sanitized XTVERSION payload from a complete DCS reply.
///
/// Accepts 7-bit (`ESC P > | payload ESC \`) and 8-bit (`0x90 > | payload 0x9C`)
/// wrappers, plus BEL (`0x07`) as the event-loop filter does
/// (`xt_filter.rs:280-287`). Typeahead before the DCS is ignored. Only the
/// first `MAX_PROBE_RESPONSE` bytes are considered — a terminator past the
/// cap is treated as absent, matching the timed-read bound.
///
/// `nil` or empty bytes are no-reply, not `""`.
public func parseXtversionReply(_ reply: [UInt8]?) -> String? {
    guard let reply, !reply.isEmpty else { return nil }
    guard let range = findXtversionPayloadRange(reply) else { return nil }
    let payloadBytes = Array(reply[range])
    guard let text = String(bytes: payloadBytes, encoding: .utf8) else { return nil }
    return sanitizeXtversionPayload(text)
}

/// Locate `>|` after a DCS intro and the matching terminator, inside the
/// 256-byte window. Byte scan — never `Character` — so CRLF cannot hide ST.
private func findXtversionPayloadRange(_ bytes: [UInt8]) -> Range<Int>? {
    let limit = min(bytes.count, MAX_PROBE_RESPONSE)
    var index = 0
    while index < limit {
        let afterIntro: Int?
        if bytes[index] == 0x90 {
            afterIntro = index + 1
        } else if bytes[index] == 0x1B, index + 1 < limit, bytes[index + 1] == 0x50 {
            afterIntro = index + 2
        } else {
            afterIntro = nil
        }
        if let after = afterIntro,
           after + 1 < limit,
           bytes[after] == 0x3E,
           bytes[after + 1] == 0x7C
        {
            let start = after + 2
            var cursor = start
            while cursor < limit {
                if bytes[cursor] == 0x07 || bytes[cursor] == 0x9C {
                    return start..<cursor
                }
                if bytes[cursor] == 0x1B, cursor + 1 < limit, bytes[cursor + 1] == 0x5C {
                    return start..<cursor
                }
                cursor += 1
            }
            return nil
        }
        index += 1
    }
    return nil
}

// MARK: - Byte-stream filter (xt_filter.rs, byte-level)

/// Residual keystrokes plus an optional completed payload from one `feed`.
public struct XtversionFilterStep: Sendable, Equatable {
    public var residual: [UInt8]
    public var completedPayload: String?

    public init(residual: [UInt8], completedPayload: String? = nil) {
        self.residual = residual
        self.completedPayload = completedPayload
    }
}

/// Swallows one XTVERSION DCS reply from a chunked byte stream.
///
/// Fire-and-forget: stays armed until a reply completes (or the caller
/// disarms / resolves a dead hold). Incomplete ST or intro fragments are
/// held across `feed` calls. Following keystrokes — including a CRLF pair
/// as two bytes — come out in `residual`.
public struct XtversionReplyFilter: Sendable {
    private enum State: Equatable {
        case idle
        case esc
        case dcs
        case gt
        case payload
        case payloadEsc
    }

    public private(set) var armed: Bool
    public private(set) var completed: String?

    private var state: State = .idle
    private var held: [UInt8] = []
    private var payloadBytes: [UInt8] = []

    public init(armed: Bool = true) {
        self.armed = armed
    }

    /// True while a partial intro or payload is staged.
    public var holding: Bool { !held.isEmpty }

    /// Consume `chunk`. Residual keystrokes are everything that is not the
    /// swallowed DCS reply. A completed payload is also returned on the
    /// step that saw the terminator.
    public mutating func feed(_ chunk: [UInt8]) -> XtversionFilterStep {
        var residual: [UInt8] = []
        var completedThisChunk: String?
        for byte in chunk {
            if !armed {
                residual.append(byte)
                continue
            }
            switch advance(byte) {
            case .hold:
                held.append(byte)
                if state == .payload, isXtversionPayloadByte(byte) {
                    payloadBytes.append(byte)
                }
                if held.count >= MAX_PROBE_RESPONSE {
                    if introConfirmed {
                        resetHold()
                    } else {
                        residual.append(contentsOf: held)
                        resetHold()
                    }
                }
            case .complete:
                held.append(byte)
                let text = String(bytes: payloadBytes, encoding: .utf8) ?? ""
                let sanitized = sanitizeXtversionPayload(text)
                completed = sanitized
                completedThisChunk = sanitized
                resetHold()
                armed = false
            case .mismatch:
                if introConfirmed {
                    resetHold()
                } else {
                    residual.append(contentsOf: held)
                    resetHold()
                }
                // Re-evaluate from idle so a following reply is still caught
                // (`xt_filter.rs` Mismatch arm).
                applyIdleByte(byte, residual: &residual)
            }
        }
        return XtversionFilterStep(residual: residual, completedPayload: completedThisChunk)
    }

    /// Pin `take_completed` (`xt_filter.rs:90-92`).
    public mutating func takeCompleted() -> String? {
        let value = completed
        completed = nil
        return value
    }

    /// Pin `resolve_dead_hold` (`xt_filter.rs:123-131`): drop a confirmed
    /// DCS fragment, flush a pre-intro hold back as residual.
    public mutating func resolveDeadHold() -> [UInt8] {
        if introConfirmed {
            resetHold()
            return []
        }
        let flushed = held
        resetHold()
        return flushed
    }

    public mutating func disarm() {
        armed = false
    }

    private var introConfirmed: Bool {
        state == .payload || state == .payloadEsc
    }

    private mutating func resetHold() {
        state = .idle
        held.removeAll(keepingCapacity: true)
        payloadBytes.removeAll(keepingCapacity: true)
    }

    private mutating func applyIdleByte(_ byte: UInt8, residual: inout [UInt8]) {
        switch advance(byte) {
        case .hold:
            held.append(byte)
            if state == .payload, isXtversionPayloadByte(byte) {
                payloadBytes.append(byte)
            }
        case .complete:
            // A lone terminator is not a reply.
            residual.append(byte)
            resetHold()
        case .mismatch:
            residual.append(byte)
            resetHold()
        }
    }

    private mutating func advance(_ byte: UInt8) -> Advance {
        switch state {
        case .idle:
            if byte == 0x1B {
                state = .esc
                return .hold
            }
            if byte == 0x90 {
                state = .dcs
                return .hold
            }
            return .mismatch
        case .esc:
            if byte == 0x50 {
                state = .dcs
                return .hold
            }
            return .mismatch
        case .dcs:
            if byte == 0x3E {
                state = .gt
                return .hold
            }
            return .mismatch
        case .gt:
            if byte == 0x7C {
                state = .payload
                return .hold
            }
            return .mismatch
        case .payload:
            if byte == 0x07 || byte == 0x9C {
                return .complete
            }
            if byte == 0x1B {
                state = .payloadEsc
                return .hold
            }
            if isXtversionPayloadByte(byte) {
                return .hold
            }
            return .mismatch
        case .payloadEsc:
            if byte == 0x5C {
                return .complete
            }
            return .mismatch
        }
    }

    private enum Advance {
        case hold
        case complete
        case mismatch
    }
}

/// Pin `is_xt_payload_char` (`xt_filter.rs:276-278`). Strict so a `/slash`
/// after an unterminated reply breaks the hold instead of being eaten.
private func isXtversionPayloadByte(_ byte: UInt8) -> Bool {
    (0x30...0x39).contains(byte)
        || (0x41...0x5A).contains(byte)
        || (0x61...0x7A).contains(byte)
        || byte == 0x20
        || byte == 0x2E
        || byte == 0x5F
        || byte == 0x2D
        || byte == 0x28
        || byte == 0x29
        || byte == 0x2B
}
