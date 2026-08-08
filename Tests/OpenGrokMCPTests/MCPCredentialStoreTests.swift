// MCPCredentialStoreTests.swift
//
// The mcp_credentials.json store against upstream's on-disk shape
// (xai-grok-mcp/src/credentials.rs at 650c1db7). The legacy fixture below is
// the byte-identical JSON literal from credentials.rs:465-482 — a file the
// Rust build persisted must load here unchanged and survive a rewrite.
// Assertions parse JSON (never substring-match): the encoder escapes nothing
// here, but the E4/E6 lesson stands.

import Foundation
import OpenGrokShared
import Testing
@testable import OpenGrokMCP

private func makeHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("opengrok-mcp-creds-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}

private func fileMode(_ path: URL) throws -> Int {
    let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
    let posix = try #require(attrs[.posixPermissions] as? NSNumber)
    return posix.intValue & 0o777
}

private func parseStoreJSON(at path: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: path)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Suite("MCP credential store")
struct MCPCredentialStoreTests {

    /// credentials.rs:461-513 — the exact rmcp 0.17-era fixture. It must
    /// keep loading, and a round-trip through this port's serializer must
    /// keep every field.
    @Test("legacy on-disk fixture still deserializes and round-trips")
    func legacyFixtureRoundTrips() throws {
        let fixture = """
        {
            "linear:https://mcp.example.com/mcp": {
                "client_id": "legacy-client-id",
                "token_response": {
                    "access_token": "at-123",
                    "token_type": "bearer",
                    "expires_in": 3600,
                    "refresh_token": "rt-456",
                    "scope": "read write"
                },
                "granted_scopes": ["read", "write"],
                "token_received_at": 1730000000
            },
            "noauth:https://example.com/mcp": {
                "client_id": "c2",
                "token_response": null
            }
        }
        """
        let entries = try JSONDecoder().decode(
            [String: MCPStoredCredentials].self, from: Data(fixture.utf8))
        let store = MCPCredentialStore(entries: entries)

        let url = try #require(URL(string: "https://mcp.example.com/mcp"))
        let creds = try #require(store.get(serverName: "linear", serverURL: url))
        #expect(creds.clientId == "legacy-client-id")
        let token = try #require(creds.tokenResponse)
        #expect(token.accessToken == "at-123")
        #expect(token.refreshToken == "rt-456")
        #expect(token.expiresIn == 3600)
        #expect(creds.grantedScopes == ["read", "write"])
        #expect(creds.tokenReceivedAt == 1_730_000_000)

        // Entry without the defaulted fields still loads.
        let url2 = try #require(URL(string: "https://example.com/mcp"))
        let creds2 = try #require(store.get(serverName: "noauth", serverURL: url2))
        #expect(creds2.tokenResponse == nil)
        #expect(creds2.grantedScopes.isEmpty)
        #expect(creds2.tokenReceivedAt == nil)

        // Round-trip through the current serializer and reload.
        let encoded = try JSONEncoder().encode(store.entries)
        let reloaded = try JSONDecoder().decode([String: MCPStoredCredentials].self, from: encoded)
        let re = try #require(reloaded["linear:https://mcp.example.com/mcp"])
        #expect(re.clientId == "legacy-client-id")
        let reToken = try #require(re.tokenResponse)
        #expect(reToken.accessToken == "at-123")
        #expect(reToken.refreshToken == "rt-456")
        #expect(re.grantedScopes == ["read", "write"])
        #expect(re.tokenReceivedAt == 1_730_000_000)
    }

    @Test("vendor extra token fields survive a store rewrite")
    func vendorExtrasSurvive() throws {
        let json = """
        {"access_token":"at","token_type":"bearer","vendorSpecificField":{"nested":true}}
        """
        let token = try JSONDecoder().decode(MCPOAuthTokenResponse.self, from: Data(json.utf8))
        #expect(token.extraFields["vendorSpecificField"] == .object(["nested": .bool(true)]))

        let re = try JSONDecoder().decode(
            MCPOAuthTokenResponse.self, from: JSONEncoder().encode(token))
        #expect(re.extraFields["vendorSpecificField"] == .object(["nested": .bool(true)]))
        #expect(re.accessToken == "at")
    }

    @Test("entry keys pin the Rust url::Url display shapes")
    func keyFormat() throws {
        // Path-bearing URL: unchanged (credentials.rs:83-85 + the fixture key).
        #expect(MCPCredentialStore.key(
            serverName: "linear",
            serverURL: URL(string: "https://mcp.example.com/mcp")!
        ) == "linear:https://mcp.example.com/mcp")
        // Bare authority gains "/" and casing/default port normalize, the way
        // Rust `Url` prints.
        #expect(MCPCredentialStore.key(
            serverName: "srv",
            serverURL: URL(string: "HTTPS://Example.COM:443")!
        ) == "srv:https://example.com/")
    }

    @Test("save is owner-only from the first byte")
    func saveIsOwnerOnly() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let path = MCPCredentialStore.defaultPath(home: home)

        var store = MCPCredentialStore()
        store.insert(
            serverName: "test",
            serverURL: URL(string: "https://test.example.com/mcp")!,
            credentials: MCPStoredCredentials(clientId: "c")
        )
        try store.save(to: path)
        #expect(try fileMode(path) == 0o600)
    }

    @Test("load tightens a world-readable credential file")
    func loadTightens() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let path = MCPCredentialStore.defaultPath(home: home)
        var store = MCPCredentialStore()
        store.insert(
            serverName: "test",
            serverURL: URL(string: "https://test.example.com/mcp")!,
            credentials: MCPStoredCredentials(clientId: "c")
        )
        try store.save(to: path)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: path.path)

        _ = try MCPCredentialStore.load(from: path)
        #expect(try fileMode(path) == 0o600)
    }

    @Test("stale save does not clobber a newer disk entry")
    func freshnessGuard() throws {
        // Unit table from credentials.rs:569-602.
        let older = MCPStoredCredentials(clientId: "c", tokenReceivedAt: 1_000)
        let newer = MCPStoredCredentials(clientId: "c", tokenReceivedAt: 2_000)
        let noTS = MCPStoredCredentials(clientId: "c")
        #expect(mcpDiskEntryIsNewer(existing: newer, incoming: older))
        #expect(!mcpDiskEntryIsNewer(existing: older, incoming: newer))
        #expect(!mcpDiskEntryIsNewer(existing: older, incoming: older))
        #expect(!mcpDiskEntryIsNewer(existing: nil, incoming: older))
        #expect(!mcpDiskEntryIsNewer(existing: newer, incoming: noTS))
        #expect(!mcpDiskEntryIsNewer(existing: noTS, incoming: older))

        // And through the real locked write path.
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = URL(string: "https://test.example.com/mcp")!
        try MCPCredentialStore.insertAndSave(
            home: home, serverName: "s", serverURL: url,
            credentials: MCPStoredCredentials(
                clientId: "c",
                tokenResponse: MCPOAuthTokenResponse(accessToken: "fresh"),
                tokenReceivedAt: 2_000
            )
        )
        try MCPCredentialStore.insertAndSave(
            home: home, serverName: "s", serverURL: url,
            credentials: MCPStoredCredentials(
                clientId: "c",
                tokenResponse: MCPOAuthTokenResponse(accessToken: "stale"),
                tokenReceivedAt: 1_000
            )
        )
        let reloaded = MCPCredentialStore.loadOrEmpty(
            from: MCPCredentialStore.defaultPath(home: home))
        let entry = try #require(reloaded.get(serverName: "s", serverURL: url))
        #expect(entry.tokenResponse?.accessToken == "fresh")
        #expect(entry.tokenReceivedAt == 2_000)
    }

    @Test("locked mutate merges concurrent writers instead of clobbering")
    func lockedMutateMerges() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let urlA = URL(string: "https://a.example.com/mcp")!
        let urlB = URL(string: "https://b.example.com/mcp")!

        // Writer 1 lands entry A.
        try MCPCredentialStore.insertAndSave(
            home: home, serverName: "a", serverURL: urlA,
            credentials: MCPStoredCredentials(clientId: "ca"))
        // Writer 2 (a different in-memory view) lands entry B; the locked
        // reload must merge, not overwrite A.
        try MCPCredentialStore.insertAndSave(
            home: home, serverName: "b", serverURL: urlB,
            credentials: MCPStoredCredentials(clientId: "cb"))

        let object = try parseStoreJSON(at: MCPCredentialStore.defaultPath(home: home))
        #expect(object.count == 2)
        #expect(object["a:https://a.example.com/mcp"] != nil)
        #expect(object["b:https://b.example.com/mcp"] != nil)
    }

    @Test("corrupt store recovers to empty and the next write heals the file")
    func corruptRecovery() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let path = MCPCredentialStore.defaultPath(home: home)
        try Data("{not json!".utf8).write(to: path)

        // Loading throws; the adapter-path load recovers to empty
        // (credentials.rs unwrap_or_default call sites).
        #expect(throws: MCPCredentialStoreError.self) {
            _ = try MCPCredentialStore.load(from: path)
        }
        #expect(MCPCredentialStore.loadOrEmpty(from: path).isEmpty)

        // A locked insert on top of the corrupt file heals it.
        let url = URL(string: "https://test.example.com/mcp")!
        try MCPCredentialStore.insertAndSave(
            home: home, serverName: "s", serverURL: url,
            credentials: MCPStoredCredentials(
                clientId: "c",
                tokenResponse: MCPOAuthTokenResponse(accessToken: "at")
            )
        )
        let object = try parseStoreJSON(at: path)
        let entry = try #require(object["s:https://test.example.com/mcp"] as? [String: Any])
        #expect(entry["client_id"] as? String == "c")
        let token = try #require(entry["token_response"] as? [String: Any])
        #expect(token["access_token"] as? String == "at")
    }

    @Test("removeAndSave deletes exactly one server's entry under the lock")
    func removeAndSave() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let urlA = URL(string: "https://a.example.com/mcp")!
        let urlB = URL(string: "https://b.example.com/mcp")!
        try MCPCredentialStore.insertAndSave(
            home: home, serverName: "a", serverURL: urlA,
            credentials: MCPStoredCredentials(clientId: "ca"))
        try MCPCredentialStore.insertAndSave(
            home: home, serverName: "b", serverURL: urlB,
            credentials: MCPStoredCredentials(clientId: "cb"))

        try MCPCredentialStore.removeAndSave(home: home, serverName: "a", serverURL: urlA)

        let object = try parseStoreJSON(at: MCPCredentialStore.defaultPath(home: home))
        #expect(object["a:https://a.example.com/mcp"] == nil)
        #expect(object["b:https://b.example.com/mcp"] != nil)
    }

    @Test("file storage adapter reads through disk for cross-process tokens")
    func fileStorageAdapter() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = URL(string: "https://test.example.com/mcp")!
        let storage = MCPFileCredentialStorage(home: home, serverName: "s", serverURL: url)
        #expect(try storage.load() == nil)

        // "Another process" writes the store directly.
        try MCPCredentialStore.insertAndSave(
            home: home, serverName: "s", serverURL: url,
            credentials: MCPStoredCredentials(
                clientId: "c",
                tokenResponse: MCPOAuthTokenResponse(accessToken: "external")
            )
        )
        #expect(try storage.load()?.tokenResponse?.accessToken == "external")

        try storage.clear()
        #expect(try storage.load() == nil)
    }
}
