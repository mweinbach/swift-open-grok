import Foundation
import OpenGrokLSP
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase
import OpenGrokToolRegistry
import OpenGrokToolRuntime
import OpenGrokWorkspace
import Testing

@testable import OpenGrokCLI

#if !os(Windows)
private struct LiveSemanticLSPFixture {
    private static let server = #"""
import json, pathlib, sys

marker = pathlib.Path(sys.argv[1])
opened = set()
ready = False

def read():
    headers = {}
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return None
        if line in (b"\r\n", b"\n"):
            break
        key, value = line.decode().split(":", 1)
        headers[key.lower()] = value.strip()
    return json.loads(sys.stdin.buffer.read(int(headers["content-length"])))

def send(value):
    body = json.dumps(value).encode()
    sys.stdout.buffer.write(("Content-Length: %d\r\n\r\n" % len(body)).encode() + body)
    sys.stdout.buffer.flush()

while True:
    call = read()
    if call is None:
        break
    method = call.get("method", "")
    identifier = call.get("id")
    if method == "initialize":
        marker.write_text("started", encoding="utf-8")
        send({"jsonrpc":"2.0","id":identifier,"result":{"capabilities":{
            "definitionProvider":True,"referencesProvider":True,"hoverProvider":True,
            "implementationProvider":True,"documentSymbolProvider":True,
            "workspaceSymbolProvider":True}}})
    elif method == "initialized":
        ready = True
    elif method == "textDocument/didOpen":
        opened.add(call["params"]["textDocument"]["uri"])
    elif method == "textDocument/diagnostic":
        send({"jsonrpc":"2.0","id":identifier,"result":{"kind":"full","items":[]}})
    elif method == "textDocument/definition":
        uri = call["params"]["textDocument"]["uri"]
        if not ready or uri not in opened:
            send({"jsonrpc":"2.0","id":identifier,
                  "error":{"code":-32001,"message":"document was never opened"}})
            continue
        send({"jsonrpc":"2.0","id":identifier,"result":{"uri":uri,"range":{
            "start":{"line":1,"character":2},"end":{"line":1,"character":3}}}})
    elif identifier is not None:
        send({"jsonrpc":"2.0","id":identifier,"result":[]})
"""#

    let root: URL
    let workspace: URL
    let ownerHome: URL
    let openGrokHome: URL
    let source: URL
    let outside: URL
    let marker: URL
    let environment: [String: String]

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-live-semantic-lsp-\(UUID().uuidString)")
        workspace = root.appendingPathComponent("workspace")
        ownerHome = root.appendingPathComponent("owner")
        openGrokHome = ownerHome.appendingPathComponent(".opengrok")
        source = workspace.appendingPathComponent("Sample.swift")
        outside = root.appendingPathComponent("outside.swift")
        marker = root.appendingPathComponent("semantic-server-started")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: openGrokHome, withIntermediateDirectories: true)
        try "let sample = true\nlet value = 1\n".write(
            to: source,
            atomically: true,
            encoding: .utf8
        )
        try "external secret".write(to: outside, atomically: true, encoding: .utf8)
        environment = [
            "HOME": ownerHome.path,
            "OPENGROK_HOME": openGrokHome.path,
            "GROK_SANDBOX": "off",
            "GROK_FOLDER_TRUST": "1",
            "GROK_LSP_TOOLS": "1",
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        ]
    }

    var server: LspServerConfig {
        LspServerConfig(
            command: "/usr/bin/env",
            args: ["python3", "-u", "-c", Self.server, marker.path],
            extensions: [".swift": "swift"]
        )
    }

    func installOwnerServer() throws {
        try JSONEncoder().encode(["swift": server])
            .write(to: openGrokHome.appendingPathComponent("lsp.json"))
    }

    func withExecutor<T>(
        environment override: [String: String]? = nil,
        _ body: (LiveToolExecutor) async throws -> T
    ) async throws -> T {
        let effectiveEnvironment = override ?? environment
        let executor = try await LiveToolExecutor(
            processBackend: LocalShellProcessBackend(inheritedEnvironment: effectiveEnvironment),
            sessionID: "semantic-lsp-\(UUID().uuidString)",
            workingDirectory: workspace,
            toolPolicy: nil,
            telemetryBootstrapContext: .empty,
            fileAccessPolicy: .allowAll,
            environment: effectiveEnvironment
        )
        do {
            let value = try await body(executor)
            await executor.shutdown()
            return value
        } catch {
            await executor.shutdown()
            throw error
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("Live upstream semantic LSP tool reachability and authority")
struct LiveLSPSemanticParityTests {
    @Test("the actual model sees one upstream lsp tool and its real six-operation schema")
    func realExecutorAdvertisesAndDispatchesSingleSemanticTool() async throws {
        let fixture = try LiveSemanticLSPFixture()
        defer { fixture.remove() }
        try fixture.installOwnerServer()

        try await fixture.withExecutor { executor in
            let matches = executor.tools.filter { $0.name == "lsp" }
            #expect(matches.count == 1)
            let tool = try #require(matches.first)
            let operations = tool.parameters["properties"]?["operation"]?["enum"]?
                .arrayValue?.compactMap(\.stringValue)
            #expect(operations == [
                "goToDefinition", "findReferences", "hover", "goToImplementation",
                "documentSymbol", "workspaceSymbol",
            ])
            #expect(executor.tools.contains { $0.name == "pull_diagnostics" })
            #expect(!FileManager.default.fileExists(atPath: fixture.marker.path))

            let result = await executor.invoke(
                sessionID: "semantic-live-call",
                workingDirectory: fixture.workspace,
                call: ToolCall(
                    id: "real-definition",
                    name: "lsp",
                    arguments: #"{"operation":"goToDefinition","file_path":"Sample.swift","line":0,"character":4}"#
                )
            )
            guard case .success(let value) = result else {
                Issue.record("the actual advertised semantic LSP tool failed: \(result)")
                return
            }
            #expect(value.promptText.contains("Definition (1 location):"))
            #expect(value.promptText.contains("Sample.swift:2:3"))
            #expect(FileManager.default.fileExists(atPath: fixture.marker.path))
        }
    }

    @Test("disabled or unconfigured language services never advertise or launch semantic tools")
    func disabledAndUnconfiguredRemainInvisible() async throws {
        let fixture = try LiveSemanticLSPFixture()
        defer { fixture.remove() }

        try await fixture.withExecutor { executor in
            #expect(executor.tools.allSatisfy { $0.name != "lsp" })
        }
        try fixture.installOwnerServer()
        var disabled = fixture.environment
        disabled["GROK_LSP_TOOLS"] = "0"
        try await fixture.withExecutor(environment: disabled) { executor in
            #expect(executor.tools.allSatisfy { $0.name != "lsp" })
            #expect(executor.tools.allSatisfy { $0.name != "pull_diagnostics" })
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.marker.path))
    }

    @Test("malformed operations and workspace escapes fail before any language-server launch")
    func invalidAndEscapingCallsCannotLaunchServer() async throws {
        let fixture = try LiveSemanticLSPFixture()
        defer { fixture.remove() }
        try fixture.installOwnerServer()

        try await fixture.withExecutor { executor in
            let badCalls = [
                #"{"operation":"deleteWorkspace","file_path":"Sample.swift","line":0,"character":0}"#,
                #"{"operation":"goToDefinition","file_path":"Sample.swift"}"#,
                #"{"operation":"hover","file_path":"../outside.swift","line":0,"character":0}"#,
            ]
            for arguments in badCalls {
                let result = await executor.invoke(
                    sessionID: "semantic-denied",
                    workingDirectory: fixture.workspace,
                    call: ToolCall(id: UUID().uuidString, name: "lsp", arguments: arguments)
                )
                guard case .failure = result else {
                    Issue.record("invalid semantic request unexpectedly reached a server: \(arguments)")
                    continue
                }
            }
            #expect(!FileManager.default.fileExists(atPath: fixture.marker.path))
        }
    }

    @Test("semantic LSP registration never bypasses the ordinary fail-closed permission pipeline")
    func missingPermissionPipelineBlocksSemanticDispatch() async throws {
        let fixture = try LiveSemanticLSPFixture()
        defer { fixture.remove() }
        let toolset = FinalizedToolset(
            tools: [],
            resources: ToolResources(cwd: fixture.workspace.path),
            codeModeNamespaces: [:],
            options: .unrestricted
        )
        let session = try #require(LiveLspComposition.registerTools(
            toolset: toolset,
            workingDirectory: fixture.workspace,
            document: nil,
            environment: fixture.environment,
            servers: ["swift": fixture.server]
        ))
        let result = await toolset.prepareAndCall(
            clientName: "lsp",
            args: .object([
                "operation": .string("goToDefinition"),
                "file_path": .string("Sample.swift"),
                "line": .number(.int64(0)),
                "character": .number(.int64(1)),
            ])
        )
        await session.shutdown()

        guard case .failure(let error) = result else {
            Issue.record("an LSP call ran without the required permission pipeline")
            return
        }
        #expect(error.kind == .permissionDenied)
        #expect(!FileManager.default.fileExists(atPath: fixture.marker.path))
    }

    @Test("owner-only language-server provenance remains available in an untrusted repository")
    func ownerConfigurationRemainsTrustedWithoutProjectApproval() async throws {
        let fixture = try LiveSemanticLSPFixture()
        defer { fixture.remove() }
        try fixture.installOwnerServer()

        let hostile = fixture.workspace.appendingPathComponent(".opengrok")
        try FileManager.default.createDirectory(at: hostile, withIntermediateDirectories: true)
        let hostileMarker = fixture.root.appendingPathComponent("hostile-started")
        let malicious = LspServerConfig(
            command: "/usr/bin/touch",
            args: [hostileMarker.path],
            extensions: [".swift": "swift"]
        )
        try JSONEncoder().encode(["swift": malicious])
            .write(to: hostile.appendingPathComponent("lsp.json"))

        try await fixture.withExecutor { executor in
            #expect(executor.tools.contains { $0.name == "lsp" })
            let result = await executor.invoke(
                sessionID: "semantic-owner-only",
                workingDirectory: fixture.workspace,
                call: ToolCall(
                    id: "owner-definition",
                    name: "lsp",
                    arguments: #"{"operation":"goToDefinition","file_path":"Sample.swift","line":0,"character":1}"#
                )
            )
            guard case .success = result else {
                Issue.record("trusted owner semantic language server failed: \(result)")
                return
            }
            #expect(FileManager.default.fileExists(atPath: fixture.marker.path))
            #expect(!FileManager.default.fileExists(atPath: hostileMarker.path))
        }
    }
}
#endif
