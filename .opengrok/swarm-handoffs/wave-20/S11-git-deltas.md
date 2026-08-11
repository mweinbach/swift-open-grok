# S11 — Packed Git OFS_DELTA / REF_DELTA resolution

## Files changed

| Path | Change |
|---|---|
| `Sources/OpenGrokGitStatus/ObjectStore.swift` | **MODIFIED** — added `resolvePackEntryAt`, `parseOfsDeltaOffset`, `applyGitDelta`, `readDeltaVarint`, `nextOffsetAfter`; replaced `packedDeltaUnsupported` throw with resolution call |
| `Sources/OpenGrokGitStatus/Types.swift` | **MODIFIED** — added `packedDeltaChainTooDeep` and `packedDeltaCorrupt` error cases |
| `Tests/OpenGrokGitStatusTests/OpenGrokGitStatusTests.swift` | **MODIFIED** — added `PackedGitDeltaTests` suite and updated `packedDeltaResolution` test |

## What changed

### ObjectStore.swift

**Delta resolution pipeline.** OFS_DELTA (type 6) and REF_DELTA (type 7)
entries now resolve instead of throwing `packedDeltaUnsupported`.

- **`resolvePackEntryAt`** — recursive resolver that walks a delta chain
  back to a non-delta base object, then applies deltas forward. Enforces
  `maximumDeltaChainDepth` (default 50, matching Git) and
  `maximumPackedObjectSize` at every level. OFS_DELTA resolves within the
  same pack file by negative offset; REF_DELTA resolves by OID through
  `readObject` (can cross to loose objects or other packs).

- **`parseOfsDeltaOffset`** — decodes Git's variable-length negative
  offset encoding for OFS_DELTA entries.

- **`applyGitDelta`** — applies Git delta instructions (copy-from-base
  and insert-literal commands) to reconstruct a target object from its
  base. Validates base-size header, result-size header, copy bounds, and
  result length. Refuses the reserved 0x00 instruction byte.

- **`readDeltaVarint`** / **`nextOffsetAfter`** — helpers for delta
  varint decoding and binary-search on sorted pack offsets.

- **`GitObjectStore.init`** now accepts `maximumDeltaChainDepth`.

- **`PackedObjectLocation`** carries `sortedOffsets: [UInt64]`** from the
  pack index, used to determine object boundaries for intermediate delta
  bases during chain resolution.

- Prefix read increased from 16 to 48 bytes to accommodate OFS_DELTA
  variable-length offsets and REF_DELTA base OIDs in the entry header.

### Types.swift

Two new error cases:

- `packedDeltaChainTooDeep(oid:depth:limit:)` — chain exceeds configured
  depth ceiling.
- `packedDeltaCorrupt(oid:reason:)` — structural corruption in a delta
  entry (bad offset, truncated header, copy out of bounds, size mismatch,
  reserved instruction, etc.).

### OpenGrokGitStatusTests.swift

Former `packedDeltaRefusal` test renamed to `packedDeltaResolution` and
updated to assert successful resolution of both OFS_DELTA and REF_DELTA
single-hop entries.

New `PackedGitDeltaTests` suite with 6 tests:

| Test | Acceptance criterion |
|---|---|
| `copyFromBaseDelta` | Copy + insert instructions produce correct result |
| `nestedDeltaChain` | Two-deep OFS_DELTA chain resolves correctly |
| `deltaChainTooDeep` | Chain exceeding depth limit → `packedDeltaChainTooDeep` |
| `deltaResultTooLarge` | Oversize result → `packedObjectTooLarge` |
| `corruptDeltaBaseOffset` | Bogus OFS_DELTA offset → `packedDeltaCorrupt` |
| `nonDeltaRegression` | Non-delta packed objects still resolve after delta support |

Test helpers added: `encodeCopyInsertDelta`, `encodeDeltaVarint` for
constructing delta payloads with mixed copy/insert instructions.

## Verification

```
$ zsh workflows/swift-safe-verify.zsh build --target OpenGrokGitStatus
Build complete! (1.58 sec)                             # exit 0

$ zsh workflows/swift-safe-verify.zsh build --target OpenGrokGitStatusTests
Build complete! (1.58 sec)                             # exit 0

$ xcrun xctest .build/workflow-safe/out/Products/Debug/OpenGrokGitStatusTests.xctest
Test run with 34 tests in 3 suites passed after 0.097 seconds.   # exit 0
```

All 34 tests pass: 22 pre-existing + 6 delta-specific + 6 pack-object
(including the updated `packedDeltaResolution`).

Full `swift test --filter` is blocked by pre-existing build errors in
`OpenGrokCLITests` (NSLock async-context unavailability on macOS 27 SDK),
unrelated to this slice.

## Acceptance checklist

- [x] Single-hop OFS delta fixture (`packedDeltaResolution`)
- [x] Single-hop REF delta fixture (`packedDeltaResolution`)
- [x] Bounded nested chain fixture (`nestedDeltaChain`)
- [x] Oversize/deep chain refusal (`deltaChainTooDeep`, `deltaResultTooLarge`)
- [x] Corrupt-base refusal (`corruptDeltaBaseOffset`)
- [x] No regression for loose and non-delta packed objects (`nonDeltaRegression`, `nonDeltaPackedParity`)

## Scope — what was NOT touched

Nothing outside `Sources/OpenGrokGitStatus/` and
`Tests/OpenGrokGitStatusTests/`. No Package.swift, no LiveComposition, no
CLI files, no ledger updates.
