import test from 'node:test';
import assert from 'node:assert/strict';
import { homedir } from 'node:os';
import { findPrCreate, parseGhArgs, repoSlug, tokenize } from '../hooks/resolve-pr-target.mjs';

const dirOf = (cmd, cwd = '/session') => findPrCreate(cmd, cwd).dir;
const ghArgs = (cmd) => parseGhArgs(findPrCreate(cmd, '/s').args);

test('plain gh pr create runs in the session cwd', () => {
  assert.equal(dirOf('gh pr create --fill'), '/session');
});

test('follows cd before gh pr create (absolute, relative, ~, quoted, chained)', () => {
  assert.equal(dirOf('cd /repo/b && gh pr create'), '/repo/b');
  assert.equal(dirOf('cd sub; gh pr create'), '/session/sub');
  assert.equal(dirOf('cd ~/x && gh pr create'), `${homedir()}/x`);
  assert.equal(dirOf('cd "/a dir/with space" && gh pr create'), '/a dir/with space');
  assert.equal(dirOf("cd '/q' && git push && gh pr create"), '/q');
  assert.equal(dirOf('cd /a && cd ../b && gh pr create'), '/b');
  assert.equal(dirOf('cd && gh pr create'), homedir());
  assert.equal(dirOf('pushd /p >/dev/null && gh pr create'), '/p');
});

test('a cd inside a finished subshell does not apply; one inside the same subshell does', () => {
  assert.equal(dirOf('(cd /x && make); gh pr create'), '/session');
  assert.equal(dirOf('(cd /x && gh pr create)'), '/x');
  assert.equal(dirOf('{ cd /g; gh pr create; }'), '/g');
});

test('a cd that is not a literal path makes the directory unknown', () => {
  assert.equal(dirOf('cd $REPO && gh pr create'), null);
  assert.equal(dirOf('cd "$(git rev-parse --show-toplevel)" && gh pr create'), null);
  assert.equal(dirOf('cd - && gh pr create'), null);
  assert.equal(dirOf('cd /a && popd && gh pr create'), null);
  // ...but a dynamic value elsewhere doesn't matter.
  assert.equal(dirOf('cd /a && R=$(git remote get-url origin); gh pr create --repo "$R"'), '/a');
});

test('only gh pr create in command position counts', () => {
  assert.equal(findPrCreate('echo "gh pr create"', '/s').found, false);
  assert.equal(findPrCreate('grep -r gh pr create .', '/s').found, false);
  assert.equal(findPrCreate('gh pr view 12', '/s').found, false);
});

test('heredoc bodies are data: apostrophes and fake commands inside them are ignored', () => {
  const cmd = "cd /r && git commit -q -F - <<'EOF'\ndon't break\ncd /elsewhere\nEOF\ngh pr create --fill";
  assert.equal(dirOf(cmd), '/r');
  assert.equal(dirOf('cat <<-END\n\tcd /nope\n\tEND\ngh pr create'), '/session');
});

test('parses -R/--repo and -H/--head in every flag form; dynamic values are null', () => {
  assert.deepEqual(ghArgs('gh pr create --repo o/r --head b'), { repo: 'o/r', head: 'b' });
  assert.deepEqual(ghArgs('gh pr create --repo=o/r --head=fork:b'), { repo: 'o/r', head: 'fork:b' });
  assert.deepEqual(ghArgs('gh pr create -R o/r -H b'), { repo: 'o/r', head: 'b' });
  assert.deepEqual(ghArgs('gh pr create -Ro/r -Hb'), { repo: 'o/r', head: 'b' });
  assert.deepEqual(ghArgs('gh pr create --repo "$R"'), { repo: null, head: undefined });
  assert.deepEqual(ghArgs('gh pr create --title t --body-file x.md'), { repo: undefined, head: undefined });
});

test('repoSlug normalises remotes and gh repo values', () => {
  assert.equal(repoSlug('https://github.com/Job-Bot-AI/news-feed.git'), 'job-bot-ai/news-feed');
  assert.equal(repoSlug('git@github.com:job-bot-ai/job_bot_ai.git'), 'job-bot-ai/job_bot_ai');
  assert.equal(repoSlug('github.com/job-bot-ai/news-feed'), 'job-bot-ai/news-feed');
  assert.equal(repoSlug('job-bot-ai/news-feed'), 'job-bot-ai/news-feed');
  assert.equal(repoSlug('nonsense'), null);
});

test('tokenizer: operators split commands, quotes and escapes join words', () => {
  const t = tokenize('a "b c" d\\ e && f|g');
  assert.deepEqual(t.map((x) => x.value), ['a', 'b c', 'd e', '&&', 'f', '|', 'g']);
  assert.throws(() => tokenize("echo 'unterminated"));
});
