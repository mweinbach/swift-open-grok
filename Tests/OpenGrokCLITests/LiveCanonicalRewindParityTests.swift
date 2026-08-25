import Foundation
import OpenGrokSamplingTypes
import OpenGrokSessionPersistence
import OpenGrokShared
import OpenGrokShellSessionSupport
import Testing

@testable import OpenGrokCLI

private struct CanonicalRewindFixture {
    let root: URL
    let home: URL
    let workspace: URL
    let outside: URL
    let sessionID = "rewind-parity"

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-canonical-rewind-\(UUID().uuidString)",
            isDirectory: true
        )
        home = root.appendingPathComponent("home", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        outside = root.appendingPathComponent("outside", isDirectory: true)
        for directory in [home, workspace, outside] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    func write(_ value: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(value.utf8).write(to: url)
    }

    func persist(
        before: [LiveRewindSnapshot],
        after: [LiveRewindSnapshot] = []
    ) async {
        var point = LiveRewindPoint(promptIndex: 0, createdAt: Date(), promptText: "rewind")
        point.before = before
        point.after = after
        await LiveRewindStore(openGrokHome: home, sessionID: sessionID).append(point)
    }

    func coordinator(items: [ConversationItem] = [.user("rewind")]) async -> LiveRewindCoordinator {
        await LiveRewindCoordinator(
            openGrokHome: home,
            sessionID: sessionID,
            workingDirectory: workspace,
            conversationItems: items
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("Canonical rewind containment and replay parity")
struct LiveCanonicalRewindParityTests {
    @Test(
        "persisted hostile snapshot paths fail before previews or workspace mutations",
        arguments: [
            "../outside/secret.txt",
            "/absolute/secret.txt",
            "nested/../secret.txt",
            "nested//secret.txt",
            ".git/config",
            "nested/.git/config",
            "C:\\outside\\secret.txt",
            "nested\\secret.txt",
        ]
    )
    func hostilePersistedSnapshotsFailClosed(_ path: String) async throws {
        let fixture = try CanonicalRewindFixture()
        defer { fixture.cleanup() }
        let safe = fixture.workspace.appendingPathComponent("safe.txt")
        let outside = fixture.outside.appendingPathComponent("secret.txt")
        try fixture.write("changed", to: safe)
        try fixture.write("untouched secret", to: outside)

        await fixture.persist(before: [
            LiveRewindSnapshot(path: "safe.txt", content: "restored"),
            LiveRewindSnapshot(path: path, content: "attacker controlled"),
        ], after: [LiveRewindSnapshot(path: "safe.txt", content: "changed")])
        let coordinator = await fixture.coordinator()

        await #expect(throws: LiveRewindError.self) {
            _ = try await coordinator.restore(
                toPromptIndex: 0,
                mode: .all,
                force: true,
                currentItems: [.user("rewind")]
            )
        }

        #expect(try String(contentsOf: safe, encoding: .utf8) == "changed")
        #expect(try String(contentsOf: outside, encoding: .utf8) == "untouched secret")
        #expect(await coordinator.points().count == 1)
    }

    @Test("malicious after-only snapshots cannot preview or read outside the workspace")
    func afterSnapshotCannotEscape() async throws {
        let fixture = try CanonicalRewindFixture()
        defer { fixture.cleanup() }
        let safe = fixture.workspace.appendingPathComponent("safe.txt")
        try fixture.write("changed", to: safe)
        await fixture.persist(
            before: [LiveRewindSnapshot(path: "safe.txt", content: "before")],
            after: [LiveRewindSnapshot(path: "../outside/secret.txt", content: "secret")]
        )
        let coordinator = await fixture.coordinator()

        await #expect(throws: LiveRewindError.self) {
            _ = try await coordinator.restore(
                toPromptIndex: 0,
                mode: .all,
                force: false,
                currentItems: [.user("rewind")]
            )
        }
        #expect(try String(contentsOf: safe, encoding: .utf8) == "changed")
    }

    @Test("swapping a captured ancestor for an outside symlink blocks preview and restore")
    func replacedAncestorCannotRedirectRewind() async throws {
        let fixture = try CanonicalRewindFixture()
        defer { fixture.cleanup() }
        let nested = fixture.workspace.appendingPathComponent("nested", isDirectory: true)
        let file = nested.appendingPathComponent("secret.txt")
        let outside = fixture.outside.appendingPathComponent("secret.txt")
        try fixture.write("before", to: file)
        try fixture.write("outside secret", to: outside)

        let coordinator = await fixture.coordinator(items: [])
        await coordinator.beginPrompt(text: "edit nested file")
        await coordinator.capture(paths: ["nested/secret.txt"])
        try fixture.write("after", to: file)
        await coordinator.endPrompt()

        try FileManager.default.removeItem(at: nested)
        try FileManager.default.createSymbolicLink(at: nested, withDestinationURL: fixture.outside)

        for force in [false, true] {
            await #expect(throws: LiveRewindError.self) {
                _ = try await coordinator.restore(
                    toPromptIndex: 0,
                    mode: .all,
                    force: force,
                    currentItems: [.user("edit nested file")]
                )
            }
        }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "outside secret")
    }

    @Test("final symlinks are rejected for both snapshot writes and deletion")
    func finalSymlinkCannotTargetOutsideFile() async throws {
        let fixture = try CanonicalRewindFixture()
        defer { fixture.cleanup() }
        let outside = fixture.outside.appendingPathComponent("secret.txt")
        let link = fixture.workspace.appendingPathComponent("link.txt")
        try fixture.write("outside secret", to: outside)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        await fixture.persist(before: [LiveRewindSnapshot(path: "link.txt", content: nil)])
        let coordinator = await fixture.coordinator()

        await #expect(throws: LiveRewindError.self) {
            _ = try await coordinator.restore(
                toPromptIndex: 0,
                mode: .filesOnly,
                force: true,
                currentItems: []
            )
        }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "outside secret")
        #expect(FileManager.default.fileExists(atPath: link.path))
    }

    @Test("missing canonical compaction checkpoints block restoration before files change")
    func invalidCanonicalReplayCannotPartiallyRestore() async throws {
        let fixture = try CanonicalRewindFixture()
        defer { fixture.cleanup() }
        let currentItems: [ConversationItem] = [.user("rewind")]
        var record = LiveConversationRecord.new(
            sessionID: fixture.sessionID,
            workingDirectory: fixture.workspace
        )
        record.items = currentItems
        try await LiveConversationStore(openGrokHome: fixture.home).save(record)

        let missingCheckpoint = try SessionUpdateEnvelope(
            method: "_x.ai/session/update",
            params: .object([
                "sessionId": .string(fixture.sessionID),
                "update": .object([
                    "sessionUpdate": .string("compaction_checkpoint"),
                    "checkpoint_id": .string("missing-checkpoint"),
                    "prompt_index_at_compaction": .number(.int64(1)),
                ]),
            ])
        )
        try SessionDocumentStore(grokHome: fixture.home).appendUpdate(
            missingCheckpoint,
            sessionID: fixture.sessionID,
            cwd: fixture.workspace.path
        )
        let safe = fixture.workspace.appendingPathComponent("safe.txt")
        try fixture.write("changed", to: safe)
        await fixture.persist(
            before: [LiveRewindSnapshot(path: "safe.txt", content: "before")],
            after: [LiveRewindSnapshot(path: "safe.txt", content: "changed")]
        )
        let coordinator = await fixture.coordinator(items: currentItems)

        await #expect(throws: LiveRewindError.self) {
            _ = try await coordinator.restore(
                toPromptIndex: 0,
                mode: .all,
                force: true,
                currentItems: currentItems
            )
        }
        #expect(try String(contentsOf: safe, encoding: .utf8) == "changed")
        #expect(await coordinator.points().count == 1)
    }

    @Test("canonical rewind marker is a durable Rust-compatible xAI update envelope")
    func markerUsesCanonicalJournal() async throws {
        let fixture = try CanonicalRewindFixture()
        defer { fixture.cleanup() }
        try await LiveConversationStore(openGrokHome: fixture.home).save(.new(
            sessionID: fixture.sessionID,
            workingDirectory: fixture.workspace
        ))

        try LiveCanonicalRewind.appendMarker(
            targetPromptIndex: 3,
            openGrokHome: fixture.home,
            sessionID: fixture.sessionID,
            workingDirectory: fixture.workspace
        )

        let directory = try SessionDocumentStore(grokHome: fixture.home).sessionDirectory(
            sessionID: fixture.sessionID,
            cwd: fixture.workspace.path
        )
        let journal = try String(
            contentsOf: directory.appendingPathComponent("updates.jsonl"),
            encoding: .utf8
        )
        let line = try #require(journal.split(whereSeparator: \.isNewline).last)
        let marker = try JSONDecoder().decode(SessionUpdateEnvelope.self, from: Data(line.utf8))
        #expect(marker.method == "_x.ai/session/update")
        guard case .object(let params) = marker.params,
              case .object(let update)? = params["update"]
        else {
            Issue.record("canonical rewind marker was not a typed xAI update envelope")
            return
        }
        #expect(params["sessionId"] == .string(fixture.sessionID))
        #expect(update["sessionUpdate"] == .string("rewind_marker"))
        #expect(update["target_prompt_index"] == .number(.int64(3)))
    }
}
