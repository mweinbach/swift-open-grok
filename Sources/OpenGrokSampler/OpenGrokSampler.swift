// OpenGrokSampler.swift
//
// Open Grok — Swift port of `xai-grok-sampler`
// (`crates/codegen/xai-grok-sampler`).
//
// Layered sampling runtime:
//   * Layer 1 — `SamplingClient` posts streaming / non-streaming requests
//     through an injected `HTTPTransport` (no concrete Auth/Models imports).
//   * Layer 2 — pure stream transforms emit `SamplingEvent`s with exactly-one
//     terminal completion (Completed or Failed).
//   * Layer 3 — `SamplerActor` / `SamplerHandle` own concurrent requests,
//     retry classification, cancellation, and Codex sticky-routing turn state.
//
// Authentication and model catalog policy are injected via protocols
// (`BearerResolver`, config snapshots). Provider transport policy is selected
// by `ModelProvider` through `providerAdapter(_:)`.

import Foundation
import OpenGrokHTTP
import OpenGrokSamplingTypes
import OpenGrokShared
