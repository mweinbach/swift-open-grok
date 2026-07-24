// ViewImageTool.swift
//
// Attach an image path for multimodal model inspection.

import Foundation
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRegistry
import OpenGrokToolRuntime

public enum ViewImageTool {
    public static func run(
        args: JSONValue,
        resources: ToolResources
    ) async -> Result<TypedToolOutput, ToolError> {
        do {
            guard case .object(let obj) = args else {
                throw SessionFSError.invalidInput("expected object")
            }
            let path = string(obj, "path") ?? string(obj, "target_file") ?? string(obj, "file_path")
            guard let path else { throw SessionFSError.invalidInput("missing path") }
            let absolute = SessionFS.resolve(cwd: resources.cwd, path: path)
            try SessionFS.enforceRoots(absolute, roots: resources.allowedRoots)
            guard SessionFS.fileExists(absolute) else {
                throw SessionFSError.notFound(absolute)
            }
            let mime = SessionFS.imageMIME(for: absolute) ?? "application/octet-stream"
            let data = try SessionFS.readBytes(at: absolute)
            let b64 = data.base64EncodedString()
            let value: JSONValue = .object([
                "type": .string("image"),
                "path": .string(absolute),
                "mime_type": .string(mime),
                "size_bytes": .number(.int64(Int64(data.count))),
            ])
            return .success(
                TypedToolOutput(
                    toolId: FileToolIDs.viewImage,
                    value: value,
                    modelOutput: [
                        .image(
                            mimeType: mime,
                            data: b64,
                            mediaId: nil,
                            filename: (absolute as NSString).lastPathComponent,
                            path: absolute,
                            metadata: [:]
                        )
                    ]
                )
            )
        } catch let e as SessionFSError {
            return .failure(.invalidArguments(e.description))
        } catch {
            return .failure(.execution(toolId: FileToolIDs.viewImage, detail: "\(error)"))
        }
    }
}
