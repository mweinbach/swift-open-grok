# open-grok verification map

This directory is the maintained source for verifying user-facing CLI behavior of `open-grok`. Read the index before driving the app, then use the matching feature file as the recipe.

## Baseline preconditions

- Work from the repo root of `swift-open-grok`.
- Build only through `zsh workflows/swift-safe-verify.zsh` (the helper does this).
- Put the helper on your mental PATH as:
  `.cursor/skills/verify-open-grok/scripts/control-open-grok`
- Run `control-open-grok launch` so `OPENGROK_HOME` is `/tmp/open-grok-verify-<run-id>`.
- Run `control-open-grok doctor` and require `doctor ok` with version equal to `OPEN_GROK_VERSION`.
- Never drive `~/.opengrok` or any home you did not create in this verify run.
- Never drive a binary whose `version --json` does not match `OPEN_GROK_VERSION`.

## Driving conventions

- Start every recipe from a fresh launched home unless the feature says otherwise.
- Treat every command as literal. Keep quoted flags and JSON keys unchanged.
- Run all product commands through `control-open-grok cli -- …` or `control-open-grok evidence … -- …`.
- Prefer JSON fields (`version`, `opengrok_home`, `default`, `models`) over human-formatted lines when both exist.
- Restore nothing on disk for these baseline routes (they are read-only aside from whatever empty dirs `OPENGROK_HOME` creates). Cleanup removes the home; keep artifacts.

## Proof and skip reporting

- Capture the command, stdout, stderr, and exit code under `.cursor/skills/verify-open-grok/artifacts/`.
- Mutation proof is not required for the baseline set; isolation proof for `paths` is required.
- Record the feature ID and entry point used with every artifact (the evidence helper writes this).
- Report an unreachable path with the attempted command and the refusal text (example: product `doctor` route unwired).
- Do not report a skipped entry point as verified through a different path.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph describing the user-visible behavior. It then uses exactly four H2 sections in this order.

1. `Sub-features` lists short IDs with one line for each behavior.
2. `How to get to it (user POV)` lists every user entry point.
3. `Driving it with control-open-grok` starts with `Preconditions:` and uses labeled bullets that pair each user action with an exact command and observable result.
4. `Gotchas` lists traps that can waste or invalidate a verification run.

Keep implementation details out of the map. Name only user paths, stable handles, required state, commands, and observable proof.

## Features

- [Version](./version.md) — identity string from `--version` / `version` / `version --json`.
- [Paths](./paths.md) — `OPENGROK_HOME` resolution and isolation via `paths` / `paths --json`.
- [Help](./help.md) — top-level help, topic help, and unknown-topic errors.
- [Models](./models.md) — default model and catalog listing.
- [Sessions list](./sessions.md) — empty and listed session history on the CLI.
