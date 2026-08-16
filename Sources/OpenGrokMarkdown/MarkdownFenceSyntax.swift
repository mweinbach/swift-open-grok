import Foundation

func markdownHighlightFenceLine(
    _ line: String,
    info: String
) -> [MarkdownRenderSegment] {
    guard let language = markdownFenceLanguage(info) else {
        return [MarkdownRenderSegment(text: line, style: .code)]
    }
    let keywords = markdownFenceKeywords[language] ?? []
    let lineComments = markdownFenceLineComments[language] ?? ["//"]
    let characters = Array(line)
    var segments: [MarkdownRenderSegment] = []
    var index = 0

    func append(_ text: String, _ style: MarkdownTextStyle) {
        guard !text.isEmpty else { return }
        if let last = segments.last, last.style == style {
            segments[segments.count - 1] = MarkdownRenderSegment(
                text: last.text + text,
                style: style
            )
        } else {
            segments.append(MarkdownRenderSegment(text: text, style: style))
        }
    }

    while index < characters.count {
        if lineComments.contains(where: { marker in
            let markerCharacters = Array(marker)
            guard index + markerCharacters.count <= characters.count else { return false }
            return Array(characters[index..<(index + markerCharacters.count)]) == markerCharacters
        }) {
            append(String(characters[index...]), .syntaxComment)
            index = characters.count
            continue
        }

        let character = characters[index]
        if character == "\"" || character == "'" || character == "`" {
            let quote = character
            var end = index + 1
            var escaped = false
            while end < characters.count {
                let current = characters[end]
                if escaped {
                    escaped = false
                } else if current == "\\" {
                    escaped = true
                } else if current == quote {
                    end += 1
                    break
                }
                end += 1
            }
            append(String(characters[index..<min(end, characters.count)]), .syntaxString)
            index = end
            continue
        }

        if character.isNumber {
            var end = index + 1
            while end < characters.count,
                  characters[end].isNumber || ".xXabcdefABCDEF_".contains(characters[end]) {
                end += 1
            }
            append(String(characters[index..<end]), .syntaxNumber)
            index = end
            continue
        }

        if character.isLetter || character == "_" {
            var end = index + 1
            while end < characters.count,
                  characters[end].isLetter || characters[end].isNumber || characters[end] == "_" {
                end += 1
            }
            let token = String(characters[index..<end])
            if keywords.contains(token) {
                append(token, .syntaxKeyword)
            } else if token.first?.isUppercase == true {
                append(token, .syntaxType)
            } else {
                append(token, .code)
            }
            index = end
            continue
        }

        append(String(character), .code)
        index += 1
    }
    return segments.isEmpty ? [MarkdownRenderSegment(text: line, style: .code)] : segments
}

func markdownFenceLanguage(_ info: String) -> String? {
    let token = info.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty else { return nil }
    let candidate: String
    let parts = token.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
    if parts.count == 3,
       Int(parts[0]) != nil,
       Int(parts[1]) != nil,
       !parts[2].isEmpty {
        candidate = String(parts[2].split(separator: "/").last ?? parts[2])
    } else {
        candidate = token.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? token
    }
    let lower = candidate.lowercased()
    let extensionToken = lower.split(separator: ".").last.map(String.init) ?? lower
    return markdownFenceLanguageAliases[extensionToken] ?? markdownFenceLanguageAliases[lower]
}

private let markdownFenceLanguageAliases: [String: String] = [
    "swift": "swift", "rs": "rust", "rust": "rust",
    "py": "python", "python": "python",
    "js": "javascript", "jsx": "javascript", "javascript": "javascript",
    "ts": "typescript", "tsx": "typescript", "typescript": "typescript",
    "json": "json", "sh": "shell", "bash": "shell", "zsh": "shell", "shell": "shell",
    "c": "c", "h": "c", "cc": "cpp", "cpp": "cpp", "cxx": "cpp", "hpp": "cpp",
    "go": "go", "java": "java", "kt": "kotlin", "kotlin": "kotlin",
    "rb": "ruby", "ruby": "ruby", "sql": "sql"
]

private let markdownFenceLineComments: [String: [String]] = [
    "python": ["#"], "shell": ["#"], "ruby": ["#"], "sql": ["--"]
]

private let markdownFenceKeywords: [String: Set<String>] = [
    "swift": ["actor", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue", "default", "defer", "deinit", "do", "else", "enum", "extension", "fallthrough", "false", "fileprivate", "for", "func", "guard", "if", "import", "in", "init", "inout", "internal", "is", "isolated", "let", "nil", "nonisolated", "open", "private", "protocol", "public", "repeat", "return", "self", "some", "static", "struct", "subscript", "super", "switch", "throw", "throws", "true", "try", "typealias", "var", "where", "while"],
    "rust": ["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while"],
    "python": ["and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "False", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass", "raise", "return", "True", "try", "while", "with", "yield"],
    "javascript": ["async", "await", "break", "case", "catch", "class", "const", "continue", "default", "delete", "do", "else", "export", "extends", "false", "finally", "for", "function", "if", "import", "in", "instanceof", "let", "new", "null", "return", "static", "super", "switch", "this", "throw", "true", "try", "typeof", "var", "void", "while", "yield"],
    "typescript": ["abstract", "as", "async", "await", "break", "case", "catch", "class", "const", "continue", "declare", "default", "do", "else", "enum", "export", "extends", "false", "finally", "for", "function", "if", "implements", "import", "in", "interface", "keyof", "let", "namespace", "never", "new", "null", "private", "protected", "public", "readonly", "return", "static", "super", "switch", "this", "throw", "true", "try", "type", "typeof", "var", "void", "while"],
    "json": ["true", "false", "null"],
    "shell": ["case", "do", "done", "elif", "else", "esac", "fi", "for", "function", "if", "in", "select", "then", "until", "while"],
    "c": ["auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long", "register", "restrict", "return", "short", "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void", "volatile", "while"],
    "cpp": ["alignas", "auto", "bool", "break", "case", "catch", "char", "class", "const", "constexpr", "continue", "default", "delete", "do", "double", "else", "enum", "explicit", "export", "extern", "false", "float", "for", "friend", "if", "inline", "int", "long", "namespace", "new", "nullptr", "operator", "private", "protected", "public", "return", "short", "signed", "sizeof", "static", "struct", "switch", "template", "this", "throw", "true", "try", "typedef", "typename", "union", "unsigned", "using", "virtual", "void", "volatile", "while"],
    "go": ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct", "switch", "type", "var"],
    "java": ["abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "const", "continue", "default", "do", "double", "else", "enum", "extends", "false", "final", "finally", "float", "for", "if", "implements", "import", "instanceof", "int", "interface", "long", "native", "new", "null", "package", "private", "protected", "public", "return", "short", "static", "strictfp", "super", "switch", "synchronized", "this", "throw", "throws", "transient", "true", "try", "void", "volatile", "while"],
    "kotlin": ["as", "break", "class", "continue", "do", "else", "false", "for", "fun", "if", "in", "interface", "is", "null", "object", "package", "return", "super", "this", "throw", "true", "try", "typealias", "typeof", "val", "var", "when", "while"],
    "ruby": ["alias", "and", "begin", "break", "case", "class", "def", "defined", "do", "else", "elsif", "end", "ensure", "false", "for", "if", "in", "module", "next", "nil", "not", "or", "redo", "rescue", "retry", "return", "self", "super", "then", "true", "undef", "unless", "until", "when", "while", "yield"],
    "sql": ["alter", "and", "as", "asc", "begin", "between", "by", "case", "create", "delete", "desc", "distinct", "drop", "else", "end", "exists", "from", "group", "having", "in", "insert", "into", "is", "join", "like", "limit", "not", "null", "on", "or", "order", "select", "set", "table", "then", "union", "update", "values", "when", "where"]
]
