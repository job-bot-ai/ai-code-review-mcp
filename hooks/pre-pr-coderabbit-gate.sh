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
printf '%s' "$input" | grep -Eq 'gh[^"]*pr[^"]*(create|new)' || exit 0   # `gh pr new` is an alias

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

# Any `gh pr create` words anywhere go to the resolver, which follows runners
# (`timeout 60 gh pr create`), `GH_REPO=... gh pr create`, `bash -c`, `eval`, backticks
# and pipes into shells, and lets mentions that are only data (commit messages, grep
# patterns) through. Only the no-node fallback below keeps the command-position match.
# (`\n`/`\t` escapes count as separators: `printf 'cd x\ngh pr create' | bash`.)
printf '%s' "$cmd" | grep -Eq '(^|[^[:alnum:]_-]|\\[nt])gh([[:space:]]|\\t)+pr([[:space:]]|\\t)+(create|new)([^[:alnum:]_-]|$)' || exit 0

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
gate="$here/../review-gate"

# Fail-open if the gate helper is missing/unreadable — never wedge the shell.
[ -r "$gate" ] || exit 0

# Which checkout(s) do the PR(s) come from? Not necessarily the session's cwd: the
# resolver follows `cd` before each `gh pr create`, checks `--repo` against that checkout's
# remotes and prefers the worktree holding `--head` (resolve-pr-target.mjs).
session_cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
[ -n "$session_cwd" ] && [ -d "$session_cwd" ] || session_cwd="$PWD"
# The session's checkout (its toplevel), so a session in a subdirectory or via a symlink
# isn't told it was "gated on another repo".
session_top="$(git -C "$session_cwd" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$session_cwd")"

block() { echo "BLOCKED by the AI code-review PR gate: $1" >&2; exit 2; }
# Without a resolver result, falling back to the session cwd is only safe when nothing in
# the command could move the PR elsewhere (same rule as the resolver's RISKY check).
risky() {
  printf '%s' "$cmd" | grep -Eq "(^|[[:space:];&|(){}'\"\`])(cd|pushd|popd)([[:space:]]|\$)|(^|[[:space:]])(--repo|--head)([[:space:]=]|\$)|(^|[[:space:]])-[A-Za-z]*[RH]|GH_REPO|CDPATH"
}
fallback_or_block() {
  risky && block "couldn't run the target resolver ($1), and the command changes directory or names a repo/branch, so the session cwd may be the wrong repo."
  notes="review-gate: $1; checked the session cwd"
}
targets=""; notes=""
if command -v node >/dev/null 2>&1 && [ -r "$here/resolve-pr-target.mjs" ]; then
  res="$(printf '%s' "$cmd" | node "$here/resolve-pr-target.mjs" "$session_cwd" 2>/dev/null || true)"
  status="$(printf '%s' "$res" | jq -r '.status // empty' 2>/dev/null || true)"
  reason="$(printf '%s' "$res" | jq -r '.reason // empty' 2>/dev/null || true)"
  case "$status" in
    ok)    targets="$(printf '%s' "$res" | jq -c '.targets[]')" ;;
    help|none) exit 0 ;;   # --help, or `gh pr create` only mentioned as data (heredoc, quotes)
    block) block "$reason" ;;
    error)
      # Falling back to the session cwd is only safe when nothing could move the PR elsewhere.
      if [ "$(printf '%s' "$res" | jq -r '.risky')" = "true" ]; then
        block "couldn't work out which repo this PR comes from ($reason), and the command changes directory or names a repo/branch. Simplify it, e.g. write the PR body to a file and use --body-file."
      fi
      notes="review-gate: checked the session cwd ($reason)" ;;
    *) fallback_or_block "target resolver failed" ;;
  esac
else
  # Without the resolver: gate only `gh pr create` in command position (start of the
  # command or after ; | & ( { ), as before; env-prefixed and `bash -c` forms aren't seen.
  printf '%s' "$cmd" | grep -Eq '(^|[;|&(){])[[:space:]]*gh[[:space:]]+pr[[:space:]]+(create|new)([[:space:];|&)}]|$)' || exit 0
  case "$cmd" in *--help*|*" -h"*) exit 0;; esac   # crude help check without the resolver
  fallback_or_block "node unavailable"
fi
[ -n "$targets" ] || targets="$(jq -cn --arg d "$session_cwd" '{dir: $d, rev: null, note: null}')"

msgs="$notes"; blocked=""
while IFS= read -r t; do
  [ -n "$t" ] || continue
  dir="$(printf '%s' "$t" | jq -r '.dir')"
  rev="$(printf '%s' "$t" | jq -r '.rev // empty')"
  note="$(printf '%s' "$t" | jq -r '.note // empty')"
  where="$dir${rev:+ @ ${rev:0:12}}"
  out="$( (cd "$dir" && bash "$gate" check ${rev:+--rev "$rev"}) 2>&1 >/dev/null )"; rc=$?
  [ -n "$note" ] && msgs="${msgs:+$msgs
}review-gate: $note"
  case "$rc" in
    0)  # pass; never hide a skip or a cross-repo gate
      [ "$dir" != "$session_top" ] && msgs="${msgs:+$msgs
}review-gate: gated on $where (not the session's checkout)"
      [ -n "$out" ] && msgs="${msgs:+$msgs
}$out" ;;
    1)  q="$(printf '%q' "$dir")"; gq="$(printf '%q' "$gate")"
        revnote=""
        [ -n "$rev" ] && revnote="
    (commit ${rev:0:12} is not checked out there: check out that branch in a worktree and review it)"
        blocked="${blocked:+$blocked
}  $where: ${out:-no green light recorded}
    review there:  cd $q && coderabbit review --base main && bash $gq record coderabbit
                   cd $q && codex review --base main && bash $gq record codex$revnote" ;;
    *)  [ -n "$note" ] || msgs="${msgs:+$msgs
}review-gate: $dir is not a git repo with commits; not gated" ;;   # fail-open by design
  esac
done <<<"$targets"

if [ -n "$blocked" ]; then
  {
    echo "BLOCKED by the AI code-review PR gate (run BOTH reviews, iterate until green, record each pass):"
    echo "$blocked"
    echo "If a reviewer genuinely can't run (quota/outage), record an explicit, announced skip in that checkout:"
    echo "    bash $(printf '%q' "$gate") record-skip <reviewer> --reason \"why\""
    echo "then re-run \`gh pr create\`. (Standing rule: CodeRabbit + Codex green before any PR.)"
  } >&2
  exit 2
fi
[ -n "$msgs" ] && jq -cn --arg m "$msgs" '{systemMessage: $m}'
exit 0
