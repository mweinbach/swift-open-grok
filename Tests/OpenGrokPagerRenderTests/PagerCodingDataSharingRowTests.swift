// PagerCodingDataSharingRowTests.swift
//
// Wave 18 B9-c2 registry and state pins for the `coding_data_sharing` row.
//
//  * The storage pin is the tripwire for this slice's design decision: the
//    row persists to the xAI service through the retention client and to
//    the auth-metadata mirror — NEVER to config.toml. `.authMetadata` is
//    upstream's storage for it (settings/defs.rs:156: "Persisted in auth
//    metadata (`AuthEntry::coding_data_retention_opt_out`)" at pin
//    650c1db7), and `PagerSettingsStore` must keep refusing it so a future
//    refactor cannot quietly give the consent flag a second, disagreeing
//    home on disk.
//  * The lock derivation is `coding_data_sharing_lock`
//    (app_view.rs:1693-1703) on the same state struct the banner gate
//    reads, so the row's lock and the gate's guards can never disagree.
//  * The toast scrub is `scrub_error_for_toast` (dispatch/status.rs:186-200)
//    over `is_unsafe_display_char` (line_utils.rs:39-50) — the server-error
//    path onto a painted surface.

import Foundation
import Testing
@testable import OpenGrokPagerRender

@Suite("coding-data sharing row pins")
struct PagerCodingDataSharingRowTests {
    // MARK: Registry / storage

    @Test("the row's storage stays .authMetadata — a server-persisted row is not .config")
    func rowStorageIsAuthMetadata() throws {
        let meta = try #require(PagerSettingsRegistry.default.find("coding_data_sharing"))
        #expect(meta.storage == .authMetadata(key: "coding_data_sharing"))
        #expect(meta.category == .privacy)
    }

    @Test("the config store refuses the row: no config.toml home, ever")
    func configStoreRefusesTheRow() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-cds-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let configPath = home.appendingPathComponent("config.toml")
        let store = PagerSettingsStore(configPath: configPath)

        let meta = try #require(PagerSettingsRegistry.default.find("coding_data_sharing"))
        #expect(store.persistedPath(for: meta) == nil)
        do {
            try store.write(key: "coding_data_sharing", value: .string("opt-in"))
            Issue.record("the config store must refuse the consent row")
        } catch let error as PagerSettingsStoreError {
            #expect(error == .notPersistable(key: "coding_data_sharing"))
        }
        // The refusal must also leave no file behind: a write that "failed"
        // but created a config.toml would still have leaked the consent
        // value to the wrong store.
        #expect(!FileManager.default.fileExists(atPath: configPath.path))
    }

    // MARK: Lock derivation (app_view.rs:1693-1703)

    @Test("editable for a personal account and for a team admin")
    func lockNilForPersonalAndAdmin() {
        #expect(PagerPrivacyBannerState().codingDataSharingLock == nil)
        #expect(PagerPrivacyBannerState(
            teamName: "acme",
            teamRole: "Admin"
        ).codingDataSharingLock == nil)
    }

    @Test("ZDR locks the row, and outranks the team arm")
    func zdrLockWins() {
        #expect(PagerPrivacyBannerState(isZDR: true).codingDataSharingLock
            == .zeroDataRetention)
        // A ZDR team's non-admin member is told about ZDR — upstream
        // checks is_zdr first (app_view.rs:1696-1699).
        #expect(PagerPrivacyBannerState(
            isZDR: true,
            teamName: "acme",
            teamRole: "member"
        ).codingDataSharingLock == .zeroDataRetention)
    }

    @Test("a non-admin team member gets the policy lock")
    func nonAdminPolicyLock() {
        #expect(PagerPrivacyBannerState(
            teamName: "acme",
            teamRole: "member"
        ).codingDataSharingLock == .policyManaged)
        // No role at all is still non-admin (app_view.rs:1688-1691's
        // is_some_and over the Option).
        #expect(PagerPrivacyBannerState(
            teamName: "acme"
        ).codingDataSharingLock == .policyManaged)
    }

    // MARK: Toast scrub (dispatch/status.rs:186-200, line_utils.rs:39-50)

    @Test("a short, safe server error passes through verbatim")
    func scrubPassesSafeText() {
        #expect(pagerScrubErrorForToast("server returned HTTP 503")
            == "server returned HTTP 503")
        // Multibyte but safe and under the byte limit.
        #expect(pagerScrubErrorForToast("quota épuisé") == "quota épuisé")
    }

    @Test("the 120 limit is BYTES, exactly at the boundary")
    func scrubLengthIsByteExact() {
        let exactly120 = String(repeating: "a", count: 120)
        #expect(pagerScrubErrorForToast(exactly120) == exactly120)
        #expect(pagerScrubErrorForToast(exactly120 + "a")
            == "server error (see logs for details)")
        // 40 three-byte characters = 120 bytes (passes); 41 trips it.
        let multibyte120 = String(repeating: "€", count: 40)
        #expect(pagerScrubErrorForToast(multibyte120) == multibyte120)
        #expect(pagerScrubErrorForToast(multibyte120 + "€")
            == "server error (see logs for details)")
    }

    @Test("controls and bidi/zero-width formats substitute wholesale")
    func scrubSubstitutesUnsafeCharacters() {
        // Escape-sequence injection (C0), DEL, C1, and the Trojan-Source
        // set — each poisons the WHOLE message, upstream's all-or-nothing
        // substitution.
        for needle in ["\u{1B}[31m", "\u{07}", "\u{7F}", "\u{85}",
                       "\u{202E}", "\u{200B}", "\u{061C}", "\u{FEFF}", "\u{2066}"] {
            #expect(
                pagerScrubErrorForToast("error \(needle) detail")
                    == "server error (see logs for details)",
                "\(needle.unicodeScalars.map { String(format: "U+%04X", $0.value) }) must scrub"
            )
        }
        // The safe neighbors stay safe: plain space, punctuation, CJK.
        #expect(pagerScrubErrorForToast("拒否されました (403)") == "拒否されました (403)")
    }
}
