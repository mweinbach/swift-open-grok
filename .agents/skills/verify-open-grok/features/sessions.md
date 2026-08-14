# Sessions list

Sessions list shows recent conversations stored under the active `OPENGROK_HOME`. On a fresh verify home the honest success state is an empty list.

## Sub-features

- `sessions-list-empty` reports no sessions on a new home.
- `sessions-help` documents list/search/delete/show via `help sessions` (cross-check with the help feature).

## How to get to it (user POV)

- Run `open-grok sessions list`.
- Run `open-grok help sessions` for the subcommand shape.
- Resume is a root flag (`open-grok --resume`), not a `sessions` subcommand — not part of this feature's drive.

## Driving it with control-open-grok

Preconditions:

- Fresh home from `control-open-grok launch` (no prior sessions written into it).
- `control-open-grok doctor` reports `doctor ok`.

- **Empty list.** List sessions. Run `control-open-grok evidence sessions sessions-list-empty -- sessions list`. Exit `0`; stdout is `No sessions found.` (plus newline).
- **Help cross-check.** Confirm the list entry is documented. Run `control-open-grok evidence sessions sessions-help -- help sessions`. Exit `0`; stdout mentions `list`.
- **Proof.** Artifacts under `artifacts/sessions/`. On a fresh home, finding sessions is a failed isolation proof (wrong home), not a pass.

## Gotchas

- Driving against `~/.opengrok` can show real user sessions and must never be used for verify.
- Creating a session (interactive / headless `-p`) needs credentials or a mock provider and is out of scope for this baseline feature. Do not invent a session just to list it unless a later map entry owns that path.
- `sessions show` / `delete` / `search` need an id; skip them until a mapped create path exists.
