// LlmPermissionClassifierTests.swift

import Testing
@testable import OpenGrokWorkspace

@Suite("LlmPermissionClassifier")
struct LlmPermissionClassifierTests {

    @Test("heuristic Allow skips side-query")
    func heuristicAllowSkipsSideQuery() async {
        final class CallCounter: @unchecked Sendable {
            var count = 0
        }
        let counter = CallCounter()
        let classifier = LlmPermissionClassifier { _ in
            counter.count += 1
            return #"{"thinking":"x","shouldBlock":true,"reason":"should not run"}"#
        }
        let outcome = await classifier.classifyOutcome(
            toolName: "bash",
            access: .bash("ls"),
            accessDetail: "ls",
            context: ClassifierContext()
        )
        #expect(outcome.verdict == .allow)
        #expect(outcome.source == .heuristic)
        #expect(counter.count == 0)
        let decision = await classifier.classify(
            access: .bash("ls"),
            toolName: "bash",
            accessDetail: "ls",
            transcript: ""
        )
        #expect(decision == .allow)
        #expect(counter.count == 0)
    }

    @Test("fixed shouldBlock false allows heuristic-blocked edit")
    func llmAllowOverridesHeuristicBlock() async {
        let classifier = LlmPermissionClassifier.withFixedModelText(
            #"{"thinking":"ok","shouldBlock":false,"reason":"routine edit"}"#
        )
        let outcome = await classifier.classifyOutcome(
            toolName: "edit",
            access: .edit("src/main.swift"),
            accessDetail: "src/main.swift",
            context: ClassifierContext()
        )
        #expect(outcome.verdict == .allow)
        #expect(outcome.source == .llm)
        #expect(outcome.reason == "routine edit")
        let decision = LlmPermissionClassifier.permissionDecision(from: outcome)
        #expect(decision == .allow)
    }

    @Test("fixed shouldBlock true blocks")
    func llmBlock() async {
        let classifier = LlmPermissionClassifier.withFixedModelText(
            #"{"thinking":"no","shouldBlock":true,"reason":"side effect"}"#
        )
        let outcome = await classifier.classifyOutcome(
            toolName: "edit",
            access: .edit("src/main.swift"),
            accessDetail: "src/main.swift",
            context: ClassifierContext()
        )
        #expect(outcome.verdict == .block)
        #expect(outcome.source == .llm)
        guard case .policyDeny(let reason) = LlmPermissionClassifier.permissionDecision(from: outcome) else {
            Issue.record("expected policyDeny")
            return
        }
        #expect(reason == "side effect")
    }

    @Test("unparseable falls back to heuristic Block")
    func unparseableFallsBackToHeuristic() async {
        let classifier = LlmPermissionClassifier.withFixedModelText("not json at all")
        let outcome = await classifier.classifyOutcome(
            toolName: "edit",
            access: .edit("src/main.swift"),
            accessDetail: "src/main.swift",
            context: ClassifierContext()
        )
        #expect(outcome.verdict == .block)
        #expect(outcome.source == .heuristic)
    }

    @Test("timeout maps to Unavailable and ask")
    func timeoutUnavailableAsk() async {
        let classifier = LlmPermissionClassifier { _ in
            throw ClassifierFailure.timeout
        }
        let outcome = await classifier.classifyOutcome(
            toolName: "edit",
            access: .edit("src/main.swift"),
            accessDetail: "src/main.swift",
            context: ClassifierContext()
        )
        #expect(outcome.verdict == .unavailable)
        #expect(outcome.isTimeout)
        #expect(outcome.source == .timeout)
        #expect(LlmPermissionClassifier.permissionDecision(from: outcome) == .ask)
    }

    @Test("parse terse allow and block; empty unavailable")
    func parseTerseAndEmpty() {
        #expect(parseClassifierModelOutput("allow").verdict == .allow)
        #expect(parseClassifierModelOutput("ALLOW").verdict == .allow)
        #expect(parseClassifierModelOutput("blocked").verdict == .block)
        #expect(parseClassifierModelOutput("deny").verdict == .block)
        let empty = parseClassifierModelOutput("   ")
        #expect(empty.verdict == .unavailable)
        // Loose false substring must not Allow.
        let loose = parseClassifierModelOutput(
            #"narrative mentions "shouldBlock": false but is not a decision"#
        )
        #expect(loose.verdict == .unavailable)
        let fenced = parseClassifierModelOutput(
            """
            Here you go:
            ```json
            {"thinking":"t","shouldBlock":true,"reason":"r"}
            ```
            """
        )
        #expect(fenced.verdict == .block)
        #expect(fenced.reason == "r")
    }

    @Test("buildClassifierMessages Full includes system prompt and proposed action")
    func buildMessagesFull() {
        let messages = buildClassifierMessages(
            toolName: "bash",
            access: .bash("cargo test"),
            accessDetail: "cargo test",
            context: ClassifierContext(
                transcript: "User: please test",
                projectInstructions: "# Project\nBe careful"
            ),
            promptType: .full
        )
        #expect(messages.count >= 3)
        #expect(messages[0].role == .system)
        #expect(messages[0].text == AUTO_MODE_CLASSIFIER_SYSTEM_PROMPT)
        #expect(messages.contains { $0.role == .user && $0.text.contains("<project_instructions>") })
        let trailing = messages.last
        #expect(trailing?.role == .user)
        #expect(trailing?.text.contains("## Proposed action") == true)
        #expect(trailing?.text.contains("tool: bash") == true)
        #expect(trailing?.text.contains("access_kind: bash") == true)
        #expect(trailing?.text.contains("detail: cargo test") == true)
        #expect(trailing?.text.contains("## Recent conversation") == true)
        // Heading neutralization escapes leading #.
        #expect(messages.contains { $0.text.contains("\\# Project") })
    }

    @Test("schema has thinking shouldBlock reason")
    func schemaShape() {
        guard case .object(let root) = classifierOutputJSONSchema() else {
            Issue.record("expected object schema")
            return
        }
        guard case .object(let props)? = root["properties"] else {
            Issue.record("expected properties")
            return
        }
        #expect(props["thinking"] != nil)
        #expect(props["shouldBlock"] != nil)
        #expect(props["reason"] != nil)
        guard case .array(let required)? = root["required"] else {
            Issue.record("expected required")
            return
        }
        #expect(required.contains(.string("thinking")))
        #expect(required.contains(.string("shouldBlock")))
        #expect(required.contains(.string("reason")))
    }

    @Test("PermissionHandle hasLLMSideQuery tracks classifyText")
    func handleSideQueryFlag() async {
        let handle = PermissionHandle(autoMode: true, classifier: HeuristicPermissionClassifier())
        #expect(await handle.hasLLMSideQuery == false)
        await handle.setClassifier(LlmPermissionClassifier())
        #expect(await handle.hasLLMSideQuery == false)
        await handle.setClassifier(LlmPermissionClassifier.withFixedModelText("{}"))
        #expect(await handle.hasLLMSideQuery == true)
        await handle.setClassifierTranscript("User: hi")
        await handle.setClassifierProjectInstructions("agents")
        #expect(await handle.classifierTranscript == "User: hi")
        #expect(await handle.classifierProjectInstructions == "agents")
    }
}
