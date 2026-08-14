// PreviewScraper.swift
//
// Activity and metrics scrapers for the in-sandbox preview-proxy control endpoints.
// Ported from `xai-grok-workspace-daemon/src/preview_supervisor.rs`.

import Foundation

// MARK: - Constants

/// Default loopback control port for the preview-proxy.
public let DEFAULT_PREVIEW_CONTROL_PORT: UInt16 = 6015

/// Route exposing the last-activity stamp.
public let PREVIEW_ACTIVITY_PATH: String = "/__control/activity"

/// Route exposing the proxy metrics.
public let PREVIEW_METRICS_PATH: String = "/__control/metrics"

/// Prefix for exported proxy metrics.
public let PREVIEW_METRICS_PREFIX: String = "preview_proxy_"

/// Interval for scraping metrics.
public let PREVIEW_METRICS_SCRAPE_INTERVAL: TimeInterval = 60.0

/// Per-scrape budget.
public let PREVIEW_ACTIVITY_SCRAPE_TIMEOUT: TimeInterval = 2.0

// MARK: - Activity Sink Protocol

/// Sink interface for reporting scraped preview-proxy activity.
public protocol PreviewActivitySink: Sendable {
    /// A request was routed through the proxy since the previous scrape.
    func notePreviewRoutedActivity()
    /// The proxy's generic activity stamp advanced without a routed request.
    func notePreviewStatusActivity()
    /// Absolute mirror of the proxy's attached-client counters.
    func setPreviewAttached(wsTunnelsOpen: UInt64, routedInFlight: UInt64)
    /// How long a stamp keeps withholding idle (milliseconds).
    func previewActivityWindowMs() -> UInt64
}

// MARK: - Activity Sample & Classification

/// One scrape sample from the proxy's activity endpoint.
public struct ActivitySample: Codable, Sendable, Equatable {
    public var last_activity_ms: UInt64
    public var last_routed_ms: UInt64
    public var ws_tunnels_open: UInt64
    public var routed_requests_in_flight: UInt64

    public var lastActivityMs: UInt64 { last_activity_ms }
    public var lastRoutedMs: UInt64 { last_routed_ms }
    public var wsTunnelsOpen: UInt64 { ws_tunnels_open }
    public var routedInFlight: UInt64 { routed_requests_in_flight }

    public init(
        last_activity_ms: UInt64,
        last_routed_ms: UInt64 = 0,
        ws_tunnels_open: UInt64 = 0,
        routed_requests_in_flight: UInt64 = 0
    ) {
        self.last_activity_ms = last_activity_ms
        self.last_routed_ms = last_routed_ms
        self.ws_tunnels_open = ws_tunnels_open
        self.routed_requests_in_flight = routed_requests_in_flight
    }

    enum CodingKeys: String, CodingKey {
        case last_activity_ms
        case last_routed_ms
        case ws_tunnels_open
        case routed_requests_in_flight
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.last_activity_ms = try container.decode(UInt64.self, forKey: .last_activity_ms)
        self.last_routed_ms = try container.decodeIfPresent(UInt64.self, forKey: .last_routed_ms) ?? 0
        self.ws_tunnels_open = try container.decodeIfPresent(UInt64.self, forKey: .ws_tunnels_open) ?? 0
        self.routed_requests_in_flight = try container.decodeIfPresent(UInt64.self, forKey: .routed_requests_in_flight) ?? 0
    }
}

/// Classified result of one activity scrape.
public enum ScrapeOutcome: Sendable, Equatable {
    case stamp(ActivitySample)
    case absent
    case badResponse
}

/// Parse an activity body JSON; `nil` for a malformed body or missing/non-integer `last_activity_ms`.
public func parseActivityBody(_ body: String) -> ActivitySample? {
    guard let data = body.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let lastActivity = json["last_activity_ms"] as? NSNumber,
          // NSNumber(value: 0) can look like Bool on Apple platforms.
          // Use CFGetTypeID to distinguish actual JSON booleans from integers.
          CFGetTypeID(lastActivity) != CFBooleanGetTypeID(),
          lastActivity.doubleValue == Double(lastActivity.uint64Value)
    else {
        return nil
    }
    return try? JSONDecoder().decode(ActivitySample.self, from: data)
}

/// Classify a completed response by status and body.
public func classifyActivityResponse(status: Int, body: String) -> ScrapeOutcome {
    guard (200..<300).contains(status) else {
        return .badResponse
    }
    guard let sample = parseActivityBody(body) else {
        return .badResponse
    }
    return .stamp(sample)
}

/// Whether a scraped stamp is strictly newer than the last seen.
public func previewActivityAdvanced(lastSeen: UInt64, current: UInt64) -> Bool {
    current > lastSeen
}

public func activityUrl(controlPort: UInt16) -> URL {
    URL(string: "http://127.0.0.1:\(controlPort)\(PREVIEW_ACTIVITY_PATH)")!
}

public func metricsUrl(controlPort: UInt16) -> URL {
    URL(string: "http://127.0.0.1:\(controlPort)\(PREVIEW_METRICS_PATH)")!
}

// MARK: - Activity Scraper

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil // Do not follow redirects.
    }
}

public func makeScraperSession(timeout: TimeInterval = PREVIEW_ACTIVITY_SCRAPE_TIMEOUT) -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = timeout
    config.timeoutIntervalForResource = timeout
    config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    return URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
}

public func scrapeActivity(session: URLSession, url: URL) async -> ScrapeOutcome {
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = PREVIEW_ACTIVITY_SCRAPE_TIMEOUT

    do {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            return .badResponse
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        return classifyActivityResponse(status: httpResponse.statusCode, body: body)
    } catch {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorCannotConnectToHost,
                 NSURLErrorNotConnectedToInternet,
                 NSURLErrorTimedOut,
                 NSURLErrorNetworkConnectionLost:
                return .absent
            default:
                return .badResponse
            }
        }
        return .badResponse
    }
}

/// Supervise preview activity polling loop until `shutdown` is signaled.
public func supervisePreviewActivity(
    controlPort: UInt16? = nil,
    tracker: any PreviewActivitySink,
    scrapeInterval: TimeInterval,
    shutdown: PreviewSupervisorShutdownToken = PreviewSupervisorShutdownToken()
) async {
    let port = controlPort ?? DEFAULT_PREVIEW_CONTROL_PORT
    await scrapeActivityLoop(
        controlPort: port,
        tracker: tracker,
        interval: scrapeInterval,
        shutdown: shutdown
    )
}

public func scrapeActivityLoop(
    controlPort: UInt16,
    tracker: any PreviewActivitySink,
    interval: TimeInterval,
    shutdown: PreviewSupervisorShutdownToken
) async {
    if shutdown.isShutDown || Task.isCancelled { return }

    let url = activityUrl(controlPort: controlPort)
    let session = makeScraperSession()
    defer { session.invalidateAndCancel() }

    var lastSeen: ActivitySample? = nil
    let attachedGrace = Double(tracker.previewActivityWindowMs()) / 1000.0
    var attachedStaleSince: Date? = nil

    while !shutdown.isShutDown && !Task.isCancelled {
        if await sleepOrShutdown(delay: interval, shutdown: shutdown) {
            return
        }

        let outcome = await scrapeActivity(session: session, url: url)
        switch outcome {
        case .stamp(let current):
            if let prev = lastSeen {
                if previewActivityAdvanced(lastSeen: prev.last_routed_ms, current: current.last_routed_ms) {
                    tracker.notePreviewRoutedActivity()
                } else if previewActivityAdvanced(lastSeen: prev.last_activity_ms, current: current.last_activity_ms) {
                    tracker.notePreviewStatusActivity()
                }
            }
            tracker.setPreviewAttached(
                wsTunnelsOpen: current.ws_tunnels_open,
                routedInFlight: current.routed_requests_in_flight
            )
            lastSeen = current
            attachedStaleSince = nil

        case .absent, .badResponse:
            let since = attachedStaleSince ?? Date()
            if attachedStaleSince == nil {
                attachedStaleSince = since
            }
            if Date().timeIntervalSince(since) >= attachedGrace {
                tracker.setPreviewAttached(wsTunnelsOpen: 0, routedInFlight: 0)
            }
        }
    }
}

// MARK: - Metrics Scraper

/// Supervise preview metrics scraper loop.
public func supervisePreviewMetrics(
    controlPort: UInt16? = nil,
    interval: TimeInterval = PREVIEW_METRICS_SCRAPE_INTERVAL,
    shutdown: PreviewSupervisorShutdownToken = PreviewSupervisorShutdownToken(),
    donate: @Sendable @escaping (String) -> Void
) async {
    let port = controlPort ?? DEFAULT_PREVIEW_CONTROL_PORT
    await scrapeMetricsLoop(
        controlPort: port,
        interval: interval,
        shutdown: shutdown,
        donate: donate
    )
}

public func scrapeMetricsLoop(
    controlPort: UInt16,
    interval: TimeInterval,
    shutdown: PreviewSupervisorShutdownToken,
    donate: @Sendable @escaping (String) -> Void
) async {
    if shutdown.isShutDown || Task.isCancelled { return }

    let url = metricsUrl(controlPort: controlPort)
    let session = makeScraperSession()
    defer { session.invalidateAndCancel() }

    // Scrape-first immediately on start.
    while !shutdown.isShutDown && !Task.isCancelled {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = PREVIEW_ACTIVITY_SCRAPE_TIMEOUT

        if let (data, response) = try? await session.data(for: request),
           let httpResponse = response as? HTTPURLResponse,
           (200..<300).contains(httpResponse.statusCode),
           let body = String(data: data, encoding: .utf8) {
            donate(body)
        }

        if await sleepOrShutdown(delay: interval, shutdown: shutdown) {
            return
        }
    }
}
