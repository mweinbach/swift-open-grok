import Foundation
import OpenGrokShared

public enum PullDiagnostics {
    public static let requestTimeout: TimeInterval = 10

    /// One `textDocument/diagnostic` round trip. Updates the support flag from
    /// what the server does, but writes no diagnostics — that is the caller's job.
    ///
    /// Rust reference: `pull.rs:371-437`.
    public static func request(
        client: LSPStdioClient,
        uri: String,
        previousResultID: String?,
        support: PullSupportFlag
    ) async -> PullOutcome {
        guard support.get() == .asking else {
            return .unsupported
        }

        var params: [String: JSONValue] = [
            "textDocument": .object([
                "uri": .string(uri),
            ]),
        ]
        if let previousResultID {
            params["previousResultId"] = .string(previousResultID)
        }

        do {
            let result = try await client.request(
                method: "textDocument/diagnostic",
                params: .object(params)
            )
            return parseReport(result)
        } catch let error as LSPError {
            switch error {
            case .methodNotFound:
                support.writeOff()
                return .unsupported
            case .timeout:
                return .failed("diagnostic pull timed out")
            default:
                return .failed(String(describing: error))
            }
        } catch {
            return .failed(String(describing: error))
        }
    }

    static func parseReport(_ value: JSONValue) -> PullOutcome {
        let report: JSONValue
        switch value {
        case .object(let object) where object["kind"] != nil:
            report = value
        case .object(let wrapper) where wrapper["fullDocumentDiagnosticReport"] != nil:
            report = wrapper["fullDocumentDiagnosticReport"] ?? value
        default:
            return .failed("unexpected diagnostic pull response shape")
        }

        guard case .object(let object) = report else {
            return .failed("unexpected diagnostic pull response shape")
        }

        if case .string("unchanged") = object["kind"] {
            let resultID: String?
            if case .string(let id)? = object["resultId"] {
                resultID = id
            } else {
                resultID = nil
            }
            return .clean(resultID: resultID)
        }

        let resultID: String?
        if case .string(let id)? = object["resultId"] {
            resultID = id
        } else {
            resultID = nil
        }

        let items = parseDiagnostics(object["items"])
        if items.isEmpty {
            return .clean(resultID: resultID)
        }
        return .reported(items: items, resultID: resultID)
    }

    static func parseDiagnostics(_ value: JSONValue?) -> [LSPDiagnostic] {
        guard case .array(let entries)? = value else { return [] }
        return entries.compactMap(parseDiagnostic)
    }

    static func parseDiagnostic(_ value: JSONValue) -> LSPDiagnostic? {
        guard case .object(let object) = value else { return nil }
        let message: String
        if case .string(let text)? = object["message"] {
            message = text
        } else {
            return nil
        }
        let severity: Int?
        if let value = object["severity"]?.int64Value {
            severity = Int(value)
        } else if let value = object["severity"]?.doubleValue {
            severity = Int(value)
        } else {
            severity = nil
        }
        let source: String?
        if case .string(let text)? = object["source"] {
            source = text
        } else {
            source = nil
        }
        var line = 0
        var character = 0
        if case .object(let range)? = object["range"],
           case .object(let start)? = range["start"] {
            if let value = start["line"]?.int64Value { line = Int(value) }
            else if let value = start["line"]?.doubleValue { line = Int(value) }
            if let value = start["character"]?.int64Value { character = Int(value) }
            else if let value = start["character"]?.doubleValue { character = Int(value) }
        }
        return LSPDiagnostic(
            message: message,
            severity: severity,
            line: line,
            character: character,
            source: source
        )
    }
}
