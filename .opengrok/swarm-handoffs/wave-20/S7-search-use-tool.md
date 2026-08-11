# S7 — `search_tool` / `use_tool` MCP meta-tools

**Status:** COMPLETE + lead-wired (2026-08-10)
**Date:** 2026-08-10
**Rust pin:** `650c1db7`

## What landed

### New files
- `Sources/OpenGrokToolRegistry/MCPMetaToolCatalog.swift` — catalog entries, schemas,
  `ToolSearchIndexing` protocol, `ToolSearchIndexResource`/`EnabledNativeToolNames`
  resource wrappers, description truncation/sanitization helpers
- `Sources/OpenGrokToolRegistry/MCPMetaToolHandlers.swift` — `SearchToolHandler` and
  `UseToolHandler` implementations with grouping, dispatch, native-tool correction,
  argument normalization
- `Tests/OpenGrokToolRegistryTests/MCPMetaToolTests.swift` — 26 tests covering
  truncation, sanitization, catalog entries, capability filtering, grouped search
  results, schema inclusion, use_tool dispatch, native-tool corrective error,
  argument normalization, and registry builder integration

### Modified files
- `Sources/OpenGrokToolRegistry/Catalog.swift` — added `mcpMetaTools` to
  `builtinTools` array (always-retained per `builder.rs:2243-2261`)
- `Sources/OpenGrokToolRegistry/Taxonomy.swift` — added `searchTool` and `useTool`
  cases to `ProductToolKind`; `searchTool` marked as readOnly-safe
- `Sources/OpenGrokToolRegistry/CapabilityFilter.swift` — `searchTool` always
  allowed (all modes); `useTool` requires `readWrite` or `execute`

## Acceptance criteria

| Criterion | Evidence |
|---|---|
| Grouped search results with schemas | `SearchToolHandlerTests.groupedByServer` — groups by server, includes `input_schema` |
| `use_tool` dispatch to qualified MCP tool | `UseToolHandlerTests.qualifiedDispatches` — dispatches through `FinalizedToolset.prepareAndCall` |
| Native-tool corrective error | `UseToolHandlerTests.nativeToolCorrective` — returns corrective message for native tool names |
| Capability-mode listing differences | `MCPMetaToolCapabilityTests` — `search_tool` always allowed, `use_tool` blocked in readOnly; `MCPMetaToolRegistryTests.readOnlyDropsUseTool` — `use_tool` absent from finalized readOnly toolset |
| End-to-end visibility after live MCP reconnect | See integration notes below |

## Rust parity cites

| Behavior | Rust file:line |
|---|---|
| Description truncation (2048 chars) | `search_tool/mod.rs:21-28` |
| Description sanitization (newlines) | `search_tool/mod.rs:186-190` |
| SearchTool schema | `search_tool/types.rs:8-17` |
| SearchTool::run grouping/output | `search_tool/mod.rs:208-326` |
| UseTool schema | `use_tool/mod.rs:12-19` |
| UseTool::run dispatch | `use_tool/mod.rs:315-380` |
| Argument normalization | `use_tool/mod.rs:139-148` |
| Native tool correction | `use_tool/mod.rs:320-338` |
| Always-retained in allowlist | `builder.rs:2243-2261` |
| Retention registration | `builder.rs:2279-2295` |

## Build verification

```
$ zsh workflows/swift-safe-verify.zsh build --target OpenGrokToolRegistry
Build complete! (2.05 sec)

$ zsh workflows/swift-safe-verify.zsh build --target OpenGrokToolRegistryTests
Build complete! (2.06 sec)
```

ConfigSpine `.boolean` compile error was fixed by the lead during S8 wiring.

## Lead wiring (2026-08-10)

1. **Handlers:** `SearchToolHandler` on the builder before finalize;
   `UseToolHandler` via new `FinalizedToolset.setHandler(clientName:handler:)`
   after finalize (needs the toolset reference).
2. **`LiveMCPToolSearchIndex`:** production `ToolSearchIndexing` over the live
   MCP toolset; injected as `ToolSearchIndexResource` before finalize; refreshed
   after connect and on ACP MCP mutations (`emitToolsChanged`, auth, add, delete).
3. **`EnabledNativeToolNames`:** non-MCP client names from the finalized toolset.
4. **Profiles:** `search_tool` / `use_tool` restored on `defaultGrokBuild`,
   concise, codex, orchestrator, and opencode (not explore/plan).

## Deliberate divergences

- Search scoring is keyword match (name > description), not BM25. Ranking can
  tighten later without changing the protocol.
- **`use_tool` dispatches through `FinalizedToolset.prepareAndCall`.** Rust uses
  `InnerDispatch`; we use the existing dispatch surface which already handles
  permission evaluation, capping, and error formatting.

## Not done

- Dedicated end-to-end reconnect test for search index refresh
- BM25 ranking parity
