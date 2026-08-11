import Foundation
import OpenGrokLSP
import OpenGrokShared
import Testing

private func fixtureScript(named name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(name)")
}

private func makeTempWorkspace() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("opengrok-lsp-sync-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Suite("OpenGrokLSP document sync and push diagnostics")
struct SyncDiagnosticsTests {
    @Test("notifyFileChanged drain returns pushed diagnostics")
    func notifyThenDrain() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let source = workspace.appendingPathComponent("Sample.swift")
        let content = "let x = 1"
        try content.write(to: source, atomically: true, encoding: .utf8)

        let servers = [
            "swift": LspServerConfig(
                command: "/usr/bin/env",
                args: ["python3", fixtureScript(named: "mock_push_lsp.py").path],
                extensions: [".swift": "swift"]
            ),
        ]
        let session = LSPSession(workspaceRoot: workspace.path, servers: servers)
        defer { await session.shutdown() }

        await session.notifyFileChanged(path: "Sample.swift", content: content)
        let summary = await session.drainDiagnostics(timeout: 2.0)
        #expect(summary != nil)
        let text = try #require(summary)
        #expect(text.contains("<lsp-diagnostics>"))
        #expect(text.contains("</lsp-diagnostics>"))
        #expect(text.contains("pushed diagnostic"))
        #expect(text.contains("Sample.swift"))
    }

    @Test("pull_diagnostics still works against pull mock")
    func pullStillWorks() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let source = workspace.appendingPathComponent("Sample.swift")
        try "let x = 1".write(to: source, atomically: true, encoding: .utf8)

        let servers = [
            "swift": LspServerConfig(
                command: "/usr/bin/env",
                args: ["python3", fixtureScript(named: "mock_pull_lsp.py").path, "ok"],
                extensions: [".swift": "swift"]
            ),
        ]
        let session = LSPSession(workspaceRoot: workspace.path, servers: servers)
        defer { await session.shutdown() }

        let text = await session.pullDiagnostics(path: "Sample.swift")
        #expect(text.contains("mock diagnostic"))
        #expect(text.contains("Sample.swift"))
    }

    @Test("inbound notification without id decodes and does not require response id")
    func inboundNotificationDecode() throws {
        let body = Data("""
        {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///x.swift","diagnostics":[]}}
        """.utf8)
        let message = try LSPInboundMessage.decode(from: body)
        guard case .notification(let method, let params) = message else {
            Issue.record("expected notification, got \(message)")
            return
        }
        #expect(method == "textDocument/publishDiagnostics")
        #expect(params != nil)
    }

    @Test("Documents plan open then change with previous end")
    func documentsPlan() {
        let documents = Documents()
        let uri = "file:///a.swift"
        #expect(documents.plan(uri: uri) == .open(version: 1))
        documents.commit(
            uri: uri,
            version: 1,
            languageID: "swift",
            end: Documents.endPosition("one\ntwo")
        )
        #expect(
            documents.plan(uri: uri) == .change(
                version: 2,
                previousEnd: LSPPosition(line: 1, character: 3)
            )
        )
    }

    @Test("DiagnosticsStore recordPush answers matching version")
    func diagnosticsStoreVersions() {
        let store = DiagnosticsStore()
        let uri = "file:///a.swift"
        #expect(!store.answered(for: uri, version: 1))
        _ = store.recordPush(
            uri: uri,
            diagnostics: [LSPDiagnostic(message: "boom", severity: 1)],
            reported: 1,
            latestSent: 1
        )
        #expect(store.answered(for: uri, version: 1))
        #expect(store.items(uri: uri).count == 1)
        #expect(store.serverPublishes())
    }
}
