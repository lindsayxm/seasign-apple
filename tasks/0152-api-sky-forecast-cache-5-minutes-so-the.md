---
id: 152
title: API: sky forecast cache 5 minutes so the app's 10-minute refresh and pulls get fresh data
status: done
owner: lead
depends_on: []
created: 2026-11-19T17:00:57Z
updated: 2026-11-19T17:01:26Z
---

## Goal


## Acceptance criteria


## Relevant files

- api/src/routes/sky.ts
- api/test

## What's been tried


## Log

- 2026-11-19T17:00:57Z [lead] created (todo)
- 2026-11-19T17:00:57Z [lead] status: todo → in-progress — claimed by lead
- 2026-11-19T17:01:26Z [lead] FORECAST_TTL 15 min -> 5 min in api/src/routes/sky.ts; architecture.md KV line updated. tsc clean, npm test 1613 passed. No contract change. No test pinned the old value. Closed by the lead without a separate reviewer.
- 2026-11-19T17:01:26Z [lead] status: in-progress → review
- 2026-11-19T17:01:26Z [lead] status: review → done
