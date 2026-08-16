import Foundation
import OpenGrokACP
import OpenGrokHTTP
import OpenGrokShared

public enum ACPTransportError: Error, Hashable, Sendable, CustomStringConvertible {
    case closed
    case invalidLine
    case invalidMessage(String)
    case unsupportedPayload

    public var description: String {
        switch self {
        case .closed: return "ACP transport is closed"
        case .invalidLine: return "ACP transport received an empty line"
        case .invalidMessage(let message): return "invalid ACP message: \(message)"
        case .unsupportedPayload: return "ACP transport received an unsupported payload"
        }
    }
}

public enum ACPMessage: Hashable, Sendable, Codable {
    case request(id: AcpRequestId, method: String, params: JSONValue)
    case notification(method: String, params: JSONValue)
    case response(id: AcpRequestId, result: JSONValue?, error: AcpError?)

    public init(from decoder: Decoder) throws {
        try self.init(json: JSONValue(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try json.encode(to: encoder)
    }

    public init(json: JSONValue) throws {
        guard case .object(let object) = json else {
            throw ACPTransportError.invalidMessage("message must be an object")
        }
        if let jsonrpc = object["jsonrpc"], jsonrpc != .string("2.0") {
            throw ACPTransportError.invalidMessage("jsonrpc must be 2.0")
        }
        if let methodValue = object["method"] {
            guard case .string(let method) = methodValue, !method.isEmpty else {
                throw ACPTransportError.invalidMessage("method must be a non-empty string")
            }
            let params = object["params"] ?? .object([:])
            if let idValue = object["id"] {
                self = .request(id: try idValue.decode(AcpRequestId.self), method: method, params: params)
            } else {
                self = .notification(method: method, params: params)
            }
            return
        }
        guard let idValue = object["id"], object["result"] != nil || object["error"] != nil else {
            throw ACPTransportError.invalidMessage("message must contain method or response")
        }
        let error = try object["error"]?.decode(AcpError.self)
        self = .response(
            id: try idValue.decode(AcpRequestId.self),
            result: object["result"],
            error: error
        )
    }

    public var json: JSONValue {
        switch self {
        case .request(let id, let method, let params):
            return .object([
                "jsonrpc": .string("2.0"),
                "id": Self.encode(id),
                "method": .string(method),
                "params": params,
            ])
        case .notification(let method, let params):
            return .object([
                "jsonrpc": .string("2.0"),
                "method": .string(method),
                "params": params,
            ])
        case .response(let id, let result, let error):
            var object: [String: JSONValue] = [
                "jsonrpc": .string("2.0"),
                "id": Self.encode(id),
            ]
            if let result { object["result"] = result }
            if let error { object["error"] = (try? JSONValue.encode(error)) ?? .object([:]) }
            if result == nil, error == nil { object["result"] = .object([:]) }
            return .object(object)
        }
    }

    public var method: String? {
        switch self {
        case .request(_, let method, _), .notification(let method, _): return method
        case .response: return nil
        }
    }

    public var id: AcpRequestId? {
        switch self {
        case .request(let id, _, _), .response(let id, _, _): return id
        case .notification: return nil
        }
    }

    public var params: JSONValue? {
        switch self {
        case .request(_, _, let params), .notification(_, let params): return params
        case .response: return nil
        }
    }

    public func encodedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public init(data: Data) throws {
        do {
            self = try JSONDecoder().decode(ACPMessage.self, from: data)
        } catch let error as ACPTransportError {
            throw error
        } catch {
            throw ACPTransportError.invalidMessage(String(describing: error))
        }
    }

    private static func encode(_ id: AcpRequestId) -> JSONValue {
        switch id {
        case .null: return .null
        case .number(let number): return .number(.int64(number))
        case .string(let string): return .string(string)
        }
    }
}

public struct ACPMethodRoute: Hashable, Sendable {
    public var method: String
    public var params: JSONValue
    public var wasWrapped: Bool

    public init(method: String, params: JSONValue, wasWrapped: Bool = false) {
        self.method = method
        self.params = params
        self.wasWrapped = wasWrapped
    }

    public static func normalize(method: String, params: JSONValue) -> ACPMethodRoute {
        guard method.hasPrefix("_x.ai/"), case .object(let object) = params,
              case .string(let innerMethod) = object["method"] else {
            return ACPMethodRoute(method: method, params: params)
        }
        return ACPMethodRoute(
            method: innerMethod,
            params: object["params"] ?? .object([:]),
            wasWrapped: true
        )
    }
}

public protocol ACPTransport: Sendable {
    func send(_ message: ACPMessage) async throws
    func receive() async throws -> ACPMessage
    func close() async
}

private actor ACPMailbox {
    private var values: [ACPMessage] = []
    private var waiters: [CheckedContinuation<ACPMessage, Error>] = []
    private var closed = false

    func send(_ value: ACPMessage) {
        guard !closed else { return }
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume(returning: value)
        } else {
            values.append(value)
        }
    }

    func receive() async throws -> ACPMessage {
        if let value = values.first {
            values.removeFirst()
            return value
        }
        if closed { throw ACPTransportError.closed }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    func close() {
        guard !closed else { return }
        closed = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(throwing: ACPTransportError.closed) }
    }
}

public struct InProcessACPTransport: ACPTransport {
    private let inbound: ACPMailbox
    private let outbound: ACPMailbox

    private init(inbound: ACPMailbox, outbound: ACPMailbox) {
        self.inbound = inbound
        self.outbound = outbound
    }

    public static func makePair() -> (client: InProcessACPTransport, agent: InProcessACPTransport) {
        let clientInbound = ACPMailbox()
        let agentInbound = ACPMailbox()
        return (
            InProcessACPTransport(inbound: clientInbound, outbound: agentInbound),
            InProcessACPTransport(inbound: agentInbound, outbound: clientInbound)
        )
    }

    public func send(_ message: ACPMessage) async throws { await outbound.send(message) }
    public func receive() async throws -> ACPMessage { try await inbound.receive() }
    public func close() async {
        await inbound.close()
        await outbound.close()
    }
}

public protocol ACPLineIO: Sendable {
    func readLine() async throws -> String?
    func writeLine(_ line: String) async throws
    func close() async
}

public struct ClosureACPLineIO: ACPLineIO {
    private let reader: @Sendable () async throws -> String?
    private let writer: @Sendable (String) async throws -> Void
    private let closer: @Sendable () async -> Void

    public init(
        readLine: @escaping @Sendable () async throws -> String?,
        writeLine: @escaping @Sendable (String) async throws -> Void,
        close: @escaping @Sendable () async -> Void = {}
    ) {
        reader = readLine
        writer = writeLine
        closer = close
    }

    public func readLine() async throws -> String? { try await reader() }
    public func writeLine(_ line: String) async throws { try await writer(line) }
    public func close() async { await closer() }
}

public struct ACPStdioTransport: ACPTransport {
    private let io: any ACPLineIO

    public init(io: any ACPLineIO) { self.io = io }

    public func send(_ message: ACPMessage) async throws {
        guard let line = String(data: try message.encodedData(), encoding: .utf8) else {
            throw ACPTransportError.unsupportedPayload
        }
        try await io.writeLine(line)
    }

    public func receive() async throws -> ACPMessage {
        guard let line = try await io.readLine() else { throw ACPTransportError.closed }
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ACPTransportError.invalidLine
        }
        guard let data = line.data(using: .utf8) else { throw ACPTransportError.unsupportedPayload }
        return try ACPMessage(data: data)
    }

    public func close() async { await io.close() }
}

public struct ACPWebSocketTransport: ACPTransport {
    private let client: any WebSocketClient

    public init(client: any WebSocketClient) { self.client = client }

    public func send(_ message: ACPMessage) async throws {
        let data = try message.encodedData()
        try await client.send(.text(String(decoding: data, as: UTF8.self)))
    }

    public func receive() async throws -> ACPMessage {
        guard let message = try await client.receive() else {
            throw ACPTransportError.closed
        }
        switch message {
        case .text(let text):
            guard let data = text.data(using: .utf8) else { throw ACPTransportError.unsupportedPayload }
            return try ACPMessage(data: data)
        case .data(let data):
            return try ACPMessage(data: data)
        }
    }

    public func close() async {
        await client.close(code: 1000, reason: "ACP runtime closed")
    }
}
