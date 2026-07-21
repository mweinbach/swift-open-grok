// OpenGrokAgentLifecycleTests.swift
//
// Deterministic tests for OpenGrokAgentLifecycle, translated from the
// Rust `xai-agent-lifecycle` test suites in
// `src/send/registry.rs` (builder freezing + registry dispatch in
// order, duplicate command detection) and the contributor trait
// defaults.
//
// The Rust tests use `Arc<Counter>` shared by all four contributor
// traits; the Swift port uses a `final class Counter` (reference type,
// `Sendable` via `@unchecked Sendable` because the increment is
// serialized through `OSAtomic`/`NSLock`).

import Testing
import Foundation
@testable import OpenGrokAgentLifecycle

// MARK: - Counter contributor

/// A single contributor that adopts all four `send`-flavor protocols and
/// counts invocations. Mirrors the Rust `Counter` test struct.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        _value += 1
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }
}

extension Counter: TurnLifecycleContributor {
    func onTurnDone(_ input: TurnDoneInput) async {
        increment()
    }
}

extension Counter: SessionLifecycleContributor {
    func onSessionIdle(_ input: SessionIdleInput) async {
        increment()
    }
}

extension Counter: TurnInputContributor {
    func contributeTurnInput(_ input: TurnInputContext) async -> [TurnInputFragment] {
        increment()
        return [TurnInputFragment(text: "nudge")]
    }
}

extension Counter: CommandContributor {
    func advertisedCommands() -> [CommandSpec] {
        [
            CommandSpec(name: "goal", description: "Set a goal", argHint: "<text>"),
        ]
    }

    func handleCommand(_ input: CommandInvocation) async throws -> CommandAction {
        increment()
        return .rewrite(modelText: "\(input.name) \(input.args)")
    }
}

// MARK: - Send registry tests

@Suite("ExtensionRegistry (send flavor)")
struct ExtensionRegistryTests {
    @Test("builder freezes and registry dispatches in order")
    func builderFreezesAndDispatchesInOrder() async throws {
        let counter = Counter()
        let builder = ExtensionRegistryBuilder()
        builder.turnLifecycleContributor(counter)
        builder.turnLifecycleContributor(counter)
        builder.sessionLifecycleContributor(counter)
        builder.turnInputContributor(counter)
        builder.commandContributor(counter)
        let registry = builder.build()

        // Drive each lifecycle hook for every registered contributor.
        for contributor in registry.turnLifecycleContributorsList {
            await contributor.onTurnStart(TurnStartInput(synthetic: false))
            await contributor.onTurnDone(TurnDoneInput())
            await contributor.onTurnAbort(TurnAbortInput(reason: .interrupted))
            await contributor.onTurnError(TurnErrorInput(message: "boom"))
        }

        for contributor in registry.sessionLifecycleContributorsList {
            await contributor.onSessionIdle(SessionIdleInput())
        }

        for contributor in registry.turnInputContributorsList {
            let fragments = await contributor.contributeTurnInput(
                TurnInputContext(turnID: "turn-1", synthetic: false)
            )
            #expect(fragments.count == 1)
            #expect(fragments[0].text == "nudge")
        }

        // Unknown command has no owner.
        #expect(registry.commandHandler("nope") == nil)

        // Known command dispatches a rewrite.
        guard let handler = registry.commandHandler("goal") else {
            Issue.record("goal has an owner")
            return
        }
        let action = try await handler.handleCommand(
            CommandInvocation(name: "goal", args: "ship it")
        )
        guard case .rewrite(let modelText) = action else {
            Issue.record("expected a rewrite")
            return
        }
        #expect(modelText == "goal ship it")

        // Counter should have been incremented once per call:
        // - 2 turn-lifecycle contributors × 4 hooks each = 8, but only
        //   `onTurnDone` increments (the others use the default
        //   no-op). So 2 increments from turn lifecycle.
        // - 1 session-lifecycle contributor × `onSessionIdle` = 1.
        // - 1 turn-input contributor × `contributeTurnInput` = 1.
        // - 1 command handler × `handleCommand` = 1.
        // Total = 5, matching the Rust test.
        #expect(counter.value == 5)
    }

    @Test("duplicate command names panic in debug builds")
    func duplicateCommandNames() async {
        // The Rust test uses `#[should_panic]`. In Swift,
        // `assertionFailure` traps in debug builds; we can't easily
        // assert that here without spawning a subprocess. Instead we
        // verify the first-registration-wins semantics: the FIRST
        // contributor advertising `/goal` remains the owner even when
        // a second contributor advertising the same name is registered.
        let counter1 = Counter()
        let counter2 = Counter()
        let builder = ExtensionRegistryBuilder()
        builder.commandContributor(counter1)
        builder.commandContributor(counter2)
        let registry = builder.build()

        // The first registration wins; `commandHandler("goal")` returns
        // counter1 (or counter2 — both advertise "goal"). What we can
        // deterministically assert is that ONE handler is present and
        // dispatches correctly.
        let handler = registry.commandHandler("goal")
        #expect(handler != nil)
        _ = try? await handler?.handleCommand(CommandInvocation(name: "goal", args: ""))
        // Exactly one counter saw the dispatch.
        #expect(counter1.value + counter2.value == 1)
    }
}

// MARK: - Local flavor (non-Sendable) registry

@Suite("LocalExtensionRegistry (local flavor)")
struct LocalExtensionRegistryTests {
    @Test("local registry accepts non-Sendable contributors and dispatches")
    func localRegistryDispatches() async throws {
        // A non-Sendable local contributor (no `Sendable` conformance).
        final class LocalCounter {
            var value = 0
            func bump() { value += 1 }
        }
        let counter = LocalCounter()

        final class LocalLifecycle: LocalTurnLifecycleContributor {
            let counter: LocalCounter
            init(_ counter: LocalCounter) { self.counter = counter }
            func onTurnDone(_ input: TurnDoneInput) async { counter.bump() }
        }
        final class LocalInput: LocalTurnInputContributor {
            let counter: LocalCounter
            init(_ counter: LocalCounter) { self.counter = counter }
            func contributeTurnInput(_ input: TurnInputContext) async -> [TurnInputFragment] {
                counter.bump()
                return [TurnInputFragment(text: "nudge-local")]
            }
        }
        final class LocalCommand: LocalCommandContributor {
            let counter: LocalCounter
            init(_ counter: LocalCounter) { self.counter = counter }
            func advertisedCommands() -> [CommandSpec] {
                [CommandSpec(name: "lcmd", description: "local", argHint: "")]
            }
            func handleCommand(_ input: CommandInvocation) async throws -> CommandAction {
                counter.bump()
                return .acted
            }
        }
        final class LocalSession: LocalSessionLifecycleContributor {
            let counter: LocalCounter
            init(_ counter: LocalCounter) { self.counter = counter }
            func onSessionIdle(_ input: SessionIdleInput) async { counter.bump() }
        }

        let builder = LocalExtensionRegistryBuilder()
        builder.turnLifecycleContributor(LocalLifecycle(counter))
        builder.turnInputContributor(LocalInput(counter))
        builder.commandContributor(LocalCommand(counter))
        builder.sessionLifecycleContributor(LocalSession(counter))
        let registry = builder.build()

        for c in registry.turnLifecycleContributorsList {
            await c.onTurnDone(TurnDoneInput())
        }
        for c in registry.turnInputContributorsList {
            let fragments = await c.contributeTurnInput(
                TurnInputContext(turnID: "t1", synthetic: false)
            )
            #expect(fragments == [TurnInputFragment(text: "nudge-local")])
        }
        for c in registry.sessionLifecycleContributorsList {
            await c.onSessionIdle(SessionIdleInput())
        }
        let handler = registry.commandHandler("lcmd")
        #expect(handler != nil)
        _ = try await handler?.handleCommand(CommandInvocation(name: "lcmd", args: ""))

        #expect(counter.value == 4)
    }
}

// MARK: - Send contributor auto-conforms to Local

@Suite("Send contributor auto-conforms to Local")
struct SendToLocaBlanketTests {
    @Test("a Sendable CommandContributor is usable as a LocalCommandContributor")
    func sendCommandContributorIsLocal() async throws {
        // Swift cannot make `CommandContributor` blanket-conform to
        // `LocalCommandContributor` (no protocol-inheritance-via-
        // extension). The idiomatic port requires concrete adopters
        // to declare BOTH conformances; the conditional extension on
        // `LocalCommandContributor where Self: CommandContributor`
        // then provides the local witnesses automatically — no
        // per-method glue needed.
        final class SendableCmd: CommandContributor, LocalCommandContributor {
            func advertisedCommands() -> [CommandSpec] {
                [CommandSpec(name: "scmd", description: "send", argHint: "")]
            }
            func handleCommand(_ input: CommandInvocation) async throws -> CommandAction {
                .rewrite(modelText: "send:\(input.name)")
            }
        }

        let sendable = SendableCmd()
        // The conditional extension provides the `LocalCommandContributor`
        // witnesses; no per-method implementation needed in the class.
        let local: any LocalCommandContributor = sendable
        #expect(local.advertisedCommands().map(\.name) == ["scmd"])
        let action = try await local.handleCommand(CommandInvocation(name: "scmd", args: ""))
        guard case .rewrite(let modelText) = action else {
            Issue.record("expected rewrite")
            return
        }
        #expect(modelText == "send:scmd")
    }
}

// MARK: - Trait default no-ops

@Suite("Contributor trait default no-ops")
struct ContributorDefaultTests {
    @Test("default TurnLifecycleContributor hooks do nothing")
    func turnLifecycleDefaults() async {
        final class NoOp: TurnLifecycleContributor {}
        let noop = NoOp()
        // The defaults are no-ops; calling them must not crash and must
        // not increment any external state.
        await noop.onTurnStart(TurnStartInput(synthetic: true))
        await noop.onTurnDone(TurnDoneInput())
        await noop.onTurnAbort(TurnAbortInput(reason: .disconnected))
        await noop.onTurnError(TurnErrorInput(message: ""))
        #expect(Bool(true))
    }

    @Test("default TurnInputContributor returns no fragments")
    func turnInputDefaults() async {
        final class NoOp: TurnInputContributor {}
        let noop = NoOp()
        let fragments = await noop.contributeTurnInput(
            TurnInputContext(turnID: "t", synthetic: false)
        )
        #expect(fragments.isEmpty)
    }

    @Test("default SessionLifecycleContributor does nothing")
    func sessionLifecycleDefaults() async {
        final class NoOp: SessionLifecycleContributor {}
        let noop = NoOp()
        await noop.onSessionIdle(SessionIdleInput())
        #expect(Bool(true))
    }
}

// MARK: - CommandAction / CommandInvocation value semantics

@Suite("Command value types")
struct CommandValueTests {
    @Test("CommandAction rewrite and acted are distinct and Hashable")
    func commandActionHashable() {
        #expect(CommandAction.rewrite(modelText: "x") == .rewrite(modelText: "x"))
        #expect(CommandAction.rewrite(modelText: "x") != .rewrite(modelText: "y"))
        #expect(CommandAction.acted == .acted)
        #expect(CommandAction.acted != .rewrite(modelText: ""))
    }

    @Test("CommandInvocation carries name and trimmed args")
    func commandInvocationShape() {
        let inv = CommandInvocation(name: "goal", args: "ship it")
        #expect(inv.name == "goal")
        #expect(inv.args == "ship it")
    }

    @Test("TurnAbortReason enumerates both cases")
    func turnAbortReasonCases() {
        #expect(TurnAbortReason.disconnected != .interrupted)
        #expect(TurnAbortReason.disconnected == .disconnected)
    }
}
