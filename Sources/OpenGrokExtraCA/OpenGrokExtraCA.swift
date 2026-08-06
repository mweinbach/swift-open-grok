// OpenGrokExtraCA.swift
//
// Opt-in enterprise trust roots for the production HTTP transport. The
// environment variable contains a PEM bundle path; roots are parsed once per
// process, capped before reading, and never replace the platform trust store.

import Foundation
import OpenGrokTracing

#if canImport(Security)
import Security
#endif

public let openGrokExtraCABundleEnvironment = "OPENGROK_EXTRA_CA_BUNDLE"
public let openGrokExtraCAMaxBundleBytes = 1024 * 1024

/// Structured warning sink used by the extra-CA loader.
public struct ExtraCALogger: Sendable {
    public let warning: @Sendable (_ message: String, _ metadata: [String: String]) -> Void

    public init(
        warning: @escaping @Sendable (_ message: String, _ metadata: [String: String]) -> Void
    ) {
        self.warning = warning
    }

    /// Emits a redacted tracing span when a sink is installed and a concise
    /// stderr warning otherwise, so optional CA failures remain observable.
    public static let standard = ExtraCALogger { message, metadata in
        let attributes = metadata.reduce(into: [String: TraceAttributeValue]()) { result, pair in
            result[pair.key] = .string(pair.value)
        }
        let tracer = Tracer()
        var span = tracer.startSpan(
            "open_grok.extra_ca.warning",
            attributes: attributes
        )
        tracer.endSpan(&span, status: .error(message: message))

        var line = "warning: \(message)"
        if !metadata.isEmpty {
            let fields = metadata
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            line += " (\(fields))"
        }
        line += "\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}

public enum ExtraCAFileError: Error, Sendable, Equatable {
    case unreadable(String)
    case tooLarge
}

/// Result of parsing a PEM bundle. Invalid blocks are dropped individually so
/// one bad certificate cannot hide otherwise usable roots.
public struct ExtraCAPEMParseResult: Sendable, Equatable {
    public let certificates: [Data]
    public let rejectedBlockCount: Int
    public let foundCertificateBlock: Bool

    public init(
        certificates: [Data],
        rejectedBlockCount: Int,
        foundCertificateBlock: Bool
    ) {
        self.certificates = certificates
        self.rejectedBlockCount = rejectedBlockCount
        self.foundCertificateBlock = foundCertificateBlock
    }
}

/// Injectable loader used by production and deterministic unit tests.
public struct OpenGrokExtraCALoader: Sendable {
    public typealias Environment = @Sendable () -> String?
    public typealias FileReader = @Sendable (URL) throws -> Data

    private let environment: Environment
    private let readFile: FileReader
    private let logger: ExtraCALogger

    public init(
        environment: @escaping Environment = {
            ProcessInfo.processInfo.environment[openGrokExtraCABundleEnvironment]
        },
        readFile: @escaping FileReader = { url in
            try Self.readCappedFile(at: url)
        },
        logger: ExtraCALogger = .standard
    ) {
        self.environment = environment
        self.readFile = readFile
        self.logger = logger
    }

    /// Load accepted DER roots. Unset/empty, unreadable, oversized, malformed,
    /// and zero-usable bundles all return an empty array without throwing.
    public func load() -> [Data] {
        guard let path = environment(), !path.isEmpty else { return [] }

        let url = URL(fileURLWithPath: path)
        let bundle: Data
        do {
            bundle = try readFile(url)
        } catch ExtraCAFileError.tooLarge {
            logger.warning(
                "OPENGROK_EXTRA_CA_BUNDLE exceeds the size cap; continuing without extra roots",
                ["limit_bytes": String(openGrokExtraCAMaxBundleBytes)]
            )
            return []
        } catch {
            logger.warning(
                "OPENGROK_EXTRA_CA_BUNDLE is unreadable; continuing without extra roots",
                ["path": TraceRedaction.redactString(path)]
            )
            return []
        }

        if bundle.count > openGrokExtraCAMaxBundleBytes {
            logger.warning(
                "OPENGROK_EXTRA_CA_BUNDLE exceeds the size cap; continuing without extra roots",
                ["limit_bytes": String(openGrokExtraCAMaxBundleBytes)]
            )
            return []
        }

        let parsed = OpenGrokExtraCA.parsePEM(bundle)
        guard parsed.foundCertificateBlock else {
            logger.warning(
                "OPENGROK_EXTRA_CA_BUNDLE contains no PEM certificate blocks; continuing without extra roots",
                [:]
            )
            return []
        }
        if parsed.rejectedBlockCount > 0 {
            logger.warning(
                "OPENGROK_EXTRA_CA_BUNDLE dropped unusable certificate blocks",
                [
                    "accepted": String(parsed.certificates.count),
                    "rejected": String(parsed.rejectedBlockCount),
                ]
            )
        }
        if parsed.certificates.isEmpty {
            logger.warning(
                "OPENGROK_EXTRA_CA_BUNDLE produced zero usable certificates; continuing without extra roots",
                [:]
            )
        }
        return parsed.certificates
    }

    /// Read at most one byte beyond the configured cap, avoiding unbounded
    /// startup reads while still distinguishing an exact-limit bundle.
    public static func readCappedFile(
        at url: URL,
        limit: Int = openGrokExtraCAMaxBundleBytes
    ) throws -> Data {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ExtraCAFileError.unreadable(String(describing: error))
        }
        defer { try? handle.close() }

        var result = Data()
        while result.count <= limit {
            let remaining = limit + 1 - result.count
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: min(64 * 1024, remaining)) ?? Data()
            } catch {
                throw ExtraCAFileError.unreadable(String(describing: error))
            }
            if chunk.isEmpty { break }
            result.append(chunk)
        }
        if result.count > limit { throw ExtraCAFileError.tooLarge }
        return result
    }
}

public enum OpenGrokExtraCA {
    public static let environmentVariable = openGrokExtraCABundleEnvironment
    public static let maxBundleBytes = openGrokExtraCAMaxBundleBytes

    /// Process-wide validated DER roots. Accessing this property performs at
    /// most one environment lookup and one bounded file read.
    public static let processRootCertificates: [Data] = OpenGrokExtraCALoader().load()

    public static func parsePEM(_ data: Data) -> ExtraCAPEMParseResult {
        let text = String(decoding: data, as: UTF8.self)
        let begin = "-----BEGIN CERTIFICATE-----"
        let end = "-----END CERTIFICATE-----"
        var cursor = text.startIndex
        var certificates: [Data] = []
        var rejected = 0
        var found = false

        while let beginRange = text.range(of: begin, range: cursor..<text.endIndex) {
            found = true
            guard let endRange = text.range(of: end, range: beginRange.upperBound..<text.endIndex) else {
                rejected += 1
                break
            }

            let body = text[beginRange.upperBound..<endRange.lowerBound]
            let encoded = body.filter { !$0.isWhitespace }
            if let der = decodeBase64(String(encoded)), isCertificateDER(der) {
                certificates.append(der)
            } else {
                rejected += 1
            }
            cursor = endRange.upperBound
        }

        return ExtraCAPEMParseResult(
            certificates: certificates,
            rejectedBlockCount: rejected,
            foundCertificateBlock: found
        )
    }

    private static func decodeBase64(_ encoded: String) -> Data? {
        guard !encoded.isEmpty else { return nil }
        guard encoded.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=" }) else {
            return nil
        }
        if let firstPadding = encoded.firstIndex(of: "=") {
            guard encoded[firstPadding...].allSatisfy({ $0 == "=" }),
                  encoded.distance(from: firstPadding, to: encoded.endIndex) <= 2
            else { return nil }
        }
        var padded = encoded
        while padded.count % 4 != 0 { padded.append("=") }
        return Data(base64Encoded: padded)
    }

    private static func isCertificateDER(_ data: Data) -> Bool {
        #if canImport(Security)
        return importSecurityCertificateCheck(data)
        #else
        return hasCertificateSequenceShape(data)
        #endif
    }

    #if canImport(Security)
    private static func importSecurityCertificateCheck(_ data: Data) -> Bool {
        guard let certificate = SecCertificateCreateWithData(nil, data as CFData) else { return false }
        _ = certificate
        return true
    }
    #endif

    /// FoundationNetworking has no portable X.509 parser. This structural
    /// check rejects malformed/non-certificate DER on Linux; Darwin additionally
    /// delegates validation to Security before trust-anchor installation.
    private static func hasCertificateSequenceShape(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        var cursor = 0
        guard let outer = readDERElement(bytes, cursor: &cursor), outer.tag == 0x30,
              outer.end == bytes.count else { return false }
        var inner = outer.contentStart
        guard let tbs = readDERElement(bytes, cursor: &inner), tbs.tag == 0x30,
              let algorithm = readDERElement(bytes, cursor: &inner), algorithm.tag == 0x30,
              let signature = readDERElement(bytes, cursor: &inner), signature.tag == 0x03,
              inner == outer.end else { return false }
        return tbs.end > tbs.contentStart && algorithm.end > algorithm.contentStart
            && signature.end > signature.contentStart
    }

    private struct DERElement {
        let tag: UInt8
        let contentStart: Int
        let end: Int
    }

    private static func readDERElement(_ bytes: [UInt8], cursor: inout Int) -> DERElement? {
        guard cursor < bytes.count else { return nil }
        let tag = bytes[cursor]
        cursor += 1
        guard cursor < bytes.count else { return nil }
        let lengthByte = bytes[cursor]
        cursor += 1
        let length: Int
        if lengthByte & 0x80 == 0 {
            length = Int(lengthByte)
        } else {
            let octets = Int(lengthByte & 0x7f)
            guard octets > 0, octets <= 4, cursor + octets <= bytes.count else { return nil }
            var value = 0
            for _ in 0..<octets {
                value = (value << 8) | Int(bytes[cursor])
                cursor += 1
            }
            length = value
        }
        let contentStart = cursor
        let end = contentStart + length
        guard end >= contentStart, end <= bytes.count else { return nil }
        cursor = end
        return DERElement(tag: tag, contentStart: contentStart, end: end)
    }
}
