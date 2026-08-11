// VideoGeneration.swift
//
// `image_to_video` tool — generate a video from a source image via the xAI
// Video Generation API.
// Port of `crates/codegen/xai-grok-tools/src/implementations/grok_build/video_gen/mod.rs`
// (650c1db7).

import Foundation
import OpenGrokHTTP
import OpenGrokShared

// MARK: - Constants

public let XAI_VIDEO_QUALITY_MODEL = "grok-imagine-video-1.5-preview"
public let VIDEO_START_TIMEOUT_SECONDS: TimeInterval = 60
public let VIDEO_GEN_TIMEOUT_SECONDS: TimeInterval = 300
public let VIDEO_POLL_INTERVAL_SECONDS: TimeInterval = 5
public let VIDEO_POLL_REQUEST_TIMEOUT_SECONDS: TimeInterval = 30
public let VIDEO_DOWNLOAD_TIMEOUT_SECONDS: TimeInterval = 120
public let DEFAULT_VIDEO_RESOLUTION = "480p"
public let DEFAULT_IMAGINE_VIDEO_DURATION_SECS: UInt32 = 6
public let VALID_VIDEO_RESOLUTIONS = ["480p", "720p"]
public let IMAGINE_VIDEO_DURATIONS_SECS: [UInt32] = [6, 10]

/// Prose returned to the model when a free / X Basic user calls a video tool.
public let VIDEO_TIER_RESTRICTED_UPSELL = "Video generation is a SuperGrok feature and isn't available on the free or X Basic tier. Let the user know they can unlock image and video generation by upgrading to SuperGrok: https://grok.com/supergrok?referrer=grok-build. Do not retry this tool."

// MARK: - Config

public enum VideoGenConfig: Sendable {
    case disabled
    case enabled(VideoGenSettings)

    public var isEnabled: Bool {
        if case .enabled = self { return true }
        return false
    }
}

public struct VideoGenSettings: Sendable {
    public var apiKey: String
    public var baseURL: String
    public var extraHeaders: [(name: String, value: String)]
    public var bearerProvider: (any ImageBearerProvider)?
    /// `true` when the user is on a tier the Imagine server zero-limits
    /// (free / X Basic).
    public var tierRestricted: Bool

    public init(
        apiKey: String,
        baseURL: String,
        extraHeaders: [(name: String, value: String)] = [],
        bearerProvider: (any ImageBearerProvider)? = nil,
        tierRestricted: Bool = false
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.extraHeaders = extraHeaders
        self.bearerProvider = bearerProvider
        self.tierRestricted = tierRestricted
    }
}

// MARK: - Errors

public enum VideoGenError: Error, Sendable, Equatable, CustomStringConvertible {
    case disabledConfig
    case invalidArguments(String)
    case httpFailure(status: Int, body: String)
    case timedOut(requestID: String)
    case noRequestID
    case noDownloadURL
    case serverFailed(requestID: String, preview: String)
    case requestExpired(requestID: String)
    case unparseableBody(operation: String, preview: String)

    public var description: String {
        switch self {
        case .disabledConfig:
            return "Cannot create VideoGenClient from disabled config"
        case .invalidArguments(let detail):
            return detail
        case .httpFailure(let status, let body):
            return "Video generation failed with HTTP \(status): \(body)"
        case .timedOut(let requestID):
            return "Video generation did not complete within \(Int(VIDEO_GEN_TIMEOUT_SECONDS))s (request_id=\(requestID))"
        case .noRequestID:
            return "No request_id received from the video generation API."
        case .noDownloadURL:
            return "Video generation completed but no download URL was returned."
        case .serverFailed(let requestID, let preview):
            return "Video generation failed on the server (request_id=\(requestID)): \(preview)"
        case .requestExpired(let requestID):
            return "Video generation request expired (request_id=\(requestID))."
        case .unparseableBody(let operation, let preview):
            return "Failed to parse video \(operation) response — body preview: \(preview)"
        }
    }
}

// MARK: - Client

/// HTTP client for the xAI Video Generation API.
public struct VideoGenClient: Sendable {
    public let baseURL: String
    public let defaultHeaders: [String: String]
    public let tierRestricted: Bool

    private let bearerProvider: (any ImageBearerProvider)?
    private let transport: any HTTPTransport

    public init(
        config: VideoGenConfig,
        legacyBearerProvider: (any ImageBearerProvider)? = nil,
        transport: any HTTPTransport = URLSessionHTTPTransport()
    ) throws {
        guard case .enabled(let settings) = config else {
            throw VideoGenError.disabledConfig
        }

        var headers = ["Content-Type": "application/json"]
        if !settings.apiKey.isEmpty {
            headers["Authorization"] = "Bearer \(settings.apiKey)"
        }
        for header in settings.extraHeaders {
            guard !header.name.isEmpty else {
                throw VideoGenError.invalidArguments("Invalid header name '\(header.name)'")
            }
            headers[header.name] = header.value
        }
        self.defaultHeaders = headers
        self.baseURL = settings.baseURL
        self.bearerProvider = settings.bearerProvider ?? legacyBearerProvider
        self.tierRestricted = settings.tierRestricted
        self.transport = transport
    }

    public var isTierRestricted: Bool { tierRestricted }

    public func currentBearer() async -> String? {
        await bearerProvider?.currentBearer()
    }

    /// Start generation and poll until the video bytes are available.
    public func generateWithImages(
        model: String = XAI_VIDEO_QUALITY_MODEL,
        prompt: String,
        duration: UInt32,
        resolution: String,
        image: String
    ) async throws -> Data {
        let requestID = try await startGeneration(
            model: model,
            prompt: prompt,
            duration: duration,
            resolution: resolution,
            image: image
        )
        let downloadURL = try await pollUntilDone(requestID: requestID)
        return try await downloadVideo(url: downloadURL)
    }

    private func startGeneration(
        model: String,
        prompt: String,
        duration: UInt32,
        resolution: String,
        image: String
    ) async throws -> String {
        let trimmedBase = trimTrailingSlash(baseURL)
        guard let url = URL(string: "\(trimmedBase)/videos/generations") else {
            throw VideoGenError.invalidArguments("Invalid video base URL: \(baseURL)")
        }

        let payload: [String: JSONValue] = [
            "model": .string(model),
            "prompt": .string(prompt),
            "duration": .number(.int64(Int64(duration))),
            "resolution": .string(resolution),
            "image": .object(["url": .string(image)]),
        ]

        let sentBearer = await currentBearer()
        var headers = defaultHeaders
        if let sentBearer {
            headers["Authorization"] = "Bearer \(sentBearer)"
        }
        let body = try JSONEncoder().encode(JSONValue.object(payload))
        let request = HTTPRequest(
            method: .post,
            url: url,
            headers: headers,
            body: body,
            timeout: VIDEO_START_TIMEOUT_SECONDS,
            idempotency: .nonIdempotent
        )
        let response = try await transport.send(request)
        let status = response.metadata.statusCode
        guard (200..<300).contains(status) else {
            let bodyText = String(decoding: response.body, as: UTF8.self)
            throw VideoGenError.httpFailure(status: status, body: String(bodyText.prefix(200)))
        }

        guard let root = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let requestID = root["request_id"] as? String,
              !requestID.isEmpty
        else {
            let preview = String(String(decoding: response.body, as: UTF8.self).prefix(500))
            throw VideoGenError.unparseableBody(operation: "start", preview: preview)
        }
        return requestID
    }

    private func pollUntilDone(requestID: String) async throws -> String {
        let trimmedBase = trimTrailingSlash(baseURL)
        guard let pollURL = URL(string: "\(trimmedBase)/videos/\(requestID)") else {
            throw VideoGenError.invalidArguments("Invalid poll URL for request_id=\(requestID)")
        }

        let deadline = Date().addingTimeInterval(VIDEO_GEN_TIMEOUT_SECONDS)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(VIDEO_POLL_INTERVAL_SECONDS * 1_000_000_000))

            let sentBearer = await currentBearer()
            var headers = defaultHeaders
            if let sentBearer {
                headers["Authorization"] = "Bearer \(sentBearer)"
            }
            let request = HTTPRequest(
                method: .get,
                url: pollURL,
                headers: headers,
                body: nil,
                timeout: VIDEO_POLL_REQUEST_TIMEOUT_SECONDS,
                idempotency: .idempotent
            )
            let response = try await transport.send(request)
            let status = response.metadata.statusCode
            if status != 202, !(200..<300).contains(status) {
                let bodyText = String(decoding: response.body, as: UTF8.self)
                throw VideoGenError.httpFailure(status: status, body: String(bodyText.prefix(200)))
            }

            guard let root = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
            else {
                let preview = String(String(decoding: response.body, as: UTF8.self).prefix(500))
                throw VideoGenError.unparseableBody(operation: "poll", preview: preview)
            }
            let pollStatus = (root["status"] as? String ?? "").lowercased()
            switch pollStatus {
            case "done":
                if let video = root["video"] as? [String: Any],
                   let downloadURL = video["url"] as? String,
                   !downloadURL.isEmpty {
                    return downloadURL
                }
                throw VideoGenError.noDownloadURL
            case "failed":
                let preview = String(String(decoding: response.body, as: UTF8.self).prefix(300))
                throw VideoGenError.serverFailed(requestID: requestID, preview: preview)
            case "expired":
                throw VideoGenError.requestExpired(requestID: requestID)
            default:
                continue
            }
        }
        throw VideoGenError.timedOut(requestID: requestID)
    }

    private func downloadVideo(url: String) async throws -> Data {
        guard let downloadURL = URL(string: url) else {
            throw VideoGenError.invalidArguments("Video download URL is invalid: \(url)")
        }
        let request = HTTPRequest(
            method: .get,
            url: downloadURL,
            headers: [:],
            body: nil,
            timeout: VIDEO_DOWNLOAD_TIMEOUT_SECONDS,
            idempotency: .idempotent
        )
        let response = try await transport.send(request)
        let status = response.metadata.statusCode
        guard (200..<300).contains(status) else {
            throw VideoGenError.httpFailure(status: status, body: "video download failed")
        }
        guard !response.body.isEmpty else {
            throw VideoGenError.invalidArguments("Video download was empty")
        }
        return response.body
    }
}

// MARK: - Tool input

/// `image_to_video` arguments. Mirrors the Rust `ImageToVideoInput` schema.
public struct ImageToVideoInput: Codable, Sendable, Equatable, Hashable {
    public var prompt: String?
    public var image: String
    public var duration: UInt32?
    public var resolutionName: String

    public init(
        prompt: String? = nil,
        image: String,
        duration: UInt32? = nil,
        resolutionName: String = DEFAULT_VIDEO_RESOLUTION
    ) {
        self.prompt = prompt
        self.image = image
        self.duration = duration
        self.resolutionName = resolutionName
    }

    public enum CodingKeys: String, CodingKey {
        case prompt
        case image
        case duration
        case resolutionName = "resolution_name"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
        self.image = try container.decode(String.self, forKey: .image)
        self.duration = try Self.decodeDuration(from: container)
        self.resolutionName = try container.decodeIfPresent(String.self, forKey: .resolutionName)
            ?? DEFAULT_VIDEO_RESOLUTION
    }

    private static func decodeDuration(from container: KeyedDecodingContainer<CodingKeys>) throws -> UInt32? {
        if let intValue = try container.decodeIfPresent(UInt32.self, forKey: .duration) {
            return intValue
        }
        if let stringValue = try container.decodeIfPresent(String.self, forKey: .duration)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !stringValue.isEmpty {
            guard let parsed = UInt32(stringValue) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .duration,
                    in: container,
                    debugDescription: "duration must be 6 or 10"
                )
            }
            return parsed
        }
        return nil
    }
}

public let IMAGE_TO_VIDEO_TOOL_NAME = "image_to_video"
public let IMAGE_TO_VIDEO_DESCRIPTION = "Generate a video from a single source image; returns the saved video's absolute path. When telling the user where it was saved, refer to it by its short session-relative path (e.g. `videos/1.mp4`) rather than the absolute path, so it renders as a clickable link that opens the video. Provide `image` for the image to animate and optionally a `prompt` to guide the animation. Use this tool when the user provides an image and wants it animated, turned into a video, or used as the first frame. Example: image_to_video(image=\"/Users/me/photo.jpg\", prompt=\"gentle camera push-in with wind moving the hair\", duration=6, resolution_name=\"480p\")"

// MARK: - Validation

public func validateImagineVideoDuration(_ duration: UInt32?) throws {
    guard let duration else { return }
    guard IMAGINE_VIDEO_DURATIONS_SECS.contains(duration) else {
        throw VideoGenError.invalidArguments(
            "`duration` must be either 6 or 10 seconds. Got \(duration)."
        )
    }
}

public func validateVideoResolution(_ resolution: String) throws {
    guard VALID_VIDEO_RESOLUTIONS.contains(resolution) else {
        throw VideoGenError.invalidArguments(
            "`resolution_name` must be one of: \(VALID_VIDEO_RESOLUTIONS.joined(separator: ", ")). Got \(resolution)."
        )
    }
}

/// Resolve an image reference to a wire-ready URL or data URL.
public func resolveVideoImageReference(_ value: String) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw VideoGenError.invalidArguments("image reference must not be empty")
    }

    if trimmed.hasPrefix("data:image/") {
        guard let comma = trimmed.firstIndex(of: ",") else {
            throw VideoGenError.invalidArguments("malformed data URL in image reference")
        }
        let header = String(trimmed[..<comma]).lowercased()
        guard header.contains(";base64") else {
            throw VideoGenError.invalidArguments("image references only support base64 data URLs")
        }
        return trimmed
    }

    if trimmed.hasPrefix("https://") {
        return trimmed
    }

    let path: String
    if let fileURL = URL(string: trimmed), fileURL.isFileURL {
        path = fileURL.path
    } else {
        path = trimmed
    }

    let rawBytes: Data
    do {
        rawBytes = try Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
    } catch {
        throw VideoGenError.invalidArguments("image reference not readable: \(path) (\(error))")
    }
    guard !rawBytes.isEmpty else {
        throw VideoGenError.invalidArguments("image reference contained no data")
    }
    guard let mime = validateImageHeader(rawBytes) else {
        throw VideoGenError.invalidArguments("invalid image reference: unsupported or corrupt image data")
    }
    let encoded = rawBytes.base64EncodedString()
    return "data:\(mime);base64,\(encoded)"
}

// MARK: - Helpers

private func trimTrailingSlash(_ value: String) -> String {
    var out = Substring(value)
    while out.hasSuffix("/") { out = out.dropLast() }
    return String(out)
}
