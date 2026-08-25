import Foundation
import Testing
@testable import OpenGrokAuth

#if os(Windows)
@Suite("Windows external auth provider subprocess parity")
struct WindowsExternalAuthParityTests {
    @Test("command-string providers execute through the native Windows command interpreter")
    func commandStringUsesWindowsShell() throws {
        let execution = try #require(
            DefaultExternalAuthProcessRunner().run(
                command: "echo windows-provider-token",
                args: nil,
                cwd: nil,
                timeout: 10,
                refreshToken: nil
            )
        )

        #expect(execution.exitCode == 0)
        #expect(execution.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            == "windows-provider-token")
    }

    @Test("a missing ComSpec resolves the trusted System32 command interpreter")
    func missingComSpecFallsBackToSystemRoot() throws {
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys)
            where key.caseInsensitiveCompare("ComSpec") == .orderedSame {
            environment.removeValue(forKey: key)
        }
        let execution = try #require(
            DefaultExternalAuthProcessRunner(environment: environment).run(
                command: "echo fallback-provider-token",
                args: nil,
                cwd: nil,
                timeout: 10,
                refreshToken: nil
            )
        )

        #expect(execution.exitCode == 0)
        #expect(execution.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            == "fallback-provider-token")
    }

    @Test("explicit executable arguments bypass the Windows command-string wrapper")
    func explicitArgumentsRemainDirect() throws {
        let commandInterpreter = try #require(commandInterpreter())
        let execution = try #require(
            DefaultExternalAuthProcessRunner().run(
                command: commandInterpreter,
                args: ["/C", "echo direct-provider-token"],
                cwd: nil,
                timeout: 10,
                refreshToken: nil
            )
        )

        #expect(execution.exitCode == 0)
        #expect(execution.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            == "direct-provider-token")
    }

    @Test("native command failures preserve their real exit status")
    func failedCommandPreservesExitStatus() throws {
        let execution = try #require(
            DefaultExternalAuthProcessRunner().run(
                command: "exit /b 37",
                args: nil,
                cwd: nil,
                timeout: 10,
                refreshToken: nil
            )
        )

        #expect(execution.exitCode == 37)
    }

    @Test("Windows helpers receive only their own provider refresh credentials")
    func helperEnvironmentScrubsHostCredentials() throws {
        var environment = ProcessInfo.processInfo.environment
        environment["XAI_API_KEY"] = "must-not-reach-provider"
        environment["CUSTOM_PROVIDER_SETTING"] = "provider-preserved"
        let execution = try #require(
            DefaultExternalAuthProcessRunner(environment: environment).run(
                command: "if defined XAI_API_KEY (exit /b 86) else"
                    + " (echo %CUSTOM_PROVIDER_SETTING%:%GROK_AUTH_PROVIDER_REFRESH_TOKEN%)",
                args: nil,
                cwd: nil,
                timeout: 10,
                refreshToken: "provider-refresh"
            )
        )

        #expect(execution.exitCode == 0)
        #expect(execution.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            == "provider-preserved:provider-refresh")
    }

    @Test("Windows providers launch in their configured working directory")
    func helperHonorsWorkingDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-windows-auth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let execution = try #require(
            DefaultExternalAuthProcessRunner().run(
                command: "cd",
                args: nil,
                cwd: directory.path,
                timeout: 10,
                refreshToken: nil
            )
        )

        #expect(execution.exitCode == 0)
        #expect(execution.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(directory.path) == .orderedSame)
    }

    @Test("timed-out direct Windows helpers are terminated within their bounded budget")
    func timeoutTerminatesDirectProviderProcess() throws {
        let commandInterpreter = try #require(commandInterpreter())
        let powershell = URL(fileURLWithPath: commandInterpreter)
            .deletingLastPathComponent()
            .appendingPathComponent("WindowsPowerShell", isDirectory: true)
            .appendingPathComponent("v1.0", isDirectory: true)
            .appendingPathComponent("powershell.exe", isDirectory: false)
            .path
        let started = Date()
        let execution = DefaultExternalAuthProcessRunner().run(
            command: powershell,
            args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep -Seconds 30"],
            cwd: nil,
            timeout: 0.25,
            refreshToken: nil
        )

        #expect(execution == nil)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    private func commandInterpreter() -> String? {
        ProcessInfo.processInfo.environment.first(where: {
            $0.key.caseInsensitiveCompare("ComSpec") == .orderedSame && !$0.value.isEmpty
        })?.value
    }
}
#endif
