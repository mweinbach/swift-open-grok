import Foundation
import OpenGrokAgentControlTools
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase

enum PreparedSessionCollaborationCall: Sendable {
    case listSessions
    case readSession(ReadSessionInput)
    case messageSession(MessageSessionInput)
}

enum LiveSessionCollaborationTools {
    private static let surface = SessionCollaborationToolSurface()

    static func toolSpecs(
        for tools: [SessionCollaborationTool] = SessionCollaborationTool.allCases
    ) -> [ToolSpec] {
        tools.map { tool in
            ToolSpec(
                name: tool.rawValue,
                description: tool.descriptionTemplate,
                parameters: SessionCollaborationToolSurface.inputSchema(for: tool)
            )
        }
    }

    static func prepare(
        name: String,
        arguments: JSONValue
    ) throws -> PreparedSessionCollaborationCall {
        guard let tool = SessionCollaborationTool(rawValue: name) else {
            throw SessionCollaborationPreparationError.unknownTool(name)
        }
        guard case .object = arguments else {
            throw SessionCollaborationPreparationError.invalidArguments(
                "\(name) arguments must be an object"
            )
        }

        switch tool {
        case .listSessions:
            return .listSessions
        case .readSession:
            let input: ReadSessionInput = try decode(arguments, toolName: name)
            return .readSession(try surface.validatedReadInput(input))
        case .messageSession:
            let input: MessageSessionInput = try decode(arguments, toolName: name)
            return .messageSession(try surface.validatedMessageInput(input))
        }
    }

    static func invoke(
        _ prepared: PreparedSessionCollaborationCall,
        backend: any SessionCollaborationBackend
    ) async -> Result<OpenGrokShellToolCallResult, OpenGrokShellToolRuntimeError> {
        do {
            switch prepared {
            case .listSessions:
                let output = try await surface.listSessions(backend: backend)
                return try result(output, promptText: serdeListSessionsJSON(output))
            case .readSession(let input):
                let output = try await surface.readSession(input: input, backend: backend)
                return try result(output, promptText: serdeReadSessionJSON(output))
            case .messageSession(let input):
                let output = try await surface.messageSession(input: input, backend: backend)
                return try result(output, promptText: serdeMessageSessionJSON(output))
            }
        } catch let error as SessionCollaborationError {
            return .failure(.invalidCall(error.description))
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(.failed(String(describing: error)))
        }
    }

    private static func decode<T: Decodable>(
        _ arguments: JSONValue,
        toolName: String
    ) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(arguments))
        } catch {
            throw SessionCollaborationPreparationError.invalidArguments(
                "\(toolName) arguments are invalid: \(error)"
            )
        }
    }

    private static func result(
        _ output: some Encodable,
        promptText: String
    ) throws -> Result<OpenGrokShellToolCallResult, OpenGrokShellToolRuntimeError> {
        let data = try JSONEncoder().encode(output)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        return .success(OpenGrokShellToolCallResult(value: value, promptText: promptText))
    }
}

enum SessionCollaborationPreparationError: Error, CustomStringConvertible {
    case unknownTool(String)
    case invalidArguments(String)

    var description: String {
        switch self {
        case .unknownTool(let name):
            return "unknown tool '\(name)'"
        case .invalidArguments(let message):
            return message
        }
    }
}

func serdeListSessionsJSON(_ output: ListSessionsOutput) -> String {
    var text = "{\n  \"bus_enabled\": \(output.busEnabled),\n  \"sessions\": "
    if output.sessions.isEmpty {
        text += "[]"
    } else {
        text += "[\n"
        text += output.sessions.map { serdeLiveSessionJSON($0, indent: "    ") }
            .joined(separator: ",\n")
        text += "\n  ]"
    }
    return text + "\n}"
}

private func serdeLiveSessionJSON(_ session: LiveSessionEntry, indent: String) -> String {
    let inner = indent + "  "
    var fields: [String] = [
        "\(inner)\"session_id\": \(serdeJSONStringLiteral(session.sessionID))",
        "\(inner)\"cwd\": \(serdeJSONStringLiteral(session.cwd))",
        "\(inner)\"project_name\": \(serdeJSONStringLiteral(session.projectName))",
    ]
    if let modelID = session.modelID {
        fields.append("\(inner)\"model_id\": \(serdeJSONStringLiteral(modelID))")
    }
    if let title = session.title {
        fields.append("\(inner)\"title\": \(serdeJSONStringLiteral(title))")
    }
    fields.append("\(inner)\"status\": \(serdeJSONStringLiteral(session.status))")
    fields.append("\(inner)\"is_self\": \(session.isSelf)")
    return indent + "{\n" + fields.joined(separator: ",\n") + "\n" + indent + "}"
}

func serdeReadSessionJSON(_ output: ReadSessionOutput) -> String {
    var fields: [String] = [
        "  \"session_id\": \(serdeJSONStringLiteral(output.sessionID))"
    ]
    if let title = output.title {
        fields.append("  \"title\": \(serdeJSONStringLiteral(title))")
    }
    fields.append("  \"live\": \(output.live)")
    if output.updates.isEmpty {
        fields.append("  \"updates\": []")
    } else {
        var updates = "  \"updates\": [\n"
        updates += output.updates.map { update in
            "    {\n"
                + "      \"role\": \(serdeJSONStringLiteral(update.role)),\n"
                + "      \"text\": \(serdeJSONStringLiteral(update.text))\n"
                + "    }"
        }.joined(separator: ",\n")
        fields.append(updates + "\n  ]")
    }
    return "{\n" + fields.joined(separator: ",\n") + "\n}"
}

func serdeMessageSessionJSON(_ output: MessageSessionOutput) -> String {
    "{\n"
        + "  \"target_session_id\": \(serdeJSONStringLiteral(output.targetSessionID)),\n"
        + "  \"status\": \(serdeJSONStringLiteral(output.status.rawValue))\n"
        + "}"
}
