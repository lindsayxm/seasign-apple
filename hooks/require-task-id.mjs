#!/usr/bin/env node
// PreToolUse (Bash): every commit message carries a task ID, [#42] or [no-task].
import { readInput, block } from './lib.mjs';

const input = readInput();
const cmd = String(input.tool_input?.command ?? '');

if (/\bgit\b[^|;&]*\bcommit\b/.test(cmd) && !/\[#\d+\]|\[no-task\]/.test(cmd)) {
  block('Blocked: the commit message needs a task ID. Use: git commit -m "[#42] what changed" (or "[no-task] ..." when no task applies). Pass the message with -m so it can be checked.');
}

process.exit(0);
