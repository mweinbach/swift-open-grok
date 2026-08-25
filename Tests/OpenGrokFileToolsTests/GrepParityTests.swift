import Foundation
import Testing
@testable import OpenGrokFileTools
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRegistry
import OpenGrokToolRuntime

@Suite("Grep multiline, context, file type, and bounded traversal parity")
struct GrepParityTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-grep-parity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func resources(at directory: URL) -> ToolResources {
        FileToolSession.makeResources(
            workspaceRoot: directory.path,
            sessionId: "grep-parity",
            policy: .allowAll
        )
    }

    private func write(_ content: String, to path: String, in directory: URL) throws {
        let file = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(content.utf8).write(to: file)
    }

    private func search(
        _ arguments: [String: JSONValue],
        in directory: URL
    ) async throws -> [String: JSONValue] {
        let toolset = try FileToolPack.finalizeBuildPack(resources: resources(at: directory))
        let output = try await toolset.prepareAndCall(
            clientName: "grep",
            args: .object(arguments)
        ).get()
        guard case .object(let value) = output.value else {
            throw ToolError.invalidArguments("grep returned an unexpected output shape")
        }
        return value
    }

    private func matches(_ value: [String: JSONValue]) throws -> [[String: JSONValue]] {
        guard case .array(let records)? = value["matches"] else {
            throw ToolError.invalidArguments("grep did not return structured matches")
        }
        return try records.map { record in
            guard case .object(let fields) = record else {
                throw ToolError.invalidArguments("grep returned a non-object match")
            }
            return fields
        }
    }

    private func lineNumbers(_ value: [String: JSONValue]) throws -> [Int] {
        try matches(value).map { record in
            guard case .number(let number)? = record["line_number"],
                  let lineNumber = number.int64Value else {
                throw ToolError.invalidArguments("grep match did not contain its line number")
            }
            return Int(lineNumber)
        }
    }

    private func content(_ value: [String: JSONValue]) throws -> String {
        guard case .string(let text)? = value["content"] else {
            throw ToolError.invalidArguments("grep did not return visible content")
        }
        return text
    }

    @Test("multiline mode matches across LF lines and returns every touched logical line")
    func multilineMatchesEntireLFSpan() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("prefix\nalpha\nbridge\nomega\nsuffix\n", to: "sample.txt", in: directory)

        let ordinary = try await search([
            "pattern": .string("alpha.*omega"),
            "path": .string("sample.txt"),
        ], in: directory)
        #expect(ordinary["match_count"] == .number(.int64(0)))

        let multiline = try await search([
            "pattern": .string("alpha.*omega"),
            "path": .string("sample.txt"),
            "multiline": .bool(true),
        ], in: directory)
        #expect(multiline["match_count"] == .number(.int64(3)))
        #expect(try lineNumbers(multiline) == [2, 3, 4])
        let visible = try content(multiline)
        #expect(visible.contains(":2:alpha"))
        #expect(visible.contains(":3:bridge"))
        #expect(visible.contains(":4:omega"))
        #expect(!visible.contains("suffix"))
    }

    @Test("multiline searches normalize CRLF and preserve UTF-16-aware line numbers")
    func multilineMatchesCRLFAndUnicode() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(
            "header🙂\r\nalpha🙂\r\nβ bridge\r\nomega🙂\r\ntail\r\n",
            to: "windows.txt",
            in: directory
        )

        let multiline = try await search([
            "pattern": .string("alpha🙂\nβ bridge\nomega"),
            "path": .string("windows.txt"),
            "multiline": .bool(true),
        ], in: directory)

        #expect(multiline["match_count"] == .number(.int64(3)))
        #expect(try lineNumbers(multiline) == [2, 3, 4])
        #expect(!(try content(multiline)).contains("\r"))
        #expect(try matches(multiline).allSatisfy { record in
            guard case .string(let line)? = record["text"] else { return false }
            return !line.contains("\r")
        })
    }

    @Test("independent multiline matches return distinct records without duplication")
    func multipleMultilineSpansStayDistinct() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("alpha\nbeta\ngap\nalpha\nbeta\n", to: "repeated.txt", in: directory)

        let output = try await search([
            "pattern": .string("alpha\nbeta"),
            "multiline": .bool(true),
        ], in: directory)

        #expect(output["match_count"] == .number(.int64(4)))
        #expect(try lineNumbers(output) == [1, 2, 4, 5])
    }

    @Test("symmetric context merges overlapping groups and separates disjoint groups")
    func symmetricContextMergesOverlappingGroups() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(
            "zero\nbefore\nneedle first\nbetween\nneedle second\nafter\ngap\nlast before\nneedle last\ntail\n",
            to: "contexts.txt",
            in: directory
        )

        let output = try await search([
            "pattern": .string("needle"),
            "-C": .number(.int64(1)),
        ], in: directory)

        let visible = try content(output)
        #expect(output["match_count"] == .number(.int64(3)))
        #expect(try lineNumbers(output) == [3, 5, 9])
        #expect(visible.contains(":2-before"))
        #expect(visible.contains(":3:needle first"))
        #expect(visible.contains(":4-between"))
        #expect(visible.contains(":5:needle second"))
        #expect(visible.contains(":6-after"))
        #expect(visible.contains("\n--\n"))
        #expect(visible.contains(":8-last before"))
        #expect(visible.contains(":9:needle last"))
        #expect(visible.contains(":10-tail"))
        #expect(visible.components(separatedBy: ":4-between").count == 2)
        #expect(!visible.contains(":1-zero"))
        #expect(!visible.contains(":7-gap"))
    }

    @Test("directional context overrides symmetric context, including explicit zero")
    func directionalContextOverridesSymmetricContext() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("before two\nbefore one\nneedle\nafter one\nafter two\n", to: "window.txt", in: directory)

        let output = try await search([
            "pattern": .string("needle"),
            "-C": .number(.int64(2)),
            "-B": .number(.int64(0)),
            "-A": .number(.int64(1)),
        ], in: directory)

        let visible = try content(output)
        #expect(try lineNumbers(output) == [3])
        #expect(visible.contains(":3:needle"))
        #expect(visible.contains(":4-after one"))
        #expect(!visible.contains("before one"))
        #expect(!visible.contains("after two"))
        #expect(output["after_context"] == .number(.int64(1)))
    }

    @Test("context rows consume the requested visible-line budget")
    func contextRowsRespectHeadLimit() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("before\nneedle\nafter\n", to: "bounded.txt", in: directory)

        let output = try await search([
            "pattern": .string("needle"),
            "-C": .number(.int64(1)),
            "head_limit": .number(.int64(2)),
        ], in: directory)

        let visible = try content(output)
        #expect(visible.contains(":1-before"))
        #expect(visible.contains(":2:needle"))
        #expect(!visible.contains(":3-after"))
        #expect(output["truncated"] == .bool(true))
        #expect(output["match_count"] == .number(.int64(1)))
    }

    @Test("file types intersect glob filters and retain case-insensitive matching")
    func fileTypesIntersectGlobFilters() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("Needle\n", to: "app.ts", in: directory)
        try write("NEEDLE\n", to: "nested/view.tsx", in: directory)
        try write("needle\n", to: "nested/excluded.rs", in: directory)
        try write("needle\n", to: "excluded.js", in: directory)

        let output = try await search([
            "pattern": .string("needle"),
            "type": .string("ts"),
            "glob": .string("**/*.{ts,tsx}"),
            "-i": .bool(true),
        ], in: directory)

        let visible = try content(output)
        #expect(output["match_count"] == .number(.int64(2)))
        #expect(output["file_type"] == .string("ts"))
        #expect(output["case_insensitive"] == .bool(true))
        #expect(visible.contains("app.ts"))
        #expect(visible.contains("view.tsx"))
        #expect(!visible.contains("excluded.rs"))
        #expect(!visible.contains("excluded.js"))

        let excludedRoot = try await search([
            "pattern": .string("needle"),
            "path": .string("nested/excluded.rs"),
            "type": .string("py"),
        ], in: directory)
        #expect(excludedRoot["match_count"] == .number(.int64(0)))
    }

    @Test("unknown file types are rejected instead of widening the search")
    func unknownFileTypesFailClosed() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("needle\n", to: "known.txt", in: directory)

        let result = await GrepTool.run(
            args: .object([
                "pattern": .string("needle"),
                "type": .string("not-a-ripgrep-type"),
            ]),
            resources: resources(at: directory)
        )

        guard case .failure(let error) = result else {
            Issue.record("unknown grep file types must fail instead of searching every file")
            return
        }
        #expect(error.kind == .invalidArguments)
        #expect(error.detail.contains("unrecognized file type"))
    }

    @Test("content and file modes use their distinct upstream defaults and hard caps")
    func headLimitsUseModeSpecificDefaultsAndCaps() throws {
        #expect(try GrepTool.effectiveHeadLimit(nil) == 200)
        #expect(try GrepTool.effectiveHeadLimit(nil, outputMode: "files_with_matches") == 500)
        #expect(try GrepTool.effectiveHeadLimit(nil, outputMode: "count") == 500)
        #expect(try GrepTool.effectiveHeadLimit(800) == 800)
        #expect(try GrepTool.effectiveHeadLimit(2_001) == 2_000)
        #expect(try GrepTool.effectiveHeadLimit(10_001, outputMode: "files_with_matches") == 10_000)
        #expect(try GrepTool.effectiveHeadLimit(10_001, outputMode: "count") == 10_000)
    }

    @Test("file-list and count modes return more than the content-mode default")
    func fileModesUseFiveHundredEntryDefault() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<225 {
            try write("needle\n", to: "\(index).txt", in: directory)
        }

        for mode in ["files_with_matches", "count"] {
            let output = try await search([
                "pattern": .string("needle"),
                "output_mode": .string(mode),
            ], in: directory)

            #expect(try matches(output).count == 225)
            #expect(output["file_count"] == .number(.int64(225)))
            #expect(output["head_limit"] == .number(.int64(500)))
            #expect(output["truncated"] == .bool(false))
        }
    }

    @Test("content limits truncate overflow but do not mark an exact fit as truncated")
    func contentHeadLimitDistinguishesExactFit() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("needle first\nneedle second\n", to: "fit.txt", in: directory)

        let exactFit = try await search([
            "pattern": .string("needle"),
            "head_limit": .number(.int64(2)),
        ], in: directory)
        #expect(exactFit["match_count"] == .number(.int64(2)))
        #expect(exactFit["truncated"] == .bool(false))

        try write("needle third\n", to: "overflow.txt", in: directory)
        let overflowing = try await search([
            "pattern": .string("needle"),
            "head_limit": .number(.int64(2)),
        ], in: directory)
        #expect(overflowing["match_count"] == .number(.int64(2)))
        #expect(overflowing["truncated"] == .bool(true))
        #expect(try content(overflowing).contains("[truncated: showing first 2 matches]"))
    }

    @Test("explicit content requests cannot exceed the two-thousand-line hard cap")
    func contentHardCapClampsLargeRequests() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let contents = (0..<2_001).map { "needle \($0)" }.joined(separator: "\n")
        try write(contents, to: "large.txt", in: directory)

        let output = try await search([
            "pattern": .string("needle"),
            "head_limit": .number(.int64(9_999)),
        ], in: directory)

        #expect(output["head_limit"] == .number(.int64(2_000)))
        #expect(output["match_count"] == .number(.int64(2_000)))
        #expect(try matches(output).count == 2_000)
        #expect(output["truncated"] == .bool(true))
    }

    @Test("negative head or context limits fail without crashing or widening output")
    func negativeLimitsAreRejected() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("needle\n", to: "sample.txt", in: directory)

        for key in ["head_limit", "-A", "-B", "-C"] {
            let result = await GrepTool.run(
                args: .object([
                    "pattern": .string("needle"),
                    key: .number(.int64(-1)),
                ]),
                resources: resources(at: directory)
            )
            guard case .failure(let error) = result else {
                Issue.record("negative \(key) must fail")
                continue
            }
            #expect(error.kind == .invalidArguments)
            #expect(error.detail.contains(key))
        }
    }

    @Test("binary, invalid UTF-8, and oversized files are never searched")
    func unsafeFileContentsAreSkipped() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("needle readable\n", to: "allowed.txt", in: directory)
        try Data([0x6E, 0x65, 0x65, 0x64, 0x6C, 0x65, 0x00]).write(
            to: directory.appendingPathComponent("binary.txt")
        )
        try Data([0x6E, 0x65, 0x65, 0x64, 0x6C, 0x65, 0xFF]).write(
            to: directory.appendingPathComponent("invalid.txt")
        )
        var oversized = Data("needle oversized\n".utf8)
        oversized.append(Data(repeating: 0x61, count: 5 * 1_024 * 1_024))
        try oversized.write(to: directory.appendingPathComponent("oversized.txt"))

        let output = try await search(["pattern": .string("needle")], in: directory)
        let visible = try content(output)

        #expect(output["match_count"] == .number(.int64(1)))
        #expect(visible.contains("allowed.txt"))
        #expect(!visible.contains("binary.txt"))
        #expect(!visible.contains("invalid.txt"))
        #expect(!visible.contains("oversized.txt"))
    }

    @Test("recursive search skips file and directory symlinks and rejects outside roots")
    func symlinksAndExternalRootsNeverLeak() async throws {
        let directory = try temporaryDirectory()
        let outside = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: outside)
        }

        try write("needle authorized\n", to: "inside.txt", in: directory)
        try write("needle SECRET_OUTSIDE\n", to: "secret.txt", in: outside)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("outside-file.txt"),
            withDestinationURL: outside.appendingPathComponent("secret.txt")
        )
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("outside-directory"),
            withDestinationURL: outside
        )
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("inside-alias.txt"),
            withDestinationURL: directory.appendingPathComponent("inside.txt")
        )

        let recursive = try await search(["pattern": .string("needle")], in: directory)
        let visible = try content(recursive)
        #expect(recursive["match_count"] == .number(.int64(1)))
        #expect(visible.contains("inside.txt"))
        #expect(!visible.contains("SECRET_OUTSIDE"))
        #expect(!visible.contains("outside-file"))
        #expect(!visible.contains("outside-directory"))
        #expect(!visible.contains("inside-alias"))

        let directEscape = await GrepTool.run(
            args: .object([
                "pattern": .string("needle"),
                "path": .string(outside.path),
            ]),
            resources: resources(at: directory)
        )
        guard case .failure(let error) = directEscape else {
            Issue.record("grep accepted a root outside its authorized workspace")
            return
        }
        #expect(error.kind == .invalidArguments)
        #expect(error.detail.contains("escapes workspace"))
    }

    @Test("individual matching lines are truncated at the upstream character ceiling")
    func longMatchingLinesAreClipped() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let line = "needle " + String(repeating: "x", count: 1_100)
        try write(line + "\n", to: "long.txt", in: directory)

        let output = try await search(["pattern": .string("needle")], in: directory)
        let record = try #require(matches(output).first)

        guard case .string(let visible)? = record["text"] else {
            Issue.record("structured grep match did not contain its clipped line")
            return
        }
        #expect(visible.hasPrefix("needle "))
        #expect(visible.contains("[... truncated (1107 chars total)]"))
        #expect(visible.count < line.count)
    }
}
