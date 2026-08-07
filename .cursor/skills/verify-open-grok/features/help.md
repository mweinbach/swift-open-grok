# Help

Help prints the CLI usage blob and per-topic help for named commands. Unknown topics error instead of silently reprinting the top-level blob.

## Sub-features

- `help-root` prints the top-level usage text.
- `help-topic` prints a named topic (example: `paths`, `sessions`).
- `help-unknown` errors with a topic list when the name is wrong.

## How to get to it (user POV)

- Run `open-grok help`.
- Run `open-grok help <topic>` (for example `paths` or `sessions`).
- Run `open-grok help` with a misspelled topic to see the error.

## Driving it with control-open-grok

Preconditions:

- `control-open-grok doctor` reports `doctor ok`.

- **Root help.** Show top-level usage. Run `control-open-grok evidence help help-root -- help`. Exit `0`; stdout starts with `Open Grok — command line` and mentions `OPENGROK_HOME`.
- **Topic help.** Show paths topic. Run `control-open-grok evidence help help-topic-paths -- help paths`. Exit `0`; stdout includes `open-grok paths [--json]`.
- **Sessions topic.** Show sessions topic. Run `control-open-grok evidence help help-topic-sessions -- help sessions`. Exit `0`; stdout includes `open-grok sessions <COMMAND>` and `list`.
- **Unknown topic.** Ask for a missing topic. Run `control-open-grok evidence help help-unknown -- help nosuchtopic`. Exit non-zero (observed `2`); stderr contains `no help topic named 'nosuchtopic'` and a `Topics:` list. Note: `evidence` returns that non-zero exit — that is the success condition for this bullet.
- **Proof.** Keep artifacts under `artifacts/help/`. Root help alone is insufficient when topic and unknown-topic entry points are listed.

## Gotchas

- Exit code for unknown topics is usage-class (not `0`). Assert the refusal text and non-zero exit; do not require a specific numeric code beyond "non-zero" unless you capture it.
- Topic names are stable handles from the printed `Topics:` list; do not invent aliases beyond what that list shows (`path` / `paths` both appear).
- A stale binary may still print an older help dialect. Version-mismatch doctor failure comes first.
