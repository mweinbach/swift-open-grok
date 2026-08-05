// RhaiLexer.swift
//
// Tokenizer for the Rhai subset the upstream workflow scripts actually use.
//
// Scope was derived by reading the two shipped built-ins
// (crates/codegen/xai-grok-shell/src/session/workflows/{ultracode,deep_research}.rhai)
// and the engine's own test scripts. Anything outside that subset is rejected
// by the parser with a diagnostic naming the construct — the one thing this
// port must never do is silently mis-execute a script it only partly
// understands.

import Foundation

/// A source position, reported in errors the way Rhai reports them.
public struct RhaiSourcePosition: Sendable, Hashable, CustomStringConvertible {
    public var line: Int
    public var column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }

    public static let none = RhaiSourcePosition(line: 0, column: 0)

    public var description: String {
        line == 0 ? "unknown position" : "line \(line), position \(column)"
    }
}

public enum RhaiTokenKind: Sendable, Hashable {
    case integer(Int64)
    case float(Double)
    case string(String)
    case identifier(String)
    case keyword(String)
    case symbol(String)
    case endOfFile
}

public struct RhaiToken: Sendable, Hashable {
    public var kind: RhaiTokenKind
    public var position: RhaiSourcePosition

    var text: String {
        switch kind {
        case .integer(let value): return String(value)
        case .float(let value): return String(value)
        case .string(let value): return "\"\(value)\""
        case .identifier(let value), .keyword(let value), .symbol(let value): return value
        case .endOfFile: return "end of script"
        }
    }
}

/// A parse-time failure. Distinct from a runtime error: a script that fails to
/// tokenize or parse never runs at all.
public struct RhaiParseError: Error, Sendable, Hashable, CustomStringConvertible {
    public var message: String
    public var position: RhaiSourcePosition

    public init(_ message: String, at position: RhaiSourcePosition) {
        self.message = message
        self.position = position
    }

    public var description: String {
        position == .none ? message : "\(message) (\(position))"
    }
}

public enum RhaiLexer {
    /// Rhai reserves these even though it does not use them; a script naming a
    /// variable `shared` fails to compile upstream with a "reserved keyword"
    /// error, so the same names are rejected here (lib.rs:23 hint text).
    /// `exit` is absent on purpose: the engine registers a function by that
    /// name (engine.rs:146) whose whole job is to tell the author to use
    /// `complete()` or `pause()` instead, and that message is more useful than
    /// a generic reserved-keyword rejection.
    static let reservedWords: Set<String> = [
        "shared", "sync", "async", "await", "spawn", "go", "thread", "new",
        "match", "case", "default", "void", "null", "nil", "static", "var",
    ]

    static let keywords: Set<String> = [
        "let", "const", "fn", "if", "else", "while", "loop", "for", "in",
        "break", "continue", "return", "try", "catch", "true", "false",
        "switch", "do", "until", "import", "export", "private", "throw", "this",
    ]

    public static func tokenize(_ source: String) throws -> [RhaiToken] {
        var tokens: [RhaiToken] = []
        let scalars = Array(source.unicodeScalars)
        var index = 0
        var line = 1
        var column = 1

        func position() -> RhaiSourcePosition { RhaiSourcePosition(line: line, column: column) }

        func advance() {
            if scalars[index] == "\n" {
                line += 1
                column = 1
            } else {
                column += 1
            }
            index += 1
        }

        while index < scalars.count {
            let scalar = scalars[index]

            if scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" {
                advance()
                continue
            }

            // Comments.
            if scalar == "/", index + 1 < scalars.count, scalars[index + 1] == "/" {
                while index < scalars.count, scalars[index] != "\n" { advance() }
                continue
            }
            if scalar == "/", index + 1 < scalars.count, scalars[index + 1] == "*" {
                let start = position()
                advance()
                advance()
                var closed = false
                while index < scalars.count {
                    if scalars[index] == "*", index + 1 < scalars.count, scalars[index + 1] == "/" {
                        advance()
                        advance()
                        closed = true
                        break
                    }
                    advance()
                }
                guard closed else {
                    throw RhaiParseError("unterminated block comment", at: start)
                }
                continue
            }

            let start = position()

            // Strings.
            if scalar == "\"" {
                advance()
                var text = String.UnicodeScalarView()
                var terminated = false
                while index < scalars.count {
                    let current = scalars[index]
                    if current == "\"" {
                        advance()
                        terminated = true
                        break
                    }
                    if current == "\\" {
                        advance()
                        guard index < scalars.count else {
                            throw RhaiParseError("unterminated string escape", at: start)
                        }
                        let escape = scalars[index]
                        switch escape {
                        case "n": text.append("\n")
                        case "t": text.append("\t")
                        case "r": text.append("\r")
                        case "\\": text.append("\\")
                        case "\"": text.append("\"")
                        case "0": text.append("\0")
                        case "u":
                            advance()
                            guard index < scalars.count, scalars[index] == "{" else {
                                throw RhaiParseError("expected `{` after \\u", at: position())
                            }
                            advance()
                            var hex = ""
                            while index < scalars.count, scalars[index] != "}" {
                                hex.unicodeScalars.append(scalars[index])
                                advance()
                            }
                            guard index < scalars.count,
                                  let code = UInt32(hex, radix: 16),
                                  let unicode = Unicode.Scalar(code)
                            else {
                                throw RhaiParseError("invalid unicode escape \\u{\(hex)}", at: start)
                            }
                            text.append(unicode)
                        default:
                            throw RhaiParseError("unsupported string escape `\\\(escape)`", at: position())
                        }
                        advance()
                        continue
                    }
                    text.append(current)
                    advance()
                }
                guard terminated else {
                    throw RhaiParseError("unterminated string literal", at: start)
                }
                tokens.append(RhaiToken(kind: .string(String(text)), position: start))
                continue
            }

            // Numbers.
            if isDigit(scalar) {
                var text = ""
                var isFloat = false
                while index < scalars.count {
                    let current = scalars[index]
                    if isDigit(current) || current == "_" {
                        if current != "_" { text.unicodeScalars.append(current) }
                        advance()
                        continue
                    }
                    // `0..5` is a range, not a float: only consume `.` when a
                    // digit follows it.
                    if current == ".", !isFloat, index + 1 < scalars.count, isDigit(scalars[index + 1]) {
                        isFloat = true
                        text.unicodeScalars.append(current)
                        advance()
                        continue
                    }
                    break
                }
                if isFloat {
                    guard let value = Double(text) else {
                        throw RhaiParseError("invalid float literal `\(text)`", at: start)
                    }
                    tokens.append(RhaiToken(kind: .float(value), position: start))
                } else {
                    guard let value = Int64(text) else {
                        throw RhaiParseError("integer literal `\(text)` does not fit in i64", at: start)
                    }
                    tokens.append(RhaiToken(kind: .integer(value), position: start))
                }
                continue
            }

            // Identifiers and keywords.
            if isIdentifierStart(scalar) {
                var text = ""
                while index < scalars.count, isIdentifierPart(scalars[index]) {
                    text.unicodeScalars.append(scalars[index])
                    advance()
                }
                if reservedWords.contains(text) {
                    throw RhaiParseError(
                        "`\(text)` is a reserved keyword in Rhai — rename it (for example "
                            + "`shared` to `has_shared`)",
                        at: start
                    )
                }
                if keywords.contains(text) {
                    tokens.append(RhaiToken(kind: .keyword(text), position: start))
                } else {
                    tokens.append(RhaiToken(kind: .identifier(text), position: start))
                }
                continue
            }

            // Symbols, longest match first.
            let threeCharacter = ["..="]
            let twoCharacter = ["==", "!=", "<=", ">=", "&&", "||", "+=", "-=", "*=", "/=", "%=", "#{", ".."]
            let oneCharacter = ["+", "-", "*", "/", "%", "!", "=", "<", ">", "(", ")", "[", "]", "{", "}", ",", ";", ":", ".", "|"]

            func peek(_ length: Int) -> String {
                let end = min(index + length, scalars.count)
                var text = String.UnicodeScalarView()
                for offset in index..<end { text.append(scalars[offset]) }
                return String(text)
            }

            if threeCharacter.contains(peek(3)) {
                let symbol = peek(3)
                advance(); advance(); advance()
                tokens.append(RhaiToken(kind: .symbol(symbol), position: start))
                continue
            }
            if twoCharacter.contains(peek(2)) {
                let symbol = peek(2)
                advance(); advance()
                tokens.append(RhaiToken(kind: .symbol(symbol), position: start))
                continue
            }
            if oneCharacter.contains(peek(1)) {
                let symbol = peek(1)
                advance()
                tokens.append(RhaiToken(kind: .symbol(symbol), position: start))
                continue
            }

            throw RhaiParseError("unexpected character `\(scalar)`", at: start)
        }

        tokens.append(RhaiToken(kind: .endOfFile, position: position()))
        return tokens
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar >= "0" && scalar <= "9"
    }

    private static func isIdentifierStart(_ scalar: Unicode.Scalar) -> Bool {
        (scalar >= "a" && scalar <= "z") || (scalar >= "A" && scalar <= "Z") || scalar == "_"
    }

    private static func isIdentifierPart(_ scalar: Unicode.Scalar) -> Bool {
        isIdentifierStart(scalar) || isDigit(scalar)
    }
}
