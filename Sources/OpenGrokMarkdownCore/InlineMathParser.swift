import Foundation

struct InlineMathParser {
    struct Match {
        let source: String
        let display: Bool
        let endIndex: Int
    }

    private enum Delimiter {
        case dollar(display: Bool)
        case parenthesis
        case bracket
        case equation(starred: Bool)

        var display: Bool {
            switch self {
            case let .dollar(display): display
            case .parenthesis: false
            case .bracket, .equation: true
            }
        }

        var opening: [Character] {
            switch self {
            case let .dollar(display): Array(display ? "$$" : "$")
            case .parenthesis: Array("\\(")
            case .bracket: Array("\\[")
            case let .equation(starred): Array(starred ? "\\begin{equation*}" : "\\begin{equation}")
            }
        }

        var closing: [Character] {
            switch self {
            case let .dollar(display): Array(display ? "$$" : "$")
            case .parenthesis: Array("\\)")
            case .bracket: Array("\\]")
            case let .equation(starred): Array(starred ? "\\end{equation*}" : "\\end{equation}")
            }
        }
    }

    static func parse(_ characters: [Character], at index: Int) -> Match? {
        guard let delimiter = delimiter(in: characters, at: index) else { return nil }
        let contentStart = index + delimiter.opening.count
        guard contentStart < characters.count else { return nil }

        if case .dollar(display: false) = delimiter,
           characters[contentStart].isWhitespace {
            return nil
        }

        var cursor = contentStart
        while cursor < characters.count {
            if !delimiter.display, characters[cursor].isNewline { return nil }

            if matches(delimiter.closing, in: characters, at: cursor),
               !isEscaped(in: characters, at: cursor),
               isValidClosing(delimiter, in: characters, at: cursor) {
                let content = String(characters[contentStart..<cursor])
                let normalized: String
                if case .parenthesis = delimiter {
                    normalized = content.trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    normalized = content
                }
                guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                return Match(
                    source: normalized,
                    display: delimiter.display,
                    endIndex: cursor + delimiter.closing.count
                )
            }

            cursor += 1
        }

        return nil
    }

    private static func delimiter(in characters: [Character], at index: Int) -> Delimiter? {
        guard characters.indices.contains(index) else { return nil }

        if characters[index] == "$" {
            guard index == 0 || characters[index - 1] != "$" else { return nil }
            let display = index + 1 < characters.count && characters[index + 1] == "$"
            let afterOpening = index + (display ? 2 : 1)
            guard afterOpening >= characters.count || characters[afterOpening] != "$" else {
                return nil
            }
            return .dollar(display: display)
        }

        guard characters[index] == "\\", !isEscaped(in: characters, at: index) else {
            return nil
        }

        for candidate: Delimiter in [.parenthesis, .bracket, .equation(starred: true), .equation(starred: false)] {
            if matches(candidate.opening, in: characters, at: index) {
                return candidate
            }
        }

        return nil
    }

    private static func isValidClosing(
        _ delimiter: Delimiter,
        in characters: [Character],
        at index: Int
    ) -> Bool {
        guard case let .dollar(display) = delimiter else { return true }

        if index > 0 && characters[index - 1] == "$" { return false }
        let afterClosing = index + delimiter.closing.count
        if afterClosing < characters.count && characters[afterClosing] == "$" { return false }

        guard !display else { return true }
        if index == 0 || characters[index - 1].isWhitespace { return false }
        return afterClosing >= characters.count || !characters[afterClosing].isNumber
    }

    private static func matches(_ delimiter: [Character], in characters: [Character], at index: Int) -> Bool {
        guard index + delimiter.count <= characters.count else { return false }
        return zip(delimiter, characters[index..<(index + delimiter.count)]).allSatisfy { $0 == $1 }
    }

    private static func isEscaped(in characters: [Character], at index: Int) -> Bool {
        guard index > 0 else { return false }
        var cursor = index
        var backslashes = 0
        while cursor > 0 && characters[cursor - 1] == "\\" {
            backslashes += 1
            cursor -= 1
        }
        return !backslashes.isMultiple(of: 2)
    }
}
