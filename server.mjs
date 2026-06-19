#!/usr/bin/env node
/**
 * coderabbit-mcp — a thin MCP (stdio) server that wraps the CodeRabbit CLI
 * (`coderabbit review`) so an MCP client (e.g. Claude Code) can run local
 * AI code reviews as a tool call.
 *
 * It shells out to the `coderabbit` binary; it does NOT reimplement review
 * logic. The CLI must be installed and authenticated separately:
 *   curl -fsSL https://cli.coderabbit.ai/install.sh | sh
 *   coderabbit auth login
 *
 * Env overrides:
 *   CODERABBIT_BIN              explicit path to the coderabbit binary
 *   CODERABBIT_TIMEOUT_SECONDS  default review timeout in seconds (default 600)
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

const DEFAULT_TIMEOUT_SECONDS =
  Number(process.env.CODERABBIT_TIMEOUT_SECONDS) || 600;

const INSTALL_HINT =
  "CodeRabbit CLI not found. Install it with:\n" +
  "  curl -fsSL https://cli.coderabbit.ai/install.sh | sh\n" +
  "then authenticate with:\n" +
  "  coderabbit auth login\n" +
  "If it is installed at a non-standard path, set CODERABBIT_BIN to its full path.";

/** Resolve the coderabbit binary, or return null if not found. */
function findBinary() {
  if (process.env.CODERABBIT_BIN) return process.env.CODERABBIT_BIN;
  const exe = "coderabbit";
  const candidates = [];
  for (const dir of (process.env.PATH || "").split(":")) {
    if (dir) candidates.push(join(dir, exe));
  }
  const home = homedir();
  candidates.push(join(home, ".local", "bin", exe));
  candidates.push(join(home, ".coderabbit", "bin", exe));
  candidates.push("/usr/local/bin/" + exe);
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

/** Spawn the CLI and capture output. Never rejects. */
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

const TOOLS = [
  {
    name: "coderabbit_review",
    description:
      "Run a CodeRabbit AI code review on the local git working tree and return its findings as text. " +
      "Wraps `coderabbit review`. Requires the CodeRabbit CLI to be installed and authenticated. " +
      "Reviews can take 1-5 minutes for large diffs.",
    inputSchema: {
      type: "object",
      properties: {
        type: {
          type: "string",
          enum: ["uncommitted", "committed", "all"],
          description:
            "Scope of the review: 'uncommitted' (working-tree changes), 'committed' (committed changes), or 'all'. Omit to use the CLI default.",
        },
        base: {
          type: "string",
          description:
            "Base branch or commit to diff against, e.g. 'main' or 'HEAD~3'. Maps to --base.",
        },
        output: {
          type: "string",
          enum: ["plain", "agent"],
          description:
            "'plain' (default) = human-readable findings with fix suggestions; 'agent' = structured findings emitted for agent workflows (--agent).",
        },
        light: {
          type: "boolean",
          description:
            "Run a lighter, faster review with reduced context work (--light).",
        },
        base_commit: {
          type: "string",
          description:
            "Base commit on the current branch to compare against (--base-commit). Distinct from `base`, which is a branch.",
        },
        path: {
          type: "string",
          description:
            "Path to the git repository to review (the CLI runs there). Defaults to the server's working directory (the project root).",
        },
        extra_args: {
          type: "array",
          items: { type: "string" },
          description:
            "Additional raw CLI flags appended verbatim, for options this wrapper does not model.",
        },
        timeout_seconds: {
          type: "number",
          description: `Maximum seconds to wait before aborting the review (default ${DEFAULT_TIMEOUT_SECONDS}).`,
        },
      },
      additionalProperties: false,
    },
  },
  {
    name: "coderabbit_status",
    description:
      "Report the CodeRabbit CLI version and authentication status. Use this to verify setup before running a review.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  },
];

async function handleReview(args = {}) {
  const bin = findBinary();
  if (!bin) return textResult(INSTALL_HINT, true);

  const output = args.output === "agent" ? "--agent" : "--plain";
  const cliArgs = ["review", output];
  if (args.light) cliArgs.push("--light");
  if (args.type) cliArgs.push("--type", args.type);
  if (args.base) cliArgs.push("--base", args.base);
  if (args.base_commit) cliArgs.push("--base-commit", args.base_commit);
  if (Array.isArray(args.extra_args)) {
    for (const a of args.extra_args) cliArgs.push(String(a));
  }

  const cwd = args.path || process.cwd();
  const timeoutMs =
    (Number(args.timeout_seconds) || DEFAULT_TIMEOUT_SECONDS) * 1000;

  const res = await runCli(bin, cliArgs, { cwd, timeoutMs });

  if (res.timedOut) {
    return textResult(
      `CodeRabbit review timed out after ${Math.round(timeoutMs / 1000)}s. ` +
        "Increase timeout_seconds or narrow the scope (e.g. type='uncommitted').\n\n" +
        (res.stdout || res.stderr),
      true
    );
  }

  if (res.code !== 0) {
    const detail = `${res.stdout}\n${res.stderr}`.trim();
    const hint = looksLikeAuthError(detail)
      ? "\n\nThis looks like an authentication problem. Run `coderabbit auth login` (or check `coderabbit auth status`)."
      : "";
    return textResult(
      `CodeRabbit CLI exited with code ${res.code}.\n\n${detail}${hint}`,
      true
    );
  }

  const review = res.stdout.trim();
  if (!review) {
    return textResult(
      "CodeRabbit completed with no output (no findings, or nothing to review)." +
        (res.stderr.trim() ? `\n\n${res.stderr.trim()}` : "")
    );
  }
  return textResult(review);
}

async function handleStatus() {
  const bin = findBinary();
  if (!bin) return textResult(INSTALL_HINT, true);

  const version = await runCli(bin, ["--version"], {
    cwd: process.cwd(),
    timeoutMs: 15000,
  });
  const auth = await runCli(bin, ["auth", "status"], {
    cwd: process.cwd(),
    timeoutMs: 30000,
  });

  const lines = [
    `binary: ${bin}`,
    `version: ${(version.stdout || version.stderr).trim() || "(unknown)"}`,
    "",
    "auth status:",
    (auth.stdout || auth.stderr).trim() || "(no output)",
  ];
  return textResult(lines.join("\n"), auth.code !== 0);
}

const server = new Server(
  { name: "coderabbit-mcp", version: "0.1.0" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: TOOLS }));

server.setRequestHandler(CallToolRequestSchema, async (req) => {
  const { name, arguments: args } = req.params;
  try {
    if (name === "coderabbit_review") return await handleReview(args);
    if (name === "coderabbit_status") return await handleStatus();
    return textResult(`Unknown tool: ${name}`, true);
  } catch (err) {
    return textResult(`coderabbit-mcp internal error: ${err?.stack || err}`, true);
  }
});

const transport = new StdioServerTransport();
server.connect(transport).then(
  () => console.error("[coderabbit-mcp] ready"),
  (err) => {
    console.error("[coderabbit-mcp] failed to start:", err);
    process.exit(1);
  }
);
