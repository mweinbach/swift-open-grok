// PKCE.swift
//
// OAuth 2.1 PKCE (S256) helpers for browser and Codex login.

import Foundation

/// PKCE code_verifier + S256 code_challenge pair.
public struct PKCE: Sendable, Equatable {
    public var codeVerifier: String
    public var codeChallenge: String

    public init(codeVerifier: String, codeChallenge: String) {
        self.codeVerifier = codeVerifier
        self.codeChallenge = codeChallenge
    }

    /// Generate a fresh PKCE pair (32 random bytes → base64url verifier).
    public static func generate() -> PKCE {
        let verifier = AuthCrypto.randomBase64URL(byteCount: 32)
        return from(verifier: verifier)
    }

    /// Compute S256 challenge for a known verifier (tests / device exchange).
    public static func from(verifier: String) -> PKCE {
        let digest = AuthCrypto.sha256(verifier)
        let challenge = AuthCrypto.base64URLEncode(digest)
        return PKCE(codeVerifier: verifier, codeChallenge: challenge)
    }
}

/// Random OAuth `state` parameter.
public func generateOAuthState() -> String {
    AuthCrypto.randomBase64URL(byteCount: 16)
}

/// Random OIDC `nonce`.
public func generateOIDCNonce() -> String {
    AuthCrypto.randomBase64URL(byteCount: 16)
}
