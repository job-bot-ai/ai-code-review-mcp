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
expect "cd into an unreviewed repo is blocked even though the session repo is green" 2 stderr "$T/b: missing/stale"

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
expect "unparseable command that changes directory is blocked" 2 stderr "couldn't work out which repo"
run "$T/a" "gh pr create --title \"unterminated"
expect "unparseable command with no cd/--repo/--head falls back to the session cwd, with a note" 0 stdout "checked the session cwd"

run "$T/b" "git commit -q -F - <<'EOF'
don't stop
EOF
gh pr create --fill"
expect "heredoc with an apostrophe before gh pr create resolves normally" 0


# ── Reproducers from the adversarial review ──
mkrepo "$T/u" acme/unrev
run "$T/a" "cd $T/u && gh pr create --title \"x\" --body \"\$(cat <<'EOF'
- see \"issue #12\" for context
EOF
)\""
expect "PR body via \$(cat <<'EOF' ...) with quotes and # inside still gates the cd target" 2 stderr "$T/u: missing/stale"
run "$T/a" "gh pr create --fill && cd $T/u && gh pr create --fill"
expect "every gh pr create is gated, not just the first" 2 stderr "$T/u"
git -C "$T/a" branch -q feat/unrev-branch "$(git -C "$T/u" rev-parse HEAD 2>/dev/null || echo HEAD)" 2>/dev/null || git -C "$T/a" branch -q feat/unrev-branch
git -C "$T/a" commit -q --allow-empty -m newer && git -C "$T/a" branch -qf feat/unrev-branch HEAD && git -C "$T/a" reset -q --hard HEAD~1
run "$T/a" "gh pr create -dH feat/unrev-branch --fill"
expect "clustered -dH is parsed (unreviewed branch tip is blocked)" 2 stderr "missing/stale"
run "$T/a" "cd $T/plain && gh pr create -R acme/unrev -H main --title t --body b"
expect "--repo/--head from a non-git directory is blocked" 2 stderr "isn't a git checkout"
run "$T/u" "gh pr create --fill --body 'use -h for help'"
expect "' -h' inside a value no longer skips the gate" 2 stderr "missing/stale"
run "$T/u" "gh pr create --help"
expect "gh pr create --help is not gated" 0
run "$T/a" "bash -c 'cd $T/u && gh pr create --fill'"
expect "gh pr create inside bash -c is gated where it runs" 2 stderr "$T/u: missing/stale"
git -C "$T/a" update-ref refs/remotes/origin/feat/nice HEAD
run "$T/a" "git push -u origin HEAD:feat/nice && gh pr create --head feat/nice --fill"
expect "--head that only exists as a fetched remote branch uses that commit" 0
run "$T/a" "gh pr create --head stranger:main --fill"
expect "--head owner:branch whose owner matches no remote is blocked" 2 stderr "none of"
run "$T/a" "cd $T/u | gh pr create --fill"
expect "a cd in a pipeline does not move gh (gated on the session repo)" 0
run "$T/u" "cd $T/a || cd $T/u && gh pr create --fill"
expect "a cd after || makes the directory unknown (blocked)" 2 stderr "isn't a literal path, or only runs conditionally"
(cd "$T/a" && REVIEW_GATE_REQUIRED=" " bash "$gate" check >/dev/null 2>"$T/e2"); rc=$?; err="$(cat "$T/e2")"
expect "an empty REVIEW_GATE_REQUIRED says so" 1 stderr "names no reviewers"

# ── Round 2 ──
run "$T/u" "git commit -q --allow-empty -m \"\$(cat <<'EOF'
gh pr create --repo o/r used to be gated
EOF
)\""
expect "a commit message that mentions gh pr create is not a PR (passes even in an unreviewed repo)" 0
[ -z "$out$err" ] || { fail=$((fail + 1)); echo "FAIL - data-only mention printed: $out$err"; }
run "$T/u" "cat > x.sh <<'EOF'
cd \"\$1\"
gh pr create --fill
EOF"
expect "writing a script that contains gh pr create is not a PR" 0
run "$T/a" "git push -u origin HEAD:nice-name && gh pr create --head nice-name --fill"
expect "--head pushed earlier in the same command is checked at the pushed commit" 0
run "$T/u" "false && cd $T/a; gh pr create --fill"
expect "an && cd whose list ends before gh makes the directory unknown" 2 stderr "only runs conditionally"
run "$T/a" "cd $T/u && PR=\$(gh pr create --fill)"
expect "gh pr create inside \$(...) is gated where it runs" 2 stderr "$T/u: missing/stale"

# ── Round 3 ──
run "$T/a" "bash <<'EOF'
cd $T/u
gh pr create --fill
EOF"
expect "gh pr create fed to bash on a heredoc is gated where it runs" 2 stderr "$T/u: missing/stale"
run "$T/a" "T=x; bash -c \"cd $T/u && gh pr create --fill --title \$T\""
expect "a partly dynamic bash -c script is still walked" 2 stderr "$T/u: missing/stale"
mkrepo "$T/p" acme/pushy && green "$T/p" && git -C "$T/p" branch -q feat/x && git -C "$T/p" commit -q --allow-empty -m unreviewed
run "$T/a" "cd $T/p && git push -f origin HEAD:feat/x && gh pr create --head feat/x --fill"
expect "a same-command push decides --head's commit (not the stale reviewed branch)" 2 stderr "missing/stale"
run "$T/a" "ssh host 'cd /srv/x && gh pr create --fill'"
expect "gh pr create passed to an unknown command with a cd is blocked" 2 stderr "can't follow"
run "$T/a" "ssh host 'true; gh pr create --fill'"
expect "gh pr create passed to an unknown command without a cd falls back to the session cwd" 0 stdout "checked the session cwd"

# ── Round 4 ──
run "$T/a" "cat <<'EOF' | bash
cd $T/u
gh pr create --fill
EOF"
expect "code piped into bash is gated where it runs" 2 stderr "$T/u: missing/stale"
run "$T/u" "test -d $T/a && { cd $T/a; gh pr create --fill; }"
expect "a cd inside an && { } group holds for gh in the same group" 0
run "$T/u" "python3 - <<'EOF'
open('/dev/null', 'w').write('cd x && gh pr create --fill')
EOF"
expect "a python heredoc that only writes text mentioning gh pr create is data" 0
[ -z "$out$err" ] || { fail=$((fail + 1)); echo "FAIL - python data printed: $out$err"; }

# ── agy review: forms the old command-position pre-filter never handed to the resolver ──
run "$T/u" "timeout 60 gh pr create --fill"
expect "timeout 60 gh pr create is gated" 2 stderr "$T/u: missing/stale"
run "$T/a" "GH_REPO=acme/beta gh pr create --fill"
expect "GH_REPO= prefix is gated and checked against the checkout" 2 stderr "the PR targets acme/beta"
run "$T/u" "bash -c \"gh pr create --fill\""
expect "bash -c \"gh pr create\" is gated" 2 stderr "$T/u: missing/stale"
run "$T/u" "eval \"gh pr create --fill\""
expect "eval \"gh pr create\" is gated" 2 stderr "$T/u: missing/stale"
run "$T/u" "PR=\`gh pr create --fill\`"
expect "a backtick gh pr create is gated" 2 stderr "$T/u: missing/stale"
run "$T/a" "echo cd $T/u '&&' gh pr create --fill | bash"
expect "echo words piped to bash are joined like echo prints them" 2 stderr "$T/u: missing/stale"
run "$T/u" "grep -rn 'gh pr create' . ; sed -n '/gh pr create/p' x 2>/dev/null"
expect "grep/sed that only mention gh pr create still pass silently" 0
[ -z "$out$err" ] || { fail=$((fail + 1)); echo "FAIL - mention printed: $out$err"; }

echo "# pass $pass"; echo "# fail $fail"
[ "$fail" -eq 0 ]
