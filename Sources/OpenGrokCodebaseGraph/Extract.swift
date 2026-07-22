// Extract.swift
//
// Deterministic, parser-style symbol extraction. Tree-sitter is the Rust
// reference; this Swift port implements equivalent concrete language scanners
// that model scopes, skip comments/strings, handle multiline declarations,
// aliases, and qualified references — independent of UI/provider/global state.

import Foundation

/// Supported language families for extraction.
public enum SourceLanguage: String, Sendable, Equatable, CaseIterable {
    case rust
    case python
    case javascript
    case typescript
    case go
    case swift
    case unknown

    public static func detect(path: String) -> SourceLanguage {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "rs": return .rust
        case "py", "pyi": return .python
        case "js", "jsx", "mjs", "cjs": return .javascript
        case "ts", "tsx": return .typescript
        case "go": return .go
        case "swift": return .swift
        default: return .unknown
        }
    }
}

/// Extracted symbols for one file.
public struct FileSymbols: Sendable, Equatable {
    public var path: String
    public var definitions: [SymbolOccurrence]
    public var references: [SymbolOccurrence]
    public var aliases: [SymbolAlias]
    public var meta: FileMeta?
    /// Nested scope ranges (1-indexed line ranges) for navigation.
    public var scopes: [SourceRange]

    public init(
        path: String,
        definitions: [SymbolOccurrence] = [],
        references: [SymbolOccurrence] = [],
        aliases: [SymbolAlias] = [],
        meta: FileMeta? = nil,
        scopes: [SourceRange] = []
    ) {
        self.path = path
        self.definitions = definitions
        self.references = references
        self.aliases = aliases
        self.meta = meta
        self.scopes = scopes
    }
}

/// Token kinds produced by the shared scanner.
enum TokKind: Equatable {
    case ident
    case keyword
    case punct
    case string
    case comment
    case newline
    case other
}

struct Tok: Equatable {
    var kind: TokKind
    var text: String
    var line: Int
    var column: Int
}

/// Deterministic symbol extractor.
public enum SymbolExtractor {
    /// Extract symbols from file contents. Pure: no I/O.
    public static func extract(path: String, content: String) -> FileSymbols {
        let lang = SourceLanguage.detect(path: path)
        guard lang != .unknown else {
            return FileSymbols(path: path)
        }
        let tokens = tokenize(content, language: lang)
        var defs: [SymbolOccurrence] = []
        var refs: [SymbolOccurrence] = []
        var aliases: [SymbolAlias] = []
        var scopes: [SourceRange] = []

        switch lang {
        case .rust:
            parseRust(tokens, defs: &defs, refs: &refs, aliases: &aliases, scopes: &scopes)
        case .python:
            parsePython(tokens, defs: &defs, refs: &refs, aliases: &aliases, scopes: &scopes)
        case .javascript, .typescript:
            parseJS(tokens, defs: &defs, refs: &refs, aliases: &aliases, scopes: &scopes)
        case .go:
            parseGo(tokens, defs: &defs, refs: &refs, aliases: &aliases, scopes: &scopes)
        case .swift:
            parseSwift(tokens, defs: &defs, refs: &refs, aliases: &aliases, scopes: &scopes)
        case .unknown:
            break
        }

        defs.sort { ($0.line, $0.column, $0.name) < ($1.line, $1.column, $1.name) }
        refs.sort { ($0.line, $0.column, $0.name) < ($1.line, $1.column, $1.name) }
        return FileSymbols(
            path: path,
            definitions: defs,
            references: refs,
            aliases: aliases,
            scopes: scopes
        )
    }
}

// MARK: - Tokenizer (comment/string aware)

private let rustKeywords: Set<String> = [
    "fn", "struct", "enum", "trait", "impl", "mod", "use", "pub", "const", "static",
    "type", "async", "unsafe", "extern", "crate", "self", "super", "where", "let",
    "mut", "ref", "match", "if", "else", "loop", "while", "for", "in", "return",
    "break", "continue", "as", "move"
]
private let pythonKeywords: Set<String> = [
    "def", "class", "async", "import", "from", "as", "return", "if", "else", "elif",
    "for", "while", "with", "try", "except", "finally", "raise", "yield", "lambda",
    "pass", "global", "nonlocal", "assert", "del", "and", "or", "not", "in", "is"
]
private let jsKeywords: Set<String> = [
    "function", "class", "const", "let", "var", "import", "export", "from", "as",
    "default", "return", "if", "else", "for", "while", "switch", "case", "break",
    "continue", "new", "this", "typeof", "instanceof", "async", "await", "of", "in"
]
private let goKeywords: Set<String> = [
    "func", "type", "struct", "interface", "package", "import", "const", "var",
    "return", "if", "else", "for", "range", "switch", "case", "go", "defer", "map",
    "chan", "select"
]
private let swiftKeywords: Set<String> = [
    "func", "struct", "class", "enum", "protocol", "actor", "import", "let", "var",
    "public", "private", "internal", "open", "fileprivate", "static", "return",
    "if", "else", "for", "while", "switch", "case", "guard", "defer", "async",
    "await", "throws", "rethrows", "extension", "typealias", "associatedtype"
]

func keywords(for lang: SourceLanguage) -> Set<String> {
    switch lang {
    case .rust: return rustKeywords
    case .python: return pythonKeywords
    case .javascript, .typescript: return jsKeywords
    case .go: return goKeywords
    case .swift: return swiftKeywords
    case .unknown: return []
    }
}

func tokenize(_ source: String, language: SourceLanguage) -> [Tok] {
    var tokens: [Tok] = []
    let chars = Array(source)
    var i = 0
    var line = 1
    var col = 1
    let kws = keywords(for: language)
    let n = chars.count

    func peek(_ k: Int = 0) -> Character? {
        let j = i + k
        return j < n ? chars[j] : nil
    }
    func advance() -> Character {
        let c = chars[i]
        i += 1
        if c == "\n" {
            line += 1
            col = 1
        } else {
            col += 1
        }
        return c
    }

    while i < n {
        let startLine = line
        let startCol = col
        let c = peek()!

        // Newline
        if c == "\n" {
            _ = advance()
            tokens.append(Tok(kind: .newline, text: "\n", line: startLine, column: startCol))
            continue
        }
        // Whitespace
        if c == " " || c == "\t" || c == "\r" {
            _ = advance()
            continue
        }

        // Comments
        if language == .python && c == "#" {
            var text = ""
            while let p = peek(), p != "\n" {
                text.append(advance())
            }
            tokens.append(Tok(kind: .comment, text: text, line: startLine, column: startCol))
            continue
        }
        if c == "/" && peek(1) == "/" && language != .python {
            var text = ""
            while let p = peek(), p != "\n" {
                text.append(advance())
            }
            tokens.append(Tok(kind: .comment, text: text, line: startLine, column: startCol))
            continue
        }
        if c == "/" && peek(1) == "*" && language != .python {
            var text = ""
            text.append(advance())
            text.append(advance())
            while i < n {
                if peek() == "*" && peek(1) == "/" {
                    text.append(advance())
                    text.append(advance())
                    break
                }
                text.append(advance())
            }
            tokens.append(Tok(kind: .comment, text: text, line: startLine, column: startCol))
            continue
        }

        // Strings (incl. raw / multi-line for python triple quotes)
        if c == "\"" || c == "'" || c == "`" {
            if language == .python && (String(chars[i...]).hasPrefix("\"\"\"") || String(chars[i...]).hasPrefix("'''")) {
                let quote = String(chars[i..<(i + 3)])
                var text = ""
                text.append(advance()); text.append(advance()); text.append(advance())
                while i + 2 < n {
                    if String(chars[i..<(i + 3)]) == quote {
                        text.append(advance()); text.append(advance()); text.append(advance())
                        break
                    }
                    text.append(advance())
                }
                tokens.append(Tok(kind: .string, text: text, line: startLine, column: startCol))
                continue
            }
            let quote = c
            var text = ""
            text.append(advance())
            var escaped = false
            while i < n {
                let ch = advance()
                text.append(ch)
                if escaped {
                    escaped = false
                    continue
                }
                if ch == "\\" {
                    escaped = true
                    continue
                }
                if ch == quote { break }
                if ch == "\n" && quote != "`" && language != .python { break }
            }
            tokens.append(Tok(kind: .string, text: text, line: startLine, column: startCol))
            continue
        }

        // Identifiers / keywords
        if c.isLetter || c == "_" || c == "$" {
            var text = ""
            while let p = peek(), p.isLetter || p.isNumber || p == "_" || p == "$" {
                text.append(advance())
            }
            let kind: TokKind = kws.contains(text) ? .keyword : .ident
            tokens.append(Tok(kind: kind, text: text, line: startLine, column: startCol))
            continue
        }

        // Numbers → other
        if c.isNumber {
            var text = ""
            while let p = peek(), p.isNumber || p == "." || p == "_" || p.isHexDigit {
                text.append(advance())
            }
            tokens.append(Tok(kind: .other, text: text, line: startLine, column: startCol))
            continue
        }

        // Punctuation / operators
        if "(){}[].,;:-+*/%=<>!&|^~?@#\\".contains(c) {
            // multi-char operators we care about
            if c == ":" && peek(1) == ":" {
                _ = advance(); _ = advance()
                tokens.append(Tok(kind: .punct, text: "::", line: startLine, column: startCol))
                continue
            }
            let t = String(advance())
            tokens.append(Tok(kind: .punct, text: t, line: startLine, column: startCol))
            continue
        }

        tokens.append(Tok(kind: .other, text: String(advance()), line: startLine, column: startCol))
    }
    return tokens
}

// MARK: - Token cursor helpers

private struct Cursor {
    let tokens: [Tok]
    var i: Int = 0

    var current: Tok? { i < tokens.count ? tokens[i] : nil }
    mutating func advance() -> Tok? {
        guard i < tokens.count else { return nil }
        defer { i += 1 }
        return tokens[i]
    }
    mutating func skipTrivia() {
        while let t = current, t.kind == .comment || t.kind == .newline {
            _ = advance()
        }
    }
    mutating func skipNewlines() {
        while let t = current, t.kind == .newline || t.kind == .comment {
            _ = advance()
        }
    }
    func peekText() -> String? { current?.text }
    mutating func matchKw(_ s: String) -> Bool {
        skipTrivia()
        if current?.kind == .keyword && current?.text == s {
            _ = advance()
            return true
        }
        return false
    }
    mutating func matchPunct(_ s: String) -> Bool {
        skipTrivia()
        if current?.kind == .punct && current?.text == s {
            _ = advance()
            return true
        }
        return false
    }
    mutating func takeIdent() -> Tok? {
        skipTrivia()
        if current?.kind == .ident {
            return advance()
        }
        // Some languages allow keywords as idents in certain positions — not here.
        return nil
    }
    /// Consume until matching closer, tracking nesting. Records scope range.
    mutating func skipBalanced(open: String, close: String, scopes: inout [SourceRange]) {
        skipTrivia()
        guard current?.text == open else { return }
        let startLine = current!.line
        let startCol = current!.column
        _ = advance()
        var depth = 1
        while let t = current {
            if t.kind == .punct && t.text == open { depth += 1 }
            if t.kind == .punct && t.text == close {
                depth -= 1
                if depth == 0 {
                    let endLine = t.line
                    let endCol = t.column
                    _ = advance()
                    scopes.append(SourceRange(
                        start: Position(line: startLine, column: startCol),
                        end: Position(line: endLine, column: endCol)
                    ))
                    return
                }
            }
            _ = advance()
        }
    }
}

// MARK: - Language parsers

private func parseRust(
    _ tokens: [Tok],
    defs: inout [SymbolOccurrence],
    refs: inout [SymbolOccurrence],
    aliases: inout [SymbolAlias],
    scopes: inout [SourceRange]
) {
    var c = Cursor(tokens: tokens)
    while c.current != nil {
        c.skipNewlines()
        guard c.current != nil else { break }

        // Visibility
        _ = c.matchKw("pub")
        _ = c.matchPunct("(")
        // skip pub(crate) etc
        if c.peekText() == "crate" || c.peekText() == "super" || c.peekText() == "self" {
            _ = c.advance()
            _ = c.matchPunct(")")
        }

        if c.matchKw("async") { /* fallthrough */ }

        if c.matchKw("fn") {
            if let name = c.takeIdent() {
                defs.append(SymbolOccurrence(name: name.text, line: name.line, column: name.column))
            }
            // skip params/body
            c.skipBalanced(open: "(", close: ")", scopes: &scopes)
            // return type optional
            if c.matchPunct("-") { _ = c.matchPunct(">"); c.skipTrivia() }
            while let t = c.current, t.text != "{" && t.text != ";" && t.kind != .newline {
                if t.kind == .ident {
                    refs.append(SymbolOccurrence(name: t.text, line: t.line, column: t.column))
                }
                _ = c.advance()
            }
            if c.peekText() == "{" {
                c.skipBalanced(open: "{", close: "}", scopes: &scopes)
            } else {
                _ = c.matchPunct(";")
            }
            continue
        }
        if c.matchKw("struct") || c.matchKw("enum") || c.matchKw("trait") || c.matchKw("mod") {
            if let name = c.takeIdent() {
                defs.append(SymbolOccurrence(name: name.text, line: name.line, column: name.column))
            }
            // generics
            if c.peekText() == "<" { c.skipBalanced(open: "<", close: ">", scopes: &scopes) }
            if c.peekText() == "{" {
                c.skipBalanced(open: "{", close: "}", scopes: &scopes)
            } else if c.peekText() == "(" {
                c.skipBalanced(open: "(", close: ")", scopes: &scopes)
                _ = c.matchPunct(";")
            } else {
                _ = c.matchPunct(";")
            }
            continue
        }
        if c.matchKw("type") || c.matchKw("const") || c.matchKw("static") {
            _ = c.matchKw("mut")
            if let name = c.takeIdent() {
                defs.append(SymbolOccurrence(name: name.text, line: name.line, column: name.column))
            }
            // consume until ; tracking type refs
            while let t = c.current, t.text != ";" {
                if t.kind == .ident {
                    refs.append(SymbolOccurrence(name: t.text, line: t.line, column: t.column))
                }
                _ = c.advance()
            }
            _ = c.matchPunct(";")
            continue
        }
        if c.matchKw("use") {
            // use path::{A as B, C} or use path::Name as Alias
            parseRustUse(&c, refs: &refs, aliases: &aliases)
            _ = c.matchPunct(";")
            continue
        }
        if c.matchKw("impl") {
            // impl Trait for Type / impl Type
            while let t = c.current, t.text != "{" {
                if t.kind == .ident {
                    refs.append(SymbolOccurrence(name: t.text, line: t.line, column: t.column))
                }
                _ = c.advance()
            }
            if c.peekText() == "{" {
                c.skipBalanced(open: "{", close: "}", scopes: &scopes)
            }
            continue
        }

        // Call / path references: Ident( or Ident::
        if c.current?.kind == .ident {
            let id = c.advance()!
            if c.peekText() == "(" {
                refs.append(SymbolOccurrence(name: id.text, line: id.line, column: id.column))
            } else if c.peekText() == "::" {
                refs.append(SymbolOccurrence(name: id.text, line: id.line, column: id.column))
            }
            continue
        }
        _ = c.advance()
    }
}

private func parseRustUse(
    _ c: inout Cursor,
    refs: inout [SymbolOccurrence],
    aliases: inout [SymbolAlias]
) {
    c.skipTrivia()
    // Collect path segments / list
    var lastIdent: Tok?
    while let t = c.current {
        if t.kind == .ident || (t.kind == .keyword && (t.text == "self" || t.text == "super" || t.text == "crate")) {
            lastIdent = t
            _ = c.advance()
            continue
        }
        if t.text == "::" {
            _ = c.advance()
            continue
        }
        if t.text == "{" {
            _ = c.advance()
            while let inner = c.current, inner.text != "}" {
                if inner.kind == .ident {
                    let original = inner
                    _ = c.advance()
                    if c.matchKw("as") || (c.current?.kind == .keyword && c.current?.text == "as") {
                        // already matched as keyword via matchKw path
                    }
                    c.skipTrivia()
                    if c.current?.kind == .keyword && c.current?.text == "as" {
                        _ = c.advance()
                    }
                    if let alias = c.takeIdent() {
                        aliases.append(SymbolAlias(alias: alias.text, original: original.text))
                        refs.append(SymbolOccurrence(name: original.text, line: original.line, column: original.column))
                    } else {
                        refs.append(SymbolOccurrence(name: original.text, line: original.line, column: original.column))
                    }
                    _ = c.matchPunct(",")
                    continue
                }
                if inner.text == "," { _ = c.advance(); continue }
                if inner.text == "}" { break }
                _ = c.advance()
            }
            _ = c.matchPunct("}")
            return
        }
        if t.kind == .keyword && t.text == "as" {
            _ = c.advance()
            if let alias = c.takeIdent(), let orig = lastIdent {
                aliases.append(SymbolAlias(alias: alias.text, original: orig.text))
                refs.append(SymbolOccurrence(name: orig.text, line: orig.line, column: orig.column))
            }
            return
        }
        if t.text == ";" { break }
        _ = c.advance()
    }
    if let last = lastIdent {
        refs.append(SymbolOccurrence(name: last.text, line: last.line, column: last.column))
    }
}

private func parsePython(
    _ tokens: [Tok],
    defs: inout [SymbolOccurrence],
    refs: inout [SymbolOccurrence],
    aliases: inout [SymbolAlias],
    scopes: inout [SourceRange]
) {
    var c = Cursor(tokens: tokens)
    while c.current != nil {
        c.skipNewlines()
        guard c.current != nil else { break }
        _ = c.matchKw("async")
        if c.matchKw("def") {
            if let name = c.takeIdent() {
                defs.append(SymbolOccurrence(name: name.text, line: name.line, column: name.column))
            }
            c.skipBalanced(open: "(", close: ")", scopes: &scopes)
            continue
        }
        if c.matchKw("class") {
            if let name = c.takeIdent() {
                defs.append(SymbolOccurrence(name: name.text, line: name.line, column: name.column))
            }
            if c.peekText() == "(" {
                // base classes as refs
                _ = c.advance()
                while let t = c.current, t.text != ")" {
                    if t.kind == .ident {
                        refs.append(SymbolOccurrence(name: t.text, line: t.line, column: t.column))
                    }
                    _ = c.advance()
                }
                _ = c.matchPunct(")")
            }
            continue
        }
        if c.matchKw("from") {
            // from x import y as z
            if let mod = c.takeIdent() {
                refs.append(SymbolOccurrence(name: mod.text, line: mod.line, column: mod.column))
            }
            // skip dotted
            while c.matchPunct(".") {
                if let seg = c.takeIdent() {
                    refs.append(SymbolOccurrence(name: seg.text, line: seg.line, column: seg.column))
                }
            }
            _ = c.matchKw("import")
            while let name = c.takeIdent() {
                c.skipTrivia()
                if c.current?.kind == .keyword && c.current?.text == "as" {
                    _ = c.advance()
                    if let alias = c.takeIdent() {
                        aliases.append(SymbolAlias(alias: alias.text, original: name.text))
                    }
                }
                refs.append(SymbolOccurrence(name: name.text, line: name.line, column: name.column))
                if !c.matchPunct(",") { break }
            }
            continue
        }
        if c.matchKw("import") {
            if let name = c.takeIdent() {
                refs.append(SymbolOccurrence(name: name.text, line: name.line, column: name.column))
                c.skipTrivia()
                if c.current?.kind == .keyword && c.current?.text == "as" {
                    _ = c.advance()
                    if let alias = c.takeIdent() {
                        aliases.append(SymbolAlias(alias: alias.text, original: name.text))
                    }
                }
            }
            continue
        }
        // call refs
        if c.current?.kind == .ident {
            let id = c.advance()!
            if c.peekText() == "(" {
                refs.append(SymbolOccurrence(name: id.text, line: id.line, column: id.column))
            }
            continue
        }
        _ = c.advance()
    }
    _ = scopes
}

private func parseJS(
    _ tokens: [Tok],
    defs: inout [SymbolOccurrence],
    refs: inout [SymbolOccurrence],
    aliases: inout [SymbolAlias],
    scopes: inout [SourceRange]
) {
    var c = Cursor(tokens: tokens)
    while c.current != nil {
        c.skipNewlines()
        guard c.current != nil else { break }
        _ = c.matchKw("export")
        _ = c.matchKw("default")
        _ = c.matchKw("async")

        if c.matchKw("function") {
            if let name = c.takeIdent() {
                defs.append(SymbolOccurrence(name: name.text, line: name.line, column: name.column))
            }
            c.skipBalanced(open: "(", close: ")", scopes: &scopes)
            if c.peekText() == "{" {
                c.skipBalanced(open: "{", close: "}", scopes: &scopes)
            }
            continue
        }
        if c.matchKw("class") {
            if let name = c.takeIdent() {
                defs.append(SymbolOccurrence(name: name.text, line: name.line, column: name.column))
            }
            if c.matchKw("extends") {
                if let base = c.takeIdent() {
                    refs.append(SymbolOccurrence(name: base.text, line: base.line, column: base.column))
                }
            }
            if c.peekText() == "{" {
                c.skipBalanced(open: "{", close: "}", scopes: &scopes)
            }
            continue
        }
        if c.matchKw("const") || c.matchKw("let") || c.matchKw("var") {
            if let name = c.takeIdent() {
                defs.append(SymbolOccurrence(name: name.text, line: name.line, column: name.column))
            }
            // consume rest of statement roughly
            while let t = c.current, t.text != ";" && t.kind != .newline {
                if t.text == "{" { c.skipBalanced(open: "{", close: "}", scopes: &scopes); continue }
                if t.text == "(" { c.skipBalanced(open: "(", close: ")", scopes: &scopes); continue }
                _ = c.advance()
            }
            _ = c.matchPunct(";")
            continue
        }
        if c.matchKw("import") {
            // import { X as Y } from '…'
            c.skipTrivia()
            if c.peekText() == "{" {
                _ = c.advance()
                while let t = c.current, t.text != "}" {
                    if t.kind == .ident {
                        let original = t
                        _ = c.advance()
                        c.skipTrivia()
                        if c.current?.kind == .keyword && c.current?.text == "as" {
                            _ = c.advance()
                            if let alias = c.takeIdent() {
                                aliases.append(SymbolAlias(alias: alias.text, original: original.text))
                            }
                        }
                        refs.append(SymbolOccurrence(name: original.text, line: original.line, column: original.column))
                        _ = c.matchPunct(",")
                        continue
                    }
                    _ = c.advance()
                }
                _ = c.matchPunct("}")
            } else if let name = c.takeIdent() {
                refs.append(SymbolOccurrence(name: name.text, line: name.line, column: name.column))
            }
            // skip until newline/semicolon
            while let t = c.current, t.text != ";" && t.kind != .newline {
                _ = c.advance()
            }
            continue
        }
        if c.current?.kind == .ident {
            let id = c.advance()!
            if c.peekText() == "(" {
                refs.append(SymbolOccurrence(name: id.text, line: id.line, column: id.column))
            }
            continue
        }
        _ = c.advance()
    }
}

private func parseGo(
    _ tokens: [Tok],
    defs: inout [SymbolOccurrence],
    refs: inout [SymbolOccurrence],
    aliases: inout [SymbolAlias],
    scopes: inout [SourceRange]
) {
    var c = Cursor(tokens: tokens)
    while c.current != nil {
        c.skipNewlines()
        guard c.current != nil else { break }
        if c.matchKw("func") {
            // method receiver
            if c.peekText() == "(" {
                c.skipBalanced(open: "(", close: ")", scopes: &scopes)
            }
            if let name = c.takeIdent() {
                defs.append(SymbolOccurrence(name: name.text, line: name.line, column: name.column))
            }
            c.skipBalanced(open: "(", close: ")", scopes: &scopes)
            // result
            if c.peekText() == "(" {
                c.skipBalanced(open: "(", close: ")", scopes: &scopes)
            } else if c.current?.kind == .ident {
                let t = c.advance()!
                refs.append(SymbolOccurrence(name: t.text, line: t.line, column: t.column))
            }
            if c.peekText() == "{" {
                c.skipBalanced(open: "{", close: "}", scopes: &scopes)
            }
            continue
        }
        if c.matchKw("type") {
            if let name = c.takeIdent() {
                defs.append(SymbolOccurrence(name: name.text, line: name.line, column: name.column))
            }
            // rest until next top-level-ish
            if c.peekText() == "struct" || c.peekText() == "interface" {
                _ = c.advance()
                if c.peekText() == "{" {
                    c.skipBalanced(open: "{", close: "}", scopes: &scopes)
                }
            }
            continue
        }
        if c.matchKw("import") {
            if c.peekText() == "(" {
                c.skipBalanced(open: "(", close: ")", scopes: &scopes)
            } else {
                while let t = c.current, t.kind != .newline {
                    _ = c.advance()
                }
            }
            continue
        }
        if c.current?.kind == .ident {
            let id = c.advance()!
            if c.peekText() == "(" {
                refs.append(SymbolOccurrence(name: id.text, line: id.line, column: id.column))
            }
            continue
        }
        _ = c.advance()
    }
    _ = aliases
}

private func parseSwift(
    _ tokens: [Tok],
    defs: inout [SymbolOccurrence],
    refs: inout [SymbolOccurrence],
    aliases: inout [SymbolAlias],
    scopes: inout [SourceRange]
) {
    var c = Cursor(tokens: tokens)
    while c.current != nil {
        c.skipNewlines()
        guard c.current != nil else { break }
        // modifiers (do not consume type-introducing `class`/`actor` here)
        var consumingMods = true
        while consumingMods {
            c.skipTrivia()
            guard let t = c.current, t.kind == .keyword else { break }
            switch t.text {
            case "public", "private", "internal", "open", "fileprivate",
                 "static", "final", "async", "nonisolated", "mutating", "override":
                _ = c.advance()
            case "class":
                // `class func` modifier vs `class Foo` type — peek next.
                let saved = c.i
                _ = c.advance()
                c.skipTrivia()
                if c.current?.kind == .keyword && c.current?.text == "func" {
                    // class func — keep class consumed
                } else {
                    c.i = saved // restore; treat as type keyword below
                    consumingMods = false
                }
            default:
                consumingMods = false
            }
        }
        if c.matchKw("func") {
            if let name = c.takeIdent() {
                defs.append(SymbolOccurrence(name: name.text, line: name.line, column: name.column))
            }
            // generics
            if c.peekText() == "<" { c.skipBalanced(open: "<", close: ">", scopes: &scopes) }
            c.skipBalanced(open: "(", close: ")", scopes: &scopes)
            while c.matchKw("async") || c.matchKw("throws") || c.matchKw("rethrows") {}
            if c.matchPunct("-") { _ = c.matchPunct(">") }
            if c.peekText() == "{" {
                c.skipBalanced(open: "{", close: "}", scopes: &scopes)
            }
            continue
        }
        if c.current?.kind == .keyword,
           ["struct", "class", "enum", "protocol", "actor"].contains(c.current!.text) {
            _ = c.advance()
            if let name = c.takeIdent() {
                defs.append(SymbolOccurrence(name: name.text, line: name.line, column: name.column))
            }
            if c.peekText() == "{" {
                c.skipBalanced(open: "{", close: "}", scopes: &scopes)
            }
            continue
        }
        if c.matchKw("let") || c.matchKw("var") {
            if let name = c.takeIdent() {
                defs.append(SymbolOccurrence(name: name.text, line: name.line, column: name.column))
            }
            continue
        }
        if c.matchKw("import") {
            if let name = c.takeIdent() {
                refs.append(SymbolOccurrence(name: name.text, line: name.line, column: name.column))
            }
            continue
        }
        if c.matchKw("typealias") {
            if let alias = c.takeIdent() {
                _ = c.matchPunct("=")
                if let orig = c.takeIdent() {
                    aliases.append(SymbolAlias(alias: alias.text, original: orig.text))
                    defs.append(SymbolOccurrence(name: alias.text, line: alias.line, column: alias.column))
                    refs.append(SymbolOccurrence(name: orig.text, line: orig.line, column: orig.column))
                }
            }
            continue
        }
        if c.current?.kind == .ident {
            let id = c.advance()!
            if c.peekText() == "(" {
                refs.append(SymbolOccurrence(name: id.text, line: id.line, column: id.column))
            }
            continue
        }
        _ = c.advance()
    }
}
