// OIDC.swift
//
// OIDC/OAuth2 Auth Code + PKCE protocol helpers (discovery, authorize URL,
// token exchange). Full browser loopback is a seam for the shell layer.

import Foundation
import OpenGrokHTTP
import OpenGrokVersion

/// OIDC discovery document (subset).
public struct OIDCDiscovery: Sendable, Equatable {
    public var issuer: String
    public var authorizationEndpoint: String
    public var tokenEndpoint: String
    public var deviceAuthorizationEndpoint: String?
    public var jwksURI: String?

    public init(
        issuer: String,
        authorizationEndpoint: String,
        tokenEndpoint: String,
        deviceAuthorizationEndpoint: String? = nil,
        jwksURI: String? = nil
    ) {
        self.issuer = issuer
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.deviceAuthorizationEndpoint = deviceAuthorizationEndpoint
        self.jwksURI = jwksURI
    }

    public static func fromJSON(_ json: [String: Any]) -> OIDCDiscovery? {
        guard let issuer = json["issuer"] as? String,
              let auth = json["authorization_endpoint"] as? String,
              let token = json["token_endpoint"] as? String
        else { return nil }
        return OIDCDiscovery(
            issuer: issuer,
            authorizationEndpoint: auth,
            tokenEndpoint: token,
            deviceAuthorizationEndpoint: json["device_authorization_endpoint"] as? String,
            jwksURI: json["jwks_uri"] as? String
        )
    }
}

/// Fetch OIDC discovery document.
public func fetchOIDCDiscovery(
    issuer: String,
    transport: any HTTPTransport
) async throws -> OIDCDiscovery {
    try Task.checkCancellation()
    let base = issuer.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard let url = URL(string: "\(base)/.well-known/openid-configuration") else {
        throw AuthError.protocolError("invalid issuer")
    }
    let request = HTTPRequest(method: .get, url: url, timeout: 30)
    let response = try await transport.send(request)
    guard (200..<300).contains(response.metadata.statusCode),
          let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
          let discovery = OIDCDiscovery.fromJSON(json)
    else {
        throw AuthError.protocolError(
            "OIDC discovery failed: HTTP \(response.metadata.statusCode)"
        )
    }
    return discovery
}

/// Build OAuth2 authorize URL with PKCE.
public func buildAuthorizeURL(
    authorizationEndpoint: String,
    clientID: String,
    redirectURI: String,
    scopes: [String],
    pkce: PKCE,
    state: String,
    nonce: String? = nil,
    extraQuery: [String: String] = [:]
) -> URL? {
    guard var components = URLComponents(string: authorizationEndpoint) else { return nil }
    var items: [URLQueryItem] = [
        URLQueryItem(name: "response_type", value: "code"),
        URLQueryItem(name: "client_id", value: clientID),
        URLQueryItem(name: "redirect_uri", value: redirectURI),
        URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
        URLQueryItem(name: "code_challenge", value: pkce.codeChallenge),
        URLQueryItem(name: "code_challenge_method", value: "S256"),
        URLQueryItem(name: "state", value: state),
    ]
    if let nonce {
        items.append(URLQueryItem(name: "nonce", value: nonce))
    }
    for (k, v) in extraQuery.sorted(by: { $0.key < $1.key }) {
        items.append(URLQueryItem(name: k, value: v))
    }
    components.queryItems = items
    return components.url
}

/// Exchange authorization code for tokens.
public func exchangeAuthorizationCode(
    tokenEndpoint: URL,
    clientID: String,
    code: String,
    redirectURI: String,
    codeVerifier: String,
    transport: any HTTPTransport
) async throws -> (accessToken: String, refreshToken: String?, idToken: String?, expiresIn: Int64?) {
    try Task.checkCancellation()
    let body = formURLEncoded([
        "grant_type": "authorization_code",
        "code": code,
        "redirect_uri": redirectURI,
        "client_id": clientID,
        "code_verifier": codeVerifier,
    ])
    let request = HTTPRequest(
        method: .post,
        url: tokenEndpoint,
        headers: [
            "Content-Type": "application/x-www-form-urlencoded",
            // Upstream stamps the client version on every code exchange
            // (`exchange_code`, auth/oidc/protocol.rs:415), both enterprise
            // OIDC and xAI OAuth2.
            "x-grok-client-version": OpenGrokVersion.compiledVersion,
        ],
        body: Data(body.utf8),
        timeout: 30,
        idempotency: .nonIdempotent
    )
    let response = try await transport.send(request)
    guard (200..<300).contains(response.metadata.statusCode),
          let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
          let access = json["access_token"] as? String
    else {
        // Body is not embedded — may contain secrets.
        throw AuthError.protocolError(
            "OIDC token exchange failed: HTTP \(response.metadata.statusCode)"
        )
    }
    return (
        access,
        json["refresh_token"] as? String,
        json["id_token"] as? String,
        int64Value(json["expires_in"])
    )
}

/// Build GrokAuth from OIDC token response fields.
public func buildGrokAuthFromOIDCTokens(
    accessToken: String,
    refreshToken: String?,
    idToken: String?,
    expiresIn: Int64?,
    issuer: String,
    clientID: String,
    now: Date = Date()
) -> GrokAuth {
    var auth = GrokAuth(
        key: accessToken,
        authMode: .oidc,
        createTime: now,
        refreshToken: refreshToken,
        expiresAt: expiresIn.map { now.addingTimeInterval(TimeInterval($0)) },
        oidcIssuer: issuer,
        oidcClientID: clientID
    )
    let claimsSource = idToken.flatMap { decodeJWTPayload($0) }
        ?? decodeJWTPayload(accessToken)
    if let claims = claimsSource {
        if let sub = claims["sub"] as? String { auth.userID = sub }
        if let email = claims["email"] as? String { auth.email = email }
    }
    if let principal = peekAccessTokenPrincipal(accessToken) {
        auth.principalType = principal.principalType
        auth.principalID = principal.principalID
        if auth.teamID == nil { auth.teamID = principal.teamID }
    }
    return auth
}

/// Whether OIDC is configured on GrokComConfig.
public func isOIDCConfigured(_ config: GrokComConfig) -> Bool {
    config.effectiveOIDC != nil
}
