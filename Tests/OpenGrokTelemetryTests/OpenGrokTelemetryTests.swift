// OpenGrokTelemetryTests.swift
//
// Telemetry mode gates, Mixpanel scrub-then-inject, independent export
// disable, and golden privacy tests proving disabled/vetoed events emit
// no bytes.

import Foundation
import Testing
@testable import OpenGrokHTTP
import OpenGrokShared
@testable import OpenGrokTelemetry
@testable import OpenGrokTracing

@Suite("TelemetryMode")
struct TelemetryModeTests {
    @Test func parseVariants() {
        #expect(TelemetryMode.parse("true") == .enabled)
        #expect(TelemetryMode.parse("false") == .disabled)
        #expect(TelemetryMode.parse("session_metrics") == .sessionMetrics)
        #expect(TelemetryMode.parse("session-metrics") == .sessionMetrics)
        #expect(TelemetryMode.parse("nope") == nil)
    }

    @Test func sessionMetricsGate() {
        #expect(TelemetryMode.disabled.sessionMetricsEnabled == false)
        #expect(TelemetryMode.sessionMetrics.sessionMetricsEnabled == true)
        #expect(TelemetryMode.enabled.sessionMetricsEnabled == true)
        #expect(TelemetryMode.sessionMetrics.isEnabled == false)
    }
}

@Suite("Mixpanel prepareProperties")
struct MixpanelTests {
    @Test func scrubsThenInjectsToken() {
        // Token is deliberately Bearer-shaped: would be redacted if scrub ran after inject.
        let projectToken = "Bearer fake-project-token-abcdef0123456789"
        let mp = MixpanelClient(
            token: projectToken,
            transport: MockHTTPTransport()
        )
        let prepared = mp.prepareProperties([
            "error": .string("Bearer abcdef0123456789abcdef"),
        ])
        #expect(prepared["token"] == .string(projectToken))
        if case .string(let error)? = prepared["error"] {
            #expect(!error.contains("abcdef0123456789abcdef"))
        } else {
            Issue.record("missing error property")
        }
    }

    @Test func trackDisabledEmitsNoBytes() async throws {
        let sink = RecordingExportSink(allowed: true)
        let mp = MixpanelClient(
            token: "tok",
            transport: MockHTTPTransport(),
            exportAllowed: { false }
        )
        try await mp.track(
            event: "test_event",
            properties: ["distinct_id": .string("u1")],
            recording: sink
        )
        // exportAllowed short-circuits before exportIfAllowed.
        #expect(sink.totalBytes == 0)
        #expect(sink.payloads.isEmpty)
    }

    @Test func trackVetoedSinkEmitsNoBytes() async throws {
        let sink = RecordingExportSink(allowed: false)
        let mp = MixpanelClient(
            token: "tok",
            transport: MockHTTPTransport(),
            exportAllowed: { true }
        )
        try await mp.track(
            event: "test_event",
            properties: ["x": .string("y")],
            recording: sink
        )
        #expect(sink.totalBytes == 0)
    }

    @Test func trackAllowedRecordsBytes() async throws {
        let sink = RecordingExportSink(allowed: true)
        let mp = MixpanelClient(
            token: "tok",
            transport: MockHTTPTransport(),
            exportAllowed: { true }
        )
        try await mp.track(
            event: "test_event",
            properties: ["distinct_id": .string("u1")],
            recording: sink
        )
        #expect(sink.totalBytes > 0)
        let text = String(data: sink.payloads[0], encoding: .utf8) ?? ""
        #expect(text.contains("test_event"))
        #expect(text.contains("tok"))
    }
}

@Suite("Product telemetry privacy")
struct ProductTelemetryPrivacyTests {
    @Test func disabledModeEmitsNoBytes() async {
        let product = RecordingExportSink()
        let mix = RecordingExportSink()
        let otel = RecordingExportSink()
        // Product + Mixpanel honor TelemetryMode; OTEL is independently gated
        // via openTelemetryEnabled (left off here so the full surface is quiet).
        let client = TelemetryClient(
            mode: .disabled,
            config: TelemetryConfig(
                eventsURL: "https://example.test/events",
                eventsAPIKey: "key",
                mixpanelEnabled: true,
                mixpanelToken: "mp",
                openTelemetryEnabled: false,
                productTelemetryEnabled: true
            ),
            productExport: product,
            otelExport: otel,
            mixpanelExport: mix
        )
        await client.track(eventName: "session.start", requestID: "r1")
        await client.trackMixpanel(event: "session.start")
        await client.exportOpenTelemetry(name: "span")
        #expect(product.totalBytes == 0)
        #expect(mix.totalBytes == 0)
        #expect(otel.totalBytes == 0)
    }

    @Test func otelIndependentOfProductMode() async {
        let otel = RecordingExportSink(allowed: true)
        let client = TelemetryClient(
            mode: .disabled,
            config: TelemetryConfig(openTelemetryEnabled: true),
            otelExport: otel
        )
        await client.exportOpenTelemetry(name: "span", attributes: ["k": .string("v")])
        #expect(otel.totalBytes > 0)
    }

    @Test func independentMixpanelDisable() async {
        let product = RecordingExportSink()
        let mix = RecordingExportSink()
        let client = TelemetryClient(
            mode: .enabled,
            config: TelemetryConfig(
                eventsURL: "https://example.test/events",
                eventsAPIKey: "key",
                mixpanelEnabled: false,
                mixpanelToken: "mp",
                productTelemetryEnabled: true
            ),
            productExport: product,
            mixpanelExport: mix
        )
        await client.track(eventName: "e", requestID: "r")
        await client.trackMixpanel(event: "e")
        #expect(product.totalBytes > 0)
        #expect(mix.totalBytes == 0)
    }

    @Test func independentOTELDisable() async {
        let otel = RecordingExportSink()
        let client = TelemetryClient(
            mode: .enabled,
            config: TelemetryConfig(openTelemetryEnabled: false),
            otelExport: otel
        )
        await client.exportOpenTelemetry(
            name: "http",
            attributes: ["authorization": .string("Bearer secret")]
        )
        #expect(otel.totalBytes == 0)
    }

    @Test func otelDropsDenylistedAttributes() async {
        let otel = RecordingExportSink(allowed: true)
        let client = TelemetryClient(
            mode: .enabled,
            config: TelemetryConfig(openTelemetryEnabled: true),
            otelExport: otel
        )
        await client.exportOpenTelemetry(
            name: "tool",
            attributes: [
                "http.request.method": .string("POST"),
                "authorization": .string("Bearer secret"),
                "prompt": .string("do not leak"),
            ]
        )
        #expect(otel.totalBytes > 0)
        let payload = otel.payloads[0]
        #expect(OTLPWire.protobufContainsUTF8(payload, "POST"))
        #expect(!OTLPWire.protobufContainsUTF8(payload, "Bearer secret"))
        #expect(!OTLPWire.protobufContainsUTF8(payload, "do not leak"))
    }

    @Test func productVetoBeforeSerialize() async {
        let product = RecordingExportSink(allowed: false)
        let client = TelemetryClient(
            mode: .enabled,
            config: TelemetryConfig(
                eventsURL: "https://example.test/events",
                eventsAPIKey: "key",
                productTelemetryEnabled: true
            ),
            productExport: product
        )
        await client.track(
            eventName: "e",
            requestID: "r",
            metadata: ["prompt": .string("secret prompt text")]
        )
        #expect(product.totalBytes == 0)
        #expect(product.payloads.isEmpty)
    }

    @Test func sessionMetricsDoesNotEnableProduct() async {
        let product = RecordingExportSink()
        let client = TelemetryClient(
            mode: .sessionMetrics,
            config: TelemetryConfig(
                eventsURL: "https://example.test/events",
                eventsAPIKey: "key",
                productTelemetryEnabled: true
            ),
            productExport: product
        )
        #expect(client.isSessionMetricsEnabled)
        #expect(!client.isProductEnabled)
        await client.track(eventName: "session.start", requestID: "r")
        #expect(product.totalBytes == 0)
    }

    @Test func redactsMetadataSecrets() async {
        let product = RecordingExportSink(allowed: true)
        let client = TelemetryClient(
            mode: .enabled,
            config: TelemetryConfig(
                eventsURL: "https://example.test/events",
                eventsAPIKey: "key"
            ),
            productExport: product
        )
        await client.track(
            eventName: "e",
            requestID: "r",
            metadata: [
                "error": .string("Bearer abcdef0123456789abcdef"),
                "path": .string("/Users/bob/project/file.swift"),
            ]
        )
        let text = String(data: product.payloads[0], encoding: .utf8) ?? ""
        #expect(!text.contains("abcdef0123456789abcdef"))
        #expect(!text.contains("/Users/bob"))
    }
}

@Suite("External OTEL policy")
struct ExternalOTELTests {
    @Test func defaultOff() {
        let policy = ExternalOTELPolicy.fromEnvironment(environment: [:])
        #expect(!policy.enabled)
        #expect(ExternalOtelConfig.resolve(environment: [:]) == nil)
    }

    @Test func masterSwitchAloneEnablesNothing() {
        // Double opt-in: master without an exporter selection is inert.
        let cfg = ExternalOtelConfig.resolve(environment: [
            "OPENGROK_EXTERNAL_OTEL": "true",
            "OTEL_EXPORTER_OTLP_ENDPOINT": "https://collector.example:4318",
        ])
        #expect(cfg == nil)
        let policy = ExternalOTELPolicy.fromEnvironment(environment: [
            "OPENGROK_EXTERNAL_OTEL": "true",
            "OTEL_EXPORTER_OTLP_ENDPOINT": "https://collector.example:4318",
        ])
        #expect(!policy.enabled)
    }

    @Test func exportersAloneEnableNothing() {
        #expect(
            ExternalOtelConfig.resolve(environment: [
                "OTEL_LOGS_EXPORTER": "otlp",
            ]) == nil
        )
    }

    @Test func doubleOptInResolvesHTTPProtobuf() {
        let cfg = ExternalOtelConfig.resolve(environment: [
            "GROK_EXTERNAL_OTEL": "1",
            "OTEL_LOGS_EXPORTER": "otlp",
            "OTEL_EXPORTER_OTLP_ENDPOINT": "https://collector.example:4318",
            "OTEL_EXPORTER_OTLP_HEADERS": "x-custom=abc,Authorization=secret",
            "OTEL_EXPORTER_OTLP_LOGS_HEADERS": "x-log=1",
        ])
        #expect(cfg != nil)
        guard let cfg else { return }
        #expect(cfg.transport == .httpProtobuf)
        #expect(cfg.logsEndpoint == "https://collector.example:4318/v1/logs")
        #expect(cfg.spansEndpoint == "https://collector.example:4318/v1/traces")
        #expect(cfg.logsExporter == .otlp)
        #expect(cfg.spansExporter == .otlp)
        // Internal auth header names are stripped (provider/export isolation).
        #expect(!cfg.logsHeaders.contains(where: { $0.name.lowercased() == "authorization" }))
        #expect(cfg.logsHeaders.contains(where: { $0.name == "x-custom" && $0.value == "abc" }))
        #expect(cfg.logsHeaders.contains(where: { $0.name == "x-log" && $0.value == "1" }))
        #expect(!cfg.gates.logUserPrompts)
    }

    @Test func grpcTransportEndpointIsOriginOnly() {
        let cfg = ExternalOtelConfig.resolve(environment: [
            "OPENGROK_EXTERNAL_OTEL": "on",
            "OTEL_METRICS_EXPORTER": "otlp",
            "OTEL_EXPORTER_OTLP_PROTOCOL": "grpc",
            "OTEL_EXPORTER_OTLP_ENDPOINT": "https://collector.example:4317",
        ])
        #expect(cfg?.transport == .grpc)
        #expect(cfg?.metricsEndpoint == "https://collector.example:4317")
    }

    @Test func grokAlias() {
        let cfg = ExternalOtelConfig.resolve(environment: [
            "GROK_EXTERNAL_OTEL": "1",
            "OTEL_TRACES_EXPORTER": "otlp",
        ])
        #expect(cfg != nil)
    }

    @Test func providerVetoEmitsZeroBytes() async throws {
        let sink = RecordingExportSink(allowed: true)
        let cfg = ExternalOtelConfig(
            metricsExporter: .none,
            logsExporter: .none,
            spansExporter: .otlp,
            transport: .httpProtobuf,
            logsEndpoint: "https://collector.example/v1/logs",
            metricsEndpoint: "https://collector.example/v1/metrics",
            spansEndpoint: "https://collector.example/v1/traces",
            exportPolicy: OTELExportPolicy(deniedProviders: ["openai"])
        )
        let exporter = OTLPExporter(
            config: cfg,
            transport: MockHTTPTransport(),
            recording: sink
        )
        let ok = try await exporter.exportSpan(
            name: "sample",
            attributes: ["k": .string("v")],
            provider: "openai"
        )
        #expect(ok == false)
        #expect(sink.totalBytes == 0)
        #expect(sink.payloads.isEmpty)

        let allowed = try await exporter.exportSpan(
            name: "sample",
            attributes: ["k": .string("v")],
            provider: "xai"
        )
        #expect(allowed)
        #expect(sink.totalBytes > 0)
    }

    @Test func allowListRequiresProvider() async throws {
        let sink = RecordingExportSink(allowed: true)
        let cfg = ExternalOtelConfig(
            metricsExporter: .none,
            logsExporter: .none,
            spansExporter: .otlp,
            transport: .httpProtobuf,
            logsEndpoint: "http://localhost:4318/v1/logs",
            metricsEndpoint: "http://localhost:4318/v1/metrics",
            spansEndpoint: "http://localhost:4318/v1/traces",
            exportPolicy: OTELExportPolicy(allowedProviders: ["xai"])
        )
        let exporter = OTLPExporter(config: cfg, recording: sink)
        #expect(try await exporter.exportSpan(name: "n", provider: nil) == false)
        #expect(sink.totalBytes == 0)
        #expect(try await exporter.exportSpan(name: "n", provider: "xai"))
        #expect(sink.totalBytes > 0)
    }

    @Test func httpProtobufWireRequestShape() throws {
        let cfg = ExternalOtelConfig(
            metricsExporter: .none,
            logsExporter: .none,
            spansExporter: .otlp,
            transport: .httpProtobuf,
            logsEndpoint: "https://collector.example/v1/logs",
            metricsEndpoint: "https://collector.example/v1/metrics",
            spansEndpoint: "https://collector.example/v1/traces",
            spansHeaders: [OTLPHeader(name: "x-tenant", value: "t1")]
        )
        let exporter = OTLPExporter(config: cfg, transport: MockHTTPTransport())
        let wire = try exporter.makeSpanWireRequest(
            name: "http_request",
            attributes: ["http.request.method": .string("GET")],
            provider: "xai"
        )
        #expect(wire != nil)
        guard let wire else { return }
        #expect(wire.request.url.absoluteString == "https://collector.example/v1/traces")
        #expect(wire.request.headers["Content-Type"] == OTLPWire.httpProtobufContentType)
        #expect(wire.request.headers["x-tenant"] == "t1")
        #expect(!wire.request.headers.keys.contains(where: {
            $0.lowercased() == "authorization"
        }))
        #expect(!wire.body.isEmpty)
        // Must be real protobuf — never JSON mislabeled as x-protobuf.
        #expect(OTLPWire.looksLikeExportTraceProtobuf(wire.body))
        #expect(wire.body.first != UInt8(ascii: "{"))
        // Span name bytes are embedded as a length-delimited UTF-8 field.
        #expect(String(decoding: wire.body, as: UTF8.self).contains("http_request"))
    }

    @Test func grpcWireFramesPayload() throws {
        let cfg = ExternalOtelConfig(
            metricsExporter: .none,
            logsExporter: .none,
            spansExporter: .otlp,
            transport: .grpc,
            logsEndpoint: "https://collector.example:4317",
            metricsEndpoint: "https://collector.example:4317",
            spansEndpoint: "https://collector.example:4317"
        )
        let exporter = OTLPExporter(config: cfg)
        let wire = try exporter.makeSpanWireRequest(name: "g", provider: "xai")
        #expect(wire != nil)
        guard let wire else { return }
        #expect(wire.request.headers["Content-Type"] == OTLPWire.grpcContentType)
        #expect(wire.request.headers["TE"] == "trailers")
        // Collector-compatible TraceService Export RPC path (not bare origin).
        #expect(
            wire.request.url.absoluteString
                == "https://collector.example:4317" + OTLPWire.grpcTraceExportPath
        )
        // 1-byte flag + 4-byte length prefix around the protobuf body.
        #expect(wire.request.body?.count == wire.body.count + 5)
        #expect(wire.request.body?.first == 0)
        #expect(OTLPWire.looksLikeExportTraceProtobuf(wire.body))
        if let framed = wire.request.body, let inner = OTLPWire.unframeGRPC(framed) {
            #expect(inner == wire.body)
            #expect(OTLPWire.looksLikeExportTraceProtobuf(inner))
            #expect(OTLPWire.protobufContainsUTF8(inner, "g"))
        } else {
            Issue.record("expected unframeable gRPC protobuf frame")
        }
    }

    @Test func mockCollectorRecordsExport() async throws {
        let mock = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 200), body: Data())
        ])
        let cfg = ExternalOtelConfig(
            metricsExporter: .none,
            logsExporter: .none,
            spansExporter: .otlp,
            transport: .httpProtobuf,
            logsEndpoint: "https://collector.example/v1/logs",
            metricsEndpoint: "https://collector.example/v1/metrics",
            spansEndpoint: "https://collector.example/v1/traces",
            spansHeaders: [OTLPHeader(name: "x-api-tenant", value: "acme")]
        )
        let exporter = OTLPExporter(config: cfg, transport: mock)
        #expect(try await exporter.exportSpan(name: "turn", provider: "xai"))
        #expect(mock.recordedRequests.count == 1)
        #expect(mock.recordedRequests[0].headers["x-api-tenant"] == "acme")
        #expect(mock.recordedRequests[0].headers["Content-Type"] == OTLPWire.httpProtobufContentType)
        #expect(mock.recordedRequests[0].url.path.hasSuffix("/v1/traces"))
        if let body = mock.recordedRequests[0].body {
            #expect(OTLPWire.looksLikeExportTraceProtobuf(body))
            #expect(OTLPWire.protobufContainsUTF8(body, "turn"))
        } else {
            Issue.record("expected HTTP protobuf body")
        }
    }

    /// In-process collector compatibility: non-recording MockHTTPTransport
    /// executes the async export path, receives a TraceService Export frame,
    /// and decodes a real `ExportTraceServiceRequest` protobuf (Rust
    /// `external_otlp_grpc` analogue at the request/decode layer).
    @Test func mockGRPCCollectorDecodesExportTraceServiceRequest() async throws {
        let mock = MockHTTPTransport(responses: [
            .init(
                metadata: HTTPResponseMetadata(
                    statusCode: 200,
                    headers: ["grpc-status": "0", "content-type": OTLPWire.grpcContentType]
                ),
                body: Data()
            )
        ])
        let cfg = ExternalOtelConfig(
            metricsExporter: .none,
            logsExporter: .none,
            spansExporter: .otlp,
            transport: .grpc,
            logsEndpoint: "http://127.0.0.1:4317",
            metricsEndpoint: "http://127.0.0.1:4317",
            spansEndpoint: "http://127.0.0.1:4317"
        )
        let exporter = OTLPExporter(config: cfg, transport: mock)
        #expect(
            try await exporter.exportSpan(
                name: "collector_compat",
                attributes: ["http.request.method": .string("GET")],
                provider: "xai"
            )
        )
        #expect(mock.recordedRequests.count == 1)
        let request = mock.recordedRequests[0]
        #expect(request.headers["Content-Type"] == OTLPWire.grpcContentType)
        #expect(request.headers["TE"] == "trailers")
        #expect(request.url.path == OTLPWire.grpcTraceExportPath)
        guard let framed = request.body, let inner = OTLPWire.unframeGRPC(framed) else {
            Issue.record("collector must receive a gRPC-framed protobuf body")
            return
        }
        #expect(OTLPWire.looksLikeExportTraceProtobuf(inner))
        #expect(OTLPWire.protobufContainsUTF8(inner, "collector_compat"))
        #expect(OTLPWire.protobufContainsUTF8(inner, "GET"))
        #expect(OTLPWire.protobufContainsUTF8(inner, "xai"))
        // Reject non-zero grpc-status.
        let reject = MockHTTPTransport(responses: [
            .init(
                metadata: HTTPResponseMetadata(
                    statusCode: 200,
                    headers: ["grpc-status": "13"]
                ),
                body: Data()
            )
        ])
        let rejecting = OTLPExporter(config: cfg, transport: reject)
        #expect(
            try await rejecting.exportSpan(name: "fail", provider: "xai") == false
        )
    }

    @Test func clientProviderVetoBeforeSerialize() async {
        let otel = RecordingExportSink(allowed: true)
        let cfg = ExternalOtelConfig(
            metricsExporter: .none,
            logsExporter: .none,
            spansExporter: .otlp,
            transport: .httpProtobuf,
            logsEndpoint: "http://localhost/v1/logs",
            metricsEndpoint: "http://localhost/v1/metrics",
            spansEndpoint: "http://localhost/v1/traces",
            exportPolicy: OTELExportPolicy(deniedProviders: ["openai"])
        )
        let client = TelemetryClient(
            mode: .enabled,
            config: TelemetryConfig(openTelemetryEnabled: true),
            otelExport: otel,
            externalOTLP: OTLPExporter(config: cfg, recording: otel)
        )
        await client.exportOpenTelemetry(
            name: "blocked",
            attributes: ["prompt": .string("secret")],
            provider: "openai"
        )
        #expect(otel.totalBytes == 0)
    }

    @Test func productEndpointIsUsedWhenEnabled() throws {
        let client = TelemetryClient(
            mode: .enabled,
            config: TelemetryConfig(
                openTelemetryEnabled: true,
                openTelemetryEndpoint: "https://otel.product.example/v1/traces"
            ),
            transport: MockHTTPTransport()
        )
        let request = try client.makeProductOTLPRequest(
            name: "product-span",
            attributes: ["k": .string("v")]
        )
        #expect(request != nil)
        #expect(
            request?.url.absoluteString == "https://otel.product.example/v1/traces"
        )
        #expect(request?.headers["Content-Type"] == OTLPWire.httpProtobufContentType)
        #expect(request?.body?.isEmpty == false)
        if let body = request?.body {
            #expect(OTLPWire.looksLikeExportTraceProtobuf(body))
            #expect(body.first != UInt8(ascii: "{"))
        }

        // Disabled product OTEL must not build a request (zero-byte invariant).
        let off = TelemetryClient(
            mode: .enabled,
            config: TelemetryConfig(
                openTelemetryEnabled: false,
                openTelemetryEndpoint: "https://otel.product.example/v1/traces"
            ),
            transport: MockHTTPTransport()
        )
        #expect(try off.makeProductOTLPRequest(name: "x", attributes: [:]) == nil)
    }

    @Test func protobufIsNotJSONBytes() throws {
        let body = try OTLPWire.encodeSpanEnvelope(
            name: "collector_golden",
            attributes: [
                "http.request.method": .string("GET"),
                "retry": .bool(false),
                "count": .number(.int64(2)),
            ]
        )
        #expect(OTLPWire.looksLikeExportTraceProtobuf(body))
        #expect(body.first == 0x0A)
        // JSON twin remains available for diagnostics but is never the wire body.
        let json = try OTLPWire.encodeSpanJSONEnvelope(
            name: "collector_golden",
            attributes: ["http.request.method": .string("GET")]
        )
        #expect(json.first == UInt8(ascii: "{"))
        #expect(body != json)
    }

    /// Golden fixture bytes must match a fixed-timestamp re-encode and decode
    /// as ExportTraceServiceRequest (semantic, not digest-only validation).
    @Test func goldenOTLPFixturesMatchEncoder() throws {
        let fixturesRoot = packageRootURL()
            .appendingPathComponent("ProtocolFixtures", isDirectory: true)
        let httpURL = fixturesRoot.appendingPathComponent("otlp-export-trace-http.pb")
        let grpcURL = fixturesRoot.appendingPathComponent("otlp-export-trace-grpc.bin")
        let httpGolden = try Data(contentsOf: httpURL)
        let grpcGolden = try Data(contentsOf: grpcURL)
        let attrs: [String: JSONValue] = [
            "http.request.method": .string("GET"),
            "provider": .string("xai"),
        ]
        let fixedNanos: UInt64 = 1_700_000_000_000_000_000
        let encoded = try OTLPWire.encodeSpanEnvelope(
            name: "collector_golden",
            attributes: attrs,
            nowNanos: fixedNanos
        )
        #expect(encoded == httpGolden)
        #expect(OTLPWire.looksLikeExportTraceProtobuf(httpGolden))
        #expect(OTLPWire.protobufContainsUTF8(httpGolden, "collector_golden"))
        let framed = OTLPWire.frameGRPC(payload: encoded)
        #expect(framed == grpcGolden)
        #expect(OTLPWire.unframeGRPC(grpcGolden) == httpGolden)
    }

    private func packageRootURL() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            let pkg = url.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: pkg.path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
}

@Suite("Process telemetry registry")
struct TelemetryRegistryTests {
    @Test func initAndReset() async {
        Telemetry.resetForTests()
        #expect(!Telemetry.isEnabled())
        let product = RecordingExportSink()
        let client = TelemetryClient(
            mode: .enabled,
            config: TelemetryConfig(
                eventsURL: "https://example.test/e",
                eventsAPIKey: "k"
            ),
            productExport: product
        )
        Telemetry.initClient(client)
        #expect(Telemetry.isEnabled())
        await Telemetry.track(eventName: "x", requestID: "r")
        #expect(product.totalBytes > 0)
        Telemetry.resetForTests()
        #expect(!Telemetry.isEnabled())
    }
}
