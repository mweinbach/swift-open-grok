// TOML.swift
//
// A TOML parser producing `TOMLValue` — the Swift equivalent of Rust's
// `toml::Value`. The parser implements the TOML 1.0 subset used by Open Grok
// config files plus forward-compat tolerance:
//   * Bare keys, dotted keys, quoted keys.
//   * Tables: `[table]`, `[a.b.c]`.
//   * Arrays of tables: `[[table]]`.
//   * Strings: basic (`"..."` with escapes), literal (`'...'`), multi-line
//     basic (`"""..."""`), multi-line literal (`'''...'''`).
//   * Integers (decimal, hex `0x`, octal `0o`, binary `0b`, underscores).
//   * Floats (incl. `inf`, `nan`, exponents).
//   * Booleans.
//   * Arrays (heterogeneous, nested, trailing newlines).
//   * Inline tables `{ key = value, ... }`.
//   * Datetimes are stored as `.datetime(String)` (raw lexical form), since
//     the Open Grok config surface does not need typed datetimes.
//
// The parser preserves unknown-key semantics: every key encountered lands in
// the resulting table, so `deepMergeTOML` and `[[version_overrides]]` /
// `[[campaigns]]` stripping behave like the Rust reference.
//
// Error messages are span-only (line/column + kind) and never include the
// offending source line — matching `toml_error_detail` in
// `xai-grok-config/src/loader.rs`, which deliberately redacts the source line
// because it may carry a secret.

import Foundation

// MARK: - TOMLValue

/// A TOML value. Mirrors `toml::Value` with the cases Open Grok config uses.
public enum TOMLValue: Hashable, Sendable, Equatable {
    case string(String)
    case integer(Int64)
    case float(Double)
    case boolean(Bool)
    /// Raw lexical form of an RFC3339 datetime. Treated as a string for
    /// merge/round-trip; not parsed into a `Date`.
    case datetime(String)
    case array([TOMLValue])
    case table(TOMLTable)

    /// `true` when this value is an empty table (or the `.table` case with
    /// no entries). Mirrors Rust `value.as_table().map(|t| t.is_empty())`.
    public var isTableEmpty: Bool {
        if case let .table(t) = self { return t.isEmpty }
        return false
    }

    /// `true` when this value is a table (any size).
    public var isTable: Bool {
        if case .table = self { return true }
        return false
    }

    /// View as a table (mutable), or `nil` if not a table.
    public var table: TOMLTable? {
        if case let .table(t) = self { return t }
        return nil
    }

    /// View as a string, or `nil` if not a string (datetime does not coerce).
    public var stringValue: String? {
        if case let .string(s) = self { return s }
        return nil
    }

    /// View as a bool, or `nil` if not a bool.
    public var boolValue: Bool? {
        if case let .boolean(b) = self { return b }
        return nil
    }

    /// View as an Int64, or `nil` if not an integer.
    public var int64Value: Int64? {
        if case let .integer(i) = self { return i }
        return nil
    }

    /// View as a Double, or `nil` if not a number (int or float).
    public var doubleValue: Double? {
        switch self {
        case let .integer(i): return Double(i)
        case let .float(f): return f
        default: return nil
        }
    }

    /// View as an array, or `nil` if not an array.
    public var arrayValue: [TOMLValue]? {
        if case let .array(a) = self { return a }
        return nil
    }

    /// Subscript into a table by key. Returns `nil` for non-tables or
    /// missing keys. Mirrors Rust `value.get(key)`.
    public subscript(key: String) -> TOMLValue? {
        if case let .table(t) = self { return t[key] }
        return nil
    }

    /// Subscript into a table by dotted path. Each segment descends into a
    /// nested table. Returns `nil` if any segment is missing or non-table.
    public subscript(path path: [String]) -> TOMLValue? {
        var cur: TOMLValue? = self
        for seg in path {
            guard let v = cur, let t = v.table, let next = t[seg] else { return nil }
            cur = next
        }
        return cur
    }
}

extension TOMLValue: CustomStringConvertible {
    /// Render the value back to TOML. Best-effort; used by tests and
    /// diagnostics. The canonical serial form for round-trip is `encode()`.
    public var description: String { TOMLEncoder.encode(self) }
}

// MARK: - TOMLTable

/// An ordered TOML table. Keys preserve insertion order to keep
/// `[[campaigns]]` / `[[version_overrides]]` round-trip stable. Mirrors Rust
/// `toml::map::Map<String, Value>` (which is a BTreeMap; we use insertion
/// order here because the merge + patch semantics only rely on key presence,
/// not ordering — and insertion order is more useful for diagnostic output).
public struct TOMLTable: Hashable, Sendable, Equatable, ExpressibleByDictionaryLiteral {
    public typealias Key = String
    fileprivate var keys: [Key] = []
    fileprivate var values: [Key: TOMLValue] = [:]

    public init() {}

    public init(_ entries: [(Key, TOMLValue)]) {
        for (k, v) in entries { self[k] = v }
    }

    public init(dictionaryLiteral elements: (Key, TOMLValue)...) {
        for (k, v) in elements { self[k] = v }
    }

    public subscript(key: Key) -> TOMLValue? {
        get { values[key] }
        set {
            if let v = newValue {
                if values[key] == nil { keys.append(key) }
                values[key] = v
            } else {
                if values[key] != nil {
                    values.removeValue(forKey: key)
                    keys.removeAll { $0 == key }
                }
            }
        }
    }

    /// Insert a value at the end of the key order, overwriting any existing
    /// value at `key` (preserving its position).
    public mutating func insert(_ value: TOMLValue, forKey key: Key) {
        if values[key] == nil { keys.append(key) }
        values[key] = value
    }

    /// Remove and return the value at `key`. Returns `nil` if absent.
    @discardableResult
    public mutating func removeValue(forKey key: Key) -> TOMLValue? {
        let v = values.removeValue(forKey: key)
        if v != nil { keys.removeAll { $0 == key } }
        return v
    }

    /// `true` when `key` is present.
    public func contains(_ key: Key) -> Bool { values[key] != nil }

    public var isEmpty: Bool { keys.isEmpty }
    public var count: Int { keys.count }

    /// Insertion-ordered keys.
    public var allKeys: [Key] { keys }
    /// Insertion-ordered (key, value) pairs.
    public var pairs: [(Key, TOMLValue)] { keys.compactMap { k in values[k].map { (k, $0) } } }
    /// Insertion-ordered values.
    public var allValues: [TOMLValue] { keys.compactMap { values[$0] } }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(keys)
        for k in keys { hasher.combine(values[k]) }
    }

    public static func == (lhs: TOMLTable, rhs: TOMLTable) -> Bool {
        lhs.keys == rhs.keys && lhs.keys.allSatisfy { lhs.values[$0] == rhs.values[$0] }
    }
}

// MARK: - TOMLError

/// A TOML parse error. `line`/`column` are 1-based; `message` is the parser
/// kind (e.g. "duplicate key", "unterminated string"). The offending source
/// line is deliberately NOT included (it may carry a secret — see
/// `toml_error_detail`).
public struct TOMLError: Error, Hashable, Sendable, CustomStringConvertible {
    public let line: Int
    public let column: Int
    public let message: String

    public init(line: Int, column: Int, message: String) {
        self.line = line
        self.column = column
        self.message = message
    }

    public var description: String {
        "TOML parse error at line \(line), column \(column): \(message)"
    }
}

/// A snippet-free description of a TOML parse error: `"TOML parse error at
/// line L, column C: <what>"`. Mirrors `toml_error_detail` in
/// `xai-grok-config/src/loader.rs`. Never includes the offending source line
/// — `Display` echoes it and it may carry a secret — so this is safe to log
/// or surface to a client.
public func tomlErrorDetail(src: String, error: TOMLError) -> String {
    error.description
}

// MARK: - TOML parser

/// Parse a TOML document into a `TOMLValue.table` (the root table).
public func parseTOML(_ src: String) throws -> TOMLValue {
    var parser = TOMLParser(src: src)
    return try parser.parse()
}

/// Parse a TOML document into a `TOMLTable` (the root table).
public func parseTOMLTable(_ src: String) throws -> TOMLTable {
    let v = try parseTOML(src)
    if case let .table(t) = v { return t }
    return TOMLTable()
}

/// The TOML parser. Internal; users call `parseTOML`/`parseTOMLTable`.
struct TOMLParser {
    let src: String
    var pos: String.Index
    var line: Int = 1
    var col: Int = 1
    /// The root table being built.
    var root: TOMLTable = TOMLTable()
    /// The current table header's dotted path (root if empty).
    var currentPath: [String] = []
    /// Tracks whether the current table was created via `[[array]]` so a
    /// subsequent `[a.b]` re-entry into an array-of-tables element appends.
    /// Not needed for the Open Grok config surface (which uses `[[campaigns]]`
    /// and `[[version_overrides]]` at the root), but kept for forward compat.
    var arrayTablesPath: [String: Bool] = [:]

    init(src: String) {
        self.src = src
        self.pos = src.startIndex
    }

    // MARK: Lexer helpers

    var isAtEnd: Bool { pos >= src.endIndex }
    var current: Character? { isAtEnd ? nil : src[pos] }
    var next: Character? {
        let i = src.index(after: pos)
        return i < src.endIndex ? src[i] : nil
    }

    /// Advance the lexer by one character. Returns `Void` so call sites that
    /// only need the side effect stay warnings-clean under
    /// `-warnings-as-errors`.
    mutating func advance() {
        let c = src[pos]
        if c.isTOMLLineBreak {
            line += 1
            col = 1
        } else {
            col += 1
        }
        pos = src.index(after: pos)
    }

    mutating func skipWhitespaceAndComments() {
        while !isAtEnd {
            let c = src[pos]
            if c == " " || c == "\t" { advance() }
            else if c == "#" { skipComment() }
            else if c.isTOMLLineBreak { advance() }
            else { break }
        }
    }

    mutating func skipInlineWhitespace() {
        while !isAtEnd {
            let c = src[pos]
            if c == " " || c == "\t" { advance() }
            else { break }
        }
    }

    mutating func skipComment() {
        while !isAtEnd && !src[pos].isTOMLLineBreak { advance() }
    }

    func error(_ message: String) -> TOMLError {
        TOMLError(line: line, column: col, message: message)
    }

    // MARK: Entry point

    mutating func parse() throws -> TOMLValue {
        while !isAtEnd {
            skipWhitespaceAndComments()
            if isAtEnd { break }
            let c = src[pos]
            if c == "[" {
                try parseTableHeader()
            } else {
                // Parse key/value first (mutating lexer state only), then
                // write into `root` — avoids exclusivity violation from
                // `parseKeyValue(into: &root, ...)` overlapping self access.
                try parseKeyValueAtCurrentPath()
            }
            // After a key/value or table header, skip to next non-blank.
            skipWhitespaceAndComments()
        }
        return .table(root)
    }

    // MARK: Nested table mutation (value-type safe)

    /// Insert `value` at `path` under `table`, creating intermediate tables.
    /// Returns the updated table. Fails on duplicate leaves or non-table parents.
    func insertValue(
        _ value: TOMLValue,
        into table: TOMLTable,
        path: [String]
    ) throws -> TOMLTable {
        guard let head = path.first else { throw error("empty key path") }
        var table = table
        if path.count == 1 {
            if table[head] != nil {
                throw error("duplicate key '\(head)'")
            }
            table[head] = value
            return table
        }
        var child: TOMLTable
        if let existing = table[head] {
            // Descend into a table, or the last element of an array-of-tables.
            if case let .table(t) = existing {
                child = t
            } else if case let .array(arr) = existing, case let .table(t) = arr.last {
                // Write into the most recent array-of-tables element, then
                // rebuild the array with the updated last table.
                let updated = try insertValue(value, into: t, path: Array(path.dropFirst()))
                var newArr = arr
                newArr[newArr.count - 1] = .table(updated)
                table[head] = .array(newArr)
                return table
            } else {
                throw error("duplicate key '\(head)' is not a table")
            }
        } else {
            child = TOMLTable()
        }
        child = try insertValue(value, into: child, path: Array(path.dropFirst()))
        table[head] = .table(child)
        return table
    }

    /// Ensure a standard table exists at `path` (create intermediate tables).
    func ensureTableExists(in table: TOMLTable, path: [String]) throws -> TOMLTable {
        guard let head = path.first else { return table }
        var table = table
        if path.count == 1 {
            if table[head] == nil {
                table[head] = .table(TOMLTable())
            } else if case .table = table[head]! {
                // already a table — ok (re-entry)
            } else if case let .array(arr) = table[head]!, case .table = arr.last {
                // re-entry into last array-of-tables element is allowed
            } else {
                throw error("duplicate key '\(head)' is not a table")
            }
            return table
        }
        if table[head] == nil {
            table[head] = .table(TOMLTable())
        }
        if case let .table(t) = table[head]! {
            let updated = try ensureTableExists(in: t, path: Array(path.dropFirst()))
            table[head] = .table(updated)
            return table
        }
        if case var .array(arr) = table[head]!, case let .table(t) = arr.last {
            let updated = try ensureTableExists(in: t, path: Array(path.dropFirst()))
            arr[arr.count - 1] = .table(updated)
            table[head] = .array(arr)
            return table
        }
        throw error("duplicate key '\(head)' is not a table")
    }

    /// Append a fresh empty table to the array-of-tables at `path`.
    func appendArrayTable(in table: TOMLTable, path: [String]) throws -> TOMLTable {
        guard let head = path.first else { throw error("empty table header") }
        var table = table
        if path.count == 1 {
            var arr: [TOMLValue]
            if table[head] == nil {
                arr = []
            } else if case let .array(existing) = table[head]! {
                arr = existing
            } else {
                throw error("key '\(head)' is not an array of tables")
            }
            arr.append(.table(TOMLTable()))
            table[head] = .array(arr)
            return table
        }
        if table[head] == nil {
            table[head] = .table(TOMLTable())
        }
        if case let .table(t) = table[head]! {
            let updated = try appendArrayTable(in: t, path: Array(path.dropFirst()))
            table[head] = .table(updated)
            return table
        }
        if case var .array(arr) = table[head]!, case let .table(t) = arr.last {
            let updated = try appendArrayTable(in: t, path: Array(path.dropFirst()))
            arr[arr.count - 1] = .table(updated)
            table[head] = .array(arr)
            return table
        }
        throw error("duplicate key '\(head)' is not a table")
    }

    // MARK: Table headers

    mutating func parseTableHeader() throws {
        precondition(src[pos] == "[")
        advance() // consume `[`
        let isArray = current == "["
        if isArray { advance() } // consume second `[`
        skipInlineWhitespace()
        let path = try parseDottedKey()
        skipInlineWhitespace()
        // Close brackets.
        guard current == "]" else { throw error("expected ']' to close table header") }
        advance()
        if isArray {
            guard current == "]" else { throw error("expected ']]' to close array-of-tables header") }
            advance()
        }
        // Validate path is non-empty (TOML disallows `[]`).
        if path.isEmpty { throw error("empty table header") }
        if isArray {
            root = try appendArrayTable(in: root, path: path)
            currentPath = path
        } else {
            root = try ensureTableExists(in: root, path: path)
            currentPath = path
        }
        // Skip the rest of the line (whitespace + optional comment).
        skipInlineWhitespace()
        if let c = current, c == "#" { skipComment() }
        if let c = current, !c.isTOMLLineBreak {
            throw error("expected newline after table header, got '\(c)'")
        }
    }

    // MARK: Keys

    /// Parse a dotted key (`a.b."c"`). Returns the list of key segments.
    mutating func parseDottedKey() throws -> [String] {
        var segments: [String] = []
        while true {
            skipInlineWhitespace()
            let seg = try parseKey()
            segments.append(seg)
            skipInlineWhitespace()
            // Consume the dotted-key separator explicitly (advance is Void).
            if current == "." {
                advance()
                continue
            }
            break
        }
        return segments
    }

    /// Parse a single key (bare, basic-string, or literal-string).
    mutating func parseKey() throws -> String {
        let c = current
        if c == "\"" { return try parseBasicString() }
        if c == "'" { return try parseLiteralString() }
        // Bare key: A-Z a-z 0-9 _ -
        var s = ""
        while let c = current {
            if c.isLetter || c.isNumber || c == "_" || c == "-" {
                s.append(c)
                advance()
            } else { break }
        }
        if s.isEmpty { throw error("expected a key") }
        return s
    }

    // MARK: Key/value

    /// Parse a `key = value` (or `a.b.c = value`) into the current table path
    /// under `root`. Value-type safe: rebuilds nested tables on write-back.
    mutating func parseKeyValueAtCurrentPath() throws {
        let keyPath = try parseDottedKey()
        skipInlineWhitespace()
        guard current == "=" else {
            throw error("expected '=' after key '\(keyPath.joined(separator: "."))'")
        }
        advance()
        skipInlineWhitespace()
        let value = try parseValue()
        // Skip trailing inline whitespace + optional comment.
        skipInlineWhitespace()
        if let c = current, c == "#" { skipComment() }
        if let c = current, !c.isTOMLLineBreak {
            throw error("expected newline after value, got '\(c)'")
        }
        let fullPath = currentPath + keyPath
        root = try insertValue(value, into: root, path: fullPath)
    }

    // MARK: Values

    mutating func parseValue() throws -> TOMLValue {
        guard let c = current else { throw error("expected a value") }
        switch c {
        case "\"":
            // Multi-line basic ("""...""") or basic ("...").
            if next == "\"" {
                let i = src.index(after: pos)
                if i < src.endIndex && src[i] == "\"" {
                    return .string(try parseMultilineBasicString())
                }
                return .string(try parseBasicString())
            }
            return .string(try parseBasicString())
        case "'":
            // Multi-line literal ('''...''') or literal ('...').
            if next == "'" {
                let i = src.index(after: pos)
                if i < src.endIndex && src[i] == "'" {
                    return .string(try parseMultilineLiteralString())
                }
                return .string(try parseLiteralString())
            }
            return .string(try parseLiteralString())
        case "[":
            return try parseArray()
        case "{":
            return try parseInlineTable()
        case "t", "f":
            return try parseBoolean()
        case "0"..."9", "-", "+":
            return try parseNumberOrDatetime()
        case "i":
            // `inf` / `nan`
            return try parseFloatSpecial()
        case "n":
            // `nan`
            return try parseFloatSpecial()
        default:
            throw error("unexpected character '\(c)' at start of value")
        }
    }

    // MARK: Booleans

    mutating func parseBoolean() throws -> TOMLValue {
        if src[pos...].hasPrefix("true") {
            advance4("true"); return .boolean(true)
        }
        if src[pos...].hasPrefix("false") {
            advance4("false"); return .boolean(false)
        }
        throw error("expected 'true' or 'false'")
    }

    mutating func advance4(_ s: String) {
        for _ in 0..<s.count {
            if !isAtEnd { advance() }
        }
    }

    // MARK: Numbers / datetimes

    /// Parse a number or datetime starting with `[0-9]`, `-`, or `+`.
    /// The lexer looks ahead for `:`/`-` separators to distinguish a datetime
    /// from a date-only or plain integer.
    mutating func parseNumberOrDatetime() throws -> TOMLValue {
        // Snapshot the start; we may consume a datetime lexically.
        let start = pos
        let startLine = line, startCol = col
        // First, try to lex a datetime by matching the lookahead pattern.
        if let dt = tryLexDatetime() {
            return .datetime(dt)
        }
        // Reset to the start in case the datetime lookahead advanced.
        pos = start
        line = startLine
        col = startCol
        // Otherwise lex a number.
        return try parseNumber()
    }

    /// Look ahead for an RFC3339-ish datetime. If matched, consumes it and
    /// returns the raw lexical form. Returns `nil` (and consumes nothing) if
    /// the lookahead does not match.
    mutating func tryLexDatetime() -> String? {
        // Datetime shapes we recognize (TOML 1.0):
        //   YYYY-MM-DD
        //   YYYY-MM-DDTHH:MM:SS[.frac][Z or ±HH:MM]
        //   HH:MM:SS[.frac]  (time only)
        // We require at least one `-` or `:` after a digit, and limit the
        // lexical run to digits, `-`, `:`, `.`, `T`, `t`, `Z`, `z`, `+`, and
        // space (only between date and time if a `T`/`t` is not used).
        // Quick check: must start with a digit (or sign followed by digit).
        guard let c = current, c.isNumber || c == "-" || c == "+" else { return nil }
        // Scan forward; bail if we see anything not in the datetime charset.
        var lookahead = ""
        var idx = pos
        var sawSep = false
        while idx < src.endIndex {
            let ch = src[idx]
            if ch.isNumber || ch == "-" || ch == ":" || ch == "." || ch == "T" || ch == "t" || ch == "Z" || ch == "z" || ch == "+" {
                lookahead.append(ch)
                if ch == "-" || ch == ":" { sawSep = true }
                idx = src.index(after: idx)
            } else if ch == " " {
                // A single space is allowed between date and time only if the
                // next non-space char is a digit (time component).
                let next = src.index(after: idx)
                if next < src.endIndex && src[next].isNumber {
                    lookahead.append(ch)
                    idx = next
                } else { break }
            } else { break }
        }
        guard sawSep, lookahead.count >= 5 else { return nil }
        // Consume the lookahead.
        for _ in 0..<lookahead.count { advance() }
        return lookahead
    }

    /// Parse a number (integer or float). Handles hex/oct/bin, signed
    /// decimals with underscores, exponents, `inf`, and `nan`.
    mutating func parseNumber() throws -> TOMLValue {
        // Sign
        var sign: Int64 = 1
        if current == "-" { sign = -1; advance() }
        else if current == "+" { advance() }
        // Non-decimal prefixes. `parseIntRadix` already returns a `.integer` value.
        if current == "0", let n = next {
            if n == "x" { return try parseIntRadix(16, sign: sign, prefixLen: 2) }
            if n == "o" { return try parseIntRadix(8, sign: sign, prefixLen: 2) }
            if n == "b" { return try parseIntRadix(2, sign: sign, prefixLen: 2) }
        }
        // Decimal int or float. Scan digits + `_`, watching for `.`/`e`/`E`.
        var intDigits = ""
        while let c = current {
            if c.isNumber { intDigits.append(c); advance() }
            else if c == "_" { advance() }
            else { break }
        }
        if intDigits.isEmpty {
            // Could be `inf` / `nan` after a sign.
            if current == "i" || current == "n" {
                return try parseFloatSpecial(sign: sign)
            }
            throw error("expected digits")
        }
        // Float?
        if current == "." {
            // Confirm next char is a digit (TOML requires digit on both sides).
            let nextIdx = src.index(after: pos)
            guard nextIdx < src.endIndex, src[nextIdx].isNumber else {
                throw error("expected digit after '.'")
            }
            return try parseFloat(intPart: intDigits, sign: sign)
        }
        if current == "e" || current == "E" {
            return try parseFloatWithExp(intPart: intDigits, fracPart: "", sign: sign)
        }
        // Plain integer.
        guard let v = Int64(intDigits) else {
            throw error("integer '\(intDigits)' out of range")
        }
        return .integer(sign * v)
    }

    mutating func parseIntRadix(_ radix: Int, sign: Int64, prefixLen: Int) throws -> TOMLValue {
        // Consume prefix `0x`/`0o`/`0b`.
        for _ in 0..<prefixLen { advance() }
        var digits = ""
        while let c = current {
            if c.isHexDigit || c == "_" {
                if c != "_" { digits.append(c) }
                advance()
            } else { break }
        }
        if digits.isEmpty { throw error("expected digits after radix prefix") }
        guard let v = UInt64(digits, radix: radix) else {
            throw error("integer '\(digits)' radix \(radix) out of range")
        }
        // Hex/oct/bin are unsigned; apply sign per TOML.
        if sign < 0 {
            // Saturate to Int64.min on overflow.
            if v > UInt64(Int64.max) + 1 { return .integer(Int64.min) }
            if v == UInt64(Int64.max) + 1 { return .integer(Int64.min) }
            return .integer(-Int64(v))
        }
        if v > UInt64(Int64.max) { return .integer(Int64.max) }
        return .integer(Int64(v))
    }

    mutating func parseFloat(intPart: String, sign: Int64) throws -> TOMLValue {
        advance() // consume `.`
        var frac = ""
        while let c = current {
            if c.isNumber { frac.append(c); advance() }
            else if c == "_" { advance() }
            else { break }
        }
        return try parseFloatWithExp(intPart: intPart, fracPart: frac, sign: sign)
    }

    mutating func parseFloatWithExp(intPart: String, fracPart: String, sign: Int64) throws -> TOMLValue {
        var expSuffix = ""
        if current == "e" || current == "E" {
            expSuffix.append("e")
            advance()
            if current == "+" || current == "-" {
                expSuffix.append(current!); advance()
            }
            var digits = ""
            while let c = current, c.isNumber {
                digits.append(c); advance()
            }
            if digits.isEmpty { throw error("expected exponent digits") }
            expSuffix += digits
        }
        let combined: String
        if fracPart.isEmpty && expSuffix.isEmpty {
            combined = intPart
        } else if fracPart.isEmpty {
            // Integer with exponent: `1e2` — do not inject a bare '.' before `e`.
            combined = intPart + expSuffix
        } else {
            combined = "\(intPart).\(fracPart)\(expSuffix)"
        }
        guard let v = Double(combined) else {
            throw error("invalid float '\(combined)'")
        }
        return .float(sign < 0 ? -v : v)
    }

    /// Parse `inf` / `nan` (with optional leading sign already consumed).
    mutating func parseFloatSpecial(sign: Int64 = 1) throws -> TOMLValue {
        if src[pos...].hasPrefix("inf") {
            advance4("inf")
            let inf = Double.infinity
            return .float(sign < 0 ? -inf : inf)
        }
        if src[pos...].hasPrefix("nan") {
            advance4("nan")
            return .float(Double.nan)
        }
        throw error("expected 'inf' or 'nan'")
    }

    // MARK: Strings

    /// Parse a basic string `"..."` with escapes.
    mutating func parseBasicString() throws -> String {
        precondition(current == "\"")
        advance() // consume opening `"`
        var out = ""
        while !isAtEnd {
            let c = src[pos]
            if c == "\"" { advance(); return out }
            if c == "\\" {
                out.append(try parseEscape())
                continue
            }
            if c.isTOMLLineBreak { throw error("unterminated basic string (newline)") }
            out.append(c)
            advance()
        }
        throw error("unterminated basic string")
    }

    mutating func parseEscape() throws -> Character {
        precondition(current == "\\")
        advance() // consume backslash
        guard let c = current else { throw error("unterminated escape") }
        advance()
        switch c {
        case "n": return "\n"
        case "t": return "\t"
        case "r": return "\r"
        case "\"": return "\""
        case "\\": return "\\"
        case "b": return "\u{08}"
        case "f": return "\u{0C}"
        case "/": return "/"
        case "u":
            return try parseUnicodeEscape(length: 4)
        case "U":
            return try parseUnicodeEscape(length: 8)
        default:
            throw error("invalid escape '\\\(c)'")
        }
    }

    mutating func parseUnicodeEscape(length: Int) throws -> Character {
        var hex = ""
        for _ in 0..<length {
            guard let c = current, c.isHexDigit else {
                throw error("invalid unicode escape (expected \(length) hex digits)")
            }
            hex.append(c); advance()
        }
        guard let v = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(v) else {
            throw error("invalid unicode scalar U+\(hex)")
        }
        return Character(scalar)
    }

    /// Parse a literal string `'...'` (no escapes).
    mutating func parseLiteralString() throws -> String {
        precondition(current == "'")
        advance()
        var out = ""
        while !isAtEnd {
            let c = src[pos]
            if c == "'" { advance(); return out }
            if c.isTOMLLineBreak { throw error("unterminated literal string (newline)") }
            out.append(c); advance()
        }
        throw error("unterminated literal string")
    }

    /// Parse a multi-line basic string `"""..."""`. A leading newline
    /// immediately after `"""` is trimmed. Escapes are processed; line-ending
    /// backslash trims following whitespace.
    mutating func parseMultilineBasicString() throws -> String {
        // Consume opening `"""`.
        advance(); advance(); advance()
        // Trim a leading newline.
        if current?.isTOMLLineBreak == true { advance() }
        var out = ""
        while !isAtEnd {
            // Closing `"""`?
            if src[pos...].hasPrefix("\"\"\"") {
                advance(); advance(); advance()
                return out
            }
            let c = src[pos]
            if c == "\\" {
                // Line-ending backslash: trim whitespace until next non-WS.
                let nextIdx = src.index(after: pos)
                if nextIdx < src.endIndex, src[nextIdx].isTOMLLineBreak {
                    advance() // consume backslash
                    while !isAtEnd {
                        let ch = src[pos]
                        if ch == " " || ch == "\t" || ch.isTOMLLineBreak { advance() }
                        else { break }
                    }
                    continue
                }
                out.append(try parseEscape())
                continue
            }
            out.append(c)
            advance()
        }
        throw error("unterminated multi-line basic string")
    }

    /// Parse a multi-line literal string `'''...'''`. A leading newline
    /// immediately after `'''` is trimmed. No escapes.
    mutating func parseMultilineLiteralString() throws -> String {
        advance(); advance(); advance()
        if current?.isTOMLLineBreak == true { advance() }
        var out = ""
        while !isAtEnd {
            if src[pos...].hasPrefix("'''") {
                advance(); advance(); advance()
                return out
            }
            let c = src[pos]
            out.append(c)
            advance()
        }
        throw error("unterminated multi-line literal string")
    }

    // MARK: Arrays

    /// Parse an array `[ ... ]`. Heterogeneous; trailing newlines/comments OK.
    mutating func parseArray() throws -> TOMLValue {
        precondition(current == "[")
        advance()
        var items: [TOMLValue] = []
        while true {
            skipWhitespaceAndComments()
            if current == "]" { advance(); return .array(items) }
            if isAtEnd { throw error("unterminated array") }
            let v = try parseValue()
            items.append(v)
            skipWhitespaceAndComments()
            if current == "," { advance(); continue }
            if current == "]" { advance(); return .array(items) }
            throw error("expected ',' or ']' in array")
        }
    }

    // MARK: Inline tables

    /// Parse an inline table `{ k = v, ... }`. Newlines NOT allowed per TOML
    /// 1.0 (we tolerate them for forward-compat).
    mutating func parseInlineTable() throws -> TOMLValue {
        precondition(current == "{")
        advance()
        var t = TOMLTable()
        while true {
            skipInlineWhitespace()
            if current == "}" { advance(); return .table(t) }
            // key = value
            let keyPath = try parseDottedKey()
            skipInlineWhitespace()
            guard current == "=" else { throw error("expected '=' in inline table") }
            advance()
            skipInlineWhitespace()
            let v = try parseValue()
            t = try insertValue(v, into: t, path: keyPath)
            skipInlineWhitespace()
            if current == "," { advance(); continue }
            if current == "}" { advance(); return .table(t) }
            throw error("expected ',' or '}' in inline table")
        }
    }
}

// MARK: - TOMLEncoder

/// A TOML serializer. Top-level must be a `TOMLValue.table`. Tables nest;
/// an array whose elements are all tables renders as `[[array-of-tables]]`.
///
/// This is the config write path (see `ConfigWrite.swift`), matching
/// upstream's `toml::to_string_pretty` re-serialize rather than a
/// format-preserving edit: key order is preserved, comments are not.
public enum TOMLEncoder {
    public static func encode(_ value: TOMLValue) -> String {
        var out = ""
        switch value {
        case let .table(t):
            encodeTable(t, into: &out, prefix: [])
        default:
            out += encodeInline(value)
        }
        return out
    }

    static func encodeTable(_ t: TOMLTable, into out: inout String, prefix: [String]) {
        // First, emit non-table key/values.
        var nestedTables: [(String, TOMLTable)] = []
        var nestedArrayTables: [(String, [TOMLValue])] = []
        for (k, v) in t.pairs {
            switch v {
            case .table(let inner):
                nestedTables.append((k, inner))
            case .array(let arr) where !arr.isEmpty && arr.allSatisfy { if case .table = $0 { return true } else { return false } }:
                nestedArrayTables.append((k, arr))
            default:
                out += "\(escapeKey(k)) = \(encodeInline(v))\n"
            }
        }
        // Then nested tables. A blank line separates each header from what
        // precedes it, but never leads the document.
        func header(_ text: String, into out: inout String) {
            if !out.isEmpty { out += "\n" }
            out += text + "\n"
        }
        for (k, inner) in nestedTables {
            let path = prefix + [k]
            header("[\(path.map(escapeKey).joined(separator: "."))]", into: &out)
            encodeTable(inner, into: &out, prefix: path)
        }
        for (k, arr) in nestedArrayTables {
            let path = prefix + [k]
            for el in arr {
                if case let .table(t) = el {
                    header("[[\(path.map(escapeKey).joined(separator: "."))]]", into: &out)
                    encodeTable(t, into: &out, prefix: path)
                }
            }
        }
    }

    static func encodeInline(_ v: TOMLValue) -> String {
        switch v {
        case let .string(s): return escapeBasicString(s)
        case let .integer(i): return String(i)
        case let .float(f):
            if f.isInfinite { return f > 0 ? "inf" : "-inf" }
            if f.isNaN { return "nan" }
            return String(f)
        case let .boolean(b): return b ? "true" : "false"
        case let .datetime(s): return s
        case let .array(arr):
            return "[" + arr.map(encodeInline).joined(separator: ", ") + "]"
        case let .table(t):
            let pairs = t.pairs.map { "\(escapeKey($0.0)) = \(encodeInline($0.1))" }
            return "{ " + pairs.joined(separator: ", ") + " }"
        }
    }

    static func escapeKey(_ k: String) -> String {
        // Bare-key charset is ASCII-only: A-Za-z0-9_-. `Character.isLetter`
        // and `.isNumber` are true for non-ASCII scalars (e.g. "é", "٣"), so
        // testing them alone would emit an unquoted key TOML cannot parse.
        let isBare = k.allSatisfy { c in
            guard let ascii = c.asciiValue else { return false }
            switch ascii {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"):
                return true
            case UInt8(ascii: "_"), UInt8(ascii: "-"):
                return true
            default:
                return false
            }
        }
        if !k.isEmpty && isBare { return k }
        return escapeBasicString(k)
    }

    static func escapeBasicString(_ s: String) -> String {
        var out = "\""
        for c in s {
            switch c {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if let scalar = c.unicodeScalars.first, scalar.value < 0x20 {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.append(c)
                }
            }
        }
        out += "\""
        return out
    }
}

// MARK: - Convenience: parse from data/file

/// Parse a TOML document from `Data` (UTF-8). Throws `TOMLError` on parse
/// failure or `EncodingError` if the data is not valid UTF-8.
public func parseTOML(_ data: Data) throws -> TOMLValue {
    let s = String(data: data, encoding: .utf8) ?? ""
    return try parseTOML(s)
}

extension Character {
    var isTOMLLineBreak: Bool {
        self == "\n" || self == "\r" || self == "\r\n"
    }

    var isHexDigit: Bool {
        return isNumber || ("a"..."f").contains(self) || ("A"..."F").contains(self)
    }
}
