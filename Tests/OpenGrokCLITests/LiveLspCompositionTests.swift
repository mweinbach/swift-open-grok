import Foundation
import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokLSP
import OpenGrokToolRegistry
import Testing
@testable import OpenGrokCLI

private func makeTempWorkspace() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("opengrok-lsp-cli-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func makeToolset(cwd: String) -> FinalizedToolset {
    FinalizedToolset(
        tools: [],
        resources: ToolResources(cwd: cwd),
        codeModeNamespaces: [:],
        options: .unrestricted
    )
}

@Suite("Live LSP composition")
struct LiveLspCompositionTests {
    @Test("tool absent when lsp_tools flag is off")
    func toolAbsentWhenFlagOff() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let toolset = makeToolset(cwd: workspace.path)
        let session = LiveLspComposition.registerTools(
            toolset: toolset,
            workingDirectory: workspace,
            document: .table(TOMLTable()),
            environment: [:],
            servers: [
                "swift": LspServerConfig(
                    command: "/bin/true",
                    extensions: [".swift": "swift"]
                ),
            ]
        )

        #expect(session == nil)
        #expect(toolset.tool(named: LiveLspComposition.toolName) == nil)
        #expect(LiveLspComposition.toolSpecs(enabled: false, servers: ["x": LspServerConfig(command: "x")]).isEmpty)
    }

    @Test("tool registers when flag on and servers configured")
    func toolRegistersWhenEnabled() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        var features = TOMLTable()
        features["lsp_tools"] = .boolean(true)
        var table = TOMLTable()
        table["features"] = .table(features)

        let toolset = makeToolset(cwd: workspace.path)
        let session = LiveLspComposition.registerTools(
            toolset: toolset,
            workingDirectory: workspace,
            document: .table(table),
            environment: [:],
            servers: [
                "swift": LspServerConfig(
                    command: "/bin/true",
                    extensions: [".swift": "swift"]
                ),
            ]
        )

        #expect(session != nil)
        #expect(toolset.tool(named: LiveLspComposition.toolName) != nil)
        let specs = LiveLspComposition.toolSpecs(
            enabled: true,
            servers: ["swift": LspServerConfig(command: "x", extensions: [".swift": "swift"])]
        )
        #expect(specs.map(\.name) == [LiveLspComposition.toolName])
        await session?.shutdown()
    }

    @Test("resolveEnabled honors GROK_LSP_TOOLS")
    func envGate() {
        #expect(
            LiveLspComposition.resolveEnabled(
                document: .table(TOMLTable()),
                environment: ["GROK_LSP_TOOLS": "1"]
            )
        )
        #expect(
            !LiveLspComposition.resolveEnabled(
                document: .table(TOMLTable()),
                environment: ["GROK_LSP_TOOLS": "0"]
            )
        )
    }
}
