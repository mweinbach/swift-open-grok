import Foundation
import OpenGrokHTTP

/// Rust: `xai-file-utils/src/s3.rs:34-37,226-322,336-340` at `00e176c8`.
/// Each request rechecks the durable session boundary before signing; abort
/// deliberately stays dark when that same boundary has since closed.
enum LiveS3MultipartUpload {
    struct Limits: Sendable, Equatable {
        let partSize: Int
        let maximumPartCount: Int

        init(
            partSize: Int = LiveCloudTraceUpload.maximumArchiveBytes,
            maximumPartCount: Int = 10_000
        ) {
            self.partSize = partSize
            self.maximumPartCount = maximumPartCount
        }
    }

    typealias AuthorizationProvider = @Sendable () async throws -> LiveCloudTraceUpload.Authorization

    private struct CompletedPart: Sendable {
        let number: Int
        let eTag: String
    }

    private static let maximumXMLResponseBytes = 64 * 1024
    private static let maximumETagBytes = 512
    private static let abortTimeout: TimeInterval = 10

    static func upload(
        sessionID: String,
        archive: Data,
        authorization: LiveCloudTraceUpload.Authorization,
        transport: any HTTPTransport,
        limits: Limits = Limits(),
        authorizeRequest: @escaping AuthorizationProvider
    ) async throws -> String {
        let expectedParts = try validatedPartCount(archiveBytes: archive.count, limits: limits)
        let objectPath = "\(sessionID)/trace_export.tar.gz"
        let endpointParts = authorization.endpoint.path.split(separator: "/")
        guard endpointParts.count >= 2,
              String(endpointParts[endpointParts.count - 2]) == sessionID,
              endpointParts.last == "trace_export.tar.gz"
        else {
            throw LiveCloudTraceUpload.Failure.authorizationChanged
        }

        let initiated = try await send(
            method: .post,
            query: [("uploads", "")],
            body: Data(),
            contentType: "application/gzip",
            authorization: authorization,
            transport: transport,
            authorizeRequest: authorizeRequest
        )
        let uploadID = try parseUploadID(
            from: initiated.body,
            expectedBucket: authorization.bucket,
            expectedObjectPath: objectPath
        )

        do {
            var completed: [CompletedPart] = []
            completed.reserveCapacity(expectedParts)

            for partNumber in 1...expectedParts {
                let lowerBound = (partNumber - 1) * limits.partSize
                let upperBound = min(lowerBound + limits.partSize, archive.count)
                let chunk = archive.subdata(in: lowerBound..<upperBound)
                let uploaded = try await send(
                    method: .put,
                    query: [
                        ("partNumber", String(partNumber)),
                        ("uploadId", uploadID),
                    ],
                    body: chunk,
                    contentType: "application/gzip",
                    authorization: authorization,
                    transport: transport,
                    authorizeRequest: authorizeRequest
                )
                guard uploaded.body.isEmpty else {
                    throw LiveCloudTraceUpload.Failure.invalidMultipartResponse
                }
                let eTag = try validatedETag(from: uploaded.metadata.headers)
                completed.append(CompletedPart(number: partNumber, eTag: eTag))
            }

            let completion = try await send(
                method: .post,
                query: [("uploadId", uploadID)],
                body: completionXML(parts: completed),
                contentType: "application/xml",
                authorization: authorization,
                transport: transport,
                authorizeRequest: authorizeRequest
            )
            try validateCompletion(
                completion.body,
                expectedBucket: authorization.bucket,
                expectedObjectPath: objectPath
            )
            return LiveCloudTraceUpload.resultURL(
                authorization: authorization,
                sessionID: sessionID
            )
        } catch {
            await abort(
                uploadID: uploadID,
                authorization: authorization,
                transport: transport,
                authorizeRequest: authorizeRequest
            )
            throw error
        }
    }

    static func validatedPartCount(archiveBytes: Int, limits: Limits = Limits()) throws -> Int {
        guard limits.partSize > 0,
              limits.partSize <= LiveCloudTraceUpload.maximumArchiveBytes,
              (1...10_000).contains(limits.maximumPartCount),
              archiveBytes >= limits.partSize
        else {
            throw LiveCloudTraceUpload.Failure.archiveTooLarge
        }
        let (maximumArchive, overflow) = limits.partSize.multipliedReportingOverflow(
            by: limits.maximumPartCount
        )
        guard !overflow, archiveBytes <= maximumArchive else {
            throw LiveCloudTraceUpload.Failure.archiveTooLarge
        }
        return archiveBytes / limits.partSize + (archiveBytes % limits.partSize == 0 ? 0 : 1)
    }

    private static func send(
        method: HTTPMethod,
        query: [(name: String, value: String)],
        body: Data,
        contentType: String,
        authorization: LiveCloudTraceUpload.Authorization,
        transport: any HTTPTransport,
        timeout: TimeInterval? = nil,
        authorizeRequest: @escaping AuthorizationProvider
    ) async throws -> HTTPResponse {
        try Task.checkCancellation()
        let current = try await authorizeRequest()
        guard current == authorization else {
            throw LiveCloudTraceUpload.Failure.authorizationChanged
        }
        let request = try LiveCloudTraceUpload.signedRequest(
            authorization: current,
            method: method,
            query: query,
            body: body,
            contentType: contentType,
            timeout: timeout
        )

        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as HTTPError {
            if case .cancelled = error { throw CancellationError() }
            throw LiveCloudTraceUpload.Failure.multipartTransport
        } catch {
            throw LiveCloudTraceUpload.Failure.multipartTransport
        }

        guard response.metadata.url == nil || response.metadata.url == request.url else {
            throw LiveCloudTraceUpload.Failure.invalidEndpoint
        }
        guard (200..<300).contains(response.metadata.statusCode) else {
            throw LiveCloudTraceUpload.Failure.multipartRejected(response.metadata.statusCode)
        }
        guard response.body.count <= maximumXMLResponseBytes else {
            throw LiveCloudTraceUpload.Failure.invalidMultipartResponse
        }
        return response
    }

    private static func abort(
        uploadID: String,
        authorization: LiveCloudTraceUpload.Authorization,
        transport: any HTTPTransport,
        authorizeRequest: @escaping AuthorizationProvider
    ) async {
        do {
            let response = try await send(
                method: .delete,
                query: [("uploadId", uploadID)],
                body: Data(),
                contentType: "application/gzip",
                authorization: authorization,
                transport: transport,
                timeout: abortTimeout,
                authorizeRequest: authorizeRequest
            )
            guard response.body.isEmpty else { return }
        } catch {
            return
        }
    }

    private static func parseUploadID(
        from data: Data,
        expectedBucket: String,
        expectedObjectPath: String
    ) throws -> String {
        let document = try safeXML(data)
        guard document.contains("<InitiateMultipartUploadResult"),
              document.contains("</InitiateMultipartUploadResult>")
        else {
            throw LiveCloudTraceUpload.Failure.invalidMultipartResponse
        }
        try validateLocation(document, bucket: expectedBucket, objectPath: expectedObjectPath)
        guard let uploadID = try element("UploadId", in: document),
              LiveCloudTraceUpload.validMultipartUploadID(uploadID)
        else {
            throw LiveCloudTraceUpload.Failure.invalidMultipartUploadID
        }
        return uploadID
    }

    private static func validateCompletion(
        _ data: Data,
        expectedBucket: String,
        expectedObjectPath: String
    ) throws {
        let document = try safeXML(data)
        guard document.contains("<CompleteMultipartUploadResult"),
              document.contains("</CompleteMultipartUploadResult>"),
              !document.contains("<Error>")
        else {
            throw LiveCloudTraceUpload.Failure.invalidMultipartResponse
        }
        try validateLocation(document, bucket: expectedBucket, objectPath: expectedObjectPath)
    }

    private static func safeXML(_ data: Data) throws -> String {
        guard !data.isEmpty,
              data.count <= maximumXMLResponseBytes,
              let document = String(data: data, encoding: .utf8),
              !document.contains("<!"),
              !document.utf8.contains(where: { $0 < 0x20 && $0 != 0x09 && $0 != 0x0A && $0 != 0x0D })
        else {
            throw LiveCloudTraceUpload.Failure.invalidMultipartResponse
        }
        return document
    }

    private static func validateLocation(
        _ document: String,
        bucket: String,
        objectPath: String
    ) throws {
        if let returnedBucket = try element("Bucket", in: document), returnedBucket != bucket {
            throw LiveCloudTraceUpload.Failure.invalidMultipartResponse
        }
        if let returnedPath = try element("Key", in: document), returnedPath != objectPath {
            throw LiveCloudTraceUpload.Failure.invalidMultipartResponse
        }
    }

    private static func element(_ name: String, in document: String) throws -> String? {
        let opening = "<\(name)>"
        let closing = "</\(name)>"
        guard let start = document.range(of: opening) else { return nil }
        guard let end = document.range(of: closing, range: start.upperBound..<document.endIndex),
              document.range(of: opening, range: end.upperBound..<document.endIndex) == nil
        else {
            throw LiveCloudTraceUpload.Failure.invalidMultipartResponse
        }
        let value = String(document[start.upperBound..<end.lowerBound])
        guard !value.contains("<"), !value.contains(">"), !value.contains("&") else {
            throw LiveCloudTraceUpload.Failure.invalidMultipartResponse
        }
        return value
    }

    private static func validatedETag(from headers: [String: String]) throws -> String {
        let matching = headers.filter { $0.key.caseInsensitiveCompare("ETag") == .orderedSame }
        guard matching.count == 1, let eTag = matching.first?.value else {
            throw LiveCloudTraceUpload.Failure.invalidMultipartETag
        }
        let bytes = Array(eTag.utf8)
        guard (3...maximumETagBytes).contains(bytes.count),
              bytes.first == UInt8(ascii: "\""),
              bytes.last == UInt8(ascii: "\""),
              bytes.dropFirst().dropLast().allSatisfy({
                  (0x21...0x7E).contains($0) && $0 != UInt8(ascii: "\"") && $0 != UInt8(ascii: "\\")
              })
        else {
            throw LiveCloudTraceUpload.Failure.invalidMultipartETag
        }
        return eTag
    }

    private static func completionXML(parts: [CompletedPart]) -> Data {
        var document = "<CompleteMultipartUpload>"
        for part in parts {
            document += "<Part><PartNumber>\(part.number)</PartNumber>"
            document += "<ETag>\(escapeXML(part.eTag))</ETag></Part>"
        }
        document += "</CompleteMultipartUpload>"
        return Data(document.utf8)
    }

    private static func escapeXML(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.utf8.count)
        for character in value {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&apos;"
            default: escaped.append(character)
            }
        }
        return escaped
    }
}
