import Foundation
import OpenGrokTTY
import Testing

@testable import OpenGrokCLI

@Suite("Windows interactive wrap terminal parity")
struct WindowsWrapParityTests {
    @Test("Live wrapping requires stdin, stdout, and stderr to all be real terminals")
    func wrappingRequiresEveryTerminalHandle() {
        let (streams, _, _) = CLIStreams.buffered()
        let dependencies = LiveWrapExecutionDependencies.live(
            environment: ProcessInfo.processInfo.environment,
            streams: streams
        )
        let allHandlesAreTerminals = PlatformTTYAdapter(fd: 0).isATTY()
            && PlatformTTYAdapter(fd: 1).isATTY()
            && PlatformTTYAdapter(fd: 2).isATTY()

        #expect(dependencies.interactive() == allHandlesAreTerminals)
    }

    #if os(Windows)
    @Test("Windows wrap never routes unresolved commands through a POSIX shell")
    func windowsLaunchRetainsExactDirectArguments() {
        let command = ["missing-command", "two words", #"C:\Program Files\"#]
        let plan = LiveWrapComposition.deriveSpawn(
            command: command,
            shell: "/bin/sh",
            executableAvailable: false,
            mode: .interactive
        )

        #expect(plan.executable == command[0])
        #expect(plan.arguments == Array(command.dropFirst()))
    }
    #endif
}
