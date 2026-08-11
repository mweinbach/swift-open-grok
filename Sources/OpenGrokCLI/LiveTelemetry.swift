// LiveTelemetry.swift
//
// The live seam between the CLI's config stack and telemetry emission.
//
// This is the only place in the executable that decides whether telemetry
// exists. Everything downstream asks ``LiveTelemetry`` and gets a no-op when
// the answer is no, so an emission call site cannot accidentally become a
// second enable path.
//
// Upstream reference (`~/Projects/grok-build` @ `9ed09e2a`):
//   - init sites `crates/codegen/xai-grok-shell/src/agent/init.rs:195-205`,
//     `agent/mvp_agent/agent_ops.rs:589-599`
//   - the ZDR conjunct `agent/mvp_agent/agent_ops.rs:4302-4303`
//   - event gating by family `xai-grok-telemetry/src/session_ctx.rs:134-195`

import Foundation
import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokHTTP
import OpenGrokShared
import OpenGrokTelemetry

/// Product/session event names actually emitted by this port.
///
/// Upstream declares 120 `telemetry_event!` names
/// (`xai-grok-telemetry/src/events.rs:1687-1940`). Only the names with a live
/// emission site here are listed: an unused constant is a claim that the event
/// exists, and a collector that never receives it is worse than one that never
/// heard of it. The remainder are recorded as not-ported in `PORT_STATUS.md`
/// rather than stubbed here.
public enum LiveTelemetryEvent {
    public static let sessionNew = "session_new"
    public static let sessionEnded = "session_ended"
    public static let promptSubmitted = "prompt_submitted"
    public static let turnCompleted = "turn_completed"
    public static let toolCallCompleted = "tool_call_completed"
    public static let apiError = "api_error"
    public static let internalError = "internal_error"
}

/// What bootstrap decided, for `/status` and for tests.
public struct LiveTelemetryStatus: Sendable, Equatable {
    public var mode: TelemetryMode
    public var modeSource: TelemetryConfigSource
    /// `true` when a process-wide client was installed.
    public var clientInstalled: Bool
    /// `true` when the external customer-collector stream is active.
    public var externalStreamActive: Bool
    public var contentGates: OTELContentGates
    public var enforced: [TelemetryEnforcedField]

    public var isDark: Bool { !clientInstalled && !externalStreamActive }

    /// One line for `/status`. Says *why*, because "telemetry: off" with no
    /// attribution is the state a user cannot act on.
    public var summary: String {
        guard !isDark else { return "telemetry: off (\(modeSource.rawValue))" }
        var parts = ["telemetry: \(mode.description) (\(modeSource.rawValue))"]
        if externalStreamActive {
            var gates: [String] = []
            if contentGates.logUserPrompts { gates.append("prompts") }
            if contentGates.logToolDetails { gates.append("tool-details") }
            parts.append("external otel: on" + (gates.isEmpty ? "" : " [\(gates.joined(separator: ","))]"))
        }
        return parts.joined(separator: "; ")
    }
}

struct LiveTelemetryBootstrapContext: Sendable, Equatable {
    let zeroDataRetention: Bool
    let userID: String?
    let teamID: String?

    static let empty = LiveTelemetryBootstrapContext(
        zeroDataRetention: false,
        userID: nil,
        teamID: nil
    )
}

public enum LiveTelemetry {
    // MARK: - Resolution

    /// Merge the requirements tiers the security context carries separately.
    /// Order matches `validation.rs:71-105` — user, then system, then MDM.
    public static func mergedRequirements(_ layers: [TOMLValue]) -> TOMLValue? {
        guard !layers.isEmpty else { return nil }
        var merged = TOMLValue.table(TOMLTable())
        for layer in layers {
            deepMergeTOML(&merged, overrides: layer)
        }
        return merged
    }

    /// Assemble resolution inputs from an already-loaded config stack.
    ///
    /// - Important: `document` must be the **base** authority chain
    ///   (`ConfigLayers.effectiveConfigBase()`: system-managed → managed →
    ///   user → requirements), never a chain that includes the project tier.
    ///   Upstream has no project layer for telemetry at all
    ///   (`xai-grok-config/src/loader.rs:467-481`), and the reason matters: a
    ///   repo's checked-in `.opengrok/config.toml` must not be able to switch
    ///   on telemetry for anyone who clones it. Prefer
    ///   ``bootstrapFromDisk(environment:remoteSettings:zeroDataRetention:userID:teamID:)``,
    ///   which loads the correct chain itself.
    public static func inputs(
        document: TOMLValue,
        requirements: [TOMLValue] = [],
        remoteSettings: RemoteSettings? = nil,
        managedSettingsEnv: [String: String] = [:],
        environment: [String: String]
    ) -> TelemetryResolutionInputs {
        TelemetryResolutionInputs(
            effectiveConfig: document,
            requirements: mergedRequirements(requirements),
            // TelemetryModeResolver / ExternalOtelRemotePolicy still take
            // RemoteSettings; project through the allowlist so only reviewed
            // remote fields can influence resolution.
            remoteSettings: allowlistedRemoteSettingsProjection(remoteSettings),
            managedSettingsEnv: managedSettingsEnv,
            environment: environment
        )
    }

    /// Narrow `RemoteSettings` to allowlisted telemetry / OTEL fields.
    private static func allowlistedRemoteSettingsProjection(
        _ remote: RemoteSettings?
    ) -> RemoteSettings? {
        guard let remote else { return nil }
        let allowed = AllowlistedRemoteSettings(projecting: remote)
        var projected = RemoteSettings()
        projected.telemetryMode = allowed.telemetryMode
        projected.telemetryEnabled = allowed.telemetryEnabled
        projected.externalOtelDisabled = allowed.externalOtelDisabled
        projected.externalOtelContentGatesLocked = allowed.externalOtelContentGatesLocked
        return projected
    }

    // MARK: - Bootstrap

    /// Resolve telemetry and install the process-wide client, or install
    /// nothing.
    ///
    /// `zeroDataRetention` is the upstream conjunct at
    /// `agent_ops.rs:4302-4303`: a ZDR team never emits product telemetry
    /// regardless of what any config layer says. It is a parameter rather than
    /// something read here because the auth manager owns that fact, and
    /// re-deriving it in a second place is how the two answers drift apart.
    ///
    /// Returns the status. Callers should surface `status.summary` rather than
    /// assume; a bootstrap that silently did nothing is the failure mode this
    /// whole slice exists to prevent.
    @discardableResult
    public static func bootstrap(
        inputs: TelemetryResolutionInputs,
        zeroDataRetention: Bool = false,
        userID: String? = nil,
        teamID: String? = nil,
        transport: (any HTTPTransport)? = nil
    ) -> LiveTelemetryStatus {
        let resolution = TelemetryModeResolver.resolve(inputs)
        let external = ExternalOtelConfig.resolve(inputs: inputs)

        guard !zeroDataRetention else {
            // ZDR suppresses both streams. Install nothing and say so.
            Telemetry.initClient(nil)
            return LiveTelemetryStatus(
                mode: .disabled,
                modeSource: resolution.mode.source,
                clientInstalled: false,
                externalStreamActive: false,
                contentGates: OTELContentGates(),
                enforced: resolution.enforced
            )
        }

        let client = TelemetryClient.resolved(
            inputs: inputs,
            userID: userID,
            teamID: teamID,
            transport: transport
        )
        Telemetry.initClient(client)

        return LiveTelemetryStatus(
            mode: resolution.mode.value,
            modeSource: resolution.mode.source,
            clientInstalled: client != nil,
            externalStreamActive: external?.isActive ?? false,
            contentGates: external?.gates ?? OTELContentGates(),
            enforced: resolution.enforced
        )
    }

    /// Bootstrap from the process environment and the on-disk config layers.
    ///
    /// `environment` is required rather than defaulted to `ProcessInfo` at the
    /// library boundary: a process-wide default here is exactly the
    /// silent-divergence footgun `AGENTS.md` §2 calls out, and telemetry is the
    /// last place to want a resolution that depends on who called it.
    @discardableResult
    public static func bootstrapFromDisk(
        environment: [String: String],
        remoteSettings: RemoteSettings? = nil,
        zeroDataRetention: Bool = false,
        userID: String? = nil,
        teamID: String? = nil
    ) -> LiveTelemetryStatus {
        let layers = try? ConfigLayers.load(environment: environment)
        let document = layers?.effectiveConfigBase() ?? .table(TOMLTable())
        let requirements = [
            layers?.userRequirements,
            layers?.systemRequirements,
            layers?.mdmRequirements,
        ].compactMap { $0 }

        return bootstrap(
            inputs: inputs(
                document: document,
                requirements: requirements,
                remoteSettings: remoteSettings,
                environment: environment
            ),
            zeroDataRetention: zeroDataRetention,
            userID: userID,
            teamID: teamID
        )
    }

    /// Tear down the process-wide client (session end, tests).
    public static func shutdown() {
        Telemetry.initClient(nil)
    }

    // MARK: - Emission

    /// `true` when a product event would actually go somewhere.
    public static var isProductEnabled: Bool { Telemetry.isEnabled() }

    /// `true` when a session-lifecycle event would actually go somewhere.
    public static var isSessionMetricsEnabled: Bool { Telemetry.isSessionMetricsEnabled() }

    /// Emit a product analytics event. No-op unless the mode is `.enabled`.
    /// Mirrors `log_event` (`session_ctx.rs:134-144`).
    public static func logEvent(
        _ name: String,
        requestID: String = UUID().uuidString,
        metadata: TelemetryMetadata = [:]
    ) async {
        guard let client = Telemetry.current(), client.isProductEnabled else { return }
        await client.track(eventName: name, requestID: requestID, metadata: metadata)
    }

    /// Emit a session-lifecycle event. Fires in both `.enabled` and
    /// `.sessionMetrics`. Mirrors `log_session_event`
    /// (`session_ctx.rs:171-177`).
    public static func logSessionEvent(
        _ name: String,
        requestID: String = UUID().uuidString,
        metadata: TelemetryMetadata = [:]
    ) async {
        guard let client = Telemetry.current(), client.isSessionMetricsEnabled else { return }
        await client.track(eventName: name, requestID: requestID, metadata: metadata)
    }

    /// Emit a schema-mapped record to the external customer collector.
    ///
    /// Independent of ``logEvent(_:requestID:metadata:)``: upstream fans out to
    /// the external stream *before* checking the product mode
    /// (`session_ctx.rs:136`), because the two streams answer to different
    /// switches. The record passes through both privacy chokepoints inside
    /// ``OTLPExporter/exportRecord(_:provider:)``.
    @discardableResult
    public static func emitExternal(_ record: ExternalRecord) async -> Bool {
        guard let exporter = Telemetry.current()?.externalOTLP, exporter.isActive else {
            return false
        }
        return (try? await exporter.exportRecord(record)) ?? false
    }

    // MARK: - Span-shaped call sites

    /// Session start. `grok_code.session_start`.
    public static func sessionStarted(
        sessionID: String,
        model: String?,
        permissionMode: String?
    ) async {
        var attrs: [(ExternalKey, ExternalAttrValue)] = [(.sessionId, .string(sessionID))]
        if let model { attrs.append((.model, .string(model))) }
        if let permissionMode { attrs.append((.permissionMode, .string(permissionMode))) }
        await emitExternal(
            ExternalRecord(eventName: ExternalEventName.sessionStart, attrs: attrs)
        )
        await logSessionEvent(
            LiveTelemetryEvent.sessionNew,
            metadata: ["session_id": .string(sessionID)]
        )
    }

    /// Session end. `grok_code.session_end`.
    public static func sessionEnded(
        sessionID: String,
        durationSeconds: Int64,
        turnCount: Int64,
        toolCallCount: Int64
    ) async {
        await emitExternal(
            ExternalRecord(
                eventName: ExternalEventName.sessionEnd,
                attrs: [
                    (.sessionId, .string(sessionID)),
                    (.durationSecs, .int(durationSeconds)),
                    (.turnCount, .int(turnCount)),
                    (.toolCallCount, .int(toolCallCount)),
                ]
            )
        )
        await logSessionEvent(
            LiveTelemetryEvent.sessionEnded,
            metadata: ["session_id": .string(sessionID)]
        )
    }

    /// User prompt. The prompt body is a *gated* attribute — with the gate shut
    /// only its length is exported.
    public static func userPrompt(
        sessionID: String,
        promptID: String,
        prompt: String,
        model: String?
    ) async {
        var attrs: [(ExternalKey, ExternalAttrValue)] = [
            (.sessionId, .string(sessionID)),
            (.promptId, .string(promptID)),
            (.promptLength, .int(Int64(prompt.count))),
        ]
        if let model { attrs.append((.model, .string(model))) }
        await emitExternal(
            ExternalRecord(
                eventName: ExternalEventName.userPrompt,
                attrs: attrs,
                gated: [
                    ExternalGatedAttr(key: .prompt, gate: .userPrompts, value: .string(prompt))
                ]
            )
        )
        await logEvent(
            LiveTelemetryEvent.promptSubmitted,
            metadata: ["prompt_length": .number(.int64(Int64(prompt.count)))]
        )
    }

    /// Turn completion. `grok_code.turn_completed`.
    public static func turnCompleted(
        sessionID: String,
        turnNumber: Int64,
        durationMs: Int64,
        inputTokens: Int64?,
        outputTokens: Int64?,
        stopReason: String?
    ) async {
        var attrs: [(ExternalKey, ExternalAttrValue)] = [
            (.sessionId, .string(sessionID)),
            (.turnNumber, .int(turnNumber)),
            (.durationMs, .int(durationMs)),
        ]
        if let inputTokens { attrs.append((.inputTokens, .int(inputTokens))) }
        if let outputTokens { attrs.append((.outputTokens, .int(outputTokens))) }
        if let stopReason { attrs.append((.stopReason, .string(stopReason))) }
        await emitExternal(
            ExternalRecord(eventName: ExternalEventName.turnCompleted, attrs: attrs)
        )
        await logEvent(
            LiveTelemetryEvent.turnCompleted,
            metadata: ["turn_number": .number(.int64(turnNumber))]
        )
    }

    /// Tool completion. The verbatim tool name, the full path and the
    /// arguments are all *gated*; with the gate shut only the sanitized
    /// category, the outcome and the file extension are exported.
    public static func toolCompleted(
        sessionID: String,
        toolName: String,
        success: Bool,
        durationMs: Int64,
        filePath: String?,
        arguments: String?
    ) async {
        var attrs: [(ExternalKey, ExternalAttrValue)] = [
            (.sessionId, .string(sessionID)),
            (.toolName, .string(sanitizeToolName(toolName))),
            (.success, .bool(success)),
            (.durationMs, .int(durationMs)),
        ]
        if let filePath, let ext = externalFileExtension(filePath) {
            attrs.append((.fileExtension, .string(ext)))
        }
        var gated: [ExternalGatedAttr] = [
            ExternalGatedAttr(key: .toolName, gate: .toolDetails, value: .string(toolName))
        ]
        if let filePath {
            gated.append(
                ExternalGatedAttr(key: .filePath, gate: .toolDetails, value: .string(filePath))
            )
        }
        if let arguments {
            gated.append(
                ExternalGatedAttr(
                    key: .toolParameters,
                    gate: .toolDetails,
                    value: .string(arguments)
                )
            )
        }
        await emitExternal(
            ExternalRecord(
                eventName: ExternalEventName.toolResult,
                attrs: attrs,
                gated: gated
            )
        )
        await logEvent(
            LiveTelemetryEvent.toolCallCompleted,
            metadata: [
                "tool_name": .string(sanitizeToolName(toolName)),
                "success": .bool(success),
            ]
        )
    }
}
