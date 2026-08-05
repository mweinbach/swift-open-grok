// MCPNamingUpstreamVectorTests.swift
//
// Supplementary vectors for the MCP qualified-name encoding, transcribed
// verbatim from the Rust tests rather than restated.
//
// The implementation under test was ported by the `mcp-hooks` agent into
// `Sources/OpenGrokToolRegistry/MCPToolBridge.swift`; `MCPToolBridgeTests`
// already covers it well. This file exists to close four specific gaps found
// while verifying that port against the reference at pin `9ed09e2a`, so each
// case below is a Rust assertion that had no Swift counterpart.
//
// Rust provenance (`crates/codegen/xai-grok-mcp/src/servers.rs`):
//   * `:5978-6024` `into_registration_encodes_provider_invalid_server_names` —
//     the five (server, tool) pairs, with the tool names Rust actually uses.
//   * `:5968-5976` `into_registration_validates_qualified_name` — the
//     `registration.name` / `registration.tool_name` pair for a plain server.
//   * `:5948-5966` `qualified_mcp_name_parser_rejects_malformed_names`.
//   * `:5920-5946` the parser accept-list, including the two names that split
//     cleanly but carry a namespace segment.
//   * `:6026-6038` `reserved_encoded_prefix_round_trips_without_alias_collision`.

import Foundation
import Testing

@testable import OpenGrokToolRegistry

@Suite("MCP naming upstream vectors")
struct MCPNamingUpstreamVectorTests {
    /// Rust `into_registration_encodes_provider_invalid_server_names`
    /// (servers.rs:5991-5997). Every pair used to be skipped outright; each
    /// must now encode, validate, and decode back to the original server name.
    ///
    /// `MCPToolBridgeTests.encodesInvalidServerNames` covers four of these with
    /// a substituted tool name and does not round-trip the `"DS Dev"` vector
    /// back through `parseMCPToolName`, which is the half that proves the alias
    /// is reversible rather than merely well-formed.
    @Test("every previously-skipped server name encodes and decodes back")
    func encodedServerNamesRoundTrip() throws {
        for (server, tool) in [
            ("DS Dev", "inspect_turn"),
            ("123", "lookup"),
            ("server:scope", "tool"),
            ("server__part", "tool"),
            ("foo_", "bar"),
        ] {
            let qualified = try #require(
                qualifiedMCPToolName(server: server, tool: tool),
                "\(server) should encode rather than be skipped"
            )
            #expect(validateMCPToolName(qualified))
            let parsed = try #require(parseMCPToolName(qualified))
            #expect(parsed.server == server, "server must survive the round trip")
            #expect(parsed.tool == tool, "tool name must survive the round trip")
        }
    }

    /// The flagship vector, pinned byte-for-byte at servers.rs:6018-6021.
    @Test("the DS Dev vector matches the pinned encoding exactly")
    func dsDevVector() throws {
        #expect(encodeMCPServerNamespace("DS Dev") == "_mcp_445320446576")
        let qualified = try #require(
            qualifiedMCPToolName(server: "DS Dev", tool: "inspect_turn")
        )
        #expect(qualified == "_mcp_445320446576__inspect_turn")
        let parsed = try #require(parseMCPToolName(qualified))
        #expect(parsed.server == "DS Dev")
        #expect(parsed.tool == "inspect_turn")
    }

    /// Rust `into_registration_validates_qualified_name` (servers.rs:5969-5974)
    /// asserts both `registration.name` and the new `registration.tool_name`
    /// for a plain server. Swift has no `McpToolRegistration` struct — the raw
    /// name is recovered by parsing — so this pins the same invariant: the
    /// unqualified tool name is always recoverable from the registered name.
    /// That is what `tool_name` exists to guarantee, since `tool_timeouts` keys
    /// are raw names and prefix-stripping is what the field replaced.
    @Test("a plain server's raw tool name is recoverable from the qualified name")
    func rawToolNameIsRecoverable() throws {
        let qualified = try #require(
            qualifiedMCPToolName(server: "linear", tool: "list_issues")
        )
        #expect(qualified == "linear__list_issues")
        let parsed = try #require(parseMCPToolName(qualified))
        #expect(parsed.server == "linear")
        #expect(parsed.tool == "list_issues")
    }

    /// Rust `qualified_mcp_name_parser_rejects_malformed_names`
    /// (servers.rs:5950-5962). `MCPToolBridgeTests.rejectsAmbiguous` covers the
    /// delimiter-shaped rejections; `"server__bad.tool"` is the one that splits
    /// cleanly and is rejected by the `ToolId` leg instead, which was the only
    /// branch of `parseMCPQualifiedToolName` with no test.
    @Test("the parser rejects every malformed name upstream lists")
    func parserRejectsMalformedNames() {
        for name in [
            "server__part__tool",
            "server__tool__part",
            "foo___bar",
            "foo____bar",
            "__tool",
            "server__",
            "server",
            "",
            "server__bad.tool",
        ] {
            #expect(
                parseMCPQualifiedToolName(name) == nil,
                "unexpectedly accepted \(name)"
            )
        }
    }

    /// The parser accept-list at servers.rs:5930-5945. These split cleanly and
    /// carry no encoded prefix, so `parseMCPToolName` returns the server half
    /// unchanged — decoding must not disturb a name it did not encode.
    @Test("names that were never encoded parse through unchanged")
    func unencodedNamesParseUnchanged() throws {
        for (name, expected) in [
            ("linear__list_issues", ("linear", "list_issues")),
            ("123__lookup", ("123", "lookup")),
            ("server:scope__tool", ("server:scope", "tool")),
        ] {
            let parsed = try #require(parseMCPToolName(name), "\(name) should parse")
            #expect(parsed.server == expected.0)
            #expect(parsed.tool == expected.1)
        }
    }

    /// Rust `reserved_encoded_prefix_round_trips_without_alias_collision`
    /// (servers.rs:6027-6037). A server literally named like the alias for
    /// `"DS Dev"` must escape to something else and still decode back.
    @Test("a server named like an encoded alias escapes without colliding")
    func reservedPrefixEscapes() throws {
        let server = "_mcp_445320446576"
        let qualified = try #require(
            qualifiedMCPToolName(server: server, tool: "inspect_turn")
        )
        #expect(qualified != "_mcp_445320446576__inspect_turn")
        let parsed = try #require(parseMCPToolName(qualified))
        #expect(parsed.server == server)
        #expect(parsed.tool == "inspect_turn")
    }

    /// `encode` then `decode` is the identity for any server name, whether or
    /// not the name needed encoding. Covers the verbatim branch and the encoded
    /// branch with one property.
    @Test("encode then decode is the identity")
    func encodeDecodeIdentity() {
        for server in [
            "linear", "_leading", "with-hyphen",
            "DS Dev", "123", "server:scope", "server__part", "foo_",
            "_mcp_445320446576", "unicode-Ünicöde", "a b c",
        ] {
            #expect(
                decodeMCPServerNamespace(encodeMCPServerNamespace(server)) == server,
                "\(server) did not survive encode -> decode"
            )
        }
    }
}
