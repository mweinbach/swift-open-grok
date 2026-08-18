// MCPConfigAndStdioTests.swift
//
// Covers the two seams added to make configured MCP servers reachable: reading
// `mcpServers` out of a merged config document, and the child-process stdio
// transport.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokHTTP
import OpenGrokShared
import OpenGrokToolProtocol
import Testing
@testable import OpenGrokMCP

// MARK: - Config

@Suite("MCP config loading")
struct MCPConfigLoadingTests {
    @Test("stdio and http servers decode from the mcpServers table")
    func decodesBothTransports() throws {
        let document = try parseTOML("""
        [mcpServers.files]
        command = "mcp-files"
        args = ["--root", "/tmp"]
        cwd = "/tmp"

        [mcpServers.files.env]
        TOKEN = "abc"

        [mcpServers.remote]
        url = "https://example.test/mcp"
        type = "sse"
        bearer_token_env_var = "REMOTE_TOKEN"
        tool_timeout_sec = 12
        """)

        let loaded = MCPConfigLoader.load(from: document)
        #expect(loaded.problems.isEmpty)
        #expect(loaded.servers.map(\.name) == ["files", "remote"])

        guard case .stdio(let command, let args, let env, let cwd) =
            loaded.servers[0].config.transport else {
            Issue.record("expected a stdio transport")
            return
        }
        #expect(command == "mcp-files")
        #expect(args == ["--root", "/tmp"])
        #expect(env?["TOKEN"] == "abc")
        #expect(cwd == "/tmp")

        guard case .streamableHttp(let url, let type, let bearer, _, _, _, _) =
            loaded.servers[1].config.transport else {
            Issue.record("expected an http transport")
            return
        }
        #expect(url == "https://example.test/mcp")
        #expect(type == "sse")
        #expect(bearer == "REMOTE_TOKEN")
        #expect(loaded.servers[1].config.toolTimeoutSec == 12)
    }

    @Test("the snake_case mcp_servers alias is accepted")
    func acceptsSnakeCaseAlias() throws {
        let document = try parseTOML("""
        [mcp_servers.files]
        command = "mcp-files"
        """)
        #expect(MCPConfigLoader.load(from: document).servers.map(\.name) == ["files"])
    }

    @Test("servers default to enabled and honor an explicit disable")
    func enabledDefaultsAndOverride() throws {
        let document = try parseTOML("""
        [mcpServers.on]
        command = "a"

        [mcpServers.off]
        command = "b"
        enabled = false
        """)
        let loaded = MCPConfigLoader.load(from: document)
        #expect(loaded.servers.count == 2)
        #expect(loaded.enabledServers.map(\.name) == ["on"])
    }

    @Test("a malformed server is reported without losing the good ones")
    func malformedServerIsIsolated() throws {
        let document = try parseTOML("""
        [mcpServers.good]
        command = "works"

        [mcpServers.blank]
        enabled = true

        [mcpServers.wrongtype]
        command = 42
        """)

        let loaded = MCPConfigLoader.load(from: document)
        #expect(loaded.servers.map(\.name) == ["good"])
        #expect(Set(loaded.problems.map(\.server)) == ["blank", "wrongtype"])
        // The blank entry is the one the transport decoder would otherwise
        // accept as HTTP with an empty url.
        let blank = try #require(loaded.problems.first { $0.server == "blank" })
        #expect(blank.message.contains("url"))
    }

    @Test("a non-table entry is a problem, not a crash")
    func nonTableEntry() throws {
        let document = try parseTOML("""
        [mcpServers]
        oops = "not a table"
        """)
        let loaded = MCPConfigLoader.load(from: document)
        #expect(loaded.servers.isEmpty)
        #expect(loaded.problems.first?.server == "oops")
    }

    @Test("a document with no mcpServers table yields nothing")
    func absentTable() throws {
        let document = try parseTOML("[other]\nkey = 1\n")
        let loaded = MCPConfigLoader.load(from: document)
        #expect(loaded.servers.isEmpty)
        #expect(loaded.problems.isEmpty)
    }

    @Test("a .mcp.json document decodes through the same types")
    func decodesJSONDocument() throws {
        let json = Data("""
        {"mcpServers": {"files": {"command": "mcp-files", "args": ["-v"]}}}
        """.utf8)
        let loaded = MCPConfigLoader.load(jsonData: json)
        #expect(loaded.problems.isEmpty)
        #expect(loaded.servers.map(\.name) == ["files"])
    }
}

// MARK: - Transport construction

@Suite("MCP transport construction")
struct MCPTransportConstructionTests {
    private func declaration(_ toml: String, name: String) throws -> MCPServerDeclaration {
        let loaded = MCPConfigLoader.load(from: try parseTOML(toml))
        return try #require(loaded.servers.first { $0.name == name })
    }

    @Test("a stdio declaration builds a stdio transport without spawning")
    func stdioBuildsLazily() throws {
        let declaration = try declaration("""
        [mcpServers.files]
        command = "/definitely/not/here/mcp-files"
        """, name: "files")

        // Building must not spawn: a missing binary is a call-time failure,
        // not a config-load failure.
        let transport = try declaration.makeTransport(
            httpTransport: URLSessionHTTPTransport()
        )
        #expect(transport is MCPStdioTransport)
    }

    @Test("a bearer token env var becomes an Authorization header")
    func bearerTokenResolves() throws {
        let declaration = try declaration("""
        [mcpServers.remote]
        url = "https://example.test/mcp"
        bearer_token_env_var = "MY_TOKEN"
        """, name: "remote")

        let transport = try declaration.makeTransport(
            httpTransport: URLSessionHTTPTransport(),
            environment: ["MY_TOKEN": "s3cret"]
        )
        #expect(transport is MCPHTTPTransport)
    }

    @Test("a disabled server refuses to build a transport")
    func disabledRefuses() throws {
        let loaded = MCPConfigLoader.load(from: try parseTOML("""
        [mcpServers.off]
        command = "a"
        enabled = false
        """))
        let declaration = try #require(loaded.servers.first)
        #expect(throws: MCPConnectError.self) {
            _ = try declaration.makeTransport(httpTransport: URLSessionHTTPTransport())
        }
    }

    @Test("a malformed url is rejected at transport build time")
    func malformedURLRejected() throws {
        // A url that parses as config but not as a URL with a scheme.
        let loaded = MCPConfigLoader.load(from: try parseTOML("""
        [mcpServers.remote]
        url = "not a url at all"
        """))
        let declaration = try #require(loaded.servers.first)
        #expect(throws: MCPConnectError.self) {
            _ = try declaration.makeTransport(httpTransport: URLSessionHTTPTransport())
        }
    }

    @Test("transport summaries render for list output")
    func transportSummaries() throws {
        let stdio = try declaration("""
        [mcpServers.files]
        command = "mcp-files"
        args = ["--root", "/tmp"]
        """, name: "files")
        #expect(stdio.transportSummary == "mcp-files --root /tmp")

        let http = try declaration("""
        [mcpServers.remote]
        url = "https://example.test/mcp"
        type = "sse"
        """, name: "remote")
        #expect(http.transportSummary == "sse https://example.test/mcp")
    }
}

// MARK: - Stdio transport

private enum StdioServerBehavior {
    case respond(requireTransformedArgument: Bool, emitNoise: Bool)
    case markStarted
    case drain
    case exitImmediately
    case sleep
}

private struct StdioServerScript {
    let root: URL
    let path: String
    let command: String
    let arguments: [String]

    init(behavior: StdioServerBehavior) throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mcp-stdio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        #if os(Windows)
        let script = root.appendingPathComponent("server.ps1")
        try Self.windowsBody(for: behavior).write(to: script, atomically: true, encoding: .utf8)
        let systemRoot = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
        let powerShell = URL(fileURLWithPath: systemRoot, isDirectory: true)
            .appendingPathComponent("System32")
            .appendingPathComponent("WindowsPowerShell")
            .appendingPathComponent("v1.0")
            .appendingPathComponent("powershell.exe")
        command = powerShell.path.replacingOccurrences(of: "\\", with: "/")
        arguments = ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script.path]
        #else
        let script = root.appendingPathComponent("server.sh")
        try "#!/bin/sh\n\(Self.unixBody(for: behavior))\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: script.path
        )
        command = script.path
        arguments = []
        #endif

        self.root = root
        path = script.path
    }

    func configuration(requestTimeout: TimeInterval = 60) -> MCPStdioTransportConfiguration {
        MCPStdioTransportConfiguration(
            command: command,
            arguments: arguments,
            requestTimeout: requestTimeout
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    private static func unixBody(for behavior: StdioServerBehavior) -> String {
        switch behavior {
        case .respond(let requireTransformedArgument, let emitNoise):
            let argumentCheck = requireTransformedArgument
                ? "if [ \"$1\" != \"--transformed\" ]; then exit 7; fi\n"
                : ""
            let noise = emitNoise
                ? "printf 'this is not json\\n'\nprintf '{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{}}\\n'\n"
                : ""
            return """
            \(argumentCheck)while IFS= read -r line; do
              id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
              if [ -n "$id" ]; then
                \(noise)printf '{"jsonrpc":"2.0","id":%s,"result":{"ok":true}}\\n' "$id"
              fi
            done
            """
        case .markStarted:
            return "printf started > \"$0.started\""
        case .drain:
            return "cat > /dev/null"
        case .exitImmediately:
            return "exit 0"
        case .sleep:
            return "sleep 30"
        }
    }

    private static func windowsBody(for behavior: StdioServerBehavior) -> String {
        switch behavior {
        case .respond(let requireTransformedArgument, let emitNoise):
            let argumentCheck = requireTransformedArgument
                ? "if ($args.Count -eq 0 -or $args[0] -ne '--transformed') { exit 7 }\n"
                : ""
            let noise = emitNoise
                ? "[Console]::Out.WriteLine('this is not json')\n[Console]::Out.WriteLine('{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{}}')\n"
                : ""
            return """
            \(argumentCheck)while (($line = [Console]::In.ReadLine()) -ne $null) {
              try { $message = $line | ConvertFrom-Json } catch { continue }
              if ($null -ne $message.id) {
                \(noise)$response = [ordered]@{ jsonrpc = '2.0'; id = $message.id; result = [ordered]@{ ok = $true } }
                [Console]::Out.WriteLine(($response | ConvertTo-Json -Compress -Depth 4))
                [Console]::Out.Flush()
              }
            }
            """
        case .markStarted:
            return "Set-Content -Path ($PSCommandPath + '.started') -Value 'started'"
        case .drain:
            return "while ([Console]::In.ReadLine() -ne $null) {}"
        case .exitImmediately:
            return "exit 0"
        case .sleep:
            return "Start-Sleep -Seconds 30"
        }
    }
}

private enum MCPLaunchTransformTestError: Error {
    case rejected
}

@Suite("MCP stdio transport")
struct MCPStdioTransportTests {
    @Test("a launch transform rewrites the child argv before spawn")
    func launchTransformRewritesArguments() async throws {
        let script = try StdioServerScript(
            behavior: .respond(requireTransformedArgument: true, emitNoise: false)
        )
        defer { script.cleanup() }

        let transport = MCPStdioTransport(
            configuration: script.configuration(requestTimeout: 15),
            launchTransform: { executable, arguments in
                #expect(executable == script.command)
                #expect(arguments == script.arguments)
                return (executable, arguments + ["--transformed"])
            }
        )
        defer { Task { await transport.close() } }

        let response = try await transport.send(.request(MCPRequest(id: .number(1), method: MCPMethod.ping, params: nil)))
        guard case .response(let payload)? = response else {
            Issue.record("expected a response after transformed launch")
            return
        }
        #expect(payload.error == nil)
    }

    @Test("a throwing launch transform prevents the stdio child from running")
    func launchTransformFailureDoesNotSpawn() async throws {
        let script = try StdioServerScript(behavior: .markStarted)
        let marker = URL(fileURLWithPath: script.path + ".started")
        defer { script.cleanup() }

        let transport = MCPStdioTransport(
            configuration: script.configuration(requestTimeout: 5),
            launchTransform: { _, _ in throw MCPLaunchTransformTestError.rejected }
        )
        defer { Task { await transport.close() } }

        await #expect(throws: MCPError.self) {
            _ = try await transport.send(.request(MCPRequest(id: .number(1), method: MCPMethod.ping, params: nil)))
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("a request gets the matching response back over stdio")
    func roundTripsARequest() async throws {
        let script = try StdioServerScript(
            behavior: .respond(requireTransformedArgument: false, emitNoise: false)
        )
        defer { script.cleanup() }

        let transport = MCPStdioTransport(configuration: script.configuration(requestTimeout: 15))
        defer { Task { await transport.close() } }

        let request = MCPRequest(id: .number(1), method: MCPMethod.ping, params: nil)
        let response = try await transport.send(.request(request))

        guard case .response(let payload)? = response else {
            Issue.record("expected a response, got \(String(describing: response))")
            return
        }
        #expect(payload.id == request.id)
        #expect(payload.error == nil)
    }

    @Test("noise and malformed lines are skipped rather than failing the call")
    func skipsNoiseLines() async throws {
        let script = try StdioServerScript(
            behavior: .respond(requireTransformedArgument: false, emitNoise: true)
        )
        defer { script.cleanup() }

        let transport = MCPStdioTransport(configuration: script.configuration(requestTimeout: 15))
        defer { Task { await transport.close() } }

        let request = MCPRequest(id: .number(1), method: MCPMethod.ping, params: nil)
        let response = try await transport.send(.request(request))
        guard case .response(let payload)? = response else {
            Issue.record("expected a response, got \(String(describing: response))")
            return
        }
        #expect(payload.id == request.id)
    }

    @Test("a notification returns nil without waiting for a reply")
    func notificationDoesNotWait() async throws {
        let script = try StdioServerScript(behavior: .drain)
        defer { script.cleanup() }

        let transport = MCPStdioTransport(configuration: script.configuration(requestTimeout: 15))
        defer { Task { await transport.close() } }

        let response = try await transport.send(
            .notification(MCPNotification(method: MCPMethod.initialized))
        )
        #expect(response == nil)
    }

    @Test("a server that exits without answering surfaces a transport error")
    func serverExitSurfacesError() async throws {
        let script = try StdioServerScript(behavior: .exitImmediately)
        defer { script.cleanup() }

        let transport = MCPStdioTransport(configuration: script.configuration(requestTimeout: 15))
        defer { Task { await transport.close() } }

        await #expect(throws: MCPError.self) {
            _ = try await transport.send(.request(MCPRequest(id: .number(1), method: MCPMethod.ping, params: nil)))
        }
    }

    @Test("a silent server times out instead of hanging the caller")
    func silentServerTimesOut() async throws {
        let script = try StdioServerScript(behavior: .sleep)
        defer { script.cleanup() }

        let transport = MCPStdioTransport(configuration: script.configuration(requestTimeout: 0.75))
        defer { Task { await transport.close() } }

        let started = Date()
        await #expect(throws: MCPError.self) {
            _ = try await transport.send(.request(MCPRequest(id: .number(1), method: MCPMethod.ping, params: nil)))
        }
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test("a missing executable fails to start rather than trapping")
    func missingExecutableFails() async throws {
        let transport = MCPStdioTransport(configuration: MCPStdioTransportConfiguration(
            command: "/definitely/not/here/mcp-server",
            requestTimeout: 5
        ))
        defer { Task { await transport.close() } }

        await #expect(throws: MCPError.self) {
            _ = try await transport.send(.request(MCPRequest(id: .number(1), method: MCPMethod.ping, params: nil)))
        }
    }

    @Test("a closed transport refuses further sends")
    func closedTransportRefuses() async throws {
        let script = try StdioServerScript(behavior: .drain)
        defer { script.cleanup() }

        let transport = MCPStdioTransport(configuration: script.configuration())
        await transport.close()

        await #expect(throws: MCPError.self) {
            _ = try await transport.send(.request(MCPRequest(id: .number(1), method: MCPMethod.ping, params: nil)))
        }
    }
}
