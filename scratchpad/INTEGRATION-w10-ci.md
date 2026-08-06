# W10 Integration Note — CI slice

Owner: CI slice (`.github/workflows/ci.yml`,
`Sources/OpenGrokCrashHandlerC/opengrok_crash_posix.c`, this note).
No SwiftPM/build/test commands were run; all findings are from read-only
`gh run list` / `gh run view` / `gh api` queries and source inspection.
Reference clone `~/Projects/grok-build` treated as read-only.

## Integration-owner update

- The owned Bash/`pipefail` workflow change and preserved `_GNU_SOURCE` fix are
  in the integrated worktree.
- Local macOS verification is green: build, build-tests, 3,325 tests / 554
  suites serialized, and the `open-grok` product build all exit 0.
- No new platform CI run was observed after these edits. Windows `/bin/sh`,
  macOS BuildSupport CI termination, and non-blocking platform jobs remain open.

## CI evidence recovered (2026-08-06)

Latest run: **31062760767** (commit `da87bea`, "Make the sandbox NUL-in-root
guard actually fire"). Per-step conclusions pulled via
`gh api repos/:owner/:repo/actions/runs/31062760767/jobs`.

| Job | Conclusion | Honest? |
|---|---|---|
| Linux (build + test) | "success" | **No — masked failure** |
| Windows (build + test) | failure | yes (Build step) |
| macOS (build + test) | failure | yes (Test (serial gate) step) |

### 1. Linux: real compile failure masked by a log-trimming pipe (FIXED in ci.yml)

Run 31062760767 Linux log, all three steps:

```
Sources/OpenGrokCrashHandlerC/opengrok_crash_posix.c:161:48: error: use of undeclared identifier 'REG_RIP'
Sources/OpenGrokCrashHandlerC/opengrok_crash_posix.c:162:48: error: use of undeclared identifier 'REG_RBP'
2 errors generated.
... error: fatalError
```

Yet Build / Build tests / Test all concluded **success**. Cause: the steps
run `swift build 2>&1 | tail -200`, and the container's step shell ran
without `pipefail`, so the pipeline exit status was `tail`'s (0). This is
the exact "succeeds, does nothing, says nothing" class from AGENTS.md §3:
the Linux job has never honestly reported a result since it was added.

**Fix landed (owned file):** job-level `defaults.run.shell: bash` on the
Linux job. GitHub's `bash` keyword is documented as
`bash --noprofile --norc -eo pipefail {0}`; the Ubuntu-based
`swift:6.1-jammy` image ships bash. The `| tail -200` pipes are kept (they
only trim volume) and are now honest. The comment on the setting records
the cost (image losing /bin/bash would fail the first step loudly, which is
the intended direction of failure). Windows and macOS jobs needed no
equivalent change: Windows steps have no pipes and correctly reported their
failure; macOS runs the wrapper unpiped.

### 2. The uncommitted `_GNU_SOURCE` fix — reviewed, preserved verbatim

`Sources/OpenGrokCrashHandlerC/opengrok_crash_posix.c` carries an
uncommitted change (not made by this slice; preserved untouched):

```c
#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE 1
#endif
```

placed before every `#include`, with a comment naming the cost (must stay
above all includes or x86_64 Linux silently breaks again).

Verdict: **correct, minimal, and exactly addresses CI failure #1's root
cause.** glibc gates the `REG_RIP`/`REG_RBP` gregs indices behind
`__USE_GNU` (i.e. `_GNU_SOURCE` defined before the first system header);
the CI errors at former lines 161–162 are precisely those two identifiers,
and they were the *only* Linux errors in the log. The `!defined(_GNU_SOURCE)`
guard avoids redefinition if the toolchain ever predefines it. No edit made.

Parity citation (read-only reference): the C extraction mirrors Rust
`crates/codegen/xai-crash-handler/src/handler.rs`:
- x86_64 Linux: `gregs[libc::REG_RIP]` / `gregs[libc::REG_RBP]` —
  `handler.rs:41-47`
- aarch64 Linux: `mc.pc` / `mc.regs[29]` — `handler.rs:50-56`
The Rust `libc` crate exposes `REG_RIP`/`REG_RBP` unconditionally, so the
reference has no feature-macro problem; `_GNU_SOURCE` is the C-side
equivalent and not a divergence.

### 3. Windows failure — diagnosis for handoff (NOT an owned file)

Run 31062760767 Windows Build step:

```
error: command Generate OpenGrokVersion from GROK_VERSION=0.1.220-open-grok.21
failed: unable to spawn process '\bin\sh' (The system cannot find the path specified.)
```

Root cause: `Plugins/OpenGrokVersionBuildPlugin/OpenGrokVersionBuildPlugin.swift:107`
hardcodes `executable: Path("/bin/sh")` with a heredoc script (line 102) to
write `CompiledVersion.generated.swift`. No `/bin/sh` exists on Windows, so
the build dies in the first build step; Build tests / Test were skipped, so
nothing further is known about the Windows tree.

Proposed fix for the plugin owner: don't spawn a shell at all. The plugin
already computes the full file contents in process; write
`outputFile` directly from `createBuildCommands` (pluginWorkDirectory is
plugin-writable) and return no commands, or gate the executable per-OS.
Direct write is the standard cross-platform pattern and keeps the checked-in
`Sources/OpenGrokVersion/CompiledVersion.generated.swift` exclude semantics
(`Package.swift:142-146`) unchanged. Owner: whoever owns `Plugins/` this
wave — not edited here.

### 4. macOS gate failure — diagnosis for handoff (NOT an owned file)

The serial test step dies mid-suite **deterministically** at the same test
in both recent runs:

- Run 31062760767: `◇ Test "DefaultProtoCompiler falls back to PATH lookup"
  started.` 01:38:01.5035 → `##[error]Process completed with exit code 1.`
  01:38:01.5134 (10 ms later, no pass/fail line).
- Run 31060770149: same test started 01:02:39.5833 → exit 1 at
  01:02:39.6102 (27 ms later).

Test: `defaultProtoCompilerPathFallback`,
`Tests/OpenGrokBuildSupportTests/OpenGrokBuildSupportTests.swift:284-297`.
The test itself is pure filesystem + injected closures
(`validateCandidates: false`, so no `Process` spawn; `pathLookup` returns a
placeholder URL). Exit code 1 with the event stream truncated mid-test is
consistent with the test process exiting/crashing without flushing (e.g. a
bare `exit(1)` or a fatal signal with buffered-output loss), not with a
recorded test failure. Mechanism undetermined from logs alone.

Ruled out by inspection: `isStrictEnvironment` reads only the injected
environment dict (`ProtoBuildSupport.swift:284-289`), so the CI
`GITHUB_ACTIONS` env var cannot flip these tests into strict mode; the
parent walk terminates at the filesystem root; ACP golden failures from run
31060770149 (`ACPStdioWireGoldenTests.swift:155`) passed in run 31062760767
and are not implicated in the death. Earlier run 31058466796 failed
differently (macOS *build* error mid-`OpenGrokSampler`), since superseded.

Suggested first reproduction step for the integration owner:
`zsh workflows/swift-safe-verify.zsh test --no-parallel --filter OpenGrokBuildSupportTests`
(verify the reported test count is non-zero), then check
`log show --last 10m --predicate 'process CONTAINS "swiftpm-testing-helper"'`
and `~/Library/Logs/DiagnosticReports/` for the crash/exit record.
Owner: whoever owns `Sources/OpenGrokBuildSupport/` +
`Tests/OpenGrokBuildSupportTests/` — not edited here.

### 5. `continue-on-error` — deliberately untouched

Both platform jobs keep `continue-on-error: true`. Linux's single "success"
was the pipe artifact above, not an observed green gate; Windows has never
reached Build tests. The instruction "Do not flip `continue-on-error` off
unless a real platform job is observed passing" is satisfied by no flips.
Re-evaluation belongs to a future run that is *honestly* green (possible
for Linux once the `_GNU_SOURCE` commit lands, modulo risk R1).

## Owned-file changes in this slice

1. `.github/workflows/ci.yml` — added `defaults.run.shell: bash` to the
   Linux job with a cost-documenting comment (fix for masking, §1). No
   other job touched. YAML re-validated with a parser after the edit.
2. `Sources/OpenGrokCrashHandlerC/opengrok_crash_posix.c` — **no edit**;
   pre-existing uncommitted `_GNU_SOURCE` fix reviewed and preserved (§2).
3. No crash/platform test changes needed: `Tests/OpenGrokCrashHandlerTests/`
   is already `#if os(macOS) || os(Linux)`-gated and compiles the C target
   through the live seam; the fix is compile-time only, behavior unchanged.

## Unresolved risks

- **R1 (Linux):** the masked pipe means nothing downstream of the crash
  handler's compile failure was ever exercised on Linux. Once the
  `_GNU_SOURCE` commit lands, later targets or `swift test` may still fail.
  Expect the next honest Linux run to surface a fresh gap list — that is
  the job working as intended, not a regression.
- **R2 (Windows):** after the plugin fix, Windows has never compiled the
  tree at all; expect a wave of adapter gaps (ConPTY, Credential Manager,
  LockFileEx, ReadDirectoryChangesW per PORT_PLAN's platform strategy).
- **R3 (macOS):** the BuildSupport death is deterministic on CI and
  unreproduced locally per PORT_STATUS's green local suite; if it is an
  environment-sensitive `exit(1)`-class bug it will keep blocking the one
  gating job until the owner reproduces it.

## Recommended wrapper verification commands (integration owner only)

```sh
git diff --check
zsh workflows/swift-safe-verify.zsh build
zsh workflows/swift-safe-verify.zsh build-tests
zsh workflows/swift-safe-verify.zsh test --no-parallel   # check reported test count, not exit code
zsh workflows/swift-safe-verify.zsh build --product open-grok
zsh workflows/swift-safe-verify.zsh test --no-parallel --filter OpenGrokBuildSupportTests  # R3 repro (non-zero count!)
```

Post-push, confirm the Linux step shells report `bash` and honestly fail or
pass: `gh run view --log | grep -E "Linux.*(REG_RIP|error:)"`.

## Proposed PORT_STATUS.md ledger text (for the integration owner to land)

> **CI (wave 10, 2026-08-06):** Linux job honesty fixed: `swift build 2>&1
> | tail -200` ran without `pipefail` in the `swift:6.1-jammy` container, so
> a failing build exited 0 through `tail` and the job reported green while
> `OpenGrokCrashHandlerC` failed to compile (`REG_RIP`/`REG_RBP`
> undeclared; run 31062760767 showed "2 errors generated" in all three
> steps, all concluded "success"). Linux job now sets
> `defaults.run.shell: bash` (documented `--noprofile --norc -eo
> pipefail`). Root cause of the compile failure is the uncommitted
> `_GNU_SOURCE` fix in `opengrok_crash_posix.c` (glibc gates the gregs
> indices behind `__USE_GNU`; parity: xai-crash-handler `handler.rs:41-47`,
> `:50-56`). Both platform jobs remain `continue-on-error: true` — Linux's
> lone "success" was this pipe artifact, not an observed green gate.
> Windows build fails in `OpenGrokVersionBuildPlugin` (`/bin/sh` hardcoded,
> spawn fails on Windows) — handed off to the plugin owner with a proposed
> in-process write fix. macOS gate dies deterministically mid-process at
> `defaultProtoCompilerPathFallback` (runs 31062760767, 31060770149) —
> handed off to the BuildSupport owner; mechanism undetermined from logs.

## Rust reference citations

- `~/Projects/grok-build/crates/codegen/xai-crash-handler/src/handler.rs:41-47`
  — x86_64 Linux `gregs[REG_RIP]` / `gregs[REG_RBP]` (the identifiers the C
  port needs `_GNU_SOURCE` for).
- `~/Projects/grok-build/crates/codegen/xai-crash-handler/src/handler.rs:50-56`
  — aarch64 Linux `uc_mcontext.pc` / `regs[29]`.
- `~/Projects/grok-build/crates/codegen/xai-crash-handler/src/handler.rs:372-374`,
  `:391` — frames[0] = crash PC, frame walk gated on non-zero PC/FP (matches
  the C port's write-two-passes structure; unchanged by this slice).
