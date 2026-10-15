#!/usr/bin/env node
// Resolve which git checkout(s) and commit(s) the `gh pr create` invocations in a Bash
// command will open PRs from, so the PR gate checks THOSE repos' review markers instead
// of the session's cwd.
// Part of https://github.com/job-bot-ai/ai-code-review-mcp
//
// Usage: resolve-pr-target.mjs <cwd>   (the Bash command on stdin)
// Prints one JSON object:
//   { "status": "ok", "targets": [{ "dir", "rev"|null, "note"|null }, ...] }
//   { "status": "block", "reason": "..." }   a target can't be determined safely
//   { "status": "help" }                     `gh pr create --help`: nothing to gate
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
const MENTION = /(^|[^A-Za-z0-9_-]|\\[nt])gh(\s|\\t)+pr(\s|\\t)+(create|new)\b/; // same boundary as the hook's pre-filter
const DIR_WORD = /(^|[\s;&|(])(cd|pushd|popd)([\s;&|)]|$)/;
const ASSIGN = /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/s;

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

function isGhPrCreate(words) {
  // `gh pr new` is gh's built-in alias of `gh pr create`.
  // ...and gh may be invoked by path (/usr/bin/gh, ./bin/gh).
  return words.length >= 3 && !words[0].dynamic && path.basename(words[0].value) === 'gh' && words[1].value === 'pr' &&
    (words[2].value === 'create' || words[2].value === 'new');
}

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
    pendingCond: false, // a `&& cd` ran in the current and-or list
    listStart: { dir: from.dir, dirStack: [...from.dirStack] },
  });
  const scopes = [newScope({
    dir: cwd,
    dirStack: [],
    ghRepo: inherit.ghRepo !== undefined ? inherit.ghRepo : (env.GH_REPO || undefined),
    cdpath: inherit.cdpath ?? Boolean(env.CDPATH),
  })];
  // A push changes the remote, not the shell, so it isn't scoped to a subshell.
  const pushes = inherit.pushes ?? []; // shared with nested scripts, so their pushes count too
  const headMoves = inherit.headMoves ?? []; // git commands that change HEAD's commit (shared too)
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
  const scope = () => scopes[scopes.length - 1];

  // Code that runs in a subshell ($(...), `...`, <(...), bash -c, eval): gate any
  // gh pr create inside it, starting from the current directory.
  const nested = (script, dir) => {
    const s = scope();
    const inner = findPrCreates(script, dir, env, { ghRepo: s.ghRepo, cdpath: s.cdpath, pushes, headMoves });
    for (const h of inner) found.push({ ...h, dir: funcDepth > 0 ? null : h.dir });
    if (inner.opaque) found.opaque = inner.opaque;
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

  const recordPush = (cmd) => {
    // `git [-C dir] push [opts] <remote> <src>:<dst> ...` — lets `--head <dst>` be checked at
    // <src> even though the push (and its remote-tracking ref) hasn't happened yet.
    const s = scope();
    let k = 1;
    let gdir = s.dir;
    while (k < cmd.length && cmd[k].value.startsWith('-')) {
      const v = cmd[k].value;
      if (v === '-C') {
        const d = cmd[k + 1];
        gdir = !d || d.dynamic ? null : path.isAbsolute(d.value) ? d.value : gdir === null ? null : path.resolve(gdir, d.value);
        k += 2;
        continue;
      }
      k += ['-c', '--git-dir', '--work-tree', '--namespace'].includes(v) ? 2 : 1;
    }
    const sub = cmd[k]?.dynamic ? null : cmd[k]?.value;
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
    if (assigns.some((w) => w.value.startsWith('CDPATH=')) && ['cd', 'pushd'].includes(cmd[0].value)) { s.dir = null; return; }
    if (isGhPrCreate(cmd)) {
      const prefixed = assigns.find((w) => w.value.startsWith('GH_REPO='));
      found.push({
        dir: funcDepth > 0 ? null : s.dir, // a function body runs later, from wherever it's called
        args: cmd.slice(3),
        ghRepo: prefixed ? (prefixed.dynamic ? null : prefixed.value.slice('GH_REPO='.length)) : s.ghRepo,
        pushes: [...pushes],
        headMoves: [...headMoves],
      });
      return;
    }
    // A command word built from an expansion ($X, $(...)) is opaque. Deliberately hiding
    // a `cd` that way is out of scope for this speed-bump; see the README.
    const stdinCode = cmd.flatMap((w) => (w.heredoc ? [w.heredoc.body ?? ''] : w.herestring ? [w.value] : []));
    const mentioned = () => cmd.some((w) => MENTION.test(w.heredoc ? w.heredoc.body ?? '' : w.value));
    if (cmd[0].dynamic) { if (mentioned()) opaque(`\`${cmd[0].value}\` (a non-literal command)`); return; }
    const c0 = cmd[0].value;
    if (c0 === 'cd' || c0 === 'pushd' || c0 === 'popd') { applyDirCommand(cmd, pipelined); return; }
    if (c0 === 'git') { recordPush(cmd); return; }
    if (c0 === 'eval') {
      // eval runs in this shell. Walk its script even when part of it is an expansion ($X
      // stays a dynamic word); a cd in it isn't modelled, so the directory becomes unknown.
      const args = cmd.slice(1).filter((w) => !w.heredoc && !w.herestring);
      const script = args.map((w) => w.value).join(' ');
      nested(script, s.dir);
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
      for (const body of code) nested(body, s.dir);
      if (substMention()) opaque(`${c0} <(...)`);
      if (!pipelined && (args.some((w) => w.dynamic) || code.some((b) => DIR_WORD.test(b)))) s.dir = null;
      return;
    }
    if (SHELLS.has(c0)) {
      // A child shell can't move us, but a gh pr create in its script still runs: walk a
      // -c script (even a partly dynamic one) or code on stdin (heredoc, here-string, pipe).
      const ci = cmd.findIndex((w, idx) => idx > 0 && /^-[A-Za-z]*c$/.test(w.value));
      if (ci > 0) { if (cmd[ci + 1]) nested(cmd[ci + 1].value, s.dir); return; }
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
      for (const body of [...stdinCode, ...(fromPipe !== null ? [fromPipe] : [])]) nested(body, s.dir);
      return;
    }
    if (INTERPRETERS.has(c0)) {
      const inline = cmd.findIndex((w, idx) => idx > 0 && /^-[A-Za-z]*[ce]$/.test(w.value));
      if (inline > 0 && MENTION.test(cmd[inline + 1]?.value ?? '')) opaque(`${c0} ${cmd[inline].value}`);
      return;
    }
    if (RUNNERS.has(c0)) {
      // `timeout 60 gh pr create ...`, `env -C dir GH_REPO=o/r gh pr create ...`
      const k = cmd.findIndex((w, idx) => idx > 0 && isGhPrCreate(cmd.slice(idx)));
      if (k > 0) {
        const pre = cmd.slice(1, k);
        const chdir = c0 === 'env' && pre.some((w) => /^(--chdir|-[A-Za-z]*C)/.test(w.value));
        const repoArg = c0 === 'env' ? pre.filter((w) => w.value.startsWith('GH_REPO=')).pop() : undefined;
        found.push({
          dir: chdir || funcDepth > 0 ? null : s.dir,
          args: cmd.slice(k + 3),
          ghRepo: repoArg ? (repoArg.dynamic ? null : repoArg.value.slice('GH_REPO='.length)) : s.ghRepo,
          pushes: [...pushes],
        headMoves: [...headMoves],
        });
        return;
      }
    }
    // sed/awk only run commands via awk system()/print|"cmd" or sed's e command/flag.
    if (c0 === 'awk' || c0 === 'gawk' || c0 === 'sed') {
      const sedRuns = /(^|[;{}\s])e(\s|;|$)|\/[A-Za-z0-9]*e[A-Za-z0-9]*(\s|;|}|$)/;
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
      found.push({ dir: funcDepth > 0 ? null : s.dir, args: cmd.slice(k + 3), ghRepo: s.ghRepo, pushes: [...pushes], headMoves: [...headMoves] });
      return;
    }
    // Otherwise, anything that receives `gh pr create` (in one argument, split across
    // arguments, a heredoc or a pipe) might run it. Script interpreters were handled above.
    const joined = cmd.slice(1).filter((w) => !w.heredoc).map((w) => w.value).join(' ');
    if (mentioned() || MENTION.test(joined) || (fromPipe !== null && MENTION.test(fromPipe))) opaque(c0);
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

/** Pull -R/--repo, -H/--head and -h/--help out of `gh pr create` args (pflag rules). */
export function parseGhArgs(args) {
  const out = { repo: undefined, head: undefined, help: false, opaque: null };
  const set = (key, w, value) => { if (key) out[key] = w && !w.dynamic ? value : null; };
  for (let i = 0; i < args.length; i++) {
    const w = args[i];
    const v = w.value;
    if (w.dynamic && !v.startsWith('-')) { out.opaque ??= v; continue; } // could expand to --repo/--head
    if (v === '--') break;
    if (v === '--help' || v === '-h') { out.help = true; continue; }
    if (v.startsWith('--')) {
      const eq = v.indexOf('=');
      const name = eq < 0 ? v : v.slice(0, eq);
      if (!VALUE_LONG.has(name)) continue;
      if (eq >= 0) set(KEY[name], w, v.slice(eq + 1));
      else { const nx = args[++i]; set(KEY[name], nx, nx?.value); }
      continue;
    }
    if (/^-[A-Za-z]/.test(v)) {
      for (let j = 1; j < v.length; j++) {
        const ch = v[j];
        if (ch === 'h') { out.help = true; continue; }
        if (!VALUE_SHORT.has(ch)) continue; // boolean shorthand like -d / -f / -w
        let rest = v.slice(j + 1);
        if (rest.startsWith('=')) rest = rest.slice(1);
        if (rest) set(KEY[ch], w, rest);
        else { const nx = args[++i]; set(KEY[ch], nx, nx?.value); }
        break;
      }
    }
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

function resolveOne(hit) {
  if (hit.dir === null) {
    return { block: "can't tell which repo a `gh pr create` runs in: a `cd` before it isn't a literal path, or only runs conditionally. Use `cd /literal/path && gh pr create ...`" };
  }
  let dir = hit.dir;
  if (!existsSync(dir) || !statSync(dir).isDirectory()) {
    return { block: `\`gh pr create\` would run in ${dir}, which doesn't exist` };
  }
  const { repo: flagRepo, head, help, opaque } = parseGhArgs(hit.args);
  if (help) return { help: true };
  if (opaque) return { block: `\`gh pr create\` has a non-literal argument (${opaque}) that could set --repo/--head; pass flags literally` };
  const repo = flagRepo !== undefined ? flagRepo : hit.ghRepo;
  const notes = [];
  const top = git(dir, 'rev-parse', '--show-toplevel');
  if (top === null) {
    if (repo !== undefined || head !== undefined) {
      return { block: `${dir} isn't a git checkout, so the reviews behind this --repo/--head PR can't be verified. Run it from the checkout.` };
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
          `Run it from the target checkout so the gate checks that repo's reviews: cd <checkout of ${repo}> && gh pr create ...`,
      };
    }
  }

  // A commit made earlier in this same command (git commit/merge/rebase/pull...) is what
  // the PR will contain, but the hook runs before it exists, so it can't have been reviewed.
  const repoOf = (d) => (d ? git(d, 'rev-parse', '--path-format=absolute', '--git-common-dir') ?? git(d, 'rev-parse', '--show-toplevel') : null);
  const moved = (hit.headMoves ?? []).find((m) => m.dir === null || repoOf(m.dir) === repoOf(dir));
  if (moved) {
    return { block: `\`git ${moved.sub}\` runs before \`gh pr create\` in the same command, so the PR would contain a commit that doesn't exist yet and can't have been reviewed. Commit first, review it, then run gh pr create.` };
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
      const wt = (git(dir, 'worktree', 'list', '--porcelain') ?? '').split('\n\n').map((block) => ({
        path: block.match(/^worktree (.+)$/m)?.[1],
        branch: block.match(/^branch refs\/heads\/(.+)$/m)?.[1],
      })).find((w) => w.branch === branch && w.path);
      if (wt) {
        dir = wt.path;
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
  let result;
  try {
    result = resolveTargets(readFileSync(0, 'utf8'), cwd);
  } catch (err) {
    result = { status: 'error', reason: String(err?.message ?? err), risky: true };
  }
  process.stdout.write(JSON.stringify(result) + '\n');
}
