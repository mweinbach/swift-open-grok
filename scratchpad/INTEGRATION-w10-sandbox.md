# INTEGRATION-w10-sandbox.md

Wave 10 — SANDBOX slice. Scope: `Sources/OpenGrokSandbox/`,
`Tests/OpenGrokSandboxTests/`, this note. No Package.swift, CI, crash-handler,
ACP, share/export, or ledger edits. SwiftPM not run (root agent owns
verification); tree kept compiling by inspection.

Reference: `~/Projects/grok-build` @ `9ed09e2ac3a2fd9147c7049ef4d75dcdcbd8fa05`
(read-only).

## Integration-owner update (supersedes sections 4 and Finding B)

- `OpenGrokShellBase` now depends on `OpenGrokSandbox`, and
  `LocalShellProcessBackend` applies the launch transform after command
  preparation and before `Process` construction. Its reachability test passes.
- The parsed CLI sandbox profile now reaches `LiveSandboxComposition.bootstrap`;
  an argv/environment precedence test proves CLI `off` overrides env `strict`.
- Linux arming remains open exactly as section 5 records: process-wide apply
  still requires bubblewrap re-exec, so normal non-off Linux CLI launches fail
  before the child network transform can arm.
- The macOS process-level network over-denial finding remains open and was not
  weakened in this integration.
- Root verification: shell base 16/3, live sandbox propagation 1/1, sandbox
  policies 35/2 on macOS; full serialized suite green.

---

## 1. Mechanism decision (from the Rust reference)

**Chosen: re-exec the child launch through `unshare(1)` network denial at the
spawner. Rejected: in-process seccomp C shim.**

What upstream actually does (verified, not from memory):

- `xai-grok-sandbox/src/child_net.rs:143-213` —
  `install_child_network_filter()`: classic-BPF filter, `EPERM` for
  connect/bind/sendto/sendmsg/listen/accept/accept4, installed via
  `prctl(PR_SET_NO_NEW_PRIVS)` + `prctl(PR_SET_SECCOMP)` **after fork, before
  exec**.
- Wired at every known Linux launch via `cmd.pre_exec`:
  `xai-grok-shell/src/terminal/streaming_local_terminal.rs:917-921`;
  `xai-grok-tools/src/computer/local/terminal.rs:711-714, 831-834, 3200-3203`.
- Armed only when the process sandbox applied *and* the profile restricts
  network: `lib.rs:80-85` (`restrict_network_at_known_linux_launches(applied,
  configured) = applied && configured && cfg!(linux)`), fed by
  `SandboxManager::apply` success + `resolved.restrict_network`
  (`lib.rs:~183-190, 268-271`).
- `unshare` appears upstream only as **attack surface**: the namespace
  lockdown seccomp must EPERM it (`tests/deny_paths_e2e.rs:574-602`,
  `child_net.rs:58-89`). Upstream never uses `unshare --net` to enforce.

Why the parity-exact mechanism is not landable in this slice:

1. Foundation.Process exposes no pre-exec hook on any platform; installing
   the filter in the *parent* would cut the agent's own provider API access
   (upstream installs in the child for exactly this reason).
2. A pre-exec-capable spawner needs a C trampoline target; SwiftPM forbids
   mixed-language targets, and `Package.swift` + C-target files are owned by
   integration / other slices (the `_GNU_SOURCE` crash-handler fix is the CI
   slice's). W9 deferred the seccomp C shim for the same reason
   (PORT_STATUS wave-9 note).

Why `unshare --net` is the right port seam (not just the available one):

- **Capability outcome is identical** — no egress, no ingress — and raw-socket
  egress is denied *more* strictly than upstream's syscall list. PORT_PLAN
  W4-S1: "Exact platform enforcement may differ, but capability outcomes and
  failure policy may not."
- **Failure policy is identical**: host can't enforce → typed
  `SandboxError.unsupported` at spawn, never an unrestricted child.
- No manifest change, no C shim, testable without root where unprivileged
  userns exist, and the probe runs the *real* invocation rather than
  inferring from kernel versions.

Named costs (also in `ChildNetworkRestriction.swift` header): blocked child
sees `ENETUNREACH` not upstream's `EPERM`; userns changes the child's
credential view (candidate order puts uid-preserving `--map-current-user`
first, `--map-root-user` second, bare `--net` for CAP_SYS_ADMIN callers
third); one extra exec per wrapped launch; depends on host namespace policy
(Docker/AppArmor/sysctl), hence runtime probing.

## 2. What landed

- **`Sources/OpenGrokSandbox/ChildNetworkRestriction.swift` (new)** —
  `LinuxChildNetworkRestriction`: `probeHost` (cached, spawns
  `unshare <prefix> /bin/sh -c :` once per binary; explicit `unsharePath`
  override is authoritative for tests), `wrappedCommand` (fail-closed),
  `wrap` (pure argv transform, `--`-terminated prefix). Probe runner uses
  `terminationHandler` + semaphore with SIGTERM→SIGKILL escalation — **no
  `waitUntilExit`** (banned; wedged suites twice).
- **`Sources/OpenGrokSandbox/NetworkPolicy.swift`** — deleted the dead
  seccomp program/`SockFilter`/`installChildNetworkFilter` (was
  `@available(*, unavailable)` or unconditionally throwing; nothing called
  them). `ChildNetworkPolicy.enforceInChildProcess()` replaced by
  `restrictedLaunch(executable:arguments:)` (`NetworkPolicy.swift:277`):
  `.blocked` → real Linux wrap / off-Linux deliberate no-op (parity:
  `child_net.rs:226-229`); `.websites` → **typed unsupported everywhere** —
  upstream models but never enforces per-origin lists
  (`network_policy.rs:3`), and degrading an allow-list to all-or-nothing
  would break allowed origins.
- **`Sources/OpenGrokSandbox/Manager.swift:227`** —
  `childNetworkRestrictedLaunch(executable:arguments:)` replaces the
  unusable `applyChildNetworkRestrictionToLaunch(preExec:)` (no callers
  existed; no pre-exec seam exists to honor it).
- **`Sources/OpenGrokSandbox/OpenGrokSandbox.swift`** — module surface list
  updated.
- **Tests** — `OpenGrokSandboxTests.swift`: `childNetworkPolicyPreExec`
  replaced by `childNetworkPolicyRestrictedLaunch` (pins all three policy
  branches per platform). `LinuxChildNetworkRestrictionTests.swift` (new):
  wrap shape, never-arms-off-Linux (`restrictNetworkAtKnownLinuxLaunches`
  both branches), passthrough-when-unarmed (reachability control), probe
  honesty both ways, bogus-path fail-closed, and the behavioral test below.

## 3. Behavioral Linux test (guarded)

`wrappedChildCannotReachNetwork`
(`Tests/OpenGrokSandboxTests/LinuxChildNetworkRestrictionTests.swift:146`):

1. Plan-time guard `.enabled(if: isRunnableOnThisHost)` — real
   `probeHost()` + a connect-probe program (`/bin/bash` `/dev/tcp` preferred,
   `python3` fallback). Unsupported hosts show a **skip** in the report, not
   a silent green (swift-testing 6.3.3 has no runtime `Skip`; `.enabled(if:)`
   is the honest guard).
2. Binds a loopback listener in the parent netns (raw Glibc sockets; no
   Network.framework, no TestSupport dependency).
3. **Control**: unwrapped probe must connect and be observed — proves probe
   mechanics on this host; failure here is a loud environment defect.
4. **Experiment**: wrapped probe must exit non-zero, stderr must *not* read
   `unshare:` (denial happened in the child, not a wrapper launch failure),
   must name a network-layer denial (`unreachable|not permitted|no route`),
   and the listener must observe nothing within 2s. The listener accepts the
   control connection so the level-triggered poll can't mask the negative
   window.

## 4. NOT landed — live-spawn wiring (needs integration; Package.swift is not mine)

The enforcement is real and behaviorally tested; it is **implemented-unwired**
until integration lands the two-line seam below. Per ledger discipline this is
recorded, not hidden.

1. `Package.swift` — add the edge (Sandbox is a leaf; no cycle):
   ```
   t.append(.target(name: "OpenGrokShellBase", dependencies: dep(w0s2, w0s3, w0s4, w1s1, w1s2, w1s3, w1s4, w1s5, w2s1, w2s2, w3s1, w3s2, w3s3, w4s3, w5s1, ["OpenGrokSandbox"])))
   ```
2. `Sources/OpenGrokShellBase/LocalShellProcessBackend.swift` — in
   `startTask(_:background:)`, after `ShellCommandPreparation.prepare(...)`
   (≈ line 225), before `Process()` construction:
   ```swift
   import OpenGrokSandbox
   ...
   // Known Linux child launch: when the process-wide sandbox restricts child
   // network, re-exec through the network-denying namespace. Fail closed —
   // a host that cannot enforce throws here, before spawn.
   let launch = try childNetworkRestrictedLaunch(
       executable: prepared.executable,
       arguments: prepared.arguments
   )
   let process = Process()
   process.executableURL = URL(fileURLWithPath: launch.executable)
   process.arguments = launch.arguments
   ```
   This is the parity site for `streaming_local_terminal.rs:917-921`. The
   `SandboxError` propagates typed out of `startTask` — do not wrap it in
   `ShellError.io` (keeps the denial greppable).
3. **Reachability test the integration must add** (repo rule: assert through
   the live seam): arm `shouldRestrictChildNetwork` via a test seam
   (requires a successful `SandboxManager.install` with applied+netRestricted
   — needs an internal test hook or a `@testable` store write), spawn through
   `LocalShellProcessBackend`, assert argv wrapping or denial. The global
   store is `private` today; I deliberately did not weaken its visibility —
   the wiring agent should choose the seam.
4. **PTY-backed execution** (`OpenGrokExecutionTools` `ProcessRunner` /
   `any PTYProcess`, ≈ upstream `computer/local/terminal.rs` ×3): same
   one-line wrap belongs at that fork/exec seam, owned by the PTY slice —
   audited and recorded, not attempted (cross-slice). Hook spawns are
   deliberately *not* wired: upstream does not filter hook children either
   (no `install_child_network_filter` in `HookRunner` equivalents).

## 5. Arming gap (pre-existing, unchanged by this slice)

`shouldRestrictChildNetwork()` = `applied && configured` on Linux
(`Manager.swift:114-120`), and `applied` requires `PlatformEnforcer.apply`
success — which on Linux still always throws
(`Manager.swift:253-255`, "requires bubblewrap re-exec"). So on Linux today
the flag can never be true: this slice makes the *denial* real; *arming*
remains gated on the deferred Linux FS-sandbox apply path (bwrap re-exec /
Landlock), exactly as upstream gates it. Do not "fix" the arming by faking
`applied` — that would silently report a filesystem sandbox that does not
exist.

## 6. macOS Seatbelt re-audit — verdicts

Claim (wave-8 close + `LiveSandboxComposition.swift` header): macOS Seatbelt
is live from the executable, applied at first tool-executor construction,
fail-closed, persisted/pinned on resume.

- **Importer claim: ACCURATE.** `LiveComposition.swift:2249` →
  `LiveSecurityContext.applySandbox` (`LiveComposition.swift:2137-2149`) →
  `LiveSandboxComposition.bootstrap` (`LiveSandboxComposition.swift:138-180`)
  → `bootstrapSandbox` → `SandboxManager.apply` → `PlatformEnforcer.apply`
  macOS arm (`Manager.swift:229-231`) → `buildSeatbeltProfile` +
  `applySeatbeltProfile` (`Platform.swift:222-251`) → real `dlsym("sandbox_init")`
  call; nonzero rc throws `SandboxError.enforcementFailed`. The per-crate
  table row 48 ("orphaned, no importer") is **stale**, superseded by wave 8.
- **Fail-closed claim: ACCURATE.** Configured-but-unenforceable throws typed
  `SandboxError` out of `LiveToolExecutor.init` (`LiveComposition.swift:2246-2253`;
  `LiveSandboxComposition.swift:175-179`; `Manager.swift:162-193`). Idempotent
  re-entry short-circuits on `isSandboxActive()`
  (`LiveSandboxComposition.swift:159-165`).
- **Timing divergence claim ("first executor, not process start"): ACCURATE**
  by construction; the call is inside `LiveToolExecutor.init`.
- **YOLO decoupling claim: ACCURATE.** `--yolo` feeds only
  `CLIPermissionOptions.alwaysApprove` → permission resolution
  (`LiveComposition.swift:2121`); no sandbox coupling found.
- **Resume pin: REAL.** `--sandbox` parses (`CLICommand.swift:1304`),
  `GROK_SANDBOX` inherits (`CLICommand.swift:1318-1326`), profile persisted
  via `LiveWorkspaceComposition.swift:252-318` (`sandbox_profile`), downgrade
  refused in `validateResume` (`LiveSandboxComposition.swift:111-125`).

### Finding A (new, parity): `(deny network*)` over-denies on macOS

`buildSeatbeltProfile` emits `(deny network*)` whenever
`resolved.restrictNetwork` (`Platform.swift:197-201`), and `readOnly`/`strict`
resolve `restrictNetwork: true` (`Profiles.swift:163-199`). **Upstream never
denies process-level network**: `lib.rs:9-10` — "Network is left open at the
process level (agent needs LLM API); child network is blocked per-subprocess
via seccomp"; `capability_set_from_profile` (`profiles.rs:232-329`) builds no
network capability; `restrict_network` feeds only the Linux child filter
(`lib.rs:80-85`, `~183-190`). Consequence: on macOS with profile `read-only`,
`strict`, or any custom `restrict_network = true`, `sandbox_init` kills the
whole process's network — the agent cannot reach its provider API. Latent
(default profile is `off`), but a live parity defect in a security profile:
over-denial that breaks upstream behavior. Residual uncertainty: nono's exact
SBPL is not vendored, but the cited intent + capability construction are
unambiguous.

Proposed fix (NOT landed — security-posture loosening belongs to a reviewed
decision; test impact included):

```
Sources/OpenGrokSandbox/Platform.swift:197-201
-    if resolved.restrictNetwork {
-        lines.append("(deny network*)")
-    } else {
-        lines.append("(allow network*)")
-    }
+    // Upstream leaves process-level network open on every profile
+    // (xai-grok-sandbox/src/lib.rs:9-10: the agent needs its LLM API);
+    // restrict_network feeds only the Linux per-child filter.
+    lines.append("(allow network*)")
Tests/OpenGrokSandboxTests/OpenGrokSandboxTests.swift (seatbeltWriteSubactionsAndAliases)
-        #expect(sbpl.contains("(deny network*)"))
+        #expect(sbpl.contains("(allow network*)"))
+        #expect(!sbpl.contains("deny network"))
```

### Finding B (live path, not my file): `--sandbox` flag is parsed but inert

`CLIPermissionOptions.sandboxProfile` (`CLICommand.swift:85`) is populated by
`--sandbox` and `GROK_SANDBOX` (`CLICommand.swift:1304-1326`), but
`LiveSecurityContext.resolve` never threads it and `applySandbox` omits
`cliProfile:` (`LiveComposition.swift:2142-2147`), so the composition's own
documented precedence (`LiveSandboxComposition.swift:60-67`: requirements >
CLI > env > config) **loses the CLI tier**. `GROK_SANDBOX` env still works
(passed through `environment:`). A user typing `--sandbox strict` gets no
sandbox and no warning — the repo's named failure mode. Minimal fix for the
CLI slice: carry `cli.sandboxProfile` on `LiveSecurityContext` and pass it as
`cliProfile:` in `applySandbox`, plus a reachability test that `--sandbox`
changes the decision.

### Finding C (minor, unreachable): bwrap plan's `--unshare-net` has no upstream basis

`bwrapReexecCommand(restrictNetwork:)` appends `--unshare-net`
(`Platform.swift:377-380`), but upstream's bwrap re-exec contains no network
flag at all (`lib.rs:~290-330` — verified: no `unshare` anywhere in
`xai-grok-sandbox/src/lib.rs` or `hook_write_deny.rs`). Same class as
Finding A: the port over-denies network where upstream deliberately leaves
the process open. Unreachable today (Linux apply throws before any re-exec;
the function's only callers are tests), so nothing ships — recorded so the
deferred FS-sandbox/bwrap slice drops the arm rather than inheriting it.
Existing test `bwrapReexecNetworkIsolation` pins the invented behavior and
must be updated by whichever slice removes it.

### Audit residual risks

- No test can prove `sandbox_init` succeeded in-process (irreversible; would
  sandbox the test runner). Recommend one manual smoke per release:
  `GROK_SANDBOX=workspace open-grok` → write outside workspace denied,
  provider calls still work.

## 7. Proposed ledger text (PORT_STATUS, wave-10 entry — for the lead)

```
## Wave 10 — 2026-08-05 (sandbox: real Linux child network denial)

- **Linux child network denial is real.** Decided from the Rust reference:
  upstream's in-process pre-exec seccomp filter (child_net.rs:143-213, wired
  at streaming_local_terminal.rs:917-921) is unreachable from
  Foundation.Process without a C trampoline target, so the port enforces the
  same capability outcome by re-execing known Linux child launches through
  `unshare(1)` user+network namespaces (unshare is upstream *attack surface*
  — deny_paths_e2e.rs:574-602 — never its mechanism; PORT_PLAN W4-S1 blesses
  mechanism divergence with identical capability/failure policy). Hosts that
  cannot enforce fail closed with typed `SandboxError.unsupported` at spawn.
  Behavioral test observes a wrapped child unable to reach a parent listener
  (control connects first), guarded by a plan-time `.enabled(if:)` probe so
  unsupported hosts skip visibly. `.websites` child policies are typed
  unsupported on all platforms (upstream models, never enforces —
  network_policy.rs:3). Dead seccomp BPF scaffolding deleted.
- **Wiring is implemented-unwired by one integration step**: the
  `LocalShellProcessBackend` spawn seam + `OpenGrokShellBase → OpenGrokSandbox`
  edge are handed to integration as exact patch text
  (INTEGRATION-w10-sandbox.md §4). Arming still requires the deferred Linux
  FS-sandbox apply path (§5) — unchanged.
- **Seatbelt re-audit**: wave-8 importer/fail-closed/timing/YOLO claims
  verified accurate; per-crate row 48 "orphaned" is stale. Two findings:
  `(deny network*)` over-denies vs upstream on read-only/strict macOS
  profiles (proposed diff in note; not landed — reviewed loosening), and
  `--sandbox` parses but never reaches the resolver (CLI-slice fix spec'd).
```

## 8. Recommended verification (root agent owns)

```sh
zsh workflows/swift-safe-verify.zsh build
zsh workflows/swift-safe-verify.zsh build-tests
zsh workflows/swift-safe-verify.zsh test --no-parallel
zsh workflows/swift-safe-verify.zsh build --product open-grok
# Scoped (after build-tests): check reported counts, not exit codes —
# zero-match --filter exits 0, and filters match TYPE names:
zsh workflows/swift-safe-verify.zsh test --no-parallel --filter 'OpenGrokSandboxTests|LinuxChildNetworkRestriction'
# Expected counts: 36 tests on macOS (32 OpenGrokSandboxTests + 4 new),
# 38 on Linux (32 + 6; the behavioral test runs or *skips* per host probe —
# a skip prints as skipped, never as a silent pass).
```
