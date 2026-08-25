import Foundation
import COpenGrokSockets

#if canImport(Security)
import Security
#endif

enum LiveGoogleCloudServiceAccountSigner {
    enum Failure: Error, Sendable {
        case invalidPrivateKey
        case unsupportedPrivateKey
        case signingFailed
    }

    private static let maximumPrivateKeyBytes = 64 * 1024
    private static let maximumSignatureBytes = 1024
    private static let rsaEncryptionOID: [UInt8] = [
        0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01,
    ]

    static func sign(_ message: Data, privateKeyPEM: String) throws -> Data {
        guard !message.isEmpty, message.count <= maximumPrivateKeyBytes else {
            throw Failure.signingFailed
        }

        var privateKey = try privateKeyDER(from: privateKeyPEM)
        defer { privateKey.resetBytes(in: 0..<privateKey.count) }

        #if canImport(Security)
        return try appleSignature(message: message, pkcs8PrivateKey: privateKey)
        #elseif os(Linux) || os(Windows)
        return try nativeSignature(message: message, pkcs8PrivateKey: privateKey)
        #else
        throw Failure.unsupportedPrivateKey
        #endif
    }

    static func privateKeyDER(from pem: String) throws -> Data {
        guard !pem.isEmpty, pem.utf8.count <= maximumPrivateKeyBytes else {
            throw Failure.invalidPrivateKey
        }

        let lines = pem.split(whereSeparator: \.isNewline)
        guard lines.count >= 3,
              lines.first == "-----BEGIN PRIVATE KEY-----",
              lines.last == "-----END PRIVATE KEY-----"
        else {
            throw Failure.invalidPrivateKey
        }

        let encoded = lines.dropFirst().dropLast().joined()
        guard let decoded = Data(base64Encoded: encoded),
              !decoded.isEmpty,
              decoded.count <= maximumPrivateKeyBytes
        else {
            throw Failure.invalidPrivateKey
        }
        return decoded
    }

    #if canImport(Security)
    private static func appleSignature(message: Data, pkcs8PrivateKey: Data) throws -> Data {
        let privateKeyBytes = try rsaPKCS1PrivateKey(from: pkcs8PrivateKey)
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        var keyError: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(
            privateKeyBytes as CFData,
            attributes as CFDictionary,
            &keyError
        ) else {
            throw Failure.invalidPrivateKey
        }

        let blockSize = SecKeyGetBlockSize(key)
        guard (256...maximumSignatureBytes).contains(blockSize),
              SecKeyIsAlgorithmSupported(key, .sign, .rsaSignatureMessagePKCS1v15SHA256)
        else {
            throw Failure.unsupportedPrivateKey
        }

        var signatureError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            key,
            .rsaSignatureMessagePKCS1v15SHA256,
            message as CFData,
            &signatureError
        ) as Data?,
            signature.count == blockSize
        else {
            throw Failure.signingFailed
        }
        return signature
    }

    private static func rsaPKCS1PrivateKey(from pkcs8: Data) throws -> Data {
        var outer = DERReader(bytes: Array(pkcs8))
        let sequence = try outer.read(tag: 0x30)
        guard outer.isAtEnd else { throw Failure.invalidPrivateKey }

        var fields = DERReader(bytes: sequence)
        let version = try fields.read(tag: 0x02)
        guard version == [0x00] || version == [0x01] else {
            throw Failure.invalidPrivateKey
        }

        var algorithm = DERReader(bytes: try fields.read(tag: 0x30))
        guard try algorithm.read(tag: 0x06) == rsaEncryptionOID else {
            throw Failure.unsupportedPrivateKey
        }
        if !algorithm.isAtEnd {
            guard try algorithm.read(tag: 0x05).isEmpty, algorithm.isAtEnd else {
                throw Failure.invalidPrivateKey
            }
        }

        let privateKey = try fields.read(tag: 0x04)
        guard !privateKey.isEmpty, fields.isAtEnd else {
            throw Failure.invalidPrivateKey
        }
        return Data(privateKey)
    }

    private struct DERReader {
        let bytes: [UInt8]
        private(set) var offset = 0

        var isAtEnd: Bool { offset == bytes.count }

        mutating func read(tag: UInt8) throws -> [UInt8] {
            guard offset < bytes.count, bytes[offset] == tag else {
                throw Failure.invalidPrivateKey
            }
            offset += 1
            guard offset < bytes.count else { throw Failure.invalidPrivateKey }

            let first = bytes[offset]
            offset += 1
            let length: Int
            if first < 0x80 {
                length = Int(first)
            } else {
                let count = Int(first & 0x7F)
                guard (1...4).contains(count),
                      offset <= bytes.count - count,
                      bytes[offset] != 0
                else {
                    throw Failure.invalidPrivateKey
                }
                var decoded = 0
                for _ in 0..<count {
                    decoded = (decoded << 8) | Int(bytes[offset])
                    offset += 1
                }
                guard decoded >= 0x80 else { throw Failure.invalidPrivateKey }
                length = decoded
            }

            guard length <= bytes.count - offset else { throw Failure.invalidPrivateKey }
            let value = Array(bytes[offset..<(offset + length)])
            offset += length
            return value
        }
    }
    #endif

    #if os(Linux) || os(Windows)
    private static func nativeSignature(message: Data, pkcs8PrivateKey: Data) throws -> Data {
        var required = 0
        let queried = pkcs8PrivateKey.withUnsafeBytes { privateKey in
            message.withUnsafeBytes { payload in
                og_cloud_sign_rsa_sha256(
                    privateKey.baseAddress,
                    privateKey.count,
                    payload.baseAddress,
                    payload.count,
                    nil,
                    &required
                )
            }
        }
        guard queried == 0, (256...maximumSignatureBytes).contains(required) else {
            throw Failure.invalidPrivateKey
        }

        var signature = Data(count: required)
        let capacity = signature.count
        let signed = signature.withUnsafeMutableBytes { output in
            pkcs8PrivateKey.withUnsafeBytes { privateKey in
                message.withUnsafeBytes { payload in
                    og_cloud_sign_rsa_sha256(
                        privateKey.baseAddress,
                        privateKey.count,
                        payload.baseAddress,
                        payload.count,
                        output.bindMemory(to: UInt8.self).baseAddress,
                        &required
                    )
                }
            }
        }
        guard signed == 0, required == capacity else {
            signature.resetBytes(in: 0..<signature.count)
            throw Failure.signingFailed
        }
        return signature
    }
    #endif
}
