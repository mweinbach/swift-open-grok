// CLIRunner.swift
//
// The testable CLI entry point. `main` returns a deterministic exit code and
// writes only requested output to `streams.out`, with diagnostics to
// `streams.err` — matching the W10-S2 acceptance that stdout contains only
// requested machine/user output while diagnostics use stderr.

import Foundation

public enum CLIRunner {
    /// Exit codes used by the bootstrap CLI.
    public enum ExitCode: Int32, Sendable {
        case success = 0
        case usage = 2
        case notImplemented = 3
    }

    /// Execute the bootstrap CLI against `args` (arguments after the program
    /// name), `environment`, and `streams`. Returns the process exit code.
    @discardableResult
    public static func main(
        _ args: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        streams: CLIStreams
    ) -> Int32 {
        let command = CLICommandParser.parse(args)
        switch command {
        case .version:
            streams.out("Open Grok \(OpenGrokCLIVersion.installed(environment: environment))\n")
            return ExitCode.success.rawValue
        case .help:
            streams.out(OpenGrokHelp.text)
            return ExitCode.success.rawValue
        case .paths:
            let home = OpenGrokHomeResolver.resolve(environment: environment)
            let managed = OpenGrokHomeResolver.managedBinaryURL(environment: environment)
            streams.out("OPENGROK_HOME: \(home.path)\n")
            streams.out("managed binary: \(managed.path)\n")
            streams.out("project state: .opengrok\n")
            return ExitCode.success.rawValue
        case .notYetImplemented(let name):
            streams.err("open-grok: '\(name)' is part of the Open Grok CLI but is not yet implemented in the bootstrap build.\n")
            streams.err("It will be provided by the W10-S2 CLI target.\n")
            return ExitCode.notImplemented.rawValue
        case .unknown(let token):
            streams.err("open-grok: unknown command or flag '\(token)'.\n")
            streams.err("Run 'open-grok help' for usage.\n")
            return ExitCode.usage.rawValue
        }
    }
}
