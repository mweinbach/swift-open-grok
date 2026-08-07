#!/bin/zsh
# Repro for: switching the TUI to a codex-provider model and sending a prompt
# kills the whole app.
#
# Drives the real open-grok binary in a PTY via expect(1), exactly the way the
# user did: launch, `/model codex:gpt-5.6-sol`, send a prompt. The codex
# endpoint is pointed at an unroutable local port so the turn fails
# deterministically without network traffic; OPENAI_API_KEY satisfies the
# switch-time credential resolution (explicit keys outrank the OAuth store).
#
# Expected on a healthy tree (upstream parity, prompt.rs:1399-1402): the turn
# fails, a "Turn failed:" marker renders, the composer stays live, /quit exits.
# Observed bug: the whole TUI exits the moment the turn fails.
#
# Requires a prior product build:
#   zsh workflows/swift-safe-verify.zsh build --product open-grok
set -euo pipefail

readonly script_dir="${0:A:h}"
readonly repo_root="${script_dir:h}"
readonly binary="${OPEN_GROK_BINARY:-$repo_root/.build/workflow-safe/debug/open-grok}"

if [[ ! -x "$binary" ]]; then
  print -u2 "repro: binary not found at $binary"
  exit 64
fi
if ! command -v expect > /dev/null; then
  print -u2 "repro: expect(1) is required"
  exit 64
fi

readonly work="$(mktemp -d "${TMPDIR:-/tmp}/open-grok-codex-repro.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT INT TERM

readonly home="$work/home"
mkdir -p "$home"

expect_status=0
expect -f - "$binary" "$home" <<'EXPECT' > "$work/expect.log" 2>&1 || expect_status=$?
set binary [lindex $argv 0]
set home [lindex $argv 1]
set timeout 30
set env(OPENGROK_HOME) $home
set env(XAI_API_KEY) proof-key-not-real
set env(OPENAI_API_KEY) proof-codex-key-not-real
# Unroutable endpoint: the turn's first request fails with connection refused.
set env(GROK_CODEX_INFERENCE_BASE_URL) "http://127.0.0.1:9"
set env(TERM) xterm-256color
spawn $binary
expect {
    timeout { puts "REPRO-FAIL: TUI never entered the alt screen"; exit 2 }
    -ex "\x1b\[?1049h"
}
sleep 1
send -- "/model codex:gpt-5.6-sol\r"
# Cell-by-cell painting splits every word across cursor moves, so no plain
# text needle can match the raw stream; pace with sleeps instead (the switch
# is local — the explicit OPENAI_API_KEY resolves without network).
sleep 3
send -- "codex crash repro prompt\r"
# The turn fails immediately (connection refused). The one question this
# proof answers: does the process survive the failed turn?
expect {
    eof {
        puts "REPRO-CONFIRMED: the TUI process died after the failed codex turn"
        exit 10
    }
    timeout {
        puts "REPRO-SURVIVED: TUI still alive 30s after the failed turn"
    }
}
# Alive: prove the composer still works, then leave.
send -- "/quit\r"
expect {
    timeout { puts "REPRO-FAIL: /quit never exited"; exit 2 }
    eof
}
puts "REPRO-HEALTHY: turn failed, TUI survived, /quit exited cleanly"
exit 0
EXPECT

print -- "expect exit status: $expect_status"
print -- "--- expect log tail ---"
tail -40 "$work/expect.log"
cp "$work/expect.log" /tmp/codex-repro-expect.log 2>/dev/null || true
exit $expect_status
