import Foundation
import OpenGrokAgentDefinitions
import OpenGrokPager
import OpenGrokPagerCommandUI
import Testing
@testable import OpenGrokCLI

@Suite("live skills reachability")
struct LiveSkillsReachabilityTests {
    @Test("the shared catalog protects builtins and advertises skill metadata")
    func catalogFeedsTUIAndACP() {
        let skills = [
            SkillInfo(
                name: "help",
                description: "Project help",
                shortDescription: "Project help",
                argumentHint: "<topic>",
                path: "/tmp/project/SKILL.md",
                scope: .local
            ),
            SkillInfo(
                name: "deploy",
                description: "Deploy the application",
                argumentHint: "<environment>",
                path: "/tmp/project/deploy/SKILL.md",
                scope: .local
            )
        ]
        let catalog = LiveSkills.commandCatalog(
            skills: skills,
            reservedNames: OpenGrokPagerInteractiveController.builtinCommandNames
        )

        #expect(catalog.map(\.commandName) == ["local:help", "deploy"])
        let rows = LiveSkills.availableCommands(
            builtins: OpenGrokPagerInteractiveController.builtinCommandCatalog,
            skills: catalog
        )
        let row = rows.first { $0.name == "deploy" }
        #expect(row?.description == "Deploy the application")
        #expect(row?.meta?["scope"] == .string("local"))
        #expect(row?.meta?["path"] == .string("/tmp/project/deploy/SKILL.md"))
    }

    @Test("a registered skill resolves through the pager command registry")
    func registryResolvesSkillSlash() {
        let skill = SkillInfo(
            name: "deploy",
            description: "Deploy the application",
            argumentHint: "<environment>",
            path: "/tmp/project/deploy/SKILL.md",
            scope: .local,
            body: "Deploy to $ARGUMENTS for session ${SESSION_ID}."
        )
        let catalog = LiveSkills.commandCatalog(skills: [skill])
        let registration = OpenGrokPagerCommandRegistration(
            name: catalog[0].commandName,
            summary: catalog[0].skill.description,
            usage: catalog[0].skill.argumentHint
        )
        let registry = PagerCommandRegistry(commands: [
            PagerCommandDefinition(name: "help"),
            PagerCommandDefinition(
                name: registration.name,
                summary: registration.summary,
                usage: registration.usage
            )
        ])

        let resolution = registry.resolve(PagerCommandInvocation(
            name: "deploy",
            arguments: ["staging"]
        ))
        guard case .available(let command) = resolution else {
            Issue.record("the registered skill was not resolvable")
            return
        }
        #expect(command.name == "deploy")
        let prompt = LiveSkills.invocationPrompt(
            commandName: command.name,
            args: "staging",
            catalog: catalog,
            sessionID: "session-1"
        )
        #expect(prompt?.contains("<skill_information>") == true)
        #expect(prompt?.contains("<skill name=\"deploy\" args=\"staging\">") == true)
        #expect(prompt?.contains("Deploy to staging for session session-1.") == true)
    }

    @Test("model listing keeps non-user-invocable skills while honoring model gating")
    func listingUsesModelGateOnly() {
        let slashOnly = SkillInfo(
            name: "slash-only",
            description: "Slash only",
            path: "/tmp/slash-only/SKILL.md",
            scope: .user,
            userInvocable: true,
            disableModelInvocation: true
        )
        let modelOnly = SkillInfo(
            name: "model-only",
            description: "Model only",
            path: "/tmp/model-only/SKILL.md",
            scope: .user,
            userInvocable: false
        )

        #expect(LiveSkills.commandCatalog(skills: [slashOnly, modelOnly]).map(\.commandName) == ["slash-only"])
        let listing = LiveSkills.listing([slashOnly, modelOnly])
        #expect(listing?.contains("model-only") == true)
        #expect(listing?.contains("slash-only") == false)
    }
}
