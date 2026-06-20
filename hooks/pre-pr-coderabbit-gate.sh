#!/usr/bin/env bash
# PreToolUse(Bash) hook: block `gh pr create` unless a CodeRabbit pass is recorded
# for the current HEAD. Wire into ~/.claude/settings.json (matcher: "Bash").
# Part of https://github.com/job-bot-ai/CodeRabbit-Claude-MCP
#
# Fail-open by design: any unexpected error exits non-2 so it never wedges the shell;
# only a genuine "no green light" condition returns exit 2 (which blocks the tool call).

input="$(cat)"

# Fast path: if the payload can't possibly contain `gh ... pr ... create`, allow now.
printf '%s' "$input" | grep -Eq 'gh[^"]*pr[^"]*create' || exit 0

# Pull the actual command string out of tool_input.command. jq is required to isolate the
# command from surrounding JSON reliably; without it, warn (not silent) and fail open
# rather than match against the raw payload and risk false blocks.
if command -v jq >/dev/null 2>&1; then
  cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
else
  echo "coderabbit PR gate: jq not found; gate disabled for this call (install jq to enable)." >&2
  exit 0
fi
[ -n "$cmd" ] || exit 0

# Ignore help invocations.
case "$cmd" in *--help*|*" -h"*) exit 0;; esac
# Match `gh pr create` only in COMMAND POSITION: at the start of the command or right after
# a shell separator ( ; | & ( { ), spaces allowed between. This avoids firing when the
# string merely appears as an argument (echo/printf/grep), inside a heredoc, or in a commit
# message. grep is line-based, so `gh pr create` starting its own line also matches via ^.
# Trade-off: env-prefixed or `bash -c "gh pr create"` forms are not gated — acceptable for a
# speed-bump, not a security boundary.
printf '%s' "$cmd" | grep -Eq '(^|[;|&(){])[[:space:]]*gh[[:space:]]+pr[[:space:]]+create([[:space:];|&)}]|$)' || exit 0

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
gate="$here/../coderabbit-gate"

# Fail-open if the gate helper is missing/unreadable — never wedge the shell.
[ -r "$gate" ] || exit 0

err="$(mktemp 2>/dev/null || echo "/tmp/cr-gate-check.$$")"
bash "$gate" check 2>"$err"; rc=$?

if [ "$rc" -eq 0 ]; then
  rm -f "$err"; exit 0                 # pass recorded for HEAD → allow
fi
if [ "$rc" -eq 1 ]; then               # genuine no-pass / stale → block
  why="$(cat "$err" 2>/dev/null || true)"; rm -f "$err"
  {
    echo "BLOCKED by CodeRabbit PR gate: ${why:-no green light recorded}."
    echo "Run a CodeRabbit review on this change, iterate until it is green, then record the pass:"
    echo "    bash $gate record"
    echo "and re-run \`gh pr create\`. (Standing rule: CodeRabbit-green before any PR.)"
  } >&2
  exit 2
fi
# Any other exit code (e.g. 3 = not a git repo / empty) → fail-open per the design above.
rm -f "$err"; exit 0
