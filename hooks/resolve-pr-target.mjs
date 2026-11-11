#!/usr/bin/env node
// Resolve which git checkout(s) and commit(s) the `gh pr create` / `gh pr ready`
// invocations in a Bash command open or mark ready, so the PR gate checks THOSE repos'
// review markers instead of the session's cwd. `gh pr create --draft` and
// `gh pr ready --undo` are not gated (a draft is how the PR reviewers get to see it).
// Part of https://github.com/job-bot-ai/ai-code-review-mcp
//
// Usage: resolve-pr-target.mjs <cwd>   (the Bash command on stdin)
// Prints one JSON object:
//   { "status": "ok", "targets": [{ "dir", "rev"|null, "note"|null }, ...] }
//   { "status": "block", "reason": "..." }   a target can't be determined safely
//   { "status": "help" }                     `--help`, a draft create or `ready --undo`: nothing to gate
//   { "status": "none" }                     `gh pr create` only appears as data (a heredoc
//                                            body, a quoted string): no PR is created
//   { "status": "error", "reason": "..." }   the command couldn't be parsed; "risky": true
//                                            when it changes directory or names a repo/branch,
//                                            so falling back to the session cwd could be wrong
//
// The shell model is deliberately conservative: when it can't tell where `gh` runs (a
// non-literal `cd`, a `cd` that only runs conditionally, `eval cd ...`), the directory
// becomes unknown and the gate blocks rather than guess. `git -C <dir>` is ignored on
// purpose: it never changes where `gh` runs.
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, realpathSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// ── Tokenizer ────────────────────────────────────────────────────────────────

const OPS = new Set([';', ';;', '&&', '||', '|', '&', '(', ')']); // ';;' = case arm end (also ;& ;;&)

function readHeredocDelim(src, i) {
  // i is just past `<<`. Returns { delim, strip, end }.
  let strip = false;
  if (src[i] === '-') { strip = true; i += 1; }
  while (src[i] === ' ' || src[i] === '\t') i += 1;
  const m = src.slice(i).match(/^(?:'([^']*)'|"([^"]*)"|(\\?)([^\s;&|()<>]+))/);
  if (!m) return { delim: null, strip, end: i };
  const quoted = m[1] !== undefined || m[2] !== undefined || m[3] === '\\';
  return { delim: m[1] ?? m[2] ?? m[4], strip, quoted, end: i + m[0].length };
}

function skipHeredocBodies(src, i, heredocs) {
  // i is just past a newline; consume each pending heredoc body in order, keeping the text
  // (h.body) — it is data for most commands but code when fed to a shell.
  for (const h of heredocs.splice(0)) {
    const lines = [];
    while (i < src.length) {
      const end = src.indexOf('\n', i);
      const line = src.slice(i, end < 0 ? src.length : end);
      i = end < 0 ? src.length : end + 1;
      if ((h.strip ? line.replace(/^\t+/, '') : line) === h.delim) break;
      lines.push(line);
    }
    h.body = lines.join('\n');
    if (!h.quoted) h.substs = substitutionsIn(h.body); // an unquoted heredoc expands $(...)
  }
  return i;
}

/** Bodies of the $(...) / `...` in expanding text (an unquoted heredoc). */
function substitutionsIn(text) {
  const out = [];
  for (let i = 0; i < text.length;) {
    if (text[i] === '\\') { i += 2; continue; }
    if (text[i] === '$' && text[i + 1] === '(') { const end = skipCommandSubst(text, i + 2); out.push(text.slice(i + 2, end - 1)); i = end; continue; }
    if (text[i] === '`') { const end = skipBackticks(text, i + 1); out.push(backtickBody(text, i, end)); i = end; continue; }
    i += 1;
  }
  return out;
}

function skipSingleQuoted(src, i) {
  const j = src.indexOf("'", i);
  if (j < 0) throw new Error('unterminated single quote');
  return j + 1;
}

function skipAnsiC(src, i) {
  // i is just past `$'`.
  while (i < src.length) {
    if (src[i] === '\\') { i += 2; continue; }
    if (src[i] === "'") return i + 1;
    i += 1;
  }
  throw new Error("unterminated $'...'");
}

function skipBackticks(src, i) {
  while (i < src.length) {
    if (src[i] === '\\') { i += 2; continue; }
    if (src[i] === '`') return i + 1;
    i += 1;
  }
  throw new Error('unterminated backtick');
}

function skipBraceExpansion(src, i) {
  // i is just past `${`; parameter expansions may nest quotes and further ${...}.
  let depth = 1;
  while (i < src.length) {
    const c = src[i];
    if (c === '\\') { i += 2; continue; }
    if (c === "'") { i = skipSingleQuoted(src, i + 1); continue; }
    if (c === '"') { i = readDoubleQuoted(src, i + 1).end; continue; }
    if (c === '$' && src[i + 1] === '(') { i = skipCommandSubst(src, i + 2); continue; }
    if (c === '$' && src[i + 1] === '{') { depth += 1; i += 2; continue; }
    if (c === '}') { depth -= 1; i += 1; if (depth === 0) return i; continue; }
    i += 1;
  }
  throw new Error('unterminated ${');
}

/** Skip a `$( ... )` (or `$(( ... ))`) body, which is nested shell code. i is just past `$(`. */
function skipCommandSubst(src, i) {
  let depth = 1;
  let wordStart = true;
  const heredocs = [];
  while (i < src.length) {
    const c = src[i];
    if (c === '\\') { i += 2; wordStart = false; continue; }
    if (c === "'") { i = skipSingleQuoted(src, i + 1); wordStart = false; continue; }
    if (c === '"') { i = readDoubleQuoted(src, i + 1).end; wordStart = false; continue; }
    if (c === '`') { i = skipBackticks(src, i + 1); wordStart = false; continue; }
    if (c === '$' && src[i + 1] === "'") { i = skipAnsiC(src, i + 2); wordStart = false; continue; }
    if (c === '$' && src[i + 1] === '{') { i = skipBraceExpansion(src, i + 2); wordStart = false; continue; }
    if (c === '<' && src.startsWith('<<<', i)) { i += 3; continue; }
    if (c === '<' && src.startsWith('<<', i)) {
      const h = readHeredocDelim(src, i + 2);
      if (h.delim !== null) heredocs.push(h);
      i = h.end;
      continue;
    }
    if (c === '#' && wordStart) {
      const j = src.indexOf('\n', i);
      i = j < 0 ? src.length : j;
      continue;
    }
    if (c === '\n') { i = heredocs.length ? skipHeredocBodies(src, i + 1, heredocs) : i + 1; wordStart = true; continue; }
    if (c === '(') { depth += 1; i += 1; wordStart = true; continue; }
    if (c === ')') { depth -= 1; i += 1; if (depth === 0) return i; wordStart = false; continue; }
    wordStart = /[\s;&|]/.test(c);
    i += 1;
  }
  throw new Error('unterminated $(');
}

/** The code inside `...` (start = index of the opening backtick, end = past the closing one). */
function backtickBody(src, start, end) {
  return src.slice(start + 1, end - 1).replace(/\\([`\\$])/g, '$1');
}

/** Read a "..." string; i is just past the opening quote. */
function readDoubleQuoted(src, i) {
  let value = '';
  let dynamic = false;
  const substs = [];
  while (i < src.length) {
    const c = src[i];
    if (c === '"') return { value, dynamic, end: i + 1, substs };
    if (c === '\\') {
      const n = src[i + 1] ?? '';
      if ('"\\$`'.includes(n) && n) { value += n; i += 2; continue; }
      if (n === '\n') { i += 2; continue; }
      value += c; i += 1; continue;
    }
    if (c === '`') { const end = skipBackticks(src, i + 1); substs.push(backtickBody(src, i, end)); dynamic = true; i = end; continue; }
    if (c === '$') {
      const v = readDollar(src, i);
      value += v.value; dynamic ||= v.dynamic; i = v.end;
      if (v.subst !== undefined) substs.push(v.subst);
      continue;
    }
    value += c;
    i += 1;
  }
  throw new Error('unterminated double quote');
}

/** A `$...` expansion at i. $HOME is expanded; anything else is dynamic. */
function readDollar(src, i) {
  const n = src[i + 1];
  if (n === '(') {
    const end = skipCommandSubst(src, i + 2);
    return { value: '$(...)', dynamic: true, end, subst: src.slice(i + 2, end - 1) };
  }
  if (n === '{') {
    if (src.startsWith('${HOME}', i)) return { value: homedir(), dynamic: false, end: i + 7 };
    return { value: '${...}', dynamic: true, end: skipBraceExpansion(src, i + 2) };
  }
  const m = src.slice(i + 1).match(/^([A-Za-z_][A-Za-z0-9_]*|[0-9@*#?$!-])/);
  if (!m) return { value: '$', dynamic: false, end: i + 1 };
  if (m[1] === 'HOME') return { value: homedir(), dynamic: false, end: i + 5 };
  return { value: '$' + m[1], dynamic: true, end: i + 1 + m[1].length };
}

/**
 * POSIX-shell tokenizer: words and the operators that separate commands. A word is
 * { type: 'word', value, dynamic, tilde, substs } — `dynamic` when part of it comes from
 * an expansion we can't evaluate, `tilde` when it starts with an unquoted `~`, `substs`
 * the bodies of any $(...), `...` or <(...) in it (code that runs, so it is walked too).
 */
export function tokenize(src) {
  const out = [];
  const heredocs = [];
  let word = null;
  let dynamic = false;
  let tilde = false;
  let substs = [];
  let hereString = false;
  const add = (s) => { if (word === null) tilde = false; word = (word ?? '') + s; };
  const push = () => {
    if (word !== null) out.push({ type: 'word', value: word, dynamic, tilde, substs, herestring: hereString });
    if (word !== null) hereString = false;
    word = null; dynamic = false; tilde = false; substs = [];
  };
  let i = 0;
  while (i < src.length) {
    const c = src[i];
    if (c === '\\') {
      if (src[i + 1] === '\n') { i += 2; continue; }
      if (i + 1 < src.length) add(src[i + 1]);
      i += 2;
      continue;
    }
    if (c === "'") { const end = skipSingleQuoted(src, i + 1); add(src.slice(i + 1, end - 1)); i = end; continue; }
    if (c === '"') { const r = readDoubleQuoted(src, i + 1); add(r.value); dynamic ||= r.dynamic; substs.push(...r.substs); i = r.end; continue; }
    if (c === '`') { const end = skipBackticks(src, i + 1); substs.push(backtickBody(src, i, end)); add('`...`'); dynamic = true; i = end; continue; }
    if (c === '$' && src[i + 1] === "'") {
      // ANSI-C quoting: literal unless it uses escapes we don't decode.
      const end = skipAnsiC(src, i + 2);
      const body = src.slice(i + 2, end - 1);
      add(body); dynamic ||= body.includes('\\'); i = end;
      continue;
    }
    if (c === '$') {
      const r = readDollar(src, i);
      add(r.value); dynamic ||= r.dynamic; i = r.end;
      if (r.subst !== undefined) substs.push(r.subst);
      continue;
    }
    if (c === '<' && src.startsWith('<<<', i)) { push(); hereString = true; i += 3; continue; } // next word is stdin
    if (c === '<' && src.startsWith('<<', i)) {
      push();
      const h = readHeredocDelim(src, i + 2);
      if (h.delim !== null) {
        heredocs.push(h);
        out.push({ type: 'word', value: '<<', dynamic: false, tilde: false, substs: [], heredoc: h });
      }
      i = h.end;
      continue;
    }
    if ((c === '<' || c === '>') && src[i + 1] === '(') { // process substitution: code that runs
      const end = skipCommandSubst(src, i + 2);
      substs.push(src.slice(i + 2, end - 1)); add(`${c}(...)`); dynamic = true; i = end;
      continue;
    }
    if (c === '\n') {
      push();
      // A trailing && / || / | continues the list onto the next line.
      const last = out[out.length - 1];
      if (!(last?.type === 'op' && ['&&', '||', '|'].includes(last.value))) out.push({ type: 'op', value: ';' });
      i = heredocs.length ? skipHeredocBodies(src, i + 1, heredocs) : i + 1;
      continue;
    }
    if (c === ';') {
      push();
      const arm = src.startsWith(';;&', i) ? 3 : src.startsWith(';;', i) || src.startsWith(';&', i) ? 2 : 0;
      out.push({ type: 'op', value: arm ? ';;' : ';' });
      i += arm || 1;
      continue;
    }
    if (c === '&' || c === '|') {
      push();
      const two = src.slice(i, i + 2);
      if (two === '&&' || two === '||') { out.push({ type: 'op', value: two }); i += 2; }
      else if (two === '|&') { out.push({ type: 'op', value: '|' }); i += 2; }
      else if (c === '&' && src[i + 1] === '>') { add('&>'); i += 2; } // &>file redirect
      else { out.push({ type: 'op', value: c }); i += 1; }
      continue;
    }
    if (c === '(' || c === ')') { push(); out.push({ type: 'op', value: c }); i += 1; continue; }
    if (c === '#' && word === null) { const j = src.indexOf('\n', i); i = j < 0 ? src.length : j; continue; }
    if (/\s/.test(c)) { push(); i += 1; continue; }
    if (c === '>' || c === '<') {
      // A redirection starts its own word, glued to its target (`>/dev/null`, `>&1`).
      push(); add(c); i += 1;
      if (src[i] === '&') { add('&'); i += 1; }
      continue;
    }
    if (c === '~' && word === null) { add('~'); tilde = true; i += 1; continue; }
    add(c);
    i += 1;
  }
  push();
  return out;
}

// ── Shell simulation ─────────────────────────────────────────────────────────

const OPENERS = new Set(['if', 'while', 'until', 'for', 'select', 'case']);
const CLOSERS = new Set(['fi', 'done', 'esac']);
const CONTINUERS = new Set(['then', 'else', 'elif', 'do', '!', 'time']);
const SHELLS = new Set(['bash', 'sh', 'zsh', 'dash']);
// git subcommands that can change which commit HEAD is (so the reviewed commit isn't the PR's).
const HEAD_MOVERS = new Set(['commit', 'merge', 'rebase', 'reset', 'cherry-pick', 'revert', 'pull', 'am', 'checkout', 'switch']);
const RUNNERS = new Set(['exec', 'env', 'sudo', 'nohup', 'xargs', 'nice', 'timeout']);
// Commands that never execute their arguments or stdin as shell code: a `gh pr create`
// mentioned in their input (a commit message, a file being written) is just text.
const DATA_SINKS = new Set(['cat', 'tee', 'echo', 'printf', 'git', 'gh', 'grep', 'egrep', 'fgrep', 'rg',
  'jq', 'head', 'tail', 'less', 'more', 'wc', 'sort', 'uniq', 'diff', 'cut', 'tr', 'base64', 'column',
  'touch', 'mkdir', 'ls', 'true', 'false', ':', 'test', '[', 'read', 'mapfile']);
// Script interpreters: a heredoc/stdin/file fed to them is nearly always a file edit, so a
// mention there is treated as data; inline code (-c/-e) that mentions gh pr create is opaque.
const INTERPRETERS = new Set(['python', 'python3', 'node', 'perl', 'ruby', 'php']);
const MENTION = /(^|[^A-Za-z0-9_-]|\\[nt])gh(\s|\\t)+pr(\s|\\t)+(create|new|ready)\b|markPullRequestReadyForReview/; // same boundary as the hook's pre-filter
// `git ... push` somewhere in text handed to a program the gate can't follow (ssh, awk, python -c, a non-literal
// command). Deliberately loose: it only decides whether to gate conservatively, never lets a push through.
const PUSH_MENTION = /(^|[^A-Za-z0-9_-])git([^A-Za-z0-9_-][\s\S]*?)?[^A-Za-z0-9_-]push([^A-Za-z0-9_-]|$)/;
// The GraphQL mutation that takes a PR out of draft: only `gh pr ready` may do that.
const READY_MUTATION = /markPullRequestReadyForReview/;
const API_CLIENTS = new Set(['curl', 'wget', 'http', 'https', 'xh']);
/** Index of an API client (`gh api`, curl, wget, httpie) in a command's words, or -1. */
function apiClientAt(words, from = 0) {
  return words.findIndex((w, i) => i >= from && !w.dynamic &&
    ((path.basename(w.value) === 'gh' && words[i + 1]?.value === 'api') || API_CLIENTS.has(path.basename(w.value))));
}
const DIR_WORD = /(^|[\s;&|(])(cd|pushd|popd)([\s;&|)]|$)/;
const ASSIGN = /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/s;
// Environment that makes git act on another repository or with injected config (which can change what a bare
// `git push` publishes): a push under it can't be checked against the directory's own HEAD.
const GIT_ENV = /^GIT_(DIR|WORK_TREE|CONFIG_COUNT|CONFIG_PARAMETERS|CONFIG_KEY_\d+|CONFIG_VALUE_\d+)=/;

/** Roughly what a pipeline element writes to stdout, over-approximated so nothing is
 * hidden: echo's words joined by spaces; printf's format text and then each argument on
 * its own line; `\n` escapes as newlines; any heredoc/here-string body; and whatever it
 * received on its own stdin (pass-through filters: `... | cat | bash`, `| tee f | sh`). */
function pipedText(cmd, stdin = null) {
  const c0 = cmd[0]?.value;
  let args = cmd.slice(1).filter((w) => !w.heredoc && !w.herestring && !/^\d*[<>]/.test(w.value));
  if (c0 === 'echo') while (args.length && /^-[neE]+$/.test(args[0].value)) args = args.slice(1); // echo's own flags
  const words = c0 === 'printf' ? args.map((w) => w.value).join('\n') : args.map((w) => w.value).join(' ');
  const bodies = cmd.flatMap((w) => (w.heredoc ? [w.heredoc.body ?? ''] : w.herestring ? [w.value] : []));
  return [words.replace(/\\n/g, '\n').replace(/\\t/g, '\t'), ...bodies, stdin].filter(Boolean).join('\n');
}

/**
 * Does an awk program run commands? With string and regex literals blanked out, that is
 * system(...) or a lone `|` (not `||`): `print x | "sh"`, `"cmd" | getline`,
 * `("cmd") | getline`, `|&`. A bare getline only reads input.
 */
export function awkRuns(program) {
  const code = program.replace(/"(\\.|[^"\\])*"/g, '""').replace(/\/(\\.|[^/\\\n])+\//g, '//');
  return /system\s*\(|(^|[^|])\|(?!\|)/.test(code); // piped getline has a lone | too; bare getline reads input
}

// Runner options that take a separate value (so the value isn't read as the executable).
// Per runner: short options that take a value (attached `-uroot` or as the next word) and
// long options that take one as the next word (`--opt=value` is a single word anyway).
const RUNNER_VALUE_OPTS = {
  timeout: { short: 'sk', long: ['--signal', '--kill-after'] },
  env: { short: 'uCS', long: ['--unset', '--chdir', '--split-string'] },
  sudo: { short: 'ughpCDrtUT', long: ['--user', '--group', '--host', '--prompt', '--close-from', '--chdir', '--role', '--type', '--other-user', '--command-timeout'] },
  nice: { short: 'n', long: ['--adjustment'] },
  exec: { short: 'a', long: [] },
  nohup: { short: '', long: [] },
};

/**
 * Where does a runner (`timeout 60`, `env -C d X=y`, `sudo -u u`, `nice -n 5`, `nohup`,
 * `exec`) put the program it launches? Returns { k, chdir, assigns } with k the index of the
 * executable, or null when that can't be told (a dynamic word, `env -S`, xargs): callers then
 * fall back to scanning every argument.
 */
export function runnerExec(cmd) {
  const c0 = progName(cmd[0]);
  if (!(c0 in RUNNER_VALUE_OPTS)) return null;
  const assigns = [];
  let chdir = false;
  let i = 1;
  const { short, long } = RUNNER_VALUE_OPTS[c0];
  const chdirOpt = c0 === 'env' ? 'C' : c0 === 'sudo' ? 'D' : null;
  let endOfOpts = false;
  for (; i < cmd.length; i++) {
    const w = cmd[i];
    const v = w.value;
    if (w.dynamic) return null;
    if (c0 === 'env' && ASSIGN.test(v)) { assigns.push(w); continue; } // also after `--`
    if (endOfOpts) break;
    if (v === '--') { endOfOpts = true; continue; }
    if (c0 === 'env' && v === '-') continue; // `env -` is `env -i`
    if (!v.startsWith('-')) break;
    if (c0 === 'nice' && /^-\d+$/.test(v)) continue;
    if (v.startsWith('--')) {
      const name = v.split('=')[0];
      if (c0 === 'env' && name === '--split-string') return null; // runs a string
      if (name === '--chdir') chdir = true;
      if (long.includes(name) && !v.includes('=')) i += 1;
      continue;
    }
    // A short-option cluster: a value-taking letter takes the rest of the word (`-uroot`,
    // `-iCdir`) or, at the end of the word, the next word (`-u root`, `-iC dir`).
    for (let j = 1; j < v.length; j++) {
      const ch = v[j];
      if (!short.includes(ch)) continue;
      if (c0 === 'env' && ch === 'S') return null; // runs a string
      if (ch === chdirOpt) chdir = true;
      if (j === v.length - 1) i += 1;
      break;
    }
  }
  if (c0 === 'timeout') { // DURATION comes before the command
    if (i >= cmd.length || cmd[i].dynamic) return null;
    i += 1;
  }
  if (i >= cmd.length) return null;
  return { k: i, chdir, assigns };
}

// Shell builtins keep their exact name (`/usr/bin/cd` doesn't move the shell); any other
// program is classified by its basename, so `/usr/bin/git`, `/bin/bash -c`,
// `/usr/bin/timeout` are handled like `git`, `bash -c`, `timeout`.
const BUILTINS = new Set(['cd', 'pushd', 'popd', 'eval', 'source', '.', 'export', 'declare', 'local', 'command', 'builtin', 'exec']);
export function progName(word) {
  const v = word?.value ?? '';
  const base = path.basename(v);
  return v.includes('/') && BUILTINS.has(base) ? v : base;
}

function isGhPrCreate(words) {
  // `gh pr new` is gh's built-in alias of `gh pr create`; `gh pr ready` marks a draft ready.
  // ...and gh may be invoked by path (/usr/bin/gh, ./bin/gh).
  return words.length >= 3 && !words[0].dynamic && path.basename(words[0].value) === 'gh' && words[1].value === 'pr' &&
    (words[2].value === 'create' || words[2].value === 'new' || words[2].value === 'ready');
}
const subOf = (w) => (w.value === 'ready' ? 'ready' : 'create');

/**
 * Walk the command, simulating the shell's working directory, and collect every
 * `gh pr create` in command position as { dir, args, ghRepo } (dir null = unknown).
 */
export function findPrCreates(command, cwd, env = process.env, inherit = {}) {
  const tokens = tokenize(command);
  const newScope = (from) => ({
    dir: from.dir,
    dirStack: [...from.dirStack],
    ghRepo: from.ghRepo,
    cdpath: from.cdpath,
    gitEnv: from.gitEnv, // GIT_DIR/GIT_WORK_TREE/GIT_CONFIG_* set in this shell: git may act on another repo/config
    pendingCond: false, // a `&& cd` ran in the current and-or list
    listStart: { dir: from.dir, dirStack: [...from.dirStack] },
  });
  const scopes = [newScope({
    dir: cwd,
    dirStack: [],
    ghRepo: inherit.ghRepo !== undefined ? inherit.ghRepo : (env.GH_REPO || undefined),
    cdpath: inherit.cdpath ?? Boolean(env.CDPATH),
    gitEnv: inherit.gitEnv ?? Object.keys(env).some((k) => GIT_ENV.test(`${k}=`)),
  })];
  // A push changes the remote, not the shell, so it isn't scoped to a subshell.
  const pushes = inherit.pushes ?? []; // shared with nested scripts, so their pushes count too
  const headMoves = inherit.headMoves ?? []; // git commands that change HEAD's commit (shared too)
  // Every `git push` that runs, wherever it runs (shared with nested scripts too), for the pre-push gate:
  // { dir (null = unknown), args, moves (head-moving git commands before it), why (a reason to block) }.
  const gitPushes = inherit.gitPushes ?? [];
  let pipeText = null; // what the previous pipeline element feeds on stdin
  const braces = [];
  let cond = 0;
  let funcDepth = 0;
  let caseDepth = 0;
  let casePattern = false; // next `)` ends a case pattern (after `in`, `;;` or `;&`)
  let funcPending = false;
  let prevOp = ';';
  let words = [];
  const found = [];
  found.gitPushes = gitPushes;
  const scope = () => scopes[scopes.length - 1];
  // A `git push` passed to something the gate can't follow (ssh, awk system(), python -c): gated in `dir`.
  const opaquePush = (what, dir) => { found.opaquePush ??= { what, dir: funcDepth > 0 ? null : dir }; };

  // Code that runs in a subshell ($(...), `...`, <(...), bash -c, eval): gate any
  // gh pr create inside it, starting from the current directory.
  const nested = (script, dir, ghRepo = scope().ghRepo) => {
    const s = scope();
    // A function body runs later, from wherever it's called: everything in it has an unknown directory.
    const inner = findPrCreates(script, funcDepth > 0 ? null : dir, env, { ghRepo, cdpath: s.cdpath, gitEnv: s.gitEnv, pushes, headMoves, gitPushes });
    for (const h of inner) found.push({ ...h, dir: funcDepth > 0 ? null : h.dir });
    if (inner.opaque) found.opaque = inner.opaque;
    if (inner.opaquePush) found.opaquePush ??= inner.opaquePush;
    if (inner.readyMutation) found.readyMutation = true;
  };
  const opaque = (why) => { found.opaque ??= why; };

  const applyDirCommand = (cmd, pipelined) => {
    const s = scope();
    const [w0, ...rest] = cmd;
    if (pipelined) return; // a pipeline/background element runs in a subshell
    if (cond > 0 || prevOp === '||') { s.dir = null; return; } // may or may not run
    if (prevOp === '&&') s.pendingCond = true; // only runs if the list so far succeeded
    const args = rest.filter((w) => !/^-[LPe@]+$/.test(w.value) && w.value !== '--');
    const arg = args[0];
    const target = () => {
      if (!arg) return homedir();
      if (arg.dynamic || arg.value === '-') return null;
      let p = arg.value;
      if (arg.tilde && (p === '~' || p.startsWith('~/'))) p = homedir() + p.slice(1);
      else if (arg.tilde) return null; // ~user
      if (path.isAbsolute(p)) return path.resolve(p);
      if (s.dir === null || s.cdpath) return null;
      return path.resolve(s.dir, p);
    };
    if (w0.value === 'cd') { s.dir = target(); return; }
    if (w0.value === 'pushd') {
      if (!arg || /^[+-]\d+$/.test(arg.value)) { s.dir = null; return; }
      const next = target();
      s.dirStack.push(s.dir);
      s.dir = next;
      return;
    }
    // popd
    if (arg) { s.dir = null; return; }
    s.dir = s.dirStack.length ? s.dirStack.pop() : null;
  };

  const recordPush = (cmd, base = scope().dir, envRepo = false) => {
    // `git [-C dir] push [opts] <remote> <src>:<dst> ...` — lets `--head <dst>` be checked at
    // <src> even though the push (and its remote-tracking ref) hasn't happened yet.
    let k = 1;
    let gdir = base;
    let otherRepo = envRepo || scope().gitEnv; // GIT_DIR=/--git-dir/--work-tree: the repo isn't the directory's
    const config = []; // `-c key=value` overrides: they can change what a bare `git push` publishes
    while (k < cmd.length && cmd[k].value.startsWith('-')) {
      const v = cmd[k].value;
      if (v === '-C') {
        const d = cmd[k + 1];
        gdir = !d || d.dynamic ? null : path.isAbsolute(d.value) ? d.value : gdir === null ? null : path.resolve(gdir, d.value);
        k += 2;
        continue;
      }
      if (/^--(git-dir|work-tree)(=|$)/.test(v)) otherRepo = true;
      if (v === '-c') config.push(cmd[k + 1] ?? { value: '', dynamic: true });
      if (v.startsWith('--config-env')) config.push({ value: 'config-env', dynamic: true });
      k += ['-c', '--git-dir', '--work-tree', '--namespace', '--config-env'].includes(v) ? 2 : 1;
    }
    const sub = cmd[k]?.dynamic ? null : cmd[k]?.value;
    if (cmd[k]?.dynamic) { // `git $SUB ...` may be a push: never let it through unchecked
      gitPushes.push({ dir: gdir, args: [], moves: [], why: `\`git ${cmd[k].value}\` has a non-literal subcommand, so the gate can't tell whether it pushes. Spell it out: \`git push ...\`` });
      return;
    }
    if (sub && HEAD_MOVERS.has(sub)) {
      // Creating a branch at HEAD (`checkout -b x`, `switch -c x`) keeps the commit.
      const rest = cmd.slice(k + 1).map((w) => w.value);
      const newBranchAtHead = (sub === 'checkout' || sub === 'switch') &&
        rest.some((v) => /^-[bBcC]$/.test(v)) && rest.filter((v) => !v.startsWith('-')).length <= 1;
      const restoreFiles = sub === 'checkout' && rest.includes('--');
      if (!newBranchAtHead && !restoreFiles) headMoves.push({ dir: gdir, sub });
      return;
    }
    if (sub !== 'push') return;
    gitPushes.push({ dir: otherRepo ? null : gdir, args: cmd.slice(k + 1), moves: headMoves.filter((m) => !m.pushOnly), config,
      why: otherRepo ? '`git push` names another repository or injects git config (GIT_DIR, GIT_CONFIG_*, --git-dir or --work-tree), so the gate can\'t tell which commit it pushes. Run it from the checkout: `cd /path/to/checkout && git push ...`' : null });
    headMoves.push({ dir: gdir, sub, pushOnly: true }); // moves the PR's head, not local HEAD
    const positional = [];
    const rest = cmd.slice(k + 1);
    let remoteGiven = false; // `--repo <remote>` means every positional is a refspec
    for (let j = 0; j < rest.length; j++) {
      const v = rest[j].value;
      if (v === '--') { positional.push(...rest.slice(j + 1)); break; }
      if (v === '--repo' || v.startsWith('--repo=')) { remoteGiven = true; if (v === '--repo') j += 1; continue; }
      if (v.startsWith('-')) { if (['-o', '--push-option', '--receive-pack', '--exec'].includes(v)) j += 1; continue; }
      positional.push(rest[j]);
    }
    for (const spec of remoteGiven ? positional : positional.slice(1)) {
      if (spec.dynamic || gdir === null) continue;
      const r = spec.value.replace(/^\+/, '');
      const [src, dst] = r.includes(':') ? [r.slice(0, r.indexOf(':')), r.slice(r.indexOf(':') + 1)] : [r, r];
      if (src && dst) pushes.push({ dir: gdir, src, dst: dst.replace(/^refs\/heads\//, '') });
    }
  };

  const flush = (nextOp) => {
    let cmd = words;
    words = [];
    const fromPipe = prevOp === '|' ? pipeText : null;
    pipeText = nextOp === '|' ? pipedText(cmd, fromPipe) : null;
    for (const w of cmd) {
      for (const body of w.substs ?? []) nested(body, scope().dir);
      for (const body of w.heredoc?.substs ?? []) nested(body, scope().dir);
    }
    const pipelined = prevOp === '|' || prevOp === '&' || nextOp === '|' || nextOp === '&';
    // Reserved words and brace groups.
    while (cmd.length && !cmd[0].dynamic) {
      const v = cmd[0].value;
      if (OPENERS.has(v)) {
        cond += 1;
        if (v === 'case') { caseDepth += 1; casePattern = true; cmd = []; break; } // `case x in` header
        if (v === 'for' || v === 'select') { cmd = []; break; } // `for x in ...` header
        cmd = cmd.slice(1);
      } else if (CLOSERS.has(v)) {
        cond = Math.max(0, cond - 1);
        if (v === 'esac') { caseDepth = Math.max(0, caseDepth - 1); casePattern = false; }
        cmd = cmd.slice(1);
      } else if (CONTINUERS.has(v)) {
        if (v !== '!' && v !== 'time') prevOp = ';'; // first command of a body isn't &&-chained
        cmd = cmd.slice(1);
      } else if (v === 'function') {
        funcPending = true;
        cmd = cmd.slice(2);
      } else if (v === '{') {
        const isFunc = funcPending;
        // `x && { cd d; gh pr create; }`: inside the group its cds hold; after it, the
        // directory is unknown if the group changed it (it may not have run).
        const conditional = !isFunc && (prevOp === '&&' || prevOp === '||');
        braces.push({ kind: isFunc ? 'func' : conditional ? 'cond' : 'group', startDir: scope().dir });
        if (isFunc) { cond += 1; funcDepth += 1; funcPending = false; }
        prevOp = ';';
        cmd = cmd.slice(1);
      } else if (v === '}') {
        const b = braces.pop();
        if (b?.kind === 'func') { cond = Math.max(0, cond - 1); funcDepth = Math.max(0, funcDepth - 1); }
        if (b?.kind === 'cond' && scope().dir !== b.startDir) scope().dir = null;
        cmd = cmd.slice(1);
      } else {
        break;
      }
    }
    // Leading assignments: `VAR=x cmd` (prefix) or a bare `VAR=x` (sets it in this shell).
    const assigns = [];
    while (cmd.length && ASSIGN.test(cmd[0].value)) { assigns.push(cmd[0]); cmd = cmd.slice(1); }
    const s = scope();
    const note = (w, bare) => {
      const [, name, value] = w.value.match(ASSIGN);
      if (name === 'CDPATH' && bare) s.cdpath = true;
      if (bare && GIT_ENV.test(w.value)) s.gitEnv = true; // `export GIT_DIR=...` / `GIT_DIR=...; git push`
      if (name === 'GH_REPO' && bare) s.ghRepo = w.dynamic ? null : value;
    };
    for (const w of assigns) note(w, cmd.length === 0);
    if (!cmd.length) return;
    if (cmd[0].value === 'export' || cmd[0].value === 'declare' || cmd[0].value === 'local') {
      for (const w of cmd.slice(1)) if (ASSIGN.test(w.value)) note(w, true);
      return;
    }
    // `command gh pr create` / `builtin cd x` run the same thing as without the prefix.
    if ((cmd[0].value === 'command' || cmd[0].value === 'builtin') && !cmd[0].dynamic && cmd[1]) cmd = cmd.slice(1);
    // Runners launch another program: unwrap them (`timeout 60 git push`, `env -C d X=y gh pr
    // ready`, `sudo -u u bash -c ...`) so the program they run is classified like any other.
    // `env -C`/`sudo -D` run it elsewhere, so its directory is unknown.
    let wrapped = false;
    let runnerChdir = false;
    const unwrapped = cmd;
    for (let r = runnerExec(cmd); r && !cmd[0].dynamic; r = runnerExec(cmd)) {
      wrapped = true;
      if (r.chdir) runnerChdir = true;
      assigns.push(...r.assigns);
      cmd = cmd.slice(r.k);
    }
    // Safety net: a runner parse can only add checks, never lose one. If the parsed program
    // isn't the `gh pr` / `git` command the old argument scan would have found, gate that one
    // too, the old way (directory unknown if any word looks like a chdir option; the last
    // GH_REPO= among the words before it).
    if (wrapped) {
      const kPr = unwrapped.findIndex((w, idx) => idx > 0 && isGhPrCreate(unwrapped.slice(idx)));
      if (kPr > 0 && unwrapped.length - kPr !== cmd.length) {
        const pre = unwrapped.slice(1, kPr);
        const anyChdir = runnerChdir || pre.some((w) => /^(--chdir|-[A-Za-z]*[CD])/.test(w.value));
        const repoW = pre.filter((w) => w.value.startsWith('GH_REPO=')).pop() ?? assigns.filter((w) => w.value.startsWith('GH_REPO=')).pop();
        found.push({
          dir: anyChdir || funcDepth > 0 ? null : s.dir,
          sub: subOf(unwrapped[kPr + 2]),
          args: unwrapped.slice(kPr + 3),
          ghRepo: repoW ? (repoW.dynamic ? null : repoW.value.slice('GH_REPO='.length)) : s.ghRepo,
          pushes: [...pushes],
          headMoves: [...headMoves],
        });
      }
      const kGit = unwrapped.findIndex((w, idx) => idx > 0 && !w.dynamic && progName(w) === 'git');
      if (kGit > 0 && unwrapped.length - kGit !== cmd.length) recordPush(unwrapped.slice(kGit), null);
    }
    // The context the command really runs in, used by every branch below: its directory, and
    // GH_REPO from prefix/env assignments (the last one wins, as in env and the shell).
    const here = runnerChdir || funcDepth > 0 ? null : s.dir; // a function body runs later, from wherever it's called
    const repoAssign = assigns.filter((w) => w.value.startsWith('GH_REPO=')).pop();
    const ghRepoHere = repoAssign ? (repoAssign.dynamic ? null : repoAssign.value.slice('GH_REPO='.length)) : s.ghRepo;
    if (wrapped && ['cd', 'pushd', 'popd'].includes(cmd[0].value)) return; // not a builtin there: can't move us
    if (assigns.some((w) => w.value.startsWith('CDPATH=')) && ['cd', 'pushd'].includes(cmd[0].value)) { s.dir = null; return; }
    if (isGhPrCreate(cmd)) {
      found.push({
        dir: here,
        sub: subOf(cmd[2]),
        args: cmd.slice(3),
        ghRepo: ghRepoHere,
        pushes: [...pushes],
        headMoves: [...headMoves],
      });
      return;
    }
    // A command word built from an expansion ($X, $(...)) is opaque. Deliberately hiding
    // a `cd` that way is out of scope for this speed-bump; see the README.
    const stdinCode = cmd.flatMap((w) => (w.heredoc ? [w.heredoc.body ?? ''] : w.herestring ? [w.value] : []));
    const mentioned = () => cmd.some((w) => MENTION.test(w.heredoc ? w.heredoc.body ?? '' : w.value));
    // A `git push` in this command's words or in the text it is handed (to run somewhere the gate can't follow).
    const pushMentioned = () => PUSH_MENTION.test(cmd.map((w) => (w.heredoc ? w.heredoc.body ?? '' : w.value)).join(' ')) ||
      (fromPipe !== null && PUSH_MENTION.test(fromPipe));
    if (cmd[0].dynamic) {
      if (mentioned()) opaque(`\`${cmd[0].value}\` (a non-literal command)`);
      if (pushMentioned()) opaquePush(`\`${cmd[0].value}\` (a non-literal command)`, here);
      return;
    }
    const c0 = progName(cmd[0]);
    if (c0 === 'cd' || c0 === 'pushd' || c0 === 'popd') { applyDirCommand(cmd, pipelined); return; }
    if (c0 === 'git') { recordPush(cmd, here, assigns.some((w) => GIT_ENV.test(w.value))); return; }
    // An API client (runners already unwrapped above) that sends the ready mutation in its
    // arguments, a heredoc, a here-string or a pipe. Only for a runner whose arguments can't be
    // parsed is every argument scanned for a client, and then a `gh pr create|ready` among its
    // words wins (the RUNNERS branch below gates it).
    const runnerRunsPr = RUNNERS.has(c0) && cmd.some((w, idx) => idx > 0 && isGhPrCreate(cmd.slice(idx)));
    const client = API_CLIENTS.has(path.basename(c0)) || (path.basename(c0) === 'gh' && cmd[1]?.value === 'api') ? 0
      : RUNNERS.has(c0) && !runnerRunsPr ? apiClientAt(cmd, 1) : -1;
    if (client >= 0) {
      if (cmd.slice(client + 1).some((w) => READY_MUTATION.test(w.heredoc ? w.heredoc.body ?? '' : w.value)) ||
        (fromPipe !== null && READY_MUTATION.test(fromPipe))) found.readyMutation = true;
      return;
    }
    if (c0 === 'eval') {
      // eval runs in this shell. Walk its script even when part of it is an expansion ($X
      // stays a dynamic word); a cd in it isn't modelled, so the directory becomes unknown.
      const args = cmd.slice(1).filter((w) => !w.heredoc && !w.herestring);
      const script = args.map((w) => w.value).join(' ');
      nested(script, here, ghRepoHere);
      if (!pipelined && (args.some((w) => w.dynamic) || DIR_WORD.test(script))) s.dir = null;
      return;
    }
    const substMention = () => cmd.some((w) => (w.substs ?? []).some((b) => MENTION.test(b)));
    if (c0 === 'source' || c0 === '.') {
      // Runs in this shell: walk code on stdin (heredoc, here-string, a pipe into
      // `source /dev/stdin`); files can't be read, and <(...) output is opaque.
      const isRedirect = (w) => /^\d*[<>]/.test(w.value) && !/^[<>]\(/.test(w.value); // not <(...)
      const args = cmd.slice(1).filter((w) => !w.heredoc && !w.herestring && !isRedirect(w));
      const code = [...stdinCode, ...(fromPipe !== null && (!args.length || ['/dev/stdin', '-'].includes(args[0].value)) ? [fromPipe] : [])];
      for (const body of code) nested(body, here, ghRepoHere);
      if (substMention()) opaque(`${c0} <(...)`);
      if (!pipelined && (args.some((w) => w.dynamic) || code.some((b) => DIR_WORD.test(b)))) s.dir = null;
      return;
    }
    if (SHELLS.has(c0)) {
      // A child shell can't move us, but a gh pr create in its script still runs: walk a
      // -c script (even a partly dynamic one) or code on stdin (heredoc, here-string, pipe).
      const ci = cmd.findIndex((w, idx) => idx > 0 && /^-[A-Za-z]*c$/.test(w.value));
      if (ci > 0) { if (cmd[ci + 1]) nested(cmd[ci + 1].value, here, ghRepoHere); return; }
      let file = null;
      const rest = cmd.slice(1);
      for (let j = 0; j < rest.length; j++) {
        const w = rest[j];
        if (w.heredoc || w.herestring) continue;
        if (/^\d+$/.test(w.value) && /^[<>]/.test(rest[j + 1]?.value ?? '')) continue; // fd of `2>...`
        if (/^[<>]/.test(w.value) && !w.value.startsWith('<(')) { if (/^[<>]+&?$/.test(w.value)) j += 1; continue; } // redirect
        if (/^[-+][A-Za-z]*[oO]$|^--(rcfile|init-file)$/.test(w.value)) { j += 1; continue; } // -o / -euo / -O take a value
        if (/^[-+]/.test(w.value)) continue;
        file = w;
        break;
      }
      if (file) { if (mentioned() || substMention()) opaque(`${c0} ${file.value}`); return; } // a script we can't read
      for (const body of [...stdinCode, ...(fromPipe !== null ? [fromPipe] : [])]) nested(body, here, ghRepoHere);
      return;
    }
    if (INTERPRETERS.has(c0)) {
      const inline = cmd.findIndex((w, idx) => idx > 0 && /^-[A-Za-z]*[ce]$/.test(w.value));
      if (inline > 0 && MENTION.test(cmd[inline + 1]?.value ?? '')) opaque(`${c0} ${cmd[inline].value}`);
      if (inline > 0 && PUSH_MENTION.test(cmd[inline + 1]?.value ?? '')) opaquePush(`${c0} ${cmd[inline].value}`, here);
      return;
    }
    // A program that launches `git ...` from its arguments (`xargs git push`, `op run -- git push`, `ssh host git
    // push`): gate the push here, conservatively. Data sinks (echo, grep, ...) never run their arguments.
    const kGitArg = DATA_SINKS.has(c0) || c0 === 'awk' || c0 === 'gawk' || c0 === 'sed' ? -1
      : cmd.findIndex((w, idx) => idx > 0 && !w.dynamic && progName(w) === 'git');
    if (kGitArg > 0) {
      const chdir = RUNNERS.has(c0) && cmd.slice(1, kGitArg).some((w) => /^(--chdir|-[A-Za-z]*[CD])/.test(w.value));
      recordPush(cmd.slice(kGitArg), chdir ? null : here);
    }
    if (RUNNERS.has(c0)) {
      // `timeout 60 gh pr create ...`, `env -C dir GH_REPO=o/r gh pr create ...`
      const k = cmd.findIndex((w, idx) => idx > 0 && isGhPrCreate(cmd.slice(idx)));
      if (k > 0) {
        const pre = cmd.slice(1, k);
        const chdir = c0 === 'env' && pre.some((w) => /^(--chdir|-[A-Za-z]*C)/.test(w.value));
        const repoArg = c0 === 'env' ? pre.filter((w) => w.value.startsWith('GH_REPO=')).pop() : undefined;
        found.push({
          dir: chdir ? null : here,
          sub: subOf(cmd[k + 2]),
          args: cmd.slice(k + 3),
          ghRepo: repoArg ? (repoArg.dynamic ? null : repoArg.value.slice('GH_REPO='.length)) : ghRepoHere,
          pushes: [...pushes],
        headMoves: [...headMoves],
        });
        return;
      }
    }
    // sed/awk only run commands via awk system()/print|"cmd" or sed's e command/flag.
    if (c0 === 'awk' || c0 === 'gawk' || c0 === 'sed') {
      const sedRuns = /(^|[;{}\s])e(\s|;|$)|\/[A-Za-z0-9]*e[A-Za-z0-9]*(\s|;|}|$)/;
      if (pushMentioned()) { // conservative: any awk/sed text that mentions git push may run it
        const runs = c0 === 'sed' ? cmd.slice(1).some((w) => sedRuns.test(w.value)) : cmd.slice(1).some((w) => awkRuns(w.value));
        if (runs) opaquePush(c0, here);
      }
      if (!mentioned()) return;
      if (c0 === 'sed') { if (cmd.slice(1).some((w) => sedRuns.test(w.value))) opaque(c0); return; }
      // awk: judge only the program text, not options like -F'|' or -v x=y.
      const args = cmd.slice(1).filter((w) => !w.heredoc && !w.herestring && !/^\d*[<>]/.test(w.value));
      let program = null;
      for (let j = 0; j < args.length; j++) {
        const v = args[j].value;
        if (v === '--') { program = args[j + 1] ?? null; break; }
        if (v === '-f' || v.startsWith('-f')) { opaque(`${c0} -f`); return; } // program in a file we can't read
        if (/^-[Fv]$/.test(v)) { j += 1; continue; }
        if (/^-[A-Za-z]/.test(v) || v.startsWith('--')) continue;
        program = args[j];
        break;
      }
      if (program && awkRuns(program.value)) opaque(c0);
      return;
    }
    if (DATA_SINKS.has(c0)) return;
    // Any other command whose arguments contain `gh pr create` as words runs it like a
    // runner would: `op run -- gh pr create`, `doppler run -- gh pr create`, `ssh host
    // gh pr create` (gated against the local checkout, conservatively).
    const k = cmd.findIndex((w, idx) => idx > 0 && isGhPrCreate(cmd.slice(idx)));
    if (k > 0) {
      found.push({ dir: here, sub: subOf(cmd[k + 2]), args: cmd.slice(k + 3), ghRepo: ghRepoHere, pushes: [...pushes], headMoves: [...headMoves] });
      return;
    }
    // Otherwise, anything that receives `gh pr create` (in one argument, split across
    // arguments, a heredoc or a pipe) might run it. Script interpreters were handled above.
    const joined = cmd.slice(1).filter((w) => !w.heredoc).map((w) => w.value).join(' ');
    if (mentioned() || MENTION.test(joined) || (fromPipe !== null && MENTION.test(fromPipe))) opaque(c0);
    if (kGitArg < 0 && pushMentioned()) opaquePush(c0, here);
  };

  const endList = (op) => {
    const s = scope();
    if (op === '&') { s.dir = s.listStart.dir; s.dirStack = [...s.listStart.dirStack]; } // a background list is a subshell
    else if (s.pendingCond) s.dir = null; // the `&& cd` may not have run
    s.pendingCond = false;
    s.listStart = { dir: s.dir, dirStack: [...s.dirStack] };
  };

  for (let k = 0; k < tokens.length; k++) {
    const t = tokens[k];
    if (t.type === 'word') { words.push(t); continue; }
    const op = t.value;
    if (op === '(' || op === ')') {
      if (caseDepth === 0 && words.length && !words[0].dynamic && words[0].value === 'case') {
        flush(';'); prevOp = ';'; // `case x in y)` / `case x in (y)`: header + first pattern
        if (op === ')') casePattern = false;
        continue;
      }
      if (caseDepth > 0 && casePattern) { // pattern position: `(y)` / `y)` / `a|b)`
        if (op === ')') { words = []; prevOp = ';'; casePattern = false; }
        continue;
      }
      if (op === '(' && tokens[k + 1]?.value === ')' && words.length === 1) {
        funcPending = true; words = []; k += 1; continue; // `name()` function definition
      }
      flush(op);
      if (op === '(') scopes.push(newScope(scope()));
      else if (scopes.length > 1) scopes.pop();
      prevOp = ';';
      continue;
    }
    if (OPS.has(op)) {
      flush(op);
      if (op === ';' || op === ';;' || op === '&') endList(op === '&' ? '&' : ';');
      if (op === ';;' && caseDepth > 0) casePattern = true;
      prevOp = op === ';;' ? ';' : op;
    }
  }
  flush(';');
  return found;
}

// ── gh arguments ─────────────────────────────────────────────────────────────

// `gh pr create` flags that take a value (so their value is never read as a flag).
const VALUE_LONG = new Set(['--assignee', '--base', '--body', '--body-file', '--label', '--milestone',
  '--project', '--reviewer', '--title', '--template', '--head', '--repo', '--recover']);
const VALUE_SHORT = new Set(['a', 'B', 'b', 'F', 'l', 'm', 'p', 'r', 't', 'T', 'H', 'R']);
const KEY = { H: 'head', R: 'repo', '--head': 'head', '--repo': 'repo' };

const BOOL_FALSE = /^(false|0|f)$/i;

/** Pull -R/--repo, -H/--head, -h/--help, -d/--draft, --undo and the first positional
 * (`gh pr ready <number|url|branch>`) out of `gh pr create|ready` args (pflag rules). */
export function parseGhArgs(args, sub = 'create') {
  const out = { repo: undefined, head: undefined, help: false, draft: false, undo: false, selector: undefined, opaque: null };
  const valueLong = sub === 'ready' ? new Set(['--repo']) : VALUE_LONG;
  const valueShort = sub === 'ready' ? new Set(['R']) : VALUE_SHORT;
  const set = (key, w, value) => { if (key) out[key] = w && !w.dynamic ? value : null; };
  for (let i = 0; i < args.length; i++) {
    const w = args[i];
    const v = w.value;
    if (w.dynamic && !v.startsWith('-')) { out.opaque ??= v; continue; } // could expand to --repo/--head
    if (w.dynamic && /^--?(d|draft|undo)\b/.test(v)) { out.opaque ??= v; continue; } // --draft=$X
    if (v === '--') { if (args[i + 1] && out.selector === undefined) out.selector = args[i + 1].value; break; }
    if (v === '--help' || v === '-h') { out.help = true; continue; }
    if (v.startsWith('--')) {
      const eq = v.indexOf('=');
      const name = eq < 0 ? v : v.slice(0, eq);
      if (name === '--draft' && sub === 'create') { out.draft = eq < 0 || !BOOL_FALSE.test(v.slice(eq + 1)); continue; }
      if (name === '--undo' && sub === 'ready') { out.undo = eq < 0 || !BOOL_FALSE.test(v.slice(eq + 1)); continue; }
      if (!valueLong.has(name)) continue;
      if (eq >= 0) set(KEY[name], w, v.slice(eq + 1));
      else { const nx = args[++i]; set(KEY[name], nx, nx?.value); }
      continue;
    }
    if (/^-[A-Za-z]/.test(v)) {
      for (let j = 1; j < v.length; j++) {
        const ch = v[j];
        if (ch === 'h') { out.help = true; continue; }
        if (ch === 'd' && sub === 'create') {
          if (w.dynamic) { out.opaque ??= v; break; } // -fd=$DRAFT: can't tell if it's a draft
          if (v[j + 1] === '=') { out.draft = !BOOL_FALSE.test(v.slice(j + 2)); break; } // -d=false
          out.draft = true;
          continue;
        }
        if (!valueShort.has(ch)) continue; // boolean shorthand like -f / -w
        let rest = v.slice(j + 1);
        if (rest.startsWith('=')) rest = rest.slice(1);
        if (rest) set(KEY[ch], w, rest);
        else { const nx = args[++i]; set(KEY[ch], nx, nx?.value); }
        break;
      }
      continue;
    }
    if (out.selector === undefined) out.selector = v; // positional: `gh pr ready 12`
  }
  return out;
}

/** "owner/repo" (lowercased) from a remote URL or a gh `[HOST/]OWNER/REPO` value. */
export function repoSlug(value) {
  const cleaned = String(value).trim().replace(/\.git$/i, '').replace(/\/+$/, '');
  const m = cleaned.match(/([^/:]+)\/([^/:]+)$/);
  return m ? `${m[1]}/${m[2]}`.toLowerCase() : null;
}

// ── Resolution ───────────────────────────────────────────────────────────────

function git(dir, ...args) {
  try {
    return execFileSync('git', ['-C', dir, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  } catch {
    return null;
  }
}

// Used only when the command can't be parsed: does falling back to the session cwd risk
// checking the wrong repo (it changes directory or names a repo/branch)?
const RISKY = /(^|[\s;&|(){}'"`])(cd|pushd|popd)(\s|$)|(^|\s)(--repo|--head)([\s=]|$)|(^|\s)-[A-Za-z]*[RH]|GH_REPO|CDPATH/;

// `gh pr view` for `gh pr ready`: the PR's head commit and branch. REVIEW_GATE_GH lets the
// tests use a fake gh.
function prHead(dir, selector, repo) {
  const args = ['pr', 'view', ...(selector !== undefined ? [selector] : []), '--json', 'headRefOid,headRefName',
    ...(repo ? ['--repo', repo] : [])];
  try {
    const out = execFileSync(process.env.REVIEW_GATE_GH || 'gh', args,
      { cwd: dir, encoding: 'utf8', timeout: 20000, stdio: ['ignore', 'pipe', 'ignore'] });
    const j = JSON.parse(out);
    return /^[0-9a-f]{40}$/.test(j.headRefOid ?? '') ? { oid: j.headRefOid, branch: j.headRefName } : null;
  } catch {
    return null;
  }
}

function worktreeFor(dir, branch) {
  return (git(dir, 'worktree', 'list', '--porcelain') ?? '').split('\n\n').map((block) => ({
    path: block.match(/^worktree (.+)$/m)?.[1],
    branch: block.match(/^branch refs\/heads\/(.+)$/m)?.[1],
  })).find((w) => w.branch === branch && w.path)?.path ?? null;
}

function resolveOne(hit) {
  const sub = hit.sub ?? 'create';
  const what = `\`gh pr ${sub}\``;
  const { repo: flagRepo, head, help, draft, undo, selector, opaque } = parseGhArgs(hit.args, sub);
  if (help) return { help: true };
  if (opaque) return { block: `${what} has a non-literal argument (${opaque}) that could change which PR or repo it acts on; pass it literally` };
  // Never gated, wherever they run: a draft PR is how the reviewers get to see it.
  if (sub === 'create' && draft) return { help: true };
  if (sub === 'ready' && undo) return { help: true }; // back to draft
  if (hit.dir === null) {
    return { block: `can't tell which repo a ${what} runs in: a \`cd\` before it isn't a literal path, or only runs conditionally. Use \`cd /literal/path && gh pr ${sub} ...\`` };
  }
  let dir = hit.dir;
  if (!existsSync(dir) || !statSync(dir).isDirectory()) {
    return { block: `${what} would run in ${dir}, which doesn't exist` };
  }
  let repo = flagRepo !== undefined ? flagRepo : hit.ghRepo;
  // `gh pr ready https://github.com/OWNER/REPO/pull/N` acts on the URL's repo, whatever
  // --repo/GH_REPO say: check that repo against the checkout like --repo.
  const urlRepo = sub === 'ready' && typeof selector === 'string' ? selector.match(/^https?:\/\/[^/]+\/([^/]+\/[^/]+)\/pull\/\d+/)?.[1] : undefined;
  if (urlRepo) repo = urlRepo;
  const notes = [];
  const top = git(dir, 'rev-parse', '--show-toplevel');
  if (top === null) {
    if (repo !== undefined || head !== undefined) {
      return { block: `${dir} isn't a git checkout, so the reviews behind this --repo/--head PR can't be verified. Run it from the checkout.` };
    }
    if (sub === 'ready') {
      return { block: `${dir} isn't a git checkout, so the reviews behind \`gh pr ready\` can't be verified. Run it from the PR's checkout.` };
    }
    return { target: { dir, rev: null, note: `${dir} isn't a git repo; not gated` } };
  }
  dir = top;

  const remoteSlugs = () => [...new Set((git(dir, 'remote', '-v') ?? '').split('\n')
    .map((l) => repoSlug(l.split(/\s+/)[1] ?? '')).filter(Boolean))];
  if (repo === null) notes.push('the PR repo is not a literal value, so the checkout was not matched against it');
  if (repo) {
    const want = repoSlug(repo);
    const have = remoteSlugs();
    if (!want || !have.includes(want)) {
      return {
        block: `the PR targets ${repo}, but ${dir} is a checkout of ${have.join(', ') || '(no remotes)'}. ` +
          `Run it from the target checkout so the gate checks that repo's reviews: cd <checkout of ${repo}> && gh pr ${sub} ...`,
      };
    }
  }

  // A commit made earlier in this same command (git commit/merge/rebase/pull...) is what
  // the PR will contain, but the hook runs before it exists, so it can't have been reviewed.
  const repoOf = (d) => (d ? git(d, 'rev-parse', '--path-format=absolute', '--git-common-dir') ?? git(d, 'rev-parse', '--show-toplevel') : null);
  const moved = (hit.headMoves ?? []).find((m) => (!m.pushOnly || sub === 'ready') &&
    (m.dir === null || repoOf(m.dir) === repoOf(dir)));
  if (moved?.pushOnly) {
    return { block: `\`git push\` runs before \`gh pr ready\` in the same command, so the PR's head would be a commit the gate can't look up yet. Push first, make sure the reviews cover the pushed commit, then run gh pr ready on its own.` };
  }
  if (moved) {
    return { block: `\`git ${moved.sub}\` runs before ${what} in the same command, so the PR would contain a commit that doesn't exist yet and can't have been reviewed. Commit first, review it, then run gh pr ${sub}.` };
  }

  if (sub === 'ready') {
    // The reviews must cover the PR's head commit on GitHub, which may differ from local HEAD.
    const pr = prHead(dir, selector, repo);
    if (!pr) {
      if (selector !== undefined) {
        return { block: `couldn't look up PR ${selector} with \`gh pr view\`, so there's no way to tell which commit it would mark ready. Run \`gh pr ready\` with no argument from the PR's checkout.` };
      }
      notes.push("couldn't look up the PR with `gh pr view`; checked local HEAD");
      return { target: { dir, rev: null, note: notes.join('; ') } };
    }
    const wt = worktreeFor(dir, pr.branch);
    if (wt) dir = wt; // markers live in the worktree that has the branch checked out
    if (!git(dir, 'rev-parse', '--verify', '--quiet', `${pr.oid}^{commit}`)) {
      return { block: `the PR's head commit ${pr.oid.slice(0, 12)} (${pr.branch}) isn't in ${dir}, so it can't have been reviewed there. Fetch or check out the branch, review that commit, then run \`gh pr ready\`.` };
    }
    return { target: { dir, rev: pr.oid, note: notes.length ? notes.join('; ') : null } };
  }

  let rev = null;
  if (head === null) {
    return { block: '--head is not a literal value, so there is no way to tell which commit the PR contains. Pass the branch name literally.' };
  }
  if (head) {
    const colon = head.indexOf(':');
    const owner = colon >= 0 ? head.slice(0, colon).toLowerCase() : null;
    const branch = colon >= 0 ? head.slice(colon + 1) : head;
    if (owner && !remoteSlugs().some((slug) => slug.split('/')[0] === owner)) {
      return { block: `--head ${head} is a branch in ${owner}'s repo, but none of ${dir}'s remotes belong to ${owner}` };
    }
    // A push to this branch earlier in the same command decides what the PR contains,
    // so it wins over a (possibly stale) local or remote-tracking branch.
    const repoId = (d) => git(d, 'rev-parse', '--path-format=absolute', '--git-common-dir') ?? git(d, 'rev-parse', '--show-toplevel');
    const here = repoId(dir);
    const pushed = (hit.pushes ?? []).filter((p) => p.dst === branch && repoId(p.dir) === here).pop();
    const current = git(dir, 'symbolic-ref', '--quiet', '--short', 'HEAD');
    if (pushed) {
      const top = git(pushed.dir, 'rev-parse', '--show-toplevel');
      rev = git(pushed.dir, 'rev-parse', '--verify', '--quiet', `${pushed.src}^{commit}`);
      if (!top || !rev) return { block: `can't resolve ${pushed.src}, pushed to ${branch} in ${pushed.dir}` };
      dir = top; // its markers live in the checkout that pushed
    } else if (branch !== current) {
      // Markers live in each worktree's own git dir: prefer the worktree that has the branch.
      const wt = worktreeFor(dir, branch);
      if (wt) {
        dir = wt;
      } else {
        rev = git(dir, 'rev-parse', '--verify', '--quiet', `refs/heads/${branch}^{commit}`);
        if (!rev) {
          // Pushed earlier but never a local branch (e.g. `git push origin HEAD:name`): use the remote-tracking ref.
          const refs = (git(dir, 'for-each-ref', '--format=%(objectname)', `refs/remotes/*/${branch}`) ?? '').split('\n').filter(Boolean);
          if (new Set(refs).size === 1) rev = refs[0];
        }
        if (!rev) {
          return {
            block: `--head ${head} isn't a local branch or a fetched remote branch in ${dir}, so there's no way to tell which commit was reviewed. ` +
              'Push it first, or run `gh pr create` from a checkout of that branch.',
          };
        }
      }
    }
  }
  return { target: { dir, rev, note: notes.length ? notes.join('; ') : null } };
}

export function resolveTargets(command, cwd, env = process.env) {
  let hits;
  try {
    hits = findPrCreates(command, cwd, env);
  } catch (err) {
    return { status: 'error', reason: String(err?.message ?? err), risky: RISKY.test(command) };
  }
  if (hits.readyMutation) {
    return { status: 'block', reason: 'mark a PR ready with `gh pr ready` (gated on the recorded reviews), not through the GraphQL API.' };
  }
  if (hits.opaque && READY_MUTATION.test(command)) {
    return { status: 'block', reason: `the GraphQL ready mutation is passed to ${hits.opaque}, which the gate can't follow. Use \`gh pr ready\`.` };
  }
  if (!hits.length) {
    if (hits.opaque) {
      return { status: 'error', reason: `\`gh pr create\` is passed to ${hits.opaque}, which the gate can't follow`, risky: RISKY.test(command) };
    }
    return { status: 'none' }; // only mentioned as data (a commit message, a file being written)
  }
  const targets = [];
  if (hits.opaque) {
    // Another `gh pr create` went somewhere the gate can't follow: same policy as an
    // unparseable command, applied on top of the hits that could be resolved.
    if (RISKY.test(command)) {
      return { status: 'block', reason: `\`gh pr create\` is also passed to ${hits.opaque}, which the gate can't follow, and the command changes directory or names a repo/branch` };
    }
    targets.push({ dir: cwd, rev: null, note: `gh pr create is also passed to ${hits.opaque}; checked the session cwd for it` });
  }
  let allHelp = true;
  for (const hit of hits) {
    const r = resolveOne(hit);
    if (r.block) return { status: 'block', reason: r.block };
    if (r.help) continue;
    allHelp = false;
    if (!targets.some((t) => t.dir === r.target.dir && t.rev === r.target.rev)) targets.push(r.target);
  }
  return allHelp && !targets.length ? { status: 'help' } : { status: 'ok', targets };
}

// ── Pre-push gate ────────────────────────────────────────────────────────────

// Used only when the command can't be parsed: could the push run somewhere other than the session cwd?
const PUSH_RISKY = /(^|[\s;&|(){}'"`])(cd|pushd|popd)(\s|$)|(^|\s)(-C|--git-dir|--work-tree)([\s=]|$)|GIT_DIR|GIT_WORK_TREE|CDPATH/;
// `git push` options that take a separate value, and the short ones that take one (attached or next word).
const PUSH_VALUE_LONG = new Set(['--repo', '--push-option', '--receive-pack', '--exec']);
const PUSH_VALUE_SHORT = new Set(['o']);
// Config that decides what a push without refspecs publishes (`remote.<name>.push`, push.default=matching).
const PUSH_CONFIG = /^(remote\..+\.push|remote\..+\.mirror|push\.default)=/i;

/**
 * Which commits does one `git push` publish? Returns { skip } (nothing to gate: help, dry run, deletes, tags only),
 * { block: reason }, or { targets: [{ dir, rev }] }: each commit pushed to a branch, with the checkout whose
 * review-gate markers hold its pre-push review.
 */
function resolvePush(p) {
  if (p.why) return { block: p.why };
  if (p.dir === null) {
    return { block: "can't tell which repo a `git push` runs in: a `cd` or `-C` before it isn't a literal path, or only runs conditionally. Use `cd /literal/path && git push ...` or `git -C /literal/path push ...`" };
  }
  if (!existsSync(p.dir) || !statSync(p.dir).isDirectory()) return { block: `\`git push\` would run in ${p.dir}, which doesn't exist` };
  const top = git(p.dir, 'rev-parse', '--show-toplevel');
  if (top === null) return { skip: true, note: `${p.dir} isn't a git checkout; push not gated` };
  const repoOf = (d) => (d ? git(d, 'rev-parse', '--path-format=absolute', '--git-common-dir') ?? git(d, 'rev-parse', '--show-toplevel') : null);
  const here = repoOf(top);
  const moved = (p.moves ?? []).find((m) => m.dir === null || repoOf(m.dir) === here);
  if (moved) {
    return { block: `\`git ${moved.sub}\` runs before \`git push\` in the same command, so the push would publish a commit that doesn't exist yet and can't have had its pre-push review. Commit first, run \`review-gate prepush\`, then push on its own.` };
  }
  const positional = [];
  let remoteGiven = false; let del = false; let dry = false; let help = false; let all = false; let tags = false;
  const args = p.args ?? [];
  for (let j = 0; j < args.length; j++) {
    const w = args[j];
    const v = w.value;
    if (/^\d*[<>]/.test(v)) { if (/^\d*[<>]+&?$/.test(v)) j += 1; continue; } // a redirection, not an argument
    if (v === '--') { positional.push(...args.slice(j + 1)); break; }
    if (w.dynamic) { // could expand to --all, another refspec, ...
      return { block: `\`git push\` has a non-literal argument (${v}) that could change what it pushes; pass it literally` };
    }
    if (v.startsWith('--')) {
      const name = v.split('=')[0];
      if (name === '--delete') del = true;
      else if (name === '--dry-run') dry = true;
      else if (name === '--help') help = true;
      else if (['--all', '--mirror', '--branches'].includes(name)) all = true;
      else if (name === '--tags') tags = true;
      if (name === '--repo') remoteGiven = true;
      if (PUSH_VALUE_LONG.has(name) && !v.includes('=')) j += 1;
      continue;
    }
    if (/^-[A-Za-z0-9]/.test(v)) {
      for (let c = 1; c < v.length; c++) {
        const ch = v[c];
        if (ch === 'd') del = true;
        if (ch === 'n') dry = true;
        if (ch === 'h') help = true;
        if (PUSH_VALUE_SHORT.has(ch)) { if (c === v.length - 1) j += 1; break; }
      }
      continue;
    }
    positional.push(w);
  }
  if (help || dry || del) return { skip: true }; // nothing is published (`--delete` removes refs only)
  if (all) return { block: '`git push --all/--mirror/--branches` publishes every branch at once; push one branch (`git push origin HEAD`) so the gate can check its pre-push review' };
  const specs = remoteGiven ? positional : positional.slice(1);
  const headRev = () => git(top, 'rev-parse', '--verify', '--quiet', 'HEAD^{commit}');
  if (!specs.length) {
    if (tags) return { skip: true }; // `git push --tags [remote]`: tags only
    // Without refspecs git publishes what its config says: only the current branch is checkable. Configured push
    // refspecs, mirror remotes or push.default=matching (in the repo's config or a `-c` override) may publish
    // other branches, so spell the refspec out instead.
    const cfgOverride = (p.config ?? []).find((w) => w.dynamic || PUSH_CONFIG.test(w.value));
    const pd = git(top, 'config', '--get', 'push.default');
    const refspecCfg = git(top, 'config', '--get-regexp', '^remote\\..*\\.(push|mirror)$');
    if (cfgOverride || pd === 'matching' || refspecCfg) {
      return { block: `a \`git push\` without a refspec publishes what ${cfgOverride ? `\`-c ${cfgOverride.value}\`` : pd === 'matching' ? 'push.default=matching' : 'the configured remote push refspecs'} say${cfgOverride ? 's' : ''}, which may be more than the current branch. Name it: \`git push origin HEAD\`` };
    }
    const rev = headRev(); // the current branch (push.default)
    return rev ? { targets: [{ dir: top, rev }] } : { skip: true, note: `${top} has no commits; push not gated` };
  }
  const current = git(top, 'symbolic-ref', '--quiet', '--short', 'HEAD');
  const targets = [];
  for (let j = 0; j < specs.length; j++) {
    const s = specs[j];
    if (s.dynamic) return { block: `\`git push\` has a non-literal refspec (${s.value}), so the gate can't tell which commit it publishes; pass it literally` };
    const r = s.value.replace(/^\+/, '');
    if (r === 'tag') { j += 1; continue; } // `git push origin tag v1`
    if (r === ':' || r.includes('*')) return { block: `\`git push ${r}\` publishes several branches at once; push one branch so the gate can check its pre-push review` };
    const colon = r.indexOf(':');
    const src = colon >= 0 ? r.slice(0, colon) : r;
    const dst = colon >= 0 ? r.slice(colon + 1) : r;
    if (!src) continue; // `:branch` deletes it
    if (dst.startsWith('refs/tags/')) continue; // publishes a tag, not a branch
    if (colon < 0) { // `git push origin v1`: a tag pushed as itself. A tag pushed to a branch (`v1:main`) is checked.
      if (src.startsWith('refs/tags/')) continue;
      const isBranch = src === 'HEAD' || src.startsWith('refs/') || git(top, 'rev-parse', '--verify', '--quiet', `refs/heads/${src}`) !== null;
      if (!isBranch && git(top, 'rev-parse', '--verify', '--quiet', `refs/tags/${src}`) !== null) continue;
    }
    const rev = git(top, 'rev-parse', '--verify', '--quiet', `${src}^{commit}`);
    if (!rev) return { block: `can't resolve \`${src}\` (pushed by \`git push\`) to a commit in ${top}, so its pre-push review can't be checked` };
    let dir = top;
    const branch = src.replace(/^refs\/heads\//, '');
    if (src !== 'HEAD' && branch !== current) dir = worktreeFor(top, branch) ?? top; // markers live in that worktree
    targets.push({ dir, rev });
  }
  return targets.length ? { targets } : { skip: true };
}

/** Every commit the command would push to a branch, for the pre-push gate (status ok/none/block/error). */
export function resolvePushes(command, cwd, env = process.env) {
  let hits;
  try {
    hits = findPrCreates(command, cwd, env);
  } catch (err) {
    return { status: 'error', reason: String(err?.message ?? err), risky: PUSH_RISKY.test(command) };
  }
  const targets = [];
  const notes = [];
  const add = (t, note = null) => {
    const old = targets.find((x) => x.dir === t.dir && x.rev === t.rev);
    if (!old) targets.push({ ...t, note });
  };
  for (const p of hits.gitPushes ?? []) {
    const r = resolvePush(p);
    if (r.block) return { status: 'block', reason: r.block };
    if (r.note) notes.push(r.note);
    for (const t of r.targets ?? []) add(t);
  }
  if (hits.opaquePush) {
    const { what, dir } = hits.opaquePush;
    if (dir === null) return { status: 'block', reason: `\`git push\` is passed to ${what}, which the gate can't follow, from a directory it can't tell. Run the push directly: \`cd /literal/path && git push ...\`` };
    const top = git(dir, 'rev-parse', '--show-toplevel');
    const rev = top && git(top, 'rev-parse', '--verify', '--quiet', 'HEAD^{commit}');
    if (rev) add({ dir: top, rev }, `git push is passed to ${what}, which the gate can't follow; checked ${top} HEAD for it`);
  }
  return targets.length ? { status: 'ok', targets, notes } : { status: 'none', notes };
}

// Run as a script? Compare real paths: node resolves symlinks for import.meta.url but
// argv[1] keeps the path it was invoked by (e.g. a symlinked install dir).
function isMain() {
  try {
    return Boolean(process.argv[1]) && realpathSync(fileURLToPath(import.meta.url)) === realpathSync(process.argv[1]);
  } catch {
    return false;
  }
}

if (isMain()) {
  const cwd = process.argv[2] || process.cwd();
  const mode = process.argv[3] === '--push' ? resolvePushes : resolveTargets;
  let result;
  try {
    result = mode(readFileSync(0, 'utf8'), cwd);
  } catch (err) {
    result = { status: 'error', reason: String(err?.message ?? err), risky: true };
  }
  process.stdout.write(JSON.stringify(result) + '\n');
}
