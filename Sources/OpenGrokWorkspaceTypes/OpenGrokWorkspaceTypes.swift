// OpenGrokWorkspaceTypes.swift
//
// Wire types for the `xai-grok-workspace` API — Swift port of the Rust crate
// `crates/codegen/xai-grok-workspace-types`. This target is intentionally
// pure-data: it depends only on `Foundation` and `OpenGrokShared` (for the
// shared `SessionID` / `ToolCallID` / `HunkID` newtypes and `JSONValue`
// stand-in for `serde_json::Value`). There is no async runtime, no I/O, no
// transport — making it cheap to depend on from anywhere, including the
// eventual remote workspace client.
//
// Module map (mirrors the Rust crate):
//   * `Metadata` — typed-string metadata map plus standard `META_*` keys.
//   * `RequestMessage` — the typed envelope shared by all RPC requests.
//   * `WorkspaceError` / `IoKind` — fully serializable error surface.
//   * `ChunkKind` — discriminator shared by every streaming chunk enum.
//   * `ToolChunk` / `OpsChunk` / `SessionChunk` / `ToolResponse` — stream
//     chunks for the three RPC domains plus the bidi tool-response flow.
//   * `WorkspaceEvent` / `WorkspaceTopic` / `WorkspaceTopicSet` /
//     `EventLag` — pub/sub events plus backpressure signal.
//   * `WorkspaceRequest` / `ToolRequest` / `WorkspaceOpsRequest` /
//     `SessionLifecycleRequest` — request enums.
//   * Supporting `types/*` structs/enums (config, files, git, hunk,
//     interaction, memory, permission, plan_mode, plugins, search, session,
//     skills, tools).
//   * `RpcEnvelope` / `RpcError` / `WorkspaceRpc` protocol + per-method
//     request/response types for the hub-proxied `workspace.*` dispatch.
//
// Wire format
// -----------
// Every enum that appears on the wire is **adjacently tagged** with
// `tag = "type", content = "data"`. The JSON wire shape is:
//
//   {"type": "<variant_name>", "data": <payload>}
//
// Adjacent (rather than internal) tagging is required because internal
// tagging fails for newtype variants wrapping non-struct payloads — e.g.
// `OpsChunk.gitMetadata(Option<GitMetadata>)`, `SessionChunk.sessionId(SessionId)`
// (a string), `WorkspaceOpsRequest.resolveFileRefs([String])`. Adjacent
// tagging works uniformly across all payload shapes (struct, newtype, unit)
// and gives the JSON wire format an explicit discriminator. Each variant
// maps directly to a protobuf `oneof` regardless of which serde tagging
// form is used; the wire-format choice here only affects the JSON
// representation.
//
// Wire-format struct fields use **snake_case** to match gRPC field
// conventions (proto field names are snake_case) unless the Rust source
// crate explicitly opts into `camelCase` (the hooks/plugins DTOs and the
// `client_fs_*` ops).
//
// Wire integer types
// ------------------
// Every `usize` field is replaced with `UInt64` (or `UInt32` for
// known-bounded sizes like `MemorySearch.limit`) so the wire width is
// pinned regardless of host. `Int64` is used for signed wire integers.
//
// Rust crate mapping: xai-grok-workspace-types
// (crates/codegen/xai-grok-workspace-types). See CRATE_MAP.md and
// PORT_PLAN.md (W1-S4).

import Foundation
import OpenGrokShared

/// MCP tool name delimiter: server names are qualified as `"server__tool"`.
///
/// Lives in `OpenGrokWorkspaceTypes` (instead of `OpenGrokWorkspace` or
/// `OpenGrokMCP`) so both the permission-validation layer and the MCP
/// transport layer can depend on it without dragging the full workspace or
/// `rmcp` into each other. Re-exported by the workspace permission module
/// for callers that historically imported it from there.
public let MCP_TOOL_NAME_DELIMITER: String = "__"

// MARK: - Identifier re-exports
//
// The Rust crate defines `SessionId`, `ToolCallId`, and `HunkId` newtypes
// with `#[serde(transparent)]` (bare JSON string wire form). `OpenGrokShared`
// already ports these as `SessionID` / `ToolCallID` / `HunkID`. Re-export
// them under the Rust crate's spelling so consumers can use either form
// without a cross-target dependency on a different module.

/// Rust `xai_grok_workspace_types::identity::SessionId` — see
/// `OpenGrokShared.SessionID` for the implementation. Serializes as a bare
/// JSON string.
public typealias SessionId = OpenGrokShared.SessionID

/// Rust `xai_grok_workspace_types::identity::ToolCallId` — see
/// `OpenGrokShared.ToolCallID` for the implementation. Serializes as a bare
/// JSON string.
public typealias ToolCallId = OpenGrokShared.ToolCallID

/// Rust `xai_grok_workspace_types::identity::HunkId` — see
/// `OpenGrokShared.HunkID` for the implementation. Serializes as a bare
/// JSON string.
public typealias HunkId = OpenGrokShared.HunkID
