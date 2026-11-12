#!/usr/bin/env node
// command-segments.mjs — the commands in a Bash command line, for the PreToolUse hook's bypass list.
// Reads the command on stdin; prints one line per simple command, fields separated by \x1f (unit separator), the bodies of $(...), `...`, <(...)
// and unquoted heredocs included as commands of their own (code that runs):
//   <subst> <text> <redirect targets> <alone> <assigned names>
//   subst  1 when a word holds a $(...)/`...`, or the command word itself is built at run time (`$cmd push`)
//   text   the words, unquoted, joined by spaces (a heredoc body is not a word: it is data, or its own command)
//   redirect targets  the words written to by > >> >| &> (an fd duplication like >&2 is not a target)
//   alone  1 when the command is only assignments (`HOME=/x`: it holds for the rest of the shell)
//   assigned names    the NAME= words before the command word
// Code fed to a shell on stdin (a heredoc or here-string to bash/sh/zsh/dash/ksh, or to eval/source/.) is code too:
// its commands are listed as well.
// It splits with the hook's own tokenizer (resolve-pr-target.mjs): quotes, heredocs and substitutions stay inside
// the command that holds them. Exit 1 (no output) when it can't tokenize; the hook then falls back to a cruder split.
// Part of https://github.com/job-bot-ai/ai-code-review-mcp
import { readFileSync } from 'node:fs';
import { tokenize, SHELLS, progName } from './resolve-pr-target.mjs';

const ASSIGN = /^[A-Za-z_][A-Za-z0-9_%]*\+?=/;
const flat = (s) => s.replace(/[\t\n\r]/g, ' ');

export function segments(src, out = [], depth = 0) {
  if (depth > 20) throw new Error('nested too deep');
  let words = [];
  const nested = [];
  const stdinCode = [];
  const flush = () => {
    if (words.length === 0) return;
    let i = 0;
    const names = [];
    while (i < words.length && ASSIGN.test(words[i].value)) { names.push(words[i].value.split(/\+?=/)[0]); i += 1; }
    const cmd = words[i];
    const subst = words.some((w) => w.substs.length > 0) || Boolean(cmd && cmd.dynamic);
    const targets = [];
    for (let j = 0; j < words.length; j += 1) {
      const m = words[j].value.match(/^(?:&>|>[>|]?)(.*)$/s);
      if (!m) continue;
      if (m[1].startsWith('&')) continue; // >&2: an fd, not a file
      if (m[1] === '' && words[j + 1]?.value.startsWith('>')) continue; // `>>` is two words here: the second has the target
      const t = m[1] !== '' ? m[1] : (words[j + 1]?.value ?? '');
      if (m[1] === '' && words[j + 1]) j += 1;
      targets.push(t);
    }
    const text = words.filter((w) => !w.heredoc).map((w) => w.value).join(' ');
    if (cmd && (SHELLS.has(progName(cmd)) || ['eval', 'source', '.'].includes(cmd.value))) {
      for (const w of words) {
        if (w.heredoc) stdinCode.push(w.heredoc); // its body is read after this command's line
        else if (w.herestring) nested.push(w.value);
      }
    }
    out.push([subst ? 1 : 0, flat(text), flat(targets.join(' ')), i === words.length ? 1 : 0, names.join(' ')].join('\x1f'));
    words = [];
  };
  for (const t of tokenize(src)) {
    if (t.type === 'op') { flush(); continue; }
    words.push(t);
    nested.push(...t.substs);
    if (t.heredoc?.substs) nested.push(...t.heredoc.substs);
  }
  flush();
  // Heredoc bodies are read when the tokenizer reaches them, so their substitutions are collected after the loop.
  for (const s of nested) segments(s, out, depth + 1);
  for (const h of stdinCode) segments(h.body ?? '', out, depth + 1);
  return out;
}

try {
  const lines = segments(readFileSync(0, 'utf8'));
  process.stdout.write(lines.join('\n') + (lines.length ? '\n' : ''));
} catch {
  process.exit(1);
}
