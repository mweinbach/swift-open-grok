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

    @Test("completion ranks fuzzily and includes unavailable state")
    func completesCommands() {
        let completions = registry.completions(for: "/m")

        // `m` scores identically against `memory`, `model`, and the alias
        // `m`; ties fall to the MATCHED trigger's display text — upstream's
        // `rows[..].display.cmp` (`slash/mod.rs:1003`) compares the
        // "/{alias-or-canonical}" string (`registry.rs:76`), so model's
        // alias row "/m" sorts before "/memory". (An earlier port compared
        // canonical names here, which inverted this order and ranked
        // `/docs` above `/help` on `/h` once docs gained its `howto`
        // alias.)
        #expect(completions.map(\.commandName) == ["model", "memory"])
        // At equal score the exact alias trigger wins the per-command dedupe
        // (`slash/mod.rs:934-940`), so the model row records the alias hit.
        #expect(completions[0].matchedAlias == "m")
        #expect(completions[1].availability.isAvailable == false)
    }

    @Test("autocomplete selection wraps and accepts the canonical command")
    func selectsCompletion() {
        // The alias-matched model row ranks first; accepting inserts the
        // CANONICAL name, not the alias (the port's recorded divergence —
        // upstream inserts the alias display text).
        var state = registry.autocompleteState(for: "/m")
        #expect(state.selectedSuggestion?.commandName == "model")
        #expect(state.acceptSelected() == "/model")
        #expect(state.renderDescription().height == 0)

        // Wrapping backwards from the first row lands on the last —
        // memory, which is unavailable, so accepting it refuses (nil).
        var wrapped = registry.autocompleteState(for: "/m")
        wrapped.moveSelection(by: -1)
        #expect(wrapped.selectedSuggestion?.commandName == "memory")
        #expect(wrapped.acceptSelected() == nil)
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
