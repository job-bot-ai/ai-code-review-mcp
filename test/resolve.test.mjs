import test from 'node:test';
import assert from 'node:assert/strict';
import { homedir } from 'node:os';
import { findPrCreates, parseGhArgs, repoSlug, tokenize } from '../hooks/resolve-pr-target.mjs';

const ENV = {}; // no inherited GH_REPO / CDPATH
const hits = (cmd, cwd = '/session', env = ENV) => findPrCreates(cmd, cwd, env);
const dirOf = (cmd, cwd, env) => {
  const h = hits(cmd, cwd, env);
  assert.equal(h.length, 1, `expected one gh pr create in: ${cmd}`);
  return h[0].dir;
};
const ghArgs = (cmd) => parseGhArgs(hits(cmd)[0].args);

test('plain gh pr create runs in the session cwd', () => {
  assert.equal(dirOf('gh pr create --fill'), '/session');
});

test('follows cd before gh pr create (absolute, relative, ~, $HOME, quoted, chained)', () => {
  assert.equal(dirOf('cd /repo/b && gh pr create'), '/repo/b');
  assert.equal(dirOf('cd sub; gh pr create'), '/session/sub');
  assert.equal(dirOf('cd ~/x && gh pr create'), `${homedir()}/x`);
  assert.equal(dirOf('cd "$HOME/x" && gh pr create'), `${homedir()}/x`);
  assert.equal(dirOf('cd ${HOME}/y && gh pr create'), `${homedir()}/y`);
  assert.equal(dirOf('cd "~/x" && gh pr create'), '/session/~/x'); // quoted ~ is literal in bash
  assert.equal(dirOf('cd "/a dir/with space" && gh pr create'), '/a dir/with space');
  assert.equal(dirOf("cd '/q' && git push && gh pr create"), '/q');
  assert.equal(dirOf('cd /a && cd ../b && gh pr create'), '/b');
  assert.equal(dirOf('cd && gh pr create'), homedir());
  assert.equal(dirOf('cd /x >/dev/null 2>&1 && gh pr create'), '/x');
  assert.equal(dirOf('cd /x>/dev/null && gh pr create'), '/x');
  assert.equal(dirOf('builtin cd /b && gh pr create'), '/b');
  assert.equal(dirOf('command cd /c && gh pr create'), '/c');
});

test('pushd/popd keep a directory stack', () => {
  assert.equal(dirOf('pushd /p >/dev/null && gh pr create'), '/p');
  assert.equal(dirOf('pushd /a && pushd /b && popd && gh pr create'), '/a');
  assert.equal(dirOf('popd && gh pr create'), null);
});

test('scoping: subshells, pipelines and background jobs do not leak a cd', () => {
  assert.equal(dirOf('(cd /x && make); gh pr create'), '/session');
  assert.equal(dirOf('(cd /x && gh pr create)'), '/x');
  assert.equal(dirOf('{ cd /g; gh pr create; }'), '/g');
  assert.equal(dirOf('cd /green | gh pr create'), '/session');
  assert.equal(dirOf('cd /green & gh pr create'), '/session');
  assert.equal(dirOf('echo x | cd /green; gh pr create'), '/session');
});

test('a cd that may or may not run, or is not a literal path, makes the directory unknown', () => {
  for (const cmd of [
    'cd $REPO && gh pr create',
    'cd "$(git rev-parse --show-toplevel)" && gh pr create',
    'cd - && gh pr create',
    'cd /unrev || cd /green && gh pr create',
    'if cd /unrev; then\n  gh pr create\nfi',
    'if [ -d /x ]; then cd /x; fi; gh pr create',
    'case x in y) cd /green ;; esac; gh pr create',
    'for d in /a /b; do cd $d; done; gh pr create',
    'f() { cd /green; }; gh pr create',
    'eval cd /x && gh pr create',
    'eval "cd /x" && gh pr create',
    'CDPATH=/z cd x && gh pr create',
    'cd ~other/x && gh pr create',
  ]) assert.equal(dirOf(cmd), null, cmd);
  assert.equal(dirOf('export CDPATH=/z; cd x && gh pr create'), null);
  assert.equal(dirOf('cd x && gh pr create', '/s', { CDPATH: '/z' }), null);
  assert.equal(dirOf('cd /abs && gh pr create', '/s', { CDPATH: '/z' }), '/abs');
  // a dynamic value elsewhere doesn't matter
  assert.equal(dirOf('cd /a && R=$(git remote get-url origin); gh pr create --repo "$R"'), '/a');
  // a gh pr create inside a function body runs later, from wherever it's called
  assert.equal(dirOf('f() { cd /x && gh pr create; }; f'), null);
});

test('every gh pr create is found, each with its own directory', () => {
  assert.deepEqual(hits('gh pr create --fill && cd /unrev && gh pr create --fill').map((h) => h.dir), ['/session', '/unrev']);
});

test('only gh pr create in command position counts', () => {
  assert.equal(hits('echo "gh pr create"').length, 0);
  assert.equal(hits('grep -r gh pr create .').length, 0);
  assert.equal(hits('gh pr view 12').length, 0);
  assert.equal(hits("bash -c 'cd /x && gh pr create'").length, 0);
});

test('heredocs and $(...) bodies are nested code/data, not top-level commands', () => {
  const commit = "cd /r && git commit -q -F - <<'EOF'\ndon't break\ncd /elsewhere\nEOF\ngh pr create --fill";
  assert.equal(dirOf(commit), '/r');
  assert.equal(dirOf('cat <<-END\n\tcd /nope\n\tEND\ngh pr create'), '/session');
  // The usual PR-body pattern: a quoted $(cat <<'EOF' ...) with quotes and # inside.
  const body = 'cd /unrev && gh pr create --title "x" --body "$(cat <<\'EOF\'\n- see "issue #12" for context\nit\'s fine (really)\nEOF\n)"';
  assert.equal(dirOf(body), '/unrev');
  assert.equal(dirOf("cd /a && gh pr create --title $'it\\'s'"), '/a');
  assert.equal(dirOf('cd /a && gh pr create --title "`date`" --body "${X:-"y"}"'), '/a');
});

test('parses -R/--repo, -H/--head, help, clustered short flags and value flags (pflag rules)', () => {
  const p = (cmd) => { const { repo, head, help, opaque } = ghArgs(cmd); return { repo, head, help, opaque }; };
  assert.deepEqual(p('gh pr create --repo o/r --head b'), { repo: 'o/r', head: 'b', help: false, opaque: null });
  assert.deepEqual(p('gh pr create --repo=o/r --head=fork:b'), { repo: 'o/r', head: 'fork:b', help: false, opaque: null });
  assert.deepEqual(p('gh pr create -R o/r -H b'), { repo: 'o/r', head: 'b', help: false, opaque: null });
  assert.deepEqual(p('gh pr create -Ro/r -Hb'), { repo: 'o/r', head: 'b', help: false, opaque: null });
  assert.equal(p('gh pr create -dH feat/x --fill').head, 'feat/x');
  assert.equal(p('gh pr create -dfHfeat/y').head, 'feat/y');
  assert.equal(p('gh pr create -H=x').head, 'x');
  assert.equal(p('gh pr create --title -H --fill').head, undefined); // -H is the title's value
  assert.equal(p('gh pr create -t -R').repo, undefined);
  assert.equal(p('gh pr create --repo "$R"').repo, null);
  assert.equal(p('gh pr create --help').help, true);
  assert.equal(p('gh pr create -h').help, true);
  assert.equal(p("gh pr create --fill --body 'use -h for help'").help, false);
  assert.equal(p('gh pr create $ARGS').opaque, '$ARGS');
  assert.equal(p('gh pr create --title "$T" --body "$(cat x)"').opaque, null);
});

test('GH_REPO from the environment, an export or a prefix applies to gh', () => {
  assert.equal(hits('gh pr create', '/s', { GH_REPO: 'o/env' })[0].ghRepo, 'o/env');
  assert.equal(hits('export GH_REPO=o/r; gh pr create')[0].ghRepo, 'o/r');
  assert.equal(hits('true; GH_REPO=o/p gh pr create')[0].ghRepo, 'o/p');
  assert.equal(hits('(export GH_REPO=o/sub); gh pr create')[0].ghRepo, undefined);
});

test('repoSlug normalises remotes and gh repo values', () => {
  assert.equal(repoSlug('https://github.com/Job-Bot-AI/news-feed.git'), 'job-bot-ai/news-feed');
  assert.equal(repoSlug('git@github.com:job-bot-ai/job_bot_ai.git'), 'job-bot-ai/job_bot_ai');
  assert.equal(repoSlug('github.com/job-bot-ai/news-feed'), 'job-bot-ai/news-feed');
  assert.equal(repoSlug('job-bot-ai/news-feed'), 'job-bot-ai/news-feed');
  assert.equal(repoSlug('nonsense'), null);
});

test('tokenizer: operators split commands, quotes and escapes join words, errors are thrown', () => {
  const t = tokenize('a "b c" d\\ e && f|g ;; h');
  assert.deepEqual(t.map((x) => x.value), ['a', 'b c', 'd e', '&&', 'f', '|', 'g', ';', 'h']);
  assert.deepEqual(tokenize('a#b # comment').map((x) => x.value), ['a#b']);
  assert.throws(() => tokenize("echo 'unterminated"));
  assert.throws(() => tokenize('echo "$(unterminated'));
});
