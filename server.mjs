#!/usr/bin/env node
/**
 * ai-code-review-mcp — a thin MCP (stdio) server that wraps local AI code-review
 * CLIs so an MCP client (e.g. Claude Code) can run reviews as tool calls.
 *
 * Reviewers wrapped (each shells out to its CLI; no review logic reimplemented):
 *   - CodeRabbit   (`coderabbit review`) -> tools coderabbit_review / coderabbit_status
 *   - OpenAI Codex (`codex review`)      -> tools codex_review / codex_status
 *
 * The CLIs must be installed and authenticated separately:
 *   curl -fsSL https://cli.coderabbit.ai/install.sh | sh ; coderabbit auth login
 *   npm i -g @openai/codex  (or brew install codex)      ; codex login
 *
 * Env overrides:
 *   CODERABBIT_BIN / CODEX_BIN                 explicit binary paths
 *   CODERABBIT_TIMEOUT_SECONDS (default 600)
 *   CODEX_TIMEOUT_SECONDS      (default 900)
 *
 * The server logs only to stderr; stdout is reserved for the MCP protocol.
 */

import { spawn } from "node:child_process";
import { accessSync, constants } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";

const CODERABBIT_TIMEOUT = Number(process.env.CODERABBIT_TIMEOUT_SECONDS) || 600;
const CODEX_TIMEOUT = Number(process.env.CODEX_TIMEOUT_SECONDS) || 900;

const HINTS = {
  coderabbit:
    "CodeRabbit CLI not found. Install: curl -fsSL https://cli.coderabbit.ai/install.sh | sh\n" +
    "then: coderabbit auth login. Override the path with CODERABBIT_BIN.",
  codex:
    "Codex CLI not found. Install: npm i -g @openai/codex (or brew install codex)\n" +
    "then: codex login. Override the path with CODEX_BIN.",
};

/** Resolve an executable by name, or null. Checks env override, PATH, then common dirs. */
function findBinary(exe, envVar) {
  if (process.env[envVar]) return process.env[envVar];
  const candidates = [];
  for (const dir of (process.env.PATH || "").split(":")) {
    if (dir) candidates.push(join(dir, exe));
  }
  const home = homedir();
  candidates.push(join(home, ".local", "bin", exe));
  candidates.push(join(home, "." + exe, "bin", exe));
  candidates.push("/usr/local/bin/" + exe, "/usr/bin/" + exe);
  for (const c of candidates) {
    try {
      accessSync(c, constants.X_OK);
      return c;
    } catch {
      /* keep looking */
    }
  }
  return null;
}

/** Spawn a CLI and capture output. Never rejects. */
function runCli(bin, args, { cwd, timeoutMs }) {
  return new Promise((resolve) => {
    let stdout = "";
    let stderr = "";
    let timedOut = false;
    const child = spawn(bin, args, { cwd, env: process.env });
    const timer = setTimeout(() => {
      timedOut = true;
      child.kill("SIGTERM");
      setTimeout(() => child.kill("SIGKILL"), 5000).unref();
    }, timeoutMs);
    child.stdout.on("data", (d) => (stdout += d.toString()));
    child.stderr.on("data", (d) => (stderr += d.toString()));
    child.on("error", (err) => {
      clearTimeout(timer);
      resolve({ code: -1, stdout, stderr: `${stderr}\n${err.message}`, timedOut });
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      resolve({ code, stdout, stderr, timedOut });
    });
  });
}

const textResult = (text, isError = false) => ({
  content: [{ type: "text", text }],
  isError,
});

const looksLikeAuthError = (s) =>
  /auth|log ?in|logged in|unauthor|token|credential/i.test(s);

/** Shared interpretation of a review run's result. */
function reviewResult(label, res, timeoutMs, authCmd) {
  if (res.timedOut) {
    return textResult(
      `${label} review timed out after ${Math.round(timeoutMs / 1000)}s. ` +
        "Increase timeout_seconds or narrow the scope.\n\n" +
        (res.stdout || res.stderr),
      true
    );
  }
  if (res.code !== 0) {
    const detail = `${res.stdout}\n${res.stderr}`.trim();
    const hint = looksLikeAuthError(detail)
      ? `\n\nThis looks like an authentication problem. Try \`${authCmd}\`.`
      : "";
    return textResult(`${label} CLI exited with code ${res.code}.\n\n${detail}${hint}`, true);
  }
  const out = res.stdout.trim();
  if (!out) {
    return textResult(
      `${label} completed with no output (no findings, or nothing to review).` +
        (res.stderr.trim() ? `\n\n${res.stderr.trim()}` : "")
    );
  }
  return textResult(out);
}

/** version + auth status for a CLI. */
async function statusResult(label, bin, versionArgs, authArgs) {
  const v = await runCli(bin, versionArgs, { cwd: process.cwd(), timeoutMs: 15000 });
  const a = await runCli(bin, authArgs, { cwd: process.cwd(), timeoutMs: 30000 });
  return textResult(
    [
      `binary: ${bin}`,
      `version: ${(v.stdout || v.stderr).trim() || "(unknown)"}`,
      "",
      "auth status:",
      (a.stdout || a.stderr).trim() || "(no output)",
    ].join("\n"),
    a.code !== 0
  );
}

// ---------- CodeRabbit ----------
async function handleCoderabbitReview(args = {}) {
  const bin = findBinary("coderabbit", "CODERABBIT_BIN");
  if (!bin) return textResult(HINTS.coderabbit, true);
  const cliArgs = ["review", args.output === "agent" ? "--agent" : "--plain"];
  if (args.light) cliArgs.push("--light");
  if (args.type) cliArgs.push("--type", args.type);
  if (args.base) cliArgs.push("--base", args.base);
  if (args.base_commit) cliArgs.push("--base-commit", args.base_commit);
  if (Array.isArray(args.extra_args)) for (const a of args.extra_args) cliArgs.push(String(a));
  const timeoutMs = (Number(args.timeout_seconds) || CODERABBIT_TIMEOUT) * 1000;
  const res = await runCli(bin, cliArgs, { cwd: args.path || process.cwd(), timeoutMs });
  return reviewResult("CodeRabbit", res, timeoutMs, "coderabbit auth login");
}

const handleCoderabbitStatus = () =>
  (function () {
    const bin = findBinary("coderabbit", "CODERABBIT_BIN");
    if (!bin) return Promise.resolve(textResult(HINTS.coderabbit, true));
    return statusResult("CodeRabbit", bin, ["--version"], ["auth", "status"]);
  })();

// ---------- Codex ----------
async function handleCodexReview(args = {}) {
  const bin = findBinary("codex", "CODEX_BIN");
  if (!bin) return textResult(HINTS.codex, true);
  const cliArgs = ["review"];
  if (args.uncommitted) cliArgs.push("--uncommitted");
  if (args.base) cliArgs.push("--base", args.base);
  if (args.commit) cliArgs.push("--commit", args.commit);
  if (args.title) cliArgs.push("--title", args.title);
  if (Array.isArray(args.extra_args)) for (const a of args.extra_args) cliArgs.push(String(a));
  if (args.instructions) cliArgs.push(String(args.instructions)); // positional [PROMPT]
  const timeoutMs = (Number(args.timeout_seconds) || CODEX_TIMEOUT) * 1000;
  const res = await runCli(bin, cliArgs, { cwd: args.path || process.cwd(), timeoutMs });
  return reviewResult("Codex", res, timeoutMs, "codex login");
}

const handleCodexStatus = () =>
  (function () {
    const bin = findBinary("codex", "CODEX_BIN");
    if (!bin) return Promise.resolve(textResult(HINTS.codex, true));
    return statusResult("Codex", bin, ["--version"], ["login", "status"]);
  })();

const TOOLS = [
  {
    name: "coderabbit_review",
    description:
      "Run a CodeRabbit AI code review on the local git working tree and return findings as text. " +
      "Wraps `coderabbit review`. Requires the CodeRabbit CLI installed + authenticated. 1-5 min for large diffs.",
    inputSchema: {
      type: "object",
      properties: {
        type: { type: "string", enum: ["uncommitted", "committed", "all"], description: "Review scope (omit for CLI default)." },
        base: { type: "string", description: "Base branch/commit to diff against, e.g. 'main' (--base)." },
        output: { type: "string", enum: ["plain", "agent"], description: "'plain' (default) or 'agent' (structured, --agent)." },
        light: { type: "boolean", description: "Lighter/faster review (--light)." },
        base_commit: { type: "string", description: "Base commit on the current branch (--base-commit)." },
        path: { type: "string", description: "Git repo to review. Defaults to the server's cwd." },
        extra_args: { type: "array", items: { type: "string" }, description: "Extra raw CLI flags appended verbatim." },
        timeout_seconds: { type: "number", description: `Max seconds before aborting (default ${CODERABBIT_TIMEOUT}).` },
      },
      additionalProperties: false,
    },
  },
  {
    name: "coderabbit_status",
    description: "Report the CodeRabbit CLI version and authentication status.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "codex_review",
    description:
      "Run an OpenAI Codex code review on the local git changes and return findings as text. " +
      "Wraps `codex review`. Requires the Codex CLI installed + authenticated (`codex login`). Agentic; can take minutes.",
    inputSchema: {
      type: "object",
      properties: {
        base: { type: "string", description: "Base branch to diff against, e.g. 'main' (--base)." },
        uncommitted: { type: "boolean", description: "Review staged + unstaged + untracked changes (--uncommitted)." },
        commit: { type: "string", description: "Review the changes introduced by a specific commit SHA (--commit)." },
        title: { type: "string", description: "Optional title shown in the review summary (--title)." },
        instructions: { type: "string", description: "Custom review instructions passed to Codex (positional prompt), e.g. 'focus on security'." },
        path: { type: "string", description: "Git repo to review. Defaults to the server's cwd." },
        extra_args: { type: "array", items: { type: "string" }, description: "Extra raw CLI flags appended verbatim." },
        timeout_seconds: { type: "number", description: `Max seconds before aborting (default ${CODEX_TIMEOUT}).` },
      },
      additionalProperties: false,
    },
  },
  {
    name: "codex_status",
    description: "Report the Codex CLI version and authentication status.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  },
];

const HANDLERS = {
  coderabbit_review: handleCoderabbitReview,
  coderabbit_status: handleCoderabbitStatus,
  codex_review: handleCodexReview,
  codex_status: handleCodexStatus,
};

const server = new Server(
  { name: "ai-code-review-mcp", version: "0.2.0" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: TOOLS }));

server.setRequestHandler(CallToolRequestSchema, async (req) => {
  const { name, arguments: args } = req.params;
  try {
    const handler = HANDLERS[name];
    if (!handler) return textResult(`Unknown tool: ${name}`, true);
    return await handler(args);
  } catch (err) {
    return textResult(`ai-code-review-mcp internal error: ${err?.stack || err}`, true);
  }
});

const transport = new StdioServerTransport();
server.connect(transport).then(
  () => console.error("[ai-code-review-mcp] ready"),
  (err) => {
    console.error("[ai-code-review-mcp] failed to start:", err);
    process.exit(1);
  }
);
