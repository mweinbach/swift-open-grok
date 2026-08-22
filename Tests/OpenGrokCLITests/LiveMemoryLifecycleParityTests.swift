import Foundation
import OpenGrokConfig
import OpenGrokMemory
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShellSessionSupport
import Testing
@testable import OpenGrokCLI

private struct LiveMemoryLifecycleFixture {
    let root: URL
    let workingDirectory: URL
    let openGrokHome: URL
    let environment: [String: String]

    init(memoryEnabled: Bool = true) throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        root = packageRoot
            .appendingPathComponent(".build/memory-lifecycle-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        workingDirectory = root.appendingPathComponent("workspace", isDirectory: true)
        openGrokHome = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: openGrokHome,
            withIntermediateDirectories: true
        )
        var environment = ["OPENGROK_HOME": openGrokHome.path]
        if memoryEnabled { environment["OPENGROK_MEMORY"] = "1" }
        self.environment = environment
    }

    var storage: MemoryStorage {
        MemoryStorage(cwd: workingDirectory, environment: environment)
    }

    func record(
        sessionID: String = "memory1234-session",
        items: [ConversationItem] = LiveMemoryLifecycleFixture.substantialConversation,
        provider: ModelProvider? = .xai,
        everUsedNonXAI: Bool? = false,
        parentSessionID: String? = nil,
        sessionKind: String? = nil,
        workingDirectory: URL? = nil
    ) -> LiveConversationRecord {
        let now = Date()
        return LiveConversationRecord(
            sessionID: sessionID,
            workingDirectory: (workingDirectory ?? self.workingDirectory).path,
            parentSessionID: parentSessionID,
            sessionKind: sessionKind,
            createdAt: now,
            updatedAt: now,
            items: items,
            currentProvider: provider,
            everUsedNonXAI: everUsedNonXAI
        )
    }

    func services(
        for record: LiveConversationRecord,
        owningSessionID: String? = nil,
        workingDirectory: URL? = nil
    ) async -> LiveSessionServices {
        await OpenGrokLiveApplicationLauncher.makeSessionServices(
            sessionID: owningSessionID ?? record.sessionID,
            workingDirectory: workingDirectory ?? self.workingDirectory,
            openGrokHome: openGrokHome,
            conversationRecord: record,
            environment: environment
        )
    }

    func history(
        for record: LiveConversationRecord,
        boundary: ExportBoundary? = nil
    ) -> LiveConversationHistory {
        LiveConversationHistory(
            record: record,
            store: LiveConversationStore(openGrokHome: openGrokHome),
            exportBoundary: boundary
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func populateMemory() throws -> URL {
        try storage.ensureInitialized()
        let session = try storage.writeDailyLog(
            date: "2026-08-22",
            slug: "workspace",
            sessionID: "memory1234-session",
            content: "## Session\n\nA durable memory entry.",
            append: false
        )
        guard FileManager.default.fileExists(atPath: session.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return session
    }

    static let substantialConversation: [ConversationItem] = [
        .user("Investigate phosphorescent memory lifecycle integration carefully"),
        .assistant("The assistant reply contains private assistant-only reasoning."),
        .user("Preserve provider boundaries across shutdown and session replay."),
        .toolResult(toolCallId: "call-1", content: "sensitive-terminal-command-output"),
        .user("Make the resulting session summary discoverable by memory search."),
    ]
}

private func runMemoryClear(
    fixture: LiveMemoryLifecycleFixture,
    scope: LiveMemoryClearScope,
    skipConfirmation: Bool,
    confirmation: @escaping @Sendable () -> String? = { nil }
) -> (exitCode: Int32, output: String, error: String) {
    let output = BufferedStream()
    let error = BufferedStream()
    let exitCode = LiveMemoryComposition.runClear(
        scope: scope,
        skipConfirmation: skipConfirmation,
        workingDirectory: fixture.workingDirectory,
        environment: fixture.environment,
        confirmation: confirmation,
        output: { output.write($0) },
        error: { error.write($0) }
    )
    return (exitCode, output.contents, error.contents)
}

@Suite("Live memory clear command parity")
struct LiveMemoryClearParityTests {
    @Test("an empty memory scope succeeds without requesting confirmation")
    func emptyMemoryDoesNotPrompt() throws {
        let fixture = try LiveMemoryLifecycleFixture()
        defer { fixture.cleanup() }
        let confirmationRequests = BufferedStream()

        let result = runMemoryClear(
            fixture: fixture,
            scope: .workspace,
            skipConfirmation: false,
            confirmation: {
                confirmationRequests.write("requested")
                return "yes"
            }
        )

        #expect(result.exitCode == 0)
        #expect(result.output == "Nothing to clear — no memory files found.\n")
        #expect(result.error.isEmpty)
        #expect(confirmationRequests.contents.isEmpty)
    }

    @Test("an absent confirmation response cancels without deleting memory")
    func absentConfirmationFailsClosed() throws {
        let fixture = try LiveMemoryLifecycleFixture()
        defer { fixture.cleanup() }
        let session = try fixture.populateMemory()

        let result = runMemoryClear(
            fixture: fixture,
            scope: .workspace,
            skipConfirmation: false
        )

        #expect(result.exitCode == 0)
        #expect(result.output.contains("Are you sure? [y/N] Cancelled."))
        #expect(FileManager.default.fileExists(atPath: session.path))
        #expect(FileManager.default.fileExists(atPath: fixture.storage.globalMemoryFile.path))
    }

    @Test("a negative confirmation response cancels without deleting memory")
    func rejectedConfirmationFailsClosed() throws {
        let fixture = try LiveMemoryLifecycleFixture()
        defer { fixture.cleanup() }
        let session = try fixture.populateMemory()

        let result = runMemoryClear(
            fixture: fixture,
            scope: .all,
            skipConfirmation: false,
            confirmation: { "no" }
        )

        #expect(result.exitCode == 0)
        #expect(result.output.hasSuffix("Cancelled.\n"))
        #expect(FileManager.default.fileExists(atPath: session.path))
        #expect(FileManager.default.fileExists(atPath: fixture.storage.globalMemoryFile.path))
    }

    @Test("case-insensitive explicit yes authorizes only the requested workspace")
    func affirmativeConfirmationClearsWorkspace() throws {
        let fixture = try LiveMemoryLifecycleFixture()
        defer { fixture.cleanup() }
        let session = try fixture.populateMemory()

        let result = runMemoryClear(
            fixture: fixture,
            scope: .workspace,
            skipConfirmation: false,
            confirmation: { "  YeS  " }
        )

        #expect(result.exitCode == 0)
        #expect(result.output.contains("Cleared: workspace memory"))
        #expect(result.output.hasSuffix("Memory cleared.\n"))
        #expect(!FileManager.default.fileExists(atPath: session.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.storage.workspaceDir.path))
        #expect(FileManager.default.fileExists(atPath: fixture.storage.globalMemoryFile.path))
    }

    @Test("--yes bypasses confirmation without authorizing global memory")
    func skipConfirmationClearsOnlyWorkspace() throws {
        let fixture = try LiveMemoryLifecycleFixture()
        defer { fixture.cleanup() }
        let session = try fixture.populateMemory()
        let confirmationRequests = BufferedStream()

        let result = runMemoryClear(
            fixture: fixture,
            scope: .workspace,
            skipConfirmation: true,
            confirmation: {
                confirmationRequests.write("requested")
                return nil
            }
        )

        #expect(result.exitCode == 0)
        #expect(confirmationRequests.contents.isEmpty)
        #expect(!result.output.contains("Are you sure?"))
        #expect(!FileManager.default.fileExists(atPath: session.path))
        #expect(FileManager.default.fileExists(atPath: fixture.storage.globalMemoryFile.path))
    }

    @Test("global scope removes only global MEMORY.md and preserves all workspace logs")
    func globalScopePreservesWorkspace() throws {
        let fixture = try LiveMemoryLifecycleFixture()
        defer { fixture.cleanup() }
        let session = try fixture.populateMemory()

        let result = runMemoryClear(
            fixture: fixture,
            scope: .global,
            skipConfirmation: true
        )

        #expect(result.exitCode == 0)
        #expect(result.output.contains("Cleared: global MEMORY.md"))
        #expect(!result.output.contains("Cleared: workspace memory"))
        #expect(!FileManager.default.fileExists(atPath: fixture.storage.globalMemoryFile.path))
        #expect(FileManager.default.fileExists(atPath: session.path))
        #expect(FileManager.default.fileExists(atPath: fixture.storage.workspaceMemoryFile.path))
    }

    @Test("all scope removes the selected workspace and global memory only")
    func allScopePreservesUnrelatedWorkspace() throws {
        let fixture = try LiveMemoryLifecycleFixture()
        defer { fixture.cleanup() }
        let session = try fixture.populateMemory()
        let unrelatedDirectory = fixture.root.appendingPathComponent("other-workspace")
        try FileManager.default.createDirectory(
            at: unrelatedDirectory,
            withIntermediateDirectories: true
        )
        let unrelatedStorage = MemoryStorage(
            cwd: unrelatedDirectory,
            environment: fixture.environment
        )
        try unrelatedStorage.ensureInitialized()

        let result = runMemoryClear(
            fixture: fixture,
            scope: .all,
            skipConfirmation: true
        )

        #expect(result.exitCode == 0)
        #expect(result.output.contains("Cleared: workspace memory"))
        #expect(result.output.contains("Cleared: global MEMORY.md"))
        #expect(!FileManager.default.fileExists(atPath: session.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.storage.globalMemoryFile.path))
        #expect(FileManager.default.fileExists(atPath: unrelatedStorage.workspaceMemoryFile.path))
    }

    #if !os(Windows)
    @Test("workspace symlinks are rejected without touching their external targets")
    func symlinkedWorkspaceFailsClosed() throws {
        let fixture = try LiveMemoryLifecycleFixture()
        defer { fixture.cleanup() }
        let session = try fixture.populateMemory()
        #expect(FileManager.default.fileExists(atPath: session.path))
        try FileManager.default.removeItem(at: fixture.storage.workspaceDir)

        let external = fixture.root.appendingPathComponent("external-memory")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let protectedFile = external.appendingPathComponent("protected.md")
        try "Never delete this.".write(to: protectedFile, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: fixture.storage.workspaceDir,
            withDestinationURL: external
        )

        let result = runMemoryClear(
            fixture: fixture,
            scope: .workspace,
            skipConfirmation: true
        )

        #expect(result.exitCode == 1)
        #expect(result.error.contains("Failed to clear memory:"))
        #expect(FileManager.default.fileExists(atPath: protectedFile.path))
        #expect(FileManager.default.fileExists(atPath: fixture.storage.workspaceDir.path))
        #expect(FileManager.default.fileExists(atPath: fixture.storage.globalMemoryFile.path))
    }

    @Test("a global MEMORY.md symlink is rejected without touching its target")
    func symlinkedGlobalMemoryFailsClosed() throws {
        let fixture = try LiveMemoryLifecycleFixture()
        defer { fixture.cleanup() }
        let session = try fixture.populateMemory()
        try FileManager.default.removeItem(at: fixture.storage.globalMemoryFile)
        let protectedFile = fixture.root.appendingPathComponent("protected-global.md")
        try "Never delete global target.".write(
            to: protectedFile,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.storage.globalMemoryFile,
            withDestinationURL: protectedFile
        )

        let result = runMemoryClear(
            fixture: fixture,
            scope: .all,
            skipConfirmation: true
        )

        #expect(result.exitCode == 1)
        #expect(FileManager.default.fileExists(atPath: protectedFile.path))
        #expect(FileManager.default.fileExists(atPath: session.path))
    }
    #endif
}

@Suite("Live session-end memory lifecycle parity")
struct LiveMemoryLifecycleParityTests {
    @Test("memory session configuration defaults on and honors explicit opt-out")
    func saveOnEndConfiguration() throws {
        let defaults = LiveMemoryConfiguration.resolve(
            document: try parseTOML("[memory]\nenabled = true\n"),
            environment: [:]
        )
        #expect(defaults.session.saveOnEnd)

        let disabled = LiveMemoryConfiguration.resolve(
            document: try parseTOML("""
                [memory]
                enabled = true

                [memory.session]
                save_on_end = false
                """),
            environment: [:]
        )
        #expect(disabled.enabled)
        #expect(!disabled.session.saveOnEnd)
    }

    @Test("session shutdown writes an immediately searchable owner-private summary")
    func shutdownWritesAndIndexesSummary() async throws {
        let fixture = try LiveMemoryLifecycleFixture()
        defer { fixture.cleanup() }
        let record = fixture.record()
        let services = await fixture.services(for: record)
        let outcome = await services.endSession(history: fixture.history(for: record))

        guard case .written(let path) = outcome else {
            Issue.record("expected a persisted session summary, got \(outcome)")
            return
        }
        let fileURL = URL(fileURLWithPath: path)
        #expect(fileURL.deletingLastPathComponent() == fixture.storage.sessionsDir)
        #expect(fileURL.lastPathComponent.contains("investigate-phosphorescent"))
        #expect(fileURL.lastPathComponent.hasSuffix("-memory12.md"))

        let content = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(content.contains("## Session Summary"))
        #expect(content.contains("3 user, 1 assistant, 1 tool results"))
        #expect(content.contains("## Topics Discussed"))
        #expect(content.contains("Investigate phosphorescent memory lifecycle"))
        #expect(!content.contains("private assistant-only reasoning"))
        #expect(!content.contains("sensitive-terminal-command-output"))

        let search = await services.invoke(
            name: LiveMemoryTools.searchToolName,
            arguments: .object([
                "query": .string("phosphorescent"),
                "min_score": .number(.int64(0)),
            ])
        )
        #expect(search.contains("phosphorescent"))

        #if !os(Windows)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        for directory in [
            fixture.storage.globalDir,
            fixture.storage.workspaceDir,
            fixture.storage.sessionsDir,
        ] {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        }
        #endif
    }

    @Test("repeated shutdown of one session never appends or duplicates its summary")
    func shutdownIsIdempotent() async throws {
        let fixture = try LiveMemoryLifecycleFixture()
        defer { fixture.cleanup() }
        let record = fixture.record()
        let services = await fixture.services(for: record)
        let history = fixture.history(for: record)

        let first = await services.endSession(history: history)
        let second = await services.endSession(history: history)
        guard case .written(let firstPath) = first,
              case .alreadySaved(let secondPath) = second
        else {
            Issue.record("unexpected shutdown outcomes: \(first), \(second)")
            return
        }
        #expect(firstPath == secondPath)
        let content = try String(contentsOf: URL(fileURLWithPath: firstPath), encoding: .utf8)
        #expect(content.components(separatedBy: "## Session Summary").count == 2)
        let files = try FileManager.default.contentsOfDirectory(
            at: fixture.storage.sessionsDir,
            includingPropertiesForKeys: nil
        )
        #expect(files.filter { $0.pathExtension == "md" }.count == 1)
    }

    @Test("a resumed backend replaces the same stable per-session daily log")
    func resumedSessionUsesStablePath() async throws {
        let fixture = try LiveMemoryLifecycleFixture()
        defer { fixture.cleanup() }
        let record = fixture.record()
        let firstServices = await fixture.services(for: record)
        let secondServices = await fixture.services(for: record)

        let first = await firstServices.endSession(history: fixture.history(for: record))
        let second = await secondServices.endSession(history: fixture.history(for: record))
        guard case .written(let firstPath) = first,
              case .written(let secondPath) = second
        else {
            Issue.record("unexpected resumed shutdown outcomes: \(first), \(second)")
            return
        }
        #expect(firstPath == secondPath)
        let content = try String(contentsOf: URL(fileURLWithPath: firstPath), encoding: .utf8)
        #expect(content.components(separatedBy: "## Session Summary").count == 2)
    }

    @Test("fewer than three real human prompts do not create memory files")
    func minimumPromptThreshold() async throws {
        let fixture = try LiveMemoryLifecycleFixture()
        defer { fixture.cleanup() }
        let record = fixture.record(items: [
            .user(String(repeating: "long genuine question ", count: 4)),
            .user(String(repeating: "another genuine question ", count: 4)),
            .agentMessage(String(repeating: "synthetic peer message ", count: 8)),
            .autoContinue(String(repeating: "synthetic continuation ", count: 8)),
            .user("__auto_continue__"),
        ])
        let services = await fixture.services(for: record)

        #expect(await services.endSession(history: fixture.history(for: record)) == .tooFewPrompts)
        #expect(!FileManager.default.fileExists(atPath: fixture.storage.sessionsDir.path))
    }

    @Test("three prompts totaling fewer than fifty UTF-8 bytes are skipped")
    func minimumByteThreshold() async throws {
        let fixture = try LiveMemoryLifecycleFixture()
        defer { fixture.cleanup() }
        let record = fixture.record(items: [.user("hey"), .user("ok"), .user("thanks")])
        let services = await fixture.services(for: record)

        #expect(await services.endSession(history: fixture.history(for: record)) == .tooFewQueryBytes)
        #expect(!FileManager.default.fileExists(atPath: fixture.storage.sessionsDir.path))
    }

    @Test("the fifty-byte threshold counts UTF-8 bytes instead of graphemes")
    func thresholdCountsUTF8Bytes() async throws {
        let fixture = try LiveMemoryLifecycleFixture()
        defer { fixture.cleanup() }
        let record = fixture.record(items: [
            .user(String(repeating: "🌊", count: 5)),
            .user(String(repeating: "🌊", count: 5)),
            .user(String(repeating: "🌊", count: 3)),
        ])
        let services = await fixture.services(for: record)

        let result = await services.endSession(history: fixture.history(for: record))
        guard case .written = result else {
            Issue.record("expected 52 UTF-8 bytes to pass the threshold: \(result)")
            return
        }
    }

    @Test("synthetic turns and metadata-only bootstrap text are never indexed")
    func syntheticTurnsAndMetadataAreExcluded() async throws {
        let fixture = try LiveMemoryLifecycleFixture()
        defer { fixture.cleanup() }
        let record = fixture.record(items: [
            .user("<user_info>bootstrap-secret</user_info>"),
            .user("<user_info>hidden-context</user_info><user_query>Investigate auroral persistence isolation thoroughly</user_query>"),
            .systemReminder("hidden synthetic reminder with lots of private data"),
            .agentMessage("hidden synthetic peer message with lots of private data"),
            .user("__auto_continue__"),
            .user("Verify provider security boundaries remain correctly closed."),
            .user("Confirm terminal lifecycle metadata remains fully searchable."),
        ])
        let services = await fixture.services(for: record)

        let result = await services.endSession(history: fixture.history(for: record))
        guard case .written(let path) = result else {
            Issue.record("expected a persisted genuine-user summary: \(result)")
            return
        }
        let content = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        #expect(content.contains("3 user"))
        #expect(content.contains("Investigate auroral persistence"))
        #expect(!content.contains("bootstrap-secret"))
        #expect(!content.contains("hidden-context"))
        #expect(!content.contains("synthetic reminder"))
        #expect(!content.contains("synthetic peer"))
        #expect(!content.contains("__auto_continue__"))
    }

    @Test("the metadata summary includes only the first five bounded user topics")
    func summaryBoundsTopics() {
        let long = String(repeating: "é", count: 140)
        let queries = [long, "second", "third", "fourth", "fifth", "sixth-private"]
        let items = queries.map(ConversationItem.user)
        let content = LiveMemorySessionSummary.render(
            conversation: items,
            realQueries: queries,
            date: Date(timeIntervalSince1970: 0)
        )

        #expect(content.contains("1970-01-01 00:00 UTC"))
        #expect(content.contains("1. \(String(repeating: "é", count: 100))\n"))
        #expect(!content.contains(String(repeating: "é", count: 101)))
        #expect(content.contains("5. fifth"))
        #expect(!content.contains("sixth-private"))
    }

    @Test("disabled memory leaves the user state untouched")
    func disabledMemoryDoesNotPersist() async throws {
        let fixture = try LiveMemoryLifecycleFixture(memoryEnabled: false)
        defer { fixture.cleanup() }
        let record = fixture.record()
        let services = await fixture.services(for: record)

        #expect(await services.endSession(history: fixture.history(for: record)) == .disabled)
        #expect(!FileManager.default.fileExists(atPath: fixture.storage.globalDir.path))
    }

    @Test("explicit save_on_end false blocks even substantial eligible sessions")
    func disabledSaveOnEndDoesNotPersist() async throws {
        let fixture = try LiveMemoryLifecycleFixture()
        defer { fixture.cleanup() }
        var configuration = LiveMemoryConfiguration.disabled
        configuration.enabled = true
        configuration.session.saveOnEnd = false
        let backend = try #require(LiveMemoryBackend(
            configuration: configuration,
            workingDirectory: fixture.workingDirectory,
            environment: fixture.environment
        ))
        let record = fixture.record()
        let services = LiveSessionServices(
            rewind: nil,
            memory: backend,
            goal: nil,
            goalIsActive: false,
            owningSessionID: record.sessionID
        )

        #expect(await services.endSession(history: fixture.history(for: record)) == .configuredOff)
        #expect(!FileManager.default.fileExists(atPath: fixture.storage.globalDir.path))
    }

    @Test("persisted non-xAI provider history cannot leak into xAI-injectable memory")
    func persistedClosedProviderBoundaryDoesNotPersist() async throws {
        let fixture = try LiveMemoryLifecycleFixture()
        defer { fixture.cleanup() }
        let record = fixture.record(provider: .xai, everUsedNonXAI: true)
        let services = await fixture.services(for: record)

        #expect(await services.endSession(history: fixture.history(for: record)) == .providerBoundaryClosed)
        #expect(!FileManager.default.fileExists(atPath: fixture.storage.globalDir.path))
    }

    @Test("the live monotonic boundary wins over a stale clean session record")
    func liveClosedProviderBoundaryDoesNotPersist() async throws {
        let fixture = try LiveMemoryLifecycleFixture()
        defer { fixture.cleanup() }
        let record = fixture.record(provider: .xai, everUsedNonXAI: false)
        let boundary = ExportBoundary(everUsedNonXAI: false)
        let history = fixture.history(for: record, boundary: boundary)
        #expect(boundary.observe(.codex))
        let services = await fixture.services(for: record)

        #expect(await services.endSession(history: history) == .providerBoundaryClosed)
        #expect(!FileManager.default.fileExists(atPath: fixture.storage.globalDir.path))
    }

    @Test("unknown legacy export provenance fails closed")
    func unknownProviderBoundaryDoesNotPersist() async throws {
        let fixture = try LiveMemoryLifecycleFixture()
        defer { fixture.cleanup() }
        let record = fixture.record(provider: .xai, everUsedNonXAI: nil)
        let services = await fixture.services(for: record)

        #expect(await services.endSession(history: fixture.history(for: record)) == .providerBoundaryClosed)
        #expect(!FileManager.default.fileExists(atPath: fixture.storage.globalDir.path))
    }

    @Test("Codex sessions cannot enter the shared xAI memory scope")
    func foreignProviderDoesNotPersist() async throws {
        let fixture = try LiveMemoryLifecycleFixture()
        defer { fixture.cleanup() }
        let record = fixture.record(provider: .codex, everUsedNonXAI: false)
        let services = await fixture.services(for: record)

        #expect(await services.endSession(history: fixture.history(for: record)) == .providerBoundaryClosed)
        #expect(!FileManager.default.fileExists(atPath: fixture.storage.globalDir.path))
    }

    @Test("subagent sessions never produce independent workspace memory")
    func subagentDoesNotPersist() async throws {
        let fixture = try LiveMemoryLifecycleFixture()
        defer { fixture.cleanup() }
        let record = fixture.record(parentSessionID: "parent", sessionKind: "subagent")
        let services = await fixture.services(for: record)

        #expect(await services.endSession(history: fixture.history(for: record)) == .subagent)
        #expect(!FileManager.default.fileExists(atPath: fixture.storage.globalDir.path))
    }

    @Test("a root fork remains eligible even though it has a parent session")
    func rootForkCanPersist() async throws {
        let fixture = try LiveMemoryLifecycleFixture()
        defer { fixture.cleanup() }
        let record = fixture.record(parentSessionID: "parent", sessionKind: "fork")
        let services = await fixture.services(for: record)

        let result = await services.endSession(history: fixture.history(for: record))
        guard case .written = result else {
            Issue.record("expected an independent root fork to save: \(result)")
            return
        }
    }

    @Test("one session's services cannot save a different session's conversation")
    func sessionMismatchDoesNotPersist() async throws {
        let fixture = try LiveMemoryLifecycleFixture()
        defer { fixture.cleanup() }
        let first = fixture.record(sessionID: "owner-session")
        let second = fixture.record(sessionID: "foreign-session")
        let services = await fixture.services(for: first)

        #expect(await services.endSession(history: fixture.history(for: second)) == .sessionMismatch)
        #expect(!FileManager.default.fileExists(atPath: fixture.storage.globalDir.path))
    }

    @Test("a moved session cannot write into another workspace's memory scope")
    func workspaceMismatchDoesNotPersist() async throws {
        let fixture = try LiveMemoryLifecycleFixture()
        defer { fixture.cleanup() }
        let foreignWorkspace = fixture.root.appendingPathComponent("foreign", isDirectory: true)
        let record = fixture.record(workingDirectory: foreignWorkspace)
        let services = await fixture.services(for: record)

        #expect(await services.endSession(history: fixture.history(for: record)) == .workspaceMismatch)
        #expect(!FileManager.default.fileExists(atPath: fixture.storage.globalDir.path))
    }

    @Test("ephemeral workspaces do not write session summaries")
    func ephemeralWorkspaceDoesNotPersist() async throws {
        let fixture = try LiveMemoryLifecycleFixture()
        defer { fixture.cleanup() }
        let ephemeral = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-memory-ephemeral-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ephemeral, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: ephemeral) }
        let record = fixture.record(workingDirectory: ephemeral)
        let services = await fixture.services(for: record, workingDirectory: ephemeral)

        #expect(await services.endSession(history: fixture.history(for: record)) == .ephemeralWorkspace)
        #expect(!FileManager.default.fileExists(atPath: fixture.storage.globalDir.path))
    }
}
