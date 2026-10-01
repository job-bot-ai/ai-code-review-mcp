#!/usr/bin/env node
// Resolve which git checkout (and commit) a `gh pr create` command will open a PR from,
// so the PR gate checks THAT repo's review markers instead of the session's cwd.
// Part of https://github.com/job-bot-ai/ai-code-review-mcp
//
// Usage: resolve-pr-target.mjs <cwd>   (the Bash command on stdin)
// Prints one JSON object:
//   { "status": "ok", "dir": "...", "rev": "<sha>"|null, "note": "..."|null }
//   { "status": "block", "reason": "..." }   the target can't be determined or doesn't match
//   { "status": "none" }                     no `gh pr create` in command position
//
// What it follows: `cd`/`pushd` before the `gh pr create` (including inside `( ... )`
// subshells), `-R/--repo [HOST/]OWNER/REPO` (must match one of the checkout's remotes),
// and `-H/--head [OWNER:]BRANCH` (if that branch is checked out in another worktree of the
// repo, that worktree's markers are the ones that count). `git -C <dir>` is NOT followed:
// it changes the directory of that git invocation only, never where `gh` runs.
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const SEPARATORS = new Set([';', '&&', '||', '|', '&']);

/**
 * Minimal POSIX-shell tokenizer: words and the operators that start a new command.
 * Quotes and backslashes are honoured; a word built from `$...` or backticks (outside
 * single quotes) is flagged `dynamic`, since its value isn't knowable statically.
 */
export function tokenize(src) {
  const out = [];
  const heredocs = [];
  let word = null;
  let dynamic = false;
  const push = () => {
    if (word !== null) out.push({ type: 'word', value: word, dynamic });
    word = null;
    dynamic = false;
  };
  let i = 0;
  while (i < src.length) {
    const c = src[i];
    if (c === '\\') {
      if (src[i + 1] === '\n') { i += 2; continue; }
      if (i + 1 < src.length) { word = (word ?? '') + src[i + 1]; i += 2; continue; }
      i += 1; continue;
    }
    if (c === "'") {
      const j = src.indexOf("'", i + 1);
      if (j < 0) throw new Error('unterminated single quote');
      word = (word ?? '') + src.slice(i + 1, j);
      i = j + 1;
      continue;
    }
    if (c === '"') {
      let j = i + 1;
      let s = '';
      while (j < src.length && src[j] !== '"') {
        if (src[j] === '\\' && '"\\$`\n'.includes(src[j + 1] ?? '')) { s += src[j + 1]; j += 2; continue; }
        if (src[j] === '$' || src[j] === '`') dynamic = true;
        s += src[j];
        j += 1;
      }
      if (j >= src.length) throw new Error('unterminated double quote');
      word = (word ?? '') + s;
      i = j + 1;
      continue;
    }
    if (c === '$' || c === '`') { dynamic = true; word = (word ?? '') + c; i += 1; continue; }
    if (c === '<' && src.startsWith('<<<', i)) { push(); i += 3; continue; } // here-string: next word is data
    if (c === '<' && src.startsWith('<<', i)) {
      // Heredoc: remember the delimiter; its body (skipped at the next newline) is data, not commands.
      push();
      i += 2;
      const strip = src[i] === '-';
      if (strip) i += 1;
      while (src[i] === ' ' || src[i] === '\t') i += 1;
      const m = src.slice(i).match(/^(?:'([^']*)'|"([^"]*)"|\\?([^\s;&|()<>]+))/);
      if (m) { heredocs.push({ delim: m[1] ?? m[2] ?? m[3], strip }); i += m[0].length; }
      continue;
    }
    if (c === '\n' && heredocs.length) {
      push();
      out.push({ type: 'op', value: ';' });
      i += 1;
      for (const { delim, strip } of heredocs.splice(0)) {
        while (i < src.length) {
          const end = src.indexOf('\n', i);
          const line = src.slice(i, end < 0 ? src.length : end);
          i = end < 0 ? src.length : end + 1;
          if ((strip ? line.replace(/^\t+/, '') : line) === delim) break;
        }
      }
      continue;
    }
    if (c === '\n' || c === ';') { push(); out.push({ type: 'op', value: ';' }); i += 1; continue; }
    if (c === '&' || c === '|') {
      push();
      const two = src.slice(i, i + 2);
      if (two === '&&' || two === '||') { out.push({ type: 'op', value: two }); i += 2; }
      else { out.push({ type: 'op', value: c }); i += 1; }
      continue;
    }
    if (c === '(' || c === ')') { push(); out.push({ type: 'op', value: c }); i += 1; continue; }
    if (c === '#' && word === null) {
      const j = src.indexOf('\n', i);
      i = j < 0 ? src.length : j;
      continue;
    }
    if (/\s/.test(c)) { push(); i += 1; continue; }
    word = (word ?? '') + c;
    i += 1;
  }
  push();
  return out;
}

function expandHome(p) {
  if (p === '~') return homedir();
  if (p.startsWith('~/')) return path.join(homedir(), p.slice(2));
  return p;
}

/**
 * Walk the command up to the first `gh pr create` in command position, simulating the
 * shell's working directory. Returns { found, dir, args } where dir is null when a `cd`
 * on the way can't be resolved statically ($VAR, $(...), `cd -`, popd).
 */
export function findPrCreate(command, cwd) {
  const tokens = tokenize(command);
  const stack = [cwd];
  let words = [];
  const flush = () => {
    const cmd = words;
    words = [];
    // `{` and `}` group in the current shell; they don't change the directory.
    while (cmd.length && (cmd[0].value === '{' || cmd[0].value === '}') && !cmd[0].dynamic) cmd.shift();
    if (!cmd.length) return null;
    const [w0, w1, w2] = cmd;
    if (w0.value === 'gh' && w1?.value === 'pr' && w2?.value === 'create' && !w0.dynamic) {
      return { found: true, dir: stack[stack.length - 1], args: cmd.slice(3) };
    }
    if ((w0.value === 'cd' || w0.value === 'pushd') && !w0.dynamic) {
      const rest = cmd.slice(1).filter((w) => !['-L', '-P', '-e', '--'].includes(w.value));
      const top = stack[stack.length - 1];
      const arg = rest[0];
      if (!arg) stack[stack.length - 1] = homedir();
      else if (arg.dynamic || arg.value === '-' || top === null) stack[stack.length - 1] = null;
      else stack[stack.length - 1] = path.resolve(top, expandHome(arg.value));
    } else if (w0.value === 'popd') {
      stack[stack.length - 1] = null;
    }
    return null;
  };
  for (const t of tokens) {
    if (t.type === 'word') { words.push(t); continue; }
    if (t.value === '(') {
      const hit = flush(); if (hit) return hit;
      stack.push(stack[stack.length - 1]);
      continue;
    }
    if (t.value === ')') {
      const hit = flush(); if (hit) return hit;
      if (stack.length > 1) stack.pop();
      continue;
    }
    if (SEPARATORS.has(t.value)) {
      const hit = flush(); if (hit) return hit;
    }
  }
  return flush() ?? { found: false };
}

/** Pull -R/--repo and -H/--head out of `gh pr create` args. Values may be null (dynamic). */
export function parseGhArgs(args) {
  const out = { repo: undefined, head: undefined };
  const take = (key, w) => { out[key] = w && !w.dynamic ? w.value : null; };
  for (let i = 0; i < args.length; i++) {
    const v = args[i].value;
    if (v === '--') break;
    if (v === '-R' || v === '--repo') { take('repo', args[++i]); continue; }
    if (v === '-H' || v === '--head') { take('head', args[++i]); continue; }
    if (v.startsWith('--repo=')) { take('repo', { ...args[i], value: v.slice(7) }); continue; }
    if (v.startsWith('--head=')) { take('head', { ...args[i], value: v.slice(7) }); continue; }
    if (/^-R./.test(v)) { take('repo', { ...args[i], value: v.slice(2) }); continue; }
    if (/^-H./.test(v)) { take('head', { ...args[i], value: v.slice(2) }); continue; }
  }
  return out;
}

/** "owner/repo" (lowercased) from a remote URL or a gh `[HOST/]OWNER/REPO` value. */
export function repoSlug(value) {
  const cleaned = String(value).trim().replace(/\.git$/i, '').replace(/\/+$/, '');
  const m = cleaned.match(/([^/:]+)\/([^/:]+)$/);
  return m ? `${m[1]}/${m[2]}`.toLowerCase() : null;
}

function git(dir, ...args) {
  try {
    return execFileSync('git', ['-C', dir, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  } catch {
    return null;
  }
}

export function resolveTarget(command, cwd) {
  const hit = findPrCreate(command, cwd);
  if (!hit.found) return { status: 'none' };
  if (hit.dir === null) {
    return {
      status: 'block',
      reason: "can't tell which repo this PR comes from: a `cd` before `gh pr create` isn't a literal path. Use `cd /literal/path && gh pr create ...`",
    };
  }
  let dir = hit.dir;
  if (!existsSync(dir) || !statSync(dir).isDirectory()) {
    return { status: 'block', reason: `\`cd ${dir}\` before \`gh pr create\` points at a directory that doesn't exist` };
  }
  const top = git(dir, 'rev-parse', '--show-toplevel');
  if (top === null) return { status: 'ok', dir, rev: null, note: null }; // not a git repo: the gate fails open there
  dir = top;

  const { repo, head } = parseGhArgs(hit.args);
  const notes = [];
  if (repo === null) notes.push('--repo is not a literal value, so the checkout was not matched against it');
  if (repo) {
    const want = repoSlug(repo);
    const remotes = (git(dir, 'remote', '-v') ?? '').split('\n').map((l) => l.split(/\s+/)[1]).filter(Boolean);
    const have = [...new Set(remotes.map(repoSlug).filter(Boolean))];
    if (!want || !have.includes(want)) {
      return {
        status: 'block',
        reason: `the PR targets ${repo}, but ${dir} is a checkout of ${have.join(', ') || '(no remotes)'}. ` +
          `Run it from the target checkout so the gate checks that repo's reviews: cd <checkout of ${repo}> && gh pr create ...`,
      };
    }
  }

  let rev = null;
  if (head === null) notes.push('--head is not a literal value; checked the checkout\'s HEAD');
  if (head) {
    const branch = head.includes(':') ? head.slice(head.indexOf(':') + 1) : head;
    const current = git(dir, 'symbolic-ref', '--quiet', '--short', 'HEAD');
    if (branch !== current) {
      // Markers live in each worktree's own git dir: prefer the worktree that has the branch.
      const list = git(dir, 'worktree', 'list', '--porcelain') ?? '';
      const wt = list.split('\n\n').map((block) => ({
        path: block.match(/^worktree (.+)$/m)?.[1],
        branch: block.match(/^branch refs\/heads\/(.+)$/m)?.[1],
      })).find((w) => w.branch === branch && w.path);
      if (wt) {
        dir = wt.path;
      } else {
        rev = git(dir, 'rev-parse', '--verify', '--quiet', `refs/heads/${branch}^{commit}`);
        if (!rev) {
          return {
            status: 'block',
            reason: `--head ${head} isn't a local branch in ${dir}, so there's no way to tell which commit was reviewed. ` +
              'Run `gh pr create` from a checkout of that branch.',
          };
        }
      }
    }
  }
  return { status: 'ok', dir, rev, note: notes.length ? notes.join('; ') : null };
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  const cwd = process.argv[2] || process.cwd();
  let result;
  try {
    result = resolveTarget(readFileSync(0, 'utf8'), cwd);
  } catch (err) {
    result = { status: 'error', reason: String(err && err.message ? err.message : err) };
  }
  process.stdout.write(JSON.stringify(result) + '\n');
}
