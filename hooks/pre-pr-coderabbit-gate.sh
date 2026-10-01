#!/usr/bin/env bash
# PreToolUse(Bash) hook: block `gh pr create` unless all required reviewer passes
# (CodeRabbit + Codex) are recorded via `review-gate` for the commit the PR comes from,
# in the repo the PR comes from (followed from `cd`/`--repo`/`--head` by
# resolve-pr-target.mjs; the session cwd is only the fallback).
# Wire into ~/.claude/settings.json (matcher: "Bash"). Filename kept for back-compat
# with existing settings.json entries.
# Part of https://github.com/job-bot-ai/ai-code-review-mcp
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
gate="$here/../review-gate"

# Fail-open if the gate helper is missing/unreadable — never wedge the shell.
[ -r "$gate" ] || exit 0

# Which checkout does this PR come from? Not necessarily the session's cwd: follow a
# `cd <dir>` before `gh pr create`, check `--repo` against that checkout's remotes and
# prefer the worktree holding `--head` (resolve-pr-target.mjs). If the resolver can't run
# or can't parse the command, fall back to the session cwd (the pre-resolver behaviour).
session_cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
[ -n "$session_cwd" ] && [ -d "$session_cwd" ] || session_cwd="$PWD"
target="$session_cwd"; rev=""; note=""
if command -v node >/dev/null 2>&1 && [ -r "$here/resolve-pr-target.mjs" ]; then
  res="$(printf '%s' "$cmd" | node "$here/resolve-pr-target.mjs" "$session_cwd" 2>/dev/null || true)"
  status="$(printf '%s' "$res" | jq -r '.status // empty' 2>/dev/null || true)"
  case "$status" in
    ok)
      target="$(printf '%s' "$res" | jq -r '.dir')"
      rev="$(printf '%s' "$res" | jq -r '.rev // empty')"
      note="$(printf '%s' "$res" | jq -r '.note // empty')"
      ;;
    block)
      echo "BLOCKED by the AI code-review PR gate: $(printf '%s' "$res" | jq -r '.reason')" >&2
      exit 2
      ;;
    *) note="couldn't parse the command (${status:-resolver failed}); checked the session cwd" ;;
  esac
fi

err="$(mktemp 2>/dev/null || echo "/tmp/cr-gate-check.$$")"
(cd "$target" && bash "$gate" check ${rev:+--rev "$rev"}) 2>"$err"; rc=$?
where="$target${rev:+ @ ${rev:0:12}}"

if [ "$rc" -eq 0 ]; then               # pass recorded → allow; never hide a skip
  msgs="$(cat "$err" 2>/dev/null || true)"; rm -f "$err"
  [ "$target" != "$session_cwd" ] && msgs="review-gate: gated on $where (not the session cwd)${msgs:+
$msgs}"
  [ -n "$note" ] && msgs="${msgs:+$msgs
}review-gate: $note"
  if [ -n "$msgs" ]; then
    jq -cn --arg m "$msgs" '{systemMessage: $m}'
  fi
  exit 0
fi
if [ "$rc" -eq 1 ]; then               # genuine no-pass / stale → block
  why="$(cat "$err" 2>/dev/null || true)"; rm -f "$err"
  {
    echo "BLOCKED by the AI code-review PR gate (checked $where): ${why:-no green light recorded}."
    echo "Run BOTH reviews on this change, iterate until each is green, then record each pass:"
    echo "    cd $target && coderabbit review --base main  && bash $gate record coderabbit"
    echo "    cd $target && codex review --base main       && bash $gate record codex"
    echo "If a reviewer genuinely can't run (quota/outage), record an explicit, announced skip:"
    echo "    cd $target && bash $gate record-skip <reviewer> --reason \"why\""
    echo "then re-run \`gh pr create\`. (Standing rule: CodeRabbit + Codex green before any PR.)"
  } >&2
  exit 2
fi
# Any other exit code (e.g. 3 = not a git repo / empty) → fail-open per the design above.
rm -f "$err"; exit 0
