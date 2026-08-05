// RhaiParser.swift
//
// Recursive-descent parser for the supported Rhai subset.
//
// Out-of-subset constructs (`switch`, `do`/`until`, `import`, `throw`, `this`,
// modules) are rejected with a diagnostic that names the construct rather than
// being skipped or approximated — a workflow script that parses here must mean
// the same thing it means under upstream Rhai.

import Foundation

public struct RhaiParser {
    private let tokens: [RhaiToken]
    private var index = 0

    public init(tokens: [RhaiToken]) {
        self.tokens = tokens
    }

    public static func parse(_ source: String) throws -> RhaiProgram {
        var parser = RhaiParser(tokens: try RhaiLexer.tokenize(source))
        return try parser.parseProgram()
    }

    // MARK: - Token helpers

    private var current: RhaiToken { tokens[index] }

    private var isAtEnd: Bool {
        if case .endOfFile = current.kind { return true }
        return false
    }

    private mutating func advance() -> RhaiToken {
        let token = tokens[index]
        if !isAtEnd { index += 1 }
        return token
    }

    private func check(symbol: String) -> Bool {
        if case .symbol(let value) = current.kind { return value == symbol }
        return false
    }

    private func check(keyword: String) -> Bool {
        if case .keyword(let value) = current.kind { return value == keyword }
        return false
    }

    private mutating func match(symbol: String) -> Bool {
        guard check(symbol: symbol) else { return false }
        _ = advance()
        return true
    }

    private mutating func match(keyword: String) -> Bool {
        guard check(keyword: keyword) else { return false }
        _ = advance()
        return true
    }

    private mutating func expect(symbol: String, context: String) throws {
        guard match(symbol: symbol) else {
            throw RhaiParseError(
                "expected `\(symbol)` \(context) but found `\(current.text)`",
                at: current.position
            )
        }
    }

    private mutating func expectIdentifier(context: String) throws -> String {
        guard case .identifier(let name) = current.kind else {
            throw RhaiParseError(
                "expected an identifier \(context) but found `\(current.text)`",
                at: current.position
            )
        }
        _ = advance()
        return name
    }

    // MARK: - Program

    public mutating func parseProgram() throws -> RhaiProgram {
        var statements: [RhaiStatement] = []
        var functions: [String: RhaiFunction] = [:]
        while !isAtEnd {
            let statement = try parseStatement()
            if case .function(let function) = statement {
                guard functions[function.name] == nil else {
                    throw RhaiParseError(
                        "function `\(function.name)` is declared more than once",
                        at: function.position
                    )
                }
                functions[function.name] = function
            }
            statements.append(statement)
        }
        return RhaiProgram(statements: statements, functions: functions)
    }

    // MARK: - Statements

    private mutating func parseStatement() throws -> RhaiStatement {
        let position = current.position

        if case .keyword(let keyword) = current.kind {
            switch keyword {
            case "switch", "do", "until", "import", "export", "private", "throw", "this":
                throw RhaiParseError(
                    "`\(keyword)` is outside the supported workflow-script subset",
                    at: position
                )
            case "let", "const":
                _ = advance()
                let isConstant = keyword == "const"
                let name = try expectIdentifier(context: "after `\(keyword)`")
                var value: RhaiExpression?
                if match(symbol: "=") {
                    value = try parseExpression()
                } else if isConstant {
                    throw RhaiParseError("`const \(name)` must be initialized", at: position)
                }
                _ = match(symbol: ";")
                return .declaration(name: name, value: value, isConstant: isConstant, position: position)
            case "fn":
                _ = advance()
                let name = try expectIdentifier(context: "after `fn`")
                try expect(symbol: "(", context: "after function name `\(name)`")
                var parameters: [String] = []
                if !check(symbol: ")") {
                    repeat {
                        parameters.append(try expectIdentifier(context: "in the parameter list of `\(name)`"))
                    } while match(symbol: ",")
                }
                try expect(symbol: ")", context: "to close the parameter list of `\(name)`")
                let body = try parseBlock(context: "as the body of `\(name)`")
                _ = match(symbol: ";")
                return .function(RhaiFunction(name: name, parameters: parameters, body: body, position: position))
            case "if":
                return try parseIfStatement()
            case "while":
                _ = advance()
                let condition = try parseExpression()
                let body = try parseBlock(context: "as the body of `while`")
                _ = match(symbol: ";")
                return .whileLoop(condition: condition, body: body, position: position)
            case "loop":
                _ = advance()
                let body = try parseBlock(context: "as the body of `loop`")
                _ = match(symbol: ";")
                return .loopForever(body: body, position: position)
            case "for":
                _ = advance()
                let variable = try expectIdentifier(context: "after `for`")
                guard match(keyword: "in") else {
                    throw RhaiParseError(
                        "expected `in` after `for \(variable)` but found `\(current.text)`",
                        at: current.position
                    )
                }
                let sequence = try parseExpression()
                let body = try parseBlock(context: "as the body of `for`")
                _ = match(symbol: ";")
                return .forLoop(variable: variable, sequence: sequence, body: body, position: position)
            case "break":
                _ = advance()
                _ = match(symbol: ";")
                return .breakLoop(position)
            case "continue":
                _ = advance()
                _ = match(symbol: ";")
                return .continueLoop(position)
            case "return":
                _ = advance()
                if match(symbol: ";") { return .returnValue(nil, position) }
                if check(symbol: "}") { return .returnValue(nil, position) }
                let value = try parseExpression()
                _ = match(symbol: ";")
                return .returnValue(value, position)
            case "try":
                _ = advance()
                let body = try parseBlock(context: "as the body of `try`")
                guard match(keyword: "catch") else {
                    throw RhaiParseError(
                        "expected `catch` after a `try` block but found `\(current.text)`",
                        at: current.position
                    )
                }
                var errorName: String?
                if match(symbol: "(") {
                    errorName = try expectIdentifier(context: "as the `catch` binding")
                    try expect(symbol: ")", context: "to close the `catch` binding")
                }
                let handler = try parseBlock(context: "as the body of `catch`")
                _ = match(symbol: ";")
                return .tryCatch(body: body, errorName: errorName, handler: handler, position: position)
            default:
                break
            }
        }

        if check(symbol: "{") {
            let block = try parseBlock(context: "")
            _ = match(symbol: ";")
            return .block(block, position)
        }

        // Expression or assignment statement.
        let expression = try parseExpression()
        let assignmentOperators = ["=", "+=", "-=", "*=", "/=", "%="]
        if case .symbol(let symbol) = current.kind, assignmentOperators.contains(symbol) {
            _ = advance()
            guard isAssignable(expression) else {
                throw RhaiParseError(
                    "the left-hand side of `\(symbol)` is not assignable",
                    at: expression.position
                )
            }
            let value = try parseExpression()
            _ = match(symbol: ";")
            return .assignment(target: expression, op: symbol, value: value, position: position)
        }
        _ = match(symbol: ";")
        return .expression(expression)
    }

    private mutating func parseIfStatement() throws -> RhaiStatement {
        let position = current.position
        _ = advance()
        let condition = try parseExpression()
        let then = try parseBlock(context: "as the body of `if`")
        var otherwise: RhaiBlock?
        if match(keyword: "else") {
            if check(keyword: "if") {
                let nested = try parseIfStatement()
                otherwise = RhaiBlock(statements: [nested], position: current.position)
            } else {
                otherwise = try parseBlock(context: "as the body of `else`")
            }
        }
        _ = match(symbol: ";")
        return .conditional(condition: condition, then: then, otherwise: otherwise, position: position)
    }

    private mutating func parseBlock(context: String) throws -> RhaiBlock {
        let position = current.position
        let suffix = context.isEmpty ? "" : " \(context)"
        guard match(symbol: "{") else {
            throw RhaiParseError(
                "expected `{`\(suffix) but found `\(current.text)`",
                at: current.position
            )
        }
        var statements: [RhaiStatement] = []
        while !check(symbol: "}") {
            guard !isAtEnd else {
                throw RhaiParseError("unterminated block", at: position)
            }
            statements.append(try parseStatement())
        }
        try expect(symbol: "}", context: "to close a block")
        return RhaiBlock(statements: statements, position: position)
    }

    private func isAssignable(_ expression: RhaiExpression) -> Bool {
        switch expression {
        case .identifier: return true
        case .index(let target, _, _), .member(let target, _, _): return isAssignable(target)
        default: return false
        }
    }

    // MARK: - Expressions

    public mutating func parseExpression() throws -> RhaiExpression {
        try parseLogicalOr()
    }

    private mutating func parseLogicalOr() throws -> RhaiExpression {
        var left = try parseLogicalAnd()
        while check(symbol: "||") {
            let position = advance().position
            let right = try parseLogicalAnd()
            left = .logical(op: "||", left: left, right: right, position: position)
        }
        return left
    }

    private mutating func parseLogicalAnd() throws -> RhaiExpression {
        var left = try parseEquality()
        while check(symbol: "&&") {
            let position = advance().position
            let right = try parseEquality()
            left = .logical(op: "&&", left: left, right: right, position: position)
        }
        return left
    }

    private mutating func parseEquality() throws -> RhaiExpression {
        var left = try parseComparison()
        while check(symbol: "==") || check(symbol: "!=") {
            let token = advance()
            guard case .symbol(let op) = token.kind else { break }
            let right = try parseComparison()
            left = .binary(op: op, left: left, right: right, position: token.position)
        }
        return left
    }

    private mutating func parseComparison() throws -> RhaiExpression {
        var left = try parseRange()
        while check(symbol: "<") || check(symbol: "<=") || check(symbol: ">") || check(symbol: ">=") {
            let token = advance()
            guard case .symbol(let op) = token.kind else { break }
            let right = try parseRange()
            left = .binary(op: op, left: left, right: right, position: token.position)
        }
        return left
    }

    private mutating func parseRange() throws -> RhaiExpression {
        let left = try parseAdditive()
        if check(symbol: "..") || check(symbol: "..=") {
            let token = advance()
            let inclusive = token.text == "..="
            let right = try parseAdditive()
            return .range(from: left, to: right, inclusive: inclusive, position: token.position)
        }
        return left
    }

    private mutating func parseAdditive() throws -> RhaiExpression {
        var left = try parseMultiplicative()
        while check(symbol: "+") || check(symbol: "-") {
            let token = advance()
            guard case .symbol(let op) = token.kind else { break }
            let right = try parseMultiplicative()
            left = .binary(op: op, left: left, right: right, position: token.position)
        }
        return left
    }

    private mutating func parseMultiplicative() throws -> RhaiExpression {
        var left = try parseUnary()
        while check(symbol: "*") || check(symbol: "/") || check(symbol: "%") {
            let token = advance()
            guard case .symbol(let op) = token.kind else { break }
            let right = try parseUnary()
            left = .binary(op: op, left: left, right: right, position: token.position)
        }
        return left
    }

    private mutating func parseUnary() throws -> RhaiExpression {
        if check(symbol: "!") || check(symbol: "-") || check(symbol: "+") {
            let token = advance()
            guard case .symbol(let op) = token.kind else {
                throw RhaiParseError("malformed unary operator", at: token.position)
            }
            let operand = try parseUnary()
            if op == "+" { return operand }
            return .unary(op: op, operand: operand, position: token.position)
        }
        return try parsePostfix()
    }

    private mutating func parsePostfix() throws -> RhaiExpression {
        var expression = try parsePrimary()
        while true {
            if check(symbol: ".") {
                let position = advance().position
                let name = try expectIdentifier(context: "after `.`")
                if match(symbol: "(") {
                    let arguments = try parseArguments(closing: ")", context: "in a method call to `\(name)`")
                    expression = .method(target: expression, name: name, arguments: arguments, position: position)
                } else {
                    expression = .member(target: expression, name: name, position: position)
                }
                continue
            }
            if check(symbol: "[") {
                let position = advance().position
                let subscriptExpression = try parseExpression()
                try expect(symbol: "]", context: "to close an index")
                expression = .index(target: expression, index: subscriptExpression, position: position)
                continue
            }
            break
        }
        return expression
    }

    private mutating func parseArguments(closing: String, context: String) throws -> [RhaiExpression] {
        var arguments: [RhaiExpression] = []
        if !check(symbol: closing) {
            repeat {
                if check(symbol: closing) { break }
                arguments.append(try parseExpression())
            } while match(symbol: ",")
        }
        try expect(symbol: closing, context: "\(context)")
        return arguments
    }

    private mutating func parsePrimary() throws -> RhaiExpression {
        let token = current
        let position = token.position

        switch token.kind {
        case .integer(let value):
            _ = advance()
            return .integer(value, position)
        case .float(let value):
            _ = advance()
            return .float(value, position)
        case .string(let value):
            _ = advance()
            return .string(value, position)
        case .keyword("true"):
            _ = advance()
            return .boolean(true, position)
        case .keyword("false"):
            _ = advance()
            return .boolean(false, position)
        case .keyword("if"):
            guard case .conditional(let condition, let then, let otherwise, _) = try parseIfStatement() else {
                throw RhaiParseError("malformed `if` expression", at: position)
            }
            return .conditional(condition: condition, then: then, otherwise: otherwise, position: position)
        case .keyword(let keyword):
            throw RhaiParseError(
                "`\(keyword)` cannot start an expression in the supported subset",
                at: position
            )
        case .identifier(let name):
            _ = advance()
            if match(symbol: "(") {
                let arguments = try parseArguments(closing: ")", context: "in a call to `\(name)`")
                return .call(name: name, arguments: arguments, position: position)
            }
            return .identifier(name, position)
        case .symbol("("):
            _ = advance()
            if match(symbol: ")") { return .unit(position) }
            let inner = try parseExpression()
            try expect(symbol: ")", context: "to close a parenthesized expression")
            return inner
        case .symbol("["):
            _ = advance()
            let items = try parseArguments(closing: "]", context: "to close an array literal")
            return .array(items, position)
        case .symbol("#{"):
            _ = advance()
            var entries: [(key: String, value: RhaiExpression)] = []
            if !check(symbol: "}") {
                repeat {
                    if check(symbol: "}") { break }
                    let key: String
                    switch current.kind {
                    case .identifier(let name):
                        _ = advance()
                        key = name
                    case .string(let name):
                        _ = advance()
                        key = name
                    case .keyword(let name):
                        // Rhai allows keyword-shaped map keys such as `type`.
                        _ = advance()
                        key = name
                    default:
                        throw RhaiParseError(
                            "expected a map key but found `\(current.text)`",
                            at: current.position
                        )
                    }
                    try expect(symbol: ":", context: "after the map key `\(key)`")
                    entries.append((key: key, value: try parseExpression()))
                } while match(symbol: ",")
            }
            try expect(symbol: "}", context: "to close a map literal")
            return .map(entries, position)
        case .symbol("{"):
            let block = try parseBlock(context: "")
            return .block(block, position)
        case .symbol("|"), .symbol("||"):
            var parameters: [String] = []
            if check(symbol: "||") {
                _ = advance()
            } else {
                _ = advance()
                if !check(symbol: "|") {
                    repeat {
                        parameters.append(try expectIdentifier(context: "in a closure parameter list"))
                    } while match(symbol: ",")
                }
                try expect(symbol: "|", context: "to close a closure parameter list")
            }
            let body: RhaiBlock
            if check(symbol: "{") {
                body = try parseBlock(context: "as a closure body")
            } else {
                let expression = try parseExpression()
                body = RhaiBlock(statements: [.expression(expression)], position: position)
            }
            return .closure(parameters: parameters, body: body, position: position)
        default:
            throw RhaiParseError("unexpected `\(token.text)`", at: position)
        }
    }
}
