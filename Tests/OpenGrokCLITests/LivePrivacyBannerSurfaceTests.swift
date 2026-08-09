// LivePrivacyBannerSurfaceTests.swift
//
// The privacy banner SURFACE through the live seam (AGENTS.md §3, Wave 18
// B9-c3): the real `LiveInteractiveControllerRenderer` over an isolated
// `$OPENGROK_HOME`, a REAL credential seeded through `AuthManager`, the
// rollout forced on the way upstream's e2e forces it
// (`GROK_PRIVACY_NOTICE_ROLLOUT=1`, privacy_banner_e2e.rs:50-55 at pin
// 650c1db7), and clicks delivered as mouse events into the real router.
// Nothing asserts against a hand-built state: every claim is what the
// running renderer painted, published, sent, and stamped on disk.
//
// This surface takes CONSENT clicks (AGENTS.md §5), so the suite pins the
// asymmetry by name: `[Opt in]` acks only after the PUT confirms (a failed
// round trip leaves the banner up AND clickable); `[Opt out]` acks
// immediately and never gates dismissal on the server; a double-click
// issues exactly one request; a capturing overlay (and the welcome hero
// that overpaints this slot) blocks every banner click.

import Foundation
import OpenGrokAuth
import OpenGrokHTTP
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokSamplingTypes
import OpenGrokShellSessionSupport
import OpenGrokTerminalCore
import OpenGrokTestSupport
import Testing
@testable import OpenGrokCLI

// MARK: - Sink (the retention suite's stripper; single-token assertions
// only — the cell differ moves the cursor between runs)

private final class BannerCapturingSink: PagerTerminalSink, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []

    var capabilities: PagerTerminalCapabilities { .standard }

    func write(bytes newBytes: [UInt8]) throws {
        lock.lock(); defer { lock.unlock() }
        bytes.append(contentsOf: newBytes)
    }

    func flush() throws {}

    var strippedText: String {
        lock.lock(); defer { lock.unlock() }
        var output = ""
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x1B else {
                output.unicodeScalars.append(Unicode.Scalar(bytes[index]))
                index += 1
                continue
            }
            index += 1
            guard index < bytes.count else { break }
            switch bytes[index] {
            case UInt8(ascii: "["):
                index += 1
                while index < bytes.count, !(0x40...0x7E).contains(bytes[index]) {
                    index += 1
                }
                index += 1
            case UInt8(ascii: "]"):
                index += 1
                while index < bytes.count {
                    if bytes[index] == 0x07 { index += 1; break }
                    if bytes[index] == 0x1B, index + 1 < bytes.count,
                       bytes[index + 1] == UInt8(ascii: "\\") {
                        index += 2
                        break
                    }
                    index += 1
                }
            default:
                index += 1
            }
        }
        return output
    }
}

// MARK: - Transports

/// Records every request; the FIRST parks until released. This is how both
/// halves of the round-trip asymmetry are produced deterministically: the
/// opt-out's ack must land WHILE the decline is still parked, and the
/// opt-in's second click must be swallowed while the first is out.
private final class RecordingHoldFirstTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var held: CheckedContinuation<HTTPResponse, Error>?
    private var recorded: [HTTPRequest] = []

    var requests: [HTTPRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let ordinal: Int = {
            lock.lock(); defer { lock.unlock() }
            recorded.append(request)
            return recorded.count
        }()
        if ordinal == 1 {
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                held = continuation
                lock.unlock()
            }
        }
        return HTTPResponse(
            metadata: HTTPResponseMetadata(statusCode: 200),
            body: Data("{}".utf8)
        )
    }

    func releaseHeld(status: Int, body: String) {
        lock.lock()
        let continuation = held
        held = nil
        lock.unlock()
        continuation?.resume(returning: HTTPResponse(
            metadata: HTTPResponseMetadata(statusCode: status),
            body: Data(body.utf8)
        ))
    }

    func stream(_ request: HTTPRequest) -> AsyncThrowingStream<HTTPStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: HTTPError.transport(
                TransportFailure(kind: .permanent, detail: "stream unsupported")
            ))
        }
    }
}

/// Records every request to the real listener and answers 200 — the
/// upstream mock server's `/v1/privacy/coding-data-retention` role
/// (mock_server.rs:1080-1096).
private final class BannerRecordingHandler: HttpRequestHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var received: [HttpRequest] = []

    func handle(_ request: HttpRequest) -> HttpResponse {
        lock.lock()
        received.append(request)
        lock.unlock()
        return .json(status: 200, .object([("ok", .bool(true))]))
    }

    var requests: [HttpRequest] {
        lock.lock(); defer { lock.unlock() }
        return received
    }
}

/// Thread-safe capture for the browser seam.
private final class OpenedURLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func append(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        urls.append(url)
    }

    var captured: [URL] {
        lock.lock(); defer { lock.unlock() }
        return urls
    }
}

// MARK: - Fixture

/// The live renderer over an isolated home with the rollout env forced on
/// — the `RetentionFixture` shape plus the banner's seams (announcements
/// composition, browser capture).
private struct BannerFixture {
    let home: URL
    let environment: [String: String]
    let sink: BannerCapturingSink
    let renderer: LiveInteractiveControllerRenderer

    init(
        client: LiveCodingDataRetentionClient? = nil,
        announcements: LiveAnnouncementsComposition? = nil,
        openBrowser: (@Sendable (URL) -> Void)? = nil,
        rolloutEnabled: Bool = true
    ) throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "opengrok-banner-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var env = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "XDG_STATE_HOME": home.appendingPathComponent("state").path,
        ]
        if rolloutEnabled { env["GROK_PRIVACY_NOTICE_ROLLOUT"] = "1" }
        environment = env
        sink = BannerCapturingSink()
        let terminal = OpenGrokLiveTerminal(
            isTTY: { false },
            size: { OpenGrokLiveTerminalSize(width: 120, height: 40) },
            write: { _ in }
        )
        renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: terminal,
            sink: sink,
            workingDirectory: home.path,
            modelName: "test-model",
            sessionID: "privacy-banner-surface",
            openGrokHome: home,
            announcements: announcements,
            codingDataRetention: client,
            paintCadence: PagerMotion.minimumPaintCadence,
            environment: env,
            authServices: LivePagerAuthServices(
                makeTransport: { URLSessionHTTPTransport() },
                codexBrowserLogin: { _, _, _, _ in throw CancellationError() },
                openBrowser: openBrowser
            )
        )
    }

    /// Seed a REAL credential through the same `AuthManager` construction
    /// the renderer's hydration and write both use.
    func seedAuth(_ auth: GrokAuth) async throws {
        try await AuthManager(
            grokHome: home,
            config: GrokComConfig.default(environment: environment),
            environment: environment
        ).update(auth)
    }

    var configPath: URL { home.appendingPathComponent("config.toml") }

    var configText: String {
        (try? String(contentsOf: configPath, encoding: .utf8)) ?? ""
    }

    func dispose() {
        try? FileManager.default.removeItem(at: home)
    }

    /// Start and finish a turn so the welcome hero — which overpaints the
    /// banner slot until the first turn (the recorded B2 deferral of
    /// upstream's welcome-first placement) — leaves the screen.
    func dismissWelcome() async throws {
        try await renderer.render(.turnStarted(OpenGrokPagerRequest(
            prompt: "hello banner",
            mode: .fullScreen
        )))
        try await renderer.render(.turnFinished(OpenGrokPagerRuntimeResult(
            lifecycle: .completed,
            sessionID: nil,
            forwardedEventCount: 0,
            terminalRestored: false
        )))
    }

    func waitForFrame(containing needle: String, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if sink.strippedText.contains(needle) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return sink.strippedText.contains(needle)
    }

    func waitForAckOnDisk(timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if configText.contains("privacy_banner_acked") { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return configText.contains("privacy_banner_acked")
    }
}

/// An opted-out personal xAI OAuth credential — upstream's banner cohort.
private func optedOutXAIAuth(
    teamName: String? = nil,
    teamRole: String? = nil,
    teamBlockedReasons: [String] = []
) -> GrokAuth {
    GrokAuth(
        key: "live-token",
        authMode: .oidc,
        userID: "user-1",
        teamName: teamName,
        teamRole: teamRole,
        teamBlockedReasons: teamBlockedReasons,
        codingDataRetentionOptOut: true,
        oidcIssuer: xaiOAuth2Issuer
    )
}

private func optedInXAIAuth() -> GrokAuth {
    GrokAuth(
        key: "live-token",
        authMode: .oidc,
        userID: "user-1",
        codingDataRetentionOptOut: false,
        oidcIssuer: xaiOAuth2Issuer
    )
}

private func client(
    transport: any HTTPTransport
) -> LiveCodingDataRetentionClient {
    LiveCodingDataRetentionClient(
        transport: transport,
        exportPolicy: .allowed,
        proxyBaseURL: URL(string: "https://proxy.invalid/v1")
    )
}

/// Decode the single-key PUT body.
private func retentionOptOut(in request: HTTPRequest) -> Bool? {
    guard let body = request.body,
          let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    else { return nil }
    return object["codingDataRetentionOptOut"] as? Bool
}

// MARK: - Tests

@Suite("privacy banner live surface", .serialized)
struct LivePrivacyBannerSurfaceTests {
    // MARK: Painted / absent

    @Test("the banner paints for the opted-out cohort and publishes its rects")
    func bannerPaintsForOptedOutCohort() async throws {
        let fixture = try BannerFixture()
        defer { fixture.dispose() }
        try await fixture.seedAuth(optedOutXAIAuth())
        try await fixture.renderer.begin()
        try await fixture.dismissWelcome()

        // Banner copy in the frame bytes (single tokens; "SpaceXAI" is
        // unique to the disclosure) and both button labels.
        #expect(await fixture.waitForFrame(containing: "SpaceXAI"))
        #expect(await fixture.waitForFrame(containing: "[Opt"))
        #expect(await fixture.waitForFrame(containing: "out]"))
        // The frame published the geometry the click router consumes.
        let rects = try #require(await fixture.renderer.lastPrivacyBannerHits)
        #expect(rects.optIn != nil)
        #expect(rects.optOut != nil)
        #expect(rects.terms != nil)
        #expect(rects.policy != nil)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("ZDR, team-non-admin, acked, and opted-in arms all stay dark")
    func gatedArmsStayDark() async throws {
        // Each arm gets its own isolated fixture; the positive control is
        // the painted-banner test above, over the same fixture shape.
        let arms: [(String, GrokAuth, String?)] = [
            ("zdr", optedOutXAIAuth(
                teamName: "acme",
                teamRole: "admin",
                teamBlockedReasons: ["BLOCKED_REASON_NO_LOGS"]
            ), nil),
            ("non-admin", optedOutXAIAuth(teamName: "acme", teamRole: "member"), nil),
            ("opted-in", optedInXAIAuth(), nil),
            ("acked", optedOutXAIAuth(),
             "[privacy]\nprivacy_banner_acked = \"2026-01-01T00:00:00Z\"\n"),
        ]
        for (name, auth, configTOML) in arms {
            let fixture = try BannerFixture()
            defer { fixture.dispose() }
            try await fixture.seedAuth(auth)
            if let configTOML {
                try configTOML.write(
                    to: fixture.configPath, atomically: true, encoding: .utf8
                )
            }
            try await fixture.renderer.begin()
            try await fixture.dismissWelcome()
            #expect(
                await fixture.renderer.lastPrivacyBannerHits == nil,
                "\(name): the banner must not own the slot"
            )
            #expect(
                !fixture.sink.strippedText.contains("SpaceXAI"),
                "\(name): banner copy must not paint"
            )
            try await fixture.renderer.restoreTerminal()
        }
    }

    @Test("a critical announcement evicts the banner from the slot")
    func criticalAnnouncementEvicts() async throws {
        // One critical announcement on the wire, the announcements test's
        // payload shape.
        let payload = try JSONSerialization.data(withJSONObject: [
            "gen": 3,
            "announcements": [[
                "id": "crit-1",
                "severity": "critical",
                "title": "Outage",
                "message": "Do not deploy",
                "dismissible": true,
            ]],
        ])
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-banner-ann-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let announcements = LiveAnnouncementsComposition.live(
            transport: MockHTTPTransport(responses: [
                .init(metadata: HTTPResponseMetadata(statusCode: 200), body: payload)
            ]),
            openGrokHome: home,
            environment: ["HOME": home.path, "OPENGROK_HOME": home.path],
            provider: .xai,
            proxyBaseURL: "https://cli-chat-proxy.example.com/v1"
        )
        let cache = try await announcements.refreshAndWait()
        #expect(cache?.announcements.count == 1, "the critical must reach the cache")

        let fixture = try BannerFixture(announcements: announcements)
        defer { fixture.dispose() }
        try await fixture.seedAuth(optedOutXAIAuth())
        try await fixture.renderer.begin()
        await fixture.renderer.refreshAnnouncementBanner()
        try await fixture.dismissWelcome()

        // The gate itself says show — what hides the banner is ONLY the
        // occupied slot (app_view.rs:4859-4863). Without this pin, a
        // broken gate would pass the eviction assertions below.
        #expect(await fixture.renderer.privacyBanner?.shouldShow() == true)
        #expect(await fixture.waitForFrame(containing: "Outage"))
        // Current-frame semantics only: under B2-W4 the banner LEGITIMATELY
        // paints on the welcome tip slot before the critical arrives
        // (upstream also shows it until its announcements fetch fills), and
        // this sink accumulates bytes — so eviction is pinned on the
        // replace-wholesale rects, never on cumulative absence (the W3
        // ledger note's convention).
        #expect(await fixture.renderer.lastPrivacyBannerHits == nil)
        try await fixture.renderer.restoreTerminal()
    }

    // MARK: [Opt out] — immediate local ack + best-effort decline

    @Test("[Opt out] acks on disk and dismisses BEFORE the decline returns")
    func optOutAcksImmediately() async throws {
        let transport = RecordingHoldFirstTransport()
        let fixture = try BannerFixture(client: client(transport: transport))
        defer { fixture.dispose() }
        try await fixture.seedAuth(optedOutXAIAuth())
        try await fixture.renderer.begin()
        try await fixture.dismissWelcome()

        let rects = try #require(await fixture.renderer.lastPrivacyBannerHits)
        let optOut = try #require(rects.optOut)
        let routing = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: optOut.x + 1, y: optOut.y
        )))
        #expect(routing == .consumed)

        // The decline is parked inside the transport — and the ack has
        // ALREADY landed: dismissal never waits on the server
        // (status.rs:516-520). The banner is gone from the very next
        // frame's geometry.
        let deadline = Date().addingTimeInterval(5)
        while transport.requests.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(transport.requests.count == 1, "the decline must reach the transport")
        #expect(await fixture.waitForAckOnDisk(), "ack stamped while the decline is parked")
        #expect(await fixture.renderer.lastPrivacyBannerHits == nil)
        #expect(await fixture.renderer.privacyBanner?.shouldShow() == false)

        // The decline's envelope: a PUT recording opt-OUT (true), issued
        // despite the idempotent state — bypassing the guard is the point
        // (status.rs:522-525).
        #expect(retentionOptOut(in: transport.requests[0]) == true)

        // Its completion is not a banner concern: released as a success it
        // re-anchors the mirror and nothing re-shows (status.rs:432-435).
        transport.releaseHeld(status: 200, body: "{}")
        let outcome = await fixture.renderer.pendingCodingDataWrite?.value
        #expect(outcome == .saved)
        #expect(await fixture.renderer.lastPrivacyBannerHits == nil)
        try await fixture.renderer.restoreTerminal()
    }

    // MARK: [Opt in] — the flagship: click → real PUT → ack

    @Test("[Opt in] PUTs to the real listener, then acks and dismisses")
    func optInPutsOnRealListenerThenAcks() async throws {
        let handler = BannerRecordingHandler()
        let server = HttpServer(handler: handler, basePath: "")
        try server.start()
        defer { server.stop() }

        let fixture = try BannerFixture(client: LiveCodingDataRetentionClient(
            transport: URLSessionHTTPTransport(),
            exportPolicy: .allowed,
            proxyBaseURL: URL(string: server.baseURL)
        ))
        defer { fixture.dispose() }
        try await fixture.seedAuth(optedOutXAIAuth())
        try await fixture.renderer.begin()
        try await fixture.dismissWelcome()
        #expect(await fixture.waitForFrame(containing: "SpaceXAI"))

        // [Opt in]'s pinned geometry, the rail-test convention (a chrome
        // drift fails this click loudly): 120×40 fullscreen puts the
        // status bar at y=0, its gap at y=1, the banner slot at y=2; the
        // button block is right-aligned 18 columns ([Opt out] + gap +
        // [Opt in]), so [Opt in] spans x=112..119 on the title row y=2.
        let routing = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: 113, y: 2
        )))
        #expect(routing == .consumed)

        let write = try #require(await fixture.renderer.pendingCodingDataWrite)
        #expect(await write.value == .saved)

        // The wire: one PUT with upstream's path and single-key body
        // asking to RETAIN (opt-out false) — the e2e's assertion
        // (privacy_banner_e2e.rs:146-157). Auth header by presence only.
        #expect(handler.requests.count == 1)
        let request = try #require(handler.requests.first)
        #expect(request.method == "PUT")
        #expect(request.pathOnly == "/v1/privacy/coding-data-retention")
        let body = try #require(
            try JSONSerialization.jsonObject(with: request.body) as? [String: Any]
        )
        #expect(body["codingDataRetentionOptOut"] as? Bool == false)
        let authorization = try #require(request.authorization)
        #expect(authorization.hasPrefix("Bearer "))

        // Ack only AFTER the confirmed round trip, then the banner is gone
        // from the next frame's geometry and gate alike.
        #expect(await fixture.waitForAckOnDisk())
        #expect(await fixture.renderer.lastPrivacyBannerHits == nil)
        #expect(await fixture.renderer.privacyBanner?.shouldShow() == false)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("a failed [Opt in] records no ack and leaves the banner clickable")
    func failedOptInLeavesBannerClickable() async throws {
        let transport = MockHTTPTransport(responses: [
            .init(
                metadata: HTTPResponseMetadata(statusCode: 500),
                body: Data(#"{"error":"nope"}"#.utf8)
            ),
            .init(
                metadata: HTTPResponseMetadata(statusCode: 500),
                body: Data(#"{"error":"nope"}"#.utf8)
            ),
        ])
        let fixture = try BannerFixture(client: client(transport: transport))
        defer { fixture.dispose() }
        try await fixture.seedAuth(optedOutXAIAuth())
        try await fixture.renderer.begin()
        try await fixture.dismissWelcome()

        let rects = try #require(await fixture.renderer.lastPrivacyBannerHits)
        let optIn = try #require(rects.optIn)
        let firstClick = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: optIn.x + 1, y: optIn.y
        )))
        #expect(firstClick == .consumed)
        let firstWrite = try #require(await fixture.renderer.pendingCodingDataWrite)
        #expect(await firstWrite.value == .failed)

        // No ack recorded for a change that did not happen (status.rs:
        // 498-500), the rollback re-armed the banner on the next frame,
        // and the error c2 surfaced reached it.
        #expect(!fixture.configText.contains("privacy_banner_acked"))
        #expect(await fixture.waitForFrame(containing: "nope"))
        let rearmed = try #require(await fixture.renderer.lastPrivacyBannerHits)
        let optInAgain = try #require(rearmed.optIn)

        // Inflight was cleared (status.rs:486-487): the second click
        // dispatches a second real request.
        let secondClick = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: optInAgain.x + 1, y: optInAgain.y
        )))
        #expect(secondClick == .consumed)
        let secondWrite = try #require(await fixture.renderer.pendingCodingDataWrite)
        #expect(await secondWrite.value == .failed)
        #expect(transport.recordedRequests.count == 2)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("a double-click on [Opt in] issues exactly one request")
    func doubleClickIssuesOneRequest() async throws {
        let transport = RecordingHoldFirstTransport()
        let fixture = try BannerFixture(client: client(transport: transport))
        defer { fixture.dispose() }
        try await fixture.seedAuth(optedOutXAIAuth())
        try await fixture.renderer.begin()
        try await fixture.dismissWelcome()

        let rects = try #require(await fixture.renderer.lastPrivacyBannerHits)
        let optIn = try #require(rects.optIn)
        let click = MouseEvent(kind: .down, x: optIn.x + 1, y: optIn.y)
        // Two clicks while the first write is parked in the transport.
        // Both layers of protection point the same way — the inflight flag
        // (status.rs:502) for clicks inside one frame, the
        // replace-wholesale geometry for clicks after the optimistic
        // repaint — and the observable contract is one consent PUT.
        let first = try await fixture.renderer.handleInput(.mouse(click))
        #expect(first == .consumed)
        let second = try await fixture.renderer.handleInput(.mouse(click))
        #expect(second == .consumed)

        let deadline = Date().addingTimeInterval(5)
        while transport.requests.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        // Give a would-be second request time to surface before counting.
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(transport.requests.count == 1, "a double-click must issue one request")

        transport.releaseHeld(status: 200, body: "{}")
        let outcome = await fixture.renderer.pendingCodingDataWrite?.value
        #expect(outcome == .saved)
        #expect(await fixture.waitForAckOnDisk())
        try await fixture.renderer.restoreTerminal()
    }

    // MARK: Links

    @Test("terms and policy clicks route their URLs to the browser seam")
    func termsAndPolicyRouteToBrowserSeam() async throws {
        let opened = OpenedURLBox()
        let fixture = try BannerFixture(openBrowser: { opened.append($0) })
        defer { fixture.dispose() }
        try await fixture.seedAuth(optedOutXAIAuth())
        try await fixture.renderer.begin()
        try await fixture.dismissWelcome()

        let rects = try #require(await fixture.renderer.lastPrivacyBannerHits)
        let terms = try #require(rects.terms)
        let policy = try #require(rects.policy)
        let termsClick = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: terms.x + 1, y: terms.y
        )))
        #expect(termsClick == .consumed)
        let policyClick = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: policy.x + 1, y: policy.y
        )))
        #expect(policyClick == .consumed)
        #expect(opened.captured.map(\.absoluteString) == [
            pagerPrivacyBannerTermsURL,
            pagerPrivacyBannerPolicyURL,
        ])
        try await fixture.renderer.restoreTerminal()
    }

    // MARK: Overlays block the banner

    @Test("the welcome hero and a capturing overlay both block banner clicks")
    func overlaysBlockBannerClicks() async throws {
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 200), body: Data("{}".utf8))
        ])
        let fixture = try BannerFixture(client: client(transport: transport))
        defer { fixture.dispose() }
        try await fixture.seedAuth(optedOutXAIAuth())
        try await fixture.renderer.begin()

        // Before the first turn (B2-W4) the banner lives in the WELCOME TIP
        // SLOT above the composer, not the chrome slot — so a click at the
        // chrome coordinates hits cells where no banner is painted and must
        // dispatch nothing (the welcome swallows it). The clickable-on-
        // welcome positive lives in `bannerOwnsTheWelcomeTipSlot`.
        let welcomeClick = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: 113, y: 2
        )))
        #expect(welcomeClick == .consumed)
        #expect(await fixture.renderer.pendingCodingDataWrite == nil)

        try await fixture.dismissWelcome()

        // A capturing overlay blocks the banner exactly as it blocks the
        // rail (the `overlay_blocks_rail_hover` analog,
        // agent_view/render.rs:1195-1200). The document viewer is the
        // harmless capturing modal: no row it could offer commits anything.
        try await fixture.renderer.render(.overlay(.showDocument(
            title: "Doc",
            content: "body"
        )))
        let blockedClick = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: 113, y: 2
        )))
        #expect(blockedClick == .consumed)
        #expect(await fixture.renderer.pendingCodingDataWrite == nil)
        #expect(transport.recordedRequests.isEmpty)
        #expect(!fixture.configText.contains("privacy_banner_acked"))

        // Positive control: the SAME coordinates dispatch once the overlay
        // is gone — the negatives above tested the guards, not a dead rect.
        try await fixture.renderer.render(.overlay(.dismissAll))
        let click = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: 113, y: 2
        )))
        #expect(click == .consumed)
        let write = try #require(await fixture.renderer.pendingCodingDataWrite)
        #expect(await write.value == .saved)
        #expect(transport.recordedRequests.count == 1)
        try await fixture.renderer.restoreTerminal()
    }

    // MARK: B2-W4 — the welcome tip slot

    @Test("the banner owns the welcome tip slot: painted above the composer and clickable")
    func bannerOwnsTheWelcomeTipSlot() async throws {
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 200), body: Data("{}".utf8))
        ])
        let fixture = try BannerFixture(client: client(transport: transport))
        defer { fixture.dispose() }
        try await fixture.seedAuth(optedOutXAIAuth())
        try await fixture.renderer.begin()

        // Painted OVER the welcome (`views/welcome/mod.rs:2112-2137` at pin
        // 650c1db7: the banner owns the tip slot above the prompt), with the
        // rects published from the visible tip-slot paint — in the lower
        // half of the screen, never the chrome slot's rows.
        #expect(await fixture.waitForFrame(containing: "SpaceXAI"))
        let rects = try #require(await fixture.renderer.lastPrivacyBannerHits)
        let optIn = try #require(rects.optIn)
        #expect(optIn.y > 20, "the tip slot sits above the composer, not in the chrome rows")

        // The W4 router rule: banner rects route under the NON-CAPTURING
        // welcome, because a published rect is a visible banner by
        // construction. The click opts in through the real c2 seam.
        let click = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: optIn.x + 1, y: optIn.y
        )))
        #expect(click == .consumed)
        let write = try #require(await fixture.renderer.pendingCodingDataWrite)
        #expect(await write.value == .saved)
        #expect(transport.recordedRequests.count == 1)
        #expect(await fixture.waitForAckOnDisk())
        try await fixture.renderer.restoreTerminal()
    }

    @Test("a capturing overlay still blocks the tip-slot banner at its own rects")
    func capturingOverlayBlocksTheTipSlot() async throws {
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 200), body: Data("{}".utf8))
        ])
        let fixture = try BannerFixture(client: client(transport: transport))
        defer { fixture.dispose() }
        try await fixture.seedAuth(optedOutXAIAuth())
        try await fixture.renderer.begin()
        #expect(await fixture.waitForFrame(containing: "SpaceXAI"))
        let rects = try #require(await fixture.renderer.lastPrivacyBannerHits)
        let optIn = try #require(rects.optIn)

        // A capturing modal over the welcome blocks the banner exactly as
        // it blocks everything else (`!overlays.isActive` — upstream's
        // modal rule); only the non-capturing welcome is routable-through.
        try await fixture.renderer.render(.overlay(.showDocument(
            title: "Doc",
            content: "body"
        )))
        let blocked = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: optIn.x + 1, y: optIn.y
        )))
        #expect(blocked == .consumed)
        #expect(await fixture.renderer.pendingCodingDataWrite == nil)
        #expect(transport.recordedRequests.isEmpty)
        try await fixture.renderer.restoreTerminal()
    }
}
