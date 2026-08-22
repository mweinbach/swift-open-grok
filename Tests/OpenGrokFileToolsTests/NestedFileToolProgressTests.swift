import Foundation
@testable import OpenGrokFileTools
import OpenGrokShared
import OpenGrokToolRegistry
import OpenGrokToolRuntime
import Testing

private actor NestedFileProgressLog {
    private var progress: [ToolProgress] = []

    func append(_ value: ToolProgress) {
        progress.append(value)
    }

    func values() -> [ToolProgress] {
        progress
    }
}

@Suite("Nested file tools emit only authorized visible progress")
struct NestedFileToolProgressTests {
    private func directory() throws -> URL {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-nested-file-progress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }

    private func toolset(at directory: URL) throws -> FinalizedToolset {
        try FileToolPack.finalizeBuildPack(resources: FileToolSession.makeResources(
            workspaceRoot: directory.path,
            sessionId: "nested-progress",
            policy: .allowAll
        ))
    }

    private func payloads(_ progress: [ToolProgress], subkind expected: String) throws -> [PartialResultPayload] {
        try progress.map { item in
            guard case .custom(let subkind, let value) = item, subkind == expected else {
                throw ToolError.invalidArguments("unexpected progress item")
            }
            return try value.decode(PartialResultPayload.self)
        }
    }

    @Test("nested read replays the exact Unicode-formatted body in bounded chunks")
    func nestedReadStreamsFormattedVisibleContent() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = (0..<160).map { "🙂 line \($0) " + String(repeating: "x", count: 42) }
            .joined(separator: "\n")
        try Data(contents.utf8).write(to: root.appendingPathComponent("unicode.txt"))

        let log = NestedFileProgressLog()
        let active = try toolset(at: root)
        let result = await active.callNested(
            clientName: "read_file",
            args: .object(["target_file": .string("unicode.txt")]),
            viewerContext: WorkspaceViewerContext(streamToolProgress: true),
            onProgress: { await log.append($0) }
        )
        guard case .success(let output) = result,
              case .object(let value) = output.value,
              case .string(let visible) = value["content"] else {
            Issue.record("expected successful read with visible content")
            return
        }

        let chunks = try payloads(await log.values(), subkind: "read_file_chunk")
        #expect(chunks.count > 1)
        #expect(chunks.map(\.delta).joined() == visible)
        #expect(chunks.allSatisfy { $0.delta.utf8.count <= 4_096 && !$0.gap && !$0.truncated })
        #expect(chunks.last?.totalBytes == UInt64(visible.utf8.count))
    }

    @Test("grep streams each visible match but not its terminal-only truncation footer")
    func nestedGrepStreamsOnlyMatchBody() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("needle one\nneedle two\nneedle three\n".utf8)
            .write(to: root.appendingPathComponent("matches.txt"))

        let log = NestedFileProgressLog()
        let active = try toolset(at: root)
        let result = await active.callNested(
            clientName: "grep",
            args: .object([
                "pattern": .string("needle"),
                "path": .string("."),
                "head_limit": .number(.int64(2)),
            ]),
            viewerContext: WorkspaceViewerContext(streamToolProgress: true),
            onProgress: { await log.append($0) }
        )
        guard case .success(let output) = result,
              case .object(let value) = output.value,
              case .string(let visible) = value["content"] else {
            Issue.record("expected successful grep with visible matches")
            return
        }

        let chunks = try payloads(await log.values(), subkind: "grep_match_chunk")
        #expect(chunks.count == 2)
        #expect(chunks[0].delta.hasSuffix("needle one"))
        #expect(chunks[1].delta.hasPrefix("\n"))
        #expect(visible.hasPrefix(chunks.map(\.delta).joined()))
        #expect(visible.contains("[truncated:"))
        #expect(!chunks.map(\.delta).joined().contains("[truncated:"))
    }

    @Test("viewer opt-out, images, denied permissions, and empty matches emit nothing")
    func nonStreamingAndDeniedCallsEmitNothing() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("visible line\n".utf8).write(to: root.appendingPathComponent("text.txt"))
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: root.appendingPathComponent("image.png"))

        let log = NestedFileProgressLog()
        let active = try toolset(at: root)
        let optedOut = await active.callNested(
            clientName: "read_file",
            args: .object(["target_file": .string("text.txt")]),
            viewerContext: WorkspaceViewerContext(streamToolProgress: false),
            onProgress: { await log.append($0) }
        )
        guard case .success = optedOut else {
            Issue.record("viewer opt-out must not suppress terminal output")
            return
        }

        let image = await active.callNested(
            clientName: "read_file",
            args: .object(["target_file": .string("image.png")]),
            viewerContext: WorkspaceViewerContext(streamToolProgress: true),
            onProgress: { await log.append($0) }
        )
        guard case .success = image else {
            Issue.record("image reads must remain terminal-only")
            return
        }

        let noMatches = await active.callNested(
            clientName: "grep",
            args: .object(["pattern": .string("never-present"), "path": .string("text.txt")]),
            viewerContext: WorkspaceViewerContext(streamToolProgress: true),
            onProgress: { await log.append($0) }
        )
        guard case .success = noMatches else {
            Issue.record("empty grep must still produce terminal output")
            return
        }

        let ungated = try FileToolPack.finalizeBuildPack(resources: ToolResources(cwd: root.path))
        let denied = await ungated.callNested(
            clientName: "read_file",
            args: .object(["target_file": .string("text.txt")]),
            viewerContext: WorkspaceViewerContext(streamToolProgress: true),
            onProgress: { await log.append($0) }
        )
        guard case .failure(let error) = denied else {
            Issue.record("missing permission pipeline must fail closed")
            return
        }
        #expect(error.kind == .permissionDenied)
        #expect(await log.values().isEmpty)
    }

    @Test("cooperative cancellation stops delivery after the acknowledged chunk")
    func cancellationClosesProgressBeforeTerminal() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(String(repeating: "authorized ", count: 1_500).utf8)
            .write(to: root.appendingPathComponent("long.txt"))

        let log = NestedFileProgressLog()
        let cancellation = Cancellation()
        let active = try toolset(at: root)
        let result = await active.callNested(
            clientName: "read_file",
            args: .object(["target_file": .string("long.txt")]),
            viewerContext: WorkspaceViewerContext(streamToolProgress: true),
            onProgress: { progress in
                await log.append(progress)
                cancellation.cancel()
            },
            cancellation: cancellation
        )

        guard case .failure(let error) = result else {
            Issue.record("cancelled read must not report terminal success")
            return
        }
        #expect(error.kind == .cancelled)
        #expect(await log.values().count == 1)
    }
}
