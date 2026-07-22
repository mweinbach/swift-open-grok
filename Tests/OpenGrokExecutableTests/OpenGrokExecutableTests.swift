// OpenGrokExecutableTests.swift
//
// Composition-level coverage for the `open-grok` product entry path.
// The executable target itself is not importable from tests; these suites
// exercise the same `CLIRunner.main` surface that `Sources/OpenGrokExecutable/main.swift`
// wires to process argv/stdio.

import Foundation
import Testing
@testable import OpenGrokCLI

@Suite("OpenGrokExecutable composition")
struct OpenGrokExecutableTests {
    @Test("version path uses canonical OpenGrokVersion semantics via CLI")
    func versionUsesCanonicalSemantics() {
        let (streams, out, err) = CLIStreams.buffered()
        let code = CLIRunner.main(["--version"], environment: [:], streams: streams)
        #expect(code == 0)
        #expect(out.contents.contains("Open Grok \(OpenGrokCLIVersion.compiled)"))
        #expect(err.contents.isEmpty)
        #expect(!OpenGrokCLIVersion.compiled.isEmpty)
    }

    @Test("empty GROK_TEST_VERSION override is honored (Rust parity)")
    func emptyTestVersionOverride() {
        let env = ["GROK_TEST_VERSION": ""]
        #expect(OpenGrokCLIVersion.installed(environment: env) == "")
        let (streams, out, _) = CLIStreams.buffered()
        let code = CLIRunner.main(["version"], environment: env, streams: streams)
        #expect(code == 0)
        // Empty override prints "Open Grok " with no compiled version token.
        #expect(out.contents.hasPrefix("Open Grok "))
        #expect(!out.contents.contains(OpenGrokCLIVersion.compiled))
    }

    @Test("help is available and exits 0")
    func helpSmoke() {
        let (streams, out, err) = CLIStreams.buffered()
        let code = CLIRunner.main(["help"], environment: [:], streams: streams)
        #expect(code == 0)
        #expect(out.contents.contains("Open Grok") || out.contents.lowercased().contains("usage"))
        #expect(err.contents.isEmpty)
    }

    @Test("paths respects OPENGROK_HOME isolation")
    func pathsSmoke() {
        let env = ["OPENGROK_HOME": "/tmp/og-exec-test-home", "HOME": "/tmp/should-not-use"]
        let (streams, out, err) = CLIStreams.buffered()
        let code = CLIRunner.main(["paths"], environment: env, streams: streams)
        #expect(code == 0)
        #expect(out.contents.contains("OPENGROK_HOME: /tmp/og-exec-test-home"))
        #expect(out.contents.contains(".opengrok"))
        #expect(!out.contents.contains("/.grok\n"))
        #expect(err.contents.isEmpty)
    }

    @Test("unimplemented product commands stay explicitly unavailable")
    func unimplementedCommands() {
        for name in ["login", "session", "acp", "models", "resume"] {
            let (streams, out, err) = CLIStreams.buffered()
            let code = CLIRunner.main([name], environment: [:], streams: streams)
            #expect(
                code == CLIRunner.ExitCode.notImplemented.rawValue
                    || code == CLIRunner.ExitCode.usage.rawValue
            )
            #expect(out.contents.isEmpty)
            #expect(
                err.contents.contains("not yet implemented")
                    || err.contents.contains("unknown command")
            )
        }
    }
}
