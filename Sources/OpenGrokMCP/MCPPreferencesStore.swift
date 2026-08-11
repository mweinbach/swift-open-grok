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
// consistent state. The `mcp_preferences.json` file upstream also uses for
// setup-schema values is NOT ported here because setup is deferred (no
// setup-schema surface); its server entries are unrelated to the toggle
// disabled lists.
//
// Writes use the same atomic-replace path as `upsert`/`delete`
// (`writeConfigFile`), and a store write failure means the toggle did NOT
// happen (fail-closed: AGENTS.md §5).

import Foundation
import OpenGrokConfig

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
