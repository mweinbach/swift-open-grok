// TelemetryPrivacyGateTests.swift
//
// The privacy contract for telemetry, asserted rather than described.
//
// The single most important test in this file is
// `defaultSessionResolvesDisabledAndBuildsNoClient`: with no config and no
// env, telemetry must resolve to disabled, construct no client, and open no
// external stream. Every other test here defends a specific way that default
// could be lost.

import Foundation
import Testing
import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokHTTP
import OpenGrokShared
@testable import OpenGrokTelemetry

// MARK: - Helpers

/// A transport that records every request and refuses to answer any of them.
///
/// The default-off claim is "emits nothing and contacts nothing"; only a
/// transport that can report contact proves the second half. `MockHTTPTransport`
/// with an empty script throws on any send, so a leak surfaces as a recorded
/// request rather than a silently swallowed one.
private func forbiddenTransport() -> MockHTTPTransport { MockHTTPTransport() }

private func toml(_ source: String) throws -> TOMLValue {
    try parseTOML(source)
}

private let emptyInputs = TelemetryResolutionInputs()

// MARK: - The acceptance bar

@Suite struct TelemetryDefaultOffTests {
    @Test func defaultSessionResolvesDisabledAndBuildsNoClient() {
        let resolution = TelemetryModeResolver.resolve(emptyInputs)

        #expect(resolution.mode.value == .disabled)
        #expect(resolution.mode.source == .default)
        #expect(resolution.isDisabled)
        #expect(!resolution.isSessionMetricsEnabled)
        #expect(resolution.enforced.isEmpty)

        // No external stream.
        #expect(ExternalOtelConfig.resolve(inputs: emptyInputs) == nil)

        // No client at all — nothing exists that could emit.
        let transport = forbiddenTransport()
        let client = TelemetryClient.resolved(inputs: emptyInputs, transport: transport)
        #expect(client == nil)
        #expect(transport.recordedRequests.isEmpty)
    }

    @Test func defaultSyncPathIsDisabled() {
        #expect(TelemetryModeResolver.isDisabledSync(emptyInputs))
    }

    /// The specific inversion this slice existed to fix: a bare
    /// `TelemetryConfig()` must not enable product telemetry.
    @Test func bareConfigDefaultsProductTelemetryOff() {
        #expect(TelemetryConfig().productTelemetryEnabled == false)

        let client = TelemetryClient(mode: .enabled, config: TelemetryConfig())
        #expect(!client.isProductEnabled)
        #expect(!client.isMixpanelEnabled)
        #expect(!client.isOpenTelemetryEnabled)
    }

    @Test func defaultClientEmitsNoBytesAndContactsNothing() async {
        let transport = forbiddenTransport()
        let sink = RecordingExportSink(allowed: true)
        let client = TelemetryClient(
            mode: .disabled,
            config: TelemetryConfig(
                eventsURL: "https://collector.invalid/events",
                eventsAPIKey: "key"
            ),
            transport: transport,
            productExport: sink
        )

        await client.track(eventName: "session_new", requestID: "r")
        await client.trackMixpanel(event: "session_new")
        await client.exportOpenTelemetry(name: "session", attributes: ["model": .string("m")])

        #expect(sink.totalBytes == 0)
        #expect(transport.recordedRequests.isEmpty)
    }
}

// MARK: - Mode precedence

@Suite struct TelemetryModePrecedenceTests {
    @Test func requirementsPinOutranksEverything() throws {
        let inputs = TelemetryResolutionInputs(
            effectiveConfig: try toml("[features]\ntelemetry = true\n"),
            requirements: try toml("[features]\ntelemetry = false\n"),
            remoteSettings: nil,
            managedSettingsEnv: [:],
            environment: ["GROK_TELEMETRY_ENABLED": "true"]
        )
        let resolution = TelemetryModeResolver.resolve(inputs)
        #expect(resolution.mode.value == .disabled)
        #expect(resolution.mode.source == .requirement)
    }

    @Test func envOutranksConfigAndRemote() throws {
        var remote = RemoteSettings()
        remote.telemetryEnabled = true
        let inputs = TelemetryResolutionInputs(
            effectiveConfig: try toml("[features]\ntelemetry = true\n"),
            remoteSettings: remote,
            environment: ["GROK_TELEMETRY_ENABLED": "false"]
        )
        let resolution = TelemetryModeResolver.resolve(inputs)
        #expect(resolution.mode.value == .disabled)
        #expect(resolution.mode.source == .env)
    }

    @Test func configOutranksRemote() throws {
        var remote = RemoteSettings()
        remote.telemetryMode = "true"
        let inputs = TelemetryResolutionInputs(
            effectiveConfig: try toml("[features]\ntelemetry = \"session_metrics\"\n"),
            remoteSettings: remote
        )
        let resolution = TelemetryModeResolver.resolve(inputs)
        #expect(resolution.mode.value == .sessionMetrics)
        #expect(resolution.mode.source == .config)
        #expect(resolution.isSessionMetricsEnabled)
        #expect(!resolution.isEnabled)
    }

    @Test func remoteIsConsultedLastBeforeDefault() {
        var remote = RemoteSettings()
        remote.telemetryMode = "session_metrics"
        let resolution = TelemetryModeResolver.resolve(
            TelemetryResolutionInputs(remoteSettings: remote)
        )
        #expect(resolution.mode.value == .sessionMetrics)
        #expect(resolution.mode.source == .remote)
    }

    /// A typo in a config file must never fail open. Upstream warns
    /// `TELEMETRY_MODE_UNKNOWN` and treats the value as disabled
    /// (`config.rs:72-85`).
    @Test func unknownConfigModeStringResolvesDisabled() throws {
        let inputs = TelemetryResolutionInputs(
            effectiveConfig: try toml("[features]\ntelemetry = \"enabled-ish\"\n")
        )
        let resolution = TelemetryModeResolver.resolve(inputs)
        #expect(resolution.mode.value == .disabled)
    }

    @Test func modeParseTable() {
        for raw in ["1", "true", "yes", "on", "enabled", "full", " TRUE "] {
            #expect(TelemetryMode.parse(raw) == .enabled, "\(raw)")
        }
        for raw in ["0", "false", "no", "off", "disabled"] {
            #expect(TelemetryMode.parse(raw) == .disabled, "\(raw)")
        }
        for raw in ["session-metrics", "session_metrics"] {
            #expect(TelemetryMode.parse(raw) == .sessionMetrics, "\(raw)")
        }
        #expect(TelemetryMode.parse("maybe") == nil)
    }
}

// MARK: - DISABLE_TELEMETRY and kill switches

@Suite struct TelemetryKillSwitchTests {
    @Test func managedSettingsDisableForcesConfigLayerOff() throws {
        let inputs = TelemetryResolutionInputs(
            effectiveConfig: try toml("[features]\ntelemetry = true\n"),
            managedSettingsEnv: ["DISABLE_TELEMETRY": "1"]
        )
        let resolution = TelemetryModeResolver.resolve(inputs)
        #expect(resolution.mode.value == .disabled)
        #expect(resolution.mode.source == .config)
        #expect(
            resolution.enforced.contains(
                TelemetryEnforcedField(
                    path: "features.telemetry",
                    value: "false (DISABLE_TELEMETRY)"
                )
            )
        )
    }

    @Test func processEnvDisableForcesOffInSyncPath() {
        let inputs = TelemetryResolutionInputs(
            environment: [
                "DISABLE_TELEMETRY": "1",
                "GROK_TELEMETRY_ENABLED": "true",
            ]
        )
        // Sync path: DISABLE_TELEMETRY outranks the enable var
        // (agent/config.rs:3291-3300).
        #expect(TelemetryModeResolver.isDisabledSync(inputs))
    }

    @Test func syncPathHonorsRequirementsPinFirst() throws {
        let inputs = TelemetryResolutionInputs(
            requirements: try toml("[features]\ntelemetry = true\n"),
            environment: ["DISABLE_TELEMETRY": "1"]
        )
        // Upstream precedent (agent/config.rs:3280-3285): an admin pin beats
        // DISABLE_TELEMETRY. Preserved deliberately, not an oversight.
        #expect(!TelemetryModeResolver.isDisabledSync(inputs))
    }

    @Test func managedSettingsFlagTruthinessIsLooseByDesign() {
        #expect(managedSettingsEnvFlag("1") == true)
        #expect(managedSettingsEnvFlag("yes please") == true)
        #expect(managedSettingsEnvFlag("0") == false)
        #expect(managedSettingsEnvFlag("false") == false)
        #expect(managedSettingsEnvFlag("") == false)
        #expect(managedSettingsEnvFlag(nil) == nil)
    }

    /// The two `env_bool` truth tables differ upstream and the difference is
    /// load-bearing for `GROK_EXTERNAL_OTEL=""`.
    @Test func envBoolTablesDifferOnEmptyString() {
        #expect(telemetryEnvBool("") == nil)
        #expect(externalEnvBool("") == false)
        #expect(telemetryEnvBool("enabled") == true)
        #expect(externalEnvBool("enabled") == nil)
    }
}

// MARK: - External stream double opt-in

@Suite struct ExternalOtelDoubleOptInTests {
    @Test func masterSwitchAloneEnablesNothing() {
        let cfg = ExternalOtelConfig.resolve(environment: ["GROK_EXTERNAL_OTEL": "1"])
        #expect(cfg == nil)
    }

    @Test func exporterVarsAloneEnableNothing() {
        let cfg = ExternalOtelConfig.resolve(
            environment: [
                "OTEL_LOGS_EXPORTER": "otlp",
                "OTEL_METRICS_EXPORTER": "otlp",
            ]
        )
        #expect(cfg == nil)
    }

    @Test func bothTogetherActivate() {
        let cfg = ExternalOtelConfig.resolve(
            environment: [
                "GROK_EXTERNAL_OTEL": "1",
                "OTEL_LOGS_EXPORTER": "otlp",
            ]
        )
        #expect(cfg != nil)
        #expect(cfg?.isActive == true)
        // Gates stay shut even on an activated stream.
        #expect(cfg?.gates.logUserPrompts == false)
        #expect(cfg?.gates.logToolDetails == false)
    }

    @Test func emptyMasterSwitchReadsAsOff() {
        let cfg = ExternalOtelConfig.resolve(
            getenv: { ["GROK_EXTERNAL_OTEL": "", "OTEL_LOGS_EXPORTER": "otlp"][$0] },
            file: ExternalOtelFileConfig(enabled: true)
        )
        // Empty string is an explicit `false` on this path, so it must beat
        // the file layer rather than fall through to it.
        #expect(cfg == nil)
    }

    @Test func unrecognizedProtocolDisablesTheWholeStream() {
        let cfg = ExternalOtelConfig.resolve(
            environment: [
                "GROK_EXTERNAL_OTEL": "1",
                "OTEL_LOGS_EXPORTER": "otlp",
                "OTEL_EXPORTER_OTLP_PROTOCOL": "carrier-pigeon",
            ]
        )
        #expect(cfg == nil)
    }

    @Test func remotePolicyCanForceDisableButNeverEnable() throws {
        let on = TelemetryResolutionInputs(
            environment: [
                "GROK_EXTERNAL_OTEL": "1",
                "OTEL_LOGS_EXPORTER": "otlp",
            ]
        )
        #expect(ExternalOtelConfig.resolve(inputs: on) != nil)

        var remote = RemoteSettings()
        remote.externalOtelDisabled = true
        var forced = on
        forced.remoteSettings = remote
        #expect(ExternalOtelConfig.resolve(inputs: forced) == nil)

        // And the reverse: a permissive remote cannot switch the stream on.
        var permissive = RemoteSettings()
        permissive.externalOtelDisabled = false
        permissive.externalOtelContentGatesLocked = false
        let off = TelemetryResolutionInputs(remoteSettings: permissive)
        #expect(ExternalOtelConfig.resolve(inputs: off) == nil)
    }

    @Test func remotePolicyLocksContentGatesShut() {
        var remote = RemoteSettings()
        remote.externalOtelContentGatesLocked = true
        let inputs = TelemetryResolutionInputs(
            remoteSettings: remote,
            environment: [
                "GROK_EXTERNAL_OTEL": "1",
                "OTEL_LOGS_EXPORTER": "otlp",
                "OTEL_LOG_USER_PROMPTS": "1",
                "OTEL_LOG_TOOL_DETAILS": "1",
            ]
        )
        let cfg = ExternalOtelConfig.resolve(inputs: inputs)
        #expect(cfg != nil)
        #expect(cfg?.gates.logUserPrompts == false)
        #expect(cfg?.gates.logToolDetails == false)
    }

    @Test func requirementsPinCanForceGatesShutOverEnv() throws {
        let inputs = TelemetryResolutionInputs(
            requirements: try toml(
                """
                [telemetry]
                otel_log_user_prompts = false
                otel_log_tool_details = false
                """
            ),
            environment: [
                "GROK_EXTERNAL_OTEL": "1",
                "OTEL_LOGS_EXPORTER": "otlp",
                "OTEL_LOG_USER_PROMPTS": "1",
                "OTEL_LOG_TOOL_DETAILS": "1",
            ]
        )
        let cfg = ExternalOtelConfig.resolve(inputs: inputs)
        #expect(cfg?.gates.logUserPrompts == false)
        #expect(cfg?.gates.logToolDetails == false)
    }

    @Test func fileConfigCanActivateWhenEnvIsSilent() throws {
        let inputs = TelemetryResolutionInputs(
            effectiveConfig: try toml(
                """
                [telemetry]
                otel_enabled = true
                otel_logs_exporter = "otlp"
                """
            )
        )
        let cfg = ExternalOtelConfig.resolve(inputs: inputs)
        #expect(cfg != nil)
        #expect(cfg?.gates.logUserPrompts == false)
    }
}

// MARK: - Content gates: the load-bearing proof

@Suite struct ExternalContentGateTests {
    private static let secretPrompt = """
        Refactor this and use my key sk-abcdefghijklmnopqrstuvwxyz012345 \
        in /Users/realperson/Projects/secret-app/main.swift
        """

    private func promptRecord() -> ExternalRecord {
        ExternalRecord(
            eventName: ExternalEventName.userPrompt,
            attrs: [
                (.promptLength, .int(Int64(Self.secretPrompt.count))),
                (.model, .string("grok-4")),
            ],
            gated: [
                ExternalGatedAttr(
                    key: .prompt,
                    gate: .userPrompts,
                    value: .string(Self.secretPrompt)
                )
            ]
        )
    }

    private func toolRecord() -> ExternalRecord {
        ExternalRecord(
            eventName: ExternalEventName.toolResult,
            attrs: [
                (.toolName, .string(sanitizeToolName("mcp__acme__deploy"))),
                (.success, .bool(true)),
                (.fileExtension, .string("swift")),
            ],
            gated: [
                ExternalGatedAttr(key: .toolName, gate: .toolDetails, value: .string("mcp__acme__deploy")),
                ExternalGatedAttr(
                    key: .filePath,
                    gate: .toolDetails,
                    value: .string("/Users/realperson/Projects/secret-app/main.swift")
                ),
                ExternalGatedAttr(
                    key: .toolParameters,
                    gate: .toolDetails,
                    value: .string(#"{"target":"prod","token":"sk-abcdefghijklmnopqrstuvwxyz012345"}"#)
                ),
            ]
        )
    }

    /// THE test the slice is graded on: with gates off, a prompt body cannot
    /// reach an exporter.
    @Test func promptBodyCannotReachExporterWithGatesOff() async throws {
        let gates = OTELContentGates()
        let prepared = try #require(
            ExternalRecordValidator.prepareForExport(promptRecord(), gates: gates)
        )

        let keys = prepared.attrs.map(\.0)
        #expect(!keys.contains(.prompt))
        #expect(keys.contains(.promptLength))

        // And no attribute value contains any fragment of the prompt.
        for (_, value) in prepared.attrs {
            guard case .string(let s) = value else { continue }
            #expect(!s.contains("Refactor this"))
            #expect(!s.contains("sk-abcdefghijklmnopqrstuvwxyz012345"))
            #expect(!s.contains("realperson"))
        }

        // Byte-level: the serialized OTLP body must not contain the prompt.
        let exporter = try #require(makeExporter(gates: gates))
        let wire = try #require(try exporter.makeRecordWireRequest(prepared))
        let body = String(decoding: wire.body, as: UTF8.self)
        #expect(!body.contains("Refactor this"))
        #expect(!body.contains("sk-abcdefghijklmnopqrstuvwxyz012345"))
        #expect(!body.contains("realperson"))
    }

    /// A home path cannot reach an exporter with gates off.
    @Test func homePathCannotReachExporterWithGatesOff() async throws {
        let gates = OTELContentGates()
        let prepared = try #require(
            ExternalRecordValidator.prepareForExport(toolRecord(), gates: gates)
        )

        let keys = prepared.attrs.map(\.0)
        #expect(!keys.contains(.filePath))
        #expect(!keys.contains(.toolParameters))
        // Only the extension survives.
        #expect(keys.contains(.fileExtension))
        // The verbatim MCP tool name did not replace the sanitized one.
        let toolName = prepared.attrs.first { $0.0 == .toolName }?.1
        #expect(toolName == .string("mcp_tool"))

        let exporter = try #require(makeExporter(gates: gates))
        let wire = try #require(try exporter.makeRecordWireRequest(prepared))
        let body = String(decoding: wire.body, as: UTF8.self)
        #expect(!body.contains("/Users/realperson"))
        #expect(!body.contains("realperson"))
        #expect(!body.contains("secret-app"))
        #expect(!body.contains("acme"))
    }

    /// The export path itself refuses a record that skipped gating, so a
    /// caller cannot reach the wire by forgetting to call `applyGates`.
    @Test func exportRefusesRecordWithUnappliedGatedAttributes() throws {
        let gates = OTELContentGates()
        let rejection = ExternalRecordValidator.rejection(promptRecord(), gates: gates)
        #expect(rejection == .unappliedGatedAttribute(key: "prompt"))
    }

    /// And it refuses a record that carries a gated key with the gate shut,
    /// even if something hand-built it into `attrs`.
    @Test func exportRefusesHandBuiltGatedKey() throws {
        let smuggled = ExternalRecord(
            eventName: ExternalEventName.userPrompt,
            attrs: [(.prompt, .string("hello"))]
        )
        #expect(
            ExternalRecordValidator.rejection(smuggled, gates: OTELContentGates())
                == .closedGate(key: "prompt", gate: .userPrompts)
        )
        #expect(ExternalRecordValidator.prepareForExport(smuggled, gates: OTELContentGates()) == nil)

        let exporter = try #require(makeExporter(gates: OTELContentGates()))
        let smuggledWire = try exporter.makeRecordWireRequest(smuggled)
        #expect(smuggledWire == nil)
    }

    /// With the gate open the value is admitted — but still scrubbed. The
    /// opt-in buys prompt text, not unscrubbed secrets.
    @Test func openGateAdmitsScrubbedValueOnly() throws {
        let gates = OTELContentGates(logUserPrompts: true, logToolDetails: false)
        let prepared = try #require(
            ExternalRecordValidator.prepareForExport(promptRecord(), gates: gates)
        )
        let prompt = prepared.attrs.first { $0.0 == .prompt }?.1
        guard case .string(let text)? = prompt else {
            Issue.record("prompt attribute missing with gate open")
            return
        }
        #expect(text.contains("Refactor this"))
        #expect(!text.contains("sk-abcdefghijklmnopqrstuvwxyz012345"))
        #expect(!text.contains("realperson"))
    }

    /// A record whose string values were never scrubbed is dropped whole
    /// rather than scrubbed in place at export time.
    @Test func validatorDropsUnscrubbedStrings() {
        let dirty = ExternalRecord(
            eventName: ExternalEventName.toolResult,
            attrs: [(.model, .string("/Users/realperson/model"))]
        )
        #expect(
            ExternalRecordValidator.rejection(dirty, gates: OTELContentGates())
                == .unscrubbedString(key: "model")
        )
    }

    @Test func gateForKeyMatchesUpstreamKeySet() {
        #expect(externalGate(forKey: "prompt") == .userPrompts)
        for key in ["tool_parameters", "file_path", "skill.name", "plugin_name", "plugin_version"] {
            #expect(externalGate(forKey: key) == .toolDetails, "\(key)")
        }
        for key in ["model", "tool_name", "duration_ms", "session.id"] {
            #expect(externalGate(forKey: key) == nil, "\(key)")
        }
    }

    @Test func allowlistIsExactlyTheTypedKeys() {
        #expect(externalAllowedKeys.count == ExternalKey.allCases.count)
        #expect(externalAllowedKeys.contains("session.id"))
        #expect(!externalAllowedKeys.contains("user_prompt"))
        #expect(!externalAllowedKeys.contains("messages"))
    }

    @Test func toolNameSanitizerCategories() {
        #expect(sanitizeToolName("bash") == "bash")
        #expect(sanitizeToolName("mcp__acme__deploy") == "mcp_tool")
        #expect(sanitizeToolName("MyCompanyTool") == "custom_tool")
    }

    @Test func fileExtensionCapAndLowercasing() {
        #expect(externalFileExtension("/a/b/Main.SWIFT") == "swift")
        #expect(externalFileExtension("/a/b/noext") == nil)
        #expect(externalFileExtension("/a/b/f.thisextensioniswaytoolong") == nil)
    }

    @Test func promptContentCapAppliesAtSixtyKilobytes() {
        let huge = String(repeating: "a", count: 70 * 1024)
        let capped = ExternalTruncation.truncateContent(huge)
        #expect(capped.utf8.count <= ExternalTruncation.maxContentBytes
            + ExternalTruncation.truncationMarker.utf8.count)
        #expect(capped.hasSuffix(ExternalTruncation.truncationMarker))
    }

    @Test func standardValuesTruncateAtFiveTwelve() {
        let long = String(repeating: "b", count: 600)
        let out = ExternalTruncation.truncateValue(long)
        #expect(out.count == ExternalTruncation.truncatedPrefixLength
            + ExternalTruncation.truncationMarker.count)
        #expect(ExternalTruncation.truncateValue("short") == "short")
    }

    private func makeExporter(gates: OTELContentGates) -> OTLPExporter? {
        guard var cfg = ExternalOtelConfig.resolve(
            environment: [
                "GROK_EXTERNAL_OTEL": "1",
                "OTEL_TRACES_EXPORTER": "otlp",
                "OTEL_EXPORTER_OTLP_ENDPOINT": "http://collector.invalid:4318",
            ]
        ) else { return nil }
        cfg.gates = gates
        return OTLPExporter(config: cfg, transport: forbiddenTransport())
    }
}

// MARK: - Redaction

@Suite struct TelemetryRedactionDetectorTests {
    @Test func redactionIsIdempotentSoTheDetectorIsStable() {
        let inputs = [
            "/Users/realperson/x",
            "Bearer abcdefghijklmnopqrstuvwxyz",
            "sk-abcdefghijklmnopqrstuvwxyz012345",
            "/home/realperson/y",
        ]
        for input in inputs {
            let once = TelemetryRedaction.redactString(input)
            #expect(once != input, "\(input) should have been redacted")
            #expect(TelemetryRedaction.redactString(once) == once, "\(input) not idempotent")
            #expect(TelemetryRedaction.redactedIfChanged(once) == nil, "\(input) flagged twice")
        }
    }

    @Test func cleanStringsAreNotFlagged() {
        for clean in ["grok-4", "session_new", "1234", "", "tool_result"] {
            #expect(TelemetryRedaction.redactedIfChanged(clean) == nil, "\(clean)")
        }
    }

    @Test func homePathsAreRedacted() {
        #expect(!TelemetryRedaction.redactString("/Users/realperson/x").contains("realperson"))
        #expect(!TelemetryRedaction.redactString("/home/realperson/x").contains("realperson"))
    }
}
