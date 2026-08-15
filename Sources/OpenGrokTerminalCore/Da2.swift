// Da2.swift
//
// Runtime DA2 (Secondary Device Attributes) probe helpers.
//
// Query: `CSI > 0 c` → reply `CSI > Pp ; Pv ; Pc c`, where `Pv` is packed as
// `major * 10000 + minor * 100 + patch`.
//
// Alacritty is why this exists: it exports no version environment variable
// and refuses XTVERSION. What it answers with is the `alacritty_terminal`
// library version, not the application release (those diverged after 0.5 —
// Alacritty 0.15.1 answers `2500`).
//
// Pin: crates/codegen/xai-grok-pager-render/src/terminal/da2.rs @ 650c1db7.
// Timed stdin read and raw mode stay in the pager startup glue; this file
// only parses and unpacks so tests never grab stdin.

import Foundation

// MARK: - Constants (da2.rs:39-50, probe.rs:18-26)

/// `ESC [ > 0 c` — DA2 query written at startup.
public let DA2_QUERY: [UInt8] = [0x1B, 0x5B, 0x3E, 0x30, 0x63]

/// Same query as a string for writers that take `String`.
public let DA2_QUERY_STRING = "\u{1B}[>0c"

/// Sized for a slow link, not a silent terminal: a reply that misses this
/// deadline is typed into the composer, not merely lost (da2.rs:42-44).
public let DA2_REPLY_TIMEOUT_MILLISECONDS: UInt64 = 500

/// Rejects a packed value that cannot be a real release (major ≥ 100)
/// instead of folding it into a plausible-looking version (da2.rs:47-50).
public let DA2_MAX_PACKED_VERSION: UInt32 = 999_999

/// Bounds the reply buffer against terminals that stream without a
/// terminator (probe.rs:18).
public let DA2_MAX_PROBE_RESPONSE: Int = 256

/// Hard cap on post-deadline consumption of an in-flight reply (probe.rs:22).
public let DA2_LATE_REPLY_GRACE_MILLISECONDS: UInt64 = 100

/// Per-byte quiet window during the grace period (probe.rs:26).
public let DA2_LATE_REPLY_QUIET_MILLISECONDS: Int32 = 25

private let da2Intro: [UInt8] = [0x1B, 0x5B, 0x3E]

// MARK: - Version

/// Both forms of one DA2 reply. The packed integer is kept rather than
/// recovered from `text`, so version gates compare what the terminal sent
/// instead of re-parsing what this module formatted (da2.rs:28-36).
public struct Da2Version: Sendable, Equatable {
    public let packed: UInt32
    public let major: UInt32
    public let minor: UInt32
    public let patch: UInt32

    public var text: String { "\(major).\(minor).\(patch)" }

    public init(packed: UInt32, major: UInt32, minor: UInt32, patch: UInt32) {
        self.packed = packed
        self.major = major
        self.minor = minor
        self.patch = patch
    }
}

// MARK: - Unpack

/// Unpack a packed `Pv` (`major * 10000 + minor * 100 + patch`).
///
/// `0` and values above `DA2_MAX_PACKED_VERSION` are `nil`, never a
/// fabricated `0.0.0`. `negotiatedKittyFlags` treats packed `0` as a
/// broken Alacritty and withholds `reportEventTypes`; silence must stay
/// `nil` so that path is not taken by accident.
public func unpackDa2Version(_ packed: UInt32) -> Da2Version? {
    guard packed != 0, packed <= DA2_MAX_PACKED_VERSION else {
        return nil
    }
    let major = packed / 10_000
    let minor = (packed / 100) % 100
    let patch = packed % 100
    return Da2Version(packed: packed, major: major, minor: minor, patch: patch)
}

// MARK: - Parse

/// Decode `CSI > Pp ; Pv ; Pc c`, rejecting anything that is not
/// Alacritty's exact reply shape (`Pp == 0`, `Pc == 1`).
///
/// `Pv` means whatever its emulator decided — xterm puts a patch level
/// there, so `> 0 ; 388 ; 0 c` would decode to a confident, wrong
/// `0.3.88`. The brand evidence is only `TERM=alacritty`, so the shape
/// upstream hardcodes is what makes the number trustworthy (da2.rs:115-121).
///
/// `nil` or empty bytes are no-reply (`nil`), not packed `0`.
public func parseDa2Reply(_ reply: [UInt8]?) -> Da2Version? {
    guard let reply, !reply.isEmpty else {
        return nil
    }
    return parseDa2ReplyBytes(reply)
}

private func parseDa2ReplyBytes(_ reply: [UInt8]) -> Da2Version? {
    // Lossy UTF-8 matches `String::from_utf8_lossy`: invalid sequences
    // become U+FFFD and then fail numeric parse, they never panic.
    let text = String(decoding: reply, as: UTF8.self)
    // Split at the last `>` so a keystroke racing the reply cannot shift
    // the parameter list (da2.rs:127-129).
    guard let lastGT = text.lastIndex(of: ">") else {
        return nil
    }
    let params = text[text.index(after: lastGT)...]
    var fieldsSource = params.trimmingCharacters(in: .whitespacesAndNewlines)
    // `trim_end_matches('c')` strips every trailing ASCII `c`.
    while fieldsSource.last == "c" {
        fieldsSource.removeLast()
    }
    // Rust `split(';')` keeps empty fields (`>0;;1c` must stay rejectable).
    let fields = fieldsSource.split(separator: ";", omittingEmptySubsequences: false)
    var iterator = fields.makeIterator()
    guard let pp = iterator.next(), pp.trimmingCharacters(in: .whitespaces) == "0" else {
        return nil
    }
    guard let pv = iterator.next() else {
        return nil
    }
    let packedText = pv.trimmingCharacters(in: .whitespaces)
    guard let packed = UInt32(packedText) else {
        return nil
    }
    guard let pc = iterator.next(), pc.trimmingCharacters(in: .whitespaces) == "1" else {
        return nil
    }
    return unpackDa2Version(packed)
}

// MARK: - Testable timed-read stand-in

/// Terminator used by the Unix timed read: the latest byte is `c` and the
/// buffer contains the DA2 intro `ESC [ >` (da2.rs:99-101). Startup
/// typeahead can already hold a `>` and a `c` (`ls > out.c`); a late DA1
/// reply has the escape but a `?`. Both are consumed and the read continues.
public func da2ReplyIsComplete(buffer: [UInt8], lastByte: UInt8) -> Bool {
    lastByte == 0x63 && containsDa2Intro(buffer)
}

/// Consume a canned byte stream the same way the Unix timed read would,
/// stopping at the DA2 terminator or `DA2_MAX_PROBE_RESPONSE`.
///
/// Returns `nil` when nothing arrived (no-reply). A partial or rejected
/// buffer is returned as bytes so the caller can parse it; parse of that
/// buffer is `nil`, never packed `0`. Does not read stdin.
public func consumeDa2Reply(_ bytes: [UInt8]) -> [UInt8]? {
    guard !bytes.isEmpty else {
        return nil
    }
    var buffer: [UInt8] = []
    buffer.reserveCapacity(min(bytes.count, DA2_MAX_PROBE_RESPONSE))
    for byte in bytes {
        buffer.append(byte)
        if buffer.count >= DA2_MAX_PROBE_RESPONSE || da2ReplyIsComplete(buffer: buffer, lastByte: byte) {
            return buffer
        }
    }
    return buffer
}

private func containsDa2Intro(_ buffer: [UInt8]) -> Bool {
    let needle = da2Intro
    guard buffer.count >= needle.count else {
        return false
    }
    let lastStart = buffer.count - needle.count
    for start in 0...lastStart {
        if buffer[start] == needle[0],
           buffer[start + 1] == needle[1],
           buffer[start + 2] == needle[2]
        {
            return true
        }
    }
    return false
}
