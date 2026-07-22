// OpenGrokModels.swift
//
// Open Grok — Swift port of `xai-grok-models` plus the shell model-catalog
// surface that owns provider-aware defaults, aliases, caches, and capability
// truth for later sampling and UI layers.
//
// Scope (R13):
//   * Exact embedded `default_models.json` corpus
//   * Catalog assembly with provider-isolated remote partitions
//   * Deterministic default-model precedence (CLI > ENV > config > remote > bundled)
//   * xAI / Codex disk caches (isolated paths, ETag, TTL, origin binding)
//   * Capability queries that never invent truth from model names
//
// Non-scope (later slices): live AuthManager, sampler actor, ACP model wire
// mapping, pager UI. Credential material is injected via
// `ModelCatalogCredentialSnapshot`.

import Foundation

// Module umbrella. Public API is declared across:
//   DefaultModelsJSON, DefaultModels, ModelTypes, OrderedModelMap,
//   EndpointsConfig, ModelsConfig, CatalogResolution, DefaultModelSelection,
//   ModelGlobSet, ModelsCache, RemoteModelParse, KimiModels, FireworksModels,
//   CodexModels, CapabilityQuery, ModelsManager, EnvKeys, AuthScheme,
//   ModelsError, WireCodec, AtomicWrite.
