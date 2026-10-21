#!/usr/bin/env bash
# kimi-review tests: a fake `gh` stands in for GitHub (no network). Checks that only a
# complete review of the pushed HEAD with no high finding records the kimi pass.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kr="$root/kimi-review"
gate="$root/review-gate"
T="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$T"' EXIT
unset REVIEW_GATE_REQUIRED
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# Fake gh. FAKE_VERDICT: JSON written as verdict.json ("HEAD" is replaced by the dispatched
# sha); FAKE_NO_WORKFLOW=1: workflow not on the default branch; FAKE_NO_ARTIFACT=1.
mkdir -p "$T/bin"
cat >"$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
state="$FAKE_STATE"
case "$1 $2" in
  "repo view") echo main ;;
  "api repos/acme/alpha/contents/.github/workflows/ollama-review.yml?ref=main") [ -z "${FAKE_NO_WORKFLOW:-}" ] ;;
  "workflow run")
    printf '%s\n' "$@" >"$state/dispatch"
    grep -qx -- '--ref' "$state/dispatch" && grep -A1 -x -- '--ref' "$state/dispatch" | tail -1 | grep -qx main || exit 1 ;;
  "run list")
    sha="$(sed -n 's/^head_sha=//p' "$state/dispatch")"; rid="$(sed -n 's/^request_id=//p' "$state/dispatch")"
    printf '[{"databaseId":7,"displayTitle":"pre-PR review other x"},{"databaseId":42,"displayTitle":"pre-PR review %s %s"}]\n' "$sha" "$rid" ;;
  "run view") [ -z "${FAKE_ON_VIEW:-}" ] || bash -c "$FAKE_ON_VIEW" >/dev/null 2>&1; echo "completed ${FAKE_CONCLUSION:-success}" ;;
  "run download")
    [ -z "${FAKE_NO_ARTIFACT:-}" ] || exit 1
    while [ $# -gt 0 ]; do [ "$1" = "-D" ] && dir="$2"; shift; done
    sha="$(sed -n 's/^head_sha=//p' "$state/dispatch")"
    printf '%s' "$FAKE_VERDICT" | sed "s/HEAD/$sha/" >"$dir/verdict.json"
    echo "### Ollama review (fake)" >"$dir/review.md" ;;
  *) echo "fake gh: unexpected: $*" >&2; exit 9 ;;
esac
EOF
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH" FAKE_STATE="$T"

git init -q --bare "$T/remote/acme/alpha.git"
git init -q -b main "$T/w" && git -C "$T/w" remote add origin "$T/remote/acme/alpha.git"
git -C "$T/w" commit -q --allow-empty -m init && git -C "$T/w" push -q origin main
git -C "$T/w" checkout -q -b feat/x && git -C "$T/w" commit -q --allow-empty -m change

pass=0; fail=0
run() { out="$(cd "$T/w" && bash "$kr" "$@" 2>&1)"; rc=$?; }
expect() { # expect <name> <rc> [substring]
  if [ "$rc" -eq "$2" ] && { [ -z "${3:-}" ] || [[ "$out" == *"$3"* ]]; }; then
    pass=$((pass + 1)); echo "ok   - $1"
  else fail=$((fail + 1)); echo "FAIL - $1 (rc=$rc)"; echo "$out" | sed 's/^/       /'; fi
}
kimi_state() { (cd "$T/w" && bash "$gate" status) | sed -n 's/^  kimi *//p' | sed 's/ \[required\]$//'; }

export FAKE_VERDICT='{"complete":true,"sha":"HEAD","high":0,"medium":0}'
run
expect "unpushed HEAD is refused" 2 "Push first"

git -C "$T/w" remote set-url origin "$T/nonexistent/acme/alpha.git"
run
expect "an unreachable origin is a setup error with a message" 2 "can't reach origin"
git -C "$T/w" remote set-url origin "$T/remote/acme/alpha.git"

git -C "$T/w" push -q origin feat/x
FAKE_NO_WORKFLOW=1 run
expect "missing workflow on the default branch is a setup error" 2 "merge its chore/ollama-pr-review PR first"

FAKE_VERDICT='{"complete":true,"sha":"HEAD","high":1,"medium":0}' run
expect "a high finding fails without recording" 1 "Fix the high findings"
[ "$(kimi_state)" = "(none)" ] || { fail=$((fail + 1)); echo "FAIL - kimi recorded despite a high finding"; }

FAKE_VERDICT='{"complete":false,"sha":"HEAD","reason":"model down"}' run
expect "an incomplete review fails" 1 "did not complete: model down"

FAKE_VERDICT='{"complete":true,"sha":"0000000000000000000000000000000000000000","high":0,"medium":0}' run
expect "a verdict for another commit fails" 1 "not HEAD"

FAKE_VERDICT='{"complete":true,"sha":"HEAD","medium":0}' run
expect "a verdict without a high count fails closed" 1 "no valid high/medium counts"
FAKE_VERDICT='{"complete":true,"sha":"HEAD","high":null,"medium":0}' run
expect "a null high count fails closed" 1 "no valid high/medium counts"

FAKE_NO_ARTIFACT=1 FAKE_CONCLUSION=failure run
expect "no artifact (secret missing / model down) fails" 1 "no review came back"

run --no-record
expect "--no-record reports a pass without recording" 0 "not recorded"
[ "$(kimi_state)" = "(none)" ] || { fail=$((fail + 1)); echo "FAIL - --no-record recorded"; }

FAKE_VERDICT='{"complete":true,"sha":"HEAD","high":0,"medium":2}' run --base develop
expect "no high findings records kimi, flagging mediums" 0 "2 medium finding(s)"
case "$(kimi_state)" in "green @ "*) ;; *) fail=$((fail + 1)); echo "FAIL - kimi not green: $(kimi_state)";; esac
grep -qx 'base=develop' "$T/dispatch" || { fail=$((fail + 1)); echo "FAIL - --base not dispatched"; }
grep -qx "head_sha=$(git -C "$T/w" rev-parse HEAD)" "$T/dispatch" || { fail=$((fail + 1)); echo "FAIL - wrong head_sha"; }

FAKE_VERDICT='{"complete":true,"sha":"HEAD","high":2,"medium":0}' run
expect "a failed re-review of the same commit fails" 1 "2 high"
[ "$(kimi_state)" = "(none)" ] || { fail=$((fail + 1)); echo "FAIL - earlier kimi pass survived a failed re-review: $(kimi_state)"; }
run
expect "a clean re-review records kimi again" 0
FAKE_VERDICT='{not json' run
expect "a malformed verdict fails" 1 "not a JSON object"
[ "$(kimi_state)" = "(none)" ] || { fail=$((fail + 1)); echo "FAIL - kimi pass survived a malformed re-review"; }
FAKE_VERDICT='[1]' run
expect "a non-object verdict fails" 1 "not a JSON object"
run
expect "and a clean review records it again" 0

# HEAD moves mid-review and the new commit gets its own pass: rejecting the old commit
# must not withdraw it.
git -C "$T/w" checkout -q -b feat/race && git -C "$T/w" push -q origin feat/race
FAKE_ON_VIEW="cd '$T/w' && git commit -q --allow-empty -m newer && bash '$gate' record kimi" \
  FAKE_VERDICT='{"complete":true,"sha":"HEAD","high":1,"medium":0}' run
expect "a rejection of an older commit fails" 1 "1 high"
case "$(kimi_state)" in "green @ "*) ;; *) fail=$((fail + 1)); echo "FAIL - newer kimi pass was withdrawn: $(kimi_state)";; esac
git -C "$T/w" checkout -q feat/x
run
expect "back on feat/x, a clean review records kimi" 0

# record --rev binds the pass to the given commit, not to whatever HEAD is.
old="$(git -C "$T/w" rev-parse HEAD)"
git -C "$T/w" commit -q --allow-empty -m tmp
out="$(cd "$T/w" && bash "$gate" record kimi --rev "$old" 2>&1)"; rc=$?
expect "record --rev records the given commit" 0 "@ ${old:0:12}"
out="$(cd "$T/w" && bash "$gate" check --rev "$old" 2>&1 >/dev/null; bash "$gate" record kimi --rev nosuch 2>&1)"; rc=$?
expect "record --rev rejects a non-commit" 2 "is not a commit"
git -C "$T/w" reset -q --hard "$old"

# The gate: both required reviewers skipped + kimi pass → allowed, and announced.
(cd "$T/w" && bash "$gate" record-skip coderabbit --reason "free hourly allowance used up" >/dev/null \
  && bash "$gate" record-skip codex --reason "skipped until 2026-10-24" >/dev/null)
out="$(cd "$T/w" && bash "$gate" check 2>&1)"; rc=$?
expect "gate: kimi pass + codex skip is enough, and the skip is announced" 0 "codex was SKIPPED"
git -C "$T/w" commit -q --allow-empty -m later
out="$(cd "$T/w" && bash "$gate" check 2>&1)"; rc=$?
expect "gate: a kimi pass is bound to its commit" 1 "missing/stale"

echo "kimi-review: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
