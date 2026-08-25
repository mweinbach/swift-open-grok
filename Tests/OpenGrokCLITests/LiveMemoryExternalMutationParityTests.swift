import Foundation
import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokFileUtils
import OpenGrokMemory
import OpenGrokShared
import Testing
@testable import OpenGrokCLI

private struct LiveMemoryExternalMutationFixture {
    let root: URL
    let workspace: URL
    let environment: [String: String]
    let storage: MemoryStorage
    let backend: LiveMemoryBackend

    init(workspaceName: String = "project") throws {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        root = package.appendingPathComponent(
            ".build/memory-external-mutation-parity/\(UUID().uuidString)",
            isDirectory: true
        )
        workspace = root.appendingPathComponent(workspaceName, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        environment = [
            "OPENGROK_HOME": root.appendingPathComponent("state", isDirectory: true).path,
            "OPENGROK_MEMORY": "1",
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        ]
        var configuration = LiveMemoryConfiguration.disabled
        configuration.enabled = true
        configuration.search.minScore = 0
        configuration.search.temporalDecay.enabled = false
        configuration.dream.enabled = true
        guard let backend = LiveMemoryBackend(
            configuration: configuration,
            workingDirectory: workspace,
            environment: environment
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        self.backend = backend
        storage = MemoryStorage(cwd: workspace, environment: environment)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func makeSessionsDirectory() throws {
        try FileManager.default.createDirectory(
            at: storage.sessionsDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}

@Suite("Live memory immediately observes external mutations")
struct LiveMemoryExternalMutationParityTests {
    @Test("created, replaced, and deleted session files affect the very next search")
    func externalCreateModifyDelete() async throws {
        let fixture = try LiveMemoryExternalMutationFixture()
        defer { fixture.remove() }
        try fixture.storage.ensureInitialized()
        try fixture.makeSessionsDirectory()

        let initial = await fixture.backend.search(query: "dragonfruit")
        #expect(initial.isEmpty)

        let external = fixture.storage.sessionsDir.appendingPathComponent("external-session.md")
        try "# Session\n\nThe dragonfruit secret is fresh."
            .write(to: external, atomically: true, encoding: .utf8)
        let created = await fixture.backend.search(query: "dragonfruit")
        #expect(created.count == 1)

        try "# Session\n\nThe elderberry secret replaced it."
            .write(to: external, atomically: true, encoding: .utf8)
        let removedText = await fixture.backend.search(query: "dragonfruit")
        let replacement = await fixture.backend.search(query: "elderberry")
        #expect(removedText.isEmpty)
        #expect(replacement.count == 1)

        try FileManager.default.removeItem(at: external)
        let deleted = await fixture.backend.search(query: "elderberry")
        #expect(deleted.isEmpty)
        #expect(
            FileManager.default.fileExists(
                atPath: fixture.storage.workspaceDir.appendingPathComponent("index.sqlite").path
            )
        )
    }

    @Test("dream immediately reindexes rewritten memory and purges only deleted sessions")
    func dreamDoesNotRetainDeletedSecrets() async throws {
        let fixture = try LiveMemoryExternalMutationFixture()
        defer { fixture.remove() }
        try fixture.storage.ensureInitialized()
        try fixture.makeSessionsDirectory()

        let old = fixture.storage.sessionsDir.appendingPathComponent("old-session-abcd1234.md")
        let recent = fixture.storage.sessionsDir.appendingPathComponent("recent-session-efgh5678.md")
        try "# Old\n\nObsolete ceruleansecret must disappear."
            .write(to: old, atomically: true, encoding: .utf8)
        try "# Recent\n\nRetained vermilionsecret remains on disk."
            .write(to: recent, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -600)],
            ofItemAtPath: old.path
        )
        #expect(await fixture.backend.search(query: "ceruleansecret").count == 1)
        #expect(await fixture.backend.search(query: "vermilionsecret").count == 1)

        let result = await fixture.backend.runDream(
            sessionID: "current-9999",
            dreamConfig: MemoryDreamConfig(enabled: true),
            sample: { _, _ in "## Consolidated\n\nPersisted chartreuseknowledge." }
        )
        guard case .completed = result.status else {
            Issue.record("dream failed: \(result.status)")
            return
        }
        #expect(result.cleanedStems.contains("old-session-abcd1234"))
        #expect(!result.cleanedStems.contains("recent-session-efgh5678"))
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: recent.path))
        #expect(await fixture.backend.search(query: "ceruleansecret").isEmpty)
        #expect(await fixture.backend.search(query: "vermilionsecret").count == 1)
        #expect(await fixture.backend.search(query: "chartreuseknowledge").count == 1)
    }

    @Test("the previous SHA-256 workspace directory migrates without removing original notes")
    func legacyWorkspaceMigrationPreservesOriginal() async throws {
        let fixture = try LiveMemoryExternalMutationFixture()
        defer { fixture.remove() }
        let normalized = fixture.workspace.standardizedFileURL
        let slug = slugify(normalized.lastPathComponent, maxLength: 40)
        let hash = String(FileChecksum.sha256Hex(normalized.path).prefix(8))
        let oldWorkspace = fixture.storage.globalDir.appendingPathComponent("\(slug)-\(hash)")
        try FileManager.default.createDirectory(
            at: oldWorkspace,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let original = oldWorkspace.appendingPathComponent("MEMORY.md")
        try "# Existing project\n\nAn irreplaceable mangosteen decision."
            .write(to: original, atomically: true, encoding: .utf8)

        let results = await fixture.backend.search(query: "mangosteen")
        #expect(results.count == 1)
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(FileManager.default.fileExists(atPath: fixture.storage.workspaceMemoryFile.path))
        #expect(try String(contentsOf: original, encoding: .utf8).contains("mangosteen"))
    }

    @Test("memory_get preserves Rust's header, 1-based numbering, and blank lines")
    func memoryGetFormatsNumberedFileWindows() async throws {
        let fixture = try LiveMemoryExternalMutationFixture()
        defer { fixture.remove() }
        try fixture.storage.ensureInitialized()
        try fixture.storage.writeLongTerm(scope: .workspace, content: "alpha\n\nbeta\ngamma\n")

        let output = await LiveMemoryTools.invoke(
            name: LiveMemoryTools.getToolName,
            arguments: .object([
                "path": .string(fixture.storage.workspaceMemoryFile.path),
                "from": .number(.int64(2)),
                "lines": .number(.int64(2)),
            ]),
            backend: fixture.backend
        )
        #expect(output.contains("**File:** \(fixture.storage.workspaceMemoryFile.path)"))
        #expect(output.contains("**Lines:** 2 (from: 2, limit: 2)"))
        #expect(output.contains("2→\n3→beta"))

        let fromZero = await LiveMemoryTools.invoke(
            name: LiveMemoryTools.getToolName,
            arguments: .object([
                "path": .string(fixture.storage.workspaceMemoryFile.path),
                "from": .number(.int64(0)),
                "lines": .number(.int64(1)),
            ]),
            backend: fixture.backend
        )
        #expect(fromZero.contains("1→alpha"))
    }

    @Test("oversized and negative memory_get line arguments fail without numeric traps")
    func memoryGetRejectsHostileNumericValues() async throws {
        let fixture = try LiveMemoryExternalMutationFixture()
        defer { fixture.remove() }
        try fixture.storage.ensureInitialized()

        let oversized = await LiveMemoryTools.invoke(
            name: LiveMemoryTools.getToolName,
            arguments: .object([
                "path": .string(fixture.storage.workspaceMemoryFile.path),
                "from": .number(.uint64(UInt64.max)),
            ]),
            backend: fixture.backend
        )
        #expect(oversized.contains("non-negative 'from'"))

        let negative = await LiveMemoryTools.invoke(
            name: LiveMemoryTools.getToolName,
            arguments: .object([
                "path": .string(fixture.storage.workspaceMemoryFile.path),
                "from": .number(.int64(Int64.min)),
            ]),
            backend: fixture.backend
        )
        #expect(negative.contains("non-negative 'from'"))

        let negativeLimit = await LiveMemoryTools.invoke(
            name: LiveMemoryTools.getToolName,
            arguments: .object([
                "path": .string(fixture.storage.workspaceMemoryFile.path),
                "lines": .number(.int64(-1)),
            ]),
            backend: fixture.backend
        )
        #expect(negativeLimit.contains("non-negative 'lines'"))
    }

    @Test("negative dream intervals disable malformed dream configuration without trapping")
    func malformedDreamIntervalsFailClosed() throws {
        for key in ["min_hours", "min_sessions", "stale_lock_secs", "check_interval_secs"] {
            let document = try parseTOML(
                """
                [memory]
                enabled = true

                [memory.dream]
                enabled = true
                \(key) = -1
                """
            )
            let configuration = LiveMemoryConfiguration.resolve(document: document, environment: [:])
            #expect(configuration.enabled)
            #expect(!configuration.dream.enabled)
        }
    }

    @Test("hostile working-directory metacharacters never become a shell command")
    func gitOriginDiscoveryDoesNotEvaluateShellSyntax() throws {
        let fixture = try LiveMemoryExternalMutationFixture(
            workspaceName: "project-$(touch memory-injection-marker)"
        )
        defer { fixture.remove() }
        let marker = fixture.root.appendingPathComponent("memory-injection-marker")
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(fixture.storage.workspaceDir.lastPathComponent.contains("-"))
    }
}
