// LiveTelemetryTests.swift
//
// The acceptance bar for the telemetry slice, asserted through the live seam
// rather than against composition types: a session with no config and no env
// emits nothing and contacts nothing.
//
// `AGENTS.md` §3 is the reason these go through `LiveTelemetry.bootstrap` and
// then through the real emission helpers. A composition-level test passes just
// as happily when nothing constructs the composition; these fail if bootstrap
// stops installing a client, and they fail if an emission helper stops asking.

import Foundation
import Testing
import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokHTTP
import OpenGrokShared
import OpenGrokTelemetry
@testable import OpenGrokCLI

private func toml(_ source: String) throws -> TOMLValue {
    try parseTOML(source)
}

/// Records every request and answers none — contact shows up as a recorded
/// request rather than being swallowed.
private func forbiddenTransport() -> MockHTTPTransport { MockHTTPTransport() }

@Suite(.serialized)
struct LiveTelemetryDefaultOffTests {
    /// THE acceptance test for this slice.
    @Test func emptySessionInstallsNothingAndContactsNothing() async {
        LiveTelemetry.shutdown()
        defer { LiveTelemetry.shutdown() }

        let transport = forbiddenTransport()
        let status = LiveTelemetry.bootstrap(
            inputs: LiveTelemetry.inputs(
                document: .table(TOMLTable()),
                environment: [:]
            ),
            transport: transport
        )

        #expect(status.mode == .disabled)
        #expect(status.modeSource == .default)
        #expect(!status.clientInstalled)
        #expect(!status.externalStreamActive)
        #expect(status.isDark)
        #expect(status.contentGates == OTELContentGates())
        #expect(status.summary == "telemetry: off (default)")

        // Nothing was installed, so nothing downstream can emit.
        #expect(Telemetry.current() == nil)
        #expect(!LiveTelemetry.isProductEnabled)
        #expect(!LiveTelemetry.isSessionMetricsEnabled)

        // Drive every live emission helper anyway. Each must be a no-op.
        await LiveTelemetry.sessionStarted(
            sessionID: "s1",
            model: "grok-4",
            permissionMode: "default"
        )
        await LiveTelemetry.userPrompt(
            sessionID: "s1",
            promptID: "p1",
            prompt: "my secret prompt in /Users/realperson/app",
            model: "grok-4"
        )
        await LiveTelemetry.turnCompleted(
            sessionID: "s1",
            turnNumber: 1,
            durationMs: 12,
            inputTokens: 10,
            outputTokens: 20,
            stopReason: "end_turn"
        )
        await LiveTelemetry.toolCompleted(
            sessionID: "s1",
            toolName: "mcp__acme__deploy",
            success: true,
            durationMs: 5,
            filePath: "/Users/realperson/app/main.swift",
            arguments: #"{"token":"sk-abcdefghijklmnopqrstuvwxyz012345"}"#
        )
        await LiveTelemetry.sessionEnded(
            sessionID: "s1",
            durationSeconds: 30,
            turnCount: 1,
            toolCallCount: 1
        )
        let externalAccepted = await LiveTelemetry.emitExternal(
            ExternalRecord(
                eventName: ExternalEventName.userPrompt,
                attrs: [(.promptLength, .int(5))]
            )
        )

        #expect(!externalAccepted)
        #expect(transport.recordedRequests.isEmpty)
    }

    /// The whole disk path, with an empty home, must land in the same place.
    @Test func diskBootstrapWithEmptyHomeIsDark() throws {
        LiveTelemetry.shutdown()
        defer { LiveTelemetry.shutdown() }

        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-telemetry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let status = LiveTelemetry.bootstrapFromDisk(
            environment: ["OPENGROK_HOME": home.path, "HOME": home.path]
        )

        #expect(status.isDark)
        #expect(status.mode == .disabled)
        #expect(Telemetry.current() == nil)
    }

    /// A repo's own config cannot switch telemetry on for whoever clones it.
    ///
    /// `bootstrapFromDisk` loads only the base authority chain
    /// (system-managed → managed → user → requirements). A project
    /// `.opengrok/config.toml` sitting in the workspace is never consulted,
    /// matching upstream, which has no project tier for telemetry at all.
    @Test func projectConfigCannotEnableTelemetry() throws {
        LiveTelemetry.shutdown()
        defer { LiveTelemetry.shutdown() }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-telemetry-project-\(UUID().uuidString)")
        let projectDir = root.appendingPathComponent(".opengrok")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try """
            [features]
            telemetry = true

            [telemetry]
            otel_enabled = true
            otel_logs_exporter = "otlp"
            """
            .write(
                to: projectDir.appendingPathComponent("config.toml"),
                atomically: true,
                encoding: .utf8
            )

        let previousCwd = FileManager.default.currentDirectoryPath
        #expect(FileManager.default.changeCurrentDirectoryPath(root.path))
        defer { _ = FileManager.default.changeCurrentDirectoryPath(previousCwd) }

        let status = LiveTelemetry.bootstrapFromDisk(
            environment: ["OPENGROK_HOME": root.path, "HOME": root.path]
        )

        #expect(status.isDark)
        #expect(status.mode == .disabled)
        #expect(!status.externalStreamActive)
        #expect(Telemetry.current() == nil)
    }

    /// Zero-data-retention suppresses both streams even with every switch on.
    @Test func zeroDataRetentionSuppressesEverything() throws {
        LiveTelemetry.shutdown()
        defer { LiveTelemetry.shutdown() }

        let status = LiveTelemetry.bootstrap(
            inputs: LiveTelemetry.inputs(
                document: try toml("[features]\ntelemetry = true\n"),
                environment: [
                    "GROK_EXTERNAL_OTEL": "1",
                    "OTEL_LOGS_EXPORTER": "otlp",
                    "OTEL_LOG_USER_PROMPTS": "1",
                ]
            ),
            zeroDataRetention: true
        )

        #expect(status.isDark)
        #expect(!status.clientInstalled)
        #expect(!status.externalStreamActive)
        #expect(Telemetry.current() == nil)
    }
}

@Suite(.serialized)
struct LiveTelemetryEnabledPathTests {
    /// The seam is genuinely reachable: with telemetry turned on, bootstrap
    /// installs a client and the emission helpers become live.
    ///
    /// Without this, every default-off assertion above would also pass if
    /// bootstrap were hard-coded to do nothing.
    @Test func explicitOptInInstallsAClient() throws {
        LiveTelemetry.shutdown()
        defer { LiveTelemetry.shutdown() }

        let status = LiveTelemetry.bootstrap(
            inputs: LiveTelemetry.inputs(
                document: try toml(
                    """
                    [features]
                    telemetry = true

                    [telemetry]
                    events_url = "https://collector.invalid/events"
                    events_api_key = "k"
                    """
                ),
                environment: [:]
            ),
            transport: forbiddenTransport()
        )

        #expect(status.mode == .enabled)
        #expect(status.modeSource == .config)
        #expect(status.clientInstalled)
        #expect(!status.isDark)
        #expect(Telemetry.current() != nil)
        #expect(LiveTelemetry.isProductEnabled)
    }

    /// And the external stream is separately reachable, with gates shut.
    @Test func externalOptInActivatesStreamWithGatesShut() {
        LiveTelemetry.shutdown()
        defer { LiveTelemetry.shutdown() }

        let status = LiveTelemetry.bootstrap(
            inputs: LiveTelemetry.inputs(
                document: .table(TOMLTable()),
                environment: [
                    "GROK_EXTERNAL_OTEL": "1",
                    "OTEL_TRACES_EXPORTER": "otlp",
                    "OTEL_EXPORTER_OTLP_ENDPOINT": "http://collector.invalid:4318",
                ]
            ),
            transport: forbiddenTransport()
        )

        #expect(status.externalStreamActive)
        #expect(status.clientInstalled)
        // Product telemetry stays off: the two switches are independent.
        #expect(status.mode == .disabled)
        #expect(!LiveTelemetry.isProductEnabled)
        // And content gates are shut on the freshly activated stream.
        #expect(status.contentGates.logUserPrompts == false)
        #expect(status.contentGates.logToolDetails == false)
    }

    /// With the external stream on and gates shut, a real prompt driven
    /// through the live helper must not put the prompt on the wire.
    @Test func livePromptWithGatesShutSendsNoPromptBytes() async {
        LiveTelemetry.shutdown()
        defer { LiveTelemetry.shutdown() }

        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(
                statusCode: 200,
                headers: [:],
                url: URL(string: "http://collector.invalid:4318/v1/traces")!
            ))
        ])
        let status = LiveTelemetry.bootstrap(
            inputs: LiveTelemetry.inputs(
                document: .table(TOMLTable()),
                environment: [
                    "GROK_EXTERNAL_OTEL": "1",
                    "OTEL_TRACES_EXPORTER": "otlp",
                    "OTEL_EXPORTER_OTLP_ENDPOINT": "http://collector.invalid:4318",
                ]
            ),
            transport: transport
        )
        #expect(status.externalStreamActive)

        await LiveTelemetry.userPrompt(
            sessionID: "s1",
            promptID: "p1",
            prompt: "deploy with sk-abcdefghijklmnopqrstuvwxyz012345 from /Users/realperson/app",
            model: "grok-4"
        )

        // The stream is on, so a request is expected — but it must carry only
        // the length, never the body.
        for request in transport.recordedRequests {
            let body = String(decoding: request.body ?? Data(), as: UTF8.self)
            #expect(!body.contains("deploy with"))
            #expect(!body.contains("sk-abcdefghijklmnopqrstuvwxyz012345"))
            #expect(!body.contains("realperson"))
        }
        #expect(!transport.recordedRequests.isEmpty)
    }
}
