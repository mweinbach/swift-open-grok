// SearchReplaceTool.swift
//
// Exact string replace / create (Grok Build + shared OpenCode path).
// Stale context detection: no match → error with re-read guidance.
// Atomic write + path lock; hunk attribution only after success.

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

            if input.oldString.isEmpty {
                // Create / overwrite path.
                let exists = SessionFS.fileExists(absolute)
                if exists && emptyOldDoesNotOverride {
                    throw SessionFSError.invalidInput(
                        "Error: file already exists; empty old_string does not override existing content."
                    )
                }
                previous = exists ? (try? SessionFS.readText(at: absolute)) : nil
                newContent = input.newString
                replacements = 1
            } else {
                guard SessionFS.fileExists(absolute) else {
                    throw SessionFSError.notFound(absolute)
                }
                let text = try SessionFS.readText(at: absolute)
                previous = text
                let count = text.components(separatedBy: input.oldString).count - 1
                if count == 0 {
                    // Stale context: model must re-read.
                    throw SessionFSError.staleContext(
                        """
                        Error: old_string not found in \(input.filePath). The file may have changed \
                        (stale context). Re-read the file with read_file and retry with exact content.
                        """
                    )
                }
                if count > 1 && !input.replaceAll {
                    throw SessionFSError.ambiguousMatch(
                        """
                        Error: old_string appears \(count) times in \(input.filePath). \
                        Provide more surrounding context to make it unique, or set replace_all.
                        """
                    )
                }
                if input.replaceAll {
                    newContent = text.replacingOccurrences(of: input.oldString, with: input.newString)
                    replacements = count
                } else {
                    if let range = text.range(of: input.oldString) {
                        newContent = text.replacingCharacters(in: range, with: input.newString)
                        replacements = 1
                    } else {
                        throw SessionFSError.noMatch("old_string not found")
                    }
                }
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
            let value: JSONValue = .object([
                "type": .string("edits_applied"),
                "path": .string(absolute),
                "replacements": .number(.int64(Int64(replacements))),
                "content": .string(snippet),
                "created": .bool(input.oldString.isEmpty && previous == nil),
            ])
            return .success(
                TypedToolOutput(
                    toolId: FileToolIDs.searchReplace,
                    value: value,
                    modelOutput: [.text(text: "The file \(absolute) has been updated (\(replacements) replacement(s)).\n\(snippet)")]
                )
            )
        } catch let e as SessionFSError {
            return .failure(.invalidArguments(e.description))
        } catch {
            return .failure(.execution(toolId: FileToolIDs.searchReplace, detail: "\(error)"))
        }
    }

    private static func renderSnippet(old: String, new: String, file: String) -> String {
        // Show a small window around the first changed region.
        guard let range = file.range(of: new) else {
            return String(file.prefix(500))
        }
        let start = file.distance(from: file.startIndex, to: range.lowerBound)
        let lines = file.split(separator: "\n", omittingEmptySubsequences: false)
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
}
