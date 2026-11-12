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
//   written  for cp/mv/ln/install/rsync (also behind sudo/env/timeout/nice/nohup/exec): the paths it writes, the
//            destination (the last operand, or -t DIR) and, for mv, its sources too (moving one away removes it);
//            every operand when a word is built at run time
//   copier   1 when written was worked out; 0 otherwise (the hook then treats any path in the command as written)
// Code fed to a shell on stdin (a heredoc or here-string to bash/sh/zsh/dash/ksh, or to eval/source/.) is code too:
// its commands are listed as well.
// It splits with the hook's own tokenizer (resolve-pr-target.mjs): quotes, heredocs and substitutions stay inside
// the command that holds them. Exit 1 (no output) when it can't tokenize; the hook then falls back to a cruder split.
// Part of https://github.com/job-bot-ai/ai-code-review-mcp
import { readFileSync } from 'node:fs';
import { tokenize, SHELLS, progName, runnerExec } from './resolve-pr-target.mjs';

const ASSIGN = /^[A-Za-z_][A-Za-z0-9_%]*\+?=/;
const COPIERS = new Set(['cp', 'mv', 'ln', 'install', 'rsync']);
// Each copier's options (GNU coreutils, rsync): short letters with no value, short letters that take one, long options
// that take one (`--suffix .bak` or `--suffix=.bak`), and long options without one (or only `--opt=value`). Anything
// else and the destination can't be told: the hook then treats any protected path in the command as written.
const BACKUP = ['--backup', '--force', '--interactive', '--no-target-directory', '--verbose', '--strip-trailing-slashes', '--debug', '--context'];
const COPIER_OPTS = {
  cp: { flags: 'abdfHilLnPpRrsTuvxZ', args: 'St', argLong: ['--suffix', '--target-directory', '--no-preserve', '--sparse'],
    flagLong: [...BACKUP, '--archive', '--attributes-only', '--copy-contents', '--dereference', '--link', '--no-dereference',
      '--no-clobber', '--one-file-system', '--parents', '--preserve', '--recursive', '--remove-destination', '--symbolic-link',
      '--update', '--reflink', '--keep-directory-symlink'] },
  mv: { flags: 'bfinTuvZ', args: 'St', argLong: ['--suffix', '--target-directory'],
    flagLong: [...BACKUP, '--no-clobber', '--no-copy', '--update', '--exchange'] },
  ln: { flags: 'bdFfinLPrsTv', args: 'St', argLong: ['--suffix', '--target-directory'],
    flagLong: [...BACKUP, '--directory', '--logical', '--no-dereference', '--physical', '--relative', '--symbolic'] },
  install: { flags: 'bcCdDpsTvZ', args: 'gmoSt', argLong: ['--group', '--mode', '--owner', '--suffix', '--target-directory', '--strip-program'],
    flagLong: [...BACKUP, '--compare', '--directory', '--preserve-timestamps', '--strip', '--preserve-context'] },
  // rsync 3.4's own `rsync --help` (plus -P, -D, -F, listed there in another form); `--no-<flag>` too.
  rsync: { flags: 'vqcarRbudlLkKHpEAXogtUNOJSnWxmIyzC0s8hi46VhPDF', args: 'BeTfM',
    argLong: [
      '--address', '--backup-dir', '--block-size', '--bwlimit', '--checksum-choice', '--checksum-seed', '--chmod',
      '--chown', '--compare-dest', '--compress-choice', '--compress-level', '--contimeout', '--copy-as',
      '--copy-dest', '--debug', '--early-input', '--exclude', '--exclude-from', '--files-from', '--filter',
      '--groupmap', '--iconv', '--include', '--include-from', '--info', '--link-dest', '--log-file',
      '--log-file-format', '--max-alloc', '--max-delete', '--max-size', '--min-size', '--only-write-batch',
      '--out-format', '--outbuf', '--partial-dir', '--password-file', '--port', '--protocol', '--read-batch',
      '--remote-option', '--rsh', '--rsync-path', '--skip-compress', '--sockopts', '--stderr', '--stop-after',
      '--stop-at', '--suffix', '--temp-dir', '--timeout', '--usermap', '--write-batch'],
    flagLong: [
      '--8-bit-output', '--acls', '--append', '--append-verify', '--archive', '--atimes', '--backup',
      '--blocking-io', '--checksum', '--compress', '--copy-devices', '--copy-dirlinks', '--copy-links',
      '--copy-unsafe-links', '--crtimes', '--cvs-exclude', '--del', '--delay-updates', '--delete', '--delete-after',
      '--delete-before', '--delete-delay', '--delete-during', '--delete-excluded', '--delete-missing-args',
      '--devices', '--dirs', '--dry-run', '--executability', '--existing', '--fake-super', '--force', '--from0',
      '--fsync', '--fuzzy', '--group', '--hard-links', '--help', '--human-readable', '--ignore-errors',
      '--ignore-existing', '--ignore-missing-args', '--ignore-times', '--inplace', '--ipv4', '--ipv6',
      '--itemize-changes', '--keep-dirlinks', '--links', '--list-only', '--mkpath', '--munge-links',
      '--no-implied-dirs', '--no-motd', '--numeric-ids', '--old-args', '--omit-dir-times', '--omit-link-times',
      '--one-file-system', '--open-noatime', '--owner', '--partial', '--perms', '--preallocate', '--progress',
      '--prune-empty-dirs', '--quiet', '--recursive', '--relative', '--remove-source-files', '--safe-links',
      '--secluded-args', '--size-only', '--sparse', '--specials', '--stats', '--super', '--times', '--trust-sender',
      '--update', '--verbose', '--version', '--whole-file', '--write-devices', '--xattrs'] },
};

const REDIRECT = /^(?:&>>?|>&|<&|>>?\|?|<<?<?|<>)/; // the operator at the start of a tokenizer word
/**
 * A command's words without its redirects: the operator word (`>/dev/null`, `>&1`, `</dev/null`, `&>log`), a bare
 * operator's target word (`>` `log`; `>>` is two `>` words), an fd number in front of an operator (`2>/dev/null` is
 * `2` `>/dev/null`), heredocs and here-strings. Redirect targets are checked as writes separately (field 3).
 */
function withoutRedirects(words) {
  const out = [];
  for (let j = 0; j < words.length; j += 1) {
    const w = words[j];
    if (w.heredoc || w.herestring || w.value === '<<' || w.value === '<<<') continue;
    if (/^\d+$/.test(w.value) && REDIRECT.test(words[j + 1]?.value ?? '')) continue; // the 2 of 2>file
    const m = w.value.match(REDIRECT);
    if (!m) { out.push(w); continue; }
    // A bare operator (nothing after it in this word) takes the next word: its target, or the fd of `>& 2`.
    if (w.value.length === m[0].length) {
      while (words[j + 1] && REDIRECT.test(words[j + 1].value) && words[j + 1].value === '>') j += 1; // `>` `>` = >>
      j += 1;
    }
  }
  return out;
}

/** The paths a cp/mv/ln/install/rsync command writes: [written[], parsed]. */
function copierWrites(words, k) {
  const prog = progName(words[k]);
  if (!COPIERS.has(prog)) return [[], false];
  const args = withoutRedirects(words.slice(k + 1));
  const spec = COPIER_OPTS[prog];
  const operands = [];
  let target = null;
  let endOpts = false;
  for (let a = 0; a < args.length; a += 1) {
    const v = args[a].value;
    if (endOpts || v === '-' || !v.startsWith('-')) { operands.push(v); continue; }
    if (v === '--') { endOpts = true; continue; }
    if (v.startsWith('--')) {
      const eq = v.indexOf('=');
      const name = eq < 0 ? v : v.slice(0, eq);
      let value = eq < 0 ? null : v.slice(eq + 1);
      if (spec.argLong.includes(name)) {
        if (value === null) { value = args[a + 1]?.value ?? ''; a += 1; } // `--suffix .bak`: the value is not an operand
      } else if (value === null && !spec.flagLong.includes(name) && !spec.flagLong.includes(name.replace(/^--no-/, '--'))) {
        // A bare long option we don't know: it might take the next word, so the destination can't be told. (With
        // `=value` attached it can't take another word: `--info=progress2` is self-contained.)
        return [[], false];
      }
      if (name === '--target-directory') target = value;
      continue;
    }
    // A short-option cluster: a value-taking letter takes the rest of the word, or the next word.
    for (let j = 1; j < v.length; j += 1) {
      const ch = v[j];
      if (spec.flags.includes(ch)) continue;
      if (!spec.args.includes(ch)) return [[], false];
      let value = v.slice(j + 1);
      if (value === '') { value = args[a + 1]?.value ?? ''; a += 1; }
      if (ch === 't') target = value;
      break;
    }
  }
  // A word built at run time could be an option (-t DIR) or a path: every operand counts as written.
  if (args.some((w) => w.dynamic)) return [operands.concat(target ?? []), true];
  const written = [];
  if (target !== null) written.push(target);
  else if (operands.length) written.push(operands[operands.length - 1]);
  if (prog === 'mv') written.push(...(target !== null ? operands : operands.slice(0, -1)));
  if (prog === 'rsync' && args.some((w) => w.value === '--remove-source-files')) written.push(...operands);
  return [written, true];
}
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
      if (m[1] === '&' && !/^(?:\d+-?|-)$/.test(words[j + 1]?.value ?? '')) { targets.push(words[j + 1]?.value ?? ''); j += 1; continue; } // >& FILE
      if (m[1].startsWith('&')) continue; // >&2: an fd, not a file
      if (m[1] === '' && words[j + 1]?.value.startsWith('>')) continue; // `>>` is two words here: the second has the target
      const t = m[1] !== '' ? m[1] : (words[j + 1]?.value ?? '');
      if (m[1] === '' && words[j + 1]) j += 1;
      targets.push(t);
    }
    const text = words.filter((w) => !w.heredoc).map((w) => w.value).join(' ');
    let k = i;
    for (let n = 0; n < 5 && words[k]; n += 1) { const r = runnerExec(words.slice(k)); if (!r) break; k += r.k; }
    const [written, copier] = words[k] ? copierWrites(words, k) : [[], false];
    if (cmd && (SHELLS.has(progName(cmd)) || ['eval', 'source', '.'].includes(cmd.value))) {
      for (const w of words) {
        if (w.heredoc) stdinCode.push(w.heredoc); // its body is read after this command's line
        else if (w.herestring) nested.push(w.value);
      }
    }
    out.push([subst ? 1 : 0, flat(text), flat(targets.join(' ')), i === words.length ? 1 : 0, names.join(' '),
      flat(written.join(' ')), copier ? 1 : 0].join('\x1f'));
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
