import Foundation
import OpenGrokReleaseValidation

public struct ReleaseValidationProcessOutput: Sendable, Equatable {
    public let exitStatus: Int32
    public let stdout: String
    public let stderr: String

    public init(exitStatus: Int32, stdout: String, stderr: String) {
        self.exitStatus = exitStatus
        self.stdout = stdout
        self.stderr = stderr
    }
}

public struct LiveReleaseValidationDependencies: Sendable {
    public var runProcess: @Sendable (
        _ executable: String,
        _ arguments: [String],
        _ environment: [String: String]
    ) throws -> ReleaseValidationProcessOutput
    public var validateChecksum: @Sendable (
        _ artifactName: String,
        _ artifact: URL,
        _ sidecar: URL
    ) -> ReleaseValidationReport

    public init(
        runProcess: @escaping @Sendable (
            _ executable: String,
            _ arguments: [String],
            _ environment: [String: String]
        ) throws -> ReleaseValidationProcessOutput,
        validateChecksum: @escaping @Sendable (
            _ artifactName: String,
            _ artifact: URL,
            _ sidecar: URL
        ) -> ReleaseValidationReport
    ) {
        self.runProcess = runProcess
        self.validateChecksum = validateChecksum
    }

    public static var live: Self {
        Self(
            runProcess: LiveReleaseValidationProcess.run,
            validateChecksum: { artifactName, artifact, sidecar in
                ChecksumValidation.validate(
                    artifactName: artifactName,
                    at: artifact,
                    sidecar: sidecar
                )
            }
        )
    }
}

public enum LiveReleaseValidation {
    public static func run(
        options: CLIReleaseValidationOptions,
        environment: [String: String],
        streams: CLIStreams,
        dependencies: LiveReleaseValidationDependencies = .live
    ) -> Int32 {
        var report = ReleaseValidationReport()
        var childEnvironment = environment
        childEnvironment["OPENGROK_HOME"] = options.isolatedRoot
        childEnvironment["HOME"] = options.isolatedRoot
        childEnvironment["OPEN_GROK_BIN_DIR"] = URL(
            fileURLWithPath: options.isolatedRoot
        ).appendingPathComponent("bin", isDirectory: true).path

        do {
            let version = try dependencies.runProcess(
                options.binaryPath,
                ["--version"],
                childEnvironment
            )
            if version.exitStatus != 0 {
                report.record(ReleaseValidationFinding(
                    id: "smoke.versionProcessFailed",
                    severity: .failure,
                    subject: "--version",
                    message: "binary exited with status \(version.exitStatus): \(version.stderr)"
                ))
            }
            report.merge(
                SmokeValidation.validateVersionOutput(
                    version.stdout.isEmpty ? version.stderr : version.stdout,
                    expectedVersion: options.expectedVersion,
                    expectedShortCommit: options.expectedShortCommit
                )
            )
        } catch {
            report.record(ReleaseValidationFinding(
                id: "smoke.versionUnreadable",
                severity: .failure,
                subject: "--version",
                message: "could not execute binary: \(error)"
            ))
        }

        do {
            let paths = try dependencies.runProcess(
                options.binaryPath,
                ["paths", "--json"],
                childEnvironment
            )
            if paths.exitStatus != 0 {
                report.record(ReleaseValidationFinding(
                    id: "smoke.pathsProcessFailed",
                    severity: .failure,
                    subject: "paths --json",
                    message: "binary exited with status \(paths.exitStatus): \(paths.stderr)"
                ))
            } else if let data = paths.stdout.data(using: .utf8),
                      let resolved = try? JSONDecoder().decode(SmokeResolvedPaths.self, from: data) {
                report.merge(
                    SmokeValidation.validateResolvedPaths(
                        resolved,
                        isolatedRoot: options.isolatedRoot
                    )
                )
            } else {
                report.record(ReleaseValidationFinding(
                    id: "smoke.pathsMalformed",
                    severity: .failure,
                    subject: "paths --json",
                    message: "output was not a valid resolved-paths JSON object: \(paths.stdout)"
                ))
            }
        } catch {
            report.record(ReleaseValidationFinding(
                id: "smoke.pathsUnreadable",
                severity: .failure,
                subject: "paths --json",
                message: "could not execute binary: \(error)"
            ))
        }

        for artifact in options.artifacts {
            report.merge(
                dependencies.validateChecksum(
                    artifact.name,
                    URL(fileURLWithPath: artifact.artifactPath),
                    URL(fileURLWithPath: artifact.sidecarPath)
                )
            )
        }

        let passed = report.passed
        if !report.findings.isEmpty {
            streams.err(report.render() + "\n")
        }
        return passed ? 0 : 1
    }
}

private enum LiveReleaseValidationProcess {
    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> ReleaseValidationProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            terminated.signal()
        }
        try process.run()
        terminated.wait()

        let stdout = String(
            decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        let stderr = String(
            decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        return ReleaseValidationProcessOutput(
            exitStatus: process.terminationStatus,
            stdout: stdout,
            stderr: stderr
        )
    }
}
