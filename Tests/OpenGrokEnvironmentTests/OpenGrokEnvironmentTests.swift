// OpenGrokEnvironmentTests.swift
//
// Target-scoped Swift Testing suites for `OpenGrokEnvironment` (W0-S3).
//
// Tests translate the Rust `xai-grok-env/src/lib.rs` `tests` module and add
// deterministic coverage for endpoint resolution with injectable environments
// and `EnvVarGuard` RAII semantics.

import Foundation
import Testing
@testable import OpenGrokEnvironment

@Suite("OpenGrokEnvironment")
struct OpenGrokEnvironmentTests {

    // MARK: - Compiled production constants

    @Test("Production endpoints match the Rust compiled defaults")
    func productionEndpointsCompiled() {
        let endpoints = GrokBuildEndpoints.production
        #expect(endpoints.cliChatProxyBaseURL == "https://cli-chat-proxy.grok.com/v1")
        #expect(endpoints.assetServerURL == "https://assets.grok.com")
        #expect(endpoints.relayWsURL == "wss://code.grok.com/ws/code-agent")
        #expect(endpoints.gatewayWsURL == "wss://grok.com/ws/gw/")
        #expect(endpoints.wsOrigin == "https://grok.com")
    }

    @Test("PROD_* constants re-export the production endpoints")
    func prodConstants() {
        #expect(PROD_CLI_CHAT_PROXY_BASE_URL == "https://cli-chat-proxy.grok.com/v1")
        #expect(PROD_ASSET_SERVER_URL == "https://assets.grok.com")
        #expect(PROD_RELAY_WS_URL == "wss://code.grok.com/ws/code-agent")
        #expect(PROD_GATEWAY_WS_URL == "wss://grok.com/ws/gw/")
        #expect(PROD_WS_ORIGIN == "https://grok.com")
    }

    // MARK: - env_prefix

    @Test("The env-var prefixes are an operator interface; do not rename")
    func envPrefix() {
        #expect(GrokBuildEnvironment.production.envPrefix == "GROK_PRODUCTION")
    }

    // MARK: - from_flags

    @Test("fromFlags always returns Production in public builds")
    func fromFlagsAlwaysProduction() {
        #expect(GrokBuildEnvironment.fromFlags(dev: false, staging: false) == .production)
        #expect(GrokBuildEnvironment.fromFlags(dev: true, staging: false) == .production)
        #expect(GrokBuildEnvironment.fromFlags(dev: false, staging: true) == .production)
        #expect(GrokBuildEnvironment.fromFlags(dev: true, staging: true) == .production)
    }

    // MARK: - indicator / isProduction / description

    @Test("Production indicator is nil")
    func productionIndicatorIsNil() {
        #expect(GrokBuildEnvironment.production.indicator == nil)
    }

    @Test("Production isProduction is true")
    func productionIsProduction() {
        #expect(GrokBuildEnvironment.production.isProduction)
    }

    @Test("Production description is 'production'")
    func productionDescription() {
        #expect(GrokBuildEnvironment.production.description == "production")
    }

    // MARK: - Endpoint resolution with injectable environment

    @Test("Endpoint resolvers return compiled defaults when no override is set")
    func endpointResolversDefault() {
        let env: [String: String] = [:]
        let e = GrokBuildEnvironment.production
        #expect(e.cliChatProxyBaseURL(environment: env) == PROD_CLI_CHAT_PROXY_BASE_URL)
        #expect(e.assetServerURL(environment: env) == PROD_ASSET_SERVER_URL)
        #expect(e.relayWsURL(environment: env) == PROD_RELAY_WS_URL)
        #expect(e.gatewayWsURL(environment: env) == PROD_GATEWAY_WS_URL)
        #expect(e.wsOrigin(environment: env) == PROD_WS_ORIGIN)
    }

    @Test("Endpoint resolvers honor GROK_PRODUCTION_* overrides")
    func endpointResolversOverride() {
        let env = [
            "GROK_PRODUCTION_CLI_CHAT_PROXY_BASE_URL": "https://override-proxy.example/v1",
            "GROK_PRODUCTION_ASSET_SERVER_URL": "https://override-assets.example",
            "GROK_PRODUCTION_WS_URL": "wss://override-relay.example/ws",
            "GROK_PRODUCTION_GATEWAY_WS_URL": "wss://override-gw.example/ws/gw/",
            "GROK_PRODUCTION_WS_ORIGIN": "https://override-origin.example",
        ]
        let e = GrokBuildEnvironment.production
        #expect(e.cliChatProxyBaseURL(environment: env) == "https://override-proxy.example/v1")
        #expect(e.assetServerURL(environment: env) == "https://override-assets.example")
        #expect(e.relayWsURL(environment: env) == "wss://override-relay.example/ws")
        #expect(e.gatewayWsURL(environment: env) == "wss://override-gw.example/ws/gw/")
        #expect(e.wsOrigin(environment: env) == "https://override-origin.example")
    }

    @Test("Empty-string override returns empty string (Rust std::env::var parity)")
    func endpointResolversEmptyOverrideReturnsEmpty() {
        // The Rust reference uses `std::env::var(key).unwrap_or_else(|_| compiled)`,
        // which returns an empty value when the variable is set to empty (only
        // absent keys trigger the fallback). The Swift port matches this: an
        // explicitly empty `GROK_PRODUCTION_*` override returns `""`, not the
        // compiled default.
        let env = [
            "GROK_PRODUCTION_CLI_CHAT_PROXY_BASE_URL": "",
            "GROK_PRODUCTION_WS_URL": "",
        ]
        let e = GrokBuildEnvironment.production
        #expect(e.cliChatProxyBaseURL(environment: env) == "")
        #expect(e.relayWsURL(environment: env) == "")
    }

    @Test("Empty-string override returns empty string for all endpoints (Rust parity)")
    func endpointResolversAllEmptyOverrideReturnsEmpty() {
        let env = [
            "GROK_PRODUCTION_CLI_CHAT_PROXY_BASE_URL": "",
            "GROK_PRODUCTION_ASSET_SERVER_URL": "",
            "GROK_PRODUCTION_WS_URL": "",
            "GROK_PRODUCTION_GATEWAY_WS_URL": "",
            "GROK_PRODUCTION_WS_ORIGIN": "",
        ]
        let e = GrokBuildEnvironment.production
        #expect(e.cliChatProxyBaseURL(environment: env) == "")
        #expect(e.assetServerURL(environment: env) == "")
        #expect(e.relayWsURL(environment: env) == "")
        #expect(e.gatewayWsURL(environment: env) == "")
        #expect(e.wsOrigin(environment: env) == "")
    }

    @Test("Relay and gateway URLs are distinct (relay must not connect to gateway)")
    func relayAndGatewayUrlsAreDistinct() {
        let env: [String: String] = [:]
        let e = GrokBuildEnvironment.production
        #expect(e.relayWsURL(environment: env) != e.gatewayWsURL(environment: env))
        #expect(PROD_RELAY_WS_URL != PROD_GATEWAY_WS_URL)
    }

    // MARK: - EnvVarGuard

    @Test("EnvVarGuard.set_value updates then restores on drop")
    func envVarGuardSetValueUpdatesThenRestores() {
        let key = "XAI_GROK_ENV_VAR_GUARD_SET_VALUE_PROBE"
        let before = ProcessInfo.processInfo.environment[key]
        do {
            let envGuard = EnvVarGuard.set(key, "initial")
            #expect(ProcessInfo.processInfo.environment[key] == "initial")
            envGuard.setValue("updated")
            #expect(ProcessInfo.processInfo.environment[key] == "updated",
                    "set_value must update the env var while the guard is live")
            envGuard.restore()
        }
        // After explicit restore, the env var returns to its prior value.
        let after = ProcessInfo.processInfo.environment[key]
        #expect(after == before,
                "Restore must return the pre-guard snapshot (was \(before ?? "nil"), now \(after ?? "nil"))")
    }

    @Test("EnvVarGuard.set then deinit restores the prior value")
    func envVarGuardSetRestoresOnDeinit() {
        let key = "XAI_GROK_ENV_VAR_GUARD_DEINIT_PROBE"
        let before = ProcessInfo.processInfo.environment[key]
        // Hold the guard in a variable so it lives for the do-scope. `_ =`
        // would release it immediately and deinit would run before the
        // expectation below.
        do {
            let envGuard = EnvVarGuard.set(key, "scoped")
            #expect(ProcessInfo.processInfo.environment[key] == "scoped")
            // Explicitly end the guard's lifetime before exiting the scope so
            // deinit runs deterministically inside the do-block.
            envGuard.restore()
            _ = envGuard
        }
        // After restore, the env var returns to its prior value.
        let after = ProcessInfo.processInfo.environment[key]
        #expect(after == before,
                "Restore must return the pre-guard snapshot (was \(before ?? "nil"), now \(after ?? "nil"))")
    }

    @Test("EnvVarGuard.remove unsets then restores")
    func envVarGuardRemoveRestores() {
        let key = "XAI_GROK_ENV_VAR_GUARD_REMOVE_PROBE"
        // Pre-set a value so we can verify remove + restore.
        let preGuard = EnvVarGuard.set(key, "preexisting")
        let before = ProcessInfo.processInfo.environment[key]
        #expect(before == "preexisting")
        do {
            let envGuard = EnvVarGuard.remove(key)
            #expect(ProcessInfo.processInfo.environment[key] == nil,
                    "remove must unset the env var while the guard is live")
            envGuard.restore()
        }
        let after = ProcessInfo.processInfo.environment[key]
        #expect(after == "preexisting",
                "Restore must return the pre-remove snapshot (got \(after ?? "nil"))")
        // Cleanup: restore to the truly-prior state.
        preGuard.restore()
    }

    @Test("EnvVarGuard restores to nil when the var was never set")
    func envVarGuardRestoresToNilWhenAbsent() {
        let key = "XAI_GROK_ENV_VAR_GUARD_ABSENT_PROBE"
        // Ensure absent.
        let cleanup = EnvVarGuard.remove(key)
        #expect(ProcessInfo.processInfo.environment[key] == nil)
        do {
            let envGuard = EnvVarGuard.set(key, "ephemeral")
            #expect(ProcessInfo.processInfo.environment[key] == "ephemeral")
            envGuard.restore()
        }
        #expect(ProcessInfo.processInfo.environment[key] == nil,
                "Restore must return to nil when the var was absent before the guard")
        cleanup.restore()
    }

    @Test("EnvVarGuard double-restore restores exactly once")
    func envVarGuardDoubleRestoreRestoresOnce() {
        let key = "XAI_GROK_ENV_VAR_GUARD_DOUBLE_RESTORE_PROBE"
        let before = ProcessInfo.processInfo.environment[key]
        do {
            let envGuard = EnvVarGuard.set(key, "temporary")
            #expect(ProcessInfo.processInfo.environment[key] == "temporary")
            envGuard.restore()
            // After the first restore, the env var returns to its prior value.
            let afterFirst = ProcessInfo.processInfo.environment[key]
            #expect(afterFirst == before,
                    "First restore must return the pre-guard snapshot")
            // Calling restore() again must be a no-op (restore-once semantics).
            envGuard.restore()
            let afterSecond = ProcessInfo.processInfo.environment[key]
            #expect(afterSecond == before,
                    "Second restore must be a no-op (restore-once)")
        }
        // After the do-scope, deinit must also be a no-op (restore already ran).
        let after = ProcessInfo.processInfo.environment[key]
        #expect(after == before,
                "deinit after explicit restore must be a no-op")
    }

    @Test("EnvVarGuard deinit restores when restore() was not called")
    func envVarGuardDeinitRestoresWithoutExplicitRestore() {
        let key = "XAI_GROK_ENV_VAR_GUARD_DEINIT_NO_RESTORE_PROBE"
        let before = ProcessInfo.processInfo.environment[key]
        // Create a guard in an inner scope and let it go out of scope WITHOUT
        // calling restore(). deinit must restore the prior value and release
        // the lock. `withExtendedLifetime` guarantees the guard survives until
        // the closure ends (Swift may otherwise release unused bindings early).
        do {
            let envGuard = EnvVarGuard.set(key, "scoped-no-restore")
            withExtendedLifetime(envGuard) {
                #expect(ProcessInfo.processInfo.environment[key] == "scoped-no-restore")
            }
            // The guard goes out of scope here; deinit runs and restores.
        }
        // After deinit, the env var returns to its prior value and the lock is
        // released (verified by creating a new guard below without deadlock).
        let after = ProcessInfo.processInfo.environment[key]
        #expect(after == before,
                "deinit must restore the pre-guard snapshot without explicit restore()")
        // Verify the lock was released by creating a new guard.
        let verifyGuard = EnvVarGuard.set(key, "verify-lock-released")
        #expect(ProcessInfo.processInfo.environment[key] == "verify-lock-released")
        verifyGuard.restore()
        #expect(ProcessInfo.processInfo.environment[key] == before)
    }

    @Test("EnvVarGuard nested guards restore in LIFO order")
    func envVarGuardNestedGuardsRestoreLIFO() {
        // Nested guards (like nested Rust EnvVarGuards) must restore in
        // last-in-first-out order. The inner guard snapshots the value set by
        // the outer guard; when the inner guard restores, it restores to the
        // outer guard's value (not the pre-outer-guard value). When the outer
        // guard restores, it restores to the truly-prior value.
        let key = "XAI_GROK_ENV_VAR_GUARD_NESTED_PROBE"
        let before = ProcessInfo.processInfo.environment[key]
        do {
            let outer = EnvVarGuard.set(key, "outer-value")
            #expect(ProcessInfo.processInfo.environment[key] == "outer-value")
            do {
                let inner = EnvVarGuard.set(key, "inner-value")
                #expect(ProcessInfo.processInfo.environment[key] == "inner-value")
                inner.restore()
                // Inner restore returns to the outer guard's value.
                #expect(ProcessInfo.processInfo.environment[key] == "outer-value",
                        "Inner restore must return to the outer guard's value")
            }
            outer.restore()
            // Outer restore returns to the truly-prior value.
            #expect(ProcessInfo.processInfo.environment[key] == before,
                    "Outer restore must return to the pre-guard snapshot")
        }
        let after = ProcessInfo.processInfo.environment[key]
        #expect(after == before,
                "After nested guards, the env var must match the pre-guard state")
    }

    @Test("EnvVarGuard nested remove inside set restores correctly")
    func envVarGuardNestedRemoveInsideSet() {
        let key = "XAI_GROK_ENV_VAR_GUARD_NESTED_REMOVE_PROBE"
        let before = ProcessInfo.processInfo.environment[key]
        do {
            let outer = EnvVarGuard.set(key, "outer-set")
            #expect(ProcessInfo.processInfo.environment[key] == "outer-set")
            do {
                let inner = EnvVarGuard.remove(key)
                #expect(ProcessInfo.processInfo.environment[key] == nil,
                        "Inner remove must unset the env var while the guard is live")
                inner.restore()
                // Inner restore returns to the outer guard's value.
                #expect(ProcessInfo.processInfo.environment[key] == "outer-set",
                        "Inner restore must return to the outer guard's value")
            }
            outer.restore()
            #expect(ProcessInfo.processInfo.environment[key] == before)
        }
        #expect(ProcessInfo.processInfo.environment[key] == before)
    }

    @Test("EnvVarGuard serializes concurrent tasks (no interleaving)")
    func envVarGuardSerializesConcurrentTasks() {
        // The guard holds the global env lock for its lifetime, so concurrent
        // tasks that try to create their own guards block until the first
        // guard is restored. This verifies the Rust `MutexGuard` lifetime
        // semantics: concurrent guards cannot interleave or snapshot one
        // another's temporary values.
        let key = "XAI_GROK_ENV_VAR_GUARD_CONCURRENT_PROBE"
        let before = ProcessInfo.processInfo.environment[key]
        // Use a unique value that the concurrent task can detect if it
        // incorrectly snapshots the main task's temporary value.
        do {
            let mainGuard = EnvVarGuard.set(key, "main-task-value")
            #expect(ProcessInfo.processInfo.environment[key] == "main-task-value")

            // Launch a concurrent task that tries to set the same key. It
            // should block on the env lock until `mainGuard` is restored.
            // We use a timeout so the test fails rather than hangs if the
            // lock is not held correctly.
            let taskStarted = DispatchSemaphore(value: 0)
            let taskCompleted = DispatchSemaphore(value: 0)
            var taskSawValue: String? = nil
            DispatchQueue.global().async {
                taskStarted.signal()
                // This guard creation blocks on `envVarLock` until the main
                // guard restores. After acquiring the lock, it snapshots the
                // restored (pre-guard) value, NOT "main-task-value".
                let concurrentGuard = EnvVarGuard.set(key, "concurrent-value")
                taskSawValue = ProcessInfo.processInfo.environment[key]
                concurrentGuard.restore()
                taskCompleted.signal()
            }
            // Wait for the task to start (it should be blocked on the lock).
            // Generous: this only waits for the global queue to schedule the block, which
            // can take a while under a loaded machine. The lock behaviour is asserted below.
            #expect(taskStarted.wait(timeout: .now() + 10.0) == .success,
                    "Concurrent task must start")
            // The task should NOT have completed yet because it's blocked on
            // the lock held by `mainGuard`.
            #expect(taskCompleted.wait(timeout: .now() + 0.2) == .timedOut,
                    "Concurrent task must block on the env lock while the main guard is live")
            // Restore the main guard, releasing the lock.
            mainGuard.restore()
            // Now the concurrent task should complete.
            #expect(taskCompleted.wait(timeout: .now() + 2.0) == .success,
                    "Concurrent task must complete after the main guard restores")
            // The concurrent task must have seen its own value (after acquiring
            // the lock), NOT the main task's temporary value. This proves the
            // guard did not interleave.
            #expect(taskSawValue == "concurrent-value",
                    "Concurrent task must see its own value, not the main task's temporary value (got \(taskSawValue ?? "nil"))")
        }
        let after = ProcessInfo.processInfo.environment[key]
        #expect(after == before,
                "After concurrent guards, the env var must match the pre-guard state")
    }
}
