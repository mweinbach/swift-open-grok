import Testing
@testable import OpenGrokCLI

@Suite("persistent agent relay command-line parity")
struct AgentRelayCommandLineParityTests {
    @Test("bare agent and explicit agent headless select the same persistent relay")
    func bareAndExplicitRelayModes() throws {
        for arguments in [["agent"], ["agent", "headless"]] {
            guard case .launch(let options) = try CLICommandParser.parseOrThrow(arguments) else {
                Issue.record("agent relay did not produce a launch command")
                continue
            }
            #expect(options.mode == .headless)
            #expect(options.agentRelay == CLIAgentRelayOptions())
            #expect(options.prompt == nil)
        }
    }

    @Test("agent parent flags are consumed before the headless mode word")
    func parentOptionsBeforeRelayMode() throws {
        let command = try CLICommandParser.parseOrThrow([
            "agent", "--cwd", "headless", "--reauth", "headless",
        ])
        guard case .launch(let options) = command else {
            Issue.record("agent relay did not produce a launch command")
            return
        }
        #expect(options.mode == .headless)
        #expect(options.agentRelay != nil)
        #expect(options.common.cwd == "headless")
        #expect(options.advanced.reauthenticate)
    }

    @Test("explicit relay URL and origin remain distinct and support inline values")
    func relayEndpointOptions() throws {
        let command = try CLICommandParser.parseOrThrow([
            "agent", "--grok-ws-url=wss://relay.example/agent",
            "headless", "--grok-ws-origin", "https://grok.com",
        ])
        guard case .launch(let options) = command else {
            Issue.record("agent relay did not produce a launch command")
            return
        }
        #expect(options.agentRelay?.grokWSURL == "wss://relay.example/agent")
        #expect(options.agentRelay?.grokWSOrigin == "https://grok.com")
    }

    @Test("root one-shot headless and agent stdio never acquire relay authority")
    func existingTransportModesRemainSeparate() throws {
        for arguments in [["headless", "--prompt", "hello"], ["agent", "stdio"]] {
            guard case .launch(let options) = try CLICommandParser.parseOrThrow(arguments) else {
                Issue.record("existing transport did not produce a launch command")
                continue
            }
            #expect(options.agentRelay == nil)
        }
    }

    @Test("repeated relay mode and unknown positional words are rejected")
    func malformedRelayModesFailClosed() {
        for arguments in [["agent", "headless", "headless"], ["agent", "unknown"]] {
            guard case .invalid = CLICommandParser.parse(arguments) else {
                Issue.record("invalid agent relay invocation was accepted: \(arguments)")
                continue
            }
        }
    }

    @Test("agent help describes a persistent authenticated relay")
    func helpDescribesActualRelay() throws {
        let help = try #require(OpenGrokHelp.topic("agent"))
        #expect(help.contains("Persistent authenticated xAI WebSocket agent relay"))
        #expect(help.contains("--reauth"))
        #expect(!help.contains("One-shot run"))
    }
}
