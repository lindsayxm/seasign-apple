#!/usr/bin/env node
// Task CLI + board server. Zero dependencies. See tasks/README.md.
// One markdown file per task; every change goes through this script so that
// state transitions are validated and writes are atomic.

import fs from 'node:fs';
import path from 'node:path';
import http from 'node:http';
import { fileURLToPath } from 'node:url';

const DIR = path.dirname(fileURLToPath(import.meta.url));
const LOCK = path.join(DIR, '.lock');
const TASK_FILE = /^(\d{4,})-[a-z0-9-]*\.md$/;

const STATES = ['backlog', 'todo', 'in-progress', 'review', 'done', 'blocked', 'cancelled'];
const CLOSED = ['done', 'cancelled'];
const TRANSITIONS = {
  backlog: ['todo', 'cancelled'],
  todo: ['backlog', 'in-progress', 'blocked', 'cancelled'],
  'in-progress': ['review', 'todo', 'blocked', 'cancelled'],
  review: ['done', 'in-progress', 'cancelled'],
  blocked: ['todo', 'in-progress', 'cancelled'],
  done: [],
  cancelled: [],
};
const SECTIONS = ['Goal', 'Acceptance criteria', 'Relevant files', "What's been tried", 'Log'];
const SECTION_KEYS = { goal: 'Goal', criteria: 'Acceptance criteria', files: 'Relevant files' };

class UserError extends Error {}
const fail = (msg) => { throw new UserError(msg); };
const now = () => new Date().toISOString().replace(/\.\d+Z$/, 'Z');

// ---------- locking & atomic writes ----------

function sleep(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function withLock(fn) {
  const deadline = Date.now() + 10_000;
  for (;;) {
    try {
      fs.mkdirSync(LOCK);
      break;
    } catch (e) {
      if (e.code !== 'EEXIST') throw e;
      try {
        // A lock older than 15s belongs to a crashed process.
        if (Date.now() - fs.statSync(LOCK).mtimeMs > 15_000) fs.rmdirSync(LOCK);
      } catch { /* someone else released or removed it */ }
      if (Date.now() > deadline) fail('could not get the task lock (tasks/.lock); try again');
      sleep(15 + Math.floor(Math.random() * 30));
    }
  }
  try {
    return fn();
  } finally {
    try { fs.rmdirSync(LOCK); } catch { /* already gone */ }
  }
}

function writeAtomic(file, text) {
  const tmp = path.join(DIR, `.tmp-${process.pid}-${path.basename(file)}`);
  fs.writeFileSync(tmp, text);
  fs.renameSync(tmp, file);
}

// ---------- file format ----------

function parse(text, file) {
  const m = text.match(/^---\n([\s\S]*?)\n---\n?([\s\S]*)$/);
  if (!m) fail(`${file}: missing frontmatter`);
  const meta = {};
  for (const line of m[1].split('\n')) {
    const i = line.indexOf(':');
    if (i > 0) meta[line.slice(0, i).trim()] = line.slice(i + 1).trim();
  }
  const id = Number(meta.id);
  if (!Number.isInteger(id)) fail(`${file}: bad id`);
  if (!STATES.includes(meta.status)) fail(`${file}: bad status "${meta.status}"`);
  const depends_on = (meta.depends_on || '').replace(/[[\]]/g, '').split(',')
    .map((s) => s.trim()).filter(Boolean).map(Number);
  if (depends_on.some((d) => !Number.isInteger(d))) fail(`${file}: bad depends_on`);

  const sections = [];
  let cur = null;
  for (const line of m[2].split('\n')) {
    const h = line.match(/^## (.+)$/);
    if (h) { cur = { heading: h[1].trim(), lines: [] }; sections.push(cur); }
    else if (cur) cur.lines.push(line);
  }
  const body = {};
  for (const s of sections) body[s.heading] = s.lines.join('\n').trim();
  for (const s of SECTIONS) body[s] ??= '';

  return {
    id, title: meta.title || '', status: meta.status, owner: meta.owner || '',
    depends_on, created: meta.created || '', updated: meta.updated || '', body, file,
  };
}

function serialize(t) {
  const extra = Object.keys(t.body).filter((h) => !SECTIONS.includes(h));
  const order = [...SECTIONS.slice(0, -1), ...extra, 'Log'];
  const head = [
    '---',
    `id: ${t.id}`,
    `title: ${t.title}`,
    `status: ${t.status}`,
    `owner: ${t.owner}`,
    `depends_on: [${t.depends_on.join(', ')}]`,
    `created: ${t.created}`,
    `updated: ${t.updated}`,
    '---',
  ].join('\n');
  const body = order.map((h) => `## ${h}\n\n${t.body[h] ? t.body[h] + '\n' : ''}`).join('\n');
  return `${head}\n\n${body}`;
}

function taskFiles() {
  return fs.readdirSync(DIR).filter((f) => TASK_FILE.test(f)).sort();
}

function parseId(raw) {
  const id = Number(String(raw ?? '').replace(/^#/, ''));
  if (!Number.isInteger(id) || id < 1) fail(`expected a task id, got "${raw ?? ''}"`);
  return id;
}

function load(rawId) {
  const id = parseId(rawId);
  const file = taskFiles().find((f) => Number(f.match(TASK_FILE)[1]) === id);
  if (!file) fail(`task #${id} not found`);
  return parse(fs.readFileSync(path.join(DIR, file), 'utf8'), file);
}

function loadAll() {
  const tasks = [];
  const errors = [];
  for (const f of taskFiles()) {
    try { tasks.push(parse(fs.readFileSync(path.join(DIR, f), 'utf8'), f)); }
    catch (e) { errors.push(e.message); }
  }
  return { tasks, errors };
}

function save(t) {
  t.updated = now();
  writeAtomic(path.join(DIR, t.file), serialize(t));
}

function addLog(t, who, text) {
  const entry = `- ${now()} [${who}] ${String(text).trim().replace(/\n/g, '\n  ')}`;
  t.body.Log = t.body.Log ? `${t.body.Log}\n${entry}` : entry;
}

const oneLine = (s) => String(s).replace(/\s+/g, ' ').trim();
const actor = (flags, t) => oneLine(flags.by || flags.owner || process.env.TASK_OWNER || t?.owner || process.env.USER || 'unknown');

// Read-modify-write one task under the lock.
function mutate(rawId, fn) {
  return withLock(() => {
    const t = load(rawId);
    fn(t);
    save(t);
    return t;
  });
}

function move(t, to, who, why) {
  if (!STATES.includes(to)) fail(`unknown status "${to}". Valid: ${STATES.join(', ')}`);
  if (t.status === to) fail(`#${t.id} is already ${to}`);
  if (!TRANSITIONS[t.status].includes(to)) {
    const next = TRANSITIONS[t.status].join(', ') || 'nothing (it is closed)';
    fail(`#${t.id} cannot go ${t.status} → ${to}. From ${t.status} it can go to: ${next}`);
  }
  if (to === 'in-progress' && !t.owner) fail(`#${t.id} has no owner. Use: task claim ${t.id}`);
  const from = t.status;
  t.status = to;
  if (to === 'todo' || to === 'backlog') t.owner = '';
  addLog(t, who, `status: ${from} → ${to}${why ? ` — ${why}` : ''}`);
}

// ---------- commands ----------

function parseArgs(argv) {
  const BOOL = new Set(['json', 'open', 'todo', 'help']);
  const pos = [];
  const flags = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--') && a.length > 2) {
      const k = a.slice(2);
      if (BOOL.has(k)) { flags[k] = true; continue; }
      const v = argv[++i];
      if (v === undefined) fail(`--${k} needs a value`);
      if (k === 'accept') (flags.accept ??= []).push(v);
      else flags[k] = v;
    } else pos.push(a);
  }
  return { pos, flags };
}

// Acceptance criteria are checkbox lines: "- [ ] text" or "- [x] text".
const CHECKBOX = /^- \[( |x)\] /;
function criteriaCount(t) {
  const boxes = t.body['Acceptance criteria'].split('\n').filter((l) => CHECKBOX.test(l));
  return { total: boxes.length, done: boxes.filter((l) => l.startsWith('- [x]')).length };
}

function setCheck(t, rawN, checked, who) {
  const n = Number(rawN);
  const lines = t.body['Acceptance criteria'].split('\n');
  const idx = lines.map((l, i) => (CHECKBOX.test(l) ? i : -1)).filter((i) => i >= 0);
  if (!idx.length) fail(`#${t.id} has no checkbox criteria ("- [ ] ..." lines)`);
  if (!Number.isInteger(n) || n < 1 || n > idx.length) fail(`criterion must be a number from 1 to ${idx.length}`);
  const i = idx[n - 1];
  const text = lines[i].replace(CHECKBOX, '');
  const mark = checked ? 'x' : ' ';
  if (lines[i].startsWith(`- [${mark}]`)) fail(`criterion ${n} of #${t.id} is already ${checked ? 'checked' : 'unchecked'}`);
  lines[i] = `- [${mark}] ${text}`;
  t.body['Acceptance criteria'] = lines.join('\n');
  addLog(t, who, `criterion ${n} ${checked ? 'met' : 'unchecked'}: ${text}`);
}

// Would giving task `id` the dependencies `deps` create a loop?
function findCycle(id, deps, tasks) {
  const byId = new Map(tasks.map((x) => [x.id, x]));
  const seen = new Set();
  const stack = [...deps];
  while (stack.length) {
    const d = stack.pop();
    if (d === id) return true;
    if (seen.has(d)) continue;
    seen.add(d);
    stack.push(...(byId.get(d)?.depends_on ?? []));
  }
  return false;
}

const bullets = (items, prefix) => items.map((s) => `${prefix}${s.trim()}`).join('\n');
const textArg = (s) => (s === '-' ? fs.readFileSync(0, 'utf8') : s ?? '').trim();

const commands = {
  new({ pos, flags }) {
    const title = oneLine(pos.join(' '));
    if (!title) fail('usage: task new "title" [--goal ..] [--accept ..]... [--files a,b] [--depends 1,2] [--todo]');
    const depends_on = (flags.depends || '').split(',').map((s) => s.trim()).filter(Boolean).map(parseId);
    const t = withLock(() => {
      const files = taskFiles();
      const ids = files.map((f) => Number(f.match(TASK_FILE)[1]));
      for (const d of depends_on) if (!ids.includes(d)) fail(`dependency #${d} does not exist`);
      const id = Math.max(0, ...ids) + 1;
      const slug = title.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 40).replace(/-$/, '');
      const ts = now();
      const task = {
        id, title, status: flags.todo ? 'todo' : 'backlog', owner: '', depends_on,
        created: ts, updated: ts, file: `${String(id).padStart(4, '0')}-${slug}.md`,
        body: {
          Goal: textArg(flags.goal),
          'Acceptance criteria': flags.accept ? bullets(flags.accept, '- [ ] ') : '',
          'Relevant files': flags.files ? bullets(flags.files.split(','), '- ') : '',
          "What's been tried": '',
          Log: '',
        },
      };
      addLog(task, actor(flags), `created (${task.status})`);
      save(task);
      return task;
    });
    console.log(`created #${t.id} (${t.status}) tasks/${t.file}`);
  },

  list({ flags }) {
    const { tasks, errors } = loadAll();
    if (flags.status && !STATES.includes(flags.status)) fail(`unknown status "${flags.status}"`);
    const rows = tasks.filter((t) => (flags.status ? t.status === flags.status : !flags.open || !CLOSED.includes(t.status)));
    if (flags.json) return console.log(JSON.stringify(rows.map(publicTask), null, 2));
    for (const e of errors) console.error(`warning: ${e}`);
    if (!rows.length) return console.log('no tasks');
    rows.sort((a, b) => STATES.indexOf(a.status) - STATES.indexOf(b.status) || a.id - b.id);
    for (const t of rows) {
      const deps = t.depends_on.length ? `  needs ${t.depends_on.map((d) => `#${d}`).join(' ')}` : '';
      const c = criteriaCount(t);
      const crit = c.total ? `  [${c.done}/${c.total}]` : '';
      console.log(`#${String(t.id).padEnd(4)} ${t.status.padEnd(12)} ${(t.owner || '-').padEnd(14)} ${t.title}${crit}${deps}`);
    }
  },

  show({ pos }) {
    const t = load(pos[0]);
    process.stdout.write(fs.readFileSync(path.join(DIR, t.file), 'utf8'));
  },

  claim({ pos, flags }) {
    const who = actor(flags);
    const t = mutate(pos[0], (t) => {
      if (t.owner) fail(`#${t.id} is already claimed by ${t.owner}`);
      if (t.status !== 'todo') fail(`#${t.id} is ${t.status}; only todo tasks can be claimed`);
      const { tasks } = loadAll();
      const open = t.depends_on.filter((d) => tasks.find((x) => x.id === d)?.status !== 'done');
      const dead = open.filter((d) => tasks.find((x) => x.id === d)?.status === 'cancelled');
      if (dead.length) {
        fail(`#${t.id} depends on cancelled ${dead.map((d) => `#${d}`).join(', ')}. Change its dependencies with: task edit ${t.id} --depends <ids|none>`);
      }
      if (open.length) fail(`#${t.id} is waiting on ${open.map((d) => `#${d}`).join(', ')}`);
      t.owner = who;
      move(t, 'in-progress', who, `claimed by ${who}`);
    });
    console.log(`#${t.id} claimed by ${t.owner}`);
  },

  update({ pos, flags }) {
    if (!flags.status) fail('usage: task update <id> --status <status>');
    const t = mutate(pos[0], (t) => move(t, flags.status, actor(flags, t)));
    console.log(`#${t.id} → ${t.status}`);
  },

  done({ pos, flags }) {
    const t = mutate(pos[0], (t) => move(t, 'done', actor(flags, t)));
    console.log(`#${t.id} → done`);
    const c = criteriaCount(t);
    if (c.done < c.total) console.error(`warning: #${t.id} is done with ${c.total - c.done} of ${c.total} criteria unchecked`);
  },

  cancel({ pos, flags }) {
    const why = oneLine(pos.slice(1).join(' '));
    if (!why) fail('usage: task cancel <id> "reason"');
    const t = mutate(pos[0], (t) => move(t, 'cancelled', actor(flags, t), why));
    console.log(`#${t.id} → cancelled`);
  },

  edit({ pos, flags }) {
    if (flags.title === undefined && flags.depends === undefined) {
      fail('usage: task edit <id> [--title "new title"] [--depends 1,2|none]');
    }
    const t = mutate(pos[0], (t) => {
      if (CLOSED.includes(t.status)) fail(`#${t.id} is ${t.status} and can no longer be edited`);
      const who = actor(flags, t);
      if (flags.title !== undefined) {
        const title = oneLine(flags.title);
        if (!title) fail('the title cannot be empty');
        addLog(t, who, `title: "${t.title}" → "${title}"`);
        t.title = title;
      }
      if (flags.depends !== undefined) {
        const deps = flags.depends === 'none' ? []
          : [...new Set(flags.depends.split(',').map((s) => s.trim()).filter(Boolean).map(parseId))];
        const { tasks } = loadAll();
        for (const d of deps) {
          if (d === t.id) fail(`#${t.id} cannot depend on itself`);
          if (!tasks.some((x) => x.id === d)) fail(`dependency #${d} does not exist`);
        }
        if (findCycle(t.id, deps, tasks)) fail(`those dependencies would make a loop back to #${t.id}`);
        const fmt = (a) => (a.length ? a.map((d) => `#${d}`).join(', ') : 'none');
        addLog(t, who, `depends on: ${fmt(t.depends_on)} → ${fmt(deps)}`);
        t.depends_on = deps;
      }
    });
    console.log(`#${t.id} updated`);
  },

  check({ pos, flags }) {
    if (pos.length < 2) fail('usage: task check <id> <n>   (n is the criterion number, from 1)');
    const t = mutate(pos[0], (t) => setCheck(t, pos[1], true, actor(flags, t)));
    const c = criteriaCount(t);
    console.log(`#${t.id} criteria ${c.done}/${c.total} met`);
  },

  uncheck({ pos, flags }) {
    if (pos.length < 2) fail('usage: task uncheck <id> <n>');
    const t = mutate(pos[0], (t) => setCheck(t, pos[1], false, actor(flags, t)));
    const c = criteriaCount(t);
    console.log(`#${t.id} criteria ${c.done}/${c.total} met`);
  },

  block({ pos, flags }) {
    const why = oneLine(pos.slice(1).join(' '));
    if (!why) fail('usage: task block <id> "reason"');
    const t = mutate(pos[0], (t) => move(t, 'blocked', actor(flags, t), why));
    console.log(`#${t.id} → blocked`);
  },

  note({ pos, flags }) {
    const text = textArg(pos.slice(1).join(' '));
    if (!text) fail('usage: task note <id> "what you did and why"   (use - to read stdin)');
    const t = mutate(pos[0], (t) => addLog(t, actor(flags, t), text));
    console.log(`#${t.id} note added`);
  },

  tried({ pos, flags }) {
    const text = textArg(pos.slice(1).join(' '));
    if (!text) fail('usage: task tried <id> "approach and outcome"');
    const t = mutate(pos[0], (t) => {
      const entry = `- ${text.replace(/\n/g, '\n  ')}`;
      const k = "What's been tried";
      t.body[k] = t.body[k] ? `${t.body[k]}\n${entry}` : entry;
      addLog(t, actor(flags, t), `tried: ${oneLine(text)}`);
    });
    console.log(`#${t.id} recorded`);
  },

  set({ pos, flags }) {
    const heading = SECTION_KEYS[pos[1]];
    const text = textArg(pos.slice(2).join(' '));
    if (!heading || !text) fail('usage: task set <id> goal|criteria|files "text"   (use - to read stdin)');
    const t = mutate(pos[0], (t) => {
      t.body[heading] = text;
      addLog(t, actor(flags, t), `edited section: ${heading}`);
    });
    console.log(`#${t.id} ${heading} updated`);
  },

  serve({ flags }) {
    const port = Number(flags.port || process.env.TASK_PORT || 4242);
    const server = http.createServer((req, res) => {
      const url = req.url.split('?')[0];
      if (url === '/api/tasks') {
        const { tasks, errors } = loadAll();
        res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' });
        res.end(JSON.stringify({ states: STATES, tasks: tasks.map(publicTask), errors, generated: now() }));
      } else if (url === '/') {
        res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
        res.end(fs.readFileSync(path.join(DIR, 'ui', 'index.html')));
      } else {
        res.writeHead(404).end('not found');
      }
    });
    server.on('error', (e) => {
      console.error(e.code === 'EADDRINUSE' ? `port ${port} is in use; try --port <n>` : e.message);
      process.exit(1);
    });
    server.listen(port, '127.0.0.1', () => console.log(`task board: http://127.0.0.1:${port}  (ctrl-c to stop)`));
  },

  help() {
    console.log(`task — file-per-task kanban

  task new "title" [--goal t] [--accept t]... [--files a,b] [--depends 1,2] [--todo]
  task list [--status s] [--open] [--json]
  task show <id>
  task claim <id> [--owner name]         todo → in-progress, atomic
  task update <id> --status <status>
  task note <id> "text"                  append to the task log
  task tried <id> "text"                 record an approach and its outcome
  task set <id> goal|criteria|files "text"
  task edit <id> [--title t] [--depends 1,2|none]
  task check <id> <n>                    tick acceptance criterion n (uncheck undoes it)
  task block <id> "reason"
  task done <id>                         review → done
  task cancel <id> "reason"              close a task that will not be finished
  task serve [--port 4242]               live board in the browser

  states: ${STATES.join(', ')}
  identity: --owner / --by, else $TASK_OWNER, else $USER
  text arguments accept - to read from stdin`);
  },
};

function publicTask(t) {
  const c = criteriaCount(t);
  return {
    id: t.id, title: t.title, status: t.status, owner: t.owner, depends_on: t.depends_on,
    created: t.created, updated: t.updated, file: `tasks/${t.file}`,
    goal: t.body.Goal, criteria: t.body['Acceptance criteria'], files: t.body['Relevant files'],
    tried: t.body["What's been tried"], log: t.body.Log,
    criteria_done: c.done, criteria_total: c.total,
  };
}

try {
  const [cmd = 'help', ...rest] = process.argv.slice(2);
  const args = parseArgs(rest);
  const run = args.flags.help ? commands.help : commands[cmd];
  if (!run) fail(`unknown command "${cmd}". Run: task help`);
  run(args);
} catch (e) {
  if (!(e instanceof UserError)) throw e;
  console.error(`error: ${e.message}`);
  process.exit(1);
}
