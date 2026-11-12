# ai-code-review-mcp

A thin [MCP](https://modelcontextprotocol.io) stdio server that wraps local
AI **code-review CLIs** so any MCP client (Claude Code, etc.) can run reviews as
tool calls — no PR required — plus a **PR gate**: open the PR as a draft, let the PR
reviewers (Kodus + Greptile; CodeRabbit was retired on 2026-11-12) review it, and
`gh pr ready` is blocked until two reviews are green on the PR's final commit.

Reviewers wrapped (each shells out to its CLI; no review logic reimplemented):

| Reviewer | CLI | Tools |
|---|---|---|
| CodeRabbit | `coderabbit review` (v0.8.0) | `coderabbit_review`, `coderabbit_status` |
| OpenAI Codex | `codex review` (codex-cli 0.125) | `codex_review`, `codex_status` |

`coderabbit_review` drives the CLI's `--agent` structured event stream and parses
it into a findings report. It probes `coderabbit review --help` once (cached) to
stay compatible across CLI versions — e.g. pre-0.8 CLIs used `--plain` and
`--type <scope>`; 0.8+ dropped those for `--agent` and discrete scope flags.

## Prerequisites

Install and authenticate each CLI you want to use:

```bash
# CodeRabbit (needs `unzip`)
curl -fsSL https://cli.coderabbit.ai/install.sh | sh
coderabbit auth login        # interactive GitHub OAuth

# OpenAI Codex
npm i -g @openai/codex        # or: brew install codex
codex login                   # ChatGPT or API-key auth
```

`jq` is also required for the PR gate hook.

## Setup

```bash
git clone https://github.com/job-bot-ai/ai-code-review-mcp
cd ai-code-review-mcp
npm install
```

`node_modules/` is git-ignored.

## Register with an MCP client

Point your client's MCP config at the **absolute path** of `server.mjs`:

```json
{
  "mcpServers": {
    "codereview": {
      "command": "node",
      "args": ["/absolute/path/to/ai-code-review-mcp/server.mjs"]
    }
  }
}
```

The server reviews its own working directory by default (`process.cwd()`), which
for a project-scoped server is that project's root — so one install serves every
project you register it in. Tools surface as `mcp__<server-key>__*` — e.g.
`mcp__codereview__coderabbit_review` for the `codereview` key above (the prefix
follows the config key you choose, not the server's internal name).

## Tools

Each reviewer exposes a `*_status` tool (CLI version + auth) and a `*_review` tool.

- **`coderabbit_review`** — `type` (`uncommitted`/`committed`/`all`), `base`,
  `base_commit`, `output` (`agent` default — parsed structured findings — or
  `plain` for the CLI's own text report), `light`, `path`, `extra_args`,
  `timeout_seconds` (default 600).
- **`codex_review`** — `base`, `uncommitted` (bool), `commit`, `title`,
  `instructions` (custom review prompt), `path`, `extra_args`, `timeout_seconds`
  (default 900).

## PR gate — draft first, two green reviews before ready

`review-gate` + `hooks/pre-pr-coderabbit-gate.sh` enforce "two independent reviews
before a PR is ready". Wired as a Claude Code `PreToolUse` hook:

- `gh pr create --draft` (or `-d`) is **always allowed**: Kodus, the CodeRabbit app and
  Greptile only review a PR that exists, so the draft is how they get to see it.
  `gh pr ready --undo` is not gated either.
- `gh pr ready` and a **non-draft** `gh pr create` are blocked until `review-gate check`
  passes for the PR's commit. For `gh pr ready` that is the PR's head on GitHub (looked up
  with `gh pr view`; if the lookup fails and no PR was named, local HEAD is checked and the
  hook says so). A stale pass from before later commits does not count.
- `gh pr ready https://github.com/OWNER/REPO/pull/N` is checked against the checkout's
  remotes like `--repo`; a `git push` in the same command as `gh pr ready` blocks (the PR's
  head would change after the lookup).
- Sending the GraphQL ready mutation (`markPullRequestReadyForReview`) with an API client
  (`gh api`, `curl`, `wget`, httpie) is blocked wherever the resolver sees it run (directly,
  through runners, `bash -c`, `eval`, a heredoc or pipe fed to a shell, or piped into the
  client). A mention that is only data (`echo`, a heredoc written to a file) passes.

`check` passes when:

1. at least **two different reviewers** have a pass recorded for the commit
   (`REVIEW_GATE_MIN`, default 2);
2. every **primary** reviewer has a pass **or** an announced skip. Primaries are
   `kodus greptile` (CodeRabbit was retired on 2026-11-12);
   override with `REVIEW_GATE_PRIMARY` (`REVIEW_GATE_REQUIRED` is read as a legacy alias);
3. a `self` pass only counts once `codex` has a pass or a skip (Codex is the first fallback);
4. the commit has a **pre-push review**, the same check the git pre-push hook makes: a finished OpenQodex review
   of exactly that commit that passed (or whose findings were declined with `prepush-accept`, which every check
   announces), given the punch list that is on main now. See the next section.

Reviewers: `kodus`, `greptile` (primaries; `coderabbit` stays valid for old records), `codex` (fallback), `self`
(the agent's own thorough review, last resort). `agy` stays valid for old records. `kimi`
(the retired `kimi-review` pass) is no longer a reviewer: a leftover kimi marker is ignored
and never counts.

**Which repo is checked.** The PR's repo, not the session's working directory
(`hooks/resolve-pr-target.mjs` reads the command the way bash would). Every
`gh pr create` in the command is checked, each in its own repo:

- `cd`/`pushd`/`popd` before it are followed: literal paths, `~`, `$HOME`, `( ... )`
  subshells, `builtin cd`/`command cd`. A `cd` in a pipeline or background job doesn't
  move `gh`, just as in bash.
- Code that runs is walked too, from the directory it runs in:
  - `$(...)`, backticks and `<(...)` (e.g. `PR_URL=$(gh pr create ...)`), including
    those in unquoted heredocs;
  - `bash`/`sh -c` and `eval` scripts, even when part of the script is a variable;
  - code fed to a shell or `source` on stdin: a heredoc, a here-string, or a pipe
    (`cat <<'EOF' | bash`, `echo "..." | bash`);
  - `timeout`/`env`/`sudo`/`nice`/`nohup`/`exec` runners are unwrapped to the program they
    launch, so a wrapped `git push`/`git commit`, `bash -c`, API client or `gh pr` command is
    handled like an unwrapped one (`env -C`/`sudo -D` make the directory unknown; `env -S` and
    `xargs` fall back to scanning every argument).
- A mention fed to a command that never runs its input (`cat`, `tee`, `echo`, `git`,
  `gh`, `grep`, `jq`, …) is data, e.g. a commit message or a script being written,
  and isn't gated. Text fed to `python`/`node`/`perl`/`ruby` on a heredoc or stdin is
  also treated as data, since it's nearly always a file edit.
- A mention the gate can't follow (`ssh`, an `awk` script using `system(...)` or a `sed` `e` command,
  `bash script.sh`, `bash <(...)`, `python3 -c "..."`) is treated like an unparseable
  command.
- When it can't know where `gh` runs, it **blocks** rather than guess:
  - a non-literal `cd` (`cd $X`, `cd -`);
  - a `cd` that may or may not run before `gh pr create`:
    - after `||`;
    - inside `if`/`case`/loops/functions;
    - `x && cd dir` whose list ends before `gh pr create` (a trailing `&&`/`||`/`|`
      continues the list onto the next line, as in bash);
    - `x && { cd dir; }` followed by `gh pr create` outside the group. Inside the
      group the `cd` holds, so `test -d d && { cd d; gh pr create; }` is fine;
  - `eval cd …`, `eval`/`source` with a non-literal argument, or `CDPATH`;
  - `gh pr create` inside a function, or with a non-literal argument such as `$ARGS`.
- `-R/--repo [HOST/]OWNER/REPO` (or `GH_REPO`) must match one of that checkout's
  remotes; otherwise it blocks and asks you to run `gh pr create` from the target checkout.
- `-H/--head [OWNER:]BRANCH` (including clusters like `-fH`; a non-literal `--head "$B"`
  blocks, since the PR's commit is unknown), resolved in this order:
  - the owner, if given, must own one of the checkout's remotes;
  - a branch checked out in another worktree is checked there;
  - a `git push <remote> <src>:<branch>` earlier in the same command decides the commit
    (it is what the PR will contain), checked in the checkout that pushed;
  - otherwise the local branch's tip, or a fetched remote branch's tip, must have been
    reviewed.
- A `git commit`/`merge`/`rebase`/`pull`/`reset`/`cherry-pick`/`revert`/`am`, or a
  `checkout`/`switch` to another commit, earlier in the same command and repo blocks: the
  hook runs before that commit exists, so it can't have been reviewed. Creating a branch
  at HEAD (`checkout -b x`) is fine.
- A `--repo`/`--head` PR from a non-git directory is blocked. A plain `gh pr create`
  outside git is not gated (gh fails there anyway); this is announced.
- If the command can't be parsed, the gate falls back to the session's cwd and says so,
  unless the command changes directory or names a repo/branch: then it blocks.
- `gh pr create --help` isn't gated. A `-h` that is only part of an argument (for example
  a PR body that says "use -h") no longer skips the gate.
- `git -C <dir>` is ignored on purpose: it never changes where `gh` runs.
- Out of scope: deliberately hiding a `cd` or `gh pr create` from the gate. Examples:
  a command word built from an expansion (`$X /dir`, `$(echo cd) /dir`), or a script
  interpreter told to run it (`python3 - <<EOF ... os.system(...)`). The gate is a
  speed-bump against mistakes, not a sandbox.

When it gated on a different repo than the cwd, or relied on a skip, the hook says so
(as a `systemMessage`).

Workflow:

```bash
gh pr create --draft ...                 # always allowed; Kodus reviews it automatically
# CodeRabbit skips drafts by default: comment `@coderabbitai review` (Greptile: `@greptileai review`)
# fix high findings, fix medium ones or say why not, push, request a re-review; then for each clean pass:
./review-gate record kodus               # and: record greptile
gh pr ready                              # now allowed
```

If findings remain after two review rounds, don't start a third fix-by-fix round: do a
deep analysis of the whole change first (the root cause the findings share, the same bug
class elsewhere in the diff, tests), fix that, and say in the PR body what kept coming
up before asking for the third review.

`./review-gate status` shows each reviewer's state vs HEAD; `clear [reviewer]`
removes a pass (and any skip). A pass for a commit other than HEAD:
`./review-gate record <reviewer> --rev <commit>`.

**A reviewer that can't run** (not installed on the repo, errored, quota exhausted, no
review within 30 min) is skipped for one commit, with a reason, and replaced by Codex,
then by your own review:

```bash
./review-gate record-skip kodus --reason "no review within 30 min"
codex review --base main && ./review-gate record codex
# if Codex can't run either:
./review-gate record-skip codex --reason "usage limit until 2026-11-09 13:32"
./review-gate record self                # after a thorough review of your own
```

A skip is bound to HEAD like a pass, is printed by every `check` that relies on it
(the hook surfaces it as a `systemMessage`), and never counts as a pass.
CodeRabbit may only use its free hourly allowance: never `--use-credits`.

**`agy` (legacy).** Still a valid reviewer name. In headless mode agy refuses shell and file
tools and still exits 0, so embed the diff in the prompt and treat a
"no output produced" reply as no review:

```bash
d="$(git diff main...HEAD)"; mkdir -p /tmp/agy-empty && cd /tmp/agy-empty   # nothing to explore
agy -p "Do NOT use any tools; everything is in this message. Review this diff ...
If nothing material, write exactly: NO MATERIAL FINDINGS.
$d" --model gemini-3.8-flash-high --mode plan --print-timeout 900s
```

Pass `--model` explicitly: the default model's quota can be exhausted ("Individual quota
reached", printed as `AGY_ERROR` with exit 0) while `gemini-3.8-flash-high` still works
(`agy models` lists them). Without the "no tools" line agy often tries a command, is denied,
and prints "no output produced". Neither case is a review.

**`kimi` (retired).** The `kimi-review` helper and its `kimi` pass were removed with the
in-repo `ollama-review` workflow (job_bot_ai#228); Kodus runs DeepSeek on every PR instead.

Scope/safety: only `gh pr create`, `gh pr ready` and the GraphQL ready mutation are gated here (not other clients
or the web UI); `git push` is gated by git's pre-push hook (next section). The hook requires `jq` (to extract the command from the payload) and
hands any command containing the words `gh pr create` to the resolver above, which
gates real invocations wherever they run and lets data-only mentions (echo, grep,
commit messages, heredocs) through. Without `node`, it falls back to gating only
`gh pr create` in **command position** of the session cwd. It is
**fail-open** — a missing `jq`, or `review-gate` saying there is nothing to gate (exit 3), lets the command
through rather than wedging your shell; any other unexpected `review-gate check` exit code blocks — so it is a
strong speed-bump, not a hard security boundary.

Tests: `npm test` (resolver unit tests, hook integration tests, and pre-push tests on real `git push`es to a local
bare remote, with stub `openqodex` and `gh` binaries in `test/stub/` that write OpenQodex's real record shapes).

## Pre-push review — OpenQodex reviews the whole change before every push

Fixes pushed one at a time let the PR bots find the next problem on the next push (one PR took 44 review threads).
So before **every** push to a PR branch the whole change is reviewed against our punch list, and what it finds is
fixed first. The reviewer is [OpenQodex](https://github.com/openqodex/openqodex) (Apache-2.0, no telemetry, runs
locally, starts its own read-only Claude Code or Codex reviewer); the push gate is **git's own pre-push hook**.
This repo only adds glue: fetching the punch list, binding a review to a commit, and failing closed.

```bash
review-gate prepush [--base <ref>]   # default base: the PR's base (gh pr view), else origin/main
# fix every finding at minor or above (and the same bug class elsewhere), commit, run it again, then push
review-gate prepush-accept --reason "why each finding is not being fixed"   # declining, for this commit only
review-gate status                   # shows the pre-push review of HEAD
```

**What `prepush` does.** On a **clean** work tree (OpenQodex reviews the work tree, so only a clean tree makes the
reviewed change exactly the commit you push) it:

1. fetches the punch list from `j-bot-ai/pr-orchestrator` `main` (with `GH_TOKEN="$(gh auth token --user
   job-bot-ai)"` when `GH_TOKEN` is unset; the token is never printed): `review/punch-list/NN-*.md` when that
   folder exists (not `log.md`), else `review/PUNCH_LIST.md`. Each file is pinned to one `main` commit and checked
   against its git blob id. A failed fetch fails the review; it never means "review without the list";
2. copies it to `.openqodex/punch-list/` in the checkout (git-ignored: `prepush` adds `/.openqodex/` to
   `.git/info/exclude`), and names those copies in `review.instructions_files` of **our own** OpenQodex config,
   `$GIT_COMMON_DIR/review-gate-prepush/openqodex.yaml`, outside the work tree so a branch can't loosen it. OpenQodex's
   limits: 32 KB (32,768 bytes) per file, 64 KB (65,536 bytes) in all; a file past either is skipped whole. `prepush`
   checks both **before** the review and fails at once (exit 4) when the list doesn't fit: it never reviews without
   the whole list. For the single `review/PUNCH_LIST.md` the message names pr-orchestrator #21, the split into section
   files. Every run prints the list's size against 64 KB and warns past 56 KB (7/8), so the post-mortems that add to
   it are seen growing before they hit the cap. (Not `--instructions`: it takes one file of at most 32 KB.
   `--instructions` gets `prompts/openqodex-instructions.md`, so a repo's own `.openqodex/custom-instructions.md` is
   not used.)
3. runs `openqodex review --base <base> --offline --reviewer-web off --config <ours> --instructions <ours>
   --block-on-severity minor --timeout 1800` under `systemd-run --scope -p MemoryMax=2G -p MemorySwapMax=256M`
   (panda is RAM-fragile: a runaway is killed inside its scope instead of swap-thrashing the host; exit 137 is
   reported as that kill, naming `MemoryMax`, not as a timeout), watched by a
   watchdog of its own: the run gets its own process group, which gets TERM at `--timeout` + 120 s and KILL 30 s
   later, so a reviewer that ignores `--timeout` and TERM can't hold on (not `timeout(1)`: uutils' timeout, Ubuntu's
   default, neither escalates nor exits 124 with `-k`); the lock's file
   descriptor is closed for it, so a hung run or a leftover reviewer never holds the lock. Never `review --agent`:
   that is the coding agent reviewing its own work;
4. records the result in `$GIT_COMMON_DIR/review-gate-prepush/<sha>.json` (shared by all worktrees, keyed by
   commit; `clear` doesn't touch it, `clear prepush` removes HEAD's), only for a review that **finished**: exit 0 with verdict `passed`, or exit 1 with `blocked`, OpenQodex's
   `last-review` record written by this run, the report matching its sha256, and the manifest showing every
   punch-list file supplied whole with the hashes we fetched. A change that commits files under the top-level
   `.openqodex/` is refused (here and at push time): OpenQodex leaves that folder out of both its review and its
   change id. Exit 2 (incomplete, no reviewer that can start,
   OpenQodex failing), "Nothing to review", HEAD moving during the run: nothing passes, exit 4, and the reason is
   kept in `<sha>.last`.

**Findings.** A `blocked` review exits 1. Fix the findings. Declining them for that commit with
`prepush-accept --reason "..."` (only after a finished review with findings; an unfinished review can't be
accepted) is a waiver, so it is **Tim's**: Claude Code's hook blocks `review-gate prepush-accept` unless Tim set
`REVIEW_GATE_PREPUSH=off`, and every acceptance is written to the bypass log below (when the log can't be written,
nothing is accepted). Every check of that commit announces the reason.

**Severity: `minor`, not `major`.** OpenQodex's scale: `critical` (data loss, security, a crash on a common path),
`major` (wrong behaviour under realistic conditions), `minor` ("a real bug that will rarely surface"), `nitpick`
(style). Our old gate blocked P0-P2 and let only P3 nits through; P2 ("should fix before merge") is where the
rarely-surfacing real bugs our punch list is about sit, so `minor` maps P2 and blocking at `major` would let them
through. Nitpicks and observations never block.

**The git hook.** `githooks/pre-push`, installed with `core.hooksPath`, reads git's ref lines and, for each pushed
branch commit, runs `review-gate check-prepush --rev <sha>`, the same function (`verify_prepush`) `review-gate check`
uses for `gh pr ready`. (`gh pr ready` passes the PR's own branch, as the resolver found it, with `check --branch`,
so a stacked PR marked ready from another checkout is judged by its own PR base.) It passes only when all of these hold:

- the record for that commit exists and OpenQodex's own receipt (`~/.openqodex/receipts/<repo id>/<change id>.json`)
  says `kind: complete` with the same change, verdict, base and `block_on_severity`;
- `report.json` and `manifest.json` still have the sha256 recorded, the report is `complete`, and the manifest shows
  the whole punch list supplied;
- OpenQodex's change id for `<reviewed base>..<commit>`, worked out again at push time with OpenQodex's own formula
  (below), is the one in the record, so a record copied or edited onto another commit never matches;
- the reviewed base is an ancestor of the commit and is on origin's default branch (`origin/HEAD`, else
  `origin/main`) or on the base branch of the pushed branch's PR (`gh pr view <branch>`), so a review of only the
  newest commits (`--base HEAD~1`, the branch's own remote tip, any other branch they were pushed to) doesn't count.
  The first push of a stacked branch, before its PR exists, is therefore reviewed against `main`;
- the verdict is `passed`, or `blocked` with an accepted reason;
- the punch list on `main` **now** has the same files and blob ids as the one reviewed (one or two `gh api` calls; a
  failed fetch blocks).

Anything else blocks, including `review-gate` exiting with any other code. Not gated: deletes and tags. A
`--dry-run` *is* checked like a push: git runs the pre-push hook for it and doesn't tell the hook, and finding out
would mean parsing the push's arguments again. The repo's own `.git/hooks/*` keep running: every hook name in
githooks(5), client and server side, is a link in `githooks/` to `chain`, which runs the repo's own hook
(`core.hooksPath` would otherwise switch them off).

*How a review is bound to a commit.* OpenQodex identifies a review by a change id, not by a commit: sha256 of the
base sha, a newline, and `git diff --raw -z --no-abbrev` (with its `DIFF_FLAGS`, minus its `.openqodex/` folder)
from the base to the work tree (`changeId`/`diffChange` in its `dist/bin.js`; its own pre-push hook matches a push to
a review with the same formula from base to commit). `prepush` requires a clean tree and the same HEAD before and
after the run, so that diff is exactly `<merge base>..<HEAD>`; it checks that the id OpenQodex recorded is the one
the formula gives for HEAD, and `check-prepush` works it out again for the pushed commit, so the tie can't be
edited. `review-gate change-id <base> [<commit>]` prints it; the tests pin it against real OpenQodex 0.18.0 runs.
A repo whose git clean/smudge filters change the bytes (OpenQodex hashes the work tree with filters off) gets
another id, and `prepush` fails rather than record a review no push can match. Pushing another commit needs its
own review.

**Ways around a git hook** are blocked by the Claude Code PreToolUse hook with a short fixed list (no parsing):
`core.hooksPath` in a `git` command (`-c`, `--config-env`,
`git config` writes; `git config --get core.hooksPath` is fine); `include.path`/`includeIf.*.path` in a `git config`
or `-c`; `--no-verify` on any git command (an alias can push); a `GIT_CONFIG*`, `GIT_DIR`, `GIT_COMMON_DIR`,
`HOME`, `XDG_CONFIG_HOME`, `XDG_STATE_HOME`, `PATH`, `BASH_ENV`, `ENV`, `BASH_FUNC_*`, `SHELLOPTS`, `BASHOPTS`,
`LD_PRELOAD` or `LD_LIBRARY_PATH` assignment in a command with `git` or `review-gate`, unless it is plainly a
temporary one for a single other command (`HOME=/tmp npm test; git status`; a segment with quotes, `$(` or
backticks counts), and `env -i`/`-u` or `unset` of them; `export -f`/`declare -fx` (an exported function) with
`git` or `review-gate`; any `REVIEW_GATE_*=` or `OPENQODEX_*=` assignment (the
gate's settings are Tim's); `review-gate prepush-accept` (Tim's waiver, above); `install-githooks --uninstall`;
a write (a redirect to it; `tee`, `sed -i`, `rm`, `chmod`, ... on it in the same command; for `cp`, `ln`,
`install` and `rsync` only their destination (the last operand, or `-t DIR`; option values such as
`--suffix .bak` or `-m 755` are not operands, and an option whose arity isn't known counts every path; redirects such
as `2>/dev/null` are not operands either), so `cp ~/.gitconfig /tmp/backup` is a
read, and for `mv` its sources too, since moving one away removes it; any path in the command when the copy is hidden
behind `xargs`, `bash -c` or a word built at run time; or a `cd` into it or a variable holding it plus any write) to `.gitconfig`, `.git/config`, `git/config`, `.git/hooks`, `githooks/`,
the pre-push records (`review-gate-prepush/`) or OpenQodex's (`.openqodex/`, `~/.openqodex/`);
`git config --remove-section`/`--rename-section`/`--edit`; `git send-pack`/`http-push` (they run no hook); on a
push, any `-c` but `credential.helper=...`, and `--config-env`. Quotes and backslashes are removed before matching,
and two conditions that belong to one command must hold in the same command. The command line is split by the
hook's own shell tokenizer (`hooks/command-segments.mjs`, on `resolve-pr-target.mjs`'s `tokenize`): at `;`, `&`,
`|`, `&&`, `||`, parentheses and newlines **outside** quotes, heredocs, `$(...)` and backticks, with the body of each
substitution, and of code fed to a shell on stdin (`bash <<EOF`, `sh <<< ...`, `eval`/`source`), checked as
commands of their own, and redirect targets (`>`, `>>`, `>|`, `&>`) read as whole words. So
`git -c user.name=x commit && git push`, `git log > f; cat .git/hooks/x` and Claude Code's usual heredoc commit
message (`git commit -m "$(cat <<'EOF' ... -> .git/hooks ... EOF)" && git push`) aren't read as writes, while
`> "$(pwd)/githooks/pre-push"` and `echo $(cp x ~/.gitconfig)` are. Without node, or when the tokenizer can't read
the command, a cruder split errs toward blocking (a command with `$(` or a backtick is matched whole, and any
`HOME=`/`PATH=`/... assignment with git counts). `githooks/pre-push` and `review-gate` run as `#!/bin/bash -p` (the hook calls
`/bin/bash -p review-gate`), which ignores `BASH_ENV`, `ENV`, `SHELLOPTS`, `BASHOPTS` and exported functions, and
set a fixed `PATH` themselves, so neither a `PATH` prefix nor bash's startup inputs can hand them a look-alike
`bash`, `cat`, `git`, `jq` or `systemd-run`. And a command with `git` and `push` is blocked unless `core.hooksPath` in the session's checkout
is this repo's `githooks/`: a repo-local `core.hooksPath` (husky sets one) wins over the global one and would
switch the gate off there, and with nothing installed no push passes. It is a speed bump against an agent
working around the gate, not a sandbox: it sees only Bash commands (not Edit/Write), and only the session's
checkout for the `core.hooksPath` check: a push from another checkout (`git -C <dir> push`, `cd <dir> && git push`)
whose own repo-local `core.hooksPath` (husky) overrides the global one is not caught here. A forged record is no
longer the way around (the change id is worked out again at push time); what is left is writing OpenQodex-shaped
records by hand for a change that was never reviewed, which the write list above slows down but can't prevent.

**Threat model.** The local gate (this git hook and the PreToolUse list) catches **honest mistakes**: an agent
that pushes before the review, forgets to re-review after a fix, or reviews only the newest commit. It is **not a
security boundary** against an agent trying to get around it. Known ways around it, left open on purpose:

- words built at run time: `v=verify; git push --no-$v`, `$'--no-\x76erify'`, a git alias (`alias.p='!git push
  --no-verify'`), a variable name assembled with `${g}_COUNT`;
- moving local remote-tracking refs (`git update-ref refs/remotes/origin/main HEAD~1`, `git remote set-head`) so the
  base check accepts a review of only the newest commits: the check trusts local refs;
- pushing from another checkout whose own `core.hooksPath` (husky) overrides the global one;
- bash-level tricks the list doesn't name, hand-written OpenQodex-shaped records, Edit/Write tool calls (the hook sees
  only Bash), and anything root can do to the files themselves.

The real gate will be **server-side**: a required status check on the PR that only prorch's GitHub App can post,
after its own review (pr-orchestrator #22, round 0). This hook stays as the early, local warning.

**Deploying**, in this order:

0. **pr-orchestrator #21 merged** (https://github.com/j-bot-ai/pr-orchestrator/pull/21, the punch list split into
   `review/punch-list/NN-*.md`, each at most 32 KB and at most 64 KB in all). `main` still has only
   `review/PUNCH_LIST.md`, which is 36,375 bytes, over OpenQodex's 32 KB per-file limit: until #21 is merged every
   `prepush` fails at once (naming #21) and, after step 2, no push passes. Headroom after the split: the sections
   #21 adds come to 26,835 bytes on its branch today (`log.md` is not sent); `prepush` prints the size on every run
   and warns past 56 KB of the 64 KB cap.
1. OpenQodex 0.18.0 installed at `/opt/openqodex` (below).
2. `install-githooks --global` (or `--repo`). From then on every `git push` from Claude Code needs a passing review;
   until steps 0 and 1 are done, pushes are blocked, which is the point.

**Escape hatch (Tim only).** `REVIEW_GATE_PREPUSH=off` in the environment Claude Code itself runs in (e.g. `env` in
`~/.claude/settings.json`, or exported before starting `claude`) lets both hooks through; git inherits it from
Claude Code. As a command prefix it is blocked. Every use is logged to
`~<user>/.local/state/review-gate/prepush-bypass.log`, a fixed place from the user's passwd entry, never from `HOME`
or `XDG_STATE_HOME` (`REVIEW_GATE_BYPASS_LOG`, Tim's, moves it). `review-gate bypass-log` prints it, and both hooks
take the path from there; when that log can't be written, the switch
doesn't work (a bypass is never silent). The same log gets every `prepush-accept` (repo, commit, finding counts,
reason). By hand, outside Claude Code, the same variable
works (and `git push --no-verify` is git's own).

### Installing

```bash
# OpenQodex, pinned (no npx, no auto-update: an npm install has no launcher, and the gate passes
# OPENQODEX_AUTO_UPDATE=0 and --offline anyway)
npm i -g --prefix /opt/openqodex --ignore-scripts openqodex@0.18.0
/opt/openqodex/bin/openqodex --version            # 0.18.0
# the hook, for every repository root pushes from on panda:
./install-githooks --global
# or for one repository:  ./install-githooks --repo /path/to/checkout
```

**Global or per repo:** `--global` (root's `~/.gitconfig`) is the setup for panda: the agents push from many
clones and worktrees, created all the time, and a per-repo setting misses every new clone. Its cost is that it
applies to every repository of root; `githooks/` therefore chains every client hook to the repo's own
`.git/hooks/<name>`, so husky/OpenQodex/other local hooks keep running. `install-githooks` refuses to replace a
different `core.hooksPath` (`--force` does) and `--uninstall` removes only its own.

The reviewer needs Claude Code (or Codex) installed and logged in for root; OpenQodex has no account of its own.
`--offline` keeps semgrep, osv-scanner and the other network scanners off and stops scanner downloads (the
reviewer itself still sends the change to its model service). Scanners not installed are listed in the report and
never change the verdict; `openqodex doctor --install` (online, once) would fetch the pinned ones.

### Settings (Tim's; the PreToolUse hook blocks an agent setting them)

- `REVIEW_GATE_BLOCK_ON` — `block_on_severity` (default `minor`); a review run with another value doesn't count
- `REVIEW_GATE_OPENQODEX_OFFLINE=off` — let OpenQodex's network scanners run (default: `--offline`)
- `REVIEW_GATE_OPENQODEX_MEMORY` — the scope's `MemoryMax` (default `2G`; `off` runs uncapped),
  `REVIEW_GATE_OPENQODEX_SWAP` — its `MemorySwapMax` (default `256M`)
- `REVIEW_GATE_PREPUSH_TIMEOUT` — OpenQodex's `--timeout` in seconds (default 1800); `REVIEW_GATE_PREPUSH_GRACE` —
  how much longer the watchdog waits before TERM (default 120); `REVIEW_GATE_PREPUSH_KILL_AFTER` — then KILL (default 30)
- `REVIEW_GATE_BYPASS_LOG` — where bypasses and `prepush-accept`s are logged (default
  `~<user>/.local/state/review-gate/prepush-bypass.log`)
- `REVIEW_GATE_SYSTEMD_RUN`, `REVIEW_GATE_GH` — the `systemd-run` and `gh` to use (tests; default: the fixed `PATH`'s)
- `REVIEW_GATE_OPENQODEX` — the binary (default `/opt/openqodex/bin/openqodex`); it must report the pinned version
- `REVIEW_GATE_PUNCH_REPO` — where the punch list lives (default `j-bot-ai/pr-orchestrator`, branch `main`)
- `OPENQODEX_HOME` — OpenQodex's record folder (default `~/.openqodex`)
- `REVIEW_GATE_PREPUSH=off` — the escape hatch above

### Upgrading OpenQodex

The version is pinned in `review-gate` (`OQ_VERSION`); `prepush` refuses any other. To upgrade: read the
[changelog](https://github.com/openqodex/openqodex/blob/main/packages/cli/CHANGELOG.md) for changes to `review`'s
flags, exit codes, `report.json`, `manifest.json` or the `receipts/` and `last-review/` records (`review-gate`
reads them, and `test/stub/openqodex` mirrors their shapes); install the new version under the same prefix; run one
real review on a throwaway repo; then bump `OQ_VERSION` (and the stub) in a reviewed PR.

## Env overrides

- `CODERABBIT_BIN` / `CODEX_BIN` — explicit binary paths (if not on `PATH`)
- `CODERABBIT_TIMEOUT_SECONDS` (default 600) / `CODEX_TIMEOUT_SECONDS` (default 900)
- `REVIEW_GATE_PRIMARY` — space-separated primary reviewers (default `kodus greptile`; valid: `kodus coderabbit greptile codex self agy`)
- `REVIEW_GATE_MIN` — how many different reviewers must pass (default 2)
- the pre-push settings are listed above

## Headless / remote auth (CodeRabbit)

On a headless box, `coderabbit auth login --agent` emits JSON containing an
`authUrl` whose `redirect_uri` is a loopback callback
(`http://127.0.0.1:<port>/callback`) on the **server**. Open `authUrl` in any
browser and approve; the browser's redirect to `127.0.0.1:<port>` will fail
(nothing is listening on your laptop). Copy that full callback URL from the
address bar and replay it **on the server**:

```bash
curl '<the-full-127.0.0.1-callback-url>'
```

The CLI's local callback server then completes the login. (Alternative:
`ssh -L <port>:127.0.0.1:<port> user@server`, then open the URL.) `codex login`
uses a similar loopback flow.

## Notes

- The server logs only to stderr; stdout is reserved for the MCP protocol.
- If a CLI is missing or unauthenticated, its tools return a clear, actionable
  message rather than failing the connection.
