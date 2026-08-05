// LiveSessionsCompositionTests.swift
//
// `open-grok sessions list|show|delete` against a fixture store. Every test
// points OPENGROK_HOME at a fresh temporary directory, so the real
// `~/.opengrok` is never read and never written.

import Foundation
import OpenGrokSamplingTypes
import Testing

@testable import OpenGrokCLI

/// An isolated OPENGROK_HOME with a writable session directory.
private struct SessionsFixture {
    let home: URL
    let environment: [String: String]

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-sessions-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sessions", isDirectory: true),
            withIntermediateDirectories: true
        )
        home = root
        environment = ["OPENGROK_HOME": root.path, "HOME": root.path]
    }

    func dispose() { try? FileManager.default.removeItem(at: home) }

    var sessionsDirectory: URL {
        home.appendingPathComponent("sessions", isDirectory: true)
    }

    /// Write one session file in exactly the layout `LiveConversationStore`
    /// produces: `$OPENGROK_HOME/sessions/<id>.json`.
    @discardableResult
    func write(
        id: String,
        cwd: String = "/work/repo",
        created: Date = Date(timeIntervalSince1970: 1_700_000_000),
        updated: Date = Date(timeIntervalSince1970: 1_700_000_500),
        parent: String? = nil,
        items: [ConversationItem] = []
    ) throws -> LiveConversationRecord {
        let record = LiveConversationRecord(
            sessionID: id,
            workingDirectory: cwd,
            parentSessionID: parent,
            createdAt: created,
            updatedAt: updated,
            items: items
        )
        let data = try JSONEncoder().encode(record)
        try data.write(
            to: sessionsDirectory.appendingPathComponent(id).appendingPathExtension("json")
        )
        return record
    }
}

private func userTurn(_ text: String, synthetic: SyntheticReason? = nil) -> ConversationItem {
    .user(UserItem(content: [.text(text: text)], syntheticReason: synthetic))
}

private func assistantTurn(_ text: String, model: String? = nil) -> ConversationItem {
    .assistant(AssistantItem(content: text, modelId: model))
}

private func sessionOptions(
    _ action: CLISessionAction,
    identifier: String? = nil,
    json: Bool = false
) -> CLISessionOptions {
    CLISessionOptions(action: action, identifier: identifier, json: json)
}

@Suite("Live sessions composition")
struct LiveSessionsCompositionTests {

    // MARK: parsing

    @Test("sessions show and delete parse with a positional id")
    func parsesShowAndDelete() throws {
        #expect(
            try CLICommandParser.parseOrThrow(["sessions", "show", "abc"])
                == .sessions(CLISessionOptions(action: .show, identifier: "abc"))
        )
        #expect(
            try CLICommandParser.parseOrThrow(["sessions", "delete", "abc"])
                == .sessions(CLISessionOptions(action: .delete, identifier: "abc"))
        )
        #expect(
            try CLICommandParser.parseOrThrow(["sessions", "list", "--json"])
                == .sessions(CLISessionOptions(action: .list, json: true))
        )
    }

    @Test("route only claims the actions it serves")
    func handlesOnlyServedActions() {
        #expect(LiveSessionsComposition.handles(.sessions(sessionOptions(.list))))
        #expect(LiveSessionsComposition.handles(.sessions(sessionOptions(.show, identifier: "a"))))
        #expect(LiveSessionsComposition.handles(.sessions(sessionOptions(.delete, identifier: "a"))))
        // `resume` belongs to the launch path, not this route.
        #expect(!LiveSessionsComposition.handles(.sessions(sessionOptions(.resume))))
        #expect(!LiveSessionsComposition.handles(.doctor))
    }

    // MARK: list

    @Test("list reports the empty store with the Rust wording")
    func listEmptyStore() throws {
        let fixture = try SessionsFixture()
        defer { fixture.dispose() }
        let (streams, out, err) = CLIStreams.buffered()

        try LiveSessionsComposition.run(
            options: sessionOptions(.list),
            environment: fixture.environment,
            streams: streams
        )

        #expect(out.contents == "No sessions found.\n")
        #expect(err.contents.isEmpty)
    }

    @Test("list shows id, dates, model and derived title newest first")
    func listOrdersByLastActivity() throws {
        let fixture = try SessionsFixture()
        defer { fixture.dispose() }
        try fixture.write(
            id: "older",
            updated: Date(timeIntervalSince1970: 1_700_000_100),
            items: [userTurn("Fix the parser"), assistantTurn("done", model: "grok-4")]
        )
        try fixture.write(
            id: "newer",
            updated: Date(timeIntervalSince1970: 1_700_009_000),
            items: [userTurn("Add a cache"), assistantTurn("ok", model: "grok-code")]
        )
        let (streams, out, err) = CLIStreams.buffered()

        try LiveSessionsComposition.run(
            options: sessionOptions(.list),
            environment: fixture.environment,
            streams: streams
        )

        let lines = out.contents.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("SESSION ID"))
        #expect(lines[0].contains("MODEL"))
        #expect(lines[1].hasPrefix("newer"))
        #expect(lines[1].contains("grok-code"))
        #expect(lines[1].contains("Add a cache"))
        #expect(lines[2].hasPrefix("older"))
        #expect(lines[2].contains("grok-4"))
        #expect(lines[2].contains("Fix the parser"))
        #expect(err.contents.isEmpty)
    }

    @Test("list titles skip synthetic user turns")
    func listSkipsSyntheticTurns() throws {
        let fixture = try SessionsFixture()
        defer { fixture.dispose() }
        try fixture.write(
            id: "synthetic",
            items: [
                userTurn("INJECTED PROJECT CONTEXT", synthetic: .projectInstructions),
                userTurn("  \n  the real question  "),
            ]
        )
        let (streams, out, _) = CLIStreams.buffered()

        try LiveSessionsComposition.run(
            options: sessionOptions(.list),
            environment: fixture.environment,
            streams: streams
        )

        #expect(out.contents.contains("the real question"))
        #expect(!out.contents.contains("INJECTED PROJECT CONTEXT"))
    }

    @Test("list falls back when there is no title or model")
    func listFallsBack() throws {
        let fixture = try SessionsFixture()
        defer { fixture.dispose() }
        try fixture.write(id: "bare")
        let (streams, out, _) = CLIStreams.buffered()

        try LiveSessionsComposition.run(
            options: sessionOptions(.list),
            environment: fixture.environment,
            streams: streams
        )

        #expect(out.contents.contains("(no title)"))
        #expect(out.contents.contains("bare"))
    }

    @Test("list skips an unreadable session instead of failing the listing")
    func listSkipsCorruptFile() throws {
        let fixture = try SessionsFixture()
        defer { fixture.dispose() }
        try fixture.write(id: "good", items: [userTurn("keeps working")])
        try Data("{ not json".utf8).write(
            to: fixture.sessionsDirectory.appendingPathComponent("torn.json")
        )
        let (streams, out, _) = CLIStreams.buffered()

        try LiveSessionsComposition.run(
            options: sessionOptions(.list),
            environment: fixture.environment,
            streams: streams
        )

        #expect(out.contents.contains("good"))
        #expect(!out.contents.contains("torn"))
    }

    @Test("list --json emits one object per session")
    func listJSON() throws {
        let fixture = try SessionsFixture()
        defer { fixture.dispose() }
        try fixture.write(
            id: "json-session",
            cwd: "/work/repo",
            items: [userTurn("A title"), assistantTurn("reply", model: "grok-4")]
        )
        let (streams, out, _) = CLIStreams.buffered()

        try LiveSessionsComposition.run(
            options: sessionOptions(.list, json: true),
            environment: fixture.environment,
            streams: streams
        )

        let decoded = try JSONSerialization.jsonObject(with: Data(out.contents.utf8))
        let rows = try #require(decoded as? [[String: Any]])
        #expect(rows.count == 1)
        #expect(rows[0]["id"] as? String == "json-session")
        #expect(rows[0]["title"] as? String == "A title")
        #expect(rows[0]["model"] as? String == "grok-4")
        #expect(rows[0]["cwd"] as? String == "/work/repo")
        #expect(rows[0]["num_messages"] as? Int == 2)
        #expect(rows[0]["last_activity_at"] as? String == "2023-11-14T22:21:40Z")
    }

    // MARK: show

    @Test("show prints the session detail")
    func showSession() throws {
        let fixture = try SessionsFixture()
        defer { fixture.dispose() }
        try fixture.write(
            id: "detail",
            cwd: "/work/repo",
            parent: "origin-session",
            items: [userTurn("Explain the cache"), assistantTurn("Here", model: "grok-4")]
        )
        let (streams, out, err) = CLIStreams.buffered()

        try LiveSessionsComposition.run(
            options: sessionOptions(.show, identifier: "detail"),
            environment: fixture.environment,
            streams: streams
        )

        #expect(out.contents.contains("Session:    detail"))
        #expect(out.contents.contains("Directory:  /work/repo"))
        #expect(out.contents.contains("Title:      Explain the cache"))
        #expect(out.contents.contains("Model:      grok-4"))
        #expect(out.contents.contains("Messages:   2 (1 user, 1 assistant)"))
        #expect(out.contents.contains("Forked from: origin-session"))
        #expect(err.contents.isEmpty)
    }

    @Test("show requires an id and rejects an unknown one")
    func showRejectsBadInput() throws {
        let fixture = try SessionsFixture()
        defer { fixture.dispose() }
        let (streams, _, _) = CLIStreams.buffered()

        #expect(throws: CLIApplicationError.self) {
            try LiveSessionsComposition.run(
                options: sessionOptions(.show),
                environment: fixture.environment,
                streams: streams
            )
        }
        #expect(throws: CLIApplicationError.self) {
            try LiveSessionsComposition.run(
                options: sessionOptions(.show, identifier: "missing"),
                environment: fixture.environment,
                streams: streams
            )
        }
    }

    // MARK: delete

    @Test("delete removes exactly the named session")
    func deleteRemovesOne() throws {
        let fixture = try SessionsFixture()
        defer { fixture.dispose() }
        try fixture.write(id: "doomed")
        try fixture.write(id: "keeper")
        let (streams, out, err) = CLIStreams.buffered()

        try LiveSessionsComposition.run(
            options: sessionOptions(.delete, identifier: "doomed"),
            environment: fixture.environment,
            streams: streams
        )

        #expect(out.contents == "Deleted session doomed\n")
        #expect(err.contents.isEmpty)
        let survivors = try FileManager.default.contentsOfDirectory(
            atPath: fixture.sessionsDirectory.path
        )
        #expect(survivors == ["keeper.json"])
    }

    @Test("delete reports a miss without failing")
    func deleteMiss() throws {
        let fixture = try SessionsFixture()
        defer { fixture.dispose() }
        let (streams, out, _) = CLIStreams.buffered()

        try LiveSessionsComposition.run(
            options: sessionOptions(.delete, identifier: "ghost"),
            environment: fixture.environment,
            streams: streams
        )

        #expect(out.contents == "No session found with id ghost.\n")
    }

    @Test("delete requires an id and refuses a traversal id")
    func deleteRefusesBadIdentifiers() throws {
        let fixture = try SessionsFixture()
        defer { fixture.dispose() }
        let (streams, _, _) = CLIStreams.buffered()

        #expect(throws: CLIApplicationError.self) {
            try LiveSessionsComposition.run(
                options: sessionOptions(.delete),
                environment: fixture.environment,
                streams: streams
            )
        }
        #expect(throws: CLIApplicationError.self) {
            try LiveSessionsComposition.run(
                options: sessionOptions(.delete, identifier: "../escape"),
                environment: fixture.environment,
                streams: streams
            )
        }
    }

    @Test("delete --json reports the outcome")
    func deleteJSON() throws {
        let fixture = try SessionsFixture()
        defer { fixture.dispose() }
        try fixture.write(id: "target")
        let (streams, out, _) = CLIStreams.buffered()

        try LiveSessionsComposition.run(
            options: sessionOptions(.delete, identifier: "target", json: true),
            environment: fixture.environment,
            streams: streams
        )

        let decoded = try JSONSerialization.jsonObject(with: Data(out.contents.utf8))
        let payload = try #require(decoded as? [String: Any])
        #expect(payload["id"] as? String == "target")
        #expect(payload["deleted"] as? Bool == true)
    }

    // MARK: isolation

    @Test("the route never touches the real opengrok home")
    func neverTouchesRealHome() throws {
        let fixture = try SessionsFixture()
        defer { fixture.dispose() }
        let resolved = OpenGrokHomeResolver.resolve(environment: fixture.environment)
        #expect(resolved.standardizedFileURL.path == fixture.home.standardizedFileURL.path)
        #expect(!OpenGrokHomeResolver.isLegacyGrokPath(resolved, environment: fixture.environment))
    }
}
