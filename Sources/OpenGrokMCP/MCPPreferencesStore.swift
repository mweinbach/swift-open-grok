// MCPPreferencesStore.swift
//
// Durable persistence for MCP server/tool enable state.
//
// Upstream stores two orthogonal disabled lists:
//
//   * `disabled_mcp_servers` — a flat array in `config.toml` naming servers
//     the user turned off (util/config/mcp.rs:803-825, :644-700).
//   * `disabled_mcp_tools` — a per-server table in `config.toml` listing
//     tool names the user individually disabled
//     (util/config/mcp.rs:991-1035, session/acp_session_impl/run_loop.rs:1486).
//
// This port persists both in `config.toml` using the same TOML shape as
// upstream so `mcp list`/`mcp inspect` (and any external reader) sees
// consistent state. Setup selections live separately in the upstream-shaped,
// owner-private `$OPENGROK_HOME/mcp_preferences.json`; corrupt preferences
// must never be replaced with an empty snapshot.
//
// Writes use the same atomic-replace path as `upsert`/`delete`
// (`writeConfigFile`), and a store write failure means the toggle did NOT
// happen (fail-closed: AGENTS.md §5).

import Foundation
import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokFileUtils

// MARK: - Setup preferences

/// Missing preferences are safe to initialize; unreadable or corrupt existing
/// preferences are readable as empty for discovery but never writable.
///
/// Mirrors `McpPreferencesLoad` in `util/config/mcp.rs:400-440`.
public enum MCPSetupPreferencesLoad: Sendable, Equatable {
    case loaded(McpPreferencesFile)
    case missing
    case corrupt

    public var file: McpPreferencesFile {
        switch self {
        case .loaded(let preferences):
            preferences
        case .missing, .corrupt:
            McpPreferencesFile()
        }
    }

    public var isWritable: Bool {
        if case .corrupt = self { return false }
        return true
    }
}

public enum MCPSetupPreferencesError: Error, Sendable, Equatable, CustomStringConvertible {
    case unreadable

    public var description: String {
        switch self {
        case .unreadable:
            "MCP preferences file is unreadable; fix or remove mcp_preferences.json before saving"
        }
    }
}

/// The setup-selection store, independent from OAuth credentials and the
/// enable/disable lists in `config.toml`.
public enum MCPSetupPreferencesStore: Sendable {
    public static let fileName = "mcp_preferences.json"
    private static let lockFileName = "mcp_preferences.lock"

    public static func path(home: URL) -> URL {
        home.appendingPathComponent(fileName)
    }

    public static func load(home: URL) -> MCPSetupPreferencesLoad {
        load(from: path(home: home))
    }

    public static func load(from path: URL) -> MCPSetupPreferencesLoad {
        guard FileManager.default.fileExists(atPath: path.path) else {
            return .missing
        }
        do {
            let data = try Data(contentsOf: path)
            let preferences = try JSONDecoder().decode(McpPreferencesFile.self, from: data)
            return .loaded(preferences)
        } catch {
            return .corrupt
        }
    }

    public static func save(_ preferences: McpPreferencesFile, home: URL) throws {
        try save(preferences, to: path(home: home))
    }

    public static func save(_ preferences: McpPreferencesFile, to path: URL) throws {
        guard load(from: path).isWritable else {
            throw MCPSetupPreferencesError.unreadable
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(preferences)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try AtomicFile.write(path, data: data, options: .ownerOnly)
        try SecureFile.ensureOwnerOnlyPermissions(at: path)
    }

    /// Reload under an owner-private cross-process lock so simultaneous ACP
    /// sessions cannot erase each other's unrelated server selections.
    @discardableResult
    public static func updateServer(
        named name: String,
        preferences: McpServerPreferences,
        home: URL
    ) throws -> McpServerPreferences? {
        try withLockedPreferences(home: home) { file in
            file.servers.updateValue(preferences, forKey: name)
        }
    }

    /// Roll back only the exact pending selection. A later successful writer
    /// must not be erased by an earlier request whose reconnect finishes late.
    @discardableResult
    public static func restoreServer(
        named name: String,
        previous: McpServerPreferences?,
        ifCurrentIs pending: McpServerPreferences,
        home: URL
    ) throws -> Bool {
        try withLockedPreferences(home: home) { file in
            guard file.servers[name] == pending else { return false }
            if let previous {
                file.servers[name] = previous
            } else {
                file.servers.removeValue(forKey: name)
            }
            return true
        }
    }

    private static func withLockedPreferences<Result>(
        home: URL,
        _ mutation: (inout McpPreferencesFile) throws -> Result
    ) throws -> Result {
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let lockPath = home.appendingPathComponent(lockFileName)
        let lock = try AdvisoryFileLock.acquire(
            at: lockPath,
            options: AdvisoryLockOptions(nonBlocking: false, create: true, mode: 0o600)
        )
        defer { lock.release() }
        try SecureFile.ensureOwnerOnlyPermissions(at: lockPath)

        let loaded = load(home: home)
        guard loaded.isWritable else {
            throw MCPSetupPreferencesError.unreadable
        }
        var file = loaded.file
        let result = try mutation(&file)
        try save(file, home: home)
        return result
    }
}

// MARK: - Disabled-server persistence

/// Read the `disabled_mcp_servers` array from a config.toml root.
///
/// Ports `apply_mcp_server_enabled`'s read half (util/config/mcp.rs:803-807).
public func disabledMCPServers(in root: TOMLValue) -> Set<String> {
    guard let table = root.table,
          let array = table["disabled_mcp_servers"]?.arrayValue else {
        return []
    }
    return Set(array.compactMap(\.stringValue))
}

/// Persist a server enable/disable to `config.toml`.
///
/// Ports `apply_mcp_server_enabled` (util/config/mcp.rs:797-831):
/// adds/removes the name in `disabled_mcp_servers` and sets the per-server
/// `enabled` field when the `[mcp_servers.<name>]` entry exists.
public func applyMCPServerEnabled(
    _ name: String,
    enabled: Bool,
    in root: inout TOMLValue
) throws {
    guard var table = root.table else { throw TOMLWriteError.rootIsNotATable }

    var disabledList: [String] = table["disabled_mcp_servers"]?.arrayValue?
        .compactMap(\.stringValue) ?? []

    if enabled {
        disabledList.removeAll { $0 == name }
    } else if !disabledList.contains(name) {
        disabledList.append(name)
    }

    if disabledList.isEmpty {
        _ = table.removeValue(forKey: "disabled_mcp_servers")
    } else {
        table.insert(
            .array(disabledList.map(TOMLValue.string)),
            forKey: "disabled_mcp_servers"
        )
    }

    setMCPServerEnabledField(name, enabled: enabled, in: &table)
    root = .table(table)
}

/// Set the `enabled` field on a declared `[mcp_servers.<name>]` entry when it
/// exists. Does nothing if the server is not declared inline.
///
/// Ports `set_mcp_server_enabled_field` (util/config/mcp.rs:838-855).
private func setMCPServerEnabledField(
    _ name: String,
    enabled: Bool,
    in table: inout TOMLTable
) {
    let tableName = MCPServerTableName.resolved(in: table)
    guard var servers = table[tableName]?.table,
          var entry = servers[name]?.table else {
        return
    }
    entry.insert(.boolean(enabled), forKey: "enabled")
    servers.insert(.table(entry), forKey: name)
    table.insert(.table(servers), forKey: tableName)
}

// MARK: - Disabled-tool persistence

/// Read the full `disabled_mcp_tools` map from a config.toml root.
///
/// Ports `get_all_mcp_disabled_tools` (util/config/mcp.rs:991-1035).
/// Returns `{ serverName: Set<toolName> }`.
public func allDisabledMCPTools(in root: TOMLValue) -> [String: Set<String>] {
    guard let table = root.table,
          let section = table["disabled_mcp_tools"]?.table else {
        return [:]
    }
    var result: [String: Set<String>] = [:]
    for (server, value) in section.pairs {
        guard let tools = value.arrayValue else { continue }
        let names = Set(tools.compactMap(\.stringValue))
        if !names.isEmpty {
            result[server] = names
        }
    }
    return result
}

/// Persist a per-tool enable/disable to `config.toml`.
///
/// Ports the session's `ToggleMcpTool` command handling
/// (run_loop.rs:1486-1490): inserts or removes the tool name in
/// `[disabled_mcp_tools.<server_name>]`.
public func applyMCPToolEnabled(
    server: String,
    tool: String,
    enabled: Bool,
    in root: inout TOMLValue
) throws {
    guard var table = root.table else { throw TOMLWriteError.rootIsNotATable }

    var section: TOMLTable = table["disabled_mcp_tools"]?.table ?? TOMLTable()
    var tools: [String] = section[server]?.arrayValue?
        .compactMap(\.stringValue) ?? []

    if enabled {
        tools.removeAll { $0 == tool }
    } else if !tools.contains(tool) {
        tools.append(tool)
    }

    if tools.isEmpty {
        _ = section.removeValue(forKey: server)
    } else {
        section.insert(.array(tools.map(TOMLValue.string)), forKey: server)
    }

    if section.isEmpty {
        _ = table.removeValue(forKey: "disabled_mcp_tools")
    } else {
        table.insert(.table(section), forKey: "disabled_mcp_tools")
    }

    root = .table(table)
}
