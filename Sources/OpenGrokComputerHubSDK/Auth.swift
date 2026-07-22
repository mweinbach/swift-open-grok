// Auth.swift
//
// Hub authentication credentials and principal keys.

import Foundation
import OpenGrokComputerHubCore
import OpenGrokToolProtocol

/// Credential material presented at hub connect. Never log secrets.
public enum AuthCredential: Sendable, Equatable {
    case bearer(token: String)
    case apiKey(String)
    case none

    /// Redacted description safe for logs.
    public var redactedDescription: String {
        switch self {
        case .bearer: return "bearer:***"
        case .apiKey: return "api_key:***"
        case .none: return "none"
        }
    }
}

public struct AuthIdentity: Sendable, Equatable, Hashable {
    public var userId: UserId
    public var sessions: [SessionId]
    public var scopes: [String]

    public init(userId: UserId, sessions: [SessionId] = [], scopes: [String] = []) {
        self.userId = userId
        self.sessions = sessions
        self.scopes = scopes
    }

    public func asPrincipal() -> Principal {
        var p = Principal.new(userId)
        for s in sessions { p = p.withSession(s) }
        for sc in scopes { p = p.withScope(sc) }
        return p
    }
}

/// Stable key for connection pool entries: `(url, principal)`.
public struct PrincipalKey: Hashable, Sendable, Equatable {
    public var url: String
    public var userId: UserId

    public init(url: String, userId: UserId) {
        self.url = url
        self.userId = userId
    }
}

public protocol AuthProvider: Sendable {
    func credential() async throws -> AuthCredential
    func identity() async throws -> AuthIdentity
}

public struct StaticAuthProvider: AuthProvider {
    public var cred: AuthCredential
    public var id: AuthIdentity

    public init(credential: AuthCredential, identity: AuthIdentity) {
        self.cred = credential
        self.id = identity
    }

    public func credential() async throws -> AuthCredential { cred }
    public func identity() async throws -> AuthIdentity { id }
}
