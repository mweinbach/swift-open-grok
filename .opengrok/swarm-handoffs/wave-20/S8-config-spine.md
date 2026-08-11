# S8 — Config authority spine

Date: 2026-08-10
Owner: S8 slice agent
Rust reference: `650c1db7` at `~/Projects/grok-build`

## What was delivered

Three new files in `Sources/OpenGrokConfig/`, one test file in
`Tests/OpenGrokConfigTests/`, implementing the config authority spine:
RemoteSettings allowlist, documented GROK_* env gates, and the
EffectiveFeatures precedence resolver.

### 1. RemoteSettingsAllowlist (`RemoteSettingsAllowlist.swift`)

Explicit, field-by-field allowlist that gates which `RemoteSettings` fields
may influence runtime behavior.

**Allowlisted fields** (11 fields, each with a cited Swift consumer):

| Wire name | Consumer |
|---|---|
| `telemetry_mode` | `TelemetryModeResolver.resolve()` |
| `telemetry_enabled` | `TelemetryModeResolver.resolve()` |
| `external_otel_disabled` | `ExternalOtelRemotePolicy.init` |
| `external_otel_content_gates_locked` | `ExternalOtelRemotePolicy.init` |
| `privacy_notice_rollout` | `resolvePrivacyNoticeRollout()` |
| `privacy_banner_reshow_days` | `resolvePrivacyBannerReshowDays()` |
| `announcements` | `LiveAnnouncementsComposition` |
| `sharing_enabled` | `LiveShareComposition` |
| `workspace_command_enabled` | `workspaceCommandGate()` |
| `zdr_access_enabled` | `refreshPrivacyBannerState()` |
| `gate_message` | `refreshPrivacyBannerState()` |

**Fail-closed**: `AllowlistedRemoteSettings(projecting:)` copies only the
listed fields. All other `RemoteSettings` fields (100+ fields) are dropped
and cannot reach runtime resolvers.

The `remoteSettingsAllowlistedWireNames` set enables negative tests.

### 2. GrokEnvGates (`GrokEnvGates.swift`)

Typed registry of `GROK_*` / `OPENGROK_*` environment variables with live
Swift consumers. Each gate is a static method with an injectable
`environment` parameter. No new variables are invented — every entry cites
its consumer.

Gates registered:
- `telemetryEnabled` (OPENGROK_/GROK_ spelling)
- `sessionRecap`, `webFetch`, `imageGen`, `imageEdit`
- `feedbackEnabled`, `workspaceCommand`, `folderTrust`
- `workflows`, `campaigns`, `schedulerBackgroundLoops`
- `privacyNoticeRollout`
- `shell` (raw string)
- `worktreeAutoGc`, `worktreeAutoGcDryRun`
- `disableAutoupdater`, `crashHandler`

### 3. EffectiveFeatures (`EffectiveFeatures.swift`)

Resolved feature snapshot combining env gates, local TOML `[features]`
config, and allowlisted remote settings with documented precedence:

```
requirement > env > config(TOML) > remote > default
```

Resolved fields (only those with live Swift consumers):
- `sessionRecap` (default ON)
- `webFetch` (default ON)
- `imageGen` (default ON)
- `imageEdit` (default ON)
- `feedback` (default ON)
- `workspaceCommand` (default OFF, remote-wired)
- `folderTrust` (default ON)
- `workflows` (default OFF)
- `sharing` (default OFF, remote-wired)

Telemetry mode is deliberately excluded — it has its own dedicated resolver
(`TelemetryModeResolver`) with managed-settings pre-mutation and a string mode value (not bool). Duplicating it in `EffectiveFeatures` would create two sources of truth.

### 4. Tests (`ConfigSpineTests.swift`)

**Precedence tests:**
- Requirement wins over all tiers
- Env wins over config and remote
- Config wins over remote and default
- Remote wins over default
- Default used when nothing set
- Full five-tier chain: requirement > env > config > remote > default

**Negative inert tests:**
- `sessionRecap` remote cannot override (not allowlisted for EffectiveFeatures remote tier)
- `webFetchEnabled` remote cannot override
- `imageGenEnabled` remote cannot override
- `feedbackEnabled` remote cannot override
- `folderTrustEnabled` remote cannot override
- `lspToolsEnabled` remote cannot reach `AllowlistedRemoteSettings`
- `compactionMode` remote cannot reach `AllowlistedRemoteSettings`
- Non-allowlisted wire names are not in the allowlist set

**Live-seam proofs:**
- Announcements: projected announcements readable with id/severity
- Telemetry mode: `telemetryMode` and `telemetryEnabled` project correctly
- Workspace command: resolves through `EffectiveFeatures` via remote tier
- Sharing: resolves through `EffectiveFeatures` via remote tier
- Privacy banner: both fields project

## Verification

```
$ zsh workflows/swift-safe-verify.zsh build --target OpenGrokConfig
Build complete! (5.52 sec)

$ zsh workflows/swift-safe-verify.zsh build --target OpenGrokCLI
Build complete! (after lead wiring)
```

## Files changed

- `Sources/OpenGrokConfig/RemoteSettingsAllowlist.swift` (new)
- `Sources/OpenGrokConfig/GrokEnvGates.swift` (new)
- `Sources/OpenGrokConfig/EffectiveFeatures.swift` (new)
- `Tests/OpenGrokConfigTests/ConfigSpineTests.swift` (new)

## LiveComposition wiring (lead-integrated 2026-08-10)

1. **Announcements**: Still served from `AnnouncementsService` cache/fetch,
   not inline `RemoteSettings.announcements` — no consumer to re-point yet.
   Field remains allowlisted for when that path lands.
2. **Telemetry**: `LiveTelemetry.inputs` projects via
   `AllowlistedRemoteSettings` before `TelemetryResolutionInputs`.
3. **Workspace command**: `workspaceCommandGate` reads
   `AllowlistedRemoteSettings(projecting:).workspaceCommandEnabled`
   (keeps `.unknown` when settings are absent).
4. **Sharing**: `LiveShareComposition` reads allowlisted `sharingEnabled`.
5. **Privacy banner**: `refreshPrivacyBannerState` projects allowlisted
   privacy/ZDR/gate fields before `resolvePrivacy*` / banner state.

Also fixed `ConfigSpineTests` compile: `JSONValue` case is `.bool`, not
`.boolean`. Suite-blocker NSLock-in-async in
`LiveWorkspaceCompositionTests.HubMockMcpTransport` fixed while unblocking
ConfigSpine runs.

## Deliberately not done

- No new `GROK_*` variables without consumers (per FORBIDDEN rules).
- Telemetry mode is not duplicated in `EffectiveFeatures` — the existing
  `TelemetryModeResolver` handles its unique precedence chain.
- Remote settings fields without Swift consumers (compaction_mode,
  file_toolset, default_model, subscription_tier, etc.) are not wired
  and are tested inert.
- Full `EffectiveFeatures.resolve` at every gate (would change workspace
  `.unknown` semantics when settings are unloaded) — allowlist choke only.
- No Package.swift or ledger edits from the slice agent (FORBIDDEN).
