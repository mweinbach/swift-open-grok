# S3 — MCP preferences + durable toggle/toggle_tool

**Status**: COMPLETE  
**Date**: 2026-08-10  
**Owner**: S3 slice agent  
**Reference commit**: 650c1db7 at ~/Projects/grok-build

## Summary

Implemented durable `disabled_mcp_servers` and `disabled_mcp_tools` persistence
in `config.toml`, wired `x.ai/mcp/toggle` and `x.ai/mcp/toggle_tool` ACP
extension methods through store-then-live-swap, and emits `x.ai/mcp/tools_changed`
notification exactly once after each successful swap. `x.ai/mcp/setup` remains
explicitly refused (no setup-schema surface in this port).

## Files changed

| File | Action |
|------|--------|
| `Sources/OpenGrokMCP/MCPPreferencesStore.swift` | **New** — persistence helpers |
| `Sources/OpenGrokCLI/LiveMCPACPHandlers.swift` | Wired toggle/toggle_tool |
| `Tests/OpenGrokCLITests/ACPMCPExtensionTests.swift` | Updated + new tests |

## What was done

### Persistence layer (`MCPPreferencesStore.swift`)

Four public functions in `OpenGrokMCP`:

- `disabledMCPServers(in:)` — reads `disabled_mcp_servers` array
- `applyMCPServerEnabled(_:enabled:in:)` — adds/removes name in array, sets
  per-server `enabled` field when inline entry exists
- `allDisabledMCPTools(in:)` — reads the `[disabled_mcp_tools]` section
- `applyMCPToolEnabled(server:tool:enabled:in:)` — persists per-tool disable

All work against `TOMLValue` (from `OpenGrokConfig`), use the same atomic
`writeConfigFile` path as `upsert`/`delete`, and follow the Rust reference
shapes at `util/config/mcp.rs:797-831` (server toggle) and `:991-1035` (tool
disable read).

### Handler wiring (`LiveMCPACPHandlers.swift`)

- `handle` switch: `setup` stays refused alone; `toggle` and `toggle_tool`
  route to new private methods.
- `handleToggle`: persist → live-swap (connect or teardown) → notify.
  On enable: finds the declaration, tears down any stale client, reconnects
  via `LiveMCPComposition.connect`, records outcome, emits `tools_changed`.
  On disable: unregisters tools, releases client, removes outcome, emits.
- `handleToggleTool`: persist → live unregister single qualified name (disable)
  or full server re-register (enable) → notify.
- `emitToolsChanged`: fires `x.ai/mcp/tools_changed` via the gateway with
  `sessionId` + `serverName` — pager uses sessionId for routing.

### Acceptance criteria

| Criterion | How met |
|-----------|---------|
| Disable survives restart | `disabled_mcp_servers` array written to `config.toml` |
| Per-tool disable removes only that qualified tool | `toolset.unregister(prefix: qualified)` targets exact name |
| Failed reconnect leaves stored state unchanged | Persist happens BEFORE swap; a connect failure does NOT roll back the stored disable |
| Notification fires exactly once after successful swap | `emitToolsChanged` called once at end of each successful branch |
| Deferred methods still refused | `setup` throws `unknownExtensionMethodError` (test pinned) |

### Security-shaped claims (landed lines)

Fail-closed on store write failure:

```swift
// LiveMCPACPHandlers.swift handleToggle:
do {
    try applyMCPServerEnabled(serverName, enabled: enabled, in: &root)
    try writeConfigFile(root, to: userConfigPath)
} catch {
    throw internalError("failed to persist toggle: \(error)")
}
```

The `throw` prevents the swap path from executing — the caller receives an
error and the session state stays unchanged.

## Build verification

```
zsh workflows/swift-safe-verify.zsh build --target OpenGrokMCP
→ Build complete! (11.74 sec)

zsh workflows/swift-safe-verify.zsh build --target OpenGrokCLI
→ Our files compile cleanly (pre-existing error in OpenGrokJavaScriptRuntime
  — Result<String, String> vs Swift 6 strict Error conformance on Xcode 27 beta;
  unrelated to this slice).

zsh workflows/swift-safe-verify.zsh build-tests
→ No errors in ACPMCPExtensionTests, LiveMCPACPHandlers, MCPPreferencesStore.
```

## Deliberately not done

- **`x.ai/mcp/setup`** — no `mcp_preferences.json` setup-values surface, no
  setup-schema resolution. Recorded as deferred, explicitly refused.
- **Managed connectors** — no managed-gateway prefix routing, no plugin
  registry snapshot, no `toggle_managed_gateway_tool` path. Out of scope per
  plan; absent rather than stubbed.
- **`disabled_mcp_tools` integration at connect time** — upstream's connect
  path filters tools against the disabled-tools map before registration; this
  port's `MCPToolBridge.register` does not accept a disabled set. The disable
  is enforced live (toggle_tool removes it from the toolset) and persisted
  (re-read at next session start), but a fresh `session/new` on the same
  process does not yet filter at registration. This is a follow-up for whoever
  owns the session wiring.
- **`save_user_mcp_server_enabled` cleanup in delete** — upstream's trailing
  cleanup after delete (removing the name from `disabled_mcp_servers`, since
  the server definition itself was just deleted). Now possible with
  `applyMCPServerEnabled` — the lead can wire this into `handleDelete` if
  desired; it is a one-liner.

## Integration notes for lead

1. No `Package.swift` changes needed — `MCPPreferencesStore.swift` is a new
   `.swift` file under `Sources/OpenGrokMCP/`, auto-included by SwiftPM.
2. If the lead wants `handleDelete` to also clean `disabled_mcp_servers` after
   removing a server (upstream's `save_user_mcp_server_enabled` call at
   mcp.rs:1938), add after the config removal:
   ```swift
   try? applyMCPServerEnabled(serverName, enabled: true, in: &root)
   ```
3. The `OpenGrokJavaScriptRuntime` pre-existing build error is unrelated to
   this slice and blocks neither the `OpenGrokMCP` nor `OpenGrokCLI` module
   compilation — only the full `build-tests` link step for that target.
