// FileSearchContext.swift
//
// @-context detection: parses `@query` tokens from prompt text + cursor position.
//
// Given the prompt text and cursor position, determines whether the cursor is
// inside an `@`-token and extracts the query string for fuzzy matching.
//
// Rules:
// - The `@` must NOT be preceded by an alphanumeric character or underscore
//   (avoids triggering on email addresses like `user@example.com`).
// - The token extends from `@` to the first whitespace, comma, or semicolon.
// - The cursor must be within the token range.
// - The query is the text between `@` (exclusive) and the cursor.
//
// Special modes:
// - Dir mode: query ends with `/` -> restrict matches to directories only.
// - Hidden mode: query starts with `!` -> show hidden/gitignored files.

import Foundation
import OpenGrokPagerRender

/// Context for the current @-completion token.
public struct AtContext: Sendable, Equatable, Hashable {
    /// Character range in the input text (includes the `@` as the first character).
    public var range: Range<Int>
    /// Cursor character position within the input text.
    public var cursor: Int
    /// Query string: text after `@` (and after `!` if hidden mode) up to cursor.
    public var query: String

    public init(range: Range<Int>, cursor: Int, query: String) {
        self.range = range
        self.cursor = cursor
        self.query = query
    }

    /// Whether the query requests directory-only results (ends with `/`).
    public var isDirMode: Bool {
        query.hasSuffix("/")
    }

    /// Whether the query requests hidden/gitignored files (starts with `!`).
    public var isHiddenMode: Bool {
        query.hasPrefix("!")
    }

    /// The effective query for the fuzzy matcher (strips leading `!`).
    public var matcherQuery: String {
        if query.hasPrefix("!") {
            return String(query.dropFirst())
        }
        return query
    }

    /// Byte / character range covering only the path portion of the @-token: starts
    /// after the leading `@` and (in hidden mode) the `!` prefix, ends at
    /// the @-token end.
    public var pathRange: Range<Int> {
        let prefix = 1 + (isHiddenMode ? 1 : 0)
        let start = min(range.lowerBound + prefix, range.upperBound)
        return start..<range.upperBound
    }

    /// Detect an @-completion context from prompt text and cursor position.
    public static func detect(text: String, cursor: Int) -> AtContext? {
        detectWithDrill(text: text, cursor: cursor, drillPrefix: nil)
    }

    /// Like `detect`, but treats whitespace inside `drillPrefix` as part of the @-token.
    public static func detectWithDrill(
        text: String,
        cursor: Int,
        drillPrefix: String?
    ) -> AtContext? {
        guard cursor >= 0, cursor <= text.count else {
            return nil
        }

        let prefixSubstring = text.prefix(cursor)
        guard let atIndex = prefixSubstring.lastIndex(of: "@") else {
            return nil
        }

        // Reject if `@` is preceded by alphanumeric or underscore (email-like).
        if atIndex > text.startIndex {
            let prevChar = text[text.index(before: atIndex)]
            if prevChar.isLetter || prevChar.isNumber || prevChar == "_" {
                return nil
            }
        }

        let atInt = text.distance(from: text.startIndex, to: atIndex)
        let contentStartIndex = text.index(after: atIndex)
        let contentStartInt = atInt + 1

        let afterAtSubstring = text[contentStartIndex...]
        let afterBangInt: Int
        if afterAtSubstring.hasPrefix("!") {
            afterBangInt = contentStartInt + 1
        } else {
            afterBangInt = contentStartInt
        }

        // Whitespace inside the drilled prefix is path content, not a terminator.
        let internalUntil: Int?
        if let drill = drillPrefix, !drill.isEmpty {
            let afterBangIndex = text.index(text.startIndex, offsetBy: afterBangInt)
            let rest = text[afterBangIndex...]
            if rest.hasPrefix(drill) {
                internalUntil = afterBangInt + drill.count
            } else {
                internalUntil = nil
            }
        } else {
            internalUntil = nil
        }

        // Find the end of the @-token: first whitespace, comma, or semicolon after `@`.
        var tokenEnd = text.count
        var currentIndex = contentStartIndex
        var currentOffset = contentStartInt

        while currentIndex < text.endIndex {
            let ch = text[currentIndex]
            let isTerminator = ch.isWhitespace || ch == "," || ch == ";"
            let isInsideDrill = internalUntil.map { currentOffset < $0 } ?? false
            if isTerminator && !isInsideDrill {
                tokenEnd = currentOffset
                break
            }
            currentIndex = text.index(after: currentIndex)
            currentOffset += 1
        }

        // Cursor must be within the @-token.
        if cursor > tokenEnd {
            return nil
        }

        let cursorIndex = text.index(text.startIndex, offsetBy: cursor)
        let query = String(text[contentStartIndex..<cursorIndex])

        return AtContext(
            range: atInt..<tokenEnd,
            cursor: cursor,
            query: query
        )
    }
}

/// Detect an @-completion context from prompt text and cursor position.
public func detect(text: String, cursor: Int) -> AtContext? {
    AtContext.detect(text: text, cursor: cursor)
}

/// Like `detect`, but treats whitespace inside `drillPrefix` as part of the @-token.
public func detectWithDrill(
    text: String,
    cursor: Int,
    drillPrefix: String?
) -> AtContext? {
    AtContext.detectWithDrill(text: text, cursor: cursor, drillPrefix: drillPrefix)
}
