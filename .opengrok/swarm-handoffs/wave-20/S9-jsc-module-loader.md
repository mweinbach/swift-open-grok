# S9 — JSC Module-Loader Abstraction

## Status: COMPLETE

## What landed

A `JavaScriptModuleLoader` abstraction mirroring V8's module resolver
pipeline (`runtime/module_loader.rs`), wired into `JavaScriptCellEngine`
so static import rejection flows through proper resolution and caching
rather than through ad-hoc string formatting.

### New file

- **`Sources/OpenGrokJavaScriptRuntime/JavaScriptModuleLoader.swift`**
  - `JavaScriptModuleSpecifier`: resolved specifier value type carrying
    raw + canonical forms (mirrors V8's specifier + referrer plumbing
    from `resolve_module_callback`, module_loader.rs:164).
  - `JavaScriptModuleLoader`: per-cell loader with:
    - **Specifier resolution**: relative paths (`./`, `../`) normalized
      against the referrer directory; bare specifiers pass through.
      Static method `resolveSpecifier(_:relativeTo:)` for unit testing.
    - **Module cache**: keyed by canonical specifier. Repeated imports of
      the same canonical specifier return the cached result (mirrors V8's
      module-identity dedup).
    - **Load/reject**: `load(_:)` returns `LoadOutcome.rejected(error:)`
      with the exact Rust message `"Unsupported import in exec:
      {specifier}"` (module_loader.rs:228). Cache stores the rejection so
      repeat queries are consistent.
    - `hasResolved(_:)` and `resolvedCount` for test observability.

### Modified files

- **`Sources/OpenGrokJavaScriptRuntime/JavaScriptCellRuntime.swift`**
  - `JavaScriptCellEngine` gains a `moduleLoader` property.
  - `evaluateSource()` routes scanner-discovered specifiers through
    `moduleLoader.resolve()` → `moduleLoader.load()` instead of
    formatting the rejection string inline.
  - `JavaScriptSourceScanner` doc comment updated to reference the
    module loader pipeline.

- **`Tests/OpenGrokJavaScriptRuntimeTests/OpenGrokJavaScriptRuntimeTests.swift`**
  - `JavaScriptModuleLoaderTests` suite (12 tests):
    - 7 specifier resolution tests (bare, node:, relative, parent
      traversal, bare referrer, dot collapse, parent beyond root)
    - 3 cache semantics tests (hit, separation, canonical sharing)
    - 2 rejection message tests (bare, relative)
  - `JavaScriptModuleLoaderIntegrationTests` suite (3 tests):
    - Relative import rejection end-to-end
    - Export rejection end-to-end
    - Dynamic `import()` not treated as static import declaration

## Acceptance checklist

| Criterion | Evidence |
|---|---|
| Relative module import resolution | `resolveSpecifier` normalizes `./` and `../` against referrer directory; 7 unit tests pass |
| Cache/repeat-import semantics | `load()` caches by canonical specifier; 3 cache tests pass |
| Static import/export support as upstream requires | Scanner + loader reject static `import`/`export` matching Rust's `resolve_module`; existing `staticImportsRejected` test + 2 new integration tests pass |
| Unchanged termination behavior | No changes to `JavaScriptExecutionWatchdog` or the ceiling/terminate pipeline; existing termination tests pass (37/37 green) |
| Unsupported import rejected with clear error | Error text `"Unsupported import in exec: {specifier}"` matches Rust verbatim; verified by unit + integration tests |

## Verification

```
$ zsh workflows/swift-safe-verify.zsh build --target OpenGrokJavaScriptRuntime
Build complete! (1.95 sec)

$ xcrun xctest .build/workflow-safe/out/Products/Debug/OpenGrokJavaScriptRuntimeTests.xctest
Test run with 37 tests in 7 suites passed after 0.019 seconds.
```

Note: `swift test --filter` cannot run because a pre-existing compilation
error in `OpenGrokWorkflowTests/LegacyWorkflowProductionImportTests.swift`
(static member used on instance — not related to this slice) blocks
SwiftPM's build-all-test-targets phase. Tests were run via direct `xcrun
xctest` invocation of the compiled test bundle.

## Deliberate divergences

1. **No V8 module compilation.** JavaScriptCore's public API has no
   ES module compile entry point. The cell source continues to run as an
   async IIFE, with static `import`/`export` rejected by source scanning
   before evaluation. The module loader abstraction provides the
   resolution/cache layer that V8's callbacks provide natively.

2. **Dynamic `import()` not intercepted.** V8 has
   `dynamic_import_callback` (module_loader.rs:175); JSC has no public
   equivalent. A dynamic `import()` inside the IIFE falls through to
   JSC's own resolver (which fails because no source provider is
   configured). The error text will differ from Rust's
   `"Unsupported import in exec: {specifier}"`.

3. **`export` rejected.** Rust compiles the cell as a module where
   `export` is valid syntax (though useless since no consumer reads the
   module namespace). This port rejects `export` at the scanner level
   because it would be a syntax error inside the IIFE wrapper.

## Not touched

- `Package.swift`, ledgers, `LiveComposition.swift`, any Batch 1 CLI
  owner files, V8 packaging — all forbidden per the slice contract.
- `Sources/OpenGrokCodeMode/` — no protocol changes needed; the module
  loader is entirely internal to `OpenGrokJavaScriptRuntime`.
