import Foundation

public enum LSPError: Error, Sendable, Equatable {
    case transport(String)
    case transportClosed
    case parse(String)
    case methodNotFound(String)
    case timeout(method: String)
    case unsupported(String)
    case server(String)

    public var isMethodNotFound: Bool {
        if case .methodNotFound = self { return true }
        return false
    }
}

public enum LSPJSONRPCErrorCode {
    public static let parseError: Int = -32700
    public static let invalidRequest: Int = -32600
    public static let methodNotFound: Int = -32601
    public static let invalidParams: Int = -32602
    public static let internalError: Int = -32603
}
