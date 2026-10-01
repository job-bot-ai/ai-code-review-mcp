import test from 'node:test';
import assert from 'node:assert/strict';
import { homedir } from 'node:os';
import { awkRuns, findPrCreates, parseGhArgs, repoSlug, tokenize } from '../hooks/resolve-pr-target.mjs';

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
});

test('code that runs in a subshell is walked: $(...), backticks, <(...), bash -c, eval', () => {
  assert.deepEqual(hits("bash -c 'cd /x && gh pr create'").map((h) => h.dir), ['/x']);
  assert.deepEqual(hits('cd /a && PR_URL=$(gh pr create --head x --fill)').map((h) => h.dir), ['/a']);
  assert.deepEqual(hits('cd /a && echo "$(cd /b && gh pr create)"').map((h) => h.dir), ['/b']);
  assert.deepEqual(hits('cd /a && echo `gh pr create`').map((h) => h.dir), ['/a']);
  assert.deepEqual(hits('eval gh pr create --fill').map((h) => h.dir), ['/session']);
  assert.deepEqual(hits('timeout 60 gh pr create --fill').map((h) => h.dir), ['/session']);
  assert.deepEqual(hits('env -C /x gh pr create').map((h) => h.dir), [null]);
  // a cd inside a substitution doesn't move the outer shell
  assert.equal(dirOf('x=$(cd /b); gh pr create'), '/session');
});

test('gh pr create mentioned only as data is not a PR', () => {
  const commit = 'cd /w && git commit -m "$(cat <<\'EOF\'\ngh pr create --repo o/r used to be gated\nEOF\n)"';
  assert.equal(hits(commit).length, 0);
  assert.equal(hits("cat > x.sh <<'EOF'\ncd \"$1\"\ngh pr create --fill\nEOF").length, 0);
});

test('round-2 shell model: && lists, case in subshell, indirect cd, recovery, pushes', () => {
  assert.equal(dirOf('false && cd /green; gh pr create'), null);
  assert.equal(dirOf('cd /a && git push && gh pr create'), '/a');
  assert.equal(dirOf('cd /a && make &\ngh pr create'), '/session'); // backgrounded list is a subshell
  assert.equal(dirOf('(case x in y) ;; esac; cd /green); gh pr create'), '/session');
  assert.equal(dirOf("$'cd' /x && gh pr create"), '/x');
  assert.equal(dirOf('eval "$(echo cd /x)" && gh pr create'), null);
  assert.equal(dirOf('source <(echo cd /x) && gh pr create'), null);
  assert.equal(dirOf('cd "$(git rev-parse --show-toplevel)"; cd /repo && gh pr create'), '/repo');
  const [h] = hits('git push -u origin HEAD:nice-name && gh pr create --head nice-name');
  assert.deepEqual(h.pushes, [{ dir: '/session', src: 'HEAD', dst: 'nice-name' }]);
  assert.deepEqual(hits('git -C /r push origin +feat:refs/heads/x; gh pr create')[0].pushes, [{ dir: '/r', src: 'feat', dst: 'x' }]);
});

test('round 3: code fed to a shell on stdin, dynamic eval/-c scripts, data sinks vs opaque', () => {
  assert.deepEqual(hits("bash <<'EOF'\ncd /u\ngh pr create --fill\nEOF").map((h) => h.dir), ['/u']);
  assert.deepEqual(hits('bash <<< "cd /u && gh pr create --fill"').map((h) => h.dir), ['/u']);
  assert.deepEqual(hits('T=x; eval "cd /u && gh pr create --fill --title $T"').map((h) => h.dir), ['/u']);
  assert.deepEqual(hits('T=x; bash -c "cd /u && gh pr create --fill --title $T"').map((h) => h.dir), ['/u']);
  assert.deepEqual(hits('cat <<EOF\n$(cd /u && gh pr create)\nEOF').map((h) => h.dir), ['/u']); // unquoted heredoc expands
  assert.equal(hits("cat <<'EOF'\n$(gh pr create)\nEOF").length, 0); // quoted heredoc doesn't
  const data = hits("cat > x.sh <<'EOF'\ngh pr create\nEOF");
  assert.equal(data.length, 0); assert.equal(data.opaque, undefined);
  const remote = hits("ssh host 'cd x && gh pr create'");
  assert.equal(remote.length, 0); assert.equal(remote.opaque, 'ssh');
  assert.equal(hits("bash ./deploy.sh <<'EOF'\ngh pr create\nEOF").opaque, 'bash ./deploy.sh');
  assert.equal(hits('env GH_REPO=o/r gh pr create')[0].ghRepo, 'o/r');
});

test('round 3: list continuation across newlines; && before a { } group is conditional', () => {
  assert.equal(dirOf('false &&\ncd /green\ngh pr create --fill'), null);
  assert.equal(dirOf('false && { true; cd /green; }; gh pr create --fill'), null);
  assert.equal(dirOf('{ cd /g; }; gh pr create'), '/g');
  assert.equal(dirOf('cd /a &&\n  git push &&\n  gh pr create'), '/a');
});

test('round 4: code piped into a shell, <(...) scripts, awk, interpreters, groups, pushes', () => {
  assert.deepEqual(hits("cat <<'EOF' | bash\ncd /u\ngh pr create --fill\nEOF").map((h) => h.dir), ['/u']);
  assert.deepEqual(hits('echo "cd /u && gh pr create --fill" | bash').map((h) => h.dir), ['/u']);
  assert.deepEqual(hits("printf '%s' 'gh pr create' | sh -s").map((h) => h.dir), ['/session']);
  assert.equal(hits("bash <(echo 'cd /u && gh pr create --fill')").opaque, 'bash <(...)');
  assert.equal(hits(`awk 'BEGIN{system("cd /u && gh pr create --fill")}'`).opaque, 'awk');
  assert.equal(hits(`python3 -c "import os; os.system('gh pr create')"`).opaque, 'python3 -c');
  const edit = hits("python3 - <<'EOF'\nopen('t', 'w').write('cd r && gh pr create')\nEOF");
  assert.equal(edit.length, 0); assert.equal(edit.opaque, undefined);
  assert.deepEqual(hits("bash -euo pipefail <<'EOF'\ncd /w\ngh pr create --fill\nEOF").map((h) => h.dir), ['/w']);
  assert.equal(dirOf('test -d /w && { cd /w; gh pr create --fill; }'), '/w');
  assert.equal(dirOf('test -d /w && { cd /w; }; gh pr create'), null);
  assert.equal(dirOf('if true; then cd /w && gh pr create; fi'), null); // if-bodies stay conservative
  assert.deepEqual(hits('(git push -f origin HEAD:feat/x) && gh pr create --head feat/x')[0].pushes,
    [{ dir: '/session', src: 'HEAD', dst: 'feat/x' }]);
});

test('agy review: piped words, push --repo, sed/awk only opaque when they run commands', () => {
  assert.deepEqual(hits("echo cd /u '&&' gh pr create --fill | bash").map((h) => h.dir), ['/u']);
  assert.deepEqual(hits("printf '%s\\n' 'cd /u' 'gh pr create --fill' | bash").map((h) => h.dir), ['/u']);
  assert.deepEqual(hits('git push --repo origin HEAD:feat && gh pr create --head feat')[0].pushes,
    [{ dir: '/session', src: 'HEAD', dst: 'feat' }]);
  const edit = hits("sed -i 's/gh pr create --fill/gh pr create --draft/' notes.md");
  assert.equal(edit.length, 0); assert.equal(edit.opaque, undefined);
  assert.equal(hits(`awk '/gh pr create/ {n++} END {print n}' log`).opaque, undefined);
  assert.equal(hits(`awk 'BEGIN{system("gh pr create --fill")}'`).opaque, 'awk');
  assert.equal(hits("sed 's/.*/gh pr create --fill/e' x").opaque, 'sed');
});

test('agy re-review: single-arg printf and echo -e into a shell; awk || is not execution', () => {
  assert.deepEqual(hits("printf 'cd /u && gh pr create --fill\\n' | bash").map((h) => h.dir), ['/u']);
  assert.deepEqual(hits("echo -e 'cd /u\\ngh pr create --fill' | bash").map((h) => h.dir), ['/u']);
  assert.equal(hits("cd /r && awk '/gh pr create/ || count++' log.txt").opaque, undefined);
  assert.equal(hits("awk '/gh pr create|gh pr view/ {n++}' log").opaque, undefined);
  assert.equal(hits(`awk '{print "gh pr create --fill" | "sh"}'`).opaque, 'awk');
  assert.equal(hits(`awk 'BEGIN{"gh pr create" | getline x}'`).opaque, 'awk');
});

test('awkRuns: execution forms vs data processing', () => {
  for (const prog of ['BEGIN{system("x")}', 'BEGIN{("cd /u && gh pr create") | getline}', '{print "x" | "sh"}',
    'BEGIN{"date" | getline d}', '{print |& "coproc"}']) assert.equal(awkRuns(prog), true, prog);
  for (const prog of ['/gh pr create/ || count++', '/gh pr create|gh pr view/ {n++}',
    '{\n  print "gh pr create"\n  fallback || "default"\n}', '{ s = "a|b" } END { print n }',
    '/gh pr create/ { getline; print }']) assert.equal(awkRuns(prog), false, prog);
  assert.equal(hits("git log --format='%h|%s' | awk -F'|' '/gh pr create/ { print $1 }'").opaque, undefined);
  assert.equal(hits("awk -F '|' -v x=1 '/gh pr create/ { print $1 }' f").opaque, undefined);
  assert.equal(hits("awk -f prog.awk 'gh pr create' f").opaque, 'awk -f');
  assert.equal(hits("echo 'cd /u && gh pr create --fill' | ssh host").opaque, 'ssh');
  assert.equal(hits("echo 'gh pr create' | grep -c create").opaque, undefined);
});

test('case arms: patterns vs subshells inside an arm', () => {
  assert.deepEqual(hits('case x in y) (gh pr create --fill) ;; esac').map((h) => h.dir), ['/session']);
  assert.deepEqual(hits('case $1 in\n  (a|b) gh pr create ;;\n  c) (cd /u && gh pr create) ;&\n  *) true ;;\nesac').map((h) => h.dir), ['/session', null]);
  assert.equal(dirOf('(case x in y) ;; esac; cd /green); gh pr create'), '/session');
  assert.equal(dirOf('case x in y) cd /green ;; esac; gh pr create'), null);
});

test('piped text survives pass-through filters', () => {
  assert.deepEqual(hits("echo 'cd /u && gh pr create' | cat | sort | bash").map((h) => h.dir), ['/u']);
});

test('gh pr new is the same command as gh pr create', () => {
  assert.deepEqual(hits('cd /u && gh pr new --fill').map((h) => h.dir), ['/u']);
});

test('gh by path; pushes made in nested scripts reach the outer gh pr create', () => {
  assert.deepEqual(hits('cd /u && /usr/bin/gh pr create --fill').map((h) => h.dir), ['/u']);
  assert.deepEqual(hits("bash -c 'git push origin HEAD:x'; gh pr create --head x")[0].pushes,
    [{ dir: '/session', src: 'HEAD', dst: 'x' }]);
});

test('gh pr create as split arguments of another command is gated like a runner', () => {
  assert.deepEqual(hits('cd /u && op run -- gh pr create --fill').map((h) => h.dir), ['/u']);
  assert.deepEqual(hits('doppler run -- gh pr new --fill').map((h) => h.dir), ['/session']);
  assert.deepEqual(hits('ssh host gh pr create --fill').map((h) => h.dir), ['/session']);
  assert.equal(hits('echo gh pr create | cat').length, 0); // a data sink just prints it
  assert.equal(hits("ssh host 'cd /x && gh' 'pr create'").opaque, 'ssh'); // split, not a clean word run
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
  assert.deepEqual(t.map((x) => x.value), ['a', 'b c', 'd e', '&&', 'f', '|', 'g', ';;', 'h']);
  assert.deepEqual(tokenize('a#b # comment').map((x) => x.value), ['a#b']);
  assert.throws(() => tokenize("echo 'unterminated"));
  assert.throws(() => tokenize('echo "$(unterminated'));
});
