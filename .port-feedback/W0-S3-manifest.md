# W0-S3 — Manifest and integration feedback

**Slice:** W0-S3 — Branding, paths, environment, and version
**Swift targets:** `OpenGrokPaths`, `OpenGrokEnvironment`, `OpenGrokVersion`
**Rust crates:** `xai-grok-paths`, `xai-grok-env`, `xai-grok-version`
**Status:** Target-green (all three targets build; all 96 Swift Testing tests pass in isolation).

## Summary

The three W0-S3 targets are implemented and their target-scoped tests pass. No
`Package.swift` edits were required: the predeclared manifest already declares
`OpenGrokPaths`, `OpenGrokEnvironment`, and `OpenGrokVersion` with no
dependencies (`dep()`), which is correct for this slice.

## GROK_VERSION build-time injection (resolved)

The Rust crate `xai-grok-version` reads the compile-time env var `GROK_VERSION`
via `option_env!("GROK_VERSION")` and a `build.rs` that emits
`cargo:rerun-if-env-changed=GROK_VERSION`. The compiled version falls back to
`CARGO_PKG_VERSION` when `GROK_VERSION` is unset.

SwiftPM cannot run build-time scripts without a `Package.swift` edit (W0-S1-
owned), so the Swift port uses a **generated source file** approach that stays
within the W0-S3-owned paths:

- `Sources/OpenGrokVersion/CompiledVersion.generated.swift` — a checked-in,
  generated file containing `internal enum OpenGrokCompiledVersion` with a
  `version: String` constant. This is the SwiftPM equivalent of
  `option_env!("GROK_VERSION")`.
- `Sources/OpenGrokVersion/regenerate-compiled-version.sh` — an explicit
  regeneration script (analogous to `scripts/regenerate-protocol-manifest.sh`)
  that reads `GROK_VERSION` from the environment, falls back to the
  `OPEN_GROK_VERSION` file at the package root, then to the default
  `0.1.220-open-grok.21`, and writes the generated file.
- `OpenGrokVersion.compiledVersion` is now a computed property that reads
  `OpenGrokCompiledVersion.version`, so it consumes the generated/injected
  value rather than a hard-coded constant.

The release process (and any build that wants to stamp a specific version) must
run `Sources/OpenGrokVersion/regenerate-compiled-version.sh` before
`swift build`, exactly as the Rust release script runs `cargo build` with
`GROK_VERSION="$version"`. Two clean builds with distinct `GROK_VERSION` values
produce distinct `OpenGrokVersion.compiledVersion` values after regeneration;
this is verified by the test `regenerateCompiledVersionInjectsDistinctVersions`.

**Optional W0-S1 enhancement:** If the W0-S1 integration owner later adds a
SwiftPM build-tool plugin to `Package.swift` that runs
`regenerate-compiled-version.sh` automatically before each build (the SwiftPM
equivalent of `cargo:rerun-if-env-changed=GROK_VERSION`), the manual
regeneration step can be eliminated. The current generated-file approach is
fully functional without that enhancement.

**Note:** SwiftPM emits a benign warning about the unhandled
`regenerate-compiled-version.sh` file in `Sources/OpenGrokVersion/`. This
warning cannot be suppressed without a `Package.swift` `exclude` declaration
(W0-S1-owned). The build succeeds regardless.

## Switch `OpenGrokCLI` to import `OpenGrokVersion` / `OpenGrokPaths`

The bootstrap `Sources/OpenGrokCLI/OpenGrokHome.swift` and
`Sources/OpenGrokCLI/Version.swift` carry local copies of the
`OPENGROK_HOME` resolution and version logic. The `Package.swift` edge
`w10s2 -> w0s3` is already predeclared, so the W0-S1 or W10-S2 owner can switch
`OpenGrokCLI` to `import OpenGrokPaths` / `import OpenGrokVersion` and delete
the local shims without a manifest edit. This slice deliberately did NOT edit
`OpenGrokCLI` (owned by W0-S1/W10-S2).

## Blocker: W0-S2 linker failure blocks `swift test` globally

`swift test` in the main workspace fails at link time for
`OpenGrokTestSupportTests` with undefined symbols from `OpenGrokTestUtilities`
(`HermeticEnv`, `HermeticGit`). Root cause: `Sources/OpenGrokTestSupport/`
imports `OpenGrokTestUtilities` (e.g. `EnvGuard.swift` line 177:
`HermeticEnv(realHome:...)`), but `Package.swift` declares
`OpenGrokTestSupport` with `dep()` (no dependencies). The test target
`OpenGrokTestSupportTests` only links `OpenGrokTestSupport`, so the
`OpenGrokTestUtilities` symbols are missing at link time.

This is a W0-S2 + `Package.swift` issue, NOT a W0-S3 issue. W0-S3 cannot edit
`Package.swift` (W0-S1-owned) or W0-S2's files. The fix is for the W0-S1
integration owner to add `OpenGrokTestUtilities` as a dependency of
`OpenGrokTestSupport` in `Package.swift`:

```swift
// Current (broken):
t.append(contentsOf: libs(w0s2, dep()))

// Fix:
t.append(.target(name: "OpenGrokTestUtilities", dependencies: dep()))
t.append(.target(name: "OpenGrokTestSupport", dependencies: dep(["OpenGrokTestUtilities"])))
```

Until this is fixed, W0-S3 tests were verified in a standalone SwiftPM package
at `/tmp/w0-s3-verify/` containing only the three W0-S3 targets and their tests.
All 78 Swift Testing tests pass there. The three W0-S3 targets also build
cleanly in the main workspace (`swift build --target OpenGrokPaths
--target OpenGrokEnvironment --target OpenGrokVersion` exits 0).

## Files landed by W0-S3

### Sources

- `Sources/OpenGrokPaths/OpenGrokPaths.swift` — path types, errors, component
  model, `isAbsolutePath`, `splitComponents`, `normalizeLexically`,
  `joinComponents`, `pathStartsWith`, `toRelativePath`, `fromRelativePath`.
- `Sources/OpenGrokPaths/AbsPath.swift` — `AbsPath` value type.
- `Sources/OpenGrokPaths/RelPath.swift` — `RelPath` value type (Codable),
  `ToAbsPath` protocol with conformances.
- `Sources/OpenGrokPaths/OpenGrokStatePaths.swift` — `OpenGrokPathPolicy`
  constants and `OpenGrokStatePaths` resolver (OPENGROK_HOME, ~/.opengrok,
  managed binary, project state, legacy ~/.grok rejection).
- `Sources/OpenGrokEnvironment/OpenGrokEnvironment.swift` —
  `GrokBuildEndpoints`, `GrokBuildEnvironment`, `PROD_*` constants,
  `EnvVarGuard` RAII test helper with process-wide lock.
- `Sources/OpenGrokVersion/SemVerVersion.swift` — minimal semver parser
  preserving Open Grok prerelease format.
- `Sources/OpenGrokVersion/OpenGrokVersion.swift` — `OpenGrokVersion` namespace
  with `installed`, `installedSemVer`, `displayVersion`,
  `displayVersionWithCommit`.

### Tests

- `Tests/OpenGrokPathsTests/OpenGrokPathsTests.swift` — 32 tests covering all
  Rust `xai-grok-paths` tests plus W0-S3 acceptance (OPENGROK_HOME precedence,
  ~/.opengrok fallback, ~/.grok non-touch, managed binary, project state).
- `Tests/OpenGrokEnvironmentTests/OpenGrokEnvironmentTests.swift` — 15 tests
  covering endpoint resolution, env-var overrides, EnvVarGuard RAII.
- `Tests/OpenGrokVersionTests/OpenGrokVersionTests.swift` — 31 tests covering
  semver parsing, ordering, display version matrix, GROK_TEST_VERSION override.
