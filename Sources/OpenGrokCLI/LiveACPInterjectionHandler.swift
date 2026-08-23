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

        let sessionID = AcpSessionId(request.sessionId)
        guard await gateway.ownsSession(sessionID) else {
            throw AcpError.invalidParams().withData(
                .string("session not found: \(request.sessionId)")
            )
        }

        let textOverride = request.content.lazy.compactMap { block -> String? in
            guard case .text(let text) = block,
                  !text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return nil
            }
            return text.text
        }.first
        let text = stripPathsFromImagePlaceholders(textOverride ?? request.text)

        // The shared sanitizer deliberately processes only its bounded image
        // budget. Reject overflow instead of passing later local paths onward.
        guard stripPathsFromImagePlaceholders(text) == text else {
            throw AcpError.invalidParams().withData(
                .string("invalid params: too many image placeholders")
            )
        }

        if await interjections.interject(text) {
            return Self.queued
        }

        let admitted: Bool
        if let idleFallback {
            admitted = try await idleFallback(sessionID, text, request.interjectionId)
        } else {
            admitted = try await gateway.submitUserInterjection(
                sessionId: sessionID,
                text: text,
                interjectionID: request.interjectionId
            )
        }

        if !admitted {
            // A genuine user turn may have started between the actor's idle
            // observation and admission; it now owns the same live buffer.
            guard await interjections.interject(text) else {
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
