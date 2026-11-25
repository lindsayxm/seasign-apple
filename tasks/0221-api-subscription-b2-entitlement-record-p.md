---
id: 221
title: API subscription B2: entitlement record per account and the one check the routes use
status: in-progress
owner: implementer-1
depends_on: [13]
created: 2026-11-25T02:31:50Z
updated: 2026-11-25T03:32:34Z
---

## Goal

Read plans/2026-11-24-account-and-subscription.md (phase B), memory/decisions/2026-11-24-subscription-gate-and-ai-lapse-rule.md and memory/notes/2026-11-24-storekit-research.md first. An entitlements table (user ID, product ID, original transaction ID, state, expires at, updated at) and one function, activeEntitlement(userId, now), that every paid route calls: active only when the state is active and the expiry is later than now; grace period and billing retry are not active (the user: stop as soon as a renewal fails); no row, or anything unreadable, is not active. A route for the phone to link its purchase to the signed-in account. HOW Apple's signed data is verified and how notifications feed the table is NOT decided (X.509 chain validation of the JWS, or the App Store Server API with a key the user sets): build the table, the check and their tests behind an interface, and stop before the Apple part until the user decides.

## Acceptance criteria

- [ ] Tests: active, expired, grace, billing retry, revoked, no row; the clock is injected
- [ ] Every query scoped by the session user ID
- [ ] npm test and npx tsc --noEmit pass

## Relevant files

- api/src/db/schema.ts
- api/src/lib
- api/test

## What's been tried


## Log

- 2026-11-25T02:31:50Z [li] created (backlog)
- 2026-11-25T03:32:34Z [li] status: backlog → todo
- 2026-11-25T03:32:34Z [implementer-1] status: todo → in-progress — claimed by implementer-1
