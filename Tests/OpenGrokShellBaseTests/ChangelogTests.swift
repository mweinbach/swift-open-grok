// ChangelogTests.swift
//
// The `ChangelogManager` port (`xai-grok-shell-base/src/util/changelog.rs`
// at the pin), its five upstream unit tests near-verbatim, plus the two
// behaviors upstream documents in comments but does not unit-test (the
// write-through markdown cache and the parse-before-cache JSON guard) and
// the port's recorded export-boundary divergence.
//
// Every test drives `fetchWith` against an isolated temp home — upstream's
// `manager_for(home)` seam — so no test mutates process-global env
// (`OPENGROK_HOME` / `GROK_CHANGELOG_OFFLINE`), which would race the
// parallel harness. The CDN-miss test forces the miss with an unreachable
// base (`http://127.0.0.1:1`), exactly as upstream does, instead of
// depending on whether the sandbox happens to block network.

import Foundation
import OpenGrokHTTP
import OpenGrokSamplingTypes
import Testing
@testable import OpenGrokShellBase

@Suite("ChangelogManager")
struct ChangelogTests {
    /// A hermetic home under the temp directory, isolated per test.
    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-changelog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    /// Upstream's `manager_for(home)`: cache paths direct, bypassing env.
    private func manager(
        for home: URL,
        transport: (any HTTPTransport)? = nil,
        exportPolicy: XaiServicePolicy = .allowed
    ) -> ChangelogManager {
        ChangelogManager(
            mdCache: home.appendingPathComponent("CHANGELOG.md"),
            jsonCache: home.appendingPathComponent("CHANGELOG.json"),
            transport: transport,
            exportPolicy: exportPolicy
        )
    }

    // MARK: - Upstream's unit tests, near-verbatim

    @Test("offline mode reads the seeded disk cache only")
    func offlineModeReadsSeededDiskCacheOnly() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try "# seeded offline md\n".write(
            to: home.appendingPathComponent("CHANGELOG.md"),
            atomically: true,
            encoding: .utf8
        )
        try #"[{"category":"features","description":"seeded entry","breaking_change":false}]"#
            .write(
                to: home.appendingPathComponent("CHANGELOG.json"),
                atomically: true,
                encoding: .utf8
            )

        // Offline path: read only the seeded disk cache, no network.
        let changelog = await manager(for: home).fetchWith(
            offline: true,
            base: ChangelogManager.changelogBase
        )
        #expect(
            changelog.markdown == "# seeded offline md\n",
            "offline mode must return seeded markdown"
        )
        let entries = try #require(changelog.entries, "seeded json entries")
        #expect(entries.count == 1)
        #expect(entries[0].description == "seeded entry")
    }

    @Test("a CDN miss falls back to the disk cache")
    func cdnMissFallsBackToDiskCache() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try "# fallback md\n".write(
            to: home.appendingPathComponent("CHANGELOG.md"),
            atomically: true,
            encoding: .utf8
        )

        // Non-offline path with an unreachable CDN base: the remote fetch
        // fails deterministically (no dependency on the sandbox blocking
        // network), so the on-disk cache must win.
        let changelog = await manager(
            for: home,
            transport: URLSessionHTTPTransport()
        ).fetchWith(offline: false, base: "http://127.0.0.1:1")
        #expect(
            changelog.markdown == "# fallback md\n",
            "CDN miss must fall back to the seeded CHANGELOG.md"
        )
    }

    @Test("bullets strip markdown and respect max")
    func bulletsStripMarkdownAndRespectMax() {
        let entries = [
            ChangelogEntry(
                category: "features",
                description: "Added **dark mode** support",
                breakingChange: false
            ),
            ChangelogEntry(
                category: "fixes",
                description: "Fixed `crash` on startup",
                breakingChange: false
            ),
            ChangelogEntry(
                category: "performance",
                description: "Faster **rendering** of `code` blocks",
                breakingChange: false
            ),
        ]

        let bullets = bulletsFromEntries(entries, max: 2)
        #expect(bullets.count == 2)
        #expect(bullets[0] == "Added dark mode support")
        #expect(bullets[1] == "Fixed crash on startup")
    }

    @Test("bullets skip empty descriptions")
    func bulletsSkipEmptyDescriptions() {
        let entries = [
            ChangelogEntry(category: "features", description: "Good entry", breakingChange: false),
            // bad entry from tolerant deserialization
            ChangelogEntry(category: "", description: "", breakingChange: false),
            ChangelogEntry(category: "fixes", description: "Another good one", breakingChange: false),
        ]
        let bullets = bulletsFromEntries(entries, max: 10)
        #expect(bullets == ["Good entry", "Another good one"])
    }

    @Test("tolerant deserialization defaults missing fields")
    func tolerantDeserializationPartialEntry() throws {
        // Missing description field → defaults to empty string, not a parse
        // error (serde's `#[serde(default)]` semantics).
        let json = #"[{"category":"features"},{"description":"ok"}]"#
        let entries = try JSONDecoder().decode(
            [ChangelogEntry].self,
            from: Data(json.utf8)
        )
        #expect(entries.count == 2)
        #expect(entries[0].description == "")
        #expect(entries[1].category == "")
        #expect(entries[1].description == "ok")
    }

    // MARK: - Cache-write guards (upstream's comments, pinned as behavior)

    @Test("a fetched markdown is write-through cached; malformed JSON never poisons its cache")
    func writeThroughMarkdownAndParseGuardedJSON() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // Both parallel fetches receive the same non-JSON body, so whichever
        // order the mock serves them in, the markdown arm caches it and the
        // JSON arm must refuse to.
        let body = Data("# fresh remote md\n".utf8)
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 200), body: body),
            .init(metadata: HTTPResponseMetadata(statusCode: 200), body: body),
        ])

        let changelog = await manager(for: home, transport: transport).fetchWith(
            offline: false,
            base: "https://cdn.example.com/changelogs"
        )

        #expect(changelog.markdown == "# fresh remote md\n")
        #expect(changelog.entries == nil, "non-JSON body must not decode to entries")
        // Write-through: the markdown landed on disk.
        let cachedMD = try String(
            contentsOf: home.appendingPathComponent("CHANGELOG.md"),
            encoding: .utf8
        )
        #expect(cachedMD == "# fresh remote md\n")
        // Parse-before-cache: the malformed JSON never touched the disk.
        #expect(
            !FileManager.default.fileExists(
                atPath: home.appendingPathComponent("CHANGELOG.json").path
            ),
            "a failed parse must not poison the JSON disk cache"
        )
        // Both artifact URLs were requested (upstream fetches in parallel).
        let paths = transport.recordedRequests.map(\.url.absoluteString)
        #expect(paths.contains { $0.hasSuffix(".external.md") })
        #expect(paths.contains { $0.hasSuffix(".external.json") })
    }

    @Test("a JSON changelog is cached only after a successful parse")
    func jsonCachedAfterSuccessfulParse() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let raw = #"[{"category":"features","description":"remote entry","breaking_change":true}]"#
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 200), body: Data(raw.utf8)),
        ])

        let entries = await manager(for: home, transport: transport).fetchJSON(
            base: "https://cdn.example.com/changelogs",
            version: "0.0.0-test",
            transport: transport
        )

        let decoded = try #require(entries)
        #expect(decoded.count == 1)
        #expect(decoded[0].description == "remote entry")
        #expect(decoded[0].breakingChange == true)
        // The raw payload landed on disk, byte for byte.
        let cached = try String(
            contentsOf: home.appendingPathComponent("CHANGELOG.json"),
            encoding: .utf8
        )
        #expect(cached == raw)
    }

    // MARK: - Export boundary (recorded stricter-than-upstream divergence)

    @Test("a denied export policy issues no request and reads only the cache")
    func deniedExportPolicyIssuesNoRequest() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try "# cached under a denied boundary\n".write(
            to: home.appendingPathComponent("CHANGELOG.md"),
            atomically: true,
            encoding: .utf8
        )
        // A scripted response that must never be served: if the gate leaks,
        // the fetch would consume it and the request record would show it.
        let transport = MockHTTPTransport(responses: [
            .init(
                metadata: HTTPResponseMetadata(statusCode: 200),
                body: Data("# must never be fetched\n".utf8)
            ),
        ])

        let changelog = await manager(
            for: home,
            transport: transport,
            exportPolicy: .denied
        ).fetchWith(offline: false, base: ChangelogManager.changelogBase)

        #expect(
            transport.recordedRequests.isEmpty,
            "a denied provider issued a changelog request"
        )
        #expect(
            changelog.markdown == "# cached under a denied boundary\n",
            "the denied arm must still serve the disk cache"
        )
    }

    @Test("an allowed export policy does reach the wire (gate positive control)")
    func allowedExportPolicyReachesTheWire() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let body = Data("# gate-open remote md\n".utf8)
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 200), body: body),
            .init(metadata: HTTPResponseMetadata(statusCode: 200), body: body),
        ])

        let changelog = await manager(
            for: home,
            transport: transport,
            exportPolicy: .allowed
        ).fetchWith(offline: false, base: "https://cdn.example.com/changelogs")

        // Without this arm the denied test above would pass vacuously
        // against a transport nothing ever calls.
        #expect(transport.recordedRequests.count == 2)
        #expect(changelog.markdown == "# gate-open remote md\n")
    }

    // MARK: - Env resolution

    @Test("fetch re-resolves $OPENGROK_HOME from the live environment, over stale paths")
    func fetchReresolvesHomeFromEnvironment() async throws {
        let staleHome = try makeHome()
        let liveHome = try makeHome()
        defer {
            try? FileManager.default.removeItem(at: staleHome)
            try? FileManager.default.removeItem(at: liveHome)
        }
        try "# stale home md\n".write(
            to: staleHome.appendingPathComponent("CHANGELOG.md"),
            atomically: true,
            encoding: .utf8
        )
        try "# live harness home md\n".write(
            to: liveHome.appendingPathComponent("CHANGELOG.md"),
            atomically: true,
            encoding: .utf8
        )

        // The manager was built against the stale home; `fetch` must ignore
        // those paths and honour the environment it is handed — upstream's
        // `from_env_home` re-resolution ("harness homes win").
        let changelog = await manager(for: staleHome).fetch(environment: [
            "OPENGROK_HOME": liveHome.path,
            "GROK_CHANGELOG_OFFLINE": "1",
        ])
        #expect(changelog.markdown == "# live harness home md\n")
    }

    @Test("GROK_CHANGELOG_OFFLINE: set and non-zero means offline")
    func changelogOfflineFlagParsing() {
        #expect(!ChangelogManager.changelogOffline(environment: [:]))
        #expect(!ChangelogManager.changelogOffline(environment: ["GROK_CHANGELOG_OFFLINE": ""]))
        #expect(!ChangelogManager.changelogOffline(environment: ["GROK_CHANGELOG_OFFLINE": "0"]))
        #expect(ChangelogManager.changelogOffline(environment: ["GROK_CHANGELOG_OFFLINE": "1"]))
        #expect(ChangelogManager.changelogOffline(environment: ["GROK_CHANGELOG_OFFLINE": "true"]))
    }
}
