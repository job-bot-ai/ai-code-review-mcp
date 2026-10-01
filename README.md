# ai-code-review-mcp

A thin [MCP](https://modelcontextprotocol.io) stdio server that wraps local
AI **code-review CLIs** so any MCP client (Claude Code, etc.) can run reviews as
tool calls — no PR required — plus a **PR gate** that blocks `gh pr create` until
both reviewers are green.

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

## PR gate — CodeRabbit + Codex green before any PR

`review-gate` + `hooks/pre-pr-coderabbit-gate.sh` enforce "review before you open
a PR". Wired as a Claude Code `PreToolUse` hook, it blocks `gh pr create` unless
**every required reviewer** has a pass recorded for the **commit the PR comes from** —
a stale pass from before later commits does not count. Required reviewers default
to `coderabbit codex` (override with `REVIEW_GATE_REQUIRED`).

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
  - `timeout`/`env`/`sudo`-style runners (`env -C`/`GH_REPO=` operands included).
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
- `-H/--head [OWNER:]BRANCH` (including clusters like `-dH`; a non-literal `--head "$B"`
  blocks, since the PR's commit is unknown), resolved in this order:
  - the owner, if given, must own one of the checkout's remotes;
  - a branch checked out in another worktree is checked there;
  - a `git push <remote> <src>:<branch>` earlier in the same command decides the commit
    (it is what the PR will contain), checked in the checkout that pushed;
  - otherwise the local branch's tip, or a fetched remote branch's tip, must have been
    reviewed.
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
coderabbit review --base main  && ./review-gate record coderabbit   # iterate until green
codex review --base main       && ./review-gate record codex        # iterate until green
gh pr create ...                                                    # now allowed
```

`./review-gate status` shows each reviewer's state vs HEAD; `clear [reviewer]`
removes a pass (and any skip).

**A reviewer that can't run** (quota exhausted, outage, no seat) can be skipped for
one commit, with a reason:

```bash
./review-gate record-skip codex --reason "usage limit until 2026-10-03 13:32"
```

A skip is bound to HEAD like a pass, is printed by every `check` that relies on it
(the hook surfaces it as a `systemMessage`), and never satisfies the gate alone: at
least one required reviewer needs a real pass. Prefer this over
`REVIEW_GATE_REQUIRED`, which can only be set in the hook's environment and leaves no
per-commit record.

Scope/safety: only `gh pr create` is gated (not `gh api` PR creation or other
clients). The hook requires `jq` (to extract the command from the payload) and
hands any command containing the words `gh pr create` to the resolver above, which
gates real invocations wherever they run and lets data-only mentions (echo, grep,
commit messages, heredocs) through. Without `node`, it falls back to gating only
`gh pr create` in **command position** of the session cwd. It is
**fail-open** — any internal error, or a missing `jq`, lets the command through
rather than wedging your shell — so it is a strong speed-bump, not a hard security
boundary.

Tests: `npm test` (resolver unit tests + hook integration tests against throwaway repos).

## Env overrides

- `CODERABBIT_BIN` / `CODEX_BIN` — explicit binary paths (if not on `PATH`)
- `CODERABBIT_TIMEOUT_SECONDS` (default 600) / `CODEX_TIMEOUT_SECONDS` (default 900)
- `REVIEW_GATE_REQUIRED` — space-separated reviewers the gate requires (default `coderabbit codex`)

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
