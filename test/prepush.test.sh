#!/usr/bin/env bash
# Pre-push review gate: `review-gate prepush` (with stub codex/claude binaries on PATH that print canned output)
# and the hook blocking `git push` until the pushed commit has a pre-push review. Throwaway repos; no network.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
hook="$root/hooks/pre-pr-coderabbit-gate.sh"
gate="$root/review-gate"
T="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$T"' EXIT
unset REVIEW_GATE_REQUIRED REVIEW_GATE_MIN REVIEW_GATE_PREPUSH REVIEW_GATE_PREPUSH_TIMEOUT
export REVIEW_GATE_PRIMARY="kodus coderabbit"
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export XDG_STATE_HOME="$T/state"

# Stub reviewers: they record their arguments and stdin, then print what the test put in $T/stub.
S="$T/stub"; mkdir -p "$S/bin"
cat >"$S/bin/codex" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >"$S/codex.args"; cat >"$S/codex.stdin"; : >"$S/codex.called"
[ -z "\${STUB_SLEEP:-}" ] || sleep "\$STUB_SLEEP"
cat "$S/codex.out"; cat "$S/codex.err" >&2; exit "\$(cat "$S/codex.rc")"
EOF
cat >"$S/bin/claude" <<EOF
#!/bin/sh
printf '%s\n' "\$@" >"$S/claude.args"; cat >"$S/claude.stdin"; : >"$S/claude.called"
cat "$S/claude.out"; exit "\$(cat "$S/claude.rc")"
EOF
printf '#!/bin/sh\nexit 1\n' >"$S/bin/nogh"
chmod +x "$S/bin/"*
export PATH="$S/bin:$PATH" REVIEW_GATE_GH="$S/bin/nogh"
codex_says() { # codex_says <rc> <stdout> [stderr]
  printf '%s' "$1" >"$S/codex.rc"; printf '%s' "$2" >"$S/codex.out"; printf '%s' "${3:-}" >"$S/codex.err"
  rm -f "$S/codex.called" "$S/claude.called"
}
claude_says() { # claude_says <rc> <json stdout>
  printf '%s' "$1" >"$S/claude.rc"; printf '%s' "$2" >"$S/claude.out"
}
claude_json() { jq -cn --arg r "$1" '{type:"result",subtype:"success",is_error:false,result:$r}'; }
claude_says 1 ""   # by default the fallback can't run either

# Codex's real usage-limit failure (curly apostrophe), followed by the trace line it prints after it.
LIMIT="ERROR: You’ve hit your usage limit. Upgrade to Pro (https://chatgpt.com/explore/pro), visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at 8:15 AM."
TRACE="2026-11-11T07:58:01.123456Z ERROR codex_core::session: failed to record rollout items: failed to queue rollout items: channel closed"

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1"; [ -z "${2:-}" ] || printf '       %s\n' "$2"; }
has() { case "$1" in *"$2"*) return 0;; *) return 1;; esac; }
prep() { # prep → rc, out, err of `review-gate prepush` in $R
  out="$(cd "$R" && bash "$gate" prepush "$@" 2>"$T/err")"; rc=$?; err="$(cat "$T/err")"
}
expect() { # expect <name> <rc> [stdout|stderr] [substring]
  local ok_=1 hay
  [ "$rc" -eq "$2" ] || ok_=0
  if [ -n "${4:-}" ]; then [ "$3" = stdout ] && hay="$out" || hay="$err"; has "$hay" "$4" || ok_=0; fi
  if [ "$ok_" -eq 1 ]; then ok "$1"; else bad "$1 (rc=$rc)" "stdout: $out
       stderr: $err"; fi
}
marker_for() { local m; m="$(git -C "$1" rev-parse --absolute-git-dir)/review-gate/prepush"; [ -f "$m" ] && cut -d' ' -f1 "$m"; }
no_marker() { [ -z "$(marker_for "$R")" ] && ok "$1" || bad "$1" "a prepush marker was recorded: $(cat "$(git -C "$R" rev-parse --absolute-git-dir)/review-gate/prepush")"; }
has_marker() { [ "$(marker_for "$R")" = "$(git -C "$R" rev-parse HEAD)" ] && ok "$1" || bad "$1" "no prepush marker for HEAD"; }
reset_marker() { rm -rf "$(git -C "$R" rev-parse --absolute-git-dir)/review-gate"; }

mkrepo() { # mkrepo <dir>: a base commit (origin/main) and one feature commit on top
  git init -q -b main "$1" && git -C "$1" remote add origin "https://github.com/acme/$(basename "$1").git"
  printf 'base\n' >"$1/f.txt" && git -C "$1" add f.txt && git -C "$1" commit -q -m base
  git -C "$1" update-ref refs/remotes/origin/main HEAD
  git -C "$1" checkout -q -b feat/x
  printf 'base\nchanged UNIQUE_DIFF_LINE\n' >"$1/f.txt" && git -C "$1" commit -q -am change
}

# ══ review-gate prepush ══
R="$T/r"; mkrepo "$R"

codex_says 0 "No findings."
prep
expect "codex 'No findings.' is a pass" 0 stdout "No findings. Recorded prepush pass"
has_marker "a pass records a prepush marker bound to HEAD"
grep -qx 'review -c sandbox_mode="read-only" -' "$S/codex.args" && ok "codex runs as \`codex review -\` (prompt on stdin) in a read-only sandbox" || bad "codex args" "$(cat "$S/codex.args")"
grep -q 'UNIQUE_DIFF_LINE' "$S/codex.stdin" && grep -q 'git diff origin/main\.\.\.' "$S/codex.stdin" &&
  ok "the prompt carries the full diff against the base" || bad "prompt lacks the diff"
grep -q 'No review/PUNCH_LIST.md' "$S/codex.stdin" && ok "without a punch list the prompt says so" || bad "punch list note missing"
[ ! -e "$S/claude.called" ] && ok "claude is not run when codex completed" || bad "claude ran after a good codex run"
(cd "$R" && bash "$gate" check-prepush) 2>/dev/null; rc=$?
[ "$rc" -eq 0 ] && ok "check-prepush passes for the reviewed commit" || bad "check-prepush rc=$rc"
(cd "$R" && bash "$gate" status) >"$T/st" 2>&1
grep -q 'prepush .*green @ .*(codex vs origin/main)' "$T/st" && ok "status shows the prepush pass for HEAD" || bad "status" "$(cat "$T/st")"

git -C "$R" commit -q --allow-empty -m "after review"
(cd "$R" && bash "$gate" check-prepush) 2>"$T/e"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'no pre-push review' "$T/e" && ok "the marker is bound to its commit (a new commit needs a new review)" || bad "binding rc=$rc" "$(cat "$T/e")"
(cd "$R" && bash "$gate" status) >"$T/st" 2>&1
grep -q 'prepush .*STALE @' "$T/st" && ok "status shows a stale prepush marker" || bad "stale status" "$(cat "$T/st")"
git -C "$R" reset -q --hard HEAD~1

mkdir -p "$R/review" && printf '# Punch list\n- PUNCH_ITEM_SENTINEL: check it\n' >"$R/review/PUNCH_LIST.md"
reset_marker; codex_says 0 "No findings."
prep
grep -q 'PUNCH_ITEM_SENTINEL' "$S/codex.stdin" && ok "review/PUNCH_LIST.md is in the prompt" || bad "punch list not in prompt"
rm -rf "$R/review"

reset_marker
codex_says 0 "user
review this
exec
bash -lc 'git diff' in /repo succeeded:
- [P1] text in the diff output is not a verdict — x:1
codex
No findings.
tokens used
1234"
prep
expect "only Codex's final message is the verdict (a [P1] in exec output doesn't count)" 0 stdout "No findings."

reset_marker
codex_says 0 "- [P1] Lease shorter than the job — worker/x.py:12
  The lease expires before the job ends.
- [P3] Nit — worker/x.py:20"
prep
expect "a P1 finding fails the pre-push review" 1 stdout "[P1] Lease shorter than the job"
has "$err" "prepush-accept --reason" && ok "the failure says how to decline findings explicitly" || bad "no accept hint" "$err"
no_marker "a P0-P2 finding records nothing"
(cd "$R" && bash "$gate" check-prepush) 2>"$T/e"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'found 1 P0-P2' "$T/e" && ok "check-prepush reports the open findings" || bad "check-prepush after findings" "$(cat "$T/e")"
(cd "$R" && bash "$gate" prepush-accept --reason "short") >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "prepush-accept needs a real reason" || bad "short reason accepted rc=$rc"
(cd "$R" && bash "$gate" prepush-accept --reason "the lease is renewed by the caller; false positive") >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && has_marker "prepush-accept records the marker for HEAD" || bad "prepush-accept rc=$rc"
(cd "$R" && bash "$gate" check-prepush) 2>"$T/e"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'ACCEPTED, not fixed — reason: the lease is renewed' "$T/e" && grep -q "prepush-$(git -C "$R" rev-parse HEAD).txt" "$T/e" &&
  ok "an accepted review passes check-prepush and is announced with its reason and findings file" || bad "accepted check" "$(cat "$T/e")"
(cd "$R" && bash "$gate" status) >"$T/st" 2>&1
grep -q 'prepush .*ACCEPTED @' "$T/st" && ok "status shows accepted findings" || bad "accepted status" "$(cat "$T/st")"

reset_marker
codex_says 0 "- [P3] Only a nit — a.sh:3"
prep
expect "P3-only findings still pass" 0 stdout "only P3 findings"
has_marker "P3-only records the marker"

# ── a reviewer that errors is never a pass ──
reset_marker
codex_says 1 "" "$LIMIT
$TRACE"
claude_says 1 ""
prep
expect "codex at its usage limit and claude unavailable: FAILED, exit non-zero" 4 stderr "FAILED"
no_marker "a usage-limit run records nothing"
[ -e "$S/claude.called" ] && ok "codex's usage limit falls back to claude" || bad "claude fallback not tried"
(cd "$R" && bash "$gate" prepush-accept --reason "codex is out of quota, pushing anyway") >/dev/null 2>"$T/e"; rc=$?
[ "$rc" -eq 2 ] && grep -q "can't be accepted" "$T/e" && ok "a failed review can't be accepted" || bad "failed review accepted rc=$rc"
no_marker "still no marker after a refused accept"

reset_marker
codex_says 0 "$LIMIT
$TRACE" ""
prep
expect "codex exiting 0 with the usage-limit ERROR (and a trailing trace line) is FAILED, not clean" 4 stderr "codex reported: ERROR: You’ve hit your usage limit"
no_marker "an exit-0 usage-limit run records nothing"

reset_marker
codex_says 0 "No findings." "$LIMIT
$TRACE"
prep
expect "an ERROR: line on stderr fails codex even when stdout says No findings." 4 stderr "codex reported"
no_marker "no marker when codex reported an error"

reset_marker
codex_says 0 ""
prep
expect "codex with no final message is FAILED" 4 stderr "codex printed no final message"

reset_marker
codex_says 124 "" ""
claude_says 0 "$(claude_json "No findings.")"
prep
expect "codex timing out falls back to a claude review that can pass" 0 stdout "(claude vs origin/main): No findings."
has_marker "the claude fallback records the marker"
grep -qx -- '-p' "$S/claude.args" && grep -qx -- '--disallowedTools' "$S/claude.args" && grep -qx 'Bash,Edit,Write,MultiEdit,NotebookEdit,WebFetch,WebSearch' "$S/claude.args" &&
  grep -qx 'Read,Glob,Grep' "$S/claude.args" &&
  ok "the claude fallback runs read-only (-p, only Read/Glob/Grep allowed, Bash and edit tools disallowed)" || bad "claude args" "$(cat "$S/claude.args")"
grep -q 'UNIQUE_DIFF_LINE' "$S/claude.stdin" && ok "claude gets the full diff too" || bad "claude prompt lacks diff"
(cd "$R" && bash "$gate" status) >"$T/st" 2>&1
grep -q 'prepush .*green @ .*(claude vs origin/main)' "$T/st" && ok "status names the claude fallback" || bad "status" "$(cat "$T/st")"

reset_marker
codex_says 1 "" "$LIMIT"
claude_says 0 "$(jq -cn '{type:"result",subtype:"success",is_error:true,result:"API Error: 401"}')"
prep
expect "a claude result with is_error is FAILED" 4 stderr "FAILED"
no_marker "no marker after claude is_error"

reset_marker
claude_says 0 "$(jq -cn '{type:"result",subtype:"error_max_turns",is_error:false,result:"No findings."}')"
prep
expect "a claude run cut off at max turns is FAILED" 4 stderr "no successful result"
no_marker "no marker after max turns"

reset_marker
claude_says 1 "$(claude_json "No findings.")"
prep
expect "a claude exit code other than 0 is FAILED even with a clean result" 4 stderr "claude exited 1"
no_marker "no marker after claude exit 1"

reset_marker
codex_says 1 "- [P1] Seen before the error — a.sh:1" "$LIMIT"
claude_says 0 "$(claude_json "No findings.")"
prep
expect "findings Codex printed before failing still block, even when the fallback is clean" 1 stdout "[P1] Seen before the error"
no_marker "no marker when a failed codex run had findings"

# A later review of the same commit replaces the earlier one (its findings can't hide behind an old pass).
reset_marker; codex_says 0 "No findings."; prep >/dev/null
codex_says 0 "- [P1] found on the second look — a.sh:1"; prep
expect "a re-review with blockers fails" 1 stdout "found on the second look"
no_marker "a re-review with blockers removes the earlier pass of the same commit"
(cd "$R" && bash "$gate" check-prepush) 2>/dev/null; rc=$?
[ "$rc" -eq 1 ] && ok "check-prepush fails after the re-review found blockers" || bad "old pass still counts rc=$rc"

# A failed Codex run with a good finding and a malformed tagged line: no fallback can clear it.
reset_marker
codex_says 1 "- [P1] a good finding — a.sh:1
**[P2]** malformed — b.sh:2" "$LIMIT"
claude_says 0 "$(claude_json "No findings.")"
prep
expect "a failed codex run with an unreadable [Pn] line is FAILED even when claude is clean" 4 stderr "not in the finding format"
has "$err" "[P1] a good finding" && ok "its readable findings are still printed" || bad "good finding not printed" "$err"
no_marker "no marker when failed codex output had an unreadable finding"
claude_says 1 ""
reset_marker
codex_says 1 "- [P1 cut off by the error" "$LIMIT"
claude_says 0 "$(claude_json "No findings.")"
prep
expect "a failed codex run with a cut-off [P1 tag is FAILED even when claude is clean" 4 stderr "not in the finding format"
no_marker "no marker when failed codex output had a cut-off tag"
claude_says 1 ""
reset_marker
codex_says 0 "- [P2] Detect truncated tags — review-gate:358
  When Codex prints a truncated tag such as \`[P1\`, or quotes \`[P2]\`, it is only a quote."
prep
expect "tags quoted in a code span inside an explanation are quotes, not findings" 1 stdout "1 finding(s), 1 of them P0-P2"

# ── the verdict must be readable ──
for v in "\`[P1]\` hidden in a code span — a.sh:1" "**[P1]** bold tag — a.sh:1" "1. [P1] numbered — a.sh:1" "- [P1] two — a.sh:1 [P2] tags on one line" "- [p1] lower case tag — a.sh:1"; do
  reset_marker; codex_says 0 "$v"
  prep
  expect "an unreadable tagged line fails the review: $v" 4 stderr "not in the finding format"
  no_marker "no marker for: $v"
done
reset_marker; codex_says 0 "- [P3] a nit — a.sh:1
- [P1 cut off here"
prep
expect "a cut-off tag after a valid finding fails the review (not a P3-only pass)" 4 stderr "not in the finding format"
no_marker "no marker for a cut-off tag"
reset_marker; codex_says 0 "Looks good to me."
prep
expect "a free-form answer is neither findings nor No findings. (FAILED)" 4 stderr "neither [Pn] findings"
reset_marker; codex_says 0 "One P1 issue in the lease code, otherwise fine.
No findings."
prep
expect "No findings. that mentions a P1 is contradictory (FAILED)" 4 stderr "mentions a P0-P3"
reset_marker; codex_says 0 "No findings. But see below.
- [P2] actually a finding — a.sh:2"
prep
expect "a finding after a No findings. line still counts as a finding" 1 stdout "[P2] actually a finding"

reset_marker
codex_says 0 "No findings."
claude_says 1 ""
out="$(cd "$R" && REVIEW_GATE_PREPUSH_TIMEOUT=1 STUB_SLEEP=5 bash "$gate" prepush 2>"$T/err")"; rc=$?; err="$(cat "$T/err")"
expect "a codex run past the time limit is not a pass (claude fallback unavailable here)" 4 stderr "codex exited 124"
no_marker "no marker after a timed-out codex"

# One prepush at a time per worktree, raced for real: two runs started together, exactly one reviews.
gd="$(git -C "$R" rev-parse --absolute-git-dir)"
race() { # race → r1, r2 exit codes of two concurrent prepush runs (codex takes 2s)
  reset_marker; codex_says 0 "No findings."
  (cd "$R" && STUB_SLEEP=2 bash "$gate" prepush >/dev/null 2>&1; echo $? >"$T/r1") &
  (cd "$R" && STUB_SLEEP=2 bash "$gate" prepush >/dev/null 2>&1; echo $? >"$T/r2") &
  wait; r1="$(cat "$T/r1")"; r2="$(cat "$T/r2")"
}
race
[ "$(printf '%s\n' "$r1" "$r2" | sort | tr '\n' ' ')" = "0 5 " ] && ok "two concurrent prepush runs: one reviews, the other is refused (exit 5)" || bad "concurrent runs: $r1 $r2"
if command -v flock >/dev/null 2>&1; then
  ( exec 9>>"$gd/review-gate/prepush.lock"; flock 9; sleep 3 ) & holder=$!; sleep 0.5
  (cd "$R" && bash "$gate" prepush-accept --reason "racing an ongoing review here") >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 5 ] && ok "prepush-accept waits for the lock too" || bad "accept during lock rc=$rc"
  wait "$holder"
fi
export REVIEW_GATE_NO_FLOCK=1   # the fallback lock (no flock, e.g. macOS)
race
[ "$(printf '%s\n' "$r1" "$r2" | sort | tr '\n' ' ')" = "0 5 " ] && ok "fallback lock: two concurrent runs, one refused" || bad "fallback concurrent runs: $r1 $r2"

reset_marker; mkdir -p "$gd/review-gate"; ln -s 999999 "$gd/review-gate/prepush.lock.pid"
prep
expect "fallback lock: a lock left by a dead process is taken over" 0 stdout "No findings."
[ ! -e "$gd/review-gate/prepush.lock.pid" ] && ok "fallback lock: released after the run" || bad "fallback lock left behind"
ln -s 999999 "$gd/review-gate/prepush.lock.pid"
rm -f "$gd/review-gate/prepush.lock.pid"; ln -s 999999 "$gd/review-gate/prepush.lock.pid"
(cd "$R" && STUB_SLEEP=2 bash "$gate" prepush >/dev/null 2>&1; echo $? >"$T/r1") &
(cd "$R" && STUB_SLEEP=2 bash "$gate" prepush >/dev/null 2>&1; echo $? >"$T/r2") &
wait; r1="$(cat "$T/r1")"; r2="$(cat "$T/r2")"
[ "$(printf '%s\n' "$r1" "$r2" | sort | tr '\n' ' ')" = "0 5 " ] && ok "fallback lock: two runs taking over the same dead lock, one refused" || bad "concurrent takeover: $r1 $r2"
ln -s $$ "$gd/review-gate/prepush.lock.pid"
prep
expect "fallback lock: a live owner refuses the run" 5 stderr "another prepush"
rm -f "$gd/review-gate/prepush.lock.pid"; unset REVIEW_GATE_NO_FLOCK

# ── base, empty diff, record ──
reset_marker; codex_says 0 "No findings."
git -C "$R" update-ref refs/remotes/origin/feat/base "$(git -C "$R" rev-parse HEAD~1)"
printf '#!/bin/sh\necho feat/base\n' >"$S/bin/basegh"; chmod +x "$S/bin/basegh"
out="$(cd "$R" && REVIEW_GATE_GH="$S/bin/basegh" bash "$gate" prepush 2>"$T/err")"; rc=$?; err="$(cat "$T/err")"
expect "the default base is the PR's base when gh can tell" 0 stdout "vs origin/feat/base"
reset_marker
prep --base HEAD
expect "an empty diff is not a review (FAILED)" 4 stderr "nothing to review"
no_marker "no marker for an empty diff"
prep --base nosuchref
expect "an unknown --base is refused" 2 stderr "is not a commit"
(cd "$R" && bash "$gate" record prepush) >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "\`record prepush\` is refused (only prepush/prepush-accept write it)" || bad "record prepush rc=$rc"

# ── check requires the pre-push review ──
reset_marker
(cd "$R" && bash "$gate" record kodus >/dev/null && bash "$gate" record coderabbit >/dev/null)
(cd "$R" && bash "$gate" check) 2>"$T/e"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'no pre-push review for this commit' "$T/e" && ok "check requires a prepush marker even with two passes" || bad "check without prepush rc=$rc" "$(cat "$T/e")"
codex_says 0 "No findings."; prep >/dev/null
(cd "$R" && bash "$gate" check) 2>"$T/e"; rc=$?
[ "$rc" -eq 0 ] && ok "check passes once the pre-push review passed" || bad "check with prepush rc=$rc" "$(cat "$T/e")"
reset_marker
(cd "$R" && bash "$gate" record kodus >/dev/null && bash "$gate" record coderabbit >/dev/null)
codex_says 0 "- [P2] a real one — a.sh:1"; prep
(cd "$R" && bash "$gate" prepush-accept --reason "out of scope for this PR, tracked in #99") >/dev/null 2>&1
(cd "$R" && bash "$gate" check) 2>"$T/e"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'ACCEPTED, not fixed' "$T/e" && ok "check passes on accepted findings and announces them" || bad "check accepted rc=$rc" "$(cat "$T/e")"

# ══ the hook: git push ══
run() { # run <cwd> <command> → rc, out, err
  local payload; payload="$(jq -cn --arg c "$2" --arg d "$1" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')"
  out="$(printf '%s' "$payload" | bash "$hook" 2>"$T/err")"; rc=$?; err="$(cat "$T/err")"
}
H="$T/h"; mkrepo "$H"; mkdir -p "$T/elsewhere" "$T/plain"
CRED="git -c credential.helper= -c credential.helper='!f(){ echo username=x-access-token; echo \"password=\$(gh auth token --user job-bot-ai)\"; }; f' push -q -u origin HEAD"
blocked_forms=(
  "git push"
  "git push -u origin HEAD"
  "$CRED"
  "git -C $H push origin HEAD"
  "cd $H && git push -q origin HEAD"
  "/usr/bin/git push"
  "timeout 60 git push"
  "env GIT_TERMINAL_PROMPT=0 git push"
  "GIT_TERMINAL_PROMPT=0 git push"
  "sudo -uroot git push"
  "bash -c 'git push origin HEAD'"
  "echo HEAD | xargs git push origin"
  "true && git push --force-with-lease origin HEAD:feat/x"
  "git push origin +HEAD:refs/heads/feat/x"
  "git push --follow-tags origin HEAD"
  "ssh host 'git push'"
  "REVIEW_GATE_PREPUSH=off git push"
)
for c in "${blocked_forms[@]}"; do
  wd="$H"; case "$c" in "git -C"*|"cd "*) wd="$T/elsewhere";; esac
  run "$wd" "$c"
  expect "unreviewed push is blocked: $c" 2 stderr "BLOCKED by the pre-push review gate"
done
run "$H" "git push"
has "$err" "prepush" && has "$err" "prepush-accept --reason" && ok "the block message says what to run and how to accept findings" || bad "block message" "$err"
has "$err" "REVIEW_GATE_PREPUSH" && bad "the block message must not suggest the escape hatch" "$err" || ok "the block message never mentions the escape hatch"

R="$H"; codex_says 0 "No findings."; prep >/dev/null
for c in "${blocked_forms[@]}"; do
  wd="$H"; case "$c" in "git -C"*|"cd "*) wd="$T/elsewhere";; esac
  run "$wd" "$c"
  expect "reviewed push is allowed: $c" 0
done

run "$H" "git commit -q --allow-empty -m wip && git push"
expect "a commit in the same command as the push is blocked (it can't have been reviewed)" 2 stderr "\`git commit\` runs before \`git push\`"
git -C "$H" branch -q feat/other HEAD~1
run "$H" "git push origin feat/other"
expect "pushing another, unreviewed branch is blocked (its own commit is checked)" 2 stderr "@ $(git -C "$H" rev-parse --short=12 feat/other)"
run "$H" "git push origin feat/other:feat/x"
expect "src:dst checks the src commit" 2 stderr "BLOCKED by the pre-push review gate"
run "$H" "git push --all origin"
expect "git push --all is blocked (every branch at once)" 2 stderr "every branch at once"
run "$H" "git push origin 'refs/heads/*:refs/heads/*'"
expect "a wildcard refspec is blocked" 2 stderr "several branches"
run "$H" "git push origin \"\$BR\""
expect "a non-literal refspec is blocked" 2 stderr "non-literal"
run "$H" "git push \$FLAGS"
expect "a non-literal word in the remote position is blocked (it could be --all, a refspec, ...)" 2 stderr "non-literal argument"
run "$H" "git \$SUB origin HEAD; echo push"
expect "a non-literal git subcommand in a command that mentions push is blocked" 2 stderr "non-literal subcommand"
run "$H" "GIT_DIR=/x/.git git push"
expect "GIT_DIR pointing elsewhere is blocked" 2 stderr "names another repository"
run "$H" "cd \$X && git push"
expect "a push after a non-literal cd is blocked" 2 stderr "isn't a literal path"
run "$T/elsewhere" "git -C \$X push"
expect "git -C with a non-literal directory is blocked" 2 stderr "isn't a literal path"

git -C "$H" commit -q --allow-empty -m "unreviewed"
git -C "$H" tag v1
for c in "git push --delete origin feat/old" "git push -d origin feat/old" "git push origin :feat/old" "git push --tags" "git push origin --tags" \
         "git push origin tag v1" "git push origin refs/tags/v1" "git push origin HEAD:refs/tags/v2" "git push origin v1" "git push --dry-run" "git push -n origin HEAD" "git push --help" \
         "git log --grep push" "grep -rn 'git push' ." "echo git push" "git commit --allow-empty -q -m 'fix git push'" "cd $T/plain && git push"; do
  run "$H" "$c"
  expect "not a branch push, allowed without a review: $c" 0
done
run "$H" "git push -n --no-dry-run origin HEAD"
expect "--no-dry-run after -n publishes (gated)" 2 stderr "BLOCKED by the pre-push review gate"
run "$H" "git push --delete --no-delete origin HEAD"
expect "--no-delete after --delete publishes (gated)" 2 stderr "BLOCKED by the pre-push review gate"
git -C "$H" reset -q --hard HEAD~1

# Config and environment that change what a push publishes or which repo it acts on.
run "$H" "export GIT_DIR=$H/.git; git push origin HEAD"
expect "an exported GIT_DIR before the push is blocked" 2 stderr "names another repository"
run "$H" "git -c push.default=matching push"
expect "a bare push under -c push.default=matching is blocked" 2 stderr "push.default=matching"
run "$H" "GIT_DIR=$H/.git bash -c 'git push origin HEAD'"
expect "a prefix GIT_DIR reaches a git push inside bash -c" 2 stderr "names another repository"
run "$H" "env GIT_DIR=$H/.git bash -c 'git push origin HEAD'"
expect "an env-runner GIT_DIR reaches a git push inside bash -c" 2 stderr "names another repository"
mkrepo "$T/o"
run "$H" "python3 -c 'import os; os.system(\"git push\")'; cd $T/o && python3 -c 'import os; os.system(\"git push\")'"
expect "every opaque push is checked, not just the first" 2 stderr "$T/o @"
printf '[push]\n\tdefault = matching\n' >"$T/cfg"
run "$H" "GIT_CONFIG_GLOBAL=$T/cfg git push"
expect "a GIT_CONFIG_GLOBAL prefix is blocked (its config is invisible to the gate)" 2 stderr "injects git config"
run "$H" "export GIT_CONFIG_SYSTEM=$T/cfg; git push"
expect "an exported GIT_CONFIG_SYSTEM is blocked" 2 stderr "injects git config"
run "$H" "HOME=$T git push"
expect "a HOME prefix (moves the global config) is blocked" 2 stderr "injects git config"
run "$H" "git update-ref refs/heads/feat/other HEAD && git push origin feat/other"
expect "a ref changed by update-ref before the push is blocked" 2 stderr "\`git update-ref\` runs before"
run "$H" "git branch -f feat/other HEAD && git push origin feat/other"
expect "a branch moved by branch -f before the push is blocked" 2 stderr "\`git branch\` runs before"
run "$H" "git branch --show-current && git status && git push origin HEAD"
expect "read-only git commands before the push don't block it (reviewed → allowed)" 0
git -C "$T/o" config alias.p push
run "$H" "cd $T/o && git p origin HEAD"
expect "an alias that pushes, defined only in the checkout git runs in, is blocked" 2 stderr "is an alias that pushes"
run "$H" "git status"
expect "a plain git command is not a push" 0
[ -z "$out$err" ] && ok "a plain git command passes silently" || bad "git status printed: $out$err"
git -C "$H" branch -q -f feat/old-reviewed HEAD
git -C "$H" checkout -q -b feat/unrev && git -C "$H" commit -q --allow-empty -m unreviewed-on-branch
(cd "$H" && git checkout -q feat/old-reviewed && git checkout -q feat/unrev)
gdH="$(git -C "$H" rev-parse --absolute-git-dir)"; cp "$gdH/review-gate/prepush" "$T/pp.bak"
printf '%s feat/old-reviewed 2026-11-11T00:00:00Z pass origin/main codex\n' "$(git -C "$H" rev-parse feat/old-reviewed)" >"$gdH/review-gate/prepush"
run "$H" "git checkout -q -B feat/old-reviewed && git push origin feat/old-reviewed"
expect "checkout -B resets a reviewed branch to an unreviewed HEAD: the push is blocked" 2 stderr "\`git checkout\` runs before \`git push\`"
run "$H" "git switch -q -C feat/old-reviewed && git push origin feat/old-reviewed"
expect "switch -C before the push is blocked too" 2 stderr "\`git switch\` runs before \`git push\`"
git -C "$H" checkout -q feat/x && git -C "$H" branch -q -D feat/unrev feat/old-reviewed; cp "$T/pp.bak" "$gdH/review-gate/prepush"
run "$H" "git config remote.origin.push refs/heads/feat/other && git push"
expect "a git config write before the push is blocked (the gate reads the old config)" 2 stderr "\`git config\` runs before \`git push\`"
run "$H" "git config --get remote.origin.url; git push origin HEAD"
expect "a git config read before the push doesn't block it (reviewed → allowed)" 0
run "$H" "git -c submodule.recurse=true push origin HEAD"
expect "-c submodule.recurse=true (on-demand submodule push) is blocked" 2 stderr "submodule commits"
git -C "$H" config submodule.recurse true
run "$H" "git push origin HEAD"
expect "submodule.recurse=true in config is blocked" 2 stderr "submodule commits"
run "$H" "git -c push.recurseSubmodules=check push origin HEAD"
expect "push.recurseSubmodules=check overrides submodule.recurse (reviewed → allowed)" 0
git -C "$H" config --unset submodule.recurse
git -C "$H" commit -q --allow-empty -m "unreviewed for the escape test"
run "$H" "printf 'true\\ngit push origin HEAD\\n' | bash"
expect "a git push after a \\n escape piped to bash reaches the gate" 2 stderr "BLOCKED by the pre-push review gate"
git -C "$H" reset -q --hard HEAD~1
run "$H" "git fetch -q origin && git push origin origin/main:feat/x"
expect "a fetch before the push is blocked (it can move what the push publishes)" 2 stderr "\`git fetch\` runs before \`git push\`"
run "$H" "git commit -q --allow-empty -m x; python3 -c 'import os; os.system(\"git push\")'"
expect "a commit before an opaque push is blocked" 2 stderr "\`git commit\` runs before \`git push\`"
run "$H" "git -c alias.a=p -c alias.p=push a origin HEAD"
expect "an alias chain that ends in push is blocked" 2 stderr "a -> p -> push"
run "$H" "git -c alias.a=a a"
expect "an alias loop is blocked" 2 stderr "alias loop"
run "$H" "git config alias.p2 push; git p2 origin HEAD"
expect "an alias used after a git config in the same command is blocked" 2 stderr "after a \`git config\`"
run "$H" "git -c submodule.recurse push origin HEAD"
expect "a valueless -c submodule.recurse (true) is blocked" 2 stderr "submodule commits"
run "$H" "MODE=on-demand git --config-env=push.recurseSubmodules=MODE push origin HEAD"
expect "--config-env (unreadable override) is blocked even with a refspec" 2 stderr "config override the gate can't read"
run "$H" "git push --al origin"
expect "an abbreviated long option (--al = --all) is refused" 2 stderr "spell it out in full"
run "$H" "git push --recurse-submodule=on-demand origin HEAD"
expect "an abbreviated --recurse-submodule=on-demand is refused" 2 stderr "spell it out in full"
run "$H" "git push -x origin HEAD"
expect "an unknown short option is refused" 2 stderr "isn't an option the gate knows"
run "$H" "git push --force-with-lease -u origin HEAD"
expect "known long and short options pass (reviewed → allowed)" 0
run "$H" "git show -s --format=%H --output=.git/HEAD HEAD~1 && git push origin HEAD"
expect "a read-only command with --output (writes a file) before the push is blocked" 2 stderr "\`git show\` runs before \`git push\`"
run "$H" "git -c diff.external=true diff && git push origin HEAD"
expect "a read-only command with a -c override before the push is blocked" 2 stderr "\`git diff\` runs before \`git push\`"
run "$H" "GIT_EXTERNAL_DIFF=true git diff && git push origin HEAD"
expect "a read-only command with an env prefix before the push is blocked" 2 stderr "\`git diff\` runs before \`git push\`"
run "$H" "git -c alias.p=push p origin HEAD"
expect "a -c alias that pushes is blocked" 2 stderr "is an alias that pushes"
git -C "$H" config alias.pu "push --force"
run "$H" "git pu origin HEAD"
expect "a configured alias that pushes is blocked" 2 stderr "is an alias that pushes"
git -C "$H" config --unset alias.pu
run "$H" "git push --recurse-submodules=on-demand origin HEAD"
expect "--recurse-submodules=on-demand is blocked (submodule commits weren't reviewed)" 2 stderr "submodule commits"
run "$H" "git push --recurse-submodules=check origin HEAD"
expect "--recurse-submodules=check only checks (reviewed → allowed)" 0
git -C "$H" config push.recurseSubmodules on-demand
run "$H" "git push origin HEAD"
expect "push.recurseSubmodules=on-demand in config is blocked" 2 stderr "submodule commits"
git -C "$H" config --unset push.recurseSubmodules
git -C "$H" config remote.origin.push 'refs/heads/feat/other:refs/heads/feat/other'
run "$H" "git push"
expect "a bare push with configured remote push refspecs is blocked" 2 stderr "configured remote push refspecs"
run "$H" "git push origin HEAD"
expect "naming the refspec checks just that commit (reviewed → allowed)" 0
git -C "$H" config --unset remote.origin.push
git -C "$H" tag v0 HEAD~1
run "$H" "git push origin refs/tags/v0:refs/heads/release"
expect "a tag pushed to a branch is checked like a branch push" 2 stderr "@ $(git -C "$H" rev-parse --short=12 HEAD~1)"
run "$H" "git push origin v0:release"
expect "a short tag name pushed to a branch is checked too" 2 stderr "BLOCKED by the pre-push review gate"

# A branch checked out in another worktree: its markers live there.
git -C "$H" worktree add -q -b feat/wt "$T/h-wt" HEAD
printf 'x\n' >"$T/h-wt/g.txt" && git -C "$T/h-wt" add g.txt && git -C "$T/h-wt" commit -q -m wt
run "$H" "git push origin feat/wt"
expect "a branch from another worktree without a review is blocked" 2 stderr "$T/h-wt"
R="$T/h-wt"; prep >/dev/null
run "$H" "git push origin feat/wt"
expect "a branch reviewed in its own worktree is allowed" 0

# Accepted findings: the push goes through, announced.
git -C "$H" commit -q --allow-empty -m "accepted one"
printf 'more\n' >>"$H/f.txt" && git -C "$H" commit -q -am more
R="$H"; codex_says 0 "- [P1] declined finding — f.txt:2"; prep >/dev/null
(cd "$H" && bash "$gate" prepush-accept --reason "intentional, documented in the README") >/dev/null 2>&1
run "$H" "git push"
expect "a push of a commit with accepted findings is allowed and announced" 0 stdout "ACCEPTED, not fixed"

# Escape hatch: only Claude Code's own environment, and it is logged.
git -C "$H" commit -q --allow-empty -m "unreviewed again"
payload="$(jq -cn --arg c "git push" --arg d "$H" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')"
out="$(printf '%s' "$payload" | REVIEW_GATE_PREPUSH=off bash "$hook" 2>"$T/err")"; rc=$?; err="$(cat "$T/err")"
expect "REVIEW_GATE_PREPUSH=off in the hook's environment skips the push gate, with a notice" 0 stdout "pre-push gate is OFF"
grep -q "git push" "$T/state/review-gate/prepush-bypass.log" 2>/dev/null && ok "a bypassed push is logged" || bad "bypass not logged"

# The PR gate still runs alongside, and its existing behaviour is unchanged.
run "$H" "git push && gh pr ready"
expect "push + gh pr ready in one command is still blocked by the PR gate" 2 stderr "runs before \`gh pr ready\`"

# Without a working resolver: a risky push blocks, a plain one is checked at the session cwd.
cp -r "$root" "$T/broken" && printf 'process.exit(1)\n' >"$T/broken/hooks/resolve-pr-target.mjs"
payload="$(jq -cn --arg c "cd $H && git push" --arg d "$T/elsewhere" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')"
out="$(printf '%s' "$payload" | bash "$T/broken/hooks/pre-pr-coderabbit-gate.sh" 2>"$T/err")"; rc=$?; err="$(cat "$T/err")"
expect "resolver failure + cd: the push is blocked" 2 stderr "couldn't work out where"
payload="$(jq -cn --arg c "git push" --arg d "$H" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')"
out="$(printf '%s' "$payload" | bash "$T/broken/hooks/pre-pr-coderabbit-gate.sh" 2>"$T/err")"; rc=$?; err="$(cat "$T/err")"
expect "resolver failure, plain push: checked at the session cwd (unreviewed → blocked)" 2 stderr "BLOCKED by the pre-push review gate"
payload="$(jq -cn --arg c "git status" --arg d "$H" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')"
out="$(printf '%s' "$payload" | bash "$T/broken/hooks/pre-pr-coderabbit-gate.sh" 2>"$T/err")"; rc=$?; err="$(cat "$T/err")"
expect "resolver failure: a git command without push is not gated" 0

echo "# pass $pass"; echo "# fail $fail"
[ "$fail" -eq 0 ]
