// ProviderDefinitions.swift
//
// Trusted-layer definitions for named model gateways and external auth
// commands. The parser deliberately stays in OpenGrokConfig so lower layers
// never gain ownership of credentials or process execution.

import Foundation

public struct AuthProviderConfig: Sendable, Equatable {
    public var command: String
    public var args: [String]?
    public var tokenTTLSecs: UInt64?
    public var timeoutSecs: UInt64?
    public var cwd: String?

    public init(
        command: String,
        args: [String]? = nil,
        tokenTTLSecs: UInt64? = nil,
        timeoutSecs: UInt64? = nil,
        cwd: String? = nil
    ) {
        self.command = command
        self.args = args
        self.tokenTTLSecs = tokenTTLSecs
        self.timeoutSecs = timeoutSecs
        self.cwd = cwd
    }

    public var isUsable: Bool {
        !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var effectiveTimeoutSecs: UInt64 {
        min(max(timeoutSecs ?? 30, 1), 600)
    }
}

public struct ModelProviderConfig: Sendable, Equatable {
    public var baseURL: String?
    public var apiBaseURL: String?
    public var envKey: [String]
    public var apiKey: String?
    public var apiBackend: String?
    public var extraHeaders: [(String, String)]
    public var queryParams: [(String, String)]
    public var envHTTPHeaders: [(String, String)]
    public var authProvider: String?
    public var auth: AuthProviderConfig?
    public var contextWindow: UInt64?

    public init(
        baseURL: String? = nil,
        apiBaseURL: String? = nil,
        envKey: [String] = [],
        apiKey: String? = nil,
        apiBackend: String? = nil,
        extraHeaders: [(String, String)] = [],
        queryParams: [(String, String)] = [],
        envHTTPHeaders: [(String, String)] = [],
        authProvider: String? = nil,
        auth: AuthProviderConfig? = nil,
        contextWindow: UInt64? = nil
    ) {
        self.baseURL = baseURL
        self.apiBaseURL = apiBaseURL
        self.envKey = envKey
        self.apiKey = apiKey
        self.apiBackend = apiBackend
        self.extraHeaders = extraHeaders
        self.queryParams = queryParams
        self.envHTTPHeaders = envHTTPHeaders
        self.authProvider = authProvider
        self.auth = auth
        self.contextWindow = contextWindow
    }
}

public struct ConfigProviderWarning: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case notATable
        case unknownField
        case invalidValue
        case conflictingFields
    }

    public var section: String
    public var name: String?
    public var field: String?
    public var kind: Kind
    public var message: String

    public init(
        section: String,
        name: String? = nil,
        field: String? = nil,
        kind: Kind,
        message: String
    ) {
        self.section = section
        self.name = name
        self.field = field
        self.kind = kind
        self.message = message
    }
}

public struct ParsedProviderDefinitions: Sendable, Equatable {
    public var authProviders: [(String, AuthProviderConfig)]
    public var modelProviders: [(String, ModelProviderConfig)]
    public var warnings: [ConfigProviderWarning]

    public init(
        authProviders: [(String, AuthProviderConfig)] = [],
        modelProviders: [(String, ModelProviderConfig)] = [],
        warnings: [ConfigProviderWarning] = []
    ) {
        self.authProviders = authProviders
        self.modelProviders = modelProviders
        self.warnings = warnings
    }

    public func authProvider(named name: String) -> AuthProviderConfig? {
        authProviders.first { $0.0 == name }?.1
    }

    public func modelProvider(named name: String) -> ModelProviderConfig? {
        modelProviders.first { $0.0 == name }?.1
    }
}

private func equalPairs(_ lhs: [(String, String)], _ rhs: [(String, String)]) -> Bool {
    lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
}

extension ModelProviderConfig {
    public static func == (lhs: ModelProviderConfig, rhs: ModelProviderConfig) -> Bool {
        lhs.baseURL == rhs.baseURL && lhs.apiBaseURL == rhs.apiBaseURL &&
        lhs.envKey == rhs.envKey && lhs.apiKey == rhs.apiKey &&
        lhs.apiBackend == rhs.apiBackend && equalPairs(lhs.extraHeaders, rhs.extraHeaders) &&
        equalPairs(lhs.queryParams, rhs.queryParams) && equalPairs(lhs.envHTTPHeaders, rhs.envHTTPHeaders) &&
        lhs.authProvider == rhs.authProvider && lhs.auth == rhs.auth &&
        lhs.contextWindow == rhs.contextWindow
    }
}

extension ParsedProviderDefinitions {
    public static func == (lhs: ParsedProviderDefinitions, rhs: ParsedProviderDefinitions) -> Bool {
        lhs.authProviders.count == rhs.authProviders.count &&
        zip(lhs.authProviders, rhs.authProviders).allSatisfy {
            $0.0 == $1.0 && $0.1 == $1.1
        } && lhs.modelProviders.count == rhs.modelProviders.count &&
        zip(lhs.modelProviders, rhs.modelProviders).allSatisfy {
            $0.0 == $1.0 && $0.1 == $1.1
        } && lhs.warnings == rhs.warnings
    }
}

public func parseProviderDefinitions(from document: TOMLValue) -> ParsedProviderDefinitions {
    var warnings: [ConfigProviderWarning] = []
    let auth = parseAuthProviderDefinitions(from: document["auth_provider"], warnings: &warnings)
    let models = parseModelProviderDefinitions(from: document["model_providers"], warnings: &warnings)
    return ParsedProviderDefinitions(authProviders: auth, modelProviders: models, warnings: warnings)
}

public func parseAuthProviderDefinitions(
    from value: TOMLValue?,
    warnings: inout [ConfigProviderWarning]
) -> [(String, AuthProviderConfig)] {
    guard let value else { return [] }
    guard case let .table(table) = value else {
        warnings.append(ConfigProviderWarning(
            section: "auth_provider",
            kind: .notATable,
            message: "auth_provider must be a table; all named auth providers ignored"
        ))
        return []
    }
    var providers: [(String, AuthProviderConfig)] = []
    for (name, value) in table.pairs {
        guard case let .table(entry) = value else {
            warnings.append(ConfigProviderWarning(
                section: "auth_provider",
                name: name,
                kind: .invalidValue,
                message: "provider entry must be a table; entry skipped"
            ))
            continue
        }
        guard let command = entry["command"]?.stringValue else {
            warnings.append(ConfigProviderWarning(
                section: "auth_provider",
                name: name,
                field: "command",
                kind: .invalidValue,
                message: "command must be a string; provider skipped"
            ))
            continue
        }
        let args = parseStringArray(entry["args"])
        if entry["args"] != nil && args == nil {
            warnings.append(ConfigProviderWarning(
                section: "auth_provider",
                name: name,
                field: "args",
                kind: .invalidValue,
                message: "args must be an array of strings; provider skipped"
            ))
            continue
        }
        let tokenTTL = parseUInt64(entry["token_ttl_secs"])
        if entry["token_ttl_secs"] != nil && tokenTTL == nil {
            warnings.append(ConfigProviderWarning(
                section: "auth_provider",
                name: name,
                field: "token_ttl_secs",
                kind: .invalidValue,
                message: "token_ttl_secs must be a non-negative integer; provider skipped"
            ))
            continue
        }
        let timeout = parseUInt64(entry["timeout_secs"])
        if entry["timeout_secs"] != nil && timeout == nil {
            warnings.append(ConfigProviderWarning(
                section: "auth_provider",
                name: name,
                field: "timeout_secs",
                kind: .invalidValue,
                message: "timeout_secs must be a non-negative integer; provider skipped"
            ))
            continue
        }
        let cwd = entry["cwd"]?.stringValue
        if entry["cwd"] != nil && cwd == nil {
            warnings.append(ConfigProviderWarning(
                section: "auth_provider",
                name: name,
                field: "cwd",
                kind: .invalidValue,
                message: "cwd must be a string; provider skipped"
            ))
            continue
        }
        let known = Set(["command", "args", "token_ttl_secs", "timeout_secs", "cwd"])
        for key in entry.allKeys where !known.contains(key) {
            warnings.append(ConfigProviderWarning(
                section: "auth_provider",
                name: name,
                field: key,
                kind: .unknownField,
                message: "unrecognized key; field ignored"
            ))
        }
        providers.append((name, AuthProviderConfig(
            command: command,
            args: args,
            tokenTTLSecs: tokenTTL,
            timeoutSecs: timeout,
            cwd: cwd
        )))
    }
    return providers
}

public func parseModelProviderDefinitions(
    from value: TOMLValue?,
    warnings: inout [ConfigProviderWarning]
) -> [(String, ModelProviderConfig)] {
    guard let value else { return [] }
    guard case let .table(table) = value else {
        warnings.append(ConfigProviderWarning(
            section: "model_providers",
            kind: .notATable,
            message: "model_providers must be a table; all named model providers ignored"
        ))
        return []
    }
    var providers: [(String, ModelProviderConfig)] = []
    for (name, value) in table.pairs {
        let warningStart = warnings.count
        guard case let .table(entry) = value else {
            warnings.append(ConfigProviderWarning(
                section: "model_providers",
                name: name,
                kind: .invalidValue,
                message: "provider entry must be a table; entry skipped"
            ))
            continue
        }
        let baseURL = stringValue(entry["base_url"], section: "model_providers", name: name, field: "base_url", warnings: &warnings)
        let apiBaseURL = stringValue(entry["api_base_url"], section: "model_providers", name: name, field: "api_base_url", warnings: &warnings)
        let apiKey = stringValue(entry["api_key"], section: "model_providers", name: name, field: "api_key", warnings: &warnings)
        let apiBackend = stringValue(entry["api_backend"], section: "model_providers", name: name, field: "api_backend", warnings: &warnings)
        let authProvider = stringValue(entry["auth_provider"], section: "model_providers", name: name, field: "auth_provider", warnings: &warnings)
        let envKey = parseStringOrArray(entry["env_key"])
        if entry["env_key"] != nil && envKey == nil {
            warnings.append(ConfigProviderWarning(section: "model_providers", name: name, field: "env_key", kind: .invalidValue, message: "env_key must be a string or array of strings; provider skipped"))
            continue
        }
        let extraHeaders = parsePairs(entry["extra_headers"], section: "model_providers", name: name, field: "extra_headers", warnings: &warnings)
        let queryParams = parsePairs(entry["query_params"], section: "model_providers", name: name, field: "query_params", warnings: &warnings)
        let envHTTPHeaders = parsePairs(entry["env_http_headers"], section: "model_providers", name: name, field: "env_http_headers", warnings: &warnings)
        let contextWindow = parseUInt64(entry["context_window"])
        if entry["context_window"] != nil && contextWindow == nil {
            warnings.append(ConfigProviderWarning(section: "model_providers", name: name, field: "context_window", kind: .invalidValue, message: "context_window must be a non-negative integer; provider skipped"))
            continue
        }
        var inlineAuth: AuthProviderConfig?
        if let authValue = entry["auth"] {
            var nestedWarnings: [ConfigProviderWarning] = []
            let parsed = parseAuthProviderDefinitions(
                from: .table(TOMLTable([(name, authValue)])),
                warnings: &nestedWarnings
            ).first?.1
            if parsed == nil {
                warnings.append(ConfigProviderWarning(section: "model_providers", name: name, field: "auth", kind: .invalidValue, message: "inline auth is invalid; provider skipped"))
                continue
            }
            inlineAuth = parsed
            warnings.append(contentsOf: nestedWarnings.map { warning in
                ConfigProviderWarning(section: warning.section, name: name, field: "auth.\(warning.field ?? "")", kind: warning.kind, message: warning.message)
            })
        }
        if authProvider != nil && inlineAuth != nil {
            warnings.append(ConfigProviderWarning(section: "model_providers", name: name, field: "auth", kind: .conflictingFields, message: "auth_provider shadows inline auth"))
        }
        let known = Set(["base_url", "api_base_url", "env_key", "api_key", "api_backend", "extra_headers", "query_params", "env_http_headers", "auth_provider", "auth", "context_window"])
        for key in entry.allKeys where !known.contains(key) {
            warnings.append(ConfigProviderWarning(section: "model_providers", name: name, field: key, kind: .unknownField, message: "unrecognized key; field ignored"))
        }
        if warnings[warningStart...].contains(where: { $0.name == name && $0.kind == .invalidValue }) {
            continue
        }
        providers.append((name, ModelProviderConfig(
            baseURL: baseURL,
            apiBaseURL: apiBaseURL,
            envKey: envKey ?? [],
            apiKey: apiKey,
            apiBackend: apiBackend,
            extraHeaders: extraHeaders,
            queryParams: queryParams,
            envHTTPHeaders: envHTTPHeaders,
            authProvider: authProvider,
            auth: inlineAuth,
            contextWindow: contextWindow
        )))
    }
    return providers
}

private func stringValue(
    _ value: TOMLValue?,
    section: String,
    name: String,
    field: String,
    warnings: inout [ConfigProviderWarning]
) -> String? {
    guard let value else { return nil }
    guard let string = value.stringValue else {
        warnings.append(ConfigProviderWarning(section: section, name: name, field: field, kind: .invalidValue, message: "field must be a string; value ignored"))
        return nil
    }
    return string
}

private func parseStringArray(_ value: TOMLValue?) -> [String]? {
    guard let value else { return nil }
    guard case let .array(values) = value else { return nil }
    return values.map(\.stringValue).allSatisfy { $0 != nil } ? values.compactMap(\.stringValue) : nil
}

private func parseStringOrArray(_ value: TOMLValue?) -> [String]? {
    guard let value else { return nil }
    if let string = value.stringValue { return [string] }
    return parseStringArray(value)
}

private func parseUInt64(_ value: TOMLValue?) -> UInt64? {
    guard let value else { return nil }
    guard case let .integer(number) = value, number >= 0 else { return nil }
    return UInt64(number)
}

private func parsePairs(
    _ value: TOMLValue?,
    section: String,
    name: String,
    field: String,
    warnings: inout [ConfigProviderWarning]
) -> [(String, String)] {
    guard let value else { return [] }
    guard case let .table(table) = value else {
        warnings.append(ConfigProviderWarning(section: section, name: name, field: field, kind: .invalidValue, message: "field must be a table of strings; value ignored"))
        return []
    }
    var out: [(String, String)] = []
    for (key, item) in table.pairs {
        guard let string = item.stringValue else {
            warnings.append(ConfigProviderWarning(section: section, name: name, field: "\(field).\(key)", kind: .invalidValue, message: "value must be a string; entry ignored"))
            continue
        }
        out.append((key, string))
    }
    return out
}
