import Foundation
import OpenGrokConfig
import OpenGrokSamplingTypes
import Testing
@testable import OpenGrokCLI

@Suite("Session search UTF-8 content budgets and recent-tail parity")
struct LiveSessionSearchTailParityTests {
    @Test("long histories retain recent prompts, assistant replies, and tool metadata")
    func longHistoryIndexesItsMostRecentContent() throws {
        let oldest = "oldestpromptneedle " + String(repeating: "x", count: 210_000)
        let record = makeRecord(
            items: [
                .user(oldest),
                .user("newestpromptneedle"),
                .assistant(AssistantItem(
                    content: "newestassistantneedle",
                    toolCalls: [ToolCall(
                        id: "recent-tool",
                        name: "newesttoolneedle",
                        arguments: #"{"path":"/workspace/newestpathneedle.swift"}"#
                    )]
                )),
            ],
            title: "Preserved explicit title"
        )
        let document = LiveSessionDocument.build(from: record)

        #expect(document.content.utf8.count == 200_000)
        #expect(document.title == "Preserved explicit title")
        #expect(!document.content.contains("oldestpromptneedle"))
        for needle in [
            "newestpromptneedle",
            "newestassistantneedle",
            "newesttoolneedle",
            "newestpathneedle",
        ] {
            #expect(document.content.contains(needle))
            #expect(
                LiveSessionSearch.rank(documents: [document], query: needle, limit: 1)
                    .map(\.sessionID) == [record.sessionID]
            )
        }
        #expect(
            LiveSessionSearch.rank(
                documents: [document],
                query: "oldestpromptneedle",
                limit: 1
            ).isEmpty
        )

        #if canImport(SQLite3)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-session-tail-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = [
            "HOME": root.path,
            "OPENGROK_HOME": root.path,
            "GROK_SESSION_SEARCH": "1",
        ]
        let gate = SessionSearchGate()
        let source = LiveSessionSearchIndexSource(document: document)

        for needle in ["newestassistantneedle", "newesttoolneedle", "newestpathneedle"] {
            let page = try LiveSessionSearchIndex.search(
                openGrokHome: root,
                environment: environment,
                query: needle,
                limit: 1,
                gate: gate,
                sources: { [source] }
            )
            #expect(page.hits.map(\.sessionID) == [record.sessionID])
        }
        let trimmed = try LiveSessionSearchIndex.search(
            openGrokHome: root,
            environment: environment,
            query: "oldestpromptneedle",
            limit: 1,
            gate: gate,
            sources: { [source] }
        )
        #expect(trimmed.hits.isEmpty)
        #endif
    }

    @Test("combined content keeps at most 200,000 bytes", arguments: [
        199_995, 199_996, 199_997, 200_000,
    ])
    func combinedContentBoundary(promptBytes: Int) {
        let prompt = String(repeating: "p", count: promptBytes)
        let document = LiveSessionDocument.build(from: makeRecord(items: [.user(prompt)]))

        #expect(document.content.utf8.count == min(promptBytes + 4, 200_000))
        #expect(document.content.hasSuffix("\n\n\n\n"))
        #expect(document.content.filter { $0 == "p" }.count == min(promptBytes, 199_996))
    }

    @Test("assistant text has its own 100,000-byte budget", arguments: [
        99_999, 100_000, 100_001,
    ])
    func assistantFieldBoundary(assistantBytes: Int) {
        let assistant = String(repeating: "a", count: assistantBytes)
        let document = LiveSessionDocument.build(from: makeRecord(items: [
            .user("prompt"),
            .assistant(AssistantItem(content: assistant)),
        ]))

        #expect(document.content == "prompt\n\n" + String(assistant.prefix(100_000)) + "\n\n")
    }

    @Test("tool metadata has its own 100,000-byte budget", arguments: [
        99_999, 100_000, 100_001,
    ])
    func toolMetadataFieldBoundary(toolBytes: Int) {
        let toolName = String(repeating: "t", count: toolBytes)
        let document = LiveSessionDocument.build(from: makeRecord(items: [
            .user("prompt"),
            .assistant(AssistantItem(
                content: "",
                toolCalls: [ToolCall(id: "large-tool", name: toolName, arguments: "{}")]
            )),
        ]))

        #expect(document.content == "prompt\n\n\n\n" + String(toolName.prefix(100_000)))
    }

    @Test("field limits round down at UTF-8 scalar boundaries without charging separators")
    func multibyteFieldBoundariesRemainValid() {
        let oversizedAssistant = String(repeating: "a", count: 99_998) + "🚀discardedassistant"
        let oversizedToolName = String(repeating: "t", count: 99_998)
        let document = LiveSessionDocument.build(from: makeRecord(items: [
            .user("prompt"),
            .assistant(AssistantItem(content: oversizedAssistant)),
            .assistant(AssistantItem(
                content: "ok",
                toolCalls: [ToolCall(
                    id: "unicode-tool",
                    name: oversizedToolName,
                    arguments: #"{"path":"🚀discardedpath","file_path":"ok"}"#
                )]
            )),
        ]))

        #expect(document.content.utf8.count == 200_000)
        #expect(document.content.contains(String(repeating: "a", count: 99_985)))
        #expect(document.content.contains("a\nok\n\n"))
        #expect(document.content.hasSuffix("t\nok"))
        #expect(!document.content.contains("🚀"))
        #expect(!document.content.contains("discardedassistant"))
        #expect(!document.content.contains("discardedpath"))
        #expect(!document.content.contains("\u{FFFD}"))
    }

    @Test("field truncation follows Rust scalar boundaries inside extended graphemes")
    func combinedGraphemeUsesScalarBoundaries() {
        let oversizedAssistant = String(repeating: "a", count: 99_998) + "e\u{301}"
        let document = LiveSessionDocument.build(from: makeRecord(items: [
            .user("prompt"),
            .assistant(AssistantItem(content: oversizedAssistant)),
            .assistant(AssistantItem(content: "Z")),
        ]))

        #expect(document.content.hasSuffix("e\nZ\n\n"))
        #expect(!document.content.contains("\u{301}"))
        #expect(!document.content.contains("\u{FFFD}"))
    }

    @Test("the 200,000-byte tail starts after a split multibyte scalar")
    func multibyteCombinedBoundaryRemainsValid() {
        let suffix = String(repeating: "y", count: 199_993)
        let prompt = "x🚀" + suffix
        let document = LiveSessionDocument.build(from: makeRecord(items: [.user(prompt)]))

        #expect(document.content.utf8.count == 199_997)
        #expect(document.content == suffix + "\n\n\n\n")
        #expect(!document.content.contains("🚀"))
        #expect(!document.content.contains("\u{FFFD}"))
    }

    @Test("synthetic prompts and raw private tool arguments remain excluded")
    func privateAndSyntheticContentRemainsExcluded() {
        let record = makeRecord(
            items: [
                .system("privatesystemneedle"),
                .userMeta("syntheticsecretneedle"),
                .user("realpromptneedle"),
                .assistant(AssistantItem(
                    content: "visibleassistantneedle",
                    toolCalls: [ToolCall(
                        id: "visible-tool",
                        name: "visibletoolneedle",
                        arguments: #"{"command":"privatetoolargumentneedle","path":"/visible/path.swift"}"#
                    )]
                )),
            ],
            title: "Private-safe explicit title"
        )
        let document = LiveSessionDocument.build(from: record)

        #expect(document.title == "Private-safe explicit title")
        #expect(document.content == """
        realpromptneedle

        visibleassistantneedle

        visibletoolneedle
        /visible/path.swift
        """)
        #expect(!document.content.contains("privatesystemneedle"))
        #expect(!document.content.contains("syntheticsecretneedle"))
        #expect(!document.content.contains("privatetoolargumentneedle"))
    }

    private func makeRecord(
        items: [ConversationItem],
        title: String? = nil
    ) -> LiveConversationRecord {
        let timestamp = Date(timeIntervalSince1970: 1_000)
        return LiveConversationRecord(
            sessionID: "tail-parity-session",
            workingDirectory: "/workspace",
            parentSessionID: nil,
            createdAt: timestamp,
            updatedAt: timestamp,
            items: items,
            title: title
        )
    }
}
