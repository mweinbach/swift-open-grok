// OIDCIdTokenValidator.swift
//
// JWKS-backed id_token signature and claim validation for OIDC browser login.
// Ports upstream `validate_and_extract_user_info` (protocol.rs:639-715).

import Foundation
import OpenGrokHTTP

#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Security)
import Security
#endif

/// Parsed id_token claims returned after JWKS validation succeeds.
public struct OIDCIdTokenClaims: Sendable, Equatable {
    public var sub: String
    public var iss: String?
    public var email: String?

    public init(sub: String, iss: String? = nil, email: String? = nil) {
        self.sub = sub
        self.iss = iss
        self.email = email
    }
}

private let allowedIDTokenAlgs: Set<String> = [
    "RS256", "RS384", "RS512",
    "PS256", "PS384", "PS512",
    "ES256", "ES384",
    "EdDSA",
]

/// Validate an OIDC id_token: fetch JWKS, verify signature, check claims.
public func validateOIDCIdToken(
    token: String,
    discovery: OIDCDiscovery,
    expectedIssuer: String,
    expectedClientID: String,
    expectedNonce: String,
    transport: any HTTPTransport,
    now: Date = Date()
) async throws -> OIDCIdTokenClaims {
    try Task.checkCancellation()

    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3,
          !parts[0].isEmpty,
          !parts[1].isEmpty,
          !parts[2].isEmpty
    else {
        throw idTokenValidationFailed("malformed JWT")
    }

    guard let headerData = AuthCrypto.base64URLDecode(String(parts[0])),
          let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any]
    else {
        throw idTokenValidationFailed("malformed JWT header")
    }

    guard let alg = header["alg"] as? String, !alg.isEmpty else {
        throw idTokenValidationFailed("OIDC id_token missing alg header")
    }
    guard let kid = header["kid"] as? String, !kid.isEmpty else {
        throw XAILoginFlowError("OIDC id_token validation failed: OIDC id_token missing kid header")
    }

    try ensureAlgAllowed(alg, discoverySupported: discovery.idTokenSigningAlgValuesSupported)

    guard let jwksURI = discovery.jwksURI, !jwksURI.isEmpty else {
        throw XAILoginFlowError("OIDC id_token validation failed: OIDC discovery missing jwks_uri")
    }
    guard let jwksURL = URL(string: jwksURI) else {
        throw idTokenValidationFailed("invalid jwks_uri")
    }

    let jwks = try await fetchJWKS(url: jwksURL, transport: transport)
    guard let jwk = jwks.first(where: { ($0["kid"] as? String) == kid }) else {
        throw XAILoginFlowError(
            "OIDC id_token validation failed: OIDC JWK not found for kid=\(kid)")
    }

    let signingInput = Data("\(parts[0]).\(parts[1])".utf8)
    guard let signature = AuthCrypto.base64URLDecode(String(parts[2])) else {
        throw idTokenValidationFailed("malformed JWT signature")
    }

    try verifyJWTSignature(alg: alg, jwk: jwk, signingInput: signingInput, signature: signature)

    guard let payloadData = AuthCrypto.base64URLDecode(String(parts[1])),
          let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
    else {
        throw idTokenValidationFailed("malformed JWT payload")
    }

    try validateIDTokenClaims(
        payload,
        expectedIssuer: expectedIssuer,
        expectedClientID: expectedClientID,
        expectedNonce: expectedNonce,
        now: now
    )

    guard let sub = payload["sub"] as? String, !sub.isEmpty else {
        throw idTokenValidationFailed("OIDC id_token missing sub claim")
    }

    return OIDCIdTokenClaims(
        sub: sub,
        iss: payload["iss"] as? String,
        email: payload["email"] as? String
    )
}

// MARK: - Algorithm policy

private func ensureAlgAllowed(_ alg: String, discoverySupported: [String]?) throws {
    if alg.hasPrefix("HS") {
        throw XAILoginFlowError(
            "OIDC id_token validation failed: OIDC id_token uses unsupported algorithm: \(alg)")
    }
    guard allowedIDTokenAlgs.contains(alg) else {
        throw XAILoginFlowError(
            "OIDC id_token validation failed: OIDC id_token uses unsupported algorithm: \(alg)")
    }
    if let supported = discoverySupported, !supported.isEmpty, !supported.contains(alg) {
        throw XAILoginFlowError(
            "OIDC id_token validation failed: OIDC id_token alg \(alg) is not in discovery supported list")
    }
}

// MARK: - JWKS fetch

private func fetchJWKS(
    url: URL,
    transport: any HTTPTransport
) async throws -> [[String: Any]] {
    try Task.checkCancellation()
    let request = HTTPRequest(method: .get, url: url, timeout: 10)
    let response = try await transport.send(request)
    guard (200..<300).contains(response.metadata.statusCode),
          let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
          let keys = json["keys"] as? [[String: Any]]
    else {
        throw idTokenValidationFailed("JWKS fetch failed: HTTP \(response.metadata.statusCode)")
    }
    return keys
}

// MARK: - Signature verification

private func verifyJWTSignature(
    alg: String,
    jwk: [String: Any],
    signingInput: Data,
    signature: Data
) throws {
    switch alg {
    case "RS256", "RS384", "RS512", "PS256", "PS384", "PS512":
        #if canImport(Security)
        try verifyRSASignature(alg: alg, jwk: jwk, signingInput: signingInput, signature: signature)
        #else
        throw idTokenValidationFailed("RSA signature verification unavailable on this platform")
        #endif
    case "ES256", "ES384":
        #if canImport(CryptoKit)
        try verifyECDSASignature(alg: alg, jwk: jwk, signingInput: signingInput, signature: signature)
        #else
        throw idTokenValidationFailed("ECDSA signature verification unavailable on this platform")
        #endif
    case "EdDSA":
        #if canImport(CryptoKit)
        try verifyEdDSASignature(jwk: jwk, signingInput: signingInput, signature: signature)
        #else
        throw idTokenValidationFailed("EdDSA signature verification unavailable on this platform")
        #endif
    default:
        throw idTokenValidationFailed("unsupported algorithm: \(alg)")
    }
}

#if canImport(Security)
private func verifyRSASignature(
    alg: String,
    jwk: [String: Any],
    signingInput: Data,
    signature: Data
) throws {
    guard (jwk["kty"] as? String) == "RSA",
          let nStr = jwk["n"] as? String,
          let eStr = jwk["e"] as? String,
          let modulus = AuthCrypto.base64URLDecode(nStr),
          let exponent = AuthCrypto.base64URLDecode(eStr)
    else {
        throw idTokenValidationFailed("invalid RSA JWK")
    }

    let keyData = rsaPublicKeyPKCS1DER(modulus: modulus, exponent: exponent)
    let attributes: [String: Any] = [
        kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
        kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
    ]
    var error: Unmanaged<CFError>?
    guard let secKey = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, &error)
    else {
        throw idTokenValidationFailed("invalid RSA JWK")
    }

    let algorithm: SecKeyAlgorithm
    switch alg {
    case "RS256": algorithm = .rsaSignatureMessagePKCS1v15SHA256
    case "RS384": algorithm = .rsaSignatureMessagePKCS1v15SHA384
    case "RS512": algorithm = .rsaSignatureMessagePKCS1v15SHA512
    case "PS256": algorithm = .rsaSignatureMessagePSSSHA256
    case "PS384": algorithm = .rsaSignatureMessagePSSSHA384
    case "PS512": algorithm = .rsaSignatureMessagePSSSHA512
    default:
        throw idTokenValidationFailed("unsupported RSA algorithm: \(alg)")
    }

    guard SecKeyIsAlgorithmSupported(secKey, .verify, algorithm) else {
        throw idTokenValidationFailed("RSA algorithm not supported: \(alg)")
    }

    var verifyError: Unmanaged<CFError>?
    let ok = SecKeyVerifySignature(
        secKey,
        algorithm,
        signingInput as CFData,
        signature as CFData,
        &verifyError
    )
    guard ok else {
        throw idTokenValidationFailed("invalid signature")
    }
}
#endif

#if canImport(CryptoKit)
private func verifyECDSASignature(
    alg: String,
    jwk: [String: Any],
    signingInput: Data,
    signature: Data
) throws {
    guard (jwk["kty"] as? String) == "EC",
          let crv = jwk["crv"] as? String,
          let xStr = jwk["x"] as? String,
          let yStr = jwk["y"] as? String,
          let x = AuthCrypto.base64URLDecode(xStr),
          let y = AuthCrypto.base64URLDecode(yStr)
    else {
        throw idTokenValidationFailed("invalid EC JWK")
    }

    var point = Data([0x04])
    point.append(x)
    point.append(y)

    let valid: Bool
    switch (alg, crv) {
    case ("ES256", "P-256"):
        let publicKey = try P256.Signing.PublicKey(x963Representation: point)
        let sig = try P256.Signing.ECDSASignature(rawRepresentation: signature)
        valid = publicKey.isValidSignature(sig, for: signingInput)
    case ("ES384", "P-384"):
        let publicKey = try P384.Signing.PublicKey(x963Representation: point)
        let sig = try P384.Signing.ECDSASignature(rawRepresentation: signature)
        valid = publicKey.isValidSignature(sig, for: signingInput)
    default:
        throw idTokenValidationFailed("unsupported EC algorithm/crv: \(alg)/\(crv)")
    }

    guard valid else {
        throw idTokenValidationFailed("invalid signature")
    }
}

private func verifyEdDSASignature(
    jwk: [String: Any],
    signingInput: Data,
    signature: Data
) throws {
    guard (jwk["kty"] as? String) == "OKP",
          (jwk["crv"] as? String) == "Ed25519",
          let xStr = jwk["x"] as? String,
          let x = AuthCrypto.base64URLDecode(xStr)
    else {
        throw idTokenValidationFailed("invalid OKP JWK")
    }

    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: x)
    guard publicKey.isValidSignature(signature, for: signingInput) else {
        throw idTokenValidationFailed("invalid signature")
    }
}
#endif

// MARK: - Claims

private func validateIDTokenClaims(
    _ payload: [String: Any],
    expectedIssuer: String,
    expectedClientID: String,
    expectedNonce: String,
    now: Date
) throws {
    let iss = payload["iss"] as? String
    guard iss == expectedIssuer else {
        throw XAILoginFlowError(
            "OIDC id_token validation failed: OIDC id_token issuer mismatch")
    }

    guard let aud = payload["aud"] else {
        throw idTokenValidationFailed("OIDC id_token missing aud claim")
    }
    guard audienceMatches(aud, expected: expectedClientID) else {
        throw XAILoginFlowError(
            "OIDC id_token validation failed: OIDC id_token audience mismatch")
    }

    guard let exp = numericClaim(payload["exp"]) else {
        throw idTokenValidationFailed("OIDC id_token missing exp claim")
    }
    guard Date(timeIntervalSince1970: exp) > now else {
        throw idTokenValidationFailed("OIDC id_token expired")
    }

    guard let nonce = payload["nonce"] as? String else {
        throw idTokenValidationFailed("OIDC id_token missing nonce claim")
    }
    guard nonce == expectedNonce else {
        throw XAILoginFlowError.nonceMismatch
    }
}

private func audienceMatches(_ aud: Any, expected: String) -> Bool {
    if let s = aud as? String {
        return s == expected
    }
    if let arr = aud as? [Any] {
        return arr.contains { ($0 as? String) == expected }
    }
    return false
}

private func numericClaim(_ value: Any?) -> TimeInterval? {
    if let n = value as? NSNumber { return n.doubleValue }
    if let i = value as? Int { return TimeInterval(i) }
    if let i = value as? Int64 { return TimeInterval(i) }
    if let d = value as? Double { return d }
    return nil
}

// MARK: - ASN.1 (RSA public key PKCS#1 DER for SecKeyCreateWithData)

private func rsaPublicKeyPKCS1DER(modulus: Data, exponent: Data) -> Data {
    encodeASN1Sequence([
        encodeASN1Integer(modulus),
        encodeASN1Integer(exponent),
    ])
}

private func encodeASN1Integer(_ bytes: Data) -> Data {
    var content = bytes
    while content.count > 1, content.first == 0, content[content.index(after: content.startIndex)] & 0x80 == 0 {
        content.removeFirst()
    }
    if content.first.map({ $0 & 0x80 != 0 }) == true {
        content = Data([0x00]) + content
    }
    return Data([0x02]) + encodeASN1Length(content.count) + content
}

private func encodeASN1Sequence(_ parts: [Data]) -> Data {
    let body = parts.reduce(into: Data()) { $0.append($1) }
    return Data([0x30]) + encodeASN1Length(body.count) + body
}

private func encodeASN1Length(_ length: Int) -> Data {
    if length < 128 {
        return Data([UInt8(length)])
    }
    var remaining = length
    var bytes = [UInt8]()
    while remaining > 0 {
        bytes.insert(UInt8(remaining & 0xff), at: 0)
        remaining >>= 8
    }
    return Data([0x80 | UInt8(bytes.count)]) + Data(bytes)
}

private func idTokenValidationFailed(_ detail: String) -> XAILoginFlowError {
    XAILoginFlowError("OIDC id_token validation failed: \(detail)")
}
