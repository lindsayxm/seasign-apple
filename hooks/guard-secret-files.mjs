#!/usr/bin/env node
// PreToolUse (Read|Edit|Write|Bash): keep secrets, Apple signing material and
// the generated Xcode project out of reach. See RULES in AGENTS.md.
import path from 'node:path';
import { readInput, block } from './lib.mjs';

const input = readInput();
const tool = input.tool_name;
const args = input.tool_input ?? {};

const SIGNING = /\.(p8|p12|cer|mobileprovision)$/i;

function secretReason(file) {
  const base = path.basename(file);
  const parts = file.split(/[\\/]/);
  if (base === '.env.example') return null;
  if (base === '.env' || base.startsWith('.env.')) return 'an environment file';
  if (base.startsWith('.dev.vars')) return 'a Wrangler secrets file';
  if (base.endsWith('.toml')) return 'a .toml file (Wrangler config lives in api/wrangler.jsonc)';
  if (parts.includes('.wrangler')) return 'inside .wrangler/';
  if (SIGNING.test(base)) return 'Apple signing material';
  return null;
}

if (tool === 'Read' || tool === 'Edit' || tool === 'Write') {
  const file = String(args.file_path ?? '');
  const why = secretReason(file);
  if (why) block(`Blocked: ${file} is ${why}. Do not read or write it; ask the user if you need a value from it.`);
  if (tool !== 'Read' && /\.xcodeproj([\\/]|$)/.test(file)) {
    block(`Blocked: ${file} is generated. Change ios/project.yml and run "xcodegen generate".`);
  }
}

if (tool === 'Bash') {
  const cmd = String(args.command ?? '');
  // Split on shell separators and quotes, then test each word as a path.
  const words = cmd.split(/[\s'"`;|&<>()=]+/).filter(Boolean);
  for (const w of words) {
    const why = secretReason(w);
    if (why) {
      block(`Blocked: this command names ${w}, which is ${why}. Do not cat, source, copy or otherwise touch it from the shell.`);
    }
  }
  if (/\bsecurity\s+(find-|dump-|export|unlock-)/.test(cmd)) {
    block('Blocked: this command reads keychain contents.');
  }
}

process.exit(0);
