import Foundation
import OpenGrokChatState
import OpenGrokCompaction
import OpenGrokConfig
import OpenGrokSamplingTypes
import OpenGrokSessionPersistence
import OpenGrokShared
import Testing
@testable import OpenGrokCLI

private struct CompactionLaunchCodexTransport: CodexCompactionTransport {
    func send(
        _ request: CodexCompactionRequest,
        onEvent: @Sendable (CodexCompactionStreamEvent) async throws -> Void
    ) async throws {
        let raw: JSONValue = .object([
            "type": .string("compaction"),
            "encrypted_content": .string("opaque-provider-summary"),
        ])
        try await onEvent(.outputItemDone(CodexCompactionOutputItem(
            id: "",
            raw: raw,
            encryptedContent: "opaque-provider-summary"
        )))
        try await onEvent(.responseCompleted)
    }
}

private struct CompactionLaunchFixture {
    let root: URL
    let home: URL
    let workspace: URL
    let environment: [String: String]
    let sessionID: String
    let history: LiveConversationHistory
    let modelSwitch: LiveModelSwitchCoordinator
    let sampler: OpenGrokLiveSampler
    let items: [ConversationItem]

    init(provider: ModelProvider = .xai) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-compaction-launch-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let workspace = root.appendingPathComponent("workspace with spaces", isDirectory: true)
        let home = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let environment = [
            "HOME": root.path,
            "OPENGROK_HOME": home.path,
            "GROK_SANDBOX": "off",
            "GROK_AUTO_COMPACT_THRESHOLD_PERCENT": "1",
            "XAI_API_KEY": "compaction-launch-fixture-only-key",
        ]
        let sessionID = "compaction-launch-\(UUID().uuidString.lowercased())"
        let model = provider == .codex ? "gpt-5.6-sol" : "grok-4.5"
        let retainedProjectDetails = String(repeating:
            "Preserve the verified implementation, exact tool output, active migration, "
                + "workspace boundaries, security decisions, and remaining user requirements. ",
            count: 8
        )
        let summary = """
        <summary>
        ## 8. Current Work
        Continue WidgetMigration with FeatureToggle and preserve ToolOutput exactly.
        \(retainedProjectDetails)
        ## 9. Optional Next Step
        HiddenSectionLeak
        </summary>
        """
        let sampler = OpenGrokLiveSampler { _, emit in
            await emit(.output(summary))
            return OpenGrokLiveSamplingResponse(output: summary)
        }
        let items: [ConversationItem] = [
            .system("You are an isolated test agent."),
            .user(UserItem(content: [
                .text(text: "Original project task"),
                .image(url: "data:image/png;base64,PRIVATE_USER_IMAGE_BYTES"),
            ])),
            .assistant(AssistantItem(
                content: String(repeating: "earlier WidgetMigration investigation ", count: 1_500),
                toolCalls: [ToolCall(
                    id: "call-1",
                    name: "read_file",
                    arguments: #"{"target_file":"Sources/Widget.swift"}"#
                )]
            )),
            .toolResult(ToolResultItem(
                toolCallId: "call-1",
                content: "EXACT_TOOL_OUTPUT = 42",
                images: [.image(url: "data:image/png;base64,PRIVATE_TOOL_IMAGE_BYTES")]
            )),
            .user("Continue the implementation"),
            .assistant(AssistantItem(
                content: String(repeating: "completed FeatureToggle research ", count: 1_200)
            )),
            .user("Preserve every active task"),
        ]
        let record = LiveConversationRecord(
            sessionID: sessionID,
            workingDirectory: workspace.path,
            parentSessionID: nil,
            createdAt: Date(),
            updatedAt: Date(),
            items: items,
            currentModelID: model,
            currentProvider: provider,
            everUsedNonXAI: provider == .codex
        )
        let store = LiveConversationStore(openGrokHome: home)
        try await store.save(record)
        let history = LiveConversationHistory(record: record, store: store)
        let configuration = OpenGrokLiveSamplingConfiguration(
            model: model,
            baseURL: "https://compaction.example.test",
            apiKey: "fixture-only-key",
            provider: provider,
            apiBackend: provider == .codex ? .responses : .chatCompletions,
            environment: environment,
            tuning: OpenGrokLiveSamplingTuning(contextWindow: 12_000)
        )
        let modelSwitch = LiveModelSwitchCoordinator(
            sampling: configuration,
            sampler: sampler,
            resolver: LiveModelCatalogResolver(
                environment: environment,
                openGrokHome: home,
                sessionID: sessionID,
                workingDirectory: workspace
            ),
            makeSampler: { _ in sampler },
            history: history
        )

        self.root = root
        self.home = home
        self.workspace = workspace
        self.environment = environment
        self.sessionID = sessionID
        self.history = history
        self.modelSwitch = modelSwitch
        self.sampler = sampler
        self.items = items
    }

    func coordinator(mode: CompactionMode) -> LiveCompactionCoordinator {
        LiveCompactionCoordinator(
            history: history,
            modelSwitch: modelSwitch,
            sessionID: sessionID,
            openGrokHome: home,
            launchPolicy: LiveCompactionLaunchPolicy(mode: mode),
            makeCodexTransport: { _, _, _, _ in CompactionLaunchCodexTransport() }
        )
    }

    func sessionDirectory() throws -> URL {
        try SessionDocumentStore(grokHome: home).sessionDirectory(
            sessionID: sessionID,
            cwd: workspace.path
        )
    }

    func cleanup() {
        LiveManagedPolicyLifecycle.stop(environment: environment)
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("Live compaction launch mode and artifact parity")
struct LiveCompactionLaunchParityTests {
    private func options(_ arguments: [String]) throws -> CLIExecutionOptions {
        let command = try CLICommandParser.parseOrThrow(["headless", "--prompt", "compact"] + arguments)
        guard case .launch(let options) = command else {
            throw CLIApplicationError.failed("compaction fixture did not produce launch options")
        }
        return options
    }

    @Test("CLI, environment, trusted config, and allowlisted remote resolve independently")
    func resolvesModeAndDetailUsingUpstreamPrecedence() throws {
        var remote = AllowlistedRemoteSettings()
        remote.compactionMode = "segments"
        remote.compactionDetail = "none"
        let trusted = try parseTOML("""
        [features]
        compaction_mode = "transcript"
        compaction_detail = "balanced"
        """)

        let explicit = LiveCompactionLaunchPolicy.resolve(
            options: try options(["--compaction-mode", "segments", "--compaction-detail", "minimal"]),
            environment: ["GROK_COMPACTION_MODE": "summary", "GROK_COMPACTION_DETAIL": "verbose"],
            trustedConfiguration: trusted,
            remoteSettings: remote
        )
        #expect(explicit.mode == .segments(.minimal))

        let fallback = LiveCompactionLaunchPolicy.resolve(
            options: try options(["--compaction-mode", "unknown", "--compaction-detail", "unknown"]),
            environment: ["GROK_COMPACTION_MODE": "unknown", "GROK_COMPACTION_DETAIL": "unknown"],
            trustedConfiguration: try parseTOML("[features]\ncompaction_detail = \"balanced\"\n"),
            remoteSettings: remote
        )
        #expect(fallback.mode == .segments(.balanced))
        #expect(LiveCompactionLaunchPolicy.resolve(
            options: try options([]),
            environment: [:],
            trustedConfiguration: .table(TOMLTable())
        ).mode == .summary)
    }

    @Test("transcript mode adds the canonical actual updates path to durable model history")
    func transcriptHintPointsToCanonicalSessionTranscript() async throws {
        let fixture = try await CompactionLaunchFixture()
        defer { fixture.cleanup() }
        let result = await fixture.coordinator(mode: .transcript).compactNow()
        guard case .compacted(let items, let report) = result else {
            Issue.record("transcript compaction failed: \(result)")
            return
        }

        let session = try fixture.sessionDirectory()
        #expect(report.kind == .local)
        #expect(items.contains { $0.textContent().contains(session.appendingPathComponent("updates.jsonl").path) })
        #expect(await fixture.history.items == items)
        #expect(!FileManager.default.fileExists(atPath: session.appendingPathComponent("compaction").path))
    }

    @Test("segments persist canonical files, scoped keywords, scrubbed images, and the real summary hint")
    func segmentsPersistCanonicalSecureArtifacts() async throws {
        let fixture = try await CompactionLaunchFixture()
        defer { fixture.cleanup() }
        let result = await fixture.coordinator(mode: .segments(.verbose)).compactNow()
        guard case .compacted(let items, let report) = result else {
            Issue.record("segment compaction failed: \(result)")
            return
        }

        let directory = try fixture.sessionDirectory().appendingPathComponent("compaction", isDirectory: true)
        let segmentURL = directory.appendingPathComponent("segment_000.md")
        let segment = try String(contentsOf: segmentURL, encoding: .utf8)
        let index = try String(contentsOf: directory.appendingPathComponent("INDEX.md"), encoding: .utf8)
        #expect(report.kind == .local)
        #expect(segment.contains("detail=verbose"))
        #expect(segment.contains("EXACT_TOOL_OUTPUT = 42"))
        #expect(segment.contains("Sources/Widget.swift"))
        #expect(segment.contains("[image]"))
        #expect(!segment.contains("PRIVATE_USER_IMAGE_BYTES"))
        #expect(!segment.contains("PRIVATE_TOOL_IMAGE_BYTES"))
        #expect(index.contains("| 000 | segment_000.md |"))
        #expect(index.contains("\"WidgetMigration\""))
        #expect(index.contains("\"FeatureToggle\""))
        #expect(!index.contains("HiddenSectionLeak"))
        #expect(items.contains { item in
            item.textContent().contains(directory.path + "/segment_*.md")
                && item.textContent().contains(directory.path + "/INDEX.md")
        })
        #expect(await fixture.history.items == items)

        #if !os(Windows)
        let permissions = try #require(FileManager.default.attributesOfItem(
            atPath: segmentURL.path
        )[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o077 == 0)
        #endif
    }

    @Test("disk numbering survives resumed coordinators without duplicating the index header")
    func resumedCoordinatorContinuesSegmentNumbering() async throws {
        let fixture = try await CompactionLaunchFixture()
        defer { fixture.cleanup() }
        let first = await fixture.coordinator(mode: .segments(.minimal)).compactNow()
        guard case .compacted = first else {
            Issue.record("first compaction failed: \(first)")
            return
        }
        try await fixture.history.commit(sessionID: fixture.sessionID, items: fixture.items)
        let second = await fixture.coordinator(mode: .segments(.minimal)).compactNow()
        guard case .compacted = second else {
            Issue.record("resumed compaction failed: \(second)")
            return
        }

        let directory = try fixture.sessionDirectory().appendingPathComponent("compaction", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("segment_000.md").path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("segment_001.md").path))
        let index = try String(contentsOf: directory.appendingPathComponent("INDEX.md"), encoding: .utf8)
        #expect(index.components(separatedBy: "# Compaction Segment Index").count == 2)
        #expect(index.contains("| 001 | segment_001.md |"))
    }

    @Test("Codex segment persistence cannot inject local hints into opaque provider-owned history")
    func codexCompactionKeepsOpaqueHistoryUntouched() async throws {
        let fixture = try await CompactionLaunchFixture(provider: .codex)
        defer { fixture.cleanup() }
        let result = await fixture.coordinator(mode: .segments(.balanced)).compactNow()
        guard case .compacted(let items, let report) = result else {
            Issue.record("Codex compaction failed: \(result)")
            return
        }

        let directory = try fixture.sessionDirectory().appendingPathComponent("compaction", isDirectory: true)
        let segment = try String(contentsOf: directory.appendingPathComponent("segment_000.md"), encoding: .utf8)
        #expect(report.kind == .codexRemoteV2)
        #expect(segment.contains("[OpenAI server-side compacted context]"))
        #expect(!items.contains { $0.textContent().contains(directory.path) })
    }

    @Test("a symlinked segment directory fails closed without writing outside the session")
    func symlinkedArtifactDirectoryCannotEscapeSession() async throws {
        #if !os(Windows)
        let fixture = try await CompactionLaunchFixture()
        defer { fixture.cleanup() }
        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = try fixture.sessionDirectory().appendingPathComponent("compaction", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let result = await fixture.coordinator(mode: .segments(.minimal)).compactNow()
        guard case .unableToCompact = result else {
            Issue.record("symlinked compaction unexpectedly succeeded: \(result)")
            return
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        #endif
    }

    @Test("the production launch stack threads parsed mode and detail into real durable compaction")
    func actualLaunchStackHonorsCompactionFlags() async throws {
        let fixture = try await CompactionLaunchFixture()
        defer { fixture.cleanup() }
        let launch = try options([
            "--cwd", fixture.workspace.path,
            "--resume", fixture.sessionID,
            "--model", "grok-4.5",
            "--compaction-mode", "segments",
            "--compaction-detail", "minimal",
        ])
        let sampler = fixture.sampler
        let dependencies = OpenGrokLiveCompositionDependencies(makeSampler: { _ in sampler })
        let context = CLIApplicationContext(
            environment: fixture.environment,
            streams: CLIStreams(out: { _ in }, err: { _ in }),
            control: .never
        )
        let foundation = try await OpenGrokLiveApplicationLauncher.makeSessionFoundation(
            options: launch,
            context: context,
            dependencies: dependencies
        )
        let stack = await OpenGrokLiveApplicationLauncher.makeAgentStack(
            foundation: foundation,
            context: context,
            dependencies: dependencies
        )
        let result = await stack.compaction.compactNow()
        stack.sessionBusObserver?.cancel()
        await foundation.toolExecutor.shutdown()
        guard case .compacted = result else {
            Issue.record("production launch compaction failed: \(result)")
            return
        }

        let segment = try String(
            contentsOf: fixture.sessionDirectory()
                .appendingPathComponent("compaction/segment_000.md"),
            encoding: .utf8
        )
        #expect(segment.contains("detail=minimal"))
        #expect(segment.contains("## Turn signatures"))
    }
}
