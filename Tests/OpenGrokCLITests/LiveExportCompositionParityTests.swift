import Foundation
import OpenGrokSamplingTypes
import OpenGrokSessionPersistence
import OpenGrokShared
import OpenGrokShellSessionSupport
import OpenGrokWebMediaTools
import Testing

@testable import OpenGrokCLI

private typealias JSONValue = OpenGrokShared.JSONValue

private actor ExportClipboardCapture {
    private var copied: [String] = []

    func append(_ text: String) {
        copied.append(text)
    }

    func snapshot() -> [String] {
        copied
    }
}

private struct LiveExportFixture {
    let root: URL
    let state: URL
    let userHome: URL
    let workspace: URL

    var environment: [String: String] {
        ["OPENGROK_HOME": state.path, "HOME": userHome.path]
    }

    static func make() throws -> Self {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(
            "opengrok-live-export-\(UUID().uuidString)",
            isDirectory: true
        )
        try manager.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let state = root.appendingPathComponent("state", isDirectory: true)
        let userHome = root.appendingPathComponent("user", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        for directory in [state, userHome, workspace] {
            try manager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        return Self(root: root, state: state, userHome: userHome, workspace: workspace)
    }

    func seed(
        _ id: String,
        items: [ConversationItem] = [],
        hiddenTransportIDs: [String]? = nil
    ) async throws {
        var record = LiveConversationRecord.new(sessionID: id, workingDirectory: workspace)
        record.items = items
        record.codeModeTransportCallIDs = hiddenTransportIDs
        try await LiveConversationStore(openGrokHome: state).save(record)
    }

    func append(
        to id: String,
        method: String = "session/update",
        tag: String,
        text: String? = nil,
        promptIndex: UInt64? = nil,
        rewindTo: UInt64? = nil,
        hostTurn: Bool = false,
        owner: String? = nil,
        title: String? = nil,
        input: [String: JSONValue]? = nil,
        toolCallID: String? = nil,
        hiddenTransport: Bool = false
    ) throws {
        var update: [String: JSONValue] = ["sessionUpdate": .string(tag)]
        if let text {
            update["content"] = .object(["type": .string("text"), "text": .string(text)])
        }
        var updateMetadata: [String: JSONValue] = [:]
        if let promptIndex { updateMetadata["promptIndex"] = .number(.uint64(promptIndex)) }
        if hostTurn { updateMetadata["hostTurn"] = .bool(true) }
        if !updateMetadata.isEmpty { update["_meta"] = .object(updateMetadata) }
        if let rewindTo { update["target_prompt_index"] = .number(.uint64(rewindTo)) }
        if let title { update["title"] = .string(title) }
        if let input { update["rawInput"] = .object(input) }
        if let toolCallID { update["toolCallId"] = .string(toolCallID) }
        var params: [String: JSONValue] = [
            "sessionId": .string(owner ?? id),
            "update": .object(update),
        ]
        if hiddenTransport {
            params["_meta"] = .object(["open-grok/codeModeTransport": .bool(true)])
        }
        try SessionDocumentStore(grokHome: state).appendUpdate(
            SessionUpdateEnvelope(timestamp: 123, method: method, params: .object(params)),
            sessionID: id,
            cwd: workspace.path
        )
    }

    func journal(_ id: String) throws -> URL {
        try SessionDocumentStore(grokHome: state)
            .sessionDirectory(sessionID: id, cwd: workspace.path)
            .appendingPathComponent(SessionDocumentStore.updatesFileName)
    }

    func launch(
        _ arguments: [String],
        streams: CLIStreams
    ) async throws {
        let command = try CLICommandParser.parseOrThrow(arguments)
        let session = try await OpenGrokLiveApplicationLauncher().launcher.start(
            command,
            CLIApplicationContext(environment: environment, streams: streams, control: .never)
        )
        try await session.waitForExit()
        await session.shutdown()
    }

    func runInjected(
        _ arguments: [String],
        streams: CLIStreams,
        services: LiveExportServices
    ) async throws {
        let command = try CLICommandParser.parseOrThrow(arguments)
        let session = try await LiveExportComposition.session(
            for: command,
            context: CLIApplicationContext(
                environment: environment,
                streams: streams,
                control: .never
            ),
            services: services
        )
        try await session.waitForExit()
        await session.shutdown()
    }

    func clean() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("live Rust-compatible session Markdown export", .serialized)
struct LiveExportCompositionParityTests {
    @Test("the executable's CLIRunner entry point returns success after exporting a live session")
    func exportTraversesRealExecutableDispatch() async throws {
        let fixture = try LiveExportFixture.make()
        defer { fixture.clean() }
        try await fixture.seed("executable", items: [.user("Executable route")])
        let (streams, output, errors) = CLIStreams.buffered()

        let status = await CLIRunner.run(
            ["export", "executable"],
            environment: fixture.environment,
            streams: streams,
            application: .live(control: .never)
        )

        #expect(status == CLIRunner.ExitCode.success.rawValue)
        #expect(output.contents == "## User\n\nExecutable route\n")
        #expect(errors.contents.isEmpty)
    }

    @Test("the parsed production export command renders real canonical journal updates to stdout")
    func exportIsReachableFromProductionLauncher() async throws {
        let fixture = try LiveExportFixture.make()
        defer { fixture.clean() }
        try await fixture.seed("live-export", items: [
            .user("Explain **Swift** concurrency"),
            .assistant(AssistantItem(
                content: "Use `Sendable` values.",
                toolCalls: [ToolCall(
                    id: "read-1",
                    name: "read_file",
                    arguments: "{\"path\":\"/workspace/main.swift\"}"
                )]
            )),
        ])
        let (streams, output, errors) = CLIStreams.buffered()

        try await fixture.launch(["export", "live-export"], streams: streams)

        #expect(output.contents == """
        ## User

        Explain **Swift** concurrency

        ## Assistant

        Use `Sendable` values.

        ## Tools

        - Read: /workspace/main.swift

        """)
        #expect(errors.contents.isEmpty)
    }

    @Test("the production launcher creates nested output parents and writes Markdown without a trailing newline")
    func exportCreatesOutputFile() async throws {
        let fixture = try LiveExportFixture.make()
        defer { fixture.clean() }
        try await fixture.seed("file-export", items: [.user("Archive me")])
        let destination = fixture.root.appendingPathComponent("archives/nested/conversation.md")
        let (streams, output, errors) = CLIStreams.buffered()

        try await fixture.launch(["export", "file-export", destination.path], streams: streams)

        let exported = try String(contentsOf: destination, encoding: .utf8)
        #expect(exported == "## User\n\nArchive me")
        #expect(output.contents.isEmpty)
        #expect(errors.contents == "Conversation exported to \(destination.path)\n")
    }

    @Test("tilde output paths expand using the launch environment's isolated user home")
    func exportExpandsHomeRelativeOutput() async throws {
        let fixture = try LiveExportFixture.make()
        defer { fixture.clean() }
        try await fixture.seed("tilde", items: [.user("At home")])
        let destination = fixture.userHome.appendingPathComponent("exports/session.md")
        let (streams, output, errors) = CLIStreams.buffered()

        try await fixture.launch(["export", "tilde", "~/exports/session.md"], streams: streams)

        let exported = try String(contentsOf: destination, encoding: .utf8)
        #expect(exported == "## User\n\nAt home")
        #expect(output.contents.isEmpty)
        #expect(errors.contents == "Conversation exported to \(destination.path)\n")
    }

    @Test("a supplied output path takes precedence over clipboard mode exactly like Rust")
    func explicitFileWinsOverClipboard() async throws {
        let fixture = try LiveExportFixture.make()
        defer { fixture.clean() }
        try await fixture.seed("precedence", items: [.user("Keep the file")])
        let destination = fixture.root.appendingPathComponent("wins.md")
        let clipboard = ExportClipboardCapture()
        let services = LiveExportServices { text, _ in await clipboard.append(text) }
        let (streams, output, errors) = CLIStreams.buffered()

        try await fixture.runInjected(
            ["export", "precedence", destination.path, "-c"],
            streams: streams,
            services: services
        )

        #expect(await clipboard.snapshot().isEmpty)
        let exported = try String(contentsOf: destination, encoding: .utf8)
        #expect(exported == "## User\n\nKeep the file")
        #expect(output.contents.isEmpty)
        #expect(errors.contents == "Conversation exported to \(destination.path)\n")
    }

    @Test("clipboard exports perform the actual injected write before reporting Rust's byte and line counts")
    func clipboardExportWritesBeforeReportingSuccess() async throws {
        let fixture = try LiveExportFixture.make()
        defer { fixture.clean() }
        try await fixture.seed("clipboard", items: [.user("Café")])
        let clipboard = ExportClipboardCapture()
        let services = LiveExportServices { text, _ in await clipboard.append(text) }
        let (streams, output, errors) = CLIStreams.buffered()

        try await fixture.runInjected(
            ["export", "clipboard", "--clipboard"],
            streams: streams,
            services: services
        )

        let expected = "## User\n\nCafé"
        #expect(await clipboard.snapshot() == [expected])
        #expect(output.contents.isEmpty)
        #expect(errors.contents
            == "Conversation copied to clipboard (\(expected.utf8.count) chars, 3 lines)\n")
    }

    @Test("unsupported clipboard capabilities fail loudly and never claim a successful copy")
    func unsupportedClipboardNeverSucceedsSilently() async throws {
        let fixture = try LiveExportFixture.make()
        defer { fixture.clean() }
        try await fixture.seed("unavailable", items: [.user("Secret")])
        let services = LiveExportServices { _, _ in
            throw OpenGrokWebMediaTools.ClipboardError.unsupported("no clipboard service")
        }
        let (streams, output, errors) = CLIStreams.buffered()

        await #expect(throws: CLIApplicationError.self) {
            try await fixture.runInjected(
                ["export", "unavailable", "-c"],
                streams: streams,
                services: services
            )
        }
        #expect(output.contents.isEmpty)
        #expect(errors.contents.isEmpty)
    }

    @Test("rewound prompt branches, thinking chrome, host turns, and hidden transport calls never leak")
    func replayFiltersDeadBranchesAndSensitiveTransport() async throws {
        let fixture = try LiveExportFixture.make()
        defer { fixture.clean() }
        try await fixture.seed("replay")
        try fixture.append(to: "replay", tag: "user_message_chunk", text: "Keep this", promptIndex: 0)
        try fixture.append(to: "replay", tag: "agent_message_chunk", text: "Kept answer")
        try fixture.append(to: "replay", tag: "user_message_chunk", text: "Host secret", hostTurn: true)
        try fixture.append(to: "replay", tag: "user_message_chunk", text: "Discard this", promptIndex: 1)
        try fixture.append(to: "replay", tag: "agent_message_chunk", text: "Dead branch")
        try fixture.append(
            to: "replay",
            method: "_x.ai/session/update",
            tag: "rewind_marker",
            rewindTo: 1
        )
        try fixture.append(to: "replay", tag: "agent_thought_chunk", text: "Private reasoning")
        try fixture.append(to: "replay", tag: "user_message_chunk", text: "Replacement", promptIndex: 1)
        try fixture.append(
            to: "replay", tag: "tool_call", title: "exec",
            input: ["command": .string("print('transport secret')")],
            toolCallID: "hidden-exec", hiddenTransport: true
        )
        try fixture.append(to: "replay", tag: "agent_message_chunk", text: "Live answer")
        let (streams, output, errors) = CLIStreams.buffered()

        try await fixture.launch(["export", "replay"], streams: streams)

        #expect(output.contents.contains("Keep this"))
        #expect(output.contents.contains("Kept answer"))
        #expect(output.contents.contains("Replacement"))
        #expect(output.contents.contains("Live answer"))
        #expect(!output.contents.contains("Discard this"))
        #expect(!output.contents.contains("Dead branch"))
        #expect(!output.contents.contains("Host secret"))
        #expect(!output.contents.contains("Private reasoning"))
        #expect(!output.contents.contains("transport secret"))
        #expect(errors.contents.isEmpty)
    }

    @Test("incremental assistant chunks coalesce while executable and web tools use Rust's summaries")
    func assistantChunksAndToolKindsRenderFaithfully() async throws {
        let fixture = try LiveExportFixture.make()
        defer { fixture.clean() }
        try await fixture.seed("tool-summary")
        try fixture.append(to: "tool-summary", tag: "user_message_chunk", text: "Investigate", promptIndex: 0)
        try fixture.append(to: "tool-summary", tag: "agent_message_chunk", text: "Hello ")
        try fixture.append(to: "tool-summary", tag: "agent_thought_chunk", text: "hidden")
        try fixture.append(to: "tool-summary", tag: "agent_message_chunk", text: "world")
        try fixture.append(
            to: "tool-summary", tag: "tool_call", title: "bash",
            input: ["command": .string("swift test"), "description": .string("verify")],
            toolCallID: "bash-call"
        )
        try fixture.append(
            to: "tool-summary", tag: "tool_call", title: "web_search",
            input: ["query": .string("Swift actors")], toolCallID: "web-call"
        )
        let (streams, output, _) = CLIStreams.buffered()

        try await fixture.launch(["export", "tool-summary"], streams: streams)

        #expect(output.contents.contains("## Assistant\n\nHello world"))
        #expect(output.contents.contains("## Tools\n\n- Execute: swift test (verify)"))
        #expect(output.contents.contains("- WebSearch: Swift actors"))
        #expect(!output.contents.contains("hidden"))
    }

    @Test("fork/resume context wrappers are stripped from exported user prompts")
    func internalContextWrappersNeverLeak() async throws {
        let fixture = try LiveExportFixture.make()
        defer { fixture.clean() }
        try await fixture.seed("wrapped")
        try fixture.append(
            to: "wrapped",
            tag: "user_message_chunk",
            text: "<fork-context>parent credentials</fork-context> Real prompt",
            promptIndex: 0
        )
        let (streams, output, _) = CLIStreams.buffered()

        try await fixture.launch(["export", "wrapped"], streams: streams)

        #expect(output.contents == "## User\n\nReal prompt\n")
        #expect(!output.contents.contains("parent credentials"))
    }

    @Test("missing sessions and sessions containing only non-conversation updates fail with Rust's messages")
    func missingAndEmptySessionsFailExplicitly() async throws {
        let fixture = try LiveExportFixture.make()
        defer { fixture.clean() }
        let (streams, output, errors) = CLIStreams.buffered()

        do {
            try await fixture.launch(["export", "missing"], streams: streams)
            Issue.record("missing session unexpectedly exported")
        } catch let error as CLIApplicationError {
            #expect(error == .failed("Session 'missing' not found."))
        }

        try await fixture.seed("empty")
        try fixture.append(to: "empty", tag: "agent_thought_chunk", text: "not conversation")
        do {
            try await fixture.launch(["export", "empty"], streams: streams)
            Issue.record("empty conversation unexpectedly exported")
        } catch let error as CLIApplicationError {
            #expect(error == .failed("Session 'empty' has no conversation content to export"))
        }
        #expect(output.contents.isEmpty)
        #expect(errors.contents.isEmpty)
    }

    @Test("journal replay, never a compatibility record or chat-history sidecar, owns export truth")
    func exportUsesJournalInsteadOfCompatibilityHistory() async throws {
        let fixture = try LiveExportFixture.make()
        defer { fixture.clean() }
        try await fixture.seed("journal-truth", items: [.user("Legacy compatibility text")])
        let journal = try fixture.journal("journal-truth")
        try Data().write(to: journal)
        try fixture.append(
            to: "journal-truth", tag: "user_message_chunk",
            text: "Authoritative journal text", promptIndex: 0
        )
        let (streams, output, _) = CLIStreams.buffered()

        try await fixture.launch(["export", "journal-truth"], streams: streams)

        #expect(output.contents == "## User\n\nAuthoritative journal text\n")
        #expect(!output.contents.contains("Legacy compatibility text"))
    }

    #if !os(Windows)
    @Test("a symbolic-link journal or symbolic-link sessions root is refused before any transcript read")
    func sourceSymlinksCannotExfiltrateOtherSessions() async throws {
        let fixture = try LiveExportFixture.make()
        defer { fixture.clean() }
        try await fixture.seed("victim", items: [.user("Protected content")])
        let journal = try fixture.journal("victim")
        let outside = fixture.root.appendingPathComponent("outside.jsonl")
        try Data("{\"stolen\":true}\n".utf8).write(to: outside)
        try FileManager.default.removeItem(at: journal)
        try FileManager.default.createSymbolicLink(at: journal, withDestinationURL: outside)
        let (streams, output, errors) = CLIStreams.buffered()

        await #expect(throws: CLIApplicationError.self) {
            try await fixture.launch(["export", "victim"], streams: streams)
        }
        #expect(output.contents.isEmpty)
        #expect(errors.contents.isEmpty)

        let attacker = try LiveExportFixture.make()
        defer { attacker.clean() }
        try FileManager.default.createSymbolicLink(
            at: attacker.state.appendingPathComponent("sessions"),
            withDestinationURL: fixture.state.appendingPathComponent("sessions")
        )
        let (attackerStreams, attackerOutput, _) = CLIStreams.buffered()
        await #expect(throws: CLIApplicationError.self) {
            try await attacker.launch(["export", "victim"], streams: attackerStreams)
        }
        #expect(attackerOutput.contents.isEmpty)
    }
    #endif

    @Test("cross-session envelope injection and malformed JSONL records fail before producing output")
    func poisonedJournalIsRejected() async throws {
        let fixture = try LiveExportFixture.make()
        defer { fixture.clean() }
        try await fixture.seed("owner")
        try fixture.append(
            to: "owner", tag: "user_message_chunk", text: "stolen", owner: "other-session"
        )
        let (streams, output, errors) = CLIStreams.buffered()

        await #expect(throws: CLIApplicationError.self) {
            try await fixture.launch(["export", "owner"], streams: streams)
        }
        #expect(output.contents.isEmpty)
        #expect(errors.contents.isEmpty)

        try await fixture.seed("malformed")
        try Data("{not valid JSON}\n".utf8).write(to: fixture.journal("malformed"))
        await #expect(throws: CLIApplicationError.self) {
            try await fixture.launch(["export", "malformed"], streams: streams)
        }
        #expect(output.contents.isEmpty)
    }

    #if !os(Windows)
    @Test("group-readable canonical journals are refused instead of exporting non-private history")
    func nonPrivateJournalFailsClosed() async throws {
        let fixture = try LiveExportFixture.make()
        defer { fixture.clean() }
        try await fixture.seed("permissions", items: [.user("Private")])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: fixture.journal("permissions").path
        )
        let (streams, output, errors) = CLIStreams.buffered()

        await #expect(throws: CLIApplicationError.self) {
            try await fixture.launch(["export", "permissions"], streams: streams)
        }
        #expect(output.contents.isEmpty)
        #expect(errors.contents.isEmpty)
    }
    #endif

    @Test("an oversized source journal is rejected by metadata before loading its bytes")
    func oversizedJournalIsBounded() async throws {
        let fixture = try LiveExportFixture.make()
        defer { fixture.clean() }
        try await fixture.seed("oversized", items: [.user("Should not appear")])
        let handle = try FileHandle(forUpdating: fixture.journal("oversized"))
        try handle.truncate(atOffset: UInt64(16 * 1_024 * 1_024 + 1))
        try handle.close()
        let (streams, output, _) = CLIStreams.buffered()

        await #expect(throws: CLIApplicationError.self) {
            try await fixture.launch(["export", "oversized"], streams: streams)
        }
        #expect(output.contents.isEmpty)
    }

    #if !os(Windows)
    @Test("existing symbolic-link destinations are never followed or reported as successful")
    func outputSymlinkIsRejected() async throws {
        let fixture = try LiveExportFixture.make()
        defer { fixture.clean() }
        try await fixture.seed("destination", items: [.user("Private export")])
        let untouched = fixture.root.appendingPathComponent("existing.md")
        try Data("do not overwrite".utf8).write(to: untouched)
        let link = fixture.root.appendingPathComponent("redirect.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: untouched)
        let (streams, output, errors) = CLIStreams.buffered()

        await #expect(throws: CLIApplicationError.self) {
            try await fixture.launch(["export", "destination", link.path], streams: streams)
        }
        let preserved = try String(contentsOf: untouched, encoding: .utf8)
        #expect(preserved == "do not overwrite")
        #expect(output.contents.isEmpty)
        #expect(errors.contents.isEmpty)
    }
    #endif

    @Test("export route claims only the real export command and rejects unsafe session identifiers")
    func routeClaimAndSessionIdentityAreStrict() async throws {
        let fixture = try LiveExportFixture.make()
        defer { fixture.clean() }
        let export = try CLICommandParser.parseOrThrow(["export", "legitimate"])
        let unrelated = try CLICommandParser.parseOrThrow(["trace", "legitimate"])
        #expect(LiveExportComposition.handles(export))
        #expect(!LiveExportComposition.handles(unrelated))
        let (streams, output, _) = CLIStreams.buffered()

        await #expect(throws: CLIApplicationError.self) {
            try await fixture.launch(["export", "../../another-user"], streams: streams)
        }
        #expect(output.contents.isEmpty)
    }
}
