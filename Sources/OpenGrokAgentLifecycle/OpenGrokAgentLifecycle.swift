// OpenGrokAgentLifecycle.swift
//
// Host-agnostic agent lifecycle hooks shared by multiple agent hosts
// (e.g. xai-grok-shell). Contributors receive data-only per-hook inputs
// at dispatch time; anything they act through is a capability injected
// at install time, and they never own loop control.
//
// This is the Swift port of the Rust crate `xai-agent-lifecycle`
// (crates/codegen/xai-agent-lifecycle). The Rust crate splits
// contributors into a `send` flavor (`Send + Sync`-bounded trait
// futures, used by hosts whose state is `Send`) and a `local` flavor
// (`?Send` twin, used by single-threaded hosts like grok build's TUI
// agent whose session state is `Rc`/`RefCell`-based). The local trait
// is auto-implemented for any `T: SendFlavor` so shared logic can be
// registered against either host.
//
// Swift 6 strict-concurrency translation:
//   * The `send` flavor becomes a `Sendable` protocol whose async
//     requirements run on a `Sendable` executor. Concrete adopters must
//     be `Sendable` (typically `final class`/`actor`/`struct` of
//     `Sendable` fields).
//   * The `local` flavor becomes a non-`Sendable` protocol whose
//     adopters are not required to be `Sendable` — they live behind a
//     single-threaded host's isolation boundary (typically a `@MainActor`
//     or a dedicated `actor` for the TUI agent).
//   * The blanket `impl<T: SendFlavor> LocalFlavor for T` is mirrored
//     by a conditional extension on `LocalCommandContributor where Self:
//     CommandContributor` etc., so a `Sendable` contributor registered
//     against a local host gets its `send`-flavor behavior transparently.
//
// Rust crate mapping: xai-agent-lifecycle
// (crates/codegen/xai-agent-lifecycle). See CRATE_MAP.md and
// PORT_PLAN.md (W1-S2).

import Foundation

// MARK: - send::contributors::command

/// A slash command a contributor advertises; the host maps it onto its
/// own advertising protocol.
///
/// Swift port of `xai_agent_lifecycle::send::contributors::CommandSpec`.
public struct CommandSpec: Hashable, Sendable {
    public var name: String
    public var description: String
    public var argHint: String

    public init(name: String, description: String, argHint: String) {
        self.name = name
        self.description = description
        self.argHint = argHint
    }
}

/// A parsed `/name args` invocation. The host owns parsing and routes
/// it to the command's one owner.
///
/// Swift port of `xai_agent_lifecycle::send::contributors::CommandInvocation`.
/// Unlike the Rust version (which borrows `&str` for the lifetime of the
/// invocation), the Swift port owns its strings so the value can cross
/// async boundaries safely. The strings are still cheap to copy
/// (COW).
public struct CommandInvocation: Hashable, Sendable {
    public var name: String
    /// Whitespace-trimmed; empty for a bare `/name`.
    public var args: String

    public init(name: String, args: String) {
        self.name = name
        self.args = args
    }
}

/// What a handled command does to the turn; rejections travel as the
/// `Err` reason.
///
/// Swift port of `xai_agent_lifecycle::send::contributors::CommandAction`.
public enum CommandAction: Hashable, Sendable {
    /// Replace the model-visible copy of the message with `modelText`.
    case rewrite(modelText: String)
    /// Side effect performed, nothing to say; the state change surfaces
    /// through the host's own rendering.
    case acted
}

/// Handles the slash commands the extension advertises. Only invoked
/// for commands this contributor owns; the `Err` reason is the only
/// channel for "why not", so hosts must surface it.
///
/// Swift port of `xai_agent_lifecycle::send::contributors::CommandContributor`.
/// Marked `Sendable` to mirror the Rust `Send + Sync` bound — concrete
/// adopters must be safe to share across actors.
public protocol CommandContributor: Sendable {
    func advertisedCommands() -> [CommandSpec]

    func handleCommand(_ input: CommandInvocation) async throws -> CommandAction
}

// MARK: - send::contributors::session_lifecycle

/// Input supplied when the host observes the session settling idle.
///
/// Swift port of `xai_agent_lifecycle::send::contributors::SessionIdleInput`.
/// Like the Rust unit struct, carries no data; preserved as a nominal
/// type so dispatch sites can name it.
public struct SessionIdleInput: Hashable, Sendable {
    public init() {}
}

/// Swift port of `xai_agent_lifecycle::send::contributors::SessionLifecycleContributor`.
public protocol SessionLifecycleContributor: Sendable {
    /// Fired when the session settles idle (no running turn or queued
    /// work); the host owns the check.
    func onSessionIdle(_ input: SessionIdleInput) async
}

extension SessionLifecycleContributor {
    /// Default no-op implementation. Adopters override to react.
    public func onSessionIdle(_ input: SessionIdleInput) async {}
}

// MARK: - send::contributors::turn_input

/// Turn facts supplied when the host pulls extension input at its
/// sampling chokepoint.
///
/// Swift port of `xai_agent_lifecycle::send::contributors::TurnInputContext`.
public struct TurnInputContext: Hashable, Sendable {
    /// Stable host-owned turn identifier.
    public var turnID: String
    /// True when the harness produced the turn (auto-wake, drain, cron,
    /// continuation), not the user.
    public var synthetic: Bool

    public init(turnID: String, synthetic: Bool) {
        self.turnID = turnID
        self.synthetic = synthetic
    }
}

/// A model-visible input fragment contributed into the active turn. The
/// host owns wrapping, origin stamping, and placement.
///
/// Swift port of `xai_agent_lifecycle::send::contributors::TurnInputFragment`.
public struct TurnInputFragment: Hashable, Sendable {
    public var text: String

    public init(text: String) {
        self.text = text
    }
}

/// Contributes model-visible input fragments into the active turn when
/// the host pulls at its sampling chokepoint. Fragments land in the same
/// turn, never a new one.
///
/// Swift port of `xai_agent_lifecycle::send::contributors::TurnInputContributor`.
public protocol TurnInputContributor: Sendable {
    func contributeTurnInput(_ input: TurnInputContext) async -> [TurnInputFragment]
}

extension TurnInputContributor {
    /// Default no-op: contributes no fragments.
    public func contributeTurnInput(_ input: TurnInputContext) async -> [TurnInputFragment] {
        []
    }
}

// MARK: - send::contributors::turn_lifecycle

/// Input supplied when the host starts a turn.
///
/// Swift port of `xai_agent_lifecycle::send::contributors::TurnStartInput`.
public struct TurnStartInput: Hashable, Sendable {
    /// True when the harness produced the turn (auto-wake, drain, cron,
    /// continuation), not the user.
    public var synthetic: Bool

    public init(synthetic: Bool) {
        self.synthetic = synthetic
    }
}

/// Input supplied when the host completes a turn.
///
/// Swift port of `xai_agent_lifecycle::send::contributors::TurnDoneInput`.
/// Unit-struct parity.
public struct TurnDoneInput: Hashable, Sendable {
    public init() {}
}

/// Why the host aborted the turn instead of completing it.
///
/// Swift port of `xai_agent_lifecycle::send::contributors::TurnAbortReason`.
public enum TurnAbortReason: Hashable, Sendable {
    /// The client went away mid-turn.
    case disconnected
    /// The user interrupted the turn before it completed.
    case interrupted
}

/// Input supplied when the host aborts a turn.
///
/// Swift port of `xai_agent_lifecycle::send::contributors::TurnAbortInput`.
public struct TurnAbortInput: Hashable, Sendable {
    public var reason: TurnAbortReason

    public init(reason: TurnAbortReason) {
        self.reason = reason
    }
}

/// Input supplied when the host observes an error for a turn.
///
/// Swift port of `xai_agent_lifecycle::send::contributors::TurnErrorInput`.
/// The Rust version borrows `&'a str` for the lifetime of the dispatch;
/// the Swift port owns the `String` so the value can cross async
/// boundaries and be retained by the adopter.
public struct TurnErrorInput: Hashable, Sendable {
    public var message: String

    public init(message: String) {
        self.message = message
    }
}

/// Swift port of `xai_agent_lifecycle::send::contributors::TurnLifecycleContributor`.
public protocol TurnLifecycleContributor: Sendable {
    func onTurnStart(_ input: TurnStartInput) async

    func onTurnDone(_ input: TurnDoneInput) async

    func onTurnAbort(_ input: TurnAbortInput) async

    func onTurnError(_ input: TurnErrorInput) async
}

extension TurnLifecycleContributor {
    /// Default no-op. Adopters override to react.
    public func onTurnStart(_ input: TurnStartInput) async {}

    /// Default no-op. Adopters override to react.
    public func onTurnDone(_ input: TurnDoneInput) async {}

    /// Default no-op. Adopters override to react.
    public func onTurnAbort(_ input: TurnAbortInput) async {}

    /// Default no-op. Adopters override to react.
    public func onTurnError(_ input: TurnErrorInput) async {}
}

// MARK: - send::registry

/// Mutable registry used while hosts register typed runtime
/// contributions.
///
/// Swift port of `xai_agent_lifecycle::send::registry::ExtensionRegistryBuilder`.
/// The Rust `Vec<Arc<dyn …>>` becomes `[any …]` (which Swift stores
/// with reference semantics for class/actor adopters and value semantics
/// for struct adopters; both are `Sendable` because the protocols are
/// `Sendable`-bounded).
public final class ExtensionRegistryBuilder: @unchecked Sendable {
    private var turnLifecycleContributors: [any TurnLifecycleContributor] = []
    private var sessionLifecycleContributors: [any SessionLifecycleContributor] = []
    private var turnInputContributors: [any TurnInputContributor] = []
    private var commandContributors: [any CommandContributor] = []

    public init() {}

    public func turnLifecycleContributor(_ contributor: any TurnLifecycleContributor) {
        turnLifecycleContributors.append(contributor)
    }

    public func sessionLifecycleContributor(_ contributor: any SessionLifecycleContributor) {
        sessionLifecycleContributors.append(contributor)
    }

    public func turnInputContributor(_ contributor: any TurnInputContributor) {
        turnInputContributors.append(contributor)
    }

    public func commandContributor(_ contributor: any CommandContributor) {
        commandContributors.append(contributor)
    }

    /// Routes each advertised command to its one owner. Duplicate names
    /// are a composition bug: first registration wins, traps in debug
    /// builds, logs in release.
    public func build() -> ExtensionRegistry {
        var commandHandlers: [String: any CommandContributor] = [:]
        for contributor in commandContributors {
            for spec in contributor.advertisedCommands() {
                if commandHandlers[spec.name] != nil {
                    // Mirror Rust: debug_assert!(false, …) panics in
                    // debug, traces in release. Swift `assertionFailure`
                    // traps in debug, is a no-op in release. We also
                    // log via `os_log`-equivalent on the release path
                    // so the composition bug is observable.
                    assertionFailure("duplicate command contributed: /\(spec.name)")
                    print("[OpenGrokAgentLifecycle] Duplicate command contributed; first registration wins: /\(spec.name)")
                    continue
                }
                commandHandlers[spec.name] = contributor
            }
        }
        return ExtensionRegistry(
            turnLifecycleContributors: turnLifecycleContributors,
            sessionLifecycleContributors: sessionLifecycleContributors,
            turnInputContributors: turnInputContributors,
            commandContributors: commandContributors,
            commandHandlers: commandHandlers
        )
    }
}

/// Immutable typed registry produced after extensions are installed.
///
/// Swift port of `xai_agent_lifecycle::send::registry::ExtensionRegistry`.
public struct ExtensionRegistry: Sendable {
    private let turnLifecycleContributors: [any TurnLifecycleContributor]
    private let sessionLifecycleContributors: [any SessionLifecycleContributor]
    private let turnInputContributors: [any TurnInputContributor]
    private let commandContributors: [any CommandContributor]
    private let commandHandlers: [String: any CommandContributor]

    public init(
        turnLifecycleContributors: [any TurnLifecycleContributor],
        sessionLifecycleContributors: [any SessionLifecycleContributor],
        turnInputContributors: [any TurnInputContributor],
        commandContributors: [any CommandContributor],
        commandHandlers: [String: any CommandContributor]
    ) {
        self.turnLifecycleContributors = turnLifecycleContributors
        self.sessionLifecycleContributors = sessionLifecycleContributors
        self.turnInputContributors = turnInputContributors
        self.commandContributors = commandContributors
        self.commandHandlers = commandHandlers
    }

    public init() {
        self.init(
            turnLifecycleContributors: [],
            sessionLifecycleContributors: [],
            turnInputContributors: [],
            commandContributors: [],
            commandHandlers: [:]
        )
    }

    public var turnLifecycleContributorsList: [any TurnLifecycleContributor] {
        turnLifecycleContributors
    }

    public var sessionLifecycleContributorsList: [any SessionLifecycleContributor] {
        sessionLifecycleContributors
    }

    public var turnInputContributorsList: [any TurnInputContributor] {
        turnInputContributors
    }

    public var commandContributorsList: [any CommandContributor] {
        commandContributors
    }

    /// The one contributor owning `name`, or `nil` when no extension
    /// advertised it.
    public func commandHandler(_ name: String) -> (any CommandContributor)? {
        commandHandlers[name]
    }
}

// MARK: - local::contributors

/// `?Send` twin of `CommandContributor` for single-threaded hosts like
/// grok build's TUI agent, whose session state is reference-cell-based
/// and need not satisfy the `Sendable` bounds the send flavor bakes
/// into its async hooks.
///
/// Swift port of `xai_agent_lifecycle::local::contributors::LocalCommandContributor`.
/// Concrete adopters are NOT required to be `Sendable` — they live
/// behind a single-threaded host's isolation boundary.
public protocol LocalCommandContributor {
    func advertisedCommands() -> [CommandSpec]

    func handleCommand(_ input: CommandInvocation) async throws -> CommandAction
}

extension LocalCommandContributor {
    /// Default no-op handler. Adopters override.
    public func handleCommand(_ input: CommandInvocation) async throws -> CommandAction {
        .acted
    }
}

/// `?Send` twin of `SessionLifecycleContributor`.
///
/// Swift port of `xai_agent_lifecycle::local::contributors::LocalSessionLifecycleContributor`.
public protocol LocalSessionLifecycleContributor {
    /// Fired when the session settles idle (no running turn or queued
    /// work); the host owns the check.
    func onSessionIdle(_ input: SessionIdleInput) async
}

extension LocalSessionLifecycleContributor {
    /// Default no-op. Adopters override.
    public func onSessionIdle(_ input: SessionIdleInput) async {}
}

/// `?Send` twin of `TurnInputContributor` for single-threaded hosts like
/// grok build's TUI agent, whose session state is reference-cell-based
/// and need not satisfy the `Sendable` bounds the send flavor bakes into
/// its async hook futures.
///
/// Swift port of `xai_agent_lifecycle::local::contributors::LocalTurnInputContributor`.
public protocol LocalTurnInputContributor {
    func contributeTurnInput(_ input: TurnInputContext) async -> [TurnInputFragment]
}

extension LocalTurnInputContributor {
    /// Default no-op: contributes no fragments.
    public func contributeTurnInput(_ input: TurnInputContext) async -> [TurnInputFragment] {
        []
    }
}

/// `?Send` twin of `TurnLifecycleContributor` for single-threaded hosts
/// like grok build's TUI agent, whose session state is
/// reference-cell-based and need not satisfy the `Sendable` bounds the
/// send flavor bakes into its async hook futures.
///
/// Swift port of `xai_agent_lifecycle::local::contributors::LocalTurnLifecycleContributor`.
public protocol LocalTurnLifecycleContributor {
    func onTurnStart(_ input: TurnStartInput) async

    func onTurnDone(_ input: TurnDoneInput) async

    func onTurnAbort(_ input: TurnAbortInput) async

    func onTurnError(_ input: TurnErrorInput) async
}

extension LocalTurnLifecycleContributor {
    /// Default no-op. Adopters override.
    public func onTurnStart(_ input: TurnStartInput) async {}

    /// Default no-op. Adopters override.
    public func onTurnDone(_ input: TurnDoneInput) async {}

    /// Default no-op. Adopters override.
    public func onTurnAbort(_ input: TurnAbortInput) async {}

    /// Default no-op. Adopters override.
    public func onTurnError(_ input: TurnErrorInput) async {}
}

// MARK: - send contributors are usable in local hosts (blanket impls)
//
// Rust models this as `impl<T: CommandContributor> LocalCommandContributor for T`
// with explicit method bodies that delegate to the send-flavor witness.
//
// Swift does NOT permit making one protocol inherit another via an
// extension (`extension CommandContributor: LocalCommandContributor {}`
// is rejected with "cannot declare inheritance relationship"). The
// idiomatic Swift translation is a conditional extension on the LOCAL
// protocol constrained to `Self: <SendProtocol>`, providing method
// witnesses that delegate to the send-flavor witness via a cast. This
// is the same pattern the Swift standard library uses for
// `LosslessStringConvertible`-style blanket conformances.
//
// IMPORTANT: the conditional extension only ADDS witnesses for types
// that already conform to the local protocol. It does not, by itself,
// make every `T: CommandContributor` conform to `LocalCommandContributor`.
// To get the Rust blanket behavior (every `T: Send` is automatically a
// `T: Local`), each concrete send-flavor adopter must declare conformance
// to the local flavor too: `final class X: CommandContributor, LocalCommandContributor {}`.
// The conditional extension then provides the local witnesses
// automatically — no per-method glue needed.

extension LocalCommandContributor where Self: CommandContributor {
    public func advertisedCommands() -> [CommandSpec] {
        (self as CommandContributor).advertisedCommands()
    }

    public func handleCommand(_ input: CommandInvocation) async throws -> CommandAction {
        try await (self as CommandContributor).handleCommand(input)
    }
}

extension LocalSessionLifecycleContributor where Self: SessionLifecycleContributor {
    public func onSessionIdle(_ input: SessionIdleInput) async {
        await (self as SessionLifecycleContributor).onSessionIdle(input)
    }
}

extension LocalTurnInputContributor where Self: TurnInputContributor {
    public func contributeTurnInput(_ input: TurnInputContext) async -> [TurnInputFragment] {
        await (self as TurnInputContributor).contributeTurnInput(input)
    }
}

extension LocalTurnLifecycleContributor where Self: TurnLifecycleContributor {
    public func onTurnStart(_ input: TurnStartInput) async {
        await (self as TurnLifecycleContributor).onTurnStart(input)
    }

    public func onTurnDone(_ input: TurnDoneInput) async {
        await (self as TurnLifecycleContributor).onTurnDone(input)
    }

    public func onTurnAbort(_ input: TurnAbortInput) async {
        await (self as TurnLifecycleContributor).onTurnAbort(input)
    }

    public func onTurnError(_ input: TurnErrorInput) async {
        await (self as TurnLifecycleContributor).onTurnError(input)
    }
}

// MARK: - local::registry

/// Mutable registry used while single-threaded hosts register typed
/// runtime contributions.
///
/// Swift port of `xai_agent_lifecycle::local::registry::LocalExtensionRegistryBuilder`.
/// Not `Sendable` — local contributors need not be `Sendable` and the
/// builder is meant to be used within one isolation domain.
public final class LocalExtensionRegistryBuilder {
    private var turnLifecycleContributors: [any LocalTurnLifecycleContributor] = []
    private var sessionLifecycleContributors: [any LocalSessionLifecycleContributor] = []
    private var turnInputContributors: [any LocalTurnInputContributor] = []
    private var commandContributors: [any LocalCommandContributor] = []

    public init() {}

    public func turnLifecycleContributor(_ contributor: any LocalTurnLifecycleContributor) {
        turnLifecycleContributors.append(contributor)
    }

    public func sessionLifecycleContributor(_ contributor: any LocalSessionLifecycleContributor) {
        sessionLifecycleContributors.append(contributor)
    }

    public func turnInputContributor(_ contributor: any LocalTurnInputContributor) {
        turnInputContributors.append(contributor)
    }

    public func commandContributor(_ contributor: any LocalCommandContributor) {
        commandContributors.append(contributor)
    }

    /// Routes each advertised command to its one owner. Duplicate names
    /// are a composition bug: first registration wins, traps in debug
    /// builds, logs in release.
    public func build() -> LocalExtensionRegistry {
        var commandHandlers: [String: any LocalCommandContributor] = [:]
        for contributor in commandContributors {
            for spec in contributor.advertisedCommands() {
                if commandHandlers[spec.name] != nil {
                    assertionFailure("duplicate command contributed: /\(spec.name)")
                    print("[OpenGrokAgentLifecycle] Duplicate command contributed; first registration wins: /\(spec.name)")
                    continue
                }
                commandHandlers[spec.name] = contributor
            }
        }
        return LocalExtensionRegistry(
            turnLifecycleContributors: turnLifecycleContributors,
            sessionLifecycleContributors: sessionLifecycleContributors,
            turnInputContributors: turnInputContributors,
            commandContributors: commandContributors,
            commandHandlers: commandHandlers
        )
    }
}

/// Immutable typed registry produced after extensions are installed in
/// a single-threaded host.
///
/// Swift port of `xai_agent_lifecycle::local::registry::LocalExtensionRegistry`.
/// Not `Sendable` — local contributors need not be `Sendable`.
public final class LocalExtensionRegistry {
    private let turnLifecycleContributors: [any LocalTurnLifecycleContributor]
    private let sessionLifecycleContributors: [any LocalSessionLifecycleContributor]
    private let turnInputContributors: [any LocalTurnInputContributor]
    private let commandContributors: [any LocalCommandContributor]
    private let commandHandlers: [String: any LocalCommandContributor]

    public init(
        turnLifecycleContributors: [any LocalTurnLifecycleContributor],
        sessionLifecycleContributors: [any LocalSessionLifecycleContributor],
        turnInputContributors: [any LocalTurnInputContributor],
        commandContributors: [any LocalCommandContributor],
        commandHandlers: [String: any LocalCommandContributor]
    ) {
        self.turnLifecycleContributors = turnLifecycleContributors
        self.sessionLifecycleContributors = sessionLifecycleContributors
        self.turnInputContributors = turnInputContributors
        self.commandContributors = commandContributors
        self.commandHandlers = commandHandlers
    }

    /// Convenience initializer producing an empty registry. Mirrors
    /// Rust `#[derive(Default)]`.
    public convenience init() {
        self.init(
            turnLifecycleContributors: [],
            sessionLifecycleContributors: [],
            turnInputContributors: [],
            commandContributors: [],
            commandHandlers: [:]
        )
    }

    public var turnLifecycleContributorsList: [any LocalTurnLifecycleContributor] {
        turnLifecycleContributors
    }

    public var sessionLifecycleContributorsList: [any LocalSessionLifecycleContributor] {
        sessionLifecycleContributors
    }

    public var turnInputContributorsList: [any LocalTurnInputContributor] {
        turnInputContributors
    }

    public var commandContributorsList: [any LocalCommandContributor] {
        commandContributors
    }

    /// The one contributor owning `name`, or `nil` when no extension
    /// advertised it.
    public func commandHandler(_ name: String) -> (any LocalCommandContributor)? {
        commandHandlers[name]
    }
}
