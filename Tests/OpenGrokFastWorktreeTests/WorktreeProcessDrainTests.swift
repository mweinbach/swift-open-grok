import Foundation
import Testing
@testable import OpenGrokFastWorktree

@Suite("worktree git process output")
struct WorktreeProcessDrainTests {
    @Test("git drains oversized stdout and stderr without pipe deadlock")
    func largeGitOutputDoesNotDeadlock() throws {
        #if !os(Windows)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("worktree-process-drain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let initialized = try runGit(["init"], cwd: directory)
        #expect(initialized.exitCode == 0)

        let alias = "alias.foundation-output=!printf '%131072s' stdout; printf '%131072s' stderr >&2"
        let result = try runGit(["-c", alias, "foundation-output"], cwd: directory)

        #expect(result.exitCode == 0)
        #expect(result.stdout.utf8.count >= 131_072)
        #expect(result.stderr.utf8.count >= 131_072)
        #expect(result.stdout.hasSuffix("stdout"))
        #expect(result.stderr.hasSuffix("stderr"))
        #endif
    }
}
