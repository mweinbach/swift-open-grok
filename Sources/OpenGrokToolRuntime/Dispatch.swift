// Dispatch.swift
//
// Open Grok — Swift port of `xai-tool-runtime/src/dispatch.rs`.

import Foundation
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolTypes

/// Object-safe tool dispatch interface.
///
/// Implementations route `toolId` to the correct tool, decode `args`,
/// and return a streaming result as `TypedToolOutput`.
public protocol ToolDispatch: Sendable {
    /// Streaming dispatch. The returned stream MUST end with exactly one
    /// `Terminal` item per the `ToolStream` invariant.
    func call(
        toolId: ToolId,
        args: JSONValue,
        ctx: ToolCallContext
    ) async -> ToolStream<TypedToolOutput>
}

extension ToolDispatch {
    /// Drain the stream and return only the terminal result.
    public func callTerminal(
        toolId: ToolId,
        args: JSONValue,
        ctx: ToolCallContext
    ) async -> Result<TypedToolOutput, ToolError> {
        let stream = await call(toolId: toolId, args: args, ctx: ctx)
        for await item in stream {
            switch item {
            case .progress:
                continue
            case .terminal(let result):
                return result
            }
        }
        return .failure(.custom(
            code: "stream_no_terminal",
            detail: "dispatch stream ended without a terminal item"
        ))
    }
}

/// Ensures exactly one terminal outcome is emitted for a dispatch call.
private final class TerminalArbiter: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    /// Returns `true` if this caller wins the race to emit the terminal.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if finished { return false }
        finished = true
        return true
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }
}

private enum InvokeRace: Sendable {
    /// User cancellation won.
    case cancelled
    /// Tool produced a terminal result (success, failure, or missing-terminal).
    case terminal(Result<TypedToolOutput, ToolError>)
}

/// In-memory registry dispatch over a map of type-erased tools.
public actor ToolRegistryDispatch: ToolDispatch {
    private var tools: [String: any ToolDyn] = [:]

    public init() {}

    public init(tools: [any ToolDyn]) {
        for tool in tools {
            self.tools[tool.id().rawValue] = tool
        }
    }

    public func register(_ tool: any ToolDyn) {
        tools[tool.id().rawValue] = tool
    }

    public func unregister(toolId: ToolId) {
        tools.removeValue(forKey: toolId.rawValue)
    }

    public func listTools(ctx: ListToolsContext = ListToolsContext()) -> [ToolDescription] {
        tools.values
            .filter { $0.shouldList(ctx: ctx) }
            .map { $0.description(ctx: ctx) }
            .sorted { $0.name < $1.name }
    }

    public func call(
        toolId: ToolId,
        args: JSONValue,
        ctx: ToolCallContext
    ) async -> ToolStream<TypedToolOutput> {
        guard let tool = tools[toolId.rawValue] else {
            return terminalOnly(.failure(
                .notFound(toolId: toolId, detail: "tool not found: \(toolId.rawValue)")
            ))
        }
        // Cooperative cancellation: if the context carries a Cancellation
        // extension that is already cancelled, short-circuit.
        if let cancellation = ctx.get(Cancellation.self), cancellation.isCancelled {
            return terminalOnly(.failure(
                .cancelled(toolId: toolId, detail: "tool call cancelled before start")
            ))
        }

        // Race the full invocation (execute + stream drain) against mid-flight
        // cancellation so the dispatcher hard-cancels running calls and emits
        // exactly one terminal item.
        return Self.cancellableInvocation(
            toolId: toolId,
            args: args,
            ctx: ctx,
            tool: tool
        )
    }

    /// Own the invocation task, race it with `Cancellation`, and emit
    /// exactly one terminal result.
    private static func cancellableInvocation(
        toolId: ToolId,
        args: JSONValue,
        ctx: ToolCallContext,
        tool: any ToolDyn
    ) -> ToolStream<TypedToolOutput> {
        let cancellation = ctx.get(Cancellation.self)
        return AsyncStream { continuation in
            let arbiter = TerminalArbiter()

            func finish(_ result: Result<TypedToolOutput, ToolError>) {
                guard arbiter.claim() else { return }
                continuation.yield(.terminal(result))
                continuation.finish()
            }

            let work = Task {
                await withTaskGroup(of: InvokeRace.self) { group in
                    // Invocation: execute tool, forward progress, capture terminal.
                    group.addTask {
                        let toolStream = await tool.execute(ctx: ctx, args: args)
                        for await item in toolStream {
                            if Task.isCancelled { break }
                            if let cancellation, cancellation.isCancelled { break }
                            switch item {
                            case .progress(let progress):
                                if !arbiter.isFinished {
                                    continuation.yield(.progress(progress))
                                }
                            case .terminal(let result):
                                return .terminal(result)
                            }
                        }
                        if Task.isCancelled || (cancellation?.isCancelled ?? false) {
                            return .cancelled
                        }
                        return .terminal(.failure(.custom(
                            code: "stream_no_terminal",
                            detail: "dispatch stream ended without a terminal item"
                        )))
                    }

                    // Cancellation watcher (only when a handle is present).
                    if let cancellation {
                        group.addTask {
                            await cancellation.waitUntilCancelled()
                            if cancellation.isCancelled {
                                return .cancelled
                            }
                            // Task-cancelled wake without user cancel: park.
                            while !Task.isCancelled {
                                try? await Task.sleep(nanoseconds: 60_000_000_000)
                            }
                            return .cancelled
                        }
                    }

                    // First decisive outcome wins; cancel the sibling.
                    let winner = await group.next() ?? .terminal(.failure(.custom(
                        code: "stream_no_terminal",
                        detail: "dispatch race produced no outcome"
                    )))
                    group.cancelAll()

                    switch winner {
                    case .cancelled:
                        finish(.failure(.cancelled(
                            toolId: toolId,
                            detail: "tool call cancelled"
                        )))
                    case .terminal(let result):
                        finish(result)
                    }

                    // Drain remaining children (they must not block forever —
                    // Cancellation.waitUntilCancelled respects task cancel).
                    for await _ in group {}

                    // Safety net: always emit exactly one terminal.
                    if !arbiter.isFinished {
                        if cancellation?.isCancelled == true || Task.isCancelled {
                            finish(.failure(.cancelled(
                                toolId: toolId,
                                detail: "tool call cancelled"
                            )))
                        } else {
                            finish(.failure(.custom(
                                code: "stream_no_terminal",
                                detail: "dispatch stream ended without a terminal item"
                            )))
                        }
                    }
                }
            }

            continuation.onTermination = { _ in
                work.cancel()
            }
        }
    }
}
