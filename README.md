# Open Grok (Swift port)

A Swift source-port of **Open Grok**, a terminal coding agent. The public
executable is **`open-grok`**. This repository is the SwiftPM workspace that
ports the Open Grok Rust codebase to Swift, preserving end-user behavior and
the Open Grok branding while keeping all runtime/configuration state isolated
to `$OPENGROK_HOME` or `~/.opengrok` (the legacy `~/.grok` path is never read
or written).

> **Status (2026-08-25):** The pinned Rust baseline is
> `00e176c8fb4035701c24199bf9225973c1b13c20` (`1.0.0-open-grok.82`).
> `CRATE_MAP.md` inventories all 93 root workspace members and the separately
> rooted Markdown fuzz crate. `PORT_STATUS.md` and `PARITY_ROADMAP.md` record
> which behaviors are live, unwired, absent, or deliberately diverged.
> Workers must still **not** invoke
> SwiftPM directly; the sole integration path is the serialized verifier below.
> Complete cross-platform product parity is not yet claimed.

## Build and test (serialized safe verifier only)

Requires a Swift 6.1+ toolchain (developed against Swift 6.4).

**Do not run `swift build` / `swift test` / `swift package` directly** from
worker agents or ad-hoc scripts that share this workspace. Use the lock +
scratch-path wrapper so only one process owns the SwiftPM cache:

```sh
zsh workflows/swift-safe-verify.zsh build
zsh workflows/swift-safe-verify.zsh build-tests
zsh workflows/swift-safe-verify.zsh test --no-parallel
zsh workflows/swift-safe-verify.zsh build --product open-grok
```

After a green product build, executable smokes:

```sh
# Paths depend on the verifier scratch path (default `.build/workflow-safe`).
.build/workflow-safe/out/Products/Debug/open-grok --version
.build/workflow-safe/out/Products/Debug/open-grok help
OPENGROK_HOME=/tmp/og .build/workflow-safe/out/Products/Debug/open-grok paths
```

The live CLI includes authentication, model discovery, sessions, plugin and MCP
management, command wrapping, ACP, the interactive pager, and coding-agent
tools. Consult `open-grok help`, `PORT_STATUS.md`, and `PARITY_ROADMAP.md` for
the exact supported routes and remaining behavioral or platform gaps.

## Protocol fixture validation

Checked-in fixtures under `ProtocolFixtures/` carry their own historical
provenance; the current product reference is Rust commit
`00e176c8fb4035701c24199bf9225973c1b13c20`. They cover:

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
scripts/regenerate-protocol-manifest.sh --reference-revision 00e176c8fb4035701c24199bf9225973c1b13c20
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
| macOS | Primary verified host; native sandbox and interactive terminal routes are exercised |
| Linux | Partial support; system SQLite/zlib and updater exist, but enterprise CA, graphics, and native runtime proof remain incomplete |
| Windows | Partial conditional implementations only; interactive terminal, ConPTY, clipboard reads, and Job Objects remain incomplete |
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
