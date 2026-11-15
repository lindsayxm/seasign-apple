#!/usr/bin/env node
// SessionStart: print where the last session left off and the open tasks.
// Whatever this prints is added to the session's context.
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = process.env.CLAUDE_PROJECT_DIR || path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const out = [];

try {
  const text = fs.readFileSync(path.join(root, 'PROJECT-STATUS.md'), 'utf8');
  // Entries follow the "---" rule; each starts with "## YYYY-MM-DD".
  const entries = text.split(/\n(?=## \d{4}-\d{2}-\d{2})/).slice(1);
  out.push('Last PROJECT-STATUS.md entry:');
  out.push(entries.length ? entries[entries.length - 1].trim() : '(none yet; this is the first session)');
} catch {
  out.push('PROJECT-STATUS.md not found.');
}

try {
  const list = execFileSync('node', [path.join(root, 'tasks', 'task.mjs'), 'list', '--open'], { encoding: 'utf8' });
  out.push('', 'Open tasks (./tasks/task list --open):', list.trim());
} catch (e) {
  out.push('', `Could not list tasks: ${String(e.message).split('\n')[0]}`);
}

console.log(out.join('\n'));
