---
id: 13
title: API: auth, D1 tables, sync, account deletion, Cron refresh
status: backlog
owner: 
depends_on: [12]
created: 2026-11-15T22:33:55Z
updated: 2026-11-24T19:05:41Z
---

## Goal

Superseded design: read plans/2026-11-24-account-and-subscription.md (approved 2026-11-24), phase B. Better Auth with Sign in with Apple (bearer plugin, appBundleIdentifier from vars); an entitlement record per account fed by Apple; D1 tables and sync routes for settings, calendar links, sites, saved items and list items, every query scoped by the session user ID and refused without an active entitlement; DELETE /v1/account; POST /v1/discover requires an active entitlement (hard rule: no AI on a lapsed subscription); Cron morning refresh for subscribed accounts only. To be split into smaller tasks when phase B starts; how the Worker verifies Apple's signed data is still to be decided.

## Acceptance criteria

- [ ] Every user-data query is scoped by the session user ID, proven by tests
- [ ] DELETE /v1/account removes all of the user's rows
- [ ] npm test and npx tsc --noEmit pass; spec and client regenerated

## Relevant files

- api/src/auth.ts
- api/src/db/schema.ts
- api/src/routes/

## What's been tried


## Log

- 2026-11-15T22:33:55Z [li] created (backlog)
- 2026-11-24T15:55:23Z [li] Lead 2026-11-24: design replaced by plans/2026-11-24-account-and-subscription.md once the user approves it (accounts exist only with a subscription; sync and discover need an entitlement). Do not start from the old goal.
- 2026-11-24T19:05:41Z [li] edited section: Goal
