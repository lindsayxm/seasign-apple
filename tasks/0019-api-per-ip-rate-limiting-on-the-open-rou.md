---
id: 19
title: API: per-IP rate limiting on the open routes, and deployment limits
status: in-progress
owner: implementer-1
depends_on: [7]
created: 2026-11-16T03:45:09Z
updated: 2026-11-16T15:59:36Z
---

## Goal

The plan calls for a per-client-IP rate limit on the routes that need no account (/v1/sky, /v1/calendar/events, /v1/sites/resolve, /v1/feed, later /v1/discover); it is not built. Choose the mechanism from current Cloudflare docs (the Workers Rate Limiting binding is the likely fit; it is configured in api/wrangler.jsonc and creates no separate resource) and ask the user before adding anything that is a new service. Also record the deployment constraints found so far: /v1/feed needs the Workers Paid plan (CPU time and subrequest count), and consider limits.cpu_ms. Must be done before any deploy.

## Acceptance criteria

- [ ] Each open route returns 429 with a fixed body past its limit, with tests
- [ ] The plan requirement and chosen limits are recorded in memory/decisions/

## Relevant files

- api/src/app.ts
- api/wrangler.jsonc
- api/test/
- memory/decisions/

## What's been tried


## Log

- 2026-11-16T03:45:09Z [li] created (backlog)
- 2026-11-16T15:59:36Z [li] User approved (2026-11-16) using Cloudflare's Workers Rate Limiting binding for this task.
- 2026-11-16T15:59:36Z [li] status: backlog → todo
- 2026-11-16T15:59:36Z [implementer-1] status: todo → in-progress — claimed by implementer-1
