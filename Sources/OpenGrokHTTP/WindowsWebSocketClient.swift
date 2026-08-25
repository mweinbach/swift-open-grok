#if os(Windows)

import COpenGrokSockets
import Foundation
import OpenGrokExtraCA

private enum WindowsWebSocketBlockingExecutor {
    static func run<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let worker = Thread {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            worker.name = "opengrok-winhttp-websocket"
            worker.start()
        }
    }
}

private final class WindowsWebSocketHandle: @unchecked Sendable {
    let value: Int64

    init(_ value: Int64) {
        self.value = value
    }

    deinit {
        og_windows_websocket_destroy(value)
    }
}

private struct WindowsWebSocketFragment: Sendable {
    let bytes: [UInt8]
    let kind: Int32
    let isFinal: Bool
}

enum WindowsWebSocketHandshakeHeaders {
    private static let reservedNames: Set<String> = [
        "connection",
        "content-length",
        "cookie",
        "host",
        "proxy-authenticate",
        "proxy-authorization",
        "sec-websocket-extensions",
        "sec-websocket-key",
        "sec-websocket-version",
        "set-cookie",
        "transfer-encoding",
        "upgrade",
    ]

    static func serialize(
        _ headers: [(String, String)],
        url: WebSocketURL
    ) throws -> String {
        var result = ""
        for (name, value) in headers {
            guard !name.isEmpty, name.utf8.allSatisfy(isTokenByte) else {
                throw WebSocketDialError.connectionFailed(
                    url: url.absoluteString,
                    reason: "WebSocket header name contains a prohibited character"
                )
            }
            guard !reservedNames.contains(name.lowercased()) else {
                throw WebSocketDialError.connectionFailed(
                    url: url.absoluteString,
                    reason: "WebSocket handshake cannot override a reserved header"
                )
            }
            guard value.utf8.allSatisfy({ $0 == 9 || (32...126).contains($0) }) else {
                throw WebSocketDialError.connectionFailed(
                    url: url.absoluteString,
                    reason: "WebSocket header value contains a prohibited character"
                )
            }
            result += name
            result += ": "
            result += value
            result += "\r\n"
            guard result.utf8.count <= WebSocketLimits.maximumHandshakeHeadSize else {
                throw WebSocketHandshakeError.headTooLarge(
                    limit: WebSocketLimits.maximumHandshakeHeadSize
                )
            }
        }
        return result
    }

    private static func isTokenByte(_ value: UInt8) -> Bool {
        switch value {
        case 48...57, 65...90, 97...122, 33, 35...39, 42, 43, 45, 46, 94...96, 124, 126:
            true
        default:
            false
        }
    }
}

/// Native WinHTTP WebSockets backed by Schannel and the Windows trust store.
///
/// WinHTTP owns its WebSocket ping scheduler and does not expose an API for an
/// immediate caller-triggered ping. The connection refuses to open unless its
/// automatic interval exactly matches upstream's 15-second keepalive; `ping()`
/// verifies that the scheduler remains armed instead of claiming to send a
/// control frame WinHTTP cannot represent.
public actor WindowsWebSocketClient: WebSocketClient {
    public let maximumMessageSize: Int

    static var nativeKeepaliveIntervalMilliseconds: Int {
        Int(og_windows_websocket_keepalive_interval_milliseconds())
    }

    private let native: WindowsWebSocketHandle
    private let endpoint: String
    private var closed = false
    private var receiving = false

    private init(handle: Int64, endpoint: String, maximumMessageSize: Int) {
        self.native = WindowsWebSocketHandle(handle)
        self.endpoint = endpoint
        self.maximumMessageSize = maximumMessageSize
    }

    public static func connect(
        to url: WebSocketURL,
        options: WebSocketDialOptions = WebSocketDialOptions(),
        extraRootCertificates: [Data] = OpenGrokExtraCA.processRootCertificates
    ) async throws -> WindowsWebSocketClient {
        guard og_windows_websocket_is_available() == 1 else {
            throw WebSocketDialError.unsupportedPlatform(
                "the Windows WinHTTP WebSocket backend is unavailable"
            )
        }
        guard options.connectTimeoutSeconds.isFinite, options.connectTimeoutSeconds > 0 else {
            throw WebSocketDialError.connectionFailed(
                url: url.absoluteString,
                reason: "WebSocket connection timeout must be positive and finite"
            )
        }
        guard options.maximumMessageSize > 0, options.maximumMessageSize <= Int(UInt32.max) else {
            throw WebSocketDialError.connectionFailed(
                url: url.absoluteString,
                reason: "WebSocket maximum message size is outside the supported range"
            )
        }
        // Rust applies enterprise roots to HTTP clients, not WebSocket dialers
        // (relay.rs:433); Schannel must retain its unmodified system trust.
        guard !url.host.isEmpty,
              url.host.utf8.allSatisfy({ (33...126).contains($0) }),
              url.target.hasPrefix("/"),
              url.target.utf8.allSatisfy({ (33...126).contains($0) })
        else {
            throw WebSocketDialError.connectionFailed(
                url: url.absoluteString,
                reason: "WebSocket endpoint contains a prohibited character"
            )
        }

        let headers = try WindowsWebSocketHandshakeHeaders.serialize(options.headers, url: url)
        let timeout = options.connectTimeoutSeconds
        let handle = try await WindowsWebSocketBlockingExecutor.run {
            var connected: Int64 = -1
            var status: Int32 = 0
            let result = url.host.withCString { host in
                url.target.withCString { target in
                    headers.withCString { headers in
                        og_windows_websocket_connect(
                            host,
                            url.port,
                            target,
                            headers,
                            url.isSecure ? 1 : 0,
                            timeout,
                            &connected,
                            &status
                        )
                    }
                }
            }
            guard result == 0 else {
                let timedOut = og_windows_websocket_last_error_is_timeout() != 0
                let reason = Self.lastNativeError()
                if timedOut {
                    throw WebSocketDialError.connectTimeout(
                        seconds: timeout,
                        url: url.absoluteString
                    )
                }
                if status > 0, status != 101 {
                    throw WebSocketChannelError.handshakeRejected(status: Int(status), body: "")
                }
                throw WebSocketDialError.connectionFailed(
                    url: url.absoluteString,
                    reason: reason
                )
            }
            return connected
        }
        return WindowsWebSocketClient(
            handle: handle,
            endpoint: url.absoluteString,
            maximumMessageSize: options.maximumMessageSize
        )
    }

    public func send(_ message: WebSocketMessage) async throws {
        guard !closed else { throw WebSocketChannelError.closed }

        let payload: [UInt8]
        let isText: Bool
        switch message {
        case .text(let value):
            payload = Array(value.utf8)
            isText = true
        case .data(let value):
            payload = Array(value)
            isText = false
        }
        guard payload.count <= maximumMessageSize else {
            throw WebSocketProtocolError.messageTooLarge(limit: maximumMessageSize)
        }

        let native = self.native
        try await WindowsWebSocketBlockingExecutor.run {
            let result = payload.withUnsafeBytes { bytes in
                og_windows_websocket_send(
                    native.value,
                    isText ? 1 : 0,
                    bytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    bytes.count
                )
            }
            guard result == 0 else { throw Self.operationFailure() }
        }
    }

    public func receive() async throws -> WebSocketMessage? {
        guard !closed else { return nil }
        guard !receiving else { throw WebSocketProtocolError.interleavedDataFrame }
        receiving = true
        defer { receiving = false }

        var assembled: [UInt8] = []
        var messageKind: Int32?

        while !closed {
            let remaining = maximumMessageSize - assembled.count
            let capacity = remaining >= 64 * 1024 ? 64 * 1024 : remaining + 1
            let native = self.native
            let fragment = try await WindowsWebSocketBlockingExecutor.run {
                var buffer = [UInt8](repeating: 0, count: capacity)
                var bytesRead = 0
                var kind: Int32 = 0
                var finished: Int32 = 0
                let result = buffer.withUnsafeMutableBytes { bytes in
                    og_windows_websocket_receive(
                        native.value,
                        bytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        bytes.count,
                        &bytesRead,
                        &kind,
                        &finished
                    )
                }
                guard result == 0 else { throw Self.operationFailure() }
                return WindowsWebSocketFragment(
                    bytes: Array(buffer.prefix(bytesRead)),
                    kind: kind,
                    isFinal: finished != 0
                )
            }

            if fragment.kind == 0 {
                await close(code: 1000, reason: "")
                return nil
            }
            guard fragment.kind == 1 || fragment.kind == 2 else {
                let error = WebSocketProtocolError.unknownOpcode(UInt8(clamping: fragment.kind))
                await close(code: error.closeCode, reason: error.description)
                throw error
            }
            if let messageKind, messageKind != fragment.kind {
                let error = WebSocketProtocolError.interleavedDataFrame
                await close(code: error.closeCode, reason: error.description)
                throw error
            }
            messageKind = fragment.kind
            assembled.append(contentsOf: fragment.bytes)
            guard assembled.count <= maximumMessageSize else {
                let error = WebSocketProtocolError.messageTooLarge(limit: maximumMessageSize)
                await close(code: error.closeCode, reason: error.description)
                throw error
            }
            guard fragment.isFinal else {
                try Task.checkCancellation()
                continue
            }

            if fragment.kind == 2 { return .data(Data(assembled)) }
            guard let text = String(bytes: assembled, encoding: .utf8) else {
                let error = WebSocketProtocolError.invalidUTF8
                await close(code: error.closeCode, reason: error.description)
                throw error
            }
            return .text(text)
        }
        return nil
    }

    public func ping() async throws {
        guard !closed else { throw WebSocketChannelError.closed }
        let native = self.native
        try await WindowsWebSocketBlockingExecutor.run {
            guard og_windows_websocket_verify_keepalive(native.value) == 0 else {
                throw Self.operationFailure()
            }
        }
    }

    public func close(code: UInt16, reason: String) async {
        guard !closed else { return }
        closed = true
        let native = self.native
        var truncatedReason = Array(reason.utf8.prefix(123))
        while String(bytes: truncatedReason, encoding: .utf8) == nil {
            truncatedReason.removeLast()
        }
        let boundedReason = truncatedReason

        do {
            try await WindowsWebSocketBlockingExecutor.run {
                let result = boundedReason.withUnsafeBytes { bytes in
                    og_windows_websocket_close(
                        native.value,
                        code,
                        bytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        bytes.count
                    )
                }
                guard result == 0 else { throw Self.operationFailure() }
            }
        } catch {
            // WebSocketClient.close cannot throw. Native ownership still closes
            // all WinHTTP handles when the final in-flight operation releases it.
        }
    }

    private nonisolated static func lastNativeError() -> String {
        guard let value = og_windows_websocket_last_error_message() else {
            return "unknown WinHTTP WebSocket failure"
        }
        let message = String(cString: value)
        return message.isEmpty ? "unknown WinHTTP WebSocket failure" : message
    }

    private nonisolated static func operationFailure() -> HTTPError {
        .transport(TransportFailure(kind: .interrupted, detail: lastNativeError()))
    }
}

#endif
