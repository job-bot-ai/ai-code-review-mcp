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
REVIEW_GATE_BLOCK_ON=critical push -q origin feat
expect "a review run with another block_on_severity doesn't count" 1 "block_on_severity"
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
STUB_OQ=hang REVIEW_GATE_PREPUSH_TIMEOUT=1 REVIEW_GATE_PREPUSH_GRACE=1 prepush
expect "an OpenQodex that never returns is stopped (exit 4)" 4 "didn't finish within 2s"
prepush
expect "and the next prepush is not locked out, though a reviewer it started still runs" 0 "pre-push review passed"
kill "$(cat "$OPENQODEX_HOME/orphan.pid")" 2>/dev/null
STUB_OQ=killed prepush
expect "a SIGKILL (the memory cap) is reported as that, naming MemoryMax" 4 "MemoryMax"

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
