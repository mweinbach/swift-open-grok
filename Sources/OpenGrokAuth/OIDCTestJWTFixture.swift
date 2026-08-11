// OIDCTestJWTFixture.swift
//
// Deterministic RSA/EC JWT signing for OIDC id_token tests (unit + live
// pager login reachability). Lives in the auth module so CLI tests can
// script a JWKS-backed IdP without duplicating SecKey/CryptoKit setup.
// Uses Security + CryptoKit — no third-party JWT libraries.
//
// Both of those are Apple-only, so this fixture cannot exist on Linux without
// taking a swift-crypto dependency. It is compiled out there rather than
// ported, which is why the OIDC id_token suites below it do not run on Linux —
// recorded as a platform coverage gap in PORT_STATUS.md. Do not "fix" a Linux
// build failure here by loosening the validator it exercises.
#if canImport(CryptoKit) && canImport(Security)

import CryptoKit
import Foundation
import Security

public enum OIDCTestJWTFixture: Sendable {
    public static let kid = "test-kid"
    public static let clientID = "client-under-test"
    public static let issuer = "http://127.0.0.1:9"

    public struct RSAFixture: @unchecked Sendable {
        public let privateKey: SecKey
        public let jwkN: String
        public let jwkE: String
    }

    public struct ES256Fixture: Sendable {
        public let privateKey: P256.Signing.PrivateKey
        public let jwkX: String
        public let jwkY: String
    }

    private final class Cache: @unchecked Sendable {
        static let shared = Cache()
        private let lock = NSLock()
        private var rsa: RSAFixture?
        private var es256: ES256Fixture?

        func rsaFixture() throws -> RSAFixture {
            lock.lock()
            defer { lock.unlock() }
            if let rsa { return rsa }
            let fixture = try OIDCTestJWTFixture.generateRSA()
            rsa = fixture
            return fixture
        }

        func es256Fixture() throws -> ES256Fixture {
            lock.lock()
            defer { lock.unlock() }
            if let es256 { return es256 }
            let fixture = try OIDCTestJWTFixture.generateES256()
            es256 = fixture
            return fixture
        }
    }

    public static func rsa() throws -> RSAFixture {
        try Cache.shared.rsaFixture()
    }

    public static func es256() throws -> ES256Fixture {
        try Cache.shared.es256Fixture()
    }

    public static func generateRSA() throws -> RSAFixture {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecAttrIsPermanent as String: false,
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error!.takeRetainedValue() as Error
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let pubData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?
        else {
            throw error!.takeRetainedValue() as Error
        }
        let (modulus, exponent) = try parseRSAPublicKeyPKCS1(pubData)
        return RSAFixture(
            privateKey: privateKey,
            jwkN: AuthCrypto.base64URLEncode(modulus),
            jwkE: AuthCrypto.base64URLEncode(exponent)
        )
    }

    public static func generateES256() throws -> ES256Fixture {
        let privateKey = P256.Signing.PrivateKey()
        let raw = privateKey.publicKey.rawRepresentation
        return ES256Fixture(
            privateKey: privateKey,
            jwkX: AuthCrypto.base64URLEncode(Data(raw.prefix(32))),
            jwkY: AuthCrypto.base64URLEncode(Data(raw.suffix(32)))
        )
    }

    public static func personalClaims(
        nonce: String,
        issuer: String = issuer,
        clientID: String = clientID,
        expiresIn: TimeInterval = 3600,
        now: Date = Date()
    ) -> [String: Any] {
        [
            "sub": "user-42",
            "email": "browser@x.ai",
            "iss": issuer,
            "aud": clientID,
            "nonce": nonce,
            "exp": Int(now.addingTimeInterval(expiresIn).timeIntervalSince1970),
        ]
    }

    public static func signRS256(
        payload: [String: Any],
        privateKey: SecKey,
        kid: String = kid
    ) throws -> String {
        let header: [String: Any] = ["alg": "RS256", "typ": "JWT", "kid": kid]
        let headerData = try JSONSerialization.data(withJSONObject: header)
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        let headerB64 = AuthCrypto.base64URLEncode(headerData)
        let payloadB64 = AuthCrypto.base64URLEncode(payloadData)
        let signingInput = Data("\(headerB64).\(payloadB64)".utf8)

        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            signingInput as CFData,
            &error
        ) as Data? else {
            throw error!.takeRetainedValue() as Error
        }
        return "\(headerB64).\(payloadB64).\(AuthCrypto.base64URLEncode(signature))"
    }

    public static func signES256(
        payload: [String: Any],
        privateKey: P256.Signing.PrivateKey,
        kid: String = kid
    ) throws -> String {
        let header: [String: Any] = ["alg": "ES256", "typ": "JWT", "kid": kid]
        let headerData = try JSONSerialization.data(withJSONObject: header)
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        let headerB64 = AuthCrypto.base64URLEncode(headerData)
        let payloadB64 = AuthCrypto.base64URLEncode(payloadData)
        let signingInput = Data("\(headerB64).\(payloadB64)".utf8)
        let signature = try privateKey.signature(for: signingInput)
        return "\(headerB64).\(payloadB64).\(AuthCrypto.base64URLEncode(signature.rawRepresentation))"
    }

    public static func rsaJWKSJSON(n: String, e: String, kid: String = kid) -> String {
        """
        {"keys":[{"kty":"RSA","alg":"RS256","kid":"\(kid)","use":"sig","n":"\(n)","e":"\(e)"}]}
        """
    }

    public static func es256JWKSJSON(x: String, y: String, kid: String = kid) -> String {
        """
        {"keys":[{"kty":"EC","alg":"ES256","crv":"P-256","kid":"\(kid)","use":"sig","x":"\(x)","y":"\(y)"}]}
        """
    }

    public static func discoveryJSON(
        issuer: String = issuer,
        jwksURI: String? = "\(issuer)/jwks",
        supportedAlgs: [String]? = ["RS256"]
    ) -> String {
        var fields: [String] = [
            "\"issuer\":\"\(issuer)\"",
            "\"authorization_endpoint\":\"\(issuer)/authorize\"",
            "\"token_endpoint\":\"\(issuer)/token\"",
        ]
        if let jwksURI {
            fields.append("\"jwks_uri\":\"\(jwksURI)\"")
        }
        if let supportedAlgs {
            let algs = supportedAlgs.map { "\"\($0)\"" }.joined(separator: ",")
            fields.append("\"id_token_signing_alg_values_supported\":[\(algs)]")
        }
        return "{\(fields.joined(separator: ","))}"
    }
}

// MARK: - ASN.1 RSA public key parse (PKCS#1 from SecKeyCopyExternalRepresentation)

private func parseRSAPublicKeyPKCS1(_ data: Data) throws -> (modulus: Data, exponent: Data) {
    var parser = ASN1Reader(data: data)
    try parser.expectTag(0x30)
    let seqLen = try parser.readLength()
    let seqEnd = parser.offset + seqLen
    try parser.expectTag(0x02)
    let modulus = try parser.readIntegerContent()
    try parser.expectTag(0x02)
    let exponent = try parser.readIntegerContent()
    guard parser.offset == seqEnd else {
        throw NSError(domain: "OIDCTestJWTFixture", code: 2)
    }
    return (modulus, exponent)
}

private struct ASN1Reader {
    let data: Data
    var offset = 0

    init(data: Data) {
        self.data = data
    }

    mutating func expectTag(_ tag: UInt8) throws {
        guard offset < data.count, data[offset] == tag else {
            throw NSError(domain: "ASN1Reader", code: 1)
        }
        offset += 1
    }

    mutating func readLength() throws -> Int {
        guard offset < data.count else { throw NSError(domain: "ASN1Reader", code: 2) }
        let first = data[offset]
        offset += 1
        if first & 0x80 == 0 { return Int(first) }
        let count = Int(first & 0x7f)
        guard count > 0, offset + count <= data.count else {
            throw NSError(domain: "ASN1Reader", code: 3)
        }
        var length = 0
        for _ in 0..<count {
            length = (length << 8) | Int(data[offset])
            offset += 1
        }
        return length
    }

    mutating func readIntegerContent() throws -> Data {
        let length = try readLength()
        guard offset + length <= data.count else {
            throw NSError(domain: "ASN1Reader", code: 4)
        }
        var bytes = Data(data[offset..<(offset + length)])
        offset += length
        if bytes.first == 0x00 { bytes.removeFirst() }
        return bytes
    }
}

#endif /* canImport(CryptoKit) && canImport(Security) */
