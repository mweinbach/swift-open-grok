import Foundation
import Testing
@testable import OpenGrokWorkspace

@Suite("managed MCP policy Rust parity")
struct ManagedMCPPolicyParityTests {
    @Test("absent and explicitly empty allowlists remain unrestricted but distinguishable")
    func emptyAllowlistPreservesRustAdmissionSemantics() {
        let absent = ManagedMCPPolicy.parse(Data("{}".utf8))
        let explicit = ManagedMCPPolicy.parse(Data(#"{"allowedMcpServers":[]}"#.utf8))
        let server = ManagedMCPServerIdentity(name: "anything", transport: .stdio(command: "node"))

        #expect(absent.allowedServers == nil)
        #expect(explicit.allowedServers == [])
        #expect(!absent.isRestricted)
        #expect(!explicit.isRestricted)
        #expect(absent.isServerAllowed(server))
        #expect(explicit.isServerAllowed(server))
    }

    @Test("deny-only policies block exact commands without restricting unrelated servers")
    func denyOnlyCommandMatchesExactly() {
        let policy = ManagedMCPPolicy.parse(Data(#"{"deniedMcpServers":[{"command":"npx"}]}"#.utf8))

        #expect(policy.isRestricted)
        #expect(!policy.isServerAllowed(.init(name: "blocked", transport: .stdio(command: "npx"))))
        #expect(policy.isServerDenied(.init(name: "blocked", transport: .stdio(command: "npx"))))
        #expect(policy.isServerAllowed(.init(name: "other", transport: .stdio(command: "node"))))
        #expect(policy.isServerAllowed(.init(
            name: "other", transport: .stdio(command: "/usr/local/bin/npx")
        )))
        #expect(policy.isServerAllowed(.init(
            name: "http", transport: .http(url: "https://anything.example/mcp")
        )))
    }

    @Test("explicit denies outrank matching URL, command, and name allows")
    func deniesBeatAllowsAcrossDimensions() {
        let policy = ManagedMCPPolicy.parse(Data(#"""
        {
          "allowedMcpServers": [
            {"serverUrl":"https://*.example.com/*"},
            {"command":"npx"},
            {"serverName":"trusted"}
          ],
          "deniedMcpServers": [
            {"serverUrl":"https://blocked.example.com/*"},
            {"command":"npx"},
            {"serverName":"trusted"}
          ]
        }
        """#.utf8))

        #expect(!policy.isServerAllowed(.init(
            name: "gateway", transport: .http(url: "https://blocked.example.com/mcp")
        )))
        #expect(!policy.isServerAllowed(.init(name: "other", transport: .stdio(command: "npx"))))
        #expect(!policy.isServerAllowed(.init(
            name: "grok_com_trusted", transport: .http(url: "https://ok.example.com/mcp")
        )))
        #expect(policy.isServerAllowed(.init(
            name: "other", transport: .http(url: "https://ok.example.com/mcp")
        )))
    }

    @Test(
        "URL denies cannot be bypassed with scheme, ports, casing, trailing dots, or absent paths",
        arguments: [
            "https://mcp-gateway.example.net:443/mcp",
            "http://mcp-gateway.example.net/mcp",
            "https://mcp-gateway.example.net",
            "https://mcp-gateway.example.net./mcp",
            "https://MCP-GATEWAY.example.net/mcp",
            "https://mcp-gateway.example.net/mcp?allowed=https://safe.example/mcp",
            "https://mcp-gateway.example.net/mcp#fragment",
            "https://user:password@mcp-gateway.example.net:8443/mcp",
        ]
    )
    func normalizedDenyURL(_ candidate: String) {
        let policy = ManagedMCPPolicy(
            deniedServers: [.serverURL("https://mcp-gateway.example.net/*")]
        )
        let identity = ManagedMCPServerIdentity(name: "gateway", transport: .http(url: candidate))

        #expect(policy.isServerDenied(identity))
        #expect(!policy.isServerAllowed(identity))
    }

    @Test("URL deny host matching does not overblock unrelated hosts")
    func denyDoesNotBlockOtherHosts() {
        let policy = ManagedMCPPolicy(
            deniedServers: [.serverURL("https://mcp-gateway.example.net/*")]
        )

        #expect(policy.isServerAllowed(.init(
            name: "staging", transport: .http(url: "https://mcp-gateway.staging.example.net/mcp")
        )))
        #expect(policy.isServerAllowed(.init(
            name: "other", transport: .http(url: "https://other.example.com/mcp")
        )))
    }

    @Test("host-only denies cover every path, scheme, and port")
    func hostOnlyDenyBlocksEveryPath() {
        let policy = ManagedMCPPolicy(deniedServers: [.serverURL("*.corp.example")])

        #expect(!policy.isServerAllowed(.init(
            name: "a", transport: .http(url: "https://api.corp.example")
        )))
        #expect(!policy.isServerAllowed(.init(
            name: "b", transport: .http(url: "http://other.corp.example:9000/private")
        )))
        #expect(policy.isServerAllowed(.init(
            name: "c", transport: .http(url: "https://corp.example")
        )))
    }

    @Test("URL allows strip query injection but retain literal scheme and port restrictions")
    func allowURLIsLiteralApartFromGlob() {
        let policy = ManagedMCPPolicy(
            allowedServers: [.serverURL("https://*.example.com/*")]
        )

        #expect(policy.isServerAllowed(.init(
            name: "good", transport: .http(url: "https://API.example.com/mcp?token=hidden")
        )))
        #expect(!policy.isServerAllowed(.init(
            name: "wrong-scheme", transport: .http(url: "http://api.example.com/mcp")
        )))
        #expect(!policy.isServerAllowed(.init(
            name: "wrong-port", transport: .http(url: "https://api.example.com:443/mcp")
        )))
        #expect(!policy.isServerAllowed(.init(
            name: "query-injection",
            transport: .http(url: "https://evil.com/?url=https://api.example.com/mcp")
        )))
    }

    @Test("URL-only and command-only allowlists restrict only their own transport")
    func transportAllowsDoNotRestrictOtherTransport() {
        let httpOnly = ManagedMCPPolicy(allowedServers: [.serverURL("https://ok.example/*")])
        let stdioOnly = ManagedMCPPolicy(allowedServers: [.command("npx")])

        #expect(httpOnly.isServerAllowed(.init(name: "stdio", transport: .stdio(command: "node"))))
        #expect(stdioOnly.isServerAllowed(.init(
            name: "http", transport: .http(url: "https://anything.example/mcp")
        )))
        #expect(!httpOnly.isServerAllowed(.init(
            name: "http", transport: .http(url: "https://other.example/mcp")
        )))
        #expect(!stdioOnly.isServerAllowed(.init(
            name: "stdio", transport: .stdio(command: "node")
        )))
    }

    @Test("server names normalize managed prefix, case, spaces, and upstream truncation")
    func serverNamesMatchUpstreamRuntimeNormalization() {
        let policy = ManagedMCPPolicy(deniedServers: [.serverName("My Trusted Server")])

        #expect(policy.isServerDenied(.init(name: "grok_com_my_trusted_server")))
        #expect(policy.isServerDenied(.init(name: "MY TRUSTED SERVER")))
        #expect(!policy.isServerDenied(.init(name: "grok_com_my_trusted_server_extra")))

        let oversized = String(repeating: "a", count: 80)
        let truncated = "grok_com_" + String(repeating: "a", count: 30)
        #expect(ManagedMCPPolicy(deniedServers: [.serverName(oversized)])
            .isServerDenied(.init(name: truncated)))

        let reverse = ManagedMCPPolicy(deniedServers: [.serverName("grok_com_slack")])
        #expect(reverse.isServerDenied(.init(name: "Slack")))
        #expect(!reverse.isServerDenied(.init(name: "slackbot")))
    }

    @Test("name allows apply across both transports and union with URL allows")
    func nameAllowsUnionAcrossTransports() {
        let policy = ManagedMCPPolicy(allowedServers: [
            .serverURL("https://ok.example/*"),
            .serverName("special"),
        ])

        #expect(policy.isServerAllowed(.init(
            name: "ordinary", transport: .http(url: "https://ok.example/mcp")
        )))
        #expect(policy.isServerAllowed(.init(
            name: "grok_com_special", transport: .http(url: "https://other.example/mcp")
        )))
        #expect(policy.isServerAllowed(.init(
            name: "special", transport: .stdio(command: "/unlisted/command")
        )))
        #expect(!policy.isServerAllowed(.init(
            name: "ordinary", transport: .http(url: "https://other.example/mcp")
        )))
    }

    @Test("opaque ACP SDK servers cannot evade inspectable transport restrictions")
    func opaqueTransportFailsClosedWhenTransportMustBeInspected() {
        let named = ManagedMCPPolicy(allowedServers: [.serverName("trusted")])
        #expect(named.isServerAllowed(.init(name: "trusted")))
        #expect(!named.isServerAllowed(.init(name: "other")))

        let allowURL = ManagedMCPPolicy(allowedServers: [.serverURL("https://safe.example/*")])
        #expect(!allowURL.isServerAllowed(.init(name: "opaque")))

        let denyCommand = ManagedMCPPolicy(deniedServers: [.command("node")])
        #expect(denyCommand.isServerDenied(.init(name: "opaque")))
        #expect(!denyCommand.isServerAllowed(.init(name: "opaque")))

        let unrelatedNameDeny = ManagedMCPPolicy(deniedServers: [.serverName("blocked")])
        #expect(unrelatedNameDeny.isServerAllowed(.init(name: "safe")))
    }

    @Test(
        "malformed protected policies fail closed",
        arguments: [
            "[1, 2]",
            "{",
            #"{"allowedMcpServers":"npx"}"#,
            #"{"deniedMcpServers":[42]}"#,
            #"{"deniedMcpServers":[{"serverTypo":"blocked"}]}"#,
            #"{"allowedMcpServers":[{"command":""}]}"#,
            #"{"allowedMcpServers":[{"serverName":"grok_com_"}]}"#,
            #"{"deniedMcpServers":[{"serverUrl":"https://[broken"}]}"#,
            #"{"deniedMcpServers":[{"serverUrl":"https:///missing-host"}]}"#,
        ]
    )
    func malformedPolicyFailsClosed(_ json: String) {
        let policy = ManagedMCPPolicy.parse(Data(json.utf8))

        #expect(policy.invalidReason != nil)
        #expect(policy.isRestricted)
        #expect(!policy.isServerAllowed(.init(
            name: "otherwise-safe", transport: .stdio(command: "node")
        )))
    }

    @Test("an unreadable protected policy blocks rather than silently disappearing")
    func unreadablePolicyFailsClosed() {
        let nonexistent = FileManager.default.temporaryDirectory
            .appendingPathComponent("managed-mcp-missing-\(UUID().uuidString).json")
        let policy = ManagedMCPPolicy.load(from: nonexistent)

        #expect(policy.invalidReason?.contains("cannot read") == true)
        #expect(!policy.isServerAllowed(.init(name: "safe")))
        #expect(policy.blockReason(for: .init(name: "safe"))?.contains(nonexistent.path) == true)
    }

    @Test("source provenance and deny-vs-allow classification remain observable")
    func reasonCarriesSourceAndClassification() {
        let source = URL(fileURLWithPath: "/protected/managed-settings.json")
        let policy = ManagedMCPPolicy(
            allowedServers: [.serverName("allowed")],
            deniedServers: [.serverName("blocked")],
            sourcePath: source
        )

        let denied = ManagedMCPServerIdentity(name: "blocked")
        let missing = ManagedMCPServerIdentity(name: "other")
        #expect(policy.blockReason(for: denied) ==
            "matches deniedMcpServers (/protected/managed-settings.json)")
        #expect(policy.blockReason(for: missing) ==
            "not in allowedMcpServers (/protected/managed-settings.json)")
        #expect(policy.isServerDenied(denied))
        #expect(!policy.isServerDenied(missing))
    }

    @Test("entry precedence follows serverUrl then command then serverName")
    func multiFieldEntryUsesRustPrecedence() {
        let policy = ManagedMCPPolicy.parse(Data(#"""
        {"allowedMcpServers":[{
            "serverUrl":"https://safe.example/*",
            "command":"npx",
            "serverName":"anything"
        }]}
        """#.utf8))

        #expect(policy.allowedServers == [.serverURL("https://safe.example/*")])
        #expect(policy.isServerAllowed(.init(name: "stdio", transport: .stdio(command: "other"))))
        #expect(!policy.isServerAllowed(.init(
            name: "anything", transport: .http(url: "https://evil.example/mcp")
        )))
    }
}
