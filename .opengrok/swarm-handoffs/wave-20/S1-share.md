# S1 — Share signed-upload + backend clients

## Files changed

| Path | Change |
|---|---|
| `Sources/OpenGrokShellSessionSupport/ShareClients.swift` | **NEW** — `ShareSignedUploadClient` and `ShareBackendClient` protocols |
| `Sources/OpenGrokCLI/LiveShareComposition.swift` | **MODIFIED** — replaced unconditional upload-blocker with injectable client flow |
| `Tests/OpenGrokCLITests/LiveShareCompositionTests.swift` | **MODIFIED** — added success, backend-failure, mid-flight-boundary tests |

## What changed

### ShareClients.swift (new)

Two injectable protocols in `OpenGrokShellSessionSupport`:

- **`ShareSignedUploadClient`** — the GCS signed-URL upload
  (share.rs:150-199). Best-effort: errors never thrown. Boundary-gated twice
  (before serialize, before send), matching upstream's
  `upload_share_data_to_gcs`.

- **`ShareBackendClient`** — the backend share orchestration
  (client.rs:360-388). `shareSession` performs upsert → save (413 OK) →
  create share link → return URL.

- **`ShareBackendError`** — typed error for the backend path.

No `Package.swift` change needed — both protocols live in
`OpenGrokShellSessionSupport` which the CLI target already imports.

### LiveShareComposition.swift

The file header comments are updated (pin bumped to 650c1db7).

`run()` and `session()` now accept optional `signedUploadClient` and
`backendClient` parameters (both default `nil`). The flow:

1. All existing gates (auth → sharing_enabled → ZDR → lookup → boundary → empty) unchanged.
2. **When `backendClient` is `nil`**: the old fail-closed blocker fires ("upload path is not ported…"). All existing tests still pass through this path.
3. **When `backendClient` is present**:
   - If `signedUploadClient` is also present and boundary permits: upload to GCS (best-effort).
   - Mid-share boundary recheck (`ShareExportGate.authorizePostExport`): refuses if boundary closed during upload.
   - Backend `shareSession` call.
   - On success: prints share URL to `streams.out`.
   - On failure: throws `CLIApplicationError.failed("Failed to share session: …")`.

### Tests

Existing gate tests unchanged. New tests:

| Test | What it covers |
|---|---|
| `successfulShare` | Full path: upload + backend → URL printed |
| `shareWithoutSignedUpload` | Backend-only (no GCS client) → URL printed |
| `backendFailure` | Backend throws → no URL, failure message |
| `midShareBoundaryClosure` | Upload closes boundary → post-export recheck refuses, backend never called |

Mock clients: `MockShareSignedUploadClient` (records calls), `MockShareBackendClient` (canned URL or error), `ClosingShareSignedUploadClient` (closes the boundary during upload to test the recheck).

## LiveComposition / Package.swift integration notes

### LiveComposition.swift (FORBIDDEN — textual diff for lead)

The launcher's share-session route currently calls `LiveShareComposition.session(for:context:liveBoundaries:)`. To wire the live clients, add `signedUploadClient:` and `backendClient:` parameters:

```swift
// In the share route handler:
try await LiveShareComposition.session(
    for: command,
    context: context,
    liveBoundaries: liveBoundaries,
    signedUploadClient: /* real ShareSignedUploadClient impl */,
    backendClient: /* real ShareBackendClient impl */
)
```

No `Package.swift` changes needed — `ShareClients.swift` is in an existing target.

### LiveACPExtensionMethods.swift (FORBIDDEN — textual diff for lead)

For the `x.ai/share_session` ACP path, register the method on the router and
wire a handler that calls `LiveShareComposition.run()` with the ACP params
decoded as `ShareSessionRequest`, using the live session's boundary from the
session table. The `liveBoundaries` closure should read the running session's
`ExportBoundary`. The handler's return shape is `ShareSessionResponse` encoded
through `ShareSessionWireCodec`.

## Rust cites used

| Cite | What |
|---|---|
| share.rs:31-136 | `handle_share_session` — full ACP handler flow |
| share.rs:150-199 | `upload_share_data_to_gcs` — GCS signed-URL upload |
| client.rs:360-388 | `BackendClient::share_session` — backend orchestration |
| share.rs:117-123 | mid-share boundary recheck |
| share.rs:163-164, :182-184 | double boundary gate in GCS upload |

## Deliberately NOT done

- **Real `ShareSignedUploadClient` / `ShareBackendClient` implementations** — these need HTTP transport, auth headers, and the GCS signed-URL proxy endpoint. The protocols are ready; the implementations belong to the integration lead who controls `LiveComposition.swift` and the HTTP stack.
- **`x.ai/share_session` ACP handler** — needs `LiveACPExtensionMethods.swift` (FORBIDDEN). Handed back as textual integration notes above.
- **Session metadata upload** (share.rs:139-146, fire-and-forget `upload_session_metadata`) — deliberate omission; the trace/telemetry upload subsystem is not ported.
- **`agent_id` parameter** — upstream passes `agent_id()` to `share_session`; this port's `ShareBackendClient.shareSession` does not carry it. The protocol can be extended when the identity subsystem is ported.
- **Remote settings fetch** — `sharing_enabled` still defaults to `false` when `remoteSettings` is `nil` (upstream's fail-closed default). A `/v1/settings` fetch is needed to actually enable sharing for real users.

## Build verification

- `OpenGrokShellSessionSupport` builds clean.
- `OpenGrokCLI` has a pre-existing error in `LiveMCPACPHandlers.swift` (S3's `handleToggle`/`handleToggleTool` not yet landed) — not caused by this slice.
- All changed files lint clean.
