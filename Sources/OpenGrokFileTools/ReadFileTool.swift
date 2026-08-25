// ReadFileTool.swift
//
// Grok Build / Codex / OpenCode / Hashline read implementations.

import Foundation
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRegistry
import OpenGrokToolRuntime
import OpenGrokToolTypes

public enum ReadFileTool {
    public static let maxLines = maxLinesRead

    public struct Input: Sendable {
        public var path: String
        public var offset: Int?
        public var limit: Int?
        public var pages: String?
        public var format: String?

        public init(
            path: String,
            offset: Int? = nil,
            limit: Int? = nil,
            pages: String? = nil,
            format: String? = nil
        ) {
            self.path = path
            self.offset = offset
            self.limit = limit
            self.pages = pages
            self.format = format
        }

        public static func parse(_ args: JSONValue) throws -> Input {
            guard case .object(let obj) = args else {
                throw SessionFSError.invalidInput("expected object args")
            }
            let path =
                string(obj, "target_file")
                ?? string(obj, "path")
                ?? string(obj, "file_path")
                ?? string(obj, "filePath")
            guard let path, !path.isEmpty else {
                throw SessionFSError.invalidInput("missing target_file")
            }
            let offset = int(obj, "offset")
            let limit = int(obj, "limit")
            let pages = string(obj, "pages")
            let format = string(obj, "format")
            if obj["pages"] != nil && pages == nil {
                throw SessionFSError.invalidInput("pages must be a string")
            }
            if obj["format"] != nil && format == nil {
                throw SessionFSError.invalidInput("format must be a string")
            }
            return Input(path: path, offset: offset, limit: limit, pages: pages, format: format)
        }
    }

    public static func run(
        args: JSONValue,
        resources: ToolResources,
        withHashlineAnchors: Bool = false,
        concise: Bool = false,
        context: ToolCallContext? = nil
    ) async -> Result<TypedToolOutput, ToolError> {
        do {
            let input = try Input.parse(args)
            let absolute = SessionFS.resolve(cwd: resources.cwd, path: input.path)
            try SessionFS.enforceRoots(absolute, roots: resources.allowedRoots)
            try GitIgnoreAccessPolicy.enforce(path: absolute, resources: resources, operation: "read")

            let document = try DocumentExtraction.identify(path: absolute)
            if document == nil,
               let mime = SessionFS.imageMIME(for: absolute), SessionFS.fileExists(absolute) {
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
                        toolId: FileToolIDs.readFile,
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
            }

            let text: String
            if let document {
                let deadline = DocumentExtractionDeadline()
                switch document {
                case .pdf:
                    let bytes = try DocumentExtraction.readBounded(path: absolute, label: "PDF")
                    switch try PDFDocumentExtractor.extract(
                        bytes,
                        pages: input.pages,
                        format: input.format,
                        deadline: deadline
                    ) {
                    case .text(let extracted, _):
                        text = extracted
                    case .images(let pages, let totalPages):
                        let blocks: [ContentBlock] = pages.map { page in
                            .image(
                                mimeType: "image/jpeg",
                                data: page.bytes.base64EncodedString(),
                                mediaId: nil,
                                filename: "page-\(page.pageNumber).jpg",
                                path: absolute,
                                metadata: ["page_number": String(page.pageNumber)]
                            )
                        }
                        let value: JSONValue = .object([
                            "type": .string("pdf_page_images"),
                            "path": .string(absolute),
                            "total_pages": .number(.int64(Int64(totalPages))),
                            "file_size": .number(.int64(Int64(bytes.count))),
                            "pages": .array(pages.map { page in
                                .object([
                                    "page_number": .number(.int64(Int64(page.pageNumber))),
                                    "mime_type": .string("image/jpeg"),
                                    "data": .string(page.bytes.base64EncodedString()),
                                ])
                            }),
                        ])
                        return .success(TypedToolOutput(
                            toolId: FileToolIDs.readFile,
                            value: value,
                            modelOutput: blocks
                        ))
                    }
                case .pptx:
                    let bytes = try DocumentExtraction.readBounded(path: absolute, label: "PPTX")
                    text = try PowerPointDocumentExtractor.extract(bytes, deadline: deadline)
                }
            } else {
                text = try SessionFS.readText(at: absolute)
            }
            let lines = SessionFS.logicalLines(text)

            let start: Int
            if let offset = input.offset {
                start = max(1, offset)
            } else {
                start = 1
            }
            let limit = input.limit ?? maxLines
            let startIdx = start - 1
            let endIdx = min(lines.count, startIdx + max(0, limit))
            let slice: ArraySlice<String>
            if startIdx >= lines.count {
                slice = []
            } else {
                slice = lines[startIdx..<endIdx]
            }

            var bodyLines: [String] = []
            for (i, line) in slice.enumerated() {
                let lineNo = startIdx + i + 1
                if withHashlineAnchors {
                    let anchor = Hashline.anchor(for: line, line: lineNo)
                    bodyLines.append("\(lineNo)|\(anchor)→\(line)")
                } else {
                    bodyLines.append("\(lineNo)→\(line)")
                }
            }
            var content = bodyLines.joined(separator: "\n")
            var truncated = false
            if endIdx < lines.count || (input.limit == nil && lines.count > maxLines) {
                truncated = endIdx < lines.count
            }
            if content.utf8.count > defaultToolOutputBytes {
                let capped = capToolOutput(content, maxBytes: defaultToolOutputBytes)
                content = capped.modelText
                truncated = true
            }

            if concise && content.count > 4_000 {
                content = truncateMiddle(content, maxChars: 4_000)
                truncated = true
            }

            guard await streamFileToolContent(
                content,
                subkind: "read_file_chunk",
                context: context
            ) else {
                return .failure(.cancelled(
                    toolId: FileToolIDs.readFile,
                    detail: "read_file was cancelled while streaming progress"
                ))
            }

            let value: JSONValue = .object([
                "type": .string("file_content"),
                "path": .string(absolute),
                "content": .string(content),
                "total_lines": .number(.int64(Int64(lines.count))),
                "start_line": .number(.int64(Int64(start))),
                "end_line": .number(.int64(Int64(min(endIdx, lines.count)))),
                "truncated": .bool(truncated),
            ])
            return .success(
                TypedToolOutput(
                    toolId: FileToolIDs.readFile,
                    value: value,
                    modelOutput: [.text(text: content)]
                )
            )
        } catch let error as DocumentExtractionError {
            if case .cancelled = error {
                return .failure(.cancelled(
                    toolId: FileToolIDs.readFile,
                    detail: "read_file was cancelled while processing a document"
                ))
            }
            return .failure(.invalidArguments(error.localizedDescription))
        } catch let e as SessionFSError {
            return .failure(.invalidArguments(e.description))
        } catch {
            return .failure(.execution(toolId: FileToolIDs.readFile, detail: error.localizedDescription))
        }
    }
}

func string(_ obj: [String: JSONValue], _ key: String) -> String? {
    if case .string(let s) = obj[key] { return s }
    return nil
}

func int(_ obj: [String: JSONValue], _ key: String) -> Int? {
    if case .number(let n) = obj[key] { return n.int64Value.map(Int.init) }
    if case .string(let s) = obj[key] { return Int(s) }
    return nil
}

func bool(_ obj: [String: JSONValue], _ key: String) -> Bool? {
    if case .bool(let b) = obj[key] { return b }
    if case .string(let s) = obj[key] {
        switch s.lowercased() {
        case "true", "1", "yes": return true
        case "false", "0", "no": return false
        default: return nil
        }
    }
    return nil
}
