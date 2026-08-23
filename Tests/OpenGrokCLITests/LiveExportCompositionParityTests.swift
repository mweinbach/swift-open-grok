import Foundation
import OpenGrokFileUtils
import OpenGrokSamplingTypes
import OpenGrokSessionPersistence
import OpenGrokShared
import OpenGrokShellSessionSupport
import OpenGrokWebMediaTools
import Testing
#if os(Windows)
import COpenGrokSockets
#endif

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
        ownerValue: JSONValue? = nil,
        omitOwner: Bool = false,
        title: String? = nil,
        input: [String: JSONValue]? = nil,
        rawInput: JSONValue? = nil,
        rawOutput: JSONValue? = nil,
        kind: String? = nil,
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
        if let rawInput {
            update["rawInput"] = rawInput
        } else if let input {
            update["rawInput"] = .object(input)
        }
        if let rawOutput { update["rawOutput"] = rawOutput }
        if let kind { update["kind"] = .string(kind) }
        if let toolCallID { update["toolCallId"] = .string(toolCallID) }
        var params: [String: JSONValue] = ["update": .object(update)]
        if !omitOwner {
            params["sessionId"] = ownerValue ?? .string(owner ?? id)
        }
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

    @Test("summary-only exact transport identities are redacted from real stdout, file, and clipboard exports")
    func durableTransportIdentityProtectsEveryDestination() async throws {
        let fixture = try LiveExportFixture.make()
        defer { fixture.clean() }
        try await fixture.seed(
            "summary-provenance",
            items: [.user("Visible conversation")],
            hiddenTransportIDs: ["durable-exec", "durable-wait"]
        )
        try fixture.append(
            to: "summary-provenance", tag: "tool_call", title: "exec",
            input: ["command": .string("SUMMARY_ONLY_SECRET_JAVASCRIPT")],
            kind: "other", toolCallID: "durable-exec"
        )
        try fixture.append(
            to: "summary-provenance", tag: "tool_call_update",
            rawOutput: .object(["text": .string("SUMMARY_ONLY_SECRET_RESULT")]),
            toolCallID: "durable-exec"
        )
        try fixture.append(
            to: "summary-provenance", tag: "tool_call", title: "wait",
            input: ["cell_id": .string("SUMMARY_ONLY_SECRET_CELL")],
            kind: "other", toolCallID: "durable-wait"
        )
        try fixture.append(
            to: "summary-provenance", tag: "tool_call", title: "read_file",
            input: ["path": .string("visible.swift")], kind: "read", toolCallID: "nested-read"
        )
        try fixture.append(
            to: "summary-provenance", tag: "tool_call", title: "exec",
            input: ["command": .string("VISIBLE_PLUGIN_COMMAND")],
            kind: "other", toolCallID: "plugin-exec"
        )
        try fixture.append(
            to: "summary-provenance", tag: "tool_call", title: "wait",
            input: ["job": .string("visible-plugin-job")],
            kind: "other", toolCallID: "plugin-wait"
        )

        let (stdoutStreams, stdout, _) = CLIStreams.buffered()
        try await fixture.launch(["export", "summary-provenance"], streams: stdoutStreams)

        let destination = fixture.root.appendingPathComponent("sanitized.md")
        let (fileStreams, _, _) = CLIStreams.buffered()
        try await fixture.launch(
            ["export", "summary-provenance", destination.path],
            streams: fileStreams
        )
        let fileContents = try String(contentsOf: destination, encoding: .utf8)

        let clipboard = ExportClipboardCapture()
        let services = LiveExportServices { text, _ in await clipboard.append(text) }
        let (clipboardStreams, _, _) = CLIStreams.buffered()
        try await fixture.runInjected(
            ["export", "summary-provenance", "--clipboard"],
            streams: clipboardStreams,
            services: services
        )
        let copied = try #require(await clipboard.snapshot().first)

        for transcript in [stdout.contents, fileContents, copied] {
            #expect(transcript.contains("Visible conversation"))
            #expect(transcript.contains("Read: visible.swift"))
            #expect(transcript.contains("Execute: VISIBLE_PLUGIN_COMMAND"))
            #expect(transcript.components(separatedBy: "- Tool: wait").count == 2)
            #expect(!transcript.contains("SUMMARY_ONLY_SECRET"))
        }
    }

    @Test("unmarked legacy string-input exec and its exact cell-linked wait are hidden without suppressing plugins")
    func legacyTransportShapeAndPairedWaitStayPrivate() async throws {
        let fixture = try LiveExportFixture.make()
        defer { fixture.clean() }
        try await fixture.seed("legacy-transport", items: [.user("Legacy visible prompt")])
        try fixture.append(
            to: "legacy-transport", tag: "tool_call", title: "exec",
            rawInput: .string("tools.exec_command({cmd: 'LEGACY_SECRET_JS'})"),
            kind: "other", toolCallID: "legacy-exec"
        )
        try fixture.append(
            to: "legacy-transport", tag: "tool_call_update",
            rawOutput: .object([
                "cell_id": .string("linked-legacy-cell"),
                "text": .string("LEGACY_SECRET_OUTPUT"),
            ]),
            toolCallID: "legacy-exec"
        )
        try fixture.append(
            to: "legacy-transport", tag: "tool_call", title: "wait",
            rawInput: .object(["cell_id": .string("linked-legacy-cell")]),
            rawOutput: .object(["text": .string("LEGACY_WAIT_SECRET")]),
            kind: "other", toolCallID: "legacy-wait"
        )
        try fixture.append(
            to: "legacy-transport", tag: "tool_call", title: "exec",
            input: ["command": .string("SAFE_PLUGIN_EXEC")],
            kind: "other", toolCallID: "plugin-exec"
        )
        try fixture.append(
            to: "legacy-transport", tag: "tool_call", title: "wait",
            rawInput: .object(["cell_id": .string("unrelated-plugin-cell")]),
            kind: "other", toolCallID: "plugin-wait"
        )
        let (streams, output, errors) = CLIStreams.buffered()

        try await fixture.launch(["export", "legacy-transport"], streams: streams)

        #expect(output.contents.contains("Execute: SAFE_PLUGIN_EXEC"))
        #expect(output.contents.components(separatedBy: "- Tool: wait").count == 2)
        #expect(!output.contents.contains("- Execute: exec"))
        #expect(!output.contents.contains("LEGACY_SECRET"))
        #expect(!output.contents.contains("LEGACY_WAIT_SECRET"))
        #expect(errors.contents.isEmpty)
    }

    @Test("a string-input external exec is preserved when its kind is not Code Mode's reserved other kind")
    func externalStringInputExecIsNotClassifiedByTitleAlone() async throws {
        let fixture = try LiveExportFixture.make()
        defer { fixture.clean() }
        try await fixture.seed("external-exec", items: [.user("Keep the external tool")])
        try fixture.append(
            to: "external-exec", tag: "tool_call", title: "exec",
            rawInput: .string("an ordinary extension's string argument"),
            kind: "execute", toolCallID: "external-string-exec"
        )
        let (streams, output, errors) = CLIStreams.buffered()

        try await fixture.launch(["export", "external-exec"], streams: streams)

        #expect(output.contents.contains("## Tools\n\n- Execute: exec"))
        #expect(errors.contents.isEmpty)
    }

    @Test("a marked terminal update redacts its unmarked secret-bearing base across the full replay")
    func mixedMarkedAndUnmarkedTransportUpdatesAreCoupled() async throws {
        let fixture = try LiveExportFixture.make()
        defer { fixture.clean() }
        try await fixture.seed("mixed-markers", items: [.user("Keep visible tools")])
        try fixture.append(
            to: "mixed-markers", tag: "tool_call", title: "exec",
            input: ["command": .string("MIXED_MARKER_SECRET")],
            kind: "other", toolCallID: "marked-terminal-only"
        )
        try fixture.append(
            to: "mixed-markers", tag: "tool_call_update",
            rawOutput: .object(["text": .string("MIXED_RESULT_SECRET")]),
            toolCallID: "marked-terminal-only", hiddenTransport: true
        )
        try fixture.append(
            to: "mixed-markers", tag: "tool_call", title: "exec",
            input: ["command": .string("VISIBLE_EXTERNAL_EXEC")],
            kind: "other", toolCallID: "genuine-exec"
        )
        let (streams, output, errors) = CLIStreams.buffered()

        try await fixture.launch(["export", "mixed-markers"], streams: streams)

        #expect(output.contents.contains("Execute: VISIBLE_EXTERNAL_EXEC"))
        #expect(!output.contents.contains("MIXED_MARKER_SECRET"))
        #expect(!output.contents.contains("MIXED_RESULT_SECRET"))
        #expect(errors.contents.isEmpty)
    }

    @Test("transport provenance is session-owned even when an unrelated plugin reuses the same call ID")
    func transportIdentityNeverBleedsAcrossSessions() async throws {
        let fixture = try LiveExportFixture.make()
        defer { fixture.clean() }
        try await fixture.seed(
            "transport-owner",
            items: [.user("Protected session")],
            hiddenTransportIDs: ["shared-call-id"]
        )
        try fixture.append(
            to: "transport-owner", tag: "tool_call", title: "exec",
            input: ["command": .string("OWNER_ONLY_SECRET")],
            kind: "other", toolCallID: "shared-call-id"
        )
        try await fixture.seed("plugin-owner", items: [.user("Plugin session")])
        try fixture.append(
            to: "plugin-owner", tag: "tool_call", title: "exec",
            input: ["command": .string("UNRELATED_PLUGIN_VISIBLE")],
            kind: "other", toolCallID: "shared-call-id"
        )
        let (protectedStreams, protectedOutput, _) = CLIStreams.buffered()
        let (pluginStreams, pluginOutput, _) = CLIStreams.buffered()

        try await fixture.launch(["export", "transport-owner"], streams: protectedStreams)
        try await fixture.launch(["export", "plugin-owner"], streams: pluginStreams)

        #expect(!protectedOutput.contents.contains("OWNER_ONLY_SECRET"))
        #expect(pluginOutput.contents.contains("Execute: UNRELATED_PLUGIN_VISIBLE"))
    }

    @Test("forked sessions inherit exact transport identities and cannot export parent transport secrets")
    func forkInheritedTransportProvenanceRemainsPrivate() async throws {
        let fixture = try LiveExportFixture.make()
        defer { fixture.clean() }
        try await fixture.seed(
            "fork-source",
            items: [.user("Fork-visible conversation")],
            hiddenTransportIDs: ["fork-transport"]
        )
        try fixture.append(
            to: "fork-source", tag: "tool_call", title: "exec",
            input: ["command": .string("FORK_INHERITED_SECRET")],
            kind: "other", toolCallID: "fork-transport"
        )
        try fixture.append(
            to: "fork-source", tag: "tool_call", title: "exec",
            input: ["command": .string("VISIBLE_FORK_PLUGIN")],
            kind: "other", toolCallID: "fork-plugin"
        )
        let forked = try await LiveConversationStore(openGrokHome: fixture.state).fork(
            sourceSessionID: "fork-source",
            destinationSessionID: "fork-child",
            workingDirectory: fixture.workspace
        )
        #expect(forked.codeModeTransportCallIDs == ["fork-transport"])
        let (streams, output, errors) = CLIStreams.buffered()

        try await fixture.launch(["export", "fork-child"], streams: streams)

        #expect(output.contents.contains("Fork-visible conversation"))
        #expect(output.contents.contains("Execute: VISIBLE_FORK_PLUGIN"))
        #expect(!output.contents.contains("FORK_INHERITED_SECRET"))
        #expect(errors.contents.isEmpty)
    }

    @Test("malformed durable transport provenance fails closed before a secret-bearing journal can export")
    func invalidTransportAuthorityNeverFallsBackToGuessing() async throws {
        let fixture = try LiveExportFixture.make()
        defer { fixture.clean() }
        try await fixture.seed(
            "invalid-provenance",
            items: [.user("A prompt")],
            hiddenTransportIDs: ["secret-call"]
        )
        try fixture.append(
            to: "invalid-provenance", tag: "tool_call", title: "exec",
            input: ["command": .string("MALFORMED_AUTHORITY_SECRET")],
            kind: "other", toolCallID: "secret-call"
        )
        let directory = try SessionDocumentStore(grokHome: fixture.state).sessionDirectory(
            sessionID: "invalid-provenance",
            cwd: fixture.workspace.path
        )
        let summary = directory.appendingPathComponent(SessionDocumentStore.summaryFileName)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: PathSecurity.readNoFollow(summary))
        guard case .object(var object) = decoded else {
            Issue.record("session summary was not an object")
            return
        }
        object["code_mode_transport_call_ids"] = .string("secret-call")
        try SecureFile.write(at: summary, contents: JSONEncoder().encode(JSONValue.object(object)))
        let (streams, output, errors) = CLIStreams.buffered()

        await #expect(throws: CLIApplicationError.self) {
            try await fixture.launch(["export", "invalid-provenance"], streams: streams)
        }
        #expect(output.contents.isEmpty)
        #expect(errors.contents.isEmpty)
    }

    #if os(Windows)
    @Test("Windows export accepts only canonical summary and journal files with verified owner-only DACLs")
    func windowsOwnerOnlyDocumentsReachRealExport() async throws {
        let fixture = try LiveExportFixture.make()
        defer { fixture.clean() }
        try await fixture.seed("windows-private", items: [.user("Owner-private Windows transcript")])
        let journal = try fixture.journal("windows-private")
        let summary = journal.deletingLastPathComponent()
            .appendingPathComponent(SessionDocumentStore.summaryFileName)
        let summaryIsPrivate = try SecureFile.isOwnerOnly(at: summary)
        let journalIsPrivate = try SecureFile.isOwnerOnly(at: journal)
        #expect(summaryIsPrivate)
        #expect(journalIsPrivate)
        let sessionDirectory = journal.deletingLastPathComponent()
        let workspaceDirectory = sessionDirectory.deletingLastPathComponent()
        let sessionsDirectory = workspaceDirectory.deletingLastPathComponent()
        for directory in [sessionsDirectory, workspaceDirectory, sessionDirectory] {
            let ownerPrivate = directory.path.withCString {
                og_path_is_private_to_current_user($0, 1)
            }
            #expect(ownerPrivate == 1)
        }
        let (streams, output, errors) = CLIStreams.buffered()

        try await fixture.launch(["export", "windows-private"], streams: streams)

        #expect(output.contents == "## User\n\nOwner-private Windows transcript\n")
        #expect(errors.contents.isEmpty)
    }

    @Test("owner-private sessions beyond MAX_PATH export through the real stdout, file, and clipboard routes")
    func windowsExtendedLengthSessionsReachEveryExportDestination() async throws {
        let fixture = try LiveExportFixture.make()
        defer { fixture.clean() }
        let deepState = fixture.root.appendingPathComponent(
            String(repeating: "s", count: 120),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: deepState, withIntermediateDirectories: true)
        let deep = LiveExportFixture(
            root: fixture.root,
            state: deepState,
            userHome: fixture.userHome,
            workspace: fixture.workspace
        )
        let sessionID = UUID().uuidString
        let prompt = "Owner-private transcript beyond the Windows MAX_PATH boundary"
        let store = SessionDocumentStore(grokHome: deepState)
        let directory = try store.sessionDirectory(sessionID: sessionID, cwd: fixture.workspace.path)
        #expect(directory.path.utf16.count > 260)

        let history = try JSONValue.encode(ConversationItem.user(prompt))
        let update = SessionUpdateEnvelope(
            timestamp: 123,
            method: "session/update",
            params: .object([
                "sessionId": .string(sessionID),
                "update": .object([
                    "sessionUpdate": .string("user_message_chunk"),
                    "content": .object([
                        "type": .string("text"),
                        "text": .string(prompt),
                    ]),
                ]),
            ])
        )
        try store.save(PersistedSessionState(
            summary: SessionSummary(
                sessionID: SessionID(sessionID),
                cwd: fixture.workspace.path,
                currentModelID: "grok-code-fast-1"
            ),
            chatHistory: [history],
            updates: [update]
        ))

        let summary = directory.appendingPathComponent(SessionDocumentStore.summaryFileName)
        let journal = directory.appendingPathComponent(SessionDocumentStore.updatesFileName)
        let lock = directory.appendingPathComponent("\(SessionDocumentStore.summaryFileName).lock")
        let summaryPrivate = try SecureFile.isOwnerOnly(at: summary)
        let journalPrivate = try SecureFile.isOwnerOnly(at: journal)
        let lockPrivate = try SecureFile.isOwnerOnly(at: lock)
        #expect(summaryPrivate)
        #expect(journalPrivate)
        #expect(lockPrivate)
        #expect(lock.path.utf16.count > 260)
        for ancestor in [
            deepState.appendingPathComponent("sessions", isDirectory: true),
            directory.deletingLastPathComponent(),
            directory,
        ] {
            let native = try WindowsSecurePath.extendedLengthPath(ancestor.path)
            let ownerPrivate = native.withCString { og_path_is_private_to_current_user($0, 1) }
            #expect(ownerPrivate == 1)
        }

        let markdown = "## User\n\n\(prompt)"
        let (stdoutStreams, stdout, stdoutErrors) = CLIStreams.buffered()
        try await deep.launch(["export", sessionID], streams: stdoutStreams)
        #expect(stdout.contents == markdown + "\n")
        #expect(stdoutErrors.contents.isEmpty)

        let destination = fixture.root.appendingPathComponent("long-session-export.md")
        let (fileStreams, fileOutput, fileErrors) = CLIStreams.buffered()
        try await deep.launch(["export", sessionID, destination.path], streams: fileStreams)
        let written = try String(contentsOf: destination, encoding: .utf8)
        #expect(written == markdown)
        #expect(fileOutput.contents.isEmpty)
        #expect(fileErrors.contents.contains("Conversation exported to"))

        let clipboard = ExportClipboardCapture()
        let services = LiveExportServices { text, _ in await clipboard.append(text) }
        let (clipboardStreams, clipboardOutput, clipboardErrors) = CLIStreams.buffered()
        try await deep.runInjected(
            ["export", sessionID, "--clipboard"],
            streams: clipboardStreams,
            services: services
        )
        #expect(await clipboard.snapshot() == [markdown])
        #expect(clipboardOutput.contents.isEmpty)
        #expect(clipboardErrors.contents.contains("Conversation copied to clipboard"))
    }

    @Test("Windows export refuses an independently verified permissive sessions-root DACL")
    func windowsRejectsPermissiveSessionDirectory() async throws {
        let fixture = try LiveExportFixture.make()
        defer { fixture.clean() }
        let broadHome = fixture.root.appendingPathComponent("permissive-state", isDirectory: true)
        let broadSessions = broadHome.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: broadSessions, withIntermediateDirectories: true)
        let ownerPrivate = broadSessions.path.withCString {
            og_path_is_private_to_current_user($0, 1)
        }
        guard ownerPrivate == 0 else {
            Issue.record("negative Windows ACL fixture did not create a permissive sessions directory")
            return
        }
        let command = try CLICommandParser.parseOrThrow(["export", "victim"])
        let (streams, output, errors) = CLIStreams.buffered()

        await #expect(throws: CLIApplicationError.self) {
            let session = try await LiveExportComposition.session(
                for: command,
                context: CLIApplicationContext(
                    environment: ["OPENGROK_HOME": broadHome.path, "HOME": fixture.userHome.path],
                    streams: streams,
                    control: .never
                )
            )
            try await session.waitForExit()
        }
        #expect(output.contents.isEmpty)
        #expect(errors.contents.isEmpty)
    }
    #endif

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

    @Test("missing, null, numeric, and foreign journal identities cannot reach stdout, files, or clipboard")
    func everyReplayEnvelopeRequiresItsExactSessionIdentity() async throws {
        let fixture = try LiveExportFixture.make()
        defer { fixture.clean() }
        let variants: [(name: String, owner: JSONValue?, omit: Bool, method: String)] = [
            ("missing-owner", nil, true, "session/update"),
            ("null-owner", .null, false, "session/update"),
            ("numeric-owner", .number(.uint64(42)), false, "session/update"),
            ("foreign-owner", .string("another-session"), false, "session/update"),
            ("missing-xai-owner", nil, true, "_x.ai/session/update"),
        ]
        let clipboard = ExportClipboardCapture()
        let services = LiveExportServices { text, _ in await clipboard.append(text) }

        for variant in variants {
            try await fixture.seed(variant.name, items: [.user("Visible preceding update")])
            try fixture.append(
                to: variant.name,
                method: variant.method,
                tag: variant.method == "session/update" ? "agent_message_chunk" : "rewind_marker",
                text: "INJECTED_CROSS_SESSION_SECRET",
                ownerValue: variant.owner,
                omitOwner: variant.omit
            )

            let (stdoutStreams, stdout, stdoutErrors) = CLIStreams.buffered()
            await #expect(throws: CLIApplicationError.self) {
                try await fixture.launch(["export", variant.name], streams: stdoutStreams)
            }
            #expect(stdout.contents.isEmpty)
            #expect(stdoutErrors.contents.isEmpty)

            let destination = fixture.root.appendingPathComponent("\(variant.name).md")
            let (fileStreams, fileOutput, fileErrors) = CLIStreams.buffered()
            await #expect(throws: CLIApplicationError.self) {
                try await fixture.launch(
                    ["export", variant.name, destination.path],
                    streams: fileStreams
                )
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            #expect(fileOutput.contents.isEmpty)
            #expect(fileErrors.contents.isEmpty)

            let (clipboardStreams, clipboardOutput, clipboardErrors) = CLIStreams.buffered()
            await #expect(throws: CLIApplicationError.self) {
                try await fixture.runInjected(
                    ["export", variant.name, "--clipboard"],
                    streams: clipboardStreams,
                    services: services
                )
            }
            #expect(clipboardOutput.contents.isEmpty)
            #expect(clipboardErrors.contents.isEmpty)
            #expect(await clipboard.snapshot().isEmpty)
        }
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
