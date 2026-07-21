#!/usr/bin/env bash
#
# scripts/verify-bootstrap.sh
#
# Run the W0-S1 bootstrap acceptance checks:
#   1. swift package describe succeeds (manifest resolves).
#   2. swift build succeeds for the whole predeclared package.
#   3. The ogrok-validate-protocols plugin reports fixtures fresh.
#   4. The open-grok executable prints the version.
#   5. The bootstrap test suites pass (BuildSupport, CLI, platform scaffolds).
#
# Exits nonzero on the first failing step.
set -euo pipefail

cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)"

step() { printf '\n=== %s ===\n' "$1"; }

step "1/5 swift package describe"
swift package describe >/dev/null
echo "describe: ok"

step "2/5 swift build"
swift build 2>&1 | grep -E "Build complete" >/dev/null
echo "build: ok"

step "3/5 ogrok-validate-protocols"
swift package ogrok-validate-protocols 2>&1 | grep -E "Protocol fixtures are fresh" >/dev/null
echo "fixtures: fresh"

step "4/5 open-grok --version"
out="$(.build/debug/open-grok --version)"
case "$out" in
  *"Open Grok"*) echo "version: $out" ;;
  *) echo "version: FAILED ($out)" >&2; exit 1 ;;
esac

step "5/5 bootstrap test suites"
# Filter precisely on the `*Tests`-suffixed identifiers of the targets W0-S1
# owns or scaffolded (OpenGrokBuildSupport, the bootstrap OpenGrokCLI, and the
# platform-protocol scaffolds). Suffixing with `Tests` prevents the bare
# `OpenGrokCLI` token from substring-matching the W0-S4-owned
# `OpenGrokCLIChatProxyTypesTests`, which carries its own (non-bootstrap)
# failures. `swift test` exits nonzero iff a matched test fails, so its exit
# code is the authoritative pass/fail signal.
if swift test --filter "OpenGrokBuildSupportTests|OpenGrokCLITests|OpenGrokTerminalCoreTests|OpenGrokTTYTests|OpenGrokPTYTests|OpenGrokFSNotifyTests|OpenGrokSecretsTests|OpenGrokSandboxTests|OpenGrokSystemPowerTests|OpenGrokCrashHandlerTests" >"${OG_BOOTSTRAP_TEST_LOG:-/tmp/og-bootstrap-tests.log}" 2>&1; then
  echo "tests: ok"
else
  echo "tests: FAILED (see ${OG_BOOTSTRAP_TEST_LOG:-/tmp/og-bootstrap-tests.log})" >&2
  exit 1
fi

printf '\nAll bootstrap checks passed.\n'
