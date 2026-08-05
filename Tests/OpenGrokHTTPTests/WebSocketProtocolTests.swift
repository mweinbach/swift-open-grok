// WebSocketProtocolTests.swift
//
// Byte-level tests for the RFC 6455 handshake and frame codec.
//
// The frame tests are written against literal byte sequences rather than
// round-trips wherever the spec pins an exact encoding, because a round-trip
// test passes just as happily against a codec that is self-consistently wrong.

import Foundation
import Testing
@testable import OpenGrokHTTP

@Suite("WebSocket SHA-1")
struct WebSocketSHA1Tests {
    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    @Test func matchesFIPS180Vectors() {
        // The three vectors from FIPS 180-2 / RFC 3174 §7.3.
        #expect(hex(InsecureSHA1.hash(Array("abc".utf8)))
            == "a9993e364706816aba3e25717850c26c9cd0d89d")
        #expect(hex(InsecureSHA1.hash(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)))
            == "84983e441c3bd26ebaae4aa1f95129e5e54670f1")
        #expect(hex(InsecureSHA1.hash([])) == "da39a3ee5e6b4b0d3255bfef95601890afd80709")
    }

    @Test func handlesMultiBlockInput() {
        // 1,000,000 'a' would be slow here; 1000 crosses the 64-byte block
        // boundary many times and the padding boundary at 56 mod 64.
        let message = Array(String(repeating: "a", count: 1000).utf8)
        #expect(hex(InsecureSHA1.hash(message)) == "291e9a6c66994949b57ba5e650361e98fc36b1ba")
    }

    @Test func handlesExactBlockBoundaryLengths() {
        // 55/56/64 are the lengths where SHA-1 padding changes shape.
        #expect(hex(InsecureSHA1.hash(Array(String(repeating: "a", count: 55).utf8)))
            == "c1c8bbdc22796e28c0e15163d20899b65621d65a")
        #expect(hex(InsecureSHA1.hash(Array(String(repeating: "a", count: 56).utf8)))
            == "c2db330f6083854c99d4b5bfb6e8f29f201be699")
        #expect(hex(InsecureSHA1.hash(Array(String(repeating: "a", count: 64).utf8)))
            == "0098ba824b5c16427bd7a1122a5a442a25ec644d")
    }
}

@Suite("WebSocket handshake")
struct WebSocketHandshakeTests {
    @Test func computesTheAcceptToken() {
        // Goldens computed with an independent SHA-1 (Python `hashlib`) over
        // `key + WebSocketHandshake.magicGUID`, so this pins the derivation
        // against something other than the implementation under test.
        #expect(WebSocketHandshake.acceptToken(forKey: "dGhlIHNhbXBsZSBub25jZQ==")
            == "7NQHw21/u2y5o3iigl/YosUutlE=")
        #expect(WebSocketHandshake.acceptToken(forKey: "x3JJHMbDL1EzLkh9GBhXDw==")
            == "NDr7YQKnBMADxvXsIVpb/rafc98=")
        #expect(WebSocketHandshake.magicGUID == "258EAFA5-E914-47DA-95CA-5AB0DC85B11D")
    }

    @Test func parsesARequestHeadAndReportsBytesConsumed() throws {
        let head = "GET /ws?server-key=abc123 HTTP/1.1\r\n"
            + "Host: 127.0.0.1:2419\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
            + "Sec-WebSocket-Version: 13\r\n\r\n"
        let bytes = Array(head.utf8) + [0x81, 0x00]
        let parsed = try #require(try WebSocketHandshake.parseRequest(bytes))
        #expect(parsed.request.method == "GET")
        #expect(parsed.request.path == "/ws")
        #expect(parsed.request.queryItems["server-key"] == "abc123")
        #expect(parsed.request.header("Sec-WebSocket-Version") == "13")
        // Consumed must stop at the head so pipelined frame bytes survive.
        #expect(parsed.consumed == head.utf8.count)
        #expect(Array(bytes[parsed.consumed...]) == [0x81, 0x00])
    }

    @Test func returnsNilUntilTheHeadIsComplete() throws {
        let partial = Array("GET /ws HTTP/1.1\r\nHost: x\r\n".utf8)
        #expect(try WebSocketHandshake.parseRequest(partial) == nil)
    }

    @Test func rejectsAHeadThatNeverTerminates() {
        let flood = Array(String(repeating: "X", count: 40).utf8)
        #expect(throws: WebSocketHandshakeError.headTooLarge(limit: 32)) {
            _ = try WebSocketHandshake.parseRequest(flood, maximumHeadSize: 32)
        }
    }

    @Test func joinsDuplicateHeaders() throws {
        let head = "GET /ws HTTP/1.1\r\nX-Thing: a\r\nX-Thing: b\r\n\r\n"
        let parsed = try #require(try WebSocketHandshake.parseRequest(Array(head.utf8)))
        #expect(parsed.request.header("x-thing") == "a, b")
    }

    @Test func extractsABearerToken() throws {
        let head = "GET /ws HTTP/1.1\r\nAuthorization: Bearer s3cret\r\n\r\n"
        let parsed = try #require(try WebSocketHandshake.parseRequest(Array(head.utf8)))
        #expect(parsed.request.bearerToken == "s3cret")
    }

    @Test func ignoresANonBearerAuthorizationScheme() throws {
        let head = "GET /ws HTTP/1.1\r\nAuthorization: Basic abc\r\n\r\n"
        let parsed = try #require(try WebSocketHandshake.parseRequest(Array(head.utf8)))
        #expect(parsed.request.bearerToken == nil)
    }

    private func request(
        method: String = "GET",
        target: String = "/ws",
        key: String? = "dGhlIHNhbXBsZSBub25jZQ==",
        version: String? = "13",
        upgrade: String? = "websocket",
        connection: String? = "Upgrade"
    ) -> WebSocketHandshakeRequest {
        var headers: [String: String] = [:]
        if let upgrade { headers["upgrade"] = upgrade }
        if let connection { headers["connection"] = connection }
        if let version { headers["sec-websocket-version"] = version }
        if let key { headers["sec-websocket-key"] = key }
        let split = WebSocketHandshake.splitTarget(target)
        return WebSocketHandshakeRequest(
            method: method,
            target: target,
            path: split.path,
            queryItems: split.query,
            headers: headers
        )
    }

    @Test func validatesAWellFormedUpgrade() throws {
        let accept = try WebSocketHandshake.validateUpgrade(request(), expectedPath: "/ws")
        #expect(accept == "7NQHw21/u2y5o3iigl/YosUutlE=")
    }

    @Test func acceptsAConnectionHeaderWithMultipleTokens() throws {
        // Browsers and proxies routinely send "keep-alive, Upgrade".
        let accept = try WebSocketHandshake.validateUpgrade(
            request(connection: "keep-alive, Upgrade"),
            expectedPath: "/ws"
        )
        #expect(accept == "7NQHw21/u2y5o3iigl/YosUutlE=")
    }

    @Test func rejectsABadKey() {
        // Right shape, wrong decoded length — this is the "bad key" case, and
        // it must be a 400 rather than a connection both sides think worked.
        #expect(throws: WebSocketHandshakeError.invalidKey("c2hvcnQ=")) {
            _ = try WebSocketHandshake.validateUpgrade(request(key: "c2hvcnQ="))
        }
        #expect(throws: WebSocketHandshakeError.invalidKey("not base64 at all!!")) {
            _ = try WebSocketHandshake.validateUpgrade(request(key: "not base64 at all!!"))
        }
        #expect(throws: WebSocketHandshakeError.missingKey) {
            _ = try WebSocketHandshake.validateUpgrade(request(key: nil))
        }
    }

    @Test func rejectsAWrongVersionWith426() {
        let error = WebSocketHandshakeError.unsupportedVersion("8")
        #expect(throws: error) {
            _ = try WebSocketHandshake.validateUpgrade(request(version: "8"))
        }
        #expect(error.httpStatus == 426)
    }

    @Test func rejectsAWrongPathWith404() {
        let error = WebSocketHandshakeError.notFound(path: "/other")
        #expect(throws: error) {
            _ = try WebSocketHandshake.validateUpgrade(request(target: "/other"), expectedPath: "/ws")
        }
        #expect(error.httpStatus == 404)
    }

    @Test func rejectsANonGetMethod() {
        #expect(throws: WebSocketHandshakeError.unsupportedMethod("POST")) {
            _ = try WebSocketHandshake.validateUpgrade(request(method: "POST"))
        }
    }

    @Test func rejectsAMissingUpgradeHeader() {
        #expect(throws: WebSocketHandshakeError.missingUpgrade) {
            _ = try WebSocketHandshake.validateUpgrade(request(upgrade: nil))
        }
        #expect(throws: WebSocketHandshakeError.missingConnectionUpgrade) {
            _ = try WebSocketHandshake.validateUpgrade(request(connection: "keep-alive"))
        }
    }

    @Test func rendersTheAcceptResponseVerbatim() {
        let bytes = WebSocketHandshake.acceptResponse(accept: "7NQHw21/u2y5o3iigl/YosUutlE=")
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text == "HTTP/1.1 101 Switching Protocols\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: 7NQHw21/u2y5o3iigl/YosUutlE=\r\n\r\n")
    }

    @Test func rendersRejectionsWithTheRightStatusAndBody() {
        let text = String(decoding: WebSocketHandshake.rejectResponse(.unauthorized), as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"))
        // The body text is upstream's, verbatim (`server.rs:120`).
        #expect(text.hasSuffix("Invalid or missing authorization token"))
        #expect(text.contains("Content-Length: 38\r\n"))
    }

    @Test func parsesQueryItemsWithPercentEncoding() {
        let split = WebSocketHandshake.splitTarget("/ws?server-key=a%2Bb%3Dc&other=1")
        #expect(split.path == "/ws")
        #expect(split.query["server-key"] == "a+b=c")
        #expect(split.query["other"] == "1")
    }

    @Test func makesA16ByteClientKey() throws {
        let key = WebSocketHandshake.makeClientKey()
        let decoded = try #require(Data(base64Encoded: key))
        #expect(decoded.count == 16)
    }
}

@Suite("WebSocket frame codec")
struct WebSocketFrameCodecTests {
    // The four framing examples from RFC 6455 §5.7.
    @Test func encodesTheSpecExamples() {
        let unmaskedHello = WebSocketFrame(opcode: .text, payload: Array("Hello".utf8))
        #expect(WebSocketFrameCodec.encode(unmaskedHello)
            == [0x81, 0x05, 0x48, 0x65, 0x6C, 0x6C, 0x6F])

        let maskedHello = WebSocketFrame(
            opcode: .text,
            payload: Array("Hello".utf8),
            maskingKey: [0x37, 0xFA, 0x21, 0x3D]
        )
        #expect(WebSocketFrameCodec.encode(maskedHello)
            == [0x81, 0x85, 0x37, 0xFA, 0x21, 0x3D, 0x7F, 0x9F, 0x4D, 0x51, 0x58])

        let firstFragment = WebSocketFrame(isFinal: false, opcode: .text, payload: Array("Hel".utf8))
        #expect(WebSocketFrameCodec.encode(firstFragment) == [0x01, 0x03, 0x48, 0x65, 0x6C])
        let lastFragment = WebSocketFrame(opcode: .continuation, payload: Array("lo".utf8))
        #expect(WebSocketFrameCodec.encode(lastFragment) == [0x80, 0x02, 0x6C, 0x6F])

        let ping = WebSocketFrame(opcode: .ping, payload: Array("Hello".utf8))
        #expect(WebSocketFrameCodec.encode(ping) == [0x89, 0x05, 0x48, 0x65, 0x6C, 0x6C, 0x6F])
    }

    @Test func decodesTheMaskedSpecExample() throws {
        let bytes: [UInt8] = [0x81, 0x85, 0x37, 0xFA, 0x21, 0x3D, 0x7F, 0x9F, 0x4D, 0x51, 0x58]
        let decoded = try #require(
            try WebSocketFrameCodec.decode(bytes[...], role: .server, maximumPayloadSize: 1024)
        )
        #expect(decoded.consumed == bytes.count)
        #expect(decoded.frame.opcode == .text)
        #expect(decoded.frame.isFinal)
        // The payload comes back unmasked; callers never see masked bytes.
        #expect(decoded.frame.payload == Array("Hello".utf8))
        #expect(decoded.frame.maskingKey == [0x37, 0xFA, 0x21, 0x3D])
    }

    @Test func usesTheShortestLegalLengthEncoding() {
        // 125 fits the 7-bit form; 126 needs the 16-bit form; 65536 the 64-bit.
        let short = WebSocketFrame(opcode: .binary, payload: [UInt8](repeating: 0, count: 125))
        #expect(Array(WebSocketFrameCodec.encode(short).prefix(2)) == [0x82, 125])

        let medium = WebSocketFrame(opcode: .binary, payload: [UInt8](repeating: 0, count: 126))
        #expect(Array(WebSocketFrameCodec.encode(medium).prefix(4)) == [0x82, 126, 0x00, 0x7E])

        let long = WebSocketFrame(opcode: .binary, payload: [UInt8](repeating: 0, count: 65536))
        #expect(Array(WebSocketFrameCodec.encode(long).prefix(10))
            == [0x82, 127, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00])
    }

    @Test func roundTripsEveryLengthBoundary() throws {
        for size in [0, 1, 125, 126, 127, 65535, 65536, 70000] {
            let payload = (0..<size).map { UInt8($0 % 251) }
            let frame = WebSocketFrame(
                opcode: .binary,
                payload: payload,
                maskingKey: [0x01, 0x02, 0x03, 0x04]
            )
            let bytes = WebSocketFrameCodec.encode(frame)
            let decoded = try #require(
                try WebSocketFrameCodec.decode(bytes[...], role: .server, maximumPayloadSize: 1 << 20)
            )
            #expect(decoded.consumed == bytes.count, "size \(size)")
            #expect(decoded.frame.payload == payload, "size \(size)")
        }
    }

    @Test func returnsNilForEveryPrefixOfAFrame() throws {
        let frame = WebSocketFrame(
            opcode: .text,
            payload: Array("hello world".utf8),
            maskingKey: [0xAA, 0xBB, 0xCC, 0xDD]
        )
        let bytes = WebSocketFrameCodec.encode(frame)
        // Every strict prefix must be "need more bytes", never an error and
        // never a frame — this is the split-across-reads guarantee.
        for length in 0..<bytes.count {
            let prefix = Array(bytes.prefix(length))
            let decoded = try WebSocketFrameCodec.decode(
                prefix[...],
                role: .server,
                maximumPayloadSize: 1024
            )
            #expect(decoded == nil, "prefix of length \(length) decoded early")
        }
        #expect(try WebSocketFrameCodec.decode(bytes[...], role: .server, maximumPayloadSize: 1024) != nil)
    }

    @Test func decodesOnlyOneFrameFromAConcatenatedBuffer() throws {
        let first = WebSocketFrameCodec.encode(
            WebSocketFrame(opcode: .text, payload: Array("one".utf8), maskingKey: [1, 2, 3, 4])
        )
        let second = WebSocketFrameCodec.encode(
            WebSocketFrame(opcode: .text, payload: Array("two".utf8), maskingKey: [5, 6, 7, 8])
        )
        let buffer = first + second
        let decoded = try #require(
            try WebSocketFrameCodec.decode(buffer[...], role: .server, maximumPayloadSize: 1024)
        )
        #expect(decoded.consumed == first.count)
        #expect(decoded.frame.payload == Array("one".utf8))
    }

    @Test func rejectsAnUnmaskedClientFrame() {
        // RFC 6455 §5.1: a server MUST close on an unmasked client frame.
        let bytes: [UInt8] = [0x81, 0x02, 0x68, 0x69]
        #expect(throws: WebSocketProtocolError.unmaskedClientFrame) {
            _ = try WebSocketFrameCodec.decode(bytes[...], role: .server, maximumPayloadSize: 1024)
        }
    }

    @Test func rejectsAMaskedServerFrame() {
        let bytes: [UInt8] = [0x81, 0x82, 0x01, 0x02, 0x03, 0x04, 0x69, 0x6B]
        #expect(throws: WebSocketProtocolError.maskedServerFrame) {
            _ = try WebSocketFrameCodec.decode(bytes[...], role: .client, maximumPayloadSize: 1024)
        }
    }

    @Test func rejectsReservedBits() {
        for reserved: UInt8 in [0x40, 0x20, 0x10] {
            let bytes: [UInt8] = [0x80 | reserved | 0x01, 0x80, 0, 0, 0, 0]
            #expect(throws: WebSocketProtocolError.reservedBitsSet) {
                _ = try WebSocketFrameCodec.decode(bytes[...], role: .server, maximumPayloadSize: 1024)
            }
        }
    }

    @Test func rejectsUnknownOpcodes() {
        for opcode: UInt8 in [0x3, 0x4, 0x7, 0xB, 0xF] {
            let bytes: [UInt8] = [0x80 | opcode, 0x80, 0, 0, 0, 0]
            #expect(throws: WebSocketProtocolError.unknownOpcode(opcode)) {
                _ = try WebSocketFrameCodec.decode(bytes[...], role: .server, maximumPayloadSize: 1024)
            }
        }
    }

    @Test func rejectsAFragmentedControlFrame() {
        let bytes: [UInt8] = [0x09, 0x80, 0, 0, 0, 0]  // ping, FIN clear
        #expect(throws: WebSocketProtocolError.fragmentedControlFrame) {
            _ = try WebSocketFrameCodec.decode(bytes[...], role: .server, maximumPayloadSize: 1024)
        }
    }

    @Test func rejectsAnOversizedControlPayload() {
        // 126 bytes of ping payload; §5.5 caps control frames at 125.
        var bytes: [UInt8] = [0x89, 0x80 | 126, 0x00, 0x7E, 0, 0, 0, 0]
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 126))
        #expect(throws: WebSocketProtocolError.oversizedControlPayload(126)) {
            _ = try WebSocketFrameCodec.decode(bytes[...], role: .server, maximumPayloadSize: 1024)
        }
    }

    @Test func rejectsNonMinimalLengthEncodings() {
        // 16-bit length carrying a value that fits the 7-bit form.
        let sixteen: [UInt8] = [0x81, 0x80 | 126, 0x00, 0x05, 0, 0, 0, 0]
        #expect(throws: WebSocketProtocolError.invalidPayloadLength) {
            _ = try WebSocketFrameCodec.decode(sixteen[...], role: .server, maximumPayloadSize: 1 << 20)
        }
        // 64-bit length carrying a value that fits the 16-bit form.
        let sixtyFour: [UInt8] = [0x81, 0x80 | 127, 0, 0, 0, 0, 0, 0, 0x01, 0x00, 0, 0, 0, 0]
        #expect(throws: WebSocketProtocolError.invalidPayloadLength) {
            _ = try WebSocketFrameCodec.decode(sixtyFour[...], role: .server, maximumPayloadSize: 1 << 20)
        }
    }

    @Test func rejectsA64BitLengthWithTheHighBitSet() {
        let bytes: [UInt8] = [0x82, 0x80 | 127, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        #expect(throws: WebSocketProtocolError.invalidPayloadLength) {
            _ = try WebSocketFrameCodec.decode(bytes[...], role: .server, maximumPayloadSize: Int.max)
        }
    }

    @Test func rejectsAnOversizedFrameFromItsHeaderAlone() {
        // Only the 10-byte header is present. A 1 MiB declared length against
        // a 1 KiB cap must be refused now, not after buffering toward it.
        let bytes: [UInt8] = [0x82, 0x80 | 127, 0, 0, 0, 0, 0, 0x10, 0x00, 0x00]
        #expect(throws: WebSocketProtocolError.messageTooLarge(limit: 1024)) {
            _ = try WebSocketFrameCodec.decode(bytes[...], role: .server, maximumPayloadSize: 1024)
        }
    }

    @Test func closeCodeMapsToTheSpecCategory() {
        #expect(WebSocketProtocolError.unmaskedClientFrame.closeCode == 1002)
        #expect(WebSocketProtocolError.messageTooLarge(limit: 1).closeCode == 1009)
        #expect(WebSocketProtocolError.invalidUTF8.closeCode == 1007)
    }
}

@Suite("WebSocket incremental decoder")
struct WebSocketFrameDecoderTests {
    @Test func reassemblesFramesSplitAcrossReadsAtEveryOffset() throws {
        let frames = [
            WebSocketFrame(opcode: .text, payload: Array("alpha".utf8), maskingKey: [1, 2, 3, 4]),
            WebSocketFrame(opcode: .ping, payload: [0xFF], maskingKey: [9, 9, 9, 9]),
            WebSocketFrame(
                opcode: .binary,
                payload: [UInt8](repeating: 0x5A, count: 300),
                maskingKey: [4, 3, 2, 1]
            ),
        ]
        let stream = frames.flatMap { WebSocketFrameCodec.encode($0) }

        // Every possible two-chunk split of the whole stream must yield the
        // same three frames. This is the test that catches a decoder that
        // desyncs when a header straddles a read boundary.
        for split in 0...stream.count {
            var decoder = WebSocketFrameDecoder(role: .server, maximumPayloadSize: 4096)
            decoder.append(Array(stream[0..<split]))
            var decoded: [WebSocketFrame] = []
            while let frame = try decoder.nextFrame() { decoded.append(frame) }
            decoder.append(Array(stream[split...]))
            while let frame = try decoder.nextFrame() { decoded.append(frame) }
            #expect(decoded.count == 3, "split at \(split)")
            #expect(decoded.map(\.opcode) == [.text, .ping, .binary], "split at \(split)")
            #expect(decoded[2].payload.count == 300, "split at \(split)")
        }
    }

    @Test func handlesOneByteAtATime() throws {
        let frame = WebSocketFrame(
            opcode: .text,
            payload: Array("drip".utf8),
            maskingKey: [0x11, 0x22, 0x33, 0x44]
        )
        let bytes = WebSocketFrameCodec.encode(frame)
        var decoder = WebSocketFrameDecoder(role: .server, maximumPayloadSize: 1024)
        for index in 0..<(bytes.count - 1) {
            decoder.append([bytes[index]])
            #expect(try decoder.nextFrame() == nil, "byte \(index) completed a frame early")
        }
        decoder.append([bytes[bytes.count - 1]])
        let decoded = try #require(try decoder.nextFrame())
        #expect(decoded.payload == Array("drip".utf8))
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test func drainsTheBufferAfterConsumingEverything() throws {
        var decoder = WebSocketFrameDecoder(role: .server, maximumPayloadSize: 1024)
        decoder.append(WebSocketFrameCodec.encode(
            WebSocketFrame(opcode: .text, payload: Array("x".utf8), maskingKey: [1, 1, 1, 1])
        ))
        _ = try decoder.nextFrame()
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test func aMalformedFrameThrowsRatherThanResyncing() {
        var decoder = WebSocketFrameDecoder(role: .server, maximumPayloadSize: 1024)
        // Unmasked client frame followed by a perfectly good one. The decoder
        // must refuse at the bad frame instead of scanning ahead for the good
        // one — silently resyncing is how a stream desynchronises.
        decoder.append([0x81, 0x02, 0x68, 0x69])
        decoder.append(WebSocketFrameCodec.encode(
            WebSocketFrame(opcode: .text, payload: Array("ok".utf8), maskingKey: [1, 2, 3, 4])
        ))
        #expect(throws: WebSocketProtocolError.unmaskedClientFrame) {
            _ = try decoder.nextFrame()
        }
    }
}

@Suite("WebSocket message assembly")
struct WebSocketMessageAssemblerTests {
    @Test func joinsFragmentsIntoOneMessage() throws {
        var assembler = WebSocketMessageAssembler()
        #expect(try assembler.accept(
            WebSocketFrame(isFinal: false, opcode: .text, payload: Array("Hel".utf8))
        ) == nil)
        #expect(assembler.hasPartialMessage)
        let event = try assembler.accept(
            WebSocketFrame(opcode: .continuation, payload: Array("lo".utf8))
        )
        #expect(event == .text("Hello"))
        #expect(!assembler.hasPartialMessage)
    }

    @Test func passesControlFramesThroughMidMessage() throws {
        // §5.4: a control frame may be injected between fragments and must not
        // disturb the partial message.
        var assembler = WebSocketMessageAssembler()
        _ = try assembler.accept(WebSocketFrame(isFinal: false, opcode: .binary, payload: [1, 2]))
        #expect(try assembler.accept(WebSocketFrame(opcode: .ping, payload: [7])) == .ping([7]))
        #expect(assembler.hasPartialMessage)
        let event = try assembler.accept(WebSocketFrame(opcode: .continuation, payload: [3]))
        #expect(event == .binary([1, 2, 3]))
    }

    @Test func rejectsAContinuationWithNothingInProgress() {
        var assembler = WebSocketMessageAssembler()
        #expect(throws: WebSocketProtocolError.unexpectedContinuation) {
            _ = try assembler.accept(WebSocketFrame(opcode: .continuation, payload: [1]))
        }
    }

    @Test func rejectsANewDataFrameMidMessage() throws {
        var assembler = WebSocketMessageAssembler()
        _ = try assembler.accept(WebSocketFrame(isFinal: false, opcode: .text, payload: [0x61]))
        #expect(throws: WebSocketProtocolError.interleavedDataFrame) {
            _ = try assembler.accept(WebSocketFrame(opcode: .text, payload: [0x62]))
        }
    }

    @Test func enforcesTheMessageCapAcrossFragments() throws {
        var assembler = WebSocketMessageAssembler(maximumMessageSize: 8)
        _ = try assembler.accept(
            WebSocketFrame(isFinal: false, opcode: .binary, payload: [UInt8](repeating: 0, count: 5))
        )
        // Each fragment is under the cap; their sum is not.
        #expect(throws: WebSocketProtocolError.messageTooLarge(limit: 8)) {
            _ = try assembler.accept(
                WebSocketFrame(opcode: .continuation, payload: [UInt8](repeating: 0, count: 5))
            )
        }
    }

    @Test func rejectsInvalidUTF8InText() {
        var assembler = WebSocketMessageAssembler()
        #expect(throws: WebSocketProtocolError.invalidUTF8) {
            _ = try assembler.accept(WebSocketFrame(opcode: .text, payload: [0xFF, 0xFE]))
        }
    }

    @Test func readsCloseCodesAndReasons() throws {
        var assembler = WebSocketMessageAssembler()
        #expect(try assembler.accept(WebSocketFrame(opcode: .close, payload: []))
            == .close(code: nil, reason: ""))
        let payload = WebSocketMessageAssembler.closePayload(code: 1001, reason: "bye")
        #expect(try assembler.accept(WebSocketFrame(opcode: .close, payload: payload))
            == .close(code: 1001, reason: "bye"))
    }

    @Test func rejectsMalformedCloseFrames() {
        var assembler = WebSocketMessageAssembler()
        // A 1-byte close payload can never be a code.
        #expect(throws: WebSocketProtocolError.invalidClosePayload) {
            _ = try assembler.accept(WebSocketFrame(opcode: .close, payload: [0x03]))
        }
        // 1005/1006/1015 are reserved for local use and must not appear.
        for reserved: UInt16 in [1005, 1006, 1015, 999, 1016] {
            let bytes: [UInt8] = [UInt8(reserved >> 8), UInt8(reserved & 0xFF)]
            #expect(throws: WebSocketProtocolError.invalidClosePayload) {
                _ = try assembler.accept(WebSocketFrame(opcode: .close, payload: bytes))
            }
        }
    }

    @Test func truncatesALongCloseReasonToFitAControlFrame() {
        let payload = WebSocketMessageAssembler.closePayload(
            code: 1002,
            reason: String(repeating: "z", count: 400)
        )
        #expect(payload.count == 125)
    }
}
