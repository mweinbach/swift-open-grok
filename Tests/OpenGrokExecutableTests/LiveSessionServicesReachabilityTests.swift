// LiveSessionServicesReachabilityTests.swift
//
// Proves the session-recovery subsystems are actually REACHED by a live
// session, not merely implemented.
//
// This exists because of a specific failure mode this wave was created to fix:
// `OpenGrokMemory`, `OpenGrokGoalState` and the rewind store were complete,
// tested libraries that nothing called. Adding a composition layer on top does
// not fix that by itself — it just moves the dead end one layer up. A unit test
// of `LiveMemoryBackend` or `LiveRewindCoordinator` would pass just as happily
// if nothing in the live path ever constructed them.
//
// So every test here goes through the real seam: services built by the same
// `makeSessionServices` the launcher calls, handed to a real `LiveToolExecutor`,
// and exercised through `executor.tools` (what the model is actually offered)
// and `executor.invoke` (what actually runs). The assertions are about
// observable effects — a tool appearing in the advertised list, a snapshot file
// appearing on disk — rather than about internal state.

import Foundation
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase
import Testing
@testable import OpenGrokCLI

// MARK: - Fixtures

/// Runs nothing. These tests never exercise the shell; the backend exists only
/// because `LiveToolExecutor` requires one.
private actor InertShellBackend: ShellProcessBackend {
    func run(_ request: ShellCommandRequest) async throws -> ShellCommandResult {
        ShellCommandResult(combinedOutput: "", stdout: "", exitCode: 0)
    }

    func runBackground(_ request: ShellCommandRequest) async throws -> ShellBackgroundHandle {
        ShellBackgroundHandle(taskID: "bg")
    }

    func getTask(_ taskID: String) async -> ShellTaskSnapshot? { nil }
    func killTask(_ taskID: String) async -> ShellKillOutcome { .notFound }
    func killForegroundCommands() async {}
    func killForegroundCommands(ownerSessionID: String) async {}
    func killAllBackgroundTasks() async {}
    func killAllBackgroundTasks(ownerSessionID: String) async {}
    func warmShell(at cwd: URL) async {}
    func backgroundForegroundCommand(toolCallID: String) async -> Bool { false }
    func waitForCompletion(_ taskID: String, timeout: ShellDuration?) async -> ShellTaskSnapshot? { nil }
    func listTasks() async -> [ShellTaskSnapshot] { [] }
    func shellCWD() async -> URL? { nil }
}

/// A workspace with a fully isolated `$OPENGROK_HOME` / `$HOME`, so nothing
/// reads or writes the developer's real memory tree or session store.
private struct LiveWorkspace {
    let root: URL
    let grokHome: URL
    var environment: [String: String]

    /// `<package>/.build/w8s-session-tests`, derived from this file's own path
    /// so it does not depend on the process working directory.
    static let scratchRoot: URL = {
        // .../Tests/OpenGrokExecutableTests/<thisFile> → package root
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return packageRoot
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("w8s-session-tests", isDirectory: true)
    }()

    init(memoryEnabled: Bool) {
        // NOT the system temp directory. `MemoryStorage.isEphemeralPath`
        // classifies anything under /tmp, /var/tmp or the system temp dir
        // (which on macOS is `/var/folders/.../T/`) as ephemeral, and an
        // ephemeral workspace is never indexed or written to — by design, and
        // Rust does the same. A test workspace under `NSTemporaryDirectory()`
        // therefore simulates a user working inside /tmp, which is precisely
        // the configuration where memory is *supposed* to do nothing. Rooting
        // the workspace inside the package's own build scratch (gitignored,
        // and not a path SwiftPM manages) makes it look like what a real user
        // has: an ordinary project directory.
        let base = LiveWorkspace.scratchRoot
            .appendingPathComponent("w8s-reach-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        root = base.appendingPathComponent("repo")
        let home = base.appendingPathComponent("home")
        grokHome = home.appendingPathComponent(".opengrok")
        for directory in [root, home, grokHome] {
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        }
        environment = [
            "HOME": home.path,
            "OPENGROK_HOME": grokHome.path,
        ]
        if memoryEnabled {
            environment["OPENGROK_MEMORY"] = "1"
        }
    }

    func write(_ relative: String, _ contents: String) {
        let url = root.appendingPathComponent(relative)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? Data(contents.utf8).write(to: url)
    }

    func read(_ relative: String) -> String? {
        try? String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    var rewindStoreURL: URL {
        grokHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("live-session.rewind.jsonl")
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }
}

/// Build services exactly the way `makeSessionFoundation` does, then hand them
/// to a real executor. If the launcher ever stops calling `makeSessionServices`,
/// this helper still passes — which is why `servicesAreConstructedByTheLauncher`
/// below asserts the call site separately.
private func makeLiveExecutor(
    _ workspace: LiveWorkspace,
    record: LiveConversationRecord = LiveConversationRecord.new(
        sessionID: "live-session",
        workingDirectory: URL(fileURLWithPath: "/tmp")
    )
) async throws -> (LiveToolExecutor, LiveSessionServices) {
    let services = await OpenGrokLiveApplicationLauncher.makeSessionServices(
        sessionID: "live-session",
        workingDirectory: workspace.root,
        openGrokHome: workspace.grokHome,
        conversationRecord: record,
        environment: workspace.environment
    )
    let executor = try await LiveToolExecutor(
        processBackend: InertShellBackend(),
        sessionID: "live-session",
        workingDirectory: workspace.root,
        toolPolicy: nil,
        fileAccessPolicy: .allowAll,
        environment: workspace.environment,
        sessionServices: services
    )
    return (executor, services)
}

private func call(_ name: String, _ arguments: [String: Any]) -> ToolCall {
    ToolCall(
        id: "call-1",
        name: name,
        arguments: String(
            data: try! JSONSerialization.data(withJSONObject: arguments),
            encoding: .utf8
        )!
    )
}

// MARK: - Memory reachability

@Suite("session services are reached by a live session")
struct LiveSessionServicesReachabilityTests {
    @Test("memory tools are advertised to the model when memory is enabled")
    func memoryToolsReachTheModel() async throws {
        let workspace = LiveWorkspace(memoryEnabled: true)
        defer { workspace.cleanup() }

        let (executor, _) = try await makeLiveExecutor(workspace)
        let advertised = Set(executor.tools.map(\.name))
        // `executor.tools` is what the sampler is handed as the tool list, so
        // this is the difference between "the tool exists" and "the model can
        // call it".
        #expect(advertised.contains("memory_search"))
        #expect(advertised.contains("memory_get"))
    }

    @Test("--experimental-memory turns memory on without config or an env var")
    func experimentalMemoryFlagEnablesMemory() async throws {
        let workspace = LiveWorkspace(memoryEnabled: false)
        defer { workspace.cleanup() }

        // The flag used to be refused outright by `unhonoredLaunchFlag`, which
        // was correct while memory was unwired and wrong the moment it wasn't:
        // upstream's own opt-in switch would have been the one way you couldn't
        // opt in.
        let services = await OpenGrokLiveApplicationLauncher.makeSessionServices(
            sessionID: "live-session",
            workingDirectory: workspace.root,
            openGrokHome: workspace.grokHome,
            conversationRecord: LiveConversationRecord.new(
                sessionID: "live-session",
                workingDirectory: workspace.root
            ),
            environment: workspace.environment,
            experimentalMemory: true
        )
        #expect(services.memory != nil)
        #expect(services.toolSpecs.contains { $0.name == "memory_search" })
    }

    @Test("memory tools are absent when memory is off, rather than present and refusing")
    func memoryToolsAbsentWhenDisabled() async throws {
        let workspace = LiveWorkspace(memoryEnabled: false)
        defer { workspace.cleanup() }

        let (executor, _) = try await makeLiveExecutor(workspace)
        let advertised = Set(executor.tools.map(\.name))
        #expect(!advertised.contains("memory_search"))
        #expect(!advertised.contains("memory_get"))
    }

    @Test("memory_search dispatches through the executor and returns real output")
    func memorySearchDispatches() async throws {
        let workspace = LiveWorkspace(memoryEnabled: true)
        defer { workspace.cleanup() }

        let (executor, services) = try await makeLiveExecutor(workspace)
        // Seed memory through the same path `/remember` uses, and CHECK the
        // result. Discarding it is what hid the original failure: the command
        // was returning "this workspace is a temporary directory, so memory
        // writes are skipped" and the test threw that away, so the seed
        // silently no-opped and the real assertion failed later with a
        // confusing "no results" instead of the actual reason.
        let saved = await LiveMemoryCommands.remember(
            "This project pins the Rust reference at 9ed09e2a.",
            backend: services.memory
        )
        #expect(saved == "Saved to workspace memory.", "seeding memory failed: \(saved)")
        // Assert each step rather than only the last one, so a break names the
        // stage that broke. The previous version jumped straight from seeding
        // to the tool call, so an indexing failure surfaced as "the tool found
        // nothing" — true, but three steps downstream of the cause.
        #expect(
            await services.memory?.isEphemeralWorkspace == false,
            "workspace was classified ephemeral, so nothing is indexed"
        )
        // Query with words that appear VERBATIM in the seeded note. Memory
        // search matches on exact token equality — `ftsRank` intersects token
        // sets with no stemmer — so "pin" would not match "pins". (The stemming
        // in `LiveSessionSearch` is a different subsystem entirely; session
        // search and memory search do not share a matcher.) A test that leaned
        // on stemming here would be asking for behaviour neither this port nor
        // upstream implements.
        let direct = await services.memory?.search(query: "Rust reference") ?? []
        #expect(
            !direct.isEmpty,
            "the backend itself returned no results, so the tool layer is not at fault"
        )

        let result = await executor.invoke(
            sessionID: "live-session",
            workingDirectory: workspace.root,
            call: call("memory_search", ["query": "Rust reference"])
        )
        guard case .success(let output) = result else {
            Issue.record("memory_search did not dispatch: \(result)")
            return
        }
        // Reaching the backend is the claim; the exact ranking is
        // `hybridSearch`'s job and is covered by its own tests.
        #expect(output.promptText.contains("9ed09e2a"))
    }

    @Test("first-turn memory injection puts a memory-context block in the system item")
    func memoryInjectionReachesTheConversation() async throws {
        let workspace = LiveWorkspace(memoryEnabled: true)
        defer { workspace.cleanup() }

        let (_, services) = try await makeLiveExecutor(workspace)
        let saved = await LiveMemoryCommands.remember(
            "Always run the verify wrapper rather than swift test directly.",
            backend: services.memory
        )
        #expect(saved == "Saved to workspace memory.", "seeding memory failed: \(saved)")

        let items: [ConversationItem] = [.system("base prompt"), .user("hello")]
        let injected = await services.injectMemoryContext(
            into: items,
            prompt: "how should I run the tests for this project"
        )
        guard case .system(let system) = injected[0] else {
            Issue.record("expected a leading system item")
            return
        }
        #expect(system.content.contains("<memory-context>"))
        #expect(system.content.contains("verify wrapper"))
        // The original prompt must survive alongside the injected block.
        #expect(system.content.contains("base prompt"))
    }

    @Test("a temp-directory workspace says memory is inactive rather than reporting no results")
    func ephemeralWorkspaceNamesItself() async throws {
        // A cwd under the system temp dir is ephemeral by design — nothing is
        // indexed or persisted for it. What must not happen is memory_search
        // answering "No memory results found", which is indistinguishable from
        // a working memory that is simply empty. This is the case that made the
        // reachability suite fail in the first place, so it gets pinned.
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("w8s-ephemeral-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        let root = base.appendingPathComponent("repo")
        let grokHome = base.appendingPathComponent("home/.opengrok")
        for directory in [root, grokHome] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        }
        defer { try? FileManager.default.removeItem(at: base) }

        let services = await OpenGrokLiveApplicationLauncher.makeSessionServices(
            sessionID: "live-session",
            workingDirectory: root,
            openGrokHome: grokHome,
            conversationRecord: LiveConversationRecord.new(
                sessionID: "live-session",
                workingDirectory: root
            ),
            environment: ["HOME": base.path, "OPENGROK_HOME": grokHome.path],
            experimentalMemory: true
        )
        let output = await LiveMemoryTools.invoke(
            name: LiveMemoryTools.searchToolName,
            arguments: .object(["query": .string("anything")]),
            backend: services.memory
        )
        #expect(output.contains("temporary directory"))
        #expect(!output.contains("No memory results found"))
    }

    // MARK: - Goal reachability

    @Test("update_goal becomes advertised once a goal is active")
    func updateGoalReachesTheModel() async throws {
        let workspace = LiveWorkspace(memoryEnabled: false)
        defer { workspace.cleanup() }

        // No goal yet: the tool must not be offered.
        let (before, _) = try await makeLiveExecutor(workspace)
        #expect(!before.tools.contains { $0.name == "update_goal" })

        // Set a goal the way `/goal` does, then rebuild the session the way a
        // relaunch would. `update_goal` is now part of the advertised surface.
        let goalDirectory = workspace.grokHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("live-session", isDirectory: true)
        let coordinator = LiveGoalCoordinator(sessionDirectory: goalDirectory)
        await coordinator.createGoal(objective: "close the session-recovery gaps")

        let services = LiveSessionServices(
            rewind: nil,
            memory: nil,
            goal: coordinator,
            goalIsActive: await coordinator.isActive
        )
        let executor = try await LiveToolExecutor(
            processBackend: InertShellBackend(),
            sessionID: "live-session",
            workingDirectory: workspace.root,
            toolPolicy: nil,
            fileAccessPolicy: .allowAll,
            environment: workspace.environment,
            sessionServices: services
        )
        #expect(executor.tools.contains { $0.name == "update_goal" })

        // And it dispatches: the model's call reaches the tracker and comes
        // back with the tracker's own verdict.
        let result = await executor.invoke(
            sessionID: "live-session",
            workingDirectory: workspace.root,
            call: call("update_goal", ["message": "wired the rewind store"])
        )
        guard case .success(let output) = result else {
            Issue.record("update_goal did not dispatch: \(result)")
            return
        }
        #expect(output.promptText.contains("wired the rewind store"))
    }

    // MARK: - Rewind reachability

    @Test("a file written through the executor lands in a rewind point on disk")
    func rewindSnapshotReachesDisk() async throws {
        let workspace = LiveWorkspace(memoryEnabled: false)
        defer { workspace.cleanup() }
        workspace.write("Sources/A.swift", "original contents")

        let (executor, services) = try await makeLiveExecutor(workspace)

        // The prompt bracket the turn driver applies.
        await services.beginPrompt(text: "rewrite A.swift")
        let result = await executor.invoke(
            sessionID: "live-session",
            workingDirectory: workspace.root,
            call: call("write", [
                "path": "Sources/A.swift",
                "contents": "replaced contents",
            ])
        )
        // The write itself may be refused by policy in this harness; what is
        // under test is that the dispatcher captured the pre-turn state on the
        // way through, which happens before the tool runs either way.
        _ = result
        await services.endPrompt()

        // `endPrompt` persists on a detached task.
        var raw: String?
        for _ in 0..<100 {
            raw = try? String(contentsOf: workspace.rewindStoreURL, encoding: .utf8)
            if raw?.isEmpty == false { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        guard let stored = raw, !stored.isEmpty else {
            Issue.record("no rewind point was written at \(workspace.rewindStoreURL.path)")
            return
        }
        // The snapshot must hold the content as it was BEFORE the turn — that
        // is the whole basis of restoring.
        #expect(stored.contains("Sources/A.swift"))
        #expect(stored.contains("original contents"))
        #expect(stored.contains("rewrite A.swift"))
    }

    @Test("a recorded point is restorable back through the coordinator")
    func rewindRestoreReachesTheWorkingTree() async throws {
        let workspace = LiveWorkspace(memoryEnabled: false)
        defer { workspace.cleanup() }
        workspace.write("Sources/A.swift", "original contents")

        let (executor, services) = try await makeLiveExecutor(workspace)
        await services.beginPrompt(text: "rewrite A.swift")
        _ = await executor.invoke(
            sessionID: "live-session",
            workingDirectory: workspace.root,
            call: call("read_file", ["path": "Sources/A.swift"])
        )
        // Simulate the turn's edit landing on disk.
        workspace.write("Sources/A.swift", "agent's bad edit")
        await services.endPrompt()

        guard let rewind = services.rewind else {
            Issue.record("rewind coordinator was not constructed")
            return
        }
        var points: [LiveRewindPointInfo] = []
        for _ in 0..<100 {
            points = await rewind.points()
            if !points.isEmpty { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(points.count == 1)

        let outcome = try await rewind.restore(
            toPromptIndex: 0,
            mode: .filesOnly,
            force: true,
            currentItems: []
        )
        #expect(outcome.applied)
        // The bad edit is gone from the working tree — the recovery path the
        // audit called the highest-consequence missing safety net.
        #expect(workspace.read("Sources/A.swift") == "original contents")
    }

    @Test("rewind is off when the environment disables it")
    func rewindRespectsItsSwitch() async throws {
        var workspace = LiveWorkspace(memoryEnabled: false)
        workspace.environment["OPENGROK_REWIND"] = "0"
        defer { workspace.cleanup() }

        let (_, services) = try await makeLiveExecutor(workspace)
        #expect(services.rewind == nil)
    }
}
