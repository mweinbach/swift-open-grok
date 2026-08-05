// LiveImageTools.swift
//
// Session wiring for the `image_gen` / `image_edit` tools.
//
// Port of `MvpAgent::prepare_image_gen_config` / `openai_image_gen_config`
// (`xai-grok-shell/src/agent/mvp_agent/agent_ops.rs:2226-2334`) plus the
// advertisement rule in `xai-grok-agent/src/builder.rs:771-780`.
//
// The load-bearing shape upstream fixes, and this file reproduces:
//
//   * The registry always *knows* both tools (`BuiltinToolCatalog.mediaTools`).
//     Whether a session *advertises* them is decided here, from resolved
//     credentials — `image_gen_enabled()` / `image_edit_enabled()` are false
//     for a disabled config, so the tool never reaches the model.
//   * Credential isolation is an availability rule, not just a transport rule.
//     The OpenAI route is ChatGPT-OAuth-only: without isolated Codex
//     credentials that support image generation, the config resolves to
//     `.disabled` and the session advertises nothing. A session that cannot
//     legally call the endpoint never offers the tool, and `ImageGenClient`
//     independently fails closed if one is somehow constructed anyway.
//   * The Grok route only ever receives an xAI-provenanced key. A Codex
//     sampling token must never become a static fallback bearer for Imagine.

import Foundation
import OpenGrokAuth
import OpenGrokConfig
import OpenGrokHTTP
import OpenGrokPaths
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRegistry
import OpenGrokToolRuntime
import OpenGrokVersion
import OpenGrokWebMediaTools

// MARK: - Availability

/// The resolved image-tool decision for one session.
struct LiveImageToolAvailability: Sendable {
    var config: ImageGenConfig
    /// Advertise `image_gen`. Upstream `ImageGenConfig::image_gen_enabled`.
    var imageGenEnabled: Bool
    /// Advertise `image_edit`. Upstream `ImageGenConfig::image_edit_enabled`.
    var imageEditEnabled: Bool

    static let unavailable = LiveImageToolAvailability(
        config: .disabled,
        imageGenEnabled: false,
        imageEditEnabled: false
    )

    var advertisesAnything: Bool { imageGenEnabled || imageEditEnabled }
}

/// Everything `LiveToolExecutor` needs to decide on, and then build, the image
/// tools: the resolved availability and the transport their requests go over.
struct LiveImageToolContext: Sendable {
    var availability: LiveImageToolAvailability
    var transport: any HTTPTransport
}

// MARK: - Bearer providers

/// Live xAI bearer for the Grok Imagine route.
///
/// Holds the session's already-resolved xAI bearer. It is only ever built when
/// the sampling provider's session auth is xAI, so a Codex token can never
/// reach an Imagine endpoint through it.
struct LiveXaiImageBearerProvider: ImageBearerProvider {
    let bearer: String
    func currentBearer() async -> String? { bearer.isEmpty ? nil : bearer }
}

/// Identity-anchored Codex bearer for the OpenAI Images route.
///
/// Re-reads the isolated `codex-auth.json` on every request, so a concurrent
/// `open-grok logout --codex` or an account switch is observed immediately and
/// yields `nil` — which makes `ImageGenClient` fail closed rather than send.
struct LiveCodexImageBearerProvider: ImageBearerProvider {
    let provider: CodexAuthCredentialProvider

    func currentBearer() async -> String? {
        provider.resolvedBearer()?.bearer
    }
}

// MARK: - Resolution

enum LiveImageToolComposition {
    /// Resolve the session's image configuration.
    ///
    /// `samplingProvider` / `samplingAPIKey` are the session's resolved
    /// sampling credentials; they back the Grok route only when the provider's
    /// session auth is xAI (upstream `xai_media_api_key`).
    static func resolveAvailability(
        workingDirectory: URL,
        openGrokHome: URL,
        environment: [String: String],
        samplingProvider: ModelProvider,
        samplingAPIKey: String,
        samplingBaseURL: String
    ) -> LiveImageToolAvailability {
        let imageGenEnabled = resolveBoolFlag(
            envKey: "GROK_IMAGE_GEN",
            configKey: "image_gen",
            workingDirectory: workingDirectory,
            openGrokHome: openGrokHome,
            environment: environment
        )
        // `image_edit` has no `[features]` key upstream — env or default only.
        let imageEditEnabled = boolFromEnv(environment["GROK_IMAGE_EDIT"]) ?? true

        let provider = resolveProvider(
            workingDirectory: workingDirectory,
            openGrokHome: openGrokHome,
            environment: environment
        )

        switch provider {
        case .openAI:
            return resolveOpenAIAvailability(
                environment: environment,
                imageGenEnabled: imageGenEnabled,
                imageEditEnabled: imageEditEnabled
            )
        case .grok:
            return resolveGrokAvailability(
                workingDirectory: workingDirectory,
                openGrokHome: openGrokHome,
                environment: environment,
                samplingProvider: samplingProvider,
                samplingAPIKey: samplingAPIKey,
                samplingBaseURL: samplingBaseURL,
                imageGenEnabled: imageGenEnabled,
                imageEditEnabled: imageEditEnabled
            )
        }
    }

    /// ChatGPT-OAuth-only. Mirrors `prepare_image_gen_config`'s OpenAI arm:
    /// only the isolated Codex store is consulted, a Free plan is refused, and
    /// `apiKey` is left empty so nothing static can be baked as a bearer.
    private static func resolveOpenAIAvailability(
        environment: [String: String],
        imageGenEnabled: Bool,
        imageEditEnabled: Bool
    ) -> LiveImageToolAvailability {
        let authFile = OpenGrokAuthPaths.codexAuthFileURL(environment: environment)
        guard let credentials = try? loadCodexCredentials(at: authFile) else {
            return .unavailable
        }
        guard supportsImageGeneration(credentials) else {
            // ChatGPT Free: upstream logs and disables rather than letting the
            // model call an endpoint that will refuse it.
            return .unavailable
        }

        var headers: [(name: String, value: String)] = [
            ("originator", codexOriginator),
        ]
        if let accountID = credentials.accountID {
            headers.append(("ChatGPT-Account-ID", accountID))
        }
        if credentials.accountIsFedramp {
            headers.append(("X-OpenAI-Fedramp", "true"))
        }

        let bearerProvider = LiveCodexImageBearerProvider(
            provider: CodexAuthCredentialProvider(
                authFile: authFile,
                expectedIdentity: credentials.identity
            )
        )
        return LiveImageToolAvailability(
            config: .enabled(ImageGenSettings(
                provider: .openAI,
                // Deliberately empty: the live identity-anchored resolver is
                // the sole bearer source for this route.
                apiKey: "",
                baseURL: codexInferenceBaseURL(environment: environment),
                extraHeaders: headers,
                bearerProvider: bearerProvider,
                imageGenEnabled: imageGenEnabled,
                imageEditEnabled: imageEditEnabled,
                // The pinned Codex contract fixes the model; overrides do not
                // apply, and the OpenAI route is never tier-restricted.
                modelOverride: nil,
                editModelOverride: nil,
                tierRestricted: false
            )),
            imageGenEnabled: imageGenEnabled,
            imageEditEnabled: imageEditEnabled
        )
    }

    private static func resolveGrokAvailability(
        workingDirectory: URL,
        openGrokHome: URL,
        environment: [String: String],
        samplingProvider: ModelProvider,
        samplingAPIKey: String,
        samplingBaseURL: String,
        imageGenEnabled: Bool,
        imageEditEnabled: Bool
    ) -> LiveImageToolAvailability {
        guard let apiKey = xaiMediaAPIKey(
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
        return LiveImageToolAvailability(
            config: .enabled(ImageGenSettings(
                provider: .grok,
                apiKey: apiKey,
                baseURL: baseURL,
                extraHeaders: headers,
                bearerProvider: LiveXaiImageBearerProvider(bearer: apiKey),
                imageGenEnabled: imageGenEnabled,
                imageEditEnabled: imageEditEnabled,
                modelOverride: resolveStringFlag(
                    envKey: "GROK_IMAGE_GEN_MODEL_OVERRIDE",
                    configKey: "image_gen_model_override",
                    workingDirectory: workingDirectory,
                    openGrokHome: openGrokHome,
                    environment: environment
                ),
                editModelOverride: resolveStringFlag(
                    envKey: "GROK_IMAGE_EDIT_MODEL_OVERRIDE",
                    configKey: "image_edit_model_override",
                    workingDirectory: workingDirectory,
                    openGrokHome: openGrokHome,
                    environment: environment
                ),
                tierRestricted: false
            )),
            imageGenEnabled: imageGenEnabled,
            imageEditEnabled: imageEditEnabled
        )
    }

    /// `xai_media_api_key` (`agent_ops.rs:2213`): only xAI-provenanced
    /// credentials may reach an xAI media endpoint.
    static func xaiMediaAPIKey(
        samplingProvider: ModelProvider,
        samplingAPIKey: String,
        environment: [String: String]
    ) -> String? {
        if samplingProvider.profile.sessionAuth.isXai, !samplingAPIKey.isEmpty {
            return samplingAPIKey
        }
        // The session is on another provider, so its bearer is off-limits here.
        // Fall back to a stored/explicit xAI key, which is xAI-provenanced by
        // construction.
        let candidates = ["XAI_API_KEY", "GROK_API_KEY"]
        for key in candidates {
            if let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    /// `CodexCredentials::supports_image_generation`
    /// (`xai-grok-shell/src/codex_auth.rs:218`): every plan except Free.
    static func supportsImageGeneration(_ credentials: CodexCredentials) -> Bool {
        guard let plan = credentials.planType else { return true }
        return plan.caseInsensitiveCompare("free") != .orderedSame
    }

    static func resolveProvider(
        workingDirectory: URL,
        openGrokHome: URL,
        environment: [String: String]
    ) -> ImageGenerationProvider {
        if let raw = environment["GROK_IMAGE_GENERATION_PROVIDER"],
           let parsed = ImageGenerationProvider.fromCanonical(raw) {
            return parsed
        }
        if let raw = configString(
            path: ["ui", "image_generation_provider"],
            workingDirectory: workingDirectory,
            openGrokHome: openGrokHome,
            environment: environment
        ), let parsed = ImageGenerationProvider.fromCanonical(raw) {
            return parsed
        }
        return .default
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

    private static func resolveStringFlag(
        envKey: String,
        configKey: String,
        workingDirectory: URL,
        openGrokHome: URL,
        environment: [String: String]
    ) -> String? {
        if let value = environment[envKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        return configString(
            path: ["features", configKey],
            workingDirectory: workingDirectory,
            openGrokHome: openGrokHome,
            environment: environment
        )
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

    private static func configString(
        path: [String],
        workingDirectory: URL,
        openGrokHome: URL,
        environment: [String: String]
    ) -> String? {
        for table in configTables(
            workingDirectory: workingDirectory,
            openGrokHome: openGrokHome,
            environment: environment
        ) {
            guard case .string(let raw)? = table[path: path] else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
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

// MARK: - Session image writer

/// Numbered image files under `<sessionFolder>/images`, matching upstream's
/// `SessionFileWriter` (`grok_build/storage.rs:56`): the counter resumes from
/// the highest existing `<n>.<ext>` so a resumed session never overwrites an
/// image the user already has, and the directory is created 0700.
final class LiveImageSessionWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let directoryName: String
    private var counter: Int?

    init(directoryName: String = "images") {
        self.directoryName = directoryName
    }

    func save(sessionFolder: String, bytes: Data, fileExtension: String) throws -> String {
        let directory = URL(fileURLWithPath: sessionFolder, isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let next = nextIndex(in: directory)
        let destination = directory.appendingPathComponent("\(next).\(fileExtension)")
        try bytes.write(to: destination, options: .atomic)
        return destination.path
    }

    private func nextIndex(in directory: URL) -> Int {
        lock.lock()
        defer { lock.unlock() }
        if counter == nil {
            counter = highestExistingIndex(in: directory)
        }
        let next = (counter ?? 0) + 1
        counter = next
        return next
    }

    private func highestExistingIndex(in directory: URL) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.reduce(0) { best, name in
            let stem = (name as NSString).deletingPathExtension
            guard let value = Int(stem), value > best else { return best }
            return value
        }
    }
}

// MARK: - Handler

/// `ToolHandler` for `image_gen` / `image_edit`.
///
/// Dispatch runs through `FinalizedToolset.prepareAndCall` like every other
/// tool, so the plan gate, PreToolUse hooks and permission evaluation all
/// happen before `invoke` is ever reached.
struct LiveImageToolHandler: ToolHandler {
    let client: ImageGenClient
    let writer: LiveImageSessionWriter

    init(client: ImageGenClient, writer: LiveImageSessionWriter = LiveImageSessionWriter()) {
        self.client = client
        self.writer = writer
    }

    func invoke(
        clientName: String,
        args: JSONValue,
        ctx: ToolCallContext,
        resources: ToolResources
    ) async -> Result<TypedToolOutput, ToolError> {
        guard let toolId = try? ToolId(clientName) else {
            return .failure(.invalidArguments("image tool name is not a valid ToolId"))
        }

        // Free / X Basic users are zero-limited on Imagine server-side. Upstream
        // returns the upsell as a *successful* result so the model can relay the
        // nudge instead of retrying a doomed request.
        if client.isTierRestricted {
            return .success(textOutput(toolId: toolId, text: TIER_RESTRICTED_UPSELL))
        }

        // Upstream threads an `ImageGenerationTurnId` resource here, falling
        // back to the call id. Neither is reachable at the `ToolHandler` seam —
        // `ToolCallContext` carries no call id — so this is per-session rather
        // than per-turn. It only feeds `x-codex-image-turn-id`, an
        // OpenAI-route header.
        let turnID = resources.sessionId
        let prompt = stringField(args, "prompt") ?? ""
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.invalidArguments("\(clientName) requires a non-empty prompt"))
        }
        let aspectRatio = stringField(args, "aspect_ratio") ?? "auto"

        let bytes: Data
        do {
            switch clientName {
            case IMAGE_GEN_TOOL_NAME:
                bytes = try await client.generate(
                    prompt: prompt,
                    aspectRatio: aspectRatio,
                    turnID: turnID
                )
            case IMAGE_EDIT_TOOL_NAME:
                let references = stringArrayField(args, "image")
                guard !references.isEmpty else {
                    return .failure(.invalidArguments(
                        "image_edit requires at least one reference image"
                    ))
                }
                bytes = try await client.edit(
                    prompt: prompt,
                    dataURLs: references,
                    aspectRatio: aspectRatio,
                    turnID: turnID
                )
            default:
                return .failure(.notImplemented(
                    "image tool handler does not implement \(clientName)"
                ))
            }
        } catch let error as ImageGenError {
            return .failure(.custom(code: "image_gen_failed", detail: error.description))
        } catch {
            return .failure(.custom(
                code: "image_gen_failed",
                detail: String(describing: error)
            ))
        }

        let path: String
        do {
            path = try writer.save(
                sessionFolder: resources.sessionFolder,
                bytes: bytes,
                fileExtension: client.fileExtension
            )
        } catch {
            return .failure(.invalidArguments(
                "failed to save generated image: \(String(describing: error))"
            ))
        }

        // The pager tool card is text-only, so the byte count is carried in the
        // prompt text rather than as structured image content.
        let text = "Saved image to \(path) (\(bytes.count) bytes)"
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

    private func stringArrayField(_ args: JSONValue, _ key: String) -> [String] {
        guard case .object(let obj) = args else { return [] }
        switch obj[key] {
        case .string(let single):
            return [single]
        case .array(let items):
            return items.compactMap { item in
                if case .string(let value) = item { return value }
                return nil
            }
        default:
            return []
        }
    }
}
