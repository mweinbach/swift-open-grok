// MCPOAuth.swift
//
// Port of the rmcp 2.1 `transport::auth` subset that upstream's MCP OAuth
// actually exercises (rmcp-2.1.0/src/transport/auth.rs, consumed by
// xai-grok-mcp/src/oauth.rs and servers.rs at reference 650c1db7):
//
//   * metadata discovery per SEP-985 — RFC 9728 protected-resource metadata
//     first (WWW-Authenticate `resource_metadata`, then the
//     oauth-protected-resource well-known ladder), then direct RFC 8414 /
//     OIDC discovery on the server URL (auth.rs:1067-1080, 1766-2084);
//   * dynamic client registration as a public client (auth.rs:1179-1280);
//   * the PKCE (S256) authorization-code flow with the RFC 8707 `resource`
//     indicator and RFC 9207 `iss` validation (auth.rs:1297-1605);
//   * refresh-token grant that keeps the old refresh token when the server
//     omits one (RFC 6749 §6; auth.rs:1672-1728);
//   * `get_access_token` with the 30-second proactive refresh buffer
//     (auth.rs:1614-1651) and `Bearer` header attachment (auth.rs:1731-1737).
//
// Deliberately not ported (recorded): the 403 insufficient_scope upgrade
// machinery, the client-credentials flow (SEP-1046), and token revocation —
// upstream's interactive MCP flow reaches none of them.

import Foundation
import OpenGrokFileUtils
import OpenGrokHTTP
import OpenGrokShared

// MARK: - Errors (rmcp AuthError subset, auth.rs:456-524)

public enum MCPAuthError: Error, Sendable, Equatable, CustomStringConvertible {
    case authorizationRequired
    case authorizationFailed(String)
    case tokenExchangeFailed(String)
    case tokenRefreshFailed(String)
    case metadataError(String)
    case noAuthorizationSupport
    case registrationFailed(String)
    case internalError(String)
    case authorizationServerMismatch(expected: String, received: String)
    case authorizationServerMissingIssuer(expected: String)
    case invalidScope(String)

    public var description: String {
        switch self {
        case .authorizationRequired:
            return "OAuth authorization required"
        case .authorizationFailed(let detail):
            return "OAuth authorization failed: \(detail)"
        case .tokenExchangeFailed(let detail):
            return "OAuth token exchange failed: \(detail)"
        case .tokenRefreshFailed(let detail):
            return "OAuth token refresh failed: \(detail)"
        case .metadataError(let detail):
            return "Metadata error: \(detail)"
        case .noAuthorizationSupport:
            return "No authorization support detected"
        case .registrationFailed(let detail):
            return "Registration failed: \(detail)"
        case .internalError(let detail):
            return "Internal error: \(detail)"
        case .authorizationServerMismatch(let expected, let received):
            return "Authorization server issuer mismatch: expected \(expected), received \(received)"
        case .authorizationServerMissingIssuer(let expected):
            return "Authorization server response missing required issuer: expected \(expected)"
        case .invalidScope(let detail):
            return "Invalid scope: \(detail)"
        }
    }
}

// MARK: - Authorization server metadata (auth.rs:527-541)

public struct MCPAuthorizationMetadata: Sendable, Equatable, Codable {
    public var authorizationEndpoint: String
    public var tokenEndpoint: String
    public var registrationEndpoint: String?
    public var issuer: String?
    public var scopesSupported: [String]?
    public var responseTypesSupported: [String]?
    public var codeChallengeMethodsSupported: [String]?
    /// Everything else, flattened — carries
    /// `authorization_response_iss_parameter_supported` and
    /// `token_endpoint_auth_methods_supported`.
    public var additionalFields: [String: JSONValue]

    public init(
        authorizationEndpoint: String,
        tokenEndpoint: String,
        registrationEndpoint: String? = nil,
        issuer: String? = nil,
        scopesSupported: [String]? = nil,
        responseTypesSupported: [String]? = nil,
        codeChallengeMethodsSupported: [String]? = nil,
        additionalFields: [String: JSONValue] = [:]
    ) {
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.registrationEndpoint = registrationEndpoint
        self.issuer = issuer
        self.scopesSupported = scopesSupported
        self.responseTypesSupported = responseTypesSupported
        self.codeChallengeMethodsSupported = codeChallengeMethodsSupported
        self.additionalFields = additionalFields
    }

    private static let knownKeys: Set<String> = [
        "authorization_endpoint", "token_endpoint", "registration_endpoint",
        "issuer", "scopes_supported", "response_types_supported",
        "code_challenge_methods_supported",
    ]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        authorizationEndpoint = try c.decode(String.self, forKey: AnyCodingKey("authorization_endpoint"))
        tokenEndpoint = try c.decode(String.self, forKey: AnyCodingKey("token_endpoint"))
        registrationEndpoint = try c.decodeIfPresent(String.self, forKey: AnyCodingKey("registration_endpoint"))
        issuer = try c.decodeIfPresent(String.self, forKey: AnyCodingKey("issuer"))
        scopesSupported = try c.decodeIfPresent([String].self, forKey: AnyCodingKey("scopes_supported"))
        responseTypesSupported = try c.decodeIfPresent([String].self, forKey: AnyCodingKey("response_types_supported"))
        codeChallengeMethodsSupported = try c.decodeIfPresent(
            [String].self, forKey: AnyCodingKey("code_challenge_methods_supported"))
        var extras: [String: JSONValue] = [:]
        for key in c.allKeys where !Self.knownKeys.contains(key.stringValue) {
            extras[key.stringValue] = try c.decode(JSONValue.self, forKey: key)
        }
        additionalFields = extras
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encode(authorizationEndpoint, forKey: AnyCodingKey("authorization_endpoint"))
        try c.encode(tokenEndpoint, forKey: AnyCodingKey("token_endpoint"))
        try c.encodeIfPresent(registrationEndpoint, forKey: AnyCodingKey("registration_endpoint"))
        try c.encodeIfPresent(issuer, forKey: AnyCodingKey("issuer"))
        try c.encodeIfPresent(scopesSupported, forKey: AnyCodingKey("scopes_supported"))
        try c.encodeIfPresent(responseTypesSupported, forKey: AnyCodingKey("response_types_supported"))
        try c.encodeIfPresent(
            codeChallengeMethodsSupported, forKey: AnyCodingKey("code_challenge_methods_supported"))
        for (key, value) in additionalFields {
            try c.encode(value, forKey: AnyCodingKey(key))
        }
    }

    /// RFC 9207 `authorization_response_iss_parameter_supported` (auth.rs:1325-1334).
    var issParameterSupported: Bool {
        if case .bool(let value)? =
            additionalFields["authorization_response_iss_parameter_supported"] {
            return value
        }
        return false
    }

    /// rmcp auth.rs:1128-1143 — RequestBody auth only when the server
    /// advertises `client_secret_post` without `client_secret_basic`.
    var usesClientSecretPost: Bool {
        guard case .array(let methods)? =
            additionalFields["token_endpoint_auth_methods_supported"] else {
            return false
        }
        let names: [String] = methods.compactMap {
            if case .string(let s) = $0 { return s }
            return nil
        }
        return names.contains("client_secret_post") && !names.contains("client_secret_basic")
    }
}

/// RFC 9728 protected resource metadata (auth.rs:543-549).
struct MCPResourceServerMetadata: Decodable {
    var resource: String?
    var authorizationServer: String?
    var authorizationServers: [String]?
    var scopesSupported: [String]?

    enum CodingKeys: String, CodingKey {
        case resource
        case authorizationServer = "authorization_server"
        case authorizationServers = "authorization_servers"
        case scopesSupported = "scopes_supported"
    }
}

// MARK: - Small codecs

/// Percent-encode one `application/x-www-form-urlencoded` value.
private let formUnreserved: CharacterSet = {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return allowed
}()

func mcpFormEncode(_ pairs: [(String, String)]) -> String {
    pairs.map { key, value in
        let k = key.addingPercentEncoding(withAllowedCharacters: formUnreserved) ?? key
        let v = value.addingPercentEncoding(withAllowedCharacters: formUnreserved) ?? value
        return "\(k)=\(v)"
    }
    .joined(separator: "&")
}

func mcpBase64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func mcpRandomBytes(_ count: Int) -> Data {
    var data = Data(count: count)
    for index in data.indices {
        data[index] = UInt8.random(in: .min ... .max)
    }
    return data
}

private func mcpHexToData(_ hex: String) -> Data {
    var data = Data(capacity: hex.count / 2)
    var iterator = hex.makeIterator()
    while let high = iterator.next(), let low = iterator.next() {
        if let byte = UInt8(String([high, low]), radix: 16) {
            data.append(byte)
        }
    }
    return data
}

/// PKCE S256 pair matching oauth2's `PkceCodeChallenge::new_random_sha256`:
/// verifier = 32 random bytes base64url; challenge = base64url(SHA-256(verifier)).
struct MCPPKCE: Sendable {
    let verifier: String
    let challenge: String

    static func generate() -> MCPPKCE {
        let verifier = mcpBase64URL(mcpRandomBytes(32))
        let digest = mcpHexToData(FileChecksum.sha256Hex(verifier))
        return MCPPKCE(verifier: verifier, challenge: mcpBase64URL(digest))
    }
}

// MARK: - WWW-Authenticate parsing (auth.rs:2086-2166)

struct MCPWWWAuthenticateParams: Sendable, Equatable {
    var resourceMetadataURL: URL?
    var scope: String?
}

/// Read the next header parameter value (quoted or bare token) starting at
/// the beginning of `slice`. Returns the value and the count of characters
/// consumed. Port of rmcp `parse_next_header_value`.
func mcpParseNextHeaderValue(_ slice: Substring) -> (value: String, consumed: Int)? {
    guard let first = slice.first else { return nil }
    if first == "\"" {
        var value = ""
        var index = slice.index(after: slice.startIndex)
        while index < slice.endIndex {
            let ch = slice[index]
            if ch == "\"" {
                let consumed = slice.distance(from: slice.startIndex, to: index) + 1
                return (value, consumed)
            }
            value.append(ch)
            index = slice.index(after: index)
        }
        return nil
    }
    let terminatorSet = CharacterSet(charactersIn: ", \t")
    var value = ""
    var index = slice.startIndex
    while index < slice.endIndex {
        let ch = slice[index]
        if ch.unicodeScalars.allSatisfy({ terminatorSet.contains($0) }) {
            break
        }
        value.append(ch)
        index = slice.index(after: index)
    }
    guard !value.isEmpty else { return nil }
    return (value, slice.distance(from: slice.startIndex, to: index))
}

func mcpExtractWWWAuthenticateParams(
    header: String,
    baseURL: URL
) -> MCPWWWAuthenticateParams {
    var params = MCPWWWAuthenticateParams()
    let lower = header.lowercased()

    let resourceKey = "resource_metadata="
    var searchStart = lower.startIndex
    while let range = lower.range(of: resourceKey, range: searchStart..<lower.endIndex) {
        let globalStart = header.index(header.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: range.upperBound))
        let slice = header[globalStart...]
        if let (value, consumed) = mcpParseNextHeaderValue(slice) {
            if let url = mcpResolveResourceMetadataURL(value, baseURL: baseURL) {
                params.resourceMetadataURL = url
                break
            }
            searchStart = lower.index(range.upperBound, offsetBy: consumed, limitedBy: lower.endIndex) ?? lower.endIndex
        } else {
            break
        }
    }

    let scopeKey = "scope="
    if let range = lower.range(of: scopeKey) {
        let globalStart = header.index(header.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: range.upperBound))
        if let (value, _) = mcpParseNextHeaderValue(header[globalStart...]) {
            params.scope = value
        }
    }

    return params
}

// MARK: - URL policy (auth.rs:832-951)

enum MCPOAuthURLPolicy {
    static func isHTTPURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host != nil
    }

    static func isSameOrigin(_ base: URL, _ candidate: URL) -> Bool {
        guard let baseScheme = base.scheme?.lowercased(),
              let candidateScheme = candidate.scheme?.lowercased(),
              let baseHost = base.host?.lowercased(),
              let candidateHost = candidate.host?.lowercased() else {
            return false
        }
        func portOrDefault(_ url: URL, scheme: String) -> Int? {
            url.port ?? (scheme == "https" ? 443 : (scheme == "http" ? 80 : nil))
        }
        return baseScheme == candidateScheme
            && baseHost == candidateHost
            && portOrDefault(base, scheme: baseScheme) == portOrDefault(candidate, scheme: candidateScheme)
    }

    /// Cloud metadata hostnames that authorization-server candidates from
    /// resource metadata must never resolve to (auth.rs:33-37).
    static let cloudMetadataHosts: Set<String> = [
        "metadata", "metadata.google.internal", "metadata.azure.internal",
    ]

    static func isDisallowedMetadataHost(_ host: String) -> Bool {
        let host = host.hasSuffix(".") ? String(host.dropLast()) : host
        let lowered = host.lowercased()
        if lowered == "localhost" || lowered.hasSuffix(".localhost") { return true }
        if cloudMetadataHosts.contains(lowered) { return true }
        if let v4 = parseIPv4(lowered) { return isDisallowedIPv4(v4) }
        if lowered.contains(":") {
            // IPv6 literal (URL host may carry brackets already stripped).
            return isDisallowedIPv6(lowered)
        }
        return false
    }

    private static func parseIPv4(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        for part in parts {
            guard let value = UInt8(part) else { return nil }
            octets.append(value)
        }
        return octets
    }

    private static func isDisallowedIPv4(_ o: [UInt8]) -> Bool {
        // private, loopback, link-local, broadcast, unspecified, multicast,
        // 0.0.0.0/8, CGNAT 100.64/10, benchmarking 198.18/15 (auth.rs:849-860).
        if o[0] == 10 { return true }
        if o[0] == 172 && (16...31).contains(o[1]) { return true }
        if o[0] == 192 && o[1] == 168 { return true }
        if o[0] == 127 { return true }
        if o[0] == 169 && o[1] == 254 { return true }
        if o == [255, 255, 255, 255] { return true }
        if o == [0, 0, 0, 0] { return true }
        if o[0] >= 224 && o[0] <= 239 { return true }
        if o[0] == 0 { return true }
        if o[0] == 100 && (64...127).contains(o[1]) { return true }
        if o[0] == 198 && (o[1] == 18 || o[1] == 19) { return true }
        return false
    }

    private static func isDisallowedIPv6(_ host: String) -> Bool {
        let lowered = host.lowercased()
        if lowered == "::1" || lowered == "::" { return true }
        if lowered.hasPrefix("fe8") || lowered.hasPrefix("fe9")
            || lowered.hasPrefix("fea") || lowered.hasPrefix("feb") { return true }
        if lowered.hasPrefix("fc") || lowered.hasPrefix("fd") { return true }
        if lowered.hasPrefix("ff") { return true }
        if lowered.hasPrefix("::ffff:") {
            let mapped = String(lowered.dropFirst("::ffff:".count))
            if let v4 = parseIPv4(mapped) { return isDisallowedIPv4(v4) }
        }
        return false
    }

    /// SSRF gate for authorization-server metadata URLs discovered through
    /// protected resource metadata (auth.rs:894-899).
    static func isAllowedAuthorizationServerMetadataURL(_ url: URL) -> Bool {
        guard isHTTPURL(url), let host = url.host else { return false }
        return !isDisallowedMetadataHost(host)
    }
}

func mcpResolveResourceMetadataURL(_ value: String, baseURL: URL) -> URL? {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    let url: URL?
    if let absolute = URL(string: trimmed), absolute.scheme != nil {
        url = absolute
    } else {
        url = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
    }
    guard let resolved = url else { return nil }
    // RFC 9728 same-origin requirement (auth.rs:845-847, 916-923).
    guard MCPOAuthURLPolicy.isHTTPURL(resolved),
          MCPOAuthURLPolicy.isSameOrigin(baseURL, resolved) else {
        return nil
    }
    return resolved
}

// MARK: - Discovery (auth.rs:1067-1080, 1766-2084)

/// The MCP-Protocol-Version header rmcp pins on every discovery GET
/// (auth.rs:2046).
let mcpDiscoveryProtocolVersion = "2024-11-05"

public enum MCPOAuthDiscovery {
    /// RFC 8414 well-known candidates for one base URL, in spec-2025-11-25
    /// §4.3 priority order (auth.rs:1766-1795).
    static func discoveryURLs(for baseURL: URL) -> [URL] {
        var candidates: [URL] = []
        let trimmedPath = baseURL.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        func push(_ path: String) {
            guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true) else {
                return
            }
            components.query = nil
            components.fragment = nil
            components.path = path
            if let url = components.url { candidates.append(url) }
        }
        if trimmedPath.isEmpty {
            push("/.well-known/oauth-authorization-server")
            push("/.well-known/openid-configuration")
        } else {
            push("/.well-known/oauth-authorization-server/\(trimmedPath)")
            push("/.well-known/openid-configuration/\(trimmedPath)")
            push("/\(trimmedPath)/.well-known/openid-configuration")
            push("/.well-known/oauth-authorization-server")
        }
        return candidates
    }

    /// RFC 8414 / RFC 9728 well-known path candidates (auth.rs:926-951).
    static func wellKnownPaths(basePath: String, resource: String) -> [String] {
        let trimmed = basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let canonical = "/.well-known/\(resource)"
        if trimmed.isEmpty { return [canonical] }
        var candidates: [String] = []
        for candidate in ["\(canonical)/\(trimmed)", "/\(trimmed)/.well-known/\(resource)", canonical]
        where !candidates.contains(candidate) {
            candidates.append(candidate)
        }
        return candidates
    }

    /// One discovery GET. rmcp uses a no-redirect client and follows only
    /// same-origin redirects by hand (auth.rs:2040-2084); this port's
    /// transport auto-follows, so the fail-closed equivalent is validating
    /// the FINAL response URL is same-origin with the request and treating a
    /// cross-origin landing as a failed probe.
    static func discoveryGET(
        _ url: URL,
        transport: any HTTPTransport
    ) async throws -> HTTPResponse {
        let response = try await transport.send(HTTPRequest(
            method: .get,
            url: url,
            headers: ["MCP-Protocol-Version": mcpDiscoveryProtocolVersion],
            timeout: 30
        ))
        if let finalURL = response.metadata.url,
           !MCPOAuthURLPolicy.isSameOrigin(url, finalURL) {
            throw MCPAuthError.metadataError(
                "OAuth discovery redirect to non-same-origin URL rejected: \(finalURL)")
        }
        return response
    }

    static func fetchAuthorizationMetadata(
        _ discoveryURL: URL,
        transport: any HTTPTransport
    ) async -> MCPAuthorizationMetadata? {
        guard let response = try? await discoveryGET(discoveryURL, transport: transport),
              response.metadata.statusCode == 200 else {
            return nil
        }
        // Malformed JSON ⇒ try the next candidate (auth.rs:1827-1833).
        return try? JSONDecoder().decode(MCPAuthorizationMetadata.self, from: response.body)
    }

    static func tryDiscoverOAuthServer(
        baseURL: URL,
        transport: any HTTPTransport
    ) async -> MCPAuthorizationMetadata? {
        for candidate in discoveryURLs(for: baseURL) {
            if let metadata = await fetchAuthorizationMetadata(candidate, transport: transport) {
                return metadata
            }
        }
        return nil
    }

    /// Probe `url` for a protected-resource-metadata pointer: 200 means the
    /// URL itself is the metadata document; 401 means read WWW-Authenticate
    /// (auth.rs:1966-2004). Returns the URL plus any advertised scopes.
    static func fetchResourceMetadataURL(
        _ url: URL,
        baseURL: URL,
        transport: any HTTPTransport
    ) async -> (url: URL, wwwAuthScopes: [String])? {
        guard let response = try? await discoveryGET(url, transport: transport) else {
            return nil
        }
        if response.metadata.statusCode == 200 {
            return (url, [])
        }
        guard response.metadata.statusCode == 401 else { return nil }
        for (name, value) in response.metadata.headers
        where name.lowercased() == "www-authenticate" {
            let params = mcpExtractWWWAuthenticateParams(header: value, baseURL: baseURL)
            if let metadataURL = params.resourceMetadataURL {
                let scopes = params.scope?
                    .split(whereSeparator: \.isWhitespace)
                    .map(String.init) ?? []
                return (metadataURL, scopes)
            }
        }
        return nil
    }

    static func fetchResourceMetadata(
        _ url: URL,
        transport: any HTTPTransport
    ) async -> MCPResourceServerMetadata? {
        guard let response = try? await discoveryGET(url, transport: transport),
              response.metadata.statusCode == 200 else {
            return nil
        }
        return try? JSONDecoder().decode(MCPResourceServerMetadata.self, from: response.body)
    }

    /// RFC 8707-adjacent resource identifier equality with root-slash
    /// tolerance (auth.rs:1925-1936).
    static func resourceIdentifiersMatch(expected: String, actual: String) -> Bool {
        func isRootResource(_ value: String) -> Bool {
            guard let url = URL(string: value) else { return false }
            return (url.path.isEmpty || url.path == "/") && url.query == nil && url.fragment == nil
        }
        if expected == actual { return true }
        if isRootResource(expected), actual == String(expected.reversed().drop(while: { $0 == "/" }).reversed()) {
            return true
        }
        if isRootResource(actual), expected == String(actual.reversed().drop(while: { $0 == "/" }).reversed()) {
            return true
        }
        return false
    }

    /// Full SEP-985 discovery. Returns the metadata plus scope hints found on
    /// the way (WWW-Authenticate scope, resource metadata scopes_supported).
    public static func discoverMetadata(
        baseURL: URL,
        transport: any HTTPTransport
    ) async throws -> (
        metadata: MCPAuthorizationMetadata,
        wwwAuthScopes: [String],
        resourceScopes: [String]
    ) {
        // 1. Protected resource metadata first (auth.rs:1836-1903).
        var resourceMetadataTarget: (url: URL, wwwAuthScopes: [String])? =
            await fetchResourceMetadataURL(baseURL, baseURL: baseURL, transport: transport)
        if resourceMetadataTarget == nil {
            for path in wellKnownPaths(basePath: baseURL.path, resource: "oauth-protected-resource") {
                guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true) else {
                    continue
                }
                components.query = nil
                components.fragment = nil
                components.path = path
                guard let candidate = components.url else { continue }
                if let found = await fetchResourceMetadataURL(
                    candidate, baseURL: baseURL, transport: transport
                ) {
                    resourceMetadataTarget = found
                    break
                }
            }
        }

        if let target = resourceMetadataTarget,
           let resourceMetadata = await fetchResourceMetadata(target.url, transport: transport) {
            // Resource identifier must match the server we are connecting to
            // (auth.rs:1905-1922) — a mismatch is an error, not a fall-through.
            guard let resource = resourceMetadata.resource else {
                throw MCPAuthError.metadataError(
                    "Protected resource metadata missing required resource field")
            }
            guard resourceIdentifiersMatch(expected: baseURL.absoluteString, actual: resource) else {
                throw MCPAuthError.metadataError(
                    "Protected resource metadata resource mismatch: "
                        + "expected '\(baseURL.absoluteString)', got '\(resource)'")
            }
            let resourceScopes = resourceMetadata.scopesSupported ?? []

            var candidates: [String] = []
            if let single = resourceMetadata.authorizationServer { candidates.append(single) }
            if let list = resourceMetadata.authorizationServers { candidates.append(contentsOf: list) }

            for candidate in candidates {
                let trimmed = candidate.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                let candidateURL: URL?
                if let absolute = URL(string: trimmed), absolute.scheme != nil {
                    candidateURL = absolute
                } else {
                    candidateURL = URL(string: trimmed, relativeTo: target.url)?.absoluteURL
                }
                guard let asURL = candidateURL else { continue }
                guard MCPOAuthURLPolicy.isAllowedAuthorizationServerMetadataURL(asURL) else {
                    continue
                }
                if asURL.path.contains("/.well-known/") {
                    if let metadata = await fetchAuthorizationMetadata(asURL, transport: transport) {
                        return (metadata, target.wwwAuthScopes, resourceScopes)
                    }
                    continue
                }
                if let metadata = await tryDiscoverOAuthServer(baseURL: asURL, transport: transport) {
                    return (metadata, target.wwwAuthScopes, resourceScopes)
                }
            }
        }

        // 2. Direct discovery on the server URL (auth.rs:1073-1075).
        if let metadata = await tryDiscoverOAuthServer(baseURL: baseURL, transport: transport) {
            return (metadata, resourceMetadataTarget?.wwwAuthScopes ?? [], [])
        }

        // 3. Never guess endpoints (auth.rs:1077-1079).
        throw MCPAuthError.noAuthorizationSupport
    }
}

// MARK: - Authorization manager

/// Pending PKCE authorization state (rmcp StoredAuthorizationState,
/// auth.rs:282-290), keyed by the CSRF `state` value and deleted on use.
struct MCPPendingAuthorization: Sendable {
    var pkceVerifier: String
    var expectedIssuer: String?
    var requireIssuer: Bool
}

/// Client name advertised during Dynamic Client Registration; surfaces on
/// third-party consent screens (oauth.rs:22-25).
public let mcpOAuthClientName = "Grok"

/// The used subset of rmcp's `AuthorizationManager`, backed by the on-disk
/// per-server credential storage. One instance per (server name, URL).
public actor MCPAuthorizationManager {
    public let baseURL: URL
    let transport: any HTTPTransport
    let storage: any MCPServerCredentialStorage
    /// Injectable clock (epoch seconds) so expiry tests are deterministic.
    let now: @Sendable () -> UInt64

    var metadata: MCPAuthorizationMetadata?
    var clientID: String?
    var clientSecret: String?
    var redirectURI: String?
    var pendingAuthorizations: [String: MCPPendingAuthorization] = [:]
    var currentScopes: [String] = []
    var wwwAuthScopes: [String] = []
    var resourceScopes: [String] = []

    /// Proactive refresh buffer (rmcp REFRESH_BUFFER_SECS, auth.rs:1616).
    static let refreshBufferSeconds: UInt64 = 30

    public init(
        baseURL: URL,
        transport: any HTTPTransport,
        storage: any MCPServerCredentialStorage,
        now: @escaping @Sendable () -> UInt64 = {
            UInt64(max(0, Date().timeIntervalSince1970))
        }
    ) {
        self.baseURL = baseURL
        self.transport = transport
        self.storage = storage
        self.now = now
    }

    public func currentMetadata() -> MCPAuthorizationMetadata? { metadata }

    public func setMetadata(_ metadata: MCPAuthorizationMetadata) {
        self.metadata = metadata
    }

    /// Discover metadata for this manager's base URL and retain the scope
    /// hints for `selectScopes`.
    @discardableResult
    public func discoverMetadata() async throws -> MCPAuthorizationMetadata {
        let discovered = try await MCPOAuthDiscovery.discoverMetadata(
            baseURL: baseURL, transport: transport)
        wwwAuthScopes = discovered.wwwAuthScopes
        resourceScopes = discovered.resourceScopes
        return discovered.metadata
    }

    /// Load stored credentials and configure the client from them
    /// (auth.rs:1034-1047). Discovers metadata when absent. Returns `true`
    /// when a token-bearing entry exists.
    @discardableResult
    public func initializeFromStore() async throws -> Bool {
        guard let stored = try storage.load(), stored.tokenResponse != nil else {
            return false
        }
        if metadata == nil {
            metadata = try await discoverMetadata()
        }
        clientID = stored.clientId
        if redirectURI == nil {
            // rmcp's configure_client_id quirk: the stored path re-registers
            // the base URL as redirect_uri (auth.rs:1284-1294). Only token
            // refresh/attachment run from here, which never send it.
            redirectURI = baseURL.absoluteString
        }
        return true
    }

    /// Configure a client (BYO credentials or a fresh DCR result).
    public func configureClient(
        clientID: String,
        clientSecret: String? = nil,
        redirectURI: String
    ) throws {
        guard metadata != nil else { throw MCPAuthError.noAuthorizationSupport }
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.redirectURI = redirectURI
    }

    /// RFC 8414: bail early when `response_types_supported` is present and
    /// excludes "code" (auth.rs:1148-1177).
    func validateServerMetadata() throws {
        guard let metadata else { return }
        if let supported = metadata.responseTypesSupported, !supported.contains("code") {
            throw MCPAuthError.invalidScope("code")
        }
    }

    /// Dynamic client registration as a public native client
    /// (auth.rs:1179-1280).
    public func registerClient(
        name: String,
        redirectURI: String,
        scopes: [String]
    ) async throws {
        guard let metadata else { throw MCPAuthError.noAuthorizationSupport }
        guard let registrationEndpoint = metadata.registrationEndpoint,
              let registrationURL = URL(string: registrationEndpoint) else {
            throw MCPAuthError.registrationFailed("Dynamic client registration not supported")
        }
        try validateServerMetadata()

        var request: [String: JSONValue] = [
            "client_name": .string(name),
            "redirect_uris": .array([.string(redirectURI)]),
            "grant_types": .array([.string("authorization_code"), .string("refresh_token")]),
            "token_endpoint_auth_method": .string("none"),
            "response_types": .array([.string("code")]),
            "application_type": .string("native"),
        ]
        if !scopes.isEmpty {
            request["scope"] = .string(scopes.joined(separator: " "))
        }
        let body: Data
        do {
            body = try JSONEncoder().encode(JSONValue.object(request))
        } catch {
            throw MCPAuthError.registrationFailed(String(describing: error))
        }

        let response: HTTPResponse
        do {
            response = try await transport.send(HTTPRequest(
                method: .post,
                url: registrationURL,
                headers: ["Content-Type": "application/json"],
                body: body,
                timeout: 30
            ))
        } catch {
            throw MCPAuthError.registrationFailed("HTTP request error: \(error)")
        }
        guard (200..<300).contains(response.metadata.statusCode) else {
            let text = String(decoding: response.body, as: UTF8.self)
            throw MCPAuthError.registrationFailed(
                "HTTP \(response.metadata.statusCode): \(text)")
        }
        guard case .object(let registered)? =
                try? JSONDecoder().decode(JSONValue.self, from: response.body),
              case .string(let registeredClientID)? = registered["client_id"] else {
            throw MCPAuthError.registrationFailed("analyze response error: missing client_id")
        }
        // An empty client_secret means "public client", never an empty
        // password (auth.rs:1265-1272).
        var registeredSecret: String?
        if case .string(let secret)? = registered["client_secret"], !secret.isEmpty {
            registeredSecret = secret
        }
        clientID = registeredClientID
        clientSecret = registeredSecret
        self.redirectURI = redirectURI
    }

    /// SEP-835 scope selection ladder (auth.rs:1372-1435): WWW-Authenticate
    /// scope → protected resource scopes_supported → AS scopes_supported →
    /// defaults; append `offline_access` when the AS advertises it (SEP-2207).
    public func selectScopes(
        wwwAuthenticateScope: String? = nil,
        defaultScopes: [String] = []
    ) -> [String] {
        var scopes: [String]
        if let scope = wwwAuthenticateScope {
            scopes = scope.split(whereSeparator: \.isWhitespace).map(String.init)
        } else if !wwwAuthScopes.isEmpty {
            scopes = wwwAuthScopes
        } else if !resourceScopes.isEmpty {
            scopes = resourceScopes
        } else if let supported = metadata?.scopesSupported, !supported.isEmpty {
            scopes = supported
        } else {
            scopes = defaultScopes
        }
        addOfflineAccessIfSupported(&scopes)
        return scopes
    }

    func addOfflineAccessIfSupported(_ scopes: inout [String]) {
        guard !scopes.isEmpty, !scopes.contains("offline_access") else { return }
        if metadata?.scopesSupported?.contains("offline_access") == true {
            scopes.append("offline_access")
        }
    }

    /// Build the authorization URL: PKCE S256, CSRF state, and the RFC 8707
    /// `resource` indicator (auth.rs:1297-1346). The pending state records
    /// the expected issuer for RFC 9207 validation at exchange time.
    public func authorizationURL(scopes: [String]) throws -> URL {
        guard let metadata else { throw MCPAuthError.noAuthorizationSupport }
        guard let clientID, let redirectURI else {
            throw MCPAuthError.internalError("OAuth client not configured")
        }
        try validateServerMetadata()

        let pkce = MCPPKCE.generate()
        let state = mcpBase64URL(mcpRandomBytes(16))

        var pairs: [(String, String)] = [
            ("response_type", "code"),
            ("client_id", clientID),
            ("state", state),
            ("code_challenge", pkce.challenge),
            ("code_challenge_method", "S256"),
            ("redirect_uri", redirectURI),
            ("resource", baseURL.absoluteString),
        ]
        if !scopes.isEmpty {
            pairs.append(("scope", scopes.joined(separator: " ")))
        }
        let separator = metadata.authorizationEndpoint.contains("?") ? "&" : "?"
        guard let url = URL(string: metadata.authorizationEndpoint + separator + mcpFormEncode(pairs)) else {
            throw MCPAuthError.internalError("invalid authorization endpoint URL")
        }
        pendingAuthorizations[state] = MCPPendingAuthorization(
            pkceVerifier: pkce.verifier,
            expectedIssuer: metadata.issuer,
            requireIssuer: metadata.issParameterSupported
        )
        return url
    }

    /// RFC 9207 issuer validation (auth.rs:1480-1512).
    static func validateAuthorizationResponseIssuer(
        pending: MCPPendingAuthorization,
        receivedIssuer: String?
    ) throws {
        guard let expected = pending.expectedIssuer else {
            if receivedIssuer != nil || pending.requireIssuer {
                throw MCPAuthError.authorizationFailed(
                    "Authorization callback issuer cannot be validated because "
                        + "expected issuer was not recorded")
            }
            return
        }
        guard let received = receivedIssuer else {
            if pending.requireIssuer {
                throw MCPAuthError.authorizationServerMissingIssuer(expected: expected)
            }
            return
        }
        if received != expected {
            throw MCPAuthError.authorizationServerMismatch(expected: expected, received: received)
        }
    }

    /// Exchange the authorization code (auth.rs:1527-1605). Persists the
    /// resulting credentials through the store on success.
    @discardableResult
    public func exchangeCode(
        code: String,
        state: String,
        issuer: String? = nil
    ) async throws -> MCPOAuthTokenResponse {
        guard let clientID else {
            throw MCPAuthError.internalError("OAuth client not configured")
        }
        guard let pending = pendingAuthorizations[state] else {
            throw MCPAuthError.internalError("Authorization state not found")
        }
        // One-time use (auth.rs:1545-1546).
        pendingAuthorizations.removeValue(forKey: state)
        try Self.validateAuthorizationResponseIssuer(pending: pending, receivedIssuer: issuer)

        var pairs: [(String, String)] = [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("code_verifier", pending.pkceVerifier),
            ("resource", baseURL.absoluteString),
        ]
        if let redirectURI {
            pairs.append(("redirect_uri", redirectURI))
        }
        let token = try await postTokenRequest(pairs, clientID: clientID) { detail in
            MCPAuthError.tokenExchangeFailed(detail)
        }

        let grantedScopes = token.scopes
        currentScopes = grantedScopes
        try storage.save(MCPStoredCredentials(
            clientId: clientID,
            tokenResponse: token,
            grantedScopes: grantedScopes,
            tokenReceivedAt: now()
        ))
        return token
    }

    /// Refresh the access token (auth.rs:1672-1728). When the response omits
    /// a refresh token, the previous one is kept (RFC 6749 §6). Persists on
    /// success.
    @discardableResult
    public func refreshToken() async throws -> MCPOAuthTokenResponse {
        guard let stored = try storage.load() else {
            throw MCPAuthError.authorizationRequired
        }
        guard let current = stored.tokenResponse else {
            throw MCPAuthError.authorizationRequired
        }
        guard let refreshToken = current.refreshToken else {
            throw MCPAuthError.tokenRefreshFailed("No refresh token available")
        }
        if metadata == nil {
            metadata = try await discoverMetadata()
        }
        let clientID = self.clientID ?? stored.clientId
        self.clientID = clientID

        var refreshScopes = stored.grantedScopes
        addOfflineAccessIfSupported(&refreshScopes)
        var pairs: [(String, String)] = [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
        ]
        if !refreshScopes.isEmpty {
            pairs.append(("scope", refreshScopes.joined(separator: " ")))
        }
        var token = try await postTokenRequest(pairs, clientID: clientID) { detail in
            MCPAuthError.tokenRefreshFailed(detail)
        }
        if token.refreshToken == nil {
            token.refreshToken = refreshToken
        }
        let grantedScopes = token.scope != nil ? token.scopes : currentScopes
        currentScopes = grantedScopes
        try storage.save(MCPStoredCredentials(
            clientId: clientID,
            tokenResponse: token,
            grantedScopes: grantedScopes,
            tokenReceivedAt: now()
        ))
        return token
    }

    /// Access token for the next request (auth.rs:1618-1651): reads through
    /// the store (so tokens written by another process are picked up),
    /// refreshes when within 30 s of expiry, and returns expiry-less tokens
    /// as-is. No token → `authorizationRequired`.
    public func getAccessToken() async throws -> String {
        guard let stored = try storage.load(),
              let token = stored.tokenResponse else {
            throw MCPAuthError.authorizationRequired
        }
        if let expiresIn = token.expiresIn, let receivedAt = stored.tokenReceivedAt {
            let elapsed = now() >= receivedAt ? now() - receivedAt : 0
            let remaining = expiresIn >= elapsed ? expiresIn - elapsed : 0
            if remaining < Self.refreshBufferSeconds {
                do {
                    let refreshed = try await refreshToken()
                    return refreshed.accessToken
                } catch let error as MCPAuthError {
                    switch error {
                    case .authorizationRequired, .tokenRefreshFailed:
                        // Refresh not possible → re-authorization required
                        // (auth.rs:1657-1669).
                        throw MCPAuthError.authorizationRequired
                    default:
                        throw error
                    }
                }
            }
        }
        return token.accessToken
    }

    /// The token endpoint POST shared by exchange and refresh. Client
    /// authentication follows rmcp: public clients put `client_id` in the
    /// body; a configured secret uses HTTP Basic unless the AS advertises
    /// `client_secret_post` without `client_secret_basic` (auth.rs:1128-1143).
    private func postTokenRequest(
        _ pairs: [(String, String)],
        clientID: String,
        wrapError: (String) -> MCPAuthError
    ) async throws -> MCPOAuthTokenResponse {
        guard let metadata, let tokenURL = URL(string: metadata.tokenEndpoint) else {
            throw MCPAuthError.internalError("OAuth client not configured")
        }
        var body = pairs
        var headers = [
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json",
        ]
        if let clientSecret {
            if metadata.usesClientSecretPost {
                body.append(("client_id", clientID))
                body.append(("client_secret", clientSecret))
            } else {
                let raw = Data("\(clientID):\(clientSecret)".utf8)
                headers["Authorization"] = "Basic \(raw.base64EncodedString())"
            }
        } else {
            body.append(("client_id", clientID))
        }

        let response: HTTPResponse
        do {
            response = try await transport.send(HTTPRequest(
                method: .post,
                url: tokenURL,
                headers: headers,
                body: Data(mcpFormEncode(body).utf8),
                timeout: 30
            ))
        } catch {
            throw wrapError("Request failed: \(error)")
        }
        guard (200..<300).contains(response.metadata.statusCode) else {
            // Surface the RFC 6749 error code like oauth2's Display does, so
            // terminal-vs-transient classification keys stay recognizable.
            let text = String(decoding: response.body, as: UTF8.self)
            throw wrapError("Server returned error response: \(text)")
        }
        do {
            return try JSONDecoder().decode(MCPOAuthTokenResponse.self, from: response.body)
        } catch {
            throw wrapError("Failed to parse server response: \(error)")
        }
    }
}

// MARK: - Connect-time probe

/// Bounded proactive OAuth probe for HTTP MCP servers, the interactive-mode
/// arm of upstream's `discover_and_prepare_auth` under its 5-second
/// `OAUTH_DISCOVERY_TIMEOUT` (servers.rs:1078, 1826-1906, 4299-4332): an
/// inconclusive probe (error or timeout) reads as "no OAuth support" so a
/// plain-HTTP server keeps connecting.
public enum MCPOAuthProbe {
    public static let discoveryTimeoutSeconds: TimeInterval = 5

    public static func serverAdvertisesOAuth(
        url: URL,
        transport: any HTTPTransport,
        timeoutSeconds: TimeInterval = discoveryTimeoutSeconds
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                (try? await MCPOAuthDiscovery.discoverMetadata(
                    baseURL: url, transport: transport)) != nil
            }
            group.addTask {
                try? await Task.sleep(
                    nanoseconds: UInt64(max(0, timeoutSeconds) * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}

// MARK: - Transport seam conformance

extension MCPAuthorizationManager: MCPAuthorizationProviding {
    public func accessToken() async throws -> String {
        try await getAccessToken()
    }

    /// Non-browser 401 recovery: the disk-fresh and refresh arms of
    /// upstream's `force_reauth(false)` ladder (servers.rs:2884-2983). The
    /// browser arm is not reachable from a transport failure in this port —
    /// it stays behind the explicit `mcp login` trigger.
    public func handleUnauthorized(staleToken: String?) async -> Bool {
        // Disk arm: another session or process may have written a DIFFERENT
        // token while ours went stale. Comparing against the token just used
        // is load-bearing — any-token-present would retry with the same
        // stale value (servers.rs:2901-2943).
        if let fresh = (try? storage.load())?.tokenResponse?.accessToken,
           fresh != staleToken {
            return true
        }
        // Refresh arm (servers.rs:2946-2963).
        return (try? await refreshToken()) != nil
    }
}

