// LiveUnhonoredLaunchFlagTests.swift
//
// Each flag in `unhonoredLaunchFlag` must refuse before any session work
// starts — accepting one and ignoring it would run with the wrong constraints.
// These assert through the live launcher seam (AGENTS.md §3): parse, validate,
// nonzero exit, and the generic refusal copy naming the flag.

import Foundation
import Testing
@testable import OpenGrokCLI

@Suite("Unhonored launch flags refuse at validation", .serialized)
struct LiveUnhonoredLaunchFlagTests {
    private func run(_ extraArguments: [String]) async -> (Int32, String, String) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-launch-flags-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: home,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            Issue.record("could not create an isolated launch-flag home: \(error)")
            return (CLIRunner.ExitCode.failure.rawValue, "", "\(error)")
        }
        let environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "GROK_SANDBOX": "off",
        ]
        defer {
            LiveManagedPolicyLifecycle.stop(environment: environment)
            try? FileManager.default.removeItem(at: home)
        }
        let (streams, out, err) = CLIStreams.buffered()
        let code = await CLIRunner.run(
            ["headless", "--prompt", "hi"] + extraArguments,
            environment: environment,
            streams: streams,
            application: OpenGrokApplication.live(control: .never)
        )
        return (code, out.contents, err.contents)
    }

    private func expectRefusal(extraArguments: [String], flag: String) async {
        let (code, out, err) = await run(extraArguments)

        #expect(code != CLIRunner.ExitCode.success.rawValue)
        #expect(code == CLIRunner.ExitCode.notImplemented.rawValue)
        #expect(out.isEmpty)
        #expect(err.contains(flag))
        #expect(err.contains("nothing in this composition honors yet"))
    }

    @Test("--no-plan removes both plan-mode tools through live launch authority")
    func noPlan() throws {
        let command = try CLICommandParser.parseOrThrow(
            ["headless", "--prompt", "hi", "--no-plan"]
        )
        guard case .launch(let options) = command else {
            Issue.record("expected --no-plan to select the live launch route")
            return
        }
        let authority = try LiveAgentLaunchAuthority.resolve(
            options: options,
            workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            environment: ["HOME": NSTemporaryDirectory(), "OPENGROK_HOME": NSTemporaryDirectory()]
        )
        let policy = try #require(authority.toolPolicy(tools: nil, disallowedTools: nil))
        #expect(authority.noPlan)
        #expect(!policy.allows(liveToolName: "enter_plan_mode"))
        #expect(!policy.allows(liveToolName: "exit_plan_mode"))
    }

    @Test("--no-ask-user removes the actual question tool through live launch authority")
    func noAskUser() throws {
        let command = try CLICommandParser.parseOrThrow(
            ["headless", "--prompt", "hi", "--no-ask-user"]
        )
        guard case .launch(let options) = command else {
            Issue.record("expected --no-ask-user to select the live launch route")
            return
        }
        let authority = try LiveAgentLaunchAuthority.resolve(
            options: options,
            workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            environment: ["HOME": NSTemporaryDirectory(), "OPENGROK_HOME": NSTemporaryDirectory()]
        )
        let policy = try #require(authority.toolPolicy(tools: nil, disallowedTools: nil))
        #expect(authority.noAskUser)
        #expect(!policy.allows(liveToolName: "ask_user_question"))
    }

    @Test("--todo-gate reaches its live runtime rather than unsupported-flag refusal")
    func todoGate() async {
        let (code, _, error) = await run(["--todo-gate"])
        #expect(code != CLIRunner.ExitCode.notImplemented.rawValue)
        #expect(!error.contains("nothing in this composition honors yet"))
    }

    @Test("--compaction-mode reaches its live compaction policy")
    func compactionMode() async {
        let (code, _, error) = await run(["--compaction-mode", "segments"])
        #expect(code != CLIRunner.ExitCode.notImplemented.rawValue)
        #expect(!error.contains("nothing in this composition honors yet"))
    }

    @Test("--compaction-detail reaches its live compaction policy")
    func compactionDetail() async {
        let (code, _, error) = await run(["--compaction-detail", "minimal"])
        #expect(code != CLIRunner.ExitCode.notImplemented.rawValue)
        #expect(!error.contains("nothing in this composition honors yet"))
    }

    @Test("--hunk-tracker-mode reaches the actual file-tool tracker")
    func hunkTrackerMode() async {
        let (code, _, error) = await run(["--hunk-tracker-mode", "off"])
        #expect(code != CLIRunner.ExitCode.notImplemented.rawValue)
        #expect(!error.contains("nothing in this composition honors yet"))
    }

    @Test("--storage-mode writeback reaches first-party persistence authorization")
    func storageMode() async {
        let (code, _, error) = await run(["--storage-mode", "writeback"])
        #expect(code != CLIRunner.ExitCode.notImplemented.rawValue)
        #expect(!error.contains("nothing in this composition honors yet"))
    }

    @Test("unknown --storage-mode values are refused before launch")
    func unsupportedStorageMode() async {
        await expectRefusal(
            extraArguments: ["--storage-mode", "unknown"],
            flag: "--storage-mode"
        )
    }

    @Test("--client-identifier reaches the actual session and provider")
    func clientIdentifier() async {
        let (code, _, error) = await run(["--client-identifier", "ci"])
        #expect(code != CLIRunner.ExitCode.notImplemented.rawValue)
        #expect(!error.contains("nothing in this composition honors yet"))
    }

    @Test("--installer reaches durable owner update configuration")
    func installer() async {
        let (code, _, error) = await run(["--installer", "brew"])
        #expect(code != CLIRunner.ExitCode.notImplemented.rawValue)
        #expect(!error.contains("nothing in this composition honors yet"))
    }

    @Test("--xai-api-base-url reaches the first-party sampling configuration")
    func xaiAPIBaseURL() async {
        let (code, _, error) = await run([
            "--xai-api-base-url", "https://inference.example.test/v1",
        ])
        #expect(code != CLIRunner.ExitCode.notImplemented.rawValue)
        #expect(!error.contains("nothing in this composition honors yet"))
    }

    @Test("--cli-chat-proxy-base-url reaches only first-party auxiliary services")
    func chatProxyBaseURL() async {
        let (code, _, error) = await run([
            "--cli-chat-proxy-base-url", "https://proxy.example.test/v1",
        ])
        #expect(code != CLIRunner.ExitCode.notImplemented.rawValue)
        #expect(!error.contains("nothing in this composition honors yet"))
    }

    @Test("--terminal is refused before launch")
    func terminal() async {
        await expectRefusal(extraArguments: ["--terminal"], flag: "--terminal")
    }

    @Test("--fs-read is refused before launch")
    func fsRead() async {
        await expectRefusal(extraArguments: ["--fs-read"], flag: "--fs-read")
    }

    @Test("--fs-write is refused before launch")
    func fsWrite() async {
        await expectRefusal(extraArguments: ["--fs-write"], flag: "--fs-write")
    }

    @Test("--force-login is refused before launch")
    func forceLogin() async {
        await expectRefusal(extraArguments: ["--force-login"], flag: "--force-login")
    }

    @Test("--log-sampling reaches bounded owner-private sampling diagnostics")
    func logSampling() async {
        let (code, _, error) = await run(["--log-sampling"])
        #expect(code != CLIRunner.ExitCode.notImplemented.rawValue)
        #expect(!error.contains("nothing in this composition honors yet"))
    }

    @Test("--no-wait-for-background reaches bounded headless shutdown")
    func noWaitForBackground() async {
        let (code, _, error) = await run(["--no-wait-for-background"])
        #expect(code != CLIRunner.ExitCode.notImplemented.rawValue)
        #expect(!error.contains("nothing in this composition honors yet"))
    }

    @Test("--background-wait-timeout reaches bounded headless shutdown")
    func backgroundWaitTimeout() async {
        let (code, _, error) = await run(["--background-wait-timeout", "30"])
        #expect(code != CLIRunner.ExitCode.notImplemented.rawValue)
        #expect(!error.contains("nothing in this composition honors yet"))
    }

    @Test("--storage-mode local honors the existing durable local session backend")
    func localStorageMode() async {
        let (code, _, error) = await run(["--storage-mode", "local"])
        #expect(code != CLIRunner.ExitCode.notImplemented.rawValue)
        #expect(!error.contains("nothing in this composition honors yet"))
    }

    @Test("--chat is parsed but honestly refuses without the gateway frontend")
    func chatFrontendUnavailable() async {
        let (code, out, err) = await run(["--chat", "--no-leader"])
        #expect(code == CLIRunner.ExitCode.notImplemented.rawValue)
        #expect(out.isEmpty)
        #expect(err.contains("--chat gateway frontend"))
    }

    @Test("local-workspace is parsed but honestly refuses without gateway integration")
    func localWorkspaceUnavailable() async {
        let (code, out, err) = await run([
            "--chat", "--no-leader", "--local-workspace=/tmp/project"
        ])
        #expect(code == CLIRunner.ExitCode.notImplemented.rawValue)
        #expect(out.isEmpty)
        #expect(err.contains("local-workspace gateway integration"))
    }

    @Test("chat and leader conflict before unavailable frontend handling")
    func chatLeaderConflict() async {
        let (code, out, err) = await run(["--chat", "--leader"])
        #expect(code != CLIRunner.ExitCode.success.rawValue)
        #expect(out.isEmpty)
        #expect(err.contains("cannot run with leader mode"))
    }
}
