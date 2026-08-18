import Foundation
import OpenGrokPagerRender

actor LiveEditHighlightWorker {
    static let maximumBytes = 2 * 1024 * 1024
    static let maximumLines = 50_000
    typealias Operation = @Sendable ([PagerEditFile], URL) -> [PagerEditFile]?

    private var generations: [String: UInt64] = [:]
    private let operation: Operation

    init(operation: Operation? = nil) {
        self.operation = operation ?? { files, workingDirectory in
            Self.compute(files: files, workingDirectory: workingDirectory)
        }
    }

    func highlight(
        callID: String,
        files: [PagerEditFile],
        workingDirectory: URL
    ) async -> [PagerEditFile]? {
        let generation = (generations[callID] ?? 0) &+ 1
        generations[callID] = generation
        let operation = self.operation
        let result = await Task.detached(priority: .utility) {
            operation(files, workingDirectory)
        }.value
        guard generations[callID] == generation else { return nil }
        generations.removeValue(forKey: callID)
        return result
    }

    private static func compute(
        files: [PagerEditFile],
        workingDirectory: URL
    ) -> [PagerEditFile]? {
        var highlighted: [PagerEditFile] = []
        highlighted.reserveCapacity(files.count)
        var producedAny = false

        for var file in files {
            guard let syntax = Syntax.forPath(file.path),
                  let text = readCapped(path: file.path, workingDirectory: workingDirectory),
                  validate(hunks: file.hunks, against: text)
            else {
                file.highlights = []
                highlighted.append(file)
                continue
            }
            let lastLine = file.hunks
                .flatMap { $0 }
                .filter { $0.tag != .delete }
                .map(\.ln)
                .max() ?? 0
            guard lastLine > 0 else {
                highlighted.append(file)
                continue
            }
            let lines = splitLines(text)
            let limit = min(lastLine, lines.count)
            var blockCommentOpen = false
            file.highlights = (0..<limit).compactMap { lineIndex in
                let spans = highlight(
                    line: lines[lineIndex],
                    syntax: syntax,
                    blockCommentOpen: &blockCommentOpen
                )
                return spans.isEmpty ? nil : PagerEditLineHighlight(
                    lineNumber: lineIndex + 1,
                    spans: spans
                )
            }
            producedAny = producedAny || !file.highlights.isEmpty
            highlighted.append(file)
        }
        return producedAny ? highlighted : nil
    }

    private static func readCapped(path: String, workingDirectory: URL) -> String? {
        let url = liveResolveURL(path, relativeTo: workingDirectory.path)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType,
              type == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.intValue <= maximumBytes,
              let data = try? Data(contentsOf: url),
              data.count <= maximumBytes,
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        guard splitLines(text).count <= maximumLines else { return nil }
        return text
    }

    private static func validate(hunks: [DiffHunk], against text: String) -> Bool {
        let lines = splitLines(text)
        for line in hunks.flatMap({ $0 }) where line.tag != .delete {
            guard line.ln > 0, line.ln <= lines.count else { return false }
            let expected = line.text.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
            guard lines[line.ln - 1] == expected else { return false }
        }
        return true
    }

    private static func splitLines(_ text: String) -> [String] {
        (text as NSString).components(separatedBy: "\n").map {
            $0.hasSuffix("\r") ? String($0.dropLast()) : $0
        }
    }

    private enum Syntax {
        case cLike(Set<String>)
        case hash(Set<String>)
        case json

        static func forPath(_ path: String) -> Syntax? {
            switch URL(fileURLWithPath: path).pathExtension.lowercased() {
            case "swift":
                return .cLike(swiftKeywords)
            case "rs":
                return .cLike(rustKeywords)
            case "js", "jsx", "ts", "tsx", "mjs", "cjs":
                return .cLike(javaScriptKeywords)
            case "c", "h", "cc", "cpp", "cxx", "hpp", "java", "kt", "kts", "go":
                return .cLike(cFamilyKeywords)
            case "py", "pyi", "rb", "sh", "bash", "zsh", "fish":
                return .hash(hashKeywords)
            case "json", "jsonc":
                return .json
            default:
                return nil
            }
        }
    }

    private static func highlight(
        line: String,
        syntax: Syntax,
        blockCommentOpen: inout Bool
    ) -> [PagerEditHighlightSpan] {
        let characters = Array(line)
        guard !characters.isEmpty else { return [] }
        let keywords: Set<String>
        let lineComment: String?
        let supportsBlockComments: Bool
        switch syntax {
        case .cLike(let values):
            keywords = values
            lineComment = "//"
            supportsBlockComments = true
        case .hash(let values):
            keywords = values
            lineComment = "#"
            supportsBlockComments = false
        case .json:
            keywords = ["true", "false", "null"]
            lineComment = nil
            supportsBlockComments = false
        }

        func matches(_ token: String, at index: Int) -> Bool {
            let tokenCharacters = Array(token)
            guard index + tokenCharacters.count <= characters.count else { return false }
            return Array(characters[index..<(index + tokenCharacters.count)]) == tokenCharacters
        }

        var spans: [PagerEditHighlightSpan] = []
        var index = 0
        while index < characters.count {
            if blockCommentOpen {
                let start = index
                while index < characters.count, !matches("*/", at: index) { index += 1 }
                if index < characters.count { index += 2; blockCommentOpen = false }
                spans.append(PagerEditHighlightSpan(
                    start: start,
                    length: index - start,
                    kind: .comment
                ))
                continue
            }
            if let lineComment, matches(lineComment, at: index) {
                spans.append(PagerEditHighlightSpan(
                    start: index,
                    length: characters.count - index,
                    kind: .comment
                ))
                break
            }
            if supportsBlockComments, matches("/*", at: index) {
                let start = index
                index += 2
                while index < characters.count, !matches("*/", at: index) { index += 1 }
                if index < characters.count { index += 2 } else { blockCommentOpen = true }
                spans.append(PagerEditHighlightSpan(
                    start: start,
                    length: index - start,
                    kind: .comment
                ))
                continue
            }
            if characters[index] == "\"" || characters[index] == "'" || characters[index] == "`" {
                let quote = characters[index]
                let start = index
                index += 1
                var escaped = false
                while index < characters.count {
                    let character = characters[index]
                    index += 1
                    if escaped { escaped = false; continue }
                    if character == "\\" { escaped = true; continue }
                    if character == quote { break }
                }
                spans.append(PagerEditHighlightSpan(
                    start: start,
                    length: index - start,
                    kind: .string
                ))
                continue
            }
            if characters[index].isNumber {
                let start = index
                index += 1
                while index < characters.count,
                      characters[index].isNumber || characters[index] == "." || characters[index] == "_" {
                    index += 1
                }
                spans.append(PagerEditHighlightSpan(
                    start: start,
                    length: index - start,
                    kind: .number
                ))
                continue
            }
            if characters[index].isLetter || characters[index] == "_" {
                let start = index
                index += 1
                while index < characters.count,
                      characters[index].isLetter || characters[index].isNumber || characters[index] == "_" {
                    index += 1
                }
                let token = String(characters[start..<index])
                if keywords.contains(token) {
                    spans.append(PagerEditHighlightSpan(
                        start: start,
                        length: index - start,
                        kind: .keyword
                    ))
                } else if token.first?.isUppercase == true {
                    spans.append(PagerEditHighlightSpan(
                        start: start,
                        length: index - start,
                        kind: .type
                    ))
                }
                continue
            }
            index += 1
        }
        return spans
    }

    private static let swiftKeywords: Set<String> = [
        "actor", "as", "async", "await", "break", "case", "catch", "class",
        "continue", "default", "defer", "do", "else", "enum", "extension",
        "false", "for", "func", "guard", "if", "import", "in", "init", "is",
        "let", "nil", "protocol", "repeat", "return", "self", "static", "struct",
        "super", "switch", "throw", "throws", "true", "try", "typealias", "var", "where", "while"
    ]
    private static let rustKeywords: Set<String> = [
        "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else",
        "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop",
        "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static",
        "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while"
    ]
    private static let javaScriptKeywords: Set<String> = [
        "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger",
        "default", "delete", "do", "else", "export", "extends", "false", "finally", "for",
        "from", "function", "if", "import", "in", "instanceof", "let", "new", "null", "of",
        "return", "static", "super", "switch", "this", "throw", "true", "try", "typeof", "var", "while", "yield"
    ]
    private static let cFamilyKeywords: Set<String> = [
        "break", "case", "class", "const", "continue", "default", "defer", "do", "else",
        "enum", "false", "final", "for", "func", "if", "import", "interface", "package",
        "private", "protected", "public", "return", "static", "struct", "switch", "true",
        "type", "typedef", "var", "void", "while"
    ]
    private static let hashKeywords: Set<String> = [
        "and", "as", "async", "await", "break", "case", "class", "def", "do", "done",
        "elif", "else", "elsif", "end", "ensure", "except", "export", "false", "fi", "for",
        "from", "function", "if", "import", "in", "lambda", "local", "module", "nil", "none",
        "not", "or", "raise", "return", "then", "true", "try", "unless", "until", "when", "while", "yield"
    ]
}
