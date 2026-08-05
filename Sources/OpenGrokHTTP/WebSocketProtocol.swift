// WebSocketProtocol.swift
//
// The pure, platform-independent half of a WebSocket implementation: the
// RFC 6455 opening handshake and the frame codec. Nothing in this file touches
// a socket, so all of it is exercised by byte-level unit tests; the listener
// that feeds it lives in `WebSocketServer.swift` behind a platform guard.
//
// Why this exists at all: `OpenGrokHTTP` already shipped a WebSocket *client*
// (`URLSessionWebSocketClient`), which is enough to talk to grok.com but not
// to *serve* anything — `URLSession` has no server side. `open-grok serve`
// needs the server half, so the framing had to be written out.
//
// Rust reference (`/Users/mweinbach/Projects/grok-build`): upstream gets this
// layer from `axum`/`tungstenite` and never spells it out, so there is no
// line-for-line counterpart to cite here. What upstream *does* pin, and what
// this file is sized to match, is at
// `crates/codegen/xai-grok-shell/src/agent/server.rs:56-57`:
// `MAX_BUFFER_SIZE = 8 * 1024 * 1024` and `KEEPALIVE_INTERVAL_SECS = 15`.
//
// Spec references are to RFC 6455:
//   * §1.3   opening handshake, `Sec-WebSocket-Accept` derivation
//   * §5.2   base framing protocol (FIN/RSV/opcode/MASK/length/masking-key)
//   * §5.4   fragmentation, and the rule that control frames may be injected
//            in the middle of a fragmented message
//   * §5.5   control frames: never fragmented, payload ≤ 125 bytes
//   * §7.4.1 close codes

import Foundation

// MARK: - Errors

/// A protocol violation by the peer.
///
/// Each case carries the RFC 6455 §7.4.1 close code the connection must send
/// before closing, so the connection layer never has to re-derive it.
public enum WebSocketProtocolError: Error, Sendable, Hashable, CustomStringConvertible {
    /// RSV1/2/3 set with no extension negotiated (§5.2).
    case reservedBitsSet
    case unknownOpcode(UInt8)
    /// A client-to-server frame arrived unmasked (§5.1: clients MUST mask).
    case unmaskedClientFrame
    /// A server-to-client frame arrived masked (§5.1: servers MUST NOT mask).
    case maskedServerFrame
    case fragmentedControlFrame
    /// Control payload exceeded 125 bytes (§5.5).
    case oversizedControlPayload(Int)
    /// A 64-bit length with the high bit set, or a non-minimal encoding (§5.2).
    case invalidPayloadLength
    /// The frame, or the message being assembled, exceeded the configured cap.
    case messageTooLarge(limit: Int)
    /// A continuation frame with no message in progress.
    case unexpectedContinuation
    /// A new text/binary frame while a fragmented message was still open.
    case interleavedDataFrame
    /// A close frame with a 1-byte payload, or a code from a reserved range.
    case invalidClosePayload
    /// Text payload that is not valid UTF-8 (§8.1).
    case invalidUTF8

    /// The close code to send back before closing, per §7.4.1.
    public var closeCode: UInt16 {
        switch self {
        case .messageTooLarge: return 1009  // Message Too Big
        case .invalidUTF8: return 1007      // Invalid frame payload data
        default: return 1002                // Protocol error
        }
    }

    public var description: String {
        switch self {
        case .reservedBitsSet:
            return "websocket frame set a reserved bit with no extension negotiated"
        case .unknownOpcode(let opcode):
            return "websocket frame used unknown opcode 0x\(String(opcode, radix: 16))"
        case .unmaskedClientFrame:
            return "websocket client frame was not masked"
        case .maskedServerFrame:
            return "websocket server frame was masked"
        case .fragmentedControlFrame:
            return "websocket control frame was fragmented"
        case .oversizedControlPayload(let size):
            return "websocket control frame payload is \(size) bytes, limit is 125"
        case .invalidPayloadLength:
            return "websocket frame declared an invalid payload length"
        case .messageTooLarge(let limit):
            return "websocket message exceeded the \(limit) byte limit"
        case .unexpectedContinuation:
            return "websocket continuation frame arrived with no message in progress"
        case .interleavedDataFrame:
            return "websocket data frame arrived while a fragmented message was open"
        case .invalidClosePayload:
            return "websocket close frame carried an invalid payload"
        case .invalidUTF8:
            return "websocket text payload was not valid UTF-8"
        }
    }
}

/// A handshake that cannot become a WebSocket connection.
public enum WebSocketHandshakeError: Error, Sendable, Hashable, CustomStringConvertible {
    case malformedRequestLine
    case malformedHeader(String)
    /// The request head exceeded the byte cap before `\r\n\r\n` arrived.
    case headTooLarge(limit: Int)
    case unsupportedMethod(String)
    case missingUpgrade
    case missingConnectionUpgrade
    case unsupportedVersion(String?)
    case missingKey
    /// `Sec-WebSocket-Key` was present but not 16 base64-encoded bytes (§4.1).
    case invalidKey(String)
    case notFound(path: String)
    case unauthorized

    /// The HTTP status to answer a failed handshake with.
    public var httpStatus: Int {
        switch self {
        case .notFound: return 404
        case .unauthorized: return 401
        case .unsupportedVersion: return 426  // Upgrade Required
        case .unsupportedMethod: return 405
        default: return 400
        }
    }

    public var description: String {
        switch self {
        case .malformedRequestLine: return "malformed HTTP request line"
        case .malformedHeader(let line): return "malformed HTTP header: \(line)"
        case .headTooLarge(let limit): return "HTTP request head exceeded \(limit) bytes"
        case .unsupportedMethod(let method): return "method \(method) is not supported; use GET"
        case .missingUpgrade: return "missing or non-websocket Upgrade header"
        case .missingConnectionUpgrade: return "Connection header does not contain 'upgrade'"
        case .unsupportedVersion(let version):
            return "unsupported Sec-WebSocket-Version \(version ?? "<absent>"); expected 13"
        case .missingKey: return "missing Sec-WebSocket-Key header"
        case .invalidKey(let key): return "invalid Sec-WebSocket-Key: \(key)"
        case .notFound(let path): return "no websocket route at \(path)"
        case .unauthorized: return "Invalid or missing authorization token"
        }
    }
}

// MARK: - SHA-1

/// SHA-1, needed only for `Sec-WebSocket-Accept` (RFC 6455 §1.3).
///
/// Written out rather than taken from CryptoKit because `OpenGrokHTTP` must
/// keep building where CryptoKit is absent, and adding `swift-crypto` would
/// mean touching `Package.swift`. The name says `Insecure` for the same reason
/// CryptoKit's does: SHA-1 is broken for anything security-bearing. Here it is
/// a fixed protocol constant with no security property attached — the accept
/// token proves only that the peer read the request, and RFC 6455 §1.3 says so
/// explicitly.
enum InsecureSHA1 {
    static func hash(_ message: [UInt8]) -> [UInt8] {
        var state: [UInt32] = [0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0]
        var padded = message
        let bitLength = UInt64(message.count) &* 8
        padded.append(0x80)
        while padded.count % 64 != 56 { padded.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            padded.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }

        var schedule = [UInt32](repeating: 0, count: 80)
        var chunkStart = 0
        while chunkStart < padded.count {
            for index in 0..<16 {
                let offset = chunkStart + index * 4
                schedule[index] =
                    (UInt32(padded[offset]) << 24)
                    | (UInt32(padded[offset + 1]) << 16)
                    | (UInt32(padded[offset + 2]) << 8)
                    | UInt32(padded[offset + 3])
            }
            for index in 16..<80 {
                let value = schedule[index - 3] ^ schedule[index - 8] ^ schedule[index - 14] ^ schedule[index - 16]
                schedule[index] = rotateLeft(value, 1)
            }

            var a = state[0], b = state[1], c = state[2], d = state[3], e = state[4]
            for index in 0..<80 {
                let f: UInt32
                let k: UInt32
                switch index {
                case 0..<20:
                    f = (b & c) | (~b & d)
                    k = 0x5A82_7999
                case 20..<40:
                    f = b ^ c ^ d
                    k = 0x6ED9_EBA1
                case 40..<60:
                    f = (b & c) | (b & d) | (c & d)
                    k = 0x8F1B_BCDC
                default:
                    f = b ^ c ^ d
                    k = 0xCA62_C1D6
                }
                let temp = rotateLeft(a, 5) &+ f &+ e &+ k &+ schedule[index]
                e = d
                d = c
                c = rotateLeft(b, 30)
                b = a
                a = temp
            }
            state[0] = state[0] &+ a
            state[1] = state[1] &+ b
            state[2] = state[2] &+ c
            state[3] = state[3] &+ d
            state[4] = state[4] &+ e
            chunkStart += 64
        }

        var digest = [UInt8]()
        digest.reserveCapacity(20)
        for word in state {
            digest.append(UInt8(truncatingIfNeeded: word >> 24))
            digest.append(UInt8(truncatingIfNeeded: word >> 16))
            digest.append(UInt8(truncatingIfNeeded: word >> 8))
            digest.append(UInt8(truncatingIfNeeded: word))
        }
        return digest
    }

    private static func rotateLeft(_ value: UInt32, _ amount: UInt32) -> UInt32 {
        (value << amount) | (value >> (32 - amount))
    }
}

// MARK: - Frames

public enum WebSocketOpcode: UInt8, Sendable, Hashable, CaseIterable {
    case continuation = 0x0
    case text = 0x1
    case binary = 0x2
    case close = 0x8
    case ping = 0x9
    case pong = 0xA

    public var isControl: Bool { rawValue & 0x8 != 0 }
}

/// One RFC 6455 §5.2 frame.
public struct WebSocketFrame: Sendable, Hashable {
    public var isFinal: Bool
    public var opcode: WebSocketOpcode
    /// Unmasked payload. Masking is applied at encode time and undone at
    /// decode time, so callers never see masked bytes.
    public var payload: [UInt8]
    /// The 4-byte masking key, or `nil` for an unmasked frame. Clients must
    /// set it; servers must not (§5.1).
    public var maskingKey: [UInt8]?

    public init(
        isFinal: Bool = true,
        opcode: WebSocketOpcode,
        payload: [UInt8] = [],
        maskingKey: [UInt8]? = nil
    ) {
        self.isFinal = isFinal
        self.opcode = opcode
        self.payload = payload
        self.maskingKey = maskingKey
    }
}

/// Which side of the connection a codec is running on.
///
/// This is not cosmetic: §5.1 makes masking asymmetric and mandatory in both
/// directions, so the role decides both what to emit and what to reject.
public enum WebSocketRole: Sendable, Hashable {
    case server
    case client

    /// Frames this role *sends* must be masked.
    var masksOutbound: Bool { self == .client }
    /// Frames this role *receives* must be masked.
    var expectsMaskedInbound: Bool { self == .server }
}

public enum WebSocketFrameCodec {
    /// Serialize one frame. Payload length uses the shortest legal form
    /// (§5.2: 7-bit, then 16-bit, then 64-bit).
    public static func encode(_ frame: WebSocketFrame) -> [UInt8] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(frame.payload.count + 14)
        bytes.append((frame.isFinal ? 0x80 : 0x00) | frame.opcode.rawValue)

        let masked = frame.maskingKey != nil
        let maskBit: UInt8 = masked ? 0x80 : 0x00
        let length = frame.payload.count
        if length < 126 {
            bytes.append(maskBit | UInt8(length))
        } else if length <= 0xFFFF {
            bytes.append(maskBit | 126)
            bytes.append(UInt8(truncatingIfNeeded: length >> 8))
            bytes.append(UInt8(truncatingIfNeeded: length))
        } else {
            bytes.append(maskBit | 127)
            for shift in stride(from: 56, through: 0, by: -8) {
                bytes.append(UInt8(truncatingIfNeeded: UInt64(length) >> UInt64(shift)))
            }
        }

        if let key = frame.maskingKey {
            bytes.append(contentsOf: key)
            for (index, byte) in frame.payload.enumerated() {
                bytes.append(byte ^ key[index % 4])
            }
        } else {
            bytes.append(contentsOf: frame.payload)
        }
        return bytes
    }

    /// Decode one frame from the front of `bytes`.
    ///
    /// Returns `nil` when the buffer holds a prefix of a frame but not a whole
    /// one — that is the split-across-reads case, and it is *not* an error.
    /// Throws only on bytes that can never become a valid frame, which is what
    /// keeps a malformed frame from desynchronising the stream: the caller
    /// closes rather than guessing where the next frame starts.
    public static func decode(
        _ bytes: ArraySlice<UInt8>,
        role: WebSocketRole,
        maximumPayloadSize: Int
    ) throws -> (frame: WebSocketFrame, consumed: Int)? {
        guard bytes.count >= 2 else { return nil }
        let base = bytes.startIndex
        let first = bytes[base]
        let second = bytes[base + 1]

        guard first & 0x70 == 0 else { throw WebSocketProtocolError.reservedBitsSet }
        guard let opcode = WebSocketOpcode(rawValue: first & 0x0F) else {
            throw WebSocketProtocolError.unknownOpcode(first & 0x0F)
        }
        let isFinal = first & 0x80 != 0
        let masked = second & 0x80 != 0

        if role.expectsMaskedInbound && !masked { throw WebSocketProtocolError.unmaskedClientFrame }
        if !role.expectsMaskedInbound && masked { throw WebSocketProtocolError.maskedServerFrame }

        var cursor = base + 2
        let indicator = second & 0x7F
        let payloadLength: Int
        switch indicator {
        case 0..<126:
            payloadLength = Int(indicator)
        case 126:
            guard bytes.count >= cursor - base + 2 else { return nil }
            let value = (Int(bytes[cursor]) << 8) | Int(bytes[cursor + 1])
            // §5.2 requires the minimal length encoding; a 16-bit length below
            // 126 is a non-minimal encoding and therefore a protocol error.
            guard value >= 126 else { throw WebSocketProtocolError.invalidPayloadLength }
            payloadLength = value
            cursor += 2
        default:
            guard bytes.count >= cursor - base + 8 else { return nil }
            var value: UInt64 = 0
            for offset in 0..<8 { value = (value << 8) | UInt64(bytes[cursor + offset]) }
            // §5.2: the high bit of a 64-bit length MUST be 0.
            guard value & 0x8000_0000_0000_0000 == 0 else {
                throw WebSocketProtocolError.invalidPayloadLength
            }
            guard value > 0xFFFF else { throw WebSocketProtocolError.invalidPayloadLength }
            guard value <= UInt64(Int.max) else { throw WebSocketProtocolError.invalidPayloadLength }
            payloadLength = Int(value)
            cursor += 8
        }

        if opcode.isControl {
            guard isFinal else { throw WebSocketProtocolError.fragmentedControlFrame }
            guard payloadLength <= 125 else {
                throw WebSocketProtocolError.oversizedControlPayload(payloadLength)
            }
        }
        // Checked against the declared length before allocating, so an
        // 8 EiB header cannot make us buffer toward it.
        guard payloadLength <= maximumPayloadSize else {
            throw WebSocketProtocolError.messageTooLarge(limit: maximumPayloadSize)
        }

        var maskingKey: [UInt8]?
        if masked {
            guard bytes.count >= cursor - base + 4 else { return nil }
            maskingKey = Array(bytes[cursor..<(cursor + 4)])
            cursor += 4
        }

        guard bytes.count >= cursor - base + payloadLength else { return nil }
        var payload = Array(bytes[cursor..<(cursor + payloadLength)])
        if let key = maskingKey {
            for index in payload.indices { payload[index] ^= key[index % 4] }
        }
        cursor += payloadLength

        let frame = WebSocketFrame(
            isFinal: isFinal,
            opcode: opcode,
            payload: payload,
            maskingKey: maskingKey
        )
        return (frame, cursor - base)
    }
}

/// Incremental frame decoder: feed it whatever the socket hands back, take out
/// whole frames.
///
/// The buffer is compacted only when it drains, so the common case (one read,
/// one frame) does no copying of unconsumed bytes.
public struct WebSocketFrameDecoder: Sendable {
    public let role: WebSocketRole
    public let maximumPayloadSize: Int
    private var buffer: [UInt8] = []
    private var offset: Int = 0

    public init(role: WebSocketRole, maximumPayloadSize: Int = WebSocketLimits.defaultMaximumMessageSize) {
        self.role = role
        self.maximumPayloadSize = maximumPayloadSize
    }

    public var bufferedByteCount: Int { buffer.count - offset }

    public mutating func append(_ bytes: [UInt8]) {
        if offset > 0 && offset == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            offset = 0
        }
        buffer.append(contentsOf: bytes)
    }

    /// Pull the next complete frame, or `nil` if more bytes are needed.
    public mutating func nextFrame() throws -> WebSocketFrame? {
        guard let decoded = try WebSocketFrameCodec.decode(
            buffer[offset...],
            role: role,
            maximumPayloadSize: maximumPayloadSize
        ) else { return nil }
        offset += decoded.consumed
        if offset == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            offset = 0
        } else if offset > 64 * 1024 {
            buffer.removeFirst(offset)
            offset = 0
        }
        return decoded.frame
    }
}

// MARK: - Message assembly

public enum WebSocketLimits {
    /// Matches upstream's `MAX_BUFFER_SIZE`
    /// (`crates/codegen/xai-grok-shell/src/agent/server.rs:56`).
    public static let defaultMaximumMessageSize = 8 * 1024 * 1024
    /// Matches upstream's `KEEPALIVE_INTERVAL_SECS`
    /// (`crates/codegen/xai-grok-shell/src/agent/server.rs:57`).
    public static let keepAliveIntervalSeconds: UInt64 = 15
    /// Cap on the HTTP request head, so a peer that never sends `\r\n\r\n`
    /// cannot make the server buffer without bound before the upgrade.
    public static let maximumHandshakeHeadSize = 16 * 1024
}

/// A complete application-level event, after fragments are joined.
public enum WebSocketEvent: Sendable, Hashable {
    case text(String)
    case binary([UInt8])
    case ping([UInt8])
    case pong([UInt8])
    case close(code: UInt16?, reason: String)
}

/// Joins frames into messages, per §5.4.
///
/// Control frames may arrive *between* the fragments of a data message, so
/// they are passed straight through without disturbing the partial message.
public struct WebSocketMessageAssembler: Sendable {
    public let maximumMessageSize: Int
    private var fragmentOpcode: WebSocketOpcode?
    private var fragments: [UInt8] = []

    public init(maximumMessageSize: Int = WebSocketLimits.defaultMaximumMessageSize) {
        self.maximumMessageSize = maximumMessageSize
    }

    public var hasPartialMessage: Bool { fragmentOpcode != nil }

    /// Feed one frame. Returns the completed event, or `nil` when this frame
    /// was a non-final fragment.
    public mutating func accept(_ frame: WebSocketFrame) throws -> WebSocketEvent? {
        switch frame.opcode {
        case .ping:
            return .ping(frame.payload)
        case .pong:
            return .pong(frame.payload)
        case .close:
            return .close(code: try Self.closeCode(from: frame.payload), reason: Self.closeReason(from: frame.payload))
        case .text, .binary:
            guard fragmentOpcode == nil else { throw WebSocketProtocolError.interleavedDataFrame }
            if frame.isFinal { return try Self.event(opcode: frame.opcode, payload: frame.payload) }
            try checkSize(frame.payload.count)
            fragmentOpcode = frame.opcode
            fragments = frame.payload
            return nil
        case .continuation:
            guard let opcode = fragmentOpcode else { throw WebSocketProtocolError.unexpectedContinuation }
            try checkSize(fragments.count + frame.payload.count)
            fragments.append(contentsOf: frame.payload)
            guard frame.isFinal else { return nil }
            let payload = fragments
            fragmentOpcode = nil
            fragments = []
            return try Self.event(opcode: opcode, payload: payload)
        }
    }

    private func checkSize(_ size: Int) throws {
        guard size <= maximumMessageSize else {
            throw WebSocketProtocolError.messageTooLarge(limit: maximumMessageSize)
        }
    }

    private static func event(opcode: WebSocketOpcode, payload: [UInt8]) throws -> WebSocketEvent {
        switch opcode {
        case .binary:
            return .binary(payload)
        default:
            guard let text = String(bytes: payload, encoding: .utf8) else {
                throw WebSocketProtocolError.invalidUTF8
            }
            return .text(text)
        }
    }

    /// §5.5.1: a close payload is empty, or a 2-byte code optionally followed
    /// by a UTF-8 reason. A 1-byte payload is a protocol error.
    static func closeCode(from payload: [UInt8]) throws -> UInt16? {
        if payload.isEmpty { return nil }
        guard payload.count >= 2 else { throw WebSocketProtocolError.invalidClosePayload }
        let code = (UInt16(payload[0]) << 8) | UInt16(payload[1])
        switch code {
        // §7.4.1 reserves 1005/1006/1015 for local use — they must never
        // appear on the wire.
        case 1005, 1006, 1015:
            throw WebSocketProtocolError.invalidClosePayload
        case 0..<1000, 1016..<3000:
            throw WebSocketProtocolError.invalidClosePayload
        default:
            return code
        }
    }

    static func closeReason(from payload: [UInt8]) -> String {
        guard payload.count > 2 else { return "" }
        return String(decoding: payload[2...], as: UTF8.self)
    }

    /// Build a close frame payload from a code and reason.
    public static func closePayload(code: UInt16, reason: String) -> [UInt8] {
        var payload: [UInt8] = [UInt8(truncatingIfNeeded: code >> 8), UInt8(truncatingIfNeeded: code)]
        // §5.5 caps a control payload at 125 bytes, so the reason gets 123.
        // Truncation is on UTF-8 code-unit boundaries to avoid emitting a
        // partial scalar.
        var reasonBytes = Array(reason.utf8)
        if reasonBytes.count > 123 {
            reasonBytes = Array(reasonBytes.prefix(123))
            while !reasonBytes.isEmpty && String(bytes: reasonBytes, encoding: .utf8) == nil {
                reasonBytes.removeLast()
            }
        }
        payload.append(contentsOf: reasonBytes)
        return payload
    }
}

// MARK: - Handshake

/// A parsed HTTP/1.1 request head, enough to answer an upgrade.
public struct WebSocketHandshakeRequest: Sendable, Hashable {
    public var method: String
    /// The raw request target, query string included.
    public var target: String
    /// The path with the query stripped.
    public var path: String
    public var queryItems: [String: String]
    /// Header names lowercased; duplicates joined with `", "` per RFC 7230 §3.2.2.
    public var headers: [String: String]

    public init(
        method: String,
        target: String,
        path: String,
        queryItems: [String: String],
        headers: [String: String]
    ) {
        self.method = method
        self.target = target
        self.path = path
        self.queryItems = queryItems
        self.headers = headers
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// The bearer token from `Authorization: Bearer <token>`, if present.
    public var bearerToken: String? {
        guard let value = header("authorization") else { return nil }
        let prefix = "Bearer "
        guard value.hasPrefix(prefix) else { return nil }
        return String(value.dropFirst(prefix.count))
    }
}

public enum WebSocketHandshake {
    /// RFC 6455 §1.3.
    public static let magicGUID = "258EAFA5-E914-47DA-95CA-5AB0DC85B11D"

    /// `base64(SHA1(key + GUID))`.
    public static func acceptToken(forKey key: String) -> String {
        let digest = InsecureSHA1.hash(Array((key + magicGUID).utf8))
        return Data(digest).base64EncodedString()
    }

    /// A fresh 16-byte client key, base64-encoded (§4.1).
    public static func makeClientKey(
        randomBytes: @Sendable () -> UInt8 = { UInt8.random(in: 0...255) }
    ) -> String {
        var bytes = [UInt8]()
        bytes.reserveCapacity(16)
        for _ in 0..<16 { bytes.append(randomBytes()) }
        return Data(bytes).base64EncodedString()
    }

    /// Parse a request head.
    ///
    /// Returns `nil` when `\r\n\r\n` has not arrived yet, so the caller keeps
    /// reading. The second element is the byte count consumed, which lets the
    /// caller keep any frame bytes a client pipelined behind the handshake.
    public static func parseRequest(
        _ bytes: [UInt8],
        maximumHeadSize: Int = WebSocketLimits.maximumHandshakeHeadSize
    ) throws -> (request: WebSocketHandshakeRequest, consumed: Int)? {
        guard let terminator = findHeadTerminator(bytes) else {
            guard bytes.count <= maximumHeadSize else {
                throw WebSocketHandshakeError.headTooLarge(limit: maximumHeadSize)
            }
            return nil
        }
        guard terminator <= maximumHeadSize else {
            throw WebSocketHandshakeError.headTooLarge(limit: maximumHeadSize)
        }
        let head = String(decoding: bytes[0..<terminator], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw WebSocketHandshakeError.malformedRequestLine }
        lines.removeFirst()

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { throw WebSocketHandshakeError.malformedRequestLine }
        let method = String(parts[0])
        let target = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                throw WebSocketHandshakeError.malformedHeader(line)
            }
            let name = line[line.startIndex..<colon]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw WebSocketHandshakeError.malformedHeader(line) }
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }

        let (path, query) = splitTarget(target)
        let request = WebSocketHandshakeRequest(
            method: method,
            target: target,
            path: path,
            queryItems: query,
            headers: headers
        )
        return (request, terminator)
    }

    /// Check the upgrade preconditions and return the accept token.
    ///
    /// `path` is checked when supplied; upstream serves exactly one route,
    /// `GET /ws` (`crates/codegen/xai-grok-shell/src/agent/server.rs:470`).
    public static func validateUpgrade(
        _ request: WebSocketHandshakeRequest,
        expectedPath: String? = nil
    ) throws -> String {
        guard request.method.uppercased() == "GET" else {
            throw WebSocketHandshakeError.unsupportedMethod(request.method)
        }
        if let expectedPath, request.path != expectedPath {
            throw WebSocketHandshakeError.notFound(path: request.path)
        }
        guard let upgrade = request.header("upgrade"),
              upgrade.lowercased().contains("websocket")
        else { throw WebSocketHandshakeError.missingUpgrade }
        guard let connection = request.header("connection"),
              connection.lowercased().split(whereSeparator: { $0 == "," || $0 == " " })
                  .contains("upgrade")
        else { throw WebSocketHandshakeError.missingConnectionUpgrade }
        let version = request.header("sec-websocket-version")
        guard version == "13" else { throw WebSocketHandshakeError.unsupportedVersion(version) }
        guard let key = request.header("sec-websocket-key") else {
            throw WebSocketHandshakeError.missingKey
        }
        // §4.1: the key is exactly 16 base64-encoded bytes. Checking it here is
        // what makes a bad key a 400 instead of a connection that both sides
        // think succeeded.
        guard let decoded = Data(base64Encoded: key), decoded.count == 16 else {
            throw WebSocketHandshakeError.invalidKey(key)
        }
        return acceptToken(forKey: key)
    }

    public static func acceptResponse(accept: String) -> [UInt8] {
        let response = """
            HTTP/1.1 101 Switching Protocols\r
            Upgrade: websocket\r
            Connection: Upgrade\r
            Sec-WebSocket-Accept: \(accept)\r
            \r

            """
        return Array(response.utf8)
    }

    public static func rejectResponse(_ error: WebSocketHandshakeError) -> [UInt8] {
        rejectResponse(status: error.httpStatus, body: error.description)
    }

    public static func rejectResponse(status: Int, body: String) -> [UInt8] {
        let reason = reasonPhrase(status)
        let bodyBytes = Array(body.utf8)
        let head = """
            HTTP/1.1 \(status) \(reason)\r
            Content-Type: text/plain; charset=utf-8\r
            Content-Length: \(bodyBytes.count)\r
            Connection: close\r
            \r

            """
        return Array(head.utf8) + bodyBytes
    }

    /// The client-side request head, used by the in-process test client and by
    /// any future client that needs to speak to a non-URLSession peer.
    public static func clientRequest(
        host: String,
        target: String,
        key: String,
        headers: [(String, String)] = []
    ) -> [UInt8] {
        var lines = [
            "GET \(target) HTTP/1.1",
            "Host: \(host)",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: \(key)",
            "Sec-WebSocket-Version: 13",
        ]
        for (name, value) in headers { lines.append("\(name): \(value)") }
        return Array((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    /// Parse a server response head. Returns `nil` until it is complete.
    public static func parseResponse(
        _ bytes: [UInt8],
        maximumHeadSize: Int = WebSocketLimits.maximumHandshakeHeadSize
    ) throws -> (status: Int, headers: [String: String], body: String, consumed: Int)? {
        guard let terminator = findHeadTerminator(bytes) else {
            guard bytes.count <= maximumHeadSize else {
                throw WebSocketHandshakeError.headTooLarge(limit: maximumHeadSize)
            }
            return nil
        }
        let head = String(decoding: bytes[0..<terminator], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { throw WebSocketHandshakeError.malformedRequestLine }
        lines.removeFirst()
        let parts = statusLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, let status = Int(parts[1]) else {
            throw WebSocketHandshakeError.malformedRequestLine
        }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                throw WebSocketHandshakeError.malformedHeader(line)
            }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let body = String(decoding: bytes[terminator...], as: UTF8.self)
        return (status, headers, body, terminator)
    }

    // MARK: helpers

    private static func findHeadTerminator(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        let cr = UInt8(ascii: "\r"), lf = UInt8(ascii: "\n")
        var index = 0
        while index + 3 < bytes.count {
            if bytes[index] == cr, bytes[index + 1] == lf, bytes[index + 2] == cr, bytes[index + 3] == lf {
                return index + 4
            }
            index += 1
        }
        return nil
    }

    static func splitTarget(_ target: String) -> (path: String, query: [String: String]) {
        guard let mark = target.firstIndex(of: "?") else { return (target, [:]) }
        let path = String(target[target.startIndex..<mark])
        let queryString = target[target.index(after: mark)...]
        var items: [String: String] = [:]
        for pair in queryString.split(separator: "&", omittingEmptySubsequences: true) {
            let halves = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = percentDecoded(String(halves[0]))
            let value = halves.count > 1 ? percentDecoded(String(halves[1])) : ""
            items[name] = value
        }
        return (path, items)
    }

    private static func percentDecoded(_ value: String) -> String {
        let plusDecoded = value.replacingOccurrences(of: "+", with: " ")
        return plusDecoded.removingPercentEncoding ?? plusDecoded
    }

    private static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 101: return "Switching Protocols"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 426: return "Upgrade Required"
        default: return "Error"
        }
    }
}
