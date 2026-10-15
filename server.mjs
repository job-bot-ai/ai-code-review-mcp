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
import { accessSync, constants, realpathSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";

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

/**
 * Detect which flags the installed `coderabbit review` supports so we can adapt
 * to CLI drift (e.g. v0.6.x used `--plain`/`--light`/`--type <x>`; v0.8.x dropped
 * them for `--agent` + discrete scope flags). The help text is fetched once per
 * binary and cached — cheap backward/forward compatibility.
 */
const _crHelpCache = new Map();
async function coderabbitReviewHelp(bin) {
  if (_crHelpCache.has(bin)) return _crHelpCache.get(bin);
  const res = await runCli(bin, ["review", "--help"], {
    cwd: process.cwd(),
    timeoutMs: 15000,
  });
  // Only trust and cache a successful probe. On timeout/non-zero exit, return ""
  // (uncached) so the modern-flag fallback applies and a later call can retry.
  if (res.timedOut || res.code !== 0) return "";
  const help = `${res.stdout}\n${res.stderr}`;
  _crHelpCache.set(bin, help);
  return help;
}
// Flags a current CodeRabbit CLI is assumed to support if `--help` can't be read.
const CR_MODERN_FLAGS = new Set([
  "--agent",
  "--committed",
  "--uncommitted",
  "--include-untracked",
  "--base",
  "--base-commit",
  "--dir",
]);
/** True if `flag` appears as a distinct token in the CLI help (word-boundary match). */
function helpHasFlag(help, flag) {
  if (!help || !help.trim()) return CR_MODERN_FLAGS.has(flag);
  const esc = flag.replace(/[-/\\^$*+?.()|[\]{}]/g, "\\$&");
  return new RegExp(`(^|\\s)${esc}(\\s|=|,|$)`, "m").test(help);
}

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

/** Parse newline-delimited JSON (the `--agent` event stream). Tolerates blank/partial lines. */
function parseJsonLines(text) {
  const events = [];
  let sawNonJson = false;
  for (const line of String(text).split(/\r?\n/)) {
    const t = line.trim();
    if (!t) continue;
    try {
      events.push(JSON.parse(t));
    } catch {
      sawNonJson = true;
    }
  }
  return { events, sawNonJson };
}

// Each finding's `codegenInstructions` is prefixed with an identical safety
// preamble; strip it so the rendered report shows the actionable text once.
const CR_INSTRUCTION_PREAMBLE = /^Treat finding text[\s\S]*?\n\n/;
const cleanInstruction = (s) =>
  typeof s === "string" ? s.replace(CR_INSTRUCTION_PREAMBLE, "").trim() : "";

function renderSuggestion(s) {
  if (s == null) return null;
  if (typeof s === "string") return s.trim() || null;
  const parts = [];
  if (s.title) parts.push(String(s.title));
  if (s.description) parts.push(String(s.description));
  const code = s.replacement ?? s.code ?? s.snippet;
  if (code) parts.push("```\n" + String(code) + "\n```");
  return parts.length ? parts.join("\n") : JSON.stringify(s);
}

/** Turn the `--agent` event stream into a readable findings report. */
function renderCoderabbitFindings(events) {
  const ctx = events.find((e) => e.type === "review_context");
  const findings = events.filter((e) => e.type === "finding");
  const done = events.find((e) => e.type === "complete");
  const lines = [];

  if (ctx) {
    const scope = ctx.reviewType ? `${ctx.reviewType} ` : "";
    const range =
      ctx.baseBranch && ctx.currentBranch
        ? ` (${ctx.baseBranch}...${ctx.currentBranch})`
        : "";
    lines.push(`CodeRabbit ${scope}review${range}`.replace(/\s+/g, " ").trim());
  } else {
    lines.push("CodeRabbit review");
  }

  if (findings.length === 0) {
    lines.push("", "No findings.");
  } else {
    lines.push("", `${findings.length} finding${findings.length === 1 ? "" : "s"}:`);
    findings.forEach((f, i) => {
      const sev = String(f.severity || "note").toUpperCase();
      const loc = [f.fileName || f.file, f.line ?? f.startLine ?? f.lineNumber]
        .filter((x) => x != null && x !== "")
        .join(":");
      const title = f.title || f.summary || "";
      lines.push("", `${i + 1}. [${sev}] ${loc || "(no location)"}${title ? ` — ${title}` : ""}`);
      const body = f.description || f.message || cleanInstruction(f.codegenInstructions);
      if (body) for (const bl of String(body).split("\n")) lines.push(`   ${bl}`);
      const sugg = Array.isArray(f.suggestions)
        ? f.suggestions.map(renderSuggestion).filter(Boolean)
        : [];
      for (const s of sugg) {
        lines.push("   Suggestion:");
        for (const sl of s.split("\n")) lines.push(`     ${sl}`);
      }
    });
  }

  if (done) {
    const reviewed = Array.isArray(done.reviewedFiles) ? done.reviewedFiles : [];
    lines.push("", "—");
    lines.push(
      `Outcome: ${done.outcome || done.status || "unknown"}` +
        (done.message ? ` — ${done.message}` : "")
    );
    if (reviewed.length)
      lines.push(
        `Reviewed ${reviewed.length} file${reviewed.length === 1 ? "" : "s"}: ${reviewed.join(", ")}`
      );
  }
  return lines.join("\n");
}

/** Interpret an `--agent` run: surface error events, else render findings. */
function coderabbitAgentResult(res, timeoutMs) {
  if (res.timedOut) {
    return textResult(
      `CodeRabbit review timed out after ${Math.round(timeoutMs / 1000)}s. ` +
        "Increase timeout_seconds or narrow the scope.\n\n" +
        (res.stdout || res.stderr),
      true
    );
  }
  const { events } = parseJsonLines(res.stdout);
  const errEvent = events.find((e) => e.type === "error");
  if (errEvent) {
    const detail = errEvent.message || JSON.stringify(errEvent);
    const meta = errEvent.metadata || {};
    const parts = [`CodeRabbit review error: ${detail}`];
    if (meta.waitTime) parts.push(`Wait time: ${meta.waitTime}.`);
    if (meta.policyGuidance) parts.push(String(meta.policyGuidance));
    if (looksLikeAuthError(detail))
      parts.push("This looks like an authentication problem. Try `coderabbit auth login`.");
    return textResult(parts.join("\n\n"), true);
  }
  // The CLI can pause for confirmation (e.g. included reviews exhausted → asks to
  // re-run with --use-credits). Surface the required action instead of a bare
  // non-zero exit, so the caller knows how to proceed.
  const action = events.find((e) => e.type === "action_required");
  if (action) {
    const bits = [`CodeRabbit needs confirmation to proceed: ${action.action || "action required"}.`];
    if (action.promotionTerms) bits.push(action.promotionTerms);
    if (typeof action.billableFilesCount === "number")
      bits.push(`Billable files: ${action.billableFilesCount}.`);
    if (action.command)
      bits.push(`Re-run with \`${action.command}\` (e.g. extra_args: ["--use-credits"]).`);
    return textResult(bits.join("\n"), true);
  }
  if (events.length === 0) {
    // Not the structured stream we expected — fall back to raw text handling.
    return reviewResult("CodeRabbit", res, timeoutMs, "coderabbit auth login");
  }
  if (res.code !== 0) {
    const detail = `${res.stdout}\n${res.stderr}`.trim();
    return textResult(`CodeRabbit CLI exited with code ${res.code}.\n\n${detail}`, true);
  }
  return textResult(renderCoderabbitFindings(events));
}

async function handleCoderabbitReview(args = {}) {
  const bin = findBinary("coderabbit", "CODERABBIT_BIN");
  if (!bin) return textResult(HINTS.coderabbit, true);

  const help = await coderabbitReviewHelp(bin);
  const has = (flag) => helpHasFlag(help, flag);

  // Output mode. Default to the structured `--agent` JSON stream (parsed into a
  // findings report). `output: "plain"` returns the CLI's own text report — on
  // modern CLIs that's the default (no flag); older CLIs needed `--plain`.
  const useAgent = args.output !== "plain" && has("--agent");

  const cliArgs = ["review"];
  if (useAgent) {
    cliArgs.push("--agent");
  } else if (has("--plain")) {
    cliArgs.push("--plain"); // back-compat with pre-0.8 CLIs
  }

  // Scope. Modern CLIs use discrete flags; older CLIs used `--type <scope>`.
  const scopeFlag = {
    committed: "--committed",
    uncommitted: "--uncommitted",
    all: "--include-untracked",
  };
  if (args.type) {
    const flag = scopeFlag[args.type];
    if (flag && has(flag)) cliArgs.push(flag);
    else if (has("--type")) cliArgs.push("--type", args.type);
    else if (flag) cliArgs.push(flag); // best effort if help couldn't be read
  }

  if (args.base) cliArgs.push("--base", args.base);
  if (args.base_commit) cliArgs.push("--base-commit", args.base_commit);
  if (args.light && has("--light")) cliArgs.push("--light"); // dropped in newer CLIs
  if (Array.isArray(args.extra_args)) for (const a of args.extra_args) cliArgs.push(String(a));

  const timeoutMs = (Number(args.timeout_seconds) || CODERABBIT_TIMEOUT) * 1000;
  const res = await runCli(bin, cliArgs, { cwd: args.path || process.cwd(), timeoutMs });

  return useAgent
    ? coderabbitAgentResult(res, timeoutMs)
    : reviewResult("CodeRabbit", res, timeoutMs, "coderabbit auth login");
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
      "Wraps `coderabbit review` (uses the CLI's `--agent` structured event stream, parsed into a " +
      "findings report). Requires the CodeRabbit CLI installed + authenticated. 1-5 min for large diffs.",
    inputSchema: {
      type: "object",
      properties: {
        type: { type: "string", enum: ["uncommitted", "committed", "all"], description: "Review scope (--committed/--uncommitted/--include-untracked; omit for CLI default)." },
        base: { type: "string", description: "Base branch/commit to diff against, e.g. 'main' (--base)." },
        output: { type: "string", enum: ["plain", "agent"], description: "'agent' (default: structured --agent stream, parsed to findings) or 'plain' (the CLI's own text report)." },
        light: { type: "boolean", description: "Lighter/faster review (--light); ignored on CLIs that no longer support it." },
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
  { name: "ai-code-review-mcp", version: "0.3.0" },
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

// Pure helpers exported for unit testing; importing the module must not start
// the stdio server (guarded below), so tests can exercise the parser directly.
export { parseJsonLines, renderCoderabbitFindings, coderabbitAgentResult, helpHasFlag };

// Start the MCP server only when run as the entrypoint (`node server.mjs`), not
// when imported as a module. Compare resolved real paths so a symlinked or
// relative launch path (e.g. via the `bin` entry) still counts as the entrypoint.
const isEntrypoint = (() => {
  const argv1 = process.argv[1];
  if (!argv1) return false;
  try {
    return realpathSync(fileURLToPath(import.meta.url)) === realpathSync(argv1);
  } catch {
    return false;
  }
})();
if (isEntrypoint) {
  const transport = new StdioServerTransport();
  server.connect(transport).then(
    () => console.error("[ai-code-review-mcp] ready"),
    (err) => {
      console.error("[ai-code-review-mcp] failed to start:", err);
      process.exit(1);
    }
  );
}
