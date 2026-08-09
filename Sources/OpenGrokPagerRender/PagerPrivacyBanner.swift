// PagerPrivacyBanner.swift
//
// The coding-data privacy banner's gate and ack plumbing, ported from the
// Rust reference at pin 650c1db7 — state and decisions only. Nothing here
// paints: the banner itself (upstream's welcome-frame chrome slot,
// app_view.rs:4847-4860) is a later slice, gated on the retention write
// client. The rollout flag defaults FALSE (app_view.rs:2025), so this whole
// surface stays dark until a remote settings payload or an explicit env
// override turns it on.
//
// What lives here:
//  - `PagerPrivacyBannerState` — the banner-relevant slice of upstream's
//    `AppView` fields (app_view.rs:1264-1274) plus the auth/trust/access
//    preconditions the gate reads, with `shouldShow` ported arm-for-arm
//    from `privacy_banner_should_show` (app_view.rs:1705-1731).
//  - `privacyBannerReshowElapsed` — app_view.rs:1394-1407, including the
//    unparseable-ack FAIL-OPEN arm.
//  - The env-over-remote resolvers for `privacy_notice_rollout` and
//    `privacy_banner_reshow_days` — the first readers of the two keys
//    `RemoteSettings` has parsed reader-less since they landed
//    (event_loop.rs:1007-1021 is the startup resolution;
//    acp_handler/settings.rs:135-150 re-applies the same env-wins rule on
//    live updates).
//  - `PagerPrivacyBannerAckStore` — `[privacy].privacy_banner_acked`
//    read/write (settings_writes.rs:406-412 over util/config/mcp.rs:62-72).

import Foundation
import OpenGrokConfig
import OpenGrokConfigTypes

// MARK: - Env-over-remote resolvers

/// `GROK_PRIVACY_NOTICE_ROLLOUT`, spelled byte-identically to upstream
/// (event_loop.rs:1007) so an environment written for the Rust binary
/// drives this port the same way.
public let privacyNoticeRolloutEnvVar = "GROK_PRIVACY_NOTICE_ROLLOUT"

/// `GROK_PRIVACY_BANNER_RESHOW_DAYS` (event_loop.rs:1014).
public let privacyBannerReshowDaysEnvVar = "GROK_PRIVACY_BANNER_RESHOW_DAYS"

/// Resolve the rollout flag: env wins over remote, absent-everything is
/// FALSE (event_loop.rs:1007-1013 `env_bool(..).or(remote).unwrap_or(false)`).
///
/// Deliberately NOT the `BoolFlag` requirements/config/managed tier builder
/// the E22 `background_loops` resolver rides: upstream resolves these two
/// keys with plain env-then-remote chaining and no config.toml tier at all,
/// and inventing extra tiers here would let a repo or managed layer switch
/// on a consent upsell upstream says only the server cohort (or a local dev
/// override) may.
public func resolvePrivacyNoticeRollout(
    remoteSettings: RemoteSettings?,
    environment: [String: String]
) -> Bool {
    OpenGrokConfigTypes.envBool(privacyNoticeRolloutEnvVar, environment: environment)
        ?? remoteSettings?.privacyNoticeRollout
        ?? false
}

/// Resolve the re-show window: env wins over remote, no default
/// (event_loop.rs:1014-1021). An unparseable env value falls through to the
/// remote value — upstream's `.ok().and_then(parse.ok())` chain, not a hard
/// override to nil.
public func resolvePrivacyBannerReshowDays(
    remoteSettings: RemoteSettings?,
    environment: [String: String]
) -> UInt64? {
    if let raw = environment[privacyBannerReshowDaysEnvVar],
       let parsed = UInt64(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
        return parsed
    }
    return remoteSettings?.privacyBannerReshowDays
}

// MARK: - Re-show window

/// Whether the re-show window after an ack has elapsed
/// (`privacy_banner_reshow_elapsed`, app_view.rs:1394-1407).
///
/// `reshowDays` nil or 0 = never re-show once acked. An UNPARSEABLE ack
/// fails OPEN (returns true, the banner shows again) — upstream's explicit
/// arm (app_view.rs:1399-1401), pinned by test. Do not "harden" this to
/// fail closed: a corrupt timestamp hiding a consent upsell forever is the
/// silent outcome that arm exists to prevent, and the cost of the open
/// direction is only a re-shown banner.
///
/// Upstream guards `checked_add_signed` overflow into "not elapsed"
/// (app_view.rs:1403-1405); `Date.addingTimeInterval` saturates into the
/// distant future for the same inputs, which lands on the same answer
/// without a separate arm.
public func privacyBannerReshowElapsed(
    ackedAt: String,
    reshowDays: UInt64?,
    now: Date = Date()
) -> Bool {
    guard let days = reshowDays, days > 0 else { return false }
    guard let acked = parsePrivacyBannerAckTimestamp(ackedAt) else {
        return true
    }
    let next = acked.addingTimeInterval(TimeInterval(days) * 86_400)
    return now >= next
}

/// RFC 3339 parse, fractional-second tolerant — the same two-formatter
/// shape the auth store uses (`OpenGrokAuth/Storage.swift`), because
/// `ISO8601DateFormatter` refuses fractions unless asked and refuses their
/// absence when asked.
func parsePrivacyBannerAckTimestamp(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: value)
}

/// The ack timestamp the port writes: RFC 3339 UTC, seconds precision, `Z`
/// suffix — upstream's `Utc::now().to_rfc3339_opts(SecondsFormat::Secs,
/// true)` (dispatch/status.rs:493).
public func privacyBannerAckTimestamp(now: Date = Date()) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: now)
}

// MARK: - Gate state

/// The banner-relevant slice of upstream's `AppView`, resolved by the live
/// composition and consumed (in a later slice) by the frame builder.
///
/// Pure by the `ShareExportGate` precedent: inputs arrive resolved, so the
/// decision is testable without stores, auth files, or a live session.
/// Field defaults mirror `AppView`'s construction defaults
/// (app_view.rs:2020-2033): rollout FALSE, opt-out TRUE, no team, no ack,
/// `zdr_access_enabled` FALSE — a default-constructed state never shows.
public struct PagerPrivacyBannerState: Sendable, Equatable {
    /// `screen_mode.is_minimal()` (app_view.rs:1706) — minimal mode has no
    /// welcome chrome to host the banner.
    public var minimalMode: Bool
    /// Remote `privacy_notice_rollout` after env-over-remote resolution
    /// (cohort on for this user). Default FALSE (app_view.rs:2025).
    public var privacyNoticeRollout: Bool
    /// Remote `privacy_banner_reshow_days`. nil/0 = never re-show after ack
    /// (app_view.rs:1271-1272).
    public var privacyBannerReshowDays: UInt64?
    /// Local `[privacy].privacy_banner_acked`, RFC 3339 UTC
    /// (app_view.rs:1273-1274).
    public var privacyBannerAcked: String?
    /// Enterprise Zero Data Retention team (app_view.rs:1264).
    public var isZDR: Bool
    /// Remote `zdr_access_enabled`; default FALSE (app_view.rs:2033).
    public var zdrAccessEnabled: Bool
    /// Team name from auth; `nil` for personal sessions (app_view.rs:1262).
    public var teamName: String?
    /// Team role from auth (app_view.rs:1266).
    public var teamRole: String?
    /// TRUE means the user is opted OUT of coding-data retention — the
    /// population the banner upsells (app_view.rs:1267-1268). Polarity is
    /// load-bearing: opted-IN users must never see it.
    public var codingDataRetentionOptOut: Bool
    /// Upstream `AuthState::Done` (app_view.rs:1718).
    public var authDone: Bool
    /// Upstream `has_access()` = no remote gate (app_view.rs:1678-1680).
    public var hasAccess: Bool
    /// Upstream `TrustState::Done` (app_view.rs:1721).
    public var trustDone: Bool

    public init(
        minimalMode: Bool = false,
        privacyNoticeRollout: Bool = false,
        privacyBannerReshowDays: UInt64? = nil,
        privacyBannerAcked: String? = nil,
        isZDR: Bool = false,
        zdrAccessEnabled: Bool = false,
        teamName: String? = nil,
        teamRole: String? = nil,
        codingDataRetentionOptOut: Bool = true,
        authDone: Bool = false,
        hasAccess: Bool = true,
        trustDone: Bool = false
    ) {
        self.minimalMode = minimalMode
        self.privacyNoticeRollout = privacyNoticeRollout
        self.privacyBannerReshowDays = privacyBannerReshowDays
        self.privacyBannerAcked = privacyBannerAcked
        self.isZDR = isZDR
        self.zdrAccessEnabled = zdrAccessEnabled
        self.teamName = teamName
        self.teamRole = teamRole
        self.codingDataRetentionOptOut = codingDataRetentionOptOut
        self.authDone = authDone
        self.hasAccess = hasAccess
        self.trustDone = trustDone
    }

    /// Coding-data preference is team-admin-owned for non-admin members
    /// (`is_team_non_admin`, app_view.rs:1686-1692). Case-insensitive on
    /// the role, exactly upstream's `eq_ignore_ascii_case`.
    public var isTeamNonAdmin: Bool {
        teamName != nil && teamRole?.lowercased() != "admin"
    }

    /// `is_zdr_blocked` (app_view.rs:1523-1525).
    public var isZDRBlocked: Bool {
        isZDR && !zdrAccessEnabled
    }

    /// `privacy_banner_should_show` (app_view.rs:1705-1731), arm for arm.
    ///
    /// The opt-out arm reads inverted on first sight and is correct: the
    /// banner only upsells users who are currently opted OUT, so
    /// `codingDataRetentionOptOut == false` (already opted in) hides it.
    public func shouldShow(now: Date = Date()) -> Bool {
        if minimalMode {
            return false
        }
        if !privacyNoticeRollout {
            return false
        }
        if isZDR || isTeamNonAdmin {
            return false
        }
        if !codingDataRetentionOptOut {
            return false
        }
        if !authDone || !hasAccess || isZDRBlocked || !trustDone {
            return false
        }
        switch privacyBannerAcked {
        case .none:
            return true
        case .some(let ackedAt):
            return privacyBannerReshowElapsed(
                ackedAt: ackedAt,
                reshowDays: privacyBannerReshowDays,
                now: now
            )
        }
    }
}

// MARK: - Ack persistence

/// `[privacy].privacy_banner_acked` in `config.toml` — the local dismiss
/// timestamp, read at startup (event_loop.rs:1022-1029) and written on
/// dismiss (`set_privacy_banner_acked`, settings_writes.rs:406-412).
///
/// Write-seam choice, deliberate: this is the raw parse-mutate-serialize
/// shape of upstream's `update_config` (util/config/persist.rs:244-254) —
/// read the file fresh, splice one dotted path, write atomically — built on
/// the same table surgery and atomic replace `PagerSettingsStore` uses. It
/// does NOT go through `PagerSettingsStore.write` itself because that store
/// is keyed by `PagerSettingMeta` registry rows, and every registry row is
/// a row the settings modal renders: upstream has no settings row for the
/// ack (`PrivacyConfig`, util/config/mcp.rs:62-72, is written only by the
/// dismiss effect), so registering one would put a phantom entry on a real
/// UI surface to reach a file path this helper reaches directly.
///
/// Read-modify-write against the file on every call, not a cached tree —
/// the same reasoning as `PagerSettingsStore`: another process may have
/// edited `config.toml` since this one loaded, and re-reading is what keeps
/// the ack write from reverting someone else's change. Sibling `[privacy]`
/// keys survive because only the one dotted path is spliced.
public struct PagerPrivacyBannerAckStore: Sendable {
    public var configPath: URL

    public init(configPath: URL) {
        self.configPath = configPath
    }

    /// The persisted ack, or nil when the file, table, or key is absent or
    /// the value is not a string (upstream's tolerant startup read,
    /// event_loop.rs:1022-1029 — a broken config must not break launch).
    public func read() -> String? {
        guard let data = try? Data(contentsOf: configPath),
              let root = try? parseTOML(data) else { return nil }
        return root[path: ["privacy", "privacy_banner_acked"]]?.stringValue
    }

    /// Persist the ack. A missing or unparseable file becomes an empty tree
    /// (upstream `update_config`'s `unwrap_or_else(Table::new)`,
    /// persist.rs:249-250, and `PagerSettingsStore.write`'s identical
    /// fallback). Throws when a path segment holds a scalar where a table
    /// is needed (a hand-written `privacy = "…"` line must not be silently
    /// deleted) or the atomic replace fails; the caller owns rolling back
    /// any in-memory mirror.
    public func write(ackedAt: String) throws {
        var root = (try? Data(contentsOf: configPath)).flatMap { try? parseTOML($0) }
            ?? .table(TOMLTable())
        try setValue(
            .string(ackedAt),
            at: ["privacy", "privacy_banner_acked"],
            in: &root
        )
        try writeConfigFile(root, to: configPath)
    }
}
