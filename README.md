# CodeRabbit-Claude-MCP

A thin [MCP](https://modelcontextprotocol.io) stdio server that wraps the
**CodeRabbit CLI** (`coderabbit review`) so any MCP client (Claude Code, etc.)
can run local AI code reviews as a tool call — no PR required.

It shells out to the `coderabbit` binary; it does **not** reimplement review
logic. Verified against CodeRabbit CLI **v0.6.1**.

## Prerequisites

Install and authenticate the CodeRabbit CLI (a CodeRabbit account is required):

```bash
curl -fsSL https://cli.coderabbit.ai/install.sh | sh   # installs `coderabbit` (alias `cr`); needs `unzip`
coderabbit auth login                                  # interactive GitHub OAuth
coderabbit auth status                                 # verify
```

## Setup

```bash
git clone <this-repo> CodeRabbit-Claude-MCP
cd CodeRabbit-Claude-MCP
npm install
```

`node_modules/` is git-ignored.

## Register with an MCP client

Point your client's MCP config at the **absolute path** of `server.mjs`. For a
project-scoped Claude Code server, add to that project's `.mcp.json`:

```json
{
  "mcpServers": {
    "coderabbit": {
      "command": "node",
      "args": ["/absolute/path/to/CodeRabbit-Claude-MCP/server.mjs"]
    }
  }
}
```

The server reviews its own working directory by default (`process.cwd()`),
which for a project-scoped server is that project's root — so the same install
serves every project you register it in.

## Tools

- **`coderabbit_status`** — report the CLI version and auth status. Run first to
  confirm setup.
- **`coderabbit_review`** — run a review and return findings as text. Params:
  - `type` — `uncommitted` | `committed` | `all` (CLI default is `all`)
  - `base` — base **branch** to diff against, e.g. `main` (`--base`)
  - `base_commit` — base **commit** on the current branch (`--base-commit`)
  - `output` — `plain` (default; human-readable + fix suggestions) or `agent`
    (structured findings, `--agent`)
  - `light` — boolean; lighter/faster review (`--light`)
  - `path` — repo to review (defaults to the server's cwd)
  - `extra_args` — array of raw CLI flags appended verbatim (e.g. `--config`,
    `--dir`)
  - `timeout_seconds` — default 600

## Env overrides

- `CODERABBIT_BIN` — explicit path to the `coderabbit` binary (if not on `PATH`
  or in `~/.local/bin`)
- `CODERABBIT_TIMEOUT_SECONDS` — default review timeout (seconds)

## Headless / remote auth

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
`ssh -L <port>:127.0.0.1:<port> user@server`, then open the URL.)

## PR gate — CodeRabbit-green before any PR

`coderabbit-gate` + `hooks/pre-pr-coderabbit-gate.sh` enforce "review before you
open a PR". Wired as a Claude Code `PreToolUse` hook, it blocks `gh pr create`
unless a CodeRabbit pass is recorded for the **current HEAD commit** — a stale
pass from before later commits does not count.

Wire the hook into `~/.claude/settings.json` (user-level → applies in every repo):

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "bash /absolute/path/to/CodeRabbit-Claude-MCP/hooks/pre-pr-coderabbit-gate.sh" }
        ]
      }
    ]
  }
}
```

Workflow:

```bash
coderabbit review --base main      # review the change, iterate until green
./coderabbit-gate record           # record the pass for the current HEAD
gh pr create ...                   # now allowed
```

`./coderabbit-gate status` shows the recorded pass vs HEAD; `clear` removes it.

Scope/safety: only `gh pr create` is gated (not `gh api` PR creation or other
clients). It requires `jq` (to extract the command from the hook payload) and
matches `gh pr create` only in **command position** — so commands that merely
mention the string (echo, grep, commit messages, heredocs) are not blocked. The
hook is **fail-open** — any internal error, or a missing `jq`, lets the command
through rather than wedging your shell — so it is a strong speed-bump, not a hard
security boundary.

## Notes

- The server logs only to stderr; stdout is reserved for the MCP protocol.
- If the CLI is missing or unauthenticated, tool calls return a clear,
  actionable message rather than failing the connection.
