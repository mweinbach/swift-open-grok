import Foundation
import OpenGrokLSP
import OpenGrokShared
import Testing

private func fixtureScript(named name: String = "mock_pull_lsp.py") -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(name)")
}

private func makeTempWorkspace() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("opengrok-lsp-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Suite("OpenGrokLSP pull diagnostics")
struct PullDiagnosticsTests {
    @Test("mock stdio server returns diagnostics")
    func mockServerReturnsDiagnostics() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let source = workspace.appendingPathComponent("Sample.swift")
        try "let x = 1".write(to: source, atomically: true, encoding: .utf8)

        let servers = [
            "swift": LspServerConfig(
                command: "/usr/bin/env",
                args: ["python3", fixtureScript().path, "ok"],
                extensions: [".swift": "swift"]
            ),
        ]
        let session = LSPPullSession(workspaceRoot: workspace.path, servers: servers)
        defer { await session.shutdown() }

        let text = await session.pullDiagnostics(path: "Sample.swift")
        #expect(text.contains("mock diagnostic"))
        #expect(text.contains("Sample.swift"))
    }

    @Test("MethodNotFound marks server rejected")
    func methodNotFoundRejected() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let source = workspace.appendingPathComponent("Sample.swift")
        try "let x = 1".write(to: source, atomically: true, encoding: .utf8)

        let servers = [
            "swift": LspServerConfig(
                command: "/usr/bin/env",
                args: ["python3", fixtureScript().path, "reject"],
                extensions: [".swift": "swift"]
            ),
        ]
        let session = LSPPullSession(workspaceRoot: workspace.path, servers: servers)
        defer { await session.shutdown() }

        let first = await session.pullDiagnostics(path: "Sample.swift")
        #expect(first.contains("does not support pull diagnostics"))
        #expect(await session.support(for: "swift") == .rejected)

        let second = await session.pullDiagnostics(path: "Sample.swift")
        #expect(second.contains("does not support pull diagnostics"))
    }

    @Test("PullSupportFlag rejects only on writeOff")
    func supportFlag() {
        let flag = PullSupportFlag()
        #expect(flag.get() == .asking)
        flag.writeOff()
        #expect(flag.get() == .rejected)
    }

    @Test("LSP message framing handles CRLF headers")
    func framingCRLF() throws {
        let body = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}".utf8)
        var buffer = LSPMessageFraming.encode(body)
        let parsed = LSPMessageFraming.takeMessage(from: &buffer)
        #expect(parsed == body)
        #expect(buffer.isEmpty)
    }
}

@Suite("OpenGrokLSP config")
struct LSPConfigTests {
    @Test("project lsp.json overrides user on name collision")
    func mergePrefersProject() throws {
        let root = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let user = root.appendingPathComponent("user-lsp.json")
        let project = root.appendingPathComponent("project-lsp.json")
        try """
        {"swift":{"command":"user","extensions":{".swift":"swift"}}}
        """.write(to: user, atomically: true, encoding: .utf8)
        try """
        {"swift":{"command":"project","extensions":{".swift":"swift"}}}
        """.write(to: project, atomically: true, encoding: .utf8)

        let merged = LSPConfigLoader.loadMerged(
            userConfigPath: user,
            projectConfigPath: project
        )
        #expect(merged["swift"]?.command == "project")
    }

    @Test("resolveServer picks extension map")
    func resolveServer() {
        let servers = [
            "csharp": LspServerConfig(
                command: "roslyn",
                extensions: [".cs": "csharp"]
            ),
        ]
        let resolved = LSPConfigLoader.resolveServer(for: "Program.cs", servers: servers)
        #expect(resolved?.name == "csharp")
        #expect(resolved?.languageID == "csharp")
    }
}
