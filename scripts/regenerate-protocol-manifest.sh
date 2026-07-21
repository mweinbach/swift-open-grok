#!/usr/bin/env bash
#
# scripts/regenerate-protocol-manifest.sh
#
# Deterministic, network-free regeneration of ProtocolFixtures/manifest.json.
# The OpenGrokProtoBuildPlugin command is read-only (sandboxed); this helper
# performs the write side of the protocol-fixture tooling.
#
# The manifest format (version/generatedAt/referenceRevision/files with
# path/sizeBytes/sha256) matches OpenGrokBuildSupport.GeneratedManifest so the
# plugin and the Wave 11 compatibility tests consume the same file.
#
# Usage: scripts/regenerate-protocol-manifest.sh [--reference-revision REF]
set -euo pipefail

cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
FIX_DIR="ProtocolFixtures"
MANIFEST="$FIX_DIR/manifest.json"
REF="${1:-}"
if [[ "$REF" == "--reference-revision" ]]; then REF="$2"; else REF="open-grok.21"; fi

command -v shasum >/dev/null 2>&1 || { echo "shasum (SHA-256) is required" >&2; exit 1; }

DATE="$(date -u +%Y-%m-%d)"
{
  printf '{\n'
  printf '  "version": 1,\n'
  printf '  "generatedAt": "%s",\n' "$DATE"
  printf '  "referenceRevision": "%s",\n' "$REF"
  printf '  "files": [\n'
  first=1
  for f in "$FIX_DIR"/*; do
    [[ -f "$f" ]] || continue
    name="$(basename "$f")"
    [[ "$name" == "manifest.json" ]] && continue
    rel="ProtocolFixtures/$name"
    size="$(wc -c < "$f" | tr -d ' ')"
    sha="$(shasum -a 256 "$f" | awk '{print $1}')"
    if [[ $first -eq 0 ]]; then printf ',\n'; fi
    printf '    {\n'
    printf '      "path": "%s",\n' "$rel"
    printf '      "sizeBytes": %s,\n' "$size"
    printf '      "sha256": "%s"\n' "$sha"
    printf '    }'
    first=0
  done
  printf '\n  ]\n'
  printf '}\n'
} > "$MANIFEST"

echo "Regenerated $MANIFEST"
