---
id: 223
title: API subscription B4: DELETE /v1/account
status: backlog
owner: 
depends_on: [222]
created: 2026-11-25T02:31:50Z
updated: 2026-11-25T02:31:50Z
---

## Goal

Read plans/2026-11-24-account-and-subscription.md (phase B), memory/decisions/2026-11-24-subscription-gate-and-ai-lapse-rule.md and memory/notes/2026-11-24-storekit-research.md first. Removes every row of the signed-in user (auth, entitlement, sync tables, push channels tied to the account) and ends the session; the reply tells the phone the Apple subscription itself is cancelled in the App Store, not here. App Store rule 5.1.1(v).

## Acceptance criteria

- [ ] Test: after the delete no table holds a row for that user and another user's rows are untouched
- [ ] npm test and npx tsc --noEmit pass; spec and client regenerated; iOS builds

## Relevant files

- api/src/routes
- api/test
- openapi

## What's been tried


## Log

- 2026-11-25T02:31:50Z [li] created (backlog)
