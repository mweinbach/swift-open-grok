// PagerPrivacyBannerTests.swift
//
// The privacy banner's gate, re-show window, env-over-remote resolvers, and
// ack store (Wave 18 B9-c1), against the Rust reference at pin 650c1db7.
// The gate matrix ports `privacy_banner_should_show_respects_gates`
// (app/dispatch/tests/status.rs:586-629) and then covers every arm of
// `privacy_banner_should_show` (app_view.rs:1705-1731) the upstream test
// leaves implicit — minimal mode, team role, auth/trust/access, and the
// unparseable-ack FAIL-OPEN arm, which is pinned so nobody "hardens" it.

import Foundation
import Testing
@testable import OpenGrokPagerRender
import OpenGrokConfigTypes

// MARK: - Fixtures

/// Upstream's `privacy_banner_ready_app` (tests/status.rs:586-599): every
/// gate open, so each test closes exactly one.
private func readyState() -> PagerPrivacyBannerState {
    PagerPrivacyBannerState(
        minimalMode: false,
        privacyNoticeRollout: true,
        privacyBannerReshowDays: nil,
        privacyBannerAcked: nil,
        isZDR: false,
        zdrAccessEnabled: false,
        teamName: nil,
        teamRole: nil,
        codingDataRetentionOptOut: true,
        authDone: true,
        hasAccess: true,
        trustDone: true
    )
}

private func remoteSettings(_ json: String) throws -> RemoteSettings {
    try JSONDecoder().decode(RemoteSettings.self, from: Data(json.utf8))
}

private func tempConfigPath() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("opengrok-privacy-ack-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("config.toml")
}

// MARK: - Gate matrix

@Suite("privacy banner gate")
struct PagerPrivacyBannerGateTests {
    @Test("the ready state shows (tests/status.rs:603-604)")
    func readyStateShows() {
        #expect(readyState().shouldShow())
    }

    @Test("already opted in hides — polarity: opt-out TRUE is the upsell population")
    func optedInHides() {
        var state = readyState()
        state.codingDataRetentionOptOut = false
        #expect(!state.shouldShow(), "already opted in (tests/status.rs:606-607)")
    }

    @Test("enterprise ZDR hides, and zdr_access_enabled cannot resurrect it")
    func zdrHides() {
        var state = readyState()
        state.isZDR = true
        #expect(!state.shouldShow(), "enterprise ZDR (tests/status.rs:610-611)")
        // The `is_zdr ||` arm (app_view.rs:1712) precedes the blocked check,
        // so ZDR-with-access is still no banner.
        state.zdrAccessEnabled = true
        #expect(!state.shouldShow())
    }

    @Test("recently acked with no reshow window hides")
    func recentAckNoReshowHides() {
        var state = readyState()
        state.privacyBannerAcked = "2099-01-01T00:00:00Z"
        #expect(!state.shouldShow(), "recently acked, no reshow (tests/status.rs:614-618)")
    }

    @Test("acked long ago plus reshow_days shows again")
    func oldAckWithReshowShows() {
        var state = readyState()
        state.privacyBannerReshowDays = 30
        state.privacyBannerAcked = "2020-01-01T00:00:00Z"
        #expect(state.shouldShow(), "acked long ago + reshow_days (tests/status.rs:620-625)")
    }

    @Test("rollout off hides — the flag this slice ships dark on")
    func rolloutOffHides() {
        var state = readyState()
        state.privacyNoticeRollout = false
        #expect(!state.shouldShow(), "rollout off (tests/status.rs:627-628)")
    }

    @Test("a default-constructed state never shows")
    func defaultStateDark() {
        // app_view.rs:2020-2033 construction defaults: rollout false.
        #expect(!PagerPrivacyBannerState().shouldShow())
    }

    @Test("minimal mode hides (app_view.rs:1706-1708)")
    func minimalModeHides() {
        var state = readyState()
        state.minimalMode = true
        #expect(!state.shouldShow())
    }

    @Test("team non-admin hides; admin shows, case-insensitively")
    func teamRoleArms() {
        // app_view.rs:1686-1692: team_name present + role != "admin".
        var state = readyState()
        state.teamName = "Acme"
        state.teamRole = "Member"
        #expect(!state.shouldShow())
        state.teamRole = nil
        #expect(!state.shouldShow(), "team with no role is non-admin")
        state.teamRole = "Admin"
        #expect(state.shouldShow())
        state.teamRole = "ADMIN"
        #expect(state.shouldShow(), "eq_ignore_ascii_case, not exact match")
        // No team at all is not "non-admin" — personal accounts pass.
        state.teamName = nil
        state.teamRole = nil
        #expect(state.shouldShow())
    }

    @Test("auth, access, ZDR-block, and trust preconditions each hide")
    func preconditionArms() {
        // app_view.rs:1718-1724, one conjunct at a time.
        var state = readyState()
        state.authDone = false
        #expect(!state.shouldShow())

        state = readyState()
        state.hasAccess = false
        #expect(!state.shouldShow())

        state = readyState()
        state.trustDone = false
        #expect(!state.shouldShow())
    }

    @Test("an UNPARSEABLE ack fails OPEN when a reshow window exists")
    func unparseableAckFailsOpen() {
        // app_view.rs:1399-1401, ported exactly and pinned: a corrupt
        // timestamp must re-show the banner, never hide it forever. If this
        // test starts failing because someone made the parse failure return
        // false, that is the regression it exists to catch.
        var state = readyState()
        state.privacyBannerReshowDays = 30
        state.privacyBannerAcked = "not-a-timestamp"
        #expect(state.shouldShow())
    }

    @Test("an unparseable ack with NO reshow window still never re-shows")
    func unparseableAckWithoutWindowHides() {
        // Ordering pin: the days guard (app_view.rs:1396-1398) precedes the
        // parse, so reshow_days nil/0 means the parse arm is unreachable.
        var state = readyState()
        state.privacyBannerAcked = "not-a-timestamp"
        state.privacyBannerReshowDays = nil
        #expect(!state.shouldShow())
        state.privacyBannerReshowDays = 0
        #expect(!state.shouldShow())
    }
}

// MARK: - Re-show window

@Suite("privacy banner reshow window")
struct PagerPrivacyBannerReshowTests {
    @Test("nil or zero days never elapses (app_view.rs:1396-1398)")
    func nilOrZeroNeverElapses() {
        #expect(!privacyBannerReshowElapsed(ackedAt: "2020-01-01T00:00:00Z", reshowDays: nil))
        #expect(!privacyBannerReshowElapsed(ackedAt: "2020-01-01T00:00:00Z", reshowDays: 0))
    }

    @Test("elapses exactly at ack + days, not before (app_view.rs:1403-1406)")
    func boundaryIsInclusive() {
        let acked = "2026-01-01T00:00:00Z"
        let next = parsePrivacyBannerAckTimestamp(acked)!.addingTimeInterval(30 * 86_400)
        #expect(privacyBannerReshowElapsed(ackedAt: acked, reshowDays: 30, now: next))
        #expect(!privacyBannerReshowElapsed(
            ackedAt: acked,
            reshowDays: 30,
            now: next.addingTimeInterval(-1)
        ))
    }

    @Test("accepts fractional seconds and numeric offsets, like chrono's RFC 3339 parse")
    func parseTolerance() {
        #expect(privacyBannerReshowElapsed(
            ackedAt: "2020-01-01T00:00:00.123Z",
            reshowDays: 1
        ))
        #expect(privacyBannerReshowElapsed(
            ackedAt: "2020-01-01T05:30:00+05:30",
            reshowDays: 1
        ))
    }

    @Test("the written ack timestamp round-trips through the parser")
    func writtenTimestampRoundTrips() {
        let now = Date()
        let stamp = privacyBannerAckTimestamp(now: now)
        // Upstream writes seconds precision with a Z suffix
        // (dispatch/status.rs:493, `SecondsFormat::Secs`, use_z = true).
        #expect(stamp.hasSuffix("Z"))
        #expect(!stamp.contains("."))
        let parsed = parsePrivacyBannerAckTimestamp(stamp)
        #expect(parsed != nil)
        // A just-written ack must read as not-elapsed under any window.
        #expect(!privacyBannerReshowElapsed(ackedAt: stamp, reshowDays: 30, now: now))
    }
}

// MARK: - Env-over-remote resolvers

@Suite("privacy banner env-over-remote resolution")
struct PagerPrivacyBannerResolverTests {
    @Test("rollout: env wins over remote in both directions (event_loop.rs:1007-1013)")
    func rolloutEnvWins() throws {
        let remoteOn = try remoteSettings(#"{"privacy_notice_rollout": true}"#)
        let remoteOff = try remoteSettings(#"{"privacy_notice_rollout": false}"#)
        #expect(resolvePrivacyNoticeRollout(
            remoteSettings: remoteOff,
            environment: [privacyNoticeRolloutEnvVar: "1"]
        ))
        #expect(!resolvePrivacyNoticeRollout(
            remoteSettings: remoteOn,
            environment: [privacyNoticeRolloutEnvVar: "0"]
        ))
    }

    @Test("rollout: env absent falls to remote; absent-everything is FALSE")
    func rolloutFallsToRemoteThenFalse() throws {
        let remoteOn = try remoteSettings(#"{"privacy_notice_rollout": true}"#)
        #expect(resolvePrivacyNoticeRollout(remoteSettings: remoteOn, environment: [:]))
        #expect(!resolvePrivacyNoticeRollout(
            remoteSettings: try remoteSettings("{}"),
            environment: [:]
        ))
        #expect(!resolvePrivacyNoticeRollout(remoteSettings: nil, environment: [:]))
    }

    @Test("rollout: a garbage env value is no override, not a false")
    func rolloutGarbageEnvFallsThrough() throws {
        // Upstream `env_bool` yields None for unrecognized spellings
        // (xai-grok-config/src/lib.rs:77-85), so remote still decides.
        let remoteOn = try remoteSettings(#"{"privacy_notice_rollout": true}"#)
        #expect(resolvePrivacyNoticeRollout(
            remoteSettings: remoteOn,
            environment: [privacyNoticeRolloutEnvVar: "banana"]
        ))
    }

    @Test("reshow days: env wins, including an explicit zero (event_loop.rs:1014-1021)")
    func reshowDaysEnvWins() throws {
        let remote = try remoteSettings(#"{"privacy_banner_reshow_days": 7}"#)
        #expect(resolvePrivacyBannerReshowDays(
            remoteSettings: remote,
            environment: [privacyBannerReshowDaysEnvVar: "45"]
        ) == 45)
        #expect(resolvePrivacyBannerReshowDays(
            remoteSettings: remote,
            environment: [privacyBannerReshowDaysEnvVar: " 0 "]
        ) == 0)
    }

    @Test("reshow days: unparseable env falls to remote; absent-everything is nil")
    func reshowDaysFallsThrough() throws {
        // Upstream's `.ok().and_then(parse.ok())` chain: a bad value is no
        // override. `u64` refuses negatives the same way `UInt64` does.
        let remote = try remoteSettings(#"{"privacy_banner_reshow_days": 7}"#)
        #expect(resolvePrivacyBannerReshowDays(
            remoteSettings: remote,
            environment: [privacyBannerReshowDaysEnvVar: "soon"]
        ) == 7)
        #expect(resolvePrivacyBannerReshowDays(
            remoteSettings: remote,
            environment: [privacyBannerReshowDaysEnvVar: "-3"]
        ) == 7)
        #expect(resolvePrivacyBannerReshowDays(remoteSettings: remote, environment: [:]) == 7)
        #expect(resolvePrivacyBannerReshowDays(
            remoteSettings: try remoteSettings("{}"),
            environment: [:]
        ) == nil)
        #expect(resolvePrivacyBannerReshowDays(remoteSettings: nil, environment: [:]) == nil)
    }
}

// MARK: - Ack store

@Suite("privacy banner ack store")
struct PagerPrivacyBannerAckStoreTests {
    @Test("write → read round-trips, and the gate sees the ack")
    func roundTrip() throws {
        let path = try tempConfigPath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let store = PagerPrivacyBannerAckStore(configPath: path)
        #expect(store.read() == nil, "no file yet reads as no ack")

        try store.write(ackedAt: "2099-01-01T00:00:00Z")
        #expect(store.read() == "2099-01-01T00:00:00Z")

        var state = readyState()
        state.privacyBannerAcked = store.read()
        #expect(!state.shouldShow(), "the persisted ack must reach the gate")

        // A second write overwrites — the ack is a single timestamp, not a log.
        try store.write(ackedAt: "2099-02-02T00:00:00Z")
        #expect(store.read() == "2099-02-02T00:00:00Z")
    }

    @Test("the ack lands beside existing [privacy] keys and foreign tables intact")
    func preservesSiblings() throws {
        let path = try tempConfigPath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        try """
        [ui]
        theme = "grok-night"

        [privacy]
        future_key = "kept"
        """.write(to: path, atomically: true, encoding: .utf8)

        try PagerPrivacyBannerAckStore(configPath: path).write(ackedAt: "2099-01-01T00:00:00Z")
        let body = try String(contentsOf: path, encoding: .utf8)
        #expect(body.contains(#"future_key = "kept""#), "sibling [privacy] keys must survive")
        #expect(body.contains(#"theme = "grok-night""#), "unrelated tables must survive")
        #expect(body.contains(#"privacy_banner_acked = "2099-01-01T00:00:00Z""#))
    }

    @Test("a hand-written scalar `privacy` key refuses the write instead of clobbering")
    func scalarPrivacyRefuses() throws {
        let path = try tempConfigPath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        try "privacy = \"oops\"\n".write(to: path, atomically: true, encoding: .utf8)

        let store = PagerPrivacyBannerAckStore(configPath: path)
        #expect(store.read() == nil)
        #expect(throws: (any Error).self) {
            try store.write(ackedAt: "2099-01-01T00:00:00Z")
        }
        // The refusal left the user's line alone.
        let body = try String(contentsOf: path, encoding: .utf8)
        #expect(body.contains(#"privacy = "oops""#))
    }
}
