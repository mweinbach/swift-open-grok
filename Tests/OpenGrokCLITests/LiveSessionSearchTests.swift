// LiveSessionSearchTests.swift
//
// Covers session content search, resume-by-title, memory injection, and the
// `update_goal` registration.
//
// The common thread is reachability: each of these subsystems already had a
// tested implementation and no caller, so the assertions that matter are the
// ones about the seam — does a query reach the ranker, does a title reach a
// session id, does a memory block reach the system prompt, and is `update_goal`
// actually in the advertised tool list when the prompt text tells the model to
// call it.

import Foundation
import OpenGrokConfig
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokToolsAPI
import Testing
@testable import OpenGrokCLI

// MARK: - Memory workspace

/// Non-ephemeral scratch workspace for memory reachability tests.
private struct LiveMemoryTestWorkspace {
    let root: URL
    let grokHome: URL
    var environment: [String: String]

    static func make(memoryEnabled: Bool = false) -> LiveMemoryTestWorkspace {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let canonical = packageRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let isTempPackage = canonical.hasPrefix("/tmp/")
            || canonical.hasPrefix("/private/tmp/")
            || canonical.hasPrefix("/var/tmp/")
        let scratchParent: URL
        if isTempPackage {
            scratchParent = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".opengrok-test-scratch", isDirectory: true)
                .appendingPathComponent("cli-memory-gate", isDirectory: true)
        } else {
            scratchParent = packageRoot
                .appendingPathComponent(".build", isDirectory: true)
                .appendingPathComponent("cli-memory-gate", isDirectory: true)
        }
        let base = scratchParent
            .appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        let root = base.appendingPathComponent("repo")
        let home = base.appendingPathComponent("home")
        let grokHome = home.appendingPathComponent(".opengrok")
        for directory in [root, home, grokHome] {
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        }
        var environment = [
            "HOME": home.path,
            "OPENGROK_HOME": grokHome.path,
        ]
        if memoryEnabled {
            environment["OPENGROK_MEMORY"] = "1"
        }
        return LiveMemoryTestWorkspace(root: root, grokHome: grokHome, environment: environment)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }
}

// MARK: - Fixtures

private func record(
    id: String,
    cwd: String = "/repo",
    prompts: [String],
    replies: [String] = [],
    updatedAt: Date = Date()
) -> LiveConversationRecord {
    var items: [ConversationItem] = []
    for (index, prompt) in prompts.enumerated() {
        items.append(.user(prompt))
        if index < replies.count {
            items.append(.assistant(AssistantItem(content: replies[index])))
        }
    }
    return LiveConversationRecord(
        sessionID: id,
        workingDirectory: cwd,
        parentSessionID: nil,
        createdAt: updatedAt,
        updatedAt: updatedAt,
        items: items
    )
}

// MARK: - Search

@Test("search finds a session by a word that appears only in the assistant reply")
func searchMatchesAssistantContent() {
    let documents = [
        record(
            id: "a",
            prompts: ["how do I set this up"],
            replies: ["You need to configure the mercurial bridge first."]
        ),
        record(id: "b", prompts: ["unrelated question"], replies: ["unrelated answer"]),
    ].map(LiveSessionDocument.build(from:))

    let hits = LiveSessionSearch.rank(documents: documents, query: "mercurial", limit: 10)
    #expect(hits.map(\.sessionID) == ["a"])
    // The snippet is what makes a hit list usable rather than a wall of ids.
    #expect(hits[0].snippet.lowercased().contains("mercurial"))
}

@Test("a title match outranks a body match")
func searchWeightsTitleAboveContent() {
    let documents = [
        record(id: "body", prompts: ["something else"], replies: ["deployment deployment deployment"]),
        record(id: "title", prompts: ["deployment checklist"], replies: ["sure"]),
    ].map(LiveSessionDocument.build(from:))

    let hits = LiveSessionSearch.rank(documents: documents, query: "deployment", limit: 10)
    // Rust weights the title field 10× in its bm25 call; the port has to agree
    // or the picker surfaces the wrong session first.
    #expect(hits.first?.sessionID == "title")
}

@Test("a multi-word query requires every word, then falls back to any")
func searchAndThenOr() {
    let documents = [
        record(id: "both", prompts: ["fix the parser and the lexer"]),
        record(id: "one", prompts: ["fix the parser"]),
    ].map(LiveSessionDocument.build(from:))

    #expect(
        LiveSessionSearch.rank(documents: documents, query: "parser lexer", limit: 10)
            .map(\.sessionID) == ["both"]
    )
    // Nothing contains both words, so the OR pass runs and returns what it can
    // rather than reporting no results.
    let fallback = LiveSessionSearch.rank(
        documents: documents,
        query: "parser tokenizer",
        limit: 10
    )
    #expect(Set(fallback.map(\.sessionID)) == ["both", "one"])
}

@Test("plural queries match their singular stem, but short and identifier-like tokens stay exact")
func searchStemming() {
    #expect(LiveSessionSearchQuery.stem("sessions") == "session")
    // Too short to stem.
    #expect(LiveSessionSearchQuery.stem("has") == "has")
    // `ss` ending: stemming would turn `pass` into `pas`.
    #expect(LiveSessionSearchQuery.stem("pass") == "pass")
    // Identifier-shaped: `--flags` should not become `--flag`.
    #expect(LiveSessionSearchQuery.stem("some_ids") == "some_ids")
}

@Test("an empty or punctuation-only query returns nothing rather than everything")
func searchEmptyQuery() {
    let documents = [record(id: "a", prompts: ["hello"])].map(LiveSessionDocument.build(from:))
    #expect(LiveSessionSearch.rank(documents: documents, query: "", limit: 10).isEmpty)
    #expect(LiveSessionSearch.rank(documents: documents, query: "!!! ???", limit: 10).isEmpty)
}

// MARK: - Resume by title

@Test("a UUID argument always resolves as an id, never as a title")
func resumeUUIDShortCircuit() {
    let uuid = UUID().uuidString
    #expect(LiveSessionTitleResolver.looksLikeSessionID(uuid))
    #expect(!LiveSessionTitleResolver.looksLikeSessionID("deployment checklist"))
}

@Test("a unique title resolves to its session id, scoped to the working directory")
func resumeByTitle() throws {
    let listings = [
        LiveSessionCatalog.listing(for: record(id: "a", cwd: "/repo", prompts: ["Fix the parser"])),
        LiveSessionCatalog.listing(for: record(id: "b", cwd: "/other", prompts: ["Fix the parser"])),
    ]
    let resolved = try LiveSessionTitleResolver.resolve(
        value: "fix the parser",
        in: listings,
        workingDirectory: URL(fileURLWithPath: "/repo")
    )
    // Case-insensitive, and the same title in another directory is not a
    // candidate — sessions are scoped by cwd.
    #expect(resolved == "a")
}

@Test("an ambiguous title errors instead of guessing")
func resumeAmbiguousTitle() {
    let listings = [
        LiveSessionCatalog.listing(for: record(id: "a", cwd: "/repo", prompts: ["Fix the parser"])),
        LiveSessionCatalog.listing(for: record(id: "b", cwd: "/repo", prompts: ["Fix the parser"])),
    ]
    #expect(throws: LiveSessionResolveFailure.self) {
        _ = try LiveSessionTitleResolver.resolve(
            value: "Fix the parser",
            in: listings,
            workingDirectory: URL(fileURLWithPath: "/repo")
        )
    }
}

@Test("a miss points at the command that would find it")
func resumeMissHint() {
    let failure = LiveSessionResolveFailure.noMatch("parser")
    #expect(failure.description.contains("sessions search"))
}

// MARK: - Memory injection

@Test("a short or greeting prompt falls back to the generic injection query")
func memoryInjectionQueryFallback() {
    #expect(LiveMemoryInjection.query(forPrompt: "hi") == LiveMemoryInjection.fallbackQuery)
    #expect(LiveMemoryInjection.query(forPrompt: "continue.") == LiveMemoryInjection.fallbackQuery)
    // Under 20 characters is treated as too thin to search with.
    #expect(LiveMemoryInjection.query(forPrompt: "fix it") == LiveMemoryInjection.fallbackQuery)

    let real = "please refactor the session store to use an append-only log"
    #expect(LiveMemoryInjection.query(forPrompt: real) == real)
}

@Test("injection splices into the system item and replaces an existing block in place")
func memoryInjectionIsIdempotent() {
    let items: [ConversationItem] = [
        .system("base prompt"),
        .user("hello"),
    ]
    let first = LiveMemoryInjection.inject("<memory-context>\nA\n</memory-context>", into: items)
    #expect(first.count == 2)
    #expect(LiveMemoryInjection.alreadyInjected(first))

    // A second injection must replace, not stack: otherwise every resume grows
    // the system prompt and breaks the prompt cache.
    let second = LiveMemoryInjection.inject("<memory-context>\nB\n</memory-context>", into: first)
    guard case .system(let system) = second[0] else {
        Issue.record("expected a system item")
        return
    }
    #expect(system.content.contains("B"))
    #expect(!system.content.contains("\nA\n"))
    #expect(system.content.contains("base prompt"))
}

@Test("injection creates a system item when the conversation has none")
func memoryInjectionWithoutSystemItem() {
    let injected = LiveMemoryInjection.inject(
        "<memory-context>\nA\n</memory-context>",
        into: [.user("hello")]
    )
    #expect(injected.count == 2)
    if case .system = injected[0] {} else {
        Issue.record("expected the injected block to become a leading system item")
    }
}

@Test("memory is off unless config or the environment turns it on")
func memoryConfigurationGate() {
    let empty = LiveMemoryConfiguration.resolve(
        document: .table(TOMLTable()),
        environment: [:]
    )
    #expect(!empty.enabled)

    let viaEnvironment = LiveMemoryConfiguration.resolve(
        document: .table(TOMLTable()),
        environment: ["OPENGROK_MEMORY": "1"]
    )
    #expect(viaEnvironment.enabled)
    // The knobs the audit called out as parsed-but-ignored now have a reader.
    #expect(viaEnvironment.search.maxResults == 6)
    #expect(viaEnvironment.initialInjection.enabled)
}

@Test("memory tool specs are empty when memory is disabled")
func memoryToolSpecsAbsentWhenDisabled() {
    #expect(LiveMemoryTools.toolSpecs(configuration: .disabled).isEmpty)
    #expect(LiveMemoryTools.advertisedToolNames(configuration: .disabled).isEmpty)
}

@Test("makeSessionServices omits memory tools when memory is off")
func memoryToolsNotAdvertisedWhenDisabled() async {
    let base = LiveMemoryTestWorkspace.make()
    defer { base.cleanup() }

    let services = await OpenGrokLiveApplicationLauncher.makeSessionServices(
        sessionID: "live-session",
        workingDirectory: base.root,
        openGrokHome: base.grokHome,
        conversationRecord: LiveConversationRecord.new(
            sessionID: "live-session",
            workingDirectory: base.root
        ),
        environment: base.environment
    )
    #expect(services.memory == nil)
    let names = Set(services.toolSpecs.map(\.name))
    #expect(!names.contains(LiveMemoryTools.searchToolName))
    #expect(!names.contains(LiveMemoryTools.getToolName))
}

@Test("makeSessionServices advertises memory tools when memory is on")
func memoryToolsAdvertisedWhenEnabled() async {
    let base = LiveMemoryTestWorkspace.make(memoryEnabled: true)
    defer { base.cleanup() }

    let services = await OpenGrokLiveApplicationLauncher.makeSessionServices(
        sessionID: "live-session",
        workingDirectory: base.root,
        openGrokHome: base.grokHome,
        conversationRecord: LiveConversationRecord.new(
            sessionID: "live-session",
            workingDirectory: base.root
        ),
        environment: base.environment
    )
    #expect(services.memory != nil)
    let names = Set(services.toolSpecs.map(\.name))
    #expect(names.contains(LiveMemoryTools.searchToolName))
    #expect(names.contains(LiveMemoryTools.getToolName))
}

@Test("/remember, /recall, and /flush surface notices when memory is disabled")
func memorySlashCommandsWhenDisabled() async {
    let remember = await LiveMemoryCommands.remember("note", backend: nil)
    #expect(remember.contains("Memory is not enabled"))

    let recall = await LiveMemoryCommands.recall("query", backend: nil)
    #expect(recall.contains("Memory is not enabled"))

    let flush = await LiveMemoryCommands.flush(
        "session notes",
        sessionID: "live-session",
        backend: nil
    )
    #expect(flush.contains("Memory is not enabled"))
}

@Test("a disabled memory backend answers the tool without pretending to search")
func memoryToolWhenDisabled() async {
    let output = await LiveMemoryTools.invoke(
        name: LiveMemoryTools.searchToolName,
        arguments: .object(["query": .string("anything")]),
        backend: nil
    )
    #expect(output.contains("Memory is not enabled"))
}

// MARK: - Goals

@Test("update_goal is advertised only while a goal is active")
func goalToolAdvertisedOnlyWhenActive() {
    #expect(LiveGoalTools.toolSpecs(goalIsActive: false).isEmpty)
    let active = LiveGoalTools.toolSpecs(goalIsActive: true)
    #expect(active.map(\.name) == [LiveGoalTools.toolName])
}

@Test("the registered tool name matches the name the prompt text tells the model to call")
func goalToolNameMatchesPromptText() {
    // This is the dangling reference the audit found: `goalInstruction` names
    // `update_goal` in text handed to the model, and nothing registered a tool
    // by that name. If these two ever drift apart, the model is being told to
    // call something that does not exist.
    #expect(LiveGoalTools.toolName == "update_goal")
    #expect(goalInstruction("ship it").contains(LiveGoalTools.toolName))
}

@Test("a blocked report is not applied until the third consecutive attempt")
func goalBlockedStreak() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("w8-goal-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let coordinator = LiveGoalCoordinator(sessionDirectory: directory)
    await coordinator.createGoal(objective: "port the session store")
    #expect(await coordinator.isActive)

    let arguments = JSONValue.object(["blocked_reason": .string("cannot reach the API")])
    let first = await LiveGoalTools.invoke(arguments: arguments, coordinator: coordinator)
    #expect(first.contains("1/3"))
    let second = await LiveGoalTools.invoke(arguments: arguments, coordinator: coordinator)
    #expect(second.contains("2/3"))
    // Only the third consecutive block actually pauses the goal.
    let third = await LiveGoalTools.invoke(arguments: arguments, coordinator: coordinator)
    #expect(third.contains("Goal blocked"))
    #expect(!(await coordinator.isActive))
}

@Test("a loose boolean still reads as a completion claim")
func goalAcceptsLooseCompleted() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("w8-goal-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let coordinator = LiveGoalCoordinator(sessionDirectory: directory)
    await coordinator.createGoal(objective: "port the session store")
    // A model that emits `"true"` instead of `true` must not have its
    // completion silently read as a progress note.
    let output = await LiveGoalTools.invoke(
        arguments: .object([
            "completed": .string("true"),
            "message": .string("done"),
        ]),
        coordinator: coordinator
    )
    #expect(output.contains("complete"))
    #expect(!(await coordinator.isActive))
}
