#!/bin/zsh
# Live proof for /transcript's suspend-into-$PAGER (roadmap B3, wave 14).
#
# Drives the real open-grok binary in a PTY via expect(1), the way a user
# does: submit one prompt (a fake key makes the turn fail, which still puts
# a "You:" block in the transcript), run /transcript, and assert the child
# pager actually received a file containing that prompt. A green unit suite
# cannot prove this seam — the suspend host only exists end-to-end in the
# live composition with a real tty (AGENTS.md §3).
#
# Requires a prior product build:
#   zsh workflows/swift-safe-verify.zsh build --product open-grok
set -euo pipefail

readonly script_dir="${0:A:h}"
readonly repo_root="${script_dir:h}"
readonly binary="${OPEN_GROK_BINARY:-$repo_root/.build/workflow-safe/debug/open-grok}"

if [[ ! -x "$binary" ]]; then
  print -u2 "verify-transcript-pager: binary not found at $binary"
  print -u2 "build it first: zsh workflows/swift-safe-verify.zsh build --product open-grok"
  exit 64
fi
if ! command -v expect > /dev/null; then
  print -u2 "verify-transcript-pager: expect(1) is required"
  exit 64
fi

readonly work="$(mktemp -d "${TMPDIR:-/tmp}/open-grok-transcript-proof.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT INT TERM

readonly home="$work/home"
mkdir -p "$home"

# The recorder stands in for $PAGER: it copies the transcript it was handed
# and exits, so the TUI's restore path runs immediately.
readonly recorder="$work/recording-pager"
cat > "$recorder" <<EOF
#!/bin/zsh
cp "\$1" "$work/seen.md"
EOF
chmod +x "$recorder"

# The `|| expect_status=$?` rides the command so a failing driver reaches the
# diagnostics below instead of tripping set -e and losing the log to the trap.
expect_status=0
expect -f - "$binary" "$home" "$recorder" <<'EXPECT' > "$work/expect.log" 2>&1 || expect_status=$?
set binary [lindex $argv 0]
set home [lindex $argv 1]
set recorder [lindex $argv 2]
set timeout 60
set env(OPENGROK_HOME) $home
set env(XAI_API_KEY) proof-key-not-real
set env(PAGER) $recorder
set env(TERM) xterm-256color
spawn $binary
# Cell-by-cell painting splits every word across cursor moves, so no plain
# text needle can match the raw stream. The alt-screen enter is the one
# verbatim marker of a started TUI.
expect {
    timeout { puts "PROOF-FAIL: TUI never entered the alt screen"; exit 1 }
    -ex "\x1b\[?1049h"
}
sleep 1
send -- "transcript proof marker\r"
# The fake key fails the turn; any painted reaction means the block landed.
sleep 5
send -- "/transcript\r"
# The recorder exits instantly; give the suspend/restore cycle time.
sleep 5
send -- "/quit\r"
expect {
    timeout { puts "PROOF-FAIL: quit never exited"; exit 1 }
    eof
}
EXPECT

if (( expect_status != 0 )); then
  print -u2 "verify-transcript-pager: expect driver failed (status $expect_status)"
  cp "$work/expect.log" /tmp/transcript-proof-expect.log 2>/dev/null || true
  tail -20 "$work/expect.log" >&2
  exit 1
fi
if [[ ! -f "$work/seen.md" ]]; then
  print -u2 "PROOF-FAIL: \$PAGER was never invoked with a transcript file"
  tail -20 "$work/expect.log" >&2
  exit 1
fi
if ! grep -q "transcript proof marker" "$work/seen.md"; then
  print -u2 "PROOF-FAIL: the pager's file lacks the submitted prompt"
  cat "$work/seen.md" >&2
  exit 1
fi
print "PROOF-OK: /transcript suspended into \$PAGER and the child saw the transcript"
print "  transcript bytes: $(wc -c < "$work/seen.md" | tr -d ' ')"
