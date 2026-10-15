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
**every required reviewer** has a pass recorded for the **current HEAD commit** —
a stale pass from before later commits does not count. Required reviewers default
to `coderabbit codex` (override with `REVIEW_GATE_REQUIRED`).

> The hook file is named `pre-pr-coderabbit-gate.sh` for back-compat with existing
> `settings.json` entries; it gates on all configured reviewers, not just CodeRabbit.

Wire the hook into `~/.claude/settings.json` (user-level → applies in every repo):

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "bash /absolute/path/to/ai-code-review-mcp/hooks/pre-pr-coderabbit-gate.sh" }
        ]
      }
    ]
  }
}
```

Workflow:

```bash
coderabbit review --base main  && ./review-gate record coderabbit   # iterate until green
codex review --base main       && ./review-gate record codex        # iterate until green
gh pr create ...                                                    # now allowed
```

`./review-gate status` shows each reviewer's state vs HEAD; `clear [reviewer]`
removes a pass.

Scope/safety: only `gh pr create` is gated (not `gh api` PR creation or other
clients). The hook requires `jq` (to extract the command from the payload) and
matches `gh pr create` only in **command position** — so commands that merely
mention the string (echo, grep, commit messages, heredocs) are not blocked. It is
**fail-open** — any internal error, or a missing `jq`, lets the command through
rather than wedging your shell — so it is a strong speed-bump, not a hard security
boundary.

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
