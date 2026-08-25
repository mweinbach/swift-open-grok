import Foundation
import OpenGrokLSP
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRegistry
import OpenGrokToolRuntime
import OpenGrokToolTypes

enum LiveLSPSemanticTools {
    static let toolName = "lsp"

    static let description = """
    Code intelligence via language servers. Operations: goToDefinition (jump to where a \
    symbol is defined), findReferences (all usages of a symbol), hover (type info/docs at \
    a position), goToImplementation (trait/interface implementations), documentSymbol \
    (list all symbols in a file), workspaceSymbol (search symbols by name across the \
    workspace — requires query parameter, not file_path). Requires file_path + line + \
    character for position-based operations.
    """

    static var inputSchema: JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "operation": .object([
                    "type": .string("string"),
                    "enum": .array(LSPSemanticOperation.allCases.map { .string($0.rawValue) }),
                    "description": .string("The LSP operation to perform."),
                ]),
                "file_path": .object([
                    "type": .string("string"),
                    "description": .string("Absolute or workspace-relative path to the file."),
                ]),
                "line": .object([
                    "type": .string("integer"),
                    "minimum": .number(.int64(0)),
                    "description": .string("0-indexed line number."),
                ]),
                "character": .object([
                    "type": .string("integer"),
                    "minimum": .number(.int64(0)),
                    "description": .string("0-indexed UTF-16 character offset."),
                ]),
                "query": .object([
                    "type": .string("string"),
                    "description": .string("Symbol name or partial name (workspaceSymbol only)."),
                ]),
            ]),
            "required": .array([.string("operation")]),
            "additionalProperties": .bool(false),
        ])
    }

    static func register(into toolset: FinalizedToolset, session: LSPSession) {
        let definition = ToolDescription(name: toolName, description: description)
            .withKind(ProductToolKind.lsp.rawValue)
            .withNamespace(ProductToolNamespace.grokBuild.rawValue)
            .withArgumentsSchema(inputSchema)
        toolset.registerDynamic(FinalizedTool(
            qualifiedId: "GrokBuild:\(toolName)",
            namespace: .grokBuild,
            id: toolName,
            clientName: toolName,
            kind: .lsp,
            description: description,
            definition: definition,
            inputSchema: inputSchema,
            reverseParams: [:],
            contractVersion: nil,
            visibility: .topLevel,
            exposure: .ordinary,
            handler: LiveLSPSemanticToolHandler(session: session)
        ))
    }
}

private struct LiveLSPSemanticToolHandler: ToolHandler {
    let session: LSPSession

    func invoke(
        clientName: String,
        args: JSONValue,
        ctx: ToolCallContext,
        resources: ToolResources
    ) async -> Result<TypedToolOutput, ToolError> {
        _ = resources
        guard let toolID = try? ToolId(clientName) else {
            return .failure(.custom(code: "process_manager", detail: "invalid LSP tool id"))
        }
        guard case .object(let fields) = args,
              let name = fields["operation"]?.stringValue,
              let operation = LSPSemanticOperation(rawValue: name)
        else {
            return .failure(.invalidArguments("lsp requires a supported operation"))
        }

        let line: Int?
        let character: Int?
        do {
            line = try optionalOffset(fields["line"], name: "line")
            character = try optionalOffset(fields["character"], name: "character")
        } catch let error as LSPSemanticError {
            return .failure(.invalidArguments(error.description))
        } catch {
            return .failure(.invalidArguments("invalid LSP position"))
        }

        let input = LSPSemanticInput(
            operation: operation,
            filePath: fields["file_path"]?.stringValue,
            line: line,
            character: character,
            query: fields["query"]?.stringValue
        )
        let cancellation = ctx.get(Cancellation.self)
        guard cancellation?.isCancelled != true, !Task.isCancelled else {
            return .failure(.cancelled(toolId: toolID, detail: "LSP request cancelled."))
        }

        let request = Task { try await session.dispatchSemantic(input) }
        let watcher: Task<Void, Never>?
        if let cancellation {
            watcher = Task {
                await cancellation.waitUntilCancelled()
                if cancellation.isCancelled {
                    request.cancel()
                }
            }
        } else {
            watcher = nil
        }
        defer { watcher?.cancel() }

        do {
            let text = try await request.value
            guard cancellation?.isCancelled != true else {
                return .failure(.cancelled(toolId: toolID, detail: "LSP request cancelled."))
            }
            return .success(TypedToolOutput(
                toolId: toolID,
                value: .object(["content": .string(text)]),
                modelOutput: [.text(text: text)]
            ))
        } catch is CancellationError {
            return .failure(.cancelled(toolId: toolID, detail: "LSP request cancelled."))
        } catch let error as LSPSemanticError {
            switch error {
            case .invalidArguments:
                return .failure(.invalidArguments(error.description))
            case .workspaceEscape:
                return .failure(.permissionDenied(error.description))
            case .unavailable, .unsupported, .invalidResponse:
                return .failure(.custom(code: "process_manager", detail: error.description))
            }
        } catch let error as LSPError {
            if case .timeout(let method) = error {
                return .failure(.timeout(
                    toolId: toolID,
                    detail: "LSP request \(method) timed out."
                ))
            }
            return .failure(.custom(code: "process_manager", detail: "LSP error: \(error)"))
        } catch {
            return .failure(.custom(code: "process_manager", detail: "LSP error: \(error)"))
        }
    }

    private func optionalOffset(_ value: JSONValue?, name: String) throws -> Int? {
        guard let value else { return nil }
        guard let number = value.int64Value,
              number >= 0,
              number <= Int64(Int.max)
        else {
            throw LSPSemanticError.invalidArguments(
                "LSP \(name) must be a non-negative integer."
            )
        }
        return Int(number)
    }
}
