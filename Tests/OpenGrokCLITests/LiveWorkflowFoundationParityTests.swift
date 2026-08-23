import Foundation
import OpenGrokFastWorktree
import OpenGrokSessionRuntime
import OpenGrokShared
import OpenGrokWorkflow
import Testing

@testable import OpenGrokCLI

private struct WorkflowFoundationFixture {
    let root: URL
    let workspace: URL
    let home: URL
    let environment: [String: String]

    init(gitRepository: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-workflow-foundation-\(UUID().uuidString)",
            isDirectory: true
        )
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "PATH": ProcessInfo.processInfo.environment["PATH"]
                ?? ProcessInfo.processInfo.environment["Path"]
                ?? "",
        ]

        if gitRepository {
            try git(["init"])
            try git(["config", "user.email", "workflow-foundation@example.test"])
            try git(["config", "user.name", "Workflow Foundation Parity"])
            try "committed line\n".write(
                to: workspace.appendingPathComponent("tracked.txt"),
                atomically: true,
                encoding: .utf8
            )
            try git(["add", "tracked.txt"])
            try git(["commit", "-m", "Initial workflow foundation"])
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func git(_ arguments: [String]) throws -> String {
        let result = try runGit(arguments, cwd: workspace)
        guard result.exitCode == 0 else {
            throw NSError(
                domain: "LiveWorkflowFoundationGit",
                code: Int(result.exitCode),
                userInfo: [NSLocalizedDescriptionKey: result.stderr]
            )
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    #if !os(Windows)
    func fakeGit(_ script: String) throws -> [String: String] {
        let binaries = root.appendingPathComponent("fake-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binaries, withIntermediateDirectories: true)
        let executable = binaries.appendingPathComponent("git")
        try ("#!/bin/sh\n" + script + "\n").write(
            to: executable,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: executable.path
        )
        var resolved = environment
        resolved["PATH"] = binaries.path
        return resolved
    }
    #endif

    func host(
        templates: LiveWorkflowTemplates = .empty,
        gitEnvironment: [String: String]? = nil,
        timeout: TimeInterval = LiveWorkflowGitDiff.timeoutSeconds
    ) -> LiveWorkflowHost {
        let context = RhaiWorkflowRunContext(
            runID: "foundation-\(UUID().uuidString)",
            workflowName: "foundation",
            arguments: .object([:]),
            agentBudget: 8,
            journalURL: nil,
            cancellation: RhaiCancellationToken()
        )
        let agentEnvironment = LiveWorkflowAgentEnvironment(
            sampler: OpenGrokLiveSampler { _, _ in
                OpenGrokLiveSamplingResponse(output: "unused workflow agent")
            },
            model: "grok-4.5",
            workspaceRoot: workspace,
            makeInvoker: { _ in
                throw RhaiHostError.failed("foundation tests never spawn an agent")
            }
        )
        let resolvedEnvironment = gitEnvironment ?? environment
        return LiveWorkflowHost(
            context: context,
            environment: agentEnvironment,
            scratchRoot: root.appendingPathComponent("scratch", isDirectory: true),
            templates: templates,
            gitDiff: { commit, directory in
                try await LiveWorkflowGitDiff.run(
                    commit,
                    directory,
                    environment: resolvedEnvironment,
                    timeout: timeout
                )
            }
        )
    }

    func runScript(_ script: String, host: LiveWorkflowHost) async -> RhaiWorkflowOutcome {
        await RhaiWorkflowEngine.run(RhaiWorkflowRunParameters(
            script: script,
            journal: RhaiJournal(clock: { 1 }),
            host: host
        ))
    }
}

@Suite("Live workflow Git diff and template foundation", .serialized)
struct LiveWorkflowFoundationParityTests {
    @Test("git_diff_since accepts only nonempty ASCII alphanumeric commit identifiers")
    func commitValidationFailsClosed() async throws {
        let fixture = try WorkflowFoundationFixture()
        defer { fixture.cleanup() }

        for commit in ["", "HEAD~1", "abc..HEAD", "abc def", "--output=/tmp/leak", "é"] {
            do {
                _ = try await LiveWorkflowGitDiff.run(
                    commit,
                    fixture.workspace,
                    environment: fixture.environment
                )
                Issue.record("unsafe git commit unexpectedly accepted: \(commit)")
            } catch let error as RhaiHostError {
                guard case let .failed(message) = error else {
                    Issue.record("commit validation returned the wrong failure: \(error)")
                    continue
                }
                #expect(message == "git_diff_since expects a commit hash, got: \(commit)")
            }
        }
    }

    @Test("real git repository diff reaches the workflow host and live Rhai interpreter")
    func realGitDiffReachesLiveInterpreter() async throws {
        let fixture = try WorkflowFoundationFixture(gitRepository: true)
        defer { fixture.cleanup() }
        let commit = try fixture.git(["rev-parse", "HEAD"])
        try "changed by the workflow test\n".write(
            to: fixture.workspace.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )

        let host = fixture.host()
        let output = try await host.gitDiffSince(commit: commit)
        #expect(output.contains("tracked.txt"))
        #expect(output.contains("+changed by the workflow test"))

        let outcome = await fixture.runScript(
            #"let delta = git_diff_since("\#(commit)"); complete(delta);"#,
            host: host
        )
        guard case let .completed(result) = outcome,
              case let .string(scriptOutput) = result
        else {
            Issue.record("live Rhai Git diff unexpectedly failed: \(outcome)")
            return
        }
        #expect(scriptOutput.contains("+changed by the workflow test"))
    }

    @Test("real output above pipe capacity drains concurrently and truncates on a UTF-8 boundary")
    func largeGitOutputIsBoundedAndUnicodeSafe() async throws {
        let fixture = try WorkflowFoundationFixture(gitRepository: true)
        defer { fixture.cleanup() }
        let commit = try fixture.git(["rev-parse", "HEAD"])
        let large = String(repeating: "😀abcdefghijklmnopqrstuvwxyz0123456789\n", count: 12_000)
        try large.write(
            to: fixture.workspace.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )

        let diff = try await LiveWorkflowGitDiff.run(
            commit,
            fixture.workspace,
            environment: fixture.environment,
            timeout: 10
        )
        #expect(diff.hasSuffix(LiveWorkflowGitDiff.truncationMarker))
        let payload = String(diff.dropLast(LiveWorkflowGitDiff.truncationMarker.count))
        #expect(payload.utf8.count <= LiveWorkflowGitDiff.maximumOutputBytes)
        #expect(payload.utf8.count > 200_000)
        #expect(!payload.contains("�"))
    }

    @Test("nonzero git exit preserves stderr as a real script-catchable host failure")
    func nonzeroGitExitReachesScriptCatch() async throws {
        let fixture = try WorkflowFoundationFixture(gitRepository: true)
        defer { fixture.cleanup() }
        let unknown = String(repeating: "a", count: 40)
        let host = fixture.host()

        do {
            _ = try await host.gitDiffSince(commit: unknown)
            Issue.record("nonexistent git commit unexpectedly succeeded")
        } catch let error as RhaiHostError {
            guard case let .failed(message) = error else {
                Issue.record("git returned the wrong host error: \(error)")
                return
            }
            #expect(message.contains("git diff exited with"))
            #expect(message.contains("fatal:") || message.contains("ambiguous argument"))
        }

        let outcome = await fixture.runScript(
            #"let reason = ""; try { git_diff_since("\#(unknown)"); } catch (error) { reason = error; } complete(reason);"#,
            host: host
        )
        guard case let .completed(result) = outcome,
              case let .string(message) = result
        else {
            Issue.record("Git host error did not reach Rhai catch: \(outcome)")
            return
        }
        #expect(message.contains("git diff exited with"))
    }

    @Test("missing PATH executable fails loudly instead of returning an invented empty diff")
    func missingGitFailsClosed() async throws {
        let fixture = try WorkflowFoundationFixture()
        defer { fixture.cleanup() }
        let empty = fixture.root.appendingPathComponent("empty-path", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        var environment = fixture.environment
        environment["PATH"] = empty.path
        environment["Path"] = empty.path

        do {
            _ = try await LiveWorkflowGitDiff.run("abc123", fixture.workspace, environment: environment)
            Issue.record("missing git executable unexpectedly succeeded")
        } catch let error as RhaiHostError {
            #expect(error == .failed("git diff: git executable was not found on PATH"))
        }
    }

    #if !os(Windows)
    @Test("git receives exactly diff and the validated commit, never a synthesized revision range")
    func gitArgumentsMatchRustExactly() async throws {
        let fixture = try WorkflowFoundationFixture()
        defer { fixture.cleanup() }
        let environment = try fixture.fakeGit(#"printf '%s|%s|%s' "$#" "$1" "$2""#)
        let output = try await LiveWorkflowGitDiff.run(
            "abc123",
            fixture.workspace,
            environment: environment,
            timeout: 3
        )
        #expect(output == "2|diff|abc123")
    }

    @Test("large simultaneous stdout and stderr streams drain before child completion")
    func stdoutAndStderrDrainConcurrently() async throws {
        let fixture = try WorkflowFoundationFixture()
        defer { fixture.cleanup() }
        let environment = try fixture.fakeGit("""
        i=0
        while [ "$i" -lt 1600 ]; do
          printf 'OUT-abcdefghijklmnopqrstuvwxyz-0123456789-ABCDEFGHIJKLMNOPQRSTUVWXYZ-END\\n'
          printf 'ERR-abcdefghijklmnopqrstuvwxyz-0123456789-ABCDEFGHIJKLMNOPQRSTUVWXYZ-END\\n' >&2
          i=$((i + 1))
        done
        """)
        let output = try await LiveWorkflowGitDiff.run(
            "abc123",
            fixture.workspace,
            environment: environment,
            timeout: 8
        )
        #expect(output.utf8.count > 64 * 1024)
        #expect(output.hasPrefix("OUT-"))
        #expect(output.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ-END"))
    }

    @Test("deadline kills a stalled git process and reports the upstream timeout error")
    func stalledGitTimesOut() async throws {
        let fixture = try WorkflowFoundationFixture()
        defer { fixture.cleanup() }
        let environment = try fixture.fakeGit("exec /bin/sleep 10")
        let started = Date()

        do {
            _ = try await LiveWorkflowGitDiff.run(
                "abc123",
                fixture.workspace,
                environment: environment,
                timeout: 0.15
            )
            Issue.record("stalled git command unexpectedly succeeded")
        } catch let error as RhaiHostError {
            #expect(error == .failed("git diff timed out"))
            #expect(Date().timeIntervalSince(started) < 3)
        }
    }

    @Test("task cancellation kills the child promptly and remains terminal workflow cancellation")
    func taskCancellationKillsGit() async throws {
        let fixture = try WorkflowFoundationFixture()
        defer { fixture.cleanup() }
        let environment = try fixture.fakeGit("exec /bin/sleep 10")
        let started = Date()
        let task = Task {
            try await LiveWorkflowGitDiff.run(
                "abc123",
                fixture.workspace,
                environment: environment,
                timeout: 10
            )
        }
        try await Task.sleep(nanoseconds: 80_000_000)
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("cancelled git command unexpectedly succeeded")
        } catch let error as RhaiHostError {
            #expect(error == .cancelled)
            #expect(Date().timeIntervalSince(started) < 3)
        }
    }
    #endif

    @Test("production template map is empty and unknown names fail with the exact upstream failure")
    func productionTemplatesRemainExplicitlyEmpty() async throws {
        let fixture = try WorkflowFoundationFixture()
        defer { fixture.cleanup() }
        let host = fixture.host()

        do {
            _ = try await host.renderTemplate(name: "../workspace/private", variables: .object([:]))
            Issue.record("empty production template map unexpectedly loaded a project file")
        } catch let error as RhaiHostError {
            #expect(error == .failed("unknown template: ../workspace/private"))
        }
    }

    @Test("trusted injected templates substitute raw strings and canonical JSON without resolving missing variables")
    func injectedTemplateSubstitutionMatchesRust() throws {
        let templates = LiveWorkflowTemplates(entries: [
            "summary": "Name={name}; enabled={enabled}; count={count}; object={object}; remaining={missing}",
        ])
        let output = try templates.render(
            name: "summary",
            variables: .object([
                "name": .string("Ada / Lovelace"),
                "enabled": .bool(true),
                "count": .number(.int64(4)),
                "object": .object([
                    "z": .number(.int64(2)),
                    "a": .array([.string("value")]),
                ]),
            ])
        )
        #expect(output == #"Name=Ada / Lovelace; enabled=true; count=4; object={"a":["value"],"z":2}; remaining={missing}"#)
        #expect(try templates.render(name: "summary", variables: .array([])) ==
            "Name={name}; enabled={enabled}; count={count}; object={object}; remaining={missing}")
    }

    @Test("template input and rendered UTF-8 output enforce the exact one-MiB limit")
    func templatesEnforceByteBounds() throws {
        let exact = String(repeating: "a", count: LiveWorkflowTemplates.maximumOutputBytes)
        let exactTemplates = LiveWorkflowTemplates(entries: ["exact": exact])
        #expect(try exactTemplates.render(name: "exact", variables: .object([:])).utf8.count ==
            LiveWorkflowTemplates.maximumOutputBytes)

        let oversized = LiveWorkflowTemplates(entries: ["huge": exact + "x"])
        do {
            _ = try oversized.render(name: "huge", variables: .object([:]))
            Issue.record("oversized raw template unexpectedly rendered")
        } catch let error as RhaiHostError {
            #expect(error == .failed("template exceeds 1048576 bytes"))
        }

        let expands = LiveWorkflowTemplates(entries: ["expands": "{value}"])
        do {
            _ = try expands.render(name: "expands", variables: .object(["value": .string(exact + "x")]))
            Issue.record("oversized rendered template unexpectedly succeeded")
        } catch let error as RhaiHostError {
            #expect(error == .failed("rendered template exceeds 1048576 bytes"))
        }
    }

    @Test("actual live workflow host and Rhai interpreter receive trusted injected templates")
    func injectedTemplatesReachLiveInterpreter() async throws {
        let fixture = try WorkflowFoundationFixture()
        defer { fixture.cleanup() }
        let host = fixture.host(templates: LiveWorkflowTemplates(entries: [
            "review": "Review {topic}; findings={count}; missing={unknown}",
        ]))
        let output = try await host.renderTemplate(
            name: "review",
            variables: .object([
                "topic": .string("permission gates"),
                "count": .number(.int64(3)),
            ])
        )
        #expect(output == "Review permission gates; findings=3; missing={unknown}")

        let outcome = await fixture.runScript(
            #"let report = render_template("review", #{ topic: "live security", count: 7 }); complete(report);"#,
            host: host
        )
        #expect(outcome == .completed(result: .string(
            "Review live security; findings=7; missing={unknown}"
        )))
    }

    @Test("missing templates remain catchable failures through the actual Rhai interpreter")
    func missingTemplateIsCatchableByScript() async throws {
        let fixture = try WorkflowFoundationFixture()
        defer { fixture.cleanup() }
        let outcome = await fixture.runScript(
            #"let reason = ""; try { render_template("missing", #{}); } catch (error) { reason = error; } complete(reason);"#,
            host: fixture.host()
        )
        #expect(outcome == .completed(result: .string("unknown template: missing")))
    }
}
