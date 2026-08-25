import Foundation
import OpenGrokGoalState
import OpenGrokSessionPersistence
import OpenGrokShared
import Testing

@testable import OpenGrokCLI

private struct LiveGoalParityFixture {
    let root: URL
    let openGrokHome: URL
    let workingDirectory: URL

    init() throws {
        let manager = FileManager.default
        root = manager.temporaryDirectory.appendingPathComponent(
            "opengrok-goal-parity-\(UUID().uuidString)",
            isDirectory: true
        )
        openGrokHome = root.appendingPathComponent("state", isDirectory: true)
        workingDirectory = root.appendingPathComponent("workspace", isDirectory: true)
        for directory in [openGrokHome, workingDirectory] {
            try manager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    func services(sessionID: String = "goal-session") async -> LiveSessionServices {
        await OpenGrokLiveApplicationLauncher.makeSessionServices(
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            openGrokHome: openGrokHome,
            conversationRecord: .new(
                sessionID: sessionID,
                workingDirectory: workingDirectory
            ),
            environment: [
                "HOME": root.path,
                "OPENGROK_HOME": openGrokHome.path,
                "OPENGROK_REWIND": "0",
            ]
        )
    }

    func sessionDirectory(sessionID: String = "goal-session") throws -> URL {
        try SessionDocumentStore(grokHome: openGrokHome).sessionDirectory(
            sessionID: sessionID,
            cwd: workingDirectory.standardizedFileURL.path
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("Live goal fail-closed and persistence parity")
struct LiveGoalFailClosedParityTests {
    @Test("a worker self-claim pauses infra until independent verification exists")
    func unverifiedCompletionPausesRatherThanCompletes() async throws {
        let fixture = try LiveGoalParityFixture()
        defer { fixture.remove() }
        let services = await fixture.services()
        let coordinator = try #require(services.goal)

        #expect(await services.goalToolSpecs().isEmpty)
        #expect(await services.activeToolSpecs().allSatisfy { $0.name != "update_goal" })

        let command = await LiveGoalCommands.run(
            argument: "independently verify the release",
            coordinator: coordinator
        )
        guard case .submitPrompt(let instruction) = command else {
            Issue.record("creating a durable goal did not produce its model instruction")
            return
        }
        #expect(instruction.contains("update_goal"))
        #expect(await services.goalToolSpecs().map(\.name) == ["update_goal"])
        #expect(services.handles("update_goal"))

        let output = await services.invoke(
            name: "update_goal",
            arguments: .object([
                "completed": .bool(true),
                "message": .string("the same worker claims everything is finished"),
            ])
        )

        #expect(output.contains("cannot be completed"))
        #expect(output.contains(LiveGoalCoordinator.verificationUnavailableMessage))
        let snapshot = try #require(await coordinator.snapshot)
        #expect(snapshot.status == .infraPaused)
        #expect(snapshot.status != .complete)
        #expect(snapshot.pauseMessage == LiveGoalCoordinator.verificationUnavailableMessage)
        #expect(snapshot.history.last?.event == .goalPaused)
        #expect(snapshot.history.last?.detail == "infra")
        #expect(await services.goalToolSpecs().isEmpty)

        let status = await LiveGoalCommands.statusText(coordinator: coordinator)
        #expect(status.contains("infra_paused"))
        #expect(status.contains(LiveGoalCoordinator.verificationUnavailableMessage))

        let stateURL = try fixture.sessionDirectory()
            .appendingPathComponent("goal", isDirectory: true)
            .appendingPathComponent("state.json")
        let persisted = try JSONDecoder().decode(
            GoalOrchestration.self,
            from: Data(contentsOf: stateURL)
        )
        #expect(persisted.status == .infraPaused)
        #expect(persisted.pauseMessage == LiveGoalCoordinator.verificationUnavailableMessage)
    }

    @Test("goal state uses the canonical encoded-cwd session tree and private modes")
    func canonicalStateDirectoryAndOwnerOnlyPermissions() async throws {
        let fixture = try LiveGoalParityFixture()
        defer { fixture.remove() }
        let services = await fixture.services()
        let coordinator = try #require(services.goal)
        let created = await coordinator.createGoal(objective: "persist below the real session")
        try created.get()

        let sessionDirectory = try fixture.sessionDirectory()
        let goalDirectory = sessionDirectory.appendingPathComponent("goal", isDirectory: true)
        let stateURL = goalDirectory.appendingPathComponent("state.json")
        #expect(FileManager.default.fileExists(atPath: stateURL.path))

        let obsoleteStateURL = fixture.openGrokHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("goal-session", isDirectory: true)
            .appendingPathComponent("goal", isDirectory: true)
            .appendingPathComponent("state.json")
        #expect(!FileManager.default.fileExists(atPath: obsoleteStateURL.path))

        let persisted = try JSONDecoder().decode(
            GoalOrchestration.self,
            from: Data(contentsOf: stateURL)
        )
        #expect(persisted.objective == "persist below the real session")

        #if !os(Windows)
        for directory in [
            sessionDirectory.deletingLastPathComponent(),
            sessionDirectory,
            goalDirectory,
        ] {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            let mode = try #require(attributes[.posixPermissions] as? NSNumber)
            #expect((mode.intValue & 0o777) == 0o700)
        }
        let stateAttributes = try FileManager.default.attributesOfItem(atPath: stateURL.path)
        let stateMode = try #require(stateAttributes[.posixPermissions] as? NSNumber)
        #expect((stateMode.intValue & 0o777) == 0o600)
        #endif
    }

    @Test("failed goal creation is visible and does not advertise phantom goal tools")
    func creationWriteFailureIsVisibleAndRollsBack() async throws {
        let fixture = try LiveGoalParityFixture()
        defer { fixture.remove() }
        let services = await fixture.services()
        let coordinator = try #require(services.goal)
        let sessionDirectory = try fixture.sessionDirectory()
        try FileManager.default.createDirectory(
            at: sessionDirectory,
            withIntermediateDirectories: true
        )
        let obstructingFile = sessionDirectory.appendingPathComponent("goal")
        try Data("not a directory".utf8).write(to: obstructingFile)

        let result = await LiveGoalCommands.run(
            argument: "this must not silently disappear",
            coordinator: coordinator
        )
        guard case .message(let message) = result else {
            Issue.record("a failed goal write incorrectly submitted a model prompt")
            return
        }

        #expect(message.contains("Goal was not created"))
        #expect(message.contains("could not be persisted"))
        #expect(!(await coordinator.isActive))
        #expect(await coordinator.snapshot == nil)
        #expect(await services.goalToolSpecs().isEmpty)
    }

    @Test("invalid canonical session paths fail visibly without a legacy fallback")
    func invalidSessionDirectoryIsReported() async throws {
        let fixture = try LiveGoalParityFixture()
        defer { fixture.remove() }
        let services = await fixture.services(sessionID: "../outside")
        let coordinator = try #require(services.goal)

        let result = await LiveGoalCommands.run(
            argument: "do not escape the state directory",
            coordinator: coordinator
        )
        guard case .message(let message) = result else {
            Issue.record("an invalid session path incorrectly submitted a model prompt")
            return
        }

        #expect(message.contains("Goal was not created"))
        #expect(message.contains("invalid session ID"))
        #expect(!(await coordinator.isActive))
        #expect(await services.goalToolSpecs().isEmpty)
    }

    #if !os(Windows)
    @Test("a symlinked goal directory is rejected before touching its destination")
    func symlinkedGoalDirectoryNeverReceivesState() async throws {
        let fixture = try LiveGoalParityFixture()
        defer { fixture.remove() }
        let services = await fixture.services()
        let coordinator = try #require(services.goal)
        let sessionDirectory = try fixture.sessionDirectory()
        try FileManager.default.createDirectory(
            at: sessionDirectory,
            withIntermediateDirectories: true
        )
        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let link = sessionDirectory.appendingPathComponent("goal")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let result = await LiveGoalCommands.run(
            argument: "keep secrets inside the session",
            coordinator: coordinator
        )
        guard case .message(let message) = result else {
            Issue.record("a symlinked goal directory incorrectly started goal mode")
            return
        }

        #expect(message.contains("symbolic link"))
        #expect(!(await coordinator.isActive))
        #expect(!FileManager.default.fileExists(
            atPath: outside.appendingPathComponent("state.json").path
        ))
    }

    @Test("update_goal surfaces write failures and rolls back the attempted pause")
    func completionWriteFailureIsVisibleWithoutFollowingFinalSymlink() async throws {
        let fixture = try LiveGoalParityFixture()
        defer { fixture.remove() }
        let services = await fixture.services()
        let coordinator = try #require(services.goal)
        let created = await coordinator.createGoal(objective: "protect the existing document")
        try created.get()

        let stateURL = try fixture.sessionDirectory()
            .appendingPathComponent("goal", isDirectory: true)
            .appendingPathComponent("state.json")
        let outside = fixture.root.appendingPathComponent("outside-secret.json")
        let secret = Data("must never be overwritten".utf8)
        try secret.write(to: outside)
        try FileManager.default.removeItem(at: stateURL)
        try FileManager.default.createSymbolicLink(at: stateURL, withDestinationURL: outside)

        let output = await services.invoke(
            name: "update_goal",
            arguments: .object(["completed": .bool(true)])
        )

        #expect(output.contains("update_goal was not applied"))
        #expect(output.contains("symbolic link"))
        #expect(await coordinator.status == .active)
        #expect(await coordinator.snapshot?.pauseMessage == nil)
        #expect(try Data(contentsOf: outside) == secret)
        let linkAttributes = try FileManager.default.attributesOfItem(atPath: stateURL.path)
        #expect(linkAttributes[.type] as? FileAttributeType == .typeSymbolicLink)
    }
    #endif
}
