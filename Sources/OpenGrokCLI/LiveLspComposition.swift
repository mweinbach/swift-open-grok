// LiveLspComposition.swift
//
// Live wiring for the `pull_diagnostics` tool — the first LSP slice.
//
// Registers one read-only tool when `features.lsp_tools` is enabled and at
// least one language server is configured in `lsp.json`. The heavy LSP
// transport lives in `OpenGrokLSP`; this file is the only place that sees
// both that library and `OpenGrokToolRegistry`.
//
// The launcher hook that registers these tools belongs in
// `LiveComposition.swift`, which the integration slice owns.

import Foundation
import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokLSP
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRegistry
import OpenGrokToolRuntime
import OpenGrokToolTypes

public enum LiveLspComposition {
    public static let toolName = PullDiagnosticsTool.toolName

    // MARK: - Feature gate

    /// Whether LSP tools are enabled for this session.
    ///
    /// Rust reference: `resolve_lsp_tools` (`config.rs:2684-2691`) —
    /// `GROK_LSP_TOOLS` env, then `[features].lsp_tools`, default false.
    public static func resolveEnabled(
        document: TOMLValue?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if let raw = environment["GROK_LSP_TOOLS"], !raw.isEmpty {
            return raw == "1" || raw.lowercased() == "true"
        }
        if let enabled = document?[path: ["features", "lsp_tools"]]?.boolValue {
            return enabled
        }
        return false
    }

    // MARK: - Config loading

    public static func loadServers(
        workingDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userConfigPath: URL? = nil,
        projectConfigPath: URL? = nil
    ) -> [String: LspServerConfig] {
        let user = userConfigPath ?? userGrokHome(environment: environment)?
            .appendingPathComponent("lsp.json")
        let project = projectConfigPath ?? workingDirectory
            .appendingPathComponent(".opengrok", isDirectory: true)
            .appendingPathComponent("lsp.json")
        return LSPConfigLoader.loadMerged(userConfigPath: user, projectConfigPath: project)
    }

    // MARK: - Tool specs

    public static func toolSpecs(
        enabled: Bool,
        servers: [String: LspServerConfig]
    ) -> [ToolSpec] {
        guard enabled, !servers.isEmpty else { return [] }
        let spec = PullDiagnosticsTool.spec
        return [
            ToolSpec(
                name: spec.name,
                description: spec.description,
                parameters: spec.parameters
            ),
        ]
    }

    public static func advertisedToolNames(
        enabled: Bool,
        servers: [String: LspServerConfig]
    ) -> Set<String> {
        Set(toolSpecs(enabled: enabled, servers: servers).map(\.name))
    }

    // MARK: - Registration

    /// Register `pull_diagnostics` into a finalized toolset when enabled and
    /// configured. Returns the live session handle, or nil when nothing was
    /// registered.
    @discardableResult
    public static func registerTools(
        toolset: FinalizedToolset,
        workingDirectory: URL,
        document: TOMLValue?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        servers: [String: LspServerConfig]? = nil
    ) -> LSPPullSession? {
        let enabled = resolveEnabled(document: document, environment: environment)
        let resolvedServers = servers ?? loadServers(
            workingDirectory: workingDirectory,
            environment: environment
        )
        guard enabled, !resolvedServers.isEmpty else { return nil }

        let session = LSPPullSession(
            workspaceRoot: workingDirectory.standardizedFileURL.path,
            servers: resolvedServers
        )
        let spec = PullDiagnosticsTool.spec
        let description = ToolDescription(name: spec.name, description: spec.description)
            .withKind(ProductToolKind.lsp.rawValue)
            .withNamespace(ProductToolNamespace.grokBuild.rawValue)

        toolset.registerDynamic(FinalizedTool(
            qualifiedId: "GrokBuild:\(spec.name)",
            namespace: .grokBuild,
            id: spec.name,
            clientName: spec.name,
            kind: .lsp,
            description: spec.description,
            definition: description,
            inputSchema: spec.parameters,
            reverseParams: [:],
            contractVersion: nil,
            visibility: .topLevel,
            exposure: .ordinary,
            handler: PullDiagnosticsToolHandler(session: session)
        ))
        return session
    }
}

struct PullDiagnosticsToolHandler: ToolHandler {
    let session: LSPPullSession

    func invoke(
        clientName: String,
        args: JSONValue,
        ctx: ToolCallContext,
        resources: ToolResources
    ) async -> Result<TypedToolOutput, ToolError> {
        _ = (clientName, ctx, resources)
        guard case .object(let fields) = args else {
            return .failure(.invalidArguments("pull_diagnostics arguments must be a JSON object"))
        }
        guard case .string(let path)? = fields["path"], !path.isEmpty else {
            return .failure(.invalidArguments("pull_diagnostics requires a non-empty path"))
        }
        let text = await session.pullDiagnostics(path: path)
        guard let toolId = try? ToolId(clientName) else {
            return .failure(.custom(code: "pull_diagnostics", detail: "invalid tool id"))
        }
        return .success(TypedToolOutput(
            toolId: toolId,
            value: .object(["content": .string(text)]),
            modelOutput: [.text(text: text)]
        ))
    }
}
