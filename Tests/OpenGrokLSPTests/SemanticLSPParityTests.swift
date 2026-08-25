import Foundation
import OpenGrokLSP
import OpenGrokShared
import Testing

#if !os(Windows)
private struct SemanticLSPFixture {
    static let server = #"""
import json, os, pathlib, sys, time, urllib.parse

mode = sys.argv[1]
label = sys.argv[2]
outside = sys.argv[3]
marker = sys.argv[4]
opened = {}
initialized = False
root = None

def read_message():
    headers = {}
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return None
        if line in (b"\r\n", b"\n"):
            break
        name, value = line.decode().split(":", 1)
        headers[name.lower()] = value.strip()
    return json.loads(sys.stdin.buffer.read(int(headers["content-length"])))

def send(payload):
    encoded = json.dumps(payload, separators=(",", ":")).encode()
    sys.stdout.buffer.write(("Content-Length: %d\r\n\r\n" % len(encoded)).encode())
    sys.stdout.buffer.write(encoded)
    sys.stdout.buffer.flush()

def record(method):
    if marker:
        with open(marker, "a", encoding="utf-8") as output:
            output.write(method + "\n")

def position(line, character):
    return {"start":{"line":line,"character":character},
            "end":{"line":line,"character":character + 1}}

while True:
    message = read_message()
    if message is None:
        break
    method = message.get("method", "")
    identifier = message.get("id")
    params = message.get("params", {})
    record(method)
    if method == "initialize":
        root = pathlib.Path(urllib.parse.unquote(urllib.parse.urlparse(params["rootUri"]).path))
        caps = {
            "definitionProvider":True,
            "referencesProvider":True,
            "hoverProvider":True,
            "implementationProvider":{"workDoneProgress":False},
            "documentSymbolProvider":True,
            "workspaceSymbolProvider":True,
        }
        if mode == "unsupported":
            caps["hoverProvider"] = False
        send({"jsonrpc":"2.0","id":identifier,"result":{"capabilities":caps}})
    elif method == "initialized":
        initialized = True
    elif method == "textDocument/didOpen":
        document = params["textDocument"]
        opened[document["uri"]] = {"text":document["text"], "changes":0}
    elif method == "textDocument/didChange":
        uri = params["textDocument"]["uri"]
        opened[uri]["text"] = params["contentChanges"][0]["text"]
        opened[uri]["changes"] += 1
    elif method == "$/cancelRequest":
        pass
    elif method == "textDocument/diagnostic":
        send({"jsonrpc":"2.0","id":identifier,"result":{"kind":"full","items":[]}})
    elif identifier is not None:
        uri = params.get("textDocument", {}).get("uri")
        if not initialized or (method != "workspace/symbol" and uri not in opened):
            send({"jsonrpc":"2.0","id":identifier,
                  "error":{"code":-32001,"message":"document not initialized or opened"}})
            continue
        other = (root / "Other.swift").as_uri()
        character = params.get("position", {}).get("character", 0)
        if method == "textDocument/definition":
            locations = [{"targetUri":uri,"targetRange":position(0, 0),
                          "targetSelectionRange":position(1, character)}]
            if mode == "escape":
                locations.insert(0, {"uri":pathlib.Path(outside).as_uri(),"range":position(7, 0)})
            result = locations
        elif method == "textDocument/references":
            if not params.get("context", {}).get("includeDeclaration"):
                result = []
            else:
                result = [{"uri":uri,"range":position(0, 1)},
                          {"uri":other,"range":position(2, 3)}]
        elif method == "textDocument/implementation":
            result = {"uri":other,"range":position(4, 2)}
        elif method == "textDocument/hover":
            if mode == "slow":
                time.sleep(2)
            value = "x" * 100000 if mode == "large" else "type: " + opened[uri]["text"]
            result = {"contents":[{"language":"swift","value":value},
                                   "changes=" + str(opened[uri]["changes"])]}
        elif method == "textDocument/documentSymbol":
            result = [{"name":"Container","kind":5,"range":position(0, 0),
                       "children":[{"name":"member","kind":6,"range":position(1, 2)}]}]
        elif method == "workspace/symbol":
            result = [{"name":label + ":" + params["query"],"kind":12,
                       "location":{"uri":other,"range":position(3, 0)}}]
        else:
            send({"jsonrpc":"2.0","id":identifier,
                  "error":{"code":-32601,"message":"Method not found"}})
            continue
        send({"jsonrpc":"2.0","id":identifier,"result":result})
"""#

    let root: URL
    let workspace: URL
    let source: URL
    let other: URL
    let outside: URL
    let marker: URL

    init(content: String = "let sample = true\nlet second = true\n") throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-semantic-lsp-\(UUID().uuidString)")
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        source = workspace.appendingPathComponent("Sample.swift")
        other = workspace.appendingPathComponent("Other.swift")
        outside = root.appendingPathComponent("outside.swift")
        marker = root.appendingPathComponent("requests.log")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try content.write(to: source, atomically: true, encoding: .utf8)
        try "func other() {}\n".write(to: other, atomically: true, encoding: .utf8)
        try "private external information".write(to: outside, atomically: true, encoding: .utf8)
    }

    func configuration(mode: String = "normal", label: String = "primary") -> LspServerConfig {
        LspServerConfig(
            command: "/usr/bin/env",
            args: ["python3", "-u", "-c", Self.server, mode, label, outside.path, marker.path],
            extensions: [".swift": "swift"]
        )
    }

    func requests() throws -> [String] {
        guard FileManager.default.fileExists(atPath: marker.path) else { return [] }
        return try String(contentsOf: marker, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    func dispose() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("Pinned semantic language-server JSON-RPC parity")
struct SemanticLSPParityTests {
    @Test("all six upstream operations use initialized stdio, synchronized documents and exact formatting")
    func allSemanticOperationsReachRealServer() async throws {
        let fixture = try SemanticLSPFixture()
        defer { fixture.dispose() }

        try await withLSPSession(
            workspaceRoot: fixture.workspace.path,
            servers: ["swift": fixture.configuration()]
        ) { session in
            let definition = try await session.dispatchSemantic(.init(
                operation: .goToDefinition, filePath: "Sample.swift", line: 0, character: 4
            ))
            #expect(definition.contains("Definition (1 location):"))
            #expect(definition.contains("Sample.swift:2:5"))

            let references = try await session.dispatchSemantic(.init(
                operation: .findReferences, filePath: fixture.source.path, line: 0, character: 4
            ))
            #expect(references.contains("References (2 locations):"))
            #expect(references.contains("Sample.swift:1:2"))
            #expect(references.contains("Other.swift:3:4"))

            let hover = try await session.dispatchSemantic(.init(
                operation: .hover, filePath: "Sample.swift", line: 0, character: 4
            ))
            #expect(hover.contains("```swift\ntype: let sample = true"))

            let implementation = try await session.dispatchSemantic(.init(
                operation: .goToImplementation, filePath: "Sample.swift", line: 0, character: 4
            ))
            #expect(implementation.contains("Implementations (1 location):"))
            #expect(implementation.contains("Other.swift:5:3"))

            let document = try await session.dispatchSemantic(.init(
                operation: .documentSymbol, filePath: "Sample.swift"
            ))
            #expect(document.contains("Class Container ("))
            #expect(document.contains("Method member ("))

            let workspace = try await session.dispatchSemantic(.init(
                operation: .workspaceSymbol, query: "needle"
            ))
            #expect(workspace.contains("Function primary:needle ("))

            let requests = try fixture.requests()
            #expect(requests.first == "initialize")
            #expect(requests.contains("initialized"))
            #expect(requests.contains("textDocument/didOpen"))
            #expect(requests.contains("textDocument/definition"))
            #expect(requests.contains("workspace/symbol"))
        }
    }

    @Test("UTF-16 emoji boundaries and CRLF positions reject split surrogate columns")
    func utf16PositionsAndCRLF() async throws {
        let fixture = try SemanticLSPFixture(content: "let 🎯 = true\r\nsecond\r\n")
        defer { fixture.dispose() }

        try await withLSPSession(
            workspaceRoot: fixture.workspace.path,
            servers: ["swift": fixture.configuration()]
        ) { session in
            let afterEmoji = try await session.dispatchSemantic(.init(
                operation: .goToDefinition, filePath: "Sample.swift", line: 0, character: 6
            ))
            #expect(afterEmoji.contains("Sample.swift:2:7"))

            await #expect(throws: LSPSemanticError.self) {
                try await session.dispatchSemantic(.init(
                    operation: .goToDefinition, filePath: "Sample.swift", line: 0, character: 5
                ))
            }
            let nextLine = try await session.dispatchSemantic(.init(
                operation: .goToDefinition, filePath: "Sample.swift", line: 1, character: 3
            ))
            #expect(nextLine.contains("Sample.swift:2:4"))
        }
    }

    @Test("unsupported advertised capabilities fail before their JSON-RPC method is sent")
    func unsupportedCapabilityNeverDispatches() async throws {
        let fixture = try SemanticLSPFixture()
        defer { fixture.dispose() }

        try await withLSPSession(
            workspaceRoot: fixture.workspace.path,
            servers: ["swift": fixture.configuration(mode: "unsupported")]
        ) { session in
            await #expect(throws: LSPSemanticError.self) {
                try await session.dispatchSemantic(.init(
                    operation: .hover, filePath: "Sample.swift", line: 0, character: 1
                ))
            }
            let requests = try fixture.requests()
            #expect(!requests.contains("textDocument/hover"))
            #expect(!requests.contains("textDocument/didOpen"))
        }
    }

    @Test("traversal, absolute external files and outbound symlinks never start a server")
    func workspaceEscapesAreDeniedBeforeLaunch() async throws {
        let fixture = try SemanticLSPFixture()
        defer { fixture.dispose() }
        let redirect = fixture.workspace.appendingPathComponent("redirect.swift")
        try FileManager.default.createSymbolicLink(at: redirect, withDestinationURL: fixture.outside)

        try await withLSPSession(
            workspaceRoot: fixture.workspace.path,
            servers: ["swift": fixture.configuration()]
        ) { session in
            for path in ["../outside.swift", fixture.outside.path, redirect.path] {
                await #expect(throws: LSPSemanticError.self) {
                    try await session.dispatchSemantic(.init(
                        operation: .hover, filePath: path, line: 0, character: 1
                    ))
                }
            }
            let requests = try fixture.requests()
            #expect(requests.isEmpty)
        }
    }

    @Test("language-server response locations cannot disclose files outside the workspace")
    func externalResponseURIsAreDiscarded() async throws {
        let fixture = try SemanticLSPFixture()
        defer { fixture.dispose() }

        try await withLSPSession(
            workspaceRoot: fixture.workspace.path,
            servers: ["swift": fixture.configuration(mode: "escape")]
        ) { session in
            let result = try await session.dispatchSemantic(.init(
                operation: .goToDefinition, filePath: "Sample.swift", line: 0, character: 1
            ))
            #expect(result.contains("Definition (1 location):"))
            #expect(!result.contains("outside.swift"))
            #expect(!result.contains(fixture.outside.path))
        }
    }

    @Test("a configured language-server working directory cannot escape session authority")
    func configuredWorkspaceEscapeNeverLaunches() async throws {
        let fixture = try SemanticLSPFixture()
        defer { fixture.dispose() }
        var escaping = fixture.configuration()
        escaping.workspaceFolder = fixture.root.path

        try await withLSPSession(
            workspaceRoot: fixture.workspace.path,
            servers: ["swift": escaping]
        ) { session in
            await #expect(throws: LSPSemanticError.self) {
                try await session.dispatchSemantic(.init(
                    operation: .hover,
                    filePath: "Sample.swift",
                    line: 0,
                    character: 1
                ))
            }
            await #expect(throws: LSPSemanticError.self) {
                try await session.dispatchSemantic(.init(
                    operation: .workspaceSymbol,
                    query: "external"
                ))
            }
            let requests = try fixture.requests()
            #expect(requests.isEmpty)
        }
    }

    @Test("a later on-disk revision is synchronized before the next semantic request")
    func changedDocumentIsSynchronized() async throws {
        let fixture = try SemanticLSPFixture()
        defer { fixture.dispose() }

        try await withLSPSession(
            workspaceRoot: fixture.workspace.path,
            servers: ["swift": fixture.configuration()]
        ) { session in
            let first = try await session.dispatchSemantic(.init(
                operation: .hover, filePath: "Sample.swift", line: 0, character: 1
            ))
            #expect(first.contains("changes=0"))

            try "let replacement = true\n".write(
                to: fixture.source,
                atomically: true,
                encoding: .utf8
            )
            let second = try await session.dispatchSemantic(.init(
                operation: .hover, filePath: "Sample.swift", line: 0, character: 1
            ))
            #expect(second.contains("let replacement = true"))
            #expect(second.contains("changes=1"))
            let requests = try fixture.requests()
            #expect(requests.contains("textDocument/didChange"))
        }
    }

    @Test("workspace symbol requests fan out to every initialized supporting server")
    func workspaceSymbolsFanOut() async throws {
        let fixture = try SemanticLSPFixture()
        defer { fixture.dispose() }

        try await withLSPSession(
            workspaceRoot: fixture.workspace.path,
            servers: [
                "alpha": fixture.configuration(label: "alpha"),
                "beta": fixture.configuration(label: "beta"),
            ]
        ) { session in
            let result = try await session.dispatchSemantic(.init(
                operation: .workspaceSymbol,
                query: "symbol"
            ))
            #expect(result.contains("alpha:symbol"))
            #expect(result.contains("beta:symbol"))
            let requests = try fixture.requests()
            #expect(requests.filter { $0 == "workspace/symbol" }.count == 2)
        }
    }

    @Test("oversized semantic responses are bounded without splitting UTF-8")
    func semanticOutputIsBounded() async throws {
        let fixture = try SemanticLSPFixture()
        defer { fixture.dispose() }

        try await withLSPSession(
            workspaceRoot: fixture.workspace.path,
            servers: ["swift": fixture.configuration(mode: "large")]
        ) { session in
            let result = try await session.dispatchSemantic(.init(
                operation: .hover, filePath: "Sample.swift", line: 0, character: 1
            ))
            #expect(result.utf8.count <= LSPSession.maximumSemanticOutputBytes)
            #expect(result.hasSuffix("[LSP output truncated]"))
        }
    }

    @Test("cancelled semantic requests release their pending JSON-RPC continuation")
    func cancellationDoesNotWaitForTheServerTimeout() async throws {
        let fixture = try SemanticLSPFixture()
        defer { fixture.dispose() }

        try await withLSPSession(
            workspaceRoot: fixture.workspace.path,
            servers: ["swift": fixture.configuration(mode: "slow")]
        ) { session in
            let task = Task {
                try await session.dispatchSemantic(.init(
                    operation: .hover, filePath: "Sample.swift", line: 0, character: 1
                ))
            }
            try await Task.sleep(nanoseconds: 100_000_000)
            task.cancel()
            await #expect(throws: CancellationError.self) {
                try await task.value
            }
        }
    }

    @Test("a revoked session cannot restart its previously authorized language-server command")
    func shutdownPermanentlyRevokesServerAuthority() async throws {
        let fixture = try SemanticLSPFixture()
        defer { fixture.dispose() }
        let session = LSPSession(
            workspaceRoot: fixture.workspace.path,
            servers: ["swift": fixture.configuration()]
        )
        await session.shutdown()

        await #expect(throws: LSPSemanticError.self) {
            try await session.dispatchSemantic(.init(
                operation: .hover,
                filePath: "Sample.swift",
                line: 0,
                character: 1
            ))
        }
        let requests = try fixture.requests()
        #expect(requests.isEmpty)
        #expect(await session.pullDiagnostics(path: "Sample.swift") == "LSP session is closed.")
    }

    @Test("client initialize capabilities include pinned read-only semantic features")
    func clientAdvertisesPinnedSemanticCapabilities() {
        let capabilities = LSPStdioClient.clientCapabilities
        #expect(capabilities["textDocument"]?["definition"]?["linkSupport"] == .bool(false))
        #expect(capabilities["textDocument"]?["references"]?["dynamicRegistration"] == .bool(false))
        #expect(capabilities["textDocument"]?["hover"]?["contentFormat"] == .array([.string("plaintext")]))
    }
}
#endif
