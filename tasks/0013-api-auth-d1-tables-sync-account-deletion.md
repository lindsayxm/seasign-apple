---
id: 13
title: API: auth, D1 tables, sync, account deletion, Cron refresh
status: backlog
owner: 
depends_on: [12]
created: 2026-11-15T22:33:55Z
updated: 2026-11-15T22:33:55Z
---

## Goal

Read plans/2026-11-15-v1-build.md first; it holds the decisions and design. Blocked until the Apple Developer account is approved. Better Auth with Sign in with Apple (bearer plugin, appBundleIdentifier from vars), D1 tables for settings, calendar links, sites, saved items and list items, sync routes, DELETE /v1/account, and the Cron morning refresh of signed-in users' sites. Every query is scoped by the session user ID.

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
