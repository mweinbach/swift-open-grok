import Foundation
import OpenGrokPagerMinimal
import OpenGrokPagerRender
import OpenGrokShell
import Testing
@testable import OpenGrokCLI

@Suite("Wave C live painter reachability")
struct WaveCLivePainterReachabilityTests {
    @Test("live read and list updates retain typed payloads")
    func readAndListPayloads() {
        var state = LivePagerConversationState()
        state.startTurn(prompt: "inspect")
        state.apply(OpenGrokPagerToolUpdate(
            callID: "read-1",
            name: "read_file",
            input: #"{"file_path":"/tmp/a.swift"}"#,
            output: "1→let value = 1",
            structuredOutput: #"{"type":"file_content","path":"/tmp/a.swift","content":"1→let value = 1","total_lines":1,"start_line":1,"end_line":1,"truncated":false}"#,
            state: .succeeded
        ))
        state.apply(OpenGrokPagerToolUpdate(
            callID: "list-1",
            name: "list_dir",
            input: #"{"target_directory":"/tmp"}"#,
            output: "/tmp/\n  a.swift",
            structuredOutput: #"{"type":"list_dir","path":"/tmp","content":"/tmp/\n  a.swift","entry_count":1,"truncated":false}"#,
            state: .succeeded
        ))

        guard let readPayload = state.testingToolCard(callID: "read-1")?.waveCPayload,
              case .read(let read) = readPayload,
              let listPayload = state.testingToolCard(callID: "list-1")?.waveCPayload,
              case .list(let list) = listPayload
        else {
            Issue.record("typed read/list payloads did not reach pager state")
            return
        }
        #expect(read.content == "let value = 1")
        #expect(list.entryCount == 1)
        #expect(list.content == "a.swift")
    }

    @Test("live grep and glob updates carry grouped mode metadata")
    func searchPayloads() {
        var state = LivePagerConversationState()
        state.startTurn(prompt: "search")
        state.apply(OpenGrokPagerToolUpdate(
            callID: "grep-1",
            name: "grep",
            input: #"{"pattern":"needle","path":"/tmp","output_mode":"count"}"#,
            output: "/tmp/a.swift:3",
            structuredOutput: #"{"type":"grep","pattern":"needle","path":"/tmp","output_mode":"count","match_count":3,"file_count":1,"case_insensitive":false,"multiline":false,"truncated":false,"matches":[{"path":"/tmp/a.swift","count":3}]}"#,
            state: .succeeded
        ))
        state.apply(OpenGrokPagerToolUpdate(
            callID: "glob-1",
            name: "glob",
            input: #"{"pattern":"*.swift","path":"/tmp"}"#,
            output: "/tmp/a.swift",
            structuredOutput: #"{"type":"glob","pattern":"*.swift","path":"/tmp","output_mode":"glob","match_count":1,"file_count":1,"truncated":false,"matches":[{"path":"/tmp/a.swift"}]}"#,
            state: .succeeded
        ))

        guard let grepPayload = state.testingToolCard(callID: "grep-1")?.waveCPayload,
              case .search(let grep) = grepPayload,
              let globCard = state.testingToolCard(callID: "glob-1"),
              let globPayload = globCard.waveCPayload,
              case .search(let glob) = globPayload
        else {
            Issue.record("typed search payloads did not reach pager state")
            return
        }
        #expect(grep.mode == .count)
        #expect(grep.matches.first?.text == "3")
        #expect(globCard.kind == .search)
        #expect(glob.mode == .glob)
    }

    @Test("live web and X search keep distinct kinds and citation payloads")
    func webPayloads() {
        var state = LivePagerConversationState()
        state.startTurn(prompt: "web")
        state.apply(OpenGrokPagerToolUpdate(
            callID: "web-1",
            name: "web_search",
            input: #"{"query":"swift"}"#,
            output: "results",
            structuredOutput: #"{"content":"results","citations":[{"title":"A","url":"https://example.com/a"}]}"#,
            state: .succeeded
        ))
        state.apply(OpenGrokPagerToolUpdate(
            callID: "x-1",
            name: "x_search",
            input: #"{"query":"swift posts"}"#,
            state: .succeeded
        ))

        guard let webPayload = state.testingToolCard(callID: "web-1")?.waveCPayload,
              case .webSearch(let web) = webPayload
        else {
            Issue.record("typed web payload did not reach pager state")
            return
        }
        #expect(web.citations.count == 1)
        #expect(state.testingToolCard(callID: "x-1")?.kind == .xSearch)
        #expect(state.testingToolCard(callID: "x-1")?.isFoldableByKind == false)
    }

    @Test("live memory and MCP envelopes parse at the pager boundary")
    func memoryAndMCPPayloads() {
        let memory = """
        Found 1 memory result(s):

        ### Result 1 (score: 0.90, source: global)
        **File:** /memory/a.md (lines 1-2)
        ```
        remembered
        ```
        """
        let catalog = #"{"status":"ready","results":[{"server":"linear","tools":[{"tool_name":"linear__save_issue","description":"Save"}]}]}"#
        var state = LivePagerConversationState()
        state.startTurn(prompt: "tools")
        state.apply(OpenGrokPagerToolUpdate(
            callID: "memory-1",
            name: "memory_search",
            input: #"{"query":"prefs"}"#,
            output: memory,
            structuredOutput: try! JSONEncoder().encode(memory).withString,
            state: .succeeded
        ))
        state.apply(OpenGrokPagerToolUpdate(
            callID: "search-tool-1",
            name: "search_tool",
            input: #"{"query":"issues"}"#,
            output: catalog,
            structuredOutput: #"{"content":"{\"status\":\"ready\",\"results\":[{\"server\":\"linear\",\"tools\":[{\"tool_name\":\"linear__save_issue\",\"description\":\"Save\"}]}]}"}"#,
            state: .succeeded
        ))
        state.apply(OpenGrokPagerToolUpdate(
            callID: "use-tool-1",
            name: "use_tool",
            input: #"{"tool_name":"linear__save_issue","tool_input":{"title":"Bug"}}"#,
            output: "LIN-1",
            structuredOutput: #"{"content":"LIN-1"}"#,
            state: .succeeded
        ))

        guard let memoryPayload = state.testingToolCard(callID: "memory-1")?.waveCPayload,
              case .memorySearch(let parsedMemory) = memoryPayload,
              let searchPayload = state.testingToolCard(callID: "search-tool-1")?.waveCPayload,
              case .integrationSearch(let parsedSearch) = searchPayload,
              let usePayload = state.testingToolCard(callID: "use-tool-1")?.waveCPayload,
              case .useTool(let parsedUse) = usePayload
        else {
            Issue.record("memory/MCP payloads did not reach pager state")
            return
        }
        #expect(parsedMemory.results.count == 1)
        #expect(parsedSearch.results.first?.toolName == "linear__save_issue")
        #expect(parsedUse.arguments.first?.key == "title")
    }

    @Test("live fold helper respects per-kind foldability")
    func foldGuard() {
        var items: [PagerConversationItem] = [
            .tool(PagerToolCard(
                name: "read_file",
                kind: .read,
                input: "empty.txt",
                output: "",
                state: .succeeded,
                waveCPayload: .read(PagerReadPayload(path: "empty.txt", content: ""))
            )),
            .tool(PagerToolCard(
                name: "grep",
                kind: .search,
                input: "missing",
                state: .succeeded,
                waveCPayload: .search(PagerSearchPayload(pattern: "missing"))
            )),
        ]
        LiveScrollbackSelection.toggleFold(at: 0, items: &items)
        LiveScrollbackSelection.toggleFold(at: 1, items: &items)
        #expect(items[0].isFolded)
        #expect(!items[1].isFolded)
    }
}

private extension Data {
    var withString: String { String(data: self, encoding: .utf8)! }
}
