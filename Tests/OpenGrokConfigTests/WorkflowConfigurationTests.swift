import Testing
@testable import OpenGrokConfig
import OpenGrokConfigTypes

@Suite("Workflow configuration")
struct WorkflowConfigurationTests {
    @Test("workflows default to enabled")
    func defaultsToEnabled() throws {
        let document = try parseTOML("model = \"grok\"\n")
        #expect(resolveWorkflows(document: document, environment: [:]) == Resolved(value: true, source: .default))
    }

    @Test("local TOML can disable workflows")
    func localConfigDisables() throws {
        let document = try parseTOML("[workflows]\nenabled = false\n")
        #expect(resolveWorkflows(document: document, environment: [:]) == Resolved(value: false, source: .config))
    }

    @Test("GROK_WORKFLOWS=0 is a negative control")
    func environmentDisables() throws {
        let document = try parseTOML("[workflows]\nenabled = true\n")
        #expect(resolveWorkflows(document: document, environment: ["GROK_WORKFLOWS": "0"]) == Resolved(value: false, source: .env))
    }

    @Test("GROK_WORKFLOWS overrides local TOML")
    func environmentWins() throws {
        let document = try parseTOML("[workflows]\nenabled = false\n")
        #expect(resolveWorkflows(document: document, environment: ["GROK_WORKFLOWS": "1"]) == Resolved(value: true, source: .env))
    }

    @Test("remote rollout fields are not inputs to local resolution")
    func remoteFieldIsIgnored() throws {
        let document = try parseTOML("[remote]\nworkflows_enabled = false\n")
        #expect(resolveWorkflows(document: document, environment: [:]) == Resolved(value: true, source: .default))
    }
}
