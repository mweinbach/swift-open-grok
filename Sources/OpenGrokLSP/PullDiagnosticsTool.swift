import Foundation
import OpenGrokShared

public enum PullDiagnosticsTool {
    public static let toolName = "pull_diagnostics"

    public static var spec: PullDiagnosticsToolSpec {
        PullDiagnosticsToolSpec(
            name: toolName,
            description: """
            Pull language-server diagnostics for one file via `textDocument/diagnostic`. \
            Requires a configured LSP server whose extension map covers the file.
            """,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("File path to inspect, relative to the workspace or absolute."),
                    ]),
                ]),
                "required": .array([.string("path")]),
                "additionalProperties": .bool(false),
            ])
        )
    }
}

public struct PullDiagnosticsToolSpec: Sendable, Equatable {
    public var name: String
    public var description: String
    public var parameters: JSONValue
}

public actor LSPPullSession {
    public let workspaceRoot: String
    private var servers: [String: LspServerConfig]
    private var clients: [String: LSPStdioClient] = [:]
    private var supportFlags: [String: PullSupportFlag] = [:]
    private var initializedRoots: [String: String] = [:]

    public init(workspaceRoot: String, servers: [String: LspServerConfig]) {
        self.workspaceRoot = workspaceRoot
        self.servers = servers
    }

    public func pullDiagnostics(path: String) async -> String {
        guard let resolved = LSPConfigLoader.resolveServer(for: path, servers: servers) else {
            return "No configured LSP server handles '\(path)'."
        }
        let support = supportFlag(for: resolved.name)
        guard support.get() == .asking else {
            return "LSP server '\(resolved.name)' does not support pull diagnostics."
        }

        let absolutePath = LSPDocumentURI.resolvePath(path, workspaceRoot: workspaceRoot)
        let uri = LSPDocumentURI.fileURI(for: absolutePath, workspaceRoot: workspaceRoot)

        do {
            let client = try await client(for: resolved.name, config: resolved.config)
            let outcome = await PullDiagnostics.request(
                client: client,
                uri: uri,
                previousResultID: nil,
                support: support
            )
            switch outcome {
            case .reported(let items, _):
                return DiagnosticFormatting.format(path: absolutePath, diagnostics: items)
            case .clean:
                return DiagnosticFormatting.format(path: absolutePath, diagnostics: [])
            case .unsupported:
                return "LSP server '\(resolved.name)' does not support pull diagnostics."
            case .failed(let detail):
                return "Diagnostic pull failed for '\(absolutePath)': \(detail)"
            }
        } catch {
            return "Diagnostic pull failed for '\(absolutePath)': \(error)"
        }
    }

    public func support(for serverName: String) -> PullSupport {
        supportFlag(for: serverName).get()
    }

    public func shutdown() async {
        for client in clients.values {
            await client.close()
        }
        clients.removeAll()
    }

    private func supportFlag(for serverName: String) -> PullSupportFlag {
        if let existing = supportFlags[serverName] {
            return existing
        }
        let created = PullSupportFlag()
        supportFlags[serverName] = created
        return created
    }

    private func client(for serverName: String, config: LspServerConfig) async throws -> LSPStdioClient {
        if let existing = clients[serverName] {
            return existing
        }
        let root = config.effectiveRoot(workspaceRoot: workspaceRoot)
        let rootURI = LSPDocumentURI.fileURI(for: root, workspaceRoot: workspaceRoot)
        let client = LSPStdioClient(
            configuration: LSPStdioClientConfiguration(
                command: config.command,
                arguments: config.args,
                environment: config.env.isEmpty ? nil : config.env,
                currentDirectoryPath: root,
                requestTimeout: PullDiagnostics.requestTimeout
            )
        )
        try await client.start()
        if initializedRoots[serverName] != rootURI {
            try await client.initialize(rootURI: rootURI)
            initializedRoots[serverName] = rootURI
        }
        clients[serverName] = client
        return client
    }
}
