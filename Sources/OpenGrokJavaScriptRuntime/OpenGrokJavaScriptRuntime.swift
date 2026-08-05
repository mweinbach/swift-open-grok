// OpenGrokJavaScriptRuntime.swift
//
// Embedded, per-cell JavaScript runtime for Open Grok's Code Mode. Ported
// from the Rust crate `xai-grok-code-mode`'s `src/runtime` module
// (crates/codegen/xai-grok-code-mode/src/runtime/{mod,globals,callbacks,
// value,timers,module_loader}.rs), which is itself adapted from OpenAI
// Codex's `codex-code-mode` crate (Apache-2.0, revision
// 2be648ba4a6c159a3d80b1c07e7323cbd5efef8f).
//
// Shape of the port
// -----------------
// The Rust runtime owns a dedicated OS thread per cell running a V8
// isolate, driven by two synchronous channels (`RuntimeCommand` and
// `RuntimeControlCommand`) and publishing `RuntimeEvent`s back to the cell
// actor. This port keeps that architecture verbatim and swaps V8 for
// JavaScriptCore:
//
//   * `JavaScriptCellRuntime` owns one `Thread` + one `JSContext`
//     (`spawn_runtime` / `run_runtime`).
//   * `JavaScriptRuntimeCommand` / `JavaScriptRuntimeControlCommand` /
//     `JavaScriptRuntimeEvent` mirror the Rust enums one-for-one.
//   * Host functions install the same global surface (`tools.*`,
//     `ALL_TOOLS`, `text`, `image`, `generatedImage`, `store`, `load`,
//     `notify`, `yield_control`, `exit`, `setTimeout`, `clearTimeout`).
//   * Termination uses the JavaScriptCore execution-time-limit watchdog in
//     place of `v8::IsolateHandle::terminate_execution`, so a busy JS loop
//     is interruptible.
//
// Divergences from the Rust source are recorded beside the code that
// diverges and in the slice's integration notes.

import Foundation
