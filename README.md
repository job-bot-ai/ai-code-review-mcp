# ai-code-review-mcp

A thin [MCP](https://modelcontextprotocol.io) stdio server that wraps local
AI **code-review CLIs** so any MCP client (Claude Code, etc.) can run reviews as
tool calls — no PR required — plus a **PR gate**: open the PR as a draft, let the PR
reviewers (Kodus + CodeRabbit, then Kodus + Greptile from 2026-11-19) review it, and
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
   `kodus coderabbit` until 2026-11-19 and `kodus greptile` from then (UTC);
   override with `REVIEW_GATE_PRIMARY` (`REVIEW_GATE_REQUIRED` is read as a legacy alias);
3. a `self` pass only counts once `codex` has a pass or a skip (Codex is the first fallback).

Reviewers: `kodus`, `coderabbit`, `greptile` (primaries), `codex` (fallback), `self`
(the agent's own thorough review, last resort). `agy` and `kimi` stay valid so old records
and `kimi-review` keep working.

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
./review-gate record kodus               # and: record coderabbit (until 2026-11-19) / record greptile (from then)
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

**`kimi` (legacy; Kodus now runs DeepSeek on every PR).** `kimi-review` still works and
records a `kimi` pass, which counts as one review but not as a primary:

```bash
git push -u origin "$(git branch --show-current)"     # GitHub reviews the pushed commit
/opt/CodeRabbit-Claude-MCP/kimi-review --base main     # ~5-10 min; records kimi on a pass
```

How it works:

- The review runs in GitHub Actions. Each job-bot-ai repo has an `ollama-review.yml`
  workflow, added by its `chore/ollama-pr-review` PR, with the `OLLAMA_API_KEY` repo secret.
  `kimi-review` dispatches that workflow on the default branch (trusted workflow and
  prompt) with `head_sha=<HEAD>`. It waits for the run, then reads the run's `ollama-review`
  artifact (`verdict.json`, `review.md`). No key on this host, nothing posted to GitHub.
- **Pass** = the review completed, it reviewed exactly HEAD, and it has **no high finding**.
  Then `kimi-review` runs `review-gate record kimi --rev <reviewed sha>`, so the pass is
  bound to the commit that was reviewed even if HEAD moves. Medium findings are printed: fix them,
  or say in the PR description why not. High findings, an incomplete run (secret missing,
  model down, unparsable answer) or a moved HEAD record nothing and exit 1; a completed
  review that rejects also withdraws any earlier kimi pass.
- When the PR is then opened at that same commit, the workflow posts this pre-PR review on
  the PR instead of running the model again. Pushes to an open PR are not re-reviewed
  automatically (cost). Comment `/review` (or `/review deep`) on the PR to re-review the
  new head.
- Exit codes: 0 pass, 1 findings or no review, 2 setup (branch not pushed, workflow not on
  the default branch yet, gh not authenticated).

Scope/safety: only `gh pr create`, `gh pr ready` and the GraphQL ready mutation are
gated (not other clients or the web UI). The hook requires `jq` (to extract the command from the payload) and
hands any command containing the words `gh pr create` to the resolver above, which
gates real invocations wherever they run and lets data-only mentions (echo, grep,
commit messages, heredocs) through. Without `node`, it falls back to gating only
`gh pr create` in **command position** of the session cwd. It is
**fail-open** — any internal error, or a missing `jq`, lets the command through
rather than wedging your shell — so it is a strong speed-bump, not a hard security
boundary.

Tests: `npm test` (resolver unit tests, hook integration tests against throwaway repos, and
`kimi-review` tests against a fake `gh`).

## Env overrides

- `CODERABBIT_BIN` / `CODEX_BIN` — explicit binary paths (if not on `PATH`)
- `CODERABBIT_TIMEOUT_SECONDS` (default 600) / `CODEX_TIMEOUT_SECONDS` (default 900)
- `REVIEW_GATE_PRIMARY` — space-separated primary reviewers (default `kodus coderabbit`
  until 2026-11-19, `kodus greptile` from then; valid: `kodus coderabbit greptile codex self agy kimi`)
- `REVIEW_GATE_MIN` — how many different reviewers must pass (default 2)

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
