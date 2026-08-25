// LiveACPInterjectionHandler.swift
//
// The authenticated `x.ai/interject` extension feeds the same live buffer the
// provider turn drains, or starts a genuine user turn when the session is idle.

import Foundation
import OpenGrokACP
import OpenGrokACPRuntime
import OpenGrokShared

struct LiveACPInterjectionHandler: ACPAgentExtensionHandler, Sendable {
    static let method = "x.ai/interject"
    private static let maximumImageBytes = 1_500_000
    private static let maximumTotalImageBytes = 8_000_000
    private static let maximumTextBytes = 131_072
    private static let acceptedImageMIMETypes: Set<String> = [
        "image/png", "image/jpeg", "image/webp", "image/gif",
    ]

    typealias IdleFallback = @Sendable (AcpSessionId, String, String?) async throws -> Bool

    let gateway: ACPNotificationGateway
    let interjections: LiveSessionInterjections
    let idleFallback: IdleFallback?

    init(
        gateway: ACPNotificationGateway,
        interjections: LiveSessionInterjections,
        idleFallback: IdleFallback? = nil
    ) {
        self.gateway = gateway
        self.interjections = interjections
        self.idleFallback = idleFallback
    }

    func handle(method: String, params: JSONValue) async throws -> JSONValue {
        guard method == Self.method else {
            throw ACPExtensionMethodRouter.unknownExtensionMethodError(method)
        }

        let request: InterjectionRequest
        do {
            request = try params.decode(InterjectionRequest.self)
        } catch {
            throw AcpError.invalidParams().withData(.string("invalid params: \(error)"))
        }

        guard !request.sessionId.isEmpty,
              request.sessionId.utf8.count <= 128,
              request.interjectionId.map({ !$0.isEmpty && $0.utf8.count <= 128 }) ?? true,
              request.content.count <= maxPlaceholdersPerPrompt + 16
        else {
            throw AcpError.invalidParams().withData(
                .string("invalid params: interjection exceeds its size limit")
            )
        }
        let sessionID = AcpSessionId(request.sessionId)
        guard await gateway.ownsSession(sessionID) else {
            throw AcpError.invalidParams().withData(
                .string("session not found: \(request.sessionId)")
            )
        }
        guard await interjections.bindAuthenticatedSession(request.sessionId) else {
            throw AcpError.invalidParams().withData(
                .string("session not found: \(request.sessionId)")
            )
        }

        let images = try Self.validatedImages(request.content)
        let textOverride = request.content.lazy.compactMap { block -> String? in
            guard case .text(let text) = block,
                  !text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return nil
            }
            return text.text
        }.first
        let text = stripPathsFromImagePlaceholders(textOverride ?? request.text)
        guard text.utf8.count <= Self.maximumTextBytes else {
            throw AcpError.invalidParams().withData(
                .string("invalid params: interjection text exceeds its size limit")
            )
        }

        // The shared sanitizer deliberately processes only its bounded image
        // budget. Reject overflow instead of passing later local paths onward.
        guard stripPathsFromImagePlaceholders(text) == text else {
            throw AcpError.invalidParams().withData(
                .string("invalid params: too many image placeholders")
            )
        }

        if await interjections.interject(text, images: images) {
            return Self.queued
        }

        let pendingImages = LiveACPImageInterjectionContext.Pending(
            sessionID: request.sessionId,
            text: text,
            images: images
        )
        let admitted = try await LiveACPImageInterjectionContext.$pending.withValue(pendingImages) {
            if let idleFallback {
                return try await idleFallback(sessionID, text, request.interjectionId)
            }
            return try await gateway.submitUserInterjection(
                sessionId: sessionID,
                text: text,
                interjectionID: request.interjectionId
            )
        }

        if !admitted {
            // A genuine user turn may have started between the actor's idle
            // observation and admission; it now owns the same live buffer.
            guard await interjections.interject(text, images: images) else {
                throw AcpError.invalidRequest().withData(
                    .string("interjection could not be queued")
                )
            }
        }

        return Self.queued
    }

    private static var queued: JSONValue {
        .object(["result": .object(["status": .string("queued")])])
    }

    private static func validatedImages(
        _ blocks: [OpenGrokACP.ContentBlock]
    ) throws -> [OpenGrokACP.ImageContent] {
        var images: [OpenGrokACP.ImageContent] = []
        var totalBytes = 0
        for block in blocks {
            switch block {
            case .text:
                continue
            case .image(let image):
                let mimeType = image.mimeType.lowercased()
                guard images.count < maxPlaceholdersPerPrompt,
                      acceptedImageMIMETypes.contains(mimeType),
                      image.data.utf8.count <= ((maximumImageBytes + 2) / 3) * 4,
                      let bytes = Data(base64Encoded: image.data),
                      !bytes.isEmpty,
                      bytes.count <= maximumImageBytes,
                      totalBytes <= maximumTotalImageBytes - bytes.count
                else {
                    throw AcpError.invalidParams().withData(
                        .string("invalid params: unsupported or oversized interjection image")
                    )
                }
                totalBytes += bytes.count
                images.append(OpenGrokACP.ImageContent(
                    data: bytes.base64EncodedString(),
                    mimeType: mimeType
                ))
            default:
                throw AcpError.invalidParams().withData(
                    .string("invalid params: unsupported interjection content")
                )
            }
        }
        return images
    }

    private struct InterjectionRequest: Decodable {
        let sessionId: String
        let text: String
        let interjectionId: String?
        let content: [OpenGrokACP.ContentBlock]

        private enum CodingKeys: String, CodingKey {
            case sessionId
            case text
            case interjectionId
            case content
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sessionId = try container.decode(String.self, forKey: .sessionId)
            text = try container.decode(String.self, forKey: .text)
            interjectionId = try container.decodeIfPresent(String.self, forKey: .interjectionId)
            if container.contains(.content) {
                content = try container.decode([OpenGrokACP.ContentBlock].self, forKey: .content)
            } else {
                content = []
            }
        }
    }
}
