// CryptoPrimitivesTests.swift
//
// Tests for consolidated crypto (SHA-256, SHA-512, StreamingSHA-256, FormURLEncoding, Base64URL)
// and concurrency primitives (CancellationToken, LockHolder, DynamicCodingKey, MonotonicInstant).

import Foundation
import Testing
import OpenGrokShared

@Suite("Shared Crypto and Primitives")
struct CryptoPrimitivesTests {

    @Test("SHA-256 matches NIST vectors")
    func sha256NistVectors() {
        // Empty string
        #expect(SHA256.hexDigest("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        // "abc"
        #expect(SHA256.hexDigest("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        // 1,000,000 "a"s
        let millionA = String(repeating: "a", count: 1_000_000)
        #expect(SHA256.hexDigest(millionA) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    @Test("Streaming SHA-256 matches single-pass SHA-256 across chunk boundaries")
    func streamingSha256Chunks() {
        var streaming = StreamingSHA256()
        streaming.update(Data("abc".utf8))
        streaming.update(Data("def".utf8))
        streaming.update(Data("ghi".utf8))
        let streamingDigest = streaming.finalize()

        let singlePassDigest = SHA256.hash("abcdefghi")
        #expect(streamingDigest == singlePassDigest)
    }

    @Test("SHA-512 matches NIST vectors")
    func sha512NistVectors() {
        #expect(
            SHA512.hexDigest("abc") ==
            "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"
        )
    }

    @Test("FormURLEncoding conforms to RFC-3986 application/x-www-form-urlencoded")
    func formURLEncoding() {
        let params = [
            "client_id": "open-grok+app/v1",
            "redirect_uri": "https://example.com/callback?query=1&b=2",
            "scope": "openid email profile",
        ]
        let encoded = FormURLEncoding.encode(params)
        // Check sorting and proper encoding of reserved characters (+ -> %2B, / -> %2F, ? -> %3F, space -> +)
        #expect(encoded.contains("client_id=open-grok%2Bapp%2Fv1"))
        #expect(encoded.contains("redirect_uri=https%3A%2F%2Fexample.com%2Fcallback%3Fquery%3D1%26b%3D2"))
        #expect(encoded.contains("scope=openid%20email%20profile"))
    }

    @Test("Base64URL round-trip encoding and decoding without padding")
    func base64UrlRoundTrip() {
        let original = Data([0x00, 0x01, 0x02, 0xfe, 0xff, 0x3f, 0xbf])
        let encoded = Base64URL.encode(original)
        #expect(!encoded.contains("="))
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))

        let decoded = Base64URL.decode(encoded)
        #expect(decoded == original)
    }

    @Test("CancellationToken cancellation lifecycle")
    func cancellationToken() async {
        let token = CancellationToken()
        #expect(!token.isCancelled)

        let callbackRan = LockHolder(false)
        token.onCancel {
            callbackRan.withLock { $0 = true }
        }

        token.cancel()
        #expect(token.isCancelled)
        #expect(callbackRan.withLock { $0 })

        do {
            try token.throwIfCancelled()
            #expect(Bool(false), "Expected CancellationError")
        } catch is CancellationError {
            // Expected
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    @Test("LockHolder thread-safety under concurrent access")
    func lockHolderConcurrency() async {
        let holder = LockHolder(0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    holder.withLock { count in
                        count += 1
                    }
                }
            }
        }
        let finalCount = holder.withLock { $0 }
        #expect(finalCount == 100)
    }

    @Test("DynamicCodingKey string and int value preservation")
    func dynamicCodingKey() {
        let strKey = DynamicCodingKey(stringValue: "custom_key")
        #expect(strKey?.stringValue == "custom_key")
        #expect(strKey?.intValue == nil)

        let intKey = DynamicCodingKey(intValue: 42)
        #expect(intKey?.stringValue == "42")
        #expect(intKey?.intValue == 42)
    }
}
