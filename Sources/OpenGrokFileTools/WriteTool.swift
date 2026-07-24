// WriteTool.swift
//
// OpenCode full-file write.

import Foundation
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRegistry
import OpenGrokToolRuntime

public enum WriteTool {
    public static func run(
        args: JSONValue,
        resources: ToolResources
    ) async -> Result<TypedToolOutput, ToolError> {
        do {
            guard case .object(let obj) = args else {
                throw SessionFSError.invalidInput("expected object")
            }
            let path = string(obj, "file_path") ?? string(obj, "filePath") ?? string(obj, "path")
            let content = string(obj, "content")
            guard let path, let content else {
                throw SessionFSError.invalidInput("file_path and content are required")
            }
            let absolute = SessionFS.resolve(cwd: resources.cwd, path: path)
            try SessionFS.enforceRoots(absolute, roots: resources.allowedRoots)
            if SessionFS.isDirectory(absolute) {
                throw SessionFSError.isDirectory(absolute)
            }
            let previous = SessionFS.fileExists(absolute) ? try? SessionFS.readText(at: absolute) : nil
            try await SessionFS.writeText(
                absolute: absolute,
                content: content,
                resources: resources,
                previousContent: previous
            )
            let value: JSONValue = .object([
                "type": .string("edits_applied"),
                "path": .string(absolute),
                "content": .string("Wrote \(content.utf8.count) bytes to \(absolute)"),
                "created": .bool(previous == nil),
            ])
            return .success(
                TypedToolOutput(
                    toolId: FileToolIDs.write,
                    value: value,
                    modelOutput: [.text(text: "Wrote \(absolute)")]
                )
            )
        } catch let e as SessionFSError {
            return .failure(.invalidArguments(e.description))
        } catch {
            return .failure(.execution(toolId: FileToolIDs.write, detail: "\(error)"))
        }
    }
}
