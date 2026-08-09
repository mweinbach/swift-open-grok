// LiveCodingDataRetentionTests.swift
//
// The coding-data retention write through the LIVE seam (AGENTS.md §3):
// the real `LiveInteractiveControllerRenderer` over an isolated
// `$OPENGROK_HOME`, a REAL credential seeded through `AuthManager`, and —
// for the flagship — the real settings modal driven key by key with the
// PUT landing on a real 127.0.0.1 HTTP listener. Nothing here asserts
// against a hand-built state or a composition type: every claim is "what
// the running renderer offered, sent, and re-read".
//
// This is a consent write to a server (AGENTS.md §5), so the suite pins
// the failure directions by name: a failed PUT rolls BOTH mirrors back and
// says so; a denied export boundary issues NO request and still reports
// failure (with the positive control proving the same fixture would have
// sent one); a superseded reply touches nothing.

import Foundation
import OpenGrokAuth
import OpenGrokHTTP
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShellSessionSupport
import OpenGrokTerminalCore
import OpenGrokTestSupport
import Testing
@testable import OpenGrokCLI

// MARK: - Sink

private final class RetentionCapturingSink: PagerTerminalSink, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []

    var capabilities: PagerTerminalCapabilities { .standard }

    func write(bytes newBytes: [UInt8]) throws {
        lock.lock(); defer { lock.unlock() }
        bytes.append(contentsOf: newBytes)
    }

    func flush() throws {}

    /// CSI/OSC-stripped text. Assert on SINGLE tokens only: the cell
    /// differ moves the cursor between runs, so multi-word phrases are not
    /// guaranteed contiguous (the `LivePagerCommandReachabilityTests`
    /// stripper note).
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

// MARK: - Fixture

/// The live renderer over an isolated home, with an injected retention
/// client — the `PrivacyBannerRendererFixture` shape plus the write seam.
private struct RetentionFixture {
    let home: URL
    let environment: [String: String]
    let sink: RetentionCapturingSink
    let renderer: LiveInteractiveControllerRenderer

    init(
        client: LiveCodingDataRetentionClient?,
        extraEnvironment: [String: String] = [:]
    ) throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "opengrok-retention-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var env = ["HOME": home.path, "OPENGROK_HOME": home.path]
        for (key, value) in extraEnvironment { env[key] = value }
        environment = env
        sink = RetentionCapturingSink()
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
            sessionID: "retention-live",
            openGrokHome: home,
            codingDataRetention: client,
            paintCadence: PagerMotion.minimumPaintCadence,
            environment: env
        )
    }

    /// Seed a REAL credential through the same `AuthManager` construction
    /// the write seam resolves — the store the production read hits.
    func seedAuth(_ auth: GrokAuth) async throws {
        try await manager().update(auth)
    }

    /// A FRESH manager over the same home — how a next launch would read
    /// the auth-metadata mirror.
    func manager() -> AuthManager {
        AuthManager(
            grokHome: home,
            config: GrokComConfig.default(environment: environment),
            environment: environment
        )
    }

    func dispose() {
        try? FileManager.default.removeItem(at: home)
    }

    func waitForFrame(containing needle: String, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if sink.strippedText.contains(needle) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return sink.strippedText.contains(needle)
    }
}

/// An opted-out personal xAI OAuth credential — the population the row's
/// opt-in exists for.
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

/// A client over a scripted transport, gates open — the arms then close
/// one gate at a time.
private func client(
    transport: any HTTPTransport,
    exportPolicy: XaiServicePolicy = .allowed
) -> LiveCodingDataRetentionClient {
    LiveCodingDataRetentionClient(
        transport: transport,
        exportPolicy: exportPolicy,
        proxyBaseURL: URL(string: "https://proxy.invalid/v1")
    )
}

// MARK: - Real listener handler

/// Records every request and answers with a configurable status — the
/// upstream mock server's `/v1/privacy/coding-data-retention` role
/// (mock_server.rs:1080-1096 at pin 650c1db7).
private final class RetentionRecordingHandler: HttpRequestHandler, @unchecked Sendable {
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

// MARK: - Hold-first transport (superseded-reply orchestration)

/// Holds the FIRST request until released; every later request succeeds
/// immediately. This is how the out-of-order completion upstream's write
/// generations exist for (status.rs:96-110) is produced deterministically.
private final class HoldFirstTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var held: CheckedContinuation<HTTPResponse, Error>?
    private var seen = 0

    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return seen
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let ordinal: Int = {
            lock.lock(); defer { lock.unlock() }
            seen += 1
            return seen
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

// MARK: - Tests

@Suite("coding-data retention live seam", .serialized)
struct LiveCodingDataRetentionTests {
    // MARK: The flagship: modal keys → real PUT on a real socket

    @Test("the settings-modal commit PUTs to the real listener and flips row, gate, and auth mirror")
    func modalCommitWritesEverywhere() async throws {
        let handler = RetentionRecordingHandler()
        let server = HttpServer(handler: handler, basePath: "")
        try server.start()
        defer { server.stop() }

        let fixture = try RetentionFixture(client: LiveCodingDataRetentionClient(
            transport: URLSessionHTTPTransport(),
            exportPolicy: .allowed,
            proxyBaseURL: URL(string: server.baseURL)
        ))
        defer { fixture.dispose() }
        try await fixture.seedAuth(optedOutXAIAuth())
        try await fixture.renderer.begin()

        // `/privacy`'s exact overlay intent, then the row's real chooser:
        // Enter opens it on the current value ("opt-out", choice index 1),
        // Up moves to "opt-in", Enter commits.
        try await fixture.renderer.render(.overlay(.settings(
            deepLinkKey: "coding_data_sharing"
        )))
        let openChooser = try await fixture.renderer.handleInput(.key(KeyEvent(key: .enter)))
        #expect(openChooser == .consumed)
        let moveToOptIn = try await fixture.renderer.handleInput(.key(KeyEvent(key: .up)))
        #expect(moveToOptIn == .consumed)
        let commit = try await fixture.renderer.handleInput(.key(KeyEvent(key: .enter)))
        #expect(commit == .consumed)

        let outcome = await fixture.renderer.pendingCodingDataWrite?.value
        #expect(outcome == .saved)

        // The wire: one PUT, upstream's path, body, and headers
        // (privacy.rs:36-60). Auth headers are asserted by PRESENCE and
        // shape only — never the secret value.
        #expect(handler.requests.count == 1)
        let request = try #require(handler.requests.first)
        #expect(request.method == "PUT")
        #expect(request.pathOnly == "/v1/privacy/coding-data-retention")
        let body = try #require(
            try JSONSerialization.jsonObject(with: request.body) as? [String: Any]
        )
        #expect(body["codingDataRetentionOptOut"] as? Bool == false)
        #expect(body.count == 1)
        let authorization = try #require(request.authorization)
        #expect(authorization.hasPrefix("Bearer "))
        #expect(authorization.count > "Bearer ".count)
        #expect(request.header("X-XAI-Token-Auth") == "xai-grok-cli")
        #expect(request.header("x-grok-client-version")?.isEmpty == false)
        #expect(request.header("x-grok-client-mode") == "interactive")

        // The three mirrors: the OPEN modal's row, the B9-c1 gate state
        // (no restart), and the on-disk auth metadata a next launch reads.
        #expect(await fixture.renderer.openSettingsRowValue(
            forKey: "coding_data_sharing"
        ) == .string("opt-in"))
        #expect(await fixture.renderer.privacyBanner?.codingDataRetentionOptOut == false)
        let disk = await fixture.manager().currentOrExpired()
        #expect(disk?.codingDataRetentionOptOut == false)
        try await fixture.renderer.restoreTerminal()
    }

    // MARK: Failure rolls back everything and says so

    @Test("a failed PUT rolls back the row and the gate and surfaces the server's error")
    func failedPutRollsBack() async throws {
        let transport = MockHTTPTransport(responses: [
            .init(
                metadata: HTTPResponseMetadata(statusCode: 500),
                body: Data(#"{"error":"nope"}"#.utf8)
            )
        ])
        let fixture = try RetentionFixture(client: client(transport: transport))
        defer { fixture.dispose() }
        try await fixture.seedAuth(optedOutXAIAuth())
        try await fixture.renderer.begin()

        try await fixture.renderer.render(.overlay(.settings(
            deepLinkKey: "coding_data_sharing"
        )))
        let openChooser = try await fixture.renderer.handleInput(.key(KeyEvent(key: .enter)))
        #expect(openChooser == .consumed)
        let moveToOptIn = try await fixture.renderer.handleInput(.key(KeyEvent(key: .up)))
        #expect(moveToOptIn == .consumed)
        let commit = try await fixture.renderer.handleInput(.key(KeyEvent(key: .enter)))
        #expect(commit == .consumed)

        let outcome = await fixture.renderer.pendingCodingDataWrite?.value
        #expect(outcome == .failed)
        #expect(transport.recordedRequests.count == 1)

        // Both mirrors rolled back — the open modal's row AND the gate
        // state — and the disk mirror was never touched.
        #expect(await fixture.renderer.openSettingsRowValue(
            forKey: "coding_data_sharing"
        ) == .string("opt-out"))
        #expect(await fixture.renderer.privacyBanner?.codingDataRetentionOptOut == true)
        let disk = await fixture.manager().currentOrExpired()
        #expect(disk?.codingDataRetentionOptOut == true)
        // The failure toast carries the server's error through the scrub
        // (status.rs:475-479). Single-token assertion per the stripper note.
        #expect(await fixture.waitForFrame(containing: "nope"))
        try await fixture.renderer.restoreTerminal()
    }

    // MARK: Export boundary — denied arm plus positive control

    @Test("a denied export policy issues NO request and reports the failure")
    func exportDeniedIssuesNoRequest() async throws {
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 200), body: Data("{}".utf8))
        ])
        let fixture = try RetentionFixture(
            client: client(transport: transport, exportPolicy: .denied)
        )
        defer { fixture.dispose() }
        try await fixture.seedAuth(optedOutXAIAuth())
        try await fixture.renderer.begin()

        let outcome = await fixture.renderer.setCodingDataSharing(optedIn: true)
        #expect(outcome == .failed)
        #expect(transport.recordedRequests.isEmpty, "denied means the request is never issued")
        #expect(await fixture.renderer.privacyBanner?.codingDataRetentionOptOut == true)
        #expect(await fixture.waitForFrame(containing: "denies"))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("positive control: the same fixture with the policy open issues the request and saves")
    func exportAllowedPositiveControl() async throws {
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 200), body: Data("{}".utf8))
        ])
        let fixture = try RetentionFixture(
            client: client(transport: transport, exportPolicy: .allowed)
        )
        defer { fixture.dispose() }
        try await fixture.seedAuth(optedOutXAIAuth())
        try await fixture.renderer.begin()

        let outcome = await fixture.renderer.setCodingDataSharing(optedIn: true)
        #expect(outcome == .saved)
        #expect(transport.recordedRequests.count == 1)
        #expect(await fixture.renderer.privacyBanner?.codingDataRetentionOptOut == false)
        let disk = await fixture.manager().currentOrExpired()
        #expect(disk?.codingDataRetentionOptOut == false)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("a closed live boundary refuses the write even with the frozen policy open")
    func closedLiveBoundaryRefuses() async throws {
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 200), body: Data("{}".utf8))
        ])
        // The monotonic session boundary already closed (a non-xAI provider
        // was observed) — the send-time bail must win over the
        // construction-time policy.
        let fixture = try RetentionFixture(client: LiveCodingDataRetentionClient(
            transport: transport,
            exportPolicy: .allowed,
            proxyBaseURL: URL(string: "https://proxy.invalid/v1"),
            liveBoundary: ExportBoundary(everUsedNonXAI: true)
        ))
        defer { fixture.dispose() }
        try await fixture.seedAuth(optedOutXAIAuth())
        try await fixture.renderer.begin()

        let outcome = await fixture.renderer.setCodingDataSharing(optedIn: true)
        #expect(outcome == .failed)
        #expect(transport.recordedRequests.isEmpty)
        #expect(await fixture.renderer.privacyBanner?.codingDataRetentionOptOut == true)
        try await fixture.renderer.restoreTerminal()
    }

    // MARK: Auth-required arm

    @Test("no credential: no request, rollback, upstream's auth-required copy")
    func missingCredentialFails() async throws {
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 200), body: Data("{}".utf8))
        ])
        let fixture = try RetentionFixture(client: client(transport: transport))
        defer { fixture.dispose() }
        // Deliberately NO seeded credential.
        try await fixture.renderer.begin()

        let outcome = await fixture.renderer.setCodingDataSharing(optedIn: true)
        #expect(outcome == .failed)
        #expect(transport.recordedRequests.isEmpty)
        #expect(await fixture.renderer.privacyBanner?.codingDataRetentionOptOut == true)
        // privacy.rs:32-33's copy, through the toast. Single token.
        #expect(await fixture.waitForFrame(containing: "re-authenticate"))
        try await fixture.renderer.restoreTerminal()
    }

    // MARK: Upstream's dispatch guards

    @Test("ZDR refuses with upstream's toast and issues nothing")
    func zdrGuardRefuses() async throws {
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 200), body: Data("{}".utf8))
        ])
        let fixture = try RetentionFixture(client: client(transport: transport))
        defer { fixture.dispose() }
        try await fixture.seedAuth(optedOutXAIAuth(
            teamName: "acme",
            teamRole: "admin",
            teamBlockedReasons: ["BLOCKED_REASON_NO_LOGS"]
        ))
        try await fixture.renderer.begin()

        let outcome = await fixture.renderer.setCodingDataSharing(optedIn: true)
        #expect(outcome == .refused)
        #expect(transport.recordedRequests.isEmpty)
        #expect(await fixture.renderer.privacyBanner?.codingDataRetentionOptOut == true)
        // "✗ Cannot change: Zero Data Retention enabled" — single token.
        #expect(await fixture.waitForFrame(containing: "Retention"))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("a non-admin team member is refused with the admin toast")
    func nonAdminGuardRefuses() async throws {
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 200), body: Data("{}".utf8))
        ])
        let fixture = try RetentionFixture(client: client(transport: transport))
        defer { fixture.dispose() }
        try await fixture.seedAuth(optedOutXAIAuth(teamName: "acme", teamRole: "member"))
        try await fixture.renderer.begin()

        let outcome = await fixture.renderer.setCodingDataSharing(optedIn: true)
        #expect(outcome == .refused)
        #expect(transport.recordedRequests.isEmpty)
        // "✗ Data sharing is controlled by your team admin" — single token.
        #expect(await fixture.waitForFrame(containing: "admin"))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("already at the requested value: idempotent skip, no request")
    func idempotentSkip() async throws {
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 200), body: Data("{}".utf8))
        ])
        let fixture = try RetentionFixture(client: client(transport: transport))
        defer { fixture.dispose() }
        try await fixture.seedAuth(optedInXAIAuth())
        try await fixture.renderer.begin()

        let outcome = await fixture.renderer.setCodingDataSharing(optedIn: true)
        #expect(outcome == .unchanged)
        #expect(transport.recordedRequests.isEmpty)
        try await fixture.renderer.restoreTerminal()
    }

    // MARK: Write generations

    @Test("a superseded failure neither reverts nor toasts — the newer write owns the state")
    func supersededFailureDropped() async throws {
        let transport = HoldFirstTransport()
        let fixture = try RetentionFixture(client: client(transport: transport))
        defer { fixture.dispose() }
        try await fixture.seedAuth(optedOutXAIAuth())
        try await fixture.renderer.begin()

        // Write A (opt-in) parks inside the transport holding generation 1.
        let renderer = fixture.renderer
        let writeA = Task { await renderer.setCodingDataSharing(optedIn: true) }
        let deadline = Date().addingTimeInterval(5)
        while transport.requestCount < 1, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(transport.requestCount == 1, "write A must reach the transport first")

        // Write B (opt-out) takes generation 2 and completes immediately.
        let outcomeB = await renderer.setCodingDataSharing(optedIn: false)
        #expect(outcomeB == .saved)
        #expect(await renderer.privacyBanner?.codingDataRetentionOptOut == true)

        // Now A's failure lands, carrying generation 1: applying its
        // rollback would resurrect A's optimistic value and silently undo
        // what the user did since (status.rs:96-110, :462-467).
        transport.releaseHeld(status: 500, body: #"{"error":"stalefail"}"#)
        let outcomeA = await writeA.value
        #expect(outcomeA == .failed)
        #expect(
            await renderer.privacyBanner?.codingDataRetentionOptOut == true,
            "the superseded failure must not revert the newer write"
        )
        // No toast either: nothing the user is looking at failed.
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(!fixture.sink.strippedText.contains("stalefail"))
        try await fixture.renderer.restoreTerminal()
    }

    // MARK: /privacy deep link + modal hydration

    @Test("the /privacy deep link lands on a row hydrated from the live mirror")
    func deepLinkLandsOnHydratedRow() async throws {
        let transport = MockHTTPTransport()
        let fixture = try RetentionFixture(client: client(transport: transport))
        defer { fixture.dispose() }
        // Opted IN: the row must show the NON-default value, which only
        // happens if the modal read the live mirror rather than the
        // registry default.
        try await fixture.seedAuth(optedInXAIAuth())
        try await fixture.renderer.begin()

        // The selection: /privacy's deep-link key must land the cursor on
        // the row (the row exists and is selected).
        let overlay = await fixture.renderer.settingsOverlay(
            deepLinkKey: "coding_data_sharing"
        )
        #expect(overlay.visibleRows[overlay.selectedIndex].settingKey == "coding_data_sharing")
        #expect(overlay.values["coding_data_sharing"] == .string("opt-in"))

        // The open modal through the real overlay route (`/privacy` emits
        // exactly this intent, OpenGrokPagerInteractiveController).
        try await fixture.renderer.render(.overlay(.settings(
            deepLinkKey: "coding_data_sharing"
        )))
        #expect(await fixture.renderer.openSettingsRowValue(
            forKey: "coding_data_sharing"
        ) == .string("opt-in"))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("a ZDR mirror locks the row in the freshly built modal")
    func zdrLocksTheRow() async throws {
        let transport = MockHTTPTransport()
        let fixture = try RetentionFixture(client: client(transport: transport))
        defer { fixture.dispose() }
        try await fixture.seedAuth(optedOutXAIAuth(
            teamName: "acme",
            teamRole: "admin",
            teamBlockedReasons: ["BLOCKED_REASON_NO_LOGS"]
        ))
        try await fixture.renderer.begin()

        let overlay = await fixture.renderer.settingsOverlay()
        #expect(overlay.locks["coding_data_sharing"] == .zeroDataRetention)
        try await fixture.renderer.restoreTerminal()
    }
}
