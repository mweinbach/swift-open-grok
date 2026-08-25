import Foundation
import OpenGrokConfig
import Testing
@testable import OpenGrokAuth

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if canImport(Darwin) || canImport(Glibc)
private final class ExternalAuthSingleFlightProbeRunner: ExternalAuthProcessRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var invocationCount = 0

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return invocationCount
    }

    func run(
        command: String,
        args: [String]?,
        cwd: String?,
        timeout: TimeInterval,
        refreshToken: String?
    ) -> ExternalAuthExecution? {
        lock.lock()
        invocationCount += 1
        lock.unlock()
        usleep(200_000)
        return ExternalAuthExecution(
            stdout: #"{"access_token":"shared-token","expires_in":120}"#,
            exitCode: 0
        )
    }
}

private final class ExternalAuthConcurrentResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String?] = []

    func append(_ value: String?) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var snapshot: [String?] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

@Suite("External auth provider subprocess security parity")
struct ExternalAuthSecurityParityTests {
    private let auditedCredentialKeys = [
        "XAI_API_KEY",
        "XAI_ACCESS_TOKEN",
        "XAI_REFRESH_TOKEN",
        "XAI_AUTH",
        "GROK_CODE_XAI_API_KEY",
        "GROK_API_KEY",
        "GROK_AUTH",
        "GROK_AUTH_PATH",
        "GROK_AUTH_TOKEN",
        "GROK_ACCESS_TOKEN",
        "GROK_REFRESH_TOKEN",
        "GROK_DEPLOYMENT_KEY",
        "GROK_EXTRA_AUTH_KEY",
        "GROK_TRACE_UPLOAD_CREDENTIALS_FILE",
        "GROK_INTERNAL_OTLP_HEADERS",
        "GROK_OAUTH2_CLIENT_SECRET",
        "OTEL_EXPORTER_OTLP_HEADERS",
        "OTEL_EXPORTER_OTLP_TRACES_HEADERS",
        "OTEL_EXPORTER_OTLP_METRICS_HEADERS",
        "OTEL_EXPORTER_OTLP_LOGS_HEADERS",
        "OPENGROK_CODE_XAI_API_KEY",
        "OPENGROK_API_KEY",
        "OPENGROK_AUTH",
        "OPENGROK_AUTH_PATH",
        "OPENGROK_AUTH_TOKEN",
        "OPENGROK_ACCESS_TOKEN",
        "OPENGROK_REFRESH_TOKEN",
        "OPENGROK_DEPLOYMENT_KEY",
        "OPENGROK_EXTRA_AUTH_KEY",
        "OPENGROK_TRACE_UPLOAD_CREDENTIALS_FILE",
        "OPENGROK_INTERNAL_OTLP_HEADERS",
        "OPENGROK_OAUTH2_CLIENT_SECRET",
        "OPENAI_API_KEY",
        "OPENAI_ACCESS_TOKEN",
        "OPENAI_REFRESH_TOKEN",
        "CODEX_API_KEY",
        "CODEX_ACCESS_TOKEN",
        "CODEX_REFRESH_TOKEN",
        "CHATGPT_ACCESS_TOKEN",
        "CHATGPT_REFRESH_TOKEN",
        "GROK_AUTH_PROVIDER_ACCESS_TOKEN",
        "GROK_AUTH_PROVIDER_REFRESH_TOKEN",
        "GROK_AUTH_PROVIDER_EXPIRES_AT",
        "GROK_AUTH_REFRESH_TOKEN",
    ]

    @Test("real helper inherits no host credentials but retains provider-specific configuration")
    func helperEnvironmentScrubsIndependentlyAuditedCredentials() throws {
        #expect(
            DefaultExternalAuthProcessRunner.firstPartyCredentialEnvironmentKeys
                == Set(auditedCredentialKeys)
        )

        var environment = Dictionary(
            uniqueKeysWithValues: auditedCredentialKeys.map { ($0, "host-secret-\($0)") }
        )
        environment["PATH"] = "/usr/bin:/bin"
        environment["CUSTOM_PROVIDER_SETTING"] = "preserved"
        environment["MY_PROVIDER_API_KEY"] = "provider-specific"

        let deliberatelyHandedBack: Set<String> = [
            "GROK_AUTH_PROVIDER_REFRESH_TOKEN",
            "GROK_AUTH_REFRESH_TOKEN",
        ]
        let assertions = auditedCredentialKeys
            .filter { !deliberatelyHandedBack.contains($0) }
            .map { key in
                "if [ \"${\(key)+set}\" = set ]; then printf 'LEAK:\(key)'; exit 86; fi"
            }
            .joined(separator: "; ")
        let command = assertions
            + "; printf '%s|%s|%s|%s' \"$CUSTOM_PROVIDER_SETTING\" \"$MY_PROVIDER_API_KEY\""
            + " \"$GROK_AUTH_PROVIDER_REFRESH_TOKEN\" \"$GROK_AUTH_REFRESH_TOKEN\""

        let execution = try #require(
            DefaultExternalAuthProcessRunner(environment: environment).run(
                command: command,
                args: nil,
                cwd: nil,
                timeout: 5,
                refreshToken: "refresh-for-this-provider"
            )
        )

        #expect(execution.exitCode == 0)
        #expect(
            execution.stdout
                == "preserved|provider-specific|refresh-for-this-provider|refresh-for-this-provider"
        )
        #expect(!execution.stdout.contains("host-secret"))
    }

    @Test("initial mint strips stale refresh handback and expired markers")
    func initialMintCannotInheritAnotherProvidersRefreshToken() throws {
        let runner = DefaultExternalAuthProcessRunner(environment: [
            "PATH": "/usr/bin:/bin",
            "GROK_AUTH_EXPIRED": "inherited-expired",
            "GROK_AUTH_PROVIDER_REFRESH_TOKEN": "another-provider-refresh",
            "GROK_AUTH_REFRESH_TOKEN": "another-provider-legacy-refresh",
        ])
        let execution = try #require(
            runner.run(
                command: "printf '%s|%s|%s' \"${GROK_AUTH_EXPIRED-unset}\""
                    + " \"${GROK_AUTH_PROVIDER_REFRESH_TOKEN-unset}\""
                    + " \"${GROK_AUTH_REFRESH_TOKEN-unset}\"",
                args: nil,
                cwd: nil,
                timeout: 5,
                refreshToken: nil
            )
        )

        #expect(execution.exitCode == 0)
        #expect(execution.stdout == "unset|unset|unset")
    }

    @Test("credentials travel only through private pipe descriptors, never temporary files")
    func capturedTokensNeverLandOnDisk() throws {
        let directory = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let runner = DefaultExternalAuthProcessRunner(environment: [
            "PATH": "/usr/bin:/bin",
            "TMPDIR": directory.path,
        ])
        let execution = try #require(
            runner.run(
                command: "if [ -p /dev/fd/1 ] && [ -p /dev/fd/2 ]; then"
                    + " printf 'descriptor-private-bearer'; else exit 87; fi",
                args: nil,
                cwd: nil,
                timeout: 5,
                refreshToken: nil
            )
        )

        #expect(execution.exitCode == 0)
        #expect(execution.stdout == "descriptor-private-bearer")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test("stdout above the 1 MiB ceiling fails closed without returning bearer fragments")
    func oversizedOutputFailsVisiblyAndDoesNotPersist() throws {
        let directory = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let runner = DefaultExternalAuthProcessRunner(environment: [
            "PATH": "/usr/bin:/bin",
            "TMPDIR": directory.path,
        ])
        #expect(runner.maxOutputBytes == 1_048_576)

        let execution = try #require(
            runner.run(
                command: "head -c 1048577 /dev/zero",
                args: nil,
                cwd: nil,
                timeout: 5,
                refreshToken: nil
            )
        )

        #expect(execution.exitCode != 0)
        #expect(execution.stdout.isEmpty)
        #expect(execution.stderr == "external auth provider stdout exceeded 1048576 bytes")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)

        let resolver = NamedAuthProviderResolver(
            configuration: AuthProviderConfig(command: "head -c 1048577 /dev/zero"),
            runner: runner
        )
        #expect(resolver.currentToken() == nil)
    }

    @Test("stdout and stderr drain concurrently while stderr remains bounded to 64 KiB")
    func concurrentStderrFloodCannotDeadlockValidToken() throws {
        let execution = try #require(
            DefaultExternalAuthProcessRunner(environment: ["PATH": "/usr/bin:/bin"]).run(
                command: "head -c 131072 /dev/zero >&2 & writer=$!;"
                    + " printf 'valid-provider-token'; wait \"$writer\"",
                args: nil,
                cwd: nil,
                timeout: 5,
                refreshToken: nil
            )
        )

        #expect(execution.exitCode == 0)
        #expect(execution.stdout == "valid-provider-token")
        #expect(execution.stderr.utf8.count == 65_536)
        #expect(try parseExternalAuthOutput(stdout: execution.stdout, exitCode: execution.exitCode).key
            == "valid-provider-token")
    }

    @Test("timeout kills and reaps the helper's complete isolated process group")
    func timeoutKillsGrandchildrenThatIgnoreTermination() throws {
        let directory = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let descendantPIDFile = directory.appendingPathComponent("descendant.pid")
        let script = """
        (trap '' TERM; while :; do sleep 1; done) &
        printf '%s' "$!" > "$1"
        trap '' TERM
        while :; do sleep 1; done
        """

        let started = Date()
        let result = DefaultExternalAuthProcessRunner(environment: ["PATH": "/usr/bin:/bin"]).run(
            command: "/bin/sh",
            args: ["-c", script, "opengrok-auth-security", descendantPIDFile.path],
            cwd: nil,
            timeout: 0.4,
            refreshToken: "must-not-survive-in-a-grandchild"
        )

        #expect(result == nil)
        #expect(Date().timeIntervalSince(started) < 3)

        let rawPID = try String(contentsOf: descendantPIDFile, encoding: .utf8)
        let descendantPID = try #require(Int32(rawPID))
        var descendantWasReaped = false
        for _ in 0..<50 {
            if kill(descendantPID, 0) == -1 && errno == ESRCH {
                descendantWasReaped = true
                break
            }
            usleep(20_000)
        }
        #expect(descendantWasReaped)
    }

    @Test("one successful refresh broadcasts its cached token to every concurrent caller")
    func concurrentCallersCannotRemainParkedAfterSingleFlightRefresh() {
        let runner = ExternalAuthSingleFlightProbeRunner()
        let resolver = NamedAuthProviderResolver(
            configuration: AuthProviderConfig(command: "ignored"),
            runner: runner
        )
        let start = DispatchSemaphore(value: 0)
        let completed = DispatchGroup()
        let results = ExternalAuthConcurrentResults()

        for _ in 0..<4 {
            completed.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                start.wait()
                results.append(resolver.currentToken())
                completed.leave()
            }
        }
        for _ in 0..<4 {
            start.signal()
        }

        let finished = completed.wait(timeout: .now() + 3) == .success
        #expect(finished)
        if finished {
            #expect(results.snapshot.count == 4)
            #expect(results.snapshot.allSatisfy { $0 == "shared-token" })
            #expect(runner.calls == 1)
        }
    }

    private func makePrivateTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-external-auth-security-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }
}
#endif
