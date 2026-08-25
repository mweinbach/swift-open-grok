import Foundation
import OpenGrokConfig
import OpenGrokTerminalCore
import OpenGrokWorkspace

enum LiveFolderTrustPromptResult: Sendable {
    case proceed(OpenGrokLiveInteractiveInput?)
    case cancelled
}

enum LiveFolderTrustPrompt {
    static func preflight(
        workingDirectory: URL,
        environment: [String: String],
        explicitTrust: Bool,
        interactiveInput: OpenGrokLiveInteractiveInput?,
        hasInteractiveSurface: Bool,
        terminal: OpenGrokLiveTerminal,
        authenticationReady: Bool = true
    ) async throws -> LiveFolderTrustPromptResult {
        let cwd = workingDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let workspace = workspaceRoot(for: cwd, environment: environment)
        let base = (try? ConfigLayers.load(environment: environment))?.effectiveConfigBase()
        let featureEnabled = folderTrustEnabled(document: base, environment: environment)
        let keyRecordable = !isUnsafeTrustRoot(workspace.path, home: environment["HOME"])

        if explicitTrust {
            guard keyRecordable else {
                throw CLIApplicationError.failed(
                    "Refusing folder trust for an unsafe workspace root: \(workspace.path)"
                )
            }
            try persistVerifiedGrant(workspace, environment: environment)
            return .proceed(interactiveInput)
        }

        // Rust renders access/login/ZDR before its trust interceptor. Explicit
        // `--trust` is separate CLI consent and is persisted before auth there.
        guard authenticationReady else { return .proceed(interactiveInput) }

        let outcome = decideFolderTrust(
            featureEnabled: featureEnabled,
            inputs: FolderTrustDecideInputs(
                storeTrusted: PersistentFolderTrustStore(environment: environment).isTrusted(workspace),
                repoConfigsPresent: repoConfigsPresent(at: cwd, environment: environment),
                isInteractive: hasInteractiveSurface && interactiveInput != nil && terminal.isTTY(),
                keyRecordable: keyRecordable
            )
        )
        guard outcome == .prompt, let interactiveInput else {
            return .proceed(interactiveInput)
        }

        let bridge = LiveFolderTrustPromptInputBridge(upstream: interactiveInput)
        bridge.start()
        // The input producer starts before this preflight. Giving its bridge the
        // first turn drains already-buffered startup typeahead while the gate is
        // disarmed; otherwise a prompt typed during launch could answer "n".
        await Task.yield()

        do {
            try await terminal.write(render(workspace: workspace))
            bridge.arm()
            var answers = bridge.answers.makeAsyncIterator()
            guard let answer = try await answers.next() else {
                bridge.stop()
                return .cancelled
            }

            switch answer {
            case .decline:
                bridge.stop()
                try await terminal.write("\r\n")
                return .cancelled
            case .grant:
                do {
                    try persistVerifiedGrant(workspace, environment: environment)
                } catch {
                    bridge.stop()
                    throw error
                }
                let relay = bridge.forwardingInput()
                try await terminal.write("\r\n")
                return .proceed(relay)
            }
        } catch {
            bridge.stop()
            throw error
        }
    }

    static func workspaceRoot(for workingDirectory: URL, environment: [String: String]) -> URL {
        LiveWorkspaceTrustIdentity.resolve(
            workingDirectory: workingDirectory,
            environment: environment
        )
    }

    private static func persistVerifiedGrant(_ workspace: URL, environment: [String: String]) throws {
        do {
            var store = PersistentFolderTrustStore(environment: environment)
            try store.record(workspace, trusted: true)
            guard PersistentFolderTrustStore(environment: environment).isTrusted(workspace) else {
                throw CLIApplicationError.failed(
                    "Failed to persist folder trust for \(workspace.path). Project access is blocked."
                )
            }
        } catch let error as CLIApplicationError {
            throw error
        } catch {
            throw CLIApplicationError.failed(
                "Failed to persist folder trust for \(workspace.path): \(error). Project access is blocked."
            )
        }
    }

    private static func render(workspace: URL) -> String {
        "\r\nDo you trust the contents of this directory?\r\n"
            + "\(workspace.path)\r\n\r\n"
            + "Open Grok may run or modify contents in this directory,\r\n"
            + "posing security risks.\r\n\r\n"
            + "[y] Yes, proceed    [n] No, quit\r\n"
    }
}

private enum LiveFolderTrustPromptAnswer: Sendable {
    case grant
    case decline
}

private final class LiveFolderTrustPromptInputBridge: @unchecked Sendable {
    private enum Phase {
        case discardStartup
        case pending
        case buffering
        case forwarding
        case stopped
    }

    private let lock = NSLock()
    private let upstream: OpenGrokLiveInteractiveInput
    private let answerContinuation: AsyncThrowingStream<LiveFolderTrustPromptAnswer, Error>.Continuation
    private let eventContinuation: AsyncThrowingStream<InputEvent, Error>.Continuation
    private let events: AsyncThrowingStream<InputEvent, Error>
    private var phase: Phase = .discardStartup
    private var bufferedEvents: [InputEvent] = []
    private var task: Task<Void, Never>?
    private var upstreamFinished = false
    private var upstreamFailure: (any Error)?

    let answers: AsyncThrowingStream<LiveFolderTrustPromptAnswer, Error>

    init(upstream: OpenGrokLiveInteractiveInput) {
        self.upstream = upstream
        let answerPair = AsyncThrowingStream<LiveFolderTrustPromptAnswer, Error>.makeStream()
        answers = answerPair.stream
        answerContinuation = answerPair.continuation
        let eventPair = AsyncThrowingStream<InputEvent, Error>.makeStream()
        events = eventPair.stream
        eventContinuation = eventPair.continuation
    }

    func start() {
        let upstream = upstream
        let task = Task { [weak self] in
            do {
                for try await event in upstream.events {
                    guard let self else { return }
                    self.receive(event)
                }
                self?.finish()
            } catch {
                self?.finish(throwing: error)
            }
        }
        lock.withLock { self.task = task }
    }

    func arm() {
        lock.withLock {
            if phase == .discardStartup { phase = .pending }
        }
    }

    func forwardingInput() -> OpenGrokLiveInteractiveInput {
        lock.withLock {
            phase = .forwarding
            for event in bufferedEvents {
                eventContinuation.yield(event)
            }
            bufferedEvents.removeAll(keepingCapacity: false)
            if upstreamFinished {
                eventContinuation.finish(throwing: upstreamFailure)
            }
        }
        let upstream = upstream
        return OpenGrokLiveInteractiveInput(
            events: events,
            close: { [self] in
                stop()
                await upstream.close()
            },
            suspendControl: { await upstream.beginSuspension() }
        )
    }

    func stop() {
        let task = lock.withLock { () -> Task<Void, Never>? in
            guard phase != .stopped else { return nil }
            phase = .stopped
            bufferedEvents.removeAll(keepingCapacity: false)
            answerContinuation.finish()
            eventContinuation.finish()
            let task = self.task
            self.task = nil
            return task
        }
        task?.cancel()
    }

    private func receive(_ event: InputEvent) {
        lock.withLock {
            switch phase {
            case .discardStartup, .stopped:
                return
            case .buffering:
                bufferedEvents.append(event)
            case .forwarding:
                eventContinuation.yield(event)
            case .pending:
                guard case .key(let key) = event,
                      let answer = Self.answer(for: key)
                else { return }
                phase = .buffering
                answerContinuation.yield(answer)
            }
        }
    }

    private func finish(throwing error: (any Error)? = nil) {
        lock.withLock {
            upstreamFinished = true
            upstreamFailure = error
            answerContinuation.finish(throwing: error)
            // An answer and following composer events can arrive in one read.
            // Keep the downstream continuation open until its buffered tail is
            // published, even when that read also observed EOF.
            if phase != .buffering {
                eventContinuation.finish(throwing: error)
            }
        }
    }

    private static func answer(for key: KeyEvent) -> LiveFolderTrustPromptAnswer? {
        switch key.key {
        case .enter where key.modifiers.isEmpty:
            return .grant
        case .escape:
            return .decline
        case .char(let character):
            if key.modifiers.contains(.control), character == "c" || character == "d" {
                return .decline
            }
            guard !key.modifiers.contains(.control),
                  !key.modifiers.contains(.alt),
                  !key.modifiers.contains(.meta),
                  !key.modifiers.contains(.superKey)
            else { return nil }
            switch character {
            case "y", "Y": return .grant
            case "n", "N": return .decline
            default: return nil
            }
        default:
            return nil
        }
    }
}
