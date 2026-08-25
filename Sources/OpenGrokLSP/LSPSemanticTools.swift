import Foundation
import OpenGrokShared

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The single upstream `lsp` tool multiplexes these six exact camel-case operations.
public enum LSPSemanticOperation: String, CaseIterable, Sendable, Codable {
    case goToDefinition
    case findReferences
    case hover
    case goToImplementation
    case documentSymbol
    case workspaceSymbol

    var requestMethod: String {
        switch self {
        case .goToDefinition: "textDocument/definition"
        case .findReferences: "textDocument/references"
        case .hover: "textDocument/hover"
        case .goToImplementation: "textDocument/implementation"
        case .documentSymbol: "textDocument/documentSymbol"
        case .workspaceSymbol: "workspace/symbol"
        }
    }

    var providerCapability: String {
        switch self {
        case .goToDefinition: "definitionProvider"
        case .findReferences: "referencesProvider"
        case .hover: "hoverProvider"
        case .goToImplementation: "implementationProvider"
        case .documentSymbol: "documentSymbolProvider"
        case .workspaceSymbol: "workspaceSymbolProvider"
        }
    }

    var requiresPosition: Bool {
        switch self {
        case .goToDefinition, .findReferences, .hover, .goToImplementation: true
        case .documentSymbol, .workspaceSymbol: false
        }
    }
}

public struct LSPSemanticInput: Sendable, Equatable {
    public let operation: LSPSemanticOperation
    public let filePath: String?
    public let line: Int?
    public let character: Int?
    public let query: String?

    public init(
        operation: LSPSemanticOperation,
        filePath: String? = nil,
        line: Int? = nil,
        character: Int? = nil,
        query: String? = nil
    ) {
        self.operation = operation
        self.filePath = filePath
        self.line = line
        self.character = character
        self.query = query
    }
}

public enum LSPSemanticError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidArguments(String)
    case workspaceEscape(String)
    case unavailable(String)
    case unsupported(String)
    case invalidResponse(String)

    public var description: String {
        switch self {
        case .invalidArguments(let message), .workspaceEscape(let message),
             .unavailable(let message), .unsupported(let message),
             .invalidResponse(let message):
            message
        }
    }
}

private struct LSPSemanticSource: Sendable {
    let canonicalRoot: URL
    let url: URL
    let uri: String
    let content: String
}

private struct LSPSemanticLocation: Sendable {
    let path: String
    let line: Int
    let character: Int
}

private struct LSPSemanticSymbol: Sendable {
    let name: String
    let kind: Int
    let location: LSPSemanticLocation
}

extension LSPSession {
    public static let maximumSemanticSourceBytes = 4 * 1024 * 1024
    public static let maximumSemanticOutputBytes = 64 * 1024

    /// Dispatch a real initialized LSP request after canonical workspace and
    /// advertised-server-capability gates; no command ever runs through a shell.
    public func dispatchSemantic(_ input: LSPSemanticInput) async throws -> String {
        try Task.checkCancellation()
        if input.operation == .workspaceSymbol {
            return try await dispatchWorkspaceSymbols(input)
        }

        guard let rawPath = input.filePath, !rawPath.isEmpty else {
            throw LSPSemanticError.invalidArguments("Required: file_path.")
        }
        if input.operation.requiresPosition,
           input.line == nil || input.character == nil {
            throw LSPSemanticError.invalidArguments(
                "Required: file_path, line, character."
            )
        }

        let source = try Self.semanticSource(path: rawPath, workspaceRoot: workspaceRoot)
        if input.operation.requiresPosition {
            try Self.validatePosition(
                line: input.line ?? -1,
                character: input.character ?? -1,
                content: source.content
            )
        }

        let configured = semanticServerConfigurations()
        guard let resolved = LSPConfigLoader.resolveServer(
            for: source.url.path,
            servers: configured
        ) else {
            throw LSPSemanticError.unavailable(
                "No LSP server configured for \(source.url.path)"
            )
        }

        try Self.validateServerWorkspace(
            resolved.config,
            workspaceRoot: workspaceRoot,
            canonicalRoot: source.canonicalRoot
        )
        let client = try await semanticClient(for: resolved.name, config: resolved.config)
        guard await Self.serverSupports(input.operation, client: client) else {
            throw LSPSemanticError.unsupported(
                "LSP server '\(resolved.name)' does not support \(input.operation.rawValue)."
            )
        }

        if !semanticDocumentIsSynchronized(
            uri: source.uri,
            serverName: resolved.name,
            content: source.content
        ) {
            await notifyFileChanged(path: source.url.path, content: source.content)
            try Task.checkCancellation()
            guard semanticDocumentIsSynchronized(
                uri: source.uri,
                serverName: resolved.name,
                content: source.content
            ) else {
                throw LSPSemanticError.unavailable(
                    "LSP server '\(resolved.name)' could not synchronize the requested document."
                )
            }
        }

        try Task.checkCancellation()
        let response = try await client.request(
            method: input.operation.requestMethod,
            params: Self.requestParameters(input, uri: source.uri)
        )
        return try Self.formatResponse(
            response,
            operation: input.operation,
            root: source.canonicalRoot,
            documentURI: source.uri
        )
    }

    private func dispatchWorkspaceSymbols(_ input: LSPSemanticInput) async throws -> String {
        guard let query = input.query else {
            throw LSPSemanticError.invalidArguments("Required: query (string).")
        }
        guard query.utf8.count <= 1_024 else {
            throw LSPSemanticError.invalidArguments("LSP symbol query exceeds 1024 bytes.")
        }
        let root = try Self.canonicalExisting(URL(fileURLWithPath: workspaceRoot))
        let configured = semanticServerConfigurations().sorted { $0.key < $1.key }
        guard !configured.isEmpty else {
            throw LSPSemanticError.unavailable("No LSP servers are running.")
        }

        var symbols: [LSPSemanticSymbol] = []
        var supported = false
        var lastFailure: Error?
        for (name, configuration) in configured {
            try Task.checkCancellation()
            do {
                try Self.validateServerWorkspace(
                    configuration,
                    workspaceRoot: workspaceRoot,
                    canonicalRoot: root
                )
                let client = try await semanticClient(for: name, config: configuration)
                guard await Self.serverSupports(.workspaceSymbol, client: client) else {
                    continue
                }
                supported = true
                let response = try await client.request(
                    method: LSPSemanticOperation.workspaceSymbol.requestMethod,
                    params: .object(["query": .string(query)])
                )
                symbols.append(contentsOf: Self.symbols(
                    from: response,
                    root: root,
                    documentURI: nil
                ))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastFailure = error
            }
        }
        if symbols.isEmpty, let lastFailure {
            throw lastFailure
        }
        guard supported else {
            throw LSPSemanticError.unsupported(
                "No configured LSP server supports workspaceSymbol."
            )
        }
        return Self.formatSymbols(symbols)
    }

    private static func validateServerWorkspace(
        _ configuration: LspServerConfig,
        workspaceRoot: String,
        canonicalRoot: URL
    ) throws {
        let rootPath = configuration.effectiveRoot(workspaceRoot: workspaceRoot)
        let configuredRoot = try canonicalExisting(URL(fileURLWithPath: rootPath))
        guard configuredRoot == canonicalRoot
            || contains(configuredRoot, inside: canonicalRoot)
        else {
            throw LSPSemanticError.workspaceEscape(
                "LSP server workspaceFolder must stay inside the current workspace."
            )
        }
    }

    private static func requestParameters(_ input: LSPSemanticInput, uri: String) -> JSONValue {
        var fields: [String: JSONValue] = [
            "textDocument": .object(["uri": .string(uri)]),
        ]
        if input.operation.requiresPosition {
            fields["position"] = .object([
                "line": .number(.int64(Int64(input.line ?? 0))),
                "character": .number(.int64(Int64(input.character ?? 0))),
            ])
        }
        if input.operation == .findReferences {
            fields["context"] = .object(["includeDeclaration": .bool(true)])
        }
        return .object(fields)
    }

    private static func serverSupports(
        _ operation: LSPSemanticOperation,
        client: LSPStdioClient
    ) async -> Bool {
        let capabilities = await client.serverCapabilities()
        guard case .object(let fields) = capabilities,
              let capability = fields[operation.providerCapability]
        else { return false }
        switch capability {
        case .bool(let supported): return supported
        case .object: return true
        default: return false
        }
    }

    private static func semanticSource(
        path: String,
        workspaceRoot: String
    ) throws -> LSPSemanticSource {
        guard !path.contains("\0"),
              !path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).contains("..")
        else {
            throw LSPSemanticError.workspaceEscape(
                "LSP file_path must stay inside the current workspace."
            )
        }

        let canonicalRoot = try canonicalExisting(URL(fileURLWithPath: workspaceRoot))
        let candidate: URL
        if (path as NSString).isAbsolutePath {
            candidate = URL(fileURLWithPath: path)
        } else {
            candidate = canonicalRoot.appendingPathComponent(path)
        }
        let canonicalFile: URL
        do {
            canonicalFile = try canonicalExisting(candidate)
        } catch {
            throw LSPSemanticError.unavailable("LSP file does not exist or cannot be resolved.")
        }
        guard contains(canonicalFile, inside: canonicalRoot) else {
            throw LSPSemanticError.workspaceEscape(
                "LSP file_path must stay inside the current workspace."
            )
        }
        let metadata = try canonicalFile.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard metadata.isRegularFile == true,
              (metadata.fileSize ?? 0) <= maximumSemanticSourceBytes
        else {
            throw LSPSemanticError.invalidArguments(
                "LSP file must be a regular UTF-8 document no larger than 4 MiB."
            )
        }
        let handle = try FileHandle(forReadingFrom: canonicalFile)
        let data = try handle.read(upToCount: maximumSemanticSourceBytes + 1) ?? Data()
        try handle.close()
        guard data.count <= maximumSemanticSourceBytes,
              let content = String(data: data, encoding: .utf8)
        else {
            throw LSPSemanticError.invalidArguments(
                "LSP file must be a regular UTF-8 document no larger than 4 MiB."
            )
        }
        return LSPSemanticSource(
            canonicalRoot: canonicalRoot,
            url: canonicalFile,
            uri: LSPDocumentURI.fileURI(
                for: canonicalFile.path,
                workspaceRoot: canonicalRoot.path
            ),
            content: content
        )
    }

    private static func validatePosition(
        line: Int,
        character: Int,
        content: String
    ) throws {
        guard line >= 0, character >= 0 else {
            throw LSPSemanticError.invalidArguments(
                "LSP line and character must be non-negative UTF-16 offsets."
            )
        }
        let lines = content.split(
            omittingEmptySubsequences: false,
            whereSeparator: { $0.isNewline }
        )
        guard line < lines.count else {
            throw LSPSemanticError.invalidArguments("LSP line is outside the requested document.")
        }
        let text = String(lines[line])
        guard let index = text.utf16.index(
            text.utf16.startIndex,
            offsetBy: character,
            limitedBy: text.utf16.endIndex
        ), String.Index(index, within: text) != nil else {
            throw LSPSemanticError.invalidArguments(
                "LSP character must identify a complete UTF-16 position in the requested line."
            )
        }
    }

    private static func canonicalExisting(_ url: URL) throws -> URL {
        #if os(Windows)
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: resolved.path) else {
            throw LSPSemanticError.unavailable("LSP path does not exist.")
        }
        return resolved
        #else
        let resolved = url.path.withCString { path -> String? in
            guard let canonical = realpath(path, nil) else { return nil }
            defer { free(canonical) }
            return String(cString: canonical)
        }
        guard let resolved else {
            throw LSPSemanticError.unavailable("LSP path does not exist.")
        }
        return URL(fileURLWithPath: resolved)
        #endif
    }

    private static func contains(_ candidate: URL, inside root: URL) -> Bool {
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        guard candidateComponents.count > rootComponents.count else { return false }
        return zip(rootComponents, candidateComponents).allSatisfy { expected, actual in
            #if os(Windows)
            expected.caseInsensitiveCompare(actual) == .orderedSame
            #else
            expected == actual
            #endif
        }
    }

    private static func formatResponse(
        _ response: JSONValue,
        operation: LSPSemanticOperation,
        root: URL,
        documentURI: String
    ) throws -> String {
        switch operation {
        case .goToDefinition:
            return formatLocations("Definition", locations(from: response, root: root))
        case .goToImplementation:
            return formatLocations("Implementations", locations(from: response, root: root))
        case .findReferences:
            return formatLocations("References", locations(from: response, root: root))
        case .hover:
            return bounded(hoverText(response) ?? "No hover information available.")
        case .documentSymbol:
            return formatSymbols(symbols(from: response, root: root, documentURI: documentURI))
        case .workspaceSymbol:
            throw LSPSemanticError.invalidResponse("workspace symbols must be dispatched separately")
        }
    }

    private static func locations(from response: JSONValue, root: URL) -> [LSPSemanticLocation] {
        let values: [JSONValue]
        switch response {
        case .null: return []
        case .array(let entries): values = entries
        case .object: values = [response]
        default: return []
        }
        return values.prefix(1_024).compactMap { location(from: $0, root: root) }
    }

    private static func location(
        from value: JSONValue,
        root: URL,
        defaultURI: String? = nil
    ) -> LSPSemanticLocation? {
        guard case .object(let fields) = value else { return nil }
        let rawURI = fields["uri"]?.stringValue
            ?? fields["targetUri"]?.stringValue
            ?? defaultURI
        guard let rawURI,
              let uri = URL(string: rawURI),
              uri.isFileURL,
              uri.host == nil || uri.host == "localhost",
              let candidate = try? canonicalExisting(uri),
              contains(candidate, inside: root)
        else { return nil }

        let range = fields["targetSelectionRange"]?.objectValue
            ?? fields["range"]?.objectValue
            ?? fields["targetRange"]?.objectValue
        let start = range?["start"]?.objectValue
        let line = start?["line"]?.int64Value ?? 0
        let character = start?["character"]?.int64Value ?? 0
        guard line >= 0, character >= 0,
              line < Int64(Int.max), character < Int64(Int.max)
        else { return nil }
        return LSPSemanticLocation(
            path: candidate.path,
            line: Int(line),
            character: Int(character)
        )
    }

    private static func symbols(
        from response: JSONValue,
        root: URL,
        documentURI: String?
    ) -> [LSPSemanticSymbol] {
        guard case .array(let entries) = response else { return [] }
        var output: [LSPSemanticSymbol] = []
        for entry in entries {
            appendSymbols(entry, root: root, documentURI: documentURI, output: &output)
            if output.count >= 1_024 { break }
        }
        return output
    }

    private static func appendSymbols(
        _ value: JSONValue,
        root: URL,
        documentURI: String?,
        output: inout [LSPSemanticSymbol]
    ) {
        guard output.count < 1_024,
              case .object(let fields) = value,
              let name = fields["name"]?.stringValue,
              let rawKind = fields["kind"]?.int64Value,
              rawKind >= 1, rawKind <= 26
        else { return }
        let locationValue: JSONValue
        if let location = fields["location"] {
            locationValue = location
        } else {
            locationValue = .object([
                "uri": documentURI.map(JSONValue.string) ?? .null,
                "range": fields["range"] ?? .null,
            ])
        }
        guard let location = location(
            from: locationValue,
            root: root,
            defaultURI: documentURI
        ) else { return }
        output.append(LSPSemanticSymbol(name: name, kind: Int(rawKind), location: location))
        if case .array(let children)? = fields["children"] {
            for child in children {
                appendSymbols(child, root: root, documentURI: documentURI, output: &output)
                if output.count >= 1_024 { break }
            }
        }
    }

    private static func hoverText(_ response: JSONValue) -> String? {
        guard case .object(let object) = response,
              let contents = object["contents"]
        else { return nil }
        return markupText(contents)
    }

    private static func markupText(_ value: JSONValue) -> String? {
        switch value {
        case .string(let text): return text
        case .array(let values):
            let joined = values.compactMap(markupText).joined(separator: "\n")
            return joined.isEmpty ? nil : joined
        case .object(let fields):
            guard let text = fields["value"]?.stringValue else { return nil }
            if let language = fields["language"]?.stringValue {
                return "```\(language)\n\(text)\n```"
            }
            return text
        default: return nil
        }
    }

    private static func formatLocations(
        _ label: String,
        _ locations: [LSPSemanticLocation]
    ) -> String {
        guard !locations.isEmpty else { return "No results found." }
        let count = locations.count
        let lines = locations.map {
            "  \($0.path):\($0.line + 1):\($0.character + 1)"
        }.joined(separator: "\n")
        return bounded("\(label) (\(count) location\(count == 1 ? "" : "s")):\n\(lines)")
    }

    private static func formatSymbols(_ symbols: [LSPSemanticSymbol]) -> String {
        guard !symbols.isEmpty else { return "No symbols found." }
        let names = [
            "File", "Module", "Namespace", "Package", "Class", "Method",
            "Property", "Field", "Constructor", "Enum", "Interface", "Function",
            "Variable", "Constant", "String", "Number", "Boolean", "Array",
            "Object", "Key", "Null", "EnumMember", "Struct", "Event", "Operator",
            "TypeParameter",
        ]
        let text = symbols.map { symbol in
            "\(names[symbol.kind - 1]) \(symbol.name) (\(symbol.location.path):\(symbol.location.line + 1))"
        }.joined(separator: "\n")
        return bounded(text)
    }

    private static func bounded(_ output: String) -> String {
        guard output.utf8.count > maximumSemanticOutputBytes else { return output }
        let suffix = "\n[LSP output truncated]"
        let limit = maximumSemanticOutputBytes - suffix.utf8.count
        var end = output.startIndex
        var count = 0
        while end < output.endIndex {
            let next = output.index(after: end)
            let width = output[end..<next].utf8.count
            guard count + width <= limit else { break }
            count += width
            end = next
        }
        return String(output[..<end]) + suffix
    }
}
