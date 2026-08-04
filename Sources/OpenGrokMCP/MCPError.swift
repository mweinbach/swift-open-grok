import Foundation
import OpenGrokHTTP
import OpenGrokShared
import OpenGrokToolProtocol

public enum MCPJSONRPCErrorCode {
    public static let parseError: Int32 = -32700
    public static let invalidRequest: Int32 = -32600
    public static let methodNotFound: Int32 = -32601
    public static let invalidParams: Int32 = -32602
    public static let internalError: Int32 = -32603

    public static let notInitialized: Int32 = -32000
    public static let alreadyInitialized: Int32 = -32001
    public static let cancelled: Int32 = -32002
    public static let timeout: Int32 = -32003
    public static let transportClosed: Int32 = -32004
    public static let transport: Int32 = -32005
    public static let toolNotFound: Int32 = -32011
    public static let resourceNotFound: Int32 = -32012
    public static let promptNotFound: Int32 = -32013
    public static let capabilityUnsupported: Int32 = -32014
}

public enum MCPError: Error, Sendable, Hashable, Equatable, CustomStringConvertible {
    case parse(String)
    case invalidRequest(String)
    case methodNotFound(String)
    case invalidParams(String)
    case internalError(String)
    case notInitialized
    case alreadyInitialized
    case cancelled(requestID: JsonRpcId, reason: String?)
    case timeout(method: String)
    case transportClosed
    case transport(String)
    case toolNotFound(String)
    case resourceNotFound(String)
    case promptNotFound(String)
    case capabilityUnsupported(String)
    case server(code: Int32, message: String, data: JSONValue?)

    public var description: String {
        switch self {
        case .parse(let detail): return "parse error: \(detail)"
        case .invalidRequest(let detail): return "invalid request: \(detail)"
        case .methodNotFound(let method): return "method not found: \(method)"
        case .invalidParams(let detail): return "invalid params: \(detail)"
        case .internalError(let detail): return "internal error: \(detail)"
        case .notInitialized: return "MCP session is not initialized"
        case .alreadyInitialized: return "MCP session is already initialized"
        case .cancelled(_, let reason): return reason.map { "request cancelled: \($0)" } ?? "request cancelled"
        case .timeout(let method): return "request timed out: \(method)"
        case .transportClosed: return "MCP transport closed"
        case .transport(let detail): return "MCP transport error: \(detail)"
        case .toolNotFound(let name): return "tool not found: \(name)"
        case .resourceNotFound(let uri): return "resource not found: \(uri)"
        case .promptNotFound(let name): return "prompt not found: \(name)"
        case .capabilityUnsupported(let capability): return "MCP capability unsupported: \(capability)"
        case .server(_, let message, _): return message
        }
    }

    public var code: Int32 {
        switch self {
        case .parse: return MCPJSONRPCErrorCode.parseError
        case .invalidRequest: return MCPJSONRPCErrorCode.invalidRequest
        case .methodNotFound: return MCPJSONRPCErrorCode.methodNotFound
        case .invalidParams: return MCPJSONRPCErrorCode.invalidParams
        case .internalError: return MCPJSONRPCErrorCode.internalError
        case .notInitialized: return MCPJSONRPCErrorCode.notInitialized
        case .alreadyInitialized: return MCPJSONRPCErrorCode.alreadyInitialized
        case .cancelled: return MCPJSONRPCErrorCode.cancelled
        case .timeout: return MCPJSONRPCErrorCode.timeout
        case .transportClosed: return MCPJSONRPCErrorCode.transportClosed
        case .transport: return MCPJSONRPCErrorCode.transport
        case .toolNotFound: return MCPJSONRPCErrorCode.toolNotFound
        case .resourceNotFound: return MCPJSONRPCErrorCode.resourceNotFound
        case .promptNotFound: return MCPJSONRPCErrorCode.promptNotFound
        case .capabilityUnsupported: return MCPJSONRPCErrorCode.capabilityUnsupported
        case .server(let code, _, _): return code
        }
    }

    public func jsonRPCError() -> JsonRpcError {
        let data: JSONValue?
        switch self {
        case .parse(let detail):
            data = details(subcode: "parse_error", detail: detail)
        case .invalidRequest(let detail):
            data = details(subcode: "invalid_request", detail: detail)
        case .methodNotFound(let method):
            data = details(subcode: "method_not_found", detail: method)
        case .invalidParams(let detail):
            data = details(subcode: "invalid_params", detail: detail)
        case .internalError(let detail):
            data = details(subcode: "internal_error", detail: detail)
        case .notInitialized:
            data = details(subcode: "not_initialized", detail: nil)
        case .alreadyInitialized:
            data = details(subcode: "already_initialized", detail: nil)
        case .cancelled(let requestID, let reason):
            var values: [String: JSONValue] = [
                "subcode": .string("cancelled"),
                "request_id": rpcIDValue(requestID),
            ]
            if let reason { values["reason"] = .string(reason) }
            data = .object(values)
        case .timeout(let method):
            data = details(subcode: "timeout", detail: method)
        case .transportClosed:
            data = details(subcode: "transport_closed", detail: nil)
        case .transport(let detail):
            data = details(subcode: "transport", detail: detail)
        case .toolNotFound(let name):
            data = details(subcode: "tool_not_found", detail: name)
        case .resourceNotFound(let uri):
            data = details(subcode: "resource_not_found", detail: uri)
        case .promptNotFound(let name):
            data = details(subcode: "prompt_not_found", detail: name)
        case .capabilityUnsupported(let capability):
            data = details(subcode: "capability_unsupported", detail: capability)
        case .server(_, _, let serverData):
            data = serverData
        }

        return JsonRpcError(code: code, message: wireMessage, data: data)
    }

    public static func from(_ error: JsonRpcError, method: String? = nil) -> MCPError {
        let subcode = error.data?["subcode"]?.stringValue
        switch subcode {
        case "parse_error": return .parse(error.data?["detail"]?.stringValue ?? error.message)
        case "invalid_request": return .invalidRequest(error.data?["detail"]?.stringValue ?? error.message)
        case "method_not_found": return .methodNotFound(error.data?["detail"]?.stringValue ?? error.message)
        case "invalid_params": return .invalidParams(error.data?["detail"]?.stringValue ?? error.message)
        case "internal_error": return .internalError(error.data?["detail"]?.stringValue ?? error.message)
        case "not_initialized": return .notInitialized
        case "already_initialized": return .alreadyInitialized
        case "cancelled":
            let requestID = error.data?["request_id"].flatMap { try? $0.decode(JsonRpcId.self) } ?? .string("")
            return .cancelled(requestID: requestID, reason: error.data?["reason"]?.stringValue)
        case "timeout": return .timeout(method: error.data?["detail"]?.stringValue ?? method ?? "")
        case "transport_closed": return .transportClosed
        case "transport": return .transport(error.data?["detail"]?.stringValue ?? error.message)
        case "tool_not_found": return .toolNotFound(error.data?["detail"]?.stringValue ?? "")
        case "resource_not_found": return .resourceNotFound(error.data?["detail"]?.stringValue ?? "")
        case "prompt_not_found": return .promptNotFound(error.data?["detail"]?.stringValue ?? "")
        case "capability_unsupported": return .capabilityUnsupported(error.data?["detail"]?.stringValue ?? "")
        default: break
        }

        switch error.code {
        case MCPJSONRPCErrorCode.parseError: return .parse(error.message)
        case MCPJSONRPCErrorCode.invalidRequest: return .invalidRequest(error.message)
        case MCPJSONRPCErrorCode.methodNotFound: return .methodNotFound(error.message)
        case MCPJSONRPCErrorCode.invalidParams: return .invalidParams(error.message)
        case MCPJSONRPCErrorCode.internalError: return .internalError(error.message)
        case MCPJSONRPCErrorCode.notInitialized: return .notInitialized
        case MCPJSONRPCErrorCode.alreadyInitialized: return .alreadyInitialized
        case MCPJSONRPCErrorCode.cancelled: return .cancelled(requestID: .string(""), reason: error.message)
        case MCPJSONRPCErrorCode.timeout: return .timeout(method: method ?? error.message)
        case MCPJSONRPCErrorCode.transportClosed: return .transportClosed
        case MCPJSONRPCErrorCode.transport: return .transport(error.message)
        case MCPJSONRPCErrorCode.toolNotFound: return .toolNotFound(error.message)
        case MCPJSONRPCErrorCode.resourceNotFound: return .resourceNotFound(error.message)
        case MCPJSONRPCErrorCode.promptNotFound: return .promptNotFound(error.message)
        case MCPJSONRPCErrorCode.capabilityUnsupported: return .capabilityUnsupported(error.message)
        default: return .server(code: error.code, message: error.message, data: error.data)
        }
    }

    fileprivate var wireMessage: String {
        switch self {
        case .parse: return "Parse error"
        case .invalidRequest: return "Invalid Request"
        case .methodNotFound: return "Method not found"
        case .invalidParams: return "Invalid params"
        case .internalError: return "Internal error"
        case .notInitialized: return "MCP session is not initialized"
        case .alreadyInitialized: return "MCP session is already initialized"
        case .cancelled: return "Request cancelled"
        case .timeout: return "Request timed out"
        case .transportClosed: return "MCP transport closed"
        case .transport: return "MCP transport error"
        case .toolNotFound: return "Tool not found"
        case .resourceNotFound: return "Resource not found"
        case .promptNotFound: return "Prompt not found"
        case .capabilityUnsupported: return "Capability unsupported"
        case .server(_, let message, _): return message
        }
    }

    private func details(subcode: String, detail: String?) -> JSONValue {
        var values: [String: JSONValue] = ["subcode": .string(subcode)]
        if let detail { values["detail"] = .string(detail) }
        return .object(values)
    }
}

private func rpcIDValue(_ value: JsonRpcId) -> JSONValue {
    switch value {
    case .string(let string): return .string(string)
    case .number(let number): return .number(.int64(number))
    }
}

public func mcpError(from error: Error, method: String? = nil) -> MCPError {
    if let error = error as? MCPError { return error }
    if error is CancellationError { return .cancelled(requestID: .string(""), reason: "cancelled") }
    if let error = error as? HTTPError {
        switch error {
        case .cancelled: return .cancelled(requestID: .string(""), reason: "cancelled")
        case .webSocketClosed(_, _), .transport, .unexpectedStatus, .invalidURL, .bufferExceeded, .webSocketUnsupported:
            return .transport(error.description)
        }
    }
    return .internalError(method.map { "\($0): \(error)" } ?? String(describing: error))
}

public func mcpJSONValue<T: Encodable>(_ value: T) throws -> JSONValue {
    try JSONValue.encode(value)
}
