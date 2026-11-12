#!/usr/bin/env bash
# PreToolUse(Bash) hook: `gh pr create --draft` is always allowed (the PR reviewers —
# Kodus, CodeRabbit/Greptile — only review a PR that exists). `gh pr ready` and a non-draft
# `gh pr create` are blocked until `review-gate check` passes (two different reviewers'
# passes, primaries passed or skipped) for the PR's commit, in the repo the PR comes from
# (followed from `cd`/`--repo`/`--head` by resolve-pr-target.mjs; the session cwd is only
# the fallback). Marking a PR ready through the GraphQL API is blocked outright.
# Pushes are gated by git itself: githooks/pre-push (core.hooksPath) needs a passing OpenQodex review of each pushed
# commit. This hook only blocks the ways around a git hook, with a short fixed check (bypass_check below): skipping
# it (--no-verify), pointing git elsewhere for its hooks or its config, and setting the gate's own variables. Tim's
# escape hatch: REVIEW_GATE_PREPUSH=off in the environment Claude Code runs in (never a command prefix), logged.
# Wire into ~/.claude/settings.json (matcher: "Bash"). Filename kept for back-compat
# with existing settings.json entries.
# Part of https://github.com/job-bot-ai/ai-code-review-mcp
#
# Fail-open where it can't tell (no jq, review-gate's "nothing to gate"), so it never wedges the shell; a genuine
# "no green light", a bypass, and any unexpected review-gate exit code return exit 2 (which blocks the tool call).

input="$(cat)"

# Fast path: if the payload can't possibly contain `gh ... pr ... create` or touch git or the gate, allow now.
printf '%s' "$input" | grep -Eqi 'gh[^"]*pr[^"]*(create|new|ready)|markPullRequestReadyForReview|git|review_gate|openqodex|hookspath' || exit 0   # `gh pr new` is an alias

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

# ── Ways around the git pre-push hook: a fixed list, matched anywhere in the command (no parsing) ──
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
session_cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
[ -n "$session_cwd" ] && [ -d "$session_cwd" ] || session_cwd="$PWD"
bypass_check() {
  local why="" log
  if [ "${REVIEW_GATE_PREPUSH:-}" = off ]; then   # Tim's switch, set in Claude Code's own environment
    log="${XDG_STATE_HOME:-$HOME/.local/state}/review-gate/prepush-bypass.log"
    # A bypass is never silent: when it can't be logged, the checks below apply.
    { mkdir -p "$(dirname "$log")" &&
      printf '%s\tclaude-hook\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(printf '%s' "$cmd" | tr '\n\t' '  ' | cut -c1-300)" >>"$log"; } 2>/dev/null &&
      return 0
  fi
  # Matched with quotes and backslashes removed, so `"core.hooks""Path"` or `"-"c` is read as what the shell runs.
  local c; c="$(printf '%s' "$cmd" | tr -d "\"'\\\\")"
  m() { printf '%s' "$c" | grep -Eq -- "$1"; }
  mi() { printf '%s' "$c" | grep -Eqi -- "$1"; }
  local git='(^|[^[:alnum:]_.-])git([^[:alnum:]_-]|$)' push='(^|[^[:alnum:]_-])push([^[:alnum:]_-]|$)'
  if m '(^|[^[:alnum:]_])(REVIEW_GATE_[[:alnum:]_]*|OPENQODEX_[[:alnum:]_]*)[[:space:]]*=' || m '(^|[^[:alnum:]_])REVIEW_GATE_PREPUSH([^[:alnum:]_]|$)'; then
    why="it sets a REVIEW_GATE_* / OPENQODEX_* variable. The gate's settings, and the REVIEW_GATE_PREPUSH=off switch, are Tim's."
  elif m "$push" && m '(^|[[:space:]])--no-ve'; then
    why="--no-verify skips the git pre-push hook."
  elif m "$git" && m "$push" && printf '%s' "$c" | grep -Pq -- '(^|\s)(-c\s+(?!credential\.helper=)|--config-env)'; then
    why="a git push may only take -c credential.helper=...: any other -c or --config-env can switch the pre-push hook off."
  elif m "$git" && mi 'hookspath' && ! mi '^[[:space:]]*git[[:space:]]+(-C[[:space:]]+[^[:space:];&|]+[[:space:]]+)?config([[:space:]]+--(global|local|system|show-origin|show-scope))*[[:space:]]+--get(-all)?[[:space:]]+core\.hookspath[[:space:]]*$'; then
    why="it sets or overrides core.hooksPath (git -c, --config-env, git config): the pre-push hook would not run."
  elif m "$git" && m '(^|[^[:alnum:]_-])(send-pack|http-push)([^[:alnum:]_-]|$)'; then
    why="git send-pack/http-push publish refs without running the pre-push hook."
  elif m "$git" && m '(^|[^[:alnum:]_-])config([[:space:]]+[^;&|]*)?[[:space:]](--remove-section|--rename-section|--edit|-e)([[:space:]]|$)'; then
    why="it edits or removes git config sections, which can drop core.hooksPath."
  elif m "$git" && m '(^|[^[:alnum:]_])(GIT_CONFIG[[:alnum:]_]*|GIT_DIR|GIT_COMMON_DIR|HOME|XDG_CONFIG_HOME)[[:space:]]*='; then
    why="it overrides GIT_CONFIG*, GIT_DIR, GIT_COMMON_DIR, HOME or XDG_CONFIG_HOME for git: another config, without the hook."
  elif m "$git" && m '(^|[^[:alnum:]_-])(env[[:space:]]+(-[[:alpha:]]*[iu]|--ignore-environment|--unset)|unset[[:space:]]+[^;&|]*(HOME|XDG_CONFIG_HOME|GIT_))'; then
    why="it clears HOME/XDG_CONFIG_HOME/GIT_* for git: git would read another config, without the hook."
  elif m 'install-githooks' && m '--uninstall'; then
    why="it uninstalls the pre-push hook."
  elif m '(\.gitconfig|\.git/config|git/config|\.git/hooks|(^|[^[:alnum:]_.-])githooks(/|$|[[:space:]]))' && m '((^|[^0-9&>])>|(^|[^[:alnum:]_-])(tee|sed[[:space:]]+-i|perl[[:space:]]+-[[:alnum:]]*i|cp|mv|ln|rm|truncate|chmod)([^[:alnum:]_-]|$))'; then
    why="it writes a git config file or a hooks folder directly."
  elif m "$git" && m "$push"; then
    # A repo-local core.hooksPath (husky sets one) wins over the global one: the gate's hook would not run there.
    local want got
    want="$(realpath -e "$here/../githooks" 2>/dev/null)"   # empty when githooks/ is missing: then nothing passes
    got="$(git -C "$session_cwd" config --get core.hooksPath 2>/dev/null || true)"
    case "$got" in "~/"*) got="$HOME/${got#\~/}" ;; esac
    [ -n "$got" ] && case "$got" in /*) ;; *) got="$(git -C "$session_cwd" rev-parse --show-toplevel 2>/dev/null)/$got" ;; esac
    [ -n "$got" ] && got="$(realpath -m "$got")"
    [ -n "$want" ] && [ "$got" = "$want" ] ||
      why="core.hooksPath in $session_cwd is ${got:-unset}, not $want, so git's pre-push review hook would not run (install-githooks --global; a repo-local core.hooksPath, as husky sets, overrides it)."
  fi
  [ -z "$why" ] && return 0
  echo "BLOCKED by the pre-push review gate: $why Push with a plain \`git push\`: the git hook checks the OpenQodex review (review-gate prepush). If the gate is wrong, stop and ask Tim." >&2
  exit 2
}
bypass_check

# `gh pr ready` is the only way the gate lets a PR out of draft: the resolver also blocks the
# GraphQL ready mutation sent by an API client (gh api, curl, ...) wherever it runs, and lets
# mentions that are only data (echo, a heredoc written to a file) through.

# Any `gh pr create` words anywhere go to the resolver, which follows runners
# (`timeout 60 gh pr create`), `GH_REPO=... gh pr create`, `bash -c`, `eval`, backticks
# and pipes into shells, and lets mentions that are only data (commit messages, grep
# patterns) through. Only the no-node fallback below keeps the command-position match.
# (`\n`/`\t` escapes count as separators: `printf 'cd x\ngh pr create' | bash`.)
printf '%s' "$cmd" | grep -Eq '(^|[^[:alnum:]_-]|\\[nt])gh([[:space:]]|\\t)+pr([[:space:]]|\\t)+(create|new|ready)([^[:alnum:]_-]|$)|markPullRequestReadyForReview' || exit 0

gate="$here/../review-gate"

# Fail-open if the gate helper is missing/unreadable — never wedge the shell.
[ -r "$gate" ] || exit 0

# Which checkout(s) do the PR(s) come from? Not necessarily the session's cwd: the
# resolver follows `cd` before each `gh pr create`, checks `--repo` against that checkout's
# remotes and prefers the worktree holding `--head` (resolve-pr-target.mjs).
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
  if printf '%s' "$cmd" | grep -q 'markPullRequestReadyForReview'; then   # can't tell data from code here
    block "the command mentions the GraphQL ready mutation and the target resolver (node) isn't available. Use \`gh pr ready\`."
  fi
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
    3)  [ -n "$note" ] || msgs="${msgs:+$msgs
}review-gate: $dir is not a git repo with commits; not gated" ;;   # review-gate's "nothing to gate"
    *)  blocked="${blocked:+$blocked
}  $where: review-gate check failed unexpectedly (exit $rc): ${out:-no output}" ;;   # never a pass
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
[ -n "$msgs" ] && jq -cn --arg m "$msgs" '{systemMessage: $m}'
exit 0
