import Foundation
import OpenGrokShared
import Testing
@testable import OpenGrokMCP

private typealias JSONValue = OpenGrokShared.JSONValue

@Suite("Rust-compatible sanitized MCP protocol icons")
struct MCPIconParityTests {
    @Test("only exact HTTPS and opaque data:image sources survive, without fetching or decoding")
    func iconSourcePolicyMatchesRust() throws {
        for source in [
            "   ",
            "http://example.com/icon.png",
            "javascript:alert(1)",
            "file:///private/session.json",
            "HTTPS://example.com/icon.png",
            "data:text/html,secret",
        ] {
            #expect(MCPIcon(src: source) == nil)
        }

        let secure = try #require(MCPIcon(
            src: "  https://127.0.0.1:1/never-fetch.png  ",
            mimeType: "  text/html  ",
            sizes: [" 48x48 "],
            theme: .dark
        ))
        #expect(secure.src == "https://127.0.0.1:1/never-fetch.png")
        #expect(secure.mimeType == "text/html")
        #expect(secure.sizes == ["48x48"])
        #expect(secure.theme == .dark)

        let opaque = try #require(MCPIcon(src: "data:image/svg+xml;base64,not-really-base64"))
        #expect(opaque.src == "data:image/svg+xml;base64,not-really-base64")
    }

    @Test("source and optional metadata caps count trimmed UTF-8 bytes")
    func byteLimitsAndOptionalMetadataMatchRust() throws {
        let prefix = "https://example.com/"
        let exact = prefix + String(
            repeating: "a",
            count: MCPIconLimits.maximumSourceBytes - prefix.utf8.count
        )
        #expect(MCPIcon(src: exact) != nil)
        #expect(MCPIcon(src: exact + "a") == nil)

        let unicodeCount = (MCPIconLimits.maximumSourceBytes - prefix.utf8.count) / 2
        let unicode = prefix + String(repeating: "é", count: unicodeCount)
        #expect(MCPIcon(src: unicode) != nil)
        #expect(MCPIcon(src: unicode + "é") == nil)

        let icon = try #require(MCPIcon(
            src: "https://example.com/icon.png",
            mimeType: String(repeating: "x", count: MCPIconLimits.maximumMIMETypeBytes + 1),
            sizes: [
                String(repeating: "x", count: MCPIconLimits.maximumSizeTokenBytes + 1),
                " 48x48 ",
                " ",
            ] + (0..<20).map { "\($0)x\($0)" }
        ))
        #expect(icon.mimeType == nil)
        #expect(icon.sizes?.count == MCPIconLimits.maximumSizes)
        #expect(icon.sizes?.first == "48x48")
    }

    @Test("tool and server wire decoding filters before its eight-icon cap and omits unknown themes")
    func wireDecodingFiltersBeforeCapping() throws {
        var icons: [JSONValue] = [
            .object(["src": .string("http://example.com/rejected.png")]),
            .object(["src": .string("   ")]),
        ]
        icons.append(contentsOf: (0..<12).map { index in
            .object([
                "src": .string("https://example.com/\(index).png"),
                "theme": .string(index == 0 ? "unknown-future-theme" : "dark"),
            ])
        })
        let implementation = try JSONValue.object([
            "name": .string("icon-server"),
            "version": .string("1.0"),
            "icons": .array(icons),
        ]).decode(MCPImplementation.self)
        #expect(implementation.icons.count == MCPIconLimits.maximumIconsPerEntity)
        #expect(implementation.icons.first?.src == "https://example.com/0.png")
        #expect(implementation.icons.first?.theme == nil)
        #expect(implementation.icons.last?.src == "https://example.com/7.png")

        let tool = try JSONValue.object([
            "name": .string("search"),
            "inputSchema": .object(["type": .string("object")]),
            "icons": .array(icons),
        ]).decode(MCPTool.self)
        #expect(tool.icons == implementation.icons)
    }

    @Test("empty icon arrays and absent optional icon metadata never appear on the wire")
    func wireEncodingOmitsEmptyFields() throws {
        let noIcons = MCPImplementation(name: "legacy", version: "1")
        let encodedImplementation = try JSONValue.encode(noIcons)
        #expect(encodedImplementation["icons"] == nil)

        let noIconTool = MCPTool(name: "legacy")
        let encodedTool = try JSONValue.encode(noIconTool)
        #expect(encodedTool["icons"] == nil)

        let icon = try #require(MCPIcon(src: "https://example.com/icon.png"))
        let encodedIcon = try JSONValue.encode(icon)
        #expect(encodedIcon.objectValue?.count == 1)
        #expect(encodedIcon["src"]?.stringValue == "https://example.com/icon.png")
        #expect(encodedIcon["mimeType"] == nil)
        #expect(encodedIcon["sizes"] == nil)
        #expect(encodedIcon["theme"] == nil)
    }

    @Test("server icons are disclosed only while their negotiated MCP client is ready")
    func serverIconsFollowClientLifecycle() async throws {
        let icon = try #require(MCPIcon(src: "https://example.com/server.png"))
        let server = MCPServer(configuration: MCPServerConfiguration(
            serverInfo: MCPImplementation(name: "icons", version: "1", icons: [icon])
        ))
        let client = MCPClient(transport: MCPInMemoryTransport(server: server))
        #expect(await client.serverIcons().isEmpty)

        let initialized = try await client.initialize()
        #expect(initialized.serverInfo.icons == [icon])
        #expect(await client.serverIcons() == [icon])

        await client.close()
        #expect(await client.serverIcons().isEmpty)
    }

    @Test("replacing a discovered tool snapshot evicts icons that disappeared on refresh")
    func clientSnapshotRemovesStaleIcons() async throws {
        let client = MCPClient(transport: MCPInMemoryTransport(server: MCPServer()))
        let icon = try #require(MCPIcon(src: "https://example.com/old.png"))
        await client.replaceToolIcons(["search": [icon], "empty": []])
        #expect(await client.toolIcons(named: "search") == [icon])
        #expect(await client.toolIcons(named: "empty").isEmpty)

        await client.replaceToolIcons([:])
        #expect(await client.toolIcons(named: "search").isEmpty)
        await client.close()
    }
}
