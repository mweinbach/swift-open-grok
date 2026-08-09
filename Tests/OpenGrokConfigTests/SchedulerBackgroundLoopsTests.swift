// SchedulerBackgroundLoopsTests.swift
//
// Precedence pins for the `[scheduler] background_loops` resolver — the port
// of upstream's `scheduler_background_loops_tests`
// (`xai-grok-shell/src/util/config/resolve/toolset.rs:266-309` plus the
// login-shell suite's env/requirements pins the resolver shares its tiers
// with). The environment is injected on every call, so no test mutates
// process-global state.

import Testing
@testable import OpenGrokConfig
import OpenGrokConfigTypes

@Suite("[scheduler] background_loops resolution")
struct SchedulerBackgroundLoopsTests {
    private func config(_ enabled: Bool) throws -> TOMLValue {
        try parseTOML("[scheduler]\nbackground_loops = \(enabled)\n")
    }

    @Test("defaults on (toolset.rs:282-288)")
    func defaultsOn() throws {
        #expect(
            resolveSchedulerBackgroundLoopsTiers(environment: [:])
                == Resolved(value: true, source: .default)
        )
    }

    @Test("remote flag can disable (toolset.rs:290-300)")
    func remoteFlagCanDisable() throws {
        #expect(
            resolveSchedulerBackgroundLoopsTiers(remote: false, environment: [:])
                == Resolved(value: false, source: .remote)
        )
    }

    @Test("user config beats remote (toolset.rs:302-309)")
    func userConfigBeatsRemote() throws {
        #expect(
            resolveSchedulerBackgroundLoopsTiers(
                user: try config(true),
                remote: false,
                environment: [:]
            ) == Resolved(value: true, source: .config)
        )
        #expect(
            resolveSchedulerBackgroundLoopsTiers(
                user: try config(false),
                remote: true,
                environment: [:]
            ) == Resolved(value: false, source: .config)
        )
    }

    @Test("user config beats managed; managed beats remote")
    func userBeatsManagedBeatsRemote() throws {
        #expect(
            resolveSchedulerBackgroundLoopsTiers(
                user: try config(true),
                managed: try config(false),
                environment: [:]
            ) == Resolved(value: true, source: .config)
        )
        #expect(
            resolveSchedulerBackgroundLoopsTiers(
                managed: try config(false),
                remote: true,
                environment: [:]
            ) == Resolved(value: false, source: .managedConfig)
        )
    }

    @Test("system-managed backs the managed tier when managed is silent (toolset.rs:256-259)")
    func systemManagedFallsBackIn() throws {
        #expect(
            resolveSchedulerBackgroundLoopsTiers(
                systemManaged: try config(false),
                environment: [:]
            ) == Resolved(value: false, source: .managedConfig)
        )
        // A managed value shadows the system-managed one entirely.
        #expect(
            resolveSchedulerBackgroundLoopsTiers(
                managed: try config(true),
                systemManaged: try config(false),
                environment: [:]
            ) == Resolved(value: true, source: .managedConfig)
        )
    }

    @Test("env beats config and remote (the login-shell env pin, toolset.rs:192-198)")
    func environmentBeatsConfigAndRemote() throws {
        #expect(
            resolveSchedulerBackgroundLoopsTiers(
                user: try config(true),
                remote: true,
                environment: [schedulerBackgroundLoopsEnvVar: "0"]
            ) == Resolved(value: false, source: .env)
        )
    }

    @Test("requirements win outright (toolset.rs:200-213)")
    func requirementsWinOutright() throws {
        #expect(
            resolveSchedulerBackgroundLoopsTiers(
                requirements: try config(false),
                user: try config(true),
                environment: [schedulerBackgroundLoopsEnvVar: "1"]
            ) == Resolved(value: false, source: .requirement)
        )
    }

    @Test("a layer without the key is transparent")
    func absentKeyIsTransparent() throws {
        let unrelated = try parseTOML("[scheduler]\nother = 1\n")
        #expect(schedulerBackgroundLoopsFromTOML(unrelated) == nil)
        #expect(
            resolveSchedulerBackgroundLoopsTiers(
                user: unrelated,
                environment: [:]
            ) == Resolved(value: true, source: .default)
        )
    }
}
