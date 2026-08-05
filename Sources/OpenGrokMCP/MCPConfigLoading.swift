// MCPConfigLoading.swift
//
// Reads MCP server declarations out of the merged config document and turns
// each one into a connectable transport.
//
// `OpenGrokConfigTypes` already models the wire shape (`McpServerConfig`,
// `McpServerTransportConfig`, `McpConfig`) but nothing ever decoded it from a
// loaded `TOMLValue` — the config loader is entirely `TOMLValue`-based and has
// no root struct. This file is that missing seam.
//
// Every failure here is per-server and non-fatal: one server with a typo must
// never take down the config load, so malformed entries are collected as
// problems and the remaining servers still connect.

import Foundation
import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokHTTP
import OpenGrokShared

/// A named server as declared in config, before any connection is attempted.
public struct MCPServerDeclaration: Sendable, Equatable {
    public var name: String
    public var config: McpServerConfig
    /// Which config layer the declaration came from, for `mcp list` output.
    public var scope: String?

    public init(name: String, config: McpServerConfig, scope: String? = nil) {
        self.name = name
        self.config = config
        self.scope = scope
    }

    public var isEnabled: Bool { config.enabled }

    /// Human-readable transport summary, matching the Rust `mcp list` column.
    public var transportSummary: String {
        switch config.transport {
        case .stdio(let command, let args, _, _):
            return ([command] + args).joined(separator: " ")
        case .streamableHttp(let url, let transportType, _, _, _, _, _):
            return transportType.map { "\($0) \(url)" } ?? url
        }
    }
}

/// A per-server config problem. Never fatal — surfaced by `mcp list`/`inspect`.
public struct MCPConfigProblem: Sendable, Equatable {
    public var server: String
    public var message: String

    public init(server: String, message: String) {
        self.server = server
        self.message = message
    }
}

public struct MCPConfigLoadResult: Sendable, Equatable {
    public var servers: [MCPServerDeclaration]
    public var problems: [MCPConfigProblem]

    public init(servers: [MCPServerDeclaration] = [], problems: [MCPConfigProblem] = []) {
        self.servers = servers
        self.problems = problems
    }

    /// Declarations that should actually be dialed.
    public var enabledServers: [MCPServerDeclaration] {
        servers.filter(\.isEnabled)
    }
}

public enum MCPConfigLoader {
    /// Table names accepted at the document root, in precedence order. The
    /// canonical spelling is `mcpServers` (matching `.mcp.json`); `mcp_servers`
    /// is the snake_case TOML alias the config types also decode.
    public static let rootTableNames = ["mcpServers", "mcp_servers"]

    /// Decode MCP server declarations from a merged config document.
    ///
    /// Servers are returned in declaration order. A server whose table fails to
    /// decode is reported in `problems` and skipped; the rest still load.
    public static func load(from document: TOMLValue, scope: String? = nil) -> MCPConfigLoadResult {
        guard let root = document.table else { return MCPConfigLoadResult() }
        var table: TOMLTable?
        for name in rootTableNames {
            if let value = root[name], let candidate = value.table {
                table = candidate
                break
            }
        }
        guard let table else { return MCPConfigLoadResult() }

        var servers: [MCPServerDeclaration] = []
        var problems: [MCPConfigProblem] = []

        for (name, value) in table.pairs {
            guard value.isTable else {
                problems.append(MCPConfigProblem(
                    server: name,
                    message: "expected a table, found \(describe(value))"
                ))
                continue
            }
            do {
                let config = try decodeServer(value)
                if let blank = blankTransportField(config) {
                    problems.append(MCPConfigProblem(
                        server: name,
                        message: "missing or empty '\(blank)'"
                    ))
                    continue
                }
                servers.append(MCPServerDeclaration(name: name, config: config, scope: scope))
            } catch {
                problems.append(MCPConfigProblem(server: name, message: describe(error)))
            }
        }
        return MCPConfigLoadResult(servers: servers, problems: problems)
    }

    /// Decode a `.mcp.json`-style document (`{"mcpServers": {...}}`).
    public static func load(jsonData: Data, scope: String? = nil) -> MCPConfigLoadResult {
        do {
            let decoded = try JSONDecoder().decode(McpConfig.self, from: jsonData)
            let servers = decoded.mcpServers.pairs.map {
                MCPServerDeclaration(name: $0.0, config: $0.1, scope: scope)
            }
            return MCPConfigLoadResult(servers: servers)
        } catch {
            return MCPConfigLoadResult(problems: [
                MCPConfigProblem(server: "(document)", message: describe(error))
            ])
        }
    }

    /// The transport decoder treats a table with neither `command` nor `url` as
    /// HTTP with an empty url rather than failing, so blankness is checked here.
    /// Returns the name of the field that is missing, or `nil` when usable.
    public static func blankTransportField(_ config: McpServerConfig) -> String? {
        switch config.transport {
        case .stdio(let command, _, _, _):
            return command.trimmingCharacters(in: .whitespaces).isEmpty ? "command" : nil
        case .streamableHttp(let url, _, _, _, _, _, _):
            return url.trimmingCharacters(in: .whitespaces).isEmpty ? "url" : nil
        }
    }

    private static func decodeServer(_ value: TOMLValue) throws -> McpServerConfig {
        let json = try JSONSerialization.data(
            withJSONObject: foundationJSON(value),
            options: [.fragmentsAllowed]
        )
        return try JSONDecoder().decode(McpServerConfig.self, from: json)
    }

    /// TOML values map onto JSON directly except datetimes, which the config
    /// types treat as opaque strings.
    static func foundationJSON(_ value: TOMLValue) -> Any {
        switch value {
        case .string(let s): return s
        case .integer(let i): return NSNumber(value: i)
        case .float(let d): return NSNumber(value: d)
        case .boolean(let b): return NSNumber(value: b)
        case .datetime(let s): return s
        case .array(let items): return items.map(foundationJSON)
        case .table(let table):
            var object: [String: Any] = [:]
            for (key, entry) in table.pairs { object[key] = foundationJSON(entry) }
            return object
        }
    }

    private static func describe(_ value: TOMLValue) -> String {
        switch value {
        case .string: return "a string"
        case .integer: return "an integer"
        case .float: return "a float"
        case .boolean: return "a boolean"
        case .datetime: return "a datetime"
        case .array: return "an array"
        case .table: return "a table"
        }
    }

    private static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else {
            return String(describing: error)
        }
        switch decoding {
        case .keyNotFound(let key, _):
            return "missing required field '\(key.stringValue)'"
        case .typeMismatch(let type, let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty
                ? "expected \(type)"
                : "field '\(path)' has the wrong type (expected \(type))"
        case .valueNotFound(let type, let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return "field '\(path)' is null (expected \(type))"
        case .dataCorrupted(let context):
            return context.debugDescription
        @unknown default:
            return String(describing: decoding)
        }
    }
}

// MARK: - Transport construction

/// Reasons a declaration cannot be turned into a live transport.
public enum MCPConnectError: Error, Sendable, Equatable, CustomStringConvertible {
    case disabled(String)
    case setupRequired(String)
    case invalidTransport(server: String, detail: String)

    public var description: String {
        switch self {
        case .disabled(let name):
            return "MCP server '\(name)' is disabled"
        case .setupRequired(let name):
            return "MCP server '\(name)' requires setup before it can connect"
        case .invalidTransport(let server, let detail):
            return "MCP server '\(server)': \(detail)"
        }
    }
}

public extension MCPServerDeclaration {
    /// Build a transport for this declaration.
    ///
    /// `stdio` spawns lazily — the child process is not started until the first
    /// `send`, so building a transport for a server whose binary is missing is
    /// not itself an error. HTTP (including `type = "sse"`, which the config
    /// types express as HTTP with a transport type rather than a separate
    /// variant) needs an injected `HTTPTransport`.
    func makeTransport(
        httpTransport: @autoclosure () -> any HTTPTransport,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> any MCPTransport {
        guard config.enabled else { throw MCPConnectError.disabled(name) }

        switch config.transport {
        case .stdio(let command, let args, let env, let cwd):
            guard !command.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw MCPConnectError.invalidTransport(server: name, detail: "empty stdio command")
            }
            return MCPStdioTransport(configuration: MCPStdioTransportConfiguration(
                command: command,
                arguments: args,
                environment: env,
                currentDirectoryPath: cwd,
                requestTimeout: TimeInterval(config.toolTimeoutSec ?? 60)
            ))

        case .streamableHttp(let url, _, let bearerTokenEnvVar, let headers, _, _, _):
            guard let endpoint = URL(string: url), endpoint.scheme != nil else {
                throw MCPConnectError.invalidTransport(
                    server: name,
                    detail: "malformed url '\(url)'"
                )
            }
            var resolved = headers ?? [:]
            if let variable = bearerTokenEnvVar,
               let token = environment[variable],
               !token.isEmpty {
                resolved["Authorization"] = "Bearer \(token)"
            }
            return MCPHTTPTransport(
                httpTransport: httpTransport(),
                configuration: MCPHTTPTransportConfiguration(
                    endpoint: endpoint,
                    headers: resolved,
                    timeout: config.toolTimeoutSec.map(TimeInterval.init)
                )
            )
        }
    }
}
