// GrepTool.swift
//
// Content search via NSRegularExpression (rg-compatible flags subset).
// Prefer pure-Swift for hermetic tests; optionally shells out to `rg` when present.

import Foundation
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRegistry
import OpenGrokToolRuntime
import OpenGrokWorkspace

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

            let files = try collectFiles(root: root, glob: glob, allowedRoots: resources.allowedRoots)
            var matches: [(path: String, lineNumber: Int, text: String)] = []
            var matchingFiles: [(path: String, count: Int)] = []
            var matchCount = 0
            var truncated = false

            for file in files {
                if outputMode == .content, matchCount >= headLimit {
                    truncated = true
                    break
                }
                do {
                    try SessionFS.enforceRoots(file, roots: resources.allowedRoots)
                } catch {
                    continue
                }
                guard let text = try? SessionFS.readText(at: file) else { continue }
                let lines = SessionFS.logicalLines(text)
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

    private static func collectFiles(root: String, glob: String?, allowedRoots: [String]) throws -> [String] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir) else {
            throw SessionFSError.notFound(root)
        }
        if !isDir.boolValue {
            return [root]
        }
        var results: [String] = []
        var ignoreRulesByDirectory: [String: [GitIgnoreRule]] = [:]
        let enumerator = FileManager.default.enumerator(atPath: root)
        while let rel = enumerator?.nextObject() as? String {
            if rel.hasPrefix(".") || rel.contains("/.") {
                enumerator?.skipDescendants()
                continue
            }
            let full = (root as NSString).appendingPathComponent(rel)
            var childDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: full, isDirectory: &childDir) else {
                continue
            }
            do {
                try SessionFS.enforceRoots(full, roots: allowedRoots)
            } catch {
                if childDir.boolValue {
                    enumerator?.skipDescendants()
                }
                continue
            }
            let parent = (full as NSString).deletingLastPathComponent
            let activeIgnoreRules = ignoreRules(
                for: parent,
                searchRoot: root,
                allowedRoots: allowedRoots,
                cache: &ignoreRulesByDirectory
            )
            if GitIgnoreRule.isIgnored(path: rel, isDir: childDir.boolValue, rules: activeIgnoreRules) {
                if childDir.boolValue {
                    enumerator?.skipDescendants()
                }
                continue
            }
            if childDir.boolValue {
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

    private static func ignoreRules(
        for directory: String,
        searchRoot: String,
        allowedRoots: [String],
        cache: inout [String: [GitIgnoreRule]]
    ) -> [GitIgnoreRule] {
        if let cached = cache[directory] {
            return cached
        }

        let relativeDirectory: String
        var rules: [GitIgnoreRule]
        if directory == searchRoot {
            relativeDirectory = ""
            rules = []
        } else {
            let parent = (directory as NSString).deletingLastPathComponent
            rules = ignoreRules(
                for: parent,
                searchRoot: searchRoot,
                allowedRoots: allowedRoots,
                cache: &cache
            )
            relativeDirectory = String(directory.dropFirst(searchRoot.count + 1)) + "/"
        }

        for filename in [".gitignore", ".ignore", ".rgignore"] {
            let path = (directory as NSString).appendingPathComponent(filename)
            guard SessionFS.fileExists(path) else { continue }
            do {
                try SessionFS.enforceRoots(path, roots: allowedRoots)
                let content = try SessionFS.readText(at: path)
                let normalized = SessionFS.logicalLines(content, preservingTrailingEmpty: true)
                    .joined(separator: "\n")
                rules.append(contentsOf: GitIgnoreRule.parse(content: normalized, scope: relativeDirectory))
            } catch {
                continue
            }
        }

        cache[directory] = rules
        return rules
    }

    static func globMatch(_ pattern: String, _ name: String) -> Bool {
        for expanded in expandedBracePatterns(pattern) {
            var expression = "^"
            var index = expanded.startIndex

            while index < expanded.endIndex {
                let character = expanded[index]
                if character == "*" {
                    let next = expanded.index(after: index)
                    if next < expanded.endIndex, expanded[next] == "*" {
                        let afterPair = expanded.index(after: next)
                        if afterPair < expanded.endIndex, expanded[afterPair] == "/" {
                            expression += "(?:.*/)?"
                            index = expanded.index(after: afterPair)
                        } else {
                            expression += ".*"
                            index = afterPair
                        }
                    } else {
                        expression += "[^/]*"
                        index = next
                    }
                } else if character == "?" {
                    expression += "[^/]"
                    index = expanded.index(after: index)
                } else {
                    expression += NSRegularExpression.escapedPattern(for: String(character))
                    index = expanded.index(after: index)
                }
            }

            expression += "$"
            guard let regex = try? NSRegularExpression(pattern: expression) else { continue }
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            if regex.firstMatch(in: name, options: [], range: range) != nil {
                return true
            }
        }
        return false
    }

    private static func expandedBracePatterns(_ pattern: String) -> [String] {
        guard let opening = pattern.firstIndex(of: "{"),
              let closing = pattern[pattern.index(after: opening)...].firstIndex(of: "}")
        else {
            return [pattern]
        }

        let alternatives = pattern[pattern.index(after: opening)..<closing]
            .split(separator: ",", omittingEmptySubsequences: false)
        guard alternatives.count > 1 else { return [pattern] }

        let prefix = String(pattern[..<opening])
        let suffix = String(pattern[pattern.index(after: closing)...])
        return alternatives.flatMap { alternative in
            expandedBracePatterns(prefix + String(alternative) + suffix)
        }
    }
}
