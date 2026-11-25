---
id: 222
title: API subscription B3: sync tables and routes (settings, calendar links, sites, saved items, list items)
status: backlog
owner: 
depends_on: [13, 221]
created: 2026-11-25T02:31:50Z
updated: 2026-11-25T02:31:50Z
---

## Goal

Read plans/2026-11-24-account-and-subscription.md (phase B), memory/decisions/2026-11-24-subscription-gate-and-ai-lapse-rule.md and memory/notes/2026-11-24-storekit-research.md first. The sync tables and routes from the v1 plan, each query scoped by the session's user ID and refused without an active entitlement (the B2 check). Decide and record the merge rule (per-row updated-at, deletions as tombstones) and stable IDs for the starter sites and list items so two devices do not duplicate them (see the note on task 220). Calendar links are credentials: say how they are stored. Spec and Swift client regenerated; the iOS app still builds.

## Acceptance criteria

- [ ] Tests: one user never reads or writes another's rows; refused without a session and without an active entitlement; merge and deletion rules
- [ ] npm test and npx tsc --noEmit pass; spec and client regenerated; iOS builds

## Relevant files

- api/src/db/schema.ts
- api/src/routes
- api/test
- openapi

## What's been tried


## Log

- 2026-11-25T02:31:50Z [li] created (backlog)
