// OpenGrokTestSupport.swift
//
// Open Grok — Swift port of `xai-grok-test-support` (Rust crate
// `crates/codegen/xai-grok-test-support`). Provides the shared hermetic
// test infrastructure consumed by every later wave's integration tests:
//
//   * `EnvGuard` — RAII environment-variable snapshot/restore for serial tests.
//   * `grokBinary()` / `gitWorkdir()` — binary resolution + temp git repo.
//   * `applyTestEnv` — the canonical hermetic env for spawned `open-grok`
//     subprocesses (isolated HOME/USERPROFILE/OPENGROK_HOME + mock endpoints
//     + telemetry kill-switches).
//   * `MockInferenceServer` — `/v1/chat/completions`, `/v1/responses`,
//     `/v1/messages`, `/v1/models`, `/v1/settings`, `/v1/user`, `/v1/storage`
//     on `127.0.0.1:0`, with echo/fixed/scripted response modes and request
//     logging.
//   * `SseEvent` / `ScriptedResponse` — data-only wire fixtures.
//   * SSE event generators (chat/responses/messages/reasoning/doom-loop).
//   * `GrokStdioClient` / `RawStdioClient` — ACP stdio subprocess drivers.
//   * `runHeadless` — `open-grok -p` subprocess runner with timeout/crash
//     detection.
//   * `spawnCountingServer` — connection-counting HTTP/1.1 server for
//     wire/pooling tests.
//   * `LeaderStdioClient` / `UdsProxy` — Unix-only leader-mode + fault-
//     injection proxy for leader IPC sockets.
//
// W0-S2 acceptance: every helper here creates isolated HOME, USERPROFILE, and
// OPENGROK_HOME directories (via the local `TestHome` type) and refuses paths
// resolving to the real `~/.opengrok`. No slice other than W0-S2 may edit
// this directory.
//
// Rust crate mapping: `xai-grok-test-support` → `OpenGrokTestSupport` (see
// `CRATE_MAP.md` row 56). This target is dependency-free (matching the Rust
// crate's independence from `xai-test-utils`); the `OpenGrokTestUtilities`
// target provides the canonical `HermeticEnv` for consumers that depend on
// it directly.

import Foundation

/// Public surface marker for `OpenGrokTestSupport`.
public enum OpenGrokTestSupport {
    /// The Open Grok module name, for diagnostic use by downstream tests.
    public static let moduleName = "OpenGrokTestSupport"
}
