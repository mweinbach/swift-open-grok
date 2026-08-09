// PagerAgentsConfigStoreTests.swift
//
// The B9-b2 config writers in isolated homes: `set_default_agent`
// (`agents_modal.rs:730-752` at upstream 650c1db7) and `toggle_agent`
// (`:754-778`) — set, clear, preserve-unrelated-keys, every error arm's
// byte-parity copy, and failed-write consistency (the file on disk is
// what the modal must keep stating). Upstream's own in-file tests cover
// the create-template/guard shapes; these cover the same writer contract
// through the port's parse-mutate-serialize seam.

import Foundation
import Testing
@testable import OpenGrokPagerRender

private struct StoreFixture {
    let directory: URL
    let configPath: URL
    let store: PagerAgentsConfigStore

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-agents-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        configPath = directory.appendingPathComponent("config.toml")
        store = PagerAgentsConfigStore(configPath: configPath)
    }

    func dispose() {
        // A failed-write test may have dropped the directory's write bit;
        // restore it so the cleanup can actually remove the tree.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: directory.path
        )
        try? FileManager.default.removeItem(at: directory)
    }

    func write(_ toml: String) throws {
        try toml.write(to: configPath, atomically: true, encoding: .utf8)
    }

    func contents() throws -> String {
        try String(contentsOf: configPath, encoding: .utf8)
    }
}

private func writeError(_ body: () throws -> Void) -> PagerAgentsConfigWriteError? {
    do {
        try body()
        return nil
    } catch let error as PagerAgentsConfigWriteError {
        return error
    } catch {
        Issue.record("unexpected error type: \(error)")
        return nil
    }
}

@Suite("agents config store — toggle writer")
struct PagerAgentsToggleWriterTests {
    @Test("a missing file gains [subagents.toggle] with the explicit boolean, both directions")
    func createsFileAndRoundTrips() throws {
        let fixture = try StoreFixture()
        defer { fixture.dispose() }
        // `toggle_agent` creates the file and both tables when missing
        // (`:756-770`) and writes the explicit boolean (`:774`).
        try fixture.store.toggleAgent(name: "explore", enabled: false)
        var body = try fixture.contents()
        #expect(body.contains("[subagents.toggle]"))
        #expect(body.contains("explore = false"))
        // Re-enabling writes `true` explicitly — never removes the key
        // (upstream sets, it does not prune).
        try fixture.store.toggleAgent(name: "explore", enabled: true)
        body = try fixture.contents()
        #expect(body.contains("explore = true"))
        #expect(!body.contains("explore = false"))
    }

    @Test("unrelated keys, sibling [subagents] keys, and key order survive; comments do not")
    func preservesUnrelatedKeys() throws {
        let fixture = try StoreFixture()
        defer { fixture.dispose() }
        try fixture.write("""
        # a comment the port's serializer cannot keep
        [endpoints]
        xai_api_base_url = "https://example.test"

        [subagents]
        enabled = true

        [subagents.models]
        explore = "grok-4-fast"

        [agent]
        name = "grok-build"
        """)
        try fixture.store.toggleAgent(name: "plan", enabled: false)
        let body = try fixture.contents()
        #expect(body.contains("xai_api_base_url = \"https://example.test\""))
        #expect(body.contains("enabled = true"))
        #expect(body.contains("[subagents.models]"))
        #expect(body.contains("explore = \"grok-4-fast\""))
        #expect(body.contains("name = \"grok-build\""))
        #expect(body.contains("plan = false"))
        // Insertion order survives (`TOMLTable` is insertion-ordered and
        // `insert` updates existing keys in place): [endpoints] still
        // precedes [subagents].
        let endpointsIndex = try #require(body.range(of: "[endpoints]")).lowerBound
        let subagentsIndex = try #require(body.range(of: "[subagents]")).lowerBound
        #expect(endpointsIndex < subagentsIndex)
        // The recorded divergence from upstream's toml_edit: this port's
        // writer re-serializes the tree, so comments are dropped. Pinned
        // here so the loss is a stated cost, not a surprise.
        #expect(!body.contains("# a comment"))
    }

    @Test("non-table guards refuse with upstream's exact copy")
    func nonTableGuards() throws {
        let fixture = try StoreFixture()
        defer { fixture.dispose() }
        // `subagents` a scalar (`:765-767`).
        try fixture.write("subagents = 5\n")
        var error = writeError { try fixture.store.toggleAgent(name: "explore", enabled: false) }
        #expect(error?.message == "subagents is not a table")
        #expect(try fixture.contents() == "subagents = 5\n", "a refused write must not touch disk")
        // `subagents.toggle` a scalar (`:771-773`).
        try fixture.write("[subagents]\ntoggle = 5\n")
        error = writeError { try fixture.store.toggleAgent(name: "explore", enabled: false) }
        #expect(error?.message == "subagents.toggle is not a table")
    }
}

@Suite("agents config store — default-agent writer")
struct PagerAgentsDefaultWriterTests {
    @Test("set writes [agent] name, creating the table; clear removes only the key and keeps the header")
    func setAndClearRoundTrip() throws {
        let fixture = try StoreFixture()
        defer { fixture.dispose() }
        try fixture.store.setDefaultAgent("explore")
        var body = try fixture.contents()
        #expect(body.contains("[agent]"))
        #expect(body.contains("name = \"explore\""))
        // Setting again overwrites in place (`agent_table["name"] = …`).
        try fixture.store.setDefaultAgent("plan")
        body = try fixture.contents()
        #expect(body.contains("name = \"plan\""))
        #expect(!body.contains("name = \"explore\""))
        // Clear removes ONLY `name` (`:746-748`); like upstream's
        // toml_edit document, the emptied `[agent]` header stays behind —
        // the writer never prunes a table it did not create.
        try fixture.store.setDefaultAgent(nil)
        body = try fixture.contents()
        #expect(body.contains("[agent]"))
        #expect(!body.contains("name ="))
    }

    @Test("clear keeps sibling [agent] keys and unrelated tables")
    func clearPreservesSiblings() throws {
        let fixture = try StoreFixture()
        defer { fixture.dispose() }
        try fixture.write("""
        [agent]
        name = "explore"
        definition = "/tmp/custom.md"

        [subagents.toggle]
        plan = false
        """)
        try fixture.store.setDefaultAgent(nil)
        let body = try fixture.contents()
        #expect(!body.contains("name = \"explore\""))
        #expect(body.contains("definition = \"/tmp/custom.md\""))
        #expect(body.contains("plan = false"))
    }

    @Test("clear on a missing or non-table [agent] silently succeeds, upstream's own arm")
    func clearToleratesMissingTable() throws {
        let fixture = try StoreFixture()
        defer { fixture.dispose() }
        // Missing `[agent]` entirely: the `else if let` guard skips the
        // mutation but the document still writes (`:746-749`), so the
        // file exists afterwards.
        try fixture.store.setDefaultAgent(nil)
        #expect(FileManager.default.fileExists(atPath: fixture.configPath.path))
        // `agent` a scalar: clearing skips it untouched — only SETTING
        // refuses a non-table.
        try fixture.write("agent = \"oops\"\n")
        try fixture.store.setDefaultAgent(nil)
        #expect(try fixture.contents().contains("agent = \"oops\""))
    }

    @Test("setting onto a non-table [agent] refuses with upstream's exact copy")
    func setRefusesNonTable() throws {
        let fixture = try StoreFixture()
        defer { fixture.dispose() }
        try fixture.write("agent = \"oops\"\n")
        let error = writeError { try fixture.store.setDefaultAgent("explore") }
        #expect(error?.message == "[agent] is not a table")
        #expect(try fixture.contents() == "agent = \"oops\"\n")
    }
}

@Suite("agents config store — shared failure arms")
struct PagerAgentsStoreFailureTests {
    @Test("a non-empty unparseable config is refused untouched, with upstream's copy")
    func unparseableConfigIsNeverClobbered() throws {
        // `read_config_document_for_edit` (`config_toml_edit.rs:7-27`):
        // the one guard that keeps a single keystroke from replacing a
        // config the user could still repair by hand.
        let fixture = try StoreFixture()
        defer { fixture.dispose() }
        let bad = "this is [not valid toml\n"
        try fixture.write(bad)
        var error = writeError { try fixture.store.toggleAgent(name: "explore", enabled: false) }
        #expect(error?.message == "Could not read or parse config.toml")
        #expect(try fixture.contents() == bad)
        error = writeError { try fixture.store.setDefaultAgent("explore") }
        #expect(error?.message == "Could not read or parse config.toml")
        #expect(try fixture.contents() == bad)
    }

    @Test("a failed disk write surfaces upstream's prefix and leaves the file as it was")
    func failedWriteLeavesDiskAlone() throws {
        let fixture = try StoreFixture()
        defer { fixture.dispose() }
        let before = "[agent]\nname = \"explore\"\n"
        try fixture.write(before)
        // The atomic replace writes a sibling temp file first, so a
        // write-protected DIRECTORY (not file — rename ignores file
        // bits on POSIX) is what makes the write fail.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: fixture.directory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: fixture.directory.path
            )
        }
        let error = writeError { try fixture.store.toggleAgent(name: "explore", enabled: false) }
        #expect(error?.message.hasPrefix("Failed to write config.toml: ") == true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fixture.directory.path
        )
        #expect(try fixture.contents() == before, "a failed write must leave disk as it was")
    }
}
