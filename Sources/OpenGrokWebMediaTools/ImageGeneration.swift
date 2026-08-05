// ImageGeneration.swift
//
// `image_gen` / `image_edit` tools — generate or edit images via the configured
// Grok Imagine or OpenAI Images service.
// Port of `crates/codegen/xai-grok-tools/src/implementations/grok_build/image_gen/mod.rs`
// and `crates/codegen/xai-grok-tools/src/types/image_generation_provider.rs`.
//
// Credential isolation is the load-bearing invariant here. The two routes do
// not share a credential path:
//
//   * Grok Imagine bakes the static xAI key as a fallback `Authorization`
//     header and may additionally be backed by the session-wide legacy bearer
//     provider.
//   * OpenAI Images is ChatGPT-OAuth-only, matching upstream codex-rs's
//     `image_generation_available` gate (`uses_codex_backend` excludes
//     `AuthMode::ApiKey`). No static bearer is ever baked into its headers, the
//     session-wide legacy provider is never consulted, and the
//     identity-anchored Codex resolver is mandatory: without it the request
//     fails closed rather than going out unauthenticated or with the wrong
//     identity.

import Foundation
import OpenGrokHTTP
import OpenGrokShared

// MARK: - Provider

/// User-selected image generation service.
///
/// This is a routing decision only. Each provider keeps its own endpoint,
/// credentials, headers, and retry path.
///
/// Canonically owned here rather than in `OpenGrokConfigTypes` for the same
/// reason upstream moved it out of `xai-grok-config-types`: the tool clients
/// match on it, and hosting it in the config layer is a dependency cycle.
/// `OpenGrokConfigTypes.ImageGenerationProvider` is the config-side mirror of
/// this wire contract; the canonical strings must stay identical.
public enum ImageGenerationProvider: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case grok
    case openAI = "openai"

    public static let `default`: ImageGenerationProvider = .grok

    public var canonical: String { rawValue }

    public static func fromCanonical(_ value: String) -> ImageGenerationProvider? {
        ImageGenerationProvider(
            rawValue: value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }
}

// MARK: - Constants

/// Default Imagine model for `image_gen`, unless `modelOverride` is supplied.
public let XAI_IMAGINE_MODEL = "grok-imagine-image-quality"
public let XAI_IMAGINE_EDIT_MODEL = "grok-imagine-image-edit"
/// Codex's image-generation extension model at the pinned upstream contract.
public let OPENAI_IMAGE_MODEL = "gpt-image-2"
public let CODEX_IMAGE_TURN_ID_HEADER = "x-codex-image-turn-id"
/// Some Imagine models expand the prompt then generate, and the proxy buffers
/// the whole image before sending any bytes, so the client may receive nothing
/// for well over a minute. Keep these generous.
public let IMAGE_GEN_TIMEOUT_SECONDS: TimeInterval = 300
/// OpenAI Images accepts at most this many reference images per edit.
public let OPENAI_IMAGE_EDIT_MAX_REFERENCES = 5

/// Prose returned to the model (as a normal, successful tool result) when a
/// free / X Basic user calls `image_gen` or `image_edit`.
public let TIER_RESTRICTED_UPSELL = "Image generation is a SuperGrok feature and isn't available on the free or X Basic tier. Let the user know they can unlock image and video generation by upgrading to SuperGrok: https://grok.com/supergrok?referrer=grok-build. Do not retry this tool."

// MARK: - Live bearer source

/// Provider-specific live bearer source, resolved per request.
///
/// OpenAI images require the identity-anchored Codex resolver; Grok Imagine
/// uses the xAI auth manager.
public protocol ImageBearerProvider: Sendable {
    func currentBearer() async -> String?
}

// MARK: - Config

/// `enabled` means credentials are present; each tool has its own gate.
public enum ImageGenConfig: Sendable {
    case disabled
    case enabled(ImageGenSettings)

    public var isEnabled: Bool {
        if case .enabled = self { return true }
        return false
    }
}

public struct ImageGenSettings: Sendable {
    public var provider: ImageGenerationProvider
    /// Static credential baked as the fallback `Authorization` header for the
    /// Grok route. Ignored for OpenAI, which is ChatGPT-OAuth-only and
    /// resolves every bearer live from `bearerProvider`.
    public var apiKey: String
    public var baseURL: String
    public var extraHeaders: [(name: String, value: String)]
    /// Provider-specific live bearer source. Mandatory for OpenAI (requests
    /// fail closed without it); optional for Grok, where it wins over the
    /// legacy session-wide provider.
    public var bearerProvider: (any ImageBearerProvider)?
    public var imageGenEnabled: Bool
    public var imageEditEnabled: Bool
    /// Imagine model override for `image_gen`. `image_edit` is unaffected.
    public var modelOverride: String?
    public var editModelOverride: String?
    /// `true` when the user is on a tier the Imagine server zero-limits
    /// (free / X Basic). Always false for the OpenAI route.
    public var tierRestricted: Bool

    public init(
        provider: ImageGenerationProvider,
        apiKey: String = "",
        baseURL: String,
        extraHeaders: [(name: String, value: String)] = [],
        bearerProvider: (any ImageBearerProvider)? = nil,
        imageGenEnabled: Bool = true,
        imageEditEnabled: Bool = true,
        modelOverride: String? = nil,
        editModelOverride: String? = nil,
        tierRestricted: Bool = false
    ) {
        self.provider = provider
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.extraHeaders = extraHeaders
        self.bearerProvider = bearerProvider
        self.imageGenEnabled = imageGenEnabled
        self.imageEditEnabled = imageEditEnabled
        self.modelOverride = modelOverride
        self.editModelOverride = editModelOverride
        self.tierRestricted = tierRestricted
    }
}

// MARK: - Errors

public enum ImageGenError: Error, Sendable, Equatable, CustomStringConvertible {
    case disabledConfig
    /// The OpenAI route had no live bearer. Fails closed: nothing is sent.
    case authRequired
    case invalidArguments(String)
    case httpFailure(status: Int, body: String)
    case noImageData(operation: String)
    case unparseableBody(operation: String, preview: String)

    public var description: String {
        switch self {
        case .disabledConfig:
            return "Cannot create ImageGenClient from disabled config"
        case .authRequired:
            return "OpenAI image authentication is unavailable; sign in again with `open-grok login --codex`."
        case .invalidArguments(let detail):
            return detail
        case .httpFailure(let status, let body):
            return "Image request failed with HTTP \(status): \(body)"
        case .noImageData(let operation):
            return "Image \(operation) returned no image data."
        case .unparseableBody(let operation, let preview):
            return "Failed to parse image \(operation) response — body preview: \(preview)"
        }
    }
}

// MARK: - Client

/// HTTP client for the configured image provider.
public struct ImageGenClient: Sendable {
    public let provider: ImageGenerationProvider
    public let baseURL: String
    public let model: String
    public let editModel: String
    public let fileExtension: String
    /// Headers baked at construction. For OpenAI this never contains an
    /// `Authorization` entry — see `ImageGenClient.init`.
    public let defaultHeaders: [String: String]
    public let tierRestricted: Bool
    /// When true, a request without a live bearer fails closed instead of
    /// going out unauthenticated. Always true for OpenAI.
    public let requireLiveBearer: Bool

    private let bearerProvider: (any ImageBearerProvider)?
    private let transport: any HTTPTransport

    /// Build a client from a config and the session-wide legacy bearer
    /// provider.
    ///
    /// `legacyBearerProvider` supplies the xAI bearer, so it may only ever back
    /// the Grok route. The OpenAI route accepts just its config-level Codex
    /// resolver and must fail closed without it.
    public init(
        config: ImageGenConfig,
        legacyBearerProvider: (any ImageBearerProvider)? = nil,
        transport: any HTTPTransport = URLSessionHTTPTransport()
    ) throws {
        guard case .enabled(let settings) = config else {
            throw ImageGenError.disabledConfig
        }

        switch settings.provider {
        case .grok:
            self.model = nonBlank(settings.modelOverride) ?? XAI_IMAGINE_MODEL
            self.editModel = nonBlank(settings.editModelOverride) ?? XAI_IMAGINE_EDIT_MODEL
            self.fileExtension = "jpg"
        case .openAI:
            // The pinned Codex contract fixes the model; overrides do not apply.
            self.model = OPENAI_IMAGE_MODEL
            self.editModel = OPENAI_IMAGE_MODEL
            self.fileExtension = "png"
        }

        var headers = ["Content-Type": "application/json"]
        // Grok Imagine bakes the static key as the fallback Authorization; the
        // live provider overrides it per request. OpenAI Images is
        // ChatGPT-OAuth-only: no static bearer is ever baked, the
        // identity-anchored live resolver is mandatory, and it fails closed on
        // logout or account drift.
        if settings.provider == .grok, !settings.apiKey.isEmpty {
            headers["Authorization"] = "Bearer \(settings.apiKey)"
        }
        for header in settings.extraHeaders {
            guard !header.name.isEmpty else {
                throw ImageGenError.invalidArguments("Invalid header name '\(header.name)'")
            }
            headers[header.name] = header.value
        }
        self.defaultHeaders = headers

        // The legacy session-wide provider carries the xAI bearer, so it may
        // only ever back the Grok route.
        switch settings.provider {
        case .grok:
            self.bearerProvider = settings.bearerProvider ?? legacyBearerProvider
        case .openAI:
            self.bearerProvider = settings.bearerProvider
        }

        self.provider = settings.provider
        self.baseURL = settings.baseURL
        self.requireLiveBearer = settings.provider == .openAI
        self.tierRestricted = settings.provider == .grok && settings.tierRestricted
        self.transport = transport
    }

    /// Whether the current user's tier is zero-limited on Imagine server-side.
    public var isTierRestricted: Bool { tierRestricted }

    public func currentBearer() async -> String? {
        await bearerProvider?.currentBearer()
    }

    // MARK: Requests

    public func generate(
        prompt: String,
        aspectRatio: String,
        turnID: String
    ) async throws -> Data {
        let payload: [String: JSONValue]
        switch provider {
        case .grok:
            payload = [
                "model": .string(model),
                "prompt": .string(prompt),
                "n": .number(.int64(1)),
                "aspect_ratio": .string(aspectRatio),
                "resolution": .string("1k"),
                "response_format": .string("b64_json"),
            ]
        case .openAI:
            payload = [
                "model": .string(model),
                "prompt": .string(prompt),
                "background": .string("auto"),
                "quality": .string("auto"),
                "size": .string(openAIImageSize(aspectRatio)),
            ]
        }
        return try await send(
            endpoint: "generations",
            operation: "generation",
            payload: payload,
            turnID: turnID
        )
    }

    public func edit(
        prompt: String,
        dataURLs: [String],
        aspectRatio: String,
        turnID: String
    ) async throws -> Data {
        if provider == .openAI, dataURLs.count > OPENAI_IMAGE_EDIT_MAX_REFERENCES {
            throw ImageGenError.invalidArguments(
                "OpenAI image editing accepts at most \(OPENAI_IMAGE_EDIT_MAX_REFERENCES) reference images."
            )
        }
        var payload: [String: JSONValue]
        switch provider {
        case .grok:
            payload = [
                "model": .string(editModel),
                "prompt": .string(prompt),
                "n": .number(.int64(1)),
                "resolution": .string("1k"),
                "response_format": .string("b64_json"),
            ]
            let images = dataURLs.map { JSONValue.object(["url": .string($0)]) }
            if images.count == 1 {
                payload["image"] = images[0]
            } else {
                payload["images"] = .array(images)
                payload["aspect_ratio"] = .string(aspectRatio)
            }
        case .openAI:
            payload = [
                "model": .string(editModel),
                "prompt": .string(prompt),
                "background": .string("auto"),
                "quality": .string("auto"),
                "size": .string(openAIImageSize(aspectRatio)),
                "images": .array(dataURLs.map { .object(["image_url": .string($0)]) }),
            ]
        }
        return try await send(
            endpoint: "edits",
            operation: "edit",
            payload: payload,
            turnID: turnID
        )
    }

    /// Build the request that `send` would issue, without issuing it.
    /// Exposed so the credential-isolation boundary is directly testable.
    public func buildRequest(
        endpoint: String,
        payload: [String: JSONValue],
        turnID: String,
        bearer: String?
    ) throws -> HTTPRequest {
        let trimmed = trimTrailingSlash(baseURL)
        guard let url = URL(string: "\(trimmed)/images/\(endpoint)") else {
            throw ImageGenError.invalidArguments("Invalid image base URL: \(baseURL)")
        }
        var headers = defaultHeaders
        if let bearer {
            headers["Authorization"] = "Bearer \(bearer)"
        }
        if provider == .openAI {
            headers[CODEX_IMAGE_TURN_ID_HEADER] = turnID
        }
        let body = try JSONEncoder().encode(JSONValue.object(payload))
        return HTTPRequest(
            method: .post,
            url: url,
            headers: headers,
            body: body,
            timeout: IMAGE_GEN_TIMEOUT_SECONDS,
            idempotency: .nonIdempotent
        )
    }

    private func send(
        endpoint: String,
        operation: String,
        payload: [String: JSONValue],
        turnID: String
    ) async throws -> Data {
        // Capture the bearer once so the request and any 401 attribution see
        // the same value even if the provider rotates mid-flight.
        let sentBearer = await currentBearer()
        if requireLiveBearer, sentBearer == nil {
            throw ImageGenError.authRequired
        }

        let request = try buildRequest(
            endpoint: endpoint,
            payload: payload,
            turnID: turnID,
            bearer: sentBearer
        )
        let response = try await transport.send(request)
        let status = response.metadata.statusCode
        guard (200..<300).contains(status) else {
            let body = String(decoding: response.body, as: UTF8.self)
            throw ImageGenError.httpFailure(status: status, body: String(body.prefix(200)))
        }

        let b64: String
        do {
            b64 = try decodeImageResponse(response.body)
        } catch {
            let preview = String(String(decoding: response.body, as: UTF8.self).prefix(500))
            throw ImageGenError.unparseableBody(operation: operation, preview: preview)
        }
        // A well-formed body with an empty `data` array is a distinct failure
        // from an unparseable one: the provider answered, just without an image.
        guard !b64.isEmpty else {
            throw ImageGenError.noImageData(operation: operation)
        }

        guard let decoded = Data(base64Encoded: b64) else {
            throw ImageGenError.invalidArguments("Failed to decode base64 image data")
        }
        return decoded
    }

    /// Extract the first `data[].b64_json` from an image response body.
    /// Returns an empty string when the array is present but carries no image.
    private func decodeImageResponse(_ body: Data) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw ImageGenError.invalidArguments("image response was not an object")
        }
        let data = root["data"] as? [[String: Any]] ?? []
        return (data.first?["b64_json"] as? String) ?? ""
    }
}

// MARK: - Tool input

/// `image_gen` arguments. Mirrors the Rust `ImageGenInput` schema.
public struct ImageGenInput: Codable, Sendable, Equatable, Hashable {
    public var prompt: String
    public var aspectRatio: String

    public init(prompt: String, aspectRatio: String = "auto") {
        self.prompt = prompt
        self.aspectRatio = aspectRatio
    }

    public enum CodingKeys: String, CodingKey {
        case prompt
        case aspectRatio = "aspect_ratio"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.prompt = try c.decode(String.self, forKey: .prompt)
        self.aspectRatio = try c.decodeIfPresent(String.self, forKey: .aspectRatio) ?? "auto"
    }
}

public let IMAGE_GEN_TOOL_NAME = "image_gen"
public let IMAGE_GEN_DESCRIPTION = "Generate a new image from a text description using the configured image provider; returns the saved image's absolute path. When telling the user where it was saved, refer to it by its short session-relative path (for example `images/1.png`) rather than the absolute path, so it renders as a clickable link that opens the image. To produce multiple images, emit multiple tool calls with distinct prompts."
public let IMAGE_GEN_PROMPT_DESCRIPTION = "Text description of the image to generate."
public let IMAGE_GEN_ASPECT_RATIO_DESCRIPTION = "Aspect ratio of the generated image, decide it based on the user's request. Defaults to 'auto'. 1:1 for square (icons, profiles), 16:9 for wide (landscapes, cinematic), 9:16 for tall (phone wallpapers, stories), 3:2 for horizontal photos, 2:3 for vertical (portraits, posters)."

// MARK: - Helpers

/// Map an aspect ratio to the size vocabulary OpenAI Images accepts.
public func openAIImageSize(_ aspectRatio: String) -> String {
    switch aspectRatio.trimmingCharacters(in: .whitespacesAndNewlines) {
    case "16:9", "3:2", "4:3", "2:1", "19.5:9", "20:9":
        return "1536x1024"
    case "9:16", "2:3", "3:4", "1:2", "9:19.5", "9:20":
        return "1024x1536"
    case "1:1":
        return "1024x1024"
    default:
        return "auto"
    }
}

private func nonBlank(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
    else { return nil }
    return value
}

private func trimTrailingSlash(_ value: String) -> String {
    var out = Substring(value)
    while out.hasSuffix("/") { out = out.dropLast() }
    return String(out)
}
