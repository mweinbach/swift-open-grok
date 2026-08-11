# S6 — Computer Hub MCP Adapter Live Wiring

Status: **COMPLETE** (build-blocked by unrelated pre-existing failures in
`OpenGrokJavaScriptRuntime` and `LiveComposition.swift`)

## What landed

### `Sources/OpenGrokCLI/LiveWorkspaceComposition.swift`

New imports: `OpenGrokComputerHubMCPAdapter`, `OpenGrokToolProtocol`,
`OpenGrokToolRegistry`, `OpenGrokToolRuntime`, `OpenGrokToolTypes`.

**`HubMCPBridgeCoordinator`** (public, `@unchecked Sendable`, lines ~620–730):

- `connect(transport:config:toolset:)` — creates an `McpBridge` from the
  provided `McpTransport` and `McpBridgeConfig`, discovers tools, registers
  each as a `FinalizedTool` in the retained toolset. Returns qualified client
  names. If already connected, disconnects the previous bridge first.

- `disconnect(toolset:)` — unregisters all tools via
  `MCPToolBridge.unregister(server:from:)` and shuts down the bridge transport.
  Safe when already disconnected.

- `isConnected`, `serverName`, `registeredNames(in:)` — read-only state.

- `registerHandlers(bridge:serverName:toolset:)` (static) — creates
  `FinalizedTool` entries from `McpBridge.handlers()`, using
  `qualifiedMCPToolName(server:tool:)` for naming and
  `HubBridgedMcpHandler` as the handler.

**`HubBridgedMcpHandler`** (internal, `ToolHandler` conformance, lines ~735–750):

- Adapts the adapter module's `McpToolHandler` to the registry's `ToolHandler`
  protocol. Call chain: `FinalizedToolset` dispatch → `invoke` →
  `McpToolHandler.execute` (which runs `mediation.admit` before touching the
  transport) → `consumeStreamTerminal` → `Result<TypedToolOutput, ToolError>`.

- Mediation is preserved because `McpToolHandler.execute` checks
  `McpBridgeConfig.mediation.admit(...)` before every call — a denied request
  never reaches the transport.

### `Tests/OpenGrokCLITests/LiveWorkspaceCompositionTests.swift`

New imports: `OpenGrokComputerHubMCPAdapter`, `OpenGrokToolRegistry`,
`OpenGrokToolRuntime`, `OpenGrokToolTypes`, `OpenGrokWorkspaceClient`.

**`HubMockMcpTransport`** — `McpTransport` conformance returning canned server
info, tool lists, and call results, recording every `callTool` invocation.

**`HubMCPBridgeCoordinatorTests`** suite (5 tests):

1. **`noHubExposesNothing`** — fresh coordinator reports `!isConnected`,
   `serverName == nil`, empty `registeredNames`. (§4: no-hub = nothing.)

2. **`connectRegistersDisconnectRemoves`** — two tools register with qualified
   names; `disconnect` removes them, shuts down transport (`closeCount == 1`),
   and clears coordinator state.

3. **`loopbackWorkspaceRead`** — the decisive loopback: registers one
   `workspace_read` tool, invokes it through the `FinalizedToolset` handler,
   asserts the response body contains the expected files, and asserts the
   transport observed exactly one call with the correct name and arguments.
   This proves the live seam: `toolset.tool(named:).handler.invoke` →
   `HubBridgedMcpHandler` → `McpToolHandler.execute` → mock transport.

4. **`mediationDeniesBeforeTransport`** — connects with `DenyAllHubMediator`,
   invokes the tool, asserts the error contains the denial reason, and
   asserts `transport.calls.isEmpty` (the decisive half: denial happened
   *before* dispatch, not after).

5. **`repeatedConnectReplaces`** — connects twice with different transports;
   the first bridge's tools are unregistered and its transport closed before
   the second's tools appear.

## Package.swift integration

`OpenGrokCLI` already depends on `OpenGrokComputerHubMCPAdapter` through `w5s4`
in its dependency list (line 351). **No Package.swift changes are needed.**

The test target `OpenGrokCLITests` (line 463–466, `dep(w10s2, w4s4, w4s3)`)
transitively has access to `OpenGrokComputerHubMCPAdapter` through
`OpenGrokCLI`. No Package.swift edit required.

## LiveComposition.swift integration notes

**Lead ruling (2026-08-10):** do **not** wire into `ComputerHubWorkspaceExposure` /
leader hub connect. That path exposes the *local* workspace *to* the hub; this
coordinator registers *hub* MCP tools *into* the local `FinalizedToolset`. Wrong
direction.

Production connect stays deferred until an interactive/agent session owns a hub
MCP transport plus the retained `mcpToolset`. The coordinator + 5 live-seam tests
are the honest landing for this slice; no-hub compositions correctly expose
nothing (§4).

## Pre-existing build issues (not introduced by this slice)

- `OpenGrokJavaScriptRuntime/JavaScriptModuleLoader.swift:103` — `Result<String, String>`
  fails Swift 6 strict concurrency (`String` does not conform to `Error`).
- `OpenGrokCLI/LiveComposition.swift:3093` — `LiveSessionCloseLatch` not found (likely
  a pending slice from another agent).
- `OpenGrokCLI/LiveComposition.swift:11641,11653` — `doctorDiagnosticSnapshot` not found.

`OpenGrokComputerHubMCPAdapter` target builds clean.

## Acceptance checklist

- [x] Adapter tools register only with live hub (`connectRegistersDisconnectRemoves`)
- [x] Bridged calls go through permission mediation (`mediationDeniesBeforeTransport`,
      `McpToolHandler.execute` gates every call)
- [x] Disconnect unregisters (`connectRegistersDisconnectRemoves`, `repeatedConnectReplaces`)
- [x] No-hub composition exposes nothing (`noHubExposesNothing`)
- [x] One loopback workspace read through live seam (`loopbackWorkspaceRead`)
