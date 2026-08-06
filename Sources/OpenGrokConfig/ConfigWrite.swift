// ConfigWrite.swift
//
// Writing config.toml back to disk.
//
// Upstream does **not** use `toml_edit` for this. `mcp add` / `mcp remove` go
// through `xai-grok-shell/src/util/config/mcp.rs`
// (`save_mcp_server_config_at:860`, `delete_mcp_server_config_at:918`), which
// parse the file into a plain `toml::Value`, mutate the tree, and re-serialize
// with `toml::to_string_pretty` — comments and original formatting are lost by
// design. `toml_edit` is used upstream only by the pager for its own
// non-config surfaces (hints, agents, personas, plugins:
// `xai-grok-pager/src/config_toml_edit.rs`).
//
// So the faithful port is a plain serializer plus the same table surgery, not
// a format-preserving editor. The shell crate enables toml's `preserve_order`
// feature (`xai-grok-shell/Cargo.toml:65`), and `TOMLTable` likewise preserves
// insertion order, so key order survives the round-trip even though comments
// do not.

import Foundation
import OpenGrokConfigTypes

// MARK: - Bridging Codable values into TOMLValue

/// Errors raised while turning a value into TOML.
public enum TOMLWriteError: Error, CustomStringConvertible, Equatable {
    /// The document root was not a table, so it cannot be serialized.
    case rootIsNotATable
    /// A named key exists but holds a non-table where a table is required.
    case notATable(String)
    /// A value has no TOML representation (e.g. a JSON `null`).
    case unrepresentable(String)

    public var description: String {
        switch self {
        case .rootIsNotATable:
            return "config root is not a table"
        case let .notATable(key):
            return "\(key) is not a table"
        case let .unrepresentable(what):
            return "value has no TOML representation: \(what)"
        }
    }
}

extension TOMLValue {
    /// Encode any `Encodable` into a `TOMLValue`, mirroring upstream's
    /// `toml::Value::try_from(config)`.
    ///
    /// Routes through JSON so the type's own `Codable` conformance (including
    /// the flattened MCP transport keys and snake_case renames) is the single
    /// source of truth for the on-disk shape. TOML has no null, so `nil`
    /// fields — which all encode via `encodeIfPresent` — are simply absent.
    public static func encoding<T: Encodable>(_ value: T) throws -> TOMLValue {
        let data = try JSONEncoder().encode(value)
        let json = try JSONSerialization.jsonObject(
            with: data, options: [.fragmentsAllowed]
        )
        return try TOMLValue(jsonObject: json)
    }

    /// Convert a `JSONSerialization` object graph into TOML.
    ///
    /// `null` has no TOML spelling. It only appears here for a field that
    /// explicitly encoded a null (never from `encodeIfPresent`), so dropping
    /// it silently would hide a real encoding bug — it throws instead.
    init(jsonObject: Any) throws {
        switch jsonObject {
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            self = .array(try value.map { try TOMLValue(jsonObject: $0) })
        case let value as [String: Any]:
            var table = TOMLTable()
            // JSON objects are unordered; sort so output is deterministic.
            for key in value.keys.sorted() {
                table.insert(try TOMLValue(jsonObject: value[key]!), forKey: key)
            }
            self = .table(table)
        case let value as NSNumber:
            // `NSNumber` erases Bool into a number, so identify booleans by
            // representation rather than casting to `Bool` (which matches `1`).
            let encoding = String(cString: value.objCType)
            #if canImport(Darwin)
            let isBoolean = CFGetTypeID(value) == CFBooleanGetTypeID()
            #else
            // swift-corelibs-foundation exposes no CoreFoundation type IDs.
            // Its JSON booleans are `__NSCFBoolean`, the only NSNumber
            // `JSONSerialization` yields with the "c" encoding — integers
            // come back as "i" or "q", floats as "d".
            let isBoolean = encoding == "c"
            #endif
            if isBoolean {
                self = .boolean(value.boolValue)
            } else if encoding == "d" || encoding == "f" {
                self = .float(value.doubleValue)
            } else {
                // Read the integer straight off the NSNumber. Going via
                // `doubleValue` would silently round integers above 2^53, and
                // these are timeouts and ports, not approximations.
                self = .integer(value.int64Value)
            }
        case is NSNull:
            throw TOMLWriteError.unrepresentable("null")
        default:
            throw TOMLWriteError.unrepresentable(String(describing: type(of: jsonObject)))
        }
    }
}

// MARK: - Atomic file write

/// Serialize `root` and replace the file at `path` atomically.
///
/// Mirrors upstream's write tail (`mcp.rs:894-900`): create the parent
/// directory, write a sibling `<stem>.toml.tmp`, then rename over the target
/// so a concurrent reader never observes a half-written config.
public func writeConfigFile(_ root: TOMLValue, to path: URL) throws {
    guard root.isTable else { throw TOMLWriteError.rootIsNotATable }
    let text = TOMLEncoder.encode(root)
    let parent = path.deletingLastPathComponent()
    try? FileManager.default.createDirectory(
        at: parent, withIntermediateDirectories: true
    )
    let temporary = path.deletingPathExtension().appendingPathExtension("toml.tmp")
    try Data(text.utf8).write(to: temporary, options: .atomic)
    // `replaceItemAt` requires an existing original, so a first write — the
    // common case for a project config — has to move the temp file into place
    // instead. Both paths leave no `.toml.tmp` behind.
    if FileManager.default.fileExists(atPath: path.path) {
        _ = try FileManager.default.replaceItemAt(path, withItemAt: temporary)
    } else {
        do {
            try FileManager.default.moveItem(at: temporary, to: path)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}

// MARK: - MCP server table surgery

/// The config root table that holds MCP server declarations.
///
/// Upstream writes `mcp_servers` (`mcp.rs:875`). `MCPConfigLoader` also reads
/// the `.mcp.json`-style `mcpServers`, so an edit targets whichever spelling
/// the file already uses and falls back to the upstream one.
public enum MCPServerTableName {
    public static let canonical = "mcp_servers"
    public static let alias = "mcpServers"

    /// The spelling already present in `root`, else `canonical`.
    public static func resolved(in root: TOMLTable) -> String {
        if root[canonical]?.isTable == true { return canonical }
        if root[alias]?.isTable == true { return alias }
        return canonical
    }
}

/// Insert or replace `[mcp_servers.<name>]` in `root`.
///
/// Ports `save_mcp_server_config_at` (`mcp.rs:860-902`): upsert the server
/// table, then drop the name from `disabled_mcp_servers` so a newly defined
/// server starts enabled, removing that array entirely once it empties.
public func upsertMCPServer(
    _ name: String,
    config: McpServerConfig,
    in root: inout TOMLValue
) throws {
    guard var table = root.table else { throw TOMLWriteError.rootIsNotATable }
    let tableName = MCPServerTableName.resolved(in: table)

    var servers: TOMLTable
    switch table[tableName] {
    case .none:
        servers = TOMLTable()
    case let .some(existing):
        guard let inner = existing.table else {
            throw TOMLWriteError.notATable(tableName)
        }
        servers = inner
    }
    servers.insert(try TOMLValue.encoding(config), forKey: name)
    table.insert(.table(servers), forKey: tableName)

    removeFromDisabledServers(name, in: &table)
    root = .table(table)
}

/// Remove `[mcp_servers.<name>]` from `root`. Returns `false` — leaving `root`
/// untouched — when the entry was not present.
///
/// Ports `delete_mcp_server_config_at` (`mcp.rs:918-988`): remove the entry,
/// drop the now-empty `mcp_servers` table, drop the name from
/// `disabled_mcp_servers`, and drop its `[disabled_mcp_tools.<name>]` entry.
///
/// Upstream additionally purges the server's OAuth credentials from the global
/// store (`mcp.rs:979-985`); that store is not wired into this build, so
/// credentials for a removed server are left in place.
@discardableResult
public func removeMCPServer(_ name: String, from root: inout TOMLValue) throws -> Bool {
    guard var table = root.table else { throw TOMLWriteError.rootIsNotATable }
    let tableName = MCPServerTableName.resolved(in: table)

    guard var servers = table[tableName]?.table,
          servers.removeValue(forKey: name) != nil else {
        return false
    }

    // An emptied server table would otherwise leave a bare `[mcp_servers]`
    // header behind.
    if servers.isEmpty {
        _ = table.removeValue(forKey: tableName)
    } else {
        table.insert(.table(servers), forKey: tableName)
    }

    removeFromDisabledServers(name, in: &table)

    if var disabledTools = table["disabled_mcp_tools"]?.table {
        _ = disabledTools.removeValue(forKey: name)
        if disabledTools.isEmpty {
            _ = table.removeValue(forKey: "disabled_mcp_tools")
        } else {
            table.insert(.table(disabledTools), forKey: "disabled_mcp_tools")
        }
    }

    root = .table(table)
    return true
}

/// Whether `[mcp_servers.<name>]` is declared in `root`.
///
/// Ports `mcp_server_defined_at` (`mcp.rs:1699-1706`), which deliberately
/// checks raw key presence rather than decoding: a server whose table fails to
/// deserialize must still be removable.
public func mcpServerIsDefined(_ name: String, in root: TOMLValue) -> Bool {
    guard let table = root.table else { return false }
    for candidate in [MCPServerTableName.canonical, MCPServerTableName.alias] {
        if table[candidate]?.table?.contains(name) == true { return true }
    }
    return false
}

/// Drop `name` from `disabled_mcp_servers`, removing the array once empty.
private func removeFromDisabledServers(_ name: String, in table: inout TOMLTable) {
    guard let array = table["disabled_mcp_servers"]?.arrayValue else { return }
    let remaining = array.filter { $0.stringValue != name }
    if remaining.isEmpty {
        _ = table.removeValue(forKey: "disabled_mcp_servers")
    } else {
        table.insert(.array(remaining), forKey: "disabled_mcp_servers")
    }
}
