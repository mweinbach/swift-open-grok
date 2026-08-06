# INTEGRATION-w10-acp.md — Wave 10 ACP slice: leader control plane

Slice: **ACP** (Wave 10). Owner of `Sources/OpenGrokACPRuntime/`,
`Tests/OpenGrokACPRuntimeTests/`, this note, and the assigned tripwire update
in `Tests/OpenGrokCLITests/LiveWorkspaceCompositionTests.swift`. No
SwiftPM/build/test commands were run by this slice (integration owns
verification); everything below is by-inspection.

Reference: `/Users/mweinbach/Projects/grok-build` @ `9ed09e2a…` (read-only).
Line cites are to that checkout.

## Integration-owner update (supersedes handoff items 1 and part of 2)

- `LeaderWorkspaceControlChannel.send` now consumes matching
  `controlResult(.workspaceStatus)` payloads, and an argv-driven production
  channel test passes through the real `ACPLeaderIPCHost`.
- Integration found and fixed duplicate client-side length framing; the shared
  codec also emits serde-compatible unescaped slashes.
- The control plane clock is macOS-12-compatible uptime nanoseconds rather than
  `ContinuousClock`, and async lock use was converted to `withLock`.
- Still open: real leader socket/version metadata and the Computer Hub exposure
  connector. Backend-less `workspace_start` remains a typed refusal.
- Root verification: control-plane 13/1, payload goldens 8/1, workspace
  capability/production channel 4/1; full serialized suite green.

## What landed

The leader control plane needed to represent workspace status on the wire.

**Before:** `ACPLeaderServerMessage` had no success case for a control
request at all — a workspace status literally could not be represented on
this port's wire. `ACPLeaderIPCHost` answered every `control` frame with a
blanket `controlError` (code 1) and advertised `control_v1 = false` /
`workspace_exposure = false`.

**After:**

1. **Wire (`ACPLeaderProtocol.swift`).**
   - New `controlResult(requestID:payload:)` case on
     `ACPLeaderServerMessage`, encoded as serde's
     `{"type":"control_result","request_id":...,"result":{"Ok":{...}}}`
     (`protocol.rs:364-367`). The existing `controlError` case and its
     `{"Err":{"code":<int>,"message":...}}` shape are unchanged; decode
     branches on `Ok` vs `Err`.
   - New payload types with upstream's serde shapes, byte-pinned by golden
     tests: `ACPLeaderWorkspaceStatus` (`protocol.rs:265-276`, tag
     `workspace_status`, explicit `null` for absent `hub_url`/`cwd`),
     `ACPLeaderInfo` (`protocol.rs:230-243`, `cpu_profile_stopping` defaults
     false on decode per `protocol.rs:240-242`), `ACPLeaderCpuProfileStatus`
     (`protocol.rs:245-251`), wrapped by `ACPLeaderControlPayload`
     (internally tagged, `protocol.rs:227-229`). Unknown payload variants
     fail decode rather than being approximated.
   - Control frames now tolerate upstream's numeric `frequency_hz`
     (`protocol.rs:198-202`): the command map decodes scalars
     (string/number/bool) and flattens them to strings, instead of a strict
     `[String: String]` decode wedging the connection over one command.
   - `ACPLeaderCapabilities.supported` is now
     `{ controlV1: true, workspaceExposure: true }`, matching upstream's
     unconditional advert (`server.rs:153-160`). `runtimeCPUProfile` stays
     false (no profiler exists in this port; upstream compiles pprof in on
     unix, `cpu_profile.rs:650-655`), `relaunchV1` stays false (upstream
     clients degrade gracefully on that, `protocol.rs:185-190`),
     `profileFormats` stays `[]` — parity, upstream advertises nothing
     during its two-phase migration (`cpu_profile.rs:658-664`).

2. **Control plane (`ACPLeaderControlPlane.swift`, new).**
   - `ACPLeaderControlCommand.parse` reads the flat frame; the discriminator
     is upstream's `type` tag with the port's shipped `command` spelling
     (`WorkspaceControlCommand.wire`) accepted as fallback so the existing
     CLI client keeps working.
   - `get_leader_info` answers from `ACPLeaderControlMetadata`
     (`server.rs:975-997`); `cpu_profile_status` answers upstream's
     `CpuProfileStatus::Inactive` (`cpu_profile.rs:107-117`) — the true
     answer for a profiler-less build, not a refusal.
   - Workspace mutations port `server.rs:1100-1226`: hub-URL resolution
     (explicit > configured default > `productionComputerHubURL`,
     `server.rs:998`, :1108-1114) with ws/wss validation (:1112-1113),
     idempotent re-start (:1116-1124), pause/resume/stop with upstream's
     exact no-exposure errors (:1176, :1192) and stop-is-a-successful-none
     (:1207-1217), reconnect-failure-stays-paused (:1197-1200), sessions
     sorted in the payload (:1081-1082), uptime from one start instant
     through pauses (:1161, :1092).
   - `finalize()` drains the exposure with the leader
     (`server.rs:1228-1235`); `ACPLeaderIPCHost.stop()` calls it.
   - **Concurrency shape is upstream's, not an actor's.** Status reads a
     lock-guarded slot (never held across an await) so `workspace_status`
     never queues behind an in-flight mutation — upstream's `ArcSwap`
     rationale (`server.rs:172-174`). Mutations serialize through a task
     tail the way upstream holds `ws.lock` across the whole handler
     (`server.rs:1114`); an actor cannot give that guarantee (re-entrant at
     every await).

3. **Host (`ACPLeaderIPC.swift`).** `ACPLeaderIPCConfiguration` gains
   `controlPlane:` (nil → default plane with real pid and no backend).
   `readLoop` dispatches each `control` frame on a detached task
   (`server.rs:1763-1817`) so a seconds-long hub connect cannot stall the
   client's ACP traffic or pings, and sends `controlResult`/`controlError`.

4. **Exposure backend is an injected seam.** The hub connection itself is
   not in this target: upstream calls
   `xai_grok_workspace::connect_local_workspace` (`server.rs:1139-1155`);
   the port's hub stack is `OpenGrokComputerHubSDK` (w4s4), which
   `OpenGrokACPRuntime` (w7s5) does not depend on, and Package.swift is
   integration-owned. `ACPWorkspaceExposureConnector` +
   `ACPWorkspaceExposureConnection` are the seam: `snapshot()` (sync,
   lock-free), `disconnect()` (drain semantics incl. upstream's 10s
   `WORKSPACE_DRAIN_TIMEOUT`, `server.rs:999`, belong to the implementor),
   `reconnect()`. A backend-less leader refuses `workspace_start` with a
   typed error naming the missing piece while `workspace_status` keeps
   answering truthfully — the same shape upstream produces when its own hub
   connect fails (`server.rs:1154-1155`).

5. **Tripwire updated, not deleted.** The wave-9 ledger records
   `portDefaultLeaderIsRefused` asserting `workspaceExposure == false` "so
   flipping that bit without building the control plane fails a test rather
   than shipping a lie". The control plane now exists, so
   `portDefaultLeaderBacksExposureAdvert`
   (`Tests/OpenGrokCLITests/LiveWorkspaceCompositionTests.swift`) inverts
   the guard: it asserts the bits stay set AND drives the real
   `ACPLeaderIPCHost` over the same frame codec the production socket
   serves — once against the production-default host (status answers
   `state:none` with the real pid), once with an injected backend (start →
   running, status → running). Dropping the control plane while keeping the
   bit fails the test, the lie the original prevented in the other
   direction. In `Tests/OpenGrokACPRuntimeTests/`, the blanket-refusal test
   was replaced by a full control-plane suite: both discriminator
   spellings, missing discriminator, backend-less status/start, the full
   lifecycle, idempotence, default hub URL, invalid hub URL (refused before
   any connect), no-exposure refusals vs successful stop, failed-reconnect
   stays paused, injected-clock uptime, leader info, and typed refusals for
   CPU profiling/relaunch.

## Deliberate divergences (recorded, not hidden)

- **Integer control-error codes.** Upstream's `ControlError.code` is a
  snake-case string (`ControlErrorCode`,
  `xai-grok-shell-base/src/cpu_profile.rs:30-60`). This port's Err dialect
  has been integer-coded since before the control plane existed — the
  shipped workspace CLI decodes `{"Err":{"code":<int>,...}}` — so integers
  stay: `invalidCommand = 100` (no upstream equivalent; upstream fails the
  whole frame decode), `unsupportedCommand = 101`
  (≈ `runtime_profiling_unsupported` for profiling; no upstream equivalent
  for relaunch), `workspaceError = 102` (≈ upstream's `internal_error`,
  `server.rs:1000-1006`). Values start at 100 to stay clear of the
  registration codes 1-3.
- **`command` discriminator fallback** alongside upstream's `type` (see
  above).
- **No CPU profiler** (`runtime_cpu_profile` / `profiling_*` false) and
  **no relaunch-for-update** (`relaunch_v1` false): genuine capability gaps,
  advertised as false and refused with typed errors.
- **`allow_insecure_ws` localhost rule and the folder-trust side effect**
  (`server.rs:1125-1126`, :1139) are the backend connector's
  responsibility, not the control plane's — flagged for the Hub slice's
  connector implementation.

## Handoff — required pairings (other slices own these files)

1. **`Sources/OpenGrokCLI/LiveWorkspaceComposition.swift` —
   `LeaderWorkspaceControlChannel.send` MUST consume `controlResult`.**
   Today its reply loop skips every non-error frame (`default: continue`),
   so against a real leader the workspace route will park forever waiting
   for a frame it refuses to read. Suggested shape (as text; file is not
   this slice's):

   ```swift
   case .controlResult(let id, let payload) where id == requestID:
       guard case .workspaceStatus(let status) = payload else {
           throw WorkspaceRouteError(
               "the leader answered `workspace \(command.wire["command"] ?? "?")` "
                   + "with an unexpected payload: \(payload)"
           )
       }
       return WorkspaceStatusPayload(
           state: status.state,
           hubURL: status.hubURL,
           cwd: status.cwd,
           uptimeMs: status.uptimeMs,
           activeToolCalls: Int(status.activeToolCalls),
           sessions: status.sessions,
           pid: Int(status.pid)
       )
   ```

   The file's header comment (lines 30-46) also describes the pre-control-
   plane behavior ("answers every `control` frame with `controlError`… no
   success case") and is stale after this slice.

2. **`Sources/OpenGrokCLI/LiveLeaderComposition.swift` — inject real
   metadata (and the hub connector when the Hub slice provides one).** The
   construction site at `:192` currently uses all defaults, so
   `get_leader_info` reports placeholder paths and version `"0.0.0"`.
   Suggested shape:

   ```swift
   configuration: ACPLeaderIPCConfiguration(
       binaryVersion: <OpenGrokVersion.installed version string>,
       controlPlane: ACPLeaderControlPlane(
           metadata: ACPLeaderControlMetadata(
               socketPath: paths.socket.path,
               lockPath: paths.lock.path,
               wsURLSuffix: ACPLeaderSocketPaths.suffix(forRelayURL: relay.url),
               binaryVersion: <same>
           ),
           connector: <hub connector over OpenGrokComputerHubSDK, when available>
       )
   )
   ```

   Nothing breaks without this: the default plane answers truthfully and
   `workspace_start` refuses with a typed, actionable error.

3. **Hub slice:** implement `ACPWorkspaceExposureConnector` over the hub
   SDK (`HubConnection` etc.), honoring `allow_insecure_ws`
   (`server.rs:1125-1126`) and folder trust (`server.rs:1139`), and wire it
   per item 2. Until then `workspace status` works end-to-end and
   `workspace start` fails with upstream's own error shape.

## Verification commands (for the integration owner)

```sh
zsh workflows/swift-safe-verify.zsh build
zsh workflows/swift-safe-verify.zsh build-tests
zsh workflows/swift-safe-verify.zsh test --no-parallel
zsh workflows/swift-safe-verify.zsh build --product open-grok
```

Focused scopes (filters match TYPE names; check reported test counts,
never exit codes alone — a zero-match filter exits 0):

```sh
zsh workflows/swift-safe-verify.zsh test --no-parallel --filter ACPLeaderControlPlaneTests
zsh workflows/swift-safe-verify.zsh test --no-parallel --filter ACPLeaderControlPayloadTests
zsh workflows/swift-safe-verify.zsh test --no-parallel --filter ACPLeaderIPC
zsh workflows/swift-safe-verify.zsh test --no-parallel --filter WorkspaceCapabilityTests
```

Expected new coverage: ~14 control-plane host tests + ~8 payload golden
tests in `OpenGrokACPRuntimeTests`, and the rewritten tripwire in
`OpenGrokCLITests`.

## Proposed ledger text (for PORT_STATUS.md, wave-10 entry)

> **ACP — the leader control plane is live, and workspace status is on the
> wire.** `ACPLeaderServerMessage` gains a `controlResult` success case with
> serde's `{"Ok": ...}` shape (`protocol.rs:364-367`), and
> `ACPLeaderControlPlane` dispatches `get_leader_info` plus the workspace
> commands with upstream's state machine (`server.rs:1100-1226`):
> idempotent start, pause/resume/stop with upstream's exact no-exposure
> errors, failed-reconnect-stays-paused, sorted sessions, uptime through
> pauses, and `finalize_workspace_on_shutdown` on `stop()`. Status reads are
> lock-free behind in-flight mutations (`server.rs:172-174`) and mutations
> serialize through a task tail (`server.rs:1114`) — structurally upstream's
> `ArcSwap` + mutex, deliberately not an actor. `control_v1` and
> `workspace_exposure` now advertise true (`server.rs:153-160`);
> `runtime_cpu_profile` and `relaunch_v1` stay false with typed refusals.
> The hub connection is an injected seam (`ACPWorkspaceExposureConnector`);
> a backend-less leader refuses `workspace_start` with a typed error while
> `workspace_status` answers truthfully. The wave-9 tripwire inverted:
> `portDefaultLeaderBacksExposureAdvert` drives the real `ACPLeaderIPCHost`
> over the frame codec and fails if the control plane is dropped while the
> bit stays set. Deliberate divergences: integer control-error codes
> (100/101/102; upstream uses string `ControlErrorCode`), the port's
> `command` discriminator accepted alongside upstream's `type`, no
> profiler, no relaunch. **Known remaining gap:** the workspace route's
> `LeaderWorkspaceControlChannel.send` does not yet consume `controlResult`
> (CLI slice), and `LiveLeaderComposition` does not yet inject socket
> metadata or a hub connector — both handed off in INTEGRATION-w10-acp.md.
