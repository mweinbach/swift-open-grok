// RhaiInterpreter.swift
//
// Evaluator for the supported Rhai subset, wired to the host seam and the run
// journal. Port of crates/codegen/xai-workflow/src/engine.rs.
//
// Two distinctions from engine.rs drive most of the design here:
//
//   * Catchable vs terminal. Rhai's `ErrorRuntime` can be caught by a script's
//     `try`/`catch`; `ErrorTerminated` (complete, pause, budget, cancel, fatal)
//     cannot. `RhaiRuntimeError` and `RhaiControlFlow` keep that split, and a
//     `catch` handler only ever intercepts the former.
//   * Journaled vs emitted. Every result-bearing host call consumes a sequence
//     number and is replayed from the journal on resume; `phase`/`log`/
//     `telemetry` are fire-and-forget and carry a `replayed` flag instead.

import Foundation
import OpenGrokShared

// MARK: - Errors and control flow

/// A script-visible error. `try { ... } catch (e) { ... }` binds `e` to
/// `message`, matching upstream, where the caught value is the raw host or
/// runtime message rather than a structured object.
public struct RhaiRuntimeError: Error, Sendable, CustomStringConvertible {
    public var message: String
    public var position: RhaiSourcePosition

    public init(_ message: String, at position: RhaiSourcePosition = .none) {
        self.message = message
        self.position = position
    }

    public var description: String {
        position == .none ? message : "\(message) (\(position))"
    }
}

/// Non-catchable flow. `complete`/`pause`/`budget`/`cancelled`/`fatal` end the
/// run; `breakLoop`/`continueLoop`/`returnValue` are consumed by the nearest
/// enclosing loop or function and never escape the script.
enum RhaiControlFlow: Error {
    case complete(JSONValue)
    case pause(RhaiPauseKind, String)
    case budget(String)
    case cancelled
    case fatal(String)
    case breakLoop
    case continueLoop
    case returnValue(RhaiValue)
}

// MARK: - Scope

/// Lexically scoped variable storage. Rhai shadows rather than errors on a
/// repeated `let` in an inner block, so a frame stack is enough.
final class RhaiScope {
    private var frames: [[String: RhaiValue]]

    init(globals: [String: RhaiValue] = [:]) {
        frames = [globals]
    }

    func push() { frames.append([:]) }

    func pop() { if frames.count > 1 { frames.removeLast() } }

    func declare(_ name: String, _ value: RhaiValue) {
        frames[frames.count - 1][name] = value
    }

    func lookup(_ name: String) -> RhaiValue? {
        for frame in frames.reversed() {
            if let value = frame[name] { return value }
        }
        return nil
    }

    @discardableResult
    func assign(_ name: String, _ value: RhaiValue) -> Bool {
        for index in frames.indices.reversed() where frames[index][name] != nil {
            frames[index][name] = value
            return true
        }
        return false
    }

    /// The flattened view a closure captures at creation.
    var flattened: [String: RhaiValue] {
        var result: [String: RhaiValue] = [:]
        for frame in frames {
            for (key, value) in frame { result[key] = value }
        }
        return result
    }
}

// MARK: - Interpreter

public struct RhaiInterpreterLimits: Sendable {
    /// engine.rs:23 — the operation ceiling that stops a runaway script.
    public var maxOperations: UInt64 = 100_000_000
    /// engine.rs:121
    public var maxCallDepth: Int = 64
    /// engine.rs:124
    public var maxArraySize: Int = 65_536
    /// engine.rs:125
    public var maxMapSize: Int = 65_536

    public init() {}
}

/// Executes a parsed program. One instance per run; not `Sendable` by design,
/// since it owns mutable interpreter state and is driven from a single task.
final class RhaiInterpreter {
    private let program: RhaiProgram
    private let host: any RhaiWorkflowHost
    private let journal: RhaiJournal
    private let cancellation: RhaiCancellationToken
    private let limits: RhaiInterpreterLimits

    private var scope: RhaiScope
    private var sequence: UInt64 = 0
    private var operations: UInt64 = 0
    private var callDepth = 0

    init(
        program: RhaiProgram,
        arguments: JSONValue,
        host: any RhaiWorkflowHost,
        journal: RhaiJournal,
        cancellation: RhaiCancellationToken,
        limits: RhaiInterpreterLimits
    ) {
        self.program = program
        self.host = host
        self.journal = journal
        self.cancellation = cancellation
        self.limits = limits
        self.scope = RhaiScope(globals: ["args": RhaiValue.from(json: arguments)])
    }

    /// Runs the program to a terminal outcome. The value of the last statement
    /// becomes the result when the script falls off the end without calling
    /// `complete()` (engine.rs:182).
    func run() async -> RhaiWorkflowOutcome {
        do {
            var last = RhaiValue.unit
            for statement in program.statements {
                last = try await execute(statement)
            }
            return .completed(result: last.json)
        } catch let flow as RhaiControlFlow {
            switch flow {
            case .complete(let result): return .completed(result: result)
            case .pause(let kind, let message): return .paused(kind: kind, message: message)
            case .budget(let message): return .budgetExceeded(message: message)
            case .cancelled: return .cancelled
            case .fatal(let error): return .failed(error: error)
            case .breakLoop: return .failed(error: "`break` outside of a loop")
            case .continueLoop: return .failed(error: "`continue` outside of a loop")
            case .returnValue(let value): return .completed(result: value.json)
            }
        } catch let error as RhaiRuntimeError {
            return .failed(error: rhaiWithHint("Runtime error: \(error.description)"))
        } catch {
            return .failed(error: rhaiWithHint(String(describing: error)))
        }
    }

    // MARK: Budgets

    private func tick(_ position: RhaiSourcePosition) throws {
        if cancellation.isCancelled { throw RhaiControlFlow.cancelled }
        operations += 1
        if operations > limits.maxOperations {
            throw RhaiControlFlow.fatal(
                "workflow exceeded the maximum of \(limits.maxOperations) operations"
            )
        }
    }

    /// engine.rs:50 — reserve `count` consecutive journal sequence numbers,
    /// refusing past the host-call ceiling. The refusal is fatal rather than
    /// catchable so a script cannot loop past its own limit.
    private func reserveSequences(_ count: Int) throws -> Range<UInt64> {
        let end = sequence.addingReportingOverflow(UInt64(count))
        guard !end.overflow else {
            throw RhaiControlFlow.fatal("workflow host-call count overflowed")
        }
        guard end.partialValue <= rhaiMaxHostCalls else {
            throw RhaiControlFlow.fatal(
                "workflow exceeded the maximum of \(rhaiMaxHostCalls) result-bearing host calls"
            )
        }
        let start = sequence
        sequence = end.partialValue
        return start..<end.partialValue
    }

    private func nextSequence() throws -> UInt64 {
        try reserveSequences(1).lowerBound
    }

    // MARK: Statements

    @discardableResult
    private func execute(_ statement: RhaiStatement) async throws -> RhaiValue {
        switch statement {
        case .declaration(let name, let value, _, let position):
            try tick(position)
            let resolved: RhaiValue = if let value { try await evaluate(value) } else { .unit }
            scope.declare(name, resolved)
            return .unit

        case .assignment(let target, let op, let value, let position):
            try tick(position)
            let incoming = try await evaluate(value)
            let resolved: RhaiValue
            if op == "=" {
                resolved = incoming
            } else {
                let existing = try await evaluate(target)
                resolved = try apply(
                    operator: String(op.dropLast()),
                    left: existing,
                    right: incoming,
                    position: position
                )
            }
            try await assign(to: target, value: resolved)
            return .unit

        case .expression(let expression):
            return try await evaluate(expression)

        case .conditional(let condition, let then, let otherwise, let position):
            try tick(position)
            if try await truth(of: condition) {
                return try await execute(block: then)
            }
            if let otherwise { return try await execute(block: otherwise) }
            return .unit

        case .whileLoop(let condition, let body, let position):
            while try await truth(of: condition) {
                try tick(position)
                do {
                    _ = try await execute(block: body)
                } catch RhaiControlFlow.breakLoop {
                    break
                } catch RhaiControlFlow.continueLoop {
                    continue
                }
            }
            return .unit

        case .loopForever(let body, let position):
            while true {
                try tick(position)
                do {
                    _ = try await execute(block: body)
                } catch RhaiControlFlow.breakLoop {
                    break
                } catch RhaiControlFlow.continueLoop {
                    continue
                }
            }
            return .unit

        case .forLoop(let variable, let sequenceExpression, let body, let position):
            try tick(position)
            let sequenceValue = try await evaluate(sequenceExpression)
            let items: [RhaiValue]
            switch sequenceValue {
            case .array(let values):
                items = values
            case .map(let fields):
                items = fields.keys.sorted().map { RhaiValue.string($0) }
            case .unit:
                // Iterating a missing field is a common shape in the shipped
                // workflows; upstream errors, and so do we, but with a message
                // that says which shape was expected.
                throw RhaiRuntimeError(
                    "`for` expects an array or range but found `()` — guard with `!= ()` first",
                    at: position
                )
            default:
                throw RhaiRuntimeError(
                    "`for` expects an array or range but found a `\(sequenceValue.typeName)`",
                    at: position
                )
            }
            scope.push()
            defer { scope.pop() }
            for item in items {
                try tick(position)
                scope.declare(variable, item)
                do {
                    _ = try await execute(block: body)
                } catch RhaiControlFlow.breakLoop {
                    break
                } catch RhaiControlFlow.continueLoop {
                    continue
                }
            }
            return .unit

        case .breakLoop:
            throw RhaiControlFlow.breakLoop

        case .continueLoop:
            throw RhaiControlFlow.continueLoop

        case .returnValue(let expression, _):
            let value: RhaiValue = if let expression { try await evaluate(expression) } else { .unit }
            throw RhaiControlFlow.returnValue(value)

        case .tryCatch(let body, let errorName, let handler, let position):
            try tick(position)
            do {
                return try await execute(block: body)
            } catch let error as RhaiRuntimeError {
                scope.push()
                defer { scope.pop() }
                if let errorName { scope.declare(errorName, .string(error.message)) }
                return try await execute(block: handler)
            }

        case .block(let block, let position):
            try tick(position)
            return try await execute(block: block)

        case .function:
            // Hoisted at parse time; the declaration itself evaluates to unit.
            return .unit
        }
    }

    private func execute(block: RhaiBlock) async throws -> RhaiValue {
        scope.push()
        defer { scope.pop() }
        var last = RhaiValue.unit
        for statement in block.statements {
            last = try await execute(statement)
        }
        return last
    }

    private func truth(of expression: RhaiExpression) async throws -> Bool {
        let value = try await evaluate(expression)
        guard case .bool(let flag) = value else {
            throw RhaiRuntimeError(
                "expected a boolean condition but found a `\(value.typeName)`",
                at: expression.position
            )
        }
        return flag
    }

    // MARK: Assignment targets

    private func assign(to target: RhaiExpression, value: RhaiValue) async throws {
        switch target {
        case .identifier(let name, let position):
            guard scope.assign(name, value) else {
                throw RhaiRuntimeError("variable `\(name)` is not defined", at: position)
            }
        case .member(let base, let name, let position):
            var container = try await evaluate(base)
            guard case .map(var fields) = container else {
                throw RhaiRuntimeError(
                    "cannot set field `\(name)` on a `\(container.typeName)`",
                    at: position
                )
            }
            fields[name] = value
            container = .map(fields)
            try await assign(to: base, value: container)
        case .index(let base, let indexExpression, let position):
            let container = try await evaluate(base)
            let indexValue = try await evaluate(indexExpression)
            switch (container, indexValue) {
            case (.array(var items), .int(let offset)):
                guard offset >= 0, Int(offset) < items.count else {
                    throw RhaiRuntimeError("array index out of bounds: \(offset)", at: position)
                }
                items[Int(offset)] = value
                try await assign(to: base, value: .array(items))
            case (.map(var fields), .string(let key)):
                fields[key] = value
                try await assign(to: base, value: .map(fields))
            default:
                throw RhaiRuntimeError(
                    "cannot index a `\(container.typeName)` with a `\(indexValue.typeName)`",
                    at: position
                )
            }
        default:
            throw RhaiRuntimeError("expression is not assignable", at: target.position)
        }
    }

    // MARK: Expressions

    private func evaluate(_ expression: RhaiExpression) async throws -> RhaiValue {
        try tick(expression.position)

        switch expression {
        case .unit:
            return .unit
        case .boolean(let value, _):
            return .bool(value)
        case .integer(let value, _):
            return .int(value)
        case .float(let value, _):
            return .float(value)
        case .string(let value, _):
            return .string(value)

        case .identifier(let name, let position):
            guard let value = scope.lookup(name) else {
                throw RhaiRuntimeError("variable `\(name)` is not defined", at: position)
            }
            return value

        case .array(let items, let position):
            var values: [RhaiValue] = []
            values.reserveCapacity(items.count)
            for item in items { values.append(try await evaluate(item)) }
            guard values.count <= limits.maxArraySize else {
                throw RhaiRuntimeError("array exceeds the maximum size", at: position)
            }
            return .array(values)

        case .map(let entries, let position):
            var fields: [String: RhaiValue] = [:]
            for entry in entries { fields[entry.key] = try await evaluate(entry.value) }
            guard fields.count <= limits.maxMapSize else {
                throw RhaiRuntimeError("map exceeds the maximum size", at: position)
            }
            return .map(fields)

        case .unary(let op, let operand, let position):
            let value = try await evaluate(operand)
            switch (op, value) {
            case ("!", .bool(let flag)):
                return .bool(!flag)
            case ("-", .int(let number)):
                return .int(0 &- number)
            case ("-", .float(let number)):
                return .float(-number)
            default:
                throw RhaiRuntimeError(
                    "unary `\(op)` is not defined for a `\(value.typeName)`",
                    at: position
                )
            }

        case .logical(let op, let left, let right, let position):
            let leftValue = try await evaluate(left)
            guard case .bool(let leftFlag) = leftValue else {
                throw RhaiRuntimeError(
                    "`\(op)` expects a boolean but found a `\(leftValue.typeName)`",
                    at: position
                )
            }
            if op == "&&", !leftFlag { return .bool(false) }
            if op == "||", leftFlag { return .bool(true) }
            let rightValue = try await evaluate(right)
            guard case .bool(let rightFlag) = rightValue else {
                throw RhaiRuntimeError(
                    "`\(op)` expects a boolean but found a `\(rightValue.typeName)`",
                    at: position
                )
            }
            return .bool(rightFlag)

        case .binary(let op, let left, let right, let position):
            let leftValue = try await evaluate(left)
            let rightValue = try await evaluate(right)
            return try apply(operator: op, left: leftValue, right: rightValue, position: position)

        case .range(let from, let to, let inclusive, let position):
            let start = try await evaluate(from)
            let end = try await evaluate(to)
            guard case .int(let lower) = start, case .int(let upper) = end else {
                throw RhaiRuntimeError("a range needs integer bounds", at: position)
            }
            let last = inclusive ? upper : upper - 1
            guard lower <= last else { return .array([]) }
            guard last - lower < Int64(limits.maxArraySize) else {
                throw RhaiRuntimeError("range exceeds the maximum array size", at: position)
            }
            return .array((lower...last).map { RhaiValue.int($0) })

        case .index(let target, let indexExpression, let position):
            let container = try await evaluate(target)
            let indexValue = try await evaluate(indexExpression)
            switch (container, indexValue) {
            case (.array(let items), .int(let offset)):
                guard offset >= 0, Int(offset) < items.count else {
                    throw RhaiRuntimeError("array index out of bounds: \(offset)", at: position)
                }
                return items[Int(offset)]
            case (.map(let fields), .string(let key)):
                return fields[key] ?? .unit
            case (.string(let text), .int(let offset)):
                let characters = Array(text)
                guard offset >= 0, Int(offset) < characters.count else {
                    throw RhaiRuntimeError("string index out of bounds: \(offset)", at: position)
                }
                return .character(characters[Int(offset)])
            default:
                throw RhaiRuntimeError(
                    "cannot index a `\(container.typeName)` with a `\(indexValue.typeName)`",
                    at: position
                )
            }

        case .member(let target, let name, let position):
            let container = try await evaluate(target)
            guard case .map(let fields) = container else {
                // Rhai's own message for this, so the authoring hint in
                // rhaiWithHint still fires for the string-indexing mistake.
                throw RhaiRuntimeError(
                    "getter is not registered for type '\(container.typeName)': .\(name)",
                    at: position
                )
            }
            return fields[name] ?? .unit

        case .conditional(let condition, let then, let otherwise, _):
            if try await truth(of: condition) {
                return try await execute(block: then)
            }
            if let otherwise { return try await execute(block: otherwise) }
            return .unit

        case .block(let block, _):
            return try await execute(block: block)

        case .closure(let parameters, let body, _):
            return .closure(RhaiClosureValue(
                parameters: parameters,
                body: body,
                captured: scope.flattened
            ))

        case .call(let name, let arguments, let position):
            return try await call(name: name, arguments: arguments, position: position)

        case .method(let target, let name, let arguments, let position):
            return try await callMethod(
                target: target,
                name: name,
                arguments: arguments,
                position: position
            )
        }
    }

    // MARK: Operators

    private func apply(
        operator op: String,
        left: RhaiValue,
        right: RhaiValue,
        position: RhaiSourcePosition
    ) throws -> RhaiValue {
        switch op {
        case "==":
            return .bool(left.rhaiEquals(right))
        case "!=":
            return .bool(!left.rhaiEquals(right))
        case "<", "<=", ">", ">=":
            if case .string(let lhs) = left, case .string(let rhs) = right {
                return .bool(compare(op, lhs < rhs, lhs == rhs))
            }
            guard let lhs = left.doubleValue, let rhs = right.doubleValue else {
                throw RhaiRuntimeError(
                    "`\(op)` is not defined between a `\(left.typeName)` and a `\(right.typeName)`",
                    at: position
                )
            }
            return .bool(compare(op, lhs < rhs, lhs == rhs))
        case "+":
            // String concatenation wins over arithmetic when either side is a
            // string, which is what makes `"count: " + n.to_string()` and the
            // looser `"caught:" + e` in the shipped workflows both work.
            if case .string(let lhs) = left { return .string(lhs + right.displayText) }
            if case .string(let rhs) = right { return .string(left.displayText + rhs) }
            if case .array(let lhs) = left, case .array(let rhs) = right { return .array(lhs + rhs) }
            if case .map(let lhs) = left, case .map(let rhs) = right {
                return .map(lhs.merging(rhs) { _, new in new })
            }
            return try arithmetic(op, left, right, position)
        case "-", "*", "/", "%":
            return try arithmetic(op, left, right, position)
        default:
            throw RhaiRuntimeError("operator `\(op)` is not supported", at: position)
        }
    }

    private func compare(_ op: String, _ isLess: Bool, _ isEqual: Bool) -> Bool {
        switch op {
        case "<": return isLess
        case "<=": return isLess || isEqual
        case ">": return !isLess && !isEqual
        default: return !isLess
        }
    }

    private func arithmetic(
        _ op: String,
        _ left: RhaiValue,
        _ right: RhaiValue,
        _ position: RhaiSourcePosition
    ) throws -> RhaiValue {
        if case .int(let lhs) = left, case .int(let rhs) = right {
            switch op {
            case "+": return .int(lhs &+ rhs)
            case "-": return .int(lhs &- rhs)
            case "*": return .int(lhs &* rhs)
            case "/":
                guard rhs != 0 else { throw RhaiRuntimeError("division by zero", at: position) }
                return .int(lhs / rhs)
            case "%":
                guard rhs != 0 else { throw RhaiRuntimeError("modulo by zero", at: position) }
                return .int(lhs % rhs)
            default: break
            }
        }
        guard let lhs = left.doubleValue, let rhs = right.doubleValue else {
            throw RhaiRuntimeError(
                "`\(op)` is not defined between a `\(left.typeName)` and a `\(right.typeName)`",
                at: position
            )
        }
        switch op {
        case "+": return .float(lhs + rhs)
        case "-": return .float(lhs - rhs)
        case "*": return .float(lhs * rhs)
        case "/":
            guard rhs != 0 else { throw RhaiRuntimeError("division by zero", at: position) }
            return .float(lhs / rhs)
        case "%":
            guard rhs != 0 else { throw RhaiRuntimeError("modulo by zero", at: position) }
            return .float(lhs.truncatingRemainder(dividingBy: rhs))
        default:
            throw RhaiRuntimeError("operator `\(op)` is not supported", at: position)
        }
    }

    // MARK: Calls

    private func call(
        name: String,
        arguments: [RhaiExpression],
        position: RhaiSourcePosition
    ) async throws -> RhaiValue {
        // Script-defined functions shadow nothing; upstream registers host
        // functions first, but no shipped workflow redefines one.
        if let function = program.functions[name] {
            var values: [RhaiValue] = []
            for argument in arguments { values.append(try await evaluate(argument)) }
            return try await invoke(function: function, arguments: values, position: position)
        }

        if let value = scope.lookup(name), case .closure(let closure) = value {
            var values: [RhaiValue] = []
            for argument in arguments { values.append(try await evaluate(argument)) }
            return try await invoke(closure: closure, arguments: values, position: position)
        }

        var values: [RhaiValue] = []
        for argument in arguments { values.append(try await evaluate(argument)) }
        return try await callBuiltin(name: name, arguments: values, position: position)
    }

    private func invoke(
        function: RhaiFunction,
        arguments: [RhaiValue],
        position: RhaiSourcePosition
    ) async throws -> RhaiValue {
        guard arguments.count == function.parameters.count else {
            throw RhaiRuntimeError(
                "`\(function.name)` takes \(function.parameters.count) argument(s) but got \(arguments.count)",
                at: position
            )
        }
        guard callDepth < limits.maxCallDepth else {
            throw RhaiRuntimeError("call stack depth exceeded", at: position)
        }
        callDepth += 1
        defer { callDepth -= 1 }

        // A function body sees only its parameters and globals, not the
        // caller's locals — Rhai script functions are not closures.
        let saved = scope
        scope = RhaiScope(globals: ["args": saved.lookup("args") ?? .unit])
        scope.push()
        for (name, value) in zip(function.parameters, arguments) { scope.declare(name, value) }
        defer { scope = saved }

        do {
            return try await execute(block: function.body)
        } catch RhaiControlFlow.returnValue(let value) {
            return value
        }
    }

    private func invoke(
        closure: RhaiClosureValue,
        arguments: [RhaiValue],
        position: RhaiSourcePosition
    ) async throws -> RhaiValue {
        guard arguments.count >= closure.parameters.count else {
            throw RhaiRuntimeError(
                "closure takes \(closure.parameters.count) argument(s) but got \(arguments.count)",
                at: position
            )
        }
        guard callDepth < limits.maxCallDepth else {
            throw RhaiRuntimeError("call stack depth exceeded", at: position)
        }
        callDepth += 1
        defer { callDepth -= 1 }

        let saved = scope
        scope = RhaiScope(globals: closure.captured)
        scope.push()
        for (name, value) in zip(closure.parameters, arguments) { scope.declare(name, value) }
        defer { scope = saved }

        do {
            return try await execute(block: closure.body)
        } catch RhaiControlFlow.returnValue(let value) {
            return value
        }
    }

    // MARK: Method calls

    private func callMethod(
        target: RhaiExpression,
        name: String,
        arguments: [RhaiExpression],
        position: RhaiSourcePosition
    ) async throws -> RhaiValue {
        var receiver = try await evaluate(target)
        var values: [RhaiValue] = []
        for argument in arguments { values.append(try await evaluate(argument)) }

        let outcome = try await RhaiBuiltins.method(
            name: name,
            receiver: &receiver,
            arguments: values,
            position: position,
            invokeClosure: { [weak self] closure, closureArguments in
                guard let self else { throw RhaiRuntimeError("interpreter released", at: position) }
                return try await self.invoke(
                    closure: closure,
                    arguments: closureArguments,
                    position: position
                )
            }
        )
        // Rhai's mutating methods (`push`, `trim`, ...) write through the
        // receiver, so the updated value has to go back to its variable. That
        // is exactly what the shipped `fn trimmed(s) { s.trim(); s }` relies on.
        if outcome.mutated, isAssignable(target) {
            try await assign(to: target, value: receiver)
        }
        return outcome.value
    }

    private func isAssignable(_ expression: RhaiExpression) -> Bool {
        switch expression {
        case .identifier: return true
        case .index(let target, _, _), .member(let target, _, _): return isAssignable(target)
        default: return false
        }
    }

    // MARK: Builtin and host functions

    private func callBuiltin(
        name: String,
        arguments: [RhaiValue],
        position: RhaiSourcePosition
    ) async throws -> RhaiValue {
        switch name {
        // engine.rs:128 — deliberately unavailable, with the reason.
        case "timestamp":
            throw RhaiRuntimeError(
                "timestamp() is unavailable: workflow scripts must be deterministic (wall-clock "
                    + "time breaks resume). Pass timestamps in via `args` instead.",
                at: position
            )
        case "sleep":
            throw RhaiRuntimeError(
                "sleep() is unavailable in workflow scripts — host calls already block until "
                    + "their work finishes.",
                at: position
            )
        case "exit":
            throw RhaiRuntimeError(
                "exit() is unavailable — end a workflow with complete(value) or pause(kind, msg).",
                at: position
            )
        case "eval":
            throw RhaiRuntimeError("eval() is disabled in workflow scripts", at: position)

        case "complete":
            throw RhaiControlFlow.complete(arguments.first?.json ?? .null)

        case "pause":
            let kindText = try string(arguments, 0, "pause", position)
            let message = try string(arguments, 1, "pause", position)
            guard let kind = RhaiPauseKind.parse(kindText) else {
                throw RhaiRuntimeError("unknown pause kind: \(kindText)", at: position)
            }
            throw RhaiControlFlow.pause(kind, message)

        case "await_user":
            return try await awaitUser(arguments: arguments, position: position)

        case "escalate":
            return try await escalate(arguments: arguments, position: position)

        case "agent":
            return try await agent(arguments: arguments, position: position)

        case "parallel":
            return try await parallel(arguments: arguments, position: position)

        case "phase":
            let title = try string(arguments, 0, "phase", position)
            await host.phase(title: title, replayed: journal.covers(sequence))
            return .unit

        case "log", "print", "debug":
            let message = arguments.first?.displayText ?? ""
            await host.log(message: message, replayed: journal.covers(sequence))
            return .unit

        case "telemetry_event":
            let eventName = try string(arguments, 0, "telemetry_event", position)
            let fields = arguments.count > 1 ? arguments[1].json : JSONValue.object([:])
            await host.telemetry(name: eventName, fields: fields, replayed: journal.covers(sequence))
            return .unit

        case "budget":
            let value = try await hostCall(kind: "budget", payload: .null, position: position) {
                .success(try await self.host.budgetState().json)
            }
            return RhaiValue.from(json: value)

        case "render_template":
            let templateName = try string(arguments, 0, "render_template", position)
            let variables = arguments.count > 1 ? arguments[1].json : JSONValue.object([:])
            let payload = JSONValue.object(["name": .string(templateName), "vars": variables])
            let value = try await hostCall(kind: "render_template", payload: payload, position: position) {
                .success(.string(try await self.host.renderTemplate(name: templateName, variables: variables)))
            }
            return RhaiValue.from(json: value)

        case "write_scratch_file":
            let fileName = try string(arguments, 0, "write_scratch_file", position)
            let content = try string(arguments, 1, "write_scratch_file", position)
            let payload = JSONValue.object(["name": .string(fileName), "content": .string(content)])
            let value = try await hostCall(kind: "write_scratch_file", payload: payload, position: position) {
                .success(.string(try await self.host.writeScratchFile(name: fileName, content: content)))
            }
            return RhaiValue.from(json: value)

        case "read_scratch_file":
            let fileName = try string(arguments, 0, "read_scratch_file", position)
            let payload = JSONValue.object(["name": .string(fileName)])
            let value = try await hostCall(kind: "read_scratch_file", payload: payload, position: position) {
                .success(.string(try await self.host.readScratchFile(name: fileName)))
            }
            return RhaiValue.from(json: value)

        case "git_diff_since":
            let commit = try string(arguments, 0, "git_diff_since", position)
            let payload = JSONValue.object(["commit": .string(commit)])
            let value = try await hostCall(kind: "git_diff_since", payload: payload, position: position) {
                .success(.string(try await self.host.gitDiffSince(commit: commit)))
            }
            return RhaiValue.from(json: value)

        default:
            return try RhaiBuiltins.function(name: name, arguments: arguments, position: position)
        }
    }

    private func string(
        _ arguments: [RhaiValue],
        _ index: Int,
        _ function: String,
        _ position: RhaiSourcePosition
    ) throws -> String {
        guard index < arguments.count else {
            throw RhaiRuntimeError("\(function)() is missing an argument", at: position)
        }
        guard case .string(let text) = arguments[index] else {
            throw RhaiRuntimeError(
                "\(function)() expects a string but got a `\(arguments[index].typeName)`",
                at: position
            )
        }
        return text
    }

    // MARK: Journaled host calls

    /// engine.rs:245 — the shared shape of every result-bearing host call:
    /// hash the request, take a sequence number, replay if the journal already
    /// covers it, otherwise go live and record the answer.
    private func hostCall(
        kind: String,
        payload: JSONValue,
        position: RhaiSourcePosition,
        perform: () async throws -> Result<JSONValue, RhaiHostError>
    ) async throws -> JSONValue {
        let hash = rhaiRequestHash(kind: kind, payload: payload)
        let seq = try nextSequence()

        do {
            if let recorded = try journal.replay(seq: seq, kind: kind, reqHash: hash) {
                if let message = recorded[rhaiHostErrorKey]?.stringValue {
                    throw RhaiRuntimeError(message, at: position)
                }
                return recorded
            }
        } catch let error as RhaiJournalError {
            throw RhaiControlFlow.fatal(error.description)
        }

        let reply: Result<JSONValue, RhaiHostError>
        do {
            reply = try await perform()
        } catch let error as RhaiHostError {
            reply = .failure(error)
        } catch let error as RhaiControlFlow {
            throw error
        } catch {
            reply = .failure(.failed(String(describing: error)))
        }

        switch reply {
        case .success(let value):
            try record(seq: seq, kind: kind, hash: hash, value: value)
            return value
        case .failure(.agentCallQuotaExceeded(let requested, let maximum)):
            // Catchable: the script may decide to fan out less and continue.
            throw RhaiRuntimeError(
                "workflow agent-call quota exceeded: requested \(requested), maximum \(maximum)",
                at: position
            )
        case .failure(.budgetExceeded):
            throw RhaiControlFlow.budget("workflow agent budget exceeded")
        case .failure(.cancelled):
            throw RhaiControlFlow.cancelled
        case .failure(.unsupported(let message)), .failure(.failed(let message)):
            // Journaled as a sentinel so a resumed run replays the same failure
            // and takes the same `catch` branch it took the first time.
            try record(seq: seq, kind: kind, hash: hash, value: rhaiHostErrorSentinel(message))
            throw RhaiRuntimeError(message, at: position)
        }
    }

    private func record(seq: UInt64, kind: String, hash: String, value: JSONValue) throws {
        do {
            try journal.record(seq: seq, kind: kind, reqHash: hash, result: value)
        } catch let error as RhaiJournalError {
            throw RhaiControlFlow.fatal(error.description)
        }
    }

    // MARK: Pause gates

    /// engine.rs:723 — pause once, then sail past the gate on resume.
    private func awaitUser(arguments: [RhaiValue], position: RhaiSourcePosition) async throws -> RhaiValue {
        let kindText = try string(arguments, 0, "await_user", position)
        let message = try string(arguments, 1, "await_user", position)
        guard let kind = RhaiPauseKind.parse(kindText) else {
            throw RhaiRuntimeError("unknown pause kind: \(kindText)", at: position)
        }
        let payload = JSONValue.object(["kind": .string(kindText), "message": .string(message)])
        let hash = rhaiRequestHash(kind: "await_user", payload: payload)
        let seq = try nextSequence()
        do {
            if try journal.replay(seq: seq, kind: "await_user", reqHash: hash) != nil {
                return .unit
            }
        } catch let error as RhaiJournalError {
            throw RhaiControlFlow.fatal(error.description)
        }
        try record(seq: seq, kind: "await_user", hash: hash, value: .null)
        throw RhaiControlFlow.pause(kind, message)
    }

    /// engine.rs:744 — pause and ask the caller to fix something, then hand the
    /// script whatever note the caller supplied on resume (or `""` when they
    /// resumed without one).
    private func escalate(arguments: [RhaiValue], position: RhaiSourcePosition) async throws -> RhaiValue {
        let message = try string(arguments, 0, "escalate", position)
        let payload = JSONValue.object(["message": .string(message)])
        let hash = rhaiRequestHash(kind: rhaiEscalateKind, payload: payload)
        let seq = try nextSequence()

        let recorded: JSONValue?
        do {
            recorded = try journal.replay(seq: seq, kind: rhaiEscalateKind, reqHash: hash)
        } catch let error as RhaiJournalError {
            throw RhaiControlFlow.fatal(error.description)
        }

        switch recorded {
        case .some(.string(let note)):
            return .string(note)
        case .some:
            // Resumed without a note. Rewrite the null placeholder to "" so a
            // trailing null always means "still waiting here" and a late note
            // can never answer a question the script already moved past.
            do {
                try journal.fulfillPendingEscalation(note: "")
            } catch let error as RhaiJournalError {
                throw RhaiControlFlow.fatal(error.description)
            }
            return .string("")
        case .none:
            try record(seq: seq, kind: rhaiEscalateKind, hash: hash, value: .null)
            throw RhaiControlFlow.pause(.verification, message)
        }
    }

    // MARK: Agents

    /// engine.rs:413 — one agent, reserved before it runs and released again if
    /// it ends in a state a resume would otherwise be charged for twice.
    private func agent(arguments: [RhaiValue], position: RhaiSourcePosition) async throws -> RhaiValue {
        let options = try agentOptions(arguments: arguments, position: position)
        let payload = options.json
        let hash = rhaiRequestHash(kind: "spawn_agent", payload: payload)

        let isLive: Bool
        do {
            isLive = try journal.replay(seq: sequence, kind: "spawn_agent", reqHash: hash) == nil
        } catch let error as RhaiJournalError {
            throw RhaiControlFlow.fatal(error.description)
        }
        if isLive { try await reserveAgentCalls(1, position: position) }

        do {
            let value = try await hostCall(kind: "spawn_agent", payload: payload, position: position) {
                .success(try await self.host.spawnAgent(options).json)
            }
            return RhaiValue.from(json: value)
        } catch {
            if isLive, isResumableTerminal(error) {
                await host.releaseAgentCalls(1)
            }
            throw error
        }
    }

    private func agentOptions(
        arguments: [RhaiValue],
        position: RhaiSourcePosition
    ) throws -> RhaiAgentOptions {
        var options: RhaiAgentOptions
        switch arguments.count {
        case 1:
            if case .string(let prompt) = arguments[0] {
                options = RhaiAgentOptions(prompt: prompt)
            } else if case .map = arguments[0] {
                options = try RhaiAgentOptions.fromJSON(arguments[0].json)
            } else {
                throw RhaiRuntimeError(
                    "agent() expects a prompt string or an options map",
                    at: position
                )
            }
        case 2:
            guard case .string(let prompt) = arguments[0], case .map = arguments[1] else {
                throw RhaiRuntimeError(
                    "agent(prompt, options) expects a string and a map",
                    at: position
                )
            }
            options = try RhaiAgentOptions.fromJSON(arguments[1].json)
            options.prompt = prompt
        default:
            throw RhaiRuntimeError("agent() takes one or two arguments", at: position)
        }
        guard !options.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RhaiRuntimeError("agent prompt must not be empty", at: position)
        }
        return options
    }

    /// engine.rs:480 — the fan-out barrier. Every sibling gets its own sequence
    /// number, results come back in input order, and a sibling that failed
    /// softly lands in the array as `()` rather than killing the batch.
    private func parallel(arguments: [RhaiValue], position: RhaiSourcePosition) async throws -> RhaiValue {
        guard let items = arguments.first?.arrayValue else {
            throw RhaiRuntimeError("parallel() expects an array of option maps", at: position)
        }
        guard items.count <= rhaiMaxParallel else {
            throw RhaiRuntimeError(
                "parallel() accepts at most \(rhaiMaxParallel) items per call (got \(items.count))",
                at: position
            )
        }

        var requests: [(options: RhaiAgentOptions, hash: String)] = []
        requests.reserveCapacity(items.count)
        for item in items {
            guard case .map = item else {
                throw RhaiRuntimeError("parallel() items must be option maps", at: position)
            }
            var options = try RhaiAgentOptions.fromJSON(item.json)
            guard !options.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RhaiRuntimeError("agent prompt must not be empty", at: position)
            }
            requests.append((options, rhaiRequestHash(kind: "spawn_agent", payload: options.json)))
        }

        // Count the live spawns *before* reserving, so a resumed run is charged
        // only for the siblings it still has to execute.
        var probe = sequence
        var liveCount = 0
        for request in requests {
            do {
                if try journal.replay(seq: probe, kind: "spawn_agent", reqHash: request.hash) == nil {
                    liveCount += 1
                }
            } catch let error as RhaiJournalError {
                throw RhaiControlFlow.fatal(error.description)
            }
            probe += 1
        }
        try await reserveAgentCalls(UInt64(liveCount), position: position)

        enum Pending {
            case replayed(JSONValue)
            case live(seq: UInt64, hash: String, index: Int)
        }

        var pending: [Pending] = []
        var liveOptions: [RhaiAgentOptions] = []
        for request in requests {
            let seq = try reserveSequences(1).lowerBound
            do {
                if let recorded = try journal.replay(seq: seq, kind: "spawn_agent", reqHash: request.hash) {
                    pending.append(.replayed(recorded))
                } else {
                    pending.append(.live(seq: seq, hash: request.hash, index: liveOptions.count))
                    liveOptions.append(request.options)
                }
            } catch let error as RhaiJournalError {
                throw RhaiControlFlow.fatal(error.description)
            }
        }

        let liveResults = liveOptions.isEmpty ? [] : await host.spawnAgents(liveOptions)

        var resolved: [(live: (seq: UInt64, hash: String)?, value: JSONValue)] = []
        var terminalKind: String?
        var terminalError: Error?
        var resumableTerminal = false

        for entry in pending {
            switch entry {
            case .replayed(let value):
                if let kind = value[rhaiHostTerminalKey]?.stringValue {
                    if terminalKind == nil { terminalKind = kind }
                    if kind == rhaiTerminalBudget || kind == rhaiTerminalCancelled {
                        resumableTerminal = true
                    }
                    continue
                }
                if let message = value[rhaiHostErrorKey]?.stringValue {
                    if terminalError == nil { terminalError = RhaiRuntimeError(message, at: position) }
                    continue
                }
                resolved.append((nil, value))
            case .live(let seq, let hash, let index):
                let value: JSONValue
                switch liveResults[index] {
                case .success(let result):
                    value = result.json
                case .failure(.budgetExceeded):
                    if terminalKind == nil { terminalKind = rhaiTerminalBudget }
                    resumableTerminal = true
                    value = rhaiHostTerminalSentinel(rhaiTerminalBudget)
                case .failure(.cancelled):
                    if terminalKind == nil { terminalKind = rhaiTerminalCancelled }
                    resumableTerminal = true
                    value = rhaiHostTerminalSentinel(rhaiTerminalCancelled)
                case .failure:
                    // Soft failure: the sibling becomes `()` in the result
                    // array so the script can decide what a missing lens means.
                    value = .null
                }
                resolved.append(((seq, hash), value))
            }
        }

        if resumableTerminal {
            // Nothing is journaled: the whole panel re-runs after the cap is
            // raised, rather than half of it replaying and half going live.
            await host.releaseAgentCalls(UInt64(liveCount))
        } else {
            for entry in resolved {
                guard let live = entry.live else { continue }
                do {
                    try record(seq: live.seq, kind: "spawn_agent", hash: live.hash, value: entry.value)
                } catch {
                    if terminalError == nil { terminalError = error }
                    break
                }
            }
        }

        if let terminalKind {
            switch terminalKind {
            case rhaiTerminalBudget:
                throw RhaiControlFlow.budget("workflow agent budget exceeded")
            case rhaiTerminalCancelled:
                throw RhaiControlFlow.cancelled
            case rhaiTerminalDroppedReply:
                throw RhaiControlFlow.fatal("workflow host dropped reply")
            default:
                throw RhaiControlFlow.fatal("workflow journal contains an unknown terminal marker")
            }
        }
        if let terminalError { throw terminalError }

        return .array(resolved.map { RhaiValue.from(json: $0.value) })
    }

    /// engine.rs:350 — a quota refusal here is terminal, not catchable: the run
    /// stops so it can be resumed against a raised cap.
    private func reserveAgentCalls(_ count: UInt64, position: RhaiSourcePosition) async throws {
        guard count > 0 else { return }
        do {
            try await host.reserveAgentCalls(count)
        } catch RhaiHostError.agentCallQuotaExceeded(let requested, let maximum) {
            throw RhaiControlFlow.budget(
                "workflow agent budget exceeded: requested \(requested), maximum \(maximum)"
            )
        } catch RhaiHostError.cancelled {
            throw RhaiControlFlow.cancelled
        } catch RhaiHostError.budgetExceeded {
            throw RhaiControlFlow.budget("workflow agent budget exceeded")
        } catch let error as RhaiHostError {
            throw RhaiRuntimeError(error.scriptMessage, at: position)
        }
    }

    private func isResumableTerminal(_ error: Error) -> Bool {
        guard let flow = error as? RhaiControlFlow else { return false }
        switch flow {
        case .cancelled, .budget: return true
        default: return false
        }
    }
}
