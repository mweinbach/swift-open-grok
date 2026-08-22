// OpenGrokCodeModeProtocol.swift
//
// Protocol and tool-description types for the Open Grok embedded JavaScript
// code-mode runtime. Ported from the Rust crate
// `crates/codegen/xai-grok-code-mode-protocol`.
//
// Portions of this crate are derived from OpenAI Codex (Apache-2.0),
// source revision 2be648ba4a6c159a3d80b1c07e7323cbd5efef8f.
// https://github.com/openai/codex
//
// The crate defines:
//   * The `exec` / `wait` tool description builders and the `// @exec:`
//     pragma parser (`Description.swift`).
//   * The JSON-Schema-to-TypeScript renderer used to surface nested-tool
//     argument shapes to the model (`Description.swift`).
//   * The function-call output content items (text / image, with
//     `image_detail`) and the default image-detail constant
//     (`Response.swift`).
//   * The runtime wire types: `ExecuteRequest`, `WaitRequest`,
//     `RuntimeResponse`, `WaitOutcome`, `ExecuteToPendingOutcome`,
//     `WaitToPendingOutcome`, `WaitToPendingRequest`,
//     `CodeModeNestedToolCall`, plus the default yield-time /
//     max-output-tokens constants (`Runtime.swift`).
//   * The session protocol: `CellId`, `StartedCell`,
//     `CodeModeSessionDelegate`, `CodeModeSession`,
//     `CodeModeSessionProvider` — translated to Swift `async`/`await` +
//     `Sendable` protocols so the runtime crate (`OpenGrokCodeMode`) can
//     implement them with actors (`Session.swift`).
//   * Bounded, drop-oldest nested-tool progress channels and typed text /
//     structured-payload chunks (`Progress.swift`).
//
// Rust crate mapping: xai-grok-code-mode-protocol
// (crates/codegen/xai-grok-code-mode-protocol). See CRATE_MAP.md and
// PORT_PLAN.md (W1-S4).

import Foundation
import OpenGrokShared

/// Public tool name for the code-mode `exec` tool. Nested tools are
/// exposed on the global `tools` object inside the JS isolate.
public let PUBLIC_TOOL_NAME: String = "exec"

/// Public tool name for the code-mode `wait` tool (resumes a running
/// cell by id).
public let WAIT_TOOL_NAME: String = "wait"
