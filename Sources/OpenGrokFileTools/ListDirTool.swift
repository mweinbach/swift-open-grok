// ListDirTool.swift
//
// Directory listing with char budget and truncation notice.

import Foundation
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRegistry
import OpenGrokToolRuntime

public enum ListDirTool {
    public static let defaultMaxOutputChars = 10_000

    public static func run(
        args: JSONValue,
        resources: ToolResources,
        maxChars: Int = defaultMaxOutputChars
    ) async -> Result<TypedToolOutput, ToolError> {
        do {
            guard case .object(let obj) = args else {
                throw SessionFSError.invalidInput("expected object")
            }
            let target =
                string(obj, "target_directory")
                ?? string(obj, "path")
                ?? "."
            let absolute = SessionFS.resolve(cwd: resources.cwd, path: target)
            try SessionFS.enforceRoots(absolute, roots: resources.allowedRoots)

            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: absolute, isDirectory: &isDir),
                  isDir.boolValue
            else {
                throw SessionFSError.notDirectory(absolute)
            }

            let contents = try FileManager.default.contentsOfDirectory(atPath: absolute)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

            var lines: [String] = ["\(absolute)/"]
            var truncated = false
            var entryCount = 0
            for name in contents {
                // Skip dotfiles like Rust default listing (gitignore may filter more).
                if name.hasPrefix(".") { continue }
                let child = (absolute as NSString).appendingPathComponent(name)
                var childIsDir: ObjCBool = false
                _ = FileManager.default.fileExists(atPath: child, isDirectory: &childIsDir)
                let entry = childIsDir.boolValue ? "  \(name)/" : "  \(name)"
                let candidate = lines.joined(separator: "\n") + "\n" + entry
                if candidate.count > maxChars {
                    truncated = true
                    break
                }
                lines.append(entry)
                entryCount += 1
            }
            if truncated {
                lines.append("    ...")
                lines.append("")
                lines.append(
                    "Note: this directory is too large to list fully. Try list_dir on a narrower path, or use grep / bash."
                )
            }
            let content = lines.joined(separator: "\n")
            let value: JSONValue = .object([
                "type": .string("list_dir"),
                "path": .string(absolute),
                "content": .string(content),
                "truncated": .bool(truncated),
                "entry_count": .number(.int64(Int64(entryCount))),
            ])
            return .success(
                TypedToolOutput(toolId: FileToolIDs.listDir, value: value, modelOutput: [.text(text: content)])
            )
        } catch let e as SessionFSError {
            return .failure(.invalidArguments(e.description))
        } catch {
            return .failure(.execution(toolId: FileToolIDs.listDir, detail: "\(error)"))
        }
    }
}
