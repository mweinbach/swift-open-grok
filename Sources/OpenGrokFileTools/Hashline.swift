// Hashline.swift
//
// Content-only hashline anchors (Candidate A) + edit apply.
// Ported from grok_build_hashline scheme/edit core.

import Foundation
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRegistry
import OpenGrokToolRuntime

public enum Hashline {
    public static let defaultHashLen = 3

    /// Whitespace-normalized local line hash (base-26 lowercase).
    public static func lineHash(_ line: String, length: Int = defaultHashLen) -> String {
        let normalized = line
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
        var hash: UInt64 = 5381
        for b in normalized.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(b)
        }
        var out = ""
        var h = hash
        for _ in 0..<length {
            let idx = Int(h % 26)
            out.append(Character(UnicodeScalar(97 + idx)!))
            h /= 26
        }
        return out
    }

    public static func anchor(for line: String, line lineNo: Int, length: Int = defaultHashLen) -> String {
        "L\(lineNo)\(lineHash(line, length: length))"
    }

    public static func parseAnchor(_ raw: String) -> (line: Int, hash: String)? {
        // Forms: L12abc  or  12abc  or full "L12|abc"
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("L") || s.first?.isNumber == true else { return nil }
        let body = s.hasPrefix("L") ? String(s.dropFirst()) : s
        var digits = ""
        var hash = ""
        var inHash = false
        for ch in body {
            if !inHash, ch.isNumber {
                digits.append(ch)
            } else {
                inHash = true
                if ch.isLetter { hash.append(ch) }
            }
        }
        guard let line = Int(digits), !hash.isEmpty else { return nil }
        return (line, hash)
    }

    public enum Op: Sendable, Equatable {
        case replace(anchor: String, content: String)
        case insertAfter(anchor: String, content: String)
        case delete(anchor: String)
    }

    public static func parseOps(_ value: JSONValue) throws -> [Op] {
        guard case .array(let arr) = value else {
            throw SessionFSError.invalidInput("edits must be an array")
        }
        var ops: [Op] = []
        for item in arr {
            guard case .object(let obj) = item else { continue }
            let type = string(obj, "op") ?? string(obj, "type") ?? "replace"
            let anchor = string(obj, "anchor") ?? string(obj, "start") ?? ""
            let content = string(obj, "content") ?? string(obj, "new_content") ?? ""
            switch type {
            case "replace":
                ops.append(.replace(anchor: anchor, content: content))
            case "insert_after", "insertAfter":
                ops.append(.insertAfter(anchor: anchor, content: content))
            case "delete":
                ops.append(.delete(anchor: anchor))
            default:
                throw SessionFSError.invalidInput("unknown hashline op: \(type)")
            }
        }
        return ops
    }

    public static func validateAnchor(
        _ anchor: String,
        lines: [String]
    ) throws -> Int {
        guard let parsed = parseAnchor(anchor) else {
            throw SessionFSError.invalidInput("invalid anchor: \(anchor)")
        }
        let idx = parsed.line - 1
        guard idx >= 0, idx < lines.count else {
            throw SessionFSError.staleContext(
                "anchor \(anchor) line \(parsed.line) out of range (file has \(lines.count) lines)"
            )
        }
        let expected = lineHash(lines[idx])
        if expected != parsed.hash {
            // Try shifted search within ±5 lines.
            var candidates: [Int] = []
            for d in -5...5 where d != 0 {
                let j = idx + d
                guard j >= 0, j < lines.count else { continue }
                if lineHash(lines[j]) == parsed.hash {
                    candidates.append(j)
                }
            }
            if candidates.count == 1 {
                return candidates[0]
            }
            throw SessionFSError.staleContext(
                "anchor \(anchor) is stale (expected hash \(expected) at line \(parsed.line)). Re-read the file."
            )
        }
        return idx
    }

    public static func runEdit(
        args: JSONValue,
        resources: ToolResources
    ) async -> Result<TypedToolOutput, ToolError> {
        do {
            guard case .object(let obj) = args else {
                throw SessionFSError.invalidInput("expected object")
            }
            let path = string(obj, "file_path") ?? string(obj, "path")
            guard let path else { throw SessionFSError.invalidInput("missing file_path") }
            let absolute = SessionFS.resolve(cwd: resources.cwd, path: path)
            try SessionFS.enforceRoots(absolute, roots: resources.allowedRoots)
            let text = try SessionFS.readText(at: absolute)
            var lines = SessionFS.logicalLines(text)
            let lineEnding = SessionFS.lineEnding(in: text)
            let previous = text
            let ops = try parseOps(obj["edits"] ?? .array([]))
            // Apply from bottom to top so line numbers stay stable.
            let resolved: [(Int, Op)] = try ops.map { op in
                switch op {
                case .replace(let a, _), .insertAfter(let a, _), .delete(let a):
                    return (try validateAnchor(a, lines: lines), op)
                }
            }.sorted { $0.0 > $1.0 }

            for (idx, op) in resolved {
                switch op {
                case .replace(_, let content):
                    let newLines = SessionFS.logicalLines(content, preservingTrailingEmpty: true)
                    lines.replaceSubrange(idx..<(idx + 1), with: newLines)
                case .insertAfter(_, let content):
                    let newLines = SessionFS.logicalLines(content, preservingTrailingEmpty: true)
                    lines.insert(contentsOf: newLines, at: idx + 1)
                case .delete:
                    lines.remove(at: idx)
                }
            }

            let newContent = lines.joined(separator: lineEnding)
                + (SessionFS.hasTrailingNewline(text) ? lineEnding : "")
            try await SessionFS.writeText(
                absolute: absolute,
                content: newContent,
                resources: resources,
                previousContent: previous
            )

            let snippetStart = max(0, (resolved.last?.0 ?? 0) - 2)
            let snippetEnd = min(lines.count, snippetStart + 8)
            var snippet: [String] = []
            for i in snippetStart..<snippetEnd {
                snippet.append("\(i + 1)|\(anchor(for: lines[i], line: i + 1))→\(lines[i])")
            }
            let content = "Applied \(ops.count) hashline edit(s) to \(absolute)\n" + snippet.joined(separator: "\n")
            let value: JSONValue = .object([
                "type": .string("hashline_edits_applied"),
                "path": .string(absolute),
                "applied": .number(.int64(Int64(ops.count))),
                "content": .string(content),
                "scheme": .string("content_only_v1"),
            ])
            return .success(
                TypedToolOutput(toolId: FileToolIDs.hashlineEdit, value: value, modelOutput: [.text(text: content)])
            )
        } catch let e as SessionFSError {
            return .failure(.invalidArguments(e.description))
        } catch {
            return .failure(.execution(toolId: FileToolIDs.hashlineEdit, detail: "\(error)"))
        }
    }
}
