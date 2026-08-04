import Foundation
import Testing
@testable import OpenGrokAnnouncements

@Suite("OpenGrokAnnouncements")
struct OpenGrokAnnouncementsTests {
    private let beforeExpiry = Date(timeIntervalSince1970: 1_893_456_000)

    private func announcement(
        id: String? = nil,
        message: String? = "message",
        severity: String? = nil,
        title: String? = nil,
        expiresAt: String? = nil,
        dismissible: Bool? = nil,
        cta: AnnouncementCta? = nil
    ) -> RemoteAnnouncement {
        RemoteAnnouncement(
            id: id,
            message: message,
            severity: severity,
            title: title,
            cta: cta,
            expiresAt: expiresAt,
            dismissible: dismissible
        )
    }

    @Test("announcement wire models use Rust snake case and tolerate missing fields")
    func wireModels() throws {
        let data = Data(#"{"id":"a","updated_at":"2026-08-01T00:00:00Z","expires_at":"2026-09-01T00:00:00Z","cta":{"label":"Open","url":"https://x.ai"}}"#.utf8)
        let decoded = try JSONDecoder().decode(RemoteAnnouncement.self, from: data)
        #expect(decoded.id == "a")
        #expect(decoded.updatedAt == "2026-08-01T00:00:00Z")
        #expect(decoded.cta?.label == "Open")
        #expect(decoded.message == nil)

        let encoded = try JSONEncoder().encode(RemoteAnnouncement(id: "a"))
        let encodedObject = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        #expect(encodedObject?["message"] is NSNull)
        #expect(encodedObject?["updated_at"] is NSNull)
        #expect(encodedObject?["updatedAt"] == nil)

        let encodedCta = try JSONEncoder().encode(AnnouncementCta())
        let encodedCtaObject = try JSONSerialization.jsonObject(with: encodedCta) as? [String: Any]
        #expect(encodedCtaObject?["label"] is NSNull)

        let refreshed = try JSONDecoder().decode(
            AnnouncementsRefreshed.self,
            from: Data(#"{"gen":7,"announcements":[{"message":"ready"}]}"#.utf8)
        )
        #expect(refreshed.gen == 7)
        #expect(refreshed.announcements.count == 1)

        let defaulted = try JSONDecoder().decode(
            AnnouncementsRefreshed.self,
            from: Data(#"{"gen":8}"#.utf8)
        )
        #expect(defaulted.announcements.isEmpty)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                AnnouncementsRefreshed.self,
                from: Data(#"{"gen":8,"announcements":null}"#.utf8)
            )
        }
    }

    @Test("hide keys prefer trimmed ids and distinguish id-less content")
    func hideKeys() {
        #expect(announcementHideKey(announcement(id: "  outage  ")) == "outage")
        #expect(
            announcementHideKey(announcement(id: " ", message: "message", title: "title"))
                == "content:title\u{1f}message"
        )
        #expect(
            announcementHideKey(announcement(message: "c", title: "a|b"))
                != announcementHideKey(announcement(message: "b|c", title: "a"))
        )
    }

    @Test("hidden state is deterministic, tolerant, and legacy bools do not migrate")
    func hiddenState() {
        let ids: Set<String> = ["outage-b", "outage-a"]
        #expect(serializeHiddenAnnouncementIDs(ids) == #"{"hidden_ids":["outage-a","outage-b"]}"#)
        #expect(parseHiddenAnnouncementIDs(#"{"hidden_ids":["outage-b","outage-a"],"future":true}"#) == ids)
        #expect(parseHiddenAnnouncementIDs(#"{"hidden":true}"#).isEmpty)
        #expect(parseHiddenAnnouncementIDs(#"{"hidden_ids":"wrong"}"#).isEmpty)
        #expect(parseHiddenAnnouncementIDs("not json").isEmpty)
    }

    @Test("pruning retains only active announcement keys and reports changes")
    func pruning() {
        let active = [announcement(id: "live"), announcement(message: "body", title: "title")]
        var ids: Set<String> = [
            "live",
            "gone",
            announcementHideKey(active[1]),
        ]
        let initiallyPruned = pruneHiddenAnnouncementIDs(&ids, active: active)
        #expect(initiallyPruned)
        #expect(ids == ["live", announcementHideKey(active[1])])
        let prunedAgain = pruneHiddenAnnouncementIDs(&ids, active: active)
        #expect(!prunedAgain)
    }

    @Test("visibility and expiry use trimmed messages and strict expiry boundary")
    func visibilityAndExpiry() {
        let expiry = "2030-01-01T00:00:00Z"
        let expiryDate = ISO8601DateFormatter().date(from: expiry)!
        let items = [
            announcement(id: "blank", message: "  "),
            announcement(id: "past", expiresAt: "2000-01-01T00:00:00Z"),
            announcement(id: "live", expiresAt: expiry),
            announcement(id: "invalid", expiresAt: "tomorrow"),
        ]
        #expect(visibleAnnouncements(items).map(\.id) == ["past", "live", "invalid"])
        #expect(filterExpiredAt(items, now: expiryDate.addingTimeInterval(-1)).map(\.id) == ["blank", "live", "invalid"])
        #expect(filterExpiredAt(items, now: expiryDate).map(\.id) == ["blank", "invalid"])

        let offsetExpiry = announcement(id: "offset", expiresAt: "2030-01-01T01:00:00+01:00")
        #expect(isExpiredAt(offsetExpiry, now: expiryDate))
    }

    @Test("critical selection wins, preserves source order, and respects hidden ids")
    func selectionOrdering() {
        let promo = announcement(id: "promo", severity: "promo")
        let criticalFirst = announcement(id: "critical-first", severity: "critical")
        let criticalSecond = announcement(id: "critical-second", severity: "critical")
        let announcements = [promo, criticalFirst, criticalSecond]
        #expect(firstSessionAnnouncement(announcements, hiddenIDs: [], now: beforeExpiry)?.id == "critical-first")
        #expect(firstSessionAnnouncement(announcements, hiddenIDs: ["critical-first"], now: beforeExpiry)?.id == "critical-second")
        #expect(firstSessionAnnouncement(announcements, hiddenIDs: ["critical-first", "critical-second"], now: beforeExpiry)?.id == "promo")
        #expect(sessionBannerHeight(announcements, hiddenIDs: [], now: beforeExpiry) == 2)
        #expect(hasCriticalSessionAnnouncement(announcements, hiddenIDs: [], now: beforeExpiry))
        #expect(!hasCriticalSessionAnnouncement(announcements, hiddenIDs: ["critical-first", "critical-second"], now: beforeExpiry))

        let informational = announcement(id: "info", severity: "warning")
        #expect(firstSessionAnnouncement([informational], hiddenIDs: [], now: beforeExpiry) == nil)
    }

    @Test("pinned announcements stay eligible even when their key is hidden")
    func pinnedSelection() {
        let pinned = announcement(id: "pinned", severity: "promo", dismissible: false)
        #expect(firstSessionAnnouncement([pinned], hiddenIDs: ["pinned"], now: beforeExpiry)?.id == "pinned")
        #expect(isDismissible(pinned) == false)
    }

    @Test("CTA inputs trim labels and allow only standard schemes")
    func ctaSafety() {
        let valid = announcement(
            id: "promo",
            severity: "promo",
            cta: AnnouncementCta(label: "  Open  ", url: " https://x.ai/promo ", caption: "  helper ")
        )
        let target = promoCTATarget([valid], hiddenIDs: [], now: beforeExpiry)
        #expect(target?.announcement.id == "promo")
        #expect(target?.url == "https://x.ai/promo")
        #expect(usableCTACaption(valid) == "helper")

        for unsafe in ["javascript:alert(1)", "file:///tmp/a", "vscode://open", "tel:+1"] {
            let invalid = announcement(
                id: "unsafe",
                severity: "promo",
                cta: AnnouncementCta(label: "Open", url: unsafe)
            )
            #expect(usableCTA(invalid) == nil)
            #expect(promoCTATarget([invalid], hiddenIDs: [], now: beforeExpiry) == nil)
        }
        #expect(usableCTA(announcement(severity: "promo", cta: AnnouncementCta(label: "Mail", url: "mailto:user@example.com"))) != nil)
    }

    @Test("session gates ignore hidden ids for reachability and exclude expired items")
    func sessionGates() {
        let critical = announcement(id: "critical", severity: "critical")
        let expired = announcement(id: "expired", severity: "promo", expiresAt: "2000-01-01T00:00:00Z")
        #expect(hasSessionAnnouncements([critical, expired], now: beforeExpiry))
        #expect(sessionAnnouncementHideKeys([critical, expired], now: beforeExpiry) == ["critical"])
        #expect(hasSessionAnnouncements([expired], now: beforeExpiry) == false)
        #expect(sessionBannerHeight([expired], hiddenIDs: [], now: beforeExpiry) == 0)

        let hidden = announcement(id: "hidden", severity: "promo")
        #expect(hasSessionAnnouncements([hidden], now: beforeExpiry))
        #expect(sessionAnnouncementHideKeys([hidden], now: beforeExpiry) == ["hidden"])
        #expect(firstSessionAnnouncement([hidden], hiddenIDs: ["hidden"], now: beforeExpiry) == nil)

        let pinned = announcement(id: "pinned", severity: "critical", dismissible: false)
        #expect(sessionAnnouncementHideKeys([pinned], now: beforeExpiry) == ["pinned"])
    }

    @Test("startup override takes precedence and invalid JSON falls back")
    func startupResolution() {
        let remote = [announcement(id: "remote")]
        let overrideEnvironment = [
            "GROK_ANNOUNCEMENTS_OVERRIDE": #"[{"id":"override","message":"local"}]"#,
        ]
        #expect(resolveStartup(remote, environment: overrideEnvironment)?.map(\.id) == ["override"])
        #expect(resolveStartup(remote, environment: ["GROK_ANNOUNCEMENTS_OVERRIDE": "not json"]) == remote)
        #expect(resolveStartup(nil, environment: ["GROK_ANNOUNCEMENTS_OVERRIDE": "not json"]) == nil)
    }

    @Test("state store is isolated by OPENGROK_HOME")
    func stateStoreIsolatedByOpenGrokHome() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-announcements-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let environment = ["OPENGROK_HOME": root.path]
        let ids: Set<String> = ["one", "two"]
        await writeHiddenAnnouncementIDs(ids, environment: environment)
        #expect(await readHiddenAnnouncementIDs(environment: environment) == ids)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("announcements.json").path))
    }

    @Test("state path follows Open Grok home and malformed files read empty")
    func statePathAndMalformedRead() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-announcements-path-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let environment = ["OPENGROK_HOME": root.path, "HOME": "/ignored"]
        #expect(announcementStateURL(environment: environment).path == root.appendingPathComponent("announcements.json").path)
        #expect(!announcementStateURL(environment: ["HOME": root.path]).path.contains(".grok"))

        try Data(#"{"hidden_ids":"wrong"}"#.utf8)
            .write(to: root.appendingPathComponent("announcements.json"))
        #expect(await readHiddenAnnouncementIDs(environment: environment).isEmpty)
    }
}
