// LiveAutoModeCompositionTests.swift
//
// Live seam for the auto-mode LLM classifier transcript + install helpers.

import Foundation
import OpenGrokSamplingTypes
import OpenGrokWorkspace
import Testing
@testable import OpenGrokCLI

@Suite("Live auto-mode composition")
struct LiveAutoModeCompositionTests {
    @Test("transcript keeps genuine user turns and assistant tool names")
    func transcriptShape() {
        let items: [ConversationItem] = [
            .user("hello world"),
            .assistant(AssistantItem(
                content: "working",
                toolCalls: [
                    ToolCall(id: "1", name: "search_replace", arguments: "{}"),
                    ToolCall(id: "2", name: "read_file", arguments: "{}"),
                ]
            )),
            .systemReminder("ignore me"),
            .user("follow up"),
        ]
        let text = LiveAutoModeComposition.transcript(from: items)
        #expect(text.contains("User: hello world"))
        #expect(text.contains("Assistant tools: search_replace, read_file"))
        #expect(text.contains("User: follow up"))
        #expect(!text.contains("ignore me"))
    }

    @Test("uninstall restores heuristic classifier")
    func uninstallRestoresHeuristic() async {
        let handle = PermissionHandle(
            autoMode: true,
            classifier: LlmPermissionClassifier.withFixedModelText(
                #"{"verdict":"allow"}"#
            )
        )
        #expect(await handle.hasLLMSideQuery)
        await LiveAutoModeComposition.uninstallLLMClassifier(on: handle)
        #expect(await handle.autoMode == false)
        #expect(await handle.hasLLMSideQuery == false)
    }
}
