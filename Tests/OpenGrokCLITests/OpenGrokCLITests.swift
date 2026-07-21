// OpenGrokCLITests.swift
//
// Target-scoped Swift Testing suites for the bootstrap OpenGrokCLI surface.

import Foundation
import Testing
@testable import OpenGrokCLI

@Suite("OpenGrokCLI")
struct OpenGrokCLITests {
    // MARK: - Version

    @Test("--version prints the Open Grok version on stdout and exits 0")
    func versionLongFlag() {
        let (streams, out, err) = CLIStreams.buffered()
        let code = CLIRunner.main(["--version"], environment: [:], streams: streams)
        #expect(code == 0)
        #expect(out.contents.contains("Open Grok"))
        #expect(out.contents.contains(OpenGrokCLIVersion.compiled))
        #expect(err.contents.isEmpty)
    }

    @Test("version subcommand behaves like --version")
    func versionSubcommand() {
        let (streams, out, _) = CLIStreams.buffered()
        let code = CLIRunner.main(["version"], environment: [:], streams: streams)
        #expect(code == 0)
        #expect(out.contents.contains(OpenGrokCLIVersion.compiled))
    }

    @Test("GROK_TEST_VERSION overrides the reported version")
    func versionOverride() {
        let (streams, out, _) = CLIStreams.buffered()
        let code = CLIRunner.main(["version"], environment: ["GROK_TEST_VERSION": "9.9.9-test"], streams: streams)
        #expect(code == 0)
        #expect(out.contents.contains("9.9.9-test"))
        #expect(!out.contents.contains(OpenGrokCLIVersion.compiled))
    }

    // MARK: - Help

    @Test("help prints usage on stdout and exits 0")
    func helpCommand() {
        let (streams, out, err) = CLIStreams.buffered()
        let code = CLIRunner.main(["help"], environment: [:], streams: streams)
        #expect(code == 0)
        #expect(out.contents.contains("USAGE") || out.contents.contains("usage"))
        #expect(out.contents.contains("OPENGROK_HOME"))
        #expect(err.contents.isEmpty)
    }

    @Test("no arguments prints help and exits 0")
    func noArgsPrintsHelp() {
        let (streams, out, _) = CLIStreams.buffered()
        let code = CLIRunner.main([], environment: [:], streams: streams)
        #expect(code == 0)
        #expect(out.contents.contains("Open Grok"))
    }

    // MARK: - Paths / OPENGROK_HOME isolation

    @Test("OPENGROK_HOME override wins over HOME")
    func opengrokHomeOverride() {
        let env = ["OPENGROK_HOME": "/tmp/og-home-xyz", "HOME": "/tmp/fake-home"]
        let home = OpenGrokHomeResolver.resolve(environment: env)
        #expect(home.path == "/tmp/og-home-xyz")
    }

    @Test("Fallback is ~/.opengrok when OPENGROK_HOME is unset")
    func fallbackHome() {
        let env = ["HOME": "/tmp/fake-home"]
        let home = OpenGrokHomeResolver.resolve(environment: env)
        #expect(home.path == "/tmp/fake-home/.opengrok")
    }

    @Test("The fallback is never ~/.grok")
    func neverLegacyGrok() {
        let env = ["HOME": "/tmp/fake-home"]
        let home = OpenGrokHomeResolver.resolve(environment: env)
        #expect(!OpenGrokHomeResolver.isLegacyGrokPath(home, environment: env))
        #expect(!home.path.hasSuffix("/.grok"))
        #expect(home.path.hasSuffix("/.opengrok"))
    }

    @Test("Empty OPENGROK_HOME falls back to ~/.opengrok")
    func emptyOverrideFallsBack() {
        let env = ["OPENGROK_HOME": "", "HOME": "/tmp/fake-home"]
        let home = OpenGrokHomeResolver.resolve(environment: env)
        #expect(home.path == "/tmp/fake-home/.opengrok")
    }

    @Test("USERPROFILE is used when HOME is absent")
    func userProfileFallback() {
        let env: [String: String] = ["USERPROFILE": "/tmp/profile-home"]
        let home = OpenGrokHomeResolver.userHomeDirectory(environment: env)
        #expect(home.path == "/tmp/profile-home")
    }

    @Test("paths command prints OPENGROK_HOME on stdout and exits 0")
    func pathsCommand() {
        let env = ["OPENGROK_HOME": "/tmp/og-paths-test", "HOME": "/tmp/fake-home"]
        let (streams, out, err) = CLIStreams.buffered()
        let code = CLIRunner.main(["paths"], environment: env, streams: streams)
        #expect(code == 0)
        #expect(out.contents.contains("OPENGROK_HOME: /tmp/og-paths-test"))
        #expect(out.contents.contains("managed binary: /tmp/og-paths-test/bin/open-grok"))
        #expect(out.contents.contains("project state: .opengrok"))
        #expect(err.contents.isEmpty)
    }

    // MARK: - Errors and not-yet-implemented commands

    @Test("Unknown command writes to stderr and exits 2")
    func unknownCommand() {
        let (streams, out, err) = CLIStreams.buffered()
        let code = CLIRunner.main(["frobnicate"], environment: [:], streams: streams)
        #expect(code == 2)
        #expect(out.contents.isEmpty)
        #expect(err.contents.contains("unknown command or flag"))
        #expect(err.contents.contains("frobnicate"))
    }

    @Test("Known W10-S2 commands report not-yet-implemented and exit 3")
    func notYetImplementedCommand() {
        let (streams, _, err) = CLIStreams.buffered()
        let code = CLIRunner.main(["sessions"], environment: [:], streams: streams)
        #expect(code == 3)
        #expect(err.contents.contains("sessions"))
        #expect(err.contents.contains("not yet implemented"))
    }

    // MARK: - Parser

    @Test("Parser maps flags and commands deterministically")
    func parserMapping() {
        #expect(CLICommandParser.parse(["--version"]) == .version)
        #expect(CLICommandParser.parse(["version"]) == .version)
        #expect(CLICommandParser.parse(["-h"]) == .help)
        #expect(CLICommandParser.parse(["help"]) == .help)
        #expect(CLICommandParser.parse(["paths"]) == .paths)
        #expect(CLICommandParser.parse(["login"]) == .notYetImplemented("login"))
        #expect(CLICommandParser.parse(["nope"]) == .unknown("nope"))
        #expect(CLICommandParser.parse([]) == .help)
    }
}
