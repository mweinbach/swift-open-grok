// ConfigWriteTests.swift
//
// Covers the config write path: TOML serialization and the MCP server table
// surgery that `mcp add` / `mcp remove` perform.
//
// The behaviours pinned here are transcribed from
// `xai-grok-shell/src/util/config/mcp.rs` — `save_mcp_server_config_at:860`
// and `delete_mcp_server_config_at:918`. Upstream re-serializes the whole
// document with `toml::to_string_pretty` rather than editing it in place, so
// these tests assert semantic round-trips, never byte-for-byte formatting.

import Foundation
import Testing

@testable import OpenGrokConfig
import OpenGrokConfigTypes

@Suite("TOML encoding")
struct TOMLEncodeTests {
    @Test("documents round-trip through encode and parse")
    func roundTrip() throws {
        let source = """
            title = "example"
            retries = 3
            ratio = 0.5
            enabled = true
            tags = ["a", "b"]

            [server]
            host = "localhost"

            [server.tls]
            enabled = false

            [[jobs]]
            name = "first"

            [[jobs]]
            name = "second"
            """
        let parsed = try parseTOML(source)
        let reparsed = try parseTOML(TOMLEncoder.encode(parsed))
        #expect(reparsed == parsed)
    }

    @Test("the document never opens with a blank line")
    func noLeadingBlankLine() throws {
        let encoded = TOMLEncoder.encode(try parseTOML("[a]\nb = 1\n"))
        #expect(encoded.hasPrefix("[a]"))
        #expect(try parseTOML(encoded) == (try parseTOML("[a]\nb = 1\n")))
    }

    /// TOML bare keys are ASCII-only. `Character.isLetter` and `.isNumber` are
    /// true for non-ASCII scalars, so a key like `"café"` or `"٣"` would have
    /// been emitted unquoted and produced a document that cannot be reparsed.
    @Test("non-ASCII keys are quoted so they reparse")
    func nonASCIIKeysAreQuoted() throws {
        var table = TOMLTable()
        table.insert(.integer(1), forKey: "café")
        table.insert(.integer(2), forKey: "٣")
        table.insert(.integer(3), forKey: "plain_key-1")
        let encoded = TOMLEncoder.encode(.table(table))
        #expect(encoded.contains("\"café\""))
        #expect(encoded.contains("plain_key-1 = 3"))
        #expect(try parseTOML(encoded) == .table(table))
    }
}

@Suite("MCP config writes")
struct MCPConfigWriteTests {
    private func stdio(_ command: String, args: [String] = []) -> McpServerConfig {
        McpServerConfig(
            transport: .stdio(command: command, args: args, env: nil, cwd: nil)
        )
    }

    @Test("adding a server writes a reparseable [mcp_servers] entry")
    func upsertRoundTrips() throws {
        var root = try parseTOML("[ui]\nvim_mode = true\n")
        try upsertMCPServer("docs", config: stdio("npx", args: ["-y", "server"]), in: &root)

        let reparsed = try parseTOML(TOMLEncoder.encode(root))
        #expect(mcpServerIsDefined("docs", in: reparsed))
        // Unrelated tables survive the re-serialize.
        #expect(reparsed["ui"]?["vim_mode"]?.boolValue == true)

        let entry = reparsed["mcp_servers"]?["docs"]
        #expect(entry?["command"]?.stringValue == "npx")
        #expect(entry?["args"]?.arrayValue?.compactMap(\.stringValue) == ["-y", "server"])
        #expect(entry?["enabled"]?.boolValue == true)
    }

    /// `save_mcp_server_config_at` drops the name from `disabled_mcp_servers`
    /// so a newly defined server starts enabled, and removes the array once it
    /// empties rather than leaving `disabled_mcp_servers = []` behind.
    @Test("adding re-enables a previously disabled server")
    func upsertClearsDisabled() throws {
        var root = try parseTOML("disabled_mcp_servers = [\"docs\", \"other\"]\n")
        try upsertMCPServer("docs", config: stdio("npx"), in: &root)
        #expect(root["disabled_mcp_servers"]?.arrayValue?.compactMap(\.stringValue) == ["other"])

        var only = try parseTOML("disabled_mcp_servers = [\"docs\"]\n")
        try upsertMCPServer("docs", config: stdio("npx"), in: &only)
        #expect(only["disabled_mcp_servers"] == nil)
    }

    @Test("adding replaces an existing entry rather than merging it")
    func upsertReplaces() throws {
        var root = try parseTOML("[mcp_servers.docs]\ncommand = \"old\"\nargs = [\"x\"]\n")
        try upsertMCPServer("docs", config: stdio("new"), in: &root)
        let entry = root["mcp_servers"]?["docs"]
        #expect(entry?["command"]?.stringValue == "new")
        #expect(entry?["args"]?.arrayValue?.isEmpty == true)
    }

    /// `delete_mcp_server_config_at` removes the entry, the emptied
    /// `mcp_servers` table, the `disabled_mcp_servers` membership, and the
    /// `[disabled_mcp_tools.<name>]` entry.
    @Test("removing a server cleans up every table that names it")
    func removeCleansUp() throws {
        var root = try parseTOML(
            """
            disabled_mcp_servers = ["docs"]

            [mcp_servers.docs]
            command = "npx"

            [disabled_mcp_tools]
            docs = ["search"]
            """
        )
        #expect(try removeMCPServer("docs", from: &root) == true)
        #expect(root["mcp_servers"] == nil)
        #expect(root["disabled_mcp_servers"] == nil)
        #expect(root["disabled_mcp_tools"] == nil)
    }

    @Test("removing one of several servers keeps the rest")
    func removeKeepsSiblings() throws {
        var root = try parseTOML(
            "[mcp_servers.docs]\ncommand = \"a\"\n\n[mcp_servers.other]\ncommand = \"b\"\n"
        )
        #expect(try removeMCPServer("docs", from: &root) == true)
        #expect(!mcpServerIsDefined("docs", in: root))
        #expect(mcpServerIsDefined("other", in: root))
    }

    @Test("removing an absent server reports false and changes nothing")
    func removeMissing() throws {
        let original = try parseTOML("[mcp_servers.other]\ncommand = \"b\"\n")
        var root = original
        #expect(try removeMCPServer("docs", from: &root) == false)
        #expect(root == original)
    }

    /// The `.mcp.json`-style `mcpServers` spelling is also read by
    /// `MCPConfigLoader`, so an edit must target whichever spelling the file
    /// already uses instead of creating a second, shadowed table.
    @Test("edits target the camelCase table when the file already uses it")
    func respectsExistingSpelling() throws {
        var root = try parseTOML("[mcpServers.docs]\ncommand = \"a\"\n")
        try upsertMCPServer("other", config: stdio("b"), in: &root)
        #expect(root["mcpServers"]?["other"] != nil)
        #expect(root["mcp_servers"] == nil)
        #expect(try removeMCPServer("docs", from: &root) == true)
        #expect(mcpServerIsDefined("other", in: root))
    }

    @Test("a scalar where mcp_servers belongs is reported, not clobbered")
    func rejectsScalarTable() throws {
        var root = try parseTOML("mcp_servers = \"bogus\"\n")
        #expect(throws: TOMLWriteError.self) {
            try upsertMCPServer("docs", config: stdio("a"), in: &root)
        }
    }

    @Test("writeConfigFile replaces the target atomically and leaves no temp file")
    func atomicWrite() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigWriteTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("config.toml")

        var root = TOMLValue.table(TOMLTable())
        try upsertMCPServer("docs", config: stdio("npx"), in: &root)
        // The parent directory does not exist yet; the write creates it.
        try writeConfigFile(root, to: path)

        let reloaded = try parseTOML(String(contentsOf: path, encoding: .utf8))
        #expect(mcpServerIsDefined("docs", in: reloaded))
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("config.toml.tmp").path
        ))

        // A second write replaces rather than appends.
        var next = TOMLValue.table(TOMLTable())
        try upsertMCPServer("other", config: stdio("b"), in: &next)
        try writeConfigFile(next, to: path)
        let second = try parseTOML(String(contentsOf: path, encoding: .utf8))
        #expect(!mcpServerIsDefined("docs", in: second))
        #expect(mcpServerIsDefined("other", in: second))
    }
}
