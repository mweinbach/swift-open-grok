import Foundation
import OpenGrokShared

public struct LSPJSONRPCRequest: Sendable {
    public var id: Int
    public var method: String
    public var params: JSONValue?

    public init(id: Int, method: String, params: JSONValue? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }

    public func encoded() throws -> Data {
        var object: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .number(.int64(Int64(id))),
            "method": .string(method),
        ]
        if let params {
            object["params"] = params
        }
        return try JSONEncoder().encode(JSONValue.object(object))
    }
}

public struct LSPJSONRPCNotification: Sendable {
    public var method: String
    public var params: JSONValue?

    public init(method: String, params: JSONValue? = nil) {
        self.method = method
        self.params = params
    }

    public func encoded() throws -> Data {
        var object: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "method": .string(method),
        ]
        if let params {
            object["params"] = params
        }
        return try JSONEncoder().encode(JSONValue.object(object))
    }
}

public enum LSPJSONRPCResponse: Sendable {
    case result(id: Int, value: JSONValue)
    case error(id: Int?, code: Int, message: String)

    public static func decode(from data: Data) throws -> LSPJSONRPCResponse {
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .object(let object) = value else {
            throw LSPError.parse("LSP message is not a JSON object")
        }
        if let errorValue = object["error"], case .object(let errorObject) = errorValue {
            let codeValue = errorObject["code"]
            let code = Int(codeValue?.int64Value ?? Int64(codeValue?.doubleValue ?? 0))
            let message = errorObject["message"]?.stringValue ?? "unknown LSP error"
            let id: Int?
            if let idNumber = object["id"]?.int64Value {
                id = Int(idNumber)
            } else if let idNumber = object["id"]?.doubleValue {
                id = Int(idNumber)
            } else {
                id = nil
            }
            return .error(id: id, code: code, message: message)
        }
        let idNumber: Int
        if let value = object["id"]?.int64Value {
            idNumber = Int(value)
        } else if let value = object["id"]?.doubleValue {
            idNumber = Int(value)
        } else {
            throw LSPError.parse("LSP response missing id")
        }
        guard let result = object["result"] else {
            throw LSPError.parse("LSP response missing result")
        }
        return .result(id: idNumber, value: result)
    }
}

public enum LSPMessageFraming {
    public static func encode(_ body: Data) -> Data {
        let header = "Content-Length: \(body.count)\r\n\r\n"
        var packet = Data(header.utf8)
        packet.append(body)
        return packet
    }

    /// Extract one complete LSP packet from `buffer`, mutating it in place.
    public static func takeMessage(from buffer: inout Data) -> Data? {
        while true {
            guard let headerEnd = headerBoundary(in: buffer) else { return nil }
            let headerData = buffer[..<headerEnd]
            guard let headerText = String(data: headerData, encoding: .utf8) else {
                buffer.removeAll(keepingCapacity: false)
                return nil
            }
            guard let contentLength = parseContentLength(headerText) else {
                buffer.removeAll(keepingCapacity: false)
                return nil
            }
            let bodyStart = headerEnd + headerSeparatorLength(in: buffer, headerEnd: headerEnd)
            let totalNeeded = bodyStart + contentLength
            guard buffer.count >= totalNeeded else { return nil }
            let body = buffer[bodyStart..<(bodyStart + contentLength)]
            buffer.removeSubrange(..<totalNeeded)
            return Data(body)
        }
    }

    private static func headerBoundary(in buffer: Data) -> Int? {
        if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
            return range.lowerBound
        }
        if let range = buffer.range(of: Data("\n\n".utf8)) {
            return range.lowerBound
        }
        return nil
    }

    private static func headerSeparatorLength(in buffer: Data, headerEnd: Int) -> Int {
        if buffer.count >= headerEnd + 4,
           buffer[headerEnd] == UInt8(ascii: "\r"),
           buffer[headerEnd + 1] == UInt8(ascii: "\n"),
           buffer[headerEnd + 2] == UInt8(ascii: "\r"),
           buffer[headerEnd + 3] == UInt8(ascii: "\n") {
            return 4
        }
        return 2
    }

    private static func parseContentLength(_ header: String) -> Int? {
        for line in header.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.lowercased().hasPrefix("content-length:") else { continue }
            let value = trimmed.dropFirst("content-length:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Int(value)
        }
        return nil
    }
}
