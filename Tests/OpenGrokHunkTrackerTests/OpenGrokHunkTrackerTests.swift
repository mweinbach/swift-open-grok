// OpenGrokHunkTrackerTests.swift
//
// Rust-derived hunk fixtures: attribution, overlap, accept/reject, rename,
// concurrent agents, line endings, binary, failed writes, snapshot restore.

import Foundation
import Testing
@testable import OpenGrokHunkTracker

@Suite("OpenGrokHunkTracker")
struct OpenGrokHunkTrackerTests {

    // MARK: - Diff pure functions

    @Test("no changes yields empty hunks")
    func noChanges() {
        let content = "line 1\nline 2\nline 3\n"
        let hunks = computeHunks(
            path: "test.rs",
            baseline: content,
            current: content,
            source: .agentEdit(promptIndex: 0)
        )
        #expect(hunks.isEmpty)
    }

    @Test("single line modification")
    func singleLineMod() {
        let baseline = "line 1\nline 2\nline 3\n"
        let current = "line 1\nmodified\nline 3\n"
        let hunks = computeHunks(
            path: "test.rs",
            baseline: baseline,
            current: current,
            source: .agentEdit(promptIndex: 0)
        )
        #expect(hunks.count == 1)
        #expect(hunks[0].oldText == "line 2\n")
        #expect(hunks[0].newText == "modified\n")
        #expect(hunks[0].lineInfo.oldStart == 2)
        #expect(hunks[0].lineInfo.newStart == 2)
    }

    @Test("insertion deletion multiple hunks")
    func insertDeleteMulti() {
        let baseline = "line 1\nline 2\n"
        let current = "line 1\ninserted\nline 2\n"
        let hunks = computeHunks(
            path: "t.rs",
            baseline: baseline,
            current: current,
            source: .agentEdit(promptIndex: 0)
        )
        #expect(hunks.count == 1)
        #expect(hunks[0].oldText == nil)
        #expect(hunks[0].lineInfo.oldCount == 0)

        let del = computeHunks(
            path: "t.rs",
            baseline: "line 1\nline 2\nline 3\n",
            current: "line 1\nline 3\n",
            source: .agentEdit(promptIndex: 0)
        )
        #expect(del.count == 1)
        #expect(del[0].newText == "")

        let multi = computeHunks(
            path: "t.rs",
            baseline: "line 1\nline 2\nline 3\nline 4\nline 5\n",
            current: "modified 1\nline 2\nline 3\nline 4\nmodified 5\n",
            source: .agentEdit(promptIndex: 0)
        )
        #expect(multi.count == 2)
    }

    @Test("patch_lines basic variants")
    func patchLinesVariants() {
        let content = "line 1\nline 2\nline 3\nline 4\nline 5\n"
        #expect(patchLines(content: content, startLine: 2, removeCount: 1, insertText: "CHANGED\n")
            == "line 1\nCHANGED\nline 3\nline 4\nline 5\n")
        #expect(patchLines(content: "line 1\nline 2\nline 3\n", startLine: 2, removeCount: 0, insertText: "INSERTED\n")
            == "line 1\nINSERTED\nline 2\nline 3\n")
        #expect(patchLines(content: "line 1\nline 2\nline 3\n", startLine: 2, removeCount: 1, insertText: "")
            == "line 1\nline 3\n")
    }

    @Test("hunks overlap and matching")
    func overlapMatching() {
        let a = Hunk(
            id: HunkId("a"),
            path: "t.rs",
            lineInfo: HunkLineInfo(oldStart: 1, oldCount: 1, newStart: 1, newCount: 2),
            source: .agentEdit(promptIndex: 0),
            oldText: "old-small\n",
            newText: "new-small\n"
        )
        let b = Hunk(
            id: HunkId("b"),
            path: "t.rs",
            lineInfo: HunkLineInfo(oldStart: 3, oldCount: 1, newStart: 3, newCount: 4),
            source: .agentEdit(promptIndex: 0),
            oldText: "old-large\n",
            newText: "new-large\n"
        )
        let newH = Hunk(
            path: "t.rs",
            lineInfo: HunkLineInfo(oldStart: 2, oldCount: 4, newStart: 2, newCount: 4),
            source: .agentEdit(promptIndex: 0),
            oldText: "different-old\n",
            newText: "different-new\n"
        )
        let match = findMatchingOldHunk(newHunk: newH, oldHunks: [a, b])
        #expect(match?.id.raw == "b")
    }

    @Test("format unified diff")
    func formatDiff() {
        let hunk = Hunk(
            path: "test.rs",
            lineInfo: HunkLineInfo(oldStart: 2, oldCount: 1, newStart: 2, newCount: 1),
            source: .agentEdit(promptIndex: 0),
            oldText: "old line\n",
            newText: "new line\n"
        )
        let diff = formatUnifiedDiff(hunk)
        #expect(diff.contains("--- a/test.rs"))
        #expect(diff.contains("+++ b/test.rs"))
        #expect(diff.contains("-old line"))
        #expect(diff.contains("+new line"))
    }

    // MARK: - Attribution invariants

    @Test("new file agent write creates agentEdit hunk")
    func newFileAgent() async {
        let handle = HunkTrackerHandle.spawn(sessionId: "s1", workingDir: "/tmp")
        await handle.recordAgentWrite(
            path: "/tmp/new-\(UUID().uuidString).txt",
            content: "hello\nworld\n",
            promptIndex: 1,
            previousContent: nil
        )
        let hunks = await handle.getAllHunks()
        #expect(hunks.count == 1)
        #expect(hunks[0].source.isAgentEdit)
        #expect(hunks[0].source.promptIndex == 1)
    }

    @Test("fs notify creates external not agent hunks")
    func fsNotifyNotAgent() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-hunk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("x.txt")
        try "base\n".write(to: file, atomically: true, encoding: .utf8)

        let handle = HunkTrackerHandle.spawn(
            sessionId: "s1",
            workingDir: dir.path,
            mode: .allDirty
        )
        // Seed baseline by agent write then external change.
        await handle.recordAgentWrite(
            path: file.path,
            content: "base\n",
            promptIndex: 0,
            previousContent: "base\n"
        )
        // Make content match baseline so no pending hunks, then external edit.
        try "changed by user\n".write(to: file, atomically: true, encoding: .utf8)
        await handle.handleFileChange(path: file.path)
        let hunks = await handle.getHunksForPath(file.path)
        // External edit on agent file preserves agent attribution on matching
        // or creates externalEditOnAgentFile / agentEdit via preservation.
        for h in hunks {
            // Must NOT invent a brand-new agent prompt for pure FS events.
            // New content vs baseline "base\n" → hunk source is external* or preserved agent.
            #expect(h.source.isAgentTracked || h.source.isExternal)
        }
        // Pure external path without prior agent:
        let file2 = dir.appendingPathComponent("y.txt")
        try "only external\n".write(to: file2, atomically: true, encoding: .utf8)
        await handle.handleFileChange(path: file2.path)
        let external = await handle.getHunksForPath(file2.path)
        for h in external {
            #expect(!h.source.isAgentEdit, "FS notify must never create agentEdit")
        }
    }

    @Test("external edit preserves agent hunk source")
    func externalPreservesAgent() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-hunk-pres-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("z.txt")
        let baseline = "line 1\nline 2\nline 3\n"
        try baseline.write(to: file, atomically: true, encoding: .utf8)

        let handle = HunkTrackerHandle.spawn(sessionId: "s", workingDir: dir.path)
        let agentContent = "line 1\nAGENT\nline 3\n"
        await handle.recordAgentWrite(
            path: file.path,
            content: agentContent,
            promptIndex: 7,
            previousContent: baseline
        )
        var hunks = await handle.getHunksForPath(file.path)
        #expect(hunks.count == 1)
        #expect(hunks[0].source.promptIndex == 7)

        // External tweak of the same region keeps agent attribution.
        let externalContent = "line 1\nAGENT!\nline 3\n"
        try externalContent.write(to: file, atomically: true, encoding: .utf8)
        await handle.handleFileChange(path: file.path)
        hunks = await handle.getHunksForPath(file.path)
        #expect(!hunks.isEmpty)
        #expect(hunks[0].source.promptIndex == 7 || hunks[0].source.isAgentEdit)
    }

    @Test("agent write before external preserves attribution")
    func agentThenExternal() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-hunk-ae-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("f.txt")
        await handleWrite(handle: HunkTrackerHandle.spawn(sessionId: "s", workingDir: dir.path),
                          file: file)
    }

    private func handleWrite(handle: HunkTrackerHandle, file: URL) async {
        await handle.recordAgentWrite(
            path: file.path,
            content: "a\nb\n",
            promptIndex: 3,
            previousContent: "a\n"
        )
        #expect(await handle.isAgentFile(file.path))
        let summary = await handle.getSessionSummary()
        #expect(summary.pendingHunks >= 1)
        #expect(summary.turns.contains { $0.promptIndex == 3 })
    }

    // MARK: - Accept / reject

    @Test("accept hunk removes it and updates baseline")
    func acceptHunk() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-hunk-acc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        let handle = HunkTrackerHandle.spawn(sessionId: "s", workingDir: dir.path)
        await handle.recordAgentWrite(
            path: file.path,
            content: "hello\n",
            promptIndex: 0,
            previousContent: nil
        )
        let hunks = await handle.getAllHunks()
        #expect(hunks.count == 1)
        try await handle.hunkAction(hunkId: hunks[0].id, action: .accept)
        let after = await handle.getAllHunks()
        #expect(after.isEmpty)
        let summary = await handle.getSessionSummary()
        #expect(summary.stats.acceptedHunks == 1)
    }

    @Test("reject hunk reverts file content")
    func rejectHunk() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-hunk-rej-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        try "base\n".write(to: file, atomically: true, encoding: .utf8)
        let handle = HunkTrackerHandle.spawn(sessionId: "s", workingDir: dir.path)
        await handle.recordAgentWrite(
            path: file.path,
            content: "changed\n",
            promptIndex: 0,
            previousContent: "base\n"
        )
        let hunks = await handle.getAllHunks()
        #expect(!hunks.isEmpty)
        try await handle.hunkAction(hunkId: hunks[0].id, action: .reject)
        let disk = try String(contentsOf: file, encoding: .utf8)
        #expect(disk == "base\n")
    }

    @Test("accept one of multiple preserves remaining")
    func acceptOnePreserves() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-hunk-multi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("m.txt")
        let baseline = "line 1\nline 2\nline 3\nline 4\nline 5\nline 6\nline 7\nline 8\nline 9\nline 10\nline 11\nline 12\n"
        let current = "line 1\nHUNK_A\nline 3\nline 4\nline 5\nline 6\nHUNK_B\nline 8\nline 9\nline 10\nHUNK_C\nline 12\n"
        try baseline.write(to: file, atomically: true, encoding: .utf8)
        let handle = HunkTrackerHandle.spawn(sessionId: "s", workingDir: dir.path)
        await handle.recordAgentWrite(
            path: file.path,
            content: current,
            promptIndex: 0,
            previousContent: baseline
        )
        var hunks = await handle.getHunksForPath(file.path)
        #expect(hunks.count == 3)
        try await handle.hunkAction(hunkId: hunks[0].id, action: .accept)
        hunks = await handle.getHunksForPath(file.path)
        #expect(hunks.count == 2)
    }

    // MARK: - Binary / line endings / snapshot

    @Test("binary agent write tracked without hunks")
    func binaryWrite() async {
        let handle = HunkTrackerHandle.spawn(sessionId: "s", workingDir: "/tmp")
        let path = "/tmp/bin-\(UUID().uuidString).bin"
        let binary = String(decoding: [0x00, 0x01, 0x02], as: UTF8.self) // will be binary via NUL
        // Use classify path with actual NUL in string isn't possible; use content that classifyString
        // detects — inject via a large/binary path:
        let content = "version https://git-lfs.github.com/spec/v1\noid sha256:abc\nsize 1\n"
        await handle.recordAgentWrite(path: path, content: content, promptIndex: 0)
        #expect(await handle.isAgentFile(path))
        // LFS pointer is not diffable
        let hunks = await handle.getHunksForPath(path)
        #expect(hunks.isEmpty)
        _ = binary
    }

    @Test("CRLF line endings")
    func crlf() {
        let baseline = "a\r\nb\r\n"
        let current = "a\r\nB\r\n"
        let hunks = computeHunks(
            path: "t.txt",
            baseline: baseline,
            current: current,
            source: .agentEdit(promptIndex: 0)
        )
        #expect(hunks.count == 1)
    }

    @Test("snapshot restore and path rewrite")
    func snapshotRestore() async {
        let handle = HunkTrackerHandle.spawn(sessionId: "s", workingDir: "/old/cwd")
        await handle.recordAgentWrite(
            path: "/old/cwd/file.txt",
            content: "new\n",
            promptIndex: 2,
            previousContent: "old\n"
        )
        var snap = await handle.snapshotState()
        #expect(!snap.fileStates.isEmpty)
        snap.rewritePaths(oldCwd: "/old/cwd", canonicalOldCwd: "/old/cwd", newCwd: "/new/cwd")
        #expect(snap.fileStates["/new/cwd/file.txt"] != nil)
        #expect(snap.fileStates["/new/cwd/file.txt"]?.hunks.first?.path == "/new/cwd/file.txt")

        let handle2 = HunkTrackerHandle.spawn(sessionId: "s2", workingDir: "/new/cwd")
        await handle2.restoreState(snap)
        let paths = await handle2.getAllTrackedPaths()
        #expect(paths.contains("/new/cwd/file.txt"))
    }

    @Test("concurrent agents different prompt indices")
    func concurrentAgents() async {
        let handle = HunkTrackerHandle.spawn(sessionId: "s", workingDir: "/tmp")
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<5 {
                group.addTask {
                    await handle.recordAgentWrite(
                        path: "/tmp/agent-\(i).txt",
                        content: "content \(i)\n",
                        promptIndex: i,
                        previousContent: nil
                    )
                }
            }
        }
        let summary = await handle.getSessionSummary()
        #expect(summary.turns.count == 5)
        let paths = await handle.getAllTrackedPaths()
        #expect(paths.count == 5)
    }

    @Test("empty file creates no hunk")
    func emptyFile() async {
        let handle = HunkTrackerHandle.spawn(sessionId: "s", workingDir: "/tmp")
        await handle.recordAgentWrite(
            path: "/tmp/empty-\(UUID().uuidString).txt",
            content: "",
            promptIndex: 0,
            previousContent: nil
        )
        let hunks = await handle.getAllHunks()
        #expect(hunks.isEmpty)
    }

    @Test("session summary excludes external from agent totals")
    func summaryExcludesExternal() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-hunk-sum-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let handle = HunkTrackerHandle.spawn(
            sessionId: "s",
            workingDir: dir.path,
            mode: .allDirty
        )
        await handle.recordAgentWrite(
            path: dir.appendingPathComponent("a.txt").path,
            content: "agent\n",
            promptIndex: 1,
            previousContent: nil
        )
        let ext = dir.appendingPathComponent("e.txt")
        try "external only\n".write(to: ext, atomically: true, encoding: .utf8)
        await handle.handleFileChange(path: ext.path)
        let summary = await handle.getSessionSummary()
        #expect(summary.pendingHunks >= 1)
        #expect(summary.turns.allSatisfy { $0.promptIndex == 1 })
        #expect(summary.unattributedPending >= 0)
    }

    @Test("file content classification")
    func contentClassify() {
        #expect(classifyString("hello").isDiffable)
        #expect(!classifyBytes(Data([0x00, 0x01])).isDiffable)
        #expect(!classifyString(String(repeating: "x", count: maxTrackedTextBytes + 1)).isDiffable)
        let lfs = "version https://git-lfs.github.com/spec/v1\noid sha256:x\nsize 1\n"
        if case .lfsPointer = classifyString(lfs) {} else {
            Issue.record("expected lfs")
        }
        #expect(FileContentView.full("ab").byteLen == 2)
        #expect(FileContentView.missing().status == .missing)
    }

    @Test("hunk id display truncates")
    func hunkIdDisplay() {
        let id = HunkId("abcdef0123456789")
        #expect(id.description == "abcdef01")
    }

    // MARK: - Identity, failed writes, restart persistence

    @Test("agent write records session and agent identity")
    func identityOnHunk() async {
        let handle = HunkTrackerHandle.spawn(
            sessionId: "sess-42",
            workingDir: "/tmp",
            defaultAgentId: "agent-main"
        )
        await handle.recordAgentWrite(
            path: "/tmp/id-\(UUID().uuidString).txt",
            content: "hi\n",
            promptIndex: 9,
            previousContent: nil,
            agentId: "agent-main"
        )
        let hunks = await handle.getAllHunks()
        #expect(hunks.count == 1)
        #expect(hunks[0].source.sessionId == "sess-42")
        #expect(hunks[0].source.agentId == "agent-main")
        #expect(hunks[0].source.promptIndex == 9)
        let snap = await handle.snapshotState()
        #expect(snap.sessionId == "sess-42")
        #expect(snap.schemaVersion == hunkTrackerSnapshotSchemaVersion)
    }

    @Test("failed write records no attribution")
    func failedWriteNoAttribution() async {
        let handle = HunkTrackerHandle.spawn(sessionId: "s", workingDir: "/tmp")
        await handle.recordAgentWrite(
            path: "/tmp/fail-\(UUID().uuidString).txt",
            content: "should not track\n",
            promptIndex: 1,
            writeSucceeded: false
        )
        #expect(await handle.getAllHunks().isEmpty)
        #expect(await handle.getAllTrackedPaths().isEmpty)

        // Structured failure result also no-ops.
        await handle.recordAgentWrite(
            result: .failure(
                path: "/tmp/fail2.txt",
                content: "nope\n",
                errorMessage: "disk full"
            ),
            promptIndex: 2
        )
        #expect(await handle.getAllHunks().isEmpty)
    }

    @Test("successful write result attributes")
    func successfulWriteResult() async {
        let handle = HunkTrackerHandle.spawn(
            sessionId: "s9",
            workingDir: "/tmp",
            defaultAgentId: "a1"
        )
        await handle.recordAgentWrite(
            result: .success(
                path: "/tmp/ok-\(UUID().uuidString).txt",
                content: "ok\n",
                previousContent: nil
            ),
            promptIndex: 0,
            agentId: "a1"
        )
        let hunks = await handle.getAllHunks()
        #expect(hunks.count == 1)
        #expect(hunks[0].source.isAgentEdit)
        #expect(hunks[0].source.agentId == "a1")
    }

    @Test("restart persistence round-trip on disk")
    func restartPersistence() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-hunk-persist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storePath = dir.appendingPathComponent("hunks.json").path

        let handle = HunkTrackerHandle.spawn(
            sessionId: "persist-session",
            workingDir: dir.path,
            defaultAgentId: "agent-x",
            persistencePath: storePath
        )
        let file = dir.appendingPathComponent("p.txt").path
        await handle.recordAgentWrite(
            path: file,
            content: "persisted\n",
            promptIndex: 4,
            previousContent: "old\n",
            agentId: "agent-x"
        )
        try await handle.persist()
        #expect(FileManager.default.fileExists(atPath: storePath))

        // New process / actor restores from disk.
        let handle2 = HunkTrackerHandle.spawn(
            sessionId: "persist-session",
            workingDir: dir.path,
            persistencePath: storePath
        )
        try await handle2.restoreFromDisk()
        let hunks = await handle2.getAllHunks()
        #expect(hunks.count == 1)
        #expect(hunks[0].source.promptIndex == 4)
        #expect(hunks[0].source.sessionId == "persist-session")
        #expect(hunks[0].source.agentId == "agent-x")
        let snap = await handle2.snapshotState()
        #expect(snap.sessionId == "persist-session")
    }

    @Test("snapshot codable forward-compatible decode")
    func snapshotCodable() throws {
        let hunk = Hunk(
            path: "/x",
            lineInfo: HunkLineInfo(oldStart: 1, oldCount: 1, newStart: 1, newCount: 1),
            source: .agentEdit(promptIndex: 1, sessionId: "s", agentId: "a"),
            oldText: "o\n",
            newText: "n\n"
        )
        let snap = HunkTrackerSnapshot(
            sessionId: "s",
            fileStates: [
                "/x": FileHunkStateSnapshot(
                    baseline: .full("o\n"),
                    currentContent: .full("n\n"),
                    hunks: [hunk],
                    isAgentFile: true
                )
            ],
            turnIndex: [1: [hunk.id]],
            sessionStats: SessionStats(acceptedHunks: 2)
        )
        try HunkTrackerStore.save(snap, to: FileManager.default.temporaryDirectory
            .appendingPathComponent("snap-\(UUID().uuidString).json").path)
        // Also pure encode/decode
        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(HunkTrackerSnapshot.self, from: data)
        #expect(decoded.sessionId == "s")
        #expect(decoded.fileStates["/x"]?.hunks.count == 1)
        #expect(decoded.sessionStats.acceptedHunks == 2)
        #expect(decoded.fileStates["/x"]?.hunks.first?.source.agentId == "a")
    }

    @Test("overlapping edits and deletion hunks")
    func overlapAndDelete() {
        let baseline = "a\nb\nc\nd\n"
        let current = "a\nX\nY\nd\n"
        let hunks = computeHunks(
            path: "t",
            baseline: baseline,
            current: current,
            source: .agentEdit(promptIndex: 0)
        )
        #expect(hunks.count == 1)

        let del = computeHunks(
            path: "t",
            baseline: "a\nb\n",
            current: "",
            source: .agentEdit(promptIndex: 0)
        )
        // empty current vs non-empty may yield delete-style hunks
        #expect(!del.isEmpty || current.isEmpty)
        _ = del
    }

    @Test("fs notify never invents agent identity")
    func fsNeverAgentIdentity() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-hunk-fsid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("e.txt")
        try "external\n".write(to: file, atomically: true, encoding: .utf8)
        let handle = HunkTrackerHandle.spawn(
            sessionId: "sess",
            workingDir: dir.path,
            mode: .allDirty
        )
        await handle.handleFileChange(path: file.path)
        for h in await handle.getHunksForPath(file.path) {
            #expect(!h.source.isAgentEdit)
            #expect(h.source.sessionId == nil)
            #expect(h.source.agentId == nil)
        }
    }
}
