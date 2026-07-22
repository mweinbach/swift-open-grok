// OpenGrokTelemetry.swift
//
// Open Grok — Swift port of `xai-grok-telemetry` + `xai-mixpanel`.
//
// Product events, Mixpanel-compatible track/engage, and OpenTelemetry export
// policy. Each export path is independently disableable. Provider/export
// isolation is enforced *before* serialization so disabled or vetoed events
// emit no bytes. Secrets and user paths are scrubbed by default.

import Foundation
import Dispatch
import OpenGrokHTTP
import OpenGrokShared
import OpenGrokTracing
import OpenGrokVersion


/// Portable lock over mutable state. Sync `withLock` is safe to call from async.
final class LockHolder<State>: @unchecked Sendable {
    private let lock = NSLock()
    private var state: State
    init(_ state: State) { self.state = state }
    @discardableResult
    func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }
}

// MARK: - Mode

/// Telemetry mode: disabled, session-metrics only, or full product telemetry.
public enum TelemetryMode: Sendable, Equatable, Hashable, CustomStringConvertible {
    case disabled
    case sessionMetrics
    case enabled

    public var isDisabled: Bool { self == .disabled }
    public var isEnabled: Bool { self == .enabled }
    public var sessionMetricsEnabled: Bool {
        self == .sessionMetrics || self == .enabled
    }

    public var description: String {
        switch self {
        case .disabled: return "false"
        case .sessionMetrics: return "session_metrics"
        case .enabled: return "true"
        }
    }

    public static func parse(_ raw: String) -> TelemetryMode? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on", "enabled", "full":
            return .enabled
        case "0", "false", "no", "off", "disabled":
            return .disabled
        case "session-metrics", "session_metrics":
            return .sessionMetrics
        default:
            return nil
        }
    }

    public init(bool: Bool) {
        self = bool ? .enabled : .disabled
    }
}

// MARK: - Config

public struct TelemetryConfig: Sendable, Equatable {
    public var eventsURL: String?
    public var eventsAPIKey: String?
    public var mixpanelEnabled: Bool
    public var mixpanelToken: String?
    public var openTelemetryEnabled: Bool
    public var openTelemetryEndpoint: String?
    public var productTelemetryEnabled: Bool

    public init(
        eventsURL: String? = nil,
        eventsAPIKey: String? = nil,
        mixpanelEnabled: Bool = false,
        mixpanelToken: String? = nil,
        openTelemetryEnabled: Bool = false,
        openTelemetryEndpoint: String? = nil,
        productTelemetryEnabled: Bool = true
    ) {
        self.eventsURL = eventsURL
        self.eventsAPIKey = eventsAPIKey
        self.mixpanelEnabled = mixpanelEnabled
        self.mixpanelToken = mixpanelToken
        self.openTelemetryEnabled = openTelemetryEnabled
        self.openTelemetryEndpoint = openTelemetryEndpoint
        self.productTelemetryEnabled = productTelemetryEnabled
    }
}

// MARK: - Redaction (shared with tracing)

public enum TelemetryRedaction {
    public static func redactString(_ input: String) -> String {
        TraceRedaction.redactString(input)
    }

    public static func redactJSONValue(_ value: JSONValue) -> JSONValue {
        switch value {
        case .null, .bool, .number:
            return value
        case .string(let s):
            return .string(redactString(s))
        case .array(let items):
            return .array(items.map(redactJSONValue))
        case .object(let obj):
            var out: [String: JSONValue] = [:]
            for (k, v) in obj {
                if TraceRedaction.denylistedKeys.contains(TraceRedaction.normalizeKey(k)) {
                    out[k] = .string("<redacted>")
                } else {
                    out[k] = redactJSONValue(v)
                }
            }
            return .object(out)
        }
    }

    public static func urlOrigin(_ value: String) -> String {
        TraceRedaction.urlOrigin(value)
    }
}

// MARK: - Export sink (byte accounting for privacy tests)

/// Captures serialized export attempts for golden privacy tests.
public final class RecordingExportSink: @unchecked Sendable {
    private struct State {
        var payloads: [Data]
        var allowed: Bool
    }

    private let state: LockHolder<State>

    public init(allowed: Bool = true) {
        self.state = LockHolder(State(payloads: [], allowed: allowed))
    }

    /// Provider/export isolation veto — when false, emit must not serialize.
    public var allowed: Bool {
        get { state.withLock { $0.allowed } }
        set { state.withLock { $0.allowed = newValue } }
    }

    public var payloads: [Data] {
        state.withLock { $0.payloads }
    }

    public var totalBytes: Int {
        payloads.reduce(0) { $0 + $1.count }
    }

    public func reset() {
        state.withLock { $0.payloads.removeAll() }
    }

    /// Attempt to export. Returns `false` when vetoed **before** serialization
    /// so the caller never builds payload bytes into this sink.
    public func exportIfAllowed(_ build: () throws -> Data) rethrows -> Bool {
        let ok = state.withLock { $0.allowed }
        guard ok else { return false }
        let data = try build()
        return state.withLock { s in
            // Re-check after build for race safety; if disabled mid-flight, drop.
            guard s.allowed else { return false }
            s.payloads.append(data)
            return true
        }
    }
}

// MARK: - Mixpanel-compatible client

/// Lightweight Mixpanel-compatible track/engage client.
///
/// Scrub-then-inject ordering: string properties are redacted *before* the
/// project token is inserted so the token is never scrubbed.
public struct MixpanelClient: Sendable {
    public var token: String
    public var trackURL: URL
    public var engageURL: URL
    public var transport: any HTTPTransport
    /// Optional export gate; when false, track/engage emit zero bytes.
    public var exportAllowed: @Sendable () -> Bool

    public init(
        token: String,
        transport: any HTTPTransport = SharedHTTP.sharedTransport(),
        trackURL: URL = URL(string: "https://api.mixpanel.com/track")!,
        engageURL: URL = URL(string: "https://api.mixpanel.com/engage")!,
        exportAllowed: @escaping @Sendable () -> Bool = { true }
    ) {
        self.token = token
        self.transport = transport
        self.trackURL = trackURL
        self.engageURL = engageURL
        self.exportAllowed = exportAllowed
    }

    /// Scrub property string values, then inject the project token.
    public func prepareProperties(
        _ properties: [String: JSONValue]
    ) -> [String: JSONValue] {
        var props: [String: JSONValue] = [:]
        for (k, v) in properties {
            props[k] = TelemetryRedaction.redactJSONValue(v)
        }
        props["token"] = .string(token)
        return props
    }

    public func track(
        event: String,
        properties: [String: JSONValue] = [:],
        recording: RecordingExportSink? = nil
    ) async throws {
        guard exportAllowed() else { return }

        let build: () throws -> Data = {
            let props = self.prepareProperties(properties)
            let payload: JSONValue = .array([
                .object([
                    "event": .string(event),
                    "properties": .object(props),
                ])
            ])
            return try encodeJSON(payload)
        }

        if let recording {
            let allowed = try recording.exportIfAllowed(build)
            if !allowed { return }
            // Privacy tests use recording sinks without requiring network.
            return
        }

        let jsonBytes = try build()
        let encoded = jsonBytes.base64EncodedString()
        let body = formURLEncoded(["data": encoded])
        _ = try await transport.send(
            HTTPRequest(
                method: .post,
                url: trackURL,
                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                body: body,
                idempotency: .idempotent
            )
        )
    }

    public func engage(
        distinctID: String,
        set: [String: JSONValue],
        recording: RecordingExportSink? = nil
    ) async throws {
        guard exportAllowed() else { return }

        let build: () throws -> Data = {
            var scrubbed: [String: JSONValue] = [:]
            for (k, v) in set {
                scrubbed[k] = TelemetryRedaction.redactJSONValue(v)
            }
            let payload: JSONValue = .array([
                .object([
                    "$token": .string(self.token),
                    "$distinct_id": .string(distinctID),
                    "$set": .object(scrubbed),
                ])
            ])
            return try encodeJSON(payload)
        }

        if let recording {
            _ = try recording.exportIfAllowed(build)
            return
        }

        let jsonBytes = try build()
        let encoded = jsonBytes.base64EncodedString()
        let body = formURLEncoded(["data": encoded])
        _ = try await transport.send(
            HTTPRequest(
                method: .post,
                url: engageURL,
                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                body: body,
                idempotency: .idempotent
            )
        )
    }
}

private func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
    try WireJSONEncoder.make().encode(value)
}

private func formURLEncoded(_ fields: [String: String]) -> Data {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    let parts = fields.map { key, value in
        let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
        let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return "\(k)=\(v)"
    }
    return Data(parts.joined(separator: "&").utf8)
}

// MARK: - Product event client

public typealias TelemetryMetadata = [String: JSONValue]

public struct TelemetryUserContext: Sendable, Equatable {
    public var country: String
    public var language: String
    public var timestamp: String

    public init(
        country: String = "ZZ",
        language: String = "en",
        timestamp: String = ISO8601DateFormatter().string(from: Date())
    ) {
        self.country = country
        self.language = language
        self.timestamp = timestamp
    }
}

public struct TelemetryClient: Sendable {
    public var mode: TelemetryMode
    public var config: TelemetryConfig
    public var userID: String?
    public var teamID: String?
    public var shellVersion: String
    public var originClient: OriginClientInfo?
    public var transport: any HTTPTransport
    public var mixpanel: MixpanelClient?
    public var productExport: RecordingExportSink?
    public var otelExport: RecordingExportSink?
    public var mixpanelExport: RecordingExportSink?
    /// Optional external OTLP exporter (customer collector). Independent of
    /// product/Mixpanel mode; requires double opt-in at construction.
    public var externalOTLP: OTLPExporter?

    public init(
        mode: TelemetryMode,
        config: TelemetryConfig,
        userID: String? = nil,
        teamID: String? = nil,
        shellVersion: String = OpenGrokVersion.installed(),
        originClient: OriginClientInfo? = nil,
        transport: any HTTPTransport = SharedHTTP.sharedTransport(),
        productExport: RecordingExportSink? = nil,
        otelExport: RecordingExportSink? = nil,
        mixpanelExport: RecordingExportSink? = nil,
        externalOTLP: OTLPExporter? = nil
    ) {
        self.mode = mode
        self.config = config
        self.userID = userID
        self.teamID = teamID
        self.shellVersion = shellVersion
        self.originClient = originClient
        self.transport = transport
        self.productExport = productExport
        self.otelExport = otelExport
        self.mixpanelExport = mixpanelExport
        self.externalOTLP = externalOTLP

        if config.mixpanelEnabled, let token = config.mixpanelToken, !token.isEmpty {
            let sink = mixpanelExport
            self.mixpanel = MixpanelClient(
                token: token,
                transport: transport,
                exportAllowed: {
                    // Independently disableable: mode + config + sink veto.
                    guard mode.isEnabled else { return false }
                    guard config.mixpanelEnabled else { return false }
                    if let sink { return sink.allowed }
                    return true
                }
            )
        } else {
            self.mixpanel = nil
        }
    }

    public var isProductEnabled: Bool {
        mode.isEnabled && config.productTelemetryEnabled
    }

    public var isSessionMetricsEnabled: Bool {
        mode.sessionMetricsEnabled
    }

    public var isOpenTelemetryEnabled: Bool {
        config.openTelemetryEnabled && (otelExport?.allowed ?? true)
    }

    public var isMixpanelEnabled: Bool {
        mode.isEnabled && config.mixpanelEnabled && mixpanel != nil
            && (mixpanelExport?.allowed ?? true)
    }

    /// Emit a product event. Disabled/vetoed paths emit **no bytes**.
    public func track(
        eventName: String,
        requestID: String,
        context: TelemetryUserContext = TelemetryUserContext(),
        metadata: TelemetryMetadata = [:]
    ) async {
        // Gate before any serialization.
        guard isProductEnabled else { return }
        if let sink = productExport, !sink.allowed { return }

        var meta = metadata
        for (k, v) in meta {
            meta[k] = TelemetryRedaction.redactJSONValue(v)
        }
        meta["shell_version"] = .string(shellVersion)
        if let teamID {
            meta["team_id"] = .string(teamID)
        }
        if let origin = originClient {
            meta["client_type"] = .string(origin.product)
            if let version = origin.version {
                meta["client_version"] = .string(version)
            }
        }

        let user = userID ?? "anonymous"
        let body: JSONValue = .object([
            "viewer_context": .object([
                "request_id": .string(requestID),
                "user_attributes": .object([
                    "user_id": .string(user),
                    "user_type": .string("LoggedIn"),
                    "country": .string(context.country),
                    "language": .string(context.language),
                ]),
                "device_attributes": .object([
                    "app_name": .string("Open Grok"),
                ]),
            ]),
            "api_key": .string(config.eventsAPIKey ?? ""),
            "events": .array([
                .object([
                    "event_name": .string(eventName),
                    "event_value": .string(eventName),
                    "event_metadata": .object(meta),
                    "timestamp": .string(context.timestamp),
                ])
            ]),
        ])

        if let sink = productExport {
            _ = try? sink.exportIfAllowed {
                try encodeJSON(body)
            }
            return
        }

        guard let urlString = config.eventsURL,
              let url = URL(string: urlString),
              let apiKey = config.eventsAPIKey
        else { return }

        guard let data = try? encodeJSON(body) else { return }
        var headers = [
            "Content-Type": "application/json",
            "x-api-key": apiKey,
        ]
        // Redact for any local span; never put the key into tracing attributes.
        _ = TraceRedaction.redactHeaders(headers)
        headers["x-api-key"] = apiKey

        _ = try? await transport.send(
            HTTPRequest(
                method: .post,
                url: url,
                headers: headers,
                body: data,
                timeout: TimeInterval(10),
                idempotency: .idempotent
            )
        )
    }

    /// Emit a Mixpanel-compatible event when enabled.
    public func trackMixpanel(
        event: String,
        properties: [String: JSONValue] = [:]
    ) async {
        guard isMixpanelEnabled, let mixpanel else { return }
        try? await mixpanel.track(
            event: event,
            properties: properties,
            recording: mixpanelExport
        )
    }

    /// Export an OpenTelemetry span when product OTEL is enabled **or** when a
    /// resolved external OTLP exporter is attached.
    ///
    /// Privacy gates and provider isolation apply *before* serialization so
    /// disabled/vetoed events emit zero bytes.
    public func exportOpenTelemetry(
        name: String,
        attributes: [String: JSONValue] = [:],
        provider: String? = nil
    ) {
        // Independent gates: product OTEL config and/or external exporter.
        let productOTEL = isOpenTelemetryEnabled
        let external = externalOTLP
        let externalActive = external?.isActive == true
        guard productOTEL || externalActive else { return }

        // Provider isolation veto before any attribute scrubbing or encode.
        if let external, !external.exportPolicy.allows(provider: provider) {
            return
        }
        if let sink = otelExport, !sink.allowed { return }

        var attrs: [String: JSONValue] = [:]
        for (k, v) in attributes {
            if TraceRedaction.denylistedKeys.contains(TraceRedaction.normalizeKey(k)) {
                continue
            }
            attrs[k] = TelemetryRedaction.redactJSONValue(v)
        }
        if let provider {
            attrs["provider"] = .string(provider)
        }

        let build: () throws -> Data = {
            try OTLPWire.encodeSpanEnvelope(name: name, attributes: attrs)
        }

        if let sink = otelExport {
            _ = try? sink.exportIfAllowed(build)
            // Recording path is hermetic; still exercise external wire builder
            // only when no sink vetoed.
            return
        }

        if let external, externalActive {
            // Network export uses the external collector seam only — never
            // shares headers with the product events pipeline.
            try? external.exportSpan(name: name, attributes: attrs, provider: provider)
            return
        }

        // Product OTEL endpoint (config.openTelemetryEndpoint) when enabled.
        guard productOTEL,
              let request = try? makeProductOTLPRequest(
                  name: name,
                  attributes: attrs
              )
        else {
            return
        }
        // Fire-and-forget best effort; failures must not affect the session.
        let transport = self.transport
        Task {
            _ = try? await transport.send(request)
        }
    }

    /// Build the product OTLP HTTP request for `config.openTelemetryEndpoint`
    /// without sending (test seam + shared construction).
    public func makeProductOTLPRequest(
        name: String,
        attributes: [String: JSONValue]
    ) throws -> HTTPRequest? {
        guard isOpenTelemetryEnabled,
              let endpoint = config.openTelemetryEndpoint,
              let url = URL(string: endpoint)
        else {
            return nil
        }
        // Product OTEL uses the same OTLP HTTP/protobuf body as external export
        // so collectors never receive JSON labeled as protobuf.
        let body = try OTLPWire.encodeSpanEnvelope(name: name, attributes: attributes)
        return HTTPRequest(
            method: .post,
            url: url,
            headers: [
                "Content-Type": OTLPWire.httpProtobufContentType,
            ],
            body: body,
            timeout: TimeInterval(10),
            idempotency: .idempotent
        )
    }
}

// MARK: - Process-wide client

public enum Telemetry {
    private static let state = LockHolder<TelemetryClient?>(nil)

    public static func initClient(_ newClient: TelemetryClient?) {
        state.withLock { $0 = newClient }
    }

    public static func current() -> TelemetryClient? {
        state.withLock { $0 }
    }

    public static func isEnabled() -> Bool {
        current()?.isProductEnabled ?? false
    }

    public static func isSessionMetricsEnabled() -> Bool {
        current()?.isSessionMetricsEnabled ?? false
    }

    public static func resetForTests() {
        state.withLock { $0 = nil }
    }

    public static func track(
        eventName: String,
        requestID: String,
        context: TelemetryUserContext = TelemetryUserContext(),
        metadata: TelemetryMetadata = [:]
    ) async {
        guard let client = current() else { return }
        await client.track(
            eventName: eventName,
            requestID: requestID,
            context: context,
            metadata: metadata
        )
    }
}

// MARK: - External OTEL / OTLP (double opt-in, isolation)

/// OTLP transport/protocol for external exporters.
public enum OtlpTransport: String, Sendable, Equatable, Hashable {
    /// OTLP over HTTP with protobuf bodies (default).
    case httpProtobuf = "http/protobuf"
    /// OTLP over gRPC/protobuf.
    case grpc = "grpc"

    public static func parse(_ raw: String) -> OtlpTransport? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "http/protobuf", "http-protobuf", "http", "":
            return .httpProtobuf
        case "grpc":
            return .grpc
        default:
            return nil
        }
    }
}

/// Exporter selection for one signal (`OTEL_METRICS_EXPORTER` / `OTEL_LOGS_EXPORTER`
/// / span export gate).
public enum ExporterSelection: String, Sendable, Equatable, Hashable {
    case none
    case otlp
    case console

    public static func parse(_ raw: String) -> ExporterSelection? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "otlp": return .otlp
        case "console": return .console
        case "none", "": return .none
        default: return nil
        }
    }

    public var isActive: Bool { self != .none }
}

/// Content gates (additive opt-ins; default off).
public struct OTELContentGates: Sendable, Equatable {
    public var logUserPrompts: Bool
    public var logToolDetails: Bool

    public init(logUserPrompts: Bool = false, logToolDetails: Bool = false) {
        self.logUserPrompts = logUserPrompts
        self.logToolDetails = logToolDetails
    }
}

/// Provider-aware pre-serialization export policy.
///
/// Isolation is enforced before any OTLP bytes are built. Disallowed providers
/// produce zero serialized bytes (golden privacy invariant).
public struct OTELExportPolicy: Sendable, Equatable {
    /// When non-empty, only these provider identifiers may export.
    public var allowedProviders: Set<String>
    /// Providers that are always vetoed.
    public var deniedProviders: Set<String>
    /// Hard disable (fleet kill switch).
    public var forceDisable: Bool

    public init(
        allowedProviders: Set<String> = [],
        deniedProviders: Set<String> = [],
        forceDisable: Bool = false
    ) {
        self.allowedProviders = allowedProviders
        self.deniedProviders = deniedProviders
        self.forceDisable = forceDisable
    }

    public func allows(provider: String?) -> Bool {
        if forceDisable { return false }
        if let provider {
            let key = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if deniedProviders.contains(key) { return false }
            if !allowedProviders.isEmpty && !allowedProviders.contains(key) {
                return false
            }
        } else if !allowedProviders.isEmpty {
            // Provider-required policy when allow-list is set.
            return false
        }
        return true
    }
}

/// Fully resolved external OTEL configuration.
///
/// Constructed only when the double opt-in is satisfied: master switch *and*
/// at least one active exporter selection. Default is off — zero sockets.
public struct ExternalOtelConfig: Sendable, Equatable {
    public var metricsExporter: ExporterSelection
    public var logsExporter: ExporterSelection
    public var spansExporter: ExporterSelection
    public var transport: OtlpTransport
    public var logsEndpoint: String
    public var metricsEndpoint: String
    public var spansEndpoint: String
    /// Customer collector headers for log exports only (ordered pairs).
    public var logsHeaders: [OTLPHeader]
    /// Customer collector headers for metric exports only.
    public var metricsHeaders: [OTLPHeader]
    /// Customer collector headers for span exports only.
    public var spansHeaders: [OTLPHeader]
    public var timeout: TimeInterval
    public var gates: OTELContentGates
    public var exportPolicy: OTELExportPolicy
    public var enabledSource: String

    public init(
        metricsExporter: ExporterSelection,
        logsExporter: ExporterSelection,
        spansExporter: ExporterSelection = .none,
        transport: OtlpTransport,
        logsEndpoint: String,
        metricsEndpoint: String,
        spansEndpoint: String,
        logsHeaders: [OTLPHeader] = [],
        metricsHeaders: [OTLPHeader] = [],
        spansHeaders: [OTLPHeader] = [],
        timeout: TimeInterval = 10,
        gates: OTELContentGates = OTELContentGates(),
        exportPolicy: OTELExportPolicy = OTELExportPolicy(),
        enabledSource: String = "env"
    ) {
        self.metricsExporter = metricsExporter
        self.logsExporter = logsExporter
        self.spansExporter = spansExporter
        self.transport = transport
        self.logsEndpoint = logsEndpoint
        self.metricsEndpoint = metricsEndpoint
        self.spansEndpoint = spansEndpoint
        self.logsHeaders = logsHeaders
        self.metricsHeaders = metricsHeaders
        self.spansHeaders = spansHeaders
        self.timeout = timeout
        self.gates = gates
        self.exportPolicy = exportPolicy
        self.enabledSource = enabledSource
    }

    public var isActive: Bool {
        metricsExporter.isActive || logsExporter.isActive || spansExporter.isActive
    }

    /// Headers for a signal — never includes internal product auth headers.
    public func headers(for signal: OTLPSignal) -> [OTLPHeader] {
        switch signal {
        case .logs: return logsHeaders
        case .metrics: return metricsHeaders
        case .spans: return spansHeaders
        }
    }

    public func endpoint(for signal: OTLPSignal) -> String {
        switch signal {
        case .logs: return logsEndpoint
        case .metrics: return metricsEndpoint
        case .spans: return spansEndpoint
        }
    }
}

/// One customer-collector header pair (env-only; never from disk config).
public struct OTLPHeader: Sendable, Equatable, Hashable {
    public var name: String
    public var value: String
    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public enum OTLPSignal: String, Sendable, Equatable, Hashable {
    case logs
    case metrics
    case spans
}

/// Parse `k=v,k2=v2` header lists (OTLP env spec); blank keys skipped.
public func parseOTLPHeaderList(_ raw: String) -> [OTLPHeader] {
    raw.split(separator: ",").compactMap { pair in
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let k = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let v = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return nil }
        // Isolation: refuse internal product auth header names on external path.
        let nk = k.lowercased()
        if nk == "authorization" || nk == "x-xai-token-auth" || nk == "x-api-key"
            || nk == "x-userid" || nk == "proxy-authorization"
        {
            return nil
        }
        return OTLPHeader(name: k, value: v)
    }
}

/// Independent external OTEL stream policy (customer collector).
///
/// Default off. Requires double opt-in (master switch + exporter selection).
/// Never shares auth headers with the internal product pipeline.
public struct ExternalOTELPolicy: Sendable, Equatable {
    public var enabled: Bool
    public var endpoint: String?
    public var logUserPrompts: Bool
    public var logToolDetails: Bool
    public var transport: OtlpTransport
    public var logsExporter: ExporterSelection
    public var metricsExporter: ExporterSelection
    public var spansExporter: ExporterSelection

    public init(
        enabled: Bool = false,
        endpoint: String? = nil,
        logUserPrompts: Bool = false,
        logToolDetails: Bool = false,
        transport: OtlpTransport = .httpProtobuf,
        logsExporter: ExporterSelection = .none,
        metricsExporter: ExporterSelection = .none,
        spansExporter: ExporterSelection = .none
    ) {
        self.enabled = enabled
        self.endpoint = endpoint
        self.logUserPrompts = logUserPrompts
        self.logToolDetails = logToolDetails
        self.transport = transport
        self.logsExporter = logsExporter
        self.metricsExporter = metricsExporter
        self.spansExporter = spansExporter
    }

    /// Resolve lightweight policy view. Prefer ``ExternalOtelConfig/resolve(environment:)``
    /// for full double-opt-in config.
    public static func fromEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ExternalOTELPolicy {
        guard let cfg = ExternalOtelConfig.resolve(environment: environment) else {
            return ExternalOTELPolicy(enabled: false)
        }
        return ExternalOTELPolicy(
            enabled: true,
            endpoint: cfg.spansEndpoint,
            logUserPrompts: cfg.gates.logUserPrompts,
            logToolDetails: cfg.gates.logToolDetails,
            transport: cfg.transport,
            logsExporter: cfg.logsExporter,
            metricsExporter: cfg.metricsExporter,
            spansExporter: cfg.spansExporter
        )
    }
}

extension ExternalOtelConfig {
    private static let defaultHTTPBase = "http://localhost:4318"
    private static let defaultGRPCBase = "http://localhost:4317"

    /// Resolve from environment. Returns `nil` unless double opt-in is met.
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ExternalOtelConfig? {
        resolve(getenv: { environment[$0] })
    }

    /// Testable resolution core.
    public static func resolve(
        getenv: (String) -> String?
    ) -> ExternalOtelConfig? {
        let masterRaw = getenv("OPENGROK_EXTERNAL_OTEL") ?? getenv("GROK_EXTERNAL_OTEL")
        let enabled = masterRaw.map {
            ["1", "true", "yes", "on"].contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        } ?? false
        guard enabled else { return nil }

        func select(_ name: String) -> ExporterSelection {
            guard let raw = getenv(name) else { return .none }
            return ExporterSelection.parse(raw) ?? .none
        }
        let metricsExporter = select("OTEL_METRICS_EXPORTER")
        let logsExporter = select("OTEL_LOGS_EXPORTER")
        // Spans: OTEL_TRACES_EXPORTER or fall back to logs exporter for parity.
        let spansExporter: ExporterSelection = {
            if let raw = getenv("OTEL_TRACES_EXPORTER") {
                return ExporterSelection.parse(raw) ?? .none
            }
            // Convenience: when logs are OTLP and traces unset, enable spans OTLP.
            return logsExporter == .otlp ? .otlp : .none
        }()

        // Double opt-in: master switch alone enables nothing.
        if !metricsExporter.isActive && !logsExporter.isActive && !spansExporter.isActive {
            return nil
        }

        let transport: OtlpTransport
        if let raw = getenv("OTEL_EXPORTER_OTLP_PROTOCOL") {
            guard let parsed = OtlpTransport.parse(raw) else { return nil }
            transport = parsed
        } else {
            transport = .httpProtobuf
        }

        let base = getenv("OTEL_EXPORTER_OTLP_ENDPOINT")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let logsEndpoint = resolveSignalEndpoint(
            specific: getenv("OTEL_EXPORTER_OTLP_LOGS_ENDPOINT"),
            base: base,
            path: "v1/logs",
            transport: transport
        )
        let metricsEndpoint = resolveSignalEndpoint(
            specific: getenv("OTEL_EXPORTER_OTLP_METRICS_ENDPOINT"),
            base: base,
            path: "v1/metrics",
            transport: transport
        )
        let spansEndpoint = resolveSignalEndpoint(
            specific: getenv("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"),
            base: base,
            path: "v1/traces",
            transport: transport
        )

        let baseHeaders = parseOTLPHeaderList(getenv("OTEL_EXPORTER_OTLP_HEADERS") ?? "")
        func signalHeaders(_ name: String) -> [OTLPHeader] {
            var headers = baseHeaders
            let extra = parseOTLPHeaderList(getenv(name) ?? "")
            for h in extra {
                if let idx = headers.firstIndex(where: { $0.name == h.name }) {
                    headers[idx] = h
                } else {
                    headers.append(h)
                }
            }
            return headers
        }

        let timeoutMs = getenv("OTEL_EXPORTER_OTLP_TIMEOUT")
            .flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            ?? 10_000
        let gates = OTELContentGates(
            logUserPrompts: envBool(getenv("OTEL_LOG_USER_PROMPTS")) ?? false,
            logToolDetails: envBool(getenv("OTEL_LOG_TOOL_DETAILS")) ?? false
        )

        // Optional provider allow/deny lists (OpenGrok extension for isolation).
        let allowed = Set(
            (getenv("OPENGROK_OTEL_ALLOWED_PROVIDERS") ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        let denied = Set(
            (getenv("OPENGROK_OTEL_DENIED_PROVIDERS") ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )

        return ExternalOtelConfig(
            metricsExporter: metricsExporter,
            logsExporter: logsExporter,
            spansExporter: spansExporter,
            transport: transport,
            logsEndpoint: logsEndpoint,
            metricsEndpoint: metricsEndpoint,
            spansEndpoint: spansEndpoint,
            logsHeaders: signalHeaders("OTEL_EXPORTER_OTLP_LOGS_HEADERS"),
            metricsHeaders: signalHeaders("OTEL_EXPORTER_OTLP_METRICS_HEADERS"),
            spansHeaders: signalHeaders("OTEL_EXPORTER_OTLP_TRACES_HEADERS"),
            timeout: timeoutMs / 1000.0,
            gates: gates,
            exportPolicy: OTELExportPolicy(
                allowedProviders: allowed,
                deniedProviders: denied
            ),
            enabledSource: "env"
        )
    }

    private static func envBool(_ raw: String?) -> Bool? {
        guard let raw else { return nil }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off", "": return false
        default: return nil
        }
    }

    private static func resolveSignalEndpoint(
        specific: String?,
        base: String?,
        path: String,
        transport: OtlpTransport
    ) -> String {
        if let full = specific?.trimmingCharacters(in: .whitespacesAndNewlines), !full.isEmpty {
            // Keep full URL; only strip trailing slash.
            return full.hasSuffix("/") ? String(full.dropLast()) : full
        }
        let defaultBase = transport == .grpc ? defaultGRPCBase : defaultHTTPBase
        let trimmedBase = (base?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? defaultBase
        let root = trimmedBase.hasSuffix("/") ? String(trimmedBase.dropLast()) : trimmedBase
        switch transport {
        case .httpProtobuf:
            return "\(root)/\(path)"
        case .grpc:
            return root
        }
    }
}

// MARK: - OTLP wire + exporter seams

/// Pure OTLP wire helpers (HTTP/protobuf and gRPC framing seams).
///
/// Serialization is hermetic and testable without network I/O. Export bodies
/// are real `ExportTraceServiceRequest` protobuf messages (not JSON mislabeled
/// as `application/x-protobuf`). A JSON diagnostic twin remains available for
/// human-readable golden fixtures.
public enum OTLPWire {
    /// Content-Type for OTLP HTTP/protobuf.
    public static let httpProtobufContentType = "application/x-protobuf"
    /// Content-Type for OTLP HTTP/JSON (diagnostic / alternate path).
    public static let httpJSONContentType = "application/json"
    /// gRPC content-type for protobuf payloads.
    public static let grpcContentType = "application/grpc+proto"

    /// Encode a real OTLP `ExportTraceServiceRequest` protobuf body for one span.
    ///
    /// This is the canonical export body for both product and external OTLP
    /// HTTP/protobuf and (pre-framing) gRPC paths.
    public static func encodeSpanEnvelope(
        name: String,
        attributes: [String: JSONValue]
    ) throws -> Data {
        OTLPProtobuf.encodeExportTraceServiceRequest(name: name, attributes: attributes)
    }

    /// Human-readable JSON twin of the span envelope (not used on the wire for
    /// `application/x-protobuf` exports).
    public static func encodeSpanJSONEnvelope(
        name: String,
        attributes: [String: JSONValue]
    ) throws -> Data {
        let envelope: JSONValue = .object([
            "resourceSpans": .array([
                .object([
                    "scopeSpans": .array([
                        .object([
                            "spans": .array([
                                .object([
                                    "name": .string(name),
                                    "attributes": .object(attributes),
                                ])
                            ])
                        ])
                    ])
                ])
            ])
        ])
        return try encodeJSON(envelope)
    }

    /// Length-prefixed gRPC framing over a protobuf payload.
    ///
    /// Format: 1-byte compression flag (0) + 4-byte big-endian length + payload.
    public static func frameGRPC(payload: Data) -> Data {
        var out = Data(capacity: 5 + payload.count)
        out.append(0) // no compression
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    /// Decode the gRPC data frame header; returns nil when the frame is short
    /// or compressed (flag != 0). Used by collector-compatibility tests.
    public static func unframeGRPC(_ framed: Data) -> Data? {
        guard framed.count >= 5, framed[0] == 0 else { return nil }
        let len =
            (UInt32(framed[1]) << 24)
            | (UInt32(framed[2]) << 16)
            | (UInt32(framed[3]) << 8)
            | UInt32(framed[4])
        guard framed.count >= 5 + Int(len) else { return nil }
        return framed.subdata(in: 5..<(5 + Int(len)))
    }

    /// True when `body` is a plausible `ExportTraceServiceRequest` protobuf
    /// (field 1 length-delimited `resource_spans` present, not JSON).
    public static func looksLikeExportTraceProtobuf(_ body: Data) -> Bool {
        OTLPProtobuf.looksLikeExportTraceServiceRequest(body)
    }

    /// HTTP request description for a signal export (no I/O).
    public static func makeExportRequest(
        config: ExternalOtelConfig,
        signal: OTLPSignal,
        body: Data
    ) -> HTTPRequest? {
        let exporter: ExporterSelection
        switch signal {
        case .logs: exporter = config.logsExporter
        case .metrics: exporter = config.metricsExporter
        case .spans: exporter = config.spansExporter
        }
        guard exporter == .otlp else { return nil }
        guard let url = URL(string: config.endpoint(for: signal)) else { return nil }

        var headers: [String: String] = [:]
        switch config.transport {
        case .httpProtobuf:
            headers["Content-Type"] = httpProtobufContentType
        case .grpc:
            headers["Content-Type"] = grpcContentType
            headers["TE"] = "trailers"
        }
        for h in config.headers(for: signal) {
            headers[h.name] = h.value
        }

        let wireBody: Data
        switch config.transport {
        case .httpProtobuf:
            wireBody = body
        case .grpc:
            wireBody = frameGRPC(payload: body)
        }

        return HTTPRequest(
            method: .post,
            url: url,
            headers: headers,
            body: wireBody,
            timeout: config.timeout,
            idempotency: .idempotent
        )
    }
}

/// External OTLP exporter with explicit HTTP/protobuf and gRPC seams.
///
/// Provider isolation and export policy are applied **before** serialization.
/// When vetoed, `exportSpan` returns without producing bytes.
public struct OTLPExporter: Sendable {
    public var config: ExternalOtelConfig
    public var transport: any HTTPTransport
    /// Optional recording sink for golden privacy / wire tests.
    public var recording: RecordingExportSink?
    public var exportPolicy: OTELExportPolicy

    public init(
        config: ExternalOtelConfig,
        transport: any HTTPTransport = SharedHTTP.sharedTransport(),
        recording: RecordingExportSink? = nil,
        exportPolicy: OTELExportPolicy? = nil
    ) {
        self.config = config
        self.transport = transport
        self.recording = recording
        self.exportPolicy = exportPolicy ?? config.exportPolicy
    }

    public var isActive: Bool {
        !exportPolicy.forceDisable && config.isActive
    }

    /// Export a span if policy allows. Returns `false` when vetoed (0 bytes).
    @discardableResult
    public func exportSpan(
        name: String,
        attributes: [String: JSONValue] = [:],
        provider: String? = nil
    ) throws -> Bool {
        guard isActive else { return false }
        guard config.spansExporter == .otlp || config.spansExporter == .console else {
            return false
        }
        // Provider-aware pre-serialization veto.
        guard exportPolicy.allows(provider: provider) else { return false }
        if let recording, !recording.allowed { return false }

        var attrs = attributes
        for (k, v) in attrs {
            if TraceRedaction.denylistedKeys.contains(TraceRedaction.normalizeKey(k)) {
                attrs.removeValue(forKey: k)
                continue
            }
            attrs[k] = TelemetryRedaction.redactJSONValue(v)
        }
        if let provider {
            attrs["provider"] = .string(provider)
        }

        let build: () throws -> Data = {
            try OTLPWire.encodeSpanEnvelope(name: name, attributes: attrs)
        }

        if let recording {
            return try recording.exportIfAllowed(build)
        }

        guard config.spansExporter == .otlp else {
            // Console path: deliberate no-op for headless/agent (parity with Rust).
            return false
        }

        let body = try build()
        guard let request = OTLPWire.makeExportRequest(
            config: config,
            signal: .spans,
            body: body
        ) else {
            return false
        }
        _ = try transport.send(request)
        return true
    }

    /// Build (but do not send) the wire request for collector/mock tests.
    public func makeSpanWireRequest(
        name: String,
        attributes: [String: JSONValue] = [:],
        provider: String? = nil
    ) throws -> (request: HTTPRequest, body: Data)? {
        guard isActive else { return nil }
        guard exportPolicy.allows(provider: provider) else { return nil }
        var attrs = attributes
        for (k, v) in attrs {
            if TraceRedaction.denylistedKeys.contains(TraceRedaction.normalizeKey(k)) {
                attrs.removeValue(forKey: k)
                continue
            }
            attrs[k] = TelemetryRedaction.redactJSONValue(v)
        }
        if let provider {
            attrs["provider"] = .string(provider)
        }
        let body = try OTLPWire.encodeSpanEnvelope(name: name, attributes: attrs)
        guard let request = OTLPWire.makeExportRequest(
            config: config,
            signal: .spans,
            body: body
        ) else {
            return nil
        }
        return (request, body)
    }
}
