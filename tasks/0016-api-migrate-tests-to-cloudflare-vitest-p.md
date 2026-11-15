---
id: 16
title: API: migrate tests to @cloudflare/vitest-plugin
status: in-progress
owner: implementer-1
depends_on: [3]
created: 2026-11-15T23:09:17Z
updated: 2026-11-15T23:20:23Z
---

## Goal

The user approved switching from the deprecated @cloudflare/vitest-pool-workers (frozen at 0.23.0) to its renamed successor @cloudflare/vitest-plugin. Follow Cloudflare's current migration guide (check the cloudflare-docs MCP server; use their codemod if one exists). Remove the old package, update the Vitest config and any test helpers (including outbound fetch mocking used by the /v1/sky tests), restore a current compatibility_date in api/wrangler.jsonc, rerun npm run cf-typegen if the config changed, and update STACK in AGENTS.md, memory/architecture.md (Test runtime note) and the package name in .claude/skills/scaffold-app/SKILL.md. Installing packages needs npx -y npm@11 install (npm 10.9.2 crashes). No other dependency changes.

## Acceptance criteria

- [ ] api/package.json has @cloudflare/vitest-plugin and no @cloudflare/vitest-pool-workers
- [ ] npm ci with the installed npm, npm test and npx tsc --noEmit all pass
- [ ] compatibility_date in api/wrangler.jsonc is within the last month and wrangler dev still answers /v1/health and /v1/sky
- [ ] AGENTS.md, memory/architecture.md and the scaffold-app skill name the new package
- [ ] npm audit result before and after is recorded in the task log

## Relevant files

- api/package.json
- api/vitest.config.ts
- api/wrangler.jsonc
- api/test/
- AGENTS.md
- memory/architecture.md
- .claude/skills/scaffold-app/SKILL.md

## What's been tried


## Log

- 2026-11-15T23:09:17Z [li] created (todo)
- 2026-11-15T23:20:23Z [implementer-1] status: todo → in-progress — claimed by implementer-1
