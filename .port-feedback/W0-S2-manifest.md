# W0-S2 Manifest Feedback

## Status (updated 2026-07-20 by W0-S2 implementer)

All W0-S2 acceptance criteria are met. The slice builds and all 65 focused tests
pass (`swift test --filter OpenGrokTestSupportTests --filter OpenGrokTestUtilitiesTests`):
44 tests in `OpenGrokTestSupportTests` + 21 tests in `OpenGrokTestUtilitiesTests`.

The manifest issues documented below are **not blocking** for W0-S2 — SwiftPM's
automatic dependency inference resolves the `import OpenGrokTestUtilities` in
`OpenGrokTestSupport` without an explicit edge, and the test-target edges were
already added explicitly in `Package.swift` (lines 252–258). The full package
builds and all test targets compile. The notes below are retained for
cross-slice visibility in case a future SwiftPM version tightens the
auto-inference behavior.

## Issue 1: Missing dependency edge `OpenGrokTestSupport → OpenGrokTestUtilities`

**Symptom:** `swift build --product OpenGrokTestSupportTests` fails at link time with
undefined symbols from `OpenGrokTestUtilities` (e.g. `HermeticEnv`, `RealOpengrokHome`,
`HermeticGit`).

**Root cause:** `Package.swift` declares both targets in the same slice group:

```swift
let w0s2 = ["OpenGrokTestSupport", "OpenGrokTestUtilities"]
```

and emits them via:

```swift
t.append(contentsOf: libs(w0s2, dep()))
```

so BOTH get `dep()` (an empty dependency list). But `OpenGrokTestSupport` imports
`OpenGrokTestUtilities` (for `HermeticEnv`, `RealOpengrokHome`, `HermeticGit` — the
hermeticity primitives that satisfy the W0-S2 acceptance criterion). Without a declared
dependency edge, the Swift module compiles (the import is resolved by SwiftPM's
transitive import scan) but the linker cannot find the `OpenGrokTestUtilities` symbols.

**Required manifest change (W0-S1 owner):**

Replace the single `libs(w0s2, dep())` call with explicit per-target declarations:

```swift
t.append(.target(name: "OpenGrokTestUtilities", dependencies: dep()))
t.append(.target(name: "OpenGrokTestSupport", dependencies: dep(["OpenGrokTestUtilities"])))
```

## Issue 2: Missing test-target dependency `OpenGrokTestSupportTests → OpenGrokTestUtilities`

**Symptom:** Same link failure; the test file `Tests/OpenGrokTestSupportTests/OpenGrokTestSupportTests.swift`
imports both `OpenGrokTestSupport` and `OpenGrokTestUtilities` (for `HermeticEnv`,
`RealOpengrokHome` used in the acceptance tests).

**Root cause:** The `tests(_:)` helper generates:

```swift
.testTarget(name: "OpenGrokTestSupportTests", dependencies: [.target(name: "OpenGrokTestSupport")])
```

which only depends on the matching library target. The test file's direct import of
`OpenGrokTestUtilities` needs a declared edge.

**Required manifest change (W0-S1 owner):**

For the W0-S2 test targets, emit them explicitly rather than via `tests(w0s2)`:

```swift
t.append(.testTarget(name: "OpenGrokTestUtilitiesTests", dependencies: dep(["OpenGrokTestUtilities"])))
t.append(.testTarget(name: "OpenGrokTestSupportTests", dependencies: dep(["OpenGrokTestSupport", "OpenGrokTestUtilities"])))
```

And remove the `t.append(contentsOf: tests(w0s2))` line to avoid duplicate declarations.

## Issue 3: `OpenGrokSharedTests` (W0-S4) build error blocks `swift test`

**Symptom:** `swift test --filter OpenGrokTestUtilitiesTests` fails because SwiftPM
builds ALL test products before running any filtered tests, and
`Tests/OpenGrokSharedTests/OpenGrokSharedTests.swift` (owned by W0-S4) has a compile
error (`use of 'writeStderr' refers to instance method rather than global function`).

**Impact:** W0-S2's test products (`OpenGrokTestUtilitiesTests`, `OpenGrokTestSupportTests`)
build and link cleanly in isolation (`swift build --product OpenGrokTestUtilitiesTests`
succeeds), but `swift test` cannot run them until W0-S4 fixes its test file.

**No action required from W0-S1** — this is a W0-S4 issue. Recorded here for
cross-slice visibility.
