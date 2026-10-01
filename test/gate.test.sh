#!/usr/bin/env bash
# Integration tests: feed Claude Code-style PreToolUse payloads to the real hook and check
# that it gates on the PR's target repo. Uses throwaway repos under a temp dir; no network.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
hook="$root/hooks/pre-pr-coderabbit-gate.sh"
gate="$root/review-gate"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
unset REVIEW_GATE_REQUIRED
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

pass=0; fail=0
mkrepo() { # mkrepo <dir> <owner/repo>
  git init -q -b main "$1" && git -C "$1" remote add origin "https://github.com/$2.git"
  git -C "$1" commit -q --allow-empty -m init
}
green() { (cd "$1" && bash "$gate" record coderabbit >/dev/null && bash "$gate" record codex >/dev/null); }
run() { # run <cwd> <command> → sets rc, out, err
  local payload; payload="$(jq -cn --arg c "$2" --arg d "$1" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')"
  out="$(printf '%s' "$payload" | bash "$hook" 2>"$T/err")"; rc=$?; err="$(cat "$T/err")"
}
expect() { # expect <name> <rc> [stdout|stderr] [substring]
  local ok=1
  [ "$rc" -eq "$2" ] || ok=0
  if [ -n "${4:-}" ]; then
    local hay; [ "$3" = stdout ] && hay="$out" || hay="$err"
    case "$hay" in *"$4"*) ;; *) ok=0;; esac
  fi
  if [ "$ok" -eq 1 ]; then pass=$((pass + 1)); echo "ok   - $1"
  else fail=$((fail + 1)); echo "FAIL - $1 (rc=$rc)"; echo "       stdout: $out"; echo "       stderr: $err"; fi
}

mkrepo "$T/a" acme/alpha && green "$T/a"
mkrepo "$T/b" acme/beta
mkdir "$T/plain"

run "$T/a" "cd $T/b && gh pr create --fill"
expect "cd into an unreviewed repo is blocked even though the session repo is green" 2 stderr "checked $T/b"

green "$T/b"
run "$T/a" "cd $T/b && gh pr create --fill"
expect "cd into a reviewed repo passes and says which repo was gated" 0 stdout "gated on $T/b"

run "$T/a" "gh pr create --repo acme/beta --fill"
expect "--repo that doesn't match the checkout is blocked" 2 stderr "the PR targets acme/beta"

run "$T/a" "gh pr create -R github.com/ACME/alpha --fill"
expect "--repo matching the checkout passes quietly" 0
[ -z "$out" ] || { fail=$((fail + 1)); echo "FAIL - quiet pass printed: $out"; }

mkrepo "$T/c" acme/gamma
(cd "$T/c" && bash "$gate" record coderabbit >/dev/null)
(cd "$T/c" && bash "$gate" record-skip codex --reason "" >/dev/null 2>&1); rc=$?
expect "record-skip without a reason is refused" 2
(cd "$T/c" && bash "$gate" record-skip codex --reason "quota exhausted until Oct 3" >/dev/null)
run "$T/a" "cd $T/c && gh pr create --fill"
expect "a recorded skip passes but is announced" 0 stdout "codex was SKIPPED"

git -C "$T/c" commit -q --allow-empty -m more
run "$T/a" "cd $T/c && gh pr create --fill"
expect "a skip is bound to its commit (new commit → blocked)" 2 stderr "missing/stale"

mkrepo "$T/d" acme/delta
(cd "$T/d" && bash "$gate" record-skip codex --reason "codex is down today" >/dev/null && bash "$gate" record-skip coderabbit --reason "coderabbit is down today" >/dev/null)
run "$T/a" "cd $T/d && gh pr create --fill"
expect "skipping every reviewer is not enough" 2 stderr "at least one real review"

mkrepo "$T/e" acme/epsilon
git -C "$T/e" worktree add -q -b feat/x "$T/e-wt" && green "$T/e-wt"
run "$T/a" "cd $T/e && gh pr create --head feat/x --fill"
expect "--head checked out in another worktree is gated there" 0 stdout "gated on $T/e-wt"
git -C "$T/e" branch -q feat/y
run "$T/a" "cd $T/e && gh pr create --head acme:feat/y --fill"
expect "--head local branch without a review is blocked at its own commit" 2 stderr "missing/stale"
run "$T/a" "cd $T/e && gh pr create --head nosuch --fill"
expect "--head that isn't a local branch is blocked" 2 stderr "isn't a local branch"

run "$T/a" "cd \$REPO && gh pr create --fill"
expect "a dynamic cd is blocked" 2 stderr "isn't a literal path"
run "$T/a" "cd $T/nope && gh pr create --fill"
expect "cd into a missing directory is blocked" 2 stderr "doesn't exist"
run "$T/a" "cd $T/plain && gh pr create --fill"
expect "outside a git repo the gate fails open" 0

run "$T/a" "gh pr view 3"
expect "non-create commands pass silently" 0
[ -z "$out$err" ] || { fail=$((fail + 1)); echo "FAIL - non-create printed something"; }

run "$T/a" "cd $T/b && gh pr create --title \"unterminated"
expect "unparseable command falls back to the session cwd, with a note" 0 stdout "couldn't parse"

run "$T/b" "git commit -q -F - <<'EOF'
don't stop
EOF
gh pr create --fill"
expect "heredoc with an apostrophe before gh pr create resolves normally" 0

echo "# pass $pass"; echo "# fail $fail"
[ "$fail" -eq 0 ]
