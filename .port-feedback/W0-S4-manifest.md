# W0-S4 Manifest Feedback

## Summary

W0-S4 ("Shared serialization and identifiers") ports `xai-grok-shared` and
`prod-mc-cli-chat-proxy-types` into `OpenGrokShared` and
`OpenGrokCLIChatProxyTypes`. The predeclared manifest in `Package.swift`
declares both targets in `w0s4` with `dep()` (no dependencies), which is
correct for `OpenGrokCLIChatProxyTypes` but **missing a forward edge** for
`OpenGrokShared`.

## Missing dependency edge

### `OpenGrokShared` → `OpenGrokCLIChatProxyTypes`

**Rust reference:** `crates/codegen/xai-grok-shared/Cargo.toml` declares:
```toml
prod-mc-cli-chat-proxy-types = { path = "../../../prod/mc/cli-chat-proxy-types" }
```

**Rust usage:** `crates/codegen/xai-grok-shared/src/session/mod.rs` re-exports
a type from the proxy-types crate:
```rust
pub use prod_mc_cli_chat_proxy_types::feedback_types::FeedbackTerminalInfo;
```

Downstream Rust crates (e.g. `xai-grok-pager-render`) consume
`xai_grok_shared::FeedbackTerminalInfo`, which is actually the proxy-types
type re-exported through the shared crate.

**Swift impact:** The Swift `OpenGrokShared` target currently has no
`FeedbackTerminalInfo` type (it lives only in
`OpenGrokCLIChatProxyTypes/FeedbackTypes.swift`). When a downstream Swift
slice (e.g. W8-S3 `OpenGrokPagerRender`) needs `FeedbackTerminalInfo`, it
would have to import `OpenGrokCLIChatProxyTypes` directly rather than going
through `OpenGrokShared` as the Rust architecture does.

**Recommended manifest fix (for W0-S1 / integration slice):**
```swift
// In Package.swift, change the W0-S4 declaration from:
t.append(contentsOf: libs(w0s4, dep()))
// To:
t.append(.target(name: "OpenGrokCLIChatProxyTypes", dependencies: dep()))
t.append(.target(name: "OpenGrokShared", dependencies: dep(["OpenGrokCLIChatProxyTypes"])))
```

This matches the Rust dependency `xai-grok-shared → prod-mc-cli-chat-proxy-types`
and is a same-wave forward edge (allowed by the plan's intra-slice rule:
"only bootstrap/integration may change Package.swift").

**Why W0-S4 did not edit Package.swift:** The slice ownership rules prohibit
editing `Package.swift`; only W0-S1 may do so. The current stub works around
the missing edge by keeping `OpenGrokShared` self-contained (no
`FeedbackTerminalInfo` re-export) and documenting the local `JSONValue`
duplication in `OpenGrokCLIChatProxyTypes/JSONValue.swift`. This is
functionally correct for W0 but diverges from the Rust dependency graph.

## Other notes

- The `OpenGrokCLIChatProxyTypes.JSONValue` is a local duplicate of
  `OpenGrokShared.JSONValue` (simpler — `Double`-only numbers, no int/uint
  distinction). If the dependency edge above is added, a future slice may
  consolidate them. The wire form is identical for all values within
  Double's exact-integer range (< 2^53), which covers all proxy DTO fields.
- `WireJSONEncoder` in `OpenGrokShared/JSONValue.swift` uses
  `.withoutEscapingSlashes` to match `serde_json`'s default (no `\/`
  escaping) for byte-significant golden-fixture round-trips.
- `SessionTurnDelta` decoder requires the non-`#[serde(default)]` counter
  fields (throws `DecodingError` on missing), matching the Rust contract
  pinned by `session_turn_delta_latency_backward_compat`.
