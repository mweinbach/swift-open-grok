// Mcp.swift
//
// Port of `xai-grok-config-types/src/mcp.rs`.
//
// MCP server configuration value types. `McpOAuthConfig` is defined locally
// here (mirroring `xai-grok-mcp::oauth_config::McpOAuthConfig`) because
// `OpenGrokConfigTypes` cannot depend on `OpenGrokMCP` (W5-S4). The wire form
// is identical. See the module doc for the consolidation plan.

import Foundation
import OpenGrokShared

// MARK: - McpOAuthConfig (local; see module doc)

/// OAuth configuration extracted from an MCP server's config. Constructed by
/// the host's TOML parsing (`McpServerConfig.oauthConfig`) and consumed by
/// the MCP OAuth flow.
public struct McpOAuthConfig: Hashable, Sendable, Equatable {
    public var clientId: String?
    public var clientSecret: String?
    public var scopes: [String]?
    public var callbackPort: UInt16?

    public init(
        clientId: String? = nil,
        clientSecret: String? = nil,
        scopes: [String]? = nil,
        callbackPort: UInt16? = nil
    ) {
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.scopes = scopes
        self.callbackPort = callbackPort
    }

    /// `true` when this server has OAuth configured (a client_id is set).
    public var isConfigured: Bool { clientId != nil }
}

// MARK: - McpServerTransportConfig

/// One MCP server's transport config. `Stdio` runs a local command;
/// `StreamableHttp` connects to an HTTP/SSE endpoint. Mirrors the Rust
/// `#[serde(untagged)]` enum: a JSON object with `command` → `.stdio`,
/// otherwise `.streamableHttp` (with `url`/`urlTemplate`/`url_template`
/// aliases accepted).
public enum McpServerTransportConfig: Hashable, Sendable, Codable, Equatable {
    case stdio(command: String, args: [String], env: [String: String]?, cwd: String?)
    case streamableHttp(
        url: String,
        transportType: String?,
        bearerTokenEnvVar: String?,
        headers: [String: String]?,
        oauthClientId: String?,
        oauthClientSecretEnvVar: String?,
        oauthScopes: [String]?
    )

    public init(from decoder: Decoder) throws {
        let dynamic = try decoder.container(keyedBy: AnyCodingKey.self)
        // `command` presence ⇒ Stdio.
        if dynamic.contains(AnyCodingKey("command")) {
            let command = try dynamic.decode(String.self, forKey: AnyCodingKey("command"))
            let args = try dynamic.decodeIfPresent([String].self, forKey: AnyCodingKey("args")) ?? []
            let env = try dynamic.decodeIfPresent([String: String].self, forKey: AnyCodingKey("env"))
            let cwd = try dynamic.decodeIfPresent(String.self, forKey: AnyCodingKey("cwd"))
            self = .stdio(command: command, args: args, env: env, cwd: cwd)
            return
        }
        // Otherwise StreamableHttp — accept `url` / `urlTemplate` / `url_template`.
        let url: String
        if let s = try dynamic.decodeIfPresent(String.self, forKey: AnyCodingKey("url")) {
            url = s
        } else if let s = try dynamic.decodeIfPresent(String.self, forKey: AnyCodingKey("urlTemplate")) {
            url = s
        } else if let s = try dynamic.decodeIfPresent(String.self, forKey: AnyCodingKey("url_template")) {
            url = s
        } else {
            url = ""
        }
        let transportType = try dynamic.decodeIfPresent(String.self, forKey: AnyCodingKey("type"))
        let bearerTokenEnvVar = try dynamic.decodeIfPresent(String.self, forKey: AnyCodingKey("bearer_token_env_var"))
        let headers = try dynamic.decodeIfPresent([String: String].self, forKey: AnyCodingKey("headers"))
        let oauthClientId = try dynamic.decodeIfPresent(String.self, forKey: AnyCodingKey("oauth_client_id"))
        let oauthClientSecretEnvVar = try dynamic.decodeIfPresent(String.self, forKey: AnyCodingKey("oauth_client_secret_env_var"))
        let oauthScopes = try dynamic.decodeIfPresent([String].self, forKey: AnyCodingKey("oauth_scopes"))
        self = .streamableHttp(
            url: url,
            transportType: transportType,
            bearerTokenEnvVar: bearerTokenEnvVar,
            headers: headers,
            oauthClientId: oauthClientId,
            oauthClientSecretEnvVar: oauthClientSecretEnvVar,
            oauthScopes: oauthScopes
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        switch self {
        case let .stdio(command, args, env, cwd):
            try c.encode(command, forKey: AnyCodingKey("command"))
            try c.encode(args, forKey: AnyCodingKey("args"))
            try c.encodeIfPresent(env, forKey: AnyCodingKey("env"))
            try c.encodeIfPresent(cwd, forKey: AnyCodingKey("cwd"))
        case let .streamableHttp(url, transportType, bearerTokenEnvVar, headers, oauthClientId, oauthClientSecretEnvVar, oauthScopes):
            try c.encode(url, forKey: AnyCodingKey("url"))
            try c.encodeIfPresent(transportType, forKey: AnyCodingKey("type"))
            try c.encodeIfPresent(bearerTokenEnvVar, forKey: AnyCodingKey("bearer_token_env_var"))
            try c.encodeIfPresent(headers, forKey: AnyCodingKey("headers"))
            try c.encodeIfPresent(oauthClientId, forKey: AnyCodingKey("oauth_client_id"))
            try c.encodeIfPresent(oauthClientSecretEnvVar, forKey: AnyCodingKey("oauth_client_secret_env_var"))
            try c.encodeIfPresent(oauthScopes, forKey: AnyCodingKey("oauth_scopes"))
        }
    }
}

// MARK: - McpJsonOAuthBlock

/// The `[oauth]` sub-table inside an MCP server config. camelCase wire form
/// (Rust `#[serde(rename_all = "camelCase")]`).
public struct McpJsonOAuthBlock: Hashable, Sendable, Codable, Equatable {
    public var clientId: String?
    public var clientSecretEnvVar: String?
    public var scopes: [String]?
    public var callbackPort: UInt16?

    public init(
        clientId: String? = nil, clientSecretEnvVar: String? = nil,
        scopes: [String]? = nil, callbackPort: UInt16? = nil
    ) {
        self.clientId = clientId
        self.clientSecretEnvVar = clientSecretEnvVar
        self.scopes = scopes
        self.callbackPort = callbackPort
    }

    private enum CodingKeys: String, CodingKey {
        case clientId = "clientId"
        case clientSecretEnvVar = "clientSecretEnvVar"
        case scopes
        case callbackPort = "callbackPort"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clientId = try c.decodeIfPresent(String.self, forKey: .clientId)
        clientSecretEnvVar = try c.decodeIfPresent(String.self, forKey: .clientSecretEnvVar)
        scopes = try c.decodeIfPresent([String].self, forKey: .scopes)
        callbackPort = try c.decodeIfPresent(UInt16.self, forKey: .callbackPort)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(clientId, forKey: .clientId)
        try c.encodeIfPresent(clientSecretEnvVar, forKey: .clientSecretEnvVar)
        try c.encodeIfPresent(scopes, forKey: .scopes)
        try c.encodeIfPresent(callbackPort, forKey: .callbackPort)
    }
}

// MARK: - McpSetupConfig

/// MCP setup schema (v0: exactly one select field).
public struct McpSetupConfig: Hashable, Sendable, Codable, Equatable {
    public var fields: [McpSetupField]
    /// Derived-variable map (Rust `alias = "values"`).
    public var variables: [String: McpSetupDerivedValue]

    public init(fields: [McpSetupField] = [], variables: [String: McpSetupDerivedValue] = [:]) {
        self.fields = fields
        self.variables = variables
    }

    private enum CodingKeys: String, CodingKey { case fields, variables }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fields = try c.decodeIfPresent([McpSetupField].self, forKey: .fields) ?? []
        variables = try c.decodeIfPresent([String: McpSetupDerivedValue].self, forKey: .variables) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(fields, forKey: .fields)
        try c.encode(variables, forKey: .variables)
    }
}

public struct McpSetupField: Hashable, Sendable, Codable, Equatable {
    public var id: String
    public var label: String
    public var fieldType: McpSetupFieldType
    public var required: Bool
    public var `default`: String?
    public var options: [McpSetupOption]

    public init(
        id: String, label: String, fieldType: McpSetupFieldType = .select,
        required: Bool = false, default: String? = nil, options: [McpSetupOption] = []
    ) {
        self.id = id
        self.label = label
        self.fieldType = fieldType
        self.required = required
        self.default = `default`
        self.options = options
    }

    private enum CodingKeys: String, CodingKey {
        case id, label
        case fieldType = "type"
        case required
        case `default`
        case options
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        fieldType = try c.decodeIfPresent(McpSetupFieldType.self, forKey: .fieldType) ?? .select
        required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? false
        `default` = try c.decodeIfPresent(String.self, forKey: .default)
        options = try c.decodeIfPresent([McpSetupOption].self, forKey: .options) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(label, forKey: .label)
        try c.encode(fieldType, forKey: .fieldType)
        try c.encode(required, forKey: .required)
        try c.encodeIfPresent(`default`, forKey: .default)
        try c.encode(options, forKey: .options)
    }
}

public enum McpSetupFieldType: String, Sendable, Codable, Hashable, Equatable {
    case select
}

public struct McpSetupOption: Hashable, Sendable, Codable, Equatable {
    public var label: String
    public var value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

public struct McpSetupDerivedValue: Hashable, Sendable, Codable, Equatable {
    public var from: String
    public var map: [String: String]

    public init(from: String, map: [String: String] = [:]) {
        self.from = from
        self.map = map
    }
}

// MARK: - McpPreferences

public struct McpPreferenceSource: Hashable, Sendable, Codable, Equatable {
    public var kind: String
    public var plugin: String?
    public var scope: String?

    public init(kind: String, plugin: String? = nil, scope: String? = nil) {
        self.kind = kind
        self.plugin = plugin
        self.scope = scope
    }

    private enum CodingKeys: String, CodingKey {
        case kind, plugin, scope
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        plugin = try c.decodeIfPresent(String.self, forKey: .plugin)
        scope = try c.decodeIfPresent(String.self, forKey: .scope)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(plugin, forKey: .plugin)
        try c.encodeIfPresent(scope, forKey: .scope)
    }
}

public struct McpServerPreferences: Hashable, Sendable, Codable, Equatable {
    public var values: [String: String]
    public var source: McpPreferenceSource?
    public var updatedAt: String?

    public init(values: [String: String] = [:], source: McpPreferenceSource? = nil, updatedAt: String? = nil) {
        self.values = values
        self.source = source
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case values
        case source
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        values = try c.decodeIfPresent([String: String].self, forKey: .values) ?? [:]
        source = try c.decodeIfPresent(McpPreferenceSource.self, forKey: .source)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(values, forKey: .values)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
    }
}

public struct McpPreferencesFile: Hashable, Sendable, Codable, Equatable {
    public var version: UInt32
    public var servers: [String: McpServerPreferences]

    public init(version: UInt32 = 1, servers: [String: McpServerPreferences] = [:]) {
        self.version = version
        self.servers = servers
    }

    private enum CodingKeys: String, CodingKey { case version, servers }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(UInt32.self, forKey: .version) ?? 1
        servers = try c.decodeIfPresent([String: McpServerPreferences].self, forKey: .servers) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(servers, forKey: .servers)
    }
}

// MARK: - McpSetupResolution

/// Result of resolving a server's `setup` templates against stored preferences.
public enum McpSetupResolution: Equatable, Sendable {
    /// Setup fully resolved; the returned config is ready to use.
    case resolved(McpServerConfig)
    /// Setup required but no preference supplied; caller must collect one.
    case required(McpSetupConfig)
    /// Setup schema or preference is invalid (caller surfaces an error).
    case invalid(String)
}

// MARK: - McpServerConfig

/// One MCP server's full config: transport, enabled flag, optional OAuth
/// block, optional setup schema, and per-tool timeout overrides.
public struct McpServerConfig: Hashable, Sendable, Codable, Equatable {
    public var transport: McpServerTransportConfig
    public var enabled: Bool
    public var oauth: McpJsonOAuthBlock?
    public var setup: McpSetupConfig?
    public var startupTimeoutSec: UInt64?
    public var toolTimeoutSec: UInt64?
    public var toolTimeouts: [String: UInt64]?
    public var exposeImageBase64: Bool?

    public init(
        transport: McpServerTransportConfig,
        enabled: Bool = true,
        oauth: McpJsonOAuthBlock? = nil,
        setup: McpSetupConfig? = nil,
        startupTimeoutSec: UInt64? = nil,
        toolTimeoutSec: UInt64? = nil,
        toolTimeouts: [String: UInt64]? = nil,
        exposeImageBase64: Bool? = nil
    ) {
        self.transport = transport
        self.enabled = enabled
        self.oauth = oauth
        self.setup = setup
        self.startupTimeoutSec = startupTimeoutSec
        self.toolTimeoutSec = toolTimeoutSec
        self.toolTimeouts = toolTimeouts
        self.exposeImageBase64 = exposeImageBase64
    }

    private enum CodingKeys: String, CodingKey {
        // Transport is flattened: its keys (command/url/...) live at the same
        // level as `enabled`/`oauth`/etc. The custom decoder/encoder below
        // handle the flatten, so this enum is only used for the non-transport
        // keys. We mark the cases for documentation but don't synthesize
        // keyed decoding against them.
        case enabled, oauth, setup
        case startupTimeoutSec = "startup_timeout_sec"
        case toolTimeoutSec = "tool_timeout_sec"
        case toolTimeouts = "tool_timeouts"
        case exposeImageBase64 = "expose_image_base64"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Transport is decoded from the same outer container (flatten).
        transport = try McpServerTransportConfig(from: decoder)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        oauth = try c.decodeIfPresent(McpJsonOAuthBlock.self, forKey: .oauth)
        setup = try c.decodeIfPresent(McpSetupConfig.self, forKey: .setup)
        startupTimeoutSec = try c.decodeIfPresent(UInt64.self, forKey: .startupTimeoutSec)
        toolTimeoutSec = try c.decodeIfPresent(UInt64.self, forKey: .toolTimeoutSec)
        toolTimeouts = try c.decodeIfPresent([String: UInt64].self, forKey: .toolTimeouts)
        exposeImageBase64 = try c.decodeIfPresent(Bool.self, forKey: .exposeImageBase64)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // Transport flattened first.
        try transport.encode(to: encoder)
        try c.encode(enabled, forKey: .enabled)
        try c.encodeIfPresent(oauth, forKey: .oauth)
        try c.encodeIfPresent(setup, forKey: .setup)
        try c.encodeIfPresent(startupTimeoutSec, forKey: .startupTimeoutSec)
        try c.encodeIfPresent(toolTimeoutSec, forKey: .toolTimeoutSec)
        try c.encodeIfPresent(toolTimeouts, forKey: .toolTimeouts)
        try c.encodeIfPresent(exposeImageBase64, forKey: .exposeImageBase64)
    }

    // MARK: Setup resolution

    /// Resolve `setup` templates using stored preferences.
    ///
    /// v0 supports exactly one select field with options. Multi-field schemas
    /// are `.invalid` until the TUI can collect them.
    public func resolveSetup(preferences: McpServerPreferences?) -> McpSetupResolution {
        guard let setup = setup else { return .resolved(self) }
        guard setup.fields.count == 1 else {
            return .invalid("setup schema must declare exactly one select field (v0)")
        }
        let field = setup.fields[0]
        guard field.fieldType == .select, !field.options.isEmpty else {
            return .invalid("setup field must be a non-empty select (v0)")
        }
        guard let preferences = preferences else { return .required(setup) }
        guard let value = preferences.values[field.id] else { return .required(setup) }
        guard field.options.contains(where: { $0.value == value }) else {
            return .required(setup)
        }

        var variables: [String: String] = [:]
        for (name, derived) in setup.variables {
            guard derived.from == field.id else {
                return .invalid("setup variable '\(name)' references unknown field '\(derived.from)'")
            }
            guard let mapped = derived.map[value] else { return .required(setup) }
            variables[name] = mapped
        }

        var resolved = self
        resolved.setup = nil
        do {
            try McpServerConfig.renderSetupTemplates(into: &resolved, variables: variables)
        } catch {
            return .invalid(String(describing: error))
        }
        return .resolved(resolved)
    }

    /// Apply a substitution function to every string in the transport.
    /// Mirrors Rust `McpServerConfig::expand_strings`.
    public mutating func expandStrings(_ sub: (String) -> String) {
        switch transport {
        case let .stdio(command, args, env, cwd):
            let newCommand = sub(command)
            let newArgs = args.map(sub)
            let newEnv = env?.mapValues(sub)
            let newCwd = cwd.map(sub)
            transport = .stdio(command: newCommand, args: newArgs, env: newEnv, cwd: newCwd)
        case let .streamableHttp(url, transportType, bearerTokenEnvVar, headers, oauthClientId, oauthClientSecretEnvVar, oauthScopes):
            let newUrl = sub(url)
            let newHeaders = headers?.mapValues(sub)
            transport = .streamableHttp(
                url: newUrl, transportType: transportType,
                bearerTokenEnvVar: bearerTokenEnvVar, headers: newHeaders,
                oauthClientId: oauthClientId, oauthClientSecretEnvVar: oauthClientSecretEnvVar,
                oauthScopes: oauthScopes
            )
        }
    }

    /// Extract OAuth configuration for this server, if any OAuth fields are
    /// set. Reads `oauth_client_id`/`oauth_client_secret_env_var`/
    /// `oauth_scopes` from the StreamableHttp transport, or the `[oauth]`
    /// block. The client secret is resolved from the named env var (no error
    /// if unset — `nil`).
    public func oauthConfig(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> McpOAuthConfig? {
        if case let .streamableHttp(_, _, _, _, oauthClientId?, oauthClientSecretEnvVar, oauthScopes) = transport {
            return McpOAuthConfig(
                clientId: oauthClientId,
                clientSecret: Self.resolveOAuthClientSecret(oauthClientSecretEnvVar, environment: environment),
                scopes: oauthScopes,
                callbackPort: nil
            )
        }
        if let block = oauth, block.clientId != nil {
            return McpOAuthConfig(
                clientId: block.clientId,
                clientSecret: Self.resolveOAuthClientSecret(block.clientSecretEnvVar, environment: environment),
                scopes: block.scopes,
                callbackPort: block.callbackPort
            )
        }
        return nil
    }

    /// Read an MCP OAuth client secret from the named env var. `nil` if unset
    /// or the env var name is `nil`.
    public static func resolveOAuthClientSecret(
        _ envVar: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let name = envVar else { return nil }
        return environment[name]
    }

    // MARK: Setup template rendering

    /// Render `{{var}}` templates in all transport strings using `variables`.
    /// Throws `McpSetupTemplateError` for an unterminated `{{` or an
    /// unresolved variable.
    static func renderSetupTemplates(
        into config: inout McpServerConfig,
        variables: [String: String]
    ) throws {
        let sub: (String) -> String = { input in
            // The throw can't propagate through this closure; instead we
            // return the input unchanged on error and the caller checks via a
            // sentinel. The `renderSetupTemplate`-throwing path below handles
            // errors by calling renderSetupTemplate directly first.
            return (try? McpServerConfig.renderSetupTemplate(input, variables: variables)) ?? input
        }
        // Validate first: render every relevant string and abort on error
        // before mutating.
        switch config.transport {
        case let .stdio(command, args, env, cwd):
            _ = try McpServerConfig.renderSetupTemplate(command, variables: variables)
            for a in args { _ = try McpServerConfig.renderSetupTemplate(a, variables: variables) }
            if let env = env { for v in env.values { _ = try McpServerConfig.renderSetupTemplate(v, variables: variables) } }
            if let cwd = cwd { _ = try McpServerConfig.renderSetupTemplate(cwd, variables: variables) }
            config.transport = .stdio(
                command: try McpServerConfig.renderSetupTemplate(command, variables: variables),
                args: try args.map { try McpServerConfig.renderSetupTemplate($0, variables: variables) },
                env: env?.mapValues { (try? McpServerConfig.renderSetupTemplate($0, variables: variables)) ?? $0 },
                cwd: cwd.map { (try? McpServerConfig.renderSetupTemplate($0, variables: variables)) ?? $0 }
            )
        case let .streamableHttp(url, _, _, headers, _, _, _):
            _ = try McpServerConfig.renderSetupTemplate(url, variables: variables)
            if let headers = headers {
                for v in headers.values { _ = try McpServerConfig.renderSetupTemplate(v, variables: variables) }
            }
            config.transport = .streamableHttp(
                url: try McpServerConfig.renderSetupTemplate(url, variables: variables),
                transportType: config.transport.streamableTransportType,
                bearerTokenEnvVar: config.transport.streamableBearerEnvVar,
                headers: headers?.mapValues { (try? McpServerConfig.renderSetupTemplate($0, variables: variables)) ?? $0 },
                oauthClientId: config.transport.streamableOauthClientId,
                oauthClientSecretEnvVar: config.transport.streamableOauthSecretEnvVar,
                oauthScopes: config.transport.streamableOauthScopes
            )
        }
        _ = sub
    }

    /// Render `{{var}}` templates in one string. Throws on unterminated
    /// template or unresolved variable. Mirrors Rust `render_setup_template`.
    static func renderSetupTemplate(_ input: String, variables: [String: String]) throws -> String {
        var out = ""
        var rest = input[...]
        while let startRange = rest.range(of: "{{") {
            out += rest[..<startRange.lowerBound]
            let afterStart = rest[startRange.upperBound...]
            guard let endRange = afterStart.range(of: "}}") else {
                throw McpSetupTemplateError.unterminated
            }
            let key = afterStart[..<endRange.lowerBound].trimmingCharacters(in: .whitespaces)
            guard let value = variables[key] else {
                throw McpSetupTemplateError.unresolved(key)
            }
            out += value
            rest = afterStart[endRange.upperBound...]
        }
        out += rest
        return out
    }
}

/// Errors thrown by setup template rendering.
public enum McpSetupTemplateError: Error, Equatable, Sendable {
    case unterminated
    case unresolved(String)
}

extension McpServerTransportConfig {
    /// Internal accessors for the StreamableHttp case's fields (used by
    /// `renderSetupTemplates` to preserve non-string fields across re-build).
    fileprivate var streamableTransportType: String? {
        if case let .streamableHttp(_, t, _, _, _, _, _) = self { return t }
        return nil
    }
    fileprivate var streamableBearerEnvVar: String? {
        if case let .streamableHttp(_, _, b, _, _, _, _) = self { return b }
        return nil
    }
    fileprivate var streamableOauthClientId: String? {
        if case let .streamableHttp(_, _, _, _, c, _, _) = self { return c }
        return nil
    }
    fileprivate var streamableOauthSecretEnvVar: String? {
        if case let .streamableHttp(_, _, _, _, _, s, _) = self { return s }
        return nil
    }
    fileprivate var streamableOauthScopes: [String]? {
        if case let .streamableHttp(_, _, _, _, _, _, sc) = self { return sc }
        return nil
    }
}

// MARK: - RelaySyncConfig

/// Configuration for relay session sharing. Set in config.toml under `[relay]`.
public struct RelaySyncConfig: Hashable, Sendable, Codable, Equatable {
    public var enabled: Bool?

    public init(enabled: Bool? = nil) {
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey { case enabled }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(enabled, forKey: .enabled)
    }

    /// Check if relay sync is enabled. Env var `GROK_RELAY_SYNC_ENABLED`
    /// takes precedence over config; `environment` is injectable for tests.
    public func isEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if let envVal = environment["GROK_RELAY_SYNC_ENABLED"] {
            return envVal.lowercased() == "true" || envVal == "1"
        }
        return enabled ?? false
    }
}

// MARK: - McpConfig

/// Top-level MCP config: the `mcpServers` table. Mirrors Rust `McpConfig`
/// (Rust renames `mcpServers` <-> `mcp_servers` via `#[serde(rename)]`).
public struct McpConfig: Hashable, Sendable, Codable, Equatable {
    /// Ordered map of server name -> config. Order is preserved (Rust
    /// `IndexMap`); insertion order matches the config file.
    public var mcpServers: OrderedMap<McpServerConfig>

    public init(mcpServers: OrderedMap<McpServerConfig> = [:]) {
        self.mcpServers = mcpServers
    }

    private struct McpConfigCodingKeys: CodingKey {
        var stringValue: String
        var intValue: Int?
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: McpConfigCodingKeys.self)
        var ordered = OrderedMap<McpServerConfig>()
        for key in c.allKeys where key.stringValue == "mcpServers" || key.stringValue == "mcp_servers" {
            let nested = try c.nestedContainer(keyedBy: AnyCodingKey.self, forKey: key)
            for serverKey in nested.allKeys {
                let server = try nested.decode(McpServerConfig.self, forKey: serverKey)
                ordered[serverKey.stringValue] = server
            }
        }
        self.mcpServers = ordered
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: McpConfigCodingKeys.self)
        var nested = c.nestedContainer(keyedBy: AnyCodingKey.self, forKey: McpConfigCodingKeys(stringValue: "mcpServers"))
        for (name, server) in mcpServers.pairs {
            try nested.encode(server, forKey: AnyCodingKey(name))
        }
    }
}

// MARK: - OrderedMap

/// An order-preserving map. Mirrors Rust `IndexMap` for the MCP servers table,
/// where insertion order matters (the first server with a given id wins on
/// duplicate-key merge, and round-trip preserves order).
public struct OrderedMap<V: Equatable & Hashable & Sendable>: Hashable, Sendable, Equatable, ExpressibleByDictionaryLiteral {
    public typealias Key = String
    fileprivate var keys: [Key] = []
    fileprivate var values: [Key: V] = [:]

    public init() {}

    public init(_ entries: [(Key, V)]) {
        for (k, v) in entries { self[k] = v }
    }

    public init(dictionaryLiteral elements: (Key, V)...) {
        for (k, v) in elements { self[k] = v }
    }

    public subscript(key: Key) -> V? {
        get { values[key] }
        set {
            if let v = newValue {
                if values[key] == nil { keys.append(key) }
                values[key] = v
            } else {
                if values[key] != nil {
                    values.removeValue(forKey: key)
                    keys.removeAll { $0 == key }
                }
            }
        }
    }

    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }

    public var pairs: [(Key, V)] { keys.compactMap { k in values[k].map { (k, $0) } } }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(keys)
        for k in keys { hasher.combine(values[k]) }
    }

    public static func == (lhs: OrderedMap<V>, rhs: OrderedMap<V>) -> Bool {
        lhs.keys == rhs.keys && lhs.keys.allSatisfy { lhs.values[$0] == rhs.values[$0] }
    }
}

extension OrderedMap where V: Codable {
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        for (k, v) in pairs { try c.encode(v, forKey: AnyCodingKey(k)) }
    }
}
