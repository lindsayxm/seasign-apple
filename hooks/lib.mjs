// Shared helpers for the PreToolUse hooks. Zero dependencies.
import fs from 'node:fs';

// Read the hook payload from stdin. A hook that cannot parse its input lets
// the call through, so a bug here cannot lock the session.
export function readInput() {
  try {
    return JSON.parse(fs.readFileSync(0, 'utf8'));
  } catch {
    process.exit(0);
  }
}

// Exit code 2 blocks the tool call and shows the message to Claude.
export function block(message) {
  console.error(message);
  process.exit(2);
}
