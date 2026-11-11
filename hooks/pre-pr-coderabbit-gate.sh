#!/usr/bin/env bash
# PreToolUse(Bash) hook: `gh pr create --draft` is always allowed (the PR reviewers —
# Kodus, CodeRabbit/Greptile — only review a PR that exists). `gh pr ready` and a non-draft
# `gh pr create` are blocked until `review-gate check` passes (two different reviewers'
# passes, primaries passed or skipped) for the PR's commit, in the repo the PR comes from
# (followed from `cd`/`--repo`/`--head` by resolve-pr-target.mjs; the session cwd is only
# the fallback). Marking a PR ready through the GraphQL API is blocked outright.
# Pre-push gate: a `git push` that publishes a branch commit (any form the resolver can follow: `cd`, `-C`,
# chained, env prefixes, runners, `bash -c`, credential-helper `-c` args) is blocked until that commit has a
# `review-gate prepush` marker (a completed review with no P0-P2 findings, or findings explicitly accepted).
# Deletes, tags-only pushes, dry runs and --help are not gated. Tim's escape hatch: REVIEW_GATE_PREPUSH=off in the
# environment Claude Code runs in (not a command prefix) skips it, and every skipped push is logged.
# Wire into ~/.claude/settings.json (matcher: "Bash"). Filename kept for back-compat
# with existing settings.json entries.
# Part of https://github.com/job-bot-ai/ai-code-review-mcp
#
# Fail-open by design: any unexpected error exits non-2 so it never wedges the shell;
# only a genuine "no green light" condition returns exit 2 (which blocks the tool call).

input="$(cat)"

# Fast path: if the payload can't possibly contain `gh ... pr ... create` or a push, allow now.
printf '%s' "$input" | grep -Eq 'gh[^"]*pr[^"]*(create|new|ready)|markPullRequestReadyForReview|git' || exit 0   # `gh pr new` is an alias

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

# `gh pr ready` is the only way the gate lets a PR out of draft: the resolver also blocks the
# GraphQL ready mutation sent by an API client (gh api, curl, ...) wherever it runs, and lets
# mentions that are only data (echo, a heredoc written to a file) through.

# Any `gh pr create` words anywhere go to the resolver, which follows runners
# (`timeout 60 gh pr create`), `GH_REPO=... gh pr create`, `bash -c`, `eval`, backticks
# and pipes into shells, and lets mentions that are only data (commit messages, grep
# patterns) through. Only the no-node fallback below keeps the command-position match.
# (`\n`/`\t` escapes count as separators: `printf 'cd x\ngh pr create' | bash`.)
want_pr=0; want_push=0
printf '%s' "$cmd" | grep -Eq '(^|[^[:alnum:]_-]|\\[nt])gh([[:space:]]|\\t)+pr([[:space:]]|\\t)+(create|new|ready)([^[:alnum:]_-]|$)|markPullRequestReadyForReview' && want_pr=1
# Any `git` command goes to the resolver: it finds pushes however they are spelled (`git -c credential.helper='!f(){
# ...; }; f' push`, `git -C dir push`) and looks up aliases (`git p` with alias.p=push) in the checkout where git
# runs. Commands without git skip it.
printf '%s' "$cmd" | grep -Eq '(^|[^[:alnum:]_-])git([^[:alnum:]_-]|$)' && want_push=1
[ "$want_pr" = 1 ] || [ "$want_push" = 1 ] || exit 0

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
have_resolver=0
command -v node >/dev/null 2>&1 && [ -r "$here/resolve-pr-target.mjs" ] && have_resolver=1
msgs=""
add_msg() { msgs="${msgs:+$msgs
}$1"; }

# ── PR gate: gh pr create (non-draft) / gh pr ready ──
pr_gate() {
targets=""; notes=""
if command -v node >/dev/null 2>&1 && [ -r "$here/resolve-pr-target.mjs" ]; then
  res="$(printf '%s' "$cmd" | node "$here/resolve-pr-target.mjs" "$session_cwd" 2>/dev/null || true)"
  status="$(printf '%s' "$res" | jq -r '.status // empty' 2>/dev/null || true)"
  reason="$(printf '%s' "$res" | jq -r '.reason // empty' 2>/dev/null || true)"
  case "$status" in
    ok)    targets="$(printf '%s' "$res" | jq -c '.targets[]')" ;;
    help|none) return 0 ;;   # --help, or `gh pr create` only mentioned as data (heredoc, quotes)
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
  if printf '%s' "$cmd" | grep -q 'markPullRequestReadyForReview'; then   # can't tell data from code here
    block "the command mentions the GraphQL ready mutation and the target resolver (node) isn't available. Use \`gh pr ready\`."
  fi
  printf '%s' "$cmd" | grep -Eq '(^|[;|&(){])[[:space:]]*gh[[:space:]]+pr[[:space:]]+(create|new|ready)([[:space:];|&)}]|$)' || return 0
  case "$cmd" in *--help*|*" -h"*|*--draft*|*--undo*) return 0;; esac   # crude help/draft check without the resolver
  fallback_or_block "node unavailable"
fi
[ -n "$targets" ] || targets="$(jq -cn --arg d "$session_cwd" '{dir: $d, rev: null, note: null}')"

[ -n "$notes" ] && add_msg "$notes"
blocked=""
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
    echo "2. The primary reviewers review it: Kodus + CodeRabbit through 2026-11-18, Kodus + Greptile from 2026-11-19 (UTC)."
    echo "   Kodus starts by itself; CodeRabbit skips drafts, so comment \`@coderabbitai review\` (Greptile: \`@greptileai review\`)."
    echo "   Fix high findings, fix medium ones or say why not, push, request a re-review, then record each clean pass:"
    echo "       $g record kodus"
    echo "       $g record coderabbit      (through 2026-11-18; from 2026-11-19: $g record greptile)"
    echo "   Still findings after two review rounds? Don't push a third fix-by-fix round: first do a deep analysis of the"
    echo "   whole change (root cause shared by the findings, the same bug class elsewhere in the diff, tests), fix that,"
    echo "   and say in the PR body what kept coming up and why before asking for the third review."
    echo "3. A primary that was requested but can't review (not installed, errored, out of quota or free allowance, no review"
    echo "   within 30 min):  $g record-skip <reviewer> --reason \"why\"   Then, to reach two passes from different reviewers:"
    echo "   - one primary out: the other primary + Codex (codex review --base main && $g record codex);"
    echo "     if Codex is out too ($g record-skip codex --reason ...): the other primary + your own review ($g record self)"
    echo "   - both primaries out: Codex + your own thorough review ($g record codex, then $g record self)"
    echo "   - both primaries and Codex out: the gate can't pass. Leave the PR as a draft, list the skips, ask Tim."
    echo "4. Once \`$g check\` passes, list every reviewer, skip and reason in the PR body, then \`gh pr ready\`."
    echo "Never falsify or work around the gate. CodeRabbit: free hourly allowance only, never --use-credits."
  } >&2
  exit 2
fi
}

# ── Pre-push gate: git push needs a pre-push review of the commit it publishes ──
push_block() { echo "BLOCKED by the pre-push review gate: $1" >&2; exit 2; }
push_risky() {
  printf '%s' "$cmd" | grep -Eq "(^|[[:space:];&|(){}'\"\`])(cd|pushd|popd)([[:space:]]|\$)|(^|[[:space:]])(-C|--git-dir|--work-tree)([[:space:]=]|\$)|GIT_DIR|GIT_WORK_TREE|CDPATH"
}
has_push_word() { printf '%s' "$cmd" | grep -Eq '(^|[^[:alnum:]_-])push([^[:alnum:]_-]|$)'; }
push_gate() {
  if [ "${REVIEW_GATE_PREPUSH:-}" = off ]; then
    # Tim's own switch, set in Claude Code's environment; logged so a bypass is never silent.
    local log="${XDG_STATE_HOME:-$HOME/.local/state}/review-gate/prepush-bypass.log"
    mkdir -p "$(dirname "$log")" 2>/dev/null &&
      printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$session_cwd" "$(printf '%s' "$cmd" | tr '\n\t' '  ' | cut -c1-300)" >>"$log" 2>/dev/null
    add_msg "review-gate: pre-push gate is OFF (REVIEW_GATE_PREPUSH=off); push not checked, logged to $log"
    return 0
  fi
  local res status reason ptargets=""
  if [ "$have_resolver" = 1 ]; then
    res="$(printf '%s' "$cmd" | node "$here/resolve-pr-target.mjs" "$session_cwd" --push 2>/dev/null || true)"
    status="$(printf '%s' "$res" | jq -r '.status // empty' 2>/dev/null || true)"
    reason="$(printf '%s' "$res" | jq -r '.reason // empty' 2>/dev/null || true)"
    case "$status" in
      none) return 0 ;;
      ok) ptargets="$(printf '%s' "$res" | jq -c '.targets[]')" ;;
      block) push_block "$reason" ;;
      *) # unparseable, or the resolver failed: the session cwd's HEAD, unless the push may run elsewhere
        has_push_word || return 0   # without the resolver only a literal `push` is looked for
        push_risky && push_block "couldn't work out where this \`git push\` runs (${reason:-resolver failed}), and the command changes directory or names a repo. Simplify it: \`cd /literal/path && git push ...\`"
        add_msg "review-gate: couldn't parse the push (${reason:-resolver failed}); checked the session cwd's HEAD" ;;
    esac
  else
    has_push_word || return 0
    push_risky && push_block "node isn't available to parse this \`git push\`, and the command changes directory or names a repo, so the session cwd may be the wrong repo."
    add_msg "review-gate: node unavailable; checked the session cwd's HEAD for the push"
  fi
  [ -n "$ptargets" ] || ptargets="$(jq -cn --arg d "$session_cwd" '{dir: $d, rev: null, note: null}')"
  local t dir rev note out rc pblocked="" g
  g="bash $(printf '%q' "$gate")"
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    dir="$(printf '%s' "$t" | jq -r '.dir')"
    rev="$(printf '%s' "$t" | jq -r '.rev // empty')"
    note="$(printf '%s' "$t" | jq -r '.note // empty')"
    [ -n "$note" ] && add_msg "review-gate: $note"
    out="$( (cd "$dir" && bash "$gate" check-prepush ${rev:+--rev "$rev"}) 2>&1 >/dev/null )"; rc=$?
    case "$rc" in
      0) [ -n "$out" ] && add_msg "$out" ;;   # never hide accepted findings
      1) pblocked="${pblocked:+$pblocked
}  $dir${rev:+ @ ${rev:0:12}}: $out
    run there:  cd $(printf '%q' "$dir") && $g prepush" ;;
      *) add_msg "review-gate: $dir is not a git repo with commits; push not gated" ;;   # fail-open by design
    esac
  done <<<"$ptargets"
  if [ -n "$pblocked" ]; then
    {
      echo "BLOCKED by the pre-push review gate: every push to a PR branch needs a review of the WHOLE change first."
      echo "$pblocked"
      echo "1. \`$g prepush\` reviews \`git diff <base>...HEAD\` against the repo's punch list (review/PUNCH_LIST.md):"
      echo "   Codex first, a read-only Claude review if Codex can't run. Base: the PR's base, else origin/main (--base <ref>)."
      echo "2. Fix every P0-P2 finding (and the same bug class elsewhere in the diff), commit, run prepush again, then push."
      echo "3. A finding you decide not to fix: decline it explicitly for this commit, then push:"
      echo "       $g prepush-accept --reason \"why each P0-P2 finding is not being fixed\""
      echo "   The reason is announced by every later check of this commit. A FAILED review (error, quota, empty or"
      echo "   cut-off answer) records nothing and can't be accepted: run it again, or leave the push and ask Tim."
    } >&2
    exit 2
  fi
}

[ "$want_pr" = 1 ] && pr_gate
[ "$want_push" = 1 ] && push_gate
[ -n "$msgs" ] && jq -cn --arg m "$msgs" '{systemMessage: $m}'
exit 0
