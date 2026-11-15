---
id: 16
title: API: migrate tests to @cloudflare/vitest-plugin
status: done
owner: implementer-1
depends_on: [3]
created: 2026-11-15T23:09:17Z
updated: 2026-11-15T23:26:44Z
---

## Goal

The user approved switching from the deprecated @cloudflare/vitest-pool-workers (frozen at 0.23.0) to its renamed successor @cloudflare/vitest-plugin. Follow Cloudflare's current migration guide (check the cloudflare-docs MCP server; use their codemod if one exists). Remove the old package, update the Vitest config and any test helpers (including outbound fetch mocking used by the /v1/sky tests), restore a current compatibility_date in api/wrangler.jsonc, rerun npm run cf-typegen if the config changed, and update STACK in AGENTS.md, memory/architecture.md (Test runtime note) and the package name in .claude/skills/scaffold-app/SKILL.md. Installing packages needs npx -y npm@11 install (npm 10.9.2 crashes). No other dependency changes.

## Acceptance criteria

- [x] api/package.json has @cloudflare/vitest-plugin and no @cloudflare/vitest-pool-workers
- [x] npm ci with the installed npm, npm test and npx tsc --noEmit all pass
- [x] compatibility_date in api/wrangler.jsonc is within the last month and wrangler dev still answers /v1/health and /v1/sky
- [x] AGENTS.md, memory/architecture.md and the scaffold-app skill name the new package
- [x] npm audit result before and after is recorded in the task log

## Relevant files

- api/package.json
- api/vitest.config.ts
- api/wrangler.jsonc
- api/test/
- AGENTS.md
- memory/architecture.md
- .claude/skills/scaffold-app/SKILL.md

## What's been tried

- npx @cloudflare/codemods vitest:pool-workers-to-vitest-plugin --dry-run: blocked by the permission classifier (running a downloaded package). Not retried; using the manual steps from Cloudflare's migration guide instead (package.json, vitest.config.ts import, tsconfig types).

## Log

- 2026-11-15T23:09:17Z [li] created (todo)
- 2026-11-15T23:20:23Z [implementer-1] status: todo → in-progress — claimed by implementer-1
- 2026-11-15T23:20:52Z [implementer-1] npm audit before (old package, lockfile at b2d13f1): 10 vulnerabilities (4 moderate, 6 high)
- 2026-11-15T23:21:47Z [implementer-1] tried: npx @cloudflare/codemods vitest:pool-workers-to-vitest-plugin --dry-run: blocked by the permission classifier (running a downloaded package). Not retried; using the manual steps from Cloudflare's migration guide instead (package.json, vitest.config.ts import, tsconfig types).
- 2026-11-15T23:24:33Z [implementer-1] Migrated by hand per Cloudflare's 'Migrate to Vitest plugin' guide (codemod was blocked): package.json devDependency @cloudflare/vitest-plugin ^1.8.2 replaces @cloudflare/vitest-pool-workers; import in vitest.config.ts; types entry in tsconfig.json. Installed with plain npm install on npm 10.9.2 (it did not crash; npx npm@11 was blocked by the permission classifier and turned out not to be needed). Direct deps unchanged: vitest 4.1.12, wrangler 4.162.0. Transitive changes: old plugin's nested wrangler 4.124.0, miniflare 5.20260815.0-alpha, zod 4.4.3, undici 7.29.0, sharp 0.35.2, unenv-preset 2.16.1 removed; plugin pins zod 4.6.6.
- 2026-11-15T23:24:33Z [implementer-1] Fetch mocking: kept vi.spyOn(globalThis, 'fetch'); it still intercepts under plugin 1.8.2. Proof: with GEOCODING_HOST temporarily set to a wrong host, 17 of 24 tests failed with the Worker's 502 in ~26 ms (mock threw, no network); reverted, 24 pass. Cloudflare's docs now recommend @msw/cloudflare + msw 3 for outbound mocks; not installed (two unapproved packages).
- 2026-11-15T23:24:34Z [implementer-1] compatibility_date 2026-08-22 -> 2026-11-13: tests and wrangler dev both run workerd 1.20261113.1. Reran npm run cf-typegen (worker-configuration.d.ts header changed). Verified after npm ci on npm 10.9.2: npm test 24/24, npx tsc --noEmit clean, npm run openapi no diff in openapi/openapi.json, wrangler dev --port 8787: /v1/health 200, /v1/sky?zip=10001 200; server stopped. No compat-date warnings in test or dev output.
- 2026-11-15T23:24:34Z [implementer-1] npm audit after: 4 vulnerabilities (4 moderate, 0 high), all the esbuild advisory GHSA-67mh-4wv8-2f99 via drizzle-kit -> @esbuild-kit. Before: 10 (4 moderate, 6 high).
- 2026-11-15T23:26:05Z [implementer-1] status: in-progress → review
- 2026-11-15T23:26:44Z [implementer-1] criterion 1 met: api/package.json has @cloudflare/vitest-plugin and no @cloudflare/vitest-pool-workers
- 2026-11-15T23:26:44Z [implementer-1] criterion 2 met: npm ci with the installed npm, npm test and npx tsc --noEmit all pass
- 2026-11-15T23:26:44Z [implementer-1] criterion 3 met: compatibility_date in api/wrangler.jsonc is within the last month and wrangler dev still answers /v1/health and /v1/sky
- 2026-11-15T23:26:44Z [implementer-1] criterion 4 met: AGENTS.md, memory/architecture.md and the scaffold-app skill name the new package
- 2026-11-15T23:26:44Z [implementer-1] criterion 5 met: npm audit result before and after is recorded in the task log
- 2026-11-15T23:26:44Z [implementer-1] review (lead): ran npm test (24 passed), tsc clean, npm run openapi no diff; package.json has only the new plugin; compatibility_date 2026-11-13; docs name the new package; audit 10 -> 4 (moderate, esbuild via drizzle-kit). Implementer verified npm ci and wrangler dev.
- 2026-11-15T23:26:44Z [implementer-1] status: review → done
