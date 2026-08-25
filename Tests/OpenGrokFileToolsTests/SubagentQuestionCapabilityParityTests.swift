import Foundation
import OpenGrokShared
import OpenGrokToolRegistry
import OpenGrokToolRuntime
import OpenGrokWorkspaceTypes
import Testing

@testable import OpenGrokFileTools

private actor ScopedQuestionCapabilityProbe: ScopedUserQuestionPresenting {
    let expectedSessionID: String
    let expectedAuthorizationSessionID: String
    let expectedAgentID: String
    let available: Bool
    private(set) var authorizationCalls = 0
    private(set) var presentationCalls = 0

    init(
        expectedSessionID: String = "authenticated-child",
        expectedAuthorizationSessionID: String = "authenticated-root",
        expectedAgentID: String = "main",
        available: Bool = true
    ) {
        self.expectedSessionID = expectedSessionID
        self.expectedAuthorizationSessionID = expectedAuthorizationSessionID
        self.expectedAgentID = expectedAgentID
        self.available = available
    }

    var canPresent: Bool { available }

    func authorizeQuestion(
        sessionID: String,
        authorizationSessionID: String,
        agentID: String,
        toolCallID: String
    ) -> Bool {
        authorizationCalls += 1
        return sessionID == expectedSessionID
            && authorizationSessionID == expectedAuthorizationSessionID
            && agentID == expectedAgentID
            && !toolCallID.isEmpty
    }

    func ask(
        questions: [UserQuestion],
        toolCallID: String
    ) -> UserQuestionPromptOutcome {
        presentationCalls += 1
        return .answered([
            AnsweredUserQuestion(question: questions[0].question, label: "Yes")
        ])
    }
}

@Suite("Scoped subagent question capability")
struct SubagentQuestionCapabilityParityTests {
    private var arguments: JSONValue {
        .object([
            "questions": .array([
                .object([
                    "question": .string("Proceed?"),
                    "options": .array([
                        .object(["label": .string("Yes")])
                    ]),
                ])
            ])
        ])
    }

    private func resources(
        sessionID: String,
        authorizationSessionID: String = "authenticated-root",
        agentID: String = "main",
        presenter: (any UserQuestionPresenting)?
    ) -> ToolResources {
        let resources = ToolResources(
            cwd: FileManager.default.temporaryDirectory.path,
            sessionId: sessionID,
            agentId: agentID,
            authorizationScope: ToolResourceAuthorizationScope(
                authorizationSessionID: authorizationSessionID,
                allowedRoots: []
            )
        )
        resources.userQuestions = presenter
        return resources
    }

    @Test("an authenticated child receives the real user's answer")
    func matchingIdentityPresents() async {
        let presenter = ScopedQuestionCapabilityProbe()
        let result = await AskUserQuestionToolHandler().invoke(
            clientName: "ask_user_question",
            args: arguments,
            ctx: ToolCallContext(),
            resources: resources(sessionID: "authenticated-child", presenter: presenter)
        )
        guard case .success(let output) = result else {
            Issue.record("expected authenticated answer, got \(result)")
            return
        }
        guard case .object(let object) = output.value,
              case .string(let status)? = object["status"]
        else {
            Issue.record("question output did not carry an answered status")
            return
        }
        #expect(status == "answered")
        #expect(await presenter.authorizationCalls == 1)
        #expect(await presenter.presentationCalls == 1)
    }

    @Test("another child cannot reuse an authenticated presenter's capability")
    func mismatchedSessionFailsBeforePresentation() async {
        let presenter = ScopedQuestionCapabilityProbe()
        let result = await AskUserQuestionToolHandler().invoke(
            clientName: "ask_user_question",
            args: arguments,
            ctx: ToolCallContext(),
            resources: resources(sessionID: "different-child", presenter: presenter)
        )
        guard case .failure(let error) = result else {
            Issue.record("expected unauthorized session, got \(result)")
            return
        }
        #expect(error.kind == .unauthorized)
        #expect(await presenter.presentationCalls == 0)
    }

    @Test("another agent within the session cannot impersonate the child owner")
    func mismatchedAgentFailsBeforePresentation() async {
        let presenter = ScopedQuestionCapabilityProbe()
        let result = await AskUserQuestionToolHandler().invoke(
            clientName: "ask_user_question",
            args: arguments,
            ctx: ToolCallContext(),
            resources: resources(
                sessionID: "authenticated-child",
                agentID: "different-agent",
                presenter: presenter
            )
        )
        guard case .failure(let error) = result else {
            Issue.record("expected unauthorized agent, got \(result)")
            return
        }
        #expect(error.kind == .unauthorized)
        #expect(await presenter.presentationCalls == 0)
    }

    @Test("a matching mutable child identity cannot cross an immutable root-session boundary")
    func mismatchedRootFailsBeforePresentation() async {
        let presenter = ScopedQuestionCapabilityProbe()
        let result = await AskUserQuestionToolHandler().invoke(
            clientName: "ask_user_question",
            args: arguments,
            ctx: ToolCallContext(),
            resources: resources(
                sessionID: "authenticated-child",
                authorizationSessionID: "different-root",
                presenter: presenter
            )
        )
        guard case .failure(let error) = result else {
            Issue.record("expected unauthorized root owner, got \(result)")
            return
        }
        #expect(error.kind == .unauthorized)
        #expect(await presenter.presentationCalls == 0)
    }

    @Test("a headless capability never fabricates a cancellation or answer")
    func unavailablePresenterFailsClosed() async {
        let presenter = ScopedQuestionCapabilityProbe(available: false)
        let result = await AskUserQuestionToolHandler().invoke(
            clientName: "ask_user_question",
            args: arguments,
            ctx: ToolCallContext(),
            resources: resources(sessionID: "authenticated-child", presenter: presenter)
        )
        guard case .failure(let error) = result else {
            Issue.record("expected unavailable surface, got \(result)")
            return
        }
        #expect(error.kind == .custom)
        #expect(await presenter.authorizationCalls == 0)
        #expect(await presenter.presentationCalls == 0)
    }
}
