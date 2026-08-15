import Testing
@testable import OpenGrokPagerRender

@Suite("PagerToolKind factory")
struct PagerToolKindFactoryTests {

    @Test("name→kind table matches the pin from_name aliases")
    func nameToKindTable() {
        let cases: [(String, PagerToolKind)] = [
            ("run_terminal_cmd", .execute),
            ("run_terminal_command", .execute),
            ("bash", .execute),
            ("shell", .execute),
            ("execute", .execute),
            ("read_file", .read),
            ("read", .read),
            ("search_replace", .edit),
            ("strreplace", .edit),
            ("str_replace", .edit),
            ("apply_patch", .edit),
            ("hashline_edit", .edit),
            ("edit", .edit),
            ("write", .create),
            ("write_file", .create),
            ("list_dir", .list),
            ("ls", .list),
            ("grep", .search),
            ("search", .search),
            ("glob", .search),
            ("web_fetch", .fetch),
            ("fetch", .fetch),
            ("web_search", .webSearch),
            ("search_tool", .integrationSearch),
            ("use_tool", .useTool),
            ("memory_search", .memorySearch),
            ("skill", .skill),
            ("TodoWrite", .generic),
        ]
        for (name, expected) in cases {
            let kind = PagerToolKind.infer(fromToolNamed: name)
            #expect(kind == expected, "\(name) → \(kind), expected \(expected)")
        }
    }

    @Test("glob is search, not list")
    func globIsSearch() {
        #expect(PagerToolKind.infer(fromToolNamed: "glob") == .search)
        #expect(PagerToolKind.infer(fromToolNamed: "GLOB") == .search)
    }

    @Test("write is create (Creating header family)")
    func writeIsCreate() {
        #expect(PagerToolKind.infer(fromToolNamed: "write") == .create)
        #expect(PagerToolKind.create.headerVerb == "Creating")
        let card = PagerToolCard.make(
            name: "write",
            rawInput: #"{"file_path":"/tmp/a.txt","contents":"hi"}"#
        )
        #expect(card.kind == .create)
        #expect(card.input == "/tmp/a.txt")
    }

    @Test("search_replace is edit with path header, not raw JSON")
    func searchReplaceIsEdit() {
        let card = PagerToolCard.make(
            name: "search_replace",
            rawInput: #"{"file_path":"Sources/Foo.swift","old_string":"a","new_string":"b"}"#
        )
        #expect(card.kind == .edit)
        #expect(card.input == "Sources/Foo.swift")
        #expect(card.headerText == "Sources/Foo.swift")
        #expect(card.rawInput.contains("file_path"))
        #expect(!card.input.contains("{"))
    }

    @Test("run_terminal_cmd is execute")
    func runTerminalCmdIsExecute() {
        let card = PagerToolCard.make(
            name: "run_terminal_cmd",
            rawInput: #"{"command":"ls -la"}"#
        )
        #expect(card.kind == .execute)
        #expect(card.input == "ls -la")
    }

    @Test("JSON {command,description} header prefers description, not JSON")
    func descriptionPreferredOverCommand() {
        let card = PagerToolCard.make(
            name: "bash",
            rawInput: #"{"command":"git status","description":"Check git status"}"#
        )
        #expect(card.kind == .execute)
        #expect(card.input == "Check git status")
        #expect(card.headerText == "Check git status")
        #expect(card.rawInput.contains("git status"))
        #expect(!card.input.contains("{"))
        #expect(!card.input.contains("command"))
    }

    @Test("cwd peel strips displayed cd <cwd> && from the header only")
    func cwdPeelFromHeaderOnly() {
        let cwd = "/Users/me/proj"
        // Command form; peel for display only.
        let card = PagerToolCard.make(
            name: "run_terminal_command",
            rawInput: #"{"command":"cd /Users/me/proj && cargo test"}"#,
            cwd: cwd
        )
        #expect(card.kind == .execute)
        #expect(card.input == "cargo test")
        #expect(card.rawInput.contains("cd /Users/me/proj && cargo test"))
        #expect(card.rawInput != card.input)

        // Description wins; peel is not applied to the description string.
        let withDesc = PagerToolCard.make(
            name: "bash",
            rawInput: #"{"command":"cd /Users/me/proj && cargo test","description":"Run tests"}"#,
            cwd: cwd
        )
        #expect(withDesc.input == "Run tests")
    }

    @Test("path extract from file_path / target_file / path, with cwd elision")
    func pathExtractAndCwdElision() {
        let cwd = "/Users/me/proj"

        let byFilePath = PagerToolCard.make(
            name: "read_file",
            rawInput: #"{"file_path":"/Users/me/proj/Sources/A.swift"}"#,
            cwd: cwd
        )
        #expect(byFilePath.kind == .read)
        #expect(byFilePath.input == "Sources/A.swift")

        let byTarget = PagerToolCard.make(
            name: "read_file",
            rawInput: #"{"target_file":"/Users/me/proj/B.swift"}"#,
            cwd: cwd
        )
        #expect(byTarget.input == "B.swift")

        let byPath = PagerToolCard.make(
            name: "apply_patch",
            rawInput: #"{"path":"/Users/me/proj/C.swift"}"#,
            cwd: cwd
        )
        #expect(byPath.kind == .edit)
        #expect(byPath.input == "C.swift")

        let outside = PagerToolCard.make(
            name: "read",
            rawInput: #"{"file_path":"/tmp/other.swift"}"#,
            cwd: cwd
        )
        #expect(outside.input == "/tmp/other.swift")
    }

    @Test("new specialized kinds get distinct header verbs")
    func specializedKindHeaderVerbs() {
        #expect(PagerToolKind.memorySearch.headerVerb == "Memory Search")
        #expect(PagerToolKind.integrationSearch.headerVerb == "Search Tools")
        #expect(PagerToolKind.skill.headerVerb == "Skill")
        #expect(PagerToolKind.useTool.headerVerb == nil)

        let mem = PagerToolCard.make(
            name: "memory_search",
            rawInput: #"{"query":"auth middleware"}"#
        )
        #expect(mem.kind == .memorySearch)
        #expect(mem.input == "auth middleware")

        let tools = PagerToolCard.make(
            name: "search_tool",
            rawInput: #"{"query":"linear create"}"#
        )
        #expect(tools.kind == .integrationSearch)
        #expect(tools.input == "linear create")

        let use = PagerToolCard.make(
            name: "use_tool",
            rawInput: #"{"tool_name":"linear__save_issue"}"#
        )
        #expect(use.kind == .useTool)
        #expect(use.input == "linear__save_issue")
    }

    @Test("minimal classify maps new kinds to other without trapping")
    func minimalClassifyNewKinds() {
        for kind: PagerToolKind in [.memorySearch, .integrationSearch, .useTool, .skill] {
            let block = MinimalTranscript.classify(
                .tool(PagerToolCard(name: "t", kind: kind, state: .succeeded))
            )
            #expect(block == .toolCall(kind: .other("t"), error: nil), "\(kind)")
        }
    }
}
