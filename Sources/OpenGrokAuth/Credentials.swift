// Credentials.swift
//
// GrokAuthCredentials + HttpAuth header application.
// Deployment key → bare Bearer; user token → Bearer + X-XAI-Token-Auth.

import Foundation
import OpenGrokHTTP
import OpenGrokSecrets

/// Header name for user/OAuth token auth marker.
public let xaiTokenAuthHeader = "X-XAI-Token-Auth"
/// Header value for CLI user tokens.
public let xaiTokenAuthValue = "xai-grok-cli"

/// Apply auth headers to outbound requests.
public protocol HttpAuth: Sendable {
    /// Mutate `headers` in place for the given base URL.
    func apply(to headers: inout [String: String], baseURL: String)
}

/// Credentials for authenticating with grok backend services.
///
/// Deployment key takes precedence when both are present (bare Bearer).
/// User token sends Bearer + `X-XAI-Token-Auth: xai-grok-cli`.
public struct GrokAuthCredentials: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public var userToken: String?
    public var deploymentKey: String?
    public var alphaTestKey: String?

    public init(
        userToken: String? = nil,
        deploymentKey: String? = nil,
        alphaTestKey: String? = nil
    ) {
        self.userToken = userToken
        self.deploymentKey = deploymentKey
        self.alphaTestKey = alphaTestKey
    }

    /// Static credentials from a snapshot token.
    public static func new(userToken: String?) -> GrokAuthCredentials {
        GrokAuthCredentials(userToken: userToken)
    }

    public var description: String {
        "GrokAuthCredentials(userToken: \(userToken.map { _ in SecretRedaction.secret } ?? "nil"), deploymentKey: \(deploymentKey.map { _ in SecretRedaction.secret } ?? "nil"))"
    }

    public var debugDescription: String { description }

    /// Error hint for 401 responses based on which credential was sent.
    public var authErrorHint: String {
        if deploymentKey != nil {
            return "Your GROK_DEPLOYMENT_KEY is invalid or expired. Please contact a team admin."
        } else if userToken != nil {
            return "Your auth token is invalid or expired. Run `open-grok login` to re-authenticate."
        } else {
            return "Not authenticated."
        }
    }

    /// Wire bearer that would be sent (deployment key first).
    public var wireBearer: String? {
        deploymentKey ?? userToken
    }

    /// Whether X-XAI-Token-Auth should be sent (false for deployment keys).
    public var needsTokenAuthHeader: Bool {
        deploymentKey == nil && userToken != nil
    }

    public func apply(to headers: inout [String: String], baseURL: String = "") {
        _ = baseURL
        if let key = deploymentKey {
            headers["Authorization"] = "Bearer \(key)"
            headers.removeValue(forKey: xaiTokenAuthHeader)
        } else if let token = userToken {
            headers["Authorization"] = "Bearer \(token)"
            headers[xaiTokenAuthHeader] = xaiTokenAuthValue
        }
    }

    /// Apply credentials onto an HTTPRequest, returning a copy.
    public func applying(to request: HTTPRequest) -> HTTPRequest {
        var req = request
        apply(to: &req.headers)
        return req
    }
}

extension GrokAuthCredentials: HttpAuth {}

/// Build collector / OTLP identity headers from one atomic snapshot.
///
/// Never mixes fields from two snapshots.
public struct CollectorAuthHeaders: Sendable, Equatable {
    public var authorization: String?
    public var userID: String?
    public var teamID: String?
    public var organizationID: String?
    public var deploymentID: String?
    public var apiKeyID: String?
    public var tokenAuth: String?

    public init(snapshot: CredentialSnapshot, needsTokenAuthHeader: Bool) {
        if let token = snapshot.token {
            authorization = "Bearer \(token)"
        } else {
            authorization = nil
        }
        userID = snapshot.userID
        teamID = snapshot.teamID
        organizationID = snapshot.organizationID
        deploymentID = snapshot.deploymentID
        apiKeyID = snapshot.apiKeyID
        if needsTokenAuthHeader, snapshot.token != nil, snapshot.deploymentID == nil {
            tokenAuth = xaiTokenAuthValue
        } else {
            tokenAuth = nil
        }
    }

    public func apply(to headers: inout [String: String]) {
        if let authorization {
            headers["Authorization"] = authorization
        }
        if let tokenAuth {
            headers[xaiTokenAuthHeader] = tokenAuth
        }
        if let userID {
            headers["x-grok-user-id"] = userID
        }
        if let teamID {
            headers["x-grok-team-id"] = teamID
        }
        if let organizationID {
            headers["x-grok-organization-id"] = organizationID
        }
        if let deploymentID {
            headers["x-grok-deployment-id"] = deploymentID
        }
        if let apiKeyID {
            headers["x-grok-api-key-id"] = apiKeyID
        }
    }

    /// Redacted description — never includes bearer.
    public var redactedDescription: String {
        "CollectorAuthHeaders(hasAuth: \(authorization != nil), userID: \(userID ?? "nil"), teamID: \(teamID ?? "nil"), orgID: \(organizationID ?? "nil"), deploymentID: \(deploymentID ?? "nil"), apiKeyID: \(apiKeyID ?? "nil"))"
    }
}
