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
    private func expectRefusal(extraArguments: [String], flag: String) async {
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

        #expect(code != CLIRunner.ExitCode.success.rawValue)
        #expect(code == CLIRunner.ExitCode.notImplemented.rawValue)
        #expect(out.contents.isEmpty)
        #expect(err.contents.contains(flag))
        #expect(err.contents.contains("nothing in this composition honors yet"))
    }

    @Test("--no-plan is refused before launch")
    func noPlan() async {
        await expectRefusal(extraArguments: ["--no-plan"], flag: "--no-plan")
    }

    @Test("--no-ask-user is refused before launch")
    func noAskUser() async {
        await expectRefusal(extraArguments: ["--no-ask-user"], flag: "--no-ask-user")
    }

    @Test("--todo-gate is refused before launch")
    func todoGate() async {
        await expectRefusal(extraArguments: ["--todo-gate"], flag: "--todo-gate")
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
}
