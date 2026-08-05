// UpstreamDriftTests.swift
//
// Golden fixtures for the auth-store schema at pin 80dff0a9.
//
// The auth.json fixtures below are written by hand in the exact shape the
// Rust `GrokAuth` Serialize impl produces
// (`crates/codegen/xai-grok-shell/src/auth/model.rs:57-117`): snake_case
// keys, `skip_serializing_if = "Option::is_none"` on every optional,
// `skip_serializing_if = "Vec::is_empty"` on `team_blocked_reasons`, and
// `coding_data_retention_opt_out` always present.

import Foundation
import Testing
@testable import OpenGrokAuth

private func tempHome(_ name: String = UUID().uuidString) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("auth-drift-\(name)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func writeAuthFile(_ home: URL, _ json: String) throws {
    try Data(json.utf8).write(to: home.appendingPathComponent("auth.json"))
}

private func readAuthFile(_ home: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: home.appendingPathComponent("auth.json"))
    return try JSONSerialization.jsonObject(with: data) as! [String: Any]
}

@Suite("Auth provider scope keys")
struct AuthProviderScopeKeyTests {
    /// Provenance: `storage.rs:437-452` at 80dff0a9. `wafer::api_key` is the
    /// scope added at this pin; the other three predate it.
    @Test("scope key strings match the Rust constants")
    func scopeStrings() {
        #expect(apiKeyScope == "xai::api_key")
        #expect(providerAPIKeyScope("kimi") == "kimi::api_key")
        #expect(kimiCodeAPIKeyScope == "kimi_code::api_key")
        #expect(perplexityAPIKeyScope == "perplexity::api_key")
        #expect(waferAPIKeyScope == "wafer::api_key")
    }

    /// The migration rule at storage.rs:445-452: Kimi **Platform** reuses the
    /// historical provider scope so existing users are not logged out, while
    /// Code gets an isolated one. Getting this backwards would silently
    /// invalidate every existing Kimi login.
    @Test("Kimi Platform reuses the historical provider scope; Code is isolated")
    func kimiScopeMigration() {
        #expect(kimiAPIKeyScope(.platform) == "kimi::api_key")
        #expect(kimiAPIKeyScope(.code) == "kimi_code::api_key")
    }

    @Test("KimiAPIEndpoint canonical tokens round trip")
    func kimiEndpointCanonical() {
        #expect(KimiAPIEndpoint.platform.canonical == "platform")
        #expect(KimiAPIEndpoint.code.canonical == "code")
        #expect(KimiAPIEndpoint.fromCanonical("  code ") == .code)
        #expect(KimiAPIEndpoint.fromCanonical("Code") == nil)  // exact match, per from_canonical
        #expect(KimiAPIEndpoint.fromCanonical("nope") == nil)
    }
}

@Suite("Auth store scope isolation")
struct AuthStoreScopeIsolationTests {
    /// Provenance: `wafer_key_round_trip_and_clear_preserve_unrelated_scopes`,
    /// storage.rs:777-799. Clearing one provider must leave every sibling
    /// login untouched — the whole point of per-provider scoping.
    @Test("wafer round trip and clear preserve unrelated scopes")
    func waferIsolation() throws {
        let home = try tempHome()
        try storeAPIKey(grokHome: home, apiKey: "xai-secret")
        try storePerplexityAPIKey(grokHome: home, apiKey: "pplx-secret")
        try storeWaferAPIKey(grokHome: home, apiKey: "wafer-secret")

        #expect(readWaferAPIKey(grokHome: home) == "wafer-secret")
        #expect(waferAPIKeyIsConfigured(grokHome: home))

        try clearWaferAPIKey(grokHome: home)

        #expect(readWaferAPIKey(grokHome: home) == nil)
        #expect(!waferAPIKeyIsConfigured(grokHome: home))
        #expect(readAPIKey(grokHome: home) == "xai-secret")
        #expect(readPerplexityAPIKey(grokHome: home) == "pplx-secret")
    }

    /// Provenance: `empty_wafer_key_clears_only_its_scope`, storage.rs:801-811.
    /// An all-whitespace key clears rather than stores, so a blanked-out
    /// settings field cannot persist an unusable credential.
    @Test("an all-whitespace key clears only its own scope")
    func whitespaceClears() throws {
        let home = try tempHome()
        try storeWaferAPIKey(grokHome: home, apiKey: "wafer-secret")
        try storeAPIKey(grokHome: home, apiKey: "xai-secret")

        try storeWaferAPIKey(grokHome: home, apiKey: "  ")

        #expect(readWaferAPIKey(grokHome: home) == nil)
        #expect(readAPIKey(grokHome: home) == "xai-secret")
    }

    /// Provenance: `kimi_platform_migrates_existing_scope_and_code_is_fully_isolated`,
    /// storage.rs:692-728.
    @Test("clearing Kimi Code preserves the migration-compatible Platform scope")
    func kimiIsolation() throws {
        let home = try tempHome()
        try storeProviderAPIKey(grokHome: home, provider: "kimi", apiKey: "platform-secret")
        try storeKimiAPIKey(grokHome: home, endpoint: .code, apiKey: "code-secret")

        #expect(readKimiAPIKey(grokHome: home, endpoint: .platform) == "platform-secret")
        #expect(readKimiAPIKey(grokHome: home, endpoint: .code) == "code-secret")

        try clearKimiAPIKey(grokHome: home, endpoint: .code)

        #expect(!kimiAPIKeyIsConfigured(grokHome: home, endpoint: .code))
        #expect(readProviderAPIKey(grokHome: home, provider: "kimi") == "platform-secret")

        try clearKimiAPIKey(grokHome: home, endpoint: .platform)
        #expect(readProviderAPIKey(grokHome: home, provider: "kimi") == nil)
    }

    /// Provenance: `store_scoped_api_key`, storage.rs:466-484 — a stored key
    /// is a `GrokAuth { key, auth_mode: ApiKey, ..Default::default() }`, and
    /// `Default` sets `coding_data_retention_opt_out` to `true`
    /// (model.rs:239 via `default_coding_data_retention_opt_out`).
    @Test("a stored scoped key writes the Rust GrokAuth default shape")
    func storedKeyShape() throws {
        let home = try tempHome()
        try storeWaferAPIKey(grokHome: home, apiKey: "wafer-secret")

        let root = try readAuthFile(home)
        let entry = try #require(root["wafer::api_key"] as? [String: Any])
        #expect(entry["key"] as? String == "wafer-secret")
        #expect(entry["auth_mode"] as? String == "api_key")
        #expect(entry["coding_data_retention_opt_out"] as? Bool == true)
        #expect(entry["user_id"] as? String == "")
        // Every `skip_serializing_if` optional must be absent, not null.
        for absent in ["email", "refresh_token", "expires_at", "oidc_issuer",
                       "oidc_client_id", "team_id", "team_blocked_reasons"] {
            #expect(entry[absent] == nil, "\(absent) must be omitted, not null")
        }
    }
}

@Suite("Auth store round trip of a Rust-written file")
struct AuthStoreRoundTripTests {
    /// A hand-written multi-scope auth.json in exactly the Rust Serialize
    /// shape. Every scope in it must survive a read/modify/write cycle that
    /// touches only one of them.
    ///
    /// Provenance: `GrokAuth` Serialize, model.rs:57-117; scope keys
    /// storage.rs:14 and :441-443.
    private static let goldenAuthJSON = """
    {
      "kimi_code::api_key" : {
        "auth_mode" : "api_key",
        "coding_data_retention_opt_out" : true,
        "create_time" : "2026-01-04T12:00:00.000Z",
        "key" : "kimi-code-secret",
        "user_id" : ""
      },
      "perplexity::api_key" : {
        "auth_mode" : "api_key",
        "coding_data_retention_opt_out" : true,
        "create_time" : "2026-01-04T12:00:00.000Z",
        "key" : "pplx-secret",
        "user_id" : ""
      },
      "wafer::api_key" : {
        "auth_mode" : "api_key",
        "coding_data_retention_opt_out" : true,
        "create_time" : "2026-01-04T12:00:00.000Z",
        "key" : "wafer-secret",
        "user_id" : ""
      },
      "xai::api_key" : {
        "auth_mode" : "oidc",
        "coding_data_retention_opt_out" : false,
        "create_time" : "2026-01-04T12:00:00.000Z",
        "email" : "user@example.com",
        "expires_at" : "2026-02-03T12:00:00.000Z",
        "key" : "xai-session-token",
        "oidc_client_id" : "grok-cli",
        "oidc_issuer" : "https://accounts.x.ai",
        "refresh_token" : "rt-secret",
        "team_blocked_reasons" : [
          "BLOCKED_REASON_NO_LOGS"
        ],
        "team_id" : "team-1",
        "user_id" : "user-1"
      }
    }
    """

    @Test("every scope decodes with its Rust-side field values")
    func decodesAllScopes() throws {
        let home = try tempHome()
        try writeAuthFile(home, Self.goldenAuthJSON)
        let store = try readAuthJSON(at: home.appendingPathComponent("auth.json"))

        #expect(store.count == 4)
        #expect(store[waferAPIKeyScope]?.key == "wafer-secret")
        #expect(store[kimiCodeAPIKeyScope]?.key == "kimi-code-secret")
        #expect(store[perplexityAPIKeyScope]?.key == "pplx-secret")

        let xai = try #require(store[apiKeyScope])
        #expect(xai.authMode == .oidc)
        #expect(xai.email == "user@example.com")
        #expect(xai.refreshToken == "rt-secret")
        #expect(xai.oidcIssuer == "https://accounts.x.ai")
        #expect(xai.teamBlockedReasons == ["BLOCKED_REASON_NO_LOGS"])
        #expect(xai.codingDataRetentionOptOut == false)
        #expect(xai.isZDRTeam)
        #expect(xai.isDataCollectionDisabled)
    }

    /// Reading a Rust file and writing it back must not lose or alter any
    /// scope. This is the property that makes a mixed Rust/Swift home
    /// directory safe.
    @Test("read then write preserves every scope byte-for-byte in value terms")
    func roundTripIsLossless() throws {
        let home = try tempHome()
        let path = home.appendingPathComponent("auth.json")
        try writeAuthFile(home, Self.goldenAuthJSON)

        let before = try readAuthJSON(at: path)
        try writeAuthJSON(at: path, store: before)
        let after = try readAuthJSON(at: path)

        #expect(after == before)
    }

    /// Writing one provider's key must leave the other three scopes intact —
    /// the failure mode per-provider scoping exists to prevent.
    @Test("writing one scope leaves the other three untouched")
    func siblingScopesSurviveAWrite() throws {
        let home = try tempHome()
        try writeAuthFile(home, Self.goldenAuthJSON)

        try storeWaferAPIKey(grokHome: home, apiKey: "rotated-wafer")

        let store = try readAuthJSON(at: home.appendingPathComponent("auth.json"))
        #expect(store.count == 4)
        #expect(store[waferAPIKeyScope]?.key == "rotated-wafer")
        #expect(store[apiKeyScope]?.key == "xai-session-token")
        #expect(store[apiKeyScope]?.refreshToken == "rt-secret")
        #expect(store[kimiCodeAPIKeyScope]?.key == "kimi-code-secret")
        #expect(store[perplexityAPIKeyScope]?.key == "pplx-secret")
    }
}

@Suite("SentCredential")
struct SentCredentialTests {
    /// Provenance: `error.rs:88-100` and the round-trip test at error.rs:975-991.
    @Test("wire tokens, and an unknown variant degrades to unknown")
    func wireTokens() throws {
        func decode(_ json: String) throws -> SentCredential {
            try JSONDecoder().decode(SentCredential.self, from: Data(json.utf8))
        }
        #expect(try decode("\"sent\"") == .sent)
        #expect(try decode("\"missing\"") == .missing)
        #expect(try decode("\"unknown\"") == .unknown)
        // A newer peer's variant must not fail the containing payload.
        #expect(try decode("\"some-future-variant\"") == .unknown)

        let encoded = try JSONEncoder().encode(SentCredential.missing)
        #expect(String(data: encoded, encoding: .utf8) == "\"missing\"")
    }

    /// `from_sent_fragment`, error.rs:118: presence of the captured credential
    /// fragment is the whole signal.
    @Test("fromSentFragment classifies by fragment presence")
    func fromFragment() {
        #expect(SentCredential.fromSentFragment("…abcd") == .sent)
        #expect(SentCredential.fromSentFragment(nil) == .missing)
    }

    @Test("default is unknown, which fails closed toward terminating")
    func defaultIsUnknown() {
        #expect(SentCredential.default == .unknown)
        #expect(SentCredential.unknown.isUnknown)
        #expect(!SentCredential.unknown.isMissing)
    }
}

@Suite("AuthRetrySchedule")
struct AuthRetryScheduleTests {
    private func clock(monotonic: TimeInterval, wall: TimeInterval) -> DualClock {
        DualClock(monotonicSeconds: monotonic, wallSeconds: wall)
    }

    /// Provenance: auth_retry.rs:131-168 and the delay invariant documented at
    /// auth_retry.rs:66-72. The 1s/2s/4s sequence is the load-bearing part:
    /// the Rust comment records a field incident where a mis-built backoff
    /// produced 11.57 days of silent hang.
    @Test("credentialed 401s back off 1s, 2s, 4s and then exhaust")
    func chargedBackoff() {
        var s = AuthRetrySchedule()
        let now = clock(monotonic: 0, wall: 0)
        let first = s.onRecovered401(.sent, now: now)
        let second = s.onRecovered401(.sent, now: now)
        let third = s.onRecovered401(.sent, now: now)
        let fourth = s.onRecovered401(.sent, now: now)
        #expect(first == .backoff(attempt: 1, delaySeconds: 1))
        #expect(second == .backoff(attempt: 2, delaySeconds: 2))
        #expect(third == .backoff(attempt: 3, delaySeconds: 4))
        #expect(fourth == .exhausted)
        #expect(s.incidentCounts == (rejections: 4, authenticated: 4))
    }

    /// Unknown provenance must charge the budget exactly like `sent`
    /// (error.rs:94-97) — retrying forever on an unclassifiable 401 is the
    /// failure mode being avoided.
    @Test("unknown provenance charges the budget like sent, but is not counted as authenticated")
    func unknownChargesLikeSent() {
        var s = AuthRetrySchedule()
        let now = clock(monotonic: 0, wall: 0)
        let decision = s.onRecovered401(.unknown, now: now)
        #expect(decision == .backoff(attempt: 1, delaySeconds: 1))
        #expect(s.incidentCounts == (rejections: 1, authenticated: 0))
    }

    /// A 401 for a request that carried no credential is not evidence against
    /// the credential, so it charges nothing (auth_retry.rs:143-152).
    @Test("missing-credential 401s are uncharged and never exhaust the slot budget")
    func unchargedResubmits() {
        var s = AuthRetrySchedule()
        let now = clock(monotonic: 0, wall: 0)
        for i in 1...10 {
            let decision = s.onRecovered401(.missing, now: now)
            #expect(decision == .unchargedResubmit(resubmit: UInt32(i)))
        }
        #expect(s.unchargedRejections == 10)
        // Slots are untouched, so a real credentialed rejection still gets the
        // full escalating budget.
        let charged = s.onRecovered401(.sent, now: now)
        #expect(charged == .backoff(attempt: 1, delaySeconds: 1))
    }

    /// auth_retry.rs:96-99: the runaway guard trips at 51, one past the cap.
    @Test("the runaway guard trips one past maxUnchargedResubmits")
    func runawayGuard() {
        var s = AuthRetrySchedule()
        let now = clock(monotonic: 0, wall: 0)
        for _ in 0..<Int(AuthRetrySchedule.maxUnchargedResubmits) {
            _ = s.onRecovered401(.missing, now: now)
        }
        let tripped = s.onRecovered401(.missing, now: now)
        #expect(tripped == .runawayGuard(rejections: 51))
    }

    /// Wall time outgrowing awake time by 30s+ means the machine slept, and
    /// separate wakes are independent 401 events (auth_retry.rs:172-194).
    @Test("an incident spanning a suspend resets the slot budget")
    func suspendReset() {
        var s = AuthRetrySchedule()
        let start = clock(monotonic: 100, wall: 1000)
        _ = s.onRecovered401(.sent, now: start)
        _ = s.onRecovered401(.sent, now: start)

        // 1s awake, 600s wall → 599s of suspend.
        let afterSleep = clock(monotonic: 101, wall: 1600)
        let didReset = s.resetIfIncidentSpansSuspend(now: afterSleep)
        #expect(didReset)
        let afterReset = s.onRecovered401(.sent, now: afterSleep)
        #expect(afterReset == .backoff(attempt: 1, delaySeconds: 1))
    }

    /// Drift below the threshold is NTP jitter, not a sleep cycle.
    @Test("sub-threshold drift is not treated as a suspend")
    func subThresholdDriftIgnored() {
        var s = AuthRetrySchedule()
        let start = clock(monotonic: 100, wall: 1000)
        _ = s.onRecovered401(.sent, now: start)
        // 10s of drift, below the 30s minimum.
        let didReset = s.resetIfIncidentSpansSuspend(now: clock(monotonic: 101, wall: 1011))
        #expect(!didReset)
    }

    /// With no open incident there is nothing to reset (auth_retry.rs:180-182).
    @Test("no open incident means no suspend reset")
    func noIncidentNoReset() {
        var s = AuthRetrySchedule()
        let didReset = s.resetIfIncidentSpansSuspend(now: clock(monotonic: 999, wall: 99999))
        #expect(!didReset)
    }

    /// auth_retry.rs:184-186: after the cap, a fault that persists across
    /// wakes must be allowed to exhaust rather than reset forever.
    @Test("suspend resets stop at the cap so a persistent fault can exhaust")
    func suspendResetCap() {
        var s = AuthRetrySchedule()
        var monotonic: TimeInterval = 0
        var wall: TimeInterval = 0
        for _ in 0..<Int(AuthRetrySchedule.maxSuspendResets) {
            _ = s.onRecovered401(.sent, now: clock(monotonic: monotonic, wall: wall))
            monotonic += 1
            wall += 600
            let didReset = s.resetIfIncidentSpansSuspend(now: clock(monotonic: monotonic, wall: wall))
            #expect(didReset)
        }
        _ = s.onRecovered401(.sent, now: clock(monotonic: monotonic, wall: wall))
        monotonic += 1
        wall += 600
        let cappedReset = s.resetIfIncidentSpansSuspend(now: clock(monotonic: monotonic, wall: wall))
        #expect(!cappedReset)
    }

    /// A success ends every open failure narrative, including the
    /// success-free-stretch counters (auth_retry.rs:196-199).
    @Test("resetOnSuccess clears slots, uncharged rejections and suspend resets")
    func resetOnSuccess() {
        var s = AuthRetrySchedule()
        let now = clock(monotonic: 0, wall: 0)
        _ = s.onRecovered401(.sent, now: now)
        _ = s.onRecovered401(.missing, now: now)
        s.resetOnSuccess()
        #expect(s.unchargedRejections == 0)
        #expect(s.incidentCounts == (rejections: 0, authenticated: 0))
        let afterSuccess = s.onRecovered401(.sent, now: now)
        #expect(afterSuccess == .backoff(attempt: 1, delaySeconds: 1))
    }

    /// Uncharged rejections deliberately survive a suspend reset — they track
    /// a success-free stretch, not one incident (auth_retry.rs:188-192).
    @Test("uncharged rejections survive a suspend reset")
    func unchargedSurvivesSuspend() {
        var s = AuthRetrySchedule()
        let start = clock(monotonic: 0, wall: 0)
        _ = s.onRecovered401(.missing, now: start)
        _ = s.onRecovered401(.missing, now: start)
        _ = s.onRecovered401(.sent, now: start)
        let didReset = s.resetIfIncidentSpansSuspend(now: clock(monotonic: 1, wall: 600))
        #expect(didReset)
        #expect(s.unchargedRejections == 2)
    }

    /// `human_duration`, auth_retry.rs:29-39.
    @Test("humanDuration renders seconds, minutes and hours compactly")
    func humanDurationRendering() {
        #expect(humanDuration(seconds: 12) == "12s")
        #expect(humanDuration(seconds: 59) == "59s")
        #expect(humanDuration(seconds: 247) == "4m7s")
        #expect(humanDuration(seconds: 7380) == "2h3m")
    }
}

@Suite("requiresManualReauth")
struct RequiresManualReauthTests {
    /// Provenance: `AuthManager::requires_manual_reauth`, manager.rs:2191-2210.
    /// Each arm below maps to one early return in that function.
    @Test("a sticky IdP verdict or no refresh authority requires manual login")
    func trueArms() {
        #expect(requiresManualReauth(
            permanentFailureBlocksUnattendedRetry: true,
            hasRefresherAttached: true,
            inMemoryTokenIsRefreshable: true,
            diskCredentialHasRefreshToken: true
        ))
        // Static-key manager: nothing can heal an expired credential silently.
        #expect(requiresManualReauth(
            permanentFailureBlocksUnattendedRetry: false,
            hasRefresherAttached: false,
            inMemoryTokenIsRefreshable: true,
            diskCredentialHasRefreshToken: true
        ))
        // Refresher attached but nothing refreshable anywhere.
        #expect(requiresManualReauth(
            permanentFailureBlocksUnattendedRetry: false,
            hasRefresherAttached: true,
            inMemoryTokenIsRefreshable: false,
            diskCredentialHasRefreshToken: false
        ))
    }

    /// Either a refreshable in-memory credential or a sibling's refresh token
    /// on disk lets a later refresh succeed without the user.
    @Test("a refreshable credential in memory or on disk self-heals")
    func falseArms() {
        #expect(!requiresManualReauth(
            permanentFailureBlocksUnattendedRetry: false,
            hasRefresherAttached: true,
            inMemoryTokenIsRefreshable: true,
            diskCredentialHasRefreshToken: false
        ))
        #expect(!requiresManualReauth(
            permanentFailureBlocksUnattendedRetry: false,
            hasRefresherAttached: true,
            inMemoryTokenIsRefreshable: false,
            diskCredentialHasRefreshToken: true
        ))
    }
}
