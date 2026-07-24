// GlobTool.swift
//
// OpenCode-compatible file glob / search.

import Foundation
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRegistry
import OpenGrokToolRuntime

public enum GlobTool {
    public static let resultLimit = 100

    public static func run(
        args: JSONValue,
        resources: ToolResources
    ) async -> Result<TypedToolOutput, ToolError> {
        do {
            guard case .object(let obj) = args else {
                throw SessionFSError.invalidInput("expected object")
            }
            guard let pattern = string(obj, "pattern"), !pattern.isEmpty else {
                throw SessionFSError.invalidInput("missing pattern")
            }
            let root = SessionFS.resolve(cwd: resources.cwd, path: string(obj, "path") ?? ".")
            try SessionFS.enforceRoots(root, roots: resources.allowedRoots)

            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
                throw SessionFSError.notDirectory(root)
            }

            var matches: [String] = []
            let enumerator = FileManager.default.enumerator(atPath: root)
            while let rel = enumerator?.nextObject() as? String {
                if rel.hasPrefix(".") || rel.contains("/.") { continue }
                let base = (rel as NSString).lastPathComponent
                if GrepTool.globMatch(pattern, rel) || GrepTool.globMatch(pattern, base) {
                    matches.append((root as NSString).appendingPathComponent(rel))
                }
            }
            matches.sort()
            let truncated = matches.count > resultLimit
            let shown = Array(matches.prefix(resultLimit))
            var content = shown.joined(separator: "\n")
            if content.isEmpty {
                content = "No files found"
            } else if truncated {
                content += "\n\n(Results are truncated: showing first \(resultLimit) results out of more. Use a more specific pattern.)"
            }

            let value: JSONValue = .object([
                "type": .string("glob"),
                "pattern": .string(pattern),
                "content": .string(content),
                "match_count": .number(.int64(Int64(matches.count))),
                "truncated": .bool(truncated),
            ])
            return .success(
                TypedToolOutput(toolId: FileToolIDs.glob, value: value, modelOutput: [.text(text: content)])
            )
        } catch let e as SessionFSError {
            return .failure(.invalidArguments(e.description))
        } catch {
            return .failure(.execution(toolId: FileToolIDs.glob, detail: "\(error)"))
        }
    }
}
