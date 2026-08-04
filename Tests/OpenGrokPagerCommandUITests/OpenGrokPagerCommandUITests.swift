import Testing
@testable import OpenGrokPagerCommandUI

struct PagerCommandParserTests {
    @Test("parser preserves quoted and escaped arguments")
    func parsesArguments() {
        let result = PagerCommandParser.parse(#"/model "grok 4" --fast\ --json"#)

        guard case .command(let invocation) = result else {
            Issue.record("expected a command invocation")
            return
        }
        #expect(invocation.name == "model")
        #expect(invocation.arguments == ["grok 4", "--fast --json"])
    }

    @Test("parser distinguishes prompts and malformed slash commands")
    func parsesPromptAndErrors() {
        guard case .prompt("hello") = PagerCommandParser.parse("hello") else {
            Issue.record("expected prompt")
            return
        }
        guard case .invalid(.unterminatedQuote) = PagerCommandParser.parse(#"/model "grok"#) else {
            Issue.record("expected unterminated quote")
            return
        }
    }
}

struct PagerCommandRegistryTests {
    private let registry = PagerCommandRegistry(commands: [
        PagerCommandDefinition(name: "model", aliases: ["m"], summary: "Choose a model"),
        PagerCommandDefinition(name: "memory", summary: "Search memory", availability: .unavailable(reason: "not configured")),
        PagerCommandDefinition(name: "help", summary: "Show help")
    ])

    @Test("completion is sorted and includes unavailable state")
    func completesCommands() {
        let completions = registry.completions(for: "/m")

        #expect(completions.map(\.commandName) == ["memory", "model"])
        #expect(completions[0].availability.isAvailable == false)
        #expect(completions[1].matchedAlias == nil)
    }

    @Test("autocomplete selection wraps and accepts the canonical command")
    func selectsCompletion() {
        var state = registry.autocompleteState(for: "/m")
        state.moveSelection(by: -1)
        #expect(state.selectedSuggestion?.commandName == "model")
        #expect(state.acceptSelected() == "/model")
        #expect(state.renderDescription().height == 0)
    }

    @Test("resolution keeps unavailable commands explicit")
    func resolvesAvailability() {
        let result = registry.resolve(PagerCommandInvocation(name: "memory"))

        guard case .unavailable(let command, let reason) = result else {
            Issue.record("expected unavailable resolution")
            return
        }
        #expect(command.name == "memory")
        #expect(reason == "not configured")
    }
}
