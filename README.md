# Open Grok (Swift port)

A Swift source-port of **Open Grok**, a terminal coding agent. The public
executable is **`open-grok`**. This repository is the SwiftPM workspace that
ports the Open Grok Rust codebase to Swift, preserving end-user behavior and
the Open Grok branding while keeping all runtime/configuration state isolated
to `$OPENGROK_HOME` or `~/.opengrok` (the legacy `~/.grok` path is never read
or written).

> **Status (2026-08-02):** The committed port is clean at checkpoint
> `1c4ed0c55e0c39722925d026af46b8ed0936be65`, including R16–R19 work that
> postdates the older status snapshot. The last recorded full verifier results
> remain historical until rerun at this checkpoint. Continuation work must also
> reconcile Rust baseline `9739c4a2ad23cfea14312a481169757f3da494f4` with
> exact upstream revision `c1bca4020bad3b8058984d49388ac150e3ce7fd7`.
> Workers must still **not** invoke
> SwiftPM directly; the sole integration path is the serialized verifier below.
> See `PORT_STATUS.md`, `PORT_PLAN.md`, and `CRATE_MAP.md` for exact scope and
> remaining product gaps. Inventory (committed tree): **98** production source
> targets, **42** bootstrap placeholders (≤15 non-comment LOC, excluding C
> helpers), **100** test targets, **46** zero-test targets. Later waves still
> own providers, tools runtime, sandbox, TUI, sessions, MCP, etc.

## Build and test (serialized safe verifier only)

Requires a Swift 6.1+ toolchain (developed against Swift 6.4).

**Do not run `swift build` / `swift test` / `swift package` directly** from
worker agents or ad-hoc scripts that share this workspace. Use the lock +
scratch-path wrapper so only one process owns the SwiftPM cache:

```sh
zsh workflows/swift-safe-verify.zsh build
zsh workflows/swift-safe-verify.zsh build-tests
zsh workflows/swift-safe-verify.zsh test
zsh workflows/swift-safe-verify.zsh build --product open-grok
```

After a green product build, executable smokes:

```sh
# Paths depend on the verifier scratch path (default `.build/workflow-safe`).
.build/workflow-safe/out/Products/Debug/open-grok --version
.build/workflow-safe/out/Products/Debug/open-grok help
OPENGROK_HOME=/tmp/og .build/workflow-safe/out/Products/Debug/open-grok paths
```

The bootstrap CLI surface is **version / help / paths** only. Other product
commands (`login`, `sessions`, `models`, ACP serve, interactive TUI, …) remain
explicitly **not yet implemented** and must not be presented as working.

## Protocol fixture validation

Checked-in fixtures under `ProtocolFixtures/` are provenance-labelled against
Rust ref `9739c4a2ad23cfea14312a481169757f3da494f4` and cover:

- ACP method names
- Binary OTLP `ExportTraceServiceRequest` (HTTP protobuf + gRPC-framed) goldens
- Git loose-object zlib + pack non-parity notes
- CLI version / `OPENGROK_HOME` / bootstrap command surface
- Config authority, workspace permission, Code Mode message kinds
- Tracing W3C `traceparent`, SQLite journal modes, hunk snapshot schema, PTY
  portable signals, crash GCRX binary sample

Validate without network (via the safe verifier only when SwiftPM is required):

```sh
zsh workflows/swift-safe-verify.zsh build   # then, if needed:
# swift package --scratch-path .build/workflow-safe ogrok-validate-protocols
```

Prefer tests that re-encode/decode goldens (telemetry + BuildSupport) over
digest-only checks. Regeneration (deterministic, network-free):

```sh
scripts/regenerate-protocol-manifest.sh --reference-revision 9739c4a2ad23cfea14312a481169757f3da494f4
```

## Package layout

`Package.swift` is owned by the integration slice (R10 / W0-S1 lineage) and
predeclares **all** Swift targets and dependency edges so parallel
implementation slices only replace sources under their owned
`Sources/<Target>/` and `Tests/<Target>Tests/` directories.

Notable foundation targets (non-exhaustive; see `PORT_STATUS.md`):

| Area | Targets |
|---|---|
| Branding / version / paths | `OpenGrokVersion`, `OpenGrokPaths`, `OpenGrokEnvironment`, `OpenGrokCLI` |
| Tool contracts | `OpenGrokToolTypes`, `OpenGrokToolProtocol`, `OpenGrokToolRuntime`, `OpenGrokToolsAPI` |
| ACP / agent contracts | `OpenGrokACP`, lifecycle, interjection, prompt queue |
| Config / workspace types | `OpenGrokConfigTypes`, `OpenGrokConfig`, `OpenGrokWorkspaceTypes`, hooks/plugin types, Code Mode protocol |
| HTTP / telemetry | `OpenGrokHTTP`, `OpenGrokCircuitBreaker`, `OpenGrokTracing`, `OpenGrokTelemetry` (OTLP **protobuf** wire) |
| Storage / secrets / FS | `OpenGrokFileUtils`, `OpenGrokSQLiteJournal`, `OpenGrokSecrets`, `OpenGrokFSNotify` |
| Git / graph / hunks | `OpenGrokGitStatus` (portable SHA-1, declared zlib, explicit pack non-parity), graph, hunk tracker |
| PTY / TTY / power / crash | `OpenGrokPTY` + `OpenGrokPTYC`, `OpenGrokTTY`, `OpenGrokSystemPower`, `OpenGrokCrashHandler` + C shim |

## Portability seams (honest)

| Seam | Status |
|---|---|
| macOS | Primary development host; Seatbelt/sandbox still later-wave |
| Linux | Intended full support; zlib via `COpenGrokZlib`; SQLite via system SQLite3; Secret Service incomplete |
| Windows | Compile-checked branches only where present; ConPTY / Credential Manager / Job Objects later |
| Packed Git objects | Explicit `packedObjectUnsupported` — not silent success |
| OTLP export | Real `ExportTraceServiceRequest` protobuf; gRPC TraceService Export path + framing + `grpc-status` (not JSON labeled protobuf) |

## Workflows

| Entry | Role |
|---|---|
| `workflows/swift-safe-verify.zsh` | **Only** allowed SwiftPM build/test entry (lock + scratch path) |
| `.opengrok/workflows/swift-open-grok-luna-continuation.rhai` | Canonical Luna `xhigh` continuation; exact upstream reconciliation, safe checkpoints, and serialized SwiftPM |
| `workflows/run-grok45-port.zsh` | Legacy cycle harness; must also use the safe verifier for builds |

## Protected artifacts

- `Sources/OpenGrokChatState/CompactionTranscript.swift` JSONValue pattern correction — do not revert.
- C helper targets `OpenGrokPTYC` and `OpenGrokCrashHandlerC` are required for R09 shims.
- Branding remains **Open Grok** / `open-grok`; state under `OPENGROK_HOME` / `~/.opengrok` only.

## License

Apache-2.0 for first-party code. Preserve third-party notices for derived sources.
