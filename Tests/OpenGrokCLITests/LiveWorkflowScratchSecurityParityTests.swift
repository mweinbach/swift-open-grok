import Foundation
import OpenGrokFileUtils
import OpenGrokSamplingTypes
import OpenGrokSessionRuntime
import OpenGrokShared
import OpenGrokShell
import OpenGrokToolRegistry
import OpenGrokWorkflow
import Testing

@testable import OpenGrokCLI

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private struct WorkflowScratchInvoker: LiveWorkflowToolInvoker {
    let workingDirectory: URL
    let tools: [ToolSpec] = []

    func invoke(
        sessionID: String,
        workingDirectory: URL,
        call: ToolCall
    ) async -> Result<OpenGrokShellToolCallResult, OpenGrokShellToolRuntimeError> {
        .success(OpenGrokShellToolCallResult(value: .string("unused"), promptText: "unused"))
    }
}

private actor WorkflowScratchInvokerFactory {
    private(set) var calls = 0
    private var failFirst: Bool
    private let workingDirectory: URL

    init(workingDirectory: URL, failFirst: Bool = false) {
        self.workingDirectory = workingDirectory
        self.failFirst = failFirst
    }

    func make(_ mode: ToolCapabilityMode) async throws -> any LiveWorkflowToolInvoker {
        calls += 1
        let shouldFail = failFirst
        failFirst = false
        try await Task.sleep(nanoseconds: 30_000_000)
        if shouldFail {
            throw RhaiHostError.failed("invoker construction failed")
        }
        return WorkflowScratchInvoker(workingDirectory: workingDirectory)
    }
}

private struct WorkflowScratchFixture: Sendable {
    let root: URL
    let home: URL
    let workspace: URL
    let scratch: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "open-grok-workflow-scratch-\(UUID().uuidString)",
            isDirectory: true
        )
        home = root.appendingPathComponent("home", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        scratch = home.appendingPathComponent("workflow-scratch/run-1", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    func makeHost(
        factory: WorkflowScratchInvokerFactory? = nil
    ) -> LiveWorkflowHost {
        let workspace = workspace
        return LiveWorkflowHost(
            context: RhaiWorkflowRunContext(
                runID: "run-1",
                workflowName: "scratch-security",
                arguments: .object([:]),
                agentBudget: 8,
                journalURL: nil,
                cancellation: RhaiCancellationToken()
            ),
            environment: LiveWorkflowAgentEnvironment(
                sampler: OpenGrokLiveSampler { _, _ in
                    OpenGrokLiveSamplingResponse(output: "unused")
                },
                model: "grok-4.5",
                workspaceRoot: workspace,
                makeInvoker: { mode in
                    if let factory {
                        return try await factory.make(mode)
                    }
                    return WorkflowScratchInvoker(workingDirectory: workspace)
                }
            ),
            scratchRoot: scratch
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("Live workflow scratch security", .serialized)
struct LiveWorkflowScratchSecurityParityTests {
    @Test("the real host returns a logical scratch artifact and privately persists its contents")
    func validScratchRoundTripUsesPrivateLogicalArtifact() async throws {
        let fixture = try WorkflowScratchFixture()
        defer { fixture.cleanup() }
        let host = fixture.makeHost()

        let artifact = try await host.writeScratchFile(name: "report.md", content: "private report")
        let contents = try await host.readScratchFile(name: "report.md")
        let file = fixture.scratch.appendingPathComponent("report.md")
        let ownerOnly = try SecureFile.isOwnerOnly(at: file)

        #expect(artifact == "scratch/report.md")
        #expect(contents == "private report")
        #expect(ownerOnly)
        #if !os(Windows)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.scratch.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o700)
        #endif
    }

    @Test("the actual Rhai engine observes scratch paths and reads from its live host")
    func actualWorkflowEngineUsesSecureLiveHost() async throws {
        let fixture = try WorkflowScratchFixture()
        defer { fixture.cleanup() }
        let host = fixture.makeHost()
        let script = """
        let meta = #{ name: "scratch", description: "secure live host" };
        let path = write_scratch_file("engine.txt", "engine content");
        let content = read_scratch_file("engine.txt");
        complete(#{ path: path, content: content });
        """

        let outcome = await RhaiWorkflowEngine.run(RhaiWorkflowRunParameters(
            script: script,
            journal: RhaiJournal(),
            host: host
        ))

        #expect(outcome == .completed(result: .object([
            "path": .string("scratch/engine.txt"),
            "content": .string("engine content"),
        ])))
    }

    @Test("absolute, traversal, empty, separator, NUL, and Windows-shaped names fail before mutation")
    func hostileNamesAreRejectedRatherThanNormalized() async throws {
        let fixture = try WorkflowScratchFixture()
        defer { fixture.cleanup() }
        let host = fixture.makeHost()
        let rejected = [
            "", ".", "..", "../outside.txt", "../../outside.txt",
            "nested/report.txt", "/outside.txt", "..\\outside.txt",
            "C:\\outside.txt", "\\\\server\\share\\outside.txt", "bad\0name",
        ]

        for name in rejected {
            do {
                _ = try await host.writeScratchFile(name: name, content: "unsafe")
                Issue.record("hostile scratch name was accepted: \(name.debugDescription)")
            } catch {
                #expect(String(describing: error).contains("single relative path component"))
            }
            do {
                _ = try await host.readScratchFile(name: name)
                Issue.record("hostile scratch read was accepted: \(name.debugDescription)")
            } catch {
                #expect(String(describing: error).contains("single relative path component"))
            }
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.scratch.path))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.workspace.appendingPathComponent("outside.txt").path
        ))
    }

    @Test("scratch names enforce the upstream 255-byte UTF-8 boundary")
    func filenameLimitCountsUTF8Bytes() async throws {
        let fixture = try WorkflowScratchFixture()
        defer { fixture.cleanup() }
        let host = fixture.makeHost()

        #if os(Windows)
        let accepted = String(repeating: "é", count: 127) + "x"
        #else
        let accepted = String(repeating: "a", count: 255)
        #endif
        let rejected = String(repeating: "é", count: 128)
        let artifact = try await host.writeScratchFile(name: accepted, content: "boundary")
        let contents = try await host.readScratchFile(name: accepted)

        #expect(artifact == "scratch/\(accepted)")
        #expect(contents == "boundary")
        do {
            _ = try await host.writeScratchFile(name: rejected, content: "unsafe")
            Issue.record("256-byte scratch name unexpectedly succeeded")
        } catch {
            #expect(String(describing: error).contains("name exceeds 255 bytes"))
        }
    }

    @Test("file size is capped by UTF-8 bytes before a scratch directory exists")
    func perFileQuotaRejectsOversizedUTF8Content() async throws {
        let fixture = try WorkflowScratchFixture()
        defer { fixture.cleanup() }
        let host = fixture.makeHost()
        let content = String(repeating: "é", count: LiveWorkflowScratchSecurity.maximumFileBytes / 2 + 1)

        do {
            _ = try await host.writeScratchFile(name: "oversized.txt", content: content)
            Issue.record("oversized scratch content unexpectedly succeeded")
        } catch {
            #expect(String(describing: error).contains("10485760 byte limit"))
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.scratch.path))
    }

    @Test("64 files are allowed, replacement remains allowed, and a 65th file is refused")
    func fileCountQuotaAndReplacementMatchUpstream() async throws {
        let fixture = try WorkflowScratchFixture()
        defer { fixture.cleanup() }
        let host = fixture.makeHost()

        for index in 0..<LiveWorkflowScratchSecurity.maximumFiles {
            let artifact = try await host.writeScratchFile(
                name: "file-\(index).txt",
                content: "a"
            )
            #expect(artifact == "scratch/file-\(index).txt")
        }
        let replaced = try await host.writeScratchFile(name: "file-0.txt", content: "replacement")
        #expect(replaced == "scratch/file-0.txt")

        do {
            _ = try await host.writeScratchFile(name: "file-64.txt", content: "unsafe")
            Issue.record("65th scratch file unexpectedly succeeded")
        } catch {
            #expect(String(describing: error).contains("scratch file quota exceeded (maximum 64)"))
        }
        #expect(!FileManager.default.fileExists(
            atPath: fixture.scratch.appendingPathComponent("file-64.txt").path
        ))
    }

    @Test("the 64 MiB aggregate quota uses logical file sizes and subtracts the replaced file")
    func aggregateQuotaUsesReplacementAwareFileSizes() async throws {
        let fixture = try WorkflowScratchFixture()
        defer { fixture.cleanup() }
        let host = fixture.makeHost()
        let seedArtifact = try await host.writeScratchFile(name: "seed.txt", content: "x")
        #expect(seedArtifact == "scratch/seed.txt")

        for index in 0..<6 {
            let path = fixture.scratch.appendingPathComponent("sparse-\(index).bin")
            try SecureFile.write(at: path, contents: Data())
            let handle = try FileHandle(forWritingTo: path)
            try handle.truncate(atOffset: UInt64(LiveWorkflowScratchSecurity.maximumFileBytes))
            try handle.close()
        }
        let tail = fixture.scratch.appendingPathComponent("tail.bin")
        try SecureFile.write(at: tail, contents: Data())
        let tailHandle = try FileHandle(forWritingTo: tail)
        let remainder = LiveWorkflowScratchSecurity.maximumTotalBytes
            - 6 * LiveWorkflowScratchSecurity.maximumFileBytes - 1
        try tailHandle.truncate(atOffset: UInt64(remainder))
        try tailHandle.close()

        let replaced = try await host.writeScratchFile(name: "seed.txt", content: "z")
        #expect(replaced == "scratch/seed.txt")
        do {
            _ = try await host.writeScratchFile(name: "overflow.txt", content: "x")
            Issue.record("scratch aggregate quota unexpectedly accepted another byte")
        } catch {
            #expect(String(describing: error).contains("scratch byte quota exceeded (maximum 67108864)"))
        }
        #expect(!FileManager.default.fileExists(
            atPath: fixture.scratch.appendingPathComponent("overflow.txt").path
        ))
    }

    @Test("reads reject oversized files without following paths or allocating their contents")
    func oversizedFileReadFailsClosed() async throws {
        let fixture = try WorkflowScratchFixture()
        defer { fixture.cleanup() }
        let host = fixture.makeHost()
        _ = try await host.writeScratchFile(name: "large.bin", content: "x")
        let path = fixture.scratch.appendingPathComponent("large.bin")
        let handle = try FileHandle(forWritingTo: path)
        try handle.truncate(atOffset: UInt64(LiveWorkflowScratchSecurity.maximumFileBytes + 1))
        try handle.close()

        do {
            _ = try await host.readScratchFile(name: "large.bin")
            Issue.record("oversized scratch file unexpectedly became readable")
        } catch {
            #expect(String(describing: error).contains("10485760"))
        }
    }

    @Test("a non-private existing scratch file fails closed instead of being silently reused")
    func preexistingNonPrivateFileIsRejected() async throws {
        let fixture = try WorkflowScratchFixture()
        defer { fixture.cleanup() }
        let host = fixture.makeHost()
        _ = try await host.writeScratchFile(name: "existing.txt", content: "private")
        let path = fixture.scratch.appendingPathComponent("existing.txt")

        #if os(Windows)
        // Windows owner-private ACL tampering requires privileged ACL fixtures;
        // regular owner-only replacement remains covered on that platform.
        let rewritten = try await host.writeScratchFile(name: "existing.txt", content: "still private")
        #expect(rewritten == "scratch/existing.txt")
        #else
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
        for operation in 0..<2 {
            do {
                if operation == 0 {
                    _ = try await host.readScratchFile(name: "existing.txt")
                } else {
                    _ = try await host.writeScratchFile(name: "existing.txt", content: "unsafe")
                }
                Issue.record("non-private scratch file was unexpectedly accepted")
            } catch {
                #expect(String(describing: error).contains("not private"))
            }
        }
        let unchanged = try String(contentsOf: path, encoding: .utf8)
        #expect(unchanged == "private")
        #endif
    }

    #if !os(Windows)
    @Test("a symlinked scratch root cannot redirect writes or expose an outside file")
    func symlinkedScratchRootCannotEscape() async throws {
        let fixture = try WorkflowScratchFixture()
        defer { fixture.cleanup() }
        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let secret = outside.appendingPathComponent("secret.txt")
        try SecureFile.write(at: secret, contents: "outside secret")
        try FileManager.default.createDirectory(
            at: fixture.scratch.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: fixture.scratch, withDestinationURL: outside)
        let host = fixture.makeHost()

        for read in [false, true] {
            do {
                if read {
                    _ = try await host.readScratchFile(name: "secret.txt")
                } else {
                    _ = try await host.writeScratchFile(name: "new.txt", content: "unsafe")
                }
                Issue.record("a symlinked scratch root unexpectedly succeeded")
            } catch {
                #expect(String(describing: error).contains("symlink"))
            }
        }
        let unchanged = try String(contentsOf: secret, encoding: .utf8)
        #expect(unchanged == "outside secret")
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("new.txt").path))
    }

    @Test("a symlinked workflow-scratch parent is rejected before its target is modified")
    func symlinkedScratchParentCannotEscape() async throws {
        let fixture = try WorkflowScratchFixture()
        defer { fixture.cleanup() }
        let outside = fixture.root.appendingPathComponent("outside-parent", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: fixture.scratch.deletingLastPathComponent(),
            withDestinationURL: outside
        )
        let host = fixture.makeHost()

        do {
            _ = try await host.writeScratchFile(name: "outside.txt", content: "unsafe")
            Issue.record("a symlinked workflow-scratch parent unexpectedly succeeded")
        } catch {
            #expect(String(describing: error).contains("symlink"))
        }

        let entries = try FileManager.default.contentsOfDirectory(atPath: outside.path)
        #expect(entries.isEmpty)
    }

    @Test("a final symlink is never read, replaced, or ignored during directory quota inspection")
    func symlinkedScratchFileNeverTouchesItsOutsideTarget() async throws {
        let fixture = try WorkflowScratchFixture()
        defer { fixture.cleanup() }
        let host = fixture.makeHost()
        _ = try await host.writeScratchFile(name: "seed.txt", content: "seed")
        let outside = fixture.root.appendingPathComponent("outside-secret.txt")
        try SecureFile.write(at: outside, contents: "outside secret")
        let alias = fixture.scratch.appendingPathComponent("alias.txt")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)

        do {
            _ = try await host.readScratchFile(name: "alias.txt")
            Issue.record("a symlinked scratch file exposed outside contents")
        } catch {
            #expect(String(describing: error).contains("symlink"))
        }
        do {
            _ = try await host.writeScratchFile(name: "alias.txt", content: "unsafe")
            Issue.record("a symlinked scratch file was overwritten")
        } catch {
            #expect(String(describing: error).contains("symlink"))
        }
        do {
            _ = try await host.writeScratchFile(name: "another.txt", content: "unsafe")
            Issue.record("scratch quota enumeration ignored a hostile symlink")
        } catch {
            #expect(String(describing: error).contains("symlink"))
        }

        let unchanged = try String(contentsOf: outside, encoding: .utf8)
        #expect(unchanged == "outside secret")
        #expect(!FileManager.default.fileExists(
            atPath: fixture.scratch.appendingPathComponent("another.txt").path
        ))
    }

    @Test("a FIFO is rejected as non-regular without blocking the workflow actor")
    func fifoCannotBlockScratchRead() async throws {
        let fixture = try WorkflowScratchFixture()
        defer { fixture.cleanup() }
        let host = fixture.makeHost()
        _ = try await host.writeScratchFile(name: "seed.txt", content: "seed")
        let fifo = fixture.scratch.appendingPathComponent("blocked.pipe")
        let created = fifo.path.withCString { mkfifo($0, mode_t(0o600)) }
        #expect(created == 0)

        do {
            _ = try await host.readScratchFile(name: "blocked.pipe")
            Issue.record("a FIFO unexpectedly became a readable scratch artifact")
        } catch {
            #expect(String(describing: error).contains("regular file"))
        }
    }
    #else
    @Test("Windows device, alternate-stream, drive-relative, and reserved names are rejected")
    func windowsReservedNamesFailClosed() async throws {
        let fixture = try WorkflowScratchFixture()
        defer { fixture.cleanup() }
        let host = fixture.makeHost()

        for name in ["CON", "NUL.txt", "report.txt:secret", "C:relative.txt", "bad.", "bad "] {
            do {
                _ = try await host.writeScratchFile(name: name, content: "unsafe")
                Issue.record("reserved Windows scratch name was accepted: \(name)")
            } catch {
                #expect(String(describing: error).contains("single relative path component"))
            }
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.scratch.path))
    }
    #endif

    @Test("concurrent equal-capability children share exactly one live invoker construction")
    func invokerConstructionIsCoalescedPerCapability() async throws {
        let fixture = try WorkflowScratchFixture()
        defer { fixture.cleanup() }
        let factory = WorkflowScratchInvokerFactory(workingDirectory: fixture.workspace)
        let host = fixture.makeHost(factory: factory)

        try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    let invoker = try await host.invoker(for: .readWrite)
                    return invoker.workingDirectory == fixture.workspace
                }
            }
            for try await matches in group {
                #expect(matches)
            }
        }

        let calls = await factory.calls
        #expect(calls == 1)
    }

    @Test("a failed shared invoker construction is evicted and the next request retries")
    func failedInvokerConstructionCanRetry() async throws {
        let fixture = try WorkflowScratchFixture()
        defer { fixture.cleanup() }
        let factory = WorkflowScratchInvokerFactory(
            workingDirectory: fixture.workspace,
            failFirst: true
        )
        let host = fixture.makeHost(factory: factory)

        do {
            _ = try await host.invoker(for: .readWrite)
            Issue.record("the first invoker unexpectedly succeeded")
        } catch {
            #expect(String(describing: error).contains("construction failed"))
        }
        let recovered = try await host.invoker(for: .readWrite)
        let calls = await factory.calls

        #expect(recovered.workingDirectory == fixture.workspace)
        #expect(calls == 2)
    }
}
