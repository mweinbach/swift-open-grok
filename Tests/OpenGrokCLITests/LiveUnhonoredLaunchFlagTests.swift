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
        let (streams, out, err) = CLIStreams.buffered()
        let code = await CLIRunner.run(
            ["headless", "--prompt", "hi"] + extraArguments,
            environment: [
                "HOME": NSTemporaryDirectory(),
                "OPENGROK_HOME": NSTemporaryDirectory(),
            ],
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

    @Test("--compaction-mode is refused before launch")
    func compactionMode() async {
        await expectRefusal(
            extraArguments: ["--compaction-mode", "segments"],
            flag: "--compaction-mode"
        )
    }

    @Test("--compaction-detail is refused before launch")
    func compactionDetail() async {
        await expectRefusal(
            extraArguments: ["--compaction-detail", "minimal"],
            flag: "--compaction-detail"
        )
    }

    @Test("--hunk-tracker-mode is refused before launch")
    func hunkTrackerMode() async {
        await expectRefusal(
            extraArguments: ["--hunk-tracker-mode", "off"],
            flag: "--hunk-tracker-mode"
        )
    }

    @Test("--storage-mode is refused before launch")
    func storageMode() async {
        await expectRefusal(
            extraArguments: ["--storage-mode", "writeback"],
            flag: "--storage-mode"
        )
    }

    @Test("--client-identifier is refused before launch")
    func clientIdentifier() async {
        await expectRefusal(
            extraArguments: ["--client-identifier", "ci"],
            flag: "--client-identifier"
        )
    }

    @Test("--installer is refused before launch")
    func installer() async {
        await expectRefusal(
            extraArguments: ["--installer", "brew"],
            flag: "--installer"
        )
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

    @Test("--log-sampling is refused before launch")
    func logSampling() async {
        await expectRefusal(extraArguments: ["--log-sampling"], flag: "--log-sampling")
    }

    @Test("--no-wait-for-background is refused before launch")
    func noWaitForBackground() async {
        await expectRefusal(
            extraArguments: ["--no-wait-for-background"],
            flag: "--no-wait-for-background"
        )
    }

    @Test("--background-wait-timeout is refused before launch")
    func backgroundWaitTimeout() async {
        await expectRefusal(
            extraArguments: ["--background-wait-timeout", "30"],
            flag: "--background-wait-timeout"
        )
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
