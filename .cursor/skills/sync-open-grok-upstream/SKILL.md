---
name: sync-open-grok-upstream
description: "Update the Rust reference pin, evaluate upstream deltas, update protocol fixtures, and forward-port changes into the Swift Open Grok workspace. Use when fetching upstream releases, re-pinning grok-build/open-grok commits, or updating protocol fixtures."
---

# Sync Open Grok Upstream (Swift Port)

Instructions for re-evaluating the upstream Rust reference pin in [`open-grok`](https://github.com/mweinbach/open-grok) (or the location that houses the Rust repository), updating protocol fixtures, and forward-porting changes into [`swift-open-grok`](https://github.com/mweinbach/swift-open-grok) (or the local directory that houses the Swift repository).

---

## 1. Inspect Upstream Rust Delta

1. **Locate the reference repository**:
   - Reference source: [`github.com/mweinbach/open-grok`](https://github.com/mweinbach/open-grok) (or the location that houses the Rust repository, e.g. `../open-grok` or `../grok-build`).
2. **Review current pin vs target pin**:
   - Current pin is recorded at the top of [`PORT_STATUS.md`](PORT_STATUS.md) (e.g. `650c1db7c2e73c59cec88bf3c6359751d6cef1bd`).
   - Run git log and diff across the pin range:
     ```sh
     git log <old_pin>..<new_pin> --oneline
     git diff <old_pin>..<new_pin> --stat crates/codegen/
     ```
3. **Categorize Delta Commits**:
   - Substantive feature/security/wire changes (e.g. provider wire headers, service tiers, reasoning pacing).
   - Version bumps and release stamps.
   - Non-substantive documentation or upstream-only CI changes.

---

## 2. Re-evaluate Protocol Fixtures & Version

1. **Inspect Protocol Fixture Diff**:
   - Check if the upstream diff touches any fixture source in `ProtocolFixtures/`:
     ```sh
     git diff <old_pin>..<new_pin> -- ProtocolFixtures/
     ```
2. **Update Release Stamp**:
   - Update [`OPEN_GROK_VERSION`](OPEN_GROK_VERSION) to match the new release version (e.g. `0.1.220-open-grok.58`).
   - Update the CLI version fixture in `ProtocolFixtures/cli/version.json` and any version-stamped golden files (e.g. GCRX sample headers).
3. **Regenerate Protocol Manifests** if protocol definitions changed:
   ```sh
   ./scripts/regenerate-protocol-manifest.sh
   ```

---

## 3. Forward-Port Changes into Swift Targets

1. **Map Touched Files to Swift Targets**:
   - Consult [`CRATE_MAP.md`](CRATE_MAP.md) to locate the corresponding Swift target in `Sources/`.
2. **Apply Changes Under Swift 6 Concurrency & Modular Rules**:
   - Keep files under the **~3,000 LOC ceiling**.
   - Keep stored properties in primary actor files, logic in domain extensions.
   - Guard against CRLF scans, `waitUntilExit()` deadlocks, and `try?` silent drops.
   - Ensure the 7-stage security gate sequence remains intact.

---

## 4. Verify and Record

1. **Compile and Test**:
   ```sh
   # 1. Build test targets
   zsh workflows/swift-safe-verify.zsh build-tests

   # 2. Run authoritative serial test gate
   zsh workflows/swift-safe-verify.zsh test --no-parallel

   # 3. Build product and run CLI smoke
   .agents/skills/verify-open-grok/scripts/control-open-grok ensure-build --force
   .agents/skills/verify-open-grok/scripts/control-open-grok doctor
   ```
2. **Update Ledgers**:
   - Update [`PORT_STATUS.md`](PORT_STATUS.md) header with the new reference pin, date, test counts, and delta analysis.
   - Update [`PARITY_ROADMAP.md`](PARITY_ROADMAP.md) if roadmap items were closed or shifted.
