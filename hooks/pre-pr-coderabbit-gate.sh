#!/usr/bin/env bash
# PreToolUse(Bash) hook: `gh pr create --draft` is always allowed (the PR reviewers —
# Kodus, CodeRabbit/Greptile — only review a PR that exists). `gh pr ready` and a non-draft
# `gh pr create` are blocked until `review-gate check` passes (two different reviewers'
# passes, primaries passed or skipped) for the PR's commit, in the repo the PR comes from
# (followed from `cd`/`--repo`/`--head` by resolve-pr-target.mjs; the session cwd is only
# the fallback). Marking a PR ready through the GraphQL API is blocked outright.
# Wire into ~/.claude/settings.json (matcher: "Bash"). Filename kept for back-compat
# with existing settings.json entries.
# Part of https://github.com/job-bot-ai/ai-code-review-mcp
#
# Fail-open by design: any unexpected error exits non-2 so it never wedges the shell;
# only a genuine "no green light" condition returns exit 2 (which blocks the tool call).

input="$(cat)"

# Fast path: if the payload can't possibly contain `gh ... pr ... create`, allow now.
printf '%s' "$input" | grep -Eq 'gh[^"]*pr[^"]*(create|new|ready)|markPullRequestReadyForReview' || exit 0   # `gh pr new` is an alias

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

# `gh pr ready` is the only way the gate lets a PR out of draft.
if printf '%s' "$cmd" | grep -q 'markPullRequestReadyForReview' &&
   printf '%s' "$cmd" | grep -Eq '(^|[^[:alnum:]_-])(gh[[:space:]]+api|curl|wget|http)([[:space:]]|$)'; then
  echo "BLOCKED by the AI code-review PR gate: mark a PR ready with \`gh pr ready\` (gated on the recorded reviews), not through the GraphQL API." >&2
  exit 2
fi

# Any `gh pr create` words anywhere go to the resolver, which follows runners
# (`timeout 60 gh pr create`), `GH_REPO=... gh pr create`, `bash -c`, `eval`, backticks
# and pipes into shells, and lets mentions that are only data (commit messages, grep
# patterns) through. Only the no-node fallback below keeps the command-position match.
# (`\n`/`\t` escapes count as separators: `printf 'cd x\ngh pr create' | bash`.)
printf '%s' "$cmd" | grep -Eq '(^|[^[:alnum:]_-]|\\[nt])gh([[:space:]]|\\t)+pr([[:space:]]|\\t)+(create|new|ready)([^[:alnum:]_-]|$)' || exit 0

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
  printf '%s' "$cmd" | grep -Eq '(^|[;|&(){])[[:space:]]*gh[[:space:]]+pr[[:space:]]+(create|new|ready)([[:space:];|&)}]|$)' || exit 0
  case "$cmd" in *--help*|*" -h"*|*--draft*|*--undo*) exit 0;; esac   # crude help/draft check without the resolver
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
    1)  q="$(printf '%q' "$dir")"
        revnote=""
        [ -n "$rev" ] && [ "$rev" != "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" ] && revnote="
    (reviews must be recorded for commit ${rev:0:12}: \`review-gate record <reviewer> --rev ${rev:0:12}\` in $q)"
        blocked="${blocked:+$blocked
}  $where: ${out:-no green light recorded}
    status there:  cd $q && bash $(printf '%q' "$gate") status$revnote" ;;
    *)  [ -n "$note" ] || msgs="${msgs:+$msgs
}review-gate: $dir is not a git repo with commits; not gated" ;;   # fail-open by design
  esac
done <<<"$targets"

if [ -n "$blocked" ]; then
  {
    g="bash $(printf '%q' "$gate")"
    echo "BLOCKED by the AI code-review PR gate: two independent reviews must be green on the PR's final commit first."
    echo "$blocked"
    echo "1. Open the PR as a draft (allowed without reviews):  gh pr create --draft ..."
    echo "2. The primary reviewers review it: Kodus + CodeRabbit (until 2026-11-19), Kodus + Greptile (from 2026-11-19)."
    echo "   Fix high findings, fix medium ones or say why not, push, request a re-review, then record each clean pass:"
    echo "       $g record kodus|coderabbit|greptile"
    echo "   Still findings after two review rounds? Don't push a third fix-by-fix round: first do a deep analysis of the"
    echo "   whole change (root cause shared by the findings, the same bug class elsewhere in the diff, tests), fix that,"
    echo "   and say in the PR body what kept coming up and why before asking for the third review."
    echo "3. A primary that can't review (not installed, errored, quota, no review within 30 min): record the skip and use Codex,"
    echo "   and if Codex can't run either, do a thorough review yourself:"
    echo "       $g record-skip <reviewer> --reason \"why\""
    echo "       codex review --base main && $g record codex      |      $g record self"
    echo "4. List every reviewer, skip and reason in the PR body, then \`gh pr ready\`."
    echo "Never falsify or work around the gate. CodeRabbit: free hourly allowance only, never --use-credits."
  } >&2
  exit 2
fi
[ -n "$msgs" ] && jq -cn --arg m "$msgs" '{systemMessage: $m}'
exit 0
