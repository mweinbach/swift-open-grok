import Foundation
import Testing
import OpenGrokReleaseValidation
@testable import OpenGrokCLI

@Suite("Release validation command")
struct ReleaseValidationCommandTests {
    private let version = "0.1.220-open-grok.58"
    private let commit = "abc1234"
    private let root = "/tmp/open-grok-release-smoke"

    @Test("the command parses explicit binary, version, root, and artifact pairs")
    func parsesReleaseValidationOptions() throws {
        let command = try CLICommandParser.parseOrThrow([
            "release-validate",
            "--binary", "/tmp/open-grok",
            "--expected-version", version,
            "--expected-commit", commit,
            "--isolated-root", root,
            "--artifact", "open-grok-macos=/tmp/open-grok-macos",
            "--sidecar", "/tmp/open-grok-macos.sha256",
        ])

        guard case .releaseValidate(let options) = command else {
            Issue.record("expected the release validation route")
            return
        }
        #expect(options.binaryPath == "/tmp/open-grok")
        #expect(options.expectedVersion == version)
        #expect(options.expectedShortCommit == commit)
        #expect(options.isolatedRoot == root)
        #expect(options.artifacts == [
            CLIReleaseValidationArtifact(
                name: "open-grok-macos",
                artifactPath: "/tmp/open-grok-macos",
                sidecarPath: "/tmp/open-grok-macos.sha256"
            )
        ])
        #expect(CLICommandParser.parse([
            "release-validate",
            "--binary", "/tmp/open-grok",
            "--expected-version", version,
            "--isolated-root", root,
            "--artifact", "open-grok-macos=/tmp/open-grok-macos"
        ]) == .invalid(.requiresOption("--artifact", "--sidecar")))
    }

    @Test("a matching binary and contained paths pass through the shipped async runner")
    func matchingSmokePassesAndSkipsChecksums() async {
        let calls = ReleaseValidationCallLog()
        let dependencies = makeDependencies(calls: calls)
        let (streams, _, errors) = CLIStreams.buffered()

        let exit = await CLIRunner.run(
            [
                "release-validate",
                "--binary", "/tmp/open-grok",
                "--expected-version", version,
                "--expected-commit", commit,
                "--isolated-root", root,
            ],
            environment: [:],
            streams: streams,
            releaseValidationDependencies: dependencies
        )

        #expect(exit == 0)
        #expect(calls.processArguments == [["--version"], ["paths", "--json"]])
        #expect(calls.checksumCalls == 0)
        #expect(errors.contents.contains("smoke.versionMatches"))
        #expect(errors.contents.contains("smoke.pathsBinaryContained"))
    }

    @Test("version, commit, malformed paths, escaped paths, and process failures block")
    func smokeFailuresRenderFindings() async {
        let cases: [(String, @Sendable (String, [String], [String: String]) throws -> ReleaseValidationProcessOutput, String)] = [
            (
                "wrong version and missing commit",
                { _, arguments, _ in
                    if arguments == ["--version"] {
                        return ReleaseValidationProcessOutput(
                            exitStatus: 0,
                            stdout: "Open Grok 0.1.220-open-grok.53\n",
                            stderr: ""
                        )
                    }
                    return ReleaseValidationProcessOutput(
                        exitStatus: 0,
                        stdout: "{\"opengrok_home\":\"/tmp/open-grok-release-smoke\",\"managed_binary\":\"/tmp/open-grok-release-smoke/bin/open-grok\",\"project_state\":\".opengrok\"}",
                        stderr: ""
                    )
                },
                "smoke.versionMismatch"
            ),
            (
                "malformed paths",
                { _, arguments, _ in
                    if arguments == ["--version"] {
                        return ReleaseValidationProcessOutput(
                            exitStatus: 0,
                            stdout: "Open Grok 0.1.220-open-grok.58 (abc1234)\n",
                            stderr: ""
                        )
                    }
                    return ReleaseValidationProcessOutput(exitStatus: 0, stdout: "not-json", stderr: "")
                },
                "smoke.pathsMalformed"
            ),
            (
                "escaped paths",
                { _, arguments, _ in
                    if arguments == ["--version"] {
                        return ReleaseValidationProcessOutput(
                            exitStatus: 0,
                            stdout: "Open Grok 0.1.220-open-grok.58 (abc1234)\n",
                            stderr: ""
                        )
                    }
                    return ReleaseValidationProcessOutput(
                        exitStatus: 0,
                        stdout: "{\"opengrok_home\":\"/tmp/elsewhere\",\"managed_binary\":\"/tmp/elsewhere/open-grok\",\"project_state\":\".opengrok\"}",
                        stderr: ""
                    )
                },
                "smoke.pathsHomeEscaped"
            ),
            (
                "unreadable binary",
                { _, arguments, _ in
                    if arguments == ["--version"] {
                        throw ReleaseValidationTestError.unreadable
                    }
                    return ReleaseValidationProcessOutput(
                        exitStatus: 0,
                        stdout: "{\"opengrok_home\":\"/tmp/open-grok-release-smoke\",\"managed_binary\":\"/tmp/open-grok-release-smoke/bin/open-grok\",\"project_state\":\".opengrok\"}",
                        stderr: ""
                    )
                },
                "smoke.versionUnreadable"
            ),
        ]

        for (label, process, findingID) in cases {
            let dependencies = LiveReleaseValidationDependencies(
                runProcess: process,
                validateChecksum: { _, _, _ in ReleaseValidationReport() }
            )
            let (streams, _, errors) = CLIStreams.buffered()
            let exit = await CLIRunner.run(
                [
                    "release-validate",
                    "--binary", "/tmp/open-grok",
                    "--expected-version", version,
                    "--expected-commit", commit,
                    "--isolated-root", root,
                ],
                environment: [:],
                streams: streams,
                releaseValidationDependencies: dependencies
            )
            #expect(exit == 1, "\(label) must fail")
            #expect(errors.contents.contains(findingID), "\(label) must render \(findingID)")
        }
    }

    @Test("artifact mode merges a checksum mismatch and returns failure")
    func checksumMismatchBlocksArtifactMode() async throws {
        let calls = ReleaseValidationCallLog()
        let dependencies = LiveReleaseValidationDependencies(
            runProcess: makeDependencies(calls: calls).runProcess,
            validateChecksum: { artifactName, _, _ in
                calls.recordChecksum(artifactName)
                return ReleaseValidationReport(findings: [
                    ReleaseValidationFinding(
                        id: "checksum.mismatch",
                        severity: .failure,
                        subject: artifactName,
                        message: "sidecar does not match artifact"
                    )
                ])
            }
        )
        let (streams, _, errors) = CLIStreams.buffered()

        let exit = await CLIRunner.run(
            [
                "release-validate",
                "--binary", "/tmp/open-grok",
                "--expected-version", version,
                "--expected-commit", commit,
                "--isolated-root", root,
                "--artifact", "open-grok-macos=/tmp/open-grok-macos",
                "--sidecar", "/tmp/open-grok-macos.sha256",
            ],
            environment: [:],
            streams: streams,
            releaseValidationDependencies: dependencies
        )

        #expect(exit == 1)
        #expect(calls.checksumCalls == 1)
        #expect(errors.contents.contains("checksum.mismatch"))
    }

    private func makeDependencies(calls: ReleaseValidationCallLog) -> LiveReleaseValidationDependencies {
        let expectedVersion = version
        let expectedCommit = commit
        let isolatedRoot = root
        return LiveReleaseValidationDependencies(
            runProcess: { _, arguments, _ in
                calls.recordProcess(arguments)
                if arguments == ["--version"] {
                    return ReleaseValidationProcessOutput(
                        exitStatus: 0,
                        stdout: "Open Grok \(expectedVersion) (\(expectedCommit))\n",
                        stderr: ""
                    )
                }
                return ReleaseValidationProcessOutput(
                    exitStatus: 0,
                    stdout: "{\"opengrok_home\":\"\(isolatedRoot)\",\"managed_binary\":\"\(isolatedRoot)/bin/open-grok\",\"project_state\":\".opengrok\"}",
                    stderr: ""
                )
            },
            validateChecksum: { artifactName, _, _ in
                calls.recordChecksum(artifactName)
                return ReleaseValidationReport()
            }
        )
    }
}

private final class ReleaseValidationCallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedProcessArguments: [[String]] = []
    private var recordedChecksumCalls = 0

    var processArguments: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recordedProcessArguments
    }

    var checksumCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedChecksumCalls
    }

    func recordProcess(_ arguments: [String]) {
        lock.lock()
        recordedProcessArguments.append(arguments)
        lock.unlock()
    }

    func recordChecksum(_ artifactName: String) {
        lock.lock()
        recordedChecksumCalls += 1
        lock.unlock()
    }
}

private enum ReleaseValidationTestError: Error, Sendable {
    case unreadable
}
