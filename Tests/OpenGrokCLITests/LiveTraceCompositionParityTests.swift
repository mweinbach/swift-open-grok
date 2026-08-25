import Foundation
import OpenGrokFileUtils
import OpenGrokSessionPersistence
import OpenGrokShared
import Testing

@testable import OpenGrokCLI

private struct LiveTraceFixture {
    let root: URL
    let home: URL
    let workspace: URL

    var environment: [String: String] {
        [
            "HOME": root.appendingPathComponent("user").path,
            "OPENGROK_HOME": home.path,
            "PWD": workspace.path,
        ]
    }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-live-trace-\(UUID().uuidString)",
            isDirectory: true
        )
        home = root.appendingPathComponent("state", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        for directory in [root, home, workspace, root.appendingPathComponent("user")] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    @discardableResult
    func seed(_ sessionID: String, prompt: String = "private conversation") async throws -> URL {
        var record = LiveConversationRecord.new(sessionID: sessionID, workingDirectory: workspace)
        record.items = [.user(prompt)]
        try await LiveConversationStore(openGrokHome: home).save(record)
        return try SessionDocumentStore(grokHome: home).sessionDirectory(
            sessionID: sessionID,
            cwd: workspace.path
        )
    }

    func run(
        _ arguments: [String],
        environment overrides: [String: String] = [:]
    ) async -> (status: Int32, output: String, errors: String) {
        let (streams, stdout, stderr) = CLIStreams.buffered()
        let status = await CLIRunner.run(
            arguments,
            environment: environment.merging(overrides) { _, override in override },
            streams: streams,
            application: .live(control: .never)
        )
        return (status, stdout.contents, stderr.contents)
    }

    func clean() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func liveTraceArchiveEntries(at path: URL) throws -> [TarEntry] {
    let gzip = Array(try Data(contentsOf: path))
    guard gzip.count >= 23,
          gzip[0] == 0x1F,
          gzip[1] == 0x8B,
          gzip[2] == 0x08,
          gzip[3] == 0
    else {
        throw CLIApplicationError.failed("trace fixture did not produce a valid gzip header")
    }

    var cursor = 10
    var tar = Data()
    while true {
        guard cursor + 5 <= gzip.count - 8 else {
            throw CLIApplicationError.failed("trace gzip contains a truncated DEFLATE block")
        }
        let header = gzip[cursor]
        guard header & 0x06 == 0 else {
            throw CLIApplicationError.failed("trace gzip is not using portable stored blocks")
        }
        let length = UInt16(gzip[cursor + 1]) | (UInt16(gzip[cursor + 2]) << 8)
        let inverse = UInt16(gzip[cursor + 3]) | (UInt16(gzip[cursor + 4]) << 8)
        guard inverse == ~length else {
            throw CLIApplicationError.failed("trace gzip has an invalid DEFLATE block length")
        }
        cursor += 5
        guard cursor + Int(length) <= gzip.count - 8 else {
            throw CLIApplicationError.failed("trace gzip contains a truncated block payload")
        }
        tar.append(contentsOf: gzip[cursor..<(cursor + Int(length))])
        cursor += Int(length)
        if header & 1 == 1 { break }
    }
    guard cursor + 8 == gzip.count else {
        throw CLIApplicationError.failed("trace gzip has an invalid trailer")
    }
    let expectedChecksum = UInt32(gzip[cursor])
        | UInt32(gzip[cursor + 1]) << 8
        | UInt32(gzip[cursor + 2]) << 16
        | UInt32(gzip[cursor + 3]) << 24
    guard expectedChecksum == CRC32.checksum(tar) else {
        throw CLIApplicationError.failed("trace gzip checksum does not match its tar payload")
    }
    return try BundleArchiveExtractor.parseTar(tar)
}

private func liveTraceJSON(_ text: String) throws -> [String: Any] {
    let data = try #require(text.data(using: .utf8))
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Suite("live Rust-compatible local session trace bundles", .serialized)
struct LiveTraceCompositionParityTests {
    @Test("the executable exports canonical private session documents and upstream JSON metadata")
    func realExecutableExportsSessionBundle() async throws {
        let fixture = try LiveTraceFixture()
        defer { fixture.clean() }
        try await fixture.seed("trace-live", prompt: "do not lose the durable transcript")

        let result = await fixture.run(["trace", "trace-live", "--local", "--json"])

        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        #expect(result.errors.isEmpty)
        let output = try liveTraceJSON(result.output)
        #expect(output["session_id"] as? String == "trace-live")
        #expect(output["status"] as? String == "exported")
        #expect(output["url"] == nil)
        #expect(output["error"] == nil)
        let archivePath = try #require(output["local_path"] as? String)
        let archiveURL = URL(fileURLWithPath: archivePath)
        #expect(archiveURL == fixture.home
            .appendingPathComponent("trace-exports")
            .appendingPathComponent("trace-live.tar.gz"))
        #expect(try SecureFile.isOwnerOnly(at: archiveURL))

        let entries = try liveTraceArchiveEntries(at: archiveURL)
        let paths = Set(entries.map(\.path))
        #expect(paths.contains("trace-live/summary.json"))
        #expect(paths.contains("trace-live/chat_history.jsonl"))
        #expect(paths.contains("trace-live/updates.jsonl"))
        #expect(paths.contains("trace-live/state.json"))
        #expect(paths.contains("trace-live/trace_config.json"))
        #expect(paths.contains("trace-live/export_metadata.json"))
        let configEntry = try #require(entries.first {
            $0.path == "trace-live/trace_config.json"
        })
        let config = try liveTraceJSON(String(decoding: configEntry.data, as: UTF8.self))
        #expect(config.keys.contains("telemetry_trace_upload"))
        #expect(config["telemetry_trace_upload"] is NSNull)
        let metadataEntry = try #require(entries.first {
            $0.path == "trace-live/export_metadata.json"
        })
        let metadata = try liveTraceJSON(String(decoding: metadataEntry.data, as: UTF8.self))
        #expect(metadata["session_id"] as? String == "trace-live")
        #expect(metadata["grok_version"] as? String == OpenGrokCLIVersion.installedWithCommit(
            environment: fixture.environment
        ))
        #expect(metadata["memtrace_files"] as? Int == 0)
        #expect(metadata["exported_at"] as? String != nil)
    }

    @Test("disabled upload falls back to local export with upstream human diagnostics")
    func disabledUploadFallsBackToLocalArchive() async throws {
        let fixture = try LiveTraceFixture()
        defer { fixture.clean() }
        try await fixture.seed("fallback")

        let result = await fixture.run(["trace", "fallback"])

        let expected = fixture.home.appendingPathComponent("trace-exports/fallback.tar.gz")
        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        #expect(result.output == expected.path + "\n")
        #expect(result.errors.contains("Trace uploads disabled."))
        #expect(result.errors.contains("Falling back to local export."))
        #expect(result.errors.contains("Session trace exported"))
        #expect(FileManager.default.fileExists(atPath: expected.path))
    }

    @Test("relative custom output resolves against the actual supplied working directory")
    func customRelativeOutputUsesSessionWorkingDirectory() async throws {
        let fixture = try LiveTraceFixture()
        defer { fixture.clean() }
        try await fixture.seed("custom")

        let result = await fixture.run([
            "trace", "custom", "--local", "-o", "nested/custom.tar.gz",
        ])

        let expected = fixture.workspace.appendingPathComponent("nested/custom.tar.gz")
        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        #expect(result.output == expected.path + "\n")
        #expect(!result.errors.contains("Falling back"))
        #expect(try SecureFile.isOwnerOnly(at: expected))
    }

    @Test("enabled remote upload fails closed while an explicit local export remains available")
    func enabledUploadRequiresExplicitLocalOptOut() async throws {
        let fixture = try LiveTraceFixture()
        defer { fixture.clean() }
        try await fixture.seed("protected")
        try "[telemetry]\ntrace_upload = true\n".write(
            to: fixture.home.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )

        let denied = await fixture.run(["trace", "protected", "--json"])
        #expect(denied.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(denied.output.isEmpty)
        #expect(denied.errors.contains("rerun with --local"))
        #expect(!FileManager.default.fileExists(atPath: fixture.home
            .appendingPathComponent("trace-exports/protected.tar.gz").path))

        let allowed = await fixture.run(["trace", "protected", "--local", "--json"])
        #expect(allowed.status == CLIRunner.ExitCode.success.rawValue)
        let output = try liveTraceJSON(allowed.output)
        let path = try #require(output["local_path"] as? String)
        let config = try #require(liveTraceArchiveEntries(at: URL(fileURLWithPath: path)).first {
            $0.path == "protected/trace_config.json"
        })
        let snapshot = try liveTraceJSON(String(decoding: config.data, as: UTF8.self))
        #expect(snapshot["trace_upload_enabled"] as? Bool == true)
        #expect(snapshot["telemetry_trace_upload"] as? Bool == true)
    }

    @Test("environment upload policy overrides local config and never leaks configured secrets")
    func environmentPolicyAndConfigurationRedaction() async throws {
        let fixture = try LiveTraceFixture()
        defer { fixture.clean() }
        try await fixture.seed("redacted")
        try """
        [telemetry]
        trace_upload = true

        [endpoints]
        deployment_key = "DEPLOYMENT_PRIVATE_SECRET"
        trace_upload_bucket = "PRIVATE_BUCKET_NAME"
        trace_upload_credentials = "INLINE_CREDENTIAL_SECRET"
        trace_upload_url = "https://secret-endpoint.example/PRIVATE"
        """.write(
            to: fixture.home.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )

        let result = await fixture.run(
            ["trace", "redacted", "--local", "--json"],
            environment: ["GROK_TELEMETRY_TRACE_UPLOAD": "false"]
        )

        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        let path = try #require(liveTraceJSON(result.output)["local_path"] as? String)
        let entries = try liveTraceArchiveEntries(at: URL(fileURLWithPath: path))
        let config = try #require(entries.first { $0.path == "redacted/trace_config.json" })
        let text = String(decoding: config.data, as: UTF8.self)
        let snapshot = try liveTraceJSON(text)
        #expect(snapshot["trace_upload_enabled"] as? Bool == false)
        #expect(snapshot["telemetry_trace_upload"] as? Bool == true)
        #expect(snapshot["has_deployment_key"] as? Bool == true)
        #expect(snapshot["has_bucket_configured"] as? Bool == true)
        #expect(snapshot["has_inline_credentials"] as? Bool == true)
        #expect(snapshot["custom_upload_url"] as? Bool == true)
        #expect(!text.contains("DEPLOYMENT_PRIVATE_SECRET"))
        #expect(!text.contains("PRIVATE_BUCKET_NAME"))
        #expect(!text.contains("INLINE_CREDENTIAL_SECRET"))
        #expect(!text.contains("secret-endpoint.example"))
    }

    @Test("memory traces use upstream process ordering and ignore unrelated files")
    func memoryTracesAreGroupedAndFiltered() async throws {
        let fixture = try LiveTraceFixture()
        defer { fixture.clean() }
        try await fixture.seed("memory")
        let directory = fixture.home.appendingPathComponent("memtrace", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, age) in [
            ("100-1.jsonl", 60.0),
            ("100-1-jemalloc-2.txt", 300.0),
            ("100-1-jemalloc-10.txt", 120.0),
            ("100-2.jsonl", 5.0),
            ("100-2-jemalloc-0.txt", 30.0),
            ("credentials.txt", 0.0),
            ("not-a-process.jsonl", 0.0),
        ] {
            let url = directory.appendingPathComponent(name)
            try Data(name.utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-age)],
                ofItemAtPath: url.path
            )
        }

        let result = await fixture.run(["trace", "memory", "--local", "--json"])
        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        let path = try #require(liveTraceJSON(result.output)["local_path"] as? String)
        let entries = try liveTraceArchiveEntries(at: URL(fileURLWithPath: path))
        let traces = entries.map(\.path).filter { $0.hasPrefix("memory/memtrace/") }
        #expect(traces == [
            "memory/memtrace/100-2.jsonl",
            "memory/memtrace/100-2-jemalloc-0.txt",
            "memory/memtrace/100-1.jsonl",
            "memory/memtrace/100-1-jemalloc-10.txt",
            "memory/memtrace/100-1-jemalloc-2.txt",
        ])
        let metadata = try #require(entries.first { $0.path == "memory/export_metadata.json" })
        let metadataJSON = try liveTraceJSON(String(decoding: metadata.data, as: UTF8.self))
        #expect(metadataJSON["memtrace_files"] as? Int == 5)
    }

    @Test("GNU long paths and multi-block stored DEFLATE preserve private session sidecars")
    func longPathsAndLargeFilesRoundTrip() async throws {
        let fixture = try LiveTraceFixture()
        defer { fixture.clean() }
        let session = try await fixture.seed("large")
        let component = String(repeating: "nested-", count: 18) + "🧵"
        let nested = session.appendingPathComponent(component, isDirectory: true)
        try FileManager.default.createDirectory(
            at: nested,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let sidecar = nested.appendingPathComponent("oversized-sidecar.json")
        let payload = Data(repeating: 0x41, count: 140_000)
        try SecureFile.write(at: sidecar, contents: payload)

        let result = await fixture.run(["trace", "large", "--local", "--json"])

        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        let path = try #require(liveTraceJSON(result.output)["local_path"] as? String)
        let entries = try liveTraceArchiveEntries(at: URL(fileURLWithPath: path))
        let entry = try #require(entries.first {
            $0.path == "large/\(component)/oversized-sidecar.json"
        })
        #expect(entry.data == payload)
    }

    @Test("unknown, missing, or traversal-shaped session identities never create an archive")
    func invalidSessionIdentitiesFailWithoutOutput() async throws {
        let fixture = try LiveTraceFixture()
        defer { fixture.clean() }

        for identifier in ["missing", "../../credentials", ".."] {
            let result = await fixture.run(["trace", identifier, "--local", "--json"])
            #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
            #expect(result.output.isEmpty)
            #expect(!FileManager.default.fileExists(
                atPath: fixture.home.appendingPathComponent("trace-exports").path
            ))
        }
    }

    #if !os(Windows)
    @Test("session symlinks and public source files are refused before private data is archived")
    func unsafeSessionFilesFailClosed() async throws {
        let fixture = try LiveTraceFixture()
        defer { fixture.clean() }
        let session = try await fixture.seed("unsafe")
        let external = fixture.root.appendingPathComponent("external-secret.txt")
        try Data("EXTERNAL_SECRET".utf8).write(to: external)
        let symlink = session.appendingPathComponent("redirect.json")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: external)

        let linked = await fixture.run(["trace", "unsafe", "--local", "--json"])
        #expect(linked.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(linked.errors.contains("symbolic link"))
        #expect(linked.output.isEmpty)
        try FileManager.default.removeItem(at: symlink)

        let exposed = session.appendingPathComponent("public.json")
        try Data("PUBLIC_PRIVATE_DATA".utf8).write(to: exposed)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: exposed.path)
        let publicFile = await fixture.run(["trace", "unsafe", "--local", "--json"])
        #expect(publicFile.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(publicFile.errors.contains("unsafe or oversized private file"))
        #expect(publicFile.output.isEmpty)
    }

    @Test("symbolic-link destinations cannot overwrite files outside the trace export")
    func outputSymlinkIsNeverFollowed() async throws {
        let fixture = try LiveTraceFixture()
        defer { fixture.clean() }
        try await fixture.seed("destination")
        let protected = fixture.root.appendingPathComponent("do-not-replace.txt")
        try Data("leave untouched".utf8).write(to: protected)
        let link = fixture.root.appendingPathComponent("redirect.tar.gz")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: protected)

        let result = await fixture.run([
            "trace", "destination", "--local", "-o", link.path,
        ])

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(result.errors.contains("refusing a symbolic-link destination"))
        #expect(result.output.isEmpty)
        #expect(try String(contentsOf: protected, encoding: .utf8) == "leave untouched")
        #expect(try PathSecurity.isSymlink(link))
    }

    @Test("dangling symbolic-link destinations are rejected before archive replacement")
    func danglingOutputSymlinkIsNeverReplaced() async throws {
        let fixture = try LiveTraceFixture()
        defer { fixture.clean() }
        try await fixture.seed("dangling-destination")
        let missing = fixture.root.appendingPathComponent("missing-target.tar.gz")
        let link = fixture.root.appendingPathComponent("dangling.tar.gz")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: missing)

        let result = await fixture.run([
            "trace", "dangling-destination", "--local", "-o", link.path,
        ])

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(result.errors.contains("refusing a symbolic-link destination"))
        #expect(result.output.isEmpty)
        #expect(try PathSecurity.isSymlink(link))
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }
    #endif
}
