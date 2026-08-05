// OpenGrokCodeMode.swift
//
// The Code Mode engine: cell lifecycle, nested tool dispatch seam, and the
// protocol projection. Ported from the Rust crate `xai-grok-code-mode`
// (crates/codegen/xai-grok-code-mode), which is adapted from OpenAI Codex's
// `codex-code-mode` crate (Apache-2.0, revision
// 2be648ba4a6c159a3d80b1c07e7323cbd5efef8f).
//
// Layering, matching the Rust crate one module at a time:
//
//   Rust                        Swift
//   -------------------------   ------------------------------------------
//   src/runtime/*               OpenGrokJavaScriptRuntime (separate target)
//   src/cell_actor/*            CodeModeCell.swift
//   src/session_runtime/*       CodeModeSessionRuntime.swift
//   src/service.rs              InProcessCodeModeSession.swift
//
// Plus two files with no Rust counterpart, which state seams the Rust
// engine expresses through its host application:
//
//   CodeModeToolExecutor.swift        — the nested-dispatch callback the
//                                        live composition implements
//   CodeModeTransportProjection.swift — what the model sees vs what the
//                                        transport keeps hidden
//
// A session is durable for a compatible agent timeline: cells share the
// `store()` / `load()` map, a terminated or completed cell id fails closed
// on the next `wait`, and `shutdown()` disposes every runtime.

import Foundation
