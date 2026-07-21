# W1-S3 Manifest / Integration Feedback

## Blockers preventing `swift test --filter` for W1-S3 test targets

`swift test --filter OpenGrokSamplingTypesTests` (and the ChatState / TokenEstimation
equivalents) build the **entire** test-target graph before running the filtered suite.
Three same-wave (Wave 1) sibling slices have landed source files that do not compile
under Swift 6.1, which prevents `swift test` from building *any* test target — including
W1-S3's, even though W1-S3's own library and test sources compile cleanly.

These files are outside W1-S3's owned paths (`Sources/OpenGrokSamplingTypes/`,
`Sources/OpenGrokChatState/`, `Sources/OpenGrokTokenEstimation/` and their `Tests/`
peers), so W1-S3 cannot fix them per the strict ownership rules. They are listed here
so the owning slices can repair them.

### 1. OpenGrokToolTypes (W1-S1) — `default` used as identifier

- `Sources/OpenGrokToolTypes/OpenGrokToolTypes.swift:243:16` —
  `public var default: JSONValue?` uses the reserved keyword `default` as a property
  name without backticks. Fix: `` public var `default`: JSONValue? `` (and update all
  call sites).
- `Sources/OpenGrokToolTypes/OpenGrokToolTypes.swift:320:31` — cascading parse error
  from the above.
- `Sources/OpenGrokToolTypes/TaskTools.swift:1066` and following — multiple invalid
  escape sequences and unterminated string literals (e.g. `\u{...}` misuse, `$`
  identifiers without backticks). These are pre-existing in the W1-S1 implementation
  and are not W1-S3's to fix.

### 2. OpenGrokWorkspaceTypes (W1-S4) — `internal` used as identifier

- `Sources/OpenGrokWorkspaceTypes/WorkspaceError.swift:172:10` / `:173:10` —
  `internal` (a Swift reserved keyword) used as an identifier without backticks.
  Fix: `` `internal` ``.

### 3. OpenGrokConfigTypes (W1-S5) — `default` used as identifier

- `Sources/OpenGrokConfigTypes/Flags.swift:90:28` —
  `@inlinable public func default(_ v: Bool) -> BoolFlag` uses `default` as a method
  name without backticks. Fix: `` public func `default`(_ v: Bool) -> BoolFlag ``.

## What W1-S3 verified despite these blockers

- `swift build --target OpenGrokTokenEstimation` → **Build complete** (green).
- `swift build --target OpenGrokShared --target OpenGrokCLIChatProxyTypes` →
  **Build complete** (W0-S4 dependencies green).
- `swift build --target OpenGrokSamplingTypes` and `swift build --target OpenGrokChatState`
  → **Build complete** after the W1-S3 implementation landed (see handoff).
- The W1-S3 test sources compile against the W1-S3 library targets; full test
  execution is gated only on the sibling-slice fixes above.

No `Package.swift` changes are required by W1-S3: the manifest already predeclares
`OpenGrokSamplingTypes`, `OpenGrokChatState`, `OpenGrokTokenEstimation`, their test
targets, and the dependency edges (`OpenGrokChatState → OpenGrokSamplingTypes`,
all three → W0-S4). No new targets, products, or dependency edges are needed.
