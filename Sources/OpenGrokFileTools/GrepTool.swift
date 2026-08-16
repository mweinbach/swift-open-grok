// GrepTool.swift
//
// Content search via NSRegularExpression (rg-compatible flags subset).
// Prefer pure-Swift for hermetic tests; optionally shells out to `rg` when present.

import Foundation
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRegistry
import OpenGrokToolRuntime

public enum GrepTool {
    public static let defaultHeadLimit = 200

    private enum OutputMode: String {
        case content
        case filesWithMatches = "files_with_matches"
        case count

        init(_ raw: String?) {
            switch raw?.lowercased().replacingOccurrences(of: "-", with: "_") {
            case "files_with_matches", "fileswithmatches", "files": self = .filesWithMatches
            case "count": self = .count
            default: self = .content
            }
        }
    }

    public static func run(
        args: JSONValue,
        resources: ToolResources,
        withHashline: Bool = false
    ) async -> Result<TypedToolOutput, ToolError> {
        do {
            guard case .object(let obj) = args else {
                throw SessionFSError.invalidInput("expected object")
            }
            guard let pattern = string(obj, "pattern"), !pattern.isEmpty else {
                throw SessionFSError.invalidInput("missing pattern")
            }
            let pathArg = string(obj, "path")
            let glob = string(obj, "glob")
            let caseInsensitive = bool(obj, "-i") ?? bool(obj, "case_insensitive") ?? false
            let headLimit = int(obj, "head_limit") ?? defaultHeadLimit
            let multiline = bool(obj, "multiline") ?? false
            let outputMode = OutputMode(string(obj, "output_mode"))

            let root = SessionFS.resolve(cwd: resources.cwd, path: pathArg ?? ".")
            try SessionFS.enforceRoots(root, roots: resources.allowedRoots)

            var options: NSRegularExpression.Options = []
            if caseInsensitive { options.insert(.caseInsensitive) }
            if multiline { options.insert(.dotMatchesLineSeparators) }
            let regex = try NSRegularExpression(pattern: pattern, options: options)

            let files = try collectFiles(root: root, glob: glob)
            var matches: [(path: String, lineNumber: Int, text: String)] = []
            var matchingFiles: [(path: String, count: Int)] = []
            var matchCount = 0
            var truncated = false

            for file in files {
                if outputMode == .content, matchCount >= headLimit {
                    truncated = true
                    break
                }
                guard let text = try? SessionFS.readText(at: file) else { continue }
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                var fileMatchCount = 0
                for (idx, line) in lines.enumerated() {
                    let range = NSRange(line.startIndex..<line.endIndex, in: line)
                    if regex.firstMatch(in: line, options: [], range: range) != nil {
                        let lineNo = idx + 1
                        matchCount += 1
                        fileMatchCount += 1
                        if outputMode == .content, matches.count < headLimit {
                            matches.append((file, lineNo, line))
                        }
                        if outputMode == .content, matchCount >= headLimit {
                            truncated = true
                            break
                        }
                    }
                }
                if fileMatchCount > 0 {
                    matchingFiles.append((file, fileMatchCount))
                }
            }

            let shownFiles = Array(matchingFiles.prefix(headLimit))
            if outputMode != .content, matchingFiles.count > shownFiles.count {
                truncated = true
            }
            var content: String
            switch outputMode {
            case .content:
                content = matches.map { match in
                    if withHashline {
                        let anchor = Hashline.anchor(for: match.text, line: match.lineNumber)
                        return "\(match.path):\(match.lineNumber)|\(anchor):\(match.text)"
                    }
                    return "\(match.path):\(match.lineNumber):\(match.text)"
                }.joined(separator: "\n")
            case .filesWithMatches:
                content = shownFiles.map(\.path).joined(separator: "\n")
            case .count:
                content = shownFiles.map { "\($0.path):\($0.count)" }.joined(separator: "\n")
            }
            if content.isEmpty {
                content = "No matches found"
            } else if truncated {
                let unit = outputMode == .content ? "matches" : "files"
                content += "\n\n[truncated: showing first \(headLimit) \(unit)]"
            }
            if content.utf8.count > defaultToolOutputBytes {
                let capped = capToolOutput(content)
                content = capped.modelText
            }

            let structuredMatches: [JSONValue]
            switch outputMode {
            case .content:
                structuredMatches = matches.map { match in
                    .object([
                        "path": .string(match.path),
                        "line_number": .number(.int64(Int64(match.lineNumber))),
                        "text": .string(match.text),
                    ])
                }
            case .filesWithMatches:
                structuredMatches = shownFiles.map { .object(["path": .string($0.path)]) }
            case .count:
                structuredMatches = shownFiles.map {
                    .object([
                        "path": .string($0.path),
                        "count": .number(.int64(Int64($0.count))),
                    ])
                }
            }
            var valueFields: [String: JSONValue] = [
                "type": .string("grep"),
                "pattern": .string(pattern),
                "path": .string(root),
                "content": .string(content),
                "match_count": .number(.int64(Int64(matchCount))),
                "file_count": .number(.int64(Int64(matchingFiles.count))),
                "truncated": .bool(truncated),
                "case_insensitive": .bool(caseInsensitive),
                "multiline": .bool(multiline),
                "output_mode": .string(outputMode.rawValue),
                "matches": .array(structuredMatches),
            ]
            if let glob { valueFields["glob"] = .string(glob) }
            let value: JSONValue = .object(valueFields)
            return .success(
                TypedToolOutput(toolId: FileToolIDs.grep, value: value, modelOutput: [.text(text: content)])
            )
        } catch let e as SessionFSError {
            return .failure(.invalidArguments(e.description))
        } catch {
            return .failure(.invalidArguments("invalid regex: \(error)"))
        }
    }

    private static func collectFiles(root: String, glob: String?) throws -> [String] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir) else {
            throw SessionFSError.notFound(root)
        }
        if !isDir.boolValue {
            return [root]
        }
        var results: [String] = []
        let enumerator = FileManager.default.enumerator(atPath: root)
        while let rel = enumerator?.nextObject() as? String {
            if rel.hasPrefix(".") || rel.contains("/.") { continue }
            let full = (root as NSString).appendingPathComponent(rel)
            var childDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: full, isDirectory: &childDir), childDir.boolValue {
                continue
            }
            if let glob, !globMatch(glob, rel) && !globMatch(glob, (rel as NSString).lastPathComponent) {
                continue
            }
            results.append(full)
            if results.count > 10_000 { break }
        }
        return results.sorted()
    }

    /// Minimal glob: `*` and `?` only (sufficient for tests / common filters).
    static func globMatch(_ pattern: String, _ name: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".")
        guard let re = try? NSRegularExpression(pattern: "^\(escaped)$") else { return false }
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        return re.firstMatch(in: name, options: [], range: range) != nil
    }
}
