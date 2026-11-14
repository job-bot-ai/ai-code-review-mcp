#!/usr/bin/env bash
# The pre-push review: `review-gate prepush` (OpenQodex, stubbed by test/stub/openqodex with real-shaped records),
# and githooks/pre-push on real `git push`es to a local bare remote. No network.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
gate="$root/review-gate"
T="$(mktemp -d)" && T="$(cd "$T" && pwd -P)" && [ -n "$T" ] || exit 1
trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export OPENQODEX_HOME="$T/oqhome" REVIEW_GATE_BYPASS_LOG="$T/state/review-gate/prepush-bypass.log"
export REVIEW_GATE_OPENQODEX="$root/test/stub/openqodex" REVIEW_GATE_GH="$root/test/stub/gh"
export REVIEW_GATE_OPENQODEX_MEMORY=off PUNCH_FIXTURE="$T/punch" STUB_OQ_ARGS="$T/oq-args"
unset GH_TOKEN STUB_OQ PUNCH_FAIL PUNCH_CORRUPT PUNCH_REF REVIEW_GATE_PREPUSH REVIEW_GATE_BLOCK_ON REVIEW_GATE_PUNCH_REPO \
  REVIEW_GATE_OPENQODEX_OFFLINE REVIEW_GATE_OPENQODEX_SWAP REVIEW_GATE_PREPUSH_TIMEOUT REVIEW_GATE_PREPUSH_GRACE \
  REVIEW_GATE_SYSTEMD_RUN STUB_PR_BASE

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1"; echo "       rc=$rc"; echo "       out: $out"; }
# expect <name> <rc> [substring]
expect() { if [ "$rc" -eq "$2" ] && { [ -z "${3:-}" ] || [[ "$out" == *"$3"* ]]; }; then ok "$1"; else bad "$1"; fi; }
prepush() { out="$(cd "$W" && bash "$gate" prepush --base origin/main "$@" 2>&1)"; rc=$?; }
push()    { out="$(cd "$W" && git push "$@" 2>&1)"; rc=$?; }

mkdir -p "$T/punch/review" && printf '# Punch list\n- 1.1 re-read before a write\n' >"$T/punch/review/PUNCH_LIST.md"
git init -q --bare -b main "$T/remote.git"
W="$T/work"; git init -q -b main "$W" && git -C "$W" remote add origin "$T/remote.git"
git -C "$W" commit -q --allow-empty -m init && git -C "$W" push -q origin main
git -C "$W" config core.hooksPath "$root/githooks"
git -C "$W" switch -q -c feat
change() { echo "$1" >>"$W/f.txt"; git -C "$W" add f.txt && git -C "$W" commit -q -m "$1"; }
change one

# ── passed ──
GH_TOKEN=secret-should-not-leak GITHUB_TOKEN=also-secret prepush
expect "a passing review records a pass" 0 "pre-push review passed"
grep -q '^GH_TOKEN=$' "$T/oq-env" && grep -q '^GITHUB_TOKEN=$' "$T/oq-env"; rc=$?
expect "no GitHub token reaches OpenQodex (GH_TOKEN/GITHUB_TOKEN unset in its environment)" 0
grep -q -- '--offline' "$T/oq-args" && grep -q -- '--reviewer-web off' "$T/oq-args" && grep -q -- '--block-on-severity minor' "$T/oq-args" \
  && ! grep -q -- '--agent' "$T/oq-args" && rc=0 || rc=1
expect "OpenQodex runs offline, without web tools, blocking at minor, never --agent" 0
cfg="$(git -C "$W" rev-parse --git-common-dir)/review-gate-prepush/openqodex.yaml"
grep -q 'block_on_severity: minor' "$W/$cfg" && grep -q '".openqodex/punch-list/PUNCH_LIST.md"' "$W/$cfg"; rc=$?
expect "our config (outside the tree) names the punch-list copy as a convention file" 0
cmp -s "$W/.openqodex/punch-list/PUNCH_LIST.md" "$T/punch/review/PUNCH_LIST.md"; rc=$?
expect "the punch list from main is copied into the git-ignored .openqodex/" 0
[ -z "$(git -C "$W" status --porcelain)" ]; rc=$?
expect "the copy and OpenQodex's report folder leave the tree clean" 0
push -q origin feat
expect "the reviewed commit can be pushed" 0

out="$(cd "$W" && bash "$gate" clear 2>&1)"; rc=$?
expect "review-gate clear runs" 0 "cleared all"
push -q origin HEAD:refs/heads/after-clear
expect "review-gate clear (the reviewer passes) leaves pre-push records alone" 0

# ── only the newest commits reviewed ──
change base-a; push -q --no-verify origin feat; change base-b
out="$(cd "$W" && bash "$gate" prepush --base origin/feat 2>&1)"; rc=$?
push -q origin feat
expect "a review against the branch's own remote tip (not the PR base) doesn't count" 1 "not on origin's default branch or the PR's base"
change base-c   # base-b, HEAD~1 now, was never pushed
out="$(cd "$W" && bash "$gate" prepush --base HEAD~1 2>&1)"; rc=$?
push -q origin feat
expect "a review against an unpushed HEAD~1 doesn't count" 1 "not on origin's default branch or the PR's base"
prepush; push -q origin feat
expect "the whole change against the PR base does" 0
# Another branch the older commits went to is not a base (deep review #26: --base origin/older reviewed one commit).
change base-d; push -q --no-verify origin HEAD~1:refs/heads/older2
out="$(cd "$W" && bash "$gate" prepush --base origin/older2 2>&1)"; rc=$?
push -q origin feat
expect "a review against any other remote branch (not the default branch or the PR's base) doesn't count" 1 "not on origin's default branch or the PR's base"
STUB_PR_BASE=older2 push -q origin feat
expect "the same review counts when that branch is the PR's base (gh pr view)" 0
push -q origin --delete older2 >/dev/null 2>&1
prepush; push -q origin feat

# ── one review at a time ──
mkdir -p "$W/.git/review-gate-prepush"
flock "$W/.git/review-gate-prepush/lock" bash -c "cd '$W' && bash '$gate' prepush --base origin/main" >"$T/lk" 2>&1; rc=$?; out="$(cat "$T/lk")"
expect "a second prepush while one runs is refused" 2 "another prepush/prepush-accept is running"

# ── prepush --wait: block on the lock itself (flock -w), then run or report ──
# Agents hand-rolled `until ! pgrep -f "openqodex review"`, which matches its own shell (#30/#31 stalled ~40 min).
# No wall-clock windows: holders keep the lock until the test lets them go (a gate file), and the waiter is checked
# to be waiting on the lock (its own message) before they do.
lk="$W/.git/review-gate-prepush/lock"
oqn() { wc -l <"$T/oq-args" 2>/dev/null | tr -d ' '; }   # OpenQodex runs so far (the stub logs each one's arguments)
nope() { fail=$((fail + 1)); echo "FAIL - $1"; }
# hold / unhold: another holder of the lock (not a review) until unhold. flock -o: flock alone holds it, so killing
# flock frees it; its sleep (pid in $T/held) goes too.
hold() { rm -f "$T/held"; flock -o "$lk" bash -c 'echo $$ >"$1"; exec sleep 600' _ "$T/held" & holder=$!
  for _ in $(seq 1 100); do [ -s "$T/held" ] && return; sleep 0.1; done; nope "hold never took the lock"; }
unhold() { kill "$holder" "$(cat "$T/held" 2>/dev/null)" 2>/dev/null; wait "$holder" 2>/dev/null; }
# bgrun <env...>: a real prepush in the background (in $BW, default $W) whose OpenQodex waits for $T/gate; returns
# once that OpenQodex has started (so the run holds the lock)
bgrun() { local n; n="$(oqn)"; rm -f "$T/gate"
  (cd "${BW:-$W}" && env STUB_OQ_GATE="$T/gate" "$@" bash "$gate" prepush --base origin/main) >"$T/bg.out" 2>&1 & bg=$!
  for _ in $(seq 1 100); do [ "$(oqn)" != "$n" ] && return; sleep 0.1; done
  nope "the background prepush never started OpenQodex: $(cat "$T/bg.out")"; }
# waitrun [args]: `prepush --wait` in the background; returns once it says it is waiting on the lock
waitrun() { (cd "$W" && bash "$gate" prepush --base origin/main "${@:---wait}") >"$T/w.out" 2>&1 & wp=$!
  for _ in $(seq 1 100); do grep -q "waiting up to" "$T/w.out" 2>/dev/null && return; kill -0 "$wp" 2>/dev/null || break; sleep 0.1; done
  nope "prepush --wait did not wait on the lock: $(cat "$T/w.out")"; }
# waitdone: let the holder (bgrun's review, if any) finish, then collect the waiter's exit code and output
waitdone() { touch "$T/gate"; [ -z "${bg:-}" ] || wait "$bg"; bg=""; wait "$wp"; rc=$?; out="$(cat "$T/w.out")"; }
change wait-1
hold; n0="$(oqn)"; bg=""
waitrun --wait=60; unhold; waitdone
[ "$(oqn)" = $((n0 + 1)) ] || { out="$out (OpenQodex runs: $n0 -> $(oqn))"; rc=98; }
expect "prepush --wait waits on the lock, then reviews (red without the wait: refused at once, exit 2)" 0 "pre-push review passed"
[[ "$out" == *"waiting up to 60s"* && "$out" == *"left no review"* ]] || rc=97
expect "and says it is waiting, and that the holder left no review of HEAD" 0
hold
prepush --wait=1
expect "a wait that runs out exits 6, having reviewed nothing" 6 "stopped waiting"
unhold
ls -a "$W/.git/review-gate-prepush" | grep -q '^\.wait\.' && { rc=96; out="$(ls -a "$W/.git/review-gate-prepush")"; } || rc=0
expect "and leaves no wait marker behind" 0
hold
(cd "$W" && exec bash "$gate" prepush --base origin/main --wait=60) >"$T/w.out" 2>&1 & wp=$!
for _ in $(seq 1 100); do grep -q "waiting up to" "$T/w.out" && break; sleep 0.1; done
kill -TERM "$wp"; wait "$wp"; rc=$?; out="$(cat "$T/w.out")"; unhold
ls -a "$W/.git/review-gate-prepush" | grep -q '^\.wait\.' && rc=96
expect "a wait cancelled by TERM exits 130 and leaves no wait marker behind" 130
prepush --wait=abc
expect "--wait=<not seconds> is a usage error" 2 "whole number of seconds"
prepush --wait=0
expect "--wait=0 is a usage error too" 2 "whole number of seconds"
# The run waited for reviewed HEAD (this worktree, this base): its result is reported, HEAD isn't reviewed twice.
change wait-2
bgrun; n0="$(oqn)"; waitrun; waitdone
[ "$(oqn)" = "$n0" ] || { out="$out (OpenQodex ran again: $n0 -> $(oqn))"; rc=98; }
expect "prepush --wait after another review of HEAD reports its pass, without a second review" 0 "the run waited for reviewed"
push -q origin feat
expect "and that commit can be pushed" 0
change wait-3
bgrun STUB_OQ=blocked; n0="$(oqn)"; waitrun; waitdone
[ "$(oqn)" = "$n0" ] || { out="$out (OpenQodex ran again)"; rc=98; }
expect "a waited-for review that blocked HEAD is reported as blocked (exit 1)" 1 "OpenQodex blocked it"
# Freshness: a record of HEAD from before the wait is not the waited-for run's, so HEAD is reviewed again.
change wait-fresh; prepush
hold; n0="$(oqn)"; bg=""; waitrun; unhold; waitdone
[ "$(oqn)" = $((n0 + 1)) ] || { out="$out (OpenQodex runs: $n0 -> $(oqn))"; rc=98; }
expect "a record of HEAD older than the wait is not reported: --wait reviews again" 0 "left no review"
# A waited-for review that no longer holds (the punch list changed on main while it ran) is reviewed again, even blocked.
change wait-stale
cp "$T/punch/review/PUNCH_LIST.md" "$T/punch0"
bgrun STUB_OQ=blocked; n0="$(oqn)"; waitrun
printf -- '- 1.2 a new item\n' >>"$T/punch/review/PUNCH_LIST.md"
waitdone
cp "$T/punch0" "$T/punch/review/PUNCH_LIST.md"
[ "$(oqn)" = $((n0 + 1)) ] || { out="$out (OpenQodex runs: $n0 -> $(oqn))"; rc=98; }
[[ "$out" == *"no longer holds"* ]] || rc=97
expect "a waited-for blocked review whose punch list changed since is reviewed again, not reported as blocked" 0 "pre-push review passed"
prepush
# HEAD moving while waiting: nothing reviewed.
change wait-move
hold; bg=""; waitrun; change wait-moved; unhold; waitdone
expect "HEAD moving during the wait exits 2, nothing reviewed" 2 "HEAD moved while waiting"
# prepush-accept, refused while a review runs, isn't told to use prepush --wait.
hold
out="$(cd "$W" && bash "$gate" prepush-accept --reason "declined: a reason long enough" 2>&1)"; rc=$?
unhold
[[ "$out" != *"--wait"* ]] || rc=97
expect "prepush-accept refused while the lock is held says to run it again, not prepush --wait" 2 "then run prepush-accept again"
# A waited-for run that failed: its reason may be its own (a dirty tree, another worktree), so HEAD is reviewed here.
change wait-4
bgrun STUB_OQ=incomplete; n0="$(oqn)"; waitrun; waitdone
[ "$(oqn)" = $((n0 + 1)) ] || { out="$out (OpenQodex runs: $n0 -> $(oqn))"; rc=98; }
expect "after a waited-for run of HEAD that failed, --wait reviews HEAD itself" 0 "pre-push review passed"
# Against another base: not this run's review.
change wait-5
bgrun; n0="$(oqn)"
(cd "$W" && bash "$gate" prepush --base origin/feat --wait) >"$T/w.out" 2>&1 & wp=$!
for _ in $(seq 1 100); do grep -q "waiting up to" "$T/w.out" && break; sleep 0.1; done
waitdone
[ "$(oqn)" = $((n0 + 1)) ] || { out="$out (OpenQodex runs: $n0 -> $(oqn))"; rc=98; }
[[ "$out" == *"left no review"* ]] || rc=97
expect "a waited-for review of HEAD against another base doesn't count: --wait reviews against its own" 0 "pre-push review passed"
# Another worktree shares the lock: its review of the same commit is that worktree's, so this one reviews HEAD itself.
git -C "$W" worktree add -q --detach "$T/w2" HEAD
BW="$T/w2" bgrun; n0="$(oqn)"; waitrun; waitdone
[ "$(oqn)" = $((n0 + 1)) ] || { out="$out (OpenQodex runs: $n0 -> $(oqn))"; rc=98; }
expect "after another worktree's review of the same commit, --wait reviews HEAD here" 0 "pre-push review passed"
# And of another commit: the same.
echo wt >>"$T/w2/g.txt" && git -C "$T/w2" add g.txt && git -C "$T/w2" commit -q -m wt
BW="$T/w2" bgrun; n0="$(oqn)"; waitrun; waitdone
[ "$(oqn)" = $((n0 + 1)) ] || { out="$out (OpenQodex runs: $n0 -> $(oqn))"; rc=98; }
expect "after another worktree's review of another commit, --wait reviews HEAD itself" 0 "pre-push review passed"
git -C "$W" worktree remove --force "$T/w2"
prepush

# ── a different commit ──
change two
push -q origin feat
expect "a new commit after the review is blocked" 1 "run \`review-gate prepush\` on that commit"
push -q origin HEAD~1:refs/heads/older
expect "the reviewed (older) commit can still be pushed to another branch" 0
push -q origin HEAD:refs/heads/other
expect "an unreviewed commit is blocked whatever branch it goes to" 1 "BLOCKED by the pre-push review gate"

# ── deletes and tags ──
push -q origin --delete older
expect "a delete is not gated" 0
git -C "$W" tag v1 && push -q origin v1
expect "a tag is not gated" 0
push -q --dry-run origin feat
expect "--dry-run is checked like a push (git runs the hook and doesn't say it's a dry run)" 1 "BLOCKED"

# ── blocked, and prepush-accept ──
prepush; out="$(cd "$W" && bash "$gate" prepush-accept --reason "nothing to accept here, really" 2>&1)"; rc=$?
expect "a passed review has nothing to accept" 2 "nothing to accept"
STUB_OQ=blocked prepush
expect "a blocked review exits 1 and says how to accept" 1 "prepush-accept --reason"
push -q origin feat
expect "a blocked review blocks the push" 1 "OpenQodex blocked it (1 major, 1 minor"
out="$(cd "$W" && bash "$gate" prepush-accept --reason "short" 2>&1)"; rc=$?
expect "prepush-accept needs a real reason" 2 "10+ characters"
out="$(cd "$W" && bash "$gate" prepush-accept --reason "false positive: the input is validated upstream" 2>&1)"; rc=$?
expect "prepush-accept records the reason" 0 "ACCEPTED"
push -q origin feat
expect "accepted findings let the push through, announced" 0 "were ACCEPTED, not fixed"

# ── incomplete, no reviewer, nothing to review: never a pass ──
change three
prepush; STUB_OQ=incomplete prepush
expect "an incomplete review fails (exit 4)" 4 "did not finish"
push -q origin feat
expect "an incomplete review blocks the push, even after an earlier pass of that commit" 1 "did not pass"
out="$(cd "$W" && bash "$gate" prepush-accept --reason "the reviewer timed out, ship it" 2>&1)"; rc=$?
expect "an unfinished review can't be accepted" 2 "unfinished review can't be accepted"
STUB_OQ=noreviewer prepush
expect "no reviewer fails" 4 "never \`openqodex review --agent\`"
push -q origin feat
expect "no reviewer blocks the push" 1 "BLOCKED"
STUB_OQ=nothing prepush
expect "a run that reviewed nothing records nothing" 4 "recorded no review"
STUB_OQ=lie prepush
expect "exit 0 with a blocked verdict is not a pass" 4 "not a finished review"
STUB_OQ=commit prepush
expect "a commit made while the review runs voids it" 4 "changed while the review ran"
git -C "$W" reset -q --hard HEAD~1

# ── the punch list ──
STUB_OQ=omit prepush
expect "a punch-list file OpenQodex skipped (over its cap) fails the review" 4 "not given the whole punch list"
STUB_OQ=badhash prepush
expect "a manifest hash that isn't the list's fails the review" 4 "not given the whole punch list"
PUNCH_FAIL=1 prepush
expect "no punch list, no review" 4 "couldn't list the punch list"
mv "$T/punch/review/PUNCH_LIST.md" "$T/pl"
prepush
expect "a punch list with no file on main is no list" 4 "couldn't list the punch list"
mv "$T/pl" "$T/punch/review/PUNCH_LIST.md"
PUNCH_CORRUPT=1 prepush
expect "a downloaded file that isn't the listed blob is refused" 4 "couldn't download"
STUB_OQ=badreport prepush
expect "a report that isn't the one OpenQodex recorded fails" 4 "doesn't match OpenQodex's record"
prepush
expect "a clean review of the new HEAD" 0
PUNCH_FAIL=1 push -q origin feat
expect "a punch-list fetch failure at push time blocks" 1 "a failed fetch never passes"
printf -- '- 9.9 a new item\n' >>"$T/punch/review/PUNCH_LIST.md"
push -q origin feat
expect "a punch list changed on main since the review blocks (stale hash)" 1 "changed since the review"
prepush && push -q origin feat
expect "reviewed again with the current list: allowed" 0

# ── tampering with the records ──
change four; prepush
m="$(git -C "$W" rev-parse --git-common-dir)/review-gate-prepush/$(git -C "$W" rev-parse HEAD).json"; m="$W/$m"
rd="$(jq -r .run_dir "$m")"
cp "$rd/manifest.json" "$T/man"; jq '.instruction_files[0].sha256 = "0"' "$T/man" >"$rd/manifest.json"
push -q origin feat
expect "a manifest changed after the review blocks" 1 "manifest.json changed"
cp "$T/man" "$rd/manifest.json"; cp "$rd/report.json" "$T/rep"; jq '.verdict = "passed"' "$T/rep" >"$rd/report.json"; printf ' ' >>"$rd/report.json"
push -q origin feat
expect "a report changed after the review blocks" 1 "report.json changed"
cp "$T/rep" "$rd/report.json"
rec="$OPENQODEX_HOME/receipts/$(jq -r .repo_id "$m")/$(jq -r .change_id "$m").json"; mv "$rec" "$T/rec"
push -q origin feat
expect "no OpenQodex receipt blocks" 1 "receipt"
jq '.kind = "incomplete"' "$T/rec" >"$rec"
push -q origin feat
expect "an incomplete receipt blocks" 1 "receipt"
mv "$T/rec" "$rec"
jq '.punch.files[0].sha256 = "0"' "$m" >"$T/m" && cp "$m" "$T/m0" && mv "$T/m" "$m"
push -q origin feat
expect "a record whose punch hashes differ from the manifest blocks" 1 "whole punch list supplied"
cp "$T/m0" "$m"
# forge <jq on report> : edit the report and keep every hash in the record consistent, so only the guard under test fails
forge() {
  cp "$rd/report.json" "$T/rep0"; cp "$m" "$T/m1"; cp "$rec" "$T/rec1"
  jq "$1" "$T/rep0" >"$rd/report.json"
  jq --arg h "$(sha256sum "$rd/report.json" | cut -d' ' -f1)" ".report_sha256 = \$h | ${2:-.}" "$T/m1" >"$m"
  jq "${3:-.}" "$T/rec1" >"$rec"
}
unforge() { cp "$T/rep0" "$rd/report.json"; cp "$T/m1" "$m"; cp "$T/rec1" "$rec"; }
forge '.completion.status = "incomplete"'
push -q origin feat
expect "a report that is not complete blocks, even with every hash consistent" 1 "not a complete review"
unforge
forge '.verdict = "incomplete"' '.verdict = "incomplete"' '.verdict = "incomplete"'
push -q origin feat
expect "any verdict other than passed/blocked blocks" 1 "verdict 'incomplete'"
unforge
other="$(git -C "$W" commit-tree -m unrelated "$(git -C "$W" mktree </dev/null)")"
forge '.' ".base_sha = \"$other\"" ".base.sha = \"$other\""
push -q origin feat
expect "a review against a base that isn't an ancestor blocks" 1 "not an ancestor"
unforge
cp "$m" "$T/m2"; prev="$(git -C "$W" rev-parse HEAD~1)"; pm="${m%/*}/$prev.json"; cp "$m" "$pm"
push -q origin HEAD~1:refs/heads/prev
expect "a record copied to another commit's name blocks" 1 "unreadable record"
rm -f "$pm"
REVIEW_GATE_BLOCK_ON=nitpick push -q origin feat
expect "a review run at a looser block_on_severity than the gate's doesn't count" 1 "block_on_severity"
REVIEW_GATE_BLOCK_ON=critical push -q origin feat
expect "a review run at a stricter block_on_severity than the gate's counts (3.10)" 0
push -q origin feat
expect "the untouched record passes" 0

# A record copied to another commit and edited to name it (deep review #26: one jq command) is not that commit's review.
change forged; reviewed="$(git -C "$W" rev-parse HEAD~1)"; new="$(git -C "$W" rev-parse HEAD)"; pd="${m%/*}"
jq --arg s "$new" '.sha = $s' "$pd/$reviewed.json" >"$pd/$new.json"
push -q origin feat
expect "a record whose .sha was edited to another commit blocks (change id worked out again)" 1 "is not of"
rm -f "$pd/$new.json"; git -C "$W" reset -q --hard HEAD~1

# The change-id formula is OpenQodex 0.18.0's: real runs of it on this repository's own history (PR #26).
real="ea23605fbddb58e31fdfb69a5379725caa87fa6f a0d7dc15ae0b1becf26ca9069dbb6398fa73563c 09cf59aa1de46ed069447e9280100790bef45ec76fa67e66700c185f9278cab6
ea23605fbddb58e31fdfb69a5379725caa87fa6f 0cdd8f86f713054094deb9f97c3660a8643e0802 815c45560241525a2752ce5eba5f82083faa3a9697604c86e763211136ba0f2d
ea23605fbddb58e31fdfb69a5379725caa87fa6f cf1ee35b577028df0f8642fbf3ef019b062a24b6 68a6ddba2a22c1819156338b5c59be8e0537fee75fafcc85f883ee6441a431bb"
while read -r rb rh rid; do
  if git -C "$root" cat-file -e "$rh^{commit}" 2>/dev/null && git -C "$root" cat-file -e "$rb^{commit}" 2>/dev/null; then
    out="$(cd "$root" && bash "$gate" change-id "$rb" "$rh" 2>&1)"; [ "$out" = "$rid" ]; rc=$?
    expect "change id of ${rh:0:7} matches a real OpenQodex 0.18.0 run" 0
  else echo "skip - ${rh:0:7} is not in this clone (real-run change id check)"; fi
done <<<"$real"
STUB_OQ=wrongid prepush
expect "a review OpenQodex recorded under another change id than the commit's fails at once" 4 "change id"

# ── punch-list folder layout ──
mkdir -p "$T/punch/review/punch-list"
printf 'a\n' >"$T/punch/review/punch-list/01-check.md"; printf 'b\n' >"$T/punch/review/punch-list/02-errors.md"
printf 'log\n' >"$T/punch/review/punch-list/log.md"
change five; prepush
expect "the folder layout is reviewed" 0
grep -q '01-check.md' "$W/$cfg" && grep -q '02-errors.md' "$W/$cfg" && ! grep -q 'log.md' "$W/$cfg" && ! grep -q PUNCH_LIST "$W/$cfg"; rc=$?
expect "punch-list/NN-*.md go to the reviewer, log.md and PUNCH_LIST.md don't" 0
push -q origin feat
expect "and the push passes" 0
printf 'c\n' >"$T/punch/review/punch-list/03-new.md"
push -q origin HEAD:refs/heads/again
expect "a new section file on main makes the review stale" 1 "changed since the review"
rm -f "$T/punch/review/punch-list/03-new.md"

# ── dirty tree, the cap, the switch, failures, chaining ──
echo dirty >>"$W/f.txt"
prepush
expect "a dirty tree is not reviewed" 4 "not clean"
git -C "$W" checkout -q f.txt
mkdir -p "$T/bin"; printf '#!/bin/sh\necho "$@" >>"%s"\nwhile [ "$1" != -- ]; do shift; done; shift; exec "$@"\n' "$T/sdrun" >"$T/bin/systemd-run"
chmod +x "$T/bin/systemd-run"
change six
REVIEW_GATE_SYSTEMD_RUN="$T/bin/systemd-run" REVIEW_GATE_OPENQODEX_MEMORY=1G prepush
grep -q -- '--scope' "$T/sdrun" && grep -q 'MemoryMax=1G' "$T/sdrun" && grep -q 'MemorySwapMax=' "$T/sdrun" && [ "$rc" = 0 ]; rc=$?
expect "the review runs in a systemd scope with a memory cap" 0
change seven
REVIEW_GATE_PREPUSH=off push -q origin feat
expect "REVIEW_GATE_PREPUSH=off lets an unreviewed push through, announced" 0 "pre-push gate is OFF"
grep -q 'git-hook' "$REVIEW_GATE_BYPASS_LOG"; rc=$?
expect "and the bypass is logged" 0
: >"$T/notadir"
REVIEW_GATE_BYPASS_LOG="$T/notadir/x.log" REVIEW_GATE_PREPUSH=off push -q origin HEAD:refs/heads/unlogged
expect "the switch doesn't work when the bypass can't be logged" 1 "can't be logged"
# The default log path (review of 824e18c): never from HOME/XDG_STATE_HOME, and the git hook takes it from review-gate.
want="$(getent passwd "$(id -un)" | cut -d: -f6)/.local/state/review-gate/prepush-bypass.log"
out="$(cd "$T" && env -u REVIEW_GATE_BYPASS_LOG HOME="$T/h" XDG_STATE_HOME="$T/x" bash "$gate" bypass-log 2>&1)"; rc=$?
[ "$out" = "$want" ] || rc=9
expect "review-gate bypass-log: <passwd home>/.local/state/review-gate/prepush-bypass.log, whatever HOME/XDG_STATE_HOME say" 0
mkdir -p "$T/sg/githooks" && cp "$root/githooks/pre-push" "$T/sg/githooks/"
printf '#!/bin/sh\n[ "$1" = bypass-log ] && { echo "%s"; exit 0; }\nexit 1\n' "$T/sg-log" >"$T/sg/review-gate"
git -C "$W" config core.hooksPath "$T/sg/githooks"
out="$(cd "$W" && env -u REVIEW_GATE_BYPASS_LOG HOME="$T/h" XDG_STATE_HOME="$T/x" REVIEW_GATE_PREPUSH=off git push -q origin HEAD:refs/heads/sg 2>&1)"; rc=$?
grep -q 'git-hook' "$T/sg-log" 2>/dev/null && [ ! -e "$T/x" ] || rc=9
expect "the git hook logs a bypass where review-gate bypass-log says, not under XDG_STATE_HOME" 0
git -C "$W" config core.hooksPath "$root/githooks"; git -C "$W" push -q --no-verify origin --delete sg >/dev/null 2>&1
mkdir -p "$T/broken/githooks" && cp "$root/githooks/pre-push" "$T/broken/githooks/"
printf '#!/bin/sh\nexit 7\n' >"$T/broken/review-gate"
change eight; prepush
git -C "$W" config core.hooksPath "$T/broken/githooks"
push -q origin feat
expect "an unexpected review-gate exit code blocks (fail closed)" 1 "review-gate exited 7"
git -C "$W" config core.hooksPath "$root/githooks"
own="$W/.git/hooks/pre-push"; printf '#!/bin/sh\necho own-hook-ran >&2\nexit 3\n' >"$own"; chmod +x "$own"
push -q origin feat
expect "the repo's own pre-push hook still runs after the gate passes (and can block)" 1 "own-hook-ran"
printf '#!/bin/sh\nexit 0\n' >"$own"; chmod +x "$own"
push -q origin feat
expect "a repo hook that exits 0 without reading stdin is not a failure" 0
rm -f "$own"
ln -s "$root/githooks/pre-commit" "$W/.git/hooks/pre-commit"
out="$(cd "$W" && timeout 20 git commit -q --allow-empty -m loop 2>&1)"; rc=$?
expect "a repo hook linked back into githooks/ doesn't loop" 0
rm -f "$W/.git/hooks/pre-commit"
[ ! -e "$root/githooks/push-to-checkout" ]; rc=$?
expect "no push-to-checkout link (its presence disables updateInstead)" 0

# ── a PATH prefix (deep review #26): neither the hook nor review-gate runs a look-alike from it ──
mkdir -p "$T/evil"
for t in bash cat readlink sha256sum jq git systemd-run timeout; do printf '#!/bin/sh\necho %s >>"%s"\nexit 0\n' "$t" "$T/evil-ran" >"$T/evil/$t"; chmod +x "$T/evil/$t"; done
change nine
out="$(cd "$W" && PATH="$T/evil:$PATH" /usr/bin/git push -q origin feat 2>&1)"; rc=$?
expect "PATH=<a bash that exits 0>:\$PATH git push still blocks an unreviewed commit" 1 "BLOCKED"
[ ! -e "$T/evil-ran" ]; rc=$?; out="$(cat "$T/evil-ran" 2>/dev/null)"
expect "and nothing from that PATH ran (the hook's #!/bin/bash and fixed PATH)" 0
out="$(cd "$W" && PATH="$T/evil:$PATH" /bin/bash "$gate" check-prepush 2>&1)"; rc=$?
[ ! -e "$T/evil-ran" ] || rc=9
expect "review-gate itself ignores PATH (its fixed PATH)" 1 "run \`review-gate prepush\`"
# bash's own startup inputs (review of 97a58fa): #!/bin/bash -p and /bin/bash -p for review-gate ignore them.
printf 'exit 0\n' >"$T/benv.sh"
out="$(cd "$W" && BASH_ENV="$T/benv.sh" git push -q origin feat 2>&1)"; rc=$?
expect "BASH_ENV=<a file that exits 0> git push still blocks an unreviewed commit" 1 "BLOCKED"
out="$(cd "$W" && cat() { :; } && export -f cat && git push -q origin feat 2>&1)"; rc=$?
expect "an exported cat function (the hook reads no refs) still blocks" 1 "BLOCKED"
out="$(cd "$W" && BASH_ENV="$T/benv.sh" "$gate" check-prepush 2>&1)"; rc=$?
expect "review-gate run directly ignores BASH_ENV (#!/bin/bash -p)" 1 "run \`review-gate prepush\`"
# A record whose only failing check is a jq one (blocked findings, none accepted): an exported jq that passes that
# check would let the push through if review-gate imported it (review of 824e18c).
change jqfn; STUB_OQ=blocked prepush
out="$(cd "$W" && jq() { case "$*" in *accepted*) return 0 ;; esac; command jq "$@"; } && export -f jq && git push -q origin feat 2>&1)"; rc=$?
expect "an exported jq function (one that waives the findings) doesn't reach review-gate" 1 "OpenQodex blocked it"

# ── files under .openqodex/ are outside OpenQodex's review and change id (review of 97a58fa) ──
git -C "$W" reset -q --hard HEAD~1; prepush   # HEAD reviewed again
reviewed="$(git -C "$W" rev-parse HEAD)"; pd="$W/$(git -C "$W" rev-parse --git-common-dir)/review-gate-prepush"
mkdir -p "$W/.openqodex" && echo 'echo unreviewed' >"$W/.openqodex/run.sh"
git -C "$W" add -f .openqodex/run.sh && git -C "$W" commit -q -m state
prepush
expect "prepush refuses a change that commits files under .openqodex/" 4 "files under .openqodex/"
jq --arg s "$(git -C "$W" rev-parse HEAD)" '.sha = $s' "$pd/$reviewed.json" >"$pd/$(git -C "$W" rev-parse HEAD).json"
push -q origin feat
expect "a record moved onto it (same change id) still blocks the push" 1 "files under .openqodex/"
rm -f "$pd/$(git -C "$W" rev-parse HEAD).json"; git -C "$W" reset -q --hard HEAD~1; change nine-again

# ── the punch list must fit OpenQodex's limits: checked before the review (deep review #26) ──
mkdir -p "$T/punch-big/review"; head -c 33000 /dev/zero | tr '\0' 'x' >"$T/punch-big/review/PUNCH_LIST.md"
: >"$T/oq-args"
PUNCH_FIXTURE="$T/punch-big" prepush
expect "a single PUNCH_LIST.md over 32 KB fails at once, naming pr-orchestrator #21" 4 "pr-orchestrator #21"
[ ! -s "$T/oq-args" ]; rc=$?
expect "and OpenQodex never ran" 0
mkdir -p "$T/punch-big/review/punch-list"
for i in 01 02 03; do head -c 22000 /dev/zero | tr '\0' 'y' >"$T/punch-big/review/punch-list/$i-s.md"; done
PUNCH_FIXTURE="$T/punch-big" prepush
expect "sections over 64 KB in all fail at once" 4 "66000 bytes in all"
head -c 40000 /dev/zero | tr '\0' 'y' >"$T/punch-big/review/punch-list/01-s.md"; rm -f "$T/punch-big/review/punch-list/"0[23]-s.md
PUNCH_FIXTURE="$T/punch-big" prepush
expect "one section over 32 KB fails at once" 4 "over 32 KB: 01-s.md (40000 bytes)"
for i in 01 02; do head -c 29000 /dev/zero | tr '\0' 'y' >"$T/punch-big/review/punch-list/$i-s.md"; done
PUNCH_FIXTURE="$T/punch-big" prepush
expect "a list close to the 64 KB cap is reviewed, with a warning" 0 "WARNING: the punch list is 58000 of"

# ── a hung OpenQodex: an outer timeout, and the lock is free again ──
# gone <pid file>: the stub wrote it (this run: each test deletes the old ones first) and that process has ended.
gone() { local p; p="$(cat "$OPENQODEX_HOME/$1" 2>/dev/null)"; [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null; }
fresh() { rm -f "$OPENQODEX_HOME"/orphan*.pid "$OPENQODEX_HOME/stubborn.pid"; }
fresh
STUB_OQ=hang REVIEW_GATE_PREPUSH_TIMEOUT=1 REVIEW_GATE_PREPUSH_GRACE=1 REVIEW_GATE_PREPUSH_KILL_AFTER=1 prepush
expect "an OpenQodex that never returns is stopped (exit 4)" 4 "didn't finish within 2s"
gone orphan.pid; rc=$?
expect "and the detached reviewer it started (in a group of its own) is stopped too (Codex on bf0ade0)" 0
kill "$(cat "$OPENQODEX_HOME/orphan2.pid")" 2>/dev/null   # cleared its environment: only a cgroup holds it (below)
prepush
expect "and the next prepush is not locked out" 0 "pre-push review passed"
# A reviewer that ignores TERM (Codex on 0a62a5e): the watchdog escalates to KILL, and the run ends in bounded time.
s0=$SECONDS
STUB_OQ=stubborn REVIEW_GATE_PREPUSH_TIMEOUT=1 REVIEW_GATE_PREPUSH_GRACE=1 REVIEW_GATE_PREPUSH_KILL_AFTER=1 prepush
[ $((SECONDS - s0)) -le 20 ] || { out="$out (took $((SECONDS - s0))s)"; rc=99; }
expect "an OpenQodex that ignores TERM is killed after the grace (exit 4, well before its own 60 s)" 4 "didn't finish within 2s"
prepush
expect "and the lock is free again" 0 "pre-push review passed"
# The run's group leader itself ignoring TERM (here a systemd-run stand-in): KILL still comes after the grace.
printf '#!/bin/bash\ntrap "" TERM\nwhile [ "$1" != -- ]; do shift; done; shift\n"$@"\n' >"$T/bin/sdrun-stubborn"; chmod +x "$T/bin/sdrun-stubborn"
s0=$SECONDS
STUB_OQ=hang REVIEW_GATE_SYSTEMD_RUN="$T/bin/sdrun-stubborn" REVIEW_GATE_OPENQODEX_MEMORY=1G REVIEW_GATE_PREPUSH_TIMEOUT=1 \
  REVIEW_GATE_PREPUSH_GRACE=1 REVIEW_GATE_PREPUSH_KILL_AFTER=1 prepush
[ $((SECONDS - s0)) -le 20 ] || { out="$out (took $((SECONDS - s0))s)"; rc=99; }
expect "a group leader that ignores TERM is killed after the grace too" 4 "didn't finish within 2s"
kill "$(cat "$OPENQODEX_HOME/orphan.pid")" "$(cat "$OPENQODEX_HOME/orphan2.pid")" 2>/dev/null
# Under the real memory cap (a systemd scope; skipped where systemd-run can't make one), even a detached reviewer that
# cleared its environment is stopped: the scope's cgroup holds it.
if /usr/bin/systemd-run --scope --quiet --collect -- /bin/true >/dev/null 2>&1; then
  fresh
  REVIEW_GATE_SYSTEMD_RUN=/usr/bin/systemd-run STUB_OQ=hang REVIEW_GATE_OPENQODEX_MEMORY=1G REVIEW_GATE_PREPUSH_TIMEOUT=1 \
    REVIEW_GATE_PREPUSH_GRACE=1 REVIEW_GATE_PREPUSH_KILL_AFTER=1 prepush
  { gone orphan.pid && gone orphan2.pid; } || { out="$out (a detached reviewer is still running)"; rc=99; }
  expect "in a real scope, every detached reviewer (also one that cleared its environment) is stopped" 4 "didn't finish"
  kill "$(cat "$OPENQODEX_HOME/orphan.pid")" "$(cat "$OPENQODEX_HOME/orphan2.pid")" 2>/dev/null
else echo "skip - systemd-run can't make a scope here (real-scope cleanup)"; fi
# Cancelling review-gate (Codex on 078af19): the run is taken down whole, TERM then KILL, before the lock is released.
fresh
( cd "$W" && STUB_OQ=stubborn REVIEW_GATE_PREPUSH_TIMEOUT=600 REVIEW_GATE_PREPUSH_KILL_AFTER=1 exec bash "$gate" prepush --base origin/main ) >"$T/cancel.out" 2>&1 &
gp=$!
for _ in $(seq 1 40); do [ -s "$OPENQODEX_HOME/stubborn.pid" ] && break; sleep 0.5; done
s0=$SECONDS; kill -TERM "$gp"; wait "$gp"; rc=$?; out="$(cat "$T/cancel.out")"
sp="$(cat "$OPENQODEX_HOME/stubborn.pid" 2>/dev/null)"
{ [ -n "$sp" ] && ! kill -0 "$sp" 2>/dev/null && gone orphan3.pid && [ $((SECONDS - s0)) -le 15 ]; } ||
  { out="$out (stub ${sp:-never started} or its detached reviewer still running, or took $((SECONDS - s0))s)"; rc=99; }
expect "TERM to review-gate prepush stops a TERM-ignoring reviewer too (exit 130), before the lock is released" 130
prepush
expect "and the next prepush runs" 0 "pre-push review passed"
# Parts of the run that outlive KILL (stand-in review of dba81db; simulated with the KILL-signal seam set to CONT):
# exit 5 naming them, never a finished run, and the next prepush refuses while they are alive.
fresh
# (Output to a file, not $(...): the survivors keep the pipe open.)
(cd "$W" && STUB_OQ=stubborn REVIEW_GATE_PREPUSH_TIMEOUT=1 REVIEW_GATE_PREPUSH_GRACE=1 REVIEW_GATE_PREPUSH_KILL_AFTER=1 \
  REVIEW_GATE_PREPUSH_KILL_SIGNAL=CONT bash "$gate" prepush --base origin/main) >"$T/sv.out" 2>&1; rc=$?; out="$(cat "$T/sv.out")"
sv="$W/$(git -C "$W" rev-parse --git-common-dir)/review-gate-prepush/survivors"
grep -q "^pid $(cat "$OPENQODEX_HOME/stubborn.pid") " "$sv" 2>/dev/null || rc=98
expect "survivors of KILL: exit 5, named (pid and start time) in the marker, the review not finished" 5 "still running after KILL: pid"
prepush
expect "the next prepush refuses while they are alive" 2 "still running after KILL"
while read -r kind id _; do [ "$kind" = pid ] && kill -9 "$id" 2>/dev/null; done <"$sv"
sleep 1
prepush
expect "once they are gone, prepush runs again (and clears the marker)" 0 "pre-push review passed"
[ ! -e "$sv" ]; rc=$?
expect "the survivors marker is gone" 0
# A zombie in a survivors entry (Greptile on 85f0514): `kill -0` passes and its start time stays, but it is dead and no
# signal clears it, so it never blocks a prepush. (Its parent execs into sleep and never reaps it.)
bash -c 'sleep 0 & echo $! >"$1"; exec sleep 30' _ "$T/zombie.pid" & zparent=$!
for _ in $(seq 1 20); do zp="$(cat "$T/zombie.pid" 2>/dev/null)"; [ -n "$zp" ] && [ "$(sed 's/^.*) //' "/proc/$zp/stat" 2>/dev/null | cut -d' ' -f1)" = Z ] && break; sleep 0.2; done
printf 'pid %s %s\n' "$zp" "$(sed 's/^.*) //' "/proc/$zp/stat" | cut -d' ' -f20)" >"$sv"
change zombie-entry; prepush
expect "a survivors entry that is a zombie doesn't refuse the next prepush" 0 "pre-push review passed"
[ ! -e "$sv" ]; rc=$?
expect "and its marker is cleared" 0
kill "$zparent" 2>/dev/null; wait "$zparent" 2>/dev/null
STUB_OQ=killed prepush
expect "a SIGKILL (the memory cap) is reported as that, naming MemoryMax" 4 "MemoryMax"
fresh; STUB_OQ=leaves prepush
gone orphan4.pid || { out="$out (the detached reviewer is still running)"; rc=99; }
expect "a review that finishes but leaves a detached reviewer running: it is stopped before the lock goes" 0 "stopping processes the review left running"

# ── prepush-accept is logged with the bypasses ──
change ten; STUB_OQ=blocked prepush
REVIEW_GATE_BYPASS_LOG="$T/notadir/x.log" bash -c "cd '$W' && bash '$gate' prepush-accept --reason 'declined: covered by an upstream check'" >"$T/acc" 2>&1; rc=$?; out="$(cat "$T/acc")"
expect "prepush-accept refuses when it can't log the acceptance" 2 "never silent"
push -q origin feat
expect "so the findings still block" 1 "OpenQodex blocked it"
out="$(cd "$W" && XDG_STATE_HOME="$T/q" HOME="$T/q" bash "$gate" prepush-accept --reason "declined: covered by an upstream check" 2>&1)"; rc=$?
grep -q $'\tprepush-accept\t.*declined: covered by an upstream check' "$REVIEW_GATE_BYPASS_LOG" || rc=9
[ ! -e "$T/q" ] || rc=8
expect "prepush-accept writes the acceptance to the bypass log, wherever XDG_STATE_HOME/HOME point" 0 "logged to"

# ── round-aware threshold (pr-orchestrator 3.10): late in a PR only serious findings block ──
pol="$T/punch/review/policy.yaml"
latepol() { printf 'check_name: review-policy\nprepush:\n  openqodex_block_on: minor\n  late:\n    from_round: 5\n    openqodex_block_on: major\n' >"$pol"; }
checks() {   # checks <round> [app]: prorch's check on the PR head
  printf '{"check_runs": [{"name": "review-policy (shadow)", "app": {"slug": "%s"}, "started_at": "2026-11-14T00:00:00Z",
    "output": {"title": "round 0 failed (no pre-push review); round %s/6, waiting on Kodus"}}]}' "${2:-jbot-orchestrator}" "$1"
}
fresh() { git -C "$W" checkout -q -B "$1" origin/main; }   # a branch with no pre-push reviews yet
latepol
export STUB_PR_HEAD=2222222222222222222222222222222222222222
# prorch's round (each case on a fresh branch, so the branch's own count stays below it)
fresh pr5; : >"$T/oq-args"; change late1; STUB_CHECKS="$(checks 5)" STUB_OQ=minoronly prepush
expect "after round 4 (prorch's) a minor finding doesn't block the push" 0 "blocking at major (round 5: late-prorch)"
expect "and the minor finding is listed for the PR's follow-up issue, not dropped" 0 "a rare bug (f.txt:1)"
grep -q -- '--block-on-severity major' "$T/oq-args"; rc=$?
expect "OpenQodex runs at major late in the PR" 0
STUB_CHECKS="$(checks 5)" push -q origin pr5
expect "and the push passes while the PR is late" 0
change late2; STUB_CHECKS="$(checks 3)" STUB_OQ=minoronly prepush
expect "before round 5 a minor finding still blocks" 1 "blocking at minor (round 3: early-prorch)"
STUB_CHECKS="$(checks 5)" push -q origin pr5
expect "a minor-level review that only a minor blocked passes once the PR is late" 0 "minor finding(s) did not block"
change late3; STUB_CHECKS="$(checks 5)" STUB_OQ=minoronly prepush
STUB_CHECKS="$(checks 1)" push -q origin pr5
expect "a review run at major doesn't count once the PR is back below round 5" 1 "the gate uses minor now (round 3)"
fresh ci; change late4; STUB_CHECKS="$(checks 5 some-ci)" STUB_OQ=minoronly prepush
expect "a round from another app's check is ignored" 1 "blocking at minor (round 1: early-local)"
fresh nocheck; change late5; STUB_OQ=minoronly prepush
expect "no prorch check on the PR head: the branch's own count decides" 1 "blocking at minor (round 1: early-local)"
fresh fork; change late5f; STUB_PR_CROSS=1 STUB_CHECKS="$(checks 5)" STUB_OQ=minoronly prepush
expect "a fork's open PR with the same branch name doesn't lower the bar (3.4)" 1 "blocking at minor (round 1: early-local)"
fresh nopr; unset STUB_PR_HEAD; change late6; STUB_CHECKS="$(checks 5)" STUB_OQ=minoronly prepush
expect "no open PR: the branch's own count decides" 1 "blocking at minor (round 1: early-local)"
# the branch's own count (no prorch round), under a policy with no late rule: the gate's own (from round 5, major)
printf 'check_name: review-policy\nprepush:\n  openqodex_block_on: major\n' >"$pol"
fresh loc
for i in 1 2 3 4; do
  change "loc$i"; STUB_OQ=minoronly prepush
  expect "round $i of the branch's own pre-push reviews: a minor still blocks (and a looser every-round value doesn't loosen it)" 1 "blocking at minor (round $i: early-local)"
done
change loc5; STUB_OQ=minoronly prepush
expect "the branch's 5th pre-push review: minors no longer block (the gate's default late rule)" 0 "blocking at major (round 5: late-local)"
STUB_OQ=minoronly prepush
expect "reviewing the same commit again is not another round" 0 "blocking at major (round 5: late-local)"
push -q origin loc
expect "and the push passes on the branch's own count" 0
fresh loc; change reuse1; STUB_OQ=minoronly prepush
expect "a reused branch name starts from round 1: the old branch's commits aren't on it (3.4)" 1 "blocking at minor (round 1: early-local)"
printf 'check_name: review-policy\nprepush:\n  late:\n    from_round: soon\n    openqodex_block_on: major\n' >"$pol"
fresh bad; change bad1; STUB_OQ=minoronly prepush
expect "a malformed late rule blocks as before" 1 "blocking at minor (round ?: bad-late-rule)"
printf 'prepush: [unclosed\n' >"$pol"
fresh badyaml; change bady1; STUB_OQ=minoronly prepush
expect "a policy that doesn't parse blocks as before (never the gate's default late rule)" 1 "blocking at minor (round ?: bad-policy)"
rm -f "$pol"
fresh nopol; change late8; STUB_OQ=minoronly prepush
expect "no readable policy blocks as before" 1 "no-policy"
latepol; git -C "$W" checkout -q --detach && change detached && STUB_OQ=minoronly prepush
expect "a detached head blocks as before" 1 "no-branch"
git -C "$W" checkout -q feat; rm -f "$pol"
unset STUB_PR_HEAD

# ── install-githooks ──
git init -q "$T/inst"
out="$(bash "$root/install-githooks" --repo "$T/inst" 2>&1)"; rc=$?
[ "$(git -C "$T/inst" config --local --get core.hooksPath)" = "$root/githooks" ] || rc=9
expect "install-githooks --repo sets core.hooksPath for that repo" 0 "core.hooksPath (repo)"
git -C "$T/inst" config core.hooksPath /elsewhere
out="$(bash "$root/install-githooks" --repo "$T/inst" 2>&1)"; rc=$?
expect "it never replaces another core.hooksPath silently" 1 "already /elsewhere"
out="$(bash "$root/install-githooks" --repo "$T/inst" --force 2>&1)"; rc=$?
expect "--force replaces it" 0
out="$(bash "$root/install-githooks" --uninstall --repo "$T/inst" 2>&1)"; rc=$?
git -C "$T/inst" config --local --get core.hooksPath >/dev/null && rc=9
expect "--uninstall removes it" 0 "removed core.hooksPath"

echo "# pass $pass"
echo "# fail $fail"
[ "$fail" -eq 0 ]
