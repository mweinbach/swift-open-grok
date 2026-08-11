# S12 — Diagnostics XTVERSION injectable probe

**Status**: COMPLETE  
**Date**: 2026-08-10  
**Owner files**: `Sources/OpenGrokDiagnostics/XtversionCollector.swift`, `Tests/OpenGrokDiagnosticsTests/XtversionCollectorTests.swift`

## What was delivered

Injectable XTVERSION collector porting `xai-grok-pager-render/src/terminal/xtversion.rs` (38-65, gate, sanitize_payload) at reference 650c1db7.

### Components

1. **`XtversionCollector` protocol** — injectable seam with `collect(context:) -> RuntimeEvidence<String?>`.
2. **`sanitizeXtversionPayload(_:)`** — shared payload sanitizer (strips control characters, trims, returns nil for empty). Shareable with the pager's event-loop filter once that lands.
3. **`gateAllowsXtversionProbe(_:)`** — brand allowlist (Unknown, Kitty, WezTerm, Ghostty, iTerm2, Rio) gated by `MultiplexerKind.interceptsCsiQueries`.
4. **`MultiplexerKind.interceptsCsiQueries`** — new computed property (tmux, screen, zellij, herdr = true; cmux, undetected = false).
5. **`LiveXtversionCollector`** — bounded synchronous probe (CSI > 0 q → DCS > | payload ST) with 2 s VTIME timeout, reports `.unavailable` outside TTY or when gate rejects.
6. **`UnavailableXtversionCollector`** — always returns `.unavailable` (standalone/non-TTY fallback).
7. **`PrerecordedXtversionCollector`** — injects pre-collected OnceLock result from pager event loop (doctor-in-TUI path).

### Tests (all pass)

- Payload sanitizer: plain passthrough, control stripping, empty → nil
- Gate logic: allowlisted brands, transparent mux (cmux), CSI-intercepting rejection, non-allowlisted rejection
- Collector behavior: UnavailableXtversionCollector always unavailable, PrerecordedXtversionCollector injects payload/nil/unavailable, LiveXtversionCollector gate rejection

### How standalone doctor stays honest

`DiagnosticRuntimeEvidence.unavailable` (already landed) means the XTVERSION probe note appears as "unavailable" in the report and the "Some checks only run in Grok" CTA still fires. No behavioral change to existing doctor output.

## Integration path (for lead)

The `LiveComposition.swift` doctor-in-TUI path needs to inject the collector into `DiagnosticRuntimeEvidence`. The diff:

```swift
// In the TUI doctor path where DiagnosticRuntimeEvidence is assembled:
// Replace:
//   xtversion: .unavailable
// With:
let xtversionCollector: any XtversionCollector = PrerecordedXtversionCollector(
    payload: /* read from pager's xtversion OnceLock equivalent */
)
let xtversionEvidence = xtversionCollector.collect(context: terminalContext)

// Then:
//   xtversion: xtversionEvidence
```

For the standalone CLI doctor path (already using `DiagnosticRuntimeEvidence.unavailable`): no change needed. If a future slice wants the standalone doctor to probe live, swap `UnavailableXtversionCollector()` for `LiveXtversionCollector()` in the standalone path.

## Verification

```
zsh workflows/swift-safe-verify.zsh build --target OpenGrokDiagnostics  → Build complete! (2.18 sec)
swift build --build-path .build/diag-test --product OpenGrokDiagnosticsTests → Build complete! (9.60 sec)
xcrun xctest .build/diag-test/.../OpenGrokDiagnosticsTests.xctest → 121 tests, 0 failures
```

## Pre-existing issues (not mine)

- `OpenGrokWorkflowTests/LegacyWorkflowProductionImportTests.swift` — "static member cannot be used on instance" errors block `build-tests` and `swift test --filter`. Unrelated to this slice.
- `OpenGrokJavaScriptRuntime/JavaScriptModuleLoader.swift:103` — `Result<String, String>` where `String` doesn't conform to `Error`. Blocks `--target OpenGrokCLI` full build. Unrelated.
