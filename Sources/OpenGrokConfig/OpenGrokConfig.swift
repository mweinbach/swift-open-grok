// OpenGrokConfig.swift
//
// Open Grok — Swift port of `xai-grok-config`.
//
// Shared config loading for Open Grok: `OPENGROK_HOME`/`~/.opengrok`
// resolution, layered TOML config (managed < user < requirements), macOS MDM
// managed preferences, `$VAR` expansion, `[[version_overrides]]`,
// `[[campaigns]]` overlays, requirements fail-closed enforcement, the
// managed-config cloud-cache marker, and Ed25519-signed managed-policy
// verification.
//
// The Swift manifest inverts the Rust `xai-grok-config-types -> xai-grok-config`
// edge: `OpenGrokConfig` depends on `OpenGrokConfigTypes` (not the reverse).
// `envBool` is therefore defined in `OpenGrokConfigTypes` and re-exported here.
//
// Module layout mirrors the Rust crate:
//   * TOML.swift             — `TOMLValue`, `TOMLError`, the TOML parser.
//   * Paths.swift            — `grokHome`, `defaultGrokHome`, `userGrokHome`,
//                              `grokApplication`, `systemConfigDir`,
//                              `claudeManagedSettingsPath`,
//                              `encodeCwdDirname` (urlencoding + BLAKE3),
//                              `decodeCwdFromDirname`, `sessionsCwdDir`,
//                              `ensureSessionsCwdDir`, `slugify`.
//   * Blake3.swift           — pure-Swift BLAKE3 for session-dir parity.
//   * Ed25519Portable.swift  — pure-Swift Ed25519 verify (Linux/Windows + tests).
//   * FsAtomic.swift         — `writeAtomically` (temp + rename).
//   * Shell.swift            — `chainSeparator`, `hasUnixUtilities`,
//                              `isCommandAvailable`, `ampersandSemantics`,
//                              `UnixShellKind`, `unixShellPath`.
//   * ConfigOverride.swift   — `ConfigOverrideEntry`, `takePatchArray`,
//                              `applyPatches`, `patchTouchesPath`,
//                              `patchTouchesAny`, `PATCH_STRIP_KEYS`.
//   * VersionOverrides.swift — `applyVersionOverrides`,
//                              `VersionOverrideError`, `VersionOverrideMeta`,
//                              `VERSION_OVERRIDES_KEY`.
//   * Campaigns.swift        — `CampaignEntry`, `CampaignOverrides`,
//                              `CampaignMeta`, `CAMPAIGNS_KEY`,
//                              `takeCampaigns`, `buildCampaignEntries`,
//                              `mergeCampaignEntries`, `filterActiveCampaigns`,
//                              `idsTouchingPaths`, `applyActiveCampaignPatches`,
//                              `takeCampaignEntries`.
//   * Loader.swift           — `loadTomlFile`, `loadConfigFile`,
//                              `loadFromDisk`, `loadManagedConfig`,
//                              `loadSystemManagedConfig`,
//                              `ManagedConfigLayer`, `managedConfigLayers`,
//                              `managedConfigLayersAt`, `ConfigLayers`,
//                              `CampaignsState`, `campaignsStatePath`,
//                              `loadDismissedIdsFromHome`,
//                              `deepMergeTOML`, `expandEnvVarsInTOML`,
//                              `expandEnvVarsInString`, `tomlErrorDetail`,
//                              `campaignsApplicationDisabled`,
//                              `loadEffectiveConfigDiskOnly`,
//                              `applyVersionOverridesWithRegistered`,
//                              `CAMPAIGNS_STATE_FILE`,
//                              `MANAGED_CONFIG_FILENAME`,
//                              `REQUIREMENTS_FILENAME`.
//   * Validation.swift       — `RequirementsError`, `RequirementsLayer`,
//                              `RequirementsSource`, `validateRequirements`,
//                              `loadMergedRequirements`, `requirementsLayers`,
//                              `failClosedFlagFromStr`.
//   * MacOSManaged.swift     — `MDM_REQUIREMENTS_SOURCE`,
//                              `managedPreferencesRequirements` (macOS-only).
//   * ManagedCache.swift     — `MANAGED_CONFIG_CACHE_FILE`,
//                              `ServingIdentity`, `SyncMarker`,
//                              `markManagedConfigSynced`,
//                              `managedDeploymentId`, `bumpRollbackFloor`,
//                              `isManagedConfigStaleFor`,
//                              `isManagedConfigHardStaleFor`,
//                              `managedPolicyCompromisedFor`,
//                              `managedConfigIdentityChanged`,
//                              `confirmedTeamSwitch`, `normalizeIdentity`.
//   * SignedPolicy.swift     — `EMBEDDED_DEPLOYMENT_CONFIG_PUBKEYS`,
//                              `SigError`, `SignedVerdict`,
//                              `verificationActive`,
//                              `embeddedKeyIdTrusted`,
//                              `verifySignedPayload`,
//                              `verifyManagedIdentityClaim`,
//                              `checkFetchIdentity`, `verifyFetched`,
//                              `verifyFetchedClaim`, `checkOnDiskMatches`,
//                              `writeSidecar`,
//                              `writeManagedIdentitySidecar`,
//                              `cloudCacheSignatureInvalid`,
//                              `signedCacheCompromised`,
//                              `managedIdentityClaimImposes`,
//                              `SIGNATURE_SIDECAR_FILE`,
//                              `MANAGED_IDENTITY_SIDECAR_FILE`,
//                              `nowUnix`.

import Foundation
import OpenGrokConfigTypes
import OpenGrokPaths
import OpenGrokEnvironment
import OpenGrokShared
import OpenGrokCLIChatProxyTypes
import OpenGrokVersion

// MARK: - Re-exports

/// Parse an env var as a boolean. `nil` if unset or unrecognized.
///
/// Re-exported from `OpenGrokConfigTypes` (the Swift manifest inverts the
/// Rust `xai-grok-config-types -> xai-grok-config` edge, so `envBool` lives
/// in the lower layer). Mirrors `xai_grok_config::env_bool`.
public func envBool(
    _ name: String,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> Bool? {
    OpenGrokConfigTypes.envBool(name, environment: environment)
}
