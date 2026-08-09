// LivePrivacyBannerReachabilityTests.swift
//
// The privacy banner's gate state through the LIVE seam (AGENTS.md §3): the
// real `LiveInteractiveControllerRenderer` over an isolated
// `$OPENGROK_HOME`, hydrating in `begin()` from a REAL credential written
// through `AuthManager` and a REAL `config.toml` — never a hand-built
// `PagerPrivacyBannerState`. A composition-level construction would pass
// just as happily if `begin()` never resolved the state or the resolver
// read the wrong home; these tests fail then. Nothing asserts on paint:
// this slice is dark by design (`privacy_notice_rollout` defaults false,
// pin 650c1db7 app_view.rs:2025), and the frame consumer is B9-c3.
//
// The gate matrix itself is pinned in
// `Tests/OpenGrokPagerRenderTests/PagerPrivacyBannerTests.swift`; here only
// the arms that prove auth metadata and disk state actually arrive.

import Foundation
import OpenGrokAuth
import OpenGrokHTTP
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokCLI

private final class PrivacyDiscardingSink: PagerTerminalSink, @unchecked Sendable {
    var capabilities: PagerTerminalCapabilities { .standard }
    func write(bytes: [UInt8]) throws {}
    func flush() throws {}
}

/// The live renderer over an isolated `$HOME`/`$OPENGROK_HOME` — the
/// `ReleaseNotesRendererFixture` shape, minus the changelog seams.
private struct PrivacyBannerRendererFixture {
    let home: URL
    let environment: [String: String]
    let renderer: LiveInteractiveControllerRenderer

    init(extraEnvironment: [String: String] = [:]) throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "opengrok-privacy-reach-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var env = ["HOME": home.path, "OPENGROK_HOME": home.path]
        for (key, value) in extraEnvironment { env[key] = value }
        environment = env
        let terminal = OpenGrokLiveTerminal(
            isTTY: { false },
            size: { OpenGrokLiveTerminalSize(width: 120, height: 40) },
            write: { _ in }
        )
        renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: terminal,
            sink: PrivacyDiscardingSink(),
            workingDirectory: home.path,
            modelName: "test-model",
            sessionID: "privacy-banner-live",
            openGrokHome: home,
            paintCadence: PagerMotion.minimumPaintCadence,
            environment: env,
            authServices: LivePagerAuthServices(
                makeTransport: { URLSessionHTTPTransport() },
                codexBrowserLogin: { _, _, _, _ in throw CancellationError() },
                openBrowser: nil
            )
        )
    }

    /// Seed a REAL credential through the same `AuthManager` construction
    /// the renderer's refresh uses, so the test exercises the store the
    /// production read hits — not a hand-crafted auth.json byte layout.
    func seedAuth(_ auth: GrokAuth) async throws {
        let manager = AuthManager(
            grokHome: home,
            config: GrokComConfig.default(environment: environment),
            environment: environment
        )
        try await manager.update(auth)
    }

    var configPath: URL { home.appendingPathComponent("config.toml") }

    func dispose() {
        try? FileManager.default.removeItem(at: home)
    }
}

/// An opted-out personal xAI OAuth credential — upstream's banner cohort.
private func optedOutXAIAuth() -> GrokAuth {
    GrokAuth(
        key: "token",
        authMode: .oidc,
        userID: "user-1",
        codingDataRetentionOptOut: true,
        oidcIssuer: xaiOAuth2Issuer
    )
}

@Suite("privacy banner live seam", .serialized)
struct LivePrivacyBannerReachabilityTests {
    @Test("begin() hydrates the gate from the real credential; env rollout arms it")
    func beginHydratesFromRealAuth() async throws {
        let fixture = try PrivacyBannerRendererFixture(
            extraEnvironment: ["GROK_PRIVACY_NOTICE_ROLLOUT": "1"]
        )
        defer { fixture.dispose() }
        try await fixture.seedAuth(optedOutXAIAuth())

        try await fixture.renderer.begin()

        let state = try #require(await fixture.renderer.privacyBanner)
        #expect(state.authDone)
        #expect(state.codingDataRetentionOptOut, "the credential's opt-out must arrive")
        #expect(state.privacyNoticeRollout, "the env override must arrive")
        #expect(state.privacyBannerAcked == nil)
        #expect(state.shouldShow())
        try await fixture.renderer.restoreTerminal()
    }

    @Test("without the env override the same session resolves dark")
    func defaultResolutionIsDark() async throws {
        // The negative control for the test above, and the pin that this
        // slice ships dark: no remote settings fetch exists in the
        // interactive composition, so absent an env override the rollout is
        // FALSE (event_loop.rs:1007-1013's `.unwrap_or(false)`).
        let fixture = try PrivacyBannerRendererFixture()
        defer { fixture.dispose() }
        try await fixture.seedAuth(optedOutXAIAuth())

        try await fixture.renderer.begin()

        let state = try #require(await fixture.renderer.privacyBanner)
        #expect(!state.privacyNoticeRollout)
        #expect(!state.shouldShow())
        try await fixture.renderer.restoreTerminal()
    }

    @Test("team and ZDR metadata flow from the credential and hide the banner")
    func teamMetadataFlows() async throws {
        let fixture = try PrivacyBannerRendererFixture(
            extraEnvironment: ["GROK_PRIVACY_NOTICE_ROLLOUT": "1"]
        )
        defer { fixture.dispose() }
        var auth = optedOutXAIAuth()
        auth.teamID = "team-1"
        auth.teamName = "Acme"
        auth.teamRole = "Member"
        auth.teamBlockedReasons = ["BLOCKED_REASON_NO_LOGS"]
        try await fixture.seedAuth(auth)

        try await fixture.renderer.begin()

        let state = try #require(await fixture.renderer.privacyBanner)
        #expect(state.teamName == "Acme")
        #expect(state.teamRole == "Member")
        #expect(state.isZDR, "BLOCKED_REASON_NO_LOGS must surface as ZDR")
        #expect(state.isTeamNonAdmin)
        #expect(!state.shouldShow())
        try await fixture.renderer.restoreTerminal()
    }

    @Test("a non-xAI credential gets upstream's cleared access controls")
    func nonXAIAuthClears() async throws {
        let fixture = try PrivacyBannerRendererFixture(
            extraEnvironment: ["GROK_PRIVACY_NOTICE_ROLLOUT": "1"]
        )
        defer { fixture.dispose() }
        // An API-key credential is never first-party xAI OAuth
        // (`GrokAuth.isXAIAuth`), so `clear_xai_access_controls`
        // (app_view.rs:1662-1675) applies: opt-out FALSE, no banner.
        var auth = GrokAuth(key: "sk-key", authMode: .apiKey, userID: "user-2")
        auth.codingDataRetentionOptOut = true
        try await fixture.seedAuth(auth)

        try await fixture.renderer.begin()

        let state = try #require(await fixture.renderer.privacyBanner)
        #expect(state.authDone)
        #expect(!state.codingDataRetentionOptOut)
        #expect(!state.shouldShow())
        try await fixture.renderer.restoreTerminal()
    }

    @Test("ack round-trip: write lands in config.toml, a fresh reload still hides")
    func ackRoundTrip() async throws {
        let fixture = try PrivacyBannerRendererFixture(
            extraEnvironment: ["GROK_PRIVACY_NOTICE_ROLLOUT": "1"]
        )
        defer { fixture.dispose() }
        try await fixture.seedAuth(optedOutXAIAuth())

        try await fixture.renderer.begin()
        #expect(try #require(await fixture.renderer.privacyBanner).shouldShow())

        // The ack, asserted at the step it happens — never `_ =` on a
        // status-returning call (AGENTS.md §3).
        #expect(await fixture.renderer.ackPrivacyBanner())

        let body = try String(contentsOf: fixture.configPath, encoding: .utf8)
        #expect(body.contains("[privacy]"))
        #expect(body.contains("privacy_banner_acked = "))
        #expect(!(try #require(await fixture.renderer.privacyBanner).shouldShow()))

        // A fresh hydration re-reads the DISK, not the in-memory mirror:
        // the write → reload → gate chain upstream's startup read performs
        // (event_loop.rs:1022-1029).
        await fixture.renderer.refreshPrivacyBannerState()
        let reloaded = try #require(await fixture.renderer.privacyBanner)
        #expect(reloaded.privacyBannerAcked != nil)
        #expect(!reloaded.shouldShow())
        try await fixture.renderer.restoreTerminal()
    }

    @Test("a failed ack write rolls the in-memory ack back")
    func failedAckWriteRollsBack() async throws {
        let fixture = try PrivacyBannerRendererFixture(
            extraEnvironment: ["GROK_PRIVACY_NOTICE_ROLLOUT": "1"]
        )
        defer { fixture.dispose() }
        try await fixture.seedAuth(optedOutXAIAuth())
        // A hand-written scalar where `[privacy]` must be a table is the
        // deterministic write failure: the store refuses to clobber it.
        try "privacy = \"oops\"\n".write(
            to: fixture.configPath, atomically: true, encoding: .utf8
        )

        try await fixture.renderer.begin()
        #expect(try #require(await fixture.renderer.privacyBanner).shouldShow())

        #expect(!(await fixture.renderer.ackPrivacyBanner()), "the write must report failure")

        // Rollback: memory still shows (this port's rollback_value
        // convention — recorded divergence from upstream's warn-and-keep,
        // effects/mod.rs:3989-4001), and the user's line survived.
        let state = try #require(await fixture.renderer.privacyBanner)
        #expect(state.privacyBannerAcked == nil)
        #expect(state.shouldShow())
        let body = try String(contentsOf: fixture.configPath, encoding: .utf8)
        #expect(body.contains(#"privacy = "oops""#))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("a seeded ack plus the reshow-days env override re-shows after the window")
    func reshowDaysEnvReaderAtLiveSeam() async throws {
        let fixture = try PrivacyBannerRendererFixture(
            extraEnvironment: [
                "GROK_PRIVACY_NOTICE_ROLLOUT": "1",
                "GROK_PRIVACY_BANNER_RESHOW_DAYS": "30",
            ]
        )
        defer { fixture.dispose() }
        try await fixture.seedAuth(optedOutXAIAuth())
        try """
        [privacy]
        privacy_banner_acked = "2020-01-01T00:00:00Z"
        """.write(to: fixture.configPath, atomically: true, encoding: .utf8)

        try await fixture.renderer.begin()

        let state = try #require(await fixture.renderer.privacyBanner)
        #expect(state.privacyBannerAcked == "2020-01-01T00:00:00Z")
        #expect(state.privacyBannerReshowDays == 30)
        #expect(state.shouldShow(), "an elapsed window must re-show")
        try await fixture.renderer.restoreTerminal()
    }
}
