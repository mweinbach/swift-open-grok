# Open Grok (Swift port)

A Swift source-port of **Open Grok**, a terminal coding agent. The public
executable is **`open-grok`**. This repository is the SwiftPM workspace that
ports the Open Grok Rust codebase to Swift, preserving end-user behavior and
the Open Grok branding while keeping all runtime/configuration state isolated
to `$OPENGROK_HOME` or `~/.opengrok` (the legacy `~/.grok` path is never read
or written).

> **Status (2026-07-22):** Wave 0 foundations plus substantial R01–R09 contract
> and infrastructure targets are present. **The integrated package build is not
> verified green** at the current HEAD — workers must **not** invoke SwiftPM
> directly. The sole integration path is the serialized safe verifier below.
> See `PORT_STATUS.md`, `PORT_PLAN.md`, and `CRATE_MAP.md` for exact scope,
> placeholder counts, and remaining product gaps. Roughly half of production
> targets remain bootstrap placeholders (later waves: providers, tools runtime,
> sandbox, TUI, sessions, MCP, etc.).

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
.build/workflow-safe/debug/open-grok --version
.build/workflow-safe/debug/open-grok help
OPENGROK_HOME=/tmp/og .build/workflow-safe/debug/open-grok paths
```

The bootstrap CLI surface is **version / help / paths** only. Other product
commands (`login`, `sessions`, `models`, ACP serve, interactive TUI, …) remain
explicitly **not yet implemented** and must not be presented as working.

## Protocol fixture validation

Checked-in fixtures under `ProtocolFixtures/` cover ACP method names plus
foundation shapes (OTLP export content types, Git object/index, CLI version and
`OPENGROK_HOME`, config/workspace/Code Mode key orders). Validate without network:

```sh
swift package ogrok-validate-protocols
```

Regeneration (deterministic, network-free):

```sh
scripts/regenerate-protocol-manifest.sh
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
| OTLP export | Real `ExportTraceServiceRequest` protobuf + gRPC framing (not JSON labeled protobuf) |

## Workflows

| Entry | Role |
|---|---|
| `workflows/swift-safe-verify.zsh` | **Only** allowed SwiftPM build/test entry (lock + scratch path) |
| `workflows/swift-open-grok-safe-resume.js` | Multi-agent resume; workers forbidden from SwiftPM |
| `workflows/run-grok45-port.zsh` | Legacy cycle harness; must also use the safe verifier for builds |

## Protected artifacts

- `Sources/OpenGrokChatState/CompactionTranscript.swift` JSONValue pattern correction — do not revert.
- C helper targets `OpenGrokPTYC` and `OpenGrokCrashHandlerC` are required for R09 shims.
- Branding remains **Open Grok** / `open-grok`; state under `OPENGROK_HOME` / `~/.opengrok` only.

## License

Apache-2.0 for first-party code. Preserve third-party notices for derived sources.
