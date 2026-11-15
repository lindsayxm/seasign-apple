#!/usr/bin/env node
// PreToolUse (Edit|Write|Bash): task files change only through ./tasks/task,
// and PROJECT-STATUS.md is append-only. See RULES in AGENTS.md.
import fs from 'node:fs';
import { readInput, block } from './lib.mjs';

const input = readInput();
const tool = input.tool_name;
const args = input.tool_input ?? {};

const TASK_FILE = /(^|[\\/])tasks[\\/]\d{4,}-[a-z0-9-]*\.md$/;
const STATUS_FILE = /(^|[\\/])PROJECT-STATUS\.md$/;

if (tool === 'Edit' || tool === 'Write') {
  const file = String(args.file_path ?? '');
  if (TASK_FILE.test(file)) {
    block(`Blocked: do not edit ${file} directly. Use the CLI: ./tasks/task help`);
  }
  if (STATUS_FILE.test(file)) {
    if (tool === 'Write' && fs.existsSync(file)) {
      block('Blocked: PROJECT-STATUS.md is append-only. Use Edit to add a new entry at the end; do not rewrite the file.');
    }
    if (tool === 'Edit') {
      const oldS = String(args.old_string ?? '');
      const newS = String(args.new_string ?? '');
      if (args.replace_all || !newS.startsWith(oldS)) {
        block('Blocked: PROJECT-STATUS.md is append-only. The edit must keep the existing text and add after it (new_string must begin with old_string).');
      }
    }
  }
}

if (tool === 'Bash') {
  // Drop harmless redirects (2>&1, 2>/dev/null) before looking for writes.
  const cmd = String(args.command ?? '').replace(/\d*>&\d/g, ' ').replace(/\d*>\s*\/dev\/null/g, ' ');
  const namesTask = /(^|[\s'"=/])tasks\/\d{4,}-[a-z0-9-]*\.md/.test(cmd) || /tasks\/\d{4,}-?\*/.test(cmd);
  const namesStatus = /PROJECT-STATUS\.md/.test(cmd);
  if (namesTask || namesStatus) {
    const writes = />/.test(cmd)
      || /\b(rm|mv|cp|tee|truncate|dd|unlink)\b/.test(cmd)
      || /\bsed\b[^|;&]*\s-[a-zA-Z]*i/.test(cmd)
      || /\bperl\b[^|;&]*\s-[a-zA-Z]*i/.test(cmd)
      || /\bgit\s+(checkout|restore|rm|mv)\b/.test(cmd);
    if (writes) {
      block(namesTask
        ? 'Blocked: task files change only through the CLI (./tasks/task help), not the shell.'
        : 'Blocked: PROJECT-STATUS.md is append-only and is not changed through the shell. Use the Edit tool to append an entry.');
    }
  }
}

process.exit(0);
