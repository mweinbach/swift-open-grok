// LiveSessionRecoveryTests.swift
//
// Covers rewind: what a snapshot records, what a restore puts back, and the
// three ways a restore can decline to act.
//
// The assertions worth making here are the ones a user would notice going
// wrong. A rewind that reports success while leaving a file edited is worse
// than no rewind at all, so the tests check the bytes on disk rather than the
// return value alone; and a dry run that silently mutates would defeat the
// confirmation step, so that gets its own test.

import Foundation
import OpenGrokSamplingTypes
import Testing
@testable import OpenGrokCLI

// MARK: - Fixtures

private struct RewindFixture {
    let root: URL
    let home: URL
    let workspace: URL

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("w8-rewind-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    func write(_ relative: String, _ contents: String) throws {
        let url = workspace.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }

    func read(_ relative: String) -> String? {
        try? String(contentsOf: workspace.appendingPathComponent(relative), encoding: .utf8)
    }

    func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent(relative).path
        )
    }

    func coordinator(
        sessionID: String = "session",
        limits: LiveRewindLimits = .default
    ) async -> LiveRewindCoordinator {
        await LiveRewindCoordinator(
            openGrokHome: home,
            sessionID: sessionID,
            workingDirectory: workspace,
            limits: limits
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func userItems(_ prompts: [String]) -> [ConversationItem] {
    prompts.flatMap { prompt -> [ConversationItem] in
        [.user(prompt), .assistant(AssistantItem(content: "ok"))]
    }
}

// MARK: - Capture

@Test("a snapshot records the file as it was before the turn edited it")
func rewindCapturesPreTurnState() async throws {
    let fixture = try RewindFixture()
    defer { fixture.cleanup() }
    try fixture.write("a.swift", "original")

    let rewind = await fixture.coordinator()
    await rewind.beginPrompt(text: "edit a.swift")
    await rewind.capture(paths: ["a.swift"])
    // The turn edits the file after the snapshot was taken.
    try fixture.write("a.swift", "edited")
    await rewind.endPrompt()

    // `endPrompt` persists on a detached task; poll rather than sleep a fixed
    // interval so the test is not timing-dependent on a loaded machine.
    var points: [LiveRewindPointInfo] = []
    for _ in 0..<50 {
        points = await rewind.points()
        if !points.isEmpty { break }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    #expect(points.count == 1)
    #expect(points.first?.promptIndex == 0)
    #expect(points.first?.fileCount == 1)
    #expect(points.first?.preview == "edit a.swift")
}

@Test("only the first capture of a path in a prompt is kept")
func rewindFirstCaptureWins() async throws {
    let fixture = try RewindFixture()
    defer { fixture.cleanup() }
    try fixture.write("a.swift", "v1")

    let rewind = await fixture.coordinator()
    await rewind.beginPrompt(text: "two edits")
    await rewind.capture(paths: ["a.swift"])
    try fixture.write("a.swift", "v2")
    // A second tool call touching the same file must not overwrite the
    // pre-turn snapshot with the mid-turn state.
    await rewind.capture(paths: ["a.swift"])
    try fixture.write("a.swift", "v3")
    await rewind.endPrompt()
    try await settle(rewind)

    let outcome = try await rewind.restore(
        toPromptIndex: 0,
        mode: .filesOnly,
        force: true,
        currentItems: []
    )
    #expect(outcome.applied)
    #expect(fixture.read("a.swift") == "v1")
}

@Test("paths outside the workspace and inside .git are never snapshotted")
func rewindRefusesUnsafePaths() async throws {
    let fixture = try RewindFixture()
    defer { fixture.cleanup() }
    try fixture.write(".git/config", "[core]")
    let outside = fixture.root.appendingPathComponent("outside.txt")
    try Data("secret".utf8).write(to: outside)

    let rewind = await fixture.coordinator()
    await rewind.beginPrompt(text: "touch everything")
    await rewind.capture(paths: [".git/config", outside.path, "../outside.txt"])
    await rewind.endPrompt()
    // Nothing was capturable, so no point is recorded at all.
    try? await Task.sleep(nanoseconds: 100_000_000)
    #expect(await rewind.points().isEmpty)
}

@Test("a file over the size cap is recorded as skipped, not silently dropped")
func rewindRecordsOversizeSkips() async throws {
    let fixture = try RewindFixture()
    defer { fixture.cleanup() }
    try fixture.write("big.txt", String(repeating: "x", count: 4096))

    var limits = LiveRewindLimits.default
    limits.maxFileBytes = 1024
    let rewind = await fixture.coordinator(limits: limits)
    await rewind.beginPrompt(text: "edit big")
    await rewind.capture(paths: ["big.txt"])
    await rewind.endPrompt()
    try await settle(rewind)

    let points = await rewind.points()
    #expect(points.count == 1)
    #expect(points.first?.fileCount == 0)
    // The whole point of recording the skip: a restore can say the file is
    // unrestorable rather than reporting success without touching it.
    #expect(points.first?.skippedCount == 1)
}

// MARK: - Restore

@Test("restoring puts the pre-turn bytes back and deletes files the turn created")
func rewindRestoresFiles() async throws {
    let fixture = try RewindFixture()
    defer { fixture.cleanup() }
    try fixture.write("existing.swift", "before")

    let rewind = await fixture.coordinator()
    await rewind.beginPrompt(text: "make a mess")
    await rewind.capture(paths: ["existing.swift", "created.swift"])
    try fixture.write("existing.swift", "after")
    try fixture.write("created.swift", "brand new")
    await rewind.endPrompt()
    try await settle(rewind)

    let outcome = try await rewind.restore(
        toPromptIndex: 0,
        mode: .all,
        force: true,
        currentItems: userItems(["make a mess"])
    )
    #expect(outcome.applied)
    #expect(fixture.read("existing.swift") == "before")
    // A file that did not exist before the turn is removed, not left behind:
    // that is the difference between "undo" and "revert what I remember".
    #expect(!fixture.exists("created.swift"))
    #expect(outcome.revertedFiles.sorted() == ["created.swift", "existing.swift"])
}

@Test("a non-forced restore is a pure dry run")
func rewindDryRunMutatesNothing() async throws {
    let fixture = try RewindFixture()
    defer { fixture.cleanup() }
    try fixture.write("a.swift", "before")

    let rewind = await fixture.coordinator()
    await rewind.beginPrompt(text: "edit")
    await rewind.capture(paths: ["a.swift"])
    try fixture.write("a.swift", "after")
    await rewind.endPrompt()
    try await settle(rewind)

    let outcome = try await rewind.restore(
        toPromptIndex: 0,
        mode: .all,
        force: false,
        currentItems: userItems(["edit"])
    )
    #expect(!outcome.applied)
    #expect(outcome.cleanFiles == ["a.swift"])
    #expect(outcome.revertedFiles.isEmpty)
    #expect(fixture.read("a.swift") == "after")
    // The points survive a dry run, so the user can confirm and re-run.
    #expect(await rewind.points().count == 1)
}

@Test("a file changed outside the session is reported as a conflict and left alone")
func rewindDetectsExternalEdits() async throws {
    let fixture = try RewindFixture()
    defer { fixture.cleanup() }
    try fixture.write("a.swift", "before")

    let rewind = await fixture.coordinator()
    await rewind.beginPrompt(text: "edit")
    await rewind.capture(paths: ["a.swift"])
    try fixture.write("a.swift", "after")
    await rewind.endPrompt()
    try await settle(rewind)

    // Somebody else edits the file after the turn ended.
    try fixture.write("a.swift", "someone else's work")

    let outcome = try await rewind.restore(
        toPromptIndex: 0,
        mode: .all,
        force: true,
        currentItems: userItems(["edit"])
    )
    #expect(outcome.conflicts.map(\.path) == ["a.swift"])
    #expect(outcome.conflicts.first?.kind == .modifiedExternally)
    #expect(outcome.revertedFiles.isEmpty)
    // The unrelated edit survives: clobbering it would destroy work the
    // session never made and cannot restore.
    #expect(fixture.read("a.swift") == "someone else's work")
}

@Test("restoring drops the points for the prompts it undid")
func rewindTruncatesPoints() async throws {
    let fixture = try RewindFixture()
    defer { fixture.cleanup() }
    try fixture.write("a.swift", "v0")

    let rewind = await fixture.coordinator()
    for (index, version) in ["v1", "v2"].enumerated() {
        await rewind.beginPrompt(text: "prompt \(index)")
        await rewind.capture(paths: ["a.swift"])
        try fixture.write("a.swift", version)
        await rewind.endPrompt()
    }
    try await settle(rewind, expected: 2)

    _ = try await rewind.restore(
        toPromptIndex: 1,
        mode: .filesOnly,
        force: true,
        currentItems: []
    )
    let points = await rewind.points()
    #expect(points.map(\.promptIndex) == [0])
    // Prompt 1 is undone, so the file is back to what prompt 0 left.
    #expect(fixture.read("a.swift") == "v1")
}

@Test("a conversation-only rewind keeps the file snapshots it did not use")
func rewindConversationOnlyMergesPoints() async throws {
    let fixture = try RewindFixture()
    defer { fixture.cleanup() }
    try fixture.write("a.swift", "v0")

    let rewind = await fixture.coordinator()
    for (index, version) in ["v1", "v2"].enumerated() {
        await rewind.beginPrompt(text: "prompt \(index)")
        await rewind.capture(paths: ["a.swift"])
        try fixture.write("a.swift", version)
        await rewind.endPrompt()
    }
    try await settle(rewind, expected: 2)

    let outcome = try await rewind.restore(
        toPromptIndex: 0,
        mode: .conversationOnly,
        force: true,
        currentItems: userItems(["prompt 0", "prompt 1"])
    )
    #expect(outcome.applied)
    // No files were touched.
    #expect(outcome.revertedFiles.isEmpty)
    #expect(fixture.read("a.swift") == "v2")

    // The two points collapse into one at the target rather than being
    // discarded, so the edits still on disk remain undoable afterwards.
    let points = await rewind.points()
    #expect(points.map(\.promptIndex) == [0])

    let followUp = try await rewind.restore(
        toPromptIndex: 0,
        mode: .filesOnly,
        force: true,
        currentItems: []
    )
    #expect(followUp.applied)
    #expect(fixture.read("a.swift") == "v0")
}

@Test("restoring to a prompt that has not run is refused")
func rewindRefusesFuturePrompt() async throws {
    let fixture = try RewindFixture()
    defer { fixture.cleanup() }
    try fixture.write("a.swift", "v0")

    let rewind = await fixture.coordinator()
    await rewind.beginPrompt(text: "prompt 0")
    await rewind.capture(paths: ["a.swift"])
    await rewind.endPrompt()
    try await settle(rewind)

    await #expect(throws: LiveRewindError.self) {
        _ = try await rewind.restore(
            toPromptIndex: 5,
            mode: .all,
            force: true,
            currentItems: userItems(["prompt 0"])
        )
    }
}

// MARK: - History truncation

@Test("truncation cuts at the target prompt and keeps the system item")
func truncateConversationKeepsSystemPrompt() {
    let items: [ConversationItem] = [
        .system("you are a helpful agent"),
        .user("first"),
        .assistant(AssistantItem(content: "one")),
        .user("second"),
        .assistant(AssistantItem(content: "two")),
    ]
    let toSecond = liveTruncateConversation(items, toPromptIndex: 1)
    #expect(toSecond.count == 3)

    // Rewinding to the very first prompt still leaves the system prompt in
    // place: dropping it would change the agent's behaviour afterwards.
    let toFirst = liveTruncateConversation(items, toPromptIndex: 0)
    #expect(toFirst.count == 1)
    if case .system = toFirst[0] {} else {
        Issue.record("expected the system item to survive truncation to prompt 0")
    }
}

@Test("synthetic user turns do not consume a prompt index")
func truncateConversationIgnoresSyntheticTurns() {
    let items: [ConversationItem] = [
        .user(UserItem(
            content: [.text(text: "project instructions")],
            syntheticReason: .projectInstructions
        )),
        .user("real first"),
        .assistant(AssistantItem(content: "one")),
        .user("real second"),
    ]
    // Prompt 1 is "real second", so the injected instructions and the first
    // real turn both survive.
    let truncated = liveTruncateConversation(items, toPromptIndex: 1)
    #expect(truncated.count == 3)
    #expect(livePromptText(in: items, at: 1) == "real second")
}

// MARK: - Path extraction

@Test("tool arguments yield the paths a rewind point should snapshot")
func pathExtractionReadsKnownKeys() {
    #expect(
        LiveRewindPathExtraction.paths(fromArguments: .object([
            "file_path": .string("Sources/A.swift"),
        ])) == ["Sources/A.swift"]
    )
    #expect(
        LiveRewindPathExtraction.paths(fromArguments: .object([
            "paths": .array([.string("a"), .string("b")]),
        ])) == ["a", "b"]
    )
    // An unrecognized shape yields nothing rather than a wrong guess.
    #expect(
        LiveRewindPathExtraction.paths(fromArguments: .object([
            "command": .string("rm -rf /"),
        ])).isEmpty
    )
}

// MARK: - Helpers

/// Wait for `endPrompt`'s detached persist to land.
private func settle(
    _ rewind: LiveRewindCoordinator,
    expected: Int = 1
) async throws {
    for _ in 0..<100 {
        if await rewind.points().count >= expected { return }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    Issue.record("rewind points did not reach \(expected) in time")
}
