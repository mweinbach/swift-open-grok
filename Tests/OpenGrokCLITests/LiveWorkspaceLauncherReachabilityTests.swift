// LiveWorkspaceLauncherReachabilityTests.swift
//
// Does `open-grok workspace` actually reach `LiveWorkspaceComposition`?
//
// `LiveWorkspaceCompositionTests` answers "does the route work", by calling
// `LiveWorkspaceComposition.run` and `.handles` directly. Both stay green if
// the launcher clause in `LiveComposition.swift` is deleted, reordered behind
// a clause that also claims `.utility`, or never lands at all — the feature
// would be implemented, tested, and unreachable. That is the exact shape the
// Computer Hub audit found (a tested library with no importer), and this
// project has now hit it three times, so it gets a test of its own.
//
// This drives the real `OpenGrokLiveApplicationLauncher` with a real parsed
// argv and asserts the command lands in this route rather than in a refusal.
// AGENTS.md §3: assert reachability through the live seam.
//
// The discriminator is a message only `LiveWorkspaceComposition.preflight`
// can produce. With `GROK_WORKSPACE_COMMAND=0` the feature gate refuses
// before anything is dialled, so the test is hermetic — no leader, no socket,
// no network — and the failure it is built to catch (the command reaching
// some other handler) surfaces as a different error type entirely.

import Foundation
import Testing
@testable import OpenGrokCLI
import OpenGrokACPRuntime
import OpenGrokConfigTypes

private final class LauncherWorkspaceChannel: WorkspaceControlChannel, @unchecked Sendable {
    let advertisedCapabilities: OpenGrokACPRuntime.ACPLeaderCapabilities? =
        OpenGrokACPRuntime.ACPLeaderCapabilities(workspaceExposure: true)
    private let lock = NSLock()
    private var received: [WorkspaceControlCommand] = []

    var commands: [WorkspaceControlCommand] {
        lock.lock(); defer { lock.unlock() }
        return received
    }

    private func record(_ command: WorkspaceControlCommand) {
        lock.lock()
        received.append(command)
        lock.unlock()
    }

    func send(_ command: WorkspaceControlCommand) async throws -> WorkspaceStatusPayload {
        record(command)
        return WorkspaceStatusPayload(state: "none", pid: 7331)
    }

    func close() async {}
}

private final class WorkspaceLoaderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var calls: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    func record() {
        lock.lock(); count += 1; lock.unlock()
    }
}

private func launcherContext(
    environment: [String: String]
) -> (context: CLIApplicationContext, out: BufferedStream, err: BufferedStream) {
    let (streams, out, err) = CLIStreams.buffered()
    return (
        CLIApplicationContext(
            environment: environment,
            streams: streams,
            control: .never
        ),
        out,
        err
    )
}

@Suite("workspace route is reachable from the launcher")
struct LiveWorkspaceLauncherReachabilityTests {
    /// Gate explicitly off: refuses inside `preflight`, before any dial.
    private static let gateOff = ["GROK_WORKSPACE_COMMAND": "0"]

    private func launcher(
        loader: @escaping @Sendable ([String: String]) async -> RemoteSettings?,
        connect: @escaping @Sendable ([String: String]) async throws -> any WorkspaceControlChannel
    ) -> OpenGrokLiveApplicationLauncher {
        let route = LiveWorkspaceRouteDependencies(
            loadRemoteSettings: loader,
            connect: connect
        )
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { _, _ in
                    throw CLIApplicationError.failed("workspace test did not need a sampler")
                }
            },
            workspaceRoute: route
        )
        return OpenGrokLiveApplicationLauncher(dependencies: dependencies)
    }

    @Test("no override fetches enabled settings and reaches the injected leader")
    func enabledRemoteSettingsReachLeader() async throws {
        let probe = WorkspaceLoaderProbe()
        let channel = LauncherWorkspaceChannel()
        var settings = RemoteSettings()
        settings.workspaceCommandEnabled = true
        let enabledSettings = settings
        let launcher = launcher(
            loader: { _ in
                probe.record()
                return enabledSettings
            },
            connect: { _ in channel }
        ).launcher
        let (context, out, _) = launcherContext(environment: [:])

        _ = try await launcher.start(
            try CLICommandParser.parseOrThrow(["workspace", "status"]),
            context
        )

        #expect(probe.calls == 1)
        #expect(channel.commands == [.status])
        #expect(out.contents.contains("Workspace exposure: not running"))
    }

    @Test("an explicit false override bypasses settings and preserves the disabled refusal")
    func overrideBypassesLoader() async throws {
        let probe = WorkspaceLoaderProbe()
        let channel = LauncherWorkspaceChannel()
        let launcher = launcher(
            loader: { _ in
                probe.record()
                return nil
            },
            connect: { _ in channel }
        ).launcher
        let (context, _, _) = launcherContext(environment: Self.gateOff)

        await #expect(throws: WorkspaceRouteError.self) {
            try await launcher.start(
                try CLICommandParser.parseOrThrow(["workspace", "status"]),
                context
            )
        }

        #expect(probe.calls == 0)
        #expect(channel.commands.isEmpty)
    }

    @Test("unavailable or disabled fetched settings refuse before leader IPC")
    func fetchedSettingsRefuseBeforeDialing() async throws {
        var disabled = RemoteSettings()
        disabled.workspaceCommandEnabled = false
        let fetchedSettings: [RemoteSettings?] = [nil, disabled]
        for fetched in fetchedSettings {
            let channel = LauncherWorkspaceChannel()
            let launcher = launcher(
                loader: { _ in fetched },
                connect: { _ in channel }
            ).launcher
            let (context, _, _) = launcherContext(environment: [:])

            await #expect(throws: WorkspaceRouteError.self) {
                try await launcher.start(
                    try CLICommandParser.parseOrThrow(["workspace", "status"]),
                    context
                )
            }
            #expect(channel.commands.isEmpty)
        }
    }

    @Test("`workspace status` reaches LiveWorkspaceComposition, not a refusal")
    func workspaceStatusReachesTheRoute() async throws {
        let command = try CLICommandParser.parseOrThrow(["workspace", "status"])
        let (context, _, _) = launcherContext(environment: Self.gateOff)
        let launcher = OpenGrokLiveApplicationLauncher().launcher

        do {
            _ = try await launcher.start(command, context)
            Issue.record("expected the route's feature gate to refuse")
        } catch let error as WorkspaceRouteError {
            // DO NOT LOOSEN THIS TO A TYPE-ONLY CHECK.
            //
            // Matching the message is deliberate. `WorkspaceRouteError` alone
            // would not distinguish *this* route's refusal from any other
            // route's, so the assertion could pass while `workspace` was being
            // handled somewhere else entirely — which is the exact failure this
            // suite exists to detect. Only
            // `LiveWorkspaceComposition.preflight` produces this text, so
            // reaching it is what proves the launcher dispatched here.
            //
            // The cost is real and accepted: the string is a parity artifact
            // copied from `main.rs:319-322`, so rewording it fails this suite
            // and `WorkspaceGateTests.disabledGateWording` together. That is
            // two failures pointing at one line, not a flaky test.
            #expect(error.message.contains("not enabled for this account"))
        } catch let error as CLIApplicationError {
            let detail = "the launcher did not route `workspace` to "
                + "LiveWorkspaceComposition — the clause in LiveComposition.swift is "
                + "missing, or an earlier clause shadowed it. Got: \(error)"
            Issue.record(Comment(rawValue: detail))
        }
    }

    @Test("every workspace subcommand reaches the route, not just status")
    func allSubcommandsReachTheRoute() async throws {
        // `start`/`restart`/`resume` would hit the sandbox refusal first if a
        // profile were active; none is in the test environment, so all six
        // land on the same feature gate.
        for action in ["start", "restart", "pause", "resume", "stop", "status", "list"] {
            let command = try CLICommandParser.parseOrThrow(["workspace", action])
            let (context, _, _) = launcherContext(environment: Self.gateOff)
            let launcher = OpenGrokLiveApplicationLauncher().launcher

            do {
                _ = try await launcher.start(command, context)
                Issue.record("expected '\(action)' to be refused by the gate")
            } catch let error as WorkspaceRouteError {
                // Same deliberate message coupling as above — see the comment
                // in `workspaceStatusReachesTheRoute` before loosening it.
                #expect(
                    error.message.contains("not enabled for this account"),
                    "'\(action)' reached the route but refused unexpectedly: \(error.message)"
                )
            } catch let error as CLIApplicationError {
                Issue.record("'\(action)' did not reach the route. Got: \(error)")
            }
        }
    }

    @Test("the launcher still refuses a genuinely unhooked utility")
    func unhookedUtilityStillRefuses() async throws {
        // The negative control. Without it, the assertions above would pass
        // just as happily against a launcher that answered *every* command
        // with a WorkspaceRouteError — the test would be measuring nothing.
        // `trace` remains a genuinely unhooked utility. `worktree` is now a
        // live route and must not be used as a negative control here.
        let command = try CLICommandParser.parseOrThrow(["trace", "--local"])
        let (context, _, _) = launcherContext(environment: Self.gateOff)
        let launcher = OpenGrokLiveApplicationLauncher().launcher

        do {
            _ = try await launcher.start(command, context)
            Issue.record("expected an unhooked utility route to refuse")
        } catch let error as WorkspaceRouteError {
            let detail = "the workspace route claimed `trace` — `handles` is "
                + "matching too broadly. Got: \(error)"
            Issue.record(Comment(rawValue: detail))
        } catch {
            // Any non-workspace error is correct here: the point is only that
            // `worktree` does not land in the workspace route.
        }
    }

    @Test("a launcher without the clause fails this suite's assertion")
    func missingClauseWouldBeCaught() async throws {
        // Proves the first test discriminates rather than passing for an
        // unrelated reason. A launcher with no workspace clause answers with
        // `CLIApplicationError`, which is the branch that calls `Issue.record`
        // above — so deleting the clause in LiveComposition.swift turns this
        // suite red instead of leaving it quietly green.
        //
        // Done by substituting a bare launcher rather than by editing
        // LiveComposition.swift: this tree is shared, and mutating source that
        // another agent is mid-build against corrupts their run (AGENTS.md §1).
        let command = try CLICommandParser.parseOrThrow(["workspace", "status"])
        let (context, _, _) = launcherContext(environment: Self.gateOff)

        do {
            _ = try await CLIApplicationLauncher.unavailable.start(command, context)
            Issue.record("expected the bare launcher to refuse")
        } catch let error as CLIApplicationError {
            #expect(error == .unsupported(route: "workspace"))
        } catch let error as WorkspaceRouteError {
            let detail = "a launcher with no workspace clause still reached the "
                + "route — the assertion in this suite cannot detect a missing "
                + "hook. Got: \(error)"
            Issue.record(Comment(rawValue: detail))
        }
    }

    @Test("the stale 'not implemented' refusal is gone from the binary's text")
    func staleRefusalIsGone() async throws {
        // `CLIRunner` used to answer `workspace` with "Computer Hub workspace
        // exposure is not implemented." That string is now false. If it comes
        // back, this is the test that says so rather than a user discovering
        // a working feature that claims not to exist.
        let command = try CLICommandParser.parseOrThrow(["workspace", "status"])
        let (context, out, err) = launcherContext(environment: Self.gateOff)
        let launcher = OpenGrokLiveApplicationLauncher().launcher

        _ = try? await launcher.start(command, context)

        #expect(!out.contents.contains("not implemented"))
        #expect(!err.contents.contains("not implemented"))
    }
}
