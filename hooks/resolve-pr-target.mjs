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
import { existsSync, readFileSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// ── Tokenizer ────────────────────────────────────────────────────────────────

const OPS = new Set([';', '&&', '||', '|', '&', '(', ')']);

function readHeredocDelim(src, i) {
  // i is just past `<<`. Returns { delim, strip, end }.
  let strip = false;
  if (src[i] === '-') { strip = true; i += 1; }
  while (src[i] === ' ' || src[i] === '\t') i += 1;
  const m = src.slice(i).match(/^(?:'([^']*)'|"([^"]*)"|\\?([^\s;&|()<>]+))/);
  if (!m) return { delim: null, strip, end: i };
  return { delim: m[1] ?? m[2] ?? m[3], strip, end: i + m[0].length };
}

function skipHeredocBodies(src, i, heredocs) {
  // i is just past a newline; consume each pending heredoc body in order.
  for (const { delim, strip } of heredocs.splice(0)) {
    while (i < src.length) {
      const end = src.indexOf('\n', i);
      const line = src.slice(i, end < 0 ? src.length : end);
      i = end < 0 ? src.length : end + 1;
      if ((strip ? line.replace(/^\t+/, '') : line) === delim) break;
    }
  }
  return i;
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
  const add = (s) => { if (word === null) tilde = false; word = (word ?? '') + s; };
  const push = () => {
    if (word !== null) out.push({ type: 'word', value: word, dynamic, tilde, substs });
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
    if (c === '<' && src.startsWith('<<<', i)) { push(); i += 3; continue; }
    if (c === '<' && src.startsWith('<<', i)) {
      push();
      const h = readHeredocDelim(src, i + 2);
      if (h.delim !== null) heredocs.push(h);
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
      out.push({ type: 'op', value: ';' });
      i = heredocs.length ? skipHeredocBodies(src, i + 1, heredocs) : i + 1;
      continue;
    }
    if (c === ';') { push(); out.push({ type: 'op', value: ';' }); i += src[i + 1] === ';' ? 2 : 1; continue; }
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
const RUNNERS = new Set(['exec', 'env', 'sudo', 'nohup', 'xargs', 'nice', 'timeout']);
const DIR_WORD = /(^|[\s;&|(])(cd|pushd|popd)([\s;&|)]|$)/;
const ASSIGN = /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/s;

function isGhPrCreate(words) {
  return words.length >= 3 && !words[0].dynamic && words[0].value === 'gh' && words[1].value === 'pr' && words[2].value === 'create';
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
    pushes: [...from.pushes],
    pendingCond: false, // a `&& cd` ran in the current and-or list
    listStart: { dir: from.dir, dirStack: [...from.dirStack] },
  });
  const scopes = [newScope({
    dir: cwd,
    dirStack: [],
    ghRepo: inherit.ghRepo !== undefined ? inherit.ghRepo : (env.GH_REPO || undefined),
    cdpath: inherit.cdpath ?? Boolean(env.CDPATH),
    pushes: inherit.pushes ?? [],
  })];
  const braces = [];
  let cond = 0;
  let funcDepth = 0;
  let caseDepth = 0;
  let funcPending = false;
  let prevOp = ';';
  let words = [];
  const found = [];
  const scope = () => scopes[scopes.length - 1];

  // Code that runs in a subshell ($(...), `...`, <(...), bash -c, eval): gate any
  // gh pr create inside it, starting from the current directory.
  const nested = (script, dir) => {
    const s = scope();
    for (const h of findPrCreates(script, dir, env, { ghRepo: s.ghRepo, cdpath: s.cdpath, pushes: s.pushes })) {
      found.push({ ...h, dir: funcDepth > 0 ? null : h.dir });
    }
  };

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
    if (cmd[k]?.value !== 'push' || cmd[k].dynamic) return;
    const positional = [];
    const rest = cmd.slice(k + 1);
    for (let j = 0; j < rest.length; j++) {
      const v = rest[j].value;
      if (v === '--') { positional.push(...rest.slice(j + 1)); break; }
      if (v.startsWith('-')) { if (['-o', '--push-option', '--repo', '--receive-pack', '--exec'].includes(v)) j += 1; continue; }
      positional.push(rest[j]);
    }
    for (const spec of positional.slice(1)) {
      if (spec.dynamic || gdir === null) continue;
      const r = spec.value.replace(/^\+/, '');
      const [src, dst] = r.includes(':') ? [r.slice(0, r.indexOf(':')), r.slice(r.indexOf(':') + 1)] : [r, r];
      if (src && dst) s.pushes.push({ dir: gdir, src, dst: dst.replace(/^refs\/heads\//, '') });
    }
  };

  const flush = (nextOp) => {
    let cmd = words;
    words = [];
    for (const w of cmd) for (const body of w.substs ?? []) nested(body, scope().dir);
    const pipelined = prevOp === '|' || prevOp === '&' || nextOp === '|' || nextOp === '&';
    // Reserved words and brace groups.
    while (cmd.length && !cmd[0].dynamic) {
      const v = cmd[0].value;
      if (OPENERS.has(v)) {
        cond += 1;
        if (v === 'case') { caseDepth += 1; cmd = []; break; } // `case x in` header
        if (v === 'for' || v === 'select') { cmd = []; break; } // `for x in ...` header
        cmd = cmd.slice(1);
      } else if (CLOSERS.has(v)) {
        cond = Math.max(0, cond - 1);
        if (v === 'esac') caseDepth = Math.max(0, caseDepth - 1);
        cmd = cmd.slice(1);
      } else if (CONTINUERS.has(v)) {
        cmd = cmd.slice(1);
      } else if (v === 'function') {
        funcPending = true;
        cmd = cmd.slice(2);
      } else if (v === '{') {
        const isFunc = funcPending;
        braces.push(isFunc ? 'func' : 'group');
        if (isFunc) { cond += 1; funcDepth += 1; funcPending = false; }
        cmd = cmd.slice(1);
      } else if (v === '}') {
        if (braces.pop() === 'func') { cond = Math.max(0, cond - 1); funcDepth = Math.max(0, funcDepth - 1); }
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
    if (assigns.some((w) => w.value.startsWith('CDPATH=')) && ['cd', 'pushd'].includes(cmd[0].value)) { s.dir = null; return; }
    if (isGhPrCreate(cmd)) {
      const prefixed = assigns.find((w) => w.value.startsWith('GH_REPO='));
      found.push({
        dir: funcDepth > 0 ? null : s.dir, // a function body runs later, from wherever it's called
        args: cmd.slice(3),
        ghRepo: prefixed ? (prefixed.dynamic ? null : prefixed.value.slice('GH_REPO='.length)) : s.ghRepo,
        pushes: [...s.pushes],
      });
      return;
    }
    // A command word built from an expansion ($X, $(...)) is opaque. Deliberately hiding
    // a `cd` that way is out of scope for this speed-bump; see the README.
    if (cmd[0].dynamic) return;
    let c0 = cmd[0].value;
    if ((c0 === 'builtin' || c0 === 'command') && cmd[1]) { cmd = cmd.slice(1); c0 = cmd[0].value; }
    if (c0 === 'cd' || c0 === 'pushd' || c0 === 'popd') { applyDirCommand(cmd, pipelined); return; }
    if (c0 === 'git') { recordPush(cmd); return; }
    if (c0 === 'eval') {
      // eval runs in this shell: gate any gh pr create in it; a cd in it isn't modelled.
      const args = cmd.slice(1);
      if (args.some((w) => w.dynamic)) { if (!pipelined) s.dir = null; return; }
      const script = args.map((w) => w.value).join(' ');
      nested(script, s.dir);
      if (!pipelined && DIR_WORD.test(script)) s.dir = null;
      return;
    }
    if (c0 === 'source' || c0 === '.') {
      if (!pipelined && cmd.slice(1).some((w) => w.dynamic)) s.dir = null; // e.g. source <(...)
      return;
    }
    if (SHELLS.has(c0)) {
      // A child shell can't move us, but a gh pr create in its -c script still runs.
      const ci = cmd.findIndex((w, idx) => idx > 0 && /^-[A-Za-z]*c$/.test(w.value));
      const script = ci > 0 ? cmd[ci + 1] : undefined;
      if (script && !script.dynamic) nested(script.value, s.dir);
      return;
    }
    if (RUNNERS.has(c0)) {
      // `timeout 60 gh pr create ...`, `env -C dir gh pr create ...`
      const k = cmd.findIndex((w, idx) => idx > 0 && isGhPrCreate(cmd.slice(idx)));
      if (k > 0) {
        const chdir = c0 === 'env' && cmd.slice(1, k).some((w) => /^(--chdir|-[A-Za-z]*C)/.test(w.value));
        found.push({ dir: chdir || funcDepth > 0 ? null : s.dir, args: cmd.slice(k + 3), ghRepo: s.ghRepo, pushes: [...s.pushes] });
      }
    }
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
        flush(';'); prevOp = ';'; continue; // `case x in y)` / `case x in (y)`: header + first pattern
      }
      if (caseDepth > 0) { if (op === ')') { words = []; prevOp = ';'; } continue; } // case patterns
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
      if (op === ';' || op === '&') endList(op);
      prevOp = op;
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

  let rev = null;
  if (head === null) notes.push("--head is not a literal value; checked the checkout's HEAD");
  if (head) {
    const colon = head.indexOf(':');
    const owner = colon >= 0 ? head.slice(0, colon).toLowerCase() : null;
    const branch = colon >= 0 ? head.slice(colon + 1) : head;
    if (owner && !remoteSlugs().some((slug) => slug.split('/')[0] === owner)) {
      return { block: `--head ${head} is a branch in ${owner}'s repo, but none of ${dir}'s remotes belong to ${owner}` };
    }
    const current = git(dir, 'symbolic-ref', '--quiet', '--short', 'HEAD');
    if (branch !== current) {
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
          // Pushed but never a local branch (e.g. `git push origin HEAD:name`): use the remote-tracking ref.
          const refs = (git(dir, 'for-each-ref', '--format=%(objectname)', `refs/remotes/*/${branch}`) ?? '').split('\n').filter(Boolean);
          if (new Set(refs).size === 1) rev = refs[0];
        }
        if (!rev) {
          // Pushed earlier in this same command (`git push origin HEAD:name && gh pr create --head name`).
          const pushed = (hit.pushes ?? []).filter((p) => p.dst === branch && git(p.dir, 'rev-parse', '--show-toplevel') === dir);
          const last = pushed[pushed.length - 1];
          if (last) rev = git(last.dir, 'rev-parse', '--verify', '--quiet', `${last.src}^{commit}`);
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
  if (!hits.length) return { status: 'none' }; // only mentioned as data (heredoc body, quoted text)
  const targets = [];
  let allHelp = true;
  for (const hit of hits) {
    const r = resolveOne(hit);
    if (r.block) return { status: 'block', reason: r.block };
    if (r.help) continue;
    allHelp = false;
    if (!targets.some((t) => t.dir === r.target.dir && t.rev === r.target.rev)) targets.push(r.target);
  }
  return allHelp ? { status: 'help' } : { status: 'ok', targets };
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  const cwd = process.argv[2] || process.cwd();
  let result;
  try {
    result = resolveTargets(readFileSync(0, 'utf8'), cwd);
  } catch (err) {
    result = { status: 'error', reason: String(err?.message ?? err), risky: true };
  }
  process.stdout.write(JSON.stringify(result) + '\n');
}
