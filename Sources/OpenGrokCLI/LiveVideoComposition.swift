// LiveVideoComposition.swift
//
// Session wiring for the `image_to_video` and `reference_to_video` tools.
//
// Port of `MvpAgent::prepare_video_gen_config`
// (`xai-grok-shell/src/agent/mvp_agent/agent_ops.rs:2272-2314`) and the
// video tool handlers (`video_gen/mod.rs` at pin 650c1db7).
//
// Video generation is xAI-only (unlike image tools, there is no OpenAI route).
// A session without xAI-provenanced credentials advertises nothing, and a
// failed `VideoGenClient` construction keeps the tools off the live list.
// Both tools share one gate — Rust registers the pair whenever
// `VideoGenConfig::is_enabled()` (`builder.rs:781-788`).

import Foundation
import OpenGrokConfig
import OpenGrokHTTP
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRegistry
import OpenGrokToolRuntime
import OpenGrokVersion
import OpenGrokWebMediaTools

// MARK: - Availability

struct LiveVideoToolAvailability: Sendable {
    var config: VideoGenConfig
    /// Advertise `image_to_video` and `reference_to_video` together.
    var imageToVideoEnabled: Bool
    var referenceToVideoEnabled: Bool

    static let unavailable = LiveVideoToolAvailability(
        config: .disabled,
        imageToVideoEnabled: false,
        referenceToVideoEnabled: false
    )

    var advertisesAnything: Bool { imageToVideoEnabled || referenceToVideoEnabled }
}

struct LiveVideoToolContext: Sendable {
    var availability: LiveVideoToolAvailability
    var transport: any HTTPTransport
}

// MARK: - Resolution

enum LiveVideoToolComposition {
    /// Resolve the session's video configuration.
    static func resolveAvailability(
        workingDirectory: URL,
        openGrokHome: URL,
        environment: [String: String],
        samplingProvider: ModelProvider,
        samplingAPIKey: String,
        samplingBaseURL: String,
        tierRestricted: Bool = false
    ) -> LiveVideoToolAvailability {
        let videoGenEnabled = resolveBoolFlag(
            envKey: "GROK_VIDEO_GEN",
            configKey: "video_gen",
            workingDirectory: workingDirectory,
            openGrokHome: openGrokHome,
            environment: environment
        )
        guard videoGenEnabled else { return .unavailable }

        guard let apiKey = LiveImageToolComposition.xaiMediaAPIKey(
            samplingProvider: samplingProvider,
            samplingAPIKey: samplingAPIKey,
            environment: environment
        ) else {
            return .unavailable
        }

        let baseURL = OpenGrokLiveApplicationLauncher.configuredXaiAPIBaseURL(
            workingDirectory: workingDirectory,
            openGrokHome: openGrokHome,
            environment: environment
        ) ?? samplingBaseURL

        let headers: [(name: String, value: String)] = [
            ("user-agent", "xai-grok-build/\(OpenGrokVersion.compiledVersion)"),
        ]
        let resolvedTierRestricted = boolFromEnv(environment["GROK_VIDEO_GEN_TIER_RESTRICTED"]) ?? tierRestricted
        return LiveVideoToolAvailability(
            config: .enabled(VideoGenSettings(
                apiKey: apiKey,
                baseURL: baseURL,
                extraHeaders: headers,
                bearerProvider: LiveXaiImageBearerProvider(bearer: apiKey),
                tierRestricted: resolvedTierRestricted
            )),
            imageToVideoEnabled: true,
            referenceToVideoEnabled: true
        )
    }

    /// Bind both video tools when the session has a constructible client.
    ///
    /// Call from `LiveComposition.makeToolExecutor` immediately after the image
    /// tool block — same gate spirit as `ImageGenClient`:
    ///
    /// ```swift
    /// if let videoToolContext {
    ///     LiveVideoToolComposition.registerVideoTools(
    ///         context: videoToolContext,
    ///         builder: &builder,
    ///         toolConfig: &toolConfig
    ///     )
    /// }
    /// ```
    ///
    /// `registerImageToVideo` remains as a compatibility alias that registers
    /// the same pair — existing `LiveComposition` call sites keep compiling
    /// and advertise both tools under one gate.
    static func registerVideoTools(
        context: LiveVideoToolContext,
        builder: inout ToolRegistryBuilder,
        toolConfig: inout ToolServerConfig
    ) {
        let availability = context.availability
        guard availability.advertisesAnything,
              let client = try? VideoGenClient(
                  config: availability.config,
                  transport: context.transport
              )
        else { return }

        if availability.imageToVideoEnabled {
            builder.setHandler(
                qualifiedId: BuiltinToolCatalog.imageToVideoQualifiedId,
                handler: LiveImageToVideoToolHandler(client: client)
            )
            toolConfig.tools.append(ToolConfig.fromId(
                BuiltinToolCatalog.imageToVideoQualifiedId,
                kind: BuiltinToolCatalog.videoToolKinds[BuiltinToolCatalog.imageToVideoQualifiedId]
            ))
        }
        if availability.referenceToVideoEnabled {
            builder.setHandler(
                qualifiedId: BuiltinToolCatalog.referenceToVideoQualifiedId,
                handler: LiveReferenceToVideoToolHandler(client: client)
            )
            toolConfig.tools.append(ToolConfig.fromId(
                BuiltinToolCatalog.referenceToVideoQualifiedId,
                kind: BuiltinToolCatalog.videoToolKinds[BuiltinToolCatalog.referenceToVideoQualifiedId]
            ))
        }
    }

    /// Compatibility alias — registers both video tools under the shared gate.
    static func registerImageToVideo(
        context: LiveVideoToolContext,
        builder: inout ToolRegistryBuilder,
        toolConfig: inout ToolServerConfig
    ) {
        registerVideoTools(context: context, builder: &builder, toolConfig: &toolConfig)
    }

    // MARK: Flag plumbing

    private static func resolveBoolFlag(
        envKey: String,
        configKey: String,
        workingDirectory: URL,
        openGrokHome: URL,
        environment: [String: String]
    ) -> Bool {
        if let fromEnv = boolFromEnv(environment[envKey]) { return fromEnv }
        if let raw = configBool(
            path: ["features", configKey],
            workingDirectory: workingDirectory,
            openGrokHome: openGrokHome,
            environment: environment
        ) {
            return raw
        }
        return true
    }

    private static func boolFromEnv(_ raw: String?) -> Bool? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty
        else { return nil }
        switch raw {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return nil
        }
    }

    private static func configTables(
        workingDirectory: URL,
        openGrokHome: URL,
        environment: [String: String]
    ) -> [TOMLValue] {
        var tables = [loadMergedProjectConfig(cwd: workingDirectory, environment: environment)]
        if let user = try? loadConfigFile(
            at: openGrokHome.appendingPathComponent("config.toml")
        ) {
            tables.append(user)
        }
        return tables
    }

    private static func configBool(
        path: [String],
        workingDirectory: URL,
        openGrokHome: URL,
        environment: [String: String]
    ) -> Bool? {
        for table in configTables(
            workingDirectory: workingDirectory,
            openGrokHome: openGrokHome,
            environment: environment
        ) {
            if case .boolean(let value)? = table[path: path] { return value }
        }
        return nil
    }
}

// MARK: - Handlers

struct LiveImageToVideoToolHandler: ToolHandler {
    let client: VideoGenClient
    let writer: LiveImageSessionWriter

    init(
        client: VideoGenClient,
        writer: LiveImageSessionWriter = LiveImageSessionWriter(directoryName: "videos")
    ) {
        self.client = client
        self.writer = writer
    }

    func invoke(
        clientName: String,
        args: JSONValue,
        ctx: ToolCallContext,
        resources: ToolResources
    ) async -> Result<TypedToolOutput, ToolError> {
        guard clientName == IMAGE_TO_VIDEO_TOOL_NAME,
              let toolId = try? ToolId(clientName)
        else {
            return .failure(.notImplemented(
                "video tool handler does not implement \(clientName)"
            ))
        }

        if client.isTierRestricted {
            return .success(textOutput(toolId: toolId, text: VIDEO_TIER_RESTRICTED_UPSELL))
        }

        guard let imageReference = stringField(args, "image") else {
            return .failure(.invalidArguments("image_to_video requires an image reference"))
        }

        let duration = uintField(args, "duration")
        let resolution = stringField(args, "resolution_name") ?? DEFAULT_VIDEO_RESOLUTION
        do {
            try validateImagineVideoDuration(duration)
            try validateVideoResolution(resolution)
        } catch let error as VideoGenError {
            return .failure(.invalidArguments(error.description))
        } catch {
            return .failure(.invalidArguments(String(describing: error)))
        }

        let resolvedImage: String
        do {
            resolvedImage = try resolveVideoImageReference(imageReference)
        } catch let error as VideoGenError {
            return .failure(.invalidArguments(error.description))
        } catch {
            return .failure(.invalidArguments(String(describing: error)))
        }

        let prompt = stringField(args, "prompt") ?? ""
        let effectiveDuration = duration ?? DEFAULT_IMAGINE_VIDEO_DURATION_SECS

        let bytes: Data
        do {
            bytes = try await client.generateWithImages(
                prompt: prompt,
                duration: effectiveDuration,
                resolution: resolution,
                image: resolvedImage
            )
        } catch let error as VideoGenError {
            return .failure(.custom(code: "video_gen_failed", detail: error.description))
        } catch {
            return .failure(.custom(
                code: "video_gen_failed",
                detail: String(describing: error)
            ))
        }

        let path: String
        do {
            path = try writer.save(
                sessionFolder: resources.sessionFolder,
                bytes: bytes,
                fileExtension: "mp4"
            )
        } catch {
            return .failure(.invalidArguments(
                "failed to save generated video: \(String(describing: error))"
            ))
        }

        let text = "Saved video to \(path) (\(bytes.count) bytes)"
        var output = textOutput(toolId: toolId, text: text)
        if case .object(var obj) = output.value {
            obj["path"] = .string(path)
            obj["byte_size"] = .number(.int64(Int64(bytes.count)))
            output.value = .object(obj)
        }
        return .success(output)
    }

    private func textOutput(toolId: ToolId, text: String) -> TypedToolOutput {
        TypedToolOutput(
            toolId: toolId,
            value: .object(["content": .string(text)]),
            modelOutput: [.text(text: text)]
        )
    }

    private func stringField(_ args: JSONValue, _ key: String) -> String? {
        guard case .object(let obj) = args, case .string(let value)? = obj[key] else {
            return nil
        }
        return value
    }

    private func uintField(_ args: JSONValue, _ key: String) -> UInt32? {
        guard case .object(let obj) = args else { return nil }
        switch obj[key] {
        case .number(.int64(let value)) where value >= 0:
            return UInt32(value)
        case .string(let raw):
            return UInt32(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }
}

/// `reference_to_video` handler. Validation order matches Rust
/// `ReferenceToVideoTool::run` (`video_gen/mod.rs:1136-1189`): prompt → image
/// count → duration → aspect_ratio → resolution → resolve → tier upsell → HTTP.
struct LiveReferenceToVideoToolHandler: ToolHandler {
    let client: VideoGenClient
    let writer: LiveImageSessionWriter

    init(
        client: VideoGenClient,
        writer: LiveImageSessionWriter = LiveImageSessionWriter(directoryName: "videos")
    ) {
        self.client = client
        self.writer = writer
    }

    func invoke(
        clientName: String,
        args: JSONValue,
        ctx: ToolCallContext,
        resources: ToolResources
    ) async -> Result<TypedToolOutput, ToolError> {
        guard clientName == REFERENCE_TO_VIDEO_TOOL_NAME,
              let toolId = try? ToolId(clientName)
        else {
            return .failure(.notImplemented(
                "video tool handler does not implement \(clientName)"
            ))
        }

        let prompt = stringField(args, "prompt") ?? ""
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .failure(.invalidArguments("`prompt` must not be empty."))
        }

        guard let images = stringArrayField(args, "images") else {
            return .failure(.invalidArguments(
                "`images` must contain at least two image references."
            ))
        }
        if images.count < 2 {
            return .failure(.invalidArguments(
                "`images` must contain at least two image references."
            ))
        }
        if images.count > MAX_R2V_REFERENCE_IMAGES {
            return .failure(.invalidArguments(
                "`images` must contain at most \(MAX_R2V_REFERENCE_IMAGES) image references."
            ))
        }

        let duration = uintField(args, "duration")
        let aspectRatio = stringField(args, "aspect_ratio") ?? ""
        let resolution = stringField(args, "resolution_name") ?? DEFAULT_VIDEO_RESOLUTION
        do {
            try validateImagineVideoDuration(duration)
            try validateImagineVideoAspectRatio(aspectRatio)
            try validateVideoResolution(resolution)
        } catch let error as VideoGenError {
            return .failure(.invalidArguments(error.description))
        } catch {
            return .failure(.invalidArguments(String(describing: error)))
        }

        var referenceImages: [String] = []
        referenceImages.reserveCapacity(images.count)
        for image in images {
            do {
                referenceImages.append(try resolveVideoImageReference(image))
            } catch let error as VideoGenError {
                return .failure(.invalidArguments(error.description))
            } catch {
                return .failure(.invalidArguments(String(describing: error)))
            }
        }

        // Free / X Basic users are zero-limited on Imagine server-side; return
        // the upsell prose instead of a doomed request (`mod.rs:1170-1173`).
        if client.isTierRestricted {
            return .success(textOutput(toolId: toolId, text: VIDEO_TIER_RESTRICTED_UPSELL))
        }

        let effectiveDuration = duration ?? DEFAULT_IMAGINE_VIDEO_DURATION_SECS
        let bytes: Data
        do {
            bytes = try await client.generateWithImages(
                model: XAI_VIDEO_BASE_MODEL,
                prompt: prompt,
                duration: effectiveDuration,
                aspectRatio: aspectRatio,
                resolution: resolution,
                image: nil,
                referenceImages: referenceImages
            )
        } catch let error as VideoGenError {
            return .failure(.custom(code: "video_gen_failed", detail: error.description))
        } catch {
            return .failure(.custom(
                code: "video_gen_failed",
                detail: String(describing: error)
            ))
        }

        let path: String
        do {
            path = try writer.save(
                sessionFolder: resources.sessionFolder,
                bytes: bytes,
                fileExtension: "mp4"
            )
        } catch {
            return .failure(.invalidArguments(
                "failed to save generated video: \(String(describing: error))"
            ))
        }

        let text = "Saved video to \(path) (\(bytes.count) bytes)"
        var output = textOutput(toolId: toolId, text: text)
        if case .object(var obj) = output.value {
            obj["path"] = .string(path)
            obj["byte_size"] = .number(.int64(Int64(bytes.count)))
            output.value = .object(obj)
        }
        return .success(output)
    }

    private func textOutput(toolId: ToolId, text: String) -> TypedToolOutput {
        TypedToolOutput(
            toolId: toolId,
            value: .object(["content": .string(text)]),
            modelOutput: [.text(text: text)]
        )
    }

    private func stringField(_ args: JSONValue, _ key: String) -> String? {
        guard case .object(let obj) = args, case .string(let value)? = obj[key] else {
            return nil
        }
        return value
    }

    private func stringArrayField(_ args: JSONValue, _ key: String) -> [String]? {
        guard case .object(let obj) = args, case .array(let values)? = obj[key] else {
            return nil
        }
        var out: [String] = []
        out.reserveCapacity(values.count)
        for value in values {
            guard case .string(let s) = value else { return nil }
            out.append(s)
        }
        return out
    }

    private func uintField(_ args: JSONValue, _ key: String) -> UInt32? {
        guard case .object(let obj) = args else { return nil }
        switch obj[key] {
        case .number(.int64(let value)) where value >= 0:
            return UInt32(value)
        case .string(let raw):
            return UInt32(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }
}
