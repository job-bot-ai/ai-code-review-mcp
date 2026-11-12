#!/usr/bin/env bash
# The pre-push review: `review-gate prepush` (OpenQodex, stubbed by test/stub/openqodex with real-shaped records),
# and githooks/pre-push on real `git push`es to a local bare remote. No network.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
gate="$root/review-gate"
T="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export OPENQODEX_HOME="$T/oqhome" XDG_STATE_HOME="$T/state"
export REVIEW_GATE_OPENQODEX="$root/test/stub/openqodex" REVIEW_GATE_GH="$root/test/stub/gh"
export REVIEW_GATE_OPENQODEX_MEMORY=off PUNCH_FIXTURE="$T/punch" STUB_OQ_ARGS="$T/oq-args"
unset GH_TOKEN STUB_OQ PUNCH_FAIL REVIEW_GATE_PREPUSH REVIEW_GATE_BLOCK_ON

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
prepush
expect "a passing review records a pass" 0 "pre-push review passed"
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

(cd "$W" && bash "$gate" clear >/dev/null) && push -q origin HEAD:refs/heads/after-clear
expect "review-gate clear (the reviewer passes) leaves pre-push records alone" 0

# ── only the newest commits reviewed ──
change base-a; push -q --no-verify origin feat; change base-b
out="$(cd "$W" && bash "$gate" prepush --base origin/feat 2>&1)"; rc=$?
push -q origin feat
expect "a review against the branch's own remote tip (not the PR base) doesn't count" 1 "not on a remote branch other than feat"
out="$(cd "$W" && bash "$gate" prepush --base HEAD~1 2>&1)"; rc=$?
push -q origin feat
expect "a review against an unpushed HEAD~1 doesn't count" 1 "not on a remote branch other than feat"
prepush; push -q origin feat
expect "the whole change against the PR base does" 0

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
PATH="$T/bin:$PATH" REVIEW_GATE_OPENQODEX_MEMORY=1G prepush
grep -q -- '--scope' "$T/sdrun" && grep -q 'MemoryMax=1G' "$T/sdrun" && grep -q 'MemorySwapMax=' "$T/sdrun" && [ "$rc" = 0 ]; rc=$?
expect "the review runs in a systemd scope with a memory cap" 0
change seven
REVIEW_GATE_PREPUSH=off push -q origin feat
expect "REVIEW_GATE_PREPUSH=off lets an unreviewed push through, announced" 0 "pre-push gate is OFF"
grep -q 'git-hook' "$XDG_STATE_HOME/review-gate/prepush-bypass.log"; rc=$?
expect "and the bypass is logged" 0
: >"$T/notadir"
XDG_STATE_HOME="$T/notadir" REVIEW_GATE_PREPUSH=off push -q origin HEAD:refs/heads/unlogged
expect "the switch doesn't work when the bypass can't be logged" 1 "can't be logged"
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
