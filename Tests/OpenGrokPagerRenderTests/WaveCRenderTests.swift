import Foundation
import Testing
@testable import OpenGrokPagerRender

private let waveCTheme = PagerRenderTheme.default

private func waveCJSON(_ value: Any) -> String {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
    return String(data: data, encoding: .utf8)!
}

private func waveCLines(_ tool: PagerToolCard, width: Int = 80) -> [PaintLine] {
    makeConversationLines([.tool(tool)], width: width, theme: waveCTheme)
}

private func waveCText(_ tool: PagerToolCard, width: Int = 80) -> String {
    waveCLines(tool, width: width).map { $0.spans.map(\.text).joined() }.joined(separator: "\n")
}

private func waveCHeaderSelection(_ tool: PagerToolCard, width: Int = 80) -> String {
    waveCLines(tool, width: width).compactMap(\.selection)
        .filter { $0.rangeID == 0 }
        .map(\.text)
        .joined()
}

private func waveCGroupedText(_ tools: [PagerToolCard], width: Int = 80) -> String {
    makeConversationLines(
        tools.map { .tool($0) },
        width: width,
        theme: waveCTheme,
        groupToolVerbs: true
    ).map(\.text).joined(separator: "\n")
}

@Suite("Wave C tool payloads and painters")
struct WaveCRenderTests {
    @Test("verb groups aggregate eligible collapsed tools and use running tense")
    func verbGroupHeaders() {
        let reads = (0..<3).map { index in
            PagerToolCard.make(
                name: "read_file",
                rawInput: waveCJSON(["file_path": "file\(index).swift"]),
                output: "line",
                state: index == 2 ? .running : .succeeded,
                structuredOutput: waveCJSON([
                    "type": "file_content",
                    "path": "file\(index).swift",
                    "content": "line",
                    "total_lines": 1,
                    "start_line": 1,
                    "end_line": 1,
                    "truncated": false,
                ])
            )
        }
        #expect(waveCGroupedText(reads).contains("Reading 3 files"))

        let search = PagerToolCard.make(
            name: "grep",
            rawInput: waveCJSON(["pattern": "TODO"]),
            state: .succeeded,
            structuredOutput: waveCJSON([
                "type": "grep",
                "pattern": "TODO",
                "output_mode": "content",
                "match_count": 0,
                "file_count": 0,
                "matches": [],
            ])
        )
        #expect(waveCGroupedText([reads[0], search]).contains("Read 1 file, Searched 1 pattern"))
    }

    @Test("verb groups stop at action tools and open cards")
    func verbGroupBoundaries() {
        let read = PagerToolCard.make(
            name: "read_file",
            rawInput: waveCJSON(["file_path": "a.swift"]),
            output: "a",
            state: .succeeded,
            structuredOutput: waveCJSON([
                "type": "file_content",
                "path": "a.swift",
                "content": "a",
                "total_lines": 1,
                "start_line": 1,
                "end_line": 1,
                "truncated": false,
            ])
        )
        let command = PagerToolCard(name: "execute", kind: .execute, input: "pwd", state: .succeeded)
        var openRead = read
        openRead.isExpanded = true
        let text = waveCGroupedText([read, command, openRead])
        #expect(text.contains("Read 1 file"))
        #expect(text.contains("Run pwd"))
        #expect(text.contains("Read a.swift"))
    }

    @Test("generic other splits Label colon content headers")
    func otherLabelContentSplit() {
        let card = PagerToolCard(
            name: "Review: src/App.swift",
            kind: .generic,
            output: "done",
            state: .succeeded
        )
        let text = waveCText(card)
        #expect(text.contains("Review src/App.swift"))
        #expect(!text.contains("Review: Src/App.Swift"))
    }

    @Test("read range uses basename collapsed, gutters expanded, and 5+3 truncation")
    func readRangeAndTruncation() throws {
        let content = (11...20).map { "\($0)→line \($0)" }.joined(separator: "\n")
        let card = PagerToolCard.make(
            name: "read_file",
            rawInput: waveCJSON(["file_path": "/workspace/src/main.swift"]),
            cwd: "/workspace",
            output: content,
            state: .succeeded,
            isExpanded: true,
            structuredOutput: waveCJSON([
                "type": "file_content",
                "path": "/workspace/src/main.swift",
                "content": content,
                "total_lines": 200,
                "start_line": 11,
                "end_line": 20,
                "truncated": true,
            ])
        )
        let payload = try #require(card.waveCPayload)
        guard case .read(let read) = payload else {
            Issue.record("expected read payload")
            return
        }
        #expect(read.content?.contains("11→") == false)
        let text = waveCText(card, width: 36)
        #expect(text.contains("Read src/main.swift (11-20 of 200)"))
        #expect(text.contains("11  line 11"))
        #expect(text.contains("20  line 20"))
        #expect(text.contains("…"))
        #expect(waveCLines(card).allSatisfy { $0.accentGlyph == nil })
    }

    @Test("empty read is header-only and non-foldable")
    func emptyReadPolicy() {
        let card = PagerToolCard.make(
            name: "read_file",
            rawInput: waveCJSON(["file_path": "empty.txt"]),
            output: "",
            state: .succeeded,
            structuredOutput: waveCJSON([
                "type": "file_content",
                "path": "empty.txt",
                "content": "",
                "total_lines": 0,
                "start_line": 1,
                "end_line": 0,
                "truncated": false,
            ])
        )
        #expect(waveCText(card).contains("(empty)"))
        #expect(!card.isFoldableByKind)
    }

    @Test("list shows singular count and expands the full listing")
    func listFullExpansion() {
        let card = PagerToolCard.make(
            name: "list_dir",
            rawInput: waveCJSON(["target_directory": "/workspace/src"]),
            output: "/workspace/src/\n  App.swift",
            state: .succeeded,
            isExpanded: true,
            structuredOutput: waveCJSON([
                "type": "list_dir",
                "path": "/workspace/src",
                "content": "/workspace/src/\n  App.swift",
                "entry_count": 1,
                "truncated": false,
            ])
        )
        let text = waveCText(card)
        #expect(text.contains("List /workspace/src (1 entry)"))
        #expect(text.contains("App.swift"))
        #expect(!text.contains("… +"))
        #expect(waveCLines(card).allSatisfy { $0.accentGlyph == nil })
    }

    @Test("search groups matches, shows metadata, and keeps zero results foldable")
    func searchGroupingAndPolicies() {
        let matches: [[String: Any]] = [
            ["path": "/w/a.swift", "line_number": 2, "text": "let needle = 1"],
            ["path": "/w/a.swift", "line_number": 9, "text": "needle()"],
            ["path": "/w/b.swift", "line_number": 4, "text": "// needle"],
        ]
        let card = PagerToolCard.make(
            name: "grep",
            rawInput: waveCJSON([
                "pattern": "needle",
                "path": "/w",
                "glob": "*.swift",
                "case_insensitive": true,
                "multiline": true,
            ]),
            state: .succeeded,
            isExpanded: true,
            structuredOutput: waveCJSON([
                "type": "grep",
                "pattern": "needle",
                "path": "/w",
                "glob": "*.swift",
                "output_mode": "content",
                "match_count": 3,
                "file_count": 2,
                "case_insensitive": true,
                "multiline": true,
                "matches": matches,
            ])
        )
        let text = waveCText(card)
        #expect(text.contains("Search \"needle\" (3 matches in 2 files)"))
        #expect(text.contains("Path: /w"))
        #expect(text.contains("Glob: *.swift"))
        #expect(text.contains("Case insensitive"))
        #expect(text.contains("Multiline"))
        #expect(text.contains("/w/a.swift"))
        #expect(text.contains("/w/b.swift"))
        #expect(waveCHeaderSelection(card) == "needle")

        let empty = PagerToolCard.make(
            name: "grep",
            rawInput: waveCJSON(["pattern": "missing"]),
            state: .succeeded,
            structuredOutput: waveCJSON([
                "type": "grep",
                "pattern": "missing",
                "output_mode": "content",
                "match_count": 0,
                "file_count": 0,
                "matches": [],
            ])
        )
        #expect(empty.isFoldableByKind)
    }

    @Test("glob and alternate grep modes parse as Search")
    func searchModes() throws {
        let glob = PagerToolCard.make(
            name: "glob",
            rawInput: waveCJSON(["pattern": "*.swift", "path": "/w"]),
            state: .succeeded,
            isExpanded: true,
            structuredOutput: waveCJSON([
                "type": "glob",
                "pattern": "*.swift",
                "path": "/w",
                "output_mode": "glob",
                "match_count": 2,
                "file_count": 2,
                "matches": [["path": "/w/a.swift"], ["path": "/w/b.swift"]],
            ])
        )
        #expect(glob.kind == .search)
        #expect(waveCText(glob).contains("Search *.swift (2 files)"))

        for mode in ["files_with_matches", "count"] {
            let card = PagerToolCard.make(
                name: "grep",
                rawInput: waveCJSON(["pattern": "x", "output_mode": mode]),
                state: .succeeded,
                isExpanded: true,
                structuredOutput: waveCJSON([
                    "type": "grep",
                    "pattern": "x",
                    "output_mode": mode,
                    "match_count": 3,
                    "file_count": 1,
                    "matches": [["path": "/w/a", "count": 3]],
                ])
            )
            let text = waveCText(card)
            #expect(text.contains(mode == "count" ? "Mode: Count" : "Mode: FilesWithMatches"))
        }
    }

    @Test("fetch paints metadata, ten-line cap, and URL-only selection")
    func fetchMetadataAndSelection() {
        let content = (1...14).map { "fetch line \($0)" }.joined(separator: "\n")
        let url = "https://example.com/really/long/path"
        let card = PagerToolCard.make(
            name: "web_fetch",
            rawInput: waveCJSON(["url": url]),
            output: content,
            state: .succeeded,
            isExpanded: true,
            structuredOutput: waveCJSON([
                "content": content,
                "final_url": url,
                "content_type": "text/markdown; charset=utf-8",
                "status_code": 200,
                "total_bytes": 14541,
                "truncated": false,
            ])
        )
        let text = waveCText(card, width: 44)
        #expect(text.contains("Fetch \(url)"))
        #expect(text.contains("200 · text/markdown · 14.2 KB"))
        #expect(text.contains("more lines, press Enter to view"))
        #expect(waveCHeaderSelection(card, width: 22) == url)
    }

    @Test("web search deduplicates sites and X search stays header-only")
    func webAndXSearch() {
        let query = "swift concurrency"
        let citations: [[String: Any]] = [
            ["title": "A", "url": "https://a.example/1"],
            ["title": "A2", "url": "https://a.example/2"],
            ["title": "B", "url": "https://b.example/1"],
            ["title": "C", "url": "https://c.example/1"],
            ["title": "D", "url": "https://d.example/1"],
        ]
        let web = PagerToolCard.make(
            name: "web_search",
            rawInput: waveCJSON(["query": query]),
            output: "result body",
            state: .succeeded,
            isExpanded: true,
            structuredOutput: waveCJSON(["content": "result body", "citations": citations])
        )
        let text = waveCText(web)
        #expect(text.contains("(4 sites)"))
        #expect(text.contains("Sources: a.example, b.example, c.example (+1 more)"))
        #expect(waveCHeaderSelection(web, width: 18) == query)

        let x = PagerToolCard.make(
            name: "x_search",
            rawInput: waveCJSON(["query": "latest posts"]),
            output: "should not paint",
            state: .succeeded,
            isExpanded: true
        )
        #expect(x.kind == .xSearch)
        #expect(waveCText(x).contains("X Search latest posts"))
        #expect(!waveCText(x).contains("should not paint"))
        #expect(!x.isFoldableByKind)
    }

    @Test("memory envelope renders numbered results and query-only selection")
    func memoryResults() throws {
        let output = """
        Found 2 memory result(s):

        ### Result 1 (score: 0.95, source: global)
        **File:** /memory/one.md (lines 10-12)
        ```
        first
        second
        third
        fourth
        ```

        ### Result 2 (score: 0.80, source: workspace)
        **File:** /memory/two.md (lines 2-3)
        ```
        another
        ```
        """
        let card = PagerToolCard.make(
            name: "memory_search",
            rawInput: waveCJSON(["query": "preferences"]),
            output: output,
            state: .succeeded,
            isExpanded: true,
            structuredOutput: waveCJSON(output)
        )
        let payload = try #require(card.waveCPayload)
        guard case .memorySearch(let memory) = payload else {
            Issue.record("expected memory payload")
            return
        }
        #expect(memory.results.count == 2)
        let text = waveCText(card)
        #expect(text.contains("Memory Search preferences (2 results)"))
        #expect(text.contains("1. /memory/one.md (lines 10-12)"))
        #expect(!text.contains("fourth"))
        #expect(waveCHeaderSelection(card, width: 20) == "preferences")
    }

    @Test("MCP search strips server prefixes and use_tool shows nested arguments")
    func mcpPainters() {
        let catalog = waveCJSON([
            "status": "ready",
            "results": [[
                "server": "linear",
                "tools": [
                    ["tool_name": "linear__save_issue", "description": "Save an issue"],
                    ["tool_name": "list_teams", "description": "List teams"],
                ],
            ]],
        ])
        let search = PagerToolCard.make(
            name: "search_tool",
            rawInput: waveCJSON(["query": "issues"]),
            output: catalog,
            state: .succeeded,
            isExpanded: true,
            structuredOutput: waveCJSON(["content": catalog])
        )
        let searchText = waveCText(search)
        #expect(searchText.contains("Search Tools issues (2 results)"))
        #expect(searchText.contains("Save Issue  linear"))
        #expect(searchText.contains("List Teams  linear"))
        #expect(waveCHeaderSelection(search, width: 20) == "issues")

        let use = PagerToolCard.make(
            name: "use_tool",
            rawInput: waveCJSON([
                "tool_name": "linear__save_issue",
                "tool_input": ["title": "Bug", "labels": ["p1", "ios"]],
            ]),
            output: "created LIN-42",
            state: .succeeded,
            isExpanded: true,
            structuredOutput: waveCJSON(["content": "created LIN-42"])
        )
        let useText = waveCText(use)
        #expect(useText.contains("Linear Save Issue"))
        #expect(useText.contains("title: Bug"))
        #expect(useText.contains("labels: [\"p1\",\"ios\"]"))
        #expect(useText.contains("created LIN-42"))
    }

    @Test("Other painter renders accepted, declined, and plan-mode question results")
    func otherQuestions() {
        let acceptedText = "User has answered your questions: \"Language?\"=\"Swift\", \"Platform?\"=\"iOS\". You can now continue with the user's answers in mind."
        let accepted = PagerToolCard.make(
            name: "ask_user_question",
            rawInput: waveCJSON(["questions": [["question": "Language?"]]]),
            output: acceptedText,
            state: .succeeded,
            isExpanded: true,
            structuredOutput: waveCJSON(["status": "answered", "message": acceptedText])
        )
        let acceptedRender = waveCText(accepted)
        #expect(acceptedRender.contains("1. Language?"))
        #expect(acceptedRender.contains("→ Swift"))
        #expect(acceptedRender.contains("2. Platform?"))

        let declinedText = "User declined to answer the questions. Continue with the task using your best judgment, or ask different questions."
        let declined = PagerToolCard.make(
            name: "ask_user_question",
            rawInput: waveCJSON(["questions": [["question": "Continue?"]]]),
            output: declinedText,
            state: .succeeded,
            isExpanded: true,
            structuredOutput: waveCJSON(["status": "cancelled", "message": declinedText])
        )
        #expect(waveCText(declined).contains("User declined to answer"))

        let plan = """
        Questions asked:
        - "Ship it?"
          Answer: Yes
        - "Add tests?"
          (No answer provided)
        """
        let planCard = PagerToolCard.make(
            name: "ask_user_question",
            rawInput: waveCJSON(["questions": [["question": "Ship it?"]]]),
            output: plan,
            state: .succeeded,
            isExpanded: true
        )
        let planRender = waveCText(planCard)
        #expect(planRender.contains("→ Yes"))
        #expect(planRender.contains("(no answer)"))
    }

    @Test("per-kind fold policy rejects failed list, empty generic, and empty searches where pinned")
    func foldPolicy() {
        let failedList = PagerToolCard(
            name: "list_dir",
            kind: .list,
            input: "missing",
            output: "not found",
            state: .failed
        )
        let emptyGeneric = PagerToolCard(name: "other", kind: .generic, input: "x", state: .succeeded)
        let emptyMemory = PagerToolCard(
            name: "memory_search",
            kind: .memorySearch,
            input: "x",
            state: .succeeded,
            waveCPayload: .memorySearch(PagerMemorySearchPayload(query: "x", results: []))
        )
        let zeroSearch = PagerToolCard(
            name: "grep",
            kind: .search,
            input: "x",
            state: .succeeded,
            waveCPayload: .search(PagerSearchPayload(pattern: "x"))
        )
        #expect(!failedList.isFoldableByKind)
        #expect(!emptyGeneric.isFoldableByKind)
        #expect(!emptyMemory.isFoldableByKind)
        #expect(zeroSearch.isFoldableByKind)
    }
}
