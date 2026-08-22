// SearchReplaceTool.swift
//
// Exact string replace / create (Grok Build + shared OpenCode path).
// Stale context detection: no match → error with re-read guidance.
// Atomic write + path lock; hunk attribution only after success.
//
// Structured payload for B2 painter: path, old/new content, edit details with
// regions/context/line numbers/line_prefix, insert/delete counts (line_diff),
// trusted/untrusted provenance, and creating-vs-editing classification.
// Provider-wire shape is additive: legacy keys (type/path/replacements/content/created)
// are retained so existing consumers (code_mode_result, promptText) keep working.
//
// Rust refs (pin 650c1db7):
// - types/output.rs:297 SearchReplaceEditsApplied / SearchReplaceEditDetail
// - implementations/grok_build/search_replace/helpers.rs build_edit_details / render_snippet
// - diff.rs build_diff_hunks

import Foundation
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRegistry
import OpenGrokToolRuntime

public enum SearchReplaceTool {
    public struct Input: Sendable {
        public var filePath: String
        public var oldString: String
        public var newString: String
        public var replaceAll: Bool

        public static func parse(_ args: JSONValue, camelCase: Bool = false) throws -> Input {
            guard case .object(let obj) = args else {
                throw SessionFSError.invalidInput("expected object")
            }
            let path: String?
            let old: String?
            let new: String?
            let replaceAll: Bool
            if camelCase {
                path = string(obj, "filePath") ?? string(obj, "file_path")
                old = string(obj, "oldString") ?? string(obj, "old_string")
                new = string(obj, "newString") ?? string(obj, "new_string")
                replaceAll = bool(obj, "replaceAll") ?? bool(obj, "replace_all") ?? false
            } else {
                path = string(obj, "file_path") ?? string(obj, "filePath")
                old = string(obj, "old_string") ?? string(obj, "oldString")
                new = string(obj, "new_string") ?? string(obj, "newString")
                replaceAll = bool(obj, "replace_all") ?? bool(obj, "replaceAll") ?? false
            }
            guard let path, let old, let new else {
                throw SessionFSError.invalidInput("file_path, old_string, and new_string are required")
            }
            return Input(filePath: path, oldString: old, newString: new, replaceAll: replaceAll)
        }

        public init(filePath: String, oldString: String, newString: String, replaceAll: Bool) {
            self.filePath = filePath
            self.oldString = oldString
            self.newString = newString
            self.replaceAll = replaceAll
        }
    }

    public static func run(
        args: JSONValue,
        resources: ToolResources,
        camelCase: Bool = false,
        emptyOldDoesNotOverride: Bool = false
    ) async -> Result<TypedToolOutput, ToolError> {
        do {
            let input = try Input.parse(args, camelCase: camelCase)
            if input.oldString == input.newString {
                throw SessionFSError.invalidInput("Old string and new string are the same")
            }
            let absolute = SessionFS.resolve(cwd: resources.cwd, path: input.filePath)
            try SessionFS.enforceRoots(absolute, roots: resources.allowedRoots)
            if SessionFS.isDirectory(absolute) {
                throw SessionFSError.isDirectory(absolute)
            }

            let previous: String?
            let newContent: String
            let replacements: Int
            var newPositions: [Int] = []
            var isNewFile = false

            if input.oldString.isEmpty {
                // Create / overwrite path (Rust: handle_new_file_creation in
                // search_replace/mod.rs:295). Rust treats an empty file as not-really-existing
                // for the notification's is_new_file; we mirror that for the structured payload.
                let fileExists = SessionFS.fileExists(absolute)
                if fileExists && emptyOldDoesNotOverride {
                    throw SessionFSError.invalidInput(
                        "Error: file already exists; empty old_string does not override existing content."
                    )
                }
                if fileExists {
                    let prev = try SessionFS.readText(at: absolute)
                    previous = prev
                    // If the file existed and was non-empty, this is an overwrite, not a creation.
                    // The wire's `created` and the painter's `Creating ` prefix must be false there.
                    isNewFile = prev.isEmpty
                } else {
                    previous = nil
                    isNewFile = true
                }
                newContent = input.newString
                replacements = 1
                newPositions = [0]
            } else {
                guard SessionFS.fileExists(absolute) else {
                    throw SessionFSError.notFound(absolute)
                }
                let text = try SessionFS.readText(at: absolute)
                previous = text
                let hasCRLF = text.contains("\r\n")
                let matchText = hasCRLF
                    ? text.replacingOccurrences(of: "\r\n", with: "\n")
                    : text

                var positions: [Int] = []
                var searchOffset = 0
                let oldLen = input.oldString.count
                while searchOffset <= matchText.count {
                    let startIdx = matchText.index(
                        matchText.startIndex,
                        offsetBy: searchOffset,
                        limitedBy: matchText.endIndex
                    ) ?? matchText.endIndex
                    if startIdx >= matchText.endIndex { break }
                    guard let range = matchText.range(
                        of: input.oldString,
                        options: [],
                        range: startIdx..<matchText.endIndex
                    ) else { break }
                    let pos = matchText.distance(from: matchText.startIndex, to: range.lowerBound)
                    positions.append(pos)
                    let nextOffset = pos + oldLen
                    if nextOffset >= matchText.count { break }
                    searchOffset = nextOffset
                    if oldLen == 0 { break }
                }

                if positions.isEmpty {
                    throw SessionFSError.staleContext(
                        """
                        Error: old_string not found in \(input.filePath). The file may have changed \
                        (stale context). Re-read the file with read_file and retry with exact content.
                        """
                    )
                }
                if positions.count > 1 && !input.replaceAll {
                    throw SessionFSError.ambiguousMatch(
                        """
                        Error: old_string appears \(positions.count) times in \(input.filePath). \
                        Provide more surrounding context to make it unique, or set replace_all.
                        """
                    )
                }
                let (computed, nPos) = SearchReplaceTool.replaceUsingPositions(
                    text: matchText,
                    matchPositions: positions,
                    oldString: input.oldString,
                    newString: input.newString
                )
                newContent = hasCRLF
                    ? computed.replacingOccurrences(of: "\r\n", with: "\n")
                        .replacingOccurrences(of: "\n", with: "\r\n")
                    : computed
                newPositions = nPos
                replacements = positions.count
                isNewFile = false
            }

            try await SessionFS.writeText(
                absolute: absolute,
                content: newContent,
                resources: resources,
                previousContent: previous
            )

            let snippet = renderSnippet(
                old: input.oldString.isEmpty ? "" : input.oldString,
                new: input.newString,
                file: newContent
            )

            var detailObjects: [JSONValue] = []
            var totalAdded: Int64 = 0
            var totalRemoved: Int64 = 0

            if input.oldString.isEmpty {
                let oldStr = ""
                let newStr = input.newString
                let (a, r) = SearchReplaceTool.lineDiff(old: oldStr, new: newStr)
                totalAdded += Int64(a)
                totalRemoved += Int64(r)
                detailObjects.append(.object([
                    "old_string": .string(oldStr),
                    "old_line": .number(.int64(1)),
                    "new_string": .string(newStr),
                    "new_line": .number(.int64(1)),
                    "context_before": .string(""),
                    "context_after": .string(""),
                    "line_prefix": .string(""),
                ]))
            } else {
                for pos in newPositions {
                    let ctx = SearchReplaceTool.contextForEdit(
                        newContent: newContent,
                        startPos: pos,
                        inserted: input.newString
                    )
                    let oldStr = input.oldString
                    let newStr = input.newString
                    let (a, r) = SearchReplaceTool.lineDiff(old: oldStr, new: newStr)
                    totalAdded += Int64(a)
                    totalRemoved += Int64(r)
                    detailObjects.append(.object([
                        "old_string": .string(oldStr),
                        "old_line": .number(.int64(Int64(ctx.oldLine))),
                        "new_string": .string(newStr),
                        "new_line": .number(.int64(Int64(ctx.newLine))),
                        "context_before": .string(ctx.before),
                        "context_after": .string(ctx.after),
                        "line_prefix": .string(ctx.prefix),
                    ]))
                }
            }

            let trusted = detailObjects.count == 1
            let createdFlag = input.oldString.isEmpty && isNewFile

            let editsValue: JSONValue = .object(["details": .array(detailObjects)])
            let value: JSONValue = .object([
                "type": .string("edits_applied"),
                "path": .string(absolute),
                "absolute_path": .string(absolute),
                "replacements": .number(.int64(Int64(replacements))),
                "content": .string(snippet),
                "created": .bool(createdFlag),
                "is_new_file": .bool(isNewFile),
                "old_string": .string(input.oldString),
                "new_string": .string(input.newString),
                "edits": editsValue,
                "lines_added": .number(.int64(totalAdded)),
                "lines_removed": .number(.int64(totalRemoved)),
                "trusted": .bool(trusted),
                "unicode_normalized": .bool(false),
            ])
            let modelText = "The file \(absolute) has been updated (\(replacements) replacement(s)).\n\(snippet)"
            return .success(
                TypedToolOutput(
                    toolId: FileToolIDs.searchReplace,
                    value: value,
                    modelOutput: [.text(text: modelText)]
                )
            )
        } catch let e as SessionFSError {
            return .failure(.invalidArguments(e.description))
        } catch {
            return .failure(.execution(toolId: FileToolIDs.searchReplace, detail: "\(error)"))
        }
    }

    private static func renderSnippet(old: String, new: String, file: String) -> String {
        guard let range = file.range(of: new) else {
            return String(file.prefix(500))
        }
        let start = file.distance(from: file.startIndex, to: range.lowerBound)
        let lines = SessionFS.logicalLines(file, preservingTrailingEmpty: true)
        var charCount = 0
        var lineIdx = 0
        for (i, line) in lines.enumerated() {
            charCount += line.count + 1
            if charCount > start {
                lineIdx = i
                break
            }
        }
        let from = max(0, lineIdx - 2)
        let to = min(lines.count, lineIdx + 3)
        var out: [String] = []
        for i in from..<to {
            out.append("\(i + 1)→\(lines[i])")
        }
        _ = old
        return out.joined(separator: "\n")
    }

    // MARK: - Structured helpers (Rust: helpers.rs / diff.rs / types/output.rs:line_diff)

    struct EditContext {
        var before: String
        var after: String
        var prefix: String
        var oldLine: Int
        var newLine: Int
    }

    static func splitInclusive(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines: [String] = []
        var cur = ""
        for ch in text {
            cur.append(ch)
            if ch.isNewline {
                lines.append(cur)
                cur = ""
            }
        }
        if !cur.isEmpty { lines.append(cur) }
        return lines
    }

    static func computeLineRange(text: String, startPos: Int, inserted: String) -> (startLine: Int, endLine: Int) {
        let prefix = String(text.prefix(startPos))
        let startLine = prefix.filter(\.isNewline).count
        let insertedLines = splitInclusive(inserted)
        let n = insertedLines.isEmpty ? 1 : insertedLines.count
        let endLine = startLine + n - 1
        return (startLine, endLine)
    }

    static func contextForEdit(newContent: String, startPos: Int, inserted: String, contextSize: Int = 3) -> EditContext {
        let lines = splitInclusive(newContent)
        let total = lines.count
        let (startLine, endLine) = computeLineRange(text: newContent, startPos: startPos, inserted: inserted)

        let snippetStart = max(0, startLine - contextSize)
        let snippetEnd: Int
        if total == 0 {
            snippetEnd = -1
        } else {
            snippetEnd = min(total - 1, endLine + contextSize)
        }

        let before: String
        if snippetStart < startLine, total > 0 {
            let s = snippetStart
            let e = min(startLine, total)
            if s < e {
                before = lines[s..<e].joined()
            } else { before = "" }
        } else { before = "" }

        let after: String
        if endLine < snippetEnd, total > 0 {
            let s = endLine + 1
            let e = snippetEnd + 1
            if s < e && s < total {
                after = lines[s..<min(e, total)].joined()
            } else { after = "" }
        } else { after = "" }

        let prefix: String
        if startPos == 0 {
            prefix = ""
        } else {
            let upToPos = String(newContent.prefix(startPos))
            if let lastNL = upToPos.lastIndex(where: \.isNewline) {
                let afterNL = newContent.index(after: lastNL)
                let startIdx = newContent.index(newContent.startIndex, offsetBy: startPos, limitedBy: newContent.endIndex) ?? newContent.endIndex
                if afterNL < startIdx {
                    prefix = String(newContent[afterNL..<startIdx])
                } else { prefix = "" }
            } else {
                let startIdx = newContent.index(newContent.startIndex, offsetBy: startPos, limitedBy: newContent.endIndex) ?? newContent.endIndex
                prefix = String(newContent[newContent.startIndex..<startIdx])
            }
        }

        let line = startLine + 1
        return EditContext(before: before, after: after, prefix: prefix, oldLine: line, newLine: line)
    }

    static func replaceUsingPositions(text: String, matchPositions: [Int], oldString: String, newString: String) -> (String, [Int]) {
        var result = ""
        var newPositions: [Int] = []
        var lastEnd = 0
        let oldLen = oldString.count
        for pos in matchPositions {
            let startIdx = text.index(text.startIndex, offsetBy: lastEnd, limitedBy: text.endIndex) ?? text.endIndex
            let posIdx = text.index(text.startIndex, offsetBy: pos, limitedBy: text.endIndex) ?? text.endIndex
            if startIdx < posIdx {
                result.append(contentsOf: text[startIdx..<posIdx])
            }
            newPositions.append(result.count)
            result.append(contentsOf: newString)
            lastEnd = pos + oldLen
        }
        let lastIdx = text.index(text.startIndex, offsetBy: lastEnd, limitedBy: text.endIndex) ?? text.endIndex
        if lastIdx < text.endIndex {
            result.append(contentsOf: text[lastIdx..<text.endIndex])
        }
        return (result, newPositions)
    }

    enum DiffOp {
        case equal(String)
        case delete(String)
        case insert(String)
    }

    static func computeDiffOps(_ oldText: String, _ newText: String) -> [DiffOp] {
        let oldLines = splitInclusive(oldText)
        let newLines = splitInclusive(newText)
        let m = oldLines.count
        let n = newLines.count
        if m == 0 { return newLines.map { .insert($0) } }
        if n == 0 { return oldLines.map { .delete($0) } }
        var dp = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)
        for i in 1...m {
            for j in 1...n {
                if oldLines[i - 1] == newLines[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }
        var ops: [DiffOp] = []
        var i = m, j = n
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && oldLines[i - 1] == newLines[j - 1] {
                ops.append(.equal(oldLines[i - 1])); i -= 1; j -= 1
            } else if j > 0 && (i == 0 || dp[i][j - 1] >= dp[i - 1][j]) {
                ops.append(.insert(newLines[j - 1])); j -= 1
            } else if i > 0 {
                ops.append(.delete(oldLines[i - 1])); i -= 1
            } else { break }
        }
        ops.reverse()
        return ops
    }

    static func lineDiff(old: String, new: String) -> (Int, Int) {
        let ops = computeDiffOps(old, new)
        var added = 0, removed = 0
        for op in ops {
            switch op {
            case .insert: added += 1
            case .delete: removed += 1
            case .equal: break
            }
        }
        return (added, removed)
    }
}
