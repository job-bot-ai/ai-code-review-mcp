#!/usr/bin/env bash
# Integration tests: feed Claude Code-style PreToolUse payloads to the real hook and check
# that it gates on the PR's target repo. Uses throwaway repos under a temp dir; no network.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
hook="$root/hooks/pre-pr-coderabbit-gate.sh"
gate="$root/review-gate"
T="$(cd "$(mktemp -d)" && pwd -P)"   # physical path: macOS /var is a symlink to /private/var
trap 'rm -rf "$T"' EXIT
unset REVIEW_GATE_REQUIRED REVIEW_GATE_MIN
export REVIEW_GATE_PRIMARY="kodus coderabbit"   # the date-based default is tested separately
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

pass=0; fail=0
mkrepo() { # mkrepo <dir> <owner/repo>
  git init -q -b main "$1" && git -C "$1" remote add origin "https://github.com/$2.git"
  git -C "$1" commit -q --allow-empty -m init
}
# A pre-push review recorded for HEAD (the marker `review-gate prepush` writes; prepush itself is tested below).
prepushed() {
  local h gd; h="$(git -C "$1" rev-parse HEAD)"; gd="$(git -C "$1" rev-parse --absolute-git-dir)"
  mkdir -p "$gd/review-gate" && printf '%s main 2026-11-11T00:00:00Z pass origin/main codex\n' "$h" >"$gd/review-gate/prepush"
}
green() { (cd "$1" && bash "$gate" record kodus >/dev/null && bash "$gate" record coderabbit >/dev/null) && prepushed "$1"; }
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
(cd "$T/c" && bash "$gate" record kodus >/dev/null)
(cd "$T/c" && bash "$gate" record-skip coderabbit --reason "" >/dev/null 2>&1); rc=$?
expect "record-skip without a reason is refused" 2
(cd "$T/c" && bash "$gate" record-skip coderabbit --reason "not installed on this repo" >/dev/null)
run "$T/a" "cd $T/c && gh pr create --fill"
expect "a skipped primary without a replacement pass is not enough" 2 stderr "1 of 2 review passes"
(cd "$T/c" && bash "$gate" record codex >/dev/null) && prepushed "$T/c"
run "$T/a" "cd $T/c && gh pr create --fill"
expect "a skipped primary replaced by codex passes, and the skip is announced" 0 stdout "coderabbit was SKIPPED"

git -C "$T/c" commit -q --allow-empty -m more
run "$T/a" "cd $T/c && gh pr create --fill"
expect "passes and skips are bound to their commit (new commit → blocked)" 2 stderr "missing/stale"

mkrepo "$T/d" acme/delta
(cd "$T/d" && bash "$gate" record kodus >/dev/null && bash "$gate" record codex >/dev/null)
run "$T/a" "cd $T/d && gh pr create --fill"
expect "a primary with neither a pass nor a skip blocks, even with two passes" 2 stderr "primary reviewer coderabbit has no pass or skip"
(cd "$T/d" && bash "$gate" clear >/dev/null && bash "$gate" record-skip kodus --reason "kodus errored on this PR" >/dev/null \
  && bash "$gate" record coderabbit >/dev/null && bash "$gate" record self >/dev/null)
run "$T/a" "cd $T/d && gh pr create --fill"
expect "self only counts after codex passed or was skipped" 2 stderr "self review only counts after codex"
mkrepo "$T/d3" acme/delta3
(cd "$T/d3" && bash "$gate" record kodus >/dev/null && bash "$gate" record coderabbit >/dev/null && bash "$gate" record self >/dev/null) && prepushed "$T/d3"
run "$T/a" "cd $T/d3 && gh pr create --fill"
expect "an extra, ineligible self pass doesn't invalidate two primary passes" 0
(cd "$T/d" && bash "$gate" record-skip codex --reason "codex quota exhausted today" >/dev/null) && prepushed "$T/d"
run "$T/a" "cd $T/d && gh pr create --fill"
expect "coderabbit + self with kodus and codex skipped passes" 0 stdout "codex was SKIPPED"
(cd "$T/d" && bash "$gate" clear >/dev/null && bash "$gate" record-skip kodus --reason "kodus errored on this PR" >/dev/null \
  && bash "$gate" record-skip coderabbit --reason "no review within 30 minutes" >/dev/null && bash "$gate" record codex >/dev/null)
run "$T/a" "cd $T/d && gh pr create --fill"
expect "skips never count as passes (codex alone is one review)" 2 stderr "1 of 2 review passes"
(cd "$T/d" && bash "$gate" record self >/dev/null) && prepushed "$T/d"
run "$T/a" "cd $T/d && gh pr create --fill"
expect "both primaries skipped: codex + self is two reviews" 0
mkrepo "$T/d2" acme/delta2
(cd "$T/d2" && bash "$gate" record kimi >/dev/null 2>&1); rc=$?
expect "kimi is no longer a valid reviewer" 2
# A kimi marker left over from the retired kimi-review tool: status/check must not crash, and it never counts.
h2="$(git -C "$T/d2" rev-parse HEAD)"; mkdir -p "$T/d2/.git/review-gate"
printf '%s main 2026-11-01T00:00:00Z\n' "$h2" >"$T/d2/.git/review-gate/kimi"
printf '%s main 2026-11-01T00:00:00Z legacy kimi skip\n' "$h2" >"$T/d2/.git/review-gate/kimi.skip"
(cd "$T/d2" && bash "$gate" status >"$T/st2" 2>&1); rc=$?; out="$(cat "$T/st2")"
expect "status works with a leftover kimi marker and doesn't list kimi" 0
case "$out" in *kimi*) fail=$((fail + 1)); echo "FAIL - status lists kimi: $out";; esac
(cd "$T/d2" && bash "$gate" record kodus >/dev/null)
(cd "$T/d2" && bash "$gate" check >/dev/null 2>"$T/e2"); rc=$?; err="$(cat "$T/e2")"
expect "kodus + a leftover kimi pass is one review, not two" 1 stderr "1 of 2 review passes (kodus)"
case "$err" in *kimi*) fail=$((fail + 1)); echo "FAIL - check mentions kimi: $err";; esac
(cd "$T/d2" && bash "$gate" clear kodus >/dev/null && bash "$gate" record codex >/dev/null)
run "$T/a" "cd $T/d2 && gh pr create --fill"
expect "the old kimi+codex pair no longer satisfies the default gate" 2 stderr "primary reviewer kodus has no pass or skip"
(cd "$T/d2" && bash "$gate" record greptile >/dev/null 2>&1 && REVIEW_GATE_PRIMARY="kodus greptile" bash "$gate" check >/dev/null 2>"$T/e2"); rc=$?; err="$(cat "$T/e2")"
expect "greptile is a valid reviewer (kodus still has to pass or be skipped)" 1 stderr "primary reviewer kodus"
(cd "$T/d2" && bash "$gate" record agy >/dev/null 2>&1); rc=$?
expect "agy stays a valid reviewer for old records" 0
(cd "$T/d2" && bash "$gate" record bogus >/dev/null 2>&1); rc=$?
expect "an unknown reviewer is refused" 2

# Default primaries: Kodus + Greptile, whatever the date (CodeRabbit retired 2026-11-12).
mkdir -p "$T/fakebin"
printf '#!/bin/sh\ncase "$*" in *+%%Y%%m%%d*) echo "${FAKE_DAY}";; *) exec /bin/date "$@";; esac\n' >"$T/fakebin/date"; chmod +x "$T/fakebin/date"
for day in 20261112 20261118 20261119; do
  (cd "$T/d2" && FAKE_DAY=$day PATH="$T/fakebin:$PATH" REVIEW_GATE_PRIMARY= bash "$gate" status) >"$T/st" 2>&1
  grep -q 'greptile .*\[primary\]' "$T/st" && grep -q 'kodus .*\[primary\]' "$T/st" && ! grep -q 'coderabbit .*\[primary\]' "$T/st"; rc=$?
  expect "on $day the default primaries are kodus + greptile" 0
done

# ── Draft PRs and gh pr ready ──
mkrepo "$T/r" acme/ready
run "$T/r" "gh pr create --draft --fill"
expect "gh pr create --draft is allowed with no reviews" 0
run "$T/r" "gh pr create -d --fill"
expect "gh pr create -d is allowed with no reviews" 0
run "$T/r" "gh pr create -dt title -b body"
expect "a clustered -dt is a draft" 0
run "$T/a" "cd \$REPO && gh pr create --draft --fill"
expect "a draft is allowed even when the directory is unknown" 0
run "$T/a" "cd \$REPO && gh pr ready"
expect "gh pr ready after a dynamic cd is still blocked" 2 stderr "isn't a literal path"
run "$T/r" "gh pr create -d=false --fill"
expect "-d=false is not a draft (gated)" 2 stderr "missing/stale"
run "$T/r" "gh pr create -fd=\$DRAFT"
expect "a non-literal clustered draft value is not trusted as a draft" 2 stderr "non-literal argument"
run "$T/r" "gh pr create --draft=\$DRAFT --fill"
expect "a non-literal --draft value is not trusted as a draft" 2 stderr "non-literal argument"
run "$T/r" "gh pr create -d=0 --fill"
expect "-d=0 is not a draft (gated)" 2 stderr "missing/stale"
run "$T/r" "gh pr create --draft=false --fill"
expect "--draft=false is not a draft (gated)" 2 stderr "missing/stale"
run "$T/r" "gh pr create --fill"
expect "a non-draft gh pr create without reviews is blocked" 2 stderr "gh pr create --draft"
run "$T/r" "bash -c 'gh pr create --fill'"
expect "a non-draft gh pr create inside bash -c is still blocked" 2 stderr "missing/stale"
run "$T/r" "GH_REPO=acme/ready gh pr create --fill"
expect "an env-prefixed non-draft gh pr create is still blocked" 2 stderr "missing/stale"
export REVIEW_GATE_GH="$T/nogh"; printf '#!/bin/sh\nexit 1\n' >"$T/nogh"; chmod +x "$T/nogh"
run "$T/r" "gh pr ready"
expect "gh pr ready before any reviews is blocked" 2 stderr "0 of 2 review passes"
run "$T/r" "eval 'gh pr ready'"
expect "gh pr ready through eval is blocked" 2 stderr "missing/stale"
run "$T/r" "bash -c 'gh pr ready'"
expect "gh pr ready through bash -c is blocked" 2 stderr "missing/stale"
run "$T/r" "timeout 30 gh pr ready"
expect "gh pr ready through a runner is blocked" 2 stderr "missing/stale"
run "$T/r" "gh pr ready --undo"
expect "gh pr ready --undo (back to draft) is not gated" 0
run "$T/r" "gh pr ready 12"
expect "gh pr ready <number> whose head can't be looked up is blocked" 2 stderr "couldn't look up PR 12"
run "$T/r" "gh pr ready https://github.com/someone/fork/pull/3"
expect "gh pr ready <url> of another repo is blocked before any lookup" 2 stderr "the PR targets someone/fork"
run "$T/r" "gh pr ready -R acme/ready https://github.com/someone/fork/pull/3"
expect "a URL selector wins over --repo (still checked)" 2 stderr "the PR targets someone/fork"
MUT="markPullRequest""ReadyForReview"
run "$T/r" "gh api graphql -f query='mutation { $MUT(input:{pullRequestId:\"x\"}) { clientMutationId } }'"
expect "marking ready through the GraphQL API is blocked" 2 stderr "not through the GraphQL API"
run "$T/r" "grep -rn $MUT docs/"
expect "only mentioning the mutation (no API call) is not blocked" 0
run "$T/r" "echo 'gh api graphql -f query=mutation{$MUT}' > notes.txt"
expect "echoing an example API call is data, not blocked" 0
run "$T/r" "bash -c 'gh api graphql -f query=mutation{$MUT}'"
expect "the mutation inside bash -c is blocked" 2 stderr "not through the GraphQL API"
run "$T/r" "GH_HOST=github.com gh api graphql -f query='mutation{$MUT}'"
expect "an env-prefixed API call with the mutation is blocked" 2 stderr "not through the GraphQL API"
run "$T/r" "cat > example.sh <<'EOF'
gh api graphql -f query='mutation{$MUT}'
EOF"
expect "a heredoc written to a file that contains the mutation is data, not blocked" 0
run "$T/r" "bash <<'EOF'
gh api graphql -f query='mutation{$MUT}'
EOF"
expect "the mutation in a heredoc fed to bash is blocked" 2 stderr "not through the GraphQL API"
run "$T/r" "timeout 30 curl -s https://api.github.com/graphql -d '{\"query\":\"mutation{$MUT}\"}'"
expect "curl through a runner with the mutation is blocked" 2 stderr "not through the GraphQL API"
run "$T/r" "echo 'mutation{$MUT}' | gh api graphql --input -"
expect "the mutation piped into gh api is blocked" 2 stderr "not through the GraphQL API"
run "$T/r" "timeout 60 gh pr create --title curl --body test"
expect "a runner-wrapped PR create whose args contain an API client name is still gated" 2 stderr "missing/stale"
run "$T/r" "env gh pr ready curl"
expect "a runner-wrapped gh pr ready with a client-named argument is still gated" 2 stderr "couldn't look up PR curl"
run "$T/r" "env FOO=1 curl -s -d 'mutation{$MUT}' https://api.github.com/graphql"
expect "env-wrapped curl with the mutation is blocked" 2 stderr "not through the GraphQL API"
run "$T/r" "env GH_REPO=someone/fork bash -c 'gh pr create --fill'"
expect "a runner's GH_REPO reaches gh inside a nested bash -c" 2 stderr "the PR targets someone/fork"
run "$T/r" "GH_REPO=someone/fork bash -c 'gh pr create --fill'"
expect "a prefix GH_REPO reaches gh inside a nested bash -c" 2 stderr "the PR targets someone/fork"
run "$T/r" "env -C $T/a xargs gh pr create --fill"
expect "env -C keeps the directory unknown through a fallback runner (xargs)" 2 stderr "isn't a literal path"
run "$T/r" "env GH_REPO=acme/ready GH_REPO=someone/fork gh pr create --fill"
expect "the last GH_REPO assignment wins" 2 stderr "the PR targets someone/fork"
run "$T/r" "sudo -uroot gh pr create --fill"
expect "sudo with an attached option value (-uroot) still gates gh pr create" 2 stderr "missing/stale"
run "$T/r" "sudo -uroot gh pr ready"
expect "sudo with an attached option value (-uroot) still gates gh pr ready" 2 stderr "missing/stale"
run "$T/r" "env -- GH_REPO=someone/fork gh pr create --fill"
expect "env assignments after -- still apply" 2 stderr "the PR targets someone/fork"
run "$T/r" "sudo -uroot git push && gh pr ready"
expect "a sudo-wrapped git push with an attached option value before gh pr ready blocks" 2 stderr "runs before"
run "$T/r" "env echo curl $MUT"
expect "a runner launching echo is data even when an argument is named curl" 0
run "$T/r" "timeout -s KILL 60 gh pr create --title curl --body x"
expect "timeout with a valued option before the duration still gates the PR create" 2 stderr "missing/stale"
run "$T/r" "sudo -u bob gh pr create --fill"
expect "sudo -u user gh pr create is gated" 2 stderr "missing/stale"
run "$T/r" "nice -n 5 bash -c 'gh pr ready'"
expect "nice -n 5 bash -c gh pr ready is gated" 2 stderr "missing/stale"
run "$T/r" "env -C $T/a gh pr ready"
expect "env -C runs gh pr ready elsewhere (directory unknown, blocked)" 2 stderr "isn't a literal path"
run "$T/r" "env git commit -q --allow-empty -m x && gh pr create --fill"
expect "a runner-wrapped git commit before gh pr create blocks" 2 stderr "git commit"
run "$T/r" "ssh host 'gh api graphql -f query=mutation{$MUT}'"
expect "the mutation passed somewhere the gate can't follow is blocked" 2 stderr "can't follow"
green "$T/r"
run "$T/r" "gh pr ready"
expect "gh pr ready after two passes is allowed (falls back to local HEAD when gh can't look it up)" 0 stdout "checked local HEAD"
# With a (fake) gh that reports the PR's head: the gate checks THAT commit.
fakegh() { printf '#!/bin/sh\necho "{\\"headRefOid\\":\\"%s\\",\\"headRefName\\":\\"main\\"}"\n' "$1" >"$T/fakegh"; chmod +x "$T/fakegh"; }
fakegh "$(git -C "$T/r" rev-parse HEAD)"
export REVIEW_GATE_GH="$T/fakegh"
run "$T/r" "gh pr ready 7"
expect "gh pr ready <number> checks the PR's head commit (reviewed → allowed)" 0
git -C "$T/r" commit -q --allow-empty -m "local follow-up"
run "$T/r" "gh pr ready"
expect "the PR's pushed head is what's checked, not a newer local HEAD" 0
fakegh "$(git -C "$T/r" rev-parse HEAD)"
run "$T/r" "gh pr ready"
expect "a new commit on the PR makes the reviews stale (blocked)" 2 stderr "missing/stale"
run "$T/r" "git push origin HEAD:main && gh pr ready"
expect "a git push in the same command as gh pr ready blocks (the PR head would change)" 2 stderr "runs before \`gh pr ready\`"
run "$T/r" "git push && gh pr ready"
expect "a bare git push before gh pr ready blocks too" 2 stderr "runs before \`gh pr ready\`"
run "$T/r" "/usr/bin/git push && gh pr ready"
expect "a git push by absolute path before gh pr ready blocks" 2 stderr "runs before"
run "$T/r" "/usr/bin/timeout 60 /usr/bin/git push && gh pr ready"
expect "runner and git both by absolute path before gh pr ready blocks" 2 stderr "runs before"
run "$T/r" "/bin/bash -c 'gh pr ready'"
expect "a shell by absolute path is walked like bash -c" 2 stderr "missing/stale"
run "$T/r" "/usr/bin/cd $T/a && gh pr ready"
expect "/usr/bin/cd doesn't move the shell (gated in the session repo)" 2 stderr "$T/r"
run "$T/r" "timeout 60 git push && gh pr ready"
expect "a runner-wrapped git push before gh pr ready blocks" 2 stderr "runs before \`gh pr ready\`"
run "$T/r" "env git push && gh pr ready"
expect "an env-wrapped git push before gh pr ready blocks" 2 stderr "runs before \`gh pr ready\`"
fakegh 0123456789abcdef0123456789abcdef01234567
run "$T/r" "gh pr ready"
expect "a PR head that isn't in the checkout is blocked" 2 stderr "isn't in"
unset REVIEW_GATE_GH

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

run "$T/b" "cat > /dev/null <<'EOF'
don't stop
EOF
gh pr create --fill"
expect "heredoc with an apostrophe before gh pr create resolves normally" 0
run "$T/b" "git commit -q --allow-empty -m wip && gh pr create --fill"
expect "a commit made in the same command as gh pr create blocks (it can't have been reviewed)" 2 stderr "git commit"
run "$T/b" "git checkout -q -b feat/new && gh pr create --fill"
expect "creating a branch at HEAD before gh pr create keeps the reviewed commit" 0


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
run "$T/a" "gh pr create -fH feat/unrev-branch"
expect "clustered -fH is parsed (unreviewed branch tip is blocked)" 2 stderr "missing/stale"
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
(cd "$T/a" && REVIEW_GATE_PRIMARY="kodus nobody" bash "$gate" check >/dev/null 2>"$T/e2"); rc=$?; err="$(cat "$T/e2")"
expect "an unknown reviewer in REVIEW_GATE_PRIMARY says so" 1 stderr "unknown primary reviewer 'nobody'"

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

# ── CodeRabbit on the agy fixes ──
run "$T/u" "command gh pr create --fill"
expect "command gh pr create is gated" 2 stderr "$T/u: missing/stale"
run "$T/a" "gh pr create --fill && awk 'BEGIN{system(\"cd $T/u && gh pr create --fill\")}'"
expect "an opaque gh pr create isn't masked by a resolvable one" 2 stderr "also passed to awk"

# ── through the real hook (pre-filter included): escapes in piped text ──
run "$T/a" "echo -e 'cd $T/u\ngh pr create --fill' | bash"
expect "echo -e with a \\n escape piped to bash reaches the resolver and is gated" 2 stderr "$T/u: missing/stale"
run "$T/a" "printf 'cd $T/u && gh pr create --fill\n' | bash"
expect "single-argument printf piped to bash is gated" 2 stderr "$T/u: missing/stale"

mkdir -p "$T/a/sub"
run "$T/a/sub" "gh pr create --fill"
expect "a session in a subdirectory of the reviewed checkout gets no cross-repo note" 0
[ -z "$out" ] || { fail=$((fail + 1)); echo "FAIL - subdir session printed: $out"; }
mkdir -p "$T/space dir" && mkrepo "$T/space dir/r" acme/space
run "$T/a" "cd '$T/space dir/r' && gh pr create --fill"
expect "remediation quotes paths with spaces" 2 stderr 'space\ dir/r && bash'

run "$T/a" "B=feat/other; gh pr create --head \"\$B\" --fill"
expect "a non-literal --head blocks (the PR's commit is unknown)" 2 stderr "--head is not a literal value"

# Resolver unavailable: a broken resolver must not quietly gate a cd'd PR on the session cwd.
cp -r "$root" "$T/broken" && printf 'process.exit(1)\n' > "$T/broken/hooks/resolve-pr-target.mjs"
payload="$(jq -cn --arg c "cd $T/u && gh pr create --fill" --arg d "$T/a" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')"
out="$(printf '%s' "$payload" | bash "$T/broken/hooks/pre-pr-coderabbit-gate.sh" 2>"$T/err")"; rc=$?; err="$(cat "$T/err")"
expect "if the resolver fails, a risky command blocks instead of using the session cwd" 2 stderr "couldn't run the target resolver"
payload="$(jq -cn --arg c "gh pr create --fill" --arg d "$T/a" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')"
out="$(printf '%s' "$payload" | bash "$T/broken/hooks/pre-pr-coderabbit-gate.sh" 2>"$T/err")"; rc=$?; err="$(cat "$T/err")"
expect "if the resolver fails, a plain command falls back to the session cwd with a note" 0 stdout "target resolver failed"

run "$T/a" "echo 'cd $T/u && gh pr create --fill' | cat | tee /dev/null | bash"
expect "text passed through cat/tee before reaching bash is still walked" 2 stderr "$T/u: missing/stale"

run "$T/u" "gh pr new --fill"
expect "gh pr new (alias of create) is gated" 2 stderr "$T/u: missing/stale"

run "$T/u" "/usr/bin/env true; \$(command -v true) ; /usr/local/bin/gh pr create --fill"
expect "gh invoked by path is gated" 2 stderr "$T/u: missing/stale"

# Installed through a symlink: the resolver must still run (not fall back silently).
ln -s "$root" "$T/linked"
payload="$(jq -cn --arg c "cd $T/u && gh pr create --fill" --arg d "$T/a" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')"
out="$(printf '%s' "$payload" | bash "$T/linked/hooks/pre-pr-coderabbit-gate.sh" 2>"$T/err")"; rc=$?; err="$(cat "$T/err")"
expect "a hook installed via a symlinked path still resolves the target" 2 stderr "$T/u: missing/stale"

run "$T/u" "op run -- gh pr create --fill"
expect "op run -- gh pr create (a wrapper that runs gh locally) is gated" 2 stderr "$T/u: missing/stale"

echo "# pass $pass"; echo "# fail $fail"
[ "$fail" -eq 0 ]
