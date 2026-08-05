// RhaiAST.swift
//
// The syntax tree for the supported Rhai subset. Kept as plain value types so
// the whole program is `Sendable` and a parsed script can be handed across
// concurrency domains (a closure value captures nodes by value).

import Foundation

public indirect enum RhaiExpression: Sendable {
    case unit(RhaiSourcePosition)
    case boolean(Bool, RhaiSourcePosition)
    case integer(Int64, RhaiSourcePosition)
    case float(Double, RhaiSourcePosition)
    case string(String, RhaiSourcePosition)
    case identifier(String, RhaiSourcePosition)
    case array([RhaiExpression], RhaiSourcePosition)
    /// A map literal preserves key order so a literal-only `meta` block can be
    /// validated in source order and report the first offending field.
    case map([(key: String, value: RhaiExpression)], RhaiSourcePosition)
    case unary(op: String, operand: RhaiExpression, position: RhaiSourcePosition)
    case binary(op: String, left: RhaiExpression, right: RhaiExpression, position: RhaiSourcePosition)
    /// `&&` and `||` are separate from `binary` because they must not evaluate
    /// their right operand when the left already decides the result.
    case logical(op: String, left: RhaiExpression, right: RhaiExpression, position: RhaiSourcePosition)
    case index(target: RhaiExpression, index: RhaiExpression, position: RhaiSourcePosition)
    case member(target: RhaiExpression, name: String, position: RhaiSourcePosition)
    case call(name: String, arguments: [RhaiExpression], position: RhaiSourcePosition)
    case method(target: RhaiExpression, name: String, arguments: [RhaiExpression], position: RhaiSourcePosition)
    case closure(parameters: [String], body: RhaiBlock, position: RhaiSourcePosition)
    /// `if` is an expression in Rhai: `let x = if c { a } else { b };`
    case conditional(condition: RhaiExpression, then: RhaiBlock, otherwise: RhaiBlock?, position: RhaiSourcePosition)
    case block(RhaiBlock, RhaiSourcePosition)
    case range(from: RhaiExpression, to: RhaiExpression, inclusive: Bool, position: RhaiSourcePosition)

    public var position: RhaiSourcePosition {
        switch self {
        case .unit(let position), .boolean(_, let position), .integer(_, let position),
             .float(_, let position), .string(_, let position), .identifier(_, let position),
             .array(_, let position), .map(_, let position), .block(_, let position):
            return position
        case .unary(_, _, let position), .binary(_, _, _, let position),
             .logical(_, _, _, let position), .index(_, _, let position),
             .member(_, _, let position), .call(_, _, let position),
             .method(_, _, _, let position), .closure(_, _, let position),
             .conditional(_, _, _, let position), .range(_, _, _, let position):
            return position
        }
    }
}

public struct RhaiBlock: Sendable {
    public var statements: [RhaiStatement]
    public var position: RhaiSourcePosition

    public init(statements: [RhaiStatement], position: RhaiSourcePosition) {
        self.statements = statements
        self.position = position
    }
}

public struct RhaiFunction: Sendable {
    public var name: String
    public var parameters: [String]
    public var body: RhaiBlock
    public var position: RhaiSourcePosition
}

public indirect enum RhaiStatement: Sendable {
    case declaration(name: String, value: RhaiExpression?, isConstant: Bool, position: RhaiSourcePosition)
    /// `target op= value`, where `target` must resolve to an assignable path
    /// (identifier, index, or member chain).
    case assignment(target: RhaiExpression, op: String, value: RhaiExpression, position: RhaiSourcePosition)
    case expression(RhaiExpression)
    case conditional(condition: RhaiExpression, then: RhaiBlock, otherwise: RhaiBlock?, position: RhaiSourcePosition)
    case whileLoop(condition: RhaiExpression, body: RhaiBlock, position: RhaiSourcePosition)
    case loopForever(body: RhaiBlock, position: RhaiSourcePosition)
    case forLoop(variable: String, sequence: RhaiExpression, body: RhaiBlock, position: RhaiSourcePosition)
    case breakLoop(RhaiSourcePosition)
    case continueLoop(RhaiSourcePosition)
    case returnValue(RhaiExpression?, RhaiSourcePosition)
    case tryCatch(body: RhaiBlock, errorName: String?, handler: RhaiBlock, position: RhaiSourcePosition)
    case block(RhaiBlock, RhaiSourcePosition)
    case function(RhaiFunction)
}

/// A parsed script: top-level statements plus the functions hoisted out of them
/// (Rhai's `fn` declarations are script-global regardless of where they appear).
public struct RhaiProgram: Sendable {
    public var statements: [RhaiStatement]
    public var functions: [String: RhaiFunction]

    public init(statements: [RhaiStatement], functions: [String: RhaiFunction]) {
        self.statements = statements
        self.functions = functions
    }
}
