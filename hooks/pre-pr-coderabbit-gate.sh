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

# Which checkout(s) do the PR(s) come from? Not necessarily the session's cwd: the
# resolver follows `cd` before each `gh pr create`, checks `--repo` against that checkout's
# remotes and prefers the worktree holding `--head` (resolve-pr-target.mjs).
session_cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
[ -n "$session_cwd" ] && [ -d "$session_cwd" ] || session_cwd="$PWD"

block() { echo "BLOCKED by the AI code-review PR gate: $1" >&2; exit 2; }
targets=""; notes=""
if command -v node >/dev/null 2>&1 && [ -r "$here/resolve-pr-target.mjs" ]; then
  res="$(printf '%s' "$cmd" | node "$here/resolve-pr-target.mjs" "$session_cwd" 2>/dev/null || true)"
  status="$(printf '%s' "$res" | jq -r '.status // empty' 2>/dev/null || true)"
  reason="$(printf '%s' "$res" | jq -r '.reason // empty' 2>/dev/null || true)"
  case "$status" in
    ok)    targets="$(printf '%s' "$res" | jq -c '.targets[]')" ;;
    help)  exit 0 ;;
    block) block "$reason" ;;
    none|error)
      # Falling back to the session cwd is only safe when nothing could move the PR elsewhere.
      if [ "$(printf '%s' "$res" | jq -r '.risky')" = "true" ]; then
        block "couldn't work out which repo this PR comes from ($reason), and the command changes directory or names a repo/branch. Simplify it, e.g. write the PR body to a file and use --body-file."
      fi
      notes="review-gate: checked the session cwd ($reason)" ;;
    *) notes="review-gate: target resolver failed; checked the session cwd" ;;
  esac
else
  case "$cmd" in *--help*|*" -h"*) exit 0;; esac   # crude help check without the resolver
  notes="review-gate: node unavailable; checked the session cwd"
fi
[ -n "$targets" ] || targets="$(jq -cn --arg d "$session_cwd" '{dir: $d, rev: null, note: null}')"

msgs="$notes"; blocked=""
err="$(mktemp 2>/dev/null || echo "/tmp/cr-gate-check.$$")"
while IFS= read -r t; do
  [ -n "$t" ] || continue
  dir="$(printf '%s' "$t" | jq -r '.dir')"
  rev="$(printf '%s' "$t" | jq -r '.rev // empty')"
  note="$(printf '%s' "$t" | jq -r '.note // empty')"
  where="$dir${rev:+ @ ${rev:0:12}}"
  (cd "$dir" && bash "$gate" check ${rev:+--rev "$rev"}) 2>"$err"; rc=$?
  out="$(cat "$err" 2>/dev/null || true)"
  [ -n "$note" ] && msgs="${msgs:+$msgs
}review-gate: $note"
  case "$rc" in
    0)  # pass; never hide a skip or a cross-repo gate
      [ "$dir" != "$session_cwd" ] && msgs="${msgs:+$msgs
}review-gate: gated on $where (not the session cwd)"
      [ -n "$out" ] && msgs="${msgs:+$msgs
}$out" ;;
    1)  blocked="${blocked:+$blocked
}  $where: ${out:-no green light recorded}" ; last_dir="$dir" ;;
    *)  [ -n "$note" ] || msgs="${msgs:+$msgs
}review-gate: $dir is not a git repo with commits; not gated" ;;   # fail-open by design
  esac
done <<<"$targets"
rm -f "$err"

if [ -n "$blocked" ]; then
  {
    echo "BLOCKED by the AI code-review PR gate:"
    echo "$blocked"
    echo "Run BOTH reviews on each change, iterate until each is green, then record each pass:"
    echo "    cd $last_dir && coderabbit review --base main  && bash $gate record coderabbit"
    echo "    cd $last_dir && codex review --base main       && bash $gate record codex"
    echo "If a reviewer genuinely can't run (quota/outage), record an explicit, announced skip:"
    echo "    cd $last_dir && bash $gate record-skip <reviewer> --reason \"why\""
    echo "then re-run \`gh pr create\`. (Standing rule: CodeRabbit + Codex green before any PR.)"
  } >&2
  exit 2
fi
[ -n "$msgs" ] && jq -cn --arg m "$msgs" '{systemMessage: $m}'
exit 0
