// PagerSlashMatcherTests.swift
//
// Parity cases for the nucleo-port fuzzy matcher, the MRU store, and the
// registry's ranked pipeline. The matcher cases mirror upstream's own tests
// (`slash/matcher.rs:123-186` and the nucleo semantics they pin), so an
// ordering drift here is an ordering drift against the reference.

import Foundation
import Testing
@testable import OpenGrokPagerCommandUI

@Suite("Fuzzy matcher parity")
struct PagerFuzzyMatcherTests {
    private let matcher = PagerFuzzyMatcher()

    @Test("a subsequence hits; a broken subsequence does not")
    func subsequence() {
        // `indices_for_are_relative_to_display` (`matcher.rs:127-133`):
        // `sw` matches `ssh-wrap`; the multi-atom `fix s` does not.
        #expect(matcher.score("ssh-wrap", query: "sw") != nil)
        #expect(matcher.score("ssh-wrap", query: "ssh") != nil)
        #expect(matcher.score("ssh-wrap", query: "fix s") == nil)
    }

    @Test("multi-atom queries AND together and sum their scores")
    func multiAtom() {
        let both = matcher.score("theme picker", query: "the pic")
        let single = matcher.score("theme picker", query: "the")
        #expect(both != nil)
        #expect(single != nil)
        #expect(both! > single!)
    }

    @Test("smart case: lowercase atoms fold, uppercase atoms respect case")
    func smartCase() {
        #expect(matcher.score("Model", query: "m") != nil)
        #expect(matcher.score("model", query: "M") == nil)
        #expect(matcher.score("Model", query: "M") != nil)
    }

    @Test("ranked results prioritize the tight match — mod puts model first")
    func rankingOrder() {
        // `ranked_results_prioritize_matches` (`matcher.rs:143-149`).
        let items = ["model", "help", "history"]
        let hits = matcher.rank(items, query: "mod", limit: items.count) { $0 }
        #expect(hits.first.map { items[$0.index] } == "model")
    }

    @Test("empty query yields insertion order at score zero")
    func emptyQuery() {
        // `empty_query_yields_insertion_order` (`matcher.rs:135-141`).
        let items = ["alpha", "beta", "gamma"]
        let hits = matcher.rank(items, query: "", limit: items.count) { $0 }
        #expect(hits.map(\.index) == [0, 1, 2])
        #expect(hits.allSatisfy { $0.score == 0 })
    }

    @Test("limit caps results")
    func limitCaps() {
        // `limit_caps_results` (`matcher.rs:151-157`).
        let items = ["aaa", "aab", "aac", "aad", "aae"]
        #expect(matcher.rank(items, query: "a", limit: 2) { $0 }.count == 2)
    }

    @Test("single-letter p ties every p-command; the tiebreak is key text")
    func singleLetterTies() {
        // `query_p_ties_personas_and_pager_headless_at_same_score`
        // (`matcher.rs:169-186`).
        let items = ["personas", "pager-headless", "plan", "plugins"]
        let hits = matcher.rank(items, query: "p", limit: items.count) { $0 }
        let scores = Dictionary(uniqueKeysWithValues: hits.map { (items[$0.index], $0.score) })
        #expect(scores["personas"] == scores["pager-headless"])
        #expect((scores["personas"] ?? 0) > 0)
        let top = matcher.rank(items, query: "p", limit: 1) { $0 }
        #expect(top.first.map { items[$0.index] } == "pager-headless")
    }

    @Test("a gap costs 3 to open and 1 to extend")
    func gapPenalties() {
        // Same match window, one extra gap column: exactly the gap-start
        // penalty difference plus extension.
        let tight = matcher.score("ab", query: "ab")!
        let gapped = matcher.score("a-b", query: "ab")!
        let wider = matcher.score("a--b", query: "ab")!
        #expect(tight > gapped)
        #expect(gapped > wider)
        #expect(gapped - wider == 1)
    }
}

@Suite("Slash MRU store")
struct PagerSlashMruTests {
    @Test("touch is flat by command and strips the leading slash")
    func flatTouch() {
        // `touch_is_flat_by_command` / `strips_leading_slash_on_command`
        // (`mru.rs:323-340`).
        var mru = PagerSlashMru()
        mru.touch("/model", now: 1_000)
        #expect(mru.lastUsed("model") == 1_000)
        #expect(mru.lastUsed("/model") == 1_000)
        #expect(mru.lastUsed("quit") == 0)
    }

    @Test("recency decays stale entries but never to zero")
    func recencyDecay() {
        // `recency_decays_stale_entries` (`mru.rs:342-352`).
        let now: UInt64 = 1_700_000_000
        let recent = PagerSlashMru.recencyScore(lastUsed: now - 60, now: now)
        let weekOld = PagerSlashMru.recencyScore(lastUsed: now - 7 * 86_400, now: now)
        let monthOld = PagerSlashMru.recencyScore(lastUsed: now - 30 * 86_400, now: now)
        #expect(recent > weekOld)
        #expect(weekOld > monthOld)
        #expect(monthOld > 0)
        #expect(PagerSlashMru.recencyScore(lastUsed: 0, now: now) == 0)
    }

    @Test("the in-memory store never produces a persist snapshot")
    func inMemoryNeverPersists() {
        // `in_memory_store_never_dirties_for_disk` (`mru.rs:354-361`).
        var mru = PagerSlashMru()
        mru.touch("plan", now: 5)
        #expect(mru.takePersistSnapshot() == nil)
        mru.markDirty()
        #expect(mru.takePersistSnapshot() == nil)
    }

    @Test("a disk store snapshots once per change and round-trips through the file")
    func persistRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("slash-mru-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        var writer = PagerSlashMru(directory: directory)
        writer.touch("compact", now: 42)
        let snapshot = writer.takePersistSnapshot()
        #expect(snapshot != nil)
        // Dirty cleared: no redundant second write (`mru.rs:363-373`).
        #expect(writer.takePersistSnapshot() == nil)
        #expect(snapshot?.write() == true)

        var reader = PagerSlashMru(directory: directory)
        #expect(reader.lastUsed("compact") == 42)
    }

    @Test("mark_dirty requeues a snapshot after a failed write")
    func markDirtyRetries() {
        // `mark_dirty_requeues_after_failed_write` (`mru.rs:375-386`).
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("slash-mru-test-\(UUID().uuidString)")
        var mru = PagerSlashMru(directory: directory)
        mru.touch("plan", now: 7)
        #expect(mru.takePersistSnapshot() != nil)
        #expect(mru.takePersistSnapshot() == nil)
        mru.markDirty()
        #expect(mru.takePersistSnapshot() != nil)
    }

    @Test("legacy by_prefix files migrate to the flat map, keeping the max timestamp")
    func legacyMigration() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("slash-mru-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = #"{"by_prefix":{"m":{"model":10},"mo":{"model":20}}}"#
        try legacy.data(using: .utf8)!.write(
            to: directory.appendingPathComponent("slash-mru.json")
        )

        var mru = PagerSlashMru(directory: directory)
        #expect(mru.lastUsed("model") == 20)
    }

    @Test("a corrupt store file is ignored rather than trusted or crashed on")
    func corruptFileIgnored() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("slash-mru-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "not json".data(using: .utf8)!.write(
            to: directory.appendingPathComponent("slash-mru.json")
        )

        var mru = PagerSlashMru(directory: directory)
        #expect(mru.lastUsed("model") == 0)
    }
}

@Suite("Ranked registry pipeline")
struct PagerCommandRegistryRankingTests {
    private let registry = PagerCommandRegistry(commands: [
        PagerCommandDefinition(name: "quit", aliases: ["exit"], summary: "Quit"),
        PagerCommandDefinition(name: "help", summary: "Help"),
        PagerCommandDefinition(name: "theme", aliases: ["t"], summary: "Theme"),
        PagerCommandDefinition(name: "queue", summary: "Queue"),
        PagerCommandDefinition(name: "gboom", summary: "Egg", isHidden: true)
    ])

    @Test("a bare slash lists the curated registration order, uncapped")
    func bareSlashIsCurated() {
        // `slash/mod.rs:865-899`: registration order, hidden commands
        // filtered, no cap.
        let rows = registry.completions(for: "/")
        #expect(rows.map(\.commandName) == ["quit", "help", "theme", "queue"])
    }

    @Test("fuzzy queries reach non-prefix matches the old prefix filter dropped")
    func fuzzyReachesSubsequences() {
        // `hp` was unmatchable under prefix-only matching.
        let rows = registry.completions(for: "/hp")
        #expect(rows.map(\.commandName) == ["help"])
    }

    @Test("equal fuzzy scores fall to display order; recency overrides it")
    func recencyBoostsTies() {
        // Without MRU, `q` ties `queue`/`quit` and display order decides
        // (`slash/mod.rs:1003`).
        let cold = registry.completions(for: "/q")
        #expect(cold.map(\.commandName) == ["queue", "quit"])

        // A recent `/quit` outranks the tie — the MRU tiebreak sits between
        // score and display (`slash/mod.rs:996-1002`,
        // `mru_beats_tiebreak_on_equal_fuzzy_score`, `slash/mod.rs:2274`).
        let boosted = registry.completions(for: "/q", recency: ["quit": 1_000])
        #expect(boosted.map(\.commandName) == ["quit", "queue"])
    }

    @Test("double-slash queries suggest nothing")
    func doubleSlashRejected() {
        // `slash/mod.rs:901-904`.
        #expect(registry.completions(for: "/he/lp").isEmpty)
    }

    @Test("an exact alias wins the per-command dedupe at equal score")
    func exactAliasWins() {
        // `slash/mod.rs:934-940`: for query `t`, the alias trigger `t` is the
        // exact match, so the theme row records the alias.
        let rows = registry.completions(for: "/t")
        let theme = rows.first { $0.commandName == "theme" }
        #expect(theme?.matchedAlias == "t")
    }
}
