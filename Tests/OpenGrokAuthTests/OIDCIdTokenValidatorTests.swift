// Depends on OIDCTestJWTFixture, which needs Apple CryptoKit + Security.
// Compiled out on Linux; see PORT_STATUS.md for the coverage gap this leaves.
#if canImport(CryptoKit) && canImport(Security)

// OIDCIdTokenValidatorTests.swift
//
// JWKS signature validation for OIDC id_tokens — ports the upstream
// `validate_and_extract_user_info` test matrix (protocol.rs:639-715, :948+).

import Foundation
import OpenGrokHTTP
import Testing
@testable import OpenGrokAuth

private final class JWKSMockTransport: HTTPTransport, @unchecked Sendable {
    var jwksBody: String
    var omitJWKS = false

    init(jwksBody: String) {
        self.jwksBody = jwksBody
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if request.url.path.hasSuffix("/jwks") {
            if omitJWKS {
                return HTTPResponse(
                    metadata: HTTPResponseMetadata(statusCode: 404),
                    body: Data()
                )
            }
            return HTTPResponse(
                metadata: HTTPResponseMetadata(statusCode: 200),
                body: Data(jwksBody.utf8)
            )
        }
        return HTTPResponse(
            metadata: HTTPResponseMetadata(statusCode: 404),
            body: Data()
        )
    }

    func stream(_ request: HTTPRequest) -> AsyncThrowingStream<HTTPStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let response = try await send(request)
                    continuation.yield(.metadata(response.metadata))
                    continuation.yield(.body(response.body))
                    continuation.yield(.end)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

private func makeDiscovery(
    jwksURI: String? = "\(OIDCTestJWTFixture.issuer)/jwks",
    supportedAlgs: [String]? = ["RS256"]
) -> OIDCDiscovery {
    OIDCDiscovery(
        issuer: OIDCTestJWTFixture.issuer,
        authorizationEndpoint: "\(OIDCTestJWTFixture.issuer)/authorize",
        tokenEndpoint: "\(OIDCTestJWTFixture.issuer)/token",
        jwksURI: jwksURI,
        idTokenSigningAlgValuesSupported: supportedAlgs
    )
}

@Suite("OIDC id_token JWKS validation")
struct OIDCIdTokenValidatorTests {
    @Test func validRS256TokenPasses() async throws {
        let rsa = try OIDCTestJWTFixture.rsa()
        let nonce = UUID().uuidString.lowercased()
        let token = try OIDCTestJWTFixture.signRS256(
            payload: OIDCTestJWTFixture.personalClaims(nonce: nonce),
            privateKey: rsa.privateKey
        )
        let transport = JWKSMockTransport(
            jwksBody: OIDCTestJWTFixture.rsaJWKSJSON(n: rsa.jwkN, e: rsa.jwkE)
        )

        let claims = try await validateOIDCIdToken(
            token: token,
            discovery: makeDiscovery(),
            expectedIssuer: OIDCTestJWTFixture.issuer,
            expectedClientID: OIDCTestJWTFixture.clientID,
            expectedNonce: nonce,
            transport: transport
        )
        #expect(claims.sub == "user-42")
        #expect(claims.email == "browser@x.ai")
    }

    @Test func validES256TokenPasses() async throws {
        let es = try OIDCTestJWTFixture.es256()
        let nonce = UUID().uuidString.lowercased()
        let token = try OIDCTestJWTFixture.signES256(
            payload: OIDCTestJWTFixture.personalClaims(nonce: nonce),
            privateKey: es.privateKey
        )
        let transport = JWKSMockTransport(
            jwksBody: OIDCTestJWTFixture.es256JWKSJSON(x: es.jwkX, y: es.jwkY)
        )

        let claims = try await validateOIDCIdToken(
            token: token,
            discovery: makeDiscovery(supportedAlgs: ["ES256"]),
            expectedIssuer: OIDCTestJWTFixture.issuer,
            expectedClientID: OIDCTestJWTFixture.clientID,
            expectedNonce: nonce,
            transport: transport
        )
        #expect(claims.sub == "user-42")
    }

    @Test func wrongSignatureFails() async throws {
        let rsa = try OIDCTestJWTFixture.rsa()
        let other = try OIDCTestJWTFixture.generateRSA()
        let nonce = UUID().uuidString.lowercased()
        let token = try OIDCTestJWTFixture.signRS256(
            payload: OIDCTestJWTFixture.personalClaims(nonce: nonce),
            privateKey: other.privateKey,
            kid: OIDCTestJWTFixture.kid
        )
        let transport = JWKSMockTransport(
            jwksBody: OIDCTestJWTFixture.rsaJWKSJSON(n: rsa.jwkN, e: rsa.jwkE)
        )

        await #expect(throws: XAILoginFlowError.self) {
            _ = try await validateOIDCIdToken(
                token: token,
                discovery: makeDiscovery(),
                expectedIssuer: OIDCTestJWTFixture.issuer,
                expectedClientID: OIDCTestJWTFixture.clientID,
                expectedNonce: nonce,
                transport: transport
            )
        }
    }

    @Test func wrongKidFails() async throws {
        let rsa = try OIDCTestJWTFixture.rsa()
        let nonce = UUID().uuidString.lowercased()
        let token = try OIDCTestJWTFixture.signRS256(
            payload: OIDCTestJWTFixture.personalClaims(nonce: nonce),
            privateKey: rsa.privateKey,
            kid: "unknown-kid"
        )
        let transport = JWKSMockTransport(
            jwksBody: OIDCTestJWTFixture.rsaJWKSJSON(n: rsa.jwkN, e: rsa.jwkE)
        )

        await #expect(throws: XAILoginFlowError.self) {
            _ = try await validateOIDCIdToken(
                token: token,
                discovery: makeDiscovery(),
                expectedIssuer: OIDCTestJWTFixture.issuer,
                expectedClientID: OIDCTestJWTFixture.clientID,
                expectedNonce: nonce,
                transport: transport
            )
        }
    }

    @Test func hs256Rejected() async throws {
        let header = AuthCrypto.base64URLEncode(
            Data(#"{"alg":"HS256","typ":"JWT","kid":"test-kid"}"#.utf8))
        let payload = AuthCrypto.base64URLEncode(
            Data(#"{"sub":"user","iss":"http://127.0.0.1:9","aud":"client-under-test","nonce":"n","exp":9999999999}"#.utf8))
        let token = "\(header).\(payload).fake-signature"
        let transport = JWKSMockTransport(jwksBody: "{\"keys\":[]}")

        await #expect(throws: XAILoginFlowError.self) {
            _ = try await validateOIDCIdToken(
                token: token,
                discovery: makeDiscovery(),
                expectedIssuer: OIDCTestJWTFixture.issuer,
                expectedClientID: OIDCTestJWTFixture.clientID,
                expectedNonce: "n",
                transport: transport
            )
        }
    }

    @Test func nonceMismatchFails() async throws {
        let rsa = try OIDCTestJWTFixture.rsa()
        let token = try OIDCTestJWTFixture.signRS256(
            payload: OIDCTestJWTFixture.personalClaims(nonce: "expected-nonce"),
            privateKey: rsa.privateKey
        )
        let transport = JWKSMockTransport(
            jwksBody: OIDCTestJWTFixture.rsaJWKSJSON(n: rsa.jwkN, e: rsa.jwkE)
        )

        await #expect(throws: XAILoginFlowError.nonceMismatch) {
            _ = try await validateOIDCIdToken(
                token: token,
                discovery: makeDiscovery(),
                expectedIssuer: OIDCTestJWTFixture.issuer,
                expectedClientID: OIDCTestJWTFixture.clientID,
                expectedNonce: "wrong-nonce",
                transport: transport
            )
        }
    }

    @Test func expiredTokenFails() async throws {
        let rsa = try OIDCTestJWTFixture.rsa()
        let nonce = UUID().uuidString.lowercased()
        let token = try OIDCTestJWTFixture.signRS256(
            payload: OIDCTestJWTFixture.personalClaims(
                nonce: nonce,
                expiresIn: -3600
            ),
            privateKey: rsa.privateKey
        )
        let transport = JWKSMockTransport(
            jwksBody: OIDCTestJWTFixture.rsaJWKSJSON(n: rsa.jwkN, e: rsa.jwkE)
        )

        await #expect(throws: XAILoginFlowError.self) {
            _ = try await validateOIDCIdToken(
                token: token,
                discovery: makeDiscovery(),
                expectedIssuer: OIDCTestJWTFixture.issuer,
                expectedClientID: OIDCTestJWTFixture.clientID,
                expectedNonce: nonce,
                transport: transport
            )
        }
    }

    @Test func missingJwksURIFails() async throws {
        let rsa = try OIDCTestJWTFixture.rsa()
        let nonce = UUID().uuidString.lowercased()
        let token = try OIDCTestJWTFixture.signRS256(
            payload: OIDCTestJWTFixture.personalClaims(nonce: nonce),
            privateKey: rsa.privateKey
        )
        let transport = JWKSMockTransport(jwksBody: "{\"keys\":[]}")

        await #expect(throws: XAILoginFlowError.self) {
            _ = try await validateOIDCIdToken(
                token: token,
                discovery: makeDiscovery(jwksURI: nil),
                expectedIssuer: OIDCTestJWTFixture.issuer,
                expectedClientID: OIDCTestJWTFixture.clientID,
                expectedNonce: nonce,
                transport: transport
            )
        }
    }

    @Test func jwksFetchFailureFails() async throws {
        let rsa = try OIDCTestJWTFixture.rsa()
        let nonce = UUID().uuidString.lowercased()
        let token = try OIDCTestJWTFixture.signRS256(
            payload: OIDCTestJWTFixture.personalClaims(nonce: nonce),
            privateKey: rsa.privateKey
        )
        let transport = JWKSMockTransport(jwksBody: "")
        transport.omitJWKS = true

        await #expect(throws: XAILoginFlowError.self) {
            _ = try await validateOIDCIdToken(
                token: token,
                discovery: makeDiscovery(),
                expectedIssuer: OIDCTestJWTFixture.issuer,
                expectedClientID: OIDCTestJWTFixture.clientID,
                expectedNonce: nonce,
                transport: transport
            )
        }
    }

    @Test func audienceArrayMatchPasses() async throws {
        let rsa = try OIDCTestJWTFixture.rsa()
        let nonce = UUID().uuidString.lowercased()
        var payload = OIDCTestJWTFixture.personalClaims(nonce: nonce)
        payload["aud"] = ["other-client", OIDCTestJWTFixture.clientID]
        let token = try OIDCTestJWTFixture.signRS256(
            payload: payload,
            privateKey: rsa.privateKey
        )
        let transport = JWKSMockTransport(
            jwksBody: OIDCTestJWTFixture.rsaJWKSJSON(n: rsa.jwkN, e: rsa.jwkE)
        )

        let claims = try await validateOIDCIdToken(
            token: token,
            discovery: makeDiscovery(),
            expectedIssuer: OIDCTestJWTFixture.issuer,
            expectedClientID: OIDCTestJWTFixture.clientID,
            expectedNonce: nonce,
            transport: transport
        )
        #expect(claims.sub == "user-42")
    }
}

#endif /* canImport(CryptoKit) && canImport(Security) */
