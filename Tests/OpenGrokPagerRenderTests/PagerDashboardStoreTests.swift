// PagerDashboardStoreTests.swift
//
// Wave 18 B1-s: `[dashboard]` persistence in isolated homes — the port
// of upstream 650c1db7's `load_persisted_from_path` (`state.rs:4917-4951`),
// `write_persisted_to_path` (`:4961-5016`), `load_persisted_enabled`
// (`:4894-4904`), the key grammar (`PersistedRowId`, `:145-181`) and the
// entry caps (`:5065-5106`).
//
// The highest-value test in this file is
// `refusesToWriteOverAnUnparseableConfig`: the table lives inside the
// SHARED user config.toml, so a writer without the parse guard would let
// one Ctrl+G erase `[ui]`, `[hints]`, `[mcp_servers]` and everything else
// a user cannot get back.
//
// Assertions run against the file text and through `load()`, never
// against an imported TOML tree — the render test target does not depend
// on OpenGrokConfig, the same reason `PagerAgentsConfigStoreTests`
// asserts on `contents()`.

import Foundation
import Testing
@testable import OpenGrokPagerRender

private struct StoreFixture {
    let directory: URL
    let configPath: URL
    let store: PagerDashboardStore

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-dashboard-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        configPath = directory.appendingPathComponent("config.toml")
        store = PagerDashboardStore(configPath: configPath)
    }

    func dispose() {
        try? FileManager.default.removeItem(at: directory)
    }

    func write(_ toml: String) throws {
        try toml.write(to: configPath, atomically: true, encoding: .utf8)
    }

    func contents() throws -> String {
        try String(contentsOf: configPath, encoding: .utf8)
    }
}

// MARK: - 16. Key grammar

@Suite("dashboard store — persisted key grammar")
struct PagerPersistedRowIDTests {
    @Test("top-level and subagent keys round-trip through their on-disk spelling")
    func roundTrip() {
        // `persisted_row_id_round_trip_top_level` / `_subagent`
        // (`state.rs:5244-5270`).
        let top = PagerPersistedRowID.topLevel(sessionID: "sess-abc")
        #expect(top.key == "top:sess-abc")
        #expect(PagerPersistedRowID(key: top.key) == top)

        let sub = PagerPersistedRowID.subagent(parentSessionID: "p1", childSessionID: "c1")
        #expect(sub.key == "sub:p1:c1")
        #expect(PagerPersistedRowID(key: sub.key) == sub)
    }

    /// Session ids are OPAQUE: only the first colon after `sub:` splits,
    /// and `top:` never splits at all (`state.rs:147-150`). An id that
    /// happens to contain colons — an ACP session id may — must survive
    /// verbatim, or a pin silently reattaches to a different session.
    @Test("colon-bearing session ids survive intact")
    func colonBearingIDs() {
        let sub = PagerPersistedRowID.subagent(
            parentSessionID: "p", childSessionID: "c:1:2"
        )
        #expect(sub.key == "sub:p:c:1:2")
        #expect(PagerPersistedRowID(key: "sub:p:c:1:2") == sub)
        #expect(
            PagerPersistedRowID(key: "top:a:b") == .topLevel(sessionID: "a:b")
        )
    }

    @Test("the whole malformed-key rejection table")
    func rejections() {
        // Every one of these would otherwise resolve to a half-empty id
        // that can never match a live row (`from_key`, `:160-181`).
        for key in ["top:", "sub::c", "sub:p:", "sub:foo", "sub:", "top", "sub", "", "x:y", ":"] {
            #expect(PagerPersistedRowID(key: key) == nil, "key \(key) must be rejected")
        }
    }
}

// MARK: - 15/18/19. Round trips against a real file

@Suite("dashboard store — file round trips")
struct PagerDashboardStoreRoundTripTests {
    @Test("a missing file yields nothing to load and is created by the first write")
    func missingFile() throws {
        let fixture = try StoreFixture()
        defer { fixture.dispose() }
        #expect(fixture.store.load() == nil)
        #expect(fixture.store.loadEnabled() == nil)

        try fixture.store.write(PagerPersistedDashboard.defaults)
        let body = try fixture.contents()
        #expect(body.contains("[dashboard]"))
        #expect(body.contains("enabled = true"))
        #expect(body.contains("grouping = \"state\""))
        #expect(body.contains("pinned = []"))
        #expect(body.contains("reorder = []"))
    }

    @Test("every field round-trips through the file, including a colon-bearing child id")
    func fullRoundTrip() throws {
        let fixture = try StoreFixture()
        defer { fixture.dispose() }
        let persisted = PagerPersistedDashboard(
            enabled: false,
            grouping: .directory,
            pinned: [
                .topLevel(sessionID: "s-a"),
                .subagent(parentSessionID: "s-a", childSessionID: "c:1"),
            ],
            reorder: [.topLevel(sessionID: "s-b"), .topLevel(sessionID: "s-a")]
        )
        try fixture.store.write(persisted)
        let loaded = try #require(fixture.store.load())
        #expect(loaded == persisted)
        // The reorder ARRAY order is the value; it must not come back sorted.
        #expect(loaded.reorder == [.topLevel(sessionID: "s-b"), .topLevel(sessionID: "s-a")])
    }

    /// `Set` iteration order in Swift is seeded per process, so an
    /// unsorted write would churn the file on every unrelated edit. The
    /// `PagerSettingsStore.writeMultiSelect` precedent (`:129-131`).
    @Test("pinned keys are written sorted, so the file is byte-deterministic")
    func pinnedKeysAreSorted() throws {
        let fixture = try StoreFixture()
        defer { fixture.dispose() }
        try fixture.store.write(PagerPersistedDashboard(
            pinned: [
                .topLevel(sessionID: "zzz"),
                .topLevel(sessionID: "aaa"),
                .subagent(parentSessionID: "p", childSessionID: "c"),
            ]
        ))
        let body = try fixture.contents()
        #expect(body.contains("pinned = [\"sub:p:c\", \"top:aaa\", \"top:zzz\"]"))
        // Rewriting the same value reproduces the same bytes.
        let first = body
        let reloaded = try #require(fixture.store.load())
        try fixture.store.write(reloaded)
        #expect(try fixture.contents() == first)
    }

    /// The whole reason for the read-modify-write shape: `[dashboard]`
    /// shares config.toml with everything else the user owns.
    @Test("unrelated tables and unrelated dashboard keys survive a write")
    func unrelatedKeysSurvive() throws {
        let fixture = try StoreFixture()
        defer { fixture.dispose() }
        try fixture.write("""
        [ui]
        theme = "dark"

        [hints]
        seen = ["ctrl-g"]

        [dashboard]
        enabled = false
        peek_width = 42
        """)
        try fixture.store.write(PagerPersistedDashboard(enabled: false, grouping: .directory))
        let body = try fixture.contents()
        #expect(body.contains("[ui]"))
        #expect(body.contains("theme = \"dark\""))
        #expect(body.contains("[hints]"))
        #expect(body.contains("seen = [\"ctrl-g\"]"))
        // An unrecognised key inside `[dashboard]` is not ours to drop.
        #expect(body.contains("peek_width = 42"))
        #expect(body.contains("grouping = \"directory\""))
    }

    /// Highest-value test in the file. Upstream warns and returns
    /// (`state.rs:4986-4995`); this port throws and — the part that
    /// matters — leaves the bytes untouched.
    @Test("an unparseable config is refused and preserved verbatim")
    func refusesToWriteOverAnUnparseableConfig() throws {
        let fixture = try StoreFixture()
        defer { fixture.dispose() }
        let broken = """
        [ui
        theme = "dark
        this is not toml at all ]]]
        """
        try fixture.write(broken)
        #expect(throws: PagerDashboardStoreError.unparseableConfig) {
            try fixture.store.write(PagerPersistedDashboard(enabled: true, grouping: .directory))
        }
        #expect(try fixture.contents() == broken)
        // And nothing loads out of it either — leniently, not by throwing.
        #expect(fixture.store.load() == nil)
        #expect(fixture.store.loadEnabled() == nil)
    }

    @Test("an empty file is treated as a fresh document, not as unparseable")
    func emptyFileWrites() throws {
        let fixture = try StoreFixture()
        defer { fixture.dispose() }
        try fixture.write("")
        try fixture.store.write(PagerPersistedDashboard(enabled: true, grouping: .directory))
        #expect(try fixture.contents().contains("grouping = \"directory\""))
    }

    /// `dashboard` present but not a table: upstream's `as_table_mut()`
    /// returns None and the writer bails without writing
    /// (`state.rs:4998-5000`). Same reasoning as the parse guard — an
    /// unrecognised shape is not ours to overwrite.
    @Test("a non-table [dashboard] key is left alone by the writer")
    func nonTableDashboardKeyIsNotClobbered() throws {
        let fixture = try StoreFixture()
        defer { fixture.dispose() }
        let original = "dashboard = 5\n"
        try fixture.write(original)
        try fixture.store.write(PagerPersistedDashboard(grouping: .directory))
        #expect(try fixture.contents() == original)
    }
}

// MARK: - 17/20. Lenient loading

@Suite("dashboard store — lenient loads")
struct PagerDashboardStoreLenientTests {
    @Test("a garbage enabled value reads as true from load and as nothing from loadEnabled")
    func garbageEnabled() throws {
        let fixture = try StoreFixture()
        defer { fixture.dispose() }
        try fixture.write("""
        [dashboard]
        enabled = "yes"
        """)
        // The full load defaults the field (`:4928-4931`) rather than
        // failing the whole table — a broken flag must not cost the pins.
        let loaded = try #require(fixture.store.load())
        #expect(loaded.enabled)
        // The narrow reader reports "no usable value", so the caller can
        // apply its own default (and let the environment win first).
        #expect(fixture.store.loadEnabled() == nil)
    }

    @Test("unknown and non-string grouping values fall back to state")
    func groupingFallbacks() throws {
        let cases: [(String, PagerDashboardGrouping)] = [
            ("\"directory\"", .directory),
            ("\"dir\"", .directory),
            ("\"state\"", .state),
            ("\"sideways\"", .state),
            ("7", .state),
            ("true", .state),
        ]
        for (literal, expected) in cases {
            let fixture = try StoreFixture()
            defer { fixture.dispose() }
            try fixture.write("[dashboard]\ngrouping = \(literal)\n")
            let loaded = try #require(fixture.store.load())
            #expect(
                loaded.grouping == expected,
                "grouping = \(literal) should load as \(expected)"
            )
        }
    }

    @Test("a missing [dashboard] table loads as nothing at all")
    func missingTable() throws {
        let fixture = try StoreFixture()
        defer { fixture.dispose() }
        try fixture.write("[ui]\ntheme = \"dark\"\n")
        #expect(fixture.store.load() == nil)
        #expect(fixture.store.loadEnabled() == nil)
    }

    @Test("a non-table [dashboard] key loads the defaults rather than nothing")
    func nonTableDashboardKey() throws {
        let fixture = try StoreFixture()
        defer { fixture.dispose() }
        try fixture.write("dashboard = 5\n")
        let loaded = try #require(fixture.store.load())
        #expect(loaded == PagerPersistedDashboard.defaults)
    }

    @Test("non-array pinned/reorder are ignored; bad entries are skipped one by one")
    func lenientArrays() throws {
        let fixture = try StoreFixture()
        defer { fixture.dispose() }
        try fixture.write("""
        [dashboard]
        pinned = "top:a"
        reorder = [1, true, "top:a", "sub:p:", "nope", "sub:p:c"]
        """)
        let loaded = try #require(fixture.store.load())
        // A non-array field yields nothing (`parse_persist_keys`, `:5074-5077`).
        #expect(loaded.pinned.isEmpty)
        // Non-strings and malformed keys are skipped individually, and
        // the surviving order is preserved.
        #expect(loaded.reorder == [
            .topLevel(sessionID: "a"),
            .subagent(parentSessionID: "p", childSessionID: "c"),
        ])
    }

    @Test("the entry count is capped at 256")
    func entryCap() throws {
        // `MAX_PERSISTED_ENTRIES` (`state.rs:5068`): a corrupted or
        // hostile config must not balloon allocations.
        let fixture = try StoreFixture()
        defer { fixture.dispose() }
        let keys = (0..<300).map { "\"top:s\($0)\"" }.joined(separator: ", ")
        try fixture.write("[dashboard]\npinned = [\(keys)]\nreorder = [\(keys)]\n")
        let loaded = try #require(fixture.store.load())
        #expect(loaded.pinned.count == PagerDashboardStore.maxPersistedEntries)
        #expect(loaded.reorder.count == PagerDashboardStore.maxPersistedEntries)
    }

    @Test("keys are capped at 1024 UTF-8 bytes, measured the way Rust measures them")
    func keyLengthCap() throws {
        // `MAX_PERSIST_KEY_LEN` (`state.rs:5071`) is `str::len` — BYTES.
        // Swift's `String.count` is grapheme clusters and would admit a
        // far longer key.
        let fixture = try StoreFixture()
        defer { fixture.dispose() }
        let atCap = "top:" + String(repeating: "x", count: 1020)
        let overCap = "top:" + String(repeating: "y", count: 1021)
        #expect(atCap.utf8.count == 1024)
        #expect(overCap.utf8.count == 1025)
        try fixture.write("[dashboard]\npinned = [\"\(atCap)\", \"\(overCap)\"]\n")
        let loaded = try #require(fixture.store.load())
        #expect(loaded.pinned == [.topLevel(sessionID: String(repeating: "x", count: 1020))])
    }
}

// MARK: - 22. loadEnabled

@Suite("dashboard store — loadEnabled")
struct PagerDashboardLoadEnabledTests {
    @Test("the whole loadEnabled table")
    func table() throws {
        let cases: [(String, Bool?)] = [
            ("[dashboard]\nenabled = true\n", true),
            ("[dashboard]\nenabled = false\n", false),
            ("[dashboard]\n", nil),
            ("[dashboard]\nenabled = \"yes\"\n", nil),
            ("[dashboard]\nenabled = 1\n", nil),
            ("[ui]\ntheme = \"dark\"\n", nil),
            ("", nil),
            ("[ui\nbroken", nil),
        ]
        for (body, expected) in cases {
            let fixture = try StoreFixture()
            defer { fixture.dispose() }
            try fixture.write(body)
            #expect(
                fixture.store.loadEnabled() == expected,
                "config <\(body)> should read enabled as \(String(describing: expected))"
            )
        }
    }
}

// MARK: - Port pins: bridging live rows to persisted keys

@Suite("dashboard store — live row bridging")
struct PagerDashboardPersistBridgeTests {
    /// PORT DIVERGENCE (lead ruling), pinned here so it cannot regress
    /// silently: upstream refuses to persist roster rows at all
    /// (`state.rs:1313-1316`) because there a roster row is another
    /// process's live view. Here the dormant feed is the on-disk session
    /// catalog, so the session outlives every process and the pin is
    /// exactly as durable as one on an attached tab.
    @Test("a dormant row persists as a top: key and re-resolves to whichever kind exists now")
    func dormantPinsPersistAsTopKeys() {
        var state = PagerDashboardState()
        state.pinned = [.dormant("s1")]
        state.reorder = [.dormant("s1")]
        let persisted = state.toPersisted(enabled: true)
        #expect(persisted.pinned == [.topLevel(sessionID: "s1")])

        // Re-opened after the session was attached: the same key now
        // resolves to the LIVE row, so the pin follows the session
        // rather than the feed it happened to arrive on.
        var reopened = PagerDashboardState()
        reopened.apply(persisted, resolvingAgainst: [.session("s1"), .dormant("s2")])
        #expect(reopened.pinned == [.session("s1")])
        #expect(reopened.reorder == [.session("s1")])

        // Still detached: it resolves back to the dormant row.
        var stillDormant = PagerDashboardState()
        stillDormant.apply(persisted, resolvingAgainst: [.dormant("s1")])
        #expect(stillDormant.pinned == [.dormant("s1")])
    }

    /// The port's subagent rows are not selectable in the overlay, so
    /// nothing can pin one and no `sub:` key is ever written — but the
    /// parser still accepts them, because a config written by upstream
    /// (or by a later port revision) must not be corrupted on the next
    /// write.
    @Test("no sub: key is written today, yet sub: keys still parse and re-resolve")
    func subagentKeysParseEvenThoughNothingWritesThem() {
        var state = PagerDashboardState()
        state.pinned = [.session("a"), .dormant("b")]
        let keys = state.toPersisted(enabled: true).pinned.map(\.key).sorted()
        #expect(keys == ["top:a", "top:b"])
        #expect(keys.allSatisfy { !$0.hasPrefix("sub:") })

        let parsed = PagerPersistedRowID(key: "sub:a:c")
        #expect(parsed == .subagent(parentSessionID: "a", childSessionID: "c"))
        #expect(
            parsed?.resolve(in: [.subagent(parent: "a", child: "c")])
                == .subagent(parent: "a", child: "c")
        )
    }

    @Test("unresolvable keys are dropped on apply, and the reorder order survives")
    func applyDropsUnresolvableKeys() {
        let persisted = PagerPersistedDashboard(
            grouping: .directory,
            pinned: [.topLevel(sessionID: "gone"), .topLevel(sessionID: "here")],
            reorder: [
                .topLevel(sessionID: "c"),
                .topLevel(sessionID: "gone"),
                .topLevel(sessionID: "a"),
            ]
        )
        var state = PagerDashboardState()
        state.apply(persisted, resolvingAgainst: [
            .session("here"), .session("c"), .session("a"),
        ])
        #expect(state.grouping == .directory)
        #expect(state.pinned == [.session("here")])
        #expect(state.reorder == [.session("c"), .session("a")])
    }

    /// `dispatch_dashboard_persist` (`dispatch/dashboard.rs:2369-2384`)
    /// threads the ON-DISK flag rather than hardcoding `true`, so a user
    /// who turned the dashboard off does not get it silently switched
    /// back on by the next pin.
    @Test("a disabled dashboard stays disabled across a pin write")
    func enabledIsThreadedNotHardcoded() throws {
        let fixture = try StoreFixture()
        defer { fixture.dispose() }
        try fixture.write("[dashboard]\nenabled = false\n")
        let onDisk = try #require(fixture.store.load())
        #expect(onDisk.enabled == false)

        var state = PagerDashboardState()
        state.togglePin(.session("s1"))
        try fixture.store.write(state.toPersisted(enabled: onDisk.enabled))

        #expect(try fixture.contents().contains("enabled = false"))
        let reloaded = try #require(fixture.store.load())
        #expect(reloaded.enabled == false)
        #expect(reloaded.pinned == [.topLevel(sessionID: "s1")])
    }

    /// Per-open state must never reach the file: a launch that opened
    /// into someone's stale search query would be a bug the user could
    /// not explain.
    @Test("filter, search, collapse and idleShowAll are never persisted")
    func perOpenStateIsNotWritten() throws {
        let fixture = try StoreFixture()
        defer { fixture.dispose() }
        var state = PagerDashboardState()
        state.filter = .substring("secret-query")
        state.searchActive = true
        state.collapsedSections = [.state(.idle), .pinned]
        state.idleShowAll = true
        state.selected = .session("s1")
        state.selectedSection = .state(.working)
        try fixture.store.write(state.toPersisted(enabled: true))

        let body = try fixture.contents()
        #expect(body.contains("secret-query") == false)
        #expect(body.contains("filter") == false)
        #expect(body.contains("search") == false)
        #expect(body.contains("collapsed") == false)
        #expect(body.contains("idle") == false)
        #expect(body.contains("selected") == false)
        // Exactly the four persisted keys.
        #expect(body.contains("enabled = true"))
        #expect(body.contains("grouping = \"state\""))
        #expect(body.contains("pinned = []"))
        #expect(body.contains("reorder = []"))
    }
}
