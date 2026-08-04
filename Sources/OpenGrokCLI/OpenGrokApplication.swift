import Foundation

public enum CLIApplicationError: Error, Sendable, Equatable, CustomStringConvertible {
    case unsupported(route: String)
    case failed(String)

    public var description: String {
        switch self {
        case .unsupported(let route):
            return "route '\(route)' is not available in the current Swift composition"
        case .failed(let message):
            return message
        }
    }
}

public struct CLIExecutionControl: Sendable {
    public let isCancelled: @Sendable () -> Bool
    public let waitForCancellation: @Sendable () async -> Void

    public init(
        isCancelled: @escaping @Sendable () -> Bool,
        waitForCancellation: @escaping @Sendable () async -> Void
    ) {
        self.isCancelled = isCancelled
        self.waitForCancellation = waitForCancellation
    }

    public static let never = CLIExecutionControl(
        isCancelled: { false },
        waitForCancellation: {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    )

    public static let taskCancellation = CLIExecutionControl(
        isCancelled: { Task.isCancelled },
        waitForCancellation: {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    )
}

public struct CLIApplicationContext: Sendable {
    public let environment: [String: String]
    public let streams: CLIStreams
    public let control: CLIExecutionControl

    public init(
        environment: [String: String],
        streams: CLIStreams,
        control: CLIExecutionControl
    ) {
        self.environment = environment
        self.streams = streams
        self.control = control
    }
}

public struct CLIApplicationSession: Sendable {
    public let waitForExit: @Sendable () async throws -> Void
    public let shutdown: @Sendable () async -> Void

    public init(
        waitForExit: @escaping @Sendable () async throws -> Void,
        shutdown: @escaping @Sendable () async -> Void
    ) {
        self.waitForExit = waitForExit
        self.shutdown = shutdown
    }
}

public struct CLIApplicationLauncher: Sendable {
    public let start: @Sendable (CLICommand, CLIApplicationContext) async throws -> CLIApplicationSession

    public init(
        start: @escaping @Sendable (CLICommand, CLIApplicationContext) async throws -> CLIApplicationSession
    ) {
        self.start = start
    }

    public static let unavailable = CLIApplicationLauncher { command, _ in
        throw CLIApplicationError.unsupported(route: command.routeName)
    }
}

public struct OpenGrokApplication: Sendable {
    public let launcher: CLIApplicationLauncher
    public let control: CLIExecutionControl

    public init(
        launcher: CLIApplicationLauncher,
        control: CLIExecutionControl = .taskCancellation
    ) {
        self.launcher = launcher
        self.control = control
    }

    public static let unavailable = OpenGrokApplication(launcher: .unavailable)

    public func run(
        command: CLICommand,
        environment: [String: String],
        streams: CLIStreams
    ) async throws {
        let context = CLIApplicationContext(
            environment: environment,
            streams: streams,
            control: control
        )
        let session = try await launcher.start(command, context)
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await session.waitForExit()
                }
                group.addTask {
                    await self.control.waitForCancellation()
                    try Task.checkCancellation()
                    throw CancellationError()
                }
                _ = try await group.next()
                group.cancelAll()
            }
        } catch {
            await session.shutdown()
            throw error
        }
        await session.shutdown()
    }
}
