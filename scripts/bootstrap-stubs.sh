#!/usr/bin/env bash
#
# scripts/bootstrap-stubs.sh
#
# Bootstrap helper (owned by W0-S1). Creates minimal compilable placeholder
# source files for every target predeclared in Package.swift so the whole
# package builds green before implementation slices land. Owning slices replace
# these placeholders in place; Package.swift is never edited by feature slices.
#
# Usage: scripts/bootstrap-stubs.sh [--check]
#   --check  verify every target has at least one .swift file; exit nonzero if
#            any target directory is missing or empty.
#
set -euo pipefail

cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)"

# Every library target declared in Package.swift (95 targets).
LIBS=(
  OpenGrokBuildSupport
  OpenGrokTestSupport OpenGrokTestUtilities
  OpenGrokPaths OpenGrokEnvironment OpenGrokVersion
  OpenGrokShared OpenGrokCLIChatProxyTypes
  OpenGrokDiagnostics OpenGrokScheduler OpenGrokMinimalScrollback
  OpenGrokToolTypes OpenGrokToolProtocol OpenGrokToolRuntime OpenGrokToolsAPI
  OpenGrokACP OpenGrokAgentLifecycle OpenGrokInterjection OpenGrokPromptQueue
  OpenGrokSamplingTypes OpenGrokChatState OpenGrokTokenEstimation
  OpenGrokWorkspaceTypes OpenGrokHooksPluginTypes OpenGrokCodeModeProtocol
  OpenGrokConfigTypes OpenGrokConfig
  OpenGrokHTTP OpenGrokCircuitBreaker OpenGrokTracing OpenGrokTelemetry OpenGrokExtraCA
  OpenGrokSQLiteJournal OpenGrokSecrets OpenGrokFileUtils
  OpenGrokFSNotify OpenGrokGitStatus OpenGrokCodebaseGraph OpenGrokHunkTracker
  OpenGrokPTY OpenGrokPTYCLI OpenGrokTTY OpenGrokSystemPower OpenGrokCrashHandler
  OpenGrokTerminalCore OpenGrokTextArea
  OpenGrokAuth OpenGrokModels OpenGrokSampler
  OpenGrokSandbox OpenGrokFastWorktree OpenGrokWorkspace
  OpenGrokComputerHubCore OpenGrokComputerHubSDK OpenGrokWorkspaceClient
  OpenGrokToolRegistry OpenGrokFileTools OpenGrokExecutionTools OpenGrokWebMediaTools
  OpenGrokAgentControlTools OpenGrokMCP OpenGrokComputerHubMCPAdapter OpenGrokWorkflow
  OpenGrokHooks OpenGrokPluginMarketplace
  OpenGrokAgentDefinitions OpenGrokAnnouncements OpenGrokUpdate OpenGrokVoice
  OpenGrokCodeMode OpenGrokJavaScriptRuntime OpenGrokCompaction
  OpenGrokMemory OpenGrokGoalState OpenGrokShellBase OpenGrokShellSessionSupport
  OpenGrokSubagentResolution
  OpenGrokSessionRuntime OpenGrokSessionPersistence OpenGrokProviderSession
  OpenGrokAgentCoordinator OpenGrokACPRuntime
  OpenGrokMarkdownCore OpenGrokMarkdown OpenGrokMermaidLayout OpenGrokMermaid
  OpenGrokPagerRender OpenGrokPagerModel OpenGrokShell
  OpenGrokPagerRuntime OpenGrokPagerConversationUI OpenGrokPagerCommandUI
  OpenGrokPagerOperationsUI OpenGrokPagerMinimal
  OpenGrokPager OpenGrokCLI
  OpenGrokDistributionSupport OpenGrokPagerPTYHarness OpenGrokReleaseValidation
)

# Standalone test targets (not derived as <Lib>Tests) plus the executable.
STANDALONE_TESTS=(
  OpenGrokCompatibilityTests OpenGrokPagerPTYTests OpenGrokFuzzingTests
  OpenGrokPerformanceTests OpenGrokSecurityTests OpenGrokExecutableTests
)

EXECUTABLE_TARGETS=(OpenGrokExecutable)

lib_stub() {
  local name="$1"
  cat <<SWIFT
// $name.swift
//
// Open Grok — Swift port. Bootstrap placeholder.
//
// This target is predeclared in Package.swift and is owned by exactly one
// implementation slice per PORT_PLAN.md / CRATE_MAP.md. The owning slice
// replaces this file with the real port of the corresponding Rust crate(s).
// No slice other than the owner may edit this directory.
//
// Rust crate mapping: see CRATE_MAP.md.

import Foundation
SWIFT
}

test_stub() {
  local name="$1"
  cat <<SWIFT
// ${name}.swift
//
// Open Grok — Swift port. Bootstrap placeholder test target.
//
// Owned by the same slice that owns the corresponding library target. The
// owning slice replaces this file with real Swift Testing suites. This
// placeholder intentionally declares no tests so `swift test` stays green
// until the owner lands target-scoped tests.
SWIFT
}

if [[ "${1:-}" == "--check" ]]; then
  rc=0
  for lib in "${LIBS[@]}"; do
    dir="Sources/$lib"
    if [[ ! -d "$dir" ]] || ! ls "$dir"/*.swift >/dev/null 2>&1; then
      echo "missing lib sources: $dir" >&2; rc=1
    fi
  done
  for exe in "${EXECUTABLE_TARGETS[@]}"; do
    dir="Sources/$exe"
    if [[ ! -d "$dir" ]] || ! ls "$dir"/*.swift >/dev/null 2>&1; then
      echo "missing executable sources: $dir" >&2; rc=1
    fi
  done
  exit $rc
fi

for lib in "${LIBS[@]}"; do
  mkdir -p "Sources/$lib"
  file="Sources/$lib/$lib.swift"
  if [[ ! -f "$file" ]]; then
    lib_stub "$lib" > "$file"
  fi
done

for exe in "${EXECUTABLE_TARGETS[@]}"; do
  mkdir -p "Sources/$exe"
  file="Sources/$exe/main.swift"
  if [[ ! -f "$file" ]]; then
    cat > "$file" <<'SWIFT'
// OpenGrokExecutable — bootstrap placeholder main.
// Replaced by W11-S1 with the real open-grok executable composition.
import Foundation
SWIFT
  fi
done

# Per-library test targets (<Lib>Tests).
for lib in "${LIBS[@]}"; do
  tname="${lib}Tests"
  mkdir -p "Tests/$tname"
  file="Tests/$tname/$tname.swift"
  if [[ ! -f "$file" ]]; then
    test_stub "$tname" > "$file"
  fi
done

# Standalone test targets.
for tname in "${STANDALONE_TESTS[@]}"; do
  mkdir -p "Tests/$tname"
  file="Tests/$tname/$tname.swift"
  if [[ ! -f "$file" ]]; then
    test_stub "$tname" > "$file"
  fi
done

# Command plugin target lives under Plugins/.
mkdir -p Plugins/OpenGrokProtoBuildPlugin

echo "Bootstrap stubs ensured for ${#LIBS[@]} library targets, ${#STANDALONE_TESTS[@]} standalone test targets, and ${#EXECUTABLE_TARGETS[@]} executable target."
