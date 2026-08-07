// LiveAnnouncementsComposition.swift
//
// The live seam between `OpenGrokAnnouncements` and the running pager.
// `AnnouncementsService` is a complete library — types, hide-key state,
// fetch/cache — but nothing in `Sources/OpenGrokCLI` ever called it, so
// announcements never fetched and never rendered. This wires both halves:
//
//   1. **Fetch → cache, post-readiness, non-blocking.** Mirrors upstream's
//      `spawn_announcements_refresh` (`xai-grok-shell/src/agent/mvp_agent/
//      agent_ops.rs:1830`): a detached background task that polls
//      `/v1/settings` on the chat proxy and stores the feed. Never awaited on
//      the launch path — a slow or unreachable feed costs zero launch time.
//   2. **Cache → banner.** Reads the cache and the persistent hide-key set,
//      runs the upstream selection (`firstSessionAnnouncement`: critical wins
//      over promo, first non-hidden), and projects the result to the
//      plain-data `PagerAnnouncementBanner` the renderer paints.
//   3. **Hide dismissal.** Writes the selected announcement's hide key to the
//      persistent state store and re-derives the banner, so a re-launch does
//      not re-show hidden IDs.
//
// Two gates gate the fetch, mirroring upstream's resolve path
// (`fetch_remote_settings`, `agent_ops.rs:1967-1992`, and
// `resolve_remote_fetch_enabled`, `util/config/resolve/features.rs:40-54`):
//
//   * **Export boundary** (`XaiServicePolicy`): the feed rides xAI
//     infrastructure. When the active provider denies xAI export — a Codex
//     session — the request is never made at all, because issuing it would
//     tell xAI that this session exists. `AnnouncementsService.shouldRefresh`
//     already encodes this; the composition supplies the active provider's
//     policy. (Upstream's settings fetch does NOT carry this gate; the Swift
//     `AnnouncementsService` is deliberately stricter. Recorded as a
//     deliberate divergence — see `PORT_STATUS.md`.)
//   * **`features.remote_fetch`** (default true): the deployment knob that
//     disables all xAI-backend fetches (catalog + settings) on firewalled /
//     air-gapped installs. Upstream walks the policy layers first-match
//     (requirements > managed > user, default true); this port reads the
//     effective config base, which is the merge the rest of the composition
//     already uses. A denied remote_fetch suppresses the spawn entirely.

import Foundation
import OpenGrokAnnouncements
import OpenGrokConfig
import OpenGrokHTTP
import OpenGrokPagerRender
import OpenGrokPaths
import OpenGrokSamplingTypes

// MARK: - remote_fetch gate

/// Whether xAI-backend fetches (model catalog + remote settings/announcements)
/// are permitted. Mirrors upstream `resolve_remote_fetch_enabled`
/// (`util/config/resolve/features.rs:40-54`): the `features.remote_fetch`
/// knob, default true. Upstream walks the policy layers first-match
/// (requirements > managed > user) so a deployment can pin "never fetch";
/// this port reads the effective config base — the same merge
/// `LiveSessionServices` and the rest of the composition use — and defaults
/// to true when the key is absent or unreadable, matching upstream's
/// "fail open only when policy is genuinely absent."
///
/// Deliberately no env var: upstream's knob has none (an env var would be one
/// more way to re-arm the fetches this knob is meant to suppress).
public func resolveRemoteFetchEnabled(environment: [String: String]) -> Bool {
    let document = (try? ConfigLayers.load(environment: environment))?
        .effectiveConfigBase() ?? .table(TOMLTable())
    if case let .boolean(value)? = document[path: ["features", "remote_fetch"]] {
        return value
    }
    return true
}

// MARK: - Banner projection

/// Project the upstream-selected announcement to the plain-data banner the
/// renderer paints. `nil` when the slot is empty (no live, non-hidden
/// critical-or-promo). The renderer is given the already-resolved selection;
/// it does not re-derive critical-wins-over-promo or hidden filtering, so the
/// one upstream gate (`firstSessionAnnouncement`) stays the source of truth.
///
/// `now` is injectable so a test can pin expiry; production passes `Date()`.
public func announcementBanner(
    from announcements: [RemoteAnnouncement],
    hiddenIDs: Set<String>,
    now: Date = Date()
) -> PagerAnnouncementBanner? {
    guard let selected = firstSessionAnnouncement(announcements, hiddenIDs: hiddenIDs, now: now) else {
        return nil
    }
    let isCritical = selected.severity == "critical"
    let severity: PagerAnnouncementBanner.Severity = isCritical ? .critical : .promo
    let dismissible = isDismissible(selected)
    // The CTA gate is the promo's alone — a critical never paints a button.
    let cta: (label: String, url: String)? = isCritical ? nil : usableCTA(selected)
    // Caption is pinned-promo-only (dismissible promos keep Ctrl+O on YOLO).
    let caption: String? = (!dismissible) ? usableCTACaption(selected) : nil
    return PagerAnnouncementBanner(
        severity: severity,
        title: trimmedNonEmpty(selected.title),
        message: trimmedNonEmpty(selected.message),
        dismissible: dismissible,
        ctaLabel: cta?.label,
        ctaURL: cta?.url,
        ctaCaption: caption
    )
}

/// Trim whitespace and return `nil` when the result is empty, so a missing
/// or blank field paints nothing rather than a blank span.
func trimmedNonEmpty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

// MARK: - Composition

/// The live announcements surface for one session: fetch → cache → banner,
/// plus the hide dismissal. An actor because the hide-key state store is
/// async and the banner is re-derived after a hide; the renderer reads the
/// cached projection synchronously between refreshes.
public actor LiveAnnouncementsComposition {
    private let service: AnnouncementsService
    private let exportPolicy: XaiServicePolicy
    private let remoteFetchEnabled: Bool
    private let proxyBaseURL: URL
    private let authorization: String?
    /// The last-derived banner projection. The renderer reads this through
    /// `currentBanner()`; it is refreshed after construction, after a hide,
    /// and (in a fuller port) after a pushed `x.ai/announcements/update`.
    private var cachedBanner: PagerAnnouncementBanner?
    /// The hide key of the currently-visible banner, so `hideCurrent()`
    /// knows what to persist without re-reading the cache.
    private var currentHideKey: String?

    public init(
        service: AnnouncementsService,
        exportPolicy: XaiServicePolicy,
        remoteFetchEnabled: Bool,
        proxyBaseURL: URL,
        authorization: String? = nil
    ) {
        self.service = service
        self.exportPolicy = exportPolicy
        self.remoteFetchEnabled = remoteFetchEnabled
        self.proxyBaseURL = proxyBaseURL
        self.authorization = authorization
    }

    /// Build the live composition for a session. The transport is the same
    /// one the sampler/catalog use; the cache lives under `openGrokHome`; the
    /// hide-key state lives under the resolved state directory (which honors
    /// `OPENGROK_HOME`, so hermetic launches and tests see the same store).
    ///
    /// `proxyBaseURL` is the chat-proxy base with the `/v1` suffix stripped —
    /// `AnnouncementsService` appends the full `v1/settings` path, matching
    /// upstream's `{cli_chat_proxy_base_url}/settings` where the base already
    /// carries `/v1`. Passing the proxy URL with `/v1` still attached would
    /// double the segment.
    public static func live(
        transport: any HTTPTransport,
        openGrokHome: URL,
        environment: [String: String],
        provider: ModelProvider,
        proxyBaseURL: String,
        authorization: String? = nil
    ) -> LiveAnnouncementsComposition {
        let service = AnnouncementsService(
            transport: transport,
            store: AnnouncementsCacheStore(openGrokHome: openGrokHome),
            stateStore: AnnouncementStateStore(environment: environment)
        )
        let stripped = stripTrailingV1(proxyBaseURL)
        return LiveAnnouncementsComposition(
            service: service,
            exportPolicy: provider.profile.xaiServices,
            remoteFetchEnabled: resolveRemoteFetchEnabled(environment: environment),
            proxyBaseURL: stripped,
            authorization: authorization
        )
    }

    /// Post-readiness background refresh spawn. Non-blocking: returns
    /// immediately, the fetch runs detached. Honors both gates — export
    /// boundary and `remote_fetch` — so a denied provider or a firewalled
    /// deployment issues no request at all. `AnnouncementsService` already
    /// checks the export boundary and cache freshness inside
    /// `shouldRefresh`; the `remote_fetch` gate is checked here because the
    /// service has no notion of it (upstream's gate lives one layer above the
    /// fetch, in `fetch_remote_settings`).
    ///
    /// `nonisolated` so the composition can fire it synchronously from
    /// `makeAgentStack` without an `await`: it only reads `let` properties and
    /// hands them to `AnnouncementsService.refreshInBackground`, which itself
    /// detaches the actual network call. No actor state is touched.
    nonisolated public func spawnBackgroundRefresh(now: Date = Date()) {
        guard remoteFetchEnabled else { return }
        guard exportPolicy.allows else { return }
        service.refreshInBackground(
            baseURL: proxyBaseURL,
            exportPolicy: exportPolicy,
            authorization: authorization,
            now: now
        )
    }

    /// Re-derive the banner from the cache + persistent hide-key state and
    /// cache the projection. The renderer reads the result through
    /// `currentBanner()`. Called after construction and after a hide.
    @discardableResult
    public func refreshVisibleBanner(now: Date = Date()) async -> PagerAnnouncementBanner? {
        let hidden = await service.stateStore.read()
        let cached = service.cachedStartupAnnouncements(hiddenIDs: hidden, now: now)
        let banner = announcementBanner(from: cached, hiddenIDs: hidden, now: now)
        cachedBanner = banner
        currentHideKey = banner.flatMap { selected in
            // Re-derive the hide key from the live selection so `hideCurrent`
            // persists the exact announcement the banner is showing. The
            // selection above already filtered hidden IDs, so this is the
            // first visible (non-hidden) item.
            rederiveHideKey(from: cached, hiddenIDs: hidden, now: now)
        }
        return banner
    }

    /// The last-derived banner projection. Synchronous by design: the
    /// renderer reads this between refreshes, so a frame never blocks on
    /// the hide-key state store.
    public func currentBanner() -> PagerAnnouncementBanner? {
        cachedBanner
    }

    /// Persist a hide for the currently-visible banner and re-derive the
    /// next one. Returns the new banner (the next non-hidden announcement, or
    /// `nil` when hiding closed the slot). A pinned (`dismissible == false`)
    /// banner has no hide affordance and is never hidden through this path —
    /// the renderer simply does not call `hideCurrent()` for it.
    @discardableResult
    public func hideCurrent() async -> PagerAnnouncementBanner? {
        guard let key = currentHideKey else { return cachedBanner }
        var hidden = await service.stateStore.read()
        hidden.insert(key)
        await service.stateStore.write(hidden)
        return await refreshVisibleBanner()
    }

    /// Apply a pushed `x.ai/announcements/update` and re-derive the banner.
    /// A push is only accepted when its generation is at least the cached one
    /// (the service enforces this); a stale push is a no-op.
    @discardableResult
    public func applyPush(_ refreshed: AnnouncementsRefreshed, now: Date = Date()) async -> PagerAnnouncementBanner? {
        _ = service.applyPush(refreshed, now: now)
        return await refreshVisibleBanner(now: now)
    }

    /// Synchronous refresh: await the real fetch (rather than the detached
    /// background spawn) and re-derive the banner. The composition's
    /// `spawnBackgroundRefresh` is the production path — fire-and-forget, the
    /// cache lands whenever the network responds — which is wrong for a test
    /// that needs to assert against the cache the moment the call returns. This
    /// is the awaitable twin: same gates, same fetch, same cache write, but the
    /// caller sees completion. Also useful as a future "refresh now" entry point.
    @discardableResult
    public func refreshAndWait(now: Date = Date()) async throws -> AnnouncementsCache? {
        guard remoteFetchEnabled else { return nil }
        guard exportPolicy.allows else { return nil }
        let cache = try await service.refresh(
            baseURL: proxyBaseURL,
            exportPolicy: exportPolicy,
            authorization: authorization,
            now: now
        )
        _ = await refreshVisibleBanner(now: now)
        return cache
    }
}

// MARK: - Helpers

/// Strip a trailing `/v1` segment from a proxy base URL so
/// `AnnouncementsService` can append the full `v1/settings` path without
/// doubling it. Upstream's `cli_chat_proxy_base_url` carries `/v1` and the
/// fetch appends `/settings`; the Swift service appends `v1/settings`, so the
/// caller must pass the base without the suffix.
func stripTrailingV1(_ proxyBaseURL: String) -> URL {
    let trimmed = proxyBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    // Drop a trailing `v1` segment only — not a `v1` elsewhere in the path.
    if trimmed.hasSuffix("/v1") {
        return URL(string: String(trimmed.dropLast(3))) ?? URL(string: trimmed)!
    }
    return URL(string: trimmed) ?? URL(string: proxyBaseURL)!
}

/// Re-derive the hide key for the banner's selected announcement. The banner
/// projection drops the `RemoteAnnouncement` identity; this re-runs the
/// upstream selection against the same cache + hidden set to recover the key
/// `hideCurrent()` should persist.
private func rederiveHideKey(
    from announcements: [RemoteAnnouncement],
    hiddenIDs: Set<String>,
    now: Date
) -> String? {
    guard let selected = firstSessionAnnouncement(announcements, hiddenIDs: hiddenIDs, now: now) else {
        return nil
    }
    return announcementHideKey(selected)
}
